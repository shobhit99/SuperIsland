"use strict";

const PREVIEW_LIMIT_COMPACT = 32;
const PREVIEW_LIMIT_EXPANDED = 72;
const REFRESH_CACHE_MS = 150;

let state = {
  state: "idle",
  loggedIn: false,
  statusText: "Not connected",
  messages: []
};
let lastRefreshAt = 0;

function asObject(value) {
  return value && typeof value === "object" ? value : null;
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function normalizeText(value) {
  if (typeof value !== "string") return "";
  const trimmed = value.trim();
  if (!trimmed) return "";
  const lowered = trimmed.toLowerCase();
  if (lowered === "undefined" || lowered === "null" || lowered === "(null)") return "";
  return trimmed;
}

function truncate(text, limit) {
  const value = normalizeText(text);
  if (!value) return "";
  if (value.length <= limit) return value;
  return `${value.slice(0, limit).trimEnd()}...`;
}

function shouldShowConnectionHint() {
  const configured = DynamicIsland.settings.get("showConnectionHint");
  return typeof configured === "boolean" ? configured : true;
}

function refreshState(force) {
  const now = Date.now();
  if (!force && now - lastRefreshAt < REFRESH_CACHE_MS) {
    return;
  }
  lastRefreshAt = now;

  if (typeof DynamicIsland.system.getWhatsAppWeb !== "function") {
    return;
  }

  const snapshot = asObject(DynamicIsland.system.getWhatsAppWeb(8));
  if (!snapshot) return;

  const messages = asArray(snapshot.messages)
    .map((message) => {
      const row = asObject(message);
      if (!row) return null;

      const sender = normalizeText(row.sender);
      const preview = normalizeText(row.preview);
      if (!sender || !preview) return null;

      const rawTimestamp = Number(row.timestamp);
      const timestamp = Number.isFinite(rawTimestamp)
        ? Math.max(0, Math.floor(rawTimestamp))
        : Math.floor(Date.now() / 1000);

      return {
        id: normalizeText(row.id) || `${sender}:${preview}:${timestamp}`,
        sender,
        preview,
        avatarURL: normalizeText(row.avatarURL),
        timestamp
      };
    })
    .filter(Boolean)
    .slice(0, 8);

  state = {
    state: normalizeText(snapshot.state) || "idle",
    loggedIn: Boolean(snapshot.loggedIn),
    statusText: normalizeText(snapshot.statusText) || "Not connected",
    messages
  };
}

function timeAgoLabel(timestamp) {
  const diff = Math.max(0, Math.floor(Date.now() / 1000) - timestamp);
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  return `${Math.floor(diff / 3600)}h ago`;
}

function compactView() {
  refreshState();

  if (!state.loggedIn) {
    const hint = shouldShowConnectionHint() ? "Scan QR in Extensions" : "WhatsApp Web";
    return View.hstack([
      View.icon("qrcode", { size: 12, color: "green" }),
      View.text(hint, { style: "caption", color: "gray", lineLimit: 1 })
    ], { spacing: 6, align: "center" });
  }

  if (state.messages.length === 0) {
    return View.hstack([
      View.icon("message.fill", { size: 12, color: "green" }),
      View.text("Connected", { style: "caption", color: "white", lineLimit: 1 })
    ], { spacing: 6, align: "center" });
  }

  const latest = state.messages[0];
  return View.hstack([
    View.icon("message.fill", { size: 12, color: "green" }),
    View.text(`${latest.sender}: ${truncate(latest.preview, PREVIEW_LIMIT_COMPACT)}`, {
      style: "caption",
      color: "white",
      lineLimit: 1
    })
  ], { spacing: 6, align: "center" });
}

function expandedView() {
  refreshState();

  if (!state.loggedIn) {
    return View.vstack([
      View.text("WhatsApp Web", { style: "title", lineLimit: 1 }),
      View.text("Login required. Open Extensions settings and scan QR.", {
        style: "caption",
        color: "gray",
        lineLimit: 2
      })
    ], { spacing: 6, align: "leading" });
  }

  const rows = state.messages.slice(0, 2).map((message) =>
    View.hstack([
      View.text(message.sender, { style: "caption", color: "white", lineLimit: 1 }),
      View.spacer(),
      View.text(timeAgoLabel(message.timestamp), { style: "footnote", color: "gray", lineLimit: 1 })
    ], { spacing: 6, align: "center" })
  );

  return View.vstack([
    View.hstack([
      View.text("WhatsApp Web", { style: "title", lineLimit: 1 })
    ], { spacing: 6, align: "center" }),
    View.text(state.statusText, { style: "caption", color: "gray", lineLimit: 1 }),
    ...rows
  ], { spacing: 6, align: "leading" });
}

function fullExpandedView() {
  refreshState();

  if (!state.loggedIn) {
    return View.vstack([
      View.text("WhatsApp Web", { style: "title", lineLimit: 1 }),
      View.text("Scan QR in Extensions settings to connect.", {
        style: "caption",
        color: "gray",
        lineLimit: 2
      }),
      View.button(View.text("Refresh QR", { style: "caption", color: "green", lineLimit: 1 }), "refresh-qr")
    ], { spacing: 8, align: "leading" });
  }

  const rows = state.messages.slice(0, 4).map((message) =>
    View.vstack([
      View.hstack([
        View.text(message.sender, { style: "caption", color: "white", lineLimit: 1 }),
        View.spacer(),
        View.text(timeAgoLabel(message.timestamp), { style: "footnote", color: "gray", lineLimit: 1 })
      ], { spacing: 6, align: "center" }),
      View.text(truncate(message.preview, PREVIEW_LIMIT_EXPANDED), {
        style: "footnote",
        color: "gray",
        lineLimit: 2
      })
    ], { spacing: 3, align: "leading" })
  );

  return View.vstack([
    View.hstack([
      View.text("WhatsApp Web", { style: "title", lineLimit: 1 })
    ], { spacing: 6, align: "center" }),
    ...rows
  ], { spacing: 8, align: "leading" });
}

DynamicIsland.registerModule({
  onActivate() {
    if (typeof DynamicIsland.system.startWhatsAppWeb === "function") {
      DynamicIsland.system.startWhatsAppWeb();
    }
    refreshState(true);
  },

  compact() {
    return compactView();
  },

  minimalCompact: {
    leading() {
      return View.icon("message.fill", { size: 11, color: state.loggedIn ? "green" : "gray" });
    },
    trailing() {
      refreshState();
      const count = state.loggedIn ? String(Math.min(state.messages.length, 9)) : "";
      return count
        ? View.text(count, { style: "caption", color: "green", lineLimit: 1 })
        : View.icon(state.loggedIn ? "checkmark.circle.fill" : "qrcode", { size: 10, color: state.loggedIn ? "green" : "gray" });
    }
  },

  expanded() {
    return expandedView();
  },

  fullExpanded() {
    return fullExpandedView();
  },

  onAction(actionID) {
    if (actionID === "refresh-qr" && typeof DynamicIsland.system.refreshWhatsAppWebQR === "function") {
      DynamicIsland.system.refreshWhatsAppWebQR();
      refreshState(true);
    }
  }
});
