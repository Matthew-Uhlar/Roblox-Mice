--!strict
-- Pressure maths (GDD §3.7). Pure: validates boards, counts points, turns a
-- board into WorldMods deltas and reward bonuses, and holds the unlock /
-- leader rules. Data lives in Config/Pressure.luau.
--
-- A board is { [modId]: rank } with only known ids and integer ranks in
-- 1..maxRank (rank 0 entries are dropped). Anything from the network or a
-- save goes through Pressure.sanitize first; every other function sanitizes
-- its input too, so a garbage board can never raise an error or overflow.
--
--   Pressure.sanitize(raw: any) -> Board
--   Pressure.clampRank(modId, rank: any) -> number          -- 0 for unknown ids
--   Pressure.setRank(board, modId, rank: any) -> Board?     -- new board; nil for unknown ids
--   Pressure.points(board) -> number                        -- 0..MAX_POINTS
--   Pressure.worldDelta(board) -> {[field]: number}         -- curse-style `world` table
--   Pressure.applyToMods(mods: WorldMods, board) -> WorldMods  -- in place, returns mods
--   Pressure.cheeseMult(points) -> number                   -- 1 + 0.08 * points
--   Pressure.luck(points) -> number                         -- 0.05 * points
--   Pressure.epicBonus(points) -> number                    -- 0.02 * points
--   Pressure.preview(board) -> { points, cheesePct, luck, epicPct }
--   Pressure.pickLeader(candidates) -> id?                  -- see below
--   Pressure.isUnlocked(profilePressure: any) -> boolean
--   Pressure.recordRun(profilePressure, won: boolean, points: any) -> (unlockedNow, newRecord)
--   Pressure.badges(highestCleared) -> {number}              -- earned badge thresholds

local Types = require("../Types")
local Config = require("../Config/Pressure")
local Stats = require("./Stats")

type WorldMods = Types.WorldMods

export type Board = { [string]: number }
export type Candidate = {
	id: number,
	ready: boolean,
	readyAt: number?, -- when they readied (any monotonic clock); nil = unknown
	joinedAt: number,
	willing: boolean?, -- would be in the next party (ready or auto-eligible)
}
export type ProfilePressure = { unlocked: boolean, highestCleared: number, board: Board }

local Pressure = {}

Pressure.MAX_POINTS = Config.MAX_POINTS
Pressure.ORDER = Config.ORDER
Pressure.REWARDS = Config.REWARDS
-- At most this many keys of a raw board are looked at (anti-garbage).
Pressure.MAX_RAW_KEYS = 64

local function finite(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

function Pressure.clampRank(modId: any, rank: any): number
	local def = Config.get(modId)
	if not def or not finite(rank) then
		return 0
	end
	return math.clamp(math.floor(rank), 0, def.maxRank)
end

function Pressure.sanitize(raw: any): Board
	local out: Board = {}
	if type(raw) ~= "table" then
		return out
	end
	local seen = 0
	for k, v in raw do
		seen += 1
		if seen > Pressure.MAX_RAW_KEYS then
			break
		end
		local r = Pressure.clampRank(k, v)
		if r > 0 then
			out[k :: string] = r
		end
	end
	return out
end

function Pressure.setRank(board: any, modId: any, rank: any): Board?
	if not Config.get(modId) then
		return nil
	end
	local out = Pressure.sanitize(board)
	local r = Pressure.clampRank(modId, rank)
	out[modId :: string] = if r > 0 then r else nil
	return out
end

function Pressure.points(board: any): number
	local b = Pressure.sanitize(board)
	local total = 0
	for id, rank in b do
		local def = Config.get(id)
		if def then
			total += rank * def.points
		end
	end
	return total
end

-- The board as a curse-style `world` table (Stats.applyCurse semantics):
-- "*Mult" fields are factors (1 + perRank * rank, multiplied across
-- modifiers), other fields are additive.
function Pressure.worldDelta(board: any): { [string]: number }
	local b = Pressure.sanitize(board)
	local out: { [string]: number } = {}
	for _, id in Config.ORDER do
		local rank = b[id]
		local def = Config.get(id)
		if rank and def then
			for field, per in def.perRank do
				if string.sub(field, -4) == "Mult" then
					out[field] = (out[field] or 1) * math.max(0, 1 + per * rank)
				else
					out[field] = (out[field] or 0) + per * rank
				end
			end
		end
	end
	return out
end

-- Applies the board on top of `mods` (in place) and returns it.
function Pressure.applyToMods(mods: WorldMods, board: any): WorldMods
	local delta = Pressure.worldDelta(board)
	if next(delta) == nil then
		return mods
	end
	Stats.applyCurse(mods, delta)
	local m = mods :: any
	if type(m.healingMult) == "number" then
		m.healingMult = math.max(0, m.healingMult)
	end
	if type(m.rangedExtraProjectiles) == "number" then
		m.rangedExtraProjectiles = math.max(0, math.floor(m.rangedExtraProjectiles + 0.5))
	end
	return mods
end

local function pts(points: any): number
	if not finite(points) then
		return 0
	end
	return math.clamp(math.floor(points), 0, Pressure.MAX_POINTS)
end

function Pressure.cheeseMult(points: any): number
	return 1 + Config.REWARDS.cheesePerPoint * pts(points)
end

function Pressure.luck(points: any): number
	return Config.REWARDS.luckPerPoint * pts(points)
end

function Pressure.epicBonus(points: any): number
	return Config.REWARDS.epicPerPoint * pts(points)
end

-- Numbers for the lobby's reward preview.
function Pressure.preview(board: any): { points: number, cheesePct: number, luck: number, epicPct: number }
	local p = Pressure.points(board)
	return {
		points = p,
		cheesePct = math.floor(Config.REWARDS.cheesePerPoint * p * 100 + 0.5),
		luck = Pressure.luck(p),
		epicPct = math.floor(Config.REWARDS.epicPerPoint * p * 100 + 0.5),
	}
end

-- Party leader (GDD §3.7): the first human to ready up (smallest readyAt);
-- if nobody is ready, the earliest-joined player who would be in the next
-- party (`willing`); else the earliest-joined player present. Ties fall back
-- to joinedAt, then the lower id. Callers pass humans only.
function Pressure.pickLeader(candidates: { Candidate }): number?
	local best: Candidate? = nil
	local function tier(c: Candidate): number
		if c.ready then
			return 1
		end
		if c.willing then
			return 2
		end
		return 3
	end
	local function before(a: Candidate, b: Candidate): boolean
		local ta, tb = tier(a), tier(b)
		if ta ~= tb then
			return ta < tb
		end
		if ta == 1 then
			local ra = if finite(a.readyAt) then a.readyAt :: number else math.huge
			local rb = if finite(b.readyAt) then b.readyAt :: number else math.huge
			if ra ~= rb then
				return ra < rb
			end
		end
		if a.joinedAt ~= b.joinedAt then
			return a.joinedAt < b.joinedAt
		end
		return a.id < b.id
	end
	for _, c in candidates do
		if type(c) == "table" and type(c.id) == "number" then
			if best == nil or before(c, best) then
				best = c
			end
		end
	end
	return if best then best.id else nil
end

-- Unlock + record rules -------------------------------------------------------

function Pressure.defaultProfile(): ProfilePressure
	return { unlocked = false, highestCleared = 0, board = {} }
end

-- Repairs a saved profile.pressure (any garbage -> defaults).
function Pressure.sanitizeProfile(raw: any): ProfilePressure
	local t = if type(raw) == "table" then raw else {}
	return {
		unlocked = t.unlocked == true,
		highestCleared = pts(t.highestCleared),
		board = Pressure.sanitize(t.board),
	}
end

function Pressure.isUnlocked(profilePressure: any): boolean
	return type(profilePressure) == "table" and profilePressure.unlocked == true
end

-- A finished run. Only a WIN (Go Home; RunState's only "Win" outcome) counts:
-- the first one unlocks the board, and the run's points raise highestCleared.
-- Returns (unlockedNow, newRecord). Mutates `pp` in place.
function Pressure.recordRun(pp: ProfilePressure, won: boolean, points: any): (boolean, boolean)
	if won ~= true then
		return false, false
	end
	local unlockedNow = pp.unlocked ~= true
	pp.unlocked = true
	local p = pts(points)
	local newRecord = p > (pp.highestCleared or 0)
	if newRecord then
		pp.highestCleared = p
	end
	return unlockedNow, newRecord
end

function Pressure.badges(highestCleared: any): { number }
	local h = pts(highestCleared)
	local out = {}
	for _, b in Config.BADGES do
		if h >= b then
			table.insert(out, b)
		end
	end
	return out
end

return Pressure
