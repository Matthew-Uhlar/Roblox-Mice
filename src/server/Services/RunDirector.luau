--!strict
-- RunDirector: owns the v2 squad match loop (docs/GDD-v2.md §1–2,
-- docs/ARCHITECTURE-v2.md). It bridges the pure Run/MatchState (squads, cheese
-- shares, extraction, kills, payouts) and its shared RunState (route cards,
-- curses, Pressure) with the combat World, and owns per-hero run data: level,
-- xp, upgrade stacks, offers, rerolls, Second Wind, gear and shrine buffs.
--
--   lobby start -> MatchState.new(12 seats = 4 squads x 3) -> begin (stage 1 card)
--   -> [ drop-in at squad corners -> waves (150 s) -> boss at the centre
--        -> winner (killing blow, else top damage) gets the chest
--        -> the winner picks the next route (VoteOpen to that squad's humans)
--        -> extraction window (Extract / Stay / Double or Nothing per squad) ]x4
--   -> Results -> lobby
--
-- Squads out of the run (extracted, eliminated, left) are paid at once and
-- their humans go back to the lobby after OUT_RESULTS_SECONDS; the match keeps
-- going for the others. The match ends after stage 4, when every squad is out,
-- on Last Herd Standing, or when no human is left in it.
--
-- Safety rules carried over from v1: every remote goes through Guard.connect and
-- is checked against the current phase and the state we actually offered; the
-- server is the authority (World + MatchState); each human is paid exactly once
-- (pr.awarded before awardRun, pcall per player); run state replicates only to
-- humans in the run; LobbyService.teleportCharacter suspends trails; MoveGuard
-- violations make a run unranked.
--
-- Bots (ids in the Ids.isBot band) are world participants with no Player. They
-- get class stats (no talents), auto-pick upgrades, equip the gear they find,
-- follow their humans' votes (a bot-only squad decides alone, never Double or
-- Nothing) and never earn rewards or touch Data/Monetization services.
--
-- Optional modules from other teams are guarded (the round may land them later):
-- Run/Gear (R2), Data/ClassProgress (R3), LightingService (R4), Visuals/HeroDecor
-- (R4), and the v2 World API (addPlayer's 7th squad argument, setSquad, giveGear,
-- resolveSwap, gearOf, addLootBag, bossInfo().damageBySquad, setSafeZones).
--
-- Clocks: os.clock() for local deadlines; workspace:GetServerTimeNow() for every
-- timestamp sent to clients (phaseEndsAt, vote/extract endsAt, swap offers).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Rng = require(Shared:WaitForChild("Util"):WaitForChild("Rng")) :: any
local Ids = require(Shared:WaitForChild("Util"):WaitForChild("Ids")) :: any
local Squads = require(Shared:WaitForChild("Util"):WaitForChild("Squads")) :: any

local RunFolder = Shared:WaitForChild("Run")
local ConfigFolder = Shared:WaitForChild("Config")
local CombatFolder = Shared:WaitForChild("Combat")
local DataFolder = Shared:WaitForChild("Data")

local RunState = require(RunFolder:WaitForChild("RunState")) :: any
local MatchState = require(RunFolder:WaitForChild("MatchState")) :: any
local Vote = require(RunFolder:WaitForChild("Vote")) :: any
local Stats = require(RunFolder:WaitForChild("Stats")) :: any
local Leveling = require(RunFolder:WaitForChild("Leveling")) :: any
local UpgradeOffers = require(RunFolder:WaitForChild("UpgradeOffers")) :: any
local EpicDrop = require(RunFolder:WaitForChild("EpicDrop")) :: any
local Maps = require(ConfigFolder:WaitForChild("Maps")) :: any
local Bosses = require(ConfigFolder:WaitForChild("Bosses")) :: any
local World = require(CombatFolder:WaitForChild("World")) :: any
local MoveGuard = require(CombatFolder:WaitForChild("MoveGuard")) :: any
local CombatService = require(script.Parent:WaitForChild("CombatService")) :: any
local ArenaBuilder = require(script.Parent:WaitForChild("ArenaBuilder")) :: any
local Guard = require(script.Parent.Guard)
local Remotes = require(script.Parent.Remotes)
local LobbyService = require(script.Parent.LobbyService)
local BotBrain = require(Shared:WaitForChild("Bots"):WaitForChild("BotBrain")) :: any
local BotRoster = require(Shared:WaitForChild("Bots"):WaitForChild("BotRoster")) :: any
local Pois = require(CombatFolder:WaitForChild("Pois")) :: any
local PoiDefs = require(ConfigFolder:WaitForChild("Pois")) :: any
local RunTokens = require(DataFolder:WaitForChild("RunTokens")) :: any

local function optionalRequire(parent: Instance?, name: string): any
	local inst = parent and parent:FindFirstChild(name)
	if not inst or not inst:IsA("ModuleScript") then
		return nil
	end
	local ok, mod = pcall(require, inst)
	if not ok then
		warn(string.format("[RunDirector] failed to load %s: %s", name, tostring(mod)))
		return nil
	end
	return mod
end

-- Optional modules (degrade gracefully when absent)
local Modifiers: any = optionalRequire(ConfigFolder, "Modifiers")
local Cosmetics: any = optionalRequire(ConfigFolder, "Cosmetics")
local TalentDefs: any = optionalRequire(ConfigFolder, "Talents")
local Gear: any = optionalRequire(RunFolder, "Gear") -- R2
local ClassProgress: any = optionalRequire(DataFolder, "ClassProgress") -- R3
local DataService: any = optionalRequire(script.Parent, "DataService")
local MonetizationService: any = optionalRequire(script.Parent, "MonetizationService")
local BotService: any = optionalRequire(script.Parent, "BotService")
local LightingService: any = optionalRequire(script.Parent, "LightingService") -- R4
local HeroDecor: any = optionalRequire(script.Parent.Parent:FindFirstChild("Visuals"), "HeroDecor") -- R4

-- Stats.compute wants { [talentId]: { perLevel } }: Talents.defs, not the module.
local talentDefTable: any = nil
if type(TalentDefs) == "table" then
	if type(TalentDefs.defs) == "table" then
		talentDefTable = TalentDefs.defs
	elseif type(TalentDefs.ORDER) == "table" and type(TalentDefs.get) == "function" then
		talentDefTable = {}
		for _, id in TalentDefs.ORDER do
			talentDefTable[id] = TalentDefs.get(id)
		end
	end
end

local RunDirector = {}

-- Tunables ------------------------------------------------------------------------
RunDirector.WAVE_SECONDS = 150
RunDirector.BOSS_SECONDS = 180 -- boss still alive: the top damage squad wins (GDD-v2 §1)
RunDirector.VOTE_SECONDS = 15 -- the winning squad's route choice
RunDirector.ROUTE_DEFAULT_SECONDS = 2 -- nobody won: the Low card, after a short beat
RunDirector.EXTRACT_SECONDS = 20 -- Rind Gate extraction window
RunDirector.STAGE_CLEAR_SECONDS = 4
RunDirector.RESULTS_SECONDS = 8
RunDirector.OUT_RESULTS_SECONDS = 8 -- an out squad's humans see Results this long, then the lobby
RunDirector.SWAP_SECONDS = 4 -- gear swap prompt
RunDirector.WIPE_GRACE = 1.5 -- fallback squad wipe: everyone down this long
RunDirector.WIPE_GRACE_SECOND_WIND = 5 -- ...or this long if a downed human can still Second Wind
RunDirector.PVP_WIPE_GRACE = 12 -- safety net when the World reports squadEliminated itself
RunDirector.BOSS_FALLBACK_DELAY = 6 -- after this, "no boss alive" also counts as a kill
RunDirector.FREE_REROLLS_PER_STAGE = 1
RunDirector.OFFER_CARDS = 3
RunDirector.HUD_INTERVAL = 0.2 -- 5 Hz
RunDirector.HUD_KEEPALIVE = 1.0
RunDirector.PARTY_INTERVAL = 0.5
RunDirector.BOT_WEIGHT = if type(World.BOT_WEIGHT) == "number" then World.BOT_WEIGHT else 0.6
RunDirector.BOT_VOTE_MIN = 1
RunDirector.BOT_VOTE_MAX = 4
RunDirector.UNRANKED_VIOLATIONS = MoveGuard.UNRANKED_VIOLATIONS
RunDirector.POI_SALT = 0x9017 -- Rng.new(stageSeed):fork(POI_SALT) -> Pois.layout (the sim uses the same)
RunDirector.PORTAL_PULL_SECONDS = 1.5
RunDirector.PORTAL_GOLD = { 255, 204, 51 }
RunDirector.SPAWN_RING = 4 -- studs between squadmates at drop-in
RunDirector.CORNER_FRAC = 0.6 -- fallback squad corner: this x arena radius from the centre
RunDirector.PORTAL_COLORS = {
	Extract = { 255, 204, 51 },
	Stay = { 110, 220, 110 },
	DoubleOrNothing = { 235, 60, 50 },
}
RunDirector.CART_PRICES = { Common = 75, Rare = 150, Epic = 250, Legendary = 400 } -- fallback only
local RARITY_RANK = { Common = 1, Rare = 2, Epic = 3, Legendary = 4 }
local GEAR_SLOTS = { "weapon", "armor", "trinket" }
local DEFAULT_WALKSPEED = 16
local AIM_LIMIT = 100000
local LIVE_PHASES = { Waves = true, Boss = true, RouteChoice = true, Extraction = true }

-- Types ------------------------------------------------------------------------------

type Offer = { offerId: number, cards: { any }, source: string? }

-- A human in the match.
type PlayerRun = {
	player: Player,
	id: number,
	userId: number,
	isBot: boolean,
	name: string,
	squad: number,
	classId: string,
	classState: any?, -- ClassProgress.classState at run start (perks, ability, level)
	skin: string?,
	level: number,
	xp: number,
	stacks: { [string]: number },
	stats: any,
	weapon: any,
	ability: any,
	gear: { [string]: any }, -- slot -> item (run-only)
	pendingLevels: number,
	offer: Offer?,
	offerRng: any,
	freeRerollsLeft: number,
	tokens: any, -- RunTokens.State
	usedSecondWindToken: boolean,
	moveViolations: number,
	awarded: boolean,
	out: boolean, -- out of the run (extracted / eliminated / left)
	leavePayout: any?,
	lastHud: { [string]: any }?,
	lastHudAt: number,
	bonusOffers: { string },
	swapOffer: { item: any, slot: string, current: any?, endsAt: number, token: number }?,
	matchSig: string?,
}

-- A bot: no Player, an Ids.isBot id, no rewards.
type BotRun = {
	id: number,
	isBot: boolean,
	name: string,
	squad: number,
	classId: string,
	classState: any?,
	skin: string?,
	level: number,
	xp: number,
	stacks: { [string]: number },
	stats: any,
	weapon: any,
	ability: any,
	gear: { [string]: any },
	offerRng: any,
}

type VoteState = {
	vote: any,
	kind: string,
	options: { any },
	voters: { [number]: boolean },
	humans: { Player },
	bots: { BotRun },
	humanVotes: { [number]: number },
	botVoted: { [number]: boolean },
	token: number,
}

type ExtractState = {
	votes: { [number]: any }, -- squad -> Vote
	humanVotes: { [number]: { [number]: number } }, -- squad -> userId -> option
	botVoted: { [number]: boolean },
	botChoice: { [number]: string }, -- bot-only squads decide once
	token: number,
}

type Ctx = {
	seed: number,
	match: any,
	run: any, -- match.run (shared RunState)
	rng: any,
	voteRng: any,
	botRng: any,
	gearRng: any,
	epicRng: any,
	discoverRng: any,
	members: { [Player]: PlayerRun },
	order: { Player },
	bots: { BotRun },
	heroes: { [number]: any }, -- id -> PlayerRun | BotRun
	world: any?,
	arena: any?,
	card: any?,
	pvpWorld: boolean,
	phaseEndsAt: number?,
	voting: VoteState?,
	extract: ExtractState?,
	voteToken: number,
	bossDead: boolean,
	bossKill: any?, -- the bossDead event (killerSquad, damageBySquad)
	bossSpawnedAt: number,
	downSince: { [number]: number },
	bossesKilled: number,
	startedAt: number,
	cycle1Time: number?,
	stageIndex: number,
	nextOfferId: number,
	aborted: boolean,
	finished: boolean,
	awarded: boolean,
	fatal: string?,
	lastPartyAt: number,
	lastParty: { [number]: string },
	buffs: { [number]: { any } }, -- squad -> active shrine buffs
	portal: { x: number, z: number, key: string }?,
	carts: { [any]: any }, -- poi id -> {offers, prices, squad, bought}
	totemSquad: number?,
	swapToken: number,
}

local ctx: Ctx? = nil
-- Humans who left mid-run, kept until DataService's beforeRelease pays them.
local departed: { [Player]: { c: Ctx, pr: PlayerRun } } = {}

-- Helpers ----------------------------------------------------------------------------

local function finite(v: any): boolean
	return Guard.isFiniteNumber(v)
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function simNow(): number
	if type(CombatService.now) == "function" then
		local ok, t = pcall(CombatService.now)
		if ok and type(t) == "number" then
			return t
		end
	end
	return serverNow()
end

-- Tolerant config lookup: Config.get(id), Config[id], BY_ID, or a list of defs.
local function lookupDef(config: any, id: any): any
	if type(config) ~= "table" or id == nil then
		return nil
	end
	if type(config.get) == "function" then
		local ok, def = pcall(config.get, id)
		if ok and type(def) == "table" then
			return def
		end
	end
	local direct = config[id]
	if type(direct) == "table" and (direct.id == nil or direct.id == id) then
		return direct
	end
	for _, key in { "BY_ID", "byId", "DEFS", "defs" } do
		local t = config[key]
		if type(t) == "table" and type(t[id]) == "table" then
			return t[id]
		end
	end
	for _, key in { "LIST", "list", "ALL", "all" } do
		local t = config[key]
		if type(t) == "table" then
			for _, d in t do
				if type(d) == "table" and d.id == id then
					return d
				end
			end
		end
	end
	return nil
end

local function defName(config: any, id: any): string
	local d = lookupDef(config, id)
	if d and type(d.name) == "string" then
		return d.name
	end
	return tostring(id)
end

local function squadName(squad: any): string
	local def = Squads.get(squad)
	return if def then def.name else "?"
end

-- Only real Player objects reach Data/Monetization services.
local function isHuman(player: any): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	if DataService and type(DataService.isRealPlayer) == "function" then
		local ok, real = pcall(DataService.isRealPlayer, player)
		if ok then
			return real == true
		end
	end
	return true
end

local function getProfile(player: Player): any
	if not isHuman(player) then
		return nil
	end
	if DataService and type(DataService.get) == "function" then
		local ok, p = pcall(DataService.get, player)
		if ok then
			return p
		end
	end
	return nil
end

local function profileUpdate(player: Player, fn: (any) -> ()): boolean
	if not isHuman(player) or not (DataService and type(DataService.update) == "function") then
		return false
	end
	local ok, err = pcall(DataService.update, player, fn)
	if not ok then
		warn("[RunDirector] DataService.update failed: " .. tostring(err))
		return false
	end
	if type(DataService.push) == "function" then
		pcall(DataService.push, player)
	end
	return true
end

local function cheeseMult(player: Player): number
	if isHuman(player) and MonetizationService and type(MonetizationService.cheeseMult) == "function" then
		local ok, m = pcall(MonetizationService.cheeseMult, player)
		if ok and finite(m) and m > 0 then
			return m
		end
	end
	return 1
end

local function xpMult(player: Player): number
	if isHuman(player) and MonetizationService and type(MonetizationService.xpMult) == "function" then
		local ok, m = pcall(MonetizationService.xpMult, player)
		if ok and finite(m) and m > 0 then
			return m
		end
	end
	return 1
end

local function awardRun(player: Player, cheese: number, xp: number, stats: { [string]: any })
	if not isHuman(player) then
		return -- bots earn nothing
	end
	if DataService and type(DataService.awardRun) == "function" then
		local ok, err = pcall(DataService.awardRun, player, cheese, xp, stats)
		if not ok then
			warn("[RunDirector] DataService.awardRun failed: " .. tostring(err))
		end
	else
		warn(
			string.format(
				"[RunDirector] DataService missing: %s would get %d cheese, %d xp",
				player.Name,
				cheese,
				xp
			)
		)
	end
end

local function isRanked(pr: PlayerRun): boolean
	return not pr.usedSecondWindToken and pr.moveViolations < RunDirector.UNRANKED_VIOLATIONS
end

-- Humans still in the run (connected, not out).
local function memberList(c: Ctx): { Player }
	local list = {}
	for _, p in c.order do
		local pr = c.members[p]
		if pr and not pr.out and p.Parent == Players then
			table.insert(list, p)
		end
	end
	return list
end

-- Every connected human of the match (in the run or already out).
local function connectedMembers(c: Ctx): { Player }
	local list = {}
	for _, p in c.order do
		if c.members[p] and p.Parent == Players then
			table.insert(list, p)
		end
	end
	return list
end

local function squadHumans(c: Ctx, squad: number): { Player }
	local list = {}
	for _, p in memberList(c) do
		if c.members[p].squad == squad then
			table.insert(list, p)
		end
	end
	return list
end

local function botsInRun(c: Ctx): { BotRun }
	local list = {}
	for _, b in c.bots do
		if c.match:isInRun(b.id) then
			table.insert(list, b)
		end
	end
	return list
end

local function squadBots(c: Ctx, squad: number): { BotRun }
	local list = {}
	for _, b in botsInRun(c) do
		if b.squad == squad then
			table.insert(list, b)
		end
	end
	return list
end

local function heroOf(c: Ctx, id: any): any
	return if type(id) == "number" then c.heroes[id] else nil
end

local function memberById(c: Ctx, id: any): PlayerRun?
	local h = heroOf(c, id)
	return if h and not h.isBot then h else nil
end

local function heroName(h: any): string
	if not h then
		return "?"
	end
	if h.isBot then
		return h.name
	end
	return if h.player then h.player.DisplayName else h.name
end

local function toastAll(c: Ctx, text: string, kind: string?)
	Remotes.toast(memberList(c), text, kind :: any)
end

local function toastSquad(c: Ctx, squad: number?, text: string, kind: string?)
	if squad then
		Remotes.toast(squadHumans(c, squad), text, kind :: any)
	end
end

local function phaseOf(c: Ctx): string
	local m = c.match
	return if m and type(m.phase) == "string" then m.phase else "Lobby"
end

local function stageKey(c: Ctx): string
	return "s" .. tostring(c.stageIndex)
end

local NO_PROFILE = table.freeze({ secondWindTokens = 0, rerollTokens = 0 })

local function tokenProfile(player: Player): any
	local profile = getProfile(player)
	if type(profile) == "table" then
		return {
			secondWindTokens = if finite(profile.secondWindTokens) then profile.secondWindTokens else 0,
			rerollTokens = if finite(profile.rerollTokens) then profile.rerollTokens else 0,
		}
	end
	return NO_PROFILE
end

local function cloneTokens(st: any): any
	local out = table.clone(st)
	out.revivesByStage = table.clone(st.revivesByStage)
	out.rerollsByStage = table.clone(st.rerollsByStage)
	return out
end

-- CombatService writes WalkSpeed every frame while a world runs.
local function combatOwnsSpeed(): boolean
	if type(CombatService.getWorld) ~= "function" then
		return false
	end
	local ok, w = pcall(CombatService.getWorld)
	return ok and w ~= nil
end

local function setHumanoidSpeed(player: Player, speed: number)
	if combatOwnsSpeed() then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = speed
	end
end

local function lobbyRunState(): { [string]: any }
	return {
		phase = "Lobby",
		cycle = 1,
		stageInCycle = 1,
		pendingCheese = 0,
		bankedCheese = 0,
		doubleOrNothing = false,
		activeCurses = {},
		activeBlessings = {},
	}
end

-- Per-recipient RunState: the v1 HUD fields, with the squad's view of the pot.
local function publicState(c: Ctx, pr: PlayerRun): { [string]: any }
	local pub = table.clone(c.run:getPublic())
	local m = c.match:member(pr.userId)
	pub.phase = phaseOf(c)
	pub.phaseEndsAt = c.phaseEndsAt
	pub.stageInCycle = c.match.stage
	pub.stages = MatchState.CONFIG.STAGES
	pub.pendingCheese = if m then m.share else 0
	pub.bankedCheese = if m then m.banked else 0
	pub.squadPending = c.match:squadPending(pr.squad)
	pub.doubleOrNothing = c.match:squadDoubleOrNothing(pr.squad)
	pub.activeBlessings = c.match:blessingsFor(pr.squad)
	pub.squad = pr.squad
	return pub
end

local function aliveOf(c: Ctx): (number) -> boolean
	return function(id: number): boolean
		local world = c.world
		local info = if world then world:getPlayer(id) else nil
		if info then
			return not info.downed and not info.dead
		end
		local m = c.match:member(id)
		return m ~= nil and not m.dead
	end
end

local function matchPayload(c: Ctx, pr: PlayerRun): { [string]: any }
	local pub = c.match:getPublic(pr.userId, aliveOf(c))
	pub.totem = c.totemSquad
	pub.phaseEndsAt = c.phaseEndsAt
	return pub
end

-- A cheap change signature for the Match payload.
local function matchSig(pub: { [string]: any }): string
	local parts = {
		tostring(pub.phase),
		tostring(pub.stage),
		tostring(pub.routeChooser),
		tostring(pub.totem),
		tostring(pub.phaseEndsAt),
		table.concat(pub.bounties or {}, ","),
	}
	for _, sq in pub.squads do
		table.insert(
			parts,
			string.format(
				"%d:%d:%s:%d:%s:%s:%s:%d",
				sq.id,
				sq.pending,
				tostring(sq.alive),
				sq.aliveCount,
				tostring(sq.extracted),
				tostring(sq.eliminated),
				tostring(sq.doubleOrNothing),
				sq.kills
			)
		)
	end
	local you = pub.you
	if you then
		table.insert(
			parts,
			string.format("%d:%d:%d:%s", you.share, you.banked, you.streak, tostring(you.bounty))
		)
	end
	return table.concat(parts, "|")
end

-- Match payload to every human in the run (on change unless forced).
local function sendMatch(c: Ctx, force: boolean?)
	for _, p in memberList(c) do
		local pr = c.members[p]
		local ok, pub = pcall(matchPayload, c, pr)
		if ok then
			local sig = matchSig(pub)
			if force or sig ~= pr.matchSig then
				pr.matchSig = sig
				Remotes.match(p, pub :: any)
			end
		end
	end
end

-- RunState + Match to the run's humans only (lobby players keep the lobby view).
local function broadcastRunState(c: Ctx)
	for _, p in memberList(c) do
		Remotes.runState(publicState(c, c.members[p]), p)
	end
	sendMatch(c, true)
end

local function setPhaseTimer(c: Ctx, seconds: number?): number?
	if seconds then
		c.phaseEndsAt = serverNow() + seconds
	else
		c.phaseEndsAt = nil
	end
	c.run.phaseEndsAt = c.phaseEndsAt
	return if seconds then os.clock() + seconds else nil
end

-- Waits until deadline/predicate/abort/fatal. Returns "timeout" | "pred" | "abort" | "fatal".
local function waitFor(c: Ctx, deadline: number?, pred: (() -> boolean)?): string
	while true do
		if c.aborted then
			return "abort"
		end
		if c.fatal then
			return "fatal"
		end
		if pred and pred() then
			return "pred"
		end
		if deadline and os.clock() >= deadline then
			return "timeout"
		end
		task.wait(0.1)
	end
end

-- Stats + gear + upgrades ---------------------------------------------------------------

local function withBuffs(c: Ctx, squad: number, stats: any): any
	local list = c.buffs[squad]
	if not list or #list == 0 then
		return stats
	end
	local ok, out = pcall(Pois.applyBuffs, stats, list, simNow())
	return if ok and type(out) == "table" then out else stats
end

-- Stats.compute (R3, 6th arg classState) -> Gear.apply (R2) -> squad shrine buffs.
local function computeStats(c: Ctx, h: any)
	local talents = {}
	if not h.isBot then
		local profile = getProfile(h.player)
		if profile and type(profile.talents) == "table" then
			talents = profile.talents
		end
	end
	local stats, weapon, ability = Stats.compute(
		h.classId,
		h.stacks,
		c.match:blessingsFor(h.squad),
		talents,
		talentDefTable,
		h.classState
	)
	if Gear and type(Gear.apply) == "function" and next(h.gear) ~= nil then
		local ok, s2, w2, a2 = pcall(Gear.apply, stats, weapon, ability, h.gear)
		if ok and type(s2) == "table" then
			stats = s2
			weapon = w2 or weapon
			ability = a2 or ability
		end
	end
	h.stats, h.weapon, h.ability = withBuffs(c, h.squad, stats), weapon, ability
	-- Portal Charm (Config/Gear extractBonus): Extract keeps 1 + bonus of the share.
	local bonus = if type(stats) == "table" and finite(stats.extractBonus) then stats.extractBonus else 0
	c.match:setExtractMult(h.id, 1 + math.max(0, bonus))
end

local function isDowned(c: Ctx, id: number): boolean
	local world = c.world
	if not world then
		return false
	end
	local info = world:getPlayer(id)
	return info ~= nil and (info.downed or info.dead)
end

-- Pushes a hero's stats to the world (and the humanoid's speed for humans).
local function pushStats(c: Ctx, h: any)
	local world = c.world
	if world then
		pcall(world.updatePlayer, world, h.id, h.stats, h.weapon)
		if type(world.setPlayerAbility) == "function" and h.ability then
			pcall(world.setPlayerAbility, world, h.id, h.ability)
		end
	end
	if not h.isBot and not isDowned(c, h.id) and h.stats and finite(h.stats.moveSpeed) then
		setHumanoidSpeed(h.player, h.stats.moveSpeed)
	end
end

local function offerLuck(c: Ctx, stats: any): number
	local luck = if stats and finite(stats.luck) then stats.luck else 0
	local ok, v = pcall(c.match.pressureLuck, c.match)
	return luck + (if ok and finite(v) then v else 0)
end

local function rerollsLeft(c: Ctx, pr: PlayerRun): number
	local ok, n = pcall(RunTokens.rerollsAvailable, pr.tokens, tokenProfile(pr.player), stageKey(c))
	return pr.freeRerollsLeft + (if ok and finite(n) then n else 0)
end

local function sendOffer(c: Ctx, pr: PlayerRun)
	local offer = pr.offer
	if not offer then
		return
	end
	Remotes.upgradeOffer(pr.player, {
		offerId = offer.offerId,
		cards = offer.cards,
		rerollsLeft = rerollsLeft(c, pr),
		queued = pr.pendingLevels + #pr.bonusOffers,
		source = offer.source,
	})
end

local function rollCards(c: Ctx, h: any, source: string?): { any }
	if source == "pantry" then
		local ok, cards = pcall(Pois.epicCards, h.offerRng, h.classId, h.stacks, RunDirector.OFFER_CARDS)
		return if ok and type(cards) == "table" then cards else {}
	end
	local luck = offerLuck(c, h.stats) + (if source == "chest" then 1 else 0)
	return UpgradeOffers.roll(h.offerRng, h.classId, h.stacks, luck, RunDirector.OFFER_CARDS)
end

local function presentNextOffer(c: Ctx, pr: PlayerRun)
	if pr.offer then
		return
	end
	local source, cards, levels = UpgradeOffers.nextQueued(
		pr.bonusOffers,
		pr.pendingLevels,
		function(src: string?)
			return rollCards(c, pr, src)
		end
	)
	pr.pendingLevels = levels
	if not cards then
		return
	end
	c.nextOfferId += 1
	pr.offer = { offerId = c.nextOfferId, cards = cards, source = source }
	sendOffer(c, pr)
end

local function grantXp(c: Ctx, pr: PlayerRun, amount: any)
	if not finite(amount) or amount <= 0 then
		return
	end
	local newLevel, newXp, gained = Leveling.addXp(pr.level, pr.xp, amount)
	pr.level, pr.xp = newLevel, newXp
	if gained and gained > 0 then
		local hadOffer = pr.offer ~= nil
		pr.pendingLevels += gained
		Remotes.toast(pr.player, string.format("Level %d!", newLevel), "good")
		if hadOffer then
			sendOffer(c, pr)
		else
			presentNextOffer(c, pr)
		end
	end
end

-- Bots pick the highest-rarity card at once (BotBrain.chooseUpgrade).
local function botLevelUp(c: Ctx, b: BotRun, source: string?)
	local cards = rollCards(c, b, source)
	if type(cards) ~= "table" or #cards == 0 then
		return
	end
	local card = cards[BotBrain.chooseUpgrade(cards, c.botRng)]
	if not card then
		return
	end
	b.stacks[card.id] = (b.stacks[card.id] or 0) + 1
	computeStats(c, b)
	pushStats(c, b)
	local world = c.world
	local heal = card.delta and card.delta.heal
	if world and finite(heal) and heal > 0 and type(world.healPlayer) == "function" then
		pcall(world.healPlayer, world, b.id, heal)
	end
end

local function grantBotXp(c: Ctx, b: BotRun, amount: any)
	if not finite(amount) or amount <= 0 then
		return
	end
	local newLevel, newXp, gained = Leveling.addXp(b.level, b.xp, amount)
	b.level, b.xp = newLevel, newXp
	for _ = 1, math.min(gained or 0, 10) do
		local ok, err = pcall(botLevelUp, c, b)
		if not ok then
			warn("[RunDirector] bot level-up failed: " .. tostring(err))
		end
	end
end

-- HUD ---------------------------------------------------------------------------------------

local function secondWindsAvailable(c: Ctx, pr: PlayerRun): number
	local ok, n = pcall(RunTokens.secondWindsAvailable, pr.tokens, tokenProfile(pr.player), stageKey(c))
	return if ok and finite(n) then math.max(0, math.floor(n)) else 0
end

local function hudPayload(c: Ctx, pr: PlayerRun): any
	local info = c.world and c.world:getPlayer(pr.userId)
	local maxHp = if pr.stats and finite(pr.stats.maxHp) then pr.stats.maxHp else 100
	local winds = secondWindsAvailable(c, pr)
	return {
		hp = if info then info.hp else maxHp,
		maxHp = if info then info.maxHp else maxHp,
		level = pr.level,
		xp = pr.xp,
		xpToNext = Leveling.xpToNext(pr.level),
		abilityReadyAt = if info then info.abilityReadyAt or 0 else 0,
		downed = if info then info.downed == true else false,
		downedUntil = if info then info.downedUntil else nil,
		secondWinds = winds,
		secondWindReady = winds > 0,
		rerolls = rerollsLeft(c, pr),
		squad = pr.squad,
		share = c.match:shareOf(pr.userId),
	}
end

local function shallowEqual(a: { [string]: any }?, b: { [string]: any }): boolean
	if not a then
		return false
	end
	for k, v in b do
		if a[k] ~= v then
			return false
		end
	end
	for k in a do
		if b[k] == nil then
			return false
		end
	end
	return true
end

local function sendHud(c: Ctx, pr: PlayerRun, force: boolean?)
	if pr.out then
		return
	end
	local payload = hudPayload(c, pr)
	local now = os.clock()
	if force or not shallowEqual(pr.lastHud, payload) or now - pr.lastHudAt >= RunDirector.HUD_KEEPALIVE then
		pr.lastHud = payload
		pr.lastHudAt = now
		Remotes.playerHud(pr.player, payload)
	end
end

-- PartyHud per squad: each squad's humans see their own squad.
local function sendPartyHud(c: Ctx, force: boolean?)
	local now = os.clock()
	for s = 1, Squads.MAX do
		local humans = squadHumans(c, s)
		if #humans > 0 then
			local payload: { [string]: any } = {}
			local sig = {}
			for _, id in c.match:squad(s).members do
				local h = c.heroes[id]
				if h and c.match:isInRun(id) then
					local info = c.world and c.world:getPlayer(id)
					local maxHp = if info then info.maxHp elseif h.stats then h.stats.maxHp else 100
					local entry = {
						name = heroName(h),
						classId = h.classId,
						hp = if info then math.floor(info.hp + 0.5) else maxHp,
						maxHp = maxHp,
						downed = if info then info.downed == true else false,
						dead = if info then info.dead == true else false,
						level = h.level,
						isBot = h.isBot,
						squad = s,
					}
					payload[tostring(id)] = entry
					table.insert(
						sig,
						string.format(
							"%d:%d/%d:%s:%s:%d",
							id,
							entry.hp,
							entry.maxHp,
							tostring(entry.downed),
							tostring(entry.dead),
							entry.level
						)
					)
				end
			end
			local key = table.concat(sig, "|")
			if force or key ~= c.lastParty[s] or now - c.lastPartyAt >= 2 then
				c.lastParty[s] = key
				Remotes.partyHud(payload :: any, humans)
			end
		end
	end
	if force or now - c.lastPartyAt >= 2 then
		c.lastPartyAt = now
	end
end

-- Inventory (gear) ----------------------------------------------------------------------------

local function sendInventory(_c: Ctx, pr: PlayerRun)
	if pr.out then
		return
	end
	local offer = pr.swapOffer
	Remotes.inventory(pr.player, {
		weapon = pr.gear.weapon,
		armor = pr.gear.armor,
		trinket = pr.gear.trinket,
		swapOffer = if offer then { item = offer.item, slot = offer.slot, endsAt = offer.endsAt } else nil,
	})
end

local function gearList(h: any): { any }
	local list = {}
	for _, slot in GEAR_SLOTS do
		if h.gear[slot] then
			table.insert(list, h.gear[slot])
		end
	end
	return list
end

local function itemName(item: any): string
	if type(item) ~= "table" then
		return "gear"
	end
	local name = if type(item.name) == "string" then item.name else nil
	if not name then
		local okC, Config = pcall(function()
			return require(ConfigFolder:FindFirstChild("Gear") :: ModuleScript) :: any
		end)
		local def = if okC then lookupDef(Config, item.id) else nil
		name = if def and type(def.name) == "string" then def.name else tostring(item.id)
	end
	return string.format("%s (%s)", name :: string, tostring(item.rarity or "?"))
end

-- Re-reads a hero's gear from the World (the truth while a stage runs).
local function syncGear(c: Ctx, h: any)
	local world = c.world
	if world and type(world.gearOf) == "function" then
		local ok, g = pcall(world.gearOf, world, h.id)
		if ok and type(g) == "table" then
			local clean = {}
			for _, slot in GEAR_SLOTS do
				if type(g[slot]) == "table" then
					clean[slot] = g[slot]
				end
			end
			h.gear = clean
		end
	end
end

local function refreshHero(c: Ctx, h: any)
	computeStats(c, h)
	pushStats(c, h)
	if not h.isBot then
		sendHud(c, h, true)
		sendInventory(c, h)
	end
end

-- Recompute every hero of a squad (buffs, blessings) and push them to the world.
local function refreshSquad(c: Ctx, squad: number?)
	for _, id in c.match:activeMembers(squad or 0) do
		local h = c.heroes[id]
		if h then
			refreshHero(c, h)
		end
	end
end

-- World calls ----------------------------------------------------------------------------------

-- Gives an item through the World (R2). Returns ok, offerSwap.
local function giveGear(c: Ctx, h: any, item: any): (boolean, boolean)
	local world = c.world
	if not world or type(world.giveGear) ~= "function" or type(item) ~= "table" then
		return false, false
	end
	local ok, given, swap = pcall(world.giveGear, world, h.id, item)
	if not ok then
		warn("[RunDirector] giveGear failed: " .. tostring(given))
		return false, false
	end
	syncGear(c, h)
	return given == true, swap == true
end

-- Squad corner for drop-in: ArenaBuilder's squadSpawns (R4), else a corner on a circle.
local function arenaCenter(c: Ctx): Vector3
	local arena = c.arena
	if arena then
		if typeof(arena.center) == "Vector3" then
			return arena.center
		end
		if typeof(arena.model) == "Instance" and arena.model:IsA("Model") then
			return arena.model:GetPivot().Position
		end
	end
	return Vector3.zero
end

local function squadCorner(c: Ctx, squad: number): Vector3
	local arena = c.arena
	local spawns = if arena then arena.squadSpawns else nil
	local sp = if type(spawns) == "table" then spawns[squad] else nil
	if typeof(sp) == "Vector3" then
		return sp
	elseif typeof(sp) == "CFrame" then
		return sp.Position
	elseif type(sp) == "table" and finite(sp.x) and finite(sp.z) then
		return Vector3.new(sp.x, if finite(sp.y) then sp.y else 0, sp.z)
	end
	local center = arenaCenter(c)
	local radius = if arena and finite(arena.radius) then arena.radius else 60
	local r = radius * RunDirector.CORNER_FRAC
	local angle = math.rad(45 + 90 * (squad - 1))
	local y = if arena and typeof(arena.spawn) == "Vector3" then arena.spawn.Y else center.Y
	return Vector3.new(center.X + math.cos(angle) * r, y, center.Z + math.sin(angle) * r)
end

local function heroSpawnPos(c: Ctx, h: any): Vector3
	local base = squadCorner(c, h.squad)
	local sq = c.match:squad(h.squad)
	local seat = if sq then table.find(sq.members, h.id) or 1 else 1
	local angle = (seat - 1) * (math.pi * 2 / 3)
	return base + Vector3.new(math.cos(angle), 0, math.sin(angle)) * RunDirector.SPAWN_RING
end

local function teleportToArena(c: Ctx, pr: PlayerRun)
	local pos = heroSpawnPos(c, pr)
	LobbyService.teleportCharacter(pr.player, pos) -- suspends the trail first
	if type(CombatService.placePlayer) == "function" then
		pcall(CombatService.placePlayer, pr.player, pos.X, pos.Z)
	end
end

local function decorate(_c: Ctx, pr: PlayerRun)
	if HeroDecor and type(HeroDecor.apply) == "function" and pr.player.Character then
		local ok, err = pcall(HeroDecor.apply, pr.player.Character, pr.classId, pr.skin, pr.squad)
		if not ok then
			warn("[RunDirector] HeroDecor.apply failed: " .. tostring(err))
		end
	end
end

local function applyLighting(mapId: string)
	if LightingService and type(LightingService.apply) == "function" then
		local ok, err = pcall(LightingService.apply, mapId)
		if not ok then
			warn("[RunDirector] LightingService.apply failed: " .. tostring(err))
		end
	end
end

local function stopCombat(c: Ctx)
	if c.world then
		pcall(CombatService.stop)
		c.world = nil
	end
	if BotService and type(BotService.setWorld) == "function" then
		pcall(BotService.setWorld, nil, nil)
	end
end

-- BotService runs the bots still in the run (spawnForRun keeps unchanged models
-- and drops the others: extracted / eliminated bots vanish).
local function syncBots(c: Ctx)
	if not BotService or type(BotService.spawnForRun) ~= "function" then
		return
	end
	local specs = {}
	for _, b in botsInRun(c) do
		table.insert(specs, {
			id = b.id,
			name = b.name,
			classId = b.classId,
			isBot = true,
			squad = b.squad,
			skin = b.skin,
		})
	end
	local ok, err = pcall(BotService.spawnForRun, specs, c.arena, c.world, c.seed + c.stageIndex)
	if not ok then
		warn("[RunDirector] BotService.spawnForRun failed: " .. tostring(err))
	end
end

local function removeFromWorld(c: Ctx, id: number)
	local world = c.world
	if world then
		pcall(world.removePlayer, world, id)
	end
end

-- Points of interest ------------------------------------------------------------------------

-- Squads a POI event rewards: the squad of `by` (contested POIs), else every squad in the run.
local function poiSquads(c: Ctx, e: any): { number }
	local s = c.match:squadOf(e.by)
	if s and c.match:isSquadInRun(s) then
		return { s }
	end
	return c.match:squadsInRun()
end

-- Rare POI found: profile.discoveries for the finding squad's humans (first find: unlock).
local function recordDiscovery(c: Ctx, kind: string, squads: { number })
	local def = PoiDefs.get(kind)
	if not def or not def.rare then
		return
	end
	local pool = {}
	if def.unlock and def.unlock.cosmetic and Cosmetics and type(Cosmetics.epicPool) == "function" then
		local ok, list = pcall(Cosmetics.epicPool)
		if ok and type(list) == "table" then
			pool = list
		end
	end
	for _, s in squads do
		for _, p in squadHumans(c, s) do
			if not isHuman(p) then
				continue
			end
			local isNew, cosmetic = false, nil
			profileUpdate(p, function(prof: any)
				if type(prof.discoveries) ~= "table" then
					prof.discoveries = {}
				end
				if prof.discoveries[kind] then
					return
				end
				prof.discoveries[kind] = true
				isNew = true
				if #pool > 0 then
					if type(prof.cosmetics) ~= "table" then
						prof.cosmetics = {}
					end
					local unowned = {}
					for _, id in pool do
						if not prof.cosmetics[id] then
							table.insert(unowned, id)
						end
					end
					if #unowned > 0 then
						cosmetic = unowned[c.discoverRng:nextInt(1, #unowned)]
						prof.cosmetics[cosmetic] = true
					end
				end
			end)
			if isNew then
				local text = "New discovery: " .. def.name .. "!"
				if cosmetic then
					local cdef = lookupDef(Cosmetics, cosmetic)
					text ..= " Unlocked: " .. (if cdef and type(cdef.name) == "string"
						then cdef.name
						else cosmetic)
				elseif def.unlock and def.unlock.title then
					text ..= " Title unlocked: " .. def.unlock.title
				end
				Remotes.toast(p, text, "good")
				Remotes.fx({ { t = "discovered", kind = kind, isNew = true } }, p)
				local okC, CosmeticsService = pcall(require, script.Parent.CosmeticsService)
				if
					okC
					and type(CosmeticsService) == "table"
					and type(CosmeticsService.refresh) == "function"
				then
					pcall(CosmeticsService.refresh, p)
				end
			end
		end
	end
end

local function onPoiActivated(c: Ctx, e: any)
	local kind = tostring(e.kind)
	local def = PoiDefs.get(kind)
	if not def then
		return
	end
	if def.mode == "camp" then
		toastAll(c, "An Elite Camp wakes up! Clear it for a chest!", "bad")
	end
	if def.rare then
		local ok, err = pcall(recordDiscovery, c, kind, poiSquads(c, e))
		if not ok then
			warn("[RunDirector] discovery failed: " .. tostring(err))
		end
	end
end

local function cartPrice(item: any, given: any): number
	if finite(given) and given > 0 then
		return math.floor(given)
	end
	if type(item) == "table" and finite(item.price) and item.price > 0 then
		return math.floor(item.price)
	end
	return RunDirector.CART_PRICES[if type(item) == "table" then item.rarity else ""] or 150
end

local function sendCart(c: Ctx, pr: PlayerRun, poi: any)
	local cart = c.carts[poi]
	if not cart then
		return
	end
	Remotes.shopCart(pr.player, {
		poi = poi,
		offers = cart.offers,
		prices = cart.prices,
		bought = cart.bought,
		share = c.match:shareOf(pr.userId),
	})
end

-- A Shop Cart opened (poiReward kind shop_cart_open {poi, by, offers}).
local function openCart(c: Ctx, e: any)
	local squad = c.match:squadOf(e.by)
	if not squad or not c.match:isSquadInRun(squad) or e.poi == nil then
		return
	end
	local offers = if type(e.offers) == "table" then e.offers else {}
	local prices = if type(e.prices) == "table" then e.prices else nil
	if #offers == 0 and Gear and type(Gear.cartOffers) == "function" then
		local route = c.match:currentRoute()
		local ok, o, pz = pcall(Gear.cartOffers, c.gearRng, route and route.tier, c.match.stage)
		if ok and type(o) == "table" then
			offers, prices = o, pz
		end
	end
	local list = {}
	for i, item in offers do
		list[i] = cartPrice(item, prices and prices[i])
	end
	c.carts[e.poi] = { offers = offers, prices = list, squad = squad, bought = {} }
	local pr = memberById(c, e.by)
	if pr and not pr.out then
		sendCart(c, pr, e.poi)
	end
	toastSquad(c, squad, "A Shop Cart! Spend pending cheese on gear.", "info")
end

-- World-side effects already happened (heals, revives, crumbs); this pays the meta part.
local function onPoiReward(c: Ctx, e: any)
	local kind = tostring(e.kind)
	if kind == "shop_cart_open" or e.reward == "cart" then
		openCart(c, e)
		return
	elseif kind == "totem_owner" then
		local s = if Squads.isValid(e.squad) then e.squad else nil
		if s ~= c.totemSquad then
			c.totemSquad = s
			if s then
				toastAll(c, squadName(s) .. " holds the Power Totem! (+15% damage)", "info")
			end
			sendMatch(c, true)
		end
		return
	end
	c.match:notePoi(e.by)
	local def = PoiDefs.get(kind)
	local reward = if def then def.reward else nil
	local squads = poiSquads(c, e)
	local name = if def then def.name else kind
	if finite(e.cheese) and e.cheese > 0 then
		-- Cheese caches, the Cheese Vault: every member of the finding squad, Pressure applied.
		local amount = RunState.applyPressureCheese(math.floor(e.cheese), c.match:pressurePoints())
		for _, s in squads do
			c.match:addSquadCheese(s, amount)
			toastSquad(c, s, string.format("%s: +%d Cheese each (pending)", name, amount), "good")
		end
		if kind == "vault" or reward == "vault" then
			toastAll(c, squadName(squads[1]) .. " cracked the Cheese Vault!", "info")
		end
		sendMatch(c)
	end
	if reward == "buff" and type(e.buff) == "table" then
		local b = e.buff
		if type(b.stat) == "string" and finite(b.untilT) then
			for _, s in squads do
				c.buffs[s] = c.buffs[s] or {}
				Pois.addBuff(c.buffs[s], {
					kind = kind,
					stat = b.stat,
					mul = if finite(b.mul) then b.mul else nil,
					addFracMaxHp = if finite(b.addFracMaxHp) then b.addFracMaxHp else nil,
					untilT = b.untilT,
				}, simNow())
				refreshSquad(c, s)
				toastSquad(
					c,
					s,
					name .. "! " .. (def and def.description or ""):gsub("^Touch it: ", ""),
					"good"
				)
			end
		end
	elseif reward == "elite_chest" or reward == "epic_pick" then
		local source = if reward == "epic_pick" then "pantry" else "chest"
		for _, s in squads do
			for _, p in squadHumans(c, s) do
				local pr = c.members[p]
				table.insert(pr.bonusOffers, source)
				if pr.offer then
					sendOffer(c, pr)
				else
					presentNextOffer(c, pr)
				end
			end
			for _, b in squadBots(c, s) do
				local ok, err = pcall(botLevelUp, c, b, source)
				if not ok then
					warn("[RunDirector] bot POI pick failed: " .. tostring(err))
				end
			end
			toastSquad(
				c,
				s,
				if source == "pantry"
					then "Grandma's Pantry! Your squad picks an EPIC upgrade!"
					elseif e.fled == true then "The camp's elites fled, leaving their chest! A free upgrade!"
					else "Elite Camp cleared! A free upgrade for your squad!",
				"good"
			)
		end
	elseif reward == "revive" then
		local key = stageKey(c)
		for _, s in squads do
			for _, p in squadHumans(c, s) do
				local pr = c.members[p]
				pr.tokens.freeUsed = 0
				pr.tokens.revivesByStage[key] = 0
				sendHud(c, pr, true)
			end
			toastSquad(c, s, "The Lost Herd answers! Your squad is up and Second Wind is refilled!", "good")
		end
		sendPartyHud(c, true)
	end
end

-- Portal (Rind Gate) ---------------------------------------------------------------------------

local function portalTint(kind: string?, option: any): { number }?
	if kind == "route" and type(option) == "table" then
		local def = lookupDef(Maps, option.mapId)
		if def and type(def.accentColor) == "table" then
			return def.accentColor
		end
		return nil
	end
	return RunDirector.PORTAL_COLORS[tostring(option)]
end

local function setPortal(c: Ctx, phase: string, color: { number }?)
	local world, portal = c.world, c.portal
	if not world or not portal then
		return
	end
	local col = color or RunDirector.PORTAL_GOLD
	pcall(world.setPortal, world, portal.x, portal.z, phase, col)
	pcall(ArenaBuilder.setPortalColor, Color3.fromRGB(col[1], col[2], col[3]))
	portal.key = table.concat(col, ",")
end

local function openPortal(c: Ctx, center: Vector3)
	local world = c.world
	if not world or type(world.setPortal) ~= "function" then
		return
	end
	c.portal = { x = center.X, z = center.Z, key = "" }
	if type(ArenaBuilder.buildPortal) == "function" then
		local col = RunDirector.PORTAL_GOLD
		local ok, err =
			pcall(ArenaBuilder.buildPortal, center.X, center.Z, Color3.fromRGB(col[1], col[2], col[3]))
		if not ok then
			warn("[RunDirector] buildPortal failed: " .. tostring(err))
		end
	end
	setPortal(c, "open", RunDirector.PORTAL_GOLD)
end

-- Payouts -----------------------------------------------------------------------------------------

local function classXpFor(summary: any): number
	if ClassProgress and type(ClassProgress.runXp) == "function" then
		local ok, xp = pcall(ClassProgress.runXp, summary)
		if ok and finite(xp) then
			return math.max(0, math.floor(xp))
		end
	end
	return MatchState.classXpFallback(summary)
end

-- Pays one human (once: pr.awarded is set before awardRun) from MatchState:payout.
local function payMember(c: Ctx, pr: PlayerRun)
	if pr.awarded then
		return
	end
	local p = pr.player
	local po = pr.leavePayout or c.match:payout(pr.userId)
	if not po then
		return
	end
	pr.awarded = true
	local statMult = if pr.stats
			and finite(pr.stats.cheeseMult)
			and pr.stats.cheeseMult > 0
		then pr.stats.cheeseMult
		else 1
	local mult = cheeseMult(p) * statMult
	local cheese = math.max(0, math.floor(po.cheese * mult + 0.5))
	local xp = math.max(0, math.floor(po.xp * xpMult(p) + 0.5))
	local classXp = classXpFor(po.summary)
	awardRun(p, cheese, xp, {
		won = po.extracted,
		cycle = 1,
		bosses = po.stagesCleared,
		cycle1Time = if po.extracted and po.stagesCleared >= MatchState.CONFIG.STAGES
			then c.cycle1Time
			else nil,
		ranked = isRanked(pr),
		withBots = #c.bots > 0,
		day = math.floor(os.time() / 86400),
		pressurePoints = c.match:pressurePoints(),
		-- v2 (R3: DataService adds the class XP; leaderboards)
		classId = pr.classId,
		classXp = classXp,
		stagesSurvived = po.summary.stagesSurvived,
		bossDamageShare = po.summary.bossDamageShare,
		heroDowns = po.downs,
		pois = po.summary.pois,
		extracted = po.extracted,
		lastHerd = po.lastHerd,
		pvpDowns = po.downs,
		pvpKills = po.kills,
		squad = po.squad,
		result = po.result,
		placement = po.placement,
	})
	if p.Parent == Players then
		Remotes.results(p, {
			outcome = if po.extracted then "Win" else "Wipe",
			result = po.result,
			cheeseEarned = cheese,
			xpEarned = xp,
			cycle = 1,
			stage = c.match.stage,
			bossesKilled = po.stagesCleared,
			duration = math.floor(os.clock() - c.startedAt),
			cheeseMult = mult,
			squad = po.squad,
			classId = pr.classId,
			classXp = classXp,
			kills = po.kills,
			downs = po.downs,
			stagesCleared = po.stagesCleared,
			lastHerd = po.lastHerd,
			placement = po.placement,
			pressurePoints = c.match:pressurePoints(),
		})
	end
end

-- Members that just left the run (extracted / eliminated / Last Herd): pay the
-- humans at once and send them back to the lobby after their Results screen.
local function handleOut(c: Ctx, ids: { number }, removeHeroes: boolean)
	local leaving: { Player } = {}
	for _, id in ids do
		local h = c.heroes[id]
		if h and removeHeroes then
			removeFromWorld(c, id)
		end
		if h and not h.isBot and not h.out then
			h.out = true
			h.offer = nil
			h.swapOffer = nil
			local ok, err = pcall(payMember, c, h)
			if not ok then
				warn("[RunDirector] payout failed for " .. h.player.Name .. ": " .. tostring(err))
			end
			if h.player.Parent == Players then
				Remotes.match(h.player, matchPayload(c, h) :: any)
				table.insert(leaving, h.player)
			end
		end
	end
	if #leaving > 0 then
		if type(CombatService.setPlayers) == "function" and c.world then
			pcall(CombatService.setPlayers, memberList(c))
		end
		if c.match.phase ~= "Results" then
			task.delay(RunDirector.OUT_RESULTS_SECONDS, function()
				if ctx ~= c or c.finished then
					return -- teardown returns everyone
				end
				LobbyService.leaveRun(leaving)
				for _, p in leaving do
					Remotes.runState(lobbyRunState(), p)
				end
			end)
		end
	end
	sendPartyHud(c, true)
	sendMatch(c, true)
end

-- PvP / squad events -----------------------------------------------------------------------------

local function killFeed(c: Ctx, entry: { [string]: any })
	Remotes.killFeed(memberList(c), entry :: any)
end

local function heroPos(c: Ctx, id: number): (number, number)
	local world = c.world
	local info = if world then world:getPlayer(id) else nil
	if info and finite(info.x) and finite(info.z) then
		return info.x, info.z
	end
	local p = heroSpawnPos(c, c.heroes[id])
	return p.X, p.Z
end

-- Drops a loot bag in the World for MatchState's bag (cheese) plus the hero's gear.
-- No World support: the cheese goes back to the hero and the gear stays.
local function dropBag(c: Ctx, id: number, cheese: number, key: number?)
	local h = c.heroes[id]
	local world = c.world
	local gear = if h then gearList(h) else {}
	if not key or (cheese <= 0 and #gear == 0) then
		return
	end
	if not world or type(world.addLootBag) ~= "function" then
		c.match:refundShare(id, cheese)
		return
	end
	local x, z = heroPos(c, id)
	local ok, bagId = pcall(world.addLootBag, world, x, z, gear, cheese)
	if not ok or bagId == nil then
		warn("[RunDirector] addLootBag failed: " .. tostring(bagId))
		c.match:refundShare(id, cheese)
		return
	end
	c.match:registerBag(bagId, key)
	if h then
		h.gear = {}
		if not h.isBot then
			sendInventory(c, h)
		end
	end
end

local function announceBounty(c: Ctx, claim: any)
	if not claim then
		return
	end
	local by, victim = c.heroes[claim.by], c.heroes[claim.victim]
	killFeed(c, {
		killer = claim.by,
		victim = claim.victim,
		killerSquad = c.match:squadOf(claim.by),
		victimSquad = c.match:squadOf(claim.victim),
		kind = "bountyClaimed",
		cheese = claim.cheese,
	})
	toastAll(
		c,
		string.format("%s claimed %s's bounty! +%d Cheese", heroName(by), heroName(victim), claim.cheese),
		"info"
	)
end

local function eliminate(c: Ctx, squad: number)
	local res = c.match:eliminateSquad(squad)
	if #res.out == 0 then
		return
	end
	for _, d in res.drops do
		dropBag(c, d.id, d.cheese, d.key)
	end
	killFeed(c, { victimSquad = squad, kind = "eliminated" })
	toastAll(c, squadName(squad) .. " squad is eliminated!", "bad")
	handleOut(c, res.out, false)
end

local function onHeroDowned(c: Ctx, e: any)
	local r = c.match:heroDowned(e.id, e.by)
	if not r then
		return
	end
	if r.killerSquad then
		killFeed(c, {
			killer = e.by,
			victim = e.id,
			killerSquad = r.killerSquad,
			victimSquad = r.victimSquad,
			kind = "down",
		})
	end
	announceBounty(c, r.bounty)
	sendMatch(c)
end

local function onHeroKilled(c: Ctx, e: any)
	local r = c.match:heroKilled(e.id, e.by)
	if not r then
		return
	end
	dropBag(c, r.victim, r.bagCheese, r.bagKey)
	killFeed(c, {
		killer = r.killer,
		victim = r.victim,
		killerSquad = r.killerSquad,
		victimSquad = r.victimSquad,
		kind = "kill",
	})
	announceBounty(c, r.bounty)
	if r.newBounty then
		killFeed(c, { killer = r.newBounty, killerSquad = r.killerSquad, kind = "bounty" })
		toastAll(
			c,
			string.format(
				"%s is on a %d-kill streak: BOUNTY +%d!",
				heroName(c.heroes[r.newBounty]),
				MatchState.CONFIG.BOUNTY_STREAK,
				MatchState.CONFIG.BOUNTY_CHEESE
			),
			"bad"
		)
	end
	sendMatch(c, true)
end

local function onGearPickup(c: Ctx, e: any)
	local h = heroOf(c, e.id)
	if not h then
		return
	end
	local slot = if type(e.slot) == "string"
		then e.slot
		elseif type(e.item) == "table" then e.item.slot
		else nil
	if table.find(GEAR_SLOTS, slot) and type(e.item) == "table" then
		h.gear[slot :: string] = e.item
	end
	syncGear(c, h)
	if not h.isBot then
		if h.swapOffer and h.swapOffer.slot == slot then
			h.swapOffer = nil
		end
		Remotes.toast(h.player, "Gear: " .. itemName(e.item), "good")
	end
	refreshHero(c, h)
end

local function resolveSwap(c: Ctx, h: any, keep: boolean)
	local world = c.world
	if world and type(world.resolveSwap) == "function" then
		local ok, err = pcall(world.resolveSwap, world, h.id, keep)
		if not ok then
			warn("[RunDirector] resolveSwap failed: " .. tostring(err))
		end
	end
	syncGear(c, h)
	refreshHero(c, h)
end

-- Slot full: humans get a SWAP_SECONDS prompt (SwapGear); bots take upgrades.
local function onGearSwapOffer(c: Ctx, e: any)
	local h = heroOf(c, e.id)
	if not h or type(e.item) ~= "table" then
		return
	end
	local slot = if type(e.slot) == "string" then e.slot else e.item.slot
	if h.isBot then
		local current = e.current or h.gear[slot]
		local better = (RARITY_RANK[e.item.rarity] or 0) >= (RARITY_RANK[current and current.rarity] or 0)
		resolveSwap(c, h, better)
		return
	end
	c.swapToken += 1
	local token = c.swapToken
	h.swapOffer = {
		item = e.item,
		slot = slot,
		current = e.current,
		endsAt = serverNow() + RunDirector.SWAP_SECONDS,
		token = token,
	}
	sendInventory(c, h)
	task.delay(RunDirector.SWAP_SECONDS, function()
		if ctx == c and h.swapOffer and h.swapOffer.token == token then
			h.swapOffer = nil
			resolveSwap(c, h, false) -- no answer: keep what you have; the item stays on the ground
		end
	end)
end

local function onLootBag(c: Ctx, e: any)
	local by = e.by
	if type(by) ~= "number" then
		return
	end
	local cheese = c.match:claimBag(e.bag, by)
	local s = c.match:squadOf(by)
	if cheese > 0 then
		toastSquad(
			c,
			s,
			string.format("%s grabbed a loot bag: +%d Cheese for the squad!", heroName(c.heroes[by]), cheese),
			"good"
		)
		sendMatch(c, true)
	end
end

-- Fallback squad wipe (a v1 World without squadEliminated, or a safety net):
-- every member of a squad down or dead for the grace time -> eliminated.
local anySquadHumanCanSecondWind: (c: Ctx, squad: number) -> boolean

local function squadWipeCheck(c: Ctx)
	local world = c.world
	if not world or c.match.phase == "Results" then
		return
	end
	local now = os.clock()
	for _, s in c.match:squadsInRun() do
		local anyIn, standing = false, false
		for _, id in c.match:activeMembers(s) do
			local info = world:getPlayer(id)
			if info then
				anyIn = true
				if not info.downed and not info.dead then
					standing = true
				end
			end
		end
		if anyIn and not standing then
			c.downSince[s] = c.downSince[s] or now
			local grace = RunDirector.WIPE_GRACE
			if c.pvpWorld then
				grace = RunDirector.PVP_WIPE_GRACE
			else
				local ok, can = pcall(anySquadHumanCanSecondWind, c, s)
				if ok and can then
					grace = RunDirector.WIPE_GRACE_SECOND_WIND
				end
			end
			if now - c.downSince[s] >= grace then
				c.downSince[s] = nil
				eliminate(c, s)
			end
		else
			c.downSince[s] = nil
		end
	end
end

-- Combat events ------------------------------------------------------------------------------

local function handleWorldEvent(e: any)
	local c = ctx
	if not c or type(e) ~= "table" or c.finished then
		return
	end
	local kind = e.type
	if kind == "fatal" then
		warn("[RunDirector] combat world failed: " .. tostring(e.kind))
		c.fatal = tostring(e.kind)
		return
	elseif kind == "moveViolation" then
		local pr = memberById(c, e.id)
		if pr then
			pr.moveViolations += 1
			if pr.moveViolations == RunDirector.UNRANKED_VIOLATIONS then
				warn(
					string.format(
						"[RunDirector] %s (%d): %d movement violations, run is unranked",
						pr.player.Name,
						pr.userId,
						pr.moveViolations
					)
				)
			end
		end
		return
	elseif kind == "bossEnrage" then
		toastAll(c, defName(Bosses, e.kind) .. " is enraged: faster attacks! Finish it fast!", "bad")
		return
	elseif kind == "bossPhase" then
		toastAll(c, "The boss gets angry! (phase 2)", "bad")
		return
	elseif kind == "bossDead" then
		c.bossDead = true
		c.bossKill = e
		return
	elseif kind == "poiActivated" then
		onPoiActivated(c, e)
		return
	elseif kind == "poiReward" then
		local ok, err = pcall(onPoiReward, c, e)
		if not ok then
			warn("[RunDirector] POI reward failed: " .. tostring(err))
		end
		return
	elseif kind == "poiProgress" then
		return
	elseif kind == "heroDowned" then
		onHeroDowned(c, e)
		return
	elseif kind == "heroKilled" then
		onHeroKilled(c, e)
		return
	elseif kind == "squadEliminated" then
		if Squads.isValid(e.squad) then
			eliminate(c, e.squad)
		end
		return
	elseif kind == "gearPickup" then
		onGearPickup(c, e)
		return
	elseif kind == "gearSwapOffer" then
		onGearSwapOffer(c, e)
		return
	elseif kind == "lootBag" then
		onLootBag(c, e)
		return
	end

	local h = heroOf(c, e.id)
	if not h then
		return
	end
	local squad = h.squad
	if kind == "xp" then
		if h.isBot then
			grantBotXp(c, h, e.amount)
		else
			grantXp(c, h, e.amount)
			sendHud(c, h)
		end
	elseif kind == "downed" then
		if not h.isBot then
			setHumanoidSpeed(h.player, if h.stats then h.stats.moveSpeed * 0.3 else DEFAULT_WALKSPEED * 0.3)
			sendHud(c, h, true)
		end
		toastSquad(c, squad, heroName(h) .. " is down! Stand close to revive.", "bad")
		sendPartyHud(c, true)
	elseif kind == "revived" then
		if not h.isBot then
			if h.stats then
				setHumanoidSpeed(h.player, h.stats.moveSpeed)
			end
			sendHud(c, h, true)
		end
		toastSquad(c, squad, heroName(h) .. " is back up!", "good")
		sendPartyHud(c, true)
	elseif kind == "dead" then
		if not h.isBot then
			setHumanoidSpeed(h.player, 0)
			sendHud(c, h, true)
		end
		-- A v1 World has no heroKilled: its "dead" is the death (no attacker known).
		if not c.pvpWorld then
			onHeroKilled(c, { id = e.id, by = nil })
		end
		toastSquad(c, squad, heroName(h) .. " is out until the next stage.", "bad")
		sendPartyHud(c, true)
	elseif kind == "damaged" then
		if not h.isBot then
			sendHud(c, h)
		end
	end
end

local function onCombatEvents(payload: any)
	if type(payload) ~= "table" then
		return
	end
	if payload.type ~= nil then
		handleWorldEvent(payload)
	else
		for _, e in payload do
			local ok, err = pcall(handleWorldEvent, e)
			if not ok then
				warn("[RunDirector] world event failed: " .. tostring(err))
			end
		end
	end
end

local combatEventsConnected = false

local function connectCombatEvents()
	local ev = CombatService.events
	local ok = false
	if typeof(ev) == "Instance" and (ev :: Instance):IsA("BindableEvent") then
		(ev :: BindableEvent).Event:Connect(onCombatEvents)
		ok = true
	elseif type(ev) == "table" then
		if type(ev.Connect) == "function" then
			ok = pcall(function()
				ev:Connect(onCombatEvents)
			end)
		elseif ev.Event ~= nil then
			ok = pcall(function()
				ev.Event:Connect(onCombatEvents)
			end)
		end
	end
	combatEventsConnected = ok
	if not ok then
		warn("[RunDirector] CombatService.events not connectable; draining world events directly")
	end
end

-- Route choice (the boss-winning squad) -------------------------------------------------------

local function tallyArray(v: VoteState): { number }
	local counts = table.create(#v.options, 0)
	local t = v.vote:tally()
	for i = 1, #v.options do
		counts[i] = if type(t[i]) == "number" then t[i] else 0
	end
	return counts
end

local function humanTallyOf(nOptions: number, votes: { [number]: number }): { number }
	local counts = table.create(nOptions, 0)
	for _, option in votes do
		if counts[option] ~= nil then
			counts[option] += 1
		end
	end
	return counts
end

local function tintFromVote(c: Ctx)
	local v = c.voting
	if not c.portal or not v then
		return
	end
	local counts = tallyArray(v)
	local best, bi = 0, 1
	for i, n in counts do
		if n > best then
			best, bi = n, i
		end
	end
	local col = portalTint(v.kind, v.options[bi])
	if col and table.concat(col, ",") ~= (c.portal :: any).key then
		setPortal(c, "open", col)
	end
end

local function botRouteVote(c: Ctx, v: VoteState, b: BotRun): boolean
	local ok, idx =
		pcall(BotBrain.chooseVote, v.kind, v.options, humanTallyOf(#v.options, v.humanVotes), c.botRng)
	if not ok or not Guard.isInt(idx, 1, #v.options) then
		return false
	end
	if v.vote:cast(b.id, idx) then
		v.botVoted[b.id] = true
		return true
	end
	return false
end

local function allVoted(v: VoteState): boolean
	if #v.humans > 0 then
		for _, p in v.humans do
			if p.Parent == Players and v.humanVotes[p.UserId] == nil then
				return false
			end
		end
		return true
	end
	for _, b in v.bots do
		if not v.botVoted[b.id] then
			return false
		end
	end
	return true
end

-- The winner picks 1 of the 3 cards. VoteOpen goes only to that squad's humans
-- (everyone else sees Match.routeChooser); its bots follow them, or pick by
-- BotBrain.chooseVote when the squad is all bots. Returns the card index.
local function runRouteChoice(c: Ctx, winner: number?): number
	local cards = c.match:routeCards() or {}
	local default = MatchState.defaultRouteIndex(cards)
	if #cards == 0 then
		return 1
	end
	if not winner or not c.match:isSquadInRun(winner) then
		local deadline = setPhaseTimer(c, RunDirector.ROUTE_DEFAULT_SECONDS)
		broadcastRunState(c)
		waitFor(c, deadline, nil)
		return default
	end
	local voters = c.match:activeMembers(winner)
	c.voteToken += 1
	local v: VoteState = {
		vote = Vote.new(#cards, voters),
		kind = "route",
		options = cards,
		voters = {},
		humans = squadHumans(c, winner),
		bots = squadBots(c, winner),
		humanVotes = {},
		botVoted = {},
		token = c.voteToken,
	}
	for _, id in voters do
		v.voters[id] = true
	end
	c.voting = v
	local deadline = setPhaseTimer(c, RunDirector.VOTE_SECONDS)
	broadcastRunState(c)
	Remotes.voteOpen(v.humans, { kind = "route", options = cards, endsAt = c.phaseEndsAt :: number })
	Remotes.voteTally(v.humans, tallyArray(v))
	toastAll(c, squadName(winner) .. " won the boss and picks the next route!", "info")
	tintFromVote(c)
	for _, b in v.bots do
		local delay = c.botRng:range(RunDirector.BOT_VOTE_MIN, RunDirector.BOT_VOTE_MAX)
		task.delay(delay, function()
			if ctx ~= c or c.voting ~= v or c.aborted then
				return
			end
			if botRouteVote(c, v, b) then
				Remotes.voteTally(v.humans, tallyArray(v))
				tintFromVote(c)
			end
		end)
	end
	waitFor(c, deadline, function()
		return allVoted(v)
	end)
	local idx = default
	local ok, r = pcall(v.vote.resolve, v.vote, c.voteRng, default)
	if ok and Guard.isInt(r, 1, #cards) then
		idx = r
	end
	c.voting = nil
	c.voteToken += 1
	Remotes.voteClosed(v.humans, idx)
	return idx
end

local function onVote(player: Player, optionIndex: number)
	local c = ctx
	local pr = c and c.members[player]
	local v = c and c.voting
	if not c or not pr or pr.out or not v then
		return
	end
	if phaseOf(c) ~= "RouteChoice" or optionIndex > #v.options or not v.voters[pr.userId] then
		Guard.reject(player, "Vote", "no matching open vote", false)
		return
	end
	if v.vote:cast(pr.userId, optionIndex) then
		v.humanVotes[pr.userId] = optionIndex
		for _, b in v.bots do
			if v.botVoted[b.id] then
				botRouteVote(c, v, b) -- re-follow the humans
			end
		end
		Remotes.voteTally(v.humans, tallyArray(v))
		tintFromVote(c)
	end
end

-- Extraction window --------------------------------------------------------------------------

local CHOICES: { string } = table.clone(MatchState.CHOICES)
local STAY_INDEX = table.find(CHOICES, "Stay") :: number

local function extractCounts(x: ExtractState, squad: number): { [string]: number }
	local out = {}
	for _, name in CHOICES do
		out[name] = 0
	end
	local vote = x.votes[squad]
	if vote then
		local t = vote:tally()
		for i, name in CHOICES do
			out[name] = t[i] or 0
		end
	end
	return out
end

local function sendExtract(c: Ctx, squad: number?)
	local x = c.extract
	if not x then
		return
	end
	for _, p in memberList(c) do
		local pr = c.members[p]
		if squad == nil or pr.squad == squad then
			local mine = x.humanVotes[pr.squad] and x.humanVotes[pr.squad][pr.userId]
			Remotes.extract(p, {
				endsAt = c.phaseEndsAt or serverNow(),
				options = CHOICES,
				votes = extractCounts(x, pr.squad),
				yourChoice = if mine then CHOICES[mine] else nil,
				squad = pr.squad,
				share = c.match:shareOf(pr.userId),
				pending = c.match:squadPending(pr.squad),
				stage = c.match.stage,
				stages = MatchState.CONFIG.STAGES,
				extractedCount = c.match:extractedCount(),
				brave = c.match:extractedCount() >= MatchState.CONFIG.BRAVE_EXTRACTED,
			})
		end
	end
end

-- A bot's extraction vote: follow its squad's humans (BotBrain.chooseVote); an
-- all-bot squad uses its one decision. Returns true if it voted.
local function botExtractVote(c: Ctx, x: ExtractState, b: BotRun): boolean
	local vote = x.votes[b.squad]
	if not vote then
		return false
	end
	local idx: number? = nil
	local choice = x.botChoice[b.squad]
	if choice then
		idx = table.find(CHOICES, choice)
	else
		local tally = humanTallyOf(#CHOICES, x.humanVotes[b.squad] or {})
		local any = false
		for _, n in tally do
			any = any or n > 0
		end
		if not any then
			return false -- wait for a human (no vote = the default Stay)
		end
		local ok, r = pcall(BotBrain.chooseVote, "extract", CHOICES, tally, c.botRng)
		idx = if ok and Guard.isInt(r, 1, #CHOICES) then r else nil
	end
	if idx and vote:cast(b.id, idx) then
		x.botVoted[b.id] = true
		return true
	end
	return false
end

local function allExtractVoted(c: Ctx, x: ExtractState): boolean
	for _, p in memberList(c) do
		local pr = c.members[p]
		local votes = x.humanVotes[pr.squad]
		if not votes or votes[pr.userId] == nil then
			return false
		end
	end
	return true
end

-- Every squad in the run chooses Extract / Stay / Double or Nothing (majority;
-- DoN needs a human vote: Vote.riskyIndices). Returns MatchState's result.
local function runExtraction(c: Ctx): any
	local live = c.match:squadsInRun()
	c.voteToken += 1
	local x: ExtractState =
		{ votes = {}, humanVotes = {}, botVoted = {}, botChoice = {}, token = c.voteToken }
	for _, s in live do
		x.votes[s] = Vote.new(#CHOICES, c.match:activeMembers(s))
		x.humanVotes[s] = {}
		if #squadHumans(c, s) == 0 then
			local choice = nil
			if type(BotBrain.chooseExtract) == "function" then
				local ok, r = pcall(BotBrain.chooseExtract, c.match:getPublic(), s, c.botRng)
				if ok and MatchState.isChoice(r) and r ~= "DoubleOrNothing" then
					choice = r
				end
			end
			x.botChoice[s] = choice or c.match:botExtractChoice(s, c.botRng)
		end
	end
	c.extract = x
	local deadline = setPhaseTimer(c, RunDirector.EXTRACT_SECONDS)
	broadcastRunState(c)
	sendExtract(c, nil)
	for _, b in botsInRun(c) do
		local delay = c.botRng:range(RunDirector.BOT_VOTE_MIN, RunDirector.BOT_VOTE_MAX)
		task.delay(delay, function()
			if ctx ~= c or c.extract ~= x or c.aborted then
				return
			end
			if botExtractVote(c, x, b) then
				sendExtract(c, b.squad)
			end
		end)
	end
	waitFor(c, deadline, function()
		return allExtractVoted(c, x)
	end)
	-- Bots that have not voted yet vote now (bot-only squads, late humans' mates).
	for _, b in botsInRun(c) do
		if not x.botVoted[b.id] then
			botExtractVote(c, x, b)
		end
	end
	local choices: { [number]: string } = {}
	local risky = Vote.riskyIndices(CHOICES)
	for _, s in live do
		local vote = x.votes[s]
		local idx = STAY_INDEX
		if vote and c.match:isSquadInRun(s) then
			local ok, r = pcall(vote.resolve, vote, c.voteRng, STAY_INDEX, risky)
			if ok and Guard.isInt(r, 1, #CHOICES) then
				idx = r
			end
		end
		choices[s] = CHOICES[idx]
	end
	c.extract = nil
	c.voteToken += 1
	local res = c.match:resolveExtraction(choices)
	for _, s in res.extracted do
		killFeed(c, { killerSquad = s, kind = "extracted" })
		toastAll(c, squadName(s) .. " extracted through the Rind Gate!", "info")
	end
	for _, s in res.doubleOrNothing do
		toastSquad(c, s, "DOUBLE OR NOTHING! Your pot grows x1.5 at the next boss, or is lost.", "bad")
	end
	handleOut(c, res.out, true)
	return res
end

local function onExtractVote(player: Player, choice: string)
	local c = ctx
	local pr = c and c.members[player]
	local x = c and c.extract
	if not c or not pr or pr.out or not x or phaseOf(c) ~= "Extraction" then
		return
	end
	local idx = table.find(CHOICES, choice)
	local vote = x.votes[pr.squad]
	if not idx or not vote then
		Guard.reject(player, "ExtractVote", "no matching extraction window", false)
		return
	end
	if vote:cast(pr.userId, idx) then
		x.humanVotes[pr.squad][pr.userId] = idx
		for _, b in squadBots(c, pr.squad) do
			if x.botVoted[b.id] or not x.botChoice[b.squad] then
				botExtractVote(c, x, b) -- bots follow their humans
			end
		end
		sendExtract(c, pr.squad)
		local col = RunDirector.PORTAL_COLORS[choice]
		if col and c.portal then
			setPortal(c, "open", col)
		end
	end
end

-- Gear / Shop Cart remotes ---------------------------------------------------------------------

local function onSwapGear(player: Player, keep: boolean)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or pr.out or not LIVE_PHASES[phaseOf(c)] then
		return
	end
	local offer = pr.swapOffer
	if not offer then
		Guard.reject(player, "SwapGear", "no swap offer", false)
		return
	end
	if serverNow() > offer.endsAt + 0.5 then
		return -- expired; the timeout already resolved it
	end
	pr.swapOffer = nil
	resolveSwap(c, pr, keep)
	if keep then
		Remotes.toast(player, "Equipped " .. itemName(offer.item), "good")
	end
end

local function onBuyCartItem(player: Player, poiId: number, index: number)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or pr.out or not LIVE_PHASES[phaseOf(c)] then
		return
	end
	local cart = c.carts[poiId]
	if not cart or cart.squad ~= pr.squad then
		Guard.reject(player, "BuyCartItem", "no such cart for this squad", false)
		return
	end
	local item, price = cart.offers[index], cart.prices[index]
	if not item or not finite(price) or cart.bought[index] then
		Guard.reject(player, "BuyCartItem", "bad or sold offer", false)
		return
	end
	-- Pending cheese only (in-run soft currency, never Robux).
	if not c.match:spendShare(pr.userId, price) then
		Remotes.toast(player, "Not enough pending cheese for that.", "bad")
		return
	end
	local ok, swap = giveGear(c, pr, item)
	if not ok and not swap then
		c.match:refundShare(pr.userId, price)
		Remotes.toast(player, "The cart can't hand that over right now.", "bad")
		return
	end
	cart.bought[index] = true
	Remotes.toast(player, string.format("Bought %s for %d cheese", itemName(item), price), "good")
	refreshHero(c, pr)
	sendCart(c, pr, poiId)
	sendMatch(c)
end

-- Upgrade / ability / Second Wind remotes ---------------------------------------------------------

local function onChooseUpgrade(player: Player, offerId: number, cardIndex: number)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or pr.out or not LIVE_PHASES[phaseOf(c)] then
		return
	end
	local offer = pr.offer
	if not offer or offer.offerId ~= offerId or cardIndex > #offer.cards then
		Guard.reject(player, "ChooseUpgrade", "stale or unknown offer", false)
		return
	end
	local card = offer.cards[cardIndex]
	pr.offer = nil
	pr.stacks[card.id] = (pr.stacks[card.id] or 0) + 1
	computeStats(c, pr)
	pushStats(c, pr)
	local heal = card.delta and card.delta.heal
	local world = c.world
	if world and finite(heal) and heal > 0 and type(world.healPlayer) == "function" then
		pcall(world.healPlayer, world, pr.userId, heal)
	end
	presentNextOffer(c, pr)
	sendHud(c, pr, true)
end

local function onRerollUpgrade(player: Player, offerId: number)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or pr.out or not LIVE_PHASES[phaseOf(c)] then
		return
	end
	local offer = pr.offer
	if not offer or offer.offerId ~= offerId then
		Guard.reject(player, "RerollUpgrade", "stale or unknown offer", false)
		return
	end
	if pr.freeRerollsLeft > 0 then
		pr.freeRerollsLeft -= 1
	else
		local spent, why = false, "no_tokens"
		local key = stageKey(c)
		profileUpdate(player, function(profile: any)
			local ok, r1, r2 = pcall(RunTokens.useReroll, pr.tokens, profile, key)
			if ok then
				spent, why = r1 == true, r2 or why
			end
		end)
		if not spent then
			Remotes.toast(
				player,
				if why == "stage_cap" then "Max 2 token rerolls per stage." else "No rerolls left.",
				"bad"
			)
			return
		end
	end
	local cards = rollCards(c, pr, offer.source)
	if type(cards) == "table" and #cards > 0 then
		pr.offer = { offerId = offer.offerId, cards = cards, source = offer.source }
	end
	sendOffer(c, pr)
	sendHud(c, pr, true)
end

local function onUseAbility(player: Player, aimX: number, aimZ: number)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or pr.out or not c.world or not LIVE_PHASES[phaseOf(c)] then
		return
	end
	if c.world:useAbility(pr.userId, aimX, aimZ, simNow()) then
		sendHud(c, pr, true)
	end
end

local function probeSecondWind(c: Ctx, pr: PlayerRun): (boolean, string, { [string]: any })
	local reviveCtx: { [string]: any } = { doubleOrNothing = c.match:squadDoubleOrNothing(pr.squad) }
	local world = c.world
	if world and type(world.bossInfo) == "function" then
		local okB, boss = pcall(world.bossInfo, world)
		if okB and type(boss) == "table" and finite(boss.hpFrac) then
			reviveCtx.bossHpFrac = boss.hpFrac
		end
	end
	local ok, allowed, how = pcall(
		RunTokens.useSecondWind,
		cloneTokens(pr.tokens),
		tokenProfile(pr.player),
		stageKey(c),
		reviveCtx
	)
	if not ok then
		return false, "error", reviveCtx
	end
	return allowed == true, how, reviveCtx
end

anySquadHumanCanSecondWind = function(c: Ctx, squad: number): boolean
	local world = c.world
	if not world then
		return false
	end
	for _, p in squadHumans(c, squad) do
		local pr = c.members[p]
		local info = world:getPlayer(pr.userId)
		if info and info.downed and not info.dead and not info.secondWindUsed then
			if probeSecondWind(c, pr) then
				return true
			end
		end
	end
	return false
end

local function onUseSecondWind(player: Player)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or pr.out or not c.world or not LIVE_PHASES[phaseOf(c)] then
		return
	end
	local world = c.world
	local info = world:getPlayer(pr.userId)
	if not info or not info.downed or info.dead then
		return
	end
	local key = stageKey(c)
	local allowed, how, reviveCtx = probeSecondWind(c, pr)
	if not allowed then
		Remotes.toast(
			player,
			if how == "stage_cap"
				then "Second Wind already used this stage."
				elseif how == "run_cap" then "No more Second Winds this run."
				elseif how == "blocked_double_or_nothing" then "No token revives on Double-or-Nothing stages."
				elseif how == "blocked_boss_low" then "Too late, the boss is almost down!"
				else "No Second Winds left.",
			"bad"
		)
		return
	end
	-- Charge BEFORE reviving (QC1 #11); refund only if the world refuses.
	local before = cloneTokens(pr.tokens)
	if how == "free" then
		RunTokens.useSecondWind(pr.tokens, table.clone(NO_PROFILE), key, reviveCtx)
	else
		local spent = false
		profileUpdate(player, function(profile: any)
			local ok, r = pcall(RunTokens.useSecondWind, pr.tokens, profile, key, reviveCtx)
			spent = ok and r == true
		end)
		if not spent then
			pr.tokens = before
			Remotes.toast(player, "Second Wind could not be used right now. Try again!", "bad")
			return
		end
	end
	if not world:useSecondWind(pr.userId) then
		local wasToken = how ~= "free"
		pr.tokens = before
		if wasToken then
			profileUpdate(player, function(profile: any)
				if finite(profile.secondWindTokens) then
					profile.secondWindTokens += 1
				end
			end)
		end
		warn("[RunDirector] world refused Second Wind after the charge; token refunded")
		return
	end
	pr.usedSecondWindToken = pr.tokens.usedToken == true
	if pr.stats then
		setHumanoidSpeed(player, pr.stats.moveSpeed)
	end
	toastSquad(c, pr.squad, player.DisplayName .. " used Second Wind!", "good")
	sendHud(c, pr, true)
	sendPartyHud(c, true)
end

-- Stage --------------------------------------------------------------------------------------------

local function stageIntroText(c: Ctx, card: any): string
	local text =
		string.format("Stage %d/%d: %s", c.match.stage, MatchState.CONFIG.STAGES, defName(Maps, card.mapId))
	if card.curseId then
		text ..= " | Curse: " .. defName(Modifiers, card.curseId)
	end
	if card.cleanse then
		text ..= " | Cleanse!"
	end
	return text
end

-- Epic boss drop (High-route kill): each human of the winning squad gets an epic
-- cosmetic they do not own (Run/EpicDrop), or a reroll token when they own them all.
local function grantEpicDrops(c: Ctx, squad: number)
	local pool = {}
	if Cosmetics and type(Cosmetics.epicPool) == "function" then
		local ok, list = pcall(Cosmetics.epicPool)
		if ok and type(list) == "table" then
			pool = list
		end
	end
	for _, p in squadHumans(c, squad) do
		if not isHuman(p) then
			continue
		end
		local profile = getProfile(p)
		if type(profile) ~= "table" then
			continue
		end
		local owned = if type(profile.cosmetics) == "table" then profile.cosmetics else {}
		local okR, drop = pcall(EpicDrop.roll, pool, owned, c.epicRng)
		if not okR or type(drop) ~= "table" then
			continue
		end
		local granted = profileUpdate(p, function(prof: any)
			if drop.kind == "cosmetic" then
				if type(prof.cosmetics) ~= "table" then
					prof.cosmetics = {}
				end
				prof.cosmetics[drop.id] = true
			else
				prof.rerollTokens = (if finite(prof.rerollTokens) then prof.rerollTokens else 0) + 1
			end
		end)
		if granted then
			if drop.kind == "cosmetic" then
				local def = lookupDef(Cosmetics, drop.id)
				Remotes.toast(
					p,
					"EPIC cosmetic unlocked: "
						.. (if def and type(def.name) == "string" then def.name else drop.id)
						.. "!",
					"good"
				)
			else
				Remotes.toast(p, "You own every epic cosmetic! +1 free reroll token.", "good")
			end
		end
	end
end

-- The boss chest's gear (Gear.bossChest, R2) for each member of the winning squad.
local function grantChestGear(c: Ctx, squad: number, tier: any)
	if not Gear then
		return
	end
	for _, id in c.match:activeMembers(squad) do
		local h = c.heroes[id]
		if h then
			local items: { any } = {}
			if type(Gear.bossChest) == "function" then
				local ok, list = pcall(Gear.bossChest, c.gearRng, tier, c.match.stage)
				if ok and type(list) == "table" then
					items = list
				end
			elseif type(Gear.roll) == "function" then
				local ok, it = pcall(Gear.roll, c.gearRng, tier, c.match.stage)
				if ok and type(it) == "table" then
					items = { it }
				end
			end
			for _, item in items do
				giveGear(c, h, item)
			end
		end
	end
end

-- Boss damage per squad when the boss times out (R2: bossInfo().damageBySquad).
local function bossDamageNow(c: Ctx): any
	local world = c.world
	if not world then
		return nil
	end
	if type(world.bossDamageBySquad) == "function" then
		local ok, d = pcall(world.bossDamageBySquad, world)
		if ok and type(d) == "table" then
			return d
		end
	end
	if type(world.bossInfo) == "function" then
		local ok, info = pcall(world.bossInfo, world)
		if ok and type(info) == "table" and type(info.damageBySquad) == "table" then
			return info.damageBySquad
		end
	end
	return nil
end

-- Match over, or nobody human left in it? (also runs the fallback squad wipe)
local function stageOver(c: Ctx): boolean
	squadWipeCheck(c)
	if c.match.phase == "Results" then
		return true
	end
	if c.match:humansInRun() == 0 then
		local out = c.match:finish("noHumans")
		handleOut(c, out, false)
		return true
	end
	return false
end

-- Builds the stage's arena and world and drops every squad at its corner.
local function buildStage(c: Ctx, card: any)
	stopCombat(c)
	ArenaBuilder.clear()
	local stageSeed = c.match:stageSeed()
	local layout = {}
	local okL, lay = pcall(
		Pois.layout,
		Rng.new(stageSeed):fork(RunDirector.POI_SALT),
		card.mapId,
		Pois.arenaRadius(card.mapId)
	)
	if okL and type(lay) == "table" then
		layout = lay
	else
		warn("[RunDirector] POI layout failed: " .. tostring(lay))
	end
	local arena = ArenaBuilder.build(card.mapId, stageSeed, { pois = layout })
	c.arena = arena
	applyLighting(card.mapId)

	local mapDef = lookupDef(Maps, card.mapId)
	local world = World.new({
		rng = Rng.new(stageSeed):fork(c.stageIndex),
		mods = c.match:worldMods(),
		arenaRadius = arena.radius,
		obstacles = arena.obstacles or {},
		enemyPool = if mapDef and mapDef.enemyPool then mapDef.enemyPool else {},
		cycle = 1,
		stage = c.match.stage,
		safeZones = arena.safeZones, -- R4 safe corners (-60% PvP damage), read by an R2 World
	})
	c.world = world
	if type(world.setStage) == "function" then
		world:setStage(1, c.match.stage)
	end
	if type(world.setSafeZones) == "function" and type(arena.safeZones) == "table" then
		pcall(world.setSafeZones, world, arena.safeZones)
	end
	local heroes: { any } = {}
	for _, p in memberList(c) do
		table.insert(heroes, c.members[p])
	end
	for _, b in botsInRun(c) do
		table.insert(heroes, b)
	end
	for _, h in heroes do
		computeStats(c, h)
		local pos = heroSpawnPos(c, h)
		world:addPlayer(h.id, h.stats, h.weapon, h.ability, pos.X, pos.Z, h.squad)
		if type(world.setSquad) == "function" then
			pcall(world.setSquad, world, h.id, h.squad)
		end
		-- Gear lasts the whole run: hand it to the new world.
		local kept = gearList(h)
		for _, item in kept do
			giveGear(c, h, item)
		end
		if #kept > 0 and type(world.gearOf) ~= "function" then
			for _, item in kept do
				h.gear[item.slot] = item
			end
		end
		if not h.isBot and finite(h.stats.moveSpeed) then
			setHumanoidSpeed(h.player, h.stats.moveSpeed)
		end
	end
	if type(world.addPoi) == "function" then
		for _, entry in layout do
			local ok, err = pcall(world.addPoi, world, entry)
			if not ok then
				warn("[RunDirector] addPoi failed: " .. tostring(err))
			end
		end
	end
	CombatService.start(world, memberList(c))
	syncBots(c)
	for _, p in memberList(c) do
		local pr = c.members[p]
		task.spawn(function()
			teleportToArena(c, pr)
			decorate(c, pr)
		end)
		sendInventory(c, pr)
	end
end

-- Plays one stage. Returns "continue" | "results" | "abort".
local function playStage(c: Ctx): string
	local match = c.match
	local card = match:currentRoute()
	c.card = card
	c.stageIndex += 1

	-- Portal pull from the previous stage.
	if c.portal and c.world then
		local col = portalTint("route", card) or RunDirector.PORTAL_GOLD
		setPortal(c, "pull", col)
		if waitFor(c, os.clock() + RunDirector.PORTAL_PULL_SECONDS, nil) == "abort" then
			return "abort"
		end
		setPortal(c, "close", col)
		waitFor(c, os.clock() + 0.15, nil)
	end
	c.portal = nil
	c.carts = {}
	c.totemSquad = nil
	c.bossKill = nil
	c.buffs = {}
	c.downSince = {}
	for _, pr in c.members do
		pr.freeRerollsLeft = RunDirector.FREE_REROLLS_PER_STAGE
		pr.swapOffer = nil
	end

	buildStage(c, card)
	local world = c.world :: any
	toastAll(c, stageIntroText(c, card), "info")

	-- Waves
	world:startWaves(RunDirector.WAVE_SECONDS)
	local deadline = setPhaseTimer(c, RunDirector.WAVE_SECONDS)
	broadcastRunState(c)
	local r = waitFor(c, deadline, function()
		return stageOver(c)
	end)
	if r == "abort" then
		return "abort"
	elseif r == "fatal" then
		handleOut(c, match:finish("crash"), false)
		return "results"
	elseif r == "pred" then
		return "results"
	end

	-- Boss (centre of the map)
	world:stopSpawning()
	world:clearEnemies()
	match:startBoss()
	c.bossDead = false
	c.bossKill = nil
	c.bossSpawnedAt = os.clock()
	local center = arenaCenter(c)
	world:spawnBoss(card.bossId, center.X, center.Z)
	local bossDeadline = setPhaseTimer(c, RunDirector.BOSS_SECONDS)
	broadcastRunState(c)
	toastAll(
		c,
		defName(Bosses, card.bossId) .. " appears at the centre! The killing blow wins the chest!",
		"bad"
	)
	local ended = false
	r = waitFor(c, bossDeadline, function()
		if stageOver(c) then
			ended = true
			return true
		end
		if c.bossDead then
			return true
		end
		if os.clock() - c.bossSpawnedAt >= RunDirector.BOSS_FALLBACK_DELAY then
			local ok, alive = pcall(world.bossAlive, world)
			if ok and not alive then
				return true
			end
		end
		return false
	end)
	if r == "abort" then
		return "abort"
	elseif r == "fatal" then
		handleOut(c, match:finish("crash"), false)
		return "results"
	elseif ended then
		return "results"
	end
	local killerSquad, damage = nil, nil
	if c.bossKill then
		killerSquad = if Squads.isValid(c.bossKill.killerSquad) then c.bossKill.killerSquad else nil
		damage = c.bossKill.damageBySquad
	end
	if r == "timeout" then
		damage = bossDamageNow(c)
		toastAll(c, "The boss fled! The squad with the most damage wins.", "bad")
	end
	if damage == nil then
		damage = bossDamageNow(c)
	end
	world:clearEnemies()

	-- Stage clear
	local result = match:bossDefeated(killerSquad, damage)
	c.bossesKilled += 1
	if result.finished and match.stage >= MatchState.CONFIG.STAGES and c.cycle1Time == nil then
		c.cycle1Time = os.clock() - c.startedAt
	end
	local winner = result.winner
	if winner then
		toastAll(
			c,
			string.format(
				"%s %s the boss and takes the chest!",
				squadName(winner),
				if result.winnerBy == "kill" then "slew" else "out-damaged"
			),
			"good"
		)
		toastSquad(
			c,
			winner,
			string.format("Boss chest: +%d Cheese each and gear!", result.chestCheese),
			"good"
		)
		grantChestGear(c, winner, result.tier)
		if result.epic then
			toastSquad(c, winner, "EPIC drop!", "good")
			grantEpicDrops(c, winner)
		end
	end
	toastAll(
		c,
		string.format(
			"Stage cleared! +%d Cheese each (pending)%s",
			result.stageCheese,
			if result.brave then " (brave bonus!)" else ""
		),
		"good"
	)
	for s, bonus in result.potBonus do
		toastSquad(c, s, string.format("Double or Nothing paid off: +%d Cheese!", bonus), "good")
	end
	if result.blessingId then
		toastSquad(c, winner, "Blessing: " .. defName(Modifiers, result.blessingId), "good")
	end
	for _, s in match:squadsInRun() do
		refreshSquad(c, s) -- blessings
	end
	sendPartyHud(c, true)
	if result.finished then
		if result.endReason == "lastHerd" then
			for _, s in Squads.LIST do
				if match:squad(s.id).outReason == "lastHerd" then
					killFeed(c, { killerSquad = s.id, kind = "lastHerd" })
					toastAll(c, s.name .. " is the LAST HERD STANDING! +50% pot!", "good")
				end
			end
		end
		handleOut(c, result.out, false)
		return "results"
	end

	-- Route choice by the winner, through the open Rind Gate.
	openPortal(c, center)
	local idx = runRouteChoice(c, winner)
	if c.aborted then
		return "abort"
	end
	local nextCard = match:chooseRoute(idx, winner)
	toastAll(
		c,
		string.format(
			"Next: %s (%s)%s",
			defName(Maps, nextCard.mapId),
			tostring(nextCard.tier),
			if nextCard.curseId then " | Curse: " .. defName(Modifiers, nextCard.curseId) else ""
		),
		"info"
	)

	-- Extraction window
	local res = runExtraction(c)
	if c.aborted then
		return "abort"
	end
	if res.finished or match.phase == "Results" then
		return "results"
	end
	if match:humansInRun() == 0 then
		handleOut(c, match:finish("noHumans"), false)
		return "results"
	end
	return "continue"
end

-- Teardown -----------------------------------------------------------------------------------------

local function teardown(c: Ctx)
	c.finished = true
	stopCombat(c)
	pcall(ArenaBuilder.clear)
	applyLighting("lobby")
	local players = {}
	for _, p in connectedMembers(c) do
		setHumanoidSpeed(p, DEFAULT_WALKSPEED)
		if LobbyService.isRunMember(p) then
			table.insert(players, p)
		end
	end
	if ctx == c then
		ctx = nil
	end
	if BotService and type(BotService.despawnAll) == "function" then
		pcall(BotService.despawnAll)
	end
	LobbyService.returnToLobby(players)
	LobbyService.setRunActive(false)
	Remotes.runState(lobbyRunState())
end

local function finishRun(c: Ctx)
	local firstCall = not c.awarded
	c.awarded = true
	if c.match.phase ~= "Results" then
		pcall(function()
			handleOut(c, c.match:finish("crash"), false)
		end)
	end
	if c.fatal then
		stopCombat(c)
		c.fatal = nil
	end
	local world = c.world
	if world then
		pcall(world.stopSpawning, world)
		pcall(world.clearEnemies, world)
	end
	local deadline = setPhaseTimer(c, RunDirector.RESULTS_SECONDS)
	if firstCall then
		broadcastRunState(c)
	end
	-- Per-player pcall: a crash retry pays whoever is still unpaid.
	for _, p in connectedMembers(c) do
		local ok, err = pcall(payMember, c, c.members[p])
		if not ok then
			warn("[RunDirector] payout failed for " .. p.Name .. ": " .. tostring(err))
		end
	end
	waitFor(c, deadline, function()
		return #connectedMembers(c) == 0
	end)
end

local function runLoop(c: Ctx)
	local first = c.match:begin()
	c.card = first
	while true do
		local r = playStage(c)
		if r == "abort" then
			return
		elseif r == "results" or c.match.phase == "Results" then
			finishRun(c)
			return
		elseif c.fatal then
			handleOut(c, c.match:finish("crash"), false)
			finishRun(c)
			return
		end
	end
end

-- Start -----------------------------------------------------------------------------------------------

-- Seats from LobbyService (squads = BotRoster.fillSquads result). Rebuilds them
-- when missing or inconsistent, so a start always has 4 squads of up to 3.
local function seatParticipants(
	party: { Player },
	classes: { [number]: string },
	botSpecs: { any }?,
	squads: any,
	seed: number
): ({ [number]: number }, { any })
	local seatOf: { [number]: number } = {}
	local count = table.create(Squads.MAX, 0)
	local ok = true
	if type(squads) == "table" then
		for s = 1, Squads.MAX do
			local list = squads[s]
			if type(list) == "table" then
				for _, m in list do
					if type(m) == "table" and type(m.id) == "number" and seatOf[m.id] == nil then
						seatOf[m.id] = s
					end
				end
			end
		end
	end
	local bots = {}
	for _, p in party do
		local s = seatOf[p.UserId]
		if not Squads.isValid(s) then
			ok = false
		else
			count[s] += 1
		end
	end
	for _, spec in botSpecs or {} do
		if
			type(spec) == "table"
			and Guard.isInt(spec.id, -1000000, -1001)
			and Ids.isBot(spec.id)
			and type(spec.classId) == "string"
		then
			local s = if Squads.isValid(spec.squad) then spec.squad else seatOf[spec.id]
			if Squads.isValid(s) and count[s] < Squads.SIZE then
				count[s] += 1
				seatOf[spec.id] = s
				table.insert(bots, spec)
			end
		end
	end
	for s = 1, Squads.MAX do
		ok = ok and count[s] <= Squads.SIZE
	end
	if ok then
		return seatOf, bots
	end
	-- Rebuild (no or bad seats from the lobby): friends unknown, bots fill everything.
	local humans = {}
	for _, p in party do
		table.insert(humans, { id = p.UserId, classId = classes[p.UserId] })
	end
	local built = BotRoster.fillSquads(humans, Rng.new(seed):fork(9))
	seatOf, bots = {}, {}
	for _, m in BotRoster.flatten(built) do
		seatOf[m.id] = m.squad
		if m.isBot then
			table.insert(bots, m)
		end
	end
	return seatOf, bots
end

-- LobbyService.onStart(players, classes, bots, pressure, squads).
local function startRun(
	players: { Player },
	classes: { [number]: string },
	botSpecs: { any }?,
	pressure: { [string]: number }?,
	squads: any?
)
	if ctx then
		warn("[RunDirector] start requested while a run is active; ignored")
		return
	end
	local party = {}
	for _, p in players do
		if p.Parent == Players and #party < LobbyService.MAX_PARTY then
			table.insert(party, p)
		end
	end
	if #party == 0 then
		return
	end
	local seed = Random.new():NextInteger(1, 2147483646)
	local rng = Rng.new(seed)
	local seatOf, botList = seatParticipants(party, classes, botSpecs, squads, seed)

	local participants = {}
	for _, p in party do
		table.insert(participants, { id = p.UserId, squad = seatOf[p.UserId], isBot = false })
	end
	for _, spec in botList do
		table.insert(participants, { id = spec.id, squad = seatOf[spec.id], isBot = true })
	end
	local runOpts: { [string]: any } =
		{ bossIds = Bosses.ORDER, mapIds = Maps.ORDER, botWeight = RunDirector.BOT_WEIGHT }
	if type(pressure) == "table" then
		runOpts.pressure = pressure -- RunState sanitizes it
	end
	local match = MatchState.new(seed, participants, runOpts)

	local c: Ctx = {
		seed = seed,
		match = match,
		run = match.run,
		rng = rng,
		voteRng = rng:fork(1),
		botRng = rng:fork(2),
		gearRng = rng:fork(3),
		epicRng = rng:fork(5),
		discoverRng = rng:fork(6),
		members = {},
		order = party,
		bots = {},
		heroes = {},
		world = nil,
		arena = nil,
		card = nil,
		pvpWorld = World.PVP_MULT ~= nil,
		phaseEndsAt = nil,
		voting = nil,
		extract = nil,
		voteToken = 0,
		bossDead = false,
		bossKill = nil,
		bossSpawnedAt = 0,
		downSince = {},
		bossesKilled = 0,
		startedAt = os.clock(),
		cycle1Time = nil,
		stageIndex = 0,
		nextOfferId = 0,
		aborted = false,
		finished = false,
		awarded = false,
		fatal = nil,
		lastPartyAt = 0,
		lastParty = {},
		buffs = {},
		portal = nil,
		carts = {},
		totemSquad = nil,
		swapToken = 0,
	}
	-- Bots get a perk preset near the humans' average class level (R3 autoSpec).
	local levelSum, levelN = 0, 0
	if ClassProgress and type(ClassProgress.classState) == "function" then
		for _, p in party do
			local ok, st =
				pcall(ClassProgress.classState, getProfile(p), classes[p.UserId] or LobbyService.getClass(p))
			if ok and type(st) == "table" and finite(st.level) then
				levelSum += st.level
				levelN += 1
			end
		end
	end
	local botLevel = if levelN > 0 then math.max(1, math.floor(levelSum / levelN + 0.5)) else 1
	for i, spec in botList do
		local classState = nil
		if ClassProgress and type(ClassProgress.autoSpec) == "function" then
			local ok, st = pcall(ClassProgress.autoSpec, spec.classId, botLevel, (i % 3) + 1)
			classState = if ok then st else nil
		end
		local b: BotRun = {
			id = spec.id,
			isBot = true,
			name = if type(spec.name) == "string" then spec.name else "Bot 🤖",
			squad = seatOf[spec.id],
			classId = spec.classId,
			classState = classState,
			skin = nil,
			level = 1,
			xp = 0,
			stacks = {},
			stats = nil,
			weapon = nil,
			ability = nil,
			gear = {},
			offerRng = rng:fork(200 + i),
		}
		table.insert(c.bots, b)
		c.heroes[b.id] = b
	end
	for slot, p in party do
		local classId = classes[p.UserId] or LobbyService.getClass(p)
		local profile = getProfile(p)
		local classState, skin = nil, nil
		if ClassProgress then
			if type(ClassProgress.classState) == "function" then
				local ok, st = pcall(ClassProgress.classState, profile, classId)
				classState = if ok then st else nil
			end
			if type(ClassProgress.skinFor) == "function" then
				local ok, sk = pcall(ClassProgress.skinFor, profile, classId)
				skin = if ok then sk else nil
			end
		elseif profile and type(profile.classes) == "table" and type(profile.classes[classId]) == "table" then
			local st = profile.classes[classId]
			classState = { perks = if type(st.perks) == "table" then st.perks else {}, ability = st.ability }
			skin = st.skin
		end
		local pr: PlayerRun = {
			player = p,
			id = p.UserId,
			userId = p.UserId,
			isBot = false,
			name = p.DisplayName,
			squad = seatOf[p.UserId],
			classId = classId,
			classState = classState,
			skin = skin,
			level = 1,
			xp = 0,
			stacks = {},
			stats = nil,
			weapon = nil,
			ability = nil,
			gear = {},
			pendingLevels = 0,
			offer = nil,
			offerRng = rng:fork(100 + slot),
			freeRerollsLeft = RunDirector.FREE_REROLLS_PER_STAGE,
			tokens = RunTokens.new(),
			usedSecondWindToken = false,
			moveViolations = 0,
			awarded = false,
			out = false,
			leavePayout = nil,
			lastHud = nil,
			lastHudAt = 0,
			bonusOffers = {},
			swapOffer = nil,
			matchSig = nil,
		}
		c.members[p] = pr
		c.heroes[pr.userId] = pr
		pcall(function()
			p:SetAttribute("Squad", pr.squad) -- 1..4 (HeroDecor / CosmeticsService / client)
			p:SetAttribute("ClassId", classId)
		end)
	end
	ctx = c
	LobbyService.setRunActive(true, party)
	for _, h in c.heroes do
		local ok, err = pcall(computeStats, c, h)
		if not ok then
			warn("[RunDirector] Stats.compute failed: " .. tostring(err))
		end
	end
	for _, p in party do
		local pr = c.members[p]
		local mates = 0
		for _, id in match:squad(pr.squad).members do
			if id ~= pr.userId then
				mates += 1
			end
		end
		Remotes.toast(
			p,
			string.format(
				"You're on squad %s with %d mate%s. 4 squads, 1 map: last herd wins!",
				squadName(pr.squad),
				mates,
				if mates == 1 then "" else "s"
			),
			"info"
		)
	end
	sendPartyHud(c, true)

	local ok, err = xpcall(runLoop, debug.traceback, c)
	if not ok then
		warn("[RunDirector] run crashed: " .. tostring(err))
		toastAll(c, "Something went wrong. Returning to the lobby.", "bad")
		pcall(finishRun, c) -- the wipe rule for everyone still in the run
	end
	teardown(c)
end

-- Player lifecycle ------------------------------------------------------------------------------------

local function onPlayerRemoving(player: Player)
	local c = ctx
	if not c or not c.members[player] then
		return
	end
	local pr = c.members[player]
	if not pr.awarded then
		-- The leaver rule (keep half the share, nothing on DoN); paid from beforeRelease.
		local ok, po = pcall(c.match.removeMember, c.match, pr.userId)
		pr.leavePayout = if ok then po else nil
		departed[player] = { c = c, pr = pr }
		task.delay(120, function()
			departed[player] = nil
		end)
	else
		pcall(c.match.removeMember, c.match, pr.userId)
	end
	c.members[player] = nil
	pr.out = true
	removeFromWorld(c, pr.userId)
	local v = c.voting
	if v then
		pcall(v.vote.removeVoter, v.vote, pr.userId)
		v.humanVotes[pr.userId] = nil
	end
	local x = c.extract
	if x and x.votes[pr.squad] then
		pcall(x.votes[pr.squad].removeVoter, x.votes[pr.squad], pr.userId)
		if x.humanVotes[pr.squad] then
			x.humanVotes[pr.squad][pr.userId] = nil
		end
	end
	if next(c.members) == nil and not c.finished then
		c.aborted = true -- bots never hold a run open
	else
		pcall(c.run.setPlayerCount, c.run, c.match:difficulty())
		local w = c.world
		if w then
			pcall(function()
				w:setMods(c.match:worldMods())
			end)
		end
		sendPartyHud(c, true)
		sendMatch(c, true)
	end
end

local function onPlayerAdded(player: Player)
	local c = ctx
	local pr = c and c.members[player]
	if c and pr and not pr.out then
		Remotes.runState(publicState(c, pr), player)
	else
		Remotes.runState(lobbyRunState(), player)
	end
end

-- Run members who respawn go back to their squad corner (if an arena is built).
local function characterOverride(player: Player, _character: Model): boolean
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or pr.out or not c.arena then
		return false
	end
	teleportToArena(c, pr)
	decorate(c, pr)
	if pr.stats and not isDowned(c, pr.userId) and finite(pr.stats.moveSpeed) then
		setHumanoidSpeed(player, pr.stats.moveSpeed)
	end
	return true
end

-- HUD loop (also drains world events if CombatService.events is unavailable).
local function hudLoop()
	local acc = 0
	while true do
		local dt = task.wait(RunDirector.HUD_INTERVAL)
		local c = ctx
		if c and not c.finished then
			if not combatEventsConnected and c.world and type(c.world.drainEvents) == "function" then
				local ok, events = pcall(c.world.drainEvents, c.world)
				if ok then
					onCombatEvents(events)
				end
			end
			for s, list in c.buffs do
				if #list > 0 and Pois.pruneBuffs(list, simNow()) then
					local okB, errB = pcall(refreshSquad, c, s)
					if not okB then
						warn("[RunDirector] buff expiry: " .. tostring(errB))
					end
				end
			end
			for _, p in memberList(c) do
				local ok, err = pcall(sendHud, c, c.members[p])
				if not ok then
					warn("[RunDirector] hud: " .. tostring(err))
				end
			end
			acc += dt
			if acc >= RunDirector.PARTY_INTERVAL then
				acc = 0
				pcall(sendPartyHud, c)
				pcall(sendMatch, c)
			end
		end
	end
end

-- Leave-time payout (DataService.beforeRelease; also covers server shutdown).
local function payLeaver(player: Player)
	local c: Ctx?, pr: PlayerRun? = nil, nil
	local live = ctx
	if live and live.members[player] then
		c, pr = live, live.members[player]
	else
		local d = departed[player]
		if d then
			c, pr = d.c, d.pr
		end
	end
	departed[player] = nil
	if not c or not pr or pr.awarded or not isHuman(player) then
		return
	end
	if not pr.leavePayout then
		local ok, po = pcall(c.match.removeMember, c.match, pr.userId)
		pr.leavePayout = if ok and po then po else c.match:payout(pr.userId)
	end
	payMember(c, pr)
end

-- Public API -----------------------------------------------------------------------------------------

local initialized = false

function RunDirector.init()
	if initialized then
		return
	end
	initialized = true

	Guard.connect(Net.C2S.Vote, { rate = 4, burst = 6, args = { Guard.T.int(1, 16) } }, onVote)
	Guard.connect(
		Net.C2S.ChooseUpgrade,
		{ rate = 4, burst = 6, args = { Guard.T.int(1, 2 ^ 31), Guard.T.int(1, 16) } },
		onChooseUpgrade
	)
	Guard.connect(
		Net.C2S.RerollUpgrade,
		{ rate = 2, burst = 3, args = { Guard.T.int(1, 2 ^ 31) } },
		onRerollUpgrade
	)
	Guard.connect(Net.C2S.UseAbility, {
		rate = 10,
		burst = 10,
		args = { Guard.T.number(-AIM_LIMIT, AIM_LIMIT), Guard.T.number(-AIM_LIMIT, AIM_LIMIT) },
	}, onUseAbility)
	Guard.connect(Net.C2S.UseSecondWind, { rate = 2, burst = 2, args = {} }, onUseSecondWind)
	-- v2 remotes (R3 owns SelectPerk / ResetPerks / SelectAbility / SelectSkin)
	Guard.connect(
		Net.C2S.ExtractVote,
		{ rate = 4, burst = 6, args = { Guard.T.enum(CHOICES) } },
		onExtractVote
	)
	Guard.connect(Net.C2S.SwapGear, { rate = 4, burst = 4, args = { Guard.T.boolean() } }, onSwapGear)
	Guard.connect(
		Net.C2S.BuyCartItem,
		{ rate = 3, burst = 4, args = { Guard.T.int(-2 ^ 31, 2 ^ 31), Guard.T.int(1, 8) } },
		onBuyCartItem
	)

	connectCombatEvents()
	if DataService and type(DataService.beforeRelease) == "function" then
		local ok, err = pcall(DataService.beforeRelease, payLeaver)
		if not ok then
			warn("[RunDirector] DataService.beforeRelease failed: " .. tostring(err))
		end
	end
	LobbyService.setCharacterOverride(characterOverride)
	LobbyService.onStart(startRun)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end
	task.spawn(hudLoop)
end

function RunDirector.isRunning(): boolean
	return ctx ~= nil
end

-- "Lobby" | "Waves" | "Boss" | "RouteChoice" | "Extraction" | "Results"
function RunDirector.getPhase(): string
	local c = ctx
	return if c then phaseOf(c) else "Lobby"
end

-- Read-only debug / test view of the match (MatchState:getPublic, no viewer).
function RunDirector.getMatchView(): { [string]: any }?
	local c = ctx
	return if c then c.match:getPublic(nil, aliveOf(c)) else nil
end

return RunDirector
