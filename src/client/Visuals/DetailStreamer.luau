--!strict
-- DetailStreamer (iter4, team G, client): client-side detail on the server's
-- cheap stand-ins, near the camera only (docs/iter/4/PLAN.md: "server collision
-- primitives plus client-side detail").
--
--   DetailStreamer.init(lowSpec, mobile)
--   DetailStreamer.step(dt, focus)     CameraController calls it every frame
--
-- The server keeps its part budget by building "_lite" obstacles (trees, rocks,
-- mesas past ArenaBuilder.OBSTACLE_DETAIL_PARTS) and lite POIs (attribute Lite,
-- past ArenaBuilder.POI_BUDGET). Within VIEW studs of the camera focus this
-- module dresses them from a fixed pool of local parts:
--   * lite trees  -> a fuller canopy (3 leaf balls tinted from the tree) + roots
--   * lite rocks  -> two extra boulders and a moss cap
--   * lite POIs   -> a ring of 6 marker stones and a pennant in the POI colour
-- Nothing collides or is queryable; low-spec devices skip it.

local DetailStreamer = {}

DetailStreamer.VIEW = 95
DetailStreamer.VIEW_MOBILE = 70
DetailStreamer.POOL = 360
DetailStreamer.POOL_MOBILE = 180
DetailStreamer.REFRESH = 0.35

local V3 = Vector3.new
local CF = CFrame.new
local M = Enum.Material
local PARK = CF(0, -5000, 0)

type Target = { model: Instance, kind: string, x: number, z: number, r: number, color: Color3 }

local enabled = true
local view = DetailStreamer.VIEW
local poolSize = DetailStreamer.POOL
local folder: Folder? = nil
local free: { BasePart } = {}
local made = 0
local dressed: { [Instance]: { BasePart } } = {}
local targets: { Target } = {}
local arenaRef: Instance? = nil
local refreshAt = 0

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "TrunkfallDetail"
	f.Parent = workspace
	folder = f
	return f
end

local function take(): BasePart?
	local p = table.remove(free)
	if p then
		return p
	end
	if made >= poolSize then
		return nil
	end
	made += 1
	local np = Instance.new("Part")
	np.Anchored = true
	np.CanCollide = false
	np.CanQuery = false
	np.CanTouch = false
	np.CastShadow = false
	np.CFrame = PARK
	np.Parent = getFolder()
	return np
end

local function firstColor(m: Instance, fallback: Color3): Color3
	local best: BasePart? = nil
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 0.5 then
			if not best or d.Size.Magnitude > best.Size.Magnitude then
				best = d
			end
		end
	end
	return if best then best.Color else fallback
end

local function scan(arena: Instance)
	table.clear(targets)
	local obs = arena:FindFirstChild("Obstacles")
	if obs then
		for _, m in obs:GetChildren() do
			local name = m.Name
			if string.sub(name, -5) == "_lite" then
				local x, z = tonumber(m:GetAttribute("X")), tonumber(m:GetAttribute("Z"))
				local r = tonumber(m:GetAttribute("Radius")) or 3
				if x and z then
					local isTree = string.find(name, "tree", 1, true) ~= nil
						or string.find(name, "pine", 1, true) ~= nil
						or string.find(name, "palm", 1, true) ~= nil
						or string.find(name, "mushroom", 1, true) ~= nil
						or string.find(name, "coral", 1, true) ~= nil
					table.insert(targets, {
						model = m,
						kind = if isTree then "tree" else "rock",
						x = x,
						z = z,
						r = r,
						color = firstColor(m, Color3.fromRGB(90, 150, 70)),
					})
				end
			end
		end
	end
	local pois = arena:FindFirstChild("POIs")
	if pois then
		for _, m in pois:GetChildren() do
			if m:GetAttribute("Lite") == true then
				local x, z = tonumber(m:GetAttribute("X")), tonumber(m:GetAttribute("Z"))
				if x and z then
					table.insert(targets, {
						model = m,
						kind = "poi",
						x = x,
						z = z,
						r = 6,
						color = firstColor(m, Color3.fromRGB(255, 201, 60)),
					})
				end
			end
		end
	end
end

local function release(m: Instance, moves: { BasePart }, cfs: { CFrame })
	local list = dressed[m]
	if not list then
		return
	end
	for _, p in list do
		table.insert(moves, p)
		table.insert(cfs, PARK)
		table.insert(free, p)
	end
	dressed[m] = nil
end

local function put(
	list: { BasePart },
	moves,
	cfs,
	shape: Enum.PartType,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	mat: Enum.Material
)
	local p = take()
	if not p then
		return
	end
	local pp = p :: Part
	pp.Shape = shape
	pp.Size = size
	pp.Color = color
	pp.Material = mat
	pp.Transparency = 0
	table.insert(list, p)
	table.insert(moves, p)
	table.insert(cfs, cf)
end

local function dress(t: Target, moves, cfs)
	local list: { BasePart } = {}
	local seed = (math.floor(t.x * 7 + t.z * 13) % 97) / 97
	if t.kind == "tree" then
		local leaf = t.color
		local h = t.r * 2.2 + 3
		for k = 0, 2 do
			local a = seed * 6.28 + k * 2.1
			local d = t.r * 0.55
			put(
				list,
				moves,
				cfs,
				Enum.PartType.Ball,
				Vector3.one * (t.r * 1.5 + 1),
				CF(t.x + math.cos(a) * d, h + (k % 2) * 1.2, t.z + math.sin(a) * d),
				leaf:Lerp(Color3.new(1, 1, 1), 0.08 * k),
				M.Grass
			)
		end
		for k = 0, 1 do
			local a = seed * 6.28 + k * 3.1
			put(
				list,
				moves,
				cfs,
				Enum.PartType.Block,
				V3(0.6, 0.5, t.r * 0.9),
				CF(t.x + math.cos(a) * t.r * 0.45, 0.2, t.z + math.sin(a) * t.r * 0.45)
					* CFrame.Angles(0, -a, 0),
				Color3.fromRGB(110, 76, 44),
				M.Wood
			)
		end
	elseif t.kind == "rock" then
		for k = 0, 1 do
			local a = seed * 6.28 + k * 2.6
			local s = t.r * (0.6 + 0.2 * k)
			put(
				list,
				moves,
				cfs,
				Enum.PartType.Ball,
				Vector3.one * s,
				CF(t.x + math.cos(a) * t.r * 0.9, s * 0.25, t.z + math.sin(a) * t.r * 0.9),
				t.color:Lerp(Color3.new(0, 0, 0), 0.12),
				M.Rock
			)
		end
		put(
			list,
			moves,
			cfs,
			Enum.PartType.Ball,
			V3(t.r * 1.2, t.r * 1.2, t.r * 1.2),
			CF(t.x, t.r * 1.1, t.z),
			Color3.fromRGB(100, 150, 70),
			M.Grass
		)
	else
		for k = 0, 5 do
			local a = k / 6 * 6.28
			put(
				list,
				moves,
				cfs,
				Enum.PartType.Block,
				V3(0.8, 1.2, 0.8),
				CF(t.x + math.cos(a) * 5, 0.6, t.z + math.sin(a) * 5) * CFrame.Angles(0, a, 0),
				Color3.fromRGB(175, 165, 150),
				M.Slate
			)
		end
		put(
			list,
			moves,
			cfs,
			Enum.PartType.Block,
			V3(0.25, 5, 0.25),
			CF(t.x + 3.5, 2.5, t.z - 3.5),
			Color3.fromRGB(110, 76, 44),
			M.Wood
		)
		put(
			list,
			moves,
			cfs,
			Enum.PartType.Block,
			V3(0.1, 1.2, 1.8),
			CF(t.x + 3.5, 4.4, t.z - 2.6),
			t.color,
			M.Fabric
		)
	end
	dressed[t.model] = list
end

-- iteration 8 (team Mesh): mesh landmarks / props (Visuals/MeshDress) run first;
-- what they cover is not dressed with extra parts here.
local MeshDress: any = nil
do
	local inst = script.Parent:FindFirstChild("MeshDress")
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		MeshDress = if ok then mod else nil
	end
end

function DetailStreamer.init(lowSpec: boolean, mobile: boolean)
	if MeshDress then
		pcall(MeshDress.init, lowSpec or mobile)
	end
	enabled = not lowSpec
	view = if mobile then DetailStreamer.VIEW_MOBILE else DetailStreamer.VIEW
	poolSize = if mobile then DetailStreamer.POOL_MOBILE else DetailStreamer.POOL
end

function DetailStreamer.step(dt: number, focus: Vector3)
	if MeshDress then
		local ok, err = pcall(MeshDress.step, dt, focus)
		if not ok then
			warn("[Trunkfall] MeshDress: " .. tostring(err))
			MeshDress = nil
		end
	end
	if not enabled then
		return
	end
	refreshAt -= dt
	if refreshAt > 0 then
		return
	end
	refreshAt = DetailStreamer.REFRESH
	local moves, cfs = {}, {}
	local arena = workspace:FindFirstChild("Arena")
	if arena ~= arenaRef then
		for m in dressed do
			release(m, moves, cfs)
		end
		arenaRef = arena
		if arena then
			scan(arena)
		else
			table.clear(targets)
		end
	end
	local v2 = view * view
	for _, t in targets do
		local dx, dz = t.x - focus.X, t.z - focus.Z
		local near = dx * dx + dz * dz <= v2
			and t.model.Parent ~= nil
			and not (MeshDress and MeshDress.covers(t.model))
		if near and not dressed[t.model] then
			dress(t, moves, cfs)
		elseif not near and dressed[t.model] then
			release(t.model, moves, cfs)
		end
	end
	if #moves > 0 then
		workspace:BulkMoveTo(moves, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

return DetailStreamer
