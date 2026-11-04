-- R1 scratch: drive the real server scripts through a whole squad match (not a spec).
local Runtime = require("../runtime/Runtime")
local Driver = require("../runtime/Driver")
local rt = Runtime.new({ root = ".", dt = 1 / 30 })
rt:startServer()
local RD = rt:serverModule("ServerScriptService.Server.Services.RunDirector")
RD.WAVE_SECONDS = 12
RD.BOSS_SECONDS = 25
RD.EXTRACT_SECONDS = 5
RD.VOTE_SECONDS = 4
Driver.powerUp(rt, 25)
rt:advance(1)
local player, client = rt:addPlayer({ userId = 424242, name = "Solo" })
rt:advance(4)
local inbox = client.inbox
local mode = ...
local phases, order = {}, {}
table.insert(rt.S.frameHooks, function(_dt, phase)
	if phase ~= "post" then return end
	local p = RD.getPhase()
	if order[#order] ~= p then table.insert(order, p) end
	phases[p] = true
end)
-- Send ExtractVote via the client remote
local function fire(name, ...)
	local args = table.pack(...)
	rt:runIn(client, function()
		local r = game:GetService("ReplicatedStorage"):WaitForChild("Remotes"):WaitForChild(name)
		r:FireServer(table.unpack(args, 1, args.n))
	end)
end
rt:click(client, Driver.findButton(rt, client, "TrunkfallLobby", "READY"))
local started = rt:runUntil(function() return RD.getPhase() == "Waves" end, 40)
print("started", started)
local view = RD.getMatchView()
for i, sq in view.squads do print("squad", i, sq.name, #sq.members, sq.alive) end
local voted = {}
local done = rt:runUntil(function()
	local ph = RD.getPhase()
	local v = RD.getMatchView()
	if ph == "Extraction" and v and not voted[v.stage] then
		voted[v.stage] = true
		local choice = if mode == "extract" and v.stage == 2 then "Extract" else (if v.stage == 1 then "DoubleOrNothing" else "Stay")
		fire("ExtractVote", choice)
		print("stage", v.stage, "vote", choice)
	end
	return ph == "Lobby" and next(voted) ~= nil
end, 900)
print("done", done, table.concat(order, " > "))
for k, n in { "Match", "Extract", "KillFeed", "Results", "VoteOpen", "RunState", "Inventory" } do
	print(n, inbox[n] and inbox[n].count or 0)
end
local res = inbox.Results and inbox.Results.last
if res then
	local t = type(res) == "table" and (res[1] or res) or res
	for k, v in t do print("  results", k, v) end
end
local saved = rt:dataStoreValue("TrunkfallProfiles_v1", "u_424242")
print("saved cheese", saved and saved.data and saved.data.cheese)
print(rt:report({}))
