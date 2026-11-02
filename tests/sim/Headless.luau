--!strict
-- Headless game driver (Testing team). Plays whole runs with only the pure
-- modules in src/shared, mirroring src/server/Services/RunDirector.luau (stage
-- loop, votes, xp -> level-ups -> upgrade picks, wipe grace, boss fallback,
-- rewards) and src/server/Services/BotService.luau (BotBrain think every 0.1 s,
-- smoothed steering, obstacle push-out, arena clamp, ability casts).
--
--   local sim = Headless.new({ seed = 7, party = { {classId = "ele_fonte", isBot = true}, ... } })
--   local result = sim:playRun()      -- or sim:playStage() for one stage
--
-- Humans are modelled as BotBrains with positive ids (1001, 1002, ...) that the
-- other bots treat as humans (leash, vote following). A "human" also presses
-- Second Wind about 1 s after going down (free one per run, 1 per stage), and
-- moves at x0.6 while slowed (CombatService applies that to real characters).
--
-- Differences from the live server, on purpose:
--   * Time is simulated: the world steps at exactly 1/30 s.
--   * Votes resolve instantly (no 15 s timer); humans pick upgrades instantly.
--   * The arena is a pure replica of ArenaBuilder's layout rules (radius =
--     map size, boss pad, spawn clearing, obstacle spacing), not the exact parts.
--   * A boss that is still alive BOSS_LIMIT sim-seconds after it spawned ends
--     the run with outcome "Timeout" (the live server would wait forever).

local Rng = require("../../src/shared/Util/Rng")
local RunState = require("../../src/shared/Run/RunState")
local Vote = require("../../src/shared/Run/Vote")
local Stats = require("../../src/shared/Run/Stats")
local Leveling = require("../../src/shared/Run/Leveling")
local UpgradeOffers = require("../../src/shared/Run/UpgradeOffers")
local World = require("../../src/shared/Combat/World")
local Bosses = require("../../src/shared/Config/Bosses")
local Maps = require("../../src/shared/Config/Maps")
local BotBrain = require("../../src/shared/Bots/BotBrain")
local Ids = require("../../src/shared/Util/Ids")

local Headless = {}
Headless.__index = Headless

-- RunDirector / BotService / ArenaBuilder constants (copied; asserted where exported).
Headless.DT = 1 / 30
Headless.WAVE_SECONDS = 150
Headless.BOSS_LIMIT = 360 -- 6 sim-minutes per boss
Headless.STAGE_CLEAR_SECONDS = 4
Headless.VOTE_SECONDS = 3 -- world keeps stepping while bots vote (1-4 s)
Headless.WIPE_GRACE = 1.5
Headless.WIPE_GRACE_SECOND_WIND = 5
Headless.BOSS_FALLBACK_DELAY = 6
Headless.RESPAWN_HP_FRAC = 0.5
Headless.OFFER_CARDS = 3
Headless.BOT_WEIGHT = World.BOT_WEIGHT
Headless.BOT_LEVELS_PER_EVENT = 10 -- RunDirector.grantBotXp caps level-ups per xp event
Headless.THINK_INTERVAL = 0.1
Headless.ACCEL = 10
Headless.PICKUP_SCAN = 20
Headless.PLAYER_RADIUS = World.PLAYER_RADIUS
Headless.HUMAN_SECOND_WIND_DELAY = 1.0
Headless.T0 = 1000 -- sim clock start (like GetServerTimeNow, never 0)
Headless.BOSS_PAD_RADIUS = 14
Headless.SPAWN_CLEAR = 12
Headless.HUMAN_ID0 = 1000

export type PartySpec = { classId: string, isBot: boolean? }

export type Options = {
	seed: number,
	party: { PartySpec },
	waveSeconds: number?,
	bossLimit: number?,
	bossOverride: string?, -- every stage fights this boss
	mapOverride: string?, -- every stage uses this map
	-- Forced choices (simulate unanimous humans). Return nil to let the party vote.
	routePolicy: ((cards: { any }, sim: any) -> number?)?,
	bankPolicy: ((kind: string, options: { string }, sim: any) -> string?)?,
	humanSecondWind: boolean?, -- default true
	maxStages: number?, -- stop after this many stages (outcome "MaxStages")
	stopAtCycleVote: boolean?, -- default true: stop when the run reaches CycleVote
	onTick: ((sim: any, phase: string) -> ())?, -- test hook, called before each world step
	playerCount: number?, -- override the difficulty party size
	humanIds: { number }?, -- e.g. Studio test players {-1, -2}; default 1001, 1002, ...
}

export type StageStats = {
	index: number,
	cycle: number,
	stageInCycle: number,
	mapId: string,
	bossId: string,
	tier: string,
	outcome: string, -- "clear" | "wipe" | "timeout"
	waveTime: number,
	bossTime: number?, -- boss spawn -> bossDead (sim seconds)
	bossFallback: boolean,
	levelsGained: number,
	levelsBy: { [number]: number },
	damageTaken: number,
	downs: number,
	deaths: number,
	revives: number,
	secondWinds: number,
	kills: number,
	enemyPeak: number,
	reward: any?,
	bankChoice: string?,
	pendingAfter: number,
	bankedAfter: number,
	phase2At: number?,
}

-- Pure replica of ArenaBuilder.build's layout rules (obstacle circles + spawn).
function Headless.arena(
	mapId: string,
	seed: number
): { radius: number, obstacles: { any }, spawnX: number, spawnZ: number }
	local def = Maps.get(mapId) :: any
	local R = if def and type(def.size) == "number" and def.size >= 40 then def.size else 120
	local want = if def and type(def.obstacleCount) == "number" then def.obstacleCount else 18
	local rng = Rng.new(seed):fork(77)
	local spawnX, spawnZ = 0, math.min(R * 0.3, Headless.BOSS_PAD_RADIUS + 14)
	local obstacles = {}
	local function free(x: number, z: number, r: number): boolean
		if x * x + z * z < (Headless.BOSS_PAD_RADIUS + r + 6) ^ 2 then
			return false
		end
		if x * x + z * z > (R - r - 7) ^ 2 then
			return false
		end
		if (x - spawnX) ^ 2 + (z - spawnZ) ^ 2 < (Headless.SPAWN_CLEAR + r) ^ 2 then
			return false
		end
		for _, o in obstacles do
			if (x - o.x) ^ 2 + (z - o.z) ^ 2 < (o.r + r + 7) ^ 2 then
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
	return { radius = R, obstacles = obstacles, spawnX = spawnX, spawnZ = spawnZ }
end

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function Headless.new(opts: Options): any
	assert(#opts.party > 0, "Headless.new: empty party")
	local self = setmetatable({}, Headless) :: any
	self.opts = opts
	self.seed = opts.seed
	self.waveSeconds = opts.waveSeconds or Headless.WAVE_SECONDS
	self.bossLimit = opts.bossLimit or Headless.BOSS_LIMIT

	local humans, bots = {}, {}
	for _, spec in opts.party do
		if spec.isBot then
			table.insert(bots, spec)
		else
			table.insert(humans, spec)
		end
	end
	-- RunDirector: fractional party size humans + 0.6 x bots (RunState.partySize clamps it).
	local count = opts.playerCount or RunState.partySize(#humans + Headless.BOT_WEIGHT * #bots)
	self.playerCount = count

	local rng = Rng.new(opts.seed)
	self.run = RunState.new(opts.seed, count, { bossIds = Bosses.ORDER, mapIds = Maps.ORDER })
	-- Same fork order as RunDirector.startRun: bot offer rngs, voteRng, botRng, human offer rngs.
	local botOfferRngs = {}
	for i = 1, #bots do
		botOfferRngs[i] = rng:fork(200 + i)
	end
	self.voteRng = rng:fork(1)
	self.botRng = rng:fork(2)
	self.humanVoteRng = rng:fork(3) -- the humans' own vote choices (clients in reality)
	local brainRoot = rng:fork(4)

	self.members = {}
	local slot = 0
	for i, spec in humans do
		slot += 1
		local id = if opts.humanIds and opts.humanIds[i] then opts.humanIds[i] else Headless.HUMAN_ID0 + i
		table.insert(self.members, {
			id = id,
			classId = spec.classId,
			isBot = false,
			slot = slot,
			offerRng = rng:fork(100 + slot),
		})
	end
	for i, spec in bots do
		slot += 1
		table.insert(self.members, {
			id = Ids.botId(i), -- -1001, -1002, ... (Util/Ids)
			classId = spec.classId,
			isBot = true,
			slot = slot,
			offerRng = botOfferRngs[i],
		})
	end
	for i, m in self.members do
		m.level = 1
		m.xp = 0
		m.stacks = {}
		m.brain = BotBrain.new(m.id, m.classId, brainRoot:fork(1000 + i))
		m.intent = { moveX = 0, moveZ = 0, speedFrac = 0 }
		m.velX, m.velZ = 0, 0
		m.freeSecondWindUsed = false
		m.secondWindsThisStage = 0
		m.downedAt = nil
		m.picks = {}
	end
	self.byId = {}
	for _, m in self.members do
		self.byId[m.id] = m
	end

	self.now = Headless.T0
	self.stageIndex = 0
	self.stages = {}
	self.world = nil
	self.phase = "Lobby"
	self.thinkAcc = 0
	self.downSince = nil
	self.bossDead = false
	self.bossesKilled = 0
	return self
end

-- Stats / upgrades ----------------------------------------------------------------------

function Headless._computeStats(self: any, m: any)
	m.stats, m.weapon, m.ability = Stats.compute(m.classId, m.stacks, self.run:activeBlessings(), {}, nil)
end

function Headless._levelUp(self: any, m: any)
	local luck = if m.stats and finite(m.stats.luck) then m.stats.luck else 0
	local cards = UpgradeOffers.roll(m.offerRng, m.classId, m.stacks, luck, Headless.OFFER_CARDS)
	if #cards == 0 then
		return
	end
	local idx = BotBrain.chooseUpgrade(cards, self.botRng)
	local card = cards[idx]
	if not card then
		return
	end
	m.stacks[card.id] = (m.stacks[card.id] or 0) + 1
	table.insert(m.picks, card.id)
	self:_computeStats(m)
	local world = self.world
	if world then
		world:updatePlayer(m.id, m.stats, m.weapon)
		local heal = card.delta and card.delta.heal
		if finite(heal) and heal > 0 then
			world:healPlayer(m.id, heal)
		end
	end
end

function Headless._grantXp(self: any, m: any, amount: any)
	if not finite(amount) or amount <= 0 then
		return
	end
	local newLevel, newXp, gained = Leveling.addXp(m.level, m.xp, amount)
	m.level, m.xp = newLevel, newXp
	local st = self.cur
	if st and gained > 0 then
		st.levelsGained += gained
		st.levelsBy[m.id] = (st.levelsBy[m.id] or 0) + gained
	end
	local n = if m.isBot then math.min(gained, Headless.BOT_LEVELS_PER_EVENT) else gained
	for _ = 1, n do
		self:_levelUp(m)
	end
end

-- Votes ----------------------------------------------------------------------------------------

-- Humans vote (BotBrain.chooseVote with no tally = the safe option, sometimes the
-- next one), bots follow the human plurality, Vote.resolve breaks ties.
function Headless._vote(self: any, kind: string, options: { any }, default: number): number
	local voters = {}
	for _, m in self.members do
		table.insert(voters, m.id)
	end
	local vote = Vote.new(#options, voters)
	local tally = table.create(#options, 0)
	for _, m in self.members do
		if not m.isBot then
			local i = BotBrain.chooseVote(kind, options, {}, self.humanVoteRng)
			vote:cast(m.id, i)
			tally[i] += 1
		end
	end
	for _, m in self.members do
		if m.isBot then
			vote:cast(m.id, BotBrain.chooseVote(kind, options, tally, self.botRng))
		end
	end
	-- Risky options (Double or Nothing / Next Cycle) only win with a human vote, as in RunDirector.
	return vote:resolve(self.voteRng, default, Vote.riskyIndices(options))
end

-- Per-tick driving (BotService.stepBots) -------------------------------------------------------------

function Headless._allies(self: any): { any }
	local list = {}
	for id, p in self.world:getPlayers() do
		if not p.dead and finite(p.x) and finite(p.z) then
			table.insert(list, { id = id, x = p.x, z = p.z, downed = p.downed == true, isBot = p.isBot })
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
	local enemies, allies
	if think then
		enemies = world:snapshot()
		allies = self:_allies()
	end
	local alpha = 1 - math.exp(-Headless.ACCEL * dt)
	local radius = world.arenaRadius
	for _, m in self.members do
		local info = world:getPlayer(m.id)
		if not info then
			continue
		end
		local x, z = info.x, info.z
		if think then
			local view = {
				self = {
					x = x,
					z = z,
					hp = info.hp,
					maxHp = info.maxHp,
					downed = info.downed == true,
					abilityReady = now >= (info.abilityReadyAt or 0),
				},
				allies = allies,
				enemies = enemies,
				pickups = world:pickupsNear(x, z, Headless.PICKUP_SCAN),
				arenaRadius = radius,
				obstacles = world.obstacles,
				now = now,
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
		local speed = if finite(info.moveSpeed) then info.moveSpeed else 16
		if info.downed then
			speed *= World.DOWNED_SPEED
		elseif info.slowed then
			speed *= World.PLAYER_SLOW -- CombatService (humans) and BotService (bots)
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

function Headless._handleEvents(self: any)
	local st = self.cur
	for _, e in self.world:drainEvents() do
		local kind = e.type
		local m = if e.id ~= nil then self.byId[e.id] else nil
		if kind == "xp" then
			if m then
				self:_grantXp(m, e.amount)
			end
		elseif kind == "damaged" then
			st.damageTaken += e.amount or 0
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
		elseif kind == "bossDead" then
			if not self.bossDead then
				self.bossDead = true
				st.bossTime = self.now - self.bossSpawnAt
			end
		elseif kind == "bossPhase" then
			st.phase2At = st.phase2At or (self.now - (self.bossSpawnAt or self.now))
		end
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
	world:step(dt, self.now)
	world:drainTeleports()
	self:_handleEvents()
	local n = world:enemyCount()
	if n > self.cur.enemyPeak then
		self.cur.enemyPeak = n
	end
end

-- RunDirector.wipeCheck: everyone down for WIPE_GRACE (5 s if a human can still Second Wind).
function Headless._wipeCheck(self: any): boolean
	local world = self.world
	if world:allPlayersDown() then
		self.downSince = self.downSince or self.now
		local grace = Headless.WIPE_GRACE
		if self.opts.humanSecondWind ~= false then
			for _, m in self.members do
				if not m.isBot and not m.freeSecondWindUsed and m.secondWindsThisStage < 1 then
					local info = world:getPlayer(m.id)
					if info and info.downed and not info.dead and not info.secondWindUsed then
						grace = Headless.WIPE_GRACE_SECOND_WIND
					end
				end
			end
		end
		return self.now - self.downSince >= grace
	end
	self.downSince = nil
	return false
end

function Headless._stepFor(self: any, seconds: number)
	local steps = math.floor(seconds / Headless.DT + 0.5)
	for _ = 1, steps do
		self:tick()
	end
end

-- Stage ---------------------------------------------------------------------------------------------

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

-- Plays one stage. Returns "continue" | "results" | "cyclevote" | "timeout".
function Headless.playStage(self: any): string
	local run = self.run
	local opts = self.opts
	self.phase = "RouteVote"
	local cards = run:openRouteVote()
	local idx = (opts.routePolicy and opts.routePolicy(cards, self))
		or self:_vote("route", cards, defaultRouteIndex(cards))
	local card = run:chooseRoute(idx)
	self.stageIndex += 1
	local bossId = opts.bossOverride or card.bossId
	local mapId = opts.mapOverride or card.mapId
	local pub = run:getPublic()
	local st: StageStats = {
		index = self.stageIndex,
		cycle = pub.cycle,
		stageInCycle = pub.stageInCycle,
		mapId = mapId,
		bossId = bossId,
		tier = card.tier,
		outcome = "clear",
		waveTime = 0,
		bossTime = nil,
		bossFallback = false,
		levelsGained = 0,
		levelsBy = {},
		damageTaken = 0,
		downs = 0,
		deaths = 0,
		revives = 0,
		secondWinds = 0,
		kills = 0,
		enemyPeak = 0,
		reward = nil,
		bankChoice = nil,
		pendingAfter = 0,
		bankedAfter = 0,
		phase2At = nil,
	}
	self.cur = st
	table.insert(self.stages, st)
	for _, m in self.members do
		m.secondWindsThisStage = 0
		m.velX, m.velZ = 0, 0
		m.intent = { moveX = 0, moveZ = 0, speedFrac = 0 }
		m.downedAt = nil
	end

	-- Arena + world (RunDirector step 3).
	local stageSeed = run:getStageSeed()
	local arena = Headless.arena(mapId, stageSeed)
	local mapDef = Maps.get(mapId) :: any
	local world = World.new({
		rng = Rng.new(stageSeed):fork(self.stageIndex),
		mods = run:worldMods(),
		arenaRadius = arena.radius,
		obstacles = arena.obstacles,
		enemyPool = if mapDef and mapDef.enemyPool then mapDef.enemyPool else {},
		cycle = pub.cycle,
		stage = pub.stageInCycle,
	})
	self.world = world
	self.arenaInfo = arena
	world:setStage(pub.cycle, pub.stageInCycle)
	local n = math.max(1, #self.members)
	for _, m in self.members do
		self:_computeStats(m)
		local angle = (m.slot - 1) * (math.pi * 2 / n)
		local r = if n > 1 then 4 else 0
		world:addPlayer(
			m.id,
			m.stats,
			m.weapon,
			m.ability,
			arena.spawnX + math.cos(angle) * r,
			arena.spawnZ + math.sin(angle) * r
		)
	end
	self.thinkAcc = Headless.THINK_INTERVAL -- BotService.setWorld: think on the first frame

	-- Waves.
	self.phase = "Waves"
	world:startWaves(self.waveSeconds)
	self.downSince = nil
	local steps = math.floor(self.waveSeconds / Headless.DT + 0.5)
	for i = 1, steps do
		self:tick()
		if self:_wipeCheck() then
			st.waveTime = i * Headless.DT
			st.outcome = "wipe"
			run:wipe()
			self.phase = "Results"
			return "results"
		end
	end
	st.waveTime = self.waveSeconds

	-- Boss.
	self.phase = "Boss"
	world:stopSpawning()
	world:clearEnemies()
	run:startBoss()
	self.bossDead = false
	self.bossSpawnAt = self.now
	local bx, bz = world:bossSpawnPoint(Bosses.get(bossId).radius)
	world:spawnBoss(bossId, bx, bz)
	while true do
		self:tick()
		if self:_wipeCheck() then
			st.outcome = "wipe"
			run:wipe()
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
		if elapsed >= self.bossLimit then
			st.outcome = "timeout"
			self.phase = "Timeout"
			return "timeout"
		end
	end

	-- Stage clear (RunDirector step 6).
	self.phase = "StageClear"
	st.reward = run:bossDefeated()
	self.bossesKilled += 1
	world:clearEnemies()
	world:respawnDead(Headless.RESPAWN_HP_FRAC)
	for _, m in self.members do
		self:_computeStats(m)
		world:updatePlayer(m.id, m.stats, m.weapon)
	end
	self:_stepFor(Headless.STAGE_CLEAR_SECONDS)

	-- Bank / cycle vote.
	local bank = run:openBankVote()
	self.phase = run.phase
	self:_stepFor(Headless.VOTE_SECONDS)
	if bank.kind == "cycle" and opts.stopAtCycleVote ~= false and not opts.bankPolicy then
		st.pendingAfter = run.pendingCheese
		st.bankedAfter = run.bankedCheese
		return "cyclevote"
	end
	local forced = opts.bankPolicy and opts.bankPolicy(bank.kind, bank.options, self)
	local choice = forced or bank.options[self:_vote(bank.kind, bank.options, defaultBankIndex(bank.options))]
	st.bankChoice = choice
	run:chooseBank(choice)
	st.pendingAfter = run.pendingCheese
	st.bankedAfter = run.bankedCheese
	if run.phase == "Results" then
		self.phase = "Results"
		return "results"
	end
	return "continue"
end

-- Plays until Results, CycleVote (default), a timeout or opts.maxStages.
-- outcome: "CycleVote" | "Win" | "Wipe" | "Timeout" | "MaxStages".
function Headless.playRun(self: any): any
	local outcome
	while true do
		local r = self:playStage()
		if r == "results" then
			outcome = self.run.outcome or "Wipe"
			break
		elseif r == "cyclevote" then
			outcome = "CycleVote"
			break
		elseif r == "timeout" then
			outcome = "Timeout"
			break
		end
		if self.opts.maxStages and self.stageIndex >= self.opts.maxStages then
			outcome = "MaxStages"
			break
		end
	end
	local final = if self.run.phase == "Results" then self.run:finalRewards() else nil
	local levels = {}
	for _, m in self.members do
		levels[m.id] = m.level
	end
	return {
		outcome = outcome,
		stages = self.stages,
		final = final,
		levels = levels,
		pending = self.run.pendingCheese,
		banked = self.run.bankedCheese,
		bossesKilled = self.bossesKilled,
		simSeconds = self.now - Headless.T0,
	}
end

-- A short, stable text digest of a run result (determinism checks).
function Headless.digest(result: any): string
	local parts = { tostring(result.outcome), tostring(result.pending), tostring(result.banked) }
	for _, s in result.stages do
		table.insert(
			parts,
			string.format(
				"%s/%s/%s/%s/%.4f/%.4f/%d/%.4f/%d/%d/%d/%s",
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
				tostring(s.bankChoice)
			)
		)
	end
	local ids = {}
	for id in result.levels do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		table.insert(parts, tostring(id) .. "=" .. tostring(result.levels[id]))
	end
	return table.concat(parts, "|")
end

function Headless.formatStage(s: StageStats): string
	return string.format(
		"  %d-%d %-8s %-18s %-4s %-7s boss %6s s  lvl+%-3d dmg %6.0f  downs %d deaths %d  peak %3d  kills %4d  bank %s",
		s.cycle,
		s.stageInCycle,
		s.mapId,
		s.bossId,
		s.tier,
		s.outcome,
		if s.bossTime then string.format("%.1f", s.bossTime) else "-",
		s.levelsGained,
		s.damageTaken,
		s.downs,
		s.deaths,
		s.enemyPeak,
		s.kills,
		tostring(s.bankChoice)
	)
end

return Headless
