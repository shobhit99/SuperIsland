# AI Usage Rings Extension

Displays Codex + Claude usage/availability inside DynamicIsland with circular indicators.

## Colors

- Green: healthy/available
- Orange: low
- Red: very low / blocked

## Permissions

- `usage` (required for `DynamicIsland.system.getAIUsage()`)

## Data Sources

- Codex:
  - `~/.codex/usage-summary.json` or `~/.codex/usage/summary.json`
  - fallback: ChatGPT OAuth usage API (`https://chatgpt.com/backend-api/wham/usage`) using token from `~/.codex/auth.json`
- Claude:
  - `~/.claude/usage-summary.json` or `~/.config/claude/usage-summary.json`
  - fallback: Anthropic OAuth usage API (`https://api.anthropic.com/api/oauth/usage`) using token from:
    - `~/.claude/.credentials.json` / `~/.claude/credentials.json`
    - macOS keychain service `Claude Code-credentials`
  - last fallback: `~/.claude/stats-cache.json`

## Refresh Behavior

- The native usage provider cache refreshes every 5 minutes.
- Codex still updates from local summary / OAuth API data.
- Claude reads session (`five_hour`) and weekly (`seven_day*`) windows from OAuth usage when available.
- Week/session values no longer mirror overall remaining when source data is missing (they show `--%`).
