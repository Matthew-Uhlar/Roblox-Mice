--!strict
-- Run/Difficulty: the 11-tier cheese difficulty ladder (docs/iter/2/ALIGNMENT.md
-- §2c A1, iteration-2 PLAN). Pure.
--
-- Each tier is a Pressure PRESET (a Config/Pressure board worth exactly `points`)
-- plus, for tiers 1 and 10-11, base multipliers on enemy HP / damage / spawn rate.
-- The tier's `reward` multiplies the payout cheese (and, through awardRun, stomps
-- and class XP: team P); it REPLACES the +8%-per-point Pressure cheese bonus.
-- Tier 0 = Custom: the leader's own Pressure board (unlocked after a Sharp clear);
-- it counts as the highest tier whose preset points are at or below its points.
--
-- Names are working names (team U / G finalize; cheese-themed, not Liberty's).

local Pressure = require("./Pressure")
local Types = require("../Types")

type WorldMods = Types.WorldMods

local Difficulty = {}

export type Tier = {
	id: number,
	key: string,
	name: string,
	points: number, -- Pressure preset points
	base: { hp: number, damage: number, spawn: number }?,
	reward: number, -- x payout cheese (stomps, class XP: team P)
	gemTier: number,
}

Difficulty.CUSTOM = 0
Difficulty.MILD = 1
Difficulty.MEDIUM = 2
Difficulty.SHARP = 3
Difficulty.DEFAULT = 2 -- Medium (today's P0)
Difficulty.CUSTOM_UNLOCK = 3 -- Custom opens after a Sharp clear

Difficulty.TIERS = table.freeze({
	{
		id = 1,
		key = "mild",
		name = "Mild",
		points = 0,
		base = { hp = 0.7, damage = 0.7, spawn = 0.85 },
		reward = 0.75,
		gemTier = 1,
	},
	{ id = 2, key = "medium", name = "Medium", points = 0, reward = 1.0, gemTier = 2 },
	{ id = 3, key = "sharp", name = "Sharp", points = 3, reward = 1.2, gemTier = 3 },
	{ id = 4, key = "extra_sharp", name = "Extra Sharp", points = 5, reward = 1.4, gemTier = 4 },
	{ id = 5, key = "aged", name = "Aged", points = 8, reward = 1.7, gemTier = 5 },
	{ id = 6, key = "smoked", name = "Smoked", points = 11, reward = 2.0, gemTier = 6 },
	{ id = 7, key = "pungent", name = "Pungent", points = 14, reward = 2.4, gemTier = 7 },
	{ id = 8, key = "stinky", name = "Stinky", points = 17, reward = 2.9, gemTier = 8 },
	{ id = 9, key = "scorched", name = "Scorched", points = 21, reward = 3.5, gemTier = 9 },
	{
		id = 10,
		key = "moldy",
		name = "Moldy",
		points = 21,
		base = { hp = 1.5, damage = 1.25, spawn = 1.0 },
		reward = 4.2,
		gemTier = 10,
	},
	{
		id = 11,
		key = "doomwheel",
		name = "Doomwheel",
		points = 21,
		base = { hp = 2.2, damage = 1.5, spawn = 1.2 },
		reward = 5.0,
		gemTier = 11,
	},
} :: { Tier })

Difficulty.MAX = #Difficulty.TIERS

-- Gem drops (top-damage squad's humans): bosses 1-3 35%, the final boss 100%;
-- a won Double or Nothing that stage doubles the chance. Tier 12 = the Golden
-- Wheel: Doomwheel's final boss on a won Double or Nothing.
Difficulty.GEM_CHANCE = 0.35
Difficulty.GEM_CHANCE_FINAL = 1.0
Difficulty.GOLDEN_WHEEL = 12

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function Difficulty.clamp(tier: any): number
	if not finite(tier) then
		return Difficulty.DEFAULT
	end
	return math.clamp(math.floor(tier), Difficulty.CUSTOM, Difficulty.MAX)
end

function Difficulty.get(tier: any): Tier?
	return Difficulty.TIERS[Difficulty.clamp(tier)]
end

-- The tier's Pressure board: ranks added one at a time round-robin over
-- Config/Pressure's order until the board is worth `points` (deterministic).
function Difficulty.preset(tier: any): Pressure.Board
	local def = Difficulty.get(tier)
	local want = if def then def.points else 0
	local board: Pressure.Board = {}
	local guard = 0
	while Pressure.points(board) < want and guard < 200 do
		guard += 1
		local progressed = false
		for _, id in Pressure.ORDER do
			if Pressure.points(board) >= want then
				break
			end
			local nextBoard = Pressure.setRank(board, id, (board[id] or 0) + 1)
			if
				nextBoard
				and Pressure.points(nextBoard) <= want
				and Pressure.points(nextBoard) > Pressure.points(board)
			then
				board = nextBoard
				progressed = true
			end
		end
		if not progressed then
			break
		end
	end
	return board
end

-- The tier a Custom board counts as: the highest whose preset points are at or
-- below its points (never below Medium).
function Difficulty.forPoints(points: any): number
	local p = if finite(points) then points else 0
	local best = Difficulty.MEDIUM
	for _, t in Difficulty.TIERS do
		if t.id >= Difficulty.MEDIUM and t.points <= p and not t.base then
			best = math.max(best, t.id)
		end
	end
	return best
end

-- The run's effective tier (Custom resolves through its board's points).
function Difficulty.effective(tier: any, board: any?): number
	local t = Difficulty.clamp(tier)
	if t == Difficulty.CUSTOM then
		return Difficulty.forPoints(Pressure.points(board))
	end
	return t
end

-- The run's Pressure board: the preset, or the Custom board.
function Difficulty.board(tier: any, customBoard: any?): Pressure.Board
	local t = Difficulty.clamp(tier)
	if t == Difficulty.CUSTOM then
		return Pressure.sanitize(customBoard)
	end
	return Difficulty.preset(t)
end

-- Multiplies the tier's base onto WorldMods (in place; returns it).
function Difficulty.applyBase(mods: WorldMods, tier: any): WorldMods
	local def = Difficulty.get(tier)
	local base = def and def.base
	if not base then
		return mods
	end
	mods.enemyHpMult *= base.hp
	mods.bossHpMult *= base.hp
	mods.enemyDamageMult *= base.damage
	mods.bossDamageMult *= base.damage
	mods.spawnRateMult *= base.spawn
	return mods
end

function Difficulty.reward(tier: any): number
	local def = Difficulty.get(tier)
	return if def then def.reward else 1
end

-- Gem drop chance for a boss kill (stageIndex 1..4; final = the last stage).
function Difficulty.gemChance(final: boolean, donWon: boolean?): number
	local p = if final then Difficulty.GEM_CHANCE_FINAL else Difficulty.GEM_CHANCE
	if donWon then
		p *= 2
	end
	return math.min(1, p)
end

function Difficulty.gemTier(tier: any, final: boolean?, donWon: boolean?): number
	local t = Difficulty.effective(tier)
	local def = Difficulty.get(t)
	local g = if def then def.gemTier else Difficulty.DEFAULT
	if t == Difficulty.MAX and final and donWon then
		return Difficulty.GOLDEN_WHEEL
	end
	return g
end

-- Which tier the leader may pick: unlocked = profile.difficulty.unlocked (team P;
-- default Medium); Custom needs a Sharp clear. Rookies (runs 0-2) play Mild unless
-- a non-rookie leads.
function Difficulty.allowed(tier: any, unlocked: any, cleared: any): boolean
	local t = Difficulty.clamp(tier)
	local u = if finite(unlocked) then unlocked else Difficulty.DEFAULT
	if t == Difficulty.CUSTOM then
		return finite(cleared) and cleared >= Difficulty.CUSTOM_UNLOCK
	end
	return t >= 1 and t <= u
end

-- The lobby payload's ladder view.
function Difficulty.view(): { any }
	local out = {}
	for _, t in Difficulty.TIERS do
		table.insert(out, {
			id = t.id,
			key = t.key,
			name = t.name,
			points = t.points,
			reward = t.reward,
			gemTier = t.gemTier,
		})
	end
	return out
end

return Difficulty
