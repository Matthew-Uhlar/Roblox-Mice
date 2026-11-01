--!strict
-- Top-down, fixed-yaw camera (~55° pitch) that springs after the character.
-- Scroll wheel / pinch zoom within limits. Fixed yaw keeps the default
-- PlayerModule movement camera-relative (W = screen up = world -Z).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Device = require(Client.Util.Device)

local CameraController = {}

local PITCH = math.rad(55)
local FOV = 45
local MIN_ZOOM = 34
local MAX_ZOOM = 95
local FOLLOW_RATE = 10 -- higher = snappier follow
local ZOOM_RATE = 10
local WHEEL_STEP = 6
local BIND_NAME = "TrunkfallTopDownCamera"

local zoom = if Device.isMobile() then 62 else 56
local targetZoom = zoom
local focus: Vector3? = nil
local shakeAmp = 0
local shakeDecay = 0
local connections: { RBXScriptConnection } = {}
local bound = false

local function clampZoom(z: number): number
	return math.clamp(z, MIN_ZOOM, MAX_ZOOM)
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
	if target then
		if focus == nil or (target - (focus :: Vector3)).Magnitude > 80 then
			focus = target -- snap on spawn/teleport
		else
			focus = (focus :: Vector3):Lerp(target, 1 - math.exp(-FOLLOW_RATE * dt))
		end
	end
	if focus == nil then
		return
	end

	zoom += (targetZoom - zoom) * (1 - math.exp(-ZOOM_RATE * dt))
	local offset = Vector3.new(0, math.sin(PITCH) * zoom, math.cos(PITCH) * zoom)

	local shake = Vector3.zero
	if shakeAmp > 0 then
		shake = Vector3.new((math.random() - 0.5) * 2 * shakeAmp, 0, (math.random() - 0.5) * 2 * shakeAmp)
		shakeAmp = math.max(0, shakeAmp - shakeDecay * dt)
	end

	local f = focus :: Vector3
	cam.FieldOfView = FOV
	cam.CFrame = CFrame.lookAt(f + offset + shake, f + shake)
	cam.Focus = CFrame.new(f)
end

function CameraController.init()
	if bound then
		return
	end
	bound = true

	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, step)

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
			if input.KeyCode == Enum.KeyCode.ButtonL3 then
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
