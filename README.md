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

  🖴 Disks
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
required for the focus model). **Every act is a single token** — Yazi 26.5
passes a plugin only its first positional argument, so multi-word forms like
`plugin nice-sidebar guard arrow bot` silently lose the tail; the acts emit
any fallthrough themselves.

```toml
[mgr]
prepend_keymap = [
  # Sidebar item navigation (from the panes)
  { on = "K",          run = "plugin nice-sidebar prev",  desc = "Sidebar: previous item" },
  { on = "J",          run = "plugin nice-sidebar next",  desc = "Sidebar: next item" },
  { on = "<S-Up>",     run = "plugin nice-sidebar prev",  desc = "Sidebar: previous item" },
  { on = "<S-Down>",   run = "plugin nice-sidebar next",  desc = "Sidebar: next item" },

  # Horizontal focus slider: sidebar │ file panes │ staging panel
  { on = "H",          run = "plugin nice-sidebar left",  desc = "Focus left: staging -> panes -> sidebar" },
  { on = "<S-Left>",   run = "plugin nice-sidebar left",  desc = "Focus left" },
  { on = "L",          run = "plugin nice-sidebar right", desc = "Focus right: sidebar -> panes -> staging; else bypass" },
  { on = "<S-Right>",  run = "plugin nice-sidebar right", desc = "Focus right" },
  { on = "<Esc>",      run = "plugin nice-sidebar left",  desc = "Step focus back toward the panes" },

  # Within-region navigation (interpreted by the focused region)
  { on = "h",          run = "plugin nice-sidebar h",     desc = "List: leave · Panel: Staged lane" },
  { on = "<Left>",     run = "plugin nice-sidebar h",     desc = "List: leave · Panel: Staged lane" },
  { on = "l",          run = "plugin nice-sidebar l",     desc = "List: enter · Sidebar: focus panes · Panel: Clipboard lane" },
  { on = "<Right>",    run = "plugin nice-sidebar l",     desc = "List: enter · Sidebar: focus panes · Panel: Clipboard lane" },
  { on = "j",          run = "plugin nice-sidebar j",     desc = "Down (list / sidebar / panel)" },
  { on = "<Down>",     run = "plugin nice-sidebar j",     desc = "Down (list / sidebar / panel)" },
  { on = "k",          run = "plugin nice-sidebar k",     desc = "Up (list / sidebar / panel)" },
  { on = "<Up>",       run = "plugin nice-sidebar k",     desc = "Up (list / sidebar / panel)" },
  { on = "<Enter>",    run = "plugin nice-sidebar enter", desc = "List: open/smart-enter · Sidebar: commit · Panel: reveal" },
  { on = "G",          run = "plugin nice-sidebar guard_bot", desc = "Bottom (list only)" },
  { on = [ "g", "g" ], run = "plugin nice-sidebar guard_top", desc = "Top (list only)" },

  # Selection + staging/clipboard panel
  { on = "<Space>",    run = "plugin nice-sidebar space",  desc = "Toggle selection (cursor stays) / unstage in panel" },
  { on = "<A-Space>",  run = "plugin nice-sidebar sspace", desc = "Toggle selection (move next) / unstage in panel" },
  { on = "<A-s>",      run = "plugin nice-sidebar lane_staged",    desc = "Jump to the Staged lane" },
  { on = "<A-c>",      run = "plugin nice-sidebar lane_clipboard", desc = "Jump to the Clipboard lane" },

  { on = [ "b", "p" ], run = "plugin nice-sidebar pin",   desc = "Sidebar: pin/unpin this directory" },
]
```

## Interaction model

By default the sidebar is a **picker you browse, then confirm** — once the
sidebar is focused, moving the highlight does *not* touch the file panes; you
press `Enter` to commit and jump into the panes. From the main pane,
`Shift+Up`/`Shift+Down` still jump directly (cd immediately, focus stays on the
panes). Set `follow = true` to make the panes track the highlight live in the
sidebar too (see [Navigation mode](#navigation-mode)).

Two invariants hold in both modes:

1. **A focused sidebar always has a selection.** Focusing it with nothing
   selected highlights Home.
2. **When the file list has focus, the highlight reflects the cwd** — it
   adopts an item when you cd exactly onto its path, and clears when the cwd
   leaves every item's subtree.

The table below is the default (deferred) mode:

| Key | File list focused | Sidebar focused |
| --- | --- | --- |
| `J` / `Shift+Down` | select next + cd (focus stays on panes) | highlight next (no cd) |
| `K` / `Shift+Up` | select previous + cd (focus stays on panes) | highlight previous (no cd) |
| `H` / `Shift+Left` | focus the sidebar (slider: → sidebar) | nothing |
| `L` / `Shift+Right` | staging panel if populated, else `bypass` (slider: → panel) | cancel: focus panes |
| `h` / `Left` | leave; at `/`, focus the sidebar | nothing |
| `l` / `Right` | enter | cancel: focus panes, highlight reverts to cwd |
| `Enter` | open / smart-enter | **commit**: cd + jump to panes |
| `G`, `g g`, … | list navigation | nothing (suppressed) |
| `j` / `Down` | cursor down | highlight next (no cd) |
| `k` / `Up` | cursor up | highlight previous (no cd) |
| `b p` | pin/unpin the hovered directory | pin/unpin the selected sidebar item |

With `follow = true`, every "highlight" cell above cds live instead, `Enter`
just re-anchors and jumps, and `J`/`K` don't change focus.

Mouse: clicking an item commits it (cd); clicking empty sidebar space focuses
the sidebar and highlights Home (cd only in `follow` mode).

### Navigation mode

`follow = false` (the default) gives the deferred picker above: browse the
sidebar without disturbing the panes, `Enter` to confirm, `l`/`Shift+Right`
to cancel. `follow = true` restores live navigation — the panes cd on every
highlight move.

While the sidebar holds focus it owns the keyboard: list-navigation keys
(`Enter`, `G`, `g g`, and any others you wrap) are suppressed so navigation
never runs in the file column underneath you. Wrap those keys with the
`guard` command (or `enter` for `Enter`) — see below. `b p` retargets too:
with the sidebar focused it toggles the pin for the **selected** item, so
you can unpin the row you are looking at.

The selected row draws as the same rounded pill yazi uses for its file
cursor (the caps come from your theme's `th.indicator.padding`), inset one
cell from the column edges. Without configured selection colors, the
list-focused fallback is plain bold text — no pill, since there is no
background color to shape the caps with.

Each act **carries its own fallthrough** and is a single token (Yazi 26.5
gives a plugin only its first positional argument, so keymap-level fallthrough
words are dropped):

- `right` — `L`/`Shift+Right` step focus right; from the panes with nothing
  staged it runs `bypass` (recursive-enter) itself.
- `enter` — on the list it opens files / recursive-enters directories; on the
  sidebar it commits (cd + jump); on the panel it reveals the hovered row.
- `guard_bot` / `guard_top` — `G` / `g g` jump the file list to bottom/top,
  and are inert while the sidebar or panel owns focus.

`plugin nice-sidebar refresh` manually rescans mounted volumes (rescans also
happen on navigation, throttled, and on mount events when yazi publishes
them). Disks cover `/Volumes` plus disk images attached at custom
mountpoints (say, a sparse bundle mounted under `~/Projects`); labels use
the volume's name, not its mountpoint.

## Selection staging & clipboard panel

When you have files selected (`<Space>`) or yanked (`y`/`x`), a compact panel
docks at the **bottom of the preview column** — a third focus region on the
same Shift slider (sidebar │ panes │ **panel**). It has two lanes:

- **Staged** — the current tab's `<Space>` selection (per-tab). Files often
  live in other directories; rows show a cwd-relative or `~`-abbreviated path.
- **Clipboard** — the global yank register (`y` copy / `x` cut). Cut entries
  render in the cut colour.

A tab-bar header shows `stage (N) | 󰅍 clipboard (M)` (only populated lanes get
a label), with a coloured `▁` bar under the active lane. The panel grows one
row per file, caps at half the preview height, and shows a scrollbar past that.

**Keys** (see the keymap above):

| Key | Panes / sidebar | Staged lane | Clipboard lane |
| --- | --- | --- | --- |
| `Space` | toggle selection, cursor stays | **unstage** the row | — (view-only) |
| `Alt+Space` | toggle selection, move next | unstage, move next | — |
| `Alt+s` / `Alt+c` | jump to the Staged / Clipboard lane | | |
| `h` / `l` | *(region nav)* | switch lane (Staged ↔ Clipboard) | |
| `j` / `k`, wheel | *(region nav)* | move the cursor | move the cursor |
| `Enter` | *(open)* | reveal the row → panes | reveal the row → panes |
| `y` / `x` | yank / cut **all staged** | same | same |

The panel is a first-class focus region: while it owns focus the file-list
cursor dims (like the sidebar), and an empty selection *and* clipboard drops
focus back to the panes.

**Clipboard is view-only.** Yazi exposes the yank register read-only to
plugins — it can only be cleared wholesale (`unyank`) or set from a native
object with no Lua constructor — so a single clipboard entry cannot be removed
from the panel. Use `Enter` to reveal, then manage it in the panes.

Disable the panel with `staging = { enabled = false }`.

## Configuration

Everything is optional; the defaults are shown.

```lua
require("nice-sidebar"):setup({
	title = "Yazi File Manager",
	title_icon = "󰇥",
	width = 26, -- sidebar width in cells
	follow = false, -- false: browse, then Enter to commit (default)
	--              -- true:  panes follow the highlight live
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
	disk_icons = { internal = "󰋊", image = "", external = "󱊞" },
	pins_file = nil, -- default: $XDG_STATE_HOME/yazi/nice-sidebar/pins
	staging = { -- the selection / clipboard panel
		enabled = true, -- false: no panel, byte-for-byte the old behaviour
		max_ratio = 0.5, -- cap: fraction of the preview height
		reveal_on_enter = true, -- Enter on a row reveals it (cd + hover)
		icon = "\239\128\156", -- staged rows/tab (U+F01C; byte escapes)
		clipboard_icon = "󰅍", -- clipboard rows/tab
	},
	colors = { -- named ANSI or "#rrggbb"; nil = portable default
		title = nil, -- H1 (default: magenta, bold)
		section = nil, -- H2 (default: bold)
		separator = nil, -- rules (default: darkgray)
		item = nil, -- item rows (default: your fg)
		selected_bg = nil, -- selected row, sidebar focused
		selected_fg = nil, --   (default: reversed)
		selected_inactive_bg = nil, -- selected row, list focused
		selected_inactive_fg = nil, --   (default: bold)
		cursor_bg = nil, -- file cursor while the sidebar/panel holds focus
		cursor_fg = nil, --   (default: untouched)
		staged = nil, -- "stage" tab label (default: yellow)
		clipboard = nil, -- "clipboard" tab label, copy (default: green)
		clipboard_cut = nil, -- "clipboard" tab label, cut (default: red)
		tab_rule = nil, -- panel tab-bar rule glyphs (default: separator)
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
