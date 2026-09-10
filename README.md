# Moo Terminal

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey.svg)](#quick-install)

A native macOS terminal that keeps your work grouped — terminals, Markdown
previews and web pages side by side in one window, organized into projects.

## Table of Contents

- [Overview](#overview)
- [Quick Install](#quick-install)
- [Features](#features)
- [Usage](#usage)
- [Building from Source](#building-from-source)
- [Acknowledgements](#acknowledgements)
- [Third-Party Components](#third-party-components)
- [License](#license)

## Overview

A terminal window is rarely just terminals. You are reading a README, watching
a dev server's page, and running a build — and those normally live in three
different applications with three different window stacks.

Moo groups terminals into **projects** in a sidebar, and lets a project's tabs
hold Markdown previews and web pages alongside shells. Switching projects
switches the whole working set at once; the shells you left behind keep
running.

## Quick Install

```bash
git clone https://github.com/ventz/moo-mac-terminal
cd moo-mac-terminal
xcodebuild -downloadComponent MetalToolchain   # one time, ~688 MB
open Moo.xcodeproj                             # ⌘R to build and run
```

Requires macOS 15+ and Xcode 26. The Metal Toolchain is not optional — the
terminal renderer compiles a Metal shader, and a stock Xcode fails ~90% of the
way through the build without it.

## Features

- **Projects.** A sidebar groups terminals into named projects, each with its
  own tabs. Selecting a project swaps the window's contents; nothing is torn
  down, so background projects keep running.
- **Live project status.** Each row reports whether it is idle, running a
  command, or has unread output, read from the shell's actual child processes
  rather than guessed from screen activity.
- **Markdown preview tabs.** Open a `.md` file as a rendered, GitHub-styled tab
  next to the shell that produced it.
- **Browser tabs.** Open a URL as a real web tab in the same window — a dev
  server, a doc page, an API console — instead of switching to a browser.
- **Ads blocked, pages sandboxed.** Local files and remote pages are treated as
  untrusted: no arbitrary file access, no automatic launching of what a page
  points at, and ad blocking on by default.
- Plus splits, profiles, themes, AppleScript and App Intents automation, and
  session persistence.

## Usage

Create a project from the sidebar, or `⌘T` for a new tab inside the current
one. The status dot on each project row is live: **Idle** at a prompt,
**Running** with a command in flight, **Activity** when a background project
produced output.

Open a Markdown file or URL as a tab from the File menu, or by
command-clicking a path or link in terminal output.

## Building from Source

Debug build and run:

```bash
xcodebuild build -project Moo.xcodeproj -scheme Moo \
  -configuration Debug -destination "platform=macOS" \
  -skipPackagePluginValidation \
  -derivedDataPath build/DerivedData
open build/DerivedData/Build/Products/Debug/Moo.app
```

`-skipPackagePluginValidation` is required — SwiftTerm ships a build-tool
plugin.

Release build and a distributable DMG:

```bash
xcodebuild build -project Moo.xcodeproj -scheme Moo \
  -configuration Release -destination "generic/platform=macOS" \
  -skipPackagePluginValidation \
  -derivedDataPath build/DerivedDataRelease
scripts/create-dmg.sh build/DerivedDataRelease/Build/Products/Release/Moo.app \
  ~/Desktop/Moo.dmg "Moo"
```

Release builds are universal (`x86_64 arm64`); local Debug builds are
arm64-only.

A DMG signed with a self-signed or ad-hoc identity reports *"Moo.app is
damaged"* on another Mac. That message means unsigned, not corrupt. Clear it
with `xattr -dr com.apple.quarantine /Applications/Moo.app`, or sign with a
Developer ID certificate and notarize.

## Acknowledgements

**Moo Terminal exists because of [Miguel de Icaza](https://github.com/migueldeicaza).**

This project started as a personal customization of his macOS terminal,
[Tecolot](https://github.com/migueldeicaza/Tecolot), built on his terminal
engine, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). Tecolot is the
application underneath — the windows and panes, the profiles and themes, the
automation, the persistence — and SwiftTerm is the emulation itself: parsing,
buffers, rendering, the pty. Nearly every line of this program is his work.

What began as three customizations became this fork:

* **Projects + panes** — a way to manage windows and tabs as one working set
* **Markdown preview** — Markdown as tabs and windows
* **Web browser** — browser tabs and windows, with ad blocking

Both Tecolot and SwiftTerm are MIT licensed, © 2026 Miguel de Icaza. Moo is not
affiliated with or endorsed by him.

**Please report bugs to the right place.** If a problem reproduces in Tecolot
itself, it belongs [upstream](https://github.com/migueldeicaza/Tecolot/issues),
where everyone benefits from the fix. Only fork-specific behavior belongs here.

SwiftTerm in turn builds on the work of the
[xterm.js](https://github.com/xtermjs/xterm.js) authors, SourceLair Private
Company, and Christopher Jeffrey.

## Third-Party Components

| Component | Author | License |
|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Miguel de Icaza | MIT |
| [Sparkle](https://sparkle-project.org) | Sparkle contributors | MIT |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apple | Apache 2.0 |
| [swift-png](https://github.com/tayloraswift/swift-png) | Taylor Swift (tayloraswift) | MPL 2.0 |
| Symbols Nerd Font (Nerd Fonts 3.4.0) | Nerd Fonts contributors | MIT |

Sparkle auto-update is deliberately disabled: this fork publishes no appcast,
and inheriting upstream's feed would install the upstream app over Moo.

## License

[MIT](LICENSE) © Miguel de Icaza (original work) and © Ventz Petkov (fork changes)
