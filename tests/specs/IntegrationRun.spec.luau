--!strict
-- Cross-module integration (lead): whole v2 squad matches through MatchState +
-- RunState + World + BotBrain + BotRoster + Gear + Leveling + UpgradeOffers via
-- tests/sim/Headless.luau (docs/GDD-v2.md §1–3). A solo human gets 11 bots in
-- 4 squads; "Win" means the human EXTRACTED (Extract, the final stage, or Last
-- Herd Standing). Payout tests pin the MatchState cheese rules exactly.
local T = require("../lib/Test")
local H = require("../sim/Headless")
local MatchState = require("../../src/shared/Run/MatchState")
local Bosses = require("../../src/shared/Config/Bosses")
local Classes = require("../../src/shared/Config/Classes")
local Ids = require("../../src/shared/Util/Ids")

local SEEDS = { 11, 22, 33, 44, 55, 66 }
local C = MatchState.CONFIG

-- onTick hook: keeps every standing hero at full HP (in the listed phases, or always).
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

-- onTick: puts every hero in squad 1 of the World (no PvP), so a test measures
-- the boss alone. MatchState keeps the real squads.
local function noPvp(inner: ((any, string) -> ())?)
	local done: any = nil
	return function(sim: any, phase: string)
		if done ~= sim.world then
			done = sim.world
			for _, p in sim.world.playerList do
				sim.world:setSquad(p.id, 1)
			end
		end
		if inner then
			inner(sim, phase)
		end
	end
end

-- God mode, and the boss is finished off 20 s after it spawns (no killer: the
-- top damage squad wins), so payout paths never depend on balance.
local function quickWin(extra: ((any, string) -> ())?)
	local god = godMode()
	return function(sim: any, phase: string)
		if extra then
			extra(sim, phase)
		end
		god(sim, phase)
		local boss = sim.world.boss
		if phase == "Boss" and boss and boss.alive and sim.now - sim.bossSpawnAt >= 20 then
			sim.world:damageEnemy(boss, boss.hp + 1, nil)
		end
	end
end

-- onTick: downs every member of the human's squad once that stage's waves reach `at` s.
local function wipeHumanSquad(stage: number, at: number)
	local start: number? = nil
	return function(sim: any, phase: string)
		if sim.match.stage == stage and phase == "Waves" then
			start = start or sim.now
			if sim.now - (start :: number) >= at then
				local squad = sim.human.squad
				for _, p in sim.world.playerList do
					if p.squad == squad and not p.downed and not p.dead then
						p.iframeUntil = 0
						p.invulnUntil = 0
						p.protectUntil = 0
						sim.world:damagePlayer(p, 1e9, "test")
					end
				end
			end
		end
	end
end

local function fmt(counts: { [string]: number }): string
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

T.describe("Integration › seating (BotRoster.fillSquads + flatten)", function()
	T.it("a solo human gets 11 bots across 4 squads (2 of them squad-mates)", function()
		local sim = H.new({ seed = 3, humans = { { classId = "ele_fonte" } } })
		local perSquad, bots = { 0, 0, 0, 0 }, 0
		for _, m in sim.members do
			perSquad[m.squad] += 1
			if m.isBot then
				bots += 1
				T.truthy(Ids.isBot(m.id), "bot id in the bot band: " .. m.id)
				T.truthy(sim.match:member(m.id).isBot, "MatchState knows it is a bot")
			end
		end
		T.eq(#sim.members, 12)
		T.eq(bots, 11)
		for s = 1, 4 do
			T.eq(perSquad[s], 3, "squad " .. s)
		end
		local human = sim.human
		T.falsy(human.isBot)
		T.eq(#sim:humanOf(human.squad), 1)
		T.near(
			sim.match:difficulty(),
			require("../../src/shared/Run/RunState").partySize((1 + 11 * H.BOT_WEIGHT) / 4),
			1e-9
		)
	end)

	T.it("friends (one partyId) share a squad; a Studio player -1 is a human", function()
		local sim = H.new({
			seed = 4,
			humans = {
				{ classId = "elephante", partyId = 7 },
				{ classId = "filet" },
				{ classId = "jumbo", partyId = 7 },
			},
			humanIds = { -1, 1002, -2 },
		})
		local byId = sim.byId
		T.eq(byId[-1].squad, byId[-2].squad, "the party sits together")
		T.falsy(byId[-1].isBot, "-1 is a human")
		T.falsy(sim.match:member(-1).isBot)
		local bots = 0
		for _, m in sim.members do
			bots += if m.isBot then 1 else 0
		end
		T.eq(bots, 9, "9 bots fill the other seats")
	end)
end)

T.describe("Integration › whole matches (solo human + 11 bots)", function()
	T.it("(a) every match reaches Results; Win only when the human extracted", function()
		local counts: { [string]: number } = {}
		print("\n  [a] solo human (BotBrain stand-in) + 11 bots, POIs on")
		for i, seed in SEEDS do
			local human = Classes.ORDER[(i - 1) % #Classes.ORDER + 1]
			local sim = H.new({ seed = seed, humans = { { classId = human } } })
			local r = sim:playRun()
			counts[r.outcome] = (counts[r.outcome] or 0) + 1
			print(
				string.format(
					"  seed %d (%s, squad %d) -> %s [%s] after %d stage(s), %.0f sim-s, %d cheese",
					seed,
					human,
					r.humanSquad,
					r.outcome,
					tostring(r.endReason),
					#r.stages,
					r.simSeconds,
					r.payout.cheese
				)
			)
			for _, s in r.stages do
				print(H.formatStage(s))
				T.truthy(s.secondWinds <= 1, "at most one Second Wind per stage (one human)")
			end
			T.eq(sim.match.phase, "Results", "the match ended")
			T.truthy(#r.stages <= C.STAGES, "at most 4 stages")
			T.eq(r.outcome == "Win", r.payout.extracted, "Win iff extracted")
			if r.outcome == "Win" then
				T.truthy(r.payout.result == "extracted" or r.payout.result == "lastHerd", r.payout.result)
			end
			for _, po in r.payouts do
				T.truthy(po.result ~= "unfinished" or r.endReason == "noHumans", "everyone is paid out")
				T.truthy(po.cheese >= 0)
			end
		end
		print("  [a] human outcome distribution: " .. fmt(counts))
	end)
end)

T.describe("Integration › payouts (GDD-v2 §1, MatchState)", function()
	-- v4: a member's {share, banked} after the given stage result. DoN doubles the
	-- share when the squad got a champion / boss kill (potBonus), else loses it;
	-- 25% of the boss chest and of the Snatch bonus banks at once (secured).
	local function grow(acc: { number }, res: any, squad: number, don: boolean): { number }
		local share, banked = acc[1], acc[2]
		if don then
			share = if res.potBonus[squad] then share * C.DON_POT_MULT else 0
		end
		share += res.stageCheese
		for _, part in { { res.winner, res.chestCheese }, { res.snatch, res.snatchCheese } } do
			if part[1] == squad then
				local sec = math.floor(part[2] * C.SECURED_FRAC + 1e-6)
				banked += sec
				share += part[2] - sec
			end
		end
		return { share, banked }
	end
	local function paid(acc: { number }, frac: number, stage: number): number
		return math.max(acc[2] + math.floor(acc[1] * frac + 1e-6), C.STAGE_FLOOR * stage)
	end
	-- onTick: the human's squad kills a champion in the given stage's waves (DoN condition)
	local function champKill(stage: number)
		local done = false
		return function(sim: any, phase: string)
			if not done and sim.match.stage == stage and phase == "Waves" then
				done = true
				local sq = sim.human.squad
				sim.match:championKilled({ [sq] = 1 }, sq, sq, 0)
			end
		end
	end
	local function plan(list: { string })
		return function(_squad: number, sim: any): string?
			return list[sim.match.stage]
		end
	end
	local base = { waveSeconds = 30, pois = false, humanSecondWind = false }
	local function opts(seed: number, extra: { [string]: any }): any
		local o: any = { seed = seed, humans = { { classId = "elephante" } } }
		for k, v in base do
			o[k] = v
		end
		for k, v in extra do
			o[k] = v
		end
		return o
	end

	T.it("Extract at the stage-2 gate banks 100% of the share; the match goes on", function()
		local sim = H.new(opts(101, { onTick = quickWin(), extractPolicy = plan({ "Stay", "Extract" }) }))
		local r = sim:playRun()
		local h = sim.human
		local acc = { 0, 0 }
		for i = 1, 2 do
			acc = grow(acc, r.stages[i].result, h.squad, false)
		end
		T.eq(r.outcome, "Win")
		T.eq(r.payout.result, "extracted")
		T.eq(r.payout.stagesCleared, 2)
		T.eq(r.payout.cheese, paid(acc, 1, 2), "share banked x1 (+ secured)")
		T.eq(r.payout.won, false, "[M1] a stage-2 extraction is not a win")
		T.truthy(r.stages[2].extracted and table.find(r.stages[2].extracted, h.squad), "extracted at stage 2")
	end)

	T.it("[v4] Double or Nothing: x2 with a champion kill that stage, then Extract", function()
		local sim = H.new(opts(102, {
			onTick = quickWin(champKill(2)),
			extractPolicy = plan({ "DoubleOrNothing", "Extract" }),
		}))
		local r = sim:playRun()
		local h = sim.human
		local s1 = grow({ 0, 0 }, r.stages[1].result, h.squad, false)
		local s2 = grow(s1, r.stages[2].result, h.squad, true)
		T.eq(r.stages[1].choices[h.squad], "DoubleOrNothing")
		T.truthy((r.stages[2].result.potBonus[h.squad] or 0) > 0, "pot bonus paid")
		T.eq(r.payout.cheese, paid(s2, 1, 2))
		T.eq(r.payout.result, "extracted")
	end)
	T.it("[v4] Double or Nothing without a kill: the pot is lost", function()
		local sim = H.new(opts(106, {
			onTick = quickWin(function(s2: any, phase: string)
				-- nobody in the human's squad lands boss damage: the World's boss damage goes to others
				if phase == "Boss" and s2.match.stage == 2 then
					for _, p in s2.world.playerList do
						if p.squad == s2.human.squad then
							p.x, p.z = s2.world.arenaRadius * 0.9, 0
						end
					end
				end
			end),
			extractPolicy = plan({ "DoubleOrNothing", "Extract" }),
		}))
		local r = sim:playRun()
		local res = r.stages[2].result
		local sq = sim.human.squad
		if res.winner ~= sq and res.snatch ~= sq and not r.stages[2].champBySquad[sq] then
			T.truthy(res.potLost[sq] ~= nil, "pot lost")
		end
	end)

	T.it("staying to the end: survivors extract automatically (stage 4 or Last Herd Standing)", function()
		local sim =
			H.new(opts(103, { onTick = quickWin(), extractPolicy = plan({ "Stay", "Stay", "Stay" }) }))
		local r = sim:playRun()
		local h = sim.human
		T.truthy(r.endReason == "final" or r.endReason == "lastHerd", tostring(r.endReason))
		-- Last Herd Standing ends it after LAST_HERD_STAGES alone stages, else stage 4 does.
		T.truthy(#r.stages == C.STAGES or r.endReason == "lastHerd", #r.stages .. " stages")
		T.eq(r.outcome, "Win")
		T.eq(r.payout.won, true)
		-- champions (secured) pay too in a long run: the payout is at least the stage pay
		local acc = { 0, 0 }
		for i = 1, #r.stages do
			acc = grow(acc, r.stages[i].result, h.squad, false)
		end
		local mult = if r.payout.lastHerd then C.LAST_HERD_MULT else 1
		T.truthy(r.payout.cheese >= paid(acc, mult, #r.stages), r.payout.cheese .. " >= stage pay")
	end)

	T.it("eliminated on a normal stage: the loot bag takes 30%, the hero keeps 50% of the rest", function()
		local wipe = wipeHumanSquad(3, 3)
		local sim = H.new(opts(104, { onTick = quickWin(wipe), extractPolicy = plan({ "Stay", "Stay" }) }))
		local r = sim:playRun()
		local h = sim.human
		local acc = { 0, 0 }
		for i = 1, 2 do
			acc = grow(acc, r.stages[i].result, h.squad, false)
		end
		T.eq(r.outcome, "Wipe")
		T.eq(r.payout.result, "eliminated")
		T.truthy(table.find(r.stages[3].eliminated, h.squad) ~= nil, "eliminated in stage 3")
		-- 30% bag, half the rest kept, the secured part, the 40-per-stage floor
		-- (champion cheese of stage 3 may add to it: at least this much)
		local bag = math.floor(acc[1] * C.LOOT_BAG_FRAC + 1e-6)
		local want =
			math.max(acc[2] + math.floor((acc[1] - bag) * C.ELIMINATED_KEEP_FRAC + 1e-6), C.STAGE_FLOOR * 3)
		T.truthy(r.payout.cheese >= want, string.format("%d >= %d", r.payout.cheese, want))
		T.truthy(r.payout.cheese <= want * 2 + 200, "no more than champions could add")
		T.truthy(r.stages[3].bags >= 1, "loot bags dropped")
	end)

	T.it("eliminated on a Double-or-Nothing stage loses the whole pot", function()
		local wipe = wipeHumanSquad(3, 3)
		local sim =
			H.new(opts(105, { onTick = quickWin(wipe), extractPolicy = plan({ "Stay", "DoubleOrNothing" }) }))
		local r = sim:playRun()
		T.eq(r.outcome, "Wipe")
		-- v4: the pending pot is lost; secured cheese and the floor stay
		T.eq(r.payout.cheese, math.max(sim.match:member(sim.human.id).secured, C.STAGE_FLOOR * 3))
	end)
end)

T.describe("Integration › determinism", function()
	T.it("(d) the same seed gives an identical match", function()
		for _, seed in { 7, 8 } do
			local a = H.digest(H.new({ seed = seed, maxStages = 2 }):playRun())
			local b = H.digest(H.new({ seed = seed, maxStages = 2 }):playRun())
			T.eq(a, b, "seed " .. seed)
		end
	end)
	T.it("different seeds diverge", function()
		local a = H.digest(H.new({ seed = 1, maxStages = 1 }):playRun())
		local b = H.digest(H.new({ seed = 2, maxStages = 1 }):playRun())
		T.truthy(a ~= b)
	end)
end)

-- (e) Boss balance: 12 heroes with PvP off in the World (one squad) and god
-- mode during waves, so every seed reaches the boss; the boss fight itself is
-- unassisted. (PvP balance is IntegrationSquads.) A boss still alive after
-- BOSS_SECONDS times out (the top damage squad wins), which counts as a failure.
local BOSS_SEEDS = { 1, 2 }
local MIN_KILL = 8

T.describe("Integration › balance: 13 bosses vs 4 squads", function()
	local rows = {}
	for _, bossId in Bosses.ORDER do
		T.it("(e) 12 heroes kill " .. bossId .. " within the time limit (and not in < 8 s)", function()
			local kills, over, timeouts, times = 0, 0, 0, {}
			for _, seed in BOSS_SEEDS do
				local r = H.new({
					seed = seed * 1000 + #bossId,
					bossOverride = bossId,
					maxStages = 1,
					waveSeconds = 40,
					pois = false,
					onTick = noPvp(godMode({ Waves = true })),
				}):playRun()
				local s = r.stages[1]
				if s.bossTimeout then
					timeouts += 1
				elseif s.outcome == "clear" then
					kills += 1
					table.insert(times, s.bossTime or 0)
				else
					over += 1
				end
			end
			table.sort(times)
			local sum = 0
			for _, t in times do
				sum += t
			end
			table.insert(rows, {
				bossId = bossId,
				kills = kills,
				over = over,
				timeouts = timeouts,
				avg = if #times > 0 then sum / #times else nil,
				min = times[1],
				max = times[#times],
			})
			T.eq(timeouts, 0, bossId .. ": boss outlived the " .. H.BOSS_SECONDS .. " s limit")
			T.truthy(kills > 0, bossId .. ": never killed in " .. #BOSS_SEEDS .. " tries")
			T.truthy(
				(times[1] or MIN_KILL) >= MIN_KILL,
				string.format("%s: died in %.1f s (< %d s)", bossId, times[1] or -1, MIN_KILL)
			)
		end)
	end
	T.it("prints the boss balance table", function()
		print("\n  [e] boss              kills ended t/o   avg s   min s   max s")
		for _, r in rows do
			print(
				string.format(
					"  %-18s %5d %5d %3d  %6s  %6s  %6s",
					r.bossId,
					r.kills,
					r.over,
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

return T.finish()
