--!strict
-- Points of interest (GDD §3.8): Combat/Pois.luau logic and its Combat/World integration.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local Pois = require("../../src/shared/Combat/Pois")
local Config = require("../../src/shared/Config/Pois")
local Maps = require("../../src/shared/Config/Maps")
local Stats = require("../../src/shared/Run/Stats")
local BotBrain = require("../../src/shared/Bots/BotBrain")
local FxFilter = require("../../src/shared/Combat/FxFilter")

local DT = 1 / 30

-- A quiet world: enemyCap 0 means the waves spawn nothing (camps still spawn their pack).
local function newWorld(seed: number, extra: { [string]: any }?): any
	local o: any = {
		rng = Rng.new(seed),
		mods = Defaults.mods(),
		arenaRadius = 120,
		obstacles = {},
		enemyPool = { "mouse" },
		cycle = 1,
		stage = 1,
		enemyCap = 0,
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

local function addHero(w: any, id: number, x: number, z: number)
	w:addPlayer(id, Defaults.stats(), harmless(), Defaults.ability("burst"), x, z)
end

local function run(w: any, seconds: number): { any }
	local all = {}
	local t = w.now
	for _ = 1, math.floor(seconds / DT + 0.5) do
		t += DT
		for _, f in w:step(DT, t) do
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

local function poiOf(w: any, id: number): any
	for _, p in w:pois() do
		if p.id == id then
			return p
		end
	end
	return nil
end

-- JSON-safe: numbers (finite), strings, booleans and plain arrays/maps of those.
local function jsonSafe(v: any, depth: number?): boolean
	local d = depth or 0
	local ty = type(v)
	if ty == "number" then
		return v == v and v ~= math.huge and v ~= -math.huge
	elseif ty == "string" or ty == "boolean" or v == nil then
		return true
	elseif ty == "table" and d < 4 then
		for k, x in v do
			if (type(k) ~= "string" and type(k) ~= "number") or not jsonSafe(x, d + 1) then
				return false
			end
		end
		return true
	end
	return false
end

T.describe("Config.Pois / Maps POI tables", function()
	T.it("every map table entry is a known POI kind", function()
		for _, mapId in Maps.ORDER do
			local def = Maps.get(mapId) :: any
			for _, e in def.poiTable do
				T.truthy(Config.get(e.id) ~= nil, mapId .. ": unknown POI " .. e.id)
			end
		end
		for _, rare in Config.RARES do
			T.truthy(Config.get(rare.id) ~= nil and (Config.get(rare.id) :: any).rare == true, rare.id)
		end
	end)
	T.it("defs are complete and sane", function()
		for id, def in Config.defs do
			T.eq(def.id, id)
			T.truthy(#def.name > 0 and #def.description > 0, id)
			T.truthy(def.radius > 0, id .. " radius")
			if def.mode == "channel" then
				T.truthy((def.channel or 0) > 0, id .. " channel")
			end
			if def.buff then
				T.truthy(def.buff.duration > 0, id .. " buff duration")
				T.truthy((Stats.DEFAULT :: any)[def.buff.stat] ~= nil, id .. " buff stat " .. def.buff.stat)
			end
		end
		T.eq(Config.get("shrine_swift").buff.duration, 45)
		T.eq(Config.get("shrine_might").buff.mul, 1.25)
		T.eq(Config.get("cheese_cache").channel, 3)
	end)
	T.it("reward maths scale with stage and cycle", function()
		T.eq(Config.cacheCheese("cheese_cache", 1, 1), 20)
		T.eq(Config.cacheCheese("cheese_cache", 1, 4), 35)
		T.eq(Config.cacheCheese("cheese_cache", 2, 1), 30)
		T.eq(Config.cacheCheese("sunken_chest", 1, 1), 60, "landmarks pay x3")
		T.truthy(Config.fountainXp(1, 3) > Config.fountainXp(1, 1))
		T.eq(Config.campPack(1, 1), 3)
		T.eq(Config.campPack(1, 4), 5)
		T.truthy(Config.campPack(9, 4) <= Config.CAMP_PACK_MAX)
	end)
end)

T.describe("Combat.Pois rolls and layout", function()
	T.it("rollStage is deterministic and fills every slot", function()
		local a = Pois.rollStage(Rng.new(5), "volcano")
		local b = Pois.rollStage(Rng.new(5), "volcano")
		T.deepEq(a, b)
		T.eq(#a, (Maps.get("volcano") :: any).poiSlots)
	end)
	T.it("rare POIs: ~3% Pantry and ~2% Statue per stage, never both", function()
		local N = 20000
		local pantry, statue, both = 0, 0, 0
		local rng = Rng.new(2026)
		for i = 1, N do
			local ids = Pois.rollStage(rng, Maps.ORDER[(i % #Maps.ORDER) + 1])
			local p = table.find(ids, "grandmas_pantry") ~= nil
			local s = table.find(ids, "lost_herd_statue") ~= nil
			pantry += if p then 1 else 0
			statue += if s then 1 else 0
			both += if p and s then 1 else 0
		end
		print(
			string.format(
				"  [rare] pantry %.2f%%  statue %.2f%% over %d stages",
				pantry / N * 100,
				statue / N * 100,
				N
			)
		)
		T.near(pantry / N, 0.03, 0.006, "pantry rate")
		T.near(statue / N, 0.02, 0.005, "statue rate")
		T.eq(both, 0)
	end)
	T.it("rare rates hold across many run seeds (one stage each)", function()
		local hits = 0
		for seed = 1, 5000 do
			for _, id in Pois.rollStage(Rng.new(seed):fork(0x9017), "plains") do
				if id == "grandmas_pantry" or id == "lost_herd_statue" then
					hits += 1
				end
			end
		end
		T.near(hits / 5000, 0.05, 0.012, "rare share per stage")
	end)
	T.it("layout: one entry per slot on the ring between the pad and the rim", function()
		for _, mapId in Maps.ORDER do
			local R = Pois.arenaRadius(mapId)
			local list = Pois.layout(Rng.new(9), mapId)
			T.eq(#list, (Maps.get(mapId) :: any).poiSlots)
			for i, e in list do
				T.eq(e.slot, i)
				local d = math.sqrt(e.x * e.x + e.z * e.z)
				T.truthy(d >= R * 0.55 - 1e-6 and d <= R * 0.8 + 1e-6, mapId .. " ring " .. d)
				T.truthy(e.r > 0)
			end
		end
		T.deepEq(Pois.layout(Rng.new(3), "moon"), Pois.layout(Rng.new(3), "moon"))
	end)
end)

T.describe("Combat.Pois channel maths", function()
	T.it("several heroes channel faster, capped", function()
		T.eq(Pois.channelRate(0), 0)
		T.eq(Pois.channelRate(1), 1)
		T.eq(Pois.channelRate(2), 1.5)
		T.eq(Pois.channelRate(4), Config.MULTI_USER_MAX)
	end)
	T.it("advance: fills, holds while interrupted, decays when empty", function()
		T.near(Pois.advance(0, 3, 1, 1, 1), 1 / 3, 1e-9)
		T.near(Pois.advance(0.5, 3, 0, 1, 1), 0.5, 1e-9, "hurt hero in range: hold")
		T.near(Pois.advance(0.5, 3, 0, 0, 1), 0.5 - Config.DECAY_RATE, 1e-9, "empty: decay")
		T.eq(Pois.advance(0.1, 3, 0, 0, 10), 0)
		T.eq(Pois.advance(0.9, 3, 2, 2, 5), 1)
	end)
end)

T.describe("Combat.World POIs", function()
	T.it("addPoi emits a JSON-safe state Fx; pois() returns copies", function()
		local w = newWorld(1)
		local id = w:addPoi({ kind = "cheese_cache", x = 40, z = 0 })
		local fx = run(w, DT)
		local f = fxOf(fx, "poi")[1]
		T.truthy(f ~= nil)
		T.eq(f.id, id)
		T.eq(f.kind, "cheese_cache")
		T.eq(f.r, Config.get("cheese_cache").radius)
		T.truthy(jsonSafe(f))
		local copy = poiOf(w, id)
		copy.state = "done"
		T.eq(poiOf(w, id).state, "idle", "copies, not the live entity")
	end)
	T.it("is inactive outside the waves", function()
		local w = newWorld(2)
		addHero(w, 1, 40, 0)
		local id = w:addPoi({ kind = "cheese_cache", x = 40, z = 0 })
		run(w, 5)
		T.eq(poiOf(w, id).progress, 0, "no progress before the waves")
		T.eq(poiOf(w, id).active, false)
		w:startWaves(60)
		run(w, 1)
		T.truthy(poiOf(w, id).progress > 0)
		T.eq(poiOf(w, id).active, true)
		w:stopSpawning()
		local p = poiOf(w, id).progress
		local fx = run(w, 3)
		T.eq(poiOf(w, id).progress, p, "frozen once the waves stop")
		T.eq(poiOf(w, id).state ~= "done", true)
		local last = fxOf(fx, "poi")
		T.truthy(#last >= 1 and last[1].active == false, "clients are told it went dark")
	end)
	T.it("a cache completes after 3 s, rewards once, reports progress in 10% steps", function()
		local w = newWorld(3, { cycle = 1, stage = 2 })
		addHero(w, 1, 40, 0)
		local id = w:addPoi({ kind = "cheese_cache", x = 40, z = 0 })
		w:startWaves(60)
		local fx = run(w, 2.9)
		T.truthy(poiOf(w, id).state ~= "done", "not before 3 s")
		fx = run(w, 0.2)
		T.eq(poiOf(w, id).state, "done")
		local evs = w:drainEvents()
		local prog = eventsOf(evs, "poiProgress")
		T.truthy(#prog >= 9, "progress steps " .. #prog)
		local act = eventsOf(evs, "poiActivated")
		T.eq(#act, 1)
		T.eq(act[1].kind, "cheese_cache")
		T.eq(act[1].by, 1)
		T.eq(act[1].poi, id)
		T.eq(act[1].x, 40)
		local rew = eventsOf(evs, "poiReward")
		T.eq(#rew, 1)
		T.eq(rew[1].cheese, Config.cacheCheese("cheese_cache", 1, 2))
		T.deepEq(rew[1].ids, { 1 })
		local done = fxOf(fx, "poiDone")
		T.eq(#done, 1)
		T.truthy(jsonSafe(done[1]))
		run(w, 10)
		T.eq(#eventsOf(w:drainEvents(), "poiReward"), 0, "never twice")
	end)
	T.it("two heroes channel 1.5x faster; usedBy lists both", function()
		local w = newWorld(4)
		addHero(w, 1, 40, 0)
		addHero(w, -1001, 41, 1)
		local id = w:addPoi({ kind = "cheese_cache", x = 40, z = 0 })
		w:startWaves(60)
		run(w, 2.1)
		T.eq(poiOf(w, id).state, "done", "3 s / 1.5 = 2 s")
		local used = poiOf(w, id).usedBy
		table.sort(used)
		T.deepEq(used, { -1001, 1 })
	end)
	T.it("leaving decays progress; damage pauses the channel", function()
		local w = newWorld(5)
		addHero(w, 1, 40, 0)
		local id = w:addPoi({ kind = "cheese_cache", x = 40, z = 0 })
		w:startWaves(60)
		run(w, 1.5)
		local mid = poiOf(w, id).progress
		T.near(mid, 0.5, 0.03)
		w:setPlayerPosition(1, 0, 0)
		run(w, 1)
		T.near(poiOf(w, id).progress, mid - Config.DECAY_RATE, 0.03, "decays while empty")
		w:setPlayerPosition(1, 40, 0)
		run(w, 0.1)
		local before = poiOf(w, id).progress
		-- a hit: the channel holds for HURT_PAUSE
		local p = w.players[1]
		p.iframeUntil = 0
		w:damagePlayer(p, 5, "test")
		run(w, Config.HURT_PAUSE * 0.8)
		T.near(poiOf(w, id).progress, before, 0.02, "interrupted")
		run(w, 1)
		T.truthy(poiOf(w, id).progress > before + 0.2, "resumes")
	end)
	T.it("downed heroes do not channel", function()
		local w = newWorld(6)
		addHero(w, 1, 40, 0)
		local id = w:addPoi({ kind = "shrine_might", x = 40, z = 0 })
		local p = w.players[1]
		w:damagePlayer(p, 1e9, "test")
		w:startWaves(60)
		run(w, 3)
		T.eq(poiOf(w, id).progress, 0)
	end)
	T.it("shrines: a timed party buff payload; Mending heals the party", function()
		local w = newWorld(7)
		addHero(w, 1, 40, 0)
		addHero(w, 2, -40, 0)
		w.players[2].hp = 10
		w:addPoi({ kind = "shrine_mending", x = 40, z = 0 })
		w:startWaves(60)
		local fx = run(w, 1.2)
		local rew = eventsOf(w:drainEvents(), "poiReward")
		T.eq(#rew, 1)
		local b = rew[1].buff
		T.eq(b.kind, "shrine_mending")
		T.eq(b.stat, "regen")
		T.eq(b.duration, 45)
		T.near(b.untilT, w.now + 45, 1.2)
		T.near(w.players[2].hp, 10 + 0.3 * w.players[2].maxHp, 1, "far hero healed too")
		local done = fxOf(fx, "poiDone")[1]
		T.eq(done.dur, 45)
	end)
	T.it("Crumb Fountain bursts XP crumbs", function()
		local w = newWorld(8)
		addHero(w, 1, 40, 0)
		w:addPoi({ kind = "crumb_fountain", x = 40, z = 0 })
		w:startWaves(60)
		run(w, 2.2)
		local total = 0
		for _, c in w.pickups do
			total += c.xp
		end
		for _, e in eventsOf(w:drainEvents(), "xp") do
			total += e.amount
		end
		T.near(total, Config.fountainXp(1, 1), 1e-6, "every crumb of the burst is on the floor or picked up")
	end)
	T.it("Lost Herd Statue revives everyone and refills Second Wind", function()
		local w = newWorld(9)
		addHero(w, 1, 40, 0)
		addHero(w, -1001, -40, 0)
		addHero(w, 2, -45, 0)
		w:startWaves(60)
		w.players[-1001].iframeUntil = 0
		w:damagePlayer(w.players[-1001], 1e9, "test")
		w.players[2].secondWindUsed = true
		w.players[2].iframeUntil = 0
		w:damagePlayer(w.players[2], 1e9, "test")
		w.players[2].downedUntil = w.now -- bleeds out next step: a spectator
		run(w, 0.1)
		T.eq(w:getPlayer(2).dead, true)
		w:addPoi({ kind = "lost_herd_statue", x = 40, z = 0 })
		run(w, 3.2)
		T.eq(w:getPlayer(-1001).downed, false)
		T.eq(w:getPlayer(2).dead, false)
		T.eq(w:getPlayer(2).secondWindUsed, false)
		local rew = eventsOf(w:drainEvents(), "poiReward")
		T.eq(#rew, 1)
		T.eq(rew[1].revived, 2)
	end)
	T.it("Grandma's Pantry reward asks for an Epic pick", function()
		local w = newWorld(10)
		addHero(w, 1, 40, 0)
		w:addPoi({ kind = "grandmas_pantry", x = 40, z = 0 })
		w:startWaves(60)
		run(w, 3.2)
		local rew = eventsOf(w:drainEvents(), "poiReward")
		T.eq(#rew, 1)
		T.eq(rew[1].cards, Config.EPIC_CARDS)
	end)
end)

T.describe("Combat.World Elite Camp", function()
	T.it("wakes an elite pack; clearing it opens the chest once", function()
		local w = newWorld(11, { stage = 2 })
		addHero(w, 1, 0, 0)
		local id = w:addPoi({ kind = "elite_camp", x = 40, z = 0 })
		w:startWaves(60)
		run(w, 0.5)
		T.eq(w:enemyCount(), 0, "asleep until someone walks in")
		w:setPlayerPosition(1, 40, 0)
		run(w, DT)
		local n = Config.campPack(1, 2)
		T.eq(w:enemyCount(), n, "the pack ignores the wave cap")
		T.eq(poiOf(w, id).state, "active")
		T.eq(poiOf(w, id).pack, n)
		local evs = w:drainEvents()
		T.eq(#eventsOf(evs, "poiActivated"), 1)
		for _, e in w.enemies do
			T.eq(e.elite, true)
			T.eq(e.poiId, id)
		end
		-- kill all but one: no chest yet
		local list = table.clone(w.enemies)
		for i = 1, #list - 1 do
			w:damageEnemy(list[i], 1e9, w.players[1])
		end
		run(w, DT)
		T.eq(#eventsOf(w:drainEvents(), "poiReward"), 0)
		w:damageEnemy(list[#list], 1e9, nil) -- any killer counts
		local fx = run(w, DT)
		local rew = eventsOf(w:drainEvents(), "poiReward")
		T.eq(#rew, 1)
		T.eq(rew[1].kind, "elite_camp")
		T.eq(rew[1].by, 1)
		T.deepEq(rew[1].ids, { 1 })
		T.eq(poiOf(w, id).state, "done")
		T.eq(fxOf(fx, "poiDone")[1].chest, true)
		run(w, 2)
		T.eq(#eventsOf(w:drainEvents(), "poiReward"), 0, "once")
	end)
	T.it("a pack wiped by clearEnemies (boss start) never opens the chest", function()
		local w = newWorld(12)
		addHero(w, 1, 40, 0)
		w:addPoi({ kind = "elite_camp", x = 40, z = 0 })
		w:startWaves(60)
		run(w, DT)
		T.truthy(w:enemyCount() > 0)
		w:stopSpawning()
		w:clearEnemies()
		run(w, 1)
		T.eq(#eventsOf(w:drainEvents(), "poiReward"), 0)
	end)
end)

T.describe("Combat.World Mousetrap Field", function()
	T.it("snaps mice AND heroes after a telegraph", function()
		local w = newWorld(13)
		addHero(w, 1, -60, 0)
		local id = w:addPoi({ kind = "mousetrap_field", x = 40, z = 0 })
		local trap = w.poiById[id].traps[1] -- the centre trap
		T.eq(trap.x, 40)
		w:startWaves(60)
		run(w, DT)
		w.cap = 10
		local e = w:spawnEnemy("chonk", 40, 0, false)
		w.cap = 0
		e.speed = 0 -- stays on the trap (real mice may walk off in time)
		e.contact = 0 -- only the trap hurts the hero here
		local hp0 = e.hp
		local fx = run(w, DT * 2)
		local teles = {}
		for _, f in fx do
			if f.t == "tele" and f.style == "trap" then
				table.insert(teles, f)
			end
		end
		T.truthy(#teles >= 1, "telegraph first")
		T.truthy(teles[1].delay >= 0.6, "fair warning")
		T.eq(e.hp, hp0, "no damage during the telegraph")
		-- a hero walks in during the telegraph
		w:setPlayerPosition(1, 40.5, 0)
		local hpHero = w.players[1].hp
		fx = run(w, Config.TRAP_DELAY + 0.1)
		T.truthy(not e.alive or e.hp < hp0, "the mouse got snapped")
		T.truthy(w.players[1].hp < hpHero, "so did the hero")
		T.truthy(#fxOf(fx, "trap") >= 1)
		local dmg = eventsOf(w:drainEvents(), "damaged")
		local trapHits = 0
		for _, d in dmg do
			if d.kind == "trap" then
				trapHits += 1
			end
		end
		T.truthy(trapHits >= 1)
	end)
	T.it("a sprung trap rearms; nothing happens outside the waves", function()
		local w = newWorld(14)
		addHero(w, 1, 40, 0)
		local id = w:addPoi({ kind = "mousetrap_field", x = 40, z = 0 })
		w:startWaves(60)
		local fx = run(w, Config.TRAP_DELAY + 0.2)
		T.eq(#fxOf(fx, "trap"), 1)
		fx = run(w, Config.TRAP_REARM * 0.5)
		T.eq(#fxOf(fx, "trap"), 0, "rearming")
		fx = run(w, Config.TRAP_REARM + Config.TRAP_DELAY + 0.5)
		T.truthy(#fxOf(fx, "trap") >= 1, "snaps again")
		w:stopSpawning()
		local hp = w.players[1].hp
		fx = run(w, 6)
		T.eq(#fxOf(fx, "trap"), 0)
		T.truthy(w.players[1].hp >= hp)
		T.eq(poiOf(w, id).active, false)
	end)
end)

T.describe("Combat.Pois buffs and epic cards", function()
	T.it("applyBuffs multiplies / adds, ignores expired and same-kind repeats", function()
		local s = table.clone(Stats.DEFAULT) :: any
		s.maxHp = 200
		local buffs = {
			{ kind = "shrine_swift", stat = "moveSpeed", mul = 1.25, untilT = 100 },
			{ kind = "shrine_swift", stat = "moveSpeed", mul = 1.25, untilT = 100 },
			{ kind = "shrine_mending", stat = "regen", addFracMaxHp = 0.005, untilT = 100 },
			{ kind = "shrine_might", stat = "damageMult", mul = 1.25, untilT = 10 },
		}
		local out = Pois.applyBuffs(s, buffs :: any, 50) :: any
		T.near(out.moveSpeed, s.moveSpeed * 1.25, 1e-9)
		T.near(out.regen, s.regen + 1, 1e-9)
		T.eq(out.damageMult, s.damageMult, "expired")
		T.eq((s :: any).moveSpeed, Stats.DEFAULT.moveSpeed, "input untouched")
	end)
	T.it("addBuff refreshes; pruneBuffs drops expired", function()
		local buffs: { any } = {}
		Pois.addBuff(buffs, { kind = "shrine_swift", stat = "moveSpeed", mul = 1.25, untilT = 45 }, 0)
		Pois.addBuff(buffs, { kind = "shrine_swift", stat = "moveSpeed", mul = 1.25, untilT = 60 }, 10)
		T.eq(#buffs, 1)
		T.eq(buffs[1].untilT, 60)
		T.eq(Pois.pruneBuffs(buffs, 59), false)
		T.eq(Pois.pruneBuffs(buffs, 60), true)
		T.eq(#buffs, 0)
	end)
	T.it("epicCards: unique Epic cards the class can take", function()
		local cards = Pois.epicCards(Rng.new(1), "elephante", {}, 3)
		T.eq(#cards, 3)
		local seen = {}
		for _, c in cards do
			T.eq(c.rarity, "Epic")
			T.falsy(seen[c.id])
			seen[c.id] = true
			T.truthy(c.classOnly == nil or c.classOnly == "elephante")
		end
	end)
end)

T.describe("Combat.World portal", function()
	T.it("setPortal emits JSON-safe Fx and keeps state until close", function()
		local w = newWorld(15)
		w:setPortal(0, 0, "open", { 255, 204, 51 })
		T.eq(w:portal().phase, "open")
		w:setPortal(0, 0, "pull", { 60, 170, 220 })
		T.eq(w:portal().phase, "pull")
		T.deepEq(w:portal().color, { 60, 170, 220 })
		w:setPortal(0, 0, "close")
		T.eq(w:portal(), nil)
		local fx = fxOf(run(w, DT), "portal")
		T.eq(#fx, 3)
		T.eq(fx[1].phase, "open")
		T.eq(fx[2].phase, "pull")
		T.eq(fx[3].phase, "close")
		for _, f in fx do
			T.truthy(jsonSafe(f))
		end
	end)
end)

T.describe("BotBrain › POIs and the portal (via the view)", function()
	local function view(extra: { [string]: any }): any
		local v: any = {
			self = { x = 0, z = 0, hp = 100, maxHp = 100, downed = false, abilityReady = false },
			allies = { { id = 1, x = 2, z = 0, downed = false, isBot = false } },
			enemies = {},
			pickups = {},
			arenaRadius = 120,
			obstacles = {},
			now = 10,
		}
		for k, x in extra do
			v[k] = x
		end
		return v
	end
	local function cache(x: number, z: number, extra: { [string]: any }?): any
		local p: any = {
			id = 1,
			kind = "cheese_cache",
			x = x,
			z = z,
			r = 6,
			state = "idle",
			progress = 0,
			active = true,
			mode = "channel",
		}
		for k, v in extra or {} do
			p[k] = v
		end
		return p
	end
	local function brain(): any
		return BotBrain.new(-1001, "ele_fonte", Rng.new(1))
	end
	T.it("walks to a safe, live cache near the party", function()
		local it = brain():think(view({ pois = { cache(30, 0) } }), 0.1)
		T.truthy(it.moveX > 0.8, "heads for it " .. it.moveX)
	end)
	T.it("ignores done, sleeping or far-away POIs", function()
		for _, p in { cache(30, 0, { state = "done" }), cache(30, 0, { active = false }), cache(80, 0) } do
			local it = brain():think(view({ pois = { p } }), 0.1)
			T.truthy(it.moveX < 0.6, "not drawn to it")
		end
	end)
	T.it("skips a POI swarmed by mice; stays in one it has nearly finished", function()
		local mice = {}
		for i = 1, 8 do
			table.insert(mice, { id = i, kind = 1, x = 30 + (i % 3), z = (i % 2), hpFrac = 1, flags = 0 })
		end
		local it = brain():think(view({ pois = { cache(30, 0) }, enemies = mice }), 0.1)
		T.truthy(it.moveX < 0.6, "unsafe")
		local v = view({ pois = { cache(30, 0, { progress = 0.8 }) }, enemies = mice })
		v.self.x = 28
		v.allies[1].x = 20
		local p = brain():_poiTarget(v, 1, mice, v.allies)
		T.truthy(p ~= nil, "committed")
	end)
	T.it("the statue only when someone is down", function()
		local statue = cache(30, 0, { kind = "lost_herd_statue" })
		local v = view({ pois = { statue } })
		T.eq(brain():_poiTarget(v, 1, {}, v.allies), nil)
		table.insert(v.allies, { id = 2, x = -5, z = 0, downed = true, isBot = false })
		T.truthy(brain():_poiTarget(v, 1, {}, v.allies) ~= nil)
	end)
	T.it("keeps out of a Mousetrap Field", function()
		local field = {
			id = 2,
			kind = "mousetrap_field",
			x = 3,
			z = 0,
			r = 12,
			state = "idle",
			active = true,
			mode = "hazard",
		}
		local v = view({ pois = { field } })
		v.allies[1].x = -2
		local it = brain():think(v, 0.1)
		T.truthy(it.moveX < 0, "pushed out " .. it.moveX)
	end)
	T.it("walks into the portal on pull", function()
		local it = brain():think(view({ portal = { x = 0, z = 40, phase = "pull" } }), 0.1)
		T.near(it.moveZ, 1, 1e-6)
		T.eq(it.speedFrac, 1)
	end)
end)

T.describe("FxFilter › POI and portal events", function()
	T.it("POI state and the portal always reach every client; trap snaps are culled far away", function()
		T.truthy(FxFilter.relevant({ t = "poi", id = 1, x = 500, z = 0 }, 0, 0, 100))
		T.truthy(FxFilter.relevant({ t = "poiDone", id = 1, x = 500, z = 0 }, 0, 0, 100))
		T.truthy(FxFilter.relevant({ t = "poiProgress", id = 1, p = 0.5 }, 0, 0, 100))
		T.truthy(FxFilter.relevant({ t = "portal", x = 500, z = 0, phase = "pull" }, 0, 0, 100))
		T.falsy(FxFilter.relevant({ t = "trap", id = 1, x = 500, z = 0, r = 3 }, 0, 0, 100))
		T.truthy(FxFilter.relevant({ t = "trap", id = 1, x = 50, z = 0, r = 3 }, 0, 0, 100))
	end)
end)

return T.finish()
