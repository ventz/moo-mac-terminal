#!/bin/bash

# Builds a drag-to-install DMG: the app on the left, an Applications alias on
# the right, sized and positioned so the window explains itself on open.

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 APP_PATH OUTPUT_DMG [VOLUME_NAME]" >&2
    exit 64
fi

app_path="$1"
output_path="$2"
volume_name="${3:-Moo}"

if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
    echo "The app path is not an application bundle: $app_path" >&2
    exit 66
fi

if [[ "$output_path" != *.dmg ]]; then
    echo "The output path must end in .dmg: $output_path" >&2
    exit 64
fi

app_name="$(basename "$app_path")"
output_directory="$(dirname "$output_path")"
mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
output_path="$output_directory/$(basename "$output_path")"

staging_directory="$(mktemp -d "$output_directory/moo-dmg.XXXXXX")"
temp_dmg="$staging_directory/rw.dmg"
mount_point=""
cleanup() {
    if [[ -n "$mount_point" && -d "$mount_point" ]]; then
        hdiutil detach "$mount_point" -quiet -force 2>/dev/null || true
    fi
    rm -rf "$staging_directory"
}
trap cleanup EXIT

payload="$staging_directory/payload"
mkdir -p "$payload"
ditto "$app_path" "$payload/$app_name"
ln -s /Applications "$payload/Applications"

# A read/write image first, so the Finder window layout can be set and saved
# into the volume's .DS_Store, then converted to the compressed image shipped.
# 64 MB of slack is enough for the layout metadata.
size_kb=$(du -sk "$payload" | awk '{print $1}')
hdiutil create -srcfolder "$payload" -volname "$volume_name" \
    -fs HFS+ -format UDRW -size $((size_kb + 65536))k -quiet "$temp_dmg"

mount_point="/Volumes/$volume_name"
hdiutil attach "$temp_dmg" -readwrite -noverify -noautoopen -quiet
# The Finder needs a moment after attach before it will accept scripting.
sleep 2

osascript <<APPLESCRIPT || echo "note: could not set the window layout; the DMG is still valid" >&2
tell application "Finder"
    tell disk "$volume_name"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 150, 800, 550}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set text size of theViewOptions to 13
        set position of item "$app_name" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$mount_point" -quiet
mount_point=""

hdiutil convert "$temp_dmg" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "$output_path"
echo "created: $output_path"
