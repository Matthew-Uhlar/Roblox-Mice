--!strict
-- Boots the Trunkfall server. Main.server.luau calls Boot.start(); so does the
-- in-Roblox smoke test (scripts/smoke.luau, docs/publishing/SMOKE.md), because
-- Luau Execution sessions don't run place Scripts. One source of truth for the
-- boot order:
--
--   1. Net.setupServer() (ReplicatedStorage.Remotes)
--   2. OPTIONAL services (pcall require + init): Data, Monetization, Shop,
--      Leaderboard, Cosmetics. A missing or broken one only disables its feature.
--   3. Players.RespawnTime = 3
--   4. REQUIRED services: LobbyService.init(), then RunDirector.init()
--   5. Lobby lighting (LightingService.apply("lobby"), R4) when it exists
--
-- Boot.start() -> { [serviceName]: "ok" | "missing" | "load failed: …" | "init failed: …" }
-- It runs once; later calls return the first result. A REQUIRED service that
-- fails is recorded, warned and re-raised on a separate thread, so it still
-- shows up as a script error (LogService / the smoke test's `errors`).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Boot = {}

Boot.OPTIONAL = { "DataService", "MonetizationService", "ShopService", "LeaderboardService", "CosmeticsService" }
Boot.REQUIRED = { "LobbyService", "RunDirector" }

local result: { [string]: string }? = nil

function Boot.start(): { [string]: string }
	if result then
		return result
	end
	local status: { [string]: string } = {}
	result = status

	local Shared = ReplicatedStorage:WaitForChild("Shared")
	local Net = require(Shared:WaitForChild("Net")) :: any
	Net.setupServer()

	local Services = script.Parent:WaitForChild("Services")

	local function load(name: string): (any, string?)
		local inst = Services:FindFirstChild(name)
		if not inst or not inst:IsA("ModuleScript") then
			return nil, "missing"
		end
		local ok, mod = pcall(require, inst)
		if not ok then
			return nil, "load failed: " .. tostring(mod)
		end
		return mod, nil
	end

	local function init(mod: any): string
		if type(mod) == "table" and type(mod.init) == "function" then
			local ok, err = pcall(mod.init)
			if not ok then
				return "init failed: " .. tostring(err)
			end
		end
		return "ok"
	end

	-- Optional services: a missing or broken module only disables its feature
	-- (RunDirector falls back to cheeseMult = 1, no awards).
	for _, name in Boot.OPTIONAL do
		local mod, why = load(name)
		status[name] = if why then why else init(mod)
		if status[name] == "missing" then
			warn(string.format("[Main] %s not found; continuing without it", name))
		elseif status[name] ~= "ok" then
			warn(string.format("[Main] %s: %s", name, status[name]))
		end
	end

	pcall(function()
		Players.RespawnTime = 3
	end)

	for _, name in Boot.REQUIRED do
		local mod, why = load(name)
		status[name] = if why then why else init(mod)
		if status[name] ~= "ok" then
			local msg = string.format("[Main] REQUIRED %s: %s", name, status[name])
			warn(msg)
			task.spawn(error, msg, 0)
		end
	end

	-- Lobby mood (R4). Not a service with init; optional.
	local lighting, why = load("LightingService")
	if lighting and type(lighting.apply) == "function" then
		local ok, err = pcall(lighting.apply, "lobby")
		status.LightingService = if ok then "ok" else "init failed: " .. tostring(err)
	else
		status.LightingService = why or "missing"
	end

	return status
end

return Boot
