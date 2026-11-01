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
				T.truthy((x - o.x) ^ 2 + (z - o.z) ^ 2 >= (o.r + WaveDirector.OBSTACLE_MARGIN) ^ 2, "clear of obstacle")
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
		w:addPlayer(1, Defaults.stats(), harmless, Defaults.ability("burst"), 0, 0)
		w.players[1].invulnUntil = 1e9
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
					T.truthy(math.sqrt(e.x ^ 2 + e.z ^ 2) >= WaveDirector.VIEW_RADIUS * 0.8, "spawned off-screen")
				end
			end
			maxSeen = math.max(maxSeen, w:enemyCount())
		end
		T.eq(maxSeen, 60)
	end)

	T.it("default cap is 220", function()
		T.eq(WaveDirector.DEFAULT_CAP, 220)
		T.eq(World.DEFAULT_CAP, 220)
	end)
end)

return T.finish()
