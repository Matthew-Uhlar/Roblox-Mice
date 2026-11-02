local T = require("../lib/Test")
local RunState = require("../../src/shared/Run/RunState")
local Modifiers = require("../../src/shared/Config/Modifiers")
local Maps = require("../../src/shared/Config/Maps")
local Stats = require("../../src/shared/Run/Stats")

local C = RunState.CONFIG

local function indexOfTier(cards: { any }, tier: string): number
	for i, c in cards do
		if c.tier == tier then
			return i
		end
	end
	error("no card of tier " .. tier)
end

-- Plays one stage: route vote (picking `tier`, or card 1), waves, boss, win.
local function playStage(run: any, tier: string?): (any, any)
	local cards = run:openRouteVote()
	local idx = if tier then indexOfTier(cards, tier) else 1
	local card = run:chooseRoute(idx)
	run:startBoss()
	return run:bossDefeated(), card
end

local function continueTo(run: any, option: string)
	run:openBankVote()
	run:chooseBank(option)
end

-- Plays a full cycle of 4 stages picking `tier` after stage 1; stops at CycleVote.
local function playCycle(run: any, tier: string?)
	for stage = 1, C.STAGES_PER_CYCLE do
		playStage(run, if run.cycle == 1 and stage == 1 then nil else tier)
		if stage < C.STAGES_PER_CYCLE then
			continueTo(run, "Continue")
		end
	end
	run:openBankVote()
end

local function tierOf(id: string): string
	local def = Modifiers.get(id)
	assert(def, "unknown modifier " .. id)
	return def.tier
end

T.describe("RunState basics", function()
	T.it("starts in the Lobby at cycle 1 stage 1 with no cheese", function()
		local run = RunState.new(1, 2)
		T.eq(run.phase, "Lobby")
		local p = run:getPublic()
		T.eq(p.phase, "Lobby")
		T.eq(p.cycle, 1)
		T.eq(p.stageInCycle, 1)
		T.eq(p.pendingCheese, 0)
		T.eq(p.bankedCheese, 0)
		T.eq(p.doubleOrNothing, false)
		T.deepEq(p.activeCurses, {})
		T.deepEq(p.activeBlessings, {})
		T.eq(p.mapId, nil)
		T.eq(p.outcome, nil)
		T.eq(run:currentRoute(), nil)
	end)
	T.it("clamps playerCount", function()
		T.eq(RunState.new(1, 0).playerCount, 1)
		T.eq(RunState.new(1, 9).playerCount, 4)
		T.eq(RunState.new(1, 0 / 0).playerCount, 1)
		local run = RunState.new(1, 1)
		run:setPlayerCount(3)
		T.eq(run.playerCount, 3)
		T.deepEq(run:worldMods(), Stats.worldMods(1, 1, {}, 3))
	end)
	T.it("keeps a fractional party size (bots count 0.6): 1 + 2 x 0.6 = 2.2", function()
		T.eq(RunState.new(1, 1 + 2 * 0.6).playerCount, 2.2)
		T.eq(RunState.new(1, 3 * 0.6).playerCount, 1.8)
		T.eq(RunState.partySize(0.4), 1)
		T.eq(RunState.partySize(math.huge), 4)
		local run = RunState.new(1, 2.2)
		run:setPlayerCount(1.6)
		T.eq(run.playerCount, 1.6)
		T.deepEq(run:worldMods(), Stats.worldMods(1, 1, {}, 1.6))
	end)
	T.it("is deterministic for a seed", function()
		local a, b = RunState.new(77, 1), RunState.new(77, 1)
		for _ = 1, 3 do
			T.deepEq(a:openRouteVote(), b:openRouteVote())
			playStage(a, "Low")
			playStage(b, "Low")
			continueTo(a, "Continue")
			continueTo(b, "Continue")
		end
		T.eq(a:getStageSeed(), b:getStageSeed())
	end)
	T.it("different seeds give different routes", function()
		local differs = false
		local first = RunState.new(1, 1):openRouteVote()
		for seed = 2, 10 do
			local cards = RunState.new(seed, 1):openRouteVote()
			for i = 1, 3 do
				if cards[i].mapId ~= first[i].mapId or cards[i].bossId ~= first[i].bossId then
					differs = true
				end
			end
		end
		T.truthy(differs)
	end)
	T.it("rejects empty map or boss lists", function()
		T.throws(function()
			RunState.new(1, 1, { mapIds = {} })
		end)
		T.throws(function()
			RunState.new(1, 1, { bossIds = {} })
		end)
	end)
end)

T.describe("RunState phase guards", function()
	T.it("errors on calls in the wrong phase", function()
		local run = RunState.new(1, 1)
		T.throws(function()
			run:chooseRoute(1)
		end)
		T.throws(function()
			run:startBoss()
		end)
		T.throws(function()
			run:bossDefeated()
		end)
		T.throws(function()
			run:openBankVote()
		end)
		T.throws(function()
			run:chooseBank("Continue")
		end)
		T.throws(function()
			run:finalRewards()
		end)
		run:openRouteVote()
		T.throws(function()
			run:startBoss()
		end)
		run:chooseRoute(1)
		T.throws(function()
			run:openRouteVote()
		end)
		T.throws(function()
			run:bossDefeated()
		end)
	end)
	T.it("rejects an invalid card index without changing state", function()
		local run = RunState.new(1, 1)
		run:openRouteVote()
		T.throws(function()
			run:chooseRoute(0)
		end)
		T.throws(function()
			run:chooseRoute(4)
		end)
		T.eq(run.phase, "RouteVote")
		run:chooseRoute(3)
		T.eq(run.phase, "Waves")
	end)
	T.it("rejects bank options that don't fit the vote", function()
		local run = RunState.new(1, 1)
		playStage(run)
		run:openBankVote()
		T.throws(function()
			run:chooseBank("GoHome")
		end)
		T.throws(function()
			run:chooseBank("nonsense")
		end)
		T.eq(run.phase, "BankVote")
		local run2 = RunState.new(1, 1)
		playCycle(run2, "Low")
		T.eq(run2.phase, "CycleVote")
		T.throws(function()
			run2:chooseBank("DoubleOrNothing")
		end)
	end)
	T.it("openRouteVote is idempotent while the vote is open", function()
		local run = RunState.new(3, 1)
		local a = run:openRouteVote()
		local b = run:openRouteVote()
		T.eq(a, b)
	end)
	T.it("walks the full phase flow", function()
		local run = RunState.new(5, 1)
		run:openRouteVote()
		T.eq(run.phase, "RouteVote")
		run:chooseRoute(1)
		T.eq(run.phase, "Waves")
		run:startBoss()
		T.eq(run.phase, "Boss")
		run:bossDefeated()
		T.eq(run.phase, "StageClear")
		local bv = run:openBankVote()
		T.eq(run.phase, "BankVote")
		T.eq(bv.kind, "bank")
		T.deepEq(bv.options, { "Continue", "DoubleOrNothing" })
		run:chooseBank("Continue")
		T.eq(run.phase, "RouteVote")
		T.eq(run.stageInCycle, 2)
		T.truthy(run:routeCards() ~= nil, "next cards are pre-rolled")
	end)
end)

T.describe("RunState route cards", function()
	T.it("run stage 1 shows 3 different maps, all Low, no curse, small blessings", function()
		for seed = 1, 50 do
			local cards = RunState.new(seed, 1):openRouteVote()
			T.eq(#cards, 3)
			local maps, blessings = {}, {}
			for _, c in cards do
				T.eq(c.tier, "Low")
				T.eq(c.curseId, nil)
				T.eq(c.rewardMult, 1)
				T.eq(c.cleanse, false)
				T.eq(c.epicChance, 0)
				T.truthy(c.blessingId and tierOf(c.blessingId) == "Low", "blessing tier")
				T.truthy(Maps.get(c.mapId), "map resolves")
				T.truthy(table.find(RunState.DEFAULT_BOSS_IDS, c.bossId) ~= nil, "boss resolves")
				T.falsy(maps[c.mapId], "duplicate map on stage 1")
				maps[c.mapId] = true
				T.falsy(blessings[c.blessingId], "duplicate blessing on stage 1")
				blessings[c.blessingId :: string] = true
			end
		end
	end)
	T.it("later stages show Low / Mid / High with matching curses, blessings and rewards", function()
		for seed = 1, 40 do
			local run = RunState.new(seed, 1)
			playStage(run)
			continueTo(run, "Continue")
			local cards = run:openRouteVote()
			T.deepEq({ cards[1].tier, cards[2].tier, cards[3].tier }, { "Low", "Mid", "High" })
			T.eq(cards[1].rewardMult, 1.0)
			T.eq(cards[2].rewardMult, 1.5)
			T.eq(cards[3].rewardMult, 2.0)
			T.eq(cards[1].epicChance, 0)
			T.eq(cards[2].epicChance, 0)
			T.truthy(cards[3].epicChance > 0 and cards[3].epicChance < 0.5, "small epic chance on High")
			for _, c in cards do
				T.truthy(c.curseId ~= nil, "stage 2 cards all have curses")
				T.eq(tierOf(c.curseId :: string), c.tier)
				T.eq(Modifiers.get(c.curseId :: string).kind, "curse")
				T.truthy(c.blessingId ~= nil)
				T.eq(tierOf(c.blessingId :: string), c.tier)
				T.eq(Modifiers.get(c.blessingId :: string).kind, "blessing")
			end
			T.falsy(cards[1].cleanse or cards[2].cleanse, "only High may cleanse")
			T.falsy(cards[3].cleanse, "no cleanse when there is no run curse")
		end
	end)
	T.it("cards in one vote show different maps and bosses", function()
		for seed = 1, 30 do
			local run = RunState.new(seed, 1)
			for _ = 1, 3 do
				local cards = run:openRouteVote()
				T.truthy(
					cards[1].mapId ~= cards[2].mapId
						and cards[2].mapId ~= cards[3].mapId
						and cards[1].mapId ~= cards[3].mapId
				)
				T.truthy(
					cards[1].bossId ~= cards[2].bossId
						and cards[2].bossId ~= cards[3].bossId
						and cards[1].bossId ~= cards[3].bossId
				)
				run:chooseRoute(1)
				run:startBoss()
				run:bossDefeated()
				continueTo(run, "Continue")
			end
		end
	end)
	T.it("maps never repeat inside a cycle (and are never offered again)", function()
		for seed = 1, 40 do
			local run = RunState.new(seed, 1)
			local used = {}
			for stage = 1, 4 do
				local cards = run:openRouteVote()
				for _, c in cards do
					T.falsy(used[c.mapId], "offered a used map " .. c.mapId)
				end
				local _, card = playStage(run, if stage == 1 then nil else "Mid")
				used[card.mapId] = true
				if stage < 4 then
					continueTo(run, "Continue")
				end
			end
		end
	end)
	T.it("bosses do not repeat inside a cycle when the list allows", function()
		for seed = 1, 20 do
			local run = RunState.new(seed, 1)
			local used = {}
			for stage = 1, 4 do
				local _, card = playStage(run, if stage == 1 then nil else "Low")
				T.falsy(used[card.bossId], "boss repeated " .. card.bossId)
				used[card.bossId] = true
				if stage < 4 then
					continueTo(run, "Continue")
				end
			end
		end
	end)
	T.it("cycle 2 resets the map pool", function()
		local four = { "plains", "beach", "volcano", "swamp" }
		local run = RunState.new(9, 1, { mapIds = four })
		local cycle1 = {}
		for stage = 1, 4 do
			local _, card = playStage(run, if stage == 1 then nil else "Low")
			cycle1[card.mapId] = true
			if stage < 4 then
				continueTo(run, "Continue")
			end
		end
		local n = 0
		for _ in cycle1 do
			n += 1
		end
		T.eq(n, 4, "a 4-map pool is fully used in one cycle")
		run:openBankVote()
		run:chooseBank("NextCycle")
		T.eq(run.cycle, 2)
		T.eq(run.stageInCycle, 1)
		local cards = run:openRouteVote()
		local seen = {}
		for _, c in cards do
			T.truthy(table.find(four, c.mapId) ~= nil)
			T.falsy(seen[c.mapId], "maps distinct after reset")
			seen[c.mapId] = true
		end
		-- and the whole cycle 2 still never repeats
		local cycle2 = {}
		for stage = 1, 4 do
			local _, card = playStage(run, "Low")
			T.falsy(cycle2[card.mapId])
			cycle2[card.mapId] = true
			if stage < 4 then
				continueTo(run, "Continue")
			end
		end
	end)
	T.it("a tiny map pool repeats maps instead of breaking", function()
		local run = RunState.new(4, 1, { mapIds = { "moon", "ocean" } })
		for stage = 1, 4 do
			local cards = run:openRouteVote()
			T.eq(#cards, 3)
			for _, c in cards do
				T.truthy(c.mapId == "moon" or c.mapId == "ocean")
			end
			playStage(run, if stage == 1 then nil else "Low")
			if stage < 4 then
				continueTo(run, "Continue")
			end
		end
	end)
	T.it("uses opts.bossIds", function()
		local run = RunState.new(2, 1, { bossIds = { "void_cat" } })
		for _, c in run:openRouteVote() do
			T.eq(c.bossId, "void_cat")
		end
	end)
	T.it("the Low card has no curse on stage 1 of later cycles", function()
		for seed = 1, 10 do
			local run = RunState.new(seed, 1)
			playCycle(run, "Low")
			run:chooseBank("NextCycle")
			local cards = run:openRouteVote()
			T.deepEq({ cards[1].tier, cards[2].tier, cards[3].tier }, { "Low", "Mid", "High" })
			T.eq(cards[1].curseId, nil)
			T.truthy(cards[2].curseId ~= nil and cards[3].curseId ~= nil)
		end
	end)
	T.it("chooseRoute returns a copy and sets the public map and boss", function()
		local run = RunState.new(8, 1)
		local cards = run:openRouteVote()
		local card = run:chooseRoute(2)
		T.eq(card.mapId, cards[2].mapId)
		card.mapId = "hacked"
		local p = run:getPublic()
		T.eq(p.mapId, cards[2].mapId)
		T.eq(p.bossId, cards[2].bossId)
		T.eq((run:currentRoute() :: any).mapId, cards[2].mapId)
		T.eq(run:routeCards(), nil)
	end)
end)

T.describe("RunState curses and blessings", function()
	T.it("Low and Mid curses last only their stage", function()
		for _, tier in { "Low", "Mid" } do
			local run = RunState.new(12, 1)
			playStage(run)
			continueTo(run, "Continue")
			local cards = run:openRouteVote()
			local card = run:chooseRoute(indexOfTier(cards, tier))
			T.deepEq(run:activeCurses(), { card.curseId })
			T.eq(run:curseEntries()[1].duration, "stage")
			T.deepEq(run:worldMods(), Stats.worldMods(1, 2, { card.curseId :: string }, 1))
			run:startBoss()
			run:bossDefeated()
			T.deepEq(run:activeCurses(), {}, tier .. " curse should expire")
		end
	end)
	T.it("High curses last the whole run, across cycles", function()
		local run = RunState.new(13, 1)
		playStage(run)
		continueTo(run, "Continue")
		local _, card = playStage(run, "High")
		local id = card.curseId :: string
		T.deepEq(run:activeCurses(), { id })
		T.eq(run:curseEntries()[1].duration, "run")
		continueTo(run, "Continue")
		playStage(run, "Low")
		T.truthy(table.find(run:activeCurses(), id) ~= nil)
		continueTo(run, "Continue")
		playStage(run, "Low")
		run:openBankVote()
		run:chooseBank("NextCycle")
		T.truthy(table.find(run:activeCurses(), id) ~= nil, "still active in cycle 2")
		T.truthy(table.find(run:getPublic().activeCurses, id) ~= nil)
	end)
	T.it("an active run curse is never offered again", function()
		local run = RunState.new(14, 1)
		playStage(run)
		continueTo(run, "Continue")
		local _, card = playStage(run, "High")
		for _ = 1, 2 do
			continueTo(run, "Continue")
			local cards = run:openRouteVote()
			for _, c in cards do
				T.truthy(c.curseId ~= card.curseId)
			end
			playStage(run, "Low")
		end
	end)
	T.it("the blessing is granted only after the boss falls", function()
		local run = RunState.new(15, 1)
		local cards = run:openRouteVote()
		run:chooseRoute(1)
		T.deepEq(run:activeBlessings(), {})
		run:startBoss()
		local reward = run:bossDefeated()
		T.eq(reward.blessingId, cards[1].blessingId)
		T.deepEq(run:activeBlessings(), { cards[1].blessingId })
		T.deepEq(run:getPublic().activeBlessings, { cards[1].blessingId })
	end)
	T.it("a wipe grants no blessing", function()
		local run = RunState.new(16, 1)
		run:openRouteVote()
		run:chooseRoute(1)
		run:startBoss()
		run:wipe()
		T.deepEq(run:activeBlessings(), {})
	end)
	T.it("prefers blessings the party does not own yet", function()
		local run = RunState.new(17, 1)
		local owned = {}
		for stage = 1, 4 do
			local cards = run:openRouteVote()
			local i = if stage == 1 then 1 else indexOfTier(cards, "Low")
			T.falsy(owned[cards[i].blessingId], "re-offered owned Low blessing")
			owned[cards[i].blessingId] = true
			run:chooseRoute(i)
			run:startBoss()
			run:bossDefeated()
			if stage < 4 then
				continueTo(run, "Continue")
			end
		end
	end)
	T.it("cleanse removes the oldest run-long curse, then adds the card's curse", function()
		local found = false
		for seed = 1, 200 do
			local run = RunState.new(seed, 1)
			playStage(run)
			continueTo(run, "Continue")
			local _, first = playStage(run, "High")
			continueTo(run, "Continue")
			local cards = run:openRouteVote()
			local high = cards[indexOfTier(cards, "High")]
			if high.cleanse then
				found = true
				T.truthy(high.curseId ~= first.curseId)
				run:chooseRoute(indexOfTier(cards, "High"))
				local active = run:activeCurses()
				T.eq(table.find(active, first.curseId), nil, "old curse cleansed")
				T.deepEq(active, { high.curseId })
				break
			end
		end
		T.truthy(found, "some seed should offer a cleanse")
	end)
	T.it("cleanse removes only one curse and keeps the rest", function()
		local found = false
		for seed = 1, 400 do
			local run = RunState.new(seed, 1)
			playStage(run)
			continueTo(run, "Continue")
			local _, a = playStage(run, "High")
			continueTo(run, "Continue")
			local cards = run:openRouteVote()
			if not cards[3].cleanse then
				local _, b = playStage(run, "High")
				continueTo(run, "Continue")
				local cards4 = run:openRouteVote()
				if cards4[3].cleanse then
					found = true
					run:chooseRoute(3)
					T.deepEq(
						run:activeCurses(),
						{ b.curseId, cards4[3].curseId },
						"oldest (" .. tostring(a.curseId) .. ") removed"
					)
					break
				end
			end
		end
		T.truthy(found)
	end)
	T.it("High cards offer cleanse only sometimes", function()
		local yes, no = 0, 0
		for seed = 1, 200 do
			local run = RunState.new(seed, 1)
			playStage(run)
			continueTo(run, "Continue")
			playStage(run, "High")
			continueTo(run, "Continue")
			if run:openRouteVote()[3].cleanse then
				yes += 1
			else
				no += 1
			end
		end
		T.truthy(yes > 20 and no > 20, "yes " .. yes .. " no " .. no)
	end)
end)

T.describe("RunState rewards", function()
	T.it("stageCheese / stageXp follow the formulas", function()
		T.eq(RunState.stageCheese(1, 1, 1, false), 100)
		T.eq(RunState.stageCheese(1, 2, 1.5, false), 187) -- floor(125 * 1.5)
		T.eq(RunState.stageCheese(1, 1, 2, true), 400)
		T.eq(RunState.stageCheese(2, 1, 1, false), 150)
		T.eq(RunState.stageXp(1, 1, 1), 50)
		T.eq(RunState.stageXp(2, 4, 2), math.floor(80 * 1.5 * 2))
	end)
	T.it("boss rewards add to pending, scaled by the route mult", function()
		local run = RunState.new(20, 1)
		local r1 = playStage(run)
		T.eq(r1.cheesePerPlayer, 100)
		T.eq(r1.xpPerPlayer, 50)
		T.eq(r1.potBonus, 0)
		T.eq(run.pendingCheese, 100)
		continueTo(run, "Continue")
		local r2 = playStage(run, "High")
		T.eq(r2.cheesePerPlayer, RunState.stageCheese(1, 2, 2, false))
		T.eq(run.pendingCheese, 100 + r2.cheesePerPlayer)
		T.eq(run:getPublic().pendingCheese, run.pendingCheese)
		T.eq(run.bankedCheese, 0)
		T.eq(run.bossesKilled, 2)
	end)
	T.it("epic drops only come from High routes, at a small rate", function()
		local highEpics, lowEpics, n = 0, 0, 300
		for seed = 1, n do
			local run = RunState.new(seed, 1)
			playStage(run)
			continueTo(run, "Continue")
			local r = playStage(run, "High")
			if r.epic then
				highEpics += 1
			end
			continueTo(run, "Continue")
			local r2 = playStage(run, "Low")
			if r2.epic then
				lowEpics += 1
			end
		end
		T.eq(lowEpics, 0)
		T.truthy(highEpics > 0 and highEpics < n * 0.25, "high epics " .. highEpics)
	end)
	T.it("bank votes: stages 1-3 offer Continue / DoN, stage 4 offers GoHome / NextCycle", function()
		local run = RunState.new(21, 1)
		for stage = 1, 4 do
			playStage(run, if stage == 1 then nil else "Low")
			local bv = run:openBankVote()
			if stage < 4 then
				T.eq(bv.kind, "bank")
				T.eq(run.phase, "BankVote")
				run:chooseBank("Continue")
			else
				T.eq(bv.kind, "cycle")
				T.eq(run.phase, "CycleVote")
				T.deepEq(bv.options, { "GoHome", "NextCycle" })
			end
		end
	end)
	T.it("Double or Nothing win doubles the stage chest and grows the pot x1.5", function()
		local run = RunState.new(22, 1)
		playStage(run) -- pending 100
		continueTo(run, "DoubleOrNothing")
		T.eq(run.doubleOrNothing, true)
		T.eq(run:getPublic().doubleOrNothing, true)
		local r = playStage(run, "Low")
		T.eq(r.cheesePerPlayer, 250) -- floor(125 * 1 * 2)
		T.eq(r.potBonus, 50)
		T.eq(run.pendingCheese, 150 + 250)
		T.eq(run.doubleOrNothing, false, "DoN lasts one stage")
		T.eq(r.xpPerPlayer, RunState.stageXp(1, 2, 1), "XP is not doubled")
	end)
	T.it("Continue after DoN goes back to normal rewards", function()
		local run = RunState.new(23, 1)
		playStage(run)
		continueTo(run, "DoubleOrNothing")
		playStage(run, "Low")
		continueTo(run, "Continue")
		local before = run.pendingCheese
		local r = playStage(run, "Low")
		T.eq(r.cheesePerPlayer, RunState.stageCheese(1, 3, 1, false))
		T.eq(run.pendingCheese, before + r.cheesePerPlayer)
	end)
	T.it("Go Home banks 100% and ends the run as a win", function()
		local run = RunState.new(24, 1)
		playCycle(run, "Low")
		local pending = run.pendingCheese
		T.truthy(pending > 0)
		run:chooseBank("GoHome")
		T.eq(run.phase, "Results")
		T.eq(run.bankedCheese, pending)
		T.eq(run.pendingCheese, 0)
		local f = run:finalRewards()
		T.eq(f.outcome, "Win")
		T.eq(f.cheesePerPlayer, pending)
		T.eq(f.xpPerPlayer, run.xpEarned)
		T.eq(run:getPublic().outcome, "Win")
	end)
	T.it("Next Cycle banks 50% and carries the rest as pending", function()
		local run = RunState.new(25, 1)
		playCycle(run, "Mid")
		local pending = run.pendingCheese
		run:chooseBank("NextCycle")
		T.eq(run.bankedCheese, math.floor(pending * 0.5))
		T.eq(run.pendingCheese, pending - math.floor(pending * 0.5))
		T.eq(run.cycle, 2)
		T.eq(run.stageInCycle, 1)
		T.eq(run.phase, "RouteVote")
		T.eq(run.outcome, nil)
	end)
	T.it("rewards and difficulty grow in cycle 2", function()
		local run = RunState.new(26, 1)
		playCycle(run, "Low")
		local c1 = run:worldMods()
		run:chooseBank("NextCycle")
		local c2 = run:worldMods()
		T.truthy(c2.enemyHpMult > c1.enemyHpMult, "cycle 2 stage 1 is harder than cycle 1 stage 4")
		T.truthy(c2.enemyHpMult > Stats.worldMods(1, 1, {}, 1).enemyHpMult)
		local r = playStage(run, "Low")
		T.eq(r.cheesePerPlayer, RunState.stageCheese(2, 1, 1, false))
		T.truthy(r.cheesePerPlayer > RunState.stageCheese(1, 1, 1, false))
		T.eq(run:globalStage(), 5)
	end)
end)

T.describe("RunState wipes", function()
	T.it("a wipe keeps banked cheese and 50% of pending", function()
		local run = RunState.new(30, 1)
		playStage(run)
		continueTo(run, "Continue")
		playStage(run, "Mid")
		continueTo(run, "Continue")
		local pending = run.pendingCheese
		run:openRouteVote()
		run:chooseRoute(1)
		run:wipe()
		T.eq(run.phase, "Results")
		T.eq(run.bankedCheese, math.floor(pending * 0.5))
		T.eq(run.pendingCheese, 0)
		local f = run:finalRewards()
		T.eq(f.outcome, "Wipe")
		T.eq(f.cheesePerPlayer, math.floor(pending * 0.5))
	end)
	T.it("a wipe during Double or Nothing loses the whole pending pot", function()
		local run = RunState.new(31, 1)
		playStage(run)
		continueTo(run, "DoubleOrNothing")
		run:openRouteVote()
		run:chooseRoute(1)
		run:startBoss()
		run:wipe()
		T.eq(run.bankedCheese, 0)
		T.eq(run:finalRewards().cheesePerPlayer, 0)
		T.eq(run:finalRewards().outcome, "Wipe")
	end)
	T.it("a DoN wipe in cycle 2 keeps what was banked at the cycle change", function()
		local run = RunState.new(32, 1)
		playCycle(run, "Low")
		run:chooseBank("NextCycle")
		local banked = run.bankedCheese
		T.truthy(banked > 0)
		playStage(run, "Low")
		continueTo(run, "DoubleOrNothing")
		run:openRouteVote()
		run:chooseRoute(2)
		run:wipe()
		T.eq(run:finalRewards().cheesePerPlayer, banked)
	end)
	T.it("a wipe during the route vote after choosing DoN still loses the pot", function()
		local run = RunState.new(33, 1)
		playStage(run)
		continueTo(run, "DoubleOrNothing")
		T.eq(run.phase, "RouteVote")
		run:wipe()
		T.eq(run.bankedCheese, 0)
	end)
	T.it("a wipe on stage 1 with nothing earned pays 0", function()
		local run = RunState.new(34, 1)
		run:openRouteVote()
		run:chooseRoute(1)
		run:wipe()
		local f = run:finalRewards()
		T.eq(f.cheesePerPlayer, 0)
		T.eq(f.xpPerPlayer, 0)
		T.eq(f.outcome, "Wipe")
	end)
	T.it("XP earned is kept on a wipe", function()
		local run = RunState.new(35, 1)
		playStage(run)
		continueTo(run, "DoubleOrNothing")
		run:openRouteVote()
		run:chooseRoute(1)
		run:wipe()
		T.eq(run:finalRewards().xpPerPlayer, 50)
	end)
	T.it("wipe is a no-op once the run is over", function()
		local run = RunState.new(36, 1)
		playCycle(run, "Low")
		run:chooseBank("GoHome")
		local banked = run.bankedCheese
		run:wipe()
		T.eq(run.bankedCheese, banked)
		T.eq(run:finalRewards().outcome, "Win")
	end)
	T.it("no further transitions after Results", function()
		local run = RunState.new(37, 1)
		run:wipe()
		T.throws(function()
			run:openRouteVote()
		end)
		T.throws(function()
			run:openBankVote()
		end)
	end)
end)

T.describe("RunState with Pressure (GDD §3.7)", function()
	local Pressure = require("../../src/shared/Run/Pressure")
	local board = { stampede = 2, thick_rind = 3, boss_fury = 1, no_snacks = 1 } -- 7 points

	T.it("no pressure: identical to a plain run", function()
		local a = RunState.new(5, 2)
		local b = RunState.new(5, 2, { pressure = {} })
		T.eq(a:pressurePoints(), 0)
		T.eq(a:pressureLuck(), 0)
		T.deepEq(a:worldMods(), b:worldMods())
		T.deepEq(a:openRouteVote(), b:openRouteVote())
		T.deepEq(playStage(a, "Low"), playStage(b, "Low"))
		T.deepEq(a:getPublic().pressure, {})
		T.eq(a:getPublic().pressurePoints, 0)
	end)

	T.it("sanitizes the board it is given and never aliases it", function()
		local raw = { stampede = 99, nope = 4, thick_rind = -1, boss_fury = 0 / 0 }
		local run = RunState.new(1, 1, { pressure = raw :: any })
		T.deepEq(run:pressureBoard(), { stampede = 3 })
		T.eq(run:pressurePoints(), 3)
		raw.stampede = 1
		T.deepEq(run:getPublic().pressure, { stampede = 3 })
		local pub = run:getPublic()
		pub.pressure.stampede = 1
		T.deepEq(run:pressureBoard(), { stampede = 3 }, "public copy is a copy")
	end)

	T.it("points, luck and the public view", function()
		local run = RunState.new(3, 2.2, { pressure = board })
		T.eq(run:pressurePoints(), 7)
		T.near(run:pressureLuck(), 0.35)
		local pub = run:getPublic()
		T.deepEq(pub.pressure, board)
		T.eq(pub.pressurePoints, 7)
	end)

	T.it("worldMods = difficulty + curses + pressure, every stage", function()
		local run = RunState.new(9, 3, { pressure = board })
		T.deepEq(run:worldMods(), Pressure.applyToMods(Stats.worldMods(1, 1, {}, 3), board))
		local mods = run:worldMods() :: any
		local plain = Stats.worldMods(1, 1, {}, 3)
		T.near(mods.enemyHpMult, plain.enemyHpMult * 1.45)
		T.near(mods.bossHpMult, plain.bossHpMult * 1.45)
		T.near(mods.bossDamageMult, plain.bossDamageMult * 1.2)
		T.near(mods.healingMult, 0.75)
		T.near(mods.eliteSpeedMult, 1.6)
		playStage(run, nil)
		continueTo(run, "Continue")
		local card = run:chooseRoute(indexOfTier(run:openRouteVote(), "Mid"))
		local curses = if card.curseId then { card.curseId :: string } else {}
		T.deepEq(run:worldMods(), Pressure.applyToMods(Stats.worldMods(1, 2, curses, 3), board))
	end)

	T.it("+8% cheese per point on every stage chest, carried into finalRewards once", function()
		local plain = RunState.new(21, 1)
		local hot = RunState.new(21, 1, { pressure = board })
		local total = 0
		for stage = 1, C.STAGES_PER_CYCLE do
			local tier = if stage == 1 then nil else "Mid"
			local r1 = playStage(plain, tier)
			local r2 = playStage(hot, tier)
			T.eq(r2.cheesePerPlayer, math.floor(r1.cheesePerPlayer * 1.56 + 1e-6), "stage " .. stage)
			T.eq(r2.xpPerPlayer, r1.xpPerPlayer, "XP is not boosted")
			total += r2.cheesePerPlayer
			if stage < C.STAGES_PER_CYCLE then
				continueTo(plain, "Continue")
				continueTo(hot, "Continue")
			end
		end
		T.eq(hot:getPublic().pendingCheese, total)
		hot:openBankVote()
		hot:chooseBank("GoHome")
		local fr = hot:finalRewards()
		T.eq(fr.cheesePerPlayer, total, "bonus counted once, not again at the end")
		T.eq(fr.outcome, "Win")
		T.eq(fr.pressurePoints, 7)
	end)

	T.it("stacks with Double or Nothing", function()
		local hot = RunState.new(4, 1, { pressure = { stampede = 1 } })
		playStage(hot, nil)
		continueTo(hot, "DoubleOrNothing")
		local r = playStage(hot, "Low")
		T.eq(r.cheesePerPlayer, math.floor(RunState.stageCheese(1, 2, 1, true) * 1.08 + 1e-6))
		T.eq(RunState.applyPressureCheese(100, 0), 100)
		T.eq(RunState.applyPressureCheese(125, 3), 155)
	end)

	T.it("+2% Epic chance per point on every card, capped at 1", function()
		local run = RunState.new(8, 1, { pressure = board })
		for _, card in run:openRouteVote() do
			T.near(card.epicChance, C.EPIC_CHANCE[card.tier] + 0.14)
		end
		playStage(run, nil)
		continueTo(run, "Continue")
		for _, card in run:openRouteVote() do
			T.near(card.epicChance, C.EPIC_CHANCE[card.tier] + 0.14)
		end
		local full: { [string]: number } = {}
		for _, id in Pressure.ORDER do
			full[id] = 3
		end
		local maxed = RunState.new(8, 1, { pressure = full })
		for _, card in maxed:openRouteVote() do
			T.truthy(card.epicChance <= 1)
			T.near(card.epicChance, math.min(1, C.EPIC_CHANCE[card.tier] + 0.42))
		end
	end)

	T.it("a Low route can drop an Epic under Pressure", function()
		local full: { [string]: number } = {}
		for _, id in Pressure.ORDER do
			full[id] = 3
		end
		local epics = 0
		for seed = 1, 40 do
			local run = RunState.new(seed, 1, { pressure = full })
			if playStage(run, nil).epic then
				epics += 1
			end
		end
		T.truthy(epics > 5 and epics < 35, "about 42% of 40 stage-1 clears, got " .. epics)
	end)
end)

T.describe("RunState.addPending", function()
	T.it("adds whole, finite, positive amounts only", function()
		local run = RunState.new(1, 1)
		T.eq(run:addPending(12.7), 12)
		T.eq(run.pendingCheese, 12)
		T.eq(run:addPending(-5), 0)
		T.eq(run:addPending(0 / 0), 0)
		T.eq(run:addPending(math.huge), 0)
		T.eq(run.pendingCheese, 12)
	end)
end)

return T.finish()
