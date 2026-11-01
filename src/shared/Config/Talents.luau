--!strict
-- Permanent talents (Team D), bought with cheese in the lobby shop ("talent:<id>").
-- Small but meaningful: a maxed talent is roughly one Common in-run upgrade.
-- Team A's Stats.compute applies `perLevel` x level (talentDefs param), using
-- only `add` deltas so stacking is linear and predictable. Baselines from
-- Stats.DEFAULT: maxHp 100, moveSpeed ~16, damageMult 1.

local Types = require("../Types")

export type TalentDef = {
	id: string,
	name: string,
	description: string,
	maxLevel: number,
	costs: { number }, -- cheese cost of level 1..maxLevel (#costs == maxLevel)
	perLevel: Types.StatDelta,
}

local T = {}

T.ORDER = {
	"thick_hide",
	"heavy_trunk",
	"quick_feet",
	"crumb_magnet",
	"cheese_nose",
	"quick_study",
	"second_breath",
	"lucky_tusk",
}

local defs: { [string]: TalentDef } = {
	thick_hide = {
		id = "thick_hide",
		name = "Thick Hide",
		description = "+6 max HP per level.",
		maxLevel = 5,
		costs = { 250, 500, 900, 1400, 2000 },
		perLevel = { add = { maxHp = 6 } },
	},
	heavy_trunk = {
		id = "heavy_trunk",
		name = "Heavy Trunk",
		description = "+3% damage per level.",
		maxLevel = 5,
		costs = { 300, 600, 1000, 1600, 2400 },
		perLevel = { add = { damageMult = 0.03 } },
	},
	quick_feet = {
		id = "quick_feet",
		name = "Quick Feet",
		description = "+0.5 move speed per level.",
		maxLevel = 4,
		costs = { 250, 550, 950, 1500 },
		perLevel = { add = { moveSpeed = 0.5 } },
	},
	crumb_magnet = {
		id = "crumb_magnet",
		name = "Crumb Magnet",
		description = "+1.5 crumb pickup radius per level.",
		maxLevel = 4,
		costs = { 200, 450, 800, 1200 },
		perLevel = { add = { pickupRadius = 1.5 } },
	},
	cheese_nose = {
		id = "cheese_nose",
		name = "Cheese Nose",
		description = "+3% cheese found in runs per level.",
		maxLevel = 5,
		costs = { 400, 800, 1300, 2000, 3000 },
		perLevel = { add = { cheeseMult = 0.03 } },
	},
	quick_study = {
		id = "quick_study",
		name = "Quick Study",
		description = "+4% in-run XP per level.",
		maxLevel = 5,
		costs = { 300, 600, 1000, 1500, 2200 },
		perLevel = { add = { xpMult = 0.04 } },
	},
	second_breath = {
		id = "second_breath",
		name = "Second Breath",
		description = "+0.15 HP regeneration per second per level.",
		maxLevel = 4,
		costs = { 350, 700, 1200, 1800 },
		perLevel = { add = { regen = 0.15 } },
	},
	lucky_tusk = {
		id = "lucky_tusk",
		name = "Lucky Tusk",
		description = "+0.05 luck per level (slightly better upgrade rarities).",
		maxLevel = 4,
		costs = { 500, 1000, 1700, 2500 },
		perLevel = { add = { luck = 0.05 } },
	},
}

T.defs = defs

function T.get(id: string): TalentDef?
	return defs[id]
end

-- Cheese cost to go from `currentLevel` to currentLevel + 1, or nil at max.
function T.costFor(id: string, currentLevel: number): number?
	local def = defs[id]
	if not def or currentLevel >= def.maxLevel or currentLevel < 0 then
		return nil
	end
	return def.costs[currentLevel + 1]
end

return T
