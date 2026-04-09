# Contributing to SuperIsland

Thanks for taking the time to contribute. Here's everything you need to get going.

---

## Getting started

```bash
git clone https://github.com/shobhit99/superisland.git
cd superisland
xcodegen generate
open SuperIsland.xcodeproj
```

Run the `SuperIsland` scheme on your Mac. Accessibility permission is required for the island window to sit above other apps.

---

## What to work on

Check the [Issues](https://github.com/shobhit99/superisland/issues) tab. Issues labelled `good first issue` are a good starting point. For anything larger — new modules, architecture changes — open an issue first so we can align before you spend time on it.

---

## Making changes

- Branch off `main`: `git checkout -b your-feature`
- Keep commits focused. One thing per commit.
- Run the app and manually test your change before opening a PR.
- If you add a new module, follow the existing module pattern: a `Manager` singleton with `@Published` state, a `CompactView`, and an `ExpandedView`. Register the module in `ModuleType`.

---

## Pull requests

- Target `main`
- Fill in what changed and why — a screenshot or screen recording goes a long way for UI changes
- Keep PRs small and reviewable. Large refactors should be discussed in an issue first

---

## Adding extensions

Extensions are the easiest way to contribute without touching Swift. See [dynamicisland.app/docs](https://dynamicisland.app/docs) or [EXTENSIONS.md](EXTENSIONS.md) for a full guide. Drop your extension in `Extensions/` and it will be picked up automatically during development.

---

## Code style

- Swift: follow existing conventions — no force unwraps, `@MainActor` on anything that touches UI, `guard` for early exits
- JavaScript (extensions): plain ES5-compatible JS or compile TS → JS before committing. No bundler required for simple extensions.
- No commented-out code, no debug `print` statements in PRs

---

## Reporting bugs

Open an issue with:
- macOS version and whether you have a notch
- Steps to reproduce
- What you expected vs what happened
