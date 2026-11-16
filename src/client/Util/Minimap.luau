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
	site = 1,
	portal = 2,
	enemy = 3,
	champion = 4,
	mate = 4,
	boss = 5,
	bounty = 6,
	self = 7,
}

-- v3 big maps (arena radius 320-400): the radar shows more of the arena on a
-- bigger map. range = clamp(radius x RANGE_FRAC, RANGE, MAX_RANGE); unknown
-- radius -> RANGE.
Minimap.RANGE_FRAC = 0.4
Minimap.MAX_RANGE = 160

function Minimap.rangeFor(arenaRadius: number?): number
	local r = tonumber(arenaRadius)
	if r == nil or r ~= r or r <= 0 then
		return Minimap.RANGE
	end
	return math.clamp(r * Minimap.RANGE_FRAC, Minimap.RANGE, Minimap.MAX_RANGE)
end

-- The arena radius: an explicit `arenaRadius` / `radius` field on the RunState
-- or Match payload wins; else Config/Maps (`maps`) size by `mapId`. nil if unknown.
function Minimap.arenaRadius(run: any, match: any, maps: any): number?
	for _, t in { run, match } do
		if type(t) == "table" then
			local r = tonumber(t.arenaRadius) or tonumber(t.radius)
			if r and r > 0 then
				return r
			end
		end
	end
	local mapId = if type(run) == "table" then run.mapId else nil
	if mapId == nil and type(match) == "table" then
		mapId = match.mapId
	end
	if mapId == nil or type(maps) ~= "table" then
		return nil
	end
	local def = nil
	if type(maps.get) == "function" then
		local ok, d = pcall(maps.get, tostring(mapId))
		def = if ok then d else nil
	end
	if type(def) ~= "table" then
		local byId = maps.defs or maps.byId or maps.BY_ID
		def = if type(byId) == "table" then byId[mapId] else maps[mapId]
	end
	local size = if type(def) == "table" then tonumber(def.size) else nil
	return if size and size > 0 then size else nil
end

-- Champion marker icons (UI-primitive icons, Theme.icon / UI/Icons), one per
-- Config/Champions id; unknown ids draw a star.
Minimap.CHAMP_ICON = {
	champ_captain = "shield",
	champ_golem = "cheese",
	champ_ratking = "crown",
	champ_sniper = "target",
	champ_chemist = "skull",
	champ_thunder = "bolt",
} :: { [string]: string }

function Minimap.champIcon(champId: any): string
	return Minimap.CHAMP_ICON[tostring(champId)] or "star"
end

-- Marker size in px: lairs are bigger.
function Minimap.champSize(lair: boolean?): number
	return if lair then 20 else 15
end

-- Off-screen edge arrow. (sx, sy) is the target's viewport point, `behind`
-- true when it is behind the camera; (w, h) is the viewport. Returns nil when
-- the point is on screen (inside the margin), else the arrow's (x, y) on the
-- screen edge (inset by `margin`) and its angle in degrees (0 = right,
-- 90 = down, screen coordinates).
function Minimap.edgeArrow(
	sx: number,
	sy: number,
	behind: boolean,
	w: number,
	h: number,
	margin: number?
): (number?, number?, number?)
	local m = margin or 28
	if not behind and sx >= m and sx <= w - m and sy >= m and sy <= h - m then
		return nil, nil, nil
	end
	local cx, cy = w / 2, h / 2
	local dx, dy = sx - cx, sy - cy
	if behind then
		dx, dy = -dx, -dy
	end
	if math.abs(dx) < 1e-6 and math.abs(dy) < 1e-6 then
		dy = 1
	end
	local hw, hh = math.max(1, cx - m), math.max(1, cy - m)
	local t = math.min(
		if math.abs(dx) > 1e-6 then hw / math.abs(dx) else math.huge,
		if math.abs(dy) > 1e-6 then hh / math.abs(dy) else math.huge
	)
	return cx + dx * t, cy + dy * t, math.deg(math.atan2(dy, dx))
end

-- Live champions within `maxDist` studs of (cx, cz), nearest first (at most `cap`).
function Minimap.nearChampions(list: any, cx: number, cz: number, maxDist: number, cap: number?): { any }
	local out = {}
	if type(list) ~= "table" then
		return out
	end
	local d2max = maxDist * maxDist
	for _, ch in list do
		local x, z = tonumber(ch.x), tonumber(ch.z)
		if x and z then
			local d2 = (x - cx) ^ 2 + (z - cz) ^ 2
			if d2 <= d2max then
				table.insert(out, { ch = ch, d = math.sqrt(d2) })
			end
		end
	end
	table.sort(out, function(a, b)
		return a.d < b.d
	end)
	local n = cap or #out
	while #out > n do
		table.remove(out)
	end
	return out
end

-- Which markers keep their direction on the rim when out of range.
Minimap.CLAMPS = {
	mate = true,
	boss = true,
	champion = true,
	site = false,
	portal = true,
	bounty = false,
	enemy = false,
	poi = false,
	self = false,
}

return Minimap
