--!strict
-- LeaderboardService (Team D): global boards on OrderedDataStores.
--
--   deepestCycle   deepest cycle reached (descending)
--   wins           total ranked wins (descending)
--   fastestCycle1  fastest Cycle-1 clear in whole seconds (ascending, GDD §8)
--
-- Values come from profile.stats.ranked, so runs that used a Second Wind token never
-- count. Writes happen at most once per run per player: DataService.awardRun calls
-- submit() (RunDirector should NOT call it separately), and submit ignores repeat
-- calls inside MIN_SUBMIT_INTERVAL. A write only happens when the value improved.
-- Top-50 lists are cached and refreshed every 5 minutes.
--
-- API:
--   LeaderboardService.init()
--   LeaderboardService.submit(player, { deepestCycle: number, wins: number, fastestCycle1: number? })
--   LeaderboardService.getTop(boardName) -> { { rank, userId, name, value } }
--   LeaderboardService.BOARDS (names)

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local LeaderboardService = {}

LeaderboardService.TOP_N = 50
LeaderboardService.REFRESH_INTERVAL = 300
LeaderboardService.MIN_SUBMIT_INTERVAL = 60
LeaderboardService.SEASON = "v1" -- bump (or use e.g. "2026W44") to start a new season

type BoardDef = { name: string, ascending: boolean }

LeaderboardService.BOARDS = {
	deepestCycle = { name = "deepestCycle", ascending = false },
	wins = { name = "wins", ascending = false },
	fastestCycle1 = { name = "fastestCycle1", ascending = true },
} :: { [string]: BoardDef }

export type Entry = { rank: number, userId: number, name: string, value: number }

local stores: { [string]: any } = {}
local memoryBoards: { [string]: { [string]: number } } = {}
local cache: { [string]: { Entry } } = {}
local names: { [number]: string } = {}
local lastSubmit: { [number]: number } = {}
local useMemory = false
local initialized = false

local function storeName(board: string): string
	return "LB_" .. board .. "_" .. LeaderboardService.SEASON
end

local function nameFor(userId: number): string
	local cached = names[userId]
	if cached then
		return cached
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		names[userId] = player.DisplayName
		return player.DisplayName
	end
	local ok, n = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local name = if ok and type(n) == "string" then n else ("#" .. tostring(userId))
	if ok then
		names[userId] = name
	end
	return name
end

local function validValue(board: BoardDef, v: any): number?
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return nil
	end
	local n = math.floor(v)
	if board.ascending then
		if n <= 0 or n > 1e6 then
			return nil -- 0 means "never cleared"
		end
	elseif n <= 0 or n > 1e9 then
		return nil
	end
	return n
end

local function better(board: BoardDef, new: number, old: any): boolean
	if type(old) ~= "number" then
		return true
	end
	return if board.ascending then new < old else new > old
end

local function write(board: BoardDef, userId: number, value: number)
	local key = tostring(userId)
	if useMemory then
		local t = memoryBoards[board.name]
		if better(board, value, t[key]) then
			t[key] = value
		end
		return
	end
	local store = stores[board.name]
	if not store then
		return
	end
	for attempt = 1, 3 do
		local ok, err = pcall(function()
			store:UpdateAsync(key, function(old: any)
				if better(board, value, old) then
					return value
				end
				return nil -- not an improvement: cancel the write
			end)
		end)
		if ok then
			return
		end
		warn(string.format("[Leaderboard] %s write failed (%d/3): %s", board.name, attempt, tostring(err)))
		task.wait(2 ^ attempt)
	end
end

-- Called once per run by DataService.awardRun with the player's ranked stats.
function LeaderboardService.submit(player: Player, stats: { [string]: any })
	-- Real players only: bots (ids <= 0, no Player) and Studio test ids never rank.
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.UserId <= 0 then
		return
	end
	if type(stats) ~= "table" then
		return
	end
	local userId = player.UserId
	local now = os.clock()
	if lastSubmit[userId] and now - lastSubmit[userId] < LeaderboardService.MIN_SUBMIT_INTERVAL then
		return
	end
	lastSubmit[userId] = now
	names[userId] = player.DisplayName
	for boardName, board in LeaderboardService.BOARDS do
		local v = validValue(board, stats[boardName])
		if v then
			task.spawn(write, board, userId, v)
		end
	end
end

local function refresh(board: BoardDef)
	local raw: { { key: string, value: number } } = {}
	if useMemory then
		for k, v in memoryBoards[board.name] do
			table.insert(raw, { key = k, value = v })
		end
		table.sort(raw, function(a, b)
			return if board.ascending then a.value < b.value else a.value > b.value
		end)
	else
		local store = stores[board.name]
		if not store then
			return
		end
		local ok, pages = pcall(function()
			return store:GetSortedAsync(board.ascending, LeaderboardService.TOP_N)
		end)
		if not ok then
			warn("[Leaderboard] refresh failed for " .. board.name .. ": " .. tostring(pages))
			return
		end
		local okPage, page = pcall(function()
			return pages:GetCurrentPage()
		end)
		if not okPage then
			return
		end
		for _, item in page do
			table.insert(raw, { key = item.key, value = item.value })
		end
	end
	local list: { Entry } = {}
	for i, item in raw do
		if i > LeaderboardService.TOP_N then
			break
		end
		local userId = tonumber(item.key)
		if userId and userId > 0 then
			table.insert(
				list,
				{ rank = #list + 1, userId = userId, name = nameFor(userId), value = item.value }
			)
		end
	end
	cache[board.name] = list
end

-- Cached top list (copy). Unknown board -> empty list.
function LeaderboardService.getTop(boardName: string): { Entry }
	local list = cache[boardName]
	if not list then
		return {}
	end
	return table.clone(list)
end

function LeaderboardService.refreshAll()
	for _, board in LeaderboardService.BOARDS do
		refresh(board)
	end
end

function LeaderboardService.init()
	if initialized then
		return
	end
	initialized = true
	for name in LeaderboardService.BOARDS do
		memoryBoards[name] = {}
		local ok, store = pcall(function()
			return DataStoreService:GetOrderedDataStore(storeName(name))
		end)
		if ok then
			stores[name] = store
		end
	end
	if RunService:IsStudio() then
		local probeOk = pcall(function()
			local any = stores.wins
			if any then
				any:GetSortedAsync(false, 1)
			else
				error("no store")
			end
		end)
		if not probeOk then
			useMemory = true
			warn("[Leaderboard] DataStores unavailable in Studio: using in-memory boards.")
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		lastSubmit[player.UserId] = nil
	end)
	task.spawn(function()
		while true do
			LeaderboardService.refreshAll()
			task.wait(LeaderboardService.REFRESH_INTERVAL)
		end
	end)
end

return LeaderboardService
