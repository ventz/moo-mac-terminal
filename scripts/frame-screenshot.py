#!/usr/bin/env -S uv run --with pillow --quiet python
"""Frames a Moo window screenshot for the dark landing page.

Usage: frame-screenshot.py [--transparent] <in.png> <out.png> [aspect]

The input is a macOS window capture (Cmd-Shift-4, Space): the window on
transparency with its system shadow. On the site's near-black page that shadow
vanishes and the black window edge melts into the background, so this rebuilds
the frame for a dark page instead:

  - crops to the window, then to `aspect` (width / height, default 1.9) from
    the top, keeping the title bar and tabs and dropping empty rows below;
  - flattens the translucent terminal onto solid black, so the page does not
    show through it;
  - gives the new bottom edge the window's own rounded corners, mirrored from
    the top;
  - lays a light hairline ring around the edge and a soft green glow and drop
    shadow behind it, on a margin in the page's own background color.

--transparent is for the README instead: GitHub shows it on white or on dark,
so there is no background and no glow, only the ring and a neutral shadow.
"""
import sys

from PIL import Image, ImageChops, ImageFilter

PAGE_BG = (12, 18, 16)      # site --bg, so the margin blends into the page
GLOW = (63, 163, 77)        # site --green
FILL = (0, 0, 0)            # the stock theme's background, made opaque
MARGIN = 0.07               # of the window width, each side


def main(src, out, aspect=1.9, transparent=False):
    im = Image.open(src).convert("RGBA")
    # The window body is 85% opaque; its shadow never gets near that.
    win = im.crop(im.getchannel("A").point(lambda v: 255 if v > 204 else 0).getbbox())
    w = win.width
    h = min(win.height, round(w / aspect))
    win = win.crop((0, 0, w, h))

    # Edge mask from the window's own antialiased alpha, stretched so the
    # translucent body reads as fully opaque.
    mask = win.getchannel("A").point(
        lambda v: 0 if v < 120 else 255 if v >= 216 else round((v - 120) * 255 / 96))
    corner = mask.crop((0, 0, w, 64))
    mask.paste(corner.transpose(Image.FLIP_TOP_BOTTOM), (0, h - 64))

    body = Image.new("RGBA", win.size, FILL + (255,))
    body.alpha_composite(win)
    body.putalpha(mask)

    pad = round(w * (0.045 if transparent else MARGIN))
    size = (w + 2 * pad, h + 2 * pad)
    canvas = Image.new("RGBA", size, PAGE_BG + (0 if transparent else 255,))

    def placed(m, dy=0):
        layer = Image.new("L", size, 0)
        layer.paste(m, (pad, pad + dy))
        return layer

    def paint(color, alpha):
        canvas.alpha_composite(Image.merge("RGBA", (*[Image.new("L", size, c) for c in color], alpha)))

    if transparent:
        paint((0, 0, 0), placed(mask.point(lambda v: v * 0.45), dy=round(pad * 0.25))
              .filter(ImageFilter.GaussianBlur(pad * 0.35)))
    else:
        paint(GLOW, placed(mask.point(lambda v: v * 0.30)).filter(ImageFilter.GaussianBlur(pad * 0.45)))
        paint((0, 0, 0), placed(mask.point(lambda v: v * 0.9), dy=round(pad * 0.12))
              .filter(ImageFilter.GaussianBlur(pad * 0.25)))
    canvas.alpha_composite(body, (pad, pad))

    edge = placed(mask)
    outer = edge.filter(ImageFilter.GaussianBlur(2.2)).point(lambda v: min(255, v * 3))
    paint((150, 150, 150), ImageChops.subtract(outer, edge).point(lambda v: v * 0.85))
    inner = edge.filter(ImageFilter.GaussianBlur(1.5)).point(lambda v: max(0, v * 2 - 255))
    paint((255, 255, 255), ImageChops.subtract(edge, inner).point(lambda v: v * 0.18))

    (canvas if transparent else canvas.convert("RGB")).save(out)
    print(f"{out}: {size[0]}x{size[1]}")


if __name__ == "__main__":
    args = sys.argv[1:]
    transparent = "--transparent" in args
    args = [a for a in args if a != "--transparent"]
    if len(args) not in (2, 3):
        sys.exit(__doc__.split("\n\n")[1])
    main(args[0], args[1], *map(float, args[2:]), transparent=transparent)
