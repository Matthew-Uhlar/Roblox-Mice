local T = require("../lib/Test")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local Daily = require("../../src/shared/Data/Daily")
local Monetization = require("../../src/shared/Config/Monetization")

T.describe("Daily.claim", function()
	T.it("claims once per day", function()
		local p = ProfileSchema.default()
		local ok, r = Daily.claim(p, 100)
		T.truthy(ok)
		T.eq(r.day, 1)
		T.eq(r.granted.cheese, 100)
		T.eq(p.cheese, 100)
		local ok2, why = Daily.claim(p, 100)
		T.falsy(ok2)
		T.eq(why, "already_claimed")
		T.eq(p.cheese, 100)
	end)
	T.it("walks the 7-day ladder and loops", function()
		local p = ProfileSchema.default()
		local days = {}
		for d = 1, 9 do
			local ok, r = Daily.claim(p, 200 + d)
			T.truthy(ok)
			days[d] = r.day
		end
		T.deepEq(days, { 1, 2, 3, 4, 5, 6, 7, 1, 2 })
		T.eq(p.daily.streak, 9)
		T.eq(p.secondWindTokens, 1)
		T.eq(p.goldenCheese, 25)
		T.truthy(p.cosmetics.tint_sunny)
		T.truthy(p.cosmetics.trail_streak)
	end)
	T.it("gives a fixed fallback for owned cosmetic days", function()
		local p = ProfileSchema.default()
		p.cosmetics.tint_sunny = true
		p.daily = { lastClaimDay = 49, streak = 3 }
		local ok, r = Daily.claim(p, 50)
		T.truthy(ok)
		T.eq(r.day, 4)
		T.eq(r.granted.rerollTokens, 3)
		T.eq(p.rerollTokens, 3)
	end)
	T.it("steps back one day per missed day instead of resetting", function()
		local p = ProfileSchema.default()
		p.daily = { lastClaimDay = 10, streak = 5 }
		local ok, r = Daily.claim(p, 12) -- missed day 11
		T.truthy(ok)
		T.eq(p.daily.streak, 5, "repeats day 5 instead of advancing to 6")
		T.eq(r.day, 5)
		p.daily = { lastClaimDay = 10, streak = 5 }
		Daily.claim(p, 13) -- missed 2 days
		T.eq(p.daily.streak, 4)
		p.daily = { lastClaimDay = 10, streak = 5 }
		Daily.claim(p, 40) -- long break floors at day 1
		T.eq(p.daily.streak, 1)
	end)
	T.it("rejects bad day numbers and backwards clocks", function()
		local p = ProfileSchema.default()
		for _, bad in { 0, -1, 1.5, 0 / 0, "5", nil } do
			T.falsy((Daily.claim(p, bad :: any)), tostring(bad))
		end
		p.daily = { lastClaimDay = 50, streak = 2 }
		local ok, why = Daily.claim(p, 49)
		T.falsy(ok)
		T.eq(why, "clock")
	end)
	T.it("adds the fixed VIP bonus", function()
		local p = ProfileSchema.default()
		local _, r = Daily.claim(p, 7, { vip = true })
		T.eq(p.cheese, 100 + Monetization.RULES.vipDailyCheese)
		T.eq(p.goldenCheese, Monetization.RULES.vipDailyGolden)
		T.truthy(r.vipBonus)
	end)
	T.it("never contains a random reward", function()
		for _, r in Daily.REWARDS do
			T.eq((r :: any).random, nil)
			T.eq((r :: any).weights, nil)
		end
	end)
end)

T.describe("Daily.claimClub", function()
	T.it("grants the club daily once per day", function()
		local p = ProfileSchema.default()
		T.truthy(Daily.claimClub(p, 300))
		T.eq(p.goldenCheese, Monetization.RULES.clubDailyGolden)
		T.eq(p.secondWindTokens, Monetization.RULES.clubDailySecondWinds)
		T.falsy(Daily.claimClub(p, 300))
		T.falsy(Daily.claimClub(p, 299))
		T.truthy(Daily.claimClub(p, 301))
		T.eq(p.goldenCheese, 2 * Monetization.RULES.clubDailyGolden)
	end)
end)

return T.finish()
