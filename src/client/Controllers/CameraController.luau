--!strict
-- Top-down camera (~55° pitch) that springs after the character.
-- Scroll wheel / pinch zoom within limits.
-- Iteration 5 (A2): the yaw is free (Util/CameraMath has the conventions):
--   PC       hold the right mouse button and drag (a short right-CLICK still
--            fires the ability, InputController asks CameraController.rmbDragged),
--            `,` / `.` turn 45° steps, N snaps back to north.
--   Gamepad  right stick X turns it while the aim mode is not "cursor" (the
--            stick aims there); hold R3 (stick click, zoom in) for 0.6 s = north.
--   Phone    drag one finger on empty screen (right 60%: never the thumbstick,
--            never a button: GUI touches are processed) or twist two fingers.
--   Anyone   tap the minimap's N compass (MinimapUI) = CameraController.resetYaw().
-- Movement stays camera-relative: the default PlayerModule reads the camera's CFrame.
-- R4 polish: smooth (critically damped) zoom, a slight look-ahead in the
-- direction you move, smooth-noise screen shake with a little roll, and no
-- collision handling at all (Scriptable camera: nothing pops). Tree canopies
-- between the camera and the hero fade out; DepthOfField stays focused on the
-- hero (off on mobile); low-spec devices hide "Decor" (Visuals/DetailLevel).
-- v3: the maps are ~2.5x larger, so the zoom range goes further out (MAX_ZOOM
-- 118) and the look-ahead leads a little more (out-of-combat sprint). Crits add
-- a short FOV "punch" (CameraController.punch); sprinting (the `Sprinting`
-- attribute on your character) eases the FOV SPRINT_FOV degrees wider. DetailLevel also streams the
-- "Decor" props by distance from the camera focus on mid / low devices.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Device = require(Client.Util.Device)
local CameraMath = require(Client.Util.CameraMath)

local DetailLevel: any = nil
do
	local folder = Client:FindFirstChild("Visuals")
	local inst = folder and folder:FindFirstChild("DetailLevel")
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		DetailLevel = if ok and type(mod) == "table" then mod else nil
	end
end

-- v4: streamed micro decor near the camera (Visuals/GroundScatter)
local GroundScatter: any = nil
do
	local folder = Client:FindFirstChild("Visuals")
	local inst = folder and folder:FindFirstChild("GroundScatter")
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		GroundScatter = if ok and type(mod) == "table" then mod else nil
	end
end

-- iter4: client detail on the server's lite obstacles / POIs (Visuals/DetailStreamer)
local DetailStreamer: any = nil
do
	local folder = Client:FindFirstChild("Visuals")
	local inst = folder and folder:FindFirstChild("DetailStreamer")
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		DetailStreamer = if ok and type(mod) == "table" then mod else nil
	end
end

local CameraController = {}

-- iter1 (team G):
--   Spectating (VERIFIED #17): while your hero is dead (party entry `dead`, or a
--   pending Herd Call in State "redeploy"), the camera follows the nearest
--   standing squadmate. Q / ButtonY / a tap cycles. State key "spectate" =
--   {id, name} (U shows "Spectating X"), nil otherwise. CameraController.spectating().
--   Cinematics: CameraController.cinematic(pos, hold, zoom?) eases the focus to a
--   world point, holds, and eases back (boss intro pan). CameraController.slowmo(t)
--   gives a slow-motion feel for t seconds (narrower FOV, a slow push-in, slower
--   follow; FxController slows particle TimeScale): the server keeps its speed.
local StateMod: any = nil
local function getState(): any
	if StateMod == nil then
		local ok, mod = pcall(require, script.Parent:WaitForChild("State", 5) :: any)
		StateMod = if ok and type(mod) == "table" then mod else false
	end
	return StateMod or nil
end

local spectateId: number? = nil
local spectateSkip = 0
local cine: { pos: Vector3, t: number, hold: number, zoom: number? }? = nil
local slowUntil = 0
local slowLen = 0.6

local function rootOf(id: number): BasePart?
	if id <= -1000 then
		local bots = workspace:FindFirstChild("Bots")
		if not bots then
			return nil
		end
		for _, m in bots:GetChildren() do
			if tonumber(m:GetAttribute("BotId")) == id or m.Name == "Bot_" .. tostring(-id) then
				local r = (m :: any).PrimaryPart or m:FindFirstChild("Root")
				return if r and r:IsA("BasePart") then r else nil
			end
		end
		return nil
	end
	local plr = Players:GetPlayerByUserId(id)
	local char = plr and plr.Character
	local r = char and char:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

-- Spectate target while dead (nil when alive or nobody stands).
local function pickSpectate(): number?
	local State = getState()
	if not State then
		return nil
	end
	local party = State.get("party")
	local me = State.localUserId()
	local mine = type(party) == "table" and party[me]
	local dead = (type(mine) == "table" and mine.dead == true) or State.get("redeploy") ~= nil
	if not dead or type(party) ~= "table" then
		return nil
	end
	local myPos = CameraController.getFocus() or Vector3.zero
	local cands = {}
	for id, e in party do
		local nid = tonumber(id)
		if nid and nid ~= me and type(e) == "table" and e.dead ~= true and e.downed ~= true then
			local r = rootOf(nid)
			if r then
				table.insert(cands, { id = nid, d = (r.Position - myPos).Magnitude })
			end
		end
	end
	if #cands == 0 then
		return nil
	end
	table.sort(cands, function(a, b)
		return if a.d == b.d then a.id < b.id else a.d < b.d
	end)
	if spectateId then
		for i, c in cands do
			if c.id == spectateId then
				return cands[((i - 1 + spectateSkip) % #cands) + 1].id
			end
		end
	end
	return cands[(spectateSkip % #cands) + 1].id
end

function CameraController.spectating(): number?
	return spectateId
end

function CameraController.cycleSpectate()
	if spectateId then
		spectateSkip += 1
	end
end

function CameraController.cinematic(pos: Vector3, hold: number?, zoomTo: number?)
	cine = { pos = pos, t = 0, hold = hold or 1.2, zoom = zoomTo }
end

function CameraController.slowmo(seconds: number?)
	slowLen = math.max(0.1, seconds or 0.6)
	slowUntil = os.clock() + slowLen
end

-- 0..1 strength of the current slow-mo (1 at the start).
function CameraController.slowAmount(): number
	local left = slowUntil - os.clock()
	if left <= 0 then
		return 0
	end
	return math.clamp(left / slowLen, 0, 1)
end

local PITCH = math.rad(55)
local FOV = 45
local MIN_ZOOM = 34
local MAX_ZOOM = 118
local FOLLOW_RATE = 10 -- higher = snappier follow
local ZOOM_RATE = 10
local WHEEL_STEP = 6
local LOOK_AHEAD = 0.3 -- seconds of velocity to lead the view by
local LOOK_AHEAD_MAX = 9 -- studs
local PUNCH_FOV = 4 -- degrees of FOV kick at punch strength 1
local SPRINT_FOV = 3 -- degrees wider while the local hero sprints (`Sprinting` attribute)
local SPRINT_RATE = 4
local LOOK_RATE = 3
local BIND_NAME = "TrunkfallTopDownCamera"

local ACTION_ROTATE = "TrunkfallCameraRotate"
local NORTH_HOLD = 0.6 -- seconds of R3 that snap the camera north

local yaw = 0 -- current (smoothed) yaw, radians; 0 = north-up
local targetYaw = 0
local rmbDown = false
local rmbMoved = 0
local rmbDragging = false
-- live fix: with an unlocked mouse Roblox often reports MouseMovement Delta = 0,
-- so the drag measures the cursor's Position change instead, and once a drag
-- starts the cursor is held in place (LockCurrentPosition), where Delta is valid.
local rmbLastPos: Vector2? = nil
local rmbLocked = false
local function releaseRmbLock()
	if rmbLocked then
		rmbLocked = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
	rmbLastPos = nil
end
local stickX = 0
local stickY = 0
-- QC minor 5: the right stick also aims abilities (X / Y / B), so no stick
-- yaw while one of those is held or for ABILITY_HOLD s after it.
local ABILITY_HOLD = 0.4
local ABILITY_BUTTONS: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.ButtonX] = true,
	[Enum.KeyCode.ButtonY] = true,
	[Enum.KeyCode.ButtonB] = true,
}
local function abilityButtonDown(): boolean
	for k in ABILITY_BUTTONS do
		if UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, k) then
			return true
		end
	end
	return false
end
local abilityQuietUntil = 0
local r3Since: number? = nil
-- one-finger rotate drags: touch -> {start, last, rotating}
local rotTouches: { [InputObject]: { start: Vector2, last: Vector2, rotating: boolean } } = {}
local twisting = false
local lastTwist = 0

local zoom = if Device.isMobile() then 66 else 60
local targetZoom = zoom
local focus: Vector3? = nil
local shakeAmp = 0
local shakeDecay = 0
local shakeT = 0
local lead = Vector3.zero
local punchAmt = 0
local sprintAmt = 0
local connections: { RBXScriptConnection } = {}
local bound = false

local function clampZoom(z: number): number
	return math.clamp(z, MIN_ZOOM, MAX_ZOOM)
end

local function characterVelocity(): Vector3
	local player = Players.LocalPlayer
	local char = player and player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local v = root.AssemblyLinearVelocity
		return Vector3.new(v.X, 0, v.Z)
	end
	return Vector3.zero
end

local function characterFocus(): Vector3?
	local player = Players.LocalPlayer
	local char = player and player.Character
	if not char then
		return nil
	end
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		return root.Position
	end
	local ok, pivot = pcall(function()
		return char:GetPivot().Position
	end)
	return if ok then pivot else nil
end

-- Current camera focus (ground point the camera looks at).
function CameraController.getFocus(): Vector3?
	return focus
end

-- iteration 7 (§B2): every shake is scaled by the Screen shake setting and
-- the Effects level (Util/GameFeel.shakeMult: "off" / Effects off = none).
local GameFeelMod: any = nil
local function shakeMult(): number
	if GameFeelMod == nil then
		local ok, mod = pcall(require, script.Parent.Parent.Util.GameFeel)
		GameFeelMod = if ok and type(mod) == "table" then mod else false
	end
	local State = getState()
	if not GameFeelMod or not State or type(State.feel) ~= "function" then
		return 1
	end
	local ok, m = pcall(function()
		local g = State.gfx()
		return GameFeelMod.shakeMult(State.feel().shake, if type(g) == "table" then g.fx else nil)
	end)
	return if ok and type(m) == "number" then m else 1
end

-- Adds a decaying screen shake. amount in studs, duration in seconds.
function CameraController.shake(amount: number, duration: number?)
	amount *= shakeMult()
	if amount > shakeAmp then
		shakeAmp = math.min(amount, 3)
		shakeDecay = shakeAmp / math.max(duration or 0.3, 0.05)
	end
end

-- iteration 7 (§B2): hit-stop. For `seconds` the camera holds its frame
-- (no follow, no shake), so a big hit reads as a short freeze on the local view.
local stopUntil = 0
function CameraController.hitStop(seconds: number)
	stopUntil = math.max(stopUntil, os.clock() + math.clamp(seconds, 0, 0.12))
end

function CameraController.hitStopped(): boolean
	return os.clock() < stopUntil
end

-- A short FOV kick (crits). strength 0..1.5.
function CameraController.punch(strength: number)
	punchAmt = math.max(punchAmt, math.clamp(strength, 0, 1.5))
end

function CameraController.setZoom(z: number)
	targetZoom = clampZoom(z)
end

-- iteration 5 (A2): yaw API. getYaw() is the yaw the camera shows now.
function CameraController.getYaw(): number
	return yaw
end

function CameraController.setYaw(a: number, instant: boolean?)
	targetYaw = CameraMath.wrap(a)
	if instant then
		yaw = targetYaw
	end
end

function CameraController.rotateBy(da: number)
	targetYaw = CameraMath.wrap(targetYaw + da)
end

-- Turn 45°: dir +1 = the view turns right, -1 = left.
function CameraController.step(dir: number)
	targetYaw = CameraMath.stepYaw(targetYaw, dir)
end

-- Snap back to north-up.
function CameraController.resetYaw()
	targetYaw = 0
end

-- True when the current / last right-button press turned into a rotate drag
-- (InputController then skips the right-click ability cast).
function CameraController.rmbDragged(): boolean
	return rmbDragging
end

-- Total mouse travel (px) of the current / last right-button press.
function CameraController.rmbMoved(): number
	return rmbMoved
end

local function aimModeCursor(): boolean
	local State = getState()
	return State ~= nil and type(State.aimMode) == "function" and State.aimMode() == "cursor"
end

-- Whether a touch is a candidate one-finger rotate drag (empty screen, right side).
local function touchMayRotate(pos: Vector3): boolean
	local cam = workspace.CurrentCamera
	if not cam then
		return false
	end
	return CameraMath.touchMayRotate(pos.X, cam.ViewportSize.X)
end

local function step(dt: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end
	if os.clock() < stopUntil then
		return -- iteration 7: hit-stop holds the frame
	end

	local target = characterFocus()
	-- iter1: spectate a squadmate while dead
	local sid = pickSpectate()
	spectateSkip = 0
	if sid ~= spectateId then
		spectateId = sid
		local State = getState()
		if State then
			State.set("spectate", if sid then { id = sid, name = State.nameOf(sid) } else nil)
		end
	end
	if sid then
		local r = rootOf(sid)
		if r then
			target = r.Position
		end
	end
	-- iter1: cinematic pan (boss intro): ease to the point, hold, ease back
	local follow = FOLLOW_RATE
	if cine then
		local c = cine
		c.t += dt
		local inT, outT = 0.5, 0.5
		local w
		if c.t < inT then
			w = c.t / inT
		elseif c.t < inT + c.hold then
			w = 1
		else
			w = 1 - (c.t - inT - c.hold) / outT
		end
		w = math.clamp(w, 0, 1)
		w = w * w * (3 - 2 * w)
		if target then
			target = target:Lerp(c.pos, w)
		else
			target = c.pos
		end
		follow = 6
		if c.t >= inT + c.hold + outT then
			cine = nil
		end
	end
	local slow = CameraController.slowAmount()
	if slow > 0 then
		follow *= 0.35
	end
	if target then
		if focus == nil or (target - (focus :: Vector3)).Magnitude > 80 and not cine then
			focus = target -- snap on spawn/teleport
		else
			focus = (focus :: Vector3):Lerp(target, 1 - math.exp(-follow * dt))
		end
	end
	if focus == nil then
		return
	end

	local wantZoom = targetZoom
	if cine and cine.zoom then
		wantZoom = cine.zoom
	end
	if slow > 0 then
		wantZoom *= 1 - 0.18 * slow -- slow push-in
	end
	zoom += (wantZoom - zoom) * (1 - math.exp(-ZOOM_RATE * dt))
	-- iteration 5: free yaw (gamepad right stick X when the stick is not aiming)
	if
		stickX ~= 0
		and not aimModeCursor()
		and os.clock() >= abilityQuietUntil
		and math.abs(stickX) >= 1.5 * math.abs(stickY) -- mostly horizontal: a turn, not an aim
		and not abilityButtonDown()
	then
		targetYaw = CameraMath.wrap(targetYaw + CameraMath.stickYaw(stickX, dt))
	end
	if r3Since and os.clock() - (r3Since :: number) >= NORTH_HOLD then
		r3Since = nil
		CameraController.resetYaw()
	end
	yaw = CameraMath.approach(yaw, targetYaw, CameraMath.RATE, dt)
	local ox, oy, oz = CameraMath.offset(yaw, PITCH, zoom)
	local offset = Vector3.new(ox, oy, oz)

	-- look-ahead: lead the view a little toward where you are walking
	local v = characterVelocity()
	local want = v * LOOK_AHEAD
	if want.Magnitude > LOOK_AHEAD_MAX then
		want = want.Unit * LOOK_AHEAD_MAX
	end
	lead = lead:Lerp(want, 1 - math.exp(-LOOK_RATE * dt))

	-- smooth-noise shake (math.noise) instead of per-frame jitter
	local shake = Vector3.zero
	local roll = 0
	if shakeAmp > 0 then
		shakeT += dt * 22
		shake = Vector3.new(math.noise(shakeT, 0.3) * 2 * shakeAmp, 0, math.noise(0.7, shakeT) * 2 * shakeAmp)
		roll = math.noise(shakeT, 5.1) * 0.02 * shakeAmp
		shakeAmp = math.max(0, shakeAmp - shakeDecay * dt)
	end

	local f = (focus :: Vector3) + lead
	local kick = 0
	if punchAmt > 0 then
		kick = punchAmt * PUNCH_FOV
		punchAmt = math.max(0, punchAmt - dt * 9)
	end
	local lp = Players.LocalPlayer
	local char = lp and lp.Character
	local sprinting = char ~= nil and char:GetAttribute("Sprinting") == true
	sprintAmt += ((if sprinting then 1 else 0) - sprintAmt) * (1 - math.exp(-SPRINT_RATE * dt))
	cam.FieldOfView = FOV + sprintAmt * SPRINT_FOV - kick - slow * 6
	cam.CFrame = CFrame.lookAt(f + offset + shake, f + shake) * CFrame.Angles(0, 0, roll)
	cam.Focus = CFrame.new(f)
	if DetailLevel then
		local dof = DetailLevel.depthOfField()
		if dof then
			dof.FocusDistance = offset.Magnitude
		end
		DetailLevel.fadeCanopies(dt, focus :: Vector3, f + offset)
		if DetailLevel.stream then
			DetailLevel.stream(dt, focus :: Vector3)
		end
	end
	if DetailStreamer then
		local okD, errD = pcall(DetailStreamer.step, dt, f)
		if not okD then
			warn("[Trunkfall] DetailStreamer: " .. tostring(errD))
			DetailStreamer = nil
		end
	end
	if GroundScatter then
		local ok, err = pcall(GroundScatter.step, dt, f)
		if not ok then
			warn("[Trunkfall] GroundScatter: " .. tostring(err))
			GroundScatter = nil
		end
	end
end

function CameraController.init()
	if bound then
		return
	end
	bound = true

	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, step)
	if DetailLevel then
		pcall(DetailLevel.init, Device.lowSpec(), Device.isMobile())
	end
	if GroundScatter then
		pcall(GroundScatter.init, Device.lowSpec(), Device.isMobile())
	end
	if DetailStreamer then
		pcall(DetailStreamer.init, Device.lowSpec(), Device.isMobile())
	end
	-- iteration 5 Phase B #3: the saved Decor setting, applied live
	local State = getState()
	if State and type(State.subscribe) == "function" then
		local unsub = State.subscribe("gfx", function()
			local decor = State.gfx().decor
			if DetailLevel and DetailLevel.setDecor then
				pcall(DetailLevel.setDecor, decor)
			end
			if GroundScatter and GroundScatter.setDecor then
				pcall(GroundScatter.setDecor, decor)
			end
		end, true)
		table.insert(connections, { Disconnect = unsub } :: any)
	end

	pcall(function()
		local p = Players.LocalPlayer :: any
		p.DevEnableMouseLock = false -- shift-lock makes no sense with a top-down camera
	end)

	-- iteration 5: step keys and north. `,` `.` and N are free (InputController:
	-- Space/Q, E, R, F/G, T, V, Tab, 1-8; the arrow keys stay with the
	-- PlayerModule's movement).
	-- Pass while a TextBox has focus so typing never turns the camera.
	ContextActionService:BindActionAtPriority(
		ACTION_ROTATE,
		function(_n, st: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
			if st ~= Enum.UserInputState.Begin or UserInputService:GetFocusedTextBox() then
				return Enum.ContextActionResult.Pass
			end
			local k = input.KeyCode
			if k == Enum.KeyCode.Comma then
				CameraController.step(-1)
			elseif k == Enum.KeyCode.Period then
				CameraController.step(1)
			elseif k == Enum.KeyCode.N then
				CameraController.resetYaw()
			else
				return Enum.ContextActionResult.Pass
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.Medium.Value,
		Enum.KeyCode.Comma,
		Enum.KeyCode.Period,
		Enum.KeyCode.N
	)

	-- Right-mouse drag (tracked whatever else handles the button: the
	-- ability binding sinks it in ContextActionService).
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				rmbDown = true
				rmbMoved = 0
				rmbDragging = false
				rmbLastPos = Vector2.new(input.Position.X, input.Position.Y)
			elseif ABILITY_BUTTONS[input.KeyCode] then
				abilityQuietUntil = os.clock() + ABILITY_HOLD
			end
		end)
	)
	table.insert(
		connections,
		UserInputService.InputEnded:Connect(function(input)
			if ABILITY_BUTTONS[input.KeyCode] then
				abilityQuietUntil = os.clock() + ABILITY_HOLD
			end
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				rmbDown = false
				releaseRmbLock()
			elseif input.KeyCode == Enum.KeyCode.ButtonR3 then
				r3Since = nil
			elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
				stickX = 0
				stickY = 0
			elseif input.UserInputType == Enum.UserInputType.Touch then
				rotTouches[input] = nil
			end
		end)
	)
	table.insert(
		connections,
		UserInputService.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				if rmbDown then
					if not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
						rmbDown = false -- the release went to something else
						releaseRmbLock()
						return
					end
					local dx, dy = input.Delta.X, input.Delta.Y
					local pos = Vector2.new(input.Position.X, input.Position.Y)
					if dx == 0 and dy == 0 and not rmbLocked and rmbLastPos then
						dx = pos.X - rmbLastPos.X
						dy = pos.Y - rmbLastPos.Y
					end
					rmbLastPos = pos
					rmbMoved += math.abs(dx) + math.abs(dy)
					if rmbDragging or rmbMoved >= CameraMath.DRAG_PX then
						rmbDragging = true
						if not rmbLocked then
							rmbLocked = true
							UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
						end
						targetYaw = CameraMath.wrap(targetYaw + CameraMath.dragYaw(dx))
						yaw = CameraMath.wrap(yaw + CameraMath.dragYaw(dx)) -- the mouse feels direct
					end
				end
			elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
				stickX = input.Position.X
				stickY = input.Position.Y
			elseif input.UserInputType == Enum.UserInputType.Touch then
				local t = rotTouches[input]
				if not t or twisting then
					return
				end
				local p = Vector2.new(input.Position.X, input.Position.Y)
				if not t.rotating and (p - t.start).Magnitude >= CameraMath.TOUCH_DRAG_PX then
					t.rotating = true
				end
				if t.rotating then
					local dx = p.X - t.last.X
					targetYaw = CameraMath.wrap(targetYaw + CameraMath.dragYaw(dx, CameraMath.TOUCH_SENS))
					yaw = CameraMath.wrap(yaw + CameraMath.dragYaw(dx, CameraMath.TOUCH_SENS))
				end
				t.last = p
			end
		end)
	)

	-- Two-finger twist: both fingers on the rotate side of the screen, so a
	-- thumb on the movement stick never turns the camera.
	table.insert(
		connections,
		UserInputService.TouchRotate:Connect(function(positions, rotation, _velocity, state, processed)
			if processed then
				return
			end
			local cam = workspace.CurrentCamera
			if not cam then
				return
			end
			for _, pos in positions do
				if not CameraMath.touchMayRotate(pos.X, cam.ViewportSize.X) then
					twisting = false
					return
				end
			end
			if state == Enum.UserInputState.Begin then
				twisting = true
				lastTwist = rotation
			elseif state == Enum.UserInputState.Change and twisting then
				local d = math.rad(rotation - lastTwist)
				lastTwist = rotation
				targetYaw = CameraMath.wrap(targetYaw + d)
				yaw = CameraMath.wrap(yaw + d)
			else
				twisting = false
			end
		end)
	)

	table.insert(
		connections,
		UserInputService.InputChanged:Connect(function(input, processed)
			if processed then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseWheel then
				targetZoom = clampZoom(targetZoom - input.Position.Z * WHEEL_STEP)
			end
		end)
	)

	local pinchStartZoom = targetZoom
	table.insert(
		connections,
		UserInputService.TouchPinch:Connect(function(positions, scale, _velocity, state, processed)
			if processed then
				return
			end
			-- iteration 5: a thumb on the movement stick is not half of a pinch
			local cam = workspace.CurrentCamera
			if state == Enum.UserInputState.Begin then
				pinchStartZoom = targetZoom
				if cam then
					for _, pos in positions do
						if not CameraMath.touchMayRotate(pos.X, cam.ViewportSize.X) then
							pinchStartZoom = -1
						end
					end
				end
			elseif pinchStartZoom > 0 and scale > 0.01 then
				targetZoom = clampZoom(pinchStartZoom / scale)
			end
		end)
	)

	-- Gamepad: DPad is reserved for upgrade picks, so zoom uses stick clicks (L3 out, R3 in).
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input, processed)
			if processed then
				return
			end
			if
				spectateId
				and (
					input.KeyCode == Enum.KeyCode.Q
					or input.KeyCode == Enum.KeyCode.ButtonY
					or input.UserInputType == Enum.UserInputType.Touch
				)
			then
				CameraController.cycleSpectate()
			elseif input.KeyCode == Enum.KeyCode.ButtonL3 then
				targetZoom = clampZoom(targetZoom + 12)
			elseif input.KeyCode == Enum.KeyCode.ButtonR3 then
				targetZoom = clampZoom(targetZoom - 12)
				r3Since = os.clock() -- held: north (step)
			end
			-- iteration 5: a one-finger drag on empty screen may turn the camera
			if input.UserInputType == Enum.UserInputType.Touch and touchMayRotate(input.Position) then
				local p = Vector2.new(input.Position.X, input.Position.Y)
				rotTouches[input] = { start = p, last = p, rotating = false }
			end
		end)
	)

	local player = Players.LocalPlayer
	if player then
		table.insert(
			connections,
			player.CharacterAdded:Connect(function()
				focus = nil -- snap to the new character
			end)
		)
	end
end

function CameraController.destroy()
	if bound then
		RunService:UnbindFromRenderStep(BIND_NAME)
		ContextActionService:UnbindAction(ACTION_ROTATE)
		bound = false
	end
	table.clear(rotTouches)
	rmbDown = false
	releaseRmbLock()
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	local cam = workspace.CurrentCamera
	if cam then
		cam.CameraType = Enum.CameraType.Custom
	end
end

return CameraController
