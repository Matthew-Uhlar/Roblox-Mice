--!strict
-- Ability input for every platform. Movement stays on the default
-- PlayerModule controls (WASD / thumbstick / left stick).
--
--  PC:      aim with the mouse (ray to ground plane Y=0); Space / Q / a right-CLICK
--           fires slot 1 (a right-button drag turns the camera instead, iteration 5).
--  Gamepad: ButtonX fires; right stick aims, otherwise auto-aims the nearest enemy.
--  Mobile:  big on-screen Ability button. Tap = auto-aim nearest enemy;
--           drag off the button = manual aim in that direction (Wild Rift style).
--  Iteration 5 (A3) ability slots (State.abilitySlots): slot 2 = E / ButtonY,
--           slot 3 = R / ButtonB (R passes while the upgrade strip is up: reroll);
--           iteration 6: slot 4 = C / DPadLeft (DPadLeft passes while the strip is up);
--           phones get one smaller button per extra slot, left of the main one.
--  Second Wind (while downed): E / ButtonY (HudUI also shows a button).
--  Iteration 5 (A2): the camera yaw is free, so every screen direction (stick
--           aim, the phone drag-aim) is turned into a world direction with the
--           camera's yaw (Util/CameraMath); mouse / touch rays need nothing.
--  Gear swap prompt (v2): F / ButtonL1 = equip the new item, G / ButtonR1 = keep
--           the current one (Net.C2S.SwapGear(true / false)); touch uses the buttons.
--  Scoreboard (v2): Tab / ButtonSelect toggles the full squad board; touch taps
--           the HUD strip. During a run the Roblox player list is hidden so Tab
--           opens ours (Main re-enables it in the lobby).
--  Iteration 7 (§B1) hold-to-aim: every ability key / button casts on RELEASE.
--           A quick tap (< AimPreview.HOLD_TIME) quick-casts exactly as before
--           (cursor / stick / auto-aim); a hold shows the aim preview
--           (Controllers/AimRenderer reads InputController.holdPreview()) and
--           the release casts at the previewed point, clamped to the cast range.
--           Gamepad: the right stick's deflection picks the distance; phones:
--           drag off the button (the drag length picks the distance).
--
-- Sends Net.C2S.UseAbility(aimX, aimZ, slot?) (slot 1 keeps the 2-arg form)
-- and Net.C2S.UseSecondWind(). Client
-- debounce only; the server is authoritative for cooldowns.

local ContextActionService = game:GetService("ContextActionService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Remotes = require(Client.Util.Remotes)
local Device = require(Client.Util.Device)
local HudMath = require(Client.Util.HudMath)
local CameraMath = require(Client.Util.CameraMath)
local AbilitySlots = require(Client.Util.AbilitySlots)
local AimPreview = require(Client.Util.AimPreview)
local Signal = require(Client.Util.Signal)
local State = require(script.Parent.State)
local ArenaHeight: any = nil -- iteration 4 (team G): plateau / ramp height of the arena
do
	local ok, mod = pcall(function()
		return require(script.Parent.Parent.Visuals:FindFirstChild("ArenaHeight") :: any) :: any
	end)
	ArenaHeight = if ok and type(mod) == "table" then mod else nil
end

local InputController = {}

local DEBOUNCE = 0.25
local AUTO_AIM_RANGE = 70
local STICK_AIM_DISTANCE = 22
local STICK_DEADZONE = 0.3
local DRAG_THRESHOLD = 28 -- design px before a touch counts as manual aim
local DRAG_FULL = 150 -- iteration 7: design px of drag past the threshold = full cast range
local GROUND_Y = 0
local ACTION_ABILITY = "TrunkfallAbility"
local ACTION_ABILITY3 = "TrunkfallAbility3" -- iteration 5: slot 3 (R / ButtonB)
-- iteration 6: slot 4 (C / DPadLeft; DPadLeft also picks upgrade 1 while the
-- strip is up, so it passes then, like R does for the reroll)
local ACTION_ABILITY4 = "TrunkfallAbility4"
local ACTION_SECOND_WIND = "TrunkfallSecondWind"
local ACTION_SWAP = "TrunkfallSwapGear"
local ACTION_SCOREBOARD = "TrunkfallScoreboard"
local ACTION_PING = "TrunkfallPing" -- v4: G / middle mouse / R2 (UI/CombatHudUI wheel; R3 is the camera zoom)
local ACTION_AIM = "TrunkfallAimMode" -- iteration 4: T / L2 toggles nearest <-> cursor aim
local AIM_HZ = 15 -- AimAt at most this often...
local AIM_MOVE = 0.75 -- ...and only once the point moved this far (studs)

local BUILD_GLYPH: { [any]: string } = {
	turret = "🔩",
	barricade = "🧱",
	repair = "🔧",
	chain = "⚡", -- iteration 6 advanced abilities
	vortex = "🌀",
	leap = "💨",
	mark = "🎯",
}
local SLOT_GLYPH = { "💥", "✨", "🌀", "⭐" }

-- Fired locally after an ability intent is sent: (aimX, aimZ, slot)
InputController.abilityFired = Signal.new()

local lastFire: { [number]: number } = {}
local shownPrompts: { [ProximityPrompt]: boolean } = {} -- E prompts on screen now
local rmbAt = 0
local rightStick = Vector2.zero
local connections: { RBXScriptConnection } = {}
local unsubs: { () -> () } = {}
local touchScreen: any = nil
local aimMarker: BasePart? = nil
-- iteration 6: the phone drag-aim in progress (BuildRenderer's placement ghost)
local touchPreview: { x: number, z: number, slot: number }? = nil
-- iteration 7 (§B1): held ability keys, per slot (cast on release)
type Hold = { at: number, gamepad: boolean, key: Enum.KeyCode }
local holds: { [number]: Hold } = {}
local lastHoldSlot: number? = nil
-- a phone button held without a drag (preview at the auto-aim point)
local touchHeld: { slot: number, at: number }? = nil
local horde: any = nil

local camCtl: any = nil
local function cameraController(): any
	if camCtl == nil then
		local ok, mod = pcall(require, script.Parent.CameraController)
		camCtl = if ok and type(mod) == "table" then mod else false
	end
	return camCtl or nil
end

-- The camera's yaw now (0 = north-up), read from the camera itself so it is
-- right during cinematics and spectating too.
local function camYaw(): number
	local cam = workspace.CurrentCamera
	if not cam then
		return 0
	end
	local look = cam.CFrame.LookVector
	return CameraMath.yawFromLook(look.X, look.Z)
end

local function hordeRenderer(): any
	if horde == nil then
		local ok, mod = pcall(require, script.Parent.HordeRenderer)
		horde = if ok then mod else false
	end
	return horde or nil
end

local function rootPart(): BasePart?
	local player = Players.LocalPlayer
	local char = player and player.Character
	local r = char and char:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function finite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- Mouse ray -> ground plane Y=0.
local function mouseAim(): (number?, number?)
	local cam = workspace.CurrentCamera
	if not cam then
		return nil, nil
	end
	local m = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(m.X, m.Y)
	local dy = ray.Direction.Y
	if dy > -1e-4 then
		return nil, nil
	end
	local t = (GROUND_Y - ray.Origin.Y) / dy
	local p = ray.Origin + ray.Direction * t
	-- iteration 4: plateaus. Re-cast at the ground height found there (one
	-- step is enough at the 55° camera pitch).
	if ArenaHeight then
		local h = ArenaHeight.at(p.X, p.Z)
		if h > 0.05 then
			local t2 = (GROUND_Y + h - ray.Origin.Y) / dy
			p = ray.Origin + ray.Direction * t2
		end
	end
	return p.X, p.Z
end

-- Nearest enemy (HordeRenderer only tracks mice/bosses, never players or bots),
-- else straight ahead of the character.
local function autoAim(): (number?, number?)
	local root = rootPart()
	if not root then
		return nil, nil
	end
	local pos = root.Position
	local h = hordeRenderer()
	if h and h.nearest then
		local ex, ez = h.nearest(pos.X, pos.Z, AUTO_AIM_RANGE)
		if ex and ez then
			return ex, ez
		end
	end
	local look = root.CFrame.LookVector
	return pos.X + look.X * 12, pos.Z + look.Z * 12
end

-- A SCREEN direction (dx right, dy down) from the hero, turned into the world
-- with the camera's yaw (iteration 5: the yaw is free).
local function directionAim(sx: number, sy: number, distance: number): (number?, number?)
	local root = rootPart()
	if not root then
		return nil, nil
	end
	local dx, dz = CameraMath.screenToWorld(sx, sy, camYaw())
	local m = math.sqrt(dx * dx + dz * dz)
	if m < 1e-4 then
		return nil, nil
	end
	local pos = root.Position
	return pos.X + dx / m * distance, pos.Z + dz / m * distance
end

local function stickAim(): (number?, number?)
	if rightStick.Magnitude > STICK_DEADZONE then
		return directionAim(rightStick.X, -rightStick.Y, STICK_AIM_DISTANCE)
	end
	return autoAim()
end

local function downed(): boolean
	local hud = State.get("hud")
	return type(hud) == "table" and hud.downed == true
end

-- Number of live ability slots (1-3).
local function slotCount(): number
	local ok, list = pcall(State.abilitySlots)
	return if ok and type(list) == "table" then math.max(1, #list) else 1
end

local function canFire(slot: number): boolean
	if downed() or slot > slotCount() then
		return false
	end
	local rem = State.abilityCooldown(slot)
	return rem <= 0.15
end

-- Sends the ability intent for a slot (default 1). Returns true if sent.
function InputController.fireAbility(aimX: number?, aimZ: number?, slot: number?): boolean
	if aimX == nil or aimZ == nil or not finite(aimX) or not finite(aimZ) then
		return false
	end
	local s = math.clamp(math.floor(slot or 1), 1, AbilitySlots.MAX)
	local now = os.clock()
	if now - (lastFire[s] or 0) < DEBOUNCE or not canFire(s) then
		return false
	end
	lastFire[s] = now
	Remotes.fire(Remotes.C2S.UseAbility, table.unpack(AbilitySlots.useArgs(aimX, aimZ, s)))
	InputController.abilityFired:Fire(aimX, aimZ, s)
	return true
end

-- Aim for a key / button press: the gamepad stick, else the mouse, else auto.
local function pressAim(input: InputObject): (number?, number?)
	if string.find(input.UserInputType.Name, "Gamepad", 1, true) ~= nil then
		return stickAim()
	end
	local x, z = mouseAim()
	if x == nil then
		x, z = autoAim()
	end
	return x, z
end

function InputController.useSecondWind()
	local hud = State.get("hud")
	if type(hud) ~= "table" or hud.downed ~= true then
		return
	end
	if hud.secondWindReady == false or (tonumber(hud.secondWinds) or 0) <= 0 then
		return
	end
	Remotes.fire(Remotes.C2S.UseSecondWind)
end

function InputController.autoAim(): (number?, number?)
	return autoAim()
end

-- iteration 7 (§B1): the aim-preview shape of a live slot (Util/AimPreview),
-- from the slot's AbilityDef (UI/ClassInfo), cached per class + loadout.
local classInfoMod: any = nil
local shapeSig = ""
local shapeCache: { [number]: AimPreview.Shape } = {}
function InputController.slotShape(slot: number): AimPreview.Shape?
	if classInfoMod == nil then
		local ok, mod = pcall(require, Client.UI.ClassInfo)
		classInfoMod = if ok and type(mod) == "table" then mod else false
	end
	local classId = State.myClassId()
	if not classInfoMod or not classId then
		return nil
	end
	local okS, slots = pcall(State.abilitySlots)
	if not okS or type(slots) ~= "table" then
		return nil
	end
	local sig = classId
	for _, s in slots do
		sig ..= "|" .. tostring(s.slot) .. "=" .. tostring(s.id)
	end
	if sig ~= shapeSig then
		shapeSig = sig
		table.clear(shapeCache)
		for _, s in slots do
			local okD, def = pcall(classInfoMod.abilityDef, classId, s.id)
			if okD and type(def) == "table" then
				shapeCache[s.slot] = AimPreview.shapeFor(def)
			end
		end
	end
	return shapeCache[slot]
end

-- Whether a held key / button is still down (a lost focus drops the hold).
local function stillDown(h: Hold): boolean
	local ok, down = pcall(function()
		if h.gamepad then
			return UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, h.key)
		end
		return UserInputService:IsKeyDown(h.key)
	end)
	return not ok or down == true
end

-- The aim of a hold: the right stick inside the cast range (gamepad), else
-- the cursor; auto-aim when neither aims.
local function holdAim(slot: number, h: Hold): (number?, number?)
	if h.gamepad then
		if rightStick.Magnitude > STICK_DEADZONE then
			local root = rootPart()
			if not root then
				return nil, nil
			end
			local shape = InputController.slotShape(slot)
			local dx, dz = CameraMath.screenToWorld(rightStick.X, -rightStick.Y, camYaw())
			local mag = (math.min(rightStick.Magnitude, 1) - STICK_DEADZONE) / (1 - STICK_DEADZONE)
			local pos = root.Position
			return AimPreview.stickPoint(
				pos.X,
				pos.Z,
				dx,
				dz,
				mag,
				if shape then shape.range else STICK_AIM_DISTANCE
			)
		end
		return autoAim()
	end
	local x, z = mouseAim()
	if x == nil then
		return autoAim()
	end
	return x, z
end

-- The point an aimed cast sends: the previewed centre (clamped to the range)
-- for area / landing / path shapes; line, cone and self shapes keep the aim.
local function castPoint(slot: number, x: number?, z: number?): (number?, number?)
	local shape = InputController.slotShape(slot)
	local root = rootPart()
	if x == nil or z == nil or not shape or not root then
		return x, z
	end
	local f = shape.form
	if f == "circle" or f == "path" or f == "leap" or f == "ghost" then
		local pos = root.Position
		local cx, cz = AimPreview.clamp(pos.X, pos.Z, x, z, shape.range)
		return cx, cz
	end
	return x, z
end

export type HoldView = { slot: number, x: number, z: number, how: string }

-- iteration 7 (§B1): the aim preview to draw now, or nil: a key held past
-- AimPreview.HOLD_TIME ("mouse" / "stick"), or a phone button being dragged
-- ("touch") or held ("touch", auto-aim point).
function InputController.holdPreview(): HoldView?
	local tp = touchPreview
	if tp then
		return { slot = tp.slot, x = tp.x, z = tp.z, how = "touch" }
	end
	local th = touchHeld
	if th and AimPreview.isHold(os.clock() - th.at) then
		local x, z = autoAim()
		if x and z then
			return { slot = th.slot, x = x, z = z, how = "touch" }
		end
	end
	local slot = lastHoldSlot
	local h = if slot then holds[slot] else nil
	if not slot or not h then
		return nil
	end
	if not stillDown(h) then
		holds[slot] = nil
		lastHoldSlot = nil
		return nil
	end
	if not AimPreview.isHold(os.clock() - h.at) then
		return nil
	end
	local x, z = holdAim(slot, h)
	if x == nil or z == nil then
		return nil
	end
	return { slot = slot, x = x, z = z, how = if h.gamepad then "stick" else "mouse" }
end

-- iteration 6: where an ability fired right now would aim, for a placement
-- preview: (x, z, slot?, how). A phone drag gives its slot ("touch"); a
-- deflected right stick ("stick"); else the mouse ("mouse"). nil, nil when
-- nothing is aiming (a phone with no drag, a gamepad at rest: auto-aim).
-- iteration 7: a held ability key (holdPreview) wins and names its slot.
function InputController.previewAim(): (number?, number?, number?, string?)
	local hv = InputController.holdPreview()
	if hv then
		return hv.x, hv.z, hv.slot, hv.how
	end
	if rightStick.Magnitude > STICK_DEADZONE then
		local x, z = directionAim(rightStick.X, -rightStick.Y, STICK_AIM_DISTANCE)
		return x, z, nil, "stick"
	end
	if Device.mode() ~= "kbm" or not UserInputService.MouseEnabled then
		return nil, nil, nil, nil
	end
	local x, z = mouseAim()
	return x, z, nil, if x then "mouse" else nil
end

----------------------------------------------------------------------
-- Keyboard / mouse / gamepad
----------------------------------------------------------------------

-- iteration 7 (§B1): a key / button went down for `slot`: start a hold.
local function holdBegin(slot: number, input: InputObject)
	holds[slot] = {
		at = os.clock(),
		gamepad = string.find(input.UserInputType.Name, "Gamepad", 1, true) ~= nil,
		key = input.KeyCode,
	}
	lastHoldSlot = slot
end

-- ...and came up: a tap quick-casts (the old press aim), a hold casts at the
-- previewed point. Returns false when no hold was running for the slot.
local function holdRelease(slot: number, input: InputObject): boolean
	local h = holds[slot]
	if not h then
		return false
	end
	holds[slot] = nil
	if lastHoldSlot == slot then
		lastHoldSlot = nil
		for s in holds do
			lastHoldSlot = s
		end
	end
	local x, z
	if AimPreview.isHold(os.clock() - h.at) then
		x, z = holdAim(slot, h)
		x, z = castPoint(slot, x, z)
	else
		x, z = pressAim(input)
	end
	InputController.fireAbility(x, z, slot)
	return true
end

local function onAbilityAction(
	_name: string,
	state: Enum.UserInputState,
	input: InputObject
): Enum.ContextActionResult
	-- iteration 5: a right-CLICK fires on release; a right-button drag turns the camera
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		if state == Enum.UserInputState.Begin then
			rmbAt = os.clock()
		elseif state == Enum.UserInputState.End then
			local cc = cameraController()
			local dragged = cc ~= nil and cc.rmbDragged()
			local moved = if cc then cc.rmbMoved() else 0
			if not dragged and CameraMath.isClick(moved, os.clock() - rmbAt) then
				local x, z = mouseAim()
				if x == nil then
					x, z = autoAim()
				end
				InputController.fireAbility(x, z, 1)
			end
		end
		return Enum.ContextActionResult.Sink
	end
	-- iteration 7: cast on release (tap = quick-cast, hold = aimed preview)
	if state == Enum.UserInputState.Begin then
		holdBegin(1, input)
	elseif state == Enum.UserInputState.End then
		holdRelease(1, input)
	elseif state == Enum.UserInputState.Cancel then
		holds[1] = nil
	end
	-- Sink so Space does not also jump.
	return Enum.ContextActionResult.Sink
end

-- E / ButtonY: Second Wind while downed, else ability slot 2 (iteration 5).
-- Passes when neither applies (dead / spectating: ButtonY cycles the view).
local function onSecondWindAction(
	_name: string,
	state: Enum.UserInputState,
	input: InputObject
): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		if state == Enum.UserInputState.End and holdRelease(2, input) then
			return Enum.ContextActionResult.Sink
		end
		holds[2] = nil
		return Enum.ContextActionResult.Pass
	end
	if downed() then
		InputController.useSecondWind()
		return Enum.ContextActionResult.Sink
	end
	-- a shown E prompt (in-run shop stalls) keeps E
	if next(shownPrompts) ~= nil then
		return Enum.ContextActionResult.Pass
	end
	if UserInputService:GetFocusedTextBox() then
		return Enum.ContextActionResult.Pass
	end
	if State.inCombat() and slotCount() >= 2 then
		local cc = cameraController()
		if cc and cc.spectating() ~= nil then
			return Enum.ContextActionResult.Pass
		end
		holdBegin(2, input)
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

-- R / ButtonB: ability slot 3. R passes while the upgrade strip is up (reroll).
local function onSlot3Action(
	_name: string,
	state: Enum.UserInputState,
	input: InputObject
): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		if state == Enum.UserInputState.End and holdRelease(3, input) then
			return Enum.ContextActionResult.Sink
		end
		holds[3] = nil
		return Enum.ContextActionResult.Pass
	end
	if input.KeyCode == Enum.KeyCode.R and State.get("upgradeShown") == true then
		return Enum.ContextActionResult.Pass
	end
	if UserInputService:GetFocusedTextBox() then
		return Enum.ContextActionResult.Pass
	end
	if not State.inCombat() or slotCount() < 3 or downed() then
		return Enum.ContextActionResult.Pass
	end
	holdBegin(3, input)
	return Enum.ContextActionResult.Sink
end

-- iteration 6: slot 4 (C / DPadLeft), same rules as slot 3.
local function onSlot4Action(
	_name: string,
	state: Enum.UserInputState,
	input: InputObject
): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		if state == Enum.UserInputState.End and holdRelease(4, input) then
			return Enum.ContextActionResult.Sink
		end
		holds[4] = nil
		return Enum.ContextActionResult.Pass
	end
	if input.KeyCode == Enum.KeyCode.DPadLeft and State.get("upgradeShown") == true then
		return Enum.ContextActionResult.Pass -- UpgradeUI: pick 1
	end
	if UserInputService:GetFocusedTextBox() then
		return Enum.ContextActionResult.Pass
	end
	if not State.inCombat() or slotCount() < 4 or downed() then
		return Enum.ContextActionResult.Pass
	end
	holdBegin(4, input)
	return Enum.ContextActionResult.Sink
end

-- F / L1 = equip the new item, G / R1 = keep the current one. Passes the key
-- through when there is no swap offer, so F / G keep their default uses.
local function onSwapAction(
	_name: string,
	state: Enum.UserInputState,
	input: InputObject
): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	local inv = State.get("inventory")
	if type(inv) ~= "table" or type(inv.swapOffer) ~= "table" then
		return Enum.ContextActionResult.Pass
	end
	local take = input.KeyCode == Enum.KeyCode.F or input.KeyCode == Enum.KeyCode.ButtonL1
	State.answerSwap(take)
	return Enum.ContextActionResult.Sink
end

-- v4 pings. G / R2 open the ping wheel at the aim point (State
-- "pingWheel"; a hold + release picks the slot under the pointer); middle
-- mouse sends an instant context ping at the cursor. Only during a run; G
-- reaches here only when no gear swap offer is open (onSwapAction passes).
local function pingPoint(): (number?, number?)
	if Device.mode() == "kbm" then
		local x, z = mouseAim()
		if x and z then
			return x, z
		end
	elseif Device.mode() == "gamepad" and rightStick.Magnitude > STICK_DEADZONE then
		return stickAim()
	end
	local root = rootPart()
	if root then
		return root.Position.X, root.Position.Z
	end
	return nil, nil
end

local function onPingAction(
	_name: string,
	state: Enum.UserInputState,
	input: InputObject
): Enum.ContextActionResult
	local phase = State.phase()
	if phase == nil or phase == "Lobby" or phase == "Results" then
		return Enum.ContextActionResult.Pass
	end
	if input.UserInputType == Enum.UserInputType.MouseButton3 then
		if state == Enum.UserInputState.Begin then
			local x, z = mouseAim()
			if x and z then
				State.sendPing(HudMath.contextPing(x, z, State.marks()), x, z)
			end
		end
		return Enum.ContextActionResult.Sink
	end
	if state == Enum.UserInputState.Begin then
		local x, z = pingPoint()
		if x and z then
			State.set("pingWheel", { open = true, x = x, z = z, at = os.clock() })
		end
		return Enum.ContextActionResult.Sink
	elseif state == Enum.UserInputState.End then
		State.set("pingWheel", { open = false, released = true, at = os.clock() })
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

function InputController.swapGear(take: boolean): boolean
	return State.answerSwap(take)
end

-- Tab / Back: the squad scoreboard (squad matches) and, iteration 5 Phase B,
-- the damage meter: Tab toggles it, Back / Select shows it while HELD.
local function onScoreboardAction(
	_name: string,
	state: Enum.UserInputState,
	input: InputObject
): Enum.ContextActionResult
	local phase = State.phase()
	local inRun = phase ~= nil and phase ~= "Lobby" and phase ~= "Results"
	local hold = input.KeyCode == Enum.KeyCode.ButtonSelect
	if state == Enum.UserInputState.End then
		if hold and inRun and State.get("meterOpen") == true then
			State.set("meterOpen", false)
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if inRun then
		State.set("meterOpen", if hold then true else State.get("meterOpen") ~= true)
	end
	if State.isSquadMatch() then
		State.toggleScoreboard()
	elseif not inRun then
		return Enum.ContextActionResult.Pass
	end
	return Enum.ContextActionResult.Sink
end

----------------------------------------------------------------------
-- Mobile ability button
----------------------------------------------------------------------

local function ensureAimMarker(): BasePart
	if aimMarker and aimMarker.Parent then
		return aimMarker
	end
	local p = Instance.new("Part")
	p.Name = "TrunkfallAimMarker"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(255, 204, 51)
	p.Transparency = 0.45
	p.Size = Vector3.new(1.2, 0.1, 1)
	p.CFrame = CFrame.new(0, -5000, 0)
	p.Parent = workspace
	aimMarker = p
	return p
end

local function showAimMarker(dx: number, dz: number)
	local root = rootPart()
	if not root then
		return
	end
	local m = ensureAimMarker()
	local pos = root.Position
	local ax, az = directionAim(dx, dz, STICK_AIM_DISTANCE)
	if not ax or not az then
		return
	end
	local from = Vector3.new(pos.X, GROUND_Y + 0.15, pos.Z)
	local to = Vector3.new(ax, GROUND_Y + 0.15, az)
	local len = (to - from).Magnitude
	m.Size = Vector3.new(1.2, 0.1, len)
	m.CFrame = CFrame.lookAt(from, to) * CFrame.new(0, 0, -len / 2)
end

-- iteration 7: a phone drag (screen px) -> a world point inside the slot's
-- cast range (drag length past the threshold / DRAG_FULL = the fraction).
local function dragAim(slot: number, d: Vector2, threshold: number, scale: number): (number?, number?)
	local root = rootPart()
	local shape = InputController.slotShape(slot)
	if not root or not shape then
		return directionAim(d.X, d.Y, STICK_AIM_DISTANCE)
	end
	local dx, dz = CameraMath.screenToWorld(d.X, d.Y, camYaw())
	local frac = (d.Magnitude - threshold) / math.max(1, DRAG_FULL * scale)
	local pos = root.Position
	return AimPreview.stickPoint(pos.X, pos.Z, dx, dz, frac, shape.range)
end

local function hideAimMarker()
	if aimMarker then
		aimMarker.CFrame = CFrame.new(0, -5000, 0)
	end
end

-- One touch button per live ability slot (iteration 5): slot 1 is the big
-- button in the thumb spot; slots 2-3 are smaller, stacked left of it (below
-- the 📍 / 🎯 buttons that sit above the big one).
local function buildTouchButton()
	local okTheme, Theme = pcall(require, Client.UI.Theme)
	if not okTheme then
		warn("[Trunkfall] Theme missing, no touch ability button: " .. tostring(Theme))
		return
	end
	local okInfo, ClassInfo = pcall(require, Client.UI.ClassInfo)
	local screen = Theme.screen("TrunkfallTouch", 15)
	touchScreen = screen

	-- v3: smaller on roomy (PC / tablet-with-keyboard) screens, where 100
	-- design px is still >= 48 screen px; phones keep 150.
	local big = if Theme.dense() then 100 else 150
	local small = if Theme.dense() then 70 else 78

	type Btn = {
		slot: number,
		button: TextButton,
		icon: TextLabel,
		name: TextLabel,
		cdText: TextLabel,
		radial: any,
		size: number,
	}
	local buttons: { Btn } = {}

	local function makeButton(slot: number): Btn
		local size = if slot == 1 then big else small
		local pos = if slot == 1
			then UDim2.new(1, -36, 1, -44)
			else UDim2.new(1, -(36 + big + 18), 1, -(44 + (slot - 2) * (small + 10)))
		local button = Theme.make("TextButton", {
			Name = if slot == 1 then "AbilityButton" else "AbilityButton" .. slot,
			AnchorPoint = Vector2.new(1, 1),
			Position = pos,
			Size = UDim2.fromOffset(size, size),
			BackgroundColor3 = Theme.C.cheese,
			AutoButtonColor = false,
			Text = "",
			Visible = slot == 1,
			Parent = screen.root,
		}) :: TextButton
		Theme.round().Parent = button
		Theme.stroke(Theme.C.brownDark, if slot == 1 then 5 else 4).Parent = button
		local icon = Theme.label({
			Size = UDim2.fromScale(1, 0.55),
			Position = UDim2.fromScale(0, 0.12),
			Text = SLOT_GLYPH[slot] or "💥",
			TextSize = math.floor(size * 0.36),
			ZIndex = 4,
			Parent = button,
		})
		local name = Theme.label({
			Size = UDim2.new(1, -6, 0.22, 0),
			Position = UDim2.new(0, 3, 0.64, 0),
			Text = "ABILITY",
			TextSize = math.floor(size * (if slot == 1 then 0.135 else 0.16)),
			TextColor3 = Theme.C.ink,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 4,
			Parent = button,
		})
		local cdText = Theme.label({
			Size = UDim2.fromScale(1, 1),
			Text = "",
			TextSize = math.floor(size * 0.295),
			ZIndex = 5,
			Parent = button,
		})
		Theme.textStroke().Parent = cdText
		local radial = Theme.radial(button, Theme.C.shade, 0.4)
		radial.frame.ZIndex = 3
		return {
			slot = slot,
			button = button,
			icon = icon,
			name = name,
			cdText = cdText,
			radial = radial,
			size = size,
		}
	end
	for slot = 1, AbilitySlots.MAX do
		buttons[slot] = makeButton(slot)
	end

	-- Ability names per slot (cosmetic only).
	local function refreshName()
		local classId = State.myClassId()
		local slots = State.abilitySlots()
		for _, b in buttons do
			local info = slots[b.slot]
			local label = "ABILITY"
			if okInfo and classId then
				local okN, n = pcall(ClassInfo.abilityName, classId, if info then info.id else nil)
				if okN and type(n) == "string" then
					label = n
				end
			end
			b.name.Text = string.upper(label)
			-- iteration 6: the Tinkerphant's builds get their own glyphs
			local glyph = SLOT_GLYPH[b.slot] or "💥"
			if okInfo and classId and type(ClassInfo.abilityDef) == "function" then
				local okD, def = pcall(ClassInfo.abilityDef, classId, if info then info.id else nil)
				local kind = if okD and type(def) == "table" then def.kind else nil
				glyph = BUILD_GLYPH[kind] or glyph
			end
			b.icon.Text = glyph
		end
	end
	table.insert(unsubs, State.subscribe("lobby", refreshName, true))
	table.insert(unsubs, State.subscribe("profile", refreshName))
	table.insert(unsubs, State.subscribe("hud", refreshName))

	local function refreshVisible()
		local phase = State.phase()
		local on = phase ~= nil and phase ~= "Lobby" and phase ~= "Results"
		local n = slotCount()
		local upgrades = State.get("upgradeShown") == true
		for _, b in buttons do
			-- extra slots step aside while the upgrade strip is up (phones)
			b.button.Visible = on and b.slot <= n and (b.slot == 1 or not upgrades)
		end
	end
	table.insert(unsubs, State.subscribe("run", refreshVisible, true))
	table.insert(unsubs, State.subscribe("hud", refreshVisible))
	table.insert(unsubs, State.subscribe("profile", refreshVisible))
	table.insert(unsubs, State.subscribe("upgradeShown", refreshVisible))

	local activeTouch: InputObject? = nil
	local activeSlot = 1
	local startPos = Vector2.zero
	local dragging = false

	for _, b in buttons do
		b.button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch and activeTouch == nil then
				activeTouch = input
				activeSlot = b.slot
				startPos = Vector2.new(input.Position.X, input.Position.Y)
				dragging = false
				touchHeld = { slot = b.slot, at = os.clock() } -- iteration 7: hold = preview
				b.button.BackgroundColor3 = Theme.C.cheeseDark
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
				-- Touch-capable laptops: plain click = auto-aim.
				local x, z = autoAim()
				InputController.fireAbility(x, z, b.slot)
			end
		end)
	end

	table.insert(
		connections,
		UserInputService.InputChanged:Connect(function(input)
			if input ~= activeTouch then
				return
			end
			local d = Vector2.new(input.Position.X, input.Position.Y) - startPos
			local threshold = DRAG_THRESHOLD * Theme.scale()
			if d.Magnitude > threshold then
				dragging = true
				-- iteration 7: the drag length picks the distance inside the cast
				-- range; AimRenderer draws the preview (the old strip marker only
				-- shows when the slot's shape is unknown)
				local px, pz = dragAim(activeSlot, d, threshold, Theme.scale())
				touchPreview = if px and pz then { x = px, z = pz, slot = activeSlot } else nil
				if InputController.slotShape(activeSlot) == nil then
					showAimMarker(d.X, d.Y)
				end
			elseif dragging then
				hideAimMarker()
				dragging = false
				touchPreview = nil
			end
		end)
	)

	table.insert(
		connections,
		UserInputService.InputEnded:Connect(function(input)
			if input ~= activeTouch then
				return
			end
			activeTouch = nil
			touchHeld = nil
			local b = buttons[activeSlot]
			if b then
				b.button.BackgroundColor3 = Theme.C.cheese
			end
			hideAimMarker()
			touchPreview = nil
			local x, z
			if dragging then
				local d = Vector2.new(input.Position.X, input.Position.Y) - startPos
				x, z = dragAim(activeSlot, d, DRAG_THRESHOLD * Theme.scale(), Theme.scale())
				x, z = castPoint(activeSlot, x, z)
			else
				x, z = autoAim()
			end
			dragging = false
			InputController.fireAbility(x, z, activeSlot)
		end)
	)

	table.insert(
		connections,
		RunService.RenderStepped:Connect(function()
			for _, b in buttons do
				if b.button.Visible then
					local rem, total = State.abilityCooldown(b.slot)
					b.radial.set(if rem > 0 then rem / total else 0)
					b.cdText.Text = if rem > 0 then tostring(math.ceil(rem)) else ""
					b.icon.Visible = rem <= 0
				end
			end
		end)
	)
end

-- Hides the default touch jump button: jumping has no use in a top-down
-- horde game, and the ability button lives in that thumb spot.
local function disableJumpOnTouch(char: Model)
	if not Device.isMobile() then
		return
	end
	local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
	if hum then
		pcall(function()
			hum.UseJumpPower = false
			hum.JumpHeight = 0
			hum.JumpPower = 0
		end)
	end
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

local started = false

function InputController.init()
	if started then
		return
	end
	started = true

	ContextActionService:BindActionAtPriority(
		ACTION_ABILITY,
		onAbilityAction,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.Space,
		Enum.KeyCode.Q,
		Enum.UserInputType.MouseButton2,
		Enum.KeyCode.ButtonX
	)
	ContextActionService:BindActionAtPriority(
		ACTION_SECOND_WIND,
		onSecondWindAction,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.E,
		Enum.KeyCode.ButtonY
	)
	-- iteration 5: slot 3. Medium, so anything bound higher on R / B keeps it.
	ContextActionService:BindActionAtPriority(
		ACTION_ABILITY3,
		onSlot3Action,
		false,
		Enum.ContextActionPriority.Medium.Value,
		Enum.KeyCode.R,
		Enum.KeyCode.ButtonB
	)
	ContextActionService:BindActionAtPriority(
		ACTION_ABILITY4,
		onSlot4Action,
		false,
		Enum.ContextActionPriority.Medium.Value,
		Enum.KeyCode.C,
		Enum.KeyCode.DPadLeft
	)
	table.insert(
		connections,
		ProximityPromptService.PromptShown:Connect(function(prompt)
			if prompt.KeyboardKeyCode == Enum.KeyCode.E or prompt.GamepadKeyCode == Enum.KeyCode.ButtonY then
				shownPrompts[prompt] = true
			end
		end)
	)
	table.insert(
		connections,
		ProximityPromptService.PromptHidden:Connect(function(prompt)
			shownPrompts[prompt] = nil
		end)
	)

	ContextActionService:BindActionAtPriority(
		ACTION_SWAP,
		onSwapAction,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.F,
		Enum.KeyCode.G,
		Enum.KeyCode.ButtonL1,
		Enum.KeyCode.ButtonR1
	)
	-- Lower than the swap action, which takes G only while a swap offer is open.
	ContextActionService:BindActionAtPriority(
		ACTION_PING,
		onPingAction,
		false,
		Enum.ContextActionPriority.Medium.Value,
		Enum.KeyCode.G,
		Enum.UserInputType.MouseButton3,
		Enum.KeyCode.ButtonR2
	)
	ContextActionService:BindActionAtPriority(
		ACTION_SCOREBOARD,
		onScoreboardAction,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.Tab,
		Enum.KeyCode.ButtonSelect
	)

	table.insert(
		connections,
		UserInputService.InputChanged:Connect(function(input)
			if input.KeyCode == Enum.KeyCode.Thumbstick2 then
				rightStick = Vector2.new(input.Position.X, input.Position.Y)
			end
		end)
	)
	table.insert(
		connections,
		UserInputService.InputEnded:Connect(function(input)
			if input.KeyCode == Enum.KeyCode.Thumbstick2 then
				rightStick = Vector2.zero
			end
		end)
	)

	-- Iteration 4: auto-attack aim mode (T / L2; the phone button is in CombatHudUI)
	ContextActionService:BindActionAtPriority(ACTION_AIM, function(_n, st: Enum.UserInputState)
		if st ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		State.toggleAimMode()
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.Medium.Value, Enum.KeyCode.T, Enum.KeyCode.ButtonL2)
	-- Cursor mode: send AimAt(x, z) while the aim point changes (<= 15/s)
	local lastTouch: Vector2? = nil
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input, processed)
			if processed then
				return
			end
			if input.UserInputType == Enum.UserInputType.Touch then
				local cam = workspace.CurrentCamera
				-- the right half of the screen aims; the left half is the thumbstick
				if cam and input.Position.X > cam.ViewportSize.X * 0.4 then
					lastTouch = Vector2.new(input.Position.X, input.Position.Y)
				end
			end
		end)
	)
	local function touchAim(): (number?, number?)
		local cam = workspace.CurrentCamera
		local tp = lastTouch
		if not cam or not tp then
			return nil, nil
		end
		local ray = cam:ViewportPointToRay(tp.X, tp.Y)
		if ray.Direction.Y > -1e-4 then
			return nil, nil
		end
		local t = (GROUND_Y - ray.Origin.Y) / ray.Direction.Y
		local p = ray.Origin + ray.Direction * t
		return p.X, p.Z
	end
	local sentX, sentZ, sentAt = math.huge, math.huge, 0
	table.insert(
		connections,
		RunService.Heartbeat:Connect(function()
			if State.aimMode() ~= "cursor" or not State.inCombat() or not Remotes.C2S.AimAt then
				return
			end
			local now = os.clock()
			if now - sentAt < 1 / AIM_HZ then
				return
			end
			local mode = Device.mode()
			local x, z
			if mode == "kbm" then
				x, z = mouseAim()
			elseif mode == "gamepad" then
				if rightStick.Magnitude > STICK_DEADZONE then
					x, z = stickAim()
				end
			else
				x, z = touchAim()
			end
			if not x or not z or not finite(x) or not finite(z) then
				return
			end
			if (x - sentX) ^ 2 + (z - sentZ) ^ 2 < AIM_MOVE * AIM_MOVE then
				return -- unchanged: send nothing
			end
			sentX, sentZ, sentAt = x, z, now
			Remotes.fire(Remotes.C2S.AimAt, x, z)
		end)
	)

	if Device.hasTouch() then
		buildTouchButton()
	end

	local player = Players.LocalPlayer
	if player then
		if player.Character then
			task.spawn(disableJumpOnTouch, player.Character)
		end
		table.insert(
			connections,
			player.CharacterAdded:Connect(function(char)
				disableJumpOnTouch(char)
			end)
		)
	end
end

function InputController.destroy()
	ContextActionService:UnbindAction(ACTION_ABILITY)
	ContextActionService:UnbindAction(ACTION_SECOND_WIND)
	ContextActionService:UnbindAction(ACTION_ABILITY3)
	ContextActionService:UnbindAction(ACTION_ABILITY4)
	table.clear(shownPrompts)
	ContextActionService:UnbindAction(ACTION_SWAP)
	ContextActionService:UnbindAction(ACTION_SCOREBOARD)
	ContextActionService:UnbindAction(ACTION_PING)
	ContextActionService:UnbindAction(ACTION_AIM)
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	if touchScreen then
		touchScreen.destroy()
		touchScreen = nil
	end
	if aimMarker then
		aimMarker:Destroy()
		aimMarker = nil
	end
	started = false
end

return InputController
