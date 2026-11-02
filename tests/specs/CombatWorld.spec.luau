local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local Stats = require("../../src/shared/Run/Stats")

local DT = 1 / 30

local function newWorld(seed: number, extra: { [string]: any }?): any
	local o: any = {
		rng = Rng.new(seed),
		mods = Defaults.mods(),
		arenaRadius = 120,
		obstacles = { { x = 30, z = 30, r = 4 }, { x = -40, z = 10, r = 6 } },
		enemyPool = { "mouse", "rat_runner", "chonk", "crumb_slinger", "fuse_mouse" },
		cycle = 1,
		stage = 1,
	}
	for k, v in extra or {} do
		o[k] = v
	end
	return World.new(o)
end

-- A weapon that never hurts anything (to observe enemies / contact damage).
local function harmless(): any
	local w = Defaults.weapon("bolt")
	w.damage = 0
	return w
end

local function run(w: any, seconds: number, t0: number?): (number, { any })
	local t = t0 or w.now
	local all = {}
	for _ = 1, math.floor(seconds / DT + 0.5) do
		t += DT
		for _, f in w:step(DT, t) do
			table.insert(all, f)
		end
	end
	return t, all
end

local function count(list: { any }, pred: (any) -> boolean): number
	local n = 0
	for _, v in list do
		if pred(v) then
			n += 1
		end
	end
	return n
end

local function eventsOf(w: any, typ: string): { any }
	local out = {}
	for _, e in w:drainEvents() do
		if e.type == typ then
			table.insert(out, e)
		end
	end
	return out
end

T.describe("Combat.World", function()
	T.it("is deterministic for a seed", function()
		local function sim(seed: number)
			local w = newWorld(seed)
			w:addPlayer(1, Defaults.stats(), Defaults.weapon("bolt"), Defaults.ability("burst"), 0, 0)
			w:addPlayer(-1, Defaults.stats(), Defaults.weapon("melee_arc"), Defaults.ability("dash"), 5, 0)
			w:startWaves(60)
			local t = 0
			for i = 1, 450 do
				t += DT
				w:setPlayerPosition(1, math.cos(i / 40) * 10, math.sin(i / 40) * 10)
				w:step(DT, t)
			end
			return w:snapshot(), #w:drainEvents()
		end
		local a, ea = sim(77)
		local b, eb = sim(77)
		T.truthy(#a > 0, "something spawned")
		T.eq(#a, #b)
		T.eq(ea, eb)
		T.deepEq(a, b)
		local c = sim(78)
		T.falsy(#c == #a and c[1].x == a[1].x and c[#c].z == a[#a].z, "other seed differs")
	end)

	T.it("enemies approach the nearest player", function()
		local w = newWorld(1)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		local e = w:spawnEnemy("mouse", 40, 0, false)
		T.truthy(e)
		run(w, 2)
		T.truthy(e.x < 40 - 15, "moved ~18 studs closer, x=" .. e.x)
		T.near(e.z, 0, 1)
	end)

	T.it("enemies steer around obstacles and never end up inside one", function()
		local w = newWorld(2, { obstacles = { { x = 20, z = 0, r = 6 } } })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		local list = {}
		for i = 1, 10 do
			table.insert(list, w:spawnEnemy("mouse", 45, (i - 5) * 0.5, false))
		end
		for _ = 1, 150 do
			run(w, DT)
			for _, e in list do
				T.truthy((e.x - 20) ^ 2 + e.z ^ 2 >= (6 + e.r - 0.01) ^ 2, "inside obstacle")
			end
		end
		local reached = 0
		for _, e in list do
			if e.x < 15 then
				reached += 1
			end
		end
		T.truthy(reached >= 8, "most got past the rock: " .. reached)
	end)

	T.it("separation keeps a crowd from collapsing to a point", function()
		local w = newWorld(3)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		w.players[1].invulnUntil = 1e9
		for i = 1, 40 do
			w:spawnEnemy("mouse", 30 + (i % 7), (i % 5) - 2, false)
		end
		run(w, 6)
		local snaps = w:snapshot()
		local close = 0
		for i = 1, #snaps do
			for j = i + 1, #snaps do
				if (snaps[i].x - snaps[j].x) ^ 2 + (snaps[i].z - snaps[j].z) ^ 2 < 0.5 ^ 2 then
					close += 1
				end
			end
		end
		T.truthy(close < 10, "overlapping pairs " .. close)
	end)

	T.it("weapons kill enemies and drop crumbs that become XP", function()
		local w = newWorld(4)
		w:addPlayer(
			7,
			Defaults.stats({ pickupRadius = 30 }),
			Defaults.weapon("bolt"),
			Defaults.ability("burst"),
			0,
			0
		)
		for i = 1, 6 do
			local a = i / 6 * math.pi * 2
			w:spawnEnemy("mouse", math.cos(a) * 20, math.sin(a) * 20, false)
		end
		local _, fx = run(w, 8)
		local evs = w:drainEvents()
		T.eq(
			count(evs, function(e)
				return e.type == "kill" and e.id == 7 and e.kind == "mouse"
			end),
			6
		)
		T.eq(
			count(fx, function(f)
				return f.t == "die"
			end),
			6
		)
		T.eq(
			count(fx, function(f)
				return f.t == "pickup"
			end),
			6
		)
		local xp = 0
		for _, e in evs do
			if e.type == "xp" then
				T.eq(e.id, 7)
				xp += e.amount
			end
		end
		T.near(xp, 6, 1e-9, "6 mice x 1 xp")
		T.eq(w:enemyCount(), 0)
		T.eq(w:pickupCount(), 0)
	end)

	T.it("xpMult scales collected xp", function()
		local w = newWorld(5)
		w:addPlayer(
			1,
			Defaults.stats({ xpMult = 2, pickupRadius = 40 }),
			Defaults.weapon("bolt"),
			Defaults.ability("burst"),
			0,
			0
		)
		w:spawnEnemy("chonk", 15, 0, false)
		run(w, 8)
		local xp = 0
		for _, e in eventsOf(w, "xp") do
			xp += e.amount
		end
		T.near(xp, 10, 1e-9)
	end)

	T.it("contact damage respects armor and 0.5 s i-frames", function()
		local w = newWorld(6)
		w:addPlayer(1, Defaults.stats({ armor = 2 }), harmless(), Defaults.ability("burst"), 0, 0)
		local e = w:spawnEnemy("mouse", 0.5, 0, false)
		T.truthy(e)
		local t = run(w, DT)
		local p = w:getPlayer(1)
		T.near(p.hp, 100 - (6 - 2), 1e-9, "one hit minus armor")
		-- still overlapping during i-frames: no further damage
		t = run(w, 0.4, t)
		T.near(w:getPlayer(1).hp, 96, 1e-9)
		run(w, 0.2, t)
		T.near(w:getPlayer(1).hp, 92, 1e-9, "hit again after i-frames")
		local dmg = eventsOf(w, "damaged")
		T.eq(#dmg, 2)
		T.eq(dmg[1].kind, "contact")
	end)

	T.it("damage is at least 1 even with huge armor; oneHitKO downs on any hit", function()
		local w = newWorld(7)
		w:addPlayer(1, Defaults.stats({ armor = 50 }), harmless(), Defaults.ability("burst"), 0, 0)
		w:spawnEnemy("mouse", 0.5, 0, false)
		run(w, DT)
		T.near(w:getPlayer(1).hp, 99, 1e-9)

		local w2 = newWorld(7, { mods = Defaults.mods({ oneHitKO = true }) })
		w2:addPlayer(1, Defaults.stats({ armor = 50 }), harmless(), Defaults.ability("burst"), 0, 0)
		w2:spawnEnemy("mouse", 0.5, 0, false)
		run(w2, DT)
		T.truthy(w2:getPlayer(1).downed)
	end)

	T.it("downed players are revived by a teammate (bot) within 8 studs for 3 s at 40% HP", function()
		local w = newWorld(8)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		w:addPlayer(-1, Defaults.stats(), harmless(), Defaults.ability("burst"), 40, 0)
		local t = run(w, DT)
		w:damagePlayer(w.players[1], 500, "test")
		local p = w:getPlayer(1)
		T.truthy(p.downed)
		T.near(p.downedUntil, t + 20, 1e-6)
		T.eq(#eventsOf(w, "downed"), 1)
		T.falsy(w:allPlayersDown(), "bot still standing")
		-- too far: no progress
		t = run(w, 2, t)
		T.truthy(w:getPlayer(1).downed)
		w:setPlayerPosition(-1, 6, 0)
		t = run(w, 2.5, t)
		T.truthy(w:getPlayer(1).downed, "not yet")
		run(w, 0.6, t)
		p = w:getPlayer(1)
		T.falsy(p.downed)
		T.near(p.hp, 40, 1e-9)
		local rev = eventsOf(w, "revived")
		T.eq(#rev, 1)
		T.eq(rev[1].kind, "teammate")
	end)

	T.it("downed bots get revived by a human too", function()
		local w = newWorld(9)
		w:addPlayer(5, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		w:addPlayer(-2, Defaults.stats(), harmless(), Defaults.ability("burst"), 3, 0)
		local t = run(w, DT)
		w:damagePlayer(w.players[-2], 500)
		T.truthy(w:getPlayer(-2).downed)
		run(w, 3.2, t)
		T.falsy(w:getPlayer(-2).downed)
	end)

	T.it("downed timer expires into spectator; allPlayersDown; respawnDead", function()
		local w = newWorld(10)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 50, 0)
		local t = run(w, DT)
		T.falsy(w:allPlayersDown())
		w:damagePlayer(w.players[1], 500)
		T.falsy(w:allPlayersDown())
		w:damagePlayer(w.players[2], 500)
		T.truthy(w:allPlayersDown())
		t = run(w, 20.1, t)
		T.truthy(w:getPlayer(1).dead)
		T.falsy(w:getPlayer(1).downed)
		T.eq(#eventsOf(w, "dead"), 2)
		T.truthy(w:allPlayersDown())
		T.falsy(w:useAbility(1, 1, 1, t), "spectators can't cast")
		w:respawnDead(0.5)
		T.falsy(w:getPlayer(1).dead)
		T.near(w:getPlayer(2).hp, 50, 1e-9)
		T.falsy(w:allPlayersDown())
	end)

	T.it("second wind self-revives once per stage", function()
		local w = newWorld(11)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		local t = run(w, DT)
		T.falsy(w:useSecondWind(1), "not downed")
		w:damagePlayer(w.players[1], 500)
		T.truthy(w:allPlayersDown())
		T.truthy(w:useSecondWind(1))
		T.near(w:getPlayer(1).hp, 50, 1e-9)
		T.falsy(w:allPlayersDown())
		run(w, 3, t)
		w:damagePlayer(w.players[1], 500)
		T.falsy(w:useSecondWind(1), "capped at 1 per stage")
		w:setStage(1, 2)
		T.truthy(w:useSecondWind(1), "new stage resets the cap")
	end)

	T.it("regen heals, scaled by healingMult; healPlayer heals a fraction of max HP", function()
		local w = newWorld(12, { mods = Defaults.mods({ healingMult = 0.5 }) })
		w:addPlayer(1, Defaults.stats({ regen = 4 }), harmless(), Defaults.ability("burst"), 0, 0)
		local p = w.players[1]
		p.hp = 50
		run(w, 1)
		T.near(p.hp, 52, 0.01)
		w:healPlayer(1, 0.2)
		T.near(p.hp, 62, 0.01)
		w:healPlayer(1, 5)
		T.near(p.hp, 100, 1e-9, "capped at max")
	end)

	T.it("updatePlayer keeps the hp ratio", function()
		local w = newWorld(13)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		w.players[1].hp = 50
		w:updatePlayer(1, Defaults.stats({ maxHp = 200 }), Defaults.weapon("bolt"))
		local p = w:getPlayer(1)
		T.eq(p.maxHp, 200)
		T.near(p.hp, 100, 1e-9)
	end)

	T.it("crumb slingers shoot projectiles that hurt", function()
		local w = newWorld(14)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		w:spawnEnemy("crumb_slinger", 25, 0, false)
		local _, fx = run(w, 6)
		T.truthy(count(fx, function(f)
			return f.t == "proj" and f.hostile == true and f.kind == "crumb"
		end) >= 1)
		local hurt = 0
		for _, e in eventsOf(w, "damaged") do
			if e.kind == "projectile" then
				hurt += 1
			end
		end
		T.truthy(hurt >= 1, "slinger hit the player")
	end)

	T.it("fuse mice telegraph for 1 s then explode", function()
		local w = newWorld(15)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		local e = w:spawnEnemy("fuse_mouse", 12, 0, false)
		local t, fx = 0, {}
		local teleAt, boomAt
		for _ = 1, 150 do
			t, fx = run(w, DT, t)
			for _, f in fx do
				if f.t == "tele" and f.style == "fuse" and not teleAt then
					teleAt = t
					T.near(f.delay, 1, 1e-9)
				elseif f.t == "boom" and f.kind == "fuse" then
					boomAt = t
				end
			end
		end
		T.truthy(teleAt and boomAt, "telegraphed and exploded")
		T.near(boomAt - teleAt, 1, DT + 1e-6)
		T.falsy(e.alive)
		T.truthy(w:getPlayer(1).hp < 100)
		T.eq(w:pickupCount(), 0, "exploded fuse mice drop nothing")
	end)

	T.it("falling rocks telegraph then slam when the mod is on", function()
		local w = newWorld(16, { mods = Defaults.mods({ fallingRocks = true }) })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		w:startWaves(60)
		local _, fx = run(w, 12)
		local tele = count(fx, function(f)
			return f.t == "tele" and f.style == "rock"
		end)
		local slam = count(fx, function(f)
			return f.t == "slam" and f.style == "rock"
		end)
		T.truthy(tele >= 2, "rocks fell: " .. tele)
		T.truthy(slam >= 2 and slam <= tele)
		for _, f in fx do
			if f.t == "tele" then
				T.truthy(f.delay >= 0.6)
			end
		end
	end)

	T.it("boss enters phase 2 at 50% HP and dies with bossDead", function()
		local w = newWorld(17)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 30)
		local t = run(w, DT)
		local b = w:spawnBoss("giant_tree", 0, 0)
		T.truthy(w:bossAlive())
		T.eq(w:bossInfo().phase, 1)
		T.eq(w:damageEnemy(b, 100, w.players[1]), 0, "invulnerable during the 3 s intro")
		t = run(w, 3.2, t)
		w:damageEnemy(b, b.maxHp * 0.49, w.players[1])
		T.eq(w:bossInfo().phase, 1)
		w:damageEnemy(b, b.maxHp * 0.02, w.players[1])
		T.eq(w:bossInfo().phase, 2)
		local ph = eventsOf(w, "bossPhase")
		T.eq(#ph, 1)
		T.eq(ph[1].kind, "giant_tree")
		T.eq(ph[1].amount, 2)
		run(w, 3, t)
		w:damageEnemy(b, 1e9, w.players[1])
		T.falsy(w:bossAlive())
		T.eq(w:bossInfo(), nil)
		local evs = w:drainEvents()
		T.eq(
			count(evs, function(e)
				return e.type == "bossDead" and e.kind == "giant_tree"
			end),
			1
		)
	end)

	T.it("getPlayers and pickupsNear expose allies and crumbs (bots use the -1000 id band)", function()
		local w = newWorld(18)
		w:addPlayer(3, Defaults.stats(), harmless(), Defaults.ability("burst"), 1, 2)
		w:addPlayer(-1001, Defaults.stats(), harmless(), Defaults.ability("dash"), -4, 5)
		local all = w:getPlayers()
		T.eq(all[3].x, 1)
		T.eq(all[-1001].z, 5)
		T.truthy(all[-1001].isBot)
		T.eq(all[-1001].hp, 100)
		w:spawnPickup(50, 50, 1)
		w:spawnPickup(52, 50, 2)
		w:spawnPickup(-60, 0, 1)
		local near = w:pickupsNear(50, 50, 5)
		T.eq(#near, 2)
		T.eq(#w:pickupsNear(0, 0, 10), 0)
		T.truthy(w:useAbility(-1001, 10, 5, 0), "bots cast abilities too")
	end)

	T.it(
		"bots count fractionally toward spawn pressure; Studio test players (negative UserIds) count fully",
		function()
			local w = newWorld(19)
			w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
			w:addPlayer(-1001, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
			run(w, DT)
			T.near(w:partyWeight(), 1 + World.BOT_WEIGHT, 1e-9)
		end
	)

	T.it("rejects NaN positions and aims", function()
		local w = newWorld(20)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		w:setPlayerPosition(1, 0 / 0, 5)
		T.eq(w:getPlayer(1).x, 0)
		T.falsy(w:useAbility(1, 0 / 0, 0, 0))
		w:setPlayerPosition(1, 1e6, 0)
		T.truthy(w:getPlayer(1).x <= 120)
	end)

	T.it("clearEnemies wipes the field", function()
		local w = newWorld(21)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0)
		w:startWaves(30)
		run(w, 10)
		T.truthy(w:enemyCount() > 0)
		w:stopSpawning()
		w:clearEnemies()
		T.eq(w:enemyCount(), 0)
		T.eq(#w:snapshot(), 0)
		local _, fx = run(w, 1)
		T.eq(
			count(fx, function(f)
				return f.t == "die"
			end),
			0
		)
	end)

	T.it("every Fx event is JSON-safe (numbers, strings, booleans, plain tables)", function()
		local w = newWorld(22, { mods = Defaults.mods({ fallingRocks = true }) })
		local _, weapon, ability = Stats.compute("filet", {}, {}, nil)
		w:addPlayer(
			1,
			Defaults.stats({ chain = 2, explodeOnKill = 4 }),
			Defaults.weapon("lob"),
			Defaults.ability("field"),
			0,
			0
		)
		w:addPlayer(-1, Defaults.stats(), weapon, ability, 3, 0)
		w:startWaves(20)
		local t, fx = run(w, 15)
		w:useAbility(1, 10, 0, t)
		w:spawnBoss("serpent_sisters", 0, 20)
		local _, fx2 = run(w, 15, t)
		local function check(v: any, depth: number)
			local ty = type(v)
			T.truthy(ty == "number" or ty == "string" or ty == "boolean" or ty == "table", "bad type " .. ty)
			if ty == "number" then
				T.truthy(v == v, "NaN in fx")
			elseif ty == "table" then
				T.truthy(depth < 3)
				T.truthy(getmetatable(v) == nil)
				for k, x in v do
					T.truthy(type(k) == "string" or type(k) == "number")
					check(x, depth + 1)
				end
			end
		end
		for _, f in fx do
			check(f, 0)
		end
		for _, f in fx2 do
			check(f, 0)
		end
	end)

	T.it("perf: 220 enemies + 4 players, 600 steps at 1/30 s", function()
		local w = newWorld(23, { mods = Defaults.mods({ enemyHpMult = 400 }), arenaRadius = 140 })
		local ids = { 1, 2, -1, -2 }
		local classes = { "elephante", "ele_fonte", "filet", "fizzante" }
		for i, id in ids do
			local stats, weapon, ability = Stats.compute(classes[i], {}, {}, nil)
			w:addPlayer(id, stats, weapon, ability, (i - 2.5) * 6, 0)
			w.players[id].invulnUntil = 1e9
		end
		local rng = Rng.new(5)
		while w:enemyCount() < 220 do
			local a, d = rng:range(0, math.pi * 2), rng:range(20, 60)
			w:spawnEnemy(
				rng:pick({ "mouse", "mouse", "rat_runner", "chonk", "crumb_slinger" }),
				math.cos(a) * d,
				math.sin(a) * d,
				false
			)
		end
		w:startWaves(150)
		local t = 0
		local fxCount = 0
		local start = os.clock()
		for i = 1, 600 do
			t += DT
			for k, id in ids do
				local a = i / 60 + k
				w:setPlayerPosition(id, math.cos(a) * 15, math.sin(a) * 15)
			end
			fxCount += #w:step(DT, t)
			w:drainEvents()
		end
		local ms = (os.clock() - start) * 1000 / 600
		print(
			string.format(
				"    [perf] %.3f ms/step (%d enemies live at end, %d fx total)",
				ms,
				w:enemyCount(),
				fxCount
			)
		)
		T.truthy(w:enemyCount() <= 220, "cap held")
		T.truthy(ms < 33, "slower than real time under Lune: " .. ms)
	end)
end)

T.describe("Combat.World › fix round (QC + testing team)", function()
	local function player(w: any, id: number, x: number, z: number, stats: any?)
		w:addPlayer(id, stats or Defaults.stats(), harmless(), Defaults.ability("burst"), x, z)
	end

	T.it("setPlayerPosition pushes the centre out of rocks and returns the stored point", function()
		local w = newWorld(1) -- rock at (30, 30) r 4
		player(w, 1, 0, 0)
		local x, z = w:setPlayerPosition(1, 30.5, 30)
		T.truthy(x and z)
		T.truthy(((x :: number) - 30) ^ 2 + ((z :: number) - 30) ^ 2 >= 4 * 4 - 1e-6, "still inside the rock")
		local p = w:getPlayer(1)
		T.eq(p.x, x)
		T.eq(p.z, z)
		local nx = w:setPlayerPosition(99, 1, 1)
		T.eq(nx, nil, "unknown id")
	end)

	T.it("useAbility before the first step ignores a NaN / inf clock; step survives a NaN clock", function()
		for _, bad in { 0 / 0, math.huge, -math.huge } do
			local w = newWorld(2)
			w:addPlayer(1, Defaults.stats(), Defaults.weapon("bolt"), Defaults.ability("burst"), 0, 0)
			w:useAbility(1, 5, 5, bad)
			local a = w:getPlayer(1).abilityReadyAt
			T.truthy(a == a and a ~= math.huge and a ~= -math.huge, "abilityReadyAt " .. tostring(a))
		end
		local w = newWorld(3)
		player(w, 1, 0, 0)
		w:step(DT, 10)
		w:step(DT, 0 / 0)
		T.truthy(w.now == w.now and w.now > 10, "clock kept moving: " .. tostring(w.now))
	end)

	T.it("one merged damage number per enemy per step", function()
		local w = newWorld(4)
		player(w, 1, 0, 0)
		w:step(DT, 1)
		local e = w:spawnEnemy("chonk", 20, 0, false)
		w.fx = {}
		w:damageEnemy(e, 3, nil, false)
		w:damageEnemy(e, 4, nil, true)
		w:damageEnemy(e, 5, nil, false)
		local hits = {}
		for _, f in w.fx do
			if f.t == "hit" then
				table.insert(hits, f)
			end
		end
		T.eq(#hits, 1)
		T.eq(hits[1].amount, 12)
		T.eq(hits[1].crit, true)
		T.eq(hits[1].id, e.id)
		-- the next step starts fresh numbers
		local out = w:step(DT, 1 + DT)
		w:damageEnemy(e, 2, nil, false)
		local fresh = 0
		for _, f in w.fx do
			if f.t == "hit" then
				fresh += 1
			end
		end
		T.eq(fresh, 1)
		T.truthy(out ~= w.fx)
	end)

	T.it("boss loot crumbs (vacuum) split their XP evenly across standing participants", function()
		local w = newWorld(5)
		player(w, 1, 0, 0)
		player(w, -1001, 10, 0)
		player(w, -1002, -10, 0)
		w:step(DT, 1)
		local boss = w:spawnBoss("froggus", 0, 30)
		boss.introUntil = 0
		w:drainEvents()
		w:damageEnemy(boss, boss.hp + 1, nil)
		local xp: { [number]: number } = {}
		local t = 1
		for _ = 1, 300 do
			t += DT
			w:step(DT, t)
			for _, ev in w:drainEvents() do
				if ev.type == "xp" then
					xp[ev.id] = (xp[ev.id] or 0) + ev.amount
				end
			end
		end
		T.eq(w:pickupCount(), 0, "every crumb collected")
		local a, b, c = xp[1] or 0, xp[-1001] or 0, xp[-1002] or 0
		T.truthy(a > 0, "human got xp")
		T.near(a, b, 1e-6, "human vs bot 1")
		T.near(a, c, 1e-6, "human vs bot 2")
	end)

	T.it("a boss alive for BOSS_ENRAGE_AFTER enrages once: faster, shorter gaps, Fx + event", function()
		local w = newWorld(6)
		player(w, 1, 0, 0, (function()
			local st = Defaults.stats()
			st.maxHp = 1e9
			return st
		end)())
		w:step(DT, 100)
		local boss = w:spawnBoss("giant_tree", 0, 40)
		local speed0, gap0 = boss.speed, boss.gap
		w:drainEvents()
		local _, fx = run(w, World.BOSS_ENRAGE_AFTER - 1)
		T.eq(count(fx, function(f)
			return f.t == "enrage"
		end), 0, "not yet")
		T.eq(boss.enraged, false)
		local _, fx2 = run(w, 2)
		local enr = {}
		for _, f in fx2 do
			if f.t == "enrage" then
				table.insert(enr, f)
			end
		end
		T.eq(#enr, 1)
		T.eq(enr[1].id, boss.id)
		T.truthy(type(enr[1].x) == "number" and type(enr[1].z) == "number")
		T.near(boss.speed, speed0 * World.ENRAGE_SPEED_MULT)
		T.truthy(boss.gap < gap0)
		T.eq(#eventsOf(w, "bossEnrage"), 1)
		T.eq(w:bossInfo().enraged, true)
		local _, fx3 = run(w, 5)
		T.eq(count(fx3, function(f)
			return f.t == "enrage"
		end), 0, "only once")
	end)

	T.it("bossSpawnPoint: near the party, toward the centre, never inside a rock", function()
		local w = newWorld(7, { obstacles = { { x = 60, z = 0, r = 6 } } })
		player(w, 1, 100, 0)
		player(w, 2, 100, 4)
		local x, z = w:bossSpawnPoint(5)
		local d = math.sqrt((x - 100) ^ 2 + (z - 2) ^ 2)
		T.truthy(d >= World.BOSS_SPAWN_DIST - 12 and d <= World.BOSS_SPAWN_DIST + 12, "distance " .. d)
		T.truthy(x < 100, "toward the centre")
		T.truthy((x - 60) ^ 2 + z ^ 2 >= (6 + 6) ^ 2 - 1e-6, "inside the rock")
		local w2 = newWorld(8, { obstacles = {} })
		player(w2, 1, 5, 5)
		local cx, cz = w2:bossSpawnPoint(5)
		T.eq(cx, 0)
		T.eq(cz, 0)
	end)
end)

return T.finish()
