local T = require("../lib/Test")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local RunTokens = require("../../src/shared/Data/RunTokens")
local Boosts = require("../../src/shared/Data/Boosts")

T.describe("RunTokens.useSecondWind", function()
	T.it("first revive is free, then tokens, max 1 per stage and 2 tokens per run", function()
		local p = ProfileSchema.default()
		p.secondWindTokens = 5
		local s = RunTokens.new()
		local ok, src = RunTokens.useSecondWind(s, p, "1-1")
		T.truthy(ok)
		T.eq(src, "free")
		T.eq(p.secondWindTokens, 5)
		T.falsy(RunTokens.useSecondWind(s, p, "1-1"), "1 per stage")
		T.eq(select(2, RunTokens.useSecondWind(s, p, "1-1")), "stage_cap")
		T.eq(select(2, RunTokens.useSecondWind(s, p, "1-2")), "token")
		T.eq(select(2, RunTokens.useSecondWind(s, p, "1-3")), "token")
		T.eq(select(2, RunTokens.useSecondWind(s, p, "1-4")), "run_cap")
		T.eq(p.secondWindTokens, 3)
		T.truthy(s.usedToken, "run becomes unranked")
	end)
	T.it("blocks token revives on low boss HP and Double or Nothing", function()
		local p = ProfileSchema.default()
		p.secondWindTokens = 2
		local s = RunTokens.new()
		RunTokens.useSecondWind(s, p, "a")
		T.eq(select(2, RunTokens.useSecondWind(s, p, "b", { bossHpFrac = 0.05 })), "blocked_boss_low")
		T.eq(
			select(2, RunTokens.useSecondWind(s, p, "b", { doubleOrNothing = true })),
			"blocked_double_or_nothing"
		)
		T.eq(p.secondWindTokens, 2)
		T.falsy(s.usedToken)
		T.truthy(RunTokens.useSecondWind(s, p, "b", { bossHpFrac = 0.5 }))
	end)
	T.it(
		"[QC-B V2-M1] token revives are blocked while 2+ squads are in the run; the free one is not",
		function()
			local p = ProfileSchema.default()
			p.secondWindTokens = 3
			local s = RunTokens.new()
			local ok, how = RunTokens.useSecondWind(s, p, "a", { squadsInRun = 4 })
			T.truthy(ok, "the free revive still works in PvP")
			T.eq(how, "free")
			for _, n in { 4, 3, 2 } do
				T.eq(
					select(2, RunTokens.useSecondWind(s, p, "b" .. n, { squadsInRun = n })),
					"blocked_pvp",
					n .. " squads"
				)
			end
			T.eq(p.secondWindTokens, 3, "no token spent")
			T.falsy(s.usedToken)
			T.eq(
				RunTokens.secondWindsAvailable(s, p, "c", { squadsInRun = 2 }),
				0,
				"HUD shows no token revive"
			)
			T.eq(RunTokens.secondWindsAvailable(s, p, "c", { squadsInRun = 1 }), 2)
			T.eq(
				select(2, RunTokens.useSecondWind(s, p, "c", { squadsInRun = 1 })),
				"token",
				"last squad standing"
			)
			T.eq(p.secondWindTokens, 2)
			T.truthy(RunTokens.blockedByPvp({ squadsInRun = 2 }))
			T.falsy(RunTokens.blockedByPvp({ squadsInRun = 1 }))
			T.falsy(RunTokens.blockedByPvp(nil))
		end
	)
	T.it("[QC-B V2-M1] free revive is reported in PvP, tokens are not", function()
		local p = ProfileSchema.default()
		p.secondWindTokens = 5
		local s = RunTokens.new()
		T.eq(RunTokens.secondWindsAvailable(s, p, "a", { squadsInRun = 3 }), 1)
	end)
	T.it("fails without tokens and on bad stage keys", function()
		local p = ProfileSchema.default()
		local s = RunTokens.new()
		RunTokens.useSecondWind(s, p, "a")
		T.eq(select(2, RunTokens.useSecondWind(s, p, "b")), "no_tokens")
		T.eq(select(2, RunTokens.useSecondWind(s, p, 5 :: any)), "bad_stage")
	end)
	T.it("reports availability for the HUD", function()
		local p = ProfileSchema.default()
		p.secondWindTokens = 1
		local s = RunTokens.new()
		T.eq(RunTokens.secondWindsAvailable(s, p, "a"), 2)
		RunTokens.useSecondWind(s, p, "a")
		T.eq(RunTokens.secondWindsAvailable(s, p, "a"), 0)
		T.eq(RunTokens.secondWindsAvailable(s, p, "b"), 1)
	end)
end)

T.describe("RunTokens rerolls", function()
	T.it("caps token rerolls per stage", function()
		local p = ProfileSchema.default()
		p.rerollTokens = 5
		local s = RunTokens.new()
		T.eq(RunTokens.rerollsAvailable(s, p, "a"), 2)
		T.truthy(RunTokens.useReroll(s, p, "a"))
		T.truthy(RunTokens.useReroll(s, p, "a"))
		T.eq(select(2, RunTokens.useReroll(s, p, "a")), "stage_cap")
		T.truthy(RunTokens.useReroll(s, p, "b"))
		T.eq(p.rerollTokens, 2)
	end)
end)

T.describe("Boosts", function()
	T.it("adds bonuses and never multiplies them together", function()
		T.eq(Boosts.cheeseMult({}), 1)
		T.near(Boosts.cheeseMult({ herdLeader = true }), 1.15)
		T.near(Boosts.cheeseMult({ herdLeader = true, feast = true, premium = true, rush = true }), 2.75)
		T.eq(Boosts.xpMult(true), 2)
		T.eq(Boosts.xpMult(false), 1)
	end)
	T.it("extendUntil stacks time with a cap", function()
		T.eq(Boosts.extendUntil(0, 100, 50, 1000), 150)
		T.eq(Boosts.extendUntil(150, 100, 50, 1000), 200)
		T.eq(Boosts.extendUntil(1050, 100, 50, 1000), 1100)
	end)
end)

return T.finish()
