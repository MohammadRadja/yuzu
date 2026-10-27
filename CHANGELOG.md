# Changelog

## [1.1.0] - Unreleased

### New Features

- Add ICO/ICNS export, multi-image animated GIF creation, GIF/native-video to animated WebP, HTML text import, PDF-to-SVG, modern text clippings, JSON/YAML, and XML/JSON conversions. The static registry contains 305 single-file pairs; runtime availability depends on backend capabilities.
- Add safe ZIP creation and system-libarchive extraction for ZIP/RAR/7Z/TAR/GZIP, selected-entry archive inspection/repacking, and optional AES-256 ZIP export when supported by the OS backend.
- Add Make a Copy, Trash confirmation, Reveal, Quick Look, Inspect, Open With, New Folder with Selection, and the macOS Share picker.
- Add reviewed Batch Rename, Smart Organize, Batch Optimize reports, Workflow Builder, Duplicate Finder, and a persistent bookmark-based File Shelf.
- Add image/PDF watermarks, local OCR to TXT, authorized PDF password changes, Vision background removal, Lanczos upscale, PDF visual signatures, and file-content comparison. The Tools registry contains 32 tools.

### Improvements

- Keep Convert, Tools, Actions, and Tasks distinct; use More panels for long action lists and retain legacy Shift+Option access.
- Bundle libwebp 1.6.0 from pinned source with BSD license/patent notices; native WebP encoding needs no runtime package manager.
- Probe actual FFmpeg encoders, decoders, muxers, and filters before advertising optional routes; report availability in Settings.
- Validate staged outputs, declared extensions, source aliases, permissions, cancellation, and existing destinations before publication.
- Add offline archive/Pages fixtures, process-owned GUI integration, native-only checks, and bookmark volume-lifecycle coverage.
- Produce an icon-complete DMG and application ZIP from the same signed app, with SHA-256 checksums and package verification.

### Bug Fixes

- Fix WebP encoding availability and reject raw HEVC output incorrectly presented as HEIC.
- Preserve transparent PNG format during compression, including target-size requests.
- Clear stale file URLs when copying paths and use native multi-item file clipboard representations.
- Escape literal OOXML package members such as `[Content_Types].xml` when reading ZIP contents.
- Reject archive traversal, links, conflicting names, and extraction budget overruns; remove shell-based gzip extraction.
- Detect file move/rename conflicts before changes and roll back partial batch operations.
- Close successful archive panels only after all submitted jobs succeed; dismiss completed progress independently of running jobs or retained failures.
- Keep cancellation and late progress from reviving finished jobs; improve accessible action names and controls.

### Compatibility

- Requires Apple silicon (arm64) and macOS 26.0 or later; bundle identifier remains `com.radja.yuzu`.
- Native conversions, bundled WebP, OCR, and OS archive operations work without Homebrew. Optional non-native media codecs require a working local FFmpeg; supported Office input routes require LibreOffice. Neither is bundled or installed automatically.
- Source builds require Brisk and Apple's Xcode tools; run `bash scripts/prepare-native.sh` before a clean build. Existing Satsuma attribution and MIT license are preserved.

### Known Limitations

- Public release is blocked: all three mandatory OCR integration cases fail on the Xcode 27 CI host with `TextRecognition.CRImageReaderError` code 9, despite passing on the local macOS 27 host and macOS 26 CI. The cause is unresolved; no test is skipped.

- Ad-hoc signed only; no Apple Developer ID signature, hardened runtime, notarization, or stapled ticket. First-launch Gatekeeper/privacy behavior requires manual verification; do not disable macOS security controls.
- Fresh-profile installation, native file-picker navigation, Desktop-origin drags, full VoiceOver/keyboard/appearance coverage, and additional media/archive variants remain manual acceptance work. Process-owned GUI checks do not certify them.
- PDF-to-SVG embeds raster pages; PDF-to-PPTX uses image slides; PDF-to-XLSX extracts text. PDF rewrites may discard forms/outlines or invalidate existing digital signatures. Visual signatures are image overlays, not cryptographic signatures.
- HTML import is text-only without web-resource loading. YAML supports a bounded subset; XML comments/processing instructions are not retained. Legacy resource-fork-only text clippings are rejected. Pages fidelity depends on LibreOffice and document version.
- Upscale uses interpolation rather than AI reconstruction. Background-mask quality and partial-frame GIF disposal/transparency/timing need broader review. WebP animations are bounded to 640 pixels and 5,000 frames; videos to 400 seconds at 12 fps.
- Archive compression/encryption/multi-volume support depends on the OS reader. Extraction limits are intentional. Duplicate Finder reviews files without deleting originals; completed Batch Optimize copies remain after cancellation.

## [1.0.0] - 2026-10-22

Initial public, MIT-licensed Yuzu release derived from Satsuma, with a four-mode radial interface, 253 conversion pairs, and 25 tools. Distributed for arm64 macOS 26+ with ad-hoc signing and no Apple notarization.

[1.1.0]: https://github.com/MohammadRadja/yuzu/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/MohammadRadja/yuzu/releases/tag/v1.0.0
