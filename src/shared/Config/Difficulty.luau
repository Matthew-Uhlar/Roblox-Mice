--!strict
-- The difficulty ladder (iteration 2, ALIGNMENT §2c A1). Pure data, shared by M2 (match
-- rules: the Pressure preset of each tier + the base multipliers), P (records, gem
-- tiers, reward multiplier) and U (lobby selector). Names are working names (cheese-
-- themed; U and G finalise the wording).
--
--   points   the Pressure board points of the tier's preset (M2 picks the modifiers)
--   base     extra enemy multipliers on top of the preset (hp, damage, spawn)
--   reward   x cheese payout, stomps and class XP
--   gemTier  the tier of the Cheese Gems that drop on it (12 = Golden Wheel, see Config/Gems)
-- Clearing a tier (full clear or Last Herd) unlocks the next one. New players start with
-- tiers 1-2 unlocked; rookies (runs 0-2) play Mild unless a non-rookie leads.

export type TierDef = {
	tier: number,
	id: string,
	name: string,
	points: number,
	base: { hp: number, damage: number, spawn: number },
	reward: number,
	gemTier: number,
}

local D = {}

local function t(
	tier: number,
	id: string,
	name: string,
	points: number,
	hp: number,
	dmg: number,
	spawn: number,
	reward: number
): TierDef
	return {
		tier = tier,
		id = id,
		name = name,
		points = points,
		base = { hp = hp, damage = dmg, spawn = spawn },
		reward = reward,
		gemTier = tier,
	}
end

D.TIERS = {
	t(1, "mild", "Mild", 0, 0.6, 0.6, 0.8, 1.0), -- iter 3 T-11: reward x1.0 (was 0.75); bases M1 ladder tuning
	t(2, "medium", "Medium", 0, 1.0, 1.0, 1.0, 1.0), -- iter 7 (Flow): 1 / 1 / 1 with the 11-class rotation (sim 10/12, Fast 9/12); iter 6: 0.9 / 0.9 / 0.95
	t(3, "sharp", "Sharp", 3, 1.2, 1.15, 1.05, 1.2), -- iter 6 (Flow): a base (was 1 / 1 / 1; sim 10/12 -> 7/12)
	t(4, "extra_sharp", "Extra Sharp", 5, 1.2, 1.15, 1.05, 1.4), -- iter 6: tiers 4-9 share Sharp's base (ordering)
	t(5, "aged", "Aged", 8, 1.2, 1.15, 1.05, 1.7),
	t(6, "smoked", "Smoked", 11, 1.2, 1.15, 1.05, 2.0),
	t(7, "pungent", "Pungent", 14, 1.2, 1.15, 1.05, 2.4),
	t(8, "stinky", "Stinky", 17, 1.2, 1.15, 1.05, 2.9),
	t(9, "scorched", "Scorched", 21, 1.2, 1.15, 1.05, 3.5),
	t(10, "moldy", "Moldy", 21, 1.32, 1.2, 1.06, 4.2), -- iter 6: was 1.15 / 1.08 / 1.02; iteration 4: between Scorched and Doomwheel (was 1.6 / 1.4 / 1.2)
	t(11, "doomwheel", "Doomwheel", 21, 1.55, 1.3, 1.1, 5.0), -- iter 6 (Flow): was 1.3 / 1.15 / 1.05 (sim: fresh 0/12, maxed veteran 8-11/12); iteration 4: was 2.2 / 1.8 / 1.3
} :: { TierDef }

D.COUNT = #D.TIERS
D.DEFAULT_TIER = 2 -- Medium
D.START_UNLOCKED = 2 -- a new account can pick Mild and Medium
D.ROOKIE_TIER = 1 -- runs 0-2 play Mild unless a non-rookie leads
D.ROOKIE_RUNS = 3
-- Extracting at stage >= this on tiers <= ONBOARD_MAX_TIER counts as a clear for UNLOCKING only.
D.ONBOARD_EXTRACT_STAGE = 3
D.ONBOARD_MAX_TIER = 3

function D.clamp(tier: any): number
	if type(tier) ~= "number" or tier ~= tier then
		return D.DEFAULT_TIER
	end
	return math.clamp(math.floor(tier), 1, D.COUNT)
end

function D.get(tier: any): TierDef
	return D.TIERS[D.clamp(tier)]
end

-- A Custom (Pressure board) run counts as the highest tier whose preset points are at or
-- below its points (tiers 10-11 need their own base multipliers, so Custom stops at 9).
function D.tierForPoints(points: any): number
	local p = if type(points) == "number" and points == points then points else 0
	local best = D.DEFAULT_TIER
	for _, def in D.TIERS do
		if def.tier >= D.DEFAULT_TIER and def.tier <= 9 and def.points <= p then
			best = def.tier
		end
	end
	return best
end

return D
