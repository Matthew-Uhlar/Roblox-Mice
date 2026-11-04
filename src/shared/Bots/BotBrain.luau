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
	squad: number?, -- v2: enables squad behaviour
	gear: { [string]: any }?, -- v2: world:gearOf(id)
	lastHitBy: number?, -- v2: hero who last hit this bot...
	lastHitAt: number?, -- ...and when (world clock)
}
export type AllyView = {
	id: number,
	x: number,
	z: number,
	downed: boolean,
	isBot: boolean,
	squad: number?, -- v2
	protected: boolean?, -- v2 spawn protection (not worth shooting)
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
}
export type Intent = {
	moveX: number,
	moveZ: number,
	speedFrac: number,
	ability: { x: number, z: number }?,
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
BotBrain.LOW_HP = 0.35
BotBrain.ABILITY_CLUSTER = 5 -- cast when this many mice are in the ability's area
BotBrain.BOSS_KIND = 200 -- EnemySnap.kind >= 200 is a boss
BotBrain.BOSS_NEAR = 6 -- extra studs added to the ability reach for bosses
BotBrain.MAX_CANDIDATES = 32 -- cluster search cost cap
BotBrain.ENGAGE_FACTOR = 1.6 -- close in on a boss farther than kiteRadius x this...
BotBrain.ENGAGE_MIN = 10 -- ...but never closer than this
BotBrain.ENGAGE_WEIGHT = 1.4
BotBrain.VOTE_SURPRISE = 0.15 -- ROUTE votes only: chance of the next card when no human voted
BotBrain.POI_SEEK = 45 -- walk to a POI this close...
BotBrain.POI_LEASH = 40 -- ...that is also this close to the nearest human
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
BotBrain.SQUAD_ATTACK_MEMORY = 4 -- s: a foe who hit our squad this recently is fair game...
BotBrain.SQUAD_ATTACK_RANGE = 45 -- ...if it is this close
BotBrain.FIGHT_RANGE = 12 -- ranged bots hold this distance to a foe
BotBrain.MELEE_FIGHT_RANGE = 4
BotBrain.FIGHT_WEIGHT = 2.2
BotBrain.FLEE_RADIUS = 28 -- low-HP bots flee foes this close
BotBrain.FLEE_WEIGHT = 3.5
BotBrain.GEAR_SEEK = 30 -- walk to ground gear / loot bags this close
BotBrain.GEAR_WEIGHT = 1.8
BotBrain.EXTRACT_POT = 300 -- bot-only squads extract with this much pending cheese...
BotBrain.EXTRACT_HP = 0.45 -- ...or when the squad's average HP is below this

local RARITY_RANK: { [string]: number } = { Common = 1, Rare = 2, Epic = 3, Legendary = 4 }

-- Self-centred abilities hit around the caster; aimed ones land at the aim point.
local SELF_CENTRED: { [string]: boolean } = { ring = true, shield = true, hover = true }

export type Brain = typeof(setmetatable(
	{} :: {
		id: number,
		classId: string,
		rng: Rng,
		abilityKind: string,
		abilityArea: number,
		abilityRange: number,
		kiteRadius: number,
		fightRange: number,
		wanderAngle: number,
		dirX: number,
		dirZ: number,
	},
	BotBrain
))

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function BotBrain.new(id: number, classId: string, rng: Rng): Brain
	local def = (Classes :: any).get(classId)
	local ability = def and def.ability
	local weapon = def and def.weapon
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
		kiteRadius = if melee then BotBrain.MELEE_KITE_RADIUS else BotBrain.KITE_RADIUS,
		fightRange = if melee then BotBrain.MELEE_FIGHT_RANGE else BotBrain.FIGHT_RANGE,
		wanderAngle = rng:range(0, math.pi * 2),
		dirX = 0,
		dirZ = 0,
	}, BotBrain)
end

local function len(x: number, z: number): number
	return math.sqrt(x * x + z * z)
end

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

function BotBrain._ability(self: Brain, view: View, foe: AllyView?): { x: number, z: number }?
	local me = view.self
	if not me.abilityReady or me.downed then
		return nil
	end
	local area = self.abilityArea
	local selfCentred = SELF_CENTRED[self.abilityKind] == true
	local reach = if selfCentred then area else math.max(self.abilityRange, area)
	-- v2: an engaged enemy hero in reach is the best target
	if foe and not foe.downed and len(foe.x - me.x, foe.z - me.z) <= reach + 1 then
		return { x = foe.x, z = foe.z }
	end
	local enemies = view.enemies
	if #enemies == 0 then
		return nil
	end

	-- A boss within reach: always worth it.
	local boss, bossD = nearest(enemies, me.x, me.z, function(e: EnemySnap)
		return e.kind >= BotBrain.BOSS_KIND
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
	if self.abilityKind == "dash" and me.maxHp > 0 and me.hp / me.maxHp < BotBrain.LOW_HP then
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
		if d > BotBrain.POI_SEEK then
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

function BotBrain.think(self: Brain, view: View, dt: number): Intent
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

	-- Downed: crawl toward the nearest standing ally.
	if me.downed then
		local ally, d = nearest(allies, sx, sz, function(a: AllyView)
			return not a.downed and a.id ~= self.id
		end)
		if ally and d > 2 then
			local mx, mz = (ally.x - sx) / d, (ally.z - sz) / d
			self.dirX, self.dirZ = mx, mz
			return { moveX = mx, moveZ = mz, speedFrac = 1, ability = nil }
		end
		return { moveX = 0, moveZ = 0, speedFrac = 0, ability = nil }
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

	-- Revive: a downed ally we can reach without walking into a crowd.
	local reviving = false
	local downedAlly, downedD = nearest(allies, sx, sz, function(a: AllyView)
		return a.downed and a.id ~= self.id
	end)
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

	-- Points of interest: walk to a safe one and stand in it.
	local poi: PoiView? = nil
	local inPoi = false
	if not reviving and not fleeing and not foe then
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
			if e.kind >= BotBrain.BOSS_KIND then
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
	if not reviving and hpFrac >= BotBrain.LOW_HP then
		local boss, bd = nearest(enemies, sx, sz, function(e: any)
			return e.kind >= BotBrain.BOSS_KIND
		end)
		local engage = math.max(BotBrain.ENGAGE_MIN, self.kiteRadius * BotBrain.ENGAGE_FACTOR)
		if boss and bd > engage then
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
	if squadMode and not reviving and not poi and not loot and not foe and not fleeing then
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
			-- leader without a goal: drift toward the middle (mice, the totem, the boss)
			local d = len(sx, sz)
			if d > view.arenaRadius * 0.35 then
				fx -= sx / d * 0.7
				fz -= sz / d * 0.7
			end
		end
	elseif not squadMode and not reviving and not poi then
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

-- The foe to fight (GDD-v2 §2): the nearest unprotected enemy hero within
-- HERO_ENGAGE (downed ones too: finish them), else one who hit our squad (or us)
-- in the last SQUAD_ATTACK_MEMORY s and is within SQUAD_ATTACK_RANGE.
function BotBrain._pickFoe(self: Brain, view: View, mates: { AllyView }, foes: { AllyView }): (AllyView?, number)
	if #foes == 0 then
		return nil, math.huge
	end
	local me = view.self
	local best, bestD = nil, math.huge
	for _, f in foes do
		if not f.protected then
			local d = len(f.x - me.x, f.z - me.z)
			if d <= BotBrain.HERO_ENGAGE and d < bestD then
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
		if attackers[f.id] and not f.protected and not f.downed then
			local d = len(f.x - me.x, f.z - me.z)
			if d <= BotBrain.SQUAD_ATTACK_RANGE and d < bestD then
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
		if type(it) == "table" and finite(g.x) and finite(g.z) and rankOf(it) > rankOf(mine[it.slot]) then
			local d = len(g.x - me.x, g.z - me.z)
			if d < bestD then
				best, bestD = g, d
			end
		end
	end
	for _, b in view.bags or {} do
		if finite(b.x) and finite(b.z) then
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
		local stay = table.find(options, "Stay")
		if pot < BotBrain.EXTRACT_POT and hp >= BotBrain.EXTRACT_HP and stay then
			return stay
		end
		return safe
	end
	if not staking and safe < n and rng:chance(BotBrain.VOTE_SURPRISE) then
		return safe + 1
	end
	return safe
end

return BotBrain
