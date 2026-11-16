--!strict
-- Achievements (v4 plan, QC-C §5.3). Pure data; Data/Achievements evaluates them
-- against the profile after every award, collection entry and class level-up.
--
-- `req` kinds:
--   stat          profile.stats[field] >= n          (runs, extractions, lastHerd, championKills,
--                                                     bestStage, bossesKilled)
--   classes       classes unlocked >= n
--   classLevel    any class at level >= n
--   allClasses    every class in Config/Classes at level >= n
--   stars         Mastery Stars over all classes >= n
--   pressure      profile.pressure.highestCleared >= n (a FULL clear at that Pressure)
--   streak        daily streak >= n
--   page          Mousepedia page `page` complete
--   discoveries   every id in `ids` discovered (rare POIs)
--   level         account level >= n
-- Rewards are cheese, Golden Cheese, titles or cosmetics. Never stats, never Robux.
-- `badgeId` = 0 until the badge exists on Roblox (TODO(dashboard)); awarded when > 0.

export type Req = {
	kind: string,
	field: string?,
	n: number?,
	page: string?,
	ids: { string }?,
}

export type Reward = { cheese: number?, goldenCheese: number?, title: string?, cosmetic: string? }

export type AchievementDef = {
	id: string,
	name: string,
	text: string,
	req: Req,
	reward: Reward,
	badgeId: number,
}

local A = {}

local function a(id: string, name: string, text: string, req: Req, reward: Reward): AchievementDef
	return { id = id, name = name, text = text, req = req, reward = reward, badgeId = 0 }
end

A.LIST = {
	a(
		"first_steps",
		"First Steps",
		"Finish your first match.",
		{ kind = "stat", field = "runs", n = 1 },
		{ cheese = 100 }
	),
	a(
		"regular",
		"Regular",
		"Finish 50 matches.",
		{ kind = "stat", field = "runs", n = 50 },
		{ cheese = 1000 }
	),
	a(
		"over_the_rind",
		"Over the Rind",
		"Extract for the first time.",
		{ kind = "stat", field = "extractions", n = 1 },
		{ cheese = 250 }
	),
	a(
		"escape_artist",
		"Escape Artist",
		"Extract 25 times.",
		{ kind = "stat", field = "extractions", n = 25 },
		{ goldenCheese = 25 }
	),
	a(
		"last_herd",
		"Last Herd Standing",
		"Be the Last Herd once.",
		{ kind = "stat", field = "lastHerd", n = 1 },
		{ goldenCheese = 25, title = "title_last_herd" }
	),
	a(
		"full_clear",
		"All Four",
		"Clear all 4 stages in one match.",
		{ kind = "stat", field = "bestStage", n = 4 },
		{ cheese = 500 }
	),
	a(
		"champ_10",
		"Champion Hunter",
		"Help defeat 10 Mouse Champions.",
		{ kind = "stat", field = "championKills", n = 10 },
		{ cheese = 300 }
	),
	a(
		"champ_50",
		"Champion Bane",
		"Help defeat 50 Mouse Champions.",
		{ kind = "stat", field = "championKills", n = 50 },
		{ goldenCheese = 50 }
	),
	a(
		"boss_25",
		"Boss Breaker",
		"Defeat 25 bosses.",
		{ kind = "stat", field = "bossesKilled", n = 25 },
		{ cheese = 500 }
	),
	a("herd_of_five", "Herd of Many", "Unlock 5 classes.", { kind = "classes", n = 5 }, { cheese = 500 }),
	a(
		"bronze_herd",
		"Bronze Herd",
		"Reach class level 10 with any class.",
		{ kind = "classLevel", n = 10 },
		{ cheese = 300 }
	),
	a(
		"gold_herd",
		"Gold Herd",
		"Reach class level 30 with any class.",
		{ kind = "classLevel", n = 30 },
		{ goldenCheese = 50 }
	),
	a(
		"seven_masteries",
		"Seven Masteries",
		"Reach class level 10 with all 7 classes.",
		{ kind = "allClasses", n = 10 },
		{ goldenCheese = 100 }
	),
	a(
		"first_star",
		"Star Herd",
		"Earn a Mastery Star.",
		{ kind = "stars", n = 1 },
		{ title = "title_star_herd" }
	),
	a(
		"pressure_5",
		"Pressured",
		"Fully clear a match at Pressure 5.",
		{ kind = "pressure", n = 5 },
		{ title = "title_pressured" }
	),
	a(
		"pressure_10",
		"Squeezed",
		"Fully clear a match at Pressure 10.",
		{ kind = "pressure", n = 10 },
		{ title = "title_squeezed" }
	),
	a(
		"pressure_15",
		"Crushed",
		"Fully clear a match at Pressure 15.",
		{ kind = "pressure", n = 15 },
		{ title = "title_crushed" }
	),
	a(
		"pressure_21",
		"Unbreakable",
		"Fully clear a match at Pressure 21.",
		{ kind = "pressure", n = 21 },
		{ title = "title_unbreakable" }
	),
	a(
		"streak_30",
		"Streak Keeper",
		"Reach a 30-day daily streak.",
		{ kind = "streak", n = 30 },
		{ title = "title_streak_keeper" }
	),
	a(
		"discoverer",
		"Discoverer",
		"Find Grandma's Pantry and the Lost Herd Statue.",
		{ kind = "discoveries", ids = { "grandmas_pantry", "lost_herd_statue" } },
		{ goldenCheese = 50 }
	),
	a(
		"world_walker",
		"World Walker",
		"Play a stage on every map.",
		{ kind = "page", page = "maps" },
		{ goldenCheese = 25 }
	),
} :: { AchievementDef }

A.byId = {} :: { [string]: AchievementDef }
for _, def in A.LIST do
	A.byId[def.id] = def
end

function A.get(id: any): AchievementDef?
	if type(id) ~= "string" then
		return nil
	end
	return A.byId[id]
end

return A
