--!strict
-- Iteration 7 (team Systems), docs/iter/7/PLAN.md §B: death recap (#4), downed
-- squadmates' revive ping (#5), talent presets (#6), miniboss Crumb Dust (#7) and
-- gem tiers 13-14 from Overtime milestones (#8).
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local DeathRecap = require("../../src/shared/Run/DeathRecap")
local ClassProgress = require("../../src/shared/Data/ClassProgress")
local ClassPerks = require("../../src/shared/Config/ClassPerks")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local Gems = require("../../src/shared/Data/Gems")
local GemConfig = require("../../src/shared/Config/Gems")
local Difficulty = require("../../src/shared/Config/Difficulty")
local Progress = require("../../src/shared/Data/Progress")

local DT = 1 / 30

local function newWorld(seed: number): any
	return World.new({
		rng = Rng.new(seed),
		mods = Defaults.mods(),
		arenaRadius = 500,
		obstacles = {},
		enemyPool = { "mouse" },
		cycle = 1,
		stage = 1,
		enemyCap = 0,
		champions = false,
		carriers = false,
	} :: any)
end

local function hero(w: any, id: number, x: number, squad: number)
	local wpn = Defaults.weapon("bolt")
	wpn.damage = 0
	w:addPlayer(id, Defaults.stats(), wpn, Defaults.ability("burst"), x, 0, squad)
	local p = w.players[id]
	p.protectPending = nil
	p.protectUntil = 0
	return p
end

local function hit(w: any, p: any, amount: number, source: string, by: any?, src: any?)
	p.iframeUntil = 0
	p.invulnUntil = 0
	w._dmgSrc = src
	w:damagePlayer(p, amount, source, by)
	w._dmgSrc = nil
	w.now += 0.5
end

T.describe("Death recap (#4)", function()
	T.it("top 3 sources over the last 10 s, the downing hit as `by`", function()
		local w = newWorld(1)
		local p = hero(w, 1, 0, 1)
		local rival = hero(w, 2, 30, 2)
		p.hp, p.maxHp = 1000, 1000
		p.stats.armor = 0
		hit(w, p, 300, "contact", nil, { defId = "chonk" }) -- old: outside the window later
		w.now += 11
		hit(w, p, 50, "contact", nil, { defId = "mouse" })
		hit(w, p, 60, "contact", nil, { defId = "mouse" })
		hit(w, p, 120, "boss", nil, { isBoss = true, defId = "boss_x" })
		hit(w, p, 40, "trap", nil, nil)
		hit(w, p, 30, "contact", nil, { isChampion = true, defId = "champ_y" })
		T.falsy(p.downed)
		hit(w, p, 900, "pvp", rival, nil)
		T.truthy(p.downed)
		local r = w:deathRecap(1)
		T.truthy(r)
		T.eq(r.by.cat, "hero")
		T.eq(r.by.id, 2)
		T.eq(r.credit, 2)
		T.eq(#r.top, 3)
		T.eq(r.top[1].cat, "hero")
		T.eq(r.top[2].cat, "boss")
		T.eq(r.top[2].kind, "boss_x")
		T.eq(r.top[3].cat, "mouse")
		T.eq(r.top[3].amount, 110, "two mouse hits summed by kind")
		for _, s in r.top do
			T.truthy(s.kind ~= "chonk", "the hit 11 s earlier is outside the window")
		end
	end)
	T.it("storm downs and a never-downed hero", function()
		local w = newWorld(2)
		local p = hero(w, 1, 0, 1)
		T.eq(w:deathRecap(1), nil)
		T.eq(w:deathRecap(99), nil)
		w:_recapLog(p, p.hp + 10, "storm", nil)
		p.hp = 0
		w:_down(p, nil)
		local r = w:deathRecap(1)
		T.eq(r.by.cat, "storm")
		T.eq(r.top[1].cat, "storm")
	end)
	T.it("enemy projectiles remember their shooter", function()
		local w = newWorld(3)
		local p = hero(w, 1, 0, 1)
		local e = { defId = "slinger", alive = true }
		w._curEnemy = e
		w:spawnEnemyProjectile(5, 0, -20, 0, 1, 10, 2, "crumb")
		w._curEnemy = nil
		T.eq(w.eprojs[#w.eprojs].src, e)
		p.protectPending = nil
		for _ = 1, 30 do
			w:step(DT, w.now + DT)
		end
		T.truthy(p.recapLog and #p.recapLog >= 1, "the hit was logged")
		T.eq(p.recapLog[1].cat, "mouse")
		T.eq(p.recapLog[1].kind, "slinger")
	end)
	T.it("the S2C view names sources and labels bots", function()
		local recap = {
			by = { cat = "hero", id = -1001 },
			top = {
				{ cat = "hero", id = -1001, amount = 120.4 },
				{ cat = "storm", amount = 40 },
				{ cat = "mouse", kind = "nope", amount = 10 },
				{ cat = "hazard", kind = "trap", amount = 5 },
			},
			window = 10,
		}
		local v = DeathRecap.view(recap, true, -1001, function(id: number): any
			return if id == -1001 then { name = "Botty", isBot = true, squad = 3 } else nil
		end, 123) :: any
		T.eq(v.eliminated, true)
		T.eq(v.by.name, "Botty")
		T.eq(v.by.isBot, true)
		T.eq(v.killer.squad, 3)
		T.eq(#v.top, 3)
		T.eq(v.top[1].amount, 120)
		T.eq(v.top[2].name, "The Melt (storm)")
		T.eq(v.top[3].name, "Mice", "an unknown kind falls back")
		T.eq(v.t, 123)
		T.eq(DeathRecap.view(nil, false), nil)
	end)
end)

T.describe("Needs-revive auto-ping (#5)", function()
	T.it("is rate limited per hero", function()
		local log = {}
		T.truthy(DeathRecap.allowRevivePing(log, 1, 100))
		T.falsy(DeathRecap.allowRevivePing(log, 1, 100 + DeathRecap.REVIVE_PING_GAP - 0.1))
		T.truthy(DeathRecap.allowRevivePing(log, 2, 101), "another hero")
		T.truthy(DeathRecap.allowRevivePing(log, 1, 100 + DeathRecap.REVIVE_PING_GAP))
	end)
end)

local CLASS = "elephante"

local function profileAt(level: number): any
	local p = ProfileSchema.default() :: any
	p.unlockedClasses[CLASS] = true
	local st = ClassProgress.ensure(p, CLASS) :: any
	st.level = level
	st.perks = ClassProgress.autoSpec(CLASS, level).perks
	return p
end

T.describe("Talent presets (#6)", function()
	T.it("save, reset, load: the same perks, replayed legally", function()
		local p = profileAt(15)
		local st = p.classes[CLASS]
		local before = table.clone(st.perks)
		T.truthy(next(before) ~= nil)
		local ok, why, res = ClassProgress.savePreset(p, CLASS, 2)
		T.truthy(ok, why)
		T.eq(res.points, ClassProgress.perkPointsSpent(st))
		T.deepEq(st.presets[1], {})
		st.perks = {}
		ok, why = ClassProgress.loadPreset(p, CLASS, 2)
		T.truthy(ok, why)
		T.deepEq(st.perks, before)
		T.eq(select(2, ClassProgress.loadPreset(p, CLASS, 1)), "empty_preset")
		T.eq(select(2, ClassProgress.loadPreset(p, CLASS, 3)), "bad_slot")
		T.eq(select(2, ClassProgress.savePreset(p, "nope", 1)), "bad_class")
	end)
	T.it("QC M2: a preset loads only at the class's full point total (never a free respec)", function()
		local p = profileAt(5)
		local st = p.classes[CLASS]
		ClassProgress.savePreset(p, CLASS, 1) -- a small early build (4 points)
		st.level = 15
		st.perks = ClassProgress.autoSpec(CLASS, 15).perks
		local full = table.clone(st.perks)
		local ok, why, info = ClassProgress.loadPreset(p, CLASS, 1)
		T.falsy(ok)
		T.eq(why, "preset_points")
		T.eq(info.need, ClassProgress.perkPoints(15, 0))
		T.eq(info.points, ClassProgress.perkPoints(5, 0))
		T.deepEq(st.perks, full, "perks unchanged: no refund")
		local v = ClassProgress.presetView(CLASS, st)[1]
		T.eq(v.need, info.need)
		T.eq(v.valid, false)
		-- a full build saved now swaps freely
		ClassProgress.savePreset(p, CLASS, 2)
		T.eq(ClassProgress.presetView(CLASS, st)[2].valid, true)
		st.perks = {}
		T.truthy((ClassProgress.loadPreset(p, CLASS, 2)))
		T.deepEq(st.perks, full)
		-- level 5 again: the 14-point build no longer matches
		st.level = 5
		T.eq(select(2, ClassProgress.loadPreset(p, CLASS, 2)), "preset_points")
	end)
	T.it("an illegal set never replays", function()
		local p = profileAt(30)
		local st = p.classes[CLASS]
		local top = nil
		for _, b in ClassPerks.branches(CLASS) do
			for _, d in b.nodes do
				if d.gate > 0 then
					top = d
				end
			end
		end
		local perks, why = ClassProgress.applyPreset(CLASS, st, { [top.id] = true })
		T.eq(perks, nil)
		T.eq(why, "invalid_preset")
		T.truthy(next(st.perks) ~= nil, "state untouched")
	end)
	T.it("presets survive a save round trip; junk keys are dropped", function()
		local p = profileAt(12)
		ClassProgress.savePreset(p, CLASS, 1)
		p.classes[CLASS].presets[2] = { bogus_perk = true, [5] = true }
		local back = ProfileSchema.migrate(p)
		local pr = (back :: any).classes[CLASS].presets
		T.truthy(pr)
		T.truthy(next(pr[1]) ~= nil)
		T.deepEq(pr[2], {})
		T.eq((back :: any).version, ProfileSchema.VERSION)
		local fresh = ProfileSchema.default() :: any
		for _, st in fresh.classes do
			T.eq(st.presets, nil, "nothing stored until a save")
		end
	end)
end)

T.describe("Miniboss Crumb Dust (#7)", function()
	T.it("pays per kill up to the daily cap, resets next day", function()
		local p = ProfileSchema.default()
		local cap = GemConfig.MINIBOSS_DUST.dailyKills
		local per = GemConfig.MINIBOSS_DUST.perKill
		local d0 = Gems.state(p).dust
		local dust, n = Gems.minibossDust(p, 3, 100)
		T.eq(dust, 3 * per)
		T.eq(n, 3)
		dust, n = Gems.minibossDust(p, cap, 100)
		T.eq(n, cap - 3)
		T.eq(select(1, Gems.minibossDust(p, 1, 100)), 0, "capped")
		T.eq(Gems.state(p).dust, d0 + cap * per)
		T.eq(select(2, Gems.minibossDust(p, 2, 101)), 2, "a new day")
		T.eq(select(1, Gems.minibossDust(p, -4, 101)), 0)
		local s = Gems.sanitize(Gems.state(p))
		T.eq(s.mbDay, 101)
		T.eq(s.mbN, 2)
	end)
	T.it("afterRun pays it and reports it for Results", function()
		local p = ProfileSchema.default()
		local sum = Progress.afterRun(p, { day = 200, userId = 7, championKills = 2, tier = 2 } :: any)
		T.eq(sum.minibossDust, 2 * GemConfig.MINIBOSS_DUST.perKill)
		T.eq(sum.minibossKills, 2)
	end)
end)

T.describe("Gem tiers 13-14 (#8)", function()
	T.it("config: 14 tiers, ranges never go down, names and unique chances", function()
		T.eq(GemConfig.MAX_TIER, 14)
		T.deepEq(GemConfig.RANGES[13], { 75, 170 })
		T.deepEq(GemConfig.RANGES[14], { 90, 200 })
		for t = 2, GemConfig.MAX_TIER do
			T.truthy(GemConfig.RANGES[t][1] >= GemConfig.RANGES[t - 1][1], "min " .. t)
			T.truthy(GemConfig.RANGES[t][2] >= GemConfig.RANGES[t - 1][2], "max " .. t)
		end
		T.eq(#GemConfig.TIER_NAMES, GemConfig.MAX_TIER)
		T.eq(#GemConfig.UNIQUE_CHANCE, GemConfig.MAX_TIER)
	end)
	T.it("old gems are unchanged; a tier-14 gem round-trips", function()
		local raw = {
			inv = {
				{ id = 1, t = 12, s = { 75, 170, 100, 90, 80 }, lv = 2 },
				{ id = 2, t = 14, s = { 90, 200, 150, 95, 91 }, lv = 0 },
			},
			equipped = {},
			dust = 5,
			nextId = 3,
		}
		local st = Gems.sanitize(raw)
		T.deepEq(st.inv[1].s, { 75, 170, 100, 90, 80 })
		T.eq(st.inv[2].t, 14)
		T.deepEq(st.inv[2].s, { 90, 200, 150, 95, 91 })
		local r = Gems.roll(42, 14)
		for _, v in r.s do
			T.truthy(v >= 90 and v <= 200)
		end
	end)
	T.it("Overtime milestones roll only on the top two tiers, at a low chance", function()
		local top = Difficulty.COUNT
		-- iteration 8 (QC minor 9): tiers >= OVERTIME_MIN_TIER (Moldy, Doomwheel, Cosmic Curd)
		T.eq(#Gems.overtimeRolls(1, 50, GemConfig.OVERTIME_MIN_TIER - 1, top), 0, "not below Moldy")
		T.eq(#Gems.overtimeRolls(1, 9, top, top), 0, "no milestone before wave 10")
		local n13, n14, seen = 0, 0, 0
		for seed = 1, 2000 do
			for _, t in Gems.overtimeRolls(seed, 50, top - 1, top) do
				if t == 13 then
					n13 += 1
				else
					T.eq(t, 14)
					n14 += 1
				end
			end
			for _, t in Gems.overtimeRolls(seed, 15, top, top) do
				T.eq(t, 13, "wave 15: tier 13 only")
				seen += 1
			end
		end
		T.truthy(n13 > 0 and n14 > 0)
		T.truthy(n13 / 2000 < 0.4 and n14 / 2000 < 0.6, "low chance per milestone")
		T.truthy(seen > 0)
	end)
	T.it("afterRun grants them as gems (loot)", function()
		local p = ProfileSchema.default()
		local got = 0
		for seed = 1, 60 do
			local sum = Progress.afterRun(
				p,
				{ day = 300, userId = 9, tier = Difficulty.COUNT, overtimeWaves = 50, gemSeed = seed } :: any
			)
			got += sum.overtimeGems or 0
			for _, g in sum.gems do
				T.truthy(g.t <= 14)
			end
		end
		T.truthy(got > 0)
		local high = 0
		for _, g in Gems.state(p).inv do
			if g.t >= 13 then
				high += 1
			end
		end
		T.eq(high, got)
	end)
end)

return T.finish()
