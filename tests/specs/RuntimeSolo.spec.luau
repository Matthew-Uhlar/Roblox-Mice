-- Runtime emulator, scenario (b): solo play end to end, real server + real client
-- scripts. One player (positive UserId) joins, the lobby fills with 2 bots, the
-- player clicks READY, plays a full Cycle 1 (4 stages: route vote, arena with POIs,
-- waves on real CombatService Heartbeat steps, upgrade picks through the UpgradeUI,
-- boss, portal, bank votes through the VoteUI), votes Go Home, gets Results, the
-- profile is saved to the in-memory DataStore with more cheese, and the game is
-- back in the lobby. Zero script errors, zero emulator gaps, no unexpected warnings.
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
local seen = { phases = {}, portal = false, poiCount = 0, bots = 0, hordeVisible = 0, maxSteps = 0 }

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
		T.eq(bots, 2, "lobby bots")
		T.eq(humans, 1, "lobby humans")
		T.eq(#rt.workspace.Bots:GetChildren(), 2, "lobby bot models")
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
			{ "HudUI", "Toasts", "LobbyUI", "VoteUI", "UpgradeUI", "ShopUI", "ResultsUI", "Onboarding" }
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
			elseif kind == "bank" then
				return "Continue"
			elseif kind == "cycle" then
				return "Go Home"
			end
			return nil
		end)
		rt:setWalker(player, Driver.circleWalker(rt, 18, 10))
		rt:click(client, Driver.findButton(rt, client, "TrunkfallLobby", "READY"))
		local started = rt:runUntil(function()
			return RD.getPhase() == "Waves"
		end, 30)
		T.truthy(started, "reached Waves")
		T.truthy(seen.phases.RouteVote, "route vote happened")
		T.eq(log.voteKinds[1], "route", "client voted on the route")
		rt:advance(1)
		T.truthy(seen.bots >= 2, "bots in workspace.Bots during the run: " .. seen.bots)
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

	step("4 stages: bosses spawn and die, the portal opens, bank votes, Go Home", function()
		local done = rt:runUntil(function()
			return client.inbox.Results ~= nil
		end, 600)
		T.truthy(done, "Results arrived (phase now " .. RD.getPhase() .. ")")
		local res = client.inbox.Results.last[1]
		T.eq(res.outcome, "Win", "outcome")
		T.eq(res.bossesKilled, 4, "bosses killed")
		T.truthy(res.cheeseEarned > 0, "cheese earned")
		T.truthy(
			seen.phases.Boss and seen.phases.StageClear and seen.phases.BankVote and seen.phases.CycleVote,
			"phases"
		)
		T.truthy(seen.portal, "portal opened")
		local kinds = table.concat(log.voteKinds, ",")
		T.eq(kinds, "route,bank,route,bank,route,bank,route,cycle", "votes cast by the client UI")
		T.eq(log.votes[#log.votes], "Go Home")
		T.truthy(log.picks >= 3, "upgrade picks: " .. log.picks)
		rt:assertClean(nil, "full run")
	end)

	step("profile saved with more cheese; back to the lobby", function()
		rt:runUntil(function()
			return RD.getPhase() == "Lobby" and State.phase() == "Lobby"
		end, 30)
		T.eq(RD.getPhase(), "Lobby", "server phase")
		T.eq(State.phase(), "Lobby", "client phase")
		local saved = rt:dataStoreValue("TrunkfallProfiles_v1", "u_" .. USER_ID)
		T.truthy(saved and saved.data, "profile in the DataStore")
		T.truthy(
			saved.data.cheese > cheeseBefore,
			string.format("cheese %d -> %d", cheeseBefore, saved.data.cheese)
		)
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
