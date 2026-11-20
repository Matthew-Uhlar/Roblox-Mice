-- Iteration 1 pure client helpers (team U): toast priorities, the Results
-- breakdown, the calm upgrade gate, hidden shop items and awards.
local T = require("../lib/Test")
local ToastQueue = require("../../src/client/Util/ToastQueue")
local ResultsModel = require("../../src/client/Util/ResultsModel")
local HudMath = require("../../src/client/Util/HudMath")
local ShopModel = require("../../src/client/Util/ShopModel")
local Monetization = require("../../src/shared/Config/Monetization")
local RunShopModel = require("../../src/client/Util/RunShopModel")
local RunShop = require("../../src/shared/Config/RunShop")

T.describe("ToastQueue", function()
	T.it("classifies by kind and text", function()
		T.eq(ToastQueue.classify("Ann is down!", "info"), "critical")
		T.eq(ToastQueue.classify("The Melt is closing", nil), "critical")
		T.eq(ToastQueue.classify("New Mousepedia entry: Froggus", "good"), "meta")
		T.eq(ToastQueue.classify("+120 cheese", "info"), "reward")
		T.eq(ToastQueue.classify("Hello", "info"), "info")
		T.eq(ToastQueue.classify("Anything", "critical"), "critical")
	end)
	T.it("criticals jump the line and are never dropped", function()
		local q = ToastQueue.new()
		for i = 1, ToastQueue.MAX_QUEUED do
			q:push("note " .. i, "info", true)
		end
		T.eq(q:push("Bob is down!", "info", true), "queued")
		local e = q:pop(100)
		assert(e, "expected an entry")
		T.eq(e.class, "critical")
		T.eq(#q.queue, ToastQueue.MAX_QUEUED - 1) -- one info evicted
	end)
	T.it("info is rate-limited and a backlog merges into one line", function()
		local q = ToastQueue.new()
		for i = 1, 5 do
			q:push("tip " .. i, "info", false)
		end
		local a = q:pop(10)
		assert(a, "first info")
		T.truthy(string.find(a.text, "+4 more", 1, true) ~= nil, a.text)
		T.eq(q:pop(10.1), nil)
	end)
	T.it("meta is held during a run and flushed as one line", function()
		local q = ToastQueue.new()
		T.eq(q:push("Achievement: First Steps", "good", true), "held")
		T.eq(q:push("New Mousepedia entry: Froggus", "good", true), "held")
		local s = q:flushHeld()
		assert(s, "summary")
		T.truthy(string.find(s, "+2", 1, true) ~= nil)
		T.eq(q:flushHeld(), nil)
	end)
	T.it("level-ups coalesce", function()
		local q = ToastQueue.new()
		q:push("Level up! You are now level 10", "good", false)
		T.eq(q:push("Level up! You are now level 13", "good", false), "merged")
		local e = q:pop(0)
		assert(e, "entry")
		T.eq(e.text, "⬆ Level 9 → 13")
	end)
	T.it("stageClear banner lines from M2's payload", function()
		local title, lines = ToastQueue.stageClear({
			stage = 2,
			stages = 4,
			youWon = true,
			chestCheese = 300,
			stageCheese = 120,
			securedFrac = 0.25,
			wheyStage = 50,
			donLost = 400,
			blessingName = "Swift Feet",
		})
		T.eq(title, "STAGE 2 CLEAR!")
		T.eq(lines[1], "🏆 Your squad took the boss! Chest 🧀 300")
		T.eq(lines[2], "🎲 Double or Nothing lost 🧀 400")
		T.eq(lines[3], "🧀 +120 (25% secured)   🥛 +50 whey")
		T.eq(#lines, 4)
		local t2, l2 = ToastQueue.stageClear({ stage = 4, stages = 4, winnerName = "Swiss" })
		T.eq(t2, "FINAL STAGE CLEAR!")
		T.eq(l2[1], "👑 Swiss took the boss")
		local t3 = ToastQueue.stageClear(nil)
		T.eq(t3, "STAGE CLEAR!")
	end)
	T.it("boss lines join the STAGE CLEAR banner", function()
		local q = ToastQueue.new()
		q:beginBanner()
		T.eq(q:push("Boss chest: +300 Cheese each", "good", true), "banner")
		T.eq(q:push("Ann is down!", "bad", true), "queued")
		local lines = q:endBanner()
		T.eq(#lines, 1)
		T.eq(q:push("Boss chest again", "good", true), "queued")
	end)
end)

T.describe("ResultsModel", function()
	T.it("headline adds the first-extraction bonus and contracts", function()
		local r = {
			result = "extracted",
			cheeseEarned = 220,
			secured = 60,
			firstExtract = { cheese = 500, golden = 50 },
			contracts = { cheese = 300, passXp = 150, count = 2 },
			classXp = 120,
		}
		T.eq(ResultsModel.total(r), 1020)
		local rows = ResultsModel.rows(r)
		local text = {}
		for _, row in rows do
			table.insert(text, row.label .. " " .. row.value)
		end
		local all = table.concat(text, "|")
		T.truthy(string.find(all, "FIRST EXTRACTION", 1, true) ~= nil, all)
		T.truthy(string.find(all, "Contracts done (2) +300", 1, true) ~= nil, all)
		T.truthy(string.find(all, "secured", 1, true) ~= nil, all)
		T.truthy(string.find(all, "Class XP +120", 1, true) ~= nil, all)
	end)
	T.it("a server breakdown list wins; totalCheese wins", function()
		local r = { totalCheese = 999, breakdown = { { label = "Pot", amount = 10 } } }
		T.eq(ResultsModel.total(r), 999)
		local rows = ResultsModel.rows(r)
		T.eq(#rows, 1)
		T.eq(rows[1].value, "+10")
	end)
	T.it("Double or Nothing rows", function()
		T.eq(ResultsModel.don({ don = { won = true, amount = 400 } }), "won")
		T.eq(ResultsModel.don({ donLost = 250 }), "lost")
		T.eq(ResultsModel.don({}), nil)
	end)
	T.it("stats count mice and champions first (P-9)", function()
		local st = ResultsModel.stats({ mice = 144, championKills = 2, pois = 3, kills = 0 })
		T.eq(st[1], "🐭 Mice: 144")
		T.eq(st[2], "👑 Champions: 2")
		T.eq(#ResultsModel.stats(nil), 0)
	end)
end)

T.describe("calm upgrade gate (P-13)", function()
	T.it("waits during a fight, opens after 1.5 s calm or 8 s max", function()
		local g = HudMath.newCalmGate()
		T.falsy(HudMath.calmGate(g, 1, 10, 0))
		T.falsy(HudMath.calmGate(g, 1, 10, 3))
		T.falsy(HudMath.calmGate(g, 1, 2, 3.1)) -- calm starts
		T.falsy(HudMath.calmGate(g, 1, 2, 4.0))
		T.truthy(HudMath.calmGate(g, 1, 2, 4.7)) -- 1.5 s calm
		T.truthy(HudMath.calmGate(g, 1, 20, 5)) -- stays open
		local g2 = HudMath.newCalmGate()
		T.falsy(HudMath.calmGate(g2, 7, 30, 0))
		T.truthy(HudMath.calmGate(g2, 7, 30, 8.1)) -- max wait
		T.truthy(HudMath.calmGate(g2, 8, 30, 8.2)) -- next queued level opens at once
		T.falsy(HudMath.calmGate(g2, nil, 0, 9))
	end)
	T.it("recommended card", function()
		T.eq(HudMath.recommendedCard({ { rarity = "Common" }, { rarity = "Epic" }, { rarity = "Rare" } }), 2)
		T.eq(HudMath.recommendedCard({ { rarity = "Epic" }, { recommended = true } }), 2)
		T.eq(HudMath.recommendedCard(nil), 1)
	end)
end)

T.describe("shop H6 and awards", function()
	T.it("items with id 0 or listed unavailable are hidden unless owned", function()
		T.truthy(ShopModel.hidden({ key = "x", assetId = 0 }, nil))
		T.truthy(ShopModel.hidden({ key = "x", configured = false }, nil))
		T.truthy(ShopModel.hidden({ key = "emote_pack", assetId = 5 }, { emote_pack = true }))
		T.falsy(ShopModel.hidden({ key = "vip", assetId = 5 }, {}))
		local set = ShopModel.unavailableSet({ unavailable = { "emote_pack" } })
		T.truthy(set.emote_pack)
		local items = ShopModel.itemsFor("Featured", {
			{ key = "emote_pack", kind = "product", assetId = 9, emotes = {}, price = 1, name = "E" },
			{ key = "starter_pack", kind = "product", assetId = 0, oneTime = true, price = 1, name = "S" },
			{ key = "skin_bundle", kind = "product", assetId = 3, covers = {}, price = 2, name = "B" },
		}, {}, set)
		T.eq(#items, 1)
		T.eq(items[1].key, "skin_bundle")
		-- with the live catalog, every unconfigured item is hidden
		for _, it in ShopModel.itemsFor("Passes", Monetization.ALL, {}, nil) do
			T.truthy(Monetization.isConfigured(it), it.key)
		end
	end)
	T.it("awards: top bot apart, fallback accolade for a human", function()
		local a = HudMath.awards(
			{ mvp = { id = 5, name = "Ann" }, topBot = { name = "🤖 Bo" }, you = { accolades = {} } },
			7,
			88
		)
		assert(a, "awards")
		T.eq(a.topBotName, "🤖 Bo")
		T.eq(#a.yours, 1)
		T.eq(a.yours[1].text, "Mouse Masher")
		T.eq(a.yours[1].value, "88")
	end)
end)

T.describe("v5 run shop model", function()
	T.it("ranks: 8 stats, costs from RunShop, affordability", function()
		local rows =
			RunShopModel.ranks(RunShop, { rinds = RunShop.rankCost("hide", 0), ranks = { might = 2 } })
		T.eq(#rows, 8)
		T.eq(rows[1].id, "might")
		T.eq(rows[1].rank, 2)
		T.eq(rows[1].cost, RunShop.rankCost("might", 2))
		T.eq(rows[2].cost, RunShop.rankCost("hide", 0)) -- hide rank 1
		T.truthy(rows[2].canBuy)
		T.falsy(rows[1].canBuy)
		local maxed = RunShopModel.ranks(RunShop, { rinds = 1e9, ranks = { might = RunShop.MAX_RANK } })
		T.eq(maxed[1].cost, nil)
		T.falsy(maxed[1].canBuy)
		T.eq(#RunShopModel.ranks(nil, nil), 0)
	end)
	T.it("stall offers, the class stall, owned buffs", function()
		local w = { whey = 300, buffs = { "rush" } }
		local o = RunShopModel.stall(RunShop, { id = "s1", offers = { "rush", "keen" } }, w, "elephante")
		T.eq(#o, 2)
		T.truthy(o[1].owned)
		T.falsy(o[1].canBuy)
		T.truthy(o[2].canBuy)
		local poor = { whey = RunShop.CLASS_BUFF_COST - 1, buffs = {} }
		local cls = RunShopModel.stall(
			RunShop,
			{ id = "class", offers = { "class" }, class = true },
			poor,
			"elephante"
		)
		T.eq(cls[1].name, "Thunder Tusks")
		T.eq(cls[1].cost, RunShop.CLASS_BUFF_COST)
		T.falsy(cls[1].canBuy)
	end)
	T.it("altar: closed before stage 3, max 2, funds", function()
		local rich = { rinds = 20000, whey = 2000, ultimates = {} }
		local early = RunShopModel.altar(RunShop, { open = false }, rich, 2)
		T.eq(early[1].why, "stage")
		local open = RunShopModel.altar(RunShop, { open = true }, rich, 3)
		T.truthy(open[1].canBuy)
		local full = RunShopModel.altar(
			RunShop,
			{ open = true },
			{ rinds = 20000, whey = 2000, ultimates = { "titan", "overdrive" } },
			3
		)
		T.eq(full[1].why, "owned")
		T.eq(full[2].why, "max")
		local poor = RunShopModel.altar(RunShop, { open = true }, { rinds = 10, whey = 0 }, 3)
		T.eq(poor[1].why, "funds")
	end)
	T.it("swap preview matches the stand's rate and fee", function()
		T.eq(
			RunShopModel.swapPreview(RunShop, 1000),
			math.floor(1000 / RunShop.SWAP_RATE * (1 - RunShop.SWAP_FEE))
		)
		T.eq(RunShopModel.swapPreview(RunShop, RunShop.SWAP_RATE - 1), 0)
	end)
	T.it("what's left: nearest first, owned skipped, altar last line", function()
		local shops = {
			stalls = {
				{ id = "s1", x = 100, z = 0, offers = { "rush", "keen" } },
				{ id = "s2", x = 10, z = 0, offers = { "bloom", "greed" } },
				{ id = "class", x = 50, z = 0, offers = { "class" }, class = true },
			},
			altar = { x = 0, z = 0, open = false },
		}
		local list =
			RunShopModel.whatsLeft(RunShop, shops, { whey = 260, buffs = { "rush" } }, 0, 0, 1, "jumbo")
		T.eq(list[1].kind, "altar")
		T.eq(list[2].text, "Bloom")
		local names = {}
		for _, e in list do
			table.insert(names, e.text)
		end
		T.falsy(table.find(names, "Rush"), "owned buff skipped")
		T.truthy(table.find(names, "Gale Ears"), "class buff listed")
		T.eq(#RunShopModel.whatsLeft(RunShop, nil, nil, 0, 0, 1, nil), 0)
	end)
	T.it("level buffs list", function()
		-- iteration 4 gains: +3% HP and +2% damage every level, +1 armor every 5
		local have, nextUp = RunShopModel.levels(12, nil)
		T.eq(have[1], "+33% max HP (+3% per level)")
		T.eq(have[2], "+22% damage (+2% per level)")
		T.eq(have[3], "+2 armor (+1 every 5 levels)")
		T.eq(nextUp[2], "Level 15: +1 armor")
		T.eq(nextUp[3], "Level 15: an upgrade pick")
		local rows = RunShopModel.levelRows(4, nil, 2)
		T.eq(#rows, 5) -- levels 2..6
		T.eq(rows[4].text, "+3% HP · +2% dmg · +1 armor · 🃏 upgrade pick")
		T.falsy(rows[4].reached)
		T.truthy(rows[3].reached)
		T.eq(RunShopModel.short(12345), "12.3k")
	end)
end)

return T.finish()
