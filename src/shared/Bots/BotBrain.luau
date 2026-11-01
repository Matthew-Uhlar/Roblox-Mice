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

local Rng = require("../Util/Rng")
local Types = require("../Types")
local Classes = require("../Config/Classes")

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
}
export type AllyView = { id: number, x: number, z: number, downed: boolean, isBot: boolean }
export type PickupView = { x: number, z: number }
export type Obstacle = { x: number, z: number, r: number }
export type View = {
	self: SelfView,
	allies: { AllyView },
	enemies: { EnemySnap },
	pickups: { PickupView }?,
	arenaRadius: number,
	obstacles: { Obstacle }?,
	now: number,
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
BotBrain.VOTE_SURPRISE = 0.15 -- chance of the next option when no human voted

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
	local melee = weapon ~= nil and (weapon.kind == "melee_arc" or weapon.kind == "orbit" or weapon.kind == "cone")
	return setmetatable({
		id = id,
		classId = classId,
		rng = rng,
		abilityKind = kind,
		abilityArea = area,
		abilityRange = range,
		kiteRadius = if melee then BotBrain.MELEE_KITE_RADIUS else BotBrain.KITE_RADIUS,
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

function BotBrain._ability(self: Brain, view: View): { x: number, z: number }?
	local me = view.self
	if not me.abilityReady or me.downed then
		return nil
	end
	local enemies = view.enemies
	if #enemies == 0 then
		return nil
	end
	local area = self.abilityArea
	local selfCentred = SELF_CENTRED[self.abilityKind] == true
	local reach = if selfCentred then area else math.max(self.abilityRange, area)

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

function BotBrain.think(self: Brain, view: View, dt: number): Intent
	local me = view.self
	local sx, sz = me.x, me.z
	local fx, fz = 0, 0
	local hpFrac = if me.maxHp > 0 then math.clamp(me.hp / me.maxHp, 0, 1) else 1
	local allies = view.allies or {}

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
		end
		fx += ax / d * strength
		fz += az / d * strength
	end

	-- Leash: stay near the nearest human (any ally if no humans are left).
	if not reviving then
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
		ability = self:_ability(view),
	}
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
	for _, name in { "Continue", "GoHome" } do
		local i = table.find(options, name)
		if i then
			return i
		end
	end
	return 1
end

-- Follows the human plurality (ties broken with the rng). With no human
-- votes it takes the safe option, with a small chance of the next one.
function BotBrain.chooseVote(kind: string, options: { any }, humanTally: { number }, rng: Rng): number
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
	if best > 0 then
		return if #ties == 1 then ties[1] else rng:pick(ties)
	end
	local safe = BotBrain.safeOption(kind, options)
	if safe < n and rng:chance(BotBrain.VOTE_SURPRISE) then
		return safe + 1
	end
	return safe
end

return BotBrain
