"use strict";

var LASTFM_API_ROOT = "https://ws.audioscrobbler.com/2.0/";
var LASTFM_AUTHORIZE_URL = "https://api.supercmd.sh/auth/lastfm/authorize?app=superisland";
// Last.fm API key for the SuperCMD-registered app. Public per Last.fm's auth flow
// (Last.fm exposes it in the auth redirect URL). Used as a fallback when the
// OAuth callback doesn't carry an apiKey of its own.
var LASTFM_DEFAULT_API_KEY = "d7f31db0cf7868f348a7fb411a91b6c4";
var MAX_BATCH_SIZE = 50;
var MAX_QUEUE_SIZE = 200;
var MAX_HISTORY_SIZE = 300;
var NOTIFICATION_COOLDOWN_SECONDS = 45;
var BACKOFF_BASE_MS = 5000;
var BACKOFF_MAX_MS = 300000;
var ERROR_LOG_DEDUPE_WINDOW_MS = 30000;
var LASTFM_ICON_DATA_URL = "data:image/svg+xml;utf8,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32' fill='none'%3E%3Cpath fill='%23D51007' d='M14.23 22.512l-1.1-2.99c-1.137 1.176-2.708 1.926-4.454 1.992l-.012 0c-2.371 0-4.055-2.061-4.055-5.36 0-4.227 2.13-5.739 4.226-5.739 3.025 0 3.986 1.959 4.811 4.468l1.1 3.436c1.1 3.332 3.161 6.012 9.106 6.012 4.261 0 7.148-1.305 7.148-4.741 0-2.784-1.581-4.226-4.538-4.914l-2.197-.481c-1.512-.344-1.959-.963-1.959-1.994 0-1.168.927-1.855 2.44-1.855 1.65 0 2.543.619 2.68 2.096l3.436-.412c-.275-3.092-2.405-4.365-5.911-4.365-3.093 0-6.116 1.169-6.116 4.915 0 2.338 1.134 3.814 3.986 4.501l2.337.55c1.753.413 2.336 1.134 2.336 2.13 0 1.271-1.238 1.788-3.575 1.788-.12.009-.26.015-.401.015-2.619 0-4.806-1.847-5.33-4.309l-.006-.036-1.134-3.438c-1.444-4.466-3.746-6.116-8.316-6.116-5.053 0-7.732 3.196-7.732 8.625 0 5.225 2.68 8.043 7.491 8.043.145.009.314.014.485.014 1.994 0 3.826-.692 5.27-1.848l-.017.013z'/%3E%3C/svg%3E";

var state = {
  auth: {
    username: "",
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
var persistedStateSignature = "";
var runtimeState = {
  tickInFlight: false,
  operations: {
    nowPlaying: { inFlight: false, failureCount: 0, nextAllowedAtEpochMs: 0, lastLoggedMessage: "", lastLoggedAtEpochMs: 0 },
    queue: { inFlight: false, failureCount: 0, nextAllowedAtEpochMs: 0, lastLoggedMessage: "", lastLoggedAtEpochMs: 0 }
  }
};

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

function logInfo(message) {
  if (typeof console !== "undefined" && console && typeof console.log === "function") {
    console.log("[lastfm] " + trimString(message));
  }
}

function logWarning(message) {
  if (typeof console !== "undefined" && console && typeof console.log === "function") {
    console.log("[lastfm] warning: " + trimString(message));
  }
}

function setResult(message, shouldLog) {
  state.lastResult = trimString(message);
  if (shouldLog !== false && state.lastResult) {
    logInfo(state.lastResult);
  }
  persistState();
}

function syncSettingFlag(key, nextValue) {
  var currentValue = SuperIsland.settings.get(key);
  if (typeof currentValue === "boolean" && currentValue === nextValue) return;
  SuperIsland.settings.set(key, nextValue);
}

function syncButtonAvailability() {
  syncSettingFlag("uiCanConnect", !authConnected());
  syncSettingFlag("uiCanDisconnect", authConnected());
  syncSettingFlag("uiCanRetryQueue", authConnected() && state.queue.length > 0);
}

function operationState(name) {
  return runtimeState.operations[name];
}

function shouldThrottleLog(operationName, message) {
  var op = operationState(operationName);
  var normalizedMessage = trimString(message);
  var now = nowEpochMs();
  return op.lastLoggedMessage === normalizedMessage && normalizedMessage && (now - op.lastLoggedAtEpochMs) < ERROR_LOG_DEDUPE_WINDOW_MS;
}

function noteOperationLog(operationName, message) {
  var op = operationState(operationName);
  op.lastLoggedMessage = trimString(message);
  op.lastLoggedAtEpochMs = nowEpochMs();
}

function backoffDelayMs(failureCount) {
  var exponent = Math.max(0, Math.min(6, toNumber(failureCount, 0) - 1));
  return Math.min(BACKOFF_MAX_MS, BACKOFF_BASE_MS * Math.pow(2, exponent));
}

function scheduleOperationRetry(operationName, delayMs, resetFailureCount) {
  var op = operationState(operationName);
  if (resetFailureCount) {
    op.failureCount = 0;
  } else {
    op.failureCount += 1;
  }
  op.nextAllowedAtEpochMs = nowEpochMs() + Math.max(0, toNumber(delayMs, 0));
}

function clearOperationRetry(operationName) {
  var op = operationState(operationName);
  op.inFlight = false;
  op.failureCount = 0;
  op.nextAllowedAtEpochMs = 0;
  op.lastLoggedMessage = "";
  op.lastLoggedAtEpochMs = 0;
}

function operationReady(operationName, force) {
  var op = operationState(operationName);
  if (op.inFlight) return false;
  if (force) return true;
  return nowEpochMs() >= toNumber(op.nextAllowedAtEpochMs, 0);
}

function formatRetryDelay(ms) {
  var totalSeconds = Math.max(1, Math.ceil(toNumber(ms, 0) / 1000));
  if (totalSeconds < 60) return totalSeconds + "s";
  return Math.ceil(totalSeconds / 60) + "m";
}

function safeLastErrorMessage(payload, fallbackMessage) {
  var code = toNumber(payload && payload.error, 0);
  var message = trimString(payload && payload.message);

  if (!message && payload && typeof payload.error === "string") {
    message = trimString(payload.error);
  }
  if (!message) {
    message = trimString(fallbackMessage) || "Unknown Last.fm error.";
  }

  return {
    code: code || 0,
    message: message,
    retryable: [4, 9, 10, 13, 14, 15, 26].indexOf(code) === -1
  };
}

function logOperationWarning(operationName, message) {
  if (shouldThrottleLog(operationName, message)) return;
  logWarning(message);
  noteOperationLog(operationName, message);
}

function sanitizedPlaybackForStorage(session) {
  var key;
  var sanitized;
  if (!session) return null;
  sanitized = {};
  for (key in session) {
    if (Object.prototype.hasOwnProperty.call(session, key) && key !== "artworkURL") {
      sanitized[key] = session[key];
    }
  }
  if (trimString(session.artworkURL) && trimString(session.artworkURL).indexOf("data:image/") !== 0) {
    sanitized.artworkURL = trimString(session.artworkURL);
  }
  return sanitized;
}

function persistedStatePayload() {
  return {
    auth: state.auth,
    queue: state.queue,
    history: state.history,
    currentPlayback: sanitizedPlaybackForStorage(state.currentPlayback),
    lastResult: state.lastResult,
    lastError: state.lastError
  };
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

function readOAuthSession() {
  var oauth = asObject(storeGet("oauth", null));
  if (!oauth) return null;

  var accessToken = trimString(oauth.accessToken || oauth.access_token);
  if (!accessToken) return null;

  var tokenType = trimString(oauth.tokenType || oauth.token_type) || "Bearer";
  var scope = trimString(oauth.scope);
  var receivedAt = toNumber(oauth.receivedAt, 0);
  var expiresIn = toNumber(oauth.expiresIn, toNumber(oauth.expires_in, 0));
  var username = trimString(oauth.username || oauth.name);
  // Last.fm signing requires the api_key/api_secret of the app the OAuth flow
  // ran under. The supercmd callback forwards both alongside the session key.
  var apiKey = trimString(oauth.apiKey || oauth.api_key) || LASTFM_DEFAULT_API_KEY;
  var apiSecret = trimString(oauth.apiSecret || oauth.api_secret);

  return {
    accessToken: accessToken,
    tokenType: tokenType,
    scope: scope,
    receivedAt: receivedAt,
    expiresIn: expiresIn,
    username: username,
    apiKey: apiKey,
    apiSecret: apiSecret
  };
}

function oauthSessionState() {
  var session = readOAuthSession();
  if (!session) {
    return { connected: false, expired: false, session: null };
  }
  var expiresAt = session.receivedAt > 0 && session.expiresIn > 0
    ? session.receivedAt + session.expiresIn
    : 0;
  var expired = expiresAt > 0 ? nowEpochSeconds() >= expiresAt - 60 : false;
  return { connected: !expired, expired: expired, session: session };
}

function configuredAccessToken() {
  var oauth = oauthSessionState();
  return oauth.connected && oauth.session ? oauth.session.accessToken : "";
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

function lastFmStatusPill(summary) {
  var label = summary.label;
  if (label === "Scrobbled") label = "Sent";
  if (label === "Tracking") label = "Tracking";
  return statusPill(label, summary.tone, {
    leadingNode: lastFmBadgeNode(10, summary.tone),
    padding: 8
  });
}

function overflowTrackText(value, style, color) {
  return View.marqueeText(value, {
    style: style,
    color: color
  });
}

function encodeLastFmPathSegment(value) {
  return encodeURIComponent(trimString(value));
}

function lastFmArtistURL() {
  var artist = trimString(state.currentPlayback && state.currentPlayback.artist) || trimString(state.lastSnapshot && state.lastSnapshot.artist);
  if (!artist) return "";
  return "https://www.last.fm/music/" + encodeLastFmPathSegment(artist);
}

function lastFmAlbumURL() {
  var artist = trimString(state.currentPlayback && state.currentPlayback.artist) || trimString(state.lastSnapshot && state.lastSnapshot.artist);
  var album = trimString(state.currentPlayback && state.currentPlayback.album) || trimString(state.lastSnapshot && state.lastSnapshot.album);
  if (!artist || !album) return "";
  return "https://www.last.fm/music/" + encodeLastFmPathSegment(artist) + "/" + encodeLastFmPathSegment(album);
}

function lastFmTrackURL() {
  var artist = trimString(state.currentPlayback && state.currentPlayback.artist) || trimString(state.lastSnapshot && state.lastSnapshot.artist);
  var track = trimString(state.currentPlayback && state.currentPlayback.title) || trimString(state.lastSnapshot && state.lastSnapshot.title);
  if (!artist || !track) return "";
  return "https://www.last.fm/music/" + encodeLastFmPathSegment(artist) + "/_/" + encodeLastFmPathSegment(track);
}

function lastFmProfileURL() {
  var username = trimString(state.auth && state.auth.username);
  if (!username) return "";
  return "https://www.last.fm/user/" + encodeLastFmPathSegment(username);
}

function linkedTextLine(textNode, actionID) {
  if (!actionID) return textNode;
  return View.button(
    View.frame(textNode, { maxWidth: 9999, alignment: "leading" }),
    actionID
  );
}

function linkedNode(node, actionID) {
  if (!actionID) return node;
  return View.button(node, actionID);
}

function profileStatusButton(summary, session) {
  if (!authConnected()) return lastFmStatusPill(summary);
  var label = summary.label === "Scrobbled"
    ? "Sent • Open profile"
    : (summary.label === "Tracking"
      ? ("Tracking • " + summaryHeadline(summary, session))
      : (summary.label + " • " + summaryHeadline(summary, session)));

  return View.button(
    View.cornerRadius(
      View.background(
        View.padding(
          View.hstack([
            lastFmBadgeNode(10, summary.tone),
            View.text(label, {
              style: "caption",
              color: summary.tone === "success" ? successTextColor() : "white",
              lineLimit: 1
            }),
            View.spacer(),
            View.icon("arrow.up.forward.square", {
              size: 10,
              color: summary.tone === "success" ? successTextColor() : secondaryTextColor()
            })
          ], { spacing: 6, align: "center" }),
          { edges: "all", amount: 8 }
        ),
        summary.tone === "success" ? subtleGreenFillColor() : elevatedPanelColor()
      ),
      10
    ),
    "openProfilePage"
  );
}

function summaryHeadline(summary, session) {
  if (!session) return "Waiting for playback";
  if (summary.label === "Scrobbled") return "Sent at " + formatClock(session.scrobbledAtSeconds || session.thresholdSeconds);
  if (summary.label === "Paused") return "Paused at " + formatClock(session.activePlaySeconds);
  if (summary.label === "Tracking") return "Scrobbles in " + formatClock(Math.max(0, session.thresholdSeconds - session.activePlaySeconds));
  return summary.detail;
}

function scrobblerPlayerCard(size) {
  var session = state.currentPlayback;
  var summary = trackStatusSummary(session);
  var artworkSize = size === "compact" ? 94 : 106;
  var artworkRadius = size === "compact" ? 16 : 18;
  var playbackProgress = playbackProgressValue(session);
  var barColor = summary.tone === "success" ? successTextColor() : accentColor();
  var albumActionID = lastFmAlbumURL() ? "openAlbumPage" : (lastFmTrackURL() ? "openTrackPage" : "");
  var albumLine = currentTrackAlbum();
  var artistLine = currentTrackArtist();
  var topSection = View.hstack([
    linkedNode(artworkNode(artworkSize, artworkRadius), albumActionID),
    View.frame(
      View.vstack([
        linkedTextLine(
          overflowTrackText(currentTrackTitle(), "title", "white"),
          lastFmTrackURL() ? "openTrackPage" : ""
        ),
        albumLine
          ? linkedTextLine(
              overflowTrackText(albumLine, "subtitle", secondaryTextColor()),
              lastFmAlbumURL() ? "openAlbumPage" : ""
            )
          : null,
        artistLine
          ? linkedTextLine(
              overflowTrackText(artistLine, "subtitle", secondaryTextColor()),
              lastFmArtistURL() ? "openArtistPage" : ""
            )
          : null,
        View.hstack([
          profileStatusButton(summary, session)
        ], { spacing: 8, align: "center" })
      ].filter(Boolean), { spacing: 4, align: "leading" }),
      { maxWidth: 9999, maxHeight: 9999, alignment: "topLeading" }
    )
  ], { spacing: 12, align: "top" });
  var bottomSection = View.padding(
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
      View.progress(playbackProgress, { total: 1, color: barColor })
    ], { spacing: 8, align: "leading" }),
    { edges: "bottom", amount: 10 }
  );

  return View.vstack([
    View.frame(topSection, { maxWidth: 9999, alignment: "topLeading" }),
    View.frame(bottomSection, { maxWidth: 9999, alignment: "bottomLeading" })
  ], { spacing: 8, align: "leading" });
}

function setupStatusCard() {
  var cleanError = trimString(state.lastError.replace("Last.fm now playing failed:", "").replace("Failed to flush scrobble queue:", ""));
  var statusText = cleanError || trimString(state.lastResult);
  var oauth = oauthSessionState();
  var pending = state.auth.status === "pending" && !oauth.connected;
  var title = "Connect Last.fm";
  var subtitle = "Tap Connect to log in with Last.fm in your browser.";

  if (pending) {
    title = "Approve Last.fm access";
    subtitle = "Finish the approval in your browser. SuperIsland will connect automatically.";
  } else if (oauth.expired) {
    title = "Last.fm login expired";
    subtitle = "Reconnect to keep scrobbling.";
  }

  return View.frame(
    View.vstack([
      lastFmBadgeNode(18, cleanError ? "error" : (pending ? "warning" : (oauth.expired ? "warning" : "success"))),
      View.text(title, {
        style: "title",
        color: "white",
        lineLimit: 1
      }),
      View.text(subtitle, {
        style: "footnote",
        color: secondaryTextColor(),
        lineLimit: 2,
        multilineTextAlignment: "center"
      }),
      chipButton(authConnected() ? "Reconnect Last.fm" : "Connect Last.fm", "auth", {
        style: "caption",
        icon: "link.badge.plus",
        textColor: "white",
        fillColor: subtleRedFillColor()
      }),
      View.text(
        "Account: " + (pending
          ? "waiting for approval"
          : (authConnected() ? ("connected as " + (state.auth.username || "Last.fm user")) : "not connected")),
        {
          style: "caption",
          color: authConnected() ? successTextColor() : secondaryTextColor(),
          lineLimit: 1
        }
      ),
      statusText
        ? View.text(statusText, {
            style: "footnote",
            color: cleanError ? dangerTextColor() : secondaryTextColor(),
            lineLimit: 3,
            multilineTextAlignment: "center"
          })
        : View.text("Playback will appear here once the account is connected.", {
            style: "footnote",
            color: mutedTextColor(),
            lineLimit: 2,
            multilineTextAlignment: "center"
          })
    ].filter(Boolean), { spacing: 7, align: "center" }),
    { maxWidth: 9999, alignment: "center" }
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

function signLastFmParams(params, apiSecret) {
  var keys = Object.keys(params).sort();
  var payload = "";
  var i;
  for (i = 0; i < keys.length; i += 1) {
    if (keys[i] === "format") continue;
    payload += keys[i] + params[keys[i]];
  }
  return md5(payload + apiSecret);
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
  var oauth = oauthSessionState();
  if (!oauth.connected || !oauth.session) {
    return {
      error: oauth.expired ? "session_expired" : "not_authenticated",
      message: oauth.expired ? "Last.fm login expired. Connect again." : "Connect Last.fm to scrobble."
    };
  }

  var apiKey = trimString(oauth.session.apiKey);
  if (!apiKey) {
    return {
      error: "missing_api_key",
      message: "Last.fm API key missing from session. Reconnect Last.fm."
    };
  }

  var signed = requestOptions.signed !== false;
  var apiSecret = trimString(oauth.session.apiSecret);
  if (signed && !apiSecret) {
    return {
      error: "missing_api_secret",
      message: "Last.fm signing secret missing from session. Reconnect Last.fm."
    };
  }

  var bodyParams = {};
  var key;
  for (key in params) {
    if (Object.prototype.hasOwnProperty.call(params, key) && params[key] !== null && params[key] !== undefined && params[key] !== "") {
      bodyParams[key] = String(params[key]);
    }
  }
  bodyParams.method = methodName;
  bodyParams.api_key = apiKey;
  if (signed) {
    bodyParams.sk = oauth.session.accessToken;
    bodyParams.api_sig = signLastFmParams(bodyParams, apiSecret);
  }
  bodyParams.format = "json";

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

  try {
    var response = await SuperIsland.http.fetch(url, fetchOptions);
    var parsed = await parseResponse(response);
    var status = response && typeof response.status === "number" ? response.status : 0;
    if (status >= 200 && status < 300) {
      return parsed;
    }
    if (status > 0) {
      logWarning("Last.fm " + methodName + " HTTP " + status + " response: " + JSON.stringify(parsed));
      return {
        error: "http_" + status,
        message: trimString(parsed && (parsed.message || parsed.error)) || "Last.fm API returned HTTP " + status + ".",
        httpStatus: status
      };
    }
    return parsed;
  } catch (error) {
    return {
      error: "network_unavailable",
      message: trimString(error && error.message ? error.message : error) || "Network unavailable"
    };
  }
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
  syncButtonAvailability();
  persistedStateSignature = JSON.stringify(persistedStatePayload());
}

function persistState() {
  var payload = persistedStatePayload();
  var nextSignature = JSON.stringify(payload);
  syncButtonAvailability();
  if (nextSignature === persistedStateSignature) return;
  persistedStateSignature = nextSignature;
  storeSet("auth", payload.auth);
  storeSet("queue", payload.queue);
  storeSet("history", payload.history);
  storeSet("currentPlayback", payload.currentPlayback);
  storeSet("lastResult", payload.lastResult);
  storeSet("lastError", payload.lastError);
}

function markError(message) {
  state.lastError = trimString(message);
  if (state.lastError) {
    logWarning(state.lastError);
  }
  persistState();
  maybeNotify("Last.fm Scrobbler", state.lastError);
}

function markOperationError(operationName, message) {
  state.lastError = trimString(message);
  if (state.lastError) {
    logOperationWarning(operationName, state.lastError);
  }
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
  if (!authConnected()) {
    setResult(
      state.queue.length === 1
        ? "1 song queued for scrobbling until Last.fm is connected."
        : state.queue.length + " songs queued for scrobbling until Last.fm is connected."
    );
    return;
  }

  setResult("Queued " + session.title + " for scrobbling");
}

function startAuthFlow() {
  clearError();
  state.auth.lastAuthError = "";
  state.auth.status = "pending";
  setResult("Approve SuperIsland in your browser to finish connecting Last.fm.");
  SuperIsland.openURL(LASTFM_AUTHORIZE_URL);
}

function clearAuthState() {
  storeSet("oauth", null);
  state.auth.username = "";
  state.auth.lastAuthError = "";
  state.auth.status = "disconnected";
}

function revealIslandForSetup() {
  // Double-activate to survive the notch's initial settle animation.
  SuperIsland.island.activate(false);
  setTimeout(function() {
    SuperIsland.island.activate(false);
  }, 120);
}

function syncAuthFromOAuthStore() {
  var oauth = oauthSessionState();
  if (oauth.connected && oauth.session) {
    var nextUsername = oauth.session.username;
    var wasConnected = state.auth.status === "connected";
    if (nextUsername && state.auth.username !== nextUsername) {
      state.auth.username = nextUsername;
    }
    state.auth.lastAuthError = "";
    state.auth.status = "connected";
    if (!wasConnected) {
      clearError();
      var welcome = state.auth.username
        ? "Connected to Last.fm as " + state.auth.username
        : "Connected to Last.fm.";
      state.lastResult = welcome;
      logInfo(welcome);
      maybeNotify("Last.fm connected", welcome);
      persistState();
    }
    return;
  }

  if (oauth.expired && state.auth.status !== "disconnected") {
    state.auth.lastAuthError = "Last.fm login expired. Connect again.";
    state.auth.status = "disconnected";
    persistState();
    return;
  }

  if (state.auth.status === "connected") {
    state.auth.status = "disconnected";
    persistState();
  }
}

function authConnected() {
  return oauthSessionState().connected;
}

async function sendNowPlayingUpdate(session) {
  if (!authConnected()) return;
  if (!sendNowPlayingEnabled()) return;
  if (!session || session.nowPlayingSent) return;
  if (!session.title || !session.artist) return;
  if (!isFinite(session.thresholdSeconds) && session.durationSeconds <= 30) return;
  if (!operationReady("nowPlaying", false)) return;

  var params = {
    track: session.title,
    artist: session.artist
  };

  if (session.album) params.album = session.album;
  if (session.albumArtist) params.albumArtist = session.albumArtist;
  if (session.durationSeconds > 0) params.duration = Math.floor(session.durationSeconds);

  operationState("nowPlaying").inFlight = true;
  var data = await lastFmRequest("track.updateNowPlaying", params, { method: "POST" });
  operationState("nowPlaying").inFlight = false;
  if (data && !data.error) {
    session.nowPlayingSent = true;
    state.auth.status = "connected";
    state.auth.lastAuthError = "";
    clearError();
    clearOperationRetry("nowPlaying");
    setResult("Now playing: " + session.title);
    return;
  }

  if (data && (data.message || data.error)) {
    var nowPlayingError = safeLastErrorMessage(data, "Unable to update Last.fm now playing.");
    state.auth.lastAuthError = nowPlayingError.message;
    if (nowPlayingError.code === 9) {
      clearAuthState();
    } else {
      state.auth.status = "error";
    }
    scheduleOperationRetry("nowPlaying", nowPlayingError.retryable ? backoffDelayMs(operationState("nowPlaying").failureCount + 1) : BACKOFF_MAX_MS, false);
    markOperationError("nowPlaying", "Last.fm now playing failed: " + nowPlayingError.message);
  }
}

function mapScrobbleStatuses(data, count) {
  var statuses = [];
  var i;
  for (i = 0; i < count; i += 1) statuses.push("retry");

  if (!data || data.error) return statuses;
  if (!data.scrobbles || !data.scrobbles.scrobble) {
    logWarning("Last.fm scrobble response missing scrobbles.scrobble; treating as failure. Body: " + JSON.stringify(data));
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
  if (!state.queue.length) {
    if (force) setResult("Scrobble queue is already clear.");
    return;
  }
  if (!authConnected()) {
    if (force) setResult("Connect Last.fm before retrying queued scrobbles.");
    return;
  }
  if (!settingBool("enabled", true) && !force) return;
  if (!operationReady("queue", force)) return;

  var batch = state.queue.slice(0, MAX_BATCH_SIZE);
  if (force) {
    setResult("Retrying " + batch.length + (batch.length === 1 ? " queued scrobble..." : " queued scrobbles..."));
  }
  var params = {};
  var i;
  for (i = 0; i < batch.length; i += 1) {
    params["timestamp[" + i + "]"] = batch[i].startedAtEpochSeconds;
    params["track[" + i + "]"] = batch[i].title;
    params["artist[" + i + "]"] = batch[i].artist;
    if (batch[i].album) params["album[" + i + "]"] = batch[i].album;
    if (batch[i].albumArtist) params["albumArtist[" + i + "]"] = batch[i].albumArtist;
  }

  operationState("queue").inFlight = true;
  var data = await lastFmRequest("track.scrobble", params, { method: "POST" });
  operationState("queue").inFlight = false;
  if (data && data.error) {
    var queueError = safeLastErrorMessage(data, "Unable to reach Last.fm.");
    if (queueError.code === 9) {
      clearAuthState();
      clearOperationRetry("queue");
      markOperationError("queue", "Last.fm session expired. Sign in again.");
      persistState();
      return;
    }

    for (i = 0; i < batch.length; i += 1) {
      batch[i].attempts += 1;
    }
    state.queue = batch.concat(state.queue.slice(batch.length));
    scheduleOperationRetry("queue", queueError.retryable ? backoffDelayMs(operationState("queue").failureCount + 1) : BACKOFF_MAX_MS, false);
    markOperationError("queue", "Failed to flush scrobble queue: " + queueError.message);
    if (!force && queueError.retryable) {
      setResult(
        state.queue.length === 1
          ? "1 queued scrobble will retry in " + formatRetryDelay(operationState("queue").nextAllowedAtEpochMs - nowEpochMs()) + "."
          : state.queue.length + " queued scrobbles will retry in " + formatRetryDelay(operationState("queue").nextAllowedAtEpochMs - nowEpochMs()) + "."
      , false);
    }
    persistState();
    return;
  }

  var statuses = mapScrobbleStatuses(data, batch.length);
  state.auth.status = "connected";
  state.auth.lastAuthError = "";
  clearError();
  clearOperationRetry("queue");
  for (i = 0; i < batch.length; i += 1) {
    if (statuses[i] === "ok" || statuses[i] === "ignored") {
      markHistory(batch[i].sessionID, statuses[i]);
    } else {
      batch[i].attempts += 1;
    }
  }

  var remaining = [];
  for (i = 0; i < batch.length; i += 1) {
    if (statuses[i] !== "ok" && statuses[i] !== "ignored") {
      remaining.push(batch[i]);
    }
  }
  state.queue = remaining.concat(state.queue.slice(batch.length));
  state.lastResult = batch.length === 1 ? "Scrobbled " + batch[0].title : "Flushed " + batch.length + " queued scrobbles";
  logInfo(state.lastResult);
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
  if (state.auth.status === "pending" && !authConnected()) return "auth";
  if (!effectiveEnabled()) return "off";
  if (!authConnected()) return "login";
  if (state.currentPlayback && (state.currentPlayback.scrobbled || state.history[state.currentPlayback.id])) return "done";
  if (state.queue.length) return String(state.queue.length) + "q";
  return "live";
}

function connectionLabel() {
  if (state.auth.status === "pending" && !authConnected()) return "Awaiting Last.fm approval";
  if (authConnected()) return "Connected as " + (state.auth.username || "Last.fm user");
  if (oauthSessionState().expired) return "Last.fm login expired";
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

function currentTrackAlbum() {
  if (!hasMediaBridge()) return "";
  var snapshot = state.lastSnapshot;
  if (!snapshot) return "";
  var album = trimString(snapshot.album);
  var title = trimString(snapshot.title).toLowerCase();
  if (album && title && album.toLowerCase() === title) {
    return "";
  }
  return album;
}

function currentTrackArtist() {
  if (!hasMediaBridge()) return "";
  var snapshot = state.lastSnapshot;
  if (!snapshot) return "";
  return trimString(snapshot.artist) || currentSourceLabel();
}

function currentSourceBadgeLabel() {
  var source = currentSourceLabel();
  if (source === "No active track") return "Ready";
  if (source === "Host app update needed") return "Needs update";
  return source;
}

function mediaBridgeStatusView() {
  return View.frame(
    View.vstack([
      lastFmBadgeNode(18, "warning"),
      View.text("Last.fm connected", {
        style: "title",
        color: "white",
        lineLimit: 1
      }),
      View.text(connectionLabel(), {
        style: "footnote",
        color: secondaryTextColor(),
        lineLimit: 1,
        multilineTextAlignment: "center"
      }),
      View.text("Playback data is temporarily unavailable in this app session. Relaunch SuperIsland to restore the media bridge.", {
        style: "footnote",
        color: warningTextColor(),
        lineLimit: 3,
        multilineTextAlignment: "center"
      })
    ], { spacing: 7, align: "center" }),
    { maxWidth: 9999, alignment: "center" }
  );
}

function authRequiredCompactIcon() {
  return View.icon("rectangle.portrait.and.arrow.right", {
    size: 13,
    color: warningTextColor()
  });
}

function compactView() {
  var idleBadge = !state.lastSnapshot || currentSourceLabel() === "No active track";
  if (idleBadge) {
    return View.hstack([
      lastFmIconNode(18, 5),
      View.frame((!authConnected()) ? authRequiredCompactIcon() : lastFmIconNode(12, 4), {
        width: 16,
        height: 16,
        alignment: "trailing"
      })
    ], { spacing: 8, align: "center" });
  }

  return View.hstack([
    lastFmIconNode(18, 5),
    View.text(authConnected() ? currentSourceBadgeLabel() : "Last.fm", {
      style: "footnote",
      color: { r: 1, g: 1, b: 1, a: 0.7 },
      lineLimit: 1
    })
  ], { spacing: 8, align: "center" });
}

function minimalCompactLeadingView() {
  return View.frame(lastFmIconNode(17, 4), {
    width: 18,
    height: 18,
    alignment: "leading"
  });
}

function minimalCompactTrailingView() {
  if (!authConnected()) {
    return View.frame(decorateTrailingIndicator(
      View.animate(authRequiredCompactIcon(), "pulse")
    ), {
      width: 18,
      height: 18,
      alignment: "trailing"
    });
  }

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
  if (!authConnected()) {
    return setupStatusCard();
  }
  if (!hasMediaBridge()) {
    return mediaBridgeStatusView();
  }

  return scrobblerPlayerCard("compact");
}

function fullExpandedView() {
  if (!authConnected()) {
    return setupStatusCard();
  }

  if (!hasMediaBridge()) {
    return mediaBridgeStatusView();
  }

  return scrobblerPlayerCard("full");
}

async function tick() {
  if (runtimeState.tickInFlight) return;
  runtimeState.tickInFlight = true;
  try {
  syncAuthFromOAuthStore();

  var snapshot = null;
  try {
    snapshot = asObject(hasMediaBridge() ? SuperIsland.system.getNowPlaying() : null);
  } catch (error) {
    snapshot = null;
    logOperationWarning("nowPlaying", "Unable to read current playback from SuperIsland.");
  }
  state.lastSnapshot = snapshot;

  if (!effectiveEnabled()) {
    return;
  }

  updatePlaybackFromSnapshot(snapshot);

  if (state.currentPlayback) {
    await sendNowPlayingUpdate(state.currentPlayback);
  }

  await flushQueue(false);
  } finally {
    runtimeState.tickInFlight = false;
  }
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
  if (!authConnected() && state.auth.status !== "pending") {
    setResult("Last.fm is already disconnected.");
    clearError();
    return;
  }
  clearAuthState();
  clearOperationRetry("nowPlaying");
  clearOperationRetry("queue");
  state.currentPlayback = null;
  state.lastSnapshot = null;
  state.lastResult = "Signed out of Last.fm";
  logInfo(state.lastResult);
  clearError();
  persistState();
}

function toggleEnabled(forceValue) {
  var nextValue = typeof forceValue === "boolean" ? forceValue : !effectiveEnabled();
  SuperIsland.store.set("enabledOverride", nextValue);
  setResult(nextValue ? "Auto scrobbling enabled" : "Auto scrobbling paused");
}

function toggleSendNowPlaying(forceValue) {
  var nextValue = typeof forceValue === "boolean" ? forceValue : !sendNowPlayingEnabled();
  SuperIsland.store.set("sendNowPlayingOverride", nextValue);
  setResult(nextValue ? "Now playing updates enabled" : "Now playing updates paused");
}

loadState();

SuperIsland.registerModule({
  onActivate: function() {
    startPolling();
    if (!authConnected() || state.auth.status === "pending") {
      revealIslandForSetup();
    }
  },

  onDeactivate: function() {
    stopPolling();
  },

  onSettingsChanged: function() {
    syncButtonAvailability();
    clearError();
    void tick();
  },

  onAction: function(actionID, value) {
    if (actionID === "openAlbumPage") {
      if (lastFmAlbumURL()) {
        SuperIsland.openURL(lastFmAlbumURL());
        setResult("Opened album on Last.fm.");
      }
      return;
    }
    if (actionID === "openTrackPage") {
      if (lastFmTrackURL()) {
        SuperIsland.openURL(lastFmTrackURL());
        setResult("Opened track on Last.fm.");
      }
      return;
    }
    if (actionID === "openArtistPage") {
      if (lastFmArtistURL()) {
        SuperIsland.openURL(lastFmArtistURL());
        setResult("Opened artist on Last.fm.");
      }
      return;
    }
    if (actionID === "openProfilePage") {
      if (lastFmProfileURL()) {
        SuperIsland.openURL(lastFmProfileURL());
        setResult("Opened your Last.fm profile.");
      }
      return;
    }
    if (actionID === "auth") {
      revealIslandForSetup();
      startAuthFlow();
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
      setResult("Status cleared.");
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
