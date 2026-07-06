# nice-sidebar.yazi — Finder-style sticky sidebar for Yazi

**Date:** 2026-07-06
**Status:** approved design, pending implementation
**Repo:** `github.com/Townk/nice-sidebar.yazi` (local: `~/Projects/apps/yazi/nice-sidebar.yazi`)

## Goal

Replace Yazi's parent column with a permanent, Finder-like sidebar: a fixed-width
sticky column listing the user's core directories, pinned directories, and mounted
disks. Nothing else may ever render in that column. The interaction model is
adopted from the terminal-time-machine scrub sessions (`tm-gate.yazi`): a
`Parent:redraw` override for the visuals, disabled mouse fallthrough, and
selection keys that drive `cd` directly.

Target: Yazi 26.5+ (`Tab:layout` and `rt.mgr` APIs), macOS-first. Distributed as
a standard standalone Yazi plugin installable with `ya pkg add Townk/nice-sidebar`.

## Non-goals

- Disk eject / unmount actions (deferred).
- Pin reordering UI (pins render in file order; deferred).
- Recents / AirDrop-style virtual entries (deferred).
- Linux mount enumeration (`/run/media`, `/media`) — the Disks section
  auto-hides on non-macOS for v1 (deferred).
- Theming beyond the `colors` setup option (no theme-file parsing in the plugin).

## Repo layout

```
nice-sidebar.yazi/
├── main.lua           the whole plugin (single file, tm-gate style)
├── README.md          features, install, config reference, keymap, theming
├── LICENSE            MIT
├── .luarc.json        Lua 5.4 + yazi globals (ya, cx, rt, ui, ps, th, ...)
├── stylua.toml        repo Lua style (matches author's yazi config style)
└── docs/superpowers/specs/   this spec
```

The GitHub repo name carries the `.yazi` suffix so `ya pkg add Townk/nice-sidebar`
resolves it by convention (same shape as `Reledia/hexyl.yazi`).

## Visual spec

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

Rules:

- 1 space of leading and trailing horizontal padding on every line. The title
  rule (`━`) spans `width - 2`.
- Items render as `␣␣<icon>␣<label>` — 2 leading spaces, so item icons start at
  column 3.
- Section headers (`󰐃 Pinned`, `󰋊 Disks`) get 1 extra leading space relative to
  the main title — their icon aligns with the item icons at column 3. Their rule
  is inset by the same amount and 2 cells shorter than the title rule.
- One blank line between the title rule and the first item, and one blank line
  before each section header.
- Labels are truncated with `…` to fit the column; pinned labels are the pin's
  `~`-abbreviated path.
- If the assembled sidebar outruns the column height, the rows window around the
  selected row (or the top when nothing is selected) with `␣⋮` marker lines at
  the clipped edges — same behavior as the tm timeline.

### Colors

| Element | Default | `colors` key |
| --- | --- | --- |
| Title (H1) | `magenta`, bold | `title` |
| Section header (H2) | default fg, bold | `section` |
| Rules | `darkgray` | `separator` |
| Item label + icon | default fg | `item` |
| Selected item, sidebar focused | `reversed` pill | `selected_bg` / `selected_fg` (both set → replaces reversed) |
| Selected item, list focused | bold text, no pill | `selected_inactive_bg` / `selected_inactive_fg` (both set → colored pill) |

The selected row draws as **yazi's cursor pill**: rounded caps from
`th.indicator.padding.open/close` around the highlighted body, inset 1 cell
from each column edge (the label is pre-truncated so the close cap never
clips). When no background color is available to shape a cap with (the
portable bold default while the list holds focus), the row renders as plain
bold text without the pill.
| File cursor while sidebar focused | untouched | `cursor_bg` / `cursor_fg` (both set → restyles `th.indicator.current` on focus, restored on blur) |

Every `colors` value accepts anything `ui.Style():fg()` takes (named ANSI or
`#rrggbb`). The author's personal config passes hexes from the chezmoi theme
bridge (H1 = `roles.ui.title`, H2 = `roles.ui.fg` bold, rules =
`roles.ui.separator`, selected = `extended.tab.active_bg/active_fg`,
inactive-selected + cursor = `extended.tab.bg/fg` — the exact tm-gate
treatment) — that wiring lives in the consumer's `init.lua`, not in this
plugin.

## Sections

### 1. Core directories

From `setup{ dirs = { { label, path, icon }, ... } }`, rendered in list order.
Defaults (macOS):

| Label | Path | Icon |
| --- | --- | --- |
| Home | `~` | `󰠦` |
| Desktop | `~/Desktop` | `󰇄` |
| Downloads | `~/Downloads` | `󱑢` |
| Documents | `~/Documents` | `󰈙` |
| Pictures | `~/Pictures` | `󰋩` |
| Videos | `~/Movies` | `󰿎` |
| Music | `~/Music` | `󰝚` |

`~` in paths expands against `$HOME`. Entries whose path does not exist (or is
not a directory) are hidden, not errors. Symlinks are followed — a symlinked
entry that resolves to a directory counts (same for pins).

### 2. Pinned

Hidden entirely (header, rule, blank line) when there are no live pins.

- Store: one absolute path per line in
  `${XDG_STATE_HOME:-~/.local/state}/yazi/nice-sidebar/pins` (override with
  `setup{ pins_file = ... }`).
- `plugin nice-sidebar pin` toggles a pin for the hovered directory, falling
  back to the cwd when the hovered entry is a file. Writes the file atomically
  (write temp + rename); malformed/duplicate lines are dropped on rewrite.
- Dead paths are hidden from the sidebar but preserved in the file (a pin to an
  unmounted volume survives).
- Item icon `󰉋`; label = `~`-abbreviated path, truncated to fit.

### 3. Disks

Shown only when `ya.target_os() == "macos"` and `setup{ show_disks ~= false }`.

- Volumes = the entries of `/Volumes` (this includes `Macintosh HD` and any
  mounted disk image / external drive). Selecting one cds to
  `/Volumes/<name>`.
- Scanning is **async only** (never in the sync redraw path): a
  `plugin nice-sidebar refresh` entry lists `/Volumes` with
  `fs.read_dir(..., { resolve = true })` — resolve is required because
  `Macintosh HD` is a symlink to `/` — and classifies each volume via
  `diskutil info` plain-text output (`Command`, `output()`): `Protocol:
  Disk Image` → image; `Internal: Yes` (Intel) or `Device Location:
  Internal` (Apple Silicon) → internal; else external. The result is
  published into the sync VM (`ya.sync`) and repainted (`ui.render`).
- Triggers: once from `setup()` (via `ya.emit("plugin", ...)`), and re-triggered
  from the `cd`/`tab` events, throttled to at most one scan per 5 s. A scan
  failure keeps the previous list.
- Icons: internal disk `󰋊`, disk image ``, external/removable `󱊞`
  (overridable via `setup{ disk_icons = { internal, image, external } }`).

## Layout

`setup()` overrides `Tab:layout()`: the parent slot becomes
`ui.Constraint.Length(width)` (default 26); current and preview split the
remainder preserving the proportions of `rt.mgr.ratio[current]` :
`rt.mgr.ratio[preview]` (`ui.Constraint.Ratio` over the two). `width` is clamped
so current/preview keep at least a few columns on narrow terminals.

Compatibility: `full-border` wraps `Tab.build` and only pads `self._chunks` and
draws bars at chunk edges — it composes with this override untouched.
`toggle-pane` min/max on current/preview keeps working because the remainder
still honors `rt.mgr.ratio` (a `0`/`9999` ratio zeroes/maximizes its column);
`min-parent`/`max-parent` are documented as unsupported (the sidebar owns that
slot).

## Interaction

State lives in the sync VM: `selected` (item index or `nil` — **`nil` at
startup**), `focus` (`"list"` or `"sidebar"` — **`"list"` at startup**), the
flattened selectable item list, pins, and the volume cache.

Two invariants tie the model together:

- **Selection = cd.** Every selection change immediately `ya.emit("cd", ...)`
  to the item's path, from any trigger (keys, mouse, focus).
- **A focused sidebar always has a selection.** Any action that gives the
  sidebar focus while nothing is selected selects Home (the first item) — and
  therefore cds there.

### Commands

- **`next` / `prev`** (bindings: `<S-j>`/`<S-Down>` and `<S-k>`/`<S-Up>`):
  move the selection **globally** — they work from either focus side and do
  not change focus. Movement walks selectable rows only (headers, rules,
  blanks are skipped), clamped at both ends, crossing sections. When nothing
  is selected, both commands select Home.
- **`focus`** (binding: `<S-h>`/`<S-Left>`, global): give the sidebar focus.
  No-op when the sidebar already holds it (this is the "Shift+H from the
  sidebar is a no-op" rule).
- **`h`** (bindings: `h`, `<Left>`): focus-scoped dispatch —
  sidebar focused → **no-op**; list focused at the filesystem root (the tab
  has no parent folder) → focus the sidebar; otherwise → `leave` (stock
  behavior).
- **`l`** (bindings: `l`, `<Right>`): focus-scoped dispatch — sidebar
  focused → return focus to the file list (selection untouched); list
  focused → `enter` (stock behavior).
- **`j` / `k`** (bindings: `j`/`<Down>`, `k`/`<Up>`): focus-scoped dispatch —
  sidebar focused → same as `next`/`prev`; list focused → `arrow 1`/`arrow -1`
  (stock cursor movement).
- **`pin`** (suggested binding: `b p`): toggle pin, as above.
- **`refresh`**: manual volume rescan (also used internally).

### cd tracking (`ps.sub("cd")`)

After any cd — from the sidebar or normal navigation —

1. if the new cwd equals a sidebar item's path exactly, that item becomes
   selected (exact match beats an umbrella match, so `~/Desktop` selects
   Desktop, not Home; if two items share a path — e.g. a pin duplicating a
   core dir — the first in list order wins);
2. else if an item is selected and the new cwd is still inside its umbrella
   (path-component prefix), selection is kept;
3. else the selection clears — and if the sidebar held focus, focus returns
   to the file list (the second invariant: no focused sidebar without a
   selection).

### Mouse

- Click on an item row: select + cd, and the sidebar takes focus.
- Click anywhere else in the column: the sidebar takes focus; an existing
  selection is kept, otherwise Home is selected (invariant above).
- `Parent:scroll` is a no-op. Nothing can navigate the underlying parent
  folder through that column.

### Focus feedback

The selected row renders with the focused style while the sidebar holds
focus and with the inactive style otherwise (see §Colors). Optionally, when
`colors.cursor_bg/cursor_fg` are set, the file-list cursor
(`th.indicator.current`) is restyled with them while the sidebar holds focus
and restored on blur — the tm-gate treatment, showing at a glance which side
owns j/k.

The plugin never rebinds keys itself; the README documents the suggested
`prepend_keymap` rows (including the `j`/`k`/`h`/`l`/arrow dispatch rows,
which are required for the focus model to work).

## Config API (complete)

```lua
require("nice-sidebar"):setup {
  title = "Yazi File Manager",   -- header text
  title_icon = "󰇥",
  width = 26,                    -- sidebar column width (cells)
  dirs = { ... },                -- see §Core directories (replaces defaults)
  show_disks = true,
  disk_icons = { internal = "󰋊", image = "", external = "󱊞" },
  pins_file = nil,               -- default: XDG state path
  colors = {                     -- all optional; see §Colors
    title = nil, section = nil, separator = nil, item = nil,
    selected_bg = nil, selected_fg = nil,                    -- sidebar focused
    selected_inactive_bg = nil, selected_inactive_fg = nil,  -- list focused
    cursor_bg = nil, cursor_fg = nil,  -- file cursor while sidebar focused
  },
}
```

Calling `setup()` is what activates the plugin — no setup call, no overrides.
Consumers who need to disable it conditionally guard the call in their
`init.lua` (the author gates on `BKP_TM_SESSION` — tm scrub sessions own the
parent column via tm-gate — and on `NVIM`, where the embedded float is too
narrow).

## Error handling

- Theme values absent/invalid → per-element defaults from §Colors.
- Pins file unreadable → treated as empty; unwritable → pin toggle is a no-op
  (`ya.notify` a warning).
- Volume scan / `diskutil` failure → keep the previous volume list; icon
  classification failure → `external` icon.
- Missing configured dirs → hidden.
- All overrides installed via `pcall`; a failure degrades to stock yazi rather
  than breaking the app.

## Validation

- Pure-logic self-tests (run headless with plain `lua`): item flattening +
  header skipping, umbrella prefix matching (incl. `Home` vs `Desktop`
  nesting), focus/selection invariants (focus with no selection → Home;
  selection cleared → focus falls back to the list), pin toggle round-trip,
  label truncation, volume icon mapping.
- Manual UX pass in a live yazi: mock fidelity (padding/rules/colors),
  Shift+J/K walk incl. empty-selection → Home, immediate cd, umbrella
  clearing, exact cd adoption; focus round-trip (Shift+H in, `h`/`Left` at
  the filesystem root in, `l`/`Right` out, no-op keys inside, j/k scoping
  each side, cursor restyle when configured); click on item and on empty
  sidebar area; pinned-section appearance/disappearance; disk image
  mount/unmount; narrow-terminal windowing; full-border + toggle-pane
  coexistence; and a tm scrub session (`g t`) confirming tm-gate still owns
  the column there.

## Consumer integration (author's chezmoi repo — follow-up, separate change)

- `package.toml`: add `Townk/nice-sidebar` dep (`ya pkg add`, capture lockfile
  bump inline per repo convention).
- `init.lua`: guarded `setup{}` call passing theme-bridge colors + the extra
  dirs (Depot, Notes, Projects, Public) with the icons from the design mock.
- `keymap.toml`: rebind `K`/`J` (+ `<S-Up>`/`<S-Down>`) to
  `plugin nice-sidebar prev|next`; rebind `H` and `<S-Left>` to
  `plugin nice-sidebar focus` — **`H` currently runs `bypass reverse`, which
  this replaces** (parent siblings are never displayed, so reverse-bypass has
  nowhere to go); add the `j`/`k`/`h`/`l`/`<Up>`/`<Down>`/`<Left>`/`<Right>`
  dispatch rows; add `b p` → `plugin nice-sidebar pin`; delete the
  `parent-arrow.yazi` plugin and its `K`/`J` bindings.
- tm sessions need no changes: their K/J/H/L and j/k/h/l rows are injected at
  the head of the keymap and win, and the guarded setup never runs there.

## Deferred

Disk eject action · pin reordering · Linux mounts · virtual entries (Recents,
AirDrop) · scroll-wheel selection.
