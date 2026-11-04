--!strict
-- Run/MatchState: the v2 squad layer (docs/GDD-v2.md §1–2). Pure: no Roblox, no
-- clocks; every random choice comes from an Rng fork of the match seed.
--
-- One RunState drives the SHARED world (route cards, curses, Pressure,
-- worldMods, the stage chest maths). MatchState sits on top of it and owns the
-- squads: members, per-member cheese shares, extraction, elimination, kills,
-- loot bags, bounties and the final payouts. RunDirector drives it and feeds it
-- the World's events.
--
-- Phase flow (one cycle of CONFIG.STAGES = 4 stages):
--   Lobby --begin--> Waves --startBoss--> Boss --bossDefeated--> RouteChoice
--   --chooseRoute--> Extraction --resolveExtraction--> Waves (next stage) | Results
--   bossDefeated on the last stage, or when Last Herd Standing triggers, goes
--   straight to Results. finish(reason) ends the match from any phase.
--   Calling a phase method in the wrong phase raises an error (programming bug);
--   the event methods (heroDowned, heroKilled, eliminateSquad, removeMember, …)
--   are safe in any phase and ignore unknown ids.
--
-- Cheese model (interpretation notes where GDD-v2 left room):
--   * Every member has a SHARE of their squad's pending pot; squad.pending is
--     the sum. Stage cheese, the boss chest, Double or Nothing, the brave and Last
--     Herd bonuses all work per member, like v1's cheesePerPlayer.
--   * Stage clear: every member of every squad still in the run gets the stage
--     chest (RunState.bossDefeated().cheesePerPlayer, Pressure included) and the
--     stage XP. Dead members of a surviving squad get it too (they respawn).
--     Brave (>= BRAVE_EXTRACTED squads already extracted): stage cheese x1.25.
--   * Boss winner: the killer squad, if it is still in the run; otherwise (or on
--     a timeout) the squad with the most boss damage. Damage ties are broken with
--     the match rng; no damage at all = no winner (no chest; route = Low card).
--     The winner's members each get the boss chest (CHEST_CHEESE_FRAC x the
--     stage chest) and the squad picks the next route card.
--   * Route blessings: the stage-1 blessing goes to every squad; later blessings
--     go to the squad that picked that route, when that stage's boss falls
--     (blessingsFor(squad)). Curses and Pressure are world-wide (RunState).
--   * Double or Nothing (per squad): at the next stage clear the squad's shares
--     are x1.5 (before that stage's chest is added). Eliminated or left on a DoN
--     stage = the pot is lost.
--   * Extract: each member banks share x extractMult (gear such as Portal Charm,
--     setExtractMult; default 1) and leaves the run. Stay: keep going.
--   * Eliminated squad: each member drops a loot bag (if not already dropped this
--     stage) and banks ELIMINATED_KEEP_FRAC (50%) of what is left of the share,
--     0 on a Double-or-Nothing stage. XP is never lost.
--   * Loot bag: a killed hero drops LOOT_BAG_FRAC (30%) of THEIR share (taken out
--     of it). Whoever picks the bag up shares it with their squad (split evenly
--     over the squad's members still in the run, remainder to the picker).
--     Unclaimed bags are lost when the next stage starts.
--   * Kill streaks: a hero kill (heroKilled with an enemy `by`) adds 1 to the
--     killer's streak; at BOUNTY_STREAK (3) they carry a bounty. The enemy hero
--     who downs (or kills) a bountied hero gets +BOUNTY_CHEESE (100) in their
--     share; the bounty and streak then reset. Dying resets the streak too.
--   * Last Herd Standing: a stage counts as "alone" when exactly one squad is in
--     the run at its clear. After LAST_HERD_STAGES (2) alone stages that squad's
--     shares are x1.5 and it is extracted; the match ends.
--   * Run end: the last stage's clear (survivors extract automatically, with
--     Last Herd Standing if earned), every squad extracted or eliminated, or Last
--     Herd Standing. RunDirector also ends it with finish("noHumans") when no
--     human is left in the run, and finish("crash") pays the wipe rule to
--     everyone still in it.
--   * Leaving the server (removeMember): the member banks LEAVER_KEEP_FRAC of the
--     share (0 on a DoN stage). A squad with no member left in the run is out
--     (eliminated, reason "left"), without loot bags.
--   * Difficulty party size (difficulty()): the average squad weight (humans 1,
--     bots botWeight) over the squads in the run, clamped by RunState.partySize.

local Rng = require("../Util/Rng")
local Ids = require("../Util/Ids")
local Squads = require("../Util/Squads")
local RunState = require("./RunState")
local Types = require("../Types")

type Rng = Rng.Rng
type RouteCard = Types.RouteCard

export type Choice = "Extract" | "Stay" | "DoubleOrNothing"
export type Phase = "Lobby" | "Waves" | "Boss" | "RouteChoice" | "Extraction" | "Results"
export type Result = "extracted" | "lastHerd" | "eliminated" | "left" | "aborted" | "unfinished"

export type Participant = { id: number, squad: number, isBot: boolean?, classId: string? }

export type Member = {
	id: number,
	squad: number,
	isBot: boolean,
	classId: string?,
	share: number, -- pending cheese (this member's part of the squad pot)
	banked: number, -- cheese this member takes home
	xp: number, -- account XP earned (never lost)
	dead: boolean, -- killed this stage (respawns next stage if the squad survives)
	left: boolean, -- left the server
	bagDropped: boolean, -- dropped a loot bag this stage
	kills: number, -- hero kills
	downs: number, -- enemy heroes downed (PvP downs)
	streak: number,
	bounty: boolean,
	stagesSurvived: number, -- stage clears while standing
	stagesCleared: number, -- stage clears while the squad was in the run
	bossDamageShare: number, -- this hero's boss damage share (squad share / members), summed over bosses
	pois: number,
	extractMult: number,
	result: Result?, -- set when the member is out of the run (then payout() is final)
}

export type Squad = {
	id: number,
	name: string,
	color: { number },
	members: { number },
	empty: boolean, -- nobody was seated here
	extracted: boolean,
	eliminated: boolean,
	outReason: string?, -- "extracted" | "eliminated" | "left" | "lastHerd" | "final"
	outAtStage: number?,
	doubleOrNothing: boolean,
	kills: number,
	blessings: { string },
}

export type KillResult = {
	victim: number,
	killer: number?,
	victimSquad: number,
	killerSquad: number?,
	bagCheese: number, -- 0 = no bag cheese (the gear still drops: RunDirector's call)
	bagKey: number?, -- MatchState's id for the bag (registerBag maps the world's id)
	newBounty: number?, -- the killer now carries a bounty
	bounty: { by: number, victim: number, cheese: number }?, -- a bounty was claimed
}

export type StageResult = {
	stage: number,
	winner: number?,
	winnerBy: "kill" | "damage" | nil,
	stageCheese: number, -- per member, brave bonus included
	chestCheese: number, -- per winning member
	xp: number, -- per member
	brave: boolean,
	epic: boolean,
	blessingId: string?,
	tier: string?, -- the route tier of the stage just cleared
	potBonus: { [number]: number }, -- squad -> cheese added by Double or Nothing (all members)
	finished: boolean,
	endReason: string?,
	out: { number }, -- member ids now out of the run (pay them)
}

export type ExtractResult = {
	extracted: { number }, -- squads
	stayed: { number },
	doubleOrNothing: { number },
	out: { number }, -- member ids now out of the run (pay them)
	finished: boolean,
	endReason: string?,
}

export type Payout = {
	id: number,
	squad: number,
	cheese: number,
	xp: number,
	result: Result,
	extracted: boolean,
	lastHerd: boolean,
	kills: number,
	downs: number,
	stagesCleared: number,
	placement: number,
	summary: Summary,
}

export type Summary = {
	stagesSurvived: number,
	bossDamageShare: number,
	heroDowns: number,
	pois: number,
	extracted: boolean,
}

export type Options = {
	bossIds: { string }?,
	mapIds: { string }?,
	pressure: { [string]: number }?,
	botWeight: number?,
}

local MatchState = {}
MatchState.__index = MatchState

MatchState.CHOICES = table.freeze({ "Extract", "Stay", "DoubleOrNothing" })
MatchState.DEFAULT_CHOICE = "Stay"

MatchState.CONFIG = table.freeze({
	STAGES = RunState.CONFIG.STAGES_PER_CYCLE, -- 4: one cycle per run
	LOOT_BAG_FRAC = 0.3,
	BOUNTY_STREAK = 3,
	BOUNTY_CHEESE = 100,
	BRAVE_EXTRACTED = 2,
	BRAVE_MULT = 1.25,
	DON_POT_MULT = 1.5,
	LAST_HERD_STAGES = 2,
	LAST_HERD_MULT = 1.5,
	ELIMINATED_KEEP_FRAC = RunState.CONFIG.WIPE_KEEP_FRAC, -- 0.5, the v1 wipe rule
	LEAVER_KEEP_FRAC = RunState.CONFIG.WIPE_KEEP_FRAC,
	CHEST_CHEESE_FRAC = 1.0, -- the boss chest = one more stage chest per winning member
	MAX_EXTRACT_MULT = 2,
	BOT_WEIGHT = 0.6,
	-- Class XP fallback (ClassProgress.runXp is R3's; this is used only without it)
	XP_PER_STAGE = 40,
	XP_PER_DAMAGE_SHARE = 100,
	XP_PER_DOWN = 15,
	XP_PER_POI = 10,
	XP_EXTRACT_MULT = 1.5,
})

local C = MatchState.CONFIG

type Data = {
	seed: number,
	run: any, -- RunState
	rng: Rng,
	phase: Phase,
	stage: number,
	squads: { Squad },
	members: { [number]: Member },
	order: { number },
	aloneStages: number,
	chooserSquad: number?, -- squad that picked the CURRENT stage's route (nil = nobody)
	nextChooser: number?, -- winner of the last boss, picks the next route
	bags: { [number]: number }, -- bagKey -> cheese
	bagIds: { [any]: number }, -- world bag id -> bagKey
	nextBag: number,
	endReason: string?,
	lastStage: StageResult?,
	botWeight: number,
}

export type MatchState = typeof(setmetatable({} :: Data, MatchState))

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function expectPhase(self: MatchState, fn: string, ...: Phase)
	for i = 1, select("#", ...) do
		if self.phase == select(i, ...) then
			return
		end
	end
	error(string.format("MatchState:%s called in phase %s", fn, self.phase), 3)
end

-- Construction ------------------------------------------------------------------------

function MatchState.new(seed: number, participants: { Participant }, opts: Options?): MatchState
	local o: Options = opts or {}
	local squads: { Squad } = {}
	for i = 1, Squads.MAX do
		local def = Squads.get(i)
		squads[i] = {
			id = i,
			name = def.name,
			color = table.clone(def.color),
			members = {},
			empty = true,
			extracted = false,
			eliminated = false,
			outReason = nil,
			outAtStage = nil,
			doubleOrNothing = false,
			kills = 0,
			blessings = {},
		}
	end
	local members: { [number]: Member } = {}
	local order: { number } = {}
	for _, p in participants do
		assert(type(p) == "table" and finite(p.id), "MatchState.new: participant needs a numeric id")
		assert(Squads.isValid(p.squad), "MatchState.new: invalid squad for " .. tostring(p.id))
		assert(members[p.id] == nil, "MatchState.new: duplicate participant " .. tostring(p.id))
		local sq = squads[p.squad]
		assert(#sq.members < Squads.SIZE, "MatchState.new: squad " .. p.squad .. " is over capacity")
		members[p.id] = {
			id = p.id,
			squad = p.squad,
			isBot = if p.isBot ~= nil then p.isBot == true else Ids.isBot(p.id),
			classId = p.classId,
			share = 0,
			banked = 0,
			xp = 0,
			dead = false,
			left = false,
			bagDropped = false,
			kills = 0,
			downs = 0,
			streak = 0,
			bounty = false,
			stagesSurvived = 0,
			stagesCleared = 0,
			bossDamageShare = 0,
			pois = 0,
			extractMult = 1,
			result = nil,
		}
		table.insert(order, p.id)
		table.insert(sq.members, p.id)
		sq.empty = false
	end
	local botWeight = if finite(o.botWeight) then o.botWeight :: number else C.BOT_WEIGHT
	local self = setmetatable({
		seed = seed,
		run = nil :: any,
		rng = Rng.new(seed):fork(0x5A0D),
		phase = "Lobby" :: Phase,
		stage = 0,
		squads = squads,
		members = members,
		order = order,
		aloneStages = 0,
		chooserSquad = nil,
		nextChooser = nil,
		bags = {},
		bagIds = {},
		nextBag = 0,
		endReason = nil,
		lastStage = nil,
		botWeight = botWeight,
	}, MatchState)
	self.run = RunState.new(seed, 1, { bossIds = o.bossIds, mapIds = o.mapIds, pressure = o.pressure })
	self.run:setPlayerCount(self:difficulty())
	return self
end

-- Queries -----------------------------------------------------------------------------

function MatchState.member(self: MatchState, id: any): Member?
	return if type(id) == "number" then self.members[id] else nil
end

function MatchState.squadOf(self: MatchState, id: any): number?
	local m = self:member(id)
	return if m then m.squad else nil
end

function MatchState.squad(self: MatchState, squad: number): Squad?
	return self.squads[squad]
end

local function inRun(sq: Squad): boolean
	return not sq.empty and not sq.extracted and not sq.eliminated
end

function MatchState.isSquadInRun(self: MatchState, squad: any): boolean
	local sq = if type(squad) == "number" then self.squads[squad] else nil
	return sq ~= nil and inRun(sq)
end

-- Squads still playing (not empty, extracted or eliminated), by id.
function MatchState.squadsInRun(self: MatchState): { number }
	local out = {}
	for _, sq in self.squads do
		if inRun(sq) then
			table.insert(out, sq.id)
		end
	end
	return out
end

function MatchState.extractedCount(self: MatchState): number
	local n = 0
	for _, sq in self.squads do
		if sq.extracted then
			n += 1
		end
	end
	return n
end

-- Is this participant still in the run (squad in the run, has not left)?
function MatchState.isInRun(self: MatchState, id: any): boolean
	local m = self:member(id)
	return m ~= nil and not m.left and m.result == nil and self:isSquadInRun(m.squad)
end

function MatchState.isOut(self: MatchState, id: any): boolean
	local m = self:member(id)
	return m ~= nil and m.result ~= nil
end

-- Member ids of a squad that are still in the run (not left).
function MatchState.activeMembers(self: MatchState, squad: number): { number }
	local out = {}
	local sq = self.squads[squad]
	if not sq or not inRun(sq) then
		return out
	end
	for _, id in sq.members do
		local m = self.members[id]
		if m and not m.left and m.result == nil then
			table.insert(out, id)
		end
	end
	return out
end

function MatchState.humansInRun(self: MatchState): number
	local n = 0
	for _, id in self.order do
		local m = self.members[id]
		if not m.isBot and self:isInRun(id) then
			n += 1
		end
	end
	return n
end

function MatchState.squadPending(self: MatchState, squad: number): number
	local sq = self.squads[squad]
	if not sq then
		return 0
	end
	local total = 0
	for _, id in sq.members do
		total += self.members[id].share
	end
	return total
end

function MatchState.shareOf(self: MatchState, id: any): number
	local m = self:member(id)
	return if m then m.share else 0
end

function MatchState.squadDoubleOrNothing(self: MatchState, squad: any): boolean
	local sq = if type(squad) == "number" then self.squads[squad] else nil
	return sq ~= nil and sq.doubleOrNothing
end

function MatchState.blessingsFor(self: MatchState, squad: any): { string }
	local sq = if type(squad) == "number" then self.squads[squad] else nil
	return if sq then table.clone(sq.blessings) else {}
end

function MatchState.bountyIds(self: MatchState): { number }
	local out = {}
	for _, id in self.order do
		local m = self.members[id]
		if m.bounty and self:isInRun(id) then
			table.insert(out, id)
		end
	end
	return out
end

function MatchState.routeCards(self: MatchState): { RouteCard }?
	return if self.phase == "RouteChoice" then self.run:routeCards() else nil
end

-- The squad that picks the next route (RouteChoice), nil = default (Low card).
function MatchState.routeChooser(self: MatchState): number?
	return self.nextChooser
end

function MatchState.currentRoute(self: MatchState): RouteCard?
	return self.run:currentRoute()
end

function MatchState.worldMods(self: MatchState): any
	return self.run:worldMods()
end

function MatchState.stageSeed(self: MatchState): number
	return self.run:getStageSeed()
end

function MatchState.pressurePoints(self: MatchState): number
	return self.run:pressurePoints()
end

function MatchState.pressureLuck(self: MatchState): number
	return self.run:pressureLuck()
end

function MatchState.isFinalStage(self: MatchState): boolean
	return self.stage >= C.STAGES
end

-- Difficulty party size: average squad weight (humans 1, bots botWeight) over
-- the squads in the run, clamped like v1 (RunState.partySize).
function MatchState.difficulty(self: MatchState): number
	local total, squads = 0, 0
	for _, sq in self.squads do
		if inRun(sq) then
			squads += 1
			for _, id in sq.members do
				local m = self.members[id]
				if not m.left and m.result == nil then
					total += if m.isBot then self.botWeight else 1
				end
			end
		end
	end
	if squads == 0 then
		return RunState.partySize(1)
	end
	return RunState.partySize(total / squads)
end

-- Gear such as Portal Charm: Extract keeps `mult` x the share (1..MAX_EXTRACT_MULT).
function MatchState.setExtractMult(self: MatchState, id: number, mult: number)
	local m = self:member(id)
	if m then
		m.extractMult = if finite(mult) then math.clamp(mult, 1, C.MAX_EXTRACT_MULT) else 1
	end
end

-- Cheese helpers ----------------------------------------------------------------------

local function cleanAmount(amount: any): number
	if not finite(amount) or amount <= 0 then
		return 0
	end
	return math.floor(amount)
end

-- Adds cheese to one member's share (in the run only). Returns what was added.
function MatchState.addMemberCheese(self: MatchState, id: number, amount: number): number
	local n = cleanAmount(amount)
	if n == 0 or not self:isInRun(id) then
		return 0
	end
	self.members[id].share += n
	return n
end

-- Adds `perMember` to every active member of a squad (POI caches). Returns the total.
function MatchState.addSquadCheese(self: MatchState, squad: number, perMember: number): number
	local n = cleanAmount(perMember)
	if n == 0 then
		return 0
	end
	local total = 0
	for _, id in self:activeMembers(squad) do
		self.members[id].share += n
		total += n
	end
	return total
end

-- Splits `amount` over a squad's active members; the remainder goes to `first`
-- (when it is one of them), else to the first members in order.
function MatchState._split(self: MatchState, squad: number, amount: number, first: number?): number
	local n = cleanAmount(amount)
	local list = self:activeMembers(squad)
	if n == 0 or #list == 0 then
		return 0
	end
	if first and table.find(list, first) then
		table.remove(list, table.find(list, first) :: number)
		table.insert(list, 1, first)
	end
	local each = math.floor(n / #list)
	local rest = n - each * #list
	for i, id in list do
		self.members[id].share += each + (if i <= rest then 1 else 0)
	end
	return n
end

-- Spends pending cheese from a member's share (Shop Cart POI: in-run soft
-- currency, never Robux). Returns false (and spends nothing) if they can't pay.
function MatchState.spendShare(self: MatchState, id: number, amount: number): boolean
	local n = cleanAmount(amount)
	if n == 0 or not self:isInRun(id) then
		return false
	end
	local m = self.members[id]
	if m.share < n then
		return false
	end
	m.share -= n
	return true
end

-- Gives back cheese spent by spendShare (a purchase the World refused).
function MatchState.refundShare(self: MatchState, id: number, amount: number)
	local m = self:member(id)
	local n = cleanAmount(amount)
	if m and n > 0 then
		if m.result == nil then
			m.share += n
		else
			m.banked += n
		end
	end
end

function MatchState.notePoi(self: MatchState, id: any)
	local m = self:member(id)
	if m and self:isInRun(id) then
		m.pois += 1
	end
end

-- Out of the run --------------------------------------------------------------------------

local function bankShare(m: Member, frac: number, result: Result)
	m.banked += math.max(0, math.floor(m.share * frac + 1e-6))
	m.share = 0
	m.result = result
end

local function markOut(self: MatchState, sq: Squad, reason: string)
	sq.outReason = reason
	sq.outAtStage = self.stage
	sq.doubleOrNothing = if reason == "extracted"
			or reason == "lastHerd"
			or reason == "final"
		then false
		else sq.doubleOrNothing
end

-- Extracts a squad: every active member banks share x extractMult (x bonus).
function MatchState._extract(self: MatchState, squad: number, bonus: number, result: Result, out: { number })
	local sq = self.squads[squad]
	for _, id in self:activeMembers(squad) do
		local m = self.members[id]
		bankShare(m, bonus * m.extractMult, result)
		table.insert(out, id)
	end
	sq.extracted = true
	markOut(self, sq, if result == "lastHerd" then "lastHerd" else "extracted")
end

-- Drops a loot bag for a member (once per stage): LOOT_BAG_FRAC of their share.
function MatchState._dropBag(self: MatchState, m: Member): (number, number?)
	if m.bagDropped or m.left or m.result ~= nil then
		return 0, nil
	end
	m.bagDropped = true
	local cheese = math.floor(m.share * C.LOOT_BAG_FRAC + 1e-6)
	m.share -= cheese
	self.nextBag += 1
	local key = self.nextBag
	self.bags[key] = cheese
	return cheese, key
end

-- Squad eliminated (all members dead / downed with nobody to revive, or the
-- World's squadEliminated). Members who have not dropped a bag this stage drop
-- one now. Returns the member ids now out and the bags dropped. Idempotent.
function MatchState.eliminateSquad(
	self: MatchState,
	squad: number
): { out: { number }, drops: { { id: number, cheese: number, key: number } } }
	local res = { out = {}, drops = {} }
	local sq = if type(squad) == "number" then self.squads[squad] else nil
	if not sq or not inRun(sq) or self.phase == "Results" then
		return res
	end
	local keep = if sq.doubleOrNothing then 0 else C.ELIMINATED_KEEP_FRAC
	for _, id in self:activeMembers(squad) do
		local m = self.members[id]
		local cheese, key = self:_dropBag(m)
		if key then
			table.insert(res.drops, { id = id, cheese = cheese, key = key })
		end
		m.streak = 0
		m.bounty = false
		bankShare(m, keep, "eliminated")
		table.insert(res.out, id)
	end
	sq.eliminated = true
	markOut(self, sq, "eliminated")
	self:_checkEnd()
	return res
end

-- A participant left the server. Returns their payout (cheese, xp) if they were
-- in the run (the leaver keeps LEAVER_KEEP_FRAC of the share, 0 on DoN).
function MatchState.removeMember(self: MatchState, id: number): Payout?
	local m = self:member(id)
	if not m or m.left then
		return nil
	end
	local sq = self.squads[m.squad]
	if m.result == nil then
		if self.phase == "Results" then
			bankShare(m, 0, "unfinished")
		else
			bankShare(m, if sq.doubleOrNothing then 0 else C.LEAVER_KEEP_FRAC, "left")
		end
	end
	m.left = true
	m.streak = 0
	m.bounty = false
	if inRun(sq) and #self:activeMembers(m.squad) == 0 then
		sq.eliminated = true
		markOut(self, sq, "left")
		self:_checkEnd()
	end
	return self:payout(id)
end

-- PvP events --------------------------------------------------------------------------------

local function enemy(self: MatchState, victim: Member, by: any): Member?
	local k = self:member(by)
	if k and k.squad ~= victim.squad then
		return k
	end
	return nil
end

-- Claims the victim's bounty for `k`. Returns the claim or nil.
local function claimBounty(
	self: MatchState,
	v: Member,
	k: Member
): { by: number, victim: number, cheese: number }?
	if not v.bounty then
		return nil
	end
	v.bounty = false
	v.streak = 0
	local cheese = if self:isInRun(k.id) then C.BOUNTY_CHEESE else 0
	k.share += cheese
	return { by = k.id, victim = v.id, cheese = cheese }
end

-- A hero went down. `by` = attacker id (nil / a mouse = no PvP credit).
function MatchState.heroDowned(
	self: MatchState,
	victim: number,
	by: number?
): {
	victimSquad: number,
	killerSquad: number?,
	bounty: { by: number, victim: number, cheese: number }?,
}?
	local v = self:member(victim)
	if not v or self.phase == "Results" then
		return nil
	end
	local k = enemy(self, v, by)
	local claim = nil
	if k then
		k.downs += 1
		claim = claimBounty(self, v, k)
	end
	return { victimSquad = v.squad, killerSquad = if k then k.squad else nil, bounty = claim }
end

-- A hero died (out until the next stage). Drops the loot bag, counts the kill
-- and the streak, and may give the killer a bounty. Idempotent per stage.
function MatchState.heroKilled(self: MatchState, victim: number, by: number?): KillResult?
	local v = self:member(victim)
	if not v or v.dead or self.phase == "Results" then
		return nil
	end
	v.dead = true
	local k = enemy(self, v, by)
	local claim = if k then claimBounty(self, v, k) else nil
	v.streak = 0
	v.bounty = false
	local bagCheese, bagKey = 0, nil
	if self:isInRun(victim) then
		bagCheese, bagKey = self:_dropBag(v)
	end
	local newBounty = nil
	if k then
		k.kills += 1
		self.squads[k.squad].kills += 1
		k.streak += 1
		if k.streak >= C.BOUNTY_STREAK and not k.bounty and self:isInRun(k.id) then
			k.bounty = true
			newBounty = k.id
		end
	end
	return {
		victim = victim,
		killer = if k then k.id else nil,
		victimSquad = v.squad,
		killerSquad = if k then k.squad else nil,
		bagCheese = bagCheese,
		bagKey = bagKey,
		newBounty = newBounty,
		bounty = claim,
	}
end

-- Maps the World's loot-bag id to MatchState's bag (world:addLootBag's result).
function MatchState.registerBag(self: MatchState, worldBagId: any, bagKey: number)
	if worldBagId ~= nil and self.bags[bagKey] ~= nil then
		self.bagIds[worldBagId] = bagKey
	end
end

-- A loot bag was picked up by `picker` (World lootBag event). The cheese is
-- split over the picker's squad. `bag` is the world id (registerBag) or a
-- bagKey. Returns the cheese moved (0 if unknown / already claimed).
function MatchState.claimBag(self: MatchState, bag: any, picker: number): number
	local key = self.bagIds[bag] or (if type(bag) == "number" and self.bags[bag] then bag else nil)
	if not key or not self:isInRun(picker) then
		return 0
	end
	local cheese = self.bags[key]
	if cheese == nil then
		return 0
	end
	self.bags[key] = nil
	for wid, k in self.bagIds do
		if k == key then
			self.bagIds[wid] = nil
		end
	end
	return self:_split(self:squadOf(picker) :: number, cheese, picker)
end

function MatchState.unclaimedBagCheese(self: MatchState): number
	local n = 0
	for _, c in self.bags do
		n += c
	end
	return n
end

-- Stage loop --------------------------------------------------------------------------------

-- New stage: dead heroes of surviving squads respawn; unclaimed bags are lost.
function MatchState._startStage(self: MatchState)
	self.stage += 1
	self.bags = {}
	self.bagIds = {}
	for _, id in self.order do
		local m = self.members[id]
		m.dead = false
		m.bagDropped = false
	end
	self.run:setPlayerCount(self:difficulty())
	self.phase = "Waves"
end

-- Starts stage 1. `cardIndex` picks one of the 3 (Low) opening cards; default:
-- a seeded random one. Nobody chooses the first route, so its blessing goes to
-- every squad.
function MatchState.begin(self: MatchState, cardIndex: number?): RouteCard
	expectPhase(self, "begin", "Lobby")
	local cards = self.run:openRouteVote()
	local idx = if type(cardIndex) == "number" and cards[cardIndex]
		then cardIndex
		else self.rng:nextInt(1, #cards)
	local card = self.run:chooseRoute(idx)
	self.chooserSquad = nil
	self:_startStage()
	self:_checkEnd()
	return card
end

function MatchState.startBoss(self: MatchState)
	expectPhase(self, "startBoss", "Waves")
	self.run:startBoss()
	self.phase = "Boss"
end

local function damageOf(damageBySquad: any, squad: number): number
	if type(damageBySquad) ~= "table" then
		return 0
	end
	local v = damageBySquad[squad]
	if v == nil then
		v = damageBySquad[tostring(squad)]
	end
	return if finite(v) and v > 0 then v else 0
end

-- The boss winner: the killer squad if still in the run, else the top damage
-- squad in the run (ties: rng), else nil.
function MatchState.bossWinner(self: MatchState, killerSquad: any, damageBySquad: any): (number?, string?)
	if self:isSquadInRun(killerSquad) then
		return killerSquad, "kill"
	end
	local best, tied = 0, {}
	for _, s in self:squadsInRun() do
		local d = damageOf(damageBySquad, s)
		if d > best + 1e-9 then
			best, tied = d, { s }
		elseif d > 0 and math.abs(d - best) <= 1e-9 then
			table.insert(tied, s)
		end
	end
	if #tied == 0 then
		return nil, nil
	end
	return (if #tied == 1 then tied[1] else self.rng:pick(tied)), "damage"
end

-- The stage's boss fell (killerSquad = the squad of the killing blow) or timed
-- out (killerSquad nil). Pays the stage, picks the winner, and moves to
-- RouteChoice, or to Results on the last stage / Last Herd Standing.
function MatchState.bossDefeated(self: MatchState, killerSquad: number?, damageBySquad: any): StageResult
	expectPhase(self, "bossDefeated", "Boss")
	local route = self.run:currentRoute()
	local reward = self.run:bossDefeated()
	local winner, winnerBy = self:bossWinner(killerSquad, damageBySquad)
	local brave = self:extractedCount() >= C.BRAVE_EXTRACTED
	local stageCheese = reward.cheesePerPlayer
	if brave then
		stageCheese = math.floor(stageCheese * C.BRAVE_MULT + 1e-6)
	end
	local chestCheese = if winner then math.floor(reward.cheesePerPlayer * C.CHEST_CHEESE_FRAC + 1e-6) else 0

	-- Boss damage shares (class XP)
	local totalDamage = 0
	for _, s in self:squadsInRun() do
		totalDamage += damageOf(damageBySquad, s)
	end

	local potBonus: { [number]: number } = {}
	local live = self:squadsInRun()
	for _, s in live do
		local sq = self.squads[s]
		-- A hero's boss damage share: the squad's share split over its members
		-- (the World reports damage per squad), summed over the run's bosses.
		local active = self:activeMembers(s)
		local share = if totalDamage > 0 and #active > 0
			then damageOf(damageBySquad, s) / totalDamage / #active
			else 0
		local bonus = 0
		for _, id in active do
			local m = self.members[id]
			if sq.doubleOrNothing then
				local grown = math.floor(m.share * C.DON_POT_MULT + 1e-6)
				bonus += grown - m.share
				m.share = grown
			end
			m.share += stageCheese
			if s == winner then
				m.share += chestCheese
			end
			m.xp += reward.xpPerPlayer
			m.stagesCleared += 1
			m.bossDamageShare += share
			if not m.dead then
				m.stagesSurvived += 1
			end
		end
		if sq.doubleOrNothing then
			potBonus[s] = bonus
		end
		sq.doubleOrNothing = false
	end

	-- Blessing: the route's chooser, or every squad for an unchosen route.
	if reward.blessingId then
		if self.chooserSquad == nil then
			for _, s in live do
				table.insert(self.squads[s].blessings, reward.blessingId)
			end
		elseif self:isSquadInRun(self.chooserSquad) then
			table.insert(self.squads[self.chooserSquad :: number].blessings, reward.blessingId)
		end
	end

	if #live == 1 then
		self.aloneStages += 1
	else
		self.aloneStages = 0
	end
	self.nextChooser = winner

	local result: StageResult = {
		stage = self.stage,
		winner = winner,
		winnerBy = winnerBy :: any,
		stageCheese = stageCheese,
		chestCheese = chestCheese,
		xp = reward.xpPerPlayer,
		brave = brave,
		epic = reward.epic,
		blessingId = reward.blessingId,
		tier = if route then route.tier else nil,
		potBonus = potBonus,
		finished = false,
		endReason = nil,
		out = {},
	}
	if self.stage >= C.STAGES then
		result.out = self:finish(if self.aloneStages >= C.LAST_HERD_STAGES then "lastHerd" else "final")
	elseif self.aloneStages >= C.LAST_HERD_STAGES then
		result.out = self:finish("lastHerd")
	else
		self.run:openBankVote()
		self.run:chooseBank("Continue") -- rolls the next stage's cards (DoN is per squad here)
		self.phase = "RouteChoice"
	end
	result.finished = self.phase == "Results"
	result.endReason = self.endReason
	self.lastStage = result
	return result
end

-- The winning squad (or the default, when nobody won) picks the next route.
function MatchState.chooseRoute(self: MatchState, cardIndex: number, squad: number?): RouteCard
	expectPhase(self, "chooseRoute", "RouteChoice")
	local card = self.run:chooseRoute(cardIndex)
	self.chooserSquad = if squad ~= nil and self:isSquadInRun(squad) then squad else nil
	self.phase = "Extraction"
	return card
end

-- Default route card index (the Low card).
function MatchState.defaultRouteIndex(cards: { any }): number
	for i, card in cards do
		if type(card) == "table" and card.tier == "Low" then
			return i
		end
	end
	return 1
end

function MatchState.isChoice(v: any): boolean
	return type(v) == "string" and table.find(MatchState.CHOICES, v) ~= nil
end

-- Applies every squad's extraction choice ({[squad] = Choice}; missing = Stay),
-- then starts the next stage or ends the match.
function MatchState.resolveExtraction(self: MatchState, choices: { [number]: string }?): ExtractResult
	expectPhase(self, "resolveExtraction", "Extraction")
	local res: ExtractResult =
		{ extracted = {}, stayed = {}, doubleOrNothing = {}, out = {}, finished = false, endReason = nil }
	for _, s in self:squadsInRun() do
		local choice = if choices then choices[s] else nil
		if not MatchState.isChoice(choice) then
			choice = MatchState.DEFAULT_CHOICE
		end
		if choice == "Extract" then
			self:_extract(s, 1, "extracted", res.out)
			table.insert(res.extracted, s)
		elseif choice == "DoubleOrNothing" then
			self.squads[s].doubleOrNothing = true
			table.insert(res.doubleOrNothing, s)
		else
			table.insert(res.stayed, s)
		end
	end
	self:_checkEnd()
	if self.phase ~= "Results" then
		self:_startStage()
	end
	res.finished = self.phase == "Results"
	res.endReason = self.endReason
	return res
end

-- Bot-only squads (no human to follow) when BotBrain has no extraction logic:
-- stay early, extract more often as the stages go by, never Double or Nothing.
-- The brave bonus (>= 2 squads out) makes staying more tempting.
MatchState.BOT_EXTRACT_CHANCE = table.freeze({ 0.1, 0.25, 0.45 })

function MatchState.botExtractChoice(self: MatchState, _squad: number, rng: Rng): Choice
	local p = MatchState.BOT_EXTRACT_CHANCE[self.stage]
	if p == nil then
		return "Stay"
	end
	if self:extractedCount() >= C.BRAVE_EXTRACTED then
		p *= 0.6
	end
	return if rng:chance(p) then "Extract" else "Stay"
end

-- Ends the match when nobody is left in it. Returns true if it ended.
function MatchState._checkEnd(self: MatchState): boolean
	if self.phase == "Results" or self.phase == "Lobby" then
		return self.phase == "Results"
	end
	if #self:squadsInRun() == 0 then
		self:finish("allOut")
		return true
	end
	return false
end

-- Ends the match. reason:
--   "final"     the last stage is done: survivors extract (Last Herd if earned)
--   "lastHerd"  the lone squad extracts with the Last Herd Standing bonus
--   "allOut"    nobody is left (nothing to pay)
--   "noHumans"  no human is left in the run: bot squads end unpaid
--   "crash" / "abort"  survivors get the wipe rule (keep 50%, 0 on DoN)
-- Returns the member ids it took out of the run.
function MatchState.finish(self: MatchState, reason: string): { number }
	local out: { number } = {}
	if self.phase == "Results" then
		return out
	end
	if reason == "final" or reason == "lastHerd" then
		local live = self:squadsInRun()
		local herd = reason == "lastHerd" and #live == 1
		for _, s in live do
			if herd then
				self:_extract(s, C.LAST_HERD_MULT, "lastHerd", out)
			else
				self:_extract(s, 1, "extracted", out)
			end
		end
	elseif reason ~= "allOut" then
		for _, s in self:squadsInRun() do
			local sq = self.squads[s]
			local keep = if sq.doubleOrNothing then 0 else C.ELIMINATED_KEEP_FRAC
			for _, id in self:activeMembers(s) do
				local m = self.members[id]
				if reason == "noHumans" then
					bankShare(m, 0, "unfinished")
				else
					bankShare(m, keep, "aborted")
				end
				table.insert(out, id)
			end
			sq.eliminated = true
			markOut(self, sq, reason)
		end
	end
	self.endReason = reason
	self.phase = "Results"
	return out
end

-- Payouts ------------------------------------------------------------------------------------

-- Squad placement 1..4 (Results). Last Herd Standing is 1st. Otherwise squads
-- rank by how far they got (still in the run counts as the current stage + 1),
-- a squad that extracted ranks above one eliminated at the same stage, then by
-- the cheese its members took home, then by squad id. Empty squads come last.
-- Mid-match it is provisional (squads still playing can only pass the out ones).
function MatchState.placement(self: MatchState, squad: number): number
	local function score(sq: Squad): (number, number)
		if sq.empty then
			return -1, 0
		end
		local banked = 0
		for _, id in sq.members do
			banked += self.members[id].banked
		end
		if sq.outReason == "lastHerd" then
			return 1e6, banked
		end
		local reached = if inRun(sq) then self.stage + 1 else (sq.outAtStage or 0)
		local survived = if inRun(sq) or sq.extracted then 1 else 0
		return reached * 2 + survived, banked
	end
	local target = self.squads[squad]
	if not target then
		return Squads.MAX
	end
	local ts, tb = score(target)
	local place = 1
	for _, sq in self.squads do
		if sq.id ~= squad then
			local s2, b2 = score(sq)
			if s2 > ts or (s2 == ts and (b2 > tb or (b2 == tb and sq.id < squad))) then
				place += 1
			end
		end
	end
	return place
end

function MatchState.summary(self: MatchState, id: number): Summary
	local m = self.members[id]
	if not m then
		return { stagesSurvived = 0, bossDamageShare = 0, heroDowns = 0, pois = 0, extracted = false }
	end
	return {
		stagesSurvived = m.stagesSurvived,
		bossDamageShare = m.bossDamageShare,
		heroDowns = m.downs,
		pois = m.pois,
		extracted = m.result == "extracted" or m.result == "lastHerd",
	}
end

-- Class XP when R3's ClassProgress.runXp is missing.
function MatchState.classXpFallback(s: Summary): number
	local xp = C.XP_PER_STAGE * (s.stagesSurvived or 0)
		+ C.XP_PER_DAMAGE_SHARE * (s.bossDamageShare or 0)
		+ C.XP_PER_DOWN * (s.heroDowns or 0)
		+ C.XP_PER_POI * (s.pois or 0)
	if s.extracted then
		xp *= C.XP_EXTRACT_MULT
	end
	return math.max(0, math.floor(xp + 1e-6))
end

-- What a participant takes home. Final once isOut(id) (or in Results); before
-- that it is the banked part only.
function MatchState.payout(self: MatchState, id: number): Payout?
	local m = self.members[id]
	if not m then
		return nil
	end
	return {
		id = id,
		squad = m.squad,
		cheese = m.banked,
		xp = m.xp,
		result = m.result or "unfinished",
		extracted = m.result == "extracted" or m.result == "lastHerd",
		lastHerd = m.result == "lastHerd",
		kills = m.kills,
		downs = m.downs,
		stagesCleared = m.stagesCleared,
		placement = self:placement(m.squad),
		summary = self:summary(id),
	}
end

function MatchState.payouts(self: MatchState): { Payout }
	local out = {}
	for _, id in self.order do
		table.insert(out, self:payout(id) :: Payout)
	end
	return out
end

-- Public view (S2C Match payload) ------------------------------------------------------------

-- `viewer` (an id) adds isYou and the `you` block. `aliveOf(id)` (optional)
-- tells whether a member is standing right now (World view); default: not dead.
function MatchState.getPublic(
	self: MatchState,
	viewer: number?,
	aliveOf: ((number) -> boolean)?
): { [string]: any }
	local route = self.run:currentRoute()
	local vm = if viewer ~= nil then self.members[viewer] else nil
	local squads = {}
	for i, sq in self.squads do
		local ids = {}
		local alive = 0
		for _, id in sq.members do
			local m = self.members[id]
			if not m.left then
				table.insert(ids, id)
				if inRun(sq) and m.result == nil then
					local up = if aliveOf then aliveOf(id) else not m.dead
					if up then
						alive += 1
					end
				end
			end
		end
		squads[i] = {
			id = sq.id,
			name = sq.name,
			color = table.clone(sq.color),
			members = ids,
			pending = self:squadPending(i),
			alive = inRun(sq),
			aliveCount = alive,
			extracted = sq.extracted,
			eliminated = sq.eliminated,
			empty = sq.empty,
			outReason = sq.outReason,
			doubleOrNothing = sq.doubleOrNothing,
			kills = sq.kills,
			isYou = vm ~= nil and vm.squad == i,
		}
	end
	local pub: { [string]: any } = {
		phase = self.phase,
		stage = self.stage,
		stages = C.STAGES,
		mapId = if route then route.mapId else nil,
		bossId = if route then route.bossId else nil,
		tier = if route then route.tier else nil,
		curses = self.run:activeCurses(),
		pressurePoints = self.run:pressurePoints(),
		squads = squads,
		routeChooser = if self.phase == "RouteChoice" then self.nextChooser else nil,
		bounties = self:bountyIds(),
		extractedCount = self:extractedCount(),
		brave = self:extractedCount() >= C.BRAVE_EXTRACTED,
		aloneStages = self.aloneStages,
		endReason = self.endReason,
	}
	if vm then
		pub.you = {
			id = vm.id,
			squad = vm.squad,
			share = vm.share,
			banked = vm.banked,
			streak = vm.streak,
			bounty = vm.bounty,
			kills = vm.kills,
			downs = vm.downs,
			result = vm.result,
			blessings = self:blessingsFor(vm.squad),
		}
	end
	return pub
end

return MatchState
