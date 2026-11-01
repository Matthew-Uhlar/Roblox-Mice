--!strict
-- DataService (Team D): session-locked player profiles on DataStoreService.
--
-- A hand-written ProfileStore-style store (vendoring packages isn't possible here):
--   * One key per player ("u_<userId>") holding { data = Profile, lock = {token, jobId, at}, savedAt }.
--   * Load = UpdateAsync that takes the lock unless another server holds a fresh one.
--     A lock older than STALE_LOCK_SECONDS (30 min) is taken over (crashed server).
--     The autosave refreshes `lock.at`, so a live server's lock never goes stale.
--   * Every save is an UpdateAsync that first checks the lock token. If another
--     server took the session, this server stops saving and kicks the player.
--   * Retries with exponential backoff; autosave every 120 s; final save + release on
--     PlayerRemoving and BindToClose.
--   * Studio without API access: in-memory profiles with a warning (saves "succeed",
--     so ProcessReceipt can still be tested with Studio's mock purchases).
--
-- Public API (ARCHITECTURE.md, Team D):
--   DataService.init()
--   DataService.get(player) -> Profile?
--   DataService.waitFor(player, timeout: number?) -> Profile?
--   DataService.update(player, fn: (Profile) -> ()) -> boolean
--   DataService.push(player)                          -- sends ProfileSchema.view via Net.S2C.Profile
--   DataService.save(player) -> boolean               -- immediate save, true on confirmed write
--   DataService.awardRun(player, cheese, xp, stats)   -- stats: {won, cycle, bosses, cycle1Time?, ranked?, day?}
--   DataService.beforeRelease(callback: (Player) -> ())  -- runs before the final save on leave/shutdown
--   DataService.isReadOnly(player) -> boolean
--   DataService.today() -> number                     -- UTC day number
--   DataService.addViewDecorator(fn: (Player, view) -> ())
--   DataService.onLoaded(fn: (Player, Profile) -> ())

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Types = require(Shared:WaitForChild("Types"))
local DataFolder = Shared:WaitForChild("Data")
local ProfileSchema = require(DataFolder:WaitForChild("ProfileSchema")) :: any
local Award = require(DataFolder:WaitForChild("Award")) :: any

type Profile = Types.Profile

local DataService = {}

-- Tunables -------------------------------------------------------------------
DataService.STORE_NAME = "TrunkfallProfiles_v1"
DataService.KEY_PREFIX = "u_"
DataService.AUTOSAVE_INTERVAL = 120
DataService.STALE_LOCK_SECONDS = 30 * 60
DataService.LOAD_LOCK_ATTEMPTS = 6 -- tries while another server holds a fresh lock
DataService.LOAD_LOCK_WAIT = 5 -- seconds between those tries
DataService.MAX_RETRIES = 5 -- per DataStore call, exponential backoff
DataService.BASE_BACKOFF = 1
DataService.BEFORE_RELEASE_TIMEOUT = 3
DataService.SHUTDOWN_TIMEOUT = 25
DataService.WAIT_FOR_TIMEOUT = 30

type Session = {
	player: Player,
	userId: number,
	key: string,
	token: string,
	profile: Profile?,
	loading: boolean,
	loaded: boolean,
	failed: boolean,
	readOnly: boolean, -- saved by a newer server version: never write over it
	lockLost: boolean,
	saving: boolean,
	releasing: boolean,
	released: boolean,
}

local sessions: { [Player]: Session } = {}
local releasingUsers: { [number]: boolean } = {}
local beforeReleaseCallbacks: { (Player) -> () } = {}
local viewDecorators: { (Player, { [string]: any }) -> () } = {}
local loadedCallbacks: { (Player, Profile) -> () } = {}
local memoryStore: { [string]: any } = {}

local store: any = nil
local useMemory = false
local initialized = false
local shuttingDown = false
local profileRemote: any = nil
local toastRemote: any = nil

-- Helpers --------------------------------------------------------------------

-- Bots are fake run participants with ids <= 0 and no Player object. Every public
-- function returns a safe default for them. Studio's local test server uses negative
-- UserIds for real Player objects, so those are allowed in Studio only.
function DataService.isRealPlayer(x: any): boolean
	if typeof(x) ~= "Instance" or not x:IsA("Player") then
		return false
	end
	return x.UserId > 0 or RunService:IsStudio()
end
local isRealPlayer = DataService.isRealPlayer

function DataService.today(): number
	return math.floor(os.time() / 86400)
end

local function toast(player: Player, text: string, kind: string?)
	if toastRemote then
		pcall(function()
			toastRemote:FireClient(player, text, kind or "info")
		end)
	end
end

local function waitForBudget(requestType: any, maxWait: number)
	local t0 = os.clock()
	while os.clock() - t0 < maxWait do
		local ok, budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(requestType)
		end)
		if not ok or budget > 0 then
			return
		end
		task.wait(0.5)
	end
end

-- pcall + exponential backoff. Returns (ok, resultOrError).
local function withRetries(label: string, fn: () -> any): (boolean, any)
	local delay = DataService.BASE_BACKOFF
	local lastErr: any = nil
	for attempt = 1, DataService.MAX_RETRIES do
		waitForBudget(Enum.DataStoreRequestType.UpdateAsync, 5)
		local ok, res = pcall(fn)
		if ok then
			return true, res
		end
		lastErr = res
		warn(
			string.format(
				"[DataService] %s failed (attempt %d/%d): %s",
				label,
				attempt,
				DataService.MAX_RETRIES,
				tostring(res)
			)
		)
		if attempt < DataService.MAX_RETRIES then
			task.wait(delay)
			delay *= 2
		end
	end
	return false, lastErr
end

local function newSession(player: Player): Session
	return {
		player = player,
		userId = player.UserId,
		key = DataService.KEY_PREFIX .. tostring(player.UserId),
		token = HttpService:GenerateGUID(false),
		profile = nil,
		loading = true,
		loaded = false,
		failed = false,
		readOnly = false,
		lockLost = false,
		saving = false,
		releasing = false,
		released = false,
	}
end

-- Load -----------------------------------------------------------------------

local function finishLoad(s: Session, raw: any)
	local profile, info = ProfileSchema.migrate(raw)
	if info.futureVersion then
		s.readOnly = true
		warn(
			string.format(
				"[DataService] %d has a v%d profile (server is v%d): read-only session",
				s.userId,
				info.fromVersion,
				ProfileSchema.VERSION
			)
		)
	end
	s.profile = profile
	s.loaded = true
end

local function loadSession(s: Session)
	-- A previous session of this user on THIS server may still be saving its release.
	local t0 = os.clock()
	while releasingUsers[s.userId] and os.clock() - t0 < 30 do
		task.wait(0.2)
	end

	if useMemory then
		finishLoad(s, ProfileSchema.deepCopy(memoryStore[s.key]))
		s.loading = false
		return
	end

	local attempt = 0
	while s.player.Parent == Players and not shuttingDown do
		attempt += 1
		local outcome = "ok"
		local rawData: any = nil
		local ok, err = withRetries("load " .. s.key, function()
			return store:UpdateAsync(s.key, function(old: any)
				local now = os.time()
				outcome = "ok"
				rawData = nil
				local record: any = if type(old) == "table" then old else nil
				if
					record
					and record.data == nil
					and record.lock == nil
					and record.savedAt == nil
					and next(record) ~= nil
				then
					record = { data = record } -- legacy: bare profile without the wrapper
				end
				local lock = record and record.lock
				if type(lock) == "table" and lock.token ~= nil and lock.token ~= s.token then
					local at = if type(lock.at) == "number" then lock.at else 0
					local fresh = now - at < DataService.STALE_LOCK_SECONDS
					if lock.jobId ~= game.JobId and fresh then
						outcome = "locked"
						return nil -- cancel: another live server owns this profile
					end
					if lock.jobId ~= game.JobId then
						outcome = "stale_takeover"
					end
				end
				rawData = record and record.data
				return {
					data = rawData,
					lock = { token = s.token, jobId = game.JobId, at = now },
					savedAt = if record and type(record.savedAt) == "number" then record.savedAt else now,
				}
			end)
		end)
		if not ok then
			s.failed = true
			s.loading = false
			warn("[DataService] could not load " .. s.key .. ": " .. tostring(err))
			s.player:Kick("We couldn't load your save data. Please rejoin in a minute.")
			return
		end
		if outcome ~= "locked" then
			if outcome == "stale_takeover" then
				warn("[DataService] took over a stale session lock for " .. s.key)
			end
			finishLoad(s, rawData)
			s.loading = false
			return
		end
		if attempt >= DataService.LOAD_LOCK_ATTEMPTS then
			s.failed = true
			s.loading = false
			s.player:Kick("Your save data is still being saved by another server. Please rejoin in a minute.")
			return
		end
		task.wait(DataService.LOAD_LOCK_WAIT)
	end
	s.loading = false
end

-- Save -----------------------------------------------------------------------

-- Saves the session. `release` clears the lock (final save). Serialized per session.
local function saveSession(s: Session, release: boolean): boolean
	if not s.loaded or not s.profile or s.readOnly or s.lockLost or s.released then
		return false
	end
	while s.saving do
		task.wait(0.1)
	end
	if s.released or s.lockLost then
		return false
	end
	s.saving = true
	local snapshot = ProfileSchema.deepCopy(s.profile)
	local result = false
	if useMemory then
		memoryStore[s.key] = snapshot
		result = true
	else
		local lost = false
		local ok, err = withRetries("save " .. s.key, function()
			return store:UpdateAsync(s.key, function(old: any)
				local now = os.time()
				lost = false
				local lock = type(old) == "table" and old.lock
				if type(lock) == "table" and lock.token ~= nil and lock.token ~= s.token then
					lost = true
					return nil
				end
				return {
					data = snapshot,
					lock = if release then nil else { token = s.token, jobId = game.JobId, at = now },
					savedAt = now,
				}
			end)
		end)
		if lost then
			s.lockLost = true
			warn("[DataService] session lock lost for " .. s.key .. "; another server owns it now")
			task.defer(function()
				if s.player.Parent == Players then
					s.player:Kick("Your save was opened on another server. Please rejoin.")
				end
			end)
		elseif not ok then
			warn("[DataService] save gave up for " .. s.key .. ": " .. tostring(err))
		end
		result = ok and not lost
	end
	s.saving = false
	return result
end

local function runBeforeRelease(player: Player)
	if #beforeReleaseCallbacks == 0 then
		return
	end
	local pending = #beforeReleaseCallbacks
	for _, cb in beforeReleaseCallbacks do
		task.spawn(function()
			local ok, err = pcall(cb, player)
			if not ok then
				warn("[DataService] beforeRelease callback errored: " .. tostring(err))
			end
			pending -= 1
		end)
	end
	local t0 = os.clock()
	while pending > 0 and os.clock() - t0 < DataService.BEFORE_RELEASE_TIMEOUT do
		task.wait(0.05)
	end
end

local function releaseSession(s: Session)
	if s.releasing then
		while not s.released do
			task.wait(0.1)
		end
		return
	end
	s.releasing = true
	releasingUsers[s.userId] = true
	local t0 = os.clock()
	while s.loading and os.clock() - t0 < 60 do
		task.wait(0.1)
	end
	if s.loaded then
		runBeforeRelease(s.player)
		saveSession(s, true)
	end
	s.released = true
	if sessions[s.player] == s then
		sessions[s.player] = nil
	end
	releasingUsers[s.userId] = nil
end

-- Public API -----------------------------------------------------------------

function DataService.get(player: Player): Profile?
	if not isRealPlayer(player) then
		return nil
	end
	local s = sessions[player]
	if s and s.loaded and not s.released then
		return s.profile
	end
	return nil
end

function DataService.waitFor(player: Player, timeout: number?): Profile?
	if not isRealPlayer(player) then
		return nil
	end
	local limit = timeout or DataService.WAIT_FOR_TIMEOUT
	local t0 = os.clock()
	while os.clock() - t0 < limit do
		local s = sessions[player]
		if s then
			if s.loaded and not s.released then
				return s.profile
			end
			if s.failed or s.released then
				return nil
			end
		end
		if player.Parent ~= Players then
			return nil
		end
		task.wait(0.1)
	end
	return nil
end

function DataService.isReadOnly(player: Player): boolean
	if not isRealPlayer(player) then
		return true
	end
	local s = sessions[player]
	return s == nil or s.readOnly or s.lockLost or not s.loaded or s.released
end

-- Mutates the profile in place. Returns false if no writable profile is loaded.
-- fn must not yield.
function DataService.update(player: Player, fn: (Profile) -> ()): boolean
	if not isRealPlayer(player) or type(fn) ~= "function" then
		return false
	end
	local s = sessions[player]
	if not s or not s.loaded or not s.profile or s.released or s.readOnly or s.lockLost then
		return false
	end
	local ok, err = pcall(fn, s.profile)
	if not ok then
		warn("[DataService] update callback errored: " .. tostring(err))
		return false
	end
	return true
end

function DataService.save(player: Player): boolean
	if not isRealPlayer(player) then
		return false
	end
	local s = sessions[player]
	if not s then
		return false
	end
	return saveSession(s, false)
end

function DataService.push(player: Player)
	if not isRealPlayer(player) then
		return
	end
	local s = sessions[player]
	if not s or not s.profile or not profileRemote then
		return
	end
	local view = ProfileSchema.view(s.profile, { today = DataService.today(), now = os.time() })
	for _, deco in viewDecorators do
		local ok, err = pcall(deco, player, view)
		if not ok then
			warn("[DataService] view decorator errored: " .. tostring(err))
		end
	end
	pcall(function()
		profileRemote:FireClient(player, view)
	end)
end

function DataService.beforeRelease(callback: (Player) -> ())
	table.insert(beforeReleaseCallbacks, callback)
end

function DataService.addViewDecorator(fn: (Player, { [string]: any }) -> ())
	table.insert(viewDecorators, fn)
end

function DataService.onLoaded(fn: (Player, Profile) -> ())
	table.insert(loadedCallbacks, fn)
	for player, s in sessions do
		if s.loaded and s.profile then
			task.spawn(fn, player, s.profile)
		end
	end
end

local function finite(n: any): number
	if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
		return 0
	end
	return n
end

-- End-of-run award. `cheese` and `xp` are final (RunDirector already applied
-- MonetizationService.cheeseMult/xpMult to the banked payout). Also submits ranked
-- stats to LeaderboardService (the one leaderboard write per run) and saves.
function DataService.awardRun(player: Player, cheese: number, xp: number, stats: { [string]: any }?)
	if not isRealPlayer(player) then
		return -- bots earn nothing persistent
	end
	local st: { [string]: any } = if type(stats) == "table" then stats else {}
	local day = st.day
	if type(day) ~= "number" or day ~= day or math.abs(day - DataService.today()) > 1 then
		day = DataService.today()
	end
	local ranked = st.ranked ~= false
	local result: any = nil
	local ok = DataService.update(player, function(profile)
		result = Award.applyRun(profile, {
			cheese = math.max(0, finite(cheese)),
			xp = math.max(0, finite(xp)),
			won = st.won == true,
			cycle = finite(st.cycle),
			bosses = finite(st.bosses),
			cycle1Time = if type(st.cycle1Time) == "number" then st.cycle1Time else nil,
			ranked = ranked,
			day = math.floor(day),
		})
	end)
	if not ok or not result then
		warn("[DataService] awardRun skipped for " .. player.Name .. " (no writable profile)")
		return
	end
	if result.firstRunBonus > 0 then
		toast(player, string.format("First run of the day: +%d bonus cheese!", result.firstRunBonus), "good")
	end
	if result.levelsGained > 0 then
		local profile = DataService.get(player)
		toast(
			player,
			string.format("Level up! You are now level %d.", if profile then profile.level else 0),
			"good"
		)
	end
	for _, id in result.cosmetics do
		toast(player, "New cosmetic unlocked: " .. id, "good")
	end
	DataService.push(player)

	if ranked then
		local profile = DataService.get(player)
		local okLb, Leaderboard = pcall(function()
			return require(script.Parent:FindFirstChild("LeaderboardService") :: ModuleScript) :: any
		end)
		if profile and okLb and type(Leaderboard) == "table" and type(Leaderboard.submit) == "function" then
			local rk = profile.stats.ranked
			task.spawn(Leaderboard.submit, player, {
				deepestCycle = rk.deepestCycle,
				wins = rk.wins,
				fastestCycle1 = rk.fastestCycle1,
			})
		end
	end
	task.spawn(DataService.save, player)
end

-- Lifecycle ------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	if sessions[player] or shuttingDown or not isRealPlayer(player) then
		return
	end
	local s = newSession(player)
	sessions[player] = s
	loadSession(s)
	if s.loaded and s.profile then
		if player.Parent ~= Players then
			task.spawn(releaseSession, s)
			return
		end
		for _, fn in loadedCallbacks do
			task.spawn(fn, player, s.profile :: Profile)
		end
		DataService.push(player)
	end
end

local function onPlayerRemoving(player: Player)
	local s = sessions[player]
	if s then
		releaseSession(s)
	end
end

local function detectStore()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(DataService.STORE_NAME)
	end)
	if ok and result then
		store = result
		if RunService:IsStudio() then
			-- Probe: Studio without "Enable Studio Access to API Services" errors here.
			local probeOk, err = pcall(function()
				return store:GetAsync("__probe__")
			end)
			if not probeOk then
				useMemory = true
				warn(
					"[DataService] DataStores unavailable in Studio ("
						.. tostring(err)
						.. "). Using IN-MEMORY profiles; nothing will persist."
				)
			end
		end
	else
		if RunService:IsStudio() then
			useMemory = true
			warn(
				"[DataService] DataStores unavailable in Studio. Using IN-MEMORY profiles; nothing will persist."
			)
		else
			error("[DataService] GetDataStore failed: " .. tostring(result))
		end
	end
end

function DataService.init()
	if initialized then
		return
	end
	initialized = true
	profileRemote = Net.get(Net.S2C.Profile)
	toastRemote = Net.get(Net.S2C.Toast)
	detectStore()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	task.spawn(function()
		while not shuttingDown do
			task.wait(DataService.AUTOSAVE_INTERVAL)
			if shuttingDown then
				break
			end
			local list: { Session } = {}
			for _, s in sessions do
				if s.loaded and not s.releasing then
					table.insert(list, s)
				end
			end
			-- Spread writes over a few seconds instead of one burst.
			local gap = math.min(1, 10 / math.max(1, #list))
			for _, s in list do
				task.spawn(saveSession, s, false)
				task.wait(gap)
			end
		end
	end)

	game:BindToClose(function()
		shuttingDown = true
		local pending = 0
		for _, s in sessions do
			pending += 1
			task.spawn(function()
				releaseSession(s)
				pending -= 1
			end)
		end
		local t0 = os.clock()
		while pending > 0 and os.clock() - t0 < DataService.SHUTDOWN_TIMEOUT do
			task.wait(0.1)
		end
	end)
end

return DataService
