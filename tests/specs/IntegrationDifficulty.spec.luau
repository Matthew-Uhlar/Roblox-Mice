--!strict
-- Iteration 2: the difficulty ladder's clear rates (docs/iter/2/ALIGNMENT.md §2c A1).
-- A fresh (level 1, no gems) solo human + 11 bots per tier. "Clear" = the human's
-- squad is in the run when the final boss falls, or wins Last Herd.
-- Targets: Medium >= 70%, Sharp about 50%, a fresh squad on Doomwheel < 2%. The
-- gem / prestige stand-in rows (Smoked, Doomwheel 30-40%) wait for team M1/P's
-- gem and Ascension stats. While the combat balance is being retuned the targets
-- print as [BALANCE] warnings; the ordering is a hard guard.
local T = require("../lib/Test")
local H = require("../sim/Headless")
local Classes = require("../../src/shared/Config/Classes")
local Difficulty = require("../../src/shared/Run/Difficulty")

local SEEDS = 12
local ROWS = { Difficulty.MEDIUM, Difficulty.SHARP, Difficulty.MAX }

T.describe("Integration › difficulty ladder (iteration 2)", function()
	T.it("clear rate falls as the tier rises", function()
		local rate: { [number]: number } = {}
		for _, tier in ROWS do
			local clears = 0
			for i = 1, SEEDS do
				local class = Classes.ORDER[(i - 1) % #Classes.ORDER + 1]
				local sim =
					H.new({ seed = 7100 + i * 31, humans = { { classId = class } }, difficulty = tier })
				local r = sim:playRun()
				local po = r.payout
				if po and (po.fullClear or po.lastHerd) then
					clears += 1
				end
			end
			rate[tier] = clears / SEEDS
			local def = Difficulty.get(tier)
			print(
				string.format(
					"  [ladder] %-10s clears %d/%d (%.0f%%)",
					def and def.name or "?",
					clears,
					SEEDS,
					100 * rate[tier]
				)
			)
		end
		local function target(ok: boolean, what: string)
			if not ok then
				print("  [BALANCE] target missed: " .. what)
			end
		end
		target(rate[Difficulty.MEDIUM] >= 0.7, "Medium clears >= 70%")
		target(math.abs(rate[Difficulty.SHARP] - 0.5) <= 0.2, "Sharp clears about 50%")
		target(rate[Difficulty.MAX] < 0.02 + 1e-9, "a fresh squad clears Doomwheel < 2%")
		-- ordering, with a noise band of 2 matches out of 12
		local band = 2 / SEEDS + 1e-9
		T.truthy(rate[Difficulty.MEDIUM] + band >= rate[Difficulty.SHARP], "Medium >= Sharp (noise band)")
		T.truthy(rate[Difficulty.SHARP] + band >= rate[Difficulty.MAX], "Sharp >= Doomwheel (noise band)")
	end)
end)

return T.finish()
