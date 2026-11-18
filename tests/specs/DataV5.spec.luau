-- v5 long-term progression (iteration 1, Team P): profile v7, the account-wide Herd
-- Talent Board, stomps / evolutions / free unlocks, charms, run bonuses.
local T = require("../lib/Test")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local ClassProgress = require("../../src/shared/Data/ClassProgress")
local HerdTalents = require("../../src/shared/Data/HerdTalents")
local Evolution = require("../../src/shared/Data/Evolution")
local Charms = require("../../src/shared/Data/Charms")
local RunBonus = require("../../src/shared/Data/RunBonus")
local Progress = require("../../src/shared/Data/Progress")
local Stats = require("../../src/shared/Run/Stats")
local H = require("../../src/shared/Config/HerdTalents")
local E = require("../../src/shared/Config/Evolutions")
local C = require("../../src/shared/Config/Charms")
local Monetization = require("../../src/shared/Config/Monetization")

local DAY = 20800
local UID = 777

local function v6Save(): any
	return {
		version = 6,
		cheese = 900,
		level = 12,
		unlockedClasses = { elephante = true, ele_fonte = true, ellie_fawn = true },
		classes = {
			elephante = { xp = 0, level = 30, perks = {}, stars = 2, starXp = 300 },
			ele_fonte = { xp = 40, level = 5, perks = {} },
			ellie_fawn = { xp = 0, level = 1, perks = {} },
		},
		stats = { runs = 120, wins = 30, extractions = 50, bestStage = 4, championKills = 80, ranked = {} },
		quests = {},
		pass = { season = 1, xp = 2500 },
		titles = { title_veteran = true },
		settings = { hints = true },
	}
end

T.describe("Profile v7 migration (additive, Z-6 seed)", function()
	T.it("is version 7 and v6 -> v7 keeps every v6 field", function()
		T.eq(ProfileSchema.VERSION, 7)
		local raw = v6Save()
		local before = ProfileSchema.deepCopy(raw)
		local p, info = ProfileSchema.migrate(raw)
		local pa = p :: any
		T.falsy(info.failed)
		T.deepEq(raw, before, "the raw save is untouched")
		T.eq(pa.version, 7)
		T.eq(pa.cheese, 900)
		T.eq(pa.level, 12)
		T.eq(pa.classes.elephante.level, 30)
		T.eq(pa.classes.elephante.stars, 2)
		T.eq(pa.classes.elephante.starXp, 300)
		T.eq(pa.classes.ele_fonte.xp, 40)
		T.eq(pa.stats.championKills, 80)
		T.eq(pa.pass.xp, 2500)
		T.truthy(pa.titles.title_veteran)
		T.eq(pa.settings.hints, true)
		T.truthy(type(pa.herdTalents) == "table" and pa.herdTalents.points == 0)
		T.truthy(type(pa.charms) == "table" and #pa.charms.inv == 0)
	end)
	T.it("veterans are seeded with stomps = floor(1.2 x lifetime class XP); never 0", function()
		local p = ProfileSchema.migrate(v6Save()) :: any
		local life = ClassProgress.totalXpFor(30) + 2 * ClassProgress.STAR_XP + 300
		T.eq(p.classes.elephante.stomps, math.floor(1.2 * life))
		T.eq(p.classes.ele_fonte.stomps, math.floor(1.2 * (ClassProgress.totalXpFor(5) + 40)))
		T.eq(p.stats.stomps, p.classes.elephante.stomps + p.classes.ele_fonte.stomps)
		T.truthy(p.stats.stomps > 0)
		T.eq(p.stompSeedNotice, p.stats.stomps, "one-time toast amount")
		-- re-migrating a v7 save changes nothing
		local again = ProfileSchema.migrate(ProfileSchema.deepCopy(p))
		T.deepEq(again, p)
	end)
	T.it("every older version (v1..v5) reaches v7 with stomps seeded and v7 blocks", function()
		for v = 1, 5 do
			local p = ProfileSchema.migrate({
				version = v,
				cheese = 5,
				unlockedClasses = { elephante = true },
			}) :: any
			T.eq(p.version, 7, "v" .. v)
			T.eq(p.cheese, 5)
			T.eq(type(p.stats.stomps), "number")
			T.truthy(type(p.herdTalents) == "table")
		end
	end)
	T.it("repairs corrupted v7 blocks", function()
		local raw = v6Save()
		raw.version = 7
		raw.herdTalents = {
			points = -5,
			spent = 1e9,
			ranks = { brawn = 999, nope = 3, guard = "x" },
			bands = { ["9"] = true },
		}
		raw.charms = {
			inv = {
				{ id = 1, type = "might", rarity = 9 },
				{ id = 2, type = "fortune", rarity = 1 },
				{ id = 3, type = "vigor", rarity = 2 },
				{ id = 3, type = "vigor", rarity = 2 },
			},
			equipped = { ["1"] = 3, ["2"] = 3, ["3"] = 99 },
			nextId = 0,
		}
		local p = ProfileSchema.migrate(raw) :: any
		T.eq(p.herdTalents.points, 0)
		T.deepEq(p.herdTalents.ranks, { brawn = 50 })
		T.eq(p.herdTalents.spent, H.totalCost(50), "spent is recomputed, never trusted")
		T.deepEq(p.herdTalents.bands, {})
		T.eq(#p.charms.inv, 1, "only the valid, unique charm survives")
		T.deepEq(p.charms.equipped, { ["1"] = 3 })
		T.eq(p.charms.nextId, 4)
	end)
end)

T.describe("Herd Talent Board (account-wide)", function()
	T.it("rank costs 10 / 20 / 30 TP; a 50-rank talent is 1,100 TP", function()
		T.eq(H.rankCost(1), 10)
		T.eq(H.rankCost(11), 20)
		T.eq(H.rankCost(31), 30)
		T.eq(H.totalCost(50), 1100) -- 10x10 + 20x20 + 20x30 (V5 text said 120 x10; the curve gives 110)
		for _, def in H.LIST do
			T.falsy(def.id == "fortune", "no Fortune talent (Z-13)")
		end
	end)
	T.it("income: x(1 + 0.2 P), x1.5 extract, x2 full clear; first-of-day and weekly band bonus", function()
		local wipe = HerdTalents.runPoints({ bosses = 1, championKills = 1, stagesCleared = 1 })
		T.eq(wipe, 30 + 10 + 10)
		local ext = HerdTalents.runPoints({ bosses = 2, stagesCleared = 2, extracted = true })
		T.eq(ext, math.floor((60 + 20 + 20) * 1.5 + 0.5))
		local full = HerdTalents.runPoints({
			bosses = 4,
			stagesCleared = 4,
			extracted = true,
			win = true,
			fullClear = true,
			pressure = 10,
		})
		T.eq(full, math.floor((120 + 40 + 20 + 50) * 3 * 2 + 0.5))
		local p = ProfileSchema.default() :: any
		local a = HerdTalents.award(
			p,
			{ bosses = 4, stagesCleared = 4, extracted = true, fullClear = true, pressure = 12 },
			DAY
		)
		T.eq(a.firstDay, 100, "first match of the day: double, up to +100")
		T.eq(a.weekly, 500, "band P10-14 weekly bonus")
		local b = HerdTalents.award(
			p,
			{ bosses = 4, stagesCleared = 4, extracted = true, fullClear = true, pressure = 12 },
			DAY
		)
		T.eq(b.firstDay, 0)
		T.eq(b.weekly, 0, "once per band per week")
		local c = HerdTalents.award(p, { fullClear = true, extracted = true, pressure = 0 }, DAY)
		T.eq(c.weekly, 100, "another band pays")
		local d = HerdTalents.award(p, { fullClear = true, extracted = true, pressure = 12 }, DAY + 7)
		T.eq(d.weekly, 500, "a new week")
		T.eq(p.herdTalents.points, a.points + b.points + c.points + d.points)
	end)
	T.it("spend and respec (free once a day, then cheese)", function()
		local p = ProfileSchema.default() :: any
		p.herdTalents.points = 35
		T.truthy(HerdTalents.spend(p, "brawn"))
		T.truthy(HerdTalents.spend(p, "brawn"))
		T.truthy(HerdTalents.spend(p, "brawn"))
		T.deepEq({ HerdTalents.spend(p, "brawn") }, { false, "no_points" })
		T.deepEq({ HerdTalents.spend(p, "nope") }, { false, "unknown_talent" })
		T.eq(p.herdTalents.points, 5)
		local ok, res = HerdTalents.respec(p, DAY)
		T.truthy(ok)
		T.eq(res.cost, 0)
		T.eq(p.herdTalents.points, 35)
		HerdTalents.spend(p, "guard")
		T.deepEq({ HerdTalents.respec(p, DAY) }, { false, "insufficient_funds" })
		p.cheese = H.RESPEC_CHEESE
		T.truthy(HerdTalents.respec(p, DAY))
		T.eq(p.cheese, 0)
	end)
	T.it("board damage is PvE-only through Run/Stats; other stats apply", function()
		local p = ProfileSchema.default() :: any
		p.herdTalents.ranks = { brawn = 50, bulk = 50, focus = 25, packed_lunch = 20, scavenger = 10 }
		local r = RunBonus.resolve(HerdTalents.bonus(p))
		T.near(r.pve, 0.25, 1e-9)
		T.eq(r.extras.startRinds, 400)
		T.near(r.extras.rindMult, 1.08, 1e-9)
		T.near(r.extras.wheyMult, 1.08, 1e-9)
		local base = Stats.compute("elephante", {}, {}) :: any
		local s = Stats.compute("elephante", {}, {}, nil, nil, nil, r) :: any
		T.near(s.damageMult, base.damageMult, 1e-9, "never against heroes")
		T.near(s.pveDamageMult, 1.25, 1e-9)
		T.near(s.maxHp, base.maxHp * 1.3, 1e-6)
		T.near(s.cooldownMult, base.cooldownMult * 0.95, 1e-9)
	end)
end)

T.describe("Stomps, evolutions and free unlocks", function()
	T.it("match stomps = mice x (1 + 0.05 P), no outcome multiplier", function()
		T.eq(Evolution.matchStomps(100, 0), 100)
		T.eq(Evolution.matchStomps(100, 10), 150)
		T.eq(Evolution.matchStomps(-5, 3), 0)
	end)
	T.it("stages at 2,500 / 15,000 / 60,000; pips every 20%; display choice", function()
		T.eq(Evolution.stageFor(2499), 1)
		T.eq(Evolution.stageFor(2500), 2)
		T.eq(Evolution.stageFor(60000), 4)
		T.eq(Evolution.pips(0), 0)
		T.eq(Evolution.pips(1000), 2)
		local p = ProfileSchema.default() :: any
		local a = Evolution.addStomps(p, "elephante", 16000)
		T.eq(a.stage, 3)
		T.eq(p.stats.stomps, 16000)
		T.deepEq({ Evolution.setEvo(p, "elephante", 4) }, { false, "evo_locked" })
		T.truthy(Evolution.setEvo(p, "elephante", 2))
		T.eq(Evolution.displayStage(p, "elephante"), 2)
		local r = RunBonus.resolve(Evolution.bonus(p, "elephante"))
		T.near(r.pve, 0.03, 1e-9, "bonuses follow the unlocked stage, not the look")
		T.near(r.delta.mul.maxHp, 1.03, 1e-9)
	end)
	T.it("free class unlocks at 3k / 8k / 20k / 50k account stomps (cheese buy stays)", function()
		local order = {}
		for _, u in E.FREE_UNLOCKS do
			table.insert(order, u.stomps)
		end
		T.deepEq(order, { 3000, 8000, 20000, 50000 })
		local p = ProfileSchema.default() :: any
		local a = Evolution.addStomps(p, "elephante", 8500)
		T.deepEq(a.unlocked, { "le_fante", "filet" })
		T.truthy(p.unlockedClasses.filet)
		T.truthy(type(p.classes.filet) == "table")
		T.deepEq(Evolution.addStomps(p, "ellie_fawn", 100).unlocked, {})
	end)
end)

T.describe("Charms", function()
	T.it("no Fortune or Luck; never in any Robux item", function()
		T.eq(C.get("fortune"), nil)
		T.eq(C.get("luck"), nil)
		for _, item in Monetization.ALL do
			T.falsy(string.find(string.lower(item.benefit), "charm", 1, true), item.key)
		end
	end)
	T.it("rolls are deterministic per seed, with the Pressure-band and stage-4 floors", function()
		T.deepEq(Charms.roll(42, 0, 1), Charms.roll(42, 0, 1))
		for seed = 1, 200 do
			T.truthy(Charms.roll(seed, 21, 1).rarity >= 3, "P20+ is at least Epic")
			T.truthy(Charms.roll(seed, 12, 1).rarity >= 2, "P10+ is at least Rare")
			T.truthy(Charms.roll(seed, 0, 4).rarity >= 2, "stage 4: Rare+")
		end
		local commons = 0
		for seed = 1, 500 do
			if Charms.roll(seed, 0, 1).rarity == 1 then
				commons += 1
			end
		end
		T.truthy(commons > 250 and commons < 450, "about 70% Common at P0: " .. commons)
	end)
	T.it("grant, sockets by level, fuse, salvage, full bag", function()
		local p = ProfileSchema.default() :: any
		for _ = 1, 3 do
			Charms.grant(p, { type = "might", rarity = 1, tier = 2 }, DAY)
		end
		T.eq(#p.charms.inv, 3)
		T.truthy(Charms.equip(p, 1, 1))
		T.deepEq({ Charms.equip(p, 2, 2) }, { false, "slot_locked" })
		p.level = 10
		T.truthy(Charms.equip(p, 2, 2))
		T.truthy(Charms.equip(p, 1, 2), "moving a charm empties its old socket")
		T.eq(p.charms.equipped["2"], nil)
		local ok, made = Charms.fuse(p, "might", 1)
		T.truthy(ok)
		T.eq(made.rarity, 2)
		T.eq(made.tier, 2)
		T.eq(#p.charms.inv, 1)
		T.deepEq(p.charms.equipped, {}, "fused charms are unequipped")
		local cheese = p.cheese
		T.truthy(Charms.salvage(p, made.id))
		T.eq(p.cheese, cheese + C.SALVAGE_CHEESE[2])
		for _ = 1, C.INVENTORY do
			Charms.grant(p, { type = "vigor", rarity = 1, tier = 1 }, DAY)
		end
		local ch, salvaged = Charms.grant(p, { type = "vigor", rarity = 3, tier = 1 }, DAY)
		T.eq(ch, nil)
		T.eq(salvaged, C.SALVAGE_CHEESE[3], "a full bag never loses a drop silently")
	end)
	T.it("squad aura: the same type doesn't stack, the highest rarity wins", function()
		local r = RunBonus.resolve(Charms.aura({ { might = 1, vigor = 2 }, { might = 3 }, {} }))
		T.near(r.pve, C.get("might").values[3], 1e-9)
		T.near(r.delta.mul.maxHp, 1 + C.get("vigor").values[2], 1e-9)
	end)
end)

T.describe("afterRun: talent points, stomps and charm drops", function()
	T.it("one match adds TP, stomps and drops (deterministic for a seed)", function()
		local p = ProfileSchema.default() :: any
		p.stats.runs = 10
		local sum = Progress.afterRun(p, {
			day = DAY,
			userId = UID,
			classId = "elephante",
			stagesCleared = 4,
			stagesSurvived = 4,
			extracted = true,
			win = true,
			fullClear = true,
			bosses = 4,
			championKills = 2,
			mice = 500,
			pressure = 5,
			charmDrops = 2,
			stageReached = 4,
			charmSeed = 99,
		})
		T.truthy(sum.talentPoints.points > 0)
		T.eq(p.herdTalents.points, sum.talentPoints.points)
		T.eq(p.classes.elephante.stomps, Evolution.matchStomps(500, 5))
		T.eq(p.stats.stomps, Evolution.matchStomps(500, 5))
		T.eq(#sum.charms, 3, "2 boss charms + the stage-4 match drop")
		for _, ch in sum.charms do
			T.truthy(ch.rarity >= 2)
		end
		local view = ProfileSchema.view(p)
		T.eq(view.herdTalents.points, p.herdTalents.points)
		T.eq(view.evolution.total, p.stats.stomps)
		T.eq(#view.charms.inv, 3)
		T.eq(#view.charms.equipped, 3)
	end)
end)

return T.finish()
