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

const AVATAR_CACHE_TTL_MS = 6 * 60 * 60 * 1000;
const AVATAR_NEGATIVE_CACHE_TTL_MS = 15 * 60 * 1000;
const MESSAGE_PREVIEW_CACHE_LIMIT = 500;

function parseJid(value) {
  const jid = sanitizeText(value);
  const atIndex = jid.indexOf("@");
  if (atIndex <= 0) {
    return null;
  }
  const server = jid.slice(atIndex + 1);
  const userCombined = jid.slice(0, atIndex);
  const [userAgent] = userCombined.split(":");
  const [user] = userAgent.split("_");
  if (!user || !server) {
    return null;
  }
  return { user, server };
}

function normalizeJid(value) {
  const parsed = parseJid(value);
  if (!parsed) {
    return "";
  }
  return `${parsed.user}@${parsed.server === "c.us" ? "s.whatsapp.net" : parsed.server}`;
}

function isGroupJid(value) {
  return sanitizeText(value).endsWith("@g.us");
}

function isBroadcastJid(value) {
  return sanitizeText(value).endsWith("@broadcast");
}

function isNewsletterJid(value) {
  return sanitizeText(value).endsWith("@newsletter");
}

function isAvatarEligibleJid(value) {
  const normalized = normalizeJid(value);
  if (!normalized) {
    return false;
  }
  if (isGroupJid(normalized) || isBroadcastJid(normalized) || normalized === "status@broadcast") {
    return false;
  }
  return true;
}

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
  const reaction = sanitizeText(normalized.reactionMessage?.text);
  if (reaction) {
    return reaction;
  }
  const extracted = extractMessageContent(normalized);
  const candidates = [normalized, extracted && extracted !== normalized ? extracted : undefined];
  for (const candidate of candidates) {
    if (!candidate) {
      continue;
    }
    const reaction = sanitizeText(candidate.reactionMessage?.text);
    if (reaction) {
      return reaction;
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

function mediaLabelForContentType(contentType) {
  switch (contentType) {
    case "imageMessage":
      return "Photo";
    case "videoMessage":
      return "Video";
    case "audioMessage":
      return "Audio";
    case "documentMessage":
      return "Document";
    case "stickerMessage":
      return "Sticker";
    default:
      return "";
  }
}

function mediaThumbnailDataURL(bytes) {
  if (!bytes) {
    return undefined;
  }

  const buffer = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes);
  if (buffer.length === 0) {
    return undefined;
  }

  return `data:image/jpeg;base64,${buffer.toString("base64")}`;
}

function extractMediaMetadata(message) {
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

    if (candidate.imageMessage) {
      return {
        label: "Photo",
        previewURL: mediaThumbnailDataURL(candidate.imageMessage.jpegThumbnail),
      };
    }
    if (candidate.videoMessage) {
      return {
        label: "Video",
        previewURL: mediaThumbnailDataURL(candidate.videoMessage.jpegThumbnail),
      };
    }
    if (candidate.audioMessage) {
      return {
        label: "Audio",
        previewURL: undefined,
      };
    }
    if (candidate.documentMessage) {
      return {
        label: sanitizeText(candidate.documentMessage.fileName) || "Document",
        previewURL: mediaThumbnailDataURL(candidate.documentMessage.jpegThumbnail),
      };
    }
    if (candidate.stickerMessage) {
      return {
        label: "Sticker",
        previewURL: undefined,
      };
    }
  }

  const contentType = getContentType(normalized);
  const label = mediaLabelForContentType(contentType);
  if (label) {
    return {
      label,
      previewURL: undefined,
    };
  }
  return undefined;
}

function extractPreview(message) {
  return extractText(message) ?? extractMediaMetadata(message)?.label ?? undefined;
}

function extractMediaPreviewURL(message) {
  return extractMediaMetadata(message)?.previewURL ?? undefined;
}

function truncatePreviewText(value, limit = 48) {
  const text = sanitizeText(value);
  if (!text) {
    return "";
  }
  if (text.length <= limit) {
    return text;
  }
  return `${text.slice(0, limit).trimEnd()}...`;
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

function isReactionMessage(message) {
  const normalized = unwrapMessage(message);
  return Boolean(normalized?.reactionMessage);
}

function isStatusUpdateMessage(message) {
  const remoteJid = sanitizeText(message?.key?.remoteJid);
  const remoteJidAlt = sanitizeText(message?.key?.remoteJidAlt);
  return remoteJid === "status@broadcast" || remoteJidAlt === "status@broadcast";
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
    this.avatarCache = new Map();
    this.pendingAvatarLookups = new Map();
    this.messagePreviewCache = new Map();
    this.mutedChats = new Map();
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

  messageCacheKeys(key) {
    const id = sanitizeText(key?.id);
    if (!id) {
      return [];
    }

    const remoteCandidates = [
      normalizeJid(key?.remoteJidAlt),
      normalizeJid(key?.remoteJid),
    ].filter(Boolean);
    const participantCandidates = [
      normalizeJid(key?.participantAlt),
      normalizeJid(key?.participant),
    ].filter(Boolean);

    const keys = new Set([id]);
    for (const remote of remoteCandidates) {
      keys.add(`${remote}|${id}`);
      for (const participant of participantCandidates) {
        keys.add(`${remote}|${participant}|${id}`);
      }
    }
    for (const participant of participantCandidates) {
      keys.add(`${participant}|${id}`);
    }
    return Array.from(keys);
  }

  cacheMessagePreview(key, preview) {
    const sanitizedPreview = sanitizeText(preview);
    if (!sanitizedPreview) {
      return;
    }

    for (const cacheKey of this.messageCacheKeys(key)) {
      if (this.messagePreviewCache.has(cacheKey)) {
        this.messagePreviewCache.delete(cacheKey);
      }
      this.messagePreviewCache.set(cacheKey, sanitizedPreview);
    }

    while (this.messagePreviewCache.size > MESSAGE_PREVIEW_CACHE_LIMIT) {
      const oldestKey = this.messagePreviewCache.keys().next().value;
      if (!oldestKey) {
        break;
      }
      this.messagePreviewCache.delete(oldestKey);
    }
  }

  messagePreviewForKey(key) {
    for (const cacheKey of this.messageCacheKeys(key)) {
      const preview = this.messagePreviewCache.get(cacheKey);
      if (preview) {
        return preview;
      }
    }
    return null;
  }

  previewForMessage(message) {
    const normalized = unwrapMessage(message);
    if (!normalized) {
      return undefined;
    }

    const reactionEmoji = sanitizeText(normalized.reactionMessage?.text);
    if (reactionEmoji) {
      const reactedPreview = this.messagePreviewForKey(normalized.reactionMessage?.key);
      if (reactedPreview) {
        return `${reactionEmoji} reacted to "${truncatePreviewText(reactedPreview)}"`;
      }
      return reactionEmoji;
    }

    return extractPreview(message);
  }

  isChatMuted(jid) {
    const normalized = normalizeJid(jid);
    if (!normalized) {
      return false;
    }
    const muteExpiration = this.mutedChats.get(normalized);
    if (!muteExpiration) {
      return false;
    }
    // -1 or very large values mean muted indefinitely; otherwise check expiry
    if (muteExpiration === -1 || muteExpiration === 0) {
      return true;
    }
    return muteExpiration > Date.now() / 1000;
  }

  trackChatMuteStatus(chats) {
    for (const chat of chats) {
      const jid = normalizeJid(chat.id);
      if (!jid) {
        continue;
      }
      if (chat.muteExpiration !== undefined && chat.muteExpiration !== null) {
        if (chat.muteExpiration === 0) {
          // 0 can mean unmuted in some Baileys versions
          this.mutedChats.delete(jid);
        } else {
          this.mutedChats.set(jid, chat.muteExpiration);
        }
      } else if (chat.mute !== undefined) {
        if (chat.mute) {
          this.mutedChats.set(jid, -1);
        } else {
          this.mutedChats.delete(jid);
        }
      }
    }
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
      browser: ["SuperIsland", "macOS", "1.0.0"],
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

    sock.ev.on("chats.upsert", (chats) => {
      this.trackChatMuteStatus(chats);
    });

    sock.ev.on("chats.update", (chats) => {
      this.trackChatMuteStatus(chats);
    });

    if (sock.ws && typeof sock.ws.on === "function") {
      sock.ws.on("error", (error) => {
        emitError("WhatsApp socket error", String(error));
      });
    }

    return sock;
  }

  getCachedAvatarURL(jid) {
    const candidates = Array.isArray(jid) ? jid : [jid];
    for (const candidate of candidates) {
      const normalized = normalizeJid(candidate);
      if (!normalized) {
        continue;
      }
      const cached = this.avatarCache.get(normalized);
      if (!cached) {
        continue;
      }
      if (cached.expires <= Date.now()) {
        this.avatarCache.delete(normalized);
        continue;
      }
      return cached.url ?? null;
    }
    return null;
  }

  async fetchAvatarURLForCandidate(sock, jid) {
    const normalized = sanitizeText(jid);
    if (!normalized) {
      return null;
    }

    const cached = this.avatarCache.get(normalized);
    if (cached && cached.expires > Date.now()) {
      return cached.url ?? null;
    }

    const pending = this.pendingAvatarLookups.get(normalized);
    if (pending) {
      return pending;
    }

    const lookup = (async () => {
      try {
        const imageURL = (await sock.profilePictureUrl(normalized, "image", 2000)) ?? null;
        const url = imageURL ?? (await sock.profilePictureUrl(normalized, "preview", 2000)) ?? null;
        this.avatarCache.set(normalized, {
          url,
          expires: Date.now() + (url ? AVATAR_CACHE_TTL_MS : AVATAR_NEGATIVE_CACHE_TTL_MS),
        });
        return url;
      } catch {
        this.avatarCache.set(normalized, {
          url: null,
          expires: Date.now() + AVATAR_NEGATIVE_CACHE_TTL_MS,
        });
        return null;
      } finally {
        this.pendingAvatarLookups.delete(normalized);
      }
    })();

    this.pendingAvatarLookups.set(normalized, lookup);
    return lookup;
  }

  async fetchAvatarURL(sock, jids) {
    const candidates = Array.isArray(jids) ? jids : [jids];
    const normalizedCandidates = Array.from(
      new Set(
        candidates
          .map((value) => normalizeJid(value))
          .filter((value) => isAvatarEligibleJid(value)),
      ),
    );

    if (normalizedCandidates.length === 0) {
      return null;
    }

    const cached = this.getCachedAvatarURL(normalizedCandidates);
    if (cached) {
      return cached;
    }

    for (const candidate of normalizedCandidates) {
      const avatarURL = await this.fetchAvatarURLForCandidate(sock, candidate);
      if (avatarURL) {
        for (const alias of normalizedCandidates) {
          this.avatarCache.set(alias, {
            url: avatarURL,
            expires: Date.now() + AVATAR_CACHE_TTL_MS,
          });
        }
        return avatarURL;
      }
    }

    return null;
  }

  async resolveAvatarCandidateJids(sock, message) {
    const key = message?.key ?? {};
    const candidates = [
      key.participantAlt,
      key.participant,
      key.remoteJidAlt,
      key.remoteJid,
    ]
      .map((value) => normalizeJid(value))
      .filter((value) => isAvatarEligibleJid(value));

    const lidLookup = sock.signalRepository?.lidMapping;
    const expanded = [...candidates];
    for (const candidate of candidates) {
      try {
        if (candidate.endsWith("@lid")) {
          const pn = await lidLookup?.getPNForLID?.(candidate);
          if (pn) {
            expanded.push(normalizeJid(pn));
          }
        } else if (candidate.endsWith("@s.whatsapp.net")) {
          const lid = await lidLookup?.getLIDForPN?.(candidate);
          if (lid) {
            expanded.push(normalizeJid(lid));
          }
        }
      } catch {
        // ignore lookup failures
      }
    }

    return Array.from(new Set(expanded.filter((value) => isAvatarEligibleJid(value))));
  }

  async maybeEmitAvatarUpdate(sock, jids, payload) {
    const avatarURL = await this.fetchAvatarURL(sock, jids);
    if (!avatarURL || avatarURL === payload.avatarURL) {
      return;
    }
    emit({ ...payload, avatarURL });
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
      if (isStatusUpdateMessage(message)) {
        continue;
      }
      const remoteJid = sanitizeText(message.key?.remoteJid);
      // Skip WhatsApp channels/newsletters
      if (isNewsletterJid(remoteJid)) {
        continue;
      }
      // Skip muted chats and groups
      if (this.isChatMuted(remoteJid)) {
        continue;
      }
      const isReaction = isReactionMessage(message.message);
      // For reactions in groups, only show if the reacted message was ours
      if (isReaction && isGroupJid(remoteJid)) {
        const normalized = unwrapMessage(message.message);
        const reactedKey = normalized?.reactionMessage?.key;
        if (!reactedKey?.fromMe) {
          continue;
        }
      }
      const preview = this.previewForMessage(message.message);
      if (!preview) {
        continue;
      }
      if (!isReaction) {
        this.cacheMessagePreview(message.key, preview);
      }
      const avatarJids = await this.resolveAvatarCandidateJids(sock, message);
      const payload = {
        type: "message",
        id: [message.key?.remoteJid ?? "", message.key?.participant ?? "", message.key?.id ?? ""].join(":"),
        sender: extractSender(message),
        preview,
        mediaPreviewURL: extractMediaPreviewURL(message.message),
        isReaction,
        avatarURL: this.getCachedAvatarURL(avatarJids),
        timestamp: coerceTimestampMs(message.messageTimestamp),
        chatJid: message.key?.remoteJid ?? null,
        participant: message.key?.participant ?? null,
        participantAlt: message.key?.participantAlt ?? null,
        chatJidAlt: message.key?.remoteJidAlt ?? null,
      };
      emit(payload);
      if (avatarJids.length > 0 && !payload.avatarURL) {
        void this.maybeEmitAvatarUpdate(sock, avatarJids, payload);
      }
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
    if (result?.key) {
      this.cacheMessagePreview(
        {
          remoteJid: result.key.remoteJid ?? jid,
          remoteJidAlt: result.key.remoteJidAlt ?? null,
          participant: result.key.participant ?? null,
          participantAlt: result.key.participantAlt ?? null,
          id: result.key.id ?? null,
        },
        text,
      );
    }
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
