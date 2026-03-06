"use strict";

const SCAN_LIMIT = 30;
const DEFAULT_AUTO_REVEAL = true;
const PREVIEW_UNAVAILABLE = "Preview unavailable";
const PREVIEW_CHAR_LIMIT = 100;
const COMPACT_CHAR_LIMIT = 40;
const EXTENSION_BUNDLE_ID = "com.workview.whatsapp-notifier";
const WHATSAPP_BUNDLE_ID = "net.whatsapp.WhatsApp";
const LAST_HANDLED_KEY = "lastHandledWhatsAppMessageID";

let latestMessage = null;
let recentMessages = [];

function asObject(value) {
  return value && typeof value === "object" ? value : null;
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function normalizeAvatarURL(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (trimmed.startsWith("https://") || trimmed.startsWith("http://") || trimmed.startsWith("file://")) {
    return trimmed;
  }
  if (trimmed.startsWith("/")) return `file://${trimmed}`;
  return null;
}

function normalizeText(value) {
  if (typeof value !== "string") return "";
  const trimmed = value.trim();
  if (!trimmed) return "";
  const lowered = trimmed.toLowerCase();
  if (lowered === "undefined" || lowered === "null" || lowered === "(null)") return "";
  return trimmed;
}

function sanitizeNotification(value) {
  const notification = asObject(value);
  if (!notification) return null;

  const sourceID = typeof notification.id === "string" ? notification.id : null;
  const localID = typeof notification.localID === "string" ? notification.localID : null;
  const id = sourceID || localID;

  const appName = normalizeText(notification.appName);
  const bundleIdentifier = normalizeText(notification.bundleIdentifier);
  const senderName = normalizeText(notification.senderName);
  const title = normalizeText(notification.title);
  const body = normalizeText(notification.body);
  const previewText = normalizeText(notification.previewText);
  const avatarURL = normalizeAvatarURL(notification.avatarURL);

  const rawTimestamp = Number(notification.timestamp);
  const timestamp = Number.isFinite(rawTimestamp)
    ? Math.max(0, Math.floor(rawTimestamp))
    : Math.floor(Date.now() / 1000);

  return {
    id: id || `${appName}:${title}:${body}:${timestamp}`,
    sourceID,
    localID,
    appName,
    bundleIdentifier,
    senderName,
    title,
    body,
    previewText,
    avatarURL,
    timestamp
  };
}

function isWhatsAppNotification(notification) {
  if (!notification) return false;

  const notificationID = String(notification.id || "");
  const appName = String(notification.appName || "").toLowerCase();
  const bundleIdentifier = String(notification.bundleIdentifier || "").toLowerCase();
  const title = String(notification.title || "").toLowerCase();
  const body = String(notification.body || "").toLowerCase();

  if (notificationID.startsWith("whatsapp:")) {
    return false;
  }

  if (bundleIdentifier === EXTENSION_BUNDLE_ID) {
    return false;
  }

  return (
    appName === "whatsapp" ||
    bundleIdentifier.includes("net.whatsapp") ||
    title.includes("whatsapp") ||
    body.includes("whatsapp")
  );
}

function isGenericLabel(value) {
  const text = normalizeText(value).toLowerCase();
  return text === "" || text === "whatsapp" || text === "new whatsapp message" || text === "new message" || text === "message";
}

function truncateWithEllipsis(text, maxChars) {
  const normalized = normalizeText(text);
  if (!normalized) return "";
  if (normalized.length <= maxChars) return normalized;
  return `${normalized.slice(0, maxChars).trimEnd()}...`;
}

function inferSenderFromPreview(notification) {
  const preview = normalizeText(notification.previewText || notification.body || "");
  if (!preview) return "";

  const match = preview.match(/^([^:]{2,40}):\s+/);
  if (!match || !match[1]) return "";

  const candidate = match[1].trim();
  return isGenericLabel(candidate) ? "" : candidate;
}

function resolveDisplayName(notification) {
  const explicitSender = normalizeText(notification.senderName || "");
  if (explicitSender && !isGenericLabel(explicitSender)) return explicitSender;

  const title = normalizeText(notification.title || "");
  if (title && !isGenericLabel(title)) return title;

  const inferredSender = inferSenderFromPreview(notification);
  if (inferredSender) return inferredSender;

  return "WhatsApp";
}

function resolvePreview(notification) {
  const rawPreview = normalizeText(notification.previewText || notification.body || "");
  if (!rawPreview || isGenericLabel(rawPreview)) return PREVIEW_UNAVAILABLE;

  const inferredSender = inferSenderFromPreview(notification);
  if (inferredSender) {
    const prefix = `${inferredSender}:`;
    if (rawPreview.startsWith(prefix)) {
      const withoutPrefix = rawPreview.slice(prefix.length).trim();
      return withoutPrefix ? truncateWithEllipsis(withoutPrefix, PREVIEW_CHAR_LIMIT) : PREVIEW_UNAVAILABLE;
    }
  }

  return truncateWithEllipsis(rawPreview, PREVIEW_CHAR_LIMIT);
}

function hasPreview(notification) {
  return resolvePreview(notification) !== PREVIEW_UNAVAILABLE;
}

function previewColor(notification) {
  return hasPreview(notification) ? "white" : "gray";
}

function qualityScore(notification) {
  return (hasPreview(notification) ? 2 : 0) + (resolveDisplayName(notification) !== "WhatsApp" ? 1 : 0);
}

function dedupeByID(notifications) {
  const seen = Object.create(null);
  const unique = [];

  for (const notification of notifications) {
    if (!notification || !notification.id || seen[notification.id]) continue;
    seen[notification.id] = true;
    unique.push(notification);
  }

  return unique;
}

function sortedNotifications(notifications) {
  return notifications.slice().sort((a, b) => {
    const timeDiff = b.timestamp - a.timestamp;
    if (Math.abs(timeDiff) > 15) return timeDiff;

    const scoreDiff = qualityScore(b) - qualityScore(a);
    if (scoreDiff !== 0) return scoreDiff;

    return b.timestamp - a.timestamp;
  });
}

function readAutoRevealSetting() {
  const configured = DynamicIsland.settings.get("autoReveal");
  return typeof configured === "boolean" ? configured : DEFAULT_AUTO_REVEAL;
}

function timeAgoLabel(timestamp) {
  if (!timestamp) return "just now";

  const diff = Math.max(0, Math.floor(Date.now() / 1000) - timestamp);
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  return `${Math.floor(diff / 3600)}h ago`;
}

function loadStoredLatestMessage() {
  return sanitizeNotification(DynamicIsland.store.get("latestWhatsAppMessage"));
}

function scanWhatsAppNotifications() {
  const entries = asArray(DynamicIsland.system.getRecentNotifications(SCAN_LIMIT));
  const matches = entries
    .map(sanitizeNotification)
    .filter((entry) => entry && isWhatsAppNotification(entry));

  return sortedNotifications(dedupeByID(matches));
}

function shouldAutoReveal(notification) {
  return notification && (hasPreview(notification) || resolveDisplayName(notification) !== "WhatsApp");
}

function refreshMessages() {
  const matches = scanWhatsAppNotifications();
  recentMessages = matches.slice(0, 5);

  if (recentMessages.length > 0) {
    latestMessage = recentMessages[0];
    DynamicIsland.store.set("latestWhatsAppMessage", latestMessage);
  } else if (!latestMessage) {
    latestMessage = loadStoredLatestMessage();
  }

  if (!latestMessage || !latestMessage.id) return;

  const lastHandledID = DynamicIsland.store.get(LAST_HANDLED_KEY);
  if (lastHandledID === latestMessage.id) return;

  DynamicIsland.store.set(LAST_HANDLED_KEY, latestMessage.id);
  if (readAutoRevealSetting() && shouldAutoReveal(latestMessage)) {
    DynamicIsland.island.activate(false);
    setTimeout(() => DynamicIsland.island.activate(false), 120);
  }
}

function avatarNode(notification, size) {
  if (notification.avatarURL) {
    return View.image(notification.avatarURL, {
      width: size,
      height: size,
      cornerRadius: Math.floor(size / 2)
    });
  }

  return View.icon("person.crop.circle.fill", {
    size: Math.max(12, size - 2),
    color: "green"
  });
}

function compactBody() {
  if (!latestMessage) {
    return View.hstack([
      View.icon("message.fill", { size: 12, color: "green" }),
      View.text("Waiting for WhatsApp", { style: "caption", color: "gray", lineLimit: 1 })
    ], { spacing: 6, align: "center" });
  }

  const displayName = resolveDisplayName(latestMessage);
  const preview = truncateWithEllipsis(resolvePreview(latestMessage), COMPACT_CHAR_LIMIT);

  return View.hstack([
    avatarNode(latestMessage, 14),
    View.text(`${displayName}: ${preview}`, {
      style: "caption",
      color: previewColor(latestMessage),
      lineLimit: 1
    })
  ], { spacing: 6, align: "center" });
}

function expandedBody() {
  if (!latestMessage) {
    return View.vstack([
      View.text("WhatsApp", { style: "title" }),
      View.text("No recent messages", { style: "caption", color: "gray", lineLimit: 1 })
    ], { spacing: 4, align: "center" });
  }

  return View.vstack([
    View.hstack([
      avatarNode(latestMessage, 34),
      View.vstack([
        View.text(resolveDisplayName(latestMessage), { style: "body", color: "white", lineLimit: 1 }),
        View.text(resolvePreview(latestMessage), {
          style: "caption",
          color: previewColor(latestMessage),
          lineLimit: 2
        })
      ], { spacing: 2, align: "leading" }),
      View.spacer(),
      View.text(timeAgoLabel(latestMessage.timestamp), { style: "footnote", color: "gray", lineLimit: 1 })
    ], { spacing: 8, align: "center" }),
    View.button(View.text("Open WhatsApp", { style: "caption", color: "green", lineLimit: 1 }), "open-whatsapp")
  ], { spacing: 6, align: "leading" });
}

function fullExpandedBody() {
  if (!latestMessage) {
    return View.vstack([
      View.text("WhatsApp", { style: "title" }),
      View.text("No recent WhatsApp messages", { style: "caption", color: "gray", lineLimit: 1 })
    ], { spacing: 6, align: "center" });
  }

  const rows = recentMessages.slice(0, 4).map((message) => {
    return View.hstack([
      avatarNode(message, 22),
      View.vstack([
        View.hstack([
          View.text(resolveDisplayName(message), { style: "caption", color: "white", lineLimit: 1 }),
          View.spacer(),
          View.text(timeAgoLabel(message.timestamp), { style: "footnote", color: "gray", lineLimit: 1 })
        ], { spacing: 6, align: "center" }),
        View.text(resolvePreview(message), {
          style: "footnote",
          color: previewColor(message),
          lineLimit: 2
        })
      ], { spacing: 4, align: "leading" }),
      View.spacer()
    ], { spacing: 6, align: "center" });
  });

  return View.vstack([
    View.hstack([
      View.text("WhatsApp", { style: "title", lineLimit: 1 }),
      View.spacer(),
      View.button(View.text("Open", { style: "caption", color: "green", lineLimit: 1 }), "open-whatsapp")
    ], { spacing: 6, align: "center" }),
    ...rows
  ], { spacing: 7, align: "leading" });
}

DynamicIsland.registerModule({
  onActivate() {
    latestMessage = loadStoredLatestMessage();
    refreshMessages();
  },

  compact() {
    refreshMessages();
    return compactBody();
  },

  minimalCompact: {
    leading() {
      return View.icon("message.fill", { size: 11, color: "green" });
    },
    trailing() {
      refreshMessages();
      const count = recentMessages.length > 0 ? String(Math.min(recentMessages.length, 9)) : "";
      return count
        ? View.text(count, { style: "caption", color: "green", lineLimit: 1 })
        : View.icon("phone.fill", { size: 10, color: "gray" });
    }
  },

  expanded() {
    refreshMessages();
    return expandedBody();
  },

  fullExpanded() {
    refreshMessages();
    return fullExpandedBody();
  },

  onAction(actionID) {
    if (actionID === "open-whatsapp") {
      DynamicIsland.openURL("whatsapp://");
    }
  }
});
