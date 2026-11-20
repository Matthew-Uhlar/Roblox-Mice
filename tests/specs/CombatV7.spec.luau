--!strict
-- Iteration 4 combat (docs/iter/4/PLAN.md, M1): aim toggle, bigger maps, the new
-- objectives (beacon chain, rescue, caravan), roaming miniboss camps, personal gem uniques.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Weapons = require("../../src/shared/Combat/Weapons")
local Defaults = require("../../src/shared/Combat/Defaults")
local Maps = require("../../src/shared/Config/Maps")
local PoiConfig = require("../../src/shared/Config/Pois")
local Pois = require("../../src/shared/Combat/Pois")
local ChampConfig = require("../../src/shared/Config/Champions")
local Ids = require("../../src/shared/Util/Ids")

local DT = 1 / 30

local function newWorld(seed: number, extra: { [string]: any }?): any
	local o: any = {
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

local function eventsOf(list: { any }, typ: string): { any }
	local out = {}
	for _, e in list do
		if e.type == typ then
			table.insert(out, e)
		end
	end
	return out
end

T.describe("Aim toggle", function()
	T.it("cursor mode aims projectiles at the point (clamped to range); bots stay on nearest", function()
		local w = newWorld(1, { enemyCap = 10 })
		local wpn = Defaults.weapon("bolt")
		w:addPlayer(1, Defaults.stats(), wpn, Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(Ids.botId(1), Defaults.stats(), wpn, Defaults.ability("burst"), 50, 50, 1)
		run(w, 0.1)
		w:spawnEnemy("mouse", 10, 0) -- the nearest target is east
		T.eq(w:setAim(1, "cursor", 0, 40), "cursor")
		T.eq(w:setAim(Ids.botId(1), "cursor", 0, 40), "nearest", "bots never aim")
		local p = w.players[1]
		local t = Weapons.targetsFor(w, p, 20, 1)
		T.eq(#t, 1)
		T.near(t[1].x, 0, 1e-6)
		T.near(t[1].z, 20, 1e-6, "clamped to the range")
		w:setAim(1, "nearest")
		local n = Weapons.targetsFor(w, p, 20, 1)
		T.truthy(n[1].x > 5, "back on the mouse")
		T.eq(w:getPlayer(1).aimMode, "nearest")
	end)
	T.it("cursor mode never fires at nothing, and melee arcs ignore it", function()
		local w = newWorld(2)
		w:addPlayer(1, Defaults.stats(), Defaults.weapon("bolt"), Defaults.ability("burst"), 0, 0, 1)
		w:setAim(1, "cursor", 30, 0)
		T.eq(#Weapons.targetsFor(w, w.players[1], 20, 1), 0)
		T.falsy(Weapons.AIMABLE.melee_arc)
		T.truthy(Weapons.AIMABLE.lob and Weapons.AIMABLE.cone)
	end)
end)

T.describe("Bigger maps", function()
	T.it("stage radius x1.35, clamped 400-760; POI slots x1.6; 2-4 miniboss camps", function()
		T.eq(Maps.stageRadius("plains", 1), 648)
		for _, id in Maps.ORDER do
			local def = Maps.get(id) :: any
			for st = 1, 4 do
				local r = Maps.stageRadius(id, st)
				T.truthy(r >= 400 and r <= 760, id .. " " .. r)
			end
			T.truthy(def.minibossCamps >= 2 and def.minibossCamps <= 4, id)
		end
	end)
	T.it("layout: beacon chains of 3 links, caravans with a destination, miniboss camps", function()
		local seenBeacon, seenCaravan = false, false
		for seed = 1, 40 do
			local lay = Pois.layout(Rng.new(seed), "plains", Maps.stageRadius("plains", 1))
			local chains: { [number]: number } = {}
			local camps = 0
			for _, e in lay do
				if e.kind == "beacon" then
					seenBeacon = true
					chains[e.chain :: number] = (chains[e.chain :: number] or 0) + 1
				elseif e.kind == "caravan" then
					seenCaravan = true
					T.truthy(e.tx ~= nil and e.tz ~= nil, "caravan destination")
				elseif e.kind == "miniboss_camp" then
					camps += 1
				end
			end
			for _, n in chains do
				T.eq(n, PoiConfig.BEACON_LINKS)
			end
			T.eq(camps, (Maps.get("plains") :: any).minibossCamps)
		end
		T.truthy(seenBeacon and seenCaravan)
	end)
end)

T.describe("Objectives", function()
	local function objWorld(seed: number): any
		local w = newWorld(seed, { enemyCap = 50 })
		w:addPlayer(1, Defaults.stats({ maxHp = 1e6 }), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:startWaves(150)
		w.wave.budget = -1e9
		w.wave.seeded = true
		return w
	end
	T.it("beacons light strictly in order; the last link completes the chain", function()
		local w = objWorld(3)
		local b1 = w:addPoi({ kind = "beacon", x = 0, z = 0, chain = 1, link = 1 })
		local b2 = w:addPoi({ kind = "beacon", x = 60, z = 0, chain = 1, link = 2 })
		local b3 = w:addPoi({ kind = "beacon", x = 120, z = 0, chain = 1, link = 3 })
		w:setPlayerPosition(1, 60, 0)
		run(w, 7)
		T.eq(w.poiById[b2].progress, 0, "link 2 waits for link 1")
		w:setPlayerPosition(1, 0, 0)
		run(w, 7)
		T.eq(w.poiById[b1].state, "done")
		w:setPlayerPosition(1, 60, 0)
		run(w, 7)
		w:setPlayerPosition(1, 120, 0)
		local ev = {}
		for _ = 1, math.floor(7 / DT) do
			w:step(DT, w.now + DT)
			for _, e in w:drainEvents() do
				table.insert(ev, e)
			end
		end
		T.eq(w.poiById[b3].state, "done")
		local rewards = eventsOf(ev, "poiReward")
		T.truthy(rewards[#rewards].chainDone)
		T.eq(rewards[#rewards].kind, "beacon")
	end)
	T.it("rescue: guards first, then the cage channel frees elephants", function()
		local w = objWorld(4)
		local id = w:addPoi({ kind = "rescue_cage", x = 0, z = 0 })
		run(w, 0.2)
		local e = w.poiById[id]
		T.truthy(e.woke)
		T.eq(e.pack, PoiConfig.RESCUE_GUARDS)
		run(w, 8)
		T.eq(e.state, "active", "the guards are alive: no channel")
		for _, m in w.enemies do
			if m.alive and m.poiId == id then
				w:_killEnemy(m, w.players[1])
			end
		end
		local ev = {}
		for _ = 1, math.floor(8 / DT) do
			w:step(DT, w.now + DT)
			for _, x in w:drainEvents() do
				table.insert(ev, x)
			end
		end
		T.eq(e.state, "done")
		local r = eventsOf(ev, "poiReward")
		T.eq(r[#r].rescued, PoiConfig.RESCUE_FREED)
	end)
	T.it("caravan: moves with one squad, holds when contested, pays on arrival", function()
		local w = objWorld(5)
		w:addPlayer(2, Defaults.stats({ maxHp = 1e6 }), harmless(), Defaults.ability("burst"), 200, 200, 2)
		local id = w:addPoi({ kind = "caravan", x = 0, z = 0, tx = 40, tz = 0 })
		local e = w.poiById[id]
		run(w, 2)
		T.near(e.x, 2 * PoiConfig.ESCORT_SPEED, 0.5, "moved with squad 1")
		w:setPlayerPosition(2, e.x, 3)
		local x0 = e.x
		run(w, 2)
		T.near(e.x, x0, 1e-6, "contested: holds")
		w:setPlayerPosition(2, 200, 200)
		local ev = {}
		for _ = 1, math.floor(12 / DT) do
			w:setPlayerPosition(1, e.x, 0)
			w:step(DT, w.now + DT)
			for _, x in w:drainEvents() do
				table.insert(ev, x)
			end
		end
		T.eq(e.state, "done")
		local r = eventsOf(ev, "poiReward")
		T.eq(r[#r].squad, 1)
		T.eq(r[#r].kind, "caravan")
	end)
end)

T.describe("Miniboss camps", function()
	T.it("spawn, patrol, reward the top squad, respawn after 90 s", function()
		local w = newWorld(6, { champions = true })
		w:addPlayer(1, Defaults.stats({ maxHp = 1e6 }), harmless(), Defaults.ability("burst"), 300, 300, 1)
		local camp = w:addPoi({ kind = "miniboss_camp", x = 0, z = 0 })
		w:startWaves(150)
		run(w, ChampConfig.MINIBOSS.firstAt + 1)
		local c = w.poiById[camp]
		local body = c.body
		T.truthy(body and body.alive and body.miniboss)
		T.truthy(type(body.name) == "string")
		local hx = body.homeX
		run(w, 2)
		T.truthy(math.abs(body.homeX - hx) > 0.5, "the leash home patrols")
		body.dmgBySquad = { [1] = 100 }
		w:drainEvents()
		w:_killEnemy(body, w.players[1])
		local ev = w:drainEvents()
		local dead = eventsOf(ev, "minibossDead")
		T.eq(#dead, 1)
		T.eq(dead[1].squad, 1)
		local rinds, whey = 0, 0
		for _, e in ev do
			if e.type == "rinds" and e.id == 1 then
				rinds += e.amount
			elseif e.type == "whey" and e.id == 1 then
				whey += e.amount
			end
		end
		T.truthy(rinds >= ChampConfig.MINIBOSS.rinds)
		T.truthy(whey >= ChampConfig.MINIBOSS.whey)
		run(w, ChampConfig.MINIBOSS.respawn - 5)
		T.eq(c.body, nil, "not back yet")
		run(w, 6)
		T.truthy(c.body and c.body.alive, "respawned")
	end)
	T.it("minibosses never take a regular champion's slot", function()
		local w = newWorld(7, { champions = true })
		w:addPlayer(1, Defaults.stats({ maxHp = 1e6 }), harmless(), Defaults.ability("burst"), 300, 300, 1)
		for k = 1, 4 do
			w:addPoi({ kind = "miniboss_camp", x = k * 60 - 150, z = -200 })
		end
		w:addPoi({ kind = "champion_site", x = 0, z = 150 })
		w:setStage(1, 2)
		w:startWaves(150)
		local champs = 0
		for _ = 1, math.floor(60 / DT) do
			w:step(DT, w.now + DT)
			for _, e in w:drainEvents() do
				if e.type == "championSpawn" then
					champs += 1
				end
			end
		end
		T.truthy(champs >= 5, "4 minibosses + the site's champion: " .. champs)
	end)
end)

T.describe("Personal gem uniques (iteration 4)", function()
	T.it("setHeroUniques: generic for the hero, class uniques only for that class", function()
		local w = newWorld(8)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 5, 0, 1)
		w:setHeroClass(1, "jumbo")
		w:setHeroUniques(1, { "u_jumbo", "u_stride" })
		w:setHeroUniques(2, { "u_jumbo" })
		T.near(w.players[1].maxHp, 110, 1e-6)
		T.near(w.players[1].stats.moveSpeed, 16 * 1.06, 1e-6)
		T.eq(w.players[2].maxHp, 100, "not a Jumbo")
		w:setHeroUniques(1, nil)
		T.eq(w.players[1].maxHp, 100)
	end)
end)

return T.finish()
