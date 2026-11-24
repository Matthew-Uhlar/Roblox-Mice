--!strict
-- Per-class talent trees (iteration 6, team Talents; replaces the 3 x 5 perk ladders of
-- GDD-v2 §5). Pure data, loads in Lune.
--
-- Every class has 3 themed branches of 9 nodes on 5 rows:
--
--   row 1   A (3 ranks)            B (2 ranks)        gate  0
--   row 2   C (3 ranks, needs A)   D (1 rank, needs B) gate 3
--   row 3   E1  -- choose one --   E2                 gate 6   (needs C or D)
--   row 4   F (2 ranks)            G (2 ranks)        gate 9   (needs E1 or E2)
--   row 5           K  KEYSTONE  (1 rank)             gate 12  (needs F or G)
--
--   * Every rank costs 1 perk point. A node's `gate` is the points already spent in
--     the LOWER rows of its branch; `requires` = any one of those nodes taken.
--   * E1 / E2 are mutually exclusive (`exclusive` group). A full branch is exactly 15
--     points, the whole tree 45 = the points of a level-30 hero at Prestige 16
--     (Data/ClassProgress.perkPoints, unchanged).
--   * Keystones change how the class plays (Config/Keystones mechanics: empowered
--     attacks, shards, auras, orbs, novas, charges, frenzy, last stand, ...). Their
--     damage hits mice only (never heroes); stat nodes work like the old perks.
--
-- Saved shape (unchanged, Types.ClassState.perks): { [key] = true }. Rank 1 of a node
-- is its id, rank r >= 2 is "<id>#r". Old perk ids "<class>_<branch>_<tier>" (the 3 x 5
-- ladders) are LEGACY: Data/ClassProgress.sanitizePerks turns a branch's old tiers 1..d
-- (d(d+1)/2 points) into the same number of points in the same branch, along
-- ClassPerks.PATH (so an old full branch becomes a new full branch, keystone included).
--
-- Effects are StatDelta data per rank that Run/Stats.compute applies like talents
-- (adds, then muls; `ability` = abilityMul on every equipped slot).

local Types = require("../Types")
local Keystones = require("./Keystones")

type StatDelta = Types.StatDelta

export type NodeKind = "stat" | "minor" | "choice" | "keystone"

export type PerkDef = {
	id: string, -- "<classId>_<branchId>_<key>"
	key: string, -- "a" | "b" | "c" | "d" | "e1" | "e2" | "f" | "g" | "k"
	classId: string,
	branch: string,
	branchIndex: number, -- 1..3
	tier: number, -- row 1..5
	col: number, -- 1..3 (layout column)
	maxRank: number,
	cost: number, -- points per rank (1)
	gate: number, -- points in this branch's lower rows needed first
	requires: { string }, -- node ids; any one taken (empty = none)
	exclusive: string?, -- group id: only one node of the group
	kind: NodeKind,
	name: string,
	description: string, -- per rank, exact numbers
	delta: StatDelta, -- per rank
	abilityMul: { [string]: number }?, -- per rank
	behaviour: string?, -- the main mechanic / behaviour field (keystones, minors)
}

export type BranchDef = {
	id: string,
	name: string,
	theme: string,
	nodes: { PerkDef }, -- row order (a, b, c, d, e1, e2, f, g, k)
	perks: { PerkDef }, -- alias of nodes (older callers)
	keystone: PerkDef,
}

local ClassPerks = {}

ClassPerks.TIERS = 5
ClassPerks.BRANCHES_PER_CLASS = 3
ClassPerks.KEYS = table.freeze({ "a", "b", "c", "d", "e1", "e2", "f", "g", "k" })
ClassPerks.RANKS = table.freeze({ a = 3, b = 2, c = 3, d = 1, e1 = 1, e2 = 1, f = 2, g = 2, k = 1 })
ClassPerks.ROW = table.freeze({ a = 1, b = 1, c = 2, d = 2, e1 = 3, e2 = 3, f = 4, g = 4, k = 5 })
ClassPerks.COL = table.freeze({ a = 1, b = 3, c = 1, d = 3, e1 = 1, e2 = 3, f = 1, g = 3, k = 2 })
ClassPerks.GATE = table.freeze({ 0, 3, 6, 9, 12 }) -- per row
ClassPerks.REQUIRES = table.freeze({
	c = { "a" },
	d = { "b" },
	e1 = { "c", "d" },
	e2 = { "c", "d" },
	f = { "e1", "e2" },
	g = { "e1", "e2" },
	k = { "f", "g" },
})
ClassPerks.BRANCH_POINTS = 15
ClassPerks.TREE_POINTS = 45
-- Migration / bot order of one branch: 15 ranks, every prefix is a legal build.
ClassPerks.PATH = table.freeze({ "a", "a", "a", "b", "b", "c", "c", "c", "d", "e1", "f", "g", "k", "f", "g" })
ClassPerks.LEGACY_TIERS = 5 -- old ids "<class>_<branch>_1..5" (tier t cost t points)
ClassPerks.RANK_SEP = "#"

type NSpec = { name: string, delta: StatDelta?, ability: { [string]: number }?, text: string? }
type BSpec = {
	id: string,
	name: string,
	theme: string,
	a: NSpec,
	b: NSpec,
	c: NSpec,
	d: NSpec,
	e1: NSpec,
	e2: NSpec,
	f: NSpec,
	g: NSpec,
	k: NSpec,
}

local function N(name: string, delta: StatDelta?, ability: { [string]: number }?, text: string?): NSpec
	return { name = name, delta = delta, ability = ability, text = text }
end
local function mul(t: { [string]: number }): StatDelta
	return { mul = t }
end
local function add(t: { [string]: number }): StatDelta
	return { add = t }
end
local function both(a: { [string]: number }, m: { [string]: number }): StatDelta
	return { add = a, mul = m }
end

-- Shared node shapes (per rank) ---------------------------------------------------------
local DMG = function(v: number): StatDelta
	return mul({ damageMult = 1 + v })
end
local AS = function(v: number): StatDelta
	return mul({ attackSpeedMult = 1 + v })
end
local HP = function(v: number): StatDelta
	return mul({ maxHp = 1 + v })
end
local AREA = function(v: number): StatDelta
	return mul({ areaMult = 1 + v })
end
local CDR = function(v: number): StatDelta
	return mul({ cooldownMult = 1 - v })
end
local SPD = function(v: number): StatDelta
	return mul({ moveSpeed = 1 + v })
end

local SPECS: { [string]: { BSpec } } = {
	elephante = {
		{
			id = "bulwark",
			name = "Bulwark",
			theme = "Stand your ground: health, armour and payback.",
			a = N("Thick Plating", HP(0.03)),
			b = N("Rind Guard", add({ armor = 0.5 })),
			c = N("Second Stomach", add({ regen = 0.25 })),
			d = N("Unbreakable", add({ lifesteal = 0.02 })),
			e1 = N("Iron Hide", both({ armor = 1 }, { maxHp = 1.04 })),
			e2 = N("Last Stand", add({ tkLastStand = 0.25 })),
			f = N("Mountain Heart", HP(0.03)),
			g = N("Shoulder Check", nil, { damage = 1.06, area = 1.04 }),
			k = N("Iron Mountain", add({ tkRetaliate = 1.5, armor = 1 })),
		},
		{
			id = "stampede",
			name = "Stampede",
			theme = "Charge harder: abilities that never stop.",
			a = N("Long Charge", nil, { distance = 1.05 }),
			b = N("Quick Hooves", CDR(0.03)),
			c = N("Trample", nil, { damage = 1.05 }),
			d = N("Thunder Run", SPD(0.03)),
			e1 = N("Momentum", add({ tkCharge = 1 })),
			e2 = N("Hoof Guard", add({ tkGuard = 0.25 })),
			f = N("Herd Rhythm", CDR(0.03)),
			g = N("Rampage", nil, { damage = 1.06, area = 1.05 }),
			k = N("Rolling Thunder", add({ tkCharges = 1, tkCharge = 1 })),
		},
		{
			id = "trumpeter",
			name = "Trumpeter",
			theme = "Blast them: trunk damage and reach.",
			a = N("Heavy Trunk", DMG(0.02)),
			b = N("Wide Swing", AREA(0.03)),
			c = N("Brass Lungs", AS(0.02)),
			d = N("Fanfare", add({ chain = 1 })),
			e1 = N("Encore", add({ chain = 1 })),
			e2 = N("Shockwave", add({ explodeOnKill = 4 })),
			f = N("Blare", both({}, { damageMult = 1.02, attackSpeedMult = 1.02 })),
			g = N("Rallying Call", nil, { damage = 1.06 }),
			k = N("Fanfare Finale", add({ tkEmpower = 4 })),
		},
	},
	ele_fonte = {
		{
			id = "torrent",
			name = "Torrent",
			theme = "Firehose: faster, harder water jets.",
			a = N("Pressure Jet", DMG(0.02)),
			b = N("Rapid Flow", AS(0.025)),
			c = N("Hydro Lance", both({}, { damageMult = 1.015 })),
			d = N("Deep Current", add({ pierceBonus = 1 })),
			e1 = N("Ricochet", add({ chain = 1 })),
			e2 = N("Undertow", add({ explodeOnKill = 4 })),
			f = N("High Pressure", AS(0.025)),
			g = N("Bigger Spout", nil, { damage = 1.06 }),
			k = N("Splitstream", add({ tkShards = 2 })),
		},
		{
			id = "wellspring",
			name = "Wellspring",
			theme = "A fountain never runs dry: healing and health.",
			a = N("Cool Mist", HP(0.03)),
			b = N("Spring Water", add({ regen = 0.3 })),
			c = N("Bubble Skin", add({ armor = 0.5 })),
			d = N("Wellspring Heart", add({ lifesteal = 0.02 })),
			e1 = N("Refreshing", add({ tkKillHeal = 0.004 })),
			e2 = N("Font of Life", both({ regen = 0.5 }, { maxHp = 1.03 })),
			f = N("Deep Well", HP(0.03)),
			g = N("Healing Rain", nil, { area = 1.05, duration = 1.06 }),
			k = N("Fountain of Youth", add({ tkLastStand = 0.4, tkKillHeal = 0.003 })),
		},
		{
			id = "geyser",
			name = "Geyser",
			theme = "Bigger eruptions: ability power.",
			a = N("Higher Spout", nil, { damage = 1.04 }),
			b = N("Quick Refill", CDR(0.03)),
			c = N("Wide Splash", nil, { area = 1.04 }),
			d = N("Long Shot", nil, { distance = 1.1 }),
			e1 = N("Pressure Release", add({ tkCharge = 1 })),
			e2 = N("Spring Loaded", add({ tkCdKill = 0.1 })),
			f = N("Boiling Point", CDR(0.03)),
			g = N("Eruption", nil, { damage = 1.06, area = 1.04 }),
			k = N("Old Faithful", add({ tkNova = 7 })),
		},
	},
	ellie_fawn = {
		{
			id = "sharpshot",
			name = "Sharpshot",
			theme = "Every peanut counts: damage and crits.",
			a = N("Fresh Peanuts", DMG(0.02)),
			b = N("Keen Eye", add({ critChance = 0.02 })),
			c = N("Quick Draw", AS(0.02)),
			d = N("Piercing Shot", add({ pierceBonus = 1 })),
			e1 = N("Hard Shells", add({ critMult = 0.25 })),
			e2 = N("Ricochet Nut", add({ chain = 1 })),
			f = N("Steady Aim", DMG(0.02)),
			g = N("Thorn Volley", nil, { damage = 1.06 }),
			k = N("Golden Peanut", add({ tkEmpower = 5, pierceBonus = 1 })),
		},
		{
			id = "thicket",
			name = "Thicket",
			theme = "The forest fights back: thorns and bark.",
			a = N("Sharper Thorns", nil, { damage = 1.04 }),
			b = N("Bark Skin", add({ armor = 0.5 })),
			c = N("Overgrowth", nil, { duration = 1.05 }),
			d = N("Bramble Burst", add({ explodeOnKill = 4 })),
			e1 = N("Wider Ring", nil, { area = 1.1 }),
			e2 = N("Thornhide", add({ tkRetaliate = 0.8 })),
			f = N("Old Growth", HP(0.03)),
			g = N("Strangle Vine", nil, { damage = 1.06, duration = 1.04 }),
			k = N("Bramble Aura", add({ tkAura = 0.35 })),
		},
		{
			id = "wayfinder",
			name = "Wayfinder",
			theme = "Know the woods: speed, sustain and the hunt.",
			a = N("Fleet Foot", SPD(0.02)),
			b = N("Forager", mul({ pickupRadius = 1.06 })),
			c = N("Light Step", CDR(0.025)),
			d = N("Trail Rations", add({ regen = 0.4 })),
			e1 = N("Hunter's Mark", add({ chain = 1 })),
			e2 = N("Second Breath", add({ tkLastStand = 0.25 })),
			f = N("Pathfinder", AS(0.025)),
			g = N("Thorn Dash", nil, { damage = 1.05, area = 1.04 }),
			k = N("Hunter's Rush", add({ tkFrenzy = 0.03 })),
		},
	},
	le_fante = {
		{
			id = "panache",
			name = "Panache",
			theme = "Style is substance: crits and the finishing touch.",
			a = N("Precision", add({ critChance = 0.02 })),
			b = N("Coup de Grace", add({ critMult = 0.1 })),
			c = N("Fine Edge", DMG(0.02)),
			d = N("Riposte Chain", add({ chain = 1 })),
			e1 = N("Sharp Instinct", add({ critChance = 0.04 })),
			e2 = N("Merciless", add({ tkExecute = 0.08 })),
			f = N("Flair", add({ critMult = 0.1 })),
			g = N("Grand Riposte", nil, { damage = 1.06 }),
			k = N("Coup de Maître", add({ tkExecute = 0.15, critChance = 0.03 })),
		},
		{
			id = "en_garde",
			name = "En Garde",
			theme = "The best offence is a perfect parry.",
			a = N("Parry Practice", nil, { duration = 1.05 }),
			b = N("Guarded", add({ armor = 0.5 })),
			c = N("Steel Nerves", HP(0.03)),
			d = N("Cheese-Leech Blade", add({ lifesteal = 0.02 })),
			e1 = N("Counterstrike", add({ tkCharge = 2 })),
			e2 = N("Iron Wrist", add({ tkGuard = 0.3 })),
			f = N("Unshaken", HP(0.03)),
			g = N("Perfect Parry", nil, { damage = 1.06, area = 1.04 }),
			k = N("Riposte Royale", add({ tkGuard = 0.35, tkCharge = 2 })),
		},
		{
			id = "flourish",
			name = "Flourish",
			theme = "Never stand still: footwork and tempo.",
			a = N("Footwork", SPD(0.02)),
			b = N("Quick Thrust", AS(0.02)),
			c = N("Tempo", CDR(0.025)),
			d = N("Long Lunge", { weapon = { range = 1.5 } }),
			e1 = N("Whirling Rapier", add({ extraOrbiters = 1 })),
			e2 = N("Encore", add({ tkCdKill = 0.1 })),
			f = N("Dancer", AS(0.02)),
			g = N("Flèche", nil, { damage = 1.05, distance = 1.05 }),
			k = N("Ballet of Blades", add({ tkCombo = 0.3, tkCdKill = 0.1 })),
		},
	},
	filet = {
		{
			id = "butcher", -- stable id (saved perk ids); the shown name is kid-friendly
			name = "Chop Shop",
			theme = "Sharper, faster cleavers.",
			a = N("Sharpened Cleavers", DMG(0.02)),
			b = N("Faster Spin", AS(0.025)),
			c = N("Wide Chop", AREA(0.02)),
			d = N("Tenderizer", add({ explodeOnKill = 4 })),
			e1 = N("Extra Cleaver", add({ extraOrbiters = 1 })),
			e2 = N("Heavy Blades", DMG(0.04)),
			f = N("Whirlwind", AS(0.025)),
			g = N("Flambé", nil, { damage = 1.06 }),
			k = N("Cleaver Storm", add({ tkShards = 3 })),
		},
		{
			id = "saucier",
			name = "Saucier",
			theme = "Master of the hot pan: ability power.",
			a = N("Hotter Oil", nil, { damage = 1.04 }),
			b = N("Prep Cook", CDR(0.03)),
			c = N("Bigger Pan", nil, { area = 1.04 }),
			d = N("Slow Simmer", nil, { duration = 1.1 }),
			e1 = N("Hot Hands", add({ tkCharge = 1 })),
			e2 = N("Spice Rack", add({ tkCdKill = 0.1 })),
			f = N("Line Cook", CDR(0.03)),
			g = N("Boiling Point", nil, { damage = 1.06, distance = 1.05 }),
			k = N("Mise en Place", add({ tkCombo = 0.3, tkCharge = 1 })),
		},
		{
			id = "taste_tester",
			name = "Taste Tester",
			theme = "A chef never goes hungry: health and healing.",
			a = N("Hearty Meal", HP(0.03)),
			b = N("Seasoned", add({ regen = 0.25 })),
			c = N("Apron", add({ armor = 0.5 })),
			d = N("Chef's Kiss", add({ lifesteal = 0.02 })),
			e1 = N("Snack Break", add({ tkKillHeal = 0.004 })),
			e2 = N("Oven Mitts", add({ tkGuard = 0.25 })),
			f = N("Second Helping", HP(0.03)),
			g = N("Comfort Food", nil, { duration = 1.06, area = 1.04 }),
			k = N("Bottomless Plate", add({ tkKillHeal = 0.008, regen = 0.5 })),
		},
	},
	jumbo = {
		{
			id = "gale",
			name = "Gale",
			theme = "Flap harder: gust damage and size.",
			a = N("Strong Flap", DMG(0.02)),
			b = N("Wider Gust", AREA(0.03)),
			c = N("Gust Rhythm", AS(0.02)),
			d = N("Static Ears", add({ chain = 1 })),
			e1 = N("Hurricane", { weapon = { knockback = 3 }, mul = { damageMult = 1.03 } }),
			e2 = N("Cyclone", add({ explodeOnKill = 4 })),
			f = N("Squall", DMG(0.02)),
			g = N("Downdraft", nil, { damage = 1.06 }),
			k = N("Jet Stream", add({ tkNova = 6 })),
		},
		{
			id = "skyborne",
			name = "Skyborne",
			theme = "Own the sky: ability and mobility.",
			a = N("Longer Flight", nil, { duration = 1.05 }),
			b = N("Tailwind", SPD(0.025)),
			c = N("Quick Takeoff", CDR(0.025)),
			d = N("Landing Gust", nil, { damage = 1.1 }),
			e1 = N("Updraft Strike", add({ tkCharge = 2 })),
			e2 = N("Cloud Cover", add({ tkGuard = 0.3 })),
			f = N("Sky High", CDR(0.025)),
			g = N("Thunderclap", nil, { damage = 1.06, area = 1.05 }),
			k = N("Double Flap", add({ tkCharges = 1, tkGuard = 0.2 })),
		},
		{
			id = "big_ears",
			name = "Big Ears",
			theme = "Hear everything, shrug it off.",
			a = N("Crumb Radar", mul({ pickupRadius = 1.06 })),
			b = N("Soft Landing", HP(0.03)),
			c = N("Thick Ears", add({ armor = 0.5 })),
			d = N("Echo Ears", add({ lifesteal = 0.02 })),
			e1 = N("Sonar", add({ tkOrbs = 1 })),
			e2 = N("Big Heart", both({ regen = 0.5 }, { maxHp = 1.03 })),
			f = N("All Ears", HP(0.03)),
			g = N("Resonance", nil, { damage = 1.05, area = 1.05 }),
			k = N("Echo Chamber", add({ tkOrbs = 2 })),
		},
	},
	fizzante = {
		{
			id = "volatile",
			name = "Volatile",
			theme = "More bang per bottle.",
			a = N("Stronger Mix", DMG(0.02)),
			b = N("Bigger Bang", AREA(0.03)),
			c = N("Quick Shake", AS(0.02)),
			d = N("Fizz Chain", add({ chain = 1 })),
			e1 = N("Nitro", DMG(0.04)),
			e2 = N("Pop Rocks", add({ explodeOnKill = 4 })),
			f = N("Shaken Hard", AS(0.025)),
			g = N("Super Soda", nil, { damage = 1.06 }),
			k = N("Cluster Bombs", add({ tkShards = 3 })),
		},
		{
			id = "carbonation",
			name = "Carbonation",
			theme = "Stickier, longer-lasting soda.",
			a = N("Stickier Soda", nil, { area = 1.04 }),
			b = N("Quick Brew", CDR(0.03)),
			c = N("Long Fizz", nil, { duration = 1.05 }),
			d = N("Acidic", nil, { damage = 1.1 }),
			e1 = N("Fizz Kick", add({ tkCharge = 1 })),
			e2 = N("Recycler", add({ tkCdKill = 0.15 })),
			f = N("Double Brew", CDR(0.03)),
			g = N("Soda Flood", nil, { damage = 1.06, area = 1.04 }),
			k = N("Chain Reaction", add({ tkCdKill = 0.25 })),
		},
		{
			id = "lab_coat",
			name = "Lab Coat",
			theme = "Safety first: health and armour.",
			a = N("Padded Coat", HP(0.03)),
			b = N("Goggles", add({ armor = 0.5 })),
			c = N("Antidote", add({ regen = 0.25 })),
			d = N("Elixir", add({ lifesteal = 0.02 })),
			e1 = N("Hazmat Suit", both({ armor = 1 }, { maxHp = 1.03 })),
			e2 = N("Reactive Foam", add({ tkRetaliate = 0.8 })),
			f = N("Lab Safety", HP(0.03)),
			g = N("Bigger Flasks", nil, { duration = 1.06 }),
			k = N("Emergency Flask", add({ tkLastStand = 0.45 })),
		},
	},
	-- (iteration 6, team Builder's class; tree by team Talents)
	tinkerphant = {
		{
			id = "workshop",
			name = "Workshop",
			theme = "Better turrets and barricades.",
			a = N("Long Barrel", nil, { area = 1.04 }),
			b = N("Reinforced Plating", mul({ buildHpMult = 1.06 })),
			c = N("Hot Rivets", nil, { damage = 1.04 }),
			d = N("Fresh Batteries", nil, { duration = 1.1 }),
			e1 = N("Quick Assembly", CDR(0.05)),
			e2 = N("Armoured Frames", mul({ buildHpMult = 1.12 })),
			f = N("Overclock", CDR(0.025)),
			g = N("Calibrated Sights", nil, { damage = 1.06, area = 1.03 }),
			k = N("Drone Buddy", add({ tkOrbs = 1, tkCharge = 1 })),
		},
		{
			id = "rivets",
			name = "Rivets",
			theme = "A faster, harder rivet gun.",
			a = N("Tight Rivets", DMG(0.02)),
			b = N("Oiled Gears", AS(0.025)),
			c = N("Tempered Steel", DMG(0.015)),
			d = N("Punch Through", add({ pierceBonus = 1 })),
			e1 = N("Ricochet Rivet", add({ chain = 1 })),
			e2 = N("Shrapnel", add({ explodeOnKill = 4 })),
			f = N("Steady Hands", AS(0.025)),
			g = N("Turret Oil", nil, { damage = 1.06 }),
			k = N("Overpressure", add({ tkEmpower = 4 })),
		},
		{
			id = "hard_hat",
			name = "Hard Hat",
			theme = "Safety first: health and armour.",
			a = N("Overalls", HP(0.03)),
			b = N("Hard Hat", add({ armor = 0.5 })),
			c = N("Coffee Break", add({ regen = 0.25 })),
			d = N("Spare Parts", add({ lifesteal = 0.02 })),
			e1 = N("Steel Toes", both({ armor = 1 }, { maxHp = 1.03 })),
			e2 = N("Safety Net", add({ tkLastStand = 0.3 })),
			f = N("Union Rules", HP(0.03)),
			g = N("Field Repairs", nil, { heal = 1.08, duration = 1.04 }),
			k = N("Spring Plating", add({ tkRetaliate = 1.5, armor = 1 })),
		},
	},
}

-- Descriptions ------------------------------------------------------------------------

local pct = Keystones.pct
local function num(v: number): string
	local r = math.floor(v * 100 + 0.5) / 100
	return if r == math.floor(r) then string.format("%d", r) else tostring(r)
end

local MUL_TEXT: { [string]: string } = {
	maxHp = "max HP",
	damageMult = "damage",
	attackSpeedMult = "attack speed",
	areaMult = "weapon and ability area",
	moveSpeed = "move speed",
	pickupRadius = "pickup radius",
	buildHpMult = "turret and barricade HP",
	cooldownMult = "ability cooldowns",
}
local ADD_TEXT: { [string]: (v: number) -> string } = {
	armor = function(v)
		return "+" .. num(v) .. " armour"
	end,
	regen = function(v)
		return "+" .. num(v) .. " HP regeneration per second"
	end,
	critChance = function(v)
		return "+" .. pct(v) .. " crit chance"
	end,
	critMult = function(v)
		return "+" .. pct(v) .. " crit damage"
	end,
	lifesteal = function(v)
		return "heal " .. pct(v) .. " of the damage you deal"
	end,
	chain = function(v)
		return "your first hit each attack chains to " .. num(v) .. " more mouse"
	end,
	pierceBonus = function(v)
		return "shots pierce " .. num(v) .. " more mouse"
	end,
	projectileBonus = function(v)
		return "+" .. num(v) .. " projectile"
	end,
	explodeOnKill = function(v)
		return "mice you defeat burst (radius " .. num(v) .. ")"
	end,
	extraOrbiters = function(v)
		return "+" .. num(v) .. " blade orbiting you (60% weapon damage)"
	end,
}
local WEAPON_TEXT: { [string]: string } = { range = "weapon range", knockback = "knockback" }
local ABILITY_TEXT: { [string]: string } = {
	damage = "ability damage",
	area = "ability area",
	duration = "ability duration",
	distance = "ability reach",
	heal = "ability healing",
	cooldown = "ability cooldown",
}
local ORDER = {
	"maxHp",
	"armor",
	"regen",
	"damageMult",
	"attackSpeedMult",
	"critChance",
	"critMult",
	"areaMult",
	"moveSpeed",
	"cooldownMult",
	"pickupRadius",
	"buildHpMult",
	"lifesteal",
	"chain",
	"pierceBonus",
	"projectileBonus",
	"explodeOnKill",
	"extraOrbiters",
}

local function sortedKeys(t: { [string]: any }?): { string }
	local out = {}
	for k in t or {} do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

-- The exact text of one rank of a node (stats, ability muls, mechanics).
function ClassPerks.describe(delta: StatDelta?, ability: { [string]: number }?): string
	local parts: { string } = {}
	local d: any = delta or {}
	local seen: { [string]: boolean } = {}
	local function stat(k: string)
		local m = d.mul and d.mul[k]
		local a = d.add and d.add[k]
		if type(m) == "number" and MUL_TEXT[k] then
			local v = m - 1
			table.insert(parts, (if v >= 0 then "+" else "-") .. pct(math.abs(v)) .. " " .. MUL_TEXT[k])
		end
		if type(a) == "number" and ADD_TEXT[k] then
			table.insert(parts, ADD_TEXT[k](a))
		end
		seen[k] = true
	end
	for _, k in ORDER do
		stat(k)
	end
	for _, k in sortedKeys(d.weapon) do
		if WEAPON_TEXT[k] then
			table.insert(parts, "+" .. num(d.weapon[k]) .. " " .. WEAPON_TEXT[k])
		end
	end
	for _, k in sortedKeys(ability) do
		local v = (ability :: any)[k] - 1
		if ABILITY_TEXT[k] then
			table.insert(parts, (if v >= 0 then "+" else "-") .. pct(math.abs(v)) .. " " .. ABILITY_TEXT[k])
		end
	end
	for _, k in sortedKeys(d.add) do
		if not seen[k] then
			local ph = Keystones.phrase(k, d.add[k])
			if ph then
				table.insert(parts, ph)
			end
		end
	end
	if #parts == 0 then
		return ""
	end
	local s = table.concat(parts, "; ")
	return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2) .. "."
end

-- Build -------------------------------------------------------------------------------

local byId: { [string]: PerkDef } = {}
local branches: { [string]: { BranchDef } } = {}
local legacy: { [string]: { branchIndex: number, tier: number } } = {}

local function mainBehaviour(delta: StatDelta): string?
	local best: string? = nil
	for _, k in sortedKeys((delta :: any).add) do
		if Keystones.isField(k) then
			return k
		end
		if ADD_TEXT[k] and (k == "chain" or k == "lifesteal" or k == "explodeOnKill" or k == "pierceBonus" or k == "extraOrbiters") then
			best = best or k
		end
	end
	return best
end

-- Stat power budget: every stat number above is scaled by STAT_SCALE (mul: 1 + (m - 1) x f,
-- add: x f) so a 29-point build stays about +25-30% stat power (DataClassProgress.spec power
-- index); integer behaviours (chain, pierce, ...) and the mechanic fields are kept.
ClassPerks.STAT_SCALE = 0.6
local KEEP: { [string]: boolean } = {
	chain = true,
	pierceBonus = true,
	projectileBonus = true,
	explodeOnKill = true,
	extraOrbiters = true,
}
local function round(v: number): number
	return math.floor(v * 10000 + 0.5) / 10000
end
local function scaleDelta(d: StatDelta?): StatDelta
	local f = ClassPerks.STAT_SCALE
	local out: any = {}
	local src: any = d or {}
	if src.add then
		out.add = {}
		for k, v in src.add do
			out.add[k] = if KEEP[k] or Keystones.isField(k) then v else round(v * f)
		end
	end
	if src.mul then
		out.mul = {}
		for k, v in src.mul do
			out.mul[k] = round(1 + (v - 1) * f)
		end
	end
	if src.weapon then
		out.weapon = {}
		for k, v in src.weapon do
			out.weapon[k] = round(v * f)
		end
	end
	return out
end
local function scaleMul(m: { [string]: number }?): { [string]: number }?
	if not m then
		return nil
	end
	local out = {}
	for k, v in m do
		out[k] = round(1 + (v - 1) * ClassPerks.STAT_SCALE)
	end
	return out
end

for classId, list in SPECS do
	local out: { BranchDef } = {}
	for bi, b in list do
		local nodes: { PerkDef } = {}
		local byKey: { [string]: PerkDef } = {}
		for _, key in ClassPerks.KEYS do
			local s: NSpec = (b :: any)[key]
			assert(s, classId .. " " .. b.id .. " misses node " .. key)
			local row = ClassPerks.ROW[key]
			local delta: StatDelta = scaleDelta(s.delta)
			local abilityMul = scaleMul(s.ability)
			local kind: NodeKind = if key == "k"
				then "keystone"
				elseif key == "e1" or key == "e2" then "choice"
				elseif key == "d" then "minor"
				else "stat"
			local reqs = {}
			for _, rk in ClassPerks.REQUIRES[key] or {} do
				table.insert(reqs, classId .. "_" .. b.id .. "_" .. rk)
			end
			local def: PerkDef = {
				id = classId .. "_" .. b.id .. "_" .. key,
				key = key,
				classId = classId,
				branch = b.id,
				branchIndex = bi,
				tier = row,
				col = ClassPerks.COL[key],
				maxRank = ClassPerks.RANKS[key],
				cost = 1,
				gate = ClassPerks.GATE[row],
				requires = reqs,
				exclusive = if kind == "choice" then classId .. "_" .. b.id .. "_e" else nil,
				kind = kind,
				name = s.name,
				description = s.text or ClassPerks.describe(delta, abilityMul),
				delta = delta,
				abilityMul = abilityMul,
				behaviour = mainBehaviour(delta),
			}
			table.insert(nodes, def)
			byKey[key] = def
			byId[def.id] = def
		end
		table.insert(out, {
			id = b.id,
			name = b.name,
			theme = b.theme,
			nodes = nodes,
			perks = nodes,
			keystone = byKey.k,
		})
		for t = 1, ClassPerks.LEGACY_TIERS do
			legacy[classId .. "_" .. b.id .. "_" .. t] = { branchIndex = bi, tier = t }
		end
	end
	branches[classId] = out
end

ClassPerks.byId = byId
ClassPerks.LEGACY = legacy

-- Node def of a saved key: a node id, or a rank key "<id>#r" (nil for anything else,
-- legacy ids included). The second result is the rank the key stands for.
function ClassPerks.parse(key: any): (PerkDef?, number)
	if type(key) ~= "string" then
		return nil, 0
	end
	local def = byId[key]
	if def then
		return def, 1
	end
	local at = string.find(key, ClassPerks.RANK_SEP, 1, true)
	if not at then
		return nil, 0
	end
	def = byId[string.sub(key, 1, at - 1)]
	local r = tonumber(string.sub(key, at + 1))
	if not def or not r or r ~= math.floor(r) or r < 2 or r > def.maxRank then
		return nil, 0
	end
	return def, r
end

function ClassPerks.get(key: any): PerkDef?
	return (ClassPerks.parse(key))
end

-- Saved key of rank r of a node.
function ClassPerks.rankKey(id: string, r: number): string
	return if r <= 1 then id else id .. ClassPerks.RANK_SEP .. tostring(r)
end

-- Current rank of node `def` in a saved set (consecutive ranks from 1).
function ClassPerks.rankOf(set: any, def: PerkDef): number
	if type(set) ~= "table" then
		return 0
	end
	local r = 0
	for k = 1, def.maxRank do
		if set[ClassPerks.rankKey(def.id, k)] == true then
			r = k
		else
			break
		end
	end
	return r
end

-- Old 3 x 5 ladder id -> {branchIndex, tier} (nil for anything else).
function ClassPerks.legacy(id: any): { branchIndex: number, tier: number }?
	return if type(id) == "string" then legacy[id] else nil
end

-- The 3 branches of a class (empty list for an unknown class).
function ClassPerks.branches(classId: string): { BranchDef }
	return branches[classId] or {}
end

-- Every node of a class in branch, then row order.
function ClassPerks.forClass(classId: string): { PerkDef }
	local out = {}
	for _, b in ClassPerks.branches(classId) do
		for _, def in b.nodes do
			table.insert(out, def)
		end
	end
	return out
end

-- Node of a branch by key ("a".."k").
function ClassPerks.node(classId: string, branchIndex: number, key: string): PerkDef?
	local b = ClassPerks.branches(classId)[branchIndex]
	return if b then byId[classId .. "_" .. b.id .. "_" .. key] else nil
end

-- (compat) the node one row lower that a node needs (its first requirement), or nil.
function ClassPerks.previous(def: PerkDef): PerkDef?
	local r = def.requires[1]
	return if r then byId[r] else nil
end

-- Points of a whole branch.
function ClassPerks.branchCost(): number
	return ClassPerks.BRANCH_POINTS
end

-- Keystones of a class (one per branch).
function ClassPerks.keystones(classId: string): { PerkDef }
	local out = {}
	for _, b in ClassPerks.branches(classId) do
		table.insert(out, b.keystone)
	end
	return out
end

return ClassPerks
