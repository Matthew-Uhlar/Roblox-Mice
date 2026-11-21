--!strict
-- Run/MatchState Overtime (iteration 5 #6): the final Rind Gate, endless scaling
-- waves, the per-wave bonus, extract vs wipe.
local T = require("../lib/Test")
local MatchState = require("../../src/shared/Run/MatchState")
local Ids = require("../../src/shared/Util/Ids")

local C = MatchState.CONFIG

-- squad s = human s + 2 bots (humans 1..4)
local function lobby(): { any }
	local list = {}
	local nBot = 0
	for s = 1, 4 do
		table.insert(list, { id = s, squad = s, isBot = false })
		for _ = 1, 2 do
			nBot += 1
			table.insert(list, { id = Ids.botId(nBot), squad = s, isBot = true })
		end
	end
	return list
end

local function dmg(): { [number]: number }
	return { [1] = 10, [2] = 5, [3] = 5, [4] = 5 }
end

-- Plays to the final boss clear (everyone stays). Returns the match.
local function toFinal(overtime: boolean?): any
	local m = MatchState.new(7, lobby(), { overtime = overtime })
	m:begin()
	for _ = 1, C.STAGES - 1 do
		m:startBoss()
		m:bossDefeated(1, dmg())
		m:chooseRoute(MatchState.defaultRouteIndex(m:routeCards()), m:routeChooser())
		m:resolveExtraction({})
	end
	m:startBoss()
	m:bossDefeated(1, dmg())
	return m
end

T.describe("MatchState Overtime", function()
	T.it("off by default: the final clear ends the match as before", function()
		local m = toFinal(nil)
		T.eq(m.phase, "Results")
		T.eq(m.endReason, "final")
		T.eq(m:payout(1).result, "extracted")
	end)

	T.it("on: the final clear opens a final gate; nobody picks Overtime = the old ending", function()
		local m = toFinal(true)
		T.eq(m.phase, "Extraction")
		T.truthy(m:isFinalGate())
		T.eq(m:getPublic(1).finalGate, true)
		local share = m:shareOf(1)
		T.truthy(share > 0)
		local res = m:resolveExtraction({ [1] = "Stay", [2] = "DoubleOrNothing" }) -- both count as Extract
		T.eq(res.finished, true)
		T.eq(m.phase, "Results")
		T.eq(m.endReason, "final")
		T.eq(#res.out, 12)
		local po = m:payout(1)
		T.eq(po.result, "extracted")
		T.eq(po.fullClear, true)
		T.eq(po.overtimeWaves, 0)
	end)

	T.it("Overtime: the pot banks at once, waves pay, extract keeps the bonus", function()
		local m = toFinal(true)
		local before = m:shareOf(1)
		local banked0 = m:member(1).banked
		local res = m:resolveExtraction({ [1] = "Overtime" })
		T.eq(res.finished, false)
		T.eq(m.phase, "Overtime")
		T.eq(#(res.overtime :: any), 1)
		T.eq(#res.extracted, 3, "the other squads extract")
		T.eq(#res.out, 9)
		T.eq(m:payout(4).result, "extracted")
		T.eq(m:shareOf(1), 0, "pot banked")
		T.eq(m:member(1).banked, banked0 + before)
		T.eq(m:member(1).secured >= before, true, "secured")
		T.eq(m:overtimeWave(), 0)
		local xp0 = m:member(1).xp
		local w1 = m:overtimeWaveCleared()
		T.eq(w1.wave, 1)
		T.eq(w1.cheese, C.OVERTIME_CHEESE)
		local w2 = m:overtimeWaveCleared()
		T.eq(w2.cheese, C.OVERTIME_CHEESE + C.OVERTIME_CHEESE_STEP)
		T.eq(m:shareOf(1), w1.cheese + w2.cheese)
		T.eq(m:member(1).xp, xp0 + 2 * C.OVERTIME_XP)
		T.eq(m:getPublic(1).overtime.wave, 2)
		local out = m:extractOvertime(1)
		T.eq(#out, 3)
		T.eq(m.phase, "Results")
		T.eq(m.endReason, "overtime")
		local po = m:payout(1)
		T.eq(po.result, "extracted")
		T.eq(po.won, true)
		T.eq(po.fullClear, true)
		T.eq(po.overtimeWaves, 2)
		T.eq(po.cheese, banked0 + before + w1.cheese + w2.cheese)
	end)

	T.it("a wipe in Overtime keeps the pot and half the Overtime share; still a clear", function()
		local m = toFinal(true)
		local before = m:shareOf(2) + m:member(2).banked
		m:resolveExtraction({ [1] = "Overtime", [2] = "Overtime" })
		T.eq(m.phase, "Overtime")
		local w = m:overtimeWaveCleared()
		local res = m:eliminateSquad(2)
		T.eq(#res.drops, 0, "no loot bag in Overtime")
		T.eq(#res.out, 3)
		T.eq(m.phase, "Overtime", "squad 1 plays on")
		local po = m:payout(2)
		T.eq(po.result, "extracted")
		T.eq(po.cheese, before + math.floor(w.cheese * C.ELIMINATED_KEEP_FRAC))
		T.eq(po.overtimeWaves, 1)
		m:eliminateSquad(1)
		T.eq(m.phase, "Results")
		T.eq(m.endReason, "overtime")
	end)

	T.it("the mice multiplier grows 12% per wave; leavers in Overtime are handled", function()
		T.eq(MatchState.overtimeMult(0), 1)
		T.near(MatchState.overtimeMult(1), 1.12, 1e-9)
		T.near(MatchState.overtimeMult(5), 1.6, 1e-9)
		T.eq(MatchState.overtimeMult(0 / 0), 1)
		local m = toFinal(true)
		m:resolveExtraction({ [1] = "Overtime" })
		m:overtimeWaveCleared()
		local po = m:removeMember(1)
		T.truthy(po ~= nil)
		T.eq(m.phase, "Overtime", "the bots of squad 1 are still in")
		T.eq(#m:extractOvertime(3), 0, "squad 3 is not in Overtime")
		local res = m:finish("final")
		T.eq(#res, 2, "the hard stop extracts the rest")
		T.eq(m.phase, "Results")
	end)

	T.it("overtimeWaveCleared outside Overtime is a programming error", function()
		local m = toFinal(true)
		T.truthy(not pcall(m.overtimeWaveCleared, m))
	end)
end)

return T.finish()
