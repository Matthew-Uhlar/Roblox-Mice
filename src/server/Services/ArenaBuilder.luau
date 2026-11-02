--!strict
-- ArenaBuilder: procedurally builds the round arena for a map (Roblox side, not
-- unit-testable). Owned by Team B.
--
--   ArenaBuilder.build(mapId, seed, opts?) -> { model, obstacles = {{x, z, r}}, spawn: Vector3,
--                                        radius: number, center: Vector3, pois = {{id, x, z}} }
--       opts.pois = Combat/Pois.layout(...) entries {kind, x, z, r, traps?}: the POI parts are
--       built at exactly those points (RunDirector adds the same entries to the World), and
--       obstacles keep clear of them. Without opts.pois the slots are rolled here (decor only).
--   ArenaBuilder.clear()
--   ArenaBuilder.buildPortal(x, z, color?) -> Model   Rind Gate portal (GDD §3.9): a ring of
--       neon parts on the ground plus a glowing pool; FxController adds the client swirl.
--   ArenaBuilder.setPortalColor(color: Color3)        tint it (vote leader / next map colour)
--   ArenaBuilder.clearPortal()
--
-- Layout: flat round floor centred on the origin (top at Y = 0), rim wall, themed
-- obstacles (rocks, trees, cheese wedges, ice, coral...), POI decorations in the
-- map's POI slots, and a central boss pad. World coordinates == combat-sim X/Z, so the
-- returned obstacle circles plug straight into World.new. Every obstacle's circle is
-- the footprint of its solid (CanCollide) part; canopies and decor never collide.
-- Everything is Anchored. Built under workspace.Arena.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rng = require(Shared:WaitForChild("Util"):WaitForChild("Rng")) :: any

local PoiDefs: any = nil
do
	local ok, mod = pcall(function()
		return require(Shared:WaitForChild("Config"):WaitForChild("Pois", 5) :: ModuleScript)
	end)
	if ok then
		PoiDefs = mod
	end
end

local Maps: any = nil
do
	local ok, mod = pcall(function()
		return require(Shared:WaitForChild("Config"):WaitForChild("Maps", 5) :: ModuleScript)
	end)
	if ok then
		Maps = mod
	else
		warn("[ArenaBuilder] Config/Maps unavailable, using fallback layout:", mod)
	end
end

local ArenaBuilder = {}

ArenaBuilder.ARENA_NAME = "Arena"
ArenaBuilder.BOSS_PAD_RADIUS = 14
ArenaBuilder.SPAWN_CLEAR = 12 -- keep the party spawn free of obstacles
ArenaBuilder.WALL_HEIGHT = 6
ArenaBuilder.BARRIER_HEIGHT = 40

export type Obstacle = { x: number, z: number, r: number }
export type ArenaInfo = {
	model: Model,
	obstacles: { Obstacle },
	spawn: Vector3,
	radius: number,
	center: Vector3,
	pois: { { id: string, x: number, z: number, r: number? } },
}

type Theme = {
	ground: Enum.Material,
	kinds: { { kind: string, weight: number } },
	rock: Color3,
	wall: Color3,
	wallMaterial: Enum.Material,
}

local function rgb(t: any, fallback: Color3): Color3
	if
		type(t) == "table"
		and type(t[1]) == "number"
		and type(t[2]) == "number"
		and type(t[3]) == "number"
	then
		return Color3.fromRGB(t[1], t[2], t[3])
	end
	return fallback
end

local CHEESE = Color3.fromRGB(250, 205, 70)

local THEMES: { [string]: Theme } = {
	plains = {
		ground = Enum.Material.Grass,
		kinds = {
			{ kind = "rock", weight = 4 },
			{ kind = "tree", weight = 3 },
			{ kind = "wedge", weight = 3 },
		},
		rock = Color3.fromRGB(140, 140, 135),
		wall = Color3.fromRGB(120, 110, 90),
		wallMaterial = Enum.Material.Cobblestone,
	},
	forest = {
		ground = Enum.Material.LeafyGrass,
		kinds = {
			{ kind = "tree", weight = 6 },
			{ kind = "rock", weight = 2 },
			{ kind = "wedge", weight = 2 },
		},
		rock = Color3.fromRGB(110, 115, 105),
		wall = Color3.fromRGB(90, 70, 50),
		wallMaterial = Enum.Material.Wood,
	},
	jungle = {
		ground = Enum.Material.LeafyGrass,
		kinds = {
			{ kind = "jungle_tree", weight = 5 },
			{ kind = "rock", weight = 2 },
			{ kind = "wedge", weight = 2 },
		},
		rock = Color3.fromRGB(95, 110, 90),
		wall = Color3.fromRGB(70, 90, 50),
		wallMaterial = Enum.Material.Grass,
	},
	beach = {
		ground = Enum.Material.Sand,
		kinds = {
			{ kind = "palm", weight = 4 },
			{ kind = "rock", weight = 3 },
			{ kind = "wedge", weight = 3 },
		},
		rock = Color3.fromRGB(170, 160, 140),
		wall = Color3.fromRGB(200, 185, 140),
		wallMaterial = Enum.Material.Sandstone,
	},
	tundra = {
		ground = Enum.Material.Snow,
		kinds = {
			{ kind = "ice", weight = 4 },
			{ kind = "pine", weight = 4 },
			{ kind = "wedge", weight = 2 },
		},
		rock = Color3.fromRGB(170, 210, 235),
		wall = Color3.fromRGB(200, 220, 235),
		wallMaterial = Enum.Material.Ice,
	},
	volcano = {
		ground = Enum.Material.Basalt,
		kinds = { { kind = "lava_rock", weight = 6 }, { kind = "wedge", weight = 2 } },
		rock = Color3.fromRGB(60, 50, 50),
		wall = Color3.fromRGB(50, 40, 40),
		wallMaterial = Enum.Material.Basalt,
	},
	swamp = {
		ground = Enum.Material.Mud,
		kinds = {
			{ kind = "dead_tree", weight = 4 },
			{ kind = "rock", weight = 3 },
			{ kind = "wedge", weight = 2 },
		},
		rock = Color3.fromRGB(90, 105, 80),
		wall = Color3.fromRGB(70, 80, 55),
		wallMaterial = Enum.Material.Mud,
	},
	moon = {
		ground = Enum.Material.Slate,
		kinds = { { kind = "rock", weight = 6 }, { kind = "wedge", weight = 3 } },
		rock = Color3.fromRGB(200, 200, 205),
		wall = Color3.fromRGB(150, 150, 160),
		wallMaterial = Enum.Material.Slate,
	},
	ocean = {
		ground = Enum.Material.Sand,
		kinds = {
			{ kind = "coral", weight = 5 },
			{ kind = "rock", weight = 3 },
			{ kind = "wedge", weight = 2 },
		},
		rock = Color3.fromRGB(90, 120, 130),
		wall = Color3.fromRGB(60, 100, 130),
		wallMaterial = Enum.Material.Glass,
	},
}
local DEFAULT_THEME = THEMES.plains

local FALLBACK_DEF = {
	id = "fallback",
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
	return DEFAULT_THEME
end

-- Parts -----------------------------------------------------------------------------------

type PartProps = {
	name: string?,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?,
	shape: Enum.PartType?,
	collide: boolean?,
	transparency: number?,
	shadow: boolean?,
	wedge: boolean?,
}

local function makePart(parent: Instance, p: PartProps): BasePart
	local part: BasePart
	if p.wedge then
		part = Instance.new("WedgePart")
	else
		local pp = Instance.new("Part")
		if p.shape then
			pp.Shape = p.shape
		end
		part = pp
	end
	part.Name = p.name or "Part"
	part.Anchored = true
	part.Size = p.size
	part.CFrame = p.cframe
	part.Color = p.color
	part.Material = p.material or Enum.Material.SmoothPlastic
	part.CanCollide = p.collide == true
	part.CanTouch = false
	part.CanQuery = p.collide == true
	part.CastShadow = p.shadow ~= false
	part.Transparency = p.transparency or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Upright cylinder (Roblox cylinders run along X, so roll by 90 degrees).
local function cylinderCF(x: number, y: number, z: number): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, 0, math.rad(90))
end

-- Obstacle builders. Each builds a Model whose solid footprint is a circle of radius r.
type Builder = (parent: Model, x: number, z: number, r: number, th: Theme, rng: any) -> ()

local BUILDERS: { [string]: Builder } = {}

BUILDERS.rock = function(m, x, z, r, th, rng)
	local h = r * rng:range(1.0, 1.6)
	makePart(m, {
		name = "Rock",
		shape = Enum.PartType.Ball,
		size = Vector3.new(r * 2, r * 2, r * 2),
		cframe = CFrame.new(x, h * 0.35, z),
		color = th.rock,
		material = Enum.Material.Slate,
		collide = true,
	})
	for _ = 1, 2 do
		local a = rng:range(0, math.pi * 2)
		local s = r * rng:range(0.5, 0.8)
		local d = r * 0.7
		makePart(m, {
			name = "Pebble",
			shape = Enum.PartType.Ball,
			size = Vector3.new(s, s, s),
			cframe = CFrame.new(x + math.cos(a) * d, s * 0.3, z + math.sin(a) * d),
			color = th.rock:Lerp(Color3.new(0, 0, 0), 0.15),
			material = Enum.Material.Slate,
			shadow = false,
		})
	end
end

BUILDERS.lava_rock = function(m, x, z, r, th, rng)
	BUILDERS.rock(m, x, z, r, th, rng)
	makePart(m, {
		name = "LavaVein",
		size = Vector3.new(r * 1.6, 0.3, 0.6),
		cframe = CFrame.new(x, r * 0.9, z) * CFrame.Angles(0, rng:range(0, math.pi), 0),
		color = Color3.fromRGB(255, 110, 30),
		material = Enum.Material.Neon,
		shadow = false,
	})
end

local function trunkAndCanopy(
	m: Model,
	x: number,
	z: number,
	r: number,
	trunkH: number,
	trunkColor: Color3,
	canopyColor: Color3,
	canopyScale: number,
	material: Enum.Material?
)
	makePart(m, {
		name = "Trunk",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(trunkH, r * 2, r * 2),
		cframe = cylinderCF(x, trunkH / 2, z),
		color = trunkColor,
		material = Enum.Material.Wood,
		collide = true,
	})
	local c = r * canopyScale
	makePart(m, {
		name = "Canopy",
		shape = Enum.PartType.Ball,
		size = Vector3.new(c * 2, c * 1.6, c * 2),
		cframe = CFrame.new(x, trunkH + c * 0.5, z),
		color = canopyColor,
		material = material or Enum.Material.Grass,
	})
end

BUILDERS.tree = function(m, x, z, r, _th, rng)
	trunkAndCanopy(
		m,
		x,
		z,
		r * 0.6,
		rng:range(9, 13),
		Color3.fromRGB(110, 75, 45),
		Color3.fromRGB(70, 150, 60),
		3.4
	)
end

BUILDERS.jungle_tree = function(m, x, z, r, _th, rng)
	trunkAndCanopy(
		m,
		x,
		z,
		r * 0.6,
		rng:range(14, 18),
		Color3.fromRGB(95, 70, 40),
		Color3.fromRGB(40, 130, 50),
		4
	)
end

BUILDERS.dead_tree = function(m, x, z, r, _th, rng)
	local tr = r * 0.55
	local h = rng:range(8, 12)
	makePart(m, {
		name = "Trunk",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(h, tr * 2, tr * 2),
		cframe = cylinderCF(x, h / 2, z),
		color = Color3.fromRGB(80, 70, 60),
		material = Enum.Material.Wood,
		collide = true,
	})
	for i = 1, 2 do
		local a = rng:range(0, math.pi * 2)
		makePart(m, {
			name = "Branch",
			size = Vector3.new(0.8, 0.8, 5),
			cframe = CFrame.new(x, h * (0.55 + i * 0.15), z)
				* CFrame.Angles(0, a, 0)
				* CFrame.Angles(math.rad(35), 0, 0)
				* CFrame.new(0, 0, -2.5),
			color = Color3.fromRGB(80, 70, 60),
			material = Enum.Material.Wood,
			shadow = false,
		})
	end
end

BUILDERS.pine = function(m, x, z, r, _th, rng)
	local tr = r * 0.5
	local h = rng:range(4, 6)
	makePart(m, {
		name = "Trunk",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(h, tr * 2, tr * 2),
		cframe = cylinderCF(x, h / 2, z),
		color = Color3.fromRGB(100, 70, 45),
		material = Enum.Material.Wood,
		collide = true,
	})
	for i = 0, 2 do
		local s = r * (2.6 - i * 0.7)
		makePart(m, {
			name = "Needles",
			size = Vector3.new(s, 3, s),
			cframe = CFrame.new(x, h + i * 2.6, z) * CFrame.Angles(0, math.rad(45 * i), 0),
			color = Color3.fromRGB(235, 245, 250):Lerp(Color3.fromRGB(40, 100, 60), 0.6),
			material = Enum.Material.Snow,
		})
	end
end

BUILDERS.palm = function(m, x, z, r, _th, rng)
	local tr = r * 0.45
	local h = rng:range(10, 14)
	makePart(m, {
		name = "Trunk",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(h, tr * 2, tr * 2),
		cframe = cylinderCF(x, h / 2, z),
		color = Color3.fromRGB(150, 115, 70),
		material = Enum.Material.Wood,
		collide = true,
	})
	for i = 0, 4 do
		makePart(m, {
			name = "Frond",
			size = Vector3.new(1.6, 0.3, 7),
			cframe = CFrame.new(x, h, z)
				* CFrame.Angles(0, math.rad(72 * i), 0)
				* CFrame.Angles(math.rad(-20), 0, 0)
				* CFrame.new(0, 0, -3.5),
			color = Color3.fromRGB(60, 160, 70),
			material = Enum.Material.Grass,
			shadow = false,
		})
	end
end

BUILDERS.ice = function(m, x, z, r, th, rng)
	makePart(m, {
		name = "IceBase",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(2, r * 2, r * 2),
		cframe = cylinderCF(x, 1, z),
		color = th.rock,
		material = Enum.Material.Ice,
		collide = true,
	})
	for i = 1, 3 do
		local h = rng:range(4, 9)
		local a = i * 2.1
		makePart(m, {
			name = "Crystal",
			size = Vector3.new(r * 0.7, h, r * 0.7),
			cframe = CFrame.new(x + math.cos(a) * r * 0.35, h / 2, z + math.sin(a) * r * 0.35)
				* CFrame.Angles(math.rad(rng:range(-12, 12)), a, math.rad(rng:range(-12, 12))),
			color = th.rock,
			material = Enum.Material.Glass,
			transparency = 0.2,
		})
	end
end

BUILDERS.coral = function(m, x, z, r, _th, rng)
	local colors =
		{ Color3.fromRGB(255, 120, 150), Color3.fromRGB(255, 170, 90), Color3.fromRGB(170, 110, 220) }
	local col = colors[rng:nextInt(1, #colors)]
	makePart(m, {
		name = "CoralBase",
		shape = Enum.PartType.Ball,
		size = Vector3.new(r * 2, r * 1.4, r * 2),
		cframe = CFrame.new(x, r * 0.3, z),
		color = col,
		material = Enum.Material.Pebble,
		collide = true,
	})
	for i = 1, 4 do
		local h = rng:range(3, 7)
		local a = i * 1.6
		makePart(m, {
			name = "Branch",
			shape = Enum.PartType.Cylinder,
			size = Vector3.new(h, 0.9, 0.9),
			cframe = cylinderCF(x + math.cos(a) * r * 0.5, h / 2 + r * 0.3, z + math.sin(a) * r * 0.5),
			color = col,
			material = Enum.Material.Pebble,
			shadow = false,
		})
	end
end

-- A cheese wedge: two WedgeParts forming a triangular-prism slice, with dark "holes".
BUILDERS.wedge = function(m, x, z, r, _th, rng)
	local h = r * 1.1
	local yaw = CFrame.Angles(0, rng:range(0, math.pi * 2), 0)
	local base = CFrame.new(x, h / 2, z) * yaw
	local w, l = r * 1.6, r * 1.6
	makePart(m, {
		name = "Cheese",
		wedge = true,
		size = Vector3.new(w, h, l),
		cframe = base * CFrame.new(0, 0, -l / 2 + l / 2),
		color = CHEESE,
		material = Enum.Material.SmoothPlastic,
		collide = true,
	})
	makePart(m, {
		name = "CheeseBack",
		size = Vector3.new(w, h, 0.4),
		cframe = base * CFrame.new(0, 0, l / 2 - 0.2),
		color = CHEESE:Lerp(Color3.new(1, 1, 1), 0.1),
		material = Enum.Material.SmoothPlastic,
		collide = true,
	})
	for _ = 1, 3 do
		local s = rng:range(0.6, 1.2)
		makePart(m, {
			name = "Hole",
			shape = Enum.PartType.Ball,
			size = Vector3.new(s, s, 0.3),
			cframe = base * CFrame.new(rng:range(-w / 3, w / 3), rng:range(-h / 4, h / 4), l / 2 + 0.05),
			color = Color3.fromRGB(200, 150, 40),
			shadow = false,
		})
	end
end

-- POIs (the World runs them; these are the parts. PoiId = kind attribute) ------------------

local function poiColor(id: string, fallback: Color3): Color3
	local def = PoiDefs and type(PoiDefs.get) == "function" and PoiDefs.get(id)
	return if def then rgb(def.color, fallback) else fallback
end

local function buildPoi(
	parent: Model,
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
	m.Parent = parent
	if id == "cheese_cache" then
		for i = 0, 2 do
			makePart(m, {
				name = "Wheel",
				shape = Enum.PartType.Cylinder,
				size = Vector3.new(1.4, 4 - i * 0.8, 4 - i * 0.8),
				cframe = cylinderCF(x, 0.7 + i * 1.4, z),
				color = CHEESE,
				shadow = false,
			})
		end
	elseif id == "elite_camp" then
		makePart(m, {
			name = "Tent",
			wedge = true,
			size = Vector3.new(6, 4, 6),
			cframe = CFrame.new(x, 2, z) * CFrame.Angles(0, rng:range(0, math.pi), 0),
			color = Color3.fromRGB(150, 60, 60),
			material = Enum.Material.Fabric,
		})
		makePart(m, {
			name = "Flag",
			size = Vector3.new(0.3, 7, 0.3),
			cframe = CFrame.new(x + 4, 3.5, z),
			color = Color3.fromRGB(80, 60, 40),
		})
		makePart(m, {
			name = "Banner",
			size = Vector3.new(0.1, 1.6, 2.4),
			cframe = CFrame.new(x + 4, 6, z + 1.2),
			color = Color3.fromRGB(200, 40, 40),
			material = Enum.Material.Fabric,
			shadow = false,
		})
	elseif id == "healing_spring" or id == "crumb_fountain" then
		makePart(m, {
			name = "Basin",
			shape = Enum.PartType.Cylinder,
			size = Vector3.new(0.6, 7, 7),
			cframe = cylinderCF(x, 0.3, z),
			color = Color3.fromRGB(150, 150, 150),
			material = Enum.Material.Cobblestone,
		})
		makePart(m, {
			name = "Water",
			shape = Enum.PartType.Cylinder,
			size = Vector3.new(0.2, 6, 6),
			cframe = cylinderCF(x, 0.65, z),
			color = Color3.fromRGB(90, 220, 230),
			material = Enum.Material.Neon,
			transparency = 0.3,
			shadow = false,
		})
		if id == "crumb_fountain" then
			makePart(m, {
				name = "Spout",
				shape = Enum.PartType.Cylinder,
				size = Vector3.new(3, 1.2, 1.2),
				cframe = cylinderCF(x, 1.5, z),
				color = Color3.fromRGB(150, 150, 150),
				material = Enum.Material.Cobblestone,
			})
			makePart(m, {
				name = "Crumb",
				shape = Enum.PartType.Ball,
				size = Vector3.new(1.4, 1.4, 1.4),
				cframe = CFrame.new(x, 3.4, z),
				color = CHEESE,
				material = Enum.Material.Neon,
				shadow = false,
			})
		end
	elseif id == "mousetrap_field" then
		-- a plank floor with a trap on every spot the World will arm
		makePart(m, {
			name = "Boards",
			shape = Enum.PartType.Cylinder,
			size = Vector3.new(0.15, (entry and entry.r or 12) * 2, (entry and entry.r or 12) * 2),
			cframe = cylinderCF(x, 0.07, z),
			color = Color3.fromRGB(150, 110, 70),
			material = Enum.Material.WoodPlanks,
			transparency = 0.2,
			shadow = false,
		})
		local spots = if entry and type(entry.traps) == "table" then entry.traps else { { x = x, z = z } }
		for i, t in spots do
			local tx, tz = tonumber(t.x) or x, tonumber(t.z) or z
			makePart(m, {
				name = "Trap" .. i,
				size = Vector3.new(3.2, 0.3, 2),
				cframe = CFrame.new(tx, 0.25, tz) * CFrame.Angles(0, rng:range(0, math.pi), 0),
				color = Color3.fromRGB(190, 150, 100),
				material = Enum.Material.Wood,
				shadow = false,
			})
			makePart(m, {
				name = "Spring" .. i,
				size = Vector3.new(2.8, 0.2, 0.2),
				cframe = CFrame.new(tx, 0.5, tz),
				color = Color3.fromRGB(170, 170, 180),
				material = Enum.Material.Metal,
				shadow = false,
			})
		end
	elseif id == "grandmas_pantry" then
		makePart(m, {
			name = "Cupboard",
			size = Vector3.new(5, 6, 3),
			cframe = CFrame.new(x, 3, z),
			color = Color3.fromRGB(150, 95, 60),
			material = Enum.Material.WoodPlanks,
		})
		makePart(m, {
			name = "Doily",
			size = Vector3.new(5.4, 0.3, 3.4),
			cframe = CFrame.new(x, 6.15, z),
			color = poiColor(id, Color3.fromRGB(230, 120, 200)),
			material = Enum.Material.Fabric,
			shadow = false,
		})
		makePart(m, {
			name = "Pie",
			shape = Enum.PartType.Cylinder,
			size = Vector3.new(0.8, 3, 3),
			cframe = cylinderCF(x, 6.7, z),
			color = Color3.fromRGB(235, 175, 90),
			material = Enum.Material.SmoothPlastic,
			shadow = false,
		})
	elseif id == "lost_herd_statue" then
		local stone = Color3.fromRGB(215, 210, 195)
		makePart(m, {
			name = "Plinth",
			size = Vector3.new(6, 1.2, 6),
			cframe = CFrame.new(x, 0.6, z),
			color = stone:Lerp(Color3.new(0, 0, 0), 0.2),
			material = Enum.Material.Marble,
		})
		makePart(m, {
			name = "Body",
			shape = Enum.PartType.Ball,
			size = Vector3.new(4.6, 4, 5.4),
			cframe = CFrame.new(x, 3.4, z),
			color = stone,
			material = Enum.Material.Marble,
		})
		makePart(m, {
			name = "Head",
			shape = Enum.PartType.Ball,
			size = Vector3.new(3, 3, 3),
			cframe = CFrame.new(x, 5.4, z - 2.6),
			color = stone,
			material = Enum.Material.Marble,
		})
		makePart(m, {
			name = "Trunk",
			shape = Enum.PartType.Cylinder,
			size = Vector3.new(3, 0.9, 0.9),
			cframe = CFrame.new(x, 4.2, z - 4) * CFrame.Angles(0, 0, math.rad(90)),
			color = stone,
			material = Enum.Material.Marble,
		})
		makePart(m, {
			name = "Halo",
			shape = Enum.PartType.Cylinder,
			size = Vector3.new(0.2, 4, 4),
			cframe = cylinderCF(x, 8, z - 2.6),
			color = poiColor(id, Color3.fromRGB(255, 215, 90)),
			material = Enum.Material.Neon,
			transparency = 0.3,
			shadow = false,
		})
	elseif string.sub(id, 1, 6) == "shrine" then
		local glow = poiColor(
			id,
			if id == "shrine_speed" then Color3.fromRGB(90, 200, 255) else Color3.fromRGB(255, 120, 80)
		)
		makePart(m, {
			name = "Plinth",
			size = Vector3.new(4, 1, 4),
			cframe = CFrame.new(x, 0.5, z),
			color = Color3.fromRGB(170, 165, 150),
			material = Enum.Material.Marble,
		})
		makePart(m, {
			name = "Pillar",
			size = Vector3.new(1.6, 5, 1.6),
			cframe = CFrame.new(x, 3.5, z),
			color = Color3.fromRGB(200, 195, 180),
			material = Enum.Material.Marble,
		})
		makePart(m, {
			name = "Orb",
			shape = Enum.PartType.Ball,
			size = Vector3.new(2, 2, 2),
			cframe = CFrame.new(x, 7, z),
			color = glow,
			material = Enum.Material.Neon,
			shadow = false,
		})
	else
		-- rare / unknown POI: a golden landmark
		makePart(m, {
			name = "Base",
			shape = Enum.PartType.Cylinder,
			size = Vector3.new(1, 6, 6),
			cframe = cylinderCF(x, 0.5, z),
			color = accent,
			material = Enum.Material.Marble,
		})
		makePart(m, {
			name = "Spire",
			size = Vector3.new(1.2, 8, 1.2),
			cframe = CFrame.new(x, 5, z) * CFrame.Angles(0, math.rad(45), 0),
			color = Color3.fromRGB(255, 215, 90),
			material = Enum.Material.Neon,
			shadow = false,
		})
	end
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
end

function ArenaBuilder.build(mapId: string, seed: number, opts: { pois: { any }? }?): ArenaInfo
	ArenaBuilder.clear()
	local def = getDef(mapId)
	local th = themeFor(def.id or mapId)
	local rng = Rng.new(seed or 1):fork(0xA7E)
	local R = if type(def.size) == "number" and def.size >= 40 then def.size else FALLBACK_DEF.size
	local groundColor = rgb(def.groundColor, Color3.fromRGB(150, 200, 90))
	local accent = rgb(def.accentColor, CHEESE)

	local model = Instance.new("Model")
	model.Name = ArenaBuilder.ARENA_NAME
	model:SetAttribute("MapId", def.id or mapId)
	model:SetAttribute("Radius", R)

	-- Floor (top surface at Y = 0) plus a darker skirt so the void never shows.
	local floor = makePart(model, {
		name = "Floor",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(2, R * 2 + 8, R * 2 + 8),
		cframe = cylinderCF(0, -1, 0),
		color = groundColor,
		material = th.ground,
		collide = true,
		shadow = false,
	})
	floor.CanQuery = true
	makePart(model, {
		name = "Skirt",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(2, R * 4, R * 4),
		cframe = cylinderCF(0, -1.3, 0),
		color = groundColor:Lerp(Color3.new(0, 0, 0), 0.35),
		material = th.ground,
		collide = true,
		shadow = false,
	})

	-- Rim wall: short visible segments + a tall invisible barrier.
	local walls = Instance.new("Folder")
	walls.Name = "Rim"
	walls.Parent = model
	local segLen = 10
	local n = math.max(16, math.ceil(2 * math.pi * R / segLen))
	local actualLen = 2 * math.pi * (R + 1.5) / n + 0.6
	for i = 0, n - 1 do
		local a = (i + 0.5) / n * math.pi * 2
		local cx, cz = math.cos(a) * (R + 1.5), math.sin(a) * (R + 1.5)
		local look = CFrame.lookAt(Vector3.new(cx, 0, cz), Vector3.new(0, 0, 0))
		makePart(walls, {
			name = "Wall",
			size = Vector3.new(actualLen, ArenaBuilder.WALL_HEIGHT, 3),
			cframe = look + Vector3.new(0, ArenaBuilder.WALL_HEIGHT / 2, 0),
			color = th.wall,
			material = th.wallMaterial,
			collide = true,
		})
		makePart(walls, {
			name = "Barrier",
			size = Vector3.new(actualLen, ArenaBuilder.BARRIER_HEIGHT, 1),
			cframe = look + Vector3.new(0, ArenaBuilder.BARRIER_HEIGHT / 2, 0),
			color = th.wall,
			collide = true,
			transparency = 1,
			shadow = false,
		})
	end

	-- Boss pad at the centre (decor; flat, non-colliding).
	makePart(model, {
		name = "BossPad",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(0.2, ArenaBuilder.BOSS_PAD_RADIUS * 2, ArenaBuilder.BOSS_PAD_RADIUS * 2),
		cframe = cylinderCF(0, 0.08, 0),
		color = accent,
		material = Enum.Material.Marble,
		shadow = false,
	})
	makePart(model, {
		name = "BossPadRing",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(0.22, ArenaBuilder.BOSS_PAD_RADIUS * 2 + 2, ArenaBuilder.BOSS_PAD_RADIUS * 2 + 2),
		cframe = cylinderCF(0, 0.06, 0),
		color = accent:Lerp(Color3.new(0, 0, 0), 0.4),
		material = Enum.Material.Neon,
		shadow = false,
	})

	local spawnZ = math.min(R * 0.3, ArenaBuilder.BOSS_PAD_RADIUS + 14)
	local spawn = Vector3.new(0, 4, spawnZ)

	-- POIs on a ring between the pad and the rim.
	local poiFolder = Instance.new("Folder")
	poiFolder.Name = "POIs"
	poiFolder.Parent = model
	local pois = {}
	local given = opts and opts.pois
	if type(given) == "table" and #given > 0 then
		-- RunDirector's layout (Combat/Pois.layout): the World runs these exact spots.
		for _, entry in given do
			local id = tostring(entry.kind)
			local x, z = tonumber(entry.x) or 0, tonumber(entry.z) or 0
			buildPoi(poiFolder, id, x, z, accent, rng, entry)
			table.insert(pois, { id = id, x = x, z = z, r = tonumber(entry.r) or 6 })
		end
	else
		local slots = if type(def.poiSlots) == "number" then def.poiSlots else FALLBACK_DEF.poiSlots
		local poiIds = rollPois(rng, def.id or mapId, def, slots)
		local a0 = rng:range(0, math.pi * 2)
		for i, id in poiIds do
			local a = a0 + (i - 1) / #poiIds * math.pi * 2 + rng:range(-0.15, 0.15)
			local d = R * rng:range(0.55, 0.8)
			local x, z = math.cos(a) * d, math.sin(a) * d
			buildPoi(poiFolder, id, x, z, accent, rng)
			table.insert(pois, { id = id, x = x, z = z, r = 6 })
		end
	end

	-- Obstacles.
	local obsFolder = Instance.new("Folder")
	obsFolder.Name = "Obstacles"
	obsFolder.Parent = model
	local obstacles: { Obstacle } = {}
	local kinds, weights = {}, {}
	for _, k in th.kinds do
		table.insert(kinds, k.kind)
		table.insert(weights, k.weight)
	end
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
		for _, o in obstacles do
			if (x - o.x) ^ 2 + (z - o.z) ^ 2 < (o.r + r + 7) ^ 2 then
				return false -- leave lanes so the horde can flow
			end
		end
		for _, p in pois do
			if (x - p.x) ^ 2 + (z - p.z) ^ 2 < (r + (p.r or 6) + 6) ^ 2 then
				return false -- (same rule as tests/sim/Headless.arena)
			end
		end
		return true
	end
	for _ = 1, want do
		local kind = kinds[rng:weightedIndex(weights)]
		local builder = BUILDERS[kind] or BUILDERS.rock
		for _ = 1, 30 do
			local r = rng:range(2.5, 5)
			local a = rng:range(0, math.pi * 2)
			local d = math.sqrt(rng:range(0, 1)) * R
			local x, z = math.cos(a) * d, math.sin(a) * d
			if free(x, z, r) then
				local m = Instance.new("Model")
				m.Name = kind
				m:SetAttribute("Radius", r)
				m.Parent = obsFolder
				-- Builders size the solid part from `r` (trees use a trunk of r*0.6 etc.);
				-- record the matching collision radius.
				builder(m, x, z, r, th, rng)
				local solidR = r
				if kind == "tree" or kind == "jungle_tree" then
					solidR = r * 0.6
				elseif kind == "dead_tree" then
					solidR = r * 0.55
				elseif kind == "pine" then
					solidR = r * 0.5
				elseif kind == "palm" then
					solidR = r * 0.45
				elseif kind == "wedge" then
					solidR = r * 0.8 * math.sqrt(2) -- circumscribes the 1.6r x 1.6r wedge
				end
				table.insert(obstacles, { x = x, z = z, r = solidR })
				break
			end
		end
	end

	model.WorldPivot = CFrame.new(0, 0, 0)
	model.Parent = Workspace

	return {
		model = model,
		obstacles = obstacles,
		spawn = spawn,
		radius = R,
		center = Vector3.new(0, 0, 0),
		pois = pois,
	}
end

-- Portal (GDD §3.9) ----------------------------------------------------------------------

ArenaBuilder.PORTAL_NAME = "RindGate"
ArenaBuilder.PORTAL_RADIUS = 6
ArenaBuilder.PORTAL_SEGMENTS = 16
local PORTAL_GOLD = Color3.fromRGB(255, 204, 51)

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

-- A ring of neon segments on the ground, a floating inner ring and a glowing pool.
-- Static parts (the swirl is animated on each client by FxController); every
-- neon part is tagged with the "Tint" attribute so setPortalColor can recolour it.
function ArenaBuilder.buildPortal(x: number, z: number, color: Color3?): Model
	ArenaBuilder.clearPortal()
	local c = color or PORTAL_GOLD
	local m = Instance.new("Model")
	m.Name = ArenaBuilder.PORTAL_NAME
	m:SetAttribute("X", x)
	m:SetAttribute("Z", z)
	local R = ArenaBuilder.PORTAL_RADIUS
	local n = ArenaBuilder.PORTAL_SEGMENTS
	local segLen = 2 * math.pi * R / n + 0.2
	for ring = 1, 2 do
		local rr = if ring == 1 then R else R * 0.7
		local y = if ring == 1 then 0.35 else 3.2
		for i = 0, n - 1 do
			local a = (i + 0.5) / n * math.pi * 2
			local px, pz = x + math.cos(a) * rr, z + math.sin(a) * rr
			local seg = makePart(m, {
				name = "Ring" .. ring,
				size = Vector3.new(if ring == 1 then segLen else segLen * 0.6, 0.5, 0.6),
				cframe = CFrame.lookAt(Vector3.new(px, y, pz), Vector3.new(x, y, z))
					* CFrame.Angles(0, math.rad(90), 0),
				color = c,
				material = Enum.Material.Neon,
				shadow = false,
			})
			seg:SetAttribute("Tint", true)
		end
	end
	local pool = makePart(m, {
		name = "Pool",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(0.2, R * 2 - 0.6, R * 2 - 0.6),
		cframe = cylinderCF(x, 0.12, z),
		color = c,
		material = Enum.Material.Neon,
		transparency = 0.45,
		shadow = false,
	})
	pool:SetAttribute("Tint", true)
	local column = makePart(m, {
		name = "Column",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(12, R * 1.2, R * 1.2),
		cframe = CFrame.new(x, 6, z) * CFrame.Angles(0, 0, math.rad(90)),
		color = c,
		material = Enum.Material.Neon,
		transparency = 0.85,
		shadow = false,
	})
	column:SetAttribute("Tint", true)
	local light = Instance.new("PointLight")
	light.Brightness = 3
	light.Range = 24
	light.Color = c
	light.Parent = pool
	m.Parent = portalParent()
	return m
end

function ArenaBuilder.setPortalColor(color: Color3)
	local m = portalParent():FindFirstChild(ArenaBuilder.PORTAL_NAME)
	if not m then
		return
	end
	for _, d in m:GetDescendants() do
		if (d:IsA("BasePart") and d:GetAttribute("Tint")) or d:IsA("PointLight") then
			(d :: any).Color = color
		end
	end
end

return ArenaBuilder
