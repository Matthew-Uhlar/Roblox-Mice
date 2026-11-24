--!strict
-- MeshSuit (iteration 8, team Mesh): the procedural meshes on the elephant
-- heroes (BotModel: bots, the players' Herd Suit, lobby statues, and the
-- client's cosmetic preview through ReplicatedStorage.HeroVisuals).
--
--   MeshSuit.body(model) -> boolean            hero_elephant pieces (Bone_* rig)
--   MeshSuit.weapon(model, grip, s, classId, parts) -> { BasePart }
--                                               wpn_<classId> in ClassGear grip space
--   MeshSuit.TAG                                CollectionService tag on models
--                                               that carry both looks
--
-- The mesh pieces are ADDED next to the part body: every replaced part gets
-- attribute MeshSet = "parts", every mesh piece MeshSet = "mesh", and the model
-- the tag TrunkfallMeshSet. Each client shows one set (Visuals/MeshModels
-- .applySets with LocalTransparencyModifier): the player setting Models:
-- Classic keeps the parts. Pieces carry the rig attribute "Bone" (piece name =
-- BotModel bone) and are welded by BotModel's finish() like any part, so
-- BotAnimator poses them; class gear and Ascension looks keep their attach
-- points (same proportions as the part body). Nothing is added when
-- Shared.Config.Visuals.USE_MESHES is false or the asset is not loaded
-- (ReplicatedStorage.TrunkfallAssets.<name>, server Visuals/AssetLoader).
-- Client-safe: reads ReplicatedStorage only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local MeshSuit = {}

MeshSuit.TAG = "TrunkfallMeshSet"
MeshSuit.FOLDER = "TrunkfallAssets"
-- Part-body names the hero_elephant mesh replaces (BotModel.body)
MeshSuit.BODY_PARTS = {
	Leg = true,
	Foot = true,
	Toe = true,
	Body = true,
	Belly = true,
	Tail = true,
	TailTuft = true,
	Head = true,
	Cheeks = true,
	Eye = true,
	Pupil = true,
	Glint = true,
	Blush = true,
	Brow = true,
	Tusk = true,
	TuskTip = true,
	Ear = true,
	EarInner = true,
	Trunk = true,
	TrunkTip = true,
}

local function config(name: string): any
	local ok, mod = pcall(function()
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		local cfg = shared and shared:FindFirstChild("Config")
		local inst = cfg and cfg:FindFirstChild(name)
		return if inst and inst:IsA("ModuleScript") then require(inst) :: any else nil
	end)
	return if ok and type(mod) == "table" then mod else nil
end

function MeshSuit.enabled(): boolean
	local v = config("Visuals")
	return not (v and v.USE_MESHES == false)
end

local function v3(a: any): Vector3
	return if type(a) == "table" then Vector3.new(a[1] or 0, a[2] or 0, a[3] or 0) else Vector3.zero
end

-- Clones `name`'s pieces: { [pieceName] = { part, center (authored), size, bone } }, or nil.
local function pieces(name: string): { [string]: any }?
	if not MeshSuit.enabled() then
		return nil
	end
	local data = config("MeshData")
	local rig = data and data[name]
	local folder = ReplicatedStorage:FindFirstChild(MeshSuit.FOLDER)
	local template = folder and folder:FindFirstChild(name)
	if type(rig) ~= "table" or not template then
		return nil
	end
	local ok, clone = pcall(function()
		return template:Clone()
	end)
	if not ok or typeof(clone) ~= "Instance" then
		return nil
	end
	local byName: { [string]: BasePart } = {}
	for _, d in (clone :: Instance):GetDescendants() do
		if d:IsA("BasePart") then
			local n = d.Name
			local tail = string.match(n, "[_%.%-]([%a%d]+)$")
			byName[n] = d
			if tail and not byName[tail] then
				byName[tail] = d
			end
		end
	end
	local shift = v3(rig.shift)
	local out = {}
	for _, pc in rig.pieces do
		local p = byName[pc.name]
		if not p then
			if pc.cond == nil then
				(clone :: Instance):Destroy()
				return nil
			end
			continue
		end
		p.Parent = nil
		out[pc.name] = {
			part = p,
			center = v3(pc.center) - shift,
			size = v3(pc.size),
			bone = pc.bone or pc.name,
			neon = pc.neon == true,
		}
	end
	(clone :: Instance):Destroy()
	return out
end

local function setup(p: BasePart, name: string, parent: Instance)
	p.Name = "Mesh_" .. name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = true
	if p:IsA("MeshPart") then
		-- (the importer's textured look; Neon accents stay flat)
		p.Material = Enum.Material.SmoothPlastic
	end
	p:SetAttribute("MeshSet", "mesh")
	p.Parent = parent
end

-- Adds the hero_elephant pieces to a BotModel body (model space, scale 1, before
-- BotModel scales and welds it). Returns true when the meshes were added.
function MeshSuit.body(model: Model): boolean
	local set = pieces("hero_elephant")
	if not set then
		return false
	end
	for name, e in set do
		local p = e.part :: BasePart
		p.Size = e.size
		p.CFrame = CFrame.new(e.center)
		-- the trunk piece rides the first trunk bone
		p:SetAttribute("Bone", e.bone)
		setup(p, name, model)
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and MeshSuit.BODY_PARTS[d.Name] and d:GetAttribute("MeshSet") == nil then
			d:SetAttribute("MeshSet", "parts")
		end
	end
	CollectionService:AddTag(model, MeshSuit.TAG)
	return true
end

-- The class weapon mesh in ClassGear's grip space (grip CFrame, size s); the
-- part weapon (`parts`) becomes the Classic set. Returns the mesh pieces (the
-- caller gives them the weapon's bone), or {} when there is no mesh.
function MeshSuit.weapon(
	model: Model,
	grip: CFrame,
	s: number,
	classId: string,
	parts: { BasePart }
): { BasePart }
	local set = pieces("wpn_" .. classId)
	if not set then
		return {}
	end
	local out = {}
	for name, e in set do
		local p = e.part :: BasePart
		p.Size = e.size * s
		p.CFrame = grip * CFrame.new(e.center * s)
		setup(p, "Weapon_" .. name, model)
		if e.neon then
			p.Material = Enum.Material.Neon
			pcall(function()
				(p :: any).TextureID = ""
			end)
		end
		table.insert(out, p)
	end
	for _, p in parts do
		p:SetAttribute("MeshSet", "parts")
	end
	CollectionService:AddTag(model, MeshSuit.TAG)
	return out
end

return MeshSuit
