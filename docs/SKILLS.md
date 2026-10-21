# Yuzu maintenance skills

Each competency below is tied to the current implementation and should be maintained with source review and tests.

## Swift and SwiftUI

Purpose: implement the application, settings, radial content, tools, and observable job state. Technology: Swift 5 mode, SwiftUI, Combine, and Swift concurrency. References: `Sources/App.swift`, `Sources/App/SettingsView.swift`, `Sources/Core/JobRunner.swift`, and `Sources/Tools/`. Practice: keep state ownership clear and UI updates on the main actor. Pitfalls: retain cycles, unavailable APIs, blocking the main actor, and breaking view identity.

## AppKit and macOS application lifecycle

Purpose: integrate status items, panels, native file selection, event handling, and accessory activation. Technology: AppKit and `NSApplicationDelegate`. References: `Sources/App/AppDelegate.swift`, `Sources/Radial/RadialView.swift`, and `Sources/Tools/ToolWindowManager.swift`. Practice: manage window and monitor lifetimes explicitly. Pitfalls: stale event monitors, activation-policy surprises, and untested permission behavior.

## Keyboard shortcuts and window management

Purpose: make radial selection and utility windows efficient without a mouse. Technology: `NSEvent.keyDown`, local monitors, `NSPanel`, `NSWindow`, and `ToolWindowManager`. References: `Sources/Radial/RadialView.swift`, `Sources/Tools/Video/TrimSplitVideoToolViews.swift`, and `Sources/Tools/ToolWindowManager.swift`. Practice: preserve Escape, Return, arrow-key, and Option semantics and clean up local monitors. Pitfalls: key events reaching the wrong window, focus loss, and leaked panels.

## Filesystem and drag-and-drop

Purpose: accept user files and create safe outputs. Technology: `FileManager`, `NSPasteboard`, `NSDraggingInfo`, `URL`, and `NSOpenPanel`. References: `Sources/Radial/DragMonitor.swift`, `Sources/Radial/RadialView.swift`, and `Sources/Formats/ConversionMatrix.swift`. Practice: validate file URLs and collision names. Pitfalls: symlinks, directories, traversal, permissions, and source overwrites.

## Concurrency and memory

Purpose: keep conversions responsive and cancellable. Technology: `async/await`, `Task`, actors, `DispatchQueue`, and `AsyncSemaphore`. References: `Sources/Core/JobRunner.swift`, `Sources/Core/Shell.swift`, and `Sources/Engines/FFmpeg.swift`. Practice: propagate cancellation and clean resources. Pitfalls: races around process pipes, UI updates off the main actor, and leaked monitors or windows.

## File conversion architecture and media frameworks

Purpose: support format conversion and advanced media operations. Technology: ImageIO, Core Graphics, AVFoundation, PDFKit, Core Text, Foundation archives, and `ConversionEngine`. References: `Sources/Engines/`, `Sources/Operations/`, `Sources/Formats/`. Practice: use native APIs first and stage output. Pitfalls: codec availability, metadata loss, large-memory images, malformed documents, and partial output.

## File format identification

Purpose: map user files to safe conversion and tool choices. Technology: `FileFormat`, extension aliases, Uniform Type Identifiers, and `ConversionMatrix`. References: `Sources/Formats/FileFormat.swift`, `Sources/Formats/ConversionMatrix.swift`, and `Tests/YuzuTests.swift`. Practice: keep aliases, displayed names, UTTypes, and engine support consistent. Pitfalls: extension spoofing, compound extensions such as `.tar.gz`, and assuming an extension proves file contents.

## Image and PDF processing

Purpose: render, encode, transform, paginate, merge, and split visual documents. Technology: ImageIO, Core Graphics, PDFKit, and Core Text. References: `Sources/Engines/ImageEngine.swift`, `Sources/Engines/DocumentEngine.swift`, `Sources/Operations/ImageOps.swift`, and `Sources/Operations/PDFOps.swift`. Practice: bound pixel sizes, validate page ranges, and stage outputs. Pitfalls: memory spikes, transparency/color loss, password-protected PDFs, and incomplete redaction.

## FFmpeg and subprocesses

Purpose: cover formats unavailable through native frameworks. Technology: `FFmpeg` and `Shell` wrappers around `Process`. References: `Sources/Engines/FFmpeg.swift` and `Sources/Core/Shell.swift`. Practice: pass argument arrays, validate executable paths, support cancellation, and summarize errors. Pitfalls: `-y` overwrite behavior, untrusted protocols, PATH differences, and missing shared libraries.

## Testing and debugging

Purpose: preserve conversion behavior and diagnose platform issues. Technology: direct Swift test runner, Swift Format, SwiftLint, logs, and screenshot driver. References: `Tests/YuzuTests.swift`, `scripts/check.sh`, `Sources/App/ScreenshotDriver.swift`, and `Sources/Core/DiagnosticLog.swift`. Practice: test edge cases and record unsupported runtime validation. Pitfalls: treating CI screenshots as Finder-drag coverage or assuming macOS 15 can build a macOS 26 target.

## Performance profiling

Purpose: keep drag interaction, previews, and media processing responsive on Apple Silicon hardware. Technology: Instruments, Activity Monitor, signposts/log review, and bounded task concurrency. References: `Sources/Core/JobRunner.swift`, `Sources/Tools/Shared/`, and `Sources/Engines/`. Practice: profile representative large files and measure memory, CPU, I/O, and cancellation latency. Pitfalls: profiling only synthetic media, unbounded image allocations, and blocking the main actor.

## Brisk and Git

Purpose: build, test, archive, and maintain history. Technology: Brisk manifest commands and Git. References: `.brisk.toml`, `scripts/check.sh`, and `docs/DEVELOPMENT.md`. Practice: review diffs, preserve history, and do not change remotes or push without permission. Pitfalls: building against an unsupported OS, relying on ignored `.brisk/` output, and destructive Git commands.

## GitHub Actions and application packaging

Purpose: validate the supported toolchain and produce internal artifacts. Technology: GitHub Actions, arm64 Brisk archives, asset catalogs, signing, and app bundle metadata. References: `.github/workflows/ci.yml`, `.brisk.toml`, and `Assets.xcassets/`. Practice: verify executable names, resources, bundle identifier, icon provenance, signing, and archive contents. Pitfalls: treating headless screenshots as manual QA, ad-hoc signing, and unverified packaging claims.
