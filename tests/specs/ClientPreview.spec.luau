-- Iteration 6 (team Preview): the cosmetic showroom and its icons.
-- Pure part: every cosmetic id (trails, hats, tints, class skins, Ascension looks,
-- titles, dyes, chat tags, Prestige frames) resolves to a preview recipe and an
-- icon entry; outfits, the Effects setting and the phone layout.
-- Runtime part (tests/runtime): the real client builds the showroom with NO asset
-- ids uploaded, shows every kind of item, pauses / releases / destroys cleanly
-- (no instances left behind), and Effects "off" stops all motion.
local T = require("../lib/Test")
local PreviewRecipe = require("../../src/client/Util/PreviewRecipe")
local Cosmetics = require("../../src/shared/Config/Cosmetics")
local ClassSkins = require("../../src/shared/Config/ClassSkins")
local Looks = require("../../src/shared/Data/Looks")
local Ascension = require("../../src/shared/Config/Ascension")

local cfg = { Cosmetics = Cosmetics, ClassSkins = ClassSkins, Looks = Looks, Ascension = Ascension }

-- the icon atlas index, once scripts/make-cosmetic-icons.py has run (optional)
local okAtlas, Atlas = pcall(require, "../../src/client/UI/CosmeticIconAtlas")
if not okAtlas then
	Atlas = nil
end

T.describe("PreviewRecipe: every cosmetic has a recipe and an icon", function()
	local refs = PreviewRecipe.allRefs(cfg)

	T.it("lists every cosmetic, skin, look, title, dye, chat tag and frame", function()
		local seen = {}
		for _, r in refs do
			T.falsy(seen[r], "duplicate ref " .. r)
			seen[r] = true
		end
		for _, def in Cosmetics.LIST do
			T.truthy(seen["cosmetic:" .. def.id], def.id)
		end
		for _, def in ClassSkins.LIST do
			T.truthy(seen["skin:" .. def.id], def.id)
		end
		for k in Cosmetics.TITLES do
			T.truthy(seen["title:" .. k], k)
		end
		for k in Cosmetics.EARNED_TITLES do
			T.truthy(seen["title:" .. k], k)
		end
		for k in Cosmetics.DYES do
			T.truthy(seen["dye:" .. k], k)
		end
		for k in Cosmetics.CHAT_TAGS do
			T.truthy(seen["chattag:" .. k], k)
		end
		for _, n in Ascension.FRAMES do
			T.truthy(seen["frame:p" .. n], "frame p" .. n)
		end
		T.truthy(seen["frame:wheel"] and seen["look:base"] and seen["look:ancient"], "wheel + looks")
	end)

	T.it("resolves every ref to a drawable recipe", function()
		for _, ref in refs do
			local r = PreviewRecipe.resolve(ref, cfg)
			T.truthy(r, "recipe for " .. ref)
			if r then
				T.eq(r.ref, ref)
				T.truthy(type(r.name) == "string" and #r.name > 0, "name " .. ref)
				T.truthy(r.focus == "body" or r.focus == "head" or r.focus == "feet" or r.focus == "name")
				if r.slot == "hat" then
					T.truthy(r.hat and Cosmetics.HAT_SHAPES[r.hat.shape], "hat shape " .. ref)
				elseif r.slot == "trail" then
					T.truthy(
						r.trail and #r.trail.color == 3 and #r.trail.color2 == 3,
						"trail colours " .. ref
					)
				elseif r.slot == "tint" then
					T.truthy(r.tint and #r.tint.color == 3, "tint colour " .. ref)
				elseif r.slot == "skin" then
					T.truthy(r.classId and r.skinId == r.id, "skin class " .. ref)
				elseif r.slot == "title" then
					T.truthy(r.title and #r.title.text > 0, "title " .. ref)
				elseif r.slot == "dye" then
					T.truthy(r.nameColor, "dye " .. ref)
				elseif r.slot == "chattag" then
					T.truthy(r.chatTag, "chat tag " .. ref)
				elseif r.slot == "frame" then
					T.truthy(r.frame and r.frame.key == r.id, "frame " .. ref)
				else
					T.eq(r.slot, "look", "known slot " .. ref)
				end
			end
		end
	end)

	T.it("matches the server's look resolver for trails, hats and tints", function()
		for _, def in Cosmetics.LIST do
			local r = PreviewRecipe.resolve("cosmetic:" .. def.id, cfg)
			local look = Looks.resolve({ [def.slot] = def.id }, { [def.id] = true })
			local want = (look :: any)[def.slot]
			local got = r and (r :: any)[def.slot]
			T.truthy(want and got, def.id)
			if want and got then
				for k, v in want do
					if type(v) == "table" then
						T.eq(table.concat(got[k], ","), table.concat(v, ","), def.id .. "." .. k)
					else
						T.eq(got[k], v, def.id .. "." .. k)
					end
				end
			end
		end
	end)

	T.it("gives every ref a unique icon_cos_ entry", function()
		local names = {}
		for _, ref in refs do
			local n = PreviewRecipe.iconName(ref)
			T.eq(string.sub(n, 1, 9), "icon_cos_", ref)
			T.truthy(string.match(n, "^[%w_]+$"), "asset-safe name " .. n)
			T.falsy(names[n], "icon name clash " .. n .. " (" .. ref .. ")")
			names[n] = ref
			local r = PreviewRecipe.resolve(ref, cfg)
			T.eq(r and r.icon, n, "recipe icon " .. ref)
			-- rendered kinds come from the atlas once it is generated
			local kind = PreviewRecipe.split(ref)
			if Atlas and PreviewRecipe.RENDERED[kind :: string] then
				T.truthy(Atlas.rects[n], "atlas cell for " .. n)
			end
		end
	end)

	T.it("accepts bare ids and refuses junk", function()
		T.eq((PreviewRecipe.resolve("hat_party", cfg) :: any).ref, "cosmetic:hat_party")
		T.eq((PreviewRecipe.resolve("elephante_gilded", cfg) :: any).ref, "skin:elephante_gilded")
		T.eq(PreviewRecipe.resolve("nope", cfg), nil)
		T.eq(PreviewRecipe.resolve("cosmetic:nope", cfg), nil)
		T.eq(PreviewRecipe.resolve("frame:p3", cfg), nil)
		T.eq(PreviewRecipe.resolve("look:dragon", cfg), nil)
		T.eq(PreviewRecipe.resolve(nil, cfg), nil)
		T.eq(PreviewRecipe.resolve(42, cfg), nil)
	end)
end)

T.describe("PreviewRecipe outfits", function()
	local base = {
		classId = "jumbo",
		skinId = "jumbo_aviator",
		ascLook = "bull",
		hat = (PreviewRecipe.resolve("cosmetic:hat_party", cfg) :: any).hat,
		focus = "body",
	}
	T.it("tries one slot on and keeps the rest", function()
		local o = PreviewRecipe.outfit(base :: any, PreviewRecipe.resolve("cosmetic:trail_lava", cfg))
		T.eq(o.classId, "jumbo")
		T.eq(o.skinId, "jumbo_aviator")
		T.eq(o.hat and o.hat.id, "hat_party")
		T.eq(o.trail and o.trail.id, "trail_lava")
		T.eq(o.focus, "feet")
		T.eq(o.tried, "cosmetic:trail_lava")
		local h = PreviewRecipe.outfit(base :: any, PreviewRecipe.resolve("cosmetic:hat_wizard", cfg))
		T.eq(h.hat and h.hat.id, "hat_wizard")
		T.eq(h.focus, "head")
	end)
	T.it("a skin of another class shows that class without your Ascension look", function()
		local o = PreviewRecipe.outfit(base :: any, PreviewRecipe.resolve("skin:filet_neon", cfg))
		T.eq(o.classId, "filet")
		T.eq(o.skinId, "filet_neon")
		T.eq(o.ascLook, nil)
		local same = PreviewRecipe.outfit(base :: any, PreviewRecipe.resolve("skin:jumbo_neon", cfg))
		T.eq(same.ascLook, "bull")
	end)
	T.it("looks, titles, dyes, tags and frames", function()
		T.eq(PreviewRecipe.outfit(base :: any, PreviewRecipe.resolve("look:ancient", cfg)).ascLook, "ancient")
		T.eq(PreviewRecipe.outfit(base :: any, PreviewRecipe.resolve("look:base", cfg)).ascLook, nil)
		local t = PreviewRecipe.outfit(base :: any, PreviewRecipe.resolve("title:title_legend", cfg))
		T.eq(t.title and t.title.text, "Living Legend")
		local d = PreviewRecipe.outfit(base :: any, PreviewRecipe.resolve("dye:mint", cfg))
		T.eq(d.nameColor and d.nameColor[2], 240)
		local c = PreviewRecipe.outfit(base :: any, PreviewRecipe.resolve("chattag:vip", cfg))
		T.eq(c.chatTag and c.chatTag.text, "VIP")
		local f = PreviewRecipe.outfit(base :: any, PreviewRecipe.resolve("frame:p10", cfg))
		T.eq(f.frame and f.frame.prestige, 10)
		T.eq(PreviewRecipe.outfit(base :: any, nil).tried, nil)
	end)
end)

T.describe("PreviewRecipe motion and layout", function()
	T.it("respects the Effects setting", function()
		local off = PreviewRecipe.motion("off")
		T.falsy(off.rotate or off.animate or off.sweep, "off = still")
		T.eq(off.spin, 0)
		local full = PreviewRecipe.motion("full")
		T.truthy(full.rotate and full.animate and full.sweep)
		local red = PreviewRecipe.motion("reduced")
		T.truthy(red.rotate and red.spin < full.spin, "reduced spins slower")
		T.truthy(PreviewRecipe.motion(nil).rotate, "default full")
	end)
	T.it("a side panel on the shop / hero modals, phones included; overlay when narrow", function()
		-- phone 667 x 375: UI scale 0.6, root 1111 x 625 design px; shop modal 1000 x 600
		local shop = PreviewRecipe.panelLayout(1000 - 24, 420)
		T.eq(shop.mode, "side")
		T.truthy(shop.panelW >= 240 and shop.contentW >= PreviewRecipe.MIN_LIST)
		local hero = PreviewRecipe.panelLayout(820 - 24, 400)
		T.eq(hero.mode, "side")
		T.eq(PreviewRecipe.panelLayout(600, 400).mode, "overlay")
		T.eq(PreviewRecipe.panelLayout(1000, 200).mode, "overlay")
	end)
end)

----------------------------------------------------------------------
-- Runtime: the real client builds and tears down the showroom
----------------------------------------------------------------------

local Runtime = require("../runtime/Runtime")
local Inst = require("../runtime/Instance")
local roblox = require("@lune/roblox")
local Instance = { new = Inst.new }
local UDim2 = roblox.UDim2

local rt = Runtime.new({ root = ".", dt = 1 / 30 })
rt:startServer()
rt:advance(1)
local _, client = rt:addPlayer({ userId = 8801, name = "Previewer" })
rt:advance(6)

local function as(fn: () -> ())
	local prev = rt.S.current
	rt.S.current = client
	local ok, err = pcall(fn)
	rt.S.current = prev
	if not ok then
		error(err, 0)
	end
end

local function count(inst: any): number
	local n = 0
	for _ in inst:GetDescendants() do
		n += 1
	end
	return n
end

T.describe("CosmeticPreview (runtime, no asset ids)", function()
	local CP = rt:clientModule(client, "Client.UI.CosmeticPreview")
	local State = rt:clientModule(client, "Client.Controllers.State")
	local gui = rt:playerGui(client)
	local host, panel, before

	T.it("is built lazily: no 3-D view until the first show", function()
		rt:runIn(client, function()
			local sg = Instance.new("ScreenGui")
			sg.Name = "PreviewTest"
			sg.Parent = gui
			host = Instance.new("Frame")
			host.Size = UDim2.fromOffset(300, 420)
			host.Parent = sg
			before = count(sg)
			panel = CP.panel(host, { Size = UDim2.fromScale(1, 1) })
		end)
		as(function()
			T.falsy(host:FindFirstChild("View", true), "no ViewportFrame yet")
			T.falsy(panel.showroom.isBuilt())
		end)
	end)

	T.it("shows the hero with the shared builder and every kind of item", function()
		as(function()
			local hv = rt.game:GetService("ReplicatedStorage"):FindFirstChild("HeroVisuals")
			T.truthy(hv and hv:FindFirstChild("BotModel"), "Boot copied the hero builders")
		end)
		rt:runIn(client, function()
			panel.setActive(true)
		end)
		as(function()
			T.truthy(panel.showroom.isBuilt(), "built on activate")
			T.eq(panel.showroom.heroSource(), "builder")
			T.truthy(host:FindFirstChild("View", true):FindFirstChildOfClass("WorldModel"), "WorldModel")
		end)
		local refs = {
			"cosmetic:hat_wizard",
			"cosmetic:trail_rainbow",
			"cosmetic:tint_shadow",
			"skin:filet_neon",
			"skin:elephante_mammoth_king",
			"look:ancient",
			"title:title_legend",
			"dye:rose",
			"chattag:club",
			"frame:p20",
			"frame:wheel",
		}
		for _, ref in refs do
			rt:runIn(client, function()
				panel.select(ref, {
					status = "test",
					buttons = { { text = "Buy", enabled = true, onClick = function() end } },
				})
			end)
			rt:advance(0.2)
			as(function()
				T.truthy(panel.showroom.isBuilt(), ref)
				T.truthy(panel.showroom.partCount() < 400, "part budget " .. ref)
				T.truthy(host:FindFirstChild("TryOn", true).Visible, "try-on badge " .. ref)
			end)
		end
		as(function()
			local wm = host:FindFirstChild("View", true):FindFirstChildOfClass("WorldModel")
			local heroes = 0
			for _, ch in wm:GetChildren() do
				if ch.Name == "PreviewHero" then
					heroes += 1
				end
			end
			T.eq(heroes, 1, "one hero in the world at a time")
		end)
		rt:assertClean(nil, "preview shows")
	end)

	T.it("hats are on the head, trails sweep, tints restore", function()
		rt:runIn(client, function()
			panel.select("cosmetic:hat_party")
		end)
		rt:advance(0.1)
		as(function()
			local hat = host:FindFirstChild("Hat_hat_party", true)
			T.truthy(hat, "hat built")
			T.eq(#hat:GetChildren(), #Cosmetics.HAT_SHAPES.cone, "same parts as the server hat")
		end)
		rt:runIn(client, function()
			panel.select("cosmetic:trail_lava")
		end)
		rt:advance(0.1)
		local p1
		as(function()
			T.falsy(host:FindFirstChild("Hat_hat_party", true), "previous hat cleared")
			p1 = host:FindFirstChild("TrailRibbon", true).Seg1.Position
		end)
		rt:advance(0.5)
		as(function()
			local p2 = host:FindFirstChild("TrailRibbon", true).Seg1.Position
			T.truthy((p2 - p1).Magnitude > 0.01, "ribbon sweeps")
		end)
	end)

	T.it("Effects off: no rotation, no idle, no sweep", function()
		rt:runIn(client, function()
			State.set("gfx", { fx = "off", decor = "full" })
		end)
		rt:advance(0.1)
		local seg, pivot
		as(function()
			T.falsy(panel.showroom.motion().rotate)
			seg = host:FindFirstChild("TrailRibbon", true).Seg1.Position
			pivot = host:FindFirstChild("PreviewHero", true):GetPivot()
		end)
		rt:advance(1)
		as(function()
			T.eq(host:FindFirstChild("TrailRibbon", true).Seg1.Position, seg, "ribbon still")
			T.eq(host:FindFirstChild("PreviewHero", true):GetPivot(), pivot, "hero still")
		end)
		rt:runIn(client, function()
			State.set("gfx", { fx = "full", decor = "full" })
		end)
		rt:advance(0.5)
		as(function()
			local now = host:FindFirstChild("PreviewHero", true):GetPivot()
			T.truthy(now ~= pivot, "turntable back on")
		end)
	end)

	T.it("pauses when hidden, releases on close, destroys with nothing left", function()
		rt:runIn(client, function()
			host.Visible = false
		end)
		rt:advance(0.6)
		local pivot
		as(function()
			pivot = host:FindFirstChild("PreviewHero", true):GetPivot()
		end)
		rt:advance(0.6)
		as(function()
			T.eq(host:FindFirstChild("PreviewHero", true):GetPivot(), pivot, "paused while hidden")
		end)
		rt:runIn(client, function()
			host.Visible = true
			panel.setActive(false)
		end)
		as(function()
			T.falsy(host:FindFirstChild("PreviewHero", true), "heroes released on close")
			T.falsy(host:FindFirstChild("TrailRibbon", true), "ribbon released on close")
		end)
		rt:runIn(client, function()
			panel.setActive(true)
			panel.select("skin:jumbo_gilded")
		end)
		rt:advance(0.2)
		rt:runIn(client, function()
			panel.destroy()
		end)
		as(function()
			T.eq(count(host.Parent), before, "nothing left behind")
		end)
		rt:assertClean(nil, "preview teardown")
	end)

	T.it("falls back to a stand-in with no builder and no statue", function()
		local h
		rt:runIn(client, function()
			local builder = CP.builder
			CP.builder = function()
				return nil
			end
			h = CP.buildHero("nope_class", nil, nil)
			CP.builder = builder
		end)
		as(function()
			T.eq(h.source, "standin")
			T.truthy(h.model:FindFirstChild("Head"))
			T.truthy(#h.model:GetChildren() <= 12, "low part count")
			h.model:Destroy()
		end)
		rt:assertClean(nil, "stand-in")
	end)
end)

T.describe("CosmeticIcon (runtime, no asset ids)", function()
	local okI, Icon = pcall(function()
		return rt:clientModule(client, "Client.UI.CosmeticIcon")
	end)
	T.it("draws an icon for every ref and cleans up", function()
		T.truthy(okI, "CosmeticIcon loads: " .. tostring(Icon))
		if not okI then
			return
		end
		local gui = rt:playerGui(client)
		local sg
		rt:runIn(client, function()
			sg = Instance.new("ScreenGui")
			sg.Parent = gui
			for _, ref in PreviewRecipe.allRefs(cfg) do
				local f = Icon.make(ref, 56, { Parent = sg })
				T.truthy(f, "icon " .. ref)
			end
		end)
		rt:advance(0.5)
		rt:runIn(client, function()
			sg:Destroy()
		end)
		rt:advance(0.5)
		as(function()
			T.eq(Icon.liveCount(), 0, "no animated icons left running")
		end)
		rt:assertClean(nil, "icons")
	end)
end)

return T.finish()
