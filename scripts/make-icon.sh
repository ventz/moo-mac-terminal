#!/bin/bash

# Regenerates the app icon and the README icon from assets/moo.png.
# Run this when the artwork changes; the outputs are committed so a build
# needs nothing but Xcode.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_png="$repo/assets/moo.png"
iconset="$(mktemp -d)/Moo.iconset"
trap 'rm -rf "$(dirname "$iconset")"' EXIT

[[ -f "$source_png" ]] || { echo "missing $source_png" >&2; exit 66; }
mkdir -p "$iconset"

# Cut the opaque backdrop to transparency and square to 1024 in one step:
# .icns wants exact power-of-two sizes, and scaling every size from the same
# 1024 master keeps them consistent. macOS needs the transparent corners, or
# the icon shows as a black box behind the artwork in the Dock.
base="$iconset/../base-1024.png"
"$repo/scripts/mask-icon.py" "$source_png" "$base"

for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$base" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -s format png -z "$((size * 2))" "$((size * 2))" "$base" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$repo/Moo/Moo.icns"
sips -s format png -z 512 512 "$base" --out "$repo/docs/moo-icon.png" >/dev/null

echo "wrote Moo/Moo.icns and docs/moo-icon.png"
