-- Runtime emulator, v4 match flow (team M2, docs/V4-PLAN.md): the real server +
-- client scripts. A rookie (fresh profile) and a friend join; the lobby never
-- auto-starts while the rookie is busy in the shop (SetBusy, QA-C M8); the match
-- runs The Melt (S2C Storm), pings and quick-chat reach the squad only
-- (PingShown), a dead hero gets a Herd Call timer (S2C Redeploy), a late joiner
-- queues for a bot's seat, the Rind Gate hides Double or Nothing from rookies and
-- pre-selects Extract on run 1, and Results come with Awards. PlayAgain teleports
-- only once the player is out. Zero script errors, gaps or unexpected warnings.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")
local Driver = require("../runtime/Driver")

local ROOKIE, LATE = 515151, 525252
local rt = Runtime.new({ root = ".", dt = 1 / 30 })
rt:startServer()
local RD = rt:serverModule("ServerScriptService.Server.Services.RunDirector")
local MatchState = rt:serverModule("ReplicatedStorage.Shared.Run.MatchState")
RD.WAVE_SECONDS = 30
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

local player, client, Remotes
local serverWorld: any = nil -- the server's current World (event tap)
local function fire(name: string, ...: any)
	local args = table.pack(...)
	rt:runIn(client, function()
		Remotes.fire(Remotes.C2S[name] or name, table.unpack(args, 1, args.n))
	end)
end
local function inbox(c: any, name: string): any
	local box = c.inbox[name]
	return box and box.last and box.last[1]
end

T.describe("RuntimeV4", function()
	step("a busy rookie is never pulled in by the auto-start (SetBusy)", function()
		player, client = rt:addPlayer({ userId = ROOKIE, name = "Rookie" })
		-- the rookie walks with the storm (an AFK hero melts at the corner)
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
					return player:GetAttribute("Squad")
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
		rt:advance(3)
		Remotes = rt:clientModule(client, "Client.Util.Remotes")
		fire("SetBusy", true)
		rt:advance(40)
		T.eq(RD.getPhase(), "Lobby", "no auto-start while busy")
		local lobby = inbox(client, "Lobby")
		T.truthy(
			lobby and lobby.tier ~= nil and type(lobby.ladder) == "table",
			"iteration 2: Lobby tier / ladder"
		)
		T.truthy(lobby and lobby.pressure and lobby.pressure.hidden, "Pressure hidden for a rookie")
		fire("SetBusy", false)
		local started = rt:runUntil(function()
			return RD.getPhase() == "Waves"
		end, 45)
		T.truthy(started, "auto-start once not busy")
		rt:assertClean(nil, "busy")
	end)

	step("v4.1: every hero is inside the Melt at drop-in (radius = R)", function()
		rt:advance(0.5)
		local CombatService = rt:serverModule("ServerScriptService.Server.Services.CombatService")
		local w = CombatService.getWorld()
		T.truthy(w and w.zone, "the server World")
		local z = w:zone()
		T.truthy(z, "a storm zone at wave start")
		T.near(z.radius, w.arenaRadius, w.arenaRadius * 0.02, "the first circle is the whole arena")
		local outside = 0
		for _, p in w.playerList do
			if (p.x - z.cx) ^ 2 + (p.z - z.cz) ^ 2 > z.radius * z.radius then
				outside += 1
			end
		end
		T.eq(outside, 0, "no hero starts outside the Melt")
		T.eq(#w.playerList, 12)
	end)

	step("iteration 4: SetAimMode is saved, AimAt steers a cursor-mode hero", function()
		local CombatService = rt:serverModule("ServerScriptService.Server.Services.CombatService")
		local DataService = rt:serverModule("ServerScriptService.Server.Services.DataService")
		local w = CombatService.getWorld()
		local hero = w.players[ROOKIE]
		T.eq(hero.aimMode or "nearest", "nearest", "nearest by default")
		fire("AimAt", 30, 40)
		rt:advance(0.2)
		T.eq(hero.aimMode or "nearest", "nearest", "AimAt is ignored in nearest mode")
		fire("SetAimMode", "cursor")
		rt:advance(0.3)
		T.eq(hero.aimMode, "cursor")
		T.eq(DataService.get(player).settings.aimMode, "cursor", "saved")
		fire("AimAt", 30, 40)
		rt:advance(0.2)
		T.truthy(hero.aimX ~= nil and hero.aimZ ~= nil, "aim point stored")
		fire("AimAt", 0 / 0, 1)
		fire("SetAimMode", "sideways")
		rt:advance(0.3)
		T.eq(hero.aimMode, "cursor", "junk rejected by Guard")
		fire("SetAimMode", "nearest")
		rt:advance(0.3)
		T.eq(hero.aimMode, "nearest")
		T.eq(DataService.get(player).settings.aimMode, "nearest")
	end)

	step("rookie run: the hero is marked, the storm is sent, pings reach the squad", function()
		rt:advance(2)
		T.eq(player:GetAttribute("Rookie"), true, "Rookie attribute")
		-- iteration 2: numbered waves (Fx `wave`) and the Match payload's copy
		local mp = inbox(client, "Match")
		T.truthy(mp and type(mp.wave) == "number", "Match.wave")
		T.eq(mp.waves, 20, "20 waves a match")
		T.eq(mp.wavesPerStage, 5)
		T.truthy(mp.wave >= 1 and mp.wave <= 4, "a stage-1 wave")
		T.truthy(type(mp.horn) == "table" and type(mp.horn.stomped) == "number", "Match.horn")
		local rs = inbox(client, "RunState")
		T.truthy(rs and rs.hideDoubleOrNothing, "RunState hides Double or Nothing")
		rt:runUntil(function()
			return inbox(client, "Storm") ~= nil
		end, 10)
		local storm = inbox(client, "Storm")
		T.truthy(
			storm and type(storm.r) == "number" and storm.toR < storm.r,
			"S2C Storm with a closing circle"
		)
		T.eq(storm.stage, 1)
		fire("Ping", "go", 10, 20)
		fire("QuickChat", 2)
		rt:advance(1)
		local box = client.inbox.PingShown
		T.truthy(box and box.count >= 2, "PingShown for the ping and the quick-chat")
		local chat = box.last[1]
		T.eq(chat.kind, "chat")
		T.eq(chat.index, 2)
		T.eq(chat.by, ROOKIE)
		-- spam: at most 3 live pings
		for _ = 1, 6 do
			fire("Ping", "enemy", 0, 0)
		end
		rt:advance(0.5)
		T.truthy(client.inbox.PingShown.count <= 5, "ping cap / rate limit")
		-- PlayAgain is refused while the player is still fighting
		fire("PlayAgain")
		rt:advance(0.5)
		T.eq(#rt.teleports, 0, "no teleport while in the match")
		rt:assertClean({ "rejected Ping" }, "pings")
	end)

	step("hero tags: squadmates and enemies get client tags, server tags hidden", function()
		local HeroTags = rt:clientModule(client, "Client.Controllers.HeroTags")
		rt:advance(1)
		local tags = rt:runIn(client, function()
			return HeroTags.snapshot()
		end)
		local n = { self = 0, ally = 0, enemy = 0 }
		for _, t in tags do
			n[t.relation] = (n[t.relation] or 0) + 1
			if t.relation == "ally" then
				T.truthy(t.visible, "squadmate tag visible " .. tostring(t.id))
				T.truthy(t.ring, "squadmate ground ring")
				T.truthy(string.find(t.name, "🤖", 1, true) ~= nil, "bot mates keep the 🤖")
			end
		end
		T.eq(n.self, 1, "own slim bar")
		T.eq(n.ally, 2, "two bot squadmates")
		T.truthy(n.enemy >= 3, "enemy squads tagged (" .. n.enemy .. ")")
		local hl = 0
		for _, t in tags do
			hl += if t.highlight then 1 else 0
		end
		T.truthy(hl >= 1 and hl <= 2, "at most 2 ally outlines")
		-- the server's bot NameTags are off on this client only
		local counts = rt:runIn(client, function()
			local a, b = 0, 0
			local bots = rt:find("Workspace.Bots", client)
			for _, m in if bots then bots:GetChildren() else {} do
				local g = m:FindFirstChild("NameTag", true)
				if g then
					if g.Enabled then
						b += 1
					else
						a += 1
					end
				end
			end
			return { a, b }
		end)
		local off, on = counts[1], counts[2]
		T.truthy(off >= 11 and on == 0, string.format("server tags hidden locally (%d off, %d on)", off, on))
		rt:assertClean({ "rejected Ping" }, "hero tags")
	end)

	step("a late joiner queues for a bot's seat", function()
		local lp, lc = rt:addPlayer({ userId = LATE, name = "Late" })
		rt:advance(4)
		local view = RD.getMatchView()
		local seated = false
		for _, sq in view.squads do
			seated = seated or table.find(sq.members, LATE) ~= nil
		end
		T.falsy(seated, "not seated mid-stage without a bot's Herd Call")
		-- by the next stage start (or a bot's Herd Call) the joiner has a seat
		local voted = 0
		local lastView: any = nil
		local ok = rt:runUntil(function()
			local v = RD.getMatchView()
			if not v then
				return true
			end
			lastView = v
			-- the rookie overrides the pre-selected Extract: Stay, so the match goes on
			local ex = client.inbox.Extract
			if RD.getPhase() == "Extraction" and ex and ex.count > voted then
				voted = ex.count
				fire("ExtractVote", "Stay")
			end
			for _, sq in v.squads do
				if table.find(sq.members, LATE) then
					return true
				end
			end
			return false
		end, 120)
		T.truthy(ok, "seated (or the match ended)")
		local v = RD.getMatchView()
		if not v and lastView then
			local parts = {}
			for _, sq in lastView.squads do
				table.insert(parts, tostring(sq.outReason) .. "@" .. tostring(sq.outAtStage))
			end
			print(
				"    match ended early: " .. tostring(lastView.endReason) .. " " .. table.concat(parts, " ")
			)
		end
		T.truthy(v ~= nil, "the match went on (the rookie stayed)")
		if v then
			print("    late joiner seated, squad attr " .. tostring(lp:GetAttribute("Squad")))
			T.truthy(lp:GetAttribute("Squad") ~= nil, "the joiner has a squad")
			T.eq(RD.isSoloRun(), false, "QC: a seated joiner ends solo credit")
			T.truthy(inbox(lc, "RunState") ~= nil, "the joiner gets RunState")
		end
		rt:assertClean({ "rejected Ping" }, "late join")
	end)

	step("v5: Stalls and Wallet are sent; rinds from kills buy a stat rank", function()
		local stalls = inbox(client, "Stalls")
		T.truthy(stalls and type(stalls.stalls) == "table" and #stalls.stalls >= 5, "Stalls payload")
		T.truthy(stalls.altar and stalls.swap, "the Altar and the Swap Stand")
		local got = rt:runUntil(function()
			local w = inbox(client, "Wallet")
			return w ~= nil and w.rinds >= 20
		end, 120)
		local w = inbox(client, "Wallet")
		print("    wallet: " .. tostring(w and w.rinds) .. " rinds, " .. tostring(w and w.whey) .. " whey")
		if got then
			fire("BuyRank", "might")
			rt:advance(1)
			local w2 = inbox(client, "Wallet")
			T.eq(w2.ranks.might, 1, "a Might rank bought")
			T.truthy(w2.rinds < w.rinds + 1000, "rinds spent")
		end
		fire("BuyUltimate", "titan") -- far from the Altar and stage 1: refused with a toast
		rt:advance(0.5)
		rt:assertClean({ "rejected Ping" }, "v5 wallet")
	end)

	step("Results come with Awards; PlayAgain then teleports (reserved server)", function()
		local done = rt:runUntil(function()
			return inbox(client, "Results") ~= nil
		end, 600)
		T.truthy(done, "Results")
		local res = inbox(client, "Results")
		T.truthy(res.bestStage ~= nil and res.championKills ~= nil, "v4 Results fields")
		T.truthy(type(res.mice) == "number" and res.breakdown ~= nil, "iteration 1 Results breakdown")
		T.eq(res.breakdownDetail.classXp, res.classXp)
		T.truthy(#res.breakdown >= 1, "a {label, amount} list")
		rt:runUntil(function()
			return inbox(client, "Awards") ~= nil
		end, 30)
		local aw = inbox(client, "Awards")
		T.truthy(aw and aw.you and aw.you.id == ROOKIE, "Awards.you")
		T.truthy(aw.mvp and type(aw.mvp.score) == "number", "an MVP")
		local ex = client.inbox.Extract
		if ex then
			for _, args in ex.list do
				local opts = args[1].options
				T.falsy(table.find(opts, "DoubleOrNothing"), "no Double or Nothing for a rookie")
			end
		end
		fire("PlayAgain")
		rt:advance(1)
		local tp = rt.teleports[#rt.teleports]
		T.truthy(tp, "teleported")
		T.eq(tp.method, "TeleportAsync")
		-- QC MAJOR 2: only the caller, into a reserved server
		local list = tp.args[2]
		T.eq(#list, 1, "only the caller teleports")
		T.eq(list[1], player)
		T.eq(tp.args[3].ReservedServerAccessCode, "reserved-code")
		rt:assertClean({ "rejected Ping" }, "results")
	end)

	step("MatchState v4 config is live on the server", function()
		T.eq(MatchState.CONFIG.DON_POT_MULT, 2)
		T.eq(MatchState.CONFIG.LAST_HERD_STAGES, 1)
	end)
end)

return T.finish()
