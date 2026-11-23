-- Runtime emulator, iteration 6 (owner request): the lobby vote and the Ready
-- countdown with 2 players, real server + client scripts. A and B (fresh profiles:
-- rookies, so Mild / Medium and Normal pace) vote different tiers: the lobby view
-- carries each vote, the tallies and the winner (a 1-1 tie -> the lower tier). A
-- rookie's Fast vote does not count. The first READY starts a 60 s countdown; the
-- second READY (everyone) starts the match at once, on the voted tier.
-- Zero script errors, gaps or unexpected warnings.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")

local A_ID, B_ID = 717171, 727272
local rt = Runtime.new({ root = ".", dt = 1 / 30 })
rt:startServer()
local RD = rt:serverModule("ServerScriptService.Server.Services.RunDirector")
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

local playerA, clientA, playerB, clientB
local function fire(client: any, name: string, ...: any)
	local args = table.pack(...)
	local Remotes = rt:clientModule(client, "Client.Util.Remotes")
	rt:runIn(client, function()
		Remotes.fire(Remotes.C2S[name] or name, table.unpack(args, 1, args.n))
	end)
end
local function lobbyOf(client: any): any
	local box = client.inbox.Lobby
	return box and box.last and box.last[1]
end

T.describe("RuntimeLobbyVote", function()
	step("solo: no vote block (the single player's pick, as before)", function()
		playerA, clientA = rt:addPlayer({ userId = A_ID, name = "Alpha" })
		rt:advance(4)
		local lobby = lobbyOf(clientA)
		T.truthy(lobby, "lobby view")
		T.eq(lobby.vote, nil, "no vote with one player")
	end)

	step("2 players vote different tiers: votes, tallies, winner (tie -> lower)", function()
		playerB, clientB = rt:addPlayer({ userId = B_ID, name = "Bravo" })
		rt:advance(4)
		fire(clientA, "SetTier", 2) -- Medium
		fire(clientB, "SetTier", 1) -- Mild
		fire(clientB, "SetPace", "fast") -- a rookie: refused, never counted
		rt:advance(2)
		local lobby = lobbyOf(clientA)
		T.truthy(lobby and type(lobby.vote) == "table", "vote block with 2 players")
		T.eq(lobby.vote.tierTallies["2"], 1)
		T.eq(lobby.vote.tierTallies["1"], 1)
		T.eq(lobby.vote.tier, 1, "1-1 tie: the lower tier")
		T.eq(lobby.tier, 1, "the lobby tier is the vote winner")
		T.eq(lobby.vote.yourTier, 2, "A's own vote")
		T.eq(lobby.players[tostring(A_ID)].tierVote, 2)
		T.eq(lobby.players[tostring(B_ID)].tierVote, 1)
		T.eq(lobby.players[tostring(B_ID)].paceVote, nil, "a rookie's Fast vote does not count")
		T.eq(lobby.vote.pace, "normal")
		-- A switches to Mild: 2-0
		fire(clientA, "SetTier", 1)
		rt:advance(2)
		lobby = lobbyOf(clientB)
		T.eq(lobby.vote.tierTallies["1"], 2)
		T.eq(lobby.vote.tier, 1)
		-- B switches to Medium: 1-1 again, still the lower tier
		fire(clientB, "SetTier", 2)
		rt:advance(2)
		lobby = lobbyOf(clientA)
		T.eq(lobby.vote.tier, 1)
		rt:assertClean(nil, "vote")
	end)

	step("first READY -> 60 s countdown; everyone READY -> start now on the voted tier", function()
		fire(clientA, "SetReady", true)
		rt:advance(2)
		local lobby = lobbyOf(clientB)
		T.truthy(lobby.startsAt ~= nil, "a countdown runs")
		T.eq(lobby.countdownKind, "ready")
		T.truthy(lobby.countdown >= 55 and lobby.countdown <= 60, "about 60 s: " .. tostring(lobby.countdown))
		local LadderUIText = rt:runIn(clientB, function()
			for _, d in rt:playerGui(clientB):GetDescendants() do
				if d:IsA("TextLabel") and string.find(d.Text, "Starting in", 1, true) then
					return d.Text
				end
			end
			return nil
		end)
		T.truthy(LadderUIText ~= nil, "the lobby shows the countdown")
		rt:advance(10)
		T.eq(RD.getPhase(), "Lobby", "still counting down")
		local t0 = rt.S.now
		fire(clientB, "SetReady", true)
		local started = rt:runUntil(function()
			return RD.getPhase() ~= "Lobby"
		end, 10)
		T.truthy(started, "started")
		T.truthy(rt.S.now - t0 <= 2.5, string.format("at once (%.2f s)", rt.S.now - t0))
		local played = rt:runUntil(function()
			local m = clientA.inbox.Match and clientA.inbox.Match.last[1]
			return m ~= nil and m.tier ~= nil
		end, 30)
		T.truthy(played, "Match payload")
		T.eq(clientA.inbox.Match.last[1].tier, 1, "the match plays the voted tier (Mild)")
		rt:assertClean(nil, "start")
	end)

	step("teardown is clean", function()
		rt:removePlayer(playerA)
		rt:removePlayer(playerB)
		rt:advance(5)
		rt:assertClean(nil, "teardown")
	end)
end)

return T.finish()
