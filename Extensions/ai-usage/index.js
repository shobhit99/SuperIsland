const CARD_BACKGROUND = { r: 255, g: 255, b: 255, a: 0.08 };

function snapshot() {
  const usage = DynamicIsland.system.getAIUsage();
  if (usage && usage.codex && usage.claude) {
    return usage;
  }

  return {
    updatedAt: Math.floor(Date.now() / 1000),
    codex: { available: false },
    claude: { available: false }
  };
}

function codexPrimary(usage) {
  return usage.codex && usage.codex.primary ? usage.codex.primary : null;
}

function codexSecondary(usage) {
  return usage.codex && usage.codex.secondary ? usage.codex.secondary : null;
}

function codexColor(usage) {
  const primary = codexPrimary(usage);
  if (!primary) return "gray";
  if (primary.remainingPercent >= 50) return "green";
  if (primary.remainingPercent >= 25) return "orange";
  return "red";
}

function claudeColor(usage) {
  const claude = usage.claude || {};
  switch (claude.status) {
    case "allowed":
      return "green";
    case "allowed_warning":
      return "orange";
    case "rejected":
      return "red";
    default:
      return "gray";
  }
}

function percentText(value) {
  if (typeof value !== "number") return "--";
  return `${Math.round(Math.max(0, Math.min(value, 100)))}%`;
}

function hoursText(value) {
  if (typeof value !== "number") return "--";
  if (value <= 0) return "<1h";
  return `${value}h`;
}

function relativeReset(epochSeconds) {
  if (typeof epochSeconds !== "number") return "reset unknown";

  const deltaMinutes = Math.max(0, Math.round((epochSeconds * 1000 - Date.now()) / 60000));
  if (deltaMinutes < 60) return `reset ${deltaMinutes}m`;

  const hours = Math.floor(deltaMinutes / 60);
  if (hours < 24) return `reset ${hours}h`;

  const days = Math.floor(hours / 24);
  return `reset ${days}d`;
}

function updatedText(epochSeconds) {
  if (typeof epochSeconds !== "number") return "Updated just now";

  const deltaMinutes = Math.max(0, Math.round((Date.now() - epochSeconds * 1000) / 60000));
  if (deltaMinutes < 1) return "Updated just now";
  if (deltaMinutes < 60) return `Updated ${deltaMinutes}m ago`;

  const hours = Math.floor(deltaMinutes / 60);
  if (hours < 24) return `Updated ${hours}h ago`;

  return `Updated ${Math.floor(hours / 24)}d ago`;
}

function codexCompactText(usage) {
  const primary = codexPrimary(usage);
  return primary ? percentText(primary.remainingPercent) : "--";
}

function claudeCompactText(usage) {
  const claude = usage.claude || {};
  if (!claude.available) return "--";
  if (typeof claude.hoursTillReset === "number") return hoursText(claude.hoursTillReset);
  return claude.statusLabel || "--";
}

function claudeHeadline(usage) {
  const claude = usage.claude || {};
  if (!claude.available) return "No data";
  return claude.statusLabel || "Unknown";
}

function claudeSubline(usage) {
  const claude = usage.claude || {};
  if (!claude.available) return "Open Claude once to populate local state";
  if (claude.status === "allowed") return "Within limit";
  if (claude.status === "allowed_warning") return "Close to limit";
  return "Rate limited";
}

function codexHeadline(usage) {
  const primary = codexPrimary(usage);
  if (!primary) return "No data";
  return `${percentText(primary.remainingPercent)} left`;
}

function codexSubline(usage) {
  const primary = codexPrimary(usage);
  if (!primary) return "Open Codex once to populate local state";
  return `${primary.windowLabel} window`;
}

function card(title, headline, subline, accent) {
  return View.cornerRadius(
    View.background(
      View.padding(
        View.vstack([
          View.text(title, { style: "caption", color: "gray" }),
          View.text(headline, { style: "title", color: accent }),
          View.text(subline, { style: "footnote", color: "gray" })
        ], { spacing: 3, align: "leading" }),
        { amount: 8 }
      ),
      CARD_BACKGROUND
    ),
    12
  );
}

function codexWindowRow(label, window, accent) {
  if (!window) return null;

  return View.vstack([
    View.hstack([
      View.text(label, { style: "caption", color: "gray" }),
      View.spacer(),
      View.text(`${percentText(window.remainingPercent)} left`, { style: "caption", color: accent })
    ], { spacing: 6 }),
    View.progress(window.remainingPercent, { total: 100, color: accent }),
    View.text(relativeReset(window.resetsAt), { style: "footnote", color: "gray" })
  ], { spacing: 4, align: "leading" });
}

function fullCodexSection(usage) {
  const primary = codexPrimary(usage);
  const secondary = codexSecondary(usage);
  const accent = codexColor(usage);

  if (!primary && !secondary) {
    return card("Codex", "No data", "Open Codex and send one message", "gray");
  }

  return View.cornerRadius(
    View.background(
      View.padding(
        View.vstack([
          View.hstack([
            View.text("Codex", { style: "title" }),
            View.spacer(),
            View.text(codexHeadline(usage), { style: "caption", color: accent })
          ], { spacing: 6 }),
          codexWindowRow(primary ? primary.windowLabel : "Window", primary, accent),
          secondary ? codexWindowRow(secondary.windowLabel, secondary, "orange") : null
        ], { spacing: 8, align: "leading" }),
        { amount: 10 }
      ),
      CARD_BACKGROUND
    ),
    14
  );
}

function fullClaudeSection(usage) {
  const claude = usage.claude || {};
  const accent = claudeColor(usage);

  if (!claude.available) {
    return card("Claude", "No data", "Open Claude and hit a limit check once", "gray");
  }

  return View.cornerRadius(
    View.background(
      View.padding(
        View.vstack([
          View.hstack([
            View.text("Claude", { style: "title" }),
            View.spacer(),
            View.text(claudeHeadline(usage), { style: "caption", color: accent })
          ], { spacing: 6 }),
          View.text(claudeSubline(usage), { style: "body", color: accent }),
          View.text(
            typeof claude.hoursTillReset === "number"
              ? `reset ${hoursText(claude.hoursTillReset)}`
              : "reset unknown",
            { style: "footnote", color: "gray" }
          ),
          claude.model ? View.text(claude.model, { style: "footnote", color: "gray" }) : null
        ], { spacing: 6, align: "leading" }),
        { amount: 10 }
      ),
      CARD_BACKGROUND
    ),
    14
  );
}

DynamicIsland.registerModule({
  compact() {
    const usage = snapshot();

    return View.hstack([
      View.text("Cx", { style: "caption", color: "gray" }),
      View.text(codexCompactText(usage), { style: "monospacedSmall", color: codexColor(usage) }),
      View.spacer(),
      View.text("Cl", { style: "caption", color: "gray" }),
      View.text(claudeCompactText(usage), { style: "monospacedSmall", color: claudeColor(usage) })
    ], { spacing: 4 });
  },

  minimalCompact: {
    leading() {
      const usage = snapshot();
      const primary = codexPrimary(usage);
      const accent = codexColor(usage);

      if (!primary) {
        return View.icon("chevron.left.forwardslash.chevron.right", { size: 11, color: "gray" });
      }

      return View.circularProgress(primary.remainingPercent, {
        total: 100,
        lineWidth: 3,
        color: accent
      });
    },

    trailing() {
      const usage = snapshot();
      const claude = usage.claude || {};
      const accent = claudeColor(usage);
      const icon =
        claude.status === "rejected"
          ? "xmark.octagon.fill"
          : claude.status === "allowed_warning"
            ? "exclamationmark.triangle.fill"
            : "checkmark.circle.fill";

      return View.hstack([
        View.icon(icon, { size: 11, color: accent }),
        View.text(claudeCompactText(usage), { style: "caption", color: accent })
      ], { spacing: 3 });
    }
  },

  expanded() {
    const usage = snapshot();

    return View.hstack([
      card("Codex", codexHeadline(usage), codexSubline(usage), codexColor(usage)),
      card("Claude", claudeHeadline(usage), claudeSubline(usage), claudeColor(usage))
    ], { spacing: 10 });
  },

  fullExpanded() {
    const usage = snapshot();

    return View.vstack([
      fullCodexSection(usage),
      fullClaudeSection(usage),
      View.text(updatedText(usage.updatedAt), { style: "footnote", color: "gray" })
    ], { spacing: 10, align: "leading" });
  }
});
