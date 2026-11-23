--!strict
-- BuildModels (iteration 6, team Client): part-built models for the builder
-- elephant's structures, drawn locally by Controllers/BuildRenderer.
--
--   BuildModels.turret(opts) -> Built      Deploy Turret: a tripod, a post and a
--                                          turning head with a rivet barrel
--   BuildModels.barricade(opts) -> Built   Barricade: planks between posts with
--                                          metal bands, `len` studs long
--   BuildModels.hpBar(adornee, color) -> HpBar   a small billboard HP bar
--   BuildModels.place(b, x, y, z, yaw)     pivots the whole model (yaw = atan2 of
--                                          the facing, BuildMath.placement)
--   BuildModels.aim(b, yaw)                turns a turret head (world yaw)
--   BuildModels.ghostify(b, color)         see-through preview look
--
-- Same style as the rest of the game (chunky blocks, wood / metal / a cheese
-- accent, a squad-colour stripe). Every part is anchored, non-colliding and
-- non-queryable. `low` (Device.lowSpec / far away) builds about half the parts.
-- The model's front is its local -Z; CFrame.Angles(0, yaw + pi, 0) faces +yaw.

local BuildModels = {}

local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local rgb = Color3.fromRGB
local M = Enum.Material

local WOOD = rgb(150, 98, 56)
local WOOD_DARK = rgb(108, 68, 38)
local METAL = rgb(150, 158, 170)
local METAL_DARK = rgb(84, 90, 102)
local CHEESE = rgb(255, 204, 51)
local INK = rgb(40, 30, 24)

export type Built = {
	model: Model,
	root: BasePart, -- invisible pivot at ground level
	parts: { BasePart },
	offsets: { CFrame }, -- each part relative to the root
	head: { BasePart }?, -- turret head parts (turn with BuildModels.aim)
	headOffsets: { CFrame }?, -- relative to the head pivot
	headPivot: CFrame?, -- head pivot relative to the root
	eye: BasePart?, -- the turret's glowing eye (flashes on a shot)
	stripe: { BasePart }, -- squad-colour parts
	kind: string,
	yaw: number,
}

local function part(
	model: Model,
	shape: Enum.PartType,
	size: Vector3,
	color: Color3,
	material: Enum.Material?
): BasePart
	local p = Instance.new("Part")
	p.Shape = shape
	p.Size = size
	p.Color = color
	p.Material = material or M.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

local function newBuilt(name: string, kind: string): Built
	local model = Instance.new("Model")
	model.Name = name
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = V3(0.2, 0.2, 0.2)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Parent = model
	model.PrimaryPart = root
	return {
		model = model,
		root = root,
		parts = {},
		offsets = {},
		stripe = {},
		kind = kind,
		yaw = 0,
	}
end

local function add(b: Built, p: BasePart, offset: CFrame)
	table.insert(b.parts, p)
	table.insert(b.offsets, offset)
end

local BLOCK = Enum.PartType.Block
local CYL = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball

export type Opts = {
	low: boolean?,
	color: Color3?, -- squad / owner colour (the stripe)
	len: number?, -- barricade length
	scale: number?,
}

-- Deploy Turret: ~3.4 studs tall, a 3-stud footprint.
function BuildModels.turret(opts: Opts?): Built
	local o: Opts = opts or {}
	local k = o.scale or 1
	local low = o.low == true
	local stripeColor = o.color or CHEESE
	local b = newBuilt("BuilderTurret", "turret")
	local m = b.model
	-- base plate + tripod
	add(b, part(m, CYL, V3(0.4, 3.2, 3.2) * k, METAL_DARK, M.Metal), CF(0, 0.2 * k, 0) * ANG(0, 0, math.pi / 2))
	if not low then
		for i = 0, 2 do
			local a = i / 3 * math.pi * 2
			add(
				b,
				part(m, BLOCK, V3(0.35, 1.6, 0.35) * k, WOOD_DARK, M.Wood),
				CF(math.cos(a) * 1.05 * k, 0.75 * k, math.sin(a) * 1.05 * k) * ANG(0, -a, 0) * ANG(0, 0, math.rad(22))
			)
		end
		local ring = part(m, CYL, V3(0.25, 2.1, 2.1) * k, stripeColor, M.SmoothPlastic)
		add(b, ring, CF(0, 0.45 * k, 0) * ANG(0, 0, math.pi / 2))
		table.insert(b.stripe, ring)
	end
	-- post
	add(b, part(m, CYL, V3(1.7, 0.7, 0.7) * k, METAL, M.Metal), CF(0, 1.2 * k, 0) * ANG(0, 0, math.pi / 2))
	-- head (turns): a boxy housing, a stripe, a barrel and a glowing eye
	local pivot = CF(0, 2.35 * k, 0)
	local head: { BasePart } = {}
	local headOff: { CFrame } = {}
	local function addHead(p: BasePart, off: CFrame)
		table.insert(head, p)
		table.insert(headOff, off)
	end
	addHead(part(m, BLOCK, V3(1.6, 1.1, 1.8) * k, WOOD, M.Wood), CF(0, 0, 0.1 * k))
	local band = part(m, BLOCK, V3(1.65, 0.3, 1.85) * k, stripeColor, M.SmoothPlastic)
	addHead(band, CF(0, 0.3 * k, 0.1 * k))
	table.insert(b.stripe, band)
	addHead(part(m, CYL, V3(1.9, 0.45, 0.45) * k, METAL_DARK, M.Metal), CF(0, -0.05 * k, -1.6 * k) * ANG(0, math.pi / 2, 0))
	if not low then
		addHead(part(m, CYL, V3(0.25, 0.65, 0.65) * k, INK, M.Metal), CF(0, -0.05 * k, -2.5 * k) * ANG(0, math.pi / 2, 0))
		addHead(part(m, BLOCK, V3(0.25, 0.6, 0.8) * k, METAL, M.Metal), CF(0.9 * k, 0, 0.3 * k))
		addHead(part(m, BLOCK, V3(0.25, 0.6, 0.8) * k, METAL, M.Metal), CF(-0.9 * k, 0, 0.3 * k))
	end
	local eye = part(m, BALL, V3(0.45, 0.45, 0.45) * k, CHEESE, M.Neon)
	addHead(eye, CF(0, 0.15 * k, -0.85 * k))
	b.eye = eye
	b.head, b.headOffsets, b.headPivot = head, headOff, pivot
	return b
end

-- Barricade: planks between posts, `len` long (default 14), ~3.2 tall.
function BuildModels.barricade(opts: Opts?): Built
	local o: Opts = opts or {}
	local len = math.max(2, o.len or 14)
	local low = o.low == true
	local stripeColor = o.color or CHEESE
	local b = newBuilt("BuilderBarricade", "barricade")
	local m = b.model
	local posts = if low then 2 else math.max(3, math.floor(len / 5) + 1)
	for i = 0, posts - 1 do
		local x = -len / 2 + 0.4 + (len - 0.8) * i / (posts - 1)
		add(b, part(m, BLOCK, V3(0.8, 3.6, 0.8), WOOD_DARK, M.Wood), CF(x, 1.8, 0))
		if not low then
			-- a little cheese cap on each post
			local cap = part(m, BLOCK, V3(0.95, 0.3, 0.95), stripeColor, M.SmoothPlastic)
			add(b, cap, CF(x, 3.7, 0))
			table.insert(b.stripe, cap)
		end
	end
	local rows = if low then 1 else 3
	for r = 1, rows do
		local y = if low then 1.6 else 0.6 + (r - 1) * 1.05
		local tilt = if low then 0 else math.rad((r % 2 == 0) and 1.5 or -1.5)
		add(b, part(m, BLOCK, V3(len, if low then 2.6 else 0.85, 0.45), WOOD, M.Wood), CF(0, y, 0.15) * ANG(0, 0, tilt))
	end
	if not low then
		-- metal bands and a squad-colour stripe along the top
		for _, x in { -len / 4, len / 4 } do
			add(b, part(m, BLOCK, V3(0.3, 2.9, 0.6), METAL, M.Metal), CF(x, 1.55, 0.2))
		end
		local stripe = part(m, BLOCK, V3(len - 0.4, 0.22, 0.5), stripeColor, M.SmoothPlastic)
		add(b, stripe, CF(0, 3.05, 0.1))
		table.insert(b.stripe, stripe)
	end
	return b
end

local function headCF(b: Built, base: CFrame, worldYaw: number): CFrame?
	local pivot = b.headPivot
	if not pivot then
		return nil
	end
	local p = base * pivot
	return CF(p.Position) * ANG(0, worldYaw + math.pi, 0)
end

-- Pivots the model to (x, y, z) facing `yaw`.
function BuildModels.place(b: Built, x: number, y: number, z: number, yaw: number)
	b.yaw = yaw
	local base = CF(x, y, z) * ANG(0, yaw + math.pi, 0)
	b.root.CFrame = base
	local parts, offs = b.parts, b.offsets
	local cframes = table.create(#parts) :: { CFrame }
	for i, off in offs do
		cframes[i] = base * off
	end
	workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	BuildModels.aim(b, yaw)
end

-- Turns a turret head to a world yaw (no-op for barricades).
function BuildModels.aim(b: Built, worldYaw: number)
	local head, offs = b.head, b.headOffsets
	if not head or not offs then
		return
	end
	local hc = headCF(b, b.root.CFrame, worldYaw)
	if not hc then
		return
	end
	local cframes = table.create(#head) :: { CFrame }
	for i, off in offs do
		cframes[i] = hc * off
	end
	workspace:BulkMoveTo(head, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

-- Recolours the squad-colour parts.
function BuildModels.setColor(b: Built, color: Color3)
	for _, p in b.stripe do
		p.Color = color
	end
end

-- A see-through preview (the placement ghost).
function BuildModels.ghostify(b: Built, color: Color3)
	local function look(p: BasePart)
		p.Material = M.Neon
		p.Color = color
		p.Transparency = 0.62
	end
	for _, p in b.parts do
		look(p)
	end
	for _, p in b.head or {} do
		look(p)
	end
	b.model.Name ..= "Ghost"
end

export type HpBar = {
	gui: BillboardGui,
	fill: Frame,
	set: (frac: number, color: Color3?) -> (),
}

-- A small HP bar over a structure (hidden past 140 studs: LOD).
function BuildModels.hpBar(adornee: BasePart, height: number, width: number?): HpBar
	local gui = Instance.new("BillboardGui")
	gui.Name = "BuildHp"
	gui.Adornee = adornee
	gui.Size = UDim2.new(width or 3.2, 0, 0.38, 0)
	gui.StudsOffsetWorldSpace = V3(0, height, 0)
	gui.MaxDistance = 140
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	local back = Instance.new("Frame")
	back.Name = "Back"
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = INK
	back.BackgroundTransparency = 0.25
	back.BorderSizePixel = 0
	back.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = back
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Position = UDim2.fromScale(0.04, 0.18)
	fill.Size = UDim2.fromScale(0.92, 0.64)
	fill.BackgroundColor3 = rgb(110, 220, 90)
	fill.BorderSizePixel = 0
	fill.Parent = back
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0.5, 0)
	fc.Parent = fill
	gui.Parent = adornee
	local lastF = -1
	return {
		gui = gui,
		fill = fill,
		set = function(frac: number, color: Color3?)
			local f = math.clamp(frac, 0, 1)
			if math.abs(f - lastF) > 0.004 then
				lastF = f
				fill.Size = UDim2.fromScale(0.92 * f, 0.64)
			end
			if color then
				fill.BackgroundColor3 = color
			end
		end,
	}
end

return BuildModels
