# Yuzu development guide

## Prerequisites

The project manifest requires macOS 26 or later, Apple Silicon (`arm64`), Swift 5 language mode as configured in `.brisk.toml`, Brisk, and the Xcode command-line tools. FFmpeg is optional for non-native media conversions; `unar` is optional for RAR extraction. LibreOffice is optional for Office input conversion and is discovered in Applications or the existing executable search paths. The repository does not pin installation commands for Brisk, FFmpeg, or unar, so use their current upstream/documented installation methods rather than copying an unverified command here.

An earlier reported development machine used macOS Sequoia 15.5 and Swift 6.1.2. The October 2026 radial update was developed on an arm64 host reporting macOS 27.0.1, Swift 6.4, and the macOS 27 SDK from Xcode. This host meets the manifest deployment target; no system software was installed or upgraded.

## Validation boundary

Available even on macOS 15.5:

- Repository inspection, source edits, documentation, and Git operations.
- Static searches, configuration review, formatting/linting if tools are installed, and license review.

Requires macOS 26+ or further verification:

- `brisk build`, full application compilation, and runtime launch.
- SwiftUI/AppKit interaction validation, Finder drag behavior, screenshot automation, packaging, and distribution.

Validation on 2026-10-22: `scripts/check.sh` built the arm64 application and passed all 48 direct-runner tests with LibreOffice 26.2.3.2 already present on the host. The check script skipped formatter/linter executables that were absent from PATH. Xcode’s Swift Format was subsequently found through `xcrun`; formatting and strict lint were run successfully on all changed Swift source and test files. SwiftLint remains unavailable. Temporary SwiftUI renders were inspected with one, two, four, six, and nine items. Native Liquid Glass was also inspected in temporary transparent windows over a generated blue/green background under both system appearances; the radial remains light. These fixture checks do not establish live Finder drag behavior or other live interaction.

Do not bypass the deployment target or automatically upgrade macOS, Xcode, Swift, or system dependencies.

## Repository commands

Commands verified from the repository are:

```bash
brisk build
brisk run
brisk test
brisk archive --release
scripts/check.sh
scripts/check.sh --fix
```

`scripts/check.sh` runs Swift Format and SwiftLint when present, then makes `brisk build` and `brisk test` mandatory. `.brisk.toml` supplies the Yuzu name, `com.radja.yuzu` bundle identifier, macOS 26 deployment target, arm64 architecture, frameworks, asset catalog, resources, and archive paths.

## Development workflow

1. Inspect `AGENTS.md`, the applicable nested instructions, source, tests, and Git status.
2. Make the smallest change that preserves behavior.
3. Update tests and the relevant document when behavior changes.
4. Run formatting, linting, build, and tests at the highest level supported by the host.
5. Review the diff for accidental branding, dependency, permission, or license changes.

Use `Tests/YuzuTests.swift` for direct test-runner coverage. Tests cover the conversion matrix, format detection, output naming, subtitle parsing/serialization, PDF ranges, tool applicability, radial mode defaults, provider capability separation, drag URL normalization, compression logic, timecode behavior, full matrix engine coverage, quoted CSV/TSV parsing, package paths/XML, native PPTX/XLSX/EPUB creation, RTFD import, staging cleanup, overwrite refusal, and subprocess cancellation/launch failures.

Office integration tests run when LibreOffice is discoverable; otherwise the runner prints an explicit skip and the 47 native/core tests still run. The macOS CI workflow does not install LibreOffice. Local fixtures verify PDF-to-PPTX and back, rendered slide images, XLSX/ODS-to-TSV with literal formulas, leading zeros, tabs/newlines, OOXML escape-like text, legacy PPT/XLS input, DOCX and RTF input, and DOCX-to-EPUB/Markdown/HTML. PAGES import compatibility has not been verified with a real Pages fixture. PAGES output and text-clipping input are not implemented.

The four-mode radial still needs manual validation on a supported macOS 26+ desktop: Finder and Desktop drags, modifier switching within one drag, modifier release, multiple and mixed selections, unsupported inputs, Escape/Return/arrow-key behavior, light/dark appearance, reduced motion, screen edges, and Accessibility/VoiceOver. Verify Copy, Copy Path, Move and Rename collision handling, AirDrop availability, Terminal launch, and Tasks’ Optimize/Organize/Rename/Share entries with non-sensitive fixture paths. CI and `brisk test` do not exercise those GUI and permission boundaries.

## CI, debugging, and release

`.github/workflows/ci.yml` runs on `macos-26` and `xcode-27`, installs Brisk and FFmpeg, runs build/test, launches the screenshot driver with `YUZU_SCREENSHOTS`, uploads screenshots, archives the release, and uploads `Yuzu.zip`. The screenshot driver is not a substitute for manual Finder drag testing.

Use `YUZU_DEBUG_DRAG` for drag-monitor diagnostics. Runtime logs are written by `DiagnosticLog` under `~/Library/Logs/Yuzu/yuzu.log`; crash backtraces use the adjacent `crash.log`. Do not include sensitive user file paths in bug reports without review.

For internal distribution, verify the deployment target, arm64 output, archive contents, icon provenance, signing identity, permissions, and third-party tool expectations. The manifest currently uses ad-hoc signing (`identity = "-"`) and does not establish a notarization workflow.
