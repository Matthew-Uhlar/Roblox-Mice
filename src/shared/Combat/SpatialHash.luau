--!strict
--!native
-- Uniform grid buckets for neighbour / target queries on the X/Z plane.
-- Rebuilt every step: hash:clear() then hash:insert(item, x, z) for each entity.
-- Bucket tables are reused between clears so a steady-state step allocates nothing.
-- Queries return candidates from every cell the circle touches; callers do the exact
-- distance test (query) or get it done for them (forEachInRadius / nearest).

local SpatialHash = {}
SpatialHash.__index = SpatialHash

-- Cell coordinates are offset so keys stay positive integers for |coord| < OFFSET cells.
local OFFSET = 32768
local STRIDE = 65536

type Bucket = { n: number, items: { any }, xs: { number }, zs: { number } }

export type SpatialHash = typeof(setmetatable(
	{} :: {
		cellSize: number,
		inv: number,
		buckets: { [number]: Bucket },
		used: { number },
		usedCount: number,
		count: number,
	},
	SpatialHash
))

function SpatialHash.new(cellSize: number?): SpatialHash
	local cs = cellSize or 4
	assert(cs > 0, "SpatialHash: cellSize must be > 0")
	return setmetatable({
		cellSize = cs,
		inv = 1 / cs,
		buckets = {},
		used = {},
		usedCount = 0,
		count = 0,
	}, SpatialHash)
end

local function keyOf(cx: number, cz: number): number
	return (cx + OFFSET) * STRIDE + (cz + OFFSET)
end

function SpatialHash.clear(self: SpatialHash)
	local buckets = self.buckets
	for i = 1, self.usedCount do
		local b = buckets[self.used[i]]
		-- drop references so removed entities can be collected
		for j = 1, b.n do
			b.items[j] = nil
		end
		b.n = 0
	end
	self.usedCount = 0
	self.count = 0
end

function SpatialHash.insert(self: SpatialHash, item: any, x: number, z: number)
	local cx = math.floor(x * self.inv)
	local cz = math.floor(z * self.inv)
	local key = keyOf(cx, cz)
	local b = self.buckets[key]
	if not b then
		b = { n = 0, items = {}, xs = {}, zs = {} }
		self.buckets[key] = b
	end
	if b.n == 0 then
		self.usedCount += 1
		self.used[self.usedCount] = key
	end
	local n = b.n + 1
	b.n = n
	b.items[n] = item
	b.xs[n] = x
	b.zs[n] = z
	self.count += 1
end

-- Calls fn(item, x, z, distSq) for every item whose inserted point is within r of (x, z).
-- Return true from fn to stop early.
function SpatialHash.forEachInRadius(
	self: SpatialHash,
	x: number,
	z: number,
	r: number,
	fn: (item: any, ix: number, iz: number, distSq: number) -> boolean?
)
	local inv = self.inv
	local x0, x1 = math.floor((x - r) * inv), math.floor((x + r) * inv)
	local z0, z1 = math.floor((z - r) * inv), math.floor((z + r) * inv)
	local r2 = r * r
	local buckets = self.buckets
	for cx = x0, x1 do
		for cz = z0, z1 do
			local b = buckets[keyOf(cx, cz)]
			if b and b.n > 0 then
				local xs, zs, items = b.xs, b.zs, b.items
				for i = 1, b.n do
					local dx, dz = xs[i] - x, zs[i] - z
					local d2 = dx * dx + dz * dz
					if d2 <= r2 then
						if fn(items[i], xs[i], zs[i], d2) then
							return
						end
					end
				end
			end
		end
	end
end

-- Fills `out` (or a new table) with every item within r of (x, z). Returns the list.
function SpatialHash.query(self: SpatialHash, x: number, z: number, r: number, out: { any }?): { any }
	local list = out or {}
	if out then
		table.clear(list)
	end
	local n = 0
	self:forEachInRadius(x, z, r, function(item)
		n += 1
		list[n] = item
		return nil
	end)
	return list
end

-- Nearest item within maxR (optionally filtered). Returns (item?, distSq).
function SpatialHash.nearest(
	self: SpatialHash,
	x: number,
	z: number,
	maxR: number,
	filter: ((item: any) -> boolean)?
): (any?, number)
	local best, bestD2 = nil, math.huge
	self:forEachInRadius(x, z, maxR, function(item, _, _, d2)
		if d2 < bestD2 and (filter == nil or filter(item)) then
			best, bestD2 = item, d2
		end
		return nil
	end)
	return best, bestD2
end

return SpatialHash
