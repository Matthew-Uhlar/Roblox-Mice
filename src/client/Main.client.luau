--!strict
-- Client bootstrap (StarterPlayerScripts.Client.Main). Requires and inits
-- every controller and UI in order. Each one is isolated: a require or init
-- error is logged and the rest still start. Inits run in their own thread
-- so one that yields (e.g. waiting for remotes) can't stall the others.

local StarterGui = game:GetService("StarterGui")

local Client = script.Parent
local Controllers = Client:WaitForChild("Controllers")
local UI = Client:WaitForChild("UI")

-- Order matters: State first (it wires the S2C remotes the UIs read), then
-- world controllers, then UI.
local MODULES: { { name: string, path: () -> Instance? } } = {
	{
		name = "State",
		path = function()
			return Controllers:FindFirstChild("State")
		end,
	},
	{
		name = "CameraController",
		path = function()
			return Controllers:FindFirstChild("CameraController")
		end,
	},
	{
		name = "HordeRenderer",
		path = function()
			return Controllers:FindFirstChild("HordeRenderer")
		end,
	},
	{
		name = "FxController",
		path = function()
			return Controllers:FindFirstChild("FxController")
		end,
	},
	{
		name = "InputController",
		path = function()
			return Controllers:FindFirstChild("InputController")
		end,
	},
	{
		name = "HudUI",
		path = function()
			return UI:FindFirstChild("HudUI")
		end,
	},
	{
		name = "Toasts",
		path = function()
			return UI:FindFirstChild("Toasts")
		end,
	},
	{
		name = "LobbyUI",
		path = function()
			return UI:FindFirstChild("LobbyUI")
		end,
	},
	{
		name = "VoteUI",
		path = function()
			return UI:FindFirstChild("VoteUI")
		end,
	},
	{
		name = "UpgradeUI",
		path = function()
			return UI:FindFirstChild("UpgradeUI")
		end,
	},
	{
		name = "ShopUI",
		path = function()
			return UI:FindFirstChild("ShopUI")
		end,
	},
	{
		name = "ResultsUI",
		path = function()
			return UI:FindFirstChild("ResultsUI")
		end,
	},
}

-- Our HUD replaces the default health bar; the backpack would steal keys 1/2/3.
local function setCoreGui()
	for _ = 1, 10 do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
		end)
		if ok then
			return
		end
		task.wait(0.5)
	end
end
task.spawn(setCoreGui)

local loaded: { [string]: any } = {}

for _, entry in MODULES do
	local inst = entry.path()
	if not inst or not inst:IsA("ModuleScript") then
		warn("[Trunkfall] client module missing: " .. entry.name)
		continue
	end
	local ok, mod = pcall(require, inst)
	if not ok then
		warn("[Trunkfall] failed to require " .. entry.name .. ": " .. tostring(mod))
		continue
	end
	loaded[entry.name] = mod
	if type(mod) == "table" and type(mod.init) == "function" then
		-- task.spawn runs synchronously until the first yield, so init order holds.
		task.spawn(function()
			local okInit, err = xpcall(mod.init, debug.traceback)
			if not okInit then
				warn("[Trunkfall] " .. entry.name .. ".init failed:\n" .. tostring(err))
			end
		end)
	end
end

-- Clean up everything if the script is ever destroyed (e.g. hot reload in Studio).
script.Destroying:Connect(function()
	for _, entry in MODULES do
		local mod = loaded[entry.name]
		if type(mod) == "table" and type(mod.destroy) == "function" then
			pcall(mod.destroy)
		end
	end
end)
