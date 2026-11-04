--!strict
-- Tiny client store. Holds the latest server-sent state and fires a change
-- signal per key. UIs subscribe instead of listening to remotes directly.
--
-- Keys:
--   run      PublicRunState                (Net.S2C.RunState)
--   hud      PlayerHud                     (Net.S2C.PlayerHud)
--   party    { [userId]: PartyEntry }      (Net.S2C.PartyHud, keys normalised to numbers;
--            bots have ids <= -1000, see Shared.Util.Ids; Studio test players are -1..-8)
--   profile  ProfileView                   (Net.S2C.Profile)
--   lobby    { players = { [userId]: { name, classId, ready, inRun?, isBot?, playAgain?,
--                                      sittingOut?, needsReady?, leader? } },
--              startsAt?, runActive, autoStart?, botFill?, botFillAny?, botCount?,
--              pressure = { board = {[modId]: rank}, points, leaderId?, unlocked, youUnlocked } }
--            (Net.S2C.Lobby; see State.normalisePressure)
--   vote     { kind, options, endsAt, tally, myPick, closed, winner } | nil (VoteOpen/Tally/Closed)
--   offers   { { offerId, cards, rerollsLeft, queued } } (Net.S2C.UpgradeOffer; server sends one
--            offer at a time plus `queued`, the client tolerates several)
--   results  Results payload | nil         (Net.S2C.Results)
--   boss     { id, bossId, def, hpFrac } | nil  (set by HordeRenderer from snapshots)
--
-- v2 squad PvPvE (docs/ARCHITECTURE-v2.md, Network table):
--   match      { phase, stage, squads = { Scoreboard.Squad } (by id), mySquad?, routeChooser?,
--                bounties = { [idKey]: true } }                       (Net.S2C.Match)
--   killfeed   { entries = { {killer, victim, killerSquad, victimSquad, kind, at, seq} },
--                streaks = KillStreaks }                              (Net.S2C.KillFeed)
--   inventory  { weapon?, armor?, trinket?, swapOffer? = {item, slot, endsAt} } (Net.S2C.Inventory)
--   extract    { endsAt, options, votes = {[choice]: n}, yourChoice?, closed? } | nil (Net.S2C.Extract)
--   shopCart   { poi, offers = {item}, prices = {n}, sold = {[i]: true} } | nil     (Net.S2C.ShopCart)
--   lobby.squads  { [1..4] = { id, name, color, members = {id} } }  (Net.S2C.Lobby `squads`,
--                or derived from players[id].squad)
--   profile.classes  { [classId]: {xp, level, perks, ability, skin, perkPoints?} } (Net.S2C.Profile)
--   classesAtStart   copy of profile.classes when a run starts (ResultsUI level-up animation)
--   scoreboardOpen   boolean (Tab / View / tap on the strip)

local Players = game:GetService("Players")

local Client = script.Parent.Parent
local Signal = require(Client.Util.Signal)
local Remotes = require(Client.Util.Remotes)
local Format = require(Client.Util.Format)
local Scoreboard = require(Client.Util.Scoreboard)
local KillStreaks = require(Client.Util.KillStreaks)
local Ids = require(
	game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Ids")
)

local KILLFEED_MAX = 6

local State = {}

local data: { [string]: any } = {}
local signals: { [string]: any } = {}

-- Fired for transient Toast messages: (text: string, kind: "info"|"good"|"bad")
State.toast = Signal.new()

local function signalFor(key: string): any
	local s = signals[key]
	if not s then
		s = Signal.new()
		signals[key] = s
	end
	return s
end

function State.get(key: string): any
	return data[key]
end

-- Sets a value and always notifies subscribers (tables are often mutated in place).
function State.set(key: string, value: any)
	data[key] = value
	signalFor(key):Fire(value)
end

-- Subscribes to a key. If `fireNow`, calls fn immediately with the current value.
-- Returns a disconnect function.
function State.subscribe(key: string, fn: (any) -> (), fireNow: boolean?): () -> ()
	local conn = signalFor(key):Connect(fn)
	if fireNow then
		task.spawn(fn, data[key])
	end
	return function()
		conn:Disconnect()
	end
end

function State.serverNow(): number
	return workspace:GetServerTimeNow()
end

function State.localUserId(): number
	local p = Players.LocalPlayer
	return if p then p.UserId else 0
end

function State.phase(): string?
	local run = data.run
	return if type(run) == "table" then run.phase else nil
end

-- Bot teammates (AI fill) have ids in the Ids.isBot band (<= -1000) and/or
-- `isBot = true` on their Lobby/PartyHud entry. Studio test players have small
-- negative UserIds (-1..-8) and are humans. Policy: always label bots in the UI.
function State.isBot(id: number?, entry: any): boolean
	if type(entry) == "table" and entry.isBot == true then
		return true
	end
	return Ids.isBot(id)
end

function State.inCombat(): boolean
	local p = State.phase()
	return p == "Waves" or p == "Boss"
end

function State.inLobby(): boolean
	local p = State.phase()
	return p == nil or p == "Lobby"
end

-- Ability cooldown tracking: PlayerHud only gives abilityReadyAt, so the
-- total is inferred when a new readyAt arrives.
-- ASSUMPTION: abilityReadyAt / downedUntil use workspace:GetServerTimeNow().
local cdReadyAt = 0
local cdTotal = 1

-- Returns (remainingSeconds, totalSeconds). remaining is 0 when ready.
function State.abilityCooldown(): (number, number)
	local rem = cdReadyAt - State.serverNow()
	if rem <= 0 or rem > 600 then
		return 0, cdTotal
	end
	return rem, math.max(cdTotal, rem)
end

local function onHud(hud: any)
	if type(hud) ~= "table" then
		return
	end
	local readyAt = tonumber(hud.abilityReadyAt)
	if readyAt and readyAt ~= cdReadyAt then
		local rem = readyAt - State.serverNow()
		if rem > 0.05 and rem < 600 then
			cdTotal = rem
		end
		cdReadyAt = readyAt
	end
	State.set("hud", hud)
end

-- Votes per option, tolerant of string keys from the network.
local function normaliseTally(t: any): { [number]: number }
	local out = {}
	if type(t) ~= "table" then
		return out
	end
	for k, v in t do
		local i = tonumber(k)
		if i then
			out[i] = tonumber(v) or 0
		end
	end
	return out
end

-- Local optimistic vote pick (the server tally is authoritative).
function State.castVote(option: number)
	local v = data.vote
	if type(v) ~= "table" or v.closed then
		return
	end
	v.myPick = option
	Remotes.fire(Remotes.C2S.Vote, option)
	State.set("vote", v)
end

function State.removeOffer(offerId: number)
	local q = data.offers or {}
	for i, o in q do
		if o.offerId == offerId then
			table.remove(q, i)
			break
		end
	end
	State.set("offers", q)
end

-- Lobby Pressure block (GDD §3.7), tolerant of a missing / malformed payload.
-- Ranks are display-only here; the server validates every SetPressure.
function State.normalisePressure(p: any): { [string]: any }
	local board: { [string]: number } = {}
	local points = 0
	if type(p) == "table" and type(p.board) == "table" then
		for k, v in p.board do
			local r = tonumber(v)
			if type(k) == "string" and r and r == r and r > 0 then
				board[k] = math.floor(r)
			end
		end
	end
	if type(p) == "table" then
		local n = tonumber(p.points)
		if n and n == n then
			points = math.max(0, math.floor(n))
		end
	end
	return {
		board = board,
		points = points,
		leaderId = if type(p) == "table" then tonumber(p.leaderId) else nil,
		unlocked = type(p) == "table" and p.unlocked == true,
		youUnlocked = type(p) == "table" and p.youUnlocked == true,
	}
end

-- Am I the party leader (the one who sets Pressure)?
function State.isLeader(): boolean
	local lobby = data.lobby
	return type(lobby) == "table"
		and type(lobby.pressure) == "table"
		and lobby.pressure.leaderId ~= nil
		and lobby.pressure.leaderId == State.localUserId()
end


----------------------------------------------------------------------
-- v2: squads, kill feed, gear, extraction, shop cart, class progression
----------------------------------------------------------------------

-- My squad id in the match (or the lobby before it starts), else nil.
function State.mySquad(): number?
	local m = data.match
	if type(m) == "table" and m.mySquad then
		return m.mySquad
	end
	local lobby = data.lobby
	if type(lobby) == "table" and type(lobby.squads) == "table" then
		local me = State.localUserId()
		for id, sq in lobby.squads do
			if table.find(sq.members, me) then
				return id
			end
		end
	end
	return nil
end

-- Squad id of any participant (match first, then the lobby), else nil.
function State.squadOf(id: number?): number?
	if id == nil then
		return nil
	end
	local m = data.match
	if type(m) == "table" and type(m.squads) == "table" then
		local s = Scoreboard.squadOf(m.squads, id)
		if s then
			return s
		end
	end
	local lobby = data.lobby
	if type(lobby) == "table" and type(lobby.squads) == "table" then
		for sid, sq in lobby.squads do
			if table.find(sq.members, id) then
				return sid
			end
		end
	end
	return nil
end

-- Squad entry (Scoreboard.Squad) by id from the match, else nil.
function State.squad(id: number?): any
	local m = data.match
	if id == nil or type(m) ~= "table" then
		return nil
	end
	for _, s in m.squads do
		if s.id == id then
			return s
		end
	end
	return nil
end

-- Best display name for a participant id (party, lobby, Players, bot model).
function State.nameOf(id: any): string
	if type(id) == "string" and tonumber(id) == nil then
		return id -- the server already sent a name
	end
	local n = tonumber(id)
	if n == nil then
		return "???"
	end
	local party = data.party
	if type(party) == "table" and type(party[n]) == "table" and party[n].name then
		return tostring(party[n].name)
	end
	local lobby = data.lobby
	if type(lobby) == "table" and type(lobby.players) == "table" then
		local e = lobby.players[n]
		if type(e) == "table" and e.name then
			return tostring(e.name)
		end
	end
	local m = data.match
	if type(m) == "table" and type(m.names) == "table" and m.names[n] then
		return tostring(m.names[n])
	end
	if n > 0 or not Ids.isBot(n) then
		local p = Players:GetPlayerByUserId(n)
		if p then
			return p.DisplayName
		end
	end
	local bots = workspace:FindFirstChild("Bots")
	if bots then
		for _, model in bots:GetChildren() do
			if model:GetAttribute("BotId") == n then
				local dn = model:GetAttribute("DisplayName")
				return "🤖 " .. (if type(dn) == "string" then dn else "Bot")
			end
		end
	end
	return if Ids.isBot(n) then "🤖 Bot" else "Hero"
end

-- Is the match a v2 squad match? (Net.S2C.Match seen this run.)
function State.isSquadMatch(): boolean
	return type(data.match) == "table"
end

-- Has `id` a bounty (server-sent, or derived from the kill feed)?
function State.hasBounty(id: any): boolean
	if id == nil then
		return false
	end
	local m = data.match
	if type(m) == "table" and type(m.bounties) == "table" and m.bounties[tostring(id)] then
		return true
	end
	local kf = data.killfeed
	return type(kf) == "table" and KillStreaks.hasBounty(kf.streaks, id)
end

-- Every bounty holder key (strings), server + derived.
function State.bountyHolders(): { string }
	local seen: { [string]: boolean } = {}
	local out = {}
	local m = data.match
	if type(m) == "table" and type(m.bounties) == "table" then
		for k in m.bounties do
			if not seen[k] then
				seen[k] = true
				table.insert(out, k)
			end
		end
	end
	local kf = data.killfeed
	if type(kf) == "table" then
		for _, k in KillStreaks.holders(kf.streaks) do
			if not seen[k] then
				seen[k] = true
				table.insert(out, k)
			end
		end
	end
	return out
end

-- Per-class progression block from the profile, with safe defaults.
function State.classState(classId: string?): { [string]: any }
	local p = data.profile
	local c = if type(p) == "table" and type(p.classes) == "table" and classId then p.classes[classId] else nil
	local t = if type(c) == "table" then c else {}
	local perks: { [string]: boolean } = {}
	if type(t.perks) == "table" then
		for k, v in t.perks do
			if v == true then
				perks[tostring(k)] = true
			elseif type(v) == "string" then
				perks[v] = true -- array form {perkId…}
			end
		end
	end
	return {
		xp = math.max(0, tonumber(t.xp) or 0),
		level = math.max(1, math.floor(tonumber(t.level) or 1)),
		perks = perks,
		perkPoints = tonumber(t.perkPoints),
		ability = if t.ability ~= nil then tostring(t.ability) else nil,
		skin = if t.skin ~= nil then tostring(t.skin) else nil,
		mastery = if type(t.mastery) == "string" then t.mastery else nil,
		known = type(c) == "table",
	}
end

-- Extraction vote (optimistic pick; the server's yourChoice wins).
function State.castExtract(choice: string)
	local e = data.extract
	if type(e) ~= "table" or e.closed then
		return
	end
	e.myPick = choice
	e.myPickAt = os.clock()
	Remotes.fire(Remotes.C2S.ExtractVote, choice)
	State.set("extract", e)
end

-- Gear swap answer: true = equip the offered item, false = keep the current one.
function State.answerSwap(take: boolean): boolean
	local inv = data.inventory
	if type(inv) ~= "table" or type(inv.swapOffer) ~= "table" then
		return false
	end
	Remotes.fire(Remotes.C2S.SwapGear, take)
	inv.swapOffer = nil
	State.set("inventory", inv)
	return true
end

-- Shop Cart purchase (pending cheese only, never Robux).
function State.buyCart(index: number)
	local cart = data.shopCart
	if type(cart) ~= "table" or cart.sold[index] then
		return
	end
	Remotes.fire(Remotes.C2S.BuyCartItem, cart.poi, index)
	cart.sold[index] = "pending"
	State.set("shopCart", cart)
end

function State.closeShopCart()
	State.set("shopCart", nil)
end

function State.toggleScoreboard(open: boolean?)
	local want = if open == nil then not data.scoreboardOpen else open
	State.set("scoreboardOpen", want)
end

-- Gear item -> plain table (items are {id, slot, rarity, …}; tolerate an id string).
local function normaliseItem(it: any): any
	if type(it) == "table" and it.id ~= nil then
		return it
	elseif type(it) == "string" and it ~= "" then
		return { id = it }
	end
	return nil
end

local function normaliseMatch(m: any): any
	local squadsIn = if type(m.squads) == "table" then m.squads else {}
	local squads = Scoreboard.normalise(squadsIn, nil)
	local me = State.localUserId()
	local mine: number? = nil
	for _, s in squads do
		if s.isYou or table.find(s.members, me) then
			mine = s.id
		end
	end
	if mine then
		for _, s in squads do
			s.isYou = s.id == mine
		end
	end
	local bounties: { [string]: boolean } = {}
	local b = m.bounties or m.bounty
	if type(b) == "table" then
		for k, v in b do
			if v == true then
				bounties[tostring(k)] = true
			elseif tonumber(v) or type(v) == "string" then
				bounties[tostring(v)] = true
			end
		end
	elseif b ~= nil then
		bounties[tostring(b)] = true
	end
	local chooser = m.routeChooser
	local chooserId = tonumber(chooser)
	if chooserId == nil and type(chooser) == "table" then
		chooserId = tonumber(chooser.squad or chooser.id)
	end
	if chooserId == nil and type(chooser) == "string" then
		for _, s in squads do
			if s.name == chooser then
				chooserId = s.id
			end
		end
	end
	return {
		phase = if m.phase ~= nil then tostring(m.phase) else nil,
		stage = tonumber(m.stage),
		squads = squads,
		mySquad = mine,
		routeChooser = chooserId,
		bounties = bounties,
		names = if type(m.names) == "table" then Format.numericKeys(m.names) else nil,
	}
end

-- Lobby squads: `l.squads` (array or map, entries {members|seats|ids, name?, color?})
-- or players[id].squad. Returns nil when the server sends no squad info (v1).
local function normaliseLobbySquads(l: any, players: { [number]: any }): { [number]: any }?
	local out: { [number]: any } = {}
	local any = false
	local function ensure(i: number): any
		local s = out[i]
		if not s then
			local d = Scoreboard.squad(i, nil, nil)
			s = { id = i, name = d.name, color = d.color, members = {} }
			out[i] = s
		end
		return s
	end
	if type(l.squads) == "table" then
		for k, sq in l.squads do
			local i = tonumber(k)
			if type(sq) == "table" and tonumber(sq.id) then
				i = tonumber(sq.id)
			end
			if i and i >= 1 and i <= 4 and type(sq) == "table" then
				any = true
				local s = ensure(i)
				if type(sq.name) == "string" then
					s.name = sq.name
				end
				if type(sq.color) == "table" then
					s.color = sq.color
				end
				local list = sq.members or sq.seats or sq.ids or sq
				for _, v in list do
					local n = tonumber(if type(v) == "table" then v.id else v)
					if n and not table.find(s.members, n) then
						table.insert(s.members, n)
					end
				end
			end
		end
	end
	for id, e in players do
		local sq = type(e) == "table" and tonumber(e.squad)
		if sq and sq >= 1 and sq <= 4 then
			any = true
			local s = ensure(sq)
			if not table.find(s.members, id) then
				table.insert(s.members, id)
			end
		end
	end
	if not any then
		return nil
	end
	for i = 1, 4 do
		ensure(i)
	end
	return out
end

local handles: { any } = {}
local started = false

function State.init()
	if started then
		return
	end
	started = true
	data.offers = {}
	local S2C = Remotes.S2C

	table.insert(
		handles,
		Remotes.on(S2C.RunState, function(rs)
			if type(rs) ~= "table" then
				return
			end
			local prev = data.run
			if prev == nil and rs.phase ~= nil and rs.phase ~= "Lobby" and data.classesAtStart == nil then
				local p = data.profile
				data.classesAtStart = if type(p) == "table" and type(p.classes) == "table"
					then table.clone(p.classes)
					else {}
			end
			State.set("run", rs)
			-- A new phase that is not a vote clears any stale vote panel.
			if prev and prev.phase ~= rs.phase then
				local v = data.vote
				if v and rs.phase ~= "RouteVote" and rs.phase ~= "BankVote" and rs.phase ~= "CycleVote" then
					State.set("vote", nil)
				end
				if rs.phase == "Lobby" then
					State.set("offers", {})
					State.set("boss", nil)
					State.set("extract", nil)
					State.set("shopCart", nil)
					State.set("inventory", nil)
					State.set("match", nil)
					State.set("scoreboardOpen", false)
					local kf = data.killfeed
					if type(kf) == "table" then
						table.clear(kf.entries)
						KillStreaks.reset(kf.streaks)
						State.set("killfeed", kf)
					end
				elseif prev.phase == "Lobby" or prev.phase == nil then
					-- A run starts: remember class progress for the results screen.
					local p = data.profile
					data.classesAtStart = if type(p) == "table" and type(p.classes) == "table"
						then table.clone(p.classes)
						else {}
				end
				if rs.phase == "Waves" or rs.phase == "Results" then
					local e = data.extract
					if type(e) == "table" then
						State.set("extract", nil)
					end
				end
			end
		end)
	)
	table.insert(handles, Remotes.on(S2C.PlayerHud, onHud))
	table.insert(
		handles,
		Remotes.on(S2C.PartyHud, function(p)
			State.set("party", Format.numericKeys(p))
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.Profile, function(p)
			if type(p) == "table" then
				State.set("profile", p)
			end
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.Lobby, function(l)
			if type(l) ~= "table" then
				return
			end
			local botCount = tonumber(l.botCount)
			local players = Format.numericKeys(l.players) -- server keys are tostring(userId)
			State.set("lobby", {
				players = players,
				-- v2: 4 squad pads x 3 seats (nil from a v1 server).
				squads = normaliseLobbySquads(l, players),
				startsAt = tonumber(l.startsAt),
				runActive = l.runActive == true,
				-- true: the countdown is the idle auto-start; false: someone readied (nil = unknown).
				autoStart = if type(l.autoStart) == "boolean" then l.autoStart else nil,
				-- This player's own bot-fill toggle (nil = unknown, UI keeps its local value).
				botFill = if type(l.botFill) == "boolean" then l.botFill else nil,
				-- Whether any lobby human has bot fill on, i.e. bots will come at all.
				botFillAny = if type(l.botFillAny) == "boolean" then l.botFillAny else nil,
				-- Bots currently placed on the pad for the next run.
				botCount = if botCount then math.max(0, math.floor(botCount)) else nil,
				-- Party leader's Pressure board (GDD §3.7).
				pressure = State.normalisePressure(l.pressure),
			})
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.VoteOpen, function(v)
			if type(v) ~= "table" then
				return
			end
			State.set("vote", {
				kind = v.kind,
				options = if type(v.options) == "table" then v.options else {},
				endsAt = tonumber(v.endsAt),
				tally = {},
				myPick = nil,
				closed = false,
				winner = nil,
			})
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.VoteTally, function(t)
			local v = data.vote
			if type(v) == "table" then
				v.tally = normaliseTally(t)
				State.set("vote", v)
			end
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.VoteClosed, function(winner)
			local v = data.vote
			if type(v) == "table" then
				v.closed = true
				v.winner = tonumber(winner)
				State.set("vote", v)
			end
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.UpgradeOffer, function(o)
			if type(o) ~= "table" or tonumber(o.offerId) == nil then
				return
			end
			local q = data.offers or {}
			local entry = {
				offerId = tonumber(o.offerId),
				cards = if type(o.cards) == "table" then o.cards else {},
				rerollsLeft = tonumber(o.rerollsLeft) or 0,
				queued = tonumber(o.queued) or 0, -- levels waiting behind this offer (server-side queue)
				-- nil (level-up) | "chest" (Elite Camp) | "pantry" (Grandma's Pantry): UpgradeUI's title
				source = if o.source == "chest" or o.source == "pantry" then o.source else nil,
			}
			-- The server has one live offer per player. A reroll may come back under
			-- the same offerId or a new one, so any older offer still queued here is
			-- stale: drop it, or the UI would keep showing (and picking) dead cards.
			local replaced = false
			for i = #q, 1, -1 do
				local existing = q[i]
				if existing.offerId == entry.offerId then
					q[i] = entry
					replaced = true
				elseif existing.offerId < entry.offerId then
					table.remove(q, i)
				end
			end
			if not replaced then
				table.insert(q, entry)
			end
			table.sort(q, function(a, b)
				return a.offerId < b.offerId
			end)
			-- Rerolls left is shared per player; keep every queued offer in sync.
			for _, e in q do
				e.rerollsLeft = entry.rerollsLeft
			end
			State.set("offers", q)
		end)
	)
	-- v2 squad PvPvE ------------------------------------------------------
	data.killfeed = { entries = {}, streaks = KillStreaks.new(), seq = 0 }
	data.scoreboardOpen = false
	table.insert(
		handles,
		Remotes.on(S2C.Match, function(m)
			if type(m) ~= "table" then
				State.set("match", nil)
				return
			end
			State.set("match", normaliseMatch(m))
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.KillFeed, function(...)
			local kf = data.killfeed
			-- One entry, or a batch {entry, entry…}.
			local first = ...
			local list = if type(first) == "table" and first.kind == nil and first.killer == nil and first.victim == nil
				then first
				else { first }
			for _, e in list do
				if type(e) == "table" then
					kf.seq += 1
					local entry = {
						killer = e.killer,
						victim = e.victim,
						killerSquad = tonumber(e.killerSquad),
						victimSquad = tonumber(e.victimSquad),
						kind = tostring(e.kind or "kill"),
						at = os.clock(),
						seq = kf.seq,
					}
					entry.newBounty = KillStreaks.push(kf.streaks, entry)
					table.insert(kf.entries, entry)
					while #kf.entries > KILLFEED_MAX do
						table.remove(kf.entries, 1)
					end
				end
			end
			State.set("killfeed", kf)
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.Inventory, function(inv)
			if type(inv) ~= "table" then
				State.set("inventory", nil)
				return
			end
			local offer = nil
			local so = inv.swapOffer
			if type(so) == "table" and normaliseItem(so.item) then
				offer = {
					item = normaliseItem(so.item),
					slot = tostring(so.slot or (normaliseItem(so.item) :: any).slot or "weapon"),
					endsAt = tonumber(so.endsAt) or (State.serverNow() + 4),
					current = normaliseItem(so.current),
				}
			end
			State.set("inventory", {
				weapon = normaliseItem(inv.weapon),
				armor = normaliseItem(inv.armor),
				trinket = normaliseItem(inv.trinket),
				swapOffer = offer,
			})
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.Extract, function(e)
			if type(e) ~= "table" or e.closed == true then
				local cur = data.extract
				if type(cur) == "table" and type(e) == "table" then
					cur.closed = true
					cur.result = e.result or e.choice
					State.set("extract", cur)
				else
					State.set("extract", nil)
				end
				return
			end
			local prev = data.extract
			local votes: { [string]: number } = {}
			if type(e.votes) == "table" then
				for k, v in e.votes do
					votes[tostring(k)] = tonumber(v) or 0
				end
			end
			local options = {}
			if type(e.options) == "table" then
				for _, o in e.options do
					table.insert(options, tostring(o))
				end
			end
			if #options == 0 then
				options = { "Extract", "Stay", "DoubleOrNothing" }
			end
			local yours = if e.yourChoice ~= nil then tostring(e.yourChoice) else nil
			local sameWindow = type(prev) == "table" and not prev.closed and prev.endsAt == tonumber(e.endsAt)
			State.set("extract", {
				endsAt = tonumber(e.endsAt),
				options = options,
				votes = votes,
				yourChoice = yours,
				-- keep an optimistic pick for 2 s, until the server echoes it
				myPick = if yours then yours elseif sameWindow and prev.myPick and os.clock() - (prev.myPickAt or 0) < 2
					then prev.myPick
					else nil,
				myPickAt = if sameWindow then prev.myPickAt else nil,
				squadSize = tonumber(e.squadSize),
				closed = false,
			})
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.ShopCart, function(c)
			if type(c) ~= "table" or c.closed == true or type(c.offers) ~= "table" then
				State.set("shopCart", nil)
				return
			end
			local prev = data.shopCart
			local offers, prices = {}, {}
			for i, it in c.offers do
				local n = tonumber(i)
				local item = normaliseItem(it)
				if n and item then
					offers[n] = item
					prices[n] = tonumber(type(c.prices) == "table" and (c.prices[i] or c.prices[tostring(i)]))
						or tonumber(item.price)
						or 0
				end
			end
			local sold: { [number]: any } = {}
			if type(c.sold) == "table" then
				for k, v in c.sold do
					if v then
						sold[tonumber(k) or 0] = true
					end
				end
			elseif type(prev) == "table" and prev.poi == c.poi then
				sold = prev.sold
			end
			State.set("shopCart", { poi = c.poi, offers = offers, prices = prices, sold = sold })
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.Results, function(r)
			if type(r) == "table" then
				State.set("offers", {})
				State.set("extract", nil)
				State.set("shopCart", nil)
				State.set("scoreboardOpen", false)
				State.set("results", r)
			end
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.Toast, function(text, kind)
			if text ~= nil then
				State.toast:Fire(tostring(text), if type(kind) == "string" then kind else "info")
			end
		end)
	)
end

function State.destroy()
	for _, h in handles do
		h.Disconnect()
	end
	table.clear(handles)
	started = false
end

return State
