# Selection Staging Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a live, tab-scoped list of `<Space>`-selected files docked at the bottom of Yazi's preview column, as a third keyboard-focus region in nice-sidebar's focus model.

**Architecture:** Extend nice-sidebar's existing component overrides. Pure sizing/scroll math lands in the headlessly-tested `core.*` table. A new `Staging` component (added in an overridden `Tab:build`) claims the bottom slice of the preview chunk — `Preview._area` shrinks so the previewer draws above it — and renders the list + a hand-drawn scrollbar. `S.focus` becomes tri-state (`list`/`sidebar`/`staging`) and the `nav()` sync bridge gains a horizontal Shift-slider (`left`/`right`) plus in-panel `j`/`k`/`Enter`.

**Tech Stack:** Lua (Yazi 26.5+ plugin API: `Tab`/`Preview` component overrides, `ui.*` widgets, `ya.sync`, `ps.sub`). Headless tests via `nvim -l tests/run.lua`.

## Global Constraints

- **Target:** Yazi 26.5.6+ (`Tab:layout`/`Tab:build`, `rt.mgr`, `cx.active.selected`, `ui.Bar`/`ui.Edge`). Copied from spec.
- **Selection is per-tab:** always read the active tab (`cx.active.selected`); the panel re-renders on tab switch. Never assume a global selection.
- **Degrade, never break:** every Yazi-API touch stays inside the `setup` `pcall`; a failure drops to stock full-height preview with no panel. `staging.enabled = false` ⇒ byte-for-byte today's behaviour.
- **Keymap args are positional** (`plugin nice-sidebar left`) — `--args=` forms are silently dropped in 26.5.
- **No AI-attribution trailers** in commits (author owns the repo).
- **Pure logic → `core.*` + `tests/core_spec.lua`.** Integration (render/focus/mouse) has no headless harness in this repo — it is validated live in Yazi, mirroring how the base plugin was validated.
- **Style:** run `stylua` (repo has `stylua.toml`) before each integration commit.

---

## File Structure

- **Modify** `main.lua` — all plugin logic (core functions, state, component overrides, nav bridge, setup). Single-file plugin by design; follow its existing section banners (`--- core --`, `--- state --`, etc.).
- **Modify** `tests/core_spec.lua` — add `panel_height`, `scrollbar`, `rel` cases.
- **Modify** `README.md` — document the staging panel + the Shift-slider keymap (folded into Task 8).
- **Consumer (separate repo `~/.local/share/chezmoi`, Task 8):** `home/dot_config/yazi/keymap.toml`, `home/dot_config/yazi/init.lua`, `home/dot_config/yazi/package.toml`.

---

## Task 1: `core.panel_height`

**Files:**
- Modify: `main.lua` (add to the `core` table, near `core.window`)
- Test: `tests/core_spec.lua`

**Interfaces:**
- Produces: `core.panel_height(count, preview_h, max_ratio) -> panel_h, visible_h`
  - `count`: number of selected files. `preview_h`: height (rows) of the preview chunk. `max_ratio`: cap fraction (e.g. `0.5`).
  - Returns `panel_h` (total panel rows incl. the 1-row divider) and `visible_h` (rows available for the list = `panel_h - 1`). Returns `0, 0` when the panel must be hidden.

- [ ] **Step 1: Write the failing tests**

Add to `tests/core_spec.lua` after the `window` block:

```lua
-- panel_height --------------------------------------------------------------
t("panel_height: no selection hides the panel", function()
	local p, v = core.panel_height(0, 20, 0.5)
	eq({ p, v }, { 0, 0 })
end)
t("panel_height: one file is divider + one line", function()
	local p, v = core.panel_height(1, 20, 0.5)
	eq({ p, v }, { 2, 1 })
end)
t("panel_height: grows one line per file below the cap", function()
	local p, v = core.panel_height(3, 20, 0.5)
	eq({ p, v }, { 4, 3 })
end)
t("panel_height: caps at floor(preview_h * ratio)", function()
	local p, v = core.panel_height(100, 20, 0.5)
	eq({ p, v }, { 10, 9 })
end)
t("panel_height: a tiny preview hides the panel", function()
	local p, v = core.panel_height(5, 1, 0.5)
	eq({ p, v }, { 0, 0 })
end)
t("panel_height: nil ratio defaults to one half", function()
	local p, v = core.panel_height(100, 20)
	eq({ p, v }, { 10, 9 })
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/Projects/apps/yazi/nice-sidebar.yazi && nvim -l tests/run.lua`
Expected: FAIL lines for the six `panel_height:` tests (`attempt to call a nil value (field 'panel_height')`).

- [ ] **Step 3: Implement**

Add to `main.lua` in the `core` block (immediately after `core.window`):

```lua
-- Staging-panel height: content grows one line per selected file atop a
-- single divider row, capped at floor(preview_h * ratio). Returns the total
-- panel height (incl. divider) and the visible list height. count 0 or a
-- preview too short to hold a divider + one line hides the panel (0, 0).
function core.panel_height(count, preview_h, max_ratio)
	if count <= 0 or preview_h < 2 then
		return 0, 0
	end
	local cap = math.max(2, math.floor(preview_h * (max_ratio or 0.5)))
	local panel = math.min(1 + count, cap)
	return panel, panel - 1
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nvim -l tests/run.lua`
Expected: PASS; final line shows the new count, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add main.lua tests/core_spec.lua
git commit -m "feat(core): panel_height — content-wrapped staging height with cap"
```

---

## Task 2: `core.scrollbar`

**Files:**
- Modify: `main.lua` (`core` table)
- Test: `tests/core_spec.lua`

**Interfaces:**
- Produces: `core.scrollbar(total, track_h, first) -> { y = <int>, len = <int> } | nil`
  - `total`: item count. `track_h`: rows available for the list (= `visible_h`). `first`: 1-based index of the first visible item.
  - Returns the thumb's 0-based `y` offset into the track and its `len` (rows), or `nil` when everything fits (`total <= track_h`). Thumb length ≥ 1, never exceeds the track; `y` clamped to `[0, track_h - len]`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/core_spec.lua`:

```lua
-- scrollbar -----------------------------------------------------------------
t("scrollbar: everything fits yields nil", function()
	eq(core.scrollbar(5, 10, 1), nil)
	eq(core.scrollbar(10, 10, 1), nil)
end)
t("scrollbar: top of a long list sits at the top", function()
	local s = core.scrollbar(100, 10, 1)
	eq(s.y, 0)
end)
t("scrollbar: bottom of a long list sits at the track end", function()
	local s = core.scrollbar(100, 10, 91) -- first = total - track_h + 1
	eq(s.y, 10 - s.len)
end)
t("scrollbar: thumb is at least one row and fits the track", function()
	local s = core.scrollbar(1000, 4, 1)
	eq(s.len >= 1 and s.len <= 4, true)
end)
t("scrollbar: the middle sits between the ends", function()
	local s = core.scrollbar(100, 10, 46)
	eq(s.y > 0 and s.y < 10 - s.len, true)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nvim -l tests/run.lua`
Expected: FAIL for the five `scrollbar:` tests (`field 'scrollbar'` is nil).

- [ ] **Step 3: Implement**

Add to `main.lua` in the `core` block (after `core.panel_height`):

```lua
-- Scrollbar thumb over a track of `track_h` rows for `total` items, the
-- visible window starting at `first` (1-based). Returns { y, len } as 0-based
-- offsets into the track, or nil when everything fits. Thumb length is
-- proportional (min 1), y clamped so the thumb never leaves the track.
function core.scrollbar(total, track_h, first)
	if track_h <= 0 or total <= track_h then
		return nil
	end
	local len = math.max(1, math.floor(track_h * track_h / total + 0.5))
	len = math.min(len, track_h)
	local max_y = track_h - len
	local denom = math.max(1, total - track_h)
	local y = math.floor(((first or 1) - 1) * max_y / denom + 0.5)
	y = math.max(0, math.min(max_y, y))
	return { y = y, len = len }
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nvim -l tests/run.lua`
Expected: PASS, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add main.lua tests/core_spec.lua
git commit -m "feat(core): scrollbar — proportional thumb geometry"
```

---

## Task 3: `core.rel`

**Files:**
- Modify: `main.lua` (`core` table)
- Test: `tests/core_spec.lua`

**Interfaces:**
- Produces: `core.rel(path, cwd, home) -> string`
  - Path relative to `cwd` (no leading `./`) when `path` is strictly under `cwd`; otherwise `core.abbrev(path, home)`. `cwd` has no trailing slash.

- [ ] **Step 1: Write the failing tests**

Add to `tests/core_spec.lua`:

```lua
-- rel -----------------------------------------------------------------------
t("rel: a child of cwd is shown relative", function()
	eq(core.rel("/Users/u/proj/a.txt", "/Users/u/proj", "/Users/u"), "a.txt")
end)
t("rel: a deeper descendant keeps its subpath", function()
	eq(core.rel("/Users/u/proj/src/a.txt", "/Users/u/proj", "/Users/u"), "src/a.txt")
end)
t("rel: outside cwd falls back to tilde-abbrev", function()
	eq(core.rel("/Users/u/other/a.txt", "/Users/u/proj", "/Users/u"), "~/other/a.txt")
end)
t("rel: outside home stays absolute", function()
	eq(core.rel("/Volumes/X/a.txt", "/Users/u/proj", "/Users/u"), "/Volumes/X/a.txt")
end)
t("rel: sibling prefix is not treated as a child", function()
	eq(core.rel("/Users/u/project2/a", "/Users/u/proj", "/Users/u"), "~/project2/a")
end)
t("rel: under root cwd drops the leading slash", function()
	eq(core.rel("/etc/hosts", "/", "/Users/u"), "etc/hosts")
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nvim -l tests/run.lua`
Expected: FAIL for the six `rel:` tests.

- [ ] **Step 3: Implement**

Add to `main.lua` in the `core` block (after `core.abbrev`, since it delegates there):

```lua
-- Display path for a staging row: relative to cwd when path is strictly
-- under it, else "~"-abbreviated. cwd carries no trailing slash.
function core.rel(path, cwd, home)
	if cwd == "/" then
		if path:sub(1, 1) == "/" then
			return path:sub(2)
		end
	elseif cwd and path:sub(1, #cwd + 1) == cwd .. "/" then
		return path:sub(#cwd + 2)
	end
	return core.abbrev(path, home)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nvim -l tests/run.lua`
Expected: PASS, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add main.lua tests/core_spec.lua
git commit -m "feat(core): rel — cwd-relative else tilde-abbreviated row path"
```

---

## Task 4: Staging config, selection reader, focus scaffolding

**Files:**
- Modify: `main.lua` (state block, `merge_cfg`, new sync helpers)

**Interfaces:**
- Consumes: `core.panel_height`, `core.rel`.
- Produces (module-internal, used by later tasks):
  - `S.stg` fields: `S.stg.cfg` (`{ enabled, max_ratio, reveal_on_enter, icon }`), `S.stg.sel` (cursor index, `nil`), `S.stg.first` (int, default 1), `S.stg.area` (Rect|nil), `S.stg.vp` (table: visible line → selection index).
  - `S.focus` now takes the value `"staging"` in addition to `"list"`/`"sidebar"`.
  - `local function selection()` → array of selected path strings (active tab, insertion order).
  - `local function sel_count()` → `#cx.active.selected`.
  - `local function stg_visible()` → boolean: panel is shown right now (enabled AND `sel_count() > 0`).

- [ ] **Step 1: Extend `S` and `DEFAULTS`, add config merge**

In `main.lua`, extend the `S` table (add fields; keep existing):

```lua
	focus = "list", -- "list" | "sidebar" | "staging"
	-- ... existing fields ...
	stg = { cfg = nil, sel = nil, first = 1, area = nil, vp = {} },
```

In `merge_cfg`, before `return cfg`, add:

```lua
	local st = opts.staging or {}
	cfg.staging = {
		enabled = st.enabled ~= false,
		max_ratio = st.max_ratio or 0.5,
		reveal_on_enter = st.reveal_on_enter ~= false,
		icon = st.icon or "󰄲",
	}
```

- [ ] **Step 2: Store staging cfg in `setup`**

In `M:setup`, right after `S.cfg = merge_cfg(opts)`:

```lua
	S.stg.cfg = S.cfg.staging
```

- [ ] **Step 3: Add the selection readers (sync context)**

Add these near the other `ya.sync`-free helpers (above `select_item`), so they run in the sync VM at redraw/nav time:

```lua
-- The active tab's selected paths, insertion order (Yazi's selection is a
-- per-tab ordered set). Runs in the sync VM (redraw / nav).
local function selection()
	local out = {}
	for _, url in pairs(cx.active.selected) do
		out[#out + 1] = tostring(url)
	end
	return out
end

local function sel_count()
	return #cx.active.selected
end

local function stg_visible()
	return S.stg.cfg and S.stg.cfg.enabled and sel_count() > 0
end
```

- [ ] **Step 4: Verify main.lua still loads and core tests pass**

Run: `nvim -l tests/run.lua`
Expected: PASS, `0 failed` (the sync helpers reference `cx`, but they are not *called* by the core tests, so loading `main.lua` under the stub still succeeds).

- [ ] **Step 5: Run stylua and commit**

```bash
stylua main.lua
git add main.lua
git commit -m "feat: staging config + selection readers + tri-state focus scaffolding"
```

---

## Task 5: Layout carve, `Staging` component, rendering

**Files:**
- Modify: `main.lua` (inside `M:setup`'s `pcall`, after the existing `Parent:*` overrides; add the `Staging` component and a render helper)

**Interfaces:**
- Consumes: `selection`, `sel_count`, `stg_visible`, `core.panel_height`, `core.window`, `core.scrollbar`, `core.rel`, `core.truncate`, `sel_pill`, `style`, `pill_caps`.
- Produces:
  - Global `Staging` component (`_id = "staging"`) with `:new/:reflow/:redraw/:click/:scroll/:touch`.
  - Overridden `Tab:build` that shrinks `Preview._area` and appends `Staging` over the freed bottom slice; sets `S.stg.area`.
  - `render_staging(area) -> { <ui elements> }` (local); writes `S.stg.vp` and `S.stg.first`.
  - **Live-verification points (validate in Step 4):** (a) mouse events over the staging area reach `Staging:click`/`:scroll`; (b) the previewer honours the shrunk `Preview._area` (image/video previews fit above the panel).

- [ ] **Step 1: Override `Tab:build` to carve the panel**

Inside the `pcall` in `M:setup`, **after** the existing `function Tab:layout()` override, add:

```lua
		-- Carve the staging panel out of the bottom of the preview child.
		-- Preview is children[3] in the preset build order (Parent, Current,
		-- Preview, Rails, Markers). Shrinking Preview._area shrinks both the
		-- drawn preview (LAYOUT.preview) and its mouse hit-test rect; the
		-- Staging child then owns the freed bottom slice.
		local orig_build = Tab.build
		function Tab:build()
			orig_build(self)
			S.stg.area = nil
			if not stg_visible() then
				return
			end
			local prev = self._children[3]
			if not prev or prev._id ~= "preview" then
				return -- preset drift: bail rather than mis-carve
			end
			local a = prev._area
			local panel_h = select(1, core.panel_height(sel_count(), a.h, S.stg.cfg.max_ratio))
			if panel_h <= 0 then
				return
			end
			local top = ui.Rect({ x = a.x, y = a.y, w = a.w, h = a.h - panel_h })
			local bot = ui.Rect({ x = a.x, y = a.y + a.h - panel_h, w = a.w, h = panel_h })
			prev._area = top
			S.stg.area = bot
			self._children[#self._children + 1] = Staging:new(bot, self._tab)
		end
```

- [ ] **Step 2: Add the render helper**

Add above the `function M:setup` line (module scope, so it closes over `core`/`ui`/`S`):

```lua
-- Render the staging panel into `area`: a divider row, then the visible slice
-- of the selection with a focused cursor pill, plus a right-edge scrollbar when
-- the list overflows. Writes S.stg.vp (visible line ->
-- selection index) and S.stg.first for click/scroll hit-testing.
local function render_staging(area)
	local w, h = area.w, area.h
	if w == 0 or h < 2 then
		S.stg.vp = {}
		return {}
	end
	local c = S.cfg.colors
	local sel = selection()
	local total = #sel
	local visible_h = h - 1 -- row 1 is the divider
	local focused = S.focus == "staging"

	local first, last = core.window(total, visible_h, focused and S.stg.sel or S.stg.first)
	S.stg.first = first

	local lines, vp = {}, {}
	-- Divider row with a compact count label.
	local label = " " .. tostring(total) .. " staged "
	local fill = math.max(0, w - ui.Line({ ui.Span(label) }):width() - 1)
	lines[1] = ui.Line({
		ui.Span("─" .. label):style(style(c.separator or "darkgray")),
		ui.Span(string.rep("─", fill)):style(style(c.separator or "darkgray")),
	})
	vp[1] = nil -- divider is not selectable

	local cwd = tostring(cx.active.current.cwd)
	local home = S.cfg.home
	local line_i = 1
	for i = first, last do
		line_i = line_i + 1
		local path = sel[i]
		local shown = core.rel(path, cwd, home)
		local text = S.stg.cfg.icon .. " " .. shown
		local ln
		if focused and i == S.stg.sel then
			local body, cap = sel_pill(true)
			if cap then
				local open, close = pill_caps()
				local label2 = core.truncate(text, math.max(1, w - 4))
				local pad = math.max(0, w - 4 - ui.Line({ ui.Span(label2) }):width())
				ln = ui.Line({
					ui.Span(" "),
					ui.Span(open):style(cap),
					ui.Span(label2 .. string.rep(" ", pad)):style(body),
					ui.Span(close):style(cap),
				})
				ln:truncate({ max = w })
			else
				ln = ui.Line({ ui.Span("  " .. core.truncate(text, math.max(1, w - 3))):style(body) })
			end
		else
			ln = ui.Line({ ui.Span("  " .. core.truncate(text, math.max(1, w - 3))):style(style(c.item)) })
		end
		lines[line_i] = ln
		vp[line_i] = i
	end
	S.stg.vp = vp

	local out = { ui.List(lines):area(area) }

	-- Right-edge scrollbar thumb over the list track (below the divider).
	local bar = core.scrollbar(total, visible_h, first)
	if bar then
		local track = ui.Rect({ x = area.x + w - 1, y = area.y + 1 + bar.y, w = 1, h = bar.len })
		out[#out + 1] = ui.Bar(ui.Edge.RIGHT):area(track):symbol("█"):style(style(c.separator or "darkgray"))
	end
	return out
end
```

- [ ] **Step 3: Define the `Staging` component**

Add just below `render_staging` (still module scope, above `M:setup`):

```lua
-- Staging component: a first-class child so Yazi hit-tests mouse over its
-- area. Rendering and event bodies live in module-scope helpers.
Staging = { _id = "staging" }
function Staging:new(area, tab)
	return setmetatable({ _area = area, _tab = tab }, { __index = self })
end
function Staging:reflow()
	return { self }
end
function Staging:redraw()
	return render_staging(self._area)
end
function Staging:touch(event, step) end
-- click/scroll bodies are added in Task 7.
function Staging:click(event, up) end
function Staging:scroll(event, step) end
```

- [ ] **Step 4: Live validation in Yazi**

This path has no headless harness — validate against the installed dev build. Point Yazi at the working copy and open it:

```bash
# From the repo: verify it loads and the core suite is still green.
nvim -l tests/run.lua   # expect 0 failed
stylua --check main.lua
```

Then, in a real Yazi that loads this `main.lua` (symlink or `ya pkg` local install), confirm by eye:
- Select 1 file (`<Space>`) → a 2-row panel (divider + 1 line) appears at the **bottom of the preview column**; the preview above shrinks.
- Select more → panel grows one row per file; stops at half the preview height; the `█` scrollbar thumb appears and tracks position when clipped.
- Hover an **image/video** with a selection active → the preview still renders correctly in the shrunken area (no graphics corruption). *(Live-verification point (b).)*
- Deselect all → panel vanishes, preview returns to full height.

Record the result. If the previewer ignores the shrunk area (point b fails), fall back plan: keep `Preview._area` full and instead reduce `ya.preview.max_height` — note it and stop for guidance.

- [ ] **Step 5: Run stylua and commit**

```bash
stylua main.lua
git add main.lua
git commit -m "feat: staging panel layout carve, Staging component, rendering"
```

---

## Task 6: Tri-state focus — the Shift slider, in-panel keys

**Files:**
- Modify: `main.lua` (`nav` sync bridge; add `stg_focus`/`stg_blur`/`stg_move` helpers near `focus_sidebar`/`blur_sidebar`)

**Interfaces:**
- Consumes: `stg_visible`, `sel_count`, `selection`, `focus_sidebar`, `blur_sidebar`, `swap_cursor`, `core.step`.
- Produces new `nav` acts, called from the keymap (Task 8):
  - `left` — move focus one region left: `staging → panes → sidebar` (sidebar stays).
  - `right` — one region right: `sidebar → panes → staging` *(if `stg_visible()`)*; from panes with nothing staged, run the fallthrough (`rest`) command (`bypass`).
  - `j`/`k` — when `S.focus == "staging"`, move the panel cursor (else existing behaviour).
  - `enter` — when `S.focus == "staging"` and `reveal_on_enter`, `reveal` the cursor file and blur to panes (else existing behaviour).
  - `guard`/`h` — also swallow while `S.focus == "staging"`.
- Invariant enforced everywhere: empty selection ⇒ never `staging` focus.

- [ ] **Step 1: Add staging focus/motion helpers**

In `main.lua`, after `blur_sidebar`, add:

```lua
-- Focus the staging panel: only possible while it is visible (enabled + a
-- non-empty selection). Blurs the sidebar first (focus is exclusive) and seeds
-- the cursor at the top.
local function stg_focus()
	if S.focus == "staging" or not stg_visible() then
		return
	end
	if S.focus == "sidebar" then
		blur_sidebar()
	end
	S.focus = "staging"
	S.stg.sel = 1
	S.stg.first = 1
	ui.render()
end

-- Hand focus from the staging panel back to the file panes.
local function stg_blur()
	if S.focus ~= "staging" then
		return
	end
	S.focus = "list"
	S.stg.sel = nil
	ui.render()
end

-- Move the staging cursor by delta, clamped over the current selection count.
local function stg_move(delta)
	local n = sel_count()
	if n == 0 then
		stg_blur()
		return
	end
	S.stg.sel = core.step(S.stg.sel, delta, n)
	ui.render()
end
```

- [ ] **Step 2: Teach `nav()` the slider and in-panel keys**

In the `nav = ya.sync(function(_, act, rest)` body, make these edits.

Replace the `j`/`k` branch:

```lua
		elseif act == "j" or act == "k" then
			local delta = act == "j" and 1 or -1
			if S.focus == "sidebar" then
				move(delta)
			elseif S.focus == "staging" then
				stg_move(delta)
			else
				ya.emit("arrow", { delta })
			end
```

Replace the `enter` branch's body to handle staging first:

```lua
		elseif act == "enter" then
			if S.focus == "staging" then
				if S.stg.cfg.reveal_on_enter and S.stg.sel then
					local sel = selection()
					if sel[S.stg.sel] then
						ya.emit("reveal", { sel[S.stg.sel] })
					end
				end
				stg_blur()
			elseif S.focus == "sidebar" then
				select_item(S.selected)
				blur_sidebar()
			elseif rest and rest[1] then
				ya.emit(rest[1], { table.unpack(rest, 2) })
			end
```

Extend the `guard` branch so staging also swallows:

```lua
		elseif act == "guard" then
			if S.focus == "list" and rest and rest[1] then
				ya.emit(rest[1], { table.unpack(rest, 2) })
			end
```

Extend the `h` branch so staging leaves to the panes:

```lua
		elseif act == "h" then
			if S.focus == "sidebar" then
				return
			elseif S.focus == "staging" then
				stg_blur()
				return
			end
			if cx.active.parent then
				ya.emit("leave", {})
			else
				focus_sidebar()
			end
```

Add the two new slider acts (place before the closing `end` of the `if` chain, e.g. after the `l` branch):

```lua
		elseif act == "left" then
			-- staging -> panes -> sidebar ; sidebar stays.
			if S.focus == "staging" then
				stg_blur()
			elseif S.focus == "list" then
				focus_sidebar()
			end
		elseif act == "right" then
			-- sidebar -> panes -> staging ; from panes with nothing staged,
			-- run the fallthrough (bypass), preserving today's Shift+L.
			if S.focus == "sidebar" then
				blur_sidebar()
			elseif S.focus == "list" then
				if stg_visible() then
					stg_focus()
				elseif rest and rest[1] then
					ya.emit(rest[1], { table.unpack(rest, 2) })
				end
			end
```

- [ ] **Step 3: Enforce the empty-selection invariant on cd**

In `on_cd`, at the end (after the existing body), add:

```lua
	-- Selection can empty out from a cd (leaving a folder whose files were
	-- selected does not clear them, but a paste/delete might). If it did and
	-- staging held focus, drop back to the panes.
	if S.focus == "staging" and sel_count() == 0 then
		S.focus = "list"
		S.stg.sel = nil
		ui.render()
	end
```

- [ ] **Step 4: Live validation in Yazi**

```bash
nvim -l tests/run.lua   # expect 0 failed (nav is not exercised headlessly)
stylua --check main.lua
```

By eye, with a multi-file selection across two directories:
- `Shift+L` / `Shift+Right` from the panes focuses the panel (cursor pill on row 1); with **no** selection it still runs `bypass`.
- `Shift+H` / `Shift+Left` walks `staging → panes → sidebar`; `Shift+L` walks back.
- While the panel is focused: `j`/`k` move the cursor and the window follows; the scrollbar thumb tracks position.
- `Enter` on a row cds to that file's directory, hovers it, and focus lands on the panes.
- Deselect the last file while focused → panel hides, focus returns to panes.

- [ ] **Step 5: Run stylua and commit**

```bash
stylua main.lua
git add main.lua
git commit -m "feat: tri-state focus — Shift slider, in-panel j/k, Enter-reveals"
```

---

## Task 7: Mouse — panel click/scroll + reclaim into the plugin

**Files:**
- Modify: `main.lua` (`Staging:click`/`Staging:scroll` bodies; add a reclaim wrapper inside `M:setup` for `Current`/`Preview`)

**Interfaces:**
- Consumes: `S.stg.vp`, `stg_focus`, `stg_blur`, `blur_sidebar`, `core.step`, `sel_count`, `selection`.
- Produces: working wheel-scroll and click-to-focus over the panel; clicks elsewhere blur it. The consumer-side `reclaim_focus` shim (chezmoi `init.lua`) is superseded and removed in Task 8.

- [ ] **Step 1: Implement `Staging:click` and `Staging:scroll`**

Replace the stub bodies added in Task 5:

```lua
function Staging:click(event, up)
	if up or event.is_middle then
		return
	end
	stg_focus()
	local line = event.y - self._area.y + 1
	local idx = S.stg.vp[line]
	if idx then
		S.stg.sel = idx
		ui.render()
	end
end

function Staging:scroll(event, step)
	-- Wheel scrolls the list regardless of focus; clamp over the selection.
	local n = sel_count()
	if n == 0 then
		return
	end
	if S.focus == "staging" then
		S.stg.sel = core.step(S.stg.sel, step, n)
	else
		S.stg.first = math.max(1, math.min(n, (S.stg.first or 1) + step))
	end
	ui.render()
end
```

- [ ] **Step 2: Move the reclaim shim into the plugin (three regions)**

Inside `M:setup`'s `pcall`, after the `Staging` component is defined, add a wrapper that blurs **both** the sidebar and the staging panel when the panes/preview are clicked:

```lua
		-- Clicking the center/preview columns hands focus to the panes: run the
		-- stock click, then blur whichever region held focus. Guarded (blur is a
		-- no-op unless that region is focused), so it is inert once the panes own
		-- focus. Supersedes the consumer-side reclaim shim.
		local function reclaim(comp)
			local orig = comp.click
			comp.click = function(self, ev, up)
				if orig then
					orig(self, ev, up)
				end
				if not up and not ev.is_middle then
					if S.focus == "sidebar" then
						blur_sidebar()
					elseif S.focus == "staging" then
						stg_blur()
					end
				end
			end
		end
		reclaim(Current)
		reclaim(Preview)
```

- [ ] **Step 3: Live validation in Yazi**

```bash
nvim -l tests/run.lua && stylua --check main.lua
```

By eye:
- Wheel over the panel scrolls the list (both focused and unfocused). *(Confirms live-verification point (a): mouse reaches the `Staging` component.)*
- Click a panel row → focuses the panel and moves the cursor to that row.
- Click the center or preview → panel (or sidebar) blurs, focus returns to the panes.
- If wheel/click over the panel do **nothing** (custom component not hit-tested), fall back: override `Tab:scroll`/`Tab:click` to dispatch by `S.stg.area` coordinates — note it and stop for guidance.

- [ ] **Step 4: Run stylua and commit**

```bash
stylua main.lua
git add main.lua
git commit -m "feat: staging mouse — wheel scroll, click-to-focus, reclaim on pane click"
```

---

## Task 8: Consumer wiring (chezmoi) + README

**Files:**
- Modify (nice-sidebar repo): `README.md`
- Modify (chezmoi repo `~/.local/share/chezmoi`): `home/dot_config/yazi/keymap.toml`, `home/dot_config/yazi/init.lua`, `home/dot_config/yazi/package.toml`

**Interfaces:**
- Consumes: `nav` acts `left`/`right`, staging `setup` opts.
- Produces: the released plugin wired into the author's Yazi.

- [ ] **Step 1: Document the panel in the plugin README**

Add a "Selection staging panel" section to `README.md` describing: the bottom-of-preview list, the half-height cap + scrollbar, per-tab scoping, the Shift slider (`Shift+H`/`Shift+L` and arrows) across `sidebar | panes | staging`, `j`/`k` + `Enter`-reveals while focused, and the `staging = { enabled, max_ratio, reveal_on_enter, icon }` config block. Commit:

```bash
git add README.md
git commit -m "docs: document the selection staging panel and the Shift slider"
```

- [ ] **Step 2: Merge the feature branch to the plugin's main and tag/release**

```bash
git checkout main
git merge --ff-only feat/selection-staging-panel
git push
```
(Release/tag per the repo's normal convention so `ya pkg upgrade` can pick it up.)

- [ ] **Step 3: Repoint the keymap to the slider (chezmoi)**

In `~/.local/share/chezmoi/home/dot_config/yazi/keymap.toml`, change the four focus rows to the slider acts and add an Esc escape hatch:

```toml
  { on = "H",          run = "plugin nice-sidebar left",  desc = "Focus left: staging → panes → sidebar" },
  { on = "<S-Left>",   run = "plugin nice-sidebar left",  desc = "Focus left" },
  { on = "L",          run = "plugin nice-sidebar right plugin bypass", desc = "Focus right: sidebar → panes → staging; else bypass" },
  { on = "<S-Right>",  run = "plugin nice-sidebar right", desc = "Focus right" },
```

And add to the `[mgr] prepend_keymap` list:

```toml
  { on = "<Esc>", run = "plugin nice-sidebar left", desc = "Step focus back toward the panes" },
```

(`<S-Up>`/`<S-Down>`→`prev`/`next` and the lowercase `h/j/k/l` rows are unchanged — the plugin already interprets them by focus.)

- [ ] **Step 4: Pass staging opts and drop the old shim (chezmoi `init.lua`)**

In `home/dot_config/yazi/init.lua`, in the `require("nice-sidebar"):setup { ... }` call, add a `staging` block if any non-default is wanted (defaults are fine — this is optional):

```lua
			staging = { enabled = true, max_ratio = 0.5, reveal_on_enter = true },
```

Then **delete** the now-superseded `reclaim_focus` block (the `local function reclaim_focus(comp) ... end` plus the `reclaim_focus(Current)` / `reclaim_focus(Preview)` calls) — the plugin now owns three-region reclaim.

- [ ] **Step 5: Bump the ya-pkg lockfile inline**

```bash
cd ~/.local/share/chezmoi
ya pkg upgrade                       # updates the deployed plugin
# capture the new rev+hash into the tracked lockfile:
cp ~/.config/yazi/package.toml home/dot_config/yazi/package.toml
```

- [ ] **Step 6: Apply, validate end-to-end, commit (chezmoi)**

```bash
chezmoi apply ~/.config/yazi
```
In a fresh Yazi: repeat the Task 5–7 eyeball checks with the released plugin — panel appears/caps/scrolls, Shift slider walks all three regions, `Enter` reveals, mouse works, and (regression) the sidebar's own focus/click behaviour is unchanged. Then:

```bash
git add home/dot_config/yazi/keymap.toml home/dot_config/yazi/init.lua home/dot_config/yazi/package.toml
git commit -m "feat(yazi): wire nice-sidebar staging panel — Shift slider + lockfile bump"
```

---

## Self-Review

**Spec coverage:**
- Bottom-of-preview dock, content-wrap, ½ cap → Tasks 1, 5. Scrollbar/overflow → Tasks 2, 5. Mouse wheel + scrollbar → Tasks 2, 7. Tri-state focus + Shift slider + bypass-preservation → Task 6. In-panel `j`/`k` + `Enter`-reveal + guards → Task 6. Divider + count → Task 5. Per-tab scoping → Task 4 (`selection`/`sel_count` read the active tab). Row path (rel/abbrev) → Task 3, 5. Config API → Tasks 4, 8. Invariants (empty ⇒ no focus; exclusive focus; cd-independence) → Tasks 4/6. Mouse reclaim into plugin → Task 7. Chezmoi wiring + `ya pkg` bump → Task 8. Tests → Tasks 1–3; live validation → Tasks 5–8. **No gaps.**

**Placeholder scan:** All code steps carry complete code; no TBD/TODO. The two acknowledged live-verification points (previewer honouring the shrunk area; mouse dispatch to a custom component) are called out with explicit fallbacks, not left silent — appropriate for a TUI feature with no headless render harness.

**Type consistency:** `core.panel_height(count, preview_h, max_ratio) -> panel_h, visible_h`, `core.scrollbar(total, track_h, first) -> {y,len}|nil`, `core.rel(path, cwd, home) -> string`, `S.stg = {cfg, sel, first, area, vp}`, `S.focus ∈ {list,sidebar,staging}`, `Staging._id = "staging"`, nav acts `left`/`right`/`j`/`k`/`enter`/`guard`/`h` — names used consistently across Tasks 4–8. `Preview` is `self._children[3]` (from the verbatim preset build order). Consistent.
