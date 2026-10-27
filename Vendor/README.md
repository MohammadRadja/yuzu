# Bundled WebP encoder

`libwebp-1.6.0.tar.gz` is the unmodified upstream release from
https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz.
SHA-256: `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564`.

`scripts/prepare-native.sh` checks this digest and builds an arm64 macOS 26+
dynamic library with Apple's Clang. It does not execute the archive's build
scripts. There are no non-system dynamic dependencies. Static encoding calls
the RGBA encoder and memory release API; input decoding uses native frameworks.
The generated library is an app resource, signed before the containing app.
`WebPAnimationBridge.c` is a small MIT-licensed Yuzu adapter that keeps the
versioned encoder/decoder structs in C. GIF frames and native video snapshots
can be encoded as animated WebP without FFmpeg, and generated animations are
decoded for validation. Animation is bounded to 640 pixels, 5,000 frames, and
400 seconds for videos. Optional FFmpeg remains a fallback for non-native video.
No runtime installation, download, Homebrew, or network call is required.

Upstream BSD license and patent grant are distributed in
`Resources/libwebp-COPYING.txt` and `Resources/libwebp-PATENTS.txt`.
Keep those notices and this provenance when updating the archive. Recheck
security fixes, API compatibility, digest, architecture, dependency list, bundle
size, and signing on every update. The current application is ad-hoc signed;
Developer ID signing and notarization remain a release requirement, not a claim.
