--!strict
-- Remotes: thin server-side senders over src/shared/Net.luau. Payload shapes
-- follow the comments in Net.S2C; this module only adds typing and targeting.
--
-- Note for the client (Team C): payloads keyed by userId (Lobby.players,
-- PartyHud) use STRING keys, tostring(userId). Roblox converts non-sequential
-- numeric table keys to strings over remotes anyway, so we do it explicitly.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any

local Remotes = {}

export type VoteOpenPayload = { kind: string, options: { any }, endsAt: number }
export type UpgradeOfferPayload = { offerId: number, cards: { any }, rerollsLeft: number, queued: number? }
export type PlayerHudPayload = {
	hp: number,
	maxHp: number,
	level: number,
	xp: number,
	xpToNext: number,
	abilityReadyAt: number,
	downed: boolean,
	downedUntil: number?,
	secondWinds: number,
	secondWindReady: boolean?,
	rerolls: number?,
}
export type PartyEntry = {
	name: string,
	classId: string,
	hp: number,
	maxHp: number,
	downed: boolean,
	level: number,
	dead: boolean?,
	isBot: boolean?,
}
export type LobbyEntry = {
	name: string,
	classId: string,
	ready: boolean,
	inRun: boolean?,
	isBot: boolean?,
	botFill: boolean?,
	playAgain: boolean?,
	sittingOut: boolean?, -- un-readied: not in the next start
	needsReady: boolean?, -- AFK-capped (or sitting out): won't be auto-started
}
export type LobbyPayload = {
	players: { [string]: LobbyEntry },
	startsAt: number?,
	runActive: boolean?,
	autoStart: boolean?,
	botFill: boolean?,
	botFillAny: boolean?,
	botCount: number?,
}
export type ResultsPayload = {
	outcome: string,
	cheeseEarned: number,
	xpEarned: number,
	cycle: number,
	stage: number,
	bossesKilled: number,
	duration: number,
	cheeseMult: number?,
}
export type ToastKind = "info" | "good" | "bad"

local cache: { [string]: any } = {}

function Remotes.get(name: string): any
	local r = cache[name]
	if not r then
		r = Net.get(name)
		cache[name] = r
	end
	return r
end

local function isLive(p: Player): boolean
	return p.Parent == Players
end

function Remotes.fireAll(name: string, ...: any)
	Remotes.get(name):FireAllClients(...)
end

function Remotes.fireTo(player: Player, name: string, ...: any)
	if isLive(player) then
		Remotes.get(name):FireClient(player, ...)
	end
end

function Remotes.fireExcept(except: Player, name: string, ...: any)
	local r = Remotes.get(name)
	for _, p in Players:GetPlayers() do
		if p ~= except then
			r:FireClient(p, ...)
		end
	end
end

function Remotes.fireList(players: { Player }, name: string, ...: any)
	local r = Remotes.get(name)
	for _, p in players do
		if isLive(p) then
			r:FireClient(p, ...)
		end
	end
end

-- Sends to one player, a list, or everyone (nil).
local function send(target: (Player | { Player })?, name: string, ...: any)
	if target == nil then
		Remotes.fireAll(name, ...)
	elseif typeof(target) == "Instance" then
		Remotes.fireTo(target :: Player, name, ...)
	else
		Remotes.fireList(target :: { Player }, name, ...)
	end
end

-- Typed senders ----------------------------------------------------------------

function Remotes.runState(state: any, target: (Player | { Player })?)
	send(target, Net.S2C.RunState, state)
end

function Remotes.voteOpen(target: (Player | { Player })?, payload: VoteOpenPayload)
	send(target, Net.S2C.VoteOpen, payload)
end

-- counts is a dense array, one entry per option (zeros included).
function Remotes.voteTally(target: (Player | { Player })?, counts: { number })
	send(target, Net.S2C.VoteTally, counts)
end

function Remotes.voteClosed(target: (Player | { Player })?, winningIndex: number)
	send(target, Net.S2C.VoteClosed, winningIndex)
end

function Remotes.upgradeOffer(player: Player, payload: UpgradeOfferPayload)
	Remotes.fireTo(player, Net.S2C.UpgradeOffer, payload)
end

function Remotes.playerHud(player: Player, payload: PlayerHudPayload)
	Remotes.fireTo(player, Net.S2C.PlayerHud, payload)
end

function Remotes.partyHud(payload: { [string]: PartyEntry }, target: (Player | { Player })?)
	send(target, Net.S2C.PartyHud, payload)
end

function Remotes.lobby(payload: LobbyPayload, target: (Player | { Player })?)
	send(target, Net.S2C.Lobby, payload)
end

function Remotes.toast(target: (Player | { Player })?, text: string, kind: ToastKind?)
	send(target, Net.S2C.Toast, text, kind or "info")
end

function Remotes.results(player: Player, payload: ResultsPayload)
	Remotes.fireTo(player, Net.S2C.Results, payload)
end

function Remotes.profile(player: Player, view: any)
	Remotes.fireTo(player, Net.S2C.Profile, view)
end

function Remotes.fx(events: { any }, target: (Player | { Player })?)
	send(target, Net.S2C.Fx, events)
end

function Remotes.snapshot(buf: buffer, target: (Player | { Player })?)
	send(target, Net.S2C.Snapshot, buf)
end

return Remotes
