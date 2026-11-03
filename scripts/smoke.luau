-- In-Roblox smoke test. NOT part of the place: scripts/publish.py sends this file
-- as a Luau Execution session task against a freshly published place version
-- (docs/publishing/CLOUD_PUBLISHING_PLAYBOOK.md §4) and asserts the facts it returns.
--
-- Luau Execution sessions do not run the place's scripts. So this script waits a
-- few seconds, and if the server didn't boot by itself it boots it exactly the
-- way src/server/Main.server.luau does:
--   * if ServerScriptService.Server has a ModuleScript "Boot", it calls
--     Boot.start() (single source of truth; see docs/publishing/SMOKE.md), else
--   * it runs the MIRROR below. Keep OPTIONAL and REQUIRED in the same order as
--     Main.server.luau. `python3 scripts/publish.py smoke-sync` checks it (check.sh
--     warns, publish.yml refuses to publish when they differ).
--
-- Returns one JSON string of facts. Never prompts, never touches player data.

local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- MIRROR of Main.server.luau (boot order matters).
local OPTIONAL =
	{ "DataService", "MonetizationService", "ShopService", "LeaderboardService", "CosmeticsService" }
local REQUIRED = { "LobbyService", "RunDirector" }

local facts: { [string]: any } = {
	placeId = game.PlaceId,
	gameId = game.GameId,
	placeVersion = game.PlaceVersion,
	jobId = game.JobId,
	services = {},
	errors = {},
	warnings = {},
}

local logConn = LogService.MessageOut:Connect(function(message: string, kind: Enum.MessageType)
	if kind == Enum.MessageType.MessageError then
		if #facts.errors < 20 then
			table.insert(facts.errors, string.sub(message, 1, 500))
		end
	elseif kind == Enum.MessageType.MessageWarning then
		if #facts.warnings < 20 then
			table.insert(facts.warnings, string.sub(message, 1, 300))
		end
	end
end)

local function remotesFolder(): Instance?
	return ReplicatedStorage:FindFirstChild("Remotes")
end

-- 1. Did the place boot by itself?
local waited = 0
while not remotesFolder() and waited < 5 do
	waited += task.wait(0.25)
end
facts.autoRan = remotesFolder() ~= nil

local Server = ServerScriptService:WaitForChild("Server", 10)
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(
	Server and Shared,
	"ServerScriptService.Server or ReplicatedStorage.Shared missing: is this the Rojo place?"
)
local Services = Server:WaitForChild("Services", 10) :: Instance

local function initOptional(name: string)
	local inst = Services:FindFirstChild(name)
	if not inst or not inst:IsA("ModuleScript") then
		facts.services[name] = "missing"
		return
	end
	local ok, mod = pcall(require, inst)
	if not ok then
		facts.services[name] = "load failed: " .. tostring(mod)
		return
	end
	if type(mod) == "table" and type((mod :: any).init) == "function" then
		local initOk, err = pcall((mod :: any).init)
		if not initOk then
			facts.services[name] = "init failed: " .. tostring(err)
			return
		end
	end
	facts.services[name] = "ok"
end

local function bootMirror()
	local Net = require(Shared:WaitForChild("Net")) :: any
	Net.setupServer()
	for _, name in OPTIONAL do
		initOptional(name)
	end
	pcall(function()
		Players.RespawnTime = 3
	end)
	local mods = {}
	for _, name in REQUIRED do
		mods[name] = require(Services:WaitForChild(name, 10)) :: any
	end
	for _, name in REQUIRED do
		mods[name].init()
		facts.services[name] = "ok"
	end
end

-- 2. Boot it ourselves when it didn't.
if facts.autoRan then
	facts.bootMode = "auto"
else
	local boot = Server:FindFirstChild("Boot")
	facts.bootMode = if boot and boot:IsA("ModuleScript") then "boot-module" else "mirror"
	local ok, err = xpcall(function()
		if boot and boot:IsA("ModuleScript") then
			local report = (require(boot) :: any).start()
			if type(report) == "table" then
				for k, v in report do
					facts.services[tostring(k)] = tostring(v)
				end
			end
		else
			bootMirror()
		end
	end, debug.traceback)
	if not ok then
		facts.bootError = string.sub(tostring(err), 1, 2000)
	end
end

-- 3. Let deferred threads (task.spawn / task.defer in init) run and fail loudly.
task.wait(3)

-- 4. Facts about the booted world.
local Net = require(Shared:WaitForChild("Net")) :: any
local expected = 0
for _, group in { Net.C2S, Net.S2C } do
	for _ in group do
		expected += 1
	end
end
facts.expectedRemotes = expected
local folder = remotesFolder()
facts.remotes = if folder then #folder:GetChildren() else 0

local spawns = 0
for _, d in workspace:GetDescendants() do
	if d:IsA("SpawnLocation") then
		spawns += 1
	end
end
facts.spawnLocations = spawns

-- Config/Monetization string-requires "./ProductIds": this proves `require("./X")`
-- works on a live Roblox server (HANDOFF launch check).
local monOk, Monetization = pcall(require, Shared:WaitForChild("Config"):WaitForChild("Monetization"))
facts.stringRequire = monOk
if monOk then
	local configured = 0
	for _, item in (Monetization :: any).ALL do
		if (Monetization :: any).isConfigured(item) then
			configured += 1
		end
	end
	facts.configuredItems = configured
else
	facts.stringRequireError = tostring(Monetization)
end

logConn:Disconnect()
facts.errorCount = #facts.errors
return HttpService:JSONEncode(facts)
