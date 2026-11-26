#!/bin/bash
# Packages an app into a drag-to-install disk image: the app, an Applications symlink and an arrow background.
# Usage: scripts/make-dmg.sh <path/to/App.app> <output.dmg> [volume name]
# Finder lays out the window, so this needs a logged-in GUI session that may automate Finder.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: make-dmg.sh <App.app> <output.dmg> [volume name]}"
DMG="${2:?usage: make-dmg.sh <App.app> <output.dmg> [volume name]}"
APP_NAME="$(basename "$APP")"
VOLUME_NAME="${3:-${APP_NAME%.app}}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/make-dmg.XXXXXX")"
DEVICE=""
cleanup() {
  if [[ -n "$DEVICE" ]]; then
    hdiutil detach "$DEVICE" -quiet || hdiutil detach "$DEVICE" -force -quiet || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
swift scripts/make-dmg-background.swift "$WORK/background.png" 1
swift scripts/make-dmg-background.swift "$WORK/background@2x.png" 2
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

# Headroom for the .DS_Store Finder writes.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLUME_NAME" -fs HFS+ -format UDRW \
  -size "${SIZE_MB}m" "$WORK/rw.dmg"

ATTACH="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen)"
DEVICE="$(awk 'NR==1 { print $1 }' <<<"$ATTACH")"
MOUNT="$(grep -o '/Volumes/.*' <<<"$ATTACH" | tail -1)"

# Positions are icon centers and must match scripts/make-dmg-background.swift. Finder only saves the
# window bounds and view options reliably after the window is reopened and resized.
osascript - "$MOUNT" "$APP_NAME" <<'APPLESCRIPT'
on run {mountPath, appName}
  tell application "Finder"
    set dmgVolume to (POSIX file mountPath) as alias
    open dmgVolume
    set win to container window of dmgVolume
    set current view of win to icon view
    set toolbar visible of win to false
    set statusbar visible of win to false
    set bounds of win to {200, 120, 800, 548}
    set position of item appName of dmgVolume to {150, 190}
    set position of item "Applications" of dmgVolume to {450, 190}
    close win
    open dmgVolume
    set win to container window of dmgVolume
    set backgroundImage to (POSIX file (mountPath & "/.background/background.tiff")) as alias
    tell icon view options of win
      set arrangement to not arranged
      set icon size to 128
      set background picture to backgroundImage
    end tell
    delay 1
    set bounds of win to {200, 120, 790, 538}
    delay 1
    set bounds of win to {200, 120, 800, 548}
    update dmgVolume without registering applications
    delay 3
    close win
  end tell
end run
APPLESCRIPT

# Finder writes .DS_Store asynchronously; wait until it exists and has stopped changing.
previous=""
for _ in {1..30}; do
  current="$(stat -f %m:%z "$MOUNT/.DS_Store" 2>/dev/null || true)"
  [[ -n "$current" && "$current" == "$previous" ]] && break
  previous="$current"
  sleep 1
done
if ! grep -q backgroundImageAlias "$MOUNT/.DS_Store" 2>/dev/null; then
  echo "error: Finder did not save the disk image layout" >&2
  exit 1
fi
sync
hdiutil detach "$DEVICE" -quiet
DEVICE=""

rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
