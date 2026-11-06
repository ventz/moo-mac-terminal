# Keyboard Shortcuts

Every shortcut Moo defines, grouped by the part of the app it drives. The
same list is in **Settings → Keyboard → Shortcuts**. Shortcuts are app-wide:
they are the same in every profile. To add your own, use
[Key Mappings](SETTINGS.md#key-mappings).

Two pairs are easy to mix up:

- **⇧⌘[ / ⇧⌘]** always switch tabs.
- **⌘[ / ⌘]** go back and forward in Markdown previews and browser tabs, and
  move between splits in a terminal tab.

## Contents

- [Windows & Projects](#windows--projects)
- [Tabs](#tabs)
- [Splits](#splits)
- [Terminal](#terminal)
- [Command Palette](#command-palette)
- [Markdown Previews](#markdown-previews)
- [Browser Tabs](#browser-tabs)
- [Mouse](#mouse)

## Windows & Projects

| Keys | Action |
|---|---|
| ⌘N | New window, or a new project while the sidebar is open |
| ⌥⌘N | New window |
| ⇧⌘P | New project |
| ⌘B | Show or hide the projects sidebar |
| ⌘1–⌘8 / ⌘9 | Select a project or tab (Settings → General), ⌘9 the last |
| ⇧⌘U | Jump to the latest unread notification |
| ⌘, | Settings |

## Tabs

| Keys | Action |
|---|---|
| ⌘T | New tab |
| ⇧⌘[ / ⇧⌘] | Previous / next tab |
| ⌘W | Close the pane or tab |

## Splits

| Keys | Action |
|---|---|
| ⌘D | Split side by side |
| ⇧⌘D | Split stacked |
| ⌘[ / ⌘] | Previous / next split |
| ⌥⌘↑ / ⌥⌘↓ / ⌥⌘← / ⌥⌘→ | Select the split in that direction |
| ⌃⌘↑ / ⌃⌘↓ / ⌃⌘← / ⌃⌘→ | Move the divider |
| ⌃⌘= | Equalize splits |
| ⇧⌘↩ | Zoom or unzoom the pane |

## Terminal

| Keys | Action |
|---|---|
| ⌘K | Command palette |
| ⌘J | Jump to a directory, ranked like z |
| ⇧⌘K | Clear to start (screen and scrollback) |
| ⌥⌘K | Clear scrollback |
| ⌘↑ / ⌘↓ | Scroll to the previous / next prompt |
| ⌘F | Find |
| ⌘G / ⇧⌘G | Find next / previous |
| ⌘+ / ⌘- / ⌘0 | Bigger / smaller / default font size |
| ⌃⌘V | Paste escaped |
| ⌃⌘T | Change theme |
| ⌘P | Print |

## Command Palette

| Keys | Action |
|---|---|
| ↑ / ↓ | Move the selection |
| ↩ | Run the command, go to the tab or directory, or copy the match |
| ⌘↩ | Open the matched link or path |
| ⌥↩ | Type cd to the directory into this pane, at a shell prompt |
| z Space | Show only directories |
| t Space | Show only tabs and workspaces |
| ⎋ | Close |

⌘K opens on a list of your tabs, like zsh's ⌃R: every tab in every window except the one you are in, the one you left most recently at the top, so ⌘K ↩ goes back to it. Typing filters the tabs without reordering them. Typing in ⌘K searches every tab, split and workspace by title, workspace name, directory and running program, then menu commands, then directories (ranked like z), then what is on screen. Choosing a tab lands on the split that matched. ⌥↩ types the `cd` line but does not run it: check it and press Return. When the pane is not at a shell prompt, or the path has characters other than letters, digits, spaces and `/._-+,@~=:`, ⌥↩ beeps and does what ↩ does. ↩ switches to that workspace and tab; workspaces not yet reopened since launch are listed too. ⌘J while the palette is open switches it to directories; pressing it again closes it. Settings: [Command Palette](SETTINGS.md#command-palette-every-profile).

## Markdown Previews

| Keys | Action |
|---|---|
| ⇧⌘M | Open a Markdown file in a preview |
| ⌘[ / ⌘] | Back / forward through followed links |
| ⌘R | Reload |
| ⌘-click | Open a Markdown link in the same tab instead of a new one, or the reverse when new tabs are off (Settings → Links & Markdown) |

## Browser Tabs

| Keys | Action |
|---|---|
| ⇧⌘B | New browser tab |
| ⌘L | Open location |
| ⌘[ / ⌘] | Back / forward |
| ⌘R | Reload |
| ⌘F | Find in page |
| ⌘G / ⇧⌘G | Find next / previous |
| ⌘+ / ⌘- / ⌘0 | Zoom in / out / actual size |

## Mouse

| Keys | Action |
|---|---|
| ⌘-click | Open a link, path or Markdown file from terminal output |
| ⌥⌘-click | Open it with the default app instead |
| Right-click / ⌃-click | Pane menu (⌃-click goes to programs that track the mouse) |
