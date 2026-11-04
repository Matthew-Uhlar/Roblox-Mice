--!strict
-- ArenaBuilder (R4 Graphics): builds the round arena of a map on smooth Terrain,
-- dressed with detailed Part props (Roblox side, not unit-testable).
--
--   ArenaBuilder.build(mapId, seed, opts?) -> ArenaInfo
--       { model, obstacles = {{x, z, r}}, spawn: Vector3, radius, center: Vector3,
--         pois = {{id, x, z, r}}, squadSpawns = {[1..4] = Vector3},
--         safeZones = {[1..4] = {x, z, r}}, mapId }
--       opts.pois = Combat/Pois.layout(...) entries {kind, x, z, r, traps?}: POI props
--       are built at exactly those points; obstacles keep clear of them. Without
--       opts.pois the slots are rolled here (decor only).
--   ArenaBuilder.clear()                      parts AND the arena's terrain box
--   ArenaBuilder.buildPortal(x, z, color?) -> Model   Rind Gate (GDD §3.9)
--   ArenaBuilder.setPortalColor(color: Color3)
--   ArenaBuilder.clearPortal()
--
-- Layout rules (mirrored by tests/sim/Headless.arena): world X/Z == combat-sim X/Z;
-- radius = map size; boss pad of BOSS_PAD_RADIUS at the centre; the legacy party
-- spawn kept clear; obstacles keep 7 studs + radii from each other, 6 + r from POI
-- slots and stay inside R - r - 7. v2 adds 4 squad corners (safe zones) that
-- obstacles also keep clear of.
--
-- Ground: Terrain, flat at Y = 0 inside the playable radius (material patches and
-- paths only repaint the top voxel layer, so the surface stays at Y = 0). Cliffs,
-- plateaus, water / lava and waterfalls are outside R + 1.5, behind an invisible
-- barrier ring. Every obstacle's solid part is ONE invisible collider cylinder of
-- exactly the returned radius; all visuals are non-colliding. Small decor groups
-- are tagged "Decor" and the backdrop "DecorFar" (CollectionService) so low-spec
-- clients can hide them (src/client/Visuals/DetailLevel). Everything is Anchored
-- and built under workspace.Arena.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rng = require(Shared:WaitForChild("Util"):WaitForChild("Rng")) :: any

local Visuals = script.Parent.Parent:WaitForChild("Visuals")
local Build = require(Visuals:WaitForChild("Build")) :: any
local Props = require(Visuals:WaitForChild("Props")) :: any
local PoiModels = require(Visuals:WaitForChild("PoiModels")) :: any
local Terra = require(Visuals:WaitForChild("Terra")) :: any

local function optional(parent: Instance, name: string): any
	local ok, mod = pcall(function()
		local inst = parent:WaitForChild(name, 5)
		return if inst and inst:IsA("ModuleScript") then require(inst) :: any else nil
	end)
	return if ok then mod else nil
end

local Config = Shared:WaitForChild("Config")
local PoiDefs: any = optional(Config, "Pois")
local Maps: any = optional(Config, "Maps")
local Squads: any = optional(Shared:WaitForChild("Util"), "Squads")

local ArenaBuilder = {}

ArenaBuilder.ARENA_NAME = "Arena"
ArenaBuilder.BOSS_PAD_RADIUS = 14
ArenaBuilder.SPAWN_CLEAR = 12 -- keep the legacy party spawn free of obstacles
ArenaBuilder.WALL_HEIGHT = 6
ArenaBuilder.BARRIER_HEIGHT = 40
ArenaBuilder.SAFE_ZONE_RADIUS = 13 -- GDD-v2 §2: squad safe corner
ArenaBuilder.SQUAD_INSET = 20 -- squad corner centre = R - this
ArenaBuilder.TERRAIN_MARGIN = 72 -- terrain built out to R + this
ArenaBuilder.TERRAIN_BOX = Vector3.new(500, 160, 500) -- cleared on every rebuild
ArenaBuilder.TERRAIN_BOX_CENTER = Vector3.new(0, 40, 0)
-- Mobile budget (QC-A minor 7): BaseParts and PointLights per arena. The Rind
-- Gate (about 70 parts, 1 light) is added later, so it has headroom here; the
-- totals stay under 3,000 parts and 30 lights per map.
ArenaBuilder.PART_BUDGET = 2850
ArenaBuilder.LIGHT_BUDGET = 29

export type Obstacle = { x: number, z: number, r: number }
export type SafeZone = { x: number, z: number, r: number }
export type ArenaInfo = {
	model: Model,
	obstacles: { Obstacle },
	spawn: Vector3,
	radius: number,
	center: Vector3,
	pois: { { id: string, x: number, z: number, r: number? } },
	squadSpawns: { Vector3 },
	safeZones: { SafeZone },
	mapId: string,
}

local M = Enum.Material
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local rgb = Color3.fromRGB

local CHEESE = Props.CHEESE

-- Themes ------------------------------------------------------------------------------------
-- ground / patches / path / sub: terrain materials of the floor; cliff / cliffTop /
-- slope: the rim; outer: "water" | "lava" | "none" beyond the rim; falls: waterfalls.
-- kinds: weighted obstacle kinds (Props.OBSTACLES); decor: weighted small decor.
-- far: backdrop prop kinds on the plateau. pal: Props palette.

type Theme = {
	ground: Enum.Material,
	patches: { Enum.Material },
	path: Enum.Material,
	sub: Enum.Material,
	cliff: Enum.Material,
	cliffTop: Enum.Material,
	cliffH: { number },
	outer: string,
	falls: number,
	kinds: { { kind: string, weight: number } },
	decor: { { kind: string, weight: number } },
	far: { string },
	pal: any,
	cheese: Color3,
	padStone: Color3,
}

local function pal(t: any): any
	return t
end

local THEMES: { [string]: Theme } = {
	plains = {
		ground = M.Grass,
		patches = { M.LeafyGrass, M.Ground },
		path = M.Ground,
		sub = M.Rock,
		cliff = M.Rock,
		cliffTop = M.Grass,
		cliffH = { 8, 20 },
		outer = "water",
		falls = 2,
		kinds = {
			{ kind = "rock", weight = 4 },
			{ kind = "tree", weight = 3 },
			{ kind = "wedge", weight = 3 },
		},
		decor = {
			{ kind = "grass", weight = 5 },
			{ kind = "flower", weight = 4 },
			{ kind = "pebbles", weight = 2 },
			{ kind = "crumbs", weight = 1 },
		},
		far = { "tree", "tree", "rock", "pine" },
		pal = pal({
			rock = rgb(150, 150, 145),
			rockDark = rgb(105, 105, 102),
			moss = rgb(110, 170, 70),
			leaves = { rgb(86, 168, 68), rgb(110, 190, 80), rgb(140, 205, 95) },
			trunk = rgb(120, 82, 50),
			accent = rgb(250, 220, 110),
			glow = rgb(255, 230, 140),
			flower = { rgb(255, 255, 255), rgb(255, 210, 60), rgb(255, 130, 170), rgb(170, 140, 255) },
		}),
		cheese = rgb(255, 214, 90),
		padStone = rgb(205, 200, 185),
	},
	forest = {
		ground = M.LeafyGrass,
		patches = { M.Mud, M.Ground, M.Grass },
		path = M.Ground,
		sub = M.Rock,
		cliff = M.Rock,
		cliffTop = M.LeafyGrass,
		cliffH = { 12, 24 },
		outer = "water",
		falls = 1,
		kinds = {
			{ kind = "tree", weight = 5 },
			{ kind = "pine", weight = 2 },
			{ kind = "mushroom", weight = 1 },
			{ kind = "rock", weight = 1 },
			{ kind = "wedge", weight = 2 },
		},
		decor = {
			{ kind = "toadstool", weight = 3 },
			{ kind = "grass", weight = 4 },
			{ kind = "pebbles", weight = 2 },
			{ kind = "flower", weight = 1 },
		},
		far = { "tree", "pine", "pine", "tree", "mushroom" },
		pal = pal({
			rock = rgb(125, 128, 118),
			rockDark = rgb(85, 88, 80),
			moss = rgb(80, 130, 55),
			leaves = { rgb(48, 112, 52), rgb(66, 135, 58), rgb(92, 152, 64) },
			trunk = rgb(96, 64, 40),
			accent = rgb(230, 170, 60),
			glow = rgb(150, 230, 255),
			flower = { rgb(220, 60, 50), rgb(240, 170, 60), rgb(250, 240, 220) },
		}),
		cheese = rgb(240, 180, 60),
		padStone = rgb(170, 165, 150),
	},
	jungle = {
		ground = M.LeafyGrass,
		patches = { M.Mud, M.Grass },
		path = M.Mud,
		sub = M.Rock,
		cliff = M.Rock,
		cliffTop = M.LeafyGrass,
		cliffH = { 14, 28 },
		outer = "water",
		falls = 3,
		kinds = {
			{ kind = "jungle_tree", weight = 5 },
			{ kind = "rock", weight = 2 },
			{ kind = "wedge", weight = 2 },
		},
		decor = {
			{ kind = "grass", weight = 4 },
			{ kind = "flower", weight = 3 },
			{ kind = "reeds", weight = 1 },
			{ kind = "toadstool", weight = 1 },
		},
		far = { "jungle_tree", "jungle_tree", "palm", "rock" },
		pal = pal({
			rock = rgb(110, 120, 100),
			rockDark = rgb(75, 85, 70),
			moss = rgb(60, 140, 50),
			leaves = { rgb(30, 110, 45), rgb(45, 140, 55), rgb(80, 170, 60) },
			trunk = rgb(100, 72, 44),
			accent = rgb(245, 230, 170),
			glow = rgb(255, 120, 60),
			flower = { rgb(255, 70, 90), rgb(255, 170, 30), rgb(200, 80, 220), rgb(255, 240, 90) },
		}),
		cheese = rgb(250, 235, 175),
		padStone = rgb(150, 160, 130),
	},
	beach = {
		ground = M.Sand,
		patches = { M.Sandstone, M.Salt },
		path = M.Sandstone,
		sub = M.Sandstone,
		cliff = M.Sandstone,
		cliffTop = M.Sand,
		cliffH = { 4, 12 },
		outer = "water",
		falls = 0,
		kinds = {
			{ kind = "palm", weight = 4 },
			{ kind = "rock", weight = 3 },
			{ kind = "wedge", weight = 3 },
		},
		decor = {
			{ kind = "shell", weight = 4 },
			{ kind = "grass", weight = 2 },
			{ kind = "pebbles", weight = 2 },
		},
		far = { "palm", "palm", "rock" },
		pal = pal({
			rock = rgb(190, 175, 150),
			rockDark = rgb(150, 135, 110),
			moss = rgb(140, 175, 90),
			leaves = { rgb(60, 165, 75), rgb(90, 185, 80), rgb(120, 200, 90) },
			trunk = rgb(160, 120, 75),
			accent = rgb(60, 170, 220),
			glow = rgb(120, 220, 255),
			flower = { rgb(255, 130, 120), rgb(255, 210, 80) },
		}),
		cheese = rgb(255, 230, 150),
		padStone = rgb(235, 220, 185),
	},
	tundra = {
		ground = M.Snow,
		patches = { M.Glacier, M.Ice },
		path = M.Slate,
		sub = M.Rock,
		cliff = M.Glacier,
		cliffTop = M.Snow,
		cliffH = { 10, 24 },
		outer = "water",
		falls = 0,
		kinds = {
			{ kind = "ice", weight = 3 },
			{ kind = "pine", weight = 4 },
			{ kind = "snow_rock", weight = 1 },
			{ kind = "wedge", weight = 2 },
		},
		decor = { { kind = "snowmound", weight = 4 }, { kind = "pebbles", weight = 2 } },
		far = { "pine", "pine", "ice", "snow_rock" },
		pal = pal({
			rock = rgb(150, 165, 185),
			rockDark = rgb(100, 112, 130),
			moss = rgb(245, 250, 255),
			leaves = { rgb(40, 92, 72), rgb(56, 112, 84) },
			trunk = rgb(100, 72, 50),
			accent = rgb(110, 170, 230),
			glow = rgb(120, 200, 255),
			flower = {},
		}),
		cheese = rgb(170, 195, 235),
		padStone = rgb(210, 225, 240),
	},
	volcano = {
		ground = M.Basalt,
		patches = { M.Slate, M.Rock, M.Slate },
		path = M.Slate,
		sub = M.Basalt,
		cliff = M.Basalt,
		cliffTop = M.CrackedLava,
		cliffH = { 16, 34 },
		outer = "lava",
		falls = 0,
		kinds = { { kind = "lava_rock", weight = 6 }, { kind = "wedge", weight = 2 } },
		decor = { { kind = "ember", weight = 4 }, { kind = "pebbles", weight = 3 } },
		far = { "lava_rock", "crystal", "lava_rock" },
		pal = pal({
			rock = rgb(70, 60, 60),
			rockDark = rgb(40, 34, 34),
			moss = rgb(60, 50, 45),
			leaves = { rgb(60, 50, 45) },
			trunk = rgb(50, 40, 35),
			accent = rgb(255, 150, 30),
			glow = rgb(255, 110, 25),
			flower = {},
			rockMaterial = M.Basalt,
		}),
		cheese = rgb(255, 160, 40),
		padStone = rgb(90, 75, 70),
	},
	swamp = {
		ground = M.Mud,
		patches = { M.LeafyGrass, M.Slate, M.Ground },
		path = M.Ground,
		sub = M.Slate,
		cliff = M.Slate,
		cliffTop = M.Mud,
		cliffH = { 6, 14 },
		outer = "water",
		falls = 0,
		kinds = {
			{ kind = "dead_tree", weight = 4 },
			{ kind = "mushroom", weight = 2 },
			{ kind = "rock", weight = 2 },
			{ kind = "wedge", weight = 2 },
		},
		decor = {
			{ kind = "reeds", weight = 4 },
			{ kind = "glowcap", weight = 3 },
			{ kind = "toadstool", weight = 2 },
		},
		far = { "dead_tree", "dead_tree", "mushroom" },
		pal = pal({
			rock = rgb(95, 105, 85),
			rockDark = rgb(60, 68, 55),
			moss = rgb(110, 140, 60),
			leaves = { rgb(80, 110, 50), rgb(100, 130, 60) },
			trunk = rgb(75, 66, 56),
			accent = rgb(150, 200, 80),
			glow = rgb(150, 255, 120),
			flower = { rgb(150, 90, 170), rgb(110, 170, 90), rgb(190, 120, 70) },
			rockMaterial = M.Slate,
		}),
		cheese = rgb(190, 205, 140),
		padStone = rgb(110, 115, 100),
	},
	moon = {
		ground = M.Rock,
		patches = { M.Slate, M.Basalt },
		path = M.Slate,
		sub = M.Rock,
		cliff = M.Rock,
		cliffTop = M.Slate,
		cliffH = { 6, 16 },
		outer = "none",
		falls = 0,
		kinds = {
			{ kind = "moon_rock", weight = 4 },
			{ kind = "crystal", weight = 2 },
			{ kind = "wedge", weight = 3 },
		},
		decor = { { kind = "crater", weight = 4 }, { kind = "pebbles", weight = 3 } },
		far = { "moon_rock", "crystal" },
		pal = pal({
			rock = rgb(190, 190, 198),
			rockDark = rgb(120, 120, 132),
			moss = rgb(170, 170, 180),
			leaves = { rgb(170, 170, 180) },
			trunk = rgb(120, 120, 130),
			accent = rgb(250, 250, 235),
			glow = rgb(150, 210, 255),
			flower = {},
			rockMaterial = M.Slate,
		}),
		cheese = rgb(250, 248, 230),
		padStone = rgb(175, 175, 185),
	},
	ocean = {
		ground = M.Sand,
		patches = { M.Ground, M.Cobblestone, M.Salt },
		path = M.Limestone, -- terrain-only materials (Pebble is a Part material)
		sub = M.Rock,
		cliff = M.Rock,
		cliffTop = M.Sand,
		cliffH = { 10, 22 },
		outer = "water",
		falls = 0,
		kinds = {
			{ kind = "coral", weight = 5 },
			{ kind = "rock", weight = 2 },
			{ kind = "wedge", weight = 2 },
		},
		decor = {
			{ kind = "bubbles", weight = 2 },
			{ kind = "shell", weight = 3 },
			{ kind = "pebbles", weight = 2 },
		},
		far = { "coral", "coral", "rock" },
		pal = pal({
			rock = rgb(95, 125, 135),
			rockDark = rgb(60, 85, 95),
			moss = rgb(60, 150, 90),
			leaves = { rgb(60, 150, 90) },
			trunk = rgb(90, 80, 70),
			accent = rgb(255, 170, 120),
			glow = rgb(110, 240, 230),
			flower = { rgb(255, 110, 150), rgb(255, 170, 80), rgb(180, 110, 230), rgb(255, 220, 90) },
		}),
		cheese = rgb(245, 245, 235),
		padStone = rgb(150, 175, 180),
	},
}
ArenaBuilder.THEMES = THEMES

local FALLBACK_DEF = {
	id = "plains",
	name = "Cheese Field",
	size = 120,
	obstacleCount = 18,
	poiSlots = 8,
	poiTable = { { id = "cheese_cache", weight = 1 } },
	groundColor = { 150, 200, 90 },
	accentColor = { 250, 220, 110 },
}

local function getDef(mapId: string): any
	if Maps then
		local def = nil
		if type(Maps.get) == "function" then
			local ok, d = pcall(Maps.get, mapId)
			def = if ok then d else nil
		end
		def = def or (type(Maps[mapId]) == "table" and Maps[mapId]) or nil
		if def then
			return def
		end
	end
	warn("[ArenaBuilder] unknown map " .. tostring(mapId) .. ", using fallback")
	return FALLBACK_DEF
end

local function themeFor(mapId: string): Theme
	if THEMES[mapId] then
		return THEMES[mapId]
	end
	for key, th in THEMES do
		if string.find(mapId, key, 1, true) then
			return th
		end
	end
	return THEMES.plains
end

local function weighted(rng: any, list: { { kind: string, weight: number } }): string
	local w = {}
	for i, e in list do
		w[i] = e.weight
	end
	return list[rng:weightedIndex(w)].kind
end

local function squadColor(i: number): Color3
	local s = Squads and type(Squads.get) == "function" and Squads.get(i)
	return Build.rgb(
		s and s.color,
		({ rgb(255, 200, 60), rgb(245, 240, 220), rgb(80, 150, 255), rgb(235, 70, 60) })[i] or CHEESE
	)
end

-- Squad corners: (-,-), (+,-), (+,+), (-,+) at R - SQUAD_INSET from the centre.
function ArenaBuilder.squadCorners(R: number): { SafeZone }
	local d = R - ArenaBuilder.SQUAD_INSET
	local out = {}
	for i, deg in { 225, 315, 45, 135 } do
		local a = math.rad(deg)
		out[i] = { x = math.cos(a) * d, z = math.sin(a) * d, r = ArenaBuilder.SAFE_ZONE_RADIUS }
	end
	return out
end

-- Terrain -------------------------------------------------------------------------------------

local terrainBuilt = false

local function clearTerrain()
	if terrainBuilt then
		Terra.clearBox(ArenaBuilder.TERRAIN_BOX_CENTER, ArenaBuilder.TERRAIN_BOX)
		terrainBuilt = false
	end
end

-- Smooth pseudo-noise over the rim angle (deterministic per seed).
local function rimNoise(rng: any): (number) -> number
	local k1, k2, k3 = rng:range(0, 6.28), rng:range(0, 6.28), rng:range(0, 6.28)
	return function(a: number): number
		return 0.5 + 0.25 * math.sin(a * 3 + k1) + 0.15 * math.sin(a * 7 + k2) + 0.1 * math.sin(a * 13 + k3)
	end
end

-- Builds the terrain and returns the rim height function (for backdrop props) and
-- the waterfall spots.
local function buildTerrain(
	R: number,
	th: Theme,
	rng: any,
	corners: { SafeZone }
): ((number) -> number, { number })
	terrainBuilt = true
	Terra.reset()
	Terra.clearBox(ArenaBuilder.TERRAIN_BOX_CENTER, ArenaBuilder.TERRAIN_BOX)
	local RO = R + ArenaBuilder.TERRAIN_MARGIN
	-- bedrock + topsoil, flat top at Y = 0
	Terra.cylinder(CF(0, -14, 0), 20, RO + 6, th.sub)
	Terra.cylinder(CF(0, -2, 0), 4, RO + 6, th.ground)

	-- outer basin (water / lava) beyond the plateau
	if th.outer == "water" or th.outer == "lava" then
		Terra.cylinder(CF(0, -4, 0), 8, RO + 6, M.Air)
		Terra.cylinder(CF(0, -10, 0), 4, RO + 6, th.sub)
		if th.outer == "water" then
			Terra.cylinder(CF(0, -5, 0), 8, RO + 6, M.Sand)
			Terra.cylinder(CF(0, -3.5, 0), 5, RO + 6, M.Water)
		else
			Terra.cylinder(CF(0, -6, 0), 4, RO + 6, M.CrackedLava)
		end
		Terra.cylinder(CF(0, -4, 0), 8, R + 46, th.sub)
		Terra.cylinder(CF(0, -2, 0), 4, R + 46, th.ground)
	end

	-- floor patches (repaint only)
	for _ = 1, math.floor(R / 3) do
		local a, d = rng:range(0, 6.28), math.sqrt(rng:range(0, 1)) * (R - 4)
		Terra.paint(
			math.cos(a) * d,
			math.sin(a) * d,
			rng:range(3, 12),
			th.patches[rng:nextInt(1, #th.patches)]
		)
	end
	-- gentle cosmetic mounds (at most ~0.6 stud above Y = 0), away from the pad
	for _ = 1, 6 do
		local a, d = rng:range(0, 6.28), rng:range(ArenaBuilder.BOSS_PAD_RADIUS + 12, R - 14)
		local rb = rng:range(6, 9)
		Terra.ball(V3(math.cos(a) * d, -rb + 0.6, math.sin(a) * d), rb, th.ground)
	end

	-- paths: a ring round the boss pad + one winding path from each squad corner
	local ringR = ArenaBuilder.BOSS_PAD_RADIUS + 5
	for i = 0, 35 do
		local a = i / 36 * math.pi * 2
		Terra.paint(math.cos(a) * ringR, math.sin(a) * ringR, 3, th.path)
	end
	for _, c in corners do
		local a0 = math.atan2(c.z, c.x)
		local d0 = math.sqrt(c.x * c.x + c.z * c.z)
		local wob = rng:range(-1, 1)
		local steps = math.floor((d0 - ringR) / 3)
		for s = 0, steps do
			local t = s / math.max(1, steps)
			local d = d0 + (ringR - d0) * t
			local a = a0 + math.sin(t * math.pi) * 0.18 * wob
			Terra.paint(math.cos(a) * d, math.sin(a) * d, 2.6, th.path)
		end
		-- paved safe corner
		Terra.paint(c.x, c.z, c.r + 1, th.path)
	end

	-- the rim: a plateau ring of cliffs with a top layer and an outer slope
	local noise = rimNoise(rng)
	local lo, hi = th.cliffH[1], th.cliffH[2]
	local function height(a: number): number
		return lo + (hi - lo) * noise(a)
	end
	local falls = {}
	for _ = 1, th.falls do
		-- waterfalls on the far (north, -Z) side so the top-down camera sees their face
		table.insert(falls, math.rad(rng:range(235, 305)))
	end
	local function nearFall(a: number): boolean
		for _, f in falls do
			local d = math.abs((a - f + math.pi) % (2 * math.pi) - math.pi)
			if d < 0.09 then
				return true
			end
		end
		return false
	end
	local inner, depth = R + 2.5, 26
	local mid = inner + depth / 2
	local n = math.ceil(2 * math.pi * mid / 10)
	local segLen = 2 * math.pi * mid / n + 2
	for i = 0, n - 1 do
		local a = (i + 0.5) / n * math.pi * 2
		local h = height(a)
		local setBack = if nearFall(a) then 7 else 0
		local hh = if setBack > 0 then hi + 6 else h
		local dir = V3(math.cos(a), 0, math.sin(a))
		local c = dir * (mid + setBack)
		local look = CFrame.lookAt(c, c + dir)
		Terra.block(look + V3(0, hh / 2 - 4, 0), V3(segLen, hh + 4, depth), th.cliff)
		Terra.block(look + V3(0, hh - 1.5, 0), V3(segLen, 3, depth - 2), th.cliffTop)
		-- outer slope down to the basin (tall face toward the centre)
		local sc = dir * (mid + setBack + depth / 2 + 7)
		Terra.wedge(CFrame.lookAt(sc, sc + dir) + V3(0, hh / 2 - 3, 0), V3(segLen, hh + 2, 14), th.cliff)
	end
	-- foot boulders break the straight cliff line (never inside R + 2.5)
	for _ = 1, math.floor(n * 0.8) do
		local a = rng:range(0, 6.28)
		if not nearFall(a) then
			local rb = rng:range(3, 6)
			local d = inner + rb + rng:range(0, 3)
			Terra.ball(V3(math.cos(a) * d, rng:range(0, height(a) * 0.5), math.sin(a) * d), rb, th.cliff)
		end
	end
	-- waterfall pools at the cliff foot (outside the barrier)
	for _, f in falls do
		local dir = V3(math.cos(f), 0, math.sin(f))
		local p = dir * (inner + 5)
		Terra.cylinder(CF(p.X, -2, p.Z), 4, 4.5, M.Air)
		Terra.cylinder(CF(p.X, -3, p.Z), 2, 4.5, M.Water)
	end
	return height, falls
end

-- Parts -------------------------------------------------------------------------------------

local function decorModel(parent: Instance, name: string, tag: string): Model
	local m = Build.model(parent, name)
	m:AddTag(tag)
	return m
end

local function buildBossPad(model: Model, th: Theme, accent: Color3, glow: Color3)
	local pad = Build.model(model, "BossPad")
	local R = ArenaBuilder.BOSS_PAD_RADIUS
	local o = CF(0, 0, 0)
	Build.ucyl(
		pad,
		0.3,
		R * 2 + 1.6,
		o * CF(0, 0.12, 0),
		Build.shade(th.padStone, -0.25),
		M.Slate,
		{ shadow = false, name = "PadRim" }
	)
	Build.ucyl(
		pad,
		0.34,
		R * 2 - 1,
		o * CF(0, 0.14, 0),
		th.padStone,
		M.Marble,
		{ shadow = false, name = "PadStone" }
	)
	Build.ucyl(
		pad,
		0.36,
		R * 1.1,
		o * CF(0, 0.16, 0),
		accent,
		M.Marble,
		{ shadow = false, name = "PadInner" }
	)
	-- neon rune ring
	for i = 0, 23 do
		local a = i / 24 * math.pi * 2
		local p = V3(math.cos(a) * (R - 1.6), 0.33, math.sin(a) * (R - 1.6))
		Build.block(
			pad,
			V3(if i % 3 == 0 then 1.6 else 0.6, 0.06, 0.35),
			CFrame.lookAt(p, V3(0, 0.33, 0)) * ANG(0, math.rad(90), 0),
			glow,
			M.Neon,
			{
				shadow = false,
				name = "Rune",
			}
		)
	end
	-- spiral arms (the swirl)
	for arm = 0, 5 do
		for k = 0, 6 do
			local t = k / 6
			local a = arm / 6 * math.pi * 2 + t * 2.2
			local rr = 1.4 + t * (R * 0.5)
			local p = V3(math.cos(a) * rr, 0.36, math.sin(a) * rr)
			local tangent = V3(-math.sin(a), 0, math.cos(a))
			Build.block(
				pad,
				V3(0.28 + 0.25 * t, 0.05, 1.6 + t),
				CFrame.lookAt(p, p + tangent),
				glow:Lerp(accent, t),
				M.Neon,
				{
					shadow = false,
					name = "Swirl",
					transparency = 0.1 + 0.4 * t,
				}
			)
		end
	end
	-- centre: cheese emblem + glow, standing stones round the edge
	local core =
		Build.ucyl(pad, 0.12, 2.6, o * CF(0, 0.4, 0), glow, M.Neon, { shadow = false, name = "Core" })
	Build.light(core, glow, 26, 1.6)
	Build.emitter(core, {
		name = "Rise",
		texture = Build.TEX.sparkles,
		color = Build.cs(glow, accent),
		size = Build.ns(0.6, 0),
		transparency = Build.ns(0.1, 1),
		lifetime = NumberRange.new(1.5, 2.5),
		rate = 8,
		speed = NumberRange.new(2, 4),
		spread = Vector2.new(25, 25),
		lightEmission = 1,
		shape = Enum.ParticleEmitterShape.Disc,
		shapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
	})
	for i = 0, 7 do
		local a = (i + 0.5) / 8 * math.pi * 2
		local p = V3(math.cos(a) * (R + 0.4), 0, math.sin(a) * (R + 0.4))
		Build.block(
			pad,
			V3(1.2, 1, 1.2),
			CF(p + V3(0, 0.5, 0)) * ANG(0, a, 0),
			Build.shade(th.padStone, -0.1),
			M.Slate,
			{ name = "Stone" }
		)
		Build.block(pad, V3(0.5, 0.1, 0.5), CF(p + V3(0, 1.02, 0)), glow, M.Neon, { shadow = false })
	end
end

local function buildCorner(model: Model, i: number, z: SafeZone, R: number)
	local col = squadColor(i)
	local m = Build.model(model, "SquadCorner" .. i)
	m:SetAttribute("Squad", i)
	local o = CF(z.x, 0, z.z)
	Build.ucyl(m, 0.12, z.r * 2, o * CF(0, 0.07, 0), col, M.ForceField, {
		shadow = false,
		transparency = 0.6,
		name = "SafeDisc",
	})
	local n = 28
	for k = 0, n - 1 do
		local a = k / n * math.pi * 2
		local p = V3(z.x + math.cos(a) * z.r, 0.12, z.z + math.sin(a) * z.r)
		local seg = Build.block(
			m,
			V3(2 * math.pi * z.r / n * 0.62, 0.12, 0.45),
			CFrame.lookAt(p, V3(z.x, 0.12, z.z)) * ANG(0, math.rad(90), 0),
			col,
			M.Neon,
			{
				shadow = false,
				name = "SafeRing",
			}
		)
		seg:SetAttribute("Tint", true)
	end
	-- two banners on the rim side of the corner, a brazier in the middle
	local out = V3(z.x, 0, z.z).Unit
	local side = V3(-out.Z, 0, out.X)
	for _, s in { -1, 1 } do
		local p = V3(z.x, 0, z.z) + out * (z.r - 1) + side * s * 5
		Props.banner(m, CFrame.lookAt(p, p - out), col, 9)
	end
	local br = o * CF(out * (z.r * 0.55))
	Build.ucyl(m, 1.4, 1.2, br * CF(0, 0.7, 0), rgb(80, 80, 88), M.Slate)
	Build.ucyl(m, 0.5, 2.4, br * CF(0, 1.6, 0), rgb(70, 70, 76), M.Metal)
	local flame =
		Build.egg(m, V3(1.4, 1.8, 1.4), br * CF(0, 2.6, 0), col:Lerp(rgb(255, 180, 60), 0.5), M.Neon, {
			shadow = false,
			transparency = 0.15,
			name = "Flame",
		})
	Build.light(flame, col, 24, 2.2, true)
	Build.emitter(flame, {
		name = "Fire",
		texture = Build.TEX.fire,
		color = Build.cs(col:Lerp(Color3.new(1, 1, 1), 0.3), col),
		size = Build.ns(1.3, 0.2),
		transparency = Build.ns(0.2, 1),
		lifetime = NumberRange.new(0.5, 0.9),
		rate = 14,
		speed = NumberRange.new(2, 4),
		spread = Vector2.new(10, 10),
		lightEmission = 1,
	})
	local _ = R
end

local function poiGlow(id: string, fallback: Color3): Color3
	local def = PoiDefs and type(PoiDefs.get) == "function" and PoiDefs.get(id)
	return if def then Build.rgb(def.color, fallback) else fallback
end

ArenaBuilder.POI_LABEL_HEIGHT = 10 -- studs above the ground
ArenaBuilder.POI_LABEL_DISTANCE = 70 -- the name shows within this many studs of the camera

local function buildPoi(
	parent: Instance,
	id: string,
	x: number,
	z: number,
	accent: Color3,
	rng: any,
	entry: any?
)
	local m = Instance.new("Model")
	m.Name = "POI_" .. id
	m:SetAttribute("PoiId", id)
	local glow = poiGlow(id, accent)
	PoiModels.build(m, id, x, z, accent, glow, rng, entry)
	-- Short in-world name (FINAL-B FB-m4), seen only from nearby.
	local def = PoiDefs and type(PoiDefs.get) == "function" and PoiDefs.get(id)
	if def and type(def.name) == "string" then
		local anchor = Build.block(
			m,
			V3(0.2, 0.2, 0.2),
			CF(x, ArenaBuilder.POI_LABEL_HEIGHT, z),
			accent,
			M.SmoothPlastic,
			{
				name = "LabelAnchor",
				transparency = 1,
				shadow = false,
			}
		)
		local gui = Instance.new("BillboardGui")
		gui.Name = "PoiLabel"
		gui.Size = UDim2.fromOffset(180, 26)
		gui.MaxDistance = ArenaBuilder.POI_LABEL_DISTANCE
		gui.LightInfluence = 0
		gui.Adornee = anchor
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.Text = def.name
		label.TextColor3 = glow:Lerp(Color3.new(1, 1, 1), 0.35)
		label.TextStrokeTransparency = 0.3
		label.Parent = gui
		gui.Parent = anchor
	end
	m.Parent = parent
end

local function rollPois(rng: any, mapId: string, def: any, count: number): { string }
	if Maps and type(Maps.rollPois) == "function" then
		local ok, list = pcall(Maps.rollPois, rng, mapId)
		if ok and type(list) == "table" and #list > 0 then
			return list
		end
	end
	local out = {}
	local tbl = def.poiTable or FALLBACK_DEF.poiTable
	local weights = {}
	for _, e in tbl do
		table.insert(weights, e.weight or 1)
	end
	for _ = 1, count do
		table.insert(out, tbl[rng:weightedIndex(weights)].id)
	end
	return out
end

-- Build ------------------------------------------------------------------------------------

function ArenaBuilder.clear()
	local old = Workspace:FindFirstChild(ArenaBuilder.ARENA_NAME)
	if old then
		old:Destroy()
	end
	clearTerrain()
end

-- Lighting mood for the map (LightingService; optional so a missing module never
-- breaks the arena).
local function applyMood(mapId: string)
	local inst = script.Parent:FindFirstChild("LightingService")
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		if ok and type(mod) == "table" and type((mod :: any).apply) == "function" then
			local ok2, err = pcall((mod :: any).apply, mapId)
			if not ok2 then
				warn("[ArenaBuilder] LightingService.apply failed: " .. tostring(err))
			end
		end
	end
end

-- Thins decor until the arena fits the mobile budget: the floor decor goes
-- first (newest first: placement is random, so this thins evenly), then the
-- backdrop. Lights over the cap are removed, decor lights first. Gameplay
-- parts (obstacles, POIs, corners, the boss pad) are never touched.
local function enforceBudget(model: Model, decorFolders: { Instance })
	local parts = 0
	local lights: { PointLight } = {}
	local decorLights: { PointLight } = {}
	local decorSet: { [Instance]: boolean } = {}
	for _, f in decorFolders do
		decorSet[f] = true
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			parts += 1
		elseif d:IsA("PointLight") then
			local inDecor = false
			for f in decorSet do
				if d:IsDescendantOf(f) then
					inDecor = true
					break
				end
			end
			table.insert(if inDecor then decorLights else lights, d)
		end
	end
	for _, f in decorFolders do
		local kids = f:GetChildren()
		for i = #kids, 1, -1 do
			if parts <= ArenaBuilder.PART_BUDGET then
				break
			end
			local m = kids[i]
			local n = 0
			for _, d in m:GetDescendants() do
				if d:IsA("BasePart") then
					n += 1
				end
			end
			if m:IsA("BasePart") then
				n += 1
			end
			for j = #decorLights, 1, -1 do
				if decorLights[j]:IsDescendantOf(m) then
					table.remove(decorLights, j)
				end
			end
			m:Destroy()
			parts -= n
		end
	end
	local total = #lights + #decorLights
	while total > ArenaBuilder.LIGHT_BUDGET do
		local l = table.remove(decorLights) or table.remove(lights)
		if not l then
			break
		end
		l:Destroy()
		total -= 1
	end
end

function ArenaBuilder.build(mapId: string, seed: number, opts: { pois: { any }? }?): ArenaInfo
	ArenaBuilder.clear()
	local def = getDef(mapId)
	local id = def.id or mapId
	local th = themeFor(id)
	local rng = Rng.new(seed or 1):fork(0xA7E)
	local decoRng = Rng.new(seed or 1):fork(0xDEC0)
	local R = if type(def.size) == "number" and def.size >= 40 then def.size else FALLBACK_DEF.size
	local accent = Build.rgb(def.accentColor, CHEESE)
	local glow = th.pal.glow

	local model = Instance.new("Model")
	model.Name = ArenaBuilder.ARENA_NAME
	model:SetAttribute("MapId", id)
	model:SetAttribute("Radius", R)

	local corners = ArenaBuilder.squadCorners(R)
	local rimHeight, falls = buildTerrain(R, th, decoRng, corners)
	applyMood(id)

	-- Invisible barrier ring at the playable edge (terrain cliffs are climbable).
	local walls = Instance.new("Folder")
	walls.Name = "Rim"
	walls.Parent = model
	local n = math.max(16, math.ceil(2 * math.pi * R / 10))
	local segLen = 2 * math.pi * (R + 1.5) / n + 0.6
	for i = 0, n - 1 do
		local a = (i + 0.5) / n * math.pi * 2
		local cx, cz = math.cos(a) * (R + 1.5), math.sin(a) * (R + 1.5)
		local look = CFrame.lookAt(V3(cx, 0, cz), V3(0, 0, 0))
		Build.block(
			walls,
			V3(segLen, ArenaBuilder.BARRIER_HEIGHT, 1),
			look + V3(0, ArenaBuilder.BARRIER_HEIGHT / 2, 0),
			Color3.new(1, 1, 1),
			M.SmoothPlastic,
			{
				name = "Barrier",
				collide = true,
				transparency = 1,
				shadow = false,
			}
		)
	end
	-- Safety floor: an invisible slab just under Y = 0 so characters never fall
	-- through if terrain is unavailable.
	Build.ucyl(model, 2, R * 2 + 6, CF(0, -1.05, 0), th.pal.rock, M.SmoothPlastic, {
		name = "Floor",
		collide = true,
		transparency = 1,
		shadow = false,
	})
	if not Terra.ok() then
		-- No terrain: show the old flat floor so the arena is still playable.
		local floor = model:FindFirstChild("Floor") :: BasePart
		floor.Transparency = 0
		floor.Color = Build.rgb(def.groundColor, rgb(150, 200, 90))
		floor.Material = th.ground
	end

	buildBossPad(model, th, accent, glow)
	for i, z in corners do
		buildCorner(model, i, z, R)
	end

	local spawnZ = math.min(R * 0.3, ArenaBuilder.BOSS_PAD_RADIUS + 14)
	local spawn = V3(0, 4, spawnZ)

	-- POIs
	local poiFolder = Instance.new("Folder")
	poiFolder.Name = "POIs"
	poiFolder.Parent = model
	local pois = {}
	local given = opts and opts.pois
	if type(given) == "table" and #given > 0 then
		for _, entry in given do
			local pid = tostring(entry.kind)
			local x, z = tonumber(entry.x) or 0, tonumber(entry.z) or 0
			buildPoi(poiFolder, pid, x, z, accent, rng, entry)
			table.insert(pois, { id = pid, x = x, z = z, r = tonumber(entry.r) or 6 })
		end
	else
		local slots = if type(def.poiSlots) == "number" then def.poiSlots else FALLBACK_DEF.poiSlots
		local poiIds = rollPois(rng, id, def, slots)
		local a0 = rng:range(0, math.pi * 2)
		for i, pid in poiIds do
			local a = a0 + (i - 1) / #poiIds * math.pi * 2 + rng:range(-0.15, 0.15)
			local d = R * rng:range(0.55, 0.8)
			local x, z = math.cos(a) * d, math.sin(a) * d
			buildPoi(poiFolder, pid, x, z, accent, rng)
			table.insert(pois, { id = pid, x = x, z = z, r = 6 })
		end
	end

	-- Obstacles
	local obsFolder = Instance.new("Folder")
	obsFolder.Name = "Obstacles"
	obsFolder.Parent = model
	local obstacles: { Obstacle } = {}
	local want = if type(def.obstacleCount) == "number" then def.obstacleCount else FALLBACK_DEF.obstacleCount
	local function free(x: number, z: number, r: number): boolean
		if x * x + z * z < (ArenaBuilder.BOSS_PAD_RADIUS + r + 6) ^ 2 then
			return false
		end
		if x * x + z * z > (R - r - 7) ^ 2 then
			return false
		end
		if (x - spawn.X) ^ 2 + (z - spawn.Z) ^ 2 < (ArenaBuilder.SPAWN_CLEAR + r) ^ 2 then
			return false
		end
		for _, c in corners do
			if (x - c.x) ^ 2 + (z - c.z) ^ 2 < (c.r + r + 5) ^ 2 then
				return false
			end
		end
		for _, o in obstacles do
			if (x - o.x) ^ 2 + (z - o.z) ^ 2 < (o.r + r + 7) ^ 2 then
				return false -- leave lanes so the horde can flow
			end
		end
		for _, p in pois do
			if (x - p.x) ^ 2 + (z - p.z) ^ 2 < (r + (p.r or 6) + 6) ^ 2 then
				return false
			end
		end
		return true
	end
	for _ = 1, want do
		local kind = weighted(rng, th.kinds)
		local builder = Props.OBSTACLES[kind] or Props.OBSTACLES.rock
		for _ = 1, 30 do
			local r = rng:range(2.5, 5)
			local a = rng:range(0, math.pi * 2)
			local d = math.sqrt(rng:range(0, 1)) * R
			local x, z = math.cos(a) * d, math.sin(a) * d
			if free(x, z, r) then
				local m = Instance.new("Model")
				m.Name = kind
				m.Parent = obsFolder
				local solidR = builder(m, x, z, r, decoRng, th.pal, true)
				m:SetAttribute("Radius", solidR)
				-- spacing uses the visual radius r; the sim gets the solid radius
				table.insert(obstacles, { x = x, z = z, r = solidR })
				break
			end
		end
	end
	-- Small decor scattered on the floor (non-colliding, tag "Decor")
	local decorFolder = Instance.new("Folder")
	decorFolder.Name = "Decor"
	decorFolder.Parent = model
	local function clearOf(x: number, z: number, pad: number): boolean
		if x * x + z * z < (ArenaBuilder.BOSS_PAD_RADIUS + 2 + pad) ^ 2 or x * x + z * z > (R - 2) ^ 2 then
			return false
		end
		for _, o in obstacles do
			if (x - o.x) ^ 2 + (z - o.z) ^ 2 < (o.r + 2.5 + pad) ^ 2 then
				return false
			end
		end
		for _, p in pois do
			if (x - p.x) ^ 2 + (z - p.z) ^ 2 < ((p.r or 6) + 1 + pad) ^ 2 then
				return false
			end
		end
		for _, c in corners do
			if (x - c.x) ^ 2 + (z - c.z) ^ 2 < (c.r + pad) ^ 2 then
				return false
			end
		end
		return true
	end
	local nDecor = math.floor(R * 1.8)
	for i = 1, nDecor do
		local a, d = decoRng:range(0, 6.28), math.sqrt(decoRng:range(0, 1)) * R
		local x, z = math.cos(a) * d, math.sin(a) * d
		if clearOf(x, z, 1) then
			local kind = weighted(decoRng, th.decor)
			local fn = Props.DECOR[kind]
			if fn then
				fn(
					decorModel(decorFolder, kind .. i, "Decor"),
					x,
					z,
					decoRng:range(0.8, 1.4),
					decoRng,
					th.pal
				)
			end
		end
	end
	-- Cheese crumbs + rocks hugging obstacles make them sit in the ground
	for i, o in obstacles do
		if i % 2 == 0 then
			local a = decoRng:range(0, 6.28)
			Props.DECOR.pebbles(
				decorModel(decorFolder, "foot" .. i, "Decor"),
				o.x + math.cos(a) * (o.r + 2.2),
				o.z + math.sin(a) * (o.r + 2.2),
				1,
				decoRng,
				th.pal
			)
		end
	end

	-- Backdrop on the plateau (tag "DecorFar"); props sit on the cliff tops.
	local farFolder = Instance.new("Folder")
	farFolder.Name = "Backdrop"
	farFolder.Parent = model
	local nFar = math.floor(2 * math.pi * (R + 15) / 9)
	for i = 1, nFar do
		local a = (i + decoRng:range(-0.3, 0.3)) / nFar * math.pi * 2
		local skip = false
		for _, f in falls do
			if math.abs((a - f + math.pi) % (2 * math.pi) - math.pi) < 0.12 then
				skip = true
			end
		end
		if not skip then
			local d = R + decoRng:range(9, 24)
			local x, z = math.cos(a) * d, math.sin(a) * d
			local kind = th.far[decoRng:nextInt(1, #th.far)]
			local fn = Props.FAR[kind] or Props.FAR.rock
			if fn then
				local m = decorModel(farFolder, kind .. i, "DecorFar")
				fn(m, 0, 0, decoRng:range(3.2, 5), decoRng, th.pal)
				local hgt = rimHeight(a)
				m:PivotTo(CF(x, hgt - 2.2, z) * ANG(0, decoRng:range(0, 6.28), 0))
			end
		end
	end
	-- Waterfalls
	for _, f in falls do
		local dir = V3(math.cos(f), 0, math.sin(f))
		local h = th.cliffH[2] + 6
		local top = dir * (R + 2.5 + 7) + V3(0, h - 2, 0)
		local wf = decorModel(farFolder, "Waterfall", "DecorFar")
		Props.waterfall(wf, top, -dir, h, 7, rgb(140, 215, 245))
	end
	-- Lava glow beyond the volcano rim
	if th.outer == "lava" then
		for i = 0, 11 do
			local a = i / 12 * math.pi * 2 + decoRng:range(-0.1, 0.1)
			local d = R + ArenaBuilder.TERRAIN_MARGIN - decoRng:range(4, 16)
			local p = V3(math.cos(a) * d, -3.9, math.sin(a) * d)
			local m = decorModel(farFolder, "Lava" .. i, "DecorFar")
			local pool = Build.egg(
				m,
				V3(decoRng:range(14, 24), 0.4, decoRng:range(10, 18)),
				CF(p) * ANG(0, a, 0),
				th.pal.glow,
				M.Neon,
				{
					shadow = false,
				}
			)
			Build.light(pool, th.pal.glow, 40, 3)
		end
	end

	enforceBudget(model, { decorFolder, farFolder })

	model.WorldPivot = CF(0, 0, 0)
	model.Parent = Workspace

	local squadSpawns = {}
	for i, c in corners do
		squadSpawns[i] = V3(c.x, 4, c.z)
	end
	return {
		model = model,
		obstacles = obstacles,
		spawn = spawn,
		radius = R,
		center = V3(0, 0, 0),
		pois = pois,
		squadSpawns = squadSpawns,
		safeZones = corners,
		mapId = id,
	}
end

-- Portal (GDD §3.9) ----------------------------------------------------------------------

ArenaBuilder.PORTAL_NAME = "RindGate"
ArenaBuilder.PORTAL_RADIUS = 6
ArenaBuilder.PORTAL_SEGMENTS = 16
local PORTAL_GOLD = rgb(255, 204, 51)

local function portalParent(): Instance
	local arena = Workspace:FindFirstChild(ArenaBuilder.ARENA_NAME)
	return arena or Workspace
end

function ArenaBuilder.clearPortal()
	local arena = portalParent()
	local old = arena:FindFirstChild(ArenaBuilder.PORTAL_NAME)
	if old then
		old:Destroy()
	end
end

-- Rind arch stones round a glowing neon pool with spiral swirl arms, a faint
-- light column and particle swirls. Every tinted part / light / emitter carries
-- the "Tint" attribute so setPortalColor recolours it; FxController adds the
-- client motes and the pull.
function ArenaBuilder.buildPortal(x: number, z: number, color: Color3?): Model
	ArenaBuilder.clearPortal()
	local c = color or PORTAL_GOLD
	local m = Instance.new("Model")
	m.Name = ArenaBuilder.PORTAL_NAME
	m:SetAttribute("X", x)
	m:SetAttribute("Z", z)
	local R = ArenaBuilder.PORTAL_RADIUS
	local nSeg = ArenaBuilder.PORTAL_SEGMENTS
	local o = CF(x, 0, z)
	local function tint(p: Instance)
		p:SetAttribute("Tint", true)
	end
	-- rind ring (cheese rind stones) with neon seams
	for i = 0, nSeg - 1 do
		local a = (i + 0.5) / nSeg * math.pi * 2
		local p = V3(x + math.cos(a) * R, 0.4, z + math.sin(a) * R)
		local look = CFrame.lookAt(p, V3(x, 0.4, z)) * ANG(0, math.rad(90), 0)
		Build.block(
			m,
			V3(2 * math.pi * R / nSeg * 0.8, 0.8, 1.3),
			look,
			Props.RIND,
			M.SmoothPlastic,
			{ name = "Ring1" }
		)
		tint(Build.block(m, V3(0.25, 0.85, 1.35), look * CF(2 * math.pi * R / nSeg * 0.42, 0, 0), c, M.Neon, {
			name = "Ring1",
			shadow = false,
		}))
	end
	-- 6 standing rind pillars with neon tips
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2
		local p = o * CF(math.cos(a) * (R + 1), 0, math.sin(a) * (R + 1))
		Build.wedge(
			m,
			V3(1.2, 4.5, 1.2),
			p * CF(0, 2.25, 0) * ANG(0, -a + math.pi / 2, 0),
			Props.CHEESE,
			M.SmoothPlastic,
			{
				name = "Pillar",
			}
		)
		tint(Build.ball(m, 0.7, p * CF(0, 4.8, 0), c, M.Neon, { name = "Ring2", shadow = false }))
	end
	local pool = Build.ucyl(m, 0.2, R * 2 - 0.6, o * CF(0, 0.12, 0), c, M.Neon, {
		name = "Pool",
		transparency = 0.35,
		shadow = false,
	})
	tint(pool)
	-- swirl arms on the pool
	for arm = 0, 3 do
		for k = 0, 5 do
			local t = k / 5
			local a = arm / 4 * math.pi * 2 + t * 2.6
			local rr = 0.6 + t * (R - 1.4)
			local p = V3(x + math.cos(a) * rr, 0.26, z + math.sin(a) * rr)
			local tangent = V3(-math.sin(a), 0, math.cos(a))
			tint(
				Build.block(
					m,
					V3(0.35, 0.05, 1.3 + t),
					CFrame.lookAt(p, p + tangent),
					c:Lerp(Color3.new(1, 1, 1), 0.4 * (1 - t)),
					M.Neon,
					{
						name = "Swirl",
						shadow = false,
					}
				)
			)
		end
	end
	local column = Build.cyl(m, 14, R * 1.2, CF(x, 7, z) * ANG(0, 0, math.rad(90)), c, M.Neon, {
		name = "Column",
		transparency = 0.88,
		shadow = false,
	})
	tint(column)
	local light = Build.light(pool, c, 28, 3)
	tint(light)
	tint(Build.emitter(pool, {
		name = "Swirl",
		texture = Build.TEX.sparkles,
		color = Build.cs(c, Color3.new(1, 1, 1)),
		size = Build.ns(0.7, 0),
		transparency = Build.ns(0, 1),
		lifetime = NumberRange.new(1.2, 2),
		rate = 30,
		speed = NumberRange.new(3, 6),
		spread = Vector2.new(5, 5),
		rotSpeed = NumberRange.new(-200, 200),
		lightEmission = 1,
		shape = Enum.ParticleEmitterShape.Cylinder,
		shapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
	}))
	tint(Build.emitter(pool, {
		name = "Vortex",
		texture = Build.TEX.vortex,
		color = Build.cs(c),
		size = Build.ns(6, 9),
		transparency = Build.ns(0.4, 1),
		lifetime = NumberRange.new(1, 1.5),
		rate = 3,
		speed = NumberRange.new(0.2, 0.5),
		rotSpeed = NumberRange.new(90, 180),
		lightEmission = 0.8,
		orientation = Enum.ParticleOrientation.VelocityPerpendicular,
	}))
	m.Parent = portalParent()
	return m
end

function ArenaBuilder.setPortalColor(color: Color3)
	local m = portalParent():FindFirstChild(ArenaBuilder.PORTAL_NAME)
	if not m then
		return
	end
	for _, d in m:GetDescendants() do
		if d:GetAttribute("Tint") then
			if d:IsA("BasePart") or d:IsA("PointLight") then
				(d :: any).Color = color
			elseif d:IsA("ParticleEmitter") then
				d.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
			end
		end
	end
end

return ArenaBuilder
