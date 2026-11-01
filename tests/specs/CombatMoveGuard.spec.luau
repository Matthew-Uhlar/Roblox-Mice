--!strict
-- Combat/MoveGuard: server-side movement validation (QC2 M1).
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local MoveGuard = require("../../src/shared/Combat/MoveGuard")

local DT = 1 / 30
local SPEED = 16

-- Walks `id` along +x at `speed` for `seconds`, sampling every DT (with optional
-- timing jitter). Returns the number of violations and the last accepted x.
local function walk(g: any, id: number, speed: number, seconds: number, opts: { [string]: any }?): (number, number)
	local o = opts or {}
	local rng = Rng.new(o.seed or 1)
	local t = o.t0 or 0
	local x = o.x0 or 0
	local bad = 0
	local lastX = x
	local steps = math.floor(seconds / DT + 0.5)
	for _ = 1, steps do
		local dt = DT
		if o.jitter then
			dt = DT * rng:range(0.3, 1.7)
		end
		t += dt
		x += speed * dt
		-- bursty replication: sometimes the sample is a frame stale
		local sampleX = if o.stale and rng:chance(0.3) then x - speed * DT else x
		local ax, _, verdict = g:check(id, sampleX, 0, t, o.limit or SPEED, o.factor or 1)
		if verdict == "violation" then
			bad += 1
		end
		lastX = ax
	end
	return bad, lastX
end

T.describe("MoveGuard.stateFactor", function()
	T.it("dead 0, downed 0.3, otherwise 1", function()
		T.eq(MoveGuard.stateFactor({ dead = true, downed = false }), 0)
		T.eq(MoveGuard.stateFactor({ dead = false, downed = true }), 0.3)
		T.eq(MoveGuard.stateFactor({ dead = false, downed = false, slowed = true }), 1)
		T.eq(MoveGuard.stateFactor(nil), 1)
	end)
end)

T.describe("MoveGuard.check", function()
	T.it("an honest player at full speed never violates (with timing jitter and stale samples)", function()
		local g = MoveGuard.new()
		g:place(1, 0, 0, 0)
		local bad = walk(g, 1, SPEED, 30, { jitter = true, stale = true })
		T.eq(bad, 0)
		T.eq(g:violations(1), 0)
	end)
	T.it("a 2x speed hack is caught and clamped to the legal distance", function()
		local g = MoveGuard.new()
		g:place(1, 0, 0, 0)
		local bad, lastX = walk(g, 1, SPEED * 2, 5)
		T.truthy(bad >= 3, "violations " .. bad)
		-- over 5 s the accepted position never gets far beyond speed x 1.3 x t + slack + carry
		local maxLegal = SPEED * MoveGuard.TOLERANCE * 5 + MoveGuard.SLACK + SPEED * MoveGuard.TOLERANCE * MoveGuard.CARRY_SECONDS
		T.truthy(lastX <= maxLegal, string.format("accepted x %.1f > %.1f", lastX, maxLegal))
	end)
	T.it("the slack is a one-off allowance, not a per-check bonus", function()
		local g = MoveGuard.new()
		g:place(1, 0, 0, 0)
		-- move exactly budget + 0.9 x slack every check: the debt must catch up
		local t, x = 0, 0
		local bad = 0
		for _ = 1, 60 do
			t += DT
			x += SPEED * MoveGuard.TOLERANCE * DT + MoveGuard.SLACK * 0.9
			local _, _, v = g:check(1, x, 0, t, SPEED, 1)
			if v == "violation" then
				bad += 1
				x = (g:position(1)) :: number
			end
		end
		T.truthy(bad >= 1, "slack abuse never flagged")
	end)
	T.it("a teleport across the arena is a violation and the point stays near the anchor", function()
		local g = MoveGuard.new()
		g:place(1, 0, 0, 0)
		local x, z, v = g:check(1, 200, 0, DT, SPEED, 1)
		T.eq(v, "violation")
		T.truthy(x < 3, "clamped x " .. x)
		T.eq(z, 0)
		T.eq(g:violations(1), 1)
	end)
	T.it("after a snap, stale samples are ignored (not re-counted) for SNAP_GRACE", function()
		local g = MoveGuard.new()
		g:place(1, 0, 0, 0)
		g:check(1, 200, 0, DT, SPEED, 1) -- violation
		local _, _, v = g:check(1, 200, 0, 2 * DT, SPEED, 1)
		T.eq(v, "ignored")
		T.eq(g:violations(1), 1)
		-- still out of reach after the grace: counted again
		local _, _, v2 = g:check(1, 200, 0, MoveGuard.SNAP_GRACE + 0.2, SPEED, 1)
		T.eq(v2, "violation")
		T.eq(g:violations(1), 2)
	end)
	T.it("downed players may only crawl (x0.3)", function()
		local g = MoveGuard.new()
		g:place(1, 0, 0, 0)
		-- downed from the start (no previous higher limit to lag behind)
		local okBad = walk(g, 1, SPEED * 0.3, 5, { factor = 0.3 })
		T.eq(okBad, 0)
		local g2 = MoveGuard.new()
		g2:place(1, 0, 0, 0)
		local bad = walk(g2, 1, SPEED, 5, { factor = 0.3 })
		T.truthy(bad >= 3, "full speed while downed flagged " .. bad)
	end)
	T.it("dead players may not move beyond the slack", function()
		local g = MoveGuard.new()
		g:place(1, 0, 0, 0)
		local bad = walk(g, 1, SPEED, 3, { factor = 0 })
		T.truthy(bad >= 1)
		local g2 = MoveGuard.new()
		g2:place(1, 0, 0, 0)
		local _, _, v = g2:check(1, 1, 0, 1, SPEED, 0)
		T.eq(v, "ok", "1 stud of drift is inside the slack")
	end)
	T.it("a speed drop (going down) keeps the old limit for LAG_GRACE (WalkSpeed replication)", function()
		local g = MoveGuard.new()
		g:place(1, 0, 0, 0)
		local bad1 = walk(g, 1, SPEED, 2)
		T.eq(bad1, 0)
		-- downed now, but the client keeps running at full speed for 0.4 s (latency)
		local bad2 = walk(g, 1, SPEED, 0.4, { t0 = 2, x0 = SPEED * 2, factor = 0.3 })
		T.eq(bad2, 0, "no violation inside the lag grace")
		-- ...and must crawl after it
		local bad3 = walk(g, 1, SPEED, 2, { t0 = 2.4, x0 = SPEED * 2.4, factor = 0.3 })
		T.truthy(bad3 >= 1, "full speed long after going down is flagged")
	end)
	T.it("a server-issued dash: place() with a grace accepts the jump and ignores stale samples", function()
		local g = MoveGuard.new()
		g:place(1, 0, 0, 0)
		walk(g, 1, SPEED, 1)
		-- the world teleported the player 30 studs ahead (dash)
		local t = 1
		g:place(1, SPEED + 30, 0, t, MoveGuard.TELEPORT_GRACE)
		-- a stale pre-dash sample arrives first
		local x, _, v = g:check(1, SPEED, 0, t + DT, SPEED, 1)
		T.eq(v, "ignored")
		T.eq(x, SPEED + 30, "server position kept")
		-- then the real one
		local x2, _, v2 = g:check(1, SPEED + 30.3, 0, t + 2 * DT, SPEED, 1)
		T.eq(v2, "ok")
		T.near(x2, SPEED + 30.3)
		T.eq(g:violations(1), 0)
	end)
	T.it("without a server teleport the same 30-stud jump is a violation", function()
		local g = MoveGuard.new()
		g:place(1, 0, 0, 0)
		walk(g, 1, SPEED, 1)
		local _, _, v = g:check(1, SPEED + 30, 0, 1 + DT, SPEED, 1)
		T.eq(v, "violation")
	end)
	T.it("carry absorbs a replication burst but is capped", function()
		local g = MoveGuard.new()
		g:place(1, 0, 0, 0)
		-- no sample movement for 0.5 s, then the whole 0.5 s of walking at once
		local t = 0
		for _ = 1, 15 do
			t += DT
			g:check(1, 0, 0, t, SPEED, 1)
		end
		local _, _, v = g:check(1, SPEED * 0.5, 0, t + DT, SPEED, 1)
		T.eq(v, "ok")
		-- standing still for 10 s does not bank a 10-second teleport
		local g2 = MoveGuard.new()
		g2:place(1, 0, 0, 0)
		local t2 = 0
		for _ = 1, 300 do
			t2 += DT
			g2:check(1, 0, 0, t2, SPEED, 1)
		end
		local _, _, v2 = g2:check(1, SPEED * 3, 0, t2 + DT, SPEED, 1)
		T.eq(v2, "violation")
	end)
	T.it("ignores non-finite samples and survives a non-finite clock", function()
		local g = MoveGuard.new()
		g:place(1, 5, 5, 0)
		local x, z, v = g:check(1, 0 / 0, 1, DT, SPEED, 1)
		T.eq(v, "ignored")
		T.eq(x, 5)
		T.eq(z, 5)
		local _, _, v2 = g:check(1, 5.1, 5, math.huge, 0 / 0, 0 / 0)
		T.eq(v2, "ok")
	end)
	T.it("an unknown id is accepted as its own anchor; remove() forgets it", function()
		local g = MoveGuard.new()
		local x, _, v = g:check(7, 40, 2, 0, SPEED, 1)
		T.eq(v, "ok")
		T.eq(x, 40)
		g:remove(7)
		T.eq(g:violations(7), 0)
		T.eq((g:position(7)), nil)
	end)
	T.it("commit() moves the anchor to where the world put the player", function()
		local g = MoveGuard.new()
		g:place(1, 0, 0, 0)
		g:commit(1, 3, 4)
		local x, z = g:position(1)
		T.eq(x, 3)
		T.eq(z, 4)
	end)
end)

return T.finish()
