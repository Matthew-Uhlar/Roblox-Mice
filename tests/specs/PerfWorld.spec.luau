--!strict
-- Performance (Testing team): a 300 s wave with 4 participants pinned at the
-- 220-enemy cap. Budget under Lune: average step < 5 ms, worst step < 25 ms.
-- Also measures snapshot bandwidth at 15 Hz and 10 Hz, Fx volume, and the cost
-- of BotBrain:think on a full horde.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local SnapshotCodec = require("../../src/shared/Combat/SnapshotCodec")
local Stats = require("../../src/shared/Run/Stats")
local BotBrain = require("../../src/shared/Bots/BotBrain")
local Ids = require("../../src/shared/Util/Ids")
local serde = (require :: any)("@lune/serde")

local DT = 1 / 30
local SECONDS = 300
local AVG_BUDGET_MS = 5
local MAX_BUDGET_MS = 25

T.describe("Perf › World at the enemy cap", function()
	local result: any = nil

	local function run()
		if result then
			return result
		end
		local mods = Stats.worldMods(2, 4, {}, 4)
		mods.spawnRateMult *= 6 -- pin the horde at the cap for the whole wave
		local w = World.new({
			rng = Rng.new(2026),
			mods = mods,
			arenaRadius = 140,
			obstacles = { { x = 40, z = 40, r = 5 }, { x = -50, z = 20, r = 4 }, { x = 10, z = -70, r = 5 } },
			enemyPool = { "mouse", "rat_runner", "chonk", "crumb_slinger", "fuse_mouse" },
			cycle = 2,
			stage = 4,
		})
		local classes = { "fizzante", "filet", "ele_fonte", "elephante" }
		local ids = { 1, 2, Ids.botId(1), Ids.botId(2) }
		for i, classId in classes do
			-- Mid-run builds: more projectiles, chain, explode-on-kill, orbiters.
			local stats, weapon, ability = Stats.compute(classId, {}, {}, nil)
			stats.projectileBonus = 2
			stats.chain = 1
			stats.explodeOnKill = 4
			stats.extraOrbiters = 2
			stats.maxHp = 1e5
			stats.regen = 500
			w:addPlayer(ids[i], stats, weapon, ability, i * 4, 0)
		end
		w:startWaves(SECONDS)

		local now = 0
		local steps = math.floor(SECONDS / DT + 0.5)
		local times = table.create(steps, 0)
		local total, worst = 0, 0
		local atCap, enemySum = 0, 0
		local snap15, snap10, n15, n10 = 0, 0, 0, 0
		local chunks15 = 0
		local fxCount, fxBytes = 0, 0
		for i = 1, steps do
			-- Players circle the arena (the horde follows) and cast abilities.
			local t = i * DT
			for k, id in ids do
				local a = t * 0.15 + k * math.pi / 2
				w:setPlayerPosition(id, math.cos(a) * 60 + math.cos(t * 2 + k) * 6, math.sin(a) * 60)
				if i % 90 == k * 10 then
					w:useAbility(id, math.cos(a) * 70, math.sin(a) * 70, now)
				end
			end
			now += DT
			local t0 = os.clock()
			local fx = w:step(DT, now)
			local ms = (os.clock() - t0) * 1000
			w:drainEvents()
			w:drainTeleports()
			times[i] = ms
			total += ms
			worst = math.max(worst, ms)
			local n = w:enemyCount()
			enemySum += n
			if n >= w.cap then
				atCap += 1
			end
			fxCount += #fx
			if i % 30 == 0 and #fx > 0 then
				fxBytes += #serde.encode("json", fx) * 30 -- sampled once a second
			end
			-- 15 Hz = every 2nd step, 10 Hz = every 3rd step.
			if i % 2 == 0 then
				local chunks = SnapshotCodec.encodeChunks(w:snapshot(), now)
				for _, c in chunks do
					snap15 += buffer.len(c)
				end
				chunks15 += #chunks
				n15 += 1
			end
			if i % 3 == 0 then
				for _, c in SnapshotCodec.encodeChunks(w:snapshot(), now) do
					snap10 += buffer.len(c)
				end
				n10 += 1
			end
		end
		table.sort(times)
		result = {
			world = w,
			steps = steps,
			avg = total / steps,
			max = worst,
			p50 = times[math.floor(steps * 0.5)],
			p99 = times[math.floor(steps * 0.99)],
			atCapFrac = atCap / steps,
			avgEnemies = enemySum / steps,
			bps15 = snap15 / SECONDS,
			bps10 = snap10 / SECONDS,
			chunksPerSnap = chunks15 / n15,
			fxPerSec = fxCount / SECONDS,
			fxBytesPerSec = fxBytes / SECONDS,
			n15 = n15,
			n10 = n10,
		}
		print(
			string.format(
				"\n  [perf] %d steps, enemies avg %.0f (at cap %.0f%% of steps)\n"
					.. "  [perf] step ms: avg %.3f  p50 %.3f  p99 %.3f  max %.3f\n"
					.. "  [perf] snapshots: %.0f B/s at 15 Hz (%.1f chunks each), %.0f B/s at 10 Hz\n"
					.. "  [perf] fx: %.0f events/s, ~%.0f B/s as JSON (per client, before Roblox overhead)",
				steps,
				result.avgEnemies,
				result.atCapFrac * 100,
				result.avg,
				result.p50,
				result.p99,
				result.max,
				result.bps15,
				result.chunksPerSnap,
				result.bps10,
				result.fxPerSec,
				result.fxBytesPerSec
			)
		)
		return result
	end

	T.it("holds the horde at the 220 cap for most of the wave", function()
		local r = run()
		T.eq(r.world.cap, 220)
		T.truthy(r.atCapFrac > 0.6, string.format("at cap only %.0f%% of steps", r.atCapFrac * 100))
	end)
	T.it("average step time < " .. AVG_BUDGET_MS .. " ms", function()
		local r = run()
		T.truthy(r.avg < AVG_BUDGET_MS, string.format("avg %.3f ms", r.avg))
	end)
	T.it("worst step time < " .. MAX_BUDGET_MS .. " ms", function()
		local r = run()
		T.truthy(r.max < MAX_BUDGET_MS, string.format("max %.3f ms", r.max))
	end)
	T.it("snapshot bandwidth: 10 Hz is ~2/3 of 15 Hz and every chunk fits 850 B", function()
		local r = run()
		T.near(r.bps10 / r.bps15, 2 / 3, 0.05)
		T.truthy(r.chunksPerSnap <= 3)
	end)
end)

T.describe("Perf › BotBrain on a full horde", function()
	T.it("think() with 220 enemies costs < 1 ms", function()
		local rng = Rng.new(5)
		local enemies = {}
		for i = 1, 220 do
			table.insert(
				enemies,
				{ id = i, kind = 1, x = rng:range(-60, 60), z = rng:range(-60, 60), hpFrac = 1, flags = 0 }
			)
		end
		local allies = {
			{ id = 1, x = 0, z = 0, downed = false, isBot = false },
			{ id = Ids.botId(1), x = 3, z = 3, downed = false, isBot = true },
		}
		local brain = BotBrain.new(Ids.botId(1), "fizzante", rng)
		local view = {
			self = { x = 3, z = 3, hp = 50, maxHp = 100, downed = false, abilityReady = true },
			allies = allies,
			enemies = enemies,
			pickups = {},
			arenaRadius = 140,
			obstacles = {},
			now = 0,
		}
		local n = 300
		local t0 = os.clock()
		for _ = 1, n do
			brain:think(view, 0.1)
		end
		local ms = (os.clock() - t0) * 1000 / n
		print(string.format("  [perf] BotBrain:think with 220 enemies: %.3f ms", ms))
		T.truthy(ms < 1, string.format("%.3f ms", ms))
	end)
end)

return T.finish()
