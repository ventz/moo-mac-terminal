# Moo

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey.svg)](#quick-install)

A native macOS terminal that keeps your work grouped — terminals, Markdown
previews and web pages side by side in one window, organized into projects.

**Moo is a fork of [Tecolot](https://github.com/migueldeicaza/Tecolot) by
[Miguel de Icaza](https://github.com/migueldeicaza)**, built on his
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) engine. Nearly all of
this program is his work. See [Credits](CREDITS.md).

## Table of Contents

- [Overview](#overview)
- [Quick Install](#quick-install)
- [Features](#features)
- [Usage](#usage)
- [Building from Source](#building-from-source)
- [Relationship to Tecolot](#relationship-to-tecolot)
- [Credits](#credits)
- [License](#license)

## Overview

Tecolot is an excellent native terminal. Moo adds one idea to it: a terminal
window is rarely just terminals. You are reading a README, watching a dev
server's page, and running a build — and today those live in three different
applications with three different window stacks.

Moo groups terminals into **projects** in a sidebar, and lets a project's tabs
hold Markdown previews and web pages alongside shells. Switching projects
switches the whole working set at once; the shells you left behind keep
running.

It is a personal fork. It is not affiliated with or endorsed by Miguel de
Icaza, and it publishes no auto-update feed.

## Quick Install

```bash
git clone https://github.com/ventz/moo
cd moo
xcodebuild -downloadComponent MetalToolchain   # one time, ~688 MB
open Moo.xcodeproj                             # ⌘R to build and run
```

Requires macOS 15+ and Xcode 26. The Metal Toolchain is not optional —
SwiftTerm's renderer compiles a Metal shader, and a stock Xcode fails ~90% of
the way through the build without it. See
[Building from Source](#building-from-source) for command-line builds and
release packaging.

## Features

Everything Tecolot does — splits, profiles, themes, AppleScript and App
Intents automation, session persistence — plus:

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
- **Hardened previews and browser tabs.** Local files and remote pages are
  treated as untrusted: no arbitrary file access, no automatic launching of
  what a page points at, and ads blocked by default.

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

A DMG signed with a self-signed or ad-hoc identity will report *"Moo.app is
damaged"* on another Mac. That message means unsigned, not corrupt. Clear it
with `xattr -dr com.apple.quarantine /Applications/Moo.app`, or sign with a
Developer ID certificate and notarize.

## Relationship to Tecolot

Moo forked from Tecolot at `v0.0.22`. The fork exists to carry changes that are
personal preference rather than obviously-right-for-everyone, and it tracks
upstream rather than diverging from it.

**Please report bugs to the right place.** If a problem reproduces in Tecolot
itself, it belongs [upstream](https://github.com/migueldeicaza/Tecolot/issues),
where everyone benefits from the fix. Only fork-specific behavior belongs here.

Sparkle auto-update is deliberately disabled: the fork publishes no appcast,
and inheriting upstream's feed would have Sparkle install Tecolot over Moo.

## Credits

Moo would not exist without Miguel de Icaza. Tecolot is the application and
SwiftTerm is the engine — both his, both MIT licensed. The full attribution
list, including Sparkle, swift-argument-parser, swift-png and Nerd Fonts, is
in [CREDITS.md](CREDITS.md).

## License

[MIT](LICENSE) © Miguel de Icaza (Tecolot, SwiftTerm) and © Ventz Petkov (fork changes)
