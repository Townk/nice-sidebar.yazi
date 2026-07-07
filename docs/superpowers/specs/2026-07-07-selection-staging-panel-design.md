# nice-sidebar.yazi — selection staging panel

**Date:** 2026-07-07
**Status:** design, pending user review
**Repo:** `github.com/Townk/nice-sidebar.yazi` (local: `~/Projects/apps/yazi/nice-sidebar.yazi`)
**Builds on:** [`2026-07-06-nice-sidebar-design.md`](./2026-07-06-nice-sidebar-design.md)

## Goal

Give Yazi's multi-file selection a visible home. When files are selected with
`<Space>` (the count Yazi shows top-right), the user currently has no way to see
*which* files are staged — selection persists across directories, so the set
routinely includes files in folders they have navigated away from. Running a
`shell` command to `less` the list takes over the whole terminal, which is poor
UX.

This feature adds a **staging panel**: a live list of the currently-selected
files docked at the **bottom of the preview column**. It grows with the
selection, caps at half the preview height and scrolls beyond that, and becomes a
first-class **keyboard-focus region** integrated into nice-sidebar's existing
focus model — a third stop on the same horizontal Shift-slider that already moves
between the sidebar and the file panes.

Target: Yazi 26.5+ (same `Tab:layout` / `rt.mgr` / component-override surface the
sidebar already uses). macOS-first, but nothing here is macOS-specific.

## Why this belongs in nice-sidebar (not a separate plugin)

The panel touches the two things nice-sidebar already owns exclusively:

1. **Layout** — nice-sidebar overrides `Tab:layout()`. Splitting the preview
   chunk must happen in that same override; a second layout owner would clobber
   the first (last override wins).
2. **Focus** — focus is a single binary state (`S.focus = "list" | "sidebar"`)
   in nice-sidebar's sync VM, and *every* navigation key routes through the
   plugin so it can interpret each key by focus. A "respect the focus rules"
   requirement is, by definition, a change to that state machine. Splitting focus
   across two plugins reintroduces exactly the desync that the `Current`/`Preview`
   click-reclaim shim already had to paper over (stranded highlight). Focus must
   have **one owner**.

## Non-goals

- Editing the selection from the panel beyond what Yazi already offers (no
  multi-select-within-the-panel, no reordering). `Enter` reveals; that's it.
- A floating/modal presentation. Yazi has no scrollable-list modal primitive;
  the docked panel is the idiomatic form.
- Persisting the panel's scroll position across sessions.
- Showing anything other than the active tab's selection (yanked/cut register is
  out of scope for v1).

## Terminology

- **Staging panel** (or "panel") — the new region.
- **Selection** — the active tab's selected URLs (`cx.active.selected`; exact
  accessor verified against the Yazi Lua API at implementation time — the preset
  Status line already renders this count, so the data is reachable from a sync
  component).
- **Region** — one of the three focusable areas: `sidebar`, `panes`, `staging`.

### Selection is per-tab (not global)

Confirmed against Yazi's data model (`yazi_actor::lives::*`): the `<Space>`
**selection** is a per-tab set — there is no global "selected" surface, only the
active tab's (`cx.active.selected`), and the top-right counter reflects that tab's
selection. Switching tabs swaps the selection and therefore the panel's contents.
(The **yank/cut register**, by contrast, *is* global — `cx.yanked` — which is why
paste crosses tabs; that register is out of scope for v1, see Non-goals.) The
panel is thus inherently **tab-scoped**: it always mirrors the active tab, and
re-renders on tab switch like every other tab-scoped component.

## Architecture overview

Three changes, all inside `main.lua`:

1. **`Tab:layout()`** (already overridden) also splits the **preview** chunk
   vertically into `preview` (top) and `staging` (bottom). Preview's area shrinks,
   so image/video previewers fit the smaller region with no extra work.
2. **Focus state** goes tri-state: `S.focus ∈ { "list", "sidebar", "staging" }`
   (`"list"` = the file panes, keeping the existing name to minimise churn). The
   `nav()` sync bridge learns the third region.
3. **Rendering + mouse**: a new render path draws the panel (list + divider +
   scrollbar) into the `staging` area; `Preview:scroll` / `Preview:click` gain
   coordinate-gating so wheel/click events over the panel area drive the panel.

Pure, testable logic lands in `core.*` (headless `tests/core_spec.lua`),
reusing `core.window`, `core.step`, `core.abbrev`, `core.truncate`.

## Layout & sizing

### Splitting the preview chunk

In `Tab:layout()`, after the existing 3-column horizontal split, take the
preview chunk (`self._chunks[3]`) and split it **vertically**:

```
preview chunk (height H)
├── preview   : H - panel_h   (top, fed to the stock Preview component)
└── staging   : panel_h       (bottom, the panel)  — only when selection > 0
```

When the selection is empty the panel is **absent** — no split, preview is
full-height, exactly as today (zero visual cost).

### Panel height (content-wrapped, capped)

```
cap        = floor(H * 0.5)                 -- never more than half the preview
content_h  = number_of_selected_files       -- 1 line per file
divider    = 1                              -- the separator row (see below)
panel_h    = min(divider + content_h, cap)
visible_h  = panel_h - divider              -- rows available for the list
```

- 1 file → `divider + 1` = 2 rows total (1 divider, 1 file). 3 files → 4 rows.
- Growth stops at `cap`; beyond it the list **scrolls** within `visible_h`.
- **New pure function** `core.panel_height(count, H)` returns `panel_h` (and/or
  `visible_h`); unit-tested for count 0 (hidden), 1, at-cap, and over-cap.

### Divider

A single separator row at the top of the panel, drawn in the sidebar's
`separator` color using the same `━` rule idiom as the sidebar section rules —
visually consistent with the rest of nice-sidebar. It is chrome, not counted as
content. (Confirmed pick: keep the divider.)

## Rendering

The panel renders as a `ui.List` of lines into the `staging` area, mirroring
`Parent:redraw`'s structure:

- **Divider row**: `━` rule + a compact count/label, e.g. `── 3 staged ────`.
- **File rows**: `<type-glyph> <path>` where `path` is **relative to the current
  cwd** when the file lives under it, else `~`-abbreviated via `core.abbrev`.
  Truncated with `core.truncate` to the panel width; the type glyph uses Yazi's
  icon theme if readily available from the `Url`/`File`, else a generic file/dir
  glyph.
- Rows are shown in **selection order** (insertion order if the API preserves it;
  otherwise path-sorted for stability — decided at implementation once the
  accessor's ordering is known, and documented in code).
- The **focused cursor row** (when `S.focus == "staging"`) draws with the same
  `sel_pill(focused)` treatment the sidebar uses, so focus feedback is identical
  across regions.

A `S.panel_viewport` table (visible line → selection index) is written on redraw
and read by the panel's click/scroll handlers, exactly like `S.viewport` for the
sidebar.

## Scrolling

- **Visible window**: reuse `core.window(total, visible_h, cursor)` to compute
  the first/last visible selection rows, with the same `⋮` clipped-edge markers
  the sidebar already renders. Keyboard `j`/`k` (when focused) move the cursor and
  the window follows.
- **Scrollbar**: when `total > visible_h`, draw a thin thumb on the panel's right
  edge (track height `visible_h`, thumb size/position from `first`/`total`). A
  **new pure function** `core.scrollbar(total, visible_h, first)` returns the
  thumb's `{ y, len }`; unit-tested.
- **Mouse wheel**: wrap `Preview:scroll(event)` — if the event's `y` is within the
  `staging` area, scroll the panel window (and clamp with `core.step`); otherwise
  call the original `Preview:scroll` (stock preview seek). Same coordinate-gating
  the click-reclaim shim uses. Wheel scroll does **not** require the panel to be
  focused (it's a pointer gesture); keyboard scroll does.

## Focus model

### Regions, left to right

```
sidebar  ┃  panes  ┃  staging
```

`S.focus` values: `"sidebar"`, `"list"` (= panes), `"staging"`.

### The Shift horizontal slider

Shift moves focus one region at a time across the app. This generalises today's
`H`=focus-sidebar / `L`=focus-panes into a 3-position slider, reusing the **same
bindings** (`H`/`<S-Left>` and `L`/`<S-Right>` — capitals are already Shift):

| Key                     | sidebar        | panes                          | staging        |
|-------------------------|----------------|--------------------------------|----------------|
| `H` / `<S-Left>` (left) | — (stay)       | → sidebar                      | → panes        |
| `L` / `<S-Right>` (right)| → panes       | → staging *if selection*, else **`bypass`** fallthrough | — (stay) |

**Bypass preservation** — the crucial backward-compat detail: `L`/`<S-Right>`
from the panes focuses the staging panel **only when a selection exists** (panel
visible). With nothing staged, it falls through to the stock `bypass` behaviour it
has today (`plugin nice-sidebar blur plugin bypass`). So users lose no muscle
memory when the staging area is empty.

`<Esc>` (mgr mode) returns focus to the panes from either sidebar or staging — a
convenience escape hatch. (New binding; `<Esc>` is currently only bound in input
mode.)

### In-panel keys (while `S.focus == "staging"`)

Routed through the existing `plugin nice-sidebar <cmd>` dispatch, focus-scoped:

- `j` / `k` / `<Down>` / `<Up>` → move the cursor within the list (window
  follows). Guarded: they never reach stock cursor movement.
- `<Enter>` → **reveal** the cursor's file: `cd` to its parent directory and
  hover it (Yazi `reveal`). Focus moves to the panes (you've navigated).
- `h` / `<Left>` → leave to the panes (equivalent to Shift+H one step).
- `G` / `gg` and other list-nav keys → `guard`-swallowed, exactly as under
  sidebar focus.

### Invariants (parity with the sidebar)

1. **No selection ⇒ no staging focus.** If the selection empties (all
   deselected) while `S.focus == "staging"`, focus falls back to `"list"` and the
   panel disappears — the mirror of the sidebar's "no selection, no focus" rule.
2. **Focus is exclusive.** At most one region is focused. Entering `staging`
   blurs the sidebar; entering the sidebar or panes blurs staging.
3. **cd independence.** Navigating (`cd`) does not by itself blur the staging
   panel — the selection (and thus the panel) persists across directories, so its
   focus may too. `on_cd` only touches staging focus via invariant #1 (if a cd
   somehow empties the selection).

### Mouse

- Clicking a panel row focuses `staging` and moves the cursor to that row;
  clicking the divider focuses `staging` without moving the cursor.
- Clicking the panes/preview or the sidebar blurs `staging` (the reclaim shim,
  now internal to nice-sidebar, learns the third target: it blurs *both* the
  sidebar and staging as appropriate).
- Wheel over the panel scrolls it regardless of focus (see Scrolling).

## Config API additions

`setup(opts)` gains (all optional, backward-compatible):

```lua
require("nice-sidebar"):setup {
  -- ... existing options ...
  staging = {
    enabled   = true,   -- default true; false disables the panel entirely
    max_ratio = 0.5,    -- fraction of preview height the panel may occupy (cap)
    reveal_on_enter = true, -- <Enter> in the panel reveals the file (default true)
  },
  colors = {
    -- reuses the existing sidebar palette; optional staging-specific overrides:
    staging_title = nil,      -- falls back to colors.title
    staging_sel_bg = nil,     -- falls back to selected_bg / reversed
    staging_sel_fg = nil,
    -- divider reuses colors.separator
  },
}
```

Defaults keep the panel on with a half-height cap and Enter-reveals, matching the
approved design. Everything degrades to today's behaviour if `staging.enabled =
false`.

## Consumer integration (author's chezmoi repo — follow-up, small)

Lands in `home/dot_config/yazi/` (the Yazi silo), captured after the plugin
release:

1. **`keymap.toml`** — repoint `L`/`<S-Right>` and confirm `H`/`<S-Left>` to the
   slider semantics (the plugin interprets them; the keymap rows may be unchanged
   if the existing `focus`/`blur` command names are kept and their behaviour is
   extended plugin-side). Add `<Esc> → plugin nice-sidebar blur-to-panes` in
   `[mgr]`. Add the in-panel bindings only if new command names are introduced.
2. **`init.lua`** — pass `staging = { ... }` opts if non-default; the existing
   `reclaim_focus` shim for `Current`/`Preview` moves *into* the plugin (it now
   needs to know about three regions), so the chezmoi-side shim can be removed.
3. **`package.toml`** — `ya pkg upgrade` bumps the `Townk/nice-sidebar` `rev` +
   `hash`. Per the repo's convention, this lockfile bump is **captured and
   committed inline** in the same change, right after the upgrade.

## Pure-logic functions & test plan

New `core.*` (headless-testable, no Yazi APIs), added to `tests/core_spec.lua`:

- `core.panel_height(count, preview_h, max_ratio)` → `panel_h, visible_h`.
  Cases: `count = 0` (hidden → 0), `count = 1`, count below cap, count exactly at
  cap, count over cap (clamps, `visible_h` stays `cap - divider`).
- `core.scrollbar(total, visible_h, first)` → `{ y, len }` or `nil` when no
  overflow. Cases: no overflow (nil), top, middle, bottom; thumb never exceeds
  the track, never zero-length when overflowing.
- Reused (already tested): `core.window`, `core.step` (cursor/scroll clamp),
  `core.abbrev` (path display), `core.truncate` (width fit).

Manual validation (Yazi is a TUI; behaviour verified live):

- Select files across several directories; panel lists all, count matches
  Yazi's top-right counter.
- Panel grows 1 line per file; stops at half preview height; scrollbar appears;
  wheel scrolls; `⋮` markers at clipped edges.
- `Shift+L` from panes with a selection focuses the panel; with no selection
  runs `bypass`. `Shift+H` walks staging → panes → sidebar. `Esc` → panes.
- `j`/`k` move the cursor while focused; `<Enter>` reveals the file and lands
  focus on the panes. Deselecting the last file hides the panel and drops focus
  to the panes.
- Image/video preview still renders correctly in the shrunken preview area
  (no graphics corruption from the split).
- `staging.enabled = false` → byte-for-byte today's behaviour.

## Error handling

The whole panel path is wrapped like the existing `setup` `pcall`: any failure
degrades to stock preview (full-height, no panel) rather than breaking Yazi.
A missing/odd `cx.active.selected` accessor yields an empty panel (hidden), never
an error.

## Risks & open questions

- **Selection accessor & ordering** — `cx.active.selected` shape/ordering is
  verified at implementation; ordering choice (insertion vs. path-sorted)
  documented in code. Low risk (the count is already rendered by the preset).
- **Preview-area shrink vs. graphics previews** — kitty/überzug compute their
  region from the preview rect; shrinking it should just fit the smaller area,
  but this is the top manual-validation item.
- **`Preview:scroll`/`click` wrapping order** — must compose with, not replace,
  stock behaviour; gated purely by cursor `y` within the `staging` rect.

## Deferred

- Yanked/cut register view (a second panel or a mode toggle).
- Removing an item from the selection directly in the panel (e.g. a key to
  deselect the cursor row).
- Linux/non-macOS parity is inherited from the base plugin; nothing panel-specific
  is macOS-only.
