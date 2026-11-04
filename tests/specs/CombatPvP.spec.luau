--!strict
-- v2 squads and PvP (docs/GDD-v2.md §2): Combat/World + Combat/Weapons.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local Stats = require("../../src/shared/Run/Stats")
local Ids = require("../../src/shared/Util/Ids")
local FxFilter = require("../../src/shared/Combat/FxFilter")

local DT = 1 / 30

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

local function bolt(dmg: number): any
	local w = Defaults.weapon("bolt")
	w.damage = dmg
	w.pierce = 0
	w.cooldown = 0.5
	return w
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

-- Two heroes of different squads; protection off so they can fight at once.
local function duel(seed: number, aWeapon: any, aStats: any?, dist: number?, opts: any?): any
	local w = newWorld(seed, opts)
	w:addPlayer(1, Defaults.stats(aStats), aWeapon, Defaults.ability("burst"), 0, 0, 1)
	w:addPlayer(2, Defaults.stats({ maxHp = 1000 }), harmless(), Defaults.ability("burst"), dist or 8, 0, 2)
	w:protect(1, 0)
	w:protect(2, 0)
	return w
end

T.describe("World squads", function()
	T.it("addPlayer takes the squad as the 7th argument (default 1); setSquad / squadOf", function()
		local w = newWorld(1)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 5, 0, 3)
		T.eq(w:squadOf(1), 1)
		T.eq(w:squadOf(2), 3)
		T.truthy(w.pvp, "two squads -> PvP on")
		w:setSquad(2, 1)
		T.eq(w:squadOf(2), 1)
		T.falsy(w.pvp, "one squad -> PvP off")
		T.deepEq(w:aliveSquads(), { 1 })
		T.eq(w:getPlayer(2).squad, 1)
		T.eq(w:getPlayers()[1].squad, 1)
	end)
end)

T.describe("PvP damage", function()
	T.it("hits an enemy-squad hero at PVP_MULT and never crits", function()
		local w = duel(2, bolt(20), { critChance = 1, critMult = 3 })
		local ev = eventsOf((function()
			run(w, 0.6)
			return w:drainEvents()
		end)(), "damaged")
		T.truthy(#ev >= 1, "hero 2 was hit")
		for _, e in ev do
			T.eq(e.id, 2)
			T.eq(e.by, 1)
			T.near(e.amount, 20 * World.PVP_MULT, 1e-6)
		end
	end)
	T.it("no friendly fire: same-squad heroes are never hit", function()
		local w = newWorld(3)
		w:addPlayer(1, Defaults.stats(), bolt(30), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 5, 0, 1)
		w:addPlayer(3, Defaults.stats(), harmless(), Defaults.ability("burst"), -60, 0, 2) -- PvP on, far away
		for _, id in { 1, 2, 3 } do
			w:protect(id, 0)
		end
		run(w, 2)
		T.eq(#eventsOf(w:drainEvents(), "damaged"), 0)
		T.eq(w:getPlayer(2).hp, 100)
		-- explosions and zones neither
		w:useAbility(1, 5, 0, w.now)
		run(w, 0.5)
		T.eq(w:getPlayer(2).hp, 100)
	end)
	T.it("abilities, explosions, chains and puddle zones hit enemy heroes", function()
		-- burst ability (explosion)
		local w = duel(4, harmless())
		run(w, 0.1)
		T.truthy(w:useAbility(1, 8, 0, w.now))
		run(w, 0.1)
		T.near(w:getPlayer(2).hp, 1000 - Defaults.ability("burst").damage * World.PVP_MULT, 1e-6)
		-- puddle weapon (zone ticks)
		local pw = Defaults.weapon("puddle")
		local w2 = duel(5, pw)
		run(w2, 1.5)
		T.truthy(w2:getPlayer(2).hp < 1000, "puddle ticks hurt the rival")
		-- chain: a mouse hit jumps to the rival hero next to it
		local w3 = newWorld(6, { enemyCap = 10 })
		w3:addPlayer(1, Defaults.stats({ chain = 1 }), bolt(10), Defaults.ability("burst"), 0, 0, 1)
		w3:addPlayer(2, Defaults.stats({ maxHp = 1000 }), harmless(), Defaults.ability("burst"), 30, 0, 2)
		w3:protect(1, 0)
		w3:protect(2, 0)
		local m = w3:spawnEnemy("chonk", 25, 0)
		m.hp, m.maxHp, m.speed = 1e6, 1e6, 0
		run(w3, 0.4)
		local chainToHero = false
		for _, e in eventsOf(w3:drainEvents(), "damaged") do
			if e.id == 2 and e.by == 1 then
				chainToHero = true
			end
		end
		T.truthy(chainToHero, "chain jumped to the hero")
	end)
	T.it("targeting prefers mice, but takes a hero that is closest or within 10 studs", function()
		local w = newWorld(7, { enemyCap = 10 })
		w:addPlayer(1, Defaults.stats(), bolt(1), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 25, 0, 2)
		w:protect(2, 0)
		run(w, 0.05)
		local m = w:spawnEnemy("mouse", 15, 0)
		local p = w.players[1]
		T.eq(w:targetsFor(p, 40, 1)[1], m, "a closer mouse wins over a hero at 25 studs")
		w:setPlayerPosition(2, 9, 5)
		T.eq(w:targetsFor(p, 40, 1)[1], w.players[2], "a hero within HERO_AGGRO wins")
		w:setPlayerPosition(2, 0, 14)
		m.x, m.z = 30, 0
		T.eq(w:targetsFor(p, 40, 1)[1], w.players[2], "the closest target is a hero")
		w:setSquad(2, 1)
		T.eq(w:targetsFor(p, 40, 1)[1], m, "never a squad-mate")
	end)
end)

T.describe("Every weapon kind steps for real (regression: missing targetsFor crash)", function()
	local KINDS = { "melee_arc", "bolt", "spread", "cone", "orbit", "lob", "puddle" }
	for _, kind in KINDS do
		T.it(kind .. ": world:step in a 4-squad world hits mice and the rival hero", function()
			local w = newWorld(40, { enemyCap = 50 })
			local wpn = Defaults.weapon(kind)
			w:addPlayer(1, Defaults.stats(), wpn, Defaults.ability("burst"), 0, 0, 1)
			w:addPlayer(2, Defaults.stats({ maxHp = 1e5 }), harmless(), Defaults.ability("burst"), 70, 0, 2)
			w:addPlayer(3, Defaults.stats(), harmless(), Defaults.ability("burst"), 90, 0, 3)
			w:addPlayer(4, Defaults.stats(), harmless(), Defaults.ability("burst"), -90, 0, 4)
			for id = 1, 4 do
				w:protect(id, 0)
			end
			run(w, 0.05)
			for i = 1, 6 do
				local m = w:spawnEnemy("mouse", math.cos(i) * 5, math.sin(i) * 5)
				m.speed = 0
			end
			local ok, err = pcall(run, w, 3)
			T.truthy(ok, tostring(err))
			local kills = 0
			for _, e in w:drainEvents() do
				if e.type == "kill" then
					kills += 1
				end
			end
			-- then the rival walks up
			w:setPlayerPosition(2, 4, 3)
			local ok2, err2 = pcall(run, w, 2)
			T.truthy(ok2, tostring(err2))
			T.truthy(w:getPlayer(2).hp < 1e5, kind .. " hit the rival hero")
			T.truthy(kills > 0, kind .. " killed mice")
		end)
	end
	T.it("Weapons tolerates a world without the v2 targetsFor hook", function()
		for _, kind in KINDS do
			local w = newWorld(41, { enemyCap = 50 })
			w.targetsFor = false -- shadow the method (an older / stub world)
			w:addPlayer(1, Defaults.stats(), Defaults.weapon(kind), Defaults.ability("burst"), 0, 0)
			run(w, 0.05)
			local m = w:spawnEnemy("mouse", 3, 0)
			m.speed = 0
			local ok, err = pcall(run, w, 2)
			T.truthy(ok, kind .. ": " .. tostring(err))
		end
	end)
end)

T.describe("Downed, killed, eliminated", function()
	T.it("a downed hero dies after DOWNED_HITS enemy hits: heroDowned / heroKilled carry `by`", function()
		local w = duel(8, bolt(40), nil, 8)
		w.players[2].hp = 5
		w.players[2].maxHp = 100
		-- a third hero keeps squad 2 from being eliminated outright
		w:addPlayer(3, Defaults.stats(), harmless(), Defaults.ability("burst"), 100, 0, 2)
		w:protect(3, 0)
		local evs = {}
		local t = w.now
		local killedAt = nil
		for i = 1, 300 do
			t += DT
			w:step(DT, t)
			for _, e in w:drainEvents() do
				table.insert(evs, e)
				if e.type == "heroKilled" then
					killedAt = i
				end
			end
			if killedAt then
				break
			end
		end
		local downs = eventsOf(evs, "heroDowned")
		T.eq(#downs, 1)
		T.eq(downs[1].id, 2)
		T.eq(downs[1].by, 1)
		local kills = eventsOf(evs, "heroKilled")
		T.eq(#kills, 1)
		T.eq(kills[1].by, 1)
		T.eq(kills[1].squad, 2)
		local hits = 0
		for _, e in eventsOf(evs, "damaged") do
			if e.kind == "downedHit" then
				hits += 1
			end
		end
		T.eq(hits, World.DOWNED_HITS)
		T.truthy(w:getPlayer(2).dead)
		T.truthy(killedAt * DT < World.DOWNED_TIME, "died to hits, not the timer")
		T.eq(#eventsOf(evs, "dead"), 1, "the v1 dead event still fires")
	end)
	T.it("the downed timer still kills (by = the hero who downed them)", function()
		local w = duel(9, harmless())
		w:addPlayer(3, Defaults.stats(), harmless(), Defaults.ability("burst"), 100, 0, 2)
		run(w, 0.1)
		w:damageHeroFrom(w.players[2], 1e6, w.players[1])
		T.truthy(w:getPlayer(2).downed)
		run(w, World.DOWNED_TIME + 0.2)
		local k = eventsOf(w:drainEvents(), "heroKilled")
		T.eq(#k, 1)
		T.eq(k[1].by, 1)
	end)
	T.it("enemies do not revive each other; squad-mates do", function()
		local w = duel(10, harmless())
		w:addPlayer(3, Defaults.stats(), harmless(), Defaults.ability("burst"), 200, 0, 2)
		run(w, 0.1)
		w:damageHeroFrom(w.players[2], 1e6, w.players[1])
		run(w, World.REVIVE_TIME + 0.5)
		T.truthy(w:getPlayer(2).downed, "the enemy standing next to it does not revive")
		w:setPlayerPosition(3, 10, 0)
		run(w, World.REVIVE_TIME + 0.2)
		T.falsy(w:getPlayer(2).downed, "the squad-mate revived it")
	end)
	T.it("a squad with nobody standing is eliminated; its downed members die and drop bags", function()
		local w = duel(11, harmless())
		w:addPlayer(3, Defaults.stats(), harmless(), Defaults.ability("burst"), 60, 0, 2)
		w:protect(3, 0)
		run(w, 0.1)
		w:giveGear(2, { id = "rind_plate", slot = "armor", rarity = "Epic" })
		w.players[2].secondWindUsed = true
		w.players[3].secondWindUsed = true
		w:damageHeroFrom(w.players[2], 1e6, w.players[1])
		w:damageHeroFrom(w.players[3], 1e6, w.players[1])
		run(w, 0.1)
		local evs = w:drainEvents()
		local el = eventsOf(evs, "squadEliminated")
		T.eq(#el, 1)
		T.eq(el[1].squad, 2)
		T.eq(el[1].by, 1)
		T.eq(#eventsOf(evs, "heroKilled"), 2)
		T.truthy(w:getPlayer(2).dead and w:getPlayer(3).dead)
		T.deepEq(w:aliveSquads(), { 1 })
		T.truthy(w:isEliminated(2))
		T.eq(#w:lootBags(), 1, "the geared hero dropped a bag")
		T.eq(w:lootBags()[1].n, 1)
	end)
	T.it("a usable Second Wind gives a fully-downed squad ELIM_GRACE seconds", function()
		local w = duel(12, harmless())
		run(w, 0.1)
		w:damageHeroFrom(w.players[2], 1e6, w.players[1])
		run(w, World.ELIM_GRACE - 1)
		T.eq(#eventsOf(w:drainEvents(), "squadEliminated"), 0)
		T.truthy(w:useSecondWind(2))
		run(w, 2)
		T.eq(#eventsOf(w:drainEvents(), "squadEliminated"), 0)
		T.falsy(w:getPlayer(2).downed)
	end)
	T.it("one squad only (v1): no eliminations, the downed timer rules", function()
		local w = newWorld(13)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		run(w, 0.1)
		w:damagePlayer(w.players[1], 1e6, "contact")
		run(w, 10)
		T.eq(#eventsOf(w:drainEvents(), "squadEliminated"), 0)
		T.truthy(w:getPlayer(1).downed)
	end)
end)

T.describe("Spawn protection and safe zones", function()
	T.it("5 s of PvP protection at drop-in (not against mice)", function()
		local w = newWorld(14)
		w:addPlayer(1, Defaults.stats(), bolt(20), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 6, 0, 2)
		w:protect(1, 0) -- the attacker is not protected
		local fx = run(w, World.SPAWN_PROTECT - 0.5)
		T.truthy(w:getPlayer(2).protected)
		T.eq(w:getPlayer(2).hp, 100, "protected from heroes")
		T.truthy(#fxOf(fx, "protect") >= 2, "protect Fx")
		w:damagePlayer(w.players[2], 10, "contact")
		T.eq(w:getPlayer(2).hp, 90, "mice still hurt")
		run(w, 1.5)
		T.falsy(w:getPlayer(2).protected)
		T.truthy(w:getPlayer(2).hp < 90, "hit once protection ended")
	end)
	T.it("revives grant protection again; attacking a rival ends your own", function()
		local w = duel(15, harmless())
		w:addPlayer(3, Defaults.stats(), harmless(), Defaults.ability("burst"), 10, 2, 2)
		w:protect(3, 0)
		run(w, 0.1)
		w:damageHeroFrom(w.players[2], 1e6, w.players[1])
		run(w, World.REVIVE_TIME + 0.2)
		T.truthy(w:getPlayer(2).protected, "protected after the revive")
		T.eq(w:damageHeroFrom(w.players[2], 50, w.players[1]), 0)
		T.truthy(w:damageHeroFrom(w.players[1], 50, w.players[2]) > 0, "the protected hero can attack...")
		T.falsy(w:getPlayer(2).protected, "...which ends its protection")
		T.eq(#eventsOf(w:drainEvents(), "protectEnd"), 1)
	end)
	T.it("inside your own safe zone, other squads deal 60% less", function()
		local zones = { [2] = { x = 8, z = 0, r = 10 } }
		local w = duel(16, harmless(), nil, 8, { safeZones = zones })
		run(w, 0.1)
		local took = w:damageHeroFrom(w.players[2], 100, w.players[1])
		T.near(took, 100 * World.PVP_MULT * (1 - World.SAFE_ZONE_REDUCTION), 1e-6)
		-- the attacker gets no reduction in someone else's zone
		run(w, 0.6)
		w:setPlayerPosition(1, 8, 2)
		local back = w:damageHeroFrom(w.players[1], 100, w.players[2])
		T.near(back, 100 * World.PVP_MULT, 1e-6)
	end)
end)

T.describe("Boss damage per squad", function()
	T.it("bossDead carries killer, killerSquad and damageBySquad", function()
		local w = newWorld(17, { enemyCap = 10 })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 80, 0, 2)
		run(w, 0.1)
		local b = w:spawnBoss("cheese_golem", 0, 30)
		run(w, World.BOSS_INTRO + 0.1)
		w:damageEnemy(b, 300, w.players[1])
		w:damageEnemy(b, 100, w.players[2])
		local dmg, top = w:bossDamageBySquad()
		T.eq(dmg[1], 300)
		T.eq(dmg[2], 100)
		T.eq(top, 1)
		w:damageEnemy(b, 1e7, w.players[2])
		local ev = eventsOf(w:drainEvents(), "bossDead")
		T.eq(#ev, 1)
		T.eq(ev[1].killer, 2)
		T.eq(ev[1].killerSquad, 2, "the killing blow wins, not the top damage")
		T.truthy(ev[1].damageBySquad[1] == 300 and ev[1].damageBySquad[2] > 100)
	end)
end)

T.describe("PvP Fx", function()
	T.it("heroKill / squadOut / protect are JSON-safe and always sent; your hits on rivals always reach you", function()
		local w = duel(18, harmless())
		run(w, 0.1)
		w.players[2].secondWindUsed = true
		w:damageHeroFrom(w.players[2], 1e6, w.players[1])
		local fx = run(w, 0.1)
		T.eq(#fxOf(fx, "heroKill"), 1)
		T.eq(#fxOf(fx, "squadOut"), 1)
		for _, t in { "heroKill", "squadOut", "protect", "vault", "totem", "bag", "gear", "carrier" } do
			T.truthy(FxFilter.relevant({ t = t, x = 1e4, z = 1e4 }, 0, 0, 100, nil), t)
		end
		T.truthy(FxFilter.relevant({ t = "hurt", id = 5, by = 1, x = 1e4, z = 0 }, 0, 0, 100, 1))
		T.falsy(FxFilter.relevant({ t = "hurt", id = 5, by = 7, x = 1e4, z = 0 }, 0, 0, 100, 1))
		T.falsy(FxFilter.relevant({ t = "dodge", id = 5, x = 1e4, z = 0 }, 0, 0, 100, 1))
	end)
end)

T.describe("Perf › 12 heroes in 4 squads + 220 mice", function()
	T.it("average step <= 1.5 ms under Lune (PvP on)", function()
		local mods = Stats.worldMods(2, 4, {}, 4)
		mods.spawnRateMult *= 6
		local w = World.new({
			rng = Rng.new(77),
			mods = mods,
			arenaRadius = 140,
			obstacles = { { x = 40, z = 40, r = 5 }, { x = -50, z = 20, r = 4 } },
			enemyPool = { "mouse", "rat_runner", "chonk", "crumb_slinger", "fuse_mouse" },
			cycle = 2,
			stage = 4,
		})
		local classes = { "fizzante", "filet", "ele_fonte", "elephante" }
		local ids = {}
		for sq = 1, 4 do
			for k = 1, 3 do
				local id = if k == 1 then sq * 10 else Ids.botId(sq * 10 + k)
				local stats, weapon, ability = Stats.compute(classes[(sq + k) % 4 + 1], {}, {}, nil)
				stats.projectileBonus = 1
				stats.chain = 1
				stats.explodeOnKill = 3
				stats.maxHp = 1e5
				stats.regen = 500
				w:addPlayer(id, stats, weapon, ability, 0, 0, sq)
				table.insert(ids, { id = id, sq = sq, k = k })
			end
		end
		w:startWaves(120)
		local now, total, steps = 0, 0, 1800
		for i = 1, steps do
			local t = i * DT
			for _, h in ids do
				-- squads circle on overlapping rings: they meet and fight now and then
				local a = t * 0.12 + h.sq * math.pi / 2 + h.k * 0.15
				w:setPlayerPosition(h.id, math.cos(a) * (40 + h.sq * 6), math.sin(a) * (40 + h.sq * 6))
				if i % 90 == h.k * 7 then
					w:useAbility(h.id, math.cos(a) * 50, math.sin(a) * 50, now)
				end
			end
			now += DT
			local t0 = os.clock()
			w:step(DT, now)
			total += (os.clock() - t0) * 1000
			w:drainEvents()
			w:drainTeleports()
		end
		local avg = total / steps
		print(string.format("  [perf] 12 heroes / 4 squads, %d mice: %.3f ms/step avg", w:enemyCount(), avg))
		T.truthy(w:enemyCount() >= 150, "a big horde")
		T.truthy(avg <= 1.5, string.format("avg %.3f ms", avg))
	end)
end)

return T.finish()
