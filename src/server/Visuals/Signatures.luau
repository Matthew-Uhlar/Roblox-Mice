--!strict
-- Signatures (v4, team G): one SIGNATURE ground feature per map, repeated
-- across the floor so every screen of a big map shows the biome (V4-B S2-4).
--
--   Signatures.build(parent, themeId, R, rng, pal, free) -> {{x, z, r}}
--       free(x, z, r) -> boolean   the caller's clearance test (boss pad,
--                                  corners, POIs, obstacles, river)
--       Returns the footprints so later decor keeps off them.
--   Signatures.NAMES[themeId]      what each map gets (docs / previews)
--
-- Every feature is WALKABLE: terrain repaints, shallow terrain dishes and
-- bumps (at most ~0.8 stud of relief, below the R15 step height, invisible to
-- the 2-D combat sim) plus a few flat or tiny non-colliding parts. So nothing
-- here is an obstacle and the sim's layout is unchanged. Parts are cheap
-- (about 2-8 per feature, `PER_FEATURE_MAX`) and live in the "Signature"
-- folder, which the part budget never thins.

local Build = require(script.Parent.Build)
local Terra = require(script.Parent.Terra)

local Signatures = {}

Signatures.SPACING = 46 -- one feature per this many studs of radius
Signatures.MAX = 14

Signatures.NAMES = {
	plains = "Picnic blankets with cheese wedges in flower meadows",
	forest = "Fairy rings of red toadstools on mossy clearings",
	jungle = "Overgrown glyph plazas with glowing green runes",
	beach = "Tide pools with sandstone rims and starfish",
	tundra = "Cracked ice sheets with snowdrifts",
	volcano = "Glowing lava fissures over cracked-lava ground",
	swamp = "Bog pools with lily pads and glowcaps",
	moon = "Craters with dark rims and glowing crystals",
	ocean = "Coral gardens on cobble patches",
}

local M = Enum.Material
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local rgb = Color3.fromRGB
local NOSH = { shadow = false }

type Rng = any
type Free = (x: number, z: number, r: number) -> boolean

local function yaw(a: number): CFrame
	return ANG(0, a, 0)
end

-- shallow walkable dish of radius a and depth d at (x, z)
local function dish(x: number, z: number, a: number, d: number)
	local rb = (a * a + d * d) / (2 * d)
	Terra.ball(V3(x, rb - d, z), rb, M.Air)
end

-- low bump rising h above Y = 0
local function bump(x: number, z: number, r: number, h: number, mat: Enum.Material)
	Terra.ball(V3(x, -r + h, z), r, mat)
end

local BUILDERS: { [string]: (m: Model, x: number, z: number, r: number, rng: Rng, pal: any) -> () } = {}

BUILDERS.plains = function(m, x, z, r, rng, pal)
	Terra.paint(x, z, r, M.LeafyGrass)
	local a = rng:range(0, 6.28)
	local o = CF(x, 0.06, z) * yaw(a)
	-- red and cream checker blanket (4 tiles)
	for i = 0, 1 do
		for j = 0, 1 do
			local c = if (i + j) % 2 == 0 then rgb(214, 58, 52) else rgb(250, 240, 220)
			Build.block(m, V3(2.4, 0.08, 2.4), o * CF((i - 0.5) * 2.4, 0, (j - 0.5) * 2.4), c, M.Fabric, NOSH)
		end
	end
	Build.wedge(
		m,
		V3(1.4, 0.9, 1.6),
		o * CF(0.6, 0.5, 0.4) * yaw(0.6),
		rgb(255, 210, 80),
		M.SmoothPlastic,
		NOSH
	)
	if #pal.flower > 0 then
		for k = 0, 3 do
			local b = a + k * 1.57 + 0.7
			local px, pz = x + math.cos(b) * (r - 2), z + math.sin(b) * (r - 2)
			Build.ball(m, 0.6, CF(px, 0.35, pz), pal.flower[(k % #pal.flower) + 1], M.SmoothPlastic, NOSH)
		end
	end
end

BUILDERS.forest = function(m, x, z, r, rng, _pal)
	Terra.paint(x, z, r, M.Grass)
	Terra.paint(x, z, r * 0.55, M.LeafyGrass)
	local n = 7
	local a0 = rng:range(0, 6.28)
	for k = 0, n - 1 do
		local a = a0 + k / n * 6.28
		local px, pz = x + math.cos(a) * r * 0.75, z + math.sin(a) * r * 0.75
		local h = rng:range(0.6, 1.1)
		if k % 2 == 0 then
			Build.ucyl(m, h, 0.3, CF(px, h / 2, pz), rgb(240, 232, 210), M.SmoothPlastic, NOSH)
		end
		Build.egg(m, V3(1.3, 0.55, 1.3), CF(px, h, pz), rgb(214, 48, 44), M.SmoothPlastic, NOSH)
	end
end

BUILDERS.jungle = function(m, x, z, r, rng, _pal)
	Terra.paint(x, z, r, M.Sandstone)
	Terra.paint(x, z, r * 0.5, M.Cobblestone)
	local a0 = rng:range(0, 6.28)
	for k = 0, 3 do
		local a = a0 + k * 1.57
		local cf = CF(x + math.cos(a) * r * 0.6, 0.1, z + math.sin(a) * r * 0.6) * yaw(a)
		Build.block(m, V3(3.2, 0.2, 2.2), cf, rgb(150, 150, 120), M.Slate, NOSH)
		Build.block(m, V3(2.2, 0.05, 0.3), cf * CF(0, 0.12, 0), rgb(120, 255, 140), M.Neon, NOSH)
	end
end

BUILDERS.beach = function(m, x, z, r, rng, _pal)
	Terra.paint(x, z, r + 2, M.Salt)
	local pr = r * 0.7
	Build.ucyl(m, 0.08, pr * 2, CF(x, 0.05, z), rgb(80, 180, 220), M.Glass, {
		shadow = false,
		transparency = 0.3,
		reflectance = 0.15,
		name = "TidePool",
	})
	for k = 0, 4 do
		local a = rng:range(0, 6.28)
		local d = rng:range(1, 2)
		Build.ball(
			m,
			d,
			CF(x + math.cos(a) * pr, 0.1, z + math.sin(a) * pr),
			rgb(206, 182, 140),
			M.Sandstone,
			NOSH
		)
		local _ = k
	end
	local sa = rng:range(0, 6.28)
	local star = CF(x + math.cos(sa) * pr * 0.4, 0.12, z + math.sin(sa) * pr * 0.4)
	for k = 0, 1 do
		Build.block(m, V3(1.4, 0.1, 0.35), star * yaw(k * 1.25), rgb(255, 120, 90), M.SmoothPlastic, NOSH)
	end
end

BUILDERS.tundra = function(m, x, z, r, rng, _pal)
	Terra.paint(x, z, r + 2, M.Glacier)
	for k = 0, 2 do
		local a = rng:range(0, 6.28)
		local d = rng:range(0, r * 0.35)
		Build.block(
			m,
			V3(rng:range(r * 0.8, r * 1.2), 0.1, rng:range(r * 0.5, r * 0.8)),
			CF(x + math.cos(a) * d, 0.05 + k * 0.01, z + math.sin(a) * d) * yaw(rng:range(0, 3.14)),
			rgb(190, 225, 245),
			M.Ice,
			{ shadow = false, transparency = 0.15, reflectance = 0.25 }
		)
	end
	for _ = 1, 3 do
		local a = rng:range(0, 6.28)
		bump(x + math.cos(a) * (r + 1), z + math.sin(a) * (r + 1), rng:range(4, 7), 0.7, M.Snow)
	end
end

BUILDERS.volcano = function(m, x, z, r, rng, pal)
	Terra.paint(x, z, r * 0.6, M.CrackedLava)
	local a = rng:range(0, 6.28)
	local p = V3(x, 0.05, z) - V3(math.cos(a), 0, math.sin(a)) * r
	local n = 5
	for _ = 1, n do
		local da = a + rng:range(-0.7, 0.7)
		local len = 2 * r / n + rng:range(-1, 1)
		local q = p + V3(math.cos(da), 0, math.sin(da)) * len
		local mid = (p + q) / 2
		Build.block(m, V3(0.6, 0.08, len + 0.4), CFrame.lookAt(mid, q), pal.glow, M.Neon, NOSH)
		Terra.paint(mid.X, mid.Z, 2.5, M.CrackedLava)
		p = q
	end
end

BUILDERS.swamp = function(m, x, z, r, rng, pal)
	Terra.paint(x, z, r + 1.5, M.Mud)
	local pr = r * 0.75
	Build.ucyl(m, 0.08, pr * 2, CF(x, 0.05, z), rgb(70, 90, 50), M.Glass, {
		shadow = false,
		transparency = 0.25,
		reflectance = 0.1,
		name = "BogPool",
	})
	for _ = 1, 3 do
		local a, d = rng:range(0, 6.28), rng:range(0, pr * 0.7)
		Build.ucyl(
			m,
			0.06,
			rng:range(1.2, 2),
			CF(x + math.cos(a) * d, 0.12, z + math.sin(a) * d),
			rgb(90, 150, 60),
			M.SmoothPlastic,
			NOSH
		)
	end
	local ga = rng:range(0, 6.28)
	Build.egg(
		m,
		V3(1.2, 0.5, 1.2),
		CF(x + math.cos(ga) * (pr + 1), 0.7, z + math.sin(ga) * (pr + 1)),
		pal.glow,
		M.Neon,
		NOSH
	)
end

BUILDERS.moon = function(m, x, z, r, rng, pal)
	Terra.paint(x, z, r + 2.5, M.Basalt)
	Terra.paint(x, z, r * 0.8, M.Slate)
	for k = 0, 5 do
		local a = k / 6 * 6.28 + rng:range(-0.3, 0.3)
		bump(x + math.cos(a) * (r + 1), z + math.sin(a) * (r + 1), rng:range(3, 5), 0.6, M.Basalt)
	end
	dish(x, z, r, 0.9)
	for k = 0, 1 do
		local a = rng:range(0, 6.28)
		Build.wedge(
			m,
			V3(0.6, rng:range(1.2, 2), 0.6),
			CF(x + math.cos(a) * 1.2, 0.4, z + math.sin(a) * 1.2) * yaw(a) * ANG(0.2 * k, 0, 0.15),
			pal.glow,
			M.Neon,
			NOSH
		)
	end
end

BUILDERS.ocean = function(m, x, z, r, rng, pal)
	Terra.paint(x, z, r, M.Cobblestone)
	local flowers = pal.flower
	for k = 1, 5 do
		local a, d = rng:range(0, 6.28), rng:range(0, r * 0.7)
		local px, pz = x + math.cos(a) * d, z + math.sin(a) * d
		local h = rng:range(0.8, 1.8)
		local c = if #flowers > 0 then flowers[(k % #flowers) + 1] else pal.accent
		if k % 2 == 0 then
			Build.ball(m, h, CF(px, h * 0.35, pz), c, M.SmoothPlastic, NOSH)
		else
			Build.ucyl(
				m,
				h,
				0.45,
				CF(px, h / 2, pz) * ANG(rng:range(-0.3, 0.3), 0, 0),
				c,
				M.SmoothPlastic,
				NOSH
			)
		end
	end
end

Signatures.PER_FEATURE_MAX = 9

function Signatures.build(
	parent: Instance,
	themeId: string,
	R: number,
	rng: Rng,
	pal: any,
	free: Free
): { any }
	local fn = BUILDERS[themeId] or BUILDERS.plains
	local folder = Instance.new("Folder")
	folder.Name = "Signature"
	folder:SetAttribute("Kind", Signatures.NAMES[themeId] or Signatures.NAMES.plains)
	folder.Parent = parent
	local n = math.min(Signatures.MAX, math.floor(R / Signatures.SPACING))
	local out = {}
	local tries = 0
	while #out < n and tries < n * 25 do
		tries += 1
		local a, d = rng:range(0, 6.28), math.sqrt(rng:range(0.04, 1)) * (R - 16)
		local x, z = math.cos(a) * d, math.sin(a) * d
		local r = rng:range(6, 10)
		local clear = free(x, z, r + 2)
		if clear then
			for _, o in out do
				if (x - o.x) ^ 2 + (z - o.z) ^ 2 < (o.r + r + 30) ^ 2 then
					clear = false
					break
				end
			end
		end
		if clear then
			local m = Instance.new("Model")
			m.Name = themeId .. "_sig" .. (#out + 1)
			m:SetAttribute("X", x)
			m:SetAttribute("Z", z)
			m:SetAttribute("Radius", r + 2)
			m.Parent = folder
			fn(m, x, z, r, rng, pal)
			table.insert(out, { x = x, z = z, r = r + 2 })
		end
	end
	return out
end

return Signatures
