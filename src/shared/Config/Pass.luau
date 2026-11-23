--!strict
-- Herd Pass (v4 plan "Progression and monetization", research §4.4). Pure data.
--
-- Seasons are 28 days long and numbered from a fixed UTC epoch, so every server
-- agrees on the season without any stored state:
--   season(day) = floor((day - EPOCH_DAY) / SEASON_DAYS) + 1   (days before the epoch = season 1)
-- 30 tiers of 1,000 Pass XP. Free and premium tracks. Premium is one game pass per
-- season (Config/Monetization `passSeason`, 399 R$): 8 cosmetics + 600 Golden Cheese.
--
-- Rules (enforced in Data/HerdPass, tested in DataHerdPass.spec):
--   * Rewards are cosmetics, titles, cheese, Golden Cheese and reroll tokens only:
--     no class XP, no perk points, no gear, no talents, no boosts, no Second Wind.
--   * Pass XP comes from play, Herd Contracts and Mousepedia entries. Robux never buys
--     Pass XP or tiers.
--   * Upgrading mid-season back-fills: every premium reward of a tier already reached
--     becomes claimable at once.
--   * At the season rollover every unclaimed reward of a reached tier is granted.
--
-- Content for a season number without its own entry repeats SEASONS in order
-- (items return; nothing is "gone forever"). Its premium track is only sold when
-- that season has its own `premiumKey` game pass in Config/Monetization.

local Monetization = require("./Monetization")
local Economy = require("./Economy") -- iteration 6: the cheese grind (x0.6, free track)

export type Reward = {
	cheese: number?,
	goldenCheese: number?,
	rerollTokens: number?,
	cosmetic: string?, -- Config/Cosmetics id
	title: string?, -- Config/Cosmetics.EARNED_TITLES id
	dust: number?, -- (iteration 2) Crumb Dust
}

export type SeasonDef = {
	id: number,
	name: string,
	premiumKey: string?, -- Config/Monetization game pass of this season
	free: { [number]: Reward }, -- tier -> reward (tiers without an entry give nothing)
	premium: { [number]: Reward },
}

local P = {}

-- Season 1 starts 2026-11-18 00:00 UTC (UTC day number = floor(os.time() / 86400)) and
-- runs 28 days. Before that date it is season 1, day 0 (dayInSeason), so nothing breaks.
P.EPOCH_DAY = 20775
P.SEASON_DAYS = 28
P.TIERS = 30
P.XP_PER_TIER = 1000
P.MAX_XP = P.TIERS * P.XP_PER_TIER

-- Pass XP from one match (Data/Award): BASE + PER_STAGE x stages survived
-- + FINISH if the squad extracted or was the Last Herd, capped at RUN_CAP.
P.RUN_XP = table.freeze({
	BASE = 60,
	PER_STAGE = 40,
	FINISH = 60,
	RUN_CAP = 280,
})
P.COLLECTION_XP = 50 -- each new Mousepedia entry (Config/Collection)

-- Season 1: "Winter Rind". Free: 300 cheese on most tiers, 10 GC every 5 tiers,
-- reroll tokens at 7 and 22, a tint at 10, a title at 20 and a trail at 30.
-- Premium: 8 cosmetics + 100 Golden Cheese at tiers 3, 8, 13, 18, 23, 28 (600 total).
local function winterFree(): { [number]: Reward }
	local t: { [number]: Reward } = {}
	for tier = 1, P.TIERS do
		t[tier] = { cheese = Economy.cheese(300) }
	end
	for _, tier in { 5, 15, 25 } do
		t[tier] = { goldenCheese = 10 }
	end
	t[7] = { rerollTokens = 3 }
	t[22] = { rerollTokens = 3 }
	t[10] = { cosmetic = "tint_icy_rind" }
	t[20] = { title = "title_winter_herd" }
	t[30] = { cosmetic = "trail_frost_crumbs" }
	-- (iteration 2) Crumb Dust on a few free tiers (Data/Gems), ON TOP of their 300 cheese
	-- (the live season: nobody who hasn't claimed yet loses anything)
	for _, tier in { 12, 17, 27 } do
		t[tier] = { cheese = Economy.cheese(300), dust = 5 }
	end
	return t
end

P.SEASONS = {
	{
		id = 1,
		name = "Winter Rind",
		premiumKey = "herd_pass_s1",
		free = winterFree(),
		premium = {
			[1] = { cosmetic = "hat_snow_cap" },
			[3] = { goldenCheese = 100 },
			[6] = { cosmetic = "trail_snowfall" },
			[8] = { goldenCheese = 100 },
			[11] = { cosmetic = "tint_frostbite" },
			[13] = { goldenCheese = 100 },
			[16] = { cosmetic = "hat_earmuffs" },
			[18] = { goldenCheese = 100 },
			[20] = { cosmetic = "trail_aurora" },
			[23] = { goldenCheese = 100 },
			[25] = { cosmetic = "tint_aurora" },
			[27] = { cosmetic = "hat_ice_crown" },
			[28] = { goldenCheese = 100 },
			[30] = { cosmetic = "trail_winter_monarch" },
		},
	},
} :: { SeasonDef }

-- Season number for a UTC day number (>= 1).
function P.seasonFor(day: number): number
	if type(day) ~= "number" or day ~= day then
		return 1
	end
	return math.max(1, math.floor((math.floor(day) - P.EPOCH_DAY) / P.SEASON_DAYS) + 1)
end

-- Day of the current season, 1..SEASON_DAYS; 0 before season 1 has started.
function P.dayInSeason(day: number): number
	if type(day) ~= "number" or day ~= day then
		return 0
	end
	local d = math.floor(day)
	if d < P.EPOCH_DAY then
		return 0
	end
	return ((d - P.EPOCH_DAY) % P.SEASON_DAYS) + 1
end

-- First and last UTC day of a season.
function P.seasonDays(season: number): (number, number)
	local s = math.max(1, math.floor(season))
	local first = P.EPOCH_DAY + (s - 1) * P.SEASON_DAYS
	return first, first + P.SEASON_DAYS - 1
end

-- The content of a season (repeats SEASONS for numbers without their own entry).
function P.season(season: number): SeasonDef
	local s = math.max(1, math.floor(if season == season then season else 1))
	for _, def in P.SEASONS do
		if def.id == s then
			return def
		end
	end
	return P.SEASONS[((s - 1) % #P.SEASONS) + 1]
end

-- The game pass that unlocks premium for this season number, or nil (not sold).
function P.premiumKey(season: number): string?
	local s = math.max(1, math.floor(if season == season then season else 1))
	for _, def in P.SEASONS do
		if def.id == s then
			local key = def.premiumKey
			if key and Monetization.get(key) then
				return key
			end
			return nil
		end
	end
	return Monetization.seasonPassKey(s)
end

-- Tier reached with `xp` Pass XP (0..TIERS).
function P.tierFor(xp: number): number
	if type(xp) ~= "number" or xp ~= xp or xp <= 0 then
		return 0
	end
	return math.min(P.TIERS, math.floor(xp / P.XP_PER_TIER))
end

-- Pass XP of one match.
function P.runXp(stagesSurvived: number?, finished: boolean?): number
	local R = P.RUN_XP
	local st = if type(stagesSurvived) == "number" and stagesSurvived == stagesSurvived
		then math.clamp(math.floor(stagesSurvived), 0, 8)
		else 0
	local xp = R.BASE + R.PER_STAGE * st + (if finished then R.FINISH else 0)
	return math.min(R.RUN_CAP, xp)
end

return P
