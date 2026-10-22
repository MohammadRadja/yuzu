# Yuzu security guidelines

## Security posture

Yuzu is designed for local-first processing, but this repository does not prove that it is fully offline, sandboxed, or secure against every input. The application reads user-selected paths, invokes optional external tools, writes outputs, and logs diagnostic information. Treat all of those boundaries as security-sensitive.

## Existing controls

- `Shell.run` uses `Process.executableURL` and an argument array rather than a shell command string.
- `FFmpeg.run` adds `-nostdin`, supports cancellation, and reports bounded summaries of tool failures.
- `FileFormat.detect` limits supported formats by known extensions and aliases.
- Conversion output is staged under a UUID-based hidden sibling and moved after engine completion.
- Sources are not intentionally overwritten by conversion; output collision naming is handled by `ConversionMatrix`.
- Office conversions use a separate temporary LibreOffice profile per job with macros disabled, Writer/Calc link updates disabled, and update checks disabled. The original is copied before conversion; no automation permission is added.
- EPUB imports read validated individual ZIP members through bounded pipes and never extract untrusted entry paths. XML DTDs/entities and excessive nesting are rejected.
- Native XLSX exports store untrusted cell content as inline strings, never executable formulas.
- `Engines.convert` refuses same-path source/output and existing-file overwrite, cleans staging on all exits, and returns the committed output URL.
- Diagnostics are local files under the user's Library Logs directory.

These controls are implementation observations, not a security guarantee.

## Required practices

Validate file URLs, existence, regular-file status, readable input, output directories, and format compatibility before work begins. Reject path traversal and absolute paths when unpacking archives; extraction must remain inside a controlled directory and symlinks/hard links require explicit handling. Avoid following symlinks when a workflow assumes a regular file.

Pass external-tool arguments as separate values. Never interpolate paths into `sh -c`, shell pipelines, or command strings. Resolve executables from trusted configured paths and verify executability. Review every new FFmpeg or archive argument for overwrite, network, protocol, and resource implications.

Use unique temporary directories with restrictive permissions, clean them on success, failure, and cancellation, and avoid logging document contents or sensitive metadata. Do not claim that deletion securely erases data. Preserve user permissions where possible and never broaden file permissions unnecessarily.

The LibreOffice integration is an external document parser, not a sandbox. Configuration disables automatic link updates but does not prove that every importer cannot fetch an embedded remote resource; no network-isolation guarantee is made. Keep LibreOffice maintained, use trusted fixture data for testing, and review unusual or hostile documents before distribution. EPUB text is limited to 8 MB per member and 32 MB overall; package listings are capped at 2 MB / 10000 unique entries. Native CSV/TSV input is limited to 32 MB, spreadsheet cells to 32767 UTF-16 units, and PDF-to-PPTX to 1000 pages / 256 MB of rendered images.

## macOS permissions and packaging

The current code uses global event monitors and file panels. Permission behavior must be verified on supported macOS versions; do not promise that Accessibility or Input Monitoring permissions are never needed without testing. The repository has no declared App Sandbox entitlement and uses ad-hoc signing, so packaging is not a hardened distribution configuration. A future sandboxed build will need security-scoped URL handling and bookmark lifecycle design.

Review launch-at-login registration, status-item behavior, crash logs, and user-selected FFmpeg paths as privileged or sensitive boundaries. Keep external dependencies minimal and review their provenance, versions, licenses, and release artifacts.

## Testing and response

Security tests should cover traversal entries, symlinks, malformed media, oversized inputs, unwritable destinations, cancellation during subprocess execution, executable-path validation, output collisions, and sensitive logging. Add regression tests before changing these boundaries.

Do not invent a security contact address. Report a suspected vulnerability through the repository owner's established private channel after verifying it; avoid publishing exploit details in a public issue until coordinated disclosure is possible.
