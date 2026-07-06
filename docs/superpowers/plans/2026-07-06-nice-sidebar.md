# nice-sidebar.yazi Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the nice-sidebar.yazi plugin: a Finder-style sticky sidebar in Yazi's parent column, per the approved spec at `docs/superpowers/specs/2026-07-06-nice-sidebar-design.md`.

**Architecture:** Single-file Lua plugin (`main.lua`). A pure-logic `core` table (path math, selection stepping, cd tracking, row model, pin toggling, disk classification, windowing) is unit-tested headlessly; the yazi layer (state table `S` in the sync VM, `Tab:layout` + `Parent:redraw/click/scroll` overrides, `ya.sync` bridges, async `entry` for volume scans and pin writes) consumes it. The techniques are proven by `tm-gate.yazi` (the terminal-time-machine scrub plugin) and yazi's own preset components.

**Tech Stack:** Lua 5.4 (yazi's mlua runtime), yazi 26.5+ plugin API (`ya`, `ui`, `ps`, `fs`, `rt`, `th`, `Command`, `Url`), headless tests via `nvim -l` (LuaJIT-safe code — no `utf8` stdlib), stylua.

## Global Constraints

- Yazi version floor: **26.5** (`Tab:layout` override, `rt.mgr.ratio`, `ui.render`).
- Plugin logic lives in **one file**: `main.lua` (tm-gate style). Tests live in `tests/`.
- The plugin **never rebinds keys itself** — keymap rows are documentation.
- Keymap plugin args are **positional** (`plugin nice-sidebar prev`), never `--args=` (yazi 26.5 drops the old form silently).
- Disks section is **macOS-only** (`ya.target_os() == "macos"`); it auto-hides elsewhere.
- All filesystem/stat/process work happens in the **async context only** (`fs.cha`, `fs.read_dir`, `Command`); the sync redraw path never blocks. Use `output()` on Commands, never `spawn()` (a GC'd Child handle kills the process).
- `ui.render()` repaints from sync code, NOT `ya.render()` (renamed in yazi 26; a nil call inside a sync block fails the whole block).
- Two interaction invariants: **selection = cd** (every selection change emits `cd`), and **a focused sidebar always has a selection** (focus with none selects Home; selection clearing returns focus to the list).
- Commit style: conventional commits (`feat:`, `test:`, `docs:`, `chore:`). **No Co-Authored-By or AI-attribution trailers, ever.**
- Code style: tabs, double quotes, 120 columns (the repo `stylua.toml`; matches yazi presets and the author's existing plugin code).
- Icons are literal Nerd Font glyphs copied exactly from the spec — do not substitute "similar" glyphs.

---

### Task 1: Repo tooling, test harness, and path helpers

**Files:**
- Create: `stylua.toml`
- Create: `.luarc.json`
- Create: `LICENSE`
- Create: `.gitignore`
- Create: `tests/run.lua`
- Create: `tests/core_spec.lua`
- Create: `main.lua`

**Interfaces:**
- Produces: `main.lua` returns table `M` with `M.core`; `core.expand(path, home) -> string`, `core.abbrev(path, home) -> string`, `core.truncate(s, max) -> string`. Test harness globals `t(name, fn)` and `eq(got, want)`; runner exits non-zero on failure.

- [ ] **Step 1: Write the tooling files**

`stylua.toml`:

```toml
indent_type = "Tabs"
indent_width = 2
column_width = 120
line_endings = "Unix"
quote_style = "AutoPreferDouble"
```

`.luarc.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/LuaLS/vscode-lua/master/setting/schema.json",
  "runtime.version": "Lua 5.4",
  "diagnostics.globals": ["ya", "cx", "rt", "ui", "ps", "fs", "th", "Command", "Url", "Parent", "Tab", "Header", "Status"]
}
```

`.gitignore`:

```gitignore
.DS_Store
```

`LICENSE` — MIT, verbatim:

```text
MIT License

Copyright (c) 2026 Thiago Alves

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Write the test runner**

`tests/run.lua` — stubs the yazi globals so `main.lua` loads headlessly, defines `t`/`eq`, loads the spec, exits with a status code. Run **from the repo root** with `nvim -l tests/run.lua` (LuaJIT) or `lua tests/run.lua` (5.4) — the code must work on both, so no `utf8` stdlib anywhere.

```lua
-- Minimal headless test runner. Run from the repo root:
--   nvim -l tests/run.lua      (or: lua tests/run.lua)
-- Stubs just enough of yazi's API for main.lua to load outside yazi.

local failed, passed = 0, 0

local function dump(v)
	if type(v) ~= "table" then
		return tostring(v)
	end
	local parts = {}
	for k, val in pairs(v) do
		parts[#parts + 1] = tostring(k) .. "=" .. dump(val)
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function deep_eq(a, b)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in pairs(a) do
		if not deep_eq(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

function _G.t(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL " .. name .. "\n     " .. tostring(err))
	end
end

function _G.eq(got, want)
	if not deep_eq(got, want) then
		error("expected " .. dump(want) .. ", got " .. dump(got), 2)
	end
end

-- yazi API stubs: ya.sync just returns the function (bridges become plain
-- calls; the tests only exercise M.core, which touches no yazi API).
_G.ya = { sync = function(fn)
	return fn
end }

local root = (arg and arg[0] or "tests/run.lua"):gsub("tests/run%.lua$", "")
local M = dofile(root .. "main.lua")
_G.core = M.core

dofile(root .. "tests/core_spec.lua")

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
```

- [ ] **Step 3: Write the failing tests for the path helpers**

`tests/core_spec.lua`:

```lua
-- Pure-core tests for nice-sidebar.yazi. Loaded by tests/run.lua, which
-- provides the globals t(name, fn), eq(got, want), and core (= M.core).

-- expand -------------------------------------------------------------------
t("expand: bare tilde is home", function()
	eq(core.expand("~", "/Users/u"), "/Users/u")
end)
t("expand: tilde-slash prefixes home", function()
	eq(core.expand("~/Desktop", "/Users/u"), "/Users/u/Desktop")
end)
t("expand: absolute paths pass through", function()
	eq(core.expand("/Volumes/X", "/Users/u"), "/Volumes/X")
end)
t("expand: tilde in the middle is not expanded", function()
	eq(core.expand("/a/~/b", "/Users/u"), "/a/~/b")
end)

-- abbrev -------------------------------------------------------------------
t("abbrev: home becomes tilde", function()
	eq(core.abbrev("/Users/u", "/Users/u"), "~")
end)
t("abbrev: home prefix becomes tilde-slash", function()
	eq(core.abbrev("/Users/u/Projects/x", "/Users/u"), "~/Projects/x")
end)
t("abbrev: sibling of home is untouched", function()
	eq(core.abbrev("/Users/uu/x", "/Users/u"), "/Users/uu/x")
end)
t("abbrev: outside home is untouched", function()
	eq(core.abbrev("/Volumes/X", "/Users/u"), "/Volumes/X")
end)

-- truncate -----------------------------------------------------------------
t("truncate: short strings pass through", function()
	eq(core.truncate("abc", 5), "abc")
end)
t("truncate: exact fit passes through", function()
	eq(core.truncate("abcde", 5), "abcde")
end)
t("truncate: long strings clip with ellipsis", function()
	eq(core.truncate("abcdef", 5), "abcd…")
end)
t("truncate: multibyte characters count as one", function()
	eq(core.truncate("ábçdéf", 5), "ábçd…")
end)
t("truncate: max of one is just the ellipsis", function()
	eq(core.truncate("abc", 1), "…")
end)
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `cd ~/Projects/apps/yazi/nice-sidebar.yazi && nvim -l tests/run.lua`
Expected: FAIL — `main.lua` does not exist yet (dofile error) or every test fails with `attempt to index a nil value (global 'core')`.

- [ ] **Step 5: Write `main.lua` with the core skeleton and the three helpers**

`main.lua`:

```lua
--- @since 26.5.6
-- nice-sidebar.yazi — a Finder-style sticky sidebar in Yazi's parent column.
-- https://github.com/Townk/nice-sidebar.yazi
--
-- The parent column is replaced wholesale: core directories, pinned
-- directories, and mounted disks, with a keyboard focus model borrowed from
-- the terminal-time-machine scrub sessions. See README.md for the keymap
-- rows this plugin expects.

-- ------------------------------------------------------------------ core --
-- Pure logic, no yazi APIs: unit-tested headlessly by tests/run.lua.
local core = {}

-- Expand a leading "~" against `home`.
function core.expand(path, home)
	if path == "~" then
		return home
	end
	local rest = path:match("^~/(.+)$")
	if rest then
		return home .. "/" .. rest
	end
	return path
end

-- Abbreviate `path` with "~" when it is home or lives under it.
function core.abbrev(path, home)
	if path == home then
		return "~"
	end
	if path:sub(1, #home + 1) == home .. "/" then
		return "~" .. path:sub(#home + 1)
	end
	return path
end

-- UTF-8-aware truncation to `max` characters, "…" marks the clip. Manual
-- byte-pattern iteration: the utf8 stdlib is absent under LuaJIT (nvim -l).
function core.truncate(s, max)
	local chars = {}
	for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		chars[#chars + 1] = ch
	end
	if #chars <= max then
		return s
	end
	if max <= 1 then
		return "…"
	end
	return table.concat(chars, "", 1, max - 1) .. "…"
end

local M = { core = core }

return M
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd ~/Projects/apps/yazi/nice-sidebar.yazi && nvim -l tests/run.lua`
Expected: `13 passed, 0 failed`, exit code 0.

- [ ] **Step 7: Commit**

```bash
cd ~/Projects/apps/yazi/nice-sidebar.yazi
git add stylua.toml .luarc.json LICENSE .gitignore tests/ main.lua
git commit -m "feat: repo tooling, headless test harness, core path helpers"
```

---

### Task 2: Selection, umbrella tracking, and windowing core

**Files:**
- Modify: `main.lua` (append to the `core` section, before `local M`)
- Modify: `tests/core_spec.lua` (append)

**Interfaces:**
- Consumes: `core` table from Task 1.
- Produces: `core.step(selected, delta, count) -> index|nil`, `core.inside(path, cwd) -> bool`, `core.track(items, selected, cwd) -> index|nil` (items = array of `{ label, path, icon }`), `core.window(total, h, anchor) -> first, last`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/core_spec.lua`:

```lua
-- step ---------------------------------------------------------------------
t("step: empty list yields nil", function()
	eq(core.step(nil, 1, 0), nil)
end)
t("step: no selection targets the first item, either direction", function()
	eq(core.step(nil, 1, 5), 1)
	eq(core.step(nil, -1, 5), 1)
end)
t("step: moves by delta", function()
	eq(core.step(2, 1, 5), 3)
	eq(core.step(2, -1, 5), 1)
end)
t("step: clamps at both ends", function()
	eq(core.step(1, -1, 5), 1)
	eq(core.step(5, 1, 5), 5)
end)

-- inside -------------------------------------------------------------------
t("inside: equal paths match", function()
	eq(core.inside("/a/b", "/a/b"), true)
end)
t("inside: descendants match", function()
	eq(core.inside("/a/b", "/a/b/c/d"), true)
end)
t("inside: component boundaries are respected", function()
	eq(core.inside("/a/b", "/a/bc"), false)
end)
t("inside: parents do not match", function()
	eq(core.inside("/a/b", "/a"), false)
end)
t("inside: root umbrella holds everything", function()
	eq(core.inside("/", "/anything/at/all"), true)
end)

-- track --------------------------------------------------------------------
local items = {
	{ label = "Home", path = "/Users/u", icon = "h" },
	{ label = "Desktop", path = "/Users/u/Desktop", icon = "d" },
	{ label = "Disk", path = "/Volumes/X", icon = "x" },
}
t("track: exact match wins over an umbrella hold", function()
	eq(core.track(items, 1, "/Users/u/Desktop"), 2)
end)
t("track: exact match adopts even with no selection", function()
	eq(core.track(items, nil, "/Volumes/X"), 3)
end)
t("track: duplicate paths resolve to the first in list order", function()
	local dup = { { path = "/p" }, { path = "/p" } }
	eq(core.track(dup, 2, "/p"), 1)
end)
t("track: umbrella keeps the selection", function()
	eq(core.track(items, 2, "/Users/u/Desktop/stuff"), 2)
end)
t("track: leaving the umbrella clears", function()
	eq(core.track(items, 3, "/private/tmp"), nil)
end)
t("track: no selection and no exact match stays clear", function()
	eq(core.track(items, nil, "/Users/u/Desktop/stuff"), nil)
end)

-- window -------------------------------------------------------------------
t("window: everything fits", function()
	local first, last = core.window(5, 10, 3)
	eq({ first, last }, { 1, 5 })
end)
t("window: centers on the anchor", function()
	local first, last = core.window(20, 5, 10)
	eq({ first, last }, { 8, 12 })
end)
t("window: clamps at the top", function()
	local first, last = core.window(20, 5, 1)
	eq({ first, last }, { 1, 5 })
end)
t("window: clamps at the tail", function()
	local first, last = core.window(20, 5, 20)
	eq({ first, last }, { 16, 20 })
end)
t("window: nil anchor pins to the top", function()
	local first, last = core.window(20, 5, nil)
	eq({ first, last }, { 1, 5 })
end)
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `cd ~/Projects/apps/yazi/nice-sidebar.yazi && nvim -l tests/run.lua`
Expected: 13 passed, 20 failed (every new test errors — the functions don't exist).

- [ ] **Step 3: Implement the four functions**

Insert into `main.lua` after `core.truncate` (still before `local M`):

```lua
-- Selection stepping: clamped at both ends; with nothing selected, either
-- direction targets the first item (Home).
function core.step(selected, delta, count)
	if count == 0 then
		return nil
	end
	if not selected then
		return 1
	end
	return math.max(1, math.min(count, selected + delta))
end

-- Is `cwd` inside the umbrella of `path` — equal to it, or a descendant by
-- whole path components?
function core.inside(path, cwd)
	if path == cwd then
		return true
	end
	if path == "/" then
		return cwd:sub(1, 1) == "/"
	end
	return cwd:sub(1, #path + 1) == path .. "/"
end

-- cd tracking: an exact path match (first in list order) beats keeping the
-- umbrella'd selection, which beats clearing.
function core.track(items, selected, cwd)
	for i, it in ipairs(items) do
		if it.path == cwd then
			return i
		end
	end
	if selected and items[selected] and core.inside(items[selected].path, cwd) then
		return selected
	end
	return nil
end

-- Visible window over `total` rows given `h` rows of height, centered on
-- row `anchor` (nil anchors to the top). Returns first, last inclusive.
function core.window(total, h, anchor)
	if total <= h then
		return 1, total
	end
	local first = math.max(1, (anchor or 1) - math.floor(h / 2))
	if first + h - 1 > total then
		first = total - h + 1
	end
	return first, first + h - 1
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ~/Projects/apps/yazi/nice-sidebar.yazi && nvim -l tests/run.lua`
Expected: `33 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/apps/yazi/nice-sidebar.yazi
git add main.lua tests/core_spec.lua
git commit -m "feat: selection stepping, umbrella tracking, and window math"
```

---

### Task 3: Row model, pin toggling, and disk classification core

**Files:**
- Modify: `main.lua` (append to the `core` section, before `local M`)
- Modify: `tests/core_spec.lua` (append)

**Interfaces:**
- Consumes: `core` from Tasks 1–2.
- Produces: `core.build(sections) -> rows, items` where `sections = { dirs = {...}, pins = {...}, disks = {...} }` (entries `{ label, path, icon }`), `rows` entries are `{ type = "title"|"rule"|"blank"|"header"|"item", inset?, text?, icon?, index? }`, `items` is the ordered selectable list; `core.toggle(lines, path) -> lines`; `core.disk_kind(text) -> "image"|"internal"|"external"`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/core_spec.lua`:

```lua
-- build --------------------------------------------------------------------
local dirs = { { label = "Home", path = "/u", icon = "h" }, { label = "Desk", path = "/u/d", icon = "d" } }
t("build: dirs only — title block, no sections", function()
	local rows, its = core.build({ dirs = dirs, pins = {}, disks = {} })
	eq(#its, 2)
	eq(rows[1], { type = "title" })
	eq(rows[2], { type = "rule" })
	eq(rows[3], { type = "blank" })
	eq(rows[4], { type = "item", index = 1 })
	eq(rows[5], { type = "item", index = 2 })
	eq(#rows, 5)
end)
t("build: empty pins hide the whole Pinned section", function()
	local rows = core.build({ dirs = dirs, pins = {}, disks = { { label = "X", path = "/Volumes/X", icon = "x" } } })
	for _, row in ipairs(rows) do
		if row.type == "header" then
			eq(row.text, "Disks")
		end
	end
end)
t("build: sections carry header, inset rule, and items in order", function()
	local rows, its = core.build({
		dirs = dirs,
		pins = { { label = "~/p", path = "/u/p", icon = "p" } },
		disks = { { label = "X", path = "/Volumes/X", icon = "x" } },
	})
	eq(#its, 4)
	eq(rows[6], { type = "blank" })
	eq(rows[7], { type = "header", text = "Pinned", icon = "󰐃" })
	eq(rows[8], { type = "rule", inset = true })
	eq(rows[9], { type = "item", index = 3 })
	eq(rows[10], { type = "blank" })
	eq(rows[11], { type = "header", text = "Disks", icon = "󰋊" })
	eq(rows[12], { type = "rule", inset = true })
	eq(rows[13], { type = "item", index = 4 })
	eq(its[3].path, "/u/p")
	eq(its[4].path, "/Volumes/X")
end)

-- toggle -------------------------------------------------------------------
t("toggle: adds a missing path", function()
	eq(core.toggle({ "/a" }, "/b"), { "/a", "/b" })
end)
t("toggle: removes a present path", function()
	eq(core.toggle({ "/a", "/b" }, "/a"), { "/b" })
end)
t("toggle: drops duplicates and relative junk on rewrite", function()
	eq(core.toggle({ "/a", "/a", "junk", "" }, "/b"), { "/a", "/b" })
end)
t("toggle: refuses to add a non-absolute path", function()
	eq(core.toggle({ "/a" }, "junk"), { "/a" })
end)

-- disk_kind ----------------------------------------------------------------
t("disk_kind: disk images by protocol", function()
	eq(core.disk_kind("   Protocol:                  Disk Image\n   Internal:                  No"), "image")
end)
t("disk_kind: internal fixed disks", function()
	eq(core.disk_kind("   Protocol:                  Apple Fabric\n   Internal:                  Yes"), "internal")
end)
t("disk_kind: everything else is external", function()
	eq(core.disk_kind("   Protocol:                  USB\n   Internal:                  No"), "external")
end)
t("disk_kind: unparseable output falls back to external", function()
	eq(core.disk_kind(""), "external")
end)
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `cd ~/Projects/apps/yazi/nice-sidebar.yazi && nvim -l tests/run.lua`
Expected: 33 passed, 11 failed.

- [ ] **Step 3: Implement the three functions**

Insert into `main.lua` after `core.window` (before `local M`):

```lua
-- Flatten the sections into render rows plus the ordered selectable item
-- list. Empty pins/disks hide their whole section (header, rule, blank).
function core.build(sections)
	local rows, items = {}, {}
	local function add(it)
		items[#items + 1] = it
		rows[#rows + 1] = { type = "item", index = #items }
	end
	rows[#rows + 1] = { type = "title" }
	rows[#rows + 1] = { type = "rule" }
	rows[#rows + 1] = { type = "blank" }
	for _, it in ipairs(sections.dirs or {}) do
		add(it)
	end
	local function section(text, icon, list)
		if #list == 0 then
			return
		end
		rows[#rows + 1] = { type = "blank" }
		rows[#rows + 1] = { type = "header", text = text, icon = icon }
		rows[#rows + 1] = { type = "rule", inset = true }
		for _, it in ipairs(list) do
			add(it)
		end
	end
	section("Pinned", "󰐃", sections.pins or {})
	section("Disks", "󰋊", sections.disks or {})
	return rows, items
end

-- Toggle `path` in the pins line list. Only absolute paths survive the
-- rewrite; duplicates collapse; order is preserved.
function core.toggle(lines, path)
	local out, seen, removed = {}, {}, false
	for _, line in ipairs(lines) do
		if line:sub(1, 1) == "/" and not seen[line] then
			seen[line] = true
			if line == path then
				removed = true
			else
				out[#out + 1] = line
			end
		end
	end
	if not removed and path:sub(1, 1) == "/" then
		out[#out + 1] = path
	end
	return out
end

-- Classify `diskutil info <volume>` plain-text output. Protocol beats the
-- Internal flag: APFS system volumes report Internal, disk images report
-- their own protocol.
function core.disk_kind(text)
	if text:match("Protocol:%s+Disk Image") then
		return "image"
	end
	if text:match("Internal:%s+Yes") then
		return "internal"
	end
	return "external"
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ~/Projects/apps/yazi/nice-sidebar.yazi && nvim -l tests/run.lua`
Expected: `44 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/apps/yazi/nice-sidebar.yazi
git add main.lua tests/core_spec.lua
git commit -m "feat: sidebar row model, pin toggling, disk classification"
```

---

### Task 4: State, config, styles, and the rendering overrides

**Files:**
- Modify: `main.lua` (everything in this task goes between `local M = { core = core }` and `return M`)

**Interfaces:**
- Consumes: all `core` functions.
- Produces: locals `S` (state), `DEFAULTS`, `PIN_ICON`, `style(color, bold) -> ui.Style`, `sel_style(focused) -> ui.Style`, `swap_cursor(on)`, `select_item(i)`, `focus_sidebar()`, `blur_sidebar()`, `merge_cfg(opts) -> cfg`; `M:setup(opts)` installing `Tab:layout`, `Parent:redraw`, `Parent:click`, `Parent:scroll`. Task 5 uses `S`, `select_item`, `focus_sidebar`, `blur_sidebar`, `swap_cursor`; Task 6 uses `S.cfg` fields `dirs/pins_file/show_disks/disk_icons/home`.

- [ ] **Step 1: Add state, defaults, and config merging**

Insert into `main.lua` immediately after `local M = { core = core }`:

```lua
-- ----------------------------------------------------------------- state --
-- All mutable state lives in the sync VM behind this table. The ya.sync
-- bridges below are registered at the top level, so their sync-VM copies
-- capture this same table — async entry calls always act on it.
local S = {
	cfg = nil, -- merged config; nil until setup() runs
	rows = {}, -- render rows (core.build)
	items = {}, -- ordered selectable items
	selected = nil, -- item index, nil = nothing selected
	focus = "list", -- "list" | "sidebar"
	viewport = {}, -- visible line number -> row (redraw writes, click reads)
	last_scan = 0, -- os.time() of the last volume-rescan trigger
	indicator = nil, -- saved th.indicator.current for the cursor restyle
}

local PIN_ICON = "󰉋"

local DEFAULTS = {
	title = "Yazi File Manager",
	title_icon = "󰇥",
	width = 26,
	disk_icons = { internal = "󰋊", image = "", external = "󱊞" },
	dirs = {
		{ label = "Home", path = "~", icon = "󰠦" },
		{ label = "Desktop", path = "~/Desktop", icon = "󰇄" },
		{ label = "Downloads", path = "~/Downloads", icon = "󱑢" },
		{ label = "Documents", path = "~/Documents", icon = "󰈙" },
		{ label = "Pictures", path = "~/Pictures", icon = "󰋩" },
		{ label = "Videos", path = "~/Movies", icon = "󰿎" },
		{ label = "Music", path = "~/Music", icon = "󰝚" },
	},
}

local function merge_cfg(opts)
	opts = opts or {}
	local home = os.getenv("HOME") or "/"
	local icons = opts.disk_icons or {}
	local cfg = {
		home = home,
		title = opts.title or DEFAULTS.title,
		title_icon = opts.title_icon or DEFAULTS.title_icon,
		width = opts.width or DEFAULTS.width,
		show_disks = opts.show_disks ~= false,
		disk_icons = {
			internal = icons.internal or DEFAULTS.disk_icons.internal,
			image = icons.image or DEFAULTS.disk_icons.image,
			external = icons.external or DEFAULTS.disk_icons.external,
		},
		pins_file = opts.pins_file
			or (os.getenv("XDG_STATE_HOME") or home .. "/.local/state") .. "/yazi/nice-sidebar/pins",
		colors = opts.colors or {},
		dirs = {},
	}
	for _, d in ipairs(opts.dirs or DEFAULTS.dirs) do
		cfg.dirs[#cfg.dirs + 1] = { label = d.label, path = core.expand(d.path, home), icon = d.icon }
	end
	return cfg
end
```

- [ ] **Step 2: Add styles, cursor restyle, and the selection/focus primitives**

Insert into `main.lua` right after the `merge_cfg` block:

```lua
-- ---------------------------------------------------------------- styles --
local function style(color, bold)
	local s = ui.Style()
	if color then
		s = s:fg(color)
	end
	if bold then
		s = s:bold()
	end
	return s
end

-- The selected row: configured colors when both halves of a pair are set,
-- else reversed (focused) / bold (unfocused) as portable defaults.
local function sel_style(focused)
	local c = S.cfg.colors
	local bg = focused and c.selected_bg or c.selected_inactive_bg
	local fg = focused and c.selected_fg or c.selected_inactive_fg
	if bg and fg then
		return ui.Style():fg(fg):bg(bg):bold()
	end
	if focused then
		local ok, s = pcall(function()
			return ui.Style():reverse()
		end)
		if ok then
			return s
		end
	end
	return ui.Style():bold()
end

-- Restyle the file-list cursor while the sidebar holds focus (and restore
-- it on blur) so it is obvious which side owns j/k. Opt-in: needs both
-- colors.cursor_bg and colors.cursor_fg.
local function swap_cursor(on)
	local c = S.cfg and S.cfg.colors or {}
	if not (c.cursor_bg and c.cursor_fg) or not (th and th.indicator) then
		return
	end
	if on then
		S.indicator = S.indicator or th.indicator.current
		th.indicator.current = ui.Style():fg(c.cursor_fg):bg(c.cursor_bg):bold()
	elseif S.indicator then
		th.indicator.current = S.indicator
	end
end

-- ------------------------------------------------------- selection/focus --
-- Invariant #1: selection = cd. Selecting always navigates, even when the
-- index is unchanged (clicking Documents while deep inside it returns you
-- to ~/Documents, like Finder).
local function select_item(i)
	local it = S.items[i]
	if not it then
		return
	end
	S.selected = i
	ya.emit("cd", { it.path })
	ui.render()
end

-- Invariant #2: a focused sidebar always has a selection — focusing with
-- nothing selected selects Home (and therefore cds there).
local function focus_sidebar()
	if S.focus == "sidebar" or #S.items == 0 then
		return
	end
	S.focus = "sidebar"
	swap_cursor(true)
	if S.selected then
		ui.render()
	else
		select_item(1)
	end
end

local function blur_sidebar()
	if S.focus ~= "sidebar" then
		return
	end
	S.focus = "list"
	swap_cursor(false)
	ui.render()
end
```

- [ ] **Step 3: Add `M:setup` with the layout and rendering overrides**

Insert into `main.lua` after the `blur_sidebar` block (Task 5 will extend `setup` and add `entry`):

```lua
-- ----------------------------------------------------------------- setup --
function M:setup(opts)
	S.cfg = merge_cfg(opts)
	-- First paint: configured dirs as-is. The async refresh (Task 6) then
	-- replaces the sections with existence-filtered dirs, pins, and disks.
	S.rows, S.items = core.build({ dirs = S.cfg.dirs, pins = {}, disks = {} })

	local ok, err = pcall(function()
		-- Fixed-width sidebar: the parent slot becomes a Length constraint;
		-- current/preview split the remainder, preserving their configured
		-- proportions (so toggle-pane's 0/9999 ratio games keep working).
		function Tab:layout()
			local r = rt.mgr.ratio
			local cur = r[2] or r.current or 4
			local pre = r[3] or r.preview or 3
			if cur + pre == 0 then
				cur, pre = 1, 1
			end
			local w = math.min(S.cfg.width, math.max(10, self._area.w - 20))
			self._chunks = ui.Layout()
				:direction(ui.Layout.HORIZONTAL)
				:constraints({
					ui.Constraint.Length(w),
					ui.Constraint.Ratio(cur, cur + pre),
					ui.Constraint.Ratio(pre, cur + pre),
				})
				:split(self._area)
		end

		-- The sidebar owns the column: the parent listing never renders.
		function Parent:redraw()
			local area = self._area
			local w, h = area.w, area.h
			if w == 0 or h == 0 then
				return {}
			end
			local c = S.cfg.colors
			local focused = S.focus == "sidebar"

			local sel_row
			for i, row in ipairs(S.rows) do
				if row.type == "item" and row.index == S.selected then
					sel_row = i
					break
				end
			end

			local first, last = core.window(#S.rows, h, sel_row)
			local clipped = #S.rows > h
			local lines, vp = {}, {}
			for i = first, last do
				local row = S.rows[i]
				local ln
				if clipped and ((i == first and first > 1) or (i == last and last < #S.rows)) then
					ln = ui.Line({ ui.Span(" ⋮"):style(style(c.separator or "darkgray")) })
					row = { type = "blank" } -- the marker row is not clickable
				elseif row.type == "title" then
					ln = ui.Line({
						ui.Span(" " .. S.cfg.title_icon .. " " .. S.cfg.title):style(style(c.title or "magenta", true)),
					})
				elseif row.type == "rule" then
					local len = math.max(1, row.inset and (w - 4) or (w - 2))
					local lead = row.inset and "  " or " "
					ln = ui.Line({ ui.Span(lead .. string.rep("━", len)):style(style(c.separator or "darkgray")) })
				elseif row.type == "header" then
					ln = ui.Line({ ui.Span("  " .. row.icon .. " " .. row.text):style(style(c.section, true)) })
				elseif row.type == "item" then
					local it = S.items[row.index]
					local text = "  " .. it.icon .. " " .. it.label
					if row.index == S.selected then
						-- Full-width highlight: pad to the column edge.
						local pad = math.max(0, w - ui.Line({ ui.Span(text) }):width())
						ln = ui.Line({ ui.Span(text .. string.rep(" ", pad)):style(sel_style(focused)) })
						ln:truncate({ max = w })
					else
						ln = ui.Line({ ui.Span(text):style(style(c.item)) })
						ln:truncate({ max = w - 1 }) -- 1 cell of trailing padding
					end
				else -- blank
					ln = ui.Line({})
				end
				lines[#lines + 1] = ln
				vp[#lines] = row
			end
			S.viewport = vp
			return { ui.List(lines):area(area) }
		end

		-- Any click in the column focuses the sidebar; item rows also
		-- select + cd. Empty area with no selection selects Home
		-- (invariant #2). Nothing can reach the folder underneath.
		function Parent:click(event, up)
			if up or event.is_middle then
				return
			end
			local y = event.y - self._area.y + 1
			local row = S.viewport[y]
			if S.focus ~= "sidebar" then
				S.focus = "sidebar"
				swap_cursor(true)
			end
			if row and row.type == "item" then
				select_item(row.index)
			elseif not S.selected then
				select_item(1)
			else
				ui.render()
			end
		end

		function Parent:scroll() end
	end)
	if not ok then
		ya.dbg("nice-sidebar: setup failed, degrading to stock yazi: " .. tostring(err))
	end
end
```

- [ ] **Step 4: Run the tests (module must still load headlessly)**

Run: `cd ~/Projects/apps/yazi/nice-sidebar.yazi && nvim -l tests/run.lua`
Expected: `44 passed, 0 failed` — `setup` is not called at load time, so the yazi globals it touches don't matter.

- [ ] **Step 5: Build the sandbox config and eyeball the render**

```bash
SB=/private/tmp/claude-501/-Users-thiago--local-share-chezmoi/4fc300c8-2198-4449-858d-b23bc887c2a7/scratchpad/ns-sandbox
mkdir -p "$SB/plugins"
ln -sfn ~/Projects/apps/yazi/nice-sidebar.yazi "$SB/plugins/nice-sidebar.yazi"
printf 'require("nice-sidebar"):setup({})\n' > "$SB/init.lua"
: > "$SB/yazi.toml"
cat > "$SB/keymap.toml" <<'EOF'
[mgr]
prepend_keymap = [
  { on = "K",          run = "plugin nice-sidebar prev",  desc = "Sidebar: select the previous item" },
  { on = "J",          run = "plugin nice-sidebar next",  desc = "Sidebar: select the next item" },
  { on = "<S-Up>",     run = "plugin nice-sidebar prev",  desc = "Sidebar: select the previous item" },
  { on = "<S-Down>",   run = "plugin nice-sidebar next",  desc = "Sidebar: select the next item" },
  { on = "H",          run = "plugin nice-sidebar focus", desc = "Sidebar: focus" },
  { on = "<S-Left>",   run = "plugin nice-sidebar focus", desc = "Sidebar: focus" },
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
EOF
echo "launch with: YAZI_CONFIG_HOME=$SB yazi"
```

Launch `YAZI_CONFIG_HOME=$SB yazi` in a terminal. Expected: the left column shows the title, rule, and the seven default dirs, 26 cells wide, no parent listing; clicking a row cds there with a highlight; `q` quits. (Keyboard commands land in Task 5; pins/disks in Task 6 — the sections are absent for now.)

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/apps/yazi/nice-sidebar.yazi
git add main.lua
git commit -m "feat: config, state, and the sidebar layout + render overrides"
```

---

### Task 5: Keyboard interaction — nav bridge, cd tracking, entry dispatch

**Files:**
- Modify: `main.lua`

**Interfaces:**
- Consumes: `S`, `core`, `select_item`, `focus_sidebar`, `blur_sidebar`, `swap_cursor` from Task 4.
- Produces: top-level `local nav = ya.sync(...)` handling acts `next|prev|focus|h|l|j|k`; `local on_cd` (the `ps.sub` handler, also triggering throttled refresh emits); `M:entry(job)` dispatching nav acts (Task 6 extends it with `refresh`/`pin`); `ps.sub("cd", ...)` + best-effort `ps.sub("tab", ...)` + `ps.sub("mount", ...)` registrations inside `setup`.

- [ ] **Step 1: Add the cd handler and the nav bridge**

Insert into `main.lua` after the `blur_sidebar` block and **before** `M:setup` (order matters: `ya.sync` registrations must be at the top level, identical in both VMs):

```lua
-- ------------------------------------------------------------- cd events --
local function on_cd()
	local cwd = tostring(cx.active.current.cwd)
	local sel = core.track(S.items, S.selected, cwd)
	if sel ~= S.selected then
		S.selected = sel
		if not sel and S.focus == "sidebar" then
			-- Invariant #2, the other direction: no selection, no sidebar
			-- focus.
			S.focus = "list"
			swap_cursor(false)
		end
		ui.render()
	end
	-- Volumes drift while yazi runs; piggyback a throttled rescan on
	-- navigation (plus the mount event, when yazi publishes one).
	local now = os.time()
	if now - S.last_scan >= 5 then
		S.last_scan = now
		ya.emit("plugin", { "nice-sidebar", "refresh" })
	end
end

-- --------------------------------------------------------------- bridges --
-- Executed in the sync VM regardless of the calling context; registered at
-- the top level so both VMs agree on the registration index.
local nav = ya.sync(function(_, act)
	if not S.cfg then
		return
	end
	if act == "next" or act == "prev" then
		-- Global: works from either focus side, does not change focus.
		select_item(core.step(S.selected, act == "next" and 1 or -1, #S.items))
	elseif act == "focus" then
		focus_sidebar()
	elseif act == "h" then
		-- Sidebar focused: h/Left do nothing. List focused: leave, except
		-- at the filesystem root, where one more "left" focuses the
		-- sidebar.
		if S.focus == "sidebar" then
			return
		end
		if cx.active.parent then
			ya.emit("leave", {})
		else
			focus_sidebar()
		end
	elseif act == "l" then
		-- Sidebar focused: hand focus back to the file list. List focused:
		-- stock enter.
		if S.focus == "sidebar" then
			blur_sidebar()
		else
			ya.emit("enter", {})
		end
	elseif act == "j" or act == "k" then
		-- Focus-scoped: sidebar selection when the sidebar owns focus,
		-- stock cursor movement otherwise.
		if S.focus == "sidebar" then
			select_item(core.step(S.selected, act == "j" and 1 or -1, #S.items))
		else
			ya.emit("arrow", { act == "j" and 1 or -1 })
		end
	end
end)
```

- [ ] **Step 2: Register the subscriptions in `setup` and add `entry`**

Inside `M:setup`, immediately **before** the closing `end)` of the big `pcall` (after `function Parent:scroll() end`), add:

```lua
		ps.sub("cd", on_cd)
		-- Best-effort extra triggers: tab switches re-track the selection
		-- against the new tab's cwd; mount events rescan volumes. Neither
		-- event kind exists on every yazi build — absence is fine.
		pcall(ps.sub, "tab", on_cd)
		pcall(ps.sub, "mount", function()
			S.last_scan = os.time()
			ya.emit("plugin", { "nice-sidebar", "refresh" })
		end)
```

And right after the `if not ok then ... end` block at the end of `M:setup` (still inside it), add the boot rescan trigger:

```lua
	-- Populate pins/disks (and existence-filter the dirs) once at boot; the
	-- startup cd event covers this too, but only after the throttle window.
	ya.emit("plugin", { "nice-sidebar", "refresh" })
```

Then add `M:entry` after the whole `M:setup` function (before `return M`):

```lua
-- ----------------------------------------------------------------- entry --
-- Runs in the async context. Keymap args are POSITIONAL
-- ("plugin nice-sidebar prev") — yazi 26.5 silently drops `--args=` forms.
function M:entry(job)
	local act = job.args and job.args[1]
	if act == "refresh" then
		refresh() -- Task 6
	elseif act == "pin" then
		pin() -- Task 6
	elseif act then
		nav(act)
	end
end
```

Until Task 6 lands, stub the two async commands by inserting this **before** `M:entry` (Task 6 replaces it):

```lua
-- Placeholder async commands; Task 6 provides the real implementations.
local function refresh() end
local function pin() end
```

- [ ] **Step 3: Run the tests (module must still load)**

Run: `cd ~/Projects/apps/yazi/nice-sidebar.yazi && nvim -l tests/run.lua`
Expected: `44 passed, 0 failed`.

- [ ] **Step 4: Verify the interaction in the sandbox**

Launch `YAZI_CONFIG_HOME=$SB yazi` (sandbox from Task 4) and check, in order:

1. Boot: nothing selected, focus on the file list, j/k move the file cursor.
2. `J` (Shift+j): Home selected + cd to `~`; `J` again: Desktop; `K`: Home. At the top, `K` stays clamped on Home.
3. Navigate into `~/Desktop` by hand (`j`/`l`): Desktop row lights up (exact-match adoption). cd somewhere outside all sidebar dirs — e.g. `:cd /private/tmp` or `l` into a `/Volumes` path: selection clears.
4. `H`: sidebar takes focus (selected row uses the focused style); `j`/`k` now walk sidebar items and cd each time; `h`/`Left` do nothing; `H` again does nothing; `l`: focus returns to the list and `j`/`k` move the file cursor again.
5. `cd /` then `h` twice: first `h` steps to `/` (already there → leave is a no-op at root)… precisely: at `/`, `h` focuses the sidebar.
6. Selection clears while the sidebar is focused (select Home with `H`, then `:cd /private/tmp`): focus falls back to the list.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/apps/yazi/nice-sidebar.yazi
git add main.lua
git commit -m "feat: focus model — nav bridge, cd tracking, entry dispatch"
```

---

### Task 6: Async data — refresh (dirs/pins/disks) and the pin command

**Files:**
- Modify: `main.lua`

**Interfaces:**
- Consumes: `S`, `core`, `PIN_ICON`, `swap_cursor` (Task 4), `nav`/`on_cd` (Task 5).
- Produces: top-level bridges `get_cfg() -> {dirs, pins_file, show_disks, disk_icons, home}|nil`, `pin_target() -> path`, `publish(sections)`; async locals `read_lines(path)`, `write_lines(path, lines) -> bool`, `scan_disks(cfg) -> disks`, `refresh()`, `pin()` (replacing the Task 5 placeholders).

- [ ] **Step 1: Add the three bridges**

Insert into `main.lua` right after the `local nav = ya.sync(...)` block (top level):

```lua
local get_cfg = ya.sync(function()
	if not S.cfg then
		return nil
	end
	return {
		dirs = S.cfg.dirs,
		pins_file = S.cfg.pins_file,
		show_disks = S.cfg.show_disks,
		disk_icons = S.cfg.disk_icons,
		home = S.cfg.home,
	}
end)

-- The pin toggle target: the hovered directory, else the cwd.
local pin_target = ya.sync(function()
	local h = cx.active.current.hovered
	if h and h.cha.is_dir then
		return tostring(h.url)
	end
	return tostring(cx.active.current.cwd)
end)

-- Swap in freshly scanned sections, remapping the selection by path (the
-- item indexes shift when sections grow or shrink).
local publish = ya.sync(function(_, sections)
	if not S.cfg then
		return
	end
	local prev = S.selected and S.items[S.selected] and S.items[S.selected].path or nil
	S.rows, S.items = core.build(sections)
	S.selected = nil
	if prev then
		for i, it in ipairs(S.items) do
			if it.path == prev then
				S.selected = i
				break
			end
		end
	end
	if not S.selected and S.focus == "sidebar" then
		S.focus = "list"
		swap_cursor(false)
	end
	ui.render()
end)
```

- [ ] **Step 2: Replace the Task 5 placeholders with the real async commands**

Replace the two-line placeholder block (`local function refresh() end` / `local function pin() end`) with:

```lua
-- ------------------------------------------------------------ async work --
-- Everything below runs in the async context only: stats, dir listings,
-- process spawns, and file writes never touch the render path.
local function read_lines(path)
	local lines = {}
	local f = io.open(path, "r")
	if f then
		for line in f:lines() do
			lines[#lines + 1] = line
		end
		f:close()
	end
	return lines
end

local function write_lines(path, lines)
	local dir = path:match("^(.*)/[^/]+$")
	if dir then
		fs.create("dir_all", Url(dir))
	end
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then
		return false
	end
	f:write(table.concat(lines, "\n"))
	if #lines > 0 then
		f:write("\n")
	end
	f:close()
	return os.rename(tmp, path) ~= nil
end

-- The last successful scan, kept across entry calls (async-VM local): a
-- failed /Volumes read keeps showing it instead of blanking the section.
local last_disks = {}

local function scan_disks(cfg)
	local disks = {}
	local files = fs.read_dir(Url("/Volumes"), {})
	if not files then
		return last_disks
	end
	for _, f in ipairs(files) do
		if f.cha and f.cha.is_dir then
			local path = tostring(f.url)
			local name = path:match("([^/]+)$") or path
			local kind = "external"
			-- output() waits; spawn() must NOT be used here — the discarded
			-- Child handle is killed on GC, racing the process to death.
			local ok, output = pcall(function()
				return Command("diskutil"):arg("info"):arg(path):stdout(Command.PIPED):stderr(Command.PIPED):output()
			end)
			if ok and output and output.status and output.status.success then
				kind = core.disk_kind(output.stdout)
			end
			disks[#disks + 1] = { label = name, path = path, icon = cfg.disk_icons[kind] }
		end
	end
	last_disks = disks
	return disks
end

local function refresh()
	local cfg = get_cfg()
	if not cfg then
		return
	end
	local sections = { dirs = {}, pins = {}, disks = {} }
	for _, d in ipairs(cfg.dirs) do
		local cha = fs.cha(Url(d.path))
		if cha and cha.is_dir then
			sections.dirs[#sections.dirs + 1] = d
		end
	end
	for _, line in ipairs(read_lines(cfg.pins_file)) do
		if line:sub(1, 1) == "/" then
			-- Dead pins are hidden but stay in the file (a pin to an
			-- unmounted volume survives the unmount).
			local cha = fs.cha(Url(line))
			if cha and cha.is_dir then
				sections.pins[#sections.pins + 1] = { label = core.abbrev(line, cfg.home), path = line, icon = PIN_ICON }
			end
		end
	end
	if cfg.show_disks and ya.target_os() == "macos" then
		sections.disks = scan_disks(cfg)
	end
	publish(sections)
end

local function pin()
	local cfg = get_cfg()
	if not cfg then
		return
	end
	local lines = core.toggle(read_lines(cfg.pins_file), pin_target())
	if not write_lines(cfg.pins_file, lines) then
		ya.notify({ title = "nice-sidebar", content = "Cannot write the pins file", level = "warn", timeout = 5 })
		return
	end
	refresh()
end
```

- [ ] **Step 3: Run the tests (module must still load)**

Run: `cd ~/Projects/apps/yazi/nice-sidebar.yazi && nvim -l tests/run.lua`
Expected: `44 passed, 0 failed`.

- [ ] **Step 4: Verify pins and disks in the sandbox**

Launch `YAZI_CONFIG_HOME=$SB yazi` and check:

1. Boot: after ~a second the Disks section appears with `Macintosh HD` (`󰋊`). Any dir from the default set that doesn't exist on this machine disappears.
2. Hover a directory, `b p`: the Pinned section appears with its `~`-abbreviated path (`󰉋`); `b p` again on the same dir: the pin — and with it the whole section — vanishes. Verify the file: `cat ~/.local/state/yazi/nice-sidebar/pins` (present after pinning, path removed after unpinning).
3. Disk image round-trip:
   ```bash
   hdiutil create -size 10m -fs APFS -volname "ns test" /tmp/ns-test.dmg && hdiutil attach /tmp/ns-test.dmg
   ```
   Navigate once (any cd) or wait for a mount event: `ns test` appears under Disks with the image icon ``. Select it via `J`…: cd to `/Volumes/ns test`. Then `hdiutil detach "/Volumes/ns test" && rm /tmp/ns-test.dmg`; after the next cd the entry is gone (and the selection cleared, since the cwd left its umbrella — yazi itself will have kicked you out of the dead mount).
4. Pin selection survival: pin a dir, select it (`J`/`K` walk), pin another dir elsewhere — the selected pin stays selected after the sections rebuild.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/apps/yazi/nice-sidebar.yazi
git add main.lua
git commit -m "feat: async refresh (dirs, pins, disks) and the pin command"
```

---

### Task 7: README and repo polish

**Files:**
- Create: `README.md`
- Modify: `main.lua` (stylua formatting only, if the check flags anything)

**Interfaces:**
- Consumes: the finished plugin behavior and config API.
- Produces: the public documentation; a stylua-clean repo.

- [ ] **Step 1: Write `README.md`**

```markdown
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
| `j` / `Down` | cursor down | select next sidebar item |
| `k` / `Up` | cursor up | select previous sidebar item |
| `b p` | pin/unpin the hovered directory | — |

Mouse: clicking an item selects it (and cds); clicking empty sidebar space
focuses the sidebar, selecting Home if nothing was selected.

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
```

- [ ] **Step 2: Format check**

Run: `cd ~/Projects/apps/yazi/nice-sidebar.yazi && stylua --check main.lua tests/ || stylua main.lua tests/`
Expected: either clean, or stylua rewrites and `git diff` shows only whitespace/quote normalization. (If `stylua` is not installed: `brew install stylua`.)
Then run the tests once more: `nvim -l tests/run.lua` → `44 passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/apps/yazi/nice-sidebar.yazi
git add README.md main.lua tests/
git commit -m "docs: README — install, keymap dialect, config reference"
```

---

### Task 8: Full UX validation pass and push

**Files:**
- None created; findings from the checklist become fixes committed here.

**Interfaces:**
- Consumes: the complete plugin + sandbox from Task 4.

- [ ] **Step 1: Re-run the whole spec checklist in the sandbox**

`YAZI_CONFIG_HOME=$SB yazi`, walking the spec's Validation list end to end:

- Mock fidelity: paddings (1 title lead, 2 item lead, section headers aligned to item icons), rule lengths (title `w-2`, sections inset + `w-4`), blank lines, H1/H2/bold styling.
- `Shift+J`/`Shift+K` walk with empty selection → Home; clamping; immediate cds; crossing sections.
- Umbrella clearing, exact-path adoption, duplicate-path first-wins (pin `~/Desktop`, then cd to it).
- Focus round-trip: `Shift+H` in, `h` at `/` in, `l` out, `h`/`Shift+H`/`Left`/`Shift+Left` no-ops inside, `j`/`k` scoping per side.
- Mouse: item click (select + cd + focus), empty-area click (focus; Home when nothing selected), scroll does nothing.
- Pins: `b p` toggle on hovered dir and on a file (falls back to cwd), section appear/disappear, dead pin hidden but preserved in the file.
- Disks: `Macintosh HD` present; dmg mount/unmount round-trip (Task 6 step 4 commands); icon per kind.
- Narrow terminal: resize below ~40 columns — sidebar shrinks (clamp), rows window with `⋮`.
- Coexistence: add `require("full-border"):setup()` to the sandbox `init.lua`, relaunch, confirm borders + sidebar; remove it again.
- Degradation: launch with the pins file made unreadable (`chmod 000` its parent) — yazi boots, pin toggle warns, no crash. Restore permissions.

- [ ] **Step 2: Fix anything the checklist surfaces**

Each fix: reproduce → fix in `main.lua` → re-run `nvim -l tests/run.lua` (still green) → re-check in the sandbox → `git commit` with a conventional `fix:` message describing the symptom.

- [ ] **Step 3: Push**

```bash
cd ~/Projects/apps/yazi/nice-sidebar.yazi
git push
```

---

## Out of scope (tracked in the spec)

The consumer integration in the chezmoi repo (package.toml dep + lockfile capture, guarded `setup{}` with theme-bridge colors and the Depot/Notes/Projects/Public entries, keymap rows, deleting parent-arrow.yazi) is a **separate follow-up change** in the yazi silo, done after this plugin lands and validates.
