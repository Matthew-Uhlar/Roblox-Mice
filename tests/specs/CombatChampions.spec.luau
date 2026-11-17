--!strict
-- v3 Mouse Champions (docs/GDD-v2.md §4b, Config/Champions, Combat/Champions):
-- ids and snapshot kinds, the director (sites, timing, caps, lairs), the
-- leash / aggro AI, the per-champion mechanics (shield, rally, split, evade,
-- chain lightning), the squad reward and its events / Fx, the stacking buff,
-- the big-map layout (sites and lairs) and the out-of-combat sprint.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local BossPatterns = require("../../src/shared/Combat/BossPatterns")
local SnapshotCodec = require("../../src/shared/Combat/SnapshotCodec")
local FxFilter = require("../../src/shared/Combat/FxFilter")
local Champions = require("../../src/shared/Combat/Champions")
local Config = require("../../src/shared/Config/Champions")
local Pois = require("../../src/shared/Combat/Pois")
local PoiDefs = require("../../src/shared/Config/Pois")
local Maps = require("../../src/shared/Config/Maps")

local DT = 1 / 30

-- A big world with two squads of heroes; `sites` = champion site specs for addPoi.
local function world(seed: number, opts: { [string]: any }?): any
	local o = opts or {}
	local w = World.new({
		rng = Rng.new(seed),
		mods = Defaults.mods(),
		arenaRadius = o.radius or 350,
		enemyPool = { "mouse" },
		enemyCap = o.cap or 0,
		stage = o.stage or 1,
		carriers = false,
	})
	for _, s in o.sites or {} do
		w:addPoi(s)
	end
	return w
end

local function hero(w: any, id: number, x: number, z: number, squad: number, dmg: number?)
	local weapon = Defaults.weapon("bolt")
	weapon.damage = dmg or 0
	w:addPlayer(id, Defaults.stats({ maxHp = 1e7 }), weapon, Defaults.ability("burst"), x, z, squad)
end

local function stepFor(w: any, seconds: number, onFx: ((any) -> ())?, onEv: ((any) -> ())?)
	local t = w.now
	for _ = 1, math.floor(seconds / DT + 0.5) do
		t += DT
		local fx = w:step(DT, t)
		if onFx then
			for _, f in fx do
				onFx(f)
			end
		end
		local ev = w:drainEvents()
		if onEv then
			for _, e in ev do
				onEv(e)
			end
		end
	end
end

T.describe("Config.Champions", function()
	T.it("has exactly the 6 contract ids, in order, with kinds 101..106", function()
		T.deepEq(Config.ORDER, {
			"champ_captain",
			"champ_golem",
			"champ_ratking",
			"champ_sniper",
			"champ_chemist",
			"champ_thunder",
		})
		for i, id in Config.ORDER do
			T.eq(Config.kindOf(id), 100 + i)
			T.eq(Config.idOfKind(100 + i), id)
			T.eq(SnapshotCodec.kindClass(100 + i), "champion")
		end
		T.eq(SnapshotCodec.kindClass(5), "mouse")
		T.eq(SnapshotCodec.kindClass(201), "boss")
	end)

	T.it("every champion has 2-3 attacks (BossPatterns) and a buff", function()
		for _, id in Config.ORDER do
			local def = Config.get(id) :: any
			T.truthy(def.hp > 0 and def.speed > 0 and def.radius > 0, id)
			local distinct = {}
			for _, list in { def.patterns, def.phase2Patterns } do
				for _, p in list do
					T.truthy(BossPatterns.has(p), id .. " pattern " .. p)
					distinct[p] = true
				end
			end
			local n = 0
			for _ in distinct do
				n += 1
			end
			T.truthy(n >= 2, id .. " has at least 2 attacks")
			T.truthy(def.buff and def.buff.mul > 1 and def.buff.duration > 0, id .. " buff")
		end
		T.truthy(BossPatterns.has("sniper_evade"))
		T.truthy(BossPatterns.has("chemist_lob_small"))
	end)

	T.it("rewards grow with the stage; lairs pay more and drop better gear", function()
		for s = 2, 4 do
			T.truthy(Config.xpReward(s) > Config.xpReward(s - 1))
			T.truthy(Config.cheeseReward(s) > Config.cheeseReward(s - 1))
		end
		T.truthy(Config.xpReward(1, true) > Config.xpReward(1))
		T.eq(Config.gearRarity(1), "Rare")
		T.eq(Config.gearRarity(3), "Epic")
		T.eq(Config.gearRarity(1, true), "Epic")
		T.eq(Config.gearRarity(3, true), "Legendary")
		T.eq(Config.maxAlive(350), 3)
		T.eq(Config.maxAlive(140), 2)
		T.eq(Config.maxAlive(350, 1), Config.MAX_ALIVE_STAGE1)
		T.eq(Config.maxAlive(350, 2), 3)
		-- v4: HP follows the average hero level (no level data: x1)
		T.eq(Config.levelHpMult(nil), 1)
		T.eq(Config.levelHpMult(Config.LEVEL_HP_REF), 1)
		T.eq(Config.levelHpMult(1), Config.LEVEL_HP_MIN)
		T.truthy(Config.levelHpMult(20) > 1.3)
		T.eq(Config.levelHpMult(99), Config.LEVEL_HP_MAX)
	end)
end)

T.describe("Combat.Champions › director", function()
	local function sites(n: number, lairs: number?): { any }
		local out = {}
		for k = 1, n do
			local a = k / n * math.pi * 2
			table.insert(out, { kind = "champion_site", x = math.cos(a) * 150, z = math.sin(a) * 150 })
		end
		for k = 1, lairs or 0 do
			table.insert(out, { kind = "champion_lair", x = 70 * (if k == 1 then 1 else -1), z = 0 })
		end
		return out
	end

	T.it("no sites, no champions (v1 worlds and tests stay unchanged)", function()
		local w = world(1)
		hero(w, 1, 0, 0, 1)
		w:startWaves(150)
		stepFor(w, 80)
		T.eq(#w:champions(), 0)
	end)

	T.it("the first champion comes FIRST s into the waves, then every 30-40 s, at most 3 alive", function()
		local w = world(2, { sites = sites(6) })
		hero(w, 1, 0, 300, 1) -- far from every site: nobody fights them
		w:setStage(1, 2) -- v4: stage 1 allows only MAX_ALIVE_STAGE1
		w:startWaves(150)
		local spawns: { number } = {}
		local maxAlive = 0
		stepFor(w, 150, nil, function(e)
			if e.type == "championSpawn" then
				table.insert(spawns, w.wave.elapsed)
			end
		end)
		maxAlive = #w:champions()
		T.truthy(#spawns >= 3, "spawned " .. #spawns)
		T.truthy(
			spawns[1] >= Config.FIRST[1] - 1e-6 and spawns[1] <= Config.FIRST[2] + DT,
			"first at " .. spawns[1]
		)
		T.truthy(spawns[2] - spawns[1] >= 30 - 1e-6 and spawns[2] - spawns[1] <= 40 + DT, "interval")
		T.truthy(maxAlive <= Config.MAX_ALIVE, "cap")
		for _, t in spawns do
			T.truthy(t <= 150 - Config.CUTOFF + DT, "no spawn in the last CUTOFF s")
		end
	end)

	T.it("each lair wakes one tougher champion a stage; the boss start makes everyone leave", function()
		local w = world(3, { sites = sites(6, 1) })
		hero(w, 1, 0, 300, 1)
		w:startWaves(150)
		local lairs, fx = 0, {}
		stepFor(w, 125, function(f)
			if f.t == "champ" then
				table.insert(fx, f)
			end
		end, function(e)
			if e.type == "championSpawn" and e.lair then
				lairs += 1
			end
		end)
		T.eq(lairs, 1)
		local alive = #w:champions()
		T.truthy(alive >= 1)
		local lair = nil
		for _, c in w:champions() do
			if c.lair then
				lair = c
			end
		end
		T.truthy(lair ~= nil, "the lair champion is alive")
		local body = w.enemyById[lair.id]
		local def = Config.get(lair.champId) :: any
		T.truthy(body.r > def.radius, "lair champions are bigger")
		local snap = nil
		for _, s in w:snapshot() do
			if s.id == lair.id then
				snap = s
			end
		end
		T.truthy(
			snap and snap.kind == Config.kindOf(lair.champId) and SnapshotCodec.sizeStep(snap.flags) >= 1
		)
		w:stopSpawning()
		local escaped = 0
		w:clearEnemies()
		for _, f in w:step(DT, w.now + DT) do
			if f.t == "champ" and f.phase == "dead" and f.escaped then
				escaped += 1
			end
		end
		T.eq(escaped, alive, "every champion leaves when the boss comes")
		T.eq(#w:champions(), 0)
		for _, f in fx do
			T.truthy(f.id and f.champId and f.x and f.z and f.phase, "champ Fx shape")
		end
	end)

	T.it("short waves scale the timings down (so a 20 s test wave still sees champions)", function()
		local w = world(4, { sites = sites(6) })
		hero(w, 1, 0, 300, 1)
		w:startWaves(30)
		stepFor(w, 30)
		T.truthy(Champions.timeScale(w) < 1)
		T.truthy(w.champ.spawned >= 1)
	end)

	T.it("champions are always in the client snapshot and their Fx are always sent", function()
		local snaps = { { id = 1, kind = 101, x = 900, z = 0, hpFrac = 1, flags = 0 } }
		T.eq(#FxFilter.snapshotForViewer(snaps, 0, 0), 1)
		local fx = { { t = "champ", id = 1, champId = "champ_golem", x = 900, z = 0, phase = "spawn" } }
		T.eq(#FxFilter.forViewer(fx, 0, 0), 1)
		T.truthy(table.find(FxFilter.ALWAYS, "champ") ~= nil)
	end)
end)

T.describe("Combat.Champions › fights and rewards", function()
	T.it("leash and aggro: it ignores heroes far from its site and never shoots across the map", function()
		local w = world(5)
		hero(w, 1, 0, 120, 1)
		w:step(DT, DT)
		local c = w:spawnChampion("champ_sniper", 0, 0)
		local hits = 0
		stepFor(w, 20, nil, function(e)
			if e.type == "damaged" then
				hits += 1
			end
		end)
		T.eq(hits, 0, "a hero 120 studs away is never attacked")
		T.truthy(c.target == nil)
		T.truthy(math.sqrt(c.x ^ 2 + c.z ^ 2) <= 4, "stays home")
	end)

	T.it(
		"the killing blow's squad gets gear, xp, cheese and the buff; Fx and events are well-formed",
		function()
			local w = world(6, { stage = 3 })
			hero(w, 1, 0, 14, 1, 400)
			hero(w, 2, 3, 14, 1, 0)
			hero(w, 3, 0, -60, 2, 0) -- squad 2, far away
			w:step(DT, DT)
			local c = w:spawnChampion("champ_golem", 0, 0)
			local dead, xp, gear, fxDead = nil, {}, {}, nil
			stepFor(w, 60, function(f)
				if f.t == "champ" and f.phase == "dead" then
					fxDead = f
				end
			end, function(e)
				if e.type == "championDead" then
					dead = e
				elseif e.type == "xp" then
					xp[e.id] = (xp[e.id] or 0) + e.amount
				elseif e.type == "gearPickup" then
					gear[e.id] = e.item
				end
			end)
			T.falsy(c.alive, "killed")
			T.truthy(dead ~= nil, "championDead")
			T.eq(dead.squad, 1)
			T.eq(dead.killerSquad, 1)
			T.eq(dead.champId, "champ_golem")
			T.eq(dead.cheese, Config.cheeseReward(3))
			T.eq(dead.xp, Config.xpReward(3))
			T.truthy(dead.buff and dead.buff.kind == "champ_might" and dead.buff.untilT > w.now - 60)
			T.truthy(dead.damageBySquad[1] > 0)
			T.truthy(dead.id == nil and dead.champ == c.id, "entity id in `champ`, never `id`")
			T.truthy((xp[1] or 0) >= Config.xpReward(3) and (xp[2] or 0) >= Config.xpReward(3), "xp burst")
			T.eq(xp[3], nil, "the other squad gets nothing")
			for _, id in { 1, 2 } do
				T.truthy(gear[id] ~= nil, "gear for member " .. id)
				T.truthy(gear[id].rarity == "Epic" or gear[id].rarity == "Legendary", "Epic+ at stage 3")
			end
			T.truthy(fxDead and fxDead.squad == 1 and fxDead.id == c.id)
		end
	)

	T.it("with no hero killer the top-damage squad is rewarded", function()
		local w = world(7)
		hero(w, 1, 0, 14, 1, 50)
		w:step(DT, DT)
		local c = w:spawnChampion("champ_captain", 0, 0)
		stepFor(w, 3)
		T.truthy(c.hp < c.maxHp)
		local dead = nil
		w:_killEnemy(c, nil)
		for _, e in w:drainEvents() do
			if e.type == "championDead" then
				dead = e
			end
		end
		T.eq(dead.squad, 1)
		T.eq(dead.killerSquad, nil)
	end)

	T.it("HP scales with bossHpMult and the wave clock; lairs are tougher", function()
		local w = world(8)
		w.mods.bossHpMult = 2
		local a = w:spawnChampion("champ_thunder", 50, 0)
		local b = w:spawnChampion("champ_thunder", -50, 0, true)
		local def = Config.get("champ_thunder") :: any
		T.near(a.maxHp, def.hp * 2 * Config.HP_SCALE, 1e-6)
		T.near(b.maxHp, a.maxHp * Config.LAIR_HP_MULT, 1e-6)
		w:startWaves(100)
		w.wave.elapsed = 50
		local c = w:spawnChampion("champ_thunder", 0, 50)
		T.near(c.maxHp, a.maxHp * (1 + Config.HP_WAVE_GROWTH * 0.5), 1e-6)
	end)

	T.it("Mad Chemist enrages at 50% and splits into 2 clones that die with it", function()
		local w = world(9)
		hero(w, 1, 0, 14, 1)
		w:step(DT, DT)
		local c = w:spawnChampion("champ_chemist", 0, 0)
		local enraged = false
		stepFor(w, 2)
		w:damageEnemy(c, c.maxHp * 0.55, w.players[1])
		for _, f in w:step(DT, w.now + DT) do
			if f.t == "champ" and f.phase == "enrage" then
				enraged = true
			end
		end
		T.truthy(enraged and c.enraged)
		local clones = {}
		for _, e in w.enemies do
			if e.alive and e.champOf == c then
				table.insert(clones, e)
			end
		end
		T.eq(#clones, Config.CLONES)
		local flagged = 0
		for _, s in w:snapshot() do
			if s.kind == Config.kindOf("champ_chemist") and math.floor(s.flags / 8) % 2 == 1 then
				flagged += 1
			end
		end
		T.eq(flagged, Config.CLONES, "clones carry flag bit 3")
		T.eq(#w:champions(), 1, "clones are not listed as champions")
		w:damageEnemy(c, c.hp + 1, w.players[1])
		for _, k in clones do
			T.falsy(k.alive)
		end
	end)

	T.it("Captain Whiskers' shield cuts damage; his rally speeds up nearby mice", function()
		local w = world(10, { cap = 50 })
		hero(w, 1, 0, 14, 1)
		w:step(DT, DT)
		local c = w:spawnChampion("champ_captain", 0, 0)
		stepFor(w, 2)
		c.shieldUntil = w.now + 5
		local dealt = w:damageEnemy(c, 100, w.players[1])
		T.near(dealt, 100 * Config.SHIELD_MULT, 1e-6)
		local m = w:spawnEnemy("mouse", 5, 0)
		local n = w:rallyMice(c, 0, 0, 20, 8)
		T.eq(n, 1)
		T.truthy(m.rallyUntil > w.now)
	end)

	T.it("Sniper Squeak teleports away when a hero gets close", function()
		local w = world(11)
		hero(w, 1, 0, 30, 1)
		w:step(DT, DT)
		local c = w:spawnChampion("champ_sniper", 0, 0)
		stepFor(w, 2.5)
		w:setPlayerPosition(1, 0, 5)
		local blinked = false
		stepFor(w, 2, function(f)
			if f.t == "blink" and f.id == c.id then
				blinked = true
			end
		end)
		T.truthy(blinked, "evade blink")
		T.truthy(math.sqrt(c.x ^ 2 + (c.z - 5) ^ 2) > 12, "moved away")
		T.truthy(math.sqrt(c.x ^ 2 + c.z ^ 2) <= Config.LEASH + 1, "inside its leash")
	end)
end)

T.describe("Combat.Champions › buff stacking", function()
	T.it("Champion's Might stacks to 2, then refreshes the older stack", function()
		local buffs = {}
		local b = { kind = "champ_might", stat = "damageMult", mul = 1.25, untilT = 90 }
		T.eq(Champions.addSquadBuff(buffs, b, 0), 1)
		T.eq(Champions.addSquadBuff(buffs, table.clone(b), 10), 2)
		local s = Pois.applyBuffs(Defaults.stats(), buffs, 20)
		T.near(s.damageMult, 1.25 * 1.25, 1e-9)
		T.eq(
			Champions.addSquadBuff(
				buffs,
				{ kind = "champ_might", stat = "damageMult", mul = 1.25, untilT = 150 },
				30
			),
			2
		)
		T.eq(#buffs, 2)
		s = Pois.applyBuffs(Defaults.stats(), buffs, 85)
		T.near(s.damageMult, 1.25 * 1.25, 1e-9, "still 2 stacks")
		s = Pois.applyBuffs(Defaults.stats(), buffs, 95)
		T.near(s.damageMult, 1.25, 1e-9, "the refreshed stack outlives the other one")
	end)
end)

T.describe("Combat.Pois › v3 big-map layout", function()
	T.it("every map has 6 champion sites and 1-2 lairs, clear of every POI and safe corner", function()
		for _, mapId in Maps.ORDER do
			local def = Maps.get(mapId) :: any
			T.truthy(def.size >= 320 and def.size <= 400, mapId .. " size")
			local R = Pois.arenaRadius(mapId)
			local lay = Pois.layout(Rng.new(#mapId), mapId, R)
			local sites, lairs, regular = {}, {}, {}
			for _, e in lay do
				if e.kind == "champion_site" then
					table.insert(sites, e)
				elseif e.kind == "champion_lair" then
					table.insert(lairs, e)
				else
					table.insert(regular, e)
				end
			end
			T.eq(#sites, 6, mapId)
			T.truthy(#lairs >= 1 and #lairs <= 2, mapId)
			T.eq(#regular, def.poiSlots, mapId)
			for _, s in sites do
				local d = math.sqrt(s.x ^ 2 + s.z ^ 2) / R
				T.truthy(
					d >= Pois.CHAMPION_RING[1] - 1e-6 and d <= Pois.CHAMPION_RING[2] + 1e-6,
					"middle ring"
				)
				T.truthy(s.champion == true and PoiDefs.get(s.kind).mode == "champion")
			end
			for _, s in lairs do
				T.truthy(s.lair == true)
			end
			for _, p in regular do
				for _, s in sites do
					T.truthy(
						(p.x - s.x) ^ 2 + (p.z - s.z) ^ 2 >= (p.r + s.r) ^ 2,
						mapId .. ": " .. p.kind .. " overlaps a champion site"
					)
				end
			end
			for _, c in Pois.squadCorners(R) do
				T.truthy(c.r >= Pois.SAFE_ZONE_R and math.sqrt(c.x ^ 2 + c.z ^ 2) < R - 20)
			end
		end
	end)
end)

T.describe("Combat.World › v3 sprint", function()
	T.it("heroes sprint out of combat (walkSpeed) and stop next to an enemy", function()
		local w = world(12, { cap = 10 })
		hero(w, 1, 0, 0, 1)
		stepFor(w, Maps.SPRINT.calm + 0.5)
		local info = w:getPlayer(1)
		T.truthy(info.sprinting)
		T.near(info.walkSpeed, info.moveSpeed * Maps.SPRINT.mult, 1e-9)
		w:spawnEnemy("mouse", 6, 0)
		stepFor(w, 0.2)
		info = w:getPlayer(1)
		T.falsy(info.sprinting)
		T.near(info.walkSpeed, info.moveSpeed, 1e-9)
	end)
end)

return T.finish()
