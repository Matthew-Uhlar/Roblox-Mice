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
--
-- v4 (docs/V4-PLAN.md, team M2 "Match flow"):
--   * The Melt: each stage drives Config/Storm through world:setZone (waves:
--     Storm.zoneAt on the wave clock; boss: Storm.bossZone, the squeeze after
--     90 s) and sends S2C Storm {cx, cz, r, toR, closeStart, closeEnd, dps, now,
--     serverNow, stage, step} (world-clock times; `now` = the world clock).
--     Squad safe corners switch off at Storm.SAFE_CORNERS_OFF.
--   * Squads: bot-only squads extract from the stage-2 gate (MatchState.botExtractRule);
--     a labelled 🤖 Rival Herd enters at a stage start when <= 1 squad is left.
--   * Herd Call: a dead hero with a standing squadmate returns after 20/25/30/35 s
--     (minus 3 s per champion kill, 2 s per enemy hero downed, 1 s per POI by the
--     squad) at 60% HP with 5 s protection, once per stage, never during the boss
--     or the last 20 s of the waves. S2C Redeploy {untilT} (server time; {} = none).
--   * Payouts: secured cheese, the 40-per-stage floor, top-damage champion / boss
--     rewards with the Snatch bonus, Double or Nothing x2 (MatchState).
--   * Late joiners take a bot's seat (next stage start, or a bot's redeploy);
--     without a seat they get the practice yard (attribute PracticeYard).
--   * PlayAgain: TeleportService to a fresh server (self + party), only for
--     players who are out of a match; never automatic.
--   * Rookie Run (profile.stats.runs 0-2): world:setRookie, no bounty, run 1's
--     first champion at x0.7 HP and Extract pre-selected at the first gate, no
--     Double or Nothing before run 3, a first-extraction bonus.
--   * Pings and quick-chat (Ping / QuickChat -> S2C PingShown to the squad;
--     bots obey through BotService.ping), Herd Awards (S2C Awards) at results.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
local RunWallet = require(RunFolder:WaitForChild("RunWallet")) :: any

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
RunDirector.WAVE_SECONDS = 132 -- iteration 2: 4 waves x 30 s + 3 lulls x 4 s (Run/Waves; tests shorten it)
RunDirector.BOSS_SECONDS = 120 -- boss still alive: the top damage squad wins (iteration 3 T-3: was 180)
RunDirector.VOTE_SECONDS = 15 -- the winning squad's route choice
RunDirector.ROUTE_DEFAULT_SECONDS = 2 -- nobody won: the Low card, after a short beat
RunDirector.EXTRACT_SECONDS = 20 -- Rind Gate extraction window
-- iter 5 #6 Overtime: after the final boss the surviving squads may choose Overtime
-- (MatchState): endless waves, mice HP / damage x MatchState.overtimeMult(wave)
RunDirector.OVERTIME = true
RunDirector.OVERTIME_WAVE_SECONDS = 45
RunDirector.OVERTIME_CLASS_XP = 15 -- class XP per Overtime wave survived (on top of the run's)
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
local GEAR_SLOTS = { "weapon", "armor", "trinket" }
-- Small constants share one local: this module is close to Luau's 200-local limit.
local K = {
	RARITY_RANK = { Common = 1, Rare = 2, Epic = 3, Legendary = 4 },
	DEFAULT_WALKSPEED = 16,
	AIM_LIMIT = 100000,
	CartRules = require(RunFolder:WaitForChild("CartRules")) :: any,
	-- v3 Mouse Champions (GDD-v2 §4b): logic (stacking buff, list) and data (names)
	Champions = require(CombatFolder:WaitForChild("Champions")) :: any,
	ChampDefs = require(ConfigFolder:WaitForChild("Champions")) :: any,
	CHAMP_GRID = 8, -- Match signature: champion positions quantised to this many studs
	-- holding cap for the Epic-drop reroll fallback (Config/Shop TOKEN_CAPS)
	REROLL_CAP = ((optionalRequire(ConfigFolder, "Shop") or {}).TOKEN_CAPS or {}).rerollTokens or 30,
	-- iteration 2 (the module is near Luau's 200-local limit: these live in K)
	Difficulty = require(RunFolder:WaitForChild("Difficulty")) :: any,
	Waves = require(RunFolder:WaitForChild("Waves")) :: any,
	Pace = require(RunFolder:WaitForChild("Pace")) :: any, -- iteration 6 (team Flow)
	Economy = require(ConfigFolder:WaitForChild("Economy")) :: any, -- iteration 6: the cheese grind
	-- v4 (team M1 / P modules; guarded: they may land later)
	Storm = optionalRequire(ConfigFolder, "Storm"),
	PING_KINDS = { "go", "enemy", "champion", "loot", "extract", "stay", "help" },
	QUICK_CHAT = {
		"Nice!",
		"Thanks!",
		"Follow me",
		"Wait",
		"Group up",
		"Champion!",
		"Extract?",
		"Let's stay!",
	},
	PING_TTL = 6, -- s a ping marker lasts
	PING_ACTIVE = 3, -- active pings per player
	-- profile.stats.runs < ROOKIE_RUNS = Rookie Run (team P's ProfileSchema.ROOKIE_RUNS, 3:
	-- runs 0-2); Double or Nothing and Pressure are hidden for the whole Rookie Run
	ROOKIE_RUNS = (function(): number
		local PS = optionalRequire(DataFolder, "ProfileSchema")
		return if type(PS) == "table" and type(PS.ROOKIE_RUNS) == "number" then PS.ROOKIE_RUNS else 3
	end)(),
	ROOKIE_CHAMP_HP = 0.7, -- run 1: the first champion's HP
	INVITE_SECONDS = 60, -- PlayAgain: a party member may follow into the reserved server this long
	invites = {} :: { [Player]: { code: string, untilT: number, from: number } },
	outPlayers = {} :: { [Player]: boolean }, -- on their Results screen (PlayAgain allowed)
	teleporting = {} :: { [Player]: boolean },
	pingLog = {} :: { [Player]: { number } },
}
local LIVE_PHASES = { Waves = true, Boss = true, RouteChoice = true, Extraction = true, Overtime = true } -- iter 5 #6

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
	abilities: { any }?, -- iteration 5: every equipped ability (slot order; [1] == ability)
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
	cartPoi: any?, -- the Shop Cart this human has open (live updates)
	cartShare: number?, -- the share last sent with it
	rookieRuns: number?, -- v4: profile.stats.runs at the start when 0..2 (Rookie Run)
	hideDoN: boolean?, -- v4: Double or Nothing hidden (Rookie Run)
	seen: any?, -- v4: {maps, bosses, champions, mice, gear} ids met this run (awardRun / Mousepedia)
	questBuf: { [string]: number }?, -- v4: live quest counts waiting for the next flush
	waveSeconds: number?, -- v4 (QC minor 3): seconds of waves played
	playSeconds: number?, -- iteration 1: seconds of waves and boss played (class XP)
	joinedClock: number?, -- iter 5 #8: os.clock() when this player entered the run (time played)
	spectating: number?, -- iteration 1: the hero this dead player watches
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
	abilities: { any }?, -- iteration 5: every equipped ability (slot order)
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
	prefilled: { [number]: boolean }?, -- v4 Rookie Run: Extract pre-selected (not a real vote yet)
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
	dmgBanked: { [number]: number }?, -- iter 5 #8: damage dealt in earlier stages' Worlds
	otVotes: { [number]: { [number]: boolean } }?, -- iter 5 #6: squad -> humans voting to leave Overtime
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
	-- v4
	storm: any?, -- {R, stage, seed, waveT0?, bossT0?, step?, safeOff?, zone?}
	waveEndsAt: number?, -- server time the waves end (Herd Call window)
	tally: { [number]: { [string]: number } }, -- per hero award stats
	joinQueue: { Player }, -- late joiners waiting for a bot's seat
	firstChampDone: boolean, -- run 1 rookie: the first champion got x0.7 HP
	nextBotN: number, -- Ids.botId counter for Rival Herd bots
	-- v5
	wallets: { [number]: any }, -- id -> Run/RunWallet
	walletDirty: { [number]: boolean },
	worldRinds: boolean, -- the World sends `rinds` events (no RunDirector fallback)
	shops: any?, -- the Stalls payload {stalls, altar, swap}
	-- iteration 2
	tier: number?, -- the ladder tier (Run/Difficulty; 0 = Custom)
	skipWaveAt: number, -- the leader's Early Horn setting (0 = Off)
	pace: string, -- iteration 6 (team Flow): Run/Pace id ("normal" | "fast")
	waves: any?, -- Run/Waves state of the current stage's horde
	waveFx: any?,
	flags: { [number]: { [string]: any } }, -- challenge flags per human
	knockedOut: { [number]: boolean }, -- every hero knocked out this match
	squadChampKills: { [number]: number },
	squadStandingAtExtract: { [number]: boolean },
	solo: boolean, -- the only human in the server
	oneHit: boolean, -- the one-hit curse was active at some point
	gemRng: any,
	waveWorldT0: number?, -- the world time the current wave started (storm close times)
	gemFxId: number?,
}

local ctx: Ctx? = nil
-- Humans who left mid-run, kept until DataService's beforeRelease pays them.
local departed: { [Player]: { c: Ctx, pr: PlayerRun } } = {}

-- Helpers ----------------------------------------------------------------------------

local function finite(v: any): boolean
	return Guard.isFiniteNumber(v)
end

local function serverNow(): number
	return game:GetService("Workspace"):GetServerTimeNow()
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

-- Returns DataService.awardRun's result table when it gives one (team P: the
-- first-extraction bonus, contracts and pass XP for the Results breakdown).
local function awardRun(player: Player, cheese: number, xp: number, stats: { [string]: any }): any
	if not isHuman(player) then
		return nil -- bots earn nothing
	end
	if DataService and type(DataService.awardRun) == "function" then
		local ok, res = pcall(DataService.awardRun, player, cheese, xp, stats)
		if not ok then
			warn("[RunDirector] DataService.awardRun failed: " .. tostring(res))
			return nil
		end
		return if type(res) == "table" then res else nil
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

-- Iteration 3 (U's T-17 card): what this run added to the profile, for Results.loot.
-- A snapshot before DataService.awardRun and a diff after it.
K.lootSnap = function(player: Player): any
	local profile = if isHuman(player) then getProfile(player) else nil
	if type(profile) ~= "table" then
		return nil
	end
	local d = if type(profile.difficulty) == "table" then profile.difficulty else {}
	local g = if type(profile.gems) == "table" then profile.gems else {}
	local done = {}
	if type(profile.challenges) == "table" then
		for id, v in profile.challenges do
			if v then
				done[id] = true
			end
		end
	end
	return {
		unlocked = if type(d.unlocked) == "number" then d.unlocked else 0,
		bestSolo = if type(d.bestSolo) == "number" then d.bestSolo else 0,
		nextId = if type(g.nextId) == "number" then g.nextId else math.huge,
		challenges = done,
	}
end

K.lootOf = function(player: Player, before: any): any
	local now = K.lootSnap(player)
	if not before or not now then
		return nil
	end
	local profile = getProfile(player)
	local gems = {}
	local inv = if type(profile.gems) == "table" then profile.gems.inv else nil
	if type(inv) == "table" then
		for _, gem in inv do
			if type(gem) == "table" and type(gem.id) == "number" and gem.id >= before.nextId then
				table.insert(gems, { id = gem.id, t = gem.t, u = gem.u })
			end
		end
	end
	local challenges = {}
	for id in now.challenges do
		if not before.challenges[id] then
			table.insert(challenges, id)
		end
	end
	table.sort(challenges, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return {
		gems = gems,
		tierUnlocked = if now.unlocked > before.unlocked then now.unlocked else nil,
		bestSolo = if now.bestSolo > before.bestSolo then now.bestSolo else nil,
		challenges = challenges,
	}
end

K.isRanked = function(pr: PlayerRun): boolean
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
K.combatOwnsSpeed = function(): boolean
	if type(CombatService.getWorld) ~= "function" then
		return false
	end
	local ok, w = pcall(CombatService.getWorld)
	return ok and w ~= nil
end

local function setHumanoidSpeed(player: Player, speed: number)
	if K.combatOwnsSpeed() then
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
		pressurePoints = 0,
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
	-- v4 Rookie Run (UI): DoN / Pressure hidden before run 3
	pub.rookie = pr.rookieRuns ~= nil
	pub.rookieRun = if pr.rookieRuns ~= nil then pr.rookieRuns + 1 else nil
	pub.hideDoubleOrNothing = pr.hideDoN == true
	pub.hidePressure = pr.hideDoN == true
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
	pub.champions = K.champView(c) -- v3: {{id, champId, x, z, hpFrac, lair}} (UI + minimap)
	pub.buffs = K.buffView(c, pr.squad) -- v3: squad buffs {{kind, untilT, stat, mul}} (HUD chips)
	pub.donMarkers = K.donMarkers(c) -- v4: {{squad, x, z}} Double-or-Nothing squads on the map
	-- iteration 2 (team U reads these): wave index / total / per stage, the boss
	-- wave, the horn {stomped %, need %, at (server time of the horn's wave start),
	-- streak (horns this stage), ready (a manual CallHorn would work now)}, the tier
	local ws = c.waves
	local fx = c.waveFx
	pub.wave = if fx then fx.index else nil
	pub.waves = K.Waves.total(MatchState.CONFIG.STAGES)
	pub.wavesPerStage = K.Waves.PER_STAGE
	pub.bossWave = phaseOf(c) == "Boss"
	if pub.bossWave then
		pub.wave = K.Waves.index(c.match.stage, K.Waves.PER_STAGE)
	end
	pub.horn = if ws
		then {
			stomped = math.floor(K.Waves.stomped(ws) * 100 + 0.5),
			need = c.skipWaveAt,
			at = if ws.phase == "horn" then fx and fx.endsAt else nil,
			streak = ws.horns,
			ready = K.Waves.canHorn(ws, os.clock(), c.skipWaveAt, true),
		}
		else nil
	pub.tier = c.tier
	pub.pace = K.Pace.view(c.pace) -- iteration 6 (team Flow): {id, name, fast?, ...}
	return pub
end

-- v3: the squad's live timed buffs (shrines, champion stacks) for the HUD.
K.buffView = function(c: Ctx, squad: number?): { any }
	local out = {}
	local list = if squad then c.buffs[squad] else nil
	if type(list) ~= "table" then
		return out
	end
	local now = simNow()
	for _, b in list do
		if type(b) == "table" and finite(b.untilT) and b.untilT > now then
			table.insert(out, {
				kind = tostring(b.kind),
				untilT = math.floor(b.untilT * 10 + 0.5) / 10,
				stat = b.stat,
				mul = b.mul,
			})
		end
	end
	return out
end

-- v3: the live Mouse Champions for the Match payload (main bodies only).
K.champView = function(c: Ctx): { any }
	local world = c.world
	if not world or type(world.champions) ~= "function" then
		return {}
	end
	local ok, list = pcall(world.champions, world)
	if not ok or type(list) ~= "table" then
		return {}
	end
	local out = {}
	for _, ch in list do
		table.insert(out, {
			id = ch.id,
			champId = ch.champId,
			x = math.floor(ch.x * 10 + 0.5) / 10,
			z = math.floor(ch.z * 10 + 0.5) / 10,
			hpFrac = math.floor(ch.hpFrac * 100 + 0.5) / 100,
			lair = ch.lair == true,
		})
	end
	return out
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
	-- champions: id, hp in 10% steps and position on an 8-stud grid (the Match
	-- payload goes out at most every PARTY_INTERVAL; a sitting champion costs nothing)
	for _, ch in pub.champions or {} do
		table.insert(
			parts,
			string.format(
				"c%d:%d:%d:%d",
				ch.id,
				math.floor(ch.hpFrac * 10 + 0.5),
				math.floor(ch.x / K.CHAMP_GRID + 0.5),
				math.floor(ch.z / K.CHAMP_GRID + 0.5)
			)
		)
	end
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
	for _, b in pub.buffs or {} do
		table.insert(parts, string.format("b%s:%d", tostring(b.kind), math.floor(b.untilT)))
	end
	table.insert(
		parts,
		string.format(
			"w%s:%s:%s",
			tostring(pub.wave),
			tostring(pub.horn and math.floor(pub.horn.stomped / 5)),
			tostring(pub.horn and pub.horn.ready)
		)
	)
	for _, d in pub.donMarkers or {} do
		table.insert(parts, string.format("d%d:%d:%d", d.squad, d.x, d.z))
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
local sendCart: (c: Ctx, pr: PlayerRun, poi: any, refresh: boolean?) -> ()

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
		-- an open Shop Cart follows the hero's own share live (it is what they spend)
		if pr.cartPoi ~= nil and c.carts[pr.cartPoi] and c.match:shareOf(pr.userId) ~= pr.cartShare then
			sendCart(c, pr, pr.cartPoi, true)
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
	local stats, weapon, ability, abilities = Stats.compute(
		h.classId,
		h.stacks,
		c.match:blessingsFor(h.squad),
		talents,
		talentDefTable,
		h.classState,
		h.runBonus -- iteration 1 (team P): DataService.runBonuses (board, evolution, charm aura)
	)
	if Gear and type(Gear.apply) == "function" and next(h.gear) ~= nil then
		local ok, s2, w2, a2 = pcall(Gear.apply, stats, weapon, ability, h.gear)
		if ok and type(s2) == "table" then
			stats = s2
			weapon = w2 or weapon
			ability = a2 or ability
			-- iteration 5: gear ability effects reach every slot
			local list = { ability }
			for k = 2, #(abilities or {}) do
				local okA, _, _, ak = pcall(Gear.apply, stats, nil, abilities[k], h.gear)
				table.insert(list, if okA and type(ak) == "table" then ak else abilities[k])
			end
			abilities = list
		end
	end
	-- iteration 2 (team M1): the meta max HP baked in by Stats.compute (P's runBonus)
	-- so the World caps it at +25% in PvP
	local rd = h.runBonus and h.runBonus.delta
	local metaHp = if type(rd) == "table"
			and type(rd.mul) == "table"
			and finite(rd.mul.maxHp)
		then rd.mul.maxHp
		else 1
	(stats :: any).metaHpMult = metaHp
	-- iteration 4: P's pveResist (gems; bots get BotBonus's 60%) -> stats.pveResist
	-- (World reads it, capped, PvE only)
	local rex = h.runBonus and h.runBonus.extras
	if type(rex) == "table" and finite(rex.pveResist) and rex.pveResist > 0 then
		local s = stats :: any
		s.pveResist = (if finite(s.pveResist) then s.pveResist else 0) + rex.pveResist
	end
	-- v5 run layer (ranks, whey buffs, ultimates): the World applies it through
	-- setRunMods; a World without it gets the layer folded in here
	local wallet = c.wallets[h.id]
	local world = c.world :: any
	if wallet and not (world and type(world.setRunMods) == "function") then
		local s = stats :: any
		s.pveDamageMult = s.pveDamageMult or 1
		pcall(Stats.applyDelta, stats, weapon, RunWallet.deltas(wallet, h.classId), 1)
	end
	h.stats, h.weapon, h.ability = withBuffs(c, h.squad, stats), weapon, ability
	h.abilities = if type(abilities) == "table" and #abilities > 0 then abilities else { ability }
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
		if type(world.setPlayerAbilities) == "function" and h.abilities then
			pcall(world.setPlayerAbilities, world, h.id, h.abilities) -- iteration 5: every slot
		elseif type(world.setPlayerAbility) == "function" and h.ability then
			pcall(world.setPlayerAbility, world, h.id, h.ability)
		end
	end
	if not h.isBot and not isDowned(c, h.id) and h.stats and finite(h.stats.moveSpeed) then
		setHumanoidSpeed(h.player, h.stats.moveSpeed)
	end
end

-- Iteration 4: the hero level's fixed gains (+3% HP, +2% damage, +1 armor every 5)
-- ride on the run layer (RunWallet.deltas -> World.setRunMods).
K.levelGains = function(c: Ctx, h: any)
	if RunWallet.setLevel(K.walletOf(c, h.id), h.level) then
		K.applyRunMods(c, h)
	end
end

K.offerLuck = function(c: Ctx, stats: any): number
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
	local luck = K.offerLuck(c, h.stats) + (if source == "chest" then 1 else 0)
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
	local oldLevel = pr.level
	local newLevel, newXp, gained = Leveling.addXp(pr.level, pr.xp, amount)
	pr.level, pr.xp = newLevel, newXp
	if gained and gained > 0 then
		K.levelGains(c, pr) -- iteration 4: fixed per-level stats (the run layer)
		K.heroJoinedWorld(c, pr) -- v4: world:setHeroLevel (mice scale with hero levels)
		if DataService and type(DataService.questEvent) == "function" then
			task.spawn(pcall, DataService.questEvent, pr.player, "runLevel", newLevel) -- the Rookie contract
		end
		local hadOffer = pr.offer ~= nil
		-- iteration 4: upgrade cards only as milestone picks (every 5 levels)
		local picks = Leveling.milestones(oldLevel, newLevel)
		pr.pendingLevels += picks
		Remotes.toast(
			pr.player,
			if picks > 0
				then string.format("Level %d! Milestone pick ready.", newLevel)
				else string.format("Level %d!", newLevel),
			"good"
		)
		if picks == 0 then
			return
		end
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
	local oldLevel = b.level
	local newLevel, newXp, gained = Leveling.addXp(b.level, b.xp, amount)
	b.level, b.xp = newLevel, newXp
	if gained and gained > 0 then
		K.levelGains(c, b)
		K.heroJoinedWorld(c, b)
	end
	for _ = 1, math.min(Leveling.milestones(oldLevel, newLevel), 10) do
		local ok, err = pcall(botLevelUp, c, b)
		if not ok then
			warn("[RunDirector] bot level-up failed: " .. tostring(err))
		end
	end
end

-- HUD ---------------------------------------------------------------------------------------

local function secondWindsAvailable(c: Ctx, pr: PlayerRun): number
	local ok, n = pcall(
		RunTokens.secondWindsAvailable,
		pr.tokens,
		tokenProfile(pr.player),
		stageKey(c),
		{ squadsInRun = #c.match:squadsInRun() }
	)
	return if ok and finite(n) then math.max(0, math.floor(n)) else 0
end

-- iteration 5 (A3): per-slot ability arrays in slot order (World.getPlayer):
-- abilityReadyAts / abilityCooldowns / abilityIds / abilityNames, abilitySlots = n;
-- abilityReadyAt stays slot 1. shallowEqual compares these arrays element-wise.
K.hudSlots = function(payload: { [string]: any }, info: any?, pr: any)
	local ats, cds, ids, names = {}, {}, {}, {}
	local list = pr.abilities or { pr.ability }
	local wIds = info and info.abilityIds
	local n = if type(wIds) == "table" then #wIds else #list
	for k = 1, n do
		local def = list[k]
		local a = info and info.abilityReadyAts
		local c = info and info.abilityCooldowns
		local nm = info and info.abilityNames
		ats[k] = if type(a) == "table" and finite(a[k]) then a[k] else 0
		cds[k] = if type(c) == "table" and finite(c[k])
			then c[k]
			elseif type(def) == "table" and finite(def.cooldown) then def.cooldown
			else 0
		ids[k] = if type(wIds) == "table"
			then wIds[k]
			elseif type(def) == "table" then def.id or def.kind
			else ""
		names[k] = if type(nm) == "table"
			then nm[k]
			elseif type(def) == "table" then def.name or def.kind
			else ""
	end
	payload.abilitySlots = n
	payload.abilityReadyAts = ats
	payload.abilityCooldowns = cds
	payload.abilityIds = ids
	payload.abilityNames = names
end

K.hudPayload = function(c: Ctx, pr: PlayerRun): any
	local info = c.world and c.world:getPlayer(pr.userId)
	local maxHp = if pr.stats and finite(pr.stats.maxHp) then pr.stats.maxHp else 100
	local winds = secondWindsAvailable(c, pr)
	local payload = {
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
	K.hudSlots(payload, info, pr)
	return payload
end

-- iteration 5: array values (the per-slot ability arrays) compare element-wise
local function sameArray(x: any, y: any): boolean
	if type(x) ~= "table" or type(y) ~= "table" or #x ~= #y then
		return false
	end
	for i, v in y do
		if x[i] ~= v then
			return false
		end
	end
	return true
end

local function shallowEqual(a: { [string]: any }?, b: { [string]: any }): boolean
	if not a then
		return false
	end
	for k, v in b do
		if a[k] ~= v and not (type(v) == "table" and sameArray(a[k], v)) then
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
	local payload = K.hudPayload(c, pr)
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
					local entry: { [string]: any } = {
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
					-- iteration 7 (team Systems): a downed squadmate's position (off-screen arrows)
					if info and info.downed == true and finite(info.x) and finite(info.z) then
						entry.x = math.floor(info.x + 0.5)
						entry.z = math.floor(info.z + 0.5)
					end
					payload[tostring(id)] = entry
					table.insert(
						sig,
						string.format(
							"%d:%d/%d:%s:%s:%d:%s,%s",
							id,
							entry.hp,
							entry.maxHp,
							tostring(entry.downed),
							tostring(entry.dead),
							entry.level,
							tostring(entry.x),
							tostring(entry.z)
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

-- Portal Charm: Extract keeps (1 + world:extractBonusOf(id)) of the share (R2);
-- without it, the bonus computeStats read from the gear stats stays.
local function updateExtractMults(c: Ctx)
	local world = c.world
	if not world or type(world.extractBonusOf) ~= "function" then
		return
	end
	for id in c.heroes do
		if c.match:isInRun(id) then
			local ok, bonus = pcall(world.extractBonusOf, world, id)
			if ok and finite(bonus) then
				c.match:setExtractMult(id, 1 + math.max(0, bonus))
			end
		end
	end
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
	pos = Vector3.new(pos.X, math.max(pos.Y, K.groundY(c, pos.X, pos.Z)), pos.Z) -- iteration 4: plateaus
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

K.applyLighting = function(mapId: string)
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
			ability = b.ability, -- v4: bots use their alternate abilities (BotBrain.new 4th arg)
			abilities = b.abilities, -- iteration 5: and every unlocked slot (BotBrain:setAbilities)
		})
	end
	local ok, err = pcall(BotService.spawnForRun, specs, c.arena, c.world, c.seed + c.stageIndex)
	if not ok then
		warn("[RunDirector] BotService.spawnForRun failed: " .. tostring(err))
	end
end

-- keepGear: an extracting hero takes their gear out of the run (no loot bag);
-- a disconnect leaves it in a bag (World default).
local function removeFromWorld(c: Ctx, id: number, keepGear: boolean?)
	local world = c.world
	if world then
		pcall(world.removePlayer, world, id, keepGear == true)
	end
end

-- Points of interest ------------------------------------------------------------------------

-- Squads a POI event rewards: the squad of `by` (contested POIs), else every squad in the run.
local function poiSquads(c: Ctx, e: any): { number }
	local s = if Squads.isValid(e.squad) then e.squad else c.match:squadOf(e.by)
	if s and c.match:isSquadInRun(s) then
		return { s }
	end
	return c.match:squadsInRun()
end

-- Rare POI found: profile.discoveries for the finding squad's humans (first find: unlock).
K.recordDiscovery = function(c: Ctx, kind: string, squads: { number })
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

K.onPoiActivated = function(c: Ctx, e: any)
	local kind = tostring(e.kind)
	local def = PoiDefs.get(kind)
	if not def then
		return
	end
	if def.mode == "camp" then
		toastAll(c, "An Elite Camp wakes up! Clear it for a chest!", "bad")
	end
	if def.rare then
		local ok, err = pcall(K.recordDiscovery, c, kind, poiSquads(c, e))
		if not ok then
			warn("[RunDirector] discovery failed: " .. tostring(err))
		end
	end
end

K.cartPrice = function(item: any, given: any): number
	if finite(given) and given > 0 then
		return math.floor(given)
	end
	if type(item) == "table" and finite(item.price) and item.price > 0 then
		return math.floor(item.price)
	end
	return RunDirector.CART_PRICES[if type(item) == "table" then item.rarity else ""] or 150
end

-- The cart charges the buyer's OWN pending share (MatchState.spendShare), so
-- the payload carries that share; `bought` is the authoritative sold state.
-- `refresh` marks a live update (a squad-mate bought, or the share changed):
-- the client applies it only while the panel is still open.
sendCart = function(c: Ctx, pr: PlayerRun, poi: any, refresh: boolean?)
	local cart = c.carts[poi]
	if not cart then
		return
	end
	local share = c.match:shareOf(pr.userId)
	pr.cartPoi, pr.cartShare = poi, share
	-- string keys: a sparse {[1] = true, [3] = true} would not survive the remote
	-- (Roblox cuts arrays at the first nil)
	local bought = {}
	for i, v in cart.bought do
		if v then
			bought[tostring(i)] = true
		end
	end
	Remotes.shopCart(pr.player, {
		poi = poi,
		offers = cart.offers,
		prices = cart.prices,
		bought = bought,
		share = share,
		refresh = refresh == true or nil,
	})
end

local buyCart: (c: Ctx, h: any, poi: any, index: number) -> (boolean, string?)

-- A Shop Cart opened (poiReward kind shop_cart_open {poi, by, squad, offers, prices, sold}).
-- The World owns the stock (takeCartOffer); the opener gets ShopCart, a bot buys
-- by BotBrain.chooseCartItem.
K.openCart = function(c: Ctx, e: any)
	local squad = if Squads.isValid(e.squad) then e.squad else c.match:squadOf(e.by)
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
		list[i] = K.cartPrice(item, prices and prices[i])
	end
	local bought = {}
	if type(e.sold) == "table" then
		for i, v in e.sold do
			if v then
				bought[i] = true
			end
		end
	end
	c.carts[e.poi] = {
		offers = offers,
		prices = list,
		squad = squad,
		bought = bought,
		x = if finite(e.x) then e.x else nil,
		z = if finite(e.z) then e.z else nil,
	}
	local h = heroOf(c, e.by)
	if not h or not c.match:isInRun(h.id) then
		return
	end
	if h.isBot then
		if type(BotBrain.chooseCartItem) == "function" then
			local ok, idx = pcall(
				BotBrain.chooseCartItem,
				offers,
				list,
				bought,
				c.match:shareOf(h.id),
				table.clone(h.gear)
			)
			if ok and Guard.isInt(idx, 1, #offers) then
				buyCart(c, h, e.poi, idx)
			end
		end
		return
	end
	sendCart(c, h, e.poi)
end

-- World-side effects already happened (heals, revives, crumbs); this pays the meta part.
local function onPoiReward(c: Ctx, e: any)
	local kind = tostring(e.kind)
	if kind == "shop_cart_open" or e.reward == "cart" then
		K.openCart(c, e)
		return
	elseif kind == "totem_owner" and e.totem ~= nil and e.totem ~= "power" then
		-- iteration 5 #4: Whey / Crumb Totem (World applies the multiplier itself)
		local s = if Squads.isValid(e.squad) then e.squad else nil
		if s then
			for _, id in c.match:activeMembers(s) do
				K.tally(c, id, "totems")
			end
			K.questSquad(c, s, "totem")
			local pct = math.floor(((tonumber(e.mult) or 1) - 1) * 100 + 0.5)
			toastAll(
				c,
				if e.totem == "whey"
					then string.format("%s holds a Whey Totem! (+%d%% whey)", squadName(s), pct)
					else string.format("%s holds a Crumb Totem! (+%d%% XP)", squadName(s), pct),
				"info"
			)
		end
		return
	elseif kind == "totem_owner" then
		local s = if Squads.isValid(e.squad) then e.squad else nil
		if s ~= c.totemSquad then
			c.totemSquad = s
			for _, id in (if s then c.match:activeMembers(s) else {}) do
				K.tally(c, id, "totems")
			end
			K.questSquad(c, s, "totem")
			if s then
				toastAll(
					c,
					string.format(
						"%s holds the Power Totem! (+%d%% damage)",
						squadName(s),
						math.floor(((PoiDefs.TOTEM_DAMAGE_MULT or 1.2) - 1) * 100 + 0.5)
					),
					"info"
				)
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
	local isVault = kind == "vault" or reward == "vault"
	-- v4 Herd Call: a POI cuts the squad's timers by 1 s
	K.cutSquad(c, c.match:squadOf(e.by), MatchState.CONFIG.REDEPLOY_CUT_POI)
	K.earn(c, e.by, nil, RunWallet.Shop.WHEY.poi) -- v5: +40 whey per POI
	if finite(e.cheese) and e.cheese > 0 then
		-- Cheese caches, the Cheese Vault: every member of the finding squad, Pressure applied.
		-- v4: the Vault is a secured reward (25% banks at once).
		local amount = RunState.applyPressureCheese(math.floor(e.cheese), c.match:pressurePoints())
		for _, s in squads do
			if isVault then
				c.match:addSquadReward(s, amount)
			else
				c.match:addSquadCheese(s, amount)
			end
			toastSquad(
				c,
				s,
				string.format(
					"%s: +%d Cheese each%s",
					name,
					amount,
					if isVault then " (25% secured)" else " (pending)"
				),
				"good"
			)
		end
		if isVault then
			toastAll(c, squadName(squads[1]) .. " cracked the Cheese Vault!", "info")
			K.tally(c, e.by, "vaults")
			for _, sq in squads do
				K.questSquad(c, sq, "vault")
			end
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
	elseif reward == "beacon" or reward == "rescue" or reward == "escort" then
		K.onObjective(c, e, reward, squads, name)
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

-- Iteration 4 objectives (team M1's Combat/Pois): beacon chains, rescues and the caravan
-- escort come as poiReward (cheese via the usual branch; `whey` here, else Config/RunShop
-- WHEY); a finished one also pays OBJECTIVE_RINDS (x the stage scale) to each member. A
-- rescue rallies the squad: Herd Call timers cut by RESCUE_CUT s per freed elephant.
-- Miniboss camps: the World pays (Combat/Champions); minibossDead counts it here.
K.BotBonus = require(RunFolder:WaitForChild("BotBonus")) :: any
K.RESCUE_CUT = 5

-- Team G's objective models (server/Visuals/ObjectiveModels; PrimaryPart "Base" at the
-- ground). ArenaBuilder names each POI model "POI_<kind>" with X / Z attributes: the
-- model of a World POI is the one at its layout spot. Beacons light in the capturing
-- squad's colour, a finished rescue frees its elephant, the caravan model follows the
-- escort entity (World's pathing keeps to bridges; models only follow), lifted onto
-- plateaus with ArenaBuilder.heightAt.
K.OBJECTIVE_KINDS = { caravan = true, beacon = true, rescue_cage = true }
K.objectiveModels = function(): any
	if K._objMods == nil then
		local folder = script.Parent.Parent:FindFirstChild("Visuals")
		K._objMods = optionalRequire(folder, "ObjectiveModels") or false
	end
	return K._objMods or nil
end

K.groundY = function(c: Ctx, x: number, z: number): number
	local arena = c.arena
	local base = if type(arena) == "table" and typeof(arena.center) == "Vector3" then arena.center.Y else 0
	if type(ArenaBuilder.heightAt) == "function" then
		local ok, y = pcall(ArenaBuilder.heightAt, x, z)
		if ok and finite(y) then
			return base + y
		end
	end
	return base
end

K.indexObjective = function(c: Ctx, poiId: number, entry: any)
	local arena = c.arena
	local model = type(arena) == "table" and arena.model
	if not entry or not K.OBJECTIVE_KINDS[entry.kind] or typeof(model) ~= "Instance" then
		return
	end
	for _, m in (model :: Instance):GetDescendants() do
		if m:IsA("Model") and m:GetAttribute("PoiId") == entry.kind then
			local mx, mz = m:GetAttribute("X"), m:GetAttribute("Z")
			if
				finite(mx)
				and finite(mz)
				and math.abs(mx - entry.x) < 0.5
				and math.abs(mz - entry.z) < 0.5
			then
				c.objModels = c.objModels or {}
				c.objModels[poiId] = m
				return
			end
		end
	end
end

K.objectiveDone = function(c: Ctx, e: any, reward: string, squad: number?)
	local OM = K.objectiveModels()
	local m = c.objModels and c.objModels[e.poi]
	if not OM or not m then
		return
	end
	if reward == "beacon" and type(OM.setBeacon) == "function" then
		local def = if squad then Squads.get(squad) else nil
		local rgbT = if def then def.color else nil
		local col = if type(rgbT) == "table" then Color3.fromRGB(rgbT[1], rgbT[2], rgbT[3]) else nil
		pcall(OM.setBeacon, m, col)
	elseif reward == "rescue" and type(OM.setFreed) == "function" then
		pcall(OM.setFreed, m)
	end
end

K.moveCaravans = function(c: Ctx)
	local world = c.world :: any
	if not world or not c.objModels or type(world.pois) ~= "function" then
		return
	end
	for _, e in world:pois() do
		local m = c.objModels[e.id]
		if e.kind == "caravan" and m and m.PrimaryPart and finite(e.x) and finite(e.z) then
			local last = m:GetPivot().Position
			local dx, dz = e.x - last.X, e.z - last.Z
			if dx * dx + dz * dz > 0.04 then
				local pos = Vector3.new(e.x, K.groundY(c, e.x, e.z), e.z)
				m:PivotTo(CFrame.lookAt(pos, pos + Vector3.new(dx, 0, dz)))
			end
		end
	end
end

K.onObjective = function(c: Ctx, e: any, reward: string, squads: { number }, name: string)
	local done = reward ~= "beacon" or e.chainDone == true
	local key = if reward == "beacon" then "beaconChain" else reward
	pcall(K.objectiveDone, c, e, reward, squads[1])
	local Shop = RunWallet.Shop
	local whey = if finite(e.whey) then math.max(0, e.whey) elseif done then Shop.WHEY[key] or 0 else 0
	local rinds = if done
		then RunWallet.rindsFor("mouse", c.match.stage) / Shop.RINDS.mouse * (Shop.OBJECTIVE_RINDS[key] or 0)
		else 0
	for _, s in squads do
		for _, id in c.match:activeMembers(s) do
			K.earn(c, id, rinds, whey)
			if done then
				K.tally(c, id, "objectives")
			end
		end
		if done then
			K.questSquad(c, s, reward)
			local text
			if reward == "beacon" then
				text = "Beacon chain lit! The signal pays your squad."
			elseif reward == "rescue" then
				local n = if finite(e.rescued) then math.max(1, math.floor(e.rescued)) else 1
				K.cutSquad(c, s, K.RESCUE_CUT * n)
				text = string.format("%d elephants freed! They rally the herd.", n)
			else
				text = "The " .. name .. " arrived! Your squad is paid."
			end
			toastSquad(c, s, text, "good")
		end
	end
end

K.onMinibossDead = function(c: Ctx, e: any)
	local s = if Squads.isValid(e.squad) then e.squad else nil
	if not s then
		return
	end
	for _, id in c.match:activeMembers(s) do
		K.tally(c, id, "minibosses")
	end
	K.questSquad(c, s, "miniboss")
	K.questSquad(c, s, "lair") -- contracts count a miniboss like a lair champion
	c.squadChampKills[s] = (c.squadChampKills[s] or 0) + 1 -- Champion Hunter
	local who = if type(e.name) == "string" then e.name else "A miniboss"
	toastAll(c, string.format("%s fell to %s!", who, squadName(s)), "info")
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

K.openPortal = function(c: Ctx, center: Vector3)
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

K.classXpFor = function(summary: any): number
	if ClassProgress and type(ClassProgress.runXp) == "function" then
		local ok, xp = pcall(ClassProgress.runXp, summary)
		if ok and finite(xp) then
			return math.max(0, math.floor(xp))
		end
	end
	return MatchState.classXpFallback(summary)
end

-- iter 5 #8: damage a hero dealt this run, from the World's damage meter (team
-- Abilities' world:meter() -> {[id] = {dmg, ...}}, per stage World) plus what
-- earlier stages' Worlds recorded (K.bankMeter). 0 while the World has no meter.
K.meterDamage = function(world: any, id: number): number
	if not world or type(world.meter) ~= "function" then
		return 0
	end
	local ok, m = pcall(world.meter, world)
	local e = if ok and type(m) == "table" then m[id] or m[tostring(id)] else nil
	local d = if type(e) == "table" then e.dmg else nil
	return if finite(d) and d > 0 then d else 0
end
K.bankMeter = function(c: Ctx)
	local world = c.world
	if not world then
		return
	end
	c.dmgBanked = c.dmgBanked or {}
	for id in c.heroes do
		local d = K.meterDamage(world, id)
		if d > 0 then
			c.dmgBanked[id] = (c.dmgBanked[id] or 0) + d
		end
	end
end
-- iteration 5 #1 (team Abilities): the full damage meter for S2C Meter and Results.
-- `meterBank` = earlier stages' Worlds (K.bankFullMeter at buildStage) + the live World.
RunDirector.METER_INTERVAL = 1 -- s between S2C Meter sends (~1 Hz)
local METER_KEYS = { "dmg", "pveDmg", "pvpDmg", "heal", "taken", "kills", "deaths" }
K.bankFullMeter = function(c: Ctx)
	local world = c.world :: any
	if not world or type(world.meter) ~= "function" then
		return
	end
	local ok, m = pcall(world.meter, world)
	if not ok or type(m) ~= "table" then
		return
	end
	local cm: any = c
	local bank = cm.meterBank or {}
	cm.meterBank = bank
	for id, e in m do
		local b = bank[id] or {}
		bank[id] = b
		for _, k in METER_KEYS do
			local v = e[k]
			if finite(v) then
				b[k] = (b[k] or 0) + v
			end
		end
	end
end
-- { [tostring(heroId)] = {name, squad, isBot, dmg, pveDmg, pvpDmg, heal, taken, kills, deaths} }
-- for every hero of the run (string keys: negative bot ids survive the remote).
K.meterView = function(c: Ctx): { [string]: any }
	local bank = (c :: any).meterBank or {}
	local live = {}
	local world = c.world :: any
	if world and type(world.meter) == "function" then
		local ok, m = pcall(world.meter, world)
		if ok and type(m) == "table" then
			live = m
		end
	end
	local out = {}
	for id, h in c.heroes do
		local b, l = bank[id], live[id]
		local e: { [string]: any } = {
			name = h.name,
			squad = h.squad,
			isBot = h.isBot == true,
		}
		for _, k in METER_KEYS do
			local v = (if b and finite(b[k]) then b[k] else 0) + (if l and finite(l[k]) then l[k] else 0)
			e[k] = math.floor(v + 0.5)
		end
		out[tostring(id)] = e
	end
	return out
end
K.sendMeter = function(c: Ctx)
	if not Net.S2C.Meter then
		return
	end
	local payload = K.meterView(c)
	for _, p in connectedMembers(c) do
		pcall(Remotes.fireTo, p, Net.S2C.Meter, payload)
	end
end
K.damageOf = function(c: Ctx, id: number): number
	return math.floor(((c.dmgBanked or {})[id] or 0) + K.meterDamage(c.world, id))
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
	-- iteration 2: the ladder tier's reward x (it replaces the per-point Pressure cheese)
	local tierMult = if c.tier ~= nil
		then K.Difficulty.reward(K.Difficulty.effective(c.tier, c.match.run:pressureBoard()))
		else 1
	local paceDef = K.Pace.get(c.pace) -- iteration 6 (team Flow): Fast pays x1.15
	-- iteration 6 (owner: "slower and pricier"): earned run cheese x0.6 for veterans
	-- (Config/Economy; the Rookie Run keeps x1). Rush / Feast (cheeseMult) are unchanged.
	local econMult = K.Economy.runMult(pr.rookieRuns)
	local mult = cheeseMult(p) * statMult * tierMult * paceDef.cheese * econMult
	local cheese = math.max(0, math.floor(po.cheese * mult + 0.5))
	local xp = math.max(0, math.floor(po.xp * xpMult(p) + 0.5))
	-- iteration 1 (P-2): class XP on a wipe counts minutes played, mice and champion
	-- assists (team P's ClassProgress.runXp computes the rule)
	local t = K.tallyOf(c, pr.userId)
	local summary = table.clone(po.summary) :: any
	summary.seconds = math.floor(pr.playSeconds or 0)
	summary.mice = t.mice or 0
	summary.championAssists = t.championAssists or 0
	summary.champAssists = summary.championAssists -- team P's name
	summary.tierReward = if c.tier ~= nil
		then K.Difficulty.reward(K.Difficulty.effective(c.tier, c.match.run:pressureBoard()))
		else 1
	summary.firstRun = pr.rookieRuns == 0
	local classXp = K.classXpFor(summary)
	if paceDef.classXp ~= 1 then
		classXp = math.floor(classXp * paceDef.classXp + 0.5) -- iteration 6: Fast x1.15
	end
	-- iter 5 #6: a modest class XP bonus per Overtime wave survived (no extra gems)
	local otWaves = if finite(po.overtimeWaves) then po.overtimeWaves else 0
	if otWaves > 0 then
		classXp += otWaves * RunDirector.OVERTIME_CLASS_XP
	end
	-- QC minor 3: a leaver who never really played (< 60 s of waves or no damage)
	-- gets no run credit: no awardRun (pass XP, contracts, runs + 1), no floor
	if po.result == "left" and po.engaged == false then
		pr.questBuf = {}
		return
	end
	pcall(K.flushQuests, c, pr)
	local fullClear = po.fullClear == true
	local wallet = c.wallets[pr.userId]
	local lootBefore = K.lootSnap(p)
	local award = awardRun(p, cheese, xp, {
		-- iteration 1 / v5 counts (team P computes the grants)
		seconds = summary.seconds,
		mice = summary.mice,
		championAssists = summary.championAssists,
		champAssists = summary.championAssists, -- team P's name
		stagesAlive = po.summary.stagesSurvived or 0,
		firstRun = summary.firstRun,
		stomps = summary.mice, -- the player's own mouse kills (no split)
		rindsEarned = if wallet then math.floor(wallet.rindsEarned) else 0,
		-- iteration 2 (team P records the ladder, grants gems, evaluates challenges)
		tier = if c.tier ~= nil then K.Difficulty.effective(c.tier, c.match.run:pressureBoard()) else nil,
		custom = c.tier == K.Difficulty.CUSTOM,
		tierReward = tierMult, -- x stomps and class XP (cheese already scaled)
		pace = c.pace, -- iteration 6 (team Flow): records stay per tier; Fast clears count
		solo = K.isSolo(c),
		clearSeconds = if fullClear or po.lastHerd
			then math.floor(c.cycle1Time or (os.clock() - c.startedAt)) -- iter 5 #6: Overtime never counts
			else nil,
		extractStage = if po.extracted then po.stage else nil,
		challengeFlags = K.challengeOf(c, pr, po),
		-- v4 M1: a win is Last Herd or an extraction at stage >= 3 (MatchState payout.won)
		won = if po.won ~= nil then po.won == true else po.extracted,
		cycle = 1, -- kept for compatibility (one cycle per run); bestStage / championKills replace it (B3)
		bestStage = po.bestStage or po.stage,
		championKills = po.championKills or 0,
		fullClear = fullClear,
		secured = po.secured,
		rookie = pr.rookieRuns ~= nil,
		-- v4 (team P's awardRun: wins, first-extraction bonus, pass XP, contracts,
		-- achievements and leaderboards are all handled there)
		stagesCleared = po.stagesCleared,
		banked = po.cheese, -- before Robux multipliers
		bossIds = K.keys(pr.seen and pr.seen.bosses),
		championIds = K.keys(pr.seen and pr.seen.champions),
		mapIds = K.keys(pr.seen and pr.seen.maps),
		bosses = po.stagesCleared,
		cycle1Time = if po.extracted and po.stagesCleared >= MatchState.CONFIG.STAGES
			then c.cycle1Time
			else nil,
		ranked = K.isRanked(pr),
		withBots = #c.bots > 0,
		day = math.floor(os.time() / 86400),
		-- v4 B1: the Pressure record only counts a full 4-stage clear
		pressurePoints = if fullClear then c.match:pressurePoints() else 0,
		runPressurePoints = c.match:pressurePoints(),
		-- v2 (R3: DataService adds the class XP; leaderboards)
		classId = pr.classId,
		classXp = classXp,
		stagesSurvived = po.summary.stagesSurvived,
		bossDamageShare = po.summary.bossDamageShare,
		-- leaderboard / profile stat: distinct enemy HUMANS downed (QC-B V2-m2);
		-- class XP above already counted every PvP down (capped)
		heroDowns = po.humanDowns,
		pois = po.summary.pois,
		extracted = po.extracted,
		lastHerd = po.lastHerd,
		pvpDowns = po.downs,
		pvpKills = po.kills,
		squad = po.squad,
		result = po.result,
		placement = po.placement,
		-- iter 5 #6 / #8 (Data/LifetimeStats): time played, damage dealt, Overtime record
		playedSeconds = math.floor(os.clock() - (pr.joinedClock or c.startedAt)),
		damage = K.damageOf(c, pr.userId),
		overtimeWaves = otWaves,
	})
	local loot = K.lootOf(p, lootBefore)
	if p.Parent == Players then
		Remotes.results(p, {
			outcome = if po.extracted then "Win" else "Wipe",
			result = po.result,
			cheeseEarned = cheese,
			xpEarned = xp,
			cycle = 1,
			-- The stage the squad left at (an extraction after stage 2 shows 2, not 3).
			stage = if finite(po.stage) then po.stage else c.match.stage,
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
			-- v4
			won = po.won,
			bestStage = po.bestStage,
			championKills = po.championKills,
			secured = po.secured,
			rookie = pr.rookieRuns ~= nil,
			-- iteration 1 (P-9, P-8): what the hero did and what the profile gained
			mice = summary.mice,
			championAssists = summary.championAssists,
			pois = po.summary.pois,
			rivalsDowned = po.downs,
			seconds = summary.seconds,
			rindsEarned = if wallet then math.floor(wallet.rindsEarned) else nil,
			breakdown = K.breakdownList(po, cheese, mult, classXp, xp, award),
			breakdownDetail = {
				runCheese = po.cheese, -- before boosts
				secured = po.secured,
				boostMult = mult,
				cheese = cheese,
				classXp = classXp,
				accountXp = xp,
				stomps = summary.mice,
			},
			-- the fields team U's ResultsUI reads (filled from DataService.awardRun's
			-- result when team P returns one)
			firstExtract = K.firstExtractOf(award),
			contracts = award and award.contracts or nil,
			achievements = award and award.achievements or nil,
			passXp = award and award.passXp or nil,
			don = K.donOf(c, pr.userId),
			totalCheese = K.totalCheese(cheese, award),
			-- iteration 3: gems found, tier unlocked, Best Solo, challenges completed
			loot = loot,
			meter = K.meterView(c), -- iter 5 #1: the run's damage meter (S2C Meter shape)
			overtimeWaves = if otWaves > 0 then otWaves else nil, -- iter 5 #6
			pace = K.Pace.view(c.pace), -- iteration 6 (team Flow): Results notes the pace
			overtimeBest = if award then award.overtimeBest else nil, -- iter 5 #6: a new record
			-- iteration 7 (team Systems): {dust, kills} from miniboss kills (daily cap); the
			-- count of tier 13-14 gems from Overtime milestones (they are in loot.gems too)
			minibossDust = if award then award.minibossDust else nil,
			overtimeGems = if award then award.overtimeGems else nil,
		})
		K.showGems(c, p, loot and loot.gems) -- iteration 4: the round's gems fly up
	end
	K.tallyOf(c, pr.userId).banked = cheese
end

-- Members that just left the run (extracted / eliminated / Last Herd): pay the
-- humans at once and send them back to the lobby after their Results screen.
local function handleOut(c: Ctx, ids: { number }, removeHeroes: boolean)
	local leaving: { Player } = {}
	for _, id in ids do
		local h = c.heroes[id]
		if h and removeHeroes then
			removeFromWorld(c, id, true)
		end
		if h and not h.isBot and not h.out then
			h.out = true
			h.offer = nil
			h.swapOffer = nil
			K.outPlayers[h.player] = true -- v4 PlayAgain
			local m = c.match:member(id)
			if m and m.result == "extracted" and c.world then
				local info = c.world:getPlayer(id)
				if
					info
					and finite(info.hp)
					and finite(info.maxHp)
					and info.maxHp > 0
					and info.hp / info.maxHp < 0.3
				then
					K.tally(c, id, "escape") -- v4 awards (Escape Artist)
				end
			end
			local ok, err = pcall(payMember, c, h)
			if not ok then
				warn("[RunDirector] payout failed for " .. h.player.Name .. ": " .. tostring(err))
			end
			if h.player.Parent == Players then
				Remotes.match(h.player, matchPayload(c, h) :: any)
				Remotes.fireTo(h.player, Net.S2C.Redeploy, { untilT = nil })
				table.insert(leaving, h.player)
			end
		end
	end
	if #leaving > 0 and c.match.phase ~= "Results" then
		pcall(K.sendAwards, c, leaving, false) -- provisional: the match goes on
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
					K.outPlayers[p] = nil -- QC MAJOR 2: back in the lobby
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

-- Puts MatchState's bag cheese (30% of the hero's share) in the World.
--   * `worldBag` (heroKilled.bag): the World already dropped the hero's gear in
--     it, so only the cheese is added (world:addBagCheese).
--   * Otherwise a bag is made at the hero (world:addLootBag). An R2 World drops
--     the gear itself when the hero dies, so only a v1-style World gets the gear here.
-- No World support at all: the cheese goes back to the hero.
local function dropBag(
	c: Ctx,
	id: number,
	cheese: number,
	key: number?,
	worldBag: any?,
	x: number?,
	z: number?
)
	local h = c.heroes[id]
	local world = c.world
	if not key then
		return
	end
	if worldBag ~= nil and world and type(world.addBagCheese) == "function" then
		if cheese > 0 then
			local ok, added = pcall(world.addBagCheese, world, worldBag, cheese)
			if not ok or added == false then
				c.match:refundShare(id, cheese)
				return
			end
		end
		c.match:registerBag(worldBag, key)
	else
		local gear = if h and not c.pvpWorld then gearList(h) else {}
		if cheese <= 0 and #gear == 0 then
			return
		end
		if not world or type(world.addLootBag) ~= "function" then
			c.match:refundShare(id, cheese)
			return
		end
		local bx, bz = x, z
		if not (finite(bx) and finite(bz)) then
			bx, bz = heroPos(c, id)
		end
		local ok, bagId = pcall(world.addLootBag, world, bx, bz, gear, cheese)
		if not ok or bagId == nil then
			warn("[RunDirector] addLootBag failed: " .. tostring(bagId))
			c.match:refundShare(id, cheese)
			return
		end
		c.match:registerBag(bagId, key)
		if h and #gear > 0 then
			h.gear = {}
		end
	end
	if h then
		syncGear(c, h) -- the World took the gear into the bag
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
	K.tally(c, claim.by, "bounties")
	if memberById(c, claim.by) then
		local fl = K.flagsOf(c, claim.by)
		fl.bountiesDowned += 1 -- Bounty Breaker
	end
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
	local sq = c.match:squad(squad)
	if sq and sq.rival then
		toastAll(
			c,
			if c.match.stage >= MatchState.CONFIG.LAST_HERD_FROM_STAGE
				then "The 🤖 Rival Herd is beaten! Clear the stage to be the LAST HERD STANDING!"
				else "The 🤖 Rival Herd is beaten!",
			"good"
		)
	else
		toastAll(c, squadName(squad) .. " squad is eliminated!", "bad")
	end
	handleOut(c, res.out, false)
end

-- ===== iteration 7 (team Systems): death recap (#4) and "needs revive" auto-ping (#5) =====
K.DeathRecap = require(RunFolder:WaitForChild("DeathRecap")) :: any
K.revivePingAt = {} :: { [number]: number } -- hero id -> serverNow() of its last auto-ping

-- S2C DeathRecap to a downed / eliminated human (Run/DeathRecap.view for the shape).
K.sendDeathRecap = function(c: Ctx, id: number, eliminated: boolean, killerId: number?)
	local pr = memberById(c, id)
	local world = c.world
	if not pr or not pr.player or not world or type(world.deathRecap) ~= "function" then
		return
	end
	local ok, recap = pcall(world.deathRecap, world, id)
	if not ok or not recap then
		return
	end
	local view = K.DeathRecap.view(recap, eliminated, killerId, function(hid: number): any
		local h = c.heroes[hid]
		if not h then
			return nil
		end
		return { name = heroName(h), isBot = h.isBot == true, squad = h.squad }
	end, serverNow())
	if view then
		pcall(Remotes.fireTo, pr.player, Net.S2C.DeathRecap, view)
	end
end

-- The automatic "needs revive" ping: PingShown {kind = "revive", auto = true, by = the
-- downed hero, x, z, t} to the hero's squad humans (squadmates' off-screen arrows),
-- at most once per DeathRecap.REVIVE_PING_GAP s per hero. Only when a squadmate is
-- still standing (someone can come).
K.autoRevivePing = function(c: Ctx, id: number)
	local h = c.heroes[id]
	local world = c.world
	if not h or not world or not h.squad then
		return
	end
	local mates = squadHumans(c, h.squad)
	local any = false
	for _, p in mates do
		if p.UserId ~= id then
			any = true
			break
		end
	end
	if not any then
		return
	end
	local t = serverNow()
	if not K.DeathRecap.allowRevivePing(K.revivePingAt, id, t) then
		return
	end
	local info = world:getPlayer(id)
	if not info or not finite(info.x) or not finite(info.z) then
		return
	end
	Remotes.fireList(mates, Net.S2C.PingShown, {
		by = id,
		squad = h.squad,
		kind = K.DeathRecap.REVIVE_PING_KIND,
		auto = true,
		x = info.x,
		z = info.z,
		t = t,
	})
end
-- ===== end iteration 7 death recap / revive ping =====

local function onHeroDowned(c: Ctx, e: any)
	pcall(K.sendDeathRecap, c, e.id, false, nil) -- iteration 7 (team Systems)
	pcall(K.autoRevivePing, c, e.id)
	local r = c.match:heroDowned(e.id, e.by)
	if not r then
		return
	end
	-- v4 Herd Call: downing an enemy hero cuts the squad's timers by 2 s
	K.cutSquad(c, r.killerSquad, MatchState.CONFIG.REDEPLOY_CUT_DOWN)
	if r.killerSquad and memberById(c, e.by) then
		K.flagsOf(c, e.by).enemyDowned = true -- Peacekeeper
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
	pcall(K.sendDeathRecap, c, r.victim, true, r.killer) -- iteration 7 (team Systems)
	dropBag(c, r.victim, r.bagCheese, r.bagKey, e.bag, e.x, e.z)
	K.onDeath(c, r.victim) -- v4 Herd Call timer
	K.knockout(c, r.victim) -- v5: whey buffs and ultimates are lost
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

K.onGearPickup = function(c: Ctx, e: any)
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
K.onGearSwapOffer = function(c: Ctx, e: any)
	local h = heroOf(c, e.id)
	if not h or type(e.item) ~= "table" then
		return
	end
	local slot = if type(e.slot) == "string" then e.slot else e.item.slot
	if h.isBot then
		if type(BotBrain.chooseSwap) == "function" and BotService then
			return -- BotService answers bot swap offers (BotBrain.chooseSwap)
		end
		local current = e.current or h.gear[slot]
		local better = (K.RARITY_RANK[e.item.rarity] or 0) >= (K.RARITY_RANK[current and current.rarity] or 0)
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

K.onLootBag = function(c: Ctx, e: any)
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

-- Every squad in the run with nobody standing (all dead / downed in the World) is
-- eliminated now, through the normal path (loot bags, kill feed, payouts). Runs
-- right before the Rind Gate resolves: a wiped squad must never Extract.
local function eliminateFallen(c: Ctx)
	local world = c.world
	if not world or c.match.phase == "Results" then
		return
	end
	local fallen = c.match:fallenSquads(function(id: number): boolean?
		local info = world:getPlayer(id)
		if not info then
			return nil
		end
		return not info.downed and not info.dead
	end)
	for _, s in fallen do
		c.downSince[s] = nil
		eliminate(c, s)
	end
end

-- The route choice and the Rind Gate keep the squad wipe check running (the World
-- keeps stepping). True once the match is over.
local function gateOver(c: Ctx): boolean
	squadWipeCheck(c)
	return c.match.phase == "Results"
end

-- v3 Mouse Champions (GDD-v2 §4b): announce spawns to every squad; a kill pays
-- the rewarded squad (World already gave each member gear and xp): pending
-- cheese (Pressure applied) and the stacking squad buff, plus a kill feed entry
-- {kind = "champion", killer, killerSquad, champId, lair}.
K.onChampion = function(c: Ctx, e: any)
	local def = K.ChampDefs.get(tostring(e.champId))
	local name = if def then def.name else "A Mouse Champion"
	if e.type == "championSpawn" then
		pcall(K.softenChampion, c, e.champ) -- v4 Rookie Run: run 1's first champion x0.7 HP
		toastAll(
			c,
			if e.lair == true
				then "Lair Champion: " .. name .. " wakes!"
				else "Champion: " .. name .. " appears!",
			"info"
		)
		sendMatch(c, true)
		return
	elseif e.type == "championEnrage" then
		sendMatch(c)
		return
	end
	-- v4 (QA-A M2): the top-damage squad gets the reward; a different squad that
	-- landed the kill snatches 50% of the cheese (MatchState.championKilled).
	local amount = if finite(e.cheese) and e.cheese > 0
		then RunState.applyPressureCheese(math.floor(e.cheese), c.match:pressurePoints())
		else 0
	local res = c.match:championKilled(e.damageBySquad, e.killerSquad, e.squad, amount)
	local s = res.winner
	if s then
		c.squadChampKills[s] = (c.squadChampKills[s] or 0) + 1 -- Champion Hunter
		if e.lair == true then
			-- (iteration 4: lairs no longer drop gems; gems come only on round completion)
			c.stageLairs = c.stageLairs or {}
			c.stageLairs[s] = (c.stageLairs[s] or 0) + 1
			for _, p in squadHumans(c, s) do
				local fl = K.flagsOf(c, p.UserId)
				fl.lairsInStage = math.max(fl.lairsInStage, c.stageLairs[s]) -- Lair Raider
			end
		end
	end
	-- v5: champion rinds split by damage (fallback) and whey 60 top / 30 others
	pcall(
		K.earnSplit,
		c,
		e.damageBySquad,
		RunWallet.rindsFor("champion", c.match.stage),
		RunWallet.Shop.WHEY.championTop,
		RunWallet.Shop.WHEY.championOther
	)
	-- iteration 1 (P-2): champion assists for class XP (every member of a squad that hit it)
	for sq, d in (if type(e.damageBySquad) == "table" then e.damageBySquad else {}) :: any do
		local sqn = tonumber(sq)
		if sqn and finite(d) and d > 0 then
			for _, id in c.match:activeMembers(sqn) do
				K.tally(c, id, "championAssists")
			end
		end
	end
	-- award stats: each member's part of the squad's damage share
	local total = 0
	for _, d in (if type(e.damageBySquad) == "table" then e.damageBySquad else {}) :: any do
		total += if finite(d) then d else 0
	end
	for sq, d in (if type(e.damageBySquad) == "table" then e.damageBySquad else {}) :: any do
		local sqn = tonumber(sq)
		local members = if sqn then c.match:activeMembers(sqn) else {}
		if total > 0 and finite(d) and #members > 0 then
			for _, id in members do
				K.tally(c, id, "championShare", d / total / #members)
			end
		end
	end
	-- championKilled already cut those squads' Herd Call timers by 3 s: refresh the HUDs
	for _, sq in { res.winner, res.snatch } do
		for _, id in (if sq then c.match:activeMembers(sq) else {}) do
			local m = c.match:member(id)
			if m and m.redeployAt then
				K.sendRedeploy(c, id)
			end
		end
	end
	for _, sq in { res.winner, res.snatch } do
		for _, p in (if sq then squadHumans(c, sq) else {}) do
			K.collect(c, p.UserId, "champions", e.champId)
			if e.lair == true then
				K.quest(c, p.UserId, "lair")
			end
		end
	end
	if s then
		local b = e.buff
		local stacks = 0
		if type(b) == "table" and type(b.stat) == "string" and finite(b.untilT) then
			c.buffs[s] = c.buffs[s] or {}
			stacks = K.Champions.addSquadBuff(c.buffs[s], b, simNow())
			refreshSquad(c, s)
		end
		if e.by ~= nil then
			c.match:notePoi(e.by)
		end
		toastSquad(
			c,
			s,
			string.format(
				"%s slain! Gear, +%d XP, +%d cheese each (25%% secured), %s x%d (%d s)",
				name,
				math.floor(e.xp or 0),
				res.cheese,
				if type(b) == "table" and type(b.name) == "string" then b.name else "a buff",
				math.max(1, stacks),
				math.floor(if type(b) == "table" and finite(b.duration) then b.duration else 0)
			),
			"good"
		)
		if res.snatch then
			toastSquad(
				c,
				res.snatch,
				string.format("SNATCH! You landed the blow on %s: +%d cheese each!", name, res.snatchCheese),
				"good"
			)
		end
		toastAll(c, squadName(s) .. " defeated " .. name .. "!", "info")
		killFeed(c, {
			killer = e.by,
			killerSquad = s,
			kind = "champion",
			champId = e.champId,
			lair = e.lair == true,
			snatchSquad = res.snatch,
		})
	end
	sendMatch(c, true)
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
		K.onPoiActivated(c, e)
		return
	elseif kind == "poiReward" then
		local ok, err = pcall(onPoiReward, c, e)
		if not ok then
			warn("[RunDirector] POI reward failed: " .. tostring(err))
		end
		return
	elseif kind == "poiProgress" then
		return
	elseif kind == "minibossDead" then
		local ok, err = pcall(K.onMinibossDead, c, e)
		if not ok then
			warn("[RunDirector] miniboss event failed: " .. tostring(err))
		end
		return
	elseif kind == "championSpawn" or kind == "championDead" or kind == "championEnrage" then
		local ok, err = pcall(K.onChampion, c, e)
		if not ok then
			warn("[RunDirector] champion event failed: " .. tostring(err))
		end
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
		K.tally(c, e.id, "gear")
		K.quest(c, e.id, "gear")
		K.collect(c, e.id, "gear", type(e.item) == "table" and e.item.id or nil)
		K.onGearPickup(c, e)
		return
	elseif kind == "rinds" then
		-- v5 (team M1): the World's rinds (shares, Greed and the Totem included)
		c.worldRinds = true
		K.earn(c, e.id, if finite(e.amount) then e.amount else 0)
		return
	elseif kind == "whey" then
		-- v5 (team M1): the 1-per-25-rinds trickle and champion whey
		K.earn(c, e.id, nil, if finite(e.amount) then e.amount else 0)
		return
	elseif kind == "kill" then
		K.tally(c, e.id, "mice") -- v4 awards (Mouse Masher)
		if c.waves and c.heroes[e.id] then
			K.Waves.noteKill(c.waves) -- iteration 2: the Early Horn counts stomps
		end
		if not c.worldRinds and c.heroes[e.id] then
			-- v5 fallback until the World sends `rinds` events
			local w = K.walletOf(c, e.id)
			K.earn(c, e.id, RunWallet.rindsFor("mouse", c.match.stage), nil, RunWallet.rindMult(w))
		end
		K.quest(c, e.id, if e.kind == "carrier" then "carrier" else "mice")
		if e.kind == "carrier" then
			K.quest(c, e.id, "mice")
		end
		K.collect(c, e.id, "mice", e.kind)
		return
	elseif kind == "stormDamage" then
		K.tally(c, e.id, "stormDamage", if finite(e.amount) then e.amount else 0)
		return
	elseif kind == "gearSwapOffer" then
		K.onGearSwapOffer(c, e)
		return
	elseif kind == "lootBag" then
		K.onLootBag(c, e) -- cheese only: the World hands the gear over (gearPickup follows)
		return
	elseif kind == "gearSwapDeclined" then
		local h = heroOf(c, e.id)
		if h and not h.isBot then
			h.swapOffer = nil
			syncGear(c, h)
			sendInventory(c, h)
		end
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
			setHumanoidSpeed(h.player, if h.stats then h.stats.moveSpeed * 0.3 else K.DEFAULT_WALKSPEED * 0.3)
			sendHud(c, h, true)
		end
		toastSquad(c, squad, heroName(h) .. " is down! Stand close to revive.", "bad")
		sendPartyHud(c, true)
	elseif kind == "revived" then
		if e.kind == "teammate" then
			-- v4 awards (Clutch Reviver): the nearest standing squadmate gets the credit
			local hx, hz = heroPos(c, h.id)
			local best, bestD = nil, math.huge
			for _, mid in c.match:activeMembers(squad) do
				local info = if mid ~= h.id and c.world then c.world:getPlayer(mid) else nil
				if info and not info.downed and not info.dead then
					local d = (info.x - hx) ^ 2 + (info.z - hz) ^ 2
					if d < bestD then
						best, bestD = mid, d
					end
				end
			end
			K.tally(c, best, "revives")
			K.quest(c, best, "revive")
		end
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
		if finite(e.amount) and e.amount > 0 then
			K.tally(c, h.id, "damageTaken", e.amount)
		end
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

K.allVoted = function(v: VoteState): boolean
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
local squadHpFrac: (c: Ctx, squad: number) -> number
local memberPot: (c: Ctx, squad: number) -> number

local function runRouteChoice(c: Ctx, winner: number?): number
	local cards = c.match:routeCards() or {}
	local default = MatchState.defaultRouteIndex(cards)
	if #cards == 0 then
		return 1
	end
	local botOnly = winner ~= nil and c.match:isSquadInRun(winner) and #squadHumans(c, winner) == 0
	if not winner or not c.match:isSquadInRun(winner) or botOnly then
		local deadline = setPhaseTimer(c, RunDirector.ROUTE_DEFAULT_SECONDS)
		broadcastRunState(c)
		waitFor(c, deadline, function()
			return gateOver(c)
		end)
		-- iteration 1 (C-1): the route gamble. Nobody won: a weighted random tier
		-- (Low 50 / Mid 35 / High 15); a bot-only winner: by stage, HP and pot.
		if botOnly then
			local pots, mine = 0, memberPot(c, winner :: number)
			for _, s2 in c.match:squadsInRun() do
				pots = math.max(pots, memberPot(c, s2))
			end
			return MatchState.botRouteIndex(
				cards,
				c.match.stage + 1, -- the stage the card is for
				c.voteRng,
				squadHpFrac(c, winner :: number),
				mine < pots
			)
		end
		return MatchState.randomRouteIndex(cards, c.voteRng)
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
		return gateOver(c) or K.allVoted(v)
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

K.onVote = function(player: Player, optionIndex: number)
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
if MatchState.FINAL_CHOICES and not table.find(CHOICES, "Overtime") then
	table.insert(CHOICES, "Overtime") -- iter 5 #6: only offered at the final gate
end
local STAY_INDEX = table.find(CHOICES, "Stay") :: number
local EXTRACT_INDEX = table.find(CHOICES, "Extract") :: number
-- iter 5 #6: the options a member sees at this gate
K.gateOptions = function(c: Ctx, pr: PlayerRun): { string }
	if type(c.match.isFinalGate) == "function" and c.match:isFinalGate() then
		return table.clone(MatchState.FINAL_CHOICES)
	end
	return if pr.hideDoN then { "Extract", "Stay" } else table.clone(MatchState.CHOICES)
end

-- Average HP fraction of a squad's living members in the World (1 without a
-- World). Dead members are left out: they respawn at full HP next stage.
squadHpFrac = function(c: Ctx, squad: number): number
	local world = c.world
	local sum, n = 0, 0
	for _, id in c.match:activeMembers(squad) do
		local info = if world then world:getPlayer(id) else nil
		if info and not info.dead and finite(info.hp) and finite(info.maxHp) and info.maxHp > 0 then
			sum += math.clamp(info.hp / info.maxHp, 0, 1)
			n += 1
		end
	end
	return if n > 0 then sum / n else 1
end

-- A squad's pot per member (BotBrain's EXTRACT_POT is a per-hero amount; the
-- squad total of 3 shares would pass it after stage 1 every time).
memberPot = function(c: Ctx, squad: number): number
	local n = #c.match:activeMembers(squad)
	return if n > 0 then math.floor(c.match:squadPending(squad) / n) else 0
end

K.extractCounts = function(x: ExtractState, squad: number): { [string]: number }
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
				-- v4 Rookie Run: no Double or Nothing before run 3
				options = K.gateOptions(c, pr), -- iter 5 #6: {"Extract", "Overtime"} at the final gate
				hideDoubleOrNothing = pr.hideDoN == true or nil,
				preselected = if x.prefilled and x.prefilled[pr.userId] then "Extract" else nil,
				votes = K.extractCounts(x, pr.squad),
				yourChoice = if mine then CHOICES[mine] else nil,
				squad = pr.squad,
				share = c.match:shareOf(pr.userId),
				-- what Extract banks for THIS member: own share x extractMult (Portal Charm)
				bank = math.floor(
					c.match:shareOf(pr.userId) * ((c.match:member(pr.userId) or {}).extractMult or 1)
				),
				pending = c.match:squadPending(pr.squad),
				stage = c.match.stage,
				stages = MatchState.CONFIG.STAGES,
				extractedCount = c.match:extractedCount(),
				brave = c.match:extractedCount() >= MatchState.CONFIG.BRAVE_EXTRACTED,
				final = c.match:isFinalGate() or nil, -- iter 5 #6
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
		local ok, r = pcall(BotBrain.chooseVote, "extract", CHOICES, tally, c.botRng, {
			pot = memberPot(c, b.squad),
			hpFrac = squadHpFrac(c, b.squad),
		})
		idx = if ok and Guard.isInt(r, 1, #CHOICES) then r else nil
	end
	if idx and vote:cast(b.id, idx) then
		x.botVoted[b.id] = true
		return true
	end
	return false
end

K.allExtractVoted = function(c: Ctx, x: ExtractState): boolean
	for _, p in memberList(c) do
		local pr = c.members[p]
		local votes = x.humanVotes[pr.squad]
		if not votes or votes[pr.userId] == nil or (x.prefilled and x.prefilled[pr.userId]) then
			return false
		end
	end
	return true
end

-- Every squad in the run chooses Extract / Stay / Double or Nothing (majority;
-- DoN needs a human vote: Vote.riskyIndices). Returns MatchState's result.
local function runExtraction(c: Ctx): any
	local live = c.match:squadsInRun()
	local final = c.match:isFinalGate() -- iter 5 #6: Extract / Overtime
	c.voteToken += 1
	local x: ExtractState =
		{ votes = {}, humanVotes = {}, botVoted = {}, botChoice = {}, token = c.voteToken }
	for _, s in live do
		x.votes[s] = Vote.new(#CHOICES, c.match:activeMembers(s))
		x.humanVotes[s] = {}
		if #squadHumans(c, s) == 0 then
			-- v4: never before the stage-2 gate, then at 330 / 420 per member
			-- a Rival Herd never extracts: it is there to fight the lone squad
			local sq = c.match:squad(s)
			x.botChoice[s] = if final
				then "Extract" -- bot-only squads never play Overtime
				elseif sq and sq.rival then "Stay"
				else MatchState.botExtractRule(c.match.stage, memberPot(c, s), s)
		end
	end
	c.extract = x
	-- v4 Rookie Run: run 1's first gate has Extract pre-selected (one tap to confirm)
	x.prefilled = {}
	if c.match.stage == 1 then
		local extractIdx = table.find(CHOICES, "Extract") :: number
		for _, s in live do
			for _, p in squadHumans(c, s) do
				local pr = c.members[p]
				if pr.rookieRuns == 0 and x.votes[s]:cast(pr.userId, extractIdx) then
					x.humanVotes[s][pr.userId] = extractIdx
					x.prefilled[pr.userId] = true
				end
			end
		end
	end
	-- QC-B V2-m4: neutral gold for the whole window (each client tints its own view)
	if c.portal then
		setPortal(c, "open", RunDirector.PORTAL_GOLD)
	end
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
		return gateOver(c) or K.allExtractVoted(c, x)
	end)
	-- Bots that have not voted yet vote now (bot-only squads, late humans' mates).
	for _, b in botsInRun(c) do
		if not x.botVoted[b.id] then
			botExtractVote(c, x, b)
		end
	end
	local choices: { [number]: string } = {}
	local risky = Vote.riskyIndices(CHOICES)
	local otIdx = table.find(CHOICES, "Overtime")
	if otIdx and not table.find(risky, otIdx) then
		table.insert(risky, otIdx) -- iter 5 #6: Overtime needs a human vote
	end
	local defaultIdx = if final then EXTRACT_INDEX else STAY_INDEX
	for _, s in live do
		local vote = x.votes[s]
		local idx = defaultIdx
		if vote and c.match:isSquadInRun(s) then
			local ok, r = pcall(vote.resolve, vote, c.voteRng, defaultIdx, risky)
			if ok and Guard.isInt(r, 1, #CHOICES) then
				idx = r
			end
		end
		local choice = CHOICES[idx]
		if final and choice ~= "Overtime" then
			choice = "Extract"
		elseif not final and choice == "Overtime" then
			choice = "Stay"
		end
		choices[s] = choice
	end
	c.extract = nil
	c.voteToken += 1
	-- iteration 2 (Clean Exit): extracting squads with every member standing
	for sq, choice in choices do
		if choice == "Extract" then
			local all = true
			for _, id in c.match:activeMembers(sq) do
				all = all and not isDowned(c, id)
			end
			c.squadStandingAtExtract[sq] = all
		end
	end
	-- A squad with nobody standing at the gate is eliminated, not extracted.
	eliminateFallen(c)
	if c.match.phase ~= "Extraction" then
		-- The wipe ended the match: nothing left to resolve (eliminate paid everyone).
		return {
			extracted = {},
			stayed = {},
			doubleOrNothing = {},
			out = {},
			finished = true,
			endReason = c.match.endReason,
		}
	end
	updateExtractMults(c)
	local res = c.match:resolveExtraction(choices)
	for _, s in res.extracted do
		killFeed(c, { killerSquad = s, kind = "extracted" })
		toastAll(c, squadName(s) .. " extracted through the Rind Gate!", "info")
	end
	for _, s in res.overtime or {} do
		toastAll(c, squadName(s) .. " chose OVERTIME! Endless waves, growing stronger.", "bad")
	end
	for _, s in res.doubleOrNothing do
		toastSquad(
			c,
			s,
			"DOUBLE OR NOTHING! Survive AND kill a champion or the boss next stage: x2. Otherwise the pot is lost. Everyone can see you!",
			"bad"
		)
		toastAll(c, squadName(s) .. " went Double or Nothing!", "info")
	end
	handleOut(c, res.out, true)
	K.markDoN(c)
	return res
end

K.onExtractVote = function(player: Player, choice: string)
	local c = ctx
	local pr = c and c.members[player]
	if c and pr and not pr.out and phaseOf(c) == "Overtime" then
		if choice == "Extract" then
			K.voteOvertimeExtract(c, pr) -- iter 5 #6: majority of the standing humans
		end
		return
	end
	local x = c and c.extract
	if not c or not pr or pr.out or not x or phaseOf(c) ~= "Extraction" then
		return
	end
	-- iter 5 #6: Overtime only at the final gate, and only Extract / Overtime there
	if not table.find(K.gateOptions(c, pr), choice) then
		if choice == "DoubleOrNothing" and pr.hideDoN then
			Remotes.toast(player, "Double or Nothing unlocks after your first 3 runs!", "bad")
		end
		return
	end
	local idx = table.find(CHOICES, choice)
	local vote = x.votes[pr.squad]
	if not idx or not vote then
		Guard.reject(player, "ExtractVote", "no matching extraction window", false)
		return
	end
	if choice == "DoubleOrNothing" and pr.hideDoN then
		Remotes.toast(player, "Double or Nothing unlocks after your first 3 runs!", "bad")
		return
	end
	if x.prefilled then
		x.prefilled[pr.userId] = nil
	end
	if vote:cast(pr.userId, idx) then
		x.humanVotes[pr.squad][pr.userId] = idx
		for _, b in squadBots(c, pr.squad) do
			if x.botVoted[b.id] or not x.botChoice[b.squad] then
				botExtractVote(c, x, b) -- bots follow their humans
			end
		end
		sendExtract(c, pr.squad)
		-- QC-B V2-m4: the shared gate stays neutral gold for everyone; each
		-- client tints it locally from its OWN squad's votes (FxController)
	end
end

-- Gear / Shop Cart remotes ---------------------------------------------------------------------

K.onSwapGear = function(player: Player, keep: boolean)
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

-- Buys cart offer `index` for hero `h` with pending cheese (never Robux):
-- check the share, take the item from the World's stock, charge, then giveGear
-- (an item is never lost: a full slot gets a swap offer or the item drops at the
-- hero's feet). Returns ok, reason.
buyCart = function(c: Ctx, h: any, poi: any, index: number): (boolean, string?)
	local cart = c.carts[poi]
	if not cart or not c.match:isInRun(h.id) then
		return false, "no_cart"
	end
	-- QC-B V2-m3: only in the waves, standing at the cart; paid from the
	-- buyer's own share (Run/CartRules)
	local world = c.world
	local pos = if world then world:getPlayer(h.id) else nil
	local okRule, why, rulePrice =
		K.CartRules.check(cart, h.squad, phaseOf(c), pos, c.match:shareOf(h.id), index)
	if not okRule then
		return false, why
	end
	local item, price = cart.offers[index], rulePrice :: number
	if world and type(world.takeCartOffer) == "function" then
		local ok, got, p2 = pcall(world.takeCartOffer, world, poi, index)
		if not ok or type(got) ~= "table" then
			cart.bought[index] = true -- the World says it is gone
			return false, "sold"
		end
		item = got
		if finite(p2) and p2 > 0 and p2 <= c.match:shareOf(h.id) then
			price = math.floor(p2)
		end
	end
	if not c.match:spendShare(h.id, price) then
		return false, "funds"
	end
	cart.bought[index] = true
	local ok, swap = giveGear(c, h, item)
	if not ok and not swap and not (world and type(world.takeCartOffer) == "function") then
		-- v1-style World that can't hold gear: give the cheese back
		c.match:refundShare(h.id, price)
		cart.bought[index] = nil
		return false, "refused"
	end
	refreshHero(c, h)
	if not h.isBot then
		Remotes.toast(h.player, string.format("Bought %s for %d cheese", itemName(item), price), "good")
		sendCart(c, h, poi)
	end
	-- squad-mates with this cart open see the item sold right away
	for _, p in memberList(c) do
		local pr = c.members[p]
		if pr ~= h and pr.squad == cart.squad and pr.cartPoi == poi then
			sendCart(c, pr, poi, true)
		end
	end
	sendMatch(c)
	return true, nil
end

K.onBuyCartItem = function(player: Player, poiId: number, index: number)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or pr.out or not LIVE_PHASES[phaseOf(c)] then
		return
	end
	local ok, why = buyCart(c, pr, poiId, index)
	if ok then
		return
	end
	if why == "funds" then
		Remotes.toast(player, "Not enough cheese in your own pending share for that.", "bad")
		sendCart(c, pr, poiId)
	elseif why == "far" then
		Remotes.toast(player, "Walk back to the Shop Cart to buy.", "bad")
	elseif why == "phase" then
		Remotes.toast(player, "The Shop Cart closes when the waves end.", "bad")
	elseif why == "sold" then
		Remotes.toast(player, "That item is sold out.", "bad")
		sendCart(c, pr, poiId)
	elseif why == "refused" then
		Remotes.toast(player, "The cart can't hand that over right now.", "bad")
	else
		Guard.reject(player, "BuyCartItem", "no such cart for this squad", false)
	end
end

-- Upgrade / ability / Second Wind remotes ---------------------------------------------------------

K.onChooseUpgrade = function(player: Player, offerId: number, cardIndex: number)
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

K.onRerollUpgrade = function(player: Player, offerId: number)
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

-- Iteration 4: the auto-attack aim toggle. A saved setting (profile.settings.aimMode,
-- "nearest" by default or "cursor"); in cursor mode the client streams AimAt(x, z)
-- (<= 15/s, Guard-checked) and World.setAim clamps the point into the arena.
K.AIM_MODES = { "nearest", "cursor" }
K.aimModes = {} :: { [Player]: string } -- this session's choice (before the profile loads)

K.aimModeOf = function(player: Player?): string
	if not player then
		return "nearest"
	end
	local m = K.aimModes[player]
	if m then
		return m
	end
	local profile = getProfile(player)
	local st = if type(profile) == "table" then profile.settings else nil
	return if type(st) == "table" and st.aimMode == "cursor" then "cursor" else "nearest"
end

K.onSetAimMode = function(player: Player, mode: string)
	if mode ~= "cursor" and mode ~= "nearest" then
		return
	end
	if K.aimModeOf(player) ~= mode then
		profileUpdate(player, function(profile: any)
			if type(profile.settings) == "table" then
				profile.settings.aimMode = mode
			end
		end)
	end
	K.aimModes[player] = mode
	local c = ctx
	local pr = c and c.members[player]
	local world = c and c.world :: any
	if pr and not pr.out and world and type(world.setAim) == "function" then
		pcall(world.setAim, world, pr.userId, mode)
	end
end

K.onAimAt = function(player: Player, x: number, z: number)
	local c = ctx
	local pr = c and c.members[player]
	local world = c and c.world :: any
	if not c or not pr or pr.out or not world or type(world.setAim) ~= "function" then
		return
	end
	if K.aimModeOf(player) ~= "cursor" or not LIVE_PHASES[phaseOf(c)] then
		return
	end
	pcall(world.setAim, world, pr.userId, "cursor", x, z)
end

-- iteration 5 (A3): per-slot rate limit (on top of the remote's own bucket)
RunDirector.ABILITY_SLOT_RATE = 4
RunDirector.ABILITY_SLOT_BURST = 4

K.onUseAbility = function(player: Player, aimX: number, aimZ: number, slot: number?)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or pr.out or not c.world or not LIVE_PHASES[phaseOf(c)] then
		return
	end
	local k = if slot == nil then 1 else slot
	if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > 4 then -- iteration 6: slot 4
		return
	end
	-- a slot this hero hasn't unlocked is refused by the World (no def in that slot)
	if
		not Guard.allow(
			player,
			"UseAbility#" .. k,
			RunDirector.ABILITY_SLOT_RATE,
			RunDirector.ABILITY_SLOT_BURST
		)
	then
		return
	end
	if c.world:useAbility(pr.userId, aimX, aimZ, simNow(), k) then
		K.quest(c, pr.userId, "ability")
		sendHud(c, pr, true)
	end
end

local function probeSecondWind(c: Ctx, pr: PlayerRun): (boolean, string, { [string]: any })
	local reviveCtx: { [string]: any } = {
		doubleOrNothing = c.match:squadDoubleOrNothing(pr.squad),
		-- QC-B V2-M1: no token revives while 2+ squads are still in the run
		squadsInRun = #c.match:squadsInRun(),
	}
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

K.onUseSecondWind = function(player: Player)
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
				elseif
					how == "blocked_pvp"
				then "Second Wind tokens only work once your squad is the last one left."
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

-- Rough end of the match (server time) for the lobby: what is left of this
-- phase and stage, plus the remaining stages at a typical length (the boss at
-- half its time limit). Returns {endsAt, stage, stages}.
function RunDirector.estimateEnd(c: Ctx): { [string]: number }
	local now = serverNow()
	local stages = MatchState.CONFIG.STAGES
	local stage = c.match.stage or 1
	local R = RunDirector
	local gate = R.VOTE_SECONDS + R.EXTRACT_SECONDS + R.STAGE_CLEAR_SECONDS
	local after = ({
		Waves = R.BOSS_SECONDS / 2 + gate,
		Boss = gate,
		StageClear = R.VOTE_SECONDS + R.EXTRACT_SECONDS,
		RouteChoice = R.EXTRACT_SECONDS,
	} :: { [string]: number })[phaseOf(c)] or 0
	local full = K.waveSecondsOf(c) + R.BOSS_SECONDS / 2 + gate
	local left = math.max(0, (c.phaseEndsAt or now) - now)
	local endsAt = now + left + after + math.max(0, stages - stage) * full + R.RESULTS_SECONDS
	return { endsAt = math.floor(endsAt), stage = stage, stages = stages }
end

-- v4 Match flow (team M2) ------------------------------------------------------------------------
-- Everything below hangs off K (RunDirector is close to Luau's 200-local limit).

-- Per-hero award stats (MatchState.awards).
K.tallyOf = function(c: Ctx, id: number): { [string]: number }
	local t = c.tally[id]
	if not t then
		t = {
			mice = 0,
			championShare = 0,
			revives = 0,
			gear = 0,
			vaults = 0,
			totems = 0,
			bossDamagePct = 0,
			escape = 0,
			banked = 0,
			bounties = 0,
			stormDamage = 0,
			damageTaken = 0,
		}
		c.tally[id] = t
	end
	return t
end

K.tally = function(c: Ctx, id: any, key: string, n: number?)
	if type(id) ~= "number" or c.heroes[id] == nil then
		return
	end
	local t = K.tallyOf(c, id)
	t[key] = (t[key] or 0) + (if finite(n) then n :: number else 1)
end

-- QC minor 3: a hero who played ENGAGE_SECONDS of waves and dealt damage counts
-- as having played (payout floor, run credit for a leaver).
K.ENGAGE_SECONDS = 60
K.noteEngaged = function(c: Ctx, pr: PlayerRun, dt: number)
	if phaseOf(c) == "Boss" and not pr.out then
		pr.playSeconds = (pr.playSeconds or 0) + dt -- iteration 1: class XP per minute
	end
	if phaseOf(c) ~= "Waves" or pr.out then
		return
	end
	pr.playSeconds = (pr.playSeconds or 0) + dt
	pr.waveSeconds = (pr.waveSeconds or 0) + dt
	local m = c.match:member(pr.userId)
	-- (40% of one wave when waves are shorter, e.g. the emulator's 20 s waves)
	local need = math.min(K.ENGAGE_SECONDS, RunDirector.WAVE_SECONDS * 0.4)
	if not m or m.engaged or (pr.waveSeconds :: number) < need then
		return
	end
	local t = K.tallyOf(c, pr.userId)
	if t.mice > 0 or t.bossDamagePct > 0 or t.championShare > 0 or m.downs > 0 then
		c.match:markEngaged(pr.userId)
	end
end

-- Sorted keys of a set (awardRun's bossIds / championIds / mapIds).
K.keys = function(set: any): { string }
	local out = {}
	if type(set) == "table" then
		for k in set do
			table.insert(out, tostring(k))
		end
		table.sort(out)
	end
	return out
end

-- Live Herd Contract progress (team P: DataService.questEvent, live kinds only).
-- Counts are buffered per human and flushed by the HUD loop (K.flushQuests).
K.quest = function(c: Ctx, id: any, kind: string, n: number?)
	local pr = memberById(c, id)
	if pr and pr.questBuf then
		pr.questBuf[kind] = (pr.questBuf[kind] or 0) + (n or 1)
	end
end

K.questSquad = function(c: Ctx, squad: any, kind: string)
	if type(squad) == "number" then
		for _, p in squadHumans(c, squad) do
			K.quest(c, p.UserId, kind)
		end
	end
end

K.flushQuests = function(_c: Ctx, pr: PlayerRun)
	local buf = pr.questBuf
	if not buf or next(buf) == nil or not DataService or type(DataService.questEvent) ~= "function" then
		return
	end
	pr.questBuf = {}
	for kind, n in buf do
		local ok, err = pcall(DataService.questEvent, pr.player, kind, n)
		if not ok then
			warn("[RunDirector] questEvent failed: " .. tostring(err))
		end
	end
end

-- Mousepedia (team P: DataService.collect), once per id per run; also fills the
-- run's sets that awardRun gets (bossIds / championIds / mapIds).
K.collect = function(c: Ctx, id: any, page: string, entry: any)
	local pr = memberById(c, id)
	if not pr or not pr.seen or entry == nil then
		return
	end
	local key = (
		{ bosses = "bosses", champions = "champions", maps = "maps", mice = "mice", gear = "gear" } :: any
	)[page]
	local set = key and pr.seen[key]
	local e = tostring(entry)
	if not set or set[e] then
		return
	end
	set[e] = true
	if DataService and type(DataService.collect) == "function" then
		task.spawn(function()
			local ok, err = pcall(DataService.collect, pr.player, page, e)
			if not ok then
				warn("[RunDirector] collect failed: " .. tostring(err))
			end
		end)
	end
end

-- The arena radius of this stage (Maps.stageRadius, team M1), else the map size.
K.stageRadius = function(mapId: string, stage: number): number
	if type(Maps.stageRadius) == "function" then
		local ok, r = pcall(Maps.stageRadius, mapId, stage)
		if ok and finite(r) and r > 0 then
			return r
		end
	end
	return Pois.arenaRadius(mapId)
end

K.worldNow = function(c: Ctx): number
	local w = c.world :: any
	-- v4.1 hotfix: a fresh World has now = 0 until it steps; the storm schedule must not
	-- be anchored to that (it put every hero outside the Melt from second 0).
	return if w and finite(w.now) and w.now > 0 then w.now else simNow()
end

-- The Melt --------------------------------------------------------------------------------------

K.sendStorm = function(c: Ctx, target: any?)
	local st = c.storm
	local z = st and st.zone
	if not z then
		return
	end
	local payload = {
		cx = z.cx,
		cz = z.cz,
		r = z.r,
		toR = z.toR,
		closeStart = z.closeStart,
		closeEnd = z.closeEnd,
		dps = z.dps,
		now = K.worldNow(c), -- the world clock the close times use
		serverNow = serverNow(),
		stage = c.match.stage,
		step = z.step,
	}
	local list = if target then { target } else memberList(c)
	Remotes.fireList(list, Net.S2C.Storm, payload)
end

K.setZone = function(c: Ctx, zone: any)
	local world = c.world
	local st = c.storm
	if not world or not st then
		return
	end
	st.zone = zone
	if type(world.setZone) == "function" then
		local ok, err = pcall(world.setZone, world, zone)
		if not ok then
			warn("[RunDirector] setZone failed: " .. tostring(err))
		end
	end
	K.sendStorm(c)
end

-- A new stage: the storm plan (no zone yet; the waves set the first circle).
K.stormStart = function(c: Ctx, R: number)
	c.storm = { R = R, stage = c.match.stage, seed = c.match:stageSeed(), step = nil, safeOff = false }
end

-- Every tick of the waves / the boss (10 Hz): steps the circle when the schedule moves.
K.stormTick = function(c: Ctx)
	local st, world, Storm = c.storm, c.world, K.Storm
	if not st or not world or not Storm then
		return
	end
	local now = K.worldNow(c)
	local phase = phaseOf(c)
	local zone, t0 = nil, nil
	if phase == "Waves" then
		local wt = 0
		local dur = K.waveSecondsOf(c)
		if c.waves and type(Storm.zoneForWave) == "function" then
			-- iteration 2 (team M1): the Melt steps with the wave index (a horn shrinks
			-- it sooner); close times are relative to the wave's start
			local z = Storm.zoneForWave(st.R, st.stage, c.waves.wave, st.seed, c.waves.waveSeconds)
			if z.step ~= st.step then
				st.step = z.step
				K.setZone(c, Storm.toWorld(z, c.waveWorldT0 or now))
			end
			wt = K.Waves.waveTime(c.waves, os.clock())
			dur = K.Waves.hordeSeconds(c.waves)
			if not st.safeOff and not Storm.safeCornersOn(wt, dur) then
				st.safeOff = true
				if type(world.setSafeZones) == "function" then
					pcall(world.setSafeZones, world, {})
				end
			end
			return
		elseif c.waves then
			wt = K.Waves.waveTime(c.waves, os.clock())
			dur = K.Waves.hordeSeconds(c.waves)
		elseif type(world.stageClock) == "function" then
			local ok, _, e = pcall(world.stageClock, world)
			wt = if ok and finite(e) then e else 0
		end
		zone = Storm.zoneAt(st.R, st.stage, wt, st.seed, dur)
		t0 = now - wt
		if not st.safeOff and not Storm.safeCornersOn(wt, dur) then
			st.safeOff = true
			if type(world.setSafeZones) == "function" then
				pcall(world.setSafeZones, world, {})
			end
			toastAll(c, "The Melt is coming: the safe corners are gone!", "bad")
		end
	elseif phase == "Boss" and st.bossT0 then
		-- iteration 4 (bigger maps): the squeeze starts early enough to finish before
		-- the boss flees, and every step starts from the circle's CURRENT radius
		local sq = Storm.BOSS_SQUEEZE
		-- iteration 6 (team Flow): Fast pace squeezes sooner and faster (x0.8)
		local pk = K.Pace.get(c.pace).storm
		local sqAfter, sqOver = sq.after * pk, sq.over * pk
		local at = math.min(sqAfter, math.max(0, RunDirector.BOSS_SECONDS - sqOver - K.BOSS_SQUEEZE_MARGIN))
		local bt = now - st.bossT0
		zone = Storm.bossZone(st.R, st.stage, if bt >= at then math.max(bt / pk, sq.after) else 0, st.seed)
		t0 = st.bossT0
		if zone.step ~= st.step then
			local cur = if st.zone and type(Storm.radiusAt) == "function"
				then Storm.radiusAt(st.zone, now)
				elseif st.zone then st.zone.toR
				else zone.r
			if zone.step == 101 then
				zone.r = math.max(cur, zone.toR)
				zone.closeStart, zone.closeEnd = at, at + sqOver
			elseif cur > zone.r then
				-- the waves left a wider circle (big maps, an early horn): close to the ring
				zone.toR = zone.r
				zone.r = cur
				zone.closeStart, zone.closeEnd = bt, bt + K.BOSS_RING_CLOSE
			else
				zone.r, zone.toR = cur, cur
			end
		end
	else
		return
	end
	if zone.step == st.step then
		return
	end
	st.step = zone.step
	local wz = Storm.toWorld(zone, t0)
	if zone.step == 101 then
		toastAll(c, "The Melt squeezes the boss ring! Finish it fast!", "bad")
	elseif zone.step ~= 100 and wz.toR < wz.r and wz.closeStart > now then
		toastAll(c, "The Melt closes in! Move inside the circle.", "info")
	end
	K.setZone(c, wz)
end

K.BOSS_SQUEEZE_MARGIN = 10 -- s: the squeeze is closed this long before the boss flees

-- Iteration 6 (team Flow): the horde length at the run's pace (Fast x0.7).
K.waveSecondsOf = function(c: Ctx?): number
	return K.Pace.waveSeconds(RunDirector.WAVE_SECONDS, if c then c.pace else nil)
end
-- the Early Horn budget's per-hero rate follows the pace's spawn rate (nil = default)
K.paceHornRate = function(c: Ctx): number?
	local k = K.Pace.get(c.pace).spawn
	return if k ~= 1 then K.Waves.PER_HERO_RATE * k else nil
end
K.BOSS_RING_CLOSE = 20 -- s: a wider circle closes to the boss ring this fast

K.stormBoss = function(c: Ctx)
	if c.storm then
		c.storm.bossT0 = K.worldNow(c)
		K.stormTick(c)
	end
end

-- Double or Nothing marks: Player / bot model attribute + Match.donMarkers.
K.markDoN = function(c: Ctx)
	for id, h in c.heroes do
		local on = c.match:isInRun(id) and c.match:squadDoubleOrNothing(h.squad) or nil
		if h.isBot then
			if BotService and type(BotService.getModel) == "function" then
				local ok, model = pcall(BotService.getModel, id)
				if ok and model then
					pcall(model.SetAttribute, model, "DoubleOrNothing", on)
				end
			end
		elseif h.player then
			pcall(h.player.SetAttribute, h.player, "DoubleOrNothing", on)
		end
	end
end

K.donMarkers = function(c: Ctx): { any }
	local out = {}
	local world = c.world
	if not world then
		return out
	end
	for _, s in c.match:squadsInRun() do
		if c.match:squadDoubleOrNothing(s) then
			local sx, sz, n = 0, 0, 0
			for _, id in c.match:activeMembers(s) do
				local info = world:getPlayer(id)
				if info and not info.dead and finite(info.x) then
					sx += info.x
					sz += info.z
					n += 1
				end
			end
			if n > 0 then
				table.insert(out, {
					squad = s,
					x = math.floor(sx / n / K.CHAMP_GRID + 0.5) * K.CHAMP_GRID,
					z = math.floor(sz / n / K.CHAMP_GRID + 0.5) * K.CHAMP_GRID,
				})
			end
		end
	end
	return out
end

-- Herd Call --------------------------------------------------------------------------------------

K.sendRedeploy = function(c: Ctx, id: number)
	local pr = memberById(c, id)
	if not pr or pr.out then
		return
	end
	local m = c.match:member(id)
	local spec, specName = nil, nil
	local info = c.world and c.world:getPlayer(id)
	if info and info.dead then
		spec, specName = K.spectateOf(c, id)
	end
	pr.spectating = spec
	Remotes.fireTo(pr.player, Net.S2C.Redeploy, {
		untilT = if m then m.redeployAt else nil,
		-- iteration 1 (P-14): whom to spectate while dead (nil: alive, or nobody standing)
		spectate = spec,
		spectateName = specName,
	})
end

K.sendRedeploys = function(c: Ctx, ids: { number })
	for _, id in ids do
		K.sendRedeploy(c, id)
	end
end

K.standingMate = function(c: Ctx, id: number): (number?, number, number)
	local world = c.world
	local squad = c.match:squadOf(id)
	if not world or not squad then
		return nil, 0, 0
	end
	local best, bestHp, bx, bz = nil, -1, 0, 0
	for _, mid in c.match:activeMembers(squad) do
		if mid ~= id then
			local info = world:getPlayer(mid)
			if info and not info.downed and not info.dead and finite(info.hp) and info.hp > bestHp then
				best, bestHp, bx, bz = mid, info.hp, info.x, info.z
			end
		end
	end
	return best, bx, bz
end

-- A hero died (heroKilled): start their Herd Call timer.
K.onDeath = function(c: Ctx, id: number)
	local mate = K.standingMate(c, id)
	local untilT = c.match:startRedeploy(id, serverNow(), mate ~= nil, c.waveEndsAt)
	local ex = K.extras(c.heroes[id])
	local m = c.match:member(id)
	if untilT and m and m.redeployAt and ex and finite(ex.redeployCut) and ex.redeployCut > 0 then
		m.redeployAt -= ex.redeployCut -- iteration 1 (team P): a talent / evolution cut
		untilT = m.redeployAt
	end
	if untilT then
		K.sendRedeploy(c, id)
		local h = c.heroes[id]
		if h and not h.isBot then
			Remotes.toast(
				h.player,
				string.format(
					"Herd Call in %d s! Your squad cuts the timer by fighting.",
					math.ceil(untilT - serverNow())
				),
				"info"
			)
		end
	end
end

K.cutSquad = function(c: Ctx, squad: any, seconds: number)
	K.sendRedeploys(c, c.match:cutRedeploy(squad, seconds))
end

-- Puts a hero back in the World next to a standing squadmate (world:redeploy, M1).
K.placeRedeploy = function(c: Ctx, id: number, x: number, z: number): boolean
	local world = c.world :: any
	if not world then
		return false
	end
	local C = MatchState.CONFIG
	local angle = (id % 6) * math.pi / 3
	local px, pz = x + math.cos(angle) * 3, z + math.sin(angle) * 3
	if type(world.redeploy) == "function" then
		local ok, done = pcall(world.redeploy, world, id, px, pz, C.REDEPLOY_HP, C.REDEPLOY_PROTECT)
		return ok and done == true
	end
	-- fallback for a World without redeploy: revive in place, then move
	local p = type(world.players) == "table" and world.players[id]
	if not p or type(world._revive) ~= "function" then
		return false
	end
	local ok = pcall(function()
		world:teleportPlayer(p, px, pz)
		world:_revive(p, C.REDEPLOY_HP, "redeploy")
		world:protect(id, C.REDEPLOY_PROTECT)
	end)
	return ok
end

-- 10 Hz during the waves: due timers return (a bot's seat may go to a late joiner).
K.redeployTick = function(c: Ctx)
	if phaseOf(c) ~= "Waves" then
		return
	end
	for _, id in c.match:dueRedeploys(serverNow(), c.waveEndsAt) do
		local mate, mx, mz = K.standingMate(c, id)
		if mate then
			local h = c.heroes[id]
			if h and h.isBot and #c.joinQueue > 0 and K.seatJoinerNow(c, id, mx, mz) then
				continue
			end
			if K.placeRedeploy(c, id, mx, mz) then
				c.match:completeRedeploy(id)
				K.sendRedeploy(c, id)
				if h then
					if not h.isBot then
						teleportToArena(c, h)
						if h.stats then
							setHumanoidSpeed(h.player, h.stats.moveSpeed)
						end
						sendHud(c, h, true)
					end
					toastSquad(c, h.squad, heroName(h) .. " answers the Herd Call!", "good")
				end
				sendPartyHud(c, true)
			end
		end
	end
end

-- The waves are over (boss, gate): pending timers wait for the next stage.
K.redeployClose = function(c: Ctx)
	K.sendRedeploys(c, c.match:cancelRedeploys())
end

-- Rival Herd -------------------------------------------------------------------------------------

K.newBotId = function(c: Ctx): number
	repeat
		c.nextBotN += 1
	until c.heroes[Ids.botId(c.nextBotN)] == nil and c.match:member(Ids.botId(c.nextBotN)) == nil
	return Ids.botId(c.nextBotN)
end

K.avgHeroLevel = function(c: Ctx): number
	local sum, n = 0, 0
	for id, h in c.heroes do
		if c.match:isInRun(id) then
			sum += h.level
			n += 1
		end
	end
	return if n > 0 then math.max(1, math.floor(sum / n + 0.5)) else 1
end

-- At a stage start with <= 1 squad left: a labelled 🤖 bot squad joins.
K.addRival = function(c: Ctx)
	local specs = {}
	if type(BotRoster.rivalSquad) == "function" then
		local taken = {}
		for id in c.heroes do
			table.insert(taken, id)
		end
		local ok, list = pcall(BotRoster.rivalSquad, c.botRng, taken)
		if ok and type(list) == "table" then
			specs = list
		end
	end
	if #specs == 0 then
		for i = 1, Squads.SIZE do
			specs[i] = { id = K.newBotId(c), classId = "elephante", name = "Rival " .. i .. " 🤖" }
		end
	end
	local parts = {}
	for _, sp in specs do
		table.insert(parts, { id = sp.id, classId = sp.classId })
	end
	local slot = c.match:addRivalSquad(parts, "Rival Herd 🤖")
	if not slot then
		return
	end
	local level = K.avgHeroLevel(c)
	for i, sp in specs do
		local classState = nil
		if ClassProgress and type(ClassProgress.autoSpec) == "function" then
			local ok, st = pcall(ClassProgress.autoSpec, sp.classId, level, (i % 3) + 1)
			classState = if ok then st else nil
		end
		local b: BotRun = {
			id = sp.id,
			isBot = true,
			name = if type(sp.name) == "string" then sp.name else "Rival 🤖",
			squad = slot,
			classId = sp.classId,
			classState = classState,
			skin = nil,
			level = 1,
			xp = 0,
			stacks = {},
			stats = nil,
			weapon = nil,
			ability = nil,
			gear = {},
			offerRng = c.rng:fork(400 + c.nextBotN + i),
		}
		table.insert(c.bots, b)
		c.heroes[b.id] = b
		computeStats(c, b)
		-- catch up with the match: the same level as the heroes in it, upgrades included
		local gained = math.min(level - 1, 30)
		b.level = 1 + gained
		for _ = 1, Leveling.milestones(1, b.level) do -- iteration 4: milestone picks only
			pcall(botLevelUp, c, b)
		end
		K.levelGains(c, b)
	end
	killFeed(c, { killerSquad = slot, kind = "rival" })
	toastAll(c, "A 🤖 Rival Herd charges into the Melt!", "bad")
end

-- Late joiners -----------------------------------------------------------------------------------

-- Bots that could give their seat: squads with humans first, then bot squads.
K.botSeatFor = function(c: Ctx, wantDead: boolean?, prefer: number?): number?
	local best, bestScore = nil, -1
	for _, s in c.match:squadsInRun() do
		local humans = #squadHumans(c, s)
		for _, id in c.match:activeMembers(s) do
			local h = c.heroes[id]
			if h and h.isBot and (not wantDead or isDowned(c, id)) then
				local score = (if humans > 0 then 10 + humans else 1) + (if s == prefer then 100 else 0)
				if score > bestScore then
					best, bestScore = id, score
				end
			end
		end
	end
	return best
end

K.removeBot = function(c: Ctx, botId: number)
	c.heroes[botId] = nil
	for i, b in c.bots do
		if b.id == botId then
			table.remove(c.bots, i)
			break
		end
	end
	c.tally[botId] = nil
	if BotService and type(BotService.despawn) == "function" then
		pcall(BotService.despawn, botId)
	end
end

-- Seats a queued joiner in a bot's seat. Returns the PlayerRun or nil.
K.takeSeat = function(c: Ctx, p: Player, botId: number): PlayerRun?
	local old = c.match:member(p.UserId)
	-- QC minor 4: a returning player (old record left) may sit again
	if p.Parent ~= Players or c.members[p] or (old and not old.left) then
		return nil
	end
	if not c.match:replaceSeat(botId, p.UserId) then
		return nil
	end
	local squad = c.match:squadOf(p.UserId) :: number
	c.solo = false -- QC: a second human was seated; nobody gets solo credit
	K.removeBot(c, botId)
	removeFromWorld(c, botId, false)
	table.insert(c.order, p)
	local pr = K.newPlayerRun(c, p, LobbyService.getClass(p), squad, #c.order + 20)
	pcall(K.refreshRunBonuses, c)
	computeStats(c, pr)
	if type(LobbyService.joinRun) == "function" then
		pcall(LobbyService.joinRun, p)
	end
	Remotes.toast(
		p,
		string.format("You take a seat in squad %s! Fight with your herd.", squadName(squad)),
		"good"
	)
	toastSquad(c, squad, p.DisplayName .. " joins your squad!", "good")
	return pr
end

-- A bot's Herd Call fired with joiners waiting: the first one drops in instead.
K.seatJoinerNow = function(c: Ctx, botId: number, x: number, z: number): boolean
	local p = table.remove(c.joinQueue, 1)
	if not p then
		return false
	end
	local pr = K.takeSeat(c, p, botId)
	if not pr then
		return false
	end
	local world = c.world
	if world then
		local C = MatchState.CONFIG
		world:addPlayer(pr.id, pr.stats, pr.weapon, pr.ability, x + 3, z, pr.squad)
		if type(world.setSquad) == "function" then
			pcall(world.setSquad, world, pr.id, pr.squad)
		end
		pcall(world.protect, world, pr.id, C.REDEPLOY_PROTECT)
		K.heroJoinedWorld(c, pr)
	end
	pcall(CombatService.setPlayers, memberList(c))
	task.spawn(function()
		teleportToArena(c, pr)
		decorate(c, pr)
	end)
	broadcastRunState(c)
	sendPartyHud(c, true)
	K.sendStorm(c, pr.player)
	K.sendShops(c, pr.player) -- v5
	c.walletDirty[pr.userId] = true
	return true
end

-- Next stage start: every queued joiner takes a bot's seat (before the World is built).
K.seatJoiners = function(c: Ctx)
	local still = {}
	for _, p in c.joinQueue do
		-- QC minor 4: a returning player goes back to their old squad when it has a bot seat
		local old = c.match:member(p.UserId)
		local botId = K.botSeatFor(c, nil, old and old.squad)
		if not botId or not K.takeSeat(c, p, botId) then
			if p.Parent == Players and not c.members[p] then
				table.insert(still, p)
			end
		end
	end
	c.joinQueue = still
	for _, p in still do
		K.practiceYard(p)
	end
end

K.practiceYard = function(p: Player)
	pcall(p.SetAttribute, p, "PracticeYard", true)
	Remotes.toast(p, "This match is full: you'll join the next one from the lobby!", "info")
end

-- LobbyService: a player joined (or came back) while a match runs.
K.onLateJoin = function(p: Player)
	local c = ctx
	if not c or c.finished or c.members[p] or table.find(c.joinQueue, p) then
		return
	end
	if c.match:humansInRun() >= LobbyService.MAX_PARTY or not K.botSeatFor(c) then
		K.practiceYard(p)
		return
	end
	table.insert(c.joinQueue, p)
	Remotes.toast(p, "A match is running: you'll take a bot's seat at the next stage (or sooner)!", "info")
end

-- After a hero is (re)added to a World: rookie flag and hero level (team M1 API).
K.heroJoinedWorld = function(c: Ctx, h: any)
	local world = c.world :: any
	if not world then
		return
	end
	if type(world.setHeroLevel) == "function" then
		pcall(world.setHeroLevel, world, h.id, h.level)
	end
	-- iteration 5 (A3): every equipped ability slot (addPlayer only knows slot 1)
	if type(h.abilities) == "table" and #h.abilities > 1 and type(world.setPlayerAbilities) == "function" then
		pcall(world.setPlayerAbilities, world, h.id, h.abilities)
	end
	local m = c.match:member(h.id)
	if m and m.rookie and type(world.setRookie) == "function" then
		pcall(world.setRookie, world, h.id, true)
	end
	-- iteration 2 (team M1): class, Ascension nodes
	if type(world.setHeroClass) == "function" then
		pcall(world.setHeroClass, world, h.id, h.classId)
	end
	local ex = K.extras(h)
	if ex and finite(ex.ascNodes) and type(world.setAscension) == "function" then
		pcall(world.setAscension, world, h.id, h.classId, ex.ascNodes)
	end
	if c.wallets[h.id] and type(world.setRunMods) == "function" then
		pcall(world.setRunMods, world, h.id, RunWallet.deltas(c.wallets[h.id], h.classId)) -- v5
	end
	if not h.isBot and type(world.setAim) == "function" then
		pcall(world.setAim, world, h.id, K.aimModeOf(h.player)) -- iteration 4 (bots: nearest)
	end
end

-- Rookie: run 1's first champion at x0.7 HP (the World's champion entity).
K.softenChampion = function(c: Ctx, champ: any)
	if c.firstChampDone then
		return
	end
	local rookie1 = false
	for _, pr in c.members do
		rookie1 = rookie1 or (pr.rookieRuns == 0 and not pr.out)
	end
	if not rookie1 then
		return
	end
	local world = c.world :: any
	if not world or type(world.enemies) ~= "table" then
		return
	end
	for _, e in world.enemies do
		if type(e) == "table" and e.id == champ and e.alive then
			e.maxHp *= K.ROOKIE_CHAMP_HP
			e.hp = math.min(e.hp, e.maxHp)
			c.firstChampDone = true
			return
		end
	end
end

-- Pings and quick-chat ---------------------------------------------------------------------------

K.allowPing = function(p: Player): boolean
	local now = os.clock()
	local log = K.pingLog[p] or {}
	local live = {}
	for _, t in log do
		if now - t < K.PING_TTL then
			table.insert(live, t)
		end
	end
	if #live >= K.PING_ACTIVE then
		K.pingLog[p] = live
		return false
	end
	table.insert(live, now)
	K.pingLog[p] = live
	return true
end

K.onPing = function(player: Player, kind: string, x: number, z: number)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or pr.out or not LIVE_PHASES[phaseOf(c)] then
		return
	end
	if not K.allowPing(player) then
		return
	end
	local R = if c.storm then c.storm.R else 600
	local px, pz = math.clamp(x, -R * 1.5, R * 1.5), math.clamp(z, -R * 1.5, R * 1.5)
	local t = serverNow()
	Remotes.fireList(
		squadHumans(c, pr.squad),
		Net.S2C.PingShown,
		{ by = pr.userId, squad = pr.squad, kind = kind, x = px, z = pz, t = t }
	)
	if BotService and type(BotService.ping) == "function" then
		pcall(
			BotService.ping,
			pr.squad,
			{ kind = kind, x = px, z = pz, by = pr.userId, untilT = t + K.PING_TTL }
		)
	end
end

K.onQuickChat = function(player: Player, index: number)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or pr.out or not K.QUICK_CHAT[index] then
		return
	end
	local x, z = heroPos(c, pr.userId)
	Remotes.fireList(squadHumans(c, pr.squad), Net.S2C.PingShown, {
		by = pr.userId,
		squad = pr.squad,
		kind = "chat",
		index = index,
		x = x,
		z = z,
		t = serverNow(),
	})
end

-- Herd Awards ------------------------------------------------------------------------------------

K.awardEntries = function(c: Ctx): { any }
	local list = {}
	for id, h in c.heroes do
		local m = c.match:member(id)
		if m then
			local t = K.tallyOf(c, id)
			local e = table.clone(t)
			e.id = id
			e.heroDowns = m.downs
			e.championKills = m.championKills
			e.extracted = m.result == "extracted" or m.result == "lastHerd"
			if not h.isBot then
				local po = c.match:payout(id)
				e.banked = if po then po.cheese else m.banked
			else
				e.banked = m.banked
			end
			table.insert(list, e)
		end
	end
	return list
end

K.sendAwards = function(c: Ctx, players: { Player }, final: boolean)
	local ok, a = pcall(MatchState.awards, K.awardEntries(c))
	if not ok or type(a) ~= "table" then
		warn("[RunDirector] awards failed: " .. tostring(a))
		return
	end
	local accolades: { [string]: { string } } = {}
	for id, list in a.accolades do
		if not Ids.isBot(id) then
			accolades[tostring(id)] = list
		end
	end
	local mvp = nil
	if a.mvp then
		local h = c.heroes[a.mvp.id]
		mvp = {
			id = a.mvp.id,
			name = heroName(h),
			isBot = h ~= nil and h.isBot == true,
			squad = c.match:squadOf(a.mvp.id),
			classId = h and h.classId,
			score = a.mvp.score,
		}
	end
	local topBot = nil
	if a.topBot then
		local hb = c.heroes[a.topBot.id]
		topBot = {
			id = a.topBot.id,
			name = heroName(hb),
			isBot = true,
			squad = c.match:squadOf(a.topBot.id),
			classId = hb and hb.classId,
			score = a.topBot.score,
		}
	end
	for _, p in players do
		local id = p.UserId
		Remotes.fireTo(p, Net.S2C.Awards, {
			topBot = topBot, -- iteration 1 (P-10): the MVP is a human; the best 🤖 apart
			mvp = mvp,
			accolades = accolades,
			you = { id = id, accolades = a.accolades[id] or {}, score = a.scores[id] or 0 },
			final = final,
		})
	end
end

-- Play Again -------------------------------------------------------------------------------------

K.onPlayAgain = function(player: Player)
	if K.teleporting[player] then
		return
	end
	local c = ctx
	local pr = c and c.members[player]
	local fighting = pr ~= nil and not pr.out
	-- QC MAJOR 2: only the caller ever teleports. A party member's open invite
	-- (<= INVITE_SECONDS old) joins that reserved server; otherwise a player who is
	-- out of a match reserves a fresh one and invites their party.
	local inv = K.invites[player]
	local code: string? = nil
	if inv and os.clock() <= inv.untilT and not fighting then
		code = inv.code
	elseif not K.outPlayers[player] or fighting then
		Remotes.toast(player, "Play Again opens once you're out of the match.", "bad")
		return
	end
	K.teleporting[player] = true
	K.invites[player] = nil
	task.spawn(function()
		local TeleportService = game:GetService("TeleportService")
		local ok, err = pcall(function()
			if code == nil then
				local reserved = TeleportService:ReserveServer(game.PlaceId)
				code = reserved
				-- the party gets an invite: they choose whether to follow
				local partyList = {}
				if type(LobbyService.partyOf) == "function" then
					local okP, list = pcall(LobbyService.partyOf, player)
					partyList = if okP and type(list) == "table" then list else {}
				end
				for _, q in partyList do
					if q ~= player and q.Parent == Players then
						K.invites[q] =
							{ code = reserved, untilT = os.clock() + K.INVITE_SECONDS, from = player.UserId }
						Remotes.toast(
							q,
							player.DisplayName .. " started a new match: press Play Again to join them!",
							"info"
						)
					end
				end
			end
			local opts = Instance.new("TeleportOptions")
			opts.ReservedServerAccessCode = code :: string
			TeleportService:TeleportAsync(game.PlaceId, { player }, opts)
		end)
		if not ok then
			warn("[RunDirector] PlayAgain teleport failed: " .. tostring(err))
			K.teleporting[player] = nil
			Remotes.toast(player, "Couldn't start a new server right now. Try again in a moment!", "bad")
		else
			Remotes.toast(player, "Off to a fresh server...", "info")
			task.delay(30, function()
				K.teleporting[player] = nil
			end)
		end
	end)
end

-- v5 run economy (team M2, docs/V5-PLAN.md §A + iteration-1 PLAN §D) -------------------------
-- Every hero (bots too) has a Run/RunWallet. Rinds come from the World's `rinds`
-- events (team M1); until the World sends them, RunDirector pays the kill table
-- itself (RunShop.rindsFor: mouse, champion and boss, split by squad damage). Whey:
-- +40 per POI, champion 60 (top squad) / 30 (other squads that hit it), +50 per
-- stage survived, +1 per 25 rinds. Spending is validated here (phase, place,
-- standing hero); RunWallet checks the money. World.setRunMods applies the layer.

K.walletOf = function(c: Ctx, id: number): any
	local w = c.wallets[id]
	if not w then
		w = RunWallet.new()
		c.wallets[id] = w
	end
	return w
end

-- Iteration 1 (team P): each hero's long-term run bonus (Herd Talent Board,
-- Evolution, the squad's charm aura), read once per stage. Bots get the aura of
-- their squad's humans. Applies the one-time start rinds / whey.
K.refreshRunBonuses = function(c: Ctx)
	if not DataService or type(DataService.runBonuses) ~= "function" then
		return
	end
	-- humans first: iteration 4, bots scale to their squad's humans (Run/BotBonus)
	for pass = 1, 2 do
		for id, h in c.heroes do
			if c.match:isInRun(id) and (pass == 1) ~= (h.isBot == true) then
				local humans = squadHumans(c, h.squad)
				local ok, b
				if h.isBot then
					local aura = nil
					if type(DataService.squadGemAura) == "function" then
						local okA, a = pcall(DataService.squadGemAura, humans)
						aura = if okA and type(a) == "table" then a else nil
					end
					local bonuses = {}
					for _, p in humans do
						local hb = c.members[p] and c.members[p].runBonus
						if hb then
							table.insert(bonuses, hb)
						end
					end
					ok, b = pcall(K.BotBonus.scaled, bonuses, aura)
				else
					ok, b = pcall(DataService.runBonuses, h.player, h.classId, humans)
				end
				h.runBonus = if ok and type(b) == "table" then b else nil
				local ex = h.runBonus and h.runBonus.extras
				if ex and not h.isBot and not h.startGranted then
					h.startGranted = true
					local w = K.walletOf(c, id)
					RunWallet.earnRinds(w, if finite(ex.startRinds) then ex.startRinds else 0)
					RunWallet.earnWhey(w, if finite(ex.startWhey) then ex.startWhey else 0)
					c.walletDirty[id] = true
				end
			end
		end
	end
end

-- Iteration 2 (team M1): each squad's gem uniques (the union of its humans').
K.applySquadUniques = function(c: Ctx)
	local world = c.world :: any
	if world and type(world.setHeroUniques) == "function" then
		-- iteration 4 (team P): gems are personal, so each hero carries its OWN uniques
		for id, h in c.heroes do
			if not h.isBot and c.match:isInRun(id) then
				local b = h.runBonus
				pcall(
					world.setHeroUniques,
					world,
					id,
					if b and type(b.uniques) == "table" then b.uniques else {}
				)
			end
		end
		return
	end
	if not world or type(world.setSquadUniques) ~= "function" then
		return
	end
	for _, sq in c.match:squadsInRun() do
		local set, list = {}, {}
		for _, p in squadHumans(c, sq) do
			local b = c.members[p].runBonus
			for _, u in (if b and type(b.uniques) == "table" then b.uniques else {}) do
				if not set[u] then
					set[u] = true
					table.insert(list, u)
				end
			end
		end
		pcall(world.setSquadUniques, world, sq, list)
	end
end

K.extras = function(h: any): any
	return h and h.runBonus and h.runBonus.extras or nil
end

-- Pushes the hero's run layer to the World and marks the HUD dirty.
K.applyRunMods = function(c: Ctx, h: any)
	local world = c.world :: any
	local w = c.wallets[h.id]
	if not w then
		return
	end
	if world and type(world.setRunMods) == "function" then
		pcall(world.setRunMods, world, h.id, RunWallet.deltas(w, h.classId))
	else
		refreshHero(c, h) -- computeStats folds the layer in (no World support)
	end
	if not h.isBot then
		c.walletDirty[h.id] = true
	end
end

K.sendWallet = function(c: Ctx, pr: PlayerRun)
	local w = c.wallets[pr.userId]
	if w and not pr.out then
		local view = RunWallet.view(w)
		view.stomps = (c.tally[pr.userId] or {}).mice or 0 -- this run's own mouse kills (team U)
		Remotes.fireTo(pr.player, Net.S2C.Wallet, view)
	end
end

-- Bots spend their rinds on stat ranks (the cheapest next rank) so PvP stays even.
K.botSpend = function(c: Ctx, b: any)
	local w = c.wallets[b.id]
	if not w then
		return
	end
	local bought = false
	for _ = 1, 60 do -- iteration 4: cheap linear ranks
		local best, bestCost = nil, math.huge
		for _, stat in RunWallet.Shop.RANK_ORDER do
			local cost = RunWallet.rankCost(stat, w.ranks[stat] or 0)
			if cost and cost < bestCost then
				best, bestCost = stat, cost
			end
		end
		if not best or bestCost > w.rinds then
			break
		end
		RunWallet.buyRank(w, best)
		bought = true
	end
	if bought then
		K.applyRunMods(c, b)
	end
end

K.earn = function(c: Ctx, id: any, rinds: number?, whey: number?, mult: number?)
	local h = heroOf(c, id)
	if not h or not c.match:isInRun(h.id) then
		return
	end
	local w = K.walletOf(c, h.id)
	local ex = K.extras(h)
	if rinds and rinds > 0 then
		local rm = if ex and finite(ex.rindMult) and ex.rindMult > 0 then ex.rindMult else 1
		RunWallet.earnRinds(w, rinds, (mult or 1) * rm, c.worldRinds)
	end
	if whey and whey > 0 then
		local wm = if ex and finite(ex.wheyMult) and ex.wheyMult > 0 then ex.wheyMult else 1
		RunWallet.earnWhey(w, whey * wm)
	end
	if h.isBot then
		if w.rinds >= 20 then
			K.botSpend(c, h)
		end
	else
		c.walletDirty[h.id] = true
	end
end

-- Splits `total` over squads by damage share; each member gets its squad's part.
K.earnSplit = function(c: Ctx, damageBySquad: any, total: number, wheyTop: number?, wheyOther: number?)
	if type(damageBySquad) ~= "table" then
		return
	end
	local sum, top, topD = 0, nil, 0
	for sq, d in damageBySquad :: any do
		if finite(d) and d > 0 then
			sum += d
			if d > topD then
				top, topD = tonumber(sq), d
			end
		end
	end
	if sum <= 0 then
		return
	end
	for sq, d in damageBySquad :: any do
		local s = tonumber(sq)
		if s and finite(d) and d > 0 and c.match:isSquadInRun(s) then
			-- the World pays champion / boss rinds and champion whey itself
			local part = if c.worldRinds then 0 else total * d / sum
			local whey = if c.worldRinds then nil elseif s == top then wheyTop else wheyOther
			for _, id in c.match:activeMembers(s) do
				K.earn(c, id, part, whey)
			end
		end
	end
end

-- Stall pads, the Class Stall, the Big Cheese Altar and the Swap Stand for this
-- stage (RunWallet.layout around the arena centre at 0.55 R). G builds the models
-- from the same payload (ArenaBuilder.placeShops when it exists).
K.layoutShops = function(c: Ctx, R: number)
	local center = arenaCenter(c)
	local rng = Rng.new(c.match:stageSeed()):fork(0x57A1)
	local stalls, altar, swap = RunWallet.layout(rng, R, center.X, center.Z)
	-- iteration 1 (team G): ArenaBuilder places the models (ArenaInfo.stalls); the
	-- offers are rolled here, the positions follow the built pads (prompt StallId)
	local built = c.arena and (c.arena :: any).stalls
	if type(built) == "table" and type(built.stalls) == "table" and built.altar and built.swap then
		local list = {}
		for i, st in built.stalls do
			local pool = table.clone(RunWallet.Shop.BUFF_ORDER)
			rng:shuffle(pool)
			table.insert(list, {
				id = tostring(st.id or ("stall" .. i)),
				x = st.x,
				z = st.z,
				offers = { pool[1], pool[2] },
				class = false,
			})
		end
		if built.classStall then
			table.insert(list, {
				id = "class",
				x = built.classStall.x,
				z = built.classStall.z,
				offers = { "class" },
				class = true,
			})
		end
		stalls, altar, swap = list, built.altar, built.swap
	end
	c.shops = {
		stalls = stalls,
		altar = { x = altar.x, z = altar.z, open = c.match.stage >= RunWallet.Shop.ALTAR_FROM_STAGE },
		swap = { x = swap.x, z = swap.z },
	}
	if type(ArenaBuilder.placeShops) == "function" then
		local ok, err = pcall(ArenaBuilder.placeShops, c.shops)
		if not ok then
			warn("[RunDirector] placeShops failed: " .. tostring(err))
		end
	end
	K.sendShops(c)
	for _, p in memberList(c) do
		K.walletOf(c, p.UserId)
		c.walletDirty[p.UserId] = true
	end
end

K.sendShops = function(c: Ctx, target: Player?)
	if not c.shops then
		return
	end
	Remotes.fireList(if target then { target } else memberList(c), Net.S2C.Stalls, c.shops)
end

-- A standing hero in the run, in a live phase, within `r` studs of (x, z)?
K.at = function(c: Ctx, pr: PlayerRun, x: number, z: number, r: number): (boolean, string?)
	if pr.out or not LIVE_PHASES[phaseOf(c)] then
		return false, "phase"
	end
	local info = c.world and c.world:getPlayer(pr.userId)
	if not info or info.downed or info.dead then
		return false, "down"
	end
	if not RunWallet.near(info.x, info.z, x, z, r) then
		return false, "far"
	end
	return true, nil
end

K.SHOP_REFUSALS = {
	funds = "Not enough rinds or whey for that.",
	owned = "You already have that buff this life.",
	max = "Maxed out.",
	stage = "The Big Cheese Altar opens on stage 3.",
	far = "Walk onto the pad to buy.",
	down = "Get back up first!",
	phase = "The shops are closed right now.",
	offer = "This stall doesn't sell that.",
}

K.shopRefuse = function(player: Player, why: string?)
	Remotes.toast(player, K.SHOP_REFUSALS[why or ""] or "Can't buy that right now.", "bad")
end

K.onBuyRank = function(player: Player, stat: string)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or pr.out or not LIVE_PHASES[phaseOf(c)] then
		return
	end
	if not RunWallet.Shop.RANKS[stat] then
		Guard.reject(player, "BuyRank", "unknown stat", false)
		return
	end
	local ok, why = RunWallet.buyRank(K.walletOf(c, pr.userId), stat)
	if not ok then
		K.shopRefuse(player, why)
		return
	end
	K.flagsOf(c, pr.userId).rankBought = true
	K.applyRunMods(c, pr)
end

K.onBuyStallBuff = function(player: Player, stallId: string, buffId: string)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or not c.shops then
		return
	end
	local stall = nil
	for _, s in c.shops.stalls do
		if s.id == stallId then
			stall = s
		end
	end
	if not stall then
		Guard.reject(player, "BuyStallBuff", "unknown stall", false)
		return
	end
	local here, why = K.at(c, pr, stall.x, stall.z, RunWallet.STALL_RADIUS)
	if not here then
		K.shopRefuse(player, why)
		return
	end
	local ok, why2 = RunWallet.buyBuff(K.walletOf(c, pr.userId), buffId, stall.offers)
	if not ok then
		K.shopRefuse(player, why2)
		return
	end
	K.flagsOf(c, pr.userId).wheyBuff = true
	K.applyRunMods(c, pr)
	Remotes.toast(player, "Buff bought! It lasts until you are knocked out.", "good")
end

K.onBuyUltimate = function(player: Player, id: string)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or not c.shops then
		return
	end
	local altar = c.shops.altar
	local here, why = K.at(c, pr, altar.x, altar.z, RunWallet.ALTAR_RADIUS)
	if not here then
		K.shopRefuse(player, why)
		return
	end
	local ok, why2 = RunWallet.buyUltimate(K.walletOf(c, pr.userId), id, c.match.stage)
	if not ok then
		K.shopRefuse(player, why2)
		return
	end
	local fl = K.flagsOf(c, pr.userId)
	fl.wheyBuff = true -- an Altar buff counts too (Whey Ascetic)
	fl.ultimates += 1
	K.applyRunMods(c, pr)
	-- the buyer becomes everyone's target: announced, bounty +50%
	local name = id
	local def = RunWallet.Shop.ULTIMATES[id]
	if def and type(def.name) == "string" then
		name = def.name
	end
	c.match:altarBounty(pr.userId)
	killFeed(c, { killer = pr.userId, killerSquad = pr.squad, kind = "altar", ultimate = id })
	toastAll(
		c,
		string.format("%s claimed %s at the Big Cheese Altar! Bounty +50%%!", player.DisplayName, name),
		"bad"
	)
	sendMatch(c, true)
end

K.onSwap = function(player: Player, dir: string, amount: number)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or not c.shops then
		return
	end
	if dir ~= "toWhey" and dir ~= "toRinds" then
		return
	end
	if type(amount) ~= "number" or amount ~= amount or amount < 1 or amount > 1e6 then
		return
	end
	local sw = c.shops.swap
	local here, why = K.at(c, pr, sw.x, sw.z, RunWallet.ALTAR_RADIUS)
	if not here then
		K.shopRefuse(player, why)
		return
	end
	-- iter 5 #2: two-way (whey -> rinds at SWAP_RATE x SWAP_BACK_RATE per whey)
	local got = if dir == "toRinds"
		then RunWallet.swapToRinds(K.walletOf(c, pr.userId), math.floor(amount))
		else RunWallet.swapToWhey(K.walletOf(c, pr.userId), amount)
	if got <= 0 then
		K.shopRefuse(player, "funds")
		return
	end
	c.walletDirty[pr.userId] = true
end

-- Knocked out (dead): whey buffs and ultimates are lost (ranks, rinds and whey stay).
K.knockout = function(c: Ctx, id: number)
	c.knockedOut[id] = true
	if memberById(c, id) then
		K.flagsOf(c, id).knockedOut = true
	end
	local w = c.wallets[id]
	if not w then
		return
	end
	local lost = RunWallet.knockout(w)
	local h = c.heroes[id]
	if #lost > 0 and h then
		K.applyRunMods(c, h)
		if not h.isBot then
			Remotes.toast(h.player, "Knocked out: your whey buffs are gone.", "bad")
		end
	end
end

-- Iteration 1 (B, P-8): the Results breakdown -------------------------------------------------

K.firstExtractOf = function(award: any): any
	local fe = award and award.firstExtractBonus
	if type(fe) ~= "table" then
		return nil
	end
	return { cheese = fe.cheese or 0, golden = fe.goldenCheese or fe.golden or 0 }
end

K.totalCheese = function(cheese: number, award: any): number
	local total = cheese
	local fe = K.firstExtractOf(award)
	if fe then
		total += fe.cheese
	end
	for _, key in { "contracts", "achievements" } do
		local part = award and award[key]
		if type(part) == "table" and finite(part.cheese) then
			total += part.cheese
		end
	end
	if award and finite(award.firstRunBonus) then
		total += award.firstRunBonus
	end
	return math.floor(total)
end

-- Double or Nothing this run: {won, amount} (the member's part of the squad's x2 or loss).
K.donOf = function(c: Ctx, id: number): any
	local t = c.tally[id]
	if not t or ((t.donWon or 0) == 0 and (t.donLost or 0) == 0) then
		return nil
	end
	local won = (t.donWon or 0) >= (t.donLost or 0)
	return { won = won, amount = math.floor(if won then t.donWon else t.donLost) }
end

-- The ready-made {{label, amount}} list (team U shows it as is).
K.breakdownList = function(
	po: any,
	cheese: number,
	mult: number,
	classXp: number,
	xp: number,
	award: any
): { any }
	local list = {}
	local function row(label: string, amount: any)
		if finite(amount) and amount ~= 0 then
			table.insert(list, { label = label, amount = math.floor(amount + 0.5) })
		end
	end
	row("🧀 Run cheese", po.cheese)
	row("🔒 of it secured mid-run", po.secured)
	row(string.format("⚡ Boosts and difficulty x%.2f", mult), cheese - po.cheese)
	local fe = K.firstExtractOf(award)
	if fe then
		row("🎉 First extraction", fe.cheese)
		row("✨ First extraction Golden Cheese", fe.golden)
	end
	row("☀ First run of the day", award and award.firstRunBonus)
	row("📜 Contracts", award and type(award.contracts) == "table" and award.contracts.cheese or nil)
	row(
		"🏅 Achievements",
		award and type(award.achievements) == "table" and award.achievements.cheese or nil
	)
	row("🎟 Pass XP", award and award.passXp)
	row("🐘 Class XP", classXp)
	row("⭐ Account XP", xp)
	return list
end

-- Iteration 1 (B): Fx beats for the client (U banner, G slow-mo) ------------------------------

K.bossBeat = function(c: Ctx, kind: string, bossId: string, extra: { [string]: any }?)
	local def = lookupDef(Bosses, bossId) or {}
	local fx: { [string]: any } = {
		t = kind, -- "bossIntro" | "bossKill"
		bossId = bossId,
		name = if type(def.name) == "string" then def.name else bossId,
		title = def.title,
		lore = def.lore,
		tip = def.tip,
		stage = c.match.stage,
	}
	for k, v in extra or {} do
		fx[k] = v
	end
	Remotes.fx({ fx }, memberList(c))
end

-- Iteration 1 (C, P-14): whom a dead hero watches (the standing squadmate with the
-- most HP). Sent in Redeploy {untilT, spectate, spectateName}.
K.spectateOf = function(c: Ctx, id: number): (number?, string?)
	local mate = K.standingMate(c, id)
	if not mate then
		return nil, nil
	end
	return mate, heroName(c.heroes[mate])
end

-- Iteration 2: numbered waves + the Early Horn, gem drops, challenge flags, rind gifts -----------

-- Wave state to the run's humans: Fx {t = "wave", index, total, stageWave, phase,
-- endsAt (server time), horn = {skipped, rinds}?, horns} (team U: "Wave 7 / 20").
K.sendWave = function(c: Ctx, horn: any?)
	local s = c.waves
	if not s then
		return
	end
	local now = os.clock()
	local left = if s.phase == "wave"
		then s.waveSeconds - (now - s.waveStart)
		elseif s.phase == "lull" then s.lullSeconds - (now - s.startedAt)
		elseif s.phase == "horn" then K.Waves.HORN_WARN_SECONDS - (now - s.startedAt)
		else 0
	c.waveFx = {
		t = "wave",
		index = K.Waves.index(c.match.stage, s.wave),
		total = K.Waves.total(MatchState.CONFIG.STAGES),
		stageWave = s.wave,
		phase = s.phase,
		endsAt = serverNow() + math.max(0, left),
		stomped = math.floor(K.Waves.stomped(s) * 100 + 0.5),
		skipAt = c.skipWaveAt,
		horns = s.horns,
		horn = horn,
	}
	Remotes.fx({ c.waveFx }, memberList(c))
end

-- The horn sounded: pay the skipped seconds to every standing hero.
K.soundHorn = function(c: Ctx, by: Player?)
	local s = c.waves
	if not s then
		return
	end
	local skipped = K.Waves.horn(s, os.clock())
	local per = math.floor(skipped * K.Waves.HORN_RINDS)
	for _, sq in c.match:squadsInRun() do
		for _, id in c.match:activeMembers(sq) do
			if not isDowned(c, id) then
				K.earn(c, id, per)
				K.quest(c, id, "horn")
			end
		end
	end
	toastAll(
		c,
		string.format(
			"%sEarly Horn! The next wave comes now: +%d rinds each.",
			if by then by.DisplayName .. " sounds the " else "",
			per
		),
		"info"
	)
	K.sendWave(c, { skipped = math.floor(skipped), rinds = per })
end

-- Runs the horde waves of one stage (K.Waves.tick); true once the boss wave is due.
K.wavesTick = function(c: Ctx): boolean
	local s = c.waves
	if not s then
		return true
	end
	local now = os.clock()
	if K.Waves.canHorn(s, now, c.skipWaveAt) then
		K.soundHorn(c, nil)
	end
	local ev = K.Waves.tick(s, now, #c.match:squadsInRun() * Squads.SIZE, K.paceHornRate(c))
	if ev == nil then
		return false
	end
	local world = c.world :: any
	if ev == "wave" then
		c.waveWorldT0 = K.worldNow(c)
		if world and type(world.startWave) == "function" then
			pcall(world.startWave, world, K.Waves.index(c.match.stage, s.wave), { stageWave = s.wave })
		end
	end
	if ev == "wave" then
		s.waveHorned = s.phase == "wave" and s.horns > 0
	end
	-- the Herd Call window closes 20 s before the boss wave (an estimate with horns)
	local remaining = (K.Waves.HORDE_WAVES - s.wave) * (s.waveSeconds + s.lullSeconds)
		+ (if s.phase == "wave" then s.waveSeconds - (now - s.waveStart) else 0)
	c.waveEndsAt = serverNow() + math.max(0, remaining)
	setPhaseTimer(c, math.max(1, remaining))
	K.sendWave(c)
	if ev == "boss" then
		for _, p in memberList(c) do
			local f = K.flagsOf(c, p.UserId)
			f.allHorned = f.allHorned and s.hornAll
			f.horns += s.horns
		end
		return true
	end
	return false
end

-- A player's manual horn (C2S EarlyHorn, when the lead adds it): half stomped.
K.onEarlyHorn = function(player: Player)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or pr.out or phaseOf(c) ~= "Waves" or not c.waves then
		return
	end
	if not K.Waves.canHorn(c.waves, os.clock(), c.skipWaveAt, true) then
		Remotes.toast(player, "Stomp half of this wave first (and give it 10 s).", "bad")
		return
	end
	K.soundHorn(c, player)
end

-- Challenge flags (team P evaluates them in Data/Challenges) ------------------------------------

K.flagsOf = function(c: Ctx, id: number): { [string]: any }
	local f = c.flags[id]
	if not f then
		f = {
			rankBought = false,
			wheyBuff = false,
			knockedOut = false,
			routesAllHigh = true,
			allHorned = true,
			horns = 0,
			donWins = 0,
			ultimates = 0,
			lairsInStage = 0,
			snatchBoss = false,
			bountiesDowned = 0,
			enemyDowned = false,
		}
		c.flags[id] = f
	end
	return f
end

K.flagSquad = function(c: Ctx, squad: any, key: string, value: any)
	if type(squad) ~= "number" then
		return
	end
	for _, p in squadHumans(c, squad) do
		local f = K.flagsOf(c, p.UserId)
		if type(value) == "number" then
			f[key] = (f[key] or 0) + value
		else
			f[key] = value
		end
	end
end

-- Solo credit: one human at the start, never a second one seated, one in the run now.
K.isSolo = function(c: Ctx): boolean
	return c.solo and #c.order == 1 and c.match:humansInRun() <= 1
end

-- The awardRun `challengeFlags` block for one human: the flag and counter names
-- of Config/Challenges (team P evaluates them).
K.challengeOf = function(c: Ctx, pr: PlayerRun, po: any): { [string]: any }
	local f = K.flagsOf(c, pr.userId)
	local squadKO = false
	for _, id in (c.match:squad(pr.squad) or { members = {} }).members do
		squadKO = squadKO or (c.knockedOut[id] == true)
	end
	return {
		-- flags
		noRankBought = not f.rankBought,
		noWheyBuff = not f.wheyBuff,
		noKnockout = not f.knockedOut,
		oneHitCurse = c.oneHit == true,
		allHigh = f.routesAllHigh,
		lairBothOneStage = f.lairsInStage >= 2,
		snatchBossKill = f.snatchBoss,
		allWavesHorned = f.allHorned and f.horns > 0,
		noEnemyDowned = not f.enemyDowned,
		squadAllStanding = po.extracted and c.squadStandingAtExtract[pr.squad] == true,
		squadNoKnockout = not squadKO,
		-- counters
		donWins = f.donWins,
		ultimates = f.ultimates,
		squadChampKills = c.squadChampKills[pr.squad] or 0,
		bountiedDowns = f.bountiesDowned,
		horns = f.horns,
	}
end

-- Gems (iteration 4, team P) ----------------------------------------------------------------------
-- Gems drop only when a round is completed: DataService.awardRun rolls them (the first
-- clear of a tier guarantees one; else min(20%, (6% + 2%/stage) x reward)). Boss, lair
-- and Double or Nothing drops are gone. After the payout, each new gem (Results.loot)
-- still gets team G's fly-up: Fx {t = "gemDrop", gem, tier} then {t = "gemGone"}.
K.showGems = function(c: Ctx, p: Player, gems: { any }?)
	if type(gems) ~= "table" or #gems == 0 or p.Parent ~= Players then
		return
	end
	local pr = c.members[p]
	local x, z = nil, nil
	if pr then
		x, z = heroPos(c, pr.userId)
		pr.gemsDropped = (pr.gemsDropped or 0) + #gems
	end
	local events, ids = {}, {}
	for _, g in gems do
		c.gemFxId = (c.gemFxId or 0) + 1
		table.insert(ids, c.gemFxId)
		table.insert(events, {
			t = "gemDrop",
			id = c.gemFxId,
			x = x,
			z = z,
			tier = g.t,
			unique = g.u,
			gem = g,
		})
	end
	Remotes.fx(events, p)
	task.delay(3, function()
		local gone = {}
		for _, id in ids do
			table.insert(gone, { t = "gemGone", id = id })
		end
		Remotes.fx(gone, p)
	end)
end

-- Rind gifting (C2S GiftRinds(targetId), when the lead adds it) -----------------------------------

K.GIFT_RINDS = 100
K.onGiftRinds = function(player: Player, targetId: number)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or pr.out or not LIVE_PHASES[phaseOf(c)] then
		return
	end
	local target = memberById(c, targetId)
	if not target or target == pr or target.out or target.squad ~= pr.squad then
		Remotes.toast(player, "Gifts go to a squadmate (never a bot).", "bad")
		return
	end
	local from = K.walletOf(c, pr.userId)
	if from.rinds < K.GIFT_RINDS then
		K.shopRefuse(player, "funds")
		return
	end
	from.rinds -= K.GIFT_RINDS
	local to = K.walletOf(c, target.userId)
	to.rinds += K.GIFT_RINDS -- a gift is not "earned" (no whey trickle, no stats)
	c.walletDirty[pr.userId] = true
	c.walletDirty[target.userId] = true
	Remotes.toast(
		target.player,
		string.format("%s gifted you %d rinds!", player.DisplayName, K.GIFT_RINDS),
		"good"
	)
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
K.grantEpicDrops = function(c: Ctx, squad: number)
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
		local tokenGiven = false
		local granted = profileUpdate(p, function(prof: any)
			if drop.kind == "cosmetic" then
				if type(prof.cosmetics) ~= "table" then
					prof.cosmetics = {}
				end
				prof.cosmetics[drop.id] = true
			else
				prof.rerollTokens, tokenGiven = EpicDrop.grantFallbackToken(prof.rerollTokens, K.REROLL_CAP)
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
				Remotes.toast(
					p,
					if tokenGiven
						then "You own every epic cosmetic! +1 free reroll token."
						else "You own every epic cosmetic, and your reroll tokens are full!",
					"good"
				)
			end
		end
	end
end

-- The boss chest's gear (Gear.bossChest, R2) for each member of the winning squad.
K.grantChestGear = function(c: Ctx, squad: number, tier: any)
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
		local ok, d, top = pcall(world.bossDamageBySquad, world)
		if ok and type(d) == "table" then
			if next(d) == nil and Squads.isValid(top) then
				return { [top] = 1 }
			end
			return d -- MatchState picks the top squad (ties: the match rng)
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
	pcall(K.bankMeter, c) -- iter 5 #8: keep the old World's damage meter
	pcall(K.bankFullMeter, c) -- iter 5 #1: and the full meter (S2C Meter / Results)
	-- Gear lasts the whole run: read it from the old World before it goes.
	for _, h in c.heroes do
		syncGear(c, h)
	end
	stopCombat(c)
	ArenaBuilder.clear()
	local stageSeed = c.match:stageSeed()
	local layout = {}
	-- v3: squad corners / safe zones scale with the map (Pois.squadCorners): the
	-- source of truth for drop-in spots, safe zones and POI clearance.
	-- v4: each stage is a bit smaller (Maps.stageRadius, team M1)
	local R = K.stageRadius(card.mapId, c.match.stage)
	local corners = Pois.squadCorners(R)
	local okL, lay = pcall(Pois.layout, Rng.new(stageSeed):fork(RunDirector.POI_SALT), card.mapId, R, corners)
	if okL and type(lay) == "table" then
		layout = lay
	else
		warn("[RunDirector] POI layout failed: " .. tostring(lay))
	end
	local arena =
		ArenaBuilder.build(card.mapId, stageSeed, { pois = layout, radius = R, stage = c.match.stage } :: any)
	c.arena = arena
	-- the World never reaches past the ground ArenaBuilder built
	local worldR = if type(arena) == "table" and finite(arena.radius) then math.min(arena.radius, R) else R
	if type(arena) == "table" then
		local y = if typeof(arena.spawn) == "Vector3" then arena.spawn.Y else 0
		local spawns = {}
		for i, z in corners do
			spawns[i] = Vector3.new(z.x, y, z.z)
		end
		arena.squadSpawns, arena.safeZones = spawns, corners
	end
	-- ArenaBuilder.build already applied the map's lighting: once per stage (QC-A minor 5)

	local mapDef = lookupDef(Maps, card.mapId)
	local world = World.new({
		rng = Rng.new(stageSeed):fork(c.stageIndex),
		mods = c.match:worldMods(),
		arenaRadius = worldR,
		obstacles = arena.obstacles or {},
		enemyPool = if mapDef and mapDef.enemyPool then mapDef.enemyPool else {},
		cycle = 1,
		stage = c.match.stage,
		safeZones = arena.safeZones, -- R4 safe corners (-60% PvP damage)
		tier = card.tier, -- R2: gear rarity rolls (armory, carriers, vault)
	})
	c.world = world
	if type(world.setStage) == "function" then
		world:setStage(1, c.match.stage)
	end
	K.stormStart(c, worldR)
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
	pcall(K.refreshRunBonuses, c)
	for _, h in heroes do
		computeStats(c, h)
		local pos = heroSpawnPos(c, h)
		world:addPlayer(h.id, h.stats, h.weapon, h.ability, pos.X, pos.Z, h.squad)
		if type(world.setSquad) == "function" then
			pcall(world.setSquad, world, h.id, h.squad)
		end
		K.heroJoinedWorld(c, h) -- v4: rookie flag, hero level
		-- Gear lasts the whole run: restore it in the new World (no events).
		if next(h.gear) ~= nil then
			if type(world.setGear) == "function" then
				pcall(world.setGear, world, h.id, table.clone(h.gear))
			else
				for _, item in gearList(h) do
					giveGear(c, h, item)
				end
			end
		end
		if not h.isBot and finite(h.stats.moveSpeed) then
			setHumanoidSpeed(h.player, h.stats.moveSpeed)
		end
	end
	if type(world.addPoi) == "function" then
		c.objModels = {}
		for _, entry in layout do
			local ok, err = pcall(world.addPoi, world, entry)
			if not ok then
				warn("[RunDirector] addPoi failed: " .. tostring(err))
			elseif type(err) == "number" then
				K.indexObjective(c, err, entry) -- iteration 4: team G's objective models
			end
		end
	end
	CombatService.start(world, memberList(c))
	syncBots(c)
	for _, p in memberList(c) do
		K.collect(c, p.UserId, "maps", card.mapId)
	end
	pcall(K.applySquadUniques, c)
	local okS, errS = pcall(K.layoutShops, c, worldR) -- v5 stalls, Altar, Swap Stand
	if not okS then
		warn("[RunDirector] shops: " .. tostring(errS))
	end
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
	for _, pr in c.members do
		pr.cartPoi, pr.cartShare = nil, nil
	end
	c.totemSquad = nil
	c.bossKill = nil
	c.buffs = {}
	c.downSince = {}
	for _, pr in c.members do
		pr.freeRerollsLeft = RunDirector.FREE_REROLLS_PER_STAGE
		pr.swapOffer = nil
	end

	-- v4: late joiners take bots' seats; a lone squad gets a Rival Herd
	local okJ, errJ = pcall(K.seatJoiners, c)
	if not okJ then
		warn("[RunDirector] seating late joiners failed: " .. tostring(errJ))
	end
	if match:needsRival() then
		local okR, errR = pcall(K.addRival, c)
		if not okR then
			warn("[RunDirector] Rival Herd failed: " .. tostring(errR))
		end
	end

	buildStage(c, card)
	local world = c.world :: any
	toastAll(c, stageIntroText(c, card), "info")

	-- Waves: 4 numbered horde waves (Run/Waves), then the boss wave. The World's
	-- spawning runs for the whole horde; World.startWave (team M1) shapes each wave.
	-- iteration 6 (team Flow): Fast pace = x0.7 wave timers (K.waveSecondsOf)
	local waveSeconds = K.waveSecondsOf(c)
	local scale = waveSeconds / K.Waves.hordeSeconds()
	c.waves =
		K.Waves.new(match.stage, os.clock(), #match:squadsInRun() * Squads.SIZE, K.paceHornRate(c), scale)
	world:startWaves(waveSeconds)
	c.waveWorldT0 = K.worldNow(c)
	if type(world.startWave) == "function" then
		pcall(world.startWave, world, K.Waves.index(match.stage, 1), { stageWave = 1 })
	end
	local deadline = setPhaseTimer(c, waveSeconds)
	c.waveEndsAt = serverNow() + waveSeconds
	local mods = match:worldMods()
	c.oneHit = c.oneHit or (type(mods) == "table" and mods.oneHitKO == true) -- Paper Elephant
	K.sendWave(c)
	K.markDoN(c)
	broadcastRunState(c)
	pcall(K.stormTick, c) -- the first circle
	if type(LobbyService.refresh) == "function" then
		LobbyService.refresh() -- lobby players: a fresh "match ends in about N min"
	end
	local r = waitFor(c, deadline, function()
		local okS, errS = pcall(K.stormTick, c)
		if not okS then
			warn("[RunDirector] storm: " .. tostring(errS))
		end
		local okD, errD = pcall(K.redeployTick, c)
		if not okD then
			warn("[RunDirector] Herd Call: " .. tostring(errD))
		end
		pcall(K.moveCaravans, c) -- iteration 4: the caravan model follows its entity
		if stageOver(c) then
			c.waves = nil
			return true
		end
		local okW, due = pcall(K.wavesTick, c)
		if not okW then
			warn("[RunDirector] waves: " .. tostring(due))
			return false
		end
		return due == true
	end)
	if r == "abort" then
		return "abort"
	elseif r == "fatal" then
		handleOut(c, match:finish("crash"), false)
		return "results"
	elseif r == "pred" and (match.phase == "Results" or c.waves == nil) then
		return "results"
	end

	-- Boss (centre of the map)
	world:stopSpawning()
	world:clearEnemies()
	match:startBoss()
	c.waves = nil
	c.waveEndsAt = nil
	K.redeployClose(c) -- no Herd Call during the boss: those heroes return next stage
	c.bossDead = false
	c.bossKill = nil
	c.bossSpawnedAt = os.clock()
	local center = arenaCenter(c)
	local zone = c.storm and c.storm.zone
	if zone and finite(zone.cx) and finite(zone.cz) then
		center = Vector3.new(zone.cx, center.Y, zone.cz) -- v4: the boss ring is the last circle
	end
	world:spawnBoss(card.bossId, center.X, center.Z)
	pcall(K.stormBoss, c)
	K.bossBeat(c, "bossIntro", card.bossId, { x = center.X, z = center.Z })
	local bossDeadline = setPhaseTimer(c, RunDirector.BOSS_SECONDS)
	broadcastRunState(c)
	toastAll(
		c,
		defName(Bosses, card.bossId)
			.. " appears in the boss ring! Most damage wins the chest; the killing blow snatches a bonus!",
		"bad"
	)
	local ended = false
	r = waitFor(c, bossDeadline, function()
		pcall(K.stormTick, c)
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

	-- Stage clear (the last stage auto-extracts: Portal Charm counts)
	updateExtractMults(c)
	-- v4 awards (Boss Breaker): each member's part of the squad's boss damage, in %
	local totalDamage = 0
	for _, d in (if type(damage) == "table" then damage else {}) :: any do
		totalDamage += if finite(d) then d else 0
	end
	if totalDamage > 0 then
		for sq, d in damage :: any do
			local sqn = tonumber(sq)
			local members = if sqn then match:activeMembers(sqn) else {}
			for _, id in members do
				K.tally(c, id, "bossDamagePct", (if finite(d) then d else 0) / totalDamage * 100 / #members)
				if finite(d) and d > 0 then
					K.tally(c, id, "bosses") -- v5 talent points: boss participation
				end
			end
		end
	end
	local result = match:bossDefeated(killerSquad, damage, r == "timeout")
	c.bossesKilled += 1
	for _, p in memberList(c) do
		K.collect(c, p.UserId, "bosses", card.bossId)
	end
	if
		(result.finished or match:isFinalGate()) -- iter 5 #6: the final gate is a clear too
		and match.stage >= MatchState.CONFIG.STAGES
		and c.cycle1Time == nil
	then
		c.cycle1Time = os.clock() - c.startedAt
	end
	local winner = result.winner
	if winner then
		for _, id in match:activeMembers(winner) do
			K.tally(c, id, "bossWins") -- v5 charm drops (the top-damage squad)
		end
		K.grantChestGear(c, winner, result.tier)
		if result.epic then
			K.grantEpicDrops(c, winner)
		end
	end
	K.markDoN(c)
	for sqId, amount in result.potBonus do
		local mem = match:activeMembers(sqId)
		for _, id in mem do
			K.tally(c, id, "donWon", amount / math.max(1, #mem))
		end
	end
	for sqId, amount in result.potLost or {} do
		local mem = match:activeMembers(sqId)
		for _, id in mem do
			K.tally(c, id, "donLost", amount / math.max(1, #mem))
		end
	end
	-- iteration 2: gem drops, challenge flags
	for sqId in result.potBonus do
		K.flagSquad(c, sqId, "donWins", 1)
	end
	-- iteration 3 (T-9): Snatcher counts only the human who landed the blow, alive
	local killerId = c.bossKill and c.bossKill.killer
	local snatcher = if result.snatch and type(killerId) == "number" then memberById(c, killerId) else nil
	if snatcher and snatcher.squad == result.snatch and not isDowned(c, snatcher.userId) then
		K.flagsOf(c, snatcher.userId).snatchBoss = true
	end
	c.stageLairs = {}
	-- v5: boss rinds split by damage share; +50 whey to every standing hero
	pcall(K.earnSplit, c, damage, RunWallet.rindsFor("boss", match.stage), nil, nil)
	for _, s2 in match:squadsInRun() do
		for _, id in match:activeMembers(s2) do
			if not isDowned(c, id) then
				K.earn(c, id, nil, RunWallet.Shop.WHEY.stage)
			end
		end
	end
	-- iteration 1 (B, C-8 / P-7): the boss kill beat, then ONE "STAGE CLEAR" banner
	-- per squad (U) in place of the old toast stack
	local zone = c.storm and c.storm.zone
	K.bossBeat(c, "bossKill", card.bossId, {
		winnerSquad = winner,
		winnerBy = result.winnerBy,
		snatchSquad = result.snatch,
		fled = r == "timeout",
		x = if zone then zone.cx else nil,
		z = if zone then zone.cz else nil,
	})
	for _, p in memberList(c) do
		local s2 = c.members[p].squad
		Remotes.fx({
			{
				t = "stageClear",
				stage = match.stage,
				stages = MatchState.CONFIG.STAGES,
				bossId = card.bossId,
				winnerSquad = winner,
				winnerName = if winner then squadName(winner) else nil,
				youWon = winner == s2,
				stageCheese = result.stageCheese,
				brave = result.brave,
				chestCheese = if winner == s2 then result.chestCheese else 0,
				snatchCheese = if result.snatch == s2 then result.snatchCheese else 0,
				securedFrac = MatchState.CONFIG.SECURED_FRAC,
				epic = winner == s2 and result.epic or nil,
				donPaid = result.potBonus[s2],
				donLost = if result.potLost then result.potLost[s2] else nil,
				blessingId = if table.find(result.blessed or {}, s2) then result.blessingId else nil,
				blessingName = if table.find(result.blessed or {}, s2) and result.blessingId
					then defName(Modifiers, result.blessingId)
					else nil,
				wheyStage = RunWallet.Shop.WHEY.stage,
			},
		}, p)
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
	if match:isFinalGate() then
		-- iter 5 #6: the final Rind Gate: Extract or Overtime
		K.openPortal(c, center)
		runExtraction(c)
		if c.aborted then
			return "abort"
		end
		if match.phase == "Overtime" then
			return K.playOvertime(c)
		end
		return "results"
	end

	-- Route choice by the winner, through the open Rind Gate.
	K.openPortal(c, center)
	local idx = runRouteChoice(c, winner)
	if c.aborted then
		return "abort"
	end
	if match.phase == "Results" then
		return "results" -- every squad was eliminated during the route choice
	end
	local nextCard = match:chooseRoute(idx, winner)
	if type(nextCard) == "table" and nextCard.tier ~= "High" then
		for _, p in memberList(c) do
			K.flagsOf(c, p.UserId).routesAllHigh = false -- High Roller
		end
	end
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

-- Overtime (iter 5 #6) ------------------------------------------------------------------------------

-- S2C Overtime {active, wave, best, endsAt?} to every run member (best = this
-- player's saved best Overtime wave on this tier, for the HUD).
K.sendOvertime = function(c: Ctx, active: boolean)
	local wave = c.match:overtimeWave() or 0
	for _, p in memberList(c) do
		local pr = c.members[p]
		local best = 0
		local profile = getProfile(p)
		local tier = K.runTier(c)
		local st = profile and (profile :: any).stats
		if tier and type(st) == "table" and type(st.overtimeBest) == "table" then
			best = tonumber(st.overtimeBest[tostring(tier)]) or 0
		end
		pcall(Remotes.fireTo, p, Net.S2C.Overtime, {
			active = active and not pr.out,
			wave = wave,
			best = best,
			endsAt = if active then c.phaseEndsAt else nil,
		})
	end
end

-- The effective ladder tier of this run (nil = no ladder).
K.runTier = function(c: Ctx): number?
	if c.tier == nil then
		return nil
	end
	local ok, t = pcall(function()
		return K.Difficulty.effective(c.tier, c.match.run:pressureBoard())
	end)
	return if ok and type(t) == "number" then t else nil
end

-- A human's squad leaves Overtime through the gate (ExtractVote "Extract").
-- Is this hero standing in the World (not downed, not dead)?
K.isStanding = function(c: Ctx, id: number): boolean
	local world = c.world
	if not world then
		return false
	end
	local ok, info = pcall(world.getPlayer, world, id)
	return ok and type(info) == "table" and not info.downed and not info.dead
end

-- A human votes to leave Overtime (ExtractVote "Extract", any time in Overtime).
-- A fallen squad is eliminated first; only a standing human's vote counts, and the
-- squad extracts once a majority of its STANDING humans voted (a solo human = 1/1).
K.voteOvertimeExtract = function(c: Ctx, pr: PlayerRun)
	eliminateFallen(c)
	if pr.out or c.match.phase ~= "Overtime" or not c.match:isSquadInRun(pr.squad) then
		return
	end
	if not K.isStanding(c, pr.userId) then
		Remotes.toast(pr.player, "You can't extract while down.", "bad")
		return
	end
	c.otVotes = c.otVotes or {}
	local votes = c.otVotes[pr.squad] or {}
	c.otVotes[pr.squad] = votes
	votes[pr.userId] = true
	local standing, yes = 0, 0
	for _, p in squadHumans(c, pr.squad) do
		local id = p.UserId
		if K.isStanding(c, id) then
			standing += 1
			if votes[id] then
				yes += 1
			end
		end
	end
	if yes * 2 > standing then
		c.otVotes[pr.squad] = nil
		K.extractOvertime(c, pr.squad)
	else
		toastSquad(c, pr.squad, string.format("%s votes to extract (%d/%d).", pr.name, yes, standing), "info")
	end
end

-- An Overtime squad leaves through the gate (keeps its share and the wave bonus).
K.extractOvertime = function(c: Ctx, squad: number)
	local out = c.match:extractOvertime(squad)
	if #out == 0 then
		return
	end
	killFeed(c, { killerSquad = squad, kind = "extracted" })
	toastAll(
		c,
		string.format(
			"%s extracted after %d Overtime wave(s)!",
			squadName(squad),
			c.match:overtimeWave() or 0
		),
		"info"
	)
	handleOut(c, out, true)
	K.sendOvertime(c, c.match.phase == "Overtime")
end

-- Per hero {dmg, kills} from the World's meter and the mice tally (anti-farming).
K.overtimeSnap = function(c: Ctx): { [number]: { dmg: number, kills: number, mice: number } }
	local out = {}
	local meter = nil
	if c.world and type(c.world.meter) == "function" then
		local ok, m = pcall(c.world.meter, c.world)
		meter = if ok and type(m) == "table" then m else nil
	end
	for id in c.heroes do
		local e = meter and meter[id]
		out[id] = {
			dmg = if type(e) == "table" and finite(e.dmg) then e.dmg else 0,
			kills = if type(e) == "table" and finite(e.kills) then e.kills else 0,
			mice = (c.tally[id] or {}).mice or 0,
		}
	end
	return out
end

-- Every squad still in Overtime extracts (hard stop, or no World).
K.extractAllOvertime = function(c: Ctx)
	for _, s in c.match:squadsInRun() do
		K.extractOvertime(c, s)
	end
	if c.match.phase == "Overtime" then
		handleOut(c, c.match:finish("final"), false) -- nothing left in it: a safety net
	end
end

-- Endless waves on the final stage's World, mice x overtimeMult(wave), one wave every
-- OVERTIME_WAVE_SECONDS, until every Overtime squad extracted or wiped (or the hard
-- stop at OVERTIME_MAX_WAVES). Returns "results" | "abort".
K.playOvertime = function(c: Ctx): string
	local match = c.match
	local world = c.world
	if not world then
		K.extractAllOvertime(c)
		return "results"
	end
	local baseMods = match:worldMods()
	c.otVotes = {}
	c.downSince = {}
	toastAll(c, "OVERTIME! Survive as long as you can; extract any time at the gate.", "bad")
	while match.phase == "Overtime" do
		local wave = (match:overtimeWave() or 0) + 1
		local mult = MatchState.overtimeMult(wave)
		local mods = if type(baseMods) == "table" then table.clone(baseMods) else {}
		for _, key in { "enemyHpMult", "enemyDamageMult", "bossHpMult", "bossDamageMult" } do
			mods[key] = (if finite(mods[key]) then mods[key] else 1) * mult
		end
		pcall(world.setMods, world, mods)
		pcall(world.startWaves, world, RunDirector.OVERTIME_WAVE_SECONDS)
		if type(world.startWave) == "function" then
			-- horde waves (stage waves 1-4) on the final stage's numbering
			local sw = (wave - 1) % 4 + 1
			pcall(world.startWave, world, K.Waves.index(match.stage, sw), { stageWave = sw })
		end
		-- anti-farming: what each hero has dealt / killed so far (World meter, mice tally)
		local snap = K.overtimeSnap(c)
		local deadline = setPhaseTimer(c, RunDirector.OVERTIME_WAVE_SECONDS)
		broadcastRunState(c)
		K.sendOvertime(c, true)
		local r = waitFor(c, deadline, function()
			if stageOver(c) then
				return true
			end
			return match.phase ~= "Overtime"
		end)
		if r == "abort" then
			return "abort"
		elseif r == "fatal" then
			handleOut(c, match:finish("crash"), false)
			break
		end
		if match.phase ~= "Overtime" then
			break
		end
		eliminateFallen(c) -- nobody standing at the wave's end: the squad is out
		if match.phase ~= "Overtime" then
			break
		end
		local now = K.overtimeSnap(c)
		local res = match:overtimeWaveCleared(function(id: number): boolean
			-- a human is paid only for a wave they played (damage or a kill)
			if not memberById(c, id) then
				return true
			end
			local a, b = snap[id], now[id]
			return a ~= nil and b ~= nil and (b.dmg > a.dmg or b.kills > a.kills or b.mice > a.mice)
		end)
		for _, s in match:squadsInRun() do
			toastSquad(
				c,
				s,
				string.format(
					"Overtime wave %d survived! +%d cheese each. Mice grow stronger.",
					res.wave,
					res.cheese
				),
				"good"
			)
		end
		sendMatch(c, true)
		if res.wave >= MatchState.CONFIG.OVERTIME_MAX_WAVES then
			K.extractAllOvertime(c) -- the hard stop (Last Herd kept)
			break
		end
	end
	pcall(world.stopSpawning, world)
	pcall(world.clearEnemies, world)
	K.sendOvertime(c, false)
	return "results"
end

-- Teardown -----------------------------------------------------------------------------------------

local function teardown(c: Ctx)
	c.finished = true
	stopCombat(c)
	pcall(ArenaBuilder.clear)
	K.applyLighting("lobby")
	local players = {}
	for _, p in connectedMembers(c) do
		setHumanoidSpeed(p, K.DEFAULT_WALKSPEED)
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
	for _, p in c.joinQueue do
		pcall(p.SetAttribute, p, "PracticeYard", nil)
	end
	for _, p in connectedMembers(c) do
		pcall(p.SetAttribute, p, "DoubleOrNothing", nil)
	end
	for _, p in connectedMembers(c) do
		K.outPlayers[p] = nil -- QC MAJOR 2: back in the lobby
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
	-- v4 Herd Awards: MVP and accolades for the whole match
	for _, p in connectedMembers(c) do
		K.outPlayers[p] = true
	end
	pcall(K.sendAwards, c, connectedMembers(c), true)
	waitFor(c, deadline, function()
		return #connectedMembers(c) == 0
	end)
end

local function runLoop(c: Ctx)
	local first = c.match:begin()
	c.card = first
	-- The match is live from here: run members get its RunState (Pressure, stage 1
	-- card) at once, before the arena builds.
	broadcastRunState(c)
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

-- A human's run record (start, or a late joiner taking a bot's seat). Reads the
-- class loadout and the Rookie Run state from the profile.
K.newPlayerRun = function(c: Ctx, p: Player, classId: string, squad: number, slot: number): PlayerRun
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
		joinedClock = os.clock(), -- iter 5 #8: time played (lifetime stats)
		isBot = false,
		name = p.DisplayName,
		squad = squad,
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
		offerRng = c.rng:fork(100 + slot),
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
	-- v4 Rookie Run: the player's runs 0..2 (profile.stats.runs, read only)
	local runs = if type(profile) == "table" and type(profile.stats) == "table"
		then profile.stats.runs
		else nil
	local rookie = finite(runs) and runs < K.ROOKIE_RUNS
	if DataService and type(DataService.isRookie) == "function" then
		local ok, r = pcall(DataService.isRookie, p)
		rookie = ok and r == true
	end
	if rookie and isHuman(p) then
		pr.rookieRuns = if finite(runs) then math.max(0, math.floor(runs)) else 0
		pr.hideDoN = true
		c.match:setRookie(pr.userId, true)
	end
	pr.seen = { maps = {}, bosses = {}, champions = {}, mice = {}, gear = {} }
	pr.questBuf = {}
	c.members[p] = pr
	c.heroes[pr.userId] = pr
	K.outPlayers[p] = nil
	pcall(function()
		p:SetAttribute("Squad", pr.squad) -- 1..4 (HeroDecor / CosmeticsService / client)
		p:SetAttribute("ClassId", classId)
		p:SetAttribute("Rookie", if pr.rookieRuns ~= nil then true else nil)
		p:SetAttribute("PracticeYard", nil)
	end)
	return pr
end

-- LobbyService.onStart(players, classes, bots, pressure, squads).
local function startRun(
	players: { Player },
	classes: { [number]: string },
	botSpecs: { any }?,
	pressure: { [string]: number }?,
	squads: any?,
	ladder: any? -- iteration 2: {tier, skipWaveAt, leaderId} (LobbyService)
)
	if ctx then
		warn("[RunDirector] start requested while a run is active; ignored")
		return
	end
	K.revivePingAt = {} -- iteration 7 (team Systems, QC minor 5): bot ids are reused across runs
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
	local runOpts: { [string]: any } = {
		bossIds = Bosses.ORDER,
		mapIds = Maps.ORDER,
		botWeight = RunDirector.BOT_WEIGHT,
		overtime = RunDirector.OVERTIME, -- iter 5 #6: a final gate with Overtime
	}
	if type(pressure) == "table" then
		runOpts.pressure = pressure -- RunState sanitizes it
	end
	if type(ladder) == "table" and type(ladder.tier) == "number" then
		runOpts.difficulty = ladder.tier -- a preset board (Custom = the leader's)
	end
	-- iteration 6 (team Flow): the leader's pace (Fast spawns x1.35 via RunState.worldMods)
	runOpts.pace = K.Pace.clamp(if type(ladder) == "table" then ladder.pace else nil)
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
		storm = nil,
		waveEndsAt = nil,
		tally = {},
		joinQueue = {},
		firstChampDone = false,
		nextBotN = 0,
		wallets = {},
		walletDirty = {},
		-- a World with v5 drops (team M1) sends `rinds` / `whey` events itself
		worldRinds = type(World._grantRinds) == "function",
		shops = nil,
		tier = if type(ladder) == "table" then ladder.tier else nil,
		skipWaveAt = if type(ladder) == "table" and type(ladder.skipWaveAt) == "number"
			then ladder.skipWaveAt
			else 0,
		pace = K.Pace.clamp(if type(ladder) == "table" then ladder.pace else nil),
		waves = nil,
		waveFx = nil,
		flags = {},
		knockedOut = {},
		squadChampKills = {},
		squadStandingAtExtract = {},
		solo = #Players:GetPlayers() == 1,
		oneHit = false,
		gemRng = rng:fork(7),
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
		K.newPlayerRun(c, p, classes[p.UserId] or LobbyService.getClass(p), seatOf[p.UserId], slot)
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
	K.outPlayers[player] = nil
	K.teleporting[player] = nil
	K.pingLog[player] = nil
	K.aimModes[player] = nil
	K.invites[player] = nil
	local c = ctx
	local qi = if c then table.find(c.joinQueue, player) else nil
	if c and qi then
		table.remove(c.joinQueue, qi)
	end
	if not c or not c.members[player] then
		return
	end
	local pr = c.members[player]
	-- QC-B V2-m1 combat log: leaving while downed, or right after an enemy hero
	-- hit you, pays only what elimination would (the enemy still gets the bag).
	local combat: { by: number? }? = nil
	local world = c.world
	local info = if world and not pr.out then world:getPlayer(pr.userId) else nil
	if info and not info.dead then
		local recent = info.lastHitBy ~= nil
			and finite(info.lastHitAt)
			and (world :: any).now - info.lastHitAt <= (World.ASSIST_WINDOW or 5)
		if info.downed or recent then
			combat = { by = info.lastHitBy } -- heroKilled credits it only if it is an enemy
		end
	end
	local bx, bz = heroPos(c, pr.userId)
	local kill: any = nil
	if not pr.awarded then
		-- The leaver rule (keep half the share, nothing on DoN; the elimination
		-- rate for a combat log); paid from beforeRelease.
		local ok, po, kr = pcall(c.match.removeMember, c.match, pr.userId, combat)
		pr.leavePayout = if ok then po else nil
		kill = if ok then kr else nil
		departed[player] = { c = c, pr = pr }
		task.delay(120, function()
			departed[player] = nil
		end)
	else
		pcall(c.match.removeMember, c.match, pr.userId)
	end
	c.members[player] = nil
	pr.out = true
	removeFromWorld(c, pr.userId) -- the World drops the gear bag here
	if kill then
		-- the 30% cheese joins the gear bag at the same spot (World merges them)
		dropBag(c, kill.victim, kill.bagCheese, kill.bagKey, nil, bx, bz)
		killFeed(c, {
			killer = kill.killer,
			victim = kill.victim,
			killerSquad = kill.killerSquad,
			victimSquad = kill.victimSquad,
			kind = "kill",
		})
		announceBounty(c, kill.bounty)
		if kill.newBounty then
			killFeed(c, { killer = kill.newBounty, killerSquad = kill.killerSquad, kind = "bounty" })
		end
	end
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
	local acc2: number? = 0
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
			acc2 = (acc2 or 0) + dt
			if acc2 >= 3 then
				acc2 = 0
				for _, p in connectedMembers(c) do
					pcall(K.flushQuests, c, c.members[p])
				end
			end
			for id in c.walletDirty do
				c.walletDirty[id] = nil
				local wpr = memberById(c, id)
				if wpr then
					pcall(K.sendWallet, c, wpr)
				end
			end
			for _, p in memberList(c) do
				local hpr = c.members[p]
				-- iteration 1: keep a dead player's spectate target on a standing squadmate
				if hpr.spectating and (not K.standingMate(c, hpr.userId) or isDowned(c, hpr.spectating)) then
					pcall(K.sendRedeploy, c, hpr.userId)
				end
				pcall(K.noteEngaged, c, c.members[p], dt)
				local ok, err = pcall(sendHud, c, c.members[p])
				if not ok then
					warn("[RunDirector] hud: " .. tostring(err))
				end
			end
			-- iteration 5 #1: the damage meter, ~1 Hz
			local cm = c :: any
			cm.meterAcc = (cm.meterAcc or 0) + dt
			if cm.meterAcc >= RunDirector.METER_INTERVAL then
				cm.meterAcc = 0
				pcall(K.sendMeter, c)
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
K.payLeaver = function(player: Player)
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

	-- QC-A minor 6: lobby players (e.g. extracted ones) see when this match ends
	if type(LobbyService.setRunInfoProvider) == "function" then
		LobbyService.setRunInfoProvider(function(): any
			local c = ctx
			return if c and not c.finished then RunDirector.estimateEnd(c) else nil
		end)
	end
	-- QC-B V2-M1: no Second Wind purchase prompts while the player is in a run
	if MonetizationService and type(MonetizationService.setRunMemberCheck) == "function" then
		MonetizationService.setRunMemberCheck(function(player: Player): boolean
			local c = ctx
			local pr = c and c.members[player]
			return pr ~= nil and not pr.out
		end)
	end

	Guard.connect(Net.C2S.Vote, { rate = 4, burst = 6, args = { Guard.T.int(1, 16) } }, K.onVote)
	Guard.connect(
		Net.C2S.ChooseUpgrade,
		{ rate = 4, burst = 6, args = { Guard.T.int(1, 2 ^ 31), Guard.T.int(1, 16) } },
		K.onChooseUpgrade
	)
	Guard.connect(
		Net.C2S.RerollUpgrade,
		{ rate = 2, burst = 3, args = { Guard.T.int(1, 2 ^ 31) } },
		K.onRerollUpgrade
	)
	Guard.connect(Net.C2S.UseAbility, {
		rate = 16, -- iteration 5/6: 4 slots share this bucket (each slot also has its own)
		burst = 16,
		args = {
			Guard.T.number(-K.AIM_LIMIT, K.AIM_LIMIT),
			Guard.T.number(-K.AIM_LIMIT, K.AIM_LIMIT),
			Guard.T.optional(Guard.T.int(1, 4)), -- iteration 5: slot (nil = 1); iteration 6: 1-4
		},
	}, K.onUseAbility)
	Guard.connect(Net.C2S.UseSecondWind, { rate = 2, burst = 2, args = {} }, K.onUseSecondWind)
	-- v2 remotes (R3 owns SelectPerk / ResetPerks / SelectAbility / SelectSkin)
	Guard.connect(
		Net.C2S.ExtractVote,
		{ rate = 4, burst = 6, args = { Guard.T.enum(CHOICES) } },
		K.onExtractVote
	)
	Guard.connect(Net.C2S.SwapGear, { rate = 4, burst = 4, args = { Guard.T.boolean() } }, K.onSwapGear)
	Guard.connect(
		Net.C2S.BuyCartItem,
		{ rate = 3, burst = 4, args = { Guard.T.int(-2 ^ 31, 2 ^ 31), Guard.T.int(1, 8) } },
		K.onBuyCartItem
	)
	-- v4 (team M2): pings, quick-chat, Play Again
	Guard.connect(Net.C2S.Ping, {
		rate = 1 / 1.2,
		burst = 3,
		args = {
			Guard.T.enum(K.PING_KINDS),
			Guard.T.number(-K.AIM_LIMIT, K.AIM_LIMIT),
			Guard.T.number(-K.AIM_LIMIT, K.AIM_LIMIT),
		},
	}, K.onPing)
	Guard.connect(
		Net.C2S.QuickChat,
		{ rate = 1, burst = 3, args = { Guard.T.int(1, #K.QUICK_CHAT) } },
		K.onQuickChat
	)
	Guard.connect(Net.C2S.PlayAgain, { rate = 0.2, burst = 2, args = {} }, K.onPlayAgain)
	-- iteration 4: the auto-attack aim toggle (team U sends; World.setAim from M1)
	if Net.C2S.SetAimMode then
		Guard.connect(
			Net.C2S.SetAimMode,
			{ rate = 2, burst = 4, args = { Guard.T.enum(K.AIM_MODES) } },
			K.onSetAimMode
		)
	end
	if Net.C2S.AimAt then
		Guard.connect(Net.C2S.AimAt, {
			rate = 15,
			burst = 20,
			args = { Guard.T.number(-K.AIM_LIMIT, K.AIM_LIMIT), Guard.T.number(-K.AIM_LIMIT, K.AIM_LIMIT) },
		}, K.onAimAt)
	end
	-- iteration 2 (remotes the lead adds to Net)
	if Net.C2S.GiftRinds then
		Guard.connect(
			Net.C2S.GiftRinds,
			{ rate = 2, burst = 4, args = { Guard.T.int(-2 ^ 31, 2 ^ 31) } },
			K.onGiftRinds
		)
	end
	if Net.C2S.CallHorn then
		Guard.connect(Net.C2S.CallHorn, { rate = 0.5, burst = 1, args = {} }, K.onEarlyHorn)
	end
	-- v5 run economy (docs/V5-PLAN.md §A)
	if Net.C2S.BuyRank then
		Guard.connect(Net.C2S.BuyRank, { rate = 8, burst = 12, args = { Guard.T.string(16) } }, K.onBuyRank)
		Guard.connect(
			Net.C2S.BuyStallBuff,
			{ rate = 2, burst = 4, args = { Guard.T.string(16), Guard.T.string(16) } },
			K.onBuyStallBuff
		)
		Guard.connect(
			Net.C2S.BuyUltimate,
			{ rate = 1, burst = 2, args = { Guard.T.string(16) } },
			K.onBuyUltimate
		)
		Guard.connect(
			Net.C2S.Swap,
			{ rate = 2, burst = 4, args = { Guard.T.enum({ "toWhey", "toRinds" }), Guard.T.int(1, 1000000) } },
			K.onSwap
		)
	end
	if type(LobbyService.setLateJoinHandler) == "function" then
		LobbyService.setLateJoinHandler(K.onLateJoin)
	end

	connectCombatEvents()
	if DataService and type(DataService.beforeRelease) == "function" then
		local ok, err = pcall(DataService.beforeRelease, K.payLeaver)
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

-- Test hook: does the live match still count as solo (Best Solo, solo challenges)?
function RunDirector.isSoloRun(): boolean?
	local c = ctx
	return if c then K.isSolo(c) else nil
end

-- Test hook: the live MatchState (nil between matches). Specs only.
function RunDirector.getMatchState(): any
	local c = ctx
	return if c then c.match else nil
end

-- Read-only debug / test view of the match (MatchState:getPublic, no viewer).
function RunDirector.getMatchView(): { [string]: any }?
	local c = ctx
	return if c then c.match:getPublic(nil, aliveOf(c)) else nil
end

return RunDirector
