--!strict
-- Ability input for every platform. Movement stays on the default
-- PlayerModule controls (WASD / thumbstick / left stick).
--
--  PC:      aim with the mouse (ray to ground plane Y=0); Space / Q / right-click fires.
--  Gamepad: ButtonX fires; right stick aims, otherwise auto-aims the nearest enemy.
--  Mobile:  big on-screen Ability button. Tap = auto-aim nearest enemy;
--           drag off the button = manual aim in that direction (Wild Rift style).
--  Second Wind (while downed): E / ButtonY (HudUI also shows a button).
--
-- Sends Net.C2S.UseAbility(aimX, aimZ) and Net.C2S.UseSecondWind(). Client
-- debounce only; the server is authoritative for cooldowns.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Remotes = require(Client.Util.Remotes)
local Device = require(Client.Util.Device)
local Signal = require(Client.Util.Signal)
local State = require(script.Parent.State)

local InputController = {}

local DEBOUNCE = 0.25
local AUTO_AIM_RANGE = 70
local STICK_AIM_DISTANCE = 22
local STICK_DEADZONE = 0.3
local DRAG_THRESHOLD = 28 -- design px before a touch counts as manual aim
local GROUND_Y = 0
local ACTION_ABILITY = "TrunkfallAbility"
local ACTION_SECOND_WIND = "TrunkfallSecondWind"

-- Fired locally after an ability intent is sent: (aimX, aimZ)
InputController.abilityFired = Signal.new()

local lastFire = 0
local rightStick = Vector2.zero
local connections: { RBXScriptConnection } = {}
local touchScreen: any = nil
local aimMarker: BasePart? = nil
local horde: any = nil

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

-- Fixed-yaw camera: screen right = world +X, screen down = world +Z.
local function directionAim(dx: number, dz: number, distance: number): (number?, number?)
	local root = rootPart()
	if not root then
		return nil, nil
	end
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

local function canFire(): boolean
	local hud = State.get("hud")
	if type(hud) == "table" and hud.downed == true then
		return false
	end
	local rem = State.abilityCooldown()
	return rem <= 0.15
end

-- Sends the ability intent. Returns true if sent.
function InputController.fireAbility(aimX: number?, aimZ: number?): boolean
	if aimX == nil or aimZ == nil or not finite(aimX) or not finite(aimZ) then
		return false
	end
	local now = os.clock()
	if now - lastFire < DEBOUNCE or not canFire() then
		return false
	end
	lastFire = now
	Remotes.fire(Remotes.C2S.UseAbility, aimX, aimZ)
	InputController.abilityFired:Fire(aimX, aimZ)
	return true
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

----------------------------------------------------------------------
-- Keyboard / mouse / gamepad
----------------------------------------------------------------------

local function onAbilityAction(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	local x, z
	if input.KeyCode == Enum.KeyCode.ButtonX then
		x, z = stickAim()
	else
		x, z = mouseAim()
		if x == nil then
			x, z = autoAim()
		end
	end
	InputController.fireAbility(x, z)
	-- Sink so Space does not also jump.
	return Enum.ContextActionResult.Sink
end

local function onSecondWindAction(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		local hud = State.get("hud")
		if type(hud) == "table" and hud.downed == true then
			InputController.useSecondWind()
			return Enum.ContextActionResult.Sink
		end
	end
	return Enum.ContextActionResult.Pass
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

local function hideAimMarker()
	if aimMarker then
		aimMarker.CFrame = CFrame.new(0, -5000, 0)
	end
end

local function buildTouchButton()
	local okTheme, Theme = pcall(require, Client.UI.Theme)
	if not okTheme then
		warn("[Trunkfall] Theme missing, no touch ability button: " .. tostring(Theme))
		return
	end
	local screen = Theme.screen("TrunkfallTouch", 15)
	touchScreen = screen

	local size = 150
	local button = Theme.make("TextButton", {
		Name = "AbilityButton",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -36, 1, -44),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Theme.C.cheese,
		AutoButtonColor = false,
		Text = "",
		Parent = screen.root,
	}) :: TextButton
	Theme.round().Parent = button
	Theme.stroke(Theme.C.brownDark, 5).Parent = button
	local icon = Theme.label({
		Size = UDim2.fromScale(1, 0.55),
		Position = UDim2.fromScale(0, 0.12),
		Text = "💥",
		TextSize = 54,
		ZIndex = 4,
		Parent = button,
	})
	local name = Theme.label({
		Size = UDim2.fromScale(1, 0.22),
		Position = UDim2.fromScale(0, 0.64),
		Text = "ABILITY",
		TextSize = 20,
		TextColor3 = Theme.C.ink,
		ZIndex = 4,
		Parent = button,
	})
	local cdText = Theme.label({
		Size = UDim2.fromScale(1, 1),
		Text = "",
		TextSize = 44,
		ZIndex = 5,
		Parent = button,
	})
	Theme.textStroke().Parent = cdText
	local radial = Theme.radial(button, Theme.C.shade, 0.4)
	radial.frame.ZIndex = 3

	-- Ability name from the selected class (cosmetic only).
	local function refreshName()
		local Defs = require(Client.Util.Defs)
		local profile = State.get("profile")
		local lobby = State.get("lobby")
		local classId = nil
		local me = State.localUserId()
		if type(lobby) == "table" and type(lobby.players) == "table" and lobby.players[me] then
			classId = lobby.players[me].classId
		end
		if classId == nil and type(profile) == "table" then
			classId = profile.selectedClass
		end
		local def = Defs.get("Classes", classId)
		if def and def.ability and def.ability.name then
			name.Text = string.upper(tostring(def.ability.name))
		end
	end
	State.subscribe("lobby", refreshName, true)
	State.subscribe("profile", refreshName)

	local function refreshVisible()
		local phase = State.phase()
		button.Visible = phase ~= nil and phase ~= "Lobby" and phase ~= "Results"
	end
	State.subscribe("run", refreshVisible, true)

	local activeTouch: InputObject? = nil
	local startPos = Vector2.zero
	local dragging = false

	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch and activeTouch == nil then
			activeTouch = input
			startPos = Vector2.new(input.Position.X, input.Position.Y)
			dragging = false
			button.BackgroundColor3 = Theme.C.cheeseDark
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- Touch-capable laptops: plain click = auto-aim.
			local x, z = autoAim()
			InputController.fireAbility(x, z)
		end
	end)

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
				showAimMarker(d.X, d.Y)
			elseif dragging then
				hideAimMarker()
				dragging = false
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
			button.BackgroundColor3 = Theme.C.cheese
			hideAimMarker()
			local x, z
			if dragging then
				local d = Vector2.new(input.Position.X, input.Position.Y) - startPos
				x, z = directionAim(d.X, d.Y, STICK_AIM_DISTANCE)
			else
				x, z = autoAim()
			end
			dragging = false
			InputController.fireAbility(x, z)
		end)
	)

	table.insert(
		connections,
		RunService.RenderStepped:Connect(function()
			if not button.Visible then
				return
			end
			local rem, total = State.abilityCooldown()
			radial.set(if rem > 0 then rem / total else 0)
			cdText.Text = if rem > 0 then tostring(math.ceil(rem)) else ""
			icon.Visible = rem <= 0
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
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
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
