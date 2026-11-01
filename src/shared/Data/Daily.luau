--!strict
-- 7-day login streak (Team D). Pure: the caller passes the UTC day number
-- (DataService uses math.floor(os.time() / 86400)).
--
-- Rules (docs/research/monetization.md §4):
--   * Claim once per day. Consecutive days advance the streak; day 8 loops to day 1
--     of the ladder while the streak counter keeps counting.
--   * Each MISSED day steps the streak back one day instead of resetting it, so a
--     single missed day repeats the last reward. Streak restores are never sold.
--   * Reward ladder: cheese, cheese, Second Wind, tint, cheese, Golden Cheese, trail.
--     Cosmetic days fall back to a fixed alternative if already owned.
--   * VIP adds a fixed bonus. Cheese Club's daily grant is separate (claimClub),
--     granted automatically on login while subscribed.

local Types = require("../Types")
local Monetization = require("../Config/Monetization")
local Cosmetics = require("../Config/Cosmetics")
local Award = require("./Award")

type Profile = Types.Profile

export type Grant = {
	cheese: number?,
	goldenCheese: number?,
	secondWindTokens: number?,
	rerollTokens: number?,
	cosmetic: string?,
}

export type RewardDef = Grant & { fallback: Grant? }

local Daily = {}

Daily.LADDER_LENGTH = 7

Daily.REWARDS = {
	{ cheese = 100 },
	{ cheese = 150 },
	{ secondWindTokens = 1 },
	{ cosmetic = "tint_sunny", fallback = { rerollTokens = 3 } },
	{ cheese = 300 },
	{ goldenCheese = 25 },
	{ cosmetic = "trail_streak", fallback = { cheese = 500 } },
} :: { RewardDef }

local function validDay(day: any): boolean
	return type(day) == "number" and day == day and day >= 1 and day < 1e7 and math.floor(day) == day
end

-- Streak value a claim on `day` would produce, or nil if not claimable.
function Daily.nextStreak(profile: Profile, day: number): (number?, string?)
	if not validDay(day) then
		return nil, "bad_day"
	end
	local last = profile.daily.lastClaimDay
	local streak = profile.daily.streak
	if last == day then
		return nil, "already_claimed"
	end
	if last > day then
		return nil, "clock" -- server clock went backwards; refuse rather than double-claim
	end
	if last == 0 or streak <= 0 then
		return 1, nil
	end
	local missed = day - last - 1
	return math.max(0, streak - missed) + 1, nil
end

-- 1..7 ladder position for a streak value.
function Daily.ladderIndex(streak: number): number
	return ((math.max(1, streak) - 1) % Daily.LADDER_LENGTH) + 1
end

local function apply(profile: Profile, g: Grant, out: Grant)
	if g.cheese then
		profile.cheese = Award.clampCurrency(profile.cheese + g.cheese)
		out.cheese = (out.cheese or 0) + g.cheese
	end
	if g.goldenCheese then
		profile.goldenCheese = Award.clampCurrency(profile.goldenCheese + g.goldenCheese)
		out.goldenCheese = (out.goldenCheese or 0) + g.goldenCheese
	end
	if g.secondWindTokens then
		profile.secondWindTokens += g.secondWindTokens
		out.secondWindTokens = (out.secondWindTokens or 0) + g.secondWindTokens
	end
	if g.rerollTokens then
		profile.rerollTokens += g.rerollTokens
		out.rerollTokens = (out.rerollTokens or 0) + g.rerollTokens
	end
	if g.cosmetic then
		profile.cosmetics[g.cosmetic] = true
		out.cosmetic = g.cosmetic
	end
end

export type ClaimCtx = { vip: boolean? }
export type ClaimResult = { day: number, streak: number, granted: Grant, vipBonus: boolean }

-- Returns (true, result) or (false, reason).
function Daily.claim(profile: Profile, day: number, ctx: ClaimCtx?): (boolean, any)
	local streak, reason = Daily.nextStreak(profile, day)
	if not streak then
		return false, reason
	end
	local idx = Daily.ladderIndex(streak)
	local def = Daily.REWARDS[idx]
	local granted: Grant = {}
	if def.cosmetic and Cosmetics.get(def.cosmetic) and not profile.cosmetics[def.cosmetic] then
		apply(profile, { cosmetic = def.cosmetic }, granted)
	elseif def.cosmetic then
		apply(profile, def.fallback or {}, granted)
	else
		apply(profile, def, granted)
	end
	local vip = ctx ~= nil and ctx.vip == true
	if vip then
		local R = Monetization.RULES
		apply(profile, { cheese = R.vipDailyCheese, goldenCheese = R.vipDailyGolden }, granted)
	end
	profile.daily.lastClaimDay = day
	profile.daily.streak = streak
	return true, { day = idx, streak = streak, granted = granted, vipBonus = vip } :: ClaimResult
end

-- Cheese Club daily grant (call on login / status check while subscribed). Once per day.
function Daily.claimClub(profile: Profile, day: number): (boolean, any)
	if not validDay(day) then
		return false, "bad_day"
	end
	if profile.club.lastDailyDay >= day then
		return false, "already_claimed"
	end
	local R = Monetization.RULES
	local granted: Grant = {}
	apply(profile, { goldenCheese = R.clubDailyGolden, secondWindTokens = R.clubDailySecondWinds }, granted)
	profile.club.lastDailyDay = day
	return true, granted
end

return Daily
