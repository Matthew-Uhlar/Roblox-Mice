--!strict
-- Renders Net.S2C.Fx batches ({FxEvent}) as local, pooled visuals.
-- Every event type in docs/COMBAT-API.md has a handler (see `handlers` below;
-- FxController.handledTypes() lists them):
--   contract: proj, hit, die, tele, slam, pickup, pickupTaken, boom, down,
--             revive, ability, melee (+ heal if the server sends it)
--   added:    projEnd, strike, hurt, dead, zone, orbit, chain, boss, bossPhase,
--             minion, dash, leap, blink, roulette, adapt, fizzle, surge, clear,
--             enrage (boss enrage after 120 s: red pulsing aura + banner)
--   POIs / portal (Team G2, GDD §3.8 / §3.9):
--     poi          pooled ground ring + progress fill per POI (kind colour; dim when
--                  the waves are not running, grey when done)
--     poiProgress  grows the fill (10% steps from the server, eased here)
--     poiDone      burst + floating label (cheese, buff name, chest, Epic pick, ...)
--     trap         Mousetrap snap: small shockwave (its telegraph is a normal `tele`)
--     portal       open: spinning motes over the Rind Gate in its colour; pull: the
--                  motes spiral into your hero and the screen fades to black for the
--                  next arena (held until the Waves phase, max 6 s); close: removed
-- Ground zones (boss puddles, dash trails, player puddles / fields / rings)
-- are pooled discs with a ring edge: hostile ones red or purple, friendly ones
-- in the owner's class colour, following the owner when `follow`, fading out
-- at `ttl`. Everything is pooled and capped harder on mobile. Parts are
-- anchored, non-colliding and non-queryable; moving parts go through one
-- BulkMoveTo.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Remotes = require(Client.Util.Remotes)
local Device = require(Client.Util.Device)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local State = require(script.Parent.State)

local FxController = {}

local LOW = Device.lowSpec()
local CAP = {
	proj = if LOW then 160 else 400,
	hit = if LOW then 18 else 40,
	crumbs = if LOW then 50 else 180,
	pickups = if LOW then 120 else 320,
	effects = if LOW then 60 else 160,
	zones = if LOW then 16 else 48, -- friendly zones are evicted first; hostile ones may exceed this
	zonesHard = if LOW then 32 else 96,
	pois = if LOW then 16 else 24, -- POI ground markers (a stage has at most 12)
	portalMotes = if LOW then 6 else 12,
	pullMotes = if LOW then 8 else 16,
}
local CRUMBS_PER_DEATH = if LOW then 2 else 5
local PROJ_Y = 2.5
local GROUND_Y = 0.08
local GRAVITY = 70
local PARK = CFrame.new(0, -5000, 0)
local BIND_NAME = "TrunkfallFx"

local COLORS = {
	danger = Color3.fromRGB(255, 75, 62), -- STYLE.md danger telegraph #FF4B3E
	curse = Color3.fromRGB(142, 92, 247), -- STYLE.md curse purple #8E5CF7
	strike = Color3.fromRGB(255, 130, 60),
	shadow = Color3.fromRGB(30, 20, 15),
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

-- Cone / arc angles are full angles in degrees (COMBAT-API: telegraph cone
-- `angle`, strike `angle`, melee `arc`).
local function toRadians(a: any, defaultDeg: number): number
	return math.rad(math.clamp(num(a, defaultDeg), 1, 360))
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

-- Bot teammates (ids <= -1000, Shared.Util.Ids) live as server-built models
-- under workspace.Bots, tagged with a BotId attribute and named "Bot_<-id>"
-- (BotService).
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
	local byName = "Bot_" .. tostring(-id)
	for _, m in bots:GetChildren() do
		local attr = m:GetAttribute("BotId")
		if (attr ~= nil and tonumber(attr) == id) or m.Name == byName then
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

-- tag "hostile": boss / enemy visuals removed by the `clear` event.
type Effect = { update: (dt: number) -> boolean, kill: () -> (), tag: string? }
local effects: { Effect } = {}
-- Effects added while `effects` is being updated (e.g. dust puffs spawned by a
-- dash effect) wait here, so the update loop never sees the list shift.
local pendingEffects: { Effect } = {}
local updatingEffects = false

local function addEffect(e: Effect)
	if updatingEffects then
		if #pendingEffects + #effects >= CAP.effects then
			e.kill()
			return
		end
		table.insert(pendingEffects, e)
		return
	end
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

type Proj = { part: BasePart, x: number, z: number, vx: number, vz: number, ttl: number, hostile: boolean }
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
		hostile = hostile,
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
-- Ground zones: {t="zone", id, kind, x, z, r, ttl, owner?, follow?, hostile?}
-- A translucent disc plus a ring edge (CylinderHandleAdornment with an inner
-- radius). Hostile zones (boss puddles, dash trails) are red, or curse purple
-- for cursed kinds, and pulse; friendly zones use the owner's class colour.
----------------------------------------------------------------------

local HOSTILE_ZONE_FILL: { [string]: Color3 } = {
	gorgonzola = COLORS.curse, -- mouldy cheese trail
	cauldron = COLORS.curse, -- witch's brew
}
local HOSTILE_ZONE_RIM: { [string]: Color3 } = {
	ice = Color3.fromRGB(170, 225, 255),
	mustard = Color3.fromRGB(255, 200, 40),
	rust = Color3.fromRGB(150, 70, 35),
	soup = Color3.fromRGB(255, 140, 40),
	gorgonzola = Color3.fromRGB(90, 40, 170),
	cauldron = Color3.fromRGB(90, 40, 170),
}
local FRIENDLY_ZONE_FALLBACK: { [string]: Color3 } = {
	puddle = Color3.fromRGB(90, 185, 255),
	ring = Color3.fromRGB(120, 210, 90),
	fire = Color3.fromRGB(255, 120, 40),
	soda = Color3.fromRGB(190, 120, 240),
}
local ZONE_FADE_IN = 0.2
local ZONE_FADE_OUT = 0.35
local RIM_WIDTH = 0.45

type Zone = {
	id: any,
	seq: number,
	fill: BasePart,
	rim: CylinderHandleAdornment?,
	x: number,
	z: number,
	r: number,
	y: number,
	owner: number?,
	follow: boolean,
	hostile: boolean,
	mine: boolean,
	t: number,
	ttl: number,
	fillAlpha: number,
	rimAlpha: number,
}
local zones: { [any]: Zone } = {}
local zoneCount = 0
local zoneSeq = 0
local rimPool: { CylinderHandleAdornment } = {}
local rimAnchor: BasePart? = nil
local rimSupported = true

-- Invisible part at the origin that every ring adornment hangs off, so an
-- adornment's CFrame is its world CFrame.
local function getRimAnchor(): BasePart
	if rimAnchor and rimAnchor.Parent then
		return rimAnchor
	end
	local p = Instance.new("Part")
	p.Name = "ZoneAnchor"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.one * 0.1
	p.CFrame = CFrame.identity
	p.Parent = getFolder()
	rimAnchor = p
	return p
end

local function getRim(color: Color3, alpha: number): CylinderHandleAdornment?
	if not rimSupported then
		return nil
	end
	local a = table.remove(rimPool)
	if not a then
		local ok, made = pcall(function()
			local n = Instance.new("CylinderHandleAdornment")
			n.Name = "ZoneRim"
			n.Height = 0.14
			n.AlwaysOnTop = false
			n.ZIndex = 1
			n.InnerRadius = 0
			n.Adornee = getRimAnchor()
			n.Parent = getFolder()
			return n
		end)
		if not ok then
			rimSupported = false -- engine without InnerRadius: the disc alone still shows the zone
			return nil
		end
		a = made
	end
	local rim = a :: CylinderHandleAdornment
	rim.Color3 = color
	rim.Transparency = alpha
	rim.Visible = true
	return rim
end

local function putRim(a: CylinderHandleAdornment)
	a.Visible = false
	table.insert(rimPool, a)
end

-- Class colour of a party member (PartyHud, else Lobby), or nil.
local function memberColor(id: number?): Color3?
	if id == nil then
		return nil
	end
	local classId = nil
	local party = State.get("party")
	if type(party) == "table" and type(party[id]) == "table" then
		classId = party[id].classId
	end
	if classId == nil then
		local lobby = State.get("lobby")
		local players = if type(lobby) == "table" then lobby.players else nil
		if type(players) == "table" and type(players[id]) == "table" then
			classId = players[id].classId
		end
	end
	local def = if classId ~= nil then Defs.get("Classes", classId) else nil
	if def and def.color then
		return Format.rgb(def.color)
	end
	return nil
end

local function placeZone(zn: Zone, radius: number)
	local d = math.max(0.2, radius * 2)
	zn.fill.Size = Vector3.new(0.1, d, d)
	local rim = zn.rim
	if rim then
		rim.Radius = math.max(0.2, radius)
		rim.InnerRadius = math.max(0, radius - RIM_WIDTH)
		rim.CFrame = CFrame.new(zn.x, zn.y + 0.02, zn.z) * CFrame.Angles(math.pi / 2, 0, 0)
	end
end

local function releaseZone(id: any)
	local zn = zones[id]
	if not zn then
		return
	end
	putPart(zn.fill)
	if zn.rim then
		putRim(zn.rim)
	end
	zones[id] = nil
	zoneCount -= 1
end

-- Frees one slot: teammates' friendly zones first, then our own, then the
-- oldest hostile one (only past the hard cap).
local function evictZone(allowHostile: boolean): boolean
	local best: Zone? = nil
	local bestRank = math.huge
	for _, zn in zones do
		local rank = if zn.hostile then 2 elseif zn.mine then 1 else 0
		if (allowHostile or not zn.hostile) and (rank * 1e9 + zn.seq) < bestRank then
			best = zn
			bestRank = rank * 1e9 + zn.seq
		end
	end
	if best then
		releaseZone(best.id)
		return true
	end
	return false
end

local function onZone(ev: any)
	local id = ev.id
	if id == nil then
		zoneSeq += 1
		id = "z" .. zoneSeq
	end
	local x, z = num(ev.x, 0), num(ev.z, 0)
	local r = math.clamp(num(ev.r, 4), 0.5, 80)
	local ttl = math.clamp(num(ev.ttl, 3), 0.1, 60)
	local existing = zones[id]
	if existing then -- re-sent: refresh in place
		existing.x, existing.z, existing.r = x, z, r
		existing.ttl = existing.t + ttl
		placeZone(existing, r)
		return
	end
	local hostile = ev.hostile == true
	local owner = tonumber(ev.owner)
	if not hostile and zoneCount >= CAP.zones and not evictZone(false) then
		return -- full of hostile zones: friendly visuals are the ones to skip
	end
	if hostile and zoneCount >= CAP.zonesHard then
		evictZone(true)
	end
	local kind = tostring(ev.kind or "")
	local mine = owner ~= nil and owner == State.localUserId()
	local fillColor: Color3
	local rimColor: Color3
	local fillAlpha: number
	local rimAlpha: number
	if hostile then
		fillColor = HOSTILE_ZONE_FILL[kind] or COLORS.danger
		rimColor = HOSTILE_ZONE_RIM[kind] or Color3.fromRGB(200, 30, 30)
		fillAlpha, rimAlpha = 0.5, 0.15
	else
		fillColor = memberColor(owner) or FRIENDLY_ZONE_FALLBACK[kind] or COLORS.cheese
		rimColor = fillColor:Lerp(COLORS.white, 0.35)
		-- Own zones read clearly; teammates' stay subtle so the field doesn't drown.
		fillAlpha = if mine then 0.72 else 0.82
		rimAlpha = if mine then 0.3 else 0.5
	end
	zoneSeq += 1
	local fill = getPart(Enum.PartType.Cylinder, Vector3.new(0.1, 0.2, 0.2), fillColor, 1, hostile)
	local zn: Zone = {
		id = id,
		seq = zoneSeq,
		fill = fill,
		rim = getRim(rimColor, 1),
		x = x,
		z = z,
		r = r,
		-- Stagger heights so overlapping translucent discs don't z-fight; hostile on top.
		y = GROUND_Y + 0.01 + (zoneSeq % 6) * 0.004 + (if hostile then 0.03 else 0),
		owner = owner,
		follow = ev.follow == true and owner ~= nil,
		hostile = hostile,
		mine = mine,
		t = 0,
		ttl = ttl,
		fillAlpha = fillAlpha,
		rimAlpha = rimAlpha,
	}
	zones[id] = zn
	zoneCount += 1
	placeZone(zn, r * 0.6)
end

local function zoneAt(zn: Zone): (number, number)
	if zn.follow and zn.owner then
		local root = characterRoot(zn.owner)
		if root then
			local p = root.Position
			zn.x, zn.z = p.X, p.Z
		end
	end
	return zn.x, zn.z
end

-- Per-frame zone update. Appends moving discs to the BulkMoveTo lists.
local function updateZones(
	dt: number,
	now: number,
	parts: { BasePart },
	cframes: { CFrame },
	count: number
): number
	for id, zn in zones do
		zn.t += dt
		if zn.t >= zn.ttl then
			releaseZone(id)
			continue
		end
		local grow = math.min(zn.t / ZONE_FADE_IN, 1)
		local fade = math.clamp((zn.ttl - zn.t) / ZONE_FADE_OUT, 0, 1) * grow
		local radius = zn.r * (0.6 + 0.4 * (1 - (1 - grow) ^ 2))
		local pulse = if zn.hostile then 0.08 * math.sin(now * 7 + zn.seq) else 0
		zn.fill.Transparency = math.min(1, 1 - (1 - zn.fillAlpha) * fade + pulse)
		local x, z = zoneAt(zn)
		if grow < 1 or zn.follow then
			placeZone(zn, radius)
		end
		local rim = zn.rim
		if rim then
			rim.Transparency = math.min(1, 1 - (1 - zn.rimAlpha) * fade + pulse)
		end
		count += 1
		parts[count] = zn.fill
		cframes[count] = discCFrame(x, z, zn.y)
	end
	return count
end

local function clearZones(hostileOnly: boolean, ownerId: number?)
	for id, zn in zones do
		if (not hostileOnly or zn.hostile) and (ownerId == nil or zn.owner == ownerId) then
			releaseZone(id)
		end
	end
end

----------------------------------------------------------------------
-- Boss movement, strikes and surges
----------------------------------------------------------------------

local function bossPos(id: any): (number?, number?)
	local h = horde()
	if h and h.position and tonumber(id) then
		return h.position(tonumber(id) :: number)
	end
	return nil, nil
end

-- Pattern ids like "spider_stomp" -> "Spider Stomp".
local function pretty(s: any): string
	local text = tostring(s or ""):gsub("_", " ")
	return (text:gsub("(%a)([%w']*)", function(a: string, b: string)
		return string.upper(a) .. b
	end))
end

-- A short-lived effect that runs `step(t, dt)` for `life` seconds, then
-- `onEnd(true)`; if it is cut short (cap, clear) it gets `onEnd(false)`.
local function timed(
	life: number,
	tag: string?,
	step: (t: number, dt: number) -> (),
	onEnd: ((natural: boolean) -> ())?
)
	local t = 0
	local ended = false
	local function finish(natural: boolean)
		if not ended then
			ended = true
			if onEnd then
				onEnd(natural)
			end
		end
	end
	addEffect({
		tag = tag,
		update = function(dt)
			t += dt
			if t >= life then
				finish(true)
				return false
			end
			step(t, dt)
			return true
		end,
		kill = function()
			finish(false)
		end,
	})
end

-- Impact flash where a telegraphed boss strike lands (line / cone / circle).
local function onStrike(ev: any)
	local x, z = num(ev.x, 0), num(ev.z, 0)
	local r = math.max(0.5, num(ev.r, 4))
	local parts: { BasePart } = {}
	local life = 0.25
	if ev.shape == "line" then
		local dx, dz = flatDir(ev.dx, ev.dz)
		local len = math.max(1, num(ev.len, r * 4))
		local width = math.max(2, r * 2)
		local p = getPart(Enum.PartType.Block, Vector3.new(width, 0.3, len), COLORS.strike, 0.1, true)
		p.CFrame = CFrame.new(x, GROUND_Y + 0.15, z)
			* CFrame.Angles(0, math.atan2(-dx, -dz), 0)
			* CFrame.new(0, 0, -len / 2)
		parts = { p }
		shake(x + dx * len / 2, z + dz * len / 2, 0.5)
	elseif ev.shape == "cone" then
		local dx, dz = flatDir(ev.dx, ev.dz)
		parts = fanParts(dx, dz, r, toRadians(ev.angle, 50), if LOW then 4 else 7, COLORS.strike, 0.15)
		placeFan(parts, x, z, r)
		shake(x, z, 0.5)
	else
		local p = getPart(Enum.PartType.Cylinder, Vector3.new(0.3, 2 * r, 2 * r), COLORS.strike, 0.1, true)
		p.CFrame = discCFrame(x, z, GROUND_Y + 0.1)
		parts = { p }
		shake(x, z, math.clamp(r / 8, 0.3, 1))
	end
	local function kill()
		for _, p in parts do
			putPart(p)
		end
		table.clear(parts)
	end
	timed(life, "hostile", function(t)
		local a = 0.1 + 0.9 * (t / life)
		for _, p in parts do
			p.Transparency = a
		end
	end, kill)
end

-- Boss dash: dust puffs behind the boss while it charges (path was telegraphed).
local function onDash(ev: any)
	local id = ev.id
	local dur = math.clamp(num(ev.dur, 0.5), 0.05, 4)
	local dx, dz = flatDir(ev.dx, ev.dz)
	local every = if LOW then 0.14 else 0.06
	local acc = every
	timed(dur, "hostile", function(_t, dt)
		acc += dt
		if acc < every then
			return
		end
		acc = 0
		local bx, bz = bossPos(id)
		if bx and bz then
			expandingBall(bx - dx * 3, 0.8, bz - dz * 3, 1.8, COLORS.cream, 0.35, 0.35)
		end
	end)
	local bx, bz = bossPos(id)
	if bx and bz then
		expandingDisc(bx, bz, 5, COLORS.brown, 0.3, 0.4)
	end
end

-- Boss leap: dust at take-off and a landing shadow that grows until impact.
local function onLeap(ev: any)
	local tx, tz = num(ev.x, 0), num(ev.z, 0)
	local dur = math.clamp(num(ev.dur, 0.9), 0.1, 4)
	local bx, bz = bossPos(ev.id)
	if bx and bz then
		expandingDisc(bx, bz, 6, COLORS.brown, 0.35, 0.35)
		spawnCrumbs(bx, bz, if LOW then 2 else 6, COLORS.brown)
	end
	local shadow = getPart(Enum.PartType.Cylinder, Vector3.new(0.1, 0.2, 0.2), COLORS.shadow, 0.75, false)
	timed(dur, "hostile", function(t)
		local f = t / dur
		local d = math.max(0.2, 2 * (1.5 + 3.5 * f))
		shadow.Size = Vector3.new(0.1, d, d)
		shadow.CFrame = discCFrame(tx, tz, GROUND_Y + 0.06)
		shadow.Transparency = 0.75 - 0.35 * f
	end, function()
		putPart(shadow)
	end)
end

-- Boss blink: purple poof where it vanishes, an imploding ring where it lands.
local function onBlink(ev: any)
	local tx, tz = num(ev.x, 0), num(ev.z, 0)
	local delay = math.clamp(num(ev.delay, 0.9), 0.05, 4)
	local bx, bz = bossPos(ev.id)
	if bx and bz then
		expandingBall(bx, 2, bz, 4, COLORS.curse, 0.35, 0.3)
	end
	local ring = getPart(Enum.PartType.Cylinder, Vector3.new(0.1, 0.2, 0.2), COLORS.curse, 0.6, true)
	timed(delay, "hostile", function(t)
		local f = t / delay
		local d = math.max(0.2, 2 * (9 - 7 * f))
		ring.Size = Vector3.new(0.1, d, d)
		ring.CFrame = discCFrame(tx, tz, GROUND_Y + 0.07)
		ring.Transparency = 0.6 - 0.3 * f
	end, function(natural)
		putPart(ring)
		if natural then
			expandingBall(tx, 2, tz, 3.5, COLORS.curse, 0.3, 0.3)
		end
	end)
end

local lastSurgeToast = -math.huge

-- Wave surge: a banner (throttled) and a small rumble.
local function onSurge(_ev: any)
	local cam = workspace.CurrentCamera
	if cam then
		local f = cam.Focus.Position
		shake(f.X, f.Z, 0.6)
	end
	if os.clock() - lastSurgeToast > 12 then
		lastSurgeToast = os.clock()
		State.toast:Fire("The horde surges! 🐭🐭🐭", "bad")
	end
end

-- Boss enrage ({t="enrage", id, x, z}): a red pulsing aura that follows the
-- boss until it is gone (or `clear` runs), plus a banner. One aura per boss.
local enraged: { [any]: boolean } = {}
local function onEnrage(ev: any)
	local id = ev.id
	local key = tonumber(id) or id or "boss"
	local x, z = num(ev.x, 0), num(ev.z, 0)
	expandingDisc(x, z, 18, COLORS.danger, 0.6, 0.2)
	shake(x, z, 1.2)
	showNumber(x, z, "ENRAGED!", COLORS.danger, true)
	-- No toast here: RunDirector sends the single "enraged: faster attacks" toast.
	if enraged[key] then
		return
	end
	enraged[key] = true
	local disc = getPart(Enum.PartType.Cylinder, Vector3.new(0.1, 0.2, 0.2), COLORS.danger, 0.6, true)
	local glow = getPart(Enum.PartType.Ball, Vector3.one * 0.2, COLORS.danger, 0.85, true)
	local t, missing = 0, 0
	local function stop()
		enraged[key] = nil
		putPart(disc)
		putPart(glow)
	end
	addEffect({
		tag = "hostile",
		update = function(dt)
			t += dt
			local bx, bz = bossPos(id)
			if bx and bz then
				x, z, missing = bx, bz, 0
			else
				missing += dt
				if missing > 1.5 then -- boss died or despawned
					stop()
					return false
				end
			end
			local pulse = 0.5 + 0.5 * math.sin(t * 6)
			local d = 14 + 3 * pulse
			disc.Size = Vector3.new(0.1, d, d)
			disc.CFrame = discCFrame(x, z, GROUND_Y + 0.09)
			disc.Transparency = 0.45 + 0.3 * pulse
			glow.Size = Vector3.one * (10 + 2 * pulse)
			glow.CFrame = CFrame.new(x, 3, z)
			glow.Transparency = 0.8 + 0.12 * pulse
			return true
		end,
		kill = stop,
	})
end

-- Ability auras that stay on the caster: Riposte shield bubble, Updraft hover ring.
local function abilityAura(id: number, kind: string, dur: number, r: number, color: Color3)
	local shape = if kind == "shield" then Enum.PartType.Ball else Enum.PartType.Cylinder
	local p = getPart(shape, Vector3.one * 0.2, color, 0.75, true)
	timed(dur, nil, function(t)
		local root = characterRoot(id)
		if not root then
			p.CFrame = PARK
			return
		end
		local pos = root.Position
		local fade = math.clamp((dur - t) / 0.25, 0, 1)
		if kind == "shield" then
			p.Size = Vector3.one * 7
			p.CFrame = CFrame.new(pos)
			p.Transparency = 1 - 0.3 * fade - 0.05 * math.sin(t * 10)
		else
			local d = math.max(0.2, math.min(r, 6) * 2)
			p.Size = Vector3.new(0.1, d, d)
			p.CFrame = discCFrame(pos.X, pos.Z, GROUND_Y + 0.08)
			p.Transparency = 1 - 0.35 * fade
		end
	end, function()
		putPart(p)
	end)
end

----------------------------------------------------------------------
-- Event dispatch
----------------------------------------------------------------------

----------------------------------------------------------------------
-- Points of interest + portal (Team G2)
----------------------------------------------------------------------

local PoiDefs: any = nil
do
	local ok, mod = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Pois"))
	end)
	if ok then
		PoiDefs = mod
	end
end

local function poiDef(kind: any): any
	if PoiDefs and type(PoiDefs.get) == "function" then
		return PoiDefs.get(tostring(kind))
	end
	return nil
end

local function rgbColor(t: any, fallback: Color3): Color3
	if type(t) == "table" and tonumber(t[1]) and tonumber(t[2]) and tonumber(t[3]) then
		return Color3.fromRGB(
			math.clamp(tonumber(t[1]) :: number, 0, 255),
			math.clamp(tonumber(t[2]) :: number, 0, 255),
			math.clamp(tonumber(t[3]) :: number, 0, 255)
		)
	end
	return fallback
end

type PoiMark = {
	kind: string,
	x: number,
	z: number,
	r: number,
	color: Color3,
	state: string,
	active: boolean,
	p: number, -- server progress 0..1
	shown: number, -- eased progress drawn
	ring: BasePart,
	fill: BasePart,
	dirty: boolean,
}
local poiMarks: { [number]: PoiMark } = {}
local poiCount = 0
local GREY = Color3.fromRGB(150, 150, 150)

local function removePoiMark(id: number)
	local m = poiMarks[id]
	if m then
		poiMarks[id] = nil
		poiCount -= 1
		putPart(m.ring)
		putPart(m.fill)
	end
end

local function clearPoiMarks()
	for id in poiMarks do
		removePoiMark(id)
	end
end

local function drawPoiMark(m: PoiMark)
	local done = m.state == "done"
	local d = math.max(0.2, m.r * 2)
	m.ring.Size = Vector3.new(0.1, d, d)
	m.ring.CFrame = discCFrame(m.x, m.z, GROUND_Y + 0.02)
	m.ring.Color = if done then GREY else m.color
	m.ring.Transparency = if done then 0.93 elseif not m.active then 0.88 else 0.7
	local fd = math.max(0.1, d * math.clamp(m.shown, 0, 1))
	m.fill.Size = Vector3.new(0.12, fd, fd)
	m.fill.CFrame = discCFrame(m.x, m.z, GROUND_Y + 0.04)
	m.fill.Color = m.color
	m.fill.Transparency = if done or m.shown <= 0.01 or not m.active then 1 else 0.45
	m.dirty = false
end

local function onPoi(ev: any)
	local id = tonumber(ev.id)
	if not id then
		return
	end
	local m = poiMarks[id]
	local def = poiDef(ev.kind)
	if not m then
		if poiCount >= CAP.pois then
			return
		end
		local color = if def then rgbColor(def.color, COLORS.cheese) else COLORS.cheese
		m = {
			kind = tostring(ev.kind),
			x = num(ev.x, 0),
			z = num(ev.z, 0),
			r = math.clamp(num(ev.r, 6), 1, 40),
			color = color,
			state = "idle",
			active = false,
			p = 0,
			shown = 0,
			ring = getPart(Enum.PartType.Cylinder, Vector3.new(0.1, 1, 1), color, 0.7, true),
			fill = getPart(Enum.PartType.Cylinder, Vector3.new(0.12, 0.1, 0.1), color, 1, true),
			dirty = true,
		}
		poiMarks[id] = m
		poiCount += 1
	end
	local pm = m :: PoiMark
	if ev.kind ~= nil and tostring(ev.kind) ~= pm.kind then
		-- a new stage reuses ids: start this mark over
		removePoiMark(id)
		onPoi(ev)
		return
	end
	pm.x, pm.z = num(ev.x, pm.x), num(ev.z, pm.z)
	pm.state = if type(ev.state) == "string" then ev.state else pm.state
	pm.active = ev.active == true
	if tonumber(ev.p) then
		pm.p = math.clamp(tonumber(ev.p) :: number, 0, 1)
	end
	pm.dirty = true
end

local function onPoiProgress(ev: any)
	local m = poiMarks[tonumber(ev.id) or -1]
	if m then
		m.p = math.clamp(num(ev.p, 0), 0, 1)
		m.dirty = true
	end
end

local function onPoiDone(ev: any)
	local id = tonumber(ev.id)
	local def = poiDef(ev.kind)
	local x, z = num(ev.x, 0), num(ev.z, 0)
	local color = if def then rgbColor(def.color, COLORS.cheese) else COLORS.cheese
	local r = if def then def.radius else 6
	local m = if id then poiMarks[id] else nil
	if m then
		m.state, m.p, m.dirty = "done", 1, true
	end
	expandingDisc(x, z, r * 1.6, color, 0.6, 0.25)
	expandingBall(x, 2, z, r * 0.6, color, 0.45, 0.4)
	local text = if def then def.name else "!"
	local reward = if def then def.reward else nil
	if reward == "cheese" and tonumber(ev.cheese) then
		text = string.format("+%d 🧀", tonumber(ev.cheese) :: number)
	elseif ev.chest == true then
		text = "Chest! Free upgrade!"
	elseif reward == "crumbs" then
		text = "Crumbs!"
	elseif reward == "epic_pick" then
		text = "EPIC pick!"
	elseif reward == "revive" then
		text = "The Herd returns!"
	end
	showNumber(x, z, text, color, true)
	shake(x, z, 0.4)
end

local function onTrap(ev: any)
	local x, z = num(ev.x, 0), num(ev.z, 0)
	local r = math.max(1, num(ev.r, 3))
	expandingDisc(x, z, r * 1.3, COLORS.brown, 0.3, 0.2)
	expandingBall(x, 0.8, z, r * 0.5, COLORS.cream, 0.2, 0.5)
	shake(x, z, 0.35)
end

local function updatePoiMarks(dt: number)
	for _, m in poiMarks do
		local target = if m.state == "done" then 1 else m.p
		if math.abs(m.shown - target) > 0.002 then
			m.shown += (target - m.shown) * math.min(1, dt * 10)
			m.dirty = true
		end
		if m.dirty then
			drawPoiMark(m)
		end
	end
end

-- Portal ------------------------------------------------------------------------

type Portal = { x: number, z: number, color: Color3, motes: { BasePart }, t: number, pull: number }
local portalFx: Portal? = nil

local function removePortal()
	local pf = portalFx
	if pf then
		portalFx = nil
		for _, p in pf.motes do
			putPart(p)
		end
	end
end

local function ensurePortal(x: number, z: number, color: Color3): Portal
	local pf = portalFx
	if pf and (pf.x - x) ^ 2 + (pf.z - z) ^ 2 < 1 then
		pf.color = color
		for _, p in pf.motes do
			p.Color = color
		end
		return pf
	end
	removePortal()
	local motes = {}
	for _ = 1, CAP.portalMotes do
		table.insert(motes, getPart(Enum.PartType.Ball, Vector3.one * 0.7, color, 0.15, true))
	end
	local np: Portal = { x = x, z = z, color = color, motes = motes, t = 0, pull = 0 }
	portalFx = np
	expandingDisc(x, z, 9, color, 0.7, 0.2)
	return np
end

local function updatePortal(dt: number)
	local pf = portalFx
	if not pf then
		return
	end
	pf.t += dt
	local spin = if pf.pull > 0 then 7 else 2.2
	local n = #pf.motes
	for i, p in pf.motes do
		local a = pf.t * spin + (i - 1) / n * math.pi * 2
		local rr = 5.2 + math.sin(pf.t * 3 + i) * 0.6
		local y = 1.2 + ((pf.t * 1.5 + i / n) % 1) * 6
		p.CFrame = CFrame.new(pf.x + math.cos(a) * rr, y, pf.z + math.sin(a) * rr)
	end
end

-- Screen fade for the pull (black, held until the next arena's Waves phase).
local fadeGui: ScreenGui? = nil
local fadeFrame: Frame? = nil
local fade = { state = "none", t = 0, released = false }
local FADE_IN = 1.2
local FADE_HOLD_MAX = 6
local FADE_OUT = 0.6

local function getFade(): Frame?
	if fadeFrame and fadeFrame.Parent then
		return fadeFrame
	end
	local lp = Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil
	end
	local g = Instance.new("ScreenGui")
	g.Name = "TrunkfallPortalFade"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 12 -- above the HUD (10), below touch controls, upgrades, votes and toasts
	g.Parent = pg
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = Color3.new(0, 0, 0)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Parent = g
	fadeGui, fadeFrame = g, f
	return f
end

local function releaseFade()
	if fade.state == "in" or fade.state == "hold" then
		fade.released = true
	end
end

local function updateFade(dt: number)
	if fade.state == "none" then
		return
	end
	local f = getFade()
	fade.t += dt
	if fade.state == "in" then
		if f then
			f.BackgroundTransparency = 1 - math.min(fade.t / FADE_IN, 1)
		end
		if fade.t >= FADE_IN + 0.3 then
			fade.state, fade.t = "hold", 0
		end
	elseif fade.state == "hold" then
		if f then
			f.BackgroundTransparency = 0
		end
		if fade.released or fade.t >= FADE_HOLD_MAX then
			fade.state, fade.t = "out", 0
		end
	elseif fade.state == "out" then
		local k = math.min(fade.t / FADE_OUT, 1)
		if f then
			f.BackgroundTransparency = k
		end
		if k >= 1 then
			fade.state, fade.t, fade.released = "none", 0, false
		end
	end
end

-- Motes spiral from a ring around your hero into it while the screen fades.
local function pullSwirl(color: Color3)
	local root = characterRoot(Players.LocalPlayer and Players.LocalPlayer.UserId or 0)
	if not root then
		return
	end
	local motes: { BasePart } = {}
	for _ = 1, CAP.pullMotes do
		table.insert(motes, getPart(Enum.PartType.Ball, Vector3.one * 0.6, color, 0.1, true))
	end
	local life = 1.5
	timed(life, nil, function(t)
		local pos = root.Position
		local f = t / life
		for i, p in motes do
			local a = f * 10 + (i - 1) / #motes * math.pi * 2
			local rr = 7 * (1 - f) + 0.3
			p.CFrame = CFrame.new(pos.X + math.cos(a) * rr, pos.Y - 1 + f * 3, pos.Z + math.sin(a) * rr)
			p.Transparency = 0.1 + 0.8 * f
		end
	end, function()
		for _, p in motes do
			putPart(p)
		end
	end)
end

local function onPortal(ev: any)
	local x, z = num(ev.x, 0), num(ev.z, 0)
	local color = rgbColor(ev.color, COLORS.cheese)
	if ev.phase == "close" then
		removePortal()
		return
	end
	local pf = ensurePortal(x, z, color)
	if ev.phase == "pull" then
		pf.pull = 1
		pullSwirl(color)
		fade.state, fade.t, fade.released = "in", 0, false
		shake(x, z, 0.8)
		State.toast:Fire("🌀 Through the Rind Gate!", "info")
	end
end

local handlers: { [string]: (any) -> () } = {
	poi = onPoi,
	poiProgress = onPoiProgress,
	poiDone = onPoiDone,
	trap = onTrap,
	portal = onPortal,
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
			clearZones(false, id)
		end
	end,
	-- World.clearEnemies (boss start / boss death): enemies, enemy projectiles,
	-- pending strikes and hostile zones go. Crumbs, down tags, orbiters and
	-- player zones stay, because they still exist on the server.
	clear = function(_ev)
		FxController.clearHostile()
	end,
	zone = onZone,
	strike = onStrike,
	dash = onDash,
	leap = onLeap,
	blink = onBlink,
	surge = onSurge,
	enrage = onEnrage,
	adapt = function(ev)
		local x, z = bossPos(ev.id)
		if x and z then
			local mode = tostring(ev.mode or "")
			local icon = if mode == "near" then "🦶 " elseif mode == "far" then "🎯 " else "🕸 "
			showNumber(x, z, icon .. pretty(ev.pattern), Color3.fromRGB(210, 170, 255), true)
		end
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
		local phase = tonumber(ev.phase)
		showNumber(x, z, if phase then "PHASE " .. tostring(phase) .. "!" else "NEW PHASE!", COLORS.red, true)
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
		local x, z = tonumber(ev.x), tonumber(ev.z)
		if root then
			x, z = root.Position.X, root.Position.Z
		end
		if x and z then
			expandingDisc(x, z, 8, COLORS.green, 0.5, 0.3)
			local text = if ev.kind == "secondWind" then "Second Wind!" else "Revived!"
			showNumber(x, z, text, COLORS.green, true)
		end
	end,
	ability = function(ev)
		local x, z = num(ev.x, 0), num(ev.z, 0)
		local r = num(ev.r, 0)
		if r <= 0.5 then
			r = 4
		end
		local kind = tostring(ev.kind)
		local color = ABILITY_COLORS[kind] or COLORS.cheese
		expandingDisc(x, z, r, color, 0.4, 0.3)
		if kind == "burst" or kind == "field" then
			expandingBall(x, 1, z, r * 0.6, color, 0.3, 0.5)
		end
		local id = tonumber(ev.id)
		local dur = num(ev.dur, 0)
		if id and dur > 0 and (kind == "shield" or kind == "hover") then
			abilityAura(id, kind, math.min(dur, 10), r, color)
		end
		if kind == "dash" and ev.fromX ~= nil and ev.fromZ ~= nil then
			-- Streak along the dash path.
			local a = Vector3.new(num(ev.fromX, x), PROJ_Y - 1, num(ev.fromZ, z))
			local b = Vector3.new(x, PROJ_Y - 1, z)
			local len = (b - a).Magnitude
			if len > 0.5 then
				local p =
					getPart(Enum.PartType.Block, Vector3.new(math.max(1, r), 0.2, len), color, 0.4, true)
				p.CFrame = CFrame.lookAt(a, b) * CFrame.new(0, 0, -len / 2)
				timed(0.25, nil, function(t)
					p.Transparency = 0.4 + 0.6 * (t / 0.25)
				end, function()
					putPart(p)
				end)
			end
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

	count = updateZones(dt, now, moveParts, moveCFrames, count)

	for j = #moveParts, count + 1, -1 do
		moveParts[j] = nil
		moveCFrames[j] = nil
	end
	if count > 0 then
		workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end

	updatingEffects = true
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
	updatingEffects = false
	for _, e in pendingEffects do
		addEffect(e)
	end
	table.clear(pendingEffects)

	updateNumbers(dt)
	updateDownTags(dt)
	updatePoiMarks(dt)
	updatePortal(dt)
	updateFade(dt)
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

-- Clears enemy-side visuals only: hostile projectiles, telegraphs, strikes and
-- other boss effects, and hostile zones.
function FxController.clearHostile()
	for key, pr in projs do
		if pr.hostile then
			releaseProj(key)
		end
	end
	local k = 1
	while k <= #effects do
		local e = effects[k]
		if e.tag == "tele" or e.tag == "hostile" then
			table.remove(effects, k)
			pcall(e.kill)
		else
			k += 1
		end
	end
	clearZones(true, nil)
end

-- Clears world-bound effects (pickups, projectiles, telegraphs, zones, down tags).
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
	local old = table.clone(effects)
	table.clear(effects)
	for _, e in old do
		pcall(e.kill)
	end
	for _, e in pendingEffects do
		pcall(e.kill)
	end
	table.clear(pendingEffects)
	clearZones(false, nil)
	for userId in downTags do
		removeDown(userId)
	end
	for id in orbits do
		removeOrbit(id)
	end
	-- POI markers belong to the arena; the portal and the pull fade outlive the
	-- vote phases (they end on "close" / the next Waves phase).
	clearPoiMarks()
end

-- Lets other client code play a local effect, e.g. FxController.play({t = "boom", x = 0, z = 0, r = 5}).
function FxController.play(ev: any)
	onFx({ ev })
end

-- Every Fx `t` with a handler (sorted). Used to check coverage of COMBAT-API.
function FxController.handledTypes(): { string }
	local out = {}
	for k in handlers do
		table.insert(out, k)
	end
	table.sort(out)
	return out
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
				if phase == "Waves" or phase == nil or phase == "Lobby" or phase == "Results" then
					removePortal() -- a fresh arena (or the lobby) has no portal
					releaseFade()
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
	removePortal()
	if fadeGui then
		fadeGui:Destroy()
		fadeGui, fadeFrame = nil, nil
	end
	fade.state = "none"
	for _, n in numbers do
		n.att:Destroy()
	end
	for _, n in numberFree do
		n.att:Destroy()
	end
	table.clear(numbers)
	table.clear(numberFree)
	for _, a in rimPool do
		a:Destroy()
	end
	table.clear(rimPool)
	rimAnchor = nil
	if folder then
		folder:Destroy()
		folder = nil
	end
	table.clear(partPools)
end

return FxController
