#!/usr/bin/env -S uv run --with pillow --quiet python
"""Makes the icon's backdrop transparent.

The artwork is drawn as a rounded square on an opaque black field. macOS wants
an app icon to supply its own silhouette, so an opaque backdrop shows as a
black box behind the icon in the Dock and Finder.

Rather than guessing the corner radius and drawing a squircle over it -- which
would misfit the artwork's own curve -- this flood-fills inward from each
corner. That follows whatever shape the artist actually drew, and it cannot
touch the dark areas inside the icon (the terminal screen) because they are
not connected to the edge.

Fills at full source resolution and downsamples afterwards, so the cut edge
antialiases instead of going jagged.
"""
import sys
from PIL import Image, ImageDraw

TOLERANCE = 60      # how far from the corner colour still counts as backdrop
OUT_SIZE = 1024

source, destination = sys.argv[1], sys.argv[2]
image = Image.open(source).convert("RGBA")
w, h = image.size

# Work on a mask: white = keep, black = cut.
mask = Image.new("L", (w, h), 255)
rgb = image.convert("RGB")

for corner in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
    scratch = rgb.copy()
    ImageDraw.floodfill(scratch, corner, (255, 0, 255), thresh=TOLERANCE)
    filled = scratch.load()
    m = mask.load()
    for y in range(h):
        for x in range(w):
            if filled[x, y] == (255, 0, 255):
                m[x, y] = 0

image.putalpha(mask)
image = image.resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS)
image.save(destination)

corners = [image.getpixel(p)[3] for p in
           [(2, 2), (OUT_SIZE - 3, 2), (2, OUT_SIZE - 3), (OUT_SIZE - 3, OUT_SIZE - 3)]]
centre = image.getpixel((OUT_SIZE // 2, OUT_SIZE // 2))[3]
print(f"corner alpha: {corners}  centre alpha: {centre}")
if any(a > 8 for a in corners):
    sys.exit("corners are still opaque; raise TOLERANCE")
if centre < 250:
    sys.exit("the fill leaked into the artwork; lower TOLERANCE")
