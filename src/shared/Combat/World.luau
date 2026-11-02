--!strict
-- Pure combat simulation (see docs/ARCHITECTURE.md "Team B"). No Instances, no physics:
-- enemies, projectiles, zones and pickups are plain tables moved with maths.
-- CombatService (server) feeds player positions in and broadcasts snapshots + Fx out.
--
-- Time: `now` passed to step() is the clock for everything (CombatService uses
-- workspace:GetServerTimeNow(), so abilityReadyAt / orbit t0 / Fx times are comparable
-- on clients). useAbility() uses the world clock (last step's now) once stepping has
-- begun, so a caller with a different clock cannot desync cooldowns.

local Types = require("../Types")
local Rng = require("../Util/Rng")
local Ids = require("../Util/Ids")
local Enemies = require("../Config/Enemies")
local Bosses = require("../Config/Bosses")
local SpatialHash = require("./SpatialHash")
local WaveDirector = require("./WaveDirector")
local Weapons = require("./Weapons")
local BossPatterns = require("./BossPatterns")
local Defaults = require("./Defaults")
local Pois = require("./Pois")

type Rng = Rng.Rng
type PlayerStats = Types.PlayerStats
type WeaponDef = Types.WeaponDef
type AbilityDef = Types.AbilityDef
type WorldMods = Types.WorldMods
type EnemySnap = Types.EnemySnap
type FxEvent = Types.FxEvent

export type Obstacle = { x: number, z: number, r: number }
export type WorldEvent = {
	type: "xp"
		| "damaged"
		| "downed"
		| "revived"
		| "dead"
		| "kill"
		| "bossDead"
		| "bossPhase"
		| "bossEnrage"
		| "poiProgress"
		| "poiActivated"
		| "poiReward",
	id: number?,
	amount: number?,
	kind: string?,
	-- POI events (Combat/Pois.luau): the POI entity id, who triggered it, where,
	-- and the reward payload (cheese, buff, xp, revived, cards, ids = every participant)
	poi: number?,
	by: number?,
	x: number?,
	z: number?,
	[string]: any,
}

export type Options = {
	rng: Rng,
	mods: WorldMods,
	arenaRadius: number,
	obstacles: { Obstacle }?,
	enemyPool: { string }?,
	cycle: number?,
	stage: number?,
	enemyCap: number?, -- default 220
	viewRadius: number?, -- spawn ring distance (default WaveDirector.VIEW_RADIUS)
}

local World = {}
World.__index = World

-- Tunables (GDD §3.5 for the revive numbers)
World.PLAYER_RADIUS = 1.6
World.IFRAMES = 0.5
World.DOWNED_TIME = 20
World.REVIVE_RANGE = 8
World.REVIVE_TIME = 3
World.REVIVE_HP = 0.4
World.REVIVE_GRACE = 1.5
World.SECOND_WIND_HP = 0.5
World.DOWNED_SPEED = 0.3 -- WalkSpeed multiplier while downed (CombatService applies it)
World.DEFAULT_CAP = 220
World.CRUMB_CAP = 250
World.ENEMY_PROJ_CAP = 500
World.PLAYER_PROJ_CAP = 400
World.HIT_FX_CAP = 40
World.CELL = 4
World.BOSS_INTRO = 3
World.BOSS_GAP = { 1.3, 0.85 }
World.MINION_GAP = 2.4
-- Soft timer: a boss still alive this long after it spawned enrages once
-- (faster movement, shorter gaps between patterns, Fx {t="enrage"}).
World.BOSS_ENRAGE_AFTER = 120
World.ENRAGE_SPEED_MULT = 1.35
World.ENRAGE_GAP_MULT = 0.5
World.ROCK_INTERVAL = 3.2
World.ROCK_RADIUS = 5
World.ROCK_DAMAGE = 18
World.ROCK_WINDUP = 1.2
World.MAGNET_SPEED = 28
World.PLAYER_SLOW = 0.6
World.BOT_WEIGHT = 0.6 -- bots (Ids.isBot) count as 0.6 of a player for spawn pressure

local TAU = math.pi * 2

export type World = typeof(setmetatable({} :: { [string]: any }, World))

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function World.new(opts: Options): World
	local root = opts.rng
	local self = setmetatable({}, World) :: any
	self.rng = root:fork(2) -- combat rolls (crits, spreads)
	self.spawnRng = root:fork(1)
	self.bossRng = root:fork(3)
	self.rockRng = root:fork(4)
	self.poiRng = root:fork(5) -- trap layouts (forked last: older streams are unchanged)
	self.mods = Defaults.fillMods(opts.mods)
	self.arenaRadius = opts.arenaRadius or 100
	self.obstacles = {}
	for _, o in opts.obstacles or {} do
		table.insert(self.obstacles, { x = o.x, z = o.z, r = o.r })
	end
	self.enemyPool = opts.enemyPool or { "mouse" }
	self.cycle = opts.cycle or 1
	self.stage = opts.stage or 1
	self.cap = opts.enemyCap or World.DEFAULT_CAP
	self.wave = WaveDirector.new({
		rng = self.spawnRng,
		enemyPool = self.enemyPool,
		cycle = self.cycle,
		stage = self.stage,
		mods = self.mods,
		cap = self.cap,
		arenaRadius = self.arenaRadius,
		obstacles = self.obstacles,
		viewRadius = opts.viewRadius,
	})
	self.enemies = {}
	self.enemyById = {}
	self.liveCount = 0
	self.players = {}
	self.playerList = {}
	self.standing = {}
	self.pprojs = {}
	self.eprojs = {}
	self.zones = {}
	self.pickups = {}
	self.actions = {}
	self.actionSeq = 0
	self.booms = {}
	self.fx = {}
	self.events = {}
	self.teleports = {}
	self.hash = SpatialHash.new(World.CELL)
	self.now = 0
	self.stepped = false
	self.boss = nil
	self.nextEnemyId = 0
	self.nextProjId = 0
	self.nextPickupId = 0
	self.nextZoneId = 0
	self.nextRockAt = nil
	self.hitFx = 0
	self.hitByEnemy = {} -- enemy id -> this step's merged "hit" fx
	self.maxEnemyR = 2.5
	self.forcePattern = nil -- tests/debug: boss always runs this pattern
	-- Points of interest (Combat/Pois.luau): live only while the waves run.
	self.poiList = {}
	self.poiById = {}
	self.nextPoiId = 0
	self.poisLive = false
	self.poiResyncAt = 0
	self.portalState = nil -- Rind Gate portal after the boss (GDD §3.9)
	return self :: World
end

-- Fx / events / scheduling ---------------------------------------------------------------

function World.emit(self: World, fx: FxEvent)
	table.insert(self.fx, fx)
end

function World.event(self: World, ev: WorldEvent)
	table.insert(self.events, ev)
end

function World.telegraph(self: World, caster: any, fx: FxEvent)
	fx.delay = math.max(fx.delay or BossPatterns.MIN_TELEGRAPH, 0)
	if caster then
		fx.src = caster.id
		caster.telegraphUntil = math.max(caster.telegraphUntil or 0, self.now + fx.delay)
	end
	table.insert(self.fx, fx)
end

function World.schedule(self: World, at: number, owner: any, fn: (now: number) -> ())
	self.actionSeq += 1
	table.insert(self.actions, { at = at, owner = owner, fn = fn, seq = self.actionSeq })
end

function World._runActions(self: World, now: number)
	local list = self.actions
	if #list == 0 then
		return
	end
	local due, keep = {}, {}
	for _, a in list do
		if a.at <= now then
			table.insert(due, a)
		else
			table.insert(keep, a)
		end
	end
	if #due == 0 then
		return
	end
	self.actions = keep
	table.sort(due, function(a, b)
		if a.at == b.at then
			return a.seq < b.seq
		end
		return a.at < b.at
	end)
	for _, a in due do
		if a.owner == nil or a.owner.alive then
			a.fn(now)
		end
	end
end

-- Geometry helpers -----------------------------------------------------------------------

function World.clampToArena(self: World, x: number, z: number, margin: number?): (number, number)
	local lim = self.arenaRadius - (margin or 0)
	local d2 = x * x + z * z
	if d2 > lim * lim then
		local d = math.sqrt(d2)
		return x / d * lim, z / d * lim
	end
	return x, z
end

function World.pushOutOfObstacles(self: World, x: number, z: number, r: number): (number, number)
	for _, o in self.obstacles do
		local dx, dz = x - o.x, z - o.z
		local rr = o.r + r
		local d2 = dx * dx + dz * dz
		if d2 < rr * rr then
			local d = math.sqrt(d2)
			if d < 1e-4 then
				dx, dz, d = 1, 0, 1
			end
			x, z = o.x + dx / d * rr, o.z + dz / d * rr
		end
	end
	return x, z
end

function World.randomArenaPoint(self: World, margin: number?): (number, number)
	local rng = self.bossRng
	for _ = 1, 10 do
		local a = rng:range(0, TAU)
		local d = math.sqrt(rng:nextFloat()) * (self.arenaRadius - (margin or 2) - 2)
		local x, z = math.cos(a) * d, math.sin(a) * d
		local ok = true
		for _, o in self.obstacles do
			if (x - o.x) ^ 2 + (z - o.z) ^ 2 < (o.r + (margin or 2)) ^ 2 then
				ok = false
				break
			end
		end
		if ok then
			return x, z
		end
	end
	return 0, 0
end

-- Players ------------------------------------------------------------------------------

local function isStanding(p: any): boolean
	return not p.downed and not p.dead
end

function World.addPlayer(
	self: World,
	id: number,
	stats: PlayerStats,
	weapon: WeaponDef,
	ability: AbilityDef,
	x: number,
	z: number
)
	if self.players[id] then
		self:removePlayer(id)
	end
	local s = Defaults.fillStats(stats)
	local p = {
		id = id,
		stats = s,
		weapon = weapon,
		ability = ability,
		derived = Weapons.derive(s, weapon),
		x = if finite(x) then x else 0,
		z = if finite(z) then z else 0,
		faceX = 1,
		faceZ = 0,
		hp = s.maxHp,
		maxHp = s.maxHp,
		downed = false,
		downedUntil = nil :: number?,
		dead = false,
		reviveProgress = 0,
		iframeUntil = 0,
		invulnUntil = 0,
		hoverUntil = 0,
		slowUntil = 0,
		abilityReadyAt = 0,
		weaponReadyAt = 0,
		secondWindUsed = false,
		orbitT0 = self.now,
		orbitDirty = true,
		orbitFxAt = 0,
		shield = nil :: any,
		alive = true, -- for scheduled-action ownership
	}
	self.players[id] = p
	table.insert(self.playerList, p)
end

function World.removePlayer(self: World, id: number)
	local p = self.players[id]
	if not p then
		return
	end
	p.alive = false
	self.players[id] = nil
	local i = table.find(self.playerList, p)
	if i then
		table.remove(self.playerList, i)
	end
	for zi = #self.zones, 1, -1 do
		if self.zones[zi].owner == p then
			table.remove(self.zones, zi)
		end
	end
	for _, c in self.pickups do
		if c.target == id then
			c.target = nil
		end
	end
end

function World.updatePlayer(self: World, id: number, stats: PlayerStats, weapon: WeaponDef)
	local p = self.players[id]
	if not p then
		return
	end
	local s = Defaults.fillStats(stats)
	local ratio = if p.maxHp > 0 then p.hp / p.maxHp else 1
	p.stats = s
	p.weapon = weapon
	p.maxHp = s.maxHp
	p.hp = math.clamp(ratio * s.maxHp, 0, s.maxHp)
	if isStanding(p) and p.hp < 1 then
		p.hp = math.min(1, s.maxHp)
	end
	p.derived = Weapons.derive(s, weapon)
	p.orbitDirty = true
end

-- Ability defs can change too (class swap mid-run is unlikely, but cheap to support).
function World.setPlayerAbility(self: World, id: number, ability: AbilityDef)
	local p = self.players[id]
	if p then
		p.ability = ability
	end
end

-- Moves a participant (CombatService for humans after MoveGuard, BotService for
-- bots). The point is clamped into the arena and pushed out of obstacle circles
-- (the player's centre may not enter a rock: noclip gains nothing in the sim).
-- Returns the position actually stored, or nil for an unknown id / bad input.
function World.setPlayerPosition(self: World, id: number, x: number, z: number): (number?, number?)
	local p = self.players[id]
	if not p or not finite(x) or not finite(z) then
		return nil, nil
	end
	x, z = self:clampToArena(x, z, World.PLAYER_RADIUS)
	x, z = self:pushOutOfObstacles(x, z, 0)
	x, z = self:clampToArena(x, z, World.PLAYER_RADIUS)
	local dx, dz = x - p.x, z - p.z
	local m = math.sqrt(dx * dx + dz * dz)
	if m > 0.05 then
		p.faceX, p.faceZ = dx / m, dz / m
	end
	p.x, p.z = x, z
	return x, z
end

function World.teleportPlayer(self: World, p: any, x: number, z: number)
	p.x, p.z = x, z
	table.insert(self.teleports, { id = p.id, x = x, z = z })
end

-- CombatService moves the character for these (dash abilities). Drain once per step.
function World.drainTeleports(self: World): { { id: number, x: number, z: number } }
	local t = self.teleports
	self.teleports = {}
	return t
end

function World.useAbility(self: World, id: number, aimX: number, aimZ: number, now: number): boolean
	local p = self.players[id]
	if not p or not isStanding(p) then
		return false
	end
	if not finite(aimX) or not finite(aimZ) then
		return false
	end
	-- Before the first step the caller's clock is all we have; never trust a
	-- non-finite one (NaN would poison the cooldown, inf would lock it forever).
	local t = if self.stepped then self.now elseif finite(now) then now else self.now
	if t < p.abilityReadyAt then
		return false
	end
	if not Weapons.useAbility(self, p, aimX, aimZ, t) then
		return false
	end
	p.abilityReadyAt = t + Weapons.abilityCooldown(p.stats, p.ability)
	return true
end

function World._revive(self: World, p: any, hpFrac: number, kind: string)
	p.downed = false
	p.dead = false
	p.downedUntil = nil
	p.reviveProgress = 0
	p.hp = math.max(1, p.maxHp * hpFrac)
	p.invulnUntil = math.max(p.invulnUntil, self.now + World.REVIVE_GRACE)
	self:emit({ t = "revive", id = p.id, x = p.x, z = p.z, kind = kind })
	self:event({ type = "revived", id = p.id, kind = kind })
end

function World.useSecondWind(self: World, id: number): boolean
	local p = self.players[id]
	if not p or not p.downed or p.dead or p.secondWindUsed then
		return false
	end
	p.secondWindUsed = true
	self:_revive(p, World.SECOND_WIND_HP, "secondWind")
	p.invulnUntil = math.max(p.invulnUntil, self.now + 2)
	-- shove the crowd back so the revive is not instantly undone
	self:forEnemiesInCircle(p.x, p.z, 9, function(e)
		local dx, dz = e.x - p.x, e.z - p.z
		local m = math.max(0.01, math.sqrt(dx * dx + dz * dz))
		self:knockEnemy(e, dx / m, dz / m, 8)
	end)
	self:emit({ t = "boom", x = p.x, z = p.z, r = 9, id = p.id, kind = "secondWind" })
	return true
end

-- Internal heal of a player record by `amount` hp (x healingMult).
function World._heal(self: World, p: any, amount: number)
	if not isStanding(p) or not finite(amount) or amount <= 0 then
		return
	end
	p.hp = math.min(p.maxHp, p.hp + amount * (self.mods.healingMult or 1))
end

-- Public: heal participant `id` by `frac` of max HP (StatDelta.heal semantics, x healingMult).
function World.healPlayer(self: World, id: number, frac: number)
	local p = self.players[id]
	if p and finite(frac) and frac > 0 then
		self:_heal(p, p.maxHp * frac)
	end
end

function World._down(self: World, p: any)
	p.hp = 0
	p.downed = true
	p.downedUntil = self.now + World.DOWNED_TIME
	p.reviveProgress = 0
	p.shield = nil
	self:emit({ t = "down", id = p.id, x = p.x, z = p.z, untilT = p.downedUntil })
	self:event({ type = "downed", id = p.id })
end

-- Applies armor, i-frames, shields, hover and oneHitKO. Returns damage taken.
function World.damagePlayer(self: World, p: any, amount: number, source: string?): number
	if not isStanding(p) or amount <= 0 then
		return 0
	end
	local now = self.now
	if now < p.invulnUntil then
		if p.shield then
			p.shield.blocked += 1
		end
		return 0
	end
	if source == "contact" and now < p.hoverUntil then
		return 0
	end
	if now < p.iframeUntil then
		return 0
	end
	local dmg
	if self.mods.oneHitKO then
		dmg = p.hp
	else
		dmg = math.max(1, amount - (p.stats.armor or 0))
	end
	p.hp -= dmg
	p.iframeUntil = now + World.IFRAMES
	p.lastHurtAt = now -- interrupts POI channels (Pois.HURT_PAUSE)
	self:emit({ t = "hurt", id = p.id, amount = math.floor(dmg + 0.5), x = p.x, z = p.z })
	self:event({ type = "damaged", id = p.id, amount = dmg, kind = source })
	if p.hp <= 0 then
		self:_down(p)
	end
	return dmg
end

function World.standingPlayers(self: World): { any }
	return self.standing
end

function World.nearestStanding(self: World, x: number, z: number): any?
	local best, bestD = nil, math.huge
	for _, p in self.standing do
		local d = (p.x - x) ^ 2 + (p.z - z) ^ 2
		if d < bestD then
			best, bestD = p, d
		end
	end
	return best
end

function World.damagePlayersCircle(self: World, x: number, z: number, r: number, dmg: number, source: string?)
	for _, p in self.standing do
		local rr = r + World.PLAYER_RADIUS * 0.5
		if (p.x - x) ^ 2 + (p.z - z) ^ 2 <= rr * rr then
			self:damagePlayer(p, dmg, source or "boss")
		end
	end
end

function World.damagePlayersLine(
	self: World,
	x: number,
	z: number,
	dx: number,
	dz: number,
	len: number,
	halfW: number,
	dmg: number
)
	for _, p in self.standing do
		local px, pz = p.x - x, p.z - z
		local along = px * dx + pz * dz
		if along >= -World.PLAYER_RADIUS and along <= len + World.PLAYER_RADIUS then
			local perp = math.abs(px * -dz + pz * dx)
			if perp <= halfW + World.PLAYER_RADIUS * 0.5 then
				self:damagePlayer(p, dmg, "boss")
			end
		end
	end
end

function World.damagePlayersCone(
	self: World,
	x: number,
	z: number,
	dx: number,
	dz: number,
	range: number,
	angleDeg: number,
	dmg: number
)
	local cosHalf = math.cos(math.rad(angleDeg / 2))
	for _, p in self.standing do
		local px, pz = p.x - x, p.z - z
		local m = math.sqrt(px * px + pz * pz)
		if m <= range + World.PLAYER_RADIUS * 0.5 and (m < 2 or (px * dx + pz * dz) / m >= cosHalf) then
			self:damagePlayer(p, dmg, "boss")
		end
	end
end

-- Enemies ------------------------------------------------------------------------------

function World._allocEnemyId(self: World): number
	for _ = 1, 65535 do
		self.nextEnemyId = self.nextEnemyId % 65535 + 1
		if not self.enemyById[self.nextEnemyId] then
			return self.nextEnemyId
		end
	end
	error("World: out of enemy ids")
end

function World._addEnemy(self: World, e: any)
	e.id = self:_allocEnemyId()
	e.alive = true
	table.insert(self.enemies, e)
	self.enemyById[e.id] = e
	self.liveCount += 1
	if e.r > self.maxEnemyR then
		self.maxEnemyR = e.r
	end
	return e
end

-- Spawns a regular enemy. Returns nil when at the live cap or the id is unknown.
function World.spawnEnemy(self: World, id: string?, x: number, z: number, elite: boolean?): any?
	if self.liveCount >= self.cap then
		return nil
	end
	local defId = id or self.spawnRng:pick(self.wave.pool)
	local def = Enemies.get(defId)
	if not def then
		return nil
	end
	local mods = self.mods
	local E = Enemies.ELITE
	local el = elite == true
	x, z = self:clampToArena(x, z, def.radius)
	x, z = self:pushOutOfObstacles(x, z, def.radius)
	local hp = def.hp * (mods.enemyHpMult or 1) * (if el then E.hpMult else 1)
	local e = {
		defId = def.id,
		def = def,
		kind = Enemies.INDEX[def.id],
		behavior = def.behavior,
		elite = el,
		x = x,
		z = z,
		kvx = 0,
		kvz = 0,
		r = def.radius * (if el then E.radiusMult else 1),
		hp = hp,
		maxHp = hp,
		speed = def.speed * (if el then E.speedMult else 1),
		contact = def.contactDamage * (if el then E.damageMult else 1),
		xp = def.xp * (if el then E.xpMult else 1),
		slowUntil = 0,
		slowFactor = 1,
		nextShot = self.now + self.spawnRng:range(0.6, def.rangedCooldown or 2),
		fuseAt = nil :: number?,
	}
	return self:_addEnemy(e)
end

function World.spawnBoss(self: World, bossId: string, x: number, z: number): any
	local def = Bosses.get(bossId)
	if not def then
		bossId = Bosses.ORDER[1]
		def = Bosses.get(bossId)
	end
	assert(def, "World.spawnBoss: no boss defs")
	if self.boss and self.boss.alive then
		self:_killEnemy(self.boss, nil, true, true)
	end
	x, z = self:clampToArena(if finite(x) then x else 0, if finite(z) then z else 0, def.radius + 1)
	local hp = def.hp * (self.mods.bossHpMult or 1)
	local now = self.now
	local e = {
		defId = def.id,
		def = def,
		kind = Bosses.KIND_OFFSET + (Bosses.INDEX[def.id] or 1),
		behavior = "boss",
		isBoss = true,
		elite = false,
		x = x,
		z = z,
		kvx = 0,
		kvz = 0,
		r = def.radius,
		hp = hp,
		maxHp = hp,
		speed = def.speed,
		contact = def.contactDamage * (self.mods.bossDamageMult or 1),
		xp = 0,
		slowUntil = 0,
		slowFactor = 1,
		phase = 1,
		patternList = def.patterns,
		openerDone = false,
		introUntil = now + World.BOSS_INTRO,
		introDone = false,
		busyUntil = now + World.BOSS_INTRO,
		gap = World.BOSS_GAP[1],
		gapMult = 1,
		spawnedAt = if self.stepped then now else nil, -- else set by the first step
		enraged = false,
		lockedUntil = 0,
		telegraphUntil = now + World.BOSS_INTRO,
	}
	self:_addEnemy(e)
	self.boss = e
	self:emit({
		t = "tele",
		shape = "circle",
		x = x,
		z = z,
		r = def.radius + 4,
		delay = World.BOSS_INTRO,
		style = "bossIntro",
		src = e.id,
	})
	self:emit({
		t = "boss",
		id = e.id,
		bossId = def.id,
		name = def.name,
		title = def.title,
		x = x,
		z = z,
		intro = World.BOSS_INTRO,
	})
	return e
end

-- Where a boss should appear: BOSS_SPAWN_DIST studs from the party's centre,
-- on the side facing the arena centre (the arena centre itself when the party
-- is already close to it). A slow boss spawned across a 120-stud arena from a
-- party that kites spent half its fight walking (sim). Never inside a rock.
World.BOSS_SPAWN_DIST = 40 -- a few seconds of approach: time to breathe after the waves
function World.bossSpawnPoint(self: World, radius: number?): (number, number)
	local n, cx, cz = 0, 0, 0
	for _, p in self.playerList do
		if not p.dead then
			n += 1
			cx += p.x
			cz += p.z
		end
	end
	local r = radius or 5
	if n == 0 then
		return self:clampToArena(0, 0, r + 1)
	end
	cx, cz = cx / n, cz / n
	local d = math.sqrt(cx * cx + cz * cz)
	local x, z
	if d <= World.BOSS_SPAWN_DIST then
		x, z = 0, 0
	else
		x, z = cx - cx / d * World.BOSS_SPAWN_DIST, cz - cz / d * World.BOSS_SPAWN_DIST
	end
	x, z = self:pushOutOfObstacles(x, z, r + 1)
	return self:clampToArena(x, z, r + 1)
end

-- Boss minion (e.g. the two Serpent Sisters): boss-kind body with its own pattern loop.
function World.spawnMinion(
	self: World,
	boss: any,
	hpFrac: number,
	patterns: { string },
	x: number,
	z: number
): any?
	if not boss or not boss.alive then
		return nil
	end
	local hp = boss.maxHp * hpFrac
	local e = {
		defId = boss.defId,
		def = boss.def,
		kind = boss.kind,
		behavior = "boss",
		isMinion = true,
		minionOf = boss,
		elite = false,
		x = x,
		z = z,
		kvx = 0,
		kvz = 0,
		r = boss.r * 0.8,
		hp = hp,
		maxHp = hp,
		speed = boss.speed * 1.1,
		contact = boss.contact * 0.7,
		gapMult = boss.gapMult or 1,
		xp = 3,
		slowUntil = 0,
		slowFactor = 1,
		patternList = patterns,
		openerDone = true,
		busyUntil = self.now + 1,
		gap = World.MINION_GAP * (boss.gapMult or 1),
		lockedUntil = 0,
		telegraphUntil = 0,
	}
	self:_addEnemy(e)
	self:emit({ t = "minion", id = e.id, of = boss.id, x = x, z = z })
	return e
end

function World.countMinions(self: World, boss: any): number
	local c = 0
	for _, e in self.enemies do
		if e.alive and e.minionOf == boss then
			c += 1
		end
	end
	return c
end

function World.knockEnemy(_self: World, e: any, dx: number, dz: number, studs: number)
	local resist = if e.isBoss then 0.1 elseif e.isMinion then 0.3 elseif e.behavior == "tank" then 0.4 else 1
	local v = studs * 8 * resist -- integral of v*e^(-8t) = v/8 -> total push = studs
	e.kvx += dx * v
	e.kvz += dz * v
end

-- Returns damage dealt. Kills (and drops) when hp hits 0.
function World.damageEnemy(
	self: World,
	e: any,
	amount: number,
	by: any?,
	crit: boolean?,
	fromExplosion: boolean?
): number
	if not e.alive or amount <= 0 then
		return 0
	end
	if e.introUntil and self.now < e.introUntil then
		return 0
	end
	local dealt = math.min(amount, e.hp)
	e.hp -= amount
	-- One damage number per enemy per step: later hits are merged into it.
	local merged = self.hitByEnemy[e.id]
	if merged then
		merged.amount += math.floor(amount + 0.5)
		merged.crit = merged.crit or crit == true
		merged.x, merged.z = e.x, e.z
	elseif self.hitFx < World.HIT_FX_CAP or crit then
		self.hitFx += 1
		local fx = {
			t = "hit",
			x = e.x,
			z = e.z,
			amount = math.floor(amount + 0.5),
			crit = crit == true,
			id = e.id,
		}
		self.hitByEnemy[e.id] = fx
		self:emit(fx)
	end
	if e.isBoss and e.phase == 1 and e.hp > 0 and e.hp <= e.maxHp * 0.5 then
		self:_bossPhase2(e)
	end
	if e.hp <= 0 then
		self:_killEnemy(e, by, false, fromExplosion == true)
	end
	return dealt
end

function World._bossPhase2(self: World, e: any)
	e.phase = 2
	e.patternList = e.def.phase2Patterns or e.def.patterns
	e.openerDone = false
	e.gap = World.BOSS_GAP[2] * (e.gapMult or 1)
	e.busyUntil = math.max(e.busyUntil, self.now + 1.0) -- short roar
	e.telegraphUntil = math.max(e.telegraphUntil or 0, self.now + 1.0)
	self:emit({ t = "bossPhase", id = e.id, phase = 2, x = e.x, z = e.z })
	self:event({ type = "bossPhase", amount = 2, kind = e.defId })
end

-- Enrage (once): the boss and its live minions move faster and attack more often.
function World._enrage(self: World, e: any)
	if e.enraged then
		return
	end
	e.enraged = true
	local bodies = self:_minionsOf(e)
	table.insert(bodies, 1, e)
	for _, m in bodies do
		m.speed *= World.ENRAGE_SPEED_MULT
		m.gapMult = (m.gapMult or 1) * World.ENRAGE_GAP_MULT
		m.gap *= World.ENRAGE_GAP_MULT
	end
	self:emit({
		t = "enrage",
		id = e.id,
		x = e.x,
		z = e.z,
		speedMult = World.ENRAGE_SPEED_MULT,
		gapMult = World.ENRAGE_GAP_MULT,
	})
	self:event({ type = "bossEnrage", kind = e.defId })
end

function World._minionsOf(self: World, boss: any): { any }
	local out = {}
	for _, m in self.enemies do
		if m.alive and m.minionOf == boss then
			table.insert(out, m)
		end
	end
	return out
end

function World._killEnemy(self: World, e: any, by: any?, noDrop: boolean?, fromExplosion: boolean?)
	if not e.alive then
		return
	end
	e.alive = false
	e.hp = 0
	self.liveCount -= 1
	self:emit({ t = "die", id = e.id, x = e.x, z = e.z, kind = e.kind })
	if by then
		self:event({ type = "kill", id = by.id, kind = e.defId })
	end
	if e.poiId then
		Pois.onPackKill(self, e)
	end
	if e.isBoss then
		self:event({ type = "bossDead", kind = e.defId })
		for _, m in self.enemies do
			if m.alive and m.minionOf == e then
				self:_killEnemy(m, nil, false, true)
			end
		end
		self.enemyProjClear = true
		if not noDrop then
			local total = 60 + 20 * self.cycle
			local nCrumbs = 12
			for i = 1, nCrumbs do
				local a = i / nCrumbs * TAU
				self:spawnPickup(e.x + math.cos(a) * 4, e.z + math.sin(a) * 4, total / nCrumbs)
			end
			-- vacuum every crumb on the field to the party
			for _, c in self.pickups do
				c.vacuum = true
			end
		end
	elseif not noDrop then
		self:spawnPickup(e.x, e.z, e.xp)
	end
	if by and not fromExplosion and not noDrop then
		local r = by.stats and by.stats.explodeOnKill or 0
		if r > 0 then
			table.insert(self.booms, { by = by, x = e.x, z = e.z, r = r, dmg = 5 + 0.5 * by.derived.damage })
		end
	end
end

function World.clearEnemies(self: World)
	for _, e in self.enemies do
		e.alive = false
	end
	self.enemies = {}
	self.enemyById = {}
	self.liveCount = 0
	self.boss = nil
	self.eprojs = {}
	self.actions = {}
	for i = #self.zones, 1, -1 do
		if self.zones[i].hostile then
			table.remove(self.zones, i)
		end
	end
	self:emit({ t = "clear" })
end

-- Exact circle test against each enemy's own radius. fn(e, distSq) per enemy hit.
function World.forEnemiesInCircle(
	self: World,
	x: number,
	z: number,
	r: number,
	fn: (e: any, d2: number) -> ()
)
	local pad = self.maxEnemyR + 1.5
	self.hash:forEachInRadius(x, z, r + pad, function(e)
		if e.alive then
			local dx, dz = e.x - x, e.z - z
			local rr = r + e.r
			local d2 = dx * dx + dz * dz
			if d2 <= rr * rr then
				fn(e, d2)
			end
		end
		return nil
	end)
end

function World.forEnemiesInLine(
	self: World,
	x: number,
	z: number,
	dx: number,
	dz: number,
	len: number,
	halfW: number,
	fn: (e: any) -> ()
)
	local cx, cz = x + dx * len / 2, z + dz * len / 2
	self:forEnemiesInCircle(cx, cz, len / 2 + halfW, function(e)
		local px, pz = e.x - x, e.z - z
		local along = px * dx + pz * dz
		if along >= -e.r and along <= len + e.r and math.abs(px * -dz + pz * dx) <= halfW + e.r then
			fn(e)
		end
	end)
end

-- Up to n nearest alive enemies within range (linear scan; called a few times per second).
function World.nearestEnemies(self: World, x: number, z: number, range: number, n: number): { any }
	local best: { any } = {}
	local bestD: { number } = {}
	for _, e in self.enemies do
		if e.alive and not (e.introUntil and self.now < e.introUntil) then
			local rr = range + e.r
			local d2 = (e.x - x) ^ 2 + (e.z - z) ^ 2
			if d2 <= rr * rr and (#best < n or d2 < bestD[#best]) then
				local i = #best + 1
				while i > 1 and bestD[i - 1] > d2 do
					i -= 1
				end
				table.insert(best, i, e)
				table.insert(bestD, i, d2)
				if #best > n then
					best[n + 1] = nil
					bestD[n + 1] = nil
				end
			end
		end
	end
	return best
end

-- Projectiles, zones, pickups ---------------------------------------------------------------

local function nextId(self: any, field: string): number
	local v = self[field] % 65535 + 1
	self[field] = v
	return v
end

function World.spawnPlayerProjectile(self: World, pr: any)
	if #self.pprojs >= World.PLAYER_PROJ_CAP then
		return
	end
	pr.id = nextId(self, "nextProjId")
	pr.expires = self.now + pr.ttl
	pr.hit = {}
	table.insert(self.pprojs, pr)
	self:emit({
		t = "proj",
		id = pr.id,
		kind = pr.kind,
		x = pr.x,
		z = pr.z,
		vx = pr.vx,
		vz = pr.vz,
		ttl = pr.ttl,
		r = pr.r,
		owner = pr.owner.id,
	})
end

function World.spawnEnemyProjectile(
	self: World,
	x: number,
	z: number,
	vx: number,
	vz: number,
	r: number,
	dmg: number,
	ttl: number,
	kind: string,
	slow: boolean?
)
	if #self.eprojs >= World.ENEMY_PROJ_CAP then
		return
	end
	local m = self.mods.enemyProjectileSpeedMult or 1
	local pr = {
		id = nextId(self, "nextProjId"),
		x = x,
		z = z,
		vx = vx * m,
		vz = vz * m,
		r = r,
		dmg = dmg,
		expires = self.now + ttl,
		kind = kind,
		slow = slow,
	}
	table.insert(self.eprojs, pr)
	self:emit({
		t = "proj",
		id = pr.id,
		kind = kind,
		x = x,
		z = z,
		vx = pr.vx,
		vz = pr.vz,
		ttl = ttl,
		r = r,
		hostile = true,
	})
end

function World.spawnPlayerZone(self: World, z: any)
	z.id = nextId(self, "nextZoneId")
	z.nextTick = z.nextTick or self.now
	table.insert(self.zones, z)
	self:emit({
		t = "zone",
		id = z.id,
		kind = z.kind,
		x = z.x,
		z = z.z,
		r = z.r,
		ttl = z.untilT - self.now,
		owner = z.owner.id,
		follow = z.follow == true,
	})
end

function World.spawnHostileZone(
	self: World,
	x: number,
	z: number,
	r: number,
	dmg: number,
	duration: number,
	tick: number,
	kind: string
)
	local zone = {
		id = nextId(self, "nextZoneId"),
		x = x,
		z = z,
		r = r,
		dmg = dmg,
		tick = tick,
		untilT = self.now + duration,
		nextTick = self.now,
		kind = kind,
		hostile = true,
	}
	table.insert(self.zones, zone)
	self:emit({ t = "zone", id = zone.id, kind = kind, x = x, z = z, r = r, ttl = duration, hostile = true })
end

function World.spawnPickup(self: World, x: number, z: number, xp: number)
	x, z = self:clampToArena(x, z, 2)
	if #self.pickups >= World.CRUMB_CAP then
		-- merge into the nearest crumb instead of growing without bound
		local best, bestD = nil, math.huge
		for _, c in self.pickups do
			local d = (c.x - x) ^ 2 + (c.z - z) ^ 2
			if d < bestD then
				best, bestD = c, d
			end
		end
		if best then
			best.xp += xp
			return
		end
	end
	local c = {
		id = nextId(self, "nextPickupId"),
		x = x,
		z = z,
		xp = xp,
		target = nil :: number?,
		speed = World.MAGNET_SPEED,
	}
	table.insert(self.pickups, c)
	self:emit({ t = "pickup", id = c.id, x = x, z = z, xp = xp })
end

-- Mods / waves -------------------------------------------------------------------------------

function World.setMods(self: World, mods: WorldMods)
	self.mods = Defaults.fillMods(mods)
	self.wave:setMods(self.mods)
end

-- Optional: reuse one World across stages. Resets the per-stage second-wind cap.
function World.setStage(self: World, cycle: number, stage: number)
	self.cycle, self.stage = cycle, stage
	self.wave.cycle, self.wave.stage = math.max(1, cycle), math.max(1, stage)
	for _, p in self.playerList do
		p.secondWindUsed = false
	end
end

function World.startWaves(self: World, duration: number)
	self.wave:start(duration)
end

function World.stopSpawning(self: World)
	self.wave:stop()
end

-- Step: players ------------------------------------------------------------------------------

function World._updatePlayers(self: World, dt: number, now: number)
	local standing = self.standing
	table.clear(standing)
	for _, p in self.playerList do
		if isStanding(p) then
			table.insert(standing, p)
		end
	end
	for _, p in self.playerList do
		if p.dead then
			continue
		end
		if p.downed then
			if now >= (p.downedUntil or 0) then
				p.downed = false
				p.dead = true
				p.downedUntil = nil
				self:emit({ t = "dead", id = p.id })
				self:event({ type = "dead", id = p.id })
			else
				local helped = false
				local r2 = World.REVIVE_RANGE * World.REVIVE_RANGE
				for _, q in standing do
					if q ~= p and (q.x - p.x) ^ 2 + (q.z - p.z) ^ 2 <= r2 then
						helped = true
						break
					end
				end
				if helped then
					p.reviveProgress += dt
					if p.reviveProgress >= World.REVIVE_TIME then
						self:_revive(p, World.REVIVE_HP, "teammate")
						table.insert(standing, p)
					end
				else
					p.reviveProgress = math.max(0, p.reviveProgress - dt * 0.5)
				end
			end
		else
			local regen = p.stats.regen or 0
			if regen > 0 then
				self:_heal(p, regen * dt)
			end
			if p.shield and now >= p.shield.untilT then
				Weapons.shieldBurst(self, p)
			end
		end
	end
end

-- Step: enemies ------------------------------------------------------------------------------

function World._rebuildHash(self: World)
	local h = self.hash
	h:clear()
	for _, e in self.enemies do
		if e.alive then
			h:insert(e, e.x, e.z)
		end
	end
end

function World._casterAI(self: World, e: any, now: number)
	if e.introUntil and not e.introDone then
		if now < e.introUntil then
			return
		end
		e.introDone = true
		local r = e.r + 4
		self:damagePlayersCircle(e.x, e.z, r, e.contact)
		self:emit({ t = "slam", x = e.x, z = e.z, r = r })
	end
	if e.dash or e.leap then
		return
	end
	if now >= e.busyUntil + e.gap then
		local list: { string } = e.patternList or {}
		if #list == 0 then
			return
		end
		local id: string
		if self.forcePattern and e.isBoss then
			id = self.forcePattern
		elseif not e.openerDone then
			id = list[1]
			e.openerDone = true
		elseif #list == 1 then
			id = list[1]
		else
			id = self.bossRng:pick(list)
			local tries = 0
			while id == e.lastPattern and tries < 4 do
				id = self.bossRng:pick(list)
				tries += 1
			end
		end
		e.lastPattern = id
		local d = BossPatterns.run(self, e, id, now)
		e.busyUntil = math.max(e.busyUntil, now + d)
	end
end

-- Steering scratch (module-level so the separation callback is allocated once).
local sepE: any = nil
local sepX, sepZ = 0, 0
local function sepVisit(n: any, nx: number, nz: number, _d2: number): boolean?
	if n == sepE or not n.alive then
		return nil
	end
	local e = sepE
	local dx, dz = e.x - nx, e.z - nz
	local rr = (e.r + n.r) * 0.95
	local d2 = dx * dx + dz * dz
	if d2 < rr * rr then
		if d2 < 1e-6 then
			dx, dz, d2 = (e.id % 7) - 3 + 0.5, (e.id % 5) - 2 + 0.5, 1
		end
		local d = math.sqrt(d2)
		local overlap = rr - d
		-- big bodies (bosses, chonks) shove small ones, not the reverse
		local share = n.r / (e.r + n.r)
		if n.isBoss then
			share = 1
		end
		sepX += dx / d * overlap * share
		sepZ += dz / d * overlap * share
	end
	return nil
end

function World._moveEnemy(self: World, e: any, dt: number, now: number)
	local mods = self.mods
	local slow = if now < e.slowUntil then e.slowFactor else 1
	local spd = e.speed * (mods.enemySpeedMult or 1) * slow
	local x, z = e.x, e.z
	local mx, mz = 0, 0 -- desired direction (unit or 0)
	local target = self:nearestStanding(x, z)
	local stunned = (e.kvx * e.kvx + e.kvz * e.kvz) > 4

	if e.isBoss or e.isMinion then
		if e.dash then
			local dsh = e.dash
			local nx, nz = x + dsh.dx * dsh.speed * dt, z + dsh.dz * dsh.speed * dt
			local cx, cz = self:clampToArena(nx, nz, e.r)
			-- contact along the dash path
			for _, p in self.standing do
				local rr = e.r + World.PLAYER_RADIUS
				if (p.x - cx) ^ 2 + (p.z - cz) ^ 2 <= rr * rr then
					self:damagePlayer(p, dsh.dmg, "boss")
				end
			end
			if dsh.trail and now >= dsh.nextTrail then
				dsh.nextTrail = now + 0.2
				self:_trailZone(e, x, z, dsh.trail)
			end
			e.x, e.z = cx, cz
			if now >= dsh.untilT or cx ~= nx or cz ~= nz then
				e.dash = nil
			end
			return
		elseif e.leap then
			local lp = e.leap
			local t = math.clamp((now - lp.t0) / math.max(0.01, lp.t1 - lp.t0), 0, 1)
			e.x, e.z = lp.fx + (lp.tx - lp.fx) * t, lp.fz + (lp.tz - lp.fz) * t
			return
		elseif now < (e.lockedUntil or 0) or (e.introUntil and now < e.introUntil) then
			mx, mz = 0, 0
		elseif target then
			local dx, dz = target.x - x, target.z - z
			local d = math.sqrt(dx * dx + dz * dz)
			if d > e.r + World.PLAYER_RADIUS + 0.5 then
				mx, mz = dx / d, dz / d
			end
		end
	elseif e.behavior == "fuse" and e.fuseAt then
		if now >= e.fuseAt then
			self:_explodeFuse(e)
			return
		end
		mx, mz = 0, 0
	elseif target then
		local dx, dz = target.x - x, target.z - z
		local d = math.max(1e-4, math.sqrt(dx * dx + dz * dz))
		local edge = d - e.r - World.PLAYER_RADIUS
		if e.behavior == "ranged" then
			local range = e.def.rangedRange or 30
			if d > range * 0.85 then
				mx, mz = dx / d, dz / d
			elseif d < range * 0.45 then
				mx, mz = -dx / d, -dz / d
			else
				-- strafe a little so slingers don't stack in a line
				local side = if e.id % 2 == 0 then 1 else -1
				mx, mz = -dz / d * 0.35 * side, dx / d * 0.35 * side
			end
			if d <= range and now >= e.nextShot and not stunned then
				local def = e.def
				local ps = def.projectileSpeed or 25
				e.nextShot = now + (def.rangedCooldown or 2.5) * self.rng:range(0.85, 1.15)
				local ux, uz = dx / d, dz / d
				local dmg = (def.projectileDamage or 6)
					* (mods.enemyDamageMult or 1)
					* (if e.elite then Enemies.ELITE.damageMult else 1)
				self:spawnEnemyProjectile(
					x + ux * e.r,
					z + uz * e.r,
					ux * ps,
					uz * ps,
					0.8,
					dmg,
					range * 1.3 / ps,
					"crumb"
				)
			end
		elseif e.behavior == "fuse" and edge <= Enemies.FUSE_TRIGGER then
			e.fuseAt = now + Enemies.FUSE_TIME
			e.telegraphUntil = e.fuseAt
			self:telegraph(e, {
				t = "tele",
				shape = "circle",
				x = x,
				z = z,
				r = e.def.fuseRadius or 8,
				delay = Enemies.FUSE_TIME,
				style = "fuse",
			})
			mx, mz = 0, 0
		else
			mx, mz = dx / d, dz / d
		end
	end

	-- obstacle avoidance: steer tangentially around circles in the way
	if mx ~= 0 or mz ~= 0 then
		for _, o in self.obstacles do
			local ox, oz = x - o.x, z - o.z
			local reach = o.r + e.r + 3
			local d2 = ox * ox + oz * oz
			if d2 < reach * reach and (ox * mx + oz * mz) < 0 then
				local d = math.sqrt(d2)
				local tx, tz = -oz / d, ox / d
				if tx * mx + tz * mz < 0 then
					tx, tz = -tx, -tz
				end
				local wgt = 1 - math.max(0, d - o.r - e.r) / 3
				mx, mz = mx + tx * wgt * 1.2, mz + tz * wgt * 1.2
				local m = math.sqrt(mx * mx + mz * mz)
				if m > 1e-4 then
					mx, mz = mx / m, mz / m
				end
			end
		end
	end

	-- separation
	sepE, sepX, sepZ = e, 0, 0
	if not e.isBoss then
		self.hash:forEachInRadius(x, z, e.r + self.maxEnemyR, sepVisit)
	end
	local sx, sz = sepX, sepZ
	sepE = nil
	local sm = math.sqrt(sx * sx + sz * sz)
	local maxSep = math.max(spd, 6) * dt * 1.5
	if sm > maxSep then
		sx, sz = sx / sm * maxSep, sz / sm * maxSep
	end

	-- knockback impulse decays
	local decay = math.exp(-8 * dt)
	local kx, kz = e.kvx, e.kvz
	e.kvx, e.kvz = kx * decay, kz * decay
	if math.abs(e.kvx) < 0.05 then
		e.kvx = 0
	end
	if math.abs(e.kvz) < 0.05 then
		e.kvz = 0
	end

	x += mx * spd * dt + sx + kx * dt
	z += mz * spd * dt + sz + kz * dt
	-- hard constraints: obstacles, arena edge
	for _, o in self.obstacles do
		local ox, oz = x - o.x, z - o.z
		local rr = o.r + e.r
		local d2 = ox * ox + oz * oz
		if d2 < rr * rr then
			local d = math.sqrt(d2)
			if d < 1e-4 then
				ox, oz, d = 1, 0, 1
			end
			x, z = o.x + ox / d * rr, o.z + oz / d * rr
		end
	end
	x, z = self:clampToArena(x, z, e.r)
	e.x, e.z = x, z
	e.stunned = stunned
end

function World._trailZone(self: World, caster: any, x: number, z: number, kind: string)
	-- Trail puddles arm after a short telegraph, so running into a fresh trail is fair.
	local r = 3.5
	self:telegraph(caster, {
		t = "tele",
		shape = "circle",
		x = x,
		z = z,
		r = r,
		delay = BossPatterns.MIN_TELEGRAPH,
		style = kind,
	})
	self:schedule(self.now + BossPatterns.MIN_TELEGRAPH, nil, function()
		self:spawnHostileZone(x, z, r, 6 * (self.mods.bossDamageMult or 1), 3, 0.5, kind)
	end)
end

function World._explodeFuse(self: World, e: any)
	local def = e.def
	local r = def.fuseRadius or 8
	local dmg = (def.fuseDamage or 20)
		* (self.mods.enemyDamageMult or 1)
		* (if e.elite then Enemies.ELITE.damageMult else 1)
	self:emit({ t = "boom", x = e.x, z = e.z, r = r, kind = "fuse" })
	self:damagePlayersCircle(e.x, e.z, r, dmg, "fuse")
	self:_killEnemy(e, nil, true, true)
end

function World._updateEnemies(self: World, dt: number, now: number)
	local list = self.enemies
	for i = 1, #list do
		local e = list[i]
		if e.alive then
			if e.patternList then
				self:_casterAI(e, now)
			end
			if e.alive then
				self:_moveEnemy(e, dt, now)
			end
		end
	end
end

function World._contactDamage(self: World)
	local pad = self.maxEnemyR + World.PLAYER_RADIUS + 1.5
	local now = self.now
	for _, p in self.standing do
		if not isStanding(p) or now < p.iframeUntil then
			continue
		end
		local px, pz = p.x, p.z
		local hitBy = nil
		self.hash:forEachInRadius(px, pz, pad, function(e)
			if e.alive and not e.leap and not e.dash and not (e.introUntil and now < e.introUntil) then
				local rr = e.r + World.PLAYER_RADIUS
				if (e.x - px) ^ 2 + (e.z - pz) ^ 2 <= rr * rr then
					if hitBy == nil or e.contact > hitBy.contact then
						hitBy = e
					end
				end
			end
			return nil
		end)
		if hitBy then
			local mult = if hitBy.isBoss or hitBy.isMinion then 1 else (self.mods.enemyDamageMult or 1)
			self:damagePlayer(p, hitBy.contact * mult, "contact")
		end
	end
end

-- Step: projectiles / zones / pickups ---------------------------------------------------------

function World._updatePlayerProjectiles(self: World, dt: number, now: number)
	local list = self.pprojs
	local keep = {}
	local lim = self.arenaRadius + 4
	for _, pr in list do
		local owner = pr.owner
		local live = owner.alive
		if live and pr.lob then
			if now >= pr.landAt then
				Weapons.explode(self, owner, pr.tx, pr.tz, pr.r, pr.dmg, { knock = pr.knock, chain = true })
				live = false
			else
				pr.x += pr.vx * dt
				pr.z += pr.vz * dt
			end
		elseif live then
			local speed = math.sqrt(pr.vx * pr.vx + pr.vz * pr.vz)
			local subs = math.max(1, math.ceil(speed * dt / (pr.r + 1)))
			local sdt = dt / subs
			for _ = 1, subs do
				pr.x += pr.vx * sdt
				pr.z += pr.vz * sdt
				self:forEnemiesInCircle(pr.x, pr.z, pr.r, function(e)
					if live and not pr.hit[e] then
						pr.hit[e] = true
						Weapons.hit(self, owner, e, pr.dmg, {
							knock = pr.knock,
							fromX = pr.x - pr.vx * sdt,
							fromZ = pr.z - pr.vz * sdt,
							chain = true,
						})
						pr.pierce -= 1
						if pr.pierce < 0 then
							live = false
						end
					end
				end)
				if not live then
					break
				end
			end
			if live and (now >= pr.expires or pr.x * pr.x + pr.z * pr.z > lim * lim) then
				if now < pr.expires then
					self:emit({ t = "projEnd", id = pr.id })
				end
				live = false
			elseif not live then
				self:emit({ t = "projEnd", id = pr.id })
			end
		end
		if live then
			table.insert(keep, pr)
		end
	end
	self.pprojs = keep
end

function World._updateEnemyProjectiles(self: World, dt: number, now: number)
	if self.enemyProjClear then
		self.enemyProjClear = false
		for _, pr in self.eprojs do
			self:emit({ t = "projEnd", id = pr.id })
		end
		self.eprojs = {}
		return
	end
	local keep = {}
	local lim = self.arenaRadius + 2
	local pr2 = World.PLAYER_RADIUS
	for _, pr in self.eprojs do
		pr.x += pr.vx * dt
		pr.z += pr.vz * dt
		local live = true
		for _, p in self.standing do
			local rr = pr.r + pr2
			if (p.x - pr.x) ^ 2 + (p.z - pr.z) ^ 2 <= rr * rr then
				local took = self:damagePlayer(p, pr.dmg, "projectile")
				if took > 0 and pr.slow then
					p.slowUntil = now + 1.5
				end
				live = false
				break
			end
		end
		if live and now >= pr.expires then
			live = false
		elseif live and pr.x * pr.x + pr.z * pr.z > lim * lim then
			live = false
			self:emit({ t = "projEnd", id = pr.id })
		elseif not live then
			self:emit({ t = "projEnd", id = pr.id })
		end
		if live then
			table.insert(keep, pr)
		end
	end
	self.eprojs = keep
end

function World._updateZones(self: World, now: number)
	local zones = self.zones
	for i = #zones, 1, -1 do
		local zn = zones[i]
		if now >= zn.untilT then
			table.remove(zones, i)
			continue
		end
		if zn.hostile then
			if now >= zn.nextTick then
				zn.nextTick += zn.tick
				self:damagePlayersCircle(zn.x, zn.z, zn.r, zn.dmg, "zone")
			end
		else
			local owner = zn.owner
			if not owner.alive then
				table.remove(zones, i)
				continue
			end
			if zn.follow then
				zn.x, zn.z = owner.x, owner.z
			end
			if zn.slow then
				self:forEnemiesInCircle(zn.x, zn.z, zn.r, function(e)
					if not e.isBoss then
						e.slowUntil = now + 0.25
						e.slowFactor = 1 - zn.slow
					end
				end)
			end
			if zn.dmg > 0 and now >= zn.nextTick then
				zn.nextTick += zn.tick
				self:forEnemiesInCircle(zn.x, zn.z, zn.r, function(e)
					Weapons.hit(self, owner, e, zn.dmg, nil)
				end)
			end
		end
	end
end

function World._processBooms(self: World)
	local guard = 0
	while #self.booms > 0 and guard < 8 do
		guard += 1
		local list = self.booms
		self.booms = {}
		for _, b in list do
			if b.by.alive then
				Weapons.explode(self, b.by, b.x, b.z, b.r, b.dmg, { fromExplosion = true })
			end
		end
	end
	self.booms = {}
end

function World._updatePickups(self: World, dt: number)
	local list = self.pickups
	if #list == 0 then
		return
	end
	local keep = {}
	for _, c in list do
		local taken = false
		local p = if c.target then self.players[c.target] else nil
		if p and not isStanding(p) then
			c.target, p = nil, nil
		end
		if not p then
			local standing = self.standing
			if c.vacuum and #standing > 0 then
				-- spread the flying crumbs over the party (the XP is shared anyway)
				p = standing[(c.id % #standing) + 1]
				c.target = p.id
			else
				for _, q in standing do
					local pr = (q.stats.pickupRadius or 8) + World.PLAYER_RADIUS
					if (q.x - c.x) ^ 2 + (q.z - c.z) ^ 2 <= pr * pr then
						c.target, p = q.id, q
						break
					end
				end
			end
		end
		if p then
			local dx, dz = p.x - c.x, p.z - c.z
			local d = math.sqrt(dx * dx + dz * dz)
			local step = c.speed * dt
			c.speed += 70 * dt
			if d <= step + World.PLAYER_RADIUS then
				taken = true
				if c.vacuum and #self.standing > 1 then
					-- boss loot: every standing participant gets an equal share
					local share = c.xp / #self.standing
					for _, q in self.standing do
						self:event({ type = "xp", id = q.id, amount = share * (q.stats.xpMult or 1) })
					end
				else
					self:event({ type = "xp", id = p.id, amount = c.xp * (p.stats.xpMult or 1) })
				end
				self:emit({ t = "pickupTaken", id = c.id, by = p.id })
				local heal = (p.stats :: any).crumbHeal
				if type(heal) == "number" and heal > 0 then
					self:_heal(p, heal)
				end
			else
				c.x += dx / d * step
				c.z += dz / d * step
			end
		end
		if not taken then
			table.insert(keep, c)
		end
	end
	self.pickups = keep
end

function World._fallingRocks(self: World, now: number)
	if not self.mods.fallingRocks or #self.standing == 0 then
		return
	end
	if not (self.wave.active or (self.boss and self.boss.alive)) then
		return
	end
	if self.nextRockAt == nil then
		self.nextRockAt = now + 2
	end
	if now < self.nextRockAt then
		return
	end
	local rng = self.rockRng
	self.nextRockAt = now + World.ROCK_INTERVAL * rng:range(0.7, 1.3)
	local p = rng:pick(self.standing)
	local a, d = rng:range(0, TAU), rng:range(0, 10)
	local x, z = self:clampToArena(p.x + math.cos(a) * d, p.z + math.sin(a) * d, 1)
	local r = World.ROCK_RADIUS
	self:emit({ t = "tele", shape = "circle", x = x, z = z, r = r, delay = World.ROCK_WINDUP, style = "rock" })
	self:schedule(now + World.ROCK_WINDUP, nil, function()
		self:damagePlayersCircle(x, z, r, World.ROCK_DAMAGE * (self.mods.enemyDamageMult or 1), "rock")
		self:emit({ t = "slam", x = x, z = z, r = r, style = "rock" })
	end)
end

function World._compact(self: World)
	local list = self.enemies
	local n = 0
	for i = 1, #list do
		local e = list[i]
		if e.alive then
			n += 1
			list[n] = e
		else
			self.enemyById[e.id] = nil
		end
	end
	for i = #list, n + 1, -1 do
		list[i] = nil
	end
end

-- Main step -----------------------------------------------------------------------------------

function World.step(self: World, dt: number, now: number): { FxEvent }
	if not finite(dt) or dt <= 0 then
		dt = 1 / 30
	end
	dt = math.min(dt, 0.1)
	if not finite(now) then
		now = self.now + dt -- a broken clock must not poison timers
	end
	self.now = now
	self.stepped = true
	self.hitFx = 0
	table.clear(self.hitByEnemy)

	self:_updatePlayers(dt, now)

	local boss = self.boss
	if boss and boss.alive and not boss.enraged then
		boss.spawnedAt = boss.spawnedAt or now
		if now - boss.spawnedAt >= World.BOSS_ENRAGE_AFTER then
			self:_enrage(boss)
		end
	end

	-- spawning
	if self.wave.active then
		local reqs = self.wave:update(dt, self.liveCount, self.standing, self:partyWeight())
		local surged = false
		for _, r in reqs do
			self:spawnEnemy(r.id, r.x, r.z, r.elite)
			if r.surge then
				surged = true
			end
		end
		if surged then
			self:emit({ t = "surge" })
		end
	end

	self:_rebuildHash()
	self:_updateEnemies(dt, now)
	self:_runActions(now)
	self:_rebuildHash()

	for _, p in self.playerList do
		if isStanding(p) then
			Weapons.update(self, p, dt, now)
		end
	end
	self:_updatePlayerProjectiles(dt, now)
	self:_updateZones(now)
	self:_processBooms()
	self:_updateEnemyProjectiles(dt, now)
	self:_contactDamage()
	self:_fallingRocks(now)
	-- standing list may have changed (downs during this step)
	for i = #self.standing, 1, -1 do
		if not isStanding(self.standing[i]) then
			table.remove(self.standing, i)
		end
	end
	Pois.update(self, dt, now)
	self:_updatePickups(dt)
	self:_compact()

	local out = self.fx
	self.fx = {}
	table.clear(self.hitByEnemy) -- the batch is gone; later hits start fresh numbers
	return out
end

-- Points of interest + portal (GDD §3.8 / §3.9) -------------------------------------------------

-- Adds a POI entity: spec = {kind, x, z, r?, traps?} (Pois.layout entries fit).
-- Returns its id. It sleeps until the waves run. Emits Fx {t="poi", ...}.
function World.addPoi(self: World, spec: any): number
	self.nextPoiId += 1
	local e = Pois.newEntity(self.nextPoiId, spec, self.poiRng)
	e.active = self.poisLive
	table.insert(self.poiList, e)
	self.poiById[e.id] = e
	self:emit(Pois.stateFx(e))
	return e.id
end

-- Copies of every POI: {id, kind, x, z, r, state, progress, usedBy, active, mode, pack, traps?}.
function World.pois(self: World): { { [string]: any } }
	local out = {}
	for _, e in self.poiList do
		table.insert(out, Pois.copy(e))
	end
	return out
end

-- Opens / recolours / pulls / closes the Rind Gate portal. Emits Fx
-- {t="portal", x, z, phase, color} (color = {r, g, b} 0..255). "close" clears it.
function World.setPortal(
	self: World,
	x: number,
	z: number,
	phase: "open" | "pull" | "close",
	color: { number }?
)
	local px = if finite(x) then x else 0
	local pz = if finite(z) then z else 0
	local c = if type(color) == "table" then { color[1] or 255, color[2] or 204, color[3] or 51 } else nil
	self:emit({ t = "portal", x = px, z = pz, phase = phase, color = c })
	if phase == "close" then
		self.portalState = nil
	else
		self.portalState = { x = px, z = pz, phase = phase, color = c }
	end
end

-- {x, z, phase, color} of the open portal, or nil (bots walk in on "pull").
function World.portal(self: World): { x: number, z: number, phase: string, color: { number }? }?
	local s = self.portalState
	return if s then table.clone(s) else nil
end

-- Queries -------------------------------------------------------------------------------------

-- Effective party size of standing participants: humans 1, bots (Ids.isBot) BOT_WEIGHT.
function World.partyWeight(self: World): number
	local w = 0
	for _, p in self.standing do
		w += if Ids.isBot(p.id) then World.BOT_WEIGHT else 1
	end
	return w
end

-- Every participant (humans and bots) by id, for bot AI / HUDs. Plain copies.
function World.getPlayers(self: World): { [number]: any }
	local out = {}
	for _, p in self.playerList do
		out[p.id] = {
			id = p.id,
			x = p.x,
			z = p.z,
			hp = p.hp,
			maxHp = p.maxHp,
			downed = p.downed,
			dead = p.dead,
			abilityReadyAt = p.abilityReadyAt,
			isBot = Ids.isBot(p.id),
		}
	end
	return out
end

-- Crumbs within r of (x, z) as {x, z, xp} copies (for bots).
function World.pickupsNear(
	self: World,
	x: number,
	z: number,
	r: number
): { { x: number, z: number, xp: number } }
	local out = {}
	local r2 = r * r
	for _, c in self.pickups do
		if (c.x - x) ^ 2 + (c.z - z) ^ 2 <= r2 then
			table.insert(out, { x = c.x, z = c.z, xp = c.xp })
		end
	end
	return out
end

function World.snapshot(self: World): { EnemySnap }
	local out: { EnemySnap } = {}
	local now = self.now
	for _, e in self.enemies do
		if e.alive then
			local flags = 0
			if e.elite then
				flags += 1
			end
			if (e.telegraphUntil or 0) > now or e.leap then
				flags += 2
			end
			if e.stunned or now < e.slowUntil then
				flags += 4
			end
			if e.isMinion then
				flags += 8
			end
			table.insert(out, {
				id = e.id,
				kind = e.kind,
				x = e.x,
				z = e.z,
				hpFrac = math.clamp(e.hp / e.maxHp, 0, 1),
				flags = flags,
			})
		end
	end
	return out
end

function World.drainEvents(self: World): { WorldEvent }
	local ev = self.events
	self.events = {}
	return ev
end

function World.getPlayer(self: World, id: number): any?
	local p = self.players[id]
	if not p then
		return nil
	end
	local now = self.now
	return {
		hp = p.hp,
		maxHp = p.maxHp,
		downed = p.downed,
		downedUntil = p.downedUntil,
		dead = p.dead,
		abilityReadyAt = p.abilityReadyAt,
		x = p.x,
		z = p.z,
		reviveProgress = p.reviveProgress / World.REVIVE_TIME,
		secondWindUsed = p.secondWindUsed,
		slowed = now < p.slowUntil,
		hovering = now < p.hoverUntil,
		invulnerable = now < p.invulnUntil,
		moveSpeed = p.stats.moveSpeed,
	}
end

function World.allPlayersDown(self: World): boolean
	if #self.playerList == 0 then
		return false
	end
	for _, p in self.playerList do
		if isStanding(p) then
			return false
		end
	end
	return true
end

function World.bossAlive(self: World): boolean
	return self.boss ~= nil and self.boss.alive == true
end

function World.bossInfo(self: World): {
	id: string,
	hpFrac: number,
	phase: number,
	name: string,
	title: string,
	entityId: number,
	enraged: boolean,
}?
	local b = self.boss
	if not b or not b.alive then
		return nil
	end
	return {
		id = b.defId,
		hpFrac = math.clamp(b.hp / b.maxHp, 0, 1),
		phase = b.phase,
		name = b.def.name,
		title = b.def.title,
		entityId = b.id,
		enraged = b.enraged == true,
	}
end

function World.respawnDead(self: World, hpFrac: number)
	for _, p in self.playerList do
		if p.dead or p.downed then
			self:_revive(p, hpFrac, "respawn")
		end
	end
end

function World.enemyCount(self: World): number
	return self.liveCount
end

function World.pickupCount(self: World): number
	return #self.pickups
end

return World
