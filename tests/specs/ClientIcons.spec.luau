-- Animated icons (owner: "custom animated icons on all menu items and shop
-- items"): the generated atlas index (scripts/make-icons.py ->
-- UI/IconAtlas + assets/icons), the menu / item map (UI/IconMap), the pure
-- frame / motion maths (UI/IconMath) and, in the runtime emulator, the real
-- client with the atlases "uploaded": decorated buttons, shop cards, the
-- shared driver, the Effects setting and the no-id fallback.
local T = require("../lib/Test")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local IconAtlas = require("../../src/client/UI/IconAtlas")
local IconMap = require("../../src/client/UI/IconMap")
local IconMath = require("../../src/client/UI/IconMath")
local Monetization = require("../../src/shared/Config/Monetization")
local RunShop = require("../../src/shared/Config/RunShop")
local Talents = require("../../src/shared/Config/Talents")
local Shop = require("../../src/shared/Config/Shop")
local Cosmetics = require("../../src/shared/Config/Cosmetics")

local function pngSize(path: string): (number, number)
	local b = fs.readFile(path)
	local function u32(i: number): number
		local a, c, d, e = string.byte(b, i, i + 3)
		return ((a * 256 + c) * 256 + d) * 256 + e
	end
	return u32(17), u32(21)
end

T.describe("IconAtlas (generated)", function()
	T.it("every atlas exists, is <= 1024 px, is in the manifest as an Image", function()
		local manifest = serde.decode("json", fs.readFile("assets/models/manifest.json"))
		local entries = if manifest.assets then manifest.assets else manifest
		local byName = {}
		for _, e in entries do
			byName[e.name] = e
		end
		T.truthy(#IconAtlas.atlases >= 1, "at least one atlas")
		for _, name in IconAtlas.atlases do
			T.eq(string.sub(name, 1, 5), "icon_", name .. " uses the icon_ prefix")
			local path = "assets/icons/" .. name .. ".png"
			T.truthy(fs.isFile(path), path)
			local w, h = pngSize(path)
			T.eq(w, IconAtlas.size, name .. " width")
			T.eq(h, IconAtlas.size, name .. " height")
			T.truthy(w <= 1024 and h <= 1024, name .. " <= 1024")
			local e = byName[name]
			T.truthy(e and e.type == "Image", name .. " in the manifest as an Image")
			T.eq(e and e.path, "../icons/" .. name .. ".png", name .. " path")
		end
	end)

	T.it("every frame rect and the glow sprite stay inside their atlas", function()
		local n = 0
		local cell = IconAtlas.cell
		for key, e in IconAtlas.icons do
			n += 1
			T.truthy(table.find(IconAtlas.atlases, e.atlas), key .. " atlas listed")
			T.truthy(e.frames >= 1, key .. " frames")
			for i = 0, e.frames - 1 do
				local x, y = IconMath.rect(e, i, cell)
				T.truthy(x >= 0 and y >= 0, key .. " rect >= 0")
				T.truthy(x + cell <= IconAtlas.size and y + cell <= IconAtlas.size, key .. " rect inside")
			end
			-- out-of-range frames clamp
			local cx = IconMath.rect(e, 99, cell)
			T.truthy(cx + cell <= IconAtlas.size, key .. " clamped rect inside")
			T.truthy(e.fps >= 0 and e.fps <= 12, key .. " modest fps")
		end
		T.truthy(n >= 80, "a full icon set (" .. n .. ")")
		local g = IconAtlas.glow
		T.truthy(g.x + cell <= IconAtlas.size and g.y + cell <= IconAtlas.size, "glow inside")
		-- no icon overlaps the glow slot or another icon
		local used = {}
		for key, e in IconAtlas.icons do
			for i = 0, math.max(4, e.frames) - 1 do
				local x, y = IconMath.rect({ x = e.x, y = e.y, frames = 4 } :: any, i, cell)
				local id = e.atlas .. ":" .. x .. "," .. y
				T.falsy(used[id], key .. " cell free")
				used[id] = true
				T.falsy(x == g.x and y == g.y, key .. " not on the glow cell")
			end
		end
	end)
end)

T.describe("IconMap", function()
	T.it("every menu key maps to an atlas icon", function()
		T.truthy(#IconMap.MENU_KEYS >= 40, "menu keys")
		for _, k in IconMap.MENU_KEYS do
			local icon = IconMap.menu(k)
			T.truthy(icon and IconAtlas.icons[icon], k .. " -> " .. tostring(icon))
		end
	end)

	T.it("every shop item of the live configs maps (explicitly) to an atlas icon", function()
		local function check(kind: string, id: any)
			local icon = IconMap.explicit(kind, id)
			T.truthy(icon and IconAtlas.icons[icon], kind .. ":" .. tostring(id) .. " -> " .. tostring(icon))
		end
		local items = 0
		for _, it in Monetization.ALL do
			check("product", it.key)
			items += 1
		end
		T.truthy(items >= 20, "Robux passes / products")
		for _, slot in Cosmetics.SLOTS do
			check("cosmetic", slot)
		end
		for _, slot in { "hat", "trail", "tint", "skin" } do
			check("cosmetic", slot)
		end
		for id in Talents.defs do
			check("talent", id)
		end
		for id in Shop.BUNDLES do
			check("bundle", id)
		end
		for id in RunShop.RANKS do
			check("rank", id)
		end
		for id in RunShop.BUFFS do
			check("buff", id)
		end
		for id in RunShop.CLASS_BUFFS do
			check("classBuff", id)
		end
		for id in RunShop.ULTIMATES do
			check("ultimate", id)
		end
		check("swap", "toWhey")
		check("skin", "any")
		for _, slot in { "weapon", "armor", "trinket" } do
			check("gear", slot)
		end
	end)

	T.it("unknown ids still get a family icon (new configs never crash)", function()
		T.eq(IconMap.item("product", "golden_xxl"), "golden_m")
		T.eq(IconMap.item("product", "mystery"), "passes")
		T.eq(IconMap.item("buff", "new_buff"), "class_buff")
		T.eq(IconMap.item("nope", "x"), nil)
		T.eq(IconMap.menu("nope"), nil)
	end)
end)

T.describe("IconMath", function()
	local shine = IconAtlas.icons.hero
	local loop = IconAtlas.icons.settings
	T.it("Effects off: static first frame, no motion, no glow", function()
		for t = 0, 10, 0.37 do
			T.eq(IconMath.frame(shine, t, "off", 0), 0, "shine off")
			T.eq(IconMath.frame(loop, t, "off", 0), 0, "loop off")
			local dy, s, r = IconMath.motion(shine, t, "off", 0)
			T.eq(dy, 0)
			T.eq(s, 1)
			T.eq(r, 0)
		end
		local _, glowOff = IconMath.react("hover", "off")
		T.eq(glowOff, 1, "no glow with Effects off")
	end)

	T.it("Effects full: frames cycle and stay in range; reduced is slower with no idle motion", function()
		local seen = {}
		for t = 0, 4, 0.05 do
			local f = IconMath.frame(loop, t, "full", 0)
			T.truthy(f >= 0 and f < loop.frames, "in range")
			seen[f] = true
		end
		T.truthy(seen[0] and seen[1] and seen[loop.frames - 1], "loop visits every frame")
		local changesFull, changesReduced = 0, 0
		local pf, pr = -1, -1
		for t = 0, 6, 0.01 do
			local f = IconMath.frame(loop, t, "full", 0)
			local r = IconMath.frame(loop, t, "reduced", 0)
			if f ~= pf then
				changesFull += 1
			end
			if r ~= pr then
				changesReduced += 1
			end
			pf, pr = f, r
		end
		T.truthy(changesReduced < changesFull * 0.6, "reduced steps slower")
		local bobbed = false
		for t = 0, 3, 0.1 do
			local dy, s, r = IconMath.motion(shine, t, "reduced", 0)
			T.truthy(dy == 0 and s == 1 and r == 0, "no idle motion when reduced")
			local fdy, fs, fr = IconMath.motion(shine, t, "full", 0)
			if fdy ~= 0 or fs ~= 1 or fr ~= 0 then
				bobbed = true
			end
		end
		T.truthy(bobbed, "full has idle motion")
	end)

	T.it("shine sweeps then holds the clean frame most of the time", function()
		local clean, total = 0, 0
		for t = 0, 20, 0.02 do
			total += 1
			if IconMath.frame(shine, t, "full", 0) == 0 then
				clean += 1
			end
		end
		T.truthy(clean / total > 0.7, "mostly frame 0")
		T.truthy(clean < total, "but it does sweep")
	end)

	T.it("hover grows, press shrinks; stripLead drops only a leading emoji", function()
		T.truthy(IconMath.react("hover", "full") > 1)
		T.truthy(IconMath.react("pressed", "full") < 1)
		T.eq(IconMath.react("normal", "full"), 1)
		T.eq(IconMath.stripLead("🛒 Shop"), "Shop")
		T.eq(IconMath.stripLead("⚙"), "")
		T.eq(IconMath.stripLead("Ranks"), "Ranks")
		T.eq(IconMath.stripLead("🎁 Claim daily (day 2)"), "Claim daily (day 2)")
		T.eq(IconMath.stripLead("★ Featured"), "Featured")
		T.eq(IconMath.stripLead(""), "")
	end)

	T.it("no ids: no atlas id (UI keeps its emoji)", function()
		T.eq(IconMath.atlasId(shine, {}), nil)
		T.eq(IconMath.atlasId(shine, { [shine.atlas] = 0 }), nil)
		T.eq(IconMath.atlasId(shine, { [shine.atlas] = 42 }), 42)
		T.eq(IconMath.atlasId(nil, { x = 1 }), nil)
	end)
end)

----------------------------------------------------------------------
-- Runtime: the real client, set 2 skin uploaded; icons first missing
-- (fallback), then "uploaded" through Skin.setIds.
----------------------------------------------------------------------

local Runtime = require("../runtime/Runtime")
local Driver = require("../runtime/Driver")
local Inst = require("../runtime/Instance")
local SkinSlices = require("../../src/client/UI/SkinSlices")

local rt = Runtime.new({ root = ".", dt = 1 / 30 })
do
	local lines = { "return {" }
	for i, name in SkinSlices.names do
		table.insert(lines, string.format("\t[%q] = %d,", name, 90000 + i))
	end
	table.insert(lines, "}")
	local mod = rt:find("ReplicatedStorage.Shared.Config.AssetIds")
	local d = Inst.D[mod]
	d.extra.source = table.concat(lines, "\n")
	d.extra.path = d.extra.path .. "#icons" -- own compile-cache key
end
rt:startServer()
rt:advance(1)

local function as(client: any, fn: () -> ())
	local prev = rt.S.current
	rt.S.current = client
	local ok, err = pcall(fn)
	rt.S.current = prev
	if not ok then
		error(err, 0)
	end
end

local function animIcons(root: any): { any }
	local out = {}
	for _, x in root:GetDescendants() do
		if x.Name == "AnimIcon" then
			table.insert(out, x)
		end
	end
	return out
end

T.describe("ClientIcons runtime", function()
	local c
	local AnimatedIcon, Skin
	T.it("no atlas ids: the lobby looks exactly as before (emoji captions, no icons)", function()
		local _
		_, c = rt:addPlayer({ userId = 8201, name = "Iconic" })
		rt:advance(6)
		AnimatedIcon = rt:clientModule(c, "Client.UI.AnimatedIcon")
		Skin = rt:clientModule(c, "Client.UI.Skin")
		local shopB = Driver.findButton(rt, c, "TrunkfallLobby", "Shop")
		as(c, function()
			T.truthy(shopB, "shop button")
			T.eq(shopB:GetAttribute("AnimIcon"), "shop", "decorated")
			T.eq(shopB.SkinContent.Label.Text, "🛒 Shop", "emoji kept while not uploaded")
			T.eq(#animIcons(rt:playerGui(c)), 0, "no animated icons")
			T.eq(AnimatedIcon.count(), 0, "driver idle")
		end)
		rt:assertClean(nil, "fallback lobby")
	end)

	T.it("atlases uploaded: dock buttons and toggles show animated icons, frames step", function()
		as(c, function()
			local ids = {}
			for i, name in SkinSlices.names do
				ids[name] = 90000 + i
			end
			for i, name in IconAtlas.atlases do
				ids[name] = 70000 + i
			end
			Skin.setIds(ids)
			AnimatedIcon.setFx("full")
			T.truthy(AnimatedIcon.refresh() >= 6, "dock buttons re-decorated")
		end)
		rt:advance(1)
		local shopB = Driver.findButton(rt, c, "TrunkfallLobby", "Shop")
		local settingsB = Driver.findButton(rt, c, "TrunkfallLobby", "⚙")
		as(c, function()
			local content = shopB.SkinContent
			local icon = content:FindFirstChild("AnimIcon")
			T.truthy(icon, "shop button has an animated icon")
			T.eq(icon:GetAttribute("IconKey"), "shop")
			T.eq(content.Label.Text, "Shop", "emoji replaced by the icon")
			T.falsy(content.Icon.Visible, "texture icon slot hidden")
			T.eq(
				icon.Sprite.Image,
				"rbxassetid://" .. (70000 + table.find(IconAtlas.atlases, IconAtlas.icons.shop.atlas))
			)
			T.truthy(settingsB and settingsB.SkinContent:FindFirstChild("AnimIcon"), "icon-only ⚙ button")
			T.falsy(settingsB.SkinContent.Label.Visible, "no empty label beside a lone icon")
			T.truthy(AnimatedIcon.count() >= 6, "registered")
			-- the shared driver steps the cog's frames
			local cog = settingsB.SkinContent.AnimIcon.Sprite
			local seen = {}
			for _ = 1, 40 do
				AnimatedIcon.step(1 / 20)
				seen[cog.ImageRectOffset.X] = true
			end
			local n = 0
			for _ in seen do
				n += 1
			end
			T.truthy(n >= 3, "cog frames step (" .. n .. ")")
			-- Effects off: static first frame
			AnimatedIcon.setFx("off")
			AnimatedIcon.step(0.2)
			local e = IconAtlas.icons.settings
			T.eq(cog.ImageRectOffset.X, e.x, "off -> frame 0")
			T.eq(cog.Rotation, 0, "off -> no motion")
			AnimatedIcon.setFx("full")
		end)
		rt:assertClean(nil, "icons lobby")
	end)

	T.it("shop: tabs, robux rows and cards get icons; closing and reopening does not leak", function()
		rt:click(c, Driver.findButton(rt, c, "TrunkfallLobby", "Shop"))
		rt:advance(0.5)
		local tab = Driver.findButton(rt, c, "TrunkfallShop", "Cosmetics")
		T.truthy(tab, "Cosmetics tab")
		local before
		as(c, function()
			T.truthy(tab.SkinContent:FindFirstChild("AnimIcon"), "shop tab icon")
			local shop = rt:playerGui(c):FindFirstChild("TrunkfallShop")
			T.truthy(#animIcons(shop) >= 8, "featured cards / tabs have icons")
		end)
		rt:click(c, tab)
		rt:advance(0.5)
		local passes = Driver.findButton(rt, c, "TrunkfallShop", "Passes")
		rt:click(c, passes)
		rt:advance(0.5)
		as(c, function()
			before = AnimatedIcon.count()
		end)
		-- re-render the same tab a few times: old cards are destroyed with their icons
		for _ = 1, 3 do
			rt:click(c, Driver.findButton(rt, c, "TrunkfallShop", "Passes"))
			rt:advance(0.5)
		end
		as(c, function()
			T.eq(AnimatedIcon.count(), before, "no leaked icons after re-renders")
		end)
		rt:click(c, Driver.findButton(rt, c, "TrunkfallShop", "✕"))
		rt:advance(1)
		rt:assertClean(nil, "icons shop")
	end)
end)

return T.finish()
