-- Runtime emulator, scenario (e): the only human leaves mid-run. Stage 1 is won
-- (pending cheese), the party votes Continue, and the player leaves during stage 2
-- waves. DataService.beforeRelease pays the wipe-rule payout (RunDirector.payLeaver)
-- before the final save, the run ends cleanly (bots never hold a run open), the
-- lobby is idle again, and nothing errors.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")
local Driver = require("../runtime/Driver")

local USER_ID = 31337
local rt = Runtime.new({ root = ".", dt = 1 / 30 })
rt:startServer()
local RD = rt:serverModule("ServerScriptService.Server.Services.RunDirector")
RD.WAVE_SECONDS = 15
Driver.powerUp(rt, 25)
rt:advance(1)

T.describe("RuntimeLeave", function()
	local player, client
	local cheeseBefore = 0
	T.it("plays stage 1 and continues into stage 2", function()
		player, client = rt:addPlayer({ userId = USER_ID, name = "Leaver" })
		rt:advance(4)
		local saved = rt:dataStoreValue("TrunkfallProfiles_v1", "u_" .. USER_ID)
		cheeseBefore = if saved and saved.data then saved.data.cheese else 0
		Driver.autoplay(rt, client, function(kind)
			if kind == "route" then
				return "risk"
			elseif kind == "bank" then
				return "Continue"
			end
			return nil
		end)
		rt:setWalker(player, Driver.circleWalker(rt, 18, 10))
		rt:click(client, Driver.findButton(rt, client, "TrunkfallLobby", "READY"))
		local stage2 = rt:runUntil(function()
			local pub = client.inbox.RunState and client.inbox.RunState.last[1]
			return RD.getPhase() == "Waves" and pub and pub.stageInCycle == 2
		end, 200)
		T.truthy(stage2, "stage 2 waves (phase " .. RD.getPhase() .. ")")
		rt:advance(3)
		rt:assertClean(nil, "stage 2")
	end)

	T.it("leaving mid-run pays out through beforeRelease and ends the run cleanly", function()
		rt:removePlayer(player)
		local ended = rt:runUntil(function()
			return RD.getPhase() == "Lobby" and not RD.isRunning()
		end, 30)
		T.truthy(ended, "run ended (phase " .. RD.getPhase() .. ")")
		rt:advance(5)
		local saved = rt:dataStoreValue("TrunkfallProfiles_v1", "u_" .. USER_ID)
		T.truthy(saved and saved.data, "profile saved")
		T.truthy(
			saved.data.cheese > cheeseBefore,
			string.format("leave payout: cheese %d -> %d", cheeseBefore, saved.data.cheese)
		)
		T.eq(saved.lock, nil, "session lock released")
		T.eq(rt.workspace:FindFirstChild("Arena"), nil, "arena torn down")
		rt:assertClean(nil, "leave")
	end)

	T.it("the server keeps working: a new player can join and start a run", function()
		local p2, c2 = rt:addPlayer({ userId = USER_ID + 1, name = "Next" })
		rt:advance(4)
		rt:setWalker(p2, Driver.circleWalker(rt, 18, 10))
		rt:click(c2, Driver.findButton(rt, c2, "TrunkfallLobby", "READY"))
		T.truthy(
			rt:runUntil(function()
				return RD.getPhase() == "Waves"
			end, 40),
			"second run started"
		)
		rt:advance(2)
		rt:assertClean(nil, "second run")
	end)

	T.it("server shutdown (BindToClose) saves and releases every session", function()
		T.truthy(rt:shutdown(30), "BindToClose callbacks finished")
		local saved = rt:dataStoreValue("TrunkfallProfiles_v1", "u_" .. (USER_ID + 1))
		T.truthy(saved and saved.data, "saved")
		T.eq(saved.lock, nil, "lock released on shutdown")
		rt:assertClean(nil, "shutdown")
	end)
end)

return T.finish()
