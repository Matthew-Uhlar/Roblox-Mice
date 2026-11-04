-- Runtime emulator, scenario (b): solo play end to end, real server + real client
-- scripts (v2 squads, docs/GDD-v2.md §1). One player (positive UserId) joins and
-- the lobby seats 11 labelled bots: 2 squad-mates and 3 bot squads. The player
-- clicks READY and plays the match: arena with POIs, waves on real CombatService
-- Heartbeat steps, upgrade picks through the UpgradeUI, the boss at the centre,
-- the route choice (VoteUI, only when the player's squad won the boss) and the
-- Rind Gate extraction (ExtractUI -> ExtractVote with a string choice: Stay after
-- stage 1, Extract after stage 2). Results ("Win" only when the squad extracted),
-- the profile is saved with the cheese and class XP, and the game is back in the
-- lobby. Zero script errors, zero emulator gaps, no unexpected warnings.
--
-- Test-only knobs (tests/runtime/Driver.luau): RunDirector.WAVE_SECONDS = 20 and
-- Driver.powerUp (25x hero damage/HP), both applied to the server context's
-- module tables. src/ is not modified for the test.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")
local Driver = require("../runtime/Driver")

local USER_ID = 424242
local rt = Runtime.new({ root = ".", dt = 1 / 30 })
rt:startServer()
local RD = rt:serverModule("ServerScriptService.Server.Services.RunDirector")
local CombatService = rt:serverModule("ServerScriptService.Server.Services.CombatService")
local ArenaBuilder = rt:serverModule("ServerScriptService.Server.Services.ArenaBuilder")
RD.WAVE_SECONDS = 20
Driver.powerUp(rt, 25)
rt:advance(1)

local failed = false
local function step(name: string, fn: () -> ())
	T.it(name, function()
		if failed then
			error("skipped (an earlier step failed)")
		end
		local ok, err = pcall(fn)
		if not ok then
			failed = true
			error(err, 0)
		end
	end)
end

local player, client, State
local seen = {
	phases = {},
	portal = false,
	poiCount = 0,
	bots = 0,
	hordeVisible = 0,
	maxSteps = 0,
	wonStages = {}, -- stages whose route our squad chose (Match.routeChooser == our squad)
}

-- Watches the world every frame (driver side; reads only).
table.insert(rt.S.frameHooks, function(_dt, phase)
	if phase ~= "post" then
		return
	end
	seen.phases[RD.getPhase()] = true
	if rt.workspace:FindFirstChild(ArenaBuilder.PORTAL_NAME, true) then
		seen.portal = true
	end
	local arena = rt.workspace:FindFirstChild(ArenaBuilder.ARENA_NAME)
	local pois = arena and arena:FindFirstChild("POIs")
	if pois then
		seen.poiCount = math.max(seen.poiCount, #pois:GetChildren())
	end
	local bots = rt.workspace:FindFirstChild("Bots")
	if bots and RD.getPhase() == "Waves" then
		seen.bots = math.max(seen.bots, #bots:GetChildren())
	end
	seen.maxSteps = math.max(seen.maxSteps, CombatService.stats.steps)
	if RD.getPhase() == "RouteChoice" then
		local view = RD.getMatchView()
		local chooser = view and view.routeChooser
		if chooser then
			local mine = false
			for _, id in view.squads[chooser].members do
				mine = mine or id == USER_ID
			end
			local st = view.stage
			if mine and st and not table.find(seen.wonStages, st) then
				table.insert(seen.wonStages, st)
			end
		end
	end
end)

T.describe("RuntimeSolo", function()
	step("player joins; client controllers and UIs boot; lobby shows 2 bots", function()
		player, client = rt:addPlayer({ userId = USER_ID, name = "Solo" })
		rt:advance(4)
		rt:assertClean(nil, "join")
		State = rt:clientModule(client, "Client.Controllers.State")
		local lobby = State.get("lobby")
		T.truthy(type(lobby) == "table" and type(lobby.players) == "table", "Lobby payload reached State")
		local bots, humans = 0, 0
		for id, e in lobby.players do
			if State.isBot(tonumber(id), e) then
				bots += 1
			else
				humans += 1
			end
		end
		T.eq(bots, 11, "lobby bots: 2 squad-mates + 3 bot squads")
		T.eq(humans, 1, "lobby humans")
		T.truthy(type(lobby.squads) == "table", "lobby squads")
		local seats, mine = 0, nil
		for sId = 1, 4 do
			local sq = lobby.squads[sId] or lobby.squads[tostring(sId)]
			T.truthy(sq and #sq.members == 3, "squad " .. sId .. " has 3 seats")
			for _, id in sq.members do
				seats += 1
				if tonumber(id) == USER_ID then
					mine = sId
				end
			end
		end
		T.eq(seats, 12, "12 seats")
		T.truthy(mine ~= nil, "the player is seated")
		T.eq(#rt.workspace.Bots:GetChildren(), 11, "lobby bot models")
		-- every client module loaded
		for _, name in
			{ "State", "CameraController", "HordeRenderer", "FxController", "ChatTags", "InputController" }
		do
			T.truthy(
				client.moduleCache[rt:find("Players.Solo.PlayerScripts.Client.Controllers." .. name, client)],
				name
			)
		end
		for _, name in
			{
				"HudUI",
				"Toasts",
				"LobbyUI",
				"VoteUI",
				"UpgradeUI",
				"ShopUI",
				"ResultsUI",
				"Onboarding",
				"ExtractUI",
				"ScoreboardUI",
				"KillFeedUI",
				"MinimapUI",
				"GearUI",
			}
		do
			T.truthy(
				client.moduleCache[rt:find("Players.Solo.PlayerScripts.Client.UI." .. name, client)],
				name
			)
		end
		T.truthy(Driver.findButton(rt, client, "TrunkfallLobby", "READY"), "READY button on screen")
	end)

	local cheeseBefore = 0
	local log
	step("READY -> countdown -> run starts; bots spawn under workspace.Bots", function()
		local saved = rt:dataStoreValue("TrunkfallProfiles_v1", "u_" .. USER_ID)
		cheeseBefore = if saved and saved.data then saved.data.cheese or 0 else 0
		log = Driver.autoplay(rt, client, function(kind)
			if kind == "route" then
				return "risk" -- first route card
			elseif kind == "extract" then
				local m = State.get("match")
				return if type(m) == "table" and m.stage >= 2 then "Extract" else "Stay"
			elseif kind == "swap" then
				return true
			end
			return nil
		end)
		rt:setWalker(player, Driver.circleWalker(rt, 18, 10))
		rt:click(client, Driver.findButton(rt, client, "TrunkfallLobby", "READY"))
		local started = rt:runUntil(function()
			return RD.getPhase() == "Waves"
		end, 30)
		T.truthy(started, "reached Waves")
		T.eq(#log.voteKinds, 0, "nobody votes on the first route (a seeded Low card)")
		rt:advance(1)
		T.eq(seen.bots, 11, "11 bots in workspace.Bots during the run")
		T.truthy(seen.poiCount > 0, "arena built with POIs")
		rt:assertClean(nil, "run start")
	end)

	step("waves run on Heartbeat; Snapshot/Fx reach the client and render", function()
		rt:advance(8)
		T.truthy(seen.maxSteps > 100, "CombatService stepped: " .. seen.maxSteps)
		T.truthy((client.inbox.Snapshot and client.inbox.Snapshot.count or 0) > 20, "snapshots received")
		T.truthy((client.inbox.Fx and client.inbox.Fx.count or 0) > 20, "fx received")
		local horde = rt:find("Workspace.TrunkfallHorde", client)
		T.truthy(horde, "HordeRenderer folder")
		local shown = rt:runIn(client, function()
			local n = 0
			for _, x in horde:GetDescendants() do
				if x:IsA("BasePart") and x.Transparency < 1 and x.Position.Y > -1000 then
					n += 1
				end
			end
			return n
		end)
		T.truthy(shown > 0, "mice rendered: " .. shown)
		rt:assertClean(nil, "waves")
	end)

	step("level-ups offer upgrades; the client picks through ChooseUpgrade", function()
		rt:runUntil(function()
			return (rt.serverInbox.ChooseUpgrade and rt.serverInbox.ChooseUpgrade.count or 0) > 0
		end, 60)
		T.truthy(
			(client.inbox.UpgradeOffer and client.inbox.UpgradeOffer.count or 0) > 0,
			"UpgradeOffer received"
		)
		T.truthy(
			(rt.serverInbox.ChooseUpgrade and rt.serverInbox.ChooseUpgrade.count or 0) > 0,
			"ChooseUpgrade sent"
		)
	end)

	local res
	step("the match: bosses, route choice by the winner, the Rind Gate, Results", function()
		local done = rt:runUntil(function()
			return client.inbox.Results ~= nil
		end, 600)
		T.truthy(done, "Results arrived (phase now " .. RD.getPhase() .. ")")
		res = client.inbox.Results.last[1]
		print(
			string.format(
				"    result %s (%s) after %d stage(s): %d cheese, %d class xp; route votes %d, chooser stages %s",
				tostring(res.result),
				tostring(res.outcome),
				res.stagesCleared,
				res.cheeseEarned,
				res.classXp or 0,
				#log.voteKinds,
				table.concat(seen.wonStages, ",")
			)
		)
		local won = res.result == "extracted" or res.result == "lastHerd"
		T.eq(res.outcome, if won then "Win" else "Wipe", "Win only when the squad extracted")
		T.truthy(res.stagesCleared >= 1, "at least one boss fell")
		T.truthy(seen.phases.Boss and seen.phases.RouteChoice and seen.phases.Extraction, "v2 phases")
		T.truthy(seen.portal, "the Rind Gate opened")
		-- The route vote reaches only the squad that won the boss.
		for _, k in log.voteKinds do
			T.eq(k, "route", "only route votes")
		end
		T.eq(#log.voteKinds, #seen.wonStages, "a route vote for each boss our squad won, and no other")
		T.eq(
			(client.inbox.VoteOpen and client.inbox.VoteOpen.count or 0),
			#seen.wonStages,
			"VoteOpen only to the winner"
		)
		-- Extraction through the ExtractUI cards: ExtractVote(choice: string).
		T.truthy(#log.extracts >= 1, "the player answered an extraction window")
		T.eq(log.extractFallbacks, 0, "votes went through the ExtractUI cards")
		local sv = rt.serverInbox.ExtractVote
		T.truthy(sv and sv.count >= #log.extracts, "ExtractVote reached the server")
		for _, args in sv.list do
			T.eq(type(args[1]), "string", "ExtractVote carries a string choice")
		end
		if res.result == "extracted" then
			T.eq(log.extracts[#log.extracts], "Extract", "extracted by voting Extract")
			T.eq(res.stagesCleared, 2, "at the stage-2 gate")
		end
		T.truthy(log.picks >= 3, "upgrade picks: " .. log.picks)
		rt:assertClean(nil, "full run")
	end)

	step("profile saved with more cheese; back to the lobby", function()
		rt:runUntil(function()
			return RD.getPhase() == "Lobby" and State.phase() == "Lobby"
		end, 30)
		T.eq(RD.getPhase(), "Lobby", "server phase")
		T.eq(State.phase(), "Lobby", "client phase")
		rt:advance(8) -- the paced save after the payout (DataService.WRITE_SPACING)
		local saved = rt:dataStoreValue("TrunkfallProfiles_v1", "u_" .. USER_ID)
		T.truthy(saved and saved.data, "profile in the DataStore")
		-- (DataService adds the first-run-of-the-day bonus on top)
		T.truthy(
			saved.data.cheese >= cheeseBefore + res.cheeseEarned and saved.data.cheese > cheeseBefore,
			string.format("cheese %d + %d earned -> %d", cheeseBefore, res.cheeseEarned, saved.data.cheese)
		)
		local cls = saved.data.classes and saved.data.classes[res.classId]
		T.truthy(cls and (cls.xp > 0 or (cls.level or 1) > 1), "class XP saved for " .. tostring(res.classId))
		T.eq(saved.lock and saved.lock.jobId, rt.config.jobId, "session lock still held while playing")
		-- the Results screen stays up until the player leaves it
		local toLobby = Driver.findButton(rt, client, "TrunkfallResults", "Lobby")
		T.truthy(toLobby, "Results screen offers Lobby")
		rt:click(client, toLobby)
		rt:advance(1)
		T.truthy(Driver.findButton(rt, client, "TrunkfallLobby", "READY"), "lobby UI back")
		rt:setWalker(player, nil)
		rt:advance(15)
		-- the client cleaned the arena effects up
		local leftovers = rt:runIn(client, function()
			local n = 0
			for _, name in { "TrunkfallHorde", "TrunkfallFx" } do
				local f = rt.workspace:FindFirstChild(name)
				for _, x in if f then f:GetDescendants() else {} do
					if x:IsA("BasePart") and x.Transparency < 1 and x.Position.Y > -1000 then
						n += 1
					end
				end
			end
			return n
		end)
		T.eq(leftovers, 0, "visible client parts left after the run")
		rt:assertClean(nil, "lobby")
	end)

	step("leaving saves and releases the session lock", function()
		rt:removePlayer(player)
		rt:advance(5)
		local saved = rt:dataStoreValue("TrunkfallProfiles_v1", "u_" .. USER_ID)
		T.eq(saved.lock, nil, "lock released")
		rt:assertClean(nil, "leave")
	end)
end)

return T.finish()
