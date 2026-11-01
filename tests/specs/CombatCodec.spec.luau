local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local SnapshotCodec = require("../../src/shared/Combat/SnapshotCodec")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")

local function randomSnaps(n: number, seed: number): { any }
	local rng = Rng.new(seed)
	local out = {}
	for i = 1, n do
		table.insert(out, {
			id = i * 7 % 65535 + 1,
			kind = if i % 50 == 0 then 200 + rng:nextInt(1, 13) else rng:nextInt(1, 5),
			x = rng:range(-200, 200),
			z = rng:range(-200, 200),
			hpFrac = rng:nextFloat(),
			flags = rng:nextInt(0, 15),
		})
	end
	return out
end

local function checkSame(a: any, b: any)
	T.eq(b.id, a.id)
	T.eq(b.kind, a.kind)
	T.eq(b.flags, a.flags)
	T.near(b.x, a.x, 1 / 16 + 1e-9, "x quantised to 1/8 stud")
	T.near(b.z, a.z, 1 / 16 + 1e-9)
	T.near(b.hpFrac, a.hpFrac, 1 / 510 + 1e-9, "hp quantised to u8")
end

T.describe("Combat.SnapshotCodec", function()
	T.it("round-trips 220 enemies in one buffer", function()
		local snaps = randomSnaps(220, 1)
		local time = 1793000000.123456
		local buf = SnapshotCodec.encode(snaps, time)
		T.eq(buffer.len(buf), SnapshotCodec.HEADER + 220 * SnapshotCodec.ENTRY)
		local t, out, idx, cnt = SnapshotCodec.decode(buf)
		T.eq(t, time, "f64 server time is exact")
		T.eq(idx, 0)
		T.eq(cnt, 1)
		T.eq(#out, 220)
		for i = 1, 220 do
			checkSame(snaps[i], out[i])
		end
	end)

	T.it("chunks stay under the unreliable-remote limit and merge back", function()
		local snaps = randomSnaps(220, 2)
		local chunks = SnapshotCodec.encodeChunks(snaps, 42.5)
		T.eq(#chunks, 3)
		local merged = {}
		for i, b in chunks do
			T.truthy(buffer.len(b) <= 850, "chunk " .. i .. " is " .. buffer.len(b) .. " bytes")
			local t, out, idx, cnt = SnapshotCodec.decode(b)
			T.eq(t, 42.5)
			T.eq(idx, i - 1)
			T.eq(cnt, 3)
			for _, s in out do
				table.insert(merged, s)
			end
		end
		T.eq(#merged, 220)
		for i = 1, 220 do
			checkSame(snaps[i], merged[i])
		end
	end)

	T.it("encodes an empty snapshot", function()
		local t, out, _, cnt = SnapshotCodec.decode(SnapshotCodec.encode({}, 3))
		T.eq(t, 3)
		T.eq(#out, 0)
		T.eq(cnt, 1)
		T.eq(#SnapshotCodec.encodeChunks({}, 3), 1)
	end)

	T.it("clamps out-of-range values instead of wrapping", function()
		local snaps = { { id = 70000, kind = 300, x = 99999, z = -99999, hpFrac = 2, flags = 0 } }
		local _, out = SnapshotCodec.decode(SnapshotCodec.encode(snaps :: any, 0))
		T.eq(out[1].id, 65535)
		T.eq(out[1].kind, 255)
		T.near(out[1].x, 32767 / 8, 1e-9)
		T.near(out[1].z, -32768 / 8, 1e-9)
		T.eq(out[1].hpFrac, 1)
	end)

	T.it("rejects malformed buffers", function()
		local t, out = SnapshotCodec.decode(buffer.create(5))
		T.eq(t, 0)
		T.eq(#out, 0)
		local good = SnapshotCodec.encode(randomSnaps(10, 3), 1)
		local short = buffer.create(buffer.len(good) - 4)
		buffer.copy(short, 0, good, 0, buffer.len(short))
		T.eq(#select(2, SnapshotCodec.decode(short)), 0)
		T.eq(#select(2, SnapshotCodec.decode("nope" :: any)), 0)
	end)

	T.it("round-trips a live world snapshot (boss kind 200+)", function()
		local w = World.new({ rng = Rng.new(9), mods = Defaults.mods(), arenaRadius = 100, enemyPool = { "mouse" } })
		w:addPlayer(1, Defaults.stats(), Defaults.weapon("bolt"), Defaults.ability("burst"), 0, 0)
		for i = 1, 50 do
			w:spawnEnemy("mouse", 30 + i % 10, i % 13, i % 9 == 0)
		end
		w:spawnBoss("void_cat", 0, 40)
		w:step(1 / 30, 1)
		local snaps = w:snapshot()
		local _, out = SnapshotCodec.decode(SnapshotCodec.encode(snaps, 1))
		T.eq(#out, #snaps)
		local sawBoss, sawElite = false, false
		for i, s in snaps do
			checkSame(s, out[i])
			sawBoss = sawBoss or out[i].kind == 212
			sawElite = sawElite or out[i].flags % 2 == 1
		end
		T.truthy(sawBoss, "void_cat is Bosses.ORDER[12] -> kind 212")
		T.truthy(sawElite)
	end)
end)

return T.finish()
