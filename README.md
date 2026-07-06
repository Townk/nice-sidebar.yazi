# nice-sidebar.yazi

A Finder-style sidebar for [Yazi](https://yazi-rs.github.io), living in the
parent column — permanently. Core directories, pinned directories, and
mounted disks, with a keyboard focus model that stays out of your way.

```
 󰇥 Yazi File Manager
 ━━━━━━━━━━━━━━━━━━━

  󰠦 Home
  󰇄 Desktop
  󱑢 Downloads
  󰈙 Documents
  󰋩 Pictures
  󰿎 Videos
  󰝚 Music

  󰐃 Pinned
  ━━━━━━━━━━━━━━━━━
  󰉋 ~/Projects/My proj

  󰋊 Disks
  ━━━━━━━━━━━━━━━━━
  󰋊 Macintosh HD
   work disk image
```

## Features

- **Sticky**: the parent column is replaced wholesale — no parent listing,
  no mouse fallthrough, fixed width instead of a ratio.
- **Sections**: your directories (configurable), pins (toggle with a key,
  section hides when empty), and mounted volumes (macOS, auto-classified:
  internal disk / disk image / external drive).
- **Selection = navigation**: selecting a sidebar item cds there, from
  either side of the focus. Leave a selected item's subtree and the
  selection clears itself; cd exactly onto an item's path and it lights up.
- **Focus model**: `Shift+H` (or `h` at the filesystem root) moves focus to
  the sidebar; `j`/`k` then walk it; `l` hands focus back to the file list.
  A focused sidebar always has a selection.
- **Theme-agnostic**: named ANSI colors by default, every element
  overridable with hex values.

## Requirements

- Yazi **26.5+**
- A [Nerd Font](https://www.nerdfonts.com) (the default icons)
- macOS for the Disks section (the rest works anywhere; Disks auto-hides)

## Installation

```sh
ya pkg add Townk/nice-sidebar
```

## Setup

In `~/.config/yazi/init.lua`:

```lua
require("nice-sidebar"):setup({})
```

And in `~/.config/yazi/keymap.toml` — the plugin never rebinds keys itself;
these rows are the intended dialect (the `j`/`k`/`h`/`l`/arrow rows are
required for the focus model):

```toml
[mgr]
prepend_keymap = [
  { on = "K",          run = "plugin nice-sidebar prev",  desc = "Sidebar: select the previous item" },
  { on = "J",          run = "plugin nice-sidebar next",  desc = "Sidebar: select the next item" },
  { on = "<S-Up>",     run = "plugin nice-sidebar prev",  desc = "Sidebar: select the previous item" },
  { on = "<S-Down>",   run = "plugin nice-sidebar next",  desc = "Sidebar: select the next item" },
  { on = "H",          run = "plugin nice-sidebar focus", desc = "Sidebar: focus" },
  { on = "<S-Left>",   run = "plugin nice-sidebar focus", desc = "Sidebar: focus" },
  { on = "<S-Right>",  run = "plugin nice-sidebar blur",  desc = "Sidebar: focus the file list" },
  { on = "L",          run = "plugin nice-sidebar blur",  desc = "Sidebar: focus the file list" },
  { on = "h",          run = "plugin nice-sidebar h",     desc = "Leave; focus the sidebar at the root" },
  { on = "<Left>",     run = "plugin nice-sidebar h",     desc = "Leave; focus the sidebar at the root" },
  { on = "l",          run = "plugin nice-sidebar l",     desc = "Enter; leave the sidebar" },
  { on = "<Right>",    run = "plugin nice-sidebar l",     desc = "Enter; leave the sidebar" },
  { on = "j",          run = "plugin nice-sidebar j",     desc = "Down (list) / next (sidebar)" },
  { on = "<Down>",     run = "plugin nice-sidebar j",     desc = "Down (list) / next (sidebar)" },
  { on = "k",          run = "plugin nice-sidebar k",     desc = "Up (list) / previous (sidebar)" },
  { on = "<Up>",       run = "plugin nice-sidebar k",     desc = "Up (list) / previous (sidebar)" },
  { on = [ "b", "p" ], run = "plugin nice-sidebar pin",   desc = "Sidebar: pin or unpin this directory" },
]
```

## Interaction model

Two invariants drive everything:

1. **Selection is navigation.** Changing the sidebar selection — keys,
   mouse, focus — immediately cds to that item. Clicking an item you are
   already inside returns you to its root, like Finder.
2. **A focused sidebar always has a selection.** Focusing it with nothing
   selected selects Home (and cds there). When the selection clears (you
   navigated out of its subtree), a focused sidebar hands focus back to
   the file list.

| Key | File list focused | Sidebar focused |
| --- | --- | --- |
| `J` / `Shift+Down` | select next sidebar item | select next sidebar item |
| `K` / `Shift+Up` | select previous sidebar item | select previous sidebar item |
| `H` / `Shift+Left` | focus the sidebar | nothing |
| `h` / `Left` | leave; at `/`, focus the sidebar | nothing |
| `l` / `Right` | enter | focus the file list |
| `L` / `Shift+Right` | fallthrough (see below) | focus the file list |
| `j` / `Down` | cursor down | select next sidebar item |
| `k` / `Up` | cursor up | select previous sidebar item |
| `b p` | pin/unpin the hovered directory | — |

Mouse: clicking an item selects it (and cds); clicking empty sidebar space
focuses the sidebar, selecting Home if nothing was selected.

The selected row draws as the same rounded pill yazi uses for its file
cursor (the caps come from your theme's `th.indicator.padding`), inset one
cell from the column edges. Without configured selection colors, the
list-focused fallback is plain bold text — no pill, since there is no
background color to shape the caps with.

`blur` accepts a fallthrough: any keymap args after it run as a command when
the file list already holds focus. If you bind `L` and use a plugin there
(e.g. [bypass](https://github.com/Rolv-Apneseth/bypass)), keep its behavior
with `run = "plugin nice-sidebar blur plugin bypass"`.

`plugin nice-sidebar refresh` manually rescans mounted volumes (rescans also
happen on navigation, throttled, and on mount events when yazi publishes
them). Disks cover `/Volumes` plus disk images attached at custom
mountpoints (say, a sparse bundle mounted under `~/Projects`); labels use
the volume's name, not its mountpoint.

## Configuration

Everything is optional; the defaults are shown.

```lua
require("nice-sidebar"):setup({
	title = "Yazi File Manager",
	title_icon = "󰇥",
	width = 26, -- sidebar width in cells
	dirs = { -- replaces the whole list; order is display order
		{ label = "Home", path = "~", icon = "󰠦" },
		{ label = "Desktop", path = "~/Desktop", icon = "󰇄" },
		{ label = "Downloads", path = "~/Downloads", icon = "󱑢" },
		{ label = "Documents", path = "~/Documents", icon = "󰈙" },
		{ label = "Pictures", path = "~/Pictures", icon = "󰋩" },
		{ label = "Videos", path = "~/Movies", icon = "󰿎" },
		{ label = "Music", path = "~/Music", icon = "󰝚" },
	},
	show_disks = true, -- macOS only; auto-hidden elsewhere
	disk_icons = { internal = "󰋊", image = "", external = "󱊞" },
	pins_file = nil, -- default: $XDG_STATE_HOME/yazi/nice-sidebar/pins
	colors = { -- named ANSI or "#rrggbb"; nil = portable default
		title = nil, -- H1 (default: magenta, bold)
		section = nil, -- H2 (default: bold)
		separator = nil, -- rules (default: darkgray)
		item = nil, -- item rows (default: your fg)
		selected_bg = nil, -- selected row, sidebar focused
		selected_fg = nil, --   (default: reversed)
		selected_inactive_bg = nil, -- selected row, list focused
		selected_inactive_fg = nil, --   (default: bold)
		cursor_bg = nil, -- file cursor while the sidebar holds focus
		cursor_fg = nil, --   (default: untouched)
	},
})
```

Entries whose path doesn't exist are hidden, not errors — a `dirs` entry
for a directory that only exists on one machine is fine.

Not calling `setup()` deactivates the plugin entirely, which is also how
you disable it conditionally:

```lua
if not os.getenv("NVIM") then
	require("nice-sidebar"):setup({})
end
```

## Playing along with other plugins

- **full-border** composes cleanly (it pads the same three chunks).
- **toggle-pane** `min-preview`/`max-preview`/`min-current`/`max-current`
  keep working; `min-parent`/`max-parent` are unsupported — the sidebar
  owns that slot.
- Plugins that override `Parent:redraw` or `Tab:layout` themselves will
  fight this one; last `setup()` wins. If you conditionally run such a
  session (this plugin's ancestor, the terminal-time-machine scrub UI, is
  one), guard this `setup()` call away in that environment.

## License

MIT — see [LICENSE](LICENSE).
