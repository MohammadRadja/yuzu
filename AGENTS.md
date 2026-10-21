# Yuzu agent instructions

## Project

Yuzu is a native, local-first macOS file conversion and utility application derived from the open-source Satsuma project. It is maintained as `yuzu-tools`, uses bundle identifier `com.radja.yuzu`, targets Apple Silicon, and is built with Brisk. The application combines SwiftUI and AppKit and runs as a menu-bar accessory app.

Read this file before changing the repository. Read the nearest nested `AGENTS.md` files before changing files in their directories. The detailed technical source of truth is in `docs/`.

## Architecture principles

- Preserve the existing native-first conversion pipeline and user-visible behavior.
- Keep AppKit integration at the application/window/event boundaries; keep reusable views and presentation state in SwiftUI where practical.
- Pass subprocess arguments as arrays through `Shell`; never construct shell command strings or interpolate untrusted paths into a shell.
- Stage conversion output, check cancellation, clean up temporary files, and avoid modifying the source file.
- Keep UI work on the main actor and long-running conversion work asynchronous.
- Prefer Foundation, UniformTypeIdentifiers, ImageIO, AVFoundation, PDFKit, Core Text, and other system frameworks before external tools.

## Swift conventions

- Use Swift 5 language mode as configured by `.brisk.toml`; keep code compatible with the deployment target unless an API is availability-guarded.
- Use explicit, descriptive names and small focused types. Do not rename public or cross-module symbols without checking every reference.
- Use `guard` for invalid input and throw `YuzuError` with user-actionable messages.
- Avoid force unwraps in new code. Use `Task.checkCancellation()` in long operations and make cleanup unconditional with `defer`.
- Respect SwiftUI identity and AppKit ownership rules; avoid retain cycles in callbacks and event monitors.

## Security and data handling

- Treat dragged paths, selected files, archive entries, metadata, and FFmpeg output as untrusted.
- Validate file URLs and formats before opening them. Do not follow archive paths outside the intended extraction directory.
- Do not add telemetry, network calls, analytics, or permissions without explicit design and security review.
- Do not claim sandboxing, offline operation, or permission behavior beyond what the code and packaging configuration verify.
- Preserve license notices and credit Satsuma as upstream. Do not copy Tangerine proprietary branding or assets.

## Testing and validation

- Update or add tests for behavioral changes. Keep conversion-matrix counts and tool counts intentional.
- Run `scripts/check.sh` when the available toolchain supports it. On macOS versions below the manifest deployment target, use static inspection and clearly report that build/runtime validation is unavailable.
- Run Swift formatting and linting when installed; do not install or upgrade system software automatically.
- Never push, change remotes, reset history, or delete `.git/` without explicit permission.

## Documentation

Update the relevant file in `docs/` when architecture, security behavior, design behavior, development commands, or maintenance skills change. Keep existing behavior separate from proposals. See `docs/AGENTS.md` for the documentation workflow.
