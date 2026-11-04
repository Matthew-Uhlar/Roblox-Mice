--!strict
-- Props (R4 Graphics): detailed, multi-part themed props built from primitives
-- with PBR materials. Used by ArenaBuilder (obstacles, decor, rim dressing) and
-- LobbyWorld.
--
-- Obstacle builders: Props.OBSTACLES[kind](m, x, z, r, rng, pal, solid) -> solidRadius
--   Every visual part is non-colliding. When `solid` is true the builder adds ONE
--   invisible upright cylinder collider of radius `solidRadius` centred on (x, z),
--   so the World's obstacle circle {x, z, solidRadius} is exactly the solid footprint.
--   Canopies / tall tops are tagged "Canopy" (the client camera fades them when they
--   hide your hero).
-- Decor builders: Props.DECOR[kind](m, x, z, s, rng, pal) — small, non-colliding,
--   the caller tags the group "Decor" so low-spec clients can hide it.
-- `pal` is the map palette (ArenaBuilder.THEMES): rock, rockDark, moss, leaves {..},
-- trunk, accent, glow, flower {..}, cheese.

local Build = require(script.Parent.Build)

local Props = {}

local rad = math.rad
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local M = Enum.Material

Props.CHEESE = Color3.fromRGB(255, 201, 60)
Props.CHEESE_DARK = Color3.fromRGB(222, 150, 38)
Props.RIND = Color3.fromRGB(214, 120, 40)
Props.HOLE = Color3.fromRGB(196, 128, 30)

export type Palette = {
	rock: Color3,
	rockDark: Color3,
	moss: Color3,
	leaves: { Color3 },
	trunk: Color3,
	accent: Color3,
	glow: Color3,
	flower: { Color3 },
	rockMaterial: Enum.Material?,
}

type Rng = any

local function pick(rng: Rng, list: { any }): any
	return list[rng:nextInt(1, #list)]
end

local function yaw(a: number): CFrame
	return ANG(0, a, 0)
end

-- The single invisible collider that matches the obstacle circle.
local function collider(m: Instance, x: number, z: number, r: number, h: number)
	local c = Build.ucyl(m, h, r * 2, CF(x, h / 2, z), Color3.new(1, 1, 1), M.SmoothPlastic, {
		name = "Collider",
		collide = true,
		transparency = 1,
		shadow = false,
	})
	c:SetAttribute("Collider", true)
end

local function canopy(p: BasePart)
	p:AddTag("Canopy")
end

-- A cone made of radial wedges (tall faces meet at the axis, slopes face out).
function Props.cone(
	m: Instance,
	base: CFrame,
	radius: number,
	height: number,
	n: number,
	color: Color3,
	material: Enum.Material?,
	twist: number?
): { BasePart }
	local out = {}
	local w = 2 * radius * math.tan(math.pi / n) * 1.04
	for i = 0, n - 1 do
		local a = (i / n) * math.pi * 2 + (twist or 0)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local p = base * CF(dir * radius / 2 + Vector3.new(0, height / 2, 0))
		local cf = CFrame.lookAt(p.Position, p.Position + base:VectorToWorldSpace(dir), base.UpVector)
		table.insert(out, Build.wedge(m, V3(w, height, radius), cf, color, material))
	end
	return out
end

-- Rocks ------------------------------------------------------------------------------------

-- A faceted boulder: a ball core with corner-wedge facets and a darker base.
function Props.boulder(m: Instance, cf: CFrame, s: number, rng: Rng, pal: Palette, mossy: boolean?)
	local mat = pal.rockMaterial or M.Rock
	local base = pal.rock:Lerp(pal.rockDark, rng:range(0, 0.4))
	Build.egg(
		m,
		V3(s * rng:range(1.6, 2.0), s * rng:range(1.1, 1.5), s * rng:range(1.5, 1.9)),
		cf * CF(0, s * 0.35, 0) * yaw(rng:range(0, 6.28)),
		base,
		mat
	)
	for i = 1, 3 do
		local a = i * 2.1 + rng:range(-0.4, 0.4)
		Build.corner(
			m,
			V3(s * 0.9, s * rng:range(0.7, 1.1), s * 0.9),
			cf * CF(math.cos(a) * s * 0.55, s * 0.3, math.sin(a) * s * 0.55) * yaw(a + rng:range(-0.5, 0.5)),
			base:Lerp(pal.rockDark, 0.3),
			mat
		)
	end
	if mossy then
		Build.egg(
			m,
			V3(s * 1.3, s * 0.35, s * 1.2),
			cf * CF(rng:range(-0.2, 0.2) * s, s * 1.0, 0) * yaw(rng:range(0, 6.28)),
			pal.moss,
			M.Grass,
			{ shadow = false }
		)
	end
end

local function rockCluster(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	pal: Palette,
	mossy: boolean
)
	local c = CF(x, 0, z)
	Props.boulder(m, c, r * 0.95, rng, pal, mossy)
	local n = rng:nextInt(2, 3)
	for i = 1, n do
		local a = rng:range(0, 6.28)
		local s = r * rng:range(0.35, 0.55)
		Props.boulder(
			m,
			c * CF(math.cos(a) * r * 0.85, 0, math.sin(a) * r * 0.85),
			s,
			rng,
			pal,
			mossy and i == 1
		)
	end
	-- pebbles at the foot
	for _ = 1, 3 do
		local a = rng:range(0, 6.28)
		Build.ball(
			m,
			r * rng:range(0.18, 0.3),
			c * CF(math.cos(a) * r * 1.15, 0.1, math.sin(a) * r * 1.15),
			pal.rockDark,
			pal.rockMaterial or M.Rock,
			{ shadow = false }
		)
	end
end

-- Cheese ------------------------------------------------------------------------------------

-- A pie-slice cheese wedge (triangle in plan view, thickness h) with a rind on
-- the round back and darker holes on the faces. Built around cf (ground centre).
function Props.cheeseWedge(m: Instance, cf: CFrame, len: number, h: number, rng: Rng?, color: Color3?)
	local col = color or Props.CHEESE
	local half = len * 0.42 -- half-width of the back
	-- Two right-triangle prisms = one isosceles slice (tip at -Z, back at +Z). A
	-- WedgePart's triangle is in its YZ plane; rolling it +-90 degrees about Z lays
	-- the triangle flat (X becomes the vertical thickness). Rolling -90 instead of
	-- +90 flips the prism over, which mirrors the right half.
	for _, side in { -1, 1 } do
		local wcf = cf * CF(side * half / 2, h / 2, 0) * ANG(0, 0, rad(if side > 0 then -90 else 90))
		Build.wedge(m, V3(h, half, len), wcf, col, M.SmoothPlastic)
	end
	-- rind on the back face (+Z end)
	Build.block(
		m,
		V3(half * 2 + 0.1, h + 0.1, len * 0.06),
		cf * CF(0, h / 2, len / 2),
		Props.RIND,
		M.SmoothPlastic
	)
	-- holes: flattened ellipsoids sitting in the top and side faces
	local r = rng
	local n = if r then r:nextInt(3, 5) else 4
	for i = 1, n do
		local t = if r then r:range(0.15, 0.85) else i / (n + 1)
		local wAt = half * 2 * t
		local hs = math.min(h * 0.45, len * 0.12) * (if r then r:range(0.6, 1.1) else 0.9)
		local zpos = -len / 2 + len * t
		local xoff = (if r then r:range(-0.5, 0.5) else 0) * wAt * 0.6
		if i % 2 == 0 then
			-- top face hole
			Build.egg(
				m,
				V3(hs * 1.4, 0.12, hs * 1.4),
				cf * CF(xoff, h + 0.02, zpos),
				Props.HOLE,
				M.SmoothPlastic,
				{
					shadow = false,
				}
			)
		else
			-- side face hole (left or right sloped side)
			local side = if i % 4 == 1 then 1 else -1
			local edge = wAt / 2
			Build.egg(
				m,
				V3(0.14, hs, hs * 1.2),
				cf
					* CF(side * edge * 0.98, h * (if r then r:range(0.3, 0.7) else 0.5), zpos)
					* yaw(side * rad(-23)),
				Props.HOLE,
				M.SmoothPlastic,
				{ shadow = false }
			)
		end
	end
end

-- Trees -------------------------------------------------------------------------------------

local function trunk(
	m: Instance,
	x: number,
	z: number,
	h: number,
	d: number,
	color: Color3,
	rng: Rng,
	lean: number?
): CFrame
	local tilt = ANG(rad(rng:range(-1, 1) * (lean or 3)), 0, rad(rng:range(-1, 1) * (lean or 3)))
	local base = CF(x, 0, z) * tilt
	Build.ucyl(m, h, d, base * CF(0, h / 2, 0), color, M.Wood)
	Build.ucyl(m, h * 0.35, d * 1.25, base * CF(0, h * 0.17, 0), color:Lerp(Color3.new(0, 0, 0), 0.1), M.Wood)
	-- root flares
	for i = 0, 3 do
		local a = i * math.pi / 2 + rng:range(-0.3, 0.3)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local p = Vector3.new(x, 0, z) + dir * d * 0.75 + Vector3.new(0, d * 0.35, 0)
		Build.wedge(
			m,
			V3(d * 0.45, d * 0.7, d * 0.9),
			CFrame.lookAt(p, p + dir),
			color:Lerp(Color3.new(0, 0, 0), 0.15),
			M.Wood,
			{ shadow = false }
		)
	end
	return base * CF(0, h, 0)
end

local function leafBlob(
	m: Instance,
	cf: CFrame,
	s: number,
	color: Color3,
	rng: Rng,
	mat: Enum.Material?
): BasePart
	local p = Build.egg(
		m,
		V3(s * rng:range(1.0, 1.25), s * rng:range(0.75, 0.95), s * rng:range(1.0, 1.25)),
		cf * yaw(rng:range(0, 6.28)),
		color,
		mat or M.Grass
	)
	canopy(p)
	return p
end

-- Broadleaf tree: layered canopy of ellipsoid clusters in three greens + fruit.
function Props.tree(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	pal: Palette,
	solid: boolean
): number
	local tr = r * 0.55
	local h = rng:range(8, 12) * math.clamp(r / 3.5, 0.8, 1.5)
	local top = trunk(m, x, z, h, tr * 2, pal.trunk, rng)
	-- two branches
	for i = 1, 2 do
		local a = rng:range(0, 6.28)
		local bcf = top * CF(0, -h * (0.2 + 0.15 * i), 0) * yaw(a) * ANG(rad(-50), 0, 0)
		Build.cyl(
			m,
			h * 0.4,
			tr * 0.6,
			bcf * CF(0, h * 0.2, 0) * Build.UPRIGHT,
			pal.trunk,
			M.Wood,
			{ shadow = false }
		)
	end
	local leaves = pal.leaves
	local c = r * 2.1
	-- bottom tier (wide), middle tier, crown
	for tier = 0, 2 do
		local n = 5 - tier
		local ring = c * (0.75 - tier * 0.25)
		local y = tier * c * 0.45
		local col = leaves[math.min(#leaves, tier + 1)]
		for i = 1, n do
			local a = i / n * 6.28 + tier * 0.6 + rng:range(-0.2, 0.2)
			leafBlob(
				m,
				top * CF(math.cos(a) * ring, y, math.sin(a) * ring),
				c * (1.05 - tier * 0.2),
				col,
				rng
			)
		end
	end
	leafBlob(m, top * CF(0, c * 1.05, 0), c * 0.85, leaves[#leaves], rng)
	-- fruit / blossoms
	if #pal.flower > 0 then
		for _ = 1, 4 do
			local a = rng:range(0, 6.28)
			local ball = Build.ball(
				m,
				r * 0.32,
				top * CF(math.cos(a) * c * 0.95, rng:range(0, c * 0.6), math.sin(a) * c * 0.95),
				pick(rng, pal.flower),
				M.SmoothPlastic,
				{ shadow = false }
			)
			canopy(ball)
		end
	end
	if solid then
		collider(m, x, z, tr, h)
	end
	return tr
end

-- Conifer: tiers of radial-wedge cones, snow caps on the tundra.
function Props.pine(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	pal: Palette,
	solid: boolean
): number
	local tr = r * 0.4
	local h = rng:range(3, 4.5)
	Build.ucyl(m, h + 2, tr * 2, CF(x, (h + 2) / 2, z), pal.trunk, M.Wood)
	local snow = pal.moss
	local leaf = pal.leaves[1]
	local y = h
	local tiers = rng:nextInt(3, 4)
	for t = 0, tiers - 1 do
		local rr = r * (2.2 - t * 0.45)
		local th = 3.6 - t * 0.35
		local parts = Props.cone(
			m,
			CF(x, y, z),
			rr,
			th,
			7,
			if t % 2 == 0 then leaf else pal.leaves[2] or leaf,
			M.Grass,
			t * 0.4
		)
		for _, p in parts do
			canopy(p)
		end
		local caps = Props.cone(m, CF(x, y + th * 0.55, z), rr * 0.55, th * 0.45, 7, snow, M.Snow, t * 0.4)
		for _, p in caps do
			canopy(p)
		end
		y += th * 0.7
	end
	local tip = Build.ball(m, r * 0.45, CF(x, y + 0.8, z), snow, M.Snow)
	canopy(tip)
	if solid then
		collider(m, x, z, tr, h + 2)
	end
	return tr
end

-- Palm: a curved trunk of rings, drooping fronds and coconuts.
function Props.palm(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	pal: Palette,
	solid: boolean
): number
	local tr = r * 0.42
	local segs = 7
	local lean = rng:range(0, 6.28)
	local bend = rng:range(0.04, 0.09)
	local cf = CF(x, 0, z) * yaw(lean)
	local segH = rng:range(1.7, 2.1)
	for i = 1, segs do
		local d = tr * 2 * (1 - i * 0.04)
		cf = cf * ANG(-bend, 0, 0)
		local mid = cf * CF(0, segH / 2, 0)
		Build.ucyl(
			m,
			segH * 1.02,
			d,
			mid,
			if i % 2 == 0 then pal.trunk else Build.shade(pal.trunk, 0.12),
			M.Wood
		)
		Build.ucyl(
			m,
			0.25,
			d * 1.12,
			cf * CF(0, segH, 0),
			Build.shade(pal.trunk, -0.2),
			M.Wood,
			{ shadow = false }
		)
		cf = cf * CF(0, segH, 0)
	end
	local crown = cf
	for i = 0, 7 do
		local a = i / 8 * 6.28 + rng:range(-0.15, 0.15)
		local f1 = crown * yaw(a) * ANG(rad(-15), 0, 0)
		local leafColor = pal.leaves[(i % #pal.leaves) + 1]
		local p1 = Build.block(m, V3(1.4, 0.18, 4), f1 * CF(0, 0, -2), leafColor, M.Grass, { shadow = false })
		local f2 = f1 * CF(0, 0, -4) * ANG(rad(-35), 0, 0)
		local p2 =
			Build.wedge(m, V3(1.3, 0.18, 3.4), f2 * CF(0, 0, -1.7) * ANG(0, math.pi, 0), leafColor, M.Grass, {
				shadow = false,
			})
		canopy(p1)
		canopy(p2)
	end
	for i = 0, 2 do
		local a = i * 2.1
		local p = Build.ball(
			m,
			0.9,
			crown * CF(math.cos(a) * 0.7, -0.5, math.sin(a) * 0.7),
			Color3.fromRGB(110, 75, 40),
			M.Wood
		)
		canopy(p)
	end
	if solid then
		collider(m, x, z, tr, 6)
	end
	return tr
end

-- Jungle giant: buttress roots, hanging vines, huge canopy, orchids.
function Props.jungleTree(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	pal: Palette,
	solid: boolean
): number
	local tr = r * 0.55
	local h = rng:range(13, 17)
	local top = trunk(m, x, z, h, tr * 2, pal.trunk, rng, 2)
	for i = 0, 4 do
		local a = i / 5 * 6.28 + rng:range(-0.2, 0.2)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local p = Vector3.new(x, 1.6, z) + dir * tr * 1.25
		Build.wedge(m, V3(0.5, 3.2, tr * 1.6), CFrame.lookAt(p, p + dir), pal.trunk, M.Wood)
	end
	local c = r * 2.5
	for i = 1, 6 do
		local a = i / 6 * 6.28 + rng:range(-0.25, 0.25)
		leafBlob(
			m,
			top * CF(math.cos(a) * c * 0.7, rng:range(-0.5, 0.8), math.sin(a) * c * 0.7),
			c,
			pal.leaves[(i % #pal.leaves) + 1],
			rng
		)
	end
	leafBlob(m, top * CF(0, c * 0.55, 0), c * 1.1, pal.leaves[1], rng)
	-- vines
	for i = 1, 5 do
		local a = i / 5 * 6.28 + 0.3
		local len = rng:range(4, 8)
		local vp = top * CF(math.cos(a) * c * 0.95, -len / 2, math.sin(a) * c * 0.95)
		local v = Build.ucyl(m, len, 0.25, vp, pal.moss, M.Grass, { shadow = false })
		canopy(v)
		local bloom = Build.ball(
			m,
			0.6,
			vp * CF(0, -len / 2, 0),
			pick(rng, pal.flower),
			M.SmoothPlastic,
			{ shadow = false }
		)
		canopy(bloom)
	end
	if solid then
		collider(m, x, z, tr, h)
	end
	return tr
end

-- Swamp: twisted dead tree with hanging moss and glowing toadstools.
function Props.deadTree(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	pal: Palette,
	solid: boolean
): number
	local tr = r * 0.5
	local cf = CF(x, 0, z) * yaw(rng:range(0, 6.28))
	local segH = 2.4
	for i = 1, 4 do
		cf = cf * ANG(rad(rng:range(-12, 12)), 0, rad(rng:range(-12, 12)))
		Build.ucyl(m, segH * 1.05, tr * 2 * (1 - i * 0.12), cf * CF(0, segH / 2, 0), pal.trunk, M.Wood)
		cf = cf * CF(0, segH, 0)
	end
	for i = 1, 4 do
		local a = i / 4 * 6.28 + rng:range(-0.3, 0.3)
		local b = cf * CF(0, -i * 0.6, 0) * yaw(a) * ANG(rad(-60 + rng:range(-10, 10)), 0, 0)
		local len = rng:range(3, 5)
		Build.ucyl(m, len, 0.45, b * CF(0, len / 2, 0), pal.trunk, M.Wood, { shadow = false })
		local tip = b * CF(0, len, 0)
		local moss = Build.block(m, V3(0.12, 2.2, 0.9), tip * CF(0, -1.1, 0), pal.moss, M.Grass, {
			shadow = false,
			transparency = 0.15,
		})
		canopy(moss)
	end
	for i = 1, 3 do
		local a = i * 2.2
		local p = CF(x + math.cos(a) * (tr + 0.8), 0, z + math.sin(a) * (tr + 0.8))
		Build.ucyl(
			m,
			0.8,
			0.3,
			p * CF(0, 0.4, 0),
			Color3.fromRGB(230, 225, 200),
			M.SmoothPlastic,
			{ shadow = false }
		)
		local cap = Build.egg(m, V3(1.0, 0.45, 1.0), p * CF(0, 0.85, 0), pal.glow, M.Neon, { shadow = false })
		if i == 1 then
			Build.light(cap, pal.glow, 8, 0.8)
		end
	end
	if solid then
		collider(m, x, z, tr, 8)
	end
	return tr
end

-- Giant mushroom: stem, spotted cap and glowing gills.
function Props.mushroom(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	pal: Palette,
	solid: boolean
): number
	local tr = r * 0.45
	local h = rng:range(4, 6.5)
	Build.ucyl(m, h, tr * 2, CF(x, h / 2, z), Color3.fromRGB(240, 232, 210), M.SmoothPlastic)
	Build.ucyl(
		m,
		0.4,
		tr * 2.6,
		CF(x, h * 0.62, z),
		Color3.fromRGB(225, 215, 190),
		M.SmoothPlastic,
		{ shadow = false }
	)
	local capColor = pick(rng, pal.flower)
	local capD = r * 2.6
	local cap = Build.egg(m, V3(capD, capD * 0.5, capD), CF(x, h + capD * 0.12, z), capColor, M.SmoothPlastic)
	canopy(cap)
	local gills = Build.egg(
		m,
		V3(capD * 0.9, 0.3, capD * 0.9),
		CF(x, h - 0.05, z),
		pal.glow,
		M.Neon,
		{ shadow = false }
	)
	canopy(gills)
	Build.light(gills, pal.glow, 10, 0.7)
	for i = 1, 6 do
		local a = i / 6 * 6.28 + rng:range(-0.2, 0.2)
		local dd = capD * 0.32
		local spot = Build.egg(
			m,
			V3(capD * 0.16, capD * 0.07, capD * 0.16),
			CF(x + math.cos(a) * dd, h + capD * 0.3, z + math.sin(a) * dd)
				* ANG(math.sin(a) * 0.45, 0, -math.cos(a) * 0.45),
			Color3.fromRGB(255, 250, 240),
			M.SmoothPlastic,
			{ shadow = false }
		)
		canopy(spot)
	end
	if solid then
		collider(m, x, z, tr, h)
	end
	return tr
end

-- Crystals ------------------------------------------------------------------------------------

local function crystal(
	m: Instance,
	cf: CFrame,
	w: number,
	h: number,
	color: Color3,
	material: Enum.Material,
	t: number
)
	Build.block(m, V3(w, h, w), cf * CF(0, h / 2, 0) * yaw(rad(45)), color, material, { transparency = t })
	-- pointed tip: 4 corner wedges would need exact orientation; two crossed wedges read as a point
	for k = 0, 1 do
		Build.wedge(
			m,
			V3(w * 0.71, w * 0.9, w * 0.71),
			cf * CF(0, h + w * 0.45, 0) * yaw(rad(45 + 90 * k)) * CF(0, 0, -w * 0.0),
			color,
			material,
			{ transparency = t, shadow = false }
		)
	end
end

function Props.iceCluster(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	pal: Palette,
	solid: boolean
): number
	local base = CF(x, 0, z)
	Build.egg(m, V3(r * 2.2, 1.4, r * 2.2), base * CF(0, 0.3, 0), Build.shade(pal.rock, 0.3), M.Glacier)
	local n = rng:nextInt(4, 6)
	for i = 1, n do
		local a = i / n * 6.28 + rng:range(-0.3, 0.3)
		local d = if i == 1 then 0 else r * rng:range(0.35, 0.7)
		local h = if i == 1 then rng:range(7, 10) else rng:range(3, 6.5)
		local w = if i == 1 then r * 0.75 else r * rng:range(0.35, 0.55)
		local tilt = ANG(rad(rng:range(-18, 18)), a, rad(rng:range(-18, 18)))
		crystal(
			m,
			base * CF(math.cos(a) * d, 0, math.sin(a) * d) * tilt,
			w,
			h,
			pal.accent:Lerp(Color3.new(1, 1, 1), 0.35),
			M.Glass,
			0.25
		)
	end
	local glowPart =
		Build.ball(m, 1.2, base * CF(0, 2, 0), pal.glow, M.Neon, { transparency = 0.4, shadow = false })
	Build.light(glowPart, pal.glow, 12, 1.2)
	if solid then
		collider(m, x, z, r * 0.8, 7)
	end
	return r * 0.8
end

function Props.crystalCluster(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	pal: Palette,
	solid: boolean
): number
	local base = CF(x, 0, z)
	Props.boulder(m, base, r * 0.7, rng, pal, false)
	local n = rng:nextInt(3, 5)
	for i = 1, n do
		local a = i / n * 6.28 + rng:range(-0.3, 0.3)
		local d = r * rng:range(0.2, 0.6)
		local tilt = ANG(rad(rng:range(-25, 25)), a, rad(rng:range(-25, 25)))
		crystal(
			m,
			base * CF(math.cos(a) * d, r * 0.4, math.sin(a) * d) * tilt,
			r * rng:range(0.3, 0.45),
			rng:range(3, 6),
			pal.glow,
			M.Neon,
			0.1
		)
	end
	local core = Build.ball(m, 0.8, base * CF(0, r, 0), pal.glow, M.Neon, { shadow = false })
	Build.light(core, pal.glow, 14, 1.4)
	if solid then
		collider(m, x, z, r * 0.85, 6)
	end
	return r * 0.85
end

-- Volcano: basalt rocks with glowing lava cracks, embers and smoke.
function Props.lavaRock(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	pal: Palette,
	solid: boolean
): number
	rockCluster(m, x, z, r, rng, pal, false)
	local lava = pal.glow
	for i = 1, 3 do
		local a = rng:range(0, 3.14)
		local seg = Build.block(
			m,
			V3(r * rng:range(1.2, 1.9), 0.25, 0.35),
			CF(x, r * (0.6 + i * 0.25), z) * yaw(a) * ANG(0, 0, rad(rng:range(-25, 25))),
			lava,
			M.Neon,
			{ shadow = false }
		)
		if i == 1 then
			Build.light(seg, lava, 14, 2)
		end
	end
	local vent = Build.block(
		m,
		V3(0.4, 0.4, 0.4),
		CF(x, r * 1.4, z),
		lava,
		M.Neon,
		{ transparency = 1, shadow = false }
	)
	Build.emitter(vent, {
		name = "Smoke",
		texture = Build.TEX.smoke,
		color = Build.cs(Color3.fromRGB(70, 60, 60), Color3.fromRGB(120, 110, 110)),
		size = Build.ns(1, 3.5),
		transparency = Build.ns(0.5, 1),
		lifetime = NumberRange.new(2.5, 4),
		rate = 2,
		speed = NumberRange.new(1.5, 3),
		spread = Vector2.new(12, 12),
		rotSpeed = NumberRange.new(-20, 20),
	})
	Build.emitter(vent, {
		name = "Embers",
		texture = Build.TEX.sparkles,
		color = Build.cs(Color3.fromRGB(255, 200, 80), Color3.fromRGB(255, 80, 20)),
		size = Build.ns(0.35, 0),
		lifetime = NumberRange.new(1, 2),
		rate = 3,
		speed = NumberRange.new(3, 6),
		spread = Vector2.new(30, 30),
		accel = Vector3.new(0, -2, 0),
		lightEmission = 1,
	})
	if solid then
		collider(m, x, z, r, 6)
	end
	return r
end

-- Ocean: branching coral, brain coral, sea fan and swaying kelp.
function Props.coral(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	pal: Palette,
	solid: boolean
): number
	local base = CF(x, 0, z)
	local col = pick(rng, pal.flower)
	Build.egg(m, V3(r * 2, r * 1.2, r * 1.9), base * CF(0, r * 0.3, 0), Build.shade(col, -0.15), M.Pebble)
	-- branching staghorn
	local function branch(cf: CFrame, len: number, d: number, depth: number)
		local tip = cf * CF(0, len, 0)
		Build.ucyl(m, len, d, cf * CF(0, len / 2, 0), col, M.Pebble, { shadow = depth == 0 })
		Build.ball(m, d * 1.15, tip, Build.shade(col, 0.25), M.SmoothPlastic, { shadow = false })
		if depth < 2 then
			for k = -1, 1, 2 do
				branch(tip * ANG(rad(28 * k), rad(rng:range(0, 180)), 0), len * 0.65, d * 0.75, depth + 1)
			end
		end
	end
	branch(base * CF(r * 0.2, r * 0.6, 0) * ANG(rad(8), 0, 0), r * 1.1, r * 0.35, 0)
	-- sea fan
	local fan = pick(rng, pal.flower)
	Build.egg(
		m,
		V3(r * 1.6, r * 1.8, 0.2),
		base * CF(-r * 0.6, r * 1.3, r * 0.3) * yaw(rng:range(0, 3)),
		fan,
		M.Fabric,
		{
			transparency = 0.1,
			shadow = false,
		}
	)
	-- brain coral
	Build.egg(m, V3(r * 0.9, r * 0.7, r * 0.9), base * CF(-r * 0.5, r * 0.55, -r * 0.6), pal.accent, M.Pebble)
	-- kelp
	for i = 1, 2 do
		local a = rng:range(0, 6.28)
		local kcf = base * CF(math.cos(a) * r * 1.1, 0, math.sin(a) * r * 1.1)
		local hh = rng:range(5, 9)
		local n = 4
		for k = 1, n do
			local seg = kcf * CF(math.sin(k * 1.3 + i) * 0.4, hh / n * (k - 0.5), 0)
			local p = Build.block(
				m,
				V3(0.7, hh / n * 1.05, 0.15),
				seg * yaw(k * 0.5),
				pal.moss,
				M.Grass,
				{ shadow = false }
			)
			canopy(p)
		end
	end
	if solid then
		collider(m, x, z, r * 0.9, 5)
	end
	return r * 0.9
end

-- Moon: grey boulders pocked with craters and a glinting cheese vein.
function Props.moonRock(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	pal: Palette,
	solid: boolean
): number
	rockCluster(m, x, z, r, rng, pal, false)
	for i = 1, 3 do
		local a = i * 2 + rng:range(-0.3, 0.3)
		local p = CF(x + math.cos(a) * r * 0.6, r * 1.0, z + math.sin(a) * r * 0.6)
		Build.egg(
			m,
			V3(r * 0.5, 0.2, r * 0.5),
			p * ANG(math.sin(a) * 0.5, 0, -math.cos(a) * 0.5),
			pal.rockDark,
			M.Slate,
			{
				shadow = false,
			}
		)
	end
	local vein = Build.block(
		m,
		V3(r * 1.2, 0.3, 0.4),
		CF(x, r * 0.7, z) * yaw(rng:range(0, 3)),
		Props.CHEESE,
		M.Neon,
		{
			shadow = false,
		}
	)
	vein.Transparency = 0.1
	if solid then
		collider(m, x, z, r, 5)
	end
	return r
end

-- Cheese boulder obstacle: one big wedge + a toppled wheel chunk.
function Props.cheeseRock(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	_pal: Palette,
	solid: boolean
): number
	local cf = CF(x, 0, z) * yaw(rng:range(0, 6.28))
	Props.cheeseWedge(m, cf * CF(0, 0, 0), r * 2, r * 1.1, rng)
	-- a small wedge leaning on it
	Props.cheeseWedge(
		m,
		cf * CF(r * 0.9, 0, -r * 0.4) * yaw(rad(70)),
		r * 0.9,
		r * 0.55,
		rng,
		Props.CHEESE_DARK
	)
	-- crumbs
	for _ = 1, 3 do
		local a = rng:range(0, 6.28)
		Build.block(
			m,
			V3(0.5, 0.4, 0.5),
			CF(x + math.cos(a) * r * 1.2, 0.2, z + math.sin(a) * r * 1.2) * yaw(a),
			Props.CHEESE,
			M.SmoothPlastic,
			{ shadow = false }
		)
	end
	local sr = r * 0.85
	if solid then
		collider(m, x, z, sr, r * 1.1)
	end
	return sr
end

function Props.rock(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	pal: Palette,
	solid: boolean
): number
	rockCluster(m, x, z, r, rng, pal, true)
	if solid then
		collider(m, x, z, r, 5)
	end
	return r
end

function Props.snowRock(
	m: Instance,
	x: number,
	z: number,
	r: number,
	rng: Rng,
	pal: Palette,
	solid: boolean
): number
	rockCluster(m, x, z, r, rng, pal, false)
	Build.egg(
		m,
		V3(r * 1.9, r * 0.5, r * 1.7),
		CF(x, r * 1.1, z),
		Color3.fromRGB(245, 250, 255),
		M.Snow,
		{ shadow = false }
	)
	if solid then
		collider(m, x, z, r, 5)
	end
	return r
end

Props.OBSTACLES = {
	rock = Props.rock,
	snow_rock = Props.snowRock,
	tree = Props.tree,
	pine = Props.pine,
	palm = Props.palm,
	jungle_tree = Props.jungleTree,
	dead_tree = Props.deadTree,
	mushroom = Props.mushroom,
	ice = Props.iceCluster,
	crystal = Props.crystalCluster,
	lava_rock = Props.lavaRock,
	coral = Props.coral,
	moon_rock = Props.moonRock,
	wedge = Props.cheeseRock,
}

-- Small decor (non-colliding) ---------------------------------------------------------------------

Props.DECOR = {}

Props.DECOR.grass = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	local col = pal.leaves[1]
	for i = 0, 2 do
		local a = i * 2.1 + rng:range(-0.3, 0.3)
		Build.wedge(
			m,
			V3(0.25, s * rng:range(0.9, 1.4), 0.5),
			CF(x + math.cos(a) * 0.25, s * 0.55, z + math.sin(a) * 0.25) * yaw(a) * ANG(rad(-8), 0, 0),
			col:Lerp(pal.moss, rng:range(0, 0.5)),
			M.Grass,
			{ shadow = false }
		)
	end
end

Props.DECOR.flower = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	if #pal.flower == 0 then
		Props.DECOR.grass(m, x, z, s, rng, pal)
		return
	end
	local h = s * rng:range(0.8, 1.3)
	Build.ucyl(m, h, 0.12, CF(x, h / 2, z), pal.leaves[1], M.Grass, { shadow = false })
	local col = pick(rng, pal.flower)
	for i = 0, 4 do
		local a = i / 5 * 6.28
		Build.egg(
			m,
			V3(0.42, 0.12, 0.42),
			CF(x + math.cos(a) * 0.22, h, z + math.sin(a) * 0.22),
			col,
			M.SmoothPlastic,
			{
				shadow = false,
			}
		)
	end
	Build.ball(m, 0.22, CF(x, h + 0.05, z), Props.CHEESE, M.SmoothPlastic, { shadow = false })
end

Props.DECOR.pebbles = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	for _ = 1, 3 do
		local a = rng:range(0, 6.28)
		Build.egg(
			m,
			V3(s * rng:range(0.4, 0.8), s * 0.3, s * rng:range(0.4, 0.7)),
			CF(x + math.cos(a) * s * 0.6, 0.05, z + math.sin(a) * s * 0.6) * yaw(a),
			pal.rock:Lerp(pal.rockDark, rng:range(0, 1)),
			pal.rockMaterial or M.Rock,
			{ shadow = false }
		)
	end
end

Props.DECOR.toadstool = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	for i = 1, rng:nextInt(2, 3) do
		local px, pz = x + rng:range(-0.8, 0.8), z + rng:range(-0.8, 0.8)
		local h = s * rng:range(0.5, 0.9) * (1 - i * 0.15)
		Build.ucyl(
			m,
			h,
			0.22,
			CF(px, h / 2, pz),
			Color3.fromRGB(240, 232, 210),
			M.SmoothPlastic,
			{ shadow = false }
		)
		Build.egg(
			m,
			V3(0.9 * h + 0.2, 0.35, 0.9 * h + 0.2),
			CF(px, h, pz),
			pick(rng, pal.flower),
			M.SmoothPlastic,
			{
				shadow = false,
			}
		)
	end
end

Props.DECOR.glowcap = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	for _ = 1, 2 do
		local px, pz = x + rng:range(-0.7, 0.7), z + rng:range(-0.7, 0.7)
		local h = s * rng:range(0.4, 0.8)
		Build.ucyl(
			m,
			h,
			0.18,
			CF(px, h / 2, pz),
			Color3.fromRGB(200, 210, 190),
			M.SmoothPlastic,
			{ shadow = false }
		)
		Build.egg(m, V3(0.7, 0.28, 0.7), CF(px, h, pz), pal.glow, M.Neon, { shadow = false })
	end
end

Props.DECOR.shell = function(m: Instance, x: number, z: number, s: number, rng: Rng, _pal: Palette)
	local colors =
		{ Color3.fromRGB(255, 200, 190), Color3.fromRGB(250, 235, 210), Color3.fromRGB(255, 160, 120) }
	if rng:chance(0.5) then
		-- starfish: five flat arms
		local col = Color3.fromRGB(255, 120, 80)
		for i = 0, 4 do
			Build.wedge(
				m,
				V3(0.35, 0.15, s * 0.7),
				CF(x, 0.08, z) * yaw(i / 5 * 6.28) * CF(0, 0, -s * 0.35) * ANG(0, math.pi, 0),
				col,
				M.SmoothPlastic,
				{
					shadow = false,
				}
			)
		end
		Build.ball(m, 0.4, CF(x, 0.1, z), col, M.SmoothPlastic, { shadow = false })
	else
		Build.egg(
			m,
			V3(s * 0.7, s * 0.35, s * 0.6),
			CF(x, 0.1, z) * yaw(rng:range(0, 6)),
			pick(rng, colors),
			M.Marble,
			{
				shadow = false,
			}
		)
	end
end

Props.DECOR.snowmound = function(m: Instance, x: number, z: number, s: number, rng: Rng, _pal: Palette)
	Build.egg(
		m,
		V3(s * 2.2, s * 0.5, s * 1.8),
		CF(x, 0, z) * yaw(rng:range(0, 6)),
		Color3.fromRGB(240, 246, 255),
		M.Snow,
		{
			shadow = false,
		}
	)
	if rng:chance(0.5) then
		Build.block(
			m,
			V3(0.6, 0.6, 0.6),
			CF(x + 0.6, 0.35, z) * ANG(0.6, 0.4, 0.2),
			Color3.fromRGB(170, 215, 245),
			M.Ice,
			{
				transparency = 0.3,
				shadow = false,
			}
		)
	end
end

Props.DECOR.ember = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	local a = rng:range(0, 3.14)
	Build.block(m, V3(s * 2.5, 0.08, 0.3), CF(x, 0.04, z) * yaw(a), pal.glow, M.Neon, { shadow = false })
	Build.block(
		m,
		V3(s * 1.2, 0.08, 0.22),
		CF(x, 0.04, z) * yaw(a + 0.9) * CF(s * 0.8, 0, 0),
		pal.glow,
		M.Neon,
		{
			shadow = false,
		}
	)
	Build.egg(
		m,
		V3(s * 0.6, s * 0.4, s * 0.6),
		CF(x - 0.5, 0.1, z + 0.3),
		pal.rockDark,
		M.Basalt,
		{ shadow = false }
	)
end

Props.DECOR.reeds = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	for i = 1, 4 do
		local px, pz = x + rng:range(-0.6, 0.6), z + rng:range(-0.6, 0.6)
		local h = s * rng:range(1.2, 2.2)
		Build.ucyl(
			m,
			h,
			0.14,
			CF(px, h / 2, pz) * ANG(rad(rng:range(-8, 8)), 0, rad(rng:range(-8, 8))),
			pal.leaves[1],
			M.Grass,
			{
				shadow = false,
			}
		)
		if i <= 2 then
			Build.egg(
				m,
				V3(0.28, 0.8, 0.28),
				CF(px, h + 0.1, pz),
				Color3.fromRGB(110, 75, 45),
				M.Fabric,
				{ shadow = false }
			)
		end
	end
	Build.egg(m, V3(1.6, 0.08, 1.4), CF(x + 1, 0.04, z - 0.5), pal.moss, M.Grass, { shadow = false })
end

Props.DECOR.crater = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	local n = 8
	local rr = s * rng:range(1.2, 2)
	for i = 0, n - 1 do
		local a = i / n * 6.28
		Build.egg(
			m,
			V3(rr * 0.9, 0.35, 0.7),
			CF(x + math.cos(a) * rr, 0.06, z + math.sin(a) * rr) * yaw(-a + math.pi / 2),
			pal.rock,
			M.Slate,
			{
				shadow = false,
			}
		)
	end
	Build.egg(m, V3(rr * 1.8, 0.05, rr * 1.8), CF(x, 0.02, z), pal.rockDark, M.Slate, { shadow = false })
end

Props.DECOR.bubbles = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	Props.DECOR.pebbles(m, x, z, s, rng, pal)
	local p = Build.block(m, V3(0.3, 0.3, 0.3), CF(x, 0.3, z), Color3.new(1, 1, 1), M.SmoothPlastic, {
		transparency = 1,
		shadow = false,
	})
	Build.emitter(p, {
		name = "Bubbles",
		texture = Build.TEX.sparkles,
		color = Build.cs(Color3.fromRGB(220, 245, 255)),
		size = Build.ns(0.2, 0.45),
		transparency = Build.ns(0.2, 1),
		lifetime = NumberRange.new(3, 5),
		rate = 1.5,
		speed = NumberRange.new(1.5, 3),
		spread = Vector2.new(8, 8),
		lightEmission = 0.5,
	})
end

Props.DECOR.crumbs = function(m: Instance, x: number, z: number, s: number, rng: Rng, _pal: Palette)
	for _ = 1, 3 do
		local a = rng:range(0, 6.28)
		Build.block(
			m,
			V3(0.4, 0.3, 0.4) * s,
			CF(x + math.cos(a) * s * 0.7, 0.12, z + math.sin(a) * s * 0.7) * ANG(rng:range(0, 1), a, 0),
			if rng:chance(0.5) then Props.CHEESE else Props.CHEESE_DARK,
			M.SmoothPlastic,
			{ shadow = false }
		)
	end
end

-- Rim dressing ------------------------------------------------------------------------------------

-- A waterfall pouring down a cliff face at `top` toward `dir` (unit, flat), with
-- foam and mist emitters at the foot.
function Props.waterfall(
	m: Instance,
	top: Vector3,
	dir: Vector3,
	height: number,
	width: number,
	color: Color3
)
	local foot = top + dir * 2 - Vector3.new(0, height, 0)
	local look = CFrame.lookAt(top, top + dir)
	for i = 0, 2 do
		local w = width * (1 - i * 0.18)
		local sheet = Build.block(
			m,
			V3(w, height, 0.4),
			look * CF(0, -height / 2, -0.6 - i * 0.5),
			color:Lerp(Color3.new(1, 1, 1), i * 0.2),
			if i == 0 then M.Glass else M.Neon,
			{ transparency = 0.35 + i * 0.2, shadow = false }
		)
		sheet.Name = "Fall" .. i
	end
	local pool = Build.egg(
		m,
		V3(width * 1.6, 0.4, width * 1.2),
		CFrame.lookAt(foot, foot + dir),
		Color3.fromRGB(230, 250, 255),
		M.Neon,
		{
			transparency = 0.45,
			shadow = false,
		}
	)
	Build.emitter(pool, {
		name = "Mist",
		texture = Build.TEX.smoke,
		color = Build.cs(Color3.fromRGB(235, 248, 255)),
		size = Build.ns(1.5, 4),
		transparency = Build.ns(0.55, 1),
		lifetime = NumberRange.new(1.5, 2.5),
		rate = 6,
		speed = NumberRange.new(2, 4),
		spread = Vector2.new(60, 60),
		rotSpeed = NumberRange.new(-30, 30),
		shape = Enum.ParticleEmitterShape.Box,
	})
	Build.emitter(pool, {
		name = "Spray",
		texture = Build.TEX.sparkles,
		color = Build.cs(Color3.fromRGB(255, 255, 255)),
		size = Build.ns(0.3, 0),
		lifetime = NumberRange.new(0.6, 1.1),
		rate = 10,
		speed = NumberRange.new(5, 9),
		spread = Vector2.new(40, 40),
		accel = Vector3.new(0, -20, 0),
		lightEmission = 0.6,
	})
	local lip = Build.block(
		m,
		V3(width * 1.1, 0.5, 1.4),
		look * CF(0, 0.1, -0.2),
		Color3.fromRGB(200, 240, 255),
		M.Glass,
		{
			transparency = 0.3,
			shadow = false,
		}
	)
	Build.emitter(lip, {
		name = "Flow",
		texture = Build.TEX.sparkles,
		color = Build.cs(Color3.fromRGB(230, 250, 255)),
		size = Build.ns(0.5, 0.2),
		transparency = Build.ns(0.3, 1),
		lifetime = NumberRange.new(1.2, 1.6),
		rate = 8,
		speed = NumberRange.new(1, 2),
		accel = Vector3.new(0, -height * 1.1, 0),
		direction = Enum.NormalId.Front,
		shape = Enum.ParticleEmitterShape.Box,
		lightEmission = 0.4,
	})
end

-- A squad banner: pole, crossbar, hanging flag in the squad colour with a
-- cheese-wedge crest, a brass finial and a coloured light.
function Props.banner(m: Instance, cf: CFrame, color: Color3, height: number): BasePart
	local h = height
	Build.ucyl(m, h, 0.5, cf * CF(0, h / 2, 0), Color3.fromRGB(110, 76, 44), M.Wood)
	Build.ucyl(m, 0.5, 1.6, cf * CF(0, 0.25, 0), Color3.fromRGB(90, 90, 96), M.Slate)
	Build.cyl(m, 3.6, 0.3, cf * CF(0, h - 0.6, 0), Color3.fromRGB(110, 76, 44), M.Wood)
	local finial = Build.ball(m, 0.8, cf * CF(0, h + 0.3, 0), Color3.fromRGB(240, 190, 70), M.Metal)
	local flag = Build.block(m, V3(3.2, 4.4, 0.12), cf * CF(0, h - 3, 0), color, M.Fabric, { name = "Flag" })
	-- swallowtail
	for _, side in { -1, 1 } do
		Build.wedge(
			m,
			V3(0.12, 1.2, 1.6),
			cf * CF(side * 0.8, h - 5.8, 0) * ANG(0, rad(90), 0) * ANG(math.pi, 0, 0),
			color,
			M.Fabric,
			{ shadow = false }
		)
	end
	Build.block(
		m,
		V3(3.3, 0.35, 0.16),
		cf * CF(0, h - 0.95, 0),
		Color3.fromRGB(240, 190, 70),
		M.Metal,
		{ shadow = false }
	)
	Props.cheeseWedge(m, cf * CF(0, h - 3.3, -0.12) * ANG(rad(-90), 0, 0), 1.6, 0.12, nil, Props.CHEESE)
	Build.light(finial, color, 16, 1.5)
	return flag
end

-- Backdrop (plateau) props: cheap silhouettes, 3-6 parts each, so the rim stays
-- inside the part budget. Props.FAR[kind](m, x, z, s, rng, pal)
Props.FAR = {}

local function farTree(
	m: Instance,
	x: number,
	z: number,
	s: number,
	rng: Rng,
	pal: Palette,
	tall: number,
	mat: Enum.Material?
)
	local h = s * tall
	Build.ucyl(m, h, s * 0.6, CF(x, h / 2, z), pal.trunk, M.Wood, { shadow = false })
	for i = 0, 2 do
		local a = i * 2.1 + rng:range(-0.3, 0.3)
		local col = pal.leaves[(i % #pal.leaves) + 1]
		local d = s * (2.4 - i * 0.35)
		Build.egg(
			m,
			V3(d, d * 0.8, d),
			CF(x + math.cos(a) * s * 0.6, h + i * s * 0.55, z + math.sin(a) * s * 0.6),
			col,
			mat or M.Grass
		)
	end
end

Props.FAR.tree = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	farTree(m, x, z, s, rng, pal, 2.2)
end
Props.FAR.jungle_tree = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	farTree(m, x, z, s * 1.2, rng, pal, 3)
end
Props.FAR.palm = function(m: Instance, x: number, z: number, s: number, _rng: Rng, pal: Palette)
	local h = s * 3
	Build.ucyl(m, h, s * 0.45, CF(x, h / 2, z) * ANG(rad(8), 0, 0), pal.trunk, M.Wood, { shadow = false })
	for i = 0, 4 do
		Build.egg(
			m,
			V3(s * 0.7, 0.3, s * 2.4),
			CF(x, h, z) * yaw(i / 5 * 6.28) * CF(0, -0.2, -s * 0.9) * ANG(rad(-15), 0, 0),
			pal.leaves[1],
			M.Grass
		)
	end
end
Props.FAR.pine = function(m: Instance, x: number, z: number, s: number, _rng: Rng, pal: Palette)
	Build.ucyl(m, s * 1.4, s * 0.45, CF(x, s * 0.7, z), pal.trunk, M.Wood, { shadow = false })
	for i = 0, 2 do
		local d = s * (2.6 - i * 0.75)
		Build.egg(
			m,
			V3(d, s * 1.3, d),
			CF(x, s * (1.6 + i * 1.05), z),
			if i % 2 == 0 then pal.leaves[1] else (pal.leaves[2] or pal.leaves[1]),
			M.Grass
		)
	end
	if pal.moss.R > 0.9 then
		Build.egg(m, V3(s * 0.9, s * 0.5, s * 0.9), CF(x, s * 3.9, z), pal.moss, M.Snow)
	end
end
Props.FAR.mushroom = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	Build.ucyl(
		m,
		s * 1.6,
		s * 0.7,
		CF(x, s * 0.8, z),
		Color3.fromRGB(240, 232, 210),
		M.SmoothPlastic,
		{ shadow = false }
	)
	Build.egg(m, V3(s * 2.6, s * 1.1, s * 2.6), CF(x, s * 1.8, z), pick(rng, pal.flower), M.SmoothPlastic)
	Build.egg(m, V3(s * 2.2, 0.2, s * 2.2), CF(x, s * 1.45, z), pal.glow, M.Neon, { shadow = false })
end
Props.FAR.dead_tree = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	local h = s * 2.6
	Build.ucyl(
		m,
		h,
		s * 0.6,
		CF(x, h / 2, z) * ANG(rad(rng:range(-8, 8)), 0, rad(rng:range(-8, 8))),
		pal.trunk,
		M.Wood,
		{ shadow = false }
	)
	for i = 1, 2 do
		Build.ucyl(
			m,
			s * 1.4,
			s * 0.25,
			CF(x, h * (0.55 + i * 0.15), z) * yaw(i * 2.5) * ANG(rad(-55), 0, 0) * CF(0, s * 0.7, 0),
			pal.trunk,
			M.Wood,
			{
				shadow = false,
			}
		)
	end
	Build.egg(m, V3(s * 1.2, s * 0.6, s * 1.2), CF(x, h, z), pal.moss, M.Grass)
end
local function farRock(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	Props.boulder(m, CF(x, 0, z), s * 1.2, rng, pal, pal.moss.G > pal.moss.R)
end
for _, k in { "rock", "lava_rock", "snow_rock", "moon_rock", "coral", "ice", "crystal", "wedge" } do
	Props.FAR[k] = farRock
end
Props.FAR.crystal = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	farRock(m, x, z, s, rng, pal)
	for i = 0, 1 do
		Build.block(
			m,
			V3(s * 0.5, s * 2.2, s * 0.5),
			CF(x + (i - 0.5) * s, s * 1.4, z) * ANG(rad(15 - 30 * i), rad(45), 0),
			pal.glow,
			M.Neon,
			{
				shadow = false,
			}
		)
	end
end
Props.FAR.coral = function(m: Instance, x: number, z: number, s: number, rng: Rng, pal: Palette)
	local col = pick(rng, pal.flower)
	Build.egg(m, V3(s * 2, s * 1.2, s * 2), CF(x, s * 0.4, z), Build.shade(col, -0.15), M.Pebble)
	for i = 0, 2 do
		Build.ucyl(
			m,
			s * 1.6,
			s * 0.35,
			CF(x + (i - 1) * s * 0.5, s * 1.2, z) * ANG(0, 0, rad((i - 1) * 25)),
			col,
			M.Pebble,
			{ shadow = false }
		)
	end
end

return Props
