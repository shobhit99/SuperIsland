# Onboarding Screen — Complete Redesign Prompt

## Overview

Rebuild the entire onboarding flow for **DynamicIsland** (macOS SwiftUI app). The onboarding is a **standalone window** — not a native macOS-feeling window. Think of it as a **compact, floating A4-ish black card** centered on screen. No title bar chrome. No toolbar. Just a clean, dark, self-contained panel with rounded corners and zero native window decorations visible.

The window should be approximately **840×620 points**, with `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, `.fullSizeContentView` style mask, `isOpaque = false`, `backgroundColor = .clear`. The content fills edge to edge. The overall shape is a large **continuous rounded rectangle (cornerRadius ~28)** clipped to the window bounds, so it reads like a floating dark card on the desktop.

---

## Global Design Language

### Color Palette (Dark Theme)
- **Background base**: Rich black `#0A0A0E` to deep charcoal `#111117` gradient — NOT pure `#000000`. Slightly warm-cool undertone.
- **Text primary**: `rgba(255, 255, 255, 0.94)` — near-white, not harsh pure white.
- **Text secondary**: `rgba(255, 255, 255, 0.62)` — muted descriptions.
- **Text tertiary**: `rgba(255, 255, 255, 0.38)` — hints, footnotes.
- **Accent — cool**: Soft periwinkle blue `#7DB4FF` → deeper `#4A87F5`.
- **Accent — warm**: Amber-gold `#F5A84B` → burnt orange `#E07832`.
- **Success green**: `#34D399` at 90% opacity.
- **Card surfaces**: `rgba(255, 255, 255, 0.05)` fill with `rgba(255, 255, 255, 0.08)` 1px border stroke.
- **Borders on interactive elements**: `rgba(255, 255, 255, 0.12)`.

### Background — Liquid Glass Purple Animated Gradient
Behind ALL content on every page, render a **subtle animated gradient layer** using blurred circles that drift slowly:

1. **Purple orb** — `#8B5CF6` at 18% opacity, ~380pt diameter, blurred at radius 50. Drifts diagonally top-left ↔ center-left over 10s `easeInOut` repeating forever with autoreversal.
2. **Indigo orb** — `#6366F1` at 14% opacity, ~300pt diameter, blurred at radius 44. Drifts from center-right ↔ bottom-right over 12s.
3. **Violet-pink orb** — `#A78BFA` at 10% opacity, ~260pt diameter, blurred at radius 38. Floats near bottom-center ↔ center over 14s.

These orbs sit **behind** a semi-opaque black gradient overlay (`#0A0A0E` at 85% opacity → `#111117` at 70% opacity, top-leading to bottom-trailing) so text remains perfectly legible. The gradient animation should feel like gentle, living aurora borealis behind dark glass — visible but never competing with text.

**Critical**: The gradient must NOT overlap or wash out any text or UI elements. It is atmospheric only.

### Typography
- Use `.system` font throughout (San Francisco via SwiftUI).
- Hero titles: **size 44–48, weight .bold** (for the Hello effect) or **size 36, weight .semibold** for section headers.
- Body text: **size 16–17, weight .regular**.
- Captions / chip labels: **size 12–13, weight .semibold**.
- All text centered unless in a card layout (then left-aligned).

### Page Indicator
A horizontal row of **3 capsule dots** at the top-right of the window:
- Active page: elongated capsule (width 28, height 8), white at 85%.
- Inactive pages: circle (width 8, height 8), white at 18%.
- Animate width change with `.spring(response: 0.34, dampingFraction: 0.82)`.
- Wrap in a pill-shaped container with `rgba(255,255,255, 0.06)` fill and `rgba(255,255,255, 0.12)` 1px border.

### Page Transitions
All page transitions use `.asymmetric`:
- Insertion: `.move(edge: .trailing).combined(with: .opacity)`
- Removal: `.move(edge: .leading).combined(with: .opacity)`
- With `.spring(response: 0.38, dampingFraction: 0.9)`.

---

## Page 1 — Welcome (Apple "Hello" Effect)

### Layout (top to bottom, centered)

#### 1. Hero "Hello" Text — Apple Boot Screen Effect
Recreate the iconic Apple "Hello" animation:
- The word **"Hello."** rendered in a large, elegant cursive/script style. Since SwiftUI doesn't ship with the exact Apple "Hello" font, approximate it:
  - Use a **custom handwriting-style feel** by rendering the text with `.font(.system(size: 72, weight: .thin, design: .serif))` or, ideally, use a custom font asset if available (e.g., a lightweight script font).
  - Alternatively, use the word in a **very large, thin-weight San Francisco** (size 64, `.ultraLight`) with letter spacing, giving it an elegant minimal feel — not cursive but Apple-keynote-clean.
- **Animation**: The text appears via a **gradient mask wipe** — a horizontal `LinearGradient` (from leading transparent to trailing opaque) that animates its start/end points from left to right over ~1.8 seconds with `easeInOut`, progressively revealing the text as if being written. This is the signature Apple Hello reveal.
- **Color**: The "Hello" text should use an **animated gradient fill** that shifts colors slowly:
  - Cycle through: soft purple `#A78BFA` → blue `#60A5FA` → teal `#2DD4BF` → pink `#F472B6` → back to purple.
  - Use an `AngularGradient` or `LinearGradient` with animated `startPoint`/`endPoint` shifting over 6 seconds, repeating.
  - Apply as `.foregroundStyle()` using the gradient, so the text itself shimmers with living color.

#### 2. Subtitle
Below the Hello text (after a 20pt spacer):
- **"Welcome to DynamicIsland"** — size 22, weight .semibold, text primary color.
- Below that (8pt gap): **"Your Mac's notch, reimagined."** — size 16, weight .regular, text secondary color.

#### 3. Feature Chips
A horizontal `HStack` of 3 small pill badges:
- "Calm by default" · "Notch-native" · "Made for macOS"
- Each chip: size 12 semibold, text tertiary, inside a capsule with `rgba(255,255,255, 0.05)` fill and `rgba(255,255,255, 0.10)` 1px border.
- Separated by 8pt spacing inside the HStack.

#### 4. Continue Button (bottom)
- "Continue" button using the accent cool gradient fill (`#7DB4FF` → `#4A87F5`).
- Pill shape, 46pt tall, horizontal padding 24.
- White text, size 15 semibold.
- On hover: scale 1.04, shadow intensifies (glow effect using cool accent at 28% opacity, radius 18).
- Spring animation on hover `.spring(response: 0.32, dampingFraction: 0.78)`.

---

## Page 2 — Permissions

### Layout (top to bottom)

#### 1. Section Header
- **"Let's set things up"** — size 34, weight .semibold, text primary. Centered.
- Below (8pt): **"Grant a few permissions so everything works smoothly."** — size 16, weight .regular, text secondary. Centered.

#### 2. Permission Cards — Scrollable List
A `VStack(spacing: 14)` of permission cards. Each card uses the **liquid glass icon style** inspired by the reference images — icons with iridescent gradient fills inside rounded-rectangle containers.

**Required permissions** (blocking — must be granted to continue):

| Permission | SF Symbol | Description |
|---|---|---|
| **Screen Recording** | `display` | "Lets DynamicIsland detect your active workspace and render over the notch." |
| **Accessibility** | `figure.stand` | "Required for gesture detection, window interaction, and productivity overlays." |

**Optional permissions** (can be skipped):

| Permission | SF Symbol | Description |
|---|---|---|
| **Calendar** | `calendar` | "Show upcoming events right in the island." |
| **Notifications** | `bell.badge` | "Mirror system notifications in the Dynamic Island." |
| **Microphone** | `mic.fill` | "Powers the audio spectrogram visualizer." |
| **Location** | `location.fill` | "Displays local weather information." |
| **Bluetooth** | `wave.3.right` | "Shows connected device status." |

#### 3. Each Permission Card Design

Inspired by the reference images — each card is a horizontal row inside a rounded rect:

```
┌──────────────────────────────────────────────────────────────────┐
│  ┌─────────┐                                                    │
│  │  icon   │  Title                          [Grant Access]     │
│  │ (glass) │  Description text here...        or ✓ Granted      │
│  └─────────┘                                                    │
└──────────────────────────────────────────────────────────────────┘
```

- **Card background**: `rgba(255,255,255, 0.05)` fill, `rgba(255,255,255, 0.08)` 1px continuous rounded rect border, cornerRadius 22.
- **Padding**: 20pt all sides.
- **Icon container**: 54×54 rounded rect (cornerRadius 16, continuous), filled with a **liquid glass gradient** — an `AngularGradient` or `LinearGradient` using iridescent colors:
  - For required permissions: purple `#8B5CF6` → blue `#3B82F6` → gold `#F59E0B` with a slight noise texture feel (achieve with overlapping semi-transparent radial gradients).
  - For optional permissions: subtler version — dark surface `rgba(255,255,255, 0.08)` with a faint iridescent border shimmer.
  - The SF Symbol icon sits centered inside in white at 92% opacity, size 22 semibold.
  - When granted: the icon container gets a subtle green tint overlay.
- **Title**: size 17, weight .semibold, text primary. Left-aligned.
- **Description**: size 13, weight .regular, text secondary. Left-aligned, below title with 4pt gap.
- **Action button** (right side):
  - Not granted: "Grant Access" secondary pill button (rgba(255,255,255, 0.10) fill, white text at 88%).
  - Granted: Green checkmark badge — `checkmark.circle.fill` icon + "Granted" text in `#34D399`, inside a capsule with green at 12% fill. Animate in with `.spring(response: 0.34, dampingFraction: 0.72)` scale from 0.75 → 1.0.
- **Hover effect**: card lifts 2pt (offset y: -2), shadow deepens. Spring animated.
- **Stagger reveal**: Cards appear one by one with 100ms delay between each, sliding up from 18pt below with opacity 0 → 1. Use `.spring(response: 0.42, dampingFraction: 0.88)`.

#### 4. Divider between Required and Optional
A subtle horizontal line or label:
- Small text "Optional — you can enable these later" in text tertiary, centered, with thin `rgba(255,255,255, 0.06)` lines on either side (a divider pattern).

#### 5. Continue Button (bottom)
- Same cool accent button as Page 1.
- **Disabled** (opacity 0.48, no hover effect) until BOTH required permissions (Screen Recording + Accessibility) are granted.
- Below the button when disabled: "Enable required permissions above to continue." — size 13, text tertiary.
- Poll permission state every 800ms using a `.task` loop with `PermissionsManager.shared` checks.

#### 6. Permission Check Badge (top-right of icon, like reference images)
When a permission is granted, show a small **leaf/petal-shaped badge** at the top-right corner of the icon container (inspired by the golden-purple checkmark badge in the reference images):
- Shape: a small rounded teardrop/leaf, ~22×22.
- Fill: `AngularGradient` with gold `#F5A84B` → purple `#8B5CF6` → blue `#3B82F6`.
- Contains a small white checkmark `checkmark` at size 10, weight .bold.
- Animate in with scale + opacity spring.

---

## Page 3 — Gestures Tutorial & Done

### Layout (top to bottom)

#### 1. Section Header
- **"How to use DynamicIsland"** — size 34, weight .semibold, text primary. Centered.
- Below: **"A few quick gestures and you're ready."** — size 16, text secondary. Centered.

#### 2. Gesture Instruction Cards
A centered grid or vertical stack of **3 gesture cards** showing how to interact with the island:

##### Card A — Swipe Left & Right
- **Visual**: An animated illustration showing a miniature Dynamic Island capsule (dark pill shape, ~180×36) with a **horizontal arrow animation**:
  - A small chevron or hand icon slides left, then right, in a loop.
  - Or: render two arrows `chevron.left` and `chevron.right` on either side of the pill, with a subtle pulsing glow animation.
- **Title**: "Swipe Left & Right"
- **Description**: "Cycle through modules — music, timer, calendar, and more."
- Card styling: same dark surface card as permissions cards, but wider. Include the animated mini-island illustration at the top of the card.

##### Card B — Swipe Up & Down
- **Visual**: A mini island pill with vertical arrows — `chevron.up` above and `chevron.down` below, animated with a gentle bounce.
- **Title**: "Swipe Up & Down"
- **Description**: "Swipe up to expand, swipe down to dismiss."

##### Card C — Lock Button
- **Visual**: A lock icon `lock.fill` that toggles to `lock.open` in a looping animation (every 2s), inside a rounded square styled like the actual lock button in the app.
- **Title**: "Lock Open"
- **Description**: "Tap the lock to keep the island expanded until you dismiss it."

#### 3. Card Design
Each gesture card:
- Width: fill available (max ~340pt each if in a 2+1 grid, or full width ~680pt if stacked vertically).
- Height: auto, padding 24.
- Background: `rgba(255,255,255, 0.04)` fill, `rgba(255,255,255, 0.08)` 1px border, cornerRadius 22.
- The animated illustration area at top: ~100pt tall, centered.
- Title below illustration: size 17, weight .semibold, text primary.
- Description below title: size 14, weight .regular, text secondary.
- Stagger animation on appear (same as permissions cards).

#### 4. Layout Option
Prefer a **2-column top row + 1 centered bottom** layout:
```
┌──────────────┐  ┌──────────────┐
│  Swipe L/R   │  │  Swipe U/D   │
└──────────────┘  └──────────────┘
       ┌──────────────┐
       │   Lock Open  │
       └──────────────┘
```

Or if space is tight, a vertical `VStack(spacing: 14)` of all 3 is fine.

#### 5. "Get Started" Button (bottom)
- **"Get Started"** button using the **warm accent gradient** (`#F5A84B` → `#E07832`), amber/gold tone.
- Same pill shape, 46pt tall.
- On tap: trigger a **sparkle burst animation** (6 small sparkle/star icons that fly outward radially and fade), then dismiss the onboarding window after 0.5s.
- While launching: button text changes to "Launching…" and becomes disabled.
- Below: a subtle "Open Settings Later" tertiary text button (no background, just underlined or plain text, text secondary color).

---

## Micro-Interactions & Polish

### Hover States
All interactive elements (buttons, permission cards) should have:
- Scale effect: 1.0 → 1.03 on hover.
- Shadow deepens.
- Transition: `.spring(response: 0.32, dampingFraction: 0.78)`.

### Icon Style — Liquid Glass (from reference images)
The reference images show a specific icon treatment:
- Icons sit inside rounded-square containers with **iridescent gradient fills** — blending purple, blue, gold, and amber.
- The gradients feel like they have a **metallic, refractive quality** — think of light hitting a soap bubble or oil on water.
- To achieve in SwiftUI: use an `AngularGradient` with stops at purple, blue, gold, orange, back to purple, and rotate the gradient angle slowly (animation over 8s, repeating). Overlay with a subtle `RadialGradient` (white center at 10% → transparent) to create the "liquid glass" light refraction effect.
- Add a thin 1px border in `rgba(255,255,255, 0.15)` to give a glass-edge feel.
- Drop shadow: `Color.black.opacity(0.20), radius: 16, y: 8`.

### Window Behavior
- Window is **not resizable**. Fixed size.
- `isMovableByWindowBackground = true` — user can drag from anywhere.
- No minimize button behavior needed.
- Close button dismissal calls `onClose` callback.
- The window corners should be clipped to a continuous rounded rectangle so no sharp macOS window corners are visible.

### Accessibility
- All interactive elements must have `.accessibilityLabel()` and `.accessibilityValue()`.
- Headers marked with `.accessibilityAddTraits(.isHeader)`.
- Permission cards use `.accessibilityElement(children: .combine)` with descriptive labels.
- VoiceOver must be able to navigate all pages linearly.

---

## File Structure

```
DynamicIsland/Onboarding/
├── OnboardingView.swift              — Main container, page state, backdrop, palette, shared components
├── OnboardingWindowController.swift  — NSWindow setup (no title bar, dark, fixed size, rounded)
├── HelloScreenView.swift             — Page 1: Hello animation + welcome text
├── PermissionsScreenView.swift       — Page 2: Permission cards with required/optional sections
├── GetStartedScreenView.swift        — Page 3: Gesture tutorial cards + launch button
├── PermissionCardComponent.swift     — Reusable permission card with icon, text, action, badge
```

Replace ALL existing onboarding files with the new implementation. The `OnboardingPermission` enum should be expanded to cover all 7 permissions (Screen Recording, Accessibility, Calendar, Notifications, Microphone, Location, Bluetooth) with required vs. optional distinction. The `OnboardingPermissionState` should track all of them.

---

## Summary of Key Requirements

1. **Page 1**: Apple "Hello" effect — large text with gradient color wipe reveal animation, welcome copy, feature chips, continue button.
2. **Page 2**: All 7 permissions in cards with liquid-glass iridescent icons, required/optional split, leaf-shaped granted badge, polling for permission state.
3. **Page 3**: 3 gesture tutorial cards (swipe L/R, swipe U/D, lock button) with animated mini-illustrations, "Get Started" warm button with sparkle burst.
4. **Background**: Liquid glass purple animated gradient (blurred orbs drifting slowly) behind a dark overlay — atmospheric, never interfering with readability.
5. **Window**: Dark, non-native feel. No visible title bar. Rounded corners. Fixed size ~840×620. Movable by background.
6. **Theme**: Entirely dark/black. Rich blacks, not flat. Subtle depth through layered transparencies.
7. **Icons**: Liquid glass style — iridescent angular gradients (purple/blue/gold) in rounded-square containers, inspired by the reference images' metallic refractive look.
