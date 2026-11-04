--!strict
-- Pressure is a real difficulty / reward trade (GDD §3.7, FINAL-A M1), in v2
-- squad matches (tests/sim/Headless.luau): a solo "human" + 11 bots in 4 squads,
-- POIs on, at Pressure 0, ~10 and the full board (Pressure is match-wide).
-- Deterministic: fixed seeds, one class per seed. A "win" is the human's squad
-- EXTRACTING (Extract at a gate, the final stage or Last Herd Standing). More
-- Pressure must cost wins while every won run still pays more cheese.
local T = require("../lib/Test")
local H = require("../sim/Headless")
local Config = require("../../src/shared/Config/Pressure")
local PressureRun = require("../../src/shared/Run/Pressure")

local CLASSES = { "ele_fonte", "elephante", "ellie_fawn" }
local RUNS = 8 -- per Pressure level; ~40 s for the whole spec

local FULL: { [string]: number } = {}
for _, def in Config.LIST do
	FULL[def.id] = def.maxRank
end
-- A typical 10-point board: one rank of everything, plus Stampede and Boss Fury.
local MID: { [string]: number } = {
	stampede = 2,
	big_cheese = 1,
	rush_hour = 1,
	slingshot_season = 1,
	hot_crumbs = 1,
	boss_fury = 2,
	thick_rind = 1,
	no_snacks = 1,
}

type Tally = {
	wins: number,
	runs: number,
	winCheese: number,
	stages: number,
	stageCheese: number, -- sum of StageResult.stageCheese (per member) over cleared stages
	cleared: number,
}

local function play(board: { [string]: number }): Tally
	local t: Tally = { wins = 0, runs = 0, winCheese = 0, stages = 0, stageCheese = 0, cleared = 0 }
	for s = 1, RUNS do
		local seed = s * 7919
		local class = CLASSES[(s - 1) % #CLASSES + 1]
		local r = H.new({
			seed = seed,
			humans = { { classId = class } },
			pressure = board,
		}):playRun()
		t.runs += 1
		for _, st in r.stages do
			if st.outcome == "clear" then
				t.stages += 1
			end
			if st.result then
				t.cleared += 1
				t.stageCheese += st.result.stageCheese
			end
		end
		if r.outcome == "Win" then
			t.wins += 1
			t.winCheese += r.payout.cheese
		end
	end
	return t
end

T.describe("Integration › Pressure is a difficulty / reward trade (M1)", function()
	T.it("win(P0) > win(P10) > win(P21); the full board is still winnable and pays more per stage", function()
		T.eq(PressureRun.points(MID), 10)
		T.eq(PressureRun.points(FULL), Config.MAX_POINTS)
		local p0, p10, p21 = play({}), play(MID), play(FULL)
		for _, row in { { "P0", p0 }, { "P10", p10 }, { "P21", p21 } } do
			local name, t = row[1] :: string, row[2] :: Tally
			print(
				string.format(
					"  [pressure] %-3s wins %d/%d  stages cleared %d  cheese per win %.0f  stage cheese/member %.0f",
					name,
					t.wins,
					t.runs,
					t.stages,
					if t.wins > 0 then t.winCheese / t.wins else 0,
					t.stageCheese / math.max(1, t.cleared)
				)
			)
		end
		T.truthy(p0.wins > p10.wins, "P0 wins more than P10")
		T.truthy(p10.wins > p21.wins, "P10 wins more than P21")
		T.truthy(p0.stages > p21.stages, "P21 clears fewer stages")
		T.truthy(p0.wins - p21.wins >= RUNS / 4, "the full board costs at least 25 points of win rate")
		T.truthy(p21.wins >= 1, "the full board is still winnable")
		-- The reward side: the same stage pays more cheese per member the higher the
		-- Pressure. (v2 matches mostly end in stage 1 today, so cheese per won match
		-- is too noisy to rank; the v1 "P0 >= 85% wins" comfort target is not met
		-- under squad PvP: see the printed table and the lead's report.)
		T.truthy(
			p10.stageCheese / p10.cleared > p0.stageCheese / p0.cleared
				and p21.stageCheese / math.max(1, p21.cleared) > p10.stageCheese / p10.cleared,
			"stage cheese per member rises with Pressure"
		)
	end)
end)

return T.finish()
