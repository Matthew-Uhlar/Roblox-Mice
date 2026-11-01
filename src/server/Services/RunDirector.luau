--!strict
-- RunDirector: owns the run loop (ARCHITECTURE.md "Team E", GDD §3).
--
--   lobby start -> RunState.new -> [ route vote -> arena build -> waves (150 s)
--   -> boss -> blessing + rewards -> bank/cycle vote ]* -> Results -> lobby
--
-- It bridges the pure RunState (Team A) and the combat World (Team B), and
-- owns per-player run data: level, xp, upgrade stacks, pending offers,
-- rerolls and second winds. All client intents arrive through Guard.connect
-- and are checked against the current phase and the offers we actually made.
--
-- Bots (Team F, GDD §3.6): party-fill bots are world participants with
-- negative ids and no Player. They get class stats (no talents), auto-pick the
-- highest-rarity upgrade on level-up, vote 1-4 s after a vote opens (following
-- the human plurality), appear in PartyHud with isBot = true, count toward the
-- wipe check (World.allPlayersDown), count 0.6 for difficulty, and never earn
-- rewards or touch Data/Monetization services. The run ends when every HUMAN
-- has left. BotService moves them.
--
-- Second Wind and reroll-token accounting use Data/RunTokens (Team D).
--
-- Clocks: os.clock() for local deadlines; workspace:GetServerTimeNow() for
-- every timestamp sent to clients (phaseEndsAt, vote endsAt) and as the `now`
-- passed to world:useAbility (unless CombatService.now() exists).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Rng = require(Shared:WaitForChild("Util"):WaitForChild("Rng")) :: any

local RunFolder = Shared:WaitForChild("Run")
local ConfigFolder = Shared:WaitForChild("Config")
local CombatFolder = Shared:WaitForChild("Combat")

-- Team A
local RunState = require(RunFolder:WaitForChild("RunState")) :: any
local Vote = require(RunFolder:WaitForChild("Vote")) :: any
local Stats = require(RunFolder:WaitForChild("Stats")) :: any
local Leveling = require(RunFolder:WaitForChild("Leveling")) :: any
local UpgradeOffers = require(RunFolder:WaitForChild("UpgradeOffers")) :: any
local Maps = require(ConfigFolder:WaitForChild("Maps")) :: any
-- Team B
local Bosses = require(ConfigFolder:WaitForChild("Bosses")) :: any
local World = require(CombatFolder:WaitForChild("World")) :: any
local CombatService = require(script.Parent:WaitForChild("CombatService")) :: any
local ArenaBuilder = require(script.Parent:WaitForChild("ArenaBuilder")) :: any
-- Team E
local Guard = require(script.Parent.Guard)
local Remotes = require(script.Parent.Remotes)
local LobbyService = require(script.Parent.LobbyService)
-- Team F
local BotBrain = require(Shared:WaitForChild("Bots"):WaitForChild("BotBrain")) :: any
-- Team D (pure)
local RunTokens = require(Shared:WaitForChild("Data"):WaitForChild("RunTokens")) :: any

local function optionalRequire(parent: Instance, name: string): any
	local inst = parent:FindFirstChild(name)
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
local TalentDefs: any = optionalRequire(ConfigFolder, "Talents")
local DataService: any = optionalRequire(script.Parent, "DataService")
local MonetizationService: any = optionalRequire(script.Parent, "MonetizationService")
local BotService: any = optionalRequire(script.Parent, "BotService")

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
RunDirector.VOTE_SECONDS = 15
RunDirector.STAGE_CLEAR_SECONDS = 4
RunDirector.RESULTS_SECONDS = 8
RunDirector.WIPE_GRACE = 1.5 -- everyone down this long -> wipe (lets Second Wind land)
RunDirector.BOSS_FALLBACK_DELAY = 6 -- after this, "no boss alive" also counts as a kill
RunDirector.FREE_REROLLS_PER_STAGE = 1
RunDirector.OFFER_CARDS = 3
RunDirector.HUD_INTERVAL = 0.2 -- 5 Hz
RunDirector.HUD_KEEPALIVE = 1.0
RunDirector.PARTY_INTERVAL = 0.5
RunDirector.RESPAWN_HP_FRAC = 0.5
RunDirector.WIPE_GRACE_SECOND_WIND = 5 -- a downed human who can still Second Wind gets this long
-- A bot counts as 0.6 of a player for difficulty (GDD §3.6); same constant as World.
RunDirector.BOT_WEIGHT = if type(World.BOT_WEIGHT) == "number" then World.BOT_WEIGHT else 0.6
RunDirector.BOT_VOTE_MIN = 1 -- bots vote this many seconds after a vote opens...
RunDirector.BOT_VOTE_MAX = 4 -- ...up to this many
local DEFAULT_WALKSPEED = 16
local AIM_LIMIT = 100000

-- Types ------------------------------------------------------------------------------

type Offer = { offerId: number, cards: { any } }

type PlayerRun = {
	player: Player,
	userId: number,
	slot: number,
	classId: string,
	level: number,
	xp: number,
	stacks: { [string]: number },
	stats: any,
	weapon: any,
	ability: any,
	pendingLevels: number,
	offer: Offer?,
	offerRng: any,
	freeRerollsLeft: number,
	tokens: any, -- RunTokens.State (Second Wind / reroll-token accounting)
	usedSecondWindToken: boolean, -- paid revive used -> run is unranked (Award.ranked)
	awarded: boolean, -- rewards paid (finishRun, or the leave-time payout)
	lastHud: { [string]: any }?,
	lastHudAt: number,
}

-- A party-fill bot: no Player, negative id, no rewards.
type BotRun = {
	id: number,
	name: string,
	slot: number,
	classId: string,
	level: number,
	xp: number,
	stacks: { [string]: number },
	stats: any,
	weapon: any,
	ability: any,
	offerRng: any,
}

type Ctx = {
	seed: number,
	run: any,
	rng: any,
	voteRng: any,
	members: { [Player]: PlayerRun },
	order: { Player },
	bots: { BotRun },
	botRng: any,
	world: any?,
	arena: any?,
	card: any?,
	phaseEndsAt: number?,
	vote: any?,
	votePhase: string?,
	voteCount: number,
	voted: { [number]: boolean },
	voteKind: string?,
	voteOptions: { any }?,
	voteToken: number,
	humanVotes: { [number]: number }, -- userId -> option (bots follow these)
	botVoted: { [number]: boolean },
	bossDead: boolean,
	bossSpawnedAt: number,
	downSince: number?,
	bossesKilled: number,
	startedAt: number,
	cycle1Time: number?,
	stageIndex: number,
	nextOfferId: number,
	aborted: boolean,
	finished: boolean,
	awarded: boolean,
	lastPartyAt: number,
	lastParty: string?,
}

local ctx: Ctx? = nil
-- Humans who left mid-run, kept until DataService's beforeRelease pays them.
local departed: { [Player]: { c: Ctx, pr: PlayerRun } } = {}

-- Helpers ----------------------------------------------------------------------------

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

-- Tolerant config lookup: Config[id], Config.BY_ID[id], or a list of defs.
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
	for _, d in config do
		if type(d) == "table" and d.id == id then
			return d
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

-- Only real Player objects reach Data/Monetization services. Bots have no
-- Player (negative ids), so every call below is skipped for them.
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
		if ok and Guard.isFiniteNumber(m) and m > 0 then
			return m
		end
	end
	return 1
end

-- Account XP multiplier (e.g. the 2x XP pass).
local function xpMult(player: Player): number
	if isHuman(player) and MonetizationService and type(MonetizationService.xpMult) == "function" then
		local ok, m = pcall(MonetizationService.xpMult, player)
		if ok and Guard.isFiniteNumber(m) and m > 0 then
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

local function memberList(c: Ctx): { Player }
	local list = {}
	for _, p in c.order do
		if c.members[p] and p.Parent == Players then
			table.insert(list, p)
		end
	end
	return list
end

local function phaseOf(c: Ctx): string
	local ok, phase = pcall(function()
		return c.run.phase or c.run:getPublic().phase
	end)
	return if ok and type(phase) == "string" then phase else "Lobby"
end

-- Difficulty party size: humans + 0.6 x bots, rounded UP (RunState floors to an integer).
local function difficultyCount(c: Ctx): number
	local n = #memberList(c) + RunDirector.BOT_WEIGHT * #c.bots
	return math.max(1, math.ceil(n - 1e-9))
end

local function botById(c: Ctx, id: any): BotRun?
	if type(id) ~= "number" then
		return nil
	end
	for _, b in c.bots do
		if b.id == id then
			return b
		end
	end
	return nil
end

local function stageKey(c: Ctx): string
	return "s" .. tostring(c.stageIndex)
end

local NO_PROFILE = table.freeze({ secondWindTokens = 0, rerollTokens = 0 })

-- Profile (or a zero-token stand-in) for RunTokens queries.
local function tokenProfile(player: Player): any
	local profile = getProfile(player)
	if type(profile) == "table" then
		return {
			secondWindTokens = if Guard.isFiniteNumber(profile.secondWindTokens)
				then profile.secondWindTokens
				else 0,
			rerollTokens = if Guard.isFiniteNumber(profile.rerollTokens) then profile.rerollTokens else 0,
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

-- CombatService writes WalkSpeed every frame while a world runs (x0.3 downed,
-- x0.6 slowed, 0 spectator), so we only set it outside combat.
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

local function publicState(c: Ctx): { [string]: any }
	local pub = table.clone(c.run:getPublic())
	pub.phaseEndsAt = c.phaseEndsAt
	return pub
end

local function broadcastRunState(c: Ctx)
	Remotes.runState(publicState(c))
end

-- Sets the phase timer; returns the os.clock() deadline (nil = untimed).
local function setPhaseTimer(c: Ctx, seconds: number?): number?
	if seconds then
		c.phaseEndsAt = serverNow() + seconds
	else
		c.phaseEndsAt = nil
	end
	c.run.phaseEndsAt = c.phaseEndsAt -- RunState copies it into getPublic()
	return if seconds then os.clock() + seconds else nil
end

-- Waits until deadline/predicate/abort. Returns "timeout" | "pred" | "abort".
local function waitFor(c: Ctx, deadline: number?, pred: (() -> boolean)?): string
	while true do
		if c.aborted then
			return "abort"
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

-- Forward-declared: true if a downed human could still use a Second Wind now.
local anyHumanCanSecondWind: (c: Ctx) -> boolean

-- Everyone down (humans AND bots: World.allPlayersDown) for WIPE_GRACE -> wipe.
-- If a downed human still has a usable Second Wind, wait WIPE_GRACE_SECOND_WIND
-- (solo with bots: the button needs time to be pressed).
local function wipeCheck(c: Ctx): boolean
	local world = c.world
	if not world then
		return false
	end
	local ok, down = pcall(world.allPlayersDown, world)
	if ok and down then
		c.downSince = c.downSince or os.clock()
		local okW, canWind = pcall(anyHumanCanSecondWind, c)
		local grace = if okW and canWind then RunDirector.WIPE_GRACE_SECOND_WIND else RunDirector.WIPE_GRACE
		return os.clock() - (c.downSince :: number) >= grace
	end
	c.downSince = nil
	return false
end

-- Stats + upgrades -----------------------------------------------------------------------

local function computeStats(c: Ctx, pr: PlayerRun)
	local profile = getProfile(pr.player)
	local talents = if profile and type(profile.talents) == "table" then profile.talents else {}
	local stats, weapon, ability =
		Stats.compute(pr.classId, pr.stacks, c.run:activeBlessings(), talents, talentDefTable)
	pr.stats, pr.weapon, pr.ability = stats, weapon, ability
end

-- Bots: class + upgrades + blessings, no talents.
local function computeBotStats(c: Ctx, b: BotRun)
	local stats, weapon, ability =
		Stats.compute(b.classId, b.stacks, c.run:activeBlessings(), {}, talentDefTable)
	b.stats, b.weapon, b.ability = stats, weapon, ability
end

local function isDowned(c: Ctx, pr: PlayerRun): boolean
	local world = c.world
	if not world then
		return false
	end
	local info = world:getPlayer(pr.userId)
	return info ~= nil and (info.downed or info.dead)
end

local function pushStats(c: Ctx, pr: PlayerRun)
	local world = c.world
	if world then
		world:updatePlayer(pr.userId, pr.stats, pr.weapon)
	end
	if not isDowned(c, pr) and pr.stats and Guard.isFiniteNumber(pr.stats.moveSpeed) then
		setHumanoidSpeed(pr.player, pr.stats.moveSpeed)
	end
end

-- Free rerolls this stage + reroll tokens RunTokens allows this stage (max 2).
local function rerollsLeft(c: Ctx, pr: PlayerRun): number
	local ok, n = pcall(RunTokens.rerollsAvailable, pr.tokens, tokenProfile(pr.player), stageKey(c))
	return pr.freeRerollsLeft + (if ok and Guard.isFiniteNumber(n) then n else 0)
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
		queued = pr.pendingLevels,
	})
end

local function rollOffer(c: Ctx, pr: PlayerRun)
	local luck = if pr.stats and Guard.isFiniteNumber(pr.stats.luck) then pr.stats.luck else 0
	local cards = UpgradeOffers.roll(pr.offerRng, pr.classId, pr.stacks, luck, RunDirector.OFFER_CARDS)
	if type(cards) ~= "table" or #cards == 0 then
		-- Nothing left to offer (everything maxed): drop the pending levels.
		pr.offer = nil
		pr.pendingLevels = 0
		return
	end
	c.nextOfferId += 1
	pr.offer = { offerId = c.nextOfferId, cards = cards }
	sendOffer(c, pr)
end

-- Shows the next queued level-up if nothing is on screen.
local function presentNextOffer(c: Ctx, pr: PlayerRun)
	if pr.offer or pr.pendingLevels <= 0 then
		return
	end
	pr.pendingLevels -= 1
	rollOffer(c, pr)
end

local function grantXp(c: Ctx, pr: PlayerRun, amount: number)
	if not Guard.isFiniteNumber(amount) or amount <= 0 then
		return
	end
	local newLevel, newXp, gained = Leveling.addXp(pr.level, pr.xp, amount)
	pr.level, pr.xp = newLevel, newXp
	if gained and gained > 0 then
		local hadOffer = pr.offer ~= nil
		pr.pendingLevels += gained
		Remotes.toast(pr.player, string.format("Level %d!", newLevel), "good")
		if hadOffer then
			sendOffer(c, pr) -- same offer, refreshed queued count
		else
			presentNextOffer(c, pr)
		end
	end
end

-- Bots pick the highest-rarity card at once (BotBrain.chooseUpgrade).
local function botLevelUp(c: Ctx, b: BotRun)
	local luck = if b.stats and Guard.isFiniteNumber(b.stats.luck) then b.stats.luck else 0
	local cards = UpgradeOffers.roll(b.offerRng, b.classId, b.stacks, luck, RunDirector.OFFER_CARDS)
	if type(cards) ~= "table" or #cards == 0 then
		return
	end
	local idx = BotBrain.chooseUpgrade(cards, c.botRng)
	local card = cards[idx]
	if not card then
		return
	end
	b.stacks[card.id] = (b.stacks[card.id] or 0) + 1
	computeBotStats(c, b)
	local world = c.world
	if world then
		world:updatePlayer(b.id, b.stats, b.weapon)
		local heal = card.delta and card.delta.heal
		if Guard.isFiniteNumber(heal) and heal > 0 and type(world.healPlayer) == "function" then
			pcall(world.healPlayer, world, b.id, heal)
		end
	end
end

local function grantBotXp(c: Ctx, b: BotRun, amount: any)
	if not Guard.isFiniteNumber(amount) or amount <= 0 then
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
	return if ok and Guard.isFiniteNumber(n) then math.max(0, math.floor(n)) else 0
end

local function hudPayload(c: Ctx, pr: PlayerRun): Remotes.PlayerHudPayload
	local info = c.world and c.world:getPlayer(pr.userId)
	local maxHp = if pr.stats and Guard.isFiniteNumber(pr.stats.maxHp) then pr.stats.maxHp else 100
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
	local payload = hudPayload(c, pr)
	local now = os.clock()
	if force or not shallowEqual(pr.lastHud, payload) or now - pr.lastHudAt >= RunDirector.HUD_KEEPALIVE then
		pr.lastHud = payload
		pr.lastHudAt = now
		Remotes.playerHud(pr.player, payload)
	end
end

local function sendPartyHud(c: Ctx, force: boolean?)
	local payload: { [string]: any } = {}
	local sig = {}
	local function add(id: number, name: string, classId: string, stats: any, level: number, isBot: boolean)
		local info = c.world and c.world:getPlayer(id)
		local maxHp = if info then info.maxHp elseif stats then stats.maxHp else 100
		local entry = {
			name = name,
			classId = classId,
			hp = if info then math.floor(info.hp + 0.5) else maxHp,
			maxHp = maxHp,
			downed = if info then info.downed == true else false,
			dead = if info then info.dead == true else false,
			level = level,
			isBot = isBot,
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
	for _, p in memberList(c) do
		local pr = c.members[p]
		add(pr.userId, p.DisplayName, pr.classId, pr.stats, pr.level, false)
	end
	for _, b in c.bots do
		add(b.id, b.name, b.classId, b.stats, b.level, true)
	end
	local s = table.concat(sig, "|")
	local now = os.clock()
	if force or s ~= c.lastParty or now - c.lastPartyAt >= 2 then
		c.lastParty = s
		c.lastPartyAt = now
		Remotes.partyHud(payload)
	end
end

-- Combat events ------------------------------------------------------------------------------

local function memberById(c: Ctx, id: any): PlayerRun?
	if type(id) ~= "number" then
		return nil
	end
	for _, pr in c.members do
		if pr.userId == id then
			return pr
		end
	end
	return nil
end

local function handleWorldEvent(e: any)
	local c = ctx
	if not c or type(e) ~= "table" then
		return
	end
	local kind = e.type
	local bot = botById(c, e.id)
	if bot then
		if kind == "xp" then
			grantBotXp(c, bot, e.amount)
		elseif kind == "downed" then
			Remotes.toast(memberList(c), bot.name .. " is down! Stand close to revive.", "bad")
			sendPartyHud(c, true)
		elseif kind == "revived" then
			Remotes.toast(memberList(c), bot.name .. " is back up!", "good")
			sendPartyHud(c, true)
		elseif kind == "dead" then
			Remotes.toast(memberList(c), bot.name .. " is out until the stage ends.", "bad")
			sendPartyHud(c, true)
		end
		return
	end
	if kind == "xp" then
		local pr = memberById(c, e.id)
		if pr then
			grantXp(c, pr, e.amount)
			sendHud(c, pr)
		end
	elseif kind == "downed" then
		local pr = memberById(c, e.id)
		if pr then
			setHumanoidSpeed(
				pr.player,
				if pr.stats then pr.stats.moveSpeed * 0.3 else DEFAULT_WALKSPEED * 0.3
			)
			Remotes.toast(memberList(c), pr.player.DisplayName .. " is down! Stand close to revive.", "bad")
			sendHud(c, pr, true)
		end
		sendPartyHud(c, true)
	elseif kind == "revived" then
		local pr = memberById(c, e.id)
		if pr then
			if pr.stats then
				setHumanoidSpeed(pr.player, pr.stats.moveSpeed)
			end
			Remotes.toast(memberList(c), pr.player.DisplayName .. " is back up!", "good")
			sendHud(c, pr, true)
		end
		sendPartyHud(c, true)
	elseif kind == "dead" then
		local pr = memberById(c, e.id)
		if pr then
			setHumanoidSpeed(pr.player, 0)
			Remotes.toast(memberList(c), pr.player.DisplayName .. " is out until the stage ends.", "bad")
			sendHud(c, pr, true)
		end
		sendPartyHud(c, true)
	elseif kind == "damaged" then
		local pr = memberById(c, e.id)
		if pr then
			sendHud(c, pr)
		end
	elseif kind == "bossDead" then
		c.bossDead = true
	elseif kind == "bossPhase" then
		Remotes.toast(memberList(c), "The boss is enraged!", "bad")
	end
end

-- CombatService.events may fire one event or a list of drained events.
local function onCombatEvents(payload: any)
	if type(payload) ~= "table" then
		return
	end
	if payload.type ~= nil then
		handleWorldEvent(payload)
	else
		for _, e in payload do
			handleWorldEvent(e)
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

-- Votes ----------------------------------------------------------------------------------------

local function allMembersVoted(c: Ctx): boolean
	local list = memberList(c)
	if #list == 0 then
		return true
	end
	for _, p in list do
		if not c.voted[p.UserId] then
			return false
		end
	end
	return true
end

local function tallyArray(c: Ctx): { number }
	local counts = table.create(c.voteCount, 0)
	local vote = c.vote
	if vote then
		local t = vote:tally()
		for i = 1, c.voteCount do
			local n = t[i]
			counts[i] = if type(n) == "number" then n else 0
		end
	end
	return counts
end

-- Votes cast by humans so far, one count per option (bots follow these).
local function humanTally(c: Ctx): { number }
	local counts = table.create(c.voteCount, 0)
	for _, option in c.humanVotes do
		if counts[option] ~= nil then
			counts[option] += 1
		end
	end
	return counts
end

local function botCastVote(c: Ctx, b: BotRun): boolean
	local vote = c.vote
	if not vote or not c.voteKind or not c.voteOptions then
		return false
	end
	local ok, idx = pcall(BotBrain.chooseVote, c.voteKind, c.voteOptions, humanTally(c), c.botRng)
	if not ok or not Guard.isInt(idx, 1, c.voteCount) then
		return false
	end
	if vote:cast(b.id, idx) then
		c.botVoted[b.id] = true
		return true
	end
	return false
end

-- Each bot votes after a random 1-4 s delay.
local function scheduleBotVotes(c: Ctx)
	local token = c.voteToken
	for _, b in c.bots do
		local delay = c.botRng:range(RunDirector.BOT_VOTE_MIN, RunDirector.BOT_VOTE_MAX)
		task.delay(delay, function()
			if ctx ~= c or c.aborted or c.voteToken ~= token or not c.vote then
				return
			end
			if botCastVote(c, b) then
				Remotes.voteTally(memberList(c), tallyArray(c))
			end
		end)
	end
end

local function runVote(c: Ctx, kind: string, options: { any }, defaultIndex: number, seconds: number): number
	local voters = {}
	for _, p in memberList(c) do
		table.insert(voters, p.UserId)
	end
	for _, b in c.bots do
		table.insert(voters, b.id)
	end
	c.vote = Vote.new(#options, voters)
	c.voteCount = #options
	c.voted = {}
	c.voteKind = kind
	c.voteOptions = options
	c.voteToken += 1
	c.humanVotes = {}
	c.botVoted = {}
	c.votePhase = phaseOf(c)
	local deadline = setPhaseTimer(c, seconds)
	broadcastRunState(c)
	local members = memberList(c)
	Remotes.voteOpen(members, { kind = kind, options = options, endsAt = c.phaseEndsAt :: number })
	Remotes.voteTally(members, tallyArray(c))
	scheduleBotVotes(c)

	waitFor(c, deadline, function()
		return allMembersVoted(c)
	end)

	local idx = defaultIndex
	local vote = c.vote
	if vote then
		local ok, r = pcall(vote.resolve, vote, c.voteRng, defaultIndex)
		if ok and Guard.isInt(r, 1, #options) then
			idx = r
		end
	end
	c.vote = nil
	c.votePhase = nil
	c.voteKind = nil
	c.voteOptions = nil
	c.voteToken += 1 -- cancels bot votes still waiting
	Remotes.voteClosed(memberList(c), idx)
	return idx
end

local function onVote(player: Player, optionIndex: number)
	local c = ctx
	if not c or not c.members[player] or not c.vote then
		return
	end
	if phaseOf(c) ~= c.votePhase or optionIndex > c.voteCount then
		Guard.reject(player, "Vote", "no matching open vote", false)
		return
	end
	if c.vote:cast(player.UserId, optionIndex) then
		c.voted[player.UserId] = true
		c.humanVotes[player.UserId] = optionIndex
		-- Bots that already voted re-follow the human plurality.
		for _, b in c.bots do
			if c.botVoted[b.id] then
				botCastVote(c, b)
			end
		end
		Remotes.voteTally(memberList(c), tallyArray(c))
	end
end

-- Upgrade remotes --------------------------------------------------------------------------------

local OFFER_PHASES = {
	RouteVote = true,
	Waves = true,
	Boss = true,
	StageClear = true,
	BankVote = true,
	CycleVote = true,
}

local function onChooseUpgrade(player: Player, offerId: number, cardIndex: number)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr then
		return
	end
	if not OFFER_PHASES[phaseOf(c)] then
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
	if world and Guard.isFiniteNumber(heal) and heal > 0 and type(world.healPlayer) == "function" then
		pcall(world.healPlayer, world, pr.userId, heal)
	end
	presentNextOffer(c, pr)
	sendHud(c, pr, true)
end

local function onRerollUpgrade(player: Player, offerId: number)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr then
		return
	end
	if not OFFER_PHASES[phaseOf(c)] then
		return
	end
	local offer = pr.offer
	if not offer or offer.offerId ~= offerId then
		Guard.reject(player, "RerollUpgrade", "stale or unknown offer", false)
		return
	end
	-- Spend order: free (per stage) -> reroll tokens via RunTokens (max 2 per stage).
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
	pr.offer = nil
	rollOffer(c, pr)
	sendHud(c, pr, true)
end

local function onUseAbility(player: Player, aimX: number, aimZ: number)
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or not c.world then
		return
	end
	local phase = phaseOf(c)
	if phase ~= "Waves" and phase ~= "Boss" then
		return
	end
	local world = c.world
	if world:useAbility(pr.userId, aimX, aimZ, simNow()) then
		sendHud(c, pr, true)
	end
end

-- RunTokens dry run on copies: (allowed, "free" | "token" | reason, reviveCtx).
local function probeSecondWind(c: Ctx, pr: PlayerRun): (boolean, string, { [string]: any })
	local reviveCtx: { [string]: any } = { doubleOrNothing = c.run:getPublic().doubleOrNothing == true }
	local world = c.world
	if world and type(world.bossInfo) == "function" then
		local okB, boss = pcall(world.bossInfo, world)
		if okB and type(boss) == "table" and Guard.isFiniteNumber(boss.hpFrac) then
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

anyHumanCanSecondWind = function(c: Ctx): boolean
	local world = c.world
	if not world then
		return false
	end
	for _, p in memberList(c) do
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
	if not c or not pr or not c.world then
		return
	end
	local phase = phaseOf(c)
	if phase ~= "Waves" and phase ~= "Boss" then
		return
	end
	local world = c.world
	local info = world:getPlayer(pr.userId)
	if not info or not info.downed or info.dead then
		return
	end
	-- RunTokens rules: first revive free; 1 per stage; max 2 token revives per run;
	-- no token revive below 10% boss HP or on a Double-or-Nothing stage.
	local key = stageKey(c)
	-- Dry run on copies first, so nothing is spent if the world refuses.
	local allowed, how, reviveCtx = probeSecondWind(c, pr)
	if not allowed then
		local reason = how
		Remotes.toast(
			player,
			if reason == "stage_cap"
				then "Second Wind already used this stage."
				elseif reason == "run_cap" then "No more Second Winds this run."
				elseif
					reason == "blocked_double_or_nothing"
				then "No token revives on Double-or-Nothing stages."
				elseif reason == "blocked_boss_low" then "Too late, the boss is almost down!"
				else "No Second Winds left.",
			"bad"
		)
		return
	end
	if not world:useSecondWind(pr.userId) then
		return
	end
	if how == "free" then
		RunTokens.useSecondWind(pr.tokens, table.clone(NO_PROFILE), key, reviveCtx)
	else
		local spent = false
		profileUpdate(player, function(profile: any)
			local ok, r = pcall(RunTokens.useSecondWind, pr.tokens, profile, key, reviveCtx)
			spent = ok and r == true
		end)
		if not spent then
			warn("[RunDirector] Second Wind token could not be charged for " .. player.Name)
			pr.tokens.usedToken = true
		end
	end
	pr.usedSecondWindToken = pr.tokens.usedToken == true
	if pr.stats then
		setHumanoidSpeed(player, pr.stats.moveSpeed)
	end
	Remotes.toast(memberList(c), player.DisplayName .. " used Second Wind!", "good")
	sendHud(c, pr, true)
	sendPartyHud(c, true)
end

-- Arena / world ---------------------------------------------------------------------------------

local function arenaSpawnPos(c: Ctx, slot: number): Vector3
	local arena = c.arena
	local base: Vector3 = if arena and typeof(arena.spawn) == "Vector3" then arena.spawn else Vector3.zero
	local n = math.max(1, #c.order + #c.bots)
	local angle = (slot - 1) * (math.pi * 2 / n)
	local r = if n > 1 then 4 else 0
	return base + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r)
end

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

local function stopCombat(c: Ctx)
	if c.world then
		pcall(CombatService.stop)
		c.world = nil
	end
	if BotService and type(BotService.setWorld) == "function" then
		pcall(BotService.setWorld, nil, nil)
	end
end

local function teleportToArena(c: Ctx, pr: PlayerRun)
	local pos = arenaSpawnPos(c, pr.slot)
	LobbyService.teleportCharacter(pr.player, pos)
end

-- Stage --------------------------------------------------------------------------------------------

local function defaultRouteIndex(cards: { any }): number
	for i, card in cards do
		if card.tier == "Low" then
			return i
		end
	end
	return 1
end

local function defaultBankIndex(options: { string }): number
	return table.find(options, "Continue") or table.find(options, "GoHome") or 1
end

local function stageIntroText(c: Ctx, card: any): string
	local pub = c.run:getPublic()
	local text = string.format("Stage %d-%d: %s", pub.cycle, pub.stageInCycle, defName(Maps, card.mapId))
	if card.curseId then
		text ..= " | Curse: " .. defName(Modifiers, card.curseId)
	end
	if card.cleanse then
		text ..= " | Cleanse!"
	end
	return text
end

-- Plays one stage. Returns "continue" | "results" | "abort".
local function playStage(c: Ctx): string
	-- 1. Route vote
	local cards = c.run:openRouteVote()
	local idx = runVote(c, "route", cards, defaultRouteIndex(cards), RunDirector.VOTE_SECONDS)
	if c.aborted then
		return "abort"
	end
	local card = c.run:chooseRoute(idx)
	c.card = card
	c.stageIndex += 1

	for _, pr in c.members do
		pr.freeRerollsLeft = RunDirector.FREE_REROLLS_PER_STAGE
	end

	-- 2. Arena
	stopCombat(c)
	ArenaBuilder.clear()
	local stageSeed = c.run:getStageSeed()
	local arena = ArenaBuilder.build(card.mapId, stageSeed)
	c.arena = arena
	for _, p in memberList(c) do
		task.spawn(teleportToArena, c, c.members[p])
	end

	-- 3. World
	local pub = c.run:getPublic()
	local mapDef = lookupDef(Maps, card.mapId)
	local world = World.new({
		rng = Rng.new(stageSeed):fork(c.stageIndex),
		mods = c.run:worldMods(),
		arenaRadius = arena.radius,
		obstacles = arena.obstacles or {},
		enemyPool = if mapDef and mapDef.enemyPool then mapDef.enemyPool else {},
		cycle = pub.cycle,
		stage = pub.stageInCycle,
	})
	c.world = world
	if type(world.setStage) == "function" then
		world:setStage(pub.cycle, pub.stageInCycle)
	end
	for _, p in memberList(c) do
		local pr = c.members[p]
		computeStats(c, pr)
		local pos = arenaSpawnPos(c, pr.slot)
		world:addPlayer(pr.userId, pr.stats, pr.weapon, pr.ability, pos.X, pos.Z)
		if Guard.isFiniteNumber(pr.stats.moveSpeed) then
			setHumanoidSpeed(p, pr.stats.moveSpeed)
		end
	end
	for _, b in c.bots do
		computeBotStats(c, b)
		local pos = arenaSpawnPos(c, b.slot)
		world:addPlayer(b.id, b.stats, b.weapon, b.ability, pos.X, pos.Z)
	end
	-- Only humans: CombatService syncs character positions for real Players.
	CombatService.start(world, memberList(c))
	if BotService and #c.bots > 0 and type(BotService.setWorld) == "function" then
		local ok, err = pcall(BotService.setWorld, world, arena)
		if not ok then
			warn("[RunDirector] BotService.setWorld failed: " .. tostring(err))
		end
	end
	Remotes.toast(memberList(c), stageIntroText(c, card), "info")

	-- 4. Waves
	world:startWaves(RunDirector.WAVE_SECONDS)
	c.downSince = nil
	local deadline = setPhaseTimer(c, RunDirector.WAVE_SECONDS)
	broadcastRunState(c)
	local r = waitFor(c, deadline, function()
		return wipeCheck(c)
	end)
	if r == "abort" then
		return "abort"
	elseif r == "pred" then
		c.run:wipe()
		return "results"
	end

	-- 5. Boss
	world:stopSpawning()
	world:clearEnemies()
	c.run:startBoss()
	c.bossDead = false
	c.bossSpawnedAt = os.clock()
	local center = arenaCenter(c)
	world:spawnBoss(card.bossId, center.X, center.Z)
	setPhaseTimer(c, nil)
	broadcastRunState(c)
	Remotes.toast(memberList(c), defName(Bosses, card.bossId) .. " appears!", "bad")

	local wiped = false
	r = waitFor(c, nil, function()
		if wipeCheck(c) then
			wiped = true
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
	elseif wiped then
		c.run:wipe()
		return "results"
	end

	-- 6. Stage clear: blessing + loot
	local preStage = c.run:getPublic()
	local reward = c.run:bossDefeated()
	c.bossesKilled += 1
	if preStage.cycle == 1 and preStage.stageInCycle == 4 and c.cycle1Time == nil then
		c.cycle1Time = os.clock() - c.startedAt
	end
	world:clearEnemies()
	world:respawnDead(RunDirector.RESPAWN_HP_FRAC)
	for _, p in memberList(c) do
		local pr = c.members[p]
		computeStats(c, pr)
		pushStats(c, pr)
		sendHud(c, pr, true)
	end
	for _, b in c.bots do
		computeBotStats(c, b)
		world:updatePlayer(b.id, b.stats, b.weapon)
	end
	sendPartyHud(c, true)
	local members = memberList(c)
	Remotes.toast(
		members,
		"Boss defeated! +" .. tostring(reward.cheesePerPlayer) .. " Cheese (pending)",
		"good"
	)
	if reward.blessingId then
		Remotes.toast(members, "Blessing: " .. defName(Modifiers, reward.blessingId), "good")
	end
	if reward.epic then
		Remotes.toast(members, "EPIC drop!", "good")
	end
	local clearDeadline = setPhaseTimer(c, RunDirector.STAGE_CLEAR_SECONDS)
	broadcastRunState(c)
	if waitFor(c, clearDeadline, nil) == "abort" then
		return "abort"
	end

	-- 7. Bank / cycle vote
	local bank = c.run:openBankVote()
	local options: { string } = bank.options
	local bidx = runVote(c, bank.kind, options, defaultBankIndex(options), RunDirector.VOTE_SECONDS)
	if c.aborted then
		return "abort"
	end
	local choice = options[bidx]
	c.run:chooseBank(choice)
	if choice == "DoubleOrNothing" then
		Remotes.toast(memberList(c), "DOUBLE OR NOTHING!", "bad")
	end
	if phaseOf(c) == "Results" then
		return "results"
	end
	return "continue"
end

-- Teardown -----------------------------------------------------------------------------------------

local function teardown(c: Ctx)
	c.finished = true
	stopCombat(c)
	pcall(ArenaBuilder.clear)
	local players = memberList(c)
	for _, p in players do
		setHumanoidSpeed(p, DEFAULT_WALKSPEED)
	end
	if ctx == c then
		ctx = nil
	end
	if BotService and type(BotService.despawnAll) == "function" then
		pcall(BotService.despawnAll) -- before setRunActive(false) re-places lobby bots
	end
	LobbyService.returnToLobby(players)
	LobbyService.setRunActive(false)
	Remotes.runState(lobbyRunState())
end

local function finishRun(c: Ctx)
	if c.awarded then
		return
	end
	c.awarded = true
	local rewards = c.run:finalRewards()
	local pub = c.run:getPublic()
	local deadline = setPhaseTimer(c, RunDirector.RESULTS_SECONDS)
	broadcastRunState(c)
	local duration = os.clock() - c.startedAt
	local won = rewards.outcome == "Win"
	for _, p in memberList(c) do
		local pr = c.members[p]
		local statMult = if pr.stats
				and Guard.isFiniteNumber(pr.stats.cheeseMult)
				and pr.stats.cheeseMult > 0
			then pr.stats.cheeseMult
			else 1
		local mult = cheeseMult(p) * statMult
		local cheese = math.max(0, math.floor((rewards.cheesePerPlayer or 0) * mult + 0.5))
		pr.awarded = true
		local xp = math.max(0, math.floor((rewards.xpPerPlayer or 0) * xpMult(p) + 0.5))
		awardRun(p, cheese, xp, {
			won = won,
			cycle = pub.cycle,
			bosses = c.bossesKilled,
			cycle1Time = c.cycle1Time,
			ranked = not pr.usedSecondWindToken,
			day = math.floor(os.time() / 86400),
		})
		Remotes.results(p, {
			outcome = rewards.outcome,
			cheeseEarned = cheese,
			xpEarned = xp,
			cycle = pub.cycle,
			stage = pub.stageInCycle,
			bossesKilled = c.bossesKilled,
			duration = math.floor(duration),
			cheeseMult = mult,
		})
	end
	waitFor(c, deadline, function()
		return #memberList(c) == 0
	end)
end

-- Run loop ------------------------------------------------------------------------------------------

local function runLoop(c: Ctx)
	while true do
		local r = playStage(c)
		if r == "abort" then
			return
		elseif r == "results" then
			finishRun(c)
			return
		end
	end
end

local function startRun(players: { Player }, classes: { [number]: string }, botSpecs: { any }?)
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

	-- Bots fill empty slots but never take one from a human (cap MAX_PARTY).
	local bots: { BotRun } = {}
	for _, spec in botSpecs or {} do
		if #party + #bots >= LobbyService.MAX_PARTY then
			break
		end
		if
			type(spec) == "table"
			and Guard.isInt(spec.id, -1000000, -1)
			and type(spec.classId) == "string"
		then
			table.insert(bots, {
				id = spec.id,
				name = if type(spec.name) == "string" then spec.name else "Bot 🤖",
				slot = #party + #bots + 1,
				classId = spec.classId,
				level = 1,
				xp = 0,
				stacks = {},
				stats = nil,
				weapon = nil,
				ability = nil,
				offerRng = nil,
			})
		end
	end

	local seed = Random.new():NextInteger(1, 2147483646)
	local rng = Rng.new(seed)
	local playerCount = math.max(1, math.ceil(#party + RunDirector.BOT_WEIGHT * #bots - 1e-9))
	local run = RunState.new(seed, playerCount, { bossIds = Bosses.ORDER, mapIds = Maps.ORDER })
	for i, b in bots do
		b.offerRng = rng:fork(200 + i)
	end
	local c: Ctx = {
		seed = seed,
		run = run,
		rng = rng,
		voteRng = rng:fork(1),
		members = {},
		order = party,
		bots = bots,
		botRng = rng:fork(2),
		world = nil,
		arena = nil,
		card = nil,
		phaseEndsAt = nil,
		vote = nil,
		votePhase = nil,
		voteCount = 0,
		voted = {},
		voteKind = nil,
		voteOptions = nil,
		voteToken = 0,
		humanVotes = {},
		botVoted = {},
		bossDead = false,
		bossSpawnedAt = 0,
		downSince = nil,
		bossesKilled = 0,
		startedAt = os.clock(),
		cycle1Time = nil,
		stageIndex = 0,
		nextOfferId = 0,
		aborted = false,
		finished = false,
		awarded = false,
		lastPartyAt = 0,
		lastParty = nil,
	}
	for slot, p in party do
		local classId = classes[p.UserId] or LobbyService.getClass(p)
		c.members[p] = {
			player = p,
			userId = p.UserId,
			slot = slot,
			classId = classId,
			level = 1,
			xp = 0,
			stacks = {},
			stats = nil,
			weapon = nil,
			ability = nil,
			pendingLevels = 0,
			offer = nil,
			offerRng = rng:fork(100 + slot),
			freeRerollsLeft = RunDirector.FREE_REROLLS_PER_STAGE,
			tokens = RunTokens.new(),
			usedSecondWindToken = false,
			awarded = false,
			lastHud = nil,
			lastHudAt = 0,
		}
	end
	ctx = c
	LobbyService.setRunActive(true, party)
	for _, p in party do
		local pr = c.members[p]
		local ok, err = pcall(computeStats, c, pr)
		if not ok then
			warn("[RunDirector] Stats.compute failed: " .. tostring(err))
		end
	end
	for _, b in bots do
		local ok, err = pcall(computeBotStats, c, b)
		if not ok then
			warn("[RunDirector] bot Stats.compute failed: " .. tostring(err))
		end
	end
	if BotService and type(BotService.spawnForRun) == "function" then
		local specs = {}
		for _, b in bots do
			table.insert(specs, { id = b.id, name = b.name, classId = b.classId, isBot = true })
		end
		local ok, err = pcall(BotService.spawnForRun, specs, nil, nil, seed)
		if not ok then
			warn("[RunDirector] BotService.spawnForRun failed: " .. tostring(err))
		end
	end
	if #bots > 0 then
		Remotes.toast(
			party,
			string.format("%d bot teammate%s joined the party!", #bots, if #bots == 1 then "" else "s"),
			"info"
		)
	end
	sendPartyHud(c, true)

	local ok, err = xpcall(runLoop, debug.traceback, c)
	if not ok then
		warn("[RunDirector] run crashed: " .. tostring(err))
		Remotes.toast(memberList(c), "Something went wrong. Returning to the lobby.", "bad")
		-- Pay out what the rules allow (wipe rules: banked + partial pending).
		pcall(function()
			if phaseOf(c) ~= "Results" then
				c.run:wipe()
			end
			finishRun(c)
		end)
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
	c.members[player] = nil
	if not pr.awarded then
		-- DataService.beforeRelease pays the wipe-rule payout (see payLeaver).
		departed[player] = { c = c, pr = pr }
		task.delay(120, function()
			departed[player] = nil
		end)
	end
	local world = c.world
	if world then
		pcall(world.removePlayer, world, pr.userId)
	end
	if c.vote then
		pcall(c.vote.removeVoter, c.vote, pr.userId)
	end
	c.humanVotes[pr.userId] = nil
	-- Bots never hold a run open: no humans left -> the run ends.
	if next(c.members) == nil and not c.finished then
		c.aborted = true
	else
		pcall(c.run.setPlayerCount, c.run, difficultyCount(c))
		sendPartyHud(c, true)
	end
end

local function onPlayerAdded(player: Player)
	local c = ctx
	if c then
		Remotes.runState(publicState(c), player)
	else
		Remotes.runState(lobbyRunState(), player)
	end
end

-- Run members who respawn go back to the arena (if one is built).
local function characterOverride(player: Player, _character: Model): boolean
	local c = ctx
	local pr = c and c.members[player]
	if not c or not pr or not c.arena then
		return false
	end
	teleportToArena(c, pr)
	if pr.stats and not isDowned(c, pr) and Guard.isFiniteNumber(pr.stats.moveSpeed) then
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
			for _, p in memberList(c) do
				local pr = c.members[p]
				local ok, err = pcall(sendHud, c, pr)
				if not ok then
					warn("[RunDirector] hud: " .. tostring(err))
				end
			end
			acc += dt
			if acc >= RunDirector.PARTY_INTERVAL then
				acc = 0
				pcall(sendPartyHud, c)
			end
		end
	end
end

-- Leave-time payout ---------------------------------------------------------------------------------

-- DataService.beforeRelease: a human leaving mid-run gets the wipe-rule payout
-- (banked + kept share of pending, nothing pending on Double-or-Nothing)
-- before their profile is saved and released. Also covers server shutdown.
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
	pr.awarded = true
	local run = c.run
	local cheeseBase, xpBase = 0, 0
	if phaseOf(c) == "Results" then
		local ok, r = pcall(run.finalRewards, run)
		if ok and type(r) == "table" then
			cheeseBase, xpBase = r.cheesePerPlayer or 0, r.xpPerPlayer or 0
		end
	else
		local keepFrac = if RunState.CONFIG and Guard.isFiniteNumber(RunState.CONFIG.WIPE_KEEP_FRAC)
			then RunState.CONFIG.WIPE_KEEP_FRAC
			else 0.5
		local pending = if Guard.isFiniteNumber(run.pendingCheese) then run.pendingCheese else 0
		local banked = if Guard.isFiniteNumber(run.bankedCheese) then run.bankedCheese else 0
		local keep = if run.doubleOrNothing then 0 else math.floor(pending * keepFrac)
		cheeseBase = banked + keep
		xpBase = if Guard.isFiniteNumber(run.xpEarned) then run.xpEarned else 0
	end
	local statMult = if pr.stats
			and Guard.isFiniteNumber(pr.stats.cheeseMult)
			and pr.stats.cheeseMult > 0
		then pr.stats.cheeseMult
		else 1
	local cheese = math.max(0, math.floor(cheeseBase * cheeseMult(player) * statMult + 0.5))
	local xp = math.max(0, math.floor(xpBase * xpMult(player) + 0.5))
	local pub = run:getPublic()
	awardRun(player, cheese, xp, {
		won = false,
		cycle = pub.cycle,
		bosses = c.bossesKilled,
		cycle1Time = c.cycle1Time,
		ranked = not pr.usedSecondWindToken,
		day = math.floor(os.time() / 86400),
	})
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

-- Read-only view for debugging / other services.
function RunDirector.isRunning(): boolean
	return ctx ~= nil
end

function RunDirector.getPhase(): string
	local c = ctx
	return if c then phaseOf(c) else "Lobby"
end

return RunDirector
