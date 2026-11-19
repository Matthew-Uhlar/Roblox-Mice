--!strict
-- (iteration 2) Difficulty ladder records (Team P). Pure. Content: Config/Difficulty.
--
-- profile.difficulty = {
--   unlocked: number,        highest tier this account may pick (starts at 2: Mild, Medium)
--   cleared: number,         highest tier fully cleared (0 = none)
--   bestSolo: number,        highest tier cleared as the only human in the server (ranked)
--   bestSoloTime: number,    fastest clear of bestSolo, seconds (0 = unknown)
--   bestSquad: number,       highest tier cleared (any squad)
--   perClass: {[classId] = {bestSolo, bestSquad}},
--   week: number, weekly: {[tier] = true},   first clear of each tier this UTC week
-- }

local Types = require("../Types")
local D = require("../Config/Difficulty")
local Q = require("../Config/Quests")
local ClassProgress = require("./ClassProgress")

type Profile = Types.Profile

export type State = {
	unlocked: number,
	cleared: number,
	bestSolo: number,
	bestSoloTime: number,
	bestSquad: number,
	perClass: { [string]: { bestSolo: number, bestSquad: number } },
	week: number,
	weekly: { [string]: boolean },
}

local Ladder = {}

function Ladder.default(): State
	return {
		unlocked = D.START_UNLOCKED,
		cleared = 0,
		bestSolo = 0,
		bestSoloTime = 0,
		bestSquad = 0,
		perClass = {},
		week = 0,
		weekly = {},
	}
end

local function int(v: any, lo: number, hi: number, default: number): number
	if type(v) ~= "number" or v ~= v or math.abs(v) == math.huge then
		return default
	end
	return math.clamp(math.floor(v), lo, hi)
end

function Ladder.sanitize(raw: any): State
	local r: { [any]: any } = if type(raw) == "table" then raw else {}
	local st = Ladder.default()
	st.cleared = int(r.cleared, 0, D.COUNT, 0)
	st.unlocked = math.max(
		int(r.unlocked, 1, D.COUNT, D.START_UNLOCKED),
		D.START_UNLOCKED,
		math.min(D.COUNT, st.cleared + 1)
	)
	st.bestSolo = int(r.bestSolo, 0, D.COUNT, 0)
	st.bestSoloTime = int(r.bestSoloTime, 0, 1e6, 0)
	st.bestSquad = math.max(int(r.bestSquad, 0, D.COUNT, 0), st.bestSolo)
	if type(r.perClass) == "table" then
		for id, c in r.perClass do
			if ClassProgress.isClass(id) and type(c) == "table" then
				st.perClass[id] = {
					bestSolo = int(c.bestSolo, 0, D.COUNT, 0),
					bestSquad = int(c.bestSquad, 0, D.COUNT, 0),
				}
			end
		end
	end
	st.week = int(r.week, 0, 1e7, 0)
	if type(r.weekly) == "table" then
		for k, x in r.weekly do
			local t = tonumber(k)
			if x == true and t and t >= 1 and t <= D.COUNT then
				st.weekly[tostring(math.floor(t))] = true
			end
		end
	end
	return st
end

function Ladder.state(profile: Profile): State
	local p = profile :: any
	if type(p.difficulty) ~= "table" or type(p.difficulty.perClass) ~= "table" then
		p.difficulty = Ladder.sanitize(p.difficulty)
	end
	return p.difficulty
end

-- v6 -> v7: the Pressure record becomes ladder records (records were full clears only).
function Ladder.fromPressure(pressure: any): State
	local st = Ladder.default()
	local pp = if type(pressure) == "table" then pressure else {}
	local hc = int(pp.highestCleared, 0, 21, 0)
	local cleared = 0
	if pp.unlocked == true then
		cleared = 2 -- anyone with Pressure unlocked gets at least Medium cleared
	end
	if hc > 0 then
		cleared = math.max(cleared, D.tierForPoints(hc))
	end
	st.cleared = cleared
	st.bestSquad = cleared
	st.unlocked = math.max(D.START_UNLOCKED, math.min(D.COUNT, cleared + 1))
	return st
end

export type MatchInfo = {
	tier: number?,
	clear: boolean?, -- full clear or Last Herd
	solo: boolean?, -- the only human in the server
	ranked: boolean?,
	classId: string?,
	clearSeconds: number?,
	extracted: boolean?,
	extractStage: number?,
	day: number,
}

export type Result = {
	unlocked: number?, -- a new tier unlocked
	bestSolo: number?, -- new best solo tier
	bestSquad: number?, -- new best squad tier
	weeklyGem: number?, -- first clear of this tier this week: a guaranteed gem at this tier
}

-- Records one match. Unlocking also counts an onboarding extraction (stage >= 3 on
-- tiers 1-3). Best Solo needs a ranked solo clear. Returns what changed.
function Ladder.record(profile: Profile, m: MatchInfo): Result
	local st = Ladder.state(profile)
	local out: Result = {}
	local tier = D.clamp(m.tier)
	local onboard = m.extracted == true
		and (m.extractStage or 0) >= D.ONBOARD_EXTRACT_STAGE
		and tier <= D.ONBOARD_MAX_TIER
	if m.clear or onboard then
		local next = math.min(D.COUNT, tier + 1)
		if next > st.unlocked then
			st.unlocked = next
			out.unlocked = next
		end
	end
	if not m.clear then
		return out
	end
	st.cleared = math.max(st.cleared, tier)
	if tier > st.bestSquad then
		st.bestSquad = tier
		out.bestSquad = tier
	end
	local secs = int(m.clearSeconds, 0, 1e6, 0)
	if m.solo and m.ranked ~= false then
		if tier > st.bestSolo then
			st.bestSolo = tier
			st.bestSoloTime = secs
			out.bestSolo = tier
		elseif tier == st.bestSolo and secs > 0 and (st.bestSoloTime == 0 or secs < st.bestSoloTime) then
			st.bestSoloTime = secs
		end
	end
	if type(m.classId) == "string" and ClassProgress.isClass(m.classId) then
		local c = st.perClass[m.classId] or { bestSolo = 0, bestSquad = 0 }
		st.perClass[m.classId] = c
		c.bestSquad = math.max(c.bestSquad, tier)
		if m.solo and m.ranked ~= false then
			c.bestSolo = math.max(c.bestSolo, tier)
		end
	end
	local week = Q.weekFor(math.floor(m.day))
	if week > st.week then
		st.week = week
		st.weekly = {}
	end
	if week == st.week and not st.weekly[tostring(tier)] then
		st.weekly[tostring(tier)] = true
		out.weeklyGem = D.get(tier).gemTier
	end
	return out
end

-- Best Solo leaderboard value: tier first, then the fastest time (lower is better).
function Ladder.bestSoloScore(profile: Profile): number
	local st = Ladder.state(profile)
	if st.bestSolo <= 0 then
		return 0
	end
	local t = if st.bestSoloTime > 0 then math.min(st.bestSoloTime, 99_999) else 99_999
	return st.bestSolo * 100_000 + (99_999 - t)
end

function Ladder.view(profile: Profile): { [string]: any }
	local st = Ladder.state(profile)
	local tiers = {}
	for _, def in D.TIERS do
		table.insert(tiers, {
			tier = def.tier,
			id = def.id,
			name = def.name,
			reward = def.reward,
			gemTier = def.gemTier,
			unlocked = def.tier <= st.unlocked,
			cleared = def.tier <= st.cleared,
		})
	end
	local perClass = {}
	for id, c in st.perClass do
		perClass[id] = { bestSolo = c.bestSolo, bestSquad = c.bestSquad }
	end
	return {
		unlocked = st.unlocked,
		cleared = st.cleared,
		bestSolo = st.bestSolo,
		bestSoloTime = st.bestSoloTime,
		bestSquad = st.bestSquad,
		perClass = perClass,
		tiers = tiers,
	}
end

return Ladder
