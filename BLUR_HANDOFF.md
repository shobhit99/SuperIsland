# Blur / Expansion Handoff

## Status: IMPLEMENTED — awaiting user verification

## What Was Fixed

### Root Cause (confirmed)

There were two compounding bugs in `IslandContainerView.islandContent`:

**Bug 1 — ZStack order (critical)**
The blurred layer was on the **bottom** of the ZStack and the sharp layer was on **top**.
When `beginContentBlur` set `contentBlurOpacity = 1` and `contentSharpOpacity = 0` as
separate `@State` mutations, any render that happened between those two assignments showed
both layers at full opacity — with the sharp layer covering the blurred one.
Result: user sees sharp content, no blur.

**Bug 2 — Blur overlay rendered at compact size**
The blur was applied to `expandedIslandLayout(in: surfaceSize)` where `surfaceSize` starts at
compact dimensions (~188×34). The expanded layout clipped to 188×34 shows nearly empty
content (just the shoulder/header). Blurring nearly-empty dark content produces no visible
blur effect.

### Fix Applied (in `IslandContainerView.swift`)

1. **Removed `contentSharpOpacity`** — no longer needed. Sharp content is always-visible below.

2. **Flipped ZStack order** — sharp content on bottom (always full opacity), blurred overlay on
   TOP (fades in when transitioning, fades out when done). No race condition possible.

3. **Blur overlay renders at full target size** — when compact→expanded, the blurred overlay
   renders `expandedIslandLayout(in: blurTargetSize)` where `blurTargetSize` is the full
   expanded size (e.g. 408×88). The growing `clipShape(islandShape)` acts as a reveal mask:
   as the island expands, more of the full blurred expanded content is uncovered.
   This matches the reference: "blurred final content revealed during shell growth".

4. **Increased blur parameters**:
   - compact→expanded: `maxBlur: 28, holdDuration: 0.20, fadeDuration: 0.30`
   - other expand transitions: `maxBlur: 18, holdDuration: 0.10, fadeDuration: 0.22`

5. **Module cycler hidden during blur** — `contentBlurOpacity > 0 ? 0 : 1` opacity.

6. **Build**: `BUILD SUCCEEDED`

## Verification Target

The fix is correct if, during the first visible 80-150ms of expansion:
- the interior content is clearly blurry (soft glows of white text/icons on black)
- no sharp buttons/text are visible above it
- the shell overshoots slightly before settling

If content is still sharp on first visible frame, check:
1. Whether `contentBlurOpacity` is being set before the first render (`.onChange` timing)
2. Whether the `blurTargetSize` is computing the right value

## Files Changed

- `DynamicIsland/Views/IslandContainerView.swift` — blur logic + ZStack order fix
- `DynamicIsland/Utilities/Constants.swift` — overshoot/settle spring parameters (from prior agent, kept)
