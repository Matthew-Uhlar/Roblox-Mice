--!strict
-- Cross-module integration (Testing team): whole runs through RunState + World +
-- BotBrain + Leveling + UpgradeOffers via tests/sim/Headless.luau.
local T = require("../lib/Test")
local H = require("../sim/Headless")
local Rng = require("../../src/shared/Util/Rng")
local RunState = require("../../src/shared/Run/RunState")
local Bosses = require("../../src/shared/Config/Bosses")
local Classes = require("../../src/shared/Config/Classes")
local BotRoster = require("../../src/shared/Bots/BotRoster")

local SEEDS = { 11, 22, 33, 44, 55, 66 }

-- Roster bots for `humanClasses` (BotRoster.fill, as LobbyService does).
local function party(humanClasses: { string }, seed: number): { any }
	local out = {}
	for _, c in humanClasses do
		table.insert(out, { classId = c, isBot = false })
	end
	for _, b in BotRoster.fill(#humanClasses, 4, 3, humanClasses, Rng.new(seed)) do
		table.insert(out, { classId = b.classId, isBot = true })
	end
	return out
end

-- onTick hook: keeps every participant at full HP (in the listed phases, or always).
local function godMode(phases: { [string]: boolean }?)
	return function(sim: any, phase: string)
		if phases and not phases[phase] then
			return
		end
		for _, p in sim.world.playerList do
			if not p.downed and not p.dead then
				p.hp = p.maxHp
			end
		end
	end
end

-- onTick hook for payout tests: god mode, and the boss is finished off 20 s after
-- it spawns, so banking paths never depend on boss balance.
local function quickWin()
	local god = godMode()
	return function(sim: any, phase: string)
		god(sim, phase)
		local boss = sim.world.boss
		if phase == "Boss" and boss and boss.alive and sim.now - sim.bossSpawnAt >= 20 then
			sim.world:damageEnemy(boss, boss.hp + 1, nil)
		end
	end
end

-- onTick hook: downs the whole party once the given stage's waves reach `at` seconds.
local function wipeOnStage(stageIndex: number, at: number?, keep: ((any, string) -> ())?)
	local start: number? = nil
	return function(sim: any, phase: string)
		if sim.stageIndex == stageIndex and phase == "Waves" then
			start = start or sim.now
			if sim.now - (start :: number) >= (at or 2) then
				for _, p in sim.world.playerList do
					sim.world:damagePlayer(p, 1e9, "test")
					p.iframeUntil = 0
					p.invulnUntil = 0
				end
			end
		elseif keep then
			keep(sim, phase)
		end
	end
end

local function fmtOutcomes(counts: { [string]: number }): string
	local keys = {}
	for k in counts do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts = {}
	for _, k in keys do
		table.insert(parts, k .. "=" .. counts[k])
	end
	return table.concat(parts, " ")
end

T.describe("Integration › full Cycle 1", function()
	T.it("(a) 3 bots play Cycle 1: every run reaches CycleVote or Wipe", function()
		local counts: { [string]: number } = {}
		print("\n  [a] 3 bots, Cycle 1 (Low routes unless voted otherwise)")
		for _, seed in SEEDS do
			local sim = H.new({ seed = seed, party = party({}, seed) })
			local r = sim:playRun()
			counts[r.outcome] = (counts[r.outcome] or 0) + 1
			print(
				string.format(
					"  seed %d -> %s after %d stage(s), %.0f sim-s",
					seed,
					r.outcome,
					#r.stages,
					r.simSeconds
				)
			)
			for _, s in r.stages do
				print(H.formatStage(s))
			end
			T.truthy(
				r.outcome == "CycleVote" or r.outcome == "Wipe",
				"seed " .. seed .. " ended " .. r.outcome
			)
			if r.outcome == "CycleVote" then
				T.eq(#r.stages, 4)
				T.eq(sim.run.phase, "CycleVote")
				T.truthy(r.pending > 0, "pending cheese after 4 bosses")
			else
				T.eq(r.final.outcome, "Wipe")
			end
		end
		print("  [a] outcome distribution: " .. fmtOutcomes(counts))
	end)

	T.it("(b) solo human + 2 roster bots: every run reaches CycleVote or Wipe", function()
		local counts: { [string]: number } = {}
		print("\n  [b] solo human (BotBrain stand-in) + 2 bots")
		for i, seed in SEEDS do
			local human = Classes.ORDER[(i - 1) % 3 + 1]
			local p = party({ human }, seed)
			T.eq(#p, 3, "solo player gets 2 bots")
			local sim = H.new({ seed = seed, party = p })
			T.near(sim.playerCount, 2.2, 1e-9, "difficulty count = 1 + 2 x 0.6 (fractional)")
			local r = sim:playRun()
			counts[r.outcome] = (counts[r.outcome] or 0) + 1
			local classes = {}
			for _, x in p do
				table.insert(classes, x.classId .. (if x.isBot then "(bot)" else "(human)"))
			end
			print(string.format("  seed %d [%s] -> %s", seed, table.concat(classes, ","), r.outcome))
			for _, s in r.stages do
				print(H.formatStage(s))
				T.truthy(s.secondWinds <= 1, "at most one Second Wind per stage")
			end
			T.truthy(
				r.outcome == "CycleVote" or r.outcome == "Wipe",
				"seed " .. seed .. " ended " .. r.outcome
			)
		end
		print("  [b] outcome distribution: " .. fmtOutcomes(counts))
	end)
end)

T.describe("Integration › participant ids (Util/Ids)", function()
	T.it("a Studio test player (UserId -1) plays as a human next to -1001/-1002 bots", function()
		local seen = { weight = nil :: number?, humanFlag = nil :: any, botFlag = nil :: any }
		local sim = H.new({
			seed = 77,
			party = party({ "ele_fonte" }, 77),
			humanIds = { -1 },
			maxStages = 1,
			onTick = function(s: any, phase: string)
				if phase == "Waves" and seen.weight == nil then
					local players = s.world:getPlayers()
					seen.humanFlag = players[-1] and players[-1].isBot
					seen.botFlag = players[-1001] and players[-1001].isBot
					s.world:step(1 / 30, s.now) -- refresh the standing list
					seen.weight = s.world:partyWeight()
				end
			end,
		})
		T.eq(sim.members[1].id, -1)
		T.eq(sim.members[2].id, -1001)
		T.eq(sim.members[3].id, -1002)
		local r = sim:playRun()
		T.eq(seen.humanFlag, false, "id -1 is a human")
		T.eq(seen.botFlag, true, "id -1001 is a bot")
		T.near(seen.weight :: number, 1 + 2 * H.BOT_WEIGHT, 1e-9, "party weight 1 human + 2 bots")
		T.truthy(r.outcome == "MaxStages" or r.outcome == "Wipe")
	end)
end)

T.describe("Integration › banking payouts (GDD §3.4)", function()
	local function forcedBank(plan: { string })
		return function(_kind: string, options: { string }, sim: any): string?
			local choice = plan[sim.stageIndex]
			assert(choice and table.find(options, choice), "bad plan for stage " .. sim.stageIndex)
			return choice
		end
	end
	local function lowRoute(_cards: { any }): number?
		return 1 -- Low card: reward x1.0
	end
	local base = { waveSeconds = 45, routePolicy = lowRoute }
	local function opts(seed: number, extra: { [string]: any }): any
		local o: any = { seed = seed, party = party({}, seed) }
		for k, v in base do
			o[k] = v
		end
		for k, v in extra do
			o[k] = v
		end
		return o
	end
	local function chest(stage: number, don: boolean, cycle: number?): number
		return RunState.stageCheese(cycle or 1, stage, 1.0, don)
	end

	T.it("Go Home after 4 Continues banks 100% of pending", function()
		local r = H.new(opts(101, {
			onTick = quickWin(),
			bankPolicy = forcedBank({ "Continue", "Continue", "Continue", "GoHome" }),
		})):playRun()
		T.eq(r.outcome, "Win")
		local expected = chest(1, false) + chest(2, false) + chest(3, false) + chest(4, false)
		T.eq(r.final.cheesePerPlayer, expected)
		T.eq(r.final.outcome, "Win")
		T.eq(r.pending, 0)
	end)

	T.it("Double or Nothing win: next chest x2 and the pot x1.5", function()
		local sim = H.new(opts(102, {
			onTick = quickWin(),
			bankPolicy = forcedBank({ "DoubleOrNothing", "Continue", "Continue", "GoHome" }),
		}))
		local r = sim:playRun()
		T.eq(r.outcome, "Win")
		local s = r.stages
		T.eq(s[1].pendingAfter, chest(1, false))
		T.eq(s[2].reward.cheesePerPlayer, 2 * chest(2, false), "DoN stage chest doubled")
		T.eq(
			s[2].pendingAfter,
			math.floor(chest(1, false) * 1.5) + chest(2, true),
			"pot x1.5 + doubled chest"
		)
		T.eq(s[3].reward.cheesePerPlayer, chest(3, false), "DoN ends after its stage")
		T.eq(r.final.cheesePerPlayer, s[2].pendingAfter + chest(3, false) + chest(4, false))
	end)

	T.it("wipe on a normal stage keeps banked + 50% of pending", function()
		local r = H.new(opts(103, {
			onTick = wipeOnStage(3, 2, quickWin()),
			bankPolicy = forcedBank({ "Continue", "Continue" }),
		})):playRun()
		T.eq(r.outcome, "Wipe")
		T.eq(#r.stages, 3)
		T.eq(r.stages[3].outcome, "wipe")
		local pending = chest(1, false) + chest(2, false)
		T.eq(r.final.cheesePerPlayer, math.floor(pending * 0.5))
		T.eq(r.final.outcome, "Wipe")
	end)

	T.it("wipe on a Double-or-Nothing stage loses the whole pot", function()
		local r = H.new(opts(104, {
			onTick = wipeOnStage(3, 2, quickWin()),
			bankPolicy = forcedBank({ "Continue", "DoubleOrNothing" }),
		})):playRun()
		T.eq(r.outcome, "Wipe")
		T.eq(r.final.cheesePerPlayer, 0)
		T.eq(r.pending, 0)
	end)

	T.it("Next Cycle banks 50%; a later DoN wipe keeps only what was banked", function()
		local r = H.new(opts(105, {
			onTick = wipeOnStage(6, 2, quickWin()),
			bankPolicy = forcedBank({ "Continue", "Continue", "Continue", "NextCycle", "DoubleOrNothing" }),
		})):playRun()
		T.eq(r.outcome, "Wipe")
		T.eq(#r.stages, 6)
		local pot = chest(1, false) + chest(2, false) + chest(3, false) + chest(4, false)
		local banked = math.floor(pot * 0.5)
		T.eq(r.stages[4].bankedAfter, banked, "Next Cycle banks half")
		T.eq(r.stages[4].pendingAfter, pot - banked, "the rest stays pending")
		T.eq(r.stages[5].cycle, 2)
		T.eq(r.stages[5].reward.cheesePerPlayer, chest(1, false, 2), "cycle 2 chest +50%")
		T.eq(r.final.cheesePerPlayer, banked, "DoN wipe: pending lost, banked kept")
	end)

	T.it("Next Cycle then a normal wipe keeps banked + 50% of the carried pot", function()
		local r = H.new(opts(106, {
			onTick = wipeOnStage(5, 2, quickWin()),
			bankPolicy = forcedBank({ "Continue", "Continue", "Continue", "NextCycle" }),
		})):playRun()
		T.eq(r.outcome, "Wipe")
		local pot = chest(1, false) + chest(2, false) + chest(3, false) + chest(4, false)
		local banked = math.floor(pot * 0.5)
		T.eq(r.final.cheesePerPlayer, banked + math.floor((pot - banked) * 0.5))
	end)
end)

T.describe("Integration › determinism", function()
	T.it("(d) the same seed gives an identical run (3 bots)", function()
		for _, seed in { 7, 8 } do
			local a = H.digest(H.new({ seed = seed, party = party({}, seed) }):playRun())
			local b = H.digest(H.new({ seed = seed, party = party({}, seed) }):playRun())
			T.eq(a, b, "seed " .. seed)
		end
	end)
	T.it("(d) the same seed gives an identical run (solo human + 2 bots, forced DoN)", function()
		local function make()
			return H.new({
				seed = 9,
				party = party({ "le_fante" }, 9),
				bankPolicy = function(kind: string)
					return if kind == "bank" then "DoubleOrNothing" else "GoHome"
				end,
			})
		end
		T.eq(H.digest(make():playRun()), H.digest(make():playRun()))
	end)
	T.it("different seeds diverge", function()
		local a = H.digest(H.new({ seed = 1, party = party({}, 1), maxStages = 1 }):playRun())
		local b = H.digest(H.new({ seed = 2, party = party({}, 2), maxStages = 1 }):playRun())
		T.truthy(a ~= b)
	end)
end)

-- (e) Balance smoke test. Waves are played for real (levels, upgrades), but the
-- party is kept alive during waves so every seed reaches the boss; the boss fight
-- itself is unassisted.
local BOSS_SEEDS = { 1, 2, 3, 4 }
local MIN_KILL = 10

T.describe("Integration › balance: 13 bosses at cycle 1", function()
	local rows = {}
	for _, bossId in Bosses.ORDER do
		T.it("(e) 3 bots can kill " .. bossId .. " within the time limit (and not in < 10 s)", function()
			local kills, wipes, timeouts, times = 0, 0, 0, {}
			for _, seed in BOSS_SEEDS do
				local r = H.new({
					seed = seed * 1000 + #bossId,
					party = party({}, seed),
					bossOverride = bossId,
					maxStages = 1,
					onTick = godMode({ Waves = true }),
				}):playRun()
				local s = r.stages[1]
				if s.outcome == "clear" then
					kills += 1
					table.insert(times, s.bossTime or 0)
				elseif s.outcome == "wipe" then
					wipes += 1
				else
					timeouts += 1
				end
			end
			table.sort(times)
			local sum = 0
			for _, t in times do
				sum += t
			end
			local row = {
				bossId = bossId,
				kills = kills,
				wipes = wipes,
				timeouts = timeouts,
				avg = if #times > 0 then sum / #times else nil,
				min = times[1],
				max = times[#times],
			}
			table.insert(rows, row)
			T.eq(timeouts, 0, bossId .. ": boss outlived the 6-minute limit")
			T.truthy(kills > 0, bossId .. ": never killed in " .. #BOSS_SEEDS .. " tries (unkillable)")
			T.truthy(
				times[1] >= MIN_KILL,
				string.format("%s: died in %.1f s (< %d s)", bossId, times[1] or -1, MIN_KILL)
			)
		end)
	end
	T.it("prints the boss balance table", function()
		print("\n  [e] boss              kills wipes t/o   avg s   min s   max s")
		for _, r in rows do
			print(
				string.format(
					"  %-18s %5d %5d %3d  %6s  %6s  %6s",
					r.bossId,
					r.kills,
					r.wipes,
					r.timeouts,
					if r.avg then string.format("%.1f", r.avg) else "-",
					if r.min then string.format("%.1f", r.min) else "-",
					if r.max then string.format("%.1f", r.max) else "-"
				)
			)
		end
		T.eq(#rows, 13)
	end)
end)

-- (f) Every class completes stage 1 as the human with two roster bots.
local CLASS_SEEDS = { 5, 6, 7, 8 }
T.describe("Integration › every class clears stage 1", function()
	local rows = {}
	for _, classId in Classes.ORDER do
		T.it("(f) " .. classId .. " + 2 bots can clear stage 1", function()
			local clears, times, levels = 0, {}, 0
			for _, seed in CLASS_SEEDS do
				local r = H.new({ seed = seed, party = party({ classId }, seed), maxStages = 1 }):playRun()
				local s = r.stages[1]
				T.truthy(s.outcome ~= "timeout", classId .. ": boss timeout")
				if s.outcome == "clear" then
					clears += 1
					table.insert(times, s.waveTime + (s.bossTime or 0))
				end
				levels += r.levels[H.HUMAN_ID0 + 1] - 1
			end
			local sum = 0
			for _, t in times do
				sum += t
			end
			table.insert(rows, {
				classId = classId,
				clears = clears,
				avg = if #times > 0 then sum / #times else nil,
				levels = levels / #CLASS_SEEDS,
			})
			T.truthy(clears > 0, classId .. ": never cleared stage 1 in " .. #CLASS_SEEDS .. " seeds")
		end)
	end
	T.it("prints the class table", function()
		print("\n  [f] class        clears  avg clear s  human lvl+")
		for _, r in rows do
			print(
				string.format(
					"  %-12s %3d/%d  %10s  %8.1f",
					r.classId,
					r.clears,
					#CLASS_SEEDS,
					if r.avg then string.format("%.1f", r.avg) else "-",
					r.levels
				)
			)
		end
		T.eq(#rows, #Classes.ORDER)
	end)
end)

return T.finish()
