--!strict
-- Pure run state machine (GDD §3). RunDirector (Team E) drives it; it never
-- touches Roblox. All randomness comes from Rng forks of the run seed.
--
-- Phase flow:
--   Lobby --openRouteVote--> RouteVote --chooseRoute--> Waves --startBoss--> Boss
--   --bossDefeated--> StageClear --openBankVote--> BankVote | CycleVote
--   --chooseBank--> RouteVote (next stage, cards already rolled) | Results
--   wipe() from any phase except Results -> Results (outcome "Wipe").
-- Calling a method in the wrong phase raises an error (programming bug).
--
-- Interpretation notes (where the GDD / contract left room):
--   * RunState.new(seed, playerCount, opts?) — opts.bossIds / opts.mapIds
--     override the defaults (13 GDD bosses / Maps.ORDER).
--   * chooseBank (non-final options) rolls the next stage's cards and sets the
--     phase to "RouteVote". openRouteVote is idempotent while in RouteVote: it
--     returns the cards already rolled. From Lobby it rolls the first cards.
--   * Run stage 1 (cycle 1, stage 1): 3 Low cards on 3 different maps, no
--     curse, a small (Low) blessing each, random boss.
--   * Later stages: cards Low / Mid / High (in that order, so vote option 1 =
--     Low = the no-vote default). The Low card has no curse on stage 1 of a
--     cycle (GDD table: "none on Stage 1"). Low/Mid curses last the stage;
--     High curses last the whole run. Curses already active are not offered.
--   * Maps never repeat inside a cycle and the 3 cards show different maps when
--     the pool allows; the pool resets each cycle. If opts.mapIds has fewer
--     maps than a cycle needs, the pool resets when it runs dry. Bosses avoid
--     repeats inside a cycle the same way.
--   * Cleanse (High card only, CLEANSE_CHANCE, only when a run-long curse is
--     active): on pick it removes the OLDEST run-long curse, then the card's
--     own High curse is added.
--   * Rewards are per player. Stage cheese =
--       floor((BASE_CHEESE + CHEESE_PER_STAGE*(stage-1)) * (1 + CYCLE_REWARD_STEP*(cycle-1))
--             * rewardMult * (2 if double-or-nothing))
--     Double or Nothing win: pending pot x1.5 first, then the doubled chest is
--     added (potBonus is returned). XP is never doubled and never lost.
--   * Stage curses expire at bossDefeated. The route's blessing is added then.
--   * Next Cycle banks floor(50%) of pending; the rest stays pending.
--   * Wipe: banked kept; pending -> floor(50%) banked, or 0 if Double or
--     Nothing was active for the stage being played.
--   * Per-player multipliers (cheeseMult stat, passes, boosts) are applied by
--     RunDirector at payout, not here.
--   * Pressure (GDD §3.7, Run/Pressure): opts.pressure is the party leader's
--     board; it is sanitized here (never trusted). It adds its WorldMods deltas
--     to worldMods(), multiplies every stage chest by Pressure.cheeseMult
--     (+8% per point; the bonus is in bossDefeated's cheesePerPlayer, so it
--     flows through pending -> banked -> finalRewards exactly once), adds
--     +2% per point to every rolled card's epicChance (capped at 1), and
--     exposes pressureLuck() (+0.05 per point) for UpgradeOffers.roll.

local Types = require("../Types")
local Rng = require("../Util/Rng")
local Modifiers = require("../Config/Modifiers")
local Maps = require("../Config/Maps")
local Stats = require("./Stats")
local Pressure = require("./Pressure")

type RouteCard = Types.RouteCard
type RunPhase = Types.RunPhase
type Tier = Types.Tier
type WorldMods = Types.WorldMods
type PublicRunState = Types.PublicRunState

export type CurseEntry = { id: string, duration: "stage" | "run" }
export type Outcome = "Win" | "Wipe"
export type StageReward = {
	cheesePerPlayer: number,
	blessingId: string?,
	epic: boolean,
	xpPerPlayer: number,
	potBonus: number,
}
export type BankVote = { kind: "bank" | "cycle", options: { string } }
export type Options = { bossIds: { string }?, mapIds: { string }?, pressure: { [string]: number }? }

local RunState = {}
RunState.__index = RunState

RunState.DEFAULT_BOSS_IDS = table.freeze({
	"giant_tree",
	"froggus",
	"serpent_sisters",
	"my_grandma",
	"floating_witch",
	"corndog_bunny",
	"spider_machine",
	"green_gorilla",
	"paper_dinosaur",
	"hematite_snake",
	"ice_dragon",
	"void_cat",
	"zoomzola",
})

local REWARD_MULT: { [string]: number } = { Low = 1.0, Mid = 1.5, High = 2.0 }
local EPIC_CHANCE: { [string]: number } = { Low = 0, Mid = 0, High = 0.1 }

RunState.CONFIG = table.freeze({
	STAGES_PER_CYCLE = 4,
	CARD_COUNT = 3,
	BASE_CHEESE = 100,
	CHEESE_PER_STAGE = 25,
	CYCLE_REWARD_STEP = 0.5, -- +50% rewards per cycle after the first
	BASE_XP = 50,
	XP_PER_STAGE = 10,
	REWARD_MULT = table.freeze(REWARD_MULT),
	EPIC_CHANCE = table.freeze(EPIC_CHANCE),
	CLEANSE_CHANCE = 0.4,
	DON_STAGE_MULT = 2,
	DON_POT_MULT = 1.5,
	NEXT_CYCLE_BANK_FRAC = 0.5,
	WIPE_KEEP_FRAC = 0.5,
})

local C = RunState.CONFIG

type RunData = {
	seed: number,
	playerCount: number,
	phase: RunPhase,
	cycle: number,
	stageInCycle: number,
	pendingCheese: number,
	bankedCheese: number,
	xpEarned: number,
	doubleOrNothing: boolean,
	outcome: Outcome?,
	phaseEndsAt: number?, -- RunDirector may set this; copied into getPublic()
	bossesKilled: number,
	stagesCleared: number,
	epicDrops: number,
	curses: { CurseEntry },
	blessings: { string },
	route: RouteCard?,
	cards: { RouteCard }?,
	stageSeed: number,
	mapIds: { string },
	bossIds: { string },
	usedMaps: { [string]: boolean },
	usedBosses: { [string]: boolean },
	routeRng: Rng.Rng,
	lootRng: Rng.Rng,
	pressure: Pressure.Board, -- sanitized board (read-only after new)
	pressurePts: number, -- (not `pressurePoints`: that name is the method)
}

export type RunState = typeof(setmetatable({} :: RunData, RunState))

-- Difficulty party size: humans count 1, bots BOT_WEIGHT (0.6), so it may be
-- fractional (solo + 2 bots = 2.2). Clamped to 1..maxPlayers, 2 decimals.
function RunState.partySize(n: number): number
	local pc = if type(n) == "number" and n == n then n else 1
	pc = math.clamp(pc, 1, Stats.DIFFICULTY.maxPlayers)
	return math.floor(pc * 100 + 0.5) / 100
end

local function expectPhase(self: RunState, fn: string, ...: RunPhase)
	for i = 1, select("#", ...) do
		if self.phase == select(i, ...) then
			return
		end
	end
	error(string.format("RunState:%s called in phase %s", fn, self.phase), 3)
end

function RunState.new(seed: number, playerCount: number, opts: Options?): RunState
	local o: Options = opts or {}
	local mapIds = table.clone(o.mapIds or Maps.ORDER)
	local bossIds = table.clone(o.bossIds or RunState.DEFAULT_BOSS_IDS :: { string })
	assert(#mapIds > 0, "RunState.new: need at least one map")
	assert(#bossIds > 0, "RunState.new: need at least one boss")
	local root = Rng.new(seed)
	local pc = if playerCount == playerCount then playerCount else 1
	local pressure = Pressure.sanitize(o.pressure)
	return setmetatable({
		seed = seed,
		playerCount = RunState.partySize(pc),
		phase = "Lobby" :: RunPhase,
		cycle = 1,
		stageInCycle = 1,
		pendingCheese = 0,
		bankedCheese = 0,
		xpEarned = 0,
		doubleOrNothing = false,
		outcome = nil,
		phaseEndsAt = nil,
		bossesKilled = 0,
		stagesCleared = 0,
		epicDrops = 0,
		curses = {},
		blessings = {},
		route = nil,
		cards = nil,
		stageSeed = 0,
		mapIds = mapIds,
		bossIds = bossIds,
		usedMaps = {},
		usedBosses = {},
		routeRng = root:fork(1),
		lootRng = root:fork(2),
		pressure = pressure,
		pressurePts = Pressure.points(pressure),
	}, RunState)
end

----------------------------------------------------------------------------
-- Reward maths (exposed for tests / UI previews)

function RunState.stageCheese(
	cycle: number,
	stageInCycle: number,
	rewardMult: number,
	doubleOrNothing: boolean
): number
	local base = C.BASE_CHEESE + C.CHEESE_PER_STAGE * (stageInCycle - 1)
	local cycleMult = 1 + C.CYCLE_REWARD_STEP * (cycle - 1)
	local don = if doubleOrNothing then C.DON_STAGE_MULT else 1
	return math.floor(base * cycleMult * rewardMult * don)
end

-- Stage chest after the Pressure bonus (+8% per point), floored.
function RunState.applyPressureCheese(cheese: number, pressurePoints: number): number
	return math.floor(cheese * Pressure.cheeseMult(pressurePoints) + 1e-6)
end

function RunState.stageXp(cycle: number, stageInCycle: number, rewardMult: number): number
	local base = C.BASE_XP + C.XP_PER_STAGE * (stageInCycle - 1)
	local cycleMult = 1 + C.CYCLE_REWARD_STEP * (cycle - 1)
	return math.floor(base * cycleMult * rewardMult)
end

----------------------------------------------------------------------------
-- Card rolling

-- Picks up to n distinct ids from `all` avoiding `used`; if the unused pool is
-- smaller than n, the remaining cards repeat ids from that pool. If nothing
-- is unused, the whole list is the pool.
local function pickDistinct(rng: Rng.Rng, all: { string }, used: { [string]: boolean }, n: number): { string }
	local pool = {}
	for _, id in all do
		if not used[id] then
			table.insert(pool, id)
		end
	end
	if #pool == 0 then
		pool = table.clone(all)
	end
	rng:shuffle(pool)
	local out = {}
	for i = 1, n do
		out[i] = if i <= #pool then pool[i] else rng:pick(pool)
	end
	return out
end

function RunState._isActiveCurse(self: RunState, id: string): boolean
	for _, c in self.curses do
		if c.id == id then
			return true
		end
	end
	return false
end

function RunState._hasRunCurse(self: RunState): boolean
	for _, c in self.curses do
		if c.duration == "run" then
			return true
		end
	end
	return false
end

function RunState._pickCurse(self: RunState, tier: Tier): string?
	local pool = {}
	for _, id in Modifiers.ids("curse", tier) do
		if not self:_isActiveCurse(id) then
			table.insert(pool, id)
		end
	end
	if #pool == 0 then
		return nil
	end
	return self.routeRng:pick(pool)
end

-- Prefers blessings the party does not have yet (and not in `taken`).
function RunState._pickBlessing(self: RunState, tier: Tier, taken: { [string]: boolean }): string?
	local all = Modifiers.ids("blessing", tier)
	local owned = {}
	for _, id in self.blessings do
		owned[id] = true
	end
	local fresh, notTaken = {}, {}
	for _, id in all do
		if not taken[id] then
			table.insert(notTaken, id)
			if not owned[id] then
				table.insert(fresh, id)
			end
		end
	end
	local pool = if #fresh > 0 then fresh elseif #notTaken > 0 then notTaken else all
	if #pool == 0 then
		return nil
	end
	return self.routeRng:pick(pool)
end

-- A card's Epic-drop chance: the tier's base plus the Pressure bonus.
function RunState._epicChance(self: RunState, tier: Tier): number
	return math.min(1, C.EPIC_CHANCE[tier] + Pressure.epicBonus(self.pressurePts))
end

function RunState._rollCards(self: RunState): { RouteCard }
	local rng = self.routeRng
	local n = C.CARD_COUNT
	local maps = pickDistinct(rng, self.mapIds, self.usedMaps, n)
	local bosses = pickDistinct(rng, self.bossIds, self.usedBosses, n)
	local cards: { RouteCard } = {}
	local runStart = self.cycle == 1 and self.stageInCycle == 1
	if runStart then
		local taken = {}
		for i = 1, n do
			local blessing = self:_pickBlessing("Low", taken)
			if blessing then
				taken[blessing] = true
			end
			cards[i] = {
				tier = "Low",
				mapId = maps[i],
				bossId = bosses[i],
				curseId = nil,
				blessingId = blessing,
				rewardMult = C.REWARD_MULT.Low,
				cleanse = false,
				epicChance = self:_epicChance("Low"),
			}
		end
		return cards
	end
	local tiers: { Tier } = { "Low", "Mid", "High" }
	for i, tier in tiers do
		local curse: string?
		if tier == "Low" and self.stageInCycle == 1 then
			curse = nil
		else
			curse = self:_pickCurse(tier)
		end
		local cleanse = false
		if tier == "High" and self:_hasRunCurse() then
			cleanse = rng:chance(C.CLEANSE_CHANCE)
		end
		cards[i] = {
			tier = tier,
			mapId = maps[i],
			bossId = bosses[i],
			curseId = curse,
			blessingId = self:_pickBlessing(tier, {}),
			rewardMult = C.REWARD_MULT[tier],
			cleanse = cleanse,
			epicChance = self:_epicChance(tier),
		}
	end
	return cards
end

----------------------------------------------------------------------------
-- Phase transitions

function RunState.openRouteVote(self: RunState): { RouteCard }
	if self.phase == "RouteVote" and self.cards then
		return self.cards
	end
	expectPhase(self, "openRouteVote", "Lobby")
	self.cards = self:_rollCards()
	self.phase = "RouteVote"
	return self.cards :: { RouteCard }
end

function RunState.routeCards(self: RunState): { RouteCard }?
	return self.cards
end

function RunState.chooseRoute(self: RunState, cardIndex: number): RouteCard
	expectPhase(self, "chooseRoute", "RouteVote")
	local cards = self.cards
	assert(cards, "RunState:chooseRoute: no cards")
	local card = cards[cardIndex]
	if card == nil then
		error("RunState:chooseRoute: invalid card index " .. tostring(cardIndex), 2)
	end
	if card.cleanse then
		for i, c in self.curses do
			if c.duration == "run" then
				table.remove(self.curses, i)
				break
			end
		end
	end
	if card.curseId and not self:_isActiveCurse(card.curseId) then
		table.insert(self.curses, { id = card.curseId, duration = Modifiers.curseDuration(card.tier) })
	end
	self.usedMaps[card.mapId] = true
	self.usedBosses[card.bossId] = true
	self.route = table.clone(card)
	self.cards = nil
	self.stageSeed = self.routeRng:nextU32()
	self.phase = "Waves"
	return table.clone(card)
end

-- Adds bonus cheese to the pending pot (POI cheese caches, landmarks). Whole,
-- finite, non-negative amounts only; returns what was added. Pending cheese is
-- subject to the usual wipe / Double-or-Nothing rules.
function RunState.addPending(self: RunState, amount: number): number
	if type(amount) ~= "number" or amount ~= amount or amount == math.huge or amount <= 0 then
		return 0
	end
	local n = math.floor(amount)
	self.pendingCheese += n
	return n
end

function RunState.startBoss(self: RunState)
	expectPhase(self, "startBoss", "Waves")
	self.phase = "Boss"
end

function RunState.bossDefeated(self: RunState): StageReward
	expectPhase(self, "bossDefeated", "Boss")
	local route = self.route
	assert(route, "RunState:bossDefeated: no route")

	local cheese = RunState.applyPressureCheese(
		RunState.stageCheese(self.cycle, self.stageInCycle, route.rewardMult, self.doubleOrNothing),
		self.pressurePts
	)
	local xp = RunState.stageXp(self.cycle, self.stageInCycle, route.rewardMult)
	local potBonus = 0
	if self.doubleOrNothing then
		local grown = math.floor(self.pendingCheese * C.DON_POT_MULT)
		potBonus = grown - self.pendingCheese
		self.pendingCheese = grown
	end
	self.pendingCheese += cheese
	self.xpEarned += xp

	local epic = route.epicChance > 0 and self.lootRng:chance(route.epicChance)
	if epic then
		self.epicDrops += 1
	end
	if route.blessingId then
		table.insert(self.blessings, route.blessingId)
	end
	-- Stage-only curses end with the stage.
	local kept = {}
	for _, c in self.curses do
		if c.duration == "run" then
			table.insert(kept, c)
		end
	end
	self.curses = kept

	self.doubleOrNothing = false
	self.bossesKilled += 1
	self.stagesCleared += 1
	self.phase = "StageClear"
	return {
		cheesePerPlayer = cheese,
		blessingId = route.blessingId,
		epic = epic,
		xpPerPlayer = xp,
		potBonus = potBonus,
	}
end

function RunState.openBankVote(self: RunState): BankVote
	expectPhase(self, "openBankVote", "StageClear")
	if self.stageInCycle >= C.STAGES_PER_CYCLE then
		self.phase = "CycleVote"
		return { kind = "cycle", options = { "GoHome", "NextCycle" } }
	end
	self.phase = "BankVote"
	return { kind = "bank", options = { "Continue", "DoubleOrNothing" } }
end

function RunState._nextStage(self: RunState)
	self.route = nil
	self.cards = self:_rollCards()
	self.phase = "RouteVote"
end

function RunState.chooseBank(self: RunState, option: string)
	expectPhase(self, "chooseBank", "BankVote", "CycleVote")
	if self.phase == "BankVote" then
		if option == "Continue" then
			self.doubleOrNothing = false
		elseif option == "DoubleOrNothing" then
			self.doubleOrNothing = true
		else
			error("RunState:chooseBank: invalid bank option " .. tostring(option), 2)
		end
		self.stageInCycle += 1
		self:_nextStage()
		return
	end
	if option == "GoHome" then
		self.bankedCheese += self.pendingCheese
		self.pendingCheese = 0
		self.outcome = "Win"
		self.route = nil
		self.phase = "Results"
	elseif option == "NextCycle" then
		local banked = math.floor(self.pendingCheese * C.NEXT_CYCLE_BANK_FRAC)
		self.bankedCheese += banked
		self.pendingCheese -= banked
		self.cycle += 1
		self.stageInCycle = 1
		self.usedMaps = {}
		self.usedBosses = {}
		self:_nextStage()
	else
		error("RunState:chooseBank: invalid cycle option " .. tostring(option), 2)
	end
end

function RunState.wipe(self: RunState)
	if self.phase == "Results" then
		return
	end
	local keep = if self.doubleOrNothing then 0 else math.floor(self.pendingCheese * C.WIPE_KEEP_FRAC)
	self.bankedCheese += keep
	self.pendingCheese = 0
	self.outcome = "Wipe"
	self.cards = nil
	self.phase = "Results"
end

-- cheesePerPlayer already includes the Pressure bonus (applied per stage
-- chest in bossDefeated). pressurePoints is echoed for the award / results.
function RunState.finalRewards(self: RunState): {
	cheesePerPlayer: number,
	xpPerPlayer: number,
	outcome: Outcome,
	pressurePoints: number,
}
	expectPhase(self, "finalRewards", "Results")
	return {
		cheesePerPlayer = self.bankedCheese,
		xpPerPlayer = self.xpEarned,
		outcome = self.outcome or "Wipe",
		pressurePoints = self.pressurePts,
	}
end

----------------------------------------------------------------------------
-- Queries

function RunState.activeCurses(self: RunState): { string }
	local out = {}
	for _, c in self.curses do
		table.insert(out, c.id)
	end
	return out
end

-- Curses with their duration ("stage" | "run"), oldest first.
function RunState.curseEntries(self: RunState): { CurseEntry }
	local out = {}
	for _, c in self.curses do
		table.insert(out, table.clone(c))
	end
	return out
end

function RunState.activeBlessings(self: RunState): { string }
	return table.clone(self.blessings)
end

-- Difficulty + curses + the Pressure board.
function RunState.worldMods(self: RunState): WorldMods
	local mods = Stats.worldMods(self.cycle, self.stageInCycle, self:activeCurses(), self.playerCount)
	return Pressure.applyToMods(mods, self.pressure, self:globalStage())
end

-- Pressure (GDD §3.7) ----------------------------------------------------------

-- Total Pressure points of the run's board (0..Pressure.MAX_POINTS).
function RunState.pressurePoints(self: RunState): number
	return self.pressurePts
end

-- A copy of the run's (sanitized) Pressure board, modId -> rank.
function RunState.pressureBoard(self: RunState): { [string]: number }
	return table.clone(self.pressure)
end

-- Extra upgrade-offer luck from Pressure (+0.05 per point). RunDirector adds
-- it to the luck it passes to UpgradeOffers.roll.
function RunState.pressureLuck(self: RunState): number
	return Pressure.luck(self.pressurePts)
end

function RunState.currentRoute(self: RunState): RouteCard?
	return if self.route then table.clone(self.route) else nil
end

-- Deterministic seed for the current stage (ArenaBuilder / POI rolls / World rng).
function RunState.getStageSeed(self: RunState): number
	return self.stageSeed
end

-- 1-based stage index across the whole run (cycle 2 stage 1 = 5).
function RunState.globalStage(self: RunState): number
	return (self.cycle - 1) * C.STAGES_PER_CYCLE + self.stageInCycle
end

-- Players can leave mid-run; difficulty follows the live party size.
function RunState.setPlayerCount(self: RunState, n: number)
	self.playerCount = RunState.partySize(n)
end

function RunState.getPublic(self: RunState): PublicRunState
	local route = self.route
	return {
		phase = self.phase,
		cycle = self.cycle,
		stageInCycle = self.stageInCycle,
		mapId = if route then route.mapId else nil,
		bossId = if route then route.bossId else nil,
		pendingCheese = self.pendingCheese,
		bankedCheese = self.bankedCheese,
		doubleOrNothing = self.doubleOrNothing,
		activeCurses = self:activeCurses(),
		activeBlessings = self:activeBlessings(),
		phaseEndsAt = self.phaseEndsAt,
		outcome = self.outcome,
		pressure = table.clone(self.pressure),
		pressurePoints = self.pressurePts,
	}
end

return RunState
