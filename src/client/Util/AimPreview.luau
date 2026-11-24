--!strict
-- AimPreview (iteration 7 §B1, team Client): pure maths for the hold-to-aim
-- ability preview. No Roblox APIs (Lune-tested, tests/specs/ClientIter7.spec.luau).
--
--   AimPreview.shapeFor(def)            -> Shape   what to draw for an AbilityDef
--   AimPreview.geometry(shape, hx, hz, ax, az) -> Geo   world geometry at an aim
--   AimPreview.isHold(heldFor)          tap (quick-cast) vs hold (preview)
--   AimPreview.stickPoint(...)          a right-stick aim scaled into the range
--
-- Forms (Combat/Weapons semantics, Config/ClassAbilities header):
--   "circle"  area at the aim point clamped to `range` (burst, puddle, field,
--             vortex, mark; unknown aimed kinds)
--   "line"    a fixed-length strip from the hero toward the aim (dash, lance)
--   "path"    a strip from the hero to the clamped aim plus an end circle
--             (chain: reach + jump range; tether: link to an ally)
--   "leap"    landing ghost: path + landing circle at the clamped aim
--   "ghost"   turret / barricade: BuildRenderer draws the model ghost; we add
--             the cast-range ring and a footprint circle
--   "cone"    a cone of `angle` degrees and `length` toward the aim
--   "self"    centred on the hero (ring, shield, hover, repair, anchor)

local AimPreview = {}

AimPreview.HOLD_TIME = 0.18 -- seconds a key must be held before the preview shows
AimPreview.MIN_STICK = 4 -- studs: a barely deflected stick still aims this far out
AimPreview.PATH_WIDTH = 1.2 -- chain / tether / leap path strip width

-- Combat/Weapons default cast ranges (n(a.distance, X)) when a def has none.
AimPreview.DEFAULT_RANGE = table.freeze({
	dash = 16,
	burst = 30,
	puddle = 24,
	field = 28,
	turret = 30,
	barricade = 22,
	chain = 36,
	vortex = 30,
	leap = 26,
	mark = 34,
	lance = 90,
	tether = 35,
	cone = 20,
	spread = 20,
} :: { [string]: number })

local FORM: { [string]: string } = {
	burst = "circle",
	puddle = "circle",
	field = "circle",
	vortex = "circle",
	mark = "circle",
	dash = "line",
	lance = "line",
	chain = "path",
	tether = "path",
	leap = "leap",
	turret = "ghost",
	barricade = "ghost",
	cone = "cone",
	spread = "cone",
	ring = "self",
	shield = "self",
	hover = "self",
	repair = "self",
	anchor = "self",
}

export type Shape = {
	kind: string,
	form: string,
	range: number, -- cast range ring around the hero (self: the area)
	radius: number, -- circle radius at the aim / end / self
	width: number, -- line / path strip width
	angle: number, -- cone angle, degrees
	ghost: string?, -- "turret" | "barricade" (BuildRenderer model)
}

export type Geo = {
	form: string,
	cx: number, -- the clamped aim / landing / area centre
	cz: number,
	fromX: number, -- strip start (the hero)
	fromZ: number,
	toX: number, -- strip end
	toZ: number,
	yaw: number, -- atan2(dx, dz) of hero -> aim
	radius: number,
	width: number,
	length: number, -- strip / cone length
	angle: number,
	range: number,
}

local function num(v: any, d: number): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return d
	end
	return n
end

-- What to draw for an ability def (nil def -> a generic circle at 30).
function AimPreview.shapeFor(def: any): Shape
	local d = if type(def) == "table" then def else {}
	local kind = tostring(d.kind or "burst")
	local form = FORM[kind] or (if d.distance ~= nil then "circle" else "self")
	local area = math.max(0, num(d.area, 0))
	local dist = num(d.distance, AimPreview.DEFAULT_RANGE[kind] or 30)
	local s: Shape = {
		kind = kind,
		form = form,
		range = math.max(0, dist),
		radius = area,
		width = AimPreview.PATH_WIDTH,
		angle = 0,
		ghost = nil,
	}
	if form == "line" then
		s.width = math.max(1, 2 * area) -- dash / lance: area = half width
		s.radius = 0
	elseif form == "path" then
		s.radius = area -- chain: jump range at the end; tether: none
		if kind == "tether" then
			s.radius = 3
		end
	elseif form == "ghost" then
		s.ghost = kind
		-- turret: area = targeting range (BuildRenderer draws it); barricade: half length
		s.radius = if kind == "barricade" then math.max(1, area) else 2.5
	elseif form == "cone" then
		s.angle = math.clamp(area, 5, 180)
		s.radius = 0
	elseif form == "self" then
		-- area 0 (anchor: a stance) still shows a small footprint plate
		local r = if area > 0 then area else 4
		s.range = r
		s.radius = r
	end
	return s
end

-- Clamps (ax, az) to `range` around the hero. Returns (x, z, yaw, distance).
function AimPreview.clamp(
	hx: number,
	hz: number,
	ax: number,
	az: number,
	range: number
): (number, number, number, number)
	local dx, dz = ax - hx, az - hz
	local d = math.sqrt(dx * dx + dz * dz)
	local r = math.max(0, range)
	if d > r and d > 1e-6 then
		return hx + dx / d * r, hz + dz / d * r, math.atan2(dx, dz), r
	end
	return ax, az, if d > 1e-6 then math.atan2(dx, dz) else 0, d
end

-- World geometry of a shape for a hero at (hx, hz) aiming at (ax, az).
function AimPreview.geometry(shape: Shape, hx: number, hz: number, ax: number, az: number): Geo
	local g: Geo = {
		form = shape.form,
		cx = hx,
		cz = hz,
		fromX = hx,
		fromZ = hz,
		toX = hx,
		toZ = hz,
		yaw = 0,
		radius = shape.radius,
		width = shape.width,
		length = 0,
		angle = shape.angle,
		range = shape.range,
	}
	if shape.form == "self" then
		return g
	end
	local cx, cz, yaw, d = AimPreview.clamp(hx, hz, ax, az, shape.range)
	g.yaw = yaw
	if shape.form == "line" or shape.form == "cone" then
		-- fixed length along the aim direction (Weapons dash: distance, not the aim)
		local L = shape.range
		g.toX, g.toZ = hx + math.sin(yaw) * L, hz + math.cos(yaw) * L
		g.cx, g.cz = g.toX, g.toZ
		g.length = L
		return g
	end
	g.cx, g.cz = cx, cz
	g.toX, g.toZ = cx, cz
	g.length = d
	return g
end

-- The two far corners of a cone (for drawing its edges): (lx, lz, rx, rz).
function AimPreview.coneEdges(geo: Geo): (number, number, number, number)
	local half = math.rad(geo.angle) / 2
	local L = geo.length
	local a1, a2 = geo.yaw - half, geo.yaw + half
	return geo.fromX + math.sin(a1) * L,
		geo.fromZ + math.cos(a1) * L,
		geo.fromX + math.sin(a2) * L,
		geo.fromZ + math.cos(a2) * L
end

-- Tap vs hold: a key held at least HOLD_TIME is an aimed cast.
function AimPreview.isHold(heldFor: number): boolean
	return heldFor >= AimPreview.HOLD_TIME
end

-- Right-stick aim while holding: the stick's direction (world dx, dz) and its
-- deflection 0..1 pick a point inside the cast range.
function AimPreview.stickPoint(
	hx: number,
	hz: number,
	dx: number,
	dz: number,
	magnitude: number,
	range: number
): (number?, number?)
	local m = math.sqrt(dx * dx + dz * dz)
	if m < 1e-4 then
		return nil, nil
	end
	local reach = math.max(math.min(AimPreview.MIN_STICK, range), math.clamp(magnitude, 0, 1) * range)
	return hx + dx / m * reach, hz + dz / m * reach
end

-- Whether the outline / fill parts show for an Effects level. The outline
-- (range ring and shape edge) is essential and always shows; the translucent
-- fill is decoration ("off" hides it, "reduced" makes it fainter).
function AimPreview.fillAlpha(fx: string): number?
	if fx == "off" then
		return nil
	elseif fx == "reduced" then
		return 0.9
	end
	return 0.8
end

return AimPreview
