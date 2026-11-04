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
local Device = require(Client.Util.Device)
local State = require(script.Parent.State)
local Spec = require(Client.Visuals.Spec)
local MouseModels = require(Client.Visuals.MouseModels)
local BossModels = require(Client.Visuals.BossModels)
local Assets = require(Client.Visuals.Assets)

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
local LOD_DISTANCE = if LOW then 50 else MouseModels.LOD_DISTANCE
local PARK = CFrame.new(0, -5000, 0)
local BIND_NAME = "TrunkfallHorde"

local GOLD = Color3.fromRGB(255, 196, 40)
local FLASH_RED = Color3.fromRGB(255, 70, 50)
local HIT_WHITE = Color3.fromRGB(255, 255, 255)
local STUN_BLUE = Color3.fromRGB(140, 200, 255)

-- One drawable set of parts (the full model, or its far LOD).
type PartSet = {
	parts: { BasePart },
	specs: { any },
	colors: { Color3 },
	tint: { boolean },
	baseTransparency: { number },
	animated: boolean,
}

type Visual = {
	key: string,
	full: PartSet,
	lod: PartSet?,
	useLod: boolean,
	elite: boolean,
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

local function newSet(specs: { any }, animate: boolean): PartSet
	local set: PartSet = {
		parts = {},
		specs = specs,
		colors = {},
		tint = {},
		baseTransparency = {},
		animated = false,
	}
	local parent = getFolder()
	for i, sp in specs do
		local p = Spec.instantiate(sp, parent, PARK)
		set.parts[i] = p
		set.colors[i] = sp.color
		set.tint[i] = sp.tint == true
		set.baseTransparency[i] = sp.transparency or 0
		if animate and sp.anim then
			set.animated = true
		end
	end
	if not animate then
		-- low-spec: freeze every channel at its rest pose
		local frozen = {}
		for i, sp in specs do
			local c = table.clone(sp)
			c.anim = nil
			frozen[i] = c
		end
		set.specs = frozen
	end
	return set
end

-- A set built from a mesh template (Shared.Config.AssetIds -> server AssetLoader ->
-- ReplicatedStorage.TrunkfallAssets.<name>), scaled to the hitbox radius.
local function meshSet(template: Model, radius: number): PartSet?
	local ok, model = pcall(function()
		return template:Clone()
	end)
	if not ok or not model then
		return nil
	end
	local target = tonumber(template:GetAttribute("Radius"))
	if not target then
		local _, size = model:GetBoundingBox()
		target = math.max(size.X, size.Z) / 2
	end
	if target and target > 0 then
		pcall(function()
			model:ScaleTo(radius / target)
		end)
	end
	local pivot = model:GetPivot()
	local specs = {}
	local set: PartSet = { parts = {}, specs = specs, colors = {}, tint = {}, baseTransparency = {}, animated = false }
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			local i = #set.parts + 1
			set.parts[i] = d
			specs[i] = { offset = pivot:ToObjectSpace(d.CFrame), color = d.Color, tint = true }
			set.colors[i] = d.Color
			set.tint[i] = true
			set.baseTransparency[i] = d.Transparency
		end
	end
	if #set.parts == 0 then
		model:Destroy()
		return nil
	end
	for _, p in set.parts do
		p.Parent = getFolder()
		p.CFrame = PARK
	end
	model:Destroy()
	return set
end

local function newVisual(key: string, full: PartSet, lod: PartSet?, radius: number, isBoss: boolean): Visual
	return {
		key = key,
		full = full,
		lod = lod,
		useLod = false,
		elite = false,
		radius = radius,
		isBoss = isBoss,
		tag = nil,
		hpFill = nil,
		lastHp = -1,
	}
end

local function buildMouse(key: string, def: any, id: string?, scale: number?): Visual
	local sid = id or (if type(def) == "table" then def.id else nil) or "mouse"
	local spec = MouseModels.build(sid, def, scale, false)
	local full: PartSet? = nil
	local template = Assets.template("mouse_" .. sid)
	if template then
		full = meshSet(template, spec.radius)
	end
	if not full then
		full = newSet(if LOW then spec.low else spec.parts, not LOW)
	end
	return newVisual(key, full :: PartSet, newSet(spec.lod, false), spec.radius, false)
end

local function buildBoss(key: string, def: any, id: string?): Visual
	local sid = id or (if type(def) == "table" then def.id else nil) or "boss"
	local spec = BossModels.build(sid, def)
	local full: PartSet? = nil
	local template = Assets.template("boss_" .. sid)
	if template then
		full = meshSet(template, spec.radius)
	end
	if not full then
		full = newSet(spec.parts, true)
	end
	local r = spec.radius
	local v = newVisual(key, full :: PartSet, nil, r, true)
	local body = (full :: PartSet).parts[1]

	-- Name tag + small hp bar.
	local tag = Instance.new("BillboardGui")
	tag.Name = "BossTag"
	tag.Size = UDim2.fromOffset(260, 74)
	tag.StudsOffsetWorldSpace = Vector3.new(0, spec.height * 0.75, 0)
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

-- Size step from snapshot flags bits 4-5 (SnapshotCodec.sizeStep): elites and
-- Big Cheese elites are drawn as big as their hitbox. Pools are per kind + step.
local function sizeStep(flags: number): number
	return math.floor((tonumber(flags) or 0) / 16) % 4
end

local function acquireVisual(e: Enemy): Visual?
	local step = if e.isBoss then 0 else sizeStep(e.flags)
	local key = if step > 0 then tostring(e.kind) .. "x" .. step else tostring(e.kind)
	local pool = pools[key]
	local v: Visual? = nil
	if pool and #pool > 0 then
		v = table.remove(pool)
	else
		local _, _, id = Defs.enemyKind(e.kind)
		if e.isBoss then
			v = buildBoss(key, e.def, id)
		else
			local c = loadCodec()
			local scale = if c and type(c.sizeScale) == "function" then c.sizeScale(e.flags) else 1 + step / 3
			v = buildMouse(key, e.def, id, scale)
		end
	end
	if v and v.tag then
		v.tag.Enabled = true
	end
	visualCount += 1
	e.colorState = -1
	return v
end

local function parkSet(set: PartSet)
	for i, p in set.parts do
		p.CFrame = PARK
		p.Transparency = set.baseTransparency[i]
		p.Color = set.colors[i]
	end
end

local function releaseVisual(e: Enemy)
	local v = e.visual
	if not v then
		return
	end
	e.visual = nil
	visualCount -= 1
	parkSet(v.full)
	if v.lod then
		parkSet(v.lod)
	end
	v.useLod = false
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
	local cam = workspace.CurrentCamera
	local focusX, focusZ = 0, 0
	if cam then
		local f = cam.Focus.Position
		focusX, focusZ = f.X, f.Z
	end

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
			-- LOD: far mice switch to their 3-part model (bosses never do).
			local lodSet = v.lod
			if lodSet then
				local ddx, ddz = x - focusX, z - focusZ
				local far = ddx * ddx + ddz * ddz > LOD_DISTANCE * LOD_DISTANCE
				if far ~= v.useLod then
					v.useLod = far
					parkSet(if far then v.full else lodSet)
					e.colorState = -1
				end
			end
			local set = if v.useLod and lodSet then lodSet else v.full
			local elite = bit32.btest(e.flags, 1)
			-- Colour state: elite / telegraph flash / hit flash / stunned.
			local st = 0
			if elite then
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
				for i, p in set.parts do
					if set.tint[i] then
						p.Color = stateColor(set.colors[i], st)
					end
				end
			end
			if e.fading then
				local a = e.fadeT / FADE_TIME
				for i, p in set.parts do
					local b0 = set.baseTransparency[i]
					p.Transparency = b0 + (1 - b0) * a
				end
			end
			if v.hpFill and math.abs(v.lastHp - e.hpFrac) > 0.001 then
				v.lastHp = e.hpFrac
				v.hpFill.Size = UDim2.fromScale(math.clamp(e.hpFrac, 0, 1), 1)
			end

			local bob = math.abs(math.sin(now * 14 + e.phase)) * v.radius * 0.18 * e.moving
			if v.isBoss then
				bob = math.sin(now * 1.6 + e.phase) * v.radius * 0.02
			end
			local root = CFrame.new(x, GROUND_Y + bob, z) * CFrame.Angles(0, e.yaw, 0)
			local t = now + e.phase
			local walk = if v.isBoss then 1 else e.moving
			for i, p in set.parts do
				local sp = set.specs[i]
				count += 1
				moveParts[count] = p
				if sp.cond == "elite" and not elite then
					moveCFrames[count] = PARK
				elseif set.animated and sp.anim then
					moveCFrames[count] = root * Spec.pose(sp, t, walk)
					if sp.anim.kind == "pulse" and not e.fading then
						local pulse = sp.anim.amp * (0.5 + 0.5 * math.sin(t * sp.anim.freq))
						p.Transparency = math.clamp(set.baseTransparency[i] + pulse, 0, 1)
					end
				else
					moveCFrames[count] = root * sp.offset
				end
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
