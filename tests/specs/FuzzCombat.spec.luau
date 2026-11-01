--!strict
-- Fuzz tests for the combat simulation (Testing team): garbage positions / aims,
-- players removed mid-fight, empty and all-bot worlds, the enemy cap and the
-- snapshot codec. Nothing may throw, and no NaN/inf may reach a snapshot or Fx.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local Ids = require("../../src/shared/Util/Ids")
local World = require("../../src/shared/Combat/World")
local SnapshotCodec = require("../../src/shared/Combat/SnapshotCodec")
local Stats = require("../../src/shared/Run/Stats")
local Classes = require("../../src/shared/Config/Classes")
local Bosses = require("../../src/shared/Config/Bosses")
local Enemies = require("../../src/shared/Config/Enemies")

local DT = 1 / 30
local NAN = 0 / 0
local INF = math.huge
local BAD = { NAN, INF, -INF, 1e300, -1e300, 1e15, -1e15, 2 ^ 31, 0, -0.0, 1e-300 }
local POOL = { "mouse", "rat_runner", "chonk", "crumb_slinger", "fuse_mouse" }

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= INF and v ~= -INF
end

local function newWorld(seed: number, extra: { [string]: any }?): any
	local o: any = {
		rng = Rng.new(seed),
		mods = Stats.worldMods(1, 2, {}, 3),
		arenaRadius = 120,
		obstacles = { { x = 30, z = 30, r = 4 }, { x = -40, z = 10, r = 6 } },
		enemyPool = POOL,
		cycle = 1,
		stage = 2,
	}
	for k, v in extra or {} do
		o[k] = v
	end
	return World.new(o)
end

local function addClass(w: any, id: number, classId: string, x: number, z: number, tank: boolean?)
	local stats, weapon, ability = Stats.compute(classId, {}, {}, nil)
	if tank then
		stats.maxHp = 100000
		stats.regen = 1000
	end
	w:addPlayer(id, stats, weapon, ability, x, z)
end

-- Every number in an Fx / snapshot list is finite (recursive).
local function checkFinite(list: { any }, what: string)
	local function walk(v: any, path: string)
		if type(v) == "number" then
			if not finite(v) then
				error(string.format("%s: non-finite %s at %s", what, tostring(v), path), 0)
			end
		elseif type(v) == "table" then
			for k, x in v do
				walk(x, path .. "." .. tostring(k))
			end
		end
	end
	for i, item in list do
		walk(item, (if type(item) == "table" and item.t then item.t else "#") .. "[" .. i .. "]")
	end
end

local function checkSnapshot(w: any, what: string)
	local snaps = w:snapshot()
	checkFinite(snaps, what .. " snapshot")
	for _, s in snaps do
		T.truthy(s.hpFrac >= 0 and s.hpFrac <= 1, what .. ": hpFrac in 0..1")
		T.truthy(s.x * s.x + s.z * s.z <= (w.arenaRadius + 1) ^ 2, what .. ": enemy inside the arena")
	end
	-- Codec round trip of real snapshots: 1/8 stud, 1/255 hp.
	local _, back = SnapshotCodec.decode(SnapshotCodec.encode(snaps, w.now))
	T.eq(#back, #snaps)
	for i, s in snaps do
		local b = back[i]
		T.eq(b.id, s.id)
		T.eq(b.kind, s.kind)
		T.truthy(math.abs(b.x - s.x) <= 1 / 16 + 1e-9 and math.abs(b.z - s.z) <= 1 / 16 + 1e-9, "codec position")
		T.truthy(math.abs(b.hpFrac - s.hpFrac) <= 1 / 510 + 1e-9, "codec hp")
		T.eq(b.flags, s.flags)
	end
	return snaps
end

local function checkPlayers(w: any, what: string)
	for id, p in w:getPlayers() do
		T.truthy(finite(p.x) and finite(p.z) and finite(p.hp) and finite(p.maxHp), what .. ": player " .. id .. " finite")
		T.truthy(p.x * p.x + p.z * p.z <= w.arenaRadius ^ 2 + 1e-6, what .. ": player " .. id .. " in arena")
		T.truthy(finite(p.abilityReadyAt), what .. ": abilityReadyAt finite for " .. id)
	end
end

local function step(w: any, now: number): (number, { any })
	now += DT
	local fx = w:step(DT, now)
	w:drainEvents()
	w:drainTeleports()
	return now, fx
end

T.describe("Fuzz › garbage positions and aims", function()
	T.it("NaN/inf/huge into setPlayerPosition and useAbility for every class", function()
		local rng = Rng.new(42)
		local w = newWorld(1, { mods = Stats.worldMods(1, 3, {}, 4) })
		for i, classId in Classes.ORDER do
			addClass(w, i, classId, (i - 4) * 5, 10, true)
		end
		w:startWaves(60)
		local now = 500
		for tick = 1, 1800 do
			for i = 1, #Classes.ORDER do
				local r = rng:nextInt(1, 6)
				if r == 1 then
					w:setPlayerPosition(i, rng:pick(BAD), rng:pick(BAD))
				elseif r == 2 then
					w:setPlayerPosition(i, rng:range(-500, 500), rng:pick(BAD))
				else
					w:setPlayerPosition(i, rng:range(-130, 130), rng:range(-130, 130))
				end
				if rng:chance(0.2) then
					w.players[i].abilityReadyAt = 0 -- exercise the ability as often as possible
					local ax = if rng:chance(0.5) then rng:pick(BAD) else rng:range(-1e6, 1e6)
					local az = if rng:chance(0.5) then rng:pick(BAD) else rng:range(-1e6, 1e6)
					w:useAbility(i, ax, az, now)
				end
			end
			local fx
			now, fx = step(w, now)
			checkFinite(fx, "tick " .. tick .. " fx")
			if tick % 30 == 0 then
				checkSnapshot(w, "tick " .. tick)
				checkPlayers(w, "tick " .. tick)
			end
		end
		T.truthy(w:enemyCount() > 0, "waves spawned")
	end)

	-- [BUG] src/shared/Combat/World.luau:384 uses the caller's `now` before the first
	-- step without a finite check: abilityReadyAt becomes NaN (cooldown never applies
	-- again) or inf (ability locked forever). Left failing on purpose.
	T.it("[BUG World:384] useAbility before the first step with a NaN / inf clock does not poison the cooldown", function()
		for _, bad in { NAN, INF, -INF } do
			local w = newWorld(2)
			addClass(w, 1, "ele_fonte", 0, 0)
			w:useAbility(1, 5, 5, bad)
			local p = w:getPlayer(1)
			T.truthy(finite(p.abilityReadyAt), "abilityReadyAt after useAbility(now=" .. tostring(bad) .. ")")
		end
	end)

	T.it("garbage dt and a clock that jumps backwards", function()
		local w = newWorld(3)
		addClass(w, 1, "fizzante", 0, 0, true)
		addClass(w, 2, "filet", 5, 0, true)
		w:startWaves(30)
		local now = 100
		local rng = Rng.new(3)
		for tick = 1, 900 do
			local dt = if tick % 7 == 0 then rng:pick({ NAN, INF, -1, 0, 5, 1e9 }) else DT
			now += if tick % 50 == 0 then -0.2 else DT
			local fx = w:step(dt, now)
			checkFinite(fx, "fx")
			w:drainEvents()
		end
		checkSnapshot(w, "end")
		checkPlayers(w, "end")
	end)
end)

T.describe("Fuzz › players leaving mid-fight", function()
	T.it("random remove / re-add during waves and every boss fight", function()
		local rng = Rng.new(11)
		for b, bossId in Bosses.ORDER do
			local w = newWorld(100 + b)
			local ids = { 1, 2, Ids.botId(1), Ids.botId(2) }
			local classes = { "filet", "fizzante", "ele_fonte", "elephante" }
			for i, id in ids do
				addClass(w, id, classes[i], i * 3, 0)
			end
			w:startWaves(20)
			local now = 0
			for tick = 1, 600 do
				if tick == 300 then
					w:stopSpawning()
					w:clearEnemies()
					w:spawnBoss(bossId, 0, 0)
				end
				if rng:chance(0.03) then
					local i = rng:nextInt(1, #ids)
					if w.players[ids[i]] then
						w:removePlayer(ids[i])
					else
						addClass(w, ids[i], classes[i], rng:range(-50, 50), rng:range(-50, 50))
					end
				end
				if rng:chance(0.05) then
					local i = rng:nextInt(1, #ids)
					w:useAbility(ids[i], rng:range(-60, 60), rng:range(-60, 60), now)
				end
				local fx
				now, fx = step(w, now)
				checkFinite(fx, bossId .. " fx")
			end
			-- Everyone leaves while the boss is mid-pattern.
			for _, id in ids do
				w:removePlayer(id)
			end
			for _ = 1, 150 do
				now = step(w, now)
			end
			T.falsy(w:allPlayersDown(), "an empty world is not a wipe")
			checkSnapshot(w, bossId)
		end
	end)

	T.it("removing a downed player and the crumb target keeps the world consistent", function()
		local w = newWorld(5)
		addClass(w, 1, "ele_fonte", 0, 0)
		addClass(w, 2, "elephante", 3, 0)
		w:startWaves(30)
		local now = 0
		for _ = 1, 300 do
			now = step(w, now)
		end
		w.players[1].iframeUntil = 0
		w.players[1].invulnUntil = 0
		w:damagePlayer(w.players[1], 1e9, "test")
		T.truthy(w:getPlayer(1).downed)
		w:removePlayer(1)
		T.eq(w:getPlayer(1), nil)
		for _ = 1, 300 do
			now = step(w, now)
		end
		for _, c in w.pickups do
			T.truthy(c.target ~= 1, "no crumb targets a removed player")
		end
		T.eq(#w.playerList, 1)
	end)
end)

T.describe("Fuzz › degenerate parties", function()
	T.it("0-player world: waves, a boss and every query run without throwing", function()
		for b, bossId in Bosses.ORDER do
			local w = newWorld(200 + b)
			w:startWaves(10)
			local now = 0
			for _ = 1, 300 do
				now = step(w, now)
			end
			w:spawnBoss(bossId, 0, 0)
			for _ = 1, 300 do
				now = step(w, now)
			end
			T.falsy(w:allPlayersDown())
			T.eq(w:partyWeight(), 0)
			T.deepEq(w:getPlayers(), {})
			checkSnapshot(w, "empty " .. bossId)
			w:respawnDead(0.5)
			T.eq(w:useAbility(1, 0, 0, now), false)
			T.eq(w:useSecondWind(1), false)
			w:setPlayerPosition(1, 0, 0)
			w:updatePlayer(1, Stats.DEFAULT, Classes.get("elephante").weapon)
			w:removePlayer(1)
		end
	end)

	T.it("all-bot world: bot ids weigh 0.6, Studio ids (-1..-8) weigh 1", function()
		local w = newWorld(7)
		for n = 1, 4 do
			addClass(w, Ids.botId(n), "ele_fonte", n * 3, 0)
		end
		local now = step(w, 0)
		T.near(w:partyWeight(), 4 * World.BOT_WEIGHT, 1e-9)
		for _, p in w:getPlayers() do
			T.eq(p.isBot, true)
		end
		w:startWaves(60)
		for _ = 1, 900 do
			now = step(w, now)
		end
		checkSnapshot(w, "all-bot")
		local s = newWorld(8)
		for n = 1, 8 do
			addClass(s, -n, "ele_fonte", n * 3, 0)
		end
		step(s, 0)
		T.near(s:partyWeight(), 8, 1e-9, "Studio test players are humans")
		for _, p in s:getPlayers() do
			T.eq(p.isBot, false)
		end
	end)

	T.it("an all-downed party is a wipe; dead + downed too", function()
		local w = newWorld(9)
		addClass(w, Ids.botId(1), "ele_fonte", 0, 0)
		addClass(w, 1, "ele_fonte", 3, 0)
		local now = step(w, 0)
		w:damagePlayer(w.players[1], 1e9)
		T.falsy(w:allPlayersDown())
		w.players[Ids.botId(1)].iframeUntil = 0
		w:damagePlayer(w.players[Ids.botId(1)], 1e9)
		T.truthy(w:allPlayersDown())
		for _ = 1, math.ceil(World.DOWNED_TIME / DT) + 2 do
			now = step(w, now)
		end
		T.truthy(w:getPlayer(1).dead)
		T.truthy(w:allPlayersDown())
		w:respawnDead(0.5)
		T.falsy(w:allPlayersDown())
		T.near(w:getPlayer(1).hp, w:getPlayer(1).maxHp * 0.5, 1e-6)
	end)
end)

T.describe("Fuzz › enemy cap", function()
	for _, cap in { 30, World.DEFAULT_CAP } do
		T.it("live enemies never exceed the cap (" .. cap .. ") under a 40x spawn rate", function()
			local mods = Stats.worldMods(3, 4, {}, 4)
			mods.spawnRateMult *= 40
			local w = newWorld(cap, { mods = mods, enemyCap = if cap == World.DEFAULT_CAP then nil else cap })
			for i = 1, 4 do
				addClass(w, i, Classes.ORDER[i], i * 4, 0, true)
			end
			w:startWaves(60)
			local now, peak = 0, 0
			for tick = 1, 1800 do
				now = step(w, now)
				local n = w:enemyCount()
				peak = math.max(peak, n)
				T.truthy(n <= cap, "live " .. n .. " > cap " .. cap .. " at tick " .. tick)
				if tick % 60 == 0 then
					T.truthy(#w:snapshot() <= cap)
				end
			end
			T.eq(peak, cap, "the cap is actually reached")
			-- A boss spawned at the cap still appears; its summons respect the cap.
			w:stopSpawning()
			w:spawnBoss("giant_tree", 0, 0)
			w.forcePattern = "sapling_summon"
			for _ = 1, 600 do
				now = step(w, now)
				local minions = 0
				for _, e in w.enemies do
					if e.alive and e.isMinion then
						minions += 1
					end
				end
				T.truthy(w:enemyCount() <= cap + 1 + minions, "boss phase: " .. w:enemyCount())
			end
			T.truthy(w:bossAlive() or w:bossInfo() == nil)
		end)
	end
end)

T.describe("Fuzz › SnapshotCodec", function()
	T.it("round-trips clamped extremes without NaN", function()
		local snaps: { any } = {
			{ id = 1, kind = 1, x = 1e9, z = -1e9, hpFrac = 2, flags = 0 },
			{ id = 65535, kind = 255, x = INF, z = -INF, hpFrac = -1, flags = 255 },
			{ id = 2, kind = 2, x = NAN, z = NAN, hpFrac = NAN, flags = 3 },
			{ id = 3, kind = 213, x = 4095.875, z = -4096, hpFrac = 0.5, flags = 8 },
			{ id = 70000, kind = 300, x = 12.3, z = -7.77, hpFrac = 1, flags = 1000 },
			{ id = -5, kind = -1, x = -0.0, z = 1e-300, hpFrac = INF, flags = -3 },
		}
		local t, back = SnapshotCodec.decode(SnapshotCodec.encode(snaps, 123.25))
		T.eq(t, 123.25)
		T.eq(#back, #snaps)
		checkFinite(back, "decoded")
		local function exp(v: number): number
			local n = math.floor(v * 8 + 0.5)
			if n ~= n then
				return 0
			end
			return math.clamp(n, -32768, 32767) / 8
		end
		for i, s in snaps do
			local b = back[i]
			T.eq(b.x, exp(s.x), "x #" .. i)
			T.eq(b.z, exp(s.z), "z #" .. i)
			T.truthy(b.hpFrac >= 0 and b.hpFrac <= 1)
			T.truthy(b.id >= 0 and b.id <= 65535 and b.kind >= 0 and b.kind <= 255)
		end
		T.eq(back[1].x, 32767 / 8)
		T.eq(back[1].z, -4096)
		T.eq(back[1].hpFrac, 1)
		T.eq(back[2].hpFrac, 0)
		T.eq(back[3].x, 0)
		T.eq(back[3].hpFrac, 0)
		T.eq(back[5].id, 65535)
		T.eq(back[5].kind, 255)
		T.eq(back[5].flags, 255)
		T.eq(back[6].id, 0)
	end)

	T.it("NaN ids / kinds / flags do not throw", function()
		local ok, err = pcall(function()
			local _, back = SnapshotCodec.decode(
				SnapshotCodec.encode({ { id = NAN, kind = NAN, x = 0, z = 0, hpFrac = 1, flags = NAN } } :: any, 0)
			)
			checkFinite(back, "decoded")
		end)
		T.truthy(ok, tostring(err))
	end)

	T.it("chunks a full horde under 850 bytes per chunk and merges back", function()
		local snaps = {}
		for i = 1, World.DEFAULT_CAP + 1 do
			table.insert(snaps, { id = i, kind = (i % #Enemies.ORDER) + 1, x = i * 0.5 - 60, z = -i * 0.25, hpFrac = (i % 10) / 10, flags = i % 16 })
		end
		local chunks = SnapshotCodec.encodeChunks(snaps, 9.5)
		T.eq(#chunks, 3)
		local merged = {}
		for ci, c in chunks do
			T.truthy(buffer.len(c) <= 850)
			local t, part, idx, cnt = SnapshotCodec.decode(c)
			T.eq(t, 9.5)
			T.eq(idx, ci - 1)
			T.eq(cnt, #chunks)
			for _, s in part do
				table.insert(merged, s)
			end
		end
		T.eq(#merged, #snaps)
		for i, s in snaps do
			T.eq(merged[i].id, s.id)
			T.near(merged[i].x, s.x, 1 / 16)
		end
	end)

	T.it("decode rejects truncated or garbage buffers", function()
		local good = SnapshotCodec.encode({ { id = 1, kind = 1, x = 0, z = 0, hpFrac = 1, flags = 0 } }, 1)
		local short = buffer.create(buffer.len(good) - 1)
		buffer.copy(short, 0, good, 0, buffer.len(short))
		for _, b in { short, buffer.create(0), buffer.create(13), "abc", nil, 5 } :: { any } do
			local ok, t, list = pcall(SnapshotCodec.decode, b)
			T.truthy(ok, "decode threw")
			T.truthy(t == 0 and #list == 0 or (b == short and #list == 0) or (typeof(b) == "buffer" and #list == 0))
		end
	end)
end)

return T.finish()
