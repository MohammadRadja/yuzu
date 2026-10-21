# Engine instructions

Engines implement `ConversionEngine` for native media/document/archive paths and FFmpeg integration. Validate source and target formats, stage output, report progress, clean temporary files, and preserve source files. External tool invocation must use `Shell` with separate arguments. Add regression tests for format support, malformed input, cancellation, and cleanup.
