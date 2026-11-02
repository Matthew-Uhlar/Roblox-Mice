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
	function M.GetJoinData()
		return { LaunchData = "", SourcePlaceId = 0, Members = {}, TeleportData = nil }
	end
	function M.HasAppearanceLoaded(p)
		return Inst.self(p, "HasAppearanceLoaded").extra.appearanceLoaded == true
	end
	function M.IsFriendsWith()
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
