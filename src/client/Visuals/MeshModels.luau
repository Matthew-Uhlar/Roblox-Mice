--!strict
-- MeshModels (iter7 team Mesh, client): turns an imported procedural mesh model
-- (scripts/make-meshes.py -> upload -> server Visuals/AssetLoader ->
-- ReplicatedStorage.TrunkfallAssets.<name>) into posable pieces for HordeRenderer.
--
--   MeshModels.info(name) -> rig?            Visuals/MeshData (generated) entry
--   MeshModels.build(template, name, radius, parent, bones) -> Built?
--   MeshModels.paint(built, i, color?)       color = flat tint, nil = textured
--
-- Every creature is exported as one MeshPart per animation piece, named after
-- the Visuals/Rig bone it rides (body, head, earL/R, tail, legFL/FR/BL/BR, armL/R,
-- weapon, cape, ...) or after its boss channel (wheel, wingL/R, extra, ...).
--
--  * Scale: the glTF extras (Radius) do not survive the importer, so the scale
--    reference is MeshData[name].radius (the hitbox radius the model was
--    designed at): s = radius / rig.radius. Each piece's Size is SET to its
--    authored bounds size * s, so whatever unit scale the importer applied
--    does not matter.
--  * Pivot: the importer re-centres every MeshPart on its own bounds, so a
--    piece is placed by its authored bounds centre (MeshData center * s), not
--    by the imported CFrames. Only the imported rotation is kept, relative to
--    the body piece (undoes a whole-model rotation by the importer).
--  * Tint (hit flash / elite / stun / telegraph / enrage): MeshPart.Color does
--    not show through a texture, so a tinted piece is drawn FLAT: TextureID is
--    cleared (and a SurfaceAppearance, if the importer made one, is unparented)
--    and Color = the piece's dominant palette colour lerped to the state colour
--    (HordeRenderer.stateColor). Back to state 0 the texture is restored. Writes
--    happen only when the colour state changes. Neon accents (fuse spark, elite
--    crown, glowing eyes) are flat Neon pieces that never take the tint.
--  * Missing pieces (an old single-mesh upload, a renamed node): build returns
--    nil and the renderer keeps its part model.

local Visuals = script.Parent

local function optional(name: string): any
	local inst = Visuals:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		if ok and type(mod) == "table" then
			return mod
		end
	end
	return nil
end

local Rig = optional("Rig")
-- iter8: the rig table lives in Shared.Config.MeshData (plain numbers, shared
-- with the server's Visuals/MeshSuit); converted to Vector3 / Color3 on first use
local rawData: any = nil
local function data(): any
	if rawData == nil then
		local ok, mod = pcall(function()
			local RS = game:GetService("ReplicatedStorage")
			local shared = RS:FindFirstChild("Shared")
			local config = shared and shared:FindFirstChild("Config")
			local inst = config and config:FindFirstChild("MeshData")
			return if inst and inst:IsA("ModuleScript") then require(inst) :: any else nil
		end)
		rawData = if ok and type(mod) == "table" then mod else {}
	end
	return rawData
end
local function v3(a: any): Vector3
	return if type(a) == "table" then Vector3.new(a[1] or 0, a[2] or 0, a[3] or 0) else Vector3.zero
end
local function c3(a: any): Color3
	return if type(a) == "table" then Color3.fromRGB(a[1] or 200, a[2] or 200, a[3] or 200) else Color3.new(0.8, 0.8, 0.8)
end
local converted: { [string]: any } = {}

local MeshModels = {}

export type Built = {
	parts: { BasePart },
	specs: { any },
	bones: { [string]: any }?,
	colors: { Color3 },
	tint: { boolean },
	tex: { string },
	sa: { Instance? },
	flat: { boolean },
	neon: { boolean },
	animated: boolean,
}

local warned: { [string]: boolean } = {}

function MeshModels.info(name: string): any
	local c = converted[name]
	if c ~= nil then
		return c or nil
	end
	local e = data()[name]
	if type(e) ~= "table" or type(e.pieces) ~= "table" then
		converted[name] = false
		return nil
	end
	local pieces = {}
	for i, pc in e.pieces do
		pieces[i] = {
			name = pc.name,
			center = v3(pc.center),
			size = v3(pc.size),
			joint = v3(pc.joint),
			color = c3(pc.color),
			bone = pc.bone,
			parent = pc.parent,
			cond = pc.cond,
			anim = pc.anim,
			rot = pc.rot,
			neon = pc.neon,
		}
	end
	c = {
		kind = e.kind,
		radius = tonumber(e.radius) or 1,
		size = v3(e.size),
		shift = v3(e.shift),
		pieces = pieces,
	}
	converted[name] = c
	return c
end

-- iter8: the safety switches every mesh user honours: Shared.Config.Visuals
-- .USE_MESHES (live kill switch) and the player setting models = "classic".
local stateMod: any = nil
function MeshModels.allowed(): boolean
	local ok, off = pcall(function()
		local RS = game:GetService("ReplicatedStorage")
		local config = RS:FindFirstChild("Shared") and RS.Shared:FindFirstChild("Config")
		local inst = config and config:FindFirstChild("Visuals")
		local cfg = if inst and inst:IsA("ModuleScript") then require(inst) :: any else nil
		return type(cfg) == "table" and cfg.USE_MESHES == false
	end)
	if ok and off then
		return false
	end
	if stateMod == nil then
		local okS, st = pcall(function()
			local controllers = Visuals.Parent and Visuals.Parent:FindFirstChild("Controllers")
			local inst = controllers and controllers:FindFirstChild("State")
			return if inst and inst:IsA("ModuleScript") then require(inst) :: any else nil
		end)
		stateMod = if okS and type(st) == "table" then st else false
	end
	if stateMod then
		local okG, g = pcall(stateMod.gfx)
		if okG and type(g) == "table" and g.models == "classic" then
			return false
		end
	end
	return true
end

-- iter8: the loaded template for `name` (ReplicatedStorage.TrunkfallAssets), or nil.
function MeshModels.template(name: string): Instance?
	local inst = Visuals:FindFirstChild("Assets")
	if inst and inst:IsA("ModuleScript") then
		local ok, Assets = pcall(require, inst)
		if ok and type(Assets) == "table" then
			return (Assets :: any).template(name)
		end
	end
	return nil
end

local function pieceName(n: string, want: { [string]: boolean }): string?
	if want[n] then
		return n
	end
	-- tolerate importer prefixes ("mouse_mouse_body", "Model.body", "body.001")
	local tail = string.match(n, "[_%.%-]([%a%d]+)$")
	if tail and want[tail] then
		return tail
	end
	local head = string.match(n, "^([%a%d]+)[%.%-_]%d+$")
	if head and want[head] then
		return head
	end
	return nil
end

local function angles(rot: any): CFrame
	if type(rot) == "table" then
		return CFrame.Angles(math.rad(rot[1] or 0), math.rad(rot[2] or 0), math.rad(rot[3] or 0))
	end
	return CFrame.identity
end

local function readTexture(p: BasePart): string
	local ok, v = pcall(function()
		return (p :: any).TextureID
	end)
	return if ok and type(v) == "string" then v else ""
end

local function setTexture(p: BasePart, id: string)
	pcall(function()
		(p :: any).TextureID = id
	end)
end

-- Clones `template` and returns its pieces posed for a hitbox `radius`, or nil
-- (no rig for `name`, or the model is missing a piece). `bones`: true builds
-- the Visuals/Rig skeleton from the piece joints (mice, champions); false
-- gives every piece its anim channel instead (bosses).
function MeshModels.build(
	template: Instance,
	name: string,
	radius: number,
	parent: Instance,
	bones: boolean
): Built?
	local rig = MeshModels.info(name)
	if not rig then
		return nil
	end
	local ok, clone = pcall(function()
		return template:Clone()
	end)
	if not ok or typeof(clone) ~= "Instance" then
		return nil
	end
	local model = clone :: Instance
	local want: { [string]: boolean } = {}
	for _, pc in rig.pieces do
		want[pc.name] = true
	end
	local found: { [string]: BasePart } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local pn = pieceName(d.Name, want)
			if pn and not found[pn] then
				found[pn] = d
			end
		end
	end
	for _, pc in rig.pieces do
		if not found[pc.name] and pc.cond == nil then
			if not warned[name] then
				warned[name] = true
				warn("[MeshModels] " .. name .. " has no piece '" .. pc.name .. "'; using the part model")
			end
			model:Destroy()
			return nil
		end
	end
	local s = radius / math.max(0.01, tonumber(rig.radius) or radius)
	-- whole-model rotation applied by the importer (normally identity)
	local pivot = if model:IsA("Model") then model:GetPivot() else CFrame.identity
	local bodyPart = found.body
	local r0 = if bodyPart then pivot:ToObjectSpace(bodyPart.CFrame).Rotation else CFrame.identity
	local r0inv = r0:Inverse()
	local out: Built = {
		parts = {},
		specs = {},
		bones = nil,
		colors = {},
		tint = {},
		tex = {},
		sa = {},
		flat = {},
		neon = {},
		animated = false,
	}
	local skeleton: { [string]: any } = {}
	local anyBone = false
	for _, pc in rig.pieces do
		local p = found[pc.name]
		if not p then
			continue
		end
		local rel = r0inv * pivot:ToObjectSpace(p.CFrame).Rotation
		local size = (pc.size :: Vector3) * s
		local joint = CFrame.new((pc.joint :: Vector3) * s) * angles(pc.rot)
		local boneName: string? = pc.bone
		if boneName == nil and Rig and Rig.INDEX and Rig.INDEX[pc.name] then
			boneName = pc.name
		end
		local spec: { [string]: any } = {
			offset = CFrame.new((pc.center :: Vector3) * s) * rel,
			size = size,
			color = pc.color,
			tint = not pc.neon,
			cond = pc.cond,
			bone = if bones then boneName else nil,
			mesh = pc.name,
		}
		if type(pc.anim) == "table" and (not bones or boneName == nil or pc.anim.kind == "pulse") then
			local a = pc.anim
			spec.anim = {
				kind = a.kind,
				amp = if a.kind == "bob" then a.amp * s else a.amp,
				freq = a.freq,
				phase = a.phase,
				pivot = joint,
			}
			out.animated = true
		end
		if bones and boneName == pc.name then
			skeleton[pc.name] = { pivot = joint, parent = pc.parent }
			anyBone = true
		end
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Size = size
		local i = #out.parts + 1
		out.parts[i] = p
		out.specs[i] = spec
		out.colors[i] = pc.color
		out.tint[i] = not pc.neon
		out.tex[i] = readTexture(p)
		out.sa[i] = p:FindFirstChildOfClass("SurfaceAppearance")
		out.flat[i] = false
		out.neon[i] = pc.neon == true
		if pc.neon then
			p.Material = Enum.Material.Neon
			MeshModels.paint(out, i, pc.color)
		end
		p.Parent = parent
	end
	model:Destroy() -- the unmatched leftovers go with it
	if #out.parts == 0 then
		return nil
	end
	if bones and anyBone then
		out.bones = skeleton
	end
	return out
end

-- iter8: a static (or simply posed) mesh in its AUTHORED frame (weapons in
-- grip space, props / landmarks / builds standing on Y = 0): every piece as an
-- anchored, non-colliding part with its offset from that origin. `scale` is a
-- number or a per-axis Vector3 (the barricade stretches along X). nil when the
-- meshes are switched off, the template is missing or incomplete.
export type Prop = {
	parts: { BasePart },
	offsets: { CFrame },
	names: { string },
	joints: { CFrame },
	info: any,
	built: Built,
}
function MeshModels.prop(name: string, scale: number | Vector3, parent: Instance): Prop?
	if not MeshModels.allowed() then
		return nil
	end
	local rig = MeshModels.info(name)
	local template = if rig then MeshModels.template(name) else nil
	if not rig or not template then
		return nil
	end
	local sv = if typeof(scale) == "Vector3" then scale else Vector3.one * (scale :: number)
	-- build at radius = rig.radius (s = 1), then rescale per axis
	local b = MeshModels.build(template, name, rig.radius, parent, false)
	if not b then
		return nil
	end
	local out: Prop = { parts = b.parts, offsets = {}, names = {}, joints = {}, info = rig, built = b }
	local byName: { [string]: any } = {}
	for _, pc in rig.pieces do
		byName[pc.name] = pc
	end
	for i, p in b.parts do
		local pc = byName[b.specs[i].mesh]
		local rel = b.specs[i].offset.Rotation
		out.offsets[i] = CFrame.new((pc.center - rig.shift) * sv) * rel
		out.joints[i] = CFrame.new((pc.joint - rig.shift) * sv)
		out.names[i] = pc.name
		p.Size = pc.size * sv
		b.specs[i].size = p.Size
	end
	return out
end

-- color: a flat tint (texture off), or nil for the textured look.
function MeshModels.paint(b: Built, i: number, color: Color3?)
	local p = b.parts[i]
	if not p then
		return
	end
	if color then
		if not b.flat[i] then
			b.flat[i] = true
			setTexture(p, "")
			local sa = b.sa[i]
			if sa then
				pcall(function()
					sa.Parent = nil
				end)
			end
		end
		p.Color = color
	elseif b.flat[i] and not b.neon[i] then
		b.flat[i] = false
		setTexture(p, b.tex[i])
		local sa = b.sa[i]
		if sa then
			pcall(function()
				sa.Parent = p
			end)
		end
		p.Color = b.colors[i]
	end
end

return MeshModels
