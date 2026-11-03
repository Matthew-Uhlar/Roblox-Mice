--!strict
-- Pure minimap maths (no Roblox APIs, unit-tested under Lune in
-- tests/specs/ClientV2.spec.luau).
--
-- The minimap is a player-centred circular radar. The camera has a fixed
-- yaw (CameraController): screen right = world +X and screen down = world +Z,
-- so a world offset maps straight to a 2D offset with no rotation. Offsets
-- are in minimap px from the centre of the circle.

local Minimap = {}

Minimap.RANGE = 110 -- studs from the centre to the rim
Minimap.SIGHT = 70 -- enemy heroes closer than this are "in sight"
Minimap.EDGE_MARGIN = 7 -- px kept between a clamped marker and the rim

-- Projects world (wx, wz) onto a minimap of `radius` px centred on (cx, cz)
-- that shows `range` studs to the rim. Returns (px, py, clamped): px/py are px
-- offsets from the circle's centre; markers beyond the rim are pulled onto it
-- (clamped = true) so you still see their direction.
function Minimap.project(
	wx: number,
	wz: number,
	cx: number,
	cz: number,
	range: number,
	radius: number,
	margin: number?
): (number, number, boolean)
	local r = math.max(radius, 1)
	local rg = math.max(range, 1e-3)
	local px = (wx - cx) / rg * r
	local py = (wz - cz) / rg * r
	local limit = math.max(0, r - (margin or Minimap.EDGE_MARGIN))
	local d = math.sqrt(px * px + py * py)
	if d > limit and d > 1e-6 then
		return px / d * limit, py / d * limit, true
	end
	return px, py, false
end

-- True if an enemy hero at (wx, wz) is visible from (cx, cz).
function Minimap.inSight(wx: number, wz: number, cx: number, cz: number, sight: number?): boolean
	local s = sight or Minimap.SIGHT
	local dx, dz = wx - cx, wz - cz
	return dx * dx + dz * dz <= s * s
end

-- True if (wx, wz) is inside the minimap's range (not clamped to the rim).
function Minimap.inRange(wx: number, wz: number, cx: number, cz: number, range: number?): boolean
	local r = range or Minimap.RANGE
	local dx, dz = wx - cx, wz - cz
	return dx * dx + dz * dz <= r * r
end

-- Kinds of marker, in draw order (later = on top).
Minimap.LAYER = {
	poi = 1,
	portal = 2,
	enemy = 3,
	mate = 4,
	boss = 5,
	bounty = 6,
	self = 7,
}

-- Which markers keep their direction on the rim when out of range.
Minimap.CLAMPS = {
	mate = true,
	boss = true,
	portal = true,
	bounty = false,
	enemy = false,
	poi = false,
	self = false,
}

return Minimap
