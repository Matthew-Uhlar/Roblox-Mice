local Runtime = require("../runtime/Runtime")
local Driver = require("../runtime/Driver")
local rt = Runtime.new({ root = ".", dt = 1 / 30 })
rt:startServer()
local RD = rt:serverModule("ServerScriptService.Server.Services.RunDirector")
RD.WAVE_SECONDS = 20
Driver.powerUp(rt, 25)
rt:advance(1)
local player, client = rt:addPlayer({ userId = 424242, name = "Solo" })
rt:advance(4)
print("JOIN REPORT\n" .. rt:report())
local log = Driver.autoplay(rt, client, function(kind)
	if kind == "route" then return "risk" elseif kind == "extract" then return "Stay" end
	return nil
end)
rt:setWalker(player, Driver.circleWalker(rt, 18, 10))
rt:click(client, Driver.findButton(rt, client, "TrunkfallLobby", "READY"))
local phases, last = {}, nil
table.insert(rt.S.frameHooks, function(_, ph)
	if ph ~= "post" then return end
	local p = RD.getPhase()
	if p ~= last then table.insert(phases, string.format("%.0f:%s", rt.S.now, p)); last = p end
end)
local t0 = os.clock()
rt:runUntil(function() return client.inbox.Results ~= nil end, 900)
print("phases", table.concat(phases, " "))
print("wall", os.clock() - t0)
print("votes", table.concat(log.voteKinds, ","), "extracts", table.concat(log.extracts, ","), "fallbacks", log.extractFallbacks, "picks", log.picks, "swaps", log.swaps)
if client.inbox.Results then for k, v in client.inbox.Results.last[1] do print(" res", k, v) end end
local ts = rt:terrainStats()
print("terrain fills", ts.fills, "solid", ts.solidFills, "air", ts.airFills, "maxVox", ts.maxVoxels, "colors", ts.colorSets)
print("REPORT\n" .. rt:report())
