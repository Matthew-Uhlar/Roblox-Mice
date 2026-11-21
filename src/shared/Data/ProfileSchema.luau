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
--   5  (R3, GDD-v2 §5) per-class progression `classes = {[classId] = {xp, level, perks,
--      ability?, skin?}}` (Data/ClassProgress): every class the save already owns
--      starts at level 1. Also `ownedSkins = {[skinId] = true}` (paid class skins),
--      `respecTokens`, and PvP stats `stats.heroDowns`, `stats.lastHerd` (+ ranked).
--   6  (v4 plan, Team P) ADDITIVE ONLY: Herd Contracts `quests`, Herd Pass `pass`,
--      `achievements` (done markers), Mousepedia `collection`, `accountRewards`,
--      earned `titles`, `emotes`, Robux bundle `entitlements`, the Rookie Run flag
--      `firstExtractPaid`, `nameDye`, and stats `extractions`, `bestStage`,
--      `championKills` (+ ranked). Mastery Stars live in the class blocks
--      (classes[id].stars / starXp). `settings.busy` is never persisted.
--   7  (iterations 1 + 2, Team P; never live before) ADDITIVE ONLY from v6:
--      * stats.stomps + classes[id].stomps, seeded for veterans = floor(1.2 x lifetime
--        class XP) (Z-6), with a one-time toast (`stompSeedNotice`);
--      * Prestige replaces Mastery Stars: prestige = stars, pxp = starXp, prestigePaid =
--        stars (stars / starXp stay READ-ONLY for one release);
--      * the gentler class curve: each class level is recomputed UPWARD from its lifetime
--        XP (never lowered), with a one-time toast (`levelNotice`);
--      * `difficulty` ladder records from the Pressure record (Data/Ladder.fromPressure);
--      * `gems` (Cheese Gems + Crumb Dust), `challenges`, classes[id].look.
--      DataService keeps a one-time copy of the raw pre-v7 save (Z-17) before the first
--      v7 write. The v5 Herd Talent Board and Charms were cut before they shipped.
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
local ClassProgress = require("./ClassProgress")
local ClassSkins = require("../Config/ClassSkins")
local Quests = require("./Quests")
local HerdPass = require("./HerdPass")
local Achievements = require("./Achievements")
local AccountRewards = require("./AccountRewards")
local Evolution = require("./Evolution")
local Gems = require("./Gems")
local Ladder = require("./Ladder")
local Challenges = require("./Challenges")
local Ascension = require("./Ascension")
local LifetimeStats = require("./LifetimeStats") -- iter 5 #6 / #8 (team Lobby)

type Profile = Types.Profile

local ProfileSchema = {}

ProfileSchema.VERSION = 7
ProfileSchema.MAX_CURRENCY = Award.MAX_CURRENCY
ProfileSchema.MAX_TOKENS = 100_000
ProfileSchema.MAX_MAP_ENTRIES = 500
ProfileSchema.MAX_KEY_LEN = 64
ProfileSchema.MAX_SETTINGS = 32
-- Session-only settings keys that must never be saved (v4: "busy" = in the shop or
-- perk tree, LobbyService's SetBusy).
ProfileSchema.TRANSIENT_SETTINGS = { busy = true }

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
	local classes: { [string]: any } = {}
	for id in unlocked do
		classes[id] = ClassProgress.defaultState()
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
			heroDowns = 0, -- (v5)
			lastHerd = 0, -- (v5)
			extractions = 0, -- (v6) extractions incl. Last Herd
			bestStage = 0, -- (v6) most stages cleared in one match (QC-C B3)
			championKills = 0, -- (v6) Mouse Champions killed with squad credit
			stomps = 0, -- (v7) account stomps (Data/Evolution, leaderboard)
			-- (iter 5 #6 / #8, additive, Data/LifetimeStats) time played, damage dealt,
			-- best Overtime wave and full clears per ladder tier ({["tier"] = n})
			seconds = 0,
			damage = 0,
			overtimeBest = {},
			clears = {},
			ranked = {
				wins = 0,
				deepestCycle = 0,
				fastestCycle1 = nil,
				heroDowns = 0,
				lastHerd = 0,
				bestStage = 0,
				championKills = 0,
			},
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
		classes = classes, -- (v5) Data/ClassProgress, GDD-v2 §5
		ownedSkins = {}, -- (v5) paid class skins (Config/ClassSkins source = "paid")
		respecTokens = 0, -- (v5) Perk Respec Tokens (Robux convenience)
		quests = Quests.default(), -- (v6) Data/Quests (dealt on the first sync)
		pass = HerdPass.default(), -- (v6) Data/HerdPass
		achievements = {}, -- (v6) Data/Achievements done markers
		collection = {}, -- (v6) Mousepedia
		accountRewards = {}, -- (v6) claimed account level rewards
		titles = {}, -- (v6) earned titles (Config/Cosmetics.EARNED_TITLES)
		emotes = {}, -- (v6) Config/Cosmetics.EMOTES
		entitlements = {}, -- (v6) Robux bundle products bought (Config/Monetization)
		firstExtractPaid = false, -- (v6) Rookie Run first-extraction bonus paid
		nameDye = nil, -- (v6) Config/Cosmetics.DYES id (repeatable cheese sink)
		gems = Gems.default(), -- (v7) Cheese Gems + Crumb Dust
		difficulty = Ladder.default(), -- (v7) ladder records
		challenges = {}, -- (v7) the 30 Challenges done
		levelNotice = nil, -- (v7) one-time toast: levels raised by the new curve
		stompSeedNotice = 0, -- (v7) one-time toast: stomps seeded from class XP
	}
	return p
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

-- Deep copy for raw saves: a table seen before (a cycle, or shared) and anything
-- deeper than 32 levels becomes nil, so garbage can't hang or overflow migrate().
local function safeCopy(v: any, seen: { [any]: boolean }, depth: number): any
	if type(v) ~= "table" then
		return v
	end
	if seen[v] or depth > 32 then
		return nil
	end
	seen[v] = true
	local out = {}
	for k, x in v do
		out[k] = safeCopy(x, seen, depth + 1)
	end
	return out
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
		if type(k) == "string" and #k > 0 and #k <= 32 and not ProfileSchema.TRANSIENT_SETTINGS[k] then
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

-- Paid class skins the profile owns: only real "paid" skin ids survive.
local function paidSkinSet(v: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for k, x in tbl(v) do
		local def = if key(k) and x == true then ClassSkins.get(k) else nil
		if def and def.source == "paid" then
			out[k] = true
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
	-- (v6) earned titles and the one shown on the nametag
	local titles: { [string]: boolean } = {}
	for k, x in tbl(raw.titles) do
		if x == true and key(k) and Cosmetics.EARNED_TITLES[k] then
			titles[k] = true
		end
	end
	local anyP0: any = p
	anyP0.titles = titles
	if key(eq.title) and titles[eq.title] then
		(p.equipped :: any).title = eq.title
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
		heroDowns = num(st.heroDowns, 0, 0, MAXC),
		lastHerd = num(st.lastHerd, 0, 0, MAXC),
		ranked = {
			wins = num(rk.wins, 0, 0, MAXC),
			deepestCycle = num(rk.deepestCycle, 0, 0, 1e6),
			fastestCycle1 = optNum(rk.fastestCycle1, 0, 1e6),
			heroDowns = num(rk.heroDowns, 0, 0, MAXC),
			lastHerd = num(rk.lastHerd, 0, 0, MAXC),
		},
	}
	-- (v6) stats
	local sx: any = p.stats
	sx.extractions = num(st.extractions, 0, 0, MAXC)
	sx.bestStage = num(st.bestStage, 0, 0, 100)
	sx.championKills = num(st.championKills, 0, 0, MAXC)
	sx.stomps = num(st.stomps, 0, 0, 1e9) -- (v7)
	local rx: any = p.stats.ranked
	rx.bestStage = num(rk.bestStage, 0, 0, 100)
	rx.championKills = num(rk.championKills, 0, 0, MAXC)

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
	-- (v5) paid skins before classes (a chosen paid skin must still be owned).
	p.ownedSkins = paidSkinSet(raw.ownedSkins)
	p.classes = ClassProgress.sanitizeClasses(raw.classes, p.unlockedClasses, p.ownedSkins)
	p.respecTokens = num(raw.respecTokens, 0, 0, MAXT)
	-- After cosmetics/classes/skins: only grants the profile still holds survive.
	local anyP: any = p
	anyP.passGrants = Passes.sanitize(raw.passGrants, p)
	p.pressure = Pressure.sanitizeProfile(raw.pressure)
	p.discoveries = discoverySet(raw.discoveries)
	-- (v6)
	anyP.quests = Quests.sanitize(raw.quests)
	anyP.pass = HerdPass.sanitize(raw.pass)
	anyP.achievements = Achievements.sanitizeDone(raw.achievements)
	anyP.collection = Achievements.sanitizeCollection(raw.collection)
	anyP.accountRewards = AccountRewards.sanitize(raw.accountRewards)
	local emotes: { [string]: boolean } = {}
	for k, x in tbl(raw.emotes) do
		if x == true and key(k) and Cosmetics.EMOTES[k] then
			emotes[k] = true
		end
	end
	anyP.emotes = emotes
	local ent: { [string]: boolean } = {}
	for k, x in tbl(raw.entitlements) do
		local item = if key(k) then Monetization.get(k) else nil
		if x == true and item and item.kind == "product" then
			ent[k] = true
		end
	end
	anyP.entitlements = ent
	anyP.firstExtractPaid = raw.firstExtractPaid == true
	anyP.nameDye = if key(raw.nameDye) and Cosmetics.DYES[raw.nameDye] then raw.nameDye else nil
	-- (v7)
	anyP.gems = Gems.sanitize(raw.gems)
	anyP.difficulty = Ladder.sanitize(raw.difficulty)
	-- (iteration 3, T-8) the last chosen tier: an integer 0 (Custom) .. 11, never above
	-- the unlocked tier. Additive (an unset value means "default").
	local tier = p.settings.tier
	if tier ~= nil then
		if type(tier) ~= "number" or tier ~= math.floor(tier) or tier < 0 or tier > 11 then
			p.settings.tier = nil
		else
			p.settings.tier = math.min(tier, anyP.difficulty.unlocked)
		end
	end
	anyP.challenges = Challenges.sanitize(raw.challenges)
	anyP.stompSeedNotice = num(raw.stompSeedNotice, 0, 0, 1e9)
	local notice: { [string]: { number } }? = nil
	if type(raw.levelNotice) == "table" then
		for id, pair in raw.levelNotice do
			if ClassProgress.isClass(id) and type(pair) == "table" then
				local a, b = num(pair[1], 1, 1, 30), num(pair[2], 1, 1, 30)
				if b > a then
					notice = notice or {}
					(notice :: any)[id] = { a, b }
				end
			end
		end
	end
	anyP.levelNotice = notice
	-- (iter 5 #6 / #8, team Lobby) lifetime stats + Overtime record: additive fields
	-- in stats and classes[id].seconds (Data/LifetimeStats; after stats and classes)
	LifetimeStats.sanitize(p, raw)
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
	[4] = function(raw: { [any]: any })
		-- v4 -> v5: per-class progression (GDD-v2 §5). Every class the save already
		-- owns starts at class level 1 with no perks; new classes get a block when
		-- they are unlocked (Data/ClassProgress.ensure, reconcile).
		if type(raw.classes) ~= "table" then
			local classes = {}
			if type(raw.unlockedClasses) == "table" then
				for id, owned in raw.unlockedClasses do
					if owned == true and ClassProgress.isClass(id) then
						classes[id] = ClassProgress.defaultState()
					end
				end
			end
			raw.classes = classes
		end
		if type(raw.ownedSkins) ~= "table" then
			raw.ownedSkins = {}
		end
		if type(raw.respecTokens) ~= "number" then
			raw.respecTokens = 0
		end
		raw.version = 5
	end,
	[5] = function(raw: { [any]: any })
		-- v5 -> v6 (v4 plan): ADDITIVE ONLY. New blocks get defaults; nothing that
		-- exists is removed or renamed. Veterans who already extracted (any v5 win
		-- was an extraction) don't get the Rookie Run first-extraction bonus again.
		local st = if type(raw.stats) == "table" then raw.stats else nil
		local function n(v: any): number
			return if type(v) == "number" and v == v and v > 0 then v else 0
		end
		local oldWins = if st then n(st.wins) else 0
		local oldLastHerd = if st then n(st.lastHerd) else 0
		if st then
			if st.extractions == nil then
				st.extractions = oldWins -- v5 counted every extraction as a win
			end
			if st.bestStage == nil then
				-- unknown before v6: a recorded full-clear time proves 4 stages
				st.bestStage = if type(st.fastestCycle1) == "number" then 4 else 0
			end
			if st.championKills == nil then
				st.championKills = 0
			end
			local rk = st.ranked
			if type(rk) == "table" then
				if rk.bestStage == nil then
					rk.bestStage = if type(rk.fastestCycle1) == "number" then 4 else 0
				end
				if rk.championKills == nil then
					rk.championKills = 0
				end
			end
		end
		if raw.firstExtractPaid == nil then
			raw.firstExtractPaid = oldWins > 0 or oldLastHerd > 0
		end
		for _, field in { "achievements", "collection", "accountRewards", "titles", "emotes", "entitlements" } do
			if type(raw[field]) ~= "table" then
				raw[field] = {}
			end
		end
		if type(raw.quests) ~= "table" then
			raw.quests = Quests.default()
		end
		if type(raw.pass) ~= "table" then
			raw.pass = HerdPass.default()
		end
		if type(raw.settings) == "table" then
			raw.settings.busy = nil
		end
		raw.version = 6
	end,
	[6] = function(raw: { [any]: any })
		-- v6 -> v7: ADDITIVE ONLY. Nothing is taken away; values only go up.
		-- Z-6: there is no saved kill count, so seed stomps from lifetime class XP
		-- (on the v6 curve, before the levels are recomputed below).
		local seeded = Evolution.seed(raw)
		local st = if type(raw.stats) == "table" then raw.stats else nil
		if st and type(st.stomps) ~= "number" then
			st.stomps = seeded
		end
		if seeded > 0 and raw.stompSeedNotice == nil then
			raw.stompSeedNotice = seeded
		end
		-- Mastery Stars become Prestige; the new curve raises levels (never lowers them).
		if type(raw.classes) == "table" then
			local notice = {}
			for id, cs in raw.classes do
				if type(cs) == "table" then
					local stars = ClassProgress.stars(cs)
					if stars > 0 and cs.prestige == nil then
						cs.prestige = math.min(stars, ClassProgress.MAX_PRESTIGE)
						cs.prestigePaid = cs.prestige
					end
					if cs.pxp == nil and type(cs.starXp) == "number" and cs.starXp > 0 then
						cs.pxp = math.min(math.floor(cs.starXp), ClassProgress.PRESTIGE_XP - 1)
					end
					local level = if type(cs.level) == "number" and cs.level == cs.level
						then math.clamp(math.floor(cs.level), 1, ClassProgress.MAX_LEVEL)
						else 1
					local xp = if type(cs.xp) == "number"
							and cs.xp == cs.xp
							and cs.xp > 0
						then math.floor(cs.xp)
						else 0
					-- a v6 xp can't exceed its level's legacy cap (garbage never buys levels)
					xp = math.min(xp, math.max(0, ClassProgress.legacyXpToNext(level) - 1))
					local lifetime = ClassProgress.legacyTotalXpFor(level) + xp
					local newLevel, newXp, overflow = ClassProgress.levelForXp(lifetime, level)
					if newLevel > level then
						cs.level = newLevel
						cs.xp = newXp
						if overflow > 0 then
							cs.pxp = math.min(
								(if type(cs.pxp) == "number" then cs.pxp else 0) + overflow,
								ClassProgress.PRESTIGE_XP - 1
							)
						end
						notice[id] = { level, newLevel }
					elseif newLevel == level then
						-- same level: keep the XP inside it, within the new cap
						cs.xp = math.min(xp, math.max(0, ClassProgress.xpToNext(level) - 1))
					end
				end
			end
			if next(notice) ~= nil and raw.levelNotice == nil then
				raw.levelNotice = notice
			end
		end
		if type(raw.difficulty) ~= "table" then
			raw.difficulty = Ladder.fromPressure(raw.pressure)
		end
		if type(raw.gems) ~= "table" then
			raw.gems = Gems.default()
		end
		if type(raw.challenges) ~= "table" then
			raw.challenges = {}
		end
		raw.version = 7
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
	-- Work on a DEEP copy so the caller's table (nested blocks included) is never
	-- half-migrated or changed by a step (v6: steps write into stats / settings).
	local work: { [any]: any } = safeCopy(raw, {}, 0)
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

export type ViewCtx = {
	today: number?, -- UTC day number, for dailyClaimable
	now: number?, -- unix seconds, for boost timers
}

-- Rookie Run (v4 plan): a player's runs 0..ROOKIE_RUNS-1 are rookie runs.
ProfileSchema.ROOKIE_RUNS = 3

-- (iteration 2) The Early Horn setting: settings.skipWaveAt in {0 (Off), 50, 70, 90}
-- (% of the wave stomped). Unset: Off for runs 0-2, then 70.
ProfileSchema.SKIP_WAVE_VALUES = { 0, 50, 70, 90 }
function ProfileSchema.skipWaveAt(profile: Profile): number
	local v = profile.settings.skipWaveAt
	if type(v) == "number" and table.find(ProfileSchema.SKIP_WAVE_VALUES, v) then
		return v
	end
	return if profile.stats.runs < ProfileSchema.ROOKIE_RUNS then 0 else 70
end

-- (iteration 3, T-8) The tier to preselect for this player on any server and on Play
-- Again: the saved settings.tier (0 = Custom), clamped to the unlocked tier; otherwise
-- rookies (runs 0-2) get Mild and veterans their highest cleared tier (at least Medium).
function ProfileSchema.lastTier(profile: Profile): number
	local d = (profile :: any).difficulty
	local unlocked = if type(d) == "table" and type(d.unlocked) == "number" then d.unlocked else 2
	local t = profile.settings.tier
	if type(t) == "number" and t == math.floor(t) and t >= 0 and t <= 11 then
		return math.min(t, unlocked)
	end
	if profile.stats.runs < ProfileSchema.ROOKIE_RUNS then
		return 1
	end
	local cleared = if type(d) == "table" and type(d.cleared) == "number" then d.cleared else 0
	return math.clamp(math.max(cleared, 2), 1, unlocked)
end

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
		classes = ClassProgress.view(profile), -- (v5) per class: level, xp, perks, ability, skin, mastery...
		ownedSkins = copy((profile :: any).ownedSkins or {}), -- (v5) paid class skins
		respecTokens = (profile :: any).respecTokens or 0, -- (v5)
		-- (v6) v4 progression (docs/MONETIZATION.md "Profile view")
		titles = copy((profile :: any).titles or {}),
		emotes = copy((profile :: any).emotes or {}),
		entitlements = copy((profile :: any).entitlements or {}),
		nameDye = (profile :: any).nameDye,
		accountRewards = AccountRewards.view(profile),
		accountRewardsClaimable = AccountRewards.claimable(profile),
		book = Achievements.view(profile),
		stomps = Evolution.view(profile), -- (v7) {total, classes = {[id] = n}, freeUnlocks}
		gems = Gems.view(profile), -- (v7)
		difficulty = Ladder.view(profile), -- (v7)
		ladder = nil, -- (v7) the same table as `difficulty` (U's name), set below
		challenges = Challenges.view(profile), -- (v7)
		skipWaveAt = ProfileSchema.skipWaveAt(profile), -- (v7) effective Early Horn setting
		lastTier = ProfileSchema.lastTier(profile), -- (iteration 3, T-8) "Last played" tier
		rookie = {
			runs = profile.stats.runs,
			isRookie = profile.stats.runs < ProfileSchema.ROOKIE_RUNS,
			firstExtractPaid = (profile :: any).firstExtractPaid == true,
		},
	}
	v.ladder = v.difficulty
	-- (iter 5 #8, team Lobby) the lifetime stats card + per-class seconds played
	v.lifetime = LifetimeStats.view(profile)
	for id, secs in v.lifetime.classSeconds do
		if type(v.classes) == "table" and type(v.classes[id]) == "table" then
			v.classes[id].seconds = secs
		end
	end
	-- (iteration 2) Ascension per class: {nodes, bits, looks, look, next}
	local cls = (profile :: any).classes
	if type(cls) == "table" then
		for id, cv in v.classes do
			cv.ascension = Ascension.view(cls[id])
		end
	end
	if c.today then
		v.daily.claimable = profile.daily.lastClaimDay ~= c.today
	end
	if c.now then
		v.boosts.rushSecondsLeft = math.max(0, profile.boosts.cheese2xUntil - c.now)
	end
	return v
end

return ProfileSchema
