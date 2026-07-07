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

-- Staging-panel height: content grows one line per row atop `chrome` fixed
-- rows (a single divider, or a blank + tab-bar header — default 1), capped at
-- floor(preview_h * ratio). Returns the total panel height (incl. chrome) and
-- the visible list height. count 0 or a preview too short to hold chrome + one
-- line hides the panel (0, 0).
function core.panel_height(count, preview_h, max_ratio, chrome)
	chrome = chrome or 1
	if count <= 0 or preview_h < chrome + 1 then
		return 0, 0
	end
	local cap = math.max(chrome + 1, math.floor(preview_h * (max_ratio or 0.5)))
	local panel = math.min(chrome + count, cap)
	return panel, panel - chrome
end

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
	section("Disks", "🖴", sections.disks or {})
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
-- internal flags: APFS system volumes report internal, disk images report
-- their own protocol. Apple Silicon prints "Device Location: Internal";
-- older machines print "Internal: Yes" — accept both.
function core.disk_kind(text)
	if text:match("Protocol:%s+Disk Image") then
		return "image"
	end
	if text:match("Internal:%s+Yes") or text:match("Device Location:%s+Internal") then
		return "internal"
	end
	return "external"
end

-- The "Volume Name" field of `diskutil info` output — the label macOS
-- shows for the volume, which can differ from the mountpoint basename.
function core.volume_name(text)
	local name = text:match("Volume Name:%s*([^\n]+)")
	if name then
		name = name:gsub("%s+$", "")
		if name ~= "" and not name:match("^Not applicable") then
			return name
		end
	end
	return nil
end

-- Mountpoints of /dev/disk devices living outside /Volumes, from `mount`
-- output — disk images and volumes attached at custom paths (e.g. a sparse
-- bundle mounted under ~/Projects). System mounts and /Volumes entries
-- (listed directly) are excluded. The trailing "(options)" group is
-- anchored at end-of-line so mountpoints containing " (" survive.
function core.parse_mounts(text)
	local out, seen = {}, {}
	for line in text:gmatch("[^\n]+") do
		local path = line:match("^/dev/%S+ on (.+) %([^()]*%)%s*$")
		if path then
			-- macOS sometimes records custom mountpoints under the Data
			-- volume firmlink; fold them back onto the visible namespace.
			path = path:gsub("^/System/Volumes/Data/", "/")
		end
		if
			path
			and path ~= "/"
			and not path:match("^/System/")
			and not path:match("^/private/")
			and not path:match("^/Library/")
			and not path:match("^/Volumes/")
			and not seen[path]
		then
			seen[path] = true
			out[#out + 1] = path
		end
	end
	return out
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
	focus = "list", -- "list" | "sidebar" | "staging"
	viewport = {}, -- visible line number -> row (redraw writes, click reads)
	last_scan = 0, -- os.time() of the last volume-rescan trigger
	indicator = nil, -- saved th.indicator.current for the cursor restyle
	stg = { cfg = nil, lane = "staged", sel = nil, first = 1, area = nil, vp = {} },
}

local PIN_ICON = "󰉋"

local DEFAULTS = {
	title = "Yazi File Manager",
	title_icon = "󰇥",
	width = 26,
	disk_icons = { internal = "󰋊", image = "", external = "󱊞" },
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
		-- follow = false (default): moving the sidebar highlight while it holds
		-- focus does NOT change the file panes — it is a browse cursor, and
		-- Enter commits (cd + jump to the panes). follow = true: the panes
		-- track the highlight live (cd on every move).
		follow = opts.follow == true,
		disk_icons = {
			internal = icons.internal or DEFAULTS.disk_icons.internal,
			image = icons.image or DEFAULTS.disk_icons.image,
			external = icons.external or DEFAULTS.disk_icons.external,
		},
		pins_file = opts.pins_file or (os.getenv("XDG_STATE_HOME") or home .. "/.local/state") .. "/yazi/nice-sidebar/pins",
		colors = opts.colors or {},
		dirs = {},
	}
	for _, d in ipairs(opts.dirs or DEFAULTS.dirs) do
		cfg.dirs[#cfg.dirs + 1] = { label = d.label, path = core.expand(d.path, home), icon = d.icon }
	end
	local st = opts.staging or {}
	cfg.staging = {
		enabled = st.enabled ~= false,
		max_ratio = st.max_ratio or 0.5,
		reveal_on_enter = st.reveal_on_enter ~= false,
		icon = st.icon or "\239\128\156", -- U+F01C (nf-fa-inbox), UTF-8 bytes
		clipboard_icon = st.clipboard_icon or "󰅍",
	}
	return cfg
end

-- ---------------------------------------------------------------- styles --
local function style(color, bold)
	local s = ui.Style()
	if color then
		pcall(function()
			s = s:fg(color)
		end)
	end
	if bold then
		s = s:bold()
	end
	return s
end

-- The selected row draws as yazi's own cursor pill: rounded caps from
-- th.indicator.padding around the highlighted body. Returns the body style
-- and a cap style — a nil cap means no pill (the portable unfocused
-- default is plain bold, which has no background color to shape a cap
-- with). Configured colors when both halves of a pair are set, else
-- reversed (focused) via the preset's Entity:style_rev trick.
local function sel_pill(focused)
	local c = S.cfg.colors
	local bg, fg
	if focused then
		bg, fg = c.selected_bg, c.selected_fg
	else
		bg, fg = c.selected_inactive_bg, c.selected_inactive_fg
	end
	if bg and fg then
		local ok, body, cap = pcall(function()
			return ui.Style():fg(fg):bg(bg):bold(), ui.Style():fg(bg)
		end)
		if ok then
			return body, cap
		end
	end
	if focused then
		local ok, body, cap = pcall(function()
			return ui.Style():reverse(true), ui.Style():bg("reset"):reverse(true)
		end)
		if ok then
			return body, cap
		end
	end
	return ui.Style():bold(), nil
end

local function pill_caps()
	local p = th and th.indicator and th.indicator.padding
	return (p and p.open) or "", (p and p.close) or ""
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
		local ok, s = pcall(function()
			return ui.Style():fg(c.cursor_fg):bg(c.cursor_bg):bold()
		end)
		if ok then
			S.indicator = S.indicator or th.indicator.current
			th.indicator.current = s
		end
	elseif S.indicator then
		th.indicator.current = S.indicator
	end
end

-- ------------------------------------------------------- selection/focus --
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

-- Row counts of both lanes: staged (per-tab selection) and clipboard (the
-- global yank register).
local function lane_counts()
	return #cx.active.selected, #cx.yanked
end

-- The panel shows while EITHER lane has content.
local function stg_visible()
	if not (S.stg.cfg and S.stg.cfg.enabled) then
		return false
	end
	local staged, clip = lane_counts()
	return staged > 0 or clip > 0
end

-- Resolve the active lane, auto-switching away from an emptied lane so the
-- visible lane always has content whenever the panel is shown.
local function active_lane()
	local staged, clip = lane_counts()
	local lane = S.stg.lane or "staged"
	if lane == "staged" and staged == 0 and clip > 0 then
		lane = "clipboard"
	elseif lane == "clipboard" and clip == 0 and staged > 0 then
		lane = "staged"
	end
	S.stg.lane = lane
	return lane
end

-- The active lane's paths (+ the clipboard cut flag). `selection()` above is
-- the staged-lane reader; this dispatches on the active lane.
local function lane_data()
	local lane = active_lane()
	local list = {}
	if lane == "clipboard" then
		for _, url in pairs(cx.yanked) do
			list[#list + 1] = tostring(url)
		end
		return lane, list, cx.yanked.is_cut
	end
	for _, url in pairs(cx.active.selected) do
		list[#list + 1] = tostring(url)
	end
	return lane, list, false
end

-- select_item: commit — move the highlight AND cd to it. Navigates even when
-- the index is unchanged (clicking Documents while deep inside it returns you
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

-- highlight: move the browse cursor WITHOUT touching the file panes. The
-- deferred half of the `follow = false` model.
local function highlight(i)
	if not S.items[i] then
		return
	end
	S.selected = i
	ui.render()
end

-- move: step the sidebar selection by `delta`. In follow mode every step
-- cds live; otherwise it just moves the highlight (Enter commits later).
local function move(delta)
	local i = core.step(S.selected, delta, #S.items)
	if S.cfg.follow then
		select_item(i)
	else
		highlight(i)
	end
end

-- Invariant: a focused sidebar always has a selection. Focusing with nothing
-- highlighted picks Home. In follow mode that also cds (live); in the default
-- deferred mode focusing never moves the panes.
local function focus_sidebar()
	if S.focus == "sidebar" or #S.items == 0 then
		return
	end
	S.focus = "sidebar"
	swap_cursor(true)
	if S.cfg.follow then
		if S.selected then
			ui.render()
		else
			select_item(1)
		end
	else
		if not S.selected then
			S.selected = 1
		end
		ui.render()
	end
end

-- Blurring cancels an un-committed browse: the highlight snaps back to the
-- item matching the current cwd (or clears) so the pill never lies about
-- where the panes are. In follow mode the highlight already equals the cwd
-- item, so this is a no-op there.
local function blur_sidebar()
	if S.focus ~= "sidebar" then
		return
	end
	S.focus = "list"
	swap_cursor(false)
	if not S.cfg.follow then
		S.selected = core.track(S.items, nil, tostring(cx.active.current.cwd))
	end
	ui.render()
end

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
	-- Dim the file-list cursor so exactly one region reads as focused, the
	-- same feedback the sidebar uses (swap_cursor is a no-op unless the
	-- cursor_bg/cursor_fg colors are configured).
	swap_cursor(true)
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
	swap_cursor(false)
	S.stg.sel = nil
	ui.render()
end

-- Switch the panel's active lane. Only lands on a lane that has content (an
-- empty lane would just bounce back), and resets the cursor to the top.
local function set_lane(name)
	local staged, clip = lane_counts()
	local n = name == "clipboard" and clip or staged
	if n == 0 or S.stg.lane == name then
		return
	end
	S.stg.lane = name
	S.stg.sel = 1
	S.stg.first = 1
	ui.render()
end

-- Move the active-lane cursor by delta, clamped over that lane's row count.
local function stg_move(delta)
	local _, list = lane_data()
	local n = #list
	if n == 0 then
		stg_blur()
		return
	end
	S.stg.sel = core.step(S.stg.sel, delta, n)
	ui.render()
end

-- Remove the hovered row from the active lane: un-stage it (staged lane).
-- Clipboard-lane removal (dropping from the yank register) lands in the next
-- increment. Removal shifts the list up, so keeping the same index lands the
-- cursor on the next row — there is no visible "stay vs move" difference here
-- (that distinction only matters in the panes, where toggling leaves the file
-- in place). When the last row across both lanes goes, focus returns to panes.
local function panel_remove()
	local lane, list = lane_data()
	local n = #list
	if n == 0 then
		stg_blur()
		return
	end
	if lane == "clipboard" then
		-- View-only: Yazi exposes the yank register read-only. It can only be
		-- cleared wholesale (unyank) or set from a native EmberYank (no Lua
		-- constructor), so a single clipboard entry cannot be removed. Space is
		-- a deliberate no-op here; Enter still reveals.
		return
	end
	local i = S.stg.sel or 1
	local url = list[i]
	if not url then
		return
	end
	ya.emit("toggle_all", { url, state = "off" })
	local staged, clip = lane_counts()
	if staged + clip - 1 <= 0 then
		stg_blur()
		return
	end
	S.stg.sel = math.min(i, n - 1)
	ui.render()
end

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
	-- Selection can empty out from a cd (leaving a folder whose files were
	-- selected does not clear them, but a paste/delete might). If it did and
	-- staging held focus, drop back to the panes.
	if S.focus == "staging" and not stg_visible() then
		S.focus = "list"
		swap_cursor(false)
		S.stg.sel = nil
		ui.render()
	end
end

-- --------------------------------------------------------------- bridges --
-- Executed in the sync VM regardless of the calling context; registered at
-- the top level so both VMs agree on the registration index.
local nav = ya.sync(function(_, act, rest)
	if not S.cfg then
		return
	end
	if act == "next" or act == "prev" then
		-- Focus-scoped. From the file list: cd immediately to the next/prev
		-- sidebar item WITHOUT stealing focus — the panes change under you,
		-- the classic global jump. From the sidebar: move the highlight,
		-- deferred (Enter commits) or live per `follow`.
		local delta = act == "next" and 1 or -1
		if S.focus == "sidebar" then
			move(delta)
		else
			select_item(core.step(S.selected, delta, #S.items))
		end
	elseif act == "focus" then
		focus_sidebar()
	elseif act == "blur" then
		-- Sidebar focused: hand focus back to the file list. List focused:
		-- run the fallthrough command given as the remaining keymap args
		-- (e.g. "plugin nice-sidebar blur plugin bypass" keeps L's stock
		-- bypass behavior), or do nothing.
		if S.focus == "sidebar" then
			blur_sidebar()
		elseif rest and rest[1] then
			ya.emit(rest[1], { table.unpack(rest, 2) })
		end
	elseif act == "enter" then
		-- Staging focused: reveal the cursor file (if configured) and hand
		-- focus to the panes. Sidebar focused: CONFIRM the highlighted item —
		-- cd to it and jump focus to the file panes (never runs list
		-- navigation underneath the sidebar). This is the commit step of the
		-- deferred model, and in follow mode it just re-anchors + jumps. List
		-- focused: fallthrough.
		if S.focus == "staging" then
			if S.stg.cfg.reveal_on_enter and S.stg.sel then
				local _, list = lane_data()
				if list[S.stg.sel] then
					ya.emit("reveal", { list[S.stg.sel] })
				end
			end
			stg_blur()
		elseif S.focus == "sidebar" then
			select_item(S.selected)
			blur_sidebar()
		elseif rest and rest[1] then
			ya.emit(rest[1], { table.unpack(rest, 2) })
		end
	elseif act == "guard" then
		-- Generic list-navigation suppressor: swallow the key while the
		-- sidebar or staging panel holds focus, run the fallthrough
		-- otherwise (e.g. "plugin nice-sidebar guard arrow bot" wraps G).
		if S.focus == "list" and rest and rest[1] then
			ya.emit(rest[1], { table.unpack(rest, 2) })
		end
	elseif act == "h" then
		-- Sidebar focused: h/Left do nothing. Staging focused: switch to the
		-- Staged (left) lane — leaving the panel is Shift+H. List focused:
		-- leave, except at the filesystem root, where one more "left" focuses
		-- the sidebar.
		if S.focus == "sidebar" then
			return
		elseif S.focus == "staging" then
			set_lane("staged")
			return
		end
		if cx.active.parent then
			ya.emit("leave", {})
		else
			focus_sidebar()
		end
	elseif act == "l" then
		-- Sidebar focused: hand focus back to the file list. Staging focused:
		-- switch to the Clipboard (right) lane. List focused: stock enter.
		if S.focus == "sidebar" then
			blur_sidebar()
		elseif S.focus == "staging" then
			set_lane("clipboard")
		else
			ya.emit("enter", {})
		end
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
	elseif act == "space" or act == "sspace" then
		-- Panel focused: un-stage the hovered file. Panes/sidebar: toggle the
		-- center-hovered file's selection; `space` keeps the cursor put,
		-- `sspace` (Shift+Space) advances it — the inverse of Yazi's default
		-- `<Space>` = [toggle, arrow 1].
		if S.focus == "staging" then
			panel_remove()
		else
			ya.emit("toggle", {})
			if act == "sspace" then
				ya.emit("arrow", { 1 })
			end
		end
	elseif act == "lane_staged" or act == "lane_clipboard" then
		-- Alt+s / Alt+c: jump straight to a lane — focus the panel and switch
		-- to it (a no-op when that lane is empty). Single-token acts because
		-- Yazi 26.5 drops trailing positional plugin args.
		local name = act == "lane_clipboard" and "clipboard" or "staged"
		local staged, clip = lane_counts()
		if (name == "clipboard" and clip or staged) == 0 then
			return
		end
		S.stg.lane = name
		S.stg.sel = 1
		S.stg.first = 1
		if S.focus ~= "staging" then
			stg_focus()
		else
			ui.render()
		end
	elseif act == "j" or act == "k" then
		-- Focus-scoped: move the sidebar selection (deferred or live per
		-- `follow`) when the sidebar owns focus, the staging cursor when the
		-- panel owns focus, stock cursor movement otherwise.
		local delta = act == "j" and 1 or -1
		if S.focus == "sidebar" then
			move(delta)
		elseif S.focus == "staging" then
			stg_move(delta)
		else
			ya.emit("arrow", { delta })
		end
	end
end)

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

-- The pin toggle target: the highlighted sidebar item while the sidebar
-- holds focus (so `b p` on a selected pin unpins it instead of pinning
-- whatever the file list hovers underneath), else the hovered directory,
-- else the cwd.
local pin_target = ya.sync(function()
	if S.focus == "sidebar" and S.selected and S.items[S.selected] then
		return S.items[S.selected].path
	end
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

-- Render the staging panel into `area`: a divider row, then the visible slice
-- of the selection with a focused cursor pill, plus a right-edge scrollbar when
-- the list overflows. Writes S.stg.vp (visible line -> selection index) and
-- S.stg.first for click/scroll hit-testing.
local function render_staging(area)
	local w, h = area.w, area.h
	if w == 0 or h < 2 then
		S.stg.vp = {}
		return {}
	end
	local c = S.cfg.colors
	local lane, list, is_cut = lane_data()
	local total = #list
	local visible_h = h - 2 -- row 1 blank spacer, row 2 tab bar
	local focused = S.focus == "staging"

	-- Removals / lane switches shrink the list under the cursor; clamp so the
	-- pill never points past the end.
	if focused and S.stg.sel and total > 0 and S.stg.sel > total then
		S.stg.sel = total
	end

	local lines, vp = {}, {}
	local rule = style(c.tab_rule or c.separator or "darkgray")
	local staged_n, clip_n = lane_counts()
	local lead, mid, trail = "─ ", " | ", " "
	-- Measure with throwaway spans: ui.Line consumes the Span userdata, so the
	-- real spans must be built exactly once, not reused for a width probe.
	local function tw(s)
		return ui.Line({ ui.Span(s) }):width()
	end
	-- Only lanes with content get a label; the empty lane is hidden. Each seg is
	-- { text, colour, active }. "stage" carries Yazi's selected-marker colour,
	-- "clipboard" its yank-marker colour (the cut colour when it is a cut).
	local segs = {}
	if staged_n > 0 then
		segs[#segs + 1] = { S.stg.cfg.icon .. " stage (" .. staged_n .. ")", c.staged or "yellow", lane == "staged" }
	end
	if clip_n > 0 then
		local clip_color = is_cut and (c.clipboard_cut or "red") or (c.clipboard or "green")
		segs[#segs + 1] = { S.stg.cfg.clipboard_icon .. " clipboard (" .. clip_n .. ")", clip_color, lane == "clipboard" }
	end
	-- Row 2: the tab bar. Track the active seg's column offset + width so row 1
	-- can draw a ▁ underline bar exactly beneath it (the active-lane indicator).
	local spans = { ui.Span(lead):style(rule) }
	local x = tw(lead)
	local used = tw(lead) + tw(trail)
	local ind_x, ind_w, ind_color
	for i, seg in ipairs(segs) do
		if i > 1 then
			spans[#spans + 1] = ui.Span(mid):style(rule)
			x = x + tw(mid)
			used = used + tw(mid)
		end
		local sw = tw(seg[1])
		spans[#spans + 1] = ui.Span(seg[1]):style(style(seg[2]))
		if seg[3] then
			ind_x, ind_w, ind_color = x, sw, seg[2]
		end
		x = x + sw
		used = used + sw
	end
	spans[#spans + 1] = ui.Span(trail):style(rule)
	if w > used then
		spans[#spans + 1] = ui.Span(string.rep("─", w - used)):style(rule)
	end
	lines[2] = ui.Line(spans)
	vp[2] = nil
	-- Row 1: the ▁ indicator bar beneath the active tab (in its colour), else blank.
	if ind_x and ind_w and ind_w > 0 then
		local iparts = {}
		if ind_x > 0 then
			iparts[#iparts + 1] = ui.Span(string.rep(" ", ind_x))
		end
		iparts[#iparts + 1] = ui.Span(string.rep("▁", ind_w)):style(style(ind_color))
		lines[1] = ui.Line(iparts)
	else
		lines[1] = ui.Line({})
	end
	vp[1] = nil

	if total > 0 and visible_h >= 1 then
		local first, last = core.window(total, visible_h, focused and S.stg.sel or S.stg.first)
		S.stg.first = first
		local cwd = tostring(cx.active.current.cwd)
		local home = S.cfg.home
		local icon = lane == "clipboard" and S.stg.cfg.clipboard_icon or S.stg.cfg.icon
		local line_i = 2
		for i = first, last do
			line_i = line_i + 1
			local shown = core.rel(list[i], cwd, home)
			local text = icon .. " " .. shown
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

		local bar = core.scrollbar(total, visible_h, first)
		if bar then
			S.stg.vp = vp
			local out = { ui.List(lines):area(area) }
			local track = ui.Rect({ x = area.x + w - 1, y = area.y + 2 + bar.y, w = 1, h = bar.len })
			out[#out + 1] = ui.Bar(ui.Edge.RIGHT):area(track):symbol("█"):style(style(c.separator or "darkgray"))
			return out
		end
	end

	S.stg.vp = vp
	return { ui.List(lines):area(area) }
end

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
	local ok, res = pcall(render_staging, self._area)
	if not ok then
		pcall(ya.notify, { title = "nice-sidebar staging", content = tostring(res), level = "error", timeout = 10 })
		return {}
	end
	return res
end
function Staging:touch(event, step) end
function Staging:click(event, up)
	if up or event.is_middle then
		return
	end
	stg_focus()
	local line = event.y - self._area.y + 1
	if line == 2 then
		-- Tab bar: click the left half for Staged, the right half for Clipboard.
		set_lane(event.x - self._area.x < math.floor(self._area.w / 2) and "staged" or "clipboard")
		return
	end
	local idx = S.stg.vp[line]
	if idx then
		S.stg.sel = idx
		ui.render()
	end
end

function Staging:scroll(event, step)
	-- Wheel scrolls the active lane's list regardless of focus.
	local _, list = lane_data()
	local n = #list
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

-- ----------------------------------------------------------------- setup --
function M:setup(opts)
	S.cfg = merge_cfg(opts)
	S.stg.cfg = S.cfg.staging
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
			-- Size to the ACTIVE lane's rows atop the 2-row header (blank +
			-- tab bar); auto-switch keeps the active lane non-empty here.
			local _, list = lane_data()
			local panel_h = select(1, core.panel_height(#list, a.h, S.stg.cfg.max_ratio, 2))
			if panel_h <= 0 then
				return
			end
			local top = ui.Rect({ x = a.x, y = a.y, w = a.w, h = a.h - panel_h })
			local bot = ui.Rect({ x = a.x, y = a.y + a.h - panel_h, w = a.w, h = panel_h })
			prev._area = top
			S.stg.area = bot
			self._children[#self._children + 1] = Staging:new(bot, self._tab)
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
				if clipped and i ~= sel_row and ((i == first and first > 1) or (i == last and last < #S.rows)) then
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
					if row.index == S.selected then
						local body, cap = sel_pill(focused)
						if cap then
							-- The pill sits 1 cell in from each column edge;
							-- the label is pre-truncated so the close cap
							-- never gets clipped away.
							local open, close = pill_caps()
							local icon_w = ui.Line({ ui.Span(it.icon .. " ") }):width()
							local label = core.truncate(it.label, math.max(1, w - 4 - icon_w))
							local inner = it.icon .. " " .. label
							local pad = math.max(0, w - 4 - ui.Line({ ui.Span(inner) }):width())
							ln = ui.Line({
								ui.Span(" "),
								ui.Span(open):style(cap),
								ui.Span(inner .. string.rep(" ", pad)):style(body),
								ui.Span(close):style(cap),
							})
							ln:truncate({ max = w })
						else
							ln = ui.Line({ ui.Span("  " .. it.icon .. " " .. it.label):style(body) })
							ln:truncate({ max = math.max(1, w - 1) })
						end
					else
						ln = ui.Line({ ui.Span("  " .. it.icon .. " " .. it.label):style(style(c.item)) })
						ln:truncate({ max = math.max(1, w - 1) }) -- 1 cell of trailing padding
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
				-- Empty-area click, nothing highlighted: pick Home, but cd only
				-- in follow mode so a stray click never moves the panes in the
				-- default deferred mode.
				if S.cfg.follow then
					select_item(1)
				else
					highlight(1)
				end
			else
				ui.render()
			end
		end

		function Parent:scroll() end

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

		ps.sub("cd", on_cd)
		-- Best-effort extra triggers: tab switches re-track the selection
		-- against the new tab's cwd; mount events rescan volumes. Neither
		-- event kind exists on every yazi build — absence is fine.
		pcall(ps.sub, "tab", on_cd)
		pcall(ps.sub, "mount", function()
			S.last_scan = os.time()
			ya.emit("plugin", { "nice-sidebar", "refresh" })
		end)
	end)
	if not ok then
		ya.dbg("nice-sidebar: setup failed, degrading to stock yazi: " .. tostring(err))
	end
	-- Populate pins/disks (and existence-filter the dirs) once at boot; the
	-- startup cd event covers this too, but only after the throttle window.
	ya.emit("plugin", { "nice-sidebar", "refresh" })
end

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

-- output() waits; spawn() must NOT be used here — the discarded Child
-- handle is killed on GC, racing the process to death.
local function run(cmd, ...)
	local args = { ... }
	local ok, output = pcall(function()
		local c = Command(cmd)
		for _, a in ipairs(args) do
			c = c:arg(a)
		end
		return c:stdout(Command.PIPED):stderr(Command.PIPED):output()
	end)
	if ok and output and output.status and output.status.success then
		return output.stdout
	end
	return nil
end

local function scan_disks(cfg)
	local disks, seen = {}, {}
	local function add(path)
		if seen[path] then
			return
		end
		seen[path] = true
		local kind, label = "external", path:match("([^/]+)$") or path
		local info = run("diskutil", "info", path)
		if info then
			kind = core.disk_kind(info)
			label = core.volume_name(info) or label
		end
		disks[#disks + 1] = { label = label, path = path, icon = cfg.disk_icons[kind] }
	end
	-- resolve: "Macintosh HD" is a symlink to / — without following it,
	-- cha.is_dir is false and the internal disk vanishes from the list.
	local files = fs.read_dir(Url("/Volumes"), { resolve = true })
	if not files then
		return last_disks
	end
	for _, f in ipairs(files) do
		if f.cha and f.cha.is_dir then
			add(tostring(f.url))
		end
	end
	-- Volumes mounted outside /Volumes — disk images attached at custom
	-- mountpoints (e.g. a sparse bundle under ~/Projects) never show up
	-- there, only in the mount table.
	local mounts = run("mount")
	if mounts then
		for _, path in ipairs(core.parse_mounts(mounts)) do
			add(path)
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
		-- follow=true: a configured dir that is a symlink still counts.
		local cha = fs.cha(Url(d.path), true)
		if cha and cha.is_dir then
			sections.dirs[#sections.dirs + 1] = d
		end
	end
	for _, line in ipairs(read_lines(cfg.pins_file)) do
		if line:sub(1, 1) == "/" then
			-- Dead pins are hidden but stay in the file (a pin to an
			-- unmounted volume survives the unmount).
			local cha = fs.cha(Url(line), true)
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
	local target = pin_target()
	if target:sub(1, 1) ~= "/" then
		ya.notify({ title = "nice-sidebar", content = "Only real directories can be pinned", level = "warn", timeout = 5 })
		return
	end
	local lines = core.toggle(read_lines(cfg.pins_file), target)
	if not write_lines(cfg.pins_file, lines) then
		ya.notify({ title = "nice-sidebar", content = "Cannot write the pins file", level = "warn", timeout = 5 })
		return
	end
	refresh()
end

-- ----------------------------------------------------------------- entry --
-- Runs in the async context. Keymap args are POSITIONAL
-- ("plugin nice-sidebar prev") — yazi 26.5 silently drops `--args=` forms.
function M:entry(job)
	local act = job.args and job.args[1]
	if act == "refresh" then
		refresh()
	elseif act == "pin" then
		pin()
	elseif act then
		-- job.args may not be a plain table (no table.unpack): collect the
		-- trailing positionals by index.
		local rest, i = {}, 2
		while job.args[i] ~= nil do
			rest[i - 1], i = job.args[i], i + 1
		end
		nav(act, rest)
	end
end

return M
