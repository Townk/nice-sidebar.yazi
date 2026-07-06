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

local M = { core = core }

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

return M
