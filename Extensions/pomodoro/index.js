"use strict";

const PHASE_FOCUS = "focus";
const PHASE_BREAK = "break";

let phase = PHASE_FOCUS;
let isRunning = false;
let remainingSeconds = 0;
let timerID = null;
let sessionsCompleted = 0;

function toNumber(value, fallback) {
  if (value === null || value === undefined || value === "") {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function settingNumber(key, fallback) {
  return toNumber(DynamicIsland.settings.get(key), fallback);
}

function settingBool(key, fallback) {
  const value = DynamicIsland.settings.get(key);
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
  const safe = Math.max(0, Math.floor(seconds));
  const minutes = Math.floor(safe / 60);
  const secs = safe % 60;
  return `${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;
}

function saveState() {
  DynamicIsland.store.set("phase", phase);
  DynamicIsland.store.set("isRunning", isRunning);
  DynamicIsland.store.set("remainingSeconds", remainingSeconds);
  DynamicIsland.store.set("sessionsCompleted", sessionsCompleted);
}

function loadState() {
  sessionsCompleted = toNumber(DynamicIsland.store.get("sessionsCompleted"), 0);

  const storedPhase = DynamicIsland.store.get("phase");
  phase = storedPhase === PHASE_BREAK ? PHASE_BREAK : PHASE_FOCUS;

  const storedRemaining = toNumber(DynamicIsland.store.get("remainingSeconds"), currentPhaseDuration());
  remainingSeconds = Math.max(0, Math.min(storedRemaining, currentPhaseDuration()));

  const storedRunning = DynamicIsland.store.get("isRunning");
  isRunning = typeof storedRunning === "boolean" ? storedRunning : false;

  if (remainingSeconds <= 0) {
    remainingSeconds = currentPhaseDuration();
  }
}

function stopTimer() {
  if (timerID !== null) {
    clearInterval(timerID);
    timerID = null;
  }
}

function startTimer() {
  if (timerID !== null) return;

  timerID = setInterval(() => {
    tick();
  }, 1000);
}

function revealIsland() {
  DynamicIsland.island.activate(false);
  // Reinforce activation in case the first request races with host/menu state transitions.
  setTimeout(() => DynamicIsland.island.activate(false), 120);
  // Keep it visible for at least 2 seconds, then allow it to collapse.
  setTimeout(() => DynamicIsland.island.dismiss(), 2000);
}

function setRunning(nextRunning) {
  isRunning = nextRunning;
  if (isRunning) {
    startTimer();
  } else {
    stopTimer();
  }
  saveState();
}

function switchPhase() {
  const wasFocus = phase === PHASE_FOCUS;

  if (wasFocus) {
    sessionsCompleted += 1;
    DynamicIsland.store.set("sessionsCompleted", sessionsCompleted);
  }

  phase = wasFocus ? PHASE_BREAK : PHASE_FOCUS;
  remainingSeconds = currentPhaseDuration();

  if (settingBool("notifyOnComplete", true)) {
    DynamicIsland.notifications.send({
      title: wasFocus ? "Break started" : "Break ended",
      body: wasFocus
        ? `Session ${sessionsCompleted} complete. Break is now running.`
        : "Break ended. Start your next focus session when ready.",
      sound: settingBool("playSound", true)
    });
  }

  DynamicIsland.playFeedback("success");

  if (wasFocus) {
    // Focus -> Break: auto-start break immediately.
    setRunning(true);
    revealIsland();
  } else {
    // Break -> Focus: do not auto-start focus; user starts manually.
    setRunning(false);
    // Surface completion by expanding the island for manual focus restart.
    revealIsland();
  }

  saveState();
}

function tick() {
  if (!isRunning) return;

  remainingSeconds -= 1;

  if (remainingSeconds <= 0) {
    remainingSeconds = 0;
    switchPhase();
    return;
  }

  if (remainingSeconds % 15 === 0) {
    saveState();
  }
}

function resetToFocus() {
  phase = PHASE_FOCUS;
  remainingSeconds = focusDurationSeconds();
  setRunning(false);
  saveState();
}

function skipPhase() {
  switchPhase();
}

function progressRatio() {
  const total = Math.max(1, currentPhaseDuration());
  return 1 - remainingSeconds / total;
}

function phaseIcon() {
  if (phase === PHASE_BREAK) return "cup.and.saucer.fill";
  if (remainingSeconds <= 60) return "flame.fill";
  return "brain.head.profile";
}

function phaseColor() {
  if (phase === PHASE_BREAK) return "green";
  if (remainingSeconds <= 60) return "red";
  return "white";
}

function progressColor() {
  return phase === PHASE_BREAK ? "green" : phaseColor();
}

DynamicIsland.registerModule({
  onActivate() {
    loadState();
    if (isRunning) {
      startTimer();
    }
  },

  onDeactivate() {
    stopTimer();
    isRunning = false;
    saveState();
  },

  onAction(actionID) {
    switch (actionID) {
      case "toggle":
        setRunning(!isRunning);
        if (isRunning) {
          revealIsland();
        }
        break;
      case "reset":
        resetToFocus();
        break;
      case "skip":
        skipPhase();
        break;
      default:
        break;
    }
  },

  compact() {
    const ratio = progressRatio();

    return View.hstack([
      View.icon(phaseIcon(), { size: 12, color: phaseColor() }),
      View.text(formatTime(remainingSeconds), { style: "monospaced", color: "white" }),
      isRunning ? View.circularProgress(ratio, { total: 1, lineWidth: 2, color: progressColor() }) : null
    ], { spacing: 6, align: "center" });
  },

  minimalCompact: {
    leading() {
      return View.circularProgress(progressRatio(), {
        total: 1,
        lineWidth: 3,
        color: progressColor()
      });
    },

    trailing() {
      return View.button(
        View.icon(isRunning ? "pause.fill" : "play.fill", { size: 11, color: "white" }),
        "toggle"
      );
    }
  },

  expanded() {
    return View.hstack([
      View.circularProgress(progressRatio(), {
        total: 1,
        lineWidth: 4,
        color: progressColor()
      }),
      View.vstack([
        View.text(phase === PHASE_FOCUS ? "Focus" : "Break", { style: "title", color: "white" }),
        View.text(formatTime(remainingSeconds), { style: "monospaced", color: "white" }),
        View.text(`${sessionsCompleted} sessions today`, { style: "footnote", color: "gray" })
      ], { spacing: 3, align: "leading" }),
      View.spacer(),
      View.button(
        View.icon(isRunning ? "pause.fill" : "play.fill", { size: 16, color: "white" }),
        "toggle"
      )
    ], { spacing: 10, align: "center" });
  },

  fullExpanded() {
    return View.vstack([
      View.hstack([
        View.text(phase === PHASE_FOCUS ? "Focus Session" : "Break Time", { style: "title", color: "white" }),
        View.spacer(),
        View.text(formatTime(remainingSeconds), { style: "monospaced", color: "white" })
      ], { spacing: 8, align: "center" }),
      View.progress(progressRatio(), { total: 1, color: progressColor() }),
      View.hstack([
        View.button(View.icon("arrow.counterclockwise", { size: 16, color: "white" }), "reset"),
        View.button(View.icon(isRunning ? "pause.circle.fill" : "play.circle.fill", { size: 30, color: "white" }), "toggle"),
        View.button(View.icon("forward.fill", { size: 16, color: "white" }), "skip")
      ], { spacing: 24, align: "center" }),
      View.hstack([
        View.text("Sessions today", { style: "footnote", color: "gray" }),
        View.spacer(),
        View.text(String(sessionsCompleted), { style: "monospaced", color: "white" })
      ], { spacing: 8, align: "center" })
    ], { spacing: 10, align: "leading" });
  }
});
