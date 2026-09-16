#!/bin/bash

# Builds a drag-to-install DMG: the app on the left, an Applications alias on
# the right, an arrow between them on a background image that says what to do.

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 APP_PATH OUTPUT_DMG [VOLUME_NAME]" >&2
    exit 64
fi

app_path="$1"
output_path="$2"
volume_name="${3:-Moo}"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
background_source="$script_directory/dmg/background.tiff"

if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
    echo "The app path is not an application bundle: $app_path" >&2
    exit 66
fi

if [[ "$output_path" != *.dmg ]]; then
    echo "The output path must end in .dmg: $output_path" >&2
    exit 64
fi

# Two runs at once would both want /Volumes/<volume_name>, and the second would
# silently land on a "-1" mount whose layout is never saved.
if [[ -d "/Volumes/$volume_name" ]]; then
    echo "A volume named '$volume_name' is already mounted; detach it first." >&2
    exit 65
fi

app_name="$(basename "$app_path")"
output_directory="$(dirname "$output_path")"
mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
output_path="$output_directory/$(basename "$output_path")"

staging_directory="$(mktemp -d "$output_directory/moo-dmg.XXXXXX")"
temp_dmg="$staging_directory/rw.dmg"
device=""
cleanup() {
    if [[ -n "$device" ]]; then
        hdiutil detach "$device" -quiet -force 2>/dev/null || true
    fi
    rm -rf "$staging_directory"
}
trap cleanup EXIT

payload="$staging_directory/payload"
mkdir -p "$payload"
ditto "$app_path" "$payload/$app_name"

has_background=0
if [[ -f "$background_source" ]]; then
    mkdir -p "$payload/.background"
    cp "$background_source" "$payload/.background/background.tiff"
    has_background=1
fi

# A read/write image first, so the Finder window layout can be set and saved
# into the volume's .DS_Store, then converted to the image that ships.
size_kb=$(du -sk "$payload" | awk '{print $1}')
hdiutil create -srcfolder "$payload" -volname "$volume_name" \
    -fs HFS+ -format UDRW -size $((size_kb + 65536))k -quiet "$temp_dmg"

device=$(hdiutil attach "$temp_dmg" -readwrite -noverify -noautoopen \
    | awk '/^\/dev\/disk/ {print $1; exit}')
mount_point="/Volumes/$volume_name"

# The Applications alias is made inside the mounted volume rather than in the
# source folder. Both produce a working drag-to-install link, but creating it
# here lets the Finder index it and cache its folder icon into the volume's
# .DS_Store; made beforehand it renders as an empty dashed placeholder.
ln -s /Applications "$mount_point/Applications"

# The Finder needs a moment after attach before it accepts scripting.
sleep 2

background_clause=""
if [[ $has_background -eq 1 ]]; then
    background_clause="set background picture of theViewOptions to file \".background:background.tiff\""
fi

osascript <<APPLESCRIPT || echo "note: could not set the window layout; the DMG is still valid" >&2
tell application "Finder"
    tell disk "$volume_name"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 568}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 160
        set text size of theViewOptions to 14
        $background_clause
        set position of item "$app_name" of container window to {170, 190}
        set position of item "Applications" of container window to {490, 190}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$device" -quiet
device=""

hdiutil convert "$temp_dmg" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "$output_path"
echo "created: $output_path"
