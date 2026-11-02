--!strict
-- Pressure board (GDD §3.7): pre-run difficulty modifiers the party leader
-- stacks for more reward. Brainstorm Topic 3 (Death Must Die's "Outer Circle"
-- screen): we take the idea, not the content.
--
-- Each modifier has 1..maxRank ranks; every rank is worth `points` Pressure
-- points (1 for all of them today, so the full board is 21 points).
-- `perRank` is a WorldMods delta PER RANK, combined LINEARLY with the rank:
--   * fields ending in "Mult": factor = 1 + perRank[field] * rank, then the
--     factor MULTIPLIES the run's mods (like a curse's `world`)
--   * other numeric fields ADD perRank[field] * rank
-- `perStage` (optional) makes a modifier bite harder as the run goes on: per
-- rank, each global stage after the first adds perStage[field] on top of
-- perRank[field] (counted up to STAGE_CAP), so at global stage g the per-rank
-- value is perRank + perStage * (min(g, STAGE_CAP) - 1). Stage 1 = perRank.
-- Run/Pressure.luau does the maths; RunState applies it to run:worldMods().
--
-- New WorldMods fields used here (defaults in Run/Stats.defaultWorldMods;
-- Combat/World must read them, see docs/ARCHITECTURE.md "Pressure"):
--   eliteSpeedMult         elite mice move speed
--   eliteSizeMult          elite mice radius and the area of their attacks
--   lateSpawnMult          spawn rate during the last LATE_SPAWN_WINDOW s of waves
--   rangedExtraProjectiles extra projectiles per ranged-mouse volley (integer)
--   enemyXpMult            XP in the crumbs mice drop (No Snacks)
-- Balance (FINAL-A M1): the full board must cost real wins, not just pay more.
-- Headless (solo + 2 bots, POIs on, 8 seeds x 3 classes, Cycle 1 -> Go Home):
-- P0 24/24, P10 20/24, P21 14/24. The XP cut (No Snacks) and the per-stage
-- growth keep the party from out-levelling the board after stage 1.
-- tests/specs/IntegrationPressure.spec.luau guards the ordering.

export type PressureDef = {
	id: string,
	name: string,
	icon: string, -- emoji shown on the board
	description: string, -- per-rank effect, player-facing
	maxRank: number,
	points: number, -- Pressure points per rank
	perRank: { [string]: number }, -- WorldMods deltas per rank (see header)
	perStage: { [string]: number }?, -- extra per rank per global stage after the first (see header)
}

local Pressure = {}

-- Rush Hour's window: the last 60 s of the 150 s waves (GDD §3.3).
Pressure.LATE_SPAWN_WINDOW = 60

-- perStage growth stops at this global stage (same cap as Stats.DIFFICULTY.bossStageCap).
Pressure.STAGE_CAP = 8

-- Rewards per Pressure point (GDD §3.7).
Pressure.REWARDS = table.freeze({
	cheesePerPoint = 0.08, -- +8% stage cheese per point
	luckPerPoint = 0.05, -- added to upgrade-offer luck
	epicPerPoint = 0.02, -- +2 percentage points of Epic-drop chance on every route
})

-- Highest Pressure cleared unlocks title badges at these points (GDD §3.7).
Pressure.BADGES = table.freeze({ 5, 10, 20 })

local list: { PressureDef } = {
	{
		id = "stampede",
		name = "Stampede",
		icon = "🐾",
		description = "Elite mice +30% move speed; +4% elite chance (+1% more each stage)",
		maxRank = 3,
		points = 1,
		perRank = { eliteSpeedMult = 0.3, eliteChance = 0.04 },
		perStage = { eliteChance = 0.01 },
	},
	{
		id = "big_cheese",
		name = "Big Cheese",
		icon = "🧀",
		description = "Elite mice +25% size and attack area; +4% elite chance (+1% more each stage)",
		maxRank = 2,
		points = 1,
		perRank = { eliteSizeMult = 0.25, eliteChance = 0.04 },
		perStage = { eliteChance = 0.01 },
	},
	{
		id = "rush_hour",
		name = "Rush Hour",
		icon = "⏰",
		description = "+30% spawn rate in the last 60 s of waves (+10% more each stage)",
		maxRank = 3,
		points = 1,
		perRank = { lateSpawnMult = 0.3 },
		perStage = { lateSpawnMult = 0.1 },
	},
	{
		id = "slingshot_season",
		name = "Slingshot Season",
		icon = "🎯",
		description = "Ranged mice fire +1 projectile",
		maxRank = 2,
		points = 1,
		perRank = { rangedExtraProjectiles = 1 },
	},
	{
		id = "hot_crumbs",
		name = "Hot Crumbs",
		icon = "🔥",
		description = "Enemy projectiles +20% speed",
		maxRank = 3,
		points = 1,
		perRank = { enemyProjectileSpeedMult = 0.2 },
	},
	{
		id = "boss_fury",
		name = "Boss Fury",
		icon = "👑",
		description = "Bosses deal +20% damage; each stage, bosses and mice +15% more",
		maxRank = 3,
		points = 1,
		perRank = { bossDamageMult = 0.2 },
		perStage = { bossDamageMult = 0.15, enemyDamageMult = 0.15 },
	},
	{
		id = "thick_rind",
		name = "Thick Rind",
		icon = "🛡",
		description = "All mice and bosses +15% HP; each stage, mice +25% and bosses +15% more",
		maxRank = 3,
		points = 1,
		perRank = { enemyHpMult = 0.15, bossHpMult = 0.15 },
		perStage = { enemyHpMult = 0.25, bossHpMult = 0.15 },
	},
	{
		id = "no_snacks",
		name = "No Snacks",
		icon = "🚫",
		description = "−25% healing and −30% XP from mice",
		maxRank = 2,
		points = 1,
		perRank = { healingMult = -0.25, enemyXpMult = -0.3 },
	},
}

local byId: { [string]: PressureDef } = {}
local order: { string } = {}
local maxPoints = 0
for _, def in list do
	assert(byId[def.id] == nil, "duplicate pressure id " .. def.id)
	table.freeze(def.perRank)
	if def.perStage then
		table.freeze(def.perStage)
	end
	table.freeze(def)
	byId[def.id] = def
	table.insert(order, def.id)
	maxPoints += def.maxRank * def.points
end

Pressure.LIST = table.freeze(list)
Pressure.BY_ID = table.freeze(byId)
Pressure.ORDER = table.freeze(order)
Pressure.MAX_POINTS = maxPoints -- 21 with the board above

function Pressure.get(id: any): PressureDef?
	if type(id) ~= "string" then
		return nil
	end
	return byId[id]
end

return table.freeze(Pressure)
