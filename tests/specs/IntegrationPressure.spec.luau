--!strict
-- Pressure is a real difficulty / reward trade (GDD §3.7, FINAL-A M1): whole
-- headless runs (tests/sim/Headless.luau) of a solo "human" + 2 roster bots
-- with POIs on, Cycle 1 then Go Home, at Pressure 0, ~10 and the full board.
-- Deterministic: fixed seeds, one class per seed. More Pressure must cost wins
-- while every won run still pays more cheese.
--
-- Wider sim (8 seeds x 3 classes, same set-up; see Config/Pressure.luau):
-- P0 24/24, P10 20/24, P21 14/24 Cycle-1 wins.
local T = require("../lib/Test")
local H = require("../sim/Headless")
local Rng = require("../../src/shared/Util/Rng")
local BotRoster = require("../../src/shared/Bots/BotRoster")
local Config = require("../../src/shared/Config/Pressure")
local PressureRun = require("../../src/shared/Run/Pressure")

local CLASSES = { "ele_fonte", "elephante", "ellie_fawn" }
local RUNS = 8 -- per Pressure level; ~90 s for the whole spec

local function party(humanClass: string, seed: number): { any }
	local out: { any } = { { classId = humanClass, isBot = false } }
	for _, b in BotRoster.fill(1, 4, 3, { humanClass }, Rng.new(seed)) do
		table.insert(out, { classId = b.classId, isBot = true })
	end
	return out
end

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

type Tally = { wins: number, runs: number, winCheese: number, stages: number }

local function play(board: { [string]: number }): Tally
	local t: Tally = { wins = 0, runs = 0, winCheese = 0, stages = 0 }
	for s = 1, RUNS do
		local seed = s * 7919
		local class = CLASSES[(s - 1) % #CLASSES + 1]
		local r = H.new({
			seed = seed,
			party = party(class, seed),
			pois = true,
			pressure = board,
			bankPolicy = function(kind: string): string?
				return if kind == "cycle" then "GoHome" else nil
			end,
		}):playRun()
		t.runs += 1
		for _, st in r.stages do
			if st.outcome == "clear" then
				t.stages += 1
			end
		end
		if r.outcome == "Win" then
			t.wins += 1
			t.winCheese += r.final.cheesePerPlayer
		end
	end
	return t
end

T.describe("Integration › Pressure is a difficulty / reward trade (M1)", function()
	T.it("win(P0) > win(P10) > win(P21); the full board is still winnable and pays more", function()
		T.eq(PressureRun.points(MID), 10)
		T.eq(PressureRun.points(FULL), Config.MAX_POINTS)
		local p0, p10, p21 = play({}), play(MID), play(FULL)
		for _, row in { { "P0", p0 }, { "P10", p10 }, { "P21", p21 } } do
			local name, t = row[1] :: string, row[2] :: Tally
			print(
				string.format(
					"  [pressure] %-3s wins %d/%d  stages cleared %d  cheese per win %.0f",
					name,
					t.wins,
					t.runs,
					t.stages,
					if t.wins > 0 then t.winCheese / t.wins else 0
				)
			)
		end
		T.truthy(p0.wins > p10.wins, "P0 wins more than P10")
		T.truthy(p10.wins > p21.wins, "P10 wins more than P21")
		T.truthy(p0.stages > p21.stages, "P21 clears fewer stages")
		T.truthy(p0.wins - p21.wins >= RUNS / 4, "the full board costs at least 25 points of win rate")
		T.truthy(p0.wins >= RUNS * 0.85, "Pressure 0 stays comfortable")
		T.truthy(p21.wins >= 2, "the full board is still winnable")
		-- the reward side: a won run pays more the higher the Pressure
		local per0, per10, per21 = p0.winCheese / p0.wins, p10.winCheese / p10.wins, p21.winCheese / p21.wins
		T.truthy(per10 > per0 and per21 > per10, "cheese per won run rises with Pressure")
	end)
end)

return T.finish()
