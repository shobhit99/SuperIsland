import fsSync from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import readline from "node:readline";
import {
  DisconnectReason,
  extractMessageContent,
  fetchLatestBaileysVersion,
  getContentType,
  makeCacheableSignalKeyStore,
  makeWASocket,
  normalizeMessageContent,
  useMultiFileAuthState,
} from "@whiskeysockets/baileys";

const silentLogger = {
  level: "silent",
  child() {
    return this;
  },
  trace() {},
  debug() {},
  info() {},
  warn() {},
  error() {},
  fatal() {},
};

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) {
      continue;
    }
    const key = token.slice(2);
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) {
      result[key] = true;
      continue;
    }
    result[key] = next;
    index += 1;
  }
  return result;
}

function emit(event) {
  process.stdout.write(`${JSON.stringify(event)}\n`);
}

function emitError(message, details) {
  emit({ type: "error", message, details: details ?? null });
}

function sanitizeText(value) {
  if (typeof value !== "string") {
    return "";
  }
  return value.replace(/\s+/g, " ").trim();
}

function coerceTimestampMs(value) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value > 1_000_000_000_000 ? Math.floor(value) : Math.floor(value * 1000);
  }
  if (typeof value === "bigint") {
    return Number(value) * 1000;
  }
  if (value && typeof value === "object") {
    if (typeof value.toString === "function") {
      const parsed = Number(value.toString());
      if (Number.isFinite(parsed)) {
        return parsed > 1_000_000_000_000 ? Math.floor(parsed) : Math.floor(parsed * 1000);
      }
    }
    if (typeof value.low === "number") {
      return Math.floor(value.low * 1000);
    }
  }
  return Date.now();
}

function jidLabel(jid) {
  const trimmed = sanitizeText(jid);
  if (!trimmed) {
    return "";
  }
  return trimmed.split("@")[0] || trimmed;
}

function unwrapMessage(message) {
  return normalizeMessageContent(message) ?? undefined;
}

function extractText(message) {
  const normalized = unwrapMessage(message);
  if (!normalized) {
    return undefined;
  }
  const extracted = extractMessageContent(normalized);
  const candidates = [normalized, extracted && extracted !== normalized ? extracted : undefined];
  for (const candidate of candidates) {
    if (!candidate) {
      continue;
    }
    const conversation = sanitizeText(candidate.conversation);
    if (conversation) {
      return conversation;
    }
    const extended = sanitizeText(candidate.extendedTextMessage?.text);
    if (extended) {
      return extended;
    }
    const caption = sanitizeText(
      candidate.imageMessage?.caption ??
        candidate.videoMessage?.caption ??
        candidate.documentMessage?.caption,
    );
    if (caption) {
      return caption;
    }
  }
  return undefined;
}

function extractMediaPlaceholder(message) {
  const normalized = unwrapMessage(message);
  if (!normalized) {
    return undefined;
  }
  if (normalized.imageMessage) {
    return "<media:image>";
  }
  if (normalized.videoMessage) {
    return "<media:video>";
  }
  if (normalized.audioMessage) {
    return "<media:audio>";
  }
  if (normalized.documentMessage) {
    return "<media:document>";
  }
  if (normalized.stickerMessage) {
    return "<media:sticker>";
  }
  const contentType = getContentType(normalized);
  if (contentType) {
    return `<${contentType}>`;
  }
  return undefined;
}

function extractPreview(message) {
  return extractText(message) ?? extractMediaPlaceholder(message) ?? undefined;
}

function extractSender(message) {
  return (
    sanitizeText(message.pushName) ||
    sanitizeText(message.verifiedBizName) ||
    jidLabel(message.key?.participant) ||
    jidLabel(message.key?.remoteJid) ||
    "WhatsApp"
  );
}

function normalizeRecipient(to) {
  const raw = sanitizeText(to);
  if (!raw) {
    throw new Error("recipient_required");
  }
  if (raw.includes("@")) {
    return raw;
  }
  const digits = raw.replace(/[^\d]/g, "");
  if (!digits) {
    throw new Error("recipient_must_be_phone_or_jid");
  }
  return `${digits}@s.whatsapp.net`;
}

function getStatusCode(err) {
  return err?.output?.statusCode ?? err?.status ?? undefined;
}

class WhatsAppSocketProvider {
  constructor(authDir) {
    this.authDir = authDir;
    this.sock = null;
    this.connectingPromise = null;
    this.startRequested = false;
    this.reconnectTimer = null;
    this.reconnectAttempts = 0;
    this.saveQueue = Promise.resolve();
  }

  emitState(state, statusText, extra = {}) {
    emit({ type: "state", state, statusText, ...extra });
  }

  hasStoredSession() {
    try {
      const credsPath = path.join(this.authDir, "creds.json");
      const stats = fsSync.statSync(credsPath);
      return stats.isFile() && stats.size > 1;
    } catch {
      return false;
    }
  }

  async start({ forceFresh = false } = {}) {
    this.startRequested = true;
    if (forceFresh) {
      await this.clearAuthState();
      await this.resetSocket();
    }
    return this.connectSocket();
  }

  async refreshQR() {
    this.emitState("loading", "Refreshing QR code...");
    return this.start({ forceFresh: true });
  }

  async logout() {
    this.startRequested = true;
    this.emitState("loading", "Logging out...");
    const sock = this.sock;
    if (sock && typeof sock.logout === "function") {
      try {
        await sock.logout();
      } catch {
        // ignore
      }
    }
    await this.clearAuthState();
    await this.resetSocket();
    return this.connectSocket();
  }

  async shutdown() {
    this.startRequested = false;
    clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    await this.resetSocket();
  }

  async resetSocket() {
    const sock = this.sock;
    this.sock = null;
    if (!sock) {
      return;
    }
    try {
      sock.ws?.close();
    } catch {
      // ignore
    }
  }

  async clearAuthState() {
    try {
      await fs.rm(this.authDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
    await fs.mkdir(this.authDir, { recursive: true });
  }

  async connectSocket() {
    if (this.sock) {
      return this.sock;
    }
    if (this.connectingPromise) {
      return this.connectingPromise;
    }

    this.connectingPromise = this.createSocket().finally(() => {
      this.connectingPromise = null;
    });
    return this.connectingPromise;
  }

  async createSocket() {
    clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;

    await fs.mkdir(this.authDir, { recursive: true });
    this.emitState(
      "loading",
      this.hasStoredSession() ? "Restoring WhatsApp session..." : "Connecting to WhatsApp...",
    );

    const { state, saveCreds } = await useMultiFileAuthState(this.authDir);
    const { version } = await fetchLatestBaileysVersion();
    const sock = makeWASocket({
      auth: {
        creds: state.creds,
        keys: makeCacheableSignalKeyStore(state.keys, silentLogger),
      },
      version,
      logger: silentLogger,
      browser: ["DynamicIsland", "macOS", "1.0.0"],
      printQRInTerminal: false,
      syncFullHistory: false,
      markOnlineOnConnect: false,
      emitOwnEvents: false,
      shouldSyncHistoryMessage: () => false,
    });

    this.sock = sock;
    sock.ev.on("creds.update", () => {
      this.saveQueue = this.saveQueue
        .then(() => Promise.resolve(saveCreds()))
        .catch((error) => {
          emitError("Failed saving WhatsApp credentials", String(error));
        });
    });

    sock.ev.on("connection.update", (update) => {
      void this.handleConnectionUpdate(sock, update);
    });

    sock.ev.on("messages.upsert", (upsert) => {
      void this.handleMessagesUpsert(sock, upsert);
    });

    if (sock.ws && typeof sock.ws.on === "function") {
      sock.ws.on("error", (error) => {
        emitError("WhatsApp socket error", String(error));
      });
    }

    return sock;
  }

  nextReconnectDelay(statusCode) {
    if (statusCode === 515) {
      return 500;
    }
    const attempt = this.reconnectAttempts;
    this.reconnectAttempts += 1;
    return Math.min(30_000, Math.round(2_000 * Math.pow(1.8, attempt)));
  }

  scheduleReconnect(statusCode) {
    if (!this.startRequested || this.reconnectTimer) {
      return;
    }
    const delay = this.nextReconnectDelay(statusCode);
    this.emitState(
      "loading",
      delay <= 1000 ? "Reconnecting to WhatsApp..." : `Reconnecting to WhatsApp in ${Math.ceil(delay / 1000)}s...`,
    );
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      void this.connectSocket().catch((error) => {
        emitError("Failed reconnecting to WhatsApp", String(error));
        this.scheduleReconnect(undefined);
      });
    }, delay);
  }

  async handleConnectionUpdate(sock, update) {
    if (sock !== this.sock) {
      return;
    }

    if (update.qr) {
      this.emitState("qrReady", "Scan QR code with WhatsApp", { qr: update.qr });
    }

    if (update.connection === "open") {
      this.reconnectAttempts = 0;
      this.emitState("loggedIn", "Connected", {
        wid: sock.user?.id ?? null,
        pushName: sock.user?.name ?? null,
      });
      return;
    }

    if (update.connection === "close") {
      const statusCode = getStatusCode(update.lastDisconnect?.error);
      await this.resetSocket();
      if (statusCode === DisconnectReason.loggedOut) {
        await this.clearAuthState();
        this.emitState("idle", "Logged out. Scan QR code to reconnect.", { loggedOut: true });
        return;
      }
      this.scheduleReconnect(statusCode);
      return;
    }

    if (update.connection === "connecting") {
      this.emitState(
        "loading",
        this.hasStoredSession() ? "Restoring WhatsApp session..." : "Connecting to WhatsApp...",
      );
    }
  }

  async handleMessagesUpsert(sock, upsert) {
    if (sock !== this.sock) {
      return;
    }
    if (upsert.type !== "notify") {
      return;
    }

    for (const message of upsert.messages ?? []) {
      if (!message || message.key?.fromMe) {
        continue;
      }
      const preview = extractPreview(message.message);
      if (!preview) {
        continue;
      }
      emit({
        type: "message",
        id: [message.key?.remoteJid ?? "", message.key?.participant ?? "", message.key?.id ?? ""].join(":"),
        sender: extractSender(message),
        preview,
        timestamp: coerceTimestampMs(message.messageTimestamp),
        chatJid: message.key?.remoteJid ?? null,
        participant: message.key?.participant ?? null,
      });
    }
  }

  async sendMessage(to, body) {
    const sock = this.sock;
    if (!sock) {
      throw new Error("not_logged_in");
    }
    const jid = normalizeRecipient(to);
    const text = sanitizeText(body);
    if (!text) {
      throw new Error("message_required");
    }
    const result = await sock.sendMessage(jid, { text });
    return {
      jid,
      messageId: result?.key?.id ?? null,
    };
  }
}

const args = parseArgs(process.argv.slice(2));
const authDir = path.resolve(String(args["auth-dir"] || path.join(process.cwd(), ".auth")));
const provider = new WhatsAppSocketProvider(authDir);

async function handleCommand(line) {
  const trimmed = sanitizeText(line);
  if (!trimmed) {
    return;
  }

  let command;
  try {
    command = JSON.parse(trimmed);
  } catch (error) {
    emitError("Invalid provider command JSON", String(error));
    return;
  }

  const requestId = sanitizeText(command.requestId) || null;
  try {
    switch (command.command) {
      case "start": {
        await provider.start({ forceFresh: false });
        break;
      }
      case "refreshQR": {
        await provider.refreshQR();
        break;
      }
      case "logout": {
        await provider.logout();
        break;
      }
      case "sendMessage": {
        const result = await provider.sendMessage(command.to, command.body);
        emit({ type: "sendResult", requestId, ok: true, ...result });
        break;
      }
      default: {
        emitError(`Unknown provider command: ${String(command.command || "")}`, requestId);
        break;
      }
    }
  } catch (error) {
    emit({
      type: "sendResult",
      requestId,
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

rl.on("line", (line) => {
  void handleCommand(line);
});

process.on("SIGINT", () => {
  void provider.shutdown().finally(() => process.exit(0));
});

process.on("SIGTERM", () => {
  void provider.shutdown().finally(() => process.exit(0));
});

emit({ type: "ready" });
