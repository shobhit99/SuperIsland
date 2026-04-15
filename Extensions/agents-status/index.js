"use strict";

// --- Config --------------------------------------------------------------
var EXT_VERSION = "1.5.0";
var PORT = 7823;
var BASE = "http://127.0.0.1:" + PORT;
var POLL_INTERVAL_MS = 800;
var SETTING_HOOKS_CC = "hooksClaudeCode";
var SETTING_HOOKS_CODEX = "hooksCodex";

// --- safeFetch -----------------------------------------------------------
// Host bug (ExtensionJSRuntime.fetchSync): options.method / options.body are
// read via `forProperty(...).toString()` with no undefined/null guard. Always
// pass a complete options object so Swift never receives the literal string
// "undefined" as a method or body.
var _rawFetch = (SuperIsland && SuperIsland.http && typeof SuperIsland.http.fetch === "function")
  ? SuperIsland.http.fetch.bind(SuperIsland.http)
  : null;

function safeFetch(url, opts) {
  if (!_rawFetch) return { then: function () { return { catch: function () {} }; } };
  var o = opts || {};
  return _rawFetch(url, {
    method: (typeof o.method === "string" && o.method.length > 0) ? o.method : "GET",
    body: (typeof o.body === "string") ? o.body : "",
    headers: (o.headers && typeof o.headers === "object") ? o.headers : {}
  });
}

// --- State ---------------------------------------------------------------
var sessions = [];           // array of {agent, session_id, state, title, cwd, terminal, tab_title, tab_ordinal, updated_at}
var currentState = "Idle";   // derived from top session (for compact view)
var bridgeOnline = false;
var hooksCC = false;
var hooksCodex = false;
var activationFailed = false;
var offlineWarningSent = false;
var inFlight = false;
var pollTimer = null;

// --- Colors --------------------------------------------------------------
var COLORS = {
  Working: { r: 0.655, g: 0.545, b: 0.980, a: 1 },
  Waiting: { r: 0.984, g: 0.749, b: 0.141, a: 1 },
  Idle:    { r: 0.420, g: 0.447, b: 0.502, a: 1 },
  Error:   { r: 0.973, g: 0.443, b: 0.443, a: 1 }
};
var OFFLINE = { r: 0.3, g: 0.3, b: 0.3, a: 1 };
var WHITE_65 = { r: 1, g: 1, b: 1, a: 0.65 };
var WHITE_50 = { r: 1, g: 1, b: 1, a: 0.5 };
var WHITE_40 = { r: 1, g: 1, b: 1, a: 0.4 };
var WHITE_35 = { r: 1, g: 1, b: 1, a: 0.35 };
var CHIP_BG = { r: 1, g: 1, b: 1, a: 0.08 };

// --- Pixel patterns ------------------------------------------------------
var W = 5, H = 5;
var QMARK  = { 1:1, 2:1, 3:1, 5:1, 9:1, 12:1, 13:1, 17:1, 22:1 };
var CURSOR = { 11:1, 12:1, 13:1, 16:1, 17:1, 18:1 };
var XPAT   = { 0:1, 4:1, 6:1, 8:1, 12:1, 16:1, 18:1, 20:1, 24:1 };
var OFFLINE_GLYPH = { 2:1, 7:1, 12:1, 22:1 };

function clamp01(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
function withAlpha(c, a) { return { r: c.r, g: c.g, b: c.b, a: clamp01(a) }; }

function computeAlphas(state, t, online) {
  var out = new Array(25);
  var i;
  if (!online) {
    var blink = Math.sin(t / 450) > 0;
    for (i = 0; i < 25; i++) out[i] = OFFLINE_GLYPH[i] ? (blink ? 1.0 : 0.35) : 0;
    return out;
  }
  if (state === "Working") {
    for (i = 0; i < 25; i++) {
      var x = i % W, y = (i / W) | 0;
      var dx = x - 2, dy = y - 2;
      var d = Math.sqrt(dx * dx + dy * dy);
      var v = Math.sin(t / 400 - d * 1.2) * 0.5 + 0.5;
      out[i] = v > 0.3 ? (v * 0.9 + 0.1) : 0;
    }
  } else if (state === "Waiting") {
    var b = Math.sin(t / 500) > 0;
    for (i = 0; i < 25; i++) out[i] = QMARK[i] ? (b ? 1.0 : 0.3) : 0;
  } else if (state === "Idle") {
    var on = (t % 1060) < 600;
    for (i = 0; i < 25; i++) out[i] = CURSOR[i] ? (on ? 0.9 : 0) : 0;
  } else if (state === "Error") {
    var pulse = Math.sin(t / 300) * 0.25 + 0.75;
    for (i = 0; i < 25; i++) out[i] = XPAT[i] ? pulse : 0;
  } else {
    for (i = 0; i < 25; i++) out[i] = 0;
  }
  return out;
}

// --- Pixel view builders -------------------------------------------------
function cell(pixelSize, color, radius) {
  var box = View.frame(View.text("", { style: "caption", color: "white" }), { width: pixelSize, height: pixelSize });
  if (!color) return box;
  return View.cornerRadius(View.background(box, color), radius);
}

function pixelGrid(state, online, pixelSize, gap) {
  var t = Date.now();
  var alphas = computeAlphas(state, t, online);
  var base = online ? (COLORS[state] || COLORS.Idle) : (activationFailed ? { r: 0.98, g: 0.42, b: 0.42, a: 1 } : OFFLINE);
  var radius = Math.max(1, pixelSize * 0.18);
  var rows = [];
  for (var y = 0; y < H; y++) {
    var row = [];
    for (var x = 0; x < W; x++) {
      var i = y * W + x;
      var a = alphas[i];
      row.push(a > 0.01 ? cell(pixelSize, withAlpha(base, a), radius) : cell(pixelSize, null, 0));
    }
    rows.push(View.hstack(row, { spacing: gap, align: "center" }));
  }
  return View.vstack(rows, { spacing: gap, align: "center" });
}

function pixelBox(state, online, outerSize) {
  var pad = Math.max(3, Math.floor(outerSize * 0.14));
  var inner = outerSize - pad * 2;
  var gap = 1;
  var pixelSize = Math.max(2, Math.floor((inner - gap * 4) / 5));
  var grid = pixelGrid(state, online, pixelSize, gap);
  return View.cornerRadius(
    View.background(
      View.frame(grid, { width: outerSize, height: outerSize, alignment: "center" }),
      { r: 0, g: 0, b: 0, a: 1 }
    ),
    Math.max(4, outerSize * 0.18)
  );
}

// --- Formatting helpers --------------------------------------------------
function stateAccent(s, online) {
  if (!online) return { r: 1, g: 0.4, b: 0.4, a: 1 };
  return COLORS[s] || COLORS.Idle;
}

function stateDescription(s, online) {
  if (!online) {
    return activationFailed
      ? "Bridge unreachable · run server/install.sh"
      : "Bridge offline · awaiting connection";
  }
  if (s === "Working") return "Executing task";
  if (s === "Waiting") return "Awaiting your input";
  if (s === "Idle")    return "Standby — ready for next prompt";
  if (s === "Error")   return "Last tool call failed";
  return "";
}

// "Claude" / "Codex" tone in the pill.
function agentAccent(agent) {
  if (agent === "Codex") return { r: 0.40, g: 0.80, b: 0.55, a: 1 };
  return { r: 0.92, g: 0.55, b: 0.35, a: 1 }; // Claude (warm)
}

// "1 Mission Park Dr" style trim — last path segment, unless it's $HOME.
function cwdShort(cwd) {
  if (!cwd) return "";
  var parts = cwd.split("/");
  for (var i = parts.length - 1; i >= 0; i--) {
    if (parts[i]) return parts[i];
  }
  return cwd;
}

function titleFor(s) {
  if (s.title) return s.title;
  var c = cwdShort(s.cwd);
  return c ? c : "(no title)";
}

function displayTitleFor(s) {
  if (s && s.tab_title) return s.tab_title;
  return titleFor(s);
}

function relativeTime(updatedAt) {
  if (!updatedAt) return "";
  var diff = Math.max(0, Date.now() / 1000 - updatedAt);
  if (diff < 45) return "now";
  if (diff < 90) return "1m";
  if (diff < 3600) return Math.round(diff / 60) + "m";
  if (diff < 3600 * 36) return Math.round(diff / 3600) + "h";
  return Math.round(diff / 86400) + "d";
}

// Counts per state for the tight minimal-trailing slot. Renders as
// "112" with each digit tinted by its state color — no separators so
// 4+ digits still fit. Order: Error, Waiting, Working, Idle. Empty
// buckets omitted. Falls back to "—" if no sessions.
function stateCountsView() {
  var order = ["Error", "Waiting", "Working", "Idle"];
  var counts = { Error: 0, Waiting: 0, Working: 0, Idle: 0 };
  for (var i = 0; i < sessions.length; i++) {
    var st = sessions[i].state;
    if (counts[st] !== undefined) counts[st]++;
  }
  var parts = [];
  for (var j = 0; j < order.length; j++) {
    var s = order[j];
    if (counts[s] > 0) {
      parts.push(View.text(String(counts[s]), { style: "monospacedSmall", color: COLORS[s] }));
    }
  }
  if (parts.length === 0) {
    return View.frame(
      View.text("—", { style: "monospacedSmall", color: WHITE_40 }),
      { maxWidth: 9999, alignment: "center" }
    );
  }
  return View.frame(
    View.hstack(parts, { spacing: 0, align: "center" }),
    { maxWidth: 9999, alignment: "center" }
  );
}

// --- Chip helper ---------------------------------------------------------
function chip(text, color) {
  return View.cornerRadius(
    View.background(
      View.padding(
        View.padding(
          View.text(text, { style: "footnote", color: color || WHITE_65 }),
          { edges: "horizontal", amount: 5 }
        ),
        { edges: "vertical", amount: 1 }
      ),
      CHIP_BG
    ),
    4
  );
}

function focusActionID(s) {
  return "focus/" + encodeURIComponent(s.agent || "") + "/" + encodeURIComponent(s.session_id || "");
}

function decodeURIComponentSafe(text) {
  try { return decodeURIComponent(text); } catch (e) { return text; }
}

function isSessionFocusable(s) {
  return !!(s && s.focusable);
}

// --- Session row ---------------------------------------------------------
function sessionRow(s, pixelSize, showCwd, tappable) {
  var title = displayTitleFor(s);
  var sub = showCwd ? cwdShort(s.cwd) : "";
  var textCol = [
    View.text(title, { style: "body", color: "white", lineLimit: 1 })
  ];
  if (sub) {
    textCol.push(View.text(sub, { style: "footnote", color: WHITE_50, lineLimit: 1 }));
  }

  var chips = [];
  if (s.agent) chips.push(chip(s.agent, agentAccent(s.agent)));
  if (s.tab_ordinal) chips.push(chip("#" + s.tab_ordinal, WHITE_65));
  if (s.terminal) chips.push(chip(s.terminal, WHITE_65));
  chips.push(View.text(relativeTime(s.updated_at), { style: "footnote", color: WHITE_40 }));

  var row = View.hstack([
    pixelBox(s.state, true, pixelSize),
    View.frame(
      View.vstack(textCol, { spacing: 1, align: "leading" }),
      { maxWidth: 9999, alignment: "leading" }
    ),
    View.hstack(chips, { spacing: 4, align: "center" })
  ], { spacing: 8, align: "center" });
  if (!tappable) return row;
  return View.button(row, focusActionID(s));
}

// --- Logging -------------------------------------------------------------
var debugLogCount = 0;
function dlog(msg) {
  if (debugLogCount < 80) { debugLogCount++; console.log("[agents-status] " + msg); }
}

// --- Notifications -------------------------------------------------------
function notifyFailure(title, body) {
  if (offlineWarningSent) return;
  offlineWarningSent = true;
  try {
    SuperIsland.notifications.send({
      title: title,
      body: body,
      id: "agents-status-bridge-offline",
      systemNotification: true
    });
  } catch (e) {
    dlog("notify threw: " + e);
  }
}

// --- Settings helpers ----------------------------------------------------
function settingBool(key, fallback) {
  try {
    var v = SuperIsland.settings.get(key);
    if (typeof v === "boolean") return v;
  } catch (e) {}
  return fallback;
}

// --- Derived top-session -------------------------------------------------
function recomputeTop() {
  if (!sessions || sessions.length === 0) {
    currentState = "Idle";
    return;
  }
  // Server already sorts by priority/updated_at; pick index 0.
  currentState = sessions[0].state || "Idle";
}

// --- Networking ----------------------------------------------------------
function fetchState() {
  if (inFlight) return;
  inFlight = true;
  var url = BASE + "/state?_=" + Date.now();
  safeFetch(url)
    .then(function (res) {
      inFlight = false;
      var status = res && typeof res.status === "number" ? res.status : -1;
      if (status === 200 && res.data) {
        var list = res.data.sessions;
        sessions = (list && list.length) ? list : [];
        recomputeTop();
        var wasOffline = !bridgeOnline;
        if (wasOffline) dlog("online sessions=" + sessions.length);
        bridgeOnline = true;
        activationFailed = false;
        // Reconcile hooks on every offline→online transition so a late-starting
        // or restarted bridge still gets its agent configs installed. The
        // server's /hooks/install is idempotent, so re-firing is a no-op when
        // already installed.
        if (wasOffline) applyAllHooks();
      } else {
        if (bridgeOnline) dlog("bridge went offline status=" + status);
        bridgeOnline = false;
      }
    })
    .catch(function (e) {
      inFlight = false;
      bridgeOnline = false;
      dlog("fetch threw: " + e);
    });
}

function postBridge(path, bodyString) {
  return safeFetch(BASE + path, {
    method: "POST",
    body: bodyString || "",
    headers: { "Content-Type": "application/json" }
  });
}

function focusSession(agent, sessionID) {
  SuperIsland.playFeedback("selection");
  SuperIsland.island.dismiss();
  return postBridge("/focus", JSON.stringify({
    agent: agent || "",
    session_id: sessionID || ""
  }))
    .then(function (r) {
      var ok = !!(r && r.status === 200 && r.data && r.data.ok);
      if (!ok) {
        SuperIsland.playFeedback("error");
        dlog("focus failed status=" + (r && r.status));
      }
    })
    .catch(function (e) {
      SuperIsland.playFeedback("error");
      dlog("focus threw: " + e);
    });
}

// --- Lifecycle -----------------------------------------------------------
function activateBridge() {
  return postBridge("/control/resume", "")
    .then(function (r) {
      return !!(r && r.status === 200 && r.data && r.data.paused === false);
    })
    .catch(function () { return false; });
}

function deactivateBridge() {
  return postBridge("/control/pause", "")
    .then(function (r) {
      if (r && r.status === 200) dlog("bridge paused on deactivate");
    })
    .catch(function (e) { dlog("pause threw: " + e); });
}

function reconcileHooks(agent, want) {
  var path = (want ? "/hooks/install" : "/hooks/uninstall") + "?agent=" + agent;
  return postBridge(path, "")
    .then(function (r) {
      if (r && r.status === 200 && r.data) {
        if (agent === "claude") hooksCC = !!want;
        else if (agent === "codex") hooksCodex = !!want;
        dlog(agent + " hooks " + (want ? "installed" : "uninstalled"));
      } else {
        dlog(agent + " hooks reconcile failed status=" + (r && r.status));
      }
    })
    .catch(function (e) { dlog(agent + " hooks reconcile threw: " + e); });
}

function applyAllHooks() {
  reconcileHooks("claude", settingBool(SETTING_HOOKS_CC, true));
  reconcileHooks("codex",  settingBool(SETTING_HOOKS_CODEX, true));
}

function startPolling() {
  if (pollTimer !== null) return;
  fetchState();
  pollTimer = setInterval(fetchState, POLL_INTERVAL_MS);
}
function stopPolling() {
  if (pollTimer !== null) { clearInterval(pollTimer); pollTimer = null; }
}

// --- Module --------------------------------------------------------------
SuperIsland.registerModule({
  onActivate: function () {
    dlog("boot v" + EXT_VERSION + " at " + new Date().toISOString());
    activationFailed = false;
    offlineWarningSent = false;

    activateBridge().then(function (ok) {
      if (ok) {
        dlog("bridge resumed on activate");
        bridgeOnline = true;
        activationFailed = false;
        applyAllHooks();
      } else {
        activationFailed = true;
        bridgeOnline = false;
        dlog("ACTIVATION FAILED: bridge unreachable — run Extensions/agents-status/server/install.sh");
        notifyFailure(
          "Agents Status: bridge unreachable",
          "Disable the extension and run server/install.sh once, then re-enable."
        );
      }
      startPolling();
    });
  },

  onDeactivate: function () {
    dlog("deactivate requested → pausing bridge");
    stopPolling();
    deactivateBridge();
  },

  onSettingsChanged: function (key, value) {
    dlog("setting " + key + " -> " + value);
    if (key === SETTING_HOOKS_CC)    reconcileHooks("claude", !!value);
    else if (key === SETTING_HOOKS_CODEX) reconcileHooks("codex",  !!value);
  },

  onAction: function (actionID) {
    if (actionID === "activate") {
      SuperIsland.island.activate(false);
      return;
    }
    if (actionID && actionID.indexOf("focus/") === 0) {
      var parts = actionID.split("/");
      var target = null;
      for (var i = 0; i < sessions.length; i++) {
        if (focusActionID(sessions[i]) === actionID) { target = sessions[i]; break; }
      }
      if (!isSessionFocusable(target)) {
        SuperIsland.playFeedback("warning");
        dlog("focus skipped: session not focusable");
        return;
      }
      focusSession(decodeURIComponentSafe(parts[1] || ""), decodeURIComponentSafe(parts[2] || ""));
    }
  },

  // -- minimalCompact (notched Macs) --
  minimalCompact: {
    leading: function () {
      return View.frame(pixelBox(currentState, bridgeOnline, 24), { width: 24, height: 24, alignment: "center" });
    },
    trailing: function () {
      if (!bridgeOnline) {
        return View.text(activationFailed ? "setup" : "—", { style: "monospacedSmall", color: stateAccent(currentState, false) });
      }
      return stateCountsView();
    },
    precedence: function () {
      if (!bridgeOnline) return 2;
      return (currentState === "Waiting" || currentState === "Error") ? 2 : 1;
    }
  },

  // -- compact (non-notched) --
  compact: function () {
    if (!bridgeOnline) {
      var off = activationFailed ? "setup" : "offline";
      return View.hstack([
        pixelBox(currentState, false, 26),
        View.text(off, { style: "caption", color: stateAccent(currentState, false) })
      ], { spacing: 6, align: "center" });
    }
    var n = sessions.length;
    var label = n > 1 ? (n + " sessions") : currentState;
    return View.hstack([
      pixelBox(currentState, true, 26),
      View.text(label, { style: "caption", color: stateAccent(currentState, true) })
    ], { spacing: 6, align: "center" });
  },

  // -- expanded (drawer, ~360×80) --
  expanded: function () {
    if (!bridgeOnline || sessions.length === 0) {
      return heroView();
    }
    var rows = [];
    var n = Math.min(sessions.length, 2);
    for (var i = 0; i < n; i++) {
      rows.push(sessionRow(sessions[i], 22, false, isSessionFocusable(sessions[i])));
    }
    if (sessions.length > 2) {
      rows.push(View.text("+" + (sessions.length - 2) + " more", {
        style: "footnote", color: WHITE_40
      }));
    }
    return View.vstack(rows, { spacing: 6, align: "leading" });
  },

  // -- fullExpanded (detail, 400×200) --
  fullExpanded: function () {
    if (!bridgeOnline || sessions.length === 0) {
      return heroView();
    }
    var rows = [];
    for (var i = 0; i < sessions.length; i++) {
      rows.push(sessionRow(sessions[i], 24, true, isSessionFocusable(sessions[i])));
      if (i < sessions.length - 1) rows.push(View.divider());
    }
    return View.scroll(
      View.vstack(rows, { spacing: 6, align: "leading" }),
      { axes: "vertical", showsIndicators: false }
    );
  }
});

// Fallback when no sessions yet (bridge online but empty, or offline).
function heroView() {
  var accent = stateAccent(currentState, bridgeOnline);
  var headline = bridgeOnline
    ? "No active sessions"
    : (activationFailed ? "Setup required" : "Offline");
  var sub = bridgeOnline
    ? "Start Claude Code or Codex to see it here"
    : stateDescription(currentState, false);
  return View.hstack([
    pixelBox(currentState, bridgeOnline, 48),
    View.vstack([
      View.text("Agents Status", { style: "headline", color: "white" }),
      View.text(headline, { style: "caption", color: accent }),
      View.text(sub, { style: "footnote", color: WHITE_50, lineLimit: 2 })
    ], { spacing: 3, align: "leading" }),
    View.spacer()
  ], { spacing: 10, align: "center" });
}
