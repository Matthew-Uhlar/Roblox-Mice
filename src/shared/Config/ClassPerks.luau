--!strict
-- Per-class perk trees (GDD-v2 §5, team R3). Pure data, loads in Lune.
--
-- Every class has 3 themed branches x 5 tiers. Rules (Data/ClassProgress):
--   * 1 perk point per class level after the first (level 30 = 29 points).
--   * A tier-t perk costs t points (ClassPerks.COST[t]) and needs the tier t-1 perk of
--     the same branch (so "t-1 points already spent in that branch" always holds and
--     tiers unlock in order). One branch costs 15 points, the whole tree 45, so a
--     level-30 hero (29 points) fills about two branches: builds still differ.
--   * Respec (Data/ClassProgress.respecCost) refunds every point for cheese.
--
-- Effects are StatDelta data that Run/Stats.compute applies (as entries, like
-- talents): `delta.add` / `delta.mul` on PlayerStats, `delta.weapon` flat weapon
-- deltas, and `abilityMul` on the hero's ability (whichever ability is equipped).
-- `behaviour` flags the perks that add a small new behaviour through a stat World
-- already supports (chain, explodeOnKill, lifesteal, extraOrbiters, pierceBonus).
--
-- Power budget: a single perk is +4..12% on one stat (never bigger than an Epic
-- upgrade card); a full branch is roughly +12..15% "overall power", and the best
-- 29-point build of every class lands at about +25..30% (DataClassProgress.spec
-- checks this with a power index).

local Types = require("../Types")

type StatDelta = Types.StatDelta

export type Behaviour = "chain" | "explodeOnKill" | "lifesteal" | "extraOrbiters" | "pierceBonus"

export type PerkDef = {
	id: string, -- "<classId>_<branchId>_<tier>"
	classId: string,
	branch: string, -- branch id
	branchIndex: number, -- 1..3
	tier: number, -- 1..5
	cost: number, -- perk points
	name: string,
	description: string,
	delta: StatDelta,
	abilityMul: { [string]: number }?, -- multiplies AbilityDef numeric fields
	behaviour: Behaviour?,
}

export type BranchDef = {
	id: string,
	name: string,
	theme: string,
	perks: { PerkDef }, -- tier order, 5 entries
}

local ClassPerks = {}

ClassPerks.TIERS = 5
ClassPerks.BRANCHES_PER_CLASS = 3
ClassPerks.COST = table.freeze({ 1, 2, 3, 4, 5 })

type Spec = {
	name: string,
	desc: string,
	delta: StatDelta?,
	ability: { [string]: number }?,
	behaviour: Behaviour?,
}

type BranchSpec = { id: string, name: string, theme: string, perks: { Spec } }

local function p(
	name: string,
	desc: string,
	delta: StatDelta?,
	ability: { [string]: number }?,
	behaviour: Behaviour?
): Spec
	return { name = name, desc = desc, delta = delta, ability = ability, behaviour = behaviour }
end

local SPECS: { [string]: { BranchSpec } } = {
	elephante = {
		{
			id = "bulwark",
			name = "Bulwark",
			theme = "Stand your ground: health and armour.",
			perks = {
				p("Thick Plating", "+8% max HP.", { mul = { maxHp = 1.08 } }),
				p("Rind Guard", "+1 armour.", { add = { armor = 1 } }),
				p("Second Stomach", "+0.5 HP regeneration per second.", { add = { regen = 0.5 } }),
				p("Iron Hide", "+6% max HP and +1 armour.", { mul = { maxHp = 1.06 }, add = { armor = 1 } }),
				p(
					"Unbreakable",
					"Heal 3% of the damage you deal.",
					{ add = { lifesteal = 0.03 } },
					nil,
					"lifesteal"
				),
			},
		},
		{
			id = "stampede",
			name = "Stampede",
			theme = "Charge harder: a stronger, faster ability.",
			perks = {
				p("Long Charge", "+12% ability reach.", nil, { distance = 1.12 }),
				p("Trample", "+10% ability damage.", nil, { damage = 1.1 }),
				p("Quick Hooves", "-8% ability cooldown.", { mul = { cooldownMult = 0.92 } }),
				p(
					"Thunder Run",
					"+4% move speed and +10% ability area.",
					{ mul = { moveSpeed = 1.04 } },
					{ area = 1.1 }
				),
				p(
					"Rampage",
					"Mice you defeat burst in a small shockwave.",
					{ add = { explodeOnKill = 4 } },
					nil,
					"explodeOnKill"
				),
			},
		},
		{
			id = "trumpeter",
			name = "Trumpeter",
			theme = "Blast them: trunk damage and reach.",
			perks = {
				p("Wide Swing", "+6% area.", { mul = { areaMult = 1.06 } }),
				p("Heavy Trunk", "+5% damage.", { mul = { damageMult = 1.05 } }),
				p(
					"Blare",
					"+4% attack speed and more knockback.",
					{ mul = { attackSpeedMult = 1.04 }, weapon = { knockback = 2 } }
				),
				p("Brass Lungs", "+4% damage.", { mul = { damageMult = 1.04 } }),
				p(
					"Fanfare",
					"Your first hit each swing chains to 1 more mouse.",
					{ add = { chain = 1 } },
					nil,
					"chain"
				),
			},
		},
	},
	ele_fonte = {
		{
			id = "torrent",
			name = "Torrent",
			theme = "Firehose: faster, harder water jets.",
			perks = {
				p("Pressure Jet", "+5% damage.", { mul = { damageMult = 1.05 } }),
				p("Rapid Flow", "+5% attack speed.", { mul = { attackSpeedMult = 1.05 } }),
				p(
					"Deep Current",
					"Jets pierce 1 more mouse.",
					{ add = { pierceBonus = 1 } },
					nil,
					"pierceBonus"
				),
				p(
					"Hydro Lance",
					"+4% damage and +4 range.",
					{ mul = { damageMult = 1.04 }, weapon = { range = 4 } }
				),
				p(
					"Splitstream",
					"Each jet's first hit splashes 1 more mouse.",
					{ add = { chain = 1 } },
					nil,
					"chain"
				),
			},
		},
		{
			id = "wellspring",
			name = "Wellspring",
			theme = "A fountain never runs dry: healing and health.",
			perks = {
				p("Cool Mist", "+8% max HP.", { mul = { maxHp = 1.08 } }),
				p("Spring Water", "+0.6 HP regeneration per second.", { add = { regen = 0.6 } }),
				p("Bubble Skin", "+1 armour.", { add = { armor = 1 } }),
				p(
					"Font of Life",
					"+5% max HP and +0.3 regeneration.",
					{ mul = { maxHp = 1.05 }, add = { regen = 0.3 } }
				),
				p(
					"Lifeblood",
					"Heal 3% of the damage you deal.",
					{ add = { lifesteal = 0.03 } },
					nil,
					"lifesteal"
				),
			},
		},
		{
			id = "geyser",
			name = "Geyser",
			theme = "Bigger eruptions: ability power.",
			perks = {
				p("Higher Spout", "+10% ability damage.", nil, { damage = 1.1 }),
				p("Wide Splash", "+10% ability area.", nil, { area = 1.1 }),
				p("Quick Refill", "-8% ability cooldown.", { mul = { cooldownMult = 0.92 } }),
				p(
					"Long Shot",
					"+15% ability reach and -4% cooldown.",
					{ mul = { cooldownMult = 0.96 } },
					{ distance = 1.15 }
				),
				p(
					"Undertow",
					"Mice you defeat burst in a small splash.",
					{ add = { explodeOnKill = 4 } },
					nil,
					"explodeOnKill"
				),
			},
		},
	},
	ellie_fawn = {
		{
			id = "sharpshot",
			name = "Sharpshot",
			theme = "Every peanut counts: damage and crits.",
			perks = {
				p("Fresh Peanuts", "+5% damage.", { mul = { damageMult = 1.05 } }),
				p("Quick Draw", "+5% attack speed.", { mul = { attackSpeedMult = 1.05 } }),
				p("Keen Eye", "+4% crit chance.", { add = { critChance = 0.04 } }),
				p("Hard Shells", "+4% damage.", { mul = { damageMult = 1.04 } }),
				p(
					"Piercing Shot",
					"Peanuts pierce 1 more mouse.",
					{ add = { pierceBonus = 1 } },
					nil,
					"pierceBonus"
				),
			},
		},
		{
			id = "thicket",
			name = "Thicket",
			theme = "The forest fights back: thorns and bark.",
			perks = {
				p("Sharper Thorns", "+10% ability damage.", nil, { damage = 1.1 }),
				p("Wider Ring", "+10% ability area.", nil, { area = 1.1 }),
				p("Overgrowth", "+15% ability duration.", nil, { duration = 1.15 }),
				p("Bark Skin", "+1 armour and +5% max HP.", { add = { armor = 1 }, mul = { maxHp = 1.05 } }),
				p(
					"Bramble Burst",
					"Mice you defeat burst into thorns.",
					{ add = { explodeOnKill = 4 } },
					nil,
					"explodeOnKill"
				),
			},
		},
		{
			id = "wayfinder",
			name = "Wayfinder",
			theme = "Know the woods: speed and sustain.",
			perks = {
				p("Fleet Foot", "+5% move speed.", { mul = { moveSpeed = 1.05 } }),
				p("Forager", "+12% pickup radius.", { mul = { pickupRadius = 1.12 } }),
				p(
					"Trail Rations",
					"+0.5 regeneration and +5% max HP.",
					{ add = { regen = 0.5 }, mul = { maxHp = 1.05 } }
				),
				p("Light Step", "-8% ability cooldown.", { mul = { cooldownMult = 0.92 } }),
				p(
					"Hunter's Mark",
					"Your first hit each volley chains to 1 more mouse.",
					{ add = { chain = 1 } },
					nil,
					"chain"
				),
			},
		},
	},
	le_fante = {
		{
			id = "panache",
			name = "Panache",
			theme = "Style is substance: crits.",
			perks = {
				p("Precision", "+4% crit chance.", { add = { critChance = 0.04 } }),
				p("Coup de Grace", "+0.2 crit damage.", { add = { critMult = 0.2 } }),
				p("Fine Edge", "+4% damage.", { mul = { damageMult = 1.04 } }),
				p(
					"Killer Instinct",
					"+3% crit chance and +0.1 crit damage.",
					{ add = { critChance = 0.03, critMult = 0.1 } }
				),
				p(
					"Riposte Chain",
					"Your first hit each thrust chains to 1 more mouse.",
					{ add = { chain = 1 } },
					nil,
					"chain"
				),
			},
		},
		{
			id = "en_garde",
			name = "En Garde",
			theme = "The best offence is a perfect parry.",
			perks = {
				p("Parry Practice", "+15% ability duration.", nil, { duration = 1.15 }),
				p("Counterstrike", "+10% ability damage.", nil, { damage = 1.1 }),
				p("Guarded", "+1 armour.", { add = { armor = 1 } }),
				p("Steel Nerves", "+8% max HP.", { mul = { maxHp = 1.08 } }),
				p(
					"Vampiric Blade",
					"Heal 3% of the damage you deal.",
					{ add = { lifesteal = 0.03 } },
					nil,
					"lifesteal"
				),
			},
		},
		{
			id = "flourish",
			name = "Flourish",
			theme = "Never stand still: footwork and tempo.",
			perks = {
				p("Footwork", "+5% move speed.", { mul = { moveSpeed = 1.05 } }),
				p("Quick Thrust", "+4% attack speed.", { mul = { attackSpeedMult = 1.04 } }),
				p("Long Lunge", "+1.5 thrust range.", { weapon = { range = 1.5 } }),
				p("Tempo", "-8% ability cooldown.", { mul = { cooldownMult = 0.92 } }),
				p(
					"Whirling Rapier",
					"A spare rapier orbits you (60% weapon damage).",
					{ add = { extraOrbiters = 1 } },
					nil,
					"extraOrbiters"
				),
			},
		},
	},
	filet = {
		{
			id = "butcher",
			name = "Butcher",
			theme = "Sharper, faster cleavers.",
			perks = {
				p("Sharpened Cleavers", "+5% damage.", { mul = { damageMult = 1.05 } }),
				p("Faster Spin", "+5% attack speed.", { mul = { attackSpeedMult = 1.05 } }),
				p("Wide Chop", "+6% area.", { mul = { areaMult = 1.06 } }),
				p("Heavy Blades", "+4% damage.", { mul = { damageMult = 1.04 } }),
				p(
					"Tenderizer",
					"Mice you defeat burst in a small splash.",
					{ add = { explodeOnKill = 4 } },
					nil,
					"explodeOnKill"
				),
			},
		},
		{
			id = "saucier",
			name = "Saucier",
			theme = "Master of the hot pan: ability power.",
			perks = {
				p("Hotter Oil", "+10% ability damage.", nil, { damage = 1.1 }),
				p("Bigger Pan", "+10% ability area.", nil, { area = 1.1 }),
				p("Slow Simmer", "+15% ability duration.", nil, { duration = 1.15 }),
				p("Prep Cook", "-8% ability cooldown.", { mul = { cooldownMult = 0.92 } }),
				p(
					"Boiling Point",
					"+12% ability damage and +10% ability reach.",
					nil,
					{ damage = 1.12, distance = 1.1 }
				),
			},
		},
		{
			id = "taste_tester",
			name = "Taste Tester",
			theme = "A chef never goes hungry: health and healing.",
			perks = {
				p("Hearty Meal", "+8% max HP.", { mul = { maxHp = 1.08 } }),
				p("Seasoned", "+0.4 HP regeneration per second.", { add = { regen = 0.4 } }),
				p("Apron", "+1 armour.", { add = { armor = 1 } }),
				p("Second Helping", "+6% max HP.", { mul = { maxHp = 1.06 } }),
				p(
					"Chef's Kiss",
					"Heal 3% of the damage you deal.",
					{ add = { lifesteal = 0.03 } },
					nil,
					"lifesteal"
				),
			},
		},
	},
	jumbo = {
		{
			id = "gale",
			name = "Gale",
			theme = "Flap harder: gust damage and size.",
			perks = {
				p("Strong Flap", "+5% damage.", { mul = { damageMult = 1.05 } }),
				p("Wider Gust", "+6% area.", { mul = { areaMult = 1.06 } }),
				p("Gust Rhythm", "+5% attack speed.", { mul = { attackSpeedMult = 1.05 } }),
				p(
					"Hurricane",
					"+4% damage and more knockback.",
					{ mul = { damageMult = 1.04 }, weapon = { knockback = 3 } }
				),
				p(
					"Static Ears",
					"Your first hit each gust chains to 1 more mouse.",
					{ add = { chain = 1 } },
					nil,
					"chain"
				),
			},
		},
		{
			id = "skyborne",
			name = "Skyborne",
			theme = "Own the sky: ability and mobility.",
			perks = {
				p("Longer Flight", "+15% ability duration.", nil, { duration = 1.15 }),
				p("Landing Gust", "+10% ability damage.", nil, { damage = 1.1 }),
				p("Tailwind", "+5% move speed.", { mul = { moveSpeed = 1.05 } }),
				p("Quick Takeoff", "-8% ability cooldown.", { mul = { cooldownMult = 0.92 } }),
				p(
					"Thunderclap",
					"Mice you defeat burst in a small gust.",
					{ add = { explodeOnKill = 4 } },
					nil,
					"explodeOnKill"
				),
			},
		},
		{
			id = "big_ears",
			name = "Big Ears",
			theme = "Hear everything, shrug it off.",
			perks = {
				p("Crumb Radar", "+15% pickup radius.", { mul = { pickupRadius = 1.15 } }),
				p("Soft Landing", "+8% max HP.", { mul = { maxHp = 1.08 } }),
				p("Thick Ears", "+1 armour.", { add = { armor = 1 } }),
				p(
					"Big Heart",
					"+5% max HP and +0.4 regeneration.",
					{ mul = { maxHp = 1.05 }, add = { regen = 0.4 } }
				),
				p(
					"Echo Ears",
					"Heal 3% of the damage you deal.",
					{ add = { lifesteal = 0.03 } },
					nil,
					"lifesteal"
				),
			},
		},
	},
	fizzante = {
		{
			id = "volatile",
			name = "Volatile",
			theme = "More bang per bottle.",
			perks = {
				p("Stronger Mix", "+5% damage.", { mul = { damageMult = 1.05 } }),
				p("Bigger Bang", "+6% area.", { mul = { areaMult = 1.06 } }),
				p("Quick Shake", "+5% attack speed.", { mul = { attackSpeedMult = 1.05 } }),
				p("Nitro", "+4% damage.", { mul = { damageMult = 1.04 } }),
				p(
					"Fizz Chain",
					"Each bomb's first hit arcs to 1 more mouse.",
					{ add = { chain = 1 } },
					nil,
					"chain"
				),
			},
		},
		{
			id = "carbonation",
			name = "Carbonation",
			theme = "Stickier, longer-lasting soda.",
			perks = {
				p("Stickier Soda", "+10% ability area.", nil, { area = 1.1 }),
				p("Acidic", "+10% ability damage.", nil, { damage = 1.1 }),
				p("Long Fizz", "+15% ability duration.", nil, { duration = 1.15 }),
				p("Quick Brew", "-8% ability cooldown.", { mul = { cooldownMult = 0.92 } }),
				p(
					"Chain Reaction",
					"Mice you defeat pop in a fizzy burst.",
					{ add = { explodeOnKill = 5 } },
					nil,
					"explodeOnKill"
				),
			},
		},
		{
			id = "lab_coat",
			name = "Lab Coat",
			theme = "Safety first: health and armour.",
			perks = {
				p("Padded Coat", "+8% max HP.", { mul = { maxHp = 1.08 } }),
				p("Goggles", "+1 armour.", { add = { armor = 1 } }),
				p("Antidote", "+0.5 HP regeneration per second.", { add = { regen = 0.5 } }),
				p(
					"Hazmat Suit",
					"+5% max HP and +1 armour.",
					{ mul = { maxHp = 1.05 }, add = { armor = 1 } }
				),
				p(
					"Elixir",
					"Heal 3% of the damage you deal.",
					{ add = { lifesteal = 0.03 } },
					nil,
					"lifesteal"
				),
			},
		},
	},
}

local byId: { [string]: PerkDef } = {}
local branches: { [string]: { BranchDef } } = {}

for classId, list in SPECS do
	local out: { BranchDef } = {}
	for bi, b in list do
		local perks: { PerkDef } = {}
		for tier, s in b.perks do
			local def: PerkDef = {
				id = classId .. "_" .. b.id .. "_" .. tier,
				classId = classId,
				branch = b.id,
				branchIndex = bi,
				tier = tier,
				cost = ClassPerks.COST[tier],
				name = s.name,
				description = s.desc,
				delta = s.delta or {},
				abilityMul = s.ability,
				behaviour = s.behaviour,
			}
			table.insert(perks, def)
			byId[def.id] = def
		end
		table.insert(out, { id = b.id, name = b.name, theme = b.theme, perks = perks })
	end
	branches[classId] = out
end

ClassPerks.byId = byId

function ClassPerks.get(perkId: any): PerkDef?
	if type(perkId) ~= "string" then
		return nil
	end
	return byId[perkId]
end

-- The 3 branches of a class (empty list for an unknown class).
function ClassPerks.branches(classId: string): { BranchDef }
	return branches[classId] or {}
end

-- All perks of a class in branch, then tier order.
function ClassPerks.forClass(classId: string): { PerkDef }
	local out = {}
	for _, b in ClassPerks.branches(classId) do
		for _, def in b.perks do
			table.insert(out, def)
		end
	end
	return out
end

-- The perk one tier below `def` in the same branch (nil for tier 1).
function ClassPerks.previous(def: PerkDef): PerkDef?
	if def.tier <= 1 then
		return nil
	end
	local b = ClassPerks.branches(def.classId)[def.branchIndex]
	return if b then b.perks[def.tier - 1] else nil
end

-- Points for a whole branch / the whole tree of one class.
function ClassPerks.branchCost(): number
	local n = 0
	for _, c in ClassPerks.COST do
		n += c
	end
	return n
end

return ClassPerks
