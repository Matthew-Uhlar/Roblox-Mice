--!strict
-- Spawn budget + spawn placement for the horde phase. Pure: World owns one and asks
-- it every step for spawn requests.
--
-- Budget (spawns/s) = BASE_RATE * ramp(progress) * cycleScale * stageScale * playerScale
--                     * mods.spawnRateMult
--   ramp(p)      = 1 + RAMP_GAIN * p^1.4      (p = elapsed / duration, held at 1 after)
--   cycleScale   = 1 + 0.35 * (cycle - 1)
--   stageScale   = 1 + 0.12 * (stage - 1)
--   playerScale  = 1 + PLAYER_SCALE * (party - 1)   (party may be fractional: bots = 0.6)
-- Note: Stats.worldMods already folds party size into mods.spawnRateMult, so
-- PLAYER_SCALE here is small; it mostly tracks live changes (downs, leavers).
-- Spawns come in small clusters on a ring just outside the view of a random standing
-- player, never inside an obstacle or past the arena edge, and never within view of
-- any other standing player when the arena allows it. A periodic "surge" closes a
-- full ring around one player. Live enemies never exceed `cap`.
--
-- v4 per-hero spawning (docs/V4-PLAN.md "Mouse spawning", V4-A H2; the default):
--   rate = PER_HERO_RATE (0.9/s) x heroes x ramp(1 -> PER_HERO_RAMP 3.2)
--          x cycleScale x stageScale x mods.spawnRateMult
--   heroes = standing heroes (bots count 1). Live mice stay under
--   min(cap, PER_HERO_CAP x heroes): a soft cap of 28 per hero, the World's global
--   cap is 300. Spawn anchors prefer heroes with few mice on screen (`nearMice`,
--   set by World), and a stage starts with START_PER_HERO mice per hero banked.
--   With a storm (World.setZone) no spawn lands outside the current circle.
-- Pass perHero = false for the v1-v3 per-server budget (BASE_RATE, PLAYER_SCALE).

local Types = require("../Types")
local Rng = require("../Util/Rng")
local Enemies = require("../Config/Enemies")
local Pressure = require("../Config/Pressure")

type Rng = Rng.Rng
type WorldMods = Types.WorldMods

export type Obstacle = { x: number, z: number, r: number }
export type SpawnRequest = { id: string, x: number, z: number, elite: boolean, surge: boolean? }
export type Pos = { x: number, z: number }

local WaveDirector = {}
WaveDirector.__index = WaveDirector

WaveDirector.BASE_RATE = 1.5
WaveDirector.RAMP_GAIN = 3.2
WaveDirector.DEFAULT_CAP = 220
WaveDirector.VIEW_RADIUS = 48 -- studs from a player to the edge of their screen (top-down camera)
WaveDirector.EDGE_MARGIN = 3
WaveDirector.OBSTACLE_MARGIN = 2
WaveDirector.SURGE_EVERY = 35
WaveDirector.SURGE_FIRST = 25
WaveDirector.PLAYER_SCALE = 0.3
WaveDirector.MAX_BANKED = 12 -- budget never banks more than this while capped
WaveDirector.PER_HERO_RATE = 0.6 -- v4: spawns/s per standing hero at the start (plan 0.9; 0.6 after v4-report)...
WaveDirector.PER_HERO_RAMP = 3.2 -- ...ramping to this multiple by the end
WaveDirector.PER_HERO_CAP = 28 -- v4 soft cap: live mice per standing hero
WaveDirector.START_PER_HERO = 2 -- v4: banked at the start per hero (the first seconds are not empty)
WaveDirector.DENSITY_MAX = 14 -- v4: anchors prefer heroes with fewer mice than this within VIEW_RADIUS
WaveDirector.ZONE_MARGIN = 4 -- v4: spawns stay this far inside the storm circle

-- Mix: weight and unlock point (fraction of wave duration). Earlier on later stages/cycles.
WaveDirector.MIX = {
	mouse = { weight = 10, unlock = 0 },
	rat_runner = { weight = 4, unlock = 0.1 },
	crumb_slinger = { weight = 3, unlock = 0.2 },
	fuse_mouse = { weight = 2.5, unlock = 0.3 },
	chonk = { weight = 2, unlock = 0.35 },
} :: { [string]: { weight: number, unlock: number } }

export type Options = {
	rng: Rng,
	enemyPool: { string }?,
	cycle: number?,
	stage: number?,
	mods: WorldMods,
	cap: number?,
	arenaRadius: number,
	obstacles: { Obstacle }?,
	viewRadius: number?,
	perHero: boolean?, -- v4 (default true)
}

export type WaveDirector = typeof(setmetatable(
	{} :: {
		rng: Rng,
		pool: { string },
		cycle: number,
		stage: number,
		mods: WorldMods,
		cap: number,
		arenaRadius: number,
		obstacles: { Obstacle },
		viewRadius: number,
		active: boolean,
		duration: number,
		elapsed: number,
		budget: number,
		nextSurge: number,
		spawned: number,
		perHero: boolean,
		seeded: boolean,
		zoneCircle: { cx: number, cz: number, r: number }?,
	},
	WaveDirector
))

function WaveDirector.new(opts: Options): WaveDirector
	local pool: { string } = {}
	for _, id in opts.enemyPool or {} do
		if Enemies.get(id) then
			table.insert(pool, id)
		end
	end
	if #pool == 0 then
		pool = { "mouse", "rat_runner" }
	end
	return setmetatable({
		rng = opts.rng,
		pool = pool,
		cycle = math.max(1, opts.cycle or 1),
		stage = math.max(1, opts.stage or 1),
		mods = opts.mods,
		cap = opts.cap or WaveDirector.DEFAULT_CAP,
		arenaRadius = opts.arenaRadius,
		obstacles = opts.obstacles or {},
		viewRadius = opts.viewRadius or WaveDirector.VIEW_RADIUS,
		active = false,
		duration = 150,
		elapsed = 0,
		budget = 0,
		nextSurge = WaveDirector.SURGE_FIRST,
		spawned = 0,
		perHero = opts.perHero ~= false,
		seeded = false,
		zoneCircle = nil,
	}, WaveDirector)
end

function WaveDirector.start(self: WaveDirector, duration: number)
	self.active = true
	self.duration = math.max(1, duration)
	self.elapsed = 0
	self.budget = 2 -- a couple of mice right away so the first kill comes fast
	self.seeded = false
	self.nextSurge = math.min(WaveDirector.SURGE_FIRST, self.duration * 0.3)
end

function WaveDirector.stop(self: WaveDirector)
	self.active = false
	self.budget = 0
end

function WaveDirector.setMods(self: WaveDirector, mods: WorldMods)
	self.mods = mods
end

function WaveDirector.progress(self: WaveDirector): number
	return math.clamp(self.elapsed / self.duration, 0, 1)
end

-- Spawns per second right now for an effective party of `playerCount` (may be
-- fractional). v4 per-hero mode: playerCount = standing heroes.
function WaveDirector.rate(self: WaveDirector, playerCount: number): number
	local p = self:progress()
	local ramp = 1 + WaveDirector.RAMP_GAIN * p ^ 1.4
	local cycleScale = 1 + 0.35 * (self.cycle - 1)
	local stageScale = 1 + 0.12 * (self.stage - 1)
	local pc = if playerCount == playerCount then playerCount else 1
	local base = WaveDirector.BASE_RATE
	local playerScale = 1 + WaveDirector.PLAYER_SCALE * (math.max(1, pc) - 1)
	if self.perHero then
		ramp = 1 + (WaveDirector.PER_HERO_RAMP - 1) * p ^ 1.4
		base = WaveDirector.PER_HERO_RATE
		playerScale = math.max(1, pc)
	end
	local modMult = self.mods.spawnRateMult or 1
	-- Pressure "Rush Hour": more spawns in the last LATE_SPAWN_WINDOW s of the waves.
	local late = self.mods.lateSpawnMult
	if
		type(late) == "number"
		and late == late
		and late > 0
		and self.elapsed >= self.duration - Pressure.LATE_SPAWN_WINDOW
	then
		modMult *= late
	end
	return base * ramp * cycleScale * stageScale * playerScale * modMult
end

function WaveDirector.eliteChance(self: WaveDirector): number
	-- GDD §3.3: elites appear from stage 2 (any stage on later cycles).
	if self.cycle <= 1 and self.stage <= 1 then
		return 0
	end
	return math.clamp(self.mods.eliteChance or 0, 0, 1)
end

function WaveDirector.pickKind(self: WaveDirector): string
	local p = self:progress()
	local shift = 0.1 * (self.stage - 1) + 0.2 * (self.cycle - 1)
	local ids: { string } = {}
	local weights: { number } = {}
	for _, id in self.pool do
		local mix = WaveDirector.MIX[id]
		local w, unlock = 3, 0.2
		if mix then
			w, unlock = mix.weight, mix.unlock
		end
		if p >= unlock - shift then
			table.insert(ids, id)
			table.insert(weights, w)
		end
	end
	if #ids == 0 then
		return self.pool[1]
	end
	return ids[self.rng:weightedIndex(weights)]
end

local function insideObstacle(obstacles: { Obstacle }, x: number, z: number, margin: number): boolean
	for _, o in obstacles do
		local dx, dz = x - o.x, z - o.z
		local rr = o.r + margin
		if dx * dx + dz * dz < rr * rr then
			return true
		end
	end
	return false
end

-- Is (x, z) a legal spawn spot (inside arena, clear of obstacles)?
function WaveDirector.isValid(self: WaveDirector, x: number, z: number): boolean
	local lim = self.arenaRadius - WaveDirector.EDGE_MARGIN
	if x * x + z * z > lim * lim then
		return false
	end
	local zc = self.zoneCircle
	if zc and (x - zc.cx) ^ 2 + (z - zc.cz) ^ 2 > zc.r * zc.r then
		return false -- v4: never outside the storm circle
	end
	return not insideObstacle(self.obstacles, x, z, WaveDirector.OBSTACLE_MARGIN)
end

local function minDistSq(players: { Pos }, x: number, z: number): number
	local best = math.huge
	for _, p in players do
		local dx, dz = p.x - x, p.z - z
		local d2 = dx * dx + dz * dz
		if d2 < best then
			best = d2
		end
	end
	return best
end

-- v4: a spawn anchor, weighted toward heroes with few mice on screen (`nearMice`).
function WaveDirector._anchor(self: WaveDirector, players: { Pos }): Pos
	local n = #players
	if n == 0 then
		return { x = 0, z = 0 }
	end
	local rng = self.rng
	if not self.perHero or n == 1 or (players[1] :: any).nearMice == nil then
		return rng:pick(players)
	end
	local weights = table.create(n)
	for i, p in players do
		local near = (p :: any).nearMice or 0
		weights[i] = math.max(0.15, WaveDirector.DENSITY_MAX - near)
	end
	return players[rng:weightedIndex(weights)]
end

-- Picks a spawn point on the ring around `anchor` (or a random player) outside everyone's view.
function WaveDirector.pickSpawnPoint(self: WaveDirector, players: { Pos }, anchor: Pos?): (number, number)
	local rng = self.rng
	local view = self.viewRadius
	local a = anchor or WaveDirector._anchor(self, players)
	local view2 = (view * 0.9) ^ 2
	local bestX, bestZ, bestD = 0, 0, -1
	for _ = 1, 12 do
		local ang = rng:range(0, math.pi * 2)
		local d = view + rng:range(0, 10)
		local x, z = a.x + math.cos(ang) * d, a.z + math.sin(ang) * d
		if self:isValid(x, z) then
			local md = minDistSq(players, x, z)
			if md >= view2 then
				return x, z
			end
			if md > bestD then
				bestX, bestZ, bestD = x, z, md
			end
		end
	end
	-- Small arena or crowded edge: try spots near the rim and keep the one farthest from players.
	local lim = self.arenaRadius - WaveDirector.EDGE_MARGIN - 1
	for _ = 1, 10 do
		local ang = rng:range(0, math.pi * 2)
		local d = lim * rng:range(0.7, 1)
		local x, z = math.cos(ang) * d, math.sin(ang) * d
		if self:isValid(x, z) then
			local md = minDistSq(players, x, z)
			if md > bestD then
				bestX, bestZ, bestD = x, z, md
			end
		end
	end
	if bestD >= 0 then
		return bestX, bestZ
	end
	-- Pathological map (rim covered in obstacles): spiral inward until something is free.
	for ring = 1, 20 do
		local d = lim * (1 - ring * 0.045)
		for k = 0, 15 do
			local ang = k * math.pi / 8 + ring
			local x, z = math.cos(ang) * d, math.sin(ang) * d
			if self:isValid(x, z) then
				return x, z
			end
		end
	end
	return 0, 0
end

-- Advances the director and returns this step's spawn requests.
-- players = standing participants' positions (downed players don't attract spawns).
-- party = effective party size (defaults to #players; bots count fractionally).
function WaveDirector.update(
	self: WaveDirector,
	dt: number,
	liveCount: number,
	players: { Pos },
	party: number?
): { SpawnRequest }
	local out: { SpawnRequest } = {}
	if not self.active then
		return out
	end
	self.elapsed += dt
	if #players == 0 then
		return out
	end
	local cap = self.cap
	local partySize = party or #players
	local bank = WaveDirector.MAX_BANKED
	if self.perHero then
		partySize = #players
		cap = math.min(cap, WaveDirector.PER_HERO_CAP * #players)
		bank = math.max(bank, WaveDirector.START_PER_HERO * #players)
		if not self.seeded then
			self.seeded = true
			self.budget = math.max(self.budget, WaveDirector.START_PER_HERO * #players)
		end
	end
	local room = cap - liveCount
	self.budget = math.min(self.budget + self:rate(partySize) * dt, bank)
	if room <= 0 then
		return out
	end
	local rng = self.rng
	local elite = self:eliteChance()

	-- Surge: a ring of mice around one player.
	if self.elapsed >= self.nextSurge then
		self.nextSurge += WaveDirector.SURGE_EVERY
		local target = rng:pick(players)
		local n = math.min(room, 10 + math.floor(4 * math.min(partySize, 4)) + 2 * (self.cycle - 1))
		local d = self.viewRadius * 0.85
		local a0 = rng:range(0, math.pi * 2)
		local id = if table.find(self.pool, "mouse") then "mouse" else self.pool[1]
		for i = 1, n do
			local ang = a0 + (i / n) * math.pi * 2
			local x, z = target.x + math.cos(ang) * d, target.z + math.sin(ang) * d
			if self:isValid(x, z) then
				table.insert(out, { id = id, x = x, z = z, elite = false, surge = true })
			end
		end
		room -= #out
	end

	local maxGroup = 2 + math.floor(3 * self:progress())
	while self.budget >= 1 and room > 0 do
		local group = math.min(math.floor(self.budget), room, rng:nextInt(1, maxGroup))
		self.budget -= group
		room -= group
		local cx, cz = self:pickSpawnPoint(players)
		local kind = self:pickKind()
		for _ = 1, group do
			local x, z = cx + rng:range(-2.5, 2.5), cz + rng:range(-2.5, 2.5)
			if not self:isValid(x, z) then
				x, z = cx, cz
			end
			table.insert(out, { id = kind, x = x, z = z, elite = elite > 0 and rng:chance(elite) })
		end
	end
	self.spawned += #out
	return out
end

return WaveDirector
