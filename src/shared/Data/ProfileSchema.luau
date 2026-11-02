--!strict
-- Profile defaults, migrations and the client-safe view (Team D). Pure.
--
-- Versions:
--   1  Lead's original Profile type (no goldenCheese, club, ads, ranked stats...).
--   2  Team D additions (see the Profile block in Types.luau).
--   3  `passGrants`: the source of every game-pass grant, so a refunded pass can be
--      revoked (Data/Passes). Not in Types.Profile yet; read it via Passes.grants().
--   4  `pressure = {unlocked, highestCleared, board}` (GDD §3.7, Run/Pressure) and
--      `discoveries = {[poiId] = true}` (rare POIs, GDD §3.8). Saves from before v4
--      unlock Pressure if they already have a win; others unlock on the next Go Home win.
-- migrate() runs MIGRATIONS[n] (n -> n+1) in order, then `reconcile` repairs every
-- field: wrong types, NaN/inf, negative currencies and oversized maps fall back to
-- defaults, so a corrupted save can never crash a server.
--
-- migrate() never throws. If a migration step or `reconcile` throws on a NON-EMPTY
-- save, it returns a default profile with `info.failed = true`. That profile must
-- never be saved over the real data: DataService opens such a session read-only and
-- asks the player to rejoin (ProfileSchema.sessionMode says which mode to use).

local Types = require("../Types")
local Shop = require("../Config/Shop")
local Talents = require("../Config/Talents")
local Cosmetics = require("../Config/Cosmetics")
local Monetization = require("../Config/Monetization")
local Award = require("./Award")
local Passes = require("./Passes")
local Pressure = require("../Run/Pressure")

type Profile = Types.Profile

local ProfileSchema = {}

ProfileSchema.VERSION = 4
ProfileSchema.MAX_CURRENCY = Award.MAX_CURRENCY
ProfileSchema.MAX_TOKENS = 100_000
ProfileSchema.MAX_MAP_ENTRIES = 500
ProfileSchema.MAX_KEY_LEN = 64
ProfileSchema.MAX_SETTINGS = 32

local FALLBACK_FREE_CLASSES = { "elephante", "ele_fonte", "ellie_fawn" }
local FALLBACK_DEFAULT_CLASS = "elephante"

local function freeClasses(): { string }
	local ids = Shop.freeClassIds()
	if #ids == 0 then
		return FALLBACK_FREE_CLASSES
	end
	return ids
end

local function defaultClass(): string
	local Classes = Shop.classes()
	if Classes and type(Classes.DEFAULT_ID) == "string" then
		return Classes.DEFAULT_ID
	end
	return FALLBACK_DEFAULT_CLASS
end

function ProfileSchema.default(): Profile
	local unlocked: { [string]: boolean } = {}
	for _, id in freeClasses() do
		unlocked[id] = true
	end
	local p: any = {
		version = ProfileSchema.VERSION,
		cheese = 0,
		goldenCheese = 0,
		xp = 0,
		level = 1,
		unlockedClasses = unlocked,
		selectedClass = defaultClass(),
		talents = {},
		cosmetics = {},
		equipped = {},
		secondWindTokens = 0,
		rerollTokens = 0,
		daily = { lastClaimDay = 0, streak = 0 },
		stats = {
			runs = 0,
			wins = 0,
			deepestCycle = 0,
			bossesKilled = 0,
			fastestCycle1 = nil,
			ranked = { wins = 0, deepestCycle = 0, fastestCycle1 = nil },
		},
		purchaseHistory = {},
		purchaseOrder = {},
		boosts = { cheese2xUntil = 0, feastPending = 0 },
		club = { lastDailyDay = 0, monthsGranted = {} },
		ads = { day = 0, count = 0 },
		lastRun = { cheese = 0, adClaimed = true },
		firstRunDay = 0,
		settings = {},
		passGrants = {}, -- (v3) Data/Passes
		pressure = Pressure.defaultProfile(), -- (v4) GDD §3.7
		discoveries = {}, -- (v4) rare POIs, GDD §3.8
	}
	return p
end

-- Sanitizers ----------------------------------------------------------------

local function num(v: any, default: number, lo: number, hi: number): number
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return default
	end
	return math.clamp(math.floor(v), lo, hi)
end

local function optNum(v: any, lo: number, hi: number): number?
	if type(v) ~= "number" or v ~= v or v <= lo or v >= hi then
		return nil
	end
	return v
end

local function key(v: any): boolean
	return type(v) == "string" and #v > 0 and #v <= ProfileSchema.MAX_KEY_LEN
end

local function str(v: any, default: string): string
	if key(v) then
		return v
	end
	return default
end

local function tbl(v: any): { [any]: any }
	if type(v) == "table" then
		return v
	end
	return {}
end

local function boolSet(v: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	local n = 0
	for k, x in tbl(v) do
		if key(k) and x == true then
			n += 1
			if n > ProfileSchema.MAX_MAP_ENTRIES then
				break
			end
			out[k] = true
		end
	end
	return out
end

local function talentMap(v: any): { [string]: number }
	local out: { [string]: number } = {}
	local n = 0
	for k, x in tbl(v) do
		if key(k) and type(x) == "number" and x == x then
			local def = Talents.get(k)
			local hi = if def then def.maxLevel else 100
			local lvl = math.clamp(math.floor(x), 0, hi)
			if lvl > 0 then
				n += 1
				if n > ProfileSchema.MAX_MAP_ENTRIES then
					break
				end
				out[k] = lvl
			end
		end
	end
	return out
end

local function settingsMap(v: any): { [string]: any }
	local out: { [string]: any } = {}
	local n = 0
	for k, x in tbl(v) do
		if type(k) == "string" and #k > 0 and #k <= 32 then
			local t = type(x)
			local okValue = t == "boolean"
				or (t == "number" and x == x and math.abs(x) < 1e9)
				or (t == "string" and #x <= 64)
			if okValue then
				n += 1
				if n > ProfileSchema.MAX_SETTINGS then
					break
				end
				out[k] = x
			end
		end
	end
	return out
end

-- discoveries[poiId] = true. Tolerates a positive number per id too (e.g. a
-- discovery day) so a later format change can never wipe the set.
local function discoverySet(v: any): { [string]: boolean }
	local out: { [string]: any } = {}
	local n = 0
	for k, x in tbl(v) do
		local okValue = x == true or (type(x) == "number" and x == x and x > 0 and x < 1e12)
		if key(k) and okValue then
			n += 1
			if n > ProfileSchema.MAX_MAP_ENTRIES then
				break
			end
			out[k] = x
		end
	end
	return out
end

-- Rebuilds a consistent purchase history: order lists every id once, map == order.
local function purchases(rawMap: any, rawOrder: any): ({ [string]: boolean }, { string })
	local map: { [string]: boolean } = {}
	local order: { string } = {}
	for _, id in tbl(rawOrder) do
		if key(id) and not map[id] then
			map[id] = true
			table.insert(order, id)
		end
	end
	-- v1 profiles only had the map: append those ids (their order is unknown).
	local extra: { string } = {}
	for id, x in tbl(rawMap) do
		if key(id) and x == true and not map[id] then
			table.insert(extra, id)
		end
	end
	table.sort(extra)
	for _, id in extra do
		map[id] = true
		table.insert(order, id)
	end
	-- Keep the newest `max` ids. One pass (a loop of table.remove(order, 1) is
	-- quadratic and stalls the load of a huge saved history).
	local max = Monetization.RULES.purchaseHistoryMax
	local extraCount = #order - max
	if extraCount > 0 then
		for i = 1, extraCount do
			map[order[i]] = nil
		end
		order = table.move(order, extraCount + 1, #order, 1, {})
	end
	return map, order
end

function ProfileSchema.reconcile(raw: { [any]: any }): Profile
	local d = ProfileSchema.default()
	local MAXC = ProfileSchema.MAX_CURRENCY
	local MAXT = ProfileSchema.MAX_TOKENS

	local p = d
	p.cheese = num(raw.cheese, 0, 0, MAXC)
	p.goldenCheese = num(raw.goldenCheese, 0, 0, MAXC)
	p.level = num(raw.level, 1, 1, Award.MAX_LEVEL)
	p.xp = num(raw.xp, 0, 0, MAXC)

	local unlocked = boolSet(raw.unlockedClasses)
	for _, id in freeClasses() do
		unlocked[id] = true
	end
	p.unlockedClasses = unlocked
	local sel = str(raw.selectedClass, d.selectedClass)
	p.selectedClass = if unlocked[sel] then sel else d.selectedClass

	p.talents = talentMap(raw.talents)
	p.cosmetics = boolSet(raw.cosmetics)

	local eq = tbl(raw.equipped)
	p.equipped = {}
	for _, slot in Cosmetics.SLOTS do
		local id = eq[slot]
		local def = if key(id) then Cosmetics.get(id) else nil
		if def and def.slot == slot and p.cosmetics[id] then
			(p.equipped :: any)[slot] = id
		end
	end

	p.secondWindTokens = num(raw.secondWindTokens, 0, 0, MAXT)
	p.rerollTokens = num(raw.rerollTokens, 0, 0, MAXT)

	local daily = tbl(raw.daily)
	p.daily = {
		lastClaimDay = num(daily.lastClaimDay, 0, 0, 1e7),
		streak = num(daily.streak, 0, 0, 1e7),
	}

	local st = tbl(raw.stats)
	local rk = tbl(st.ranked)
	p.stats = {
		runs = num(st.runs, 0, 0, MAXC),
		wins = num(st.wins, 0, 0, MAXC),
		deepestCycle = num(st.deepestCycle, 0, 0, 1e6),
		bossesKilled = num(st.bossesKilled, 0, 0, MAXC),
		fastestCycle1 = optNum(st.fastestCycle1, 0, 1e6),
		ranked = {
			wins = num(rk.wins, 0, 0, MAXC),
			deepestCycle = num(rk.deepestCycle, 0, 0, 1e6),
			fastestCycle1 = optNum(rk.fastestCycle1, 0, 1e6),
		},
	}

	p.purchaseHistory, p.purchaseOrder = purchases(raw.purchaseHistory, raw.purchaseOrder)

	local boosts = tbl(raw.boosts)
	p.boosts = {
		cheese2xUntil = num(boosts.cheese2xUntil, 0, 0, 1e11),
		feastPending = num(boosts.feastPending, 0, 0, 1000),
	}

	local club = tbl(raw.club)
	p.club = {
		lastDailyDay = num(club.lastDailyDay, 0, 0, 1e7),
		monthsGranted = boolSet(club.monthsGranted),
	}

	local ads = tbl(raw.ads)
	p.ads = { day = num(ads.day, 0, 0, 1e7), count = num(ads.count, 0, 0, 1000) }

	local lr = tbl(raw.lastRun)
	p.lastRun = {
		cheese = num(lr.cheese, 0, 0, MAXC),
		adClaimed = if type(lr.adClaimed) == "boolean" then lr.adClaimed else true,
	}
	p.firstRunDay = num(raw.firstRunDay, 0, 0, 1e7)
	p.settings = settingsMap(raw.settings)
	-- After cosmetics/classes: only grants the profile still holds survive.
	local anyP: any = p
	anyP.passGrants = Passes.sanitize(raw.passGrants, p)
	p.pressure = Pressure.sanitizeProfile(raw.pressure)
	p.discoveries = discoverySet(raw.discoveries)
	p.version = ProfileSchema.VERSION
	return p
end

-- MIGRATIONS[n] turns a version-n table into version n+1, in place. Keep each step
-- pure and never delete a past step: old saves can come back after months.
ProfileSchema.MIGRATIONS = {
	[1] = function(raw: { [any]: any })
		-- v1 -> v2: new currencies and bookkeeping. Before v2 nobody could buy a
		-- Second Wind token, so every v1 run counts as ranked.
		raw.goldenCheese = raw.goldenCheese or 0
		local st = type(raw.stats) == "table" and raw.stats or {}
		raw.stats = st
		st.ranked = {
			wins = st.wins,
			deepestCycle = st.deepestCycle,
			fastestCycle1 = st.fastestCycle1,
		}
		local boosts = type(raw.boosts) == "table" and raw.boosts or {}
		raw.boosts = boosts
		boosts.feastPending = 0
		raw.version = 2
	end,
	[2] = function(raw: { [any]: any })
		-- v2 -> v3: start tracking where pass perks came from. Pass cosmetics can only
		-- come from their pass, so record them; class unlocks stay untracked (they may
		-- have been bought with cheese) and are therefore never revoked.
		raw.passGrants = Passes.inferFromCosmetics(raw.cosmetics)
		raw.version = 3
	end,
	[3] = function(raw: { [any]: any })
		-- v3 -> v4: the Pressure board and rare-POI discoveries. Veterans who already
		-- won a run (Go Home) get the board unlocked; everyone else unlocks it on
		-- their first win (Data/Award).
		if type(raw.pressure) ~= "table" then
			raw.pressure = Pressure.defaultProfile()
			local st = raw.stats
			if type(st) == "table" and type(st.wins) == "number" and st.wins > 0 then
				raw.pressure.unlocked = true
			end
		end
		if type(raw.discoveries) ~= "table" then
			raw.discoveries = {}
		end
		raw.version = 4
	end,
} :: { [number]: (any) -> () }

export type MigrateInfo = {
	fromVersion: number,
	futureVersion: boolean, -- saved by a newer server: load read-only, never save over it
	fresh: boolean, -- no usable data, a new default profile was created
	failed: boolean, -- a migration step or reconcile THREW on a non-empty save: never save
	error: string?, -- the error, for logs
}

local function nonEmpty(raw: any): boolean
	return type(raw) == "table" and next(raw) ~= nil
end

-- Never throws. Accepts anything (nil, garbage, any past version).
function ProfileSchema.migrate(raw: any): (Profile, MigrateInfo)
	if type(raw) ~= "table" then
		return ProfileSchema.default(),
			{ fromVersion = 0, futureVersion = false, fresh = true, failed = false }
	end
	local version = raw.version
	if type(version) ~= "number" or version ~= version or version < 1 then
		version = 1
	end
	version = math.floor(version)
	local from = version
	if version > ProfileSchema.VERSION then
		local ok, p = pcall(ProfileSchema.reconcile, raw)
		return if ok then p else ProfileSchema.default(),
			{
				fromVersion = from,
				futureVersion = true,
				fresh = false,
				failed = not ok,
				error = if ok then nil else tostring(p),
			}
	end
	-- Work on a shallow copy so the caller's table is not half-migrated on error.
	local work: { [any]: any } = table.clone(raw)
	local okSteps, stepErr = pcall(function()
		while version < ProfileSchema.VERSION do
			local step = ProfileSchema.MIGRATIONS[version]
			if step then
				step(work)
			end
			version += 1
		end
	end)
	if not okSteps then
		-- A half-migrated save must not be reconciled as if it were current: that can
		-- silently drop data. Refuse it (read-only session) instead.
		return ProfileSchema.default(),
			{
				fromVersion = from,
				futureVersion = false,
				fresh = false,
				failed = true,
				error = "migration step: " .. tostring(stepErr),
			}
	end
	local ok2, p = pcall(ProfileSchema.reconcile, work)
	if not ok2 then
		local failed = nonEmpty(raw)
		return ProfileSchema.default(),
			{
				fromVersion = from,
				futureVersion = false,
				fresh = not failed,
				failed = failed,
				error = "reconcile: " .. tostring(p),
			}
	end
	return p, { fromVersion = from, futureVersion = false, fresh = false, failed = false }
end

export type SessionMode = "writable" | "readOnly" | "corrupt"

-- How DataService must open a loaded save:
--   "writable"  normal session (saves allowed)
--   "readOnly"  saved by a newer server version: play, but never write
--   "corrupt"   the save exists but could not be read: never write, ask the player
--               to rejoin (the stored data stays untouched for a fix/rollback)
-- A blank default profile for a non-empty save is always "corrupt", even if a
-- future code path forgets to set info.failed.
function ProfileSchema.sessionMode(raw: any, info: MigrateInfo): SessionMode
	if info.failed or (info.fresh and nonEmpty(raw)) then
		return "corrupt"
	end
	if info.futureVersion then
		return "readOnly"
	end
	return "writable"
end

local function copy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = copy(x)
	end
	return out
end
ProfileSchema.deepCopy = copy

export type ViewCtx = {
	today: number?, -- UTC day number, for dailyClaimable
	now: number?, -- unix seconds, for boost timers
}

-- Client-safe subset for Net.S2C.Profile. Never includes purchaseHistory/Order,
-- ad counters or club internals. MonetizationService adds pass/club/boost info.
function ProfileSchema.view(profile: Profile, ctx: ViewCtx?): { [string]: any }
	local c: ViewCtx = ctx or {}
	local v: { [string]: any } = {
		version = profile.version,
		cheese = profile.cheese,
		goldenCheese = profile.goldenCheese,
		level = profile.level,
		xp = profile.xp,
		xpToNext = Award.xpToNext(profile.level),
		unlockedClasses = copy(profile.unlockedClasses),
		selectedClass = profile.selectedClass,
		talents = copy(profile.talents),
		cosmetics = copy(profile.cosmetics),
		equipped = copy(profile.equipped),
		secondWindTokens = profile.secondWindTokens,
		rerollTokens = profile.rerollTokens,
		daily = { streak = profile.daily.streak, lastClaimDay = profile.daily.lastClaimDay },
		stats = copy(profile.stats),
		boosts = { cheese2xUntil = profile.boosts.cheese2xUntil },
		settings = copy(profile.settings),
		pressure = copy(profile.pressure), -- (v4) {unlocked, highestCleared, board}
		discoveries = copy(profile.discoveries), -- (v4)
	}
	if c.today then
		v.daily.claimable = profile.daily.lastClaimDay ~= c.today
	end
	if c.now then
		v.boosts.rushSecondsLeft = math.max(0, profile.boosts.cheese2xUntil - c.now)
	end
	return v
end

return ProfileSchema
