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
let replyComposer = null;

const LEGACY_MEDIA_PREVIEW_LABELS = {
  "<media:image>": "Photo",
  "<media:video>": "Video",
  "<media:audio>": "Audio",
  "<media:document>": "Document",
  "<media:sticker>": "Sticker"
};
function renderInputComposer(options) {
  if (DynamicIsland.components && typeof DynamicIsland.components.inputComposer === "function") {
    return DynamicIsland.components.inputComposer(options);
  }

  return View.inputBox(
    options.placeholder || "",
    options.text || "",
    options.action || "",
    {
      id: options.id || "",
      autoFocus: options.autoFocus !== false,
      minHeight: options.minHeight || 46,
      showsEmojiButton: options.showsEmojiButton === true
    }
  );
}

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

function displayPreview(text) {
  const value = normalizeText(text);
  if (!value) return "";
  return LEGACY_MEDIA_PREVIEW_LABELS[value] || value;
}

function firstLinkURL(text) {
  const value = normalizeText(text);
  if (!value) return "";

  const match = value.match(/\b((?:https?:\/\/|www\.)[^\s<>"']+)/i);
  if (!match || !match[1]) return "";

  let url = match[1];
  while (/[)\].,!?:;]+$/.test(url)) {
    url = url.slice(0, -1);
  }

  if (!url) return "";
  if (/^www\./i.test(url)) {
    url = `https://${url}`;
  }

  return url;
}

function openLinkActionID(url) {
  return `open-link:${encodeURIComponent(url)}`;
}

function escapeMarkdownText(value) {
  return String(value || "")
    .replace(/\\/g, "\\\\")
    .replace(/\[/g, "\\[")
    .replace(/\]/g, "\\]")
    .replace(/\(/g, "\\(")
    .replace(/\)/g, "\\)")
    .replace(/\*/g, "\\*")
    .replace(/_/g, "\\_")
    .replace(/`/g, "\\`");
}

function markdownWithLinkedURL(text, limit) {
  const value = limit ? truncate(text, limit) : normalizeText(text);
  if (!value) return "";

  const match = value.match(/\b((?:https?:\/\/|www\.)[^\s<>"']+)/i);
  if (!match || !match[1]) return "";

  const rawLinkText = match[1];
  let linkText = rawLinkText;
  while (/[)\].,!?:;]+$/.test(linkText)) {
    linkText = linkText.slice(0, -1);
  }
  if (!linkText) return "";

  const start = match.index ?? value.indexOf(rawLinkText);
  if (start < 0) return "";

  const prefix = value.slice(0, start);
  const suffix = value.slice(start + rawLinkText.length);
  const url = firstLinkURL(linkText);
  if (!url) return "";

  return `${escapeMarkdownText(prefix)}[${escapeMarkdownText(linkText)}](${url})${escapeMarkdownText(suffix)}`;
}

function previewNode(preview, limit, style, color, lineLimit) {
  const value = truncate(preview, limit);
  if (!value) {
    return View.text("", { style, color, lineLimit });
  }

  const markdown = markdownWithLinkedURL(preview, limit);
  if (markdown) {
    return View.markdownText(markdown, { style, color, lineLimit });
  }

  return View.text(value, { style, color, lineLimit });
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
      const preview = displayPreview(row.preview);
      if (!sender || !preview) return null;

      const rawTimestamp = Number(row.timestamp);
      const timestamp = Number.isFinite(rawTimestamp)
        ? Math.max(0, Math.floor(rawTimestamp))
        : Math.floor(Date.now() / 1000);

      return {
        id: normalizeText(row.id) || `${sender}:${preview}:${timestamp}`,
        sender,
        preview,
        mediaPreviewURL: normalizeText(row.mediaPreviewURL),
        avatarURL: normalizeText(row.avatarURL),
        replyTarget: normalizeText(row.replyTarget),
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

function openReplyComposer(payload) {
  const replyPayload = asObject(payload);
  if (!replyPayload) return;

  const recipient = normalizeText(replyPayload.recipient);
  if (!recipient) return;
  const messageID = normalizeText(replyPayload.messageID);
  const matchedMessage = state.messages.find((message) =>
    (messageID && message.id === messageID) || message.replyTarget === recipient
  );
  const avatarURL = normalizeText(replyPayload.avatarURL) || (matchedMessage && matchedMessage.avatarURL) || "";
  const sender = normalizeText(replyPayload.sender) || (matchedMessage && matchedMessage.sender) || "WhatsApp";
  const preview = displayPreview(replyPayload.preview) || (matchedMessage && matchedMessage.preview) || "";
  const mediaPreviewURL = normalizeText(replyPayload.mediaPreviewURL) || (matchedMessage && matchedMessage.mediaPreviewURL) || "";

  replyComposer = {
    inputID: messageID || recipient,
    notificationSourceID: normalizeText(replyPayload.notificationSourceID),
    recipient,
    sender,
    preview,
    mediaPreviewURL,
    avatarURL,
    error: ""
  };

  if (typeof DynamicIsland.system.startWhatsAppWeb === "function") {
    DynamicIsland.system.startWhatsAppWeb();
  }
  refreshState(true);
}

function closeReplyComposer() {
  replyComposer = null;
}

function mediaPreviewSection() {
  const previewText = replyComposer.preview || "Send a quick reply from Dynamic Island.";
  const previewMarkdown = markdownWithLinkedURL(previewText);
  const previewTextNode = View.frame(
    previewMarkdown
      ? View.markdownText(previewMarkdown, {
          style: "body",
          color: { r: 1, g: 1, b: 1, a: 0.7 }
        })
      : View.text(previewText, {
          style: "body",
          color: { r: 1, g: 1, b: 1, a: 0.7 }
        }),
    { maxWidth: 1000, alignment: "leading" }
  );
  const messageScroller = View.frame(
    View.scroll(
      previewTextNode,
      { axes: "vertical", showsIndicators: true }
    ),
    {
      maxWidth: 1000,
      height: replyComposer.mediaPreviewURL ? 52 : 66,
      alignment: "topLeading"
    }
  );

  const previewBody = replyComposer.mediaPreviewURL
    ? View.hstack([
        View.image(replyComposer.mediaPreviewURL, {
          width: 56,
          height: 56,
          cornerRadius: 12
        }),
        View.frame(messageScroller, { maxWidth: 1000, alignment: "topLeading" })
      ], { spacing: 10, align: "top" })
    : messageScroller;

  return View.cornerRadius(
    View.background(
      View.padding(previewBody, { edges: "all", amount: 6 }),
      { r: 1, g: 1, b: 1, a: 0.04 }
    ),
    12
  );
}

function replyComposerView() {
  const headerChildren = [];
  if (replyComposer.avatarURL) {
    headerChildren.push(View.image(replyComposer.avatarURL, {
      width: 24,
      height: 24,
      cornerRadius: 12
    }));
  } else {
    headerChildren.push(View.icon("person.crop.circle.fill", {
      size: 18,
      color: "green"
    }));
  }

  headerChildren.push(
    View.frame(
      View.text(`Reply to ${replyComposer.sender}`, { style: "headline", lineLimit: 1 }),
      { maxWidth: 1000, alignment: "leading" }
    )
  );

  return View.frame(
    View.vstack([
      View.hstack([
        ...headerChildren,
        View.spacer(),
        View.button(View.text("Close", { style: "caption", color: "gray", lineLimit: 1 }), "close-reply")
      ], { spacing: 8, align: "top" }),
      mediaPreviewSection(),
      renderInputComposer({
        placeholder: `Message ${replyComposer.sender}`,
        text: "",
        action: "submit-reply",
        id: replyComposer.inputID,
        autoFocus: true,
        minHeight: 46,
        showsEmojiButton: true,
        showsShortcutHint: false,
        chrome: false,
        error: replyComposer.error,
        spacing: 2,
        padding: 4
      })
    ], { spacing: 6, align: "leading" }),
    { maxHeight: 1000, alignment: "topLeading" }
  );
}

function expandedView() {
  refreshState();

  if (replyComposer) {
    return View.vstack([
      View.text(`Replying to ${replyComposer.sender}`, { style: "title", lineLimit: 1 }),
      View.text("Opened from notification. Expand to send your reply.", {
        style: "caption",
        color: "gray",
        lineLimit: 2
      })
    ], { spacing: 6, align: "leading" });
  }

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

  if (replyComposer) {
    return replyComposerView();
  }

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
      previewNode(message.preview, PREVIEW_LIMIT_EXPANDED, "footnote", "gray", 2)
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
      return;
    }

    if (actionID === "close-reply") {
      closeReplyComposer();
      const closed = typeof DynamicIsland.system.closePresentedInteraction === "function"
        ? !!DynamicIsland.system.closePresentedInteraction()
        : false;
      if (!closed) {
        refreshState(true);
      }
      return;
    }

    if (actionID === "open-reply") {
      refreshState(true);
      openReplyComposer(arguments[1]);
      refreshState(true);
      return;
    }

    if (actionID === "submit-reply") {
      const body = normalizeText(arguments[1]);
      if (!replyComposer || !body) {
        return;
      }
      if (typeof DynamicIsland.system.sendWhatsAppWebMessageAsync !== "function") {
        replyComposer.error = "Reply API unavailable.";
        refreshState(true);
        return;
      }

      const recipient = replyComposer.recipient;
      const notificationSourceID = replyComposer.notificationSourceID;
      DynamicIsland.system.sendWhatsAppWebMessageAsync(recipient, body);
      if (notificationSourceID && typeof DynamicIsland.system.dismissNotification === "function") {
        DynamicIsland.system.dismissNotification(notificationSourceID);
      }
      closeReplyComposer();
      const closed = typeof DynamicIsland.system.closePresentedInteraction === "function"
        ? !!DynamicIsland.system.closePresentedInteraction()
        : false;
      if (!closed) {
        refreshState(true);
      }
      DynamicIsland.playFeedback("success");
      return;
    }
  }
});
