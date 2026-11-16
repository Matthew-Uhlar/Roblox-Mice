--!strict
-- DetailLevel (R4 Graphics, client): device-dependent world detail (GDD-v2 §6).
--
--   DetailLevel.init(lowSpec: boolean, mobile: boolean)   CameraController calls it once.
--   DetailLevel.fadeCanopies(focus: Vector3, camPos: Vector3)  per frame (throttled)
--
-- * Low-spec devices hide everything the server tagged "Decor" (small floor props)
--   and "DecorFar" (the plateau backdrop): their parts go fully transparent
--   LOCALLY (Roblox skips drawing them) and their emitters / lights turn off.
--   New arenas are handled through CollectionService instance-added signals.
-- * Mobile devices turn the DepthOfField effect off (GDD-v2: DoF off on mobile);
--   elsewhere the camera keeps it focused on the hero.
-- * Tree canopies (tag "Canopy") between the camera and your hero fade so you
--   never lose your elephant under a tree.
-- * DetailLevel.setLobbyHidden(true) while this player is in a run (FxController
--   follows the run phase): the lobby island's decor (workspace.LobbyPad, tags
--   "Decor" / "DecorFar") is hidden LOCALLY: LocalTransparencyModifier 1, its
--   lights and emitters off. It stays loaded at Z = -400 but costs no draw
--   calls during the match (QC-A minor 7). false restores it.

--   DetailLevel.stream(dt, focus)  per frame (CameraController): v3 decor streaming.
--     The arena's "Decor" models (small props, the bigger the maps the more of
--     them) are hidden locally beyond STREAM_RADIUS studs of the camera focus
--     (mid / mobile 180, high-end 300; low-spec hides all Decor anyway):
--     LocalTransparencyModifier 1 and emitters / lights off, restored when the
--     camera comes back. Checked 4x a second on a 64-stud grid of cells.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")

local DetailLevel = {}

DetailLevel.CANOPY_FADE = 0.65
DetailLevel.CANOPY_RADIUS = 9

local started = false
local mobileDof = false

local function hide(inst: Instance)
	local list = inst:GetDescendants()
	table.insert(list, inst)
	for _, d in list do
		if d:IsA("BasePart") then
			d.Transparency = 1
			d.CastShadow = false
		elseif d:IsA("ParticleEmitter") or d:IsA("Light") or d:IsA("Trail") or d:IsA("Beam") then
			(d :: any).Enabled = false
		end
	end
end

local function dofOff(inst: Instance)
	if mobileDof and inst:IsA("DepthOfFieldEffect") then
		inst.Enabled = false
	end
end

local lowSpecOn = false
local lobbyHidden = false
local lobbySaved: { [Instance]: boolean } = {} -- light / emitter -> Enabled before hiding

function DetailLevel.lobbyHidden(): boolean
	return lobbyHidden
end

function DetailLevel.setLobbyHidden(hidden: boolean)
	if hidden == lobbyHidden then
		return
	end
	lobbyHidden = hidden
	local pad = workspace:FindFirstChild("LobbyPad")
	if not pad then
		return
	end
	for _, tag in { "Decor", "DecorFar" } do
		for _, inst in CollectionService:GetTagged(tag) do
			if inst:IsDescendantOf(pad) then
				local list = inst:GetDescendants()
				table.insert(list, inst)
				for _, d in list do
					if d:IsA("BasePart") then
						d.LocalTransparencyModifier = if hidden then 1 else 0
					elseif d:IsA("ParticleEmitter") or d:IsA("Light") then
						local e = d :: any
						if hidden then
							lobbySaved[d] = e.Enabled
							e.Enabled = false
						elseif lobbySaved[d] ~= nil then
							e.Enabled = lobbySaved[d] and not lowSpecOn
							lobbySaved[d] = nil
						end
					end
				end
			end
		end
	end
	if not hidden then
		table.clear(lobbySaved)
	end
end

-- Decor streaming -------------------------------------------------------------------------

DetailLevel.STREAM_RADIUS = 300
DetailLevel.STREAM_CELL = 64
type Cell = { items: { Instance }, shown: boolean, x: number, z: number }
local cells: { [number]: Cell } = {}
local cellOf: { [Instance]: number } = {}
local streamAcc = 0
local streaming = false
local streamSaved: { [Instance]: boolean } = {}

local function cellKey(x: number, z: number): number
	local c = DetailLevel.STREAM_CELL
	return math.floor(x / c + 512) * 4096 + math.floor(z / c + 512)
end

local function setShown(inst: Instance, shown: boolean)
	local list = inst:GetDescendants()
	table.insert(list, inst)
	for _, d in list do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = if shown then 0 else 1
		elseif d:IsA("ParticleEmitter") or d:IsA("Light") then
			local e = d :: any
			if not shown then
				streamSaved[d] = e.Enabled
				e.Enabled = false
			elseif streamSaved[d] ~= nil then
				e.Enabled = streamSaved[d]
				streamSaved[d] = nil
			end
		end
	end
end

local function track(inst: Instance)
	if cellOf[inst] or lowSpecOn then
		return
	end
	local arena = workspace:FindFirstChild("Arena")
	if not arena or not inst:IsDescendantOf(arena) then
		return
	end
	local pos: Vector3? = nil
	if inst:IsA("Model") then
		local ok, pv = pcall(function()
			return inst:GetPivot().Position
		end)
		pos = if ok then pv else nil
	elseif inst:IsA("BasePart") then
		pos = inst.Position
	end
	if not pos then
		return
	end
	local key = cellKey(pos.X, pos.Z)
	local cell = cells[key]
	if not cell then
		local c = DetailLevel.STREAM_CELL
		cell = {
			items = {},
			shown = true,
			x = (math.floor(pos.X / c) + 0.5) * c,
			z = (math.floor(pos.Z / c) + 0.5) * c,
		}
		cells[key] = cell
	end
	table.insert(cell.items, inst)
	cellOf[inst] = key
	if not cell.shown then
		setShown(inst, false)
	end
end

local function untrack(inst: Instance)
	local key = cellOf[inst]
	if not key then
		return
	end
	cellOf[inst] = nil
	local cell = cells[key]
	if cell then
		local i = table.find(cell.items, inst)
		if i then
			table.remove(cell.items, i)
		end
		if #cell.items == 0 then
			cells[key] = nil
		end
	end
end

local function startStreaming(mobile: boolean)
	if streaming then
		return
	end
	streaming = true
	DetailLevel.STREAM_RADIUS = if mobile then 180 else 300
	for _, inst in CollectionService:GetTagged("Decor") do
		task.defer(track, inst)
	end
	CollectionService:GetInstanceAddedSignal("Decor"):Connect(function(inst)
		task.defer(track, inst) -- its children and pivot replicate first
	end)
	CollectionService:GetInstanceRemovedSignal("Decor"):Connect(untrack)
end

function DetailLevel.stream(dt: number, focus: Vector3)
	if not streaming then
		return
	end
	streamAcc += dt
	if streamAcc < 0.25 then
		return
	end
	streamAcc = 0
	local R = DetailLevel.STREAM_RADIUS + DetailLevel.STREAM_CELL * 0.7
	local R2 = R * R
	for _, cell in cells do
		local dx, dz = cell.x - focus.X, cell.z - focus.Z
		local want = dx * dx + dz * dz <= R2
		if want ~= cell.shown then
			cell.shown = want
			for _, inst in cell.items do
				if inst.Parent then
					setShown(inst, want)
				end
			end
		end
	end
end

function DetailLevel.streamStats(): (number, number)
	local n, hidden = 0, 0
	for _, cell in cells do
		n += #cell.items
		if not cell.shown then
			hidden += #cell.items
		end
	end
	return n, hidden
end

function DetailLevel.init(lowSpec: boolean, mobile: boolean)
	if started then
		return
	end
	started = true
	lowSpecOn = lowSpec
	if not lowSpec then
		startStreaming(mobile)
	end
	if lowSpec then
		for _, tag in { "Decor", "DecorFar" } do
			for _, inst in CollectionService:GetTagged(tag) do
				hide(inst)
			end
			CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst)
				task.defer(hide, inst) -- let its children replicate first
			end)
		end
	end
	if mobile then
		mobileDof = true
		for _, c in Lighting:GetChildren() do
			dofOff(c)
		end
		Lighting.ChildAdded:Connect(dofOff)
	end
end

-- The DepthOfField effect (server-created by LightingService), when enabled here.
function DetailLevel.depthOfField(): DepthOfFieldEffect?
	if mobileDof then
		return nil
	end
	local d = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	return if d and d.Enabled then d else nil
end

local faded: { [BasePart]: boolean } = {}
local acc = 0

function DetailLevel.fadeCanopies(dt: number, focus: Vector3, camPos: Vector3)
	acc += dt
	if acc < 0.12 then
		return
	end
	acc = 0
	local R = DetailLevel.CANOPY_RADIUS
	local now: { [BasePart]: boolean } = {}
	for _, inst in CollectionService:GetTagged("Canopy") do
		if inst:IsA("BasePart") then
			local p = inst.Position
			-- between hero and camera (the camera sits on the +Z side, above)
			local dx, dz = p.X - focus.X, p.Z - focus.Z
			if p.Y > focus.Y + 2 and dx * dx + (dz - 3) ^ 2 < R * R and dz > -4 and p.Y < camPos.Y then
				now[inst] = true
			end
		end
	end
	for part in faded do
		if not now[part] then
			part.LocalTransparencyModifier = 0
			faded[part] = nil
		end
	end
	for part in now do
		if not faded[part] then
			part.LocalTransparencyModifier = DetailLevel.CANOPY_FADE
			faded[part] = true
		end
	end
end

return DetailLevel
