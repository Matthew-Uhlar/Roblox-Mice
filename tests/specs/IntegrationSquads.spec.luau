--!strict
-- v2 squad balance (lead, docs/GDD-v2.md §1–2): unassisted headless matches
-- (tests/sim/Headless.luau) of a solo "human" (a BotBrain stand-in) + 11 bots
-- in 4 squads, POIs on, real 150 s waves. Prints each squad's extraction /
-- elimination rate and the PvP downs and kills; asserts that no squad is ever
-- immune (every seat gets eliminated in some match), that PvP never hits a
-- squad-mate, that the GDD-v2 §2 pacing targets hold (with some margin), and
-- that a full 4-stage match finishes within the time limits.
local T = require("../lib/Test")
local H = require("../sim/Headless")
local MatchState = require("../../src/shared/Run/MatchState")
local Classes = require("../../src/shared/Config/Classes")

local SEEDS =
	{ 3, 14, 15, 92, 65, 35, 89, 79, 32, 38, 46, 26, 43, 138, 27, 95, 2, 88, 41, 97, 16, 93, 99, 37 }
local C = MatchState.CONFIG
-- Live server limits per stage (RunDirector): waves + boss timeout + the
-- stage-clear beat, the route choice and the extraction window.
local STAGE_LIMIT = H.WAVE_SECONDS + H.BOSS_SECONDS + 4 + 15 + 20

type Row = {
	matches: number,
	extracted: number,
	lastHerd: number,
	eliminated: number,
	other: number,
	pvpDowns: number,
	pvpKills: number,
	stagesReached: number,
	human: number,
}

T.describe("Integration › squad balance (solo human + 11 bots)", function()
	local rows: { [number]: Row } = {}
	for s = 1, 4 do
		rows[s] = {
			matches = 0,
			extracted = 0,
			lastHerd = 0,
			eliminated = 0,
			other = 0,
			pvpDowns = 0,
			pvpKills = 0,
			stagesReached = 0,
			human = 0,
		}
	end
	local bySeat: { [string]: Row } = {
		human = {
			matches = 0,
			extracted = 0,
			lastHerd = 0,
			eliminated = 0,
			other = 0,
			pvpDowns = 0,
			pvpKills = 0,
			stagesReached = 0,
			human = 0,
		},
		bot = {
			matches = 0,
			extracted = 0,
			lastHerd = 0,
			eliminated = 0,
			other = 0,
			pvpDowns = 0,
			pvpKills = 0,
			stagesReached = 0,
			human = 0,
		},
	}
	local stageCounts: { [number]: number } = {}
	local friendly = 0
	local maxSim = 0
	-- Pacing (GDD-v2 §2): per match
	local stage1Elims, elims, downs, kills = 0, 0, 0, 0
	local firstDowns: { number } = {}
	local botSeats, botOut = 0, 0

	T.it("plays " .. #SEEDS .. " unassisted matches", function()
		print("\n  [squads] seed  human  stages  end        squads (out@stage)")
		for i, seed in SEEDS do
			local class = Classes.ORDER[(i - 1) % #Classes.ORDER + 1]
			local sim = H.new({
				seed = seed,
				humans = { { classId = class } },
			})
			local r = sim:playRun()
			friendly += r.totals.friendlyHits
			stage1Elims += #r.stages[1].eliminated
			downs += r.totals.pvpDowns
			kills += r.totals.pvpKills
			local before = 0
			for _, st in r.stages do
				if st.firstPvpDownAt then
					table.insert(firstDowns, before + st.firstPvpDownAt)
					break
				end
				before += st.waveTime + (st.bossTime or 0)
			end
			for _, q in r.squads do
				if q.outReason == "eliminated" then
					elims += 1
				end
				if q.humans == 0 then
					botSeats += 1
					if q.outReason == "extracted" or q.outReason == "final" or q.outReason == "lastHerd" then
						botOut += 1
					end
				end
			end
			maxSim = math.max(maxSim, r.simSeconds)
			stageCounts[#r.stages] = (stageCounts[#r.stages] or 0) + 1
			local parts = {}
			for _, q in r.squads do
				local row = rows[q.id]
				local seat = if q.humans > 0 then bySeat.human else bySeat.bot
				for _, x in { row, seat } do
					x.matches += 1
					x.pvpDowns += q.pvpDowns
					x.pvpKills += q.pvpKills
					x.stagesReached += q.outAtStage or #r.stages
					if q.humans > 0 then
						x.human += 1
					end
					if q.outReason == "extracted" or q.outReason == "final" then
						x.extracted += 1
					elseif q.outReason == "lastHerd" then
						x.lastHerd += 1
					elseif q.outReason == "eliminated" then
						x.eliminated += 1
					else
						x.other += 1
					end
				end
				table.insert(
					parts,
					string.format(
						"%d%s:%s@%s",
						q.id,
						if q.humans > 0 then "*" else "",
						tostring(q.outReason),
						tostring(q.outAtStage)
					)
				)
			end
			print(
				string.format(
					"  [squads] %4d  %-5s  %d       %-10s %s",
					seed,
					r.outcome,
					#r.stages,
					tostring(r.endReason),
					table.concat(parts, " ")
				)
			)
			T.eq(sim.match.phase, "Results")
		end
	end)

	T.it("prints extraction rates and PvP counts per squad", function()
		print(
			"\n  [squads] squad        matches extract lastHerd elim other  avg out@stage  pvp downs  pvp kills"
		)
		local function line(name: string, r: Row)
			print(
				string.format(
					"  [squads] %-12s %7d %7.0f%% %7.0f%% %4.0f%% %5.0f%%  %13.2f  %9d  %9d",
					name,
					r.matches,
					100 * r.extracted / math.max(1, r.matches),
					100 * r.lastHerd / math.max(1, r.matches),
					100 * r.eliminated / math.max(1, r.matches),
					100 * r.other / math.max(1, r.matches),
					r.stagesReached / math.max(1, r.matches),
					r.pvpDowns,
					r.pvpKills
				)
			)
		end
		for s = 1, 4 do
			line("seat " .. s, rows[s])
		end
		line("human squad", bySeat.human)
		line("bot squads", bySeat.bot)
		local hist = {}
		for n = 1, C.STAGES do
			table.insert(hist, n .. ":" .. (stageCounts[n] or 0))
		end
		print(
			"  [squads] matches by stages played: "
				.. table.concat(hist, " ")
				.. string.format("  (longest %.0f sim-s)", maxSim)
		)
		T.eq(friendly, 0, "no damage between squad-mates")
	end)

	T.it("pacing (GDD-v2 §2): late first blood, few stage-1 wipes, deep matches, bots get out", function()
		local n = #SEEDS
		table.sort(firstDowns)
		local median = firstDowns[math.max(1, math.ceil(#firstDowns / 2))] or math.huge
		local reach3 = (stageCounts[3] or 0) + (stageCounts[4] or 0)
		print(
			string.format(
				"  [pacing] %d matches: reach stage 3+ %.0f%%, stage 4 %.0f%%; stage-1 eliminations %.2f/match; "
					.. "eliminations %.2f/match; first PvP down median %.0f s; PvP downs %.1f, kills %.1f per match; "
					.. "bot squads out alive %.0f%%",
				n,
				100 * reach3 / n,
				100 * (stageCounts[4] or 0) / n,
				stage1Elims / n,
				elims / n,
				median,
				downs / n,
				kills / n,
				100 * botOut / math.max(1, botSeats)
			)
		)
		-- Guards with margin (see docs/HANDOFF.md for the 48-seed numbers).
		T.truthy(reach3 / n >= 0.4, "matches reaching stage 3+")
		T.truthy((stageCounts[4] or 0) / n >= 0.15, "matches reaching stage 4")
		T.truthy(stage1Elims / n <= 1, "at most 1 stage-1 elimination per match on average")
		T.truthy(median >= 45, "first PvP down after 45 s (median)")
		T.truthy(botOut / math.max(1, botSeats) >= 0.2, "bot squads get out alive")
		T.truthy(elims / n >= 1 and kills / n >= 3, "PvP still matters (eliminations, kill feed)")
	end)

	T.it("no squad is immune: every seat gets eliminated in some match", function()
		for s = 1, 4 do
			T.truthy(rows[s].eliminated > 0, "seat " .. s .. " was never eliminated")
		end
		T.truthy(bySeat.human.eliminated > 0, "the human's squad was never eliminated")
		T.truthy(bySeat.bot.eliminated > 0, "bot squads were never eliminated")
		T.truthy(bySeat.human.pvpDowns + bySeat.bot.pvpDowns > 0, "PvP happened")
	end)
end)

T.describe("Integration › [regression] a wiped squad at the Rind Gate", function()
	T.it("all members downed during the gate window: eliminated with bags, never extracted", function()
		-- The human's squad votes Extract, then every member goes down while the
		-- gate is open (the World's own Second Wind grace outlasts the window).
		local downedAt = nil
		local sim
		sim = H.new({
			seed = 77,
			humans = { { classId = "elephante" } },
			humanSecondWind = false,
			maxStages = 1,
			extractPolicy = function()
				return "Extract"
			end,
			onTick = function(sm: any, phase: string)
				local mine = sm.human.squad
				for _, p in sm.world.playerList do
					if phase == "Extraction" and p.squad == mine then
						if not p.downed and not p.dead then
							sm.world:_down(p, nil)
							downedAt = downedAt or sm.now
						end
					elseif not p.downed and not p.dead then
						p.hp = p.maxHp -- everyone reaches the gate
					end
				end
			end,
		})
		local r = sim:playRun()
		local s = r.squads[r.humanSquad]
		T.truthy(downedAt ~= nil, "the squad went down at the gate")
		T.eq(s.outReason, "eliminated", "out reason")
		T.eq(s.outAtStage, 1)
		T.falsy(s.extracted, "never extracted")
		T.eq(r.payout.result, "eliminated")
		T.falsy(r.payout.extracted)
		T.truthy(r.stages[1].bags >= 1, "loot bags dropped through the elimination path")
		T.falsy(table.find(r.stages[1].extracted, r.humanSquad), "not in the stage's extracted list")
	end)
end)

T.describe("Integration › a full 4-stage match", function()
	T.it("with every squad staying, 4 stages finish within the live time limits", function()
		-- Everyone stays at every gate (the human and every bot squad). Heroes are
		-- kept at full HP so all 4 squads go the distance (unassisted matches
		-- often end earlier, see the table above); waves, PvP and the bosses run
		-- for real, so this measures the stage and boss timings.
		local sim = H.new({
			seed = 4242,
			humans = { { classId = "elephante" } },
			extractPolicy = function()
				return "Stay"
			end,
			onTick = function(sm: any)
				for _, p in sm.world.playerList do
					if not p.downed and not p.dead then
						p.hp = p.maxHp
					end
				end
			end,
		})
		-- bot-only squads decide through BotBrain.chooseExtract; force Stay too
		local orig = sim._extractChoices
		sim._extractChoices = function(self: any)
			local out = orig(self)
			for s in out do
				out[s] = "Stay"
			end
			return out
		end
		local r = sim:playRun()
		for _, s in r.stages do
			print(H.formatStage(s))
			T.truthy(
				s.waveTime + (s.bossTime or 0) <= STAGE_LIMIT,
				"stage " .. s.stage .. " within the limit"
			)
			T.falsy(s.bossTimeout, "stage " .. s.stage .. " boss died before the timeout")
		end
		print(
			string.format(
				"  [full] %d stages, %.0f sim-s, end %s",
				#r.stages,
				r.simSeconds,
				tostring(r.endReason)
			)
		)
		T.eq(#r.stages, C.STAGES, "4 stages played")
		T.eq(r.endReason, "final", "survivors extracted after stage 4")
		T.truthy(r.simSeconds <= C.STAGES * STAGE_LIMIT, "the match fits 4 stage limits")
		T.eq(sim.match.phase, "Results")
	end)
end)

return T.finish()
