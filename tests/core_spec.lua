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
t("panel_height: chrome=2 reserves two header rows", function()
	local p, v = core.panel_height(3, 20, 0.5, 2)
	eq({ p, v }, { 5, 3 })
end)
t("panel_height: chrome=2 caps and keeps two header rows", function()
	local p, v = core.panel_height(100, 20, 0.5, 2)
	eq({ p, v }, { 10, 8 })
end)
t("panel_height: chrome=2 needs room for header + one line", function()
	local p, v = core.panel_height(5, 2, 0.5, 2)
	eq({ p, v }, { 0, 0 })
end)

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
	local headers = 0
	for _, row in ipairs(rows) do
		if row.type == "header" then
			headers = headers + 1
			eq(row.text, "Disks")
		end
	end
	eq(headers, 1)
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
	eq(rows[11], { type = "header", text = "Disks", icon = "🖴" })
	eq(rows[12], { type = "rule", inset = true })
	eq(rows[13], { type = "item", index = 4 })
	eq(its[3].path, "/u/p")
	eq(its[4].path, "/Volumes/X")
end)
t("build: empty dirs still render the title block and sections", function()
	local rows, its = core.build({
		dirs = {},
		pins = { { label = "~/p", path = "/u/p", icon = "p" } },
		disks = {},
	})
	eq(#its, 1)
	eq(rows[1], { type = "title" })
	eq(rows[2], { type = "rule" })
	eq(rows[3], { type = "blank" })
	eq(rows[4], { type = "blank" })
	eq(rows[5], { type = "header", text = "Pinned", icon = "󰐃" })
	eq(rows[6], { type = "rule", inset = true })
	eq(rows[7], { type = "item", index = 1 })
	eq(#rows, 7)
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
t("disk_kind: Apple Silicon reports internal via Device Location", function()
	eq(core.disk_kind("   Protocol:                  Apple Fabric\n   Device Location:           Internal"), "internal")
end)
t("disk_kind: everything else is external", function()
	eq(core.disk_kind("   Protocol:                  USB\n   Internal:                  No"), "external")
end)
t("disk_kind: unparseable output falls back to external", function()
	eq(core.disk_kind(""), "external")
end)

-- volume_name ----------------------------------------------------------------
t("volume_name: extracts the label", function()
	eq(
		core.volume_name("   Device Node:   /dev/disk5s1\n   Volume Name:               work disk image\n"),
		"work disk image"
	)
end)
t("volume_name: missing or inapplicable yields nil", function()
	eq(core.volume_name(""), nil)
	eq(core.volume_name("   Volume Name:               Not applicable (no file system)\n"), nil)
end)

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

-- parse_mounts ---------------------------------------------------------------
local MOUNT_OUTPUT = table.concat({
	"/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)",
	"devfs on /dev (devfs, local, nobrowse)",
	"/dev/disk3s6 on /System/Volumes/VM (apfs, local, noexec, journaled, noatime, nobrowse)",
	"/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse, protect)",
	"map auto_home on /System/Volumes/Data/home (autofs, automounted, nobrowse)",
	"/dev/disk5s1 on /Users/u/Projects/work (apfs, local, nodev, nosuid, journaled, nobrowse, mounted by u)",
	"/dev/disk6s1 on /Volumes/ns test (apfs, local, nodev, nosuid, journaled, mounted by u)",
	"/dev/disk7s1 on /Users/u/odd (dir) name (apfs, local, journaled)",
}, "\n")
t("parse_mounts: keeps only custom /dev mounts outside the system paths", function()
	eq(core.parse_mounts(MOUNT_OUTPUT), { "/Users/u/Projects/work", "/Users/u/odd (dir) name" })
end)
t("parse_mounts: empty input yields nothing", function()
	eq(core.parse_mounts(""), {})
end)
t("parse_mounts: Data-firmlink mountpoints fold back onto the visible namespace", function()
	local text = table.concat({
		"/dev/disk5s1 on /System/Volumes/Data/Users/u/Projects/work (apfs, local, journaled, mounted by u)",
		"/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse, protect)",
		"/dev/disk6s1 on /Users/u/Projects/work (apfs, local, journaled, mounted by u)",
	}, "\n")
	eq(core.parse_mounts(text), { "/Users/u/Projects/work" })
end)
