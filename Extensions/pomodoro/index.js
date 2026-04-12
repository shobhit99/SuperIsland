"use strict";

var PHASE_FOCUS = "focus";
var PHASE_BREAK = "break";

var phase = PHASE_FOCUS;
var isRunning = false;
var remainingSeconds = 0;
var timerID = null;
var sessionsCompleted = 0;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function toNumber(value, fallback) {
  if (value === null || value === undefined || value === "") return fallback;
  var parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function settingNumber(key, fallback) {
  return toNumber(SuperIsland.settings.get(key), fallback);
}

function settingBool(key, fallback) {
  var value = SuperIsland.settings.get(key);
  if (typeof value === "boolean") return value;
  if (value === null || value === undefined) return fallback;
  if (typeof value === "number") return value !== 0;
  if (typeof value === "string") return value.toLowerCase() === "true";
  return fallback;
}

function focusDurationSeconds() {
  return Math.max(60, Math.floor(settingNumber("workDuration", 25) * 60));
}

function breakDurationSeconds() {
  return Math.max(60, Math.floor(settingNumber("breakDuration", 5) * 60));
}

function currentPhaseDuration() {
  return phase === PHASE_FOCUS ? focusDurationSeconds() : breakDurationSeconds();
}

function formatTime(seconds) {
  var safe = Math.max(0, Math.floor(seconds));
  var m = Math.floor(safe / 60);
  var s = safe % 60;
  return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s;
}

// ---------------------------------------------------------------------------
// Daily reset
// ---------------------------------------------------------------------------

function todayDateString() {
  var d = new Date();
  return d.getFullYear() + "-" + (d.getMonth() < 9 ? "0" : "") + (d.getMonth() + 1) + "-" + (d.getDate() < 10 ? "0" : "") + d.getDate();
}

function resetSessionsIfNewDay() {
  var storedDate = SuperIsland.store.get("sessionsDate");
  var today = todayDateString();
  if (storedDate !== today) {
    sessionsCompleted = 0;
    SuperIsland.store.set("sessionsCompleted", 0);
    SuperIsland.store.set("sessionsDate", today);
  }
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

function saveState() {
  SuperIsland.store.set("phase", phase);
  SuperIsland.store.set("isRunning", isRunning);
  SuperIsland.store.set("remainingSeconds", remainingSeconds);
  SuperIsland.store.set("sessionsCompleted", sessionsCompleted);
  SuperIsland.store.set("sessionsDate", todayDateString());
}

function loadState() {
  resetSessionsIfNewDay();
  sessionsCompleted = toNumber(SuperIsland.store.get("sessionsCompleted"), 0);
  var storedPhase = SuperIsland.store.get("phase");
  phase = storedPhase === PHASE_BREAK ? PHASE_BREAK : PHASE_FOCUS;
  var storedRemaining = toNumber(SuperIsland.store.get("remainingSeconds"), currentPhaseDuration());
  remainingSeconds = Math.max(0, Math.min(storedRemaining, currentPhaseDuration()));
  var storedRunning = SuperIsland.store.get("isRunning");
  isRunning = typeof storedRunning === "boolean" ? storedRunning : false;
  if (remainingSeconds <= 0) remainingSeconds = currentPhaseDuration();
}

// ---------------------------------------------------------------------------
// Timer
// ---------------------------------------------------------------------------

function stopTimer() {
  if (timerID !== null) { clearInterval(timerID); timerID = null; }
}

function startTimer() {
  if (timerID !== null) return;
  timerID = setInterval(function() { tick(); }, 1000);
}

function isFullExpanded() {
  return SuperIsland.island.state === "fullExpanded";
}

function revealIsland() {
  if (isFullExpanded()) return;
  var revealSettleDelay = 120;
  var visibleDuration = 2000;
  SuperIsland.island.activate(false);
  setTimeout(function() { SuperIsland.island.activate(false); }, revealSettleDelay);
  setTimeout(function() { SuperIsland.island.dismiss(); }, visibleDuration + revealSettleDelay);
}

function setRunning(nextRunning) {
  isRunning = nextRunning;
  if (isRunning) { startTimer(); } else { stopTimer(); }
  updateMascotExpression();
  saveState();
}

function updateMascotExpression() {
  if (!isRunning || phase === PHASE_BREAK) {
    SuperIsland.mascot.setExpression("idle");
    return;
  }
  SuperIsland.mascot.setExpression("working");
}

function switchPhase() {
  var wasFocus = phase === PHASE_FOCUS;
  if (wasFocus) {
    sessionsCompleted += 1;
    SuperIsland.store.set("sessionsCompleted", sessionsCompleted);
  }
  phase = wasFocus ? PHASE_BREAK : PHASE_FOCUS;
  remainingSeconds = currentPhaseDuration();
  if (settingBool("notifyOnComplete", true)) {
    SuperIsland.notifications.send({
      title: wasFocus ? "Break started" : "Break ended",
      body: wasFocus
        ? "Session " + sessionsCompleted + " complete. Break is now running."
        : "Break ended. Start your next focus session when ready.",
      sound: settingBool("playSound", true)
    });
  }
  SuperIsland.playFeedback("success");
  if (wasFocus) { setRunning(true); revealIsland(); }
  else { setRunning(false); revealIsland(); }
  updateMascotExpression();
  saveState();
}

function tick() {
  if (!isRunning) return;
  resetSessionsIfNewDay();
  remainingSeconds -= 1;
  if (remainingSeconds <= 0) { remainingSeconds = 0; switchPhase(); return; }
  if (remainingSeconds % 15 === 0) saveState();
}

function resetToFocus() {
  phase = PHASE_FOCUS;
  remainingSeconds = focusDurationSeconds();
  setRunning(false);
  saveState();
}

function skipPhase() { switchPhase(); }

function progressRatio() {
  return 1 - remainingSeconds / Math.max(1, currentPhaseDuration());
}

// ---------------------------------------------------------------------------
// Visual theme
// ---------------------------------------------------------------------------

function phaseIcon() {
  if (phase === PHASE_BREAK) return "cup.and.saucer.fill";
  if (remainingSeconds <= 60 && isRunning) return "flame.fill";
  return "brain.head.profile";
}

function phaseColor() {
  if (phase === PHASE_BREAK) return "green";
  if (remainingSeconds <= 60 && isRunning) return "red";
  return "white";
}

function progressColor() {
  return phase === PHASE_BREAK ? "green" : phaseColor();
}

// Avatar icon per state
function avatarSymbol() {
  if (phase === PHASE_BREAK) return isRunning ? "cup.and.saucer.fill" : "leaf.fill";
  if (!isRunning) return "moon.zzz.fill";
  if (remainingSeconds <= 60) return "flame.fill";
  return "brain.head.profile.fill";
}

function avatarAnim() {
  if (!isRunning) return null;
  if (phase === PHASE_BREAK) return "bounce";
  if (remainingSeconds <= 60) return "blink";
  return "pulse";
}

function statusLabel() {
  if (phase === PHASE_BREAK) return isRunning ? "Chilling" : "Resting";
  if (isRunning) return remainingSeconds <= 60 ? "Wrapping up!" : "Deep work";
  return "Ready to focus";
}

// Accent color per state
function ac() {
  if (phase === PHASE_BREAK) return { r: 0.4, g: 0.87, b: 0.55, a: 1 };
  if (remainingSeconds <= 60 && isRunning) return { r: 1, g: 0.4, b: 0.35, a: 1 };
  return { r: 1, g: 0.68, b: 0.26, a: 1 };
}

// Glow (outer ring) color
function glowColor() {
  var c = ac();
  return { r: c.r, g: c.g, b: c.b, a: 0.12 };
}

// Core (inner circle) color
function coreColor() {
  var c = ac();
  return { r: c.r * 0.3, g: c.g * 0.3, b: c.b * 0.3, a: 1 };
}

// Icon tint (lighter accent)
function iconTint() {
  var c = ac();
  return { r: Math.min(1, c.r + 0.15), g: Math.min(1, c.g + 0.15), b: Math.min(1, c.b + 0.15), a: 1 };
}

// ---------------------------------------------------------------------------
// Reusable view builders
// ---------------------------------------------------------------------------

// Colored circle: frame first so background fills, then clip to circle
function coloredCircle(size, color) {
  return View.cornerRadius(
    View.background(
      View.frame(
        View.text("", { style: "caption", color: "white" }),
        { width: size, height: size }
      ),
      color
    ),
    size / 2
  );
}

// The 3D glowing avatar orb
function buildAvatarOrb(size, animationKind) {
  var orbSize = size || 60;
  var glowSize = orbSize;
  var midSize = orbSize * 0.8;
  var coreSize = orbSize * 0.63;
  var iconSize = orbSize * 0.43;
  var sym = avatarSymbol();
  var anim = animationKind === undefined ? avatarAnim() : animationKind;

  var iconView = View.icon(sym, { size: iconSize, color: iconTint() });
  var animatedIcon = anim ? View.animate(iconView, anim) : iconView;

  return View.zstack([
    coloredCircle(glowSize, glowColor()),
    coloredCircle(midSize, { r: ac().r * 0.2, g: ac().g * 0.2, b: ac().b * 0.2, a: 0.8 }),
    coloredCircle(coreSize, coreColor()),
    animatedIcon
  ]);
}

// Control button
function controlBtn(iconName, actionID, size, primary) {
  if (primary) {
    return View.button(
      View.cornerRadius(
        View.background(
          View.frame(
            View.icon(iconName, { size: size, color: "white" }),
            { width: 46, height: 46 }
          ),
          ac()
        ),
        23
      ),
      actionID
    );
  }
  return View.button(
    View.icon(iconName, { size: size, color: { r: 1, g: 1, b: 1, a: 0.5 } }),
    actionID
  );
}

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

SuperIsland.registerModule({
  onActivate: function() {
    loadState();
    if (isRunning) startTimer();
    updateMascotExpression();
  },

  onDeactivate: function() {
    stopTimer();
    isRunning = false;
    saveState();
  },

  onAction: function(actionID) {
    switch (actionID) {
      case "toggle":
        setRunning(!isRunning);
        if (isRunning) revealIsland();
        break;
      case "reset": resetToFocus(); break;
      case "skip":  skipPhase();    break;
    }
  },

  compact: function() {
    return View.hstack([
      View.icon(phaseIcon(), { size: 12, color: phaseColor() }),
      View.text(formatTime(remainingSeconds), { style: "monospaced", color: "white" }),
      isRunning ? View.circularProgress(progressRatio(), { total: 1, lineWidth: 2, color: progressColor() }) : null
    ], { spacing: 6, align: "center" });
  },

  minimalCompact: {
    leading: function() {
      return View.frame(View.mascot({ size: 28 }), { width: 28, height: 28, alignment: "center" });
    },
    trailing: function() {
      return View.text(formatTime(remainingSeconds), { style: "monospacedSmall", color: "white" });
    },
    precedence: function() {
      return isRunning ? 1 : 0;
    }
  },

  expanded: function() {
    return View.hstack([
      View.mascot({ size: 50 }),
      View.vstack([
        View.text(phase === PHASE_FOCUS ? "Focus" : "Break", { style: "title", color: "white" }),
        View.text(formatTime(remainingSeconds), { style: "monospaced", color: "white" }),
        View.text(sessionsCompleted + " sessions today", { style: "footnote", color: "gray" })
      ], { spacing: 3, align: "leading" }),
      View.spacer(),
      View.button(View.icon(isRunning ? "pause.fill" : "play.fill", { size: 16, color: "white" }), "toggle")
    ], { spacing: 10, align: "center" });
  },

  fullExpanded: function() {
    var ratio = progressRatio();
    var a = ac();
    var time = formatTime(remainingSeconds);
    var label = statusLabel();
    var minsLeft = Math.ceil(remainingSeconds / 60);

    // Left: mascot ~35%
    var leftPanel = View.frame(
      View.mascot({ size: 130 }),
      { width: 150, maxHeight: 9999, alignment: "center" }
    );

    // Right: timer + progress + controls ~80%
    var rightPanel = View.vstack([

      // Timer + status
      View.vstack([
        View.text(time, { style: "largeTitle", color: "white" }),
        View.text(label, { style: "caption", color: a })
      ], { spacing: 2, align: "center" }),

      // Progress
      View.progress(ratio, { total: 1, color: a }),
      View.hstack([
        View.text(phase === PHASE_FOCUS ? "Focus" : "Break", { style: "footnote", color: { r: 1, g: 1, b: 1, a: 0.35 } }),
        View.spacer(),
        View.text(minsLeft + "m left", { style: "footnote", color: { r: 1, g: 1, b: 1, a: 0.35 } })
      ], { spacing: 4, align: "center" }),

      // Controls + sessions
      View.hstack([
        View.spacer(),
        controlBtn("arrow.counterclockwise", "reset", 15, false),
        controlBtn(isRunning ? "pause.fill" : "play.fill", "toggle", 18, true),
        controlBtn("forward.fill", "skip", 15, false),
        View.spacer(),
        View.icon("checkmark.circle.fill", { size: 9, color: a }),
        View.text(sessionsCompleted + "", { style: "caption", color: { r: 1, g: 1, b: 1, a: 0.4 } })
      ], { spacing: 14, align: "center" })

    ], { spacing: 6, align: "leading" });

    return View.hstack([
      leftPanel,
      View.frame(rightPanel, { maxWidth: 9999, maxHeight: 9999 })
    ], { spacing: 8, align: "center" });
  }
});
