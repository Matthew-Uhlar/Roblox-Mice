--!strict
-- Renders Net.S2C.Fx batches ({FxEvent}) as local, pooled visuals.
-- Shapes (docs/ARCHITECTURE.md): proj, hit, die, tele, slam, pickup, pickupTaken,
-- boom, down, revive, ability, melee (+ heal if the server sends it).
-- Everything is pooled and capped harder on mobile. Parts are anchored,
-- non-colliding and non-queryable; moving parts go through one BulkMoveTo.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Remotes = require(Client.Util.Remotes)
local Device = require(Client.Util.Device)
local State = require(script.Parent.State)

local FxController = {}

local LOW = Device.lowSpec()
local CAP = {
	proj = if LOW then 160 else 400,
	hit = if LOW then 18 else 40,
	crumbs = if LOW then 50 else 180,
	pickups = if LOW then 120 else 320,
	effects = if LOW then 60 else 160,
}
local CRUMBS_PER_DEATH = if LOW then 2 else 5
local PROJ_Y = 2.5
local GROUND_Y = 0.08
local GRAVITY = 70
local PARK = CFrame.new(0, -5000, 0)
local BIND_NAME = "TrunkfallFx"

local COLORS = {
	cheese = Color3.fromRGB(255, 204, 51),
	cheeseDark = Color3.fromRGB(235, 160, 30),
	cream = Color3.fromRGB(255, 244, 214),
	brown = Color3.fromRGB(120, 80, 45),
	red = Color3.fromRGB(235, 60, 50),
	enemyProj = Color3.fromRGB(255, 80, 60),
	white = Color3.fromRGB(255, 255, 255),
	green = Color3.fromRGB(110, 220, 110),
	orange = Color3.fromRGB(255, 140, 40),
}

local PROJ_COLORS: { [string]: Color3 } = {
	bolt = Color3.fromRGB(90, 185, 255),
	water = Color3.fromRGB(90, 185, 255),
	spread = Color3.fromRGB(215, 170, 110),
	peanut = Color3.fromRGB(215, 170, 110),
	lob = Color3.fromRGB(150, 235, 90),
	fizz = Color3.fromRGB(150, 235, 90),
	puddle = Color3.fromRGB(255, 120, 40),
	cone = Color3.fromRGB(230, 230, 255),
	orbit = Color3.fromRGB(220, 220, 230),
}

local ABILITY_COLORS: { [string]: Color3 } = {
	dash = Color3.fromRGB(255, 255, 255),
	burst = Color3.fromRGB(90, 185, 255),
	ring = Color3.fromRGB(120, 210, 90),
	shield = Color3.fromRGB(255, 210, 80),
	puddle = Color3.fromRGB(255, 120, 40),
	hover = Color3.fromRGB(170, 220, 255),
	field = Color3.fromRGB(190, 120, 240),
}

----------------------------------------------------------------------
-- Pools
----------------------------------------------------------------------

local folder: Folder? = nil
local partPools: { [Enum.PartType]: { BasePart } } = {}

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "TrunkfallFx"
	f.Parent = workspace
	folder = f
	return f
end

local function getPart(
	shape: Enum.PartType,
	size: Vector3,
	color: Color3,
	transparency: number?,
	neon: boolean?
): BasePart
	local pool = partPools[shape]
	local p: BasePart
	if pool and #pool > 0 then
		p = table.remove(pool) :: BasePart
	else
		local np = Instance.new("Part")
		np.Shape = shape
		np.Anchored = true
		np.CanCollide = false
		np.CanQuery = false
		np.CanTouch = false
		np.CastShadow = false
		np.TopSurface = Enum.SurfaceType.Smooth
		np.BottomSurface = Enum.SurfaceType.Smooth
		np.CFrame = PARK
		np.Parent = getFolder()
		p = np
	end
	p.Size = size
	p.Color = color
	p.Transparency = transparency or 0
	p.Material = if neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	return p
end

local function putPart(p: BasePart)
	p.CFrame = PARK
	p.Transparency = 1
	local shape = (p :: Part).Shape
	local pool = partPools[shape]
	if not pool then
		pool = {}
		partPools[shape] = pool
	end
	table.insert(pool, p)
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function num(v: any, default: number): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return default
	end
	return n
end

-- Angles may arrive in degrees or radians; anything above 2π is degrees.
local function toRadians(a: any, defaultDeg: number): number
	local v = num(a, defaultDeg)
	if v > math.pi * 2 + 0.01 then
		return math.rad(v)
	end
	return v
end

local function flatDir(dx: any, dz: any): (number, number)
	local x, z = num(dx, 0), num(dz, -1)
	local m = math.sqrt(x * x + z * z)
	if m < 1e-4 then
		return 0, -1
	end
	return x / m, z / m
end

local function discCFrame(x: number, z: number, y: number?): CFrame
	-- Cylinder axis is X; rotate so the flat face points up.
	return CFrame.new(x, y or GROUND_Y, z) * CFrame.Angles(0, 0, math.pi / 2)
end

local function modelRoot(model: Instance): BasePart?
	local r = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Head")
	if r and r:IsA("BasePart") then
		return r
	end
	if model:IsA("Model") and model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

-- Bot teammates have negative ids and live as server-built models under
-- workspace.Bots. ASSUMPTION: a bot model is identified by an attribute
-- (BotId / Id / UserId) equal to its id, or by a name containing the id.
local botCache: { [number]: Instance } = {}
local function botModel(id: number): Instance?
	local cached = botCache[id]
	if cached and cached.Parent then
		return cached
	end
	botCache[id] = nil
	local bots = workspace:FindFirstChild("Bots")
	if not bots then
		return nil
	end
	local sid = tostring(id)
	for _, m in bots:GetChildren() do
		local attr = m:GetAttribute("BotId") or m:GetAttribute("Id") or m:GetAttribute("UserId")
		if (attr ~= nil and tonumber(attr) == id) or m.Name == sid or string.find(m.Name, sid, 1, true) then
			botCache[id] = m
			return m
		end
	end
	return nil
end

-- Root part for a party member id: real players (UserId; negative for Studio test players) or bots (Ids.isBot).
local function characterRoot(userId: number): BasePart?
	if State.isBot(userId) then
		local m = botModel(userId)
		return if m then modelRoot(m) else nil
	end
	local plr = Players:GetPlayerByUserId(userId)
	local char = plr and plr.Character
	if not char then
		return nil
	end
	return modelRoot(char)
end

local hordeRenderer: any = nil
local function horde(): any
	if hordeRenderer == nil then
		local ok, mod = pcall(require, script.Parent.HordeRenderer)
		hordeRenderer = if ok then mod else false
	end
	return hordeRenderer or nil
end

local cameraController: any = nil
local function shake(x: number, z: number, strength: number)
	if cameraController == nil then
		local ok, mod = pcall(require, script.Parent.CameraController)
		cameraController = if ok then mod else false
	end
	if not cameraController then
		return
	end
	local cam = cameraController.getFocus and cameraController.getFocus()
	local d = if cam then math.sqrt((cam.X - x) ^ 2 + (cam.Z - z) ^ 2) else 0
	if d < 60 then
		cameraController.shake(strength * (1 - d / 60), 0.35)
	end
end

----------------------------------------------------------------------
-- Generic timed effects (closures returning false when finished)
----------------------------------------------------------------------

type Effect = { update: (dt: number) -> boolean, kill: () -> (), tag: string? }
local effects: { Effect } = {}

local function addEffect(e: Effect)
	if #effects >= CAP.effects then
		local oldest = table.remove(effects, 1)
		if oldest then
			oldest.kill()
		end
	end
	table.insert(effects, e)
end

-- Expanding, fading disc (slam shockwave, ability ring).
local function expandingDisc(x: number, z: number, r: number, color: Color3, life: number, startAlpha: number)
	local p = getPart(Enum.PartType.Cylinder, Vector3.new(0.2, 0.1, 0.1), color, startAlpha, true)
	local t = 0
	local function kill()
		putPart(p)
	end
	addEffect({
		update = function(dt)
			t += dt
			local f = math.min(t / life, 1)
			local d = math.max(0.1, 2 * r * (1 - (1 - f) ^ 3))
			p.Size = Vector3.new(0.2, d, d)
			p.CFrame = discCFrame(x, z, GROUND_Y + 0.05)
			p.Transparency = startAlpha + (1 - startAlpha) * f
			if f >= 1 then
				kill()
				return false
			end
			return true
		end,
		kill = kill,
	})
end

-- Expanding, fading ball (boom, poof).
local function expandingBall(
	x: number,
	y: number,
	z: number,
	r: number,
	color: Color3,
	life: number,
	startAlpha: number
)
	local p = getPart(Enum.PartType.Ball, Vector3.one * 0.2, color, startAlpha, true)
	p.CFrame = CFrame.new(x, y, z)
	local t = 0
	local function kill()
		putPart(p)
	end
	addEffect({
		update = function(dt)
			t += dt
			local f = math.min(t / life, 1)
			p.Size = Vector3.one * math.max(0.2, 2 * r * (1 - (1 - f) ^ 2))
			p.Transparency = startAlpha + (1 - startAlpha) * f
			if f >= 1 then
				kill()
				return false
			end
			return true
		end,
		kill = kill,
	})
end

-- Fan of thin blocks from (x, z) in direction (dx, dz): used by cone telegraphs and melee swipes.
local function fanParts(
	dx: number,
	dz: number,
	radius: number,
	angle: number,
	rays: number,
	color: Color3,
	alpha: number
): { BasePart }
	local parts = {}
	local baseYaw = math.atan2(-dx, -dz)
	local width = math.max(0.6, radius * angle / rays)
	for i = 1, rays do
		local a = if rays == 1 then 0 else -angle / 2 + angle * (i - 1) / (rays - 1)
		local p = getPart(Enum.PartType.Block, Vector3.new(width, 0.15, 0.1), color, alpha, false)
		p:SetAttribute("yaw", baseYaw + a)
		table.insert(parts, p)
	end
	return parts
end

local function placeFan(parts: { BasePart }, x: number, z: number, len: number, width: number?)
	for _, p in parts do
		local yaw = (p:GetAttribute("yaw") :: number?) or 0
		local l = math.max(0.1, len)
		p.Size = Vector3.new(width or p.Size.X, p.Size.Y, l)
		p.CFrame = CFrame.new(x, GROUND_Y, z) * CFrame.Angles(0, yaw, 0) * CFrame.new(0, 0, -l / 2)
	end
end

----------------------------------------------------------------------
-- Projectiles, crumbs and pickups (bulk-moved each frame)
----------------------------------------------------------------------

type Proj = { part: BasePart, x: number, z: number, vx: number, vz: number, ttl: number }
local projs: { [any]: Proj } = {}
local projCount = 0
local projSeq = 0

type Crumb = {
	part: BasePart,
	x: number,
	y: number,
	z: number,
	vx: number,
	vy: number,
	vz: number,
	t: number,
	life: number,
	spin: number,
}
local crumbs: { Crumb } = {}

type Pickup = {
	part: BasePart,
	x: number,
	z: number,
	phase: number,
	flying: boolean,
	t: number,
	fromX: number,
	fromY: number,
	fromZ: number,
	target: number?,
}
local pickups: { [any]: Pickup } = {}
local pickupCount = 0

local function projColor(kind: any): (Color3, boolean)
	if type(kind) == "string" then
		local k = string.lower(kind)
		if
			string.find(k, "enemy")
			or string.find(k, "boss")
			or string.find(k, "mouse")
			or string.find(k, "sling")
			or string.find(k, "hostile")
		then
			return COLORS.enemyProj, true
		end
		for name, c in PROJ_COLORS do
			if string.find(k, name) then
				return c, false
			end
		end
	elseif type(kind) == "number" then
		-- Numeric kinds: assume enemy/boss projectiles (ids into Enemies/Bosses).
		return COLORS.enemyProj, true
	end
	return COLORS.cheese, false
end

local function releaseProj(key: any)
	local pr = projs[key]
	if pr then
		putPart(pr.part)
		projs[key] = nil
		projCount -= 1
	end
end

local function onProj(ev: any)
	local key = ev.id
	if key == nil then
		projSeq += 1
		key = "n" .. projSeq
	end
	local existing = projs[key]
	local r = math.clamp(num(ev.r, 0.5), 0.2, 6)
	local x, z = num(ev.x, 0), num(ev.z, 0)
	if existing then
		existing.x, existing.z = x, z
		existing.vx, existing.vz = num(ev.vx, 0), num(ev.vz, 0)
		existing.ttl = num(ev.ttl, 1)
		return
	end
	if projCount >= CAP.proj then
		return
	end
	local color, hostile = projColor(ev.kind)
	if ev.hostile == true then
		color, hostile = COLORS.enemyProj, true
	elseif ev.owner ~= nil then
		hostile = false
	end
	local size = if hostile then math.max(r * 2, 1.2) else math.max(r * 2, 0.6)
	local p = getPart(Enum.PartType.Ball, Vector3.one * size, color, 0, true)
	projs[key] = {
		part = p,
		x = x,
		z = z,
		vx = num(ev.vx, 0),
		vz = num(ev.vz, 0),
		ttl = math.clamp(num(ev.ttl, 1), 0, 10),
	}
	projCount += 1
end

local function spawnCrumbs(x: number, z: number, n: number, color: Color3?)
	for _ = 1, n do
		if #crumbs >= CAP.crumbs then
			return
		end
		local c = if color then color elseif math.random() < 0.5 then COLORS.cheese else COLORS.cheeseDark
		local s = 0.35 + math.random() * 0.35
		local p = getPart(Enum.PartType.Block, Vector3.new(s, s * 0.7, s), c, 0, false)
		local a = math.random() * math.pi * 2
		local sp = 6 + math.random() * 8
		table.insert(crumbs, {
			part = p,
			x = x,
			y = 1,
			z = z,
			vx = math.cos(a) * sp,
			vy = 10 + math.random() * 8,
			vz = math.sin(a) * sp,
			t = 0,
			life = 0.55 + math.random() * 0.2,
			spin = (math.random() - 0.5) * 20,
		})
	end
end

local function releasePickup(key: any)
	local pk = pickups[key]
	if pk then
		putPart(pk.part)
		pickups[key] = nil
		pickupCount -= 1
	end
end

local function onPickup(ev: any)
	local key = ev.id
	if key == nil or pickups[key] or pickupCount >= CAP.pickups then
		return
	end
	local p = getPart(Enum.PartType.Block, Vector3.new(0.9, 0.55, 0.9), COLORS.cheese, 0, false)
	pickups[key] = {
		part = p,
		x = num(ev.x, 0),
		z = num(ev.z, 0),
		phase = math.random() * 6,
		flying = false,
		t = 0,
		fromX = 0,
		fromY = 0,
		fromZ = 0,
		target = nil,
	}
	pickupCount += 1
end

local function onPickupTaken(ev: any)
	local pk = pickups[ev.id]
	if not pk or pk.flying then
		return
	end
	local by = tonumber(ev.by)
	if by == nil or characterRoot(by) == nil then
		releasePickup(ev.id)
		return
	end
	pk.flying = true
	pk.t = 0
	pk.fromX, pk.fromY, pk.fromZ = pk.x, 1, pk.z
	pk.target = by
end

----------------------------------------------------------------------
-- Damage / heal numbers (BillboardGui on Terrain attachments)
----------------------------------------------------------------------

type Number = {
	att: Attachment,
	gui: BillboardGui,
	label: TextLabel,
	t: number,
	life: number,
	big: boolean,
	active: boolean,
}
local numbers: { Number } = {}
local numberFree: { Number } = {}

local function newNumber(): Number
	local att = Instance.new("Attachment")
	att.Name = "FxNumber"
	att.Parent = workspace.Terrain
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(140, 48)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 200
	gui.Enabled = false
	gui.Parent = att
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.fromRGB(60, 36, 20)
	label.Parent = gui
	return { att = att, gui = gui, label = label, t = 0, life = 0.7, big = false, active = false }
end

local function showNumber(x: number, z: number, text: string, color: Color3, big: boolean)
	local n: Number
	if #numbers >= CAP.hit then
		n = table.remove(numbers, 1) :: Number -- recycle oldest
	elseif #numberFree > 0 then
		n = table.remove(numberFree) :: Number
	else
		n = newNumber()
	end
	n.att.Position = Vector3.new(x + (math.random() - 0.5) * 1.5, 3, z + (math.random() - 0.5) * 1.5)
	n.label.Text = text
	n.label.TextColor3 = color
	n.label.TextTransparency = 0
	n.label.TextStrokeTransparency = 0
	n.gui.Size = if big then UDim2.fromOffset(200, 70) else UDim2.fromOffset(130, 44)
	n.gui.StudsOffset = Vector3.zero
	n.gui.Enabled = true
	n.t = 0
	n.life = if big then 0.9 else 0.65
	n.big = big
	n.active = true
	table.insert(numbers, n)
end

local function updateNumbers(dt: number)
	local i = 1
	while i <= #numbers do
		local n = numbers[i]
		n.t += dt
		local f = n.t / n.life
		if f >= 1 then
			n.gui.Enabled = false
			n.active = false
			table.remove(numbers, i)
			table.insert(numberFree, n)
		else
			n.gui.StudsOffset = Vector3.new(0, 2.5 * (1 - (1 - f) ^ 2), 0)
			local fade = math.clamp((f - 0.6) / 0.4, 0, 1)
			n.label.TextTransparency = fade
			n.label.TextStrokeTransparency = fade
			if n.big then
				local pop = 1 + 0.35 * math.max(0, 1 - f * 5)
				n.gui.Size = UDim2.fromOffset(200 * pop, 70 * pop)
			end
			i += 1
		end
	end
end

----------------------------------------------------------------------
-- Telegraphs
----------------------------------------------------------------------

local function onTele(ev: any)
	local shape = ev.shape
	local x, z = num(ev.x, 0), num(ev.z, 0)
	local r = math.max(0.5, num(ev.r, 4))
	local delay = math.clamp(num(ev.delay, 1), 0.05, 10)
	local t = 0
	local parts: { BasePart } = {}
	local updateFill: (f: number) -> ()

	if shape == "line" then
		local dx, dz = flatDir(ev.dx, ev.dz)
		local len = math.max(1, num(ev.len, r * 4))
		local width = math.max(2, r * 2)
		local rim = getPart(Enum.PartType.Block, Vector3.new(width, 0.12, len), COLORS.red, 0.65, false)
		local fill = getPart(Enum.PartType.Block, Vector3.new(width, 0.16, 0.1), COLORS.red, 0.4, false)
		local yaw = math.atan2(-dx, -dz)
		local base = CFrame.new(x, GROUND_Y, z) * CFrame.Angles(0, yaw, 0)
		rim.CFrame = base * CFrame.new(0, 0, -len / 2)
		parts = { rim, fill }
		updateFill = function(f)
			local l = math.max(0.1, len * f)
			fill.Size = Vector3.new(width, 0.16, l)
			fill.CFrame = base * CFrame.new(0, 0.02, -l / 2)
		end
	elseif shape == "cone" then
		local dx, dz = flatDir(ev.dx, ev.dz)
		local angle = toRadians(ev.angle, 60)
		local rays = if LOW then 5 else 9
		local rim = fanParts(dx, dz, r, angle, rays, COLORS.red, 0.7)
		local fill = fanParts(dx, dz, r, angle, rays, COLORS.red, 0.45)
		placeFan(rim, x, z, r)
		for _, p in rim do
			table.insert(parts, p)
		end
		for _, p in fill do
			table.insert(parts, p)
		end
		updateFill = function(f)
			placeFan(fill, x, z, r * f)
		end
	else -- circle (default)
		local rim = getPart(Enum.PartType.Cylinder, Vector3.new(0.12, 2 * r, 2 * r), COLORS.red, 0.65, false)
		rim.CFrame = discCFrame(x, z)
		local fill = getPart(Enum.PartType.Cylinder, Vector3.new(0.16, 0.1, 0.1), COLORS.red, 0.4, false)
		parts = { rim, fill }
		updateFill = function(f)
			local d = math.max(0.1, 2 * r * f)
			fill.Size = Vector3.new(0.16, d, d)
			fill.CFrame = discCFrame(x, z, GROUND_Y + 0.02)
		end
	end

	updateFill(0)
	local function kill()
		for _, p in parts do
			putPart(p)
		end
		table.clear(parts)
	end
	addEffect({
		tag = "tele",
		update = function(dt)
			t += dt
			local f = math.min(t / delay, 1)
			updateFill(f)
			if t >= delay + 0.12 then
				kill()
				return false
			elseif f >= 1 then
				for _, p in parts do
					p.Transparency = 0.2 -- brief "it's happening" flash
				end
			end
			return true
		end,
		kill = kill,
	})
end

----------------------------------------------------------------------
-- Down / revive indicators
----------------------------------------------------------------------

type DownTag = { gui: BillboardGui, ring: BasePart, userId: number, t: number }
local downTags: { [number]: DownTag } = {}

local function removeDown(userId: number)
	local d = downTags[userId]
	if d then
		d.gui:Destroy()
		putPart(d.ring)
		downTags[userId] = nil
	end
end

local function onDown(ev: any)
	local userId = tonumber(ev.id)
	if not userId or downTags[userId] then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(200, 64)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0.6, 0)
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.Text = "💫 DOWN!"
	title.TextColor3 = Color3.fromRGB(255, 90, 80)
	title.TextStrokeTransparency = 0
	title.Parent = gui
	local sub = Instance.new("TextLabel")
	sub.BackgroundTransparency = 1
	sub.Position = UDim2.fromScale(0, 0.6)
	sub.Size = UDim2.new(1, 0, 0.4, 0)
	sub.Font = Enum.Font.GothamBold
	sub.TextScaled = true
	sub.Text = if userId == State.localUserId() then "Hang on!" else "Stand close to revive"
	sub.TextColor3 = Color3.fromRGB(255, 244, 214)
	sub.TextStrokeTransparency = 0.2
	sub.Parent = gui
	local root = characterRoot(userId)
	gui.Adornee = root
	gui.Parent = getFolder()
	-- Revive radius ring (GDD: 8 studs).
	local ring = getPart(Enum.PartType.Cylinder, Vector3.new(0.12, 16, 16), COLORS.green, 0.7, true)
	downTags[userId] = { gui = gui, ring = ring, userId = userId, t = 0 }
end

local function updateDownTags(dt: number)
	for userId, d in downTags do
		d.t += dt
		local root = characterRoot(userId)
		if root then
			if d.gui.Adornee ~= root then
				d.gui.Adornee = root
			end
			d.ring.CFrame = discCFrame(root.Position.X, root.Position.Z)
			d.ring.Transparency = 0.6 + 0.2 * math.sin(d.t * 6)
		else
			d.ring.CFrame = PARK
		end
	end
end

----------------------------------------------------------------------
-- Orbiting blades (Filet's cleavers): {t="orbit", id, n, r, blade, omega, t0}
-- Blade i sits at angle omega * (t - t0) + i * 2pi / n around the owner.
----------------------------------------------------------------------

type Orbit = {
	n: number,
	r: number,
	blade: number,
	omega: number,
	t0: number?,
	localStart: number,
	lastAt: number,
	blades: { BasePart },
}
local orbits: { [number]: Orbit } = {}
local ORBIT_TIMEOUT = 12 -- server refreshes every ~5 s while orbiters exist

local function removeOrbit(id: number)
	local o = orbits[id]
	if o then
		for _, b in o.blades do
			putPart(b)
		end
		orbits[id] = nil
	end
end

local function onOrbit(ev: any)
	local id = tonumber(ev.id)
	if not id then
		return
	end
	local n = math.clamp(math.floor(num(ev.n, 0)), 0, 12)
	if n <= 0 then
		removeOrbit(id)
		return
	end
	local r = math.max(1, num(ev.r, 6))
	local blade = math.clamp(num(ev.blade, 1), 0.4, 6)
	local omega = num(ev.omega, 3)
	local o = orbits[id]
	if o and o.n == n and o.blade == blade then
		o.r, o.omega, o.t0, o.lastAt = r, omega, tonumber(ev.t0), os.clock()
		return
	end
	removeOrbit(id)
	local blades = {}
	for i = 1, n do
		blades[i] = getPart(
			Enum.PartType.Block,
			Vector3.new(0.35, 0.3, blade * 2),
			Color3.fromRGB(225, 225, 240),
			0,
			false
		)
	end
	orbits[id] = {
		n = n,
		r = r,
		blade = blade,
		omega = omega,
		t0 = tonumber(ev.t0),
		localStart = os.clock(),
		lastAt = os.clock(),
		blades = blades,
	}
end

-- Uses the server's t0 when it shares the GetServerTimeNow clock base, else a local phase.
local function orbitBase(o: Orbit, now: number): number
	local t0 = o.t0
	if t0 then
		local sn = State.serverNow()
		if math.abs(sn - t0) < 86400 then
			return o.omega * (sn - t0)
		end
	end
	return o.omega * (now - o.localStart)
end

----------------------------------------------------------------------
-- Event dispatch
----------------------------------------------------------------------

local handlers: { [string]: (any) -> () } = {
	proj = onProj,
	hit = function(ev)
		local amount = num(ev.amount, 0)
		if amount <= 0 then
			return
		end
		local crit = ev.crit == true
		local text = if amount < 10 and amount ~= math.floor(amount)
			then string.format("%.1f", amount)
			else tostring(math.floor(amount + 0.5))
		if crit then
			text ..= "!"
		end
		showNumber(
			num(ev.x, 0),
			num(ev.z, 0),
			text,
			if crit then Color3.fromRGB(255, 220, 40) else COLORS.white,
			crit
		)
	end,
	heal = function(ev)
		local amount = num(ev.amount, 0)
		if amount <= 0 then
			return
		end
		local x, z = num(ev.x, 0), num(ev.z, 0)
		if ev.x == nil and ev.id then
			local root = characterRoot(num(ev.id, 0))
			if root then
				x, z = root.Position.X, root.Position.Z
			end
		end
		showNumber(x, z, "+" .. tostring(math.floor(amount + 0.5)), COLORS.green, false)
	end,
	die = function(ev)
		local x, z = num(ev.x, 0), num(ev.z, 0)
		local h = horde()
		if h and h.kill and ev.id ~= nil then
			h.kill(tonumber(ev.id))
		end
		spawnCrumbs(x, z, CRUMBS_PER_DEATH)
		if not LOW or #effects < CAP.effects / 2 then
			expandingBall(x, 1.2, z, 1.6, COLORS.cream, 0.25, 0.35)
		end
	end,
	tele = onTele,
	slam = function(ev)
		local x, z, r = num(ev.x, 0), num(ev.z, 0), math.max(1, num(ev.r, 6))
		expandingDisc(x, z, r, COLORS.brown, 0.35, 0.25)
		expandingDisc(x, z, r * 0.7, COLORS.cream, 0.25, 0.4)
		spawnCrumbs(x, z, if LOW then 3 else 8, COLORS.brown)
		shake(x, z, math.clamp(r / 6, 0.4, 1.5))
	end,
	boom = function(ev)
		local x, z, r = num(ev.x, 0), num(ev.z, 0), math.max(1, num(ev.r, 5))
		expandingBall(x, 1, z, r, COLORS.orange, 0.3, 0.15)
		expandingDisc(x, z, r * 1.1, COLORS.cheese, 0.3, 0.4)
		shake(x, z, math.clamp(r / 8, 0.3, 1.2))
	end,
	pickup = onPickup,
	pickupTaken = onPickupTaken,
	orbit = onOrbit,
	projEnd = function(ev)
		if ev.id ~= nil then
			releaseProj(ev.id)
		end
	end,
	hurt = function(ev)
		local amount = num(ev.amount, 0)
		if amount <= 0 then
			return
		end
		local x, z = num(ev.x, 0), num(ev.z, 0)
		local id = tonumber(ev.id)
		if ev.x == nil and id then
			local root = characterRoot(id)
			if root then
				x, z = root.Position.X, root.Position.Z
			end
		end
		showNumber(x, z, "-" .. tostring(math.floor(amount + 0.5)), COLORS.red, id == State.localUserId())
	end,
	dead = function(ev)
		local id = tonumber(ev.id)
		if id then
			removeDown(id)
			removeOrbit(id)
		end
	end,
	clear = function(_ev)
		FxController.clearWorld()
	end,
	chain = function(ev)
		local a = Vector3.new(num(ev.x1, 0), PROJ_Y, num(ev.z1, 0))
		local b = Vector3.new(num(ev.x2, 0), PROJ_Y, num(ev.z2, 0))
		local len = (b - a).Magnitude
		if len < 0.1 then
			return
		end
		local p = getPart(
			Enum.PartType.Block,
			Vector3.new(0.25, 0.25, len),
			Color3.fromRGB(150, 220, 255),
			0.1,
			true
		)
		p.CFrame = CFrame.lookAt(a, b) * CFrame.new(0, 0, -len / 2)
		local t = 0
		local function kill()
			putPart(p)
		end
		addEffect({
			update = function(dt)
				t += dt
				p.Transparency = 0.1 + 0.9 * math.min(t / 0.15, 1)
				if t >= 0.15 then
					kill()
					return false
				end
				return true
			end,
			kill = kill,
		})
	end,
	boss = function(ev)
		local x, z = num(ev.x, 0), num(ev.z, 0)
		expandingDisc(x, z, 14, COLORS.red, 0.6, 0.3)
		expandingBall(x, 2, z, 6, COLORS.cream, 0.5, 0.4)
		shake(x, z, 1.4)
	end,
	bossPhase = function(ev)
		local x, z = num(ev.x, 0), num(ev.z, 0)
		expandingDisc(x, z, 16, COLORS.red, 0.5, 0.2)
		shake(x, z, 1.2)
		showNumber(x, z, "ENRAGED!", COLORS.red, true)
	end,
	minion = function(ev)
		expandingBall(num(ev.x, 0), 1, num(ev.z, 0), 2.5, COLORS.cream, 0.3, 0.3)
	end,
	fizzle = function(ev)
		local x, z = num(ev.x, 0), num(ev.z, 0)
		expandingBall(x, 2, z, 4, Color3.fromRGB(190, 120, 240), 0.35, 0.4)
		showNumber(x, z, "fizzle…", Color3.fromRGB(210, 170, 255), false)
	end,
	roulette = function(ev)
		local h = horde()
		local x, z = nil, nil
		if h and h.position then
			x, z = h.position(tonumber(ev.id) or -1)
		end
		if x and z then
			local spell = tostring(ev.spell or "?"):gsub("_", " ")
			showNumber(x, z, "🎲 " .. spell, Color3.fromRGB(210, 170, 255), true)
		end
	end,
	down = onDown,
	revive = function(ev)
		local userId = tonumber(ev.id)
		if not userId then
			return
		end
		removeDown(userId)
		local root = characterRoot(userId)
		if root then
			local p = root.Position
			expandingDisc(p.X, p.Z, 8, COLORS.green, 0.5, 0.3)
			showNumber(p.X, p.Z, "Revived!", COLORS.green, true)
		end
	end,
	ability = function(ev)
		local x, z = num(ev.x, 0), num(ev.z, 0)
		local r = num(ev.r, 0)
		if r <= 0.5 then
			r = 4
		end
		local color = ABILITY_COLORS[tostring(ev.kind)] or COLORS.cheese
		expandingDisc(x, z, r, color, 0.4, 0.3)
		if ev.kind == "burst" or ev.kind == "field" then
			expandingBall(x, 1, z, r * 0.6, color, 0.3, 0.5)
		end
	end,
	melee = function(ev)
		local x, z = num(ev.x, 0), num(ev.z, 0)
		local dx, dz = flatDir(ev.dx, ev.dz)
		local r = math.max(1, num(ev.r, 6))
		local arc = toRadians(ev.arc, 120)
		local parts = fanParts(dx, dz, r, arc, if LOW then 3 else 6, COLORS.cream, 0.35)
		placeFan(parts, x, z, r)
		local t = 0
		local life = 0.18
		local function kill()
			for _, p in parts do
				putPart(p)
			end
			table.clear(parts)
		end
		addEffect({
			update = function(dt)
				t += dt
				local f = math.min(t / life, 1)
				for _, p in parts do
					p.Transparency = 0.35 + 0.65 * f
				end
				if f >= 1 then
					kill()
					return false
				end
				return true
			end,
			kill = kill,
		})
	end,
}

local warned: { [string]: boolean } = {}

local function onFx(batch: any)
	if type(batch) ~= "table" then
		return
	end
	for _, ev in batch do
		if type(ev) == "table" then
			local h = handlers[tostring(ev.t)]
			if h then
				local ok, err = pcall(h, ev)
				if not ok and not warned[tostring(ev.t)] then
					warned[tostring(ev.t)] = true
					warn("[Trunkfall] Fx '" .. tostring(ev.t) .. "' failed: " .. tostring(err))
				end
			end
		end
	end
end

----------------------------------------------------------------------
-- Frame update
----------------------------------------------------------------------

local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

local function render(dt: number)
	local count = 0
	local now = os.clock()

	for key, pr in projs do
		pr.ttl -= dt
		if pr.ttl <= 0 then
			releaseProj(key)
		else
			pr.x += pr.vx * dt
			pr.z += pr.vz * dt
			count += 1
			moveParts[count] = pr.part
			moveCFrames[count] = CFrame.new(pr.x, PROJ_Y, pr.z)
		end
	end

	local i = 1
	while i <= #crumbs do
		local c = crumbs[i]
		c.t += dt
		if c.t >= c.life then
			putPart(c.part)
			crumbs[i] = crumbs[#crumbs]
			crumbs[#crumbs] = nil
		else
			c.vy -= GRAVITY * dt
			c.x += c.vx * dt
			c.y = math.max(0.2, c.y + c.vy * dt)
			c.z += c.vz * dt
			local f = c.t / c.life
			if f > 0.6 then
				c.part.Transparency = (f - 0.6) / 0.4
			end
			count += 1
			moveParts[count] = c.part
			moveCFrames[count] = CFrame.new(c.x, c.y, c.z)
				* CFrame.Angles(c.t * c.spin, c.t * c.spin * 0.7, 0)
			i += 1
		end
	end

	for key, pk in pickups do
		if pk.flying then
			pk.t += dt
			local f = math.min(pk.t / 0.25, 1)
			local root = if pk.target then characterRoot(pk.target) else nil
			if root == nil or f >= 1 then
				releasePickup(key)
				continue
			end
			local tp = root.Position
			local e = f * f
			local x = pk.fromX + (tp.X - pk.fromX) * e
			local y = pk.fromY + (tp.Y - pk.fromY) * e + math.sin(f * math.pi) * 2
			local z = pk.fromZ + (tp.Z - pk.fromZ) * e
			count += 1
			moveParts[count] = pk.part
			moveCFrames[count] = CFrame.new(x, y, z) * CFrame.Angles(0, now * 12, 0)
		else
			count += 1
			moveParts[count] = pk.part
			moveCFrames[count] = CFrame.new(pk.x, 0.8 + math.sin(now * 4 + pk.phase) * 0.25, pk.z)
				* CFrame.Angles(0, now * 3 + pk.phase, math.rad(15))
		end
	end

	for id, o in orbits do
		if os.clock() - o.lastAt > ORBIT_TIMEOUT then
			removeOrbit(id)
			continue
		end
		local root = characterRoot(id)
		if root then
			local pos = root.Position
			local base = orbitBase(o, now)
			for i, b in o.blades do
				local a = base + (i - 1) * math.pi * 2 / o.n
				local bx, bz = pos.X + math.cos(a) * o.r, pos.Z + math.sin(a) * o.r
				count += 1
				moveParts[count] = b
				moveCFrames[count] = CFrame.new(bx, 2, bz) * CFrame.Angles(0, now * 12 + i, 0)
			end
		end
	end

	for j = #moveParts, count + 1, -1 do
		moveParts[j] = nil
		moveCFrames[j] = nil
	end
	if count > 0 then
		workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end

	local k = 1
	while k <= #effects do
		local ok, alive = pcall(effects[k].update, dt)
		if ok and alive then
			k += 1
		else
			if not ok then
				pcall(effects[k].kill)
			end
			table.remove(effects, k)
		end
	end

	updateNumbers(dt)
	updateDownTags(dt)
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

-- Clears world-bound effects (pickups, projectiles, telegraphs, down tags).
function FxController.clearWorld()
	for key in projs do
		releaseProj(key)
	end
	for key in pickups do
		releasePickup(key)
	end
	for _, c in crumbs do
		putPart(c.part)
	end
	table.clear(crumbs)
	for _, e in effects do
		pcall(e.kill)
	end
	table.clear(effects)
	for userId in downTags do
		removeDown(userId)
	end
	for id in orbits do
		removeOrbit(id)
	end
end

-- Lets other client code play a local effect, e.g. FxController.play({t = "boom", x = 0, z = 0, r = 5}).
function FxController.play(ev: any)
	onFx({ ev })
end

local connections: { any } = {}
local bound = false

function FxController.init()
	if bound then
		return
	end
	bound = true
	getFolder()
	table.insert(connections, Remotes.on(Remotes.S2C.Fx, onFx))
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 3, render)

	local lastPhase: string? = nil
	table.insert(connections, {
		Disconnect = State.subscribe("run", function(run)
			local phase = if type(run) == "table" then run.phase else nil
			if phase ~= lastPhase then
				lastPhase = phase
				if phase ~= "Waves" and phase ~= "Boss" and phase ~= "StageClear" then
					FxController.clearWorld()
				end
			end
		end),
	})
	-- PartyHud is authoritative for "downed": drop stale tags.
	table.insert(connections, {
		Disconnect = State.subscribe("party", function(party)
			if type(party) ~= "table" then
				return
			end
			for userId in downTags do
				local entry = party[userId]
				if entry == nil or entry.downed ~= true then
					removeDown(userId)
				end
			end
		end),
	})
end

function FxController.destroy()
	for _, c in connections do
		c.Disconnect()
	end
	table.clear(connections)
	if bound then
		RunService:UnbindFromRenderStep(BIND_NAME)
		bound = false
	end
	FxController.clearWorld()
	for _, n in numbers do
		n.att:Destroy()
	end
	for _, n in numberFree do
		n.att:Destroy()
	end
	table.clear(numbers)
	table.clear(numberFree)
	if folder then
		folder:Destroy()
		folder = nil
	end
	table.clear(partPools)
end

return FxController
