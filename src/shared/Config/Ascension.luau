--!strict
-- Prestige and Ascension (iteration 2, ALIGNMENT §2a; replace Mastery Stars and the v5
-- Evolutions). Pure data; the rules are in Data/ClassProgress (prestige) and
-- Data/Ascension (nodes).
--
-- Prestige (per class, P0-99): at class level 30, the Prestige action resets the
-- DISPLAYED level to 1 (it re-climbs to 30 over PRESTIGE_XP); every unlock keeps using
-- the stored level 30, so nothing is lost. Each Prestige: +1 perk point up to P16,
-- +0.5% PvE damage and +0.25% max HP up to P40, and 300 cheese + 10 Golden Cheese.
--
-- Ascension (per class, 8 nodes, in order): node n needs Prestige >= prestige[n] AND
-- class stomps >= stomps[n]. Nodes 2, 4 and 8 unlock the Bull, Matriarch and Ancient
-- looks. The numbers below are the generic template; M1 applies the class flavour of
-- the behaviour nodes (shape changes apply in PvP, damage numbers are PvE-only).
-- (iteration 6, team Talents) every node also has a visible mechanic
-- (Config/AscensionNodes.MECH, Combat/Talents); AscensionNodes.describe(classId, n) is
-- the full per-class text the hero screen shows.

local Economy = require("./Economy") -- iteration 6: the cheese grind (x0.6)
local A = {}

A.MAX_PRESTIGE = 99
A.PRESTIGE_XP = 12_000 -- XP for the displayed level to re-climb 1 -> 30
A.PERK_POINT_PRESTIGE_CAP = 16 -- +1 perk point per Prestige up to P16 (full 45-point tree)
A.BONUS_PRESTIGE_CAP = 40
A.PVE_PER_PRESTIGE = 0.005
A.HP_PER_PRESTIGE = 0.0025
A.REWARD = table.freeze({ cheese = Economy.cheese(300), goldenCheese = 10 })
A.FRAMES = { 1, 5, 10, 20, 40, 70, 99 } -- nameplate star frames at these Prestiges

export type NodeDef = {
	node: number,
	prestige: number,
	stomps: number,
	name: string,
	text: string,
	look: string?, -- "bull" | "matriarch" | "ancient"
	maxHpPct: number?,
	cooldownCut: number?,
	squadPve: number?, -- a squad aura (+PvE damage), summed per squad like gems
}

A.NODES = {
	{ node = 1, prestige = 1, stomps = 5000, name = "Second Wind", text = "+8% max HP; Second Wind: under 25% HP heal 35%, blast mice away (60s).", maxHpPct = 0.08 },
	{
		node = 2,
		prestige = 3,
		stomps = 10000,
		name = "Bull",
		text = "Bull look; ability +20% area; every cast sends a shockwave.",
		look = "bull",
	},
	{
		node = 3,
		prestige = 5,
		stomps = 20000,
		name = "Ascended Weapon",
		text = "Weapon +1 projectile, pierce or arc, with a glowing trail.",
	},
	{
		node = 4,
		prestige = 8,
		stomps = 35000,
		name = "Matriarch",
		text = "Matriarch look; class passive doubled; a spirit calf zaps mice.",
		look = "matriarch",
	},
	{ node = 5, prestige = 12, stomps = 60000, name = "Echo", text = "A ghostly double repeats your ability at 50%." },
	{
		node = 6,
		prestige = 16,
		stomps = 90000,
		name = "Overcharge",
		text = "-10% cooldowns; your next 2 attacks after a cast are empowered.",
		cooldownCut = 0.10,
	},
	{
		node = 7,
		prestige = 20,
		stomps = 130000,
		name = "Frenzy",
		text = "Class-Stall buff at half strength; 12 kills in 4s start a Frenzy.",
	},
	{
		node = 8,
		prestige = 25,
		stomps = 200000,
		name = "Ancient",
		text = "Ancient look; squad +5% PvE damage; an Ancient Stomp every 10s.",
		look = "ancient",
		squadPve = 0.05,
	},
} :: { NodeDef }

A.LOOKS = { "bull", "matriarch", "ancient" }
A.LOOK_NODE = { bull = 2, matriarch = 4, ancient = 8 }

return A
