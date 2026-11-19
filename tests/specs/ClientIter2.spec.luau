-- Iteration 2 pure client helpers (team U): the difficulty ladder and Early
-- Horn, Cheese Gems, Prestige / Ascension, Challenges and the V-menu ×5,
-- checked against Team P's real configs and views where they exist.
local T = require("../lib/Test")
local LadderModel = require("../../src/client/Util/LadderModel")
local GemModel = require("../../src/client/Util/GemModel")
local HeroModel = require("../../src/client/Util/HeroModel")
local Progression = require("../../src/client/Util/Progression")
local RunShopModel = require("../../src/client/Util/RunShopModel")
local Difficulty = require("../../src/shared/Config/Difficulty")
local GemsCfg = require("../../src/shared/Config/Gems")
local AscCfg = require("../../src/shared/Config/Ascension")
local ChallengesCfg = require("../../src/shared/Config/Challenges")
local RunShop = require("../../src/shared/Config/RunShop")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local GemsData = require("../../src/shared/Data/Gems")

T.describe("ladder", function()
	T.it("11 tiers from Config/Difficulty, cheese names, never Liberty's", function()
		local tiers = LadderModel.tiers(Difficulty)
		T.eq(#tiers, 11)
		T.eq(tiers[1].name, "Mild")
		T.eq(tiers[2].reward, 1)
		local liberty = {
			"Easy",
			"Normal",
			"Hard",
			"Brutal",
			"Insane",
			"Nightmare",
			"Chaotic",
			"Torture",
			"Inferno",
			"Torment",
			"Death",
		}
		for _, t in tiers do
			T.falsy(table.find(liberty, t.name), t.name)
		end
		T.eq(#LadderModel.tiers(nil), 11)
	end)
	T.it("tiles: locked above the unlock, best solo / squad, the lobby pick", function()
		local prof = { ladder = { unlocked = 4, bestSolo = { account = 3 }, bestSquad = 4 } }
		local tiles = LadderModel.view(Difficulty, prof, { tier = { tier = 3 } }, nil)
		T.falsy(tiles[4].locked)
		T.truthy(tiles[5].locked)
		T.truthy(tiles[3].selected)
		T.truthy(tiles[3].isBestSolo)
		T.truthy(tiles[4].isBestSquad)
		local u = LadderModel.record(nil, nil)
		T.eq(u, 2)
		T.eq(LadderModel.lobbyTier({ tier = 6 }), 6)
		T.eq(LadderModel.lobbyTier(nil), nil)
	end)
	T.it("Early Horn setting: Off for rookies, else 70, cycles", function()
		T.eq(LadderModel.skipWaveAt({ stats = { runs = 0 } }), 0)
		T.eq(LadderModel.skipWaveAt({ stats = { runs = 5 } }), 70)
		T.eq(LadderModel.skipWaveAt({ settings = { skipWaveAt = 50 }, stats = { runs = 0 } }), 50)
		T.eq(LadderModel.nextSkip(90), 0)
		T.eq(LadderModel.skipLabel(0), "Off")
		T.eq(LadderModel.skipLabel(70), "70%")
	end)
	T.it("waves and the horn", function()
		local w = LadderModel.wave({ wave = 10, waves = 20 }, nil)
		assert(w, "wave")
		T.truthy(w.boss)
		T.eq(w.stageWave, 5)
		T.eq(LadderModel.wave({}, {}), nil)
		T.eq(LadderModel.horn({ stomped = 0.72, need = 0.7 }, 0).phase, "ready")
		T.eq(LadderModel.horn({ stomped = 0.4, need = 0.7 }, 0).phase, nil)
		local h = LadderModel.horn({ at = 13, streak = 3 }, 10)
		T.eq(h.phase, "warning")
		T.near(h.seconds :: number, 3)
		T.eq(h.streak, 3)
	end)
end)

T.describe("Team P final shapes", function()
	T.it("ladder perClass bests, difficulty alias, top-level skipWaveAt, done count", function()
		local prof = {
			difficulty = {
				unlocked = 5,
				bestSolo = 4,
				bestSquad = 5,
				perClass = { jumbo = { bestSolo = 2, bestSquad = 3 } },
			},
			skipWaveAt = 90,
			stats = { runs = 0 },
		}
		local u, solo, squad = LadderModel.record(prof, "jumbo")
		T.eq(u, 5)
		T.eq(solo, 2)
		T.eq(squad, 3)
		local _, s2 = LadderModel.record(prof, "filet")
		T.eq(s2, 4)
		T.eq(LadderModel.skipWaveAt(prof), 90)
		local list, done, total = Progression.challenges({
			list = {
				{ id = "a", name = "A", text = "x", done = true, reward = { dust = 5 } },
				{ id = "b", name = "B", text = "y" },
			},
			done = 1,
			total = 30,
		}, nil)
		T.eq(#list, 2)
		T.eq(done, 1)
		T.eq(total, 2)
		T.eq(list[1].id, "b")
	end)
end)

T.describe("gems against Team P's gemView", function()
	T.it("stats, unique, costs come from the server view", function()
		local raw = { id = 7, t = 6, s = { 40, 30, 20, 10, 5 }, u = GemsCfg.UNIQUE_ORDER[1], lv = 2 }
		local g = GemModel.gem(GemsData.gemView(raw))
		assert(g, "gem")
		T.eq(g.tier, 6)
		T.eq(g.level, 2)
		T.truthy(g.unique ~= nil)
		T.truthy(g.uniqueText ~= nil)
		T.eq(GemModel.upgradeCost(g), GemsCfg.upgradeCost(6, 3))
		T.eq(GemModel.salvageDust(g), GemsCfg.salvageDust(6, true))
		-- 40 rind points at +2: 40 x 0.001 x 1.2
		T.near(GemModel.statValue(g, "rinds", GemsCfg), 0.048, 1e-6)
		T.truthy(#GemModel.lines(g, GemsCfg) == 5)
	end)
	T.it("inventory view: sockets, dust, equipped first, totals", function()
		local view = {
			inv = {
				GemsData.gemView({ id = 1, t = 2, s = { 3, 3, 3, 3, 3 }, lv = 0 }),
				GemsData.gemView({ id = 2, t = 9, s = { 50, 50, 50, 50, 50 }, lv = 0 }),
			},
			equipped = { 1, 0, 0 },
			dust = 33,
			socketsOpen = 1,
			socketLevels = { 1, 10, 25 },
			capacity = 200,
		}
		local gv = GemModel.view(view, nil, GemsCfg)
		T.eq(gv.inv[1].id, 1)
		T.eq(gv.inv[1].equipped, 1)
		T.eq(gv.dust, 33)
		T.eq(gv.open, 1)
		T.truthy((gv.totals.rinds or 0) > 0)
		local capped = GemModel.squadTotals({ { bite = 0.5 }, { bite = 0.5 } })
		T.eq(capped.bite, 0.6)
		T.eq(#GemModel.view(nil, nil, nil).inv, 0)
	end)
	T.it("live profile: an empty gem block", function()
		local prof = ProfileSchema.default()
		local gv = GemModel.view(GemsData.view(prof), prof, GemsCfg)
		T.eq(#gv.inv, 0)
		T.eq(gv.capacity, 200)
	end)
end)

T.describe("hero: prestige and ascension", function()
	T.it("level 30 can prestige; the shown level restarts", function()
		local h =
			HeroModel.view({ level = 30, xp = 0, prestige = 0, canPrestige = true }, "elephante", AscCfg)
		T.truthy(h.canPrestige)
		T.eq(h.shownLevel, 30)
		local p = HeroModel.view(
			{ level = 30, prestige = 3, displayLevel = 7, prestigeXp = 100, prestigeXpToNext = 400 },
			"elephante",
			AscCfg
		)
		T.eq(p.shownLevel, 7)
		T.near(p.frac, 0.25)
		T.eq(p.nextFrame, 5)
	end)
	T.it("8 nodes in order, gated by prestige then stomps", function()
		local h = HeroModel.view(
			{ level = 30, prestige = 3, stomps = 12000, asc = "10000000" },
			"elephante",
			AscCfg
		)
		T.eq(#h.nodes, 8)
		T.truthy(h.nodes[1].owned)
		T.truthy(h.nodes[2].canUnlock)
		T.eq(h.nodes[3].why, "order")
		local h2 = HeroModel.view({ prestige = 0, stomps = 99999 }, "x", AscCfg)
		T.eq(h2.nodes[1].why, "prestige")
		local h3 = HeroModel.view({ prestige = 1, stomps = 10, ascension = { bits = {} } }, "x", AscCfg)
		T.eq(h3.nodes[1].why, "stomps")
		T.truthy(string.find(HeroModel.prestigeBonus(40), "+20.0% PvE", 1, true) ~= nil)
	end)
end)

T.describe("challenges and the V menu", function()
	T.it("30 challenges from the config, open first, gem / dust rewards", function()
		local list, done, total = Progression.challenges({ done = { "bare_trunk" } }, ChallengesCfg)
		T.eq(total, 30)
		T.eq(done, 1)
		T.falsy(list[1].done)
		T.truthy(list[#list].done)
		local hasGem = false
		for _, c in list do
			if string.find(c.reward.text, "gem", 1, true) then
				hasGem = true
			end
		end
		T.truthy(hasGem)
		T.eq(Progression.reward({ dust = 10 }).text, "✨ 10 dust")
	end)
	T.it("buy ×5: count and total within the rinds", function()
		local n, total = RunShopModel.multiCost(RunShop, "hide", 0, 5, 1e9)
		T.eq(n, 5)
		T.eq(total, RunShop.rankTotal("hide", 5))
		local n2 = RunShopModel.multiCost(RunShop, "hide", 0, 5, 45)
		T.eq(n2, 2) -- 20 + 23
		T.eq(RunShopModel.multiCost(RunShop, "hide", 25, 5, 1e9), 0)
		T.truthy(RunShopModel.anyAffordable(RunShop, { rinds = 20 }))
		T.falsy(RunShopModel.anyAffordable(RunShop, { rinds = 5 }))
	end)
end)

return T.finish()
