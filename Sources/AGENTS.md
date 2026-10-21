# Source instructions

`Sources/` contains the Yuzu application. Keep boundaries between App, Core, Formats, Engines, Operations, Radial, Tools, and UI explicit. Preserve Swift 5 language mode and macOS 26 availability. Keep UI on the main actor, conversion work cancellable, subprocesses argument-safe, and errors user-actionable through `YuzuError`. Run relevant tests and update `docs/ARCHITECTURE.md` for structural changes.
