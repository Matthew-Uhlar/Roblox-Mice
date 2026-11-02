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

local Players = game:GetService("Players")

local Client = script.Parent.Parent
local Signal = require(Client.Util.Signal)
local Remotes = require(Client.Util.Remotes)
local Format = require(Client.Util.Format)
local Ids = require(
	game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Ids")
)

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
			State.set("lobby", {
				players = Format.numericKeys(l.players), -- server keys are tostring(userId)
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
	table.insert(
		handles,
		Remotes.on(S2C.Results, function(r)
			if type(r) == "table" then
				State.set("offers", {})
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
