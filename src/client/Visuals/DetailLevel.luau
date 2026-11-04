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

function DetailLevel.init(lowSpec: boolean, mobile: boolean)
	if started then
		return
	end
	started = true
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
