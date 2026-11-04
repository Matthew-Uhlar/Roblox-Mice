--!strict
--[[
	Trunkfall server entry point.

	PLACE SETTINGS (set in Studio / Creator Hub; scripts can't or shouldn't set them):
	  - Game Settings > Places > Max Players = 12  (v2: one match per server = 4 squads x 3;
	    docs/GDD-v2.md §1). Players.MaxPlayers is NOT scriptable: the publish pipeline sets
	    the place's serverSize to 12. LobbyService seats at most 12 (LobbyRules.MAX_PARTY);
	    bots fill every empty seat, so a match always has 4 squads.
	  - Workspace.StreamingEnabled = false (recommended): the arena is small and client
	    scripts read arena parts. If you turn it on, set the arena and LobbyPad models to
	    ModelStreamingMode = Persistent.
	  - Workspace.SignalBehavior = Deferred is fine: nothing here relies on immediate signals.
	  - Workspace.FallenPartsDestroyHeight: keep the default (-500). The lobby pad sits at
	    Y = 0 around (0, 0, -400) and has invisible walls.
	  - Remove the template Baseplate and SpawnLocation from the place: LobbyService builds
	    the only SpawnLocation (on the lobby pad).
	  - Players.CharacterAutoLoads = true (set in default.project.json).
	  - Game Settings > Security: API Services ON (DataStores) for Studio testing.
	  - Avatar: R15, scaling off recommended so hitboxes match the 2-D combat sim.
	  - Gravity stays at the default (196.2): there is no gameplay physics.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any

Net.setupServer()

local Services = script.Parent:WaitForChild("Services")

-- Team D services are optional during integration: a missing or broken module
-- only disables its feature (RunDirector falls back to cheeseMult = 1, no awards).
local function initOptional(name: string)
	local inst = Services:FindFirstChild(name)
	if not inst or not inst:IsA("ModuleScript") then
		warn(string.format("[Main] %s not found; continuing without it", name))
		return
	end
	local ok, mod = pcall(require, inst)
	if not ok then
		warn(string.format("[Main] %s failed to load: %s", name, tostring(mod)))
		return
	end
	if type(mod) == "table" and type((mod :: any).init) == "function" then
		local initOk, err = pcall((mod :: any).init)
		if not initOk then
			warn(string.format("[Main] %s.init failed: %s", name, tostring(err)))
		end
	end
end

initOptional("DataService")
initOptional("MonetizationService")
initOptional("ShopService")
initOptional("LeaderboardService")
initOptional("CosmeticsService") -- after Data/Monetization: draws trails, hats, tints, nametags

pcall(function()
	Players.RespawnTime = 3
end)

local LobbyService = require(Services:WaitForChild("LobbyService"))
local RunDirector = require(Services:WaitForChild("RunDirector"))

LobbyService.init()
RunDirector.init()

print("[Main] Trunkfall server ready")
