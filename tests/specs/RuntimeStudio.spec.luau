-- Runtime emulator, scenario (c): a Studio-style test player (UserId -1, with
-- RunService:IsStudio() true) is a HUMAN, not a bot: the lobby lists them as a
-- human next to 11 labelled bots (v2: 2 squad-mates + 3 bot squads), they get a
-- profile, and they are SEATED in the match as a human member of a squad. Bots
-- use the Ids.isBot band (<= -1001) only.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")
local Driver = require("../runtime/Driver")

local rt = Runtime.new({ root = ".", dt = 1 / 30, isStudio = true })
rt:startServer()
local RD = rt:serverModule("ServerScriptService.Server.Services.RunDirector")
local DataService = rt:serverModule("ServerScriptService.Server.Services.DataService")
rt:advance(1)

T.describe("RuntimeStudio", function()
	local player, client, State
	T.it("Player -1 joins and is listed as a human next to 11 bots", function()
		player, client = rt:addPlayer({ userId = -1, name = "Player1" })
		rt:advance(4)
		State = rt:clientModule(client, "Client.Controllers.State")
		local lobby = State.get("lobby")
		T.truthy(lobby and lobby.players, "lobby payload")
		local me = lobby.players[-1] or lobby.players["-1"]
		T.truthy(me, "entry for -1")
		T.falsy(me.isBot, "-1 is not flagged as a bot")
		T.falsy(State.isBot(-1, me), "client treats -1 as human")
		local bots = 0
		for id, e in lobby.players do
			if State.isBot(tonumber(id), e) then
				bots += 1
				T.truthy(tonumber(id) <= -1001, "bot id in the bot band: " .. id)
			end
		end
		T.eq(bots, 11, "bots")
		T.truthy(DataService.isRealPlayer(player), "DataService: real player in Studio")
		T.truthy(DataService.get(player), "profile loaded")
		rt:assertClean(nil, "studio join")
	end)

	T.it("-1 readies and starts the run as a human member", function()
		rt:setWalker(player, Driver.circleWalker(rt, 15, 10))
		rt:click(client, Driver.findButton(rt, client, "TrunkfallLobby", "READY"))
		T.truthy(
			rt:runUntil(function()
				return RD.getPhase() == "Waves"
			end, 40),
			"run started"
		)
		rt:advance(3)
		-- Seated in the match as a human (MatchState member, not a bot)
		local view = RD.getMatchView()
		local squad = nil
		for sId = 1, 4 do
			for _, id in view.squads[sId].members do
				if id == -1 then
					squad = sId
				end
			end
		end
		T.truthy(squad, "-1 is seated in a squad")
		local Match = State.get("match")
		T.truthy(type(Match) == "table", "Match payload reached -1")
		local party = State.get("party")
		T.truthy(party and party[-1], "PartyHud has -1")
		T.falsy(State.isBot(-1, party[-1]), "-1 is a human party member")
		local mates, bots = 0, 0
		for id in party do
			if id ~= -1 then
				mates += 1
				if State.isBot(id, party[id]) then
					bots += 1
				end
			end
		end
		T.eq(bots, mates, "every other PartyHud entry is a labelled bot")
		T.truthy(mates >= 2, "2 bot squad-mates")
		T.truthy(client.inbox.PlayerHud and client.inbox.PlayerHud.count > 0, "PlayerHud for -1")
		rt:assertClean(nil, "studio run")
	end)
end)

return T.finish()
