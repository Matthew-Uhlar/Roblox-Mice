-- Profile v6 (v4 plan, Team P): the migration is ADDITIVE ONLY. Every older save
-- (v1..v5) must reach v6 with every field it had, unchanged, plus the new blocks.
local T = require("../lib/Test")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local Award = require("../../src/shared/Data/Award")

local function deepCopy(v: any): any
	return ProfileSchema.deepCopy(v)
end

-- A realistic save of each past version, with values different from the defaults.
local function v1(): any
	return {
		version = 1,
		cheese = 12345,
		xp = 77,
		level = 9,
		unlockedClasses = { elephante = true, ele_fonte = true, ellie_fawn = true, jumbo = true },
		selectedClass = "jumbo",
		talents = { thick_hide = 3, heavy_trunk = 2 },
		cosmetics = { hat_party = true, trail_crumbs = true },
		equipped = { hat = "hat_party", trail = "trail_crumbs" },
		secondWindTokens = 4,
		rerollTokens = 7,
		daily = { lastClaimDay = 20000, streak = 12 },
		stats = { runs = 40, wins = 6, deepestCycle = 2, bossesKilled = 31, fastestCycle1 = 900 },
		purchaseHistory = { ["pid-1"] = true },
		settings = { hints = false },
	}
end

local function v2(): any
	local r = v1()
	r.version = 2
	r.goldenCheese = 640
	r.stats.ranked = { wins = 5, deepestCycle = 2, fastestCycle1 = 950 }
	r.purchaseOrder = { "pid-1" }
	r.boosts = { cheese2xUntil = 1_900_000_000, feastPending = 1 }
	r.club = { lastDailyDay = 20000, monthsGranted = { ["24300"] = true } }
	r.ads = { day = 20000, count = 2 }
	r.lastRun = { cheese = 300, adClaimed = false }
	r.firstRunDay = 20001
	return r
end

local function v3(): any
	local r = v2()
	r.version = 3
	r.cosmetics.hat_viking = true
	r.passGrants = { wardrobe = { cosmetics = { hat_viking = true }, classes = {} } }
	return r
end

local function v4(): any
	local r = v3()
	r.version = 4
	r.pressure = { unlocked = true, highestCleared = 6, board = { stampede = 2 } }
	r.discoveries = { grandmas_pantry = true }
	return r
end

local function v5(): any
	local r = v4()
	r.version = 5
	r.classes = {
		elephante = { xp = 0, level = 30, perks = {} }, -- level 30 keeps no xp (v5 rule)
		jumbo = { xp = 55, level = 12, perks = {} },
		ele_fonte = { xp = 0, level = 1, perks = {} },
		ellie_fawn = { xp = 0, level = 1, perks = {} },
	}
	r.ownedSkins = { elephante_gilded = true }
	r.respecTokens = 2
	r.stats.heroDowns = 9
	r.stats.lastHerd = 1
	r.stats.ranked.heroDowns = 8
	r.stats.ranked.lastHerd = 1
	r.settings.busy = true -- a v4 server could have saved it: never kept
	return r
end

local SAVES = { v1, v2, v3, v4, v5 }

-- Every leaf of `old` must be in `new` with the same value (except the version and
-- known v6 normalisations).
local SKIP = { version = true }
local function assertKept(old: any, new: any, path: string)
	for k, v in old do
		local p = path .. "." .. tostring(k)
		if not SKIP[k] and not (path == "" and k == "settings") then
			if type(v) == "table" then
				T.truthy(type(new[k]) == "table", p .. " kept as a table")
				if type(new[k]) == "table" then
					assertKept(v, new[k], p)
				end
			else
				T.eq(new[k], v, p .. " kept")
			end
		end
	end
end

T.describe("ProfileSchema v6: additive migration from every past version", function()
	T.it("the current version is at least 6", function()
		T.truthy(ProfileSchema.VERSION >= 6)
	end)
	for i, make in SAVES do
		T.it(string.format("v%d -> v6 keeps every field and adds the v6 blocks", i), function()
			local raw = make()
			local before = deepCopy(raw)
			local p, info = ProfileSchema.migrate(raw)
			T.falsy(info.failed, "not failed")
			T.eq(info.fromVersion, i)
			T.eq(ProfileSchema.sessionMode(raw, info), "writable")
			T.deepEq(raw, before, "the raw save is not mutated")
			local pa = p :: any
			T.eq(pa.version, ProfileSchema.VERSION)
			assertKept(before, pa, "")
			T.eq(pa.settings.hints, false, "settings kept")
			T.eq(pa.settings.busy, nil, "busy is never persisted")
			for _, field in
				{
					"quests",
					"pass",
					"achievements",
					"collection",
					"accountRewards",
					"titles",
					"emotes",
					"entitlements",
				}
			do
				T.truthy(type(pa[field]) == "table", field .. " added")
			end
			T.eq(type(pa.stats.extractions), "number")
			T.eq(type(pa.stats.bestStage), "number")
			T.eq(type(pa.stats.championKills), "number")
			T.eq(type(pa.stats.ranked.bestStage), "number")
			T.eq(type(pa.stats.ranked.championKills), "number")
			-- veterans: old wins were extractions; a recorded full-clear time proves 4 stages
			T.eq(pa.stats.extractions, before.stats.wins)
			T.eq(pa.stats.bestStage, 4)
			T.eq(pa.firstExtractPaid, true, "a veteran who extracted gets no rookie bonus")
			-- round-trip: a saved v6 profile loads identically
			local again = ProfileSchema.migrate(deepCopy(pa))
			T.deepEq(again, pa, "v6 round-trip")
		end)
	end
	T.it("a fresh player has the rookie bonus available and empty v6 blocks", function()
		local p = ProfileSchema.default() :: any
		T.eq(p.firstExtractPaid, false)
		T.eq(p.stats.bestStage, 0)
		local m = ProfileSchema.migrate({ version = 5, cheese = 3 }) :: any
		T.eq(m.firstExtractPaid, false, "no wins: still a rookie")
		T.eq(m.stats.bestStage, 0)
	end)
	T.it("v5 class levels and perks survive; mastery stars start at 0", function()
		local p = ProfileSchema.migrate(v5()) :: any
		T.eq(p.classes.elephante.level, 30)
		T.eq(p.classes.jumbo.level, 12)
		T.eq(p.classes.jumbo.xp, 55)
		T.eq(p.classes.elephante.stars, nil)
		T.truthy(p.ownedSkins.elephante_gilded)
		T.eq(p.respecTokens, 2)
		T.eq(p.pressure.highestCleared, 6)
		T.truthy(p.discoveries.grandmas_pantry)
		T.truthy(p.passGrants.wardrobe.cosmetics.hat_viking)
	end)
	T.it("repairs corrupted v6 blocks without throwing", function()
		local raw = v5()
		raw.version = 6
		raw.quests =
			{ day = "x", daily = { { id = "nope", p = 5 }, { id = "d_mice", p = 0 / 0 } }, weekly = 7 }
		raw.pass = { season = -3, xp = math.huge, free = { ["999"] = true, ["2"] = true }, premium = "x" }
		raw.achievements = { first_steps = true, [5] = true }
		raw.collection = { bosses = { not_a_boss = true }, nope = { a = true } }
		raw.accountRewards = { ["7"] = true, ["10"] = true }
		raw.titles = { title_veteran = true, fake = true }
		raw.emotes = { emote_belly_flop = true, x = true }
		raw.entitlements = { starter_pack = true, vip = true, junk = true }
		raw.nameDye = "plaid"
		raw.equipped.title = "title_last_herd" -- not owned
		local p, info = ProfileSchema.migrate(raw)
		local pa = p :: any
		T.falsy(info.failed)
		T.eq(#pa.quests.daily, 1)
		T.eq(pa.quests.daily[1].p, 0)
		T.eq(pa.pass.season, 1)
		T.eq(pa.pass.xp, 0)
		T.deepEq(pa.pass.free, { ["2"] = true })
		T.deepEq(pa.achievements, { first_steps = true })
		T.deepEq(pa.collection, { bosses = {} })
		T.deepEq(pa.accountRewards, { ["10"] = true })
		T.deepEq(pa.titles, { title_veteran = true })
		T.deepEq(pa.emotes, { emote_belly_flop = true })
		T.deepEq(pa.entitlements, { starter_pack = true }, "only product keys")
		T.eq(pa.nameDye, nil)
		T.eq(pa.equipped.title, nil)
	end)
	T.it("the client view carries the v6 additions", function()
		local p = ProfileSchema.migrate(v5()) :: any
		local v = ProfileSchema.view(p)
		T.truthy(type(v.book) == "table" and type(v.book.pages) == "table")
		T.truthy(type(v.accountRewards) == "table")
		T.eq(v.rookie.isRookie, false)
		T.truthy(type(v.titles) == "table")
		T.eq(v.quests, nil, "quests go through Net.S2C.Quests")
	end)
end)

T.describe("Award v6: wins, bestStage, championKills, Pressure record, rookie bonus", function()
	local function run(p: any, r: any): any
		r.cheese = r.cheese or 100
		r.xp = r.xp or 0
		r.cycle = 1
		r.ranked = if r.ranked == nil then true else r.ranked
		return Award.applyRun(p, r)
	end
	T.it("M1: a stage-1 or stage-2 extraction is not a win; 3+ clears or Last Herd is", function()
		local p = ProfileSchema.default() :: any
		T.falsy(run(p, { won = true, bosses = 1 }).win)
		T.falsy(run(p, { won = true, bosses = 2 }).win)
		T.truthy(run(p, { won = true, bosses = 3 }).win)
		T.truthy(run(p, { won = false, bosses = 2, lastHerd = true }).win)
		T.falsy(run(p, { won = false, bosses = 4 }).win, "a wipe is never a win")
		T.eq(p.stats.wins, 2)
		T.eq(p.stats.ranked.wins, 2)
		T.eq(p.stats.extractions, 4)
	end)
	T.it("B1: the Pressure record rises only on a full 4-stage clear; any extraction unlocks", function()
		local p = ProfileSchema.default() :: any
		p.stats.runs = 3
		local r = run(p, { won = true, bosses = 1, pressurePoints = 8 })
		T.truthy(r.pressureUnlocked)
		T.eq(p.pressure.highestCleared, 0, "stage-1 extraction: no record")
		T.eq(r.pressureRecord, nil)
		r = run(p, { won = true, bosses = 4, pressurePoints = 8 })
		T.eq(p.pressure.highestCleared, 8)
		T.eq(r.pressureRecord, 8)
		run(p, { won = true, stagesCleared = 4, fullClear = false, pressurePoints = 12 })
		T.eq(p.pressure.highestCleared, 8, "M2's explicit fullClear = false wins")
	end)
	T.it("iter 1 H5: no Pressure unlock before run 3, even after a full clear", function()
		local p = ProfileSchema.default() :: any
		local r = run(p, { won = true, bosses = 4, pressurePoints = 0 })
		T.falsy(r.pressureUnlocked)
		T.falsy(p.pressure.unlocked)
		run(p, { won = false, bosses = 1 })
		T.falsy(p.pressure.unlocked)
		r = run(p, { won = false, bosses = 1 }) -- run 3: an earlier extraction counts
		T.truthy(r.pressureUnlocked)
		T.truthy(p.pressure.unlocked)
	end)
	T.it("iter 1 P-2: a wipe pays class XP; 25 minimum; run 1 reaches class level 2", function()
		local ClassProgress = require("../../src/shared/Data/ClassProgress")
		-- the playtest wipe: 163 s, 75 mice, 1 champion assist, 0 stages, 0 POIs
		local xp = ClassProgress.runXp({ stagesSurvived = 0, seconds = 163, mice = 75, champAssists = 1 })
		T.eq(xp, math.floor(10 * 163 / 60 + 7 + 20 + 0.5))
		T.eq(ClassProgress.runXp({ stagesSurvived = 0 }), ClassProgress.MIN_RUN_XP)
		T.eq(ClassProgress.runXp({ stagesSurvived = 0, minutes = 3, mice = 75, championAssists = 1 }), 57)
		local p = ProfileSchema.default() :: any
		local r = run(p, { won = false, bosses = 0, classId = "elephante", classXp = 0 })
		T.eq(r.class.level, 2, "the first match always reaches class level 2")
		local r2 = run(p, { won = false, bosses = 0, classId = "elephante", classXp = 0 })
		T.eq(r2.class.xp, ClassProgress.MIN_RUN_XP)
	end)
	T.it("B3: bestStage and championKills (ranked only for the boards)", function()
		local p = ProfileSchema.default() :: any
		local r = run(p, { won = false, bosses = 2, championKills = 3 })
		T.eq(r.bestStage, 2)
		run(p, { won = false, bosses = 1, championKills = 2, ranked = false })
		T.eq(p.stats.bestStage, 2)
		T.eq(p.stats.championKills, 5)
		T.eq(p.stats.ranked.championKills, 3)
		T.eq(p.stats.ranked.bestStage, 2)
	end)
	T.it("Rookie Run: the first extraction pays 500 cheese + 50 GC exactly once", function()
		local p = ProfileSchema.default() :: any
		run(p, { won = false, bosses = 1, cheese = 0 })
		T.eq(p.goldenCheese, 0)
		local r = run(p, { won = true, bosses = 1, cheese = 0 })
		T.deepEq(r.firstExtractBonus, { cheese = 500, goldenCheese = 50 })
		T.eq(p.goldenCheese, 50)
		T.eq(p.cheese, 500)
		T.eq(run(p, { won = true, bosses = 1, cheese = 0 }).firstExtractBonus, nil)
		T.eq(p.goldenCheese, 50)
	end)
	T.it("M11: the first-run-of-the-day bonus is capped at 500", function()
		local p = ProfileSchema.default() :: any
		p.firstExtractPaid = true
		local r = run(p, { won = false, cheese = 2000, day = 5 })
		T.eq(r.firstRunBonus, 500)
	end)
end)

return T.finish()
