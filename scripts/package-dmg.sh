#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Package only the release output. Build it first with brisk build --release.
release_app="$PWD/.build/release/Yuzu.app"
plist="$release_app/Contents/Info.plist"
plist_buddy=/usr/libexec/PlistBuddy
[[ -f "$plist" ]] || { echo "Run brisk build --release first." >&2; exit 1; }
plutil -lint "$plist"
version="$($plist_buddy -c 'Print :CFBundleShortVersionString' "$plist")"
expected_version="$(awk '/^version = / { gsub(/"/, "", $3); print $3; exit }' .brisk.toml)"
[[ "$version" == "$expected_version" && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Release version does not match .brisk.toml." >&2; exit 1;
}
[[ "$($plist_buddy -c 'Print :CFBundleIdentifier' "$plist")" == com.radja.yuzu ]] || {
  echo "Unexpected bundle identifier." >&2; exit 1;
}
[[ -x "$release_app/Contents/MacOS/Yuzu" ]] || { echo "Missing executable." >&2; exit 1; }
[[ -f "$release_app/Contents/Resources/libyuzuwebp.dylib" ]] || { echo "Missing bundled WebP encoder. Run bash scripts/prepare-native.sh and rebuild." >&2; exit 1; }
[[ "$(lipo -archs "$release_app/Contents/Resources/libyuzuwebp.dylib")" == arm64 ]] || { echo "Expected arm64 WebP encoder." >&2; exit 1; }
codesign --verify --strict "$release_app/Contents/Resources/libyuzuwebp.dylib"
for notice in libwebp-COPYING.txt libwebp-PATENTS.txt; do
  cmp "Resources/$notice" "$release_app/Contents/Resources/$notice"
done
[[ "$(lipo -archs "$release_app/Contents/MacOS/Yuzu")" == arm64 ]] || {
  echo "Expected an arm64 release executable." >&2; exit 1;
}
minimum_macos="$($plist_buddy -c 'Print :LSMinimumSystemVersion' "$plist")"

# Retain staging and backups locally, including when packaging fails.
mkdir -p .build dist
staging_root="$(mktemp -d "$PWD/.build/dmg-stage.XXXXXX")"
payload="$staging_root/payload"
packaged_app="$payload/Yuzu.app"
mkdir -p "$packaged_app" "$staging_root/mount"
rsync -a --exclude='*.md' --exclude='.gitkeep' --exclude='_CodeSignature' \
  "$release_app/" "$packaged_app/"

# Brisk 0.2.0's direct backend omits actool's partial plist option; compile
# explicitly so the distributed bundle includes both the icon and asset catalog.
xcrun actool --compile "$packaged_app/Contents/Resources" --platform macosx \
  --minimum-deployment-target "$minimum_macos" --app-icon AppIcon \
  --output-partial-info-plist "$staging_root/icon-info.plist" "$PWD/Assets.xcassets"
plutil -replace CFBundleIconFile -string AppIcon "$packaged_app/Contents/Info.plist"
plutil -replace CFBundleIconName -string AppIcon "$packaged_app/Contents/Info.plist"
cp -p LICENSE "$packaged_app/Contents/Resources/LICENSE"
[[ -s "$packaged_app/Contents/Resources/AppIcon.icns" && -s "$packaged_app/Contents/Resources/Assets.car" ]]
[[ -z "$(find "$packaged_app" -iname '*.md' -print -quit)" ]] || {
  echo "Internal Markdown found in the package." >&2; exit 1;
}

# This is ad-hoc signing only, not Apple Developer ID signing or notarization.
codesign --force --sign - "$packaged_app"
codesign --verify --deep --strict "$packaged_app"
ln -s /Applications "$payload/Applications"
candidate="$staging_root/Yuzu-$version.dmg"
hdiutil create -volname Yuzu -srcfolder "$payload" -format UDZO "$candidate"
hdiutil verify "$candidate"

mounted=0
detach_image() {
  if (( mounted )); then
    hdiutil detach "$staging_root/mount"
  fi
}
trap detach_image EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$staging_root/mount" "$candidate"
mounted=1
[[ -d "$staging_root/mount/Yuzu.app" ]]
[[ "$(readlink "$staging_root/mount/Applications")" == /Applications ]]
codesign --verify --deep --strict "$staging_root/mount/Yuzu.app"
diff -qr "$packaged_app" "$staging_root/mount/Yuzu.app"
[[ "$(ls -A "$staging_root/mount" | wc -l | tr -d ' ')" == 2 ]]
hdiutil detach "$staging_root/mount"
mounted=0
trap - EXIT

# Distribute exactly the same signed, icon-complete app in both containers.
archive_name="Yuzu-$version-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$packaged_app" "$staging_root/$archive_name"
mkdir "$staging_root/zip-check"
ditto -x -k "$staging_root/$archive_name" "$staging_root/zip-check"
diff -qr "$packaged_app" "$staging_root/zip-check/Yuzu.app"
codesign --verify --deep --strict "$staging_root/zip-check/Yuzu.app"

checksum_name="Yuzu-$version-SHA256SUMS.txt"
(
  cd "$staging_root"
  shasum -a 256 "Yuzu-$version.dmg" "$archive_name" > "$checksum_name"
)
for artifact in "Yuzu-$version.dmg" "$archive_name" "$checksum_name"; do
  if [[ -e "$PWD/dist/$artifact" ]]; then
    backup_dir="$(mktemp -d "$PWD/dist/installer-backup.XXXXXX")"
    cp -p "$PWD/dist/$artifact" "$backup_dir/"
    cmp "$PWD/dist/$artifact" "$backup_dir/$artifact"
    echo "Previous artifact preserved: $backup_dir/$artifact"
  fi
  mv "$staging_root/$artifact" "$PWD/dist/$artifact"
done
(
  cd dist
  shasum -a 256 -c "$checksum_name"
)
echo "Installer: $PWD/dist/Yuzu-$version.dmg"
echo "Application ZIP: $PWD/dist/$archive_name"
echo "Checksums: $PWD/dist/$checksum_name"
echo "Packaged release app and staging retained: $staging_root"
