--!strict
-- Enemy snapshot codec (buffer, little-endian). Pure; round-trip tested in Lune.
--
-- Header, 13 bytes:
--   u8  version (= 1)
--   f64 serverTime        (workspace:GetServerTimeNow(); f32 would lose ~100 s of precision)
--   u16 count             entries in this buffer
--   u8  chunkIndex        0-based
--   u8  chunkCount        buffers that make up this snapshot (same serverTime)
-- Entry, 9 bytes:
--   u16 id                1..65535
--   u8  kind              Enemies.ORDER index, or 200 + Bosses.ORDER index
--   i16 x, i16 z          position * 8 (1/8 stud resolution, +-4095.875 studs)
--   u8  hp                round(hpFrac * 255)
--   u8  flags             bit0 elite, bit1 telegraphing, bit2 stunned/slowed, bit3 boss minion,
--                         bits4-5 size step (0..3): drawn size = base x (1 + step * SIZE_STEP),
--                         so elites (x1.3) and Big Cheese elites (x1.6 / x1.95) look as big
--                         as they hit. Older readers ignore bits 4-5 (VERSION stays 1).
--
-- UnreliableRemoteEvent payloads over ~900 bytes are dropped, so the server sends
-- encodeChunks(..., 850): each chunk is self-contained (93 entries max). Clients merge
-- chunks that share serverTime; an enemy missing from every chunk of a complete
-- snapshot is gone (deaths also arrive reliably as {t="die"} Fx).

local Types = require("../Types")

type EnemySnap = Types.EnemySnap

local SnapshotCodec = {}

SnapshotCodec.VERSION = 1
SnapshotCodec.HEADER = 13
SnapshotCodec.ENTRY = 9
SnapshotCodec.SCALE = 8
SnapshotCodec.MAX_CHUNK_BYTES = 850

-- Size hint in flags bits 4-5 (see the header).
SnapshotCodec.SIZE_BIT = 16
SnapshotCodec.SIZE_STEP = 1 / 3
SnapshotCodec.SIZE_MAX_STEP = 3

-- Flag bits (0, 16, 32 or 48) for an enemy drawn at `scale` x its kind's base radius.
function SnapshotCodec.sizeBits(scale: number): number
	if type(scale) ~= "number" or scale ~= scale or scale <= 1 then
		return 0
	end
	local step = math.floor((scale - 1) / SnapshotCodec.SIZE_STEP + 0.5)
	return math.clamp(step, 0, SnapshotCodec.SIZE_MAX_STEP) * SnapshotCodec.SIZE_BIT
end

-- The size step (0..3) and the draw scale (1..2) carried in `flags`.
function SnapshotCodec.sizeStep(flags: number): number
	if type(flags) ~= "number" or flags ~= flags then
		return 0
	end
	return math.floor(flags / SnapshotCodec.SIZE_BIT) % 4
end

function SnapshotCodec.sizeScale(flags: number): number
	return 1 + SnapshotCodec.sizeStep(flags) * SnapshotCodec.SIZE_STEP
end

local HEADER = SnapshotCodec.HEADER
local ENTRY = SnapshotCodec.ENTRY
local SCALE = SnapshotCodec.SCALE

local function q16(v: number): number
	local n = math.floor(v * SCALE + 0.5)
	if n ~= n then
		return 0
	end
	return math.clamp(n, -32768, 32767)
end

local function writeRange(
	snaps: { EnemySnap },
	first: number,
	last: number,
	serverTime: number,
	index: number,
	count: number
): buffer
	local n = last - first + 1
	local b = buffer.create(HEADER + n * ENTRY)
	buffer.writeu8(b, 0, SnapshotCodec.VERSION)
	buffer.writef64(b, 1, serverTime)
	buffer.writeu16(b, 9, n)
	buffer.writeu8(b, 11, index)
	buffer.writeu8(b, 12, count)
	local o = HEADER
	for i = first, last do
		local s = snaps[i]
		buffer.writeu16(b, o, math.clamp(math.floor(s.id), 0, 65535))
		buffer.writeu8(b, o + 2, math.clamp(math.floor(s.kind), 0, 255))
		buffer.writei16(b, o + 3, q16(s.x))
		buffer.writei16(b, o + 5, q16(s.z))
		local hp = s.hpFrac
		if hp ~= hp then
			hp = 0
		end
		buffer.writeu8(b, o + 7, math.clamp(math.floor(hp * 255 + 0.5), 0, 255))
		buffer.writeu8(b, o + 8, math.clamp(math.floor(s.flags or 0), 0, 255))
		o += ENTRY
	end
	return b
end

-- Whole snapshot in one buffer (contract API). Prefer encodeChunks for the network.
function SnapshotCodec.encode(snaps: { EnemySnap }, serverTime: number): buffer
	assert(#snaps <= 65535, "SnapshotCodec.encode: too many entries")
	if #snaps == 0 then
		return writeRange(snaps, 1, 0, serverTime, 0, 1)
	end
	return writeRange(snaps, 1, #snaps, serverTime, 0, 1)
end

-- Splits into self-contained buffers of at most maxBytes each (default 850).
function SnapshotCodec.encodeChunks(snaps: { EnemySnap }, serverTime: number, maxBytes: number?): { buffer }
	local per = math.max(1, math.floor(((maxBytes or SnapshotCodec.MAX_CHUNK_BYTES) - HEADER) / ENTRY))
	local total = math.max(1, math.ceil(#snaps / per))
	assert(total <= 255, "SnapshotCodec.encodeChunks: too many chunks")
	local out = {}
	for c = 0, total - 1 do
		local first = c * per + 1
		local last = math.min(#snaps, first + per - 1)
		table.insert(out, writeRange(snaps, first, last, serverTime, c, total))
	end
	return out
end

-- Returns (serverTime, snaps, chunkIndex, chunkCount). Malformed input -> (0, {}, 0, 0).
function SnapshotCodec.decode(buf: buffer): (number, { EnemySnap }, number, number)
	if typeof(buf) ~= "buffer" then
		return 0, {}, 0, 0
	end
	local len = buffer.len(buf)
	if len < HEADER or buffer.readu8(buf, 0) ~= SnapshotCodec.VERSION then
		return 0, {}, 0, 0
	end
	local t = buffer.readf64(buf, 1)
	local n = buffer.readu16(buf, 9)
	if len < HEADER + n * ENTRY or t ~= t then
		return 0, {}, 0, 0
	end
	local idx, cnt = buffer.readu8(buf, 11), buffer.readu8(buf, 12)
	local snaps: { EnemySnap } = table.create(n)
	local o = HEADER
	for i = 1, n do
		snaps[i] = {
			id = buffer.readu16(buf, o),
			kind = buffer.readu8(buf, o + 2),
			x = buffer.readi16(buf, o + 3) / SCALE,
			z = buffer.readi16(buf, o + 5) / SCALE,
			hpFrac = buffer.readu8(buf, o + 7) / 255,
			flags = buffer.readu8(buf, o + 8),
		}
		o += ENTRY
	end
	return t, snaps, idx, cnt
end

return SnapshotCodec
