--!strict
-- Top-down, fixed-yaw camera (~55° pitch) that springs after the character.
-- Scroll wheel / pinch zoom within limits. Fixed yaw keeps the default
-- PlayerModule movement camera-relative (W = screen up = world -Z).
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

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Device = require(Client.Util.Device)

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
	local myPos = focus or Vector3.zero
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

-- Adds a decaying screen shake. amount in studs, duration in seconds.
function CameraController.shake(amount: number, duration: number?)
	if amount > shakeAmp then
		shakeAmp = math.min(amount, 3)
		shakeDecay = shakeAmp / math.max(duration or 0.3, 0.05)
	end
end

-- A short FOV kick (crits). strength 0..1.5.
function CameraController.punch(strength: number)
	punchAmt = math.max(punchAmt, math.clamp(strength, 0, 1.5))
end

function CameraController.setZoom(z: number)
	targetZoom = clampZoom(z)
end

local function step(dt: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
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
	local offset = Vector3.new(0, math.sin(PITCH) * zoom, math.cos(PITCH) * zoom)

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

	pcall(function()
		local p = Players.LocalPlayer :: any
		p.DevEnableMouseLock = false -- shift-lock makes no sense with a fixed camera
	end)

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
		UserInputService.TouchPinch:Connect(function(_positions, scale, _velocity, state, processed)
			if processed then
				return
			end
			if state == Enum.UserInputState.Begin then
				pinchStartZoom = targetZoom
			elseif scale > 0.01 then
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
			if spectateId and (input.KeyCode == Enum.KeyCode.Q or input.KeyCode == Enum.KeyCode.ButtonY) then
				CameraController.cycleSpectate()
			elseif spectateId and input.UserInputType == Enum.UserInputType.Touch then
				CameraController.cycleSpectate()
			elseif input.KeyCode == Enum.KeyCode.ButtonL3 then
				targetZoom = clampZoom(targetZoom + 12)
			elseif input.KeyCode == Enum.KeyCode.ButtonR3 then
				targetZoom = clampZoom(targetZoom - 12)
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
		bound = false
	end
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
