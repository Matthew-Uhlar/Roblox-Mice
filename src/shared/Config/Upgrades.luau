--!strict
-- In-run level-up cards (GDD §5). Pillar 2: every card is a BIG, visible change.
-- No "+3% damage" filler: the smallest card is roughly +25% of something.
--
-- Delta semantics (applied by Run/Stats.luau):
--   add    -> added to PlayerStats fields
--   mul    -> multiplies PlayerStats fields (stacks compound: 1.4 twice = 1.96)
--   weapon -> added to the class WeaponDef's numeric fields (count, area, ...)
--   heal   -> instant heal as a fraction of max HP, applied by RunDirector when
--             the card is picked (Stats.compute ignores it)
-- Extension (not in Types.StatDelta yet): `abilityMul` multiplies AbilityDef
-- numeric fields (area, damage, duration, distance). Stats.compute applies it.

local Types = require("../Types")

-- Same shape as Types.UpgradeDef plus the optional `abilityMul` extension, so
-- it is usable anywhere a Types.UpgradeDef is expected.
export type UpgradeDef = {
	id: string,
	name: string,
	description: string,
	rarity: Types.Rarity,
	maxStacks: number,
	classOnly: string?,
	delta: Types.StatDelta,
	abilityMul: { [string]: number }?,
}

local Upgrades = {}

Upgrades.RARITIES = { "Common", "Rare", "Epic", "Legendary" } :: { Types.Rarity }

local list: { UpgradeDef } = {
	----------------------------------------------------------------- Common
	{
		id = "heavy_hitter",
		name = "Heavy Hitter",
		description = "+35% damage on everything.",
		rarity = "Common",
		maxStacks = 4,
		delta = { mul = { damageMult = 1.35 } },
	},
	{
		id = "big_trunk",
		name = "Big Trunk",
		description = "+40% area: bigger slams, splashes and puddles.",
		rarity = "Common",
		maxStacks = 3,
		delta = { mul = { areaMult = 1.4 } },
	},
	{
		id = "rapid_fire",
		name = "Rapid Fire",
		description = "+35% attack speed.",
		rarity = "Common",
		maxStacks = 3,
		delta = { mul = { attackSpeedMult = 1.35 } },
	},
	{
		id = "short_fuse",
		name = "Short Fuse",
		description = "-25% ability cooldown.",
		rarity = "Common",
		maxStacks = 3,
		delta = { mul = { cooldownMult = 0.75 } },
	},
	{
		id = "thick_hide",
		name = "Thick Hide",
		description = "+50% max HP and heal to full.",
		rarity = "Common",
		maxStacks = 2,
		delta = { mul = { maxHp = 1.5 }, heal = 1 },
	},
	{
		id = "zoomies",
		name = "Zoomies",
		description = "+25% move speed.",
		rarity = "Common",
		maxStacks = 2,
		delta = { mul = { moveSpeed = 1.25 } },
	},
	{
		id = "cheese_magnet",
		name = "Cheese Magnet",
		description = "Double pickup radius: crumbs fly to you from across the screen.",
		rarity = "Common",
		maxStacks = 2,
		delta = { mul = { pickupRadius = 2 } },
	},
	{
		id = "skewer",
		name = "Skewer",
		description = "Shots pierce 2 more mice.",
		rarity = "Common",
		maxStacks = 3,
		delta = { add = { pierceBonus = 2 } },
	},
	{
		id = "armor_plates",
		name = "Armor Plates",
		description = "Block 3 damage from every hit. Small mice barely scratch you.",
		rarity = "Common",
		maxStacks = 3,
		delta = { add = { armor = 3 } },
	},
	{
		id = "peanut_snack",
		name = "Peanut Butter Snack",
		description = "Regenerate 3 HP every second.",
		rarity = "Common",
		maxStacks = 3,
		delta = { add = { regen = 3 } },
	},
	{
		id = "lucky_tusk",
		name = "Lucky Tusk",
		description = "+20% crit chance.",
		rarity = "Common",
		maxStacks = 3,
		delta = { add = { critChance = 0.2 } },
	},
	{
		id = "bully",
		name = "Bully",
		description = "Hits send mice flying (+10 knockback) and deal +25% damage.",
		rarity = "Common",
		maxStacks = 2,
		delta = { mul = { damageMult = 1.25 }, weapon = { knockback = 10 } },
	},
	{
		id = "long_trunk",
		name = "Long Trunk",
		description = "+12 studs of weapon range.",
		rarity = "Common",
		maxStacks = 2,
		delta = { weapon = { range = 12 } },
	},
	{
		id = "fast_learner",
		name = "Fast Learner",
		description = "+50% XP from crumbs: level up much faster.",
		rarity = "Common",
		maxStacks = 2,
		delta = { mul = { xpMult = 1.5 } },
	},
	{
		id = "glass_tusks",
		name = "Glass Tusks",
		description = "+60% damage, but -25% max HP.",
		rarity = "Common",
		maxStacks = 2,
		delta = { mul = { damageMult = 1.6, maxHp = 0.75 } },
	},
	----------------------------------------------------------------- Rare
	{
		id = "twin_shot",
		name = "Twin Shot",
		description = "+1 projectile (or +1 swing, cleaver or bomb).",
		rarity = "Rare",
		maxStacks = 3,
		delta = { add = { projectileBonus = 1 } },
	},
	{
		id = "static_trunk",
		name = "Static Trunk",
		description = "Hits chain lightning to 2 more mice.",
		rarity = "Rare",
		maxStacks = 2,
		delta = { add = { chain = 2 } },
	},
	{
		id = "pop_mouse",
		name = "Pop Goes the Mouse",
		description = "Kills explode in a 6-stud blast. Stacks make it bigger.",
		rarity = "Rare",
		maxStacks = 3,
		delta = { add = { explodeOnKill = 6 } },
	},
	{
		id = "cheese_vampire",
		name = "Cheese Muncher",
		description = "Heal for 10% of all damage you deal.",
		rarity = "Rare",
		maxStacks = 2,
		delta = { add = { lifesteal = 0.1 } },
	},
	{
		id = "peanut_satellite",
		name = "Peanut Satellite",
		description = "A giant peanut orbits you and smacks mice.",
		rarity = "Rare",
		maxStacks = 3,
		delta = { add = { extraOrbiters = 1 } },
	},
	{
		id = "crushing_blow",
		name = "Crushing Blow",
		description = "Crits deal +150% more damage and +10% crit chance.",
		rarity = "Rare",
		maxStacks = 2,
		delta = { add = { critMult = 1.5, critChance = 0.1 } },
	},
	{
		id = "mega_stomp",
		name = "Mega Stomp",
		description = "+75% area.",
		rarity = "Rare",
		maxStacks = 2,
		delta = { mul = { areaMult = 1.75 } },
	},
	{
		id = "fortress",
		name = "Fortress",
		description = "Double max HP and +3 armor, but -15% move speed.",
		rarity = "Rare",
		maxStacks = 1,
		delta = { mul = { maxHp = 2, moveSpeed = 0.85 }, add = { armor = 3 }, heal = 1 },
	},
	{
		id = "overclock",
		name = "Overclock",
		description = "+60% attack speed.",
		rarity = "Rare",
		maxStacks = 2,
		delta = { mul = { attackSpeedMult = 1.6 } },
	},
	{
		id = "cheese_hoarder",
		name = "Cheese Hoarder",
		description = "+50% cheese from boss chests this run.",
		rarity = "Rare",
		maxStacks = 2,
		delta = { mul = { cheeseMult = 1.5 } },
	},
	{
		id = "four_leaf_peanut",
		name = "Four-Leaf Peanut",
		description = "+2 luck: Epic and Legendary cards show up far more often.",
		rarity = "Rare",
		maxStacks = 2,
		delta = { add = { luck = 2 } },
	},
	{
		id = "ability_spam",
		name = "Ability Spam",
		description = "-40% ability cooldown.",
		rarity = "Rare",
		maxStacks = 2,
		delta = { mul = { cooldownMult = 0.6 } },
	},
	-- Class-only rares
	{
		id = "aftershock",
		name = "Aftershock",
		description = "Trunk Slam reaches 6 studs further and launches mice.",
		rarity = "Rare",
		maxStacks = 2,
		classOnly = "elephante",
		delta = { weapon = { area = 6, range = 6, knockback = 10 } },
	},
	{
		id = "full_quiver",
		name = "Full Quiver",
		description = "Peanut Volley fires 3 more peanuts in a wider fan.",
		rarity = "Rare",
		maxStacks = 2,
		classOnly = "ellie_fawn",
		delta = { weapon = { count = 3, area = 20 } },
	},
	{
		id = "flurry",
		name = "Flurry",
		description = "Rapier thrusts come 0.1 s faster and crit 15% more often.",
		rarity = "Rare",
		maxStacks = 2,
		classOnly = "le_fante",
		delta = { weapon = { cooldown = -0.1 }, add = { critChance = 0.15 } },
	},
	{
		id = "knife_block",
		name = "Knife Block",
		description = "2 more cleavers orbit you, on a wider ring.",
		rarity = "Rare",
		maxStacks = 2,
		classOnly = "filet",
		delta = { weapon = { count = 2, range = 3 } },
	},
	----------------------------------------------------------------- Epic
	{
		id = "peanut_storm",
		name = "Peanut Storm",
		description = "+2 projectiles.",
		rarity = "Epic",
		maxStacks = 2,
		delta = { add = { projectileBonus = 2 } },
	},
	{
		id = "chain_storm",
		name = "Chain Storm",
		description = "Hits chain to 4 more mice.",
		rarity = "Epic",
		maxStacks = 1,
		delta = { add = { chain = 4 } },
	},
	{
		id = "cheese_bombs",
		name = "Cheese Bombs",
		description = "Kills explode in a huge 10-stud blast, and +25% area.",
		rarity = "Epic",
		maxStacks = 1,
		delta = { add = { explodeOnKill = 10 }, mul = { areaMult = 1.25 } },
	},
	{
		id = "giant_elephant",
		name = "Giant Elephant",
		description = "Double area and +50% max HP, but -10% move speed.",
		rarity = "Epic",
		maxStacks = 1,
		delta = { mul = { areaMult = 2, maxHp = 1.5, moveSpeed = 0.9 }, heal = 0.5 },
	},
	{
		id = "berserker",
		name = "Berserker",
		description = "Double damage and +50% attack speed, but -30% max HP.",
		rarity = "Epic",
		maxStacks = 1,
		delta = { mul = { damageMult = 2, attackSpeedMult = 1.5, maxHp = 0.7 } },
	},
	{
		id = "orbit_swarm",
		name = "Orbit Swarm",
		description = "3 peanuts orbit you.",
		rarity = "Epic",
		maxStacks = 1,
		delta = { add = { extraOrbiters = 3 } },
	},
	{
		id = "bloodthirst", -- stable id; the shown name is kid-friendly (SETUP.md §5)
		name = "Hungry Herd",
		description = "Heal for 25% of all damage you deal.",
		rarity = "Epic",
		maxStacks = 1,
		delta = { add = { lifesteal = 0.25 } },
	},
	{
		id = "time_warp",
		name = "Time Warp",
		description = "-50% ability cooldown and +30% attack speed.",
		rarity = "Epic",
		maxStacks = 1,
		delta = { mul = { cooldownMult = 0.5, attackSpeedMult = 1.3 } },
	},
	{
		id = "mega_ability",
		name = "Mega Ability",
		description = "Your ability is twice as big and hits 50% harder.",
		rarity = "Epic",
		maxStacks = 1,
		delta = {},
		abilityMul = { area = 2, damage = 1.5 },
	},
	-- Class-only epics
	{
		id = "fire_hose",
		name = "Fire Hose",
		description = "Water Jet fires 2 extra jets that pierce 3 more mice.",
		rarity = "Epic",
		maxStacks = 1,
		classOnly = "ele_fonte",
		delta = { weapon = { count = 2, pierce = 3 } },
	},
	{
		id = "hurricane_ears",
		name = "Hurricane Ears",
		description = "Ear Gust becomes a 120-degree hurricane with huge knockback.",
		rarity = "Epic",
		maxStacks = 1,
		classOnly = "jumbo",
		delta = { weapon = { area = 50, knockback = 15, damage = 10 } },
	},
	{
		id = "cluster_fizz",
		name = "Cluster Fizz",
		description = "Lob 3 Fizz Bombs at once, each with a bigger blast.",
		rarity = "Epic",
		maxStacks = 1,
		classOnly = "fizzante",
		delta = { weapon = { count = 2, area = 3 } },
	},
	----------------------------------------------------------------- Legendary
	{
		id = "trunkquake",
		name = "Trunkquake",
		description = "Double damage, +2 projectiles and +50% area.",
		rarity = "Legendary",
		maxStacks = 1,
		delta = { mul = { damageMult = 2, areaMult = 1.5 }, add = { projectileBonus = 2 } },
	},
	{
		id = "lightning_herd",
		name = "Lightning Herd",
		description = "Hits chain to 8 more mice and every kill explodes.",
		rarity = "Legendary",
		maxStacks = 1,
		delta = { add = { chain = 8, explodeOnKill = 8 } },
	},
	{
		id = "mammoth",
		name = "Mammoth",
		description = "Triple max HP, +5 armor, +5 HP/s regen, and heal to full.",
		rarity = "Legendary",
		maxStacks = 1,
		delta = { mul = { maxHp = 3 }, add = { armor = 5, regen = 5 }, heal = 1 },
	},
	{
		id = "golden_trunk",
		name = "Golden Trunk",
		description = "+5 luck, double cheese and double XP.",
		rarity = "Legendary",
		maxStacks = 1,
		delta = { add = { luck = 5 }, mul = { cheeseMult = 2, xpMult = 2 } },
	},
}

local byId: { [string]: UpgradeDef } = {}
for _, def in list do
	assert(byId[def.id] == nil, "duplicate upgrade id " .. def.id)
	byId[def.id] = def
end

Upgrades.list = list
Upgrades.byId = byId

function Upgrades.get(id: string): UpgradeDef?
	return byId[id]
end

return Upgrades
