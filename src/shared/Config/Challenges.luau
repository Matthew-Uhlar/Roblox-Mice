--!strict
-- 30 Challenges (iteration 2, ALIGNMENT §2c). Pure data; Data/Challenges evaluates them
-- after every match (and after gem changes for the gem ones). Each pays ONCE: a title,
-- a gem at the listed tier and/or Crumb Dust. All 30 earn the "Wheel of Legends" title.
-- None needs Robux or a friend; bots count as enemy heroes and as squadmates.
--
-- req fields (all present ones must hold):
--   clear = true        the match was a full clear (or Last Herd) of the tier
--   minTier = n         at the difficulty tier >= n
--   solo = true         the only human in the server
--   classId = id        played with that class
--   lastHerd = true     won by Last Herd Standing
--   extractStage = n    extracted at stage >= n
--   flag = name         M2's match flag is true (DataService.awardRun stats.challengeFlags)
--   count = {name, n}   M2's match counter >= n
--   maxMinutes = n      the clear took at most n minutes (stats.clearSeconds)
--   state = kind        a profile check: "gemLevel5" | "gemTier11" | "gemTier12"
-- M2's flags / counters: noRankBought, noWheyBuff, noKnockout, oneHitCurse, allHigh,
-- lairBothOneStage, snatchBossKill, allWavesHorned, noEnemyDowned, squadAllStanding,
-- squadNoKnockout (flags); donWins, ultimates, squadChampKills, bountiedDowns (counters).

export type Req = {
	clear: boolean?,
	minTier: number?,
	solo: boolean?,
	classId: string?,
	lastHerd: boolean?,
	extractStage: number?,
	flag: string?,
	count: { any }?,
	maxMinutes: number?,
	state: string?,
}
export type Reward = { gemTier: number?, gemUnique: boolean?, dust: number?, title: string? }
export type ChallengeDef = { id: string, name: string, text: string, req: Req, reward: Reward }

local C = {}

local function c(id: string, name: string, text: string, req: Req, reward: Reward): ChallengeDef
	return { id = id, name = name, text = text, req = req, reward = reward }
end

local CLASSES = {
	{ "elephante", "Elephante" },
	{ "ele_fonte", "Ele Fonte" },
	{ "ellie_fawn", "Ellie Fawn" },
	{ "le_fante", "Le Fante" },
	{ "filet", "Filet" },
	{ "jumbo", "Jumbo" },
	{ "fizzante", "Fizzante" },
}

local list: { ChallengeDef } = {}
for i, cl in CLASSES do
	table.insert(
		list,
		c(
			"lone_tusk_" .. cl[1],
			"Lone Tusk: " .. cl[2],
			"Clear Smoked solo with " .. cl[2] .. ".",
			{ clear = true, minTier = 6, solo = true, classId = cl[1] },
			{ gemTier = 6 }
		)
	)
	local _ = i
end

local rest = {
	c(
		"bare_trunk",
		"Bare Trunk",
		"Clear Sharp without buying a stat rank.",
		{ clear = true, minTier = 3, flag = "noRankBought" },
		{ dust = 10, title = "title_bare_trunk" }
	),
	c(
		"whey_ascetic",
		"Whey Ascetic",
		"Clear Aged with no stall or Altar buff.",
		{ clear = true, minTier = 5, flag = "noWheyBuff" },
		{ gemTier = 5 }
	),
	c(
		"unbroken",
		"Unbroken",
		"Clear Aged without ever being knocked out.",
		{ clear = true, minTier = 5, flag = "noKnockout" },
		{ gemTier = 5 }
	),
	c(
		"paper_elephant",
		"Paper Elephant",
		"Clear Medium with the one-hit curse active all run.",
		{ clear = true, minTier = 2, flag = "oneHitCurse" },
		{ title = "title_paper_elephant" }
	),
	c(
		"double_down",
		"Double Down",
		"Win Double or Nothing on 3 stages, then clear Aged.",
		{ clear = true, minTier = 5, count = { "donWins", 3 } },
		{ gemTier = 6 }
	),
	c(
		"high_roller",
		"High Roller",
		"Pick High on every route and clear Smoked.",
		{ clear = true, minTier = 6, flag = "allHigh" },
		{ gemTier = 7 }
	),
	c(
		"altar_titan",
		"Altar Titan",
		"Buy 2 ultimates in one match.",
		{ count = { "ultimates", 2 } },
		{ dust = 15 }
	),
	c(
		"champion_hunter",
		"Champion Hunter",
		"Your squad kills 8 champions in one match.",
		{ count = { "squadChampKills", 8 } },
		{ gemTier = 4 }
	),
	c(
		"lair_raider",
		"Lair Raider",
		"Kill both lair champions in one stage.",
		{ flag = "lairBothOneStage" },
		{ dust = 10 }
	),
	c(
		"last_herd_pungent",
		"Last Herd",
		"Win by Last Herd Standing on Pungent.",
		{ lastHerd = true, minTier = 7 },
		{ gemTier = 7 }
	),
	c(
		"snatcher",
		"Snatcher",
		"Land the killing blow on a boss another squad led.",
		{ flag = "snatchBossKill" },
		{ title = "title_snatcher" }
	),
	c(
		"bounty_breaker",
		"Bounty Breaker",
		"Down 3 bountied heroes in one match.",
		{ count = { "bountiedDowns", 3 } },
		{ title = "title_bounty_breaker" }
	),
	c(
		"horn_blower",
		"Horn Blower",
		"Clear Sharp with every wave called early.",
		{ clear = true, minTier = 3, flag = "allWavesHorned" },
		{ dust = 10 }
	),
	c(
		"speed_herd",
		"Speed Herd",
		"Clear Medium in under 13 minutes.",
		{ clear = true, minTier = 2, maxMinutes = 13 },
		{ title = "title_speed_herd" }
	),
	c(
		"peacekeeper",
		"Peacekeeper",
		"Clear Sharp without downing an enemy hero.",
		{ clear = true, minTier = 3, flag = "noEnemyDowned" },
		{ title = "title_peacekeeper" }
	),
	c(
		"clean_exit",
		"Clean Exit",
		"Extract at stage 3 on Smoked with the whole squad standing.",
		{ extractStage = 3, minTier = 6, flag = "squadAllStanding" },
		{ gemTier = 6 }
	),
	c(
		"herd_of_three",
		"Herd of Three",
		"Clear Aged with your whole squad never knocked out.",
		{ clear = true, minTier = 5, flag = "squadNoKnockout" },
		{ gemTier = 5 }
	),
	c(
		"iron_will",
		"Iron Will",
		"Clear Stinky solo.",
		{ clear = true, minTier = 8, solo = true },
		{ gemTier = 8 }
	),
	c("gem_cutter", "Gem Cutter", "Upgrade a gem to +5.", { state = "gemLevel5" }, { dust = 20 }),
	c("jeweler", "Jeweler", "Own a tier-11 gem.", { state = "gemTier11" }, { title = "title_jeweler" }),
	c("doomwheel", "Doomwheel", "Clear Doomwheel.", { clear = true, minTier = 11 }, { gemTier = 11 }),
	c(
		"doomwheel_alone",
		"Doomwheel Alone",
		"Clear Doomwheel solo.",
		{ clear = true, minTier = 11, solo = true },
		{ gemTier = 11, gemUnique = true }
	),
	c(
		"golden_wheel",
		"Golden Wheel",
		"Earn a tier-12 gem.",
		{ state = "gemTier12" },
		{ title = "title_golden_wheel" }
	),
}
for _, def in rest do
	table.insert(list, def)
end

C.LIST = list
C.ALL_TITLE = "title_wheel_of_legends" -- for finishing all 30

C.byId = {} :: { [string]: ChallengeDef }
for _, def in list do
	C.byId[def.id] = def
end

function C.get(id: any): ChallengeDef?
	if type(id) ~= "string" then
		return nil
	end
	return C.byId[id]
end

return C
