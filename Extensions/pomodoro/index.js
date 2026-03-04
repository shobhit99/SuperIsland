let remaining = 25 * 60;
let totalDuration = 25 * 60;
let isRunning = false;
let isBreak = false;
let sessionsCompleted = 0;
let timerID = null;

function tick() {
  if (!isRunning) return;
  remaining -= 1;
  if (remaining <= 0) {
    timerCompleted();
  }
}

function timerCompleted() {
  isRunning = false;
  if (timerID) {
    clearInterval(timerID);
    timerID = null;
  }

  if (!isBreak) {
    sessionsCompleted += 1;
    DynamicIsland.store.set("sessionsCompleted", sessionsCompleted);
  }

  isBreak = !isBreak;
  const breakDuration = (DynamicIsland.settings.get("breakDuration") || 5) * 60;
  const workDuration = (DynamicIsland.settings.get("workDuration") || 25) * 60;
  totalDuration = isBreak ? breakDuration : workDuration;
  remaining = totalDuration;

  if (DynamicIsland.settings.get("notifyOnComplete") !== false) {
    DynamicIsland.notifications.send({
      title: isBreak ? "Time for a break!" : "Back to focus",
      body: isBreak ? `Sessions today: ${sessionsCompleted}` : "Break finished",
      sound: DynamicIsland.settings.get("playSound") !== false
    });
  }

  DynamicIsland.playFeedback("success");
}

DynamicIsland.registerModule({
  onActivate() {
    sessionsCompleted = DynamicIsland.store.get("sessionsCompleted") || 0;
    totalDuration = (DynamicIsland.settings.get("workDuration") || 25) * 60;
    remaining = totalDuration;
  },

  onDeactivate() {
    if (timerID) {
      clearInterval(timerID);
      timerID = null;
    }
    DynamicIsland.store.set("sessionsCompleted", sessionsCompleted);
  },

  onAction(actionID, value) {
    switch (actionID) {
      case "toggleTimer":
        isRunning = !isRunning;
        if (isRunning) {
          if (timerID) clearInterval(timerID);
          timerID = setInterval(tick, 1000);
          DynamicIsland.island.activate(false);
        } else if (timerID) {
          clearInterval(timerID);
          timerID = null;
        }
        break;
      case "reset":
        isRunning = false;
        if (timerID) clearInterval(timerID);
        timerID = null;
        remaining = totalDuration;
        break;
      case "skip":
        timerCompleted();
        break;
      case "notifications":
        DynamicIsland.settings.set("notifyOnComplete", !!value);
        break;
    }
  },

  compact() {
    const progress = 1 - remaining / totalDuration;
    const icon = isBreak ? "cup.and.saucer.fill" : "timer";
    const color = isBreak ? "green" : "white";

    return View.hstack([
      View.icon(icon, { size: 11, color }),
      View.timerText(remaining, { style: "monospacedSmall" }),
      View.spacer(),
      isRunning ? View.circularProgress(progress, { lineWidth: 2, color }) : View.icon("play.fill", { size: 9, color })
    ], { spacing: 6 });
  },

  minimalCompact: {
    leading() {
      const progress = 1 - remaining / totalDuration;
      const color = isBreak ? "green" : "white";
      return View.circularProgress(progress, { lineWidth: 3, color });
    },

    trailing() {
      return View.button(
        View.icon(isRunning ? "pause.fill" : "play.fill", { size: 11 }),
        "toggleTimer"
      );
    }
  },

  expanded() {
    const progress = 1 - remaining / totalDuration;
    const color = isBreak ? "green" : "white";

    return View.hstack([
      View.circularProgress(progress, { lineWidth: 4, color }),
      View.vstack([
        View.text(isBreak ? "Break Time" : "Focus Session", { style: "title" }),
        View.timerText(remaining),
        View.text(`${sessionsCompleted} sessions today`, { style: "footnote", color: "gray" })
      ], { spacing: 3, align: "leading" }),
      View.spacer(),
      View.button(
        View.icon(isRunning ? "pause.fill" : "play.fill", { size: 18 }),
        "toggleTimer"
      )
    ], { spacing: 12 });
  },

  fullExpanded() {
    const progress = 1 - remaining / totalDuration;
    const color = isBreak ? "green" : "white";

    return View.vstack([
      View.hstack([
        View.vstack([
          View.text(isBreak ? "Break" : "Pomodoro", { style: "largeTitle" }),
          View.timerText(remaining),
          View.text(`${sessionsCompleted} sessions completed`, { style: "footnote", color: "gray" })
        ], { spacing: 4, align: "leading" }),
        View.spacer(),
        View.circularProgress(progress, { lineWidth: 6, color })
      ], { spacing: 12 }),
      View.progress(progress, { color }),
      View.hstack([
        View.button(View.icon("arrow.counterclockwise", { size: 16 }), "reset"),
        View.button(View.icon(isRunning ? "pause.circle.fill" : "play.circle.fill", { size: 30 }), "toggleTimer"),
        View.button(View.icon("forward.fill", { size: 16 }), "skip")
      ], { spacing: 18 }),
      View.toggle(DynamicIsland.settings.get("notifyOnComplete") !== false, "Notifications", "notifications")
    ], { spacing: 12 });
  }
});
