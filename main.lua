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

local M = { core = core }

return M
