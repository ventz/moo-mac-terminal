# Moo Settings Reference

Every option in **Moo → Settings** (⌘,): what it does, the choices it offers,
and what it is set to out of the box.

## Table of Contents

- [How Settings Is Organized](#how-settings-is-organized)
- **Moo** (app-wide)
  - [General](#general)
  - [Links & Markdown](#links--markdown)
  - [Projects](#projects)
  - [Notifications](#notifications)
- **Profiles** (per profile)
  - [Profiles](#profiles)
  - [Appearance](#appearance)
  - [Window](#window)
  - [Shell](#shell)
  - [Keyboard](#keyboard)
  - [Advanced](#advanced)
- [Updates](#updates)
- [Data](#data)
- [Sharing Settings Between Macs](#sharing-settings-between-macs)

## How Settings Is Organized

The sidebar has three groups, split by **what a setting applies to**:

| Group | Applies to | Pages |
|---|---|---|
| **Moo** | The whole app, every window and profile | General, Links & Markdown, Projects, Notifications |
| **Profiles** | One profile: the one named in the toolbar's **Profile:** menu | Profiles, Appearance, Window, Shell, Keyboard, Advanced |
| *(unlabeled)* | Moo itself | Updates, Data |

On a profile page, the toolbar shows **Profile: *name***. Changes apply to
that profile only, and to every open terminal using it, immediately. Pick
another profile from the same menu to edit it instead.

**Search.** The field at the top of the sidebar searches every setting by
its label and by related words. *transparency* finds Background opacity, and
*vim* finds key repeat. Results are grouped by page, each showing the section
it sits in. Clicking one opens the page, scrolls to the setting and outlines
it for a moment.

**Help.** The round **?** button in the toolbar opens this document at the
section for the page you are on.

**Defaults** in this document are the values a fresh install starts with.
For profile pages, they are the values of the built-in **Default** profile
and of any new profile.

---

## General

App-wide behavior: what happens at launch, how new tabs start, and a few
keyboard and window options that cannot differ per profile.

### Startup

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Open:** | A window with the default profile · A window with this profile · A window group | A window with the default profile | What Moo opens when it launches. |
| **Profile:** | Any profile | *(none)* | Shown when **Open:** is *A window with this profile*: the profile to launch with. |
| **Window group:** | None · any saved window group | None | Shown when **Open:** is *A window group*: the saved arrangement to reopen (Window → Window Groups). |
| **Reopen workspaces, tabs, and splits on launch** | On · Off | **On** | Brings back the layout you quit with: which workspaces, tabs and splits were open, and each pane's directory. Shells start fresh; scrollback, running commands and environment are never saved. |
| **Restore rows of text when a saved session opens** | 0 – 100,000, in steps of 100 | **1,000** | How much terminal text a saved `.moo` session file brings back when you open it. 0 restores none. |

> **Example:** with *Reopen workspaces…* on, quit Moo with two projects open,
> one holding a 2-pane split. On the next launch both projects come back,
> split and all, each shell starting in the directory it was in.

### New tabs and windows

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Default profile:** | Any profile | Default | The profile new windows use, and the fallback wherever no profile is chosen. |
| **Open new tabs in the current tab's directory** | On · Off | **On** | A new tab (⌘T) starts where the current one is. Off: it starts where a new window would. |
| **Open new tabs with the current window's profile** | On · Off | **On** | A new tab takes its window's profile. Off: it uses the default profile. |

### Keyboard (every profile)

| Setting | Options | Default | What it does |
|---|---|---|---|
| **⌘1–9 selects:** | Projects · Tabs · Nothing | **Projects** | What ⌘1 through ⌘8 jump to; ⌘9 always picks the last one. *Projects* follows the sidebar order, so dragging a project changes its number. *Nothing* turns the shortcuts off and removes their menu. |
| **Repeat keys when held** | On · Off | **On** | Holding a letter repeats it, as terminals expect: `j` held in vim scrolls. Off brings back macOS's accent picker (hold `e` for é), but letters stop repeating. Affects Moo only, never other apps. |

### Window (every profile)

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Keep the tab strip opaque in every profile** | On · Off | **On** | The strip of tabs under the title bar stays solid even when a profile's terminal is translucent, so tab names stay readable. Off: each profile decides (Appearance → *Keep the tab strip opaque*). |
| **Draw with Metal** | On · Off | **On** | Renders terminals on the GPU. Turn it off only to diagnose a drawing problem. |

---

## Links & Markdown

What ⌘-click does with links and files in the terminal, how Markdown previews
look and behave, and browser tabs.

### From the terminal

| Setting | Options | Default | What it does |
|---|---|---|---|
| **⌘-click opens links and Markdown files in Moo tabs** | On · Off | **On** | ⌘-click a web address or a `.md` file in the terminal and it opens as a tab beside it. Off: it opens in your default browser or editor. ⌥⌘-click always uses the default app. |

> **Example:** `ls` prints `README.md`. Hold ⌘, click it, and a rendered
> preview opens as a tab next to the terminal, reloading as the file changes.

### Markdown previews

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Follow the terminal theme** | On · Off | Off | Off: previews are always light, with dark text. On: a dark terminal theme gives a dark preview. |
| **Open links to other Markdown files in new tabs** | On · Off | **On** | On: a link in a preview opens that file in a new tab, and ⌘-click keeps it in the same tab. Off: it opens in the same tab, and ⌘-click opens a new tab. Back and Forward (⌘[ / ⌘], or the ‹ › buttons) work either way: within the tab's history, or back to the preview the link was clicked in. |

### Browser tabs

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Block ads and trackers** | On · Off | **On** | Filters browser tabs with EasyList and AdGuard's base and tracking-protection lists, through WebKit's content blocker. Open tabs pick up a change on their next page load. |

---

## Projects

The projects sidebar (⌘B) and the projects in it.

### Row Contents

What each project row shows under its name. The name itself is always shown.

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Status** | On · Off | **On** | Whether the project is running, waiting for you, or idle. |
| **Git branch** | On · Off | **On** | The branch of the project's directory, when it is a git repository. |
| **Directory path** | On · Off | **On** | The project's directory, shortened with `~`. |
| **Accent color** | On · Off | **On** | The project's color stripe. |

### Sidebar

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Draw a divider between the sidebar and the terminal** | On · Off | **On** | A one-pixel line where the sidebar meets the terminal. Off gives a seamless window, set apart only by the sidebar's shading. |

### Projects

The list of projects. Select one to edit it; **Remove** deletes the selected
project (not its files). New projects: ⇧⌘P, or ⌘N while the sidebar is open.

| Setting | Options | Default | What it does |
|---|---|---|---|
| Name | Text | The directory's name | The name shown in the sidebar. |
| **Accent** | Any color | None | The project's color stripe. |
| Status · Git branch · Directory path · Accent color | Default · Show · Hide | Default | Overrides the matching Row Contents setting for this project alone. *Default* follows the app-wide choice. |

---

## Notifications

Programs such as Claude Code can tell Moo they are waiting for you (through
OSC 9, OSC 777 or OSC 99). Moo always lists these in **Window → Notifications**
(⇧⌘U); this page decides what else happens when one arrives. Nothing fires for
the pane you are already looking at.

### Visual

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Show system banners** | On · Off | **On** | A macOS notification banner. Needs permission in System Settings → Notifications; the page offers a button to open it when permission is off. |
| **Show in menu bar** | On · Off | **On** | The bell in the menu bar, listing everything waiting. |
| **Show unread count on the Dock icon** | On · Off | **On** | A badge with the number waiting. |
| **Bounce the Dock icon** | Off · Once · Until Moo is active | **Once** | Draws your eye to the Dock. |
| **Mark waiting tabs and projects** | On · Off | **On** | A dot on the tab, and a *waiting* status on the project row. |

### Commands

These need Moo's shell integration (zsh, bash, fish or elvish), which reports
when each command starts and how it exits.

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Notify when a long command finishes out of sight** | On · Off | **On** | A command that ran long, in a tab you are not looking at, counts as waiting for you, so the alerts above apply. |
| **Long means at least … seconds** | 5 – 3,600, in steps of 5 | **10** | The threshold for "long". |
| **Mark tabs whose last command failed** | On · Off | **On** | Marks a tab whose last command exited with an error. Ctrl-C (130) and a closed pipe (141) do not count. |

> **Example:** start `make test` in one tab, switch to another. If it runs
> longer than 10 seconds, its tab gets a dot when it finishes, the Dock icon
> bounces once, and a banner says so.

### Audio

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Sound** | None · any macOS alert sound | **Glass** | Played by Moo itself, so it works even with banners off. |
| **Volume** | 0 – 100% | **100%** | The speaker button next to it plays the sound. |
| **Speak the message aloud** | On · Off | Off | Reads the notification out with the system voice. |
| **Play** | Always · Only when Moo is in the background | **Always** | When the sound and speech happen. |

### herdr

[herdr](https://herdr.dev) runs coding agents (Claude Code, Codex and others)
in terminals that keep running when you detach. When **Show herdr agents** is
on and herdr runs in a Moo tab, Moo reads that herdr session's agents from
herdr's local socket and lists them under the tab's project in the sidebar.
Clicking one brings up the tab and focuses the agent's pane in herdr.

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Show herdr agents** | On · Off | Off | Lists herdr's agents in the sidebar ("claude · api · needs you"). Once on, the line under it says where herdr is installed and how many agents Moo sees, or how to install it. Never taken from a shared profile. |
| **Alert when a herdr agent needs you** | On · Off | **On** | An agent that herdr reports as blocked (an approval prompt, a question) posts an entry, so the alerts above apply. The entry is marked read once the agent moves on. |
| **Alert when a herdr agent finishes** | On · Off | Off | An agent going from working to idle posts an entry. Off by default because it happens on every turn. |

- **Install.** Once the setting is on, Moo looks for herdr (it does not run
  anything while the setting is off). When herdr is missing, the page shows
  `brew install herdr` with **Copy** and **Install in New Tab**, which opens a
  tab with the command typed but not run; you press Return. Moo never
  installs anything itself.
- **Detected by herdr.** herdr works out an agent's status from its screen.
  Its entries say "detected by herdr", so they are never mistaken for a
  program asking for you itself.
- **Read-only.** Moo only reads herdr's socket and asks it to focus a pane. It
  never types into herdr. It connects only to a socket owned by you that no
  other user can write to, in folders no other user can change.
- **Detached sessions.** If you detach herdr (`ctrl+b q`) while its agents keep
  running, their rows stay until Moo quits, marked *detached*, and no longer
  alert. Clicking one opens a new tab
  that reattaches (not for a herdr started with `HERDR_SOCKET_PATH`, which a
  new shell would not find).
- **Quiet by design.** A pane alerts at most once every 30 seconds, and a
  herdr session at most 10 times a minute.
- **Not shown:** herdr sessions never attached in a Moo tab, and agents on
  other machines (`herdr --remote`).
- **herdr's own alerts** are separate from these: they need
  `[ui.toast] delivery = "terminal"` in herdr's config, which Moo does not
  edit.

> **Example:** run `herdr` in a Moo tab and start Claude Code in a herdr pane.
> The project row gets a "claude · 1 · working" line. When Claude asks to run
> a command, the line reads "needs you", the Dock icon bounces, and the bell
> lists "herdr: claude needs you".

**Send Test Notification** fires every alert that is turned on, without adding
an entry to the list.

---

## Profiles

A profile is a complete terminal setup: font, colors, window size, shell,
keys. Every terminal uses one. The **Default** profile ships with Moo.

| Action | What it does |
|---|---|
| **+** | Creates a profile with the defaults below. |
| Duplicate | Copies the selected profile. |
| Rename… | Renames it. You can also rename it in place in the list, as in the Finder. |
| Set as Default | Makes it the profile new windows use. |
| New from Preset | Pro · Homebrew · Man Page · Solarized Light, ready-made looks to start from. |
| Import… · Export… | Reads or writes a `.mooprofile` file. See [Sharing Settings Between Macs](#sharing-settings-between-macs). |

---

## Appearance

*Per profile.* Text, colors and how the window around the terminal looks.

### Text

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Font:** | Any installed font, any size | System monospaced, **12 pt** | The terminal font. The reset button returns to the default. |
| **Cursor:** | Blinking Block · Steady Block · Blinking Underline · Steady Underline · Blinking Bar · Steady Bar | **Blinking Block** | The cursor shape. Programs can still change it while they run. |
| **Use bright colors for bold text** | On · Off | **On** | Bold text is drawn in the bright version of its color, as most terminals do. |
| **Background opacity:** | 0 – 100% | **85%** | How much of the desktop shows through. System Settings → Accessibility → Display → *Reduce transparency* makes every terminal opaque without changing this value. |

### Window colors

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Color the window to match the theme** | On · Off | **On** | The title bar, tabs and sidebar take the theme's colors, so the window reads as one piece. Off: they follow the system's light or dark appearance. |
| **Use the system title bar color instead (light or dark)** | On · Off | Off | Like Terminal.app: the title bar is light in Light Mode and dark in Dark Mode, and always opaque, so it stands apart from the terminal as the place to drag the window. Only applies while the window matches the theme. |
| **Keep the projects sidebar opaque** | On · Off | Off | Keeps the sidebar solid while the terminal is translucent. |
| **Keep the tab strip opaque** | On · Off | Off | The same for the tab strip. General → *Keep the tab strip opaque in every profile* overrides this while it is on. |

> **Example:** a dark theme with *Use the system title bar color* on, in
> Light Mode, gives a white title bar above a dark terminal, the way
> Terminal.app looks.

### Theme

**Theme**: the color scheme, picked from the list of built-in and imported
themes. Default: **SwiftTerm** (black background). A window can also switch to
another theme on its own, from its theme picker, without changing the profile.

---

## Window

*Per profile.* The window title, the window's starting size, and scrollback.

### Title

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Custom title:** | Text | *(empty)* | Leads the title with your own text, e.g. `prod`. |
| **Title components** | Working directory (and Path) · Active title · Active process name (and Arguments) · Shell command name · Profile name · TTY name · Dimensions | Working directory, Active title, Active process name | What else the title shows, in this order. *Path* shows the full path instead of the folder name; *Arguments* adds the process's arguments. |

> **Example:** with Working directory, Active process name, Shell command
> name, TTY name and Dimensions on, a shell at a prompt in `/tmp` reads
> `/tmp — -zsh — zsh — ttys010 — 100×44`.

### Window Size

| Setting | Options | Default | What it does |
|---|---|---|---|
| Columns · Rows | Numbers | **80 × 25** | The size a new window opens at, in characters. |

### Scrollback

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Limit scrollback** | On · Off | **On** | Off keeps every line, which can use a lot of memory for chatty programs. |
| **Scrollback lines:** | Number | **10,000** | Shown while the limit is on: how many lines to keep. |

---

## Shell

*Per profile.* What runs in the terminal, and what happens when it ends.

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Run:** | Default login shell · Command | **Default login shell** | Your account's shell, started as a login shell. *Command* runs something else instead. |
| **Command:** | Text | *(empty)* | Shown for *Command*, e.g. `htop` or `ssh build-box`. |
| **Run inside shell** | On · Off | On | Shown for *Command*: runs it through your shell, so aliases and `PATH` work. |
| **When the shell exits:** | Close the window · Close if the shell exited cleanly · Don't close the window | **Close if the shell exited cleanly** | *Cleanly* means exit status 0, or Ctrl-C (130), or a closed pipe (141). Anything else keeps the pane open so you can read the error. |
| **Ask before closing:** | Always · Never · Only if there are running processes | **Only if there are running processes** | Whether closing a terminal asks first. |

---

## Keyboard

*Per profile.* For ⌘1–9 and key repeat, which apply to every profile, see
[General → Keyboard](#keyboard-every-profile).

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Use Option as Meta key** | On · Off | **On** | Option sends Escape plus the key, as shells and Emacs expect: ⌥B and ⌥F move by word. Off: Option types special characters (⌥E then E types é). |
| **Delete sends Control-H** | On · Off | Off | Delete sends `^H` instead of `^?`, for old systems that expect it. |
| **Hide pointer while typing** | On · Off | **On** | The mouse pointer disappears while you type, and returns when you move the mouse. |

### Key Mappings

Your own shortcuts, added with **Add Key Mapping**. Each one is a key, its
modifiers (Command, Shift, Option, Control), and an action:

| Action | Value |
|---|---|
| Send text | The text to type, e.g. `git status\n` |
| Send escape sequence | The sequence after Escape, e.g. `[A` (sends ↑) |
| Scroll one page up · Scroll one page down | — |
| Scroll one line up · Scroll one line down | — |

Default: no mappings.

> **Example:** key `j`, Command + Shift, *Send escape sequence* `[A` makes
> ⇧⌘J act as the up arrow. Pick keys Moo does not already use; see
> [SHORTCUTS.md](SHORTCUTS.md).

### Shortcuts

A read-only list of every shortcut Moo defines, grouped by Windows &
Projects, Tabs, Splits, Terminal, Command Palette, Markdown Previews, Browser
Tabs and Mouse. Shortcuts are app-wide, so the list is the same in every
profile. The full list is in [SHORTCUTS.md](SHORTCUTS.md).

---

## Advanced

*Per profile.* How the terminal identifies itself to programs.

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Declare terminal as:** | `xterm-256color` · `xterm-color` · `xterm` · `vt100` · `xterm-ghostty` · any value | **`xterm-256color`** | The `TERM` variable. Programs use it to decide which features to use. |
| **TERM_PROGRAM:** · **TERM_VERSION:** | Text | `ghostty` · `1.3.1` | Shown only for `xterm-ghostty`. Some programs, such as Claude Code, pick features by these. With any other `TERM`, Moo leaves both unset. |
| **Bell:** | None · Sound · Visual · Sound and Visual | **Sound** | What happens when a program rings the bell (`printf '\a'`). |

### Environment

Variables set for every shell this profile starts, on top of what Moo
inherits. **Add Environment Variable** adds a row with a name and a value;
**Unset** removes an inherited variable instead.

> **Example:** `EDITOR` = `nvim` sets your editor; `NO_COLOR` with *Unset*
> on removes a variable you exported elsewhere.

Default: none.

---

## Updates

| Setting | Options | Default | What it does |
|---|---|---|---|
| **When a new version is out:** | Show the update window automatically · Only show the purple dot · Don't check for updates | **Show the update window automatically** | *Window:* Moo checks daily and opens the update window when a version is out. *Purple dot:* Moo still checks once a day, quietly, and only marks the title bar; nothing opens until you click. *Don't check:* Moo never contacts the update server on its own. |
| **Download and install updates automatically** | On · Off | Off | Downloads in the background and installs when you quit. Only with *Show the update window automatically*. |
| **Check for Updates Now** | — | — | Checks right away, whatever the choice above. *Last checked* shows when the last check ran. |

**The purple dot.** Whenever Moo knows of a newer version, a purple dot sits
at the right end of every window's title bar, beside the update window if
that opened too. Click it for the version and release date, then
**Show Update…** for the release notes and **Install**. At the same time the
**Check for Updates…** menu item reads **Update to Moo *version*…**. The dot
clears when you install or skip that version, and stays after
*Remind Me Later*.

> **Example:** with *Only show the purple dot*, Moo 0.1.9 comes out while you
> work. Nothing interrupts you; within a day the dot appears, and you update
> when it suits you.

Development builds never check for updates. Where a Mac had turned automatic
checks off before this choice existed, it starts at *Don't check for updates*.

---

## Data

Lists any settings or data file Moo could not read, such as a damaged profile
file, with what to do about each: **Reveal** it in the Finder,
**Retry**, **Restore Backup**, **Reset Preferences**, or **Move to Trash**.
The page's sidebar entry shows a count when something needs attention.
Normally it reads *Moo found no data that needs attention.*

---

## Sharing Settings Between Macs

**Export…** on the Profiles page writes a `.mooprofile` file holding the
profile, its theme when the theme is not built in, and the app-wide settings
on the Moo pages. When the profile sets environment variables, Export asks
first whether to include them (**Leave Them Out** is the default): they often
hold tokens, and anyone given the file can read them.

**Import…** on another Mac reads the file and asks before changing anything:

1. If the profile does more than change how Moo looks, an alert lists each
   such part word for word: a command run instead of your shell, every
   environment variable it sets or unsets, every key mapping, and a
   `TERM_PROGRAM`/`TERM_VERSION` that differs from the default.
   **Import Appearance Only** (the default, so Return picks it) keeps the
   font, colors, theme and window settings and drops all of those, leaving
   the login shell, no variables, no key mappings and the default terminal
   identity. **Import Everything** keeps the profile as written; choose it
   only for a file you trust. **Cancel** imports nothing.
2. If the file carries app settings, a second alert asks whether to apply
   them too (**Apply Settings**) or take only the profile (**Profile
   Only**). A setting the file does not mention returns to its default.

Nothing is saved until both answers are in, so Cancel at either step leaves
Moo as it was. Sizes are brought into range on the way in: at most 1,000
columns and rows, 1,000,000 lines of scrollback, and a font size from 4 to
288 points.

### Never shared, for security

A profile file is often passed around like a theme, so importing one must
not be able to weaken the Mac it lands on, or decide what Moo runs. That is
why the profile's command, variables and key mappings are reviewed as above,
and why these settings are **never written to a `.mooprofile` and are
ignored when one is imported**, even if the file contains them. They stay
exactly as this Mac has them:

| Setting | Why it stays on this Mac |
|---|---|
| Secure Keyboard Entry (Terminal menu), and its password-prompt mode | It stops other apps from reading what you type. A shared file could switch it off. |
| Web inspector for browser tabs | It exposes the pages, cookies and storage of browser tabs. |
| Output logging | It records every pane's raw output to disk. |
| **When a new version is out:** (Updates) | A shared file could stop the Mac from hearing about security updates. |
| **Open:**, **Profile:** and **Window group:** (General → Startup) | A shared file could make every launch open a profile it brought, one whose shell runs a command, even after you imported its appearance only. |
| **Block ads and trackers** (Links & Markdown) | A shared file could switch off tracker blocking in browser tabs. |
| **Show herdr agents** (Notifications → herdr) | Turning it on lets Moo read other programs' arguments and connect to herdr's socket. That consent is yours to give, not a shared file's. |

