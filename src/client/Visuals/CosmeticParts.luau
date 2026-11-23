--!strict
-- CosmeticParts (iteration 6, team Preview, client): the part-built cosmetic
-- pieces the showroom (UI/CosmeticPreview) and the icon renderer
-- (scripts/render-cosmetics.luau) draw. Only Instances + datatypes, no services.
--
--   CosmeticParts.hat(parent, head, hatLook) -> Model?
--       The SAME geometry and welds as the server (Services/CosmeticsService
--       buildHat): Config/Cosmetics.HAT_SHAPES scaled to the head, welded to it.
--   CosmeticParts.ribbon(parent, trailLook, n?) -> Ribbon
--       A trail drawn with parts (ViewportFrames draw no Trails): `n` flat
--       segments, gradient color -> color2 and transparency start -> 1 from
--       Config/Cosmetics.TRAIL. ribbon.set(t, sweep) places it: a short arc that
--       sweeps round the pedestal (sweep = true) or a still curl (false).
--   CosmeticParts.tint(model, tintLook?) -> restore()
--       A Highlight cannot draw in a ViewportFrame either: each visible part's
--       colour is blended toward the tint by (1 - C.TINT.fillTransparency), the
--       way the Highlight fill composites in game. restore() puts colours back.
--   CosmeticParts.standIn(colors) -> Model
--       A 10-part elephant for when no hero builder and no lobby statue exist
--       (a Root "Root" at the feet, a "Head"), never in a normal lobby.

local CosmeticParts = {}

CosmeticParts.HEAD_REFERENCE = 1.2 -- C.HAT_SHAPES units are for a head this tall
CosmeticParts.RIBBON_SEGMENTS = 10

local function rgb(c: any, fallback: Color3?): Color3
	if type(c) == "table" and type(c[1]) == "number" then
		return Color3.fromRGB(c[1], c[2] or 0, c[3] or 0)
	end
	return fallback or Color3.new(1, 1, 1)
end
CosmeticParts.rgb = rgb

local function decorPart(part: BasePart, color: Color3)
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Color = color
end

-- Mirrors Services/CosmeticsService buildHat (keep the two in step).
function CosmeticParts.hat(parent: Instance, head: BasePart, look: any, shapes: { [string]: any }): Model?
	if type(look) ~= "table" then
		return nil
	end
	local shape = shapes[look.shape]
	if type(shape) ~= "table" then
		return nil
	end
	local scale = math.clamp(head.Size.Y / CosmeticParts.HEAD_REFERENCE, 0.6, 2.5)
	local top = CFrame.new(0, head.Size.Y / 2, 0)
	local main, accent = rgb(look.color), rgb(look.accent)
	local model = Instance.new("Model")
	model.Name = "Hat_" .. tostring(look.id)
	for i, spec in shape do
		local size = Vector3.new(spec.size[1], spec.size[2], spec.size[3]) * scale
		local rot = spec.rot or { 0, 0, 0 }
		local cf = top
			* CFrame.new(spec.at[1] * scale, spec.at[2] * scale, spec.at[3] * scale)
			* CFrame.Angles(math.rad(rot[1]), math.rad(rot[2]), math.rad(rot[3]))
		local part: BasePart
		if spec.form == "wedge" then
			part = Instance.new("WedgePart")
			part.Size = size
		elseif spec.form == "cyl" then
			local p = Instance.new("Part")
			p.Shape = Enum.PartType.Cylinder
			p.Size = Vector3.new(size.Y, size.X, size.Z) -- a cylinder's axis is X: stand it up
			cf *= CFrame.Angles(0, 0, math.rad(90))
			part = p
		else
			local p = Instance.new("Part")
			p.Size = size
			if spec.form == "ball" then
				local mesh = Instance.new("SpecialMesh")
				mesh.MeshType = Enum.MeshType.Sphere
				mesh.Parent = p
			end
			part = p
		end
		part.Name = "HatPart" .. i
		decorPart(part, if spec.accent then accent else main)
		part.CFrame = head.CFrame * cf
		local weld = Instance.new("Weld")
		weld.Part0 = head
		weld.Part1 = part
		weld.C0 = cf
		weld.Parent = part
		part.Parent = model
	end
	model.Parent = parent
	return model
end

export type Ribbon = {
	model: Model,
	parts: { BasePart },
	set: (t: number, sweep: boolean) -> (),
}

function CosmeticParts.ribbon(parent: Instance, look: any, tuning: any, n: number?): Ribbon
	local count = n or CosmeticParts.RIBBON_SEGMENTS
	local T = if type(tuning) == "table" then tuning else {}
	local half = tonumber(T.halfWidth) or 0.9
	local t0 = tonumber(T.startTransparency) or 0.15
	local c1, c2 = rgb(look and look.color), rgb(look and look.color2)
	local model = Instance.new("Model")
	model.Name = "TrailRibbon"
	local parts: { BasePart } = {}
	for i = 1, count do
		local f = (i - 1) / math.max(1, count - 1)
		local p = Instance.new("Part")
		p.Name = "Seg" .. i
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.CastShadow = false
		p.Material = if (tonumber(T.lightEmission) or 0) > 0.3
			then Enum.Material.Neon
			else Enum.Material.SmoothPlastic
		p.Color = c1:Lerp(c2, f)
		p.Transparency = t0 + (1 - t0) * f * 0.92
		p.Size = Vector3.new(half * 2 * (1 - f * 0.45), 0.08, 0.6)
		p.Parent = model
		parts[i] = p
	end
	model.Parent = parent
	local radius, y = 2.6, 0.12
	local arc = 2.4 -- radians the ribbon covers behind its head
	local function set(t: number, sweep: boolean)
		local head = if sweep then t * 2.2 else 2.3
		local step = arc / math.max(1, count - 1)
		for i, p in parts do
			local a = head - (i - 1) * step
			local pos = Vector3.new(math.cos(a) * radius, y, math.sin(a) * radius)
			local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
			p.CFrame = CFrame.lookAt(pos, pos + tangent)
			p.Size = Vector3.new(p.Size.X, p.Size.Y, step * radius * 1.08)
		end
	end
	set(0, false)
	return { model = model, parts = parts, set = set }
end

function CosmeticParts.tint(model: Instance, look: any, tuning: any): () -> ()
	if type(look) ~= "table" then
		return function() end
	end
	local T = if type(tuning) == "table" then tuning else {}
	local mix = 1 - (tonumber(T.fillTransparency) or 0.55)
	local c = rgb(look.color)
	local saved: { [BasePart]: Color3 } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 0.99 then
			saved[d] = d.Color
			d.Color = d.Color:Lerp(c, mix)
		end
	end
	return function()
		for p, col in saved do
			if p.Parent then
				p.Color = col
			end
		end
		table.clear(saved)
	end
end

-- 10 parts, built at the origin facing -Z, feet at Y = 0.
function CosmeticParts.standIn(body: Color3, accent: Color3): Model
	local m = Instance.new("Model")
	m.Name = "StandIn"
	local function part(name: string, size: Vector3, cf: CFrame, color: Color3, ball: boolean?): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Material = Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if ball then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = p
		end
		p:SetAttribute("BaseColor", color)
		p.Parent = m
		return p
	end
	local root = part("Root", Vector3.new(1, 1, 1), CFrame.new(), Color3.new(1, 1, 1))
	root.Transparency = 1
	m.PrimaryPart = root
	part("Body", Vector3.new(3.4, 2.8, 4.2), CFrame.new(0, 2.6, 0.3), body, true)
	part("Head", Vector3.new(2.2, 2.2, 2.2), CFrame.new(0, 3.6, -1.9), body, true)
	part(
		"EarL",
		Vector3.new(0.3, 1.8, 1.6),
		CFrame.new(-1.3, 3.8, -1.6),
		body:Lerp(Color3.new(1, 0.7, 0.75), 0.3),
		true
	)
	part(
		"EarR",
		Vector3.new(0.3, 1.8, 1.6),
		CFrame.new(1.3, 3.8, -1.6),
		body:Lerp(Color3.new(1, 0.7, 0.75), 0.3),
		true
	)
	part("Trunk", Vector3.new(0.6, 1.8, 0.6), CFrame.new(0, 2.4, -2.9) * CFrame.Angles(0.35, 0, 0), body)
	part("Sash", Vector3.new(3.5, 0.5, 4.3), CFrame.new(0, 2.9, 0.3) * CFrame.Angles(0, 0, 0.5), accent)
	for i, x in { -1, 1 } do
		part("LegF" .. i, Vector3.new(0.9, 1.6, 0.9), CFrame.new(x * 1, 0.8, -0.9), body)
		part("LegB" .. i, Vector3.new(0.9, 1.6, 0.9), CFrame.new(x * 1, 0.8, 1.4), body)
	end
	m.WorldPivot = CFrame.new()
	return m
end

return CosmeticParts
