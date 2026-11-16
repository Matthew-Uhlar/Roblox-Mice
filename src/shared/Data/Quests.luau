--!strict
-- (v6) Herd Contracts state and rules (Team P). Pure: the caller passes the UTC day
-- number and the userId (the daily pick is deterministic per player and day, so a
-- rejoin or another server shows the same contracts). Content: Config/Quests.
--
-- profile.quests = {
--   day: number,  week: number,                         the period the lists belong to
--   daily:  { {id, p, c, seen?} x3 },                   p = progress, c = claimed
--   weekly: { {id, p, c, seen?} ... },                  seen = classes for "distinct" contracts
--   rerolls: number,                                    rerolls used today (first is free)
-- }
-- Rollover (sync): a new UTC day (or Monday for weeklies) first auto-grants every
-- COMPLETED but unclaimed contract of the old period (finished work is never lost),
-- then deals new contracts.

local Types = require("../Types")
local Q = require("../Config/Quests")
local Rng = require("../Util/Rng")
local Grant = require("./Grant")

type Profile = Types.Profile

export type QuestState = { id: string, p: number, c: boolean, seen: { [string]: boolean }? }
export type QuestsState = {
	day: number,
	week: number,
	daily: { QuestState },
	weekly: { QuestState },
	rerolls: number,
}

local Quests = {}

Quests.TIERS = { "Easy", "Medium", "Hard" }
Quests.MAX_SEEN = 16

local function fresh(id: string): QuestState
	return { id = id, p = 0, c = false }
end

-- Deterministic seed per player and day.
local function seed(day: number, userId: number, salt: number): number
	return (math.floor(day) * 7919 + math.floor(userId) * 31 + salt * 104729) % 4294967296
end

-- The 3 daily contract ids for (day, userId): one per tier.
function Quests.dealDaily(day: number, userId: number): { string }
	local rng = Rng.new(seed(day, userId, 1))
	local out = {}
	for _, tier in Quests.TIERS do
		local pool = Q.dailyPool(tier :: any)
		table.insert(out, rng:pick(pool).id)
	end
	return out
end

function Quests.default(day: number?, userId: number?): QuestsState
	local d = day or 0
	local st: QuestsState = { day = d, week = Q.weekFor(d), daily = {}, weekly = {}, rerolls = 0 }
	if d > 0 then
		for _, id in Quests.dealDaily(d, userId or 0) do
			table.insert(st.daily, fresh(id))
		end
		for _, def in Q.WEEKLY do
			table.insert(st.weekly, fresh(def.id))
		end
	end
	return st
end

local function sanitizeList(raw: any, valid: (QuestStateDef: any) -> boolean, max: number): { QuestState }
	local out: { QuestState } = {}
	if type(raw) ~= "table" then
		return out
	end
	local used: { [string]: boolean } = {}
	for _, q in raw do
		if #out >= max then
			break
		end
		if type(q) == "table" then
			local def = Q.get(q.id)
			if def and valid(def) and not used[def.id] then
				used[def.id] = true
				local p = if type(q.p) == "number" and q.p == q.p
					then math.clamp(math.floor(q.p), 0, 1e9)
					else 0
				local st: QuestState = { id = def.id, p = p, c = q.c == true }
				if def.mode == "distinct" and type(q.seen) == "table" then
					local seen = {}
					local n = 0
					for k, x in q.seen do
						if type(k) == "string" and #k <= 64 and x == true and n < Quests.MAX_SEEN then
							seen[k] = true
							n += 1
						end
					end
					st.seen = seen
					st.p = n
				end
				table.insert(out, st)
			end
		end
	end
	return out
end

-- Repairs a saved block (never throws).
function Quests.sanitize(raw: any): QuestsState
	local r: { [any]: any } = if type(raw) == "table" then raw else {}
	local function int(v: any, hi: number): number
		return if type(v) == "number" and v == v then math.clamp(math.floor(v), 0, hi) else 0
	end
	return {
		day = int(r.day, 1e7),
		week = int(r.week, 1e7),
		daily = sanitizeList(r.daily, function(def)
			return def.tier ~= "Weekly"
		end, Q.DAILY_COUNT),
		weekly = sanitizeList(r.weekly, function(def)
			return def.tier == "Weekly"
		end, #Q.WEEKLY),
		rerolls = int(r.rerolls, 1000),
	}
end

function Quests.state(profile: Profile): QuestsState
	local p = profile :: any
	if type(p.quests) ~= "table" or type(p.quests.daily) ~= "table" or type(p.quests.weekly) ~= "table" then
		p.quests = Quests.sanitize(p.quests)
	end
	return p.quests
end

local function done(q: QuestState): boolean
	local def = Q.get(q.id)
	return def ~= nil and q.p >= def.target
end
Quests.isDone = done

local function reward(
	profile: Profile,
	q: QuestState,
	addPassXp: ((Profile, number) -> ())?,
	out: { [string]: any }
)
	local def = Q.get(q.id) :: Q.QuestDef
	q.c = true
	Grant.apply(profile, { cheese = def.cheese, passXp = def.passXp }, addPassXp, out)
end

-- Auto-claims completed contracts in a list (rollover). Returns how many.
local function claimFinished(
	profile: Profile,
	list: { QuestState },
	addPassXp: ((Profile, number) -> ())?,
	out: { [string]: any }
): number
	local n = 0
	for _, q in list do
		if not q.c and done(q) then
			reward(profile, q, addPassXp, out)
			n += 1
		end
	end
	return n
end

-- Brings the block to `day`. Returns (changed, autoGranted?) — autoGranted sums the
-- rewards of completed contracts from the old period that were never claimed.
function Quests.sync(
	profile: Profile,
	day: number,
	userId: number,
	addPassXp: ((Profile, number) -> ())?
): (boolean, { [string]: any }?)
	local st = Quests.state(profile)
	local d = math.floor(day)
	local week = Q.weekFor(d)
	local out: { [string]: any } = {}
	local changed = false
	if st.day ~= d then
		if st.day < d then
			claimFinished(profile, st.daily, addPassXp, out)
		end
		st.day = d
		st.rerolls = 0
		st.daily = {}
		for _, id in Quests.dealDaily(d, userId) do
			table.insert(st.daily, fresh(id))
		end
		changed = true
	end
	if st.week ~= week or #st.weekly == 0 then
		if st.week < week then
			claimFinished(profile, st.weekly, addPassXp, out)
		end
		st.week = week
		st.weekly = {}
		for _, def in Q.WEEKLY do
			table.insert(st.weekly, fresh(def.id))
		end
		changed = true
	end
	return changed, if next(out) ~= nil then out else nil
end

-- Adds progress of `kind`. `n` is the amount (for "max" contracts the value of this
-- match; for "distinct" contracts `key` names the thing counted, e.g. a classId).
-- Returns the ids of contracts that became complete with this event.
function Quests.progress(profile: Profile, kind: string, n: number?, key: string?): { string }
	local completed = {}
	if type(kind) ~= "string" then
		return completed
	end
	local amount = if type(n) == "number"
			and n == n
			and n > 0
		then math.min(math.floor(n), Q.MAX_EVENT)
		else 0
	local st = Quests.state(profile)
	for _, list in { st.daily, st.weekly } do
		for _, q in list do
			local def = Q.get(q.id)
			if def and def.kind == kind and not q.c then
				local was = q.p >= def.target
				local mode = def.mode or "sum"
				if mode == "sum" and amount > 0 then
					q.p = math.min(def.target, q.p + amount)
				elseif mode == "max" and amount > q.p then
					q.p = math.min(def.target, amount)
				elseif mode == "distinct" and type(key) == "string" and #key <= 64 then
					local seen = q.seen or {}
					q.seen = seen
					if not seen[key] then
						local count = 0
						for _ in seen do
							count += 1
						end
						if count < Quests.MAX_SEEN then
							seen[key] = true
							q.p = math.min(def.target, count + 1)
						end
					end
				end
				if not was and q.p >= def.target then
					table.insert(completed, def.id)
				end
			end
		end
	end
	return completed
end

local function find(st: QuestsState, id: any): (QuestState?, boolean)
	for _, q in st.daily do
		if q.id == id then
			return q, false
		end
	end
	for _, q in st.weekly do
		if q.id == id then
			return q, true
		end
	end
	return nil, false
end

-- Claims a finished contract. Reasons: "unknown" | "claimed" | "not_done"
function Quests.claim(profile: Profile, id: any, addPassXp: ((Profile, number) -> ())?): (boolean, any)
	local st = Quests.state(profile)
	local q = find(st, id)
	if not q then
		return false, "unknown"
	end
	if q.c then
		return false, "claimed"
	end
	if not done(q) then
		return false, "not_done"
	end
	local out: { [string]: any } = {}
	reward(profile, q, addPassXp, out)
	return true, out
end

-- Cheese price of the next reroll today (0 = free), or nil when none are left.
function Quests.rerollCost(profile: Profile): number?
	local st = Quests.state(profile)
	if st.rerolls < Q.FREE_REROLLS_PER_DAY then
		return 0
	end
	if st.rerolls >= Q.FREE_REROLLS_PER_DAY + Q.MAX_EXTRA_REROLLS_PER_DAY then
		return nil
	end
	return Q.EXTRA_REROLL_CHEESE
end

-- Replaces an unclaimed daily contract with another one of the same tier that isn't
-- already dealt (deterministic). The first reroll each day is free; the next ones
-- cost cheese. Reasons: "unknown" | "weekly" | "claimed" | "no_rerolls" |
-- "insufficient_funds" | "no_alternative"
function Quests.reroll(profile: Profile, id: any, userId: number): (boolean, any)
	local st = Quests.state(profile)
	local q, weekly = find(st, id)
	if not q then
		return false, "unknown"
	end
	if weekly then
		return false, "weekly"
	end
	if q.c then
		return false, "claimed"
	end
	local cost = Quests.rerollCost(profile)
	if cost == nil then
		return false, "no_rerolls"
	end
	if profile.cheese < cost then
		return false, "insufficient_funds"
	end
	local def = Q.get(q.id) :: Q.QuestDef
	local taken: { [string]: boolean } = {}
	for _, other in st.daily do
		taken[other.id] = true
	end
	local options = {}
	for _, cand in Q.dailyPool(def.tier) do
		if not taken[cand.id] then
			table.insert(options, cand)
		end
	end
	if #options == 0 then
		return false, "no_alternative"
	end
	local rng = Rng.new(seed(st.day, userId, 100 + st.rerolls))
	local pick = rng:pick(options)
	profile.cheese -= cost
	st.rerolls += 1
	q.id = pick.id
	q.p = 0
	q.c = false
	q.seen = nil
	return true, { id = pick.id, cost = cost }
end

-- Unclaimed finished contracts (for the UI dot).
function Quests.claimable(profile: Profile): number
	local st = Quests.state(profile)
	local n = 0
	for _, list in { st.daily, st.weekly } do
		for _, q in list do
			if not q.c and done(q) then
				n += 1
			end
		end
	end
	return n
end

local function entry(q: QuestState): { [string]: any }
	local def = Q.get(q.id) :: Q.QuestDef
	return {
		id = def.id,
		text = Q.describe(def),
		tier = def.tier,
		progress = math.min(q.p, def.target),
		target = def.target,
		passXp = def.passXp,
		cheese = def.cheese,
		claimed = q.c,
		done = q.p >= def.target,
	}
end

-- Net.S2C.Quests payload (docs/MONETIZATION.md "Herd Contracts view").
-- `now` = unix seconds, for the reset countdowns (shown as plain "resets in" text).
function Quests.view(profile: Profile, now: number): { [string]: any }
	local st = Quests.state(profile)
	local daily, weekly = {}, {}
	for _, q in st.daily do
		if Q.get(q.id) then
			table.insert(daily, entry(q))
		end
	end
	for _, q in st.weekly do
		if Q.get(q.id) then
			table.insert(weekly, entry(q))
		end
	end
	local dayEnd = (st.day + 1) * 86400
	-- weeks start Monday: week w covers days 7w - 3 .. 7w + 3
	local weekEnd = (st.week * 7 + 4) * 86400
	local cost = Quests.rerollCost(profile)
	return {
		day = st.day,
		week = st.week,
		daily = daily,
		weekly = weekly,
		rerollCost = cost, -- 0 = free, nil = none left today
		freeRerollLeft = cost == 0,
		dailyResetsIn = math.max(0, dayEnd - math.floor(now)),
		weeklyResetsIn = math.max(0, weekEnd - math.floor(now)),
		claimable = Quests.claimable(profile),
	}
end

return Quests
