# Yuzu

**Your files. Your flow.**

Version **1.1.0 is a release candidate**. The latest published installer is
**v1.0.0**. Features below describe the current source tree; public v1.1.0
publication is held while mandatory OCR integration fails on the Xcode 27 CI
host. The same OCR cases pass on the local macOS 27 host and macOS 26 CI.

Yuzu is free and open-source software for Apple silicon Macs. [Source code](https://github.com/MohammadRadja/yuzu) · [Download from GitHub Releases](https://github.com/MohammadRadja/yuzu/releases).

The zero-click, local-first file converter and file utility for macOS. Hold **Shift** while dragging files in Finder or on the Desktop to convert them, **Command** for tools, **Control** for file actions, or **Option** for Tasks. Yuzu is designed to process selected files locally, never modify the original during conversion, and avoid telemetry.

Yuzu is a separately maintained application derived from the open-source Satsuma project and inspired by the Tangerine workflow. The development registry contains 305 single-file conversion pairs across images, video, audio, documents, slides, spreadsheets, subtitles and archives, plus 32 advanced file tools. Satsuma and Tangerine remain upstream acknowledgements; Yuzu does not use Tangerine proprietary branding or assets.

## Main features

- **Shift (⇧) — Convert:** choose a compatible output format from the radial drag-and-drop menu.
- **Command (⌘) — Tools:** open file-processing tools with previews and explicit save controls.
- **Control (⌃) — Actions:** Copy, Copy Path, ZIP/Extract, Make a Copy, Trash, Reveal, Quick Look, Move, Rename, Inspect, Open With, New Folder with Selection, Share, and Terminal. Make a Copy creates new files/folders; Duplicate Finder in Tasks searches for identical content. More keeps the wheel compact; Archive Manager lives inside the archive action panels.
- **Option (⌥) — Tasks:** Batch Rename and Smart Organize with preview/confirmation, Batch Optimize with a per-file size/error report, Workflow Builder, Duplicate Finder, and File Shelf. Legacy handlers and Shift+Option tool access remain compatible.

## Install and launch

1. Open [GitHub Releases](https://github.com/MohammadRadja/yuzu/releases) and download `Yuzu-1.0.0.dmg` from the published v1.0.0 release.
2. Open the DMG and drag **Yuzu.app** onto **Applications**.
3. Eject the disk image and launch Yuzu from Applications.
4. Find Yuzu in the menu bar, open Settings as needed, and drag a test file while holding a mode modifier.

The v1.0.0 distribution uses **ad-hoc code signing**, has no Apple Developer ID signature, and is **not notarized by Apple**. macOS may block the first launch. Review the source and download origin before deciding whether to allow the app in **System Settings > Privacy & Security**. If macOS offers no supported option to open it, stop and report the warning. Do not disable Gatekeeper or remove quarantine attributes.

Yuzu uses global mouse monitors to detect drags. If macOS requests **Accessibility** or **Input Monitoring** access, review the request and grant access to Yuzu in System Settings > Privacy & Security only when needed. Permission behavior still requires manual testing on supported macOS versions; the app does not currently provide a dedicated permission-request flow.

## How it works

1. Start dragging one or more files or folders in Finder or on the Desktop.
2. Hold **Shift**. A radial menu appears around the cursor with the formats the selection can be converted to.
3. Move over a format and release to convert. Copies are written next to the originals (or to the folder chosen in Settings).
4. Hold **Command** instead to switch the radial menu to advanced tools (Compress, Crop, Trim, Merge PDFs, …). Releasing on a tool opens its window with a live preview. **Shift + Option** remains a migration shortcut for tools.
5. Hold **Control** for file and archive actions. Choose **More** for additional actions; **Share** opens the system sharing picker, including AirDrop when available.
6. Hold **Option** for dedicated batch and workflow Tasks. Review name/location previews before confirming file moves. File Shelf is also available from the menu bar.

Keyboard: while the radial menu is open, use arrow keys to choose, **Return** to apply, and **Escape** to cancel. Modifier assignments are configurable in Settings > Shortcuts; duplicate assignments are rejected.

Yuzu lives in the menu bar (no Dock icon). The status item shows job progress and opens Settings.

## Look and feel

The radial menu is a compact citrus dial made from independent annular segments with real gaps, translucent white/silver glass surfaces, a solid Yuzu Citrus Yellow selection state, a light native Liquid Glass circular backing, a stable status hub, and upright SF Symbol labels. The radial stays light over either desktop appearance and supports keyboard selection, VoiceOver labels, screen-edge clamping, and reduced-motion transitions. A short synthesized click accompanies each newly selected wedge; disable it in Settings > General. Tool windows use the stock macOS title bar (title + file subtitle), card-grouped content, standard AppKit/SwiftUI controls with the shared Yuzu accent, overlay scrollbars where content is taller than the window, and a bottom Cancel/Save bar.

## Conversions

| Source | Targets |
| --- | --- |
| JPG, PNG | PNG/JPG, WebP, HEIC, TIFF, AVIF, BMP, PDF, DOCX, ICO, ICNS |
| WebP, HEIC, TIFF, SVG, AVIF, BMP, ICO, ICNS | JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP, PDF, ICO, ICNS (excluding self) |
| Multiple images | Animated GIF with frame ordering and timing |
| MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA | every other audio format |
| MP4, MOV, MKV, WebM, AVI, WMV | every other video format, GIF, MP3, animated WebP (backend-dependent) |
| GIF | MP4, MOV, MKV, WebM, AVI, WMV, animated WebP |
| PDF | DOCX, PPTX (one image slide per page), XLSX (text rows; one sheet per page), JPG/PNG (all pages, 300 DPI), EPUB, TXT, MD, SVG (embedded PNG per page) |
| TXT | PDF, JPG, PNG, SRT, VTT, DOCX, MD, EPUB, HTML |
| DOCX, Markdown, EPUB | PDF, DOCX, MD, TXT, EPUB, HTML (excluding the source format) |
| PAGES, RTF, RTFD | PDF, DOCX, MD, TXT, EPUB, HTML (input only) |
| PPT, PPTX | PDF, JPG, PNG (all slides) |
| XLSX, ODS, CSV, TSV | XLSX, ODS, CSV, TSV, PDF (excluding the source format) |
| XLS | XLSX, ODS, CSV, TSV, PDF (input only) |
| SRT, VTT | VTT/SRT, TXT |
| HTML | PDF, DOCX, TXT (visible text; no web-resource loading) |
| Modern text clipping | TXT, Markdown, PDF |
| JSON | YAML, XML |
| YAML, XML | JSON |

Archive creation/extraction is available only in **Actions**. ZIP, RAR, 7Z, TAR, and GZIP are read through the system libarchive backend, subject to supported compression variants and extraction budgets. Archive Manager can inspect/select entries, unlock supported encrypted archives, and export ZIP copies with optional AES-256 encryption when the backend supports it.

Archive panels close after all submitted jobs succeed. Failures and cancellation
keep the panel available for review/retry. Completed progress rows disappear
after a short confirmation interval; failures remain until dismissed.

Native frameworks are used first: ImageIO/Core Graphics for images, AVFoundation for audio and video, PDFKit/Core Text for documents, the system libarchive reader for archives. Native document exporters create PDF-to-PPTX/XLSX, text-based EPUB/Markdown/HTML, and CSV/TSV spreadsheet outputs. An optional local LibreOffice installation handles PPT/PPTX, XLS/XLSX/ODS, DOCX/RTF, and PAGES input. `ffmpeg` is used only for formats Apple's frameworks cannot encode or decode (WebM/VP9, MKV, AVI, WMV, OGG, Opus, FLAC output, WMA, MP3 encoding). Collective image-to-GIF and GIF/native-video-to-WebP use bundled/native backends. Conversion output is validated before publication, and unavailable optional routes are omitted.

Original Pages 4/5 fixtures verify PDF/DOCX/TXT input conversion with an existing LibreOffice backend; arbitrary document fidelity still varies. PAGES export is not implemented. Resource-fork-only legacy text clippings are rejected with a migration message. YAML conversion supports block mappings/sequences, JSON flow values, and single-line scalars; advanced YAML constructs fail explicitly. XML/JSON uses a typed mapping to preserve data, and an ordered node mapping for arbitrary XML. Pages import depends on the file version supported by LibreOffice. PDF-to-PPTX preserves each page as an image, rather than editable slide objects; PDF-to-XLSX extracts selectable text rather than reconstructing tables. EPUB and text-document exports do not reconstruct typography, embedded media, or OCR. CSV/TSV exports from multi-sheet office files include the first sheet; HTML output is self-contained escaped text. Markdown is now a separate format rather than a TXT alias.

## Advanced tools

| Scope | Tools |
| --- | --- |
| Any file | Compress (Balanced/Strong, target size, resize), Edit metadata (view, edit, strip sensitive or all fields) |
| Images | Edit photos, Add a background, Crop, Redact, Resize, Rotate, Create a PDF, Make a collage, Remove Background (Vision), Upscale (Lanczos), Watermark, OCR |
| Video | Trim, Split, Crop, Change speed, Join, Save frames, Redact |
| Audio | Trim, Normalize volume, Convert channels, Bleep, Create an audio visualizer |
| PDF | Merge, Organize pages, Split, Password, Watermark, OCR, Visual Signature |
| Two files | Compare contents using streaming hashes and bounded text/line comparison |

Upscale uses interpolation, not AI detail reconstruction. PDF Visual Signature adds an image and does not provide a verified cryptographic signature. OCR exports UTF-8 TXT. Originals remain unchanged during these exports; existing PDF forms/outlines/signatures may not survive page copying or visual rewrites.

## Requirements

- Apple silicon Mac running macOS 26 or later.
- [Brisk](https://github.com/plyght/brisk) and the Xcode command-line tools (`swiftc`) to build.
- Optional: [LibreOffice](https://www.libreoffice.org/download/download-libreoffice/) in Applications for Office input conversion. Settings > Conversion reports availability. Yuzu does not install it automatically.
- Optional: a working local FFmpeg for non-native media codecs. Yuzu probes its actual encoders, decoders, muxers, and filters; select its executable in Settings. ZIP/RAR/7Z/TAR/GZIP use the OS archive library, with no separate extraction utility required.

## Build

```bash
git clone https://github.com/MohammadRadja/yuzu.git
cd yuzu
bash scripts/prepare-native.sh # build bundled libwebp with Apple Clang
brisk build            # debug .app in .build/debug/Yuzu.app
brisk run              # build and launch
brisk test             # compile and run Tests/ with the app sources
brisk build --release  # release .app in .build/release/Yuzu.app
brisk archive --release
scripts/package-dmg.sh # package the release output as dist/Yuzu-<version>.dmg
```

Source builds include libwebp 1.6.0 and its BSD license/patent notices. Static WebP and native GIF/video-to-WebP animation work without an external encoder or runtime package manager.

The DMG packaging script requires Xcode's asset tools. It includes the app icon and MIT license, excludes internal Markdown from the bundle, applies ad-hoc signing, verifies and mounts the compressed image, and preserves an existing installer before replacement. It also creates `dist/Yuzu-<version>-arm64.zip` from the same packaged app and `dist/Yuzu-<version>-SHA256SUMS.txt`, with extraction/content/signature checks. It does not perform Apple Developer ID signing or notarization.

During a Finder or Desktop drag, Yuzu polls `NSEvent.pressedMouseButtons`, `NSEvent.modifierFlags`, `NSEvent.mouseLocation` and the system drag pasteboard (`NSPasteboard(name: .drag)`). If Finder has not published the file URLs yet, a configured modifier plus sustained drag movement shows a non-actionable waiting state; the wheel then reads files and folders from the drag pasteboard or `NSDraggingInfo` as soon as they become available. It does not install key-event monitors or event taps. The current implementation does use global mouse monitors, so Accessibility/Input Monitoring behavior must be verified on each supported macOS configuration. Progress shows in a floating card or a small pill under the notch (Settings > Appearance); there are no system notifications.

## Logs

Yuzu writes a local activity log to `~/Library/Logs/Yuzu/yuzu.log` (drag selection, job start/finish, conversion steps, errors) and, if the process dies from a signal, a backtrace to `~/Library/Logs/Yuzu/crash.log`. "Show Logs" in the menu bar menu reveals them in Finder. The diagnostic logs stay local; sharing uses the service the user explicitly selects.

## Quality gates

```bash
scripts/check.sh        # format check, lint, build (type-check), tests
scripts/check.sh --fix  # apply swift-format fixes first
```

`scripts/check.sh` uses `swift-format` (Apple, ships with Xcode 16 / `wax install swift-format`), `swiftlint` (`wax install swiftlint`) when present, `brisk build` as the type-check and `brisk test` for the test suite. Missing optional linters are reported and skipped; the build and tests are mandatory.

## Verification status

The v1.1.0 candidate passed 97/97 primary tests, 36/36 process-owned GUI integration cases, 2/2 native-only tests, and 1/1 private-volume bookmark lifecycle test on arm64 macOS 27.0.1 / Xcode 27.1. Strict Xcode Swift Format lint passed for all 59 changed/new Swift files. SwiftLint is unavailable. The watermark/scanned-PDF OCR scenario runs in the owned AppKit host; all its assertions are retained, moving one case from the primary suite to the GUI suite. GUI integration uses real file operations and production controls, with fixture-supplied file-picker responses; it does not certify fresh-account Gatekeeper/privacy prompts, OS chooser navigation, Desktop-origin drags, or every accessibility/media/archive variant. See [CHANGELOG.md](CHANGELOG.md) for release changes and limits. Public v1.1.0 publication remains blocked by the [mandatory Xcode 27 OCR gate](https://github.com/MohammadRadja/yuzu/actions/runs/40448015219), which passed 95/95 primary cases; 0/3 OCR cases passed (all three failed). No OCR assertion is skipped.

The GitHub Actions workflow (`.github/workflows/ci.yml`) runs on the `macos-26` and `xcode-27` (macOS 27 / Xcode 27 SDK, public preview) runners: `brisk build`, `brisk test` (conversion matrix, naming, subtitle, PDF-range, tool-applicability, compression and timecode logic in `Tests/YuzuTests.swift`), then launches the app with `YUZU_SCREENSHOTS=<dir>` so `Sources/App/ScreenshotDriver.swift` generates sample media, opens the radial menu and the registered tool windows, and captures them with `screencapture`. Screenshots and verified release DMG/ZIP/checksums are uploaded as workflow artifacts. Actual Finder Shift-drag cannot be exercised on a headless runner and still need a manual check on a Mac.

## Project layout

```
.brisk.toml                Brisk manifest (bundle id com.radja.yuzu, LSUIElement)
Sources/App                App delegate, status item, settings
Sources/Formats            FileFormat enum, ConversionMatrix (305 static pairs, capability filtering, output naming)
Sources/Engines            Conversion engines: image, audio, video, document, subtitle, archive, ffmpeg bridge
Sources/Operations         Tool backends: ImageOps, VideoOps, AudioOps, PDFOps, MetadataOps, Compressor
Sources/Radial             Drag/session model, modifier monitor, radial menu, and file actions
Sources/Core               Job runner, progress HUD (card and notch pill), shell, media probing
Sources/Tools              Tool window shell, tool registry and 32 tool views
Tests                      Direct Swift tests run by `brisk test`
```

## Privacy

Yuzu contains no telemetry or analytics implementation in this repository and is designed for local-first processing. Files are read from disk, processed in memory or in a temporary folder under the user's temp directory, and written back as new files next to the originals. External conversion tools and future packaging must be reviewed separately before making stronger offline or sandboxing claims.

## License

Licensed under the [MIT License](LICENSE). The upstream copyright notice is preserved.
