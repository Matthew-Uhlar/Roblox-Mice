--!strict
-- Lifetime Stomps and Evolutions (v5 B2, iteration 1 corrections Z-5 / Z-6 / Z-15 / Z-16).
-- Pure data; Data/Evolution holds the rules.
--
-- Stomps count the mice a player stomped: per class (classes[id].stomps) and for the
-- account (stats.stomps, a leaderboard). Match stomps = mice x (1 + 0.05 x Pressure);
-- there is NO outcome multiplier (Z-15 rejected for stomps: the nameplate shows it as a
-- kill count). Never sold for Robux.

export type StageDef = {
	stage: number,
	name: string,
	stomps: number, -- class stomps needed
	maxHpPct: number?, -- bonus (cumulative with lower stages)
	pvePct: number?, -- PvE damage (stats.pveDamageMult)
	xpPct: number?, -- in-run XP
	rindPct: number?, -- rinds (run bonus extras.rindMult)
}

local E = {}

E.PRESSURE_PER_POINT = 0.05

E.STAGES = {
	{ stage = 1, name = "Calf", stomps = 0 },
	{ stage = 2, name = "Bull", stomps = 2500, maxHpPct = 0.03 },
	{ stage = 3, name = "Matriarch", stomps = 15000, pvePct = 0.03 },
	{ stage = 4, name = "Ancient", stomps = 60000, xpPct = 0.04, rindPct = 0.04 },
} :: { StageDef }

E.PIPS = 4 -- a pip every 20% of the way to the next stage (Z-16)

-- Free class unlocks by ACCOUNT stomps (an alternative to buying with cheese, which
-- stays). Order: the cheaper cheese classes first (Config/Classes unlockCost).
E.FREE_UNLOCKS = {
	{ classId = "le_fante", stomps = 3000 },
	{ classId = "filet", stomps = 8000 },
	{ classId = "jumbo", stomps = 20000 },
	{ classId = "fizzante", stomps = 50000 },
}

-- Veteran seed (Z-6, profile v7): class stomps = floor(SEED_PER_XP x lifetime class XP).
E.SEED_PER_XP = 1.2

return E
