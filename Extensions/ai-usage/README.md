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
  - fallback: `~/.claude/stats-cache.json`
