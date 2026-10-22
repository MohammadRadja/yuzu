# Yuzu Design System

> Status: Design specification and implementation roadmap. This document defines the intended UI; it does not claim that the proposed components are implemented.

## 1. Product direction

Yuzu is a native macOS file utility with a distinctive **citrus-inspired, precision-tool** identity. It should feel fast, calm, tactile, readable, and polished—not like a large translucent overlay. Use AppKit and SwiftUI conventions, system typography, SF Symbols, semantic colors, and accessible interactions.

**Design signature:** a compact **floating citrus dial** with a warm, restrained orange selection indicator, finely separated radial segments, crisp iconography, and a quiet center status area. This is Yuzu's own visual language; do not replicate Tangerine's wedge contours, arrangement, icon positioning, dimensions, or branding.

### Design principles

1. **Clarity before decoration:** users must identify actions in under a second.
2. **Compact, not overwhelming:** the dial should frame the dragged file instead of dominating the Desktop.
3. **Deliberate hierarchy:** action icon → action name → current selection or file context.
4. **Subtle material:** use restrained native vibrancy and translucency, with predictable contrast over busy wallpapers.
5. **Motion communicates state:** animation should clarify opening, selection, mode changes, and completion.
6. **Native and accessible:** honor macOS appearance, keyboard access, VoiceOver, Reduce Motion, and Increase Contrast.
7. **Real functionality:** show only supported operations; never imply an unsupported conversion works.

## 2. Visual audit of current radial

The existing Yuzu radial shown in the reference screenshot is functional, but its appearance needs refinement:

- The wheel is visually heavy: broad, dark, nearly continuous gray surfaces overpower the file and wallpaper.
- The large top/bottom segments feel unevenly balanced against the narrow center.
- Empty wedge areas and small labels make the interaction look unfinished.
- The dragged Finder thumbnail and filename overlap the center, making the center text difficult to read.
- Action names and icons do not yet form a consistent visual rhythm.
- The outer boundary and segment separations are soft and indistinct; selection feedback needs more contrast.

The second screenshot is a **quality reference only**: it demonstrates readable action labels, consistent icons, obvious active state, and balanced spacing. Yuzu must develop a different shape, spacing system, accent treatment, and overall identity.

## 3. Yuzu radial: Citrus Dial

### 3.1 Geometry

- Use a circular or subtly rounded radial silhouette with **consistent segment sizing**, rather than oversized horizontal lobes.
- Recommended initial wheel diameter: **340–380 pt** at 100% display scale; adapt for content and accessibility. Avoid a fixed giant full-screen wheel.
- Center hub diameter: **110–126 pt**, with a clear separation from the action ring.
- Radial ring: **6 segments preferred** for common actions; support **2–8 items** through a responsive layout. For more actions, use a second level or a clearly indicated More item, not cramped labels.
- Segment gaps: approximately **5–7 pt**, visually consistent at every angle. Use rounded edges (approximately **12–18 pt**) while retaining distinct, original geometry.
- Outer padding: **10–14 pt** around the segments. Avoid unnecessary surrounding translucent disks.
- Use a layout algorithm that calculates segment bounds, hit targets, icon positions, and label positions from a shared radial geometry model; do not manually position each segment.
- Keep hit regions at least **44 × 44 pt** where feasible and ensure the pointer selection region corresponds to the visible wedge.

These dimensions are starting points to be tested at 1×/2× scaling, with real Finder drag thumbnails and different screen sizes.

### 3.2 Material and surfaces

- Default wheel: native-looking light material with a warm-neutral tint, thin semantic border, and subtle depth; do not rely on transparency alone.
- Each segment is an independent raised-looking surface, separated by actual gaps. Avoid one large dark gray mass.
- In light appearance: warm off-white / neutral surfaces with dark readable text.
- In dark appearance: charcoal / elevated semantic surfaces with light readable text; never force a white-only wheel.
- Backdrop: restrained shadow and optional subtle blur; keep the file thumbnail visible.
- Selected segment: Yuzu orange accent with high-contrast foreground, not an arbitrary system-blue highlight.
- Hovered/armed states must remain distinguishable without relying on color alone.

### 3.3 Center hub

The hub is a **status display**, not a duplicate of the dragged file thumbnail:

- Idle: Yuzu symbol or concise mode name (`Convert`, `Tools`, `Actions`, `Flow`).
- During drag: show **short file type + file count** (`DOCX · 1 file`, `PNG · 3 files`) and current mode.
- While hovering a segment: show the **selected action name** (`PDF`, `Resize`, `Copy Path`) and optionally a one-line outcome.
- For long filenames: place an optional compact filename caption **outside or below the wheel**; truncate the middle and expose the full name via accessibility label/tooltip where supported.
- Never place critical text beneath the macOS drag thumbnail. Consider an offset hub label or defer central details while the Finder drag preview overlaps it.
- Keep center text within safe insets and never use tiny text to force a fit.

### 3.4 Icons and typography

- Use SF Symbols with a consistent visual weight, generally **20–24 pt** for wedge icons.
- Place icons above concise labels; aim for **one or two words** per label.
- Wedge labels: system **12–13 pt semibold**, with consistent tracking and baseline alignment.
- Hub action title: system **14–16 pt semibold**; supporting text: **11–12 pt** secondary.
- Use actual symbol assets available on the deployment target; define fallbacks when symbols differ across macOS versions.
- Do not use emoji as primary action icons.
- Keep icons and labels upright regardless of the wedge angle.

## 4. Design tokens

All values are proposed and should be centralized, not scattered across `RadialView`.

| Token | Initial value / rule | Purpose |
| --- | --- | --- |
| `accent` | Existing `Theme.accentNS`, sRGB `(1.0, 0.36, 0.0)` | Primary selected/actionable state |
| `accentHover` | Derived from accent with semantic contrast adjustment | Hover state |
| `surfaceRadial` | Appearance-aware native material + neutral tint | Wedge fill |
| `surfaceHub` | Slightly more opaque semantic surface | Center hub |
| `strokeSubtle` | `separatorColor` with appropriate opacity | Wedge boundaries |
| `inkPrimary` | `labelColor` | Primary text |
| `inkSecondary` | `secondaryLabelColor` | Supporting text |
| `wheelDiameter` | 360 pt baseline | Wheel size |
| `hubDiameter` | 118 pt baseline | Center size |
| `segmentGap` | 6 pt baseline | Wedge separation |
| `segmentCorner` | 15 pt baseline | Wedge curvature |
| `radialIconSize` | 22 pt baseline | Icon consistency |
| `radialLabelSize` | 12 pt semibold baseline | Label consistency |
| `openDuration` | 140–190 ms | Entrance motion |
| `selectionDuration` | 90–130 ms | Hover feedback |

Retain the existing `Theme.cardCorner = 12` for ordinary cards; radial geometry has its own token set. Verify WCAG-style contrast where applicable; selected-state text must remain readable over orange.

## 5. Four-mode interaction language

The modifier-to-mode mapping is a **proposed direction** and must align with the actual planning and settings implementation.

| Default modifier | Mode | Example content | Visual identifier |
| --- | --- | --- | --- |
| `Shift (⇧)` | Convert | PDF, JPG, PNG, TXT | Conversion arrows + small orange mode marker |
| `Command (⌘)` | Tools | Resize, Compress, Merge, Trim | Tool symbol + small orange mode marker |
| `Control (⌃)` | Actions | Copy, Move, Copy Path, AirDrop, Terminal | Action symbol + small orange mode marker |
| `Option (⌥)` | Yuzu Flow | Web Ready, Organize, Rename, Optimize | Workflow symbol + small orange mode marker |

- All four modes use the **same radial component**, tokens, and geometry.
- Differentiate modes primarily by icon, heading, and content; do not assign four unrelated bright color palettes.
- When switching modes, transition labels and segments smoothly without moving the hub or changing wheel scale unexpectedly.
- Do not show planned actions as enabled until the underlying engine is implemented.
- Current legacy behavior uses `Option` as an advanced modifier. Before assigning Option its own mode, explicitly plan and migrate this interaction so existing tools remain accessible.
- Respect Finder/macOS semantics: Command- and Option-modified drags may have native meanings. Test whether modifier monitoring and drop behavior can coexist safely; avoid claiming universal compatibility without verification.

## 6. Radial states and feedback

| State | Appearance | Behavior |
| --- | --- | --- |
| Waiting for file | Small neutral hub or no wheel | Do not present empty wedges from an unresolved drag pasteboard |
| Opening | Short scale/opacity transition | Anchor to cursor with screen-edge clamping |
| Default | Calm surfaces, legible icons | No preselected destructive action |
| Hover | Slightly elevated wedge, visible border | Update hub label immediately |
| Armed | Strong orange fill or border + readable text | Clearly indicate what release will trigger |
| Processing | Compact progress HUD, not a frozen radial | Dismiss or transition wheel predictably |
| Success | Subtle confirmation + output location | Optional Reveal in Finder |
| Error | Concise explanation + recovery action | Never silently fail |
| Unsupported | Clear, intentional empty state | Explain missing conversion/tool instead of a generic broken-looking wheel |
| Cancel | Short dismissal | Never perform a file operation |

**Important:** distinguish `no dragged URLs`, `unsupported input`, and `recognized input with no available targets`. These are different states and must not all display “No conversions available.”

## 7. Drag thumbnail and Desktop integration

- Design against **real Finder drag previews**, which macOS draws independently and may cover the center hub.
- Avoid placing key controls directly beneath the pointer or drag thumbnail.
- Test drags from Finder windows **and Desktop icons**, including long filenames, screenshots, DOCX, multiple selections, and folders.
- Do not let an empty/stale drag pasteboard produce a misleading full wheel.
- When the pointer approaches screen edges, reposition the wheel so all segments remain visible; support multiple displays with different scales.
- Keep the overlay non-disruptive to Finder when no Yuzu modifier is active.
- Confirm drag/drop hit-testing and release behavior independently of visual hover effects.

## 8. Motion and sound

- Entrance: quick, subtle fade and scale from approximately 0.96 to 1.0; avoid exaggerated bouncing.
- Hover: minimal elevation/contrast change, not large wedge displacement.
- Mode switch: crossfade content with a short coordinated transition.
- Commit: brief selected-wedge confirmation before dismissing into the existing progress HUD.
- Respect **Reduce Motion**: replace movement with immediate state changes or simple fades.
- No sound by default; any future feedback sound must be optional.

## 9. Other Yuzu surfaces

### Menu bar
- Keep a compact native status item with accessible title and tooltip.
- Menu actions: Open Yuzu, Recent Jobs, Settings, Quit (subject to actual implemented features).
- Avoid using the menu-bar icon as a constant bright accent; reserve orange for purposeful states.

### Settings
- Use native grouped SwiftUI settings with clear sections: General, Shortcuts, Appearance, Output, and Advanced as applicable.
- Show the four modifier mappings in a compact keyboard-shortcut table once supported.
- Include a lightweight preview of the radial theme and appearance when practical.
- Follow existing `AppearanceMode`; do not duplicate theme state.

### Tool windows and progress
- Retain native title bars, grouped cards, 12 pt card corners, previews, and clear primary/secondary actions.
- Preserve the existing shared `JobRunner` progress HUD; refine its typography and contrast to match the radial.
- Error messages should identify the file and operation, explain what happened, and suggest the next action.

## 10. Accessibility and performance requirements

- Provide VoiceOver labels for mode, each action, current selection, file count, and disabled reason.
- Support arrow keys, Return to confirm, and Escape to cancel wherever the radial can receive keyboard focus.
- Respect system Light/Dark, Increase Contrast, Reduce Transparency, Reduce Motion, and Dynamic Type/appropriate macOS text scaling.
- Ensure high-contrast focus/selection outlines and non-color-only indicators.
- Keep animation responsive; avoid repeated heavy blur rendering or unnecessary SwiftUI view reconstruction during mouse movement.
- Validate against low-power hardware, external monitors, different display scales, and rapid modifier changes.

## 11. Implementation guidance

Relevant existing components to review:

- `Sources/Radial/RadialView.swift`: radial drawing, wedge layout, icons, labels, highlights, and accessibility.
- `Sources/Radial/RadialController.swift`: positioning, mode transitions, empty states, and file context.
- `Sources/Radial/DragMonitor.swift`: drag-state reliability, modifiers, and pasteboard timing.
- Existing `Theme.swift` / shared theme helpers: add centralized radial tokens without changing unrelated cards.
- Settings views: appearance and future modifier configuration.

Recommended sequence:

1. **Visual foundation:** centralize tokens and create an original balanced radial geometry.
2. **Readability:** redesign hub, icon-label layout, selection contrast, and filename treatment.
3. **Interaction reliability:** handle empty/stale URLs, Desktop drag, screen edges, and drag-thumbnail overlap.
4. **State feedback:** distinguish hover, armed, disabled, unsupported, progress, success, and error.
5. **Modes:** adopt shared visual treatment for Convert, Tools, Actions, and future Flow, without enabling unavailable actions.
6. **Polish:** accessibility, Reduce Motion, multi-display testing, and visual regression checks.

Do not rewrite the app or replace working drag/conversion logic solely for cosmetic changes. Keep implementation incremental and reviewable.

## 12. Acceptance criteria

- [ ] Yuzu's radial is recognizably original and not a visual clone of the reference competitor.
- [ ] Wheel looks balanced and polished in both light and dark appearance.
- [ ] All visible wedge icons and labels are readable over bright and busy wallpapers.
- [ ] No wedge is oversized or visually empty without a deliberate reason.
- [ ] The Finder drag thumbnail does not obscure the selected action or essential hub text.
- [ ] Active wedge is unmistakable through contrast, outline, and label feedback.
- [ ] Wheel supports 2–8 items without clipped or overlapping labels.
- [ ] Desktop and Finder drags behave consistently for the same supported file type.
- [ ] Unsupported inputs and missing Office backends show accurate, helpful feedback; DOCX conversion uses the optional LibreOffice backend.
- [ ] Radial never presents misleading actions while waiting for file URLs.
- [ ] Keyboard navigation, Escape, VoiceOver, and reduced-motion behavior are verified.
- [ ] Layout remains usable on small displays, at screen edges, and across multiple monitors.
- [ ] Performance remains responsive during drag, hover, and mode changes.

## 13. Design review checklist

Capture and compare screenshots of: idle wheel, selected wedge, long filename, multiple files, unsupported file, Convert/Tools/Actions/Flow mode, light and dark appearances, Desktop versus Finder drag, high-contrast mode, and wheel near each screen edge.

Judge Yuzu against **readability, proportion, visual hierarchy, native feel, and originality**—not against pixel similarity to any competitor.
