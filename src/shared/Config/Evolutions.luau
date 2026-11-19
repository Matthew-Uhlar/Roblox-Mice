--!strict
-- Lifetime Stomps (v5 B2 / iteration 2). Pure data; Data/Evolution holds the rules.
-- (Iteration 2: the evolution STAGES merged into Ascension, Config/Ascension: the
-- Bull / Matriarch / Ancient looks are ascension nodes 2 / 4 / 8.)
--
-- Stomps count the mice a player stomped: per class (classes[id].stomps) and for the
-- account (stats.stomps, the Total Stomps leaderboard). Match stomps = mice x the
-- difficulty tier's reward multiplier (Config/Difficulty). There is no outcome
-- multiplier (Z-15: the nameplate shows it as a kill count). Never sold for Robux.

local E = {}

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
