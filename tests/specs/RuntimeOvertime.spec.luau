-- Runtime emulator, iteration 5 #6 Overtime (real server + client scripts): one
-- player plays all 4 stages (Stay at every gate), the final Rind Gate offers
-- {"Extract", "Overtime"}, the player picks Overtime, survives 2 scaling waves
-- (S2C Overtime for the HUD), extracts, and Results + the profile carry the
-- Overtime record (stats.overtimeBest) and the lifetime stats (iter 5 #8).
-- Zero script errors, gaps or unexpected warnings.
-- Sturdy setup (the flow is under test, not the balance): the player's squad has
-- x20 HP on top of Driver.powerUp, the walker follows the Melt, and the player
-- picks the Mild tier (SetTier 1) before READY. Route curses that a bot squad may
-- pick (High: Glass Elephants = any hit downs, Avalanche rocks) are stripped from
-- the World mods here (test knob on the server's MatchState table; src untouched).
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")
local Driver = require("../runtime/Driver")

local USER_ID = 616161
local rt = Runtime.new({ root = ".", dt = 1 / 30 })
rt:startServer()
local RD = rt:serverModule("ServerScriptService.Server.Services.RunDirector")
RD.WAVE_SECONDS = 20
RD.OVERTIME_WAVE_SECONDS = 8
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

local MatchState = rt:serverModule("ReplicatedStorage.Shared.Run.MatchState")
local seenCurses: { string } = {}
do
	local original = MatchState.worldMods
	MatchState.worldMods = function(self, ...)
		local mods = original(self, ...)
		if type(mods) ~= "table" then
			return mods
		end
		local copy = table.clone(mods)
		copy.oneHitKO = false
		copy.fallingRocks = false
		for _, id in self.run:activeCurses() do
			if not table.find(seenCurses, tostring(id)) then
				table.insert(seenCurses, tostring(id))
			end
		end
		return copy
	end
end

local player, client, Remotes
local serverWorld: any = nil
local mySquad: number? = nil
Driver.scaleHeroHp(rt, function(_id, squad)
	return if squad ~= nil and squad == mySquad then 20 else nil
end)
local function fire(name: string, ...: any)
	local args = table.pack(...)
	rt:runIn(client, function()
		Remotes.fire(Remotes.C2S[name] or name, table.unpack(args, 1, args.n))
	end)
end

T.describe("RuntimeOvertime", function()
	step("a solo player plays the 4 stages and reaches the final gate", function()
		player, client = rt:addPlayer({ userId = USER_ID, name = "Overtimer" })
		rt:advance(4)
		Remotes = rt:clientModule(client, "Client.Util.Remotes")
		Driver.tapWorldEvents(rt, function(world)
			serverWorld = world
		end)
		local arena = Driver.tapArena(rt)
		rt:setWalker(
			player,
			Driver.squadWalker(
				rt,
				arena,
				function()
					local sq = player:GetAttribute("Squad")
					mySquad = if type(sq) == "number" then sq else mySquad
					return sq
				end,
				RD.getPhase,
				{
					homeDist = 90,
					zone = function()
						return if serverWorld and serverWorld.zone then serverWorld:zone() else nil
					end,
				}
			)
		)
		Driver.autoplay(rt, client, function(kind)
			if kind == "route" then
				return "risk"
			elseif kind == "extract" then
				local m = RD.getMatchState()
				return if m and m:isFinalGate() then nil else "Stay"
			elseif kind == "swap" then
				return true
			end
			return nil
		end)
		fire("SetTier", 1) -- Mild
		rt:advance(1)
		rt:click(client, Driver.findButton(rt, client, "TrunkfallLobby", "READY"))
		local reached = rt:runUntil(function()
			local m = RD.getMatchState()
			return (m ~= nil and m:isFinalGate()) or client.inbox.Results ~= nil
		end, 900)
		T.truthy(reached, "final gate or Results (phase " .. RD.getPhase() .. ")")
		local m = RD.getMatchState()
		local early = client.inbox.Results and client.inbox.Results.last[1]
		T.truthy(
			m and m:isFinalGate(),
			"the squad survived to the final gate"
				.. (
					if early
						then string.format(
							" (Results: %s at stage %s; curses %s)",
							tostring(early.result),
							tostring(early.stage),
							table.concat(seenCurses, ",")
						)
						else ""
				)
		)
		rt:advance(0.5)
		local ex = client.inbox.Extract and client.inbox.Extract.last[1]
		T.truthy(ex and ex.final == true, "the Extract payload marks the final gate")
		T.eq(table.concat(ex.options, ","), "Extract,Overtime")
	end)

	step("Overtime: scaling waves, S2C Overtime, extract keeps the bonus", function()
		fire("ExtractVote", "Overtime")
		local inOt = rt:runUntil(function()
			return RD.getPhase() == "Overtime"
		end, 30)
		T.truthy(inOt, "phase Overtime (now " .. RD.getPhase() .. ")")
		local two = rt:runUntil(function()
			local m = RD.getMatchState()
			return (m and (m:overtimeWave() or 0) >= 2) or RD.getPhase() ~= "Overtime"
		end, 60)
		T.truthy(two, "two Overtime waves")
		local ot = client.inbox.Overtime and client.inbox.Overtime.last[1]
		T.truthy(ot and ot.active, "S2C Overtime active")
		T.truthy(RD.getPhase() == "Overtime", "still alive in Overtime")
		local waves = RD.getMatchState():overtimeWave()
		-- the "Extract now" vote (any time in Overtime); only a STANDING human's vote
		-- counts, so it is repeated until it goes through
		local lastVote = -math.huge
		local done = rt:runUntil(function()
			if client.inbox.Results ~= nil then
				return true
			end
			if rt.S.now - lastVote >= 2 then
				lastVote = rt.S.now
				fire("ExtractVote", "Extract")
			end
			return false
		end, 60)
		T.truthy(done, "Results")
		local res = client.inbox.Results.last[1]
		-- a clear: "lastHerd" when the squad was alone at the final clear
		T.truthy(res.result == "extracted" or res.result == "lastHerd", "result " .. tostring(res.result))
		T.eq(res.outcome, "Win")
		T.eq(res.overtimeWaves, waves)
		rt:runUntil(function()
			return RD.getPhase() == "Lobby"
		end, 30)
		rt:advance(8)
		local saved = rt:dataStoreValue("TrunkfallProfiles_v1", "u_" .. USER_ID)
		local st = saved and saved.data and saved.data.stats
		T.truthy(st and type(st.overtimeBest) == "table", "stats.overtimeBest saved")
		local best = 0
		for k, w in st.overtimeBest do
			T.eq(type(k), "string")
			best = math.max(best, w)
		end
		T.eq(best, waves, "the Overtime record")
		T.truthy(st.seconds > 0, "time played saved")
		local cls = saved.data.classes[res.classId]
		T.truthy(cls and (cls.seconds or 0) > 0, "class seconds saved")
		rt:assertClean(nil, "overtime")
	end)

	step("teardown is clean", function()
		rt:removePlayer(player)
		rt:advance(5)
		rt:assertClean(nil, "teardown")
	end)
end)

return T.finish()
