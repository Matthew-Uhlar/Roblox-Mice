--!strict
-- Device / input-mode detection. "Mobile" means a touch device without a
-- keyboard; it drives effect caps, the on-screen ability button and UI scale.

local UserInputService = game:GetService("UserInputService")

local Signal = require(script.Parent.Signal)

local Device = {}

Device.modeChanged = Signal.new() -- (mode: "kbm" | "gamepad" | "touch")

local function classify(t: Enum.UserInputType): string?
	if t == Enum.UserInputType.Touch then
		return "touch"
	elseif string.find(t.Name, "Gamepad") then
		return "gamepad"
	elseif
		t == Enum.UserInputType.Keyboard
		or t == Enum.UserInputType.MouseButton1
		or t == Enum.UserInputType.MouseButton2
		or t == Enum.UserInputType.MouseMovement
		or t == Enum.UserInputType.MouseWheel
	then
		return "kbm"
	end
	return nil
end

local mode: string = classify(UserInputService:GetLastInputType())
	or (if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then "touch" else "kbm")

UserInputService.LastInputTypeChanged:Connect(function(t)
	local m = classify(t)
	if m and m ~= mode then
		mode = m
		Device.modeChanged:Fire(m)
	end
end)

-- Phone/tablet: touch-capable without a hardware keyboard.
function Device.isMobile(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

-- True if the device can touch at all (show the touch ability button).
function Device.hasTouch(): boolean
	return UserInputService.TouchEnabled
end

-- Current input mode based on the last input used.
function Device.mode(): string
	return mode
end

-- Low-spec budget switch for effect caps and detail.
function Device.lowSpec(): boolean
	return Device.isMobile()
end

return Device
