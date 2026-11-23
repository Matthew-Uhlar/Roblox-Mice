--!strict
-- Iteration 6 §2 (team Flow): the Fast pace keeps the Medium ladder honest. A fresh
-- solo human + 11 bots on Medium, the same seeds at Normal and at Fast (waves x0.7,
-- spawn x1.35, boss squeeze x0.8). Guard: Fast clears within ±15 points of Normal.
local T = require("../lib/Test")
local H = require("../sim/Headless")
local Classes = require("../../src/shared/Config/Classes")
local Difficulty = require("../../src/shared/Run/Difficulty")

local SEEDS = 12

T.describe("Integration › pace (iteration 6)", function()
	T.it("Fast Medium clears within ±15 points of Normal Medium", function()
		local rate: { [string]: number } = {}
		local secs: { [string]: number } = {}
		for _, pace in { "normal", "fast" } do
			local clears, total = 0, 0
			for i = 1, SEEDS do
				local class = Classes.ORDER[(i - 1) % #Classes.ORDER + 1]
				local sim = H.new({
					seed = 7100 + i * 31,
					humans = { { classId = class } },
					difficulty = Difficulty.MEDIUM,
					pace = pace,
				})
				local r = sim:playRun()
				total += r.simSeconds or 0
				local po = r.payout
				if po and (po.fullClear or po.lastHerd) then
					clears += 1
				end
			end
			rate[pace] = clears / SEEDS
			secs[pace] = total / SEEDS
			print(
				string.format(
					"  [pace] Medium %-6s clears %d/%d (%.0f%%), mean match %.0f sim-s",
					pace,
					clears,
					SEEDS,
					100 * rate[pace],
					secs[pace]
				)
			)
		end
		T.truthy(math.abs(rate.fast - rate.normal) <= 0.15 + 1e-9, "Fast within ±15 points of Normal")
		T.truthy(secs.fast < secs.normal, "a Fast match is shorter")
	end)
end)

return T.finish()
