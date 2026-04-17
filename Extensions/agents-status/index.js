"use strict";

// --- Config --------------------------------------------------------------
var EXT_VERSION = "1.6.0";
var PORT = 7823;
var BASE = "http://127.0.0.1:" + PORT;
var POLL_INTERVAL_MS = 800;
var SETTING_HOOKS_CC = "hooksClaudeCode";
var SETTING_HOOKS_CODEX = "hooksCodex";
var SETTING_SOUND_ALERT = "soundAlert";

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
var prevSessionStates = {};  // key "agent|session_id" -> last-seen state
var soundsSeeded = false;    // skip sounds on the first snapshot after boot
var doneUntil = {};          // key "agent|session_id" -> ms timestamp; while now < value, show Done (green) instead of Idle
var DONE_DURATION_MS = 10 * 60 * 1000; // green tick sticks for 10 minutes after a session finishes, unless it starts working again
var seenPermissions = {};    // permission_id -> true; used to pop the island once per new AskUserQuestion

// --- Colors --------------------------------------------------------------
// Kept at full saturation — the compact slot sits on the pill's near-black
// background, so bright colors read much better than muted ones.
var COLORS = {
  Working: { r: 0.655, g: 0.545, b: 0.980, a: 1 },
  Waiting: { r: 0.984, g: 0.749, b: 0.141, a: 1 },
  Idle:    { r: 0.420, g: 0.447, b: 0.502, a: 1 },
  Error:   { r: 0.973, g: 0.443, b: 0.443, a: 1 },
  Done:    { r: 0.310, g: 0.835, b: 0.514, a: 1 }
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
var CHECK  = { 4:1, 8:1, 10:1, 12:1, 16:1 };
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
  } else if (state === "Done") {
    var glow = Math.sin(t / 360) * 0.15 + 0.85;
    for (i = 0; i < 25; i++) out[i] = CHECK[i] ? glow : 0;
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
function sessionKey(s) {
  return (s && s.agent ? s.agent : "") + "|" + (s && s.session_id ? s.session_id : "");
}

// Overlay a transient "Done" state on top of the server-reported state so the
// user sees a green checkmark glow right after an agent finishes, instead of
// dropping straight to the gray Idle cursor.
function effectiveState(s) {
  if (!s) return "Idle";
  var raw = s.state || "Idle";
  if (raw !== "Idle") return raw;
  var until = doneUntil[sessionKey(s)];
  if (until && Date.now() < until) return "Done";
  return raw;
}

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
  if (s === "Done")    return "Just finished";
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

// Working-session count for the tight minimal-trailing slot. Shows the number
// of sessions currently Working in the Working (purple) color. Falls back to a
// green Done count when nothing is running but something just finished, and to
// "—" when there's nothing interesting at all.
function countsByEffectiveState() {
  var counts = { Error: 0, Waiting: 0, Working: 0, Done: 0, Idle: 0 };
  for (var i = 0; i < sessions.length; i++) {
    var st = effectiveState(sessions[i]);
    if (counts[st] !== undefined) counts[st]++;
  }
  return counts;
}

function workingCountView() {
  var counts = countsByEffectiveState();
  var label, color;
  if (counts.Working > 0) {
    label = String(counts.Working);
    color = COLORS.Working;
  } else if (counts.Done > 0) {
    label = String(counts.Done);
    color = COLORS.Done;
  } else {
    label = "—";
    color = { r: 1, g: 1, b: 1, a: 0.7 };
  }
  return View.frame(
    View.text(label, { style: "headline", color: color }),
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

function askActionID(permissionId, optionIndex) {
  return "ask/" + encodeURIComponent(permissionId || "") + "/" + String(optionIndex);
}

function decodeURIComponentSafe(text) {
  try { return decodeURIComponent(text); } catch (e) { return text; }
}

function isSessionFocusable(s) {
  return !!(s && s.focusable);
}

function sessionPendingPermission(s) {
  if (!s) return null;
  var p = s.pending_permission;
  if (!p || !p.permission_id) return null;
  return p;
}

// --- Pending question renderer ------------------------------------------
// Renders a vertical stack: header, question text, and one button per option.
// Tapping a button POSTs /permission/resolve and unblocks the Claude hook.
function questionCard(s, pixelSize) {
  var p = sessionPendingPermission(s);
  if (!p) return null;

  var topLine = [];
  topLine.push(pixelBox("Waiting", true, pixelSize));
  var headerText = p.header || "Question";
  var labelChipChildren = [chip((s.agent || "Claude"), agentAccent(s.agent || "Claude"))];
  if (s.terminal) labelChipChildren.push(chip(s.terminal, WHITE_65));
  var titleStack = View.vstack([
    View.text(headerText, { style: "body", color: "white", lineLimit: 2 }),
    View.text(cwdShort(s.cwd) || displayTitleFor(s), { style: "footnote", color: WHITE_50, lineLimit: 1 })
  ], { spacing: 1, align: "leading" });
  var rowHead = View.hstack([
    pixelBox("Waiting", true, pixelSize),
    View.frame(titleStack, { maxWidth: 9999, alignment: "leading" }),
    View.hstack(labelChipChildren, { spacing: 4, align: "center" })
  ], { spacing: 8, align: "center" });

  var stack = [rowHead];
  if (p.question) {
    stack.push(View.text(p.question, { style: "caption", color: WHITE_65, lineLimit: 4 }));
  }

  var options = p.options || [];
  var buttons = [];
  for (var i = 0; i < options.length; i++) {
    var opt = options[i] || {};
    var label = opt.label || opt.value || ("Option " + (i + 1));
    var button = View.button(
      View.cornerRadius(
        View.background(
          View.padding(
            View.padding(
              View.text(label, { style: "caption", color: "white", lineLimit: 1 }),
              { edges: "horizontal", amount: 10 }
            ),
            { edges: "vertical", amount: 6 }
          ),
          { r: 1, g: 1, b: 1, a: 0.12 }
        ),
        8
      ),
      askActionID(p.permission_id, i)
    );
    buttons.push(button);
  }
  if (buttons.length > 0) {
    stack.push(View.vstack(buttons, { spacing: 4, align: "leading" }));
  }
  return View.vstack(stack, { spacing: 6, align: "leading" });
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
    pixelBox(effectiveState(s), true, pixelSize),
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
  // If any session is currently in the green "Done" window, surface that in the
  // compact view so a glance confirms a recently-finished task. Otherwise fall
  // back to the server's priority-sorted top session.
  for (var i = 0; i < sessions.length; i++) {
    if (effectiveState(sessions[i]) === "Done") {
      currentState = "Done";
      return;
    }
  }
  currentState = sessions[0].state || "Idle";
}

// --- Sound alerts --------------------------------------------------------
function playSoundTone(tone) {
  try {
    postBridge("/sound?tone=" + encodeURIComponent(tone), "");
  } catch (e) {
    dlog("sound post threw: " + e);
  }
}

function popIslandForDone(persist) {
  try {
    // Normal "done" events auto-dismiss (persist=false), but when we have a
    // pending question the island must stay open so the user can click an
    // option button — otherwise it collapses before they can answer.
    SuperIsland.island.activate(persist ? false : true);
  } catch (e) {
    dlog("island activate threw: " + e);
  }
}

function detectSoundTransitions(list) {
  var nextMap = {};
  var sawStart = false, sawStop = false, sawWaiting = false;
  var now = Date.now();
  for (var i = 0; i < list.length; i++) {
    var s = list[i];
    var key = sessionKey(s);
    var newState = s.state || "Idle";
    nextMap[key] = newState;
    if (!soundsSeeded) continue;
    var oldState = prevSessionStates[key];
    if (oldState === newState) continue;
    if (newState === "Working" && oldState !== "Working") {
      sawStart = true;
      // Entering Working clears any stale Done glow from a prior run.
      delete doneUntil[key];
    } else if (oldState === "Working" && newState !== "Working") {
      sawStop = true;
      doneUntil[key] = now + DONE_DURATION_MS;
    }
    if (newState === "Waiting" && oldState !== "Waiting") {
      sawWaiting = true;
    }
  }
  // Sessions that disappeared while Working → treat as leaving Working.
  if (soundsSeeded) {
    for (var oldKey in prevSessionStates) {
      if (!Object.prototype.hasOwnProperty.call(prevSessionStates, oldKey)) continue;
      if (nextMap[oldKey] === undefined && prevSessionStates[oldKey] === "Working") {
        sawStop = true;
        doneUntil[oldKey] = now + DONE_DURATION_MS;
      }
    }
  }
  // Prune expired / orphaned entries so the map stays bounded.
  for (var pruneKey in doneUntil) {
    if (!Object.prototype.hasOwnProperty.call(doneUntil, pruneKey)) continue;
    if (doneUntil[pruneKey] <= now) delete doneUntil[pruneKey];
  }
  prevSessionStates = nextMap;
  // New pending permissions always pop the island — user action required.
  var sawNewPermission = false;
  var stillPending = {};
  for (var pi = 0; pi < list.length; pi++) {
    var ps = list[pi];
    var pp = sessionPendingPermission(ps);
    if (!pp) continue;
    stillPending[pp.permission_id] = true;
    if (!seenPermissions[pp.permission_id]) {
      seenPermissions[pp.permission_id] = true;
      sawNewPermission = true;
    }
  }
  // Purge resolved permission IDs so a repeat permission_id reuse (unlikely
  // with UUIDs but defensive) still pops.
  for (var seenKey in seenPermissions) {
    if (!Object.prototype.hasOwnProperty.call(seenPermissions, seenKey)) continue;
    if (!stillPending[seenKey]) delete seenPermissions[seenKey];
  }
  if (!soundsSeeded) { soundsSeeded = true; return; }
  // Waiting or a new permission always pops the island — the user needs to
  // act. Permission pops persist so the option buttons are clickable.
  if (sawNewPermission) popIslandForDone(true);
  else if (sawWaiting) popIslandForDone(false);
  if (!settingBool(SETTING_SOUND_ALERT, false)) return;
  if (sawStart) playSoundTone("start");
  if (sawStop) {
    playSoundTone("stop");
    popIslandForDone(false);
  }
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
        detectSoundTransitions(sessions);
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

function resolvePermission(permissionId, optionIndex) {
  if (!permissionId || isNaN(optionIndex) || optionIndex < 0) return;
  // Find the matching pending permission to read its option label — that's
  // what Claude expects back as the answer (not the index).
  var selectedLabel = null;
  for (var i = 0; i < sessions.length; i++) {
    var p = sessionPendingPermission(sessions[i]);
    if (!p || p.permission_id !== permissionId) continue;
    var opt = (p.options || [])[optionIndex];
    if (opt) selectedLabel = opt.value != null ? opt.value : opt.label;
    break;
  }
  if (selectedLabel == null) {
    SuperIsland.playFeedback("error");
    dlog("resolve: option not found");
    return;
  }
  SuperIsland.playFeedback("selection");
  SuperIsland.island.dismiss();
  postBridge("/permission/resolve", JSON.stringify({
    permission_id: permissionId,
    selected_option: selectedLabel
  }))
    .then(function (r) {
      var ok = !!(r && r.status === 200 && r.data && r.data.ok);
      if (!ok) {
        SuperIsland.playFeedback("error");
        dlog("resolve failed status=" + (r && r.status));
      }
    })
    .catch(function (e) {
      SuperIsland.playFeedback("error");
      dlog("resolve threw: " + e);
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
    prevSessionStates = {};
    soundsSeeded = false;

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
    prevSessionStates = {};
    soundsSeeded = false;
  },

  onSettingsChanged: function (key, value) {
    dlog("setting " + key + " -> " + value);
    if (key === SETTING_HOOKS_CC)    reconcileHooks("claude", !!value);
    else if (key === SETTING_HOOKS_CODEX) reconcileHooks("codex",  !!value);
    else if (key === SETTING_SOUND_ALERT && !!value) {
      // Preview both channels so the user can verify alerts work.
      playSoundTone("start");
      setTimeout(function () { playSoundTone("stop"); }, 650);
      popIslandForDone();
    }
  },

  onAction: function (actionID) {
    if (actionID === "activate") {
      SuperIsland.island.activate(false);
      return;
    }
    if (actionID && actionID.indexOf("ask/") === 0) {
      var askParts = actionID.split("/");
      var permissionId = decodeURIComponentSafe(askParts[1] || "");
      var optionIndex = parseInt(askParts[2] || "-1", 10);
      resolvePermission(permissionId, optionIndex);
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
      return workingCountView();
    },
    precedence: function () {
      // Return > 0 whenever we want the pinned compact slot; higher values
      // just bias the tie-break when multiple pinned extensions compete.
      // (Note: the host's legacy logic used precedence > 1 to *yield* to
      // media, so we stay at 1 to hold the slot against music too.)
      if (!bridgeOnline) return 1;
      return 1;
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
    var counts = countsByEffectiveState();
    var label, labelColor;
    if (counts.Working > 0) {
      label = counts.Working + " working";
      labelColor = COLORS.Working;
    } else if (counts.Done > 0) {
      label = counts.Done + " done";
      labelColor = COLORS.Done;
    } else if (sessions.length > 0) {
      label = sessions.length === 1 ? "Idle" : (sessions.length + " idle");
      labelColor = stateAccent(currentState, true);
    } else {
      label = "No sessions";
      labelColor = WHITE_50;
    }
    return View.hstack([
      pixelBox(currentState, true, 26),
      View.text(label, { style: "caption", color: labelColor })
    ], { spacing: 6, align: "center" });
  },

  // -- expanded (drawer, ~360×80) --
  expanded: function () {
    if (!bridgeOnline || sessions.length === 0) {
      return heroView();
    }
    // If any session has a pending AskUserQuestion, surface that first —
    // the user needs to act on it before anything else matters.
    for (var q = 0; q < sessions.length; q++) {
      var card = questionCard(sessions[q], 22);
      if (card) return card;
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
    // Lift any pending AskUserQuestion cards to the top of the detail list.
    for (var q = 0; q < sessions.length; q++) {
      var card = questionCard(sessions[q], 24);
      if (card) {
        rows.push(card);
        rows.push(View.divider());
      }
    }
    for (var i = 0; i < sessions.length; i++) {
      if (sessionPendingPermission(sessions[i])) continue; // already surfaced above
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
