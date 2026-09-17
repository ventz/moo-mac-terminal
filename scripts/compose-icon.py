#!/usr/bin/env -S uv run --with pillow --with numpy --quiet python
"""Composes the app icon: the cow on a green rounded tile.

The artwork is the cow alone, on transparency. This lays it on Apple's macOS
icon grid -- an 824 px rounded tile inside a 1024 px canvas, with a soft shadow
below -- so Moo sits at the same size as other apps in the Dock.

The artwork's alpha is hard-edged, with no partial pixels, so it is softened
before compositing. Its transparent pixels are near-white, and softening would
blend that white into the edge -- a pale hairline around the cow on the tile.
So the cow's own colors are bled into those pixels first.

Green is for contrast: the purple cow reads at a glance against it, in the Dock
and at 16 px, where a white tile disappeared on light backgrounds.
"""
import sys

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

CANVAS = 1024
TILE = 824          # Apple's macOS icon grid
RADIUS = 185        # tile corner radius
# Centered on #3C9F4B (grass green, dark enough to set off the purple cow),
# lighter at the top, as macOS icons are lit. Lifted from #2F8E3E, which read
# too dark against a light Dock.
# Earlier tiles, to go back to:
#   yellow-green #B2C248: TILE_TOP = (196, 212, 94) #C4D45E, TILE_BOTTOM = (160, 176, 50) #A0B032
#   first green:          TILE_TOP = (72, 214, 110) #48D66E, TILE_BOTTOM = (38, 170, 78) #26AA4E
#   bright green #00DA4D: TILE_TOP = (0, 236, 104) #00EC68, TILE_BOTTOM = (0, 200, 50) #00C832
#   dark green #2F8E3E:   TILE_TOP = (63, 163, 77) #3FA34D, TILE_BOTTOM = (30, 122, 47) #1E7A2F
TILE_TOP = (77, 179, 91)      # #4DB35B
TILE_BOTTOM = (42, 138, 59)   # #2A8A3B
COW_FILL = 0.96     # the cow's width as a share of the tile's: ears near the edges
SHADOW_OFFSET = 12  # px down
SHADOW_BLUR = 22
SHADOW_OPACITY = 70  # of 255
EDGE_SOFTEN = 1.0   # px at artwork resolution
BLEED = 4.0         # px: how far the cow's colors reach into transparency
SUPERSAMPLE = 4     # for a smooth tile edge

source, destination = sys.argv[1], sys.argv[2]

art = Image.open(source).convert("RGBA")
hard_alpha = art.getchannel("A")

# Bleed: each transparent pixel takes the alpha-weighted average color of the
# cow near it. Opaque pixels keep their exact color.
rgb = np.asarray(art.convert("RGB"), dtype=np.float32)
a = np.asarray(hard_alpha, dtype=np.float32)[..., None] / 255.0
premultiplied = Image.fromarray(np.clip(rgb * a, 0, 255).round().astype(np.uint8))
spread_color = np.asarray(premultiplied.filter(ImageFilter.GaussianBlur(BLEED)), dtype=np.float32)
spread_alpha = np.asarray(hard_alpha.filter(ImageFilter.GaussianBlur(BLEED)), dtype=np.float32)[..., None] / 255.0
bled = np.where(spread_alpha > 1e-3, spread_color / np.maximum(spread_alpha, 1e-3), rgb)
rgb = np.where(a >= 1.0, rgb, np.clip(bled, 0, 255))

art = Image.fromarray(rgb.round().astype(np.uint8)).convert("RGBA")
alpha = hard_alpha.filter(ImageFilter.GaussianBlur(EDGE_SOFTEN))
art.putalpha(alpha)
cow = art.crop(alpha.point(lambda v: 255 if v > 8 else 0).getbbox())

offset = (CANVAS - TILE) // 2
big = Image.new("L", (CANVAS * SUPERSAMPLE,) * 2, 0)
ImageDraw.Draw(big).rounded_rectangle(
    [offset * SUPERSAMPLE, offset * SUPERSAMPLE,
     (offset + TILE) * SUPERSAMPLE - 1, (offset + TILE) * SUPERSAMPLE - 1],
    radius=RADIUS * SUPERSAMPLE, fill=255)
tile_mask = big.resize((CANVAS, CANVAS), Image.LANCZOS)

icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

shadow_alpha = (ImageChops.offset(tile_mask, 0, SHADOW_OFFSET)
                .filter(ImageFilter.GaussianBlur(SHADOW_BLUR))
                .point(lambda v: v * SHADOW_OPACITY // 255))
shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 255))
shadow.putalpha(shadow_alpha)
icon.alpha_composite(shadow)

gradient = Image.linear_gradient("L").resize((CANVAS, CANVAS))
tile = Image.composite(Image.new("RGB", (CANVAS, CANVAS), TILE_BOTTOM),
                       Image.new("RGB", (CANVAS, CANVAS), TILE_TOP), gradient).convert("RGBA")
tile.putalpha(tile_mask)
icon.alpha_composite(tile)

width = round(TILE * COW_FILL)
height = round(cow.height * width / cow.width)
cow = cow.resize((width, height), Image.LANCZOS)
layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
layer.alpha_composite(cow, ((CANVAS - width) // 2, (CANVAS - height) // 2))
# Clip to the tile, so a cow scaled close to the edge never pokes past it.
layer.putalpha(ImageChops.multiply(layer.getchannel("A"), tile_mask))
icon.alpha_composite(layer)
icon.save(destination)

corner = icon.getpixel((2, 2))[3]
center = icon.getpixel((CANVAS // 2, CANVAS // 2))[3]
print(f"cow {width}x{height} on a {TILE} px tile; corner alpha {corner}, center alpha {center}")
if corner != 0 or center != 255:
    sys.exit("unexpected alpha: corners must be clear and the tile opaque")
