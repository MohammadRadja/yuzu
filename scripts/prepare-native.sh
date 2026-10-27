#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Build the pinned upstream source using only Apple's C toolchain. No download,
# package manager, configure script, or third-party build executable is required.
webp_archive=Vendor/libwebp-1.6.0.tar.gz
webp_digest=e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
[[ "$(shasum -a 256 "$webp_archive" | awk '{print $1}')" == "$webp_digest" ]] || {
  echo "libwebp source checksum mismatch" >&2; exit 1;
}
webp_output=.build/native/libyuzuwebp.dylib
if [[ -f "$webp_output" && "$webp_output" -nt "$webp_archive" && "$webp_output" -nt "$0" && "$webp_output" -nt Vendor/WebPAnimationBridge.c ]]; then
  exit 0
fi
mkdir -p .build/native
webp_work="$(mktemp -d "$PWD/.build/webp.XXXXXX")"
trap 'rm -rf "$webp_work"' EXIT
tar -xzf "$webp_archive" -C "$webp_work"
webp_root="$webp_work/libwebp-1.6.0"
webp_sources=()
while IFS= read -r webp_source; do webp_sources+=("$webp_source"); done < <(
  find "$webp_root/src/dec" "$webp_root/src/dsp" "$webp_root/src/enc" "$webp_root/src/utils" "$webp_root/src/mux" "$webp_root/src/demux" "$webp_root/sharpyuv" -name '*.c' -type f | LC_ALL=C sort
)
xcrun clang -dynamiclib -arch arm64 -mmacosx-version-min=26.0 -O2 -DNDEBUG \
  -DWEBP_USE_THREAD -I "$webp_root" "${webp_sources[@]}" Vendor/WebPAnimationBridge.c \
  -install_name @rpath/libyuzuwebp.dylib -o "$webp_work/libyuzuwebp.dylib"
[[ "$(lipo -archs "$webp_work/libyuzuwebp.dylib")" == arm64 ]]
codesign --force --sign - "$webp_work/libyuzuwebp.dylib"
mv "$webp_work/libyuzuwebp.dylib" "$webp_output"
echo "Built bundled libwebp: $webp_output"
