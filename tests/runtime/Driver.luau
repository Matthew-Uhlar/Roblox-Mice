-- Scenario helpers: a scripted "player" that clicks the real client UI
-- (READY, vote cards, upgrade cards) and walks its character, plus test-only
-- knobs that speed a run up. Everything here lives in tests/, never in src/.

local roblox = require("@lune/roblox")
local Inst = require("./Instance")

local D = Inst.D
local rawGet = Inst.rawGet

local Driver = {}

-- First on-screen GuiButton under PlayerGui[screenName] whose text (or a label
-- inside it) contains `pattern` (plain find, case-insensitive). nil pattern = any.
-- exact = true: a text must EQUAL `pattern` (case-insensitive), e.g. a card title.
function Driver.findButton(rt: any, client: any, screenName: string, pattern: string?, exact: boolean?): any
	local gui = rt:playerGui(client)
	local screen = gui and Inst.findVisibleChild(D[gui], screenName, client)
	if not screen then
		return nil
	end
	local S = rt.S
	local prev = S.current
	S.current = client
	local found = nil
	for _, x in screen:GetDescendants() do
		local d = D[x]
		if d.cls.isA.GuiButton and rt:isShown(x) then
			if pattern == nil then
				found = x
				break
			end
			local texts = {}
			if d.cls.props.Text then
				table.insert(texts, rawGet(d, "Text"))
			end
			for _, y in x:GetDescendants() do
				local yd = D[y]
				if yd.cls.props.Text then
					table.insert(texts, rawGet(yd, "Text"))
				end
			end
			for _, t in texts do
				local hit = if exact
					then string.lower(t) == string.lower(pattern)
					else string.find(string.lower(t), string.lower(pattern), 1, true) ~= nil
				if hit then
					found = x
					break
				end
			end
			if found then
				break
			end
		end
	end
	S.current = prev
	return found
end

-- Autoplay: every 0.3 s the scripted player answers whatever the UI shows:
--   * upgrade cards: the first card with a rarity band (TrunkfallUpgrades);
--   * route votes: policy("route", options) -> text of the card to click
--     (TrunkfallVote). v2: VoteOpen kind "route" only reaches the squad that won
--     the boss, so most stages show no route vote at all;
--   * the extraction window: policy("extract", options) -> "Extract" | "Stay" |
--     "DoubleOrNothing". The card with that title is clicked in TrunkfallExtract
--     (ExtractUI -> State.castExtract -> Net.C2S.ExtractVote(choice: string)). If
--     the card is not on screen the driver calls State.castExtract itself, which
--     sends the same remote, and counts it in log.extractFallbacks;
--   * gear swap prompts: policy("swap", {item, current}) -> true (take) / false
--     (keep) / nil (let it time out), through State.answerSwap (Net.C2S.SwapGear).
-- log = { picks, votes = {text}, voteKinds = {kind}, extracts = {choice},
--         extractStages = {stage}, extractFallbacks, swaps }
local EXTRACT_TITLE = { Extract = "Extract", Stay = "Stay", DoubleOrNothing = "Double or Nothing" }
Driver.EXTRACT_TITLE = EXTRACT_TITLE

function Driver.autoplay(rt: any, client: any, policy: (kind: string, options: any) -> any)
	local State = nil
	local log = {
		picks = 0,
		votes = {},
		voteKinds = {},
		extracts = {},
		extractStages = {},
		extractFallbacks = 0,
		swaps = 0,
	}
	local lastVote = nil
	local lastExtract = nil
	local lastSwap = nil
	local nextAt = 0
	table.insert(rt.S.frameHooks, function(_dt, phase)
		if phase ~= "post" or client.dead or rt.S.now < nextAt then
			return
		end
		nextAt = rt.S.now + 0.3
		if not State then
			local ok, mod = pcall(rt.clientModule, rt, client, "Client.Controllers.State")
			if not ok then
				return -- client not booted yet
			end
			State = mod
		end
		-- upgrade offer on screen?
		local card = Driver.findButton(rt, client, "TrunkfallUpgrades", nil)
		if card then
			-- skip reroll/close buttons: upgrade cards contain a rarity band label
			local pick = Driver.findButton(rt, client, "TrunkfallUpgrades", "common")
				or Driver.findButton(rt, client, "TrunkfallUpgrades", "rare")
				or Driver.findButton(rt, client, "TrunkfallUpgrades", "epic")
				or Driver.findButton(rt, client, "TrunkfallUpgrades", "legendary")
				or Driver.findButton(rt, client, "TrunkfallUpgrades", "uncommon")
			if pick then
				rt:click(client, pick)
				log.picks += 1
			end
		end
		local vote = State.get("vote")
		if type(vote) == "table" and not vote.closed and vote ~= lastVote then
			local text = policy(tostring(vote.kind), vote.options)
			local b = if type(text) == "string"
				then Driver.findButton(rt, client, "TrunkfallVote", text)
				else nil
			if b then
				rt:click(client, b)
				lastVote = vote
				table.insert(log.votes, text)
				table.insert(log.voteKinds, vote.kind)
			end
		end
		local ex = State.get("extract")
		if type(ex) == "table" and not ex.closed and ex.endsAt ~= lastExtract then
			local choice = policy("extract", ex.options)
			if type(choice) == "string" and EXTRACT_TITLE[choice] then
				local b = Driver.findButton(rt, client, "TrunkfallExtract", EXTRACT_TITLE[choice], true)
				if b then
					rt:click(client, b)
				else
					log.extractFallbacks += 1
					rt:runIn(client, function()
						State.castExtract(choice)
					end)
				end
				lastExtract = ex.endsAt
				local match = State.get("match")
				table.insert(log.extracts, choice)
				table.insert(log.extractStages, if type(match) == "table" then match.stage else nil)
			end
		end
		local inv = State.get("inventory")
		local offer = if type(inv) == "table" then inv.swapOffer else nil
		if type(offer) == "table" and offer ~= lastSwap and type(State.answerSwap) == "function" then
			local take = policy("swap", offer)
			if take ~= nil then
				lastSwap = offer
				rt:runIn(client, function()
					State.answerSwap(take == true)
				end)
				log.swaps += 1
			end
		end
	end)
	return log
end

-- Walks the character in a circle around the arena (or stands in the lobby).
function Driver.circleWalker(rt: any, radius: number, period: number)
	return function(now: number, _pos: any)
		local arena = rt.workspace:FindFirstChild("Arena")
		if not arena then
			return nil
		end
		local c = arena:GetPivot().Position
		local a = (now / period) * math.pi * 2
		return roblox.Vector3.new(c.X + math.cos(a) * radius, c.Y, c.Z + math.sin(a) * radius)
	end
end

-- READ-ONLY TAP: records the last ArenaBuilder.build result of the SERVER
-- context (radius, center, squadSpawns, safeZones). rec.info, rec.builds.
function Driver.tapArena(rt: any)
	local AB = rt:serverModule("ServerScriptService.Server.Services.ArenaBuilder")
	local original = AB.build
	local rec = { info = nil, builds = 0 }
	AB.build = function(...)
		local info = original(...)
		rec.info = info
		rec.builds += 1
		return info
	end
	return rec
end

-- A walker that plays like a cautious human: during the boss it circles the
-- centre (`bossRadius`, to fight for the kill), otherwise it patrols a small
-- circle inside its own squad's safe corner. `squadOf()` returns the walker's
-- squad; `phaseOf()` the server phase. Falls back to the arena centre circle.
function Driver.squadWalker(
	rt: any,
	arenaRec: any,
	squadOf: () -> number?,
	phaseOf: () -> string,
	opts: { [string]: number }?
)
	local o = opts or {}
	local bossRadius, cornerRadius, period = o.bossRadius or 16, o.cornerRadius or 8, o.period or 9
	return function(now: number, _pos: any)
		local arena = rt.workspace:FindFirstChild("Arena")
		local info = arenaRec.info
		if not arena or not info then
			return nil
		end
		local c = info.center or arena:GetPivot().Position
		local a = (now / period) * math.pi * 2
		local zone = info.safeZones and info.safeZones[squadOf() or 0]
		if phaseOf() == "Boss" or not zone then
			return roblox.Vector3.new(c.X + math.cos(a) * bossRadius, c.Y, c.Z + math.sin(a) * bossRadius)
		end
		local r = math.min(cornerRadius, (zone.r or cornerRadius) * 0.6)
		return roblox.Vector3.new(zone.x + math.cos(a) * r, c.Y, zone.z + math.sin(a) * r)
	end
end

-- READ-ONLY TAP: wraps the SERVER context's World.drainEvents so a spec sees
-- every combat event the server consumes (the events are passed on unchanged).
-- Counts PvP hits ("damaged" with a hero `by`) split into enemy-squad and
-- same-squad hits (friendly fire must be 0), downs, kills, eliminations, loot
-- bag drops (World.addLootBag) and pickups, and gear pickups. rec.events keeps the last 400 PvP-relevant events.
function Driver.tapWorldEvents(rt: any, onEvent: ((world: any, e: any) -> ())?)
	local World = rt:serverModule("ReplicatedStorage.Shared.Combat.World")
	local original = World.drainEvents
	local rec = {
		pvpHits = 0,
		pvpDamage = 0,
		friendlyHits = 0,
		downs = 0,
		pvpDowns = 0,
		kills = 0,
		pvpKills = 0,
		eliminations = 0,
		eliminatedSquads = {},
		bagDrops = 0, -- world:addLootBag calls (RunDirector drops a killed hero's bag)
		bagPickups = 0, -- "lootBag" events (a bag was channelled and claimed)
		gearPickups = 0,
		humanGear = 0,
		events = {},
	}
	local function keep(e: any)
		table.insert(rec.events, e)
		if #rec.events > 400 then
			table.remove(rec.events, 1)
		end
	end
	World.drainEvents = function(self, ...)
		local events = original(self, ...)
		for _, e in events do
			local t = e.type
			local bySquad = if type(e.by) == "number" then self:squadOf(e.by) else nil
			local victimSquad = if type(e.id) == "number" then self:squadOf(e.id) else nil
			if t == "damaged" and bySquad ~= nil and e.by ~= e.id then
				if bySquad == victimSquad then
					rec.friendlyHits += 1
					keep(e)
				else
					rec.pvpHits += 1
					rec.pvpDamage += tonumber(e.amount) or 0
				end
			elseif t == "heroDowned" then
				rec.downs += 1
				if bySquad and bySquad ~= victimSquad then
					rec.pvpDowns += 1
				end
				keep(e)
			elseif t == "heroKilled" then
				rec.kills += 1
				if bySquad and bySquad ~= victimSquad then
					rec.pvpKills += 1
				end
				keep(e)
			elseif t == "squadEliminated" then
				rec.eliminations += 1
				table.insert(rec.eliminatedSquads, e.squad)
				keep(e)
			elseif t == "lootBag" then
				rec.bagPickups += 1
				keep(e)
			elseif t == "gearPickup" then
				rec.gearPickups += 1
				if type(e.id) == "number" and e.id > 0 then
					rec.humanGear += 1
				end
			end
			if onEvent then
				onEvent(self, e)
			end
		end
		return events
	end
	local originalBag = World.addLootBag
	World.addLootBag = function(self, ...)
		rec.bagDrops += 1
		return originalBag(self, ...)
	end
	rec.restore = function()
		World.drainEvents = original
		World.addLootBag = originalBag
	end
	return rec
end

-- TEST-ONLY KNOB: wraps the SERVER context's Stats.compute so every hero (the
-- test player and the bots) deals `mult`x damage and has `mult`x max HP. It
-- patches the module table the server scripts already required; src/ is untouched.
function Driver.powerUp(rt: any, mult: number)
	local Stats = rt:serverModule("ReplicatedStorage.Shared.Run.Stats")
	local original = Stats.compute
	Stats.compute = function(...)
		local stats, weapon, ability = original(...)
		stats.damageMult = (stats.damageMult or 1) * mult
		stats.maxHp = (stats.maxHp or 100) * mult
		return stats, weapon, ability
	end
	return function()
		Stats.compute = original
	end
end

-- TEST-ONLY KNOB: scales the max HP of chosen heroes in the SERVER context's
-- World (wraps World.addPlayer / updatePlayer; the stats table is copied).
-- `hpMult(id, squad) -> number?` (nil = unchanged). Used to make one squad
-- fragile so an elimination happens through the real code path.
function Driver.scaleHeroHp(rt: any, hpMult: (id: number, squad: number?) -> number?)
	local World = rt:serverModule("ReplicatedStorage.Shared.Combat.World")
	local add, upd = World.addPlayer, World.updatePlayer
	local function scaled(id: number, squad: number?, stats: any): any
		local m = hpMult(id, squad)
		if type(stats) ~= "table" or type(m) ~= "number" then
			return stats
		end
		local copy = table.clone(stats)
		copy.maxHp = (copy.maxHp or 100) * m
		return copy
	end
	World.addPlayer = function(self, id, stats, weapon, ability, x, z, squad, ...)
		return add(self, id, scaled(id, squad, stats), weapon, ability, x, z, squad, ...)
	end
	World.updatePlayer = function(self, id, stats, ...)
		return upd(self, id, scaled(id, self:squadOf(id), stats), ...)
	end
	return function()
		World.addPlayer, World.updatePlayer = add, upd
	end
end

return Driver
