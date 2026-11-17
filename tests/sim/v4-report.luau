--!strict
-- v4 match-flow report (team M2): plays N seeds of a solo human + 11 bots with
-- the Headless sim and prints squads alive per stage, the human's idle time,
-- Herd Call / Rival Herd use and the payout distribution.
--   lune run tests/sim/v4-report.luau [seeds=24] [classId]
local H = require("./Headless")
local Classes = require("../../src/shared/Config/Classes")

local process = require("@lune/process")
local args = process.args
local N = tonumber(args[1]) or 24
local fixedClass = args[2]

local function pct(list: { number }, q: number): number
	if #list == 0 then
		return 0
	end
	table.sort(list)
	return list[math.clamp(math.ceil(#list * q), 1, #list)]
end

local squadsAt: { [number]: { number } } = { {}, {}, {}, {} }
local idle, longest, payouts, wins, wipes = {}, {}, {}, {}, {}
local outcomes: { [string]: number } = {}
local rivals, redeploys, started, snatches, donPaid, donLost, storm = 0, 0, 0, 0, 0, 0, 0
local stagesHist = { 0, 0, 0, 0 }
for i = 1, N do
	local seed = 9000 + i * 17
	local classId = fixedClass or Classes.ORDER[(i - 1) % #Classes.ORDER + 1]
	local sim = H.new({ seed = seed, humans = { { classId = classId } } })
	local r = sim:playRun()
	local v = r.v4
	for st, n in v.squadsAtStart do
		table.insert(squadsAt[st], n)
	end
	stagesHist[#r.stages] += 1
	table.insert(idle, v.idleTicks / math.max(1, v.waveTicks))
	table.insert(longest, v.longestIdle / 10)
	local cheese = r.payout and r.payout.cheese or 0
	table.insert(payouts, cheese)
	outcomes[r.outcome] = (outcomes[r.outcome] or 0) + 1
	if r.outcome == "Win" then
		table.insert(wins, cheese)
	elseif r.outcome == "Wipe" then
		table.insert(wipes, cheese)
	end
	rivals += v.rivals
	redeploys += v.redeploys
	started += v.redeploysStarted
	snatches += v.snatches
	donPaid += v.donPaid
	donLost += v.donLost
	storm += v.stormDamage
	print(
		string.format(
			"seed %d %-10s %-5s %-9s stages %d cheese %5d  idle %3.0f%%  squads@start %s  rival %d redeploy %d/%d",
			seed,
			classId,
			r.outcome,
			tostring(r.endReason),
			#r.stages,
			cheese,
			100 * v.idleTicks / math.max(1, v.waveTicks),
			table.concat(v.squadsAtStart, ","),
			v.rivals,
			v.redeploys,
			v.redeploysStarted
		)
	)
end
local function avg(list: { number }): number
	local s = 0
	for _, x in list do
		s += x
	end
	return if #list > 0 then s / #list else 0
end
print(string.format("\n== v4 report: %d matches (solo human + 11 bots, default timings)", N))
for st = 1, 4 do
	print(
		string.format(
			"  squads in the run at stage %d start: avg %.2f over %d matches",
			st,
			avg(squadsAt[st]),
			#squadsAt[st]
		)
	)
end
print(string.format("  matches by stages played (1/2/3/4): %s", table.concat(stagesHist, "/")))
local oc = {}
for k, n in outcomes do
	table.insert(oc, k .. " " .. n)
end
table.sort(oc)
print("  human outcomes: " .. table.concat(oc, ", "))
print(
	string.format(
		"  human idle (no mouse within 30, no enemy hero within 45) %.1f%% of wave time (p75 %.1f%%); longest idle streak median %.0f s, max %.0f s",
		100 * avg(idle),
		100 * pct(table.clone(idle), 0.75),
		pct(table.clone(longest), 0.5),
		pct(table.clone(longest), 1)
	)
)
print(
	string.format(
		"  payout: median %d (p25 %d, p75 %d); wins median %d (n=%d); wipes median %d (n=%d) = %.0f%% of the win median; zero payouts %d",
		pct(table.clone(payouts), 0.5),
		pct(table.clone(payouts), 0.25),
		pct(table.clone(payouts), 0.75),
		pct(table.clone(wins), 0.5),
		#wins,
		pct(table.clone(wipes), 0.5),
		#wipes,
		100 * pct(table.clone(wipes), 0.5) / math.max(1, pct(table.clone(wins), 0.5)),
		(function()
			local z = 0
			for _, x in payouts do
				z += if x == 0 then 1 else 0
			end
			return z
		end)()
	)
)
print(
	string.format(
		"  Rival Herds %d; Herd Call redeploys %d of %d timers; Snatches %d; DoN paid %d / lost %d; human storm damage %.0f HP/match",
		rivals,
		redeploys,
		started,
		snatches,
		donPaid,
		donLost,
		storm / N
	)
)
