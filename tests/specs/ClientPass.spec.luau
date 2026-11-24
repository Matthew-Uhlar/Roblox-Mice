-- Iteration 6, team Pass: the Herd Pass screen (src/client/UI/PassUI.luau) and its
-- pure maths (src/client/Util/PassModel.luau).
local T = require("../lib/Test")
local fs = require("@lune/fs")
local PassModel = require("../../src/client/Util/PassModel")
local Progression = require("../../src/client/Util/Progression")
local Layout = require("../../src/client/Util/Layout")
local Pass = require("../../src/shared/Config/Pass")

local function modelFor(view: any): any
	local pv = Progression.pass(view, Pass)
	return PassModel.build(pv, Pass.season(1), Progression.reward)
end

-- A Pass view like the server's (Net.S2C.Pass).
local function view(
	tier: number,
	premium: boolean,
	claimed: { [number]: { free: boolean?, premium: boolean? } }?
): any
	local def = Pass.season(1)
	local tiers = {}
	for t = 1, Pass.TIERS do
		local c = claimed and claimed[t] or {}
		tiers[t] = {
			tier = t,
			free = def.free[t],
			premium = def.premium[t],
			freeClaimed = c.free == true,
			premiumClaimed = c.premium == true,
			reached = t <= tier,
		}
	end
	return {
		season = 1,
		name = def.name,
		xp = tier * 1000 + 400,
		tier = tier,
		tierXp = 400,
		xpPerTier = 1000,
		maxTier = Pass.TIERS,
		premium = premium,
		premiumKey = "herd_pass_s1",
		daysLeft = 9,
		tiers = tiers,
	}
end

T.describe("PassModel.build", function()
	T.it("every tier renders a free and a premium slot from Config/Pass", function()
		for _, v in { view(0, false), nil :: any } do
			local m = modelFor(v)
			T.eq(#m.columns, Pass.TIERS)
			local def = Pass.season(1)
			for t, col in m.columns do
				T.eq(col.tier, t)
				T.eq(col.free.track, "free")
				T.eq(col.premium.track, "premium")
				T.eq(col.free.reward ~= nil, def.free[t] ~= nil, "free reward of tier " .. t)
				T.eq(col.premium.reward ~= nil, def.premium[t] ~= nil, "premium reward of tier " .. t)
				if def.premium[t] == nil then
					T.eq(col.premium.state, "empty")
				end
			end
		end
	end)

	T.it("computes claimed / claimable / locked / needsPremium from the view", function()
		local m = modelFor(view(5, false, { [1] = { free = true }, [3] = { free = true } }))
		T.eq(m.tier, 5)
		T.near(m.frac, 0.4, 1e-6)
		T.eq(m.columns[1].free.state, "claimed")
		T.eq(m.columns[2].free.state, "claimable")
		T.eq(m.columns[3].free.state, "claimed")
		T.eq(m.columns[6].free.state, "locked")
		T.eq(m.columns[1].premium.state, "needsPremium") -- hat at tier 1, no premium
		T.eq(m.columns[6].premium.state, "locked")
		T.eq(m.claimable, 3) -- free 2, 4, 5
		T.eq(m.currentTier, 6)
		T.eq(PassModel.focusTier(m), 2)
		local q = PassModel.claimQueue(m)
		T.eq(#q, 3)
		T.eq(q[1].tier, 2)
		T.eq(#PassModel.claimQueue(m, { ["2:free"] = true }), 2)

		local p = modelFor(view(3, true, { [1] = { premium = true } }))
		T.eq(p.columns[1].premium.state, "claimed")
		T.eq(p.columns[3].premium.state, "claimable")
		T.eq(p.columns[2].premium.state, "empty")
		T.eq(p.claimable, 3 + 1)
		T.eq(p.premiumKey, "herd_pass_s1")
	end)

	T.it("max tier and an unknown view are safe", function()
		local m = modelFor(view(30, true))
		T.eq(m.frac, 1)
		T.eq(PassModel.xpCaption(m), PassModel.TEXT.maxTier)
		local u = modelFor(nil)
		T.falsy(u.known)
		T.eq(u.claimable, 0)
		T.eq(u.columns[1].free.state, "locked")
		T.eq(u.seasonName, "Winter Rind")
	end)

	T.it("reward cards: cosmetics preview, currencies fly to their chips", function()
		local m = modelFor(view(1, false))
		local hat =
			PassModel.rewardInfo(m.columns[1].premium.reward, "premium", { slot = "hat", name = "Snow Cap" })
		T.eq(hat.title, "Snow Cap")
		T.eq(hat.ref, "cosmetic:hat_snow_cap")
		T.truthy(hat.featured)
		local ch = PassModel.rewardInfo(m.columns[2].free.reward, "free", nil)
		T.eq(ch.fly, "cheese")
		T.eq(ch.title, tostring(Pass.season(1).free[2].cheese))
		local gc = PassModel.rewardInfo(m.columns[3].premium.reward, "premium", nil)
		T.eq(gc.fly, "golden")
		local dust = PassModel.rewardInfo(m.columns[12].free.reward, "free", nil)
		T.truthy(string.find(dust.sub, "dust", 1, true) ~= nil, dust.sub)
	end)
end)

T.describe("Policy: no countdowns, scarcity or auto-prompts", function()
	T.it("fixed texts are clean", function()
		for k, s in PassModel.TEXT do
			T.truthy(PassModel.safeText(s), k .. ": " .. s)
		end
		T.falsy(PassModel.safeText("Season ends in 3 days"))
		T.falsy(PassModel.safeText("Hurry!"))
	end)

	local src = fs.readFile("src/client/UI/PassUI.luau")
	local code = string.gsub(src, "%-%-[^\n]*", "") -- comments may name the rule

	T.it("PassUI string literals are clean and it never reads the season clock", function()
		for lit in string.gmatch(code, '"([^"\n]*)"') do
			T.truthy(PassModel.safeText(lit), lit)
		end
		for _, ident in { "daysLeft", "endsAt", "seasonEndsAt", "dayInSeason", "seasonDays" } do
			T.falsy(string.find(code, ident, 1, true), ident)
		end
	end)

	T.it("PromptProduct only from promptPremium, which only buttons call", function()
		local _, n = string.gsub(code, "PromptProduct", "")
		T.eq(n, 1)
		local callers = 0
		for line in string.gmatch(code, "[^\n]+") do
			if
				string.find(line, "promptPremium", 1, true)
				and not string.find(line, "function promptPremium", 1, true)
			then
				callers += 1
				T.truthy(
					string.find(line, "}, promptPremium)", 1, true)
						or string.find(line, "promptPremium()", 1, true),
					line
				)
			end
		end
		T.eq(callers, 2) -- header button, featured button
		T.falsy(string.find(code, "ResultsUI", 1, true))
	end)

	T.it("premium rewards are cosmetics and Golden Cheese only", function()
		for _, r in Pass.season(1).premium do
			for k in r do
				T.truthy(k == "cosmetic" or k == "goldenCheese", k)
			end
		end
	end)
end)

T.describe("Effects setting", function()
	T.it("off = static, reduced = minimal, full = everything", function()
		local off = PassModel.anim("off")
		for k, v in off do
			T.truthy(v == false or v == 0 or v == "none", "off " .. k)
		end
		local red = PassModel.anim("reduced")
		T.falsy(red.bob)
		T.falsy(red.shine)
		T.falsy(red.flash)
		T.falsy(red.fly)
		T.eq(red.particles, 0)
		T.eq(red.intro, "pop")
		local full = PassModel.anim("full")
		T.truthy(full.bob and full.shine and full.flash and full.fly and full.glowPulse)
		T.truthy(full.particles > 0)
		T.eq(full.intro, "cascade")
		T.deepEq(PassModel.anim(nil), full)
	end)

	T.it("PassUI reads the saved setting and follows changes", function()
		local src = fs.readFile("src/client/UI/PassUI.luau")
		T.truthy(string.find(src, "PassModel.anim(State.gfx().fx)", 1, true))
		T.truthy(string.find(src, 'State.subscribe("gfx"', 1, true))
		T.truthy(string.find(src, "UnbindAction", 1, true))
		local _, conns = string.gsub(src, "RenderStepped:Connect", "")
		T.eq(conns, 1) -- one shared driver
	end)
end)

T.describe("Curves and snap", function()
	T.it("centre / nearest round-trip and clamp", function()
		for _, i in { 1, 7, 30 } do
			local off = PassModel.centreOffset(i, 30, 160, 14, 1100)
			T.eq(PassModel.nearestIndex(off, 30, 160, 14, 1100), i)
		end
		T.eq(PassModel.centreOffset(1, 30, 160, 14, 1100), 0)
		T.eq(PassModel.nearestIndex(-500, 30, 160, 14, 1100), 1)
		T.eq(PassModel.nearestIndex(1e6, 30, 160, 14, 1100), 30)
	end)

	T.it("eases, pop, shine and bursts are bounded", function()
		T.near(PassModel.ease("outBack", 1), 1, 1e-9)
		T.near(PassModel.ease("outCubic", 0), 0, 1e-9)
		T.near(PassModel.popScale(0), 1, 1e-9)
		T.near(PassModel.popScale(PassModel.POP_TIME), 1, 1e-9)
		T.truthy(PassModel.popScale(PassModel.POP_TIME / 2) > 1.1)
		for t = 0, 10, 0.1 do
			local s = PassModel.shine(t, 3)
			T.truthy(s >= -1.5 and s <= 1.5)
		end
		local b = PassModel.burst(14, 42)
		T.eq(#b, 14)
		T.deepEq(b, PassModel.burst(14, 42))
		T.eq(PassModel.approach(0, 1, 100, 10), 1)
	end)
end)

T.describe("Layout fits the ClientLayout screens", function()
	local TOPBAR = 58
	local cases = {
		{ name = "iPhone SE 667x375", w = 667, h = 375, touch = true },
		{ name = "Android 740x360", w = 740, h = 360, touch = true },
		{ name = "Laptop 1366x768", w = 1366, h = 768, touch = false },
		{ name = "PC 1920x1080", w = 1920, h = 1080, touch = false },
		{ name = "PC 2560x1440", w = 2560, h = 1440, touch = false },
	}
	local function inside(r: any, w: number, h: number, msg: string)
		T.truthy(r.x >= -0.01 and r.y >= -0.01 and r.x + r.w <= w + 0.01 and r.y + r.h <= h + 0.01, msg)
	end
	for _, c in cases do
		T.it(c.name, function()
			local sw, sh = Layout.safeViewport(c.w, c.h, 0, TOPBAR, 0, 0)
			local m = Layout.metrics(sw, sh, c.touch)
			local L = PassModel.layout(m.rootW, m.rootH, m.touch, m.dense)
			inside(L.panel, m.rootW, m.rootH, "panel in root")
			local pw, ph = L.panel.w, L.panel.h
			inside(L.header, pw, ph, "header")
			inside(L.track, pw, ph, "track")
			inside(L.scroller, pw, ph, "scroller")
			inside(L.featured, pw, ph, "featured")
			T.truthy(L.track.y >= L.header.y + L.header.h, "track under header")
			-- header parts in a row, no overlap, all inside
			local order = { "season", "badge", "bar", "claimAll", "unlock", "close" }
			local x = -1
			for _, k in order do
				local r = L.headerParts[k]
				T.truthy(r.x >= x, k .. " after previous")
				inside(r, L.header.w, L.header.h, k)
				x = r.x + r.w
			end
			T.truthy(L.headerParts.bar.w >= 200, "XP bar wide enough: " .. L.headerParts.bar.w)
			for _, k in { "claimAll", "unlock", "close" } do
				T.truthy(L.headerParts[k].h >= m.touch, k .. " touch size")
			end
			-- both card rows fit in the track
			T.truthy(L.pillH + 2 * L.rowGap + 2 * L.cardH <= L.track.h + 0.01, "two rows fit")
			T.truthy(L.cardH >= 120 and L.cardW >= 120, "cards big enough")
			T.truthy(L.visibleCols >= 4, "at least 4 tiers visible: " .. L.visibleCols)
			if c.touch then
				T.eq(L.featuredMode, "drawer")
				T.truthy(L.cardH * m.scale >= 48, "card is a touch target")
			else
				T.eq(L.featuredMode, "side")
				T.truthy(L.featured.x >= L.track.x + L.track.w, "side panel beside the track")
			end
		end)
	end
end)

T.describe("ClaimPassAll (server, iteration 6)", function()
	local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
	local HerdPass = require("../../src/shared/Data/HerdPass")

	T.it("claims every reached free tier, premium only if owned, once", function()
		local p = ProfileSchema.default() :: any
		T.deepEq({ HerdPass.claimAll(p, false) }, { false, "nothing" })
		HerdPass.addXp(p, 5500) -- tier 5
		T.truthy(HerdPass.claim(p, 2, "free"))
		local before = p.cheese
		local ok, given = HerdPass.claimAll(p, false)
		T.truthy(ok)
		T.eq(given.count, 4) -- free 1, 3, 4, 5
		T.truthy(p.cheese > before)
		T.eq(HerdPass.claimable(p), 0)
		T.deepEq({ HerdPass.claimAll(p, false) }, { false, "nothing" })
		-- buying premium back-fills: the next claim-all takes the reached premium tiers
		local ok2, g2 = HerdPass.claimAll(p, true)
		T.truthy(ok2)
		local def = Pass.season(1)
		local want = 0
		for t = 1, 5 do
			if def.premium[t] then
				want += 1
			end
		end
		T.eq(g2.count, want)
		T.truthy(type(g2.cosmetics) == "table" and table.find(g2.cosmetics, "hat_snow_cap") ~= nil)
		T.eq(HerdPass.claimable(p), 0)
	end)

	T.it("ShopService wires it through Guard with a rate limit, one summary toast", function()
		local src = fs.readFile("src/server/Services/ShopService.luau")
		T.truthy(string.find(src, "Guard.connect(Net.C2S.ClaimPassAll", 1, true))
		T.truthy(string.find(src, "HerdPass.claimAll(p, prem)", 1, true))
		T.truthy(string.find(src, '"Claimed %d Herd Pass reward%s: %s"', 1, true))
		local ui = fs.readFile("src/client/UI/PassUI.luau")
		T.truthy(string.find(ui, "Remotes.fire(Remotes.C2S.ClaimPassAll)", 1, true))
		T.truthy(
			string.find(ui, "Remotes.fire(Remotes.C2S.ClaimPassTier, tier, track)", 1, true),
			"fallback kept"
		)
	end)
end)

return T.finish()
