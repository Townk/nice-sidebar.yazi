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
