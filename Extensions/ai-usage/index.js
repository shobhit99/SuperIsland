"use strict";

const LOW_THRESHOLD = 25;
const VERY_LOW_THRESHOLD = 10;

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

function sourceLabel(source) {
  switch (source) {
    case "oauth-api":
      return "OAuth API";
    case "local-summary":
      return "Local summary";
    case "auth-token":
      return "Auth token";
    case "stats-cache":
      return "Stats cache";
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
      detail: withSource("Not available", source)
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
      detail: withSource("Unlimited", source)
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
      detail: withSource("No window data", source)
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
    detail: withSource(window && window.windowLabel ? window.windowLabel : "Usage window", source)
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
      detail: withSource("Not available", source)
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
    detail: withSource(detail, source)
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

function usageSnapshot() {
  const usage = DynamicIsland.system.getAIUsage();
  return usage && typeof usage === "object" ? usage : null;
}

DynamicIsland.registerModule({
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

    return View.vstack([
      View.text("AI Usage", { style: "title", color: "white" }),
      View.hstack([
        View.vstack([
          View.circularProgress(codex.progress, { total: 1, lineWidth: 6, color: codex.color }),
          View.text("Codex", { style: "caption", color: "gray" }),
          View.text(codex.text, { style: "monospaced", color: codex.color }),
          View.text(`Week ${percentLabel(codex.weeklyRemaining)}`, { style: "footnote", color: "gray" }),
          View.text(`Session ${percentLabel(codex.sessionRemaining)}`, { style: "footnote", color: "gray" })
        ], { spacing: 4, align: "center" }),
        View.vstack([
          View.circularProgress(claude.progress, { total: 1, lineWidth: 6, color: claude.color }),
          View.text("Claude", { style: "caption", color: "gray" }),
          View.text(claude.text, { style: "monospaced", color: claude.color }),
          View.text(`Week ${percentLabel(claude.weeklyRemaining)}`, { style: "footnote", color: "gray" }),
          View.text(`Session ${percentLabel(claude.sessionRemaining)}`, { style: "footnote", color: "gray" })
        ], { spacing: 4, align: "center" })
      ], { spacing: 20, align: "center", distribution: "fillEqually" })
    ], { spacing: 10, align: "center" });
  }
});
