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
--
-- v3 animation (Visuals/Rig, no Motor6Ds): mice, champions and bosses are posed
-- procedurally every frame by CFrame offsets on their pooled parts.
--  * Mice: run cycle synced to ground speed (diagonal legs, body bob, ear flop,
--    tail sway), attack lunge (HordeRenderer.lunge, from `hurt` Fx), hit
--    flinch (squash + white flash) and a death pop (hop, roll onto the back,
--    shrink into crumbs) instead of a plain fade.
--  * Champions (kinds 100..199 = 100 + Config/Champions.ORDER index): biped
--    walk, breathing, cape / tail secondary motion, wind-up held for a
--    telegraph's `delay` then a strike (HordeRenderer.windup from `tele` Fx
--    with `src`), roar (`champ` enrage), red enrage glow pulse (Highlight), a
--    topple on death; name tag + HP bar billboard.
--  * Bosses keep their idle channels (Spec anims); legs walk only while moving,
--    and a root pose layer adds the wind-up lean / strike lunge / phase roar /
--    enrage glow / slow death collapse.
--  * LOD by distance to the camera focus: full rig within MouseModels.ANIM_FULL
--    (60 studs, at most NEAR_CAP mice), body + legs only up to 120, the static
--    3-part model beyond (moved every 3rd frame: it is off screen anyway).
--    Low-spec devices draw the low-part model and the simplified rig only.
--  * iter7 (team Mesh): when a procedural mesh is uploaded (Visuals/Assets
--    template), mice / champions / bosses are drawn from its MeshParts, one per
--    rig piece (Visuals/MeshModels + generated Visuals/MeshData): same bones and
--    animation as the part models, conditional pieces (elite crown), boss
--    channels (wheel spin, wing flaps), texture-swap tint. The far LOD, low-spec
--    mice and any missing / incomplete template keep the part models.
--    HordeRenderer.meshStats counts mesh sets, part fallbacks, flat paints, LOD switches.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Remotes = require(Client.Util.Remotes)
local Defs = require(Client.Util.Defs)
local Device = require(Client.Util.Device)
local State = require(script.Parent.State)
-- Visual modules (src/client/Visuals). Each is required defensively: a missing or
-- broken module falls back to a plain 3-part model instead of erroring per frame.
local function visualModule(name: string): any
	local folder = Client:FindFirstChild("Visuals")
	local inst = folder and folder:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		if ok and type(mod) == "table" then
			return mod
		end
		warn("[Trunkfall] Visuals." .. name .. " failed to load: " .. tostring(mod))
	end
	return nil
end
local Spec = visualModule("Spec")
local ArenaHeight = visualModule("ArenaHeight") -- iter4: plateaus lift what we draw
local Rig = visualModule("Rig")
local function fallbackSpecs(def: any, boss: boolean): { any }
	local r = math.max(0.4, tonumber(if type(def) == "table" then def.radius else nil) or 1.2)
	local c = Color3.fromRGB(139, 107, 78)
	if boss and type(def) == "table" and type(def.color) == "table" then
		c = Color3.fromRGB(def.color[1] or 150, def.color[2] or 110, def.color[3] or 190)
	end
	return {
		{
			shape = "Ball",
			size = Vector3.one * 1.6 * r,
			offset = CFrame.new(0, 0.8 * r, 0),
			color = c,
			tint = true,
		},
		{
			shape = "Ball",
			size = Vector3.one * r,
			offset = CFrame.new(0, 1.1 * r, -0.9 * r),
			color = c,
			tint = true,
		},
		{
			shape = "Block",
			size = Vector3.new(1.4 * r, 0.6 * r, 0.12 * r),
			offset = CFrame.new(0, 1.7 * r, -0.8 * r),
			color = c:Lerp(Color3.fromRGB(242, 167, 181), 0.4),
			tint = true,
		},
	}
end
if not Spec then
	Spec = {
		instantiate = function(s: any, parent: Instance, park: CFrame): BasePart
			local p = Instance.new("Part")
			p.Shape = if s.shape == "Ball" then Enum.PartType.Ball else Enum.PartType.Block
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.CastShadow = false
			p.Size = s.size
			p.Color = s.color
			p.CFrame = park
			p.Parent = parent
			return p
		end,
		pose = function(s: any, _t: number, _m: number): CFrame
			return s.offset
		end,
	}
end
local MouseModels = visualModule("MouseModels")
	or {
		LOD_DISTANCE = 120,
		ANIM_FULL = 60,
		build = function(_id: string, def: any, _scale: number?, _elite: boolean?)
			local l = fallbackSpecs(def, false)
			return {
				parts = l,
				low = l,
				lod = l,
				radius = tonumber(type(def) == "table" and def.radius) or 1.2,
			}
		end,
	}
local BossModels = visualModule("BossModels")
	or {
		build = function(_id: string, def: any)
			local r = math.max(2, tonumber(type(def) == "table" and def.radius) or 4)
			local l = fallbackSpecs({ radius = r, color = type(def) == "table" and def.color }, true)
			return { parts = l, radius = r, height = 2 * r }
		end,
	}
local ChampionModels = visualModule("ChampionModels")
local Assets = visualModule("Assets") or {
	template = function(_name: string): Model?
		return nil
	end,
}
-- iter7 (team Mesh): animated procedural meshes (one MeshPart per rig piece).
local MeshModels = visualModule("MeshModels")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local HordeRenderer = {}

local RENDER_DELAY = 0.1
local EXTRAPOLATE_MAX = 0.1
local FADE_TIME = 0.25
local MAX_SAMPLES = 4
local STALE_AFTER = 1.25 -- no snapshot for this long: fade everything
local GROUND_Y = 0
local HIT_FLASH = 0.12 -- v4: a touch longer, and champions flash too
local LOW = Device.lowSpec()
local MAX_VISUALS = if LOW then 220 else 450
local ANIM_FULL = if LOW then 30 else (MouseModels.ANIM_FULL or 60)
local ANIM_SIMPLE = if LOW then 60 else 120
local LOD_DISTANCE = if LOW then 60 else (MouseModels.LOD_DISTANCE or 120)
local NEAR_CAP = if LOW then 24 else (if Device.isMobile() then 70 else 140)
local DEATH_TIME = { mouse = 0.45, champ = 1.1, boss = 1.8 }
local MAX_SQUASH_DEATHS = if LOW then 0 else 14 -- concurrent shrinking deaths (Size writes)
local PARK = CFrame.new(0, -5000, 0)
local BIND_NAME = "TrunkfallHorde"
HordeRenderer.TIERS = { full = ANIM_FULL, simple = ANIM_SIMPLE, lod = LOD_DISTANCE, nearCap = NEAR_CAP }

local GOLD = Color3.fromRGB(255, 196, 40)
local FLASH_RED = Color3.fromRGB(255, 70, 50)
local HIT_WHITE = Color3.fromRGB(255, 255, 255)
local STUN_BLUE = Color3.fromRGB(140, 200, 255)
local ENRAGE_RED = Color3.fromRGB(255, 50, 40)
-- iter8 (team Mesh): "epic" boss variant (boss snapshot flags bit 0): violet
-- tint on the part model, violet Neon accents + a violet Highlight on meshes,
-- drawn as big as the hitbox's size step.
local EPIC_VIOLET = Color3.fromRGB(170, 80, 255)
local IDENT = CFrame.identity

-- One drawable set of parts (the full model, the low model or its far LOD).
type PartSet = {
	parts: { BasePart },
	specs: { any },
	colors: { Color3 },
	tint: { boolean },
	baseTransparency: { number },
	baseSize: { Vector3 },
	animated: boolean,
	rig: any?, -- Rig.Compiled
	squash: { boolean }, -- parts squashed on a flinch (body / head bones)
	mesh: any?, -- iter7: MeshModels.Built (texture-swap tint) when built from a mesh
}

type Visual = {
	key: string,
	kind: string, -- "mouse" | "champ" | "boss"
	style: string,
	full: PartSet,
	low: PartSet?,
	lod: PartSet?,
	active: PartSet,
	radius: number,
	k: number,
	stride: number,
	aim: number,
	isBoss: boolean,
	model: Model?,
	highlight: Highlight?,
	tag: BillboardGui?,
	hpFill: Frame?,
	lastHp: number,
	D: { CFrame },
	A: { CFrame },
	resized: boolean,
	meshMode: boolean, -- iter7: built while meshes were allowed (pools follow the Models setting)
}

type Enemy = {
	id: number,
	kind: number,
	isBoss: boolean,
	isChamp: boolean,
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
	speed: number,
	phase: number,
	hpFrac: number,
	flags: number,
	hitFrom: number,
	lastFrame: number,
	missing: number,
	fading: boolean,
	fadeT: number,
	dying: boolean,
	killedAt: number,
	visual: Visual?,
	colorState: number,
	tier: number,
	pose: any, -- Rig.State
	windAt: number,
	windDur: number,
	enrageGlow: boolean,
	lastHl: number,
	shrinkSlot: boolean,
}

local folder: Folder? = nil
local enemies: { [number]: Enemy } = {}
local pools: { [string]: { Visual } } = {}
local visualCount = 0
local frameNo = 0
local squashDeaths = 0

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
-- Kinds: mice (< 100), champions (100..199), bosses (200+)
----------------------------------------------------------------------

-- Returns (def?, isBoss, id?, isChamp).
local function resolveKind(kind: number): (any, boolean, string?, boolean)
	if kind >= 100 and kind < 200 then
		local idx = kind - 100
		local mod = Defs.module("Champions")
		local id: string? = nil
		if type(mod) == "table" and type(mod.ORDER) == "table" then
			id = mod.ORDER[idx]
		end
		if id == nil and ChampionModels and ChampionModels.ORDER then
			id = ChampionModels.ORDER[idx]
		end
		return (if id then Defs.find(mod, id) else nil), false, id, true
	end
	local def, isBoss, id = Defs.enemyKind(kind)
	return def, isBoss, id, false
end
HordeRenderer.resolveKind = resolveKind

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

local function newSet(specs: { any }, animate: boolean, bones: any?, parent: Instance?): PartSet
	local set: PartSet = {
		parts = {},
		specs = specs,
		colors = {},
		tint = {},
		baseTransparency = {},
		baseSize = {},
		animated = false,
		rig = nil,
		squash = {},
	}
	local into = parent or getFolder()
	for i, sp in specs do
		local p = Spec.instantiate(sp, into, PARK)
		set.parts[i] = p
		set.colors[i] = sp.color
		set.tint[i] = sp.tint == true
		set.baseTransparency[i] = sp.transparency or 0
		set.baseSize[i] = sp.size
		set.squash[i] = sp.bone == "body" or sp.bone == "head"
		if animate and sp.anim then
			set.animated = true
		end
	end
	if bones and Rig then
		local ok, compiled = pcall(Rig.compile, specs, bones)
		if ok then
			set.rig = compiled
		end
	end
	if not animate then
		-- low-spec / far LOD: no legacy channels (the rig still poses)
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

-- iter7 (team Mesh): a set built from a mesh template (Shared.Config.AssetIds ->
-- server AssetLoader -> ReplicatedStorage.TrunkfallAssets.<name>), one MeshPart per
-- rig piece (Visuals/MeshModels: scale from MeshData radius, pivots from the
-- authored piece centres, texture-swap tint). Mice and champions get the Rig
-- skeleton (same bones as the part models: run cycle, ear flop, tail sway,
-- lunge, flinch squash, death); bosses play each piece's anim channel (wheels,
-- wing flaps, arm swings) under the root pose. nil -> the caller uses parts.
local meshStats = { mesh = 0, parts = 0, flat = 0, lod = 0 }
HordeRenderer.meshStats = meshStats

-- Safety switches: Shared.Config.Visuals.USE_MESHES = false turns meshes off for
-- everyone (one-line publish); the player setting models = "classic" (Settings:
-- Models, State "gfx") forces the part models for this player.
local destroyVisual: (Visual) -> ()

local function meshesAllowed(): boolean
	if MeshModels and type(MeshModels.allowed) == "function" then
		return MeshModels.allowed()
	end
	return false
end
HordeRenderer.meshesAllowed = meshesAllowed

local function meshSet(name: string, radius: number, parent: Instance?, bones: boolean): PartSet?
	if not MeshModels or not meshesAllowed() then
		return nil
	end
	local template = Assets.template(name)
	if not template then
		return nil
	end
	local ok, built = pcall(MeshModels.build, template, name, radius, parent or getFolder(), bones)
	if not ok then
		warn("[Trunkfall] mesh " .. name .. " failed: " .. tostring(built))
		return nil
	end
	if not built then
		return nil
	end
	local set: PartSet = {
		parts = built.parts,
		specs = built.specs,
		colors = built.colors,
		tint = built.tint,
		baseTransparency = {},
		baseSize = {},
		animated = built.animated,
		rig = nil,
		squash = {},
		mesh = built,
	}
	for i, p in built.parts do
		local sp = built.specs[i]
		set.baseTransparency[i] = 0
		set.baseSize[i] = sp.size
		set.squash[i] = sp.bone == "body" or sp.bone == "head"
		p.Transparency = 0
		p.CFrame = PARK
	end
	if built.bones and Rig then
		local okc, compiled = pcall(Rig.compile, built.specs, built.bones)
		if okc then
			set.rig = compiled
		end
	end
	meshStats.mesh += 1
	return set
end

-- Tint one part of a set (texture swap on mesh pieces).
local function paintPart(set: PartSet, i: number, p: BasePart, c: Color3?)
	local mesh = set.mesh
	if mesh then
		if c ~= nil then
			meshStats.flat += 1
		end
		MeshModels.paint(mesh, i, c)
	else
		p.Color = c or set.colors[i]
	end
end

local function newVisual(key: string, kind: string, full: PartSet, radius: number): Visual
	return {
		key = key,
		kind = kind,
		style = if kind == "champ" then "biped" elseif kind == "boss" then "boss" else "mouse",
		full = full,
		low = nil,
		lod = nil,
		active = full,
		radius = radius,
		k = 1,
		stride = 2.2,
		aim = 0,
		isBoss = kind == "boss",
		model = nil,
		highlight = nil,
		tag = nil,
		hpFill = nil,
		lastHp = -1,
		D = if Rig then Rig.newPose() else {},
		A = {},
		resized = false,
		meshMode = meshesAllowed(),
	}
end

-- Frees a pooled visual for good (iter7: the Models setting changed).
destroyVisual = function(v: Visual)
	for _, set in { v.full, v.low, v.lod } do
		if set then
			for _, p in set.parts do
				p:Destroy()
			end
		end
	end
	if v.model then
		v.model:Destroy()
	end
end

local function buildMouse(key: string, def: any, id: string?, scale: number?): Visual
	local sid = id or (if type(def) == "table" then def.id else nil) or "mouse"
	local spec = MouseModels.build(sid, def, scale, false)
	local full: PartSet? = nil
	if not LOW then -- low-spec devices keep the low part model
		full = meshSet("mouse_" .. sid, spec.radius, nil, true)
	end
	if not full then
		meshStats.parts += 1
		full = newSet(if LOW then spec.low else spec.parts, not LOW, spec.bones)
	end
	local v = newVisual(key, "mouse", full :: PartSet, spec.radius)
	v.lod = newSet(spec.lod, false, nil)
	v.k = spec.radius / 1.2
	v.stride = spec.stride or 2.2
	return v
end

-- Container model (Highlight adornee) + name tag + HP bar for bosses / champions.
local function addTag(v: Visual, body: BasePart, title: string, sub: string, height: number, big: boolean)
	local tag = Instance.new("BillboardGui")
	tag.Name = if big then "BossTag" else "ChampionTag"
	tag.Size = if big then UDim2.fromOffset(260, 74) else UDim2.fromOffset(190, 52)
	tag.StudsOffsetWorldSpace = Vector3.new(0, height * (if big then 0.75 else 0.62), 0)
	tag.AlwaysOnTop = true
	tag.LightInfluence = 0
	tag.MaxDistance = if big then 400 else 260
	tag.Adornee = body
	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, 0, 0, if big then 32 else 22)
	name.Font = Enum.Font.FredokaOne
	name.TextScaled = true
	name.TextColor3 = if big then Color3.fromRGB(255, 214, 80) else Color3.fromRGB(255, 170, 70)
	name.TextStrokeTransparency = 0
	name.TextStrokeColor3 = Color3.fromRGB(60, 36, 20)
	name.Text = title
	name.Parent = tag
	local subtitle = Instance.new("TextLabel")
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.fromOffset(0, if big then 32 else 22)
	subtitle.Size = UDim2.new(1, 0, 0, if big then 20 else 14)
	subtitle.Font = Enum.Font.GothamBold
	subtitle.TextScaled = true
	subtitle.TextColor3 = Color3.fromRGB(255, 244, 214)
	subtitle.TextStrokeTransparency = 0.2
	subtitle.Text = sub
	subtitle.Parent = tag
	local bar = Instance.new("Frame")
	bar.Position = UDim2.new(0.1, 0, 0, if big then 56 else 38)
	bar.Size = UDim2.new(0.8, 0, 0, if big then 12 else 10)
	bar.BackgroundColor3 = Color3.fromRGB(60, 36, 20)
	bar.BorderSizePixel = 0
	bar.Parent = tag
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = bar
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = if big then Color3.fromRGB(230, 70, 60) else Color3.fromRGB(255, 140, 50)
	fill.BorderSizePixel = 0
	fill.Parent = bar
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0.5, 0)
	fc.Parent = fill
	tag.Enabled = false
	tag.Parent = body
	v.tag = tag
	v.hpFill = fill
end

local function addHighlight(v: Visual, model: Model)
	local hl = Instance.new("Highlight")
	hl.Name = "Glow"
	hl.Adornee = model
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.FillColor = HIT_WHITE
	hl.FillTransparency = 1
	hl.OutlineTransparency = 1
	hl.Enabled = false
	hl.Parent = model
	v.highlight = hl
end

local function holder(name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = getFolder()
	return m
end

local function buildBoss(key: string, def: any, id: string?, scale: number?): Visual
	local sid = id or (if type(def) == "table" then def.id else nil) or "boss"
	local spec = BossModels.build(sid, def)
	local k0 = scale or 1
	if k0 ~= 1 and Spec and type(Spec.scaled) == "function" then
		-- iter8: epic bosses are drawn as big as their hitbox size step
		spec = table.clone(spec)
		spec.parts = Spec.scaled(spec.parts, k0)
		spec.radius *= k0
		spec.height = (spec.height or 2 * spec.radius / k0) * k0
	end
	local model = holder("Boss_" .. sid)
	local full: PartSet? = meshSet("boss_" .. sid, spec.radius, model, false)
	-- iter8: per-boss telegraph poses on the mesh pieces (Rig.BOSS_TELE)
	local teleSet = if full and Rig and Rig.BOSS_TELE then Rig.BOSS_TELE[sid] else nil
	if full and teleSet then
		for _, sp in full.specs do
			sp.tele = if sp.mesh then teleSet[sp.mesh] else nil
		end
	end
	if not full then
		meshStats.parts += 1
		full = newSet(spec.parts, true, nil, model)
	end
	local r = spec.radius
	local v = newVisual(key, "boss", full :: PartSet, r)
	v.k = r * 0.5
	v.stride = r * 2.2
	v.model = model
	addHighlight(v, model)
	local title = if type(def) == "table" and def.title then tostring(def.title) else ""
	addTag(v, (full :: PartSet).parts[1], Defs.name(def, id), title, spec.height, true)
	return v
end

local function buildChamp(key: string, def: any, id: string?): Visual
	local sid = id or (if type(def) == "table" then def.id else nil) or "champ"
	local model = holder("Champion_" .. sid)
	local spec = if ChampionModels then ChampionModels.build(sid, def) else nil
	local r = if spec
		then spec.radius
		else math.max(1.5, tonumber(type(def) == "table" and def.radius) or 2.4)
	-- champion meshes are named by the champion ids (champ_captain, ...)
	local full: PartSet? = meshSet(sid, r, model, true)
	if not full then
		meshStats.parts += 1
		if spec then
			full = newSet(spec.parts, not LOW, spec.bones, model)
		else
			full = newSet(fallbackSpecs({ radius = r }, false), false, nil, model)
		end
	end
	local v = newVisual(key, "champ", full :: PartSet, r)
	v.k = if spec then spec.k else r / 2.4
	v.stride = if spec then spec.stride else 3
	v.aim = if spec then spec.aim or 0 else 0
	v.model = model
	addHighlight(v, model)
	local sub = if type(def) == "table" and def.title then tostring(def.title) else "Champion"
	addTag(
		v,
		(full :: PartSet).parts[1],
		"👑 " .. Defs.name(def, id),
		sub,
		if spec then spec.height else 5,
		false
	)
	return v
end

-- Size step from snapshot flags bits 4-5 (SnapshotCodec.sizeStep): elites and
-- Big Cheese elites are drawn as big as their hitbox. Pools are per kind + step.
local function sizeStep(flags: number): number
	return math.floor((tonumber(flags) or 0) / 16) % 4
end

local function acquireVisual(e: Enemy): Visual?
	local step = if e.isChamp
		then 0
		elseif e.isBoss then (if bit32.btest(e.flags, 1) then sizeStep(e.flags) else 0)
		else sizeStep(e.flags)
	local key = if step > 0 then tostring(e.kind) .. "x" .. step else tostring(e.kind)
	local pool = pools[key]
	local v: Visual? = nil
	-- iter7: pooled visuals built under the other Models choice are dropped
	local allowed = meshesAllowed()
	while pool and #pool > 0 do
		local pv = table.remove(pool) :: Visual
		if pv.meshMode == allowed then
			v = pv
			break
		end
		destroyVisual(pv)
	end
	if v == nil then
		local _, _, id = resolveKind(e.kind)
		if e.isBoss then
			local c = if step > 0 then loadCodec() else nil
			v = buildBoss(
				key,
				e.def,
				id,
				if c and type(c.sizeScale) == "function" then c.sizeScale(e.flags) else 1 + step / 3
			)
		elseif e.isChamp then
			v = buildChamp(key, e.def, id)
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
	e.tier = 0
	if v and Rig then
		e.pose = Rig.newState(e.phase)
		e.pose.aim = v.aim
		if e.isBoss and Rig.BOSS_VARIANTS then
			e.pose.variant = Rig.BOSS_VARIANTS[e.bossId or ""] or "slam"
		end
	end
	return v
end

local function parkSet(set: PartSet)
	for i, p in set.parts do
		p.CFrame = PARK
		p.Transparency = set.baseTransparency[i]
		if set.tint[i] then
			paintPart(set, i, p, nil)
		end
	end
end

local function restoreSizes(v: Visual)
	if v.resized then
		v.resized = false
		for _, set in { v.full, v.low, v.lod } do
			if set then
				for i, p in set.parts do
					p.Size = set.baseSize[i]
				end
			end
		end
	end
end

local function releaseVisual(e: Enemy)
	local v = e.visual
	if not v then
		return
	end
	if e.shrinkSlot then
		e.shrinkSlot = false
		squashDeaths = math.max(0, squashDeaths - 1)
	end
	e.visual = nil
	visualCount -= 1
	restoreSizes(v)
	parkSet(v.full)
	if v.lod then
		parkSet(v.lod)
	end
	v.active = v.full
	if v.tag then
		v.tag.Enabled = false
	end
	if v.highlight then
		v.highlight.Enabled = false
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
	local def, isBoss, bossId, isChamp = resolveKind(kind)
	local phase = math.random() * 10
	return {
		id = id,
		kind = kind,
		isBoss = isBoss,
		isChamp = isChamp,
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
		speed = 0,
		phase = phase,
		hpFrac = 1,
		flags = 0,
		hitFrom = -1,
		lastFrame = 0,
		missing = 0,
		fading = false,
		fadeT = 0,
		dying = false,
		killedAt = -1,
		visual = nil,
		colorState = -1,
		tier = 0,
		pose = nil,
		windAt = 0,
		windDur = 0,
		enrageGlow = false,
		lastHl = -1,
		shrinkSlot = false,
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

-- iteration 6: snapshot kinds that are not enemies (SnapshotCodec.kindClass
-- other than mouse / champion / boss: the Tinkerphant's turrets and
-- barricades) are left to Controllers/BuildRenderer.
local notEnemyKind: { [number]: boolean } = {}
local function isEnemyKind(c: any, kind: number): boolean
	local known = notEnemyKind[kind]
	if known == nil then
		known = false
		if type(c.kindClass) == "function" then
			local ok, cls = pcall(c.kindClass, kind)
			known = ok and type(cls) == "string" and cls ~= "mouse" and cls ~= "champion" and cls ~= "boss"
		end
		notEnemyKind[kind] = known
	end
	return not known
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
		if id and kind and x and z and isEnemyKind(c, kind) then
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
				local ps = en.pose
				if ps and ps.flinch <= 0 and ps.windup <= 0 then
					ps.flinch = 0.001
				end
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
	if bit32.btest(state, 16) then
		c = c:Lerp(ENRAGE_RED, 0.3)
	end
	if bit32.btest(state, 32) then -- iter8: epic boss (part model)
		c = c:Lerp(EPIC_VIOLET, 0.35)
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

-- Switches the drawn part set (parks the old one).
local function useSet(e: Enemy, v: Visual, set: PartSet)
	if v.active ~= set then
		if v.resized then
			restoreSizes(v)
		end
		parkSet(v.active)
		v.active = set
		e.colorState = -1
	end
end

-- Highlight glow for bosses / champions: white hit flash, red enrage pulse.
local function updateGlow(e: Enemy, v: Visual, now: number)
	local hl = v.highlight
	if not hl then
		return
	end
	local hit = now >= e.hitFrom and now < e.hitFrom + HIT_FLASH * 1.4
	local want = -1
	local epic = v.isBoss and bit32.btest(e.flags, 1) -- iter8: epic boss
	if hit then
		want = 0.45
	elseif e.enrageGlow and not e.dying then
		want = 0.62 + 0.18 * math.sin(now * 7)
	elseif epic and not e.dying then
		want = 0.8 + 0.08 * math.sin(now * 2.5)
	end
	if want < 0 then
		if hl.Enabled then
			hl.Enabled = false
		end
		return
	end
	if not hl.Enabled then
		hl.Enabled = true
	end
	local color = if hit then HIT_WHITE elseif e.enrageGlow then ENRAGE_RED else EPIC_VIOLET
	if hl.FillColor ~= color then
		hl.FillColor = color
		hl.OutlineColor = color
	end
	if math.abs(e.lastHl - want) > 0.02 then
		e.lastHl = want
		hl.FillTransparency = want
		hl.OutlineTransparency = if hit then 0.3 else 0.4
	end
end

local function render(dt: number)
	local now = os.clock()
	local off = clockOffset
	if off == nil then
		return
	end
	frameNo += 1
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
	local nearUsed = 0

	local bossSum, bossCount = 0, 0
	local bossKey: string? = nil
	local bossDef: any = nil
	local bossId: string? = nil

	for id, e in enemies do
		local x, z = sampleAt(e, rt)
		local dx, dz = x - e.x, z - e.z
		e.x, e.z = x, z
		local moved2 = dx * dx + dz * dz
		if moved2 > 1e-4 and not e.dying then
			e.yaw = lerpAngle(e.yaw, math.atan2(-dx, -dz), turn)
			e.moving = math.min(1, e.moving + dt * 6)
		else
			e.moving = math.max(0, e.moving - dt * 4)
		end
		if dt > 0 then
			e.speed += (math.sqrt(moved2) / dt - e.speed) * math.min(1, dt * 10)
		end

		local v = e.visual
		local deathTime = DEATH_TIME[if v then v.kind else "mouse"] or 0.45
		if e.fading then
			e.fadeT += dt
			if e.fadeT >= (if e.dying then deathTime else FADE_TIME) then
				releaseVisual(e)
				enemies[id] = nil
				continue
			end
		elseif v == nil and visualCount < MAX_VISUALS then
			e.visual = acquireVisual(e)
			v = e.visual
		end

		if v then
			local ps = e.pose
			-- tier by distance to the camera focus (hysteresis of 6 studs)
			local ddx, ddz = x - focusX, z - focusZ
			local d2 = ddx * ddx + ddz * ddz
			local hyst = if e.tier == 3 then -6 else 6
			local tier: number
			if v.kind ~= "mouse" then
				tier = if d2 < (ANIM_SIMPLE + hyst) ^ 2 then 1 else 2
			elseif d2 >= (LOD_DISTANCE + hyst) ^ 2 and v.lod then
				tier = 3
			elseif d2 < ANIM_FULL * ANIM_FULL and nearUsed < NEAR_CAP then
				tier = 1
				nearUsed += 1
			else
				tier = 2
			end
			if tier ~= e.tier then
				e.tier = tier
				local lodSet = v.lod
				if tier == 3 and lodSet and v.active ~= lodSet then
					meshStats.lod += 1
				end
				useSet(e, v, if tier == 3 and lodSet then lodSet else v.full)
			end
			local set = v.active

			-- far LOD: off screen, static, refreshed every 3rd frame
			if tier == 3 and not e.fading and (frameNo + id) % 3 ~= 0 then
				continue
			end

			local elite = bit32.btest(e.flags, 1)
			local epic = elite and v.isBoss -- iter8: bit 0 on a boss = the epic variant
			-- Colour state: elite / telegraph flash / hit flash / stunned / enraged.
			local st = 0
			if elite and not (epic and set.mesh) then
				st += if epic then 32 else 1
			end
			if bit32.btest(e.flags, 2) and flashOn then
				st += 2
			end
			if not LOW and now >= e.hitFrom and now < e.hitFrom + HIT_FLASH and v.kind ~= "boss" then
				st += 4
			end
			if bit32.btest(e.flags, 4) then
				st += 8
			end
			if e.enrageGlow and v.kind ~= "mouse" and math.sin(now * 7) > 0 then
				st += 16
			end
			if st ~= e.colorState then
				e.colorState = st
				for i, p in set.parts do
					if set.tint[i] then
						paintPart(
							set,
							i,
							p,
							if st == 0 and set.mesh then nil else stateColor(set.colors[i], st)
						)
					elseif set.mesh and v.isBoss then
						-- epic meshes: the Neon accents (eyes, glows) turn violet
						p.Color = if epic then EPIC_VIOLET else set.colors[i]
					end
				end
			end
			if v.highlight then
				updateGlow(e, v, now)
			end
			if v.hpFill and math.abs(v.lastHp - e.hpFrac) > 0.001 then
				v.lastHp = e.hpFrac
				v.hpFill.Size = UDim2.fromScale(math.clamp(e.hpFrac, 0, 1), 1)
			end

			-- animation state
			local k = v.k
			local deathF = 0
			if ps then
				if e.windDur > 0 then
					local f = (now - e.windAt) / math.min(0.35, e.windDur)
					if now >= e.windAt + e.windDur then
						e.windDur = 0
						ps.windup = 0
						ps.strike = 0.001
					else
						ps.windup = math.clamp(f, 0, 1)
					end
				end
				ps.moving = if e.dying then 0 else e.moving
				Rig.step(ps, dt, if e.dying then 0 else e.speed, k, v.stride)
				if e.dying then
					deathF = math.min(1, e.fadeT / deathTime)
					ps.dead = deathF
				end
			end

			-- root frame (ground point + yaw) and the whole-body pose
			local gy = GROUND_Y
			if ArenaHeight and tier ~= 3 then
				gy += ArenaHeight.at(x, z)
			end
			local base = CFrame.new(x, gy, z) * CFrame.Angles(0, e.yaw, 0)
			local root = base
			if ps and tier ~= 3 then
				local rp = Rig.rootPose(v.style, ps, k * (if v.kind == "boss" then 1.6 else 1))
				if rp ~= IDENT then
					root = base * rp
				end
			elseif not ps and v.kind == "boss" then
				root = base + Vector3.new(0, math.sin(now * 1.6 + e.phase) * v.radius * 0.02, 0)
			end

			-- fade / shrink while dying or fading out
			local alpha = 0
			local shrink = 1
			if e.fading then
				if e.dying then
					local tail = if v.kind == "mouse" then 0.55 else 0.6
					alpha = math.clamp((deathF - tail) / (1 - tail), 0, 1)
					if v.kind == "mouse" then
						shrink = 1 - 0.75 * math.clamp((deathF - 0.35) / 0.65, 0, 1)
					end
				else
					alpha = e.fadeT / FADE_TIME
				end
				for i, p in set.parts do
					local b0 = set.baseTransparency[i]
					p.Transparency = b0 + (1 - b0) * alpha
				end
			end

			local rig = set.rig
			local detail = if tier == 1 and not LOW then 1 else 2
			if rig and ps and tier ~= 3 then
				Rig.pose(v.style, ps, v.D, k, detail)
				Rig.solve(rig, root, v.D, v.A)
			end
			local t = (ps and ps.t) or (now + e.phase)
			local walk = if v.isBoss then math.max(0.15, e.moving) else e.moving
			-- flinch squash (full tier mice) / death shrink (Size writes, capped)
			local squashK = 0
			if tier == 1 and ps and v.kind == "mouse" and not LOW then
				if e.dying and shrink < 1 and (e.shrinkSlot or squashDeaths < MAX_SQUASH_DEATHS) then
					if not e.shrinkSlot then
						e.shrinkSlot = true
						squashDeaths += 1
					end
					squashK = -1
				elseif ps.flinch > 0 and not e.dying then
					squashK = Rig.punch(ps.flinch, 0.25)
				end
			end
			if squashK ~= 0 then
				v.resized = true
				local sq = Vector3.new(1 + 0.14 * squashK, 1 - 0.2 * squashK, 1 + 0.14 * squashK)
				for i, p in set.parts do
					if squashK < 0 then
						p.Size = set.baseSize[i] * shrink
					elseif set.squash[i] then
						p.Size = set.baseSize[i] * sq
					end
				end
			elseif v.resized and not e.dying then
				restoreSizes(v)
			end
			local rootInv = if shrink < 1 and e.shrinkSlot then root:Inverse() else nil
			local specs = set.specs
			local animated = set.animated
			for i, p in set.parts do
				local sp = specs[i]
				count += 1
				moveParts[count] = p
				local cf: CFrame
				if sp.cond == "elite" and not elite then
					cf = PARK
				elseif sp.ground then
					-- iter3 (T-26): contact shadows / rings stay flat under a tipping body
					cf = base * sp.offset
				else
					if rig and ps and tier ~= 3 then
						local b = rig.partBone[i]
						cf = (if b == 0 then root else v.A[b]) * rig.partLocal[i]
						local an = sp.anim
						if animated and an and an.kind ~= "pulse" and an.kind ~= "bob" and b == 0 then
							cf = root * Spec.pose(sp, t, walk)
						end
					elseif animated and sp.anim and tier ~= 3 then
						cf = root * Spec.pose(sp, t, walk)
					else
						cf = root * sp.offset
					end
					local tele = sp.tele
					if tele and ps and (ps.windup > 0 or ps.strike > 0) and tier ~= 3 then
						-- iter8: boss telegraph pose about the piece's joint
						local tr = Rig.telePose(tele, ps)
						if tr ~= IDENT then
							local j = sp.joint
							cf = root * (j * tr * j:Inverse() * root:ToObjectSpace(cf))
						end
					end
					if rootInv then
						local l = rootInv * cf
						cf = root * (l - l.Position * (1 - shrink))
					end
					local an = sp.anim
					if animated and an and an.kind == "pulse" and not e.fading then
						local pulse = an.amp * (0.5 + 0.5 * math.sin(t * an.freq))
						p.Transparency = math.clamp(set.baseTransparency[i] + pulse, 0, 1)
					end
				end
				moveCFrames[count] = cf
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
			if e.isBoss or e.isChamp then
				d *= 0.8 -- small preference for bosses / champions at similar range
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

-- Starts the death animation for an enemy right away (Fx "die" carries its id),
-- so deaths don't wait for the next snapshot to notice the id is gone.
-- iter1: true when `id` is a boss the renderer draws (kill beat, intro).
function HordeRenderer.isBoss(id: number?): boolean
	local e = if id then enemies[id] else nil
	return e ~= nil and e.isBoss == true
end

function HordeRenderer.kill(id: number?)
	local e = if id then enemies[id] else nil
	if e and not e.fading then
		e.killedAt = os.clock()
		e.dying = e.visual ~= nil and e.pose ~= nil
		e.windDur = 0
		startFade(e)
	end
end

-- Attack lunge (a mouse that just bit a hero; `hurt` Fx `by`).
function HordeRenderer.lunge(id: number?)
	local e = if id then enemies[id] else nil
	local ps = e and e.pose
	if ps and not (e :: Enemy).fading and ps.lunge <= 0 then
		ps.lunge = 0.001
	end
end

-- Telegraphed attack: hold the wind-up pose for `delay` seconds, then strike
-- (synced to the `tele` Fx of the caster: its `src` id).
-- iter2: a boss plays the clip of the telegraph's pattern base (Rig.CLIP_FOR_STYLE:
-- slam / charge / volley / summon / roulette / breath), else its own default.
function HordeRenderer.windup(id: number?, delay: number?, style: string?, shape: string?)
	local e = if id then enemies[id] else nil
	if e and not e.fading then
		e.windAt = os.clock()
		e.windDur = math.clamp(tonumber(delay) or 0.8, 0.15, 6)
		if e.isBoss and e.pose and Rig and Rig.clipFor then
			e.pose.variant = Rig.clipFor(e.bossId, style, shape)
		end
	end
end

-- An immediate strike pose (slam without a telegraph).
function HordeRenderer.strike(id: number?)
	local e = if id then enemies[id] else nil
	local ps = e and e.pose
	if ps and not (e :: Enemy).fading and ps.strike <= 0 and (e :: Enemy).windDur <= 0 then
		ps.strike = 0.001
	end
end

-- Phase-change / enrage roar.
function HordeRenderer.roar(id: number?)
	local e = if id then enemies[id] else nil
	local ps = e and e.pose
	if ps and not (e :: Enemy).fading then
		ps.roar = 0.001
	end
end

-- Enrage: faster idle, red glow pulse (Highlight), roar.
function HordeRenderer.enrage(id: number?, on: boolean?)
	local e = if id then enemies[id] else nil
	if e then
		e.enrageGlow = on ~= false
		if e.pose then
			e.pose.enraged = on ~= false
		end
		if on ~= false then
			HordeRenderer.roar(id)
		end
	end
end

-- Ids of plain mice (no bosses / champions) within r of (x, z), nearest
-- first, at most `cap` (Fx `rally` aura).
function HordeRenderer.miceWithin(x: number, z: number, r: number, cap: number): { number }
	local found: { { id: number, d: number } } = {}
	local r2 = r * r
	for id, e in enemies do
		if not e.fading and e.n > 0 and not e.isBoss and not e.isChamp then
			local d = (e.x - x) ^ 2 + (e.z - z) ^ 2
			if d <= r2 then
				table.insert(found, { id = id, d = d })
			end
		end
	end
	table.sort(found, function(a, b)
		return a.d < b.d
	end)
	local out = {}
	for i = 1, math.min(cap, #found) do
		out[i] = found[i].id
	end
	return out
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
	squashDeaths = 0
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
