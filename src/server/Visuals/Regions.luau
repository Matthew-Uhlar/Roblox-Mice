--!strict
-- Regions (v3 Graphics): the big-map layer of ArenaBuilder (radius 320-400).
--
--   Regions.CONFIG[themeId]                      region mix, river kind, landmarks
--   Regions.plan(R, rng, theme, keepOut) -> Plan regions + river polyline
--   Regions.paintGround(plan, th, rng)            terrain: region patches, river bed
--   Regions.paths(lines, mat, width)              terrain: roads (rotated FillBlocks)
--   Regions.river(parent, plan, cfg)              water / lava overlay strips (parts)
--   Regions.LITE[kind](m, x, z, r, rng, pal, cfg) -> solidR   part-light obstacles
--   Regions.landmark(parent, id, cf, pal, rng)    set-pieces seen from far away
--   Regions.regionDecor(parent, plan, ...)        ruins walls, flowers, reeds
--
-- Most of the mass is Terrain (free in the part budget): rock outcrops and
-- mesas are terrain balls / cylinders around ONE invisible collider, rivers are
-- painted beds under a few translucent strips, roads are rotated fill blocks.
-- The play floor stays flat at Y = 0 (the combat sim's plane): only obstacle
-- footprints rise above it, and every visual stays inside its collider circle
-- at ground level. Landmarks stand outside the barrier on the rim plateau (or
-- as one big obstacle inside), tagged "Landmark" so low-spec devices keep them.

local Build = require(script.Parent.Build)
local Props = require(script.Parent.Props)
local Terra = require(script.Parent.Terra)

local Regions = {}

local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local rad = math.rad
local M = Enum.Material
local rgb = Color3.fromRGB

type Rng = any

export type Region = { kind: string, x: number, z: number, r: number }
export type Plan = { regions: { Region }, river: { Vector3 }, R: number }
export type Config = {
	regions: { { kind: string, weight: number } },
	river: string, -- "water" | "lava" | "ice" | "murk" | "trench" | "none"
	riverColor: Color3,
	landmarks: { string }, -- rim set-pieces (outside the barrier)
	inner: string?, -- one big set-piece obstacle inside the arena
	ruinStone: Color3,
	ruinGround: Enum.Material,
	tree: string, -- lite tree flavour: "tree" | "pine" | "palm" | "jungle" | "dead" | "mushroom" | "coral" | "crystal"
	rockMat: Enum.Material,
	rockTop: Enum.Material?,
}

local WATER = rgb(70, 160, 210)

Regions.CONFIG = {
	plains = {
		regions = {
			{ kind = "forest", weight = 3 },
			{ kind = "rocks", weight = 2 },
			{ kind = "meadow", weight = 3 },
			{ kind = "ruins", weight = 1 },
			{ kind = "mesa", weight = 1 },
		},
		river = "water",
		riverColor = WATER,
		landmarks = { "windmill", "cheese_wheel" },
		inner = "cheese_wheel",
		ruinStone = rgb(200, 192, 176),
		ruinGround = M.Cobblestone,
		tree = "tree",
		rockMat = M.Rock,
	},
	forest = {
		regions = {
			{ kind = "forest", weight = 5 },
			{ kind = "rocks", weight = 1 },
			{ kind = "ruins", weight = 1 },
			{ kind = "meadow", weight = 1 },
			{ kind = "mesa", weight = 1 },
		},
		river = "water",
		riverColor = rgb(60, 140, 170),
		landmarks = { "giant_tree", "cheese_wheel" },
		inner = "cheese_wheel",
		ruinStone = rgb(160, 160, 150),
		ruinGround = M.Cobblestone,
		tree = "pine",
		rockMat = M.Rock,
	},
	jungle = {
		regions = {
			{ kind = "forest", weight = 5 },
			{ kind = "ruins", weight = 2 },
			{ kind = "rocks", weight = 1 },
			{ kind = "mesa", weight = 1 },
		},
		river = "water",
		riverColor = rgb(60, 150, 140),
		landmarks = { "temple" },
		inner = "idol",
		ruinStone = rgb(150, 160, 130),
		ruinGround = M.Cobblestone,
		tree = "jungle",
		rockMat = M.Rock,
	},
	beach = {
		regions = {
			{ kind = "forest", weight = 2 },
			{ kind = "rocks", weight = 2 },
			{ kind = "dunes", weight = 3 },
			{ kind = "ruins", weight = 1 },
		},
		river = "water",
		riverColor = rgb(70, 200, 220),
		landmarks = { "lighthouse" },
		inner = "cheese_wheel",
		ruinStone = rgb(230, 214, 180),
		ruinGround = M.Sandstone,
		tree = "palm",
		rockMat = M.Sandstone,
	},
	tundra = {
		regions = {
			{ kind = "forest", weight = 3 },
			{ kind = "rocks", weight = 2 },
			{ kind = "crystals", weight = 2 },
			{ kind = "mesa", weight = 1 },
		},
		river = "ice",
		riverColor = rgb(160, 210, 240),
		landmarks = { "ice_spire" },
		inner = "ice_spire_small",
		ruinStone = rgb(190, 200, 215),
		ruinGround = M.Slate,
		tree = "pine",
		rockMat = M.Glacier,
		rockTop = M.Snow,
	},
	volcano = {
		regions = {
			{ kind = "rocks", weight = 4 },
			{ kind = "crystals", weight = 2 },
			{ kind = "mesa", weight = 2 },
			{ kind = "ruins", weight = 1 },
		},
		river = "lava",
		riverColor = rgb(255, 120, 30),
		landmarks = { "volcano" },
		inner = nil,
		ruinStone = rgb(90, 80, 80),
		ruinGround = M.Slate,
		tree = "crystal",
		rockMat = M.Basalt,
		rockTop = M.CrackedLava,
	},
	swamp = {
		regions = {
			{ kind = "forest", weight = 4 },
			{ kind = "bog", weight = 3 },
			{ kind = "ruins", weight = 1 },
			{ kind = "rocks", weight = 1 },
		},
		river = "murk",
		riverColor = rgb(90, 120, 60),
		landmarks = { "witch_tower" },
		inner = nil,
		ruinStone = rgb(120, 125, 110),
		ruinGround = M.Slate,
		tree = "dead",
		rockMat = M.Slate,
	},
	moon = {
		regions = {
			{ kind = "craters", weight = 4 },
			{ kind = "rocks", weight = 2 },
			{ kind = "crystals", weight = 2 },
			{ kind = "mesa", weight = 1 },
		},
		river = "none",
		riverColor = rgb(150, 150, 170),
		landmarks = { "spaceship" },
		inner = "satellite",
		ruinStone = rgb(170, 170, 185),
		ruinGround = M.Slate,
		tree = "crystal",
		rockMat = M.Rock,
	},
	ocean = {
		regions = {
			{ kind = "reef", weight = 4 },
			{ kind = "rocks", weight = 2 },
			{ kind = "ruins", weight = 2 },
			{ kind = "dunes", weight = 1 },
		},
		river = "trench",
		riverColor = rgb(40, 80, 130),
		landmarks = { "shipwreck" },
		inner = nil,
		ruinStone = rgb(200, 210, 210),
		ruinGround = M.Cobblestone,
		tree = "coral",
		rockMat = M.Rock,
	},
} :: { [string]: Config }

function Regions.config(themeId: string): Config
	return Regions.CONFIG[themeId] or Regions.CONFIG.plains
end

local function weighted(rng: Rng, list: { { kind: string, weight: number } }): string
	local w = {}
	for i, e in list do
		w[i] = e.weight
	end
	return list[rng:weightedIndex(w)].kind
end

----------------------------------------------------------------------
-- Planning
----------------------------------------------------------------------

export type Circle = { x: number, z: number, r: number }

local function clear(x: number, z: number, r: number, keep: { Circle }): boolean
	for _, c in keep do
		local need = c.r + r
		if (x - c.x) ^ 2 + (z - c.z) ^ 2 < need * need then
			return false
		end
	end
	return true
end
Regions.clear = clear

-- Region blobs (Poisson-ish: spaced apart, clear of the keep-out circles) and a
-- meandering river from rim to rim that bends round the boss pad.
function Regions.plan(R: number, rng: Rng, cfg: Config, keepOut: { Circle }, padR: number): Plan
	local regions: { Region } = {}
	local want = math.clamp(math.floor(R / 26), 8, 16)
	local tries = 0
	while #regions < want and tries < want * 40 do
		tries += 1
		local rr = rng:range(R * 0.07, R * 0.12)
		local a = rng:range(0, math.pi * 2)
		local d = math.sqrt(rng:range(0.04, 1)) * (R - rr - 10)
		local x, z = math.cos(a) * d, math.sin(a) * d
		if x * x + z * z < (padR + rr + 12) ^ 2 or not clear(x, z, rr * 0.4, keepOut) then
			continue
		end
		local ok = true
		for _, g in regions do
			if (x - g.x) ^ 2 + (z - g.z) ^ 2 < (g.r + rr + 14) ^ 2 then
				ok = false
				break
			end
		end
		if ok then
			table.insert(regions, { kind = weighted(rng, cfg.regions), x = x, z = z, r = rr })
		end
	end
	-- river: an S-curve chord across the map, pushed round the boss pad
	local river: { Vector3 } = {}
	if cfg.river ~= "none" then
		local a0 = rng:range(0, math.pi * 2)
		local a1 = a0 + math.pi + rng:range(-0.5, 0.5)
		local p0 = V3(math.cos(a0), 0, math.sin(a0)) * (R + 4)
		local p1 = V3(math.cos(a1), 0, math.sin(a1)) * (R + 4)
		local dir = (p1 - p0).Unit
		local side = V3(-dir.Z, 0, dir.X)
		local wob, ph = rng:range(0.08, 0.14) * R, rng:range(0, math.pi * 2)
		local n = math.floor((p1 - p0).Magnitude / 14)
		for i = 0, n do
			local t = i / n
			local p = p0:Lerp(p1, t) + side * math.sin(t * math.pi * 2 + ph) * wob
			-- bend away from the centre (boss pad) and keep a lane round it
			local d = p.Magnitude
			local minD = padR + 34
			if d < minD then
				p = (if d > 1e-3 then p.Unit else side) * minD
			end
			table.insert(river, p)
		end
	end
	return { regions = regions, river = river, R = R }
end

-- Distance from (x, z) to the river polyline (math.huge without a river).
function Regions.riverDistance(plan: Plan, x: number, z: number): number
	local best = math.huge
	local pts = plan.river
	local p = V3(x, 0, z)
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local ab = b - a
		local t = math.clamp((p - a):Dot(ab) / math.max(1e-6, ab:Dot(ab)), 0, 1)
		local d = (a + ab * t - p).Magnitude
		if d < best then
			best = d
		end
	end
	return best
end

----------------------------------------------------------------------
-- Terrain painting
----------------------------------------------------------------------

-- A straight band of `mat` on the top voxel layer from a to b (flat at Y = 0).
local function band(a: Vector3, b: Vector3, w: number, mat: Enum.Material)
	local d = b - a
	local len = d.Magnitude
	if len < 0.5 then
		Terra.paint(a.X, a.Z, w / 2, mat)
		return
	end
	local mid = (a + b) / 2
	local cf = CFrame.lookAt(V3(mid.X, -2, mid.Z), V3(b.X, -2, b.Z))
	Terra.block(cf, V3(w, 4, len + w * 0.3), mat)
end
Regions.band = band

function Regions.paths(lines: { { Vector3 } }, mat: Enum.Material, width: number)
	for _, line in lines do
		for i = 1, #line - 1 do
			band(line[i], line[i + 1], width, mat)
		end
		for _, p in line do
			Terra.paint(p.X, p.Z, width * 0.55, mat)
		end
	end
end

-- A wobbly road from a to b in segments of ~14 studs.
function Regions.road(a: Vector3, b: Vector3, rng: Rng, wobble: number?): { Vector3 }
	local out = {}
	local d = b - a
	local n = math.max(1, math.floor(d.Magnitude / 14))
	local side = V3(-d.Z, 0, d.X).Unit
	local amp = (wobble or 0.08) * d.Magnitude
	local ph = rng:range(0, math.pi * 2)
	for i = 0, n do
		local t = i / n
		table.insert(
			out,
			a:Lerp(b, t) + side * math.sin(t * math.pi + ph * 0.2) * amp * math.sin(t * math.pi)
		)
	end
	return out
end

-- Ring road of radius rr round the centre.
function Regions.ring(rr: number): { Vector3 }
	local out = {}
	local n = math.max(12, math.floor(2 * math.pi * rr / 14))
	for i = 0, n do
		local a = i / n * math.pi * 2
		table.insert(out, V3(math.cos(a) * rr, 0, math.sin(a) * rr))
	end
	return out
end

local GROUND: { [string]: (th: any, cfg: Config) -> { Enum.Material } } = {
	forest = function(th, _cfg)
		return { M.LeafyGrass, th.patches[1] or M.Mud, M.LeafyGrass }
	end,
	rocks = function(th, cfg)
		return { th.patches[#th.patches] or M.Ground, cfg.rockMat }
	end,
	meadow = function(_th, _cfg)
		return { M.Grass, M.LeafyGrass }
	end,
	ruins = function(_th, cfg)
		return { cfg.ruinGround, cfg.ruinGround, M.Ground }
	end,
	mesa = function(th, _cfg)
		return { th.patches[1] or M.Ground }
	end,
	dunes = function(_th, _cfg)
		return { M.Sand, M.Sandstone }
	end,
	crystals = function(th, _cfg)
		return { th.patches[1] or M.Slate, th.patches[2] or M.Slate }
	end,
	bog = function(_th, _cfg)
		return { M.Mud, M.Mud, M.LeafyGrass }
	end,
	craters = function(th, _cfg)
		return { th.patches[1] or M.Slate, th.patches[2] or M.Basalt }
	end,
	reef = function(_th, _cfg)
		return { M.Sand, M.Limestone, M.Cobblestone }
	end,
}

function Regions.paintGround(plan: Plan, th: any, cfg: Config, rng: Rng)
	for _, g in plan.regions do
		local mats = (GROUND[g.kind] or GROUND.meadow)(th, cfg)
		local n = math.clamp(math.floor(g.r / 5), 4, 10)
		for i = 1, n do
			local a, d = rng:range(0, math.pi * 2), math.sqrt(rng:range(0, 1)) * g.r * 0.85
			Terra.paint(
				g.x + math.cos(a) * d,
				g.z + math.sin(a) * d,
				rng:range(g.r * 0.25, g.r * 0.55),
				mats[(i - 1) % #mats + 1]
			)
		end
		if g.kind == "craters" then
			-- shallow-looking craters: dark rings around a lighter floor
			for _ = 1, 3 do
				local a, d = rng:range(0, math.pi * 2), rng:range(0, g.r * 0.6)
				local cx, cz = g.x + math.cos(a) * d, g.z + math.sin(a) * d
				local cr = rng:range(5, 11)
				Terra.paint(cx, cz, cr, M.Basalt)
				Terra.paint(cx, cz, cr * 0.75, M.Slate)
			end
		end
	end
	-- river bed: banks + bed (top layer only)
	local pts = plan.river
	if #pts > 1 then
		local bank, bed = M.Sand, M.Mud
		if cfg.river == "lava" then
			bank, bed = M.Basalt, M.CrackedLava
		elseif cfg.river == "ice" then
			bank, bed = M.Snow, M.Glacier
		elseif cfg.river == "murk" then
			bank, bed = M.Mud, M.Slate
		elseif cfg.river == "trench" then
			bank, bed = M.Cobblestone, M.Basalt
		end
		for i = 1, #pts - 1 do
			band(pts[i], pts[i + 1], 20, bank)
		end
		for i = 1, #pts - 1 do
			band(pts[i], pts[i + 1], 12, bed)
		end
	end
end

----------------------------------------------------------------------
-- River overlay (a few translucent strips; ice and trenches are terrain only)
----------------------------------------------------------------------

function Regions.river(parent: Instance, plan: Plan, cfg: Config, keepOut: { Circle }): number
	local pts = plan.river
	if #pts < 2 or cfg.river == "ice" or cfg.river == "trench" then
		return 0
	end
	local count = 0
	local step = 3 -- strips span 3 polyline segments (~42 studs)
	local i = 1
	local lights = 0
	while i < #pts do
		local a, b = pts[i], pts[math.min(#pts, i + step)]
		local mid = (a + b) / 2
		local len = (b - a).Magnitude + 4
		if clear(mid.X, mid.Z, 4, keepOut) and mid.Magnitude < plan.R - 2 then
			local cf = CFrame.lookAt(V3(mid.X, 0.07, mid.Z), V3(b.X, 0.07, b.Z))
			local p: BasePart
			if cfg.river == "lava" then
				p = Build.block(parent, V3(8, 0.12, len), cf, cfg.riverColor, M.Neon, {
					name = "Lava",
					transparency = 0.15,
					shadow = false,
				})
				if lights < 4 then
					lights += 1
					Build.light(p, cfg.riverColor, 30, 1.6)
				end
			else
				p = Build.block(parent, V3(10, 0.12, len), cf, cfg.riverColor, M.SmoothPlastic, {
					name = "Water",
					transparency = if cfg.river == "murk" then 0.25 else 0.4,
					reflectance = 0.2,
					shadow = false,
				})
				-- foam edges
				for _, s in { -1, 1 } do
					Build.block(
						parent,
						V3(0.8, 0.13, len),
						cf * CF(s * 5, 0.005, 0),
						rgb(235, 248, 255),
						M.SmoothPlastic,
						{
							name = "Foam",
							transparency = 0.45,
							shadow = false,
						}
					)
					count += 1
				end
			end
			p:SetAttribute("River", true)
			count += 1
		end
		i += step
	end
	return count
end

----------------------------------------------------------------------
-- Part-light obstacles (most of the mass is terrain)
----------------------------------------------------------------------

local function collider(m: Instance, x: number, z: number, r: number, h: number)
	local c = Build.ucyl(m, h, r * 2, CF(x, h / 2, z), Color3.new(1, 1, 1), M.SmoothPlastic, {
		name = "Collider",
		collide = true,
		transparency = 1,
		shadow = false,
	})
	c:SetAttribute("Collider", true)
end

local function canopy(p: BasePart): BasePart
	p:AddTag("Canopy")
	return p
end

local function pick(rng: Rng, list: { any }): any
	return list[rng:nextInt(1, #list)]
end

-- Terrain rock outcrop that stays inside its collider at ground level.
local function outcrop(x: number, z: number, r: number, rng: Rng, mat: Enum.Material, top: Enum.Material?)
	Terra.ball(V3(x, r * 0.5, z), r * 1.1, mat)
	for _ = 1, 2 do
		local a = rng:range(0, math.pi * 2)
		local rr = r * rng:range(0.45, 0.65)
		Terra.ball(V3(x + math.cos(a) * r * 0.35, r * 0.45 + rr * 0.4, z + math.sin(a) * r * 0.35), rr, mat)
	end
	if top then
		Terra.ball(V3(x, r * 1.25, z), r * 0.55, top)
	end
end

local LITE: { [string]: (Instance, number, number, number, Rng, any, Config) -> number } = {}

LITE.rock = function(m, x, z, r, rng, pal, cfg)
	outcrop(x, z, r, rng, cfg.rockMat, cfg.rockTop)
	if rng:nextFloat() < 0.5 then
		Build.egg(
			m,
			V3(r * 1.1, r * 0.25, r * 0.9),
			CF(x, r * 1.35, z) * ANG(0, rng:range(0, 6.28), 0),
			pal.moss,
			M.Grass,
			{
				shadow = false,
			}
		)
	end
	collider(m, x, z, r, r * 1.6)
	return r
end

local function treeParts(m: Instance, x: number, z: number, r: number, rng: Rng, pal: any, flavour: string)
	local h = rng:range(9, 13) * math.clamp(r / 3.5, 0.8, 1.4)
	local tr = r * 0.5
	local leaves = pal.leaves
	if flavour == "pine" then
		Build.ucyl(m, h * 0.4, tr, CF(x, h * 0.2, z), pal.trunk, M.Wood)
		for i = 0, 2 do
			local w = r * (2.6 - i * 0.7)
			canopy(
				Build.egg(
					m,
					V3(w, h * 0.32, w),
					CF(x, h * (0.38 + i * 0.22), z),
					leaves[math.min(#leaves, i + 1)],
					M.Grass
				)
			)
		end
		return h
	elseif flavour == "palm" then
		local lean = rng:range(-0.25, 0.25)
		Build.ucyl(m, h, tr * 0.8, CF(x, h / 2, z) * ANG(lean, 0, lean * 0.6), pal.trunk, M.Wood)
		local top = CF(x, 0, z) * ANG(lean, 0, lean * 0.6) * CF(0, h, 0)
		for i = 0, 4 do
			local a = i / 5 * math.pi * 2
			canopy(
				Build.egg(
					m,
					V3(r * 0.8, 0.3, r * 2.6),
					top * ANG(0, a, 0) * CF(0, -0.4, -r * 1.1) * ANG(rad(-18), 0, 0),
					leaves[i % #leaves + 1],
					M.Grass
				)
			)
		end
		return h
	elseif flavour == "dead" then
		Build.ucyl(m, h * 0.8, tr, CF(x, h * 0.4, z), pal.trunk, M.Wood)
		for i = 0, 1 do
			local a = rng:range(0, 6.28)
			Build.cyl(
				m,
				h * 0.35,
				tr * 0.45,
				CF(x, h * (0.5 + i * 0.2), z) * ANG(0, a, rad(35)) * CF(h * 0.15, 0, 0),
				pal.trunk,
				M.Wood
			)
		end
		canopy(
			Build.egg(
				m,
				V3(r * 1.6, r * 0.7, r * 1.6),
				CF(x, h * 0.85, z),
				pal.moss,
				M.Grass,
				{ transparency = 0.15 }
			)
		)
		return h
	elseif flavour == "mushroom" then
		Build.ucyl(m, h * 0.6, tr * 1.1, CF(x, h * 0.3, z), rgb(240, 230, 210))
		canopy(
			Build.egg(
				m,
				V3(r * 3, r * 1.3, r * 3),
				CF(x, h * 0.62, z),
				pick(rng, pal.flower),
				M.SmoothPlastic
			)
		)
		return h
	elseif flavour == "coral" then
		for i = 0, 2 do
			local a = i / 3 * math.pi * 2 + rng:range(0, 1)
			Build.egg(
				m,
				V3(r * 0.7, h * 0.55, r * 0.7),
				CF(x + math.cos(a) * r * 0.35, h * 0.28, z + math.sin(a) * r * 0.35)
					* ANG(math.cos(a) * 0.3, 0, math.sin(a) * 0.3),
				pick(rng, pal.flower),
				M.SmoothPlastic
			)
		end
		return h * 0.6
	elseif flavour == "crystal" then
		for i = 0, 2 do
			local a = i / 3 * math.pi * 2 + rng:range(0, 1)
			local hh = h * rng:range(0.35, 0.7)
			Build.block(
				m,
				V3(r * 0.6, hh, r * 0.6),
				CF(x + math.cos(a) * r * 0.3, hh / 2, z + math.sin(a) * r * 0.3)
					* ANG(math.cos(a) * 0.3, a, math.sin(a) * 0.3),
				pal.glow,
				M.Neon,
				{
					transparency = 0.15,
				}
			)
		end
		return h * 0.6
	elseif flavour == "jungle" then
		Build.ucyl(m, h * 1.1, tr, CF(x, h * 0.55, z), pal.trunk, M.Wood)
		for i = 0, 2 do
			local a = i / 3 * math.pi * 2 + rng:range(0, 1)
			canopy(
				Build.egg(
					m,
					V3(r * 2.4, r * 1.2, r * 2.4),
					CF(x + math.cos(a) * r * 0.9, h * 1.05 + i * 0.4, z + math.sin(a) * r * 0.9),
					leaves[i % #leaves + 1],
					M.Grass
				)
			)
		end
		return h
	end
	-- broadleaf
	Build.ucyl(m, h * 0.55, tr, CF(x, h * 0.27, z), pal.trunk, M.Wood)
	for i = 0, 2 do
		local a = i / 3 * math.pi * 2 + rng:range(0, 1)
		canopy(
			Build.egg(
				m,
				V3(r * 2.3, r * 1.9, r * 2.3),
				CF(x + math.cos(a) * r * 0.7, h * 0.62 + (i % 2) * r * 0.5, z + math.sin(a) * r * 0.7),
				leaves[i % #leaves + 1],
				M.Grass
			)
		)
	end
	canopy(Build.egg(m, V3(r * 2, r * 1.7, r * 2), CF(x, h * 0.62 + r * 1.1, z), leaves[#leaves], M.Grass))
	return h
end

LITE.tree = function(m, x, z, r, rng, pal, cfg)
	local h = treeParts(m, x, z, r, rng, pal, cfg.tree)
	local solidR = if cfg.tree == "coral" or cfg.tree == "crystal" then r * 0.8 else r * 0.5
	collider(m, x, z, solidR, h)
	return solidR
end

LITE.pillar = function(m, x, z, r, rng, _pal, cfg)
	local broken = rng:nextFloat() < 0.5
	local h = if broken then rng:range(3, 6) else rng:range(8, 12)
	local d = math.min(r * 1.3, 3.2)
	Build.block(
		m,
		V3(d * 1.4, 0.8, d * 1.4),
		CF(x, 0.4, z),
		cfg.ruinStone:Lerp(Color3.new(0, 0, 0), 0.12),
		M.Slate
	)
	Build.ucyl(
		m,
		h,
		d,
		CF(x, h / 2 + 0.8, z) * ANG(0, 0, if broken then rng:range(-0.08, 0.08) else 0),
		cfg.ruinStone,
		M.Slate
	)
	if not broken then
		Build.block(m, V3(d * 1.35, 0.7, d * 1.35), CF(x, h + 1.15, z), cfg.ruinStone, M.Slate)
	end
	local solidR = d * 0.7
	collider(m, x, z, solidR, h + 1)
	return solidR
end

-- A big terrain plateau (cliff mesa) with a cheap crown of trees.
LITE.mesa = function(m, x, z, r, rng, pal, cfg)
	local h = rng:range(7, 13)
	Terra.cylinder(CF(x, h / 2, z), h, r, cfg.rockMat)
	Terra.cylinder(CF(x, h - 1, z), 2, r - 1, cfg.rockTop or M.Grass)
	for _ = 1, 3 do
		local a = rng:range(0, math.pi * 2)
		Terra.ball(
			V3(x + math.cos(a) * r * 0.75, h * 0.35, z + math.sin(a) * r * 0.75),
			r * 0.32,
			cfg.rockMat
		)
	end
	for i = 1, 2 do
		local a = rng:range(0, math.pi * 2)
		local tx, tz = x + math.cos(a) * r * 0.4 * i, z + math.sin(a) * r * 0.4 * i
		local tm = Instance.new("Model")
		tm.Name = "MesaTree"
		tm.Parent = m
		treeParts(tm, tx, tz, 2.4, rng, pal, cfg.tree)
		tm:PivotTo(tm:GetPivot() + V3(0, h - 0.5, 0))
	end
	collider(m, x, z, r, h + 2)
	return r
end

Regions.LITE = LITE

-- Lite kind for an obstacle in a region of type `kind`.
function Regions.liteKind(kind: string): string
	if kind == "forest" or kind == "reef" or kind == "bog" then
		return "tree"
	elseif kind == "ruins" then
		return "pillar"
	elseif kind == "crystals" then
		return "tree" -- crystal / coral flavour comes from the config
	end
	return "rock"
end

----------------------------------------------------------------------
-- Region decor (non-colliding; tagged "Decor" by the caller)
----------------------------------------------------------------------

-- Fallen blocks and wall stubs for ruins; flower beds for meadows; reeds for bogs.
function Regions.ruinWall(m: Instance, x: number, z: number, rng: Rng, cfg: Config)
	local a = rng:range(0, math.pi * 2)
	local n = rng:nextInt(2, 4)
	for i = 0, n - 1 do
		local h = rng:range(1.2, 3.2)
		Build.block(
			m,
			V3(2.8, h, 1.2),
			CF(x, h / 2, z) * ANG(0, a, 0) * CF((i - n / 2) * 2.9, 0, 0) * ANG(0, 0, rng:range(-0.04, 0.04)),
			cfg.ruinStone:Lerp(Color3.new(0, 0, 0), rng:range(0, 0.15)),
			M.Slate
		)
	end
end

----------------------------------------------------------------------
-- Landmarks (set-pieces readable from far away)
----------------------------------------------------------------------

local LANDMARKS: { [string]: (Instance, CFrame, any, Rng) -> () } = {}

-- Spinning parts: the client turns models tagged "Spinner" about their pivot's
-- Z axis at attribute SpinSpeed rad/s (Visuals/DetailLevel).
local function spinner(m: Model, speed: number)
	m:AddTag("Spinner")
	m:SetAttribute("SpinSpeed", speed)
end

LANDMARKS.windmill = function(p, cf, _pal, _rng)
	local stone, wood = rgb(225, 214, 190), rgb(150, 100, 60)
	for i = 0, 2 do
		local h = 14
		Build.ucyl(
			p,
			h,
			16 - i * 3,
			cf * CF(0, h / 2 + i * h, 0),
			stone:Lerp(rgb(255, 255, 255), i * 0.05),
			M.Slate
		)
	end
	Build.egg(p, V3(14, 12, 14), cf * CF(0, 45, 0), rgb(200, 70, 50), M.WoodPlanks)
	Build.block(p, V3(4, 7, 1), cf * CF(0, 3.5, -8), wood, M.WoodPlanks)
	for i = 0, 3 do
		Build.block(
			p,
			V3(2.4, 3, 0.6),
			cf * CF(math.cos(i * 1.57) * 6.8, 20 + i * 4, math.sin(i * 1.57) * 6.8) * ANG(0, -i * 1.57, 0),
			rgb(120, 170, 220),
			M.Glass,
			{
				transparency = 0.2,
			}
		)
	end
	local hub = Instance.new("Model")
	hub.Name = "Blades"
	local at = cf * CF(0, 42, -8.5)
	Build.ball(hub, 3, at, wood, M.Wood)
	for i = 0, 3 do
		local a = i * math.pi / 2
		Build.block(hub, V3(4, 26, 0.5), at * ANG(0, 0, a) * CF(0, 14, -0.6), rgb(250, 245, 230), M.Fabric)
		Build.block(hub, V3(0.6, 28, 0.6), at * ANG(0, 0, a) * CF(0, 14, -0.3), wood, M.Wood)
	end
	hub.WorldPivot = at
	hub.Parent = p
	spinner(hub, 0.6)
end

LANDMARKS.cheese_wheel = function(p, cf, _pal, _rng)
	local c, rind, hole = Props.CHEESE, Props.RIND, Props.HOLE
	-- a giant wheel standing on its edge with a slice missing
	local wheel = cf * CF(0, 13, 0) * ANG(0, 0, 0)
	Build.cyl(p, 9, 26, wheel, rind, M.SmoothPlastic)
	Build.cyl(p, 9.2, 23.5, wheel, c, M.SmoothPlastic)
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2 + 0.3
		local rr = if i % 2 == 0 then 6 else 9
		for _, s in { -1, 1 } do
			Build.cyl(
				p,
				0.3,
				if i % 2 == 0 then 3.2 else 2.2,
				wheel * CF(s * 4.55, math.cos(a) * rr, math.sin(a) * rr),
				hole,
				M.SmoothPlastic
			)
		end
	end
	Build.wedge(
		p,
		V3(9.4, 8, 8),
		wheel * CF(0, 9, -5.5) * ANG(rad(180), 0, 0),
		rgb(255, 225, 120),
		M.SmoothPlastic
	)
	Build.ucyl(p, 0.6, 30, cf * CF(0, 0.3, 0), rgb(120, 90, 60), M.WoodPlanks)
end

LANDMARKS.giant_tree = function(p, cf, pal, _rng)
	Build.ucyl(p, 40, 9, cf * CF(0, 20, 0), pal.trunk, M.Wood)
	for i = 0, 3 do
		local a = i / 4 * math.pi * 2
		Build.wedge(p, V3(3, 7, 7), cf * ANG(0, a, 0) * CF(0, 3.5, -6), pal.trunk, M.Wood)
	end
	for i = 0, 6 do
		local a = i / 7 * math.pi * 2
		Build.egg(
			p,
			V3(22, 16, 22),
			cf * CF(math.cos(a) * 12, 42 + (i % 2) * 6, math.sin(a) * 12),
			pal.leaves[i % #pal.leaves + 1],
			M.Grass
		)
	end
	Build.egg(p, V3(26, 18, 26), cf * CF(0, 54, 0), pal.leaves[#pal.leaves], M.Grass)
end

LANDMARKS.temple = function(_p, cf, _pal, _rng)
	-- a stepped pyramid in terrain (free) with a stair run
	for i = 0, 6 do
		local w = 64 - i * 8
		Terra.block(cf * CF(0, 3 + i * 6, 0), V3(w, 6, w), if i % 2 == 0 then M.Cobblestone else M.Slate)
	end
	Terra.block(cf * CF(0, 22, -26) * ANG(rad(-48), 0, 0), V3(10, 4, 58), M.Slate)
	Terra.block(cf * CF(0, 46, 0), V3(10, 8, 10), M.Rock)
end

LANDMARKS.idol = function(p, cf, _pal, _rng)
	-- a big pepper idol head (an inner set-piece; the caller adds the collider)
	Build.egg(p, V3(10, 12, 9), cf * CF(0, 6, 0), rgb(150, 160, 130), M.Slate)
	Build.egg(p, V3(4, 7, 4), cf * CF(0, 13, 0) * ANG(0, 0, rad(15)), rgb(200, 40, 30), M.SmoothPlastic)
	for _, s in { -1, 1 } do
		Build.ball(p, 1.8, cf * CF(s * 2.2, 8, -4.1), rgb(255, 200, 60), M.Neon)
	end
	Build.block(p, V3(5, 1, 1), cf * CF(0, 4.5, -4.3), rgb(60, 50, 40), M.Slate)
end

LANDMARKS.lighthouse = function(p, cf, _pal, _rng)
	for i = 0, 5 do
		Build.ucyl(
			p,
			7,
			12 - i * 1.1,
			cf * CF(0, 3.5 + i * 7, 0),
			if i % 2 == 0 then rgb(245, 245, 245) else rgb(220, 50, 50),
			M.SmoothPlastic
		)
	end
	Build.ucyl(p, 1.2, 10, cf * CF(0, 42.6, 0), rgb(60, 60, 70), M.Metal)
	local lamp = Build.ucyl(p, 5, 6, cf * CF(0, 45.7, 0), rgb(255, 240, 160), M.Neon, { transparency = 0.1 })
	Build.light(lamp, rgb(255, 240, 180), 60, 3)
	Build.egg(p, V3(8, 5, 8), cf * CF(0, 50, 0), rgb(220, 50, 50), M.SmoothPlastic)
end

LANDMARKS.ice_spire = function(p, cf, pal, rng)
	for i = 0, 6 do
		local a = i / 7 * math.pi * 2
		local h = rng:range(28, 60)
		Build.block(
			p,
			V3(7, h, 7),
			cf * CF(math.cos(a) * 7, h / 2, math.sin(a) * 7) * ANG(math.cos(a) * 0.25, a, math.sin(a) * 0.25),
			pal.glow,
			M.Ice,
			{
				transparency = 0.1,
			}
		)
	end
	Build.block(p, V3(9, 72, 9), cf * CF(0, 36, 0) * ANG(0, 0.4, 0), rgb(200, 235, 255), M.Ice)
end

LANDMARKS.ice_spire_small = function(p, cf, pal, rng)
	for i = 0, 3 do
		local a = i / 4 * math.pi * 2
		local h = rng:range(9, 16)
		Build.block(
			p,
			V3(3, h, 3),
			cf * CF(math.cos(a) * 3, h / 2, math.sin(a) * 3) * ANG(math.cos(a) * 0.3, a, math.sin(a) * 0.3),
			pal.glow,
			M.Ice,
			{
				transparency = 0.1,
			}
		)
	end
	Build.block(p, V3(4, 22, 4), cf * CF(0, 11, 0), rgb(200, 235, 255), M.Ice)
end

LANDMARKS.volcano = function(p, cf, _pal, _rng)
	-- terrain cone (stacked cylinders), a glowing crater and a smoke plume
	for i = 0, 9 do
		local rr = 70 - i * 6.5
		Terra.cylinder(cf * CF(0, 5 + i * 9, 0), 10, rr, if i >= 8 then M.CrackedLava else M.Basalt)
	end
	Terra.cylinder(cf * CF(0, 92, 0), 8, 9, M.Air)
	local glow = Build.ucyl(p, 1, 18, cf * CF(0, 88.6, 0), rgb(255, 120, 30), M.Neon)
	Build.light(glow, rgb(255, 120, 40), 60, 4)
	Build.emitter(glow, {
		name = "Plume",
		texture = Build.TEX.smoke,
		color = Build.cs(rgb(90, 80, 75), rgb(40, 36, 34)),
		size = Build.ns(8, 26),
		transparency = Build.ns(0.3, 1),
		lifetime = NumberRange.new(5, 8),
		rate = 3,
		speed = NumberRange.new(8, 12),
		spread = Vector2.new(12, 12),
		accel = Vector3.new(2, 1, 0),
		rotSpeed = NumberRange.new(-20, 20),
	})
	Build.emitter(glow, {
		name = "Embers",
		texture = Build.TEX.sparkles,
		color = Build.cs(rgb(255, 200, 80), rgb(255, 80, 30)),
		size = Build.ns(1.2, 0),
		transparency = Build.ns(0, 1),
		lifetime = NumberRange.new(2, 3),
		rate = 8,
		speed = NumberRange.new(16, 28),
		spread = Vector2.new(25, 25),
		accel = Vector3.new(0, -14, 0),
		lightEmission = 1,
	})
end

LANDMARKS.witch_tower = function(p, cf, _pal, _rng)
	local stone = rgb(95, 100, 90)
	for i = 0, 3 do
		Build.ucyl(
			p,
			10,
			12 - i * 1.6,
			cf * CF(i * 0.6, 5 + i * 10, 0) * ANG(0, 0, rad(i * 2)),
			stone:Lerp(rgb(60, 80, 50), i * 0.1),
			M.Slate
		)
	end
	Build.egg(p, V3(14, 20, 14), cf * CF(2.4, 50, 0) * ANG(0, 0, rad(-12)), rgb(70, 40, 100), M.Slate)
	for i = 0, 3 do
		Build.block(
			p,
			V3(2, 3, 0.6),
			cf * CF(math.cos(i * 1.57) * 5.5, 14 + i * 7, math.sin(i * 1.57) * 5.5) * ANG(0, -i * 1.57, 0),
			rgb(150, 255, 90),
			M.Neon
		)
	end
	Build.light(Build.ball(p, 2, cf * CF(4, 62, 0), rgb(150, 255, 90), M.Neon), rgb(150, 255, 90), 40, 2)
end

LANDMARKS.spaceship = function(p, cf, _pal, _rng)
	-- a crashed rocket ship nose-down in a crater, smoke curling out
	Terra.ball(cf.Position + V3(0, -8, 0), 22, M.Basalt)
	Terra.ball(cf.Position + V3(0, -4, 0), 18, M.Air)
	local body = cf * CF(0, 14, 0) * ANG(rad(35), 0, rad(15))
	Build.ucyl(p, 30, 12, body, rgb(230, 232, 240), M.Metal)
	Build.egg(p, V3(12, 14, 12), body * CF(0, -16, 0), rgb(220, 60, 60), M.Metal)
	Build.ucyl(p, 4, 12.4, body * CF(0, 6, 0), rgb(220, 60, 60), M.Metal)
	Build.cyl(
		p,
		1,
		6,
		body * CF(0, -4, -6) * ANG(0, rad(90), 0),
		rgb(120, 200, 255),
		M.Glass,
		{ transparency = 0.2 }
	)
	for i = 0, 2 do
		local a = i / 3 * math.pi * 2
		Build.wedge(
			p,
			V3(1.2, 10, 8),
			body * ANG(0, a, 0) * CF(0, 13, -8) * ANG(0, 0, 0),
			rgb(220, 60, 60),
			M.Metal
		)
	end
	local nozzle = Build.ucyl(p, 4, 7, body * CF(0, 17, 0), rgb(70, 70, 80), M.Metal)
	Build.emitter(nozzle, {
		name = "Smoke",
		texture = Build.TEX.smoke,
		color = Build.cs(rgb(150, 150, 160), rgb(80, 80, 90)),
		size = Build.ns(4, 14),
		transparency = Build.ns(0.4, 1),
		lifetime = NumberRange.new(3, 5),
		rate = 3,
		speed = NumberRange.new(4, 7),
		spread = Vector2.new(20, 20),
	})
	for i = 0, 3 do
		local light = Build.ball(
			p,
			1.4,
			body * CF(math.cos(i * 1.57) * 6.1, 2, math.sin(i * 1.57) * 6.1),
			rgb(120, 255, 200),
			M.Neon
		)
		if i == 0 then
			Build.light(light, rgb(120, 255, 200), 30, 2)
		end
	end
end

LANDMARKS.satellite = function(p, cf, _pal, _rng)
	Build.ucyl(p, 6, 1.4, cf * CF(0, 3, 0), rgb(160, 160, 170), M.Metal)
	Build.cyl(p, 1, 14, cf * CF(0, 8, 0) * ANG(0, 0, rad(60)), rgb(230, 232, 240), M.Metal)
	Build.ball(p, 1.4, cf * CF(0, 11, 0), rgb(255, 80, 80), M.Neon)
	for _, s in { -1, 1 } do
		Build.block(p, V3(8, 0.3, 3.5), cf * CF(s * 6, 4, 0), rgb(60, 80, 160), M.Glass)
	end
end

LANDMARKS.shipwreck = function(p, cf, _pal, _rng)
	local wood = rgb(110, 80, 55)
	local hull = cf * CF(0, 6, 0) * ANG(0, 0, rad(18))
	Build.block(p, V3(14, 10, 46), hull, wood, M.WoodPlanks)
	Build.wedge(p, V3(14, 10, 14), hull * CF(0, 0, -30) * ANG(0, rad(180), 0), wood, M.WoodPlanks)
	Build.block(p, V3(15, 1.4, 46), hull * CF(0, 5, 0), rgb(90, 60, 40), M.WoodPlanks)
	Build.ucyl(p, 34, 1.6, hull * CF(0, 20, -4) * ANG(rad(-8), 0, 0), wood, M.Wood)
	Build.block(
		p,
		V3(14, 12, 0.4),
		hull * CF(0, 24, -4) * ANG(rad(-8), 0, rad(6)),
		rgb(230, 220, 190),
		M.Fabric,
		{
			transparency = 0.1,
		}
	)
	Build.ucyl(p, 20, 1.2, hull * CF(0, 13, 12) * ANG(rad(25), 0, 0), wood, M.Wood)
	Build.ball(p, 3, hull * CF(4, 6, -12), rgb(255, 210, 80), M.Neon)
end

Regions.LANDMARKS = LANDMARKS

function Regions.landmark(parent: Instance, id: string, cf: CFrame, pal: any, rng: Rng): Model?
	local fn = LANDMARKS[id]
	if not fn then
		return nil
	end
	local m = Instance.new("Model")
	m.Name = "Landmark_" .. id
	m:AddTag("Landmark")
	m.Parent = parent
	fn(m, cf, pal, rng)
	-- iter2 detail: every landmark stands on a rocky plinth ring with two
	-- pennant poles and a beacon, so it reads as a destination from afar
	local ok, cf0, size = pcall(function()
		return m:GetBoundingBox()
	end)
	if ok and cf0 and size then
		local base = CFrame.new(cf0.Position.X, cf.Position.Y, cf0.Position.Z)
		local rr = math.clamp(math.max(size.X, size.Z) * 0.5 + 2, 6, 40)
		for k = 0, 5 do
			local a = k / 6 * math.pi * 2 + rng:range(-0.2, 0.2)
			Build.ball(
				m,
				rng:range(2.5, 4),
				base * CFrame.new(math.cos(a) * rr, 0.6, math.sin(a) * rr),
				pal.rockDark or pal.rock,
				pal.rockMaterial or Enum.Material.Rock
			)
		end
		for _, sgn in { -1, 1 } do
			local p = base * CFrame.new(sgn * rr * 0.7, 0, -rr * 0.7)
			Build.ucyl(m, 9, 0.35, p * CFrame.new(0, 4.5, 0), Color3.fromRGB(110, 76, 44), Enum.Material.Wood)
			Build.block(
				m,
				Vector3.new(0.1, 2.2, 3),
				p * CFrame.new(0, 7.6, 1.5),
				pal.accent or pal.glow,
				Enum.Material.Fabric
			)
		end
		local beacon = Build.ball(m, 1.6, base * CFrame.new(0, size.Y + 2, 0), pal.glow, Enum.Material.Neon)
		beacon.Name = "Beacon"
	end
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.CastShadow = false
		end
	end
	return m
end

return Regions
