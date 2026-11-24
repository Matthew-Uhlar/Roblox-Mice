--!strict
-- Iteration 6 (docs/iter/6/PLAN.md §1, team Builder): the 8th class, Tinkerphant.
-- Config wiring (class, abilities, perks, ascension, unlocks, skins, challenge), the
-- World builds (turret targeting / cap / lifetime / PvP x0.5, barricade blocking of
-- mice and enemy heroes, Repair Pulse) and BotBrain's use of them.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Weapons = require("../../src/shared/Combat/Weapons")
local Defaults = require("../../src/shared/Combat/Defaults")
local Stats = require("../../src/shared/Run/Stats")
local Classes = require("../../src/shared/Config/Classes")
local ClassAbilities = require("../../src/shared/Config/ClassAbilities")
local ClassPerks = require("../../src/shared/Config/ClassPerks")
local ClassSkins = require("../../src/shared/Config/ClassSkins")
local AscensionNodes = require("../../src/shared/Config/AscensionNodes")
local RunShop = require("../../src/shared/Config/RunShop")
local Evolutions = require("../../src/shared/Config/Evolutions")
local Challenges = require("../../src/shared/Config/Challenges")
local Monetization = require("../../src/shared/Config/Monetization")
local BotRoster = require("../../src/shared/Bots/BotRoster")
local BotBrain = require("../../src/shared/Bots/BotBrain")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local Passes = require("../../src/shared/Data/Passes")
local Shop = require("../../src/shared/Data/Shop")
local Evolution = require("../../src/shared/Data/Evolution")
local Ids = require("../../src/shared/Util/Ids")

local DT = 1 / 30
local ID = "tinkerphant"

local function newWorld(seed: number?): any
	return World.new({
		rng = Rng.new(seed or 7),
		mods = Defaults.mods(),
		arenaRadius = 300,
		obstacles = {},
		enemyPool = { "mouse" },
		cycle = 1,
		stage = 1,
		enemyCap = 200,
		champions = false,
		carriers = false,
	})
end

-- A Tinkerphant with every ability slot (level 30 picks: turret, barricade, repair).
local function addBuilder(w: any, id: number, x: number, z: number, squad: number?, harmless: boolean?): any
	local s, wpn, a, list = Stats.compute(ID, {}, {}, nil, nil, {
		perks = {},
		level = 30,
		abilities = { "tinkerphant_deploy_turret", "tinkerphant_barricade", "tinkerphant_repair_pulse" },
	})
	wpn = table.clone(wpn)
	if harmless then
		wpn.damage = 0
	end
	w:addPlayer(id, s, wpn, a, x, z, squad or 1)
	if list then
		w:setPlayerAbilities(id, list)
	end
	w:protect(id, 0)
	return w.players[id]
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

local function fxOf(list: { any }, t: string): { any }
	local out = {}
	for _, f in list do
		if f.t == t then
			table.insert(out, f)
		end
	end
	return out
end

T.describe("Tinkerphant config", function()
	T.it("is the 8th class: cheese 4000, the 5th free stomp unlock, never a Robux pass", function()
		T.eq(Classes.ORDER[8], ID)
		local def = Classes.get(ID) :: any
		T.eq(def.unlockCost, 6000) -- iteration 6 (Flow, Economy x1.5): was 4000
		T.eq(def.ability.kind, "turret")
		T.eq(def.weapon.kind, "bolt")
		T.truthy(def.noPassUnlock)
		T.near(def.baseStats.buildHpMult, 1.25)
		local last = Evolutions.FREE_UNLOCKS[#Evolutions.FREE_UNLOCKS]
		T.eq(#Evolutions.FREE_UNLOCKS, 5)
		T.eq(last.classId, ID)
		T.truthy(last.stomps > Evolutions.FREE_UNLOCKS[4].stomps)
		-- Founders' Stampede (Robux) unlocks the other classes but never this one
		local p = ProfileSchema.default()
		Passes.apply(p, "founders")
		T.falsy(p.unlockedClasses[ID])
		T.truthy(p.unlockedClasses.fizzante)
		for _, item in Monetization.ALL do
			T.falsy(string.find(string.lower((item :: any).benefit or ""), "tinkerphant", 1, true), item.key)
		end
		-- cheese buys it
		local q = ProfileSchema.default() :: any
		q.cheese = 4000
		T.truthy(Shop.buy(q, "class:" .. ID))
		T.truthy(q.unlockedClasses[ID])
		T.eq(q.cheese, 0)
		T.truthy(q.classes[ID], "class block")
		T.truthy(Shop.canSelectClass(q, ID))
	end)
	T.it("the stomp track unlocks it at its threshold", function()
		local p = ProfileSchema.default() :: any
		local last = Evolutions.FREE_UNLOCKS[#Evolutions.FREE_UNLOCKS]
		local got = Evolution.addStomps(p, "elephante", last.stomps)
		T.truthy(table.find(got.unlocked, ID))
		T.truthy(p.unlockedClasses[ID])
	end)
	T.it("abilities: Deploy Turret base, Barricade at 5, Repair Pulse at 15", function()
		local list = ClassAbilities.forClass(ID)
		T.eq(#list, 3)
		T.deepEq(
			{ list[1].id, list[2].id, list[3].id },
			{ "tinkerphant_deploy_turret", "tinkerphant_barricade", "tinkerphant_repair_pulse" }
		)
		T.deepEq(
			{ list[1].def.kind, list[2].def.kind, list[3].def.kind },
			{ "turret", "barricade", "repair" }
		)
		T.deepEq({ list[1].unlockLevel, list[2].unlockLevel, list[3].unlockLevel }, { 1, 5, 15 })
		for _, e in list do
			T.truthy(Weapons.ABILITY[e.def.kind], e.id .. " has a Weapons handler")
		end
	end)
	T.it("every per-class table has it: perks, ascension, class buff, skins, challenge, roster", function()
		T.eq(#ClassPerks.branches(ID), 3)
		for n = 1, AscensionNodes.COUNT do
			T.truthy(AscensionNodes.node(ID, n), "node " .. n)
		end
		T.near((AscensionNodes.node(ID, 4) :: any).delta.mul.buildHpMult, 1.25)
		T.truthy(RunShop.CLASS_BUFFS[ID])
		T.eq(#ClassSkins.forClass(ID), 4, "earned skins only (default look = class colour)")
		for _, s in ClassSkins.forClass(ID) do
			T.truthy(ClassSkins.ACCESSORIES[s.accessory], s.id)
		end
		T.truthy(Challenges.get("lone_tusk_" .. ID))
		T.eq(BotRoster.roleOf(ID), "support")
		local s = Stats.compute(ID, {}, {})
		T.near(s.buildHpMult :: number, 1.25)
	end)
end)

T.describe("World builds: turrets", function()
	T.it("deploys at the aim point, shoots the nearest mouse in range, owner gets the kill", function()
		local w = newWorld()
		addBuilder(w, 1, 0, 0, 1, true)
		local fx = {}
		w:step(DT, DT)
		T.truthy(w:useAbility(1, 10, 0, w.now, 1))
		local builds = w:builds()
		T.eq(#builds, 1)
		local b = builds[1]
		T.eq(b.kind, "turret")
		T.near(b.x, 10, 0.01)
		T.near(b.range, 40, 0.01)
		T.near(b.maxHp, 120 * 1.25, 0.01, "passive +25%")
		T.near(b.untilT - w.now, 20, 0.05)
		local near = w:spawnEnemy("mouse", 30, 0)
		local far = w:spawnEnemy("mouse", 10, 60) -- 60 from the turret: out of range
		for _, f in run(w, 3) do
			table.insert(fx, f)
		end
		T.falsy(near.alive, "the mouse in range died")
		T.truthy(far.alive, "out of range")
		T.truthy(#fxOf(fx, "buildShot") >= 1)
		local proj = fxOf(fx, "proj")[1]
		T.eq(proj.kind, "rivet")
		T.eq(proj.src, b.id)
		T.eq(proj.owner, 1)
		T.truthy(w:meter()[1].kills >= 1, "kills credited to the hero")
	end)
	T.it("at most 2 per hero: the oldest is replaced", function()
		local w = newWorld()
		addBuilder(w, 1, 0, 0, 1, true)
		w:step(DT, DT)
		local fx = {}
		for k = 1, 3 do
			w.players[1].abilityReadyAt = 0
			T.truthy(w:useAbility(1, 5 * k, 0, w.now, 1))
			for _, f in w:step(DT, w.now + DT) do
				table.insert(fx, f)
			end
		end
		T.eq(w:buildCount(1, "turret"), 2)
		local ends = fxOf(fx, "buildEnd")
		T.eq(#ends, 1)
		T.eq(ends[1].reason, "replaced")
		T.eq(#fxOf(fx, "build"), 3, "a build Fx per spawn")
	end)
	T.it("expires after its lifetime; resync Fx carry the full state", function()
		local w = newWorld()
		addBuilder(w, 1, 0, 0, 1, true)
		w:step(DT, DT)
		w:useAbility(1, 5, 0, w.now, 1)
		local fx = run(w, 21)
		T.eq(#w:builds(), 0)
		local ends = fxOf(fx, "buildEnd")
		T.eq(ends[1].reason, "expired")
		local b = fxOf(fx, "build")[1]
		for _, k in
			{ "id", "kind", "owner", "squad", "x", "z", "r", "dx", "dz", "half", "range", "hpFrac", "untilT" }
		do
			T.truthy(b[k] ~= nil, "build fx field " .. k)
		end
		T.truthy(#fxOf(fx, "build") >= 5, "periodic resync")
	end)
	T.it("mice bite it and destroy it", function()
		local w = newWorld()
		addBuilder(w, 1, 0, 0, 1, true)
		w:step(DT, DT)
		w:useAbility(1, 20, 0, w.now, 1)
		local b = w.buildEnts[1]
		b.dmg = 0 -- a harmless turret: only the bites matter
		for k = 1, 8 do
			w:spawnEnemy("mouse", 20 + math.cos(k) * 2.5, math.sin(k) * 2.5)
		end
		local fx = run(w, 1.5)
		T.truthy(#fxOf(fx, "buildHp") >= 1, "HP Fx")
		T.truthy(b.hp < b.maxHp)
		run(w, 20)
		T.falsy(b.alive)
	end)
	T.it("PvP: shoots an enemy hero (no mice) at x0.5 of the rivet damage; never its own squad", function()
		local function hpLost(halfMult: number): number
			local w = newWorld(3)
			addBuilder(w, 1, 0, 0, 1, true)
			local s = Defaults.stats()
			s.maxHp = 1000
			local wpn = Defaults.weapon("bolt")
			wpn.damage = 0
			w:addPlayer(2, s, wpn, Defaults.ability("burst"), 25, 0, 2)
			w:addPlayer(3, table.clone(s), table.clone(wpn), Defaults.ability("burst"), -10, 0, 1) -- squadmate
			w:protect(2, 0)
			w:protect(3, 0)
			w:step(DT, DT)
			World.TURRET_PVP_MULT = halfMult
			w:useAbility(1, 5, 0, w.now, 1)
			run(w, 4)
			World.TURRET_PVP_MULT = 0.5
			T.eq(w:getPlayer(3).hp, 1000, "no friendly fire")
			return 1000 - w:getPlayer(2).hp
		end
		local half = hpLost(0.5)
		local full = hpLost(1)
		T.truthy(half > 0, "the enemy hero is shot")
		T.near(half / full, 0.5, 0.08)
	end)
end)

T.describe("World builds: barricades", function()
	T.it("a 14-stud wall across the aim line that mice cannot cross (they go around or bite it)", function()
		local w = newWorld(11)
		addBuilder(w, 1, 0, 0, 1, true)
		w:step(DT, DT)
		T.truthy(w:useAbility(1, 10, 0, w.now, 2))
		local b = w.buildEnts[1]
		T.eq(b.kind, "barricade")
		T.near(b.half * 2, 14, 0.01)
		T.near(math.abs(b.dz), 1, 0.01, "perpendicular to the aim (x axis)")
		T.near(b.maxHp, 220 * 1.25, 0.01)
		-- a mouse straight behind the wall walks toward the hero: it must never be inside it
		local m = w:spawnEnemy("mouse", 25, 0)
		local inside = false
		for _ = 1, 60 do
			w:step(DT, w.now + DT)
			if m.alive and math.abs(m.x - b.x) < b.r + m.r - 0.05 and math.abs(m.z - b.z) < b.half then
				inside = true
			end
		end
		T.falsy(inside, "never inside the wall")
		T.truthy(m.x > b.x or math.abs(m.z) > b.half - 0.5, "went around the end, not through")
	end)
	T.it("blocks enemy heroes, never its own squad", function()
		local w = newWorld()
		addBuilder(w, 1, 0, 0, 1, true)
		local s = Defaults.stats()
		local wpn = Defaults.weapon("bolt")
		w:addPlayer(2, s, wpn, Defaults.ability("burst"), 14, 0, 2)
		w:addPlayer(3, table.clone(s), table.clone(wpn), Defaults.ability("burst"), 6, 0, 1)
		w:step(DT, DT)
		w:useAbility(1, 10, 0, w.now, 2)
		-- the enemy walks west through the wall: it stays on its side
		for x = 13, 4, -0.5 do
			w:setPlayerPosition(2, x, 0)
		end
		T.truthy(w:getPlayer(2).x >= 10 + World.BARRICADE_THICK + World.PLAYER_RADIUS - 0.01)
		-- the squadmate walks east through it freely
		for x = 6, 16, 0.5 do
			w:setPlayerPosition(3, x, 0)
		end
		T.near(w:getPlayer(3).x, 16, 0.01)
		-- the enemy goes around the end
		w:setPlayerPosition(2, 14, 12)
		w:setPlayerPosition(2, 4, 12)
		T.near(w:getPlayer(2).x, 4, 0.01)
	end)
	T.it("enemy shots fly through it; enemy melee / explosions damage it", function()
		local w = newWorld()
		addBuilder(w, 1, 0, 0, 1, true)
		w:step(DT, DT)
		w:useAbility(1, 10, 0, w.now, 2)
		local b = w.buildEnts[1]
		local s = Defaults.stats()
		local wpn = Defaults.weapon("bolt")
		w:addPlayer(2, s, wpn, Defaults.ability("burst"), 30, 0, 2)
		w:protect(2, 0)
		w:step(DT, w.now + DT)
		local foe = w.players[2]
		-- a projectile through the wall
		w:spawnPlayerProjectile({
			owner = foe,
			x = 20,
			z = 0,
			vx = -60,
			vz = 0,
			r = 0.8,
			dmg = 50,
			pierce = 0,
			ttl = 1,
			kind = "bolt",
			knock = 0,
		})
		run(w, 0.4)
		T.eq(b.hp, b.maxHp, "projectiles pass")
		Weapons.explode(w, foe, 11, 0, 3, 40, {})
		T.near(b.hp, b.maxHp - 40 * World.BUILD_HERO_MULT, 0.01)
	end)
end)

T.describe("Repair Pulse", function()
	T.it("heals squadmates and the squad's builds in reach, not enemies", function()
		local w = newWorld()
		local me = addBuilder(w, 1, 0, 0, 1, true)
		local s = Defaults.stats()
		local wpn = Defaults.weapon("bolt")
		wpn.damage = 0
		w:addPlayer(2, table.clone(s), table.clone(wpn), Defaults.ability("burst"), 5, 0, 1)
		w:addPlayer(3, table.clone(s), table.clone(wpn), Defaults.ability("burst"), -5, 0, 2)
		w:step(DT, DT)
		w:useAbility(1, 8, 0, w.now, 1)
		local b = w.buildEnts[1]
		b.hp = b.maxHp * 0.3
		w.players[2].hp = 50
		w.players[3].hp = 50
		me.hp = me.maxHp * 0.5
		T.truthy(w:useAbility(1, 0, 0, w.now, 3))
		T.near(w.players[2].hp, 50 + 100 * 0.12, 0.01)
		T.eq(w.players[3].hp, 50, "enemy not healed")
		T.near(b.hp, b.maxHp * (0.3 + 0.12 * Weapons.REPAIR_BUILD_MULT), 0.01)
		T.truthy(me.hp > me.maxHp * 0.5, "the caster too")
	end)
end)

T.describe("Echo / Cataclysm on builds", function()
	T.it("echo lengthens the lifetime; Cataclysm adds to the cap (no duplicate casts)", function()
		local w = newWorld()
		local p = addBuilder(w, 1, 0, 0, 1, true)
		p.stats.abilityEcho = 0.5
		p.stats.abilityRepeat = 1
		w:step(DT, DT)
		for k = 1, 3 do
			p.abilityReadyAt = 0
			w:useAbility(1, 5 * k, 0, w.now, 1)
			run(w, 1)
		end
		T.eq(w:buildCount(1, "turret"), 3)
		T.truthy(w.buildEnts[1].untilT - w.buildEnts[1].born > 29.9)
	end)
	T.it("leaving the world removes the hero's builds", function()
		local w = newWorld()
		addBuilder(w, 1, 0, 0, 1, true)
		w:step(DT, DT)
		w:useAbility(1, 5, 0, w.now, 1)
		w:removePlayer(1)
		T.eq(#w:builds(), 0)
	end)
end)

T.describe("BotBrain plays Tinkerphant", function()
	local function view(enemies: { any }, extra: { [string]: any }?): any
		local v: any = {
			self = {
				x = 0,
				z = 0,
				hp = 100,
				maxHp = 100,
				downed = false,
				abilityReady = true,
				abilityReadySlots = { true, true, true },
				squad = 1,
			},
			allies = {},
			enemies = enemies,
			arenaRadius = 300,
			now = 10,
			builds = {},
		}
		for k, x in extra or {} do
			v[k] = x
		end
		return v
	end
	local function mice(n: number, x: number, z: number): { any }
		local out = {}
		for i = 1, n do
			table.insert(
				out,
				{ id = i, kind = 1, x = x + (i % 3), z = z + math.floor(i / 3), hpFrac = 1, flags = 0 }
			)
		end
		return out
	end
	local function brain(): any
		local b = BotBrain.new(Ids.botId(1), ID, Rng.new(1))
		local list = {}
		for _, e in ClassAbilities.forClass(ID) do
			table.insert(list, e.def)
		end
		b:setAbilities(list)
		return b
	end
	T.it("deploys a turret toward a pack, close to itself", function()
		local b = brain()
		local aim = b:_ability(view(mice(4, 25, 0)), nil)
		assert(aim, "aim")
		T.eq(aim.slot, 1)
		T.truthy(aim.x > 0 and aim.x <= BotBrain.TURRET_AHEAD + 0.01, "a few studs toward them")
		T.falsy(b:_ability(view({})), "nothing to shoot: hold")
	end)
	T.it("holds the turret while two fresh ones stand; walls off a close pack; repairs when hurt", function()
		local b = brain()
		local builds = {
			{ id = 1, kind = "turret", owner = b.id, squad = 1, x = 3, z = 0, hpFrac = 1, untilT = 25 },
			{ id = 2, kind = "turret", owner = b.id, squad = 1, x = -3, z = 0, hpFrac = 1, untilT = 28 },
		}
		local v = view(mice(6, 12, 0), { builds = builds })
		local aim = b:_ability(v, nil)
		assert(aim, "aim")
		T.eq(aim.slot, 2, "barricade, not a third turret")
		T.near(aim.x, BotBrain.BARRICADE_AHEAD, 0.5)
		builds[1].hpFrac = 0.3
		v = view({}, { builds = builds })
		local r = b:_ability(v, nil)
		assert(r, "repair")
		T.eq(r.slot, 3)
		local hurt = view({})
		hurt.self.hp = 40
		T.eq((b:_ability(hurt, nil) :: any).slot, 3)
	end)
	T.it("a bot match: the bot deploys turrets and they kill mice", function()
		local w = newWorld(21)
		local bid = Ids.botId(1)
		addBuilder(w, bid, 0, 0, 1, true)
		local b = brain()
		for k = 1, 10 do
			w:spawnEnemy("mouse", 30 + k, (k % 4) * 3)
		end
		local deployed = 0
		for _ = 1, 30 * 8 do
			local info = w:getPlayer(bid)
			local snaps = w:snapshot()
			local v = view(snaps, { builds = w:builds(), now = w.now })
			v.self.abilityReady = w.now >= info.abilityReadyAt
			v.self.abilityReadySlots = {
				w.now >= info.abilityReadyAts[1],
				w.now >= (info.abilityReadyAts[2] or 0),
				w.now >= (info.abilityReadyAts[3] or 0),
			}
			local intent = b:think(v, DT)
			if intent.ability then
				if w:useAbility(bid, intent.ability.x, intent.ability.z, w.now, intent.ability.slot) then
					deployed += 1
				end
			end
			w:step(DT, w.now + DT)
		end
		T.truthy(deployed >= 1, "cast something")
		T.truthy(w:meter()[bid].kills >= 5, "turrets did the killing: " .. w:meter()[bid].kills)
	end)
end)

return T.finish()
