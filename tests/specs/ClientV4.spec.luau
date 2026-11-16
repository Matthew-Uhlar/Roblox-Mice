-- Pure client v4 helpers (team U): shop model (tabs, owned, bullets, featured
-- rotation, no pressure text), progression views (quests, Herd Pass, account
-- rewards, boost timers, dots, rookie), and the in-run HUD maths (storm,
-- redeploy, vignette, objective, pings / quick-chat, awards, results rules).
local T = require("../lib/Test")
local ShopModel = require("../../src/client/Util/ShopModel")
local Progression = require("../../src/client/Util/Progression")
local HudMath = require("../../src/client/Util/HudMath")
local Monetization = require("../../src/shared/Config/Monetization")

T.describe("ShopModel tabs", function()
	T.it("has the seven v4 tabs in order", function()
		T.eq(table.concat(ShopModel.TABS, ","), "Featured,Cosmetics,Passes,Golden Cheese,Boosts,Herd Pass,Cheese Shop")
		for _, t in ShopModel.TABS do
			T.truthy(ShopModel.SHORT[t], "short label for " .. t)
		end
	end)
	T.it("places every live Monetization item, hides ad-only items", function()
		for _, it in Monetization.ALL do
			local tab = ShopModel.tabFor(it)
			if it.adOnly then
				T.eq(tab, nil, it.key)
			else
				T.truthy(tab and table.find(ShopModel.TABS, tab), it.key .. " -> " .. tostring(tab))
			end
		end
		T.eq(ShopModel.tabFor(Monetization.get("vip")), "Passes")
		T.eq(ShopModel.tabFor(Monetization.get("golden_m")), "Golden Cheese")
		T.eq(ShopModel.tabFor(Monetization.get("cheese_rush")), "Boosts")
		T.eq(ShopModel.tabFor(Monetization.get("respec_token")), "Boosts")
		T.eq(ShopModel.tabFor({ key = "starter_pack", kind = "product" }), "Featured")
		T.eq(ShopModel.tabFor({ key = "herd_pass_s1", kind = "product" }), "Herd Pass")
		T.eq(ShopModel.tabFor({ key = "x", kind = "product", tab = "Cosmetics" }), "Cosmetics")
	end)
	T.it("owned passes say Owned and never show a price", function()
		local prof = { passes = { vip = true } }
		T.truthy(ShopModel.owned({ key = "vip", kind = "pass" }, prof))
		T.falsy(ShopModel.owned({ key = "herd_leader", kind = "pass" }, prof))
		T.eq(ShopModel.robuxLabel(true, true, 399), "✔ Owned")
		T.eq(ShopModel.robuxLabel(false, true, 399), "R$ 399")
		T.eq(ShopModel.robuxLabel(false, true, nil), "R$ —")
		T.eq(ShopModel.robuxLabel(false, false, 399), "Coming soon")
		-- owned passes sort last; the one-time starter pack hides once bought
		local list = ShopModel.itemsFor("Passes", {
			{ key = "vip", kind = "pass", price = 399, name = "VIP" },
			{ key = "wardrobe", kind = "pass", price = 99, name = "W" },
		}, prof)
		T.eq(list[1].key, "wardrobe")
		T.eq(list[2].key, "vip")
		local feat = ShopModel.itemsFor(
			"Featured",
			{ { key = "starter_pack", kind = "product", price = 99, name = "S" } },
			{ purchasesOnce = { starter_pack = true } }
		)
		T.eq(#feat, 0)
		T.falsy(ShopModel.owned({ key = "vip", kind = "pass" }, nil))
	end)
	T.it("benefit bullets keep the whole rule set reachable (M9)", function()
		local sw = Monetization.get("second_wind_1")
		local b, more = ShopModel.bullets(sw and sw.benefit, 4)
		T.truthy(#b >= 3 and #b <= 4)
		T.truthy(more, "long text offers Details")
		for _, l in b do
			T.truthy(#l <= 112, "bullet short: " .. l)
		end
		local b2, more2 = ShopModel.bullets("100 Golden Cheese for the cosmetic shop.", 4)
		T.eq(#b2, 1)
		T.eq(b2[1], "100 Golden Cheese for the cosmetic shop")
		T.falsy(more2)
		local b3 = ShopModel.bullets("1,150 Golden Cheese (1,000 + 15% bonus).", 4)
		T.eq(b3[1], "1,150 Golden Cheese (1,000 + 15% bonus)")
		T.eq(#ShopModel.bullets(nil), 0)
	end)
	T.it("featured rotation is shared per day, deterministic, and differs across days", function()
		local pool = {}
		for i = 1, 30 do
			table.insert(pool, { itemId = string.format("c%02d", i), kind = "cosmetic", currency = if i % 3 == 0 then "cheese" else "golden" })
		end
		local a = ShopModel.featuredCosmetics(pool, 20000, nil)
		local b = ShopModel.featuredCosmetics(table.clone(pool), 20000, nil)
		T.eq(#a, 6)
		for i = 1, #a do
			T.eq(a[i].itemId, b[i].itemId)
		end
		local c = ShopModel.featuredCosmetics(pool, 20001, nil)
		local same = 0
		for i = 1, #a do
			if a[i].itemId == c[i].itemId then
				same += 1
			end
		end
		T.truthy(same < 6, "rotates daily")
		local seen = {}
		for _, e in a do
			T.falsy(seen[e.itemId], "no duplicates")
			seen[e.itemId] = true
		end
		T.eq(#ShopModel.featuredCosmetics({}, 1, nil), 0)
	end)
	T.it("pressure text detector flags timers and countdowns", function()
		T.truthy(ShopModel.isPressureText("Ends in 2:59"))
		T.truthy(ShopModel.isPressureText("Only 3 left!"))
		T.truthy(ShopModel.isPressureText("50% OFF"))
		T.falsy(ShopModel.isPressureText("Today's picks"))
		T.falsy(ShopModel.isPressureText("Starter Herd Pack"))
	end)
end)

T.describe("Progression views", function()
	T.it("rookie: runs 0-2 hide DoN / Pressure; unknown profile is a rookie", function()
		T.truthy(Progression.isRookie(nil))
		T.truthy(Progression.isRookie({ stats = { runs = 0 } }))
		T.truthy(Progression.isRookie({ stats = { runs = 2 } }))
		T.falsy(Progression.isRookie({ stats = { runs = 3 } }))
		T.falsy(Progression.isRookie({ stats = { runs = 1 }, rookie = false }))
	end)
	T.it("rewards from any shape", function()
		T.eq(Progression.reward({ passXp = 150, cheese = 100 }).text, "⭐ 150 XP  🧀 100")
		T.eq(Progression.reward({ kind = "golden", amount = 25 }).kind, "golden")
		T.eq(Progression.reward({ kind = "cosmetic", id = "hat_x", name = "Hat X" }).text, "🎩 Hat X")
		T.eq(Progression.reward(50).kind, "cheese")
		T.eq(Progression.reward(nil).kind, "none")
	end)
	T.it("quests: daily / weekly split, claimable, reroll gating", function()
		local q = Progression.quests({
			daily = {
				{ id = "a", text = "Stomp 500 mice", progress = 500, goal = 500, reward = { passXp = 150, cheese = 100 } },
				{ id = "b", text = "Open 3 POIs", progress = 1, goal = 3 },
				{ id = "c", text = "Kill a champion", progress = 1, goal = 1, claimed = true },
			},
			weekly = { w1 = { text = "Extract 5 times", progress = 2, goal = 5 } },
			rerollsLeft = 1,
		})
		T.truthy(q.known)
		T.eq(#q.daily, 3)
		T.eq(q.daily[1].id, "a") -- claimable first
		T.eq(q.daily[3].id, "c") -- claimed last
		T.eq(q.claimable, 1)
		T.eq(q.weekly[1].id, "w1")
		T.truthy(q.daily[2].canReroll)
		T.falsy(q.daily[1].canReroll)
		local none = Progression.quests({ quests = { { id = "x", period = "weekly", goal = 2 } }, rerollsLeft = 0 })
		T.eq(#none.weekly, 1)
		T.falsy(none.weekly[1].canReroll)
		local empty = Progression.quests(nil)
		T.falsy(empty.known)
		T.eq(#empty.daily, 0)
	end)
	T.it("pass: 30 tiers, free + premium claimability", function()
		local v = Progression.pass({
			tier = 3,
			xp = 250,
			premium = false,
			tiers = {
				{ tier = 1, free = { cheese = 100 }, premium = { golden = 100 } },
				{ tier = 2, free = { cheese = 100 } },
				{ tier = 3, premium = { kind = "cosmetic", id = "hat_s1" } },
			},
			claimed = { free = { 1 } },
		}, nil)
		T.eq(#v.tiers, 30)
		T.eq(v.tier, 3)
		T.falsy(v.tiers[1].freeClaimable) -- already claimed
		T.truthy(v.tiers[2].freeClaimable)
		T.falsy(v.tiers[1].premiumClaimable) -- no premium
		T.eq(v.claimable, 1)
		local prem = Progression.pass({ totalXp = 3500, premium = true, tiers = { { tier = 1, premium = { golden = 100 } } } }, nil)
		T.eq(prem.tier, 3)
		T.eq(prem.xp, 500)
		T.truthy(prem.tiers[1].premiumClaimable)
		T.eq(Progression.pass(nil, nil).tier, 0)
		T.eq(#Progression.pass(nil, nil).tiers, 30)
	end)
	T.it("account rewards: claimable at or under the level, once", function()
		local defs = { { level = 5, reward = { golden = 25 } }, { level = 10, reward = { cosmetic = "hat_l10" } }, { level = 15, reward = { golden = 25 } } }
		local list = Progression.accountRewards({ level = 12, accountRewards = { claimed = { [5] = true } } }, defs)
		T.eq(#list, 3)
		T.falsy(list[1].claimable)
		T.truthy(list[2].claimable)
		T.falsy(list[3].claimable)
		T.eq(#Progression.accountRewards(nil, nil), 0)
	end)
	T.it("boost timers tick and expire", function()
		local p = { boosts = { rushSecondsLeft = 42 * 60 }, feastSecondsLeft = 100, herdLeaderActive = true }
		local b = Progression.boosts(p, 0)
		T.eq(#b, 3)
		T.eq(b[1].text, "Cheese Rush ×2: 42 min left")
		local later = Progression.boosts(p, 200)
		T.eq(#later, 2) -- the feast ran out
		T.eq(Progression.duration(3900), "1 h 05 min")
		T.eq(Progression.duration(12), "12 s")
		T.eq(#Progression.boosts(nil, 0), 0)
	end)
	T.it("dots: only for claimable things", function()
		local d = Progression.dots({ daily = { claimable = true } }, nil, nil, nil)
		T.truthy(d.daily and d.shop)
		T.falsy(d.progress)
		local d2 = Progression.dots(
			{ daily = { claimable = false }, level = 3 },
			{ daily = { { id = "a", progress = 1, goal = 1 } } },
			{ tier = 1, tiers = { { tier = 1, free = { cheese = 5 } } } },
			nil
		)
		T.falsy(d2.daily)
		T.eq(d2.contracts, 1)
		T.eq(d2.pass, 1)
		T.truthy(d2.shop)
		T.truthy(d2.progress)
		local quiet = Progression.dots({ daily = { claimable = false } }, nil, nil, nil)
		T.falsy(quiet.shop or quiet.progress)
	end)
end)

T.describe("HudMath storm", function()
	local s = HudMath.storm({ cx = 0, cz = 0, r = 100, toR = 60, closeStart = 1010, closeEnd = 1040, dps = 4, now = 1000 }, 5000)
	T.it("re-bases the close times onto the client clock", function()
		assert(s)
		T.eq(s.closeStart, 5010)
		T.eq(s.closeEnd, 5040)
		T.eq(HudMath.storm({ r = 0 }, 1), nil)
		T.eq(HudMath.storm(nil, 1), nil)
	end)
	T.it("radius shrinks linearly, timer text and outside flag", function()
		assert(s)
		T.eq(HudMath.stormRadius(s, 5000), 100)
		T.near(HudMath.stormRadius(s, 5025), 80)
		T.eq(HudMath.stormRadius(s, 6000), 60)
		local st = HudMath.stormStatus(s, 90, 0, 5000)
		T.eq(st.phase, "wait")
		T.eq(st.text, "The Melt closes in 0:10")
		T.falsy(st.outside)
		local st2 = HudMath.stormStatus(s, 90, 0, 5030)
		T.eq(st2.phase, "closing")
		T.truthy(st2.outside)
		T.eq(HudMath.stormStatus(s, 0, 0, 9999).phase, "still")
		T.eq(#HudMath.ringPoints(0, 0, 10, 24), 24)
	end)
end)

T.describe("HudMath HUD", function()
	T.it("redeploy countdown", function()
		T.eq(HudMath.redeployLeft({ untilT = 120 }, 100), 20)
		T.eq(HudMath.redeployLeft({ untilT = 100 }, 105), nil)
		T.eq(HudMath.redeployLeft(nil, 1), nil)
	end)
	T.it("vignette: flash on hit, pulse at low HP, invisible when healthy", function()
		T.eq(HudMath.vignette(99, 1, 0, false), 1)
		T.truthy(HudMath.vignette(0.05, 1, 0, false) < 0.4)
		T.truthy(HudMath.vignette(0.3, 1, 0, false) > 0.5)
		local lo = 1
		for i = 0, 20 do
			lo = math.min(lo, HudMath.vignette(99, 0.1, i * 0.05, false))
		end
		T.truthy(lo < 0.8 and lo >= 0.55)
		T.eq(HudMath.vignette(99, 0.2, 0, true), 0.55)
	end)
	T.it("objective: gate, boss, nearest safe champion, then POI", function()
		local ctx = {
			phase = "Waves",
			champions = { { x = 100, z = 0 }, { x = 10, z = 0 } },
			pois = { { x = 5, z = 0, done = true }, { x = 30, z = 0 } },
			now = 0,
		}
		local g = HudMath.objective(ctx, 0, 0)
		assert(g)
		T.eq(g.kind, "champion")
		T.eq(g.x, 10)
		ctx.champions = {}
		local p = HudMath.objective(ctx, 0, 0)
		assert(p)
		T.eq(p.kind, "poi")
		T.eq(p.x, 30)
		local gate = HudMath.objective({ phase = "Extraction", portal = { x = 1, z = 2 } }, 0, 0)
		assert(gate)
		T.eq(gate.kind, "gate")
		-- a champion outside the storm is skipped
		local storm = HudMath.storm({ cx = 0, cz = 0, r = 50, toR = 50, closeStart = 0, closeEnd = 0, now = 0 }, 0)
		local sg = HudMath.objective({ phase = "Waves", champions = { { x = 200, z = 0 } }, storm = storm, now = 0 }, 0, 0)
		T.eq(sg, nil)
		local far = HudMath.objective({ phase = "Waves", storm = storm, now = 0 }, 45, 0)
		assert(far)
		T.eq(far.kind, "safe")
		T.eq(HudMath.objective({ phase = "Lobby" }, 0, 0), nil)
	end)
	T.it("arrow angle: up is 0, right is +90°", function()
		T.near(HudMath.arrowAngle(0, 0, 0, -10), 0)
		T.near(HudMath.arrowAngle(0, 0, 10, 0), math.pi / 2)
	end)
	T.it("ping wheel sectors and slots agree", function()
		for n = 3, 8 do
			for i = 1, n do
				local x, y = HudMath.wheelSlot(i, n, 80)
				T.eq(HudMath.wheelSector(x, y, n), i)
			end
		end
		T.eq(HudMath.wheelSector(1, 1, 6), nil)
	end)
	T.it("pings and quick-chat normalise; unknown chat index drops", function()
		local p = HudMath.ping({ by = 1, squad = 2, kind = "enemy", x = 5, z = 6, t = 10 }, 0)
		assert(p)
		T.eq(p.text, "Enemy!")
		local c = HudMath.ping({ by = 1, kind = "chat", index = 2 }, 0)
		assert(c)
		T.eq(c.text, "Thanks!")
		local c2 = HudMath.ping({ kind = "chat:5" }, 0)
		assert(c2)
		T.eq(c2.text, "Group up")
		T.eq(HudMath.ping({ kind = "chat", index = 99 }, 0), nil)
		T.eq(#HudMath.QUICK_CHAT, 8)
		for _, k in HudMath.PING_KINDS do
			T.truthy(HudMath.PING_INFO[k], k)
		end
	end)
	T.it("awards: MVP and up to 3 of your accolades", function()
		local a = HudMath.awards({ mvp = { id = 7, name = "Ann", score = 120 }, accolades = { [7] = { "mouse_masher", { id = "iron_trunk", value = 3 } } } }, 7)
		assert(a)
		T.truthy(a.mvpIsYou)
		T.eq(#a.yours, 2)
		T.eq(a.yours[1].text, "Mouse Masher")
		T.eq(a.yours[2].value, "3")
		local b = HudMath.awards({ mvp = 9, you = { "a", "b", "c", "d" } }, 7)
		assert(b)
		T.falsy(b.mvpIsYou)
		T.eq(#b.yours, 3)
		T.eq(b.yours[1].text, "A")
		T.eq(HudMath.awards(nil, 1), nil)
	end)
	T.it("results rules: shop card only on a win; Play Again once out", function()
		T.truthy(HudMath.isWin({ result = "Extracted" }))
		T.truthy(HudMath.isWin({ lastHerd = true }))
		T.falsy(HudMath.isWin({ result = "Eliminated" }))
		T.falsy(HudMath.isWin({ outcome = "Wipe" }))
		T.truthy(HudMath.canPlayAgain({ result = "eliminated" }))
		T.truthy(HudMath.canPlayAgain({ result = "extracted" }))
		T.falsy(HudMath.canPlayAgain({}))
		T.eq(HudMath.secured({ secured = 120.7 }), 120)
		T.eq(HudMath.secured({}), 0)
	end)
	T.it("streak labels and milestones", function()
		local t, m = HudMath.streakLabel(12)
		T.eq(t, "×12 STOMP!")
		T.falsy(m)
		local _, m25 = HudMath.streakLabel(25)
		T.truthy(m25)
		local _, m150 = HudMath.streakLabel(150)
		T.truthy(m150)
	end)
end)

return T.finish()
