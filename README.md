# Yuzu

The zero-click, local-first file converter for macOS. Hold **Shift** while dragging files in Finder to convert them; add **Option** to open advanced tools. Yuzu is designed to process selected files locally, never modify the original during conversion, and avoid telemetry.

Yuzu is a separately maintained application derived from the open-source Satsuma project and inspired by the Tangerine workflow. It provides 188 conversion options across images, video, audio, documents, subtitles and archives, plus 25 advanced file tools. Satsuma and Tangerine remain upstream acknowledgements; Yuzu does not use Tangerine proprietary branding or assets.

## How it works

1. Start dragging one or more files in Finder (or any app).
2. Hold **Shift**. A radial menu appears around the cursor with the formats the selection can be converted to.
3. Move over a format and release to convert. Copies are written next to the originals (or to the folder chosen in Settings).
4. Hold **Shift + Option** instead to switch the radial menu to advanced tools (Compress, Crop, Trim, Merge PDFs, …). Releasing on a tool opens its window with a live preview.

Keyboard: while the radial menu is open, press **Option** to toggle between formats and tools, arrow keys to choose, **Return** to apply, **Escape** to cancel.

Yuzu lives in the menu bar (no Dock icon). The status item shows job progress and opens Settings.

## Look and feel

The radial menu is built from Liquid Glass wedges (`glassEffect` on a custom rounded annular-sector `Shape`, grouped in a `GlassEffectContainer`), with the selected wedge tinted orange and a glass centre pill naming the selection. Tool windows use the stock macOS title bar (title + file subtitle), card-grouped content, standard AppKit/SwiftUI controls with an orange accent, overlay scrollbars where content is taller than the window, and a bottom Cancel/Save bar. Every icon is an SF Symbol. Light and dark appearance follow the system, or can be forced in Settings.

## Conversions

| Source | Targets |
| --- | --- |
| JPG, PNG | PNG/JPG, WebP, HEIC, TIFF, AVIF, BMP, PDF, DOCX |
| WebP, HEIC, TIFF, SVG, AVIF, BMP | JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP, PDF |
| MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA | every other audio format |
| MP4, MOV, MKV, WebM, AVI, WMV | every other video format, GIF, MP3 |
| GIF | MP4, MOV, MKV, WebM, AVI, WMV |
| PDF | DOCX, JPG, PNG (all pages, 300 DPI), TXT |
| TXT | PDF, JPG, PNG, SRT, VTT |
| SRT, VTT | VTT/SRT, TXT |
| ZIP, TAR, GZIP, RAR | ZIP, TAR, GZIP (RAR can be read, not written) |

Native frameworks are used first: ImageIO/Core Graphics for images, AVFoundation for audio and video, PDFKit/Core Text for documents, Foundation for archives. `ffmpeg` is used only for formats Apple's frameworks cannot encode or decode (WebM/VP9, MKV, AVI, WMV, OGG, Opus, FLAC output, WMA, MP3 encoding, animated GIF export). `unar`/`bsdtar` extracts RAR.

## Advanced tools

| Scope | Tools |
| --- | --- |
| Any file | Compress (Balanced/Strong, target size, resize), Edit metadata (view, edit, strip sensitive or all fields) |
| Images | Edit photos, Add a background, Crop, Redact, Resize, Rotate, Create a PDF, Make a collage |
| Video | Trim, Split, Crop, Change speed, Join, Save frames, Redact |
| Audio | Trim, Normalize volume, Convert channels, Bleep, Create an audio visualizer |
| PDF | Merge, Organize pages, Split |

## Requirements

- Apple silicon Mac running macOS 26 or later.
- [Brisk](https://github.com/plyght/brisk) and the Xcode command-line tools (`swiftc`) to build.
- Optional: `ffmpeg` for the non-native formats listed above (`wax install ffmpeg`), `unar` for RAR extraction (`wax install unar`). Yuzu looks in `PATH`, `/opt/homebrew/bin` and `/usr/local/bin`; a custom path can be set in Settings.

## Build

```bash
brisk build            # debug .app in .build/debug/Yuzu.app
brisk run              # build and launch
brisk test             # compile and run Tests/ with the app sources
brisk archive --release
```

During a Finder drag, Yuzu polls `NSEvent.pressedMouseButtons`, `NSEvent.modifierFlags`, `NSEvent.mouseLocation` and the system drag pasteboard (`NSPasteboard(name: .drag)`). If Finder has not published the file URLs yet, Shift plus sustained drag movement shows a generic drop target immediately; the wheel then reads the files from the drag pasteboard or `NSDraggingInfo` as soon as they become available. It does not install key-event monitors or event taps. The current implementation does use global mouse monitors, so Accessibility/Input Monitoring behavior must be verified on each supported macOS configuration. Progress shows in a floating card or a small pill under the notch (Settings > Appearance); there are no system notifications.

## Logs

Yuzu writes a local activity log to `~/Library/Logs/Yuzu/yuzu.log` (drag selection, job start/finish, conversion steps, errors) and, if the process dies from a signal, a backtrace to `~/Library/Logs/Yuzu/crash.log`. "Show Logs" in the menu bar menu reveals them in Finder. Nothing leaves the machine.

## Quality gates

```bash
scripts/check.sh        # format check, lint, build (type-check), tests
scripts/check.sh --fix  # apply swift-format fixes first
```

`scripts/check.sh` uses `swift-format` (Apple, ships with Xcode 16 / `wax install swift-format`), `swiftlint` (`wax install swiftlint`) when present, `brisk build` as the type-check and `brisk test` for the test suite. Missing optional linters are reported and skipped; the build and tests are mandatory.

## Verification status

The GitHub Actions workflow (`.github/workflows/ci.yml`) runs on the `macos-26` and `xcode-27` (macOS 27 / Xcode 27 SDK, public preview) runners: `brisk build`, `brisk test` (conversion matrix, naming, subtitle, PDF-range, tool-applicability, compression and timecode logic in `Tests/YuzuTests.swift`), then launches the app with `YUZU_SCREENSHOTS=<dir>` so `Sources/App/ScreenshotDriver.swift` generates sample media, opens the radial menu and all 25 tool windows, and captures them with `screencapture`. Screenshots and the release `Yuzu.app` zip are uploaded as workflow artifacts. Actual Finder Shift-drag cannot be exercised on a headless runner and still need a manual check on a Mac.

## Project layout

```
.brisk.toml                Brisk manifest (bundle id com.radja.yuzu, LSUIElement)
Sources/App                App delegate, status item, settings
Sources/Formats            FileFormat enum, ConversionMatrix (188 options, output naming)
Sources/Engines            Conversion engines: image, audio, video, document, subtitle, archive, ffmpeg bridge
Sources/Operations         Tool backends: ImageOps, VideoOps, AudioOps, PDFOps, MetadataOps, Compressor
Sources/Radial             Global drag/modifier monitor and the radial menu overlay
Sources/Core               Job runner, progress HUD (card and notch pill), shell, media probing
Sources/Tools              Tool window shell, tool registry and the 25 tool views
Tests                      Direct Swift tests run by `brisk test`
```

## Privacy

Yuzu contains no telemetry or analytics implementation in this repository and is designed for local-first processing. Files are read from disk, processed in memory or in a temporary folder under the user's temp directory, and written back as new files next to the originals. External conversion tools and future packaging must be reviewed separately before making stronger offline or sandboxing claims.

## License

MIT
