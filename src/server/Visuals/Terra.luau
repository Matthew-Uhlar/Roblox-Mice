--!strict
-- Terra (R4 Graphics): thin wrappers over Workspace.Terrain smooth-terrain fills
-- (FillBlock / FillBall / FillCylinder / FillWedge), shared by ArenaBuilder and
-- LobbyWorld.
--
-- Rules the callers rely on:
--   * Terrain voxels are 4 studs. A fill whose top face sits exactly on Y = 0
--     leaves a flat walkable surface at Y = 0 (the combat sim's ground plane).
--   * Fills overwrite whatever terrain was in their volume, so a thin fill of
--     another material on top of the ground repaints it (paths, patches).
--   * Terra.clearBox writes Air in chunks; it only touches the given box, so the
--     lobby island (far away at Z = -400) survives an arena rebuild.
-- If the place has no Terrain (or an engine call fails), Terra.ok() is false and
-- every call is a no-op after one warning: the Part dressing still builds.

local Workspace = game:GetService("Workspace")

local Terra = {}

local terrain: Terrain? = nil
local failed = false

local function get(): Terrain?
	if failed then
		return nil
	end
	if terrain and terrain.Parent then
		return terrain
	end
	local t = Workspace:FindFirstChildOfClass("Terrain")
	terrain = t
	return t
end

local function guard(what: string, fn: (Terrain) -> ())
	local t = get()
	if not t then
		return
	end
	local ok, err = pcall(fn, t)
	if not ok then
		failed = true
		warn("[Terra] terrain " .. what .. " failed; terrain dressing disabled for this server: " .. tostring(err))
	end
end

function Terra.ok(): boolean
	return get() ~= nil
end

function Terra.block(cf: CFrame, size: Vector3, material: Enum.Material)
	guard("FillBlock", function(t)
		t:FillBlock(cf, size, material)
	end)
end

function Terra.ball(center: Vector3, radius: number, material: Enum.Material)
	guard("FillBall", function(t)
		t:FillBall(center, radius, material)
	end)
end

-- Upright cylinder: `cf` is the centre, height runs along cf's Y axis.
function Terra.cylinder(cf: CFrame, height: number, radius: number, material: Enum.Material)
	guard("FillCylinder", function(t)
		t:FillCylinder(cf, height, radius, material)
	end)
end

-- Same orientation as a WedgePart: slope faces cf's -Z (front), tall face at +Z.
function Terra.wedge(cf: CFrame, size: Vector3, material: Enum.Material)
	guard("FillWedge", function(t)
		t:FillWedge(cf, size, material)
	end)
end

-- A flat disc of `material` repainting the top voxel layer around (x, z): the
-- surface stays exactly at Y = 0.
function Terra.paint(x: number, z: number, radius: number, material: Enum.Material)
	Terra.cylinder(CFrame.new(x, -2, z), 4, radius, material)
end

-- Air in an axis-aligned box, in chunks of at most `chunk` studs per side.
function Terra.clearBox(center: Vector3, size: Vector3, chunk: number?)
	local c = chunk or 128
	local nx = math.max(1, math.ceil(size.X / c))
	local ny = math.max(1, math.ceil(size.Y / c))
	local nz = math.max(1, math.ceil(size.Z / c))
	local sx, sy, sz = size.X / nx, size.Y / ny, size.Z / nz
	local min = center - size / 2
	for i = 0, nx - 1 do
		for j = 0, ny - 1 do
			for k = 0, nz - 1 do
				local p = min + Vector3.new((i + 0.5) * sx, (j + 0.5) * sy, (k + 0.5) * sz)
				Terra.block(CFrame.new(p), Vector3.new(sx, sy, sz), Enum.Material.Air)
			end
		end
	end
end

-- Tints for terrain materials ({[Enum.Material] = Color3}); global to the Terrain.
function Terra.colors(map: { [Enum.Material]: Color3 })
	guard("SetMaterialColor", function(t)
		for mat, col in map do
			t:SetMaterialColor(mat, col)
		end
	end)
end

function Terra.water(props: { color: Color3?, transparency: number?, reflectance: number?, waveSize: number?, waveSpeed: number? })
	guard("water", function(t)
		if props.color then
			t.WaterColor = props.color
		end
		if props.transparency then
			t.WaterTransparency = props.transparency
		end
		if props.reflectance then
			t.WaterReflectance = props.reflectance
		end
		if props.waveSize then
			t.WaterWaveSize = props.waveSize
		end
		if props.waveSpeed then
			t.WaterWaveSpeed = props.waveSpeed
		end
	end)
end

-- Clouds live under Terrain (one per place). nil/false = remove.
function Terra.clouds(props: { cover: number, density: number, color: Color3 }?)
	guard("clouds", function(t)
		local c = t:FindFirstChildOfClass("Clouds")
		if not props then
			if c then
				c:Destroy()
			end
			return
		end
		if not c then
			local nc = Instance.new("Clouds")
			nc.Parent = t
			c = nc
		end
		local cl = c :: Clouds
		cl.Cover = props.cover
		cl.Density = props.density
		cl.Color = props.color
		cl.Enabled = true
	end)
end

return Terra
