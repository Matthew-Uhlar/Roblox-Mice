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
		-- M1 ladder tuning (bots x0.5 vs human squads, Moldy / Doomwheel bases): hard guards
		T.truthy(rate[Difficulty.MEDIUM] >= 0.7, "Medium clears >= 70%")
		target(math.abs(rate[Difficulty.SHARP] - 0.5) <= 0.2, "Sharp clears about 50%")
		T.truthy(rate[Difficulty.MAX] < 0.02 + 1e-9, "a fresh squad clears Doomwheel < 2%")
		-- ordering, with a noise band of 2 matches out of 12
		local band = 2 / SEEDS + 1e-9
		T.truthy(rate[Difficulty.MEDIUM] + band >= rate[Difficulty.SHARP], "Medium >= Sharp (noise band)")
		T.truthy(rate[Difficulty.SHARP] + band >= rate[Difficulty.MAX], "Sharp >= Doomwheel (noise band)")
	end)
end)

-- Iteration 4 (T-2 stand-in): a maxed veteran (Prestige 40+, all 8 Ascension nodes, two
-- max-level top-tier gems) solo with two bot squadmates, which get Run/BotBonus (60%
-- of the human's long-term bonus). Target (lead): Doomwheel >= 25%; reported as a
-- [BALANCE] line until M1/P tune it.
local RunBonus = require("../../src/shared/Data/RunBonus")
local Ascension = require("../../src/shared/Data/Ascension")
local Gems = require("../../src/shared/Data/Gems")
local GemConfig = require("../../src/shared/Config/Gems")

local function maxedBonus(classId: string): any
	local profile: any = { classes = { [classId] = { prestige = 99, stomps = 1e7 } } }
	local b = RunBonus.new()
	RunBonus.merge(b, Ascension.bonus(profile, classId))
	local gems = {}
	for k = 1, 2 do
		local r = Gems.roll(900 + k, GemConfig.MAX_TIER, { high = true })
		table.insert(gems, { id = k, t = r.t, s = r.s, lv = GemConfig.MAX_LEVEL })
	end
	RunBonus.merge(b, Gems.aura({ gems }).bonus)
	return RunBonus.resolve(b, {})
end

T.describe("Integration › maxed veteran (iteration 4 stand-in)", function()
	T.it("a maxed veteran + scaled bots on Doomwheel", function()
		local clears = 0
		for i = 1, SEEDS do
			local class = Classes.ORDER[(i - 1) % #Classes.ORDER + 1]
			local sim = H.new({
				seed = 7100 + i * 31,
				humans = { { classId = class } },
				difficulty = Difficulty.MAX,
				humanBonus = maxedBonus(class),
			})
			local po = sim:playRun().payout
			if po and (po.fullClear or po.lastHerd) then
				clears += 1
			end
		end
		print(
			string.format(
				"  [ladder] Doomwheel, maxed veteran: clears %d/%d (%.0f%%)",
				clears,
				SEEDS,
				100 * clears / SEEDS
			)
		)
		-- M1 iteration 4 retune (Doomwheel 1.3 / 1.15 / 1.05): a hard guard
		T.truthy(clears / SEEDS >= 0.25, "a maxed veteran clears Doomwheel >= 25%")
	end)
end)

return T.finish()
