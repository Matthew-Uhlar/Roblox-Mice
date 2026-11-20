--!strict
-- Headless match driver (lead test infrastructure). Plays whole v2 squad matches
-- (docs/GDD-v2.md §1–4) with only the pure modules in src/shared, mirroring
-- src/server/Services/RunDirector.luau (MatchState stage loop, squad corners,
-- boss winner, route choice by the winner, extraction per squad, PvP events,
-- loot bags, gear, POIs, xp -> level-ups -> upgrade picks, payouts) and
-- src/server/Services/BotService.luau (BotBrain think every 0.1 s, smoothed
-- steering, obstacle push-out, arena clamp, ability casts, swap answers).
--
--   local sim = Headless.new({ seed = 7, humans = { { classId = "ele_fonte" } } })
--   local result = sim:playRun()      -- or sim:playStage() for one stage
--
-- Seating (LobbyService): BotRoster.fillSquads(humans) + BotRoster.flatten, so a
-- solo human gets 2 bot squad-mates and plays against 3 bot squads (12 heroes).
-- MatchState.new(seed, participants) then owns squads, shares, extraction,
-- elimination, kills, loot bags, bounties and payouts.
--
-- Humans are modelled as BotBrains with positive ids (1001, 1002, ...): bots
-- treat them as humans. A "human" presses Second Wind about 1 s after going
-- down (free one per run, 1 per stage), votes on the route through
-- BotBrain.chooseVote (or opts.routePolicy) and decides the extraction through
-- BotBrain.chooseExtract as a stand-in (HUMAN_EXTRACT_POT, or opts.extractPolicy). Its bot
-- squad-mates follow it (BotBrain.chooseVote with the human tally), as in
-- RunDirector. A bot-only squad decides alone: BotBrain.chooseExtract (never
-- Double or Nothing) or MatchState:botExtractChoice.
--
-- v4 (team M2, docs/V4-PLAN.md): The Melt (world:setStormPlan follows the same
-- Config/Storm schedule RunDirector steps through world:setZone; the boss spawns
-- at the circle centre), Herd Call redeploys, top-damage champion / boss rewards
-- with Snatch, secured cheese and the 40-per-stage floor, Double or Nothing x2,
-- bot-only squads by MatchState.botExtractRule (never before the stage-2 gate),
-- Last Herd after 1 alone clear and the Rival Herd. result.v4 carries the v4
-- metrics (squads at each stage start, redeploys, the human's idle time, storm
-- damage, Snatch and DoN counts). tests/sim/v4-report.luau prints them over seeds.
--
-- Differences from the live server, on purpose:
--   * Time is simulated: the world steps at exactly 1/30 s.
--   * Votes resolve after VOTE_SECONDS (the world keeps stepping meanwhile, as
--     it does during the live route choice and Rind Gate windows).
--   * The arena is a pure replica of ArenaBuilder's layout rules (radius = map
--     size, squad corners = Pois.squadCorners as RunDirector uses them,
--     obstacle spacing).
--   * Mouse Champions (v3): championDead pays cheese and the stacking squad buff
--     like RunDirector (gear and xp come from the World itself).
--   * Every participant thinks every 0.1 s (BotService staggers 3 groups).
--   * Humans have no talents, perks or class state (a fresh profile).

local Rng = require("../../src/shared/Util/Rng")
local Squads = require("../../src/shared/Util/Squads")
local RunState = require("../../src/shared/Run/RunState")
local MatchState = require("../../src/shared/Run/MatchState")
local Vote = require("../../src/shared/Run/Vote")
local Stats = require("../../src/shared/Run/Stats")
local Gear = require("../../src/shared/Run/Gear")
local Leveling = require("../../src/shared/Run/Leveling")
local UpgradeOffers = require("../../src/shared/Run/UpgradeOffers")
local World = require("../../src/shared/Combat/World")
local Bosses = require("../../src/shared/Config/Bosses")
local Maps = require("../../src/shared/Config/Maps")
local BotBrain = require("../../src/shared/Bots/BotBrain")
local BotRoster = require("../../src/shared/Bots/BotRoster")
local Pois = require("../../src/shared/Combat/Pois")
local PoiDefs = require("../../src/shared/Config/Pois")
local Champions = require("../../src/shared/Combat/Champions")
local Storm = require("../../src/shared/Config/Storm")
local RunWallet = require("../../src/shared/Run/RunWallet")
local Waves = require("../../src/shared/Run/Waves")

local Headless = {}
Headless.__index = Headless

-- RunDirector / BotService / ArenaBuilder constants (copied; asserted where exported).
Headless.DT = 1 / 30
Headless.WAVE_SECONDS = 132 -- RunDirector.WAVE_SECONDS (4 waves x 30 s + 3 lulls x 4 s)
Headless.BOSS_SECONDS = 120 -- RunDirector.BOSS_SECONDS (iteration 3: was 180): then the top damage squad wins
Headless.VOTE_SECONDS = 3 -- world keeps stepping while the squads choose (bots: 1-4 s)
Headless.STAGE_CLEAR_SECONDS = 2
Headless.PVP_WIPE_GRACE = 12 -- RunDirector.PVP_WIPE_GRACE (the World eliminates squads itself)
Headless.BOSS_FALLBACK_DELAY = 6
Headless.OFFER_CARDS = 3
Headless.BOT_WEIGHT = World.BOT_WEIGHT
Headless.BOT_LEVELS_PER_EVENT = 10 -- RunDirector.grantBotXp caps level-ups per xp event
Headless.THINK_INTERVAL = 0.1
Headless.ACCEL = 10
Headless.PICKUP_SCAN = 20
Headless.PLAYER_RADIUS = World.PLAYER_RADIUS
Headless.HUMAN_SECOND_WIND_DELAY = 1.0
-- The human stand-in's extraction: BotBrain.chooseExtract with this per-member
-- pot threshold instead of the bot squads' BotBrain.EXTRACT_POT (a human stays
-- longer for a bigger pot; balance targets assume about the stage-3 pot).
Headless.HUMAN_EXTRACT_POT = 1400 -- v3: was 800 (pots ~1.7x bigger with champions; still ~the stage-3 pot)
Headless.T0 = 1000 -- sim clock start (like GetServerTimeNow, never 0)
Headless.BOSS_PAD_RADIUS = 14
Headless.SPAWN_RING = 4 -- RunDirector.SPAWN_RING
Headless.HUMAN_ID0 = 1000
Headless.POI_SALT = 0x9017 -- RunDirector.POI_SALT: Rng.new(stageSeed):fork(POI_SALT) -> Pois.layout
Headless.SEAT_SALT = 0x5EA7
Headless.PORTAL_PULL_SECONDS = 1.5 -- RunDirector.PORTAL_PULL_SECONDS
Headless.PORTAL_GOLD = { 255, 204, 51 } -- fillSquads rng (LobbyService uses its own roster seed)

local CHOICES: { string } = table.clone(MatchState.CHOICES)
local STAY_INDEX = table.find(CHOICES, "Stay") :: number
local GEAR_SLOTS = { "weapon", "armor", "trinket" }

export type HumanSpec = { classId: string, partyId: number? }

export type Options = {
	seed: number,
	humans: { HumanSpec }?, -- default: one human playing elephante
	mates: boolean?, -- false: squads that hold humans get no bot mates (LobbyService toggle)
	waveSeconds: number?,
	bossSeconds: number?,
	bossOverride: string?, -- every stage fights this boss
	mapOverride: string?, -- every stage uses this map
	-- Forced choices (simulate the squad's humans). Return nil to let the stand-in decide.
	routePolicy: ((cards: { any }, squad: number, sim: any) -> number?)?,
	extractPolicy: ((squad: number, sim: any) -> string?)?,
	humanSecondWind: boolean?, -- default true
	maxStages: number?, -- stop after this many stages (outcome "MaxStages")
	onTick: ((sim: any, phase: string) -> ())?, -- test hook, called before each world step
	humanIds: { number }?, -- e.g. Studio test players {-1, -2}; default 1001, 1002, ...
	pois: boolean?, -- POIs (Pois.layout + world:addPoi); default true
	pressure: { [string]: number }?, -- Pressure board, passed to MatchState.new as RunDirector does
	storm: boolean?, -- v4 The Melt (default true)
	redeploy: boolean?, -- v4 Herd Call (default true)
	difficulty: number?, -- iteration 2: the ladder tier (Run/Difficulty), nil = no ladder
	skipWaveAt: number?, -- iteration 2: the Early Horn setting (default 70; 0 = Off)
}

export type StageStats = {
	index: number,
	stage: number,
	mapId: string,
	bossId: string,
	tier: string,
	outcome: string, -- "clear" | "over" (the match ended during the stage)
	waveTime: number,
	bossTime: number?, -- boss spawn -> bossDead / timeout (sim seconds)
	bossTimeout: boolean,
	bossFallback: boolean,
	winner: number?,
	winnerBy: string?,
	levelsGained: number,
	damageTaken: number,
	pvpDamage: number,
	downs: number,
	pvpDowns: number,
	deaths: number,
	pvpKills: number,
	revives: number,
	secondWinds: number,
	kills: number,
	enemyPeak: number,
	eliminated: { number }, -- squads eliminated during this stage
	eliminatedAt: { number },
	startedAt: number,
	firstPvpDownAt: number?,
	extracted: { number }, -- squads that extracted at this stage's Rind Gate
	choices: { [number]: string }, -- squad -> extraction choice
	routeChooser: number?,
	bags: number,
	bagsClaimed: number,
	gear: number, -- gear pickups
	pois: { string }?,
	poiActivated: { [string]: number }, -- kind -> activations (camps: wake + chest)
	poiRewards: { [string]: number },
	result: any?, -- MatchState StageResult
	-- v3 Mouse Champions
	champSpawned: number,
	champKilled: number,
	lairSpawned: number,
	lairKilled: number,
	champBySquad: { [number]: number },
	champTimes: { number }, -- fight time (first hero hit -> death) of each rewarded kill
	firstChampKillAt: number?,
	champLog: { any }, -- {at, fight, hp, lair, champId, squad} per rewarded kill
}

-- Squad corners (-,-), (+,-), (+,+), (-,+): Pois.squadCorners, as RunDirector
-- uses them for drop-in spots and safe zones (v3: scaled with the map).
function Headless.squadCorners(R: number): { { x: number, z: number, r: number } }
	return Pois.squadCorners(R)
end

-- Pure replica of ArenaBuilder.build's layout rules (obstacle circles, the boss
-- pad, squad corners). `pois` (Pois.layout entries): obstacles keep clear.
function Headless.arena(
	mapId: string,
	seed: number,
	pois: { any }?,
	radius: number?
): { radius: number, obstacles: { any }, corners: { any } }
	local def = Maps.get(mapId) :: any
	local R = if radius
		then radius
		elseif def and type(def.size) == "number" and def.size >= 40 then def.size
		else 120
	local want = if def and type(def.obstacleCount) == "number" then def.obstacleCount else 18
	local rng = Rng.new(seed):fork(77)
	local corners = Headless.squadCorners(R)
	local obstacles = {}
	local function free(x: number, z: number, r: number): boolean
		if x * x + z * z < (Headless.BOSS_PAD_RADIUS + r + 6) ^ 2 then
			return false
		end
		if x * x + z * z > (R - r - 7) ^ 2 then
			return false
		end
		for _, c in corners do
			if (x - c.x) ^ 2 + (z - c.z) ^ 2 < (c.r + r + 4) ^ 2 then
				return false
			end
		end
		for _, o in obstacles do
			if (x - o.x) ^ 2 + (z - o.z) ^ 2 < (o.r + r + 7) ^ 2 then
				return false
			end
		end
		for _, p in pois or {} do
			if (x - p.x) ^ 2 + (z - p.z) ^ 2 < (r + (p.r or 6) + 6) ^ 2 then
				return false
			end
		end
		return true
	end
	for _ = 1, want do
		for _ = 1, 30 do
			local r = rng:range(2.5, 5)
			local a = rng:range(0, math.pi * 2)
			local d = math.sqrt(rng:range(0, 1)) * R
			local x, z = math.cos(a) * d, math.sin(a) * d
			if free(x, z, r) then
				table.insert(obstacles, { x = x, z = z, r = r })
				break
			end
		end
	end
	return { radius = R, obstacles = obstacles, corners = corners }
end

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function Headless.new(opts: Options): any
	local self = setmetatable({}, Headless) :: any
	self.opts = opts
	self.seed = opts.seed
	self.waveSeconds = opts.waveSeconds or Headless.WAVE_SECONDS
	self.bossSeconds = opts.bossSeconds or Headless.BOSS_SECONDS
	self.poisOn = opts.pois ~= false
	self.stormOn = opts.storm ~= false -- v4 The Melt (default on)
	self.redeployOn = opts.redeploy ~= false -- v4 Herd Call (default on)
	self.v4 = { -- v4 sim metrics
		squadsAtStart = {}, -- [stage] = squads in the run at the stage start (after a Rival Herd)
		rivals = 0,
		redeploys = 0,
		redeploysStarted = 0,
		idleTicks = 0, -- the human: nothing in reach (no mouse within 30, no enemy hero within 45)
		waveTicks = 0,
		idleStreak = 0,
		longestIdle = 0,
		stormDamage = 0,
		stormDowns = 0,
		snatches = 0,
		donPaid = 0,
		donLost = 0,
	}
	self.nextBotN = 200
	self.wallets = {} -- v5: id -> Run/RunWallet (every hero spends rinds on the cheapest rank)
	self.worldRinds = type(World._grantRinds) == "function" -- the World pays rinds / whey (M1)
	self.routeTiers = {} -- iteration 1: the tier of every chosen route card

	-- Seating, exactly as LobbyService: fillSquads + flatten.
	local humanSpecs = opts.humans or { { classId = "elephante" } }
	local list = {}
	for i, spec in humanSpecs do
		local id = if opts.humanIds and opts.humanIds[i] then opts.humanIds[i] else Headless.HUMAN_ID0 + i
		table.insert(list, { id = id, classId = spec.classId, partyId = spec.partyId })
	end
	local seats, overflow = BotRoster.fillSquads(list, Rng.new(opts.seed):fork(Headless.SEAT_SALT), {
		mates = opts.mates ~= false,
	})
	assert(#overflow == 0, "Headless.new: more humans than seats")
	self.seats = seats
	local flat = BotRoster.flatten(seats)
	local participants = {}
	for _, m in flat do
		table.insert(participants, { id = m.id, squad = m.squad, isBot = m.isBot, classId = m.classId })
	end
	self.match = MatchState.new(opts.seed, participants, {
		bossIds = Bosses.ORDER,
		mapIds = Maps.ORDER,
		pressure = opts.pressure,
		botWeight = Headless.BOT_WEIGHT,
		difficulty = opts.difficulty, -- iteration 2: the ladder tier (RunDirector passes it)
	})

	-- Same fork order as RunDirector.startRun.
	local rng = Rng.new(opts.seed)
	self.voteRng = rng:fork(1)
	self.botRng = rng:fork(2)
	self.gearRng = rng:fork(3)
	self.humanVoteRng = rng:fork(4) -- the humans' own choices (clients in reality)
	local brainRoot = rng:fork(7)

	self.members = {}
	self.byId = {}
	for i, m in flat do
		local member = {
			id = m.id,
			classId = m.classId or "elephante",
			isBot = m.isBot,
			squad = m.squad,
			name = m.name,
			offerRng = rng:fork(200 + i),
			level = 1,
			xp = 0,
			stacks = {},
			gear = {},
			brain = BotBrain.new(m.id, m.classId or "elephante", brainRoot:fork(1000 + i)),
			intent = { moveX = 0, moveZ = 0, speedFrac = 0 },
			velX = 0,
			velZ = 0,
			freeSecondWindUsed = false,
			secondWindsThisStage = 0,
			downedAt = nil,
			picks = {},
		}
		table.insert(self.members, member)
		self.byId[m.id] = member
	end

	-- The first human (opts.humans[1]); members are in squad order, so it is
	-- not necessarily members[1].
	for _, m in self.members do
		if not m.isBot then
			self.human = m
			break
		end
	end

	self.now = Headless.T0
	self.stageIndex = 0
	self.stages = {}
	self.world = nil
	self.phase = "Lobby"
	self.thinkAcc = 0
	self.downSince = {}
	self.bossDead = false
	self.bossKill = nil
	self.bossesKilled = 0
	self.buffs = {} -- [squad] = { Pois.Buff }, like RunDirector's c.buffs
	self.champSpawnAt = {} -- champion entity id -> spawn time (stats)
	self.totals =
		{ pvpDowns = 0, pvpKills = 0, bags = 0, bagsClaimed = 0, gear = 0, humanGear = 0, friendlyHits = 0 }
	self.pvpBySquad = {} -- [squad] = { downs, kills }
	for s = 1, Squads.MAX do
		self.pvpBySquad[s] = { downs = 0, kills = 0 }
	end
	return self
end

-- Members of the match still in the run (bots and humans).
function Headless.inRun(self: any): { any }
	local out = {}
	for _, m in self.members do
		if self.match:isInRun(m.id) then
			table.insert(out, m)
		end
	end
	return out
end

function Headless.humanOf(self: any, squad: number): { any }
	local out = {}
	for _, m in self.members do
		if not m.isBot and m.squad == squad and self.match:isInRun(m.id) then
			table.insert(out, m)
		end
	end
	return out
end

-- Stats / upgrades / gear ------------------------------------------------------------------

-- RunDirector.computeStats: Stats.compute -> Gear.apply -> squad shrine buffs.
function Headless._computeStats(self: any, m: any)
	local stats, weapon, ability =
		Stats.compute(m.classId, m.stacks, self.match:blessingsFor(m.squad), {}, nil)
	if next(m.gear) ~= nil then
		local s2, w2, a2 = Gear.apply(stats, weapon, ability, m.gear)
		if type(s2) == "table" then
			stats, weapon, ability = s2, w2 or weapon, a2 or ability
		end
	end
	local buffs = self.buffs[m.squad]
	if buffs and #buffs > 0 then
		stats = Pois.applyBuffs(stats, buffs, self.now)
	end
	m.stats, m.weapon, m.ability = stats, weapon, ability
	local bonus = if finite(stats.extractBonus) then stats.extractBonus else 0
	self.match:setExtractMult(m.id, 1 + math.max(0, bonus))
end

function Headless._push(self: any, m: any)
	self:_computeStats(m)
	local world = self.world
	if world and world:getPlayer(m.id) then
		world:updatePlayer(m.id, m.stats, m.weapon)
	end
end

-- Every hero in the run (RunDirector.refreshSquad for each squad).
function Headless._refreshStats(self: any)
	for _, s in self.match:squadsInRun() do
		self:_refreshSquad(s)
	end
end

function Headless._refreshSquad(self: any, squad: number)
	for _, m in self.members do
		if m.squad == squad and self.match:isInRun(m.id) then
			self:_push(m)
		end
	end
end

-- Re-reads a hero's gear from the World (the truth while a stage runs).
function Headless._syncGear(self: any, m: any)
	local world = self.world
	if world then
		local g = world:gearOf(m.id)
		local clean = {}
		for _, slot in GEAR_SLOTS do
			if type(g) == "table" and type(g[slot]) == "table" then
				clean[slot] = g[slot]
			end
		end
		m.gear = clean
	end
end

function Headless._levelUp(self: any, m: any, epic: boolean?)
	local luck = (if m.stats and finite(m.stats.luck) then m.stats.luck else 0) + self.match:pressureLuck()
	local cards = if epic
		then Pois.epicCards(m.offerRng, m.classId, m.stacks, PoiDefs.EPIC_CARDS)
		else UpgradeOffers.roll(m.offerRng, m.classId, m.stacks, luck, Headless.OFFER_CARDS)
	if #cards == 0 then
		return
	end
	local card = cards[BotBrain.chooseUpgrade(cards, self.botRng)]
	if not card then
		return
	end
	m.stacks[card.id] = (m.stacks[card.id] or 0) + 1
	table.insert(m.picks, card.id)
	self:_push(m)
	local heal = card.delta and card.delta.heal
	if self.world and finite(heal) and heal > 0 then
		self.world:healPlayer(m.id, heal)
	end
end

function Headless._grantXp(self: any, m: any, amount: any)
	if not finite(amount) or amount <= 0 or not self.match:isInRun(m.id) then
		return
	end
	local newLevel, newXp, gained = Leveling.addXp(m.level, m.xp, amount)
	m.level, m.xp = newLevel, newXp
	if self.cur and gained > 0 then
		self.cur.levelsGained += gained
	end
	local n = if m.isBot then math.min(gained, Headless.BOT_LEVELS_PER_EVENT) else gained
	for _ = 1, n do
		self:_levelUp(m)
	end
end

-- Per-tick driving (BotService.stepBots) -------------------------------------------------------

function Headless._allies(self: any): { any }
	local list = {}
	for id, p in self.world:getPlayers() do
		if not p.dead and finite(p.x) and finite(p.z) then
			table.insert(list, {
				id = id,
				x = p.x,
				z = p.z,
				downed = p.downed == true,
				isBot = p.isBot,
				squad = p.squad,
				protected = p.protected == true,
				lastHitBy = p.lastHitBy,
				lastHitAt = p.lastHitAt,
			})
		end
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

function Headless._drive(self: any, dt: number)
	local world = self.world
	self.thinkAcc += dt
	local think = self.thinkAcc >= Headless.THINK_INTERVAL - 1e-9
	local thinkDt = self.thinkAcc
	if think then
		self.thinkAcc = 0
	end
	local now = world.now
	local enemies, allies, poiView, portalView, gearView, bagView
	if think then
		enemies = world:snapshot()
		allies = self:_allies()
		poiView = world:pois()
		portalView = world:portal()
		gearView = world:groundItems()
		bagView = world:lootBags()
	end
	local alpha = 1 - math.exp(-Headless.ACCEL * dt)
	local radius = world.arenaRadius
	local stage, waveTime = world:stageClock() -- BotService passes the same (PvP pacing)
	local zoneView = if think and type(world.zone) == "function" then world:zone() else nil
	for _, m in self.members do
		local info = world:getPlayer(m.id)
		if not info then
			continue
		end
		local x, z = info.x, info.z
		if think then
			local offer = info.swapOffer
			if type(offer) == "table" then
				world:resolveSwap(m.id, BotBrain.chooseSwap(offer.current, offer.item) == true)
				self:_syncGear(m)
				self:_push(m)
			end
			local view = {
				self = {
					x = x,
					z = z,
					hp = info.hp,
					maxHp = info.maxHp,
					downed = info.downed == true,
					abilityReady = now >= (info.abilityReadyAt or 0),
					squad = info.squad or m.squad,
					gear = info.gear,
					lastHitBy = info.lastHitBy,
					lastHitAt = info.lastHitAt,
				},
				allies = allies,
				enemies = enemies,
				pickups = world:pickupsNear(x, z, Headless.PICKUP_SCAN),
				arenaRadius = radius,
				obstacles = world.obstacles,
				now = now,
				pois = poiView,
				portal = portalView,
				gear = gearView,
				bags = bagView,
				stage = stage,
				waveTime = waveTime,
				zone = zoneView, -- v4 The Melt (BotService passes the same)
			}
			m.intent = m.brain:think(view, thinkDt)
		end
		if info.dead then
			m.velX, m.velZ = 0, 0
			continue
		end
		-- Humans press Second Wind ~1 s after going down (free one per run, 1 per stage).
		if info.downed and not m.isBot and self.opts.humanSecondWind ~= false then
			m.downedAt = m.downedAt or self.now
			if
				self.now - m.downedAt >= Headless.HUMAN_SECOND_WIND_DELAY
				and not m.freeSecondWindUsed
				and m.secondWindsThisStage < 1
			then
				if world:useSecondWind(m.id) then
					m.freeSecondWindUsed = true
					m.secondWindsThisStage += 1
					self.cur.secondWinds += 1
					m.downedAt = nil
				end
			end
		elseif not info.downed then
			m.downedAt = nil
		end
		local ab = m.intent.ability
		if ab and not info.downed then
			m.intent.ability = nil
			world:useAbility(m.id, ab.x, ab.z, now)
		end
		-- v3: walkSpeed carries the out-of-combat sprint (BotService does the same)
		local speed = if finite(info.walkSpeed)
			then info.walkSpeed
			elseif finite(info.moveSpeed) then info.moveSpeed
			else 16
		if info.downed then
			speed *= World.DOWNED_SPEED
		elseif info.slowed then
			speed *= World.PLAYER_SLOW
		end
		local frac = math.clamp(m.intent.speedFrac or 0, 0, 1)
		local tx, tz = (m.intent.moveX or 0) * speed * frac, (m.intent.moveZ or 0) * speed * frac
		m.velX += (tx - m.velX) * alpha
		m.velZ += (tz - m.velZ) * alpha
		x += m.velX * dt
		z += m.velZ * dt
		x, z = world:pushOutOfObstacles(x, z, Headless.PLAYER_RADIUS)
		local lim = radius - Headless.PLAYER_RADIUS
		local d = math.sqrt(x * x + z * z)
		if d > lim and d > 0 then
			x, z = x / d * lim, z / d * lim
		end
		world:setPlayerPosition(m.id, x, z)
	end
end

-- World events (RunDirector.handleWorldEvent) --------------------------------------------------

-- RunDirector.dropBag: the World's bag (heroKilled.bag) gets the cheese, else a new bag.
function Headless._dropBag(self: any, id: number, cheese: number, key: number?, worldBag: any, x: any, z: any)
	if not key then
		return
	end
	local world = self.world
	if worldBag ~= nil then
		if cheese > 0 and world:addBagCheese(worldBag, cheese) == false then
			self.match:refundShare(id, cheese)
			return
		end
		self.match:registerBag(worldBag, key)
	else
		if cheese <= 0 then
			return
		end
		local bx, bz = x, z
		if not (finite(bx) and finite(bz)) then
			local info = world:getPlayer(id)
			bx, bz = if info then info.x else 0, if info then info.z else 0
		end
		local bagId = world:addLootBag(bx, bz, {}, cheese)
		if bagId == nil then
			self.match:refundShare(id, cheese)
			return
		end
		self.match:registerBag(bagId, key)
	end
	self.cur.bags += 1
	self.totals.bags += 1
	local m = self.byId[id]
	if m then
		self:_syncGear(m)
	end
end

function Headless._eliminate(self: any, squad: number)
	local res = self.match:eliminateSquad(squad)
	if #res.out == 0 then
		return
	end
	for _, d in res.drops do
		self:_dropBag(d.id, d.cheese, d.key, nil, nil, nil)
	end
	table.insert(self.cur.eliminated, squad)
	table.insert(self.cur.eliminatedAt, self.now - self.cur.startedAt)
end

-- RunDirector.eliminateFallen (right before resolveExtraction).
function Headless._eliminateFallen(self: any)
	local world = self.world
	for _, s in
		self.match:fallenSquads(function(id: number): boolean?
			local info = world:getPlayer(id)
			if not info then
				return nil
			end
			return not info.downed and not info.dead
		end)
	do
		self.downSince[s] = nil
		self:_eliminate(s)
	end
end

function Headless._handleEvents(self: any)
	local st = self.cur
	local match = self.match
	for _, e in self.world:drainEvents() do
		local kind = e.type
		local m = if e.id ~= nil then self.byId[e.id] else nil
		if kind == "xp" then
			if m then
				self:_grantXp(m, e.amount)
			end
		elseif kind == "damaged" then
			st.damageTaken += e.amount or 0
			local by = if type(e.by) == "number" then self.byId[e.by] else nil
			if by and m and by.squad ~= m.squad then
				st.pvpDamage += e.amount or 0
			elseif by and m and by ~= m and (e.amount or 0) > 0 then
				self.totals.friendlyHits += 1 -- must stay 0: no friendly fire
			end
		elseif kind == "downed" then
			st.downs += 1
		elseif kind == "dead" then
			st.deaths += 1
		elseif kind == "revived" then
			if e.kind == "teammate" then
				st.revives += 1
			end
		elseif kind == "kill" then
			st.kills += 1
			if self.waves and m then
				Waves.noteKill(self.waves)
			end
			if m and not self.worldRinds then
				local w = self:_wallet(m.id)
				self:_earn(m.id, RunWallet.rindsFor("mouse", match.stage), nil, RunWallet.rindMult(w))
			end
		elseif kind == "rinds" then
			self.worldRinds = true
			if m then
				self:_earn(m.id, e.amount or 0)
			end
		elseif kind == "whey" then
			if m then
				self:_earn(m.id, nil, e.amount or 0)
			end
		elseif kind == "heroDowned" then
			local r = match:heroDowned(e.id, e.by)
			if r and r.killerSquad then
				match:cutRedeploy(r.killerSquad, MatchState.CONFIG.REDEPLOY_CUT_DOWN)
				st.firstPvpDownAt = st.firstPvpDownAt or (self.now - st.startedAt)
				st.pvpDowns += 1
				self.totals.pvpDowns += 1
				self.pvpBySquad[r.killerSquad].downs += 1
			end
		elseif kind == "heroKilled" then
			local r = match:heroKilled(e.id, e.by)
			if r then
				if r.killerSquad then
					st.pvpKills += 1
					self.totals.pvpKills += 1
					self.pvpBySquad[r.killerSquad].kills += 1
				end
				self:_dropBag(r.victim, r.bagCheese, r.bagKey, e.bag, e.x, e.z)
				if self.redeployOn then
					local mate = self:_standingMate(r.victim)
					if match:startRedeploy(r.victim, self.now, mate ~= nil, self.waveEndsAt) then
						self.v4.redeploysStarted += 1
					end
				end
			end
		elseif kind == "stormDamage" then
			if m and not m.isBot then
				self.v4.stormDamage += e.amount or 0
			end
		elseif kind == "squadEliminated" then
			if Squads.isValid(e.squad) then
				self:_eliminate(e.squad)
			end
		elseif kind == "lootBag" then
			if type(e.by) == "number" and match:claimBag(e.bag, e.by) > 0 then
				st.bagsClaimed += 1
				self.totals.bagsClaimed += 1
			end
		elseif kind == "gearPickup" then
			if m then
				self:_syncGear(m)
				self:_push(m)
				st.gear += 1
				self.totals.gear += 1
				if not m.isBot then
					self.totals.humanGear += 1
				end
			end
		elseif kind == "bossDead" then
			if not self.bossDead then
				self.bossDead = true
				self.bossKill = e
				st.bossTime = self.now - self.bossSpawnAt
			end
		elseif kind == "poiActivated" then
			st.poiActivated[e.kind] = (st.poiActivated[e.kind] or 0) + 1
		elseif kind == "poiReward" then
			st.poiRewards[e.kind] = (st.poiRewards[e.kind] or 0) + 1
			self:_poiReward(e)
		elseif kind == "championSpawn" then
			st.champSpawned += 1
			if e.lair then
				st.lairSpawned += 1
			end
			self.champSpawnAt[e.champ] = self.now
		elseif kind == "championDead" then
			self:_championDead(e)
		end
	end
end

-- RunDirector's championDead handler, minus toasts and the kill feed: the
-- rewarded squad's pending cheese (Pressure applied) and its stacking buff.
function Headless._championDead(self: any, e: any)
	local st = self.cur
	local match = self.match
	-- v4: the top-damage squad (MatchState.championKilled; Snatch for the killer)
	local amount = if finite(e.cheese) and e.cheese > 0
		then RunState.applyPressureCheese(math.floor(e.cheese), match:pressurePoints())
		else 0
	local res = match:championKilled(e.damageBySquad, e.killerSquad, e.squad, amount)
	local s = res.winner
	self:_earnSplit(
		e.damageBySquad,
		RunWallet.rindsFor("champion", match.stage),
		RunWallet.Shop.WHEY.championTop,
		RunWallet.Shop.WHEY.championOther
	)
	if s == nil then
		return
	end
	if res.snatch then
		self.v4.snatches += 1
	end
	st.champKilled += 1
	if e.lair then
		st.lairKilled += 1
	end
	st.champBySquad[s] = (st.champBySquad[s] or 0) + 1
	self.champSpawnAt[e.champ] = nil
	if finite(e.fightTime) then
		table.insert(st.champTimes, e.fightTime) -- first hero hit -> death
		table.insert(st.champLog, {
			at = self.now - st.startedAt,
			fight = e.fightTime,
			hp = e.maxHp,
			lair = e.lair == true,
			champId = e.champId,
			squad = s,
		})
	end
	st.firstChampKillAt = st.firstChampKillAt or (self.now - st.startedAt)
	if type(e.buff) == "table" and type(e.buff.stat) == "string" then
		self.buffs[s] = self.buffs[s] or {}
		Champions.addSquadBuff(self.buffs[s], e.buff, self.now)
		self:_refreshSquad(s)
	end
end

-- RunDirector.onPoiReward, minus the Roblox side (toasts, carts, profiles).
function Headless._poiReward(self: any, e: any)
	local kind = tostring(e.kind)
	if kind == "shop_cart_open" or kind == "totem_owner" or e.reward == "cart" then
		return
	end
	local match = self.match
	match:notePoi(e.by)
	local s = if Squads.isValid(e.squad) then e.squad else match:squadOf(e.by)
	local squads = if s and match:isSquadInRun(s) then { s } else match:squadsInRun()
	local def = PoiDefs.get(kind)
	local reward = if def then def.reward else nil
	match:cutRedeploy(match:squadOf(e.by), MatchState.CONFIG.REDEPLOY_CUT_POI)
	if type(e.by) == "number" then
		self:_earn(e.by, nil, RunWallet.Shop.WHEY.poi)
	end
	if finite(e.cheese) and e.cheese > 0 then
		local amount = RunState.applyPressureCheese(math.floor(e.cheese), match:pressurePoints())
		for _, q in squads do
			if kind == "vault" or reward == "vault" then
				match:addSquadReward(q, amount) -- v4 secured
			else
				match:addSquadCheese(q, amount)
			end
		end
	end
	if reward == "buff" and type(e.buff) == "table" and type(e.buff.stat) == "string" then
		for _, q in squads do
			self.buffs[q] = self.buffs[q] or {}
			Pois.addBuff(self.buffs[q], e.buff, self.now)
			self:_refreshSquad(q)
		end
	elseif reward == "elite_chest" or reward == "epic_pick" then
		for _, m in self.members do
			if table.find(squads, m.squad) and match:isInRun(m.id) then
				self:_levelUp(m, reward == "epic_pick")
			end
		end
	elseif reward == "revive" then
		for _, m in self.members do
			if table.find(squads, m.squad) then
				m.freeSecondWindUsed = false -- RunTokens refill
				m.secondWindsThisStage = 0
			end
		end
	end
end

-- v5 run economy (RunDirector K.earn / K.earnSplit / K.botSpend) ---------------------------

function Headless._wallet(self: any, id: number): any
	local w = self.wallets[id]
	if not w then
		w = RunWallet.new()
		self.wallets[id] = w
	end
	return w
end

function Headless._earn(self: any, id: number, rinds: number?, whey: number?, mult: number?)
	if not self.match:isInRun(id) then
		return
	end
	local w = self:_wallet(id)
	if rinds and rinds > 0 then
		RunWallet.earnRinds(w, rinds, mult, self.worldRinds)
	end
	if whey and whey > 0 then
		RunWallet.earnWhey(w, whey)
	end
	-- every hero (the human stand-in too) buys the cheapest next rank it can afford
	local bought = false
	for _ = 1, 25 do
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
	local m = self.byId[id]
	if bought and m and type(self.world.setRunMods) == "function" then
		self.world:setRunMods(id, RunWallet.deltas(w, m.classId))
	end
end

function Headless._earnSplit(
	self: any,
	damageBySquad: any,
	total: number,
	wheyTop: number?,
	wheyOther: number?
)
	if type(damageBySquad) ~= "table" then
		return
	end
	local sum, top, topD = 0, nil, 0
	for sq, d in damageBySquad :: any do
		if type(d) == "number" and d > 0 then
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
		if s and type(d) == "number" and d > 0 and self.match:isSquadInRun(s) then
			local part = if self.worldRinds then 0 else total * d / sum
			local whey = if self.worldRinds then nil elseif s == top then wheyTop else wheyOther
			for _, id in self.match:activeMembers(s) do
				self:_earn(id, part, whey)
			end
		end
	end
end

-- v4 Herd Call helpers (RunDirector K.standingMate / K.redeployTick) -------------------

function Headless._standingMate(self: any, id: number): (number?, number, number)
	local squad = self.match:squadOf(id)
	if not squad then
		return nil, 0, 0
	end
	local best, bestHp, bx, bz = nil, -1, 0, 0
	for _, mid in self.match:activeMembers(squad) do
		if mid ~= id then
			local info = self.world:getPlayer(mid)
			if info and not info.downed and not info.dead and info.hp > bestHp then
				best, bestHp, bx, bz = mid, info.hp, info.x, info.z
			end
		end
	end
	return best, bx, bz
end

function Headless._redeployTick(self: any)
	if not self.redeployOn then
		return
	end
	local C = MatchState.CONFIG
	for _, id in self.match:dueRedeploys(self.now, self.waveEndsAt) do
		local mate, mx, mz = self:_standingMate(id)
		if mate and self.world:redeploy(id, mx + 3, mz, C.REDEPLOY_HP, C.REDEPLOY_PROTECT) then
			self.match:completeRedeploy(id)
			self.v4.redeploys += 1
		end
	end
end

-- v4 Rival Herd (RunDirector K.addRival): a fresh bot squad at the stage start.
function Headless._addRival(self: any)
	local taken = {}
	for _, m in self.members do
		table.insert(taken, m.id)
	end
	local specs = BotRoster.rivalSquad(self.botRng, taken)
	local parts = {}
	for _, sp in specs do
		table.insert(parts, { id = sp.id, classId = sp.classId })
	end
	local slot = self.match:addRivalSquad(parts, "Rival Herd")
	if not slot then
		return
	end
	self.v4.rivals += 1
	local sum, n = 0, 0
	for _, m in self:inRun() do
		sum += m.level
		n += 1
	end
	local level = if n > 0 then math.max(1, math.floor(sum / n + 0.5)) else 1
	for _, sp in specs do
		self.nextBotN += 1
		local member = {
			id = sp.id,
			classId = sp.classId,
			isBot = true,
			squad = slot,
			name = sp.name,
			offerRng = Rng.new(self.seed):fork(600 + self.nextBotN),
			level = 1,
			xp = 0,
			stacks = {},
			gear = {},
			brain = BotBrain.new(sp.id, sp.classId, Rng.new(self.seed):fork(700 + self.nextBotN)),
			intent = { moveX = 0, moveZ = 0, speedFrac = 0 },
			velX = 0,
			velZ = 0,
			freeSecondWindUsed = false,
			secondWindsThisStage = 0,
			downedAt = nil,
			picks = {},
		}
		table.insert(self.members, member)
		self.byId[sp.id] = member
		self:_computeStats(member)
		for _ = 2, math.min(level, 31) do
			member.level += 1
			self:_levelUp(member)
		end
	end
end

-- v4 idle metric for the human stand-in: no mouse within 30 studs and no enemy
-- hero within 45 (QA-A "nothing in reach").
function Headless._sampleIdle(self: any)
	local h = self.human
	local world = self.world
	local info = h and world:getPlayer(h.id)
	if not info or info.dead or not self.match:isInRun(h.id) then
		return
	end
	local busy = false
	for _, e in world.enemies do
		if e.alive and (e.x - info.x) ^ 2 + (e.z - info.z) ^ 2 <= 900 then
			busy = true
			break
		end
	end
	if not busy then
		for _, p in world.playerList do
			if p.squad ~= h.squad and not p.dead and (p.x - info.x) ^ 2 + (p.z - info.z) ^ 2 <= 2025 then
				busy = true
				break
			end
		end
	end
	local v = self.v4
	v.waveTicks += 1
	if busy then
		v.idleStreak = 0
	else
		v.idleTicks += 1
		v.idleStreak += 1
		v.longestIdle = math.max(v.longestIdle, v.idleStreak)
	end
end

-- One 1/30 s tick: drive participants, step the world, handle events.
function Headless.tick(self: any)
	local dt = Headless.DT
	if self.opts.onTick then
		self.opts.onTick(self, self.phase)
	end
	self:_drive(dt)
	self.now += dt
	local world = self.world
	for q, list in self.buffs do
		if #list > 0 and Pois.pruneBuffs(list, self.now) then
			self:_refreshSquad(q)
		end
	end
	world:step(dt, self.now)
	world:drainTeleports()
	self:_handleEvents()
	local n = world:enemyCount()
	if n > self.cur.enemyPeak then
		self.cur.enemyPeak = n
	end
end

-- RunDirector.squadWipeCheck (the PvP World eliminates squads itself; this is the
-- PVP_WIPE_GRACE safety net) + stageOver (Results, or no human left).
function Headless._stageOver(self: any): boolean
	local match = self.match
	local world = self.world
	if match.phase ~= "Results" then
		for _, s in match:squadsInRun() do
			local anyIn, standing = false, false
			for _, id in match:activeMembers(s) do
				local info = world:getPlayer(id)
				if info then
					anyIn = true
					if not info.downed and not info.dead then
						standing = true
					end
				end
			end
			if anyIn and not standing then
				self.downSince[s] = self.downSince[s] or self.now
				if self.now - self.downSince[s] >= Headless.PVP_WIPE_GRACE then
					self.downSince[s] = nil
					self:_eliminate(s)
				end
			else
				self.downSince[s] = nil
			end
		end
	end
	if match.phase == "Results" then
		return true
	end
	if match:humansInRun() == 0 then
		match:finish("noHumans")
		return true
	end
	return false
end

function Headless._stepFor(self: any, seconds: number): boolean
	local steps = math.floor(seconds / Headless.DT + 0.5)
	for _ = 1, steps do
		self:tick()
		if self:_stageOver() then
			return true
		end
	end
	return false
end

-- Votes -------------------------------------------------------------------------------------------

-- The winner picks the next route: its humans (stand-in or routePolicy), its bots
-- follow (BotBrain.chooseVote with the human tally); an all-bot squad picks alone.
function Headless._routeChoice(self: any, winner: number?): number
	local match = self.match
	local cards = match:routeCards() or {}
	local default = MatchState.defaultRouteIndex(cards)
	if #cards == 0 then
		return default
	end
	-- iteration 1 (C-1, RunDirector): nobody won = a weighted random tier; a bot-only
	-- winner picks by stage, HP and pot
	if not winner or not match:isSquadInRun(winner) then
		return MatchState.randomRouteIndex(cards, self.voteRng)
	end
	if #self:humanOf(winner) == 0 then
		local best = 0
		for _, s2 in match:squadsInRun() do
			best = math.max(best, self:_memberPot(s2))
		end
		return MatchState.botRouteIndex(
			cards,
			match.stage + 1, -- the stage the card is for
			self.voteRng,
			self:_squadHpFrac(winner),
			self:_memberPot(winner) < best
		)
	end
	local voters = match:activeMembers(winner)
	local vote = Vote.new(#cards, voters)
	local tally = table.create(#cards, 0)
	local best = 0
	for _, s2 in match:squadsInRun() do
		best = math.max(best, self:_memberPot(s2))
	end
	for _, m in self:humanOf(winner) do
		local forced = self.opts.routePolicy and self.opts.routePolicy(cards, winner, self)
		-- iteration 1: the human stand-in gambles on the route like a bot squad
		-- (stage, HP, pot) instead of always taking the safe Low card
		local i = forced
			or MatchState.botRouteIndex(
				cards,
				match.stage + 1,
				self.humanVoteRng,
				self:_squadHpFrac(winner),
				self:_memberPot(winner) < best
			)
		vote:cast(m.id, i)
		tally[i] += 1
	end
	for _, id in voters do
		local m = self.byId[id]
		if m and m.isBot then
			vote:cast(id, BotBrain.chooseVote("route", cards, tally, self.botRng))
		end
	end
	return vote:resolve(self.voteRng, default)
end

-- RunDirector.squadHpFrac: average HP fraction of a squad's members not dead.
function Headless._squadHpFrac(self: any, squad: number): number
	local sum, n = 0, 0
	for _, id in self.match:activeMembers(squad) do
		local info = self.world:getPlayer(id)
		if info and not info.dead and finite(info.hp) and finite(info.maxHp) and info.maxHp > 0 then
			sum += math.clamp(info.hp / info.maxHp, 0, 1)
			n += 1
		end
	end
	return if n > 0 then sum / n else 1
end

-- RunDirector.memberPot: the squad's pot per member.
function Headless._memberPot(self: any, squad: number): number
	local n = #self.match:activeMembers(squad)
	return if n > 0 then math.floor(self.match:squadPending(squad) / n) else 0
end

-- RunDirector.extractView: the Match view with each squad's hpFrac and
-- `pending` as the per-member pot (BotBrain.chooseExtract's input).
function Headless._extractView(self: any): { [string]: any }
	local world = self.world
	local view = self.match:getPublic(nil, function(id: number): boolean
		local info = world:getPlayer(id)
		if info then
			return not info.downed and not info.dead
		end
		local m = self.match:member(id)
		return m ~= nil and not m.dead
	end)
	for s, sq in view.squads do
		sq.hpFrac = self:_squadHpFrac(s)
		sq.squadPending = sq.pending
		sq.pending = self:_memberPot(s)
	end
	return view
end

-- Every squad in the run: Extract / Stay / Double or Nothing (RunDirector.runExtraction).
function Headless._extractChoices(self: any): { [number]: string }
	local match = self.match
	local choices: { [number]: string } = {}
	local risky = Vote.riskyIndices(CHOICES)
	for _, s in match:squadsInRun() do
		local humans = self:humanOf(s)
		if #humans == 0 then
			-- v4 (RunDirector): never before the stage-2 gate, then at 330 / 420 per member
			local sq = match:squad(s)
			choices[s] = if sq and sq.rival
				then "Stay" -- a Rival Herd never extracts
				else MatchState.botExtractRule(match.stage, self:_memberPot(s), s)
		else
			local vote = Vote.new(#CHOICES, match:activeMembers(s))
			local tally = table.create(#CHOICES, 0)
			for _, m in humans do
				local forced = self.opts.extractPolicy and self.opts.extractPolicy(s, self)
				local pick = forced
					or BotBrain.chooseExtract(
						self:_extractView(),
						s,
						self.humanVoteRng,
						-- the target pot is in the board's own cheese: Pressure pays more
						-- per stage, so the same "stage-3 pot" is bigger (v3: with the
						-- champion cheese a fixed target made high Pressure extract sooner)
						RunState.applyPressureCheese(Headless.HUMAN_EXTRACT_POT, match:pressurePoints())
					)
				local i = table.find(CHOICES, pick) or STAY_INDEX
				vote:cast(m.id, i)
				tally[i] += 1
			end
			for _, id in match:activeMembers(s) do
				local m = self.byId[id]
				if m and m.isBot then
					vote:cast(
						id,
						BotBrain.chooseVote("extract", CHOICES, tally, self.botRng, {
							pot = self:_memberPot(s),
							hpFrac = self:_squadHpFrac(s),
						})
					)
				end
			end
			choices[s] = CHOICES[vote:resolve(self.voteRng, STAY_INDEX, risky)]
		end
	end
	return choices
end

-- Stage ---------------------------------------------------------------------------------------------

function Headless._newStageStats(self: any, card: any, mapId: string, bossId: string): StageStats
	return {
		index = self.stageIndex,
		stage = self.match.stage,
		mapId = mapId,
		bossId = bossId,
		tier = card.tier,
		outcome = "clear",
		waveTime = 0,
		bossTime = nil,
		bossTimeout = false,
		bossFallback = false,
		winner = nil,
		winnerBy = nil,
		levelsGained = 0,
		damageTaken = 0,
		pvpDamage = 0,
		downs = 0,
		pvpDowns = 0,
		deaths = 0,
		pvpKills = 0,
		revives = 0,
		secondWinds = 0,
		kills = 0,
		enemyPeak = 0,
		eliminated = {},
		eliminatedAt = {}, -- sim seconds since the stage started
		startedAt = self.now,
		firstPvpDownAt = nil,
		extracted = {},
		choices = {},
		routeChooser = nil,
		bags = 0,
		bagsClaimed = 0,
		gear = 0,
		pois = nil,
		poiActivated = {},
		poiRewards = {},
		result = nil,
		-- v3 Mouse Champions
		champSpawned = 0,
		champKilled = 0, -- killed with a rewarded squad
		lairSpawned = 0,
		lairKilled = 0,
		champBySquad = {}, -- squad -> champion kills
		champTimes = {}, -- first hero hit -> death (sim seconds) of each rewarded kill
		firstChampKillAt = nil,
		champLog = {},
	}
end

-- Builds the stage's world and drops every squad at its corner (RunDirector.buildStage).
function Headless._buildStage(self: any, mapId: string)
	local match = self.match
	local stageSeed = match:stageSeed()
	-- v4: RunDirector's stage radius (Maps.stageRadius)
	local R = if type(Maps.stageRadius) == "function"
		then Maps.stageRadius(mapId, match.stage)
		else Pois.arenaRadius(mapId)
	local layout = if self.poisOn
		then Pois.layout(Rng.new(stageSeed):fork(Headless.POI_SALT), mapId, R, Pois.squadCorners(R))
		else nil
	local arena = Headless.arena(mapId, stageSeed, layout, R)
	local mapDef = Maps.get(mapId) :: any
	local world = World.new({
		rng = Rng.new(stageSeed):fork(self.stageIndex),
		mods = match:worldMods(),
		arenaRadius = arena.radius,
		obstacles = arena.obstacles,
		enemyPool = if mapDef and mapDef.enemyPool then mapDef.enemyPool else {},
		cycle = 1,
		stage = match.stage,
		safeZones = arena.corners,
	})
	self.world = world
	self.arenaInfo = arena
	world:setStage(1, match.stage)
	local bySquad: { [number]: number } = {}
	for _, m in self:inRun() do
		self:_computeStats(m)
		if m.ability and type(m.brain.setAbility) == "function" then
			m.brain:setAbility(m.ability) -- v4: BotService passes the equipped ability
		end
		local c = arena.corners[m.squad]
		local k = bySquad[m.squad] or 0
		bySquad[m.squad] = k + 1
		local a = k * (math.pi * 2 / 3)
		world:addPlayer(
			m.id,
			m.stats,
			m.weapon,
			m.ability,
			c.x + math.cos(a) * Headless.SPAWN_RING,
			c.z + math.sin(a) * Headless.SPAWN_RING,
			m.squad
		)
		if type(world.setHeroLevel) == "function" then
			world:setHeroLevel(m.id, m.level)
		end
		local wl = self.wallets[m.id]
		if wl and type(world.setRunMods) == "function" then
			world:setRunMods(m.id, RunWallet.deltas(wl, m.classId))
		end
		-- Gear lasts the whole run: hand it to the new world.
		local kept = {}
		for _, slot in GEAR_SLOTS do
			if m.gear[slot] then
				table.insert(kept, m.gear[slot])
			end
		end
		for _, item in kept do
			world:giveGear(m.id, item)
		end
		self:_syncGear(m)
		if #kept > 0 then
			self:_push(m)
		end
	end
	if layout then
		self.cur.pois = {}
		for _, entry in layout do
			world:addPoi(entry)
			table.insert(self.cur.pois, entry.kind)
		end
	end
	self.thinkAcc = Headless.THINK_INTERVAL -- BotService: think on the first frame
	-- v4 The Melt: the World follows Config/Storm (the schedule RunDirector drives)
	self.storm = nil
	if self.stormOn and type(world.setStormPlan) == "function" then
		world:setStormPlan({ radius = R, stage = match.stage, seed = stageSeed, duration = self.waveSeconds })
		local cx, cz = Storm.center(R, match.stage, stageSeed)
		self.storm = { R = R, cx = cx, cz = cz }
	end
end

-- Plays one stage. Returns "continue" | "results".
function Headless.playStage(self: any): string
	local match = self.match
	local opts = self.opts
	if match.phase == "Lobby" then
		match:begin()
	end
	local card = match:currentRoute()
	self.stageIndex += 1
	local bossId = opts.bossOverride or card.bossId
	local mapId = opts.mapOverride or card.mapId
	-- Portal pull from the previous stage (RunDirector.playStage).
	local oldWorld = self.world
	if oldWorld and oldWorld:portal() then
		local portal = oldWorld:portal()
		local mapDef0 = Maps.get(mapId) :: any
		oldWorld:setPortal(
			portal.x,
			portal.z,
			"pull",
			mapDef0 and mapDef0.accentColor or Headless.PORTAL_GOLD
		)
		self.phase = "Portal"
		local steps = math.floor(Headless.PORTAL_PULL_SECONDS / Headless.DT + 0.5)
		for _ = 1, steps do
			self:tick()
		end
		oldWorld:setPortal(portal.x, portal.z, "close")
	end
	local st = self:_newStageStats(card, mapId, bossId)
	self.cur = st
	table.insert(self.stages, st)
	self.buffs = {}
	self.downSince = {}
	for _, m in self.members do
		m.secondWindsThisStage = 0
		m.velX, m.velZ = 0, 0
		m.intent = { moveX = 0, moveZ = 0, speedFrac = 0 }
		m.downedAt = nil
	end
	-- v4: a lone squad gets a Rival Herd
	if match:needsRival() then
		self:_addRival()
	end
	self.v4.squadsAtStart[match.stage] = #match:squadsInRun()
	self:_buildStage(mapId)
	local world = self.world

	-- Waves.
	-- iteration 2 (RunDirector): 4 numbered horde waves (Run/Waves) with the Early
	-- Horn at the stand-in leader's setting (70; Off with opts.skipWaveAt = 0)
	self.phase = "Waves"
	local scale = self.waveSeconds / Waves.hordeSeconds()
	local heroes = #match:squadsInRun() * Squads.SIZE
	local ws = Waves.new(match.stage, self.now, heroes, nil, scale)
	self.waves = ws
	local skipAt = if self.opts.skipWaveAt ~= nil then self.opts.skipWaveAt else 70
	world:startWaves(self.waveSeconds)
	if type(world.startWave) == "function" then
		world:startWave(Waves.index(match.stage, 1), { stageWave = 1 })
	end
	self.waveEndsAt = self.now + self.waveSeconds
	local i = 0
	local maxSteps = math.floor(self.waveSeconds / Headless.DT + 0.5) + 10
	while i < maxSteps do
		i += 1
		self:tick()
		if i % 3 == 0 then
			self:_redeployTick()
			self:_sampleIdle() -- 10 Hz
			if Waves.canHorn(ws, self.now, skipAt) then
				local skipped = Waves.horn(ws, self.now)
				self.v4.horns = (self.v4.horns or 0) + 1
				for _, s2 in match:squadsInRun() do
					for _, id in match:activeMembers(s2) do
						self:_earn(id, math.floor(skipped * Waves.HORN_RINDS))
					end
				end
			end
			local ev = Waves.tick(ws, self.now, heroes)
			if ev == "wave" and type(world.startWave) == "function" then
				world:startWave(Waves.index(match.stage, ws.wave), { stageWave = ws.wave })
			elseif ev == "boss" then
				break
			end
		end
		if self:_stageOver() then
			st.waveTime = i * Headless.DT
			st.outcome = "over"
			self.phase = "Results"
			return "results"
		end
	end
	self.waves = nil
	st.waveTime = i * Headless.DT

	-- Boss at the centre.
	self.phase = "Boss"
	world:stopSpawning()
	world:clearEnemies()
	match:startBoss()
	match:cancelRedeploys()
	self.waveEndsAt = nil
	self.bossDead = false
	self.bossKill = nil
	self.bossSpawnAt = self.now
	local bx, bz = 0, 0
	if self.storm then
		bx, bz = self.storm.cx, self.storm.cz -- v4: the boss ring is the last circle
	end
	world:spawnBoss(bossId, bx, bz)
	local timedOut = false
	while true do
		self:tick()
		if self:_stageOver() then
			st.outcome = "over"
			self.phase = "Results"
			return "results"
		end
		if self.bossDead then
			break
		end
		local elapsed = self.now - self.bossSpawnAt
		if elapsed >= Headless.BOSS_FALLBACK_DELAY and not world:bossAlive() then
			st.bossFallback = true
			st.bossTime = elapsed
			break
		end
		if elapsed >= self.bossSeconds then
			timedOut = true
			st.bossTimeout = true
			st.bossTime = elapsed
			break
		end
	end
	local killerSquad, damage = nil, nil
	if self.bossKill and not timedOut then
		killerSquad = if Squads.isValid(self.bossKill.killerSquad) then self.bossKill.killerSquad else nil
		damage = self.bossKill.damageBySquad
	end
	if damage == nil or timedOut then
		local d, top = world:bossDamageBySquad()
		damage = if next(d) == nil and Squads.isValid(top) then { [top] = 1 } else d
	end
	world:clearEnemies()

	-- Stage clear.
	self.phase = "StageClear"
	local result = match:bossDefeated(killerSquad, damage, timedOut)
	st.result = result
	self:_earnSplit(damage, RunWallet.rindsFor("boss", match.stage), nil, nil)
	for _, s2 in match:squadsInRun() do
		for _, id in match:activeMembers(s2) do
			local info = world:getPlayer(id)
			if info and not info.downed and not info.dead then
				self:_earn(id, nil, RunWallet.Shop.WHEY.stage)
			end
		end
	end
	for _ in result.potBonus do
		self.v4.donPaid += 1
	end
	for _ in result.potLost or {} do
		self.v4.donLost += 1
	end
	st.winner, st.winnerBy = result.winner, result.winnerBy
	self.bossesKilled += 1
	if result.winner then
		for _, id in match:activeMembers(result.winner) do
			local m = self.byId[id]
			for _, item in Gear.bossChest(self.gearRng, result.tier, match.stage) do
				world:giveGear(id, item)
			end
			self:_syncGear(m)
		end
	end
	for _, s in match:squadsInRun() do
		self:_refreshSquad(s) -- blessings, chest gear
	end
	if result.finished then
		self.phase = "Results"
		return "results"
	end
	world:setPortal(0, 0, "open", Headless.PORTAL_GOLD)
	if self:_stepFor(Headless.STAGE_CLEAR_SECONDS) then
		self.phase = "Results"
		return "results"
	end

	-- Route choice by the winner.
	self.phase = "RouteChoice"
	st.routeChooser = match:routeChooser()
	local idx = self:_routeChoice(result.winner)
	if result.winner and self:_stepFor(Headless.VOTE_SECONDS) then
		self.phase = "Results"
		return "results"
	end
	local chosen = match:chooseRoute(idx, result.winner)
	table.insert(self.routeTiers, chosen.tier)

	-- Extraction window (the world keeps running while squads decide).
	self.phase = "Extraction"
	if self:_stepFor(Headless.VOTE_SECONDS) then
		self.phase = "Results"
		return "results"
	end
	local choices = self:_extractChoices()
	st.choices = choices
	-- RunDirector.eliminateFallen: a squad with nobody standing at the gate is
	-- eliminated (bags drop) before the choices resolve, so it can never Extract.
	self:_eliminateFallen()
	if match.phase ~= "Extraction" then
		self.phase = "Results"
		return "results"
	end
	local res = match:resolveExtraction(choices)
	st.extracted = res.extracted
	for _, id in res.out do
		world:removePlayer(id) -- RunDirector.handleOut(removeHeroes = true)
	end
	if res.finished or match.phase == "Results" then
		self.phase = "Results"
		return "results"
	end
	if match:humansInRun() == 0 then
		match:finish("noHumans")
		self.phase = "Results"
		return "results"
	end
	return "continue"
end

-- Plays until Results or opts.maxStages. outcome (the first human's view):
-- "Win" (extracted / Last Herd Standing) | "Wipe" (eliminated) | "Left" |
-- "Unfinished" | "MaxStages".
function Headless.playRun(self: any): any
	local outcome = nil
	while true do
		local r = self:playStage()
		if r == "results" then
			break
		end
		if self.opts.maxStages and self.stageIndex >= self.opts.maxStages then
			outcome = "MaxStages"
			break
		end
	end
	local match = self.match
	local payouts = {}
	local levels = {}
	for _, m in self.members do
		payouts[m.id] = match:payout(m.id)
		levels[m.id] = m.level
	end
	local human = self.human
	local po = if human then payouts[human.id] else nil
	if outcome == nil then
		if po and po.extracted then
			outcome = "Win"
		elseif po and po.result == "eliminated" then
			outcome = "Wipe"
		elseif po and po.result == "left" then
			outcome = "Left"
		else
			outcome = "Unfinished"
		end
	end
	local squads = {}
	for s = 1, Squads.MAX do
		local sq = match:squad(s)
		squads[s] = {
			id = s,
			outReason = sq.outReason,
			outAtStage = sq.outAtStage,
			extracted = sq.extracted,
			eliminated = sq.eliminated,
			kills = sq.kills,
			pvpDowns = self.pvpBySquad[s].downs,
			pvpKills = self.pvpBySquad[s].kills,
			humans = #self:humansOfSeat(s),
			placement = match:placement(s),
		}
	end
	return {
		outcome = outcome,
		endReason = match.endReason,
		humanId = if human then human.id else nil,
		humanSquad = if human then human.squad else nil,
		payout = po,
		payouts = payouts,
		squads = squads,
		stages = self.stages,
		levels = levels,
		bossesKilled = self.bossesKilled,
		totals = self.totals,
		simSeconds = self.now - Headless.T0,
		v4 = self.v4,
		routeTiers = self.routeTiers,
		rindsEarned = if human and self.wallets[human.id] then self.wallets[human.id].rindsEarned else 0,
		wheyEarned = if human and self.wallets[human.id] then self.wallets[human.id].wheyEarned else 0,
	}
end

-- Humans seated in a squad (in the run or not).
function Headless.humansOfSeat(self: any, squad: number): { any }
	local out = {}
	for _, m in self.members do
		if not m.isBot and m.squad == squad then
			table.insert(out, m)
		end
	end
	return out
end

-- A short, stable text digest of a match result (determinism checks).
function Headless.digest(result: any): string
	local parts = { tostring(result.outcome), tostring(result.endReason) }
	for _, s in result.stages do
		table.insert(
			parts,
			string.format(
				"%s/%s/%s/%s/%.4f/%.4f/%d/%.4f/%d/%d/%d/%s/%d",
				s.mapId,
				s.bossId,
				s.tier,
				s.outcome,
				s.waveTime,
				s.bossTime or -1,
				s.levelsGained,
				s.damageTaken,
				s.downs,
				s.kills,
				s.enemyPeak,
				tostring(s.winner),
				s.pvpDowns
			)
		)
	end
	local ids = {}
	for id in result.payouts do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local p = result.payouts[id]
		table.insert(parts, string.format("%d=%d/%s/%d", id, p.cheese, p.result, result.levels[id]))
	end
	return table.concat(parts, "|")
end

function Headless.formatStage(s: StageStats): string
	local ex = {}
	for q, c in s.choices do
		table.insert(ex, q .. ":" .. string.sub(c, 1, 2))
	end
	table.sort(ex)
	local at = {}
	for _, t in s.eliminatedAt do
		table.insert(at, string.format("%.0f", t))
	end
	return string.format(
		"  st%d %-8s %-18s %-4s %-5s boss %6s s%s  lvl+%-3d downs %2d (pvp %2d, 1st @%s s) kills(pvp) %d  bags %d/%d  gear %2d  winner %s  elim [%s @ %s s]  extract [%s]",
		s.stage,
		s.mapId,
		s.bossId,
		s.tier,
		s.outcome,
		if s.bossTime then string.format("%.1f", s.bossTime) else "-",
		if s.bossTimeout then "(t/o)" else "     ",
		s.levelsGained,
		s.downs,
		s.pvpDowns,
		if s.firstPvpDownAt then string.format("%.0f", s.firstPvpDownAt) else "-",
		s.pvpKills,
		s.bags,
		s.bagsClaimed,
		s.gear,
		tostring(s.winner),
		table.concat(s.eliminated, ","),
		table.concat(at, ","),
		table.concat(ex, " ")
	)
end

return Headless
