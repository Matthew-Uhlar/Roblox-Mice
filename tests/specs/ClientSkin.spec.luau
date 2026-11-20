-- UI skin (UI/Skin, UI/SkinMath): pure helpers and the generated slice data
-- (scripts/make-ui-textures.py -> assets/ui/slices.json + UI/SkinSlices.luau).
local T = require("../lib/Test")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local SkinMath = require("../../src/client/UI/SkinMath")
local SkinSlices = require("../../src/client/UI/SkinSlices")

T.describe("SkinSlices", function()
	T.it("mirrors assets/ui/slices.json exactly", function()
		local json = serde.decode("json", fs.readFile("assets/ui/slices.json"))
		local n = 0
		for name, s in json do
			n += 1
			local l = SkinSlices.slices[name]
			T.truthy(l, name .. " in SkinSlices")
			T.deepEq(l.size, s.size, name .. " size")
			T.deepEq(l.center, s.center, name .. " center")
			T.deepEq(l.pad, s.pad, name .. " pad")
			T.near(l.scale, s.scale, 1e-6, name .. " scale")
		end
		local m = 0
		for _ in SkinSlices.slices do
			m += 1
		end
		T.eq(m, n, "same entry count")
	end)
	T.it("every texture exists, is listed in the manifest as an Image, and has sane slices", function()
		local manifest = serde.decode("json", fs.readFile("assets/models/manifest.json"))
		local entries = if manifest.assets then manifest.assets else manifest
		local byName = {}
		for _, e in entries do
			byName[e.name] = e
		end
		for _, name in SkinSlices.names do
			T.truthy(fs.isFile("assets/ui/" .. name .. ".png"), name .. ".png")
			local e = byName[name]
			T.truthy(e and e.type == "Image", name .. " in manifest as Image")
			T.eq(e and e.path, "../ui/" .. name .. ".png", name .. " path")
		end
		for name, s in SkinSlices.slices do
			local c, sz = s.center, s.size
			T.truthy(c[1] < c[3] and c[2] < c[4], name .. " centre is a rect")
			T.truthy(c[3] <= sz[1] and c[4] <= sz[2], name .. " centre inside the texture")
			T.truthy(s.pad[1] < c[1] and s.pad[2] < c[2], name .. " pad outside the centre")
		end
	end)
end)

T.describe("Set 2 (ui2_)", function()
	T.it("every Theme texture has a set-2 twin except icons, emblems and set-1 extras", function()
		local names = {}
		for _, n in SkinSlices.names do
			names[n] = true
		end
		T.truthy(names.ui2_panel, "the set-2 marker exists")
		local setOneOnly = { ui_pattern_cheese = true, ui_wood_strip = true }
		for _, n in SkinSlices.names do
			if string.sub(n, 1, 3) == "ui_" and not setOneOnly[n] then
				local icon = string.sub(n, 1, 8) == "ui_icon_" or string.sub(n, 1, 9) == "ui_class_"
				if not icon then
					T.truthy(names["ui2_" .. string.sub(n, 4)], n .. " has a ui2 twin")
				end
			end
		end
		for _, n in { "ui2_dock", "ui2_input", "ui2_input_focus", "ui2_btn_primary_sq_pressed" } do
			T.truthy(names[n], n)
		end
	end)
end)

T.describe("SkinMath", function()
	T.it("picks button textures from the Theme colours", function()
		T.eq(SkinMath.buttonTexture(255, 204, 51, "Buy"), "ui_btn_primary")
		T.eq(SkinMath.buttonTexture(238, 222, 184, "Details"), "ui_btn_secondary")
		T.eq(SkinMath.buttonTexture(226, 72, 58, "Leave"), "ui_btn_danger")
		T.eq(SkinMath.buttonTexture(226, 72, 58, "✕"), "ui_close")
		T.eq(SkinMath.buttonTexture(96, 190, 92, "R$ 99"), "ui_btn_robux")
		T.eq(SkinMath.buttonTexture(255, 140, 40, "✨ 50"), "ui_btn_tint")
		T.eq(SkinMath.buttonTexture(255, 204, 51, "Featured", "tab"), "ui_tab_active")
		T.eq(SkinMath.buttonTexture(238, 222, 184, "Boosts", "tab"), "ui_tab_inactive")
		T.eq(SkinMath.stateTexture("ui_btn_primary", "hover"), "ui_btn_primary_hover")
		T.eq(SkinMath.stateTexture("ui_tab_active", "pressed"), "ui_tab_active")
		T.eq(SkinMath.stateTexture("ui_close", "normal"), "ui_close")
	end)
	T.it("every texture it can pick exists", function()
		local names = {}
		for _, n in SkinSlices.names do
			names[n] = true
		end
		for base in SkinMath.HAS_STATES do
			for _, st in { "normal", "hover", "pressed" } do
				local n = SkinMath.stateTexture(base, st)
				-- a ui_ name is drawn from set 1 or from its set-2 twin (Skin.resolve)
				local twin = "ui2_" .. string.sub(n, 4)
				T.truthy(names[n] or names[twin], base .. " " .. st)
			end
		end
		for _, e in SkinMath.EMOJI do
			T.truthy(names[e[2]], e[2])
		end
		for _, v in SkinMath.ICON_KINDS do
			T.truthy(names[v], v)
		end
		for _, r in { "Common", "Uncommon", "Rare", "Epic", "Legendary", "?" } do
			T.truthy(names[(SkinMath.rarityTexture(r))], r)
		end
		for _, cls in { "elephante", "ele_fonte", "ellie_fawn", "le_fante", "filet", "jumbo", "fizzante" } do
			T.truthy(names["ui_class_" .. cls], cls .. " emblem")
		end
	end)
	T.it("slice scale fits small objects and is smaller on dense screens", function()
		local b = SkinSlices.slices.ui_btn_primary
		local big = SkinMath.sliceScale(b, 400, 200, false)
		T.near(big, b.scale, 1e-6)
		T.truthy(SkinMath.sliceScale(b, 400, 200, true) < big, "dense is smaller")
		local small = SkinMath.sliceScale(b, 220, 34, false)
		local bc, bs, bp = b.center, b.size, b.pad
		local borders = (bc[2] - bp[2]) + (bs[2] - bc[4] - bp[4])
		T.truthy(small * borders <= 34 * 0.9 + 1e-6, "borders fit a 34 px button")
		local x, y, ew, eh = SkinMath.frameRect(b, 0.5)
		T.near(x, -bp[1] * 0.5, 1e-6)
		T.near(y, -bp[2] * 0.5, 1e-6)
		T.near(ew, (bp[1] + bp[3]) * 0.5, 1e-6)
		T.near(eh, (bp[2] + bp[4]) * 0.5, 1e-6)
	end)
	T.it("splits a leading emoji into an icon", function()
		local icon, rest = SkinMath.splitIcon("🧀 1.2K")
		T.eq(icon, "ui_icon_cheese")
		T.eq(rest, "1.2K")
		icon, rest = SkinMath.splitIcon("R$ 99")
		T.eq(icon, "ui_icon_coin")
		T.eq(rest, "99")
		icon, rest = SkinMath.splitIcon("✔ Owned")
		T.eq(icon, "ui_icon_check")
		T.eq(rest, "Owned")
		icon = SkinMath.splitIcon("🧀Cheese")
		T.eq(icon, nil, "no space: not an icon prefix")
		icon = SkinMath.splitIcon("Buy 🧀 5")
		T.eq(icon, nil, "only leading tokens")
		icon = SkinMath.splitIcon("🧀 5\nmore")
		T.eq(icon, nil, "multi-line keeps the emoji")
	end)
end)

return T.finish()
