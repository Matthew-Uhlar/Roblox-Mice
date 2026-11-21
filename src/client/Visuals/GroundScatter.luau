--!strict
-- GroundScatter (v4, team G, client): streamed micro decor around the camera.
--
--   GroundScatter.init(lowSpec, mobile)
--   GroundScatter.step(dt, focus: Vector3)   CameraController calls it every frame
--   GroundScatter.clear()
--   GroundScatter.itemsAt(theme, seed, cx, cz) -> {{x, z, kind}}   pure (previews / tests)
--
-- The v4 maps are 300-560 studs in radius; the server's part budget (3,500
-- per arena) cannot carpet that much floor. So the dense layer lives here: the
-- floor is cut into CELL-stud cells, every cell gets PER_CELL deterministic
-- items (hash of the arena's DecorSeed and the cell), and only the cells
-- within VIEW studs of the camera focus are drawn, from a fixed pool of parts
-- (POOL; reused as the camera moves, one BulkMoveTo per refresh). Nothing
-- collides or is queryable, and everything sits within 0.6 stud of the floor.
-- Items keep off the boss pad, squad corners, obstacles, POIs and signature
-- features (positions from the arena's attributes: Radius, Theme, DecorSeed and
-- X / Z / Radius on the Obstacles, POIs and Signature models). Low-spec
-- devices draw nothing; phones draw a smaller radius from a smaller pool.

local GroundScatter = {}

local ArenaHeight: any = nil
do
	local inst = script.Parent:FindFirstChild("ArenaHeight")
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		ArenaHeight = if ok and type(mod) == "table" then mod else nil
	end
end

GroundScatter.CELL = 14
GroundScatter.PER_CELL = 6 -- iter3 (T-29): denser floor at the gameplay camera
GroundScatter.SIZE = 1.8 -- every kind's size range x this (they must read from ~60 studs)
GroundScatter.CLUMP = 2.6 -- items 2.. sit within this many studs of the first (clusters read better)
GroundScatter.VIEW = 78
GroundScatter.VIEW_MOBILE = 58
GroundScatter.POOL = 780
GroundScatter.POOL_MOBILE = 340
GroundScatter.REFRESH = 0.2

local rgb = Color3.fromRGB
local V3 = Vector3.new
local CF = CFrame.new
local M = Enum.Material
local PARK = CF(0, -5000, 0)

-- {shape, min size, max size, colours, material, y lift, tilt}
type Kind = {
	shape: Enum.PartType,
	lo: Vector3,
	hi: Vector3,
	colors: { Color3 },
	material: Enum.Material,
	y: number,
	neon: boolean?,
}

local K = Enum.PartType
local function kind(shape, lo, hi, colors, material, y, neon): Kind
	return { shape = shape, lo = lo, hi = hi, colors = colors, material = material, y = y, neon = neon }
end

local TUFT = function(colors: { Color3 }): Kind
	return kind(K.Block, V3(0.18, 0.5, 0.18), V3(0.25, 1.0, 0.25), colors, M.Grass, 0.25)
end
local PEBBLE = function(colors: { Color3 }): Kind
	return kind(K.Ball, V3(0.35, 0.35, 0.35), V3(0.9, 0.9, 0.9), colors, M.Rock, -0.12)
end
local FLOWER = function(colors: { Color3 }): Kind
	return kind(K.Ball, V3(0.35, 0.35, 0.35), V3(0.55, 0.55, 0.55), colors, M.SmoothPlastic, 0.35)
end

local THEMES: { [string]: { Kind } } = {
	plains = {
		TUFT({ rgb(96, 170, 62), rgb(124, 192, 76), rgb(80, 150, 52) }),
		TUFT({ rgb(110, 182, 70) }),
		FLOWER({ rgb(255, 255, 255), rgb(255, 210, 60), rgb(255, 130, 170), rgb(170, 140, 255) }),
		PEBBLE({ rgb(160, 156, 148), rgb(120, 118, 112) }),
	},
	forest = {
		TUFT({ rgb(60, 130, 56), rgb(80, 148, 60) }),
		kind(
			K.Ball,
			V3(0.4, 0.4, 0.4),
			V3(0.7, 0.7, 0.7),
			{ rgb(214, 48, 44), rgb(240, 170, 60) },
			M.SmoothPlastic,
			0.2
		),
		PEBBLE({ rgb(118, 120, 110), rgb(90, 92, 84) }),
		kind(
			K.Block,
			V3(0.8, 0.12, 0.5),
			V3(1.4, 0.15, 0.8),
			{ rgb(150, 100, 50), rgb(120, 80, 40) },
			M.SmoothPlastic,
			0.06
		), -- leaves
	},
	jungle = {
		TUFT({ rgb(40, 130, 56), rgb(70, 160, 60) }),
		FLOWER({ rgb(255, 70, 90), rgb(255, 170, 30), rgb(200, 80, 220) }),
		kind(
			K.Block,
			V3(1, 0.1, 0.6),
			V3(1.8, 0.12, 1),
			{ rgb(40, 120, 50), rgb(60, 150, 60) },
			M.SmoothPlastic,
			0.05
		),
		PEBBLE({ rgb(110, 120, 100) }),
	},
	beach = {
		kind(
			K.Ball,
			V3(0.4, 0.4, 0.4),
			V3(0.7, 0.7, 0.7),
			{ rgb(255, 230, 220), rgb(255, 180, 160), rgb(250, 240, 200) },
			M.SmoothPlastic,
			0.0
		),
		PEBBLE({ rgb(200, 186, 160), rgb(170, 155, 130) }),
		TUFT({ rgb(140, 175, 90) }),
		kind(K.Block, V3(0.6, 0.1, 0.12), V3(1.2, 0.12, 0.15), { rgb(150, 120, 80) }, M.Wood, 0.06), -- driftwood
	},
	tundra = {
		kind(
			K.Ball,
			V3(0.8, 0.8, 0.8),
			V3(1.8, 1.8, 1.8),
			{ rgb(245, 250, 255), rgb(230, 240, 252) },
			M.Snow,
			-0.5
		),
		kind(
			K.Block,
			V3(0.3, 0.6, 0.4),
			V3(0.5, 1.3, 0.6),
			{ rgb(170, 215, 245), rgb(200, 235, 255) },
			M.Ice,
			0.35
		),
		PEBBLE({ rgb(110, 120, 140), rgb(150, 160, 180) }),
	},
	volcano = {
		PEBBLE({ rgb(50, 42, 42), rgb(80, 70, 68) }),
		kind(
			K.Ball,
			V3(0.25, 0.25, 0.25),
			V3(0.45, 0.45, 0.45),
			{ rgb(255, 120, 40), rgb(255, 170, 60) },
			M.Neon,
			0.05,
			true
		),
		kind(K.Block, V3(0.4, 0.5, 0.5), V3(0.8, 1.0, 0.9), { rgb(60, 50, 50) }, M.Basalt, 0.2),
	},
	swamp = {
		TUFT({ rgb(100, 120, 60), rgb(80, 110, 50) }),
		kind(
			K.Ball,
			V3(0.3, 0.3, 0.3),
			V3(0.5, 0.5, 0.5),
			{ rgb(150, 255, 120), rgb(120, 230, 200) },
			M.Neon,
			0.1,
			true
		),
		PEBBLE({ rgb(84, 92, 78), rgb(104, 96, 70) }),
		kind(K.Cylinder, V3(0.06, 0.9, 0.9), V3(0.06, 1.5, 1.5), { rgb(90, 150, 60) }, M.SmoothPlastic, 0.04), -- lily leaf
	},
	moon = {
		PEBBLE({ rgb(200, 205, 230), rgb(120, 125, 150), rgb(80, 82, 105) }),
		kind(
			K.Block,
			V3(0.25, 0.5, 0.3),
			V3(0.4, 1.0, 0.5),
			{ rgb(150, 210, 255), rgb(190, 160, 255) },
			M.Neon,
			0.25,
			true
		),
		PEBBLE({ rgb(160, 165, 190) }),
	},
	ocean = {
		kind(
			K.Ball,
			V3(0.4, 0.4, 0.4),
			V3(0.8, 0.8, 0.8),
			{ rgb(255, 110, 150), rgb(255, 170, 80), rgb(180, 110, 230) },
			M.SmoothPlastic,
			0.1
		),
		kind(
			K.Block,
			V3(0.15, 0.8, 0.15),
			V3(0.2, 1.5, 0.2),
			{ rgb(60, 150, 90), rgb(80, 170, 100) },
			M.SmoothPlastic,
			0.4
		), -- kelp
		PEBBLE({ rgb(150, 170, 175), rgb(110, 130, 140) }),
	},
}
GroundScatter.THEMES = THEMES

-- iter3 accents: one bigger readable piece per theme (budget-free, client side)
local ACCENTS: { [string]: Kind } = {
	plains = kind(
		K.Ball,
		V3(1.6, 1.6, 1.6),
		V3(2.6, 2.6, 2.6),
		{ rgb(86, 160, 62), rgb(110, 180, 70) },
		M.Grass,
		-0.3
	),
	forest = kind(
		K.Ball,
		V3(1.8, 1.8, 1.8),
		V3(2.8, 2.8, 2.8),
		{ rgb(52, 120, 52), rgb(70, 135, 58) },
		M.LeafyGrass,
		-0.3
	),
	jungle = kind(
		K.Ball,
		V3(1.8, 1.8, 1.8),
		V3(3.0, 3.0, 3.0),
		{ rgb(40, 130, 56), rgb(60, 150, 60) },
		M.LeafyGrass,
		-0.3
	),
	beach = kind(
		K.Ball,
		V3(1.4, 1.4, 1.4),
		V3(2.4, 2.4, 2.4),
		{ rgb(200, 186, 160), rgb(180, 165, 140) },
		M.Sandstone,
		-0.4
	),
	tundra = kind(
		K.Block,
		V3(0.9, 2.0, 0.9),
		V3(1.3, 3.0, 1.3),
		{ rgb(170, 215, 245), rgb(200, 235, 255) },
		M.Ice,
		0.6
	),
	volcano = kind(
		K.Ball,
		V3(1.6, 1.6, 1.6),
		V3(2.6, 2.6, 2.6),
		{ rgb(50, 42, 42), rgb(70, 58, 56) },
		M.Basalt,
		-0.3
	),
	swamp = kind(
		K.Ball,
		V3(1.0, 1.0, 1.0),
		V3(1.6, 1.6, 1.6),
		{ rgb(150, 255, 120), rgb(120, 230, 200) },
		M.Neon,
		0.2,
		true
	),
	moon = kind(
		K.Block,
		V3(0.6, 1.6, 0.6),
		V3(1.0, 2.6, 1.0),
		{ rgb(150, 210, 255), rgb(190, 160, 255) },
		M.Neon,
		0.5,
		true
	),
	ocean = kind(
		K.Ball,
		V3(1.4, 1.4, 1.4),
		V3(2.4, 2.4, 2.4),
		{ rgb(255, 110, 150), rgb(180, 110, 230) },
		M.SmoothPlastic,
		0
	),
}
GroundScatter.ACCENTS = ACCENTS

type Circle = { x: number, z: number, r: number }
type Item = {
	x: number,
	z: number,
	k: number,
	size: Vector3,
	color: Color3,
	yaw: number,
	tilt: number,
	kd: Kind?,
}

local enabled = true
local view = GroundScatter.VIEW
local poolSize = GroundScatter.POOL
local folder: Folder? = nil
local pool: { BasePart } = {}
local free: { BasePart } = {}
local cells: { [number]: { parts: { BasePart } } } = {}
local cellItems: { [number]: { Item } } = {}
local arenaRef: Instance? = nil
local arenaR = 0
local theme = "plains"
local seed = 1
local keep: { Circle } = {}
local refreshAt = 0
local lastCell: number? = nil

-- deterministic 0..1 hash of three integers
local U32 = 4294967296
local function hash(a: number, b: number, c: number): number
	local h = bit32.bxor((a * 73856093) % U32, (b * 19349663) % U32, (c * 83492791) % U32)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = (h * 69069 + 12345) % U32
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h / U32
end

local function cellKey(ix: number, iz: number): number
	return (ix + 4096) * 8192 + (iz + 4096)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Pure: the items of cell (cx, cz) for a theme and seed (no exclusions).
function GroundScatter.itemsAt(themeId: string, s: number, cx: number, cz: number): { Item }
	local kinds = THEMES[themeId] or THEMES.plains
	local cell = GroundScatter.CELL
	local out = {}
	local sd = math.floor(s) % 100000
	for i = 1, GroundScatter.PER_CELL do
		local u = hash(cx, cz, sd * 7 + i)
		local v = hash(cz, sd + i * 13, cx)
		local w = hash(sd + i, cx * 3, cz * 5)
		local q = hash(cx * 7 + i, cz * 11, sd)
		local k = 1 + math.floor(w * #kinds) % #kinds
		-- iter3: about 1 item in 12 is a bigger accent (a boulder / bush / crystal)
		local acc = ACCENTS[themeId] or ACCENTS.plains
		local useAccent = hash(cx * 13 + i, cz * 7, sd + 99) < 0.085
		local kd = if useAccent then acc else kinds[k]
		local k2 = if useAccent then 1 else GroundScatter.SIZE
		local sz = V3(lerp(kd.lo.X, kd.hi.X, q), lerp(kd.lo.Y, kd.hi.Y, q), lerp(kd.lo.Z, kd.hi.Z, q)) * k2
		if kd.shape == K.Cylinder then
			sz = V3(kd.lo.X, sz.Y, sz.Z) -- keep discs flat
		end
		local x, z = (cx + u) * cell, (cz + v) * cell
		local first = out[1]
		if first then
			local c = GroundScatter.CLUMP
			x, z = first.x + (u - 0.5) * 2 * c, first.z + (v - 0.5) * 2 * c
		end
		table.insert(out, {
			x = x,
			z = z,
			k = k,
			kd = kd,
			size = sz,
			color = kd.colors[1 + math.floor(u * 997) % #kd.colors],
			yaw = v * 6.28,
			tilt = (q - 0.5) * 0.5,
		})
	end
	return out
end

local function blocked(x: number, z: number): boolean
	local d2 = x * x + z * z
	if d2 > (arenaR - 3) ^ 2 or d2 < 20 * 20 then
		return true
	end
	for _, c in keep do
		local dx, dz = x - c.x, z - c.z
		if dx * dx + dz * dz < c.r * c.r then
			return true
		end
	end
	return false
end

local function readArena(arena: Instance)
	arenaRef = arena
	arenaR = tonumber(arena:GetAttribute("Radius")) or 0
	local th = arena:GetAttribute("Theme")
	theme = if type(th) == "string" then th else tostring(arena:GetAttribute("MapId") or "plains")
	seed = tonumber(arena:GetAttribute("DecorSeed")) or 1
	table.clear(keep)
	for _, fname in { "Obstacles", "POIs", "Signature", "Biome" } do
		local f = arena:FindFirstChild(fname)
		if f then
			for _, m in f:GetChildren() do
				local x, z = tonumber(m:GetAttribute("X")), tonumber(m:GetAttribute("Z"))
				if x and z then
					local r = (tonumber(m:GetAttribute("Radius")) or 6) + (if fname == "POIs" then 8 else 2)
					table.insert(keep, { x = x, z = z, r = r })
				end
			end
		end
	end
	for _, c in arena:GetChildren() do
		if string.sub(c.Name, 1, 11) == "SquadCorner" then
			local disc = c:FindFirstChild("SafeDisc")
			if disc and disc:IsA("BasePart") then
				table.insert(keep, { x = disc.Position.X, z = disc.Position.Z, r = disc.Size.Y / 2 + 2 })
			end
		end
	end
	table.clear(cellItems)
end

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "TrunkfallScatter"
	f.Parent = workspace
	folder = f
	return f
end

local function take(): BasePart?
	local p = table.remove(free)
	if p then
		return p
	end
	if #pool >= poolSize then
		return nil
	end
	local np = Instance.new("Part")
	np.Anchored = true
	np.CanCollide = false
	np.CanQuery = false
	np.CanTouch = false
	np.CastShadow = false
	np.CFrame = PARK
	np.Parent = getFolder()
	table.insert(pool, np)
	return np
end

local function releaseCell(key: number, moves: { BasePart }, cfs: { CFrame })
	local c = cells[key]
	if not c then
		return
	end
	for _, p in c.parts do
		table.insert(moves, p)
		table.insert(cfs, PARK)
		table.insert(free, p)
	end
	cells[key] = nil
end

local function fillCell(key: number, ix: number, iz: number, moves: { BasePart }, cfs: { CFrame })
	local items = cellItems[key]
	if not items then
		items = {}
		for _, it in GroundScatter.itemsAt(theme, seed, ix, iz) do
			if not blocked(it.x, it.z) then
				table.insert(items, it)
			end
		end
		cellItems[key] = items
	end
	local kinds = THEMES[theme] or THEMES.plains
	local parts = {}
	for _, it in items do
		local p = take()
		if not p then
			break
		end
		local kd = it.kd or kinds[it.k]
		local pp = p :: Part
		pp.Shape = kd.shape
		pp.Size = it.size
		pp.Color = it.color
		pp.Material = kd.material
		table.insert(parts, p)
		table.insert(moves, p)
		local gy = if ArenaHeight then ArenaHeight.at(it.x, it.z) else 0 -- iter4 plateaus
		local cf = CF(it.x, gy + kd.y + it.size.Y * 0.5 * (if kd.shape == K.Ball then 0.6 else 1), it.z)
		if kd.shape == K.Cylinder then
			cf = CF(it.x, gy + kd.y, it.z) * CFrame.Angles(0, it.yaw, math.pi / 2) -- flat disc
		else
			cf *= CFrame.Angles(it.tilt, it.yaw, 0)
		end
		table.insert(cfs, cf)
	end
	cells[key] = { parts = parts }
end

local deviceLow = false
local decorLow = false

-- iteration 5 Phase B #3: Decor = "full" | "low" (applied live: low clears
-- the floor scatter; full brings it back on the next refresh).
function GroundScatter.setDecor(level: string)
	decorLow = level == "low"
	local want = not deviceLow and not decorLow
	if want ~= enabled then
		enabled = want
		GroundScatter.clear()
		refreshAt = 0
	end
end

function GroundScatter.init(lowSpec: boolean, mobile: boolean)
	deviceLow = lowSpec
	enabled = not lowSpec and not decorLow
	view = if mobile then GroundScatter.VIEW_MOBILE else GroundScatter.VIEW
	poolSize = if mobile then GroundScatter.POOL_MOBILE else GroundScatter.POOL
end

function GroundScatter.clear()
	local moves, cfs = {}, {}
	for key in cells do
		releaseCell(key, moves, cfs)
	end
	if #moves > 0 then
		workspace:BulkMoveTo(moves, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
	table.clear(cellItems)
	lastCell = nil
	arenaRef = nil
end

function GroundScatter.step(dt: number, focus: Vector3)
	if not enabled then
		return
	end
	refreshAt -= dt
	if refreshAt > 0 then
		return
	end
	refreshAt = GroundScatter.REFRESH
	local arena = workspace:FindFirstChild("Arena")
	if arena ~= arenaRef then
		GroundScatter.clear()
		if arena and (tonumber(arena:GetAttribute("Radius")) or 0) > 0 then
			readArena(arena)
		end
	end
	if not arenaRef then
		return
	end
	local cell = GroundScatter.CELL
	local fx, fz = math.floor(focus.X / cell), math.floor(focus.Z / cell)
	local here = cellKey(fx, fz)
	if here == lastCell then
		return
	end
	lastCell = here
	local span = math.ceil(view / cell)
	local want: { [number]: boolean } = {}
	local order: { { number } } = {}
	for dx = -span, span do
		for dz = -span, span do
			local d2 = (dx * dx + dz * dz) * cell * cell
			if d2 <= view * view then
				local key = cellKey(fx + dx, fz + dz)
				want[key] = true
				table.insert(order, { d2, fx + dx, fz + dz, key })
			end
		end
	end
	local moves, cfs = {}, {}
	for key in cells do
		if not want[key] then
			releaseCell(key, moves, cfs)
		end
	end
	table.sort(order, function(a, b)
		return a[1] < b[1]
	end)
	for _, o in order do
		if not cells[o[4]] then
			fillCell(o[4], o[2], o[3], moves, cfs)
		end
	end
	if #moves > 0 then
		workspace:BulkMoveTo(moves, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function GroundScatter.destroy()
	GroundScatter.clear()
	if folder then
		folder:Destroy()
		folder = nil
	end
	table.clear(pool)
	table.clear(free)
end

return GroundScatter
