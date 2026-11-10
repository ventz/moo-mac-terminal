#!/usr/bin/env python3
"""Give Moo themes `agentPanel` colors derived from their own palettes.

Usage: agent_panel_colors.py <theme.json>... [--force]

Each theme gets colors for the sidebar's agent panel, picked from its own
palette: working from blue, needs-you from magenta, finished from green,
error from red, idle from bright black (else the secondary text), names in the foreground and
secondary text as the foreground blended toward the sidebar.

Every pick is checked against the sidebar it is drawn on (the theme's
background darkened 35%, as ContentView draws it): status dots need 3:1
(WCAG non-text contrast), text 4.5:1. A color that falls short is swapped
for the palette's bright variant; when neither reads, the normal color is
darkened (on a light sidebar) or lightened (on a dark one) until it does,
so the status keeps its hue. Themes that already have `agentPanel` are left alone unless --force
is given. convert_themes.py calls `derive` for newly converted themes.
"""
import json
import sys
from pathlib import Path

# Moo darkens the sidebar by this much (ContentView.sidebarBackground).
SIDEBAR_DARKENING = 0.35
DOT_CONTRAST = 3.0
TEXT_CONTRAST = 4.5

# Candidates per status, as ANSI indexes: the normal color, then bright.
STATUS_CANDIDATES = {
    "working": [4, 12, 6, 14],
    "blocked": [5, 13, 3, 11],
    "finished": [2, 10, 6, 14],
    "error": [1, 9],
    # Then the secondary text: idle should read as quiet, not bright.
    "idle": [8],
}


def rgb(hex_color: str) -> tuple[float, float, float]:
    value = hex_color.lstrip("#")
    return tuple(int(value[i:i + 2], 16) / 255 for i in (0, 2, 4))


def to_hex(color: tuple[float, float, float]) -> str:
    return "#" + "".join(f"{round(max(0, min(1, c)) * 255):02x}" for c in color)


def luminance(color: tuple[float, float, float]) -> float:
    def linear(c: float) -> float:
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (linear(c) for c in color)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b) -> float:
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def mix(a, b, t: float):
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def sidebar(theme: dict):
    return tuple(c * (1 - SIDEBAR_DARKENING) for c in rgb(theme["background"]))


def adjusted(color, behind):
    """The color moved toward black or white, whichever the sidebar is
    not, just far enough to reach dot contrast; its hue stays."""
    target = (0.0, 0.0, 0.0) if luminance(behind) > 0.18 else (1.0, 1.0, 1.0)
    for step in range(0, 85, 5):
        candidate = mix(color, target, step / 100)
        if contrast(candidate, behind) >= DOT_CONTRAST:
            return candidate
    return mix(color, target, 0.85)


def derive(theme: dict) -> dict:
    """The agentPanel block for a theme."""
    ansi = [rgb(c) for c in theme["ansi"]]
    foreground = rgb(theme["foreground"])
    behind = sidebar(theme)

    text = foreground
    if contrast(text, behind) < TEXT_CONTRAST:
        # A foreground that barely reads on the darkened sidebar: whichever
        # of the palette's extremes reads better.
        text = max([foreground, ansi[15], ansi[0], ansi[7]], key=lambda c: contrast(c, behind))

    # Secondary text: the foreground pulled toward the sidebar, as far as
    # it can go and still read.
    secondary = text
    for step in range(40, -1, -5):
        candidate = mix(text, behind, step / 100)
        if contrast(candidate, behind) >= TEXT_CONTRAST:
            secondary = candidate
            break

    panel = {"text": to_hex(text), "secondaryText": to_hex(secondary)}
    used: set[str] = set()
    for status, indexes in STATUS_CANDIDATES.items():
        options = [ansi[i] for i in indexes]
        if status == "idle":
            options.append(secondary)
        pick = None
        for option in options[:2]:
            if contrast(option, behind) >= DOT_CONTRAST and to_hex(option) not in used:
                pick = option
                break
        if pick is None:
            pick = adjusted(options[0], behind)
        if to_hex(pick) in used:
            pick = adjusted(options[1] if len(options) > 1 else options[0], behind)
        panel[status] = to_hex(pick)
        used.add(panel[status])
    return panel


def main(argv: list[str]) -> int:
    force = "--force" in argv
    paths = [Path(a) for a in argv if a != "--force"]
    if not paths:
        print(__doc__)
        return 1
    changed = 0
    for path in paths:
        theme = json.loads(path.read_text())
        if "agentPanel" in theme and not force:
            continue
        theme["agentPanel"] = derive(theme)
        path.write_text(json.dumps(theme, indent=2) + "\n")
        changed += 1
    print(f"gave {changed} of {len(paths)} themes agent panel colors")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
