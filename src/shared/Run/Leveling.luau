--!strict
-- In-run XP curve (crumbs -> levels -> upgrade picks). Pure.
-- Bad input (NaN, negative, inf) for `gained` counts as 0 / is clamped.
-- At MAX_LEVEL the bar stays empty (xp = 0) and no more levels are gained.

local Leveling = {}

Leveling.MAX_LEVEL = 99
Leveling.MAX_GAIN = 1e7

-- XP needed to go from `level` to `level + 1`.
-- L1: 10, L2: 18, L5: 50, L10: 122, L20: 342.
function Leveling.xpToNext(level: number): number
	local l = math.max(1, math.floor(if level == level then level else 1))
	local n = l - 1
	return math.floor(10 + 8 * n + 0.5 * n * n)
end

function Leveling.addXp(level: number, xp: number, gained: number): (number, number, number)
	local lvl = math.max(1, math.floor(if level == level then level else 1))
	local cur = if xp == xp then math.max(0, xp) else 0
	local g = if gained == gained then math.clamp(gained, 0, Leveling.MAX_GAIN) else 0
	if lvl >= Leveling.MAX_LEVEL then
		return Leveling.MAX_LEVEL, 0, 0
	end
	cur += g
	local start = lvl
	while lvl < Leveling.MAX_LEVEL do
		local need = Leveling.xpToNext(lvl)
		if cur < need then
			break
		end
		cur -= need
		lvl += 1
	end
	if lvl >= Leveling.MAX_LEVEL then
		cur = 0
	end
	return lvl, cur, lvl - start
end

-- Iteration 4 (Liberty-style strength): every level gives fixed stats, and the
-- upgrade cards come only as milestone picks every MILESTONE_EVERY levels.
Leveling.MILESTONE_EVERY = 5
Leveling.HP_PER_LEVEL = 0.03 -- +3% max HP per level gained
Leveling.DAMAGE_PER_LEVEL = 0.02 -- +2% damage per level gained
Leveling.ARMOR_EVERY = 5 -- +1 armor every this many levels

local function lv(level: any): number
	if type(level) ~= "number" or level ~= level then
		return 1
	end
	return math.clamp(math.floor(level), 1, Leveling.MAX_LEVEL)
end

-- Milestone picks earned going from `from` to `to` (levels that are multiples of 5).
function Leveling.milestones(from: number, to: number): number
	local a, b = lv(from), lv(to)
	if b <= a then
		return 0
	end
	local m = Leveling.MILESTONE_EVERY
	return b // m - a // m
end

function Leveling.isMilestone(level: number): boolean
	local l = lv(level)
	return l % Leveling.MILESTONE_EVERY == 0
end

-- The fixed gains of `level` (level 1 = none) as a Types.StatDelta {add, mul}.
function Leveling.levelDelta(level: number): { add: { [string]: number }, mul: { [string]: number } }
	local n = lv(level) - 1
	local armor = lv(level) // Leveling.ARMOR_EVERY
	return {
		add = if armor > 0 then { armor = armor } else {},
		mul = if n > 0
			then { maxHp = 1 + Leveling.HP_PER_LEVEL * n, damageMult = 1 + Leveling.DAMAGE_PER_LEVEL * n }
			else {},
	}
end

-- The Levels list (team U): what each level up to `upTo` gives.
function Leveling.gainsList(
	upTo: number?
): { { level: number, hp: number, damage: number, armor: number, pick: boolean } }
	local out = {}
	for l = 2, lv(upTo or Leveling.MAX_LEVEL) do
		table.insert(out, {
			level = l,
			hp = Leveling.HP_PER_LEVEL,
			damage = Leveling.DAMAGE_PER_LEVEL,
			armor = if l % Leveling.ARMOR_EVERY == 0 then 1 else 0,
			pick = l % Leveling.MILESTONE_EVERY == 0,
		})
	end
	return out
end

return Leveling
