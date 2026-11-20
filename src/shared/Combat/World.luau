--!strict
-- Pure combat simulation (see docs/ARCHITECTURE.md "Team B"). No Instances, no physics:
-- enemies, projectiles, zones and pickups are plain tables moved with maths.
-- CombatService (server) feeds player positions in and broadcasts snapshots + Fx out.
--
-- Time: `now` passed to step() is the clock for everything (CombatService uses
-- workspace:GetServerTimeNow(), so abilityReadyAt / orbit t0 / Fx times are comparable
-- on clients). useAbility() uses the world clock (last step's now) once stepping has
-- begun, so a caller with a different clock cannot desync cooldowns.
--
-- v2 squads (docs/GDD-v2.md §2, docs/ARCHITECTURE-v2.md): every participant has a
-- squad (addPlayer's 7th argument, default 1). With two or more squads (`self.pvp`)
-- every weapon / ability / chain / explosion / zone also hits enemy-squad heroes
-- (Weapons.hitHero -> World.damageHeroFrom: x PVP_MULT, no crits, no friendly fire,
-- spawn protection, safe zones, gear resists). Downed heroes die to DOWNED_HITS
-- enemy hits; a squad with nobody standing is eliminated (squadEliminated) and its
-- downed members die. Heroes carry run-only gear (Run/Gear, Config/Gear): ground
-- items, swap offers, loot bags on death, golden carrier mice. See docs/COMBAT-API.md.

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
local SnapshotCodec = require("./SnapshotCodec")
local Gear = require("../Run/Gear")
local PoiConfig = require("../Config/Pois")
local Champions = require("./Champions")
local Maps = require("../Config/Maps")
local Storm = require("../Config/Storm")
local RunShop = require("../Config/RunShop")
local GemEffects = require("../Config/GemEffects")
local AscensionNodes = require("../Config/AscensionNodes")

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
		| "poiReward"
		-- v2 (docs/COMBAT-API.md "v2 squads")
		| "heroDowned"
		| "heroKilled"
		| "squadEliminated"
		| "gearPickup"
		| "gearSwapOffer"
		| "gearSwapDeclined"
		| "lootBag"
		| "poiAlert"
		| "totemLost"
		| "protectEnd"
		-- v3 Mouse Champions (Combat/Champions; the entity id is in `champ`)
		| "championSpawn"
		| "championEnrage"
		| "championDead"
		-- v4 The Melt
		| "stormDamage"
		-- v5 run currencies (Config/RunShop)
		| "rinds"
		| "whey"
		-- iteration 2 numbered waves
		| "waveStart"
		-- iteration 4
		| "minibossDead",
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
	-- v2
	safeZones: { [number]: { x: number, z: number, r: number } }?, -- per squad (ArenaBuilder)
	tier: string?, -- route tier "Low" | "Mid" | "High" (gear rarity rolls)
	carriers: boolean?, -- golden carrier mice during waves (default true; never with enemyCap 0)
	champions: boolean?, -- v3 Mouse Champions at the world's champion sites (default true)
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
World.DEFAULT_CAP = 300 -- v4: global live-mouse cap (was 220); also PER_HERO_CAP x standing heroes
World.PER_HERO_CAP = 28 -- v4 soft cap: live mice per standing hero
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
World.RANGED_FAN = math.rad(12) -- angle between the shots of a multi-projectile mouse volley
-- v2 PvP (GDD-v2 §2)
World.PVP_MULT = 0.35 -- v4: hero damage against enemy-squad heroes, and the armor they keep (was 0.3)
World.PVP_DAMAGE = 0.8 -- v4: extra x on PvP damage after PVP_MULT (match-health tuning with tests/sim/v4-report)
World.PVP_FOCUS_WINDOW = 1 -- v4: attackers that hit a hero within this many s count as focusing it...
World.PVP_FOCUS_FALLOFF = 0.5 -- ...each one deals x 1 / (1 + this x (focusing - 1)) (squad wipes, v4-report)
World.PVP_LOCKOUT = 0.5 -- v4: per-attacker lockout (replaces the shared i-frames in PvP)
World.PVP_ARMOR_MULT = 0.35 -- v4: share of the target's armor that counts against hero hits
World.PVP_MICE_IFRAMES = 0.5 -- v4: s of mice-only i-frames a hero hit gives its victim (0 = none)
World.DOWNED_HIT_GAP = 0.8 -- v4: > 0 = a downed hero takes at most one finishing hit per this many s (from anyone)
World.PVP_REGEN_PAUSE = 3 -- v4: s regen stops after taking PvP damage
World.PVP_CRIT_BONUS = 0.5 -- v4: crits on heroes deal this share of the crit bonus
World.STORM_TICK = 0.5 -- v4: s between storm damage ticks (dps x max HP x tick)
World.STORM_DOWNED_DRAIN = 2 -- v4: downed heroes outside the circle bleed out this much faster
World.STORM_RESEND = 10 -- v4: s between storm Fx re-sends (late joiners)
World.MOUSE_HP_PER_LEVEL = 0.03 -- v4: mouse HP x (1 + this x (average hero level - 1))
World.DENSITY_CHECK = 0.5 -- v4: s between per-hero "mice on screen" counts (spawn anchors)
World.FINAL_STAGE = 4
-- v5 iteration 1 (docs/iter/1/PLAN.md §A, §C)
World.ROOKIE_STAGES = 3 -- a rookie hero is never an enemy BOT's target up to this stage (iter 3 T-4: was 2)...
World.ROOKIE_SQUAD_STAGES = 2 -- ...and up to this stage its whole squad is protected (was 1):
World.BOT_SAFE_AFTER_REVIVE = 10 -- iter 3 T-4: s a revived / redeployed hero is not an enemy bot's target
World.BOT_FOCUS_WINDOW = 2 -- iter 3 T-4: one enemy bot at a time hits a human (this long after its last hit)
World.ROOKIE_MICE_DAMAGE = 0.75 -- mice / champions / boss damage to a rookie's squad
World.ROOKIE_SPAWN = 0.85 -- each rookie-squad hero counts this much for mouse spawning
World.FEW_SQUADS = 2 -- with at most this many squads in the world...
World.FEW_SQUADS_SPAWN = 1.25 -- ...mice spawn this much faster (fewer heroes to share them)
World.LURE_NEAR = 30 -- a standing hero with fewer than LURE_MIN_MICE mice this close...
World.LURE_MIN_MICE = 1
World.LURE_AFTER = 2 -- ...for this many s gets a cluster of LURE_BASE + stage mice...
World.LURE_BASE = 4
World.LURE_RING = { 20, 28 } -- ...this far away (inside the storm circle)...
World.LURE_AHEAD = math.rad(45) -- the cluster lands within this angle of the hero's heading
World.LURE_RETIRE_DIST = 60 -- at the cap, the lure retires plain mice at least this far from every hero
World.LURE_EVERY = 4 -- ...at most once per this many s per hero (inside the per-hero cap)
World.PVE_RESIST_MAX = 0.6
World.BOT_PVP_VS_HUMAN_SQUAD = 0.35 -- x damage enemy BOTS deal to a squad with a human in it (ladder tuning; iter 3: was 0.5)
World.META_HP_PVP_CAP = 1.25
-- iteration 2 numbered waves (ALIGNMENT §2b): RunDirector calls world:startWave(n)
World.WAVES_PER_STAGE = 5 -- the 5th is the boss wave
World.WAVE_SECONDS = 30 -- horde waves 1-4
World.WAVE_HP_STEP = 0.04 -- mouse HP +4% per wave inside a stage
World.FRONT_SHARE = 0.4 -- this share of a wave's budget opens it as storm-edge fronts...
World.FRONT_TIME = 6 -- ...over its first seconds (3 bursts)
World.FRONTS = { 2, 3 } -- fronts per wave
World.FRONT_SPAWN_EXP = 1 -- fronts scale with spawnRateMult ^ this (tier / Pressure)
World.FRONT_EDGE = 8 -- studs inside the storm circle (or arena edge) a front starts -- iteration 2: meta max HP (Prestige, Ascension, gems) counts at most +25% vs heroes -- cap on stats.pveResist
World.CATACLYSM_DELAY = 0.35 -- s between an ability and its Cataclysm repeat
World.BIG_KNOCK_CAP = 6 -- v4: max knockback velocity (studs/s) on bosses and champions
World.BOSS_ZONE_PULL = 30 -- v4: studs/s a boss outside the storm circle walks back in
World.BOSS_ZONE_MARGIN = 6 -- v4: ...to this far inside the edge (heroes keep ~15 inside it) -- v4: spawnBoss on this stage (or opts.final) is the final boss
World.HERO_AGGRO = 4 -- auto-weapons take an enemy hero this close even with mice closer (v4: was 10)
World.DOWNED_HITS = 9 -- enemy hits that finish a downed hero (v4: was 6; each attacker counts its own)
World.SPAWN_PROTECT = 5 -- s of PvP invulnerability after any revive...
World.DROP_PROTECT = 9 -- ...and at each stage's drop-in (was 5)
World.SAFE_ZONE_REDUCTION = 0.6 -- less damage from other squads inside your own safe zone
World.ELIM_GRACE = 5 -- s a fully-downed squad waits while a Second Wind is still usable
World.ASSIST_WINDOW = 5 -- a down by mice still credits a hero who hit you this recently
World.PROJECTILE_RESIST_MAX = 0.75
World.HERO_RESIST_MAX = 0.8
World.DODGE_MAX = 0.5
-- v2 gear and loot (GDD-v2 §3)
World.GEAR_PICKUP = 3 -- walk this close to a ground item to pick it up
World.SWAP_TIME = 4 -- s a swap offer stays open
World.GROUND_CAP = 60 -- ground items (oldest vanish beyond this)
World.BAG_RANGE = 4
World.BAG_CHANNEL = 1.5 -- s to pick up a loot bag (interrupted by damage)
World.BAG_MERGE_RADIUS = 3 -- addLootBag merges into a bag this close dropped this step...
World.BAG_MERGE_AGE = 1 -- ...or less than this many seconds ago
World.CARRIER_FIRST = 25 -- s into the waves before the first golden carrier
World.CARRIER_INTERVAL = { 40, 60 }
World.CARRIER_MAX = 2 -- alive at once
World.CARRIER_MIN_DIST = 30 -- spawn at least this far from every standing hero
World.CARRIER_FLEE = 30 -- flee heroes closer than this
-- v3 big maps: plain mice this far from every standing hero are recycled (no
-- drop), checked every STRAY_CHECK s, so the 220 cap stays near the squads.
World.STRAY_RADIUS = 160
World.STRAY_CHECK = 1
World.STRAY_ZONE_MARGIN = 12 -- v4: plain mice this far outside the storm circle are recycled
-- v3 out-of-combat sprint (Config/Maps.SPRINT): x mult after `calm` s without
-- damage and with no enemy within `clear` studs. getPlayer().walkSpeed carries it.
World.SPRINT = Maps.SPRINT

local TAU = math.pi * 2

export type World = typeof(setmetatable({} :: { [string]: any }, World))

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- v4: the storm circle's radius at `now` (Config/Storm.radiusAt)
local function zoneRadius(z: any, now: number): number
	return Storm.radiusAt(z, now)
end

function World.new(opts: Options): World
	local root = opts.rng
	local self = setmetatable({}, World) :: any
	self.rng = root:fork(2) -- combat rolls (crits, spreads)
	self.spawnRng = root:fork(1)
	self.bossRng = root:fork(3)
	self.rockRng = root:fork(4)
	self.poiRng = root:fork(5) -- trap layouts (forked last: older streams are unchanged)
	self.gearRng = root:fork(6) -- v2 gear rolls + carriers (forked after every older stream)
	self.mods = Defaults.fillMods(opts.mods)
	self.arenaRadius = opts.arenaRadius or 100
	self.obstacles = {}
	for _, o in opts.obstacles or {} do
		table.insert(self.obstacles, { x = o.x, z = o.z, r = o.r })
	end
	self.obsGrid = {}
	self.obsGridN = -1 -- built on first use
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
	self.hitShare = {} -- v4: enemy id -> {[heroId] = damage} behind that merged fx
	self.maxEnemyR = 2.5
	self.forcePattern = nil -- tests/debug: boss always runs this pattern
	-- Points of interest (Combat/Pois.luau): live only while the waves run.
	self.poiList = {}
	self.poiById = {}
	self.nextPoiId = 0
	self.poisLive = false
	self.poiResyncAt = 0
	self.portalState = nil -- Rind Gate portal after the boss (GDD §3.9)
	-- v2 squads / PvP / gear
	self.tier = opts.tier or "Low"
	self.safeZones = {}
	self:setSafeZones(opts.safeZones)
	self.pvp = false -- two or more squads registered
	self.squadState = {} -- squad -> {eliminated, elimAt}
	self.squadDmg = {} -- squad -> damage mult (Power Totem owner)
	self.heroTargets = {} -- non-dead participants (rebuilt each step)
	self.bossDamage = {} -- squad -> damage dealt to the current boss
	self.ground = {} -- ground gear items
	self.nextGroundId = 0
	self.bags = {} -- loot bags
	self.nextBagId = 0
	self.carriersOn = opts.carriers ~= false and self.cap > 0
	self.nextCarrierAt = nil
	-- v3 Mouse Champions (Combat/Champions): own rng stream (forked last)
	self.champRng = root:fork(7)
	self.champ = Champions.newState()
	self.champsOff = opts.champions == false
	self.nextStrayAt = 0
	-- v4 The Melt (Config/Storm): the closing circle, the optional auto plan, and
	-- per-hero levels (mouse / champion / boss HP scale with the average)
	self.zoneState = nil :: any
	self.stormPlan = nil :: any
	self.nextStormTick = 0
	self.stormFxAt = 0
	self.safeOff = false
	self.levelAvg = 1
	-- v5: run-shop stat layers, squad auras (charms), rinds / whey trickle
	self.waveIndex = nil :: number? -- iteration 2: match wave number (1..20), nil = no numbered waves
	self.stageWave = nil :: number? -- ...and the wave inside the stage (1..5)
	self.squadAura = {} -- squad -> StatDelta
	self.squadClassAura = {} -- squad -> {[classId] = StatDelta} (iteration 2 gem class uniques)
	self.squadUniques = {} -- squad -> {aura, classes} from GemEffects.resolve (P's runBonuses uniques)
	self.rookieSquads = {} -- squad -> true (refreshed every step)
	self.humanSquads = {} -- squad -> true: has a human (refreshed with rookieSquads)
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

-- v3 big maps (60-90 obstacles): a bucket grid so each mover only looks at the
-- obstacles near it. Each obstacle sits in every OBS_CELL cell its circle,
-- grown by OBS_PAD, touches; `_obstaclesNear(x, z, need)` returns the bucket of
-- (x, z), exact for any query whose reach (radius + margin) is <= OBS_PAD, and
-- the full list otherwise. Rebuilt when the obstacle count changes.
World.OBS_CELL = 16
World.OBS_PAD = 12
local NO_OBSTACLES = table.freeze({})

function World._buildObstacleGrid(self: World)
	local grid = {}
	local cell, pad = World.OBS_CELL, World.OBS_PAD
	for _, o in self.obstacles do
		local reach = o.r + pad
		for cx = math.floor((o.x - reach) / cell), math.floor((o.x + reach) / cell) do
			for cz = math.floor((o.z - reach) / cell), math.floor((o.z + reach) / cell) do
				local key = cx * 65536 + cz
				local list = grid[key]
				if not list then
					list = {}
					grid[key] = list
				end
				table.insert(list, o)
			end
		end
	end
	self.obsGrid = grid
	self.obsGridN = #self.obstacles
end

function World._obstaclesNear(self: World, x: number, z: number, need: number): { any }
	if need > World.OBS_PAD or not finite(x) or not finite(z) then
		return self.obstacles
	end
	if self.obsGridN ~= #self.obstacles then
		self:_buildObstacleGrid()
	end
	local cell = World.OBS_CELL
	return self.obsGrid[math.floor(x / cell) * 65536 + math.floor(z / cell)] or NO_OBSTACLES
end

function World.pushOutOfObstacles(self: World, x: number, z: number, r: number): (number, number)
	for _, o in self:_obstaclesNear(x, z, r) do
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
	z: number,
	squad: number?
)
	local oldGear = nil
	if self.players[id] then
		oldGear = self.players[id].gear
		self:removePlayer(id, true)
	end
	local s = Defaults.fillStats(stats)
	local p = {
		id = id,
		isHero = true, -- Weapons.hit routes hero records to Weapons.hitHero
		r = World.PLAYER_RADIUS,
		squad = World._validSquad(squad),
		stats = s,
		weapon = weapon,
		ability = ability,
		-- v2 gear: base = pre-gear stats/weapon/ability; `external` = the caller
		-- applied gear itself (Run/Gear.apply marks stats.gearApplied)
		base = { stats = s, weapon = weapon, ability = ability },
		external = (stats :: any).gearApplied == true,
		gear = oldGear or {},
		swap = nil :: any,
		derived = Weapons.derive(s, weapon),
		x = if finite(x) then x else 0,
		z = if finite(z) then z else 0,
		faceX = 1,
		faceZ = 0,
		hp = s.maxHp,
		maxHp = s.maxHp,
		downed = false,
		downedUntil = nil :: number?,
		downedHits = 0,
		downedBy = nil :: number?,
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
		protectUntil = 0,
		protectPending = World.DROP_PROTECT :: number?, -- drop-in protection, starts at the next step
		lastHitBy = nil :: number?,
		lastHitAt = -math.huge,
		alive = true, -- for scheduled-action ownership
	}
	self.players[id] = p
	table.insert(self.playerList, p)
	if (not p.external and next(p.gear) ~= nil) or self.squadAura[p.squad] then
		self:_applyGear(p)
	end
	self:_refreshSquads()
end

function World._validSquad(squad: any): number
	if type(squad) == "number" and squad == squad and squad >= 1 and squad <= 64 then
		return math.floor(squad)
	end
	return 1
end

-- `keepGear`: addPlayer re-adding the same id (the gear moves to the new record).
-- Otherwise a leaving hero's gear drops as a loot bag where they stood.
function World.removePlayer(self: World, id: number, keepGear: boolean?)
	local p = self.players[id]
	if not p then
		return
	end
	if not keepGear and not p.dead then
		self:_dropBagOf(p)
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
	self:_refreshSquads()
end

-- Recomputes self.pvp (two or more squads) and makes sure each squad has a state.
function World._refreshSquads(self: World)
	local seen, n = {}, 0
	for _, p in self.playerList do
		if not seen[p.squad] then
			seen[p.squad] = true
			n += 1
		end
		if not self.squadState[p.squad] then
			self.squadState[p.squad] = { eliminated = false, elimAt = nil }
		end
	end
	self.pvp = n >= 2
	self:_rebuildTargets()
end

function World._rebuildTargets(self: World)
	local t = self.heroTargets
	table.clear(t)
	for _, p in self.playerList do
		if not p.dead then
			table.insert(t, p)
		end
	end
end

-- Moves a participant to another squad (RunDirector's squad assignment).
function World.setSquad(self: World, id: number, squad: number)
	local p = self.players[id]
	if p then
		p.squad = World._validSquad(squad)
		self:_refreshSquads()
		if next(self.squadAura) ~= nil or p.runMods ~= nil then
			self:_applyGear(p) -- the squad aura follows the hero
		end
	end
end

function World.squadOf(self: World, id: number): number?
	local p = self.players[id]
	return if p then p.squad else nil
end

-- Ids of every member of a squad (downed and dead included).
function World.squadMembers(self: World, squad: number): { number }
	return Pois.squadIds(self, squad)
end

-- Squads with at least one member who is not dead and that are not eliminated (sorted).
function World.aliveSquads(self: World): { number }
	local set, out = {}, {}
	for _, p in self.playerList do
		local st = self.squadState[p.squad]
		if not p.dead and not (st and st.eliminated) and not set[p.squad] then
			set[p.squad] = true
			table.insert(out, p.squad)
		end
	end
	table.sort(out)
	return out
end

function World.isEliminated(self: World, squad: number): boolean
	local st = self.squadState[squad]
	return st ~= nil and st.eliminated == true
end

-- {[squad] = {x, z, r}}: members take SAFE_ZONE_REDUCTION less damage from other
-- squads inside their own zone (ArenaBuilder safeZones).
function World.setSafeZones(self: World, zones: any)
	local out = {}
	if type(zones) == "table" then
		for sq, zn in zones do
			if
				type(sq) == "number"
				and type(zn) == "table"
				and finite(zn.x)
				and finite(zn.z)
				and finite(zn.r)
				and zn.r > 0
			then
				out[sq] = { x = zn.x, z = zn.z, r = zn.r }
			end
		end
	end
	self.safeZones = out
end

function World.inSafeZone(self: World, p: any): boolean
	if self.safeOff then
		return false -- v4: the storm owns the map after Storm.SAFE_CORNERS_OFF
	end
	local zn = self.safeZones[p.squad]
	return zn ~= nil and (p.x - zn.x) ^ 2 + (p.z - zn.z) ^ 2 <= zn.r * zn.r
end

-- Spawn protection (PvP invulnerability) for `seconds` (default SPAWN_PROTECT).
function World.protect(self: World, id: number, seconds: number?)
	local p = self.players[id]
	if not p then
		return
	end
	local dur = if finite(seconds) then math.max(0, seconds :: number) else World.SPAWN_PROTECT
	if self.stepped then
		self:_setProtect(p, self.now + dur)
	else
		p.protectPending = dur
	end
end

function World._setProtect(self: World, p: any, untilT: number)
	p.protectPending = nil
	p.protectUntil = untilT
	self:emit({ t = "protect", id = p.id, untilT = untilT })
end

function World.updatePlayer(self: World, id: number, stats: PlayerStats, weapon: WeaponDef)
	local p = self.players[id]
	if not p then
		return
	end
	p.external = (stats :: any).gearApplied == true
	p.base.stats = Defaults.fillStats(stats)
	p.base.weapon = weapon
	self:_applyGear(p)
end

-- Stores effective stats (keeps the hp ratio, re-derives the weapon).
function World._setStats(_self: World, p: any, s: PlayerStats, weapon: WeaponDef, ability: AbilityDef?)
	local ratio = if p.maxHp > 0 then p.hp / p.maxHp else 1
	p.stats = s
	p.weapon = weapon
	if ability then
		p.ability = ability
	end
	p.maxHp = s.maxHp
	p.hp = math.clamp(ratio * s.maxHp, 0, s.maxHp)
	if isStanding(p) and p.hp < 1 then
		p.hp = math.min(1, s.maxHp)
	end
	p.derived = Weapons.derive(s, weapon)
	p.orbitDirty = true
end

-- Applies p.gear over p.base (unless the caller applies gear itself).
-- Effective stats = base -> gear (unless the caller applied it) -> v5 run mods ->
-- the squad aura. Every stat change goes through here.
function World._applyGear(self: World, p: any)
	local st, w, a = p.base.stats, p.base.weapon, p.base.ability
	if not p.external and next(p.gear) ~= nil then
		local gs, gw, ga = Gear.apply(p.base.stats, p.base.weapon, p.base.ability, p.gear)
		st = Defaults.fillStats(gs);
		(st :: any).gearApplied = nil
		w, a = gw or w, ga or a
	end
	local ls = self:_layerStats(p, st)
	-- iteration 2 Ascension node 2: the ability's area x abilityAreaMult
	local am = ls.abilityAreaMult
	if a and finite(am) and am > 0 and am ~= 1 and finite(a.area) then
		a = table.clone(a)
		a.area *= am
	end
	self:_setStats(p, ls, w, a)
end

-- Default of a stat a delta touches before anything set it (x...Mult keys: 1).
local function statDefault(k: string): number
	return if string.sub(k, -4) == "Mult" then 1 else 0
end

-- pveOnly (meta layers): damageMult is read as pveDamageMult, so long-term progress
-- never adds PvP damage (iteration 2 "meta never decides PvP").
local function applyDelta(s: any, d: any?, pveOnly: boolean?)
	if type(d) ~= "table" then
		return
	end
	if type(d.add) == "table" then
		for k, v in d.add do
			if finite(v) and k ~= "gearApplied" then
				local key = if pveOnly and k == "damageMult" then "pveDamageMult" else k
				s[key] = (if finite(s[key]) then s[key] else statDefault(key)) + v
			end
		end
	end
	if type(d.mul) == "table" then
		for k, v in d.mul do
			if finite(v) and k ~= "gearApplied" then
				local key = if pveOnly and k == "damageMult" then "pveDamageMult" else k
				s[key] = (if finite(s[key]) then s[key] else statDefault(key)) * v
			end
		end
	end
end

-- v5 layers (run mods, squad aura) on top of the gear-applied stats; a copy.
function World._layerStats(self: World, p: any, st: any): any
	local aura = self.squadAura[p.squad]
	local classAura = self.squadClassAura[p.squad]
	local cls = classAura and p.classId and classAura[p.classId]
	local uq = self.squadUniques[p.squad]
	local uqCls = uq and uq.classes and p.classId and uq.classes[p.classId]
	local hu = p.heroUniques
	local huCls = hu and hu.classes and p.classId and hu.classes[p.classId]
	local baked = st.metaHpMult -- meta max HP already inside the stats (P's runBonus via Stats.compute)
	local bakedRatio = if finite(baked) and baked > 1 then baked else 1
	if
		p.runMods == nil
		and aura == nil
		and p.metaMods == nil
		and cls == nil
		and uq == nil
		and p.ascMods == nil
		and hu == nil
	then
		p.metaHpRatio = bakedRatio
		return st
	end
	local s = table.clone(st)
	applyDelta(s, p.runMods)
	-- iteration 2 meta layers (Prestige, Ascension, gems): PvE-only damage, and
	-- their max HP counts at most META_HP_PVP_CAP against heroes (damageHeroFrom)
	local hpBefore = math.max(1, s.maxHp)
	applyDelta(s, p.metaMods, true)
	applyDelta(s, aura, true)
	applyDelta(s, cls, true)
	applyDelta(s, p.ascMods, true)
	applyDelta(s, uq and uq.aura, true)
	applyDelta(s, uqCls, true)
	applyDelta(s, hu and hu.aura, true)
	applyDelta(s, huCls, true)
	p.metaHpRatio = bakedRatio * math.max(1, s.maxHp) / hpBefore
	s.maxHp = math.max(1, s.maxHp)
	s.moveSpeed = math.max(1, s.moveSpeed)
	s.attackSpeedMult = math.max(0.1, s.attackSpeedMult)
	s.cooldownMult = math.max(0.1, s.cooldownMult)
	s.critChance = math.clamp(s.critChance, 0, 1)
	return s
end

-- Iteration 2: the long-term meta layer of one hero (Prestige, Ascension nodes; P / M2
-- build it, e.g. Config/AscensionNodes.combine). Damage in it counts PvE only and its
-- max HP at most META_HP_PVP_CAP against heroes. nil clears it.
function World.setMetaMods(self: World, id: number, mods: any?)
	local p = self.players[id]
	if not p then
		return
	end
	p.metaMods = if type(mods) == "table" then mods else nil
	self:_applyGear(p)
end

-- Iteration 2 with P's DataService.runBonuses: the squad's active gem unique ids
-- (`uniques`, each once per squad; Config/GemEffects). nil / {} clears.
function World.setSquadUniques(self: World, squad: number, ids: { string }?)
	local sq = World._validSquad(squad)
	local aura, classes = GemEffects.resolve(ids)
	self.squadUniques[sq] = if aura or classes then { aura = aura, classes = classes } else nil
	for _, p in self.playerList do
		if p.squad == sq then
			self:_applyGear(p)
		end
	end
end

-- Iteration 4 (gems are personal): the hero's own active gem unique ids. Generic
-- uniques apply to the hero; a class unique only when the hero is that class
-- (setHeroClass / setAscension). A meta layer. nil / {} clears.
function World.setHeroUniques(self: World, id: number, ids: { string }?)
	local p = self.players[id]
	if not p then
		return
	end
	local aura, classes = GemEffects.resolve(ids)
	p.heroUniques = if aura or classes then { aura = aura, classes = classes } else nil
	self:_applyGear(p)
end

-- Iteration 2 with P's runBonuses: the hero's class and `extras.ascNodes` (0..8). World
-- adds the BEHAVIOUR nodes (AscensionNodes.behaviours); P's numbers are in the stats.
function World.setAscension(self: World, id: number, classId: string, nodes: number)
	local p = self.players[id]
	if not p then
		return
	end
	p.classId = classId
	local d = AscensionNodes.behaviours(classId, nodes)
	p.ascMods = if next(d.add) ~= nil or next(d.mul) ~= nil then d else nil
	self:_applyGear(p)
end

-- Iteration 4 aim toggle: mode "nearest" (default) or "cursor" with the aim point (x, z),
-- clamped into the arena. Bots always stay on "nearest". Returns the stored mode.
function World.setAim(self: World, id: number, mode: string, x: number?, z: number?): string
	local p = self.players[id]
	if not p then
		return "nearest"
	end
	if mode ~= "cursor" or Ids.isBot(id) then
		p.aimMode = "nearest"
		return "nearest"
	end
	p.aimMode = "cursor"
	if finite(x) and finite(z) then
		local ax, az = self:clampToArena(x :: number, z :: number, 0)
		p.aimX, p.aimZ = ax, az
	end
	return "cursor"
end

-- Iteration 2: a hero's class id (for class-specific squad auras).
function World.setHeroClass(self: World, id: number, classId: string?)
	local p = self.players[id]
	if p then
		p.classId = classId
		self:_applyGear(p)
	end
end

-- v5: the run-shop stat layer of one hero (RunShop.combine: ranks, whey buffs, the
-- class buff, ultimates). nil clears it. Keeps the HP fraction like any stat change.
function World.setRunMods(self: World, id: number, mods: any?)
	local p = self.players[id]
	if not p then
		return
	end
	p.runMods = if type(mods) == "table" then mods else nil
	self:_applyGear(p)
end

-- v5 / iteration 2: a squad-wide aura (gems, Ascension node 8; a StatDelta) for
-- every member, bots included, plus optional per-class deltas {[classId] = delta}
-- (gem class uniques: "that class in your squad"; heroes need setHeroClass). nil
-- clears. A meta layer: damage counts PvE only, max HP is PvP-capped.
function World.setSquadAura(self: World, squad: number, aura: any?, classAuras: any?)
	local sq = World._validSquad(squad)
	self.squadAura[sq] = if type(aura) == "table" then aura else nil
	self.squadClassAura[sq] = if type(classAuras) == "table" then classAuras else nil
	for _, p in self.playerList do
		if p.squad == sq then
			self:_applyGear(p)
		end
	end
end

-- Ability defs can change too (class swap mid-run is unlikely, but cheap to support).
function World.setPlayerAbility(self: World, id: number, ability: AbilityDef)
	local p = self.players[id]
	if p then
		p.base.ability = ability
		self:_applyGear(p)
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
	-- iteration 2 Ascension node 5: an echo of the ability at abilityEcho x damage
	local echo = p.stats.abilityEcho
	if finite(echo) and echo > 0 then
		self:schedule(t + World.CATACLYSM_DELAY * 1.5, p, function(at: number)
			if isStanding(p) then
				local saved = p.stats
				local es = table.clone(saved)
				es.damageMult = (es.damageMult or 1) * math.min(echo, 1)
				p.stats = es
				Weapons.useAbility(self, p, aimX, aimZ, at)
				p.stats = saved
			end
		end)
	end
	-- v5 Cataclysm (RunShop ultimate): the ability fires again a moment later
	local rep = p.stats.abilityRepeat
	if finite(rep) and rep >= 1 then
		for k = 1, math.min(3, math.floor(rep)) do
			self:schedule(t + World.CATACLYSM_DELAY * k, p, function(at: number)
				if isStanding(p) then
					Weapons.useAbility(self, p, aimX, aimZ, at)
				end
			end)
		end
	end
	return true
end

-- v5 rinds / whey (Config/RunShop) ------------------------------------------------------------

-- x rinds for hero p: stats.rindMult x TOTEM_RIND_MULT while its squad holds a Power Totem.
function World._rindMult(self: World, p: any): number
	local m = p.stats.rindMult
	m = if finite(m) and m > 0 then m else 1
	if self.squadDmg[p.squad] then
		m *= RunShop.TOTEM_RIND_MULT
	end
	return m
end

-- Gives hero p `amount` rinds (event `rinds {id, amount, kind}`) and the whey trickle
-- (+1 per RunShop.WHEY_PER_RINDS rinds earned, x wheyMult: event `whey {id, amount, kind = "rinds"}`).
function World._grantRinds(self: World, p: any, amount: number, kind: string)
	if not finite(amount) or amount <= 0 then
		return
	end
	self:event({ type = "rinds", id = p.id, amount = amount, kind = kind })
	local acc = (p.rindAcc or 0) + amount
	local n = math.floor(acc / RunShop.WHEY_PER_RINDS)
	p.rindAcc = acc - n * RunShop.WHEY_PER_RINDS
	if n > 0 then
		self:_grantWhey(p, n, "rinds")
	end
end

function World._grantWhey(self: World, p: any, amount: number, kind: string)
	local wm = p.stats.wheyMult
	local v = amount * (if finite(wm) and wm > 0 then wm else 1)
	if v > 0 then
		self:event({ type = "whey", id = p.id, amount = v, kind = kind })
	end
end

-- A mouse kill: the killer gets the drop, standing squadmates within SHARE_RADIUS get SHARE.
function World._rindsForKill(self: World, e: any, by: any)
	if not by or not by.isHero or e.isMinion or e.champOf then
		return
	end
	local base = RunShop.rindsFor(if e.elite then "elite" else "mouse", self.stage)
	self:_grantRinds(by, base * self:_rindMult(by), "kill")
	local r2 = RunShop.SHARE_RADIUS * RunShop.SHARE_RADIUS
	for _, q in self.standing do
		if q ~= by and q.squad == by.squad and (q.x - by.x) ^ 2 + (q.z - by.z) ^ 2 <= r2 then
			self:_grantRinds(q, base * RunShop.SHARE * self:_rindMult(q), "share")
		end
	end
end

-- A champion / boss: its rinds split by squad damage share (every member of a
-- squad, dead ones too: rinds are kept on death, get their squad's part); champions
-- also give whey (WHEY.championTop to the top-damage squad's members, championOther
-- to every other squad that hit it).
function World._rindsForBig(self: World, kind: string, dmgBySquad: { [number]: number }, top: number?)
	local total = 0
	for _, d in dmgBySquad do
		total += if finite(d) and d > 0 then d else 0
	end
	if total <= 0 then
		return
	end
	local base = RunShop.rindsFor(kind, self.stage)
	for _, p in self.playerList do
		local d = dmgBySquad[p.squad]
		if finite(d) and d > 0 then
			self:_grantRinds(p, base * d / total * self:_rindMult(p), kind)
			if kind == "champion" then
				self:_grantWhey(
					p,
					if p.squad == top then RunShop.WHEY.championTop else RunShop.WHEY.championOther,
					"champion"
				)
			end
		end
	end
end

function World._revive(self: World, p: any, hpFrac: number, kind: string)
	p.downed = false
	p.dead = false
	p.downedUntil = nil
	p.reviveProgress = 0
	p.hp = math.max(1, p.maxHp * hpFrac)
	p.invulnUntil = math.max(p.invulnUntil, self.now + World.REVIVE_GRACE)
	p.downedHits = 0
	p.downedBy = nil
	p.burnUntil = nil
	local wasOut = false
	local st = self.squadState[p.squad]
	if st and st.eliminated then
		st.eliminated = false -- a respawn / statue brings the squad back
		wasOut = true
	end
	if wasOut or not self:_inList(self.heroTargets, p) then
		self:_rebuildTargets()
	end
	-- v2 spawn protection after every revive (PvP only; GDD-v2 §2)
	if self.stepped then
		self:_setProtect(p, self.now + World.SPAWN_PROTECT)
	else
		p.protectPending = World.SPAWN_PROTECT
	end
	p.botSafeUntil = self.now + World.BOT_SAFE_AFTER_REVIVE -- iteration 3 T-4
	self:emit({ t = "revive", id = p.id, x = p.x, z = p.z, kind = kind })
	self:event({ type = "revived", id = p.id, kind = kind })
	-- v4: champion gear earned while dead (Combat/Champions) arrives now
	local pending = p.pendingGear
	if pending then
		p.pendingGear = nil
		for _, item in pending do
			self:giveGear(p.id, item)
		end
	end
end

function World._inList(_self: World, list: { any }, v: any): boolean
	return table.find(list, v) ~= nil
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
	local hm = p.stats.healMult -- iteration 2 gem unique Spring Source
	p.hp = math.min(
		p.maxHp,
		p.hp + amount * (self.mods.healingMult or 1) * (if finite(hm) and hm > 0 then hm else 1)
	)
end

-- Public: heal participant `id` by `frac` of max HP (StatDelta.heal semantics, x healingMult).
function World.healPlayer(self: World, id: number, frac: number)
	local p = self.players[id]
	if p and finite(frac) and frac > 0 then
		self:_heal(p, p.maxHp * frac)
	end
end

-- Hero credited for a down / kill: the attacker, else a hero who hit `p` within
-- ASSIST_WINDOW (a down by mice right after a rival's shots still counts).
function World._creditFor(self: World, p: any, by: any?): number?
	if by and by.isHero and by.squad ~= p.squad then
		return by.id
	end
	if p.lastHitBy and self.now - (p.lastHitAt or -math.huge) <= World.ASSIST_WINDOW then
		return p.lastHitBy
	end
	return nil
end

function World._down(self: World, p: any, by: any?)
	p.hp = 0
	p.downed = true
	local bonus = p.stats.downedTimeBonus
	p.downedUntil = self.now + World.DOWNED_TIME + (if finite(bonus) and bonus > 0 then bonus else 0)
	p.reviveProgress = 0
	p.downedHits = 0
	p.shield = nil
	p.burnUntil = nil
	p.downedBy = self:_creditFor(p, by)
	self:emit({ t = "down", id = p.id, x = p.x, z = p.z, untilT = p.downedUntil, by = p.downedBy })
	self:event({ type = "downed", id = p.id })
	self:event({ type = "heroDowned", id = p.id, by = p.downedBy, squad = p.squad })
end

-- A downed (or standing) hero dies: v1 "dead" + v2 "heroKilled". Their gear drops
-- in a loot bag (bag id in the event; RunDirector may add cheese with addLootBag).
function World._kill(self: World, p: any, byId: number?)
	if p.dead then
		return
	end
	p.hp = 0
	p.downed = false
	p.dead = true
	p.downedUntil = nil
	p.reviveProgress = 0
	p.burnUntil = nil
	local bag = self:_dropBagOf(p)
	self:_rebuildTargets()
	local bp = byId and self.players[byId]
	self:emit({ t = "dead", id = p.id })
	self:emit({
		t = "heroKill",
		id = p.id,
		by = byId,
		x = p.x,
		z = p.z,
		squad = p.squad,
		bySquad = if bp then bp.squad else nil,
	})
	self:event({ type = "dead", id = p.id })
	self:event({
		type = "heroKilled",
		id = p.id,
		by = byId,
		squad = p.squad,
		bySquad = if bp then bp.squad else nil,
		x = p.x,
		z = p.z,
		bag = bag,
	})
end

-- Applies armor, i-frames, shields, hover and oneHitKO (v2: gear dodge and
-- projectile resist; `by` = the attacking hero for PvP). Returns damage taken.
function World.damagePlayer(self: World, p: any, amount: number, source: string?, by: any?): number
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
	-- v4 PvP channel: hero hits ignore the shared i-frames (and never set them);
	-- each attacker has its own PVP_LOCKOUT. A bigger hit inside the lockout only
	-- tops up the difference (an ability landing with a weapon hit still counts).
	local pvp = by ~= nil and by.isHero == true
	local lock = nil
	if pvp then
		p.pvpLock = p.pvpLock or {}
		lock = p.pvpLock[by.id]
		if lock and now < lock.untilT and amount <= lock.amount then
			return 0
		end
	elseif now < p.iframeUntil then
		return 0
	end
	local st = p.stats
	local dodge = st.dodge
	if finite(dodge) and dodge > 0 and self.rng:chance(math.min(dodge, World.DODGE_MAX)) then
		if pvp then
			p.pvpLock[by.id] = { untilT = now + World.PVP_LOCKOUT, amount = amount }
		else
			p.iframeUntil = now + World.IFRAMES * 0.5
		end
		self:emit({ t = "dodge", id = p.id, x = p.x, z = p.z })
		return 0
	end
	if source == "projectile" then
		local res = st.projectileResist
		if finite(res) and res > 0 then
			amount *= 1 - math.min(res, World.PROJECTILE_RESIST_MAX)
		end
	end
	local dmg
	if self.mods.oneHitKO and not by then
		dmg = p.hp
	elseif pvp then
		if lock and now < lock.untilT then
			dmg = amount - lock.amount -- top-up: armor was already paid by the first hit
			lock.amount = amount
		else
			dmg = math.max(1, amount - (st.armor or 0) * World.PVP_ARMOR_MULT)
			p.pvpLock[by.id] = { untilT = now + World.PVP_LOCKOUT, amount = amount }
		end
		p.pvpRegenUntil = now + World.PVP_REGEN_PAUSE
	else
		-- v5 Bulwark / Titan-style damageTakenMult, Herdguard, v4.1 rookie squads
		amount *= self:_pveTakenMult(p)
		dmg = math.max(1, amount - (st.armor or 0))
	end
	p.hp -= dmg
	if not pvp then
		p.iframeUntil = now + World.IFRAMES
	elseif World.PVP_MICE_IFRAMES > 0 then
		-- mice i-frames only: hero hits still go through the per-attacker lockout
		p.iframeUntil = math.max(p.iframeUntil, now + World.PVP_MICE_IFRAMES)
	end
	p.lastHurtAt = now -- interrupts POI channels (Pois.HURT_PAUSE)
	local byId = nil
	if by and by.isHero then
		byId = by.id
		p.lastHitBy = by.id
		p.lastHitAt = now
	end
	self:emit({ t = "hurt", id = p.id, amount = math.floor(dmg + 0.5), x = p.x, z = p.z, by = byId })
	self:event({ type = "damaged", id = p.id, amount = dmg, kind = source, by = byId })
	if p.hp <= 0 then
		self:_down(p, by)
	end
	return dmg
end

-- PvP: `base` damage from hero `by` to hero `h` (Weapons.hitHero). No friendly
-- fire; x PVP_MULT x totem x heroDamageMult; spawn protection blocks it; less
-- inside the target's own safe zone and with heroResist. A downed target takes
-- hits instead of HP: DOWNED_HITS (+ downedHitsBonus) of them kill. Returns the
-- damage dealt (a downed hit counts as its nominal damage).
function World.damageHeroFrom(self: World, h: any, base: number, by: any, source: string?): number
	if h.dead or not by or h == by or not finite(base) or base <= 0 then
		return 0
	end
	if h.squad == by.squad then
		return 0 -- no friendly fire
	end
	local now = self.now
	if (h.protectUntil or 0) > now then
		return 0
	end
	if (by.protectUntil or 0) > now then
		-- attacking another squad ends your own spawn protection
		self:_setProtect(by, 0)
		self:event({ type = "protectEnd", id = by.id })
	end
	if self:_rookieSafe(by, h) then
		return 0 -- iteration 3 T-4: rookies, fresh revives, one bot at a time on a human
	end
	if Ids.isBot(by.id) and not Ids.isBot(h.id) then
		h.botFocus, h.botFocusAt = by.id, now
	end
	local amt = base * World.PVP_MULT * World.PVP_DAMAGE
	if Ids.isBot(by.id) and self.humanSquads[h.squad] then
		amt *= World.BOT_PVP_VS_HUMAN_SQUAD
	end
	-- v4 focus fire: every extra attacker on the same hero adds a little less
	local foc = h.pvpFocus
	if not foc then
		foc = {}
		h.pvpFocus = foc
	end
	foc[by.id] = now
	local focusing = 0
	for id, t in foc do
		if now - t <= World.PVP_FOCUS_WINDOW then
			focusing += 1
		else
			foc[id] = nil
		end
	end
	if focusing > 1 then
		amt /= 1 + World.PVP_FOCUS_FALLOFF * (focusing - 1)
	end
	local wm = by.weapon and by.weapon.pvpMult -- v4 per-class PvP weight (Fizzante 0.8)
	if finite(wm) and wm > 0 then
		amt *= wm
	end
	local sq = self.squadDmg[by.squad]
	if sq then
		amt *= sq
	end
	local hm = by.stats.heroDamageMult
	if finite(hm) and hm > 0 then
		amt *= hm
	end
	local res = h.stats.heroResist
	if finite(res) and res > 0 then
		amt *= 1 - math.min(res, World.HERO_RESIST_MAX)
	end
	-- iteration 2: meta max HP beyond +25% does not count against heroes
	local ratio = h.metaHpRatio
	if not finite(ratio) then
		ratio = h.stats.metaHpMult -- set before any layer pass (addPlayer)
	end
	if finite(ratio) and ratio > World.META_HP_PVP_CAP then
		amt *= ratio / World.META_HP_PVP_CAP
	end
	if self:inSafeZone(h) then
		amt *= 1 - World.SAFE_ZONE_REDUCTION
	end
	if h.downed then
		-- v4: per-attacker lockout, so three attackers finish a downed hero 3x faster
		h.pvpLock = h.pvpLock or {}
		local lk = h.pvpLock[by.id]
		if lk and now < lk.untilT then
			return 0
		end
		if World.DOWNED_HIT_GAP > 0 then
			if now < (h.downedHitAt or -math.huge) + World.DOWNED_HIT_GAP then
				return 0 -- time for a squadmate to come back for the revive
			end
			h.downedHitAt = now
		end
		h.pvpLock[by.id] = { untilT = now + World.PVP_LOCKOUT, amount = math.huge }
		h.downedHits += 1
		h.lastHitBy = by.id
		h.lastHitAt = now
		local need = World.DOWNED_HITS
		local bonus = h.stats.downedHitsBonus
		if finite(bonus) and bonus > 0 then
			need += math.floor(bonus)
		end
		self:emit({
			t = "hurt",
			id = h.id,
			amount = 0,
			x = h.x,
			z = h.z,
			by = by.id,
			hits = h.downedHits,
			need = need,
		})
		self:event({ type = "damaged", id = h.id, amount = 0, kind = "downedHit", by = by.id })
		if h.downedHits >= need then
			self:_kill(h, by.id)
		end
		return amt
	end
	return self:damagePlayer(h, amt, source or "pvp", by)
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
	-- Pressure (Team G1): elites can be bigger ("Big Cheese") and faster ("Stampede").
	local sizeMult = if el
			and finite(mods.eliteSizeMult)
			and mods.eliteSizeMult > 0
		then mods.eliteSizeMult
		else 1
	local speedMult = if el
			and finite(mods.eliteSpeedMult)
			and mods.eliteSpeedMult > 0
		then mods.eliteSpeedMult
		else 1
	x, z = self:clampToArena(x, z, def.radius * sizeMult)
	x, z = self:pushOutOfObstacles(x, z, def.radius * sizeMult)
	local hp = def.hp
		* (mods.enemyHpMult or 1)
		* (if el then E.hpMult else 1)
		* (1 + World.MOUSE_HP_PER_LEVEL * (self.levelAvg - 1))
		* (1 + World.WAVE_HP_STEP * ((self.stageWave or 1) - 1))
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
		r = def.radius * (if el then E.radiusMult else 1) * sizeMult,
		sizeMult = sizeMult, -- attack radii (fuse blast, projectile) scale too
		hp = hp,
		maxHp = hp,
		speed = def.speed * (if el then E.speedMult else 1) * speedMult,
		contact = def.contactDamage * (if el then E.damageMult else 1),
		xp = def.xp * (if el then E.xpMult else 1),
		slowUntil = 0,
		slowFactor = 1,
		nextShot = self.now + self.spawnRng:range(0.6, def.rangedCooldown or 2),
		fuseAt = nil :: number?,
	}
	return self:_addEnemy(e)
end

-- v4 opts: {final = boolean? (default: stage >= FINAL_STAGE), heroes = number?
-- (default: standing heroes), level = number? (default: avgHeroLevel when any hero
-- has a level), scale = false? (skip the v4 HP scaling: tests)}.
function World.spawnBoss(self: World, bossId: string, x: number, z: number, opts: any?): any
	local o = if type(opts) == "table" then opts else {}
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
	local final = if o.final ~= nil then o.final == true else self.stage >= World.FINAL_STAGE
	if o.scale ~= false then
		local heroes = if finite(o.heroes) then o.heroes else math.max(1, #self:_standingNow())
		local level = if finite(o.level) then o.level else self:levelForScaling()
		hp *= Bosses.hpScale(heroes, level, final, self.stage)
	end
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
		final = final, -- v4: a third phase at Bosses.PHASE3_FRAC
		lockedUntil = 0,
		telegraphUntil = now + World.BOSS_INTRO,
	}
	self:_addEnemy(e)
	self.boss = e
	self.bossDamage = {}
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
	local resist = if e.isBoss
		then 0.1
		elseif e.isChampion then Champions.KNOCK_RESIST
		elseif e.isMinion then 0.3
		elseif e.behavior == "tank" then 0.4
		else 1
	local v = studs * 8 * resist -- integral of v*e^(-8t) = v/8 -> total push = studs
	e.kvx += dx * v
	e.kvz += dz * v
	-- v4: a boss / champion never builds up a shove. Fast high-level knockback hits
	-- stacked to ~45 studs/s and juggled the final boss out of the storm circle,
	-- where heroes would not follow (the 180 s final-boss timeouts).
	if e.isBoss or e.isChampion then
		local cap = World.BIG_KNOCK_CAP
		local m2 = e.kvx * e.kvx + e.kvz * e.kvz
		if m2 > cap * cap then
			local k = cap / math.sqrt(m2)
			e.kvx *= k
			e.kvz *= k
		end
	end
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
	if e.shieldUntil and self.now < e.shieldUntil then
		amount *= Champions.SHIELD_MULT -- Captain Whiskers behind his shield
	end
	local dealt = math.min(amount, e.hp)
	e.hp -= amount
	if by and e.isBoss and by.squad then
		self.bossDamage[by.squad] = (self.bossDamage[by.squad] or 0) + dealt
	end
	if e.isChampion then
		Champions.onDamaged(self, e, dealt, by)
	end
	-- One damage number per enemy per step: later hits are merged into it.
	-- v4: `by` = the hero who dealt the most of this (merged) number (client: own numbers full size)
	local byId = if by and by.isHero then by.id else nil
	local merged = self.hitByEnemy[e.id]
	if merged then
		merged.amount += math.floor(amount + 0.5)
		merged.crit = merged.crit or crit == true
		merged.x, merged.z = e.x, e.z
		if byId ~= nil then
			local share = self.hitShare[e.id]
			if not share then
				share = {}
				self.hitShare[e.id] = share
			end
			share[byId] = (share[byId] or 0) + amount
			if merged.by == nil or share[byId] > (share[merged.by] or 0) then
				merged.by = byId
			end
		end
	elseif self.hitFx < World.HIT_FX_CAP or crit then
		self.hitFx += 1
		local fx = {
			t = "hit",
			x = e.x,
			z = e.z,
			amount = math.floor(amount + 0.5),
			crit = crit == true,
			id = e.id,
			by = byId,
		}
		self.hitByEnemy[e.id] = fx
		if byId ~= nil then
			self.hitShare[e.id] = { [byId] = amount }
		end
		self:emit(fx)
	end
	if e.isBoss and e.phase == 1 and e.hp > 0 and e.hp <= e.maxHp * 0.5 then
		self:_bossPhase2(e)
	end
	if e.isBoss and e.final and e.phase == 2 and e.hp > 0 and e.hp <= e.maxHp * Bosses.PHASE3_FRAC then
		self:_bossPhase3(e)
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

-- v4: the boss ring is the storm circle. Charges and leaps used to carry a boss far
-- outside it, where zone-aware heroes (bots) would not follow, so the fight stalled
-- (final boss timeouts). Between moves it walks back inside at BOSS_ZONE_PULL;
-- a leap or dash in flight is never bent, so strikes land where telegraphed.
function World._keepBossInZone(self: World, dt: number, now: number)
	local b, z = self.boss, self.zoneState
	if not b or not b.alive or not z or b.leap or b.dash then
		return
	end
	local lim = math.max(4, zoneRadius(z, now) - b.r - World.BOSS_ZONE_MARGIN)
	local dx, dz = b.x - z.cx, b.z - z.cz
	local d = math.sqrt(dx * dx + dz * dz)
	if d <= lim or d < 1e-6 then
		return
	end
	local step = math.min(d - lim, World.BOSS_ZONE_PULL * dt)
	b.x -= dx / d * step
	b.z -= dz / d * step
end

-- v4: the final boss's third phase (phase-2 patterns, faster and more often).
function World._bossPhase3(self: World, e: any)
	e.phase = 3
	e.patternList = e.def.phase2Patterns or e.def.patterns
	e.openerDone = false
	e.gap *= Bosses.PHASE3_GAP_MULT
	e.gapMult = (e.gapMult or 1) * Bosses.PHASE3_GAP_MULT
	e.speed *= Bosses.PHASE3_SPEED_MULT
	e.busyUntil = math.max(e.busyUntil, self.now + 1.2)
	e.telegraphUntil = math.max(e.telegraphUntil or 0, self.now + 1.2)
	self:emit({ t = "bossPhase", id = e.id, phase = 3, x = e.x, z = e.z })
	self:event({ type = "bossPhase", amount = 3, kind = e.defId })
end

-- Standing heroes right now (also before the first step).
function World._standingNow(self: World): { any }
	local out = {}
	for _, p in self.playerList do
		if isStanding(p) then
			table.insert(out, p)
		end
	end
	return out
end

-- The average hero level when any hero has one (setHeroLevel / stats.level), else nil.
function World.levelForScaling(self: World): number?
	return if self:_hasLevels() then self:avgHeroLevel() else nil
end

function World._hasLevels(self: World): boolean
	for _, p in self.playerList do
		if finite(p.level) or finite(p.stats.level) then
			return true
		end
	end
	return false
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
	-- v4: `by` = the killing hero's id (nil for recycles, traps, the storm): client kill streaks
	local byId = if by and by.isHero then by.id else nil
	self:emit({ t = "die", id = e.id, x = e.x, z = e.z, kind = e.kind, by = byId })
	if by then
		self:event({ type = "kill", id = by.id, kind = e.defId })
	end
	if not e.isBoss and not e.isChampion then
		self:_rindsForKill(e, by) -- v5
	end
	if e.poiId then
		Pois.onPackKill(self, e, by)
	end
	if e.carrier and not noDrop then
		-- golden carrier: drops a run-only gear item (GDD-v2 §3)
		local item = self:_rollGear(nil)
		self:dropGear(item, e.x, e.z)
	end
	if e.isBoss then
		local dmg, top = self:bossDamageBySquad()
		local killerSquad = if by and by.squad then by.squad else top
		self:_rindsForBig("boss", dmg, top) -- v5
		self:event({
			type = "bossDead",
			kind = e.defId,
			killer = if by then by.id else nil,
			killerSquad = killerSquad,
			damageBySquad = dmg,
		})
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
	elseif e.isChampion then
		Champions.onDeath(self, e, by) -- v3: the squad reward (no crumbs)
		if not e.champOf and not e.miniboss then
			local cd, ctop = Champions.damageBySquad(e)
			self:_rindsForBig("champion", cd, ctop) -- v5
		end
	elseif not noDrop then
		-- Pressure "No Snacks" (enemyXpMult): mice drop smaller XP crumbs
		local xpMult = self.mods.enemyXpMult
		if type(xpMult) ~= "number" or xpMult ~= xpMult or xpMult < 0 then
			xpMult = 1
		end
		self:spawnPickup(e.x, e.z, e.xp * xpMult)
	end
	if by and not fromExplosion and not noDrop then
		local r = by.stats and by.stats.explodeOnKill or 0
		if r > 0 then
			table.insert(self.booms, { by = by, x = e.x, z = e.z, r = r, dmg = 5 + 0.5 * by.derived.damage })
		end
	end
end

-- v3 big maps: plain mice (no boss, champion, camp pack or carrier) farther than
-- STRAY_RADIUS from every standing hero vanish (no drop), so the enemy cap keeps
-- feeding the squads instead of stragglers. Arenas smaller than that never do it.
function World._recycleStrays(self: World)
	local standing = self.standing
	if #standing == 0 or self.arenaRadius <= World.STRAY_RADIUS then
		return
	end
	local lim = World.STRAY_RADIUS * World.STRAY_RADIUS
	-- v4: plain mice well outside the storm circle are recycled too
	local zn = self.zoneState
	local zr = if zn then zoneRadius(zn, self.now) + World.STRAY_ZONE_MARGIN else math.huge
	local zr2 = zr * zr
	for _, e in self.enemies do
		if e.alive and not (e.isBoss or e.isMinion or e.isChampion or e.poiId or e.carrier) then
			if zn and (e.x - zn.cx) ^ 2 + (e.z - zn.cz) ^ 2 > zr2 then
				self:_killEnemy(e, nil, true, true)
				continue
			end
			local far = true
			for _, p in standing do
				if (p.x - e.x) ^ 2 + (p.z - e.z) ^ 2 <= lim then
					far = false
					break
				end
			end
			if far then
				self:_killEnemy(e, nil, true, true)
			end
		end
	end
end

function World.clearEnemies(self: World)
	Champions.clear(self) -- champions leave (Fx champ "dead", escaped)
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
	Champions.start(self)
end

-- Bot PvP pacing (BotBrain view.stage / view.waveTime): this World's stage and the
-- seconds since its waves started (held once they stop; 0 before they start).
function World.stageClock(self: World): (number, number)
	return self.stage, self.wave.elapsed
end

function World.stopSpawning(self: World)
	self.wave:stop()
	Champions.stop(self)
end

-- v3 Mouse Champions alive now: {{id, champId, x, z, hpFrac, lair, enraged, site,
-- damageBySquad, topSquad}} (main bodies; the Match payload, bots, tests).
function World.champions(self: World): { { [string]: any } }
	return Champions.list(self)
end

-- Captain Whiskers' rally (BossPatterns "rally"): mice within r of (x, z).
function World.rallyMice(self: World, caster: any, x: number, z: number, r: number, dur: number): number
	return Champions.rally(self, caster, x, z, r, dur)
end

-- Spawns champion `champId` at (x, z) now (tests, debug). `lair` = the lair version.
function World.spawnChampion(self: World, champId: string, x: number, z: number, lair: boolean?): any?
	return Champions.spawn(self, champId, { x = x, z = z }, lair)
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
		if p.protectPending then
			self:_setProtect(p, now + p.protectPending)
		end
		if p.downed then
			if now >= (p.downedUntil or 0) then
				self:_kill(p, p.downedBy)
			else
				-- only squad-mates revive (GDD-v2 §2); the best Revive Bell counts
				local helped = false
				local speed = 1
				local own = p.stats.reviveSpeedMult
				if finite(own) and own > speed then
					speed = own
				end
				local r2 = World.REVIVE_RANGE * World.REVIVE_RANGE
				for _, q in standing do
					if q ~= p and q.squad == p.squad and (q.x - p.x) ^ 2 + (q.z - p.z) ^ 2 <= r2 then
						helped = true
						local m = q.stats.reviveSpeedMult
						if finite(m) and m > speed then
							speed = m
						end
					end
				end
				if helped then
					p.reviveProgress += dt * speed
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
			if regen > 0 and now >= (p.pvpRegenUntil or 0) then
				self:_heal(p, regen * dt)
			end
			if p.shield and now >= p.shield.untilT then
				Weapons.shieldBurst(self, p)
			end
			self:_updateSprint(p, now)
		end
		-- gear burn from an enemy hero (Weapons.hitHero)
		if p.burnUntil then
			if now >= p.burnUntil or p.dead then
				p.burnUntil = nil
			elseif now >= (p.burnTick or 0) then
				p.burnTick = now + Weapons.BURN_TICK
				local by = p.burnBy
				if by and by.alive then
					self:damageHeroFrom(p, (p.burnDps or 0) * Weapons.BURN_TICK, by, "burn")
				end
			end
		end
	end
end

-- v3 out-of-combat sprint (World.SPRINT): calm for `calm` s (no damage taken)
-- and no enemy body within `clear` studs. Uses last step's spatial hash.
function World._updateSprint(self: World, p: any, now: number)
	local sp = World.SPRINT
	local was = p.sprinting == true
	local on = false
	if sp and finite(sp.mult) and sp.mult > 1 and now - (p.lastHurtAt or -math.huge) >= sp.calm then
		on = true
		local clear = sp.clear
		local px, pz = p.x, p.z
		self.hash:forEachInRadius(px, pz, clear + self.maxEnemyR, function(e)
			if e.alive then
				local rr = clear + e.r
				if (e.x - px) ^ 2 + (e.z - pz) ^ 2 <= rr * rr then
					on = false
					return true
				end
			end
			return nil
		end)
	end
	if on ~= was then
		p.sprinting = on
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
	if e.isChampion and not e.target then
		return -- a champion only attacks heroes near it (Combat/Champions)
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
			local rng = e.rng or self.bossRng -- champions: their own stream
			id = rng:pick(list)
			local tries = 0
			while id == e.lastPattern and tries < 4 do
				id = rng:pick(list)
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
		if n.isBoss or n.isChampion then
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
	if e.rallyUntil and now < e.rallyUntil then
		slow *= Champions.RALLY_SPEED -- Captain Whiskers' rally
	end
	local spd = e.speed * (mods.enemySpeedMult or 1) * slow
	local x, z = e.x, e.z
	local mx, mz = 0, 0 -- desired direction (unit or 0)
	local target = if e.isChampion then nil else self:nearestStanding(x, z)
	local stunned = (e.kvx * e.kvx + e.kvz * e.kvz) > 4

	if e.isBoss or e.isMinion or e.isChampion then
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
		elseif e.isChampion then
			mx, mz = Champions.steer(self, e) -- leash to its site, keep distance (sniper)
		elseif target then
			local dx, dz = target.x - x, target.z - z
			local d = math.sqrt(dx * dx + dz * dz)
			if d > e.r + World.PLAYER_RADIUS + 0.5 then
				mx, mz = dx / d, dz / d
			end
		end
	elseif e.carrier then
		-- golden carrier: run from the nearest hero, else wander; stay off the rim
		local dx, dz = 0, 0
		if target then
			dx, dz = x - target.x, z - target.z
		end
		local d = math.sqrt(dx * dx + dz * dz)
		if target and d < World.CARRIER_FLEE and d > 1e-4 then
			mx, mz = dx / d, dz / d
		else
			e.wanderA = (e.wanderA or 0) + dt * 0.6
			mx, mz = math.cos(e.wanderA) * 0.5, math.sin(e.wanderA) * 0.5
		end
		local c = math.sqrt(x * x + z * z)
		local edge = self.arenaRadius * 0.8
		if c > edge and c > 1e-4 then
			local w = (c - edge) / (self.arenaRadius * 0.2) * 1.5
			mx, mz = mx - x / c * w, mz - z / c * w
			local m = math.sqrt(mx * mx + mz * mz)
			if m > 1e-4 then
				mx, mz = mx / m, mz / m
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
				-- Pressure "Slingshot Season": 1 + rangedExtraProjectiles shots in a fan.
				local extra = mods.rangedExtraProjectiles
				local n = 1 + (if finite(extra) and extra > 0 then math.floor(extra + 0.5) else 0)
				local pr = 0.8 * (e.sizeMult or 1)
				for i = 1, n do
					local a = (i - (n + 1) / 2) * World.RANGED_FAN
					local ca, sa = math.cos(a), math.sin(a)
					local vx, vz = ux * ca - uz * sa, ux * sa + uz * ca
					self:spawnEnemyProjectile(
						x + ux * e.r,
						z + uz * e.r,
						vx * ps,
						vz * ps,
						pr,
						dmg,
						range * 1.3 / ps,
						"crumb"
					)
				end
			end
		elseif e.behavior == "fuse" and edge <= Enemies.FUSE_TRIGGER then
			e.fuseAt = now + Enemies.FUSE_TIME
			e.telegraphUntil = e.fuseAt
			self:telegraph(e, {
				t = "tele",
				shape = "circle",
				x = x,
				z = z,
				r = (e.def.fuseRadius or 8) * (e.sizeMult or 1),
				delay = Enemies.FUSE_TIME,
				style = "fuse",
			})
			mx, mz = 0, 0
		else
			mx, mz = dx / d, dz / d
		end
	end

	-- obstacle avoidance: steer tangentially around circles in the way
	-- (reach e.r + 3, plus this step's move, stays inside OBS_PAD for every body)
	local nearObs =
		self:_obstaclesNear(x, z, e.r + 4 + (math.max(spd, 6) + math.abs(e.kvx) + math.abs(e.kvz)) * dt * 2)
	if mx ~= 0 or mz ~= 0 then
		for _, o in nearObs do
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
	if not e.isBoss and not e.isChampion then
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
	for _, o in nearObs do
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
	local r = (def.fuseRadius or 8) * (e.sizeMult or 1) -- Pressure "Big Cheese" grows elite blasts
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
			if e.burnUntil then
				if now >= e.burnUntil then
					e.burnUntil = nil
				elseif now >= (e.burnTick or 0) then
					e.burnTick = now + Weapons.BURN_TICK
					local by = e.burnBy
					self:damageEnemy(
						e,
						(e.burnDps or 0) * Weapons.BURN_TICK,
						if by and by.alive then by else nil,
						false,
						true
					)
					if not e.alive then
						continue
					end
				end
			end
			if e.expiresAt and now >= e.expiresAt then
				-- a golden carrier that got away: no drop
				self:emit({ t = "carrierEscape", id = e.id, x = e.x, z = e.z })
				self:_killEnemy(e, nil, true, true)
				continue
			end
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
			local mult = if hitBy.isBoss
					or hitBy.isMinion
					or hitBy.isChampion
				then 1
				else (self.mods.enemyDamageMult or 1)
			if hitBy.rallyUntil and now < hitBy.rallyUntil then
				mult *= Champions.RALLY_DAMAGE
			end
			local took = self:damagePlayer(p, hitBy.contact * mult, "contact")
			local thorns = p.stats.thorns
			if took > 0 and finite(thorns) and thorns > 0 and hitBy.alive then
				self:damageEnemy(hitBy, took * thorns, p, false, true)
			end
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
			-- v2 PvP: does any enemy hero lie near this step's path? (cheap pre-check)
			local foes = false
			if self.pvp then
				local reach = speed * dt + pr.r + World.PLAYER_RADIUS + 1
				local sq = owner.squad
				for _, h in self.heroTargets do
					if h.squad ~= sq and (h.x - pr.x) ^ 2 + (h.z - pr.z) ^ 2 <= reach * reach then
						foes = true
						break
					end
				end
			end
			for _ = 1, subs do
				pr.x += pr.vx * sdt
				pr.z += pr.vz * sdt
				if foes then
					self:forFoesInCircle(owner, pr.x, pr.z, pr.r, function(h)
						if live and not pr.hit[h] then
							pr.hit[h] = true
							Weapons.hit(self, owner, h, pr.dmg, { chain = true, projectile = true })
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
				if took > 0 and pr.slow and not ((p.stats.unshakable or 0) > 0) then
					p.slowUntil = now + 1.5 -- iteration 2: the Unshakable gem unique ignores it
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
				self:forFoesInCircle(owner, zn.x, zn.z, zn.r, function(h)
					h.slowUntil = math.max(h.slowUntil, now + 0.25)
				end)
			end
			if zn.dmg > 0 and now >= zn.nextTick then
				zn.nextTick += zn.tick
				local function tick(e: any)
					Weapons.hit(self, owner, e, zn.dmg, nil)
				end
				self:forEnemiesInCircle(zn.x, zn.z, zn.r, tick)
				self:forFoesInCircle(owner, zn.x, zn.z, zn.r, tick)
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
					-- v5 shared XP: standing squadmates within XP_SHARE_RADIUS get XP_SHARE
					local r2 = RunShop.XP_SHARE_RADIUS * RunShop.XP_SHARE_RADIUS
					for _, q in self.standing do
						if q ~= p and q.squad == p.squad and (q.x - p.x) ^ 2 + (q.z - p.z) ^ 2 <= r2 then
							self:event({
								type = "xp",
								id = q.id,
								amount = c.xp * RunShop.XP_SHARE * (q.stats.xpMult or 1),
								kind = "share",
							})
						end
					end
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
	table.clear(self.hitShare)

	self:_rebuildTargets()
	self:_refreshRookies()
	self:_updatePlayers(dt, now)
	self:_updateStormPlan(now)
	self:_updateStorm(dt, now)

	local boss = self.boss
	if boss and boss.alive and not boss.enraged then
		boss.spawnedAt = boss.spawnedAt or now
		if now - boss.spawnedAt >= World.BOSS_ENRAGE_AFTER then
			self:_enrage(boss)
		end
	end

	-- spawning (v4: per hero, inside the storm circle)
	if self.wave.active then
		self:_updateDensity(now)
		local reqs = self.wave:update(dt, self.liveCount, self.standing, self:_spawnHeroes())
		local surged = false
		for _, r in reqs do
			if self:spawnEnemy(r.id, r.x, r.z, r.elite) then
				self.waveSpawned = (self.waveSpawned or 0) + 1 -- iteration 3 T-3 (horn carry)
			end
			if r.surge then
				surged = true
			end
		end
		if surged then
			self:emit({ t = "surge" })
		end
	end
	Champions.update(self, dt, now) -- v3 Mouse Champions: director + leash / aggro AI
	if now >= self.nextStrayAt then
		self.nextStrayAt = now + World.STRAY_CHECK
		self:_recycleStrays()
	end

	self:_rebuildHash()
	self:_updateEnemies(dt, now)
	self:_runActions(now)
	self:_keepBossInZone(dt, now)
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
	self:_carriers(now)
	-- standing list may have changed (downs during this step)
	for i = #self.standing, 1, -1 do
		if not isStanding(self.standing[i]) then
			table.remove(self.standing, i)
		end
	end
	Pois.update(self, dt, now)
	self:_updateLoot(dt, now)
	self:_updatePickups(dt)
	self:_checkSquads(now)
	self:_compact()

	local out = self.fx
	self.fx = {}
	table.clear(self.hitByEnemy) -- the batch is gone; later hits start fresh numbers
	table.clear(self.hitShare)
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

-- v2 gear and loot (GDD-v2 §3) ----------------------------------------------------------------

local function itemCopy(it: any): any
	return { id = it.id, slot = it.slot, rarity = it.rarity }
end

-- {weapon?, armor?, trinket?} copies of a hero's equipped gear (empty table if none).
function World.gearOf(self: World, id: number): { [string]: any }
	local p = self.players[id]
	local out = {}
	if p then
		for slot, it in p.gear do
			out[slot] = itemCopy(it)
		end
	end
	return out
end

-- Restores gear without events or swap offers (RunDirector carries gear between
-- stage worlds: world:setGear(id, oldWorld:gearOf(id))). Invalid items are dropped.
function World.setGear(self: World, id: number, items: any)
	local p = self.players[id]
	if not p then
		return
	end
	p.gear = Gear.clean(items)
	self:_applyGear(p)
end

-- The open swap offer of a hero: {item, slot, current, endsAt} copies, or nil.
function World.swapOffer(self: World, id: number): any?
	local p = self.players[id]
	local sw = p and p.swap
	if not sw then
		return nil
	end
	local cur = p.gear[sw.slot]
	return {
		item = itemCopy(sw.item),
		slot = sw.slot,
		current = if cur then itemCopy(cur) else nil,
		endsAt = sw.endsAt,
	}
end

-- Gives an item: an empty slot equips it at once (-> true, false, event gearPickup);
-- a full slot opens a SWAP_TIME swap offer (-> false, true, event gearSwapOffer);
-- with an offer already open (or a dead hero) the item drops at the hero's feet
-- (-> false, false). Items are never lost. Invalid items -> false, false.
function World.giveGear(self: World, id: number, item: any): (boolean, boolean)
	local p = self.players[id]
	if not Gear.valid(item) then
		return false, false
	end
	local it = itemCopy(item)
	if not p then
		return false, false
	end
	if p.dead then
		self:dropGear(it, p.x, p.z)
		return false, false
	end
	local cur = p.gear[it.slot]
	if not cur then
		p.gear[it.slot] = it
		self:_applyGear(p)
		self:emit({ t = "gearEquip", id = p.id, item = itemCopy(it), slot = it.slot })
		self:event({ type = "gearPickup", id = p.id, item = itemCopy(it), slot = it.slot })
		return true, false
	end
	if p.swap then
		self:dropGear(it, p.x, p.z, p.id)
		return false, false
	end
	local endsAt = self.now + World.SWAP_TIME
	p.swap = { item = it, slot = it.slot, endsAt = endsAt }
	self:event({
		type = "gearSwapOffer",
		id = p.id,
		item = itemCopy(it),
		slot = it.slot,
		current = itemCopy(cur),
		endsAt = endsAt,
	})
	return false, true
end

-- Answers a swap offer (Net SwapGear(takeNew)): takeNew = true equips the offered
-- item and drops the old one on the ground; false keeps the current item and
-- leaves the offered one on the ground. Expired offers resolve as false.
-- Returns false when there was no offer.
function World.resolveSwap(self: World, id: number, takeNew: boolean): boolean
	local p = self.players[id]
	local sw = p and p.swap
	if not sw then
		return false
	end
	p.swap = nil
	if takeNew == true and not p.dead then
		local old = p.gear[sw.slot]
		p.gear[sw.slot] = sw.item
		self:_applyGear(p)
		if old then
			self:dropGear(old, p.x, p.z, p.id)
		end
		self:emit({ t = "gearEquip", id = p.id, item = itemCopy(sw.item), slot = sw.slot })
		self:event({
			type = "gearPickup",
			id = p.id,
			item = itemCopy(sw.item),
			slot = sw.slot,
			replaced = if old then itemCopy(old) else nil,
		})
	else
		self:dropGear(sw.item, p.x, p.z, p.id)
		self:event({ type = "gearSwapDeclined", id = p.id, item = itemCopy(sw.item), slot = sw.slot })
	end
	return true
end

-- Puts an item on the ground (Fx "gear"). `ignoreId`: that hero does not pick it
-- up again until they have stepped away. Returns the ground id (nil if invalid).
function World.dropGear(self: World, item: any, x: number, z: number, ignoreId: number?): number?
	if not Gear.valid(item) then
		return nil
	end
	x, z = self:clampToArena(if finite(x) then x else 0, if finite(z) then z else 0, 2)
	self.nextGroundId = self.nextGroundId % 65535 + 1
	local g = { id = self.nextGroundId, item = itemCopy(item), x = x, z = z, ignoreId = ignoreId }
	table.insert(self.ground, g)
	if #self.ground > World.GROUND_CAP then
		local old = table.remove(self.ground, 1)
		self:emit({ t = "gearGone", id = old.id })
	end
	self:emit({ t = "gear", id = g.id, x = x, z = z, item = itemCopy(item) })
	return g.id
end

-- Ground items as {id, x, z, item} copies (bots, HUD).
function World.groundItems(self: World): { any }
	local out = {}
	for _, g in self.ground do
		table.insert(out, { id = g.id, x = g.x, z = g.z, item = itemCopy(g.item) })
	end
	return out
end

-- A loot bag holding `gear` (items) and `cheese` (pending cheese for the squad that
-- picks it up: RunDirector pays it on the lootBag event). A call at the spot of a
-- bag dropped within BAG_MERGE_AGE s merges into it (so RunDirector can add the
-- cheese share to the gear bag World dropped on heroKilled). Returns the bag id.
function World.addLootBag(self: World, x: number, z: number, gear: any, cheese: number?): number
	x, z = self:clampToArena(if finite(x) then x else 0, if finite(z) then z else 0, 2)
	local items = {}
	if type(gear) == "table" then
		for _, it in Gear.clean(gear) do
			table.insert(items, it)
		end
		if #items == 0 then
			for _, it in ipairs(gear) do
				if Gear.valid(it) then
					table.insert(items, itemCopy(it))
				end
			end
		end
	end
	local c = if finite(cheese) and (cheese :: number) > 0 then math.floor(cheese :: number) else 0
	local mr = World.BAG_MERGE_RADIUS
	for _, b in self.bags do
		if self.now - b.createdAt <= World.BAG_MERGE_AGE and (b.x - x) ^ 2 + (b.z - z) ^ 2 <= mr * mr then
			for _, it in items do
				table.insert(b.gear, it)
			end
			b.cheese += c
			self:emit(self:_bagFx(b))
			return b.id
		end
	end
	self.nextBagId = self.nextBagId % 65535 + 1
	local b = {
		id = self.nextBagId,
		x = x,
		z = z,
		gear = items,
		cheese = c,
		createdAt = self.now,
		progress = 0,
		by = nil :: number?,
		step = 0,
	}
	table.insert(self.bags, b)
	self:emit(self:_bagFx(b))
	return b.id
end

-- Adds pending cheese to an existing bag (true if it exists).
function World.addBagCheese(self: World, bagId: number, cheese: number): boolean
	for _, b in self.bags do
		if b.id == bagId and finite(cheese) and cheese > 0 then
			b.cheese += math.floor(cheese)
			self:emit(self:_bagFx(b))
			return true
		end
	end
	return false
end

-- `r` is the best rarity inside (nil for a cheese-only bag): the client colours
-- the bag's in-world marker with it.
function World._bagFx(_self: World, b: any): { [string]: any }
	local best, rank = nil, 0
	for _, it in b.gear do
		local k = Gear.rank(it)
		if k > rank then
			best, rank = it.rarity, k
		end
	end
	return { t = "bag", id = b.id, x = b.x, z = b.z, n = #b.gear, cheese = b.cheese, r = best }
end

-- Loot bags as {id, x, z, n, cheese, progress, by} copies.
function World.lootBags(self: World): { any }
	local out = {}
	for _, b in self.bags do
		table.insert(
			out,
			{ id = b.id, x = b.x, z = b.z, n = #b.gear, cheese = b.cheese, progress = b.progress, by = b.by }
		)
	end
	return out
end

-- A dying / leaving hero's gear (and an open swap item) goes into a bag. Returns its id.
function World._dropBagOf(self: World, p: any): number?
	local items = {}
	for _, slot in { "weapon", "armor", "trinket" } do
		if p.gear[slot] then
			table.insert(items, p.gear[slot])
		end
	end
	if p.swap then
		table.insert(items, p.swap.item)
		p.swap = nil
	end
	p.gear = {}
	if #items == 0 then
		return nil
	end
	return self:addLootBag(p.x, p.z, items, 0)
end

-- Bonus share a hero banks on Extract from gear (e.g. 0.15 = 115%).
function World.extractBonusOf(self: World, id: number): number
	local p = self.players[id]
	local v = p and p.stats.extractBonus
	return if finite(v) and v > 0 then v else 0
end

-- Ground pickups, swap expiry, loot-bag channels. Runs every step (waves or not).
function World._updateLoot(self: World, dt: number, now: number)
	for _, p in self.playerList do
		if p.swap and (now >= p.swap.endsAt or p.dead) then
			self:resolveSwap(p.id, false)
		end
	end
	local standing = self.standing
	if #self.ground > 0 and #standing > 0 then
		local r = World.GEAR_PICKUP + World.PLAYER_RADIUS
		local r2 = r * r
		local i = 1
		while i <= #self.ground do
			local g = self.ground[i]
			local taker = nil
			for _, p in standing do
				if (p.x - g.x) ^ 2 + (p.z - g.z) ^ 2 <= r2 then
					if p.id == g.ignoreId then
						continue
					end
					if not p.swap then
						taker = p
						break
					end
				end
			end
			if g.ignoreId then
				local ip = self.players[g.ignoreId]
				if not ip or not isStanding(ip) or (ip.x - g.x) ^ 2 + (ip.z - g.z) ^ 2 > (r + 1) ^ 2 then
					g.ignoreId = nil
				end
			end
			if taker then
				table.remove(self.ground, i)
				self:emit({ t = "gearGone", id = g.id, by = taker.id })
				self:giveGear(taker.id, g.item)
			else
				i += 1
			end
		end
	end
	if #self.bags > 0 then
		local r = World.BAG_RANGE + World.PLAYER_RADIUS
		local r2 = r * r
		local pause = PoiConfig.HURT_PAUSE
		local i = 1
		while i <= #self.bags do
			local b = self.bags[i]
			local picker, squads, sq = nil, 0, nil
			for _, p in standing do
				if (p.x - b.x) ^ 2 + (p.z - b.z) ^ 2 <= r2 then
					if p.squad ~= sq then
						squads += if sq == nil then 1 else 2
						sq = sq or p.squad
					end
					if not picker and now - (p.lastHurtAt or -math.huge) >= pause then
						picker = p
					end
				end
			end
			local done = false
			if squads >= 2 or not picker then
				if not picker and squads == 0 then
					b.progress, b.by, b.step = 0, nil, 0
				elseif picker == nil and b.by then
					b.progress, b.step = 0, 0 -- damage interrupts the channel
				end
			else
				if b.by ~= picker.id then
					b.by, b.progress, b.step = picker.id, 0, 0
				end
				local m = picker.stats.channelSpeedMult
				m = if finite(m) and m > 1 then m else 1
				b.progress = math.min(1, b.progress + dt / World.BAG_CHANNEL * m)
				local step = math.floor(b.progress * 4 + 1e-6)
				if step ~= b.step then
					b.step = step
					self:emit({ t = "bagProgress", id = b.id, p = step / 4, by = picker.id })
				end
				done = b.progress >= 1
			end
			if done then
				table.remove(self.bags, i)
				self:emit({ t = "bagGone", id = b.id, by = picker.id })
				local gear = {}
				for _, it in b.gear do
					table.insert(gear, itemCopy(it))
				end
				self:event({
					type = "lootBag",
					bag = b.id,
					by = picker.id,
					squad = picker.squad,
					gear = gear,
					cheese = b.cheese,
					x = b.x,
					z = b.z,
				})
				for _, it in b.gear do
					self:giveGear(picker.id, it)
				end
			else
				i += 1
			end
		end
	end
end

-- Gear roll on the world's gear stream (POIs, carriers, camps).
function World._rollGear(self: World, minRarity: string?): any
	return Gear.roll(self.gearRng, self.tier, self.stage, { minRarity = minRarity })
end

-- Shop Cart stock (Combat/Pois, first open): offers, prices.
function World._cartStock(self: World): ({ any }, { number })
	return Gear.cartOffers(self.gearRng, self.tier, self.stage)
end

-- Power Totem owners -> self.squadDmg (Weapons.hit / damageHeroFrom read it).
function World._refreshTotems(self: World)
	table.clear(self.squadDmg)
	for _, e in self.poiList do
		if e.mode == "totem" and e.owner ~= nil then
			self.squadDmg[e.owner] = PoiConfig.TOTEM_DAMAGE_MULT
		end
	end
end

-- Damage multiplier a squad currently has from Power Totems (1 = none).
function World.squadDamageMult(self: World, squad: number): number
	return self.squadDmg[squad] or 1
end

-- Shop Cart: {offers, prices, sold} copies (nil for an unknown / unopened cart).
function World.cartOffers(self: World, poiId: number): any?
	local e = self.poiById[poiId]
	if not e or e.mode ~= "cart" then
		return nil
	end
	if not e.offers then
		e.offers, e.prices = self:_cartStock()
		e.sold = {}
		for i = 1, #e.offers do
			e.sold[i] = false
		end
	end
	local offers = {}
	for i, it in e.offers do
		offers[i] = itemCopy(it)
	end
	return { offers = offers, prices = table.clone(e.prices), sold = table.clone(e.sold) }
end

-- Sells a Shop Cart offer (RunDirector charges the pending cheese first, then
-- calls giveGear). Returns the item and its price, or nil when sold / unknown.
function World.takeCartOffer(self: World, poiId: number, index: number): (any?, number?)
	local e = self.poiById[poiId]
	if not e then
		return nil, nil
	end
	local price = if e.prices then e.prices[index] else nil
	local it = Pois.takeCartOffer(self, e, index)
	return it, if it then price else nil
end

-- Golden carriers ------------------------------------------------------------------------------

function World._spawnCarrier(self: World, now: number)
	local def = Enemies.get("carrier")
	if not def then
		return
	end
	local rng = self.gearRng
	local x, z = 0, 0
	local ok = false
	for _ = 1, 10 do
		local a = rng:range(0, TAU)
		local d = math.sqrt(rng:nextFloat()) * (self.arenaRadius - 6)
		x, z = math.cos(a) * d, math.sin(a) * d
		ok = true
		for _, p in self.standing do
			if (p.x - x) ^ 2 + (p.z - z) ^ 2 < World.CARRIER_MIN_DIST ^ 2 then
				ok = false
				break
			end
		end
		if ok then
			break
		end
	end
	x, z = self:pushOutOfObstacles(x, z, def.radius)
	x, z = self:clampToArena(x, z, def.radius)
	local hp = def.hp * (self.mods.enemyHpMult or 1)
	local e = self:_addEnemy({
		defId = def.id,
		def = def,
		kind = Enemies.INDEX[def.id],
		behavior = def.behavior,
		elite = false,
		x = x,
		z = z,
		kvx = 0,
		kvz = 0,
		r = def.radius,
		sizeMult = 1,
		hp = hp,
		maxHp = hp,
		speed = def.speed,
		contact = 0,
		xp = def.xp,
		slowUntil = 0,
		slowFactor = 1,
		nextShot = math.huge,
		fuseAt = nil,
		carrier = true,
		expiresAt = now + (def.lifetime or 30),
		wanderA = rng:range(0, TAU),
	})
	self:emit({ t = "carrier", id = e.id, x = x, z = z, untilT = e.expiresAt })
end

function World._carriers(self: World, now: number)
	if not self.carriersOn or not self.wave.active then
		return
	end
	if self.nextCarrierAt == nil then
		self.nextCarrierAt = now + World.CARRIER_FIRST
		return
	end
	if now < self.nextCarrierAt then
		return
	end
	local iv = World.CARRIER_INTERVAL
	self.nextCarrierAt = now + self.gearRng:range(iv[1], iv[2])
	local alive = 0
	for _, e in self.enemies do
		if e.alive and e.carrier then
			alive += 1
		end
	end
	if alive >= World.CARRIER_MAX then
		return
	end
	if self.liveCount >= self.cap then
		-- keep the cap: retire the plain mouse furthest from every hero (no drop)
		local worst, worstD = nil, -1
		for _, e in self.enemies do
			if
				e.alive
				and not e.isBoss
				and not e.isMinion
				and not e.elite
				and not e.poiId
				and not e.carrier
			then
				local d = math.huge
				for _, p in self.standing do
					d = math.min(d, (p.x - e.x) ^ 2 + (p.z - e.z) ^ 2)
				end
				if d > worstD then
					worst, worstD = e, d
				end
			end
		end
		if not worst then
			return
		end
		self:_killEnemy(worst, nil, true, true)
	end
	self:_spawnCarrier(now)
end

-- Squad elimination (two or more squads only): a squad with nobody standing is
-- out after ELIM_GRACE (while a downed member could still Second Wind) or at once;
-- its downed members die (loot bags) and squadEliminated fires.
function World._checkSquads(self: World, now: number)
	if not self.pvp then
		return
	end
	for squad, st in self.squadState do
		if st.eliminated then
			continue
		end
		local members, standing, canWind = 0, 0, false
		for _, p in self.playerList do
			if p.squad == squad then
				members += 1
				if isStanding(p) then
					standing += 1
				elseif p.downed and not p.secondWindUsed then
					canWind = true
				end
			end
		end
		if members == 0 or standing > 0 then
			st.elimAt = nil
			continue
		end
		if st.elimAt == nil then
			st.elimAt = now + (if canWind then World.ELIM_GRACE else 0)
		end
		if now >= st.elimAt then
			st.eliminated = true
			st.elimAt = nil
			local by = nil
			for _, p in self.playerList do
				if p.squad == squad and p.downed then
					by = by or p.downedBy
					self:_kill(p, p.downedBy)
				end
			end
			self:emit({ t = "squadOut", squad = squad, by = by })
			self:event({ type = "squadEliminated", squad = squad, by = by })
		end
	end
end

-- PvP queries (Weapons) ----------------------------------------------------------------------------

-- fn(h, d2) for each enemy-squad hero of `attacker` (standing or downed, not dead,
-- not spawn-protected) whose body touches the circle. No-op with a single squad.
function World.forFoesInCircle(
	self: World,
	attacker: any,
	x: number,
	z: number,
	r: number,
	fn: (h: any, d2: number) -> ()
)
	if not self.pvp then
		return
	end
	local sq = attacker.squad
	local now = self.now
	local rr = r + World.PLAYER_RADIUS
	local rr2 = rr * rr
	for _, h in self.heroTargets do
		if h.squad ~= sq and not h.dead and h.protectUntil <= now and not self:_rookieSafe(attacker, h) then
			local dx, dz = h.x - x, h.z - z
			local d2 = dx * dx + dz * dz
			if d2 <= rr2 then
				fn(h, d2)
			end
		end
	end
end

function World.forFoesInLine(
	self: World,
	attacker: any,
	x: number,
	z: number,
	dx: number,
	dz: number,
	len: number,
	halfW: number,
	fn: (h: any) -> ()
)
	if not self.pvp then
		return
	end
	local sq = attacker.squad
	local now = self.now
	local pr = World.PLAYER_RADIUS
	for _, h in self.heroTargets do
		if h.squad ~= sq and not h.dead and h.protectUntil <= now and not self:_rookieSafe(attacker, h) then
			local px, pz = h.x - x, h.z - z
			local along = px * dx + pz * dz
			if along >= -pr and along <= len + pr and math.abs(px * -dz + pz * dx) <= halfW + pr then
				fn(h)
			end
		end
	end
end

-- Auto-weapon targets for `p`: the n nearest mice within range, with the nearest
-- enemy hero first when it is the closest target or within HERO_AGGRO studs.
function World.targetsFor(self: World, p: any, range: number, n: number): { any }
	local list = self:nearestEnemies(p.x, p.z, range, n)
	if not self.pvp then
		return list
	end
	local sq = p.squad
	local now = self.now
	local best, bestD = nil, math.huge
	for _, h in self.heroTargets do
		if h.squad ~= sq and not h.dead and h.protectUntil <= now and not self:_rookieSafe(p, h) then
			local d2 = (h.x - p.x) ^ 2 + (h.z - p.z) ^ 2
			if d2 < bestD then
				best, bestD = h, d2
			end
		end
	end
	if not best then
		return list
	end
	local rr = range + World.PLAYER_RADIUS
	if bestD > rr * rr then
		return list
	end
	local d = math.sqrt(bestD)
	local first = list[1]
	local mouseD = if first then math.sqrt((first.x - p.x) ^ 2 + (first.z - p.z) ^ 2) else math.huge
	if d <= World.HERO_AGGRO or d <= mouseD then
		table.insert(list, 1, best)
		if #list > n then
			list[#list] = nil
		end
	end
	return list
end

-- Boss damage per squad so far ({[squad] = number}, copy) and the top squad.
function World.bossDamageBySquad(self: World): ({ [number]: number }, number?)
	local out, top, topD = {}, nil, -1
	for sq, d in self.bossDamage do
		out[sq] = d
		if d > topD then
			top, topD = sq, d
		end
	end
	return out, top
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
			-- v2
			squad = p.squad,
			protected = p.protectUntil > self.now,
			lastHitBy = p.lastHitBy,
			lastHitAt = p.lastHitAt,
			downedHits = p.downedHits,
			-- v4
			rookie = p.rookie == true,
			rookieSquad = self.rookieSquads[p.squad] == true, -- iteration 1: the whole squad
			humanSquad = self.humanSquads[p.squad] == true, -- iteration 4: a squad with a human in it
			botSafe = self.now < (p.botSafeUntil or 0), -- iteration 3 T-4: freshly revived
			botFocus = if self.now - (p.botFocusAt or -math.huge) < World.BOT_FOCUS_WINDOW
				then p.botFocus
				else nil, -- the enemy bot hitting this human now
			outsideZone = p.outsideZone == true,
			secondWindUsed = p.secondWindUsed,
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
			if e.isMinion or e.champOf then
				flags += 8 -- boss minion, or a Mad Chemist clone
			end
			-- bits 4-5: size hint (elites x1.3, Big Cheese, lair champions x1.25,
			-- Chemist clones are drawn small via bit 3), so clients draw the real hitbox
			local base = if not e.isBoss and e.def then e.def.radius else nil
			if type(base) == "number" and base > 0 and e.r > base then
				flags += SnapshotCodec.sizeBits(e.r / base)
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
		-- v3 sprint: the speed the character really walks at (moveSpeed x SPRINT.mult
		-- while sprinting). CombatService / BotService / MoveGuard use this.
		walkSpeed = p.stats.moveSpeed * (if p.sprinting then World.SPRINT.mult else 1),
		sprinting = p.sprinting == true,
		-- v2
		squad = p.squad,
		protected = p.protectUntil > now,
		protectUntil = p.protectUntil,
		downedHits = p.downedHits,
		downedHitsMax = World.DOWNED_HITS
			+ (if finite(p.stats.downedHitsBonus) then math.floor(p.stats.downedHitsBonus) else 0),
		lastHitBy = p.lastHitBy,
		lastHitAt = p.lastHitAt,
		extractBonus = self:extractBonusOf(p.id),
		gear = self:gearOf(p.id),
		swapOffer = self:swapOffer(p.id),
		burning = (p.burnUntil or 0) > now,
		aimMode = p.aimMode or "nearest", -- iteration 4
		-- v4
		outsideZone = p.outsideZone == true,
		rookie = p.rookie == true,
		regenPausedUntil = p.pvpRegenUntil or 0,
		level = p.level or p.stats.level,
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
	damageBySquad: { [number]: number },
	topSquad: number?,
}?
	local b = self.boss
	if not b or not b.alive then
		return nil
	end
	local dmg, top = self:bossDamageBySquad()
	return {
		id = b.defId,
		hpFrac = math.clamp(b.hp / b.maxHp, 0, 1),
		phase = b.phase,
		name = b.def.name,
		title = b.def.title,
		entityId = b.id,
		enraged = b.enraged == true,
		damageBySquad = dmg, -- v2: a boss that times out goes to topSquad
		topSquad = top,
	}
end

-- v4 "The Melt": the closing storm circle (Config/Storm, docs/COMBAT-API.md "v4") -----------

-- Sets the storm zone: {cx, cz, r, toR, closeStart, closeEnd, dps} with close times
-- on the world clock (`now` passed to step) and dps a fraction of max HP per second.
-- The radius lerps r -> toR between closeStart and closeEnd. nil clears the storm.
-- Emits Fx {t = "storm", cx, cz, r, toR, closeStart, closeEnd, dps, now}.
function World.setZone(self: World, zone: any?)
	if zone == nil then
		if self.zoneState then
			self.zoneState = nil
			self:emit({ t = "storm", off = true, now = self.now })
		end
		return
	end
	if type(zone) ~= "table" then
		return
	end
	local r = if finite(zone.r) and zone.r > 0 then zone.r else self.arenaRadius
	local toR = if finite(zone.toR) and zone.toR >= 0 then zone.toR else r
	local cs = if finite(zone.closeStart) then zone.closeStart else self.now
	local ce = if finite(zone.closeEnd) then math.max(cs, zone.closeEnd) else cs
	local z = {
		cx = if finite(zone.cx) then zone.cx else 0,
		cz = if finite(zone.cz) then zone.cz else 0,
		r = r,
		toR = toR,
		closeStart = cs,
		closeEnd = ce,
		dps = if finite(zone.dps) and zone.dps > 0 then zone.dps else 0,
		step = zone.step,
	}
	self.zoneState = z
	self:_stormFx()
end

function World._stormFx(self: World)
	local z = self.zoneState
	if not z then
		return
	end
	self.stormFxAt = self.now + World.STORM_RESEND
	self:emit({
		t = "storm",
		cx = z.cx,
		cz = z.cz,
		r = z.r,
		toR = z.toR,
		closeStart = z.closeStart,
		closeEnd = z.closeEnd,
		dps = z.dps,
		now = self.now,
	})
end

-- The storm zone (a copy) plus `radius` = the radius right now, or nil.
function World.zone(self: World): { [string]: any }?
	local z = self.zoneState
	if not z then
		return nil
	end
	local out = table.clone(z)
	out.radius = zoneRadius(z, self.now)
	return out
end

-- Is (x, z) inside the storm circle right now (`margin` studs inside)? True without a storm.
function World.insideZone(self: World, x: number, z: number, margin: number?): boolean
	local zn = self.zoneState
	if not zn then
		return true
	end
	local r = zoneRadius(zn, self.now) - (margin or 0)
	return (x - zn.cx) ^ 2 + (z - zn.cz) ^ 2 <= r * r
end

-- Optional autopilot: the World follows Config/Storm by itself. plan = {radius?
-- (default arenaRadius), stage? (default the world's), seed?, duration? (default
-- the waves'), safeCorners? (default true: corners switch off at
-- Storm.SAFE_CORNERS_OFF)}. Waves use the wave clock; a live boss uses the time
-- since it spawned (the squeeze). nil turns it off (the zone stays as it is).
function World.setStormPlan(self: World, plan: any?)
	if type(plan) ~= "table" then
		self.stormPlan = nil
		return
	end
	self.stormPlan = {
		radius = if finite(plan.radius) and plan.radius > 0 then plan.radius else self.arenaRadius,
		stage = if finite(plan.stage) then plan.stage else self.stage,
		seed = if finite(plan.seed) then plan.seed else 0,
		duration = if finite(plan.duration) then plan.duration else nil,
		safeCorners = plan.safeCorners ~= false,
		lastStep = nil,
	}
end

function World._updateStormPlan(self: World, now: number)
	local plan = self.stormPlan
	if not plan then
		return
	end
	local boss = self.boss
	local zone, t0
	if boss and boss.alive then
		local born = boss.spawnedAt or now
		zone = Storm.bossZone(plan.radius, plan.stage, now - born, plan.seed)
		t0 = born
	elseif self.wave.active or self.wave.elapsed > 0 then
		local dur = plan.duration or self.wave.duration
		local wt = self.wave.elapsed
		zone = Storm.zoneAt(plan.radius, plan.stage, wt, plan.seed, dur)
		t0 = now - wt
		if plan.safeCorners and not self.safeOff and not Storm.safeCornersOn(wt, dur) then
			self.safeOff = true
		end
	else
		return
	end
	if zone.step ~= plan.lastStep then
		plan.lastStep = zone.step
		if zone.step == 100 and self.zoneState then
			-- boss hold: keep the circle the waves ended on, at the boss-ring dps
			local cur = zoneRadius(self.zoneState, now)
			zone.r, zone.toR = cur, cur
		end
		self:setZone(Storm.toWorld(zone, t0))
	end
end

-- Storm damage (every STORM_TICK): standing heroes outside take dps x max HP per
-- second. Ignores armor, dodge, i-frames and shields; never sets lastHurtAt or
-- iframeUntil (POI channels, sprint and PvP hits are untouched); no kill credit
-- beyond the usual assist window. Downed heroes outside bleed out faster.
-- v4: per-hero mice within the view radius (WaveDirector anchors), the average
-- hero level, and the storm circle the director spawns inside.
function World._updateDensity(self: World, now: number)
	if now < (self.nextDensityAt or 0) then
		return
	end
	self.nextDensityAt = now + World.DENSITY_CHECK
	self.levelAvg = self:avgHeroLevel()
	local standing = self.standing
	local view = self.wave.viewRadius
	local v2 = view * view
	local l2 = World.LURE_NEAR * World.LURE_NEAR
	for _, p in standing do
		p.nearMice = 0
		p.closeMice = 0
	end
	for _, e in self.enemies do
		if e.alive and not e.isBoss and not e.isChampion then
			for _, p in standing do
				local d2 = (p.x - e.x) ^ 2 + (p.z - e.z) ^ 2
				if d2 <= v2 then
					p.nearMice += 1
					if d2 <= l2 then
						p.closeMice += 1
					end
				end
			end
		end
	end
	self:_idleLure(now)
end

-- Iteration 2 numbered waves: RunDirector calls this at the start of each wave.
-- `index` = the match wave (1..20; the stage wave is (index - 1) % 5 + 1 unless
-- opts.stageWave). Sets the mouse mix and HP by wave number and the per-wave ramp
-- (WaveDirector.setWave), and opens horde waves (stage waves 1-4) with 2-3 "fronts":
-- FRONT_SHARE of the wave's budget pours in from the storm edge toward the squads
-- over FRONT_TIME s. Returns the number of front mice queued.
-- Iteration 3 (T-3 / T-18): a wave started early in the same stage (the Early Horn) does
-- not lose the rest of the current one: its unspawned budget (at most CARRY_MAX waves'
-- worth) joins the new wave's fronts, the boss wave's too. Event waveStart carries `carry`.
World.CARRY_MAX = 1
function World.startWave(self: World, index: number, opts: any?): number
	local o = if type(opts) == "table" then opts else {}
	local idx = if finite(index) then math.max(1, math.floor(index)) else 1
	local sw = if finite(o.stageWave)
		then math.max(1, math.floor(o.stageWave))
		else (idx - 1) % World.WAVES_PER_STAGE + 1
	local carry = 0
	if
		self.waveBudget
		and self.waveStage == self.stage
		and (self.stageWave or 99) < World.WAVES_PER_STAGE
		and self.now - (self.waveStartAt or self.now) < World.WAVE_SECONDS - 1
	then
		carry = math.floor(
			math.clamp(
				self.waveBudget - math.max(self.waveSpawned or 0, self.waveQueued or 0),
				0,
				self.waveBudget * World.CARRY_MAX
			) + 0.5
		)
	end
	self.waveIndex, self.stageWave = idx, sw
	self.wave:setWave(idx, sw)
	table.clear(self.standing) -- fresh (also before the first step)
	for _, p in self.playerList do
		if isStanding(p) then
			table.insert(self.standing, p)
		end
	end
	self:event({ type = "waveStart", amount = idx, kind = tostring(sw), carry = carry })
	local heroes = self:_spawnHeroes()
	local srm = self.mods.spawnRateMult -- tier / Pressure / curses, like the director
	local budget = WaveDirector.PER_HERO_RATE
		* heroes
		* World.WAVE_SECONDS
		* self.wave:waveRamp()
		* (if finite(srm) and srm > 0 then srm ^ World.FRONT_SPAWN_EXP else 1)
	self.waveBudget, self.waveSpawned, self.waveStartAt, self.waveStage = budget, 0, self.now, self.stage
	-- the boss wave: no fronts of its own (a light trickle from the director), only a carry
	local total = (if sw >= World.WAVES_PER_STAGE then 0 else math.floor(budget * World.FRONT_SHARE + 0.5))
		+ carry
	-- QC iter3 m1: what the fronts/carry already queued counts as spent, so a quick second horn
	-- cannot carry the same budget twice
	self.waveQueued = total
	if sw >= World.WAVES_PER_STAGE then
		self.waveBudget = nil -- nothing carries out of a boss wave
	end
	if total <= 0 or #self.standing == 0 then
		return 0
	end
	-- the squads to march on: centroids of the standing members, a few squads at most
	local cents = {}
	for _, sq in self:aliveSquads() do
		local cx, cz, n = 0, 0, 0
		for _, p in self.standing do
			if p.squad == sq then
				cx += p.x
				cz += p.z
				n += 1
			end
		end
		if n > 0 then
			table.insert(cents, { x = cx / n, z = cz / n })
		end
	end
	if #cents == 0 then
		return 0
	end
	local rng = self.spawnRng
	local nf = rng:nextInt(World.FRONTS[1], World.FRONTS[2])
	local z = self.zoneState
	local ox, oz = if z then z.cx else 0, if z then z.cz else 0
	local edge = (if z then zoneRadius(z, self.now) else self.arenaRadius) - World.FRONT_EDGE
	local per = math.max(1, math.floor(total / nf))
	local owner = { alive = true }
	for f = 1, nf do
		local c = cents[(f - 1) % #cents + 1]
		local dx, dz = c.x - ox, c.z - oz
		local ang = if dx * dx + dz * dz > 1 then math.atan2(dz, dx) else rng:range(0, TAU)
		ang += rng:range(-0.25, 0.25)
		local fx, fz = ox + math.cos(ang) * edge, oz + math.sin(ang) * edge
		local kind = self.wave:pickKind()
		for b = 0, 2 do -- 3 bursts over FRONT_TIME
			local n = math.floor(per / 3) + (if b < per % 3 then 1 else 0)
			self:schedule(self.now + b * World.FRONT_TIME / 3, owner, function()
				if not self.wave.active then
					return
				end
				for _ = 1, n do
					local x = fx + rng:range(-5, 5)
					local zz = fz + rng:range(-5, 5)
					if not self.wave:isValid(x, zz) then
						x, zz = fx, fz
					end
					if self:spawnEnemy(kind, x, zz, false) then
						self.waveSpawned = (self.waveSpawned or 0) + 1
					end
				end
			end)
		end
	end
	return per * nf
end

-- Retires (no drop) up to k plain mice, the furthest from every standing hero first,
-- only those at least minDist from all of them. Returns how many went.
function World._retireFar(self: World, k: number, minDist: number): number
	if k <= 0 then
		return 0
	end
	local far = {}
	local m2 = minDist * minDist
	for _, e in self.enemies do
		if e.alive and not (e.isBoss or e.isMinion or e.isChampion or e.elite or e.poiId or e.carrier) then
			local d = math.huge
			for _, p in self.standing do
				d = math.min(d, (p.x - e.x) ^ 2 + (p.z - e.z) ^ 2)
			end
			if d >= m2 then
				table.insert(far, { e = e, d = d })
			end
		end
	end
	table.sort(far, function(a, b)
		return a.d > b.d
	end)
	local n = math.min(k, #far)
	for i = 1, n do
		self:_killEnemy(far[i].e, nil, true, true)
	end
	return n
end

-- Iteration 1 idle fix (P-12): a standing hero with fewer than LURE_MIN_MICE mice within
-- LURE_NEAR for LURE_AFTER s gets a cluster of LURE_BASE + stage mice LURE_RING studs away
-- (inside the storm circle, at most once per LURE_EVERY s, inside the per-hero cap).
function World._idleLure(self: World, now: number)
	local wave = self.wave
	local cap = math.min(self.cap, WaveDirector.PER_HERO_CAP * #self.standing)
	for _, p in self.standing do
		if (p.closeMice or 0) >= World.LURE_MIN_MICE then
			p.idleSince = nil
		elseif p.idleSince == nil then
			p.idleSince = now
		elseif now - p.idleSince >= World.LURE_AFTER and now >= (p.nextLureAt or 0) then
			p.idleSince = nil
			p.nextLureAt = now + World.LURE_EVERY
			local rng = self.spawnRng
			local srm = self.mods.spawnRateMult
			local want = math.max(
				1,
				math.floor(
					(World.LURE_BASE + self.stage) * (if finite(srm) and srm > 0 then math.min(srm, 3) else 1)
						+ 0.5
				)
			)
			if self.liveCount + want > cap then
				-- at the cap: mice far from everyone make room (stragglers nobody fights)
				self:_retireFar(self.liveCount + want - cap, World.LURE_RETIRE_DIST)
			end
			local n = math.min(want, cap - self.liveCount)
			local kind = wave:pickKind()
			-- ahead of the hero (it is usually walking somewhere): the mice meet it
			local face = math.atan2(p.faceZ or 0, p.faceX or 1)
			for k = 1, 8 do
				local spread = if k <= 4 then World.LURE_AHEAD else math.pi
				local a = face + rng:range(-spread, spread)
				local d = rng:range(World.LURE_RING[1], World.LURE_RING[2])
				local cx, cz = p.x + math.cos(a) * d, p.z + math.sin(a) * d
				if wave:isValid(cx, cz) then
					for _ = 1, n do
						local x, z = cx + rng:range(-2.5, 2.5), cz + rng:range(-2.5, 2.5)
						if not wave:isValid(x, z) then
							x, z = cx, cz
						end
						self:spawnEnemy(kind, x, z, false)
					end
					break
				end
			end
		end
	end
end

function World._updateStorm(self: World, dt: number, now: number)
	local z = self.zoneState
	if not z then
		self.wave.zoneCircle = nil
		return
	end
	if now >= self.stormFxAt then
		self:_stormFx()
	end
	local r = zoneRadius(z, now)
	local r2 = r * r
	local zc = self.wave.zoneCircle or {}
	zc.cx, zc.cz, zc.r = z.cx, z.cz, math.max(1, r - WaveDirector.ZONE_MARGIN)
	self.wave.zoneCircle = zc :: any
	local tick = now >= self.nextStormTick
	if tick then
		self.nextStormTick = now + World.STORM_TICK
	end
	for _, p in self.playerList do
		if p.dead then
			continue
		end
		local outside = (p.x - z.cx) ^ 2 + (p.z - z.cz) ^ 2 > r2
		p.outsideZone = outside
		if not outside then
			continue
		end
		if p.downed then
			if p.downedUntil then
				p.downedUntil -= dt * (World.STORM_DOWNED_DRAIN - 1)
			end
		elseif tick and z.dps > 0 and now >= p.invulnUntil then
			local amount = z.dps * p.maxHp * World.STORM_TICK
			p.hp -= amount
			self:emit({
				t = "hurt",
				id = p.id,
				amount = math.floor(amount + 0.5),
				x = p.x,
				z = p.z,
				storm = true,
			})
			self:event({ type = "stormDamage", id = p.id, amount = amount })
			if p.hp <= 0 then
				self:_down(p, nil)
			end
		end
	end
end

-- v4 Herd Call redeploy: brings a downed or dead hero back at (x, z) with hpFrac of
-- max HP and `protect` seconds of spawn protection (World.SPAWN_PROTECT when nil).
-- Clears the squad's elimination like a respawn. Emits revive kind "redeploy" and a
-- teleport (drainTeleports). Returns false for an unknown or standing hero.
function World.redeploy(
	self: World,
	id: number,
	x: number,
	z: number,
	hpFrac: number?,
	protect: number?
): boolean
	local p = self.players[id]
	if not p or not (p.dead or p.downed) then
		return false
	end
	local px, pz = if finite(x) then x else p.x, if finite(z) then z else p.z
	px, pz = self:clampToArena(px, pz, World.PLAYER_RADIUS)
	px, pz = self:pushOutOfObstacles(px, pz, World.PLAYER_RADIUS)
	self:teleportPlayer(p, px, pz)
	local frac = if finite(hpFrac) and (hpFrac :: number) > 0 then math.min(1, hpFrac :: number) else 0.6
	self:_revive(p, frac, "redeploy")
	p.pvpLock = nil
	p.pvpRegenUntil = nil
	if finite(protect) then
		self:protect(id, math.max(0, protect :: number))
	end
	return true
end

-- v4 hero levels: mice (at spawn), champions and bosses scale with the average
-- level of standing heroes. Read from stats.level, or set here (RunDirector on a
-- level-up). Unknown ids are ignored.
function World.setHeroLevel(self: World, id: number, level: number)
	local p = self.players[id]
	if p and finite(level) then
		p.level = math.max(1, level)
	end
end

function World.avgHeroLevel(self: World): number
	local sum, n = 0, 0
	for _, p in self.playerList do
		if not p.dead then
			local lv = p.level or p.stats.level
			if finite(lv) then
				sum += lv
				n += 1
			end
		end
	end
	return if n > 0 then math.max(1, sum / n) else 1
end

-- v4 Rookie Run: enemy-squad BOTS never target a rookie hero in stage 1 (auto-weapons
-- here, BotBrain through getPlayers().rookie). RunDirector sets it for runs 0-2.
function World.setRookie(self: World, id: number, on: boolean)
	local p = self.players[id]
	if p then
		p.rookie = on == true
		self:_refreshRookies()
	end
end

-- Iteration 1 (P-1, P-29): an enemy-squad BOT never targets a rookie up to
-- ROOKIE_STAGES, nor any member of a rookie's squad up to ROOKIE_SQUAD_STAGES.
-- Iteration 3 (T-4): also a hero revived / redeployed in the last BOT_SAFE_AFTER_REVIVE
-- s, and a human another enemy bot hit in the last BOT_FOCUS_WINDOW s (one bot at a time).
function World._rookieSafe(self: World, attacker: any, h: any): boolean
	if not Ids.isBot(attacker.id) or attacker.squad == h.squad then
		return false
	end
	if h.rookie == true and self.stage <= World.ROOKIE_STAGES then
		return true
	end
	if self.now < (h.botSafeUntil or 0) then
		return true
	end
	if
		h.botFocus ~= nil
		and h.botFocus ~= attacker.id
		and not Ids.isBot(h.id)
		and self.now - (h.botFocusAt or -math.huge) < World.BOT_FOCUS_WINDOW
	then
		return true
	end
	return self.stage <= World.ROOKIE_SQUAD_STAGES and self.rookieSquads[h.squad] == true
end

-- Squads with a rookie member (refreshed every step, and by setRookie).
function World._refreshRookies(self: World)
	table.clear(self.rookieSquads)
	table.clear(self.humanSquads)
	for _, p in self.playerList do
		if p.rookie then
			self.rookieSquads[p.squad] = true
		end
		if not Ids.isBot(p.id) then
			self.humanSquads[p.squad] = true
		end
	end
end

-- x damage a hero takes from mice, champions and bosses: v5 damageTakenMult
-- (Bulwark), a Herdguard squadmate within RunShop.HERDGUARD_RADIUS, and a rookie
-- squad in stage 1 (ROOKIE_MICE_DAMAGE).
function World._pveTakenMult(self: World, p: any): number
	local m = 1
	local dt = p.stats.damageTakenMult
	if finite(dt) and dt > 0 then
		m *= dt
	end
	local res = p.stats.pveResist -- P's DataService.runBonuses extras.pveResist
	if finite(res) and res > 0 then
		m *= 1 - math.min(res, World.PVE_RESIST_MAX)
	end
	if self.stage <= World.ROOKIE_SQUAD_STAGES and self.rookieSquads[p.squad] then
		m *= World.ROOKIE_MICE_DAMAGE
	end
	local r2 = RunShop.HERDGUARD_RADIUS * RunShop.HERDGUARD_RADIUS
	for _, q in self.standing do
		local hg = q.stats.herdguard
		if hg and hg > 0 and q ~= p and q.squad == p.squad and (q.x - p.x) ^ 2 + (q.z - p.z) ^ 2 <= r2 then
			m *= RunShop.HERDGUARD_MULT
			break
		end
	end
	return m
end

-- Spawning weight of the standing heroes (WaveDirector per-hero rate): 1 each,
-- ROOKIE_SPAWN for a rookie squad in stage 1, x FEW_SQUADS_SPAWN with <= FEW_SQUADS squads.
function World._spawnHeroes(self: World): number
	local n = 0
	local rookieStage = self.stage <= World.ROOKIE_SQUAD_STAGES
	for _, p in self.standing do
		n += if rookieStage and self.rookieSquads[p.squad] then World.ROOKIE_SPAWN else 1
	end
	if self.pvp and #self:aliveSquads() <= World.FEW_SQUADS then
		n *= World.FEW_SQUADS_SPAWN
	end
	return n
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
