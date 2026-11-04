-- Runtime emulator, v2 squads scenario (docs/GDD-v2.md §1–3): four humans, two
-- pairs of friends (Player:IsFriendsWith via rt.config.friends), join one server.
-- The real LobbyService seats each pair in its own squad, fills every other seat
-- with a labelled bot (4 squads x 3 = 12 heroes), and the real RunDirector plays
-- the match on shared maps. Checks, all against the real server/client scripts:
--   * 4 squads seated, friends together, bots in every empty seat;
--   * PvP damage (World "damaged" events with a hero `by`) happens between enemy
--     squads and NEVER between squad-mates;
--   * a squad is eliminated and a loot bag drops;
--   * pair A extracts at the stage-2 Rind Gate: they are paid at once (Results,
--     profile cheese) while the match keeps going for pair B;
--   * per-class XP: profile.classes[classId].xp grows;
--   * gear is picked up during the run and is gone in the next run;
--   * zero script errors, zero emulator gaps, no unexpected warnings.
--
-- Test-only knobs: RunDirector.WAVE_SECONDS, Driver.powerUp (25x hero damage/HP,
-- every hero alike) and Driver.tapWorldEvents (reads the World's events).
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")
local Driver = require("../runtime/Driver")

local A1, A2, B1, B2 = 5101, 5102, 5201, 5202
local rt = Runtime.new({ root = ".", dt = 1 / 30, friends = { { A1, A2 }, { B1, B2 } } })
rt:startServer()
local RD = rt:serverModule("ServerScriptService.Server.Services.RunDirector")
local DataService = rt:serverModule("ServerScriptService.Server.Services.DataService")
RD.WAVE_SECONDS = 20
Driver.powerUp(rt, 25)
rt:advance(1)

-- Phase log with each squad's state (printed when a step fails).
local phaseLog = {}
do
	local last = nil
	table.insert(rt.S.frameHooks, function(_dt, phase)
		if phase ~= "post" then
			return
		end
		local p = RD.getPhase()
		if p ~= last then
			last = p
			local view = RD.getMatchView()
			local parts = {}
			for s = 1, 4 do
				local sq = view and view.squads[s]
				if sq then
					table.insert(
						parts,
						string.format(
							"%d:%s",
							s,
							if sq.extracted then "X" elseif sq.eliminated then "E" else tostring(sq.aliveCount)
						)
					)
				end
			end
			table.insert(
				phaseLog,
				string.format(
					"%.0fs %s st%s [%s] A=%s B=%s",
					rt.S.now,
					p,
					tostring(view and view.stage),
					table.concat(parts, " "),
					tostring(squadOfId[A1]),
					tostring(squadOfId[B1])
				)
			)
		end
	end)
end

local failed = false
local function step(name: string, fn: () -> ())
	T.it(name, function()
		if failed then
			error("skipped (an earlier step failed)")
		end
		local ok, err = pcall(fn)
		if not ok then
			print("    phases: " .. table.concat(phaseLog, " | "))
			failed = true
			error(err, 0)
		end
	end)
end

local humans = {} -- { {id, player, client, log} }
local byId = {}
local tap -- Driver.tapWorldEvents record
local arena -- Driver.tapArena record
local squadOfId: { [number]: number } = {}

-- Stage-2 policy: pair A extracts, pair B stays (and everyone stays before).
local function policyFor(id: number)
	return function(kind: string)
		if kind == "route" then
			return "risk"
		elseif kind == "extract" then
			local h = byId[id]
			local State = h and h.State
			local m = State and State.get("match")
			local stage = if type(m) == "table" then m.stage else 0
			if (id == A1 or id == A2) and stage >= 2 then
				return "Extract"
			end
			return "Stay"
		elseif kind == "swap" then
			return true
		end
		return nil
	end
end

T.describe("RuntimeSquads", function()
	step("4 humans (2 friend pairs) are seated in 4 squads; bots fill every other seat", function()
		for _, id in { A1, A2, B1, B2 } do
			local p, c = rt:addPlayer({ userId = id, name = "P" .. id })
			local h = { id = id, player = p, client = c }
			table.insert(humans, h)
			byId[id] = h
			rt:advance(0.5)
		end
		rt:advance(5)
		for _, h in humans do
			h.State = rt:clientModule(h.client, "Client.Controllers.State")
		end
		local lobby = humans[1].State.get("lobby")
		T.truthy(type(lobby) == "table" and type(lobby.squads) == "table", "Lobby payload has squads")
		local seats, bots, humansSeated = 0, 0, 0
		for s = 1, 4 do
			local sq = lobby.squads[s] or lobby.squads[tostring(s)]
			T.truthy(sq and type(sq.members) == "table", "squad " .. s)
			T.eq(#sq.members, 3, "squad " .. s .. " is full")
			for _, mid in sq.members do
				local id = tonumber(mid) :: number
				seats += 1
				squadOfId[id] = s
				if id <= -1001 then
					bots += 1
				else
					humansSeated += 1
				end
			end
		end
		T.eq(seats, 12, "12 seats")
		T.eq(bots, 8, "8 labelled bots")
		T.eq(humansSeated, 4, "4 humans")
		T.eq(squadOfId[A1], squadOfId[A2], "friends A share a squad")
		T.eq(squadOfId[B1], squadOfId[B2], "friends B share a squad")
		T.truthy(squadOfId[A1] ~= squadOfId[B1], "the two pairs are in different squads")
		rt:assertClean(nil, "squads join")
	end)

	local xpBefore: { [number]: number } = {}
	local classOf: { [number]: string } = {}
	step("READY: the match starts with 12 heroes in 4 squads at their corners", function()
		tap = Driver.tapWorldEvents(rt)
		arena = Driver.tapArena(rt)
		for _, h in humans do
			local prof = DataService.get(h.player)
			local entry = h.State.get("lobby").players
			local mine = entry[h.id] or entry[tostring(h.id)]
			classOf[h.id] = mine and mine.classId or "elephante"
			local cs = prof.classes and prof.classes[classOf[h.id]]
			xpBefore[h.id] = if cs then cs.xp or 0 else 0
			h.cheeseBefore = prof.cheese
			h.log = Driver.autoplay(rt, h.client, policyFor(h.id))
			rt:setWalker(
				h.player,
				Driver.squadWalker(rt, arena, function()
					return squadOfId[h.id]
				end, RD.getPhase, { period = 9 + h.id % 4 })
			)
		end
		for _, h in humans do
			local b = Driver.findButton(rt, h.client, "TrunkfallLobby", "READY")
			T.truthy(b, "READY for " .. h.id)
			rt:click(h.client, b)
		end
		T.truthy(
			rt:runUntil(function()
				return RD.getPhase() == "Waves"
			end, 30),
			"reached Waves"
		)
		rt:advance(1)
		local view = RD.getMatchView()
		T.truthy(view and view.squads, "match view")
		local heroes = 0
		for s = 1, 4 do
			heroes += #view.squads[s].members
		end
		T.eq(heroes, 12, "12 heroes in the match")
		for s = 1, 4 do
			for _, id in view.squads[s].members do
				T.eq(squadOfId[id], s, "seated as the lobby showed: " .. id)
			end
		end
		T.eq(#rt.workspace.Bots:GetChildren(), 8, "8 bot models in the arena")
		for _, h in humans do
			T.eq(view.squads[squadOfId[h.id]].members[1] ~= nil, true)
		end
		rt:assertClean(nil, "match start")
	end)

	step("pair A extracts at the stage-2 Rind Gate and is paid while the match goes on", function()
		local paid = rt:runUntil(function()
			return byId[A1].client.inbox.Results ~= nil or RD.getPhase() == "Lobby"
		end, 300)
		T.truthy(paid, "pair A got Results (phase " .. RD.getPhase() .. ")")
		local res = byId[A1].client.inbox.Results.last[1]
		print(
			string.format(
				"    pair A: result=%s stage=%s cheese=%s classXp=%s; server phase %s",
				tostring(res.result),
				tostring(res.stage),
				tostring(res.cheeseEarned),
				tostring(res.classXp),
				RD.getPhase()
			)
		)
		T.eq(res.result, "extracted", "pair A extracted")
		T.eq(res.outcome, "Win", "extracting is a Win")
		T.eq(res.stage, 2, "at the stage-2 gate")
		T.truthy(res.cheeseEarned > 0, "cheese paid")
		T.truthy(DataService.get(byId[A1].player).cheese > byId[A1].cheeseBefore, "profile cheese grew at once")
		local phase = RD.getPhase()
		T.truthy(phase ~= "Lobby" and phase ~= "Results", "the match continues for pair B: " .. phase)
		local extracts = table.concat(byId[A1].log.extracts, ",")
		T.eq(extracts, "Stay,Extract", "pair A's ExtractVote choices")
		T.eq(byId[A1].log.extractFallbacks, 0, "votes went through the ExtractUI cards")
		local sv = rt.serverInbox.ExtractVote
		T.truthy(sv and sv.count >= 4, "ExtractVote reached the server")
		T.eq(type(sv.last[1]), "string", "ExtractVote carries a string choice")
		rt:assertClean(nil, "stage-2 extraction")
	end)

	step("the match ends; PvP only between enemy squads; an elimination and a loot bag", function()
		T.truthy(
			rt:runUntil(function()
				return RD.getPhase() == "Lobby"
			end, 400),
			"match over (phase " .. RD.getPhase() .. ")"
		)
		print(
			string.format(
				"    world events: pvp hits %d (friendly %d), downs %d (pvp %d), kills %d (pvp %d), eliminations %d, bags dropped %d / picked %d, gear pickups %d (humans %d)",
				tap.pvpHits,
				tap.friendlyHits,
				tap.downs,
				tap.pvpDowns,
				tap.kills,
				tap.pvpKills,
				tap.eliminations,
				tap.bagDrops,
				tap.bagPickups,
				tap.gearPickups,
				tap.humanGear
			)
		)
		T.truthy(tap.pvpHits > 0, "enemy squads damaged each other")
		T.eq(tap.friendlyHits, 0, "no damage between squad-mates")
		T.truthy(tap.eliminations > 0, "a squad was eliminated")
		T.truthy(tap.bagDrops > 0, "a loot bag dropped")
		local bRes = byId[B1].client.inbox.Results
		T.truthy(bRes, "pair B got Results")
		for _, h in humans do
			local res = h.client.inbox.Results.last[1]
			local won = res.result == "extracted" or res.result == "lastHerd"
			T.eq(res.outcome, if won then "Win" else "Wipe", h.id .. " outcome matches result " .. res.result)
		end
		rt:assertClean(nil, "match end")
	end)

	step("per-class XP was awarded to every human", function()
		for _, h in humans do
			local prof = DataService.get(h.player)
			local cs = prof.classes and prof.classes[classOf[h.id]]
			T.truthy(cs, h.id .. " has a " .. classOf[h.id] .. " class block")
			T.truthy(
				cs.xp > xpBefore[h.id] or (cs.level or 1) > 1,
				string.format("%d class xp %d -> %d", h.id, xpBefore[h.id], cs.xp)
			)
		end
	end)

	step("gear was picked up in the run and is gone in the next run", function()
		T.truthy(tap.gearPickups > 0, "gear picked up during the match")
		local sawGear = false
		for _, h in humans do
			local inv = h.client.inbox.Inventory
			if inv then
				for _, args in inv.list do
					local p = args[1]
					if type(p) == "table" and (p.weapon or p.armor or p.trinket) then
						sawGear = true
					end
				end
			end
			local prof = DataService.get(h.player)
			T.eq(prof.gear, nil, "no gear in the saved profile")
		end
		T.truthy(sawGear or tap.humanGear > 0, "a human held gear")
		-- Next run: every human starts with empty slots.
		for _, h in humans do
			h.client.inbox.Inventory = nil
			local toLobby = Driver.findButton(rt, h.client, "TrunkfallResults", "Lobby")
			if toLobby then
				rt:click(h.client, toLobby)
			end
		end
		rt:advance(1)
		for _, h in humans do
			local b = Driver.findButton(rt, h.client, "TrunkfallLobby", "READY")
			if b then
				rt:click(h.client, b)
			end
		end
		T.truthy(
			rt:runUntil(function()
				return RD.getPhase() == "Waves"
			end, 40),
			"second match started"
		)
		rt:advance(0.5)
		for _, h in humans do
			local inv = h.client.inbox.Inventory
			T.truthy(inv, h.id .. " got an Inventory for the new run")
			local p = inv.last[1]
			T.truthy(p.weapon == nil and p.armor == nil and p.trinket == nil, h.id .. " starts the new run with no gear")
		end
		rt:assertClean(nil, "second match")
	end)
end)

return T.finish()
