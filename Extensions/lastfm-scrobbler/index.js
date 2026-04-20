"use strict";

var LASTFM_API_ROOT = "https://ws.audioscrobbler.com/2.0/";
var LASTFM_AUTH_ROOT = "https://www.last.fm/api/auth/";
var LASTFM_API_CREATE_URL = "https://www.last.fm/api/account/create";
var LASTFM_API_ACCOUNTS_URL = "https://www.last.fm/api/accounts";
var LASTFM_DESKTOP_AUTH_DOCS_URL = "https://www.last.fm/api/desktopauth";
var LASTFM_API_KEY = "REPLACE_WITH_LASTFM_API_KEY";
var LASTFM_API_SECRET = "REPLACE_WITH_LASTFM_API_SECRET";
var MAX_BATCH_SIZE = 50;
var MAX_QUEUE_SIZE = 200;
var MAX_HISTORY_SIZE = 300;
var AUTH_POLL_WINDOW_SECONDS = 600;
var NOTIFICATION_COOLDOWN_SECONDS = 45;
var PLACEHOLDER_KEYS = {
  key: "REPLACE_WITH_LASTFM_API_KEY",
  secret: "REPLACE_WITH_LASTFM_API_SECRET"
};
var LASTFM_ICON_DATA_URL = "data:image/svg+xml;utf8,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32' fill='none'%3E%3Cpath fill='%23D51007' d='M14.23 22.512l-1.1-2.99c-1.137 1.176-2.708 1.926-4.454 1.992l-.012 0c-2.371 0-4.055-2.061-4.055-5.36 0-4.227 2.13-5.739 4.226-5.739 3.025 0 3.986 1.959 4.811 4.468l1.1 3.436c1.1 3.332 3.161 6.012 9.106 6.012 4.261 0 7.148-1.305 7.148-4.741 0-2.784-1.581-4.226-4.538-4.914l-2.197-.481c-1.512-.344-1.959-.963-1.959-1.994 0-1.168.927-1.855 2.44-1.855 1.65 0 2.543.619 2.68 2.096l3.436-.412c-.275-3.092-2.405-4.365-5.911-4.365-3.093 0-6.116 1.169-6.116 4.915 0 2.338 1.134 3.814 3.986 4.501l2.337.55c1.753.413 2.336 1.134 2.336 2.13 0 1.271-1.238 1.788-3.575 1.788-.12.009-.26.015-.401.015-2.619 0-4.806-1.847-5.33-4.309l-.006-.036-1.134-3.438c-1.444-4.466-3.746-6.116-8.316-6.116-5.053 0-7.732 3.196-7.732 8.625 0 5.225 2.68 8.043 7.491 8.043.145.009.314.014.485.014 1.994 0 3.826-.692 5.27-1.848l-.017.013z'/%3E%3C/svg%3E";

var state = {
  auth: {
    sessionKey: "",
    username: "",
    pendingToken: "",
    pendingAtEpochMs: 0,
    lastAuthError: "",
    status: "disconnected"
  },
  queue: [],
  history: {},
  currentPlayback: null,
  lastSnapshot: null,
  lastResult: "",
  lastError: "",
  lastNotificationAtEpochMs: 0,
  ui: {
    trailingIndicatorMode: "progress",
    trailingIndicatorAnimationKind: "",
    trailingIndicatorAnimationUntilEpochMs: 0
  }
};
var pollTimer = null;

function toNumber(value, fallback) {
  if (value === null || value === undefined || value === "") return fallback;
  var parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function asObject(value) {
  return value && typeof value === "object" ? value : null;
}

function asString(value) {
  if (value === null || value === undefined) return "";
  return String(value);
}

function trimString(value) {
  return asString(value).trim();
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function nowEpochMs() {
  return Date.now();
}

function nowEpochSeconds() {
  return Math.floor(nowEpochMs() / 1000);
}

function storeGet(key, fallback) {
  var value = SuperIsland.store.get(key);
  return value === null || value === undefined ? fallback : value;
}

function storeSet(key, value) {
  SuperIsland.store.set(key, value);
}

function beginTrailingIndicatorTransition(mode, animationKind, durationMs) {
  state.ui.trailingIndicatorMode = mode;
  state.ui.trailingIndicatorAnimationKind = animationKind || "";
  state.ui.trailingIndicatorAnimationUntilEpochMs = nowEpochMs() + toNumber(durationMs, 0);
}

function currentTrackScrobbled() {
  return !!(state.currentPlayback && (state.currentPlayback.scrobbled || state.history[state.currentPlayback.id]));
}

function trailingIndicatorMode() {
  if (state.ui.trailingIndicatorMode === "success" || currentTrackScrobbled()) return "success";
  return "progress";
}

function trailingIndicatorAnimationKind() {
  if (nowEpochMs() > toNumber(state.ui.trailingIndicatorAnimationUntilEpochMs, 0)) return "";
  return trimString(state.ui.trailingIndicatorAnimationKind);
}

function decorateTrailingIndicator(node) {
  var animationKind = trailingIndicatorAnimationKind();
  return animationKind ? View.animate(node, animationKind) : node;
}

function settingBool(key, fallback) {
  var value = SuperIsland.settings.get(key);
  if (typeof value === "boolean") return value;
  if (typeof value === "number") return value !== 0;
  if (typeof value === "string") return value.toLowerCase() === "true";
  return fallback;
}

function effectiveEnabled() {
  var override = SuperIsland.store.get("enabledOverride");
  if (typeof override === "boolean") return override;
  return settingBool("enabled", true);
}

function sendNowPlayingEnabled() {
  var override = SuperIsland.store.get("sendNowPlayingOverride");
  if (typeof override === "boolean") return override;
  return settingBool("sendNowPlaying", true);
}

function hasMediaBridge() {
  return !!(SuperIsland.system && typeof SuperIsland.system.getNowPlaying === "function");
}

function configuredApiKey() {
  var storedValue = trimString(storeGet("apiKey", ""));
  if (storedValue) return storedValue;
  var settingsValue = trimString(SuperIsland.settings.get("apiKey"));
  if (settingsValue) return settingsValue;
  return LASTFM_API_KEY;
}

function configuredApiSecret() {
  var storedValue = trimString(storeGet("apiSecret", ""));
  if (storedValue) return storedValue;
  var settingsValue = trimString(SuperIsland.settings.get("apiSecret"));
  if (settingsValue) return settingsValue;
  return LASTFM_API_SECRET;
}

function draftApiKey() {
  return trimString(storeGet("apiKeyDraft", "")) || trimString(storeGet("apiKey", "")) || trimString(SuperIsland.settings.get("apiKey"));
}

function draftApiSecret() {
  return trimString(storeGet("apiSecretDraft", "")) || trimString(storeGet("apiSecret", "")) || trimString(SuperIsland.settings.get("apiSecret"));
}

function credentialsConfigured() {
  return configuredApiKey() !== PLACEHOLDER_KEYS.key && configuredApiSecret() !== PLACEHOLDER_KEYS.secret;
}

function accentColor() {
  return { r: 0.835, g: 0.063, b: 0.027, a: 1 };
}

function softPanelColor() {
  return { r: 1, g: 1, b: 1, a: 0.06 };
}

function elevatedPanelColor() {
  return { r: 1, g: 1, b: 1, a: 0.09 };
}

function secondaryTextColor() {
  return { r: 1, g: 1, b: 1, a: 0.66 };
}

function mutedTextColor() {
  return { r: 1, g: 1, b: 1, a: 0.48 };
}

function warningTextColor() {
  return { r: 1, g: 0.78, b: 0.35, a: 0.98 };
}

function dangerTextColor() {
  return { r: 1, g: 0.44, b: 0.42, a: 0.98 };
}

function successTextColor() {
  return { r: 0.55, g: 0.96, b: 0.67, a: 0.98 };
}

function subtleRedFillColor() {
  return { r: 0.84, g: 0.06, b: 0.03, a: 0.22 };
}

function subtleGreenFillColor() {
  return { r: 0.15, g: 0.72, b: 0.34, a: 0.24 };
}

function subtleAmberFillColor() {
  return { r: 0.98, g: 0.72, b: 0.16, a: 0.2 };
}

function card(child, options) {
  var opts = asObject(options) || {};
  return View.cornerRadius(
    View.background(
      View.padding(child, { edges: "all", amount: toNumber(opts.padding, 12) }),
      opts.backgroundColor || softPanelColor()
    ),
    toNumber(opts.cornerRadius, 14)
  );
}

function lastFmIconNode(size, cornerRadius) {
  return View.image(LASTFM_ICON_DATA_URL, {
    width: size,
    height: size,
    cornerRadius: cornerRadius || Math.floor(size * 0.24)
  });
}

function lastFmBadgeNode(size, tone) {
  var fill = { r: 1, g: 1, b: 1, a: 0.08 };
  if (tone === "success") fill = subtleGreenFillColor();
  if (tone === "warning") fill = subtleAmberFillColor();
  if (tone === "error") fill = subtleRedFillColor();

  return View.cornerRadius(
    View.background(
      View.frame(lastFmIconNode(size, Math.max(3, Math.floor(size * 0.25))), {
        width: size + 8,
        height: size + 8,
        alignment: "center"
      }),
      fill
    ),
    Math.floor((size + 8) * 0.34)
  );
}

function chipButton(label, actionID, options) {
  var opts = asObject(options) || {};
  var fill = opts.fillColor || elevatedPanelColor();
  var color = opts.textColor || "white";
  var buttonPadding = toNumber(opts.padding, opts.style === "caption" ? 8 : 10);
  var content = View.frame(
    View.cornerRadius(
      View.background(
        View.padding(
          View.hstack([
            opts.icon ? View.icon(opts.icon, { size: opts.style === "caption" ? 10 : 11, color: color }) : null,
            View.text(label, {
              style: opts.style || "footnote",
              color: color,
              lineLimit: 1
            })
          ].filter(Boolean), { spacing: 6, align: "center" }),
          { edges: "all", amount: buttonPadding }
        ),
        fill
      ),
      toNumber(opts.cornerRadius, 10)
    ),
    { maxWidth: opts.fullWidth ? 9999 : undefined, alignment: "center" }
  );

  return View.button(content, actionID);
}

function detailRow(label, value, options) {
  var opts = asObject(options) || {};
  return View.vstack([
    View.text(label, {
      style: "caption",
      color: mutedTextColor(),
      lineLimit: 1
    }),
    View.text(value, {
      style: opts.valueStyle || "body",
      color: opts.valueColor || "white",
      lineLimit: opts.lineLimit || 2
    })
  ], { spacing: 3, align: "leading" });
}

function detailInlineStat(label, value, options) {
  var opts = asObject(options) || {};
  return View.hstack([
    View.text(label, {
      style: "caption",
      color: mutedTextColor(),
      lineLimit: 1
    }),
    View.text(value, {
      style: opts.valueStyle || "footnote",
      color: opts.valueColor || "white",
      lineLimit: opts.lineLimit || 1
    })
  ], { spacing: 4, align: "center" });
}

function formatClock(seconds) {
  var safe = Math.max(0, Math.floor(toNumber(seconds, 0)));
  var minutes = Math.floor(safe / 60);
  var remainingSeconds = safe % 60;
  return minutes + ":" + String(remainingSeconds).padStart(2, "0");
}

function sessionDurationSeconds(session) {
  var duration = toNumber(session && session.durationSeconds, 0);
  return duration > 0 ? duration : 0;
}

function playbackProgressValue(session) {
  if (!session) return 0;
  var duration = sessionDurationSeconds(session);
  if (duration > 0) {
    return clamp(toNumber(session.activePlaySeconds, 0) / duration, 0, 1);
  }
  if (isFinite(session.thresholdSeconds) && session.thresholdSeconds > 0) {
    return clamp(toNumber(session.activePlaySeconds, 0) / session.thresholdSeconds, 0, 1);
  }
  return 0;
}

function scrobbleProgressValue(session) {
  if (!session || !isFinite(session.thresholdSeconds) || session.thresholdSeconds <= 0) return 0;
  return clamp(toNumber(session.activePlaySeconds, 0) / session.thresholdSeconds, 0, 1);
}

function playbackTimelineLabel(session) {
  if (!session) return "0:00 / --:--";
  var duration = sessionDurationSeconds(session);
  return formatClock(session.activePlaySeconds) + " / " + (duration > 0 ? formatClock(duration) : "--:--");
}

function scrobbleCheckpointLabel(session, summary) {
  if (!session) return "Scrobble at --:--";
  if (!isFinite(session.thresholdSeconds)) return "Too short to scrobble";
  if (summary.tone === "success") return "Sent at " + formatClock(session.scrobbledAtSeconds || session.thresholdSeconds);
  return "Scrobble at " + formatClock(session.thresholdSeconds);
}

function queueCountLabel() {
  return state.queue.length === 1 ? "1 queued scrobble" : state.queue.length + " queued scrobbles";
}

function currentArtworkURL() {
  var snapshot = asObject(state.lastSnapshot);
  if (snapshot && trimString(snapshot.artworkURL)) return trimString(snapshot.artworkURL);
  var session = asObject(state.currentPlayback);
  if (session && trimString(session.artworkURL)) return trimString(session.artworkURL);
  return "";
}

function artworkNode(size, cornerRadius) {
  var artworkURL = currentArtworkURL();
  if (artworkURL) {
    return View.image(artworkURL, {
      width: size,
      height: size,
      cornerRadius: cornerRadius
    });
  }

  return View.cornerRadius(
    View.background(
      View.frame(
        View.opacity(lastFmIconNode(Math.floor(size * 0.52), Math.floor(size * 0.16)), 0.92),
        { width: size, height: size, alignment: "center" }
      ),
      { r: 1, g: 1, b: 1, a: 0.06 }
    ),
    cornerRadius
  );
}

function statusPill(label, tone, options) {
  var opts = asObject(options) || {};
  var fillColor = elevatedPanelColor();
  var textColor = "white";

  if (tone === "success") {
    fillColor = subtleGreenFillColor();
    textColor = successTextColor();
  } else if (tone === "error") {
    fillColor = subtleRedFillColor();
    textColor = dangerTextColor();
  } else if (tone === "warning") {
    fillColor = subtleAmberFillColor();
    textColor = warningTextColor();
  }

  return card(
    View.hstack([
      opts.leadingNode || (opts.icon ? View.icon(opts.icon, {
        size: opts.iconSize || 11,
        color: textColor
      }) : null),
      View.text(label, {
        style: opts.style || "caption",
        color: textColor,
        lineLimit: 1
      })
    ].filter(Boolean), { spacing: 5, align: "center" }),
    {
      padding: toNumber(opts.padding, 8),
      backgroundColor: fillColor,
      cornerRadius: toNumber(opts.cornerRadius, 10)
    }
  );
}

function iconActionButton(label, actionID, options) {
  var opts = asObject(options) || {};
  return chipButton(label, actionID, {
    icon: opts.icon,
    fullWidth: !!opts.fullWidth,
    fillColor: opts.fillColor || elevatedPanelColor(),
    textColor: opts.textColor || "white",
    padding: toNumber(opts.padding, 9),
    cornerRadius: toNumber(opts.cornerRadius, 12)
  });
}

function connectedActionButtons() {
  return card(
    View.hstack([
      iconActionButton("Retry", "retryQueue", {
        icon: "arrow.clockwise.circle.fill",
        fullWidth: true,
        fillColor: { r: 1, g: 1, b: 1, a: 0.1 }
      }),
      iconActionButton(effectiveEnabled() ? "Pause" : "Resume", "toggleEnabled", {
        icon: effectiveEnabled() ? "pause.circle.fill" : "play.circle.fill",
        fullWidth: true,
        fillColor: effectiveEnabled() ? subtleAmberFillColor() : subtleGreenFillColor(),
        textColor: effectiveEnabled() ? warningTextColor() : successTextColor()
      }),
      iconActionButton("Sign out", "signOut", {
        icon: "rectangle.portrait.and.arrow.right",
        fullWidth: true,
        fillColor: subtleRedFillColor(),
        textColor: dangerTextColor()
      })
    ], { spacing: 8, distribution: "fillEqually", align: "center" }),
    { padding: 12 }
  );
}

function lastFmStatusPill(summary) {
  var label = summary.label;
  if (label === "Scrobbled") label = "Sent";
  if (label === "Tracking") label = "Tracking";
  return statusPill(label, summary.tone, {
    leadingNode: lastFmBadgeNode(10, summary.tone),
    padding: 8
  });
}

function sourcePill() {
  return statusPill(currentSourceBadgeLabel(), "neutral", {
    icon: "music.note",
    padding: 8
  });
}

function queueStatusLabel() {
  if (state.queue.length) return state.queue.length === 1 ? "1 queued scrobble" : state.queue.length + " queued scrobbles";
  return "Queue clear";
}

function summaryHeadline(summary, session) {
  if (!session) return "Waiting for playback";
  if (summary.label === "Scrobbled") return "Sent to Last.fm at " + formatClock(session.scrobbledAtSeconds || session.thresholdSeconds);
  if (summary.label === "Paused") return "Paused at " + formatClock(session.activePlaySeconds);
  if (summary.label === "Tracking") return "Scrobbles in " + formatClock(Math.max(0, session.thresholdSeconds - session.activePlaySeconds));
  return summary.detail;
}

function compactSummaryNode(summary) {
  return View.hstack([
    lastFmBadgeNode(12, summary.tone),
    View.text(summaryHeadline(summary, state.currentPlayback), {
      style: "footnote",
      color: summary.tone === "success" ? successTextColor() : "white",
      lineLimit: 2
    })
  ], { spacing: 7, align: "center" });
}

function settingsCard() {
  return card(
    View.vstack([
      View.text("Settings", {
        style: "headline",
        color: "white",
        lineLimit: 1
      }),
      View.hstack([
        View.icon("person.crop.circle.fill", { size: 13, color: secondaryTextColor() }),
        View.text(connectionLabel(), {
          style: "footnote",
          color: "white",
          lineLimit: 1
        }),
        View.spacer(),
        statusPill(currentSourceBadgeLabel(), "neutral", {
          icon: "music.note",
          padding: 8
        })
      ], { spacing: 8, align: "center" }),
      View.toggle(effectiveEnabled(), "Auto scrobble", "toggleEnabled"),
      View.toggle(sendNowPlayingEnabled(), "Send now playing", "toggleSendNowPlaying"),
      state.queue.length
        ? View.hstack([
            statusPill(queueCountLabel(), "warning", {
              icon: "tray.and.arrow.up.fill",
              padding: 8
            }),
            View.spacer()
          ], { spacing: 8, align: "center" })
        : null,
      View.hstack([
        iconActionButton("Retry", "retryQueue", {
          icon: "arrow.clockwise.circle.fill",
          fullWidth: true,
          fillColor: { r: 1, g: 1, b: 1, a: 0.1 }
        }),
        iconActionButton(effectiveEnabled() ? "Pause" : "Resume", "toggleEnabled", {
          icon: effectiveEnabled() ? "pause.circle.fill" : "play.circle.fill",
          fullWidth: true,
          fillColor: effectiveEnabled() ? subtleAmberFillColor() : subtleGreenFillColor(),
          textColor: effectiveEnabled() ? warningTextColor() : successTextColor()
        }),
        iconActionButton("Sign out", "signOut", {
          icon: "rectangle.portrait.and.arrow.right",
          fullWidth: true,
          fillColor: subtleRedFillColor(),
          textColor: dangerTextColor()
        })
      ], { spacing: 8, distribution: "fillEqually", align: "center" })
      ,
      state.lastError
        ? View.vstack([
            View.text("Last.fm issue", {
              style: "caption",
              color: dangerTextColor(),
              lineLimit: 1
            }),
            View.text(trimString(state.lastError.replace("Last.fm now playing failed:", "").replace("Failed to flush scrobble queue:", "")), {
              style: "footnote",
              color: "white",
              lineLimit: 2
            })
          ], { spacing: 4, align: "leading" })
        : (state.lastResult && state.lastResult.indexOf("Now playing:") !== 0)
          ? View.text(state.lastResult, {
              style: "footnote",
              color: secondaryTextColor(),
              lineLimit: 2
            })
          : null
    ].filter(Boolean), { spacing: 10, align: "leading" }),
    { padding: 14 }
  );
}

function scrobblerPlayerCard(size) {
  var session = state.currentPlayback;
  var summary = trackStatusSummary(session);
  var artworkSize = size === "compact" ? 54 : 72;
  var artworkRadius = size === "compact" ? 14 : 18;
  var titleLineLimit = size === "compact" ? 1 : 2;
  var duration = sessionDurationSeconds(session);
  var playbackProgress = playbackProgressValue(session);
  var barColor = summary.tone === "success" ? successTextColor() : accentColor();

  return View.vstack([
      View.hstack([
        artworkNode(artworkSize, artworkRadius),
        View.vstack([
          View.text(currentTrackTitle(), { style: "title", color: "white", lineLimit: titleLineLimit }),
          View.text(currentTrackSubtitle(), { style: "subtitle", color: secondaryTextColor(), lineLimit: 2 }),
          View.hstack([
            lastFmStatusPill(summary),
            View.text(summaryHeadline(summary, session), {
              style: "footnote",
              color: summary.tone === "success" ? successTextColor() : secondaryTextColor(),
              lineLimit: 1
            })
          ], { spacing: 8, align: "center" })
        ], { spacing: 4, align: "leading" })
      ], { spacing: 10, align: "center" }),
      View.vstack([
        View.hstack([
          View.text(playbackTimelineLabel(session), {
            style: "headline",
            color: "white",
            lineLimit: 1
          }),
          View.spacer(),
          View.text(scrobbleCheckpointLabel(session, summary), {
            style: "footnote",
            color: summary.tone === "success" ? successTextColor() : secondaryTextColor(),
            lineLimit: 1
          })
        ], { spacing: 8, align: "center" }),
        View.progress(playbackProgress, { total: 1, color: barColor }),
        duration > 0
          ? View.hstack([
              detailInlineStat("Current", formatClock(session ? session.activePlaySeconds : 0), {
                valueStyle: "footnote",
                lineLimit: 1
              }),
              detailInlineStat("Duration", formatClock(duration), {
                valueStyle: "footnote",
                lineLimit: 1
              }),
              detailInlineStat("Checkpoint", isFinite(session.thresholdSeconds) ? formatClock(session.thresholdSeconds) : "N/A", {
                valueStyle: "footnote",
                valueColor: summary.tone === "success" ? successTextColor() : "white",
                lineLimit: 1
              })
            ], { spacing: 12, distribution: "fillEqually", align: "center" })
          : null
      ].filter(Boolean), { spacing: 8, align: "leading" })
    ], { spacing: 10, align: "leading" });
}

function setupStatusCard() {
  var errorText = trimString(state.lastError.replace("Last.fm now playing failed:", "").replace("Failed to flush scrobble queue:", ""));
  return card(
    View.vstack([
      View.hstack([
        lastFmBadgeNode(16, authConnected() ? "success" : (state.lastError ? "error" : "warning")),
        View.vstack([
          View.text(authConnected() ? "Last.fm connected" : "Last.fm setup in Settings", {
            style: "title",
            color: "white",
            lineLimit: 1
          }),
          View.text(authConnected()
            ? connectionLabel()
            : "Open SuperIsland Settings -> Extensions -> Last.fm Scrobbler to add keys and connect.", {
            style: "footnote",
            color: secondaryTextColor(),
            lineLimit: 2
          })
        ], { spacing: 4, align: "leading" })
      ], { spacing: 10, align: "center" }),
      View.hstack([
        statusPill(credentialsConfigured() ? "API keys saved" : "Missing API keys", credentialsConfigured() ? "success" : "warning", {
          leadingNode: lastFmBadgeNode(10, credentialsConfigured() ? "success" : "warning"),
          padding: 8
        }),
        statusPill(authConnected() ? "Authorized" : "Not authorized", authConnected() ? "success" : "warning", {
          icon: authConnected() ? "checkmark.circle.fill" : "link.circle.fill",
          padding: 8
        })
      ], { spacing: 8, align: "center" }),
      errorText
        ? View.text(errorText, {
            style: "footnote",
            color: dangerTextColor(),
            lineLimit: 2
          })
        : View.text("Playback appears here after connection. Runtime controls stay in Settings, not in the island.", {
            style: "footnote",
            color: secondaryTextColor(),
            lineLimit: 2
          })
    ].filter(Boolean), { spacing: 10, align: "leading" }),
    { padding: 14, backgroundColor: elevatedPanelColor() }
  );
}

function trackStatusSummary(session) {
  if (!session) {
    return {
      label: "Idle",
      tone: "warning",
      detail: "Start playback to create a scrobble session."
    };
  }

  if (session.scrobbled || state.history[session.id]) {
    return {
      label: "Scrobbled",
      tone: "success",
      detail: "Scrobbled at " + formatClock(session.scrobbledAtSeconds || session.thresholdSeconds)
    };
  }

  if (session.thresholdSeconds === Infinity) {
    return {
      label: "Too short",
      tone: "warning",
      detail: "Tracks under 30 seconds are ignored by Last.fm."
    };
  }

  if (state.queue.length) {
    return {
      label: "Queued",
      tone: "warning",
      detail: state.queue.length === 1 ? "1 scrobble waiting to send." : state.queue.length + " scrobbles waiting to send."
    };
  }

  if (session.lastPlaybackState !== "playing") {
    return {
      label: "Paused",
      tone: "warning",
      detail: "Only active playback time counts toward the scrobble."
    };
  }

  return {
    label: "Tracking",
    tone: "neutral",
    detail: "Scrobbles at " + formatClock(session.thresholdSeconds) + "."
  };
}

function feedbackCard() {
  if (state.lastError) {
    var rawError = trimString(state.lastError);
    var title = "Last.fm issue";
    var body = rawError;
    var primaryAction = authConnected() ? "retryQueue" : "auth";
    var primaryLabel = authConnected() ? "Retry" : "Reconnect";

    if (rawError.indexOf("Last.fm now playing failed:") === 0) {
      title = "Could not send now playing";
      body = trimString(rawError.replace("Last.fm now playing failed:", ""));
      primaryAction = "auth";
      primaryLabel = "Reconnect";
    } else if (rawError.indexOf("Last.fm session expired") === 0) {
      title = "Session expired";
      body = rawError;
      primaryAction = "auth";
      primaryLabel = "Reconnect";
    }

    return card(
      View.vstack([
        View.text(title, {
          style: "headline",
          color: dangerTextColor(),
          lineLimit: 1
        }),
        View.text(body, {
          style: "footnote",
          color: secondaryTextColor(),
          lineLimit: 3
        }),
        View.hstack([
          chipButton(primaryLabel, primaryAction, {
            icon: primaryAction === "auth" ? "link.circle.fill" : "arrow.clockwise.circle.fill",
            fullWidth: true,
            fillColor: subtleRedFillColor()
          }),
          chipButton("Dismiss", "dismissError", {
            icon: "xmark.circle.fill",
            fullWidth: true
          })
        ], { spacing: 8, distribution: "fillEqually", align: "center" })
      ], { spacing: 8, align: "leading" }),
      { padding: 12, backgroundColor: { r: 0.8, g: 0.15, b: 0.12, a: 0.16 } }
    );
  }

  if (state.lastResult) {
    if (state.lastResult.indexOf("Now playing:") === 0) {
      return null;
    }
    var tone = state.lastResult.indexOf("Scrobbled ") === 0 || state.lastResult.indexOf("Connected to Last.fm") === 0
      ? "success"
      : "neutral";
    return card(
      View.hstack([
        statusPill(tone === "success" ? "Updated" : "Status", tone),
        View.text(state.lastResult, {
          style: "footnote",
          color: secondaryTextColor(),
          lineLimit: 2
        })
      ], { spacing: 8, align: "center" }),
      { padding: 12 }
    );
  }

  return null;
}

function onboardingField(label, placeholder, textValue, actionID, inputID, options) {
  var opts = asObject(options) || {};
  return card(
    View.vstack([
      View.text(label, {
        style: "caption",
        color: mutedTextColor(),
        lineLimit: 1
      }),
      SuperIsland.components.inputComposer({
        id: inputID,
        placeholder: placeholder,
        text: textValue,
        action: actionID,
        autoFocus: !!opts.autoFocus,
        minHeight: toNumber(opts.minHeight, 46),
        chrome: true,
        padding: 0,
        spacing: 6,
        backgroundColor: { r: 1, g: 1, b: 1, a: 0.035 },
        cornerRadius: 12,
        showsShortcutHint: false,
        showsEmojiButton: false
      }),
      opts.help
        ? View.text(opts.help, {
            style: "footnote",
            color: secondaryTextColor(),
            lineLimit: 2
          })
        : null
    ].filter(Boolean), { spacing: 8, align: "leading" }),
    { padding: 12 }
  );
}

function lastFmFormHintsCard() {
  return card(
    View.vstack([
      View.text("Use These Values On Last.fm", {
        style: "headline",
        color: "white",
        lineLimit: 1
      }),
      View.text("The API form is confusing. Use these exact values. The desktop auth flow does not need a real callback URL in this extension.", {
        style: "footnote",
        color: secondaryTextColor(),
        lineLimit: 3
      }),
      detailRow("Application name", "SuperIsland Last.fm Scrobbler", { lineLimit: 1 }),
      detailRow("Application description", "Desktop scrobbler extension for SuperIsland on macOS.", { lineLimit: 2 }),
      detailRow("Callback URL", "Leave blank", { valueColor: warningTextColor(), lineLimit: 1 }),
      detailRow("Application homepage", "Leave blank", { valueColor: warningTextColor(), lineLimit: 1 })
    ], { spacing: 8, align: "leading" }),
    { padding: 12 }
  );
}

function bridgeWarningNode() {
  return !hasMediaBridge()
    ? card(
        View.vstack([
          View.text("Host App Update Needed", {
            style: "headline",
            color: warningTextColor(),
            lineLimit: 1
          }),
          View.text("You can finish Last.fm setup now, but live playback capture will only work after the forked SuperIsland app is built and launched.", {
            style: "footnote",
            color: warningTextColor(),
            lineLimit: 3
          })
        ], { spacing: 6, align: "leading" }),
        { padding: 12, backgroundColor: { r: 0.96, g: 0.48, b: 0.15, a: 0.14 } }
      )
    : null;
}

function statusSummaryCard() {
  return card(
    View.vstack([
      View.hstack([
        View.vstack([
          View.text("Connect Last.fm", {
            style: "title",
            color: "white",
            lineLimit: 1
          }),
          View.text("Create a Last.fm API app, paste the key pair here, then approve access once in your browser.", {
            style: "footnote",
            color: secondaryTextColor(),
            lineLimit: 3
          })
        ], { spacing: 4, align: "leading" }),
        View.spacer(),
        card(
          View.text(compactStatusLabel().toUpperCase(), {
            style: "caption",
            color: "white",
            lineLimit: 1
          }),
          { padding: 8, backgroundColor: { r: 0.84, g: 0.06, b: 0.03, a: 0.28 }, cornerRadius: 10 }
        )
      ], { spacing: 10, align: "top" })
    ], { spacing: 8, align: "leading" }),
    { padding: 12, backgroundColor: elevatedPanelColor() }
  );
}

function utf8ByteString(input) {
  var text = String(input == null ? "" : input);
  try {
    return unescape(encodeURIComponent(text));
  } catch (error) {
    return text;
  }
}

function md5cycle(x, k) {
  var a = x[0];
  var b = x[1];
  var c = x[2];
  var d = x[3];

  a = ff(a, b, c, d, k[0], 7, -680876936);
  d = ff(d, a, b, c, k[1], 12, -389564586);
  c = ff(c, d, a, b, k[2], 17, 606105819);
  b = ff(b, c, d, a, k[3], 22, -1044525330);
  a = ff(a, b, c, d, k[4], 7, -176418897);
  d = ff(d, a, b, c, k[5], 12, 1200080426);
  c = ff(c, d, a, b, k[6], 17, -1473231341);
  b = ff(b, c, d, a, k[7], 22, -45705983);
  a = ff(a, b, c, d, k[8], 7, 1770035416);
  d = ff(d, a, b, c, k[9], 12, -1958414417);
  c = ff(c, d, a, b, k[10], 17, -42063);
  b = ff(b, c, d, a, k[11], 22, -1990404162);
  a = ff(a, b, c, d, k[12], 7, 1804603682);
  d = ff(d, a, b, c, k[13], 12, -40341101);
  c = ff(c, d, a, b, k[14], 17, -1502002290);
  b = ff(b, c, d, a, k[15], 22, 1236535329);

  a = gg(a, b, c, d, k[1], 5, -165796510);
  d = gg(d, a, b, c, k[6], 9, -1069501632);
  c = gg(c, d, a, b, k[11], 14, 643717713);
  b = gg(b, c, d, a, k[0], 20, -373897302);
  a = gg(a, b, c, d, k[5], 5, -701558691);
  d = gg(d, a, b, c, k[10], 9, 38016083);
  c = gg(c, d, a, b, k[15], 14, -660478335);
  b = gg(b, c, d, a, k[4], 20, -405537848);
  a = gg(a, b, c, d, k[9], 5, 568446438);
  d = gg(d, a, b, c, k[14], 9, -1019803690);
  c = gg(c, d, a, b, k[3], 14, -187363961);
  b = gg(b, c, d, a, k[8], 20, 1163531501);
  a = gg(a, b, c, d, k[13], 5, -1444681467);
  d = gg(d, a, b, c, k[2], 9, -51403784);
  c = gg(c, d, a, b, k[7], 14, 1735328473);
  b = gg(b, c, d, a, k[12], 20, -1926607734);

  a = hh(a, b, c, d, k[5], 4, -378558);
  d = hh(d, a, b, c, k[8], 11, -2022574463);
  c = hh(c, d, a, b, k[11], 16, 1839030562);
  b = hh(b, c, d, a, k[14], 23, -35309556);
  a = hh(a, b, c, d, k[1], 4, -1530992060);
  d = hh(d, a, b, c, k[4], 11, 1272893353);
  c = hh(c, d, a, b, k[7], 16, -155497632);
  b = hh(b, c, d, a, k[10], 23, -1094730640);
  a = hh(a, b, c, d, k[13], 4, 681279174);
  d = hh(d, a, b, c, k[0], 11, -358537222);
  c = hh(c, d, a, b, k[3], 16, -722521979);
  b = hh(b, c, d, a, k[6], 23, 76029189);
  a = hh(a, b, c, d, k[9], 4, -640364487);
  d = hh(d, a, b, c, k[12], 11, -421815835);
  c = hh(c, d, a, b, k[15], 16, 530742520);
  b = hh(b, c, d, a, k[2], 23, -995338651);

  a = ii(a, b, c, d, k[0], 6, -198630844);
  d = ii(d, a, b, c, k[7], 10, 1126891415);
  c = ii(c, d, a, b, k[14], 15, -1416354905);
  b = ii(b, c, d, a, k[5], 21, -57434055);
  a = ii(a, b, c, d, k[12], 6, 1700485571);
  d = ii(d, a, b, c, k[3], 10, -1894986606);
  c = ii(c, d, a, b, k[10], 15, -1051523);
  b = ii(b, c, d, a, k[1], 21, -2054922799);
  a = ii(a, b, c, d, k[8], 6, 1873313359);
  d = ii(d, a, b, c, k[15], 10, -30611744);
  c = ii(c, d, a, b, k[6], 15, -1560198380);
  b = ii(b, c, d, a, k[13], 21, 1309151649);
  a = ii(a, b, c, d, k[4], 6, -145523070);
  d = ii(d, a, b, c, k[11], 10, -1120210379);
  c = ii(c, d, a, b, k[2], 15, 718787259);
  b = ii(b, c, d, a, k[9], 21, -343485551);

  x[0] = add32(a, x[0]);
  x[1] = add32(b, x[1]);
  x[2] = add32(c, x[2]);
  x[3] = add32(d, x[3]);
}

function cmn(q, a, b, x, s, t) {
  a = add32(add32(a, q), add32(x, t));
  return add32((a << s) | (a >>> (32 - s)), b);
}

function ff(a, b, c, d, x, s, t) {
  return cmn((b & c) | ((~b) & d), a, b, x, s, t);
}

function gg(a, b, c, d, x, s, t) {
  return cmn((b & d) | (c & (~d)), a, b, x, s, t);
}

function hh(a, b, c, d, x, s, t) {
  return cmn(b ^ c ^ d, a, b, x, s, t);
}

function ii(a, b, c, d, x, s, t) {
  return cmn(c ^ (b | (~d)), a, b, x, s, t);
}

function md51(s) {
  var n = s.length;
  var stateLocal = [1732584193, -271733879, -1732584194, 271733878];
  var i;
  for (i = 64; i <= n; i += 64) {
    md5cycle(stateLocal, md5blk(s.substring(i - 64, i)));
  }
  s = s.substring(i - 64);
  var tail = new Array(16);
  for (i = 0; i < 16; i += 1) tail[i] = 0;
  for (i = 0; i < s.length; i += 1) {
    tail[i >> 2] |= s.charCodeAt(i) << ((i % 4) << 3);
  }
  tail[i >> 2] |= 0x80 << ((i % 4) << 3);
  if (i > 55) {
    md5cycle(stateLocal, tail);
    for (i = 0; i < 16; i += 1) tail[i] = 0;
  }
  tail[14] = n * 8;
  md5cycle(stateLocal, tail);
  return stateLocal;
}

function md5blk(s) {
  var md5blks = [];
  var i;
  for (i = 0; i < 64; i += 4) {
    md5blks[i >> 2] = s.charCodeAt(i) +
      (s.charCodeAt(i + 1) << 8) +
      (s.charCodeAt(i + 2) << 16) +
      (s.charCodeAt(i + 3) << 24);
  }
  return md5blks;
}

var hex_chr = "0123456789abcdef".split("");

function rhex(n) {
  var s = "";
  var j = 0;
  for (; j < 4; j += 1) {
    s += hex_chr[(n >> (j * 8 + 4)) & 0x0F] + hex_chr[(n >> (j * 8)) & 0x0F];
  }
  return s;
}

function hex(x) {
  var i;
  for (i = 0; i < x.length; i += 1) {
    x[i] = rhex(x[i]);
  }
  return x.join("");
}

function md5(s) {
  return hex(md51(utf8ByteString(s)));
}

function add32(a, b) {
  return (a + b) & 0xFFFFFFFF;
}

function signLastFmParams(params) {
  var keys = Object.keys(params).sort();
  var payload = "";
  var i;
  for (i = 0; i < keys.length; i += 1) {
    if (keys[i] === "format") continue;
    payload += keys[i] + params[keys[i]];
  }
  return md5(payload + configuredApiSecret());
}

async function parseResponse(response) {
  if (!response) return { error: "empty_response" };
  if (response.error) return { error: response.error };
  if (asObject(response.data)) return response.data;
  if (typeof response.data === "string" && response.data) {
    try {
      return JSON.parse(response.data);
    } catch (error) {
      return { error: String(error) };
    }
  }
  if (response.body) {
    try {
      return JSON.parse(response.body);
    } catch (error) {
      return { error: String(error) };
    }
  }
  if (response.text) {
    try {
      return JSON.parse(response.text);
    } catch (error) {
      return { error: String(error) };
    }
  }
  return { error: "invalid_response" };
}

async function lastFmRequest(methodName, params, options) {
  var requestOptions = asObject(options) || {};
  var bodyParams = {};
  var key;

  for (key in params) {
    if (Object.prototype.hasOwnProperty.call(params, key) && params[key] !== null && params[key] !== undefined && params[key] !== "") {
      bodyParams[key] = String(params[key]);
    }
  }

  bodyParams.method = methodName;
  bodyParams.api_key = configuredApiKey();
  bodyParams.format = "json";

  if (requestOptions.signed !== false) {
    bodyParams.api_sig = signLastFmParams(bodyParams);
  }

  var pairs = [];
  var keys = Object.keys(bodyParams);
  var i;
  for (i = 0; i < keys.length; i += 1) {
    pairs.push(encodeURIComponent(keys[i]) + "=" + encodeURIComponent(bodyParams[keys[i]]));
  }

  var requestMethod = requestOptions.method || "POST";
  var url = LASTFM_API_ROOT;
  var fetchOptions = {
    method: requestMethod,
    headers: {},
    body: ""
  };

  if (requestMethod === "GET") {
    url += "?" + pairs.join("&");
  } else {
    fetchOptions.headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8";
    fetchOptions.body = pairs.join("&");
  }

  var response = await SuperIsland.http.fetch(url, fetchOptions);
  return parseResponse(response);
}

function loadState() {
  state.auth = asObject(storeGet("auth", {})) || state.auth;
  state.queue = storeGet("queue", []);
  state.history = asObject(storeGet("history", {})) || {};
  state.currentPlayback = asObject(storeGet("currentPlayback", null));
  state.lastResult = asString(storeGet("lastResult", ""));
  state.lastError = asString(storeGet("lastError", ""));
  state.ui.trailingIndicatorMode = currentTrackScrobbled() ? "success" : "progress";
  state.ui.trailingIndicatorAnimationKind = "";
  state.ui.trailingIndicatorAnimationUntilEpochMs = 0;
}

function persistState() {
  storeSet("auth", state.auth);
  storeSet("queue", state.queue);
  storeSet("history", state.history);
  storeSet("currentPlayback", state.currentPlayback);
  storeSet("lastResult", state.lastResult);
  storeSet("lastError", state.lastError);
}

function markError(message) {
  state.lastError = trimString(message);
  persistState();
  maybeNotify("Last.fm Scrobbler", state.lastError);
}

function clearError() {
  state.lastError = "";
  persistState();
}

function maybeNotify(title, body) {
  if (!settingBool("notifyErrors", true)) return;
  var now = nowEpochMs();
  if (now - state.lastNotificationAtEpochMs < NOTIFICATION_COOLDOWN_SECONDS * 1000) return;
  state.lastNotificationAtEpochMs = now;
  SuperIsland.notifications.send({
    title: title,
    body: body,
    sound: false
  });
}

function sourceAllowed(snapshot) {
  var bundleIdentifier = trimString(snapshot.bundleIdentifier);

  if (bundleIdentifier === "com.spotify.client") {
    return settingBool("allowSpotify", true);
  }
  if (bundleIdentifier === "com.apple.Music") {
    return settingBool("allowAppleMusic", true);
  }
  if (
    bundleIdentifier === "com.google.Chrome" ||
    bundleIdentifier === "com.google.Chrome.canary" ||
    bundleIdentifier === "com.apple.Safari" ||
    bundleIdentifier === "com.microsoft.edgemac"
  ) {
    return settingBool("allowBrowsers", true);
  }
  return settingBool("allowOtherApps", true);
}

function trackFingerprint(snapshot) {
  var parts = [
    trimString(snapshot.bundleIdentifier),
    trimString(snapshot.trackIdentifier),
    trimString(snapshot.title).toLowerCase(),
    trimString(snapshot.artist).toLowerCase(),
    trimString(snapshot.album).toLowerCase()
  ];
  return parts.join("||");
}

function computeTrackStartEpochSeconds(snapshot) {
  var capturedAtEpochMs = toNumber(snapshot.capturedAtEpochMs, nowEpochMs());
  var elapsedSeconds = clamp(toNumber(snapshot.elapsedSeconds, 0), 0, 60 * 60 * 24);
  return Math.max(0, Math.floor((capturedAtEpochMs - (elapsedSeconds * 1000)) / 1000));
}

function scrobbleThresholdSeconds(durationSeconds) {
  var duration = toNumber(durationSeconds, 0);
  if (duration <= 30) return Infinity;
  if (duration <= 0) return 240;
  return Math.min(240, Math.floor(duration / 2));
}

function buildSessionFromSnapshot(snapshot) {
  var startedAtEpochSeconds = computeTrackStartEpochSeconds(snapshot);
  var elapsedSeconds = clamp(toNumber(snapshot.elapsedSeconds, 0), 0, 60 * 60 * 24);
  var durationSeconds = toNumber(snapshot.durationSeconds, 0);
  var thresholdSeconds = scrobbleThresholdSeconds(durationSeconds);
  var id = trackFingerprint(snapshot) + "::" + startedAtEpochSeconds;

  return {
    id: id,
    fingerprint: trackFingerprint(snapshot),
    sourceApp: trimString(snapshot.sourceApp),
    bundleIdentifier: trimString(snapshot.bundleIdentifier),
    title: trimString(snapshot.title),
    artist: trimString(snapshot.artist),
    album: trimString(snapshot.album),
    albumArtist: trimString(snapshot.albumArtist),
    durationSeconds: durationSeconds,
    thresholdSeconds: thresholdSeconds,
    startedAtEpochSeconds: startedAtEpochSeconds,
    activePlaySeconds: elapsedSeconds,
    lastSeenElapsedSeconds: elapsedSeconds,
    lastObservedAtEpochMs: toNumber(snapshot.capturedAtEpochMs, nowEpochMs()),
    lastPlaybackState: trimString(snapshot.playbackState) || "paused",
    trackIdentifier: trimString(snapshot.trackIdentifier),
    artworkURL: trimString(snapshot.artworkURL),
    isLocalFile: !!snapshot.isLocalFile,
    nowPlayingSent: false,
    scrobbled: !!state.history[id],
    scrobbledAtSeconds: null
  };
}

function sessionShouldRestart(session, snapshot) {
  if (!session) return true;
  var fingerprint = trackFingerprint(snapshot);
  if (session.fingerprint !== fingerprint) return true;

  var nextElapsed = toNumber(snapshot.elapsedSeconds, -1);
  var previousElapsed = toNumber(session.lastSeenElapsedSeconds, -1);

  if (nextElapsed >= 0 && previousElapsed >= 0) {
    var rewound = nextElapsed + 10 < previousElapsed;
    var restartedNearZero = nextElapsed <= 5;
    var previousTrackMostlyFinished = previousElapsed >= Math.max(30, (session.durationSeconds || 0) * 0.85);
    if (rewound && restartedNearZero && previousTrackMostlyFinished) {
      return true;
    }
  }

  return false;
}

function finalizeSessionIfNeeded(session) {
  if (!session || session.scrobbled) return;
  if (session.thresholdSeconds === Infinity) return;
  if (session.activePlaySeconds >= session.thresholdSeconds) {
    queueScrobble(session);
    session.scrobbled = true;
  }
}

function markHistory(sessionID, status) {
  state.history[sessionID] = {
    status: status,
    atEpochMs: nowEpochMs()
  };

  var keys = Object.keys(state.history).sort(function(a, b) {
    return state.history[b].atEpochMs - state.history[a].atEpochMs;
  });

  while (keys.length > MAX_HISTORY_SIZE) {
    delete state.history[keys.pop()];
  }

  if (state.currentPlayback && state.currentPlayback.id === sessionID && status === "ok") {
    beginTrailingIndicatorTransition("success", "bounce", 900);
  }
}

function queueScrobble(session) {
  if (!session || state.history[session.id]) return;
  var i;
  for (i = 0; i < state.queue.length; i += 1) {
    if (state.queue[i].sessionID === session.id) {
      return;
    }
  }

  state.queue.push({
    sessionID: session.id,
    title: session.title,
    artist: session.artist,
    album: session.album,
    albumArtist: session.albumArtist,
    durationSeconds: session.durationSeconds,
    sourceApp: session.sourceApp,
    startedAtEpochSeconds: session.startedAtEpochSeconds,
    attempts: 0,
    queuedAtEpochMs: nowEpochMs()
  });

  if (state.queue.length > MAX_QUEUE_SIZE) {
    state.queue = state.queue.slice(state.queue.length - MAX_QUEUE_SIZE);
  }

  session.scrobbledAtSeconds = Math.max(0, Math.floor(toNumber(session.activePlaySeconds, session.thresholdSeconds)));
  state.lastResult = "Queued " + session.title + " for scrobbling";
  persistState();
}

async function startAuthFlow() {
  saveCredentialDrafts();
  if (!credentialsConfigured()) {
    markError("Add your Last.fm API key and secret in the extension UI or Settings before authorizing.");
    return;
  }

  clearError();
  var data = await lastFmRequest("auth.getToken", {}, { method: "GET", signed: false });
  if (!data || !data.token) {
    markError(data && data.message ? data.message : "Unable to request a Last.fm token.");
    state.auth.status = "error";
    persistState();
    return;
  }

  state.auth.pendingToken = data.token;
  state.auth.pendingAtEpochMs = nowEpochMs();
  state.auth.lastAuthError = "";
  state.auth.status = "pending";
  state.lastResult = "Approve SuperIsland in Last.fm, then wait a few seconds.";
  persistState();

  SuperIsland.openURL(LASTFM_AUTH_ROOT + "?api_key=" + encodeURIComponent(configuredApiKey()) + "&token=" + encodeURIComponent(data.token));
}

function clearAuthState() {
  state.auth.sessionKey = "";
  state.auth.username = "";
  state.auth.pendingToken = "";
  state.auth.pendingAtEpochMs = 0;
  state.auth.lastAuthError = "";
  state.auth.status = "disconnected";
}

function saveCredentialDrafts() {
  var key = draftApiKey();
  var secret = draftApiSecret();

  if (key) storeSet("apiKey", key);
  if (secret) storeSet("apiSecret", secret);
}

function onboardingReady() {
  return trimString(draftApiKey()) && trimString(draftApiSecret());
}

function revealIslandForSetup() {
  // Double-activate to survive the notch's initial settle animation.
  SuperIsland.island.activate(false);
  setTimeout(function() {
    SuperIsland.island.activate(false);
  }, 120);
}

async function pollPendingAuth() {
  if (!state.auth.pendingToken) return;
  var ageSeconds = (nowEpochMs() - toNumber(state.auth.pendingAtEpochMs, 0)) / 1000;
  if (ageSeconds > AUTH_POLL_WINDOW_SECONDS) {
    state.auth.pendingToken = "";
    state.auth.pendingAtEpochMs = 0;
    state.auth.status = "disconnected";
    state.auth.lastAuthError = "Authorization timed out. Start the login flow again.";
    persistState();
    return;
  }

  var data = await lastFmRequest("auth.getSession", { token: state.auth.pendingToken }, { method: "POST", signed: true });
  if (data && data.session && data.session.key) {
    state.auth.sessionKey = data.session.key;
    state.auth.username = trimString(data.session.name);
    state.auth.pendingToken = "";
    state.auth.pendingAtEpochMs = 0;
    state.auth.lastAuthError = "";
    state.auth.status = "connected";
    state.lastResult = "Connected to Last.fm as " + state.auth.username;
    clearError();
    persistState();
    maybeNotify("Last.fm connected", "Signed in as " + state.auth.username + ".");
    return;
  }

  if (data && data.message) {
    state.auth.status = "pending";
    state.auth.lastAuthError = trimString(data.message);
    persistState();
  }
}

function authConnected() {
  return !!trimString(state.auth.sessionKey);
}

async function sendNowPlayingUpdate(session) {
  if (!authConnected()) return;
  if (!sendNowPlayingEnabled()) return;
  if (!session || session.nowPlayingSent) return;
  if (!session.title || !session.artist) return;
  if (!isFinite(session.thresholdSeconds) && session.durationSeconds <= 30) return;

  var params = {
    sk: state.auth.sessionKey,
    track: session.title,
    artist: session.artist
  };

  if (session.album) params.album = session.album;
  if (session.albumArtist) params.albumArtist = session.albumArtist;
  if (session.durationSeconds > 0) params.duration = Math.floor(session.durationSeconds);

  var data = await lastFmRequest("track.updateNowPlaying", params, { method: "POST", signed: true });
  if (data && !data.error) {
    session.nowPlayingSent = true;
    state.auth.status = "connected";
    state.auth.lastAuthError = "";
    clearError();
    state.lastResult = "Now playing: " + session.title;
    persistState();
    return;
  }

  if (data && data.message) {
    state.auth.lastAuthError = trimString(data.message);
    if (data.error === 9) {
      clearAuthState();
    } else {
      state.auth.status = "error";
    }
    markError("Last.fm now playing failed: " + data.message);
  }
}

function mapScrobbleStatuses(data, count) {
  var statuses = [];
  var i;
  for (i = 0; i < count; i += 1) statuses.push("retry");

  if (!data || data.error) return statuses;
  if (!data.scrobbles || !data.scrobbles.scrobble) {
    for (i = 0; i < count; i += 1) statuses[i] = "ok";
    return statuses;
  }

  var scrobbles = Array.isArray(data.scrobbles.scrobble) ? data.scrobbles.scrobble : [data.scrobbles.scrobble];
  for (i = 0; i < scrobbles.length && i < count; i += 1) {
    var ignored = scrobbles[i].ignoredMessage && scrobbles[i].ignoredMessage.code !== "0";
    statuses[i] = ignored ? "ignored" : "ok";
  }
  return statuses;
}

async function flushQueue(force) {
  if (!state.queue.length) return;
  if (!authConnected()) return;
  if (!settingBool("enabled", true) && !force) return;

  var batch = state.queue.slice(0, MAX_BATCH_SIZE);
  var params = { sk: state.auth.sessionKey };
  var i;
  for (i = 0; i < batch.length; i += 1) {
    params["timestamp[" + i + "]"] = batch[i].startedAtEpochSeconds;
    params["track[" + i + "]"] = batch[i].title;
    params["artist[" + i + "]"] = batch[i].artist;
    if (batch[i].album) params["album[" + i + "]"] = batch[i].album;
    if (batch[i].albumArtist) params["albumArtist[" + i + "]"] = batch[i].albumArtist;
  }

  var data = await lastFmRequest("track.scrobble", params, { method: "POST", signed: true });
  if (data && data.error) {
    if (data.error === 9) {
      clearAuthState();
      markError("Last.fm session expired. Sign in again.");
      persistState();
      return;
    }

    for (i = 0; i < batch.length; i += 1) {
      batch[i].attempts += 1;
    }
    state.queue = batch.concat(state.queue.slice(batch.length));
    markError("Failed to flush scrobble queue: " + (data.message || "unknown error"));
    persistState();
    return;
  }

  var statuses = mapScrobbleStatuses(data, batch.length);
  state.auth.status = "connected";
  state.auth.lastAuthError = "";
  clearError();
  for (i = 0; i < batch.length; i += 1) {
    if (statuses[i] === "ok" || statuses[i] === "ignored") {
      markHistory(batch[i].sessionID, statuses[i]);
    } else {
      batch[i].attempts += 1;
    }
  }

  var remaining = [];
  for (i = 0; i < batch.length; i += 1) {
    if (statuses[i] !== "ok" && statuses[i] !== "ignored" && batch[i].attempts < 6) {
      remaining.push(batch[i]);
    }
  }
  state.queue = remaining.concat(state.queue.slice(batch.length));
  state.lastResult = batch.length === 1 ? "Scrobbled " + batch[0].title : "Flushed " + batch.length + " queued scrobbles";
  clearError();
  persistState();
}

function validSnapshot(snapshot) {
  return snapshot &&
    trimString(snapshot.title) &&
    trimString(snapshot.artist) &&
    sourceAllowed(snapshot);
}

function updatePlaybackFromSnapshot(snapshot) {
  var session = state.currentPlayback;
  if (!validSnapshot(snapshot)) {
    if (session) {
      session.lastPlaybackState = snapshot && snapshot.playbackState ? trimString(snapshot.playbackState) : "paused";
      state.currentPlayback = session;
      persistState();
    }
    return;
  }

  if (sessionShouldRestart(session, snapshot)) {
    finalizeSessionIfNeeded(session);
    session = buildSessionFromSnapshot(snapshot);
    beginTrailingIndicatorTransition("progress", "spin", 900);
  }

  var currentEpochMs = toNumber(snapshot.capturedAtEpochMs, nowEpochMs());
  var previousObservedAtEpochMs = toNumber(session.lastObservedAtEpochMs, currentEpochMs);
  var deltaSeconds = clamp((currentEpochMs - previousObservedAtEpochMs) / 1000, 0, 5);
  var nextPlaybackState = trimString(snapshot.playbackState) || "paused";
  var nextElapsedSeconds = clamp(toNumber(snapshot.elapsedSeconds, session.lastSeenElapsedSeconds), 0, 60 * 60 * 24);

  if (session.lastPlaybackState === "playing" && nextPlaybackState === "playing") {
    var elapsedDelta = nextElapsedSeconds - toNumber(session.lastSeenElapsedSeconds, nextElapsedSeconds);
    if (elapsedDelta >= 0 && elapsedDelta <= 5) {
      deltaSeconds = elapsedDelta;
    }
    session.activePlaySeconds += deltaSeconds;
  }

  session.sourceApp = trimString(snapshot.sourceApp);
  session.bundleIdentifier = trimString(snapshot.bundleIdentifier);
  session.title = trimString(snapshot.title);
  session.artist = trimString(snapshot.artist);
  session.album = trimString(snapshot.album);
  session.albumArtist = trimString(snapshot.albumArtist);
  session.durationSeconds = toNumber(snapshot.durationSeconds, session.durationSeconds);
  session.thresholdSeconds = scrobbleThresholdSeconds(session.durationSeconds);
  session.lastSeenElapsedSeconds = nextElapsedSeconds;
  session.lastObservedAtEpochMs = currentEpochMs;
  session.lastPlaybackState = nextPlaybackState;
  session.trackIdentifier = trimString(snapshot.trackIdentifier);
  session.artworkURL = trimString(snapshot.artworkURL);
  session.isLocalFile = !!snapshot.isLocalFile;

  if (!session.scrobbled && session.thresholdSeconds !== Infinity && session.activePlaySeconds >= session.thresholdSeconds) {
    queueScrobble(session);
    session.scrobbled = true;
    beginTrailingIndicatorTransition("success", "bounce", 1100);
  }

  state.currentPlayback = session;
  persistState();
}

function compactStatusLabel() {
  if (!credentialsConfigured()) return "keys";
  if (state.auth.pendingToken) return "auth";
  if (!effectiveEnabled()) return "off";
  if (!authConnected()) return "login";
  if (state.currentPlayback && (state.currentPlayback.scrobbled || state.history[state.currentPlayback.id])) return "done";
  if (state.queue.length) return String(state.queue.length) + "q";
  return "live";
}

function connectionLabel() {
  if (!credentialsConfigured()) return "Missing API keys";
  if (state.auth.pendingToken) return "Awaiting Last.fm approval";
  if (authConnected()) return "Connected as " + (state.auth.username || "Last.fm user");
  return "Not connected";
}

function currentSourceLabel() {
  if (!hasMediaBridge()) return "Host app update needed";
  var snapshot = state.lastSnapshot;
  if (!snapshot) return "No active track";
  return trimString(snapshot.sourceApp) || "Unknown source";
}

function currentTrackTitle() {
  if (!hasMediaBridge()) return "Media bridge unavailable";
  var snapshot = state.lastSnapshot;
  if (!snapshot) return "Nothing playing";
  return trimString(snapshot.title) || "Nothing playing";
}

function currentTrackSubtitle() {
  if (!hasMediaBridge()) {
    return "This installed SuperIsland build cannot expose now-playing metadata to extensions yet.";
  }
  var snapshot = state.lastSnapshot;
  if (!snapshot) return "Start playback to create a scrobble session.";
  var artist = trimString(snapshot.artist);
  var album = trimString(snapshot.album);
  var title = trimString(snapshot.title).toLowerCase();
  if (album && title && album.toLowerCase() === title) {
    album = "";
  }
  if (artist && album) return artist + " • " + album;
  if (artist) return artist;
  if (album) return album;
  return currentSourceLabel();
}

function currentSourceBadgeLabel() {
  var source = currentSourceLabel();
  if (source === "No active track") return "Ready";
  if (source === "Host app update needed") return "Needs update";
  return source;
}

function onboardingView() {
  return View.scroll(
    View.vstack([
      statusSummaryCard(),
      card(
        View.vstack([
          View.text("Step 1", {
            style: "caption",
            color: mutedTextColor(),
            lineLimit: 1
          }),
          View.text("Open Last.fm and create or find your API app.", {
            style: "headline",
            color: "white",
            lineLimit: 2
          }),
          View.hstack([
            chipButton("Create app", "openApiCreate", { icon: "plus.square.fill", fullWidth: true, style: "caption", padding: 7 }),
            chipButton("Manage keys", "openApiAccounts", { icon: "key.fill", fullWidth: true, style: "caption", padding: 7 }),
            chipButton("Auth docs", "openDesktopAuthDocs", { icon: "book.closed.fill", fullWidth: true, style: "caption", padding: 7 })
          ], { spacing: 8, distribution: "fillEqually", align: "center" })
        ], { spacing: 8, align: "leading" }),
        { padding: 12 }
      ),
      lastFmFormHintsCard(),
      onboardingField(
        "Step 2 · API key",
        "Paste Last.fm API key and press Enter",
        draftApiKey(),
        "setApiKey",
        "lastfm-api-key",
        {
          autoFocus: true,
          help: "Copy the API key from your Last.fm API account page."
        }
      ),
      onboardingField(
        "Step 3 · API secret",
        "Paste Last.fm API secret and press Enter",
        draftApiSecret(),
        "setApiSecret",
        "lastfm-api-secret",
        {
          autoFocus: false,
          help: "Copy the shared secret that appears next to the API key."
        }
      ),
      card(
        View.vstack([
          View.text("Step 4", {
            style: "caption",
            color: mutedTextColor(),
            lineLimit: 1
          }),
          View.text("Save locally, then approve the scrobbler in Last.fm.", {
            style: "headline",
            color: "white",
            lineLimit: 2
          }),
          View.hstack([
            chipButton("Save credentials", "saveCredentials", {
              icon: "square.and.arrow.down.fill",
              fullWidth: true
            }),
            chipButton(onboardingReady() ? "Connect to Last.fm" : "Connect after saving", "auth", {
              icon: "link.circle.fill",
              fullWidth: true,
              fillColor: onboardingReady() ? { r: 0.84, g: 0.06, b: 0.03, a: 0.92 } : { r: 1, g: 1, b: 1, a: 0.08 }
            })
          ], { spacing: 8, distribution: "fillEqually", align: "center" }),
          state.lastResult
            ? View.text(state.lastResult, {
                style: "footnote",
                color: secondaryTextColor(),
                lineLimit: 2
              })
            : null
        ].filter(Boolean), { spacing: 8, align: "leading" }),
        { padding: 12, backgroundColor: elevatedPanelColor() }
      ),
      bridgeWarningNode(),
      feedbackCard()
    ].filter(Boolean), { spacing: 12, align: "leading" }),
    { axes: "vertical", showsIndicators: false }
  );
}

function compactView() {
  var idleBadge = !state.lastSnapshot || currentSourceLabel() === "No active track";
  return View.hstack([
    lastFmIconNode(18, 5),
    View.text(compactStatusLabel().toUpperCase(), { style: "caption", color: "white" }),
    idleBadge
      ? View.frame(lastFmIconNode(12, 4), {
          width: 16,
          height: 16,
          alignment: "trailing"
        })
      : View.text(authConnected() ? currentSourceBadgeLabel() : "Last.fm", {
          style: "footnote",
          color: { r: 1, g: 1, b: 1, a: 0.55 },
          lineLimit: 1
        })
  ], { spacing: 7, align: "center" });
}

function minimalCompactLeadingView() {
  return View.frame(lastFmIconNode(17, 4), {
    width: 18,
    height: 18,
    alignment: "leading"
  });
}

function minimalCompactTrailingView() {
  if (trailingIndicatorMode() === "success") {
    return View.frame(decorateTrailingIndicator(
      View.icon("checkmark.circle.fill", {
        size: 14,
        color: successTextColor()
      })
    ), {
      width: 18,
      height: 18,
      alignment: "trailing"
    });
  }

  return View.frame(decorateTrailingIndicator(
    View.circularProgress(scrobbleProgressValue(state.currentPlayback), {
      total: 1,
      lineWidth: 2,
      color: state.lastError ? dangerTextColor() : (state.queue.length ? warningTextColor() : secondaryTextColor())
    })
  ),
    {
      width: 18,
      height: 18,
      alignment: "trailing"
    }
  );
}

function expandedView() {
  if (!credentialsConfigured() || !authConnected()) {
    return setupStatusCard();
  }

  return scrobblerPlayerCard("compact");
}

function fullExpandedView() {
  if (!credentialsConfigured() || !authConnected()) {
    return setupStatusCard();
  }

  if (!hasMediaBridge()) {
    return card(
      View.vstack([
        View.text("Last.fm connected", { style: "title", color: "white", lineLimit: 1 }),
        View.text(connectionLabel(), { style: "subtitle", color: secondaryTextColor(), lineLimit: 2 }),
        View.text("The installed SuperIsland app still needs the media bridge build, so playback cannot be captured yet.", {
          style: "footnote",
          color: warningTextColor(),
          lineLimit: 3
        })
      ], { spacing: 6, align: "leading" }),
      { padding: 12, backgroundColor: elevatedPanelColor() }
    );
  }

  // Settings stay in SuperIsland Settings > Extensions > Last.fm Scrobbler.
  // settingsCard()
  return scrobblerPlayerCard("full");
}

async function tick() {
  if (state.auth.pendingToken) {
    await pollPendingAuth();
  }

  var snapshot = asObject(hasMediaBridge() ? SuperIsland.system.getNowPlaying() : null);
  state.lastSnapshot = snapshot;

  if (!effectiveEnabled()) {
    persistState();
    return;
  }

  updatePlaybackFromSnapshot(snapshot);

  if (state.currentPlayback) {
    await sendNowPlayingUpdate(state.currentPlayback);
  }

  await flushQueue(false);
  persistState();
}

function startPolling() {
  if (pollTimer !== null) return;
  void tick();
  pollTimer = setInterval(function() {
    void tick();
  }, 1000);
}

function stopPolling() {
  if (pollTimer !== null) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
}

function signOut() {
  clearAuthState();
  state.lastResult = "Signed out of Last.fm";
  clearError();
  persistState();
}

function toggleEnabled(forceValue) {
  var nextValue = typeof forceValue === "boolean" ? forceValue : !effectiveEnabled();
  SuperIsland.store.set("enabledOverride", nextValue);
  state.lastResult = nextValue ? "Auto scrobbling enabled" : "Auto scrobbling paused";
  persistState();
}

function toggleSendNowPlaying(forceValue) {
  var nextValue = typeof forceValue === "boolean" ? forceValue : !sendNowPlayingEnabled();
  SuperIsland.store.set("sendNowPlayingOverride", nextValue);
  state.lastResult = nextValue ? "Now playing updates enabled" : "Now playing updates paused";
  persistState();
}

loadState();

SuperIsland.registerModule({
  onActivate: function() {
    startPolling();
    if (!credentialsConfigured() || !authConnected() || state.auth.pendingToken) {
      revealIslandForSetup();
    }
  },

  onDeactivate: function() {
    stopPolling();
  },

  onSettingsChanged: function() {
    clearError();
    void tick();
  },

  onAction: function(actionID, value) {
    if (actionID === "openApiCreate") {
      SuperIsland.openURL(LASTFM_API_CREATE_URL);
      return;
    }
    if (actionID === "openApiAccounts") {
      SuperIsland.openURL(LASTFM_API_ACCOUNTS_URL);
      return;
    }
    if (actionID === "openDesktopAuthDocs") {
      SuperIsland.openURL(LASTFM_DESKTOP_AUTH_DOCS_URL);
      return;
    }
    if (actionID === "setApiKey") {
      if (value !== undefined && value !== null) {
        storeSet("apiKeyDraft", trimString(value));
        state.lastResult = "API key captured";
        persistState();
      }
      return;
    }
    if (actionID === "setApiSecret") {
      if (value !== undefined && value !== null) {
        storeSet("apiSecretDraft", trimString(value));
        state.lastResult = "API secret captured";
        persistState();
      }
      return;
    }
    if (actionID === "saveCredentials") {
      saveCredentialDrafts();
      state.lastResult = onboardingReady() ? "Credentials saved locally" : "Paste both the key and secret first";
      persistState();
      revealIslandForSetup();
      return;
    }
    if (actionID === "auth") {
      revealIslandForSetup();
      void startAuthFlow();
      return;
    }
    if (actionID === "retryQueue") {
      void flushQueue(true);
      return;
    }
    if (actionID === "signOut") {
      signOut();
      return;
    }
    if (actionID === "dismissError") {
      clearError();
      state.lastResult = "Status cleared";
      persistState();
      return;
    }
    if (actionID === "toggleEnabled") {
      toggleEnabled(typeof value === "boolean" ? value : undefined);
      return;
    }
    if (actionID === "toggleSendNowPlaying") {
      toggleSendNowPlaying(typeof value === "boolean" ? value : undefined);
      return;
    }
  },

  compact: function() {
    return compactView();
  },

  minimalCompact: {
    leading: function() {
      return minimalCompactLeadingView();
    },
    trailing: function() {
      return minimalCompactTrailingView();
    },
    precedence: function() {
      return 1;
    }
  },

  expanded: function() {
    return expandedView();
  },

  fullExpanded: function() {
    return fullExpandedView();
  }
});

startPolling();
