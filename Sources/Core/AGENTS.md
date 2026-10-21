# Core instructions

Core provides `JobRunner`, `Shell`, `MediaInfo`, diagnostics, and `YuzuError`. Keep asynchronous work cancellable, avoid blocking the main actor, drain subprocess pipes, and clean temporary resources. Do not turn user paths into shell commands. Test error, cancellation, collision, and process-failure paths.
