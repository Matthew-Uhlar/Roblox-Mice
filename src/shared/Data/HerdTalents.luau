--!strict
-- (v5) Herd Talent Board: ONE board per account (Team P). Pure: the caller passes the UTC
-- day. Content: Config/HerdTalents.
--
-- profile.herdTalents = {
--   points: number,               TP available
--   spent: number,                TP in ranks (for the respec refund)
--   ranks: {[talentId] = rank},
--   respecDay: number,            UTC day of the last free respec
--   firstDay: number,             UTC day of the last first-of-day bonus
--   week: number, bands: {[bandIndex] = true}   weekly full-clear bonuses taken this week
-- }

local Types = require("../Types")
local H = require("../Config/HerdTalents")
local Q = require("../Config/Quests")
local RunBonus = require("./RunBonus")

type Profile = Types.Profile

export type State = {
	points: number,
	spent: number,
	ranks: { [string]: number },
	respecDay: number,
	firstDay: number,
	week: number,
	bands: { [string]: boolean },
}

local HerdTalents = {}

HerdTalents.MAX_POINTS = 10_000_000

function HerdTalents.default(): State
	return { points = 0, spent = 0, ranks = {}, respecDay = 0, firstDay = 0, week = 0, bands = {} }
end

local function int(v: any, hi: number): number
	return if type(v) == "number"
			and v == v
			and math.abs(v) ~= math.huge
		then math.clamp(math.floor(v), 0, hi)
		else 0
end

-- Repairs a saved block. Ranks are clamped to each talent's max; `spent` is recomputed
-- from the ranks, so a corrupted value can never create points.
function HerdTalents.sanitize(raw: any): State
	local r: { [any]: any } = if type(raw) == "table" then raw else {}
	local st = HerdTalents.default()
	st.points = int(r.points, HerdTalents.MAX_POINTS)
	if type(r.ranks) == "table" then
		for id, rank in r.ranks do
			local def = H.get(id)
			local n = if def then int(rank, def.maxRank) else 0
			if def and n > 0 then
				st.ranks[def.id] = n
			end
		end
	end
	local spent = 0
	for _, rank in st.ranks do
		spent += H.totalCost(rank)
	end
	st.spent = spent
	st.respecDay = int(r.respecDay, 1e7)
	st.firstDay = int(r.firstDay, 1e7)
	st.week = int(r.week, 1e7)
	if type(r.bands) == "table" then
		for k, x in r.bands do
			local i = tonumber(k)
			if x == true and i and H.WEEKLY_BANDS[i] then
				st.bands[tostring(i)] = true
			end
		end
	end
	return st
end

function HerdTalents.state(profile: Profile): State
	local p = profile :: any
	if type(p.herdTalents) ~= "table" or type(p.herdTalents.ranks) ~= "table" then
		p.herdTalents = HerdTalents.sanitize(p.herdTalents)
	end
	return p.herdTalents
end

export type RunInfo = {
	bosses: number?,
	championKills: number?,
	stagesAlive: number?, -- stages cleared alive (defaults to stagesCleared)
	stagesCleared: number?,
	extracted: boolean?,
	win: boolean?,
	fullClear: boolean?,
	pressure: number?, -- the run's Pressure points
}

local function n(v: any): number
	return if type(v) == "number" and v == v and v > 0 and v < 1e6 then math.floor(v) else 0
end

-- TP for one match before the first-of-day and weekly bonuses.
function HerdTalents.runPoints(info: RunInfo): number
	local I = H.INCOME
	local alive = if info.stagesAlive ~= nil then n(info.stagesAlive) else n(info.stagesCleared)
	local base = I.boss * math.min(n(info.bosses), 8)
		+ I.champion * math.min(n(info.championKills), 30)
		+ I.stageAlive * math.min(alive, 8)
		+ (if info.extracted then I.extract else 0)
		+ (if info.win then I.win else 0)
	local pressure = math.min(n(info.pressure), 21)
	local outcome = if info.fullClear
		then I.outcomeFullClear
		elseif info.extracted then I.outcomeExtract
		else 1
	return math.floor(base * (1 + I.pressurePerPoint * pressure) * outcome + 0.5)
end

export type Award = { points: number, run: number, firstDay: number, weekly: number, band: number? }

-- Adds a match's TP: run points, the first-of-day bonus (double, up to +100) and the
-- weekly full-clear bonus of the run's Pressure band (once per band per week).
function HerdTalents.award(profile: Profile, info: RunInfo, day: number): Award
	local st = HerdTalents.state(profile)
	local run = HerdTalents.runPoints(info)
	local out: Award = { points = 0, run = run, firstDay = 0, weekly = 0 }
	local d = math.floor(day)
	if run > 0 and st.firstDay ~= d then
		st.firstDay = d
		out.firstDay = math.min(run, H.INCOME.firstOfDayBonusCap)
	end
	local week = Q.weekFor(d)
	if week > st.week then
		st.week = week
		st.bands = {}
	end
	if info.fullClear then
		local band = H.bandFor(n(info.pressure))
		if not st.bands[tostring(band)] and week >= st.week then
			st.bands[tostring(band)] = true
			out.weekly = H.WEEKLY_BANDS[band].tp
			out.band = band
		end
	end
	out.points = run + out.firstDay + out.weekly
	st.points = math.min(HerdTalents.MAX_POINTS, st.points + out.points)
	return out
end

-- Adds TP from another source (e.g. a future relic). Returns the new balance.
function HerdTalents.addPoints(profile: Profile, amount: number): number
	local st = HerdTalents.state(profile)
	st.points = math.min(HerdTalents.MAX_POINTS, st.points + n(amount))
	return st.points
end

-- Buys the next rank. Reasons: "unknown_talent" | "max_rank" | "no_points"
function HerdTalents.spend(profile: Profile, talentId: any): (boolean, any)
	local def = H.get(talentId)
	if not def then
		return false, "unknown_talent"
	end
	local st = HerdTalents.state(profile)
	local rank = st.ranks[def.id] or 0
	if rank >= def.maxRank then
		return false, "max_rank"
	end
	local cost = H.rankCost(rank + 1)
	if st.points < cost then
		return false, "no_points"
	end
	st.points -= cost
	st.spent += cost
	st.ranks[def.id] = rank + 1
	return true, { rank = rank + 1, cost = cost }
end

-- Resets every rank and refunds all spent TP. Free once per UTC day, otherwise
-- H.RESPEC_CHEESE cheese. Reasons: "nothing_to_reset" | "insufficient_funds"
function HerdTalents.respec(profile: Profile, day: number): (boolean, any)
	local st = HerdTalents.state(profile)
	if next(st.ranks) == nil then
		return false, "nothing_to_reset"
	end
	local d = math.floor(day)
	local cost = if st.respecDay ~= d then 0 else H.RESPEC_CHEESE
	if profile.cheese < cost then
		return false, "insufficient_funds"
	end
	profile.cheese -= cost
	if cost == 0 then
		st.respecDay = d
	end
	local refunded = st.spent
	st.points = math.min(HerdTalents.MAX_POINTS, st.points + refunded)
	st.spent = 0
	st.ranks = {}
	return true, { refunded = refunded, cost = cost }
end

-- The board's run bonus (Data/RunBonus accumulator).
function HerdTalents.bonus(profile: Profile): RunBonus.Bonus
	local st = HerdTalents.state(profile)
	local b = RunBonus.new()
	for id, rank in st.ranks do
		local def = H.get(id)
		if def then
			local v = def.per * rank
			RunBonus.add(b, def.effect, def.field, v)
			if def.field2 then
				RunBonus.add(b, def.effect, def.field2, v)
			end
		end
	end
	return b
end

local function fmt(def: H.TalentDef, rank: number): string
	local v = def.per * rank
	local s = if def.effect == "extra" and (def.field == "startRinds" or def.field == "startWhey")
		then tostring(math.floor(v))
		elseif def.effect == "addStat" and (def.field == "armor" or def.field == "regen") then string.format(
			"%.2f",
			v
		)
		elseif def.field == "redeployCut" then string.format("%.2f", v)
		else string.format("%.1f%%", v * 100)
	return (string.gsub(def.text, "%%s", (string.gsub(s, "%%", "%%%%"))))
end

-- Profile view `herdTalents` (docs/MONETIZATION.md "v5 views").
function HerdTalents.view(profile: Profile, day: number?): { [string]: any }
	local st = HerdTalents.state(profile)
	local list = {}
	for _, def in H.LIST do
		local rank = st.ranks[def.id] or 0
		table.insert(list, {
			id = def.id,
			name = def.name,
			rank = rank,
			maxRank = def.maxRank,
			nextCost = if rank < def.maxRank then H.rankCost(rank + 1) else nil,
			text = fmt(def, rank),
			nextText = if rank < def.maxRank then fmt(def, rank + 1) else nil,
		})
	end
	return {
		points = st.points,
		spent = st.spent,
		talents = list,
		freeRespec = day == nil or st.respecDay ~= math.floor(day),
		respecCheese = H.RESPEC_CHEESE,
	}
end

return HerdTalents
