--!strict
-- Run/LobbyRules: start countdown, party pick and AFK rules (QC2 M2, QC1 #15).
local T = require("../lib/Test")
local LobbyRules = require("../../src/shared/Run/LobbyRules")

local function entry(name: string, joinedAt: number, ready: boolean?): any
	return { name = name, ready = ready == true, sitOut = false, idleRuns = 0, joinedAt = joinedAt }
end

local function names(list: { any }): string
	local out = {}
	for _, e in list do
		table.insert(out, e.name)
	end
	return table.concat(out, ",")
end

T.describe("LobbyRules.countdown", function()
	T.it("iteration 6: nobody ready -> none; first Ready -> 60 s; everyone ready -> start now", function()
		local a, b, c = entry("a", 1), entry("b", 2), entry("c", 3)
		local d = LobbyRules.countdown({ a, b, c }, nil, nil)
		T.eq(d.action, "none", "no auto-start")
		LobbyRules.setReady(a, true)
		d = LobbyRules.countdown({ a, b, c }, nil, nil)
		T.eq(d.action, "arm")
		T.eq(d.seconds, 60)
		T.eq(d.kind, "ready")
		LobbyRules.setReady(b, true)
		d = LobbyRules.countdown({ a, b, c }, 51, "ready")
		T.eq(d.action, "keep", "a second Ready never restarts the 60 s")
		LobbyRules.setReady(c, true)
		d = LobbyRules.countdown({ a, b, c }, 40, "ready")
		T.eq(d.action, "arm")
		T.eq(d.kind, "all")
		T.truthy(d.seconds <= 1, "all ready: just the transition")
	end)
	T.it("iteration 6: un-readying everyone cancels; the countdown never restarts longer", function()
		local a, b = entry("a", 1), entry("b", 2)
		LobbyRules.setReady(a, true)
		T.eq(LobbyRules.countdown({ a, b }, 30, "ready").action, "keep")
		LobbyRules.setReady(a, false)
		T.eq(LobbyRules.countdown({ a, b }, 30, "ready").action, "cancel")
		LobbyRules.setReady(b, true)
		local d = LobbyRules.countdown({ a, b }, nil, nil)
		-- a sits out (un-readied), so b alone is everyone willing
		T.eq(d.kind, "all")
	end)
	T.it("once armed it only gets shorter: Ready/Unready spam never restarts it", function()
		local a, b, c = entry("a", 1), entry("b", 2), entry("c", 3)
		LobbyRules.setReady(a, true)
		LobbyRules.setReady(b, true)
		local remaining = LobbyRules.SOME_READY_SECONDS -- some ready (c idle) -> 60 s
		for i = 1, 40 do
			-- griefer b toggles every half second
			LobbyRules.setReady(b, i % 2 == 0)
			remaining -= 0.5
			local d = LobbyRules.countdown({ a, b, c }, remaining, "ready")
			if d.action == "arm" then
				T.truthy((d.seconds :: number) < remaining, "re-armed longer at step " .. i)
				remaining = d.seconds :: number
			else
				T.eq(d.action, "keep", "step " .. i)
			end
			if remaining <= 0 then
				break
			end
		end
		T.truthy(remaining <= 0, "the countdown reached zero despite the spam")
	end)
	T.it("a running ready countdown is kept (not reset to 60 s) when players join", function()
		local a = entry("a", 1)
		LobbyRules.setReady(a, true)
		local d = LobbyRules.countdown({ a, entry("late", 9) }, 12, "ready")
		T.eq(d.action, "keep")
		T.eq(d.kind, "ready")
	end)
	T.it("a lone player (Studio solo) starts at once by pressing Ready (all ready)", function()
		local a = entry("a", 1)
		T.eq(LobbyRules.countdown({ a }, nil, nil).action, "none", "idle: nothing counts down")
		LobbyRules.setReady(a, true)
		local d = LobbyRules.countdown({ a }, nil, nil)
		T.eq(d.action, "arm")
		T.eq(d.seconds, LobbyRules.ALL_READY_SECONDS)
	end)
	T.it("a stale countdown with nobody ready any more is cancelled (no auto-start)", function()
		local a, b = entry("a", 1), entry("b", 2)
		T.eq(LobbyRules.countdown({ a, b }, 12, "ready").action, "cancel")
		LobbyRules.setReady(a, true)
		LobbyRules.setReady(a, false) -- a sits out; b idle and willing but not ready
		T.eq(LobbyRules.countdown({ a, b }, 12, "ready").action, "cancel")
	end)
	T.it("cancels only when nobody is left to start", function()
		local a = entry("a", 1)
		LobbyRules.setReady(a, true)
		LobbyRules.setReady(a, false) -- sits out
		T.eq(LobbyRules.countdown({ a }, 4, "ready").action, "cancel")
		T.eq(LobbyRules.countdown({}, nil, nil).action, "none")
	end)
	T.it("sat-out and AFK-capped players do not block the 5 s all-ready countdown", function()
		local a, b, c = entry("a", 1), entry("b", 2), entry("c", 3)
		LobbyRules.setReady(a, true)
		LobbyRules.setReady(b, true)
		LobbyRules.setReady(b, false) -- b sits out
		c.idleRuns = LobbyRules.AFK_AUTO_RUNS -- c is AFK
		local d = LobbyRules.countdown({ a, b, c }, nil, nil)
		T.eq(d.seconds, LobbyRules.ALL_READY_SECONDS)
	end)
end)

T.describe("LobbyRules.party", function()
	T.it("ready first, then auto-eligible idle players by join order; un-readied players sit out", function()
		local a, b, c, d = entry("a", 1), entry("b", 2), entry("c", 3), entry("d", 4)
		LobbyRules.setReady(c, true)
		LobbyRules.setReady(b, true)
		LobbyRules.setReady(b, false) -- b drops out of this start
		T.eq(names(LobbyRules.party({ a, b, c, d })), "c,a,d")
	end)
	T.it("caps at MAX_PARTY", function()
		local list = {}
		for i = 1, LobbyRules.MAX_PARTY + 2 do
			table.insert(list, entry("p" .. i, i))
		end
		T.eq(LobbyRules.MAX_PARTY, 12, "v2: 12 seats")
		T.eq(#LobbyRules.party(list), LobbyRules.MAX_PARTY)
		T.eq(#LobbyRules.party(list, 4), 4, "an explicit cap still applies")
	end)
	T.it("pressing Ready again rejoins", function()
		local b = entry("b", 2)
		LobbyRules.setReady(b, true)
		LobbyRules.setReady(b, false)
		T.eq(b.sitOut, true)
		LobbyRules.setReady(b, true)
		T.eq(b.sitOut, false)
		T.eq(names(LobbyRules.party({ b })), "b")
	end)
	T.it("unready without ever being ready is not a sit-out", function()
		local b = entry("b", 2)
		LobbyRules.setReady(b, false)
		T.eq(b.sitOut, false)
	end)
end)

T.describe("LobbyRules AFK pull-in (QC1 #15)", function()
	T.it("after 2 pulled-in runs with no input the player is no longer pulled in", function()
		local a = entry("a", 1)
		a.idleRuns = LobbyRules.afterRun(a.idleRuns, true, false)
		T.eq(a.idleRuns, 1)
		T.eq(LobbyRules.autoEligible(a), true, "one idle run is fine")
		a.idleRuns = LobbyRules.afterRun(a.idleRuns, true, false)
		T.eq(a.idleRuns, 2)
		T.eq(LobbyRules.autoEligible(a), false)
		T.eq(#LobbyRules.party({ a }), 0)
		T.eq(LobbyRules.countdown({ a }, nil, nil).action, "none", "no countdown for an AFK player")
	end)
	T.it("any input resets the counter; Ready always works", function()
		local a = entry("a", 1)
		a.idleRuns = 2
		LobbyRules.noteInput(a)
		T.eq(a.idleRuns, 0)
		a.idleRuns = 2
		LobbyRules.setReady(a, true)
		T.eq(a.idleRuns, 0)
		T.eq(names(LobbyRules.party({ a })), "a")
		T.eq(LobbyRules.afterRun(1, true, true), 0, "input during the run")
		T.eq(LobbyRules.afterRun(1, false, false), 1, "a readied player is not counted")
	end)
end)

T.describe("LobbyRules v4 busy (QA-C M8)", function()
	T.it("a busy player is never pulled in, but Ready still counts", function()
		local a = entry("a", 1)
		a.busy = true
		T.eq(LobbyRules.autoEligible(a), false)
		T.eq(#LobbyRules.party({ a }), 0)
		T.eq(LobbyRules.countdown({ a }, nil, nil).action, "none", "no countdown for a busy lobby")
		LobbyRules.setReady(a, true)
		T.eq(#LobbyRules.party({ a }), 1)
		a.busy = false
		a.ready = false
		T.eq(LobbyRules.autoEligible(a), true)
	end)
end)

return T.finish()
