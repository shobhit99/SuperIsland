"use strict";

const LOW_THRESHOLD = 25;
const VERY_LOW_THRESHOLD = 10;
let selectedProviderInMemory = "codex";
let usagePageInMemory = "overview";

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function toNumber(value, fallback) {
  if (value === null || value === undefined || value === "") {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function asObject(value) {
  return value && typeof value === "object" ? value : null;
}

function colorForRemaining(remainingPercent) {
  if (remainingPercent <= VERY_LOW_THRESHOLD) return "red";
  if (remainingPercent <= LOW_THRESHOLD) return "orange";
  return "green";
}

function formatPercent(value) {
  return `${Math.round(clamp(value, 0, 100))}%`;
}

function percentLabel(value) {
  if (value === null || value === undefined) return "--%";
  return `${Math.round(clamp(value, 0, 100))}%`;
}

function timestampMillis(value) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value > 10000000000 ? value : value * 1000;
  }
  if (typeof value === "string" && value) {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function formatDuration(milliseconds) {
  const totalMinutes = Math.max(0, Math.ceil(milliseconds / 60000));
  if (totalMinutes < 60) return `${totalMinutes}m`;

  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (hours < 24) return `${hours}h ${minutes}m`;

  const days = Math.floor(hours / 24);
  return `${days}d ${hours % 24}h`;
}

function formatPacePercent(value) {
  const rounded = Math.round(Math.max(0, value) * 10) / 10;
  return `${Number.isInteger(rounded) ? rounded.toFixed(0) : rounded.toFixed(1)}%`;
}

function sourceLabel(source) {
  switch (source) {
    case "oauth-api":
      return "OAuth API";
    case "oauth-api-stale":
      return "OAuth API (stale)";
    case "local-summary":
      return "Local summary";
    case "auth-token":
      return "Auth token";
    case "stats-cache":
      return "Stats cache";
    case "rate-limited":
      return "Rate limited";
    case "auth-error":
      return "Auth error";
    case "no-token":
      return "Not signed in";
    case "token-expired":
      return "Token expired";
    case "server-error":
      return "Server error";
    case "network-error":
      return "Offline";
    case "parse-error":
      return "Bad response";
    case "unavailable":
      return "Unavailable";
    default:
      return null;
  }
}

function withSource(detail, source) {
  const sourceText = sourceLabel(source);
  if (!sourceText) return detail;
  return detail ? `${detail} | ${sourceText}` : sourceText;
}

function pickCodexWindow(codex) {
  const primary = asObject(codex.primary);
  const secondary = asObject(codex.secondary);

  if (!primary && !secondary) return null;
  if (primary && !secondary) return primary;
  if (!primary && secondary) return secondary;

  const primaryRemaining = toNumber(primary.remainingPercent, 101);
  const secondaryRemaining = toNumber(secondary.remainingPercent, 101);
  return primaryRemaining <= secondaryRemaining ? primary : secondary;
}

function codexRemainingPercent(codexWindow) {
  if (!codexWindow) return null;

  const remaining = toNumber(codexWindow.remainingPercent, null);
  if (remaining !== null) return clamp(remaining, 0, 100);

  const used = toNumber(codexWindow.usedPercent, null);
  if (used !== null) return clamp(100 - used, 0, 100);

  return null;
}

function codexUsageStats(codex) {
  const windows = [];
  const primary = asObject(codex.primary);
  const secondary = asObject(codex.secondary);

  [primary, secondary].forEach((window) => {
    if (!window) return;
    const remainingPercent = codexRemainingPercent(window);
    if (remainingPercent === null) return;
    windows.push({
      remainingPercent,
      windowMinutes: toNumber(window.windowMinutes, 0)
    });
  });

  if (windows.length === 0) {
    return { weeklyRemaining: null, sessionRemaining: null };
  }

  windows.sort((a, b) => a.windowMinutes - b.windowMinutes);
  const session = windows[0];
  const weekly = windows[windows.length - 1];

  return {
    weeklyRemaining: weekly ? Math.round(clamp(weekly.remainingPercent, 0, 100)) : null,
    sessionRemaining: session ? Math.round(clamp(session.remainingPercent, 0, 100)) : null
  };
}

function codexModel(usage) {
  const codex = asObject(usage && usage.codex);
  const source = codex && typeof codex.source === "string" ? codex.source : null;
  if (!codex || codex.available !== true) {
    return {
      title: "Codex",
      text: "--",
      remaining: 0,
      progress: 0,
      color: "gray",
      weeklyRemaining: null,
      sessionRemaining: null,
      detail: withSource("Not available", source),
      resetAt: null,
      hasMeasuredQuota: false,
      isUnlimited: false
    };
  }

  if (codex.unlimited === true) {
    return {
      title: "Codex",
      text: "∞",
      remaining: 100,
      progress: 1,
      color: "green",
      weeklyRemaining: 100,
      sessionRemaining: 100,
      detail: withSource("Unlimited", source),
      resetAt: null,
      hasMeasuredQuota: false,
      isUnlimited: true
    };
  }

  const window = pickCodexWindow(codex);
  const remaining = codexRemainingPercent(window);
  const usageStats = codexUsageStats(codex);

  if (remaining === null) {
    return {
      title: "Codex",
      text: "--",
      remaining: 0,
      progress: 0,
      color: "gray",
      weeklyRemaining: usageStats.weeklyRemaining,
      sessionRemaining: usageStats.sessionRemaining,
      detail: withSource("No window data", source),
      resetAt: null,
      hasMeasuredQuota: false,
      isUnlimited: false
    };
  }

  return {
    title: "Codex",
    text: formatPercent(remaining),
    remaining,
    progress: remaining / 100,
    color: colorForRemaining(remaining),
    weeklyRemaining: usageStats.weeklyRemaining,
    sessionRemaining: usageStats.sessionRemaining,
    detail: withSource(window && window.windowLabel ? window.windowLabel : "Usage window", source),
    resetAt: window ? window.resetsAt : null,
    hasMeasuredQuota: true,
    isUnlimited: false
  };
}

function claudeModel(usage) {
  const claude = asObject(usage && usage.claude);
  const source = claude && typeof claude.source === "string" ? claude.source : null;
  if (!claude || claude.available !== true) {
    return {
      title: "Claude",
      text: "--",
      remaining: 0,
      progress: 0,
      color: "gray",
      weeklyRemaining: null,
      sessionRemaining: null,
      detail: withSource("Not available", source),
      resetAt: null,
      hasMeasuredQuota: false,
      isUnlimited: false
    };
  }

  const status = typeof claude.status === "string" ? claude.status : "allowed";
  const statusLabel = typeof claude.statusLabel === "string" ? claude.statusLabel : null;
  const explicitRemaining = toNumber(claude.remainingPercent, null);
  const explicitWeeklyRemaining = toNumber(claude.weeklyRemainingPercent, null);
  const explicitSessionRemaining = toNumber(claude.currentSessionRemainingPercent, null);
  const hoursTillReset = toNumber(claude.hoursTillReset, null);

  let remaining;
  let detail;

  if (explicitRemaining !== null) {
    remaining = clamp(explicitRemaining, 0, 100);
    detail = statusLabel || "Usage data";
  } else if (status === "rejected") {
    remaining = 0;
    detail = statusLabel || "Blocked";
  } else if (status === "allowed_warning") {
    const warningLooksLow = statusLabel && /(low|limit|blocked|exceeded|critical)/i.test(statusLabel);
    if (warningLooksLow) {
      remaining = 20;
      detail = statusLabel || "Low remaining";
    } else if (hoursTillReset !== null) {
      if (hoursTillReset <= 1) {
        remaining = 8;
      } else if (hoursTillReset <= 3) {
        remaining = 22;
      } else {
        remaining = 55;
      }
      detail = statusLabel || `${Math.ceil(hoursTillReset)}h to reset`;
    } else {
      remaining = 55;
      detail = statusLabel || "Warning";
    }
  } else if (hoursTillReset !== null) {
    if (hoursTillReset <= 1) {
      remaining = 8;
    } else if (hoursTillReset <= 3) {
      remaining = 22;
    } else {
      remaining = 65;
    }
    detail = statusLabel || `${Math.ceil(hoursTillReset)}h to reset`;
  } else {
    remaining = 65;
    detail = statusLabel || "Available";
  }

  return {
    title: "Claude",
    text: formatPercent(remaining),
    remaining,
    progress: remaining / 100,
    color: colorForRemaining(remaining),
    weeklyRemaining: explicitWeeklyRemaining !== null ? Math.round(clamp(explicitWeeklyRemaining, 0, 100)) : null,
    sessionRemaining: explicitSessionRemaining !== null ? Math.round(clamp(explicitSessionRemaining, 0, 100)) : null,
    detail: withSource(detail, source),
    resetAt: claude.resetAt,
    hasMeasuredQuota: explicitRemaining !== null || status === "rejected",
    isUnlimited: false
  };
}

function ringWithPercent(model, lineWidth) {
  return View.hstack([
    View.circularProgress(model.progress, {
      total: 1,
      lineWidth,
      color: model.color
    }),
    View.text(model.text, {
      style: "monospacedSmall",
      color: model.color
    })
  ], { spacing: 5, align: "center" });
}

function paceMetrics(model, nowMs = Date.now()) {
  const resetMs = timestampMillis(model.resetAt);
  const unavailable = {
    resetText: "--",
    todayLabel: "Budget to midnight",
    todayText: "--",
    paceLabel: "Even pace / day",
    paceText: "--"
  };

  if (model.isUnlimited) {
    return {
      resetText: "No cap",
      todayLabel: "Budget to midnight",
      todayText: "Unlimited",
      paceLabel: "Even pace / day",
      paceText: "Unlimited"
    };
  }

  if (!model.hasMeasuredQuota || resetMs === null || resetMs <= nowMs) {
    return unavailable;
  }

  const remainingMs = resetMs - nowMs;
  const nextMidnight = new Date(nowMs);
  nextMidnight.setHours(24, 0, 0, 0);
  const resetBeforeMidnight = resetMs <= nextMidnight.getTime();

  if (resetBeforeMidnight) {
    return {
      resetText: formatDuration(remainingMs),
      todayLabel: "Budget until reset",
      todayText: formatPacePercent(model.remaining),
      paceLabel: "Total remaining",
      paceText: formatPacePercent(model.remaining)
    };
  }

  const untilMidnightMs = nextMidnight.getTime() - nowMs;
  return {
    resetText: formatDuration(remainingMs),
    todayLabel: "Budget to midnight",
    todayText: formatPacePercent(model.remaining * untilMidnightMs / remainingMs),
    paceLabel: "Even pace / day",
    paceText: formatPacePercent(model.remaining * 86400000 / remainingMs)
  };
}

function paceMetric(label, value) {
  return View.frame(
    View.vstack([
      View.text(label, { style: "caption", color: "gray" }),
      View.text(value, { style: "monospaced", color: "white" })
    ], { spacing: 4, align: "center" }),
    { maxWidth: 1000 }
  );
}

function usageOverviewCard(model, actionID) {
  const card = View.vstack([
    View.circularProgress(model.progress, { total: 1, lineWidth: 6, color: model.color }),
    View.text(model.title, { style: "caption", color: "gray" }),
    View.text(model.text, { style: "monospaced", color: model.color }),
    View.text(`Week ${percentLabel(model.weeklyRemaining)}`, { style: "footnote", color: "gray" }),
    View.text(`Session ${percentLabel(model.sessionRemaining)}`, { style: "footnote", color: "gray" })
  ], { spacing: 4, align: "center" });

  return View.button(
    View.frame(
      View.cornerRadius(
        View.background(
          View.padding(card, { edges: "all", amount: 8 }),
          { r: 0.08, g: 0.08, b: 0.09, a: 0.45 }
        ),
        10
      ),
      { maxWidth: 1000 }
    ),
    actionID
  );
}

function usageOverview(codex, claude) {
  return View.vstack([
    View.text("AI Usage", { style: "title", color: "white" }),
    View.hstack([
      usageOverviewCard(codex, "select-codex"),
      usageOverviewCard(claude, "select-claude")
    ], { spacing: 20, align: "center", distribution: "fillEqually" })
  ], { spacing: 10, align: "center" });
}

function usagePacePage(model) {
  const pace = paceMetrics(model);
  const overviewButton = View.button(
    View.frame(
      View.cornerRadius(
        View.background(
          View.padding(View.text("‹ Overview", { style: "caption", color: "gray" }), { edges: "all", amount: 5 }),
          { r: 0.12, g: 0.12, b: 0.14, a: 0.8 }
        ),
        7
      ),
      { width: 72, height: 28 }
    ),
    "show-overview"
  );
  const header = View.hstack([
    overviewButton,
    View.frame(
      View.text(`${model.title} · Usage pace`, { style: "title", color: "white" }),
      { maxWidth: 1000, alignment: "center" }
    ),
    View.frame(View.text("", { style: "caption", color: "gray" }), { width: 72, height: 28 })
  ], { spacing: 8, align: "center" });
  const panel = View.cornerRadius(
    View.background(
      View.padding(
        View.vstack([
          View.hstack([
            View.spacer(),
            View.text(`Resets in ${pace.resetText}`, { style: "footnote", color: "gray" })
          ], { spacing: 8, align: "center" }),
          View.hstack([
            paceMetric(pace.todayLabel, pace.todayText),
            paceMetric(pace.paceLabel, pace.paceText),
            paceMetric("Available now", model.text)
          ], { spacing: 8, align: "center", distribution: "fillEqually" })
        ], { spacing: 8, align: "leading" }),
        { edges: "all", amount: 12 }
      ),
      { r: 0.1, g: 0.1, b: 0.12, a: 0.92 }
    ),
    12
  );

  return View.vstack([header, panel], { spacing: 10, align: "leading" });
}

function usageSnapshot() {
  const usage = SuperIsland.system.getAIUsage();
  return usage && typeof usage === "object" ? usage : null;
}

SuperIsland.registerModule({
  compact() {
    const usage = usageSnapshot();
    const codex = codexModel(usage);
    const claude = claudeModel(usage);

    return View.hstack([
      ringWithPercent(codex, 2.5),
      View.spacer(),
      ringWithPercent(claude, 2.5)
    ], { spacing: 8, align: "center" });
  },

  minimalCompact: {
    leading() {
      const usage = usageSnapshot();
      const codex = codexModel(usage);
      return View.circularProgress(codex.progress, {
        total: 1,
        lineWidth: 3,
        color: codex.color
      });
    },

    trailing() {
      const usage = usageSnapshot();
      const claude = claudeModel(usage);
      return View.frame(
        View.circularProgress(claude.progress, {
          total: 1,
          lineWidth: 3,
          color: claude.color
        }),
        { maxWidth: 1000, alignment: "trailing" }
      );
    }
  },

  expanded() {
    const usage = usageSnapshot();
    const codex = codexModel(usage);
    const claude = claudeModel(usage);

    return View.hstack([
      View.vstack([
        View.text("Codex", { style: "caption", color: "gray" }),
        View.hstack([
          View.circularProgress(codex.progress, { total: 1, lineWidth: 4, color: codex.color }),
          View.text(codex.text, { style: "monospaced", color: codex.color })
        ], { spacing: 8, align: "center" })
      ], { spacing: 4, align: "center" }),

      View.vstack([
        View.text("Claude", { style: "caption", color: "gray" }),
        View.hstack([
          View.circularProgress(claude.progress, { total: 1, lineWidth: 4, color: claude.color }),
          View.text(claude.text, { style: "monospaced", color: claude.color })
        ], { spacing: 8, align: "center" })
      ], { spacing: 4, align: "center" })
    ], { spacing: 12, align: "center", distribution: "fillEqually" });
  },

  fullExpanded() {
    const usage = usageSnapshot();
    const codex = codexModel(usage);
    const claude = claudeModel(usage);

    const selected = selectedProviderInMemory === "claude" ? claude : codex;
    return usagePageInMemory === "pace"
      ? usagePacePage(selected)
      : usageOverview(codex, claude);
  },

  onAction(actionID) {
    if (actionID === "select-codex" || actionID === "select-claude") {
      selectedProviderInMemory = actionID === "select-claude" ? "claude" : "codex";
      usagePageInMemory = "pace";
      return;
    }

    if (actionID === "show-overview") {
      usagePageInMemory = "overview";
    }
  }
});
