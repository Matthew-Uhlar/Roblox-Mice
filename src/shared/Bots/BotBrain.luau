--!strict
-- Bot teammate brain (GDD §3.6, docs/ARCHITECTURE.md "Team F"). Pure and
-- deterministic for a given Rng: BotService builds a view of the world each
-- think tick and turns the returned intent into movement and ability casts.
--
--   BotBrain.new(id, classId, rng) -> brain
--   brain:think(view, dt) -> { moveX, moveZ, speedFrac, ability = {x, z}? }
--   BotBrain.chooseUpgrade(cards, rng) -> index   (0 when cards is empty)
--   BotBrain.chooseVote(kind, options, humanTally, rng) -> index
--
-- Steering is a weighted sum of: kite (away from the weighted centroid of
-- nearby mice; stronger at low HP), leash (stay near the nearest human),
-- revive (walk to a downed ally when it's safe-ish), crumbs, obstacle and
-- arena-edge avoidance, ally separation and a little wander. Downed bots crawl
-- toward the nearest standing ally.
--
-- Points of interest (GDD §3.8, view.pois from world:pois()): when it is safe
-- (healthy, few mice around the POI, close to the humans) a bot walks to the
-- nearest live channel POI (cache, shrine, fountain, rare POIs; the statue only
-- while someone is down) and stands in it until it is done; a healthy bot may
-- wake an Elite Camp next to the party. Bots keep out of Mousetrap Fields.
-- Portal (GDD §3.9, view.portal from world:portal()): on "pull" bots walk in.
--
-- v2 squads (GDD-v2 §2): with view.self.squad set, view.allies is split into
-- squad-mates (same squad) and foes (other squads; or pass view.foes). A bot
--   * sticks with its squad: leashes to the nearest squad human, else to the
--     squad leader (the bot with the highest id; the leader roams to POIs);
--   * fights an enemy hero only when one is within HERO_ENGAGE studs or has hit
--     its squad in the last SQUAD_ATTACK_MEMORY s (it closes to weapon range,
--     finishes downed foes, aims its ability at them);
--   * flees (away from foes, toward its squad) when below LOW_HP with a foe near;
--   * contests POIs other squads channel, captures / defends the Power Totem;
--   * walks over ground gear that beats its own slot (view.gear) and stands on
--     loot bags (view.bags) to channel them.
-- v3 Mouse Champions (GDD-v2 §4b; view.enemies kinds 100..199, flag bit 3 = a
-- Chemist clone): a healthy squad leader (the roaming bot, or the human stand-in
-- in the sim) hunts the nearest champion anywhere on the map before any POI, and
-- its squad follows; every bot near a champion closes in and fights it like a
-- boss (kite weight, ability), so squads that want the same champion meet there.
-- v4 (docs/V4-PLAN.md, docs/COMBAT-API.md "v4"):
--   * The Melt: with view.zone (world:zone(): {cx, cz, radius | r, toR}) a bot keeps
--     inside the NEXT circle (min(radius, toR)) with ZONE_MARGIN studs to spare, and
--     ignores POIs, champions and loot outside it; outside the current circle,
--     getting in beats everything (even fleeing). The squad leader drifts to the
--     circle's centre.
--   * Squad pings: view.ping (or brain:setPing) = {x, z, kind?, t?, untilT?}. While
--     it is live (untilT, else t + PING_TTL) a bot goes to the ping before POIs,
--     champions and its leash; kind "danger" / "retreat" makes it keep PING_AVOID
--     away instead; kind "enemy" / "attack" makes it fight a foe near the ping (any
--     stage, never a stage-1 rookie). Other kinds (go, champion, loot, extract,
--     stay, help) mean "go there".
--   * Rookie Run: foes with rookie = true (world:getPlayers().rookie) are never
--     picked as targets in stage 1 (view.stage <= 1 or no stage).
--   * Alternate abilities: BotBrain.new(id, classId, rng, ability?) or
--     brain:setAbility(abilityDef) uses the equipped ability's kind / area / range.
--   * (iteration 5, A3) Ability slots: brain:setAbilities({AbilityDef}) (slot order,
--     Run/Stats.compute's 4th result). view.self.abilityReadySlots[k] says whether slot
--     k is ready (slot 1 also reads view.self.abilityReady). The brain checks slot 1
--     first, then 2, 3, and casts the first ready slot with a target: intent.ability =
--     {x, z, slot} (slot 1..3; pass it to world:useAbility's 5th argument).
-- Pure helpers for the server: chooseSwap (gear swap offers), chooseCartItem
-- (Shop Cart), chooseVote(kind = "extract", ..., ctx) for the extraction choice.

local Rng = require("../Util/Rng")
local Types = require("../Types")
local Classes = require("../Config/Classes")
local PoiDefs = require("../Config/Pois")
local GearDefs = require("../Config/Gear")

type Rng = Rng.Rng
type EnemySnap = Types.EnemySnap
type UpgradeDef = Types.UpgradeDef

export type SelfView = {
	x: number,
	z: number,
	hp: number,
	maxHp: number,
	downed: boolean,
	abilityReady: boolean,
	abilityReadySlots: { boolean }?, -- (iteration 5) per slot, slot order (index 1 = abilityReady)
	squad: number?, -- v2: enables squad behaviour
	gear: { [string]: any }?, -- v2: world:gearOf(id)
	lastHitBy: number?, -- v2: hero who last hit this bot...
	lastHitAt: number?, -- ...and when (world clock)
	canSecondWind: boolean?, -- iteration 1: false = no Second Wind left (default: may use it)
	anchored: boolean?, -- (iteration 7) Dig In: rooted (world:getPlayer().anchored)
}
export type AllyView = {
	id: number,
	x: number,
	z: number,
	downed: boolean,
	isBot: boolean,
	squad: number?, -- v2
	protected: boolean?, -- v2 spawn protection (not worth shooting)
	rookie: boolean?, -- v4 Rookie Run: never a bot target up to ROOKIE_STAGES
	rookieSquad: boolean?, -- iteration 1: a rookie's squad (no bot target up to ROOKIE_SQUAD_STAGES)
	botSafe: boolean?, -- iteration 3: revived / redeployed in the last 10 s (no bot target)
	botFocus: number?, -- iteration 3: the enemy bot already hitting this human
	humanSquad: boolean?, -- iteration 4: a squad with a human (not hunted in BOT_ONLY_HUNT_STAGES)
	hpFrac: number?, -- (iteration 7) hp / maxHp (Elephaid bots tether the lowest)
	lastHitBy: number?, -- v2: hero who last hit this participant...
	lastHitAt: number?, -- ...and when (world clock)
}
export type PickupView = { x: number, z: number }
export type Obstacle = { x: number, z: number, r: number }
-- world:pois() entries (extra fields are ignored)
export type PoiView = {
	id: number,
	kind: string,
	x: number,
	z: number,
	r: number,
	state: string, -- "idle" | "active" | "done"
	progress: number?,
	active: boolean, -- the waves are running
	mode: string?, -- "channel" | "camp" | "hazard"
}
export type PortalView = { x: number, z: number, phase: string }
export type View = {
	self: SelfView,
	allies: { AllyView },
	enemies: { EnemySnap },
	pickups: { PickupView }?,
	arenaRadius: number,
	obstacles: { Obstacle }?,
	now: number,
	pois: { PoiView }?,
	portal: PortalView?,
	foes: { AllyView }?, -- v2: enemy-squad heroes (else derived from allies by squad)
	gear: { { id: number, x: number, z: number, item: any } }?, -- v2 world:groundItems()
	bags: { { id: number, x: number, z: number } }?, -- v2 world:lootBags()
	stage: number?, -- v2 PvP pacing (world:stageClock): the stage number...
	waveTime: number?, -- ...and seconds since its waves started (nil = no pacing)
	zone: ZoneView?, -- v4 storm: world:zone()
	ping: PingView?, -- v4: the squad's latest ping (overrides brain:setPing)
	builds: { BuildView }?, -- (iteration 6) world:builds(): turrets / barricades (Tinkerphant)
}
export type BuildView = {
	id: number,
	kind: string,
	owner: number,
	squad: number?,
	x: number,
	z: number,
	hpFrac: number,
	untilT: number?,
}
export type ZoneView = { cx: number, cz: number, radius: number?, r: number?, toR: number? }
export type PingView = { x: number, z: number, kind: string?, t: number?, untilT: number? }
export type Intent = {
	moveX: number,
	moveZ: number,
	speedFrac: number,
	ability: { x: number, z: number, slot: number? }?, -- (iteration 5) slot: 1..3 (nil = 1)
	secondWind: boolean?, -- iteration 1: downed and alone: use Second Wind now
}

local BotBrain = {}
BotBrain.__index = BotBrain

-- Tunables ----------------------------------------------------------------------------
BotBrain.KITE_RADIUS = 14 -- ranged classes keep mice at least this far
BotBrain.MELEE_KITE_RADIUS = 7 -- melee classes need to stay close to hit
BotBrain.LEASH = 25 -- stay within this of the nearest human
BotBrain.REVIVE_STAND = 6 -- stand this close to revive (World.REVIVE_RANGE is 8)
BotBrain.REVIVE_DANGER = 6 -- this many mice near the downed ally = not safe
BotBrain.REVIVE_DANGER_RADIUS = 10
BotBrain.PICKUP_RADIUS = 18
BotBrain.EDGE_MARGIN = 8
BotBrain.OBSTACLE_MARGIN = 4
BotBrain.SEPARATION = 4
BotBrain.LOW_HP = 0.5 -- below this: kite wider, flee enemy heroes (was 0.35)
BotBrain.ABILITY_CLUSTER = 5 -- cast when this many mice are in the ability's area
BotBrain.BOSS_KIND = 200 -- EnemySnap.kind >= 200 is a boss
BotBrain.BOSS_NEAR = 6 -- extra studs added to the ability reach for bosses
BotBrain.MAX_CANDIDATES = 32 -- cluster search cost cap
BotBrain.ENGAGE_FACTOR = 1.6 -- close in on a boss farther than kiteRadius x this...
BotBrain.ENGAGE_MIN = 10 -- ...but never closer than this
BotBrain.ENGAGE_WEIGHT = 1.4
BotBrain.VOTE_SURPRISE = 0.15 -- ROUTE votes only: chance of the next card when no human voted
BotBrain.POI_SEEK = 70 -- walk to a POI this close (v3 big maps: was 45)...
BotBrain.POI_LEASH = 60 -- ...that is also this close to the nearest human (was 40)
BotBrain.POI_MIN_HP = 0.45 -- below this a bot does not go POI hunting
BotBrain.POI_DANGER = 6 -- this many mice near a POI = not safe
BotBrain.POI_DANGER_RADIUS = 10
BotBrain.POI_COMMIT = 0.5 -- a channel past this is finished even if it got busy
BotBrain.POI_WEIGHT = 2
BotBrain.CAMP_MIN_HP = 0.8 -- wake an Elite Camp only this healthy...
BotBrain.CAMP_MAX_MICE = 3 -- ...with at most this many mice around
BotBrain.HAZARD_MARGIN = 3 -- keep this far outside a Mousetrap Field
-- v2 squads
BotBrain.HERO_ENGAGE = 18 -- fight an enemy hero this close (GDD-v2 §2)
-- PvP pacing (GDD-v2 §2): no hunting enemy heroes in the first CALM_SECONDS of the
-- first CALM_STAGES stages (self-defence only), and a shorter engage range (a higher
-- aggression threshold) for the first EARLY_SECONDS of every stage's waves.
BotBrain.CALM_STAGES = 1
BotBrain.CALM_SECONDS = 88 -- iteration 4: x1.35 maps; stage-1 hunting only in the last stretch (was 75)
BotBrain.EARLY_SECONDS = 75
BotBrain.EARLY_HERO_ENGAGE = 9
BotBrain.EARLY_DEFEND_RANGE = 24 -- early: chase a squad attacker only this far
-- Aggression ramps with the stage (index = stage; past the end = the last entry):
-- the engage range for hunting enemy heroes and the range to chase a squad attacker.
BotBrain.HERO_ENGAGE_BY_STAGE = { 12, 24, 44 } -- iteration 4: x1.35 maps; stage 1 hunts after CALM_SECONDS (was 0 / 13 / 32)
BotBrain.DEFEND_RANGE_BY_STAGE = { 12, 34, 74 } -- iteration 4: x1.35 maps (was 12 / 25 / 55)
BotBrain.DRIFT_FRAC = 0.35 -- a squad leader with no goal drifts inside this x arena radius...
BotBrain.EARLY_DRIFT_FRAC = 0.7 -- ...but only inside this one while early / calm (farm your side)
BotBrain.CALM_AVOID = 30 -- calm: steer away from enemy heroes this close...
BotBrain.CALM_AVOID_WEIGHT = 1.2 -- ...this hard
BotBrain.SQUAD_ATTACK_MEMORY = 4 -- s: a foe who hit our squad this recently is fair game...
BotBrain.SQUAD_ATTACK_RANGE = 45 -- ...if it is this close
BotBrain.FIGHT_RANGE = 12 -- ranged bots hold this distance to a foe
BotBrain.MELEE_FIGHT_RANGE = 4
BotBrain.FIGHT_WEIGHT = 2.2
BotBrain.FLEE_RADIUS = 28 -- low-HP bots flee foes this close
BotBrain.FLEE_WEIGHT = 3.5
BotBrain.GEAR_SEEK = 30 -- walk to ground gear / loot bags this close
BotBrain.GEAR_WEIGHT = 1.8
BotBrain.EXTRACT_POT = 260 -- bot-only squads extract with this much pending cheese (v3: was 220;
-- champion, vault and cache cheese make pots about 2x bigger)...
BotBrain.EXTRACT_HP = 0.3 -- ...or when the squad's average HP is below this (stage 3+ only:
-- every stage starts at full HP, so post-boss HP says little early on)
BotBrain.EXTRACT_HP_FROM_STAGE = 3
-- v3 Mouse Champions
BotBrain.CHAMP_KIND = 100 -- EnemySnap.kind in [CHAMP_KIND, BOSS_KIND) is a champion
BotBrain.CHAMP_CLONE_FLAG = 8 -- flags bit 3: a Mad Chemist clone (not worth hunting)
BotBrain.CHAMP_MIN_HP = 0.65 -- a leader hunts champions only this healthy...
BotBrain.CHAMP_SEEK = 1000 -- ...that are this close (the whole map)
BotBrain.CHAMP_WEIGHT = 1.8 -- pull toward the hunted champion
BotBrain.CHAMP_ENGAGE = 45 -- any healthy bot closes in on a champion this close
-- v4 The Melt, pings, rookies
BotBrain.ZONE_MARGIN = 45 -- keep this far inside the next storm circle (iteration 4: x1.35 maps; was 15)
BotBrain.ZONE_WEIGHT = 2.5 -- pull back inside the next circle...
BotBrain.ZONE_OUTSIDE_WEIGHT = 8 -- ...and this hard when outside the current one
BotBrain.PING_TTL = 12 -- s a ping without untilT stays live
BotBrain.PING_ARRIVE = 6 -- close enough to a "go" ping
BotBrain.PING_WEIGHT = 2.6
BotBrain.PING_AVOID = 35 -- "danger" pings: keep this far away
BotBrain.PING_ATTACK_RADIUS = 20 -- "attack" pings: fight a foe this close to the ping
BotBrain.ROOKIE_STAGES = 3 -- rookies are not bot targets up to this stage (iteration 3: was 2)...
BotBrain.BOT_ONLY_HUNT_STAGES = 1 -- iteration 4: in these stages bots hunt only all-bot squads (self-defence still applies)
BotBrain.HUMAN_MATES_HOLD = true -- iteration 4: in those stages a human's bot squadmates do not hunt at all
BotBrain.ROOKIE_SQUAD_STAGES = 2 -- ...nor their squadmates up to this one (foe.rookieSquad; was 1)
BotBrain.ROOKIE_REVIVE_WEIGHT = 5 -- a rookie's bot squadmates rush to revive it (normal 2.5)
BotBrain.ROOKIE_REVIVE_RANGE = 70 -- ...from this far
BotBrain.SECOND_WIND_ALONE = 10 -- downed with no standing squadmate this close: use Second Wind
-- Iteration 1 route gamble (PLAN §C, C-1): bot-only route votes pick a tier by weight
-- (Low, Mid, High); stage 1 always Low; low squad HP shifts toward Low.
BotBrain.ROUTE_WEIGHTS = { { 1, 0, 0 }, { 50, 40, 10 }, { 35, 45, 20 } } -- by stage (past the end: the last)
BotBrain.ROUTE_LOW_HP = 0.5 -- squad HP below this...
BotBrain.ROUTE_LOW_HP_WEIGHTS = { 80, 20, 0 } -- ...uses these
BotBrain.ROUTE_NO_WINNER = { 50, 35, 15 } -- BotBrain.randomRoute (RunDirector: no squad won the boss)
-- Ping kinds (RunDirector.PING_KINDS: go, enemy, champion, loot, extract, stay, help):
-- these fight a foe near the ping, these keep away; every other kind means "go there".
BotBrain.PING_ATTACK = table.freeze({ enemy = true, attack = true }) :: { [string]: boolean }
BotBrain.PING_AVOID_KINDS = table.freeze({ danger = true, retreat = true }) :: { [string]: boolean }

local RARITY_RANK: { [string]: number } = { Common = 1, Rare = 2, Epic = 3, Legendary = 4 }

-- Self-centred abilities hit around the caster; aimed ones land at the aim point.
local SELF_CENTRED: { [string]: boolean } = { ring = true, shield = true, hover = true }
-- (iteration 6, team Builder) kind -> aim function for Tinkerphant abilities (defined below)
local BUILD_AIM: { [string]: (any, any, any, number, number) -> { x: number, z: number }? }

-- (iteration 7, team Classes) kind -> aim function for the new kinds (defined below)
local CLASS7_AIM: { [string]: (any, any, any, number, number) -> { x: number, z: number }? }

-- (iteration 5) What the brain needs to know of an equipped ability.
export type SlotAbility = { kind: string, area: number, range: number }
BotBrain.MAX_SLOTS = 4 -- (iteration 6) slot 4

export type Brain = typeof(setmetatable(
	{} :: {
		id: number,
		classId: string,
		rng: Rng,
		abilityKind: string,
		abilityArea: number,
		abilityRange: number,
		slotAbilities: { [number]: SlotAbility }, -- (iteration 5) slots 2+ (slot 1: ability* fields)
		kiteRadius: number,
		fightRange: number,
		wanderAngle: number,
		dirX: number,
		dirZ: number,
		ping: PingView?,
	},
	BotBrain
))

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function BotBrain.new(id: number, classId: string, rng: Rng, ability: any?): Brain
	local def = (Classes :: any).get(classId)
	local weapon = def and def.weapon
	if type(ability) ~= "table" then
		ability = def and def.ability
	end
	local kind = if ability and type(ability.kind) == "string" then ability.kind else "burst"
	local area = if ability and finite(ability.area) and ability.area > 0 then ability.area else 8
	local range = if ability and finite(ability.distance) then ability.distance else 0
	local melee = weapon ~= nil
		and (weapon.kind == "melee_arc" or weapon.kind == "orbit" or weapon.kind == "cone")
	return setmetatable({
		id = id,
		classId = classId,
		rng = rng,
		abilityKind = kind,
		abilityArea = area,
		abilityRange = range,
		slotAbilities = {},
		kiteRadius = if melee then BotBrain.MELEE_KITE_RADIUS else BotBrain.KITE_RADIUS,
		fightRange = if melee then BotBrain.MELEE_FIGHT_RANGE else BotBrain.FIGHT_RANGE,
		wanderAngle = rng:range(0, math.pi * 2),
		dirX = 0,
		dirZ = 0,
		ping = nil,
	}, BotBrain)
end

-- v4: the ability the bot really has equipped (a ClassAbilities alternate).
function BotBrain.setAbility(self: Brain, ability: any)
	if type(ability) ~= "table" then
		return
	end
	if type(ability.kind) == "string" then
		self.abilityKind = ability.kind
	end
	self.abilityArea = if finite(ability.area) and ability.area > 0 then ability.area else self.abilityArea
	self.abilityRange = if finite(ability.distance) then ability.distance else 0
end

-- (iteration 5) Every equipped ability in slot order: slot 1 as setAbility, slots 2+
-- are cast when their view.self.abilityReadySlots entry is true.
function BotBrain.setAbilities(self: Brain, abilities: any)
	if type(abilities) ~= "table" then
		return
	end
	self:setAbility(abilities[1])
	local slots: { [number]: SlotAbility } = {}
	for k = 2, BotBrain.MAX_SLOTS do
		local a = abilities[k]
		if type(a) ~= "table" or type(a.kind) ~= "string" then
			break
		end
		slots[k] = {
			kind = a.kind,
			area = if finite(a.area) and a.area > 0 then a.area else 8,
			range = if finite(a.distance) then a.distance else 0,
		}
	end
	self.slotAbilities = slots
end

-- v4 squad ping (RunDirector / BotService on a Ping remote): {x, z, kind?, t?, untilT?}; nil clears.
function BotBrain.setPing(self: Brain, ping: PingView?)
	self.ping = ping
end

-- The live ping for this view (view.ping first), or nil.
function BotBrain._livePing(self: Brain, view: View): PingView?
	local p = view.ping or self.ping
	if not p or not finite(p.x) or not finite(p.z) then
		return nil
	end
	local now = view.now
	if finite(p.untilT) then
		return if now <= (p.untilT :: number) then p else nil
	end
	if finite(p.t) then
		return if now - (p.t :: number) <= BotBrain.PING_TTL then p else nil
	end
	return p
end

-- v4 storm: (cx, cz, current radius, safe radius = next circle - margin), or nil.
function BotBrain.zoneOf(view: View): (number?, number?, number?, number?)
	local z = view.zone
	if not z or not finite(z.cx) or not finite(z.cz) then
		return nil
	end
	local r = if finite(z.radius) then z.radius :: number elseif finite(z.r) then z.r :: number else nil
	if not r then
		return nil
	end
	local nextR = if finite(z.toR) then math.min(r, z.toR :: number) else r
	local safe = math.max(nextR - BotBrain.ZONE_MARGIN, nextR * 0.5)
	return z.cx, z.cz, r, safe
end

-- Is (x, z) inside the next circle (with the margin)? True without a storm.
function BotBrain.inZone(view: View, x: number, z: number): boolean
	local cx, cz, _, safe = BotBrain.zoneOf(view)
	if cx == nil then
		return true
	end
	return (x - cx) ^ 2 + (z - (cz :: number)) ^ 2 <= (safe :: number) ^ 2
end

local function rookieSafe(view: View, f: AllyView, myId: number?): boolean
	-- iteration 3 T-4: freshly revived heroes, and a human another bot is already on
	if f.botSafe == true then
		return true
	end
	if not f.isBot and f.botFocus ~= nil and f.botFocus ~= myId then
		return true
	end
	local st = if finite(view.stage) then view.stage :: number else 1
	if f.rookie == true and st <= BotBrain.ROOKIE_STAGES then
		return true
	end
	return f.rookieSquad == true and st <= BotBrain.ROOKIE_SQUAD_STAGES
end
BotBrain.rookieSafe = rookieSafe

local function len(x: number, z: number): number
	return math.sqrt(x * x + z * z)
end

-- A boss or a Mouse Champion body (both are fought, kited and ability targets).
local function isBig(e: any): boolean
	return e.kind >= BotBrain.CHAMP_KIND
end

-- A Mouse Champion worth hunting (not a boss, not a Chemist clone).
local function isChampion(e: any): boolean
	return e.kind >= BotBrain.CHAMP_KIND
		and e.kind < BotBrain.BOSS_KIND
		and math.floor((e.flags or 0) / BotBrain.CHAMP_CLONE_FLAG) % 2 == 0
end
BotBrain.isChampion = isChampion

local function nearest<T>(list: { T }, x: number, z: number, filter: ((T) -> boolean)?): (T?, number)
	local best: T? = nil
	local bestD = math.huge
	for _, item in list do
		local it = item :: any
		if not filter or filter(item) then
			local d = len(it.x - x, it.z - z)
			if d < bestD then
				best, bestD = item, d
			end
		end
	end
	return best, bestD
end

-- Best point to aim an area ability: (x, z, enemiesInArea, bossNear).
function BotBrain.densestCluster(
	enemies: { EnemySnap },
	sx: number,
	sz: number,
	reach: number,
	area: number
): (number, number, number)
	local candidates: { EnemySnap } = {}
	for _, e in enemies do
		if len(e.x - sx, e.z - sz) <= reach then
			table.insert(candidates, e)
		end
	end
	if #candidates == 0 then
		return sx, sz, 0
	end
	-- Evenly sample the candidates so a full horde stays cheap.
	local stride = math.max(1, math.ceil(#candidates / BotBrain.MAX_CANDIDATES))
	local bestX, bestZ, bestN = candidates[1].x, candidates[1].z, 0
	local a2 = area * area
	for i = 1, #candidates, stride do
		local c = candidates[i]
		local n, cx, cz = 0, 0, 0
		for _, e in enemies do
			if (e.x - c.x) ^ 2 + (e.z - c.z) ^ 2 <= a2 then
				n += 1
				cx += e.x
				cz += e.z
			end
		end
		if n > bestN then
			bestN = n
			bestX, bestZ = cx / n, cz / n
		end
	end
	return bestX, bestZ, bestN
end

-- (iteration 6, team Builder) Tinkerphant: where to put a turret / barricade, when to
-- Repair Pulse. Builds come from view.builds (world:builds()) when BotService sends them.
BotBrain.TURRET_MICE = 3 -- deploy a turret when this many mice are within its range...
BotBrain.TURRET_AHEAD = 6 -- ...this far toward them (it covers the bot)
BotBrain.TURRET_KEEP = 6 -- don't replace a turret with more than this many s left (both up)
BotBrain.BARRICADE_MICE = 5 -- a wall when this many mice are within BARRICADE_NEAR...
BotBrain.BARRICADE_NEAR = 18
BotBrain.BARRICADE_AHEAD = 7 -- ...this far toward them
BotBrain.REPAIR_HP = 0.7 -- Repair Pulse below this HP share, or an own build below...
BotBrain.REPAIR_BUILD = 0.6 -- ...this HP share in reach

local function myBuilds(self: Brain, view: View, kind: string): { BuildView }
	local out = {}
	for _, b in view.builds or {} do
		if b.owner == self.id and b.kind == kind then
			table.insert(out, b)
		end
	end
	return out
end

local function toward(me: SelfView, x: number, z: number, dist: number): { x: number, z: number }
	local dx, dz = x - me.x, z - me.z
	local d = len(dx, dz)
	if d < 1e-3 then
		return { x = me.x + dist, z = me.z }
	end
	local k = math.min(dist, d)
	return { x = me.x + dx / d * k, z = me.z + dz / d * k }
end

BUILD_AIM = {
	turret = function(self: Brain, view: View, foe: AllyView?, area: number, range: number)
		local me = view.self
		local mine = myBuilds(self, view, "turret")
		if #mine >= 2 then
			local oldest = math.huge
			for _, b in mine do
				oldest = math.min(oldest, (b.untilT or 0) - view.now)
			end
			if oldest > BotBrain.TURRET_KEEP then
				return nil
			end
		end
		local reach = math.max(area, 20)
		local boss, bossD = nearest(view.enemies, me.x, me.z, function(e: EnemySnap)
			return isBig(e)
		end)
		if boss and bossD <= reach then
			return toward(me, boss.x, boss.z, math.min(range, BotBrain.TURRET_AHEAD + 2))
		end
		if foe and not foe.downed and len(foe.x - me.x, foe.z - me.z) <= reach then
			return toward(me, foe.x, foe.z, BotBrain.TURRET_AHEAD)
		end
		local x, z, n = BotBrain.densestCluster(view.enemies, me.x, me.z, reach, 10)
		if n >= BotBrain.TURRET_MICE then
			return toward(me, x, z, math.min(range, BotBrain.TURRET_AHEAD))
		end
		return nil
	end,
	barricade = function(_self: Brain, view: View, foe: AllyView?, _area: number, range: number)
		local me = view.self
		local x, z, n = BotBrain.densestCluster(
			view.enemies,
			me.x,
			me.z,
			BotBrain.BARRICADE_NEAR,
			BotBrain.BARRICADE_NEAR * 0.6
		)
		if n >= BotBrain.BARRICADE_MICE then
			return toward(me, x, z, math.min(range, BotBrain.BARRICADE_AHEAD))
		end
		-- a chasing enemy hero while hurt: wall it off
		if
			foe
			and not foe.downed
			and me.maxHp > 0
			and me.hp / me.maxHp < 0.5
			and len(foe.x - me.x, foe.z - me.z) <= 14
		then
			return toward(me, foe.x, foe.z, 4)
		end
		return nil
	end,
	repair = function(self: Brain, view: View, _foe: AllyView?, area: number, _range: number)
		local me = view.self
		if me.maxHp > 0 and me.hp / me.maxHp < BotBrain.REPAIR_HP then
			return { x = me.x, z = me.z }
		end
		for _, b in view.builds or {} do
			if
				b.owner == self.id
				and b.hpFrac < BotBrain.REPAIR_BUILD
				and len(b.x - me.x, b.z - me.z) <= area
			then
				return { x = me.x, z = me.z }
			end
		end
		return nil
	end,
} :: { [string]: (Brain, View, AllyView?, number, number) -> { x: number, z: number }? }

-- (iteration 7, team Classes) Ele Vation / Elephaid / Trunkillery ----------------------------
BotBrain.LANCE_MICE = 3 -- Long Shot: cast through a line with this many mice...
BotBrain.LANCE_CANDIDATES = 40 -- ...trying the directions to this many of the nearest
BotBrain.TETHER_HP = 0.75 -- Lifeline a squadmate below this HP share...
BotBrain.TETHER_SELF_HP = 0.55 -- ...or yourself below this one with nobody to link
BotBrain.ANCHOR_MICE = 8 -- Dig In with this many mice within ANCHOR_SCAN...
BotBrain.ANCHOR_SCAN = 50
BotBrain.ANCHOR_FOE = 25 -- ...and no enemy hero this close
BotBrain.ANCHOR_MATE = 14 -- ...and a standing squadmate this close (when it has any)
BotBrain.UNROOT_HP = 0.4 -- dig out (recast) under this HP share
BotBrain.STEADY_CLEAR = 15 -- Ele Vation stands still to shoot with no mouse this close
BotBrain.STEADY_SCAN = 60 -- ...and a target within this range
BotBrain.STEADY_HOLD = false -- PROBE

-- Mice inside the line from (x, z) along (dx, dz).
local function inLine(
	enemies: { EnemySnap },
	x: number,
	z: number,
	dx: number,
	dz: number,
	length: number,
	halfW: number
): number
	local c = 0
	for _, e in enemies do
		local ex, ez = e.x - x, e.z - z
		local along = ex * dx + ez * dz
		if along >= 0 and along <= length and math.abs(ex * dz - ez * dx) <= halfW then
			c += 1
		end
	end
	return c
end
BotBrain.inLine = inLine

CLASS7_AIM = {
	lance = function(_self: Brain, view: View, foe: AllyView?, area: number, range: number)
		local me = view.self
		local length = math.max(range, 30)
		if foe and not foe.downed and len(foe.x - me.x, foe.z - me.z) <= length then
			return { x = foe.x, z = foe.z }
		end
		local boss, bossD = nearest(view.enemies, me.x, me.z, function(e: EnemySnap)
			return isBig(e)
		end)
		if boss and bossD <= length then
			return { x = boss.x, z = boss.z }
		end
		local halfW = math.max(area, 1.5) + 1
		local best, bestN = nil, 0
		local tried = 0
		for _, e in view.enemies do
			local d = len(e.x - me.x, e.z - me.z)
			if d > 1 and d <= length then
				tried += 1
				local n = inLine(view.enemies, me.x, me.z, (e.x - me.x) / d, (e.z - me.z) / d, length, halfW)
				if n > bestN then
					best, bestN = e, n
				end
				if tried >= BotBrain.LANCE_CANDIDATES then
					break
				end
			end
		end
		if best and bestN >= BotBrain.LANCE_MICE then
			return { x = best.x, z = best.z }
		end
		return nil
	end,
	tether = function(self: Brain, view: View, _foe: AllyView?, _area: number, range: number)
		local me = view.self
		local reach = math.max(range, 10)
		local pick, pickF = nil, BotBrain.TETHER_HP
		for _, a in view.allies do
			if a.id ~= self.id and (me.squad == nil or a.squad == me.squad) then
				local d = len(a.x - me.x, a.z - me.z)
				if d <= reach then
					if a.downed then
						return { x = a.x, z = a.z } -- an ascended link revives; a plain one is harmless
					end
					local f = a.hpFrac
					if f and f < pickF then
						pick, pickF = a, f
					end
				end
			end
		end
		if pick then
			return { x = pick.x, z = pick.z }
		end
		if me.maxHp > 0 and me.hp / me.maxHp < BotBrain.TETHER_SELF_HP then
			return { x = me.x, z = me.z }
		end
		return nil
	end,
	anchor = function(self: Brain, view: View, foe: AllyView?, _area: number, _range: number)
		local me = view.self
		local hpf = if me.maxHp > 0 then me.hp / me.maxHp else 1
		-- never root away from the squad (a rooted hero picks up no crumbs and leaves the leash)
		local mates, near = 0, false
		for _, a in view.allies do
			if a.id ~= self.id and me.squad ~= nil and a.squad == me.squad and not a.downed then
				mates += 1
				if len(a.x - me.x, a.z - me.z) <= BotBrain.ANCHOR_MATE then
					near = true
				end
			end
		end
		local alone = mates > 0 and not near
		if me.anchored then
			-- dig out when low or when the squad has moved on
			return if hpf < BotBrain.UNROOT_HP or alone then { x = me.x, z = me.z } else nil
		end
		if hpf < BotBrain.UNROOT_HP or alone then
			return nil
		end
		if foe and not foe.downed and len(foe.x - me.x, foe.z - me.z) <= BotBrain.ANCHOR_FOE then
			return nil
		end
		local n = 0
		for _, e in view.enemies do
			if len(e.x - me.x, e.z - me.z) <= BotBrain.ANCHOR_SCAN then
				n += 1
				if n >= BotBrain.ANCHOR_MICE then
					return { x = me.x, z = me.z }
				end
			end
		end
		return nil
	end,
} :: { [string]: (Brain, View, AllyView?, number, number) -> { x: number, z: number }? }

-- Ele Vation: stand still to shoot (Steady Trunk) while nothing is close, she is inside
-- the storm circle, nobody needs a revive and something is in range.
function BotBrain._steadyHold(self: Brain, view: View): boolean
	local me = view.self
	if not BotBrain.STEADY_HOLD or self.classId ~= "ele_vation" or me.downed then
		return false
	end
	if me.maxHp > 0 and me.hp / me.maxHp < BotBrain.LOW_HP then
		return false
	end
	if not BotBrain.inZone(view, me.x, me.z) then
		return false
	end
	for _, a in view.allies do
		if a.downed and a.id ~= self.id and (me.squad == nil or a.squad == me.squad) then
			return false
		end
	end
	local any = false
	for _, e in view.enemies do
		local d = len(e.x - me.x, e.z - me.z)
		if d <= BotBrain.STEADY_CLEAR then
			return false
		end
		if d <= BotBrain.STEADY_SCAN then
			any = true
		end
	end
	return any
end
-- (end iteration 7, team Classes)

-- (iteration 5) The first ready slot with a target: {x, z, slot}.
function BotBrain._ability(self: Brain, view: View, foe: AllyView?): { x: number, z: number, slot: number? }?
	local me = view.self
	if me.downed then
		return nil
	end
	local ready = me.abilityReadySlots
	-- (iteration 7) a dug-in Trunkillery can always recast Dig In to dig out (no cooldown)
	if me.anchored and self.abilityKind == "anchor" and not me.abilityReady then
		local aim = self:_abilityAim(view, foe, "anchor", self.abilityArea, self.abilityRange)
		if aim then
			return { x = aim.x, z = aim.z, slot = 1 }
		end
	end
	if me.abilityReady then
		local aim = self:_abilityAim(view, foe, self.abilityKind, self.abilityArea, self.abilityRange)
		if aim then
			return { x = aim.x, z = aim.z, slot = 1 }
		end
	end
	if type(ready) == "table" then
		for k = 2, BotBrain.MAX_SLOTS do
			local sa = self.slotAbilities[k]
			if sa and ready[k] == true then
				local aim = self:_abilityAim(view, foe, sa.kind, sa.area, sa.range)
				if aim then
					return { x = aim.x, z = aim.z, slot = k }
				end
			end
		end
	end
	return nil
end

-- Where to cast an ability of this kind / area / range now (nil = hold it).
function BotBrain._abilityAim(
	self: Brain,
	view: View,
	foe: AllyView?,
	kind: string,
	area: number,
	range: number
): { x: number, z: number }?
	local me = view.self
	if BUILD_AIM[kind] then
		return BUILD_AIM[kind](self, view, foe, area, range) -- (iteration 6, team Builder)
	end
	if CLASS7_AIM[kind] then
		return CLASS7_AIM[kind](self, view, foe, area, range) -- (iteration 7, team Classes)
	end
	-- (iteration 7) dug in: a leap / dash would dig out; keep it for the escape (low HP)
	if
		me.anchored
		and (kind == "leap" or kind == "dash")
		and me.maxHp > 0
		and me.hp / me.maxHp >= BotBrain.UNROOT_HP
	then
		return nil
	end
	local selfCentred = SELF_CENTRED[kind] == true
	local reach = if selfCentred then area else math.max(range, area)
	-- v2: an engaged enemy hero in reach is the best target
	if foe and not foe.downed and len(foe.x - me.x, foe.z - me.z) <= reach + 1 then
		return { x = foe.x, z = foe.z }
	end
	local enemies = view.enemies
	if #enemies == 0 then
		return nil
	end

	-- A boss (or a Mouse Champion) within reach: always worth it.
	local boss, bossD = nearest(enemies, me.x, me.z, function(e: EnemySnap)
		return isBig(e)
	end)
	if boss and bossD <= reach + BotBrain.BOSS_NEAR then
		return { x = boss.x, z = boss.z }
	end

	if selfCentred then
		local n, cx, cz = 0, 0, 0
		for _, e in enemies do
			if len(e.x - me.x, e.z - me.z) <= area then
				n += 1
				cx += e.x
				cz += e.z
			end
		end
		if n >= BotBrain.ABILITY_CLUSTER then
			return { x = cx / n, z = cz / n }
		end
		return nil
	end

	local x, z, n = BotBrain.densestCluster(enemies, me.x, me.z, reach, area)
	if n >= BotBrain.ABILITY_CLUSTER then
		return { x = x, z = z }
	end
	-- Dash: also an escape when low and surrounded.
	if kind == "dash" and me.maxHp > 0 and me.hp / me.maxHp < BotBrain.LOW_HP then
		local close = 0
		for _, e in enemies do
			if len(e.x - me.x, e.z - me.z) <= 6 then
				close += 1
			end
		end
		if close >= 3 and (self.dirX ~= 0 or self.dirZ ~= 0) then
			return { x = me.x + self.dirX * 20, z = me.z + self.dirZ * 20 }
		end
	end
	return nil
end

-- The POI worth walking to right now, or nil (see the header for the rules).
function BotBrain._poiTarget(
	self: Brain,
	view: View,
	hpFrac: number,
	enemies: { EnemySnap },
	allies: { AllyView },
	anchor: AllyView?,
	roam: boolean?
): PoiView?
	local pois = view.pois
	if not pois or #pois == 0 then
		return nil
	end
	local me = view.self
	local mySquad = me.squad
	local human = anchor
	if not human and not roam then
		human = nearest(allies, me.x, me.z, function(a: AllyView)
			return not a.isBot and a.id ~= self.id and not a.downed
		end)
	end
	local someoneDown = false
	for _, a in allies do
		if a.downed then
			someoneDown = true
			break
		end
	end
	local function miceNear(p: PoiView, r: number): number
		local n = 0
		for _, e in enemies do
			if len(e.x - p.x, e.z - p.z) <= r then
				n += 1
			end
		end
		return n
	end
	local best: PoiView? = nil
	local bestD = math.huge
	local bestCamp: PoiView? = nil
	local bestCampD = math.huge
	for _, p in pois do
		if not p.active or p.state == "done" or not finite(p.x) or not finite(p.z) then
			continue
		end
		local def = PoiDefs.get(p.kind)
		if not def then
			continue
		end
		local d = len(p.x - me.x, p.z - me.z)
		if d > BotBrain.POI_SEEK or not BotBrain.inZone(view, p.x, p.z) then
			continue
		end
		if human and len(p.x - human.x, p.z - human.z) > BotBrain.POI_LEASH then
			continue
		end
		local mode = p.mode or def.mode
		local pp = p :: any
		if mode == "totem" then
			-- capture it, or defend it while someone else drains it
			local mine = mySquad ~= nil and pp.owner == mySquad
			local threatened = pp.contested == true or (pp.capSquad ~= nil and pp.capSquad ~= mySquad)
			if
				(not mine or threatened or (p.progress or 0) < 1)
				and hpFrac >= BotBrain.POI_MIN_HP
				and d < bestD
			then
				best, bestD = p, d
			end
			continue
		elseif mode == "cart" then
			continue -- RunDirector shops for bots (BotBrain.chooseCartItem)
		end
		if mode == "channel" then
			if def.reward == "revive" and not someoneDown then
				continue
			end
			local committed = (p.progress or 0) >= BotBrain.POI_COMMIT and d <= p.r
			local safe = hpFrac >= BotBrain.POI_MIN_HP
				and miceNear(p, BotBrain.POI_DANGER_RADIUS) < BotBrain.POI_DANGER
			if (safe or committed) and d < bestD then
				best, bestD = p, d
			end
		elseif mode == "camp" and p.state == "idle" then
			if
				hpFrac >= BotBrain.CAMP_MIN_HP
				and miceNear(p, p.r + BotBrain.POI_DANGER_RADIUS) <= BotBrain.CAMP_MAX_MICE
				and d < bestCampD
			then
				bestCamp, bestCampD = p, d
			end
		end
	end
	return best or bestCamp
end

-- (iteration 7, team Classes) think = the core brain + per-class stance rules.
function BotBrain.think(self: Brain, view: View, dt: number): Intent
	local intent = self:_thinkCore(view, dt)
	if self:_steadyHold(view) then
		intent.moveX, intent.moveZ, intent.speedFrac = 0, 0, 0
	end
	return intent
end

function BotBrain._thinkCore(self: Brain, view: View, dt: number): Intent
	local me = view.self
	local sx, sz = me.x, me.z
	local fx, fz = 0, 0
	local hpFrac = if me.maxHp > 0 then math.clamp(me.hp / me.maxHp, 0, 1) else 1
	local allies = view.allies or {}

	-- Portal pull: everyone walks into the Rind Gate.
	local portal = view.portal
	if portal and portal.phase == "pull" and finite(portal.x) and finite(portal.z) and not me.downed then
		local d = len(portal.x - sx, portal.z - sz)
		if d > 1 then
			local mx, mz = (portal.x - sx) / d, (portal.z - sz) / d
			self.dirX, self.dirZ = mx, mz
			return { moveX = mx, moveZ = mz, speedFrac = 1, ability = nil }
		end
		return { moveX = 0, moveZ = 0, speedFrac = 0, ability = nil }
	end

	-- v2: split into squad-mates and foes when the view carries squads.
	local foes: { AllyView } = view.foes or {}
	local mySquad = me.squad
	if mySquad ~= nil then
		local mates = {}
		local derive = view.foes == nil
		for _, a in allies do
			if a.squad == nil or a.squad == mySquad then
				table.insert(mates, a)
			elseif derive then
				table.insert(foes, a)
			end
		end
		allies = mates
	end

	-- Downed: crawl toward the nearest standing ally. Iteration 1: with no standing
	-- squadmate within SECOND_WIND_ALONE, ask for Second Wind (intent.secondWind;
	-- BotService calls world:useSecondWind).
	if me.downed then
		local ally, d = nearest(allies, sx, sz, function(a: AllyView)
			return not a.downed and a.id ~= self.id
		end)
		local wind = me.canSecondWind ~= false and (ally == nil or d > BotBrain.SECOND_WIND_ALONE)
		if ally and d > 2 then
			local mx, mz = (ally.x - sx) / d, (ally.z - sz) / d
			self.dirX, self.dirZ = mx, mz
			return { moveX = mx, moveZ = mz, speedFrac = 1, ability = nil, secondWind = wind }
		end
		return { moveX = 0, moveZ = 0, speedFrac = 0, ability = nil, secondWind = wind }
	end

	local enemies = view.enemies or {}

	-- v2: who leads a squad without humans (highest id; that bot roams), whom
	-- to follow, which foe to fight, and whether to flee.
	local squadMode = mySquad ~= nil
	local anchor: AllyView? = nil
	local isLeader = false
	if squadMode then
		anchor = nearest(allies, sx, sz, function(a: AllyView)
			return not a.isBot and a.id ~= self.id and not a.downed
		end)
		if not anchor then
			local leader: AllyView? = nil
			for _, a in allies do
				if not a.downed and a.id ~= self.id and (leader == nil or a.id > (leader :: AllyView).id) then
					leader = a
				end
			end
			if leader == nil or self.id > (leader :: AllyView).id then
				isLeader = true
			else
				anchor = leader
			end
		end
	end
	local foe, foeD = self:_pickFoe(view, allies, foes)
	-- v4 squad ping
	local ping = self:_livePing(view)
	local pingKind = if ping then (ping.kind or "go") else nil
	if ping and BotBrain.PING_ATTACK[pingKind] and not foe then
		local best, bestPD = nil, BotBrain.PING_ATTACK_RADIUS
		for _, f in foes do
			if not f.protected and not rookieSafe(view, f, self.id) then
				local pd = len(f.x - ping.x, f.z - ping.z)
				if pd <= bestPD then
					best, bestPD = f, pd
				end
			end
		end
		if best then
			foe, foeD = best, len(best.x - sx, best.z - sz)
		end
	end
	local fleeing = false
	if #foes > 0 and hpFrac < BotBrain.LOW_HP then
		local cx2, cz2, n2 = 0, 0, 0
		for _, f in foes do
			if not f.downed and len(f.x - sx, f.z - sz) <= BotBrain.FLEE_RADIUS then
				cx2 += f.x
				cz2 += f.z
				n2 += 1
			end
		end
		if n2 > 0 then
			fleeing = true
			cx2, cz2 = cx2 / n2, cz2 / n2
			local ax, az = sx - cx2, sz - cz2
			local d = len(ax, az)
			if d < 1e-3 then
				ax, az, d = -sx, -sz, math.max(1e-3, len(sx, sz))
			end
			fx += ax / d * BotBrain.FLEE_WEIGHT
			fz += az / d * BotBrain.FLEE_WEIGHT
			local mate, md = nearest(allies, sx, sz, function(a: AllyView)
				return a.id ~= self.id and not a.downed
			end)
			if mate and md > 4 then
				fx += (mate.x - sx) / md * 1.2
				fz += (mate.z - sz) / md * 1.2
			end
			foe = nil
		end
	end
	if foe then
		-- close to weapon range (downed foes: walk right up to finish them)
		local want = if foe.downed then 2 else self.fightRange
		if foeD > want then
			local w = BotBrain.FIGHT_WEIGHT * math.clamp((foeD - want) / 6, 0.3, 1)
			fx += (foe.x - sx) / foeD * w
			fz += (foe.z - sz) / foeD * w
		elseif foeD < want * 0.6 and foeD > 1e-3 and not foe.downed then
			fx -= (foe.x - sx) / foeD * 0.8
			fz -= (foe.z - sz) / foeD * 0.8
		end
	end

	-- v4 The Melt: stay inside the next circle; outside the current one, get in first.
	local zcx, zcz, zr, zsafe = BotBrain.zoneOf(view)
	local outsideZone = false
	if zcx ~= nil then
		local dx, dz = (zcx :: number) - sx, (zcz :: number) - sz
		local d = len(dx, dz)
		if d > (zsafe :: number) and d > 1e-3 then
			local w = BotBrain.ZONE_WEIGHT * math.clamp((d - (zsafe :: number)) / 10, 0.3, 1)
			if d > (zr :: number) then
				w = BotBrain.ZONE_OUTSIDE_WEIGHT
				outsideZone = true
			end
			fx += dx / d * w
			fz += dz / d * w
		end
	end

	-- v4 ping: go to it (or keep away from a "danger" ping)
	local followPing = false
	if ping and not fleeing and not outsideZone then
		local dx, dz = ping.x - sx, ping.z - sz
		local d = len(dx, dz)
		if BotBrain.PING_AVOID_KINDS[pingKind] then
			if d < BotBrain.PING_AVOID and d > 1e-3 then
				local w = BotBrain.PING_WEIGHT * (1 - d / BotBrain.PING_AVOID)
				fx -= dx / d * w
				fz -= dz / d * w
			end
		elseif not foe then
			followPing = true
			if d > BotBrain.PING_ARRIVE then
				local w = BotBrain.PING_WEIGHT * math.clamp((d - BotBrain.PING_ARRIVE) / 10, 0.4, 1)
				fx += dx / d * w
				fz += dz / d * w
			end
		end
	end

	-- Calm (no hunting yet): keep clear of enemy heroes, so auto-weapons that take
	-- the closest target don't start a fight nobody chose.
	if not foe and not fleeing and #foes > 0 and BotBrain.pvpRanges(view) <= 0 then
		for _, f in foes do
			local d = len(f.x - sx, f.z - sz)
			if not f.downed and d < BotBrain.CALM_AVOID and d > 1e-3 then
				local w = BotBrain.CALM_AVOID_WEIGHT * (1 - d / BotBrain.CALM_AVOID)
				fx -= (f.x - sx) / d * w
				fz -= (f.z - sz) / d * w
			end
		end
	end

	-- Revive: a downed ally we can reach without walking into a crowd.
	local reviving = false
	local downedAlly, downedD = nearest(allies, sx, sz, function(a: AllyView)
		return a.downed and a.id ~= self.id
	end)
	-- iteration 1: a downed rookie squadmate comes first, from further away, whatever the danger
	local rookieDown, rookieD = nearest(allies, sx, sz, function(a: any)
		return a.downed and a.rookie == true and a.id ~= self.id
	end)
	if rookieDown and rookieD <= BotBrain.ROOKIE_REVIVE_RANGE and hpFrac >= 0.25 then
		reviving = true
		foe = nil
		if rookieD > BotBrain.REVIVE_STAND - 1 then
			fx += (rookieDown.x - sx) / rookieD * BotBrain.ROOKIE_REVIVE_WEIGHT
			fz += (rookieDown.z - sz) / rookieD * BotBrain.ROOKIE_REVIVE_WEIGHT
		end
		downedAlly = nil
	end
	if downedAlly then
		local danger = 0
		local dr = BotBrain.REVIVE_DANGER_RADIUS
		for _, e in enemies do
			if len(e.x - downedAlly.x, e.z - downedAlly.z) <= dr then
				danger += 1
			end
		end
		if danger < BotBrain.REVIVE_DANGER or hpFrac > 0.6 then
			reviving = true
			if downedD > BotBrain.REVIVE_STAND - 1 then
				local w = 2.5
				fx += (downedAlly.x - sx) / downedD * w
				fz += (downedAlly.z - sz) / downedD * w
			end
		end
	end

	-- v3 Mouse Champions: a healthy leader hunts the nearest one (before POIs).
	local hunting = nil
	if
		squadMode
		and isLeader
		and not reviving
		and not fleeing
		and not foe
		and not followPing
		and hpFrac >= BotBrain.CHAMP_MIN_HP
	then
		local champ, cd = nearest(enemies, sx, sz, function(e: EnemySnap)
			return isChampion(e) and BotBrain.inZone(view, e.x, e.z)
		end)
		if champ and cd <= BotBrain.CHAMP_SEEK then
			hunting = champ
			local engage = math.max(BotBrain.ENGAGE_MIN, self.kiteRadius * BotBrain.ENGAGE_FACTOR)
			if cd > engage and cd > 1e-3 then
				local w = BotBrain.CHAMP_WEIGHT * math.clamp((cd - engage) / 10, 0.4, 1)
				fx += (champ.x - sx) / cd * w
				fz += (champ.z - sz) / cd * w
			end
		end
	end

	-- Points of interest: walk to a safe one and stand in it.
	local poi: PoiView? = nil
	local inPoi = false
	if not reviving and not fleeing and not foe and not hunting and not followPing then
		poi = self:_poiTarget(view, hpFrac, enemies, allies, anchor, squadMode and isLeader)
		if poi then
			local d = len(poi.x - sx, poi.z - sz)
			inPoi = d <= poi.r * 0.8
			if d > poi.r * 0.4 and d > 1e-3 then
				local w = if inPoi then 0.6 else BotBrain.POI_WEIGHT
				fx += (poi.x - sx) / d * w
				fz += (poi.z - sz) / d * w
			end
		end
	end

	-- Kite: away from the weighted centroid of nearby mice.
	local kiteR = self.kiteRadius
	if hpFrac < BotBrain.LOW_HP then
		kiteR = math.max(kiteR, BotBrain.KITE_RADIUS) * 1.3
	end
	local cx, cz, wsum, dmin = 0, 0, 0, math.huge
	for _, e in enemies do
		local d = len(e.x - sx, e.z - sz)
		if d <= kiteR then
			local w = 1 / (d + 1)
			if isBig(e) then
				w *= 3
			end
			cx += e.x * w
			cz += e.z * w
			wsum += w
			if d < dmin then
				dmin = d
			end
		end
	end
	local threatened = wsum > 0
	if threatened then
		cx, cz = cx / wsum, cz / wsum
		local ax, az = sx - cx, sz - cz
		local d = len(ax, az)
		if d < 1e-3 then
			-- Standing in the middle of them: pick a direction away from the arena centre.
			ax, az = sx, sz
			d = len(ax, az)
			if d < 1e-3 then
				ax, az, d = 1, 0, 1
			end
		end
		local strength = 1 + (1 - math.min(dmin, kiteR) / kiteR) * 2
		if hpFrac < BotBrain.LOW_HP then
			strength *= 2
		end
		if reviving then
			strength *= 0.35
		elseif foe then
			strength *= 0.6
		elseif inPoi then
			strength *= 0.4 -- hold the channel
		end
		fx += ax / d * strength
		fz += az / d * strength
	end

	-- Engage: a boss out of reach pulls us back in, so a kiting party does not
	-- run circles around a slow boss for minutes (sim: Grandma / Giant Tree).
	-- v3: a Mouse Champion within CHAMP_ENGAGE does the same (not while fleeing).
	if not reviving and hpFrac >= BotBrain.LOW_HP and not fleeing then
		local boss, bd = nearest(enemies, sx, sz, function(e: any)
			return e.kind >= BotBrain.BOSS_KIND
				or (isChampion(e) and len(e.x - sx, e.z - sz) <= BotBrain.CHAMP_ENGAGE)
		end)
		local engage = math.max(BotBrain.ENGAGE_MIN, self.kiteRadius * BotBrain.ENGAGE_FACTOR)
		if boss and bd > engage and boss ~= hunting then
			local w = math.clamp((bd - engage) / 15, 0, 1) * BotBrain.ENGAGE_WEIGHT
			fx += (boss.x - sx) / bd * w
			fz += (boss.z - sz) / bd * w
		end
	end

	-- Gear and loot bags (v2): walk over better ground gear, stand on bags.
	local loot = nil
	if not reviving and not fleeing and not foe and dmin > 6 and hpFrac >= BotBrain.LOW_HP then
		loot = self:_lootTarget(view)
		if loot then
			local d = len(loot.x - sx, loot.z - sz)
			if d > 0.8 then
				fx += (loot.x - sx) / d * BotBrain.GEAR_WEIGHT
				fz += (loot.z - sz) / d * BotBrain.GEAR_WEIGHT
			end
		end
	end

	-- Leash: stay near the nearest human (any ally if no humans are left).
	-- v2 squads: the squad's human, else the squad leader; the leader roams.
	if
		squadMode
		and not reviving
		and not poi
		and not loot
		and not foe
		and not fleeing
		and not hunting
		and not followPing
	then
		if anchor then
			local hd = len(anchor.x - sx, anchor.z - sz)
			if hd > BotBrain.LEASH * 0.6 and hd > 1e-3 then
				local w = math.clamp((hd - BotBrain.LEASH * 0.6) / (BotBrain.LEASH * 0.4), 0, 1) * 1.5
				if hd > BotBrain.LEASH then
					w = 2 + (hd - BotBrain.LEASH) / 5
				end
				fx += (anchor.x - sx) / hd * w
				fz += (anchor.z - sz) / hd * w
			end
		else
			-- leader without a goal: drift toward the middle (mice, the totem, the boss);
			-- early in a stage only to the edge of the squad's own side.
			-- v4: toward the storm circle's centre when there is one
			local ox, oz = sx, sz
			local driftR = view.arenaRadius
			if zcx ~= nil then
				ox, oz = sx - (zcx :: number), sz - (zcz :: number)
				driftR = math.min(driftR, zr :: number)
			end
			local d = len(ox, oz)
			local early = finite(view.waveTime) and (view.waveTime :: number) < BotBrain.EARLY_SECONDS
			if
				d > driftR * (if early then BotBrain.EARLY_DRIFT_FRAC else BotBrain.DRIFT_FRAC)
				and d > 1e-3
			then
				fx -= ox / d * 0.7
				fz -= oz / d * 0.7
			end
		end
	elseif not squadMode and not reviving and not poi and not followPing then
		local human, hd = nearest(allies, sx, sz, function(a: AllyView)
			return not a.isBot and a.id ~= self.id
		end)
		if not human then
			human, hd = nearest(allies, sx, sz, function(a: AllyView)
				return a.id ~= self.id
			end)
		end
		if human and hd > BotBrain.LEASH * 0.6 then
			local excess = (hd - BotBrain.LEASH * 0.6) / (BotBrain.LEASH * 0.4)
			local w = math.clamp(excess, 0, 1) * 1.5
			if hd > BotBrain.LEASH then
				w = 2 + (hd - BotBrain.LEASH) / 5
			end
			fx += (human.x - sx) / hd * w
			fz += (human.z - sz) / hd * w
		elseif not human then
			-- Nobody to follow: drift toward the middle of the arena.
			local d = len(sx, sz)
			if d > view.arenaRadius * 0.5 then
				fx -= sx / d * 0.5
				fz -= sz / d * 0.5
			end
		end
	end

	-- Crumbs: grab nearby XP when nothing is in our face.
	local pickups = view.pickups
	if pickups and #pickups > 0 and not reviving and (dmin > 6) then
		local crumb, cd = nearest(pickups, sx, sz)
		if crumb and cd <= BotBrain.PICKUP_RADIUS and cd > 0.5 then
			local w = 0.8
			fx += (crumb.x - sx) / cd * w
			fz += (crumb.z - sz) / cd * w
		end
	end

	-- Allies: don't stack on top of each other.
	for _, a in allies do
		if a.id ~= self.id and not a.downed then
			local dx, dz = sx - a.x, sz - a.z
			local d = len(dx, dz)
			if d < BotBrain.SEPARATION and d > 1e-3 then
				local w = (BotBrain.SEPARATION - d) / BotBrain.SEPARATION
				fx += dx / d * w
				fz += dz / d * w
			end
		end
	end

	-- Mousetrap Fields: keep out (the traps snap heroes too).
	for _, p in view.pois or {} do
		if
			p.active
			and (p.mode == "hazard" or p.kind == "mousetrap_field")
			and finite(p.x)
			and finite(p.z)
		then
			local dx, dz = sx - p.x, sz - p.z
			local d = len(dx, dz)
			local edge = p.r + BotBrain.HAZARD_MARGIN
			if d < edge and d > 1e-3 then
				local w = (edge - d) / edge * 3
				fx += dx / d * w
				fz += dz / d * w
			end
		end
	end

	-- Obstacles.
	for _, o in view.obstacles or {} do
		local dx, dz = sx - o.x, sz - o.z
		local d = len(dx, dz)
		local edge = o.r + BotBrain.OBSTACLE_MARGIN
		if d < edge and d > 1e-3 then
			local w = (edge - d) / BotBrain.OBSTACLE_MARGIN * 2
			fx += dx / d * w
			fz += dz / d * w
		end
	end

	-- Arena edge.
	local radius = if finite(view.arenaRadius) and view.arenaRadius > 0 then view.arenaRadius else 100
	local fromCentre = len(sx, sz)
	local inner = radius - BotBrain.EDGE_MARGIN
	if fromCentre > inner and fromCentre > 1e-3 then
		local w = (fromCentre - inner) / BotBrain.EDGE_MARGIN * 3
		fx -= sx / fromCentre * w
		fz -= sz / fromCentre * w
	end

	-- Wander: a slowly drifting heading so bots don't line up.
	self.wanderAngle += self.rng:range(-1.2, 1.2) * math.max(dt, 0.05)
	local wander = if threatened then 0.15 else 0.3
	fx += math.cos(self.wanderAngle) * wander
	fz += math.sin(self.wanderAngle) * wander

	local mag = len(fx, fz)
	local moveX, moveZ, speedFrac = 0, 0, 0
	if mag > 0.2 then
		moveX, moveZ = fx / mag, fz / mag
		speedFrac = math.clamp(mag, 0.35, 1)
		self.dirX, self.dirZ = moveX, moveZ
	end

	return {
		moveX = moveX,
		moveZ = moveZ,
		speedFrac = speedFrac,
		ability = self:_ability(view, foe),
	}
end

-- PvP pacing: (engage range for hunting enemy heroes, range to chase a hero who
-- hit our squad). Calm (stage <= CALM_STAGES, waveTime < CALM_SECONDS): no hunting.
-- Early (waveTime < EARLY_SECONDS): EARLY_HERO_ENGAGE / EARLY_DEFEND_RANGE. A view
-- without stage / waveTime gets the full ranges.
function BotBrain.pvpRanges(view: View): (number, number)
	local stage, t = view.stage, view.waveTime
	if not finite(stage) or not finite(t) then
		return BotBrain.HERO_ENGAGE, BotBrain.SQUAD_ATTACK_RANGE
	end
	local function byStage(list: { number }, default: number): number
		local n = #list
		if n == 0 then
			return default
		end
		return list[math.clamp(math.floor(stage :: number), 1, n)]
	end
	local engage = byStage(BotBrain.HERO_ENGAGE_BY_STAGE, BotBrain.HERO_ENGAGE)
	local defend = byStage(BotBrain.DEFEND_RANGE_BY_STAGE, BotBrain.SQUAD_ATTACK_RANGE)
	if (t :: number) < BotBrain.EARLY_SECONDS then
		defend = math.min(defend, BotBrain.EARLY_DEFEND_RANGE)
		engage = math.min(engage, BotBrain.EARLY_HERO_ENGAGE)
	end
	if (stage :: number) <= BotBrain.CALM_STAGES and (t :: number) < BotBrain.CALM_SECONDS then
		engage = 0
	end
	return engage, defend
end

-- The foe to fight (GDD-v2 §2): the nearest unprotected enemy hero within
-- HERO_ENGAGE (downed ones too: finish them), else one who hit our squad (or us)
-- in the last SQUAD_ATTACK_MEMORY s and is within SQUAD_ATTACK_RANGE.
function BotBrain._pickFoe(
	_self: Brain,
	view: View,
	mates: { AllyView },
	foes: { AllyView }
): (AllyView?, number)
	if #foes == 0 then
		return nil, math.huge
	end
	local me = view.self
	local engage, defend = BotBrain.pvpRanges(view)
	local best, bestD = nil, math.huge
	local st = if finite(view.stage) then view.stage :: number else 99
	local botOnly = st <= BotBrain.BOT_ONLY_HUNT_STAGES
	local humanSq: { [any]: boolean } = {}
	if botOnly then
		-- a human's own bot squadmates stay by their human (no stage-1 hunting at all)
		for _, a in mates do
			if a.isBot == false and BotBrain.HUMAN_MATES_HOLD then
				engage = 0
				break
			end
		end
		for _, f in foes do
			if f.isBot == false or f.humanSquad == true then
				humanSq[f.squad] = true -- derived from the view's isBot (no extra field needed)
			end
		end
	end
	for _, f in foes do
		if not f.protected and not rookieSafe(view, f, _self.id) and not (botOnly and humanSq[f.squad]) then
			local d = len(f.x - me.x, f.z - me.z)
			if d <= engage and d < bestD then
				best, bestD = f, d
			end
		end
	end
	if best then
		return best, bestD
	end
	local now = view.now
	local attackers: { [number]: boolean } = {}
	local any = false
	local function note(a: any)
		if
			type(a.lastHitBy) == "number"
			and finite(a.lastHitAt)
			and now - a.lastHitAt <= BotBrain.SQUAD_ATTACK_MEMORY
		then
			attackers[a.lastHitBy] = true
			any = true
		end
	end
	note(me)
	for _, a in mates do
		note(a)
	end
	if not any then
		return nil, math.huge
	end
	for _, f in foes do
		if attackers[f.id] and not f.protected and not f.downed and not rookieSafe(view, f, _self.id) then
			local d = len(f.x - me.x, f.z - me.z)
			if d <= defend and d < bestD then
				best, bestD = f, d
			end
		end
	end
	return best, bestD
end

local function rankOf(item: any): number
	return if type(item) == "table" then (GearDefs.RANK[item.rarity] or 0) else 0
end

-- Nearest ground item that beats our own slot, or loot bag, within GEAR_SEEK.
function BotBrain._lootTarget(_self: Brain, view: View): { x: number, z: number }?
	local me = view.self
	local mine = me.gear or {}
	local best, bestD = nil, BotBrain.GEAR_SEEK
	for _, g in view.gear or {} do
		local it = g.item
		if
			type(it) == "table"
			and finite(g.x)
			and finite(g.z)
			and rankOf(it) > rankOf(mine[it.slot])
			and BotBrain.inZone(view, g.x, g.z)
		then
			local d = len(g.x - me.x, g.z - me.z)
			if d < bestD then
				best, bestD = g, d
			end
		end
	end
	for _, b in view.bags or {} do
		if finite(b.x) and finite(b.z) and BotBrain.inZone(view, b.x, b.z) then
			local d = len(b.x - me.x, b.z - me.z)
			if d < bestD then
				best, bestD = b, d
			end
		end
	end
	return best :: any
end

-- Swap offer (world:swapOffer): take the offered item only when it is rarer.
function BotBrain.chooseSwap(current: any, offered: any): boolean
	return rankOf(offered) > rankOf(current)
end

-- Shop Cart: the rarest affordable upgrade over our gear, spending at most
-- half of the squad's pot. Returns its index, or 0 to buy nothing.
function BotBrain.chooseCartItem(
	offers: { any },
	prices: { number },
	sold: { boolean }?,
	pot: number,
	gear: { [string]: any }?
): number
	local mine = gear or {}
	local best, bestRank = 0, 0
	for i, it in offers do
		local price = prices[i]
		if
			type(it) == "table"
			and not (sold and sold[i])
			and finite(price)
			and price <= pot * 0.5
			and rankOf(it) > rankOf(mine[it.slot])
			and rankOf(it) > bestRank
		then
			best, bestRank = i, rankOf(it)
		end
	end
	return best
end

-- Highest rarity wins; ties are broken with the rng. Returns 0 for no cards.
function BotBrain.chooseUpgrade(cards: { UpgradeDef }, rng: Rng): number
	if #cards == 0 then
		return 0
	end
	local best, ties = -1, {}
	for i, card in cards do
		local rank = RARITY_RANK[card.rarity] or 0
		if rank > best then
			best, ties = rank, { i }
		elseif rank == best then
			table.insert(ties, i)
		end
	end
	return if #ties == 1 then ties[1] else rng:pick(ties)
end

-- The safe option for a vote: the Low route card, "Continue", or "GoHome".
function BotBrain.safeOption(kind: string, options: { any }): number
	if kind == "route" then
		for i, card in options do
			if type(card) == "table" and card.tier == "Low" then
				return i
			end
		end
		return 1
	end
	for _, name in { "Extract", "Continue", "GoHome" } do
		local i = table.find(options, name)
		if i then
			return i
		end
	end
	return 1
end

-- Follows the human plurality (ties broken with the rng). With no human
-- votes it takes the safe option; on ROUTE votes only, with a small chance of
-- the next card. Bank and cycle votes (QC2 M3): a bot never picks Double or
-- Nothing / Next Cycle unless a human voted for it, and a human tie between a
-- safe and a risky option goes to the safe one.
export type VoteCtx = {
	pot: number?, -- the squad's pending cheese
	hpFrac: number?, -- the squad's average HP fraction (standing members)
	stage: number?, -- the match stage just cleared (the HP rule applies from EXTRACT_HP_FROM_STAGE)
	extractPot: number?, -- override EXTRACT_POT (the headless sim's greedier human stand-in)
	routeStage: number?, -- iteration 1 route votes: the stage the route leads to
}

-- v2 extraction (kind = "extract", options like {"Extract", "Stay",
-- "DoubleOrNothing"}): bots follow their squad's humans (humanTally counts only
-- them); a bot-only squad extracts when ctx.pot >= EXTRACT_POT or ctx.hpFrac <
-- EXTRACT_HP, else stays. Never Double or Nothing without a human vote.
function BotBrain.chooseVote(
	kind: string,
	options: { any },
	humanTally: { number },
	rng: Rng,
	ctx: VoteCtx?
): number
	local n = #options
	if n == 0 then
		return 1
	end
	local best, ties = 0, {}
	for i = 1, n do
		local c = humanTally[i]
		if type(c) == "number" and c > 0 then
			if c > best then
				best, ties = c, { i }
			elseif c == best then
				table.insert(ties, i)
			end
		end
	end
	local staking = kind ~= "route"
	if best > 0 then
		if #ties == 1 then
			return ties[1]
		end
		if staking then
			local safe = BotBrain.safeOption(kind, options)
			if table.find(ties, safe) then
				return safe
			end
		end
		return rng:pick(ties)
	end
	local safe = BotBrain.safeOption(kind, options)
	if kind == "extract" then
		local c: VoteCtx = ctx or {}
		local pot = if finite(c.pot) then c.pot :: number else 0
		local hp = if finite(c.hpFrac) then c.hpFrac :: number else 1
		local stage = if finite(c.stage) then c.stage :: number else BotBrain.EXTRACT_HP_FROM_STAGE
		local hpLow = stage >= BotBrain.EXTRACT_HP_FROM_STAGE and hp < BotBrain.EXTRACT_HP
		local stay = table.find(options, "Stay")
		local need = if finite(c.extractPot) then c.extractPot :: number else BotBrain.EXTRACT_POT
		if pot < need and not hpLow and stay then
			return stay
		end
		return safe
	end
	if kind == "route" then
		return BotBrain.chooseRoute(options, rng, ctx)
	end
	if not staking and safe < n and rng:chance(BotBrain.VOTE_SURPRISE) then
		return safe + 1
	end
	return safe
end

local TIERS = { "Low", "Mid", "High" }

-- Picks a card index by tier weights {Low, Mid, High}; tiers missing from the cards
-- give their weight to nothing (renormalised over the offered tiers).
local function pickByTier(options: { any }, weights: { number }, rng: Rng): number
	local idx, w = {}, {}
	for i, card in options do
		local tier = if type(card) == "table" then card.tier else nil
		local k = table.find(TIERS, tier)
		local wt = if k then weights[k] or 0 else 0
		if wt > 0 then
			table.insert(idx, i)
			table.insert(w, wt)
		end
	end
	if #idx == 0 then
		return BotBrain.safeOption("route", options)
	end
	return idx[rng:weightedIndex(w)]
end

-- Tier weights {Low, Mid, High} for a bot-only route vote: ROUTE_WEIGHTS by the stage
-- the route LEADS TO (ctx.routeStage; unknown: 2), ROUTE_LOW_HP_WEIGHTS when ctx.hpFrac <
-- ROUTE_LOW_HP. (ctx.stage keeps its extract meaning: the stage just cleared.)
function BotBrain.routeWeights(ctx: VoteCtx?): { number }
	local c: VoteCtx = ctx or {}
	if finite(c.hpFrac) and (c.hpFrac :: number) < BotBrain.ROUTE_LOW_HP then
		return BotBrain.ROUTE_LOW_HP_WEIGHTS
	end
	local list = BotBrain.ROUTE_WEIGHTS
	local rs = (c :: any).routeStage
	local st = if finite(rs) then math.floor(rs) else 2
	return list[math.clamp(st, 1, #list)]
end

-- Iteration 1 route gamble: the card a bot-only squad picks (weighted by tier).
function BotBrain.chooseRoute(options: { any }, rng: Rng, ctx: VoteCtx?): number
	return pickByTier(options, BotBrain.routeWeights(ctx), rng)
end

-- No squad won the boss: a random card weighted by ROUTE_NO_WINNER (RunDirector).
function BotBrain.randomRoute(options: { any }, rng: Rng): number
	return pickByTier(options, BotBrain.ROUTE_NO_WINNER, rng)
end

-- v2 extraction for one squad (RunDirector / MatchState). `matchView` is the Match
-- payload shape: {stage?, squads = {[squad] = {pending?, hpFrac?, members?,
-- extracted?, eliminated?, humanVotes? = {[choice] = n}}}}. With human votes in
-- the squad the plurality wins (a tie goes to Extract; Double or Nothing only
-- when humans chose it). A bot-only squad extracts when its pot reaches
-- EXTRACT_POT or its HP is low (EXTRACT_HP), and always on the last stage;
-- otherwise it stays.
function BotBrain.chooseExtract(
	matchView: any,
	squad: number,
	rng: Rng,
	extractPot: number? -- optional EXTRACT_POT override (VoteCtx.extractPot)
): "Extract" | "Stay" | "DoubleOrNothing"
	local options = { "Extract", "Stay", "DoubleOrNothing" }
	local mv = if type(matchView) == "table" then matchView else {}
	local squads = if type(mv.squads) == "table" then mv.squads else {}
	local info = if type(squads[squad]) == "table" then squads[squad] else {}
	local tally = {}
	local votes = info.humanVotes or info.votes
	if type(votes) == "table" then
		for i, name in options do
			local n = votes[name]
			tally[i] = if finite(n) then n else 0
		end
	end
	local stage = if finite(mv.stage) then mv.stage else 1
	if stage >= 4 then
		local anyHuman = false
		for _, n in tally do
			if n > 0 then
				anyHuman = true
			end
		end
		if not anyHuman then
			return "Extract"
		end
	end
	local idx = BotBrain.chooseVote("extract", options, tally, rng, {
		pot = if finite(info.pending) then info.pending else 0,
		hpFrac = if finite(info.hpFrac) then info.hpFrac else 1,
		stage = stage,
		extractPot = extractPot,
	})
	return (options[idx] or "Extract") :: any
end

return BotBrain
