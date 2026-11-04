-- Behaviour of non-service classes: parts and models (CFrame/pivots), GUI
-- geometry, humanoids, players, remotes and bindables, tweens, sounds.

local roblox = require("@lune/roblox")
local Core = require("./Core")
local Signal = require("./Signal")
local Inst = require("./Instance")

local Vector3 = roblox.Vector3
local Vector2 = roblox.Vector2
local CFrame = roblox.CFrame
local Enum = roblox.Enum

local D = Inst.D
local reg = Inst.reg
local rawGet, rawSet = Inst.rawGet, Inst.rawSet
local typeOf = Core.typeof

local Classes = {}

local function methods(cls)
	return reg(Inst.METHODS, cls)
end
local function events(cls)
	return reg(Inst.EVENTS, cls)
end
local function getters(cls)
	return reg(Inst.GETTERS, cls)
end
local function setters(cls)
	return reg(Inst.SETTERS, cls)
end

local function serverOnly(what: string)
	return function(ctx)
		if ctx and ctx.isClient then
			error(what .. " can only be used on the server", 3)
		end
	end
end
local function clientOnly(what: string)
	return function(ctx)
		if ctx == nil or ctx.isServer then
			error(what .. " can only be used from a LocalScript (client)", 3)
		end
	end
end
Classes.serverOnly = serverOnly
Classes.clientOnly = clientOnly

-- Parts ---------------------------------------------------------------------------------

do
	local G, S = getters("BasePart"), setters("BasePart")
	G.Position = function(d)
		return rawGet(d, "CFrame").Position
	end
	S.Position = function(d, v)
		local cf = rawGet(d, "CFrame")
		rawSet(d, "CFrame", CFrame.new(v) * cf.Rotation)
		Inst.firePropChanged(d, "Position")
	end
	S.CFrame = function(d, v)
		rawSet(d, "CFrame", v)
		Inst.firePropChanged(d, "Position")
	end
	local function orient(d)
		local rx, ry, rz = rawGet(d, "CFrame"):ToOrientation()
		return Vector3.new(math.deg(rx), math.deg(ry), math.deg(rz))
	end
	G.Orientation = orient
	G.Rotation = orient
	local function setOrient(d, v)
		local cf = rawGet(d, "CFrame")
		rawSet(
			d,
			"CFrame",
			CFrame.new(cf.Position) * CFrame.fromOrientation(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
		)
	end
	S.Orientation = setOrient
	S.Rotation = setOrient
	G.AssemblyMass = function(d)
		local s = rawGet(d, "Size")
		return s.X * s.Y * s.Z * 0.7
	end
	G.Mass = G.AssemblyMass

	local M = methods("BasePart")
	function M.GetPivot(p)
		local d = Inst.self(p, "GetPivot")
		return rawGet(d, "CFrame") * rawGet(d, "PivotOffset")
	end
	function M.PivotTo(p, cf)
		local d = Inst.self(p, "PivotTo")
		if typeOf(cf) ~= "CFrame" then
			error("invalid argument #1 to 'PivotTo' (CFrame expected)", 2)
		end
		S.CFrame(d, cf * rawGet(d, "PivotOffset"):Inverse())
	end
	function M.GetMass(p)
		return G.AssemblyMass(Inst.self(p, "GetMass"))
	end
	function M.ApplyImpulse() end
	function M.ApplyAngularImpulse() end
	function M.SetNetworkOwner() end
	function M.SetNetworkOwnershipAuto() end
	function M.GetNetworkOwner()
		return nil
	end
	function M.GetTouchingParts()
		return {}
	end
	function M.GetConnectedParts(p)
		return { p }
	end
	function M.CanCollideWith()
		return true
	end
	function M.BreakJoints() end
	function M.GetVelocityAtPosition()
		return Vector3.zero
	end
	local E = events("BasePart")
	E.Touched = true
	E.TouchEnded = true
	Inst.reg(Inst.DEFAULTS, "BasePart").CFrame = CFrame.identity
	Inst.reg(Inst.DEFAULTS, "Part").Size = Vector3.new(4, 1, 2)
end

-- Models / pivots --------------------------------------------------------------------

local function descendantParts(d, out)
	for _, c in d.children do
		local cd = D[c]
		if cd.cls.isA.BasePart then
			table.insert(out, cd)
		end
		descendantParts(cd, out)
	end
	return out
end

local function modelPivot(d): any
	local pp = rawGet(d, "PrimaryPart")
	if pp and D[pp] and not D[pp].destroyed then
		local pd = D[pp]
		return rawGet(pd, "CFrame") * rawGet(pd, "PivotOffset")
	end
	if d.extra.worldPivot then
		return d.extra.worldPivot
	end
	local parts = descendantParts(d, {})
	if #parts == 0 then
		return CFrame.identity
	end
	local minV, maxV
	for _, pd in parts do
		local pos = rawGet(pd, "CFrame").Position
		minV = if minV then minV:Min(pos) else pos
		maxV = if maxV then maxV:Max(pos) else pos
	end
	local cf = CFrame.new((minV + maxV) / 2)
	d.extra.worldPivot = cf
	return cf
end

do
	local M = methods("Model")
	function M.GetPivot(p)
		return modelPivot(Inst.self(p, "GetPivot"))
	end
	function M.PivotTo(p, cf)
		local d = Inst.self(p, "PivotTo")
		if typeOf(cf) ~= "CFrame" then
			error("invalid argument #1 to 'PivotTo' (CFrame expected)", 2)
		end
		local cur = modelPivot(d)
		local delta = cf * cur:Inverse()
		for _, pd in descendantParts(d, {}) do
			local setter = Inst.SETTERS.BasePart.CFrame
			setter(pd, delta * rawGet(pd, "CFrame"))
		end
		if not rawGet(d, "PrimaryPart") then
			d.extra.worldPivot = cf
		end
	end
	function M.SetPrimaryPartCFrame(p, cf)
		local d = Inst.self(p, "SetPrimaryPartCFrame")
		if not rawGet(d, "PrimaryPart") then
			error("Model:SetPrimaryPartCFrame() failed because no PrimaryPart has been set", 2)
		end
		M.PivotTo(p, cf)
	end
	function M.GetPrimaryPartCFrame(p)
		local d = Inst.self(p, "GetPrimaryPartCFrame")
		local pp = rawGet(d, "PrimaryPart")
		return if pp then pp.CFrame else nil
	end
	function M.MoveTo(p, pos)
		local cur = M.GetPivot(p)
		M.PivotTo(p, cur.Rotation + pos)
	end
	function M.GetBoundingBox(p)
		local d = Inst.self(p, "GetBoundingBox")
		local parts = descendantParts(d, {})
		if #parts == 0 then
			return modelPivot(d), Vector3.zero
		end
		local minV, maxV
		for _, pd in parts do
			local pos, size = rawGet(pd, "CFrame").Position, rawGet(pd, "Size")
			local lo, hi = pos - size / 2, pos + size / 2
			minV = if minV then minV:Min(lo) else lo
			maxV = if maxV then maxV:Max(hi) else hi
		end
		return CFrame.new((minV + maxV) / 2), maxV - minV
	end
	function M.GetExtentsSize(p)
		local _, size = M.GetBoundingBox(p)
		return size
	end
	function M.GetScale()
		return 1
	end
	function M.ScaleTo() end
	function M.TranslateBy(p, v)
		M.PivotTo(p, M.GetPivot(p) + v)
	end
	local G, S = getters("Model"), setters("Model")
	G.WorldPivot = function(d)
		return modelPivot(d)
	end
	S.WorldPivot = function(d, v)
		d.extra.worldPivot = v
	end
end

do
	local G = getters("Attachment")
	local function parentCF(d)
		local par = d.parent and D[d.parent]
		if par and par.cls.isA.BasePart then
			return rawGet(par, "CFrame")
		end
		return CFrame.identity
	end
	G.WorldCFrame = function(d)
		return parentCF(d) * rawGet(d, "CFrame")
	end
	G.WorldPosition = function(d)
		return (parentCF(d) * rawGet(d, "CFrame")).Position
	end
	G.Position = function(d)
		return rawGet(d, "CFrame").Position
	end
	local S = setters("Attachment")
	S.Position = function(d, v)
		rawSet(d, "CFrame", CFrame.new(v) * rawGet(d, "CFrame").Rotation)
	end
end

-- GUI geometry -------------------------------------------------------------------------

local function viewportFor(d): any
	-- the viewport of the client that owns this GUI (PlayerGui's player), else default
	local ctx = d.vis or Core.current()
	if ctx and ctx.viewport then
		return ctx.viewport
	end
	local p = d.parent
	while p do
		local pd = D[p]
		if pd.className == "Player" then
			local c = Core.rt and Core.rt.clientOf[p]
			if c then
				return c.viewport
			end
		end
		p = pd.parent
	end
	return Vector2.new(1280, 720)
end

local absSize
local function parentAbs(d): (any, any)
	local par = d.parent and D[d.parent]
	if par and par.cls.isA.GuiBase2d then
		local size = absSize(par)
		local pos = Inst.GETTERS.GuiBase2d.AbsolutePosition(par)
		return size, pos
	end
	return viewportFor(d), Vector2.zero
end

absSize = function(d): any
	local cls = d.cls
	if cls.isA.LayerCollector then
		if d.className == "ScreenGui" then
			return viewportFor(d)
		end
		local s = rawGet(d, "Size")
		if typeOf(s) == "UDim2" then
			return Vector2.new(s.X.Offset + s.X.Scale * 100, s.Y.Offset + s.Y.Scale * 100)
		end
		return Vector2.new(800, 600)
	end
	if not cls.props.Size then
		return Vector2.zero
	end
	local s = rawGet(d, "Size")
	local pa = parentAbs(d)
	return Vector2.new(pa.X * s.X.Scale + s.X.Offset, pa.Y * s.Y.Scale + s.Y.Offset)
end

do
	local G = getters("GuiBase2d")
	G.AbsoluteSize = absSize
	G.AbsolutePosition = function(d)
		if d.cls.isA.LayerCollector or not d.cls.props.Position then
			return Vector2.zero
		end
		local pa, pp = parentAbs(d)
		local pos = rawGet(d, "Position")
		local size = absSize(d)
		local anchor = if d.cls.props.AnchorPoint then rawGet(d, "AnchorPoint") else Vector2.zero
		return Vector2.new(
			pp.X + pa.X * pos.X.Scale + pos.X.Offset - anchor.X * size.X,
			pp.Y + pa.Y * pos.Y.Scale + pos.Y.Offset - anchor.Y * size.Y
		)
	end
	G.AbsoluteRotation = function(d)
		return if d.cls.props.Rotation then rawGet(d, "Rotation") else 0
	end
	local function textBounds(d)
		local text = tostring(rawGet(d, "Text") or "")
		local size = rawGet(d, "TextSize") or 14
		local lines = 1
		for _ in string.gmatch(text, "\n") do
			lines += 1
		end
		local w = math.min(utf8.len(text) or #text, 400) * size * 0.5
		return Vector2.new(w, size * lines)
	end
	for _, cls in { "TextLabel", "TextButton", "TextBox" } do
		local g = getters(cls)
		g.TextBounds = textBounds
		g.TextFits = function()
			return true
		end
		g.ContentText = function(d)
			return rawGet(d, "Text")
		end
	end
	Inst.reg(Inst.DEFAULTS, "TextLabel").TextSize = 14
	Inst.reg(Inst.DEFAULTS, "TextButton").TextSize = 14
	Inst.reg(Inst.DEFAULTS, "TextBox").TextSize = 14

	local E = events("GuiObject")
	E.InputBegan = true
	E.InputEnded = true
	E.InputChanged = true
	E.MouseEnter = true
	E.MouseLeave = true
	E.MouseMoved = true
	E.MouseWheelForward = true
	E.MouseWheelBackward = true
	E.TouchTap = true
	E.TouchLongPress = true
	E.TouchPan = true
	E.TouchPinch = true
	E.TouchSwipe = true
	E.SelectionGained = true
	E.SelectionLost = true
	local B = events("GuiButton")
	B.Activated = true
	B.MouseButton1Click = true
	B.MouseButton1Down = true
	B.MouseButton1Up = true
	B.MouseButton2Click = true
	B.MouseButton2Down = true
	B.MouseButton2Up = true
	local T = events("TextBox")
	T.FocusLost = true
	T.Focused = true
	T.ReturnPressedFromOnScreenKeyboard = true
	local TM = methods("TextBox")
	function TM.CaptureFocus() end
	function TM.ReleaseFocus() end
	function TM.IsFocused()
		return false
	end

	local GM = methods("GuiObject")
	local function tweenProps(p, props)
		for k, v in props do
			if v ~= nil then
				(p :: any)[k] = v
			end
		end
		return true
	end
	function GM.TweenPosition(p, pos)
		return tweenProps(p, { Position = pos })
	end
	function GM.TweenSize(p, size)
		return tweenProps(p, { Size = size })
	end
	function GM.TweenSizeAndPosition(p, size, pos)
		return tweenProps(p, { Size = size, Position = pos })
	end
	local LC = getters("UIGridStyleLayout")
	LC.AbsoluteContentSize = function(d)
		local par = d.parent and D[d.parent]
		if par and par.cls.isA.GuiBase2d then
			return absSize(par)
		end
		return Vector2.zero
	end
end

-- Humanoid ----------------------------------------------------------------------------

do
	local ON = Inst.ON_CREATE
	ON.Humanoid = function(d)
		d.extra.disabledStates = {}
		d.extra.state = Enum.HumanoidStateType.Running
	end
	local G, S = getters("Humanoid"), setters("Humanoid")
	G.RootPart = function(d)
		local par = d.parent and D[d.parent]
		if not par then
			return nil
		end
		return Inst.findVisibleChild(par, "HumanoidRootPart", Core.current())
	end
	S.Health = function(d, v)
		local max = rawGet(d, "MaxHealth")
		local nv = math.clamp(v, 0, max)
		local old = rawGet(d, "Health")
		rawSet(d, "Health", nv)
		if nv ~= old then
			Inst.fireIf(d, "HealthChanged", nv)
		end
		if nv <= 0 and old > 0 and not d.extra.disabledStates[Enum.HumanoidStateType.Dead] then
			local prev = d.extra.state
			d.extra.state = Enum.HumanoidStateType.Dead
			Inst.fireIf(d, "StateChanged", prev, Enum.HumanoidStateType.Dead)
			Inst.fireIf(d, "Died")
			if Core.rt then
				Core.rt:onHumanoidDied(d)
			end
		end
	end
	S.MaxHealth = function(d, v)
		rawSet(d, "MaxHealth", v)
		if rawGet(d, "Health") > v then
			rawSet(d, "Health", v)
		end
	end
	local defaults = Inst.reg(Inst.DEFAULTS, "Humanoid")
	defaults.Health = 100
	defaults.MaxHealth = 100
	defaults.WalkSpeed = 16
	defaults.JumpPower = 50
	defaults.JumpHeight = 7.2
	defaults.HipHeight = 2
	local M = methods("Humanoid")
	function M.SetStateEnabled(p, state, enabled)
		local d = Inst.self(p, "SetStateEnabled")
		if typeOf(state) ~= "EnumItem" then
			error("invalid argument #1 to 'SetStateEnabled' (EnumItem expected)", 2)
		end
		d.extra.disabledStates[state] = if enabled then nil else true
	end
	function M.GetStateEnabled(p, state)
		return not Inst.self(p, "GetStateEnabled").extra.disabledStates[state]
	end
	function M.GetState(p)
		return Inst.self(p, "GetState").extra.state
	end
	function M.ChangeState(p, state)
		local d = Inst.self(p, "ChangeState")
		local prev = d.extra.state
		d.extra.state = state
		Inst.fireIf(d, "StateChanged", prev, state)
	end
	function M.TakeDamage(p, amount)
		local d = Inst.self(p, "TakeDamage")
		S.Health(d, rawGet(d, "Health") - amount)
	end
	function M.Move(p, dir)
		local d = Inst.self(p, "Move")
		rawSet(d, "MoveDirection", if dir.Magnitude > 0 then dir.Unit else Vector3.zero)
	end
	function M.MoveTo(p, pos)
		local d = Inst.self(p, "MoveTo")
		d.extra.moveTo = pos
	end
	function M.UnequipTools() end
	function M.EquipTool() end
	function M.GetPlayingAnimationTracks()
		return {}
	end
	function M.LoadAnimation(_, anim)
		return Classes.animationTrack(anim)
	end
	function M.GetAppliedDescription()
		return Inst.new("HumanoidDescription")
	end
	function M.ApplyDescription() end
	function M.ApplyDescriptionReset() end
	function M.GetAccessories()
		return {}
	end
	function M.RemoveAccessories() end
	function M.BuildRigFromAttachments() end
	local E = events("Humanoid")
	E.Died = true
	E.StateChanged = true
	E.HealthChanged = true
	E.Running = true
	E.Jumping = true
	E.MoveToFinished = true
	E.Seated = true
	E.FreeFalling = true
	E.Touched = true
	E.StateEnabledChanged = true

	local AM = methods("Animator")
	function AM.LoadAnimation(_, anim)
		return Classes.animationTrack(anim)
	end
	function AM.GetPlayingAnimationTracks()
		return {}
	end
end

function Classes.animationTrack(anim)
	local t = Inst.make("AnimationTrack")
	local d = D[t]
	d.extra.anim = anim
	return t
end

do
	local M = methods("AnimationTrack")
	function M.Play(p)
		rawSet(D[p], "IsPlaying", true)
	end
	function M.Stop(p)
		local d = D[p]
		rawSet(d, "IsPlaying", false)
		Inst.fireIf(d, "Stopped")
	end
	function M.AdjustSpeed() end
	function M.AdjustWeight() end
	function M.GetMarkerReachedSignal(p, name)
		local d = D[p]
		local key = "Marker:" .. tostring(name)
		local s = d.sig[key]
		if not s then
			local _, sd = Signal.new(key)
			d.sig[key] = sd
			s = sd
		end
		return s.proxy
	end
	local E = events("AnimationTrack")
	E.Stopped = true
	E.Ended = true
	E.DidLoop = true
	E.KeyframeReached = true
end

-- Sounds, particles, misc ------------------------------------------------------------

do
	local M = methods("Sound")
	function M.Play(p)
		local d = D[p]
		rawSet(d, "Playing", true)
		Inst.fireIf(d, "Played", rawGet(d, "SoundId"))
	end
	function M.Stop(p)
		local d = D[p]
		rawSet(d, "Playing", false)
		Inst.fireIf(d, "Stopped", rawGet(d, "SoundId"))
	end
	function M.Pause(p)
		rawSet(D[p], "Playing", false)
	end
	function M.Resume(p)
		rawSet(D[p], "Playing", true)
	end
	local G = getters("Sound")
	G.IsPlaying = function(d)
		return rawGet(d, "Playing")
	end
	G.IsLoaded = function()
		return true
	end
	local E = events("Sound")
	E.Ended = true
	E.Loaded = true
	E.Played = true
	E.Stopped = true
	E.Paused = true
	E.Resumed = true
	local PM = methods("ParticleEmitter")
	function PM.Emit() end
	function PM.Clear() end
	methods("Trail").Clear = function() end
	methods("Beam").SetTextureOffset = function() end
end

-- Terrain (smooth-terrain fills) -------------------------------------------------------------
-- Voxels are not simulated. Every fill is validated like Roblox (argument types,
-- terrain-only materials, finite numbers) and RECORDED cheaply: counts per
-- method and per material, the world-space bounds of solid and of Air fills,
-- and the largest single fill in voxels (4-stud cells). Read it with
-- Classes.terrainStats(terrain) / rt:terrainStats().

local TERRAIN_VOXEL = 4

-- Terrain materials and Roblox's default MaterialColors (Studio's defaults).
local TERRAIN_DEFAULT_RGB: { [string]: { number } } = {
	Asphalt = { 115, 123, 107 },
	Basalt = { 30, 30, 37 },
	Brick = { 138, 86, 62 },
	Cobblestone = { 132, 123, 90 },
	Concrete = { 127, 102, 63 },
	CrackedLava = { 232, 156, 74 },
	Glacier = { 101, 176, 234 },
	Grass = { 106, 127, 63 },
	Ground = { 102, 92, 59 },
	Ice = { 129, 194, 224 },
	LeafyGrass = { 115, 132, 74 },
	Limestone = { 206, 173, 148 },
	Mud = { 58, 46, 36 },
	Pavement = { 148, 148, 140 },
	Rock = { 102, 108, 111 },
	Salt = { 198, 189, 181 },
	Sand = { 143, 126, 95 },
	Sandstone = { 137, 90, 71 },
	Slate = { 63, 127, 107 },
	Snow = { 195, 199, 218 },
	WoodPlanks = { 139, 109, 79 },
}
Classes.TERRAIN_DEFAULT_RGB = TERRAIN_DEFAULT_RGB

local function terrainState(d)
	local t = d.extra.terrain
	if not t then
		t = {
			fills = 0, -- every Fill* call (Air included)
			solidFills = 0,
			airFills = 0,
			clears = 0,
			byMethod = {} :: { [string]: number },
			byMaterial = {} :: { [string]: number },
			solidMin = nil :: any,
			solidMax = nil :: any,
			airMin = nil :: any,
			airMax = nil :: any,
			maxVoxels = 0, -- largest single fill, in voxels
			voxels = 0, -- sum of fill volumes in voxels (overlaps counted twice)
			colors = {} :: { [string]: any },
			colorSets = 0,
		}
		d.extra.terrain = t
	end
	return t
end

function Classes.terrainStats(terrain: any): any
	local d = D[terrain]
	return if d then terrainState(d) else nil
end

local function isTerrainMaterial(m: any, allowFluids: boolean): boolean
	if typeOf(m) ~= "EnumItem" or tostring(m.EnumType) ~= "Material" and tostring(m.EnumType) ~= "Enum.Material" then
		return false
	end
	if m.Name == "Air" or m.Name == "Water" then
		return allowFluids
	end
	return TERRAIN_DEFAULT_RGB[m.Name] ~= nil
end

local function finiteNum(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
local function finiteV3(v: any): boolean
	return typeOf(v) == "Vector3" and finiteNum(v.X) and finiteNum(v.Y) and finiteNum(v.Z)
end
local function finiteCF(v: any): boolean
	if typeOf(v) ~= "CFrame" then
		return false
	end
	for _, c in { v:GetComponents() } do
		if not finiteNum(c) then
			return false
		end
	end
	return true
end

-- World AABB of a box of `size` at `cf`.
local function boxBounds(cf: any, size: any): (any, any)
	local h = size / 2
	local lo, hi
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local p = cf:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))
				lo = if lo then lo:Min(p) else p
				hi = if hi then hi:Max(p) else p
			end
		end
	end
	return lo, hi
end

local function recordFill(d, method: string, material: any, lo: any, hi: any, volume: number)
	local t = terrainState(d)
	t.fills += 1
	t.byMethod[method] = (t.byMethod[method] or 0) + 1
	t.byMaterial[material.Name] = (t.byMaterial[material.Name] or 0) + 1
	local voxels = math.max(0, volume) / (TERRAIN_VOXEL ^ 3)
	t.voxels += voxels
	t.maxVoxels = math.max(t.maxVoxels, voxels)
	if material.Name == "Air" then
		t.airFills += 1
		t.airMin = if t.airMin then t.airMin:Min(lo) else lo
		t.airMax = if t.airMax then t.airMax:Max(hi) else hi
	else
		t.solidFills += 1
		t.solidMin = if t.solidMin then t.solidMin:Min(lo) else lo
		t.solidMax = if t.solidMax then t.solidMax:Max(hi) else hi
	end
end

do
	local M = methods("Terrain")
	local function checkMaterial(fn: string, argN: number, m: any)
		if typeOf(m) ~= "EnumItem" then
			error(string.format("invalid argument #%d to '%s' (Enum.Material expected, got %s)", argN, fn, typeOf(m)), 3)
		end
		if not isTerrainMaterial(m, true) then
			error(string.format("%s: %s is not a valid terrain material", fn, tostring(m)), 3)
		end
	end
	function M.FillBlock(p, cf, size, material)
		local d = Inst.self(p, "FillBlock")
		if not finiteCF(cf) then
			error("invalid argument #1 to 'FillBlock' (finite CFrame expected, got " .. typeOf(cf) .. ")", 2)
		end
		if not finiteV3(size) then
			error("invalid argument #2 to 'FillBlock' (finite Vector3 expected, got " .. typeOf(size) .. ")", 2)
		end
		checkMaterial("FillBlock", 3, material)
		local s = Vector3.new(math.abs(size.X), math.abs(size.Y), math.abs(size.Z))
		local lo, hi = boxBounds(cf, s)
		recordFill(d, "FillBlock", material, lo, hi, s.X * s.Y * s.Z)
	end
	function M.FillWedge(p, cf, size, material)
		local d = Inst.self(p, "FillWedge")
		if not finiteCF(cf) then
			error("invalid argument #1 to 'FillWedge' (finite CFrame expected, got " .. typeOf(cf) .. ")", 2)
		end
		if not finiteV3(size) then
			error("invalid argument #2 to 'FillWedge' (finite Vector3 expected, got " .. typeOf(size) .. ")", 2)
		end
		checkMaterial("FillWedge", 3, material)
		local s = Vector3.new(math.abs(size.X), math.abs(size.Y), math.abs(size.Z))
		local lo, hi = boxBounds(cf, s)
		recordFill(d, "FillWedge", material, lo, hi, s.X * s.Y * s.Z / 2)
	end
	function M.FillBall(p, center, radius, material)
		local d = Inst.self(p, "FillBall")
		if not finiteV3(center) then
			error("invalid argument #1 to 'FillBall' (finite Vector3 expected, got " .. typeOf(center) .. ")", 2)
		end
		if not finiteNum(radius) then
			error("invalid argument #2 to 'FillBall' (finite number expected, got " .. typeOf(radius) .. ")", 2)
		end
		checkMaterial("FillBall", 3, material)
		local r = math.abs(radius)
		local e = Vector3.new(r, r, r)
		recordFill(d, "FillBall", material, center - e, center + e, 4 / 3 * math.pi * r ^ 3)
	end
	function M.FillCylinder(p, cf, height, radius, material)
		local d = Inst.self(p, "FillCylinder")
		if not finiteCF(cf) then
			error("invalid argument #1 to 'FillCylinder' (finite CFrame expected, got " .. typeOf(cf) .. ")", 2)
		end
		if not finiteNum(height) then
			error("invalid argument #2 to 'FillCylinder' (finite number expected, got " .. typeOf(height) .. ")", 2)
		end
		if not finiteNum(radius) then
			error("invalid argument #3 to 'FillCylinder' (finite number expected, got " .. typeOf(radius) .. ")", 2)
		end
		checkMaterial("FillCylinder", 4, material)
		local h, r = math.abs(height), math.abs(radius)
		local lo, hi = boxBounds(cf, Vector3.new(2 * r, h, 2 * r))
		recordFill(d, "FillCylinder", material, lo, hi, math.pi * r * r * h)
	end
	function M.FillRegion(p, region, resolution, material)
		local d = Inst.self(p, "FillRegion")
		if typeOf(region) ~= "Region3" then
			error("invalid argument #1 to 'FillRegion' (Region3 expected, got " .. typeOf(region) .. ")", 2)
		end
		if resolution ~= TERRAIN_VOXEL then
			error("FillRegion: resolution must be 4", 2)
		end
		checkMaterial("FillRegion", 3, material)
		local s = region.Size
		local lo, hi = boxBounds(region.CFrame, s)
		recordFill(d, "FillRegion", material, lo, hi, s.X * s.Y * s.Z)
	end
	function M.Clear(p)
		local d = Inst.self(p, "Clear")
		local t = terrainState(d)
		t.clears += 1
		t.solidMin, t.solidMax, t.airMin, t.airMax = nil, nil, nil, nil
	end
	function M.SetMaterialColor(p, material, color)
		local d = Inst.self(p, "SetMaterialColor")
		if typeOf(material) ~= "EnumItem" then
			error("invalid argument #1 to 'SetMaterialColor' (Enum.Material expected, got " .. typeOf(material) .. ")", 2)
		end
		if typeOf(color) ~= "Color3" then
			error("invalid argument #2 to 'SetMaterialColor' (Color3 expected, got " .. typeOf(color) .. ")", 2)
		end
		-- Air and Water have no MaterialColors entry (water uses Terrain.WaterColor).
		if not isTerrainMaterial(material, false) then
			error("SetMaterialColor: " .. tostring(material) .. " is not a valid terrain material", 2)
		end
		local t = terrainState(d)
		t.colors[material.Name] = color
		t.colorSets += 1
	end
	function M.GetMaterialColor(p, material)
		local d = Inst.self(p, "GetMaterialColor")
		if not isTerrainMaterial(material, false) then
			error("GetMaterialColor: " .. tostring(material) .. " is not a valid terrain material", 2)
		end
		local c = terrainState(d).colors[material.Name]
		if c then
			return c
		end
		local rgb = TERRAIN_DEFAULT_RGB[material.Name]
		return roblox.Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	end
	-- Voxel reads and writes are not emulated: no grid is kept. Reads return Air.
	function M.ReadVoxels(p, region, resolution)
		Inst.self(p, "ReadVoxels")
		if typeOf(region) ~= "Region3" or resolution ~= TERRAIN_VOXEL then
			error("ReadVoxels: expected a Region3 and resolution 4", 2)
		end
		local s = region.Size / TERRAIN_VOXEL
		local nx, ny, nz = math.max(0, math.floor(s.X)), math.max(0, math.floor(s.Y)), math.max(0, math.floor(s.Z))
		local mats, occ = {}, {}
		for x = 1, nx do
			mats[x], occ[x] = {}, {}
			for y = 1, ny do
				mats[x][y], occ[x][y] = {}, {}
				for z = 1, nz do
					mats[x][y][z] = Enum.Material.Air
					occ[x][y][z] = 0
				end
			end
		end
		return mats, occ
	end
	function M.WriteVoxels(p, region, resolution, materials, occupancy)
		local d = Inst.self(p, "WriteVoxels")
		if typeOf(region) ~= "Region3" or resolution ~= TERRAIN_VOXEL then
			error("WriteVoxels: expected a Region3 and resolution 4", 2)
		end
		if type(materials) ~= "table" or type(occupancy) ~= "table" then
			error("WriteVoxels: materials and occupancy must be 3D arrays", 2)
		end
		local s = region.Size
		local lo, hi = boxBounds(region.CFrame, s)
		local t = terrainState(d)
		t.byMethod.WriteVoxels = (t.byMethod.WriteVoxels or 0) + 1
		t.solidMin = if t.solidMin then t.solidMin:Min(lo) else lo
		t.solidMax = if t.solidMax then t.solidMax:Max(hi) else hi
	end
	function M.CellCenterToWorld(_, x, y, z)
		return Vector3.new((x + 0.5) * TERRAIN_VOXEL, (y + 0.5) * TERRAIN_VOXEL, (z + 0.5) * TERRAIN_VOXEL)
	end
	function M.WorldToCell(_, pos)
		return Vector3.new(
			math.floor(pos.X / TERRAIN_VOXEL),
			math.floor(pos.Y / TERRAIN_VOXEL),
			math.floor(pos.Z / TERRAIN_VOXEL)
		)
	end
	function M.WorldToCellPreferSolid(_, pos)
		return M.WorldToCell(nil, pos)
	end
	function M.WorldToCellPreferEmpty(_, pos)
		return M.WorldToCell(nil, pos)
	end
end

-- Lighting -------------------------------------------------------------------------------------
-- Technology is readable but not writable by game scripts (Roblox: write needs
-- Plugin capability; LightingStyle / PrioritizeLightingQuality are its scriptable
-- successors). Post-effects (Atmosphere, Sky, Bloom/ColorCorrection/SunRays/
-- DepthOfField) are plain reflection-database classes.

-- Workspace.Terrain is a read-only Ref property on Roblox (always the Terrain).
getters("Workspace").Terrain = function(d)
	for _, c in d.children do
		if D[c].className == "Terrain" then
			return c
		end
	end
	return nil
end

do
	local G, S = getters("Lighting"), setters("Lighting")
	G.Technology = function(d)
		local ser = d.extra.serialized
		return (ser and ser.Technology) or Enum.Technology.Voxel
	end
	S.Technology = function(_d, _v)
		error("The current thread cannot write 'Technology' (lacking capability Plugin)", 3)
	end
end

-- Remotes and bindables ----------------------------------------------------------------

do
	local function remoteEvents(cls: string)
		local E = events(cls)
		E.OnServerEvent = {
			engine = true,
			guard = serverOnly("OnServerEvent"),
			makeOpts = function(d)
				return {
					onConnect = function(conn)
						Core.rt:flushPending(d, "server", conn.ctx)
					end,
				}
			end,
		}
		E.OnClientEvent = {
			engine = true,
			guard = clientOnly("OnClientEvent"),
			makeOpts = function(d)
				return {
					onConnect = function(conn)
						Core.rt:flushPending(d, "client", conn.ctx)
					end,
				}
			end,
		}
		local M = methods(cls)
		function M.FireServer(p, ...)
			local d = Inst.self(p, "FireServer")
			local ctx = Core.current()
			if ctx == nil or not ctx.isClient then
				error("FireServer can only be called from the client", 2)
			end
			Core.rt:sendToServer(d, ctx, table.pack(...))
		end
		function M.FireClient(p, player, ...)
			local d = Inst.self(p, "FireClient")
			local ctx = Core.current()
			if ctx and ctx.isClient then
				error("FireClient can only be called from the server", 2)
			end
			if typeOf(player) ~= "Instance" or not player:IsA("Player") then
				error("FireClient: player argument must be a Player object", 2)
			end
			Core.rt:sendToClient(d, player, table.pack(...))
		end
		function M.FireAllClients(p, ...)
			local d = Inst.self(p, "FireAllClients")
			local ctx = Core.current()
			if ctx and ctx.isClient then
				error("FireAllClients can only be called from the server", 2)
			end
			local args = table.pack(...)
			for _, player in Core.rt.players do
				Core.rt:sendToClient(d, player, args)
			end
		end
	end
	remoteEvents("RemoteEvent")
	remoteEvents("UnreliableRemoteEvent")

	local BE = events("BindableEvent")
	BE.Event = true
	methods("BindableEvent").Fire = function(p, ...)
		local d = Inst.self(p, "Fire")
		local sd = Inst.getSig(d, "Event")
		-- bindables pass a copy of tables (no metatables), like remotes within one VM
		Signal.fire(sd, nil, nil, ...)
	end

	reg(Inst.CALLBACKS, "BindableFunction").OnInvoke = {}
	methods("BindableFunction").Invoke = function(p, ...)
		local d = Inst.self(p, "Invoke")
		local cbs = d.extra.callbacks and d.extra.callbacks.OnInvoke
		local entry
		for _, e in cbs or {} do
			entry = e
		end
		if not entry or not entry.fn then
			error("BindableFunction:Invoke: OnInvoke is not set", 2)
		end
		return entry.fn(...)
	end

	reg(Inst.CALLBACKS, "RemoteFunction").OnServerInvoke = { serverOnly = true }
	reg(Inst.CALLBACKS, "RemoteFunction").OnClientInvoke = { clientOnly = true }
	methods("RemoteFunction").InvokeServer = function(p, ...)
		local d = Inst.self(p, "InvokeServer")
		local ctx = Core.current()
		if ctx == nil or not ctx.isClient then
			error("InvokeServer can only be called from the client", 2)
		end
		return Core.rt:invokeServer(d, ctx, table.pack(...))
	end
	methods("RemoteFunction").InvokeClient = function()
		Core.gap("RemoteFunction:InvokeClient", 2)
	end
end

-- Tween ---------------------------------------------------------------------------------

do
	local M = methods("Tween")
	function M.Play(p)
		local d = Inst.self(p, "Play")
		local x = d.extra
		if x.state == "Playing" then
			return
		end
		x.state = "Playing"
		rawSet(d, "PlaybackState", Enum.PlaybackState.Playing)
		x.token = (x.token or 0) + 1
		local token = x.token
		local info = x.info
		local total = info.DelayTime + info.Time * (if info.Reverses then 2 else 1)
		local finite = info.RepeatCount >= 0
		local S = Core.S
		local function finish()
			if x.token ~= token or x.state ~= "Playing" then
				return
			end
			local target = x.instance
			if target and D[target] and not D[target].destroyed then
				for k, v in x.goals do
					if not info.Reverses then
						(target :: any)[k] = v
					end
				end
			end
			if finite then
				x.state = "Completed"
				rawSet(d, "PlaybackState", Enum.PlaybackState.Completed)
				Inst.fireIf(d, "Completed", Enum.PlaybackState.Completed)
			end
		end
		local co = S:newThread(finish, Core.current())
		S:schedule(co, S.now + total * (if finite then (info.RepeatCount + 1) else 1))
	end
	function M.Cancel(p)
		local d = Inst.self(p, "Cancel")
		if d.extra.state == "Playing" then
			d.extra.state = "Cancelled"
			rawSet(d, "PlaybackState", Enum.PlaybackState.Cancelled)
			Inst.fireIf(d, "Completed", Enum.PlaybackState.Cancelled)
		end
	end
	function M.Pause(p)
		local d = Inst.self(p, "Pause")
		if d.extra.state == "Playing" then
			d.extra.state = "Paused"
			rawSet(d, "PlaybackState", Enum.PlaybackState.Paused)
		end
	end
	events("Tween").Completed = true
	local G = getters("Tween")
	G.Instance = function(d)
		return d.extra.instance
	end
	G.TweenInfo = function(d)
		return d.extra.info
	end
end

-- Player -------------------------------------------------------------------------------

do
	local M = methods("Player")
	function M.Kick(p, message)
		local d = Inst.self(p, "Kick")
		local ctx = Core.current()
		if ctx and ctx.isClient and ctx.player ~= p then
			error("Cannot kick a non-local Player from a LocalScript", 2)
		end
		Core.rt:kick(p, message)
		local _ = d
	end
	function M.LoadCharacter(p)
		local ctx = Core.current()
		if ctx and ctx.isClient then
			error("LoadCharacter can only be called by the backend server", 2)
		end
		Core.rt:spawnCharacter(p)
	end
	function M.LoadCharacterAsync(p)
		M.LoadCharacter(p)
	end
	function M.GetMouse(p)
		return Core.rt:mouseFor(p)
	end
	function M.IsInGroup()
		return false
	end
	function M.GetRankInGroup()
		return 0
	end
	function M.GetRoleInGroup()
		return "Guest"
	end
	-- Party teleports: rt:addPlayer({ joinMembers = {userId...} }) fills Members.
	function M.GetJoinData(p)
		local d = Inst.self(p, "GetJoinData")
		local members = {}
		for _, id in d.extra.joinMembers or {} do
			table.insert(members, id)
		end
		return { LaunchData = "", SourcePlaceId = 0, Members = members, TeleportData = nil }
	end
	function M.HasAppearanceLoaded(p)
		return Inst.self(p, "HasAppearanceLoaded").extra.appearanceLoaded == true
	end
	-- Friendships come from rt.config.friends = { {userIdA, userIdB}, ... } (symmetric).
	function M.IsFriendsWith(p, otherId)
		local d = Inst.self(p, "IsFriendsWith")
		if type(otherId) ~= "number" then
			error("invalid argument #1 to 'IsFriendsWith' (number expected, got " .. typeOf(otherId) .. ")", 2)
		end
		local me = rawGet(d, "UserId")
		for _, pair in (Core.rt and Core.rt.config and Core.rt.config.friends) or {} do
			if (pair[1] == me and pair[2] == otherId) or (pair[2] == me and pair[1] == otherId) then
				return true
			end
		end
		return false
	end
	function M.GetFriendsOnline()
		return {}
	end
	function M.ClearCharacterAppearance() end
	function M.GetNetworkPing()
		return 0.05
	end
	local E = events("Player")
	E.CharacterAdded = true
	E.CharacterRemoving = true
	E.CharacterAppearanceLoaded = true
	E.Chatted = true
	E.Idled = true
end

return Classes
