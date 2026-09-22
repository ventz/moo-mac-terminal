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
  - redraws the window edge as a clean rounded rectangle, so the new bottom
    edge gets the same corners as the top;
  - lays a light hairline ring around the edge and a soft green glow and drop
    shadow behind it, on a margin in the page's own background color.

--transparent is for the README instead: GitHub shows it on white or on dark,
so there is no background and no glow, only the ring and a neutral shadow.
"""
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

PAGE_BG = (12, 18, 16)      # site --bg, so the margin blends into the page
GLOW = (63, 163, 77)        # site --green
FILL = (0, 0, 0)            # the stock theme's background, made opaque
MARGIN = 0.07               # of the window width, each side
RADIUS = 32                 # macOS window corner in a Retina capture, px
SS = 4                      # supersampling for the drawn edge


def main(src, out, aspect=1.9, transparent=False):
    im = Image.open(src).convert("RGBA")
    # The window body is 85% opaque; its shadow never gets near that.
    win = im.crop(im.getchannel("A").point(lambda v: 255 if v > 204 else 0).getbbox())
    w = win.width
    h = min(win.height, round(w / aspect))
    win = win.crop((0, 0, w, h))

    pad = round(w * (0.045 if transparent else MARGIN))
    size = (w + 2 * pad, h + 2 * pad)
    canvas = Image.new("RGBA", size, PAGE_BG + (0 if transparent else 255,))

    # The edge is drawn, not taken from the capture: the capture's alpha is
    # soft and uneven, and rings derived from it smudged at the corners.
    def shape(grow):
        big = Image.new("L", (size[0] * SS, size[1] * SS), 0)
        box = [round((pad - grow) * SS), round((pad - grow) * SS),
               round((pad + w + grow) * SS) - 1, round((pad + h + grow) * SS) - 1]
        ImageDraw.Draw(big).rounded_rectangle(box, radius=round((RADIUS + grow) * SS), fill=255)
        return big.resize(size, Image.LANCZOS)

    edge = shape(0)

    def paint(color, alpha):
        canvas.alpha_composite(Image.merge("RGBA", (*[Image.new("L", size, c) for c in color], alpha)))

    def shadow(opacity, dy, blur):
        m = Image.new("L", size, 0)
        m.paste(edge.crop((pad, pad, pad + w, pad + h)).point(lambda v: v * opacity), (pad, pad + dy))
        return m.filter(ImageFilter.GaussianBlur(blur))

    if transparent:
        paint((0, 0, 0), shadow(0.45, round(pad * 0.25), pad * 0.35))
    else:
        paint(GLOW, shadow(0.30, 0, pad * 0.45))
        paint((0, 0, 0), shadow(0.9, round(pad * 0.12), pad * 0.25))

    body = Image.new("RGBA", size, FILL + (255,))
    body.alpha_composite(win, (pad, pad))
    body.putalpha(edge)
    canvas.alpha_composite(body)

    # Outer ring: light to lift the edge off the dark page; on GitHub a faint
    # dark line, which a white page needs. Inner hairline for dark themes.
    outer = ImageChops.subtract(shape(1.5), edge)
    if transparent:
        paint((0, 0, 0), outer.point(lambda v: v * 0.30))
    else:
        paint((150, 150, 150), outer.point(lambda v: v * 0.85))
    paint((255, 255, 255), ImageChops.subtract(edge, shape(-1.5)).point(lambda v: v * 0.20))

    (canvas if transparent else canvas.convert("RGB")).save(out)
    print(f"{out}: {size[0]}x{size[1]}")


if __name__ == "__main__":
    args = sys.argv[1:]
    transparent = "--transparent" in args
    args = [a for a in args if a != "--transparent"]
    if len(args) not in (2, 3):
        sys.exit(__doc__.split("\n\n")[1])
    main(args[0], args[1], *map(float, args[2:]), transparent=transparent)
