--!strict
-- Pure class-progression fallbacks for the UI (no Roblox APIs; tested in
-- tests/specs/ClientV2.spec.luau). Data/ClassProgress (Team R3) is the
-- authority; the UI calls it when it exists and falls back to these
-- GDD-v2 §5 numbers otherwise:
--   levels 1..30, level n needs floor(100 * n^1.4) XP to reach n + 1;
--   alternate abilities at levels 5 and 15; skins at 3, 10, 20, 30;
--   mastery Bronze / Silver / Gold Herd at 10 / 20 / 30.

local ClassMath = {}

ClassMath.MAX_LEVEL = 30
ClassMath.ABILITY_LEVELS = { 1, 5, 15 } -- base, alternate 1, alternate 2
ClassMath.SKIN_LEVELS = { 3, 10, 20, 30 }
ClassMath.MASTERY = {
	{ level = 10, id = "bronze", name = "Bronze Herd" },
	{ level = 20, id = "silver", name = "Silver Herd" },
	{ level = 30, id = "gold", name = "Gold Herd" },
}

function ClassMath.xpToNext(level: number): number
	local n = math.clamp(math.floor(level), 1, ClassMath.MAX_LEVEL)
	return math.floor(100 * n ^ 1.4)
end

-- "none" | "bronze" | "silver" | "gold"
function ClassMath.mastery(level: number): string
	local best = "none"
	for _, m in ClassMath.MASTERY do
		if level >= m.level then
			best = m.id
		end
	end
	return best
end

function ClassMath.masteryName(id: string): string?
	for _, m in ClassMath.MASTERY do
		if m.id == id then
			return m.name
		end
	end
	return nil
end

-- Fraction of the way to the next level (1 at the level cap).
function ClassMath.progress(xp: number, level: number): number
	if level >= ClassMath.MAX_LEVEL then
		return 1
	end
	return math.clamp(xp / math.max(1, ClassMath.xpToNext(level)), 0, 1)
end

export type Unlock = { kind: string, level: number, index: number }

-- Everything that unlocks when a class goes from level `a` to level `b`
-- (exclusive of a, inclusive of b): alternate abilities, skins and mastery.
function ClassMath.unlocksBetween(a: number, b: number): { Unlock }
	local out: { Unlock } = {}
	if b <= a then
		return out
	end
	for i, lv in ClassMath.ABILITY_LEVELS do
		if i > 1 and lv > a and lv <= b then
			table.insert(out, { kind = "ability", level = lv, index = i })
		end
	end
	for i, lv in ClassMath.SKIN_LEVELS do
		if lv > a and lv <= b then
			table.insert(out, { kind = "skin", level = lv, index = i })
		end
	end
	for i, m in ClassMath.MASTERY do
		if m.level > a and m.level <= b then
			table.insert(out, { kind = "mastery", level = m.level, index = i })
		end
	end
	table.sort(out, function(x, y)
		if x.level ~= y.level then
			return x.level < y.level
		end
		return x.kind < y.kind
	end)
	return out
end

-- Replays XP gains: from (xp, level) add `gain`, returning (xp, level, levelsGained).
function ClassMath.addXp(xp: number, level: number, gain: number): (number, number, number)
	local x, lv, gained = math.max(0, xp) + math.max(0, gain), math.max(1, math.floor(level)), 0
	while lv < ClassMath.MAX_LEVEL and x >= ClassMath.xpToNext(lv) do
		x -= ClassMath.xpToNext(lv)
		lv += 1
		gained += 1
	end
	if lv >= ClassMath.MAX_LEVEL then
		x = 0
	end
	return x, lv, gained
end

return ClassMath
