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

return Leveling
