--!strict
-- LeaderboardService (Team D): global boards on OrderedDataStores.
--
--   deepestCycle   deepest cycle reached (descending)
--   wins           total ranked wins (descending)
--   fastestCycle1  fastest Cycle-1 clear in whole seconds (ascending, GDD §8)
--   heroDowns      (v5) total enemy heroes downed in ranked runs (descending, GDD-v2 §8)
--   lastHerd       (v5) total Last Herd Standing finishes in ranked runs (descending)
-- The v5 boards only get writes once RunDirector passes stats.heroDowns / stats.lastHerd
-- to DataService.awardRun (a 0 value is never written).
--
-- Values come from profile.stats.ranked, so runs that used a Second Wind token never
-- count. Ranking policy (lead decision, docs/MONETIZATION.md): bot-assisted runs ARE
-- ranked (most solo players play with bots and bots never get entries themselves);
-- runs that used a paid Second Wind token are not. Writes happen at most once per run per player: DataService.awardRun calls
-- submit() (RunDirector should NOT call it separately), and submit ignores repeat
-- calls inside MIN_SUBMIT_INTERVAL. A write only happens when the value improved.
-- Top-50 lists are cached and refreshed every 5 minutes.
--
-- API:
--   LeaderboardService.init()
--   LeaderboardService.submit(player, { deepestCycle: number, wins: number, fastestCycle1: number?,
--                                       heroDowns: number?, lastHerd: number? })
--   LeaderboardService.getTop(boardName) -> { { rank, userId, name, value } }
--   LeaderboardService.BOARDS (names)

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local LeaderboardService = {}

LeaderboardService.TOP_N = 50
LeaderboardService.REFRESH_INTERVAL = 300
LeaderboardService.MIN_SUBMIT_INTERVAL = 60
-- GetSortedAsync budget is only 5 + 2/player per minute: a refresh waits up to
-- READ_BUDGET_WAIT s for budget and is skipped (stale cache kept) rather than queued.
LeaderboardService.READ_BUDGET_WAIT = 60
LeaderboardService.WRITE_BUDGET_WAIT = 60
LeaderboardService.BUDGET_POLL = 1
LeaderboardService.SEASON = "v1" -- bump (or use e.g. "2026W44") to start a new season

type BoardDef = { name: string, ascending: boolean }

LeaderboardService.BOARDS = {
	deepestCycle = { name = "deepestCycle", ascending = false },
	wins = { name = "wins", ascending = false },
	fastestCycle1 = { name = "fastestCycle1", ascending = true },
	heroDowns = { name = "heroDowns", ascending = false }, -- (v5) PvP downs
	lastHerd = { name = "lastHerd", ascending = false }, -- (v5) Last Herd Standing
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

-- Waits (bounded) until the DataStore request budget allows another request (QC2 Minor 7).
-- Returns true when budget is available, false when maxWait ran out (the caller decides
-- whether to skip the request or send it into Roblox's request queue anyway).
local function waitForBudget(requestType: any, maxWait: number): boolean
	local t0 = os.clock()
	while true do
		local ok, budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(requestType)
		end)
		if not ok or budget > 0 then
			return true
		end
		if os.clock() - t0 >= maxWait then
			return false
		end
		task.wait(LeaderboardService.BUDGET_POLL)
	end
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
		-- A write is worth queueing if the budget never frees up: send it after the wait.
		waitForBudget(Enum.DataStoreRequestType.SetIncrementSortedAsync, LeaderboardService.WRITE_BUDGET_WAIT)
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

-- Refreshes one board's cached top list. Returns "ok", "skipped" (no budget in time:
-- nothing sent, old cache kept) or "failed" (the request errored).
local function refresh(board: BoardDef, quiet: boolean?): string
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
			return "failed"
		end
		if not waitForBudget(Enum.DataStoreRequestType.GetSortedAsync, LeaderboardService.READ_BUDGET_WAIT) then
			return "skipped"
		end
		local ok, pages = pcall(function()
			return store:GetSortedAsync(board.ascending, LeaderboardService.TOP_N)
		end)
		if not ok then
			if not quiet then
				warn("[Leaderboard] refresh failed for " .. board.name .. ": " .. tostring(pages))
			end
			return "failed"
		end
		local okPage, page = pcall(function()
			return pages:GetCurrentPage()
		end)
		if not okPage then
			return "failed"
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
	return "ok"
end

-- Cached top list (copy). Unknown board -> empty list.
function LeaderboardService.getTop(boardName: string): { Entry }
	local list = cache[boardName]
	if not list then
		return {}
	end
	return table.clone(list)
end

-- Board names in a fixed order (the first one doubles as the Studio probe).
local ORDER = { "wins", "deepestCycle", "fastestCycle1", "heroDowns", "lastHerd" }

-- Refreshes every board one after another; each waits for its own GetSortedAsync
-- budget, so a cycle never sends more reads than the budget allows. `skip` names a
-- board already refreshed this cycle (the Studio probe).
function LeaderboardService.refreshAll(skip: string?)
	local order = table.clone(ORDER)
	for name in LeaderboardService.BOARDS do
		if not table.find(order, name) then
			table.insert(order, name)
		end
	end
	for _, name in order do
		local board = LeaderboardService.BOARDS[name]
		if board and name ~= skip then
			refresh(board)
		end
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
	-- Studio probe = the first board's real refresh (one GetSortedAsync, not an extra
	-- request on top of the 5 board reads).
	local probed: string? = nil
	if RunService:IsStudio() then
		local first = ORDER[1]
		if refresh(LeaderboardService.BOARDS[first], true) == "failed" then
			useMemory = true
			warn("[Leaderboard] DataStores unavailable in Studio: using in-memory boards.")
		else
			probed = first
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		lastSubmit[player.UserId] = nil
	end)
	task.spawn(function()
		while true do
			LeaderboardService.refreshAll(probed)
			probed = nil
			task.wait(LeaderboardService.REFRESH_INTERVAL)
		end
	end)
end

return LeaderboardService
