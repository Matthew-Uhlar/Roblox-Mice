local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local WaveDirector = require("../../src/shared/Combat/WaveDirector")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local Stats = require("../../src/shared/Run/Stats")

local OBST = { { x = 50, z = 0, r = 8 }, { x = -30, z = 40, r = 6 }, { x = 0, z = -55, r = 10 } }

local function wd(extra: { [string]: any }?): any
	local o: any = {
		rng = Rng.new(1),
		enemyPool = { "mouse", "rat_runner", "chonk", "crumb_slinger", "fuse_mouse" },
		cycle = 1,
		stage = 1,
		mods = Defaults.mods(),
		arenaRadius = 140,
		obstacles = OBST,
	}
	for k, v in extra or {} do
		o[k] = v
	end
	return WaveDirector.new(o)
end

T.describe("Combat.WaveDirector", function()
	T.it("budget ramps over the wave duration and holds after", function()
		local d = wd()
		d:start(150)
		local r0 = d:rate(1)
		d.elapsed = 75
		local r1 = d:rate(1)
		d.elapsed = 150
		local r2 = d:rate(1)
		d.elapsed = 400
		T.truthy(r0 < r1 and r1 < r2, string.format("%.2f %.2f %.2f", r0, r1, r2))
		T.near(d:rate(1), r2, 1e-9)
		T.truthy(r2 / r0 > 3)
	end)

	T.it("scales with cycle, stage, (fractional) party size and spawnRateMult", function()
		local base = wd()
		local function r(x: any, n: number?): number
			x:start(150)
			return x:rate(n or 1)
		end
		local b = r(base)
		T.truthy(r(wd({ cycle = 2 })) > b)
		T.truthy(r(wd({ stage = 3 })) > b)
		T.truthy(r(wd(), 1.6) > b, "1 human + 1 bot")
		T.truthy(r(wd(), 2) > r(wd(), 1.6))
		T.near(r(wd({ mods = Defaults.mods({ spawnRateMult = 2 }) })), b * 2, 1e-9)
	end)

	T.it("spawns outside every player's view, inside the arena, clear of obstacles", function()
		local d = wd()
		local players = { { x = 0, z = 0 }, { x = 20, z = 10 } }
		for _ = 1, 300 do
			local x, z = d:pickSpawnPoint(players)
			T.truthy(x * x + z * z <= (140 - WaveDirector.EDGE_MARGIN) ^ 2, "inside arena")
			for _, o in OBST do
				T.truthy(
					(x - o.x) ^ 2 + (z - o.z) ^ 2 >= (o.r + WaveDirector.OBSTACLE_MARGIN) ^ 2,
					"clear of obstacle"
				)
			end
			for _, p in players do
				T.truthy((x - p.x) ^ 2 + (z - p.z) ^ 2 >= (WaveDirector.VIEW_RADIUS * 0.9) ^ 2, "off-screen")
			end
		end
	end)

	T.it("falls back to legal spots on a small arena", function()
		local d = wd({ arenaRadius = 40, obstacles = { { x = 30, z = 0, r = 5 } } })
		for _ = 1, 200 do
			local x, z = d:pickSpawnPoint({ { x = 0, z = 0 } })
			T.truthy(x * x + z * z <= (40 - WaveDirector.EDGE_MARGIN) ^ 2)
			T.truthy((x - 30) ^ 2 + z ^ 2 >= 7 ^ 2)
		end
	end)

	T.it("no elites on the first stage of a run; elites later with eliteChance", function()
		local d = wd({ mods = Defaults.mods({ eliteChance = 1 }) })
		d:start(60)
		for _ = 1, 300 do
			for _, r in d:update(1 / 30, 0, { { x = 0, z = 0 } }) do
				T.falsy(r.elite)
			end
		end
		local d2 = wd({ stage = 2, mods = Defaults.mods({ eliteChance = 1 }) })
		d2:start(60)
		local elites = 0
		for _ = 1, 300 do
			for _, r in d2:update(1 / 30, 0, { { x = 0, z = 0 } }) do
				if r.elite and not r.surge then
					elites += 1
				end
			end
		end
		T.truthy(elites > 0)
	end)

	T.it("filters unknown enemy ids and unlocks tougher mice over time", function()
		local d = wd({ enemyPool = { "mouse", "dragon_mouse", "chonk" } })
		T.eq(#d.pool, 2)
		d:start(100)
		for _ = 1, 50 do
			T.eq(d:pickKind(), "mouse", "chonk is locked at the start")
		end
		d.elapsed = 90
		local saw = false
		for _ = 1, 200 do
			saw = saw or d:pickKind() == "chonk"
		end
		T.truthy(saw)
		T.eq(wd({ enemyPool = { "nope" } }).pool[1], "mouse")
	end)

	T.it("stop() halts spawning", function()
		local d = wd()
		d:start(60)
		d:stop()
		T.eq(#d:update(1, 0, { { x = 0, z = 0 } }), 0)
	end)

	T.it("World never exceeds the live-enemy cap (custom cap 60) and spawns go ring-side", function()
		local w = World.new({
			rng = Rng.new(5),
			mods = Stats.worldMods(3, 4, {}, 4),
			arenaRadius = 140,
			obstacles = OBST,
			enemyPool = { "mouse", "rat_runner" },
			cycle = 3,
			stage = 4,
			enemyCap = 60,
		})
		local harmless = Defaults.weapon("bolt")
		harmless.damage = 0
		-- v4: 3 heroes, so the per-hero soft cap (28 x 3) is above the custom cap
		for id = 1, 3 do
			w:addPlayer(id, Defaults.stats(), harmless, Defaults.ability("burst"), id - 2, 0)
			w.players[id].invulnUntil = 1e9
		end
		w:startWaves(60)
		local t, maxSeen, first = 0, 0, true
		for _ = 1, 1800 do
			t += 1 / 30
			local before = {}
			for _, e in w.enemies do
				before[e] = true
			end
			w:step(1 / 30, t)
			for _, e in w.enemies do
				if not before[e] and first then
					T.truthy(
						math.sqrt(e.x ^ 2 + e.z ^ 2) >= WaveDirector.VIEW_RADIUS * 0.8,
						"spawned off-screen"
					)
				end
			end
			maxSeen = math.max(maxSeen, w:enemyCount())
		end
		T.eq(maxSeen, 60)
	end)

	T.it("v4: the World's global cap is 300 (the director's own default stays 220)", function()
		T.eq(WaveDirector.DEFAULT_CAP, 220)
		T.eq(World.DEFAULT_CAP, 300)
		T.eq(WaveDirector.PER_HERO_CAP, 28)
	end)

	T.it("v4 per hero: 0.9/s per hero ramping x3.2; the v1 budget with perHero = false", function()
		local d = wd()
		d:start(150)
		T.near(d:rate(1), WaveDirector.PER_HERO_RATE, 1e-9)
		T.near(d:rate(12), WaveDirector.PER_HERO_RATE * 12, 1e-9)
		d.elapsed = 150
		T.near(d:rate(1), WaveDirector.PER_HERO_RATE * WaveDirector.PER_HERO_RAMP, 1e-9)
		local old = wd({ perHero = false })
		old:start(150)
		T.near(old:rate(1), WaveDirector.BASE_RATE, 1e-9)
	end)

	T.it("v4 per hero: live mice stay under 28 per standing hero; first spawns come at once", function()
		local d = wd({ cap = 300 })
		d:start(150)
		local players = { { x = 0, z = 0 }, { x = 30, z = 0 } }
		local first = d:update(1 / 30, 0, players)
		T.truthy(#first >= WaveDirector.START_PER_HERO * 2, "seeded " .. #first)
		T.eq(#d:update(1, 2 * WaveDirector.PER_HERO_CAP, players), 0, "at 28 per hero")
		local live = 2 * WaveDirector.PER_HERO_CAP - 3
		d.budget = 50
		T.truthy(#d:update(1 / 30, live, players) <= 3)
	end)

	T.it("v4: spawn anchors prefer heroes with few mice on screen", function()
		local d = wd({ arenaRadius = 400, obstacles = {} })
		local crowded = { x = -150, z = 0, nearMice = 40 }
		local empty = { x = 150, z = 0, nearMice = 0 }
		local nearEmpty = 0
		for _ = 1, 200 do
			local x = d:pickSpawnPoint({ crowded, empty })
			if x > 0 then
				nearEmpty += 1
			end
		end
		T.truthy(nearEmpty > 150, "near the empty hero " .. nearEmpty .. "/200")
	end)

	T.it("v4: no spawn outside the storm circle", function()
		local w = World.new({
			rng = Rng.new(9),
			mods = Defaults.mods(),
			arenaRadius = 300,
			obstacles = {},
			enemyPool = { "mouse" },
		})
		local harmless = Defaults.weapon("bolt")
		harmless.damage = 0
		for id = 1, 4 do
			w:addPlayer(id, Defaults.stats({ maxHp = 1e6 }), harmless, Defaults.ability("burst"), id * 5, 0)
		end
		w:startWaves(60)
		w:setZone({ cx = 20, cz = 0, r = 80, toR = 80, closeStart = 0, closeEnd = 0, dps = 0 })
		local t = 0
		for _ = 1, 600 do
			t += 1 / 30
			w:step(1 / 30, t)
			for _, e in w.enemies do
				if e.alive then
					T.truthy((e.x - 20) ^ 2 + e.z ^ 2 <= 80 * 80, "inside the circle")
				end
			end
		end
		T.truthy(w:enemyCount() > 20)
	end)
end)

return T.finish()
