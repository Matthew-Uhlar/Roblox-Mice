-- Scratch spec (copy to tests/specs/ to keep). Pure maths of src/client/Util/Layout
-- plus a coverage check: every Fx `t` the server emits has a client handler.
local T = require("../lib/Test")
local Layout = require("../../src/client/Util/Layout")
local fs = require("@lune/fs")

-- Safe viewport = raw minus the 58 px top bar (QC2 used ~667x317 for an SE).
local TOPBAR = 58
local cases = {
	{ name = "iPhone SE 667x375", w = 667, h = 375, touch = true },
	{ name = "Android 740x360", w = 740, h = 360, touch = true },
	{ name = "PC 1920x1080", w = 1920, h = 1080, touch = false },
}

T.describe("Layout", function()
	for _, c in cases do
		T.it(c.name, function()
			local w, h = Layout.safeViewport(c.w, c.h, 0, TOPBAR, 0, 0)
			local m = Layout.metrics(w, h, c.touch)
			print(
				string.format(
					"  %s: safe %dx%d scale %.3f root %.0fx%.0f touch %d design = %.1f px",
					c.name,
					w,
					h,
					m.scale,
					m.rootW,
					m.rootH,
					m.touch,
					m.touchPx
				)
			)
			-- the whole 1100x620 design area fits (no overflow)
			T.truthy(
				m.rootW >= Layout.DESIGN_W - 0.01 and m.rootH >= Layout.DESIGN_H - 0.01,
				"design area fits"
			)
			T.truthy(
				math.abs(m.rootW * m.scale - w) < 0.01 and math.abs(m.rootH * m.scale - h) < 0.01,
				"root maps to viewport"
			)
			-- touch targets: >= 48 px on touch, never below the 70 design px base
			if c.touch then
				T.truthy(m.touchPx >= 48 - 1e-6, "touch >= 48 px")
			end
			T.truthy(m.touch >= Layout.BASE_TOUCH, "touch >= base")
			-- lobby bar (1040 wide, touch + 30 tall) and results panel fit
			T.truthy(1040 <= m.rootW - 28, "lobby bar fits")
			T.truthy(m.touch + 30 + 14 < m.rootH / 3, "lobby bar under a third of the height")
			T.truthy(330 + (m.touch + 18) <= m.rootH - 20, "results panel fits uncapped")
		end)
	end
	T.it("SE scale is the fitted ~0.51, not the old 0.7 floor", function()
		local w, h = Layout.safeViewport(667, 375, 0, TOPBAR, 0, 0)
		local s = Layout.fitScale(w, h)
		T.truthy(s > 0.5 and s < 0.52)
	end)
	T.it("PC scale caps at 1.5 and keeps the 70 px base", function()
		T.eq(Layout.fitScale(1920, 1022), 1.5)
		T.eq(Layout.touchSize(1.5, false), 70)
	end)
	T.it("cap clamps to available minus margins", function()
		T.eq(Layout.cap(500, 400, 10), 380)
		T.eq(Layout.cap(300, 400, 10), 300)
		T.eq(Layout.cap(300, 10, 10), 0)
	end)
	T.it("degenerate sizes are safe", function()
		T.eq(Layout.fitScale(0, 0), 1)
		T.eq(Layout.fitScale(10, 10), Layout.MIN_SCALE)
		T.truthy(Layout.touchSize(Layout.MIN_SCALE, true) <= Layout.MAX_TOUCH)
	end)
end)

T.describe("Fx coverage", function()
	T.it("every emitted Fx t has a client handler", function()
		local fx = fs.readFile("src/client/Controllers/FxController.luau")
		local block = string.match(fx, "local handlers: { %[string%]: %(any%) %-> %(%) } = {(.-)\n}\n")
		assert(block, "handlers table not found")
		local handled = {}
		for k in string.gmatch(block, "\n\t([%a]+) = ") do
			handled[k] = true
		end
		-- Loot bags and ground gear need a real in-world visual (QC-A M2): a
		-- minimap dot or a HUD line does not count for these kinds.
		local WORLD_VISUAL = { "bag", "bagProgress", "bagGone", "gear", "gearGone" }
		local noWorld = {}
		for _, t in WORLD_VISUAL do
			if not handled[t] then
				table.insert(noWorld, t)
			end
		end
		T.eq(#noWorld, 0, "FxController has no world visual for: " .. table.concat(noWorld, ", "))
		-- HUD / minimap modules consume some other Fx (POI ring, carriers, spawn
		-- protection): they listen to Net.S2C.Fx and branch on `t == "<kind>"`.
		local worldSet = {}
		for _, t in WORLD_VISUAL do
			worldSet[t] = true
		end
		for _, f in { "src/client/UI/HudUI.luau", "src/client/UI/MinimapUI.luau" } do
			for t in string.gmatch(fs.readFile(f), 't == "(%a+)"') do
				if not worldSet[t] then
					handled[t] = true
				end
			end
		end
		local missing = {}
		for _, f in
			{
				"src/shared/Combat/World.luau",
				"src/shared/Combat/BossPatterns.luau",
				"src/shared/Combat/Weapons.luau",
				"src/shared/Combat/Pois.luau",
			}
		do
			local src = fs.readFile(f)
			for t in string.gmatch(src, 't = "(%a+)"') do
				if t ~= "all" and t ~= "self" then -- target selectors, not Fx
					if not handled[t] then
						missing[t] = true
					end
				end
			end
		end
		local list = {}
		for k in missing do
			table.insert(list, k)
		end
		table.sort(list)
		local hl = {}
		for k in handled do
			table.insert(hl, k)
		end
		table.sort(hl)
		print("  handled: " .. table.concat(hl, ", "))
		T.eq(#list, 0, "missing: " .. table.concat(list, ", "))
	end)
end)

T.describe("Layout.textSize (readable text on phones)", function()
	T.it("14 px design text renders >= 12 screen px on a 667x375 phone", function()
		local m = Layout.metrics(667, 375 - 58, true)
		local size = Layout.textSize(14, m.scale, true)
		T.truthy(size * m.scale >= 12 - 1e-6, "rendered " .. size * m.scale)
	end)
	T.it("never shrinks and never more than doubles", function()
		T.eq(Layout.textSize(30, 1.5, true), 30)
		T.truthy(Layout.textSize(10, 0.3, true) <= 20)
	end)
end)

return T.finish()
