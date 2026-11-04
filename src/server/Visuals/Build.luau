--!strict
-- Build (R4 Graphics): tiny part-building DSL shared by ArenaBuilder, LobbyWorld,
-- BotModel and HeroDecor. Everything is a real Roblox primitive:
--
--   Build.block(parent, size, cf, color, material?, o?)      Part (Block)
--   Build.ball(parent, d, cf, color, material?, o?)          Part (Ball, always uniform)
--   Build.egg(parent, size, cf, color, material?, o?)        Block + SpecialMesh Sphere = ellipsoid
--   Build.cyl(parent, length, d, cf, color, material?, o?)   Part (Cylinder, axis = local X)
--   Build.ucyl(parent, height, d, cf, color, material?, o?)  upright cylinder (axis = local Y of cf)
--   Build.wedge(parent, size, cf, color, material?, o?)      WedgePart (slope faces -Z, tall face +Z)
--   Build.corner(parent, size, cf, color, material?, o?)     CornerWedgePart
--   Build.light(part, color, range, brightness, shadows?)    PointLight
--   Build.emitter(parent, preset)                            ParticleEmitter from a plain table
--   Build.tag(inst, tag)                                     CollectionService tag (Instance:AddTag)
--
-- Defaults: Anchored, CanCollide/CanQuery/CanTouch false, smooth surfaces,
-- CastShadow true, SmoothPlastic. o.collide = true makes the part solid (and
-- queryable). o.shadow = false, o.transparency, o.name, o.reflectance.
-- A Roblox Ball is always a sphere and a Cylinder always has Y == Z, so the
-- helpers take one diameter and never pass a non-uniform size the engine
-- would silently fix up.

local Build = {}

export type Opts = {
	name: string?,
	collide: boolean?,
	shadow: boolean?,
	transparency: number?,
	reflectance: number?,
	anchored: boolean?,
}

-- Built-in particle textures (rbxasset://textures/particles/*). These ship with
-- every Roblox client: the legacy Sparkles/Fire/Smoke/Explosion/ForceField
-- objects use them, and public open-source Roblox code references exactly
-- these paths. Anything else falls back to "" (the emitter's default texture).
Build.TEX = {
	sparkles = "rbxasset://textures/particles/sparkles_main.dds",
	fire = "rbxasset://textures/particles/fire_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	implosion = "rbxasset://textures/particles/explosion01_implosion_main.dds",
	core = "rbxasset://textures/particles/explosion01_core_main.dds",
	shockwave = "rbxasset://textures/particles/explosion01_shockwave_main.dds",
	vortex = "rbxasset://textures/particles/forcefield_vortex_main.dds",
}

local function finish(p: BasePart, parent: Instance?, color: Color3, material: Enum.Material?, o: Opts?)
	p.Anchored = if o and o.anchored == false then false else true
	local solid = o ~= nil and o.collide == true
	p.CanCollide = solid
	p.CanQuery = solid
	p.CanTouch = false
	p.CastShadow = not (o and o.shadow == false)
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if o then
		if o.name then
			p.Name = o.name
		end
		if o.transparency then
			p.Transparency = o.transparency
		end
		if o.reflectance then
			p.Reflectance = o.reflectance
		end
	end
	if parent then
		p.Parent = parent
	end
end

local function pos(v: number): number
	return math.max(0.05, v)
end

function Build.block(
	parent: Instance?,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	o: Opts?
): Part
	local p = Instance.new("Part")
	p.Name = "Block"
	p.Size = Vector3.new(pos(size.X), pos(size.Y), pos(size.Z))
	p.CFrame = cf
	finish(p, parent, color, material, o)
	return p
end

function Build.ball(
	parent: Instance?,
	d: number,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	o: Opts?
): Part
	local p = Instance.new("Part")
	p.Name = "Ball"
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.one * pos(d)
	p.CFrame = cf
	finish(p, parent, color, material, o)
	return p
end

-- Ellipsoid: a Block with a Sphere SpecialMesh that scales to the part's size.
-- (Decor only: collisions stay box-shaped.)
function Build.egg(
	parent: Instance?,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	o: Opts?
): Part
	local p = Instance.new("Part")
	p.Name = "Egg"
	p.Size = Vector3.new(pos(size.X), pos(size.Y), pos(size.Z))
	p.CFrame = cf
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	finish(p, parent, color, material, o)
	return p
end

function Build.cyl(
	parent: Instance?,
	length: number,
	d: number,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	o: Opts?
): Part
	local p = Instance.new("Part")
	p.Name = "Cylinder"
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(pos(length), pos(d), pos(d))
	p.CFrame = cf
	finish(p, parent, color, material, o)
	return p
end

local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))
Build.UPRIGHT = UPRIGHT

-- Upright cylinder centred on cf (its axis is cf's up vector).
function Build.ucyl(
	parent: Instance?,
	height: number,
	d: number,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	o: Opts?
): Part
	return Build.cyl(parent, height, d, cf * UPRIGHT, color, material, o)
end

function Build.wedge(
	parent: Instance?,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	o: Opts?
): WedgePart
	local p = Instance.new("WedgePart")
	p.Name = "Wedge"
	p.Size = Vector3.new(pos(size.X), pos(size.Y), pos(size.Z))
	p.CFrame = cf
	finish(p, parent, color, material, o)
	return p
end

function Build.corner(
	parent: Instance?,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	o: Opts?
): CornerWedgePart
	local p = Instance.new("CornerWedgePart")
	p.Name = "Corner"
	p.Size = Vector3.new(pos(size.X), pos(size.Y), pos(size.Z))
	p.CFrame = cf
	finish(p, parent, color, material, o)
	return p
end

function Build.light(
	part: Instance,
	color: Color3,
	range: number,
	brightness: number,
	shadows: boolean?
): PointLight
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = math.clamp(range, 0, 60)
	l.Brightness = brightness
	l.Shadows = shadows == true
	l.Parent = part
	return l
end

function Build.tag(inst: Instance, tag: string)
	inst:AddTag(tag)
end

-- Number / colour sequence shorthands.
function Build.ns(...: number): NumberSequence
	local v = { ... }
	if #v == 1 then
		return NumberSequence.new(v[1])
	end
	local kps = {}
	for i, x in v do
		table.insert(kps, NumberSequenceKeypoint.new((i - 1) / (#v - 1), x))
	end
	return NumberSequence.new(kps)
end

function Build.cs(a: Color3, b: Color3?): ColorSequence
	if b then
		return ColorSequence.new(a, b)
	end
	return ColorSequence.new(a)
end

export type EmitterPreset = {
	name: string?,
	texture: string?,
	color: ColorSequence?,
	size: NumberSequence?,
	transparency: NumberSequence?,
	lifetime: NumberRange?,
	rate: number?,
	speed: NumberRange?,
	spread: Vector2?,
	accel: Vector3?,
	drag: number?,
	rotSpeed: NumberRange?,
	rotation: NumberRange?,
	lightEmission: number?,
	lightInfluence: number?,
	brightness: number?,
	direction: Enum.NormalId?,
	shape: Enum.ParticleEmitterShape?,
	shapeStyle: Enum.ParticleEmitterShapeStyle?,
	shapeInOut: Enum.ParticleEmitterShapeInOut?,
	orientation: Enum.ParticleOrientation?,
	zOffset: number?,
	locked: boolean?,
	enabled: boolean?,
	squash: NumberSequence?,
}

function Build.emitter(parent: Instance, p: EmitterPreset): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = p.name or "Emitter"
	e.Texture = p.texture or ""
	if p.color then
		e.Color = p.color
	end
	if p.size then
		e.Size = p.size
	end
	if p.transparency then
		e.Transparency = p.transparency
	end
	e.Lifetime = p.lifetime or NumberRange.new(1, 2)
	e.Rate = p.rate or 5
	e.Speed = p.speed or NumberRange.new(1, 3)
	e.SpreadAngle = p.spread or Vector2.new(15, 15)
	e.Acceleration = p.accel or Vector3.zero
	e.Drag = p.drag or 0
	e.RotSpeed = p.rotSpeed or NumberRange.new(0, 0)
	e.Rotation = p.rotation or NumberRange.new(0, 360)
	e.LightEmission = p.lightEmission or 0
	e.LightInfluence = p.lightInfluence or 1
	e.Brightness = p.brightness or 1
	e.EmissionDirection = p.direction or Enum.NormalId.Top
	if p.shape then
		e.Shape = p.shape
	end
	if p.shapeStyle then
		e.ShapeStyle = p.shapeStyle
	end
	if p.shapeInOut then
		e.ShapeInOut = p.shapeInOut
	end
	if p.orientation then
		e.Orientation = p.orientation
	end
	if p.squash then
		e.Squash = p.squash
	end
	e.ZOffset = p.zOffset or 0
	e.LockedToPart = p.locked == true
	e.Enabled = p.enabled ~= false
	e.Parent = parent
	return e
end

-- Colour helpers.
function Build.rgb(t: any, fallback: Color3): Color3
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

function Build.shade(c: Color3, f: number): Color3
	if f >= 0 then
		return c:Lerp(Color3.new(1, 1, 1), f)
	end
	return c:Lerp(Color3.new(0, 0, 0), -f)
end

-- A fresh Model parented to `parent`.
function Build.model(parent: Instance?, name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	if parent then
		m.Parent = parent
	end
	return m
end

return Build
