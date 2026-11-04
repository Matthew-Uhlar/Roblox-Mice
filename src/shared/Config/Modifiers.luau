--!strict
-- Route curses and blessings (GDD §3.1, brainstorm Topics 5 and 6).
--
-- Curses (`world`): applied by Stats.worldMods on top of difficulty scaling.
--   * boolean fields (oneHitKO, fallingRocks) are SET (any active curse turns it on)
--   * numeric fields ending in "Mult" MULTIPLY
--   * other numeric fields (eliteChance) ADD, then clamp to 0..1
--   Low and Mid curses last for the stage they were picked on; High curses last
--   the whole run (a High card's "Cleanse" can remove one).
-- Blessings (`delta`): a StatDelta given to every player for the rest of the
--   run, applied by Stats.compute. Extension: `abilityMul` multiplies AbilityDef
--   fields (used by "Jumbo Abilities", the brainstorm's double ability size).

local Types = require("../Types")

-- Same shape as Types.ModifierDef plus the optional `abilityMul` extension.
export type ModifierDef = {
	id: string,
	name: string,
	description: string,
	tier: Types.Tier,
	kind: "curse" | "blessing",
	world: { [string]: number | boolean }?,
	delta: Types.StatDelta?,
	abilityMul: { [string]: number }?,
}

local Modifiers = {}

Modifiers.TIERS = { "Low", "Mid", "High" } :: { Types.Tier }

local list: { ModifierDef } = {
	------------------------------------------------------------ Low curses
	{
		id = "curse_tough_mice",
		name = "Tough Mice",
		description = "Mice have +30% HP this stage.",
		tier = "Low",
		kind = "curse",
		world = { enemyHpMult = 1.3 },
	},
	{
		id = "curse_swarm",
		name = "Swarm",
		description = "+40% more mice spawn this stage.",
		tier = "Low",
		kind = "curse",
		world = { spawnRateMult = 1.4 },
	},
	{
		id = "curse_sharp_teeth",
		name = "Sharp Teeth",
		description = "Mice bite 30% harder this stage.",
		tier = "Low",
		kind = "curse",
		world = { enemyDamageMult = 1.3 },
	},
	{
		id = "curse_scurry",
		name = "Scurry",
		description = "Mice move 20% faster this stage.",
		tier = "Low",
		kind = "curse",
		world = { enemySpeedMult = 1.2 },
	},
	{
		id = "curse_stale_snacks",
		name = "Stale Snacks",
		description = "All healing is halved this stage.",
		tier = "Low",
		kind = "curse",
		world = { healingMult = 0.5 },
	},
	------------------------------------------------------------ Mid curses
	{
		id = "curse_turbo_mice",
		name = "Turbo Mice",
		description = "Mice move 40% faster and their spit flies 25% faster this stage.",
		tier = "Mid",
		kind = "curse",
		world = { enemySpeedMult = 1.4, enemyProjectileSpeedMult = 1.25 },
	},
	{
		id = "curse_cheese_hail",
		name = "Cheese Hail",
		description = "Wheels of cheese fall from the sky this stage. Watch the shadows!",
		tier = "Mid",
		kind = "curse",
		world = { fallingRocks = true },
	},
	{
		id = "curse_elite_pack",
		name = "Elite Pack",
		description = "+25% chance for every mouse to be an elite this stage.",
		tier = "Mid",
		kind = "curse",
		world = { eliteChance = 0.25 },
	},
	{
		id = "curse_angry_boss",
		name = "Angry Boss",
		description = "The boss has +50% HP and hits 30% harder.",
		tier = "Mid",
		kind = "curse",
		world = { bossHpMult = 1.5, bossDamageMult = 1.3 },
	},
	{
		id = "curse_horde",
		name = "Horde",
		description = "+80% more mice spawn this stage.",
		tier = "Mid",
		kind = "curse",
		world = { spawnRateMult = 1.8 },
	},
	------------------------------------------------------------ High curses (whole run)
	{
		id = "curse_one_shot",
		name = "Glass Elephants",
		description = "For the rest of the run, any hit downs you instantly.",
		tier = "High",
		kind = "curse",
		world = { oneHitKO = true },
	},
	{
		id = "curse_avalanche",
		name = "Avalanche",
		description = "For the rest of the run, boulders rain down and mice hit 25% harder.",
		tier = "High",
		kind = "curse",
		world = { fallingRocks = true, enemyDamageMult = 1.25 },
	},
	{
		id = "curse_mega_horde",
		name = "Mega Horde",
		description = "For the rest of the run, +60% more mice with +30% HP.",
		tier = "High",
		kind = "curse",
		world = { spawnRateMult = 1.6, enemyHpMult = 1.3 },
	},
	{
		id = "curse_lightning_mice",
		name = "Lightning Mice",
		description = "For the rest of the run, mice are 50% faster and their spit 40% faster.",
		tier = "High",
		kind = "curse",
		world = { enemySpeedMult = 1.5, enemyProjectileSpeedMult = 1.4 },
	},
	{
		id = "curse_famine",
		name = "Famine",
		description = "For the rest of the run, all healing is cut by 75%.",
		tier = "High",
		kind = "curse",
		world = { healingMult = 0.25 },
	},
	{
		id = "curse_boss_rage",
		name = "Boss Rage",
		description = "For the rest of the run, bosses have +75% HP and hit 50% harder.",
		tier = "High",
		kind = "curse",
		world = { bossHpMult = 1.75, bossDamageMult = 1.5 },
	},
	------------------------------------------------------------ Low blessings
	{
		id = "bless_hearty_meal",
		name = "Hearty Meal",
		description = "The whole party gets +30% max HP.",
		tier = "Low",
		kind = "blessing",
		delta = { mul = { maxHp = 1.3 } },
	},
	{
		id = "bless_quick_feet",
		name = "Quick Feet",
		description = "The whole party moves 20% faster.",
		tier = "Low",
		kind = "blessing",
		delta = { mul = { moveSpeed = 1.2 } },
	},
	{
		id = "bless_sharp_tusks",
		name = "Sharpened Tusks",
		description = "The whole party deals +25% damage.",
		tier = "Low",
		kind = "blessing",
		delta = { mul = { damageMult = 1.25 } },
	},
	{
		id = "bless_party_magnet",
		name = "Party Magnet",
		description = "The whole party gets +60% pickup radius.",
		tier = "Low",
		kind = "blessing",
		delta = { mul = { pickupRadius = 1.6 } },
	},
	{
		id = "bless_lucky_crumbs",
		name = "Lucky Crumbs",
		description = "The whole party gets +1 luck (rarer level-up cards).",
		tier = "Low",
		kind = "blessing",
		delta = { add = { luck = 1 } },
	},
	------------------------------------------------------------ Mid blessings
	{
		id = "bless_big_stomps",
		name = "Big Stomps",
		description = "The whole party gets +40% area.",
		tier = "Mid",
		kind = "blessing",
		delta = { mul = { areaMult = 1.4 } },
	},
	{
		id = "bless_fast_trunks",
		name = "Fast Trunks",
		description = "The whole party attacks 40% faster.",
		tier = "Mid",
		kind = "blessing",
		delta = { mul = { attackSpeedMult = 1.4 } },
	},
	{
		id = "bless_party_armor",
		name = "Party Armor",
		description = "The whole party blocks 3 damage per hit and regenerates 2 HP/s.",
		tier = "Mid",
		kind = "blessing",
		delta = { add = { armor = 3, regen = 2 } },
	},
	{
		id = "bless_static_party",
		name = "Static Party",
		description = "Every hit from the party chains to 1 more mouse.",
		tier = "Mid",
		kind = "blessing",
		delta = { add = { chain = 1 } },
	},
	{
		id = "bless_skewer_party",
		name = "Skewer Party",
		description = "Every shot from the party pierces 2 more mice.",
		tier = "Mid",
		kind = "blessing",
		delta = { add = { pierceBonus = 2 } },
	},
	------------------------------------------------------------ High blessings
	{
		id = "bless_extra_projectile",
		name = "+1 Projectile",
		description = "Every weapon in the party fires 1 more projectile.",
		tier = "High",
		kind = "blessing",
		delta = { add = { projectileBonus = 1 } },
	},
	{
		id = "bless_jumbo_abilities",
		name = "Jumbo Abilities",
		description = "Every ability in the party is twice as big.",
		tier = "High",
		kind = "blessing",
		delta = {},
		abilityMul = { area = 2 },
	},
	{
		id = "bless_hyper_cooldown",
		name = "Hyper Cooldown",
		description = "Party ability cooldowns are cut by 50%.",
		tier = "High",
		kind = "blessing",
		delta = { mul = { cooldownMult = 0.5 } },
	},
	{
		id = "bless_explosive_party",
		name = "Explosive Party",
		description = "Every mouse the party kills explodes in an 8-stud blast.",
		tier = "High",
		kind = "blessing",
		delta = { add = { explodeOnKill = 8 } },
	},
	{
		id = "bless_vampire_herd",
		name = "Snacking Herd",
		description = "The whole party heals for 15% of damage dealt.",
		tier = "High",
		kind = "blessing",
		delta = { add = { lifesteal = 0.15 } },
	},
}

local byId: { [string]: ModifierDef } = {}
-- byTierKind[kind][tier] = { ids in declaration order }
local byTierKind: { [string]: { [string]: { string } } } = {
	curse = { Low = {}, Mid = {}, High = {} },
	blessing = { Low = {}, Mid = {}, High = {} },
}
for _, def in list do
	assert(byId[def.id] == nil, "duplicate modifier id " .. def.id)
	byId[def.id] = def
	table.insert(byTierKind[def.kind][def.tier], def.id)
end

Modifiers.list = list
Modifiers.byId = byId

function Modifiers.get(id: string): ModifierDef?
	return byId[id]
end

-- Returns a fresh array of modifier ids for that kind and tier.
function Modifiers.ids(kind: "curse" | "blessing", tier: Types.Tier): { string }
	return table.clone(byTierKind[kind][tier])
end

-- "stage" for Low/Mid curses, "run" for High curses (GDD §3.1).
function Modifiers.curseDuration(tier: Types.Tier): "stage" | "run"
	return if tier == "High" then "run" else "stage"
end

return Modifiers
