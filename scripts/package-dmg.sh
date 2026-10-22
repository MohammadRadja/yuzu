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

installer="$PWD/dist/Yuzu-$version.dmg"
if [[ -e "$installer" ]]; then
  backup_dir="$(mktemp -d "$PWD/dist/installer-backup.XXXXXX")"
  cp -p "$installer" "$backup_dir/"
  cmp "$installer" "$backup_dir/$(basename "$installer")"
  echo "Previous installer preserved: $backup_dir"
fi
mv "$candidate" "$installer"
shasum -a 256 "$installer"
echo "Installer: $installer"
echo "Packaged release app and staging retained: $staging_root"
