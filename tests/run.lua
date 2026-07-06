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
