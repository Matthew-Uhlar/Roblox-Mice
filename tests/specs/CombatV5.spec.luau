--!strict
-- Iteration 1 / v5 combat hooks (docs/iter/1/PLAN.md §A, §C, §D; docs/V5-PLAN.md):
-- Config/RunShop, the World stat layers (setRunMods / setSquadAura), rinds / whey /
-- shared XP, rookie squads, the idle lure, champions near squads, boss poses, bots.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local RunShop = require("../../src/shared/Config/RunShop")
local Bosses = require("../../src/shared/Config/Bosses")
local Champions = require("../../src/shared/Combat/Champions")
local BotBrain = require("../../src/shared/Bots/BotBrain")
local Ids = require("../../src/shared/Util/Ids")

local DT = 1 / 30

local function newWorld(seed: number, extra: { [string]: any }?): any
	local o: any = {
		rng = Rng.new(seed),
		mods = Defaults.mods(),
		arenaRadius = 300,
		obstacles = {},
		enemyPool = { "mouse" },
		cycle = 1,
		stage = 1,
		enemyCap = 0,
		champions = false,
		carriers = false,
	}
	for k, v in extra or {} do
		o[k] = v
	end
	return World.new(o)
end

local function harmless(): any
	local w = Defaults.weapon("bolt")
	w.damage = 0
	return w
end

local function run(w: any, seconds: number): { any }
	local all = {}
	for _ = 1, math.floor(seconds / DT + 0.5) do
		for _, f in w:step(DT, w.now + DT) do
			table.insert(all, f)
		end
	end
	return all
end

local function sumEvents(list: { any }, typ: string, id: number): number
	local n = 0
	for _, e in list do
		if e.type == typ and e.id == id then
			n += e.amount
		end
	end
	return n
end

T.describe("Config/RunShop", function()
	T.it("rank costs grow x1.14 per rank and stop at 25", function()
		T.eq(RunShop.rankCost("might", 0), 20)
		T.eq(RunShop.rankCost("might", 1), math.ceil(20 * 1.14))
		T.eq(RunShop.rankCost("might", 25), nil)
		T.eq(RunShop.rankCost("nope", 0), nil)
		local all = 0
		for _, id in RunShop.RANK_ORDER do
			all += RunShop.rankTotal(id, 25)
		end
		-- ceil(base x 1.14^rank) sums to ~36k for all 8 (V5-PLAN quotes "about 75k")
		T.truthy(all > 30000 and all < 80000, "all 8 maxed: " .. all)
	end)
	T.it("drops: 5 / 15 / 200 / 750 rinds, x(1 + 0.25 (stage - 1))", function()
		T.eq(RunShop.rindsFor("mouse", 1), 5)
		T.eq(RunShop.rindsFor("elite", 1), 15)
		T.eq(RunShop.rindsFor("champion", 1), 200)
		T.eq(RunShop.rindsFor("boss", 3), 750 * 1.5)
	end)
	T.it("combine: ranks (with caps), buffs once each, class buff, at most 2 ultimates", function()
		local d = RunShop.combine({ might = 10, stride = 25, focus = 25 }, { "greed", "greed", "bulwark" }, {
			"titan",
			"overdrive",
			"cataclysm",
		}, "ele_fonte", true)
		T.near(d.add.pveDamageMult, 0.4, 1e-9)
		T.near(d.mul.moveSpeed, 1.2, 1e-9) -- capped +20%
		T.near(d.mul.cooldownMult, 0.65, 1e-9) -- capped -35%
		T.near(d.add.rindMult, 0.3, 1e-9) -- once
		T.near(d.mul.damageTakenMult, 0.85, 1e-9)
		T.eq(d.add.projectileBonus, 1)
		T.near(d.mul.maxHp, 1.4, 1e-9)
		T.near(d.mul.attackSpeedMult, 1.35, 1e-9)
		T.eq(d.add.abilityRepeat, nil, "the third ultimate is ignored")
		for _, cls in { "elephante", "ele_fonte", "ellie_fawn", "le_fante", "filet", "jumbo", "fizzante" } do
			T.truthy(RunShop.CLASS_BUFFS[cls] ~= nil, cls)
		end
	end)
	T.it("swap: rinds -> whey at 10 : 1 minus 20%", function()
		local whey, spent = RunShop.swap(1000)
		T.eq(whey, 80)
		T.eq(spent, 1000)
		T.eq(RunShop.swap(0), 0)
	end)
end)

T.describe("World stat layers", function()
	T.it("setRunMods layers a StatDelta on top of the stats; nil clears it", function()
		local w = newWorld(1)
		w:addPlayer(1, Defaults.stats({ maxHp = 100 }), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:setRunMods(1, RunShop.combine({ hide = 4, plating = 2 }, { "rush" }))
		local p = w.players[1]
		T.near(p.maxHp, 120, 1e-6)
		T.near(p.hp, 120, 1e-6, "full HP stays full")
		T.eq(p.stats.armor, 2)
		T.near(p.stats.moveSpeed, 16 * 1.15, 1e-6)
		-- the caller's stat refresh keeps the layer
		w:updatePlayer(1, Defaults.stats({ maxHp = 200 }), harmless())
		T.near(p.maxHp, 240, 1e-6)
		w:setRunMods(1, nil)
		T.near(p.maxHp, 200, 1e-6)
	end)
	T.it("setSquadAura reaches every member of the squad only, and follows setSquad", function()
		local w = newWorld(2)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 5, 0, 2)
		w:setSquadAura(1, { mul = { maxHp = 1.12 } })
		T.near(w.players[1].maxHp, 112, 1e-6)
		T.eq(w.players[2].maxHp, 100)
		w:setSquad(2, 1)
		T.near(w.players[2].maxHp, 112, 1e-6)
		w:setSquadAura(1, nil)
		T.eq(w.players[1].maxHp, 100)
	end)
	T.it("Bulwark (damageTakenMult) and a Herdguard squadmate cut mouse damage", function()
		local w = newWorld(3)
		w:addPlayer(1, Defaults.stats({ maxHp = 1000 }), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats({ maxHp = 1000 }), harmless(), Defaults.ability("burst"), 5, 0, 1)
		run(w, 0.1)
		T.eq(w:damagePlayer(w.players[1], 100, "contact"), 100)
		w:setRunMods(1, RunShop.combine(nil, { "bulwark" }))
		run(w, 0.6)
		T.near(w:damagePlayer(w.players[1], 100, "contact"), 85, 1e-6)
		w:setRunMods(2, RunShop.combine(nil, nil, { "herdguard" }))
		run(w, 0.6)
		T.near(w:damagePlayer(w.players[1], 100, "contact"), 100 * 0.85 * RunShop.HERDGUARD_MULT, 1e-6)
	end)
	T.it("pveResist (P runBonuses) cuts mouse damage, never PvP; capped", function()
		local w = newWorld(14)
		w:addPlayer(1, Defaults.stats({ maxHp = 1000 }), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats({ maxHp = 1000 }), harmless(), Defaults.ability("burst"), 5, 0, 2)
		run(w, 0.1)
		w:protect(1, 0)
		w:protect(2, 0)
		w:setRunMods(1, { add = { pveResist = 0.2 } })
		T.near(w:damagePlayer(w.players[1], 100, "contact"), 80, 1e-6)
		local pvp = w:damageHeroFrom(w.players[1], 100, w.players[2])
		T.near(pvp, 100 * World.PVP_MULT * World.PVP_DAMAGE, 1e-6)
		w:setRunMods(1, { add = { pveResist = 5 } })
		run(w, 0.6)
		T.near(w:damagePlayer(w.players[1], 100, "contact"), 100 * (1 - World.PVE_RESIST_MAX), 1e-6)
	end)

	T.it("Cataclysm: the ability fires a second time a moment later", function()
		local w = newWorld(4)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		run(w, 0.1)
		w:setRunMods(1, RunShop.combine(nil, nil, { "cataclysm" }))
		T.truthy(w:useAbility(1, 10, 0, w.now))
		local casts = 0
		for _, f in run(w, 1) do
			if f.t == "ability" then
				casts += 1
			end
		end
		T.eq(casts, 2, "the cast and its repeat")
	end)
end)

T.describe("Rinds, whey and shared XP", function()
	T.it("a mouse kill: 5 rinds x stage scale to the killer, 50% to squadmates within 45 studs", function()
		local w = newWorld(5, { stage = 3, enemyCap = 50 })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 20, 0, 1)
		w:addPlayer(3, Defaults.stats(), harmless(), Defaults.ability("burst"), 100, 0, 1)
		run(w, 0.1)
		w:drainEvents()
		local e = w:spawnEnemy("mouse", 3, 0)
		w:_killEnemy(e, w.players[1])
		local ev = w:drainEvents()
		T.near(sumEvents(ev, "rinds", 1), 5 * 1.5, 1e-9)
		T.near(sumEvents(ev, "rinds", 2), 5 * 1.5 * 0.5, 1e-9)
		T.eq(sumEvents(ev, "rinds", 3), 0, "too far for a share")
	end)
	T.it("Greed and a held Power Totem multiply rinds; +1 whey per 25 rinds", function()
		local w = newWorld(6, { enemyCap = 100 })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		run(w, 0.1)
		w:setRunMods(1, RunShop.combine(nil, { "greed" }))
		w.squadDmg[1] = 1.2 -- squad 1 holds a totem
		w:drainEvents()
		for _ = 1, 10 do
			w:_killEnemy(w:spawnEnemy("mouse", 3, 0), w.players[1])
		end
		local ev = w:drainEvents()
		local rinds = sumEvents(ev, "rinds", 1)
		T.near(rinds, 10 * 5 * 1.3 * RunShop.TOTEM_RIND_MULT, 1e-6)
		T.eq(sumEvents(ev, "whey", 1), math.floor(rinds / RunShop.WHEY_PER_RINDS))
	end)
	T.it("a champion: 200 rinds split by squad damage, whey 60 top / 30 others; dead members too", function()
		local w = newWorld(7, { champions = true })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 30, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 35, 1)
		w:addPlayer(3, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, -30, 2)
		run(w, 0.1)
		w:_kill(w.players[2], nil)
		local c = w:spawnChampion("champ_captain", 0, 0)
		c.dmgBySquad = { [1] = 300, [2] = 100 }
		w:drainEvents()
		w:_killEnemy(c, w.players[3])
		local ev = w:drainEvents()
		T.near(sumEvents(ev, "rinds", 1), 150, 1e-6)
		T.near(sumEvents(ev, "rinds", 2), 150, 1e-6, "dead members keep their share")
		T.near(sumEvents(ev, "rinds", 3), 50, 1e-6)
		T.truthy(sumEvents(ev, "whey", 1) >= 60)
		T.truthy(sumEvents(ev, "whey", 3) >= 30 and sumEvents(ev, "whey", 3) < 60)
	end)
	T.it("a boss: 750 rinds x stage scale split by squad damage", function()
		local w = newWorld(8, { stage = 2 })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 30, 1)
		run(w, 0.1)
		local b = w:spawnBoss("giant_tree", 0, 0, { scale = false })
		w.bossDamage = { [1] = 10 }
		w:drainEvents()
		w:_killEnemy(b, w.players[1], true)
		T.near(sumEvents(w:drainEvents(), "rinds", 1), 750 * 1.25, 1e-6)
	end)
	T.it("shared XP: standing squadmates within 45 studs get 50% of a crumb", function()
		local w = newWorld(9)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 30, 0, 1)
		w:addPlayer(3, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 30, 2)
		run(w, 0.1)
		w:spawnPickup(1, 0, 10)
		w:drainEvents()
		run(w, 1)
		local ev = w:drainEvents()
		T.near(sumEvents(ev, "xp", 1), 10, 1e-6)
		T.near(sumEvents(ev, "xp", 2), 5, 1e-6)
		T.eq(sumEvents(ev, "xp", 3), 0, "other squads get nothing")
	end)
end)

T.describe("Rookie squads (P-1, P-29)", function()
	T.it("stage 1: mice deal x0.75 to the rookie's squad, which spawns at x0.85", function()
		local w = newWorld(10)
		w:addPlayer(1, Defaults.stats({ maxHp = 1000 }), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(
			Ids.botId(1),
			Defaults.stats({ maxHp = 1000 }),
			harmless(),
			Defaults.ability("burst"),
			5,
			0,
			1
		)
		w:addPlayer(
			Ids.botId(2),
			Defaults.stats({ maxHp = 1000 }),
			harmless(),
			Defaults.ability("burst"),
			90,
			0,
			2
		)
		w:setRookie(1, true)
		run(w, 0.1)
		T.near(w:damagePlayer(w.players[Ids.botId(1)], 100, "contact"), 75, 1e-6)
		T.eq(w:damagePlayer(w.players[Ids.botId(2)], 100, "contact"), 100)
		-- 2 squads in the world: x FEW_SQUADS_SPAWN too
		T.near(w:_spawnHeroes(), (2 * World.ROOKIE_SPAWN + 1) * World.FEW_SQUADS_SPAWN, 1e-9)
		T.truthy(w:getPlayers()[Ids.botId(1)].rookieSquad)
		w:setStage(1, 2)
		run(w, 0.6)
		T.eq(w:damagePlayer(w.players[Ids.botId(1)], 100, "contact"), 100, "stage 2: normal")
	end)
	T.it("enemy bots skip the rookie's bot squadmates in stage 1", function()
		local w = newWorld(11)
		local mate, foe = Ids.botId(1), Ids.botId(2)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), -80, 0, 1)
		w:addPlayer(mate, Defaults.stats(), harmless(), Defaults.ability("burst"), 6, 0, 1)
		w:addPlayer(foe, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 2)
		w:setRookie(1, true)
		run(w, 0.1)
		T.truthy(w:_rookieSafe(w.players[foe], w.players[mate]))
		T.falsy(w:_rookieSafe(w.players[1], w.players[foe]), "humans are never limited")
		w:setStage(1, 2)
		T.falsy(w:_rookieSafe(w.players[foe], w.players[mate]))
		T.truthy(w:_rookieSafe(w.players[foe], w.players[1]), "the rookie itself through stage 2")
	end)
end)

T.describe("Idle time (P-12)", function()
	T.it("a hero with no mouse within LURE_NEAR for LURE_AFTER s gets a lured cluster", function()
		local w = newWorld(12, { enemyCap = 200, arenaRadius = 400 })
		w:addPlayer(1, Defaults.stats({ maxHp = 1e6 }), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w.wave:start(150)
		w.wave.budget = -1e9 -- no regular spawns: only the lure
		w.wave.seeded = true
		local function count(): number
			return w:enemyCount()
		end
		run(w, World.LURE_AFTER - 0.6)
		T.eq(count(), 0)
		run(w, 1.2)
		T.eq(count(), World.LURE_BASE + 1)
		for _, e in w.enemies do
			local d = math.sqrt(e.x ^ 2 + e.z ^ 2)
			T.truthy(d >= World.LURE_RING[1] - 4 and d <= World.LURE_RING[2] + 6, "lure ring " .. d)
		end
	end)
	T.it("champions take the free site nearest a squad", function()
		local w = newWorld(13, { champions = true })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 200, 0, 1)
		run(w, 0.1)
		local free = {
			{ x = -200, z = 0 },
			{ x = 190, z = 0 },
			{ x = 0, z = 200 },
			{ x = 180, z = 30 },
		}
		for _ = 1, 20 do
			local s = Champions.pickSite(w, free)
			T.truthy(s == free[2] or s == free[4], "one of the 2 nearest")
		end
	end)
end)

T.describe("Boss poses (C-29)", function()
	T.it("every boss has its own pose data", function()
		local seen = {}
		for _, id in Bosses.ORDER do
			local p = Bosses.POSES[id]
			T.truthy(p ~= nil, id)
			local key = p.stance .. p.windup .. p.strike .. tostring(p.lean)
			T.falsy(seen[key], id .. " duplicates another boss's pose")
			seen[key] = true
		end
		T.eq(Bosses.pose("nope").stance, "upright")
		for _, id in Bosses.ORDER do
			local def = Bosses.get(id) :: any
			T.truthy(type(def.lore) == "string" and #def.lore > 10, id .. " lore")
			T.truthy(type(def.tip) == "string" and string.sub(def.tip, 1, 9) == "Watch for", id .. " tip")
		end
	end)
end)

T.describe("Bots (iteration 1)", function()
	local function view(extra: { [string]: any }?): any
		local v: any = {
			self = { x = 0, z = 0, hp = 100, maxHp = 100, downed = false, abilityReady = false, squad = 1 },
			allies = {},
			enemies = {},
			arenaRadius = 400,
			now = 100,
			stage = 2,
			waveTime = 100,
		}
		for k, x in extra or {} do
			v[k] = x
		end
		return v
	end
	T.it("a downed bot alone asks for Second Wind; with a mate close it waits", function()
		local b = BotBrain.new(Ids.botId(1), "ele_fonte", Rng.new(1))
		local v = view()
		v.self.downed = true
		v.allies = { { id = Ids.botId(2), x = 50, z = 0, downed = false, isBot = true, squad = 1 } }
		T.truthy(b:think(v, 0.1).secondWind)
		v.allies[1].x = 5
		T.falsy(b:think(v, 0.1).secondWind)
		v.allies[1].x = 50
		v.self.canSecondWind = false
		T.falsy(b:think(v, 0.1).secondWind)
	end)
	T.it("bots rush to revive a downed rookie, even from far and under fire", function()
		local b = BotBrain.new(Ids.botId(1), "ele_fonte", Rng.new(2))
		local v = view()
		v.allies = { { id = 1, x = 0, z = 60, downed = true, isBot = false, squad = 1, rookie = true } }
		for i = 1, 12 do
			table.insert(v.enemies, { id = i, kind = 1, x = 0, z = 58 + i * 0.2, hpFrac = 1, flags = 0 })
		end
		local it = b:think(v, 0.1)
		T.truthy(it.moveZ > 0.7, "heads to the rookie " .. it.moveZ)
	end)
end)

return T.finish()
