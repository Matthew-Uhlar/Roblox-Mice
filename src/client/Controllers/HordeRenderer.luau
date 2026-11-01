--!strict
-- Renders the server's enemy snapshots (Net.S2C.Snapshot buffers decoded by
-- Shared.Combat.SnapshotCodec) as pooled, anchored, non-colliding parts.
--
--  * Clock: serverTime base is unknown to the client, so we estimate an offset
--    (serverTime - os.clock()) from arrival times and render ~100 ms behind.
--  * Snapshots that share a serverTime are merged (supports chunked frames).
--  * Ids missing from the latest complete frame fade out, then return to pool.
--  * One workspace:BulkMoveTo per frame moves every visible part.
--  * HordeRenderer.nearest(x, z) is the auto-aim query for InputController.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Remotes = require(Client.Util.Remotes)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local Device = require(Client.Util.Device)
local State = require(script.Parent.State)

local Shared = ReplicatedStorage:WaitForChild("Shared")

local HordeRenderer = {}

local RENDER_DELAY = 0.1
local EXTRAPOLATE_MAX = 0.1
local FADE_TIME = 0.25
local MAX_SAMPLES = 4
local STALE_AFTER = 1.25 -- no snapshot for this long: fade everything
local GROUND_Y = 0
local HIT_FLASH = 0.08
local LOW = Device.lowSpec()
local MAX_VISUALS = if LOW then 220 else 450
local PARK = CFrame.new(0, -5000, 0)
local BIND_NAME = "TrunkfallHorde"

local GOLD = Color3.fromRGB(255, 196, 40)
local FLASH_RED = Color3.fromRGB(255, 70, 50)
local HIT_WHITE = Color3.fromRGB(255, 255, 255)
local STUN_BLUE = Color3.fromRGB(140, 200, 255)
local PINK = Color3.fromRGB(255, 160, 175)

type Visual = {
	key: string,
	parts: { BasePart },
	offsets: { CFrame },
	colors: { Color3 },
	tint: { boolean },
	baseTransparency: { number },
	radius: number,
	isBoss: boolean,
	tag: BillboardGui?,
	hpFill: Frame?,
	lastHp: number,
}

type Enemy = {
	id: number,
	kind: number,
	isBoss: boolean,
	bossId: string?,
	def: any,
	st: { number },
	sx: { number },
	sz: { number },
	n: number,
	x: number,
	z: number,
	yaw: number,
	moving: number,
	phase: number,
	hpFrac: number,
	flags: number,
	hitFrom: number,
	lastFrame: number,
	missing: number,
	fading: boolean,
	fadeT: number,
	killedAt: number,
	visual: Visual?,
	colorState: number,
}

local folder: Folder? = nil
local enemies: { [number]: Enemy } = {}
local pools: { [string]: { Visual } } = {}
local visualCount = 0

local clockOffset: number? = nil
local lastFrameTime: number? = nil
local frameIndex = 0
local buffersThisFrame = 0
local chunked = false
local lastSnapshotLocal = 0

local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

local codec: any = nil
local codecRetryAt = 0
local warnedDecode = false

local lastBossKey: string? = nil
local lastBossHp = -1

local handle: any = nil
local bound = false

----------------------------------------------------------------------
-- Codec
----------------------------------------------------------------------

local function loadCodec(): any
	if codec then
		return codec
	end
	if os.clock() < codecRetryAt then
		return nil
	end
	codecRetryAt = os.clock() + 3
	local combat = Shared:FindFirstChild("Combat")
	local mod = combat and combat:FindFirstChild("SnapshotCodec")
	if mod and mod:IsA("ModuleScript") then
		local ok, res = pcall(require, mod)
		if ok and type(res) == "table" and type(res.decode) == "function" then
			codec = res
		else
			warn("[Trunkfall] SnapshotCodec failed to load: " .. tostring(res))
		end
	end
	return codec
end

----------------------------------------------------------------------
-- Visual construction / pooling
----------------------------------------------------------------------

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "TrunkfallHorde"
	f.Parent = workspace
	folder = f
	return f
end

local function newPart(shape: Enum.PartType, size: Vector3, color: Color3, sphereMesh: boolean?): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Shape = shape
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CFrame = PARK
	if sphereMesh then
		local m = Instance.new("SpecialMesh")
		m.MeshType = Enum.MeshType.Sphere
		m.Parent = p
	end
	p.Parent = getFolder()
	return p
end

local function fallbackEnemyColor(def: any, id: string?): Color3
	local sid = string.lower(tostring(id or (def and def.id) or ""))
	local behavior = if type(def) == "table" then def.behavior else nil
	if string.find(sid, "rat") then
		return Color3.fromRGB(150, 105, 70)
	elseif behavior == "fuse" or string.find(sid, "fuse") then
		return Color3.fromRGB(215, 95, 70)
	elseif behavior == "ranged" or string.find(sid, "sling") then
		return Color3.fromRGB(196, 160, 110)
	elseif behavior == "tank" or string.find(sid, "chonk") then
		return Color3.fromRGB(105, 105, 120)
	end
	return Color3.fromRGB(170, 170, 180)
end

local function addPart(v: Visual, part: BasePart, offset: CFrame, tintable: boolean)
	table.insert(v.parts, part)
	table.insert(v.offsets, offset)
	table.insert(v.colors, part.Color)
	table.insert(v.tint, tintable)
	table.insert(v.baseTransparency, part.Transparency)
end

local function newVisual(key: string, radius: number, isBoss: boolean): Visual
	return {
		key = key,
		parts = {},
		offsets = {},
		colors = {},
		tint = {},
		baseTransparency = {},
		radius = radius,
		isBoss = isBoss,
		tag = nil,
		hpFill = nil,
		lastHp = -1,
	}
end

local function buildMouse(key: string, def: any, id: string?): Visual
	local r = math.max(0.4, tonumber(def and def.radius) or 1.2)
	local color = Format.rgb(def and def.color, fallbackEnemyColor(def, id))
	local earColor = color:Lerp(PINK, 0.45)
	local v = newVisual(key, r, false)

	addPart(
		v,
		newPart(Enum.PartType.Block, Vector3.new(1.8 * r, 1.3 * r, 2.3 * r), color, true),
		CFrame.new(0, 0.65 * r, 0),
		true
	)
	local earSize = Vector3.new(0.12 * r + 0.05, 0.95 * r, 0.95 * r)
	for _, side in { -1, 1 } do
		addPart(
			v,
			newPart(Enum.PartType.Cylinder, earSize, earColor),
			CFrame.new(side * 0.55 * r, 1.35 * r, -0.55 * r) * CFrame.Angles(0, math.pi / 2, 0),
			true
		)
	end
	if not LOW then
		addPart(
			v,
			newPart(Enum.PartType.Block, Vector3.new(0.14 * r + 0.05, 0.14 * r + 0.05, 1.5 * r), PINK),
			CFrame.new(0, 0.5 * r, 1.75 * r) * CFrame.Angles(math.rad(20), 0, 0),
			false
		)
		addPart(
			v,
			newPart(Enum.PartType.Ball, Vector3.one * (0.32 * r + 0.05), Color3.fromRGB(235, 110, 130)),
			CFrame.new(0, 0.75 * r, -1.15 * r),
			false
		)
	end
	return v
end

local function buildBoss(key: string, def: any, id: string?): Visual
	local r = math.max(2, tonumber(def and def.radius) or 4)
	local color = Format.rgb(def and def.color, Color3.fromRGB(150, 110, 190))
	local v = newVisual(key, r, true)

	local body = newPart(Enum.PartType.Block, Vector3.new(2 * r, 1.7 * r, 2 * r), color, true)
	addPart(v, body, CFrame.new(0, 0.85 * r, 0), true)
	local earSize = Vector3.new(0.2 * r, 1.3 * r, 1.3 * r)
	for _, side in { -1, 1 } do
		addPart(
			v,
			newPart(Enum.PartType.Cylinder, earSize, color:Lerp(PINK, 0.4)),
			CFrame.new(side * 0.75 * r, 1.75 * r, -0.25 * r) * CFrame.Angles(0, math.pi / 2, 0),
			true
		)
		addPart(
			v,
			newPart(Enum.PartType.Ball, Vector3.one * 0.4 * r, Color3.new(1, 1, 1)),
			CFrame.new(side * 0.36 * r, 1.2 * r, -0.85 * r),
			false
		)
		addPart(
			v,
			newPart(Enum.PartType.Ball, Vector3.one * 0.2 * r, Color3.fromRGB(25, 20, 20)),
			CFrame.new(side * 0.36 * r, 1.2 * r, -1.03 * r),
			false
		)
	end
	addPart(
		v,
		newPart(Enum.PartType.Cylinder, Vector3.new(0.45 * r, 0.9 * r, 0.9 * r), GOLD),
		CFrame.new(0, 1.85 * r, 0) * CFrame.Angles(0, 0, math.pi / 2),
		false
	)
	addPart(
		v,
		newPart(Enum.PartType.Block, Vector3.new(0.2 * r, 0.2 * r, 1.6 * r), PINK),
		CFrame.new(0, 0.6 * r, 1.6 * r) * CFrame.Angles(math.rad(25), 0, 0),
		false
	)

	-- Name tag + small hp bar.
	local tag = Instance.new("BillboardGui")
	tag.Name = "BossTag"
	tag.Size = UDim2.fromOffset(260, 74)
	tag.StudsOffsetWorldSpace = Vector3.new(0, 1.6 * r, 0)
	tag.AlwaysOnTop = true
	tag.LightInfluence = 0
	tag.MaxDistance = 400
	tag.Adornee = body
	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, 0, 0, 32)
	name.Font = Enum.Font.FredokaOne
	name.TextScaled = true
	name.TextColor3 = Color3.fromRGB(255, 214, 80)
	name.TextStrokeTransparency = 0
	name.TextStrokeColor3 = Color3.fromRGB(60, 36, 20)
	name.Text = Defs.name(def, id)
	name.Parent = tag
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(0, 32)
	title.Size = UDim2.new(1, 0, 0, 20)
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 244, 214)
	title.TextStrokeTransparency = 0.2
	title.Text = if type(def) == "table" and def.title then tostring(def.title) else ""
	title.Parent = tag
	local bar = Instance.new("Frame")
	bar.Position = UDim2.new(0.1, 0, 0, 56)
	bar.Size = UDim2.new(0.8, 0, 0, 12)
	bar.BackgroundColor3 = Color3.fromRGB(60, 36, 20)
	bar.BorderSizePixel = 0
	bar.Parent = tag
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(230, 70, 60)
	fill.BorderSizePixel = 0
	fill.Parent = bar
	tag.Enabled = false
	tag.Parent = body
	v.tag = tag
	v.hpFill = fill
	return v
end

local function acquireVisual(e: Enemy): Visual?
	local key = tostring(e.kind)
	local pool = pools[key]
	local v: Visual? = nil
	if pool and #pool > 0 then
		v = table.remove(pool)
	else
		local _, _, id = Defs.enemyKind(e.kind)
		if e.isBoss then
			v = buildBoss(key, e.def, id)
		else
			v = buildMouse(key, e.def, id)
		end
	end
	if v and v.tag then
		v.tag.Enabled = true
	end
	visualCount += 1
	e.colorState = -1
	return v
end

local function releaseVisual(e: Enemy)
	local v = e.visual
	if not v then
		return
	end
	e.visual = nil
	visualCount -= 1
	for i, p in v.parts do
		p.CFrame = PARK
		p.Transparency = v.baseTransparency[i]
		p.Color = v.colors[i]
	end
	if v.tag then
		v.tag.Enabled = false
	end
	v.lastHp = -1
	local pool = pools[v.key]
	if not pool then
		pool = {}
		pools[v.key] = pool
	end
	table.insert(pool, v)
end

----------------------------------------------------------------------
-- Enemy records
----------------------------------------------------------------------

local function newEnemy(id: number, kind: number): Enemy
	local def, isBoss, bossId = Defs.enemyKind(kind)
	return {
		id = id,
		kind = kind,
		isBoss = isBoss,
		bossId = bossId,
		def = def,
		st = {},
		sx = {},
		sz = {},
		n = 0,
		x = 0,
		z = 0,
		yaw = math.random() * math.pi * 2,
		moving = 0,
		phase = math.random() * 10,
		hpFrac = 1,
		flags = 0,
		hitFrom = -1,
		lastFrame = 0,
		missing = 0,
		fading = false,
		fadeT = 0,
		killedAt = -1,
		visual = nil,
		colorState = -1,
	}
end

local function pushSample(e: Enemy, t: number, x: number, z: number)
	local n = e.n
	if n > 0 and e.st[n] == t then
		e.sx[n], e.sz[n] = x, z
		return
	end
	if n >= MAX_SAMPLES then
		table.remove(e.st, 1)
		table.remove(e.sx, 1)
		table.remove(e.sz, 1)
		n -= 1
	end
	n += 1
	e.st[n], e.sx[n], e.sz[n] = t, x, z
	e.n = n
	if n == 1 then
		e.x, e.z = x, z
	end
end

local function sampleAt(e: Enemy, rt: number): (number, number)
	local n = e.n
	local st, sx, sz = e.st, e.sx, e.sz
	if n == 0 then
		return e.x, e.z
	end
	if n == 1 or rt <= st[1] then
		return sx[1], sz[1]
	end
	if rt >= st[n] then
		local dt = st[n] - st[n - 1]
		if dt <= 0 then
			return sx[n], sz[n]
		end
		local over = math.min(rt - st[n], EXTRAPOLATE_MAX)
		return sx[n] + (sx[n] - sx[n - 1]) / dt * over, sz[n] + (sz[n] - sz[n - 1]) / dt * over
	end
	for i = n - 1, 1, -1 do
		if st[i] <= rt then
			local span = st[i + 1] - st[i]
			local a = if span > 0 then (rt - st[i]) / span else 1
			return sx[i] + (sx[i + 1] - sx[i]) * a, sz[i] + (sz[i + 1] - sz[i]) * a
		end
	end
	return sx[1], sz[1]
end

local function lerpAngle(a: number, b: number, t: number): number
	local d = (b - a + math.pi) % (2 * math.pi) - math.pi
	return a + d * t
end

local function startFade(e: Enemy)
	if not e.fading then
		e.fading = true
		e.fadeT = 0
	end
end

local function removeNow(id: number)
	local e = enemies[id]
	if e then
		releaseVisual(e)
		enemies[id] = nil
	end
end

----------------------------------------------------------------------
-- Snapshot intake
----------------------------------------------------------------------

local function updateClock(serverTime: number, localNow: number)
	local sample = serverTime - localNow
	local off = clockOffset
	if off == nil or math.abs(sample - off) > 1 then
		clockOffset = sample
	elseif sample > off then
		-- Arrived "earlier" than expected: less latency on this packet, adopt quickly.
		clockOffset = off + (sample - off) * 0.5
	else
		-- Drift slowly toward later arrivals so a single fast packet can't stick.
		clockOffset = off + (sample - off) * 0.02
	end
end

local function finalizeFrame()
	local need = if chunked then 2 else 1
	for _, e in enemies do
		if not e.fading then
			if e.lastFrame < frameIndex then
				e.missing += 1
				if e.missing >= need then
					startFade(e)
				end
			else
				e.missing = 0
			end
		end
	end
end

local function resetAll()
	for _, e in enemies do
		startFade(e)
		e.n = math.min(e.n, 1)
	end
	clockOffset = nil
	lastFrameTime = nil
	chunked = false
end

local function onSnapshot(buf: any)
	if typeof(buf) ~= "buffer" then
		return
	end
	local c = loadCodec()
	if not c then
		return
	end
	local ok, serverTime, snaps, _chunkIndex, chunkCount = pcall(c.decode, buf)
	if not ok or type(serverTime) ~= "number" or type(snaps) ~= "table" or serverTime <= 0 then
		-- decode returns (0, {}, 0, 0) for malformed buffers: ignore, never reset on it.
		if not warnedDecode then
			warnedDecode = true
			warn("[Trunkfall] snapshot decode failed: " .. tostring(serverTime))
		end
		return
	end
	local localNow = os.clock()
	lastSnapshotLocal = localNow

	local lft = lastFrameTime
	if lft ~= nil and serverTime < lft - 1 then
		resetAll() -- server clock went backwards: new world
		lft = nil
	elseif lft ~= nil and serverTime < lft then
		return -- late chunk of an old frame
	end
	updateClock(serverTime, localNow)

	if lft == nil or serverTime > lft then
		if lft ~= nil then
			finalizeFrame()
		end
		frameIndex += 1
		lastFrameTime = serverTime
		buffersThisFrame = 0
	end
	buffersThisFrame += 1
	if buffersThisFrame > 1 or (tonumber(chunkCount) or 1) > 1 then
		chunked = true -- multi-chunk frames: require 2 missed frames before fading
	end

	for _, s in snaps do
		local id = tonumber(s.id)
		local kind = tonumber(s.kind)
		local x, z = tonumber(s.x), tonumber(s.z)
		if id and kind and x and z then
			local e = enemies[id]
			if e and e.fading and e.kind == kind and localNow - e.killedAt < 0.6 then
				continue -- stale sample of an enemy the Fx stream already killed
			end
			if e and (e.fading or e.kind ~= kind) then
				removeNow(id) -- id was recycled by the server
				e = nil
			end
			if not e then
				local ne = newEnemy(id, kind)
				enemies[id] = ne
				e = ne
			end
			local en = e :: Enemy
			pushSample(en, serverTime, x, z)
			local hp = tonumber(s.hpFrac) or 1
			if hp < en.hpFrac - 0.001 then
				en.hitFrom = localNow + RENDER_DELAY
			end
			en.hpFrac = hp
			en.flags = tonumber(s.flags) or 0
			en.lastFrame = frameIndex
			en.missing = 0
		end
	end
end

----------------------------------------------------------------------
-- Per-frame render
----------------------------------------------------------------------

local function stateColor(base: Color3, state: number): Color3
	local c = base
	if bit32.btest(state, 8) then
		c = c:Lerp(STUN_BLUE, 0.45)
	end
	if bit32.btest(state, 1) then
		c = c:Lerp(GOLD, 0.6)
	end
	if bit32.btest(state, 2) then
		c = c:Lerp(FLASH_RED, 0.75)
	end
	if bit32.btest(state, 4) then
		c = c:Lerp(HIT_WHITE, 0.7)
	end
	return c
end

local function updateBossState(
	bossSum: number,
	bossCount: number,
	bossKey: string?,
	bossDef: any,
	bossId: string?
)
	if bossCount == 0 then
		if lastBossKey ~= nil then
			lastBossKey = nil
			lastBossHp = -1
			State.set("boss", nil)
		end
		return
	end
	local hp = bossSum / bossCount
	if bossKey ~= lastBossKey or math.abs(hp - lastBossHp) > 0.002 then
		lastBossKey = bossKey
		lastBossHp = hp
		State.set("boss", { kind = bossKey, bossId = bossId, def = bossDef, hpFrac = hp, count = bossCount })
	end
end

local function render(dt: number)
	local now = os.clock()
	local off = clockOffset
	if off == nil then
		return
	end
	if now - lastSnapshotLocal > STALE_AFTER then
		for _, e in enemies do
			startFade(e)
		end
	end
	local rt = now + off - RENDER_DELAY
	local flashOn = (math.floor(now * 10) % 2) == 0
	local count = 0
	local turn = 1 - math.exp(-14 * dt)

	local bossSum, bossCount = 0, 0
	local bossKey: string? = nil
	local bossDef: any = nil
	local bossId: string? = nil

	for id, e in enemies do
		local x, z = sampleAt(e, rt)
		local dx, dz = x - e.x, z - e.z
		e.x, e.z = x, z
		if dx * dx + dz * dz > 1e-4 then
			e.yaw = lerpAngle(e.yaw, math.atan2(-dx, -dz), turn)
			e.moving = math.min(1, e.moving + dt * 6)
		else
			e.moving = math.max(0, e.moving - dt * 4)
		end

		if e.fading then
			e.fadeT += dt
			if e.fadeT >= FADE_TIME then
				releaseVisual(e)
				enemies[id] = nil
				continue
			end
		elseif e.visual == nil and visualCount < MAX_VISUALS then
			e.visual = acquireVisual(e)
		end

		local v = e.visual
		if v then
			-- Colour state: elite / telegraph flash / hit flash / stunned.
			local st = 0
			if bit32.btest(e.flags, 1) then
				st += 1
			end
			if bit32.btest(e.flags, 2) and flashOn then
				st += 2
			end
			if not LOW and now >= e.hitFrom and now < e.hitFrom + HIT_FLASH then
				st += 4
			end
			if bit32.btest(e.flags, 4) then
				st += 8
			end
			if st ~= e.colorState then
				e.colorState = st
				for i, p in v.parts do
					if v.tint[i] then
						p.Color = stateColor(v.colors[i], st)
					end
				end
			end
			if e.fading then
				local a = e.fadeT / FADE_TIME
				for i, p in v.parts do
					local b = v.baseTransparency[i]
					p.Transparency = b + (1 - b) * a
				end
			end
			if v.hpFill and math.abs(v.lastHp - e.hpFrac) > 0.001 then
				v.lastHp = e.hpFrac
				v.hpFill.Size = UDim2.fromScale(math.clamp(e.hpFrac, 0, 1), 1)
			end

			local bob = math.abs(math.sin(now * 14 + e.phase)) * v.radius * 0.22 * e.moving
			if v.isBoss then
				bob *= 0.35
			end
			local root = CFrame.new(x, GROUND_Y + bob, z) * CFrame.Angles(0, e.yaw, 0)
			for i, p in v.parts do
				count += 1
				moveParts[count] = p
				moveCFrames[count] = root * v.offsets[i]
			end
		end

		if e.isBoss and not e.fading then
			local key = tostring(e.kind)
			if bossKey == nil or bossKey == key then
				bossKey = key
				bossDef = e.def
				bossId = e.bossId
				bossSum += e.hpFrac
				bossCount += 1
			end
		end
	end

	for i = #moveParts, count + 1, -1 do
		moveParts[i] = nil
		moveCFrames[i] = nil
	end
	if count > 0 then
		workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end

	updateBossState(bossSum, bossCount, bossKey, bossDef, bossId)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- Nearest live enemy to (x, z). Returns (ex, ez, id) or nil.
function HordeRenderer.nearest(x: number, z: number, maxDist: number?): (number?, number?, number?)
	local best: Enemy? = nil
	local bestD = if maxDist then maxDist * maxDist else math.huge
	for _, e in enemies do
		if not e.fading and e.n > 0 then
			local dx, dz = e.x - x, e.z - z
			local d = dx * dx + dz * dz
			if e.isBoss then
				d *= 0.8 -- small preference for bosses at similar range
			end
			if d < bestD then
				bestD = d
				best = e
			end
		end
	end
	if best then
		return best.x, best.z, best.id
	end
	return nil, nil, nil
end

-- Starts the fade-out for an enemy right away (Fx "die" carries its id), so
-- deaths don't wait for the next snapshot to notice the id is gone.
function HordeRenderer.kill(id: number?)
	local e = if id then enemies[id] else nil
	if e then
		e.killedAt = os.clock()
		startFade(e)
	end
end

-- Current rendered position of an enemy/boss id, or nil.
function HordeRenderer.position(id: number): (number?, number?)
	local e = enemies[id]
	if e and e.n > 0 then
		return e.x, e.z
	end
	return nil, nil
end

-- Number of tracked (non-fading) enemies.
function HordeRenderer.count(): number
	local n = 0
	for _, e in enemies do
		if not e.fading then
			n += 1
		end
	end
	return n
end

-- Immediately clears every enemy visual (e.g. on phase change to lobby).
function HordeRenderer.clear()
	for id in enemies do
		removeNow(id)
	end
	updateBossState(0, 0, nil, nil, nil)
end

function HordeRenderer.init()
	if bound then
		return
	end
	bound = true
	getFolder()
	handle = Remotes.on(Remotes.S2C.Snapshot, onSnapshot)
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 2, render)
end

function HordeRenderer.destroy()
	if handle then
		handle.Disconnect()
		handle = nil
	end
	if bound then
		RunService:UnbindFromRenderStep(BIND_NAME)
		bound = false
	end
	HordeRenderer.clear()
	if folder then
		folder:Destroy()
		folder = nil
	end
	table.clear(pools)
end

return HordeRenderer
