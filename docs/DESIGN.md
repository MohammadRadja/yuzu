# Yuzu Design System

> Status: Approved design direction with the October 2026 radial repair implemented in source. The light glass backing, solid selection, and captions were inspected in offscreen previews and temporary native windows under both system appearances. Live Finder/Desktop interaction, audible feedback, and accessibility settings still require manual validation; acceptance boxes below remain unverified.

## 1. Product direction

Yuzu is a native macOS file utility with a distinctive **citrus-inspired, precision-tool** identity. It should feel fast, calm, tactile, readable, and polished—not like a large translucent overlay. Use AppKit and SwiftUI conventions, system typography, SF Symbols, semantic colors, and accessible interactions.

**Design signature:** a compact **floating citrus dial** with a bright Yuzu-yellow selection state, golden-amber edge light, finely separated radial segments, crisp iconography, and a quiet center status area. This is Yuzu's own visual language; do not replicate Tangerine's wedge contours, arrangement, icon positioning, dimensions, or branding.

### Design principles

1. **Clarity before decoration:** users must identify actions in under a second.
2. **Compact, not overwhelming:** the dial should frame the dragged file instead of dominating the Desktop.
3. **Deliberate hierarchy:** action icon → action name → current selection or file context.
4. **Subtle material:** use restrained native vibrancy and translucency, with predictable contrast over busy wallpapers.
5. **Motion communicates state:** animation should clarify opening, selection, mode changes, and completion.
6. **Native and accessible:** honor macOS appearance, keyboard access, VoiceOver, Reduce Motion, and Increase Contrast.
7. **Real functionality:** show only supported operations; never imply an unsupported conversion works.

## 2. Visual audit of current radial

The reported pre-repair radial and reference screenshot identified these problems:

- The wheel is visually heavy: broad, dark, nearly continuous gray surfaces overpower the file and wallpaper.
- The large top/bottom segments feel unevenly balanced against the narrow center.
- Empty wedge areas and small labels make the interaction look unfinished.
- The dragged Finder thumbnail and filename overlap the center, making the center text difficult to read.
- Action names and icons do not yet form a consistent visual rhythm.
- The outer boundary and segment separations are soft and indistinct; selection feedback needs more contrast.

The second screenshot is a **quality reference only**: it demonstrates readable action labels, consistent icons, obvious active state, and balanced spacing. Yuzu must develop a different shape, spacing system, accent treatment, and overall identity.

The repair addresses mismatched AppKit/SwiftUI y coordinates, an inner radius that extended beneath the hub, interpolated selection, and a hub tint drawn over its content. The changes below describe the resulting source behavior; they do not certify the original drag freeze or appearance as resolved in a live Finder session.

## 3. Yuzu radial: Citrus Dial

### 3.1 Geometry

- Use a circular or subtly rounded radial silhouette with **consistent segment sizing**, rather than oversized horizontal lobes.
- Current canvas and panel: **364 × 364 pt**, with **166 pt** outer ring radius. The anchor stays fixed during a drag, including mode changes; presentation clamps to the selected display's visible frame.
- Center hub diameter: **118 pt**; the action ring starts at **65 pt**, leaving **6 pt** between hub and ring.
- Radial ring: **6 segments preferred** for common actions; support **2–8 items** through a responsive layout. For more actions, use a second level or a clearly indicated More item, not cramped labels.
- Segment gaps: approximately **5–7 pt**, visually consistent at every angle. Use rounded edges (approximately **12–18 pt**) while retaining distinct, original geometry.
- Backing plate: a translucent native glass circle extends **8 pt** beyond the action ring, leaving **8 pt** for shadow within the existing canvas. It provides a stable background through the segment gaps without changing hit targets.
- Use a layout algorithm that calculates segment bounds, hit targets, icon positions, and label positions from a shared radial geometry model; do not manually position each segment.
- Keep hit regions at least **44 × 44 pt** where feasible and ensure the pointer selection region corresponds to the visible wedge.
- The rendered `WedgeShape` path is also the hit-test source in `Sources/Radial/RadialView.swift`; hover and native drop dispatch share the same rounded corners and segment gaps. A single-item wheel uses full, oppositely wound outer and inner arcs to form an actual annulus so its hub is neither filled nor actionable. AppKit coordinates flip y once before querying this path.

These dimensions are starting points to be tested at 1×/2× scaling, with real Finder drag thumbnails and different screen sizes.

### 3.2 Material and surfaces

- Default wheel: bright white/silver native Liquid Glass with a translucent tint, fine rim, and subtle depth, matching the supplied light-surface references. `RadialWheelView` uses one circular `.glassEffect(.regular.tint(...))` backing rather than opaque plates or stacked material layers.
- Each segment is an independent raised-looking surface, separated by actual gaps. Avoid one large dark gray mass.
- The radial intentionally stays light in both system appearances. Its local light color scheme and explicit dark foreground tokens do not change the appearance of Settings or tool windows.
- Backdrop: a translucent white/silver circular glass plate, white reflective rim, and restrained offset shadow. Inactive segments layer a translucent white-to-silver gradient over the shared glass; the center is translucent white with a softer shadow.
- Selected segment: the entire wedge receives a solid opaque `yuzuYellow` fill, dark `yuzuActiveText` icons/labels, amber outline, and a soft offset shadow. Selection changes immediately; no tiny accent indicator substitutes for the full fill.
- Reduce Transparency bypasses glass and uses opaque light silver/white surfaces; Increase Contrast strengthens dark outlines. Hub tint is behind content rather than over it.
- Hovered/armed states must remain distinguishable without relying on color alone.

### 3.3 Center hub

The hub is a **status display**, not a duplicate of the dragged file thumbnail:

- Idle: Yuzu symbol or concise mode name (`Convert`, `Tools`, `Actions`, `Tasks`).
- During drag: show file context and current mode. The current provider emits type/count for a single file (`DOCX · 1 file`) and a count for multiple files (`3 files`). Do not duplicate Finder's filename in the hub.
- While hovering a segment: show the **selected action name** (`PDF`, `Resize`, `Copy Path`) and optionally a one-line outcome.
- In the picker: show the single selected filename as a compact center caption with middle truncation and expose the full action/file context through the accessibility label.
- The selected action is visible on its wedge as well as the hub. Finder owns its native drag preview, which Yuzu does not modify; actual preview overlap and center readability remain manual checks.
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

All values are centralized in `Sources/UI/Theme.swift`, not scattered across `RadialView`.

| Token | Initial value / rule | Purpose |
| --- | --- | --- |
| `yuzuYellow` | `#F8C537` | Primary active surface |
| `yuzuGold` | `#FF9F1C` | Retained palette companion |
| `activeGradient` | `#F8C537 → #FF9F1C` | Retained compatibility token; radial uses solid `yuzuYellow` |
| `yuzuAmber` | `#D97706` | Amber edge and active shadow accent |
| `yuzuCream` | `#FFF4C2` | Warm hub cue |
| `yuzuActiveText` | `#252014` | Dark text and SF Symbols on active wedges |
| `activeEdgeHighlight` | `softHighlight` | Retained compatibility token |
| `activeShadow` | `deepAccent` at 28% | Active segment elevation |
| `radialStroke` | Cool gray at 35% | Quiet segment separation |
| `radialRim` | White at 80% | Reflective backing and hub boundaries |
| `radialHubShadow` | Black at 8%, radius 6 pt, offset 2 pt | Restrained center depth |
| `accent` | `Theme.citrusYellow` | Shared Yuzu semantic accent |
| `radialSurfaceGradient` | White to silver at `radialSurfaceOpacity = 0.68` | Translucent inactive wedge fill |
| `radialCaption` | Opaque cool gray | Readable supporting text on light glass |
| `radialHub` | White at `radialHubOpacity = 0.84` | Bright translucent center hub |
| `radialInk` | Opaque dark gray | Primary radial text in either system appearance |
| `inkSecondary` | `secondaryLabelColor` | Supporting text |
| `radialBackdrop` / `radialGlassTint` | Silver tint at 28% over native glass with a 35% white tint | Light glass wheel background |
| `radialBackdropInset` | 8 pt beyond the action ring | Visible backing rim and filled gaps |
| `radialOuterRadius` | 166 pt; canvas adds 16 pt padding per side | Wheel size |
| `radialHubDiameter` | 118 pt | Center size |
| `radialHubSeparation` | 6 pt | Clear gap before the action ring |
| `radialSegmentGap` | 6 pt | Wedge separation |
| `radialSegmentCorner` | Up to 15 pt, constrained by segment count | Wedge curvature |
| `radialIconSize` | 22 pt baseline | Icon consistency |
| `radialLabelSize` | 12 pt semibold baseline | Label consistency |
| Selection timing | Immediate; no interpolation | Visual and hit-region agreement |

The prior `citrusYellow`, `goldenAmber`, `deepAccent`, `softHighlight`, and `activeText` names remain aliases; their colors are defined only once. Retain `Theme.cardCorner = 12` for ordinary cards. Calculated foreground contrast is **10.06:1** on Yellow and **7.90:1** on Gold; rendered light/dark and accessibility appearances still require inspection.

## 5. Four-mode interaction language

The modifier-to-mode mapping is implemented through `RadialMode`, `AppSettings`, and `DragMonitor`.

| Default modifier | Mode | Example content | Visual identifier |
| --- | --- | --- | --- |
| `Shift (⇧)` | Convert | PDF, JPG, PNG, TXT | Conversion arrows + small citrus-yellow mode marker |
| `Command (⌘)` | Tools | Resize, Compress, Merge, Trim | Tool symbol + small citrus-yellow mode marker |
| `Control (⌃)` | Actions | Copy, Move, Copy Path, AirDrop, Terminal | Action symbol + small citrus-yellow mode marker |
| `Option (⌥)` | Tasks | Optimize, Organize, Rename, Share | Workflow symbol + small citrus-yellow mode marker |

- All four modes use the **same radial component**, tokens, and geometry.
- Differentiate modes primarily by icon, heading, and content; do not assign four unrelated bright color palettes.
- When switching modes, replace content immediately, clear stale selection, and keep the hub, panel, and wheel scale fixed.
- Tasks entries are backed by existing compression, move, rename, and AirDrop handlers; unavailable system services are omitted.
- The legacy Shift+Option Tools alias remains available while Option alone selects Tasks, so existing tool access is preserved.
- Respect Finder/macOS semantics: a source may restrict its operation mask while a modifier is held. The destination accepts copy/generic and rejects move-only masks. Releasing the source modifier may be necessary before dropping; Yuzu retains its selected mode. Verify this with real Finder/Desktop drags.

## 6. Radial states and feedback

| State | Appearance | Behavior |
| --- | --- | --- |
| Waiting for file | Small neutral hub or no wheel | Do not present empty wedges from an unresolved drag pasteboard |
| Opening | Immediate presentation at final size | Anchor once with screen-edge clamping |
| Default | Calm surfaces, legible icons | No preselected destructive action |
| Hover | Slightly elevated wedge, visible border | Update hub label immediately |
| Armed | Strong citrus-yellow/golden-amber fill, amber edge, and dark readable text | Clearly indicate what release will trigger |
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
- On initial presentation, clamp the wheel to the pointer's display so all segments remain visible. Keep that anchor fixed while the pointer moves; support multiple display origins and scales.
- Keep the overlay non-disruptive to Finder when no Yuzu modifier is active.
- Confirm drag/drop hit-testing and release behavior independently of visual hover effects.

## 8. Motion and sound

- Entrance: present at final size and anchor; no scale transition during external dragging.
- Hover: immediate full active fill and outline, with no wedge displacement or color interpolation.
- Mode switch: replace content immediately without moving the panel or morphing hit targets.
- Commit: dismiss after the native destination claims the drop, then dispatch the existing operation.
- These immediate state changes also respect **Reduce Motion**; alignment haptics are suppressed when Reduce Motion is enabled.
- A short, original synthesized click plays when the pointer or arrow keys enter a different action on a visible wheel. Sound is enabled by default and can be disabled in Settings > General. Repeated native updates, hub/gaps, empty wheels, dismissal, and mode resets are silent; rapid sweeps are limited to one click per 45 ms. The audio is generated locally in memory and does not use Tangerine assets. Sound remains independent of the existing Reduce Motion haptic suppression.

## 9. Other Yuzu surfaces

### Menu bar
- Keep a compact native status item with accessible title and tooltip.
- Menu actions: Open Yuzu, Recent Jobs, Settings, Quit (subject to actual implemented features).
- Avoid using the menu-bar icon as a constant bright accent; reserve citrus yellow for purposeful states.

### Settings
- Use native grouped SwiftUI settings with clear sections: General, Shortcuts, Appearance, Output, and Advanced as applicable.
- Show the four modifier mappings in a compact keyboard-shortcut table.
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
5. **Modes:** use the shared visual treatment for Convert, Tools, Actions, and Tasks, while omitting unavailable system actions.
6. **Polish:** accessibility, Reduce Motion, multi-display testing, and visual regression checks.

Do not rewrite the app or replace working drag/conversion logic solely for cosmetic changes. Keep implementation incremental and reviewable.

## 12. Acceptance criteria

- [ ] Yuzu's radial is recognizably original and not a visual clone of the reference competitor.
- [ ] The light glass wheel remains balanced and readable over both light and dark desktop backgrounds.
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

Capture and compare screenshots of: idle wheel, selected wedge, long filename, multiple files, unsupported file, Convert/Tools/Actions/Tasks mode, light and dark appearances, Desktop versus Finder drag, high-contrast mode, and wheel near each screen edge.

Judge Yuzu against **readability, proportion, visual hierarchy, native feel, and originality**—not against pixel similarity to any competitor.
