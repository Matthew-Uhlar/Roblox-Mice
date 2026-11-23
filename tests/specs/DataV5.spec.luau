-- Iterations 1 + 2 long-term progression (Team P): profile v7 (additive from v6),
-- stomps, Prestige, Ascension, Cheese Gems + Crumb Dust, the difficulty ladder records
-- and the 30 Challenges. (The v5 Herd Talent Board and Charms were cut before shipping.)
local T = require("../lib/Test")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local ClassProgress = require("../../src/shared/Data/ClassProgress")
local Evolution = require("../../src/shared/Data/Evolution")
local Ascension = require("../../src/shared/Data/Ascension")
local Gems = require("../../src/shared/Data/Gems")
local Ladder = require("../../src/shared/Data/Ladder")
local Challenges = require("../../src/shared/Data/Challenges")
local RunBonus = require("../../src/shared/Data/RunBonus")
local Progress = require("../../src/shared/Data/Progress")
local Stats = require("../../src/shared/Run/Stats")
local E = require("../../src/shared/Config/Evolutions")
local A = require("../../src/shared/Config/Ascension")
local G = require("../../src/shared/Config/Gems")
local D = require("../../src/shared/Config/Difficulty")
local CC = require("../../src/shared/Config/Challenges")
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
			ele_fonte = { xp = 40, level = 10, perks = {} },
			ellie_fawn = { xp = 0, level = 1, perks = {} },
		},
		stats = { runs = 120, wins = 30, extractions = 50, bestStage = 4, championKills = 80, ranked = {} },
		pressure = { unlocked = true, highestCleared = 11, board = { stampede = 2 } },
		quests = {},
		pass = { season = 1, xp = 2500 },
		titles = { title_veteran = true },
		settings = { hints = true },
	}
end

local function fresh(): any
	local p = ProfileSchema.default() :: any
	p.stats.runs = 10
	return p
end

T.describe("Profile v7 migration from v6 (additive; values only go up)", function()
	T.it("keeps every v6 field and adds the v7 blocks", function()
		T.eq(ProfileSchema.VERSION, 8) -- iteration 5: v8 is a no-op step on top of v7
		local raw = v6Save()
		local before = ProfileSchema.deepCopy(raw)
		local p, info = ProfileSchema.migrate(raw)
		local pa = p :: any
		T.falsy(info.failed)
		T.deepEq(raw, before, "the raw save is untouched")
		T.eq(pa.version, ProfileSchema.VERSION) -- 8 since iteration 5
		T.eq(pa.cheese, 900)
		T.eq(pa.stats.championKills, 80)
		T.eq(pa.pass.xp, 2500)
		T.truthy(pa.titles.title_veteran)
		T.eq(pa.pressure.highestCleared, 11, "Pressure kept (achievements still read it)")
		T.truthy(type(pa.gems) == "table" and #pa.gems.inv == 0 and pa.gems.dust == 0)
		T.deepEq(pa.challenges, {})
		T.eq(pa.herdTalents, nil, "the Talent Board was cut before it shipped")
		T.eq(pa.charms, nil)
	end)
	T.it("Mastery Stars become Prestige (paid stars never paid again); stars stay read-only", function()
		local p = ProfileSchema.migrate(v6Save()) :: any
		local e = p.classes.elephante
		T.eq(e.prestige, 2)
		T.eq(e.prestigePaid, 2)
		T.eq(e.pxp, 300)
		T.eq(e.stars, 2, "kept read-only for one release")
		T.eq(ClassProgress.perkPointsFree(e), 31, "29 + 1 per Prestige")
	end)
	T.it("levels are recomputed UPWARD on the new curve, with a one-time notice", function()
		local p = ProfileSchema.migrate(v6Save()) :: any
		local f = p.classes.ele_fonte
		local life = ClassProgress.legacyTotalXpFor(10) + 40
		local lvl = ClassProgress.levelForXp(life, 10)
		T.eq(f.level, lvl)
		T.truthy(f.level > 10, "the gentler curve raises level 10")
		T.deepEq(p.levelNotice.ele_fonte, { 10, f.level })
		T.eq(p.classes.ellie_fawn.level, 1)
		T.eq(p.levelNotice.ellie_fawn, nil)
	end)
	T.it("stomps are seeded from lifetime class XP on the old curve (Z-6); never 0", function()
		local p = ProfileSchema.migrate(v6Save()) :: any
		local life = ClassProgress.legacyTotalXpFor(30) + 2 * 12000 + 300
		T.eq(p.classes.elephante.stomps, math.floor(1.2 * life))
		T.truthy(p.stats.stomps > 0)
		T.eq(p.stompSeedNotice, p.stats.stomps)
	end)
	T.it("the Pressure record becomes ladder records", function()
		local p = ProfileSchema.migrate(v6Save()) :: any
		T.eq(p.difficulty.cleared, 6, "P11 cleared = Smoked")
		T.eq(p.difficulty.bestSquad, 6)
		T.eq(p.difficulty.bestSolo, 0, "unknown: stays 0")
		T.eq(p.difficulty.unlocked, 7)
		local fresh6 =
			ProfileSchema.migrate({ version = 6, pressure = { unlocked = true, highestCleared = 0 } }) :: any
		T.eq(fresh6.difficulty.cleared, 2, "Pressure unlocked = at least Medium")
		local none = ProfileSchema.migrate({ version = 6, cheese = 1 }) :: any
		T.eq(none.difficulty.cleared, 0)
		T.eq(none.difficulty.unlocked, D.START_UNLOCKED)
	end)
	T.it("a v7 save round-trips unchanged, and every older version reaches v7", function()
		local p = ProfileSchema.migrate(v6Save()) :: any
		T.deepEq(ProfileSchema.migrate(ProfileSchema.deepCopy(p)), p)
		for v = 1, 5 do
			local q = ProfileSchema.migrate({
				version = v,
				cheese = 5,
				unlockedClasses = { elephante = true },
			}) :: any
			T.eq(q.version, ProfileSchema.VERSION, "v" .. v)
			T.eq(q.cheese, 5)
			T.truthy(type(q.difficulty) == "table" and type(q.gems) == "table")
		end
	end)
	T.it("repairs corrupted v7 blocks", function()
		local raw = ProfileSchema.migrate(v6Save()) :: any
		raw.gems = {
			inv = {
				{ id = 1, t = 3, s = { 999, 1, 5, 5, 5 }, lv = 9, u = "u_nope" },
				{ id = 1, t = 3, s = { 5, 5, 5, 5, 5 } },
				{ id = 2, t = 99, s = {} },
			},
			equipped = { ["1"] = 1, ["2"] = 1, ["3"] = 7 },
			dust = -5,
			nextId = 0,
		}
		raw.difficulty = { unlocked = 99, cleared = 4, bestSolo = 3, bestSquad = 1, perClass = { nope = {} } }
		raw.challenges = { iron_will = true, fake = true }
		raw.classes.elephante.prestige = 500
		local p = ProfileSchema.migrate(raw) :: any
		T.eq(#p.gems.inv, 1)
		local g = p.gems.inv[1]
		T.eq(g.s[1], G.RANGES[3][2], "stats clamped to the tier range")
		T.eq(g.lv, 0, "a bad level drops to 0")
		T.eq(g.u, nil)
		T.deepEq(p.gems.equipped, { ["1"] = 1 })
		T.eq(p.gems.dust, 0)
		T.eq(p.gems.nextId, 2)
		T.eq(p.difficulty.unlocked, 11)
		T.eq(p.difficulty.bestSquad, 3, "never below bestSolo")
		T.deepEq(p.difficulty.perClass, {})
		T.deepEq(p.challenges, { iron_will = true })
		T.eq(p.classes.elephante.prestige, 99)
	end)
end)

T.describe("Stomps (x the tier reward) and free unlocks", function()
	T.it("match stomps = mice x reward; free unlocks at 3k / 8k / 20k / 50k / 80k", function()
		T.eq(Evolution.matchStomps(100, 1), 100)
		T.eq(Evolution.matchStomps(100, 2.0), 200)
		T.eq(Evolution.matchStomps(-5, 3), 0)
		local order = {}
		for _, u in E.FREE_UNLOCKS do
			table.insert(order, u.stomps)
		end
		T.deepEq(order, { 3000, 8000, 20000, 50000, 80000 }) -- iteration 6: Tinkerphant 5th
		local p = fresh()
		local a = Evolution.addStomps(p, "elephante", 8500)
		T.deepEq(a.unlocked, { "le_fante", "filet" })
		T.eq(p.classes.elephante.stomps, 8500)
		T.eq(p.stats.stomps, 8500)
	end)
end)

T.describe("Ascension (8 nodes; Prestige + class stomps gates)", function()
	T.it("nodes unlock in order; looks at 2 / 4 / 8; SetEvo picks the look", function()
		local p = fresh()
		local st = ClassProgress.ensure(p, "elephante") :: any
		st.level = 30
		st.prestige = 3
		st.stomps = 10000
		T.eq(Ascension.nodes(st), 2)
		T.eq(Ascension.bits(st), "11000000")
		T.deepEq(Ascension.looks(st), { "bull" })
		st.prestige = 30
		st.stomps = 15000
		T.eq(Ascension.nodes(st), 2, "stomps gate node 3")
		T.eq(Ascension.look(p, "elephante"), "bull")
		T.deepEq({ Ascension.setLook(p, "elephante", 3) }, { false, "look_locked" })
		T.truthy(Ascension.setLook(p, "elephante", 1))
		T.eq(Ascension.look(p, "elephante"), nil, "base look chosen")
		st.stomps = 200000
		T.eq(Ascension.nodes(st), 8)
		T.truthy(Ascension.setLook(p, "elephante", 4))
		T.eq(Ascension.look(p, "elephante"), "ancient")
		T.eq(Ascension.squadPve(p, "elephante"), 0.05)
	end)
	T.it("Prestige + node bonus: PvE damage only, HP and cooldown", function()
		local p = fresh()
		local st = ClassProgress.ensure(p, "elephante") :: any
		st.level = 30
		st.prestige = 50
		st.stomps = 100000
		local r = RunBonus.resolve(Ascension.bonus(p, "elephante"))
		T.near(r.pve, A.PVE_PER_PRESTIGE * 40, 1e-9, "capped at P40")
		T.near(r.delta.mul.maxHp, 1 + A.HP_PER_PRESTIGE * 40 + 0.08, 1e-9)
		T.near(r.delta.mul.cooldownMult, 0.9, 1e-9)
		T.eq(r.extras.ascNodes, 6)
		local base = Stats.compute("elephante", {}, {}) :: any
		local s = Stats.compute("elephante", {}, {}, nil, nil, nil, r) :: any
		T.near(s.damageMult, base.damageMult, 1e-9, "never against heroes")
		T.near(s.pveDamageMult, 1 + A.PVE_PER_PRESTIGE * 40, 1e-9)
	end)
end)

T.describe("Cheese Gems and Crumb Dust", function()
	T.it("never sold, rerolled or upgraded for Robux", function()
		for _, item in Monetization.ALL do
			local b = string.lower(item.benefit)
			T.falsy(string.find(b, "cheese gem", 1, true), item.key)
			T.falsy(string.find(b, "crumb dust", 1, true), item.key)
			T.falsy(string.find(b, "prestige", 1, true) or string.find(b, "challenge", 1, true), item.key)
		end
	end)
	T.it("rolls stay in the tier range; High rolls the top half; deterministic", function()
		T.deepEq(Gems.roll(42, 6), Gems.roll(42, 6))
		for seed = 1, 300 do
			local r = Gems.roll(seed, 6)
			local hi = Gems.roll(seed, 6, { high = true })
			for i = 1, 5 do
				T.truthy(r.s[i] >= 20 and r.s[i] <= 50)
				T.truthy(hi.s[i] >= 35 and hi.s[i] <= 50)
			end
		end
		local uniques = 0
		for seed = 1, 2000 do
			if Gems.roll(seed, 11).u then
				uniques += 1
			end
		end
		T.truthy(uniques > 350 and uniques < 650, "about 25% uniques at tier 11: " .. uniques)
		T.truthy(Gems.roll(5, 1, { unique = true }).u ~= nil)
	end)
	T.it("sockets, upgrade (n x tier dust), salvage (tier, +tier with a unique), full bag", function()
		local p = fresh()
		local g = Gems.grant(p, { t = 4, s = { 10, 10, 10, 10, 10 }, u = "u_stride" }, DAY) :: any
		local g2 = Gems.grant(p, { t = 2, s = { 5, 5, 5, 5, 5 } }, DAY) :: any
		T.truthy(Gems.equip(p, 1, g.id))
		T.deepEq({ Gems.equip(p, 2, g2.id) }, { false, "slot_locked" })
		T.deepEq({ Gems.upgrade(p, g.id) }, { false, "no_dust" })
		Gems.addDust(p, 4 + 8)
		T.truthy(Gems.upgrade(p, g.id))
		T.truthy(Gems.upgrade(p, g.id))
		T.eq(p.gems.dust, 0)
		T.eq(g.lv, 2)
		local ok, res = Gems.salvage(p, g.id)
		T.truthy(ok)
		T.eq(res.dust, 8, "tier 4 + 4 for the unique")
		T.deepEq(p.gems.equipped, {}, "a salvaged gem leaves its socket")
		for _ = 1, G.INVENTORY do
			Gems.grant(p, { t = 1, s = { 1, 1, 1, 1, 1 } }, DAY)
		end
		local none, dust = Gems.grant(p, { t = 9, s = { 40, 40, 40, 40, 40 } }, DAY)
		T.eq(none, nil)
		T.eq(dust, 9, "a full bag turns the drop into dust, never loses it")
	end)
	T.it("the squad aura is the SUM of every member's gems, within the caps; uniques once", function()
		local function gem(t: number, v: number, u: string?): any
			return { id = 1, t = t, s = { v, v, v, v, v }, u = u, lv = 0 }
		end
		local one = Gems.aura({ { gem(11, 125, "u_stride") } })
		local three =
			Gems.aura({ { gem(11, 125, "u_stride") }, { gem(11, 125, "u_stride") }, { gem(11, 125) } })
		local r1, r3 = RunBonus.resolve(one.bonus), RunBonus.resolve(three.bonus)
		T.near(r1.pve, 125 * G.POINT.bite, 1e-9)
		T.near(r3.pve, 3 * 125 * G.POINT.bite, 1e-9, "3 humans beat 1")
		T.deepEq(three.uniques, { "u_stride" }, "each unique once per squad")
		local many = {}
		for i = 1, 40 do
			many[i] = { gem(12, 170) }
		end
		local capped = RunBonus.resolve(Gems.aura(many).bonus)
		T.near(capped.pve, G.SQUAD_CAP.bite, 1e-9)
		T.near(capped.extras.pveResist, G.SQUAD_CAP.plating, 1e-9)
	end)
end)

T.describe("Difficulty ladder records", function()
	T.it("a clear unlocks the next tier; onboarding extraction unlocks tiers 1-3 only", function()
		local p = fresh()
		T.eq(Ladder.state(p).unlocked, 2)
		local r = Ladder.record(p, { tier = 2, extracted = true, extractStage = 3, day = DAY })
		T.eq(r.unlocked, 3)
		T.eq(Ladder.state(p).cleared, 0, "an onboarding extraction is not a clear")
		Ladder.record(p, { tier = 5, extracted = true, extractStage = 3, day = DAY })
		T.eq(Ladder.state(p).unlocked, 3, "not above tier 3")
		r = Ladder.record(
			p,
			{ tier = 3, clear = true, solo = true, classId = "jumbo", clearSeconds = 800, day = DAY }
		)
		T.eq(r.unlocked, 4)
		T.eq(r.bestSolo, 3)
		T.eq(r.firstClearGem, 3, "iteration 4: the first-ever clear of a tier pays a guaranteed gem")
		r = Ladder.record(p, { tier = 3, clear = true, solo = true, clearSeconds = 700, day = DAY })
		T.eq(r.firstClearGem, nil, "once per tier per account")
		T.eq(Ladder.state(p).bestSoloTime, 700)
		T.eq(Ladder.state(p).perClass.jumbo.bestSolo, 3)
		r = Ladder.record(p, { tier = 3, clear = true, day = DAY + 7 })
		T.eq(r.firstClearGem, nil, "not again next week either")
		Ladder.record(p, { tier = 4, clear = true, solo = true, ranked = false, day = DAY })
		T.eq(Ladder.state(p).bestSolo, 3, "unranked runs don't set Best Solo")
		T.eq(Ladder.state(p).bestSquad, 4)
		T.eq(Ladder.bestSoloScore(p), 3 * 100000 + (99999 - 700))
	end)
end)

T.describe("Challenges (31)", function()
	T.it(
		"31 defs (iteration 6: Lone Tusk Tinkerphant); none needs Robux or a friend; rewards are titles, gems or dust",
		function()
			T.eq(#CC.LIST, 31)
			for _, def in CC.LIST do
				for k in def.reward do
					T.truthy(k == "gemTier" or k == "gemUnique" or k == "dust" or k == "title", def.id)
				end
				local text = string.lower(def.text)
				T.falsy(string.find(text, "robux", 1, true) or string.find(text, "friend", 1, true), def.id)
			end
		end
	)
	T.it("match requirements: tier, clear, solo, class, flags, counters, time", function()
		local p = fresh()
		local done = Challenges.check(p, { tier = 6, clear = true, solo = true, classId = "filet" })
		local ids = {}
		for _, d in done do
			ids[d.id] = d
		end
		T.truthy(ids.lone_tusk_filet)
		T.eq(ids.lone_tusk_filet.gemTier, 6)
		T.falsy(ids.lone_tusk_jumbo)
		T.truthy(ids.speed_herd == nil, "no time given")
		done = Challenges.check(
			p,
			{ tier = 3, clear = true, clearSeconds = 700, flags = { noRankBought = true } }
		)
		ids = {}
		for _, d in done do
			ids[d.id] = d
		end
		T.truthy(ids.bare_trunk and ids.speed_herd)
		T.eq(p.gems.dust, 10)
		T.truthy(p.titles.title_bare_trunk)
		T.deepEq(Challenges.check(p, { tier = 6, clear = true, solo = true, classId = "filet" }), {}, "once")
		done = Challenges.check(p, { flags = { squadChampKills = 8 } })
		T.eq(done[1].id, "champion_hunter")
	end)
	T.it("gem challenges read the profile; all 30 give the Wheel of Legends title", function()
		local p = fresh()
		Gems.grant(p, { t = 11, s = { 50, 50, 50, 50, 50 } }, DAY)
		local done = Challenges.check(p, nil)
		T.eq(done[1].id, "jeweler")
		for _, def in CC.LIST do
			p.challenges[def.id] = true
		end
		p.challenges.golden_wheel = nil
		Gems.grant(p, { t = 12, s = { 80, 80, 80, 80, 80 } }, DAY)
		Challenges.check(p, nil)
		T.truthy(p.titles[CC.ALL_TITLE])
	end)
end)

T.describe("afterRun: stomps, ladder, gems and challenges in one match", function()
	T.it("a solo Smoked clear", function()
		local p = fresh()
		p.unlockedClasses.filet = true
		local sum = Progress.afterRun(p, {
			day = DAY,
			userId = UID,
			classId = "filet",
			stagesCleared = 4,
			stagesSurvived = 4,
			extracted = true,
			win = true,
			fullClear = true,
			clear = true,
			bosses = 4,
			mice = 500,
			tier = 6,
			solo = true,
			ranked = true,
			clearSeconds = 900,
			extractStage = 4,
			gemSeed = 99,
		})
		T.eq(p.classes.filet.stomps, 1000, "500 x Smoked 2.0")
		T.eq(sum.ladder.unlocked, 7)
		T.eq(sum.ladder.bestSolo, 6)
		T.truthy(table.find(sum.challenges, "lone_tusk_filet"))
		-- weekly gem (tier 6) + extraction chance (tier 5, 50%) + the challenge gem (tier 6)
		T.truthy(#sum.gems >= 2)
		local view = ProfileSchema.view(p)
		T.eq(view.difficulty.bestSolo, 6)
		T.eq(#view.gems.inv, #sum.gems)
		T.eq(view.stomps.total, 1000)
		T.truthy(view.challenges.done >= 1)
		T.eq(view.classes.filet.ascension.bits, "00000000")
		T.eq(view.skipWaveAt, 70)
	end)
end)

T.describe("Iteration 3 (P): rookie gems, saved tier, Prestige carry", function()
	T.it("T-11: a Mild gem gives at least +1% (Rinds); ranges only ever went up", function()
		T.eq(G.RANGES[1][1], 10)
		T.truthy(G.RANGES[1][1] * G.POINT.rinds >= 0.01)
		for t = 2, G.MAX_TIER do
			T.truthy(G.RANGES[t][1] >= G.RANGES[t - 1][1], "min rises with the tier")
			T.truthy(G.RANGES[t][2] >= G.RANGES[t - 1][2], "max rises with the tier")
		end
		-- a saved tier-1 gem from the old 1-5 range is raised into the new range
		local p = ProfileSchema.migrate({
			version = 7,
			gems = { inv = { { id = 1, t = 1, s = { 1, 2, 3, 4, 5 } } } },
		}) :: any
		T.deepEq(p.gems.inv[1].s, { 10, 10, 10, 10, 10 })
	end)
	T.it("T-11: rookies (runs 0-2) never get a gem below tier 2", function()
		local p = ProfileSchema.default() :: any
		T.eq(Gems.dropTier(p, 1), 2)
		T.eq(Gems.dropTier(p, 5), 5)
		p.stats.runs = 3
		T.eq(Gems.dropTier(p, 1), 1)
		T.eq(Gems.dropTier(p, 1, true), 2, "the end-of-match roll of run 3 still counts as rookie")
		-- a rookie's Mild extraction at stage 2 can roll (at tier 2)
		local r = ProfileSchema.default() :: any
		r.stats.runs = 1 -- the match was already counted by Data/Award
		local found = false
		for seed = 1, 20 do
			local q = ProfileSchema.default() :: any
			q.stats.runs = 1
			local sum = Progress.afterRun(q, {
				day = DAY,
				userId = UID,
				tier = 1,
				extracted = true,
				extractStage = 2,
				stagesCleared = 2,
				gemSeed = seed,
			})
			for _, g in sum.gems do
				T.truthy(g.t >= 2)
				found = true
			end
		end
		T.truthy(found, "rookie extractions on Mild do drop gems")
	end)
	T.it("T-8: settings.tier is saved, sanitised and clamped; lastTier defaults", function()
		local p = ProfileSchema.default() :: any
		T.eq(ProfileSchema.lastTier(p), 1, "a rookie starts on Mild")
		p.settings.tier = 2
		T.eq(ProfileSchema.lastTier(p), 2, "rookies may choose Medium")
		p.stats.runs = 10
		p.settings.tier = nil
		p.difficulty.cleared = 5
		p.difficulty.unlocked = 6
		T.eq(ProfileSchema.lastTier(p), 5, "a veteran defaults to the highest tier cleared")
		p.settings.tier = 9
		T.eq(ProfileSchema.lastTier(p), 6, "never above the unlocked tier")
		p.settings.tier = 0
		T.eq(ProfileSchema.lastTier(p), 0, "Custom")
		local saved = ProfileSchema.deepCopy(p)
		saved.settings.tier = 9
		T.eq((ProfileSchema.migrate(saved) :: any).settings.tier, 6, "clamped on load")
		saved.settings.tier = 2.5
		T.eq((ProfileSchema.migrate(saved) :: any).settings.tier, nil, "junk dropped")
		T.eq(ProfileSchema.view(p).lastTier, 0)
	end)
	T.it("T-25: Prestige keeps the whole XP bank (multi-Prestige)", function()
		local p = fresh()
		local st = ClassProgress.ensure(p, "elephante") :: any
		st.level = 30
		st.pxp = 2 * ClassProgress.PRESTIGE_XP
		T.truthy(ClassProgress.doPrestige(p, "elephante"))
		T.eq(st.pxp, 2 * ClassProgress.PRESTIGE_XP, "P0 -> P1 keeps the bank")
		T.truthy(ClassProgress.canPrestige(st), "a second Prestige is ready at once")
		T.truthy(ClassProgress.doPrestige(p, "elephante"))
		T.eq(st.pxp, ClassProgress.PRESTIGE_XP)
		T.truthy(ClassProgress.doPrestige(p, "elephante"))
		T.eq(st.prestige, 3)
		T.falsy(ClassProgress.canPrestige(st))
	end)
end)

T.describe("Iteration 4 (P): personal gems, 2 sockets, round-completion drops", function()
	T.it("2 sockets; a gem in the old 3rd socket goes back to the inventory", function()
		T.eq(#G.SOCKET_LEVELS, 2)
		local raw = ProfileSchema.migrate(v6Save()) :: any
		raw.level = 30
		raw.gems = {
			inv = {
				{ id = 1, t = 2, s = { 10, 10, 10, 10, 10 } },
				{ id = 2, t = 2, s = { 10, 10, 10, 10, 10 } },
				{ id = 3, t = 2, s = { 10, 10, 10, 10, 10 } },
			},
			equipped = { ["1"] = 1, ["2"] = 2, ["3"] = 3 },
			dust = 0,
			nextId = 4,
		}
		local p = ProfileSchema.migrate(raw) :: any
		T.deepEq(p.gems.equipped, { ["1"] = 1, ["2"] = 2 })
		T.eq(#p.gems.inv, 3, "nothing is lost")
		T.deepEq({ Gems.equip(p, 3, 3) }, { false, "bad_slot" })
		T.eq(#ProfileSchema.view(p).gems.equipped, 2)
	end)
	T.it("gems are personal: class uniques only while the owner plays that class", function()
		local p = fresh()
		p.level = 10
		local a = Gems.grant(p, { t = 6, s = { 30, 30, 30, 30, 30 }, u = "u_filet" }, DAY) :: any
		local b = Gems.grant(p, { t = 6, s = { 30, 30, 30, 30, 30 }, u = "u_stride" }, DAY) :: any
		Gems.equip(p, 1, a.id)
		Gems.equip(p, 2, b.id)
		T.deepEq(Gems.personal(p, "filet").uniques, { "u_filet", "u_stride" })
		T.deepEq(Gems.personal(p, "jumbo").uniques, { "u_stride" })
		local r = RunBonus.resolve(Gems.personal(p, "jumbo").bonus)
		T.near(r.pve, 60 * G.POINT.bite, 1e-9)
	end)
	T.it("drop chance: min(20%, (6% + 2% per stage) x tier reward)", function()
		T.near(G.roundChance(0, 1), 0.06, 1e-9)
		T.near(G.roundChance(4, 1), 0.14, 1e-9)
		T.near(G.roundChance(4, 1.2), 0.168, 1e-9)
		T.eq(G.roundChance(4, 2), 0.20)
	end)
	T.it("drops only on round completion; the first-ever clear of a tier is guaranteed", function()
		local function run(p: any, seed: number, info: any): any
			local base = { day = DAY, userId = UID, gemSeed = seed, tier = 3, stagesCleared = 4 }
			for k, v in info do
				base[k] = v
			end
			return Progress.afterRun(p, base)
		end
		local wipeGems = 0
		for seed = 1, 200 do
			local p = fresh()
			wipeGems += #run(p, seed, { extracted = false, clear = false }).gems
		end
		T.eq(wipeGems, 0, "no gem on a wipe")
		local p = fresh()
		local first = run(p, 1, { extracted = true, clear = true, fullClear = true })
		T.truthy(#first.gems >= 1, "first clear of Sharp: guaranteed")
		T.eq(first.gems[1].t, 3)
		local hits, n = 0, 400
		for seed = 2, n + 1 do
			hits += #run(p, seed, { extracted = true, clear = true, fullClear = true }).gems
		end
		local expected = G.roundChance(4, 1.2)
		T.truthy(
			math.abs(hits / n - expected) < 0.05,
			string.format("drop rate %.3f vs %.3f", hits / n, expected)
		)
	end)
	T.it("mid-match drops are gone (dropGem is a no-op)", function()
		local p = fresh()
		local g = Progress.dropGem(p, 5, 6, 1, nil, DAY)
		T.eq(g, nil)
		T.eq(#p.gems.inv, 0)
	end)
end)

return T.finish()
