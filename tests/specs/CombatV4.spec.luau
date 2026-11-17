--!strict
-- v4 combat (docs/V4-PLAN.md, docs/COMBAT-API.md "v4"): stage radius, the storm
-- ("The Melt"), redeploy, the PvP channel, PvE-only talents, level scaling,
-- bosses, rookies and the v4 bot behaviour.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local Maps = require("../../src/shared/Config/Maps")
local Storm = require("../../src/shared/Config/Storm")
local Bosses = require("../../src/shared/Config/Bosses")
local ChampConfig = require("../../src/shared/Config/Champions")
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

local function bolt(dmg: number, cd: number?): any
	local w = Defaults.weapon("bolt")
	w.damage = dmg
	w.pierce = 0
	w.cooldown = cd or 0.5
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

local function eventsOf(list: { any }, typ: string): { any }
	local out = {}
	for _, e in list do
		if e.type == typ then
			table.insert(out, e)
		end
	end
	return out
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

T.describe("v4 maps", function()
	T.it("stageRadius: 480/420/360/310 x size/350, clamped 300-560", function()
		T.eq(Maps.stageRadius("plains", 1), 480)
		T.eq(Maps.stageRadius("plains", 4), 310)
		T.eq(Maps.stageRadius("plains", 9), 310)
		T.near(Maps.stageRadius("moon", 1), 480 * 400 / 350, 1e-9)
		T.eq(Maps.stageRadius("swamp", 4), 300) -- 310 x 320/350 = 283 -> clamped
		for _, id in Maps.ORDER do
			for st = 1, 4 do
				local r = Maps.stageRadius(id, st)
				T.truthy(r >= 300 and r <= 560)
				if st > 1 then
					T.truthy(r <= Maps.stageRadius(id, st - 1), "each stage smaller")
				end
			end
		end
	end)
end)

T.describe("v4 Storm config", function()
	T.it("the schedule: 0.65 / 0.40 / 0.22 R closing 30-60, 85-110, 125-150 at 2/4/8 %", function()
		local R = 480
		local z0 = Storm.zoneAt(R, 1, 0, 7)
		T.eq(z0.r, R)
		T.near(z0.toR, 0.65 * R, 1e-9)
		T.eq(z0.closeStart, 30)
		T.eq(z0.closeEnd, 60)
		T.eq(z0.dps, 0.02)
		local z70 = Storm.zoneAt(R, 1, 70, 7)
		T.near(z70.r, 0.65 * R, 1e-9)
		T.near(z70.toR, 0.40 * R, 1e-9)
		T.eq(z70.dps, 0.02)
		T.eq(Storm.zoneAt(R, 1, 90, 7).dps, 0.04)
		local z130 = Storm.zoneAt(R, 1, 130, 7)
		T.near(z130.toR, 0.22 * R, 1e-9)
		T.eq(z130.dps, 0.08)
		T.eq(z130.closeEnd, 150)
		-- longer waves stretch the times
		T.near(Storm.zoneAt(R, 1, 0, 7, 165).closeEnd, 66, 1e-9)
	end)
	T.it("boss: holds 0.22 R, then squeezes to 0.12 R after 90 s at 12 %", function()
		local R = 400
		local hold = Storm.bossZone(R, 2, 10, 3)
		T.near(hold.r, 0.22 * R, 1e-9)
		T.eq(hold.toR, hold.r)
		local sq = Storm.bossZone(R, 2, 95, 3)
		T.near(sq.toR, 0.12 * R, 1e-9)
		T.eq(sq.closeStart, 90)
		T.eq(sq.closeEnd, 120)
		T.eq(sq.dps, 0.12)
	end)
	T.it("the centre is seeded, within 0.1 R, shared by every circle", function()
		for seed = 1, 50 do
			local cx, cz = Storm.center(480, 1 + seed % 4, seed)
			T.truthy(math.sqrt(cx * cx + cz * cz) <= 48 + 1e-9)
			local a, b = Storm.center(480, 1 + seed % 4, seed)
			T.eq(a, cx)
			T.eq(b, cz)
			local z = Storm.zoneAt(480, 1 + seed % 4, 100, seed)
			T.eq(z.cx, cx)
		end
		local x1 = Storm.center(480, 1, 5)
		local x2 = Storm.center(480, 2, 5)
		T.truthy(x1 ~= x2, "a new centre each stage")
	end)
	T.it("radiusAt lerps; toWorld shifts; safe corners end at 30 s", function()
		local z = Storm.toWorld(
			{ cx = 0, cz = 0, r = 100, toR = 50, closeStart = 10, closeEnd = 20, dps = 0.02 },
			1000
		)
		T.eq(z.closeStart, 1010)
		T.eq(Storm.radiusAt(z, 1000), 100)
		T.near(Storm.radiusAt(z, 1015), 75, 1e-9)
		T.eq(Storm.radiusAt(z, 2000), 50)
		T.truthy(Storm.safeCornersOn(29))
		T.falsy(Storm.safeCornersOn(30))
	end)
end)

T.describe("v4 World storm", function()
	local function stormWorld(): any
		local w = newWorld(1)
		w:addPlayer(
			1,
			Defaults.stats({ maxHp = 200, armor = 50 }),
			harmless(),
			Defaults.ability("burst"),
			0,
			0,
			1
		)
		w:addPlayer(2, Defaults.stats({ maxHp = 200 }), harmless(), Defaults.ability("burst"), 150, 0, 1)
		w:step(DT, 1)
		return w
	end

	T.it("setZone / zone: emits the storm Fx and lerps the radius on the world clock", function()
		local w = stormWorld()
		w:setZone({ cx = 0, cz = 0, r = 200, toR = 100, closeStart = 2, closeEnd = 4, dps = 0.04 })
		local fx = fxOf(w:step(DT, 1 + DT), "storm")
		T.eq(#fx, 1)
		T.eq(fx[1].r, 200)
		T.eq(fx[1].toR, 100)
		T.eq(fx[1].dps, 0.04)
		T.truthy(type(fx[1].now) == "number")
		local zn = w:zone()
		T.eq(zn.radius, 200)
		w:step(DT, 3)
		T.near(w:zone().radius, 150, 1e-6)
		w:step(DT, 5)
		T.eq(w:zone().radius, 100)
	end)

	T.it("heroes outside take dps x max HP per second (no armor); inside take nothing", function()
		local w = stormWorld()
		w:setZone({ cx = 0, cz = 0, r = 100, toR = 100, closeStart = 0, closeEnd = 0, dps = 0.04 })
		local ev = {}
		for _ = 1, 60 do
			w:step(DT, w.now + DT)
			for _, e in w:drainEvents() do
				table.insert(ev, e)
			end
		end
		-- 2 s outside at 4% of 200 HP = 16
		T.near(w:getPlayer(2).hp, 200 - 16, 4.01)
		T.eq(w:getPlayer(1).hp, 200)
		T.truthy(#eventsOf(ev, "stormDamage") >= 3)
		T.truthy(w:getPlayer(2).outsideZone)
		T.falsy(w:getPlayer(1).outsideZone)
	end)

	T.it("storm damage never sets lastHurtAt / i-frames (POI channels and sprint go on)", function()
		local w = stormWorld()
		w:setZone({ cx = 0, cz = 0, r = 100, toR = 100, closeStart = 0, closeEnd = 0, dps = 0.04 })
		run(w, 1)
		T.eq(w.players[2].lastHurtAt, nil)
		T.eq(w.players[2].iframeUntil, 0)
	end)

	T.it("downs a hero who stays out; downed heroes outside bleed out twice as fast", function()
		local w = stormWorld()
		w:setZone({ cx = 0, cz = 0, r = 100, toR = 100, closeStart = 0, closeEnd = 0, dps = 0.5 })
		run(w, 2.5)
		local p = w:getPlayer(2)
		T.truthy(p.downed, "downed by the storm")
		local left = p.downedUntil - w.now
		run(w, 2)
		local now = w:getPlayer(2).downedUntil - w.now
		T.near(now, left - 2 * World.STORM_DOWNED_DRAIN, 0.2)
	end)

	T.it("setStormPlan follows Config/Storm and turns the safe corners off at 30 s", function()
		local w = newWorld(4, {
			safeZones = { [1] = { x = 0, z = 0, r = 20 } },
			enemyCap = 0,
		})
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 50, 0, 2)
		w:setStormPlan({ radius = 300, stage = 1, seed = 9 })
		w:startWaves(150)
		local fx = run(w, 1)
		T.eq(#fxOf(fx, "storm"), 1)
		local zn = w:zone()
		T.near(zn.toR, 0.65 * 300, 1e-9)
		T.truthy(w:inSafeZone(w.players[1]))
		run(w, 30)
		T.falsy(w:inSafeZone(w.players[1]), "corners are off")
		run(w, 40) -- 71 s: circle 2 shown
		T.near(w:zone().toR, 0.40 * 300, 1e-9)
	end)

	T.it("champions spawn only inside the next circle", function()
		local w = newWorld(5, { champions = true })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPoi({ kind = "champion_site", x = 200, z = 0 })
		w:addPoi({ kind = "champion_site", x = 30, z = 0 })
		w:setZone({ cx = 0, cz = 0, r = 280, toR = 100, closeStart = 1e9, closeEnd = 1e9 + 1, dps = 0.02 })
		w:startWaves(150)
		local spawns = {}
		for _ = 1, math.floor(120 / DT) do
			w:step(DT, w.now + DT)
			for _, e in w:drainEvents() do
				if e.type == "championSpawn" then
					table.insert(spawns, e)
				end
			end
		end
		T.truthy(#spawns >= 1)
		for _, e in spawns do
			T.truthy(math.abs(e.x) < 60, "spawned at the inner site, x = " .. e.x)
		end
	end)
end)

T.describe("v4 redeploy", function()
	T.it("revives a dead hero at (x, z) with hpFrac and `protect` s of protection", function()
		local w = newWorld(6)
		w:addPlayer(1, Defaults.stats({ maxHp = 100 }), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 40, 0, 2)
		run(w, 0.1)
		w:_kill(w.players[1], nil)
		T.truthy(w:getPlayer(1).dead)
		T.falsy(w:redeploy(2, 0, 0, 0.6, 5), "a standing hero cannot redeploy")
		T.truthy(w:redeploy(1, 20, 10, 0.6, 5))
		local p = w:getPlayer(1)
		T.falsy(p.dead)
		T.falsy(p.downed)
		T.near(p.hp, 60, 1e-6)
		T.near(p.x, 20, 1e-6)
		T.near(p.protectUntil - w.now, 5, 1e-6)
		local tp = w:drainTeleports()
		T.eq(tp[#tp].id, 1)
		local ev = eventsOf(w:drainEvents(), "revived")
		T.eq(ev[#ev].kind, "redeploy")
		T.falsy(w:isEliminated(1))
	end)
end)

T.describe("v4 PvP channel", function()
	local function duel(): any
		local w = newWorld(7)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 3, 0, 1)
		w:addPlayer(
			3,
			Defaults.stats({ maxHp = 1000, armor = 10, regen = 50 }),
			harmless(),
			Defaults.ability("burst"),
			6,
			0,
			2
		)
		run(w, 0.1)
		for id = 1, 3 do
			w:protect(id, 0)
		end
		return w
	end
	local function unit(): number
		return World.PVP_MULT * World.PVP_DAMAGE
	end

	T.it("armor counts x PVP_ARMOR_MULT against heroes", function()
		local w = duel()
		local took = w:damageHeroFrom(w.players[3], 100, w.players[1])
		T.near(took, 100 * unit() - 10 * World.PVP_ARMOR_MULT, 1e-6)
	end)

	T.it("a per-attacker 0.25 s lockout: a second attacker still lands, the same one does not", function()
		local w = duel()
		T.truthy(w:damageHeroFrom(w.players[3], 100, w.players[1]) > 0)
		T.eq(w:damageHeroFrom(w.players[3], 100, w.players[1]), 0, "same attacker, locked")
		T.truthy(w:damageHeroFrom(w.players[3], 100, w.players[2]) > 0, "another attacker lands")
		run(w, World.PVP_LOCKOUT + 0.05)
		T.truthy(w:damageHeroFrom(w.players[3], 100, w.players[1]) > 0, "after the lockout")
	end)

	T.it("a bigger hit inside the lockout tops up the difference", function()
		local w = duel()
		local hp0 = w.players[3].hp
		w:damageHeroFrom(w.players[3], 100, w.players[1])
		local hp1 = w.players[3].hp
		w:damageHeroFrom(w.players[3], 300, w.players[1])
		T.near(hp1 - w.players[3].hp, 200 * unit(), 1e-6)
		T.truthy(hp0 > hp1)
	end)

	T.it("a hero hit gives mice-only i-frames; other heroes still land", function()
		local w = duel()
		w:damageHeroFrom(w.players[3], 100, w.players[1])
		local blocked = World.PVP_MICE_IFRAMES > 0
		T.eq(w:damagePlayer(w.players[3], 50, "contact") > 0, not blocked)
		T.truthy(w:damageHeroFrom(w.players[3], 100, w.players[2]) > 0, "a second attacker lands")
	end)

	T.it("regen pauses PVP_REGEN_PAUSE s after PvP damage", function()
		local w = duel()
		w:damageHeroFrom(w.players[3], 100, w.players[1])
		local hp = w.players[3].hp
		run(w, World.PVP_REGEN_PAUSE - 0.3)
		T.near(w.players[3].hp, hp, 1e-6)
		run(w, 1)
		T.truthy(w.players[3].hp > hp, "regen back")
	end)

	T.it("downed heroes: one finishing hit per DOWNED_HIT_GAP, whoever attacks", function()
		local w = duel()
		w:damageHeroFrom(w.players[3], 1e6, w.players[1])
		T.truthy(w:getPlayer(3).downed)
		run(w, math.max(World.PVP_LOCKOUT, World.DOWNED_HIT_GAP) + 0.05)
		w:damageHeroFrom(w.players[3], 10, w.players[1])
		w:damageHeroFrom(w.players[3], 10, w.players[2])
		T.eq(w:getPlayer(3).downedHits, if World.DOWNED_HIT_GAP > 0 then 1 else 2)
		run(w, World.DOWNED_HIT_GAP + 0.05)
		w:damageHeroFrom(w.players[3], 10, w.players[2])
		T.eq(w:getPlayer(3).downedHits, if World.DOWNED_HIT_GAP > 0 then 2 else 3)
	end)

	T.it("hit / die Fx carry `by` = the hero who hit / killed", function()
		local w = newWorld(20, { enemyCap = 10 })
		w:addPlayer(1, Defaults.stats(), bolt(10), Defaults.ability("burst"), 0, 0, 1)
		run(w, 0.1)
		local e = w:spawnEnemy("mouse", 6, 0)
		e.hp, e.maxHp = 15, 15
		local fx = run(w, 2)
		local hits, dies = fxOf(fx, "hit"), fxOf(fx, "die")
		T.truthy(#hits >= 1 and #dies >= 1)
		T.eq(hits[1].by, 1)
		T.eq(dies[1].by, 1)
		local e2 = w:spawnEnemy("mouse", -60, 0)
		w:_killEnemy(e2, nil, true, true)
		local d2 = fxOf(w:step(DT, w.now + DT), "die")
		T.eq(d2[1].by, nil)
	end)

	T.it("pveDamageMult multiplies damage to mice only", function()
		local w = newWorld(8, { enemyCap = 10 })
		local s = Defaults.stats({ pveDamageMult = 2 } :: any)
		w:addPlayer(1, s, bolt(10), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(3, Defaults.stats({ maxHp = 1000 }), harmless(), Defaults.ability("burst"), 80, 0, 2)
		run(w, 0.1)
		local e = w:spawnEnemy("mouse", 6, 0)
		e.hp, e.maxHp = 1000, 1000
		run(w, 0.4)
		T.near(1000 - e.hp, 20, 1e-6)
		w:protect(3, 0)
		T.near(w:damageHeroFrom(w.players[3], 10, w.players[1]), 10 * unit(), 1e-6)
	end)
end)

T.describe("v4 champion rewards", function()
	T.it("the top-damage squad is rewarded; its dead members get their gear when they return", function()
		local w = newWorld(21, { champions = true })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 20, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 25, 1)
		w:addPlayer(3, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, -20, 2)
		run(w, 0.1)
		w:_kill(w.players[2], nil)
		local c = w:spawnChampion("champ_captain", 0, 0)
		run(w, 2)
		c.dmgBySquad = { [1] = 500, [2] = 100 }
		w:_killEnemy(c, w.players[3]) -- squad 2 lands the blow
		local dead = nil
		for _, ev in w:drainEvents() do
			if ev.type == "championDead" then
				dead = ev
			end
		end
		T.eq(dead.squad, 1, "top damage wins")
		T.eq(dead.killerSquad, 2)
		T.truthy(table.find(dead.ids, 2) ~= nil, "the dead member is in the share")
		T.truthy(next(w:gearOf(1)) ~= nil, "standing member equipped")
		T.eq(next(w:gearOf(2)), nil, "nothing while dead")
		T.truthy(w:redeploy(2, 0, 30, 0.6, 1))
		T.truthy(next(w:gearOf(2)) ~= nil, "gear arrives on return")
	end)
end)

T.describe("v4 level scaling and bosses", function()
	T.it("mouse HP x (1 + 0.06 x (average level - 1))", function()
		local w = newWorld(9, { enemyCap = 50 })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:setHeroLevel(1, 11)
		w:startWaves(60)
		run(w, 1)
		local e = nil
		for _, m in w.enemies do
			if m.alive then
				e = m
				break
			end
		end
		T.truthy(e ~= nil)
		T.near(e.maxHp, e.def.hp * (1 + World.MOUSE_HP_PER_LEVEL * 10), 1e-6)
		T.eq(w:avgHeroLevel(), 11)
	end)

	T.it("boss HP follows standing heroes and level; the final boss x2.5 with a third phase", function()
		T.near(Bosses.hpScale(3, nil, false), Bosses.HERO_HP_BASE + Bosses.HERO_HP_PER_SQUAD, 1e-9)
		T.truthy(Bosses.hpScale(12, 8) > Bosses.hpScale(3, 8))
		T.near(Bosses.hpScale(3, 8, true), Bosses.hpScale(3, 8) * 2.5, 1e-9)
		T.near(Bosses.hpScale(3, nil, false, 2), Bosses.hpScale(3, nil) * Bosses.STAGE_HP[2], 1e-9)
		T.near(
			Bosses.hpScale(3, nil, false, 9),
			Bosses.hpScale(3, nil) * Bosses.STAGE_HP[#Bosses.STAGE_HP],
			1e-9
		)
		local w = newWorld(10, { stage = 4 })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		run(w, 0.1)
		local b = w:spawnBoss("giant_tree", 0, 40)
		local def = Bosses.get("giant_tree") :: any
		T.near(b.maxHp, def.hp * Bosses.hpScale(1, nil, true, 4), 1e-6)
		T.truthy(b.final)
		run(w, World.BOSS_INTRO + 0.1)
		w:damageEnemy(b, b.maxHp * 0.6, nil)
		T.eq(b.phase, 2)
		w:damageEnemy(b, b.maxHp * 0.2, nil)
		T.eq(b.phase, 3)
		local ev = eventsOf(w:drainEvents(), "bossPhase")
		T.eq(ev[#ev].amount, 3)
		local w2 = newWorld(11, { stage = 2 })
		w2:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		local b2 = w2:spawnBoss("giant_tree", 0, 40, { scale = false })
		T.eq(b2.maxHp, def.hp)
		T.falsy(b2.final)
	end)

	T.it("champion HP follows the average hero level", function()
		local w = newWorld(12, { champions = true })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		local a = w:spawnChampion("champ_thunder", 50, 0)
		w:setHeroLevel(1, 20)
		local b = w:spawnChampion("champ_thunder", -50, 0)
		T.near(b.maxHp / a.maxHp, ChampConfig.levelHpMult(20), 1e-6)
	end)
end)

T.describe("v4 rookies", function()
	T.it("enemy bots' auto-weapons skip a rookie in stage 1, not in stage 2", function()
		for _, stage in { 1, 2 } do
			local w = newWorld(13, { stage = stage })
			local bot = Ids.botId(1)
			w:addPlayer(bot, Defaults.stats(), bolt(10), Defaults.ability("burst"), 0, 0, 1)
			w:addPlayer(5, Defaults.stats({ maxHp = 1000 }), harmless(), Defaults.ability("burst"), 6, 0, 2)
			w:setRookie(5, true)
			run(w, 0.1)
			w:protect(bot, 0)
			w:protect(5, 0)
			run(w, 2)
			local hurt = w:getPlayer(5).hp < 1000
			T.eq(hurt, stage == 2, "stage " .. stage)
			T.truthy(w:getPlayers()[5].rookie)
		end
	end)
end)

T.describe("v4 BotBrain", function()
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

	T.it("walks back inside the next storm circle", function()
		local b = BotBrain.new(Ids.botId(1), "ele_fonte", Rng.new(1))
		local v = view({ zone = { cx = 0, cz = 0, radius = 150, toR = 100 } })
		v.self.x = 140
		local it = b:think(v, 0.1)
		T.truthy(it.moveX < -0.5, "heads to the centre " .. it.moveX)
		T.falsy(BotBrain.inZone(v, 140, 0))
		T.truthy(BotBrain.inZone(v, 50, 0))
	end)

	T.it("follows a live squad ping and drops an expired one", function()
		local b = BotBrain.new(Ids.botId(1), "ele_fonte", Rng.new(2))
		local v = view({ ping = { x = 0, z = 80, kind = "go", t = 99 } })
		local it = b:think(v, 0.1)
		T.truthy(it.moveZ > 0.6, "goes to the ping")
		v.now = 99 + BotBrain.PING_TTL + 1
		T.eq(b:_livePing(v), nil)
		b:setPing({ x = 80, z = 0, untilT = 200 })
		T.truthy(b:_livePing(view({ now = 150 })) ~= nil)
	end)

	T.it("never targets a rookie in stage 1", function()
		local b = BotBrain.new(Ids.botId(1), "ele_fonte", Rng.new(3))
		local foe = { id = 7, x = 5, z = 0, downed = false, isBot = false, squad = 2, rookie = true }
		local v = view({ stage = 1, waveTime = 140, foes = { foe } })
		local f = b:_pickFoe(v, {}, { foe })
		T.eq(f, nil)
		v.stage = 2
		f = b:_pickFoe(v, {}, { foe })
		T.eq(f, foe)
	end)

	T.it("uses the equipped alternate ability", function()
		local b = BotBrain.new(Ids.botId(1), "elephante", Rng.new(4), { kind = "ring", area = 11 })
		T.eq(b.abilityKind, "ring")
		T.eq(b.abilityArea, 11)
		b:setAbility({ kind = "shield", area = 9 })
		T.eq(b.abilityKind, "shield")
	end)
end)

return T.finish()
