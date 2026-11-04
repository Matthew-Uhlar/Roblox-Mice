--!strict
-- Spec (R4 Graphics, client): part SPECS for the pooled enemy / boss models.
-- MouseModels and BossModels describe a model as a list of specs; HordeRenderer
-- instantiates each spec once per pooled visual and moves the parts every frame
-- with one workspace:BulkMoveTo. Specs only use datatypes (no services), so the
-- preview tool can read them too.
--
--   spec = { shape = "Block"|"Ball"|"Cylinder"|"Wedge"|"CornerWedge"|"Egg",
--            size, offset (CFrame in model space; ground at Y = 0, facing -Z),
--            color, material, transparency?, tint? (recoloured by hit / stun /
--            elite flashes), cond? ("elite": only shown on elites),
--            anim? = { kind, amp, freq, phase, pivot? } }
--   anim kinds (HordeRenderer.animate):
--     "swing"  rotate about the pivot's X axis (legs, arms)  amp in radians
--     "sway"   rotate about the pivot's Y axis (tails, heads)
--     "roll"   rotate about the pivot's Z axis (ears, wings)
--     "spin"   continuous rotation about the pivot's Y axis   amp = rad/s
--     "bob"    move up and down                               amp in studs
--     "pulse"  transparency flicker (fuse sparks)             amp 0..1
--   pivot (CFrame, model space): the joint; offset is still the rest pose.

local Spec = {}

export type Anim = { kind: string, amp: number, freq: number, phase: number?, pivot: CFrame? }
export type PartSpec = {
	shape: string,
	size: Vector3,
	offset: CFrame,
	color: Color3,
	material: Enum.Material?,
	transparency: number?,
	tint: boolean?,
	cond: string?,
	anim: Anim?,
}
export type List = { PartSpec }

local function add(list: List, shape: string, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?, x: { [string]: any }?): PartSpec
	local s: PartSpec = {
		shape = shape,
		size = size,
		offset = cf,
		color = color,
		material = mat or Enum.Material.SmoothPlastic,
	}
	if x then
		s.transparency = x.t
		s.tint = x.tint
		s.cond = x.cond
		s.anim = x.anim
	end
	table.insert(list, s)
	return s
end

function Spec.block(l: List, size: Vector3, cf: CFrame, c: Color3, m: Enum.Material?, x: { [string]: any }?): PartSpec
	return add(l, "Block", size, cf, c, m, x)
end
function Spec.ball(l: List, d: number, cf: CFrame, c: Color3, m: Enum.Material?, x: { [string]: any }?): PartSpec
	return add(l, "Ball", Vector3.one * d, cf, c, m, x)
end
function Spec.egg(l: List, size: Vector3, cf: CFrame, c: Color3, m: Enum.Material?, x: { [string]: any }?): PartSpec
	return add(l, "Egg", size, cf, c, m, x)
end
-- Cylinder along the local X axis (Roblox convention).
function Spec.cyl(l: List, len: number, d: number, cf: CFrame, c: Color3, m: Enum.Material?, x: { [string]: any }?): PartSpec
	return add(l, "Cylinder", Vector3.new(len, d, d), cf, c, m, x)
end
local UP = CFrame.Angles(0, 0, math.rad(90))
-- Upright cylinder centred on cf (axis = cf's Y).
function Spec.ucyl(l: List, h: number, d: number, cf: CFrame, c: Color3, m: Enum.Material?, x: { [string]: any }?): PartSpec
	return add(l, "Cylinder", Vector3.new(h, d, d), cf * UP, c, m, x)
end
function Spec.wedge(l: List, size: Vector3, cf: CFrame, c: Color3, m: Enum.Material?, x: { [string]: any }?): PartSpec
	return add(l, "Wedge", size, cf, c, m, x)
end
function Spec.corner(l: List, size: Vector3, cf: CFrame, c: Color3, m: Enum.Material?, x: { [string]: any }?): PartSpec
	return add(l, "CornerWedge", size, cf, c, m, x)
end

-- Animation shorthands.
function Spec.swing(amp: number, freq: number, phase: number, pivot: CFrame): Anim
	return { kind = "swing", amp = amp, freq = freq, phase = phase, pivot = pivot }
end
function Spec.sway(amp: number, freq: number, phase: number, pivot: CFrame): Anim
	return { kind = "sway", amp = amp, freq = freq, phase = phase, pivot = pivot }
end
function Spec.roll(amp: number, freq: number, phase: number, pivot: CFrame): Anim
	return { kind = "roll", amp = amp, freq = freq, phase = phase, pivot = pivot }
end
function Spec.spin(speed: number, pivot: CFrame): Anim
	return { kind = "spin", amp = speed, freq = 1, phase = 0, pivot = pivot }
end
function Spec.bob(amp: number, freq: number, phase: number?): Anim
	return { kind = "bob", amp = amp, freq = freq, phase = phase or 0 }
end
function Spec.pulse(amp: number, freq: number): Anim
	return { kind = "pulse", amp = amp, freq = freq, phase = 0 }
end

-- Pose of an animated spec at time t (model space). `moving` (0..1) scales the
-- walk channels (swing / sway on legs) so idle enemies stand still.
function Spec.pose(s: PartSpec, t: number, moving: number): CFrame
	local a = s.anim
	if not a then
		return s.offset
	end
	local w = math.sin(t * a.freq + (a.phase or 0))
	local k = a.kind
	if k == "bob" then
		return s.offset + Vector3.new(0, w * a.amp, 0)
	elseif k == "pulse" then
		return s.offset
	end
	local pivot = a.pivot or s.offset
	local rel = pivot:ToObjectSpace(s.offset)
	local rot: CFrame
	if k == "swing" then
		rot = CFrame.Angles(w * a.amp * moving, 0, 0)
	elseif k == "sway" then
		rot = CFrame.Angles(0, w * a.amp, 0)
	elseif k == "roll" then
		rot = CFrame.Angles(0, 0, w * a.amp)
	elseif k == "spin" then
		rot = CFrame.Angles(0, t * a.amp, 0)
	else
		return s.offset
	end
	return pivot * rot * rel
end

-- Creates the Instance for a spec (anchored, non-colliding, parked).
function Spec.instantiate(s: PartSpec, parent: Instance, park: CFrame): BasePart
	local p: BasePart
	if s.shape == "Wedge" then
		p = Instance.new("WedgePart")
	elseif s.shape == "CornerWedge" then
		p = Instance.new("CornerWedgePart")
	else
		local pp = Instance.new("Part")
		if s.shape == "Ball" then
			pp.Shape = Enum.PartType.Ball
		elseif s.shape == "Cylinder" then
			pp.Shape = Enum.PartType.Cylinder
		end
		p = pp
	end
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = s.size
	p.Color = s.color
	p.Material = s.material or Enum.Material.SmoothPlastic
	p.Transparency = s.transparency or 0
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if s.shape == "Egg" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = p
	end
	p.CFrame = park
	p.Parent = parent
	return p
end

-- Uniformly scales a spec list about the model origin.
function Spec.scaled(list: List, k: number): List
	local out = {}
	for _, s in list do
		local c = table.clone(s)
		c.size = s.size * k
		local o = s.offset
		c.offset = o - o.Position + o.Position * k
		if s.anim then
			local a = table.clone(s.anim)
			if a.pivot then
				local pv = a.pivot
				a.pivot = pv - pv.Position + pv.Position * k
			end
			if a.kind == "bob" then
				a.amp *= k
			end
			c.anim = a
		end
		table.insert(out, c)
	end
	return out
end

return Spec
