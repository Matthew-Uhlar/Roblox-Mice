--!strict
-- MeshDress (iteration 8, team Mesh, client): procedural meshes on the server's
-- part-built world objects, streamed near the camera (DetailStreamer.step calls
-- MeshDress.step every frame).
--
--   * landmarks: every arena obstacle (Arena.Obstacles: tree, pine, palm,
--     jungle_tree, dead_tree, mushroom, rock, snow_rock, ice, crystal, lava_rock,
--     coral, moon_rock, wedge, pillar, mesa; full or "_lite") -> lm_<kind>,
--     scaled by its Radius attribute: the per-biome kit (rocks, trees, ruins);
--   * props: Economy stalls / class stall / Big Cheese Altar / Swap Stand
--     (attribute Kind) -> prop_stall / prop_class_stall / prop_altar / prop_swap;
--     totem POIs -> prop_totem; objective POIs (caravan, beacon, rescue_cage,
--     miniboss_camp) -> obj_<id>; fitted to the part model's bounds, facing the
--     arena centre.
-- A dressed object hides its non-Neon parts locally (LocalTransparencyModifier),
-- so Neon state accents (lit beacons, totem crests), lights, prompts and labels
-- stay; collisions are the server's and never change. At most MAX meshes at a
-- time (the nearest within VIEW; kept until VIEW + SLACK and rank MAX + MAX_SLACK
-- so the edge does not churn), at most BUILDS new ones per step (no hitch on a
-- stage load or camera jump), released props parked in a per-mesh pool; all
-- local: the server part budget (MapBudget) is untouched. Off on low-spec
-- devices (like DetailStreamer). Dressed trees' mesh canopies are faded by
-- DetailLevel.fadeCanopies (MeshDress.canopies). Nothing happens when a mesh is missing, Config/Visuals
-- .USE_MESHES is false or the player picked Models: Classic (MeshModels.allowed).

local MeshDress = {}

MeshDress.VIEW = 150
MeshDress.SLACK = 20 -- release only past VIEW + SLACK (hysteresis)
MeshDress.MAX = 70
MeshDress.MAX_SLACK = 10 -- a dressed object keeps its mesh up to rank MAX + MAX_SLACK
MeshDress.BUILDS = 6 -- new meshes per step (spread over steps: no hitch)
MeshDress.POOL = 12 -- parked props kept per mesh name
MeshDress.REFRESH = 0.25
MeshDress.RESCAN = 4

MeshDress.LANDMARKS = {
	tree = true,
	pine = true,
	palm = true,
	jungle_tree = true,
	dead_tree = true,
	mushroom = true,
	rock = true,
	snow_rock = true,
	ice = true,
	crystal = true,
	lava_rock = true,
	coral = true,
	moon_rock = true,
	wedge = true,
	pillar = true,
	mesa = true,
} :: { [string]: boolean }
MeshDress.KINDS =
	{ stall = "prop_stall", class = "prop_class_stall", altar = "prop_altar", swap = "prop_swap" } :: {
		[string]: string,
	}
MeshDress.OBJECTIVES =
	{ caravan = true, beacon = true, rescue_cage = true, miniboss_camp = true } :: { [string]: boolean }

local MeshModels: any = nil
do
	local inst = script.Parent:FindFirstChild("MeshModels")
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		MeshModels = if ok then mod else nil
	end
end

type Target = {
	model: Instance,
	mesh: string,
	x: number,
	z: number,
	fit: string, -- "radius" | "bbox"
	r: number,
}
type Dressed = { prop: any, hidden: { BasePart }, mesh: string, canopy: boolean }

local enabled = true
local targets: { Target } = {}
local dressed: { [Instance]: Dressed } = {}
local coveredParts: { [BasePart]: boolean } = {}
local failed: { [Instance]: boolean } = {} -- no mesh for it this scan
local pools: { [string]: { any } } = {}
local arenaRef: Instance? = nil
local refreshAt = 0
local rescanAt = 0
local folder: Folder? = nil
local stats = { dressed = 0, built = 0, reused = 0, missing = 0 }
MeshDress.stats = stats
local PARK = CFrame.new(0, -5000, 0)
local TREES = { tree = true, pine = true, palm = true, jungle_tree = true, dead_tree = true, mushroom = true }

function MeshDress.init(lowSpec: boolean)
	enabled = not lowSpec
end

-- Mesh name for a world object, or nil.
function MeshDress.meshFor(m: Instance, obstacle: boolean): (string?, string?)
	if obstacle then
		local kind = string.gsub(m.Name, "_lite$", "")
		if MeshDress.LANDMARKS[kind] then
			return "lm_" .. kind, "radius"
		end
		return nil, nil
	end
	local kind = m:GetAttribute("Kind")
	if type(kind) == "string" and MeshDress.KINDS[kind] then
		return MeshDress.KINDS[kind], "bbox"
	end
	local id = m:GetAttribute("PoiId")
	if type(id) == "string" then
		local lid = string.lower(id)
		if MeshDress.OBJECTIVES[lid] then
			return "obj_" .. lid, "bbox"
		elseif string.find(lid, "totem", 1, true) then
			return "prop_totem", "bbox"
		end
	end
	return nil, nil
end

local function add(m: Instance, obstacle: boolean)
	local mesh, fit = MeshDress.meshFor(m, obstacle)
	if not mesh or not fit then
		return
	end
	local x, z = tonumber(m:GetAttribute("X")), tonumber(m:GetAttribute("Z"))
	if (x == nil or z == nil) and m:IsA("Model") then
		local p = m:GetPivot().Position
		x, z = p.X, p.Z
	end
	if x and z then
		table.insert(targets, {
			model = m,
			mesh = mesh,
			x = x,
			z = z,
			fit = fit,
			r = tonumber(m:GetAttribute("Radius")) or 3,
		})
	end
end

local function scan(arena: Instance)
	table.clear(targets)
	table.clear(failed)
	for _, f in arena:GetChildren() do
		local obstacle = f.Name == "Obstacles"
		if f:IsA("Folder") or f:IsA("Model") then
			for _, m in f:GetChildren() do
				if m:IsA("Model") then
					add(m, obstacle)
				end
			end
		end
	end
end

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "TrunkfallMeshDress"
	f.Parent = workspace
	folder = f
	return f
end

local function release(m: Instance)
	local d = dressed[m]
	if not d then
		return
	end
	dressed[m] = nil
	stats.dressed -= 1
	-- park the prop for reuse (or drop it when the pool is full)
	local pool = pools[d.mesh]
	if not pool then
		pool = {}
		pools[d.mesh] = pool
	end
	if #pool < MeshDress.POOL then
		for _, p in d.prop.parts do
			p.CFrame = PARK
			p.LocalTransparencyModifier = 0
		end
		table.insert(pool, d.prop)
	else
		for _, p in d.prop.parts do
			p:Destroy()
		end
	end
	-- the part model is shown again; DetailLevel re-applies its canopy fade
	-- (it forgets the parts we covered, so its next pass fades them if needed)
	for _, p in d.hidden do
		coveredParts[p] = nil
		if p.Parent then
			p.LocalTransparencyModifier = 0
		end
	end
end

local function dress(t: Target): boolean
	local m = t.model
	if not MeshModels.info(t.mesh) or not MeshModels.template(t.mesh) then
		return false -- not uploaded / loaded: the part model stays
	end
	-- the part model's visible, non-Neon parts and their bounds
	local hidden: { BasePart } = {}
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 1 and d.Material ~= Enum.Material.Neon then
			table.insert(hidden, d)
			local h = d.Size / 2
			lo = lo:Min(d.Position - h)
			hi = hi:Max(d.Position + h)
		end
	end
	if #hidden == 0 then
		return false
	end
	local info = MeshModels.info(t.mesh)
	local scale: number
	if t.fit == "radius" then
		scale = t.r / math.max(0.1, info.radius)
	else
		local size = hi - lo
		local ms = info.size
		scale = math.min(
			size.Y / math.max(0.1, ms.Y),
			math.max(size.X, size.Z) / math.max(0.1, math.max(ms.X, ms.Z)) * 1.15
		)
		scale = math.max(0.2, scale)
	end
	local pool = pools[t.mesh]
	local prop = if pool and #pool > 0 then table.remove(pool) else nil
	if prop then
		MeshModels.rescaleProp(prop, scale)
		stats.reused += 1
	else
		prop = MeshModels.prop(t.mesh, scale, getFolder())
		if not prop then
			stats.missing += 1
			return false
		end
		stats.built += 1
	end
	-- landmarks turn by a stable per-position yaw; props face the arena centre
	local yaw = if t.fit == "radius"
		then ((t.x * 12.9898 + t.z * 78.233) % (2 * math.pi))
		else math.atan2(t.x, t.z)
	local base = CFrame.new(t.x, lo.Y, t.z) * CFrame.Angles(0, yaw, 0)
	for i, p in prop.parts do
		p.CFrame = base * prop.offsets[i]
	end
	for _, p in hidden do
		p.LocalTransparencyModifier = 1
		coveredParts[p] = true
	end
	local kind = string.gsub(t.mesh, "^lm_", "")
	dressed[m] = { prop = prop, hidden = hidden, mesh = t.mesh, canopy = TREES[kind] == true }
	stats.dressed += 1
	return true
end

-- True when MeshDress hides this part of a server model (DetailLevel then
-- leaves its LocalTransparencyModifier alone).
function MeshDress.coversPart(p: Instance): boolean
	return coveredParts[p :: any] == true
end

-- The mesh parts of dressed trees (DetailLevel fades them like canopies).
function MeshDress.canopies(): { BasePart }
	local out = {}
	for _, d in dressed do
		if d.canopy then
			for _, p in d.prop.parts do
				table.insert(out, p)
			end
		end
	end
	return out
end

-- True when MeshDress draws `m` (DetailStreamer then leaves it alone).
function MeshDress.covers(m: Instance): boolean
	return dressed[m] ~= nil
end

function MeshDress.clear()
	for m in dressed do
		release(m)
	end
end

function MeshDress.step(dt: number, focus: Vector3)
	if not MeshModels or not enabled then
		return
	end
	refreshAt -= dt
	rescanAt -= dt
	if refreshAt > 0 then
		return
	end
	refreshAt = MeshDress.REFRESH
	local arena = workspace:FindFirstChild("Arena")
	if arena ~= arenaRef or rescanAt <= 0 then
		if arena ~= arenaRef then
			MeshDress.clear()
		end
		arenaRef = arena
		rescanAt = MeshDress.RESCAN
		if arena then
			scan(arena)
		else
			table.clear(targets)
		end
	end
	if not MeshModels.allowed() then
		MeshDress.clear()
		return
	end
	local view = MeshDress.VIEW
	local keepR = view + MeshDress.SLACK
	local k2 = keepR * keepR
	-- nearest first (within the keep radius)
	local near: { { t: Target, d: number } } = {}
	for _, t in targets do
		if t.model.Parent then
			local dx, dz = t.x - focus.X, t.z - focus.Z
			local d = dx * dx + dz * dz
			if d <= k2 then
				table.insert(near, { t = t, d = d })
			end
		end
	end
	table.sort(near, function(a, b)
		return a.d < b.d
	end)
	local keep: { [Instance]: boolean } = {}
	for i, e in near do
		-- dressed ones stay up to MAX + MAX_SLACK and VIEW + SLACK
		if i <= MeshDress.MAX + MeshDress.MAX_SLACK and dressed[e.t.model] then
			keep[e.t.model] = true
		end
	end
	for m in dressed do
		if not keep[m] or not m.Parent then
			release(m)
		end
	end
	local builds = 0
	local v2 = view * view
	for i = 1, math.min(MeshDress.MAX, #near) do
		if stats.dressed >= MeshDress.MAX + MeshDress.MAX_SLACK or builds >= MeshDress.BUILDS then
			break
		end
		local e = near[i]
		if e.d <= v2 and not dressed[e.t.model] and not failed[e.t.model] then
			if dress(e.t) then
				builds += 1
			else
				failed[e.t.model] = true
			end
		end
	end
end

return MeshDress
