--!strict
-- DataService (Team D): session-locked player profiles on DataStoreService.
--
-- A hand-written ProfileStore-style store (vendoring packages isn't possible here):
--   * One key per player ("u_<userId>") holding { data = Profile, lock = {token, jobId, at}, savedAt }.
--   * Load = UpdateAsync that takes the lock unless another server holds a fresh one.
--     A lock older than STALE_LOCK_SECONDS (7 min = 3.5 autosaves) is taken over
--     (crashed server). The autosave refreshes `lock.at` every 120 s, so a live
--     server's lock never goes stale.
--   * Release handshake (like ProfileStore): while another server holds a fresh lock,
--     the loading server publishes a MessagingService release request. The holder
--     kicks/releases that session (final save + unlock) so the player gets in within
--     seconds instead of waiting for the lock to go stale. pcall-guarded; without
--     MessagingService the stale timeout still works.
--   * A save that can't be read (migration/reconcile error) opens a read-only
--     "corrupt" session: nothing is ever written over it, the lock is released
--     without touching the data, and the player is asked to rejoin (QC2 M6).
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
--   DataService.awardRun(player, cheese, xp, stats)   -- stats: {won, cycle, bosses, cycle1Time?, ranked?, day?, pressurePoints?,
--                                                     --   classId?, classXp?, heroDowns?, lastHerd?, (or the runXp summary:
--                                                     --   stagesSurvived?, bossDamageShare?, pois?, extracted?)}
--   DataService.beforeRelease(callback: (Player) -> ())  -- runs before the final save on leave/shutdown
--   DataService.isReadOnly(player) -> boolean
--   DataService.today() -> number                     -- UTC day number
--   DataService.addViewDecorator(fn: (Player, view) -> ())
--   DataService.onLoaded(fn: (Player, Profile) -> ())
--   (v6, v4 plan "Progression") for M2 / game code:
--   DataService.questEvent(player, kind, n?)          live Herd Contract progress (Config/Quests.LIVE_KINDS:
--                                                     mice, ability, revive, gear, vault, lair, carrier, totem)
--   DataService.collect(player, page, entryId)        Mousepedia entry (pages: bosses, champions, mice,
--                                                     gear, maps; classes fill themselves)
--   DataService.runCount(player) -> number            finished matches (0 for bots / not loaded)
--   DataService.isRookie(player) -> boolean           runs < ProfileSchema.ROOKIE_RUNS (3)
--   DataService.pushProgress(player)                  sends Net.S2C.Quests and Net.S2C.Pass
--   DataService.setPremiumCheck(fn: (Player, passKey) -> boolean)  MonetizationService installs it
--   awardRun stats (v6 additions): stagesCleared?, fullClear?, championKills?, banked?
--   (cheese before Robux multipliers, for contracts), bossIds?, championIds?, mapIds? (Mousepedia).
--   The first extraction bonus (500 cheese + 50 GC, once) is automatic (Data/Award).
--   (iterations 1 + 2) long-term progression, docs/MONETIZATION.md "Iteration 2":
--   awardRun stats: mice?, minutes?/seconds?, champAssists? (class XP), tier? (Config/Difficulty),
--     solo?, clearSeconds?, extractStage?, challengeFlags? (Config/Challenges flags and counters).
--   DataService.runBonuses(player, classId, squadmates?) -> Data/RunBonus.Resolved
--     {delta, pve, extras = {rindMult, wheyMult, pveResist, ascNodes, ...}, uniques}
--     (Prestige + Ascension + the squad gem aura) for Run/Stats.compute's 7th param
--   DataService.squadGemAura(players, classIds?) -> Data/RunBonus.Resolved (node-8 squad aura only;
--     iteration 4: gems are personal)
--   DataService.dropGem: REMOVED in iteration 4 (no-op); gems drop on round completion in awardRun
--   DataService.addStomps(player, classId, mice, tier?)
--   DataService.prestige / setLook / equipGem / upgradeGem / salvageGem (player, ...) -> (ok, reasonOrResult)
--   DataService.restoreBackup(userId) -> (ok, msg)  ADMIN ONLY (console), never a remote

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Types = require(Shared:WaitForChild("Types"))
local DataFolder = Shared:WaitForChild("Data")
local ProfileSchema = require(DataFolder:WaitForChild("ProfileSchema")) :: any
local Award = require(DataFolder:WaitForChild("Award")) :: any
local ClassProgress = require(DataFolder:WaitForChild("ClassProgress")) :: any
local ConfigFolder = Shared:WaitForChild("Config")
local Classes = require(ConfigFolder:WaitForChild("Classes")) :: any
local ClassAbilities = require(ConfigFolder:WaitForChild("ClassAbilities")) :: any
local ClassSkins = require(ConfigFolder:WaitForChild("ClassSkins")) :: any
local Cosmetics = require(ConfigFolder:WaitForChild("Cosmetics")) :: any
local PassConfig = require(ConfigFolder:WaitForChild("Pass")) :: any
local QuestConfig = require(ConfigFolder:WaitForChild("Quests")) :: any
local AchievementConfig = require(ConfigFolder:WaitForChild("Achievements")) :: any
local Progress = require(DataFolder:WaitForChild("Progress")) :: any
local LifetimeStats = require(DataFolder:WaitForChild("LifetimeStats")) :: any -- iter 5 #6 / #8
local Quests = require(DataFolder:WaitForChild("Quests")) :: any
local HerdPass = require(DataFolder:WaitForChild("HerdPass")) :: any
local Grant = require(DataFolder:WaitForChild("Grant")) :: any
local Gems = require(DataFolder:WaitForChild("Gems")) :: any
local Ascension = require(DataFolder:WaitForChild("Ascension")) :: any
local Ladder = require(DataFolder:WaitForChild("Ladder")) :: any
local GemConfig = require(ConfigFolder:WaitForChild("Gems")) :: any
local ChallengeConfig = require(ConfigFolder:WaitForChild("Challenges")) :: any
local DifficultyConfig = require(ConfigFolder:WaitForChild("Difficulty")) :: any
local Evolution = require(DataFolder:WaitForChild("Evolution")) :: any
local RunBonus = require(DataFolder:WaitForChild("RunBonus")) :: any

type Profile = Types.Profile

local DataService = {}

-- Tunables -------------------------------------------------------------------
DataService.STORE_NAME = "TrunkfallProfiles_v1"
DataService.KEY_PREFIX = "u_"
DataService.AUTOSAVE_INTERVAL = 120
DataService.STALE_LOCK_SECONDS = 7 * 60 -- 3.5x AUTOSAVE_INTERVAL (QC2 M7)
DataService.RELEASE_TOPIC = "TrunkfallProfileRelease"
DataService.SAME_SERVER_RELEASE_WAIT = 90 -- a slow release on this server (retries + budget)
DataService.LOAD_LOCK_ATTEMPTS = 6 -- tries while another server holds a fresh lock
DataService.LOAD_LOCK_WAIT = 5 -- seconds between those tries
DataService.MAX_RETRIES = 5 -- per DataStore call, exponential backoff
DataService.BASE_BACKOFF = 1
DataService.BEFORE_RELEASE_TIMEOUT = 3
DataService.SHUTDOWN_TIMEOUT = 25
DataService.WAIT_FOR_TIMEOUT = 30
-- Roblox allows one write per DataStore key every 6 s (faster writes are queued with a
-- warning). Saves are paced to this and coalesced: requests made while waiting share one write.
DataService.WRITE_SPACING = 6
-- (iter 1, Z-17) one-time copy of the raw pre-v7 save, written before the first v7 save
DataService.BACKUP_STORE_NAME = "TrunkfallBackups_v1"
DataService.BACKUP_KEY_PREFIX = "pre_v7_"

type Session = {
	player: Player,
	userId: number,
	key: string,
	token: string,
	profile: Profile?,
	loading: boolean,
	loaded: boolean,
	failed: boolean,
	readOnly: boolean, -- saved by a newer server version, or unreadable: never write over it
	corrupt: boolean, -- the save exists but could not be read (ProfileSchema.sessionMode)
	lockHeld: boolean, -- this session's token is (as far as we know) the stored lock
	lockLost: boolean,
	saving: boolean,
	releasing: boolean,
	released: boolean,
	saveRequests: number, -- save requests so far (each takes the next ticket)
	savedThrough: number, -- every request up to this ticket is in a confirmed write
	lastWriteAt: number, -- os.clock() of the last write to this key (load or save)
	-- (Z-17) the raw pre-v7 save still to be backed up. While set, the session NEVER
	-- writes the profile (the stored pre-v7 save stays untouched); every save attempt
	-- retries the backup first, and a new session retries it again.
	backupRaw: any?,
	backupFrom: number,
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
local questsRemote: any = nil
local passRemote: any = nil
local premiumCheck: ((Player, string) -> boolean)? = nil
local lastProgressPush: { [Player]: number } = {}
local progressPushQueued: { [Player]: boolean } = {}
local lastSyncDay: { [Player]: number } = {}
DataService.PROGRESS_PUSH_SPACING = 2 -- seconds between Quests/Pass pushes from live events
DataService.ROLLOVER_CHECK_INTERVAL = 60

-- Forward declarations (defined in the Save section, used by loadSession).
local releaseLockOnly: (Session) -> ()
local requestRelease: (number, string) -> ()

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
		corrupt = false,
		lockHeld = false,
		lockLost = false,
		saving = false,
		releasing = false,
		released = false,
		saveRequests = 0,
		savedThrough = 0,
		lastWriteAt = -math.huge,
		backupRaw = nil,
		backupFrom = 0,
	}
end

-- Load -----------------------------------------------------------------------

-- QC m4 (iteration 6): a save from a newer server version opens read-only (no saves)
DataService.READ_ONLY_TEXT = "This server is on an older update; progress here won't save. "
	.. "Rejoin for the latest version."
DataService.READ_ONLY_TOAST_DELAY = 5

local CORRUPT_KICK = "We couldn't read your save data just now. Nothing was lost: your progress "
	.. "is safe and untouched. Please rejoin in a few minutes. (code PROFILE_READ)"

local function finishLoad(s: Session, raw: any)
	local profile, info = ProfileSchema.migrate(raw)
	local mode = ProfileSchema.sessionMode(raw, info)
	if mode == "corrupt" then
		-- Never treat an unreadable save as a fresh profile: the next autosave would
		-- overwrite the real data. No profile is exposed; the session can't save.
		s.readOnly = true
		s.corrupt = true
		s.failed = true
		warn(
			string.format(
				"[DataService] %d: save could not be read (v%d): %s. Read-only, asking the player to rejoin.",
				s.userId,
				info.fromVersion,
				tostring(info.error)
			)
		)
		return
	end
	if mode == "readOnly" then
		s.readOnly = true
		warn(
			string.format(
				"[DataService] %d has a v%d profile (server is v%d): read-only session",
				s.userId,
				info.fromVersion,
				ProfileSchema.VERSION
			)
		)
		-- QC m4 (iteration 6): tell the player once, after the client has booted
		local player = s.player
		task.delay(DataService.READ_ONLY_TOAST_DELAY, function()
			if player.Parent ~= nil then
				toast(player, DataService.READ_ONLY_TEXT, "bad")
			end
		end)
	end
	-- (iter 1, Z-17) before this session can write the first v7 save, keep the raw
	-- older save once in a separate store. Until that copy is confirmed the session
	-- writes nothing (saveSession checks), so no player can lose the backup.
	if
		info.fromVersion < 7
		and type(raw) == "table"
		and next(raw) ~= nil
		and not useMemory
		and not s.readOnly
	then
		s.backupRaw = raw
		s.backupFrom = info.fromVersion
		DataService.ensureBackup(s)
	end
	s.profile = profile
	s.loaded = true
end

-- (Z-17) Writes the one-time pre-v7 copy (with retries; UpdateAsync never overwrites an
-- earlier copy). Returns true once it is confirmed (or nothing is pending).
function DataService.ensureBackup(s: any): boolean
	if s.backupRaw == nil then
		return true
	end
	local raw, from = s.backupRaw, s.backupFrom
	local ok, err = withRetries("backup " .. s.key, function()
		local bstore = DataStoreService:GetDataStore(DataService.BACKUP_STORE_NAME)
		return bstore:UpdateAsync(DataService.BACKUP_KEY_PREFIX .. tostring(s.userId), function(old: any)
			if old ~= nil then
				return nil -- an earlier copy exists: keep it
			end
			return { data = raw, version = from, at = os.time() }
		end)
	end)
	if ok then
		s.backupRaw = nil
		return true
	end
	warn(
		"[DataService] pre-v7 backup failed for "
			.. s.key
			.. " (no save until it succeeds; retried on every save): "
			.. tostring(err)
	)
	return false
end

local function loadSession(s: Session)
	-- A previous session of this user on THIS server may still be saving its release.
	-- Its lock carries this JobId, which the load below always takes over, so wait
	-- for the old release to finish its final save (QC2 Minor 5).
	local t0 = os.clock()
	while
		releasingUsers[s.userId]
		and s.player.Parent == Players
		and os.clock() - t0 < DataService.SAME_SERVER_RELEASE_WAIT
	do
		task.wait(0.2)
	end

	if useMemory then
		finishLoad(s, ProfileSchema.deepCopy(memoryStore[s.key]))
		s.loading = false
		return
	end

	local requestedRelease = false

	local attempt = 0
	while s.player.Parent == Players and not shuttingDown do
		attempt += 1
		local outcome = "ok"
		local rawData: any = nil
		local holderJobId: any = nil
		local ok, err = withRetries("load " .. s.key, function()
			s.lastWriteAt = os.clock()
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
						holderJobId = lock.jobId
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
			s.lockHeld = true
			finishLoad(s, rawData)
			s.loading = false
			return
		end
		if not requestedRelease and type(holderJobId) == "string" then
			requestedRelease = true
			requestRelease(s.userId, holderJobId)
			toast(s.player, "Finishing the save from your last server, one moment...", "info")
		end
		if attempt >= DataService.LOAD_LOCK_ATTEMPTS then
			s.failed = true
			s.loading = false
			s.player:Kick(
				"Your save data is still being saved by another server. Please rejoin in a few minutes."
			)
			return
		end
		task.wait(DataService.LOAD_LOCK_WAIT)
	end
	s.loading = false
end

-- Save -----------------------------------------------------------------------

-- Saves the session. `release` clears the lock (final save). Serialized per session.
-- Paced and coalesced (WRITE_SPACING): a write waits until 6 s after the previous one,
-- and every save requested before its snapshot shares that ONE write instead of each
-- queueing a throttled write. A request returns true once a write whose snapshot was
-- taken after it is confirmed.
local function saveSession(s: Session, release: boolean): boolean
	if not s.loaded or not s.profile or s.readOnly or s.lockLost or s.released then
		return false
	end
	-- (Z-17) never write v7 over a pre-v7 save that has no backup copy yet
	if not DataService.ensureBackup(s) then
		return false
	end
	s.saveRequests += 1
	local ticket = s.saveRequests
	while s.saving do
		task.wait(0.1)
	end
	if s.released or s.lockLost then
		return false
	end
	if not release and s.savedThrough >= ticket then
		return true -- a later write already covered this request
	end
	s.saving = true
	local gap = DataService.WRITE_SPACING - (os.clock() - s.lastWriteAt)
	if gap > 0 then
		task.wait(gap) -- saves requested meanwhile (e.g. several pass perks) join this write
	end
	local covers = s.saveRequests
	local snapshot = ProfileSchema.deepCopy(s.profile)
	local result = false
	if useMemory then
		memoryStore[s.key] = snapshot
		result = true
	else
		local lost = false
		local ok, err = withRetries("save " .. s.key, function()
			s.lastWriteAt = os.clock()
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
		if ok and not lost and release then
			s.lockHeld = false
		end
		if lost then
			s.lockLost = true
			s.lockHeld = false
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
	if result then
		s.savedThrough = math.max(s.savedThrough, covers)
	end
	s.saving = false
	return result
end

-- Clears this session's lock WITHOUT touching the stored data (read-only and
-- corrupt sessions). Only removes the lock if it is still ours.
releaseLockOnly = function(s: Session)
	local ok, err = withRetries("unlock " .. s.key, function()
		return store:UpdateAsync(s.key, function(old: any)
			if type(old) ~= "table" or type(old.lock) ~= "table" or old.lock.token ~= s.token then
				return nil -- not our lock (or no lock): change nothing
			end
			old.lock = nil
			return old
		end)
	end)
	if ok then
		s.lockHeld = false
	else
		warn("[DataService] could not release the lock for " .. s.key .. ": " .. tostring(err))
	end
end

-- Clears a lock stamped with THIS server's JobId for a user who has no session
-- here any more (a release whose final save failed). Used by the handshake.
local function clearOrphanLock(userId: number)
	local key = DataService.KEY_PREFIX .. tostring(userId)
	local ok, err = pcall(function()
		store:UpdateAsync(key, function(old: any)
			if type(old) ~= "table" or type(old.lock) ~= "table" or old.lock.jobId ~= game.JobId then
				return nil
			end
			old.lock = nil
			return old
		end)
	end)
	if not ok then
		warn("[DataService] orphan lock clear failed for " .. key .. ": " .. tostring(err))
	end
end

-- Asks the server holding `userId`'s lock to release it. Fire-and-forget.
requestRelease = function(userId: number, holderJobId: string)
	if useMemory or holderJobId == game.JobId then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:PublishAsync(
				DataService.RELEASE_TOPIC,
				{ userId = userId, jobId = holderJobId, from = game.JobId }
			)
		end)
		if not ok then
			warn("[DataService] release request not sent: " .. tostring(err))
		end
	end)
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
	if s.loaded and not s.readOnly then
		runBeforeRelease(s.player)
		saveSession(s, true)
	end
	if s.lockHeld and not s.lockLost and not useMemory then
		-- Read-only / corrupt sessions never write data, but must still hand the lock
		-- back so the next server doesn't wait for it to go stale.
		releaseLockOnly(s)
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
	-- (v6, QC-C M2) account level as a player attribute: chat shows an [Lv N] tag.
	-- push() runs on load and after every award, so it follows every level change.
	pcall(function()
		if player:GetAttribute("AccountLevel") ~= (s.profile :: Profile).level then
			player:SetAttribute("AccountLevel", (s.profile :: Profile).level)
		end
	end)
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

-- (v5) Class level-up / unlock toasts and the mastery badge, after an award.
local function className(classId: string): string
	local def = Classes.get(classId)
	return if def then def.name else classId
end

local function awardBadge(player: Player, badgeId: number)
	if type(badgeId) ~= "number" or badgeId <= 0 then
		return -- TODO(dashboard): Config/ClassSkins.MASTERY badgeId
	end
	task.spawn(function()
		pcall(function()
			game:GetService("BadgeService"):AwardBadge(player.UserId, badgeId)
		end)
	end)
end

function DataService.classToasts(player: Player, c: any)
	if type(c) ~= "table" or type(c.classId) ~= "string" then
		return
	end
	-- (iteration 2) Prestige re-climb and the Prestige button
	if (c.plevelsGained or 0) > 0 then
		toast(player, string.format("%s reached level %d!", className(c.classId), c.plevel), "good")
	end
	if c.prestigeReady then
		toast(player, string.format("%s can Prestige! Open the Hero screen.", className(c.classId)), "good")
	end
	if (c.levelsGained or 0) <= 0 then
		return
	end
	local name = className(c.classId)
	toast(
		player,
		string.format(
			"%s reached class level %d! +%d perk point%s.",
			name,
			c.level,
			c.perkPoints,
			if c.perkPoints == 1 then "" else "s"
		),
		"good"
	)
	for _, id in c.abilities or {} do
		local e = ClassAbilities.get(id)
		toast(player, string.format("New %s ability: %s!", name, if e then e.def.name else id), "good")
	end
	for _, k in c.slots or {} do -- iteration 5 (A3): a new ability slot (class level 10 / 20)
		toast(player, string.format("New %s ability slot %d! Equip it in the hero screen.", name, k), "good")
	end
	for _, id in c.skins or {} do
		local def = ClassSkins.get(id)
		toast(player, string.format("New %s skin: %s!", name, if def then def.name else id), "good")
	end
	if c.mastery then
		local m = ClassSkins.masteryByTier(c.mastery)
		if m then
			toast(player, string.format("%s mastery: %s!", name, m.title), "good")
			awardBadge(player, m.badgeId)
		end
	end
end

-- (v6) Progression --------------------------------------------------------------

local function cosmeticName(id: string): string
	local def = Cosmetics.get(id)
	return if def then def.name else id
end

local function titleText(id: string): string
	local t = Cosmetics.EARNED_TITLES[id]
	return if t then t.text else id
end

local function refreshLooks(player: Player)
	local okC, Cos = pcall(function()
		return require(script.Parent:FindFirstChild("CosmeticsService") :: ModuleScript) :: any
	end)
	if okC and type(Cos) == "table" and type(Cos.refresh) == "function" then
		pcall(Cos.refresh, player)
	end
end

function DataService.setPremiumCheck(fn: ((Player, string) -> boolean)?)
	premiumCheck = fn
end

-- Does the player own the premium game pass of the profile's current season?
local function premiumNow(player: Player, profile: Profile): boolean
	local st = HerdPass.state(profile)
	local key = PassConfig.premiumKey(st.season)
	if not key or not premiumCheck then
		return false
	end
	local ok, v = pcall(premiumCheck, player, key)
	return ok and v == true
end
DataService.premiumNow = premiumNow

-- Toasts for a Data/Progress summary.
local function progressToasts(player: Player, sum: any)
	if type(sum) ~= "table" then
		return
	end
	for _, id in sum.completed or {} do
		local def = QuestConfig.get(id)
		if def then
			toast(
				player,
				"Contract complete: " .. QuestConfig.describe(def) .. "! Claim it in Contracts.",
				"good"
			)
		end
	end
	for _, c in sum.collected or {} do
		toast(player, string.format("Mousepedia: new %s entry! +5 Golden Cheese", c.page), "good")
	end
	if (sum.tiers or 0) > 0 then
		toast(
			player,
			string.format("Herd Pass: +%d tier%s!", sum.tiers, if sum.tiers == 1 then "" else "s"),
			"good"
		)
	end
	for _, id in sum.achievements or {} do
		local def = AchievementConfig.get(id)
		toast(player, "Achievement: " .. (if def then def.name else id) .. "!", "good")
	end
	for _, id in (sum.given and sum.given.titles) or {} do
		toast(player, "Title unlocked: " .. titleText(id), "good")
	end
end

-- Sends Net.S2C.Quests and Net.S2C.Pass (docs/MONETIZATION.md has the payloads).
function DataService.pushProgress(player: Player)
	if not isRealPlayer(player) then
		return
	end
	local s = sessions[player]
	if not s or not s.profile then
		return
	end
	local profile = s.profile :: Profile
	local day = DataService.today()
	local prem = premiumNow(player, profile)
	if prem and not s.readOnly then
		HerdPass.setPremium(profile, true)
	end
	lastProgressPush[player] = os.clock()
	local okQ, qv = pcall(Quests.view, profile, os.time())
	local okP, pv = pcall(HerdPass.view, profile, day, prem)
	if questsRemote and okQ then
		pcall(function()
			questsRemote:FireClient(player, qv)
		end)
	end
	if passRemote and okP then
		pcall(function()
			passRemote:FireClient(player, pv)
		end)
	end
end

-- Coalesced push for frequent live events.
local function pushProgressSoon(player: Player)
	if progressPushQueued[player] then
		return
	end
	local wait = DataService.PROGRESS_PUSH_SPACING - (os.clock() - (lastProgressPush[player] or -math.huge))
	if wait <= 0 then
		DataService.pushProgress(player)
		return
	end
	progressPushQueued[player] = true
	task.delay(wait, function()
		progressPushQueued[player] = nil
		if player.Parent == Players then
			DataService.pushProgress(player)
		end
	end)
end

-- Day / week / season rollover for one player (auto-grants finished work).
-- Returns true when something changed (new day, or auto-grants).
function DataService.syncProgress(player: Player): boolean
	local day = DataService.today()
	local changed = false
	local questGiven, passGiven = nil, nil
	local ok = DataService.update(player, function(profile)
		if premiumNow(player, profile) then
			HerdPass.setPremium(profile, true)
		end
		questGiven, passGiven = Progress.sync(profile, day, player.UserId)
	end)
	if not ok then
		return false
	end
	if lastSyncDay[player] ~= day then
		lastSyncDay[player] = day
		changed = true
	end
	if questGiven then
		toast(
			player,
			"Finished contracts from last time were claimed for you: " .. Grant.describe(questGiven),
			"good"
		)
	end
	if passGiven then
		toast(player, "Herd Pass season over! Your unclaimed rewards: " .. Grant.describe(passGiven), "good")
	end
	if questGiven or passGiven then
		changed = true
		task.spawn(DataService.save, player)
		DataService.push(player)
	end
	return changed
end

-- Live Herd Contract progress (M2). kind: Config/Quests.LIVE_KINDS. Run-end kinds
-- (match, stage, extract, boss, champion, pois, bank, classRun) come from awardRun
-- and are ignored here, so nothing counts twice.
function DataService.questEvent(player: Player, kind: string, n: number?)
	if not isRealPlayer(player) or type(kind) ~= "string" or not QuestConfig.LIVE_KINDS[kind] then
		return
	end
	local amount = if type(n) == "number" and n == n and n > 0 then n else 1
	local completed: { string } = {}
	local ok = DataService.update(player, function(profile)
		completed =
			Progress.event(profile, kind, amount, { day = DataService.today(), userId = player.UserId })
	end)
	if not ok then
		return
	end
	progressToasts(player, { completed = completed })
	pushProgressSoon(player)
end

-- Mousepedia entry (M2 / M1). Unknown pages / ids and repeats are ignored.
function DataService.collect(player: Player, page: string, entryId: string)
	if not isRealPlayer(player) then
		return
	end
	local sum: any = nil
	DataService.update(player, function(profile)
		sum = Progress.collect(profile, page, entryId, { day = DataService.today(), userId = player.UserId })
	end)
	if sum then
		progressToasts(player, sum)
		DataService.push(player)
		pushProgressSoon(player)
	end
end

-- (iteration 3, T-8) The chosen difficulty tier, saved in profile.settings.tier so any
-- server (and Play Again) preselects it. M2: call setTier from the tier pick (onSetDifficulty)
-- and lastTier when a lobby needs the player's tier. 0 = Custom. Clamped to the unlocked tier.
function DataService.setTier(player: Player, tier: number): boolean
	if type(tier) ~= "number" or tier ~= tier then
		return false
	end
	local t = math.clamp(math.floor(tier), 0, DifficultyConfig.COUNT) -- iteration 8: 12 tiers
	return DataService.update(player, function(profile)
		local d = (profile :: any).difficulty
		local unlocked = if type(d) == "table" and type(d.unlocked) == "number" then d.unlocked else 2
		profile.settings.tier = math.min(t, unlocked)
	end)
end

function DataService.lastTier(player: Player): number?
	local profile = DataService.get(player)
	return if profile then ProfileSchema.lastTier(profile) else nil
end

-- (iteration 6, team Flow) The chosen match pace, saved in profile.settings.pace
-- ("fast", or nil for Normal) so any server (and Play Again) preselects it. Additive.
function DataService.setPace(player: Player, pace: string): boolean
	if pace ~= "normal" and pace ~= "fast" then
		return false
	end
	return DataService.update(player, function(profile)
		profile.settings.pace = if pace == "fast" then "fast" else nil
	end)
end

function DataService.lastPace(player: Player): string?
	local profile = DataService.get(player)
	return if profile then ProfileSchema.lastPace(profile) else nil
end

-- Finished matches (Rookie Run: runs 0..2 are rookie runs). 0 for bots / unloaded.
function DataService.runCount(player: Player): number
	local profile = DataService.get(player)
	return if profile then profile.stats.runs else 0
end

function DataService.isRookie(player: Player): boolean
	if not isRealPlayer(player) then
		return false
	end
	local profile = DataService.get(player)
	return profile ~= nil and profile.stats.runs < ProfileSchema.ROOKIE_RUNS
end

-- (iterations 1 + 2) Long-term progression -----------------------------------------

local function gemText(g: any): string
	local u = if g.u then GemConfig.unique(g.u) else nil
	return string.format(
		"%s gem (tier %d)%s",
		GemConfig.TIER_NAMES[g.t] or "?",
		g.t,
		if u then " with " .. u.name else ""
	)
end

local function v5Toasts(player: Player, sum: any)
	if type(sum) ~= "table" then
		return
	end
	local st = sum.stomps
	if type(st) == "table" then
		for _, id in st.unlocked or {} do
			toast(player, string.format("%s unlocked for free by your stomps!", className(id)), "good")
		end
	end
	local lad = sum.ladder
	if type(lad) == "table" then
		if lad.unlocked then
			toast(
				player,
				"New difficulty unlocked: " .. DifficultyConfig.get(lad.unlocked).name .. "!",
				"good"
			)
		end
		if lad.bestSolo then
			toast(player, "New Best Solo: " .. DifficultyConfig.get(lad.bestSolo).name .. "!", "good")
		end
	end
	for _, g in sum.gems or {} do
		toast(player, "New " .. gemText(g) .. "!", "good")
	end
	if (sum.gemDust or 0) > 0 then
		toast(player, string.format("Gem bag full: a new gem became %d Crumb Dust.", sum.gemDust), "info")
	end
	if (sum.minibossDust or 0) > 0 then -- iteration 7 (team Systems)
		toast(player, string.format("Miniboss kills: +%d Crumb Dust.", sum.minibossDust), "good")
	end
	for _, id in sum.challenges or {} do
		local def = ChallengeConfig.get(id)
		toast(player, "Challenge complete: " .. (if def then def.name else id) .. "!", "good")
	end
	if sum.gemWatch then
		warn(string.format("[DataService] %d is over the daily gem-grant watch", player.UserId))
	end
end

-- On load: the one-time toasts (stomps seeded, levels raised by the new curve) and the
-- free class unlocks already earned.
function DataService.v5Welcome(player: Player)
	local seeded, unlocked, grew = 0, {}, nil
	DataService.update(player, function(profile)
		local p: any = profile
		seeded = p.stompSeedNotice or 0
		p.stompSeedNotice = 0
		grew = p.levelNotice
		p.levelNotice = nil
		unlocked = Evolution.freeUnlocks(profile)
	end)
	if seeded > 0 then
		toast(player, string.format("Your herd remembers: %d stomps from your past matches!", seeded), "good")
	end
	-- (iteration 3, T-15) once per account: converted Mastery Stars
	local converted = {}
	DataService.update(player, function(profile)
		if profile.settings.prestigeNoticeSeen == true then
			return
		end
		local classes = (profile :: any).classes
		if type(classes) == "table" then
			for id, cs in classes do
				if ClassProgress.stars(cs) > 0 then
					table.insert(
						converted,
						string.format("%s ⭐%d", className(id), ClassProgress.prestige(cs))
					)
				end
			end
		end
		profile.settings.prestigeNoticeSeen = true
	end)
	if #converted > 0 then
		table.sort(converted)
		toast(
			player,
			"Your Mastery Stars are now Prestige (" .. table.concat(converted, ", ") .. "). Nothing was lost.",
			"good"
		)
	end
	if type(grew) == "table" then
		local parts = {}
		for id, pair in grew do
			table.insert(parts, string.format("%s %d → %d", className(id), pair[1], pair[2]))
		end
		table.sort(parts)
		toast(player, "Your elephants grew: " .. table.concat(parts, ", "), "good")
	end
	for _, id in unlocked do
		toast(player, string.format("%s unlocked for free by your stomps!", className(id)), "good")
	end
end

-- The squad aura alone. (iteration 4) Gems are PERSONAL now, so the only squad aura left
-- is ascension node 8 (+5% PvE damage per member who has it). `classIds[player]` is the
-- class each member plays. Bots get this (they carry no gems).
function DataService.squadGemAura(players: { Player }, classIds: { [Player]: string }?): any
	local b = RunBonus.new()
	local squadPve = 0
	for _, p in players or {} do
		local profile = DataService.get(p)
		if profile then
			local cid = if classIds then classIds[p] else (profile :: any).selectedClass
			squadPve += Ascension.squadPve(profile, cid)
		end
	end
	RunBonus.add(b, "pve", nil, squadPve)
	return RunBonus.resolve(b, {})
end

-- Long-term run bonus of one hero: Prestige + Ascension of the class played, the hero's
-- OWN gems (iteration 4: personal, from round start; `uniques` are this hero's), plus the
-- squad's ascension node-8 aura (pass the squad's human players). Bots: pass nil as player.
function DataService.runBonuses(player: Player?, classId: string?, squadmates: { Player }?): any
	local b = RunBonus.new()
	local profile = if player then DataService.get(player) else nil
	local uniques = {}
	if profile then
		if type(classId) == "string" then
			RunBonus.merge(b, Ascension.bonus(profile, classId))
		end
		local own = Gems.personal(profile, classId)
		RunBonus.merge(b, own.bonus)
		uniques = own.uniques
	end
	local squadPve = 0
	for _, p in squadmates or (if player then { player } else {}) do
		local pr = DataService.get(p)
		if pr then
			local cid = if p == player and classId then classId else (pr :: any).selectedClass
			squadPve += Ascension.squadPve(pr, cid)
		end
	end
	RunBonus.add(b, "pve", nil, squadPve)
	return RunBonus.resolve(b, uniques)
end

-- Stomps outside awardRun (awardRun already adds the match's `mice`).
function DataService.addStomps(player: Player, classId: string, mice: number, tier: number?)
	local added: any = nil
	DataService.update(player, function(profile)
		added = Evolution.addStomps(
			profile,
			classId,
			Evolution.matchStomps(mice, DifficultyConfig.get(tier).reward)
		)
	end)
	if added then
		v5Toasts(player, { stomps = added })
	end
end

-- (iteration 4) REMOVED: gems drop only on round completion (DataService.awardRun rolls
-- them). Kept as a no-op so an old caller can't error; M2 should stop calling it.
function DataService.dropGem(_player: Player, _tier: number, _chance: number?, _opts: any?): any
	return nil
end

local function v5Op(player: Player, fn: (Profile) -> (boolean, any, any?)): (boolean, any, any?)
	if not DataService.get(player) or DataService.isReadOnly(player) then
		return false, "no_profile"
	end
	local ok, res, extra = false, nil, nil
	DataService.update(player, function(profile)
		ok, res, extra = fn(profile)
	end)
	return ok, res, extra
end

-- Prestige (class level 30). Returns (ok, reasonOrResult {prestige, reward?}).
function DataService.prestige(player: Player, classId: string): (boolean, any)
	local ok, reason = v5Op(player, function(profile)
		local classes = (profile :: any).classes
		local ascBefore = Ascension.nodes(if type(classes) == "table" then classes[classId] else nil)
		local o, why, r = ClassProgress.doPrestige(profile, classId)
		if o and r then
			-- (iteration 3, T-14) what the Prestige gave, for one celebratory message
			r.ascBefore = ascBefore
			r.ascNodes = Ascension.nodes(classes[classId])
			r.perkPoint = r.prestige <= ClassProgress.PERK_PRESTIGE_CAP
			r.bonus = r.prestige <= 40
		end
		return o, if o then r else why
	end)
	return ok, reason
end

function DataService.setLook(player: Player, classId: string, stage: number): (boolean, any)
	return v5Op(player, function(profile)
		return Ascension.setLook(profile, classId, stage)
	end)
end

function DataService.equipGem(player: Player, slot: number, gemId: number?): (boolean, any)
	return v5Op(player, function(profile)
		return Gems.equip(profile, slot, gemId)
	end)
end

function DataService.upgradeGem(player: Player, gemId: number): (boolean, any)
	local ok, res = v5Op(player, function(profile)
		local o, r = Gems.upgrade(profile, gemId)
		if o then
			Progress.checkChallenges(profile)
		end
		return o, r
	end)
	return ok, res
end

function DataService.salvageGem(player: Player, gemId: number): (boolean, any)
	return v5Op(player, function(profile)
		return Gems.salvage(profile, gemId)
	end)
end

-- ===== iter6 Gem Vault (team Gems): each op is one DataService.update (atomic) =====
function DataService.feedGems(player: Player, targetId: number, ids: { number }): (boolean, any)
	return v5Op(player, function(profile)
		local o, r = Gems.feed(profile, targetId, ids)
		if o then
			Progress.checkChallenges(profile)
		end
		return o, r
	end)
end

function DataService.salvageGems(player: Player, ids: { number }): (boolean, any)
	return v5Op(player, function(profile)
		return Gems.salvageMany(profile, ids)
	end)
end

function DataService.lockGem(player: Player, gemId: number, locked: boolean): (boolean, any)
	return v5Op(player, function(profile)
		return Gems.setLocked(profile, gemId, locked)
	end)
end
-- ===== end iter6 Gem Vault =====

-- ADMIN ONLY (Studio command bar / server console; never wired to a remote). Puts the
-- one-time pre-v7 copy back as the profile of an OFFLINE player whose save holds no
-- fresh lock. Returns (ok, message).
function DataService.restoreBackup(userId: number): (boolean, string)
	if useMemory or not store then
		return false, "no DataStore"
	end
	if Players:GetPlayerByUserId(userId) then
		return false, "the player is in this server: kick them first"
	end
	local okB, backup = pcall(function()
		return DataStoreService:GetDataStore(DataService.BACKUP_STORE_NAME)
			:GetAsync(DataService.BACKUP_KEY_PREFIX .. tostring(userId))
	end)
	if not okB or type(backup) ~= "table" or type(backup.data) ~= "table" then
		return false, "no backup"
	end
	local msg = "restored"
	local okW, err = pcall(function()
		store:UpdateAsync(DataService.KEY_PREFIX .. tostring(userId), function(old: any)
			local lock = type(old) == "table" and old.lock
			if
				type(lock) == "table"
				and os.time() - (tonumber(lock.at) or 0) < DataService.STALE_LOCK_SECONDS
			then
				msg = "a server holds a fresh lock: try again later"
				return nil
			end
			return { data = backup.data, savedAt = os.time() }
		end)
	end)
	if not okW then
		return false, tostring(err)
	end
	warn(
		string.format("[DataService] restoreBackup %d: %s (from v%s)", userId, msg, tostring(backup.version))
	)
	return msg == "restored", msg
end

-- End-of-run award. `cheese` and `xp` are final (RunDirector already applied
-- MonetizationService.cheeseMult/xpMult to the banked payout). Also submits ranked
-- stats to LeaderboardService (the one leaderboard write per run) and saves.
-- Returns (iter 1) a Results breakdown for M2, or nil when nothing was awarded:
--   { passXp, firstRunBonus?, firstExtractBonus = {cheese, golden}?,
--     contracts = {cheese, passXp, count}?   -- contracts COMPLETED this match (claimable)
--     achievements = {cheese, golden}? }     -- achievements earned this match (already given)
-- Callers that ignore the return keep working.
function DataService.awardRun(player: Player, cheese: number, xp: number, stats: { [string]: any }?): any
	if not isRealPlayer(player) then
		return -- bots earn nothing persistent
	end
	local st: { [string]: any } = if type(stats) == "table" then stats else {}
	local day = st.day
	if type(day) ~= "number" or day ~= day or math.abs(day - DataService.today()) > 1 then
		day = DataService.today()
	end
	local ranked = st.ranked ~= false
	-- (v5) class XP: RunDirector passes classXp (ClassProgress.runXp), or the summary
	-- fields and it is computed here. Never multiplied by Robux boosts.
	local classId = if type(st.classId) == "string" and ClassProgress.isClass(st.classId)
		then st.classId
		else nil
	local classXp = 0
	if classId then
		if type(st.classXp) == "number" then
			classXp = math.clamp(math.floor(finite(st.classXp)), 0, ClassProgress.MAX_RUN_XP)
		else
			classXp = ClassProgress.runXp({
				stagesSurvived = st.stagesSurvived,
				bossDamageShare = st.bossDamageShare,
				heroDowns = st.heroDowns,
				pois = st.pois,
				extracted = st.extracted == true or (st.extracted == nil and st.won == true),
			})
		end
	end
	local result: any = nil
	local summary: any = nil
	local lifetime: any = nil -- iter 5 #6 / #8
	local function list(v: any): { string }?
		if type(v) ~= "table" then
			return nil
		end
		local out = {}
		for _, x in v do
			if type(x) == "string" and #x <= 64 and #out < 64 then
				table.insert(out, x)
			end
		end
		return out
	end
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
			pressurePoints = finite(st.pressurePoints), -- (G1) Award clamps it to 0..Pressure.MAX_POINTS
			classId = classId,
			classXp = classXp,
			heroDowns = finite(st.heroDowns),
			lastHerd = st.lastHerd == true or (type(st.lastHerd) == "number" and st.lastHerd > 0),
			-- (v6) v4 fields
			extracted = if st.extracted ~= nil then st.extracted == true else nil,
			stagesCleared = if type(st.stagesCleared) == "number" then finite(st.stagesCleared) else nil,
			fullClear = if type(st.fullClear) == "boolean" then st.fullClear else nil,
			championKills = finite(st.championKills),
		})
		-- (v6) Herd Pass XP, contracts, Mastery Stars, Mousepedia, achievements
		local extracted = st.extracted == true
			or (st.extracted == nil and st.won == true)
			or st.lastHerd == true
			or (type(st.lastHerd) == "number" and st.lastHerd > 0)
		local cleared = if type(st.stagesCleared) == "number"
			then finite(st.stagesCleared)
			else finite(st.bosses)
		summary = Progress.afterRun(profile, {
			day = DataService.today(),
			userId = player.UserId,
			classId = classId,
			stagesCleared = cleared,
			stagesSurvived = finite(st.stagesSurvived),
			extracted = extracted,
			championKills = finite(st.championKills),
			bosses = finite(st.bosses),
			pois = finite(st.pois),
			banked = if type(st.banked) == "number" then finite(st.banked) else math.max(0, finite(cheese)),
			bossIds = list(st.bossIds),
			championIds = list(st.championIds),
			mapIds = list(st.mapIds),
			classAward = result.class,
			-- (v5)
			mice = finite(st.mice),
			pressure = if type(st.runPressurePoints) == "number"
				then finite(st.runPressurePoints)
				else finite(st.pressurePoints),
			win = result.win == true,
			fullClear = if type(st.fullClear) == "boolean" then st.fullClear else nil,
			stagesAlive = if type(st.stagesAlive) == "number" then finite(st.stagesAlive) else nil,
			stageReached = math.max(finite(st.bestStage), finite(st.stagesSurvived), cleared),
			-- (iteration 2) ladder, gems, challenges
			tier = if type(st.tier) == "number" then st.tier else nil,
			clear = st.fullClear == true or st.lastHerd == true,
			lastHerd = st.lastHerd == true or (type(st.lastHerd) == "number" and st.lastHerd > 0),
			solo = st.solo == true,
			ranked = ranked,
			clearSeconds = if type(st.clearSeconds) == "number" then finite(st.clearSeconds) else nil,
			extractStage = if type(st.extractStage) == "number"
				then finite(st.extractStage)
				elseif extracted then cleared
				else nil,
			challengeFlags = if type(st.challengeFlags) == "table" then st.challengeFlags else nil,
			gemSeed = Random.new():NextInteger(1, 2_000_000_000),
			overtimeWaves = finite(st.overtimeWaves), -- iteration 7 (team Systems): gem tiers 13-14
		})
		-- (iter 5 #6 / #8) time played, damage, clears per tier, the Overtime record
		local okL, lres = pcall(LifetimeStats.applyRun, profile, {
			seconds = if type(st.playedSeconds) == "number"
				then finite(st.playedSeconds)
				else finite(st.seconds),
			damage = finite(st.damage),
			classId = classId,
			tier = if type(st.tier) == "number" and st.custom ~= true then st.tier else nil,
			clear = st.fullClear == true or st.lastHerd == true,
			overtimeWaves = finite(st.overtimeWaves),
		})
		lifetime = if okL then lres else nil
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
		toast(player, "New cosmetic unlocked: " .. cosmeticName(id), "good") -- QC-C m3: name, not id
	end
	if result.firstExtractBonus then
		toast(
			player,
			string.format(
				"FIRST EXTRACTION! +%d cheese and +%d Golden Cheese!",
				result.firstExtractBonus.cheese,
				result.firstExtractBonus.goldenCheese
			),
			"good"
		)
	end
	if result.pressureUnlocked then
		toast(player, "Pressure unlocked! Stack modifiers in the lobby for more cheese.", "good")
	elseif result.pressureRecord then
		toast(player, string.format("New Pressure record: %d!", result.pressureRecord), "good")
	end
	if result.class then
		DataService.classToasts(player, result.class)
	end
	progressToasts(player, summary)
	v5Toasts(player, summary)
	DataService.push(player)
	DataService.pushProgress(player)
	-- QC-C m2: the nametag's mastery title / stars change with the class level
	-- (iteration 2) also when a challenge completes (WheelFrame / titles on the nametag)
	if
		result.class and (result.class.levelsGained > 0 or result.class.prestigeReady)
		or (summary and #(summary.challenges or {}) > 0)
	then
		task.spawn(refreshLooks, player)
	end

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
				heroDowns = (rk :: any).heroDowns, -- (v5) PvP downs board
				lastHerd = (rk :: any).lastHerd, -- (v5) Last Herd Standing board
				bestStage = (rk :: any).bestStage, -- (v6) replaces deepestCycle (QC-C B3)
				championKills = (rk :: any).championKills, -- (v6)
				stomps = (profile.stats :: any).stomps, -- (v5) account stomps (all runs)
				bestSolo = Ladder.bestSoloScore(profile), -- (iteration 2) tier, then time
				bestSquad = Ladder.state(profile).bestSquad, -- (iteration 2)
			})
		end
	end
	-- A releasing session (leave / shutdown: RunDirector pays leavers from beforeRelease)
	-- is about to write its final save, which includes this award. A second save here
	-- would hit Roblox's 1-write-per-6-s-per-key limit and queue the lock release.
	local s = sessions[player]
	if not (s and s.releasing) then
		task.spawn(DataService.save, player)
	end
	local out = DataService.awardSummary(result, summary)
	if type(out) == "table" and lifetime and lifetime.overtimeBest then
		out.overtimeBest = lifetime.overtimeBest -- iter 5 #6: a new best Overtime wave
	end
	return out
end

-- (iter 1) The awardRun breakdown (pure on its inputs; exposed for tests).
function DataService.awardSummary(result: any, summary: any): any
	local out: { [string]: any } = { passXp = if summary then summary.passXp or 0 else 0 }
	if result and (result.firstRunBonus or 0) > 0 then
		out.firstRunBonus = result.firstRunBonus
	end
	if result and result.firstExtractBonus then
		out.firstExtractBonus = {
			cheese = result.firstExtractBonus.cheese,
			golden = result.firstExtractBonus.goldenCheese,
		}
	end
	if summary and #(summary.completed or {}) > 0 then
		local c = { cheese = 0, passXp = 0, count = 0 }
		for _, id in summary.completed do
			local def = QuestConfig.get(id)
			if def then
				c.cheese += def.cheese
				c.passXp += def.passXp
				c.count += 1
			end
		end
		out.contracts = c
	end
	if summary and #(summary.achievements or {}) > 0 then
		local a = { cheese = 0, golden = 0 }
		for _, id in summary.achievements do
			local def = AchievementConfig.get(id)
			if def then
				a.cheese += def.reward.cheese or 0
				a.golden += def.reward.goldenCheese or 0
			end
		end
		out.achievements = a
	end
	-- iteration 7 (team Systems): miniboss Crumb Dust (daily cap), Overtime tier 13-14 gems
	if summary and (summary.minibossDust or 0) > 0 then
		out.minibossDust = { dust = summary.minibossDust, kills = summary.minibossKills or 0 }
	end
	if summary and (summary.overtimeGems or 0) > 0 then
		out.overtimeGems = summary.overtimeGems
	end
	return out
end

-- Lifecycle ------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	if sessions[player] or shuttingDown or not isRealPlayer(player) then
		return
	end
	local s = newSession(player)
	sessions[player] = s
	loadSession(s)
	if s.corrupt then
		-- PlayerRemoving -> releaseSession hands the lock back without writing data.
		if player.Parent == Players then
			player:Kick(CORRUPT_KICK)
		else
			task.spawn(releaseSession, s)
		end
		return
	end
	if s.loaded and s.profile then
		if player.Parent ~= Players then
			task.spawn(releaseSession, s)
			return
		end
		for _, fn in loadedCallbacks do
			task.spawn(fn, player, s.profile :: Profile)
		end
		DataService.syncProgress(player) -- (v6) day / week / season rollover
		DataService.v5Welcome(player) -- (v5) stomp seed toast, free class unlocks
		DataService.push(player)
		DataService.pushProgress(player)
	end
end

local function onPlayerRemoving(player: Player)
	lastProgressPush[player] = nil
	progressPushQueued[player] = nil
	lastSyncDay[player] = nil
	local s = sessions[player]
	if s then
		releaseSession(s)
	end
end

-- Another server wants a profile whose lock this server holds (handshake).
local function onReleaseRequest(message: any)
	local data = type(message) == "table" and message.Data or nil
	if type(data) ~= "table" or data.jobId ~= game.JobId or type(data.userId) ~= "number" then
		return
	end
	local userId = data.userId
	for player, s in sessions do
		if s.userId == userId then
			if player.Parent == Players then
				-- A user can only play on one server; this one is a stale ghost.
				player:Kick("You joined Trunkfall on another server.")
			else
				task.spawn(releaseSession, s)
			end
			return
		end
	end
	if not releasingUsers[userId] then
		task.spawn(clearOrphanLock, userId) -- our lock, but no session any more
	end
end

local function subscribeReleaseRequests()
	if useMemory then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(DataService.RELEASE_TOPIC, onReleaseRequest)
		end)
		if not ok then
			warn("[DataService] release handshake unavailable (stale-lock timeout only): " .. tostring(err))
		end
	end)
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
	if Net.S2C.Quests then
		questsRemote = Net.get(Net.S2C.Quests)
	end
	if Net.S2C.Pass then
		passRemote = Net.get(Net.S2C.Pass)
	end
	detectStore()
	subscribeReleaseRequests()

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

	-- (v6) UTC day rollover for players who stay online past midnight.
	task.spawn(function()
		while not shuttingDown do
			task.wait(DataService.ROLLOVER_CHECK_INTERVAL)
			local day = DataService.today()
			for player, s in sessions do
				if s.loaded and not s.releasing and lastSyncDay[player] ~= day then
					task.spawn(function()
						if DataService.syncProgress(player) then
							DataService.pushProgress(player)
						end
					end)
				end
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
