local T = require("../lib/Test")
local Pressure = require("../../src/shared/Run/Pressure")
local Config = require("../../src/shared/Config/Pressure")
local Stats = require("../../src/shared/Run/Stats")

-- A board with every modifier at its max rank.
local function maxBoard(): { [string]: number }
	local b = {}
	for _, def in Config.LIST do
		b[def.id] = def.maxRank
	end
	return b
end

T.describe("Config/Pressure", function()
	T.it("has the 8 GDD §3.7 modifiers with their max ranks", function()
		local want = {
			stampede = 3,
			big_cheese = 2,
			rush_hour = 3,
			slingshot_season = 2,
			hot_crumbs = 3,
			boss_fury = 3,
			thick_rind = 3,
			no_snacks = 2,
		}
		T.eq(#Config.LIST, 8)
		T.eq(#Config.ORDER, 8)
		for id, max in want do
			local def = Config.get(id)
			T.truthy(def, id)
			T.eq((def :: any).maxRank, max, id)
			T.eq((def :: any).points, 1, id)
		end
		T.eq(Config.MAX_POINTS, 21)
		T.eq(Pressure.MAX_POINTS, 21)
	end)
	T.it("every perRank field is a WorldMods field with a default", function()
		local defaults = Stats.defaultWorldMods() :: any
		for _, def in Config.LIST do
			T.truthy(def.name ~= "" and def.description ~= "" and def.icon ~= "", def.id)
			for field, per in def.perRank do
				T.eq(type(defaults[field]), "number", def.id .. "." .. field)
				T.truthy(per == per and per ~= 0, def.id .. "." .. field)
			end
		end
	end)
	T.it("unknown / non-string ids are nil", function()
		T.eq(Config.get("nope"), nil)
		T.eq(Config.get(5), nil)
		T.eq(Config.get(nil), nil)
	end)
end)

T.describe("Pressure.sanitize / clampRank / setRank", function()
	T.it("passes a valid board through", function()
		T.deepEq(Pressure.sanitize({ stampede = 2, no_snacks = 1 }), { stampede = 2, no_snacks = 1 })
	end)
	T.it("turns garbage into an empty board", function()
		for _, raw in { nil, 5, "board", true, function() end } do
			T.deepEq(Pressure.sanitize(raw), {})
		end
	end)
	T.it("drops unknown ids, non-string keys, rank 0 and non-numbers", function()
		local b = Pressure.sanitize({
			stampede = 1,
			nope = 3,
			[1] = 2,
			[true :: any] = 1,
			thick_rind = 0,
			boss_fury = "3",
			hot_crumbs = { 1 },
			big_cheese = true,
		})
		T.deepEq(b, { stampede = 1 })
	end)
	T.it("clamps overflow, negatives, fractions, NaN and inf", function()
		local b = Pressure.sanitize({
			stampede = 99,
			big_cheese = -4,
			rush_hour = 2.9,
			hot_crumbs = 0 / 0,
			boss_fury = math.huge,
			thick_rind = -math.huge,
			no_snacks = 1e300,
		})
		T.deepEq(b, { stampede = 3, rush_hour = 2, no_snacks = 2 })
		T.eq(Pressure.clampRank("stampede", 1e9), 3)
		T.eq(Pressure.clampRank("big_cheese", 3), 2)
		T.eq(Pressure.clampRank("stampede", -1), 0)
		T.eq(Pressure.clampRank("nope", 2), 0)
		T.eq(Pressure.clampRank("stampede", "2"), 0)
	end)
	T.it("looks at no more than MAX_RAW_KEYS keys of a huge table", function()
		local raw: { [string]: number } = {}
		for i = 1, 10000 do
			raw["junk" .. i] = 1
		end
		raw.stampede = 1
		local b = Pressure.sanitize(raw)
		T.truthy(Pressure.points(b) <= 1)
	end)
	T.it("setRank returns a new clamped board and never mutates the input", function()
		local b = { stampede = 1 }
		local nb = Pressure.setRank(b, "stampede", 7) :: any
		T.eq(nb.stampede, 3)
		T.eq(b.stampede, 1)
		local cleared = Pressure.setRank(nb, "stampede", 0) :: any
		T.eq(cleared.stampede, nil)
		T.eq(Pressure.setRank(b, "nope", 1), nil)
		T.deepEq(Pressure.setRank("garbage", "hot_crumbs", 2), { hot_crumbs = 2 })
	end)
end)

T.describe("Pressure.points and rewards", function()
	T.it("counts 1 point per rank, 21 for the full board", function()
		T.eq(Pressure.points({}), 0)
		T.eq(Pressure.points({ stampede = 2, no_snacks = 1 }), 3)
		T.eq(Pressure.points(maxBoard()), 21)
		T.eq(Pressure.points({ stampede = 50, nope = 9 }), 3)
		T.eq(Pressure.points("x"), 0)
	end)
	T.it("+8% cheese, +0.05 luck and +2% epic per point", function()
		T.eq(Pressure.cheeseMult(0), 1)
		T.near(Pressure.cheeseMult(5), 1.4)
		T.near(Pressure.cheeseMult(21), 2.68)
		T.near(Pressure.luck(4), 0.2)
		T.near(Pressure.epicBonus(10), 0.2)
	end)
	T.it("reward functions clamp garbage points", function()
		T.eq(Pressure.cheeseMult(0 / 0), 1)
		T.eq(Pressure.cheeseMult(-5), 1)
		T.near(Pressure.cheeseMult(1e9), 1 + 0.08 * 21)
		T.eq(Pressure.luck("3"), 0)
		T.eq(Pressure.epicBonus(math.huge), 0, "inf is garbage, not max")
	end)
	T.it("preview gives whole-percent numbers for the lobby", function()
		local p = Pressure.preview({ stampede = 3, thick_rind = 2 })
		T.eq(p.points, 5)
		T.eq(p.cheesePct, 40)
		T.near(p.luck, 0.25)
		T.eq(p.epicPct, 10)
		T.deepEq(Pressure.preview(nil), { points = 0, cheesePct = 0, luck = 0, epicPct = 0 })
	end)
end)

T.describe("Pressure.worldDelta / applyToMods", function()
	T.it("an empty board changes nothing", function()
		local base = Stats.worldMods(2, 3, {}, 2.2)
		local mods = Pressure.applyToMods(table.clone(base), {})
		T.deepEq(mods, base)
		T.deepEq(Pressure.worldDelta({}), {})
	end)
	T.it("ranks scale linearly: factor = 1 + perRank x rank", function()
		local d = Pressure.worldDelta({ stampede = 3, hot_crumbs = 2, no_snacks = 2, slingshot_season = 2 })
		T.near(d.eliteSpeedMult, 1.9)
		T.near(d.enemyProjectileSpeedMult, 1.4)
		T.near(d.healingMult, 0.5)
		T.eq(d.rangedExtraProjectiles, 2)
	end)
	T.it("multiplies existing Mult fields and adds the rest", function()
		local base = Stats.worldMods(1, 2, { "curse_tough_mice" }, 3)
		local mods = Pressure.applyToMods(table.clone(base), maxBoard()) :: any
		T.near(mods.enemyHpMult, base.enemyHpMult * 1.45)
		T.near(mods.bossHpMult, base.bossHpMult * 1.45)
		T.near(mods.bossDamageMult, base.bossDamageMult * 1.6)
		T.near(mods.enemyProjectileSpeedMult, base.enemyProjectileSpeedMult * 1.6)
		T.near(mods.healingMult, base.healingMult * 0.5)
		T.near(mods.eliteSpeedMult, 1.9)
		T.near(mods.eliteSizeMult, 1.5)
		T.near(mods.lateSpawnMult, 1.6)
		T.eq(mods.rangedExtraProjectiles, 2)
		-- untouched by Pressure
		T.eq(mods.enemySpeedMult, base.enemySpeedMult)
		T.eq(mods.spawnRateMult, base.spawnRateMult)
		T.eq(mods.eliteChance, base.eliteChance)
		T.eq(mods.enemyDamageMult, base.enemyDamageMult)
		T.eq(mods.oneHitKO, base.oneHitKO)
	end)
	T.it("garbage boards apply only their valid part", function()
		local base = Stats.worldMods(1, 1, {}, 1)
		local mods =
			Pressure.applyToMods(table.clone(base), { boss_fury = 99, nope = 5, thick_rind = 0 / 0 }) :: any
		T.near(mods.bossDamageMult, base.bossDamageMult * 1.6)
		T.eq(mods.enemyHpMult, base.enemyHpMult)
	end)
	T.it("healing never goes negative and extra projectiles stay whole", function()
		local mods = Stats.defaultWorldMods() :: any
		mods.healingMult = 0.1
		Pressure.applyToMods(mods, { no_snacks = 2 })
		T.truthy(mods.healingMult >= 0)
		local m2 = Stats.defaultWorldMods() :: any
		m2.rangedExtraProjectiles = 0.4
		Pressure.applyToMods(m2, { slingshot_season = 1 })
		T.eq(m2.rangedExtraProjectiles, 1)
	end)
end)

T.describe("Pressure.pickLeader", function()
	T.it("the first human to ready up leads", function()
		local id = Pressure.pickLeader({
			{ id = 1, ready = true, readyAt = 50, joinedAt = 1 },
			{ id = 2, ready = true, readyAt = 20, joinedAt = 9 },
			{ id = 3, ready = false, joinedAt = 0, willing = true },
		})
		T.eq(id, 2)
	end)
	T.it("nobody ready: the earliest-joined willing player, then anyone present", function()
		T.eq(
			Pressure.pickLeader({
				{ id = 1, ready = false, joinedAt = 1, willing = false },
				{ id = 2, ready = false, joinedAt = 5, willing = true },
				{ id = 3, ready = false, joinedAt = 3, willing = true },
			}),
			3
		)
		T.eq(
			Pressure.pickLeader({
				{ id = 7, ready = false, joinedAt = 4 },
				{ id = 8, ready = false, joinedAt = 2 },
			}),
			8
		)
	end)
	T.it("Studio players (-1..-8) are valid leaders; empty / garbage input gives nil", function()
		T.eq(Pressure.pickLeader({ { id = -2, ready = true, readyAt = 1, joinedAt = 1 } }), -2)
		T.eq(Pressure.pickLeader({}), nil)
		T.eq(Pressure.pickLeader({ 5 :: any, { id = "x" } :: any }), nil)
	end)
	T.it("a ready player without readyAt ranks after timed ones; ties use joinedAt then id", function()
		T.eq(
			Pressure.pickLeader({
				{ id = 1, ready = true, joinedAt = 0 },
				{ id = 2, ready = true, readyAt = 99, joinedAt = 5 },
			}),
			2
		)
		T.eq(
			Pressure.pickLeader({
				{ id = 9, ready = true, readyAt = 3, joinedAt = 2 },
				{ id = 4, ready = true, readyAt = 3, joinedAt = 2 },
			}),
			4
		)
	end)
end)

T.describe("Pressure unlock rules", function()
	T.it("a win unlocks the board and records the points", function()
		local pp = Pressure.defaultProfile()
		local unlockedNow, record = Pressure.recordRun(pp, true, 0)
		T.truthy(unlockedNow)
		T.falsy(record, "0 is not a record")
		T.truthy(pp.unlocked)
		T.eq(pp.highestCleared, 0)
		unlockedNow, record = Pressure.recordRun(pp, true, 6)
		T.falsy(unlockedNow)
		T.truthy(record)
		T.eq(pp.highestCleared, 6)
		_, record = Pressure.recordRun(pp, true, 4)
		T.falsy(record)
		T.eq(pp.highestCleared, 6, "never goes down")
	end)
	T.it("a wipe neither unlocks nor records", function()
		local pp = Pressure.defaultProfile()
		local u, r = Pressure.recordRun(pp, false, 15)
		T.falsy(u)
		T.falsy(r)
		T.falsy(pp.unlocked)
		T.eq(pp.highestCleared, 0)
	end)
	T.it("clamps garbage points to 0..MAX_POINTS", function()
		local pp = Pressure.defaultProfile()
		Pressure.recordRun(pp, true, 1e9)
		T.eq(pp.highestCleared, 21)
		local pp2 = Pressure.defaultProfile()
		Pressure.recordRun(pp2, true, 0 / 0)
		T.eq(pp2.highestCleared, 0)
	end)
	T.it("sanitizeProfile repairs any saved shape", function()
		T.deepEq(Pressure.sanitizeProfile(nil), Pressure.defaultProfile())
		T.deepEq(
			Pressure.sanitizeProfile({
				unlocked = "yes",
				highestCleared = -3,
				board = { stampede = 9, x = 1 },
			}),
			{ unlocked = false, highestCleared = 0, board = { stampede = 3 } }
		)
		T.truthy(Pressure.isUnlocked({ unlocked = true }))
		T.falsy(Pressure.isUnlocked(nil))
	end)
	T.it("badges at 5, 10 and 20", function()
		T.deepEq(Pressure.badges(4), {})
		T.deepEq(Pressure.badges(10), { 5, 10 })
		T.deepEq(Pressure.badges(21), { 5, 10, 20 })
	end)
end)

return T.finish()
