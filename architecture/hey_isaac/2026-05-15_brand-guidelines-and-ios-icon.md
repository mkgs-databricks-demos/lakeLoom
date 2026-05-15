# Hey Isaac — Databricks Brand Guidelines + iOS App Icon

**From:** Genie (Databricks side)
**Date:** 2026-05-15
**Status:** Design guidance for iOS app theming. Non-blocking — apply as you see fit during Module 02+.

---

## TL;DR

1. We have a **lakeLoom iOS icon** ready for you at `lakeLoom/media/lakeloom-ios-icon.png`. Use it as the app icon.
2. The Databricks App (browser side) follows a strict **brand design system**. Applying the same visual language to the iOS app will make lakeLoom feel like a cohesive Databricks-developed asset rather than two disconnected clients.
3. Below are the key brand tokens — typography, colors, motion, accessibility — for you to adapt into SwiftUI.

---

## iOS App Icon

**File:** `lakeLoom/media/lakeloom-ios-icon.png`

This is the canonical lakeLoom icon. Use it for:
- `AppIcon` asset catalog entry (all sizes — Xcode will downscale from the 1024px source)
- Any in-app branding (splash, about screen, settings header)

---

## Databricks Brand Design System — iOS Adaptation Guide

### Design Principles (Three Pillars)

Every design decision should satisfy all three:

1. **Distilled** — Clean, minimalistic, focused. Remove anything that doesn't serve meaning. Favor whitespace.
2. **Bold** — Striking and confident. Use color decisively, size headings generously, create strong visual focal points.
3. **Fresh** — Modern and evolving. Use contemporary patterns, balance consistency with relevance.

### Typography

| Role | Font | Weight | iOS Equivalent |
|------|------|--------|----------------|
| All UI text | DM Sans | Regular (400), Medium (500), Bold (700) | Bundle DM Sans or use `.system` with matching weights |
| Code / identifiers | DM Mono | Regular (400) | Bundle DM Mono or use `.monospacedSystemFont` |

**Type scale (pt):** 10 / 12 / 14 / 16 / 20 / 24 / 32 / 40 / 48 / 56

**Line heights:** 150% (1.5) for body copy, 120% (1.2) for headings.

Font files are at `/Shared/brandfolder/DM Sans/` and `/Shared/brandfolder/DM Mono/` if you need the `.ttf`/`.otf` sources. Alternatively, DM Sans is available via Google Fonts for bundling.

### Color Palette

**Primary brand colors:**

| Name | Hex | Role |
|------|-----|------|
| Lava 600 | `#FF3621` | Primary accent — CTAs, highlights, active states |
| Navy 800 | `#1B3139` | Dark surfaces, primary text (light mode) |
| Oat Medium | `#EEEDE9` | Light surface backgrounds |
| Oat Light | `#F9F7F4` | Lightest surfaces |
| White | `#FFFFFF` | Clean white backgrounds |

**Functional grays:**

| Name | Hex | Role |
|------|-----|------|
| Gray Nav | `#303F47` | Navigation backgrounds |
| Gray Text | `#5A6F77` | Body text, secondary labels |
| Gray Lines | `#DCE0E2` | Dividers, borders, separators |

**Semantic colors:**

| Role | Light Mode | Dark Mode |
|------|-----------|-----------|
| Primary CTA | Lava 600 `#FF3621` | Lava 500 `#FF5F46` |
| Success | Green 700 `#00875C` | Green 600 `#00A972` |
| Warning | Yellow 700 `#BA7B23` | Yellow 600 `#FFAB00` |
| Error | Lava 700 `#BD2B26` | Lava 500 `#FF5F46` |
| Info / links | Blue 600 `#2272B4` | Blue 400 `#8ACAFF` |
| Muted / disabled | Navy 400 `#90A5B1` | Navy 400 `#90A5B1` |

**Rules:**
- Lava is accent only — never use as a large background
- One accent family per view
- Navy, Oat, White for backgrounds

### Dark / Light Mode

The browser app uses semantic tokens that swap between modes. For iOS, map these to SwiftUI `Color` assets with light/dark variants:

| Token | Light | Dark |
|-------|-------|------|
| Surface Primary | White `#FFFFFF` | Navy 800 `#1B3139` |
| Surface Secondary | Oat Light `#F9F7F4` | Navy 900 `#0B2026` |
| Surface Raised | White `#FFFFFF` | Navy 700 `#143D4A` |
| Text Primary | Navy 800 `#1B3139` | White `#FFFFFF` |
| Text Secondary | Gray Text `#5A6F77` | Navy 400 `#90A5B1` |
| Border Default | Gray Lines `#DCE0E2` | Navy 600 `#1B5162` |
| Accent Primary | Lava 600 `#FF3621` | Lava 500 `#FF5F46` |

### Motion & Animation

| Duration | Use |
|----------|-----|
| 100ms | Button press, toggle, tooltip |
| 200ms | Dropdown, accordion, tab switch |
| 300ms | Modal enter, sidebar collapse |
| 400ms | Page transitions, skeleton reveal |

**Easing:** `.easeOut` for entrances (default), `.easeIn` for exits. Exits faster than entrances.

**Rules:** Max 2 properties animated simultaneously. Respect `UIAccessibility.isReduceMotionEnabled`. Never animate layout properties directly — use `transform` + `opacity` (or SwiftUI `.matchedGeometryEffect`).

### Accessibility (Non-Negotiable)

- Body text contrast: ≥ 4.5:1
- Large text (≥ 18px / ≥ 14px bold): ≥ 3.0:1
- **Key constraint:** Lava 600 on white = 3.6:1. Use for buttons and headings (≥ 14px bold) only. For body links use Blue 600 (5.1:1 on white).
- All interactive elements: minimum 44pt tap target
- VoiceOver labels on icon-only buttons

---

## How to Apply

You don't need to replicate the browser app pixel-for-pixel — iOS has its own platform idioms. The goal is **visual kinship**: same color palette, same type hierarchy, same motion philosophy. A user moving between iPhone and browser should feel like they're in the same product.

Suggested approach:
- Define a `BrandColors` enum or asset catalog with the hex values above
- Create a `BrandTypography` with DM Sans at the specified weights/sizes
- Use semantic color tokens in SwiftUI (light/dark adaptive)
- Apply Lava 600 as the tint color (navigation bar, buttons, active indicators)

---

## No Response Needed

This is reference material. Use it when you're ready — no urgency. If any values don't translate well to iOS (e.g., specific easing curves, tap target conflicts with Apple HIG), use your judgment and let me know what you changed.

— Genie
