# Performance

How fast Moo is, how that was measured, and what has already been tried.
Measured on 2026-09-13 on an M3 MacBook Pro (built-in 120 Hz display) against
Ghostty 1.3.1. Moo builds SwiftTerm from the `perf/moo` branch of
[ventz/SwiftTerm](https://github.com/ventz/SwiftTerm), which carries the
attribute intern cache merged upstream as
[migueldeicaza/SwiftTerm#694](https://github.com/migueldeicaza/SwiftTerm/pull/694).
The fork stays in use because it keeps pointer storage for that cache — see
[SwiftTerm engine work](#swiftterm-engine-work).

## Contents

- [Summary](#summary)
- [Throughput](#throughput)
- [Keystroke latency](#keystroke-latency)
- [Where the latency goes](#where-the-latency-goes)
- [Idle CPU](#idle-cpu)
- [SwiftTerm engine work](#swiftterm-engine-work)
- [Tried and rejected](#tried-and-rejected)
- [How to measure](#how-to-measure)
- [Measurement traps](#measurement-traps)

## Summary

| | Moo | Ghostty 1.3.1 | |
|---|---|---|---|
| 100 MB plain text through a pty | 0.33 s | 1.12 s | Moo 3.4× faster |
| 60 MB 256-color text | 0.31 s | 0.79 s | Moo 2.5× faster |
| 40 MB CJK and emoji | 0.25 s | 0.32 s | Moo 1.3× faster |
| 5,000 full-screen redraws | 0.15 s | 0.74 s | Moo 5.0× faster |
| Keystroke to screen, p50 | 21 ms | 28.6 ms | 7.5 ms sooner |
| Keystroke to screen, p99 | 27 ms | 39 ms | 12 ms sooner |
| Idle CPU, one window, per minute | 0.01–0.02 s | < 0.01 s | Ghostty lower |

These are throughput and latency numbers. They do not measure how many frames
each app shows during a flood.

## Throughput

Each app runs the same script inside its own 80×24, 12 pt window and `cat`s a
file. The clock stops on the reply to a DSR 6 cursor-position request, which a
terminal can only send after it has parsed everything before it, so this times
processing and not just `cat` returning. Five rounds, app order rotated, medians;
every repetition was within ±3%.

| Workload | Moo before the cache | Moo | Ghostty |
|---|---|---|---|
| 100 MB ASCII lines | 0.327 s | 0.331 s | 1.122 s |
| 60 MB 256-color SGR | 0.396 s | **0.313 s** | 0.789 s |
| 40 MB CJK and emoji | 0.255 s | 0.254 s | 0.322 s |
| 5,000 redraw frames | 0.150 s | 0.149 s | 0.740 s |

- **Plain text is at the pty's limit.** A Darwin pty returns about 1 KiB per
  read and tops out near 290 MiB/s; Moo already runs there, so ASCII cannot
  get faster in any terminal.
- **Colored output is where the engine matters.** The intern cache took it
  from 0.396 s to 0.313 s (+26.5%).

## Keystroke latency

A key event is posted and the first displayed frame that shows the change is
timed. Each app runs `cat > /dev/null` after `clear`, so the kernel's tty echo
answers and no shell redraw is involved. 80×24, 12 pt, 200 keystrokes per app
over two rounds with the order alternated, no timeouts.

| | p50 | p90 | p99 | max |
|---|---|---|---|---|
| Moo | **20.7–21.2 ms** | 24.9–25.4 ms | 26.4–27.2 ms | 27.9–30.2 ms |
| Ghostty 1.3.1 | 28.5–28.6 ms | 31.9–32.2 ms | 38.2–39.8 ms | 40.0–42.0 ms |

Deleting the character (the glyph disappearing) matches within 1 ms. The
absolute numbers include the screen-capture pipeline's own delay, so compare
the two apps rather than against figures from other tools.

## Where the latency goes

From SwiftTerm's signposts (`SWIFTTERM_PROFILE=1`), 200 keystrokes in Moo:

| Stage | p50 |
|---|---|
| AppKit key dispatch → echoed bytes arrive from the pty | 1.1 ms |
| Parse | 0.03 ms |
| Bytes → frame tick on the main thread | 0.59 ms |
| Acquire a Metal drawable | 0.08 ms |
| Encode and commit | 0.75 ms |
| **Bytes → Metal commit, total** | **1.3–1.5 ms** |
| Commit → on screen (macOS compositor and display) | ≈ 20 ms |

- SwiftTerm's own work is about 6% of the latency. There is no display-link
  wait to remove: the first frame after idle is drawn immediately.
- macOS's frame-pacing statistics mark about 85% of Moo's frames *late on
  glass* by exactly one 120 Hz refresh (8.33 ms). Turning off vsync on the
  layer does not change that — the window compositor still paces it.
- Ghostty cannot be compared on that statistic. It renders into an IOSurface
  and sets it as a layer's contents in a Core Animation transaction, so macOS
  reports no frame pacing for it; its end-to-end number is the slower one.

## Idle CPU

One window at a prompt, CPU time over 60 seconds:

| | CPU per minute |
|---|---|
| Moo, before process-poll gating | 0.08–0.17 s |
| Moo, now | 0.01–0.02 s |
| Ghostty | < 0.01 s |

Each pane used to ask the system for its foreground process every half second
even when idle. It now does so only for about two seconds after output or a
keystroke; a foreground program cannot start or exit without one of those.

## SwiftTerm engine work

Headless A/B with `SwiftTermProfile` (200 iterations, 5 alternating pairs),
against SwiftTerm `a7b8b94`.

**Attribute intern cache (kept, PR #694).** `CellArena.intern(attribute:)`
hashed a two-word key through `Dictionary` for nearly every style change, about
11% of the parse thread on `dense_cells`. A 1,024-slot direct-mapped cache in
front of it:

| Workload | Change |
|---|---|
| `dense_cells` | **+22.8%** |
| `medium_cells` (captured vim session) | **+9.9%** |
| `sync_medium_cells` | **+9.2%** |
| `scrolling_fullscreen` | +2.8% |
| `unicode` | +2.3% |
| `cursor_motion`, `light_cells` | unchanged |

The table is append-only — nothing removes an entry — so a cache hit can never
be stale.

**Upstream merged it, reworked (2026-09-14/15).** Miguel took the cache but
replaced `UnsafeMutablePointer` storage with an `@exclusivity(unchecked)` Array
(`b844c8a`, to avoid unsafe code), which cost ~2% on `unicode`; `233c6ba` won
that back by moving the cache fields after the grapheme fields and returning
early for the all-zero default-attribute key. `perf/moo` (`1fd6fa4`) merges his
work but keeps **our pointer storage** — re-measured over 6 workloads x 9 rounds
at 400 iterations with rotating build order, medians in MiB/s:

| Comparison | Result |
|---|---|
| pointer vs Array on `dense_cells` | **+3.0%**, faster in 9/9 rounds |
| every other workload | within noise |
| upstream `main` vs `perf/moo` | tied except `dense_cells` (−2.1%) |

That storage line in `Sources/SwiftTerm/CellStorage.swift` is now the fork's
only delta from upstream. Keep it across merges; re-A/B before dropping it.

**Which workloads the engine limits.** `light_cells` (≈3,400 MiB/s) and
`scrolling_fullscreen` (≈780 MiB/s) are limited by the pty in a real terminal.
`medium_cells` (≈150), `cursor_motion` (≈159), `dense_cells` (≈270) and
`unicode` (≈262) are engine-bound; only those can get faster in Moo.

## Tried and rejected

Every item below was measured with the same A/B and reverted. Profile hotspots
repeatedly overstated what removing them would save — A/B a change before
believing a hotspot.

| Change | Profile's share | Measured |
|---|---|---|
| Walk the parse loop by index instead of `extracting(droppingFirst:)` | 5–9% | −3% to −6% on every engine-bound workload |
| Same, with `data[unchecked:]` | — | still −3% to −6% |
| Pass captured locals `inout` into `cmdCharAttributes` helpers | ~5% | ±0.3% |
| Read the VT500 transition table through a raw pointer | 7–8% | +1.6–2.1% on four workloads, −1.9% on `dense_cells` |
| Raw load/store in `CsiParameterStorage.accumulateDigit` | 8.5% | ±0.6% |
| `CAMetalLayer.displaySyncEnabled = false` (latency) | — | p50 21.2 vs 21.3 ms, same late-frame count |
| Low-water mark on `BufferLine`'s written span | — | +14% on `scrolling`, 0.05% of cells on real vim traffic, ~1% cost elsewhere |

## How to measure

- **Headless engine A/B**: build `SwiftTermProfile` in
  `Tools/SwiftTermBenchmarks` of two SwiftTerm checkouts and alternate runs
  (`SwiftTermProfile <workload> --iterations 200 --warmup 4`). Flip the order
  each pair and keep every repetition; run-to-run spread is 2–10%.
- **Profile**: `xcrun xctrace record --template 'Time Profiler' --launch --
  SwiftTermProfile medium_cells --iterations 1200`, export the `time-profile`
  table, and read it with `Tools/SwiftTermBenchmarks/analyze-time-profile.py
  --root EscapeSequenceParser.parse --callers-of <symbol>`.
- **End-to-end throughput**: a script run inside each terminal times `cat` of a
  file and stops on a DSR 6 reply.
- **Keystroke latency**: a small tool posts CGEvents and streams only the glyph
  rectangle with ScreenCaptureKit, timing each frame's `displayTime`. It needs
  Screen Recording and Accessibility.
- **Latency stages**: launch Moo with `SWIFTTERM_PROFILE=1`, attach
  `xcrun xctrace record --template Logging --instrument os_signpost --attach
  <pid>`, and export the `os-signpost-interval` table.
- **Moo against a modified SwiftTerm** without touching this repo: resolve
  packages into a scratch DerivedData, `chmod -R u+w` its SwiftTerm checkout,
  copy the changed sources in, and build with `-disableAutomaticPackageResolution`.

## Measurement traps

- **`SwiftTermProfile` bypasses the pty**, so `\n` stays a bare line feed and
  the `scrolling*` workloads park the cursor at the right margin. Their gains
  do not transfer to real traffic; confirm on `medium_cells`.
- **`analyze-time-profile.py --root` defaults to `Terminal.feed`**, which is
  inlined away and prints `samples 0`. Use `--root ''` or
  `--root EscapeSequenceParser.parse`.
- **A rebuild of one tree reads +2.6–3.0% on `unicode` against a binary from
  another tree**, even for unrelated changes. Compare two builds from the same
  tree before believing a lone `unicode` gain.
- **GUI benchmarks need the display awake and nobody typing.** With the screen
  off no window draws; stray keystrokes land in the test window.
- **`open -g` starts Moo without a window**, so no shell runs and the workload
  never starts.
- **An ad-hoc signed build with hardened runtime aborts at launch**: library
  validation rejects Sparkle. Re-sign scratch builds without `-o runtime`.
- **A tool that needs Screen Recording must be a real app bundle** outside
  `/tmp`, signed with a Developer ID; an ad-hoc app in a temp folder cannot be
  added in Privacy & Security.
- **`SCContentFilter(display:including: [])` captures nothing.** Use
  `excludingWindows: []`.
- **xctrace in Xcode 17 has no `Blank` template**; use `Logging` for signposts.
- **SwiftTerm's `Tools/run-pty-benchmark.py` needs its window unoccluded**, or
  it prints `window_not_visible` and records nothing.
- **Ghostty ignores `HOME` passed through `open`**; pass its settings as
  `--key=value` arguments.
- **SwiftTerm's test suite already fails Kitty shared-memory tests**
  (`testKittySharedMemoryLoad`, `testSharedMemoryLoadUnlinksSource`) in this
  environment; a change is clean if it fails only those.
