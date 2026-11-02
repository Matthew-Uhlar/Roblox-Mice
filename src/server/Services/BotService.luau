--!strict
-- BotService (Team F): bodies and movement for party-fill bot elephants (GDD §3.6).
--
-- Bots are combat-world participants with negative ids. They have no Player and
-- no Humanoid: each bot is a model of anchored, non-colliding Parts under
-- workspace.Bots that we move with PivotTo. Each Heartbeat we:
--   * every THINK_INTERVAL, build a view of the world and ask BotBrain:think;
--   * every frame, steer smoothly toward the intent at the bot's moveSpeed
--     (x0.3 while downed), push out of obstacles, clamp to the arena, write the
--     result with world:setPlayerPosition and move the model;
--   * fire world:useAbility when the brain asks for it.
-- The world position is read back every frame, so dashes and clamps done by the
-- simulation win over our integration.
--
-- API:
--   BotService.placeInLobby(botSpecs, positions: {Vector3}?, lookAt: Vector3?)
--   BotService.spawnForRun(botSpecs, arenaInfo?, world?, seed: number?)
--   BotService.setWorld(world?, arenaInfo?)      -- each new stage (nil between stages)
--   BotService.despawnAll()
--   BotService.isBotId(id) -> boolean
--   BotService.getModel(id) -> Model?

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BotsFolder = Shared:WaitForChild("Bots")
local BotBrain = require(BotsFolder:WaitForChild("BotBrain")) :: any
local Rng = require(Shared:WaitForChild("Util"):WaitForChild("Rng")) :: any
local Classes = require(Shared:WaitForChild("Config"):WaitForChild("Classes")) :: any

local BotService = {}

-- Tunables ------------------------------------------------------------------------------
BotService.THINK_INTERVAL = 0.1
BotService.DOWNED_SPEED = 0.3 -- matches World.DOWNED_SPEED
BotService.SLOW_SPEED = 0.6 -- matches World.PLAYER_SLOW (slowed bots move like slowed humans)
BotService.DEFAULT_SPEED = 16
BotService.ACCEL = 10 -- 1/s; velocity smoothing toward the brain's intent
BotService.PLAYER_RADIUS = 1.6 -- matches World.PLAYER_RADIUS
BotService.PICKUP_SCAN = 20
BotService.TAG_COLOR = Color3.fromRGB(90, 210, 255)

local BODY_COLOR = Color3.fromRGB(160, 160, 172)
local EAR_COLOR = Color3.fromRGB(196, 160, 172)

type Spec = { id: number, name: string, classId: string, isBot: boolean? }
type Intent = { moveX: number, moveZ: number, speedFrac: number, ability: { x: number, z: number }? }
type Bot = {
	spec: Spec,
	model: Model,
	tag: TextLabel,
	brain: any?,
	intent: Intent,
	velX: number,
	velZ: number,
	faceX: number,
	faceZ: number,
	mode: string, -- "up" | "downed" | "dead"
}

local bots: { [number]: Bot } = {}
local order: { number } = {}
local folder: Folder? = nil
local world: any = nil
local arena: any = nil
local groundY = 0
local running = false
local thinkAcc = 0
local heartbeat: RBXScriptConnection? = nil

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function BotService.isBotId(id: any): boolean
	return type(id) == "number" and bots[id] ~= nil
end

function BotService.getModel(id: number): Model?
	local b = bots[id]
	return if b then b.model else nil
end

-- Model ------------------------------------------------------------------------------------

local function getFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local existing = Workspace:FindFirstChild("Bots")
	if existing and existing:IsA("Folder") then
		folder = existing
		return existing
	end
	local nf = Instance.new("Folder")
	nf.Name = "Bots"
	nf.Parent = Workspace
	folder = nf
	return nf
end

local function classColor(classId: string): Color3
	local ok, def = pcall(Classes.get, classId)
	local c = ok and type(def) == "table" and def.color
	if type(c) == "table" and finite(c[1]) and finite(c[2]) and finite(c[3]) then
		return Color3.fromRGB(c[1], c[2], c[3])
	end
	return Color3.fromRGB(255, 200, 60)
end

local function part(
	model: Model,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	shape: Enum.PartType?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p:SetAttribute("BaseColor", color)
	p.Parent = model
	return p
end

-- Builds a simple elephant around the origin (ground at y = 0, facing -Z).
local function buildModel(spec: Spec): (Model, TextLabel)
	local model = Instance.new("Model")
	model.Name = "Bot_" .. tostring(-spec.id)
	model:SetAttribute("IsBot", true)
	model:SetAttribute("BotId", spec.id)
	model:SetAttribute("ClassId", spec.classId)
	model:SetAttribute("DisplayName", spec.name)

	local sash = classColor(spec.classId)
	local rad = math.rad
	part(model, "Body", Vector3.new(4.4, 3.4, 6), CFrame.new(0, 3.4, 0), BODY_COLOR)
	local head = part(
		model,
		"Head",
		Vector3.new(3.6, 3.6, 3.6),
		CFrame.new(0, 4.7, -3.4),
		BODY_COLOR,
		Enum.PartType.Ball
	)
	part(
		model,
		"Trunk",
		Vector3.new(3, 1, 1),
		CFrame.new(0, 3, -4.9) * CFrame.Angles(rad(-10), 0, rad(90)),
		BODY_COLOR,
		Enum.PartType.Cylinder
	)
	part(
		model,
		"TrunkTip",
		Vector3.new(1.1, 1.1, 1.1),
		CFrame.new(0, 1.5, -5.2),
		BODY_COLOR,
		Enum.PartType.Ball
	)
	for _, side in { -1, 1 } do
		part(
			model,
			if side < 0 then "EarL" else "EarR",
			Vector3.new(0.4, 3.2, 2.8),
			CFrame.new(side * 2.2, 4.8, -3) * CFrame.Angles(0, rad(side * 25), 0),
			EAR_COLOR
		)
		part(
			model,
			if side < 0 then "EyeL" else "EyeR",
			Vector3.new(0.5, 0.5, 0.5),
			CFrame.new(side * 0.9, 5.3, -5.05),
			Color3.fromRGB(25, 25, 30),
			Enum.PartType.Ball
		)
		for _, front in { -1, 1 } do
			part(model, "Leg", Vector3.new(1.4, 2, 1.4), CFrame.new(side * 1.4, 1, front * 2), BODY_COLOR)
		end
	end
	part(model, "Sash", Vector3.new(4.6, 3.6, 1.1), CFrame.new(0, 3.4, -0.6), sash)
	part(
		model,
		"Tail",
		Vector3.new(0.3, 0.3, 1.6),
		CFrame.new(0, 4, 3.6) * CFrame.Angles(rad(30), 0, 0),
		BODY_COLOR
	)
	model.WorldPivot = CFrame.new()

	local gui = Instance.new("BillboardGui")
	gui.Name = "NameTag"
	gui.Adornee = head
	gui.Size = UDim2.fromOffset(200, 52)
	gui.StudsOffset = Vector3.new(0, 3.2, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 160
	gui.ResetOnSpawn = false

	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, 0, 0.55, 0)
	name.Font = Enum.Font.FredokaOne
	name.TextScaled = true
	name.TextColor3 = Color3.new(1, 1, 1)
	name.TextStrokeTransparency = 0.3
	name.Text = spec.name
	name.Parent = gui

	local tag = Instance.new("TextLabel")
	tag.Name = "BotTag"
	tag.AnchorPoint = Vector2.new(0.5, 0)
	tag.Position = UDim2.new(0.5, 0, 0.58, 0)
	tag.Size = UDim2.new(0.5, 0, 0.42, 0)
	tag.BackgroundColor3 = Color3.fromRGB(20, 50, 80)
	tag.BackgroundTransparency = 0.15
	tag.Font = Enum.Font.FredokaOne
	tag.TextScaled = true
	tag.TextColor3 = BotService.TAG_COLOR
	tag.Text = "🤖 BOT"
	tag.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = tag

	gui.Parent = head
	model.Parent = getFolder()
	return model, tag
end

local function setMode(b: Bot, mode: string)
	if b.mode == mode then
		return
	end
	b.mode = mode
	for _, d in b.model:GetDescendants() do
		if d:IsA("BasePart") then
			local base = d:GetAttribute("BaseColor")
			if typeof(base) == "Color3" then
				d.Color = if mode == "up" then base else base:Lerp(Color3.fromRGB(70, 70, 90), 0.45)
			end
			d.Transparency = if mode == "dead" then 0.6 else 0
		end
	end
	b.tag.Text = if mode == "downed"
		then "🤖 BOT · DOWN"
		elseif mode == "dead" then "🤖 BOT · OUT"
		else "🤖 BOT"
end

local function pose(b: Bot, x: number, z: number)
	local origin = Vector3.new(x, groundY, z)
	local cf = CFrame.lookAt(origin, origin + Vector3.new(b.faceX, 0, b.faceZ))
	if b.mode ~= "up" then
		-- Lie on one side.
		cf = cf * CFrame.new(0, 1.4, 0) * CFrame.Angles(0, 0, math.rad(80))
	end
	b.model:PivotTo(cf)
end

local function destroyBot(id: number)
	local b = bots[id]
	if b then
		b.model:Destroy()
		bots[id] = nil
	end
	local i = table.find(order, id)
	if i then
		table.remove(order, i)
	end
end

-- Makes `bots` match `specs` (keeps models whose id, name and class are unchanged).
local function sync(specs: { Spec })
	local want: { [number]: Spec } = {}
	for _, s in specs do
		if type(s) == "table" and type(s.id) == "number" then
			want[s.id] = s
		end
	end
	for _, id in table.clone(order) do
		local s = want[id]
		local b = bots[id]
		if not s or not b or b.spec.classId ~= s.classId or b.spec.name ~= s.name then
			destroyBot(id)
		end
	end
	for _, s in specs do
		if type(s) == "table" and type(s.id) == "number" and not bots[s.id] then
			local model, tag = buildModel(s)
			bots[s.id] = {
				spec = s,
				model = model,
				tag = tag,
				brain = nil,
				intent = { moveX = 0, moveZ = 0, speedFrac = 0 },
				velX = 0,
				velZ = 0,
				faceX = 0,
				faceZ = -1,
				mode = "up",
			}
			table.insert(order, s.id)
		end
	end
end

-- View ---------------------------------------------------------------------------------------

local function worldNow(): number
	local w = world
	if w and finite(w.now) and w.stepped then
		return w.now
	end
	return Workspace:GetServerTimeNow()
end

-- Team B's world:getPlayers() if present, else the raw world.playerList.
local function getAllies(w: any): { any }
	local out = {}
	local list: any = nil
	if type(w.getPlayers) == "function" then
		local ok, r = pcall(w.getPlayers, w)
		if ok and type(r) == "table" then
			list = r
		end
	end
	if not list and type(w.playerList) == "table" then
		list = w.playerList
	end
	for _, p in list or {} do
		if type(p) == "table" and type(p.id) == "number" and finite(p.x) and finite(p.z) and not p.dead then
			table.insert(out, {
				id = p.id,
				x = p.x,
				z = p.z,
				downed = p.downed == true,
				isBot = bots[p.id] ~= nil,
			})
		end
	end
	return out
end

-- Team B's world:pickupsNear(x, z, r) if present, else the raw world.pickups list.
local function getPickups(w: any, x: number, z: number): { any }
	local r = BotService.PICKUP_SCAN
	if type(w.pickupsNear) == "function" then
		local ok, list = pcall(w.pickupsNear, w, x, z, r)
		if ok and type(list) == "table" then
			return list
		end
	end
	local out = {}
	if type(w.pickups) == "table" then
		local r2 = r * r
		for _, c in w.pickups do
			if type(c) == "table" and finite(c.x) and finite(c.z) and c.target == nil then
				if (c.x - x) ^ 2 + (c.z - z) ^ 2 <= r2 then
					table.insert(out, { x = c.x, z = c.z })
				end
			end
		end
	end
	return out
end

local function arenaRadius(w: any): number
	if arena and finite(arena.radius) then
		return arena.radius
	end
	if finite(w.arenaRadius) then
		return w.arenaRadius
	end
	return 100
end

local function obstacles(w: any): { any }
	if arena and type(arena.obstacles) == "table" then
		return arena.obstacles
	end
	if type(w.obstacles) == "table" then
		return w.obstacles
	end
	return {}
end

-- Loop ---------------------------------------------------------------------------------------

local function stepBots(dt: number)
	local w = world
	if not running or not w then
		return
	end
	thinkAcc += dt
	local think = thinkAcc >= BotService.THINK_INTERVAL
	local thinkDt = thinkAcc
	if think then
		thinkAcc = 0
	end
	local now = worldNow()

	local enemies: { any } = {}
	local allies: { any } = {}
	local radius = arenaRadius(w)
	local obs = obstacles(w)
	if think then
		local ok, snaps = pcall(w.snapshot, w)
		if ok and type(snaps) == "table" then
			enemies = snaps
		end
		allies = getAllies(w)
	end

	local alpha = 1 - math.exp(-BotService.ACCEL * dt)
	for _, id in order do
		local b = bots[id]
		local okInfo, info = pcall(w.getPlayer, w, id)
		if not b or not okInfo or type(info) ~= "table" then
			continue
		end
		local x, z = info.x, info.z
		if not finite(x) or not finite(z) then
			continue
		end

		if think and b.brain then
			local view = {
				self = {
					x = x,
					z = z,
					hp = info.hp or 0,
					maxHp = info.maxHp or 100,
					downed = info.downed == true,
					abilityReady = now >= (info.abilityReadyAt or 0),
				},
				allies = allies,
				enemies = enemies,
				pickups = getPickups(w, x, z),
				arenaRadius = radius,
				obstacles = obs,
				now = now,
			}
			local ok, intent = pcall(b.brain.think, b.brain, view, thinkDt)
			if ok and type(intent) == "table" then
				b.intent = intent
			else
				warn("[BotService] think failed: " .. tostring(intent))
			end
		end

		if info.dead then
			setMode(b, "dead")
			b.velX, b.velZ = 0, 0
			pose(b, x, z)
			continue
		end
		setMode(b, if info.downed then "downed" else "up")

		-- Ability first (aimed from where we stand now).
		local ab = b.intent.ability
		if ab and not info.downed then
			b.intent.ability = nil
			if finite(ab.x) and finite(ab.z) then
				pcall(w.useAbility, w, id, ab.x, ab.z, now)
			end
		end

		-- Smooth steering.
		local speed = if finite(info.moveSpeed) then info.moveSpeed else BotService.DEFAULT_SPEED
		if info.downed then
			speed *= BotService.DOWNED_SPEED
		elseif info.slowed then
			speed *= BotService.SLOW_SPEED -- same x0.6 CombatService gives humans
		end
		local frac = math.clamp(b.intent.speedFrac or 0, 0, 1)
		local tx, tz = (b.intent.moveX or 0) * speed * frac, (b.intent.moveZ or 0) * speed * frac
		b.velX += (tx - b.velX) * alpha
		b.velZ += (tz - b.velZ) * alpha
		x += b.velX * dt
		z += b.velZ * dt

		if type(w.pushOutOfObstacles) == "function" then
			local ok, nx, nz = pcall(w.pushOutOfObstacles, w, x, z, BotService.PLAYER_RADIUS)
			if ok and finite(nx) and finite(nz) then
				x, z = nx, nz
			end
		end
		local lim = radius - BotService.PLAYER_RADIUS
		local d = math.sqrt(x * x + z * z)
		if d > lim and d > 0 then
			x, z = x / d * lim, z / d * lim
		end
		pcall(w.setPlayerPosition, w, id, x, z)

		local sp = math.sqrt(b.velX * b.velX + b.velZ * b.velZ)
		if sp > 0.5 then
			b.faceX, b.faceZ = b.velX / sp, b.velZ / sp
		end
		pose(b, x, z)
	end
end

local function ensureLoop()
	if heartbeat then
		return
	end
	heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		local ok, err = pcall(stepBots, dt)
		if not ok then
			warn("[BotService] step failed: " .. tostring(err))
		end
	end)
end

-- Public API ----------------------------------------------------------------------------------

-- Lobby: bots stand on the pad (no brain, no world). Ignored while a run drives them.
function BotService.placeInLobby(botSpecs: { Spec }, positions: { Vector3 }?, lookAt: Vector3?)
	if running then
		return
	end
	sync(botSpecs or {})
	for i, id in order do
		local b = bots[id]
		local pos = if positions and positions[i]
			then positions[i]
			else Vector3.new(math.cos(i * 1.3) * 12, 0, math.sin(i * 1.3) * 12)
		local target = lookAt or Vector3.new(pos.X, pos.Y, pos.Z - 1)
		local dir = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
		if dir.Magnitude > 1e-3 then
			b.faceX, b.faceZ = dir.Unit.X, dir.Unit.Z
		end
		b.brain = nil
		setMode(b, "up")
		groundY = pos.Y
		pose(b, pos.X, pos.Z)
	end
end

function BotService.spawnForRun(botSpecs: { Spec }, arenaInfo: any?, w: any?, seed: number?)
	running = false -- let sync run even if a previous run leaked
	sync(botSpecs or {})
	local root = Rng.new(seed or math.floor(os.clock() * 1000))
	for i, id in order do
		local b = bots[id]
		b.brain = BotBrain.new(id, b.spec.classId, root:fork(1000 + i))
		b.intent = { moveX = 0, moveZ = 0, speedFrac = 0 }
		b.velX, b.velZ = 0, 0
	end
	running = true
	thinkAcc = 0
	ensureLoop()
	if w then
		BotService.setWorld(w, arenaInfo)
	end
end

function BotService.setWorld(w: any?, arenaInfo: any?)
	world = w
	arena = arenaInfo
	thinkAcc = BotService.THINK_INTERVAL -- think on the first frame
	if arenaInfo then
		local spawn = arenaInfo.spawn
		if typeof(spawn) == "Vector3" then
			groundY = spawn.Y
		elseif finite(arenaInfo.groundY) then
			groundY = arenaInfo.groundY
		end
	end
	for _, id in order do
		local b = bots[id]
		b.intent = { moveX = 0, moveZ = 0, speedFrac = 0 }
		b.velX, b.velZ = 0, 0
		if w then
			local ok, info = pcall(w.getPlayer, w, id)
			if ok and type(info) == "table" and finite(info.x) and finite(info.z) then
				setMode(b, "up")
				pose(b, info.x, info.z)
			end
		end
	end
end

function BotService.despawnAll()
	running = false
	world = nil
	arena = nil
	for _, id in table.clone(order) do
		destroyBot(id)
	end
end

return BotService
