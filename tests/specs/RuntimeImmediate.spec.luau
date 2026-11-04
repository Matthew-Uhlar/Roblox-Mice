-- Runtime emulator, variant run: everything the solo scenario does, under the
-- OTHER Workspace.SignalBehavior (Immediate), with Studio "Play Solo" ordering (the
-- player exists before the server script starts), a phone client (touch only,
-- 667x375) that never presses READY (the 30 s auto-start), slow DataStores (0.5 s)
-- and a laggy connection (20 Hz replication, 150 ms + jitter, 0.5 s freezes).
-- The v2 match must reach Results, "Win" only if the squad extracted (the player
-- stays through the gates), with zero errors, gaps, unexpected warnings,
-- movement violations or DataStore queueing.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")
local Driver = require("../runtime/Driver")
local roblox = require("@lune/roblox")

local USER_ID = 8080
local rt = Runtime.new({
	root = ".",
	dt = 1 / 30,
	signalBehavior = "Immediate",
	asyncLatency = 0.5,
	netLatency = 0.15,
})
local player, client = rt:addPlayer({
	userId = USER_ID,
	name = "Phone",
	device = { touch = true, keyboard = false, mouse = false },
	viewport = roblox.Vector2.new(667, 375),
	bootDelay = 0,
	characterDelay = 0,
})
rt:startServer()
local RD = rt:serverModule("ServerScriptService.Server.Services.RunDirector")
local CombatService = rt:serverModule("ServerScriptService.Server.Services.CombatService")
RD.WAVE_SECONDS = 20
Driver.powerUp(rt, 25)

T.describe("RuntimeImmediate", function()
	T.it("boots in Play Solo order with Immediate signals on a phone", function()
		rt:advance(6)
		local State = rt:clientModule(client, "Client.Controllers.State")
		T.truthy(State.get("lobby") and State.get("profile"), "lobby and profile reached the client")
		T.truthy(client.actions.TrunkfallAbility, "ability action bound")
		T.truthy(rt:find("Players.Phone.PlayerGui.TrunkfallTouch", client), "touch controls built")
		rt:assertClean(nil, "boot")
	end)

	T.it("auto-starts and plays the match to Results under lag", function()
		-- Patrols its squad's safe corner, fights the boss at the centre.
		local arena = Driver.tapArena(rt)
		rt:setWalker(
			player,
			Driver.squadWalker(rt, arena, function()
				local v = RD.getMatchView()
				for s = 1, 4 do
					for _, id in (v and v.squads[s].members or {}) do
						if id == USER_ID then
							return s
						end
					end
				end
				return nil
			end, RD.getPhase)
		)
		rt.walkers[player].speedFactor = 1
		rt:setNetConditions(
			player,
			{ rate = 20, latency = 0.15, jitter = 0.1, freezeEvery = 12, freezeFor = 0.5, seed = 7 }
		)
		local log = Driver.autoplay(rt, client, function(kind)
			if kind == "route" then
				return "risk"
			elseif kind == "extract" then
				return "Stay"
			end
			return nil
		end)
		local violations = 0
		table.insert(rt.S.frameHooks, function()
			violations = math.max(violations, CombatService.violations(player))
		end)
		local done = rt:runUntil(function()
			return client.inbox.Results ~= nil and RD.getPhase() == "Lobby"
		end, 400)
		T.truthy(done, "run finished (phase " .. RD.getPhase() .. ")")
		local res = client.inbox.Results.last[1]
		print(
			string.format(
				"    result %s (%s) after %d stage(s)",
				tostring(res.result),
				tostring(res.outcome),
				res.stagesCleared
			)
		)
		local extracted = res.result == "extracted" or res.result == "lastHerd"
		T.eq(res.outcome, if extracted then "Win" else "Wipe", "Win only if the squad extracted")
		T.truthy(res.stagesCleared >= 1, "bosses killed")
		for _, c in log.extracts do
			T.eq(c, "Stay", "the phone voted Stay at every gate")
		end
		T.eq(log.extractFallbacks, 0, "votes through the ExtractUI cards (touch)")
		T.eq(violations, 0, "no MoveGuard false positives at 0.5 s freezes")
		T.eq(#rt.dataStoreThrottles, 0, "no DataStore queueing")
		rt:assertClean(nil, "immediate run")
	end)
end)

return T.finish()
