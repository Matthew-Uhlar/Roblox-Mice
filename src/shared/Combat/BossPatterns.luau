--!strict
-- Boss attack-pattern library (GDD §6). Each pattern id in DEFS maps to a base
-- behaviour plus tuning params, so bosses get distinct, themed attacks from a
-- small set of tested building blocks.
--
-- Fairness rule: every damaging pattern emits a {t="tele"} Fx first, with
-- delay >= MIN_TELEGRAPH (0.6 s), at the exact spot/shape that will be hit.
-- Projectiles are telegraphed by a circle (bursts/spirals) or lines (volleys).
--
-- BossPatterns.run(world, caster, patternId, now) -> duration (s)
-- `world` is a Combat/World instance (typed `any` to avoid a require cycle). The
-- pattern only calls these World methods:
--   telegraph(caster, fx), emit(fx), schedule(at, owner, fn(now)), standingPlayers(),
--   nearestStanding(x, z), damagePlayersCircle/Line/Cone(...), spawnEnemyProjectile(...),
--   spawnHostileZone(...), spawnEnemy(...), spawnMinion(...), countMinions(boss),
--   clampToArena(x, z, margin), randomArenaPoint(margin)

local BossPatterns = {}

BossPatterns.MIN_TELEGRAPH = 0.6

type Params = { [string]: any }
type Def = { base: string, [string]: any }

local TAU = math.pi * 2

-- Pattern definitions -----------------------------------------------------------------
-- base = one of BossPatterns.BASES. Damage values are cycle-1 baselines
-- (multiplied by WorldMods.bossDamageMult).
local DEFS: { [string]: Def } = {
	-- Generic library entries (usable by any boss)
	charge = { base = "charge", damage = 20, speed = 55, distance = 40, count = 1 },
	radial_burst = { base = "radial_burst", damage = 10, count = 16, speed = 22 },
	aimed_volley = { base = "aimed_volley", damage = 10, shots = 3, spread = 20, speed = 32, volleys = 2 },
	slam = { base = "slam", damage = 22, radius = 10, at = "self" },
	summon = { base = "summon", count = 6 },
	spiral = { base = "spiral", damage = 8, arms = 3, rate = 6, duration = 3, turn = 70, speed = 20 },
	line_sweep = {
		base = "line_sweep",
		damage = 18,
		lines = 3,
		gap = 0.45,
		length = 50,
		halfWidth = 2.5,
		rotate = 30,
	},
	spell_roulette = {
		base = "spell_roulette",
		spells = {
			"hex_rain",
			"witch_spiral",
			"toad_curse",
			"cauldron_bubbles",
			"broom_charge",
			"star_burst",
		},
	},

	-- Giant Tree
	root_slam = { base = "slam", damage = 22, radius = 7, at = "all", windup = 1.0, count = 1 },
	acorn_burst = {
		base = "radial_burst",
		damage = 9,
		count = 14,
		speed = 20,
		rings = 2,
		ringGap = 0.5,
		proj = "acorn",
		projR = 1.2,
	},
	branch_sweep = {
		base = "line_sweep",
		damage = 18,
		lines = 3,
		gap = 0.5,
		length = 46,
		halfWidth = 3,
		rotate = 35,
		windup = 0.9,
	},
	sapling_summon = { base = "summon", count = 6, ids = { "mouse", "chonk" } },
	root_eruption = {
		base = "rain",
		damage = 22,
		count = 8,
		radius = 6,
		spread = 14,
		stagger = 0.15,
		windup = 1.0,
	},
	acorn_spiral = {
		base = "spiral",
		damage = 8,
		arms = 4,
		rate = 5,
		duration = 3.5,
		turn = 50,
		speed = 18,
		proj = "acorn",
		projR = 1.2,
	},
	branch_sweep_wide = {
		base = "line_sweep",
		damage = 20,
		lines = 5,
		gap = 0.4,
		length = 55,
		halfWidth = 3.5,
		rotate = 30,
		windup = 0.8,
	},

	-- Froggus
	belly_flop = { base = "leap", damage = 24, radius = 9, hops = 1, windup = 1.0 },
	tongue_lash = {
		base = "line_sweep",
		damage = 16,
		lines = 1,
		length = 34,
		halfWidth = 2,
		windup = 0.7,
		aim = "target",
	},
	bubble_volley = {
		base = "aimed_volley",
		damage = 9,
		shots = 5,
		spread = 40,
		speed = 24,
		volleys = 2,
		gap = 0.8,
		proj = "bubble",
		projR = 1.4,
	},
	tadpole_summon = { base = "summon", count = 8, ids = { "rat_runner", "mouse" } },
	belly_flop_triple = { base = "leap", damage = 22, radius = 8, hops = 3, windup = 0.8, gap = 0.3 },
	tongue_lash_triple = {
		base = "line_sweep",
		damage = 16,
		lines = 3,
		gap = 0.35,
		length = 38,
		halfWidth = 2,
		windup = 0.65,
		aim = "target",
		rotate = 0,
		retarget = true,
	},
	lily_burst = {
		base = "radial_burst",
		damage = 10,
		count = 20,
		speed = 18,
		rings = 3,
		ringGap = 0.6,
		proj = "lily",
		projR = 1.5,
	},

	-- Serpent Sisters (+ the sisters' own attack)
	sister_summon = {
		base = "summon",
		minion = true,
		count = 2,
		maxAlive = 2,
		hpFrac = 0.3,
		minionPatterns = { "sister_spit" },
	},
	sister_spit = {
		base = "aimed_volley",
		damage = 8,
		shots = 2,
		spread = 12,
		speed = 28,
		volleys = 1,
		proj = "venom",
	},
	venom_volley = {
		base = "aimed_volley",
		damage = 10,
		shots = 3,
		spread = 24,
		speed = 30,
		volleys = 3,
		gap = 0.7,
		proj = "venom",
		targets = "all",
	},
	coil_charge = { base = "charge", damage = 20, speed = 50, distance = 40, count = 1 },
	fang_burst = {
		base = "radial_burst",
		damage = 9,
		count = 12,
		speed = 24,
		rings = 2,
		ringGap = 0.4,
		proj = "fang",
	},
	venom_spiral = {
		base = "spiral",
		damage = 8,
		arms = 2,
		rate = 8,
		duration = 3.5,
		turn = 90,
		speed = 22,
		proj = "venom",
	},
	coil_charge_double = { base = "charge", damage = 20, speed = 55, distance = 42, count = 2, gap = 0.35 },

	-- My Grandma
	cookie_volley = {
		base = "aimed_volley",
		damage = 9,
		shots = 4,
		spread = 30,
		speed = 26,
		volleys = 2,
		gap = 0.7,
		proj = "cookie",
		targets = "all",
	},
	yarn_spiral = {
		base = "spiral",
		damage = 7,
		arms = 2,
		rate = 6,
		duration = 4,
		turn = 60,
		speed = 17,
		proj = "yarn",
		projR = 1.3,
	},
	slipper_slam = { base = "slam", damage = 20, radius = 6, at = "all", windup = 0.9 },
	soup_spill = {
		base = "hazard",
		damage = 6,
		count = 3,
		radius = 6,
		duration = 5,
		tick = 0.5,
		zone = "soup",
	},
	cookie_storm = {
		base = "radial_burst",
		damage = 9,
		count = 18,
		speed = 20,
		rings = 3,
		ringGap = 0.5,
		proj = "cookie",
	},
	yarn_spiral_double = {
		base = "spiral",
		damage = 7,
		arms = 4,
		rate = 6,
		duration = 4,
		turn = -55,
		speed = 17,
		proj = "yarn",
		projR = 1.3,
	},
	rolling_pin_sweep = {
		base = "line_sweep",
		damage = 18,
		lines = 4,
		gap = 0.45,
		length = 60,
		halfWidth = 3,
		rotate = 45,
		windup = 0.8,
	},

	-- Floating Witch (spell roulette: the "gamba fight")
	witch_roulette = {
		base = "spell_roulette",
		spells = {
			"hex_rain",
			"witch_spiral",
			"toad_curse",
			"cauldron_bubbles",
			"broom_charge",
			"star_burst",
		},
	},
	witch_roulette_fast = {
		base = "spell_roulette",
		reveal = 0.6,
		spells = {
			"hex_rain_big",
			"witch_spiral_double",
			"toad_curse",
			"cauldron_bubbles",
			"broom_charge_double",
			"star_burst_double",
			"lucky_dud",
		},
	},
	hex_bolts = {
		base = "aimed_volley",
		damage = 10,
		shots = 3,
		spread = 18,
		speed = 34,
		volleys = 3,
		gap = 0.6,
		proj = "hex",
	},
	witch_blink = {
		base = "blink",
		damage = 18,
		radius = 7,
		hops = 1,
		windup = 0.9,
		ring = 10,
		ringSpeed = 20,
	},
	hex_rain = { base = "rain", damage = 18, count = 6, radius = 5, spread = 12, stagger = 0.2, windup = 0.9 },
	hex_rain_big = {
		base = "rain",
		damage = 20,
		count = 10,
		radius = 5.5,
		spread = 14,
		stagger = 0.12,
		windup = 0.8,
	},
	witch_spiral = {
		base = "spiral",
		damage = 8,
		arms = 3,
		rate = 6,
		duration = 3,
		turn = 80,
		speed = 20,
		proj = "hex",
	},
	witch_spiral_double = {
		base = "spiral",
		damage = 8,
		arms = 6,
		rate = 5,
		duration = 3.5,
		turn = -70,
		speed = 20,
		proj = "hex",
	},
	toad_curse = { base = "summon", count = 8, ids = { "mouse", "fuse_mouse" } },
	cauldron_bubbles = {
		base = "hazard",
		damage = 6,
		count = 4,
		radius = 5,
		duration = 5,
		tick = 0.5,
		zone = "cauldron",
	},
	broom_charge = { base = "charge", damage = 18, speed = 60, distance = 45, count = 1 },
	broom_charge_double = { base = "charge", damage = 18, speed = 62, distance = 45, count = 2, gap = 0.3 },
	star_burst = {
		base = "radial_burst",
		damage = 9,
		count = 16,
		speed = 22,
		rings = 2,
		ringGap = 0.45,
		proj = "star",
	},
	star_burst_double = {
		base = "radial_burst",
		damage = 9,
		count = 22,
		speed = 22,
		rings = 3,
		ringGap = 0.4,
		proj = "star",
	},
	lucky_dud = { base = "fizzle" }, -- the wheel can land on nothing (the gamba)

	-- Corndog Bunny
	bunny_hop = { base = "leap", damage = 20, radius = 7, hops = 2, windup = 0.85, gap = 0.25 },
	mustard_spray = {
		base = "cone",
		damage = 16,
		range = 24,
		angle = 60,
		count = 1,
		windup = 0.8,
		zone = "mustard",
	},
	ketchup_spiral = {
		base = "spiral",
		damage = 8,
		arms = 3,
		rate = 6,
		duration = 3,
		turn = 75,
		speed = 20,
		proj = "ketchup",
	},
	kernel_burst = {
		base = "radial_burst",
		damage = 8,
		count = 24,
		speed = 26,
		rings = 1,
		proj = "kernel",
		projR = 0.8,
	},
	bunny_hop_frenzy = { base = "leap", damage = 20, radius = 7, hops = 4, windup = 0.7, gap = 0.2 },
	mustard_sweep = {
		base = "cone",
		damage = 16,
		range = 26,
		angle = 55,
		count = 3,
		gap = 0.45,
		rotate = 50,
		windup = 0.7,
	},
	relish_rain = {
		base = "rain",
		damage = 16,
		count = 9,
		radius = 5,
		spread = 14,
		stagger = 0.15,
		windup = 0.9,
	},

	-- Spider Machine (adaptive: picks by distance to the nearest player)
	spider_adaptive = {
		base = "adaptive",
		near = "leg_stomp",
		mid = "web_volley",
		far = "laser_sweep",
		nearDist = 14,
		farDist = 32,
	},
	spider_adaptive_overdrive = {
		base = "adaptive",
		near = "leg_stomp_double",
		mid = "web_volley_heavy",
		far = "laser_sweep_cross",
		nearDist = 15,
		farDist = 30,
	},
	web_volley = {
		base = "aimed_volley",
		damage = 9,
		shots = 5,
		spread = 36,
		speed = 28,
		volleys = 2,
		gap = 0.6,
		proj = "web",
		slow = true,
	},
	web_volley_heavy = {
		base = "aimed_volley",
		damage = 10,
		shots = 7,
		spread = 50,
		speed = 30,
		volleys = 3,
		gap = 0.5,
		proj = "web",
		targets = "all",
	},
	leg_stomp = { base = "slam", damage = 22, radius = 13, at = "self", windup = 0.9 },
	leg_stomp_double = {
		base = "slam",
		damage = 22,
		radius = 14,
		at = "self",
		windup = 0.75,
		count = 2,
		gap = 0.5,
	},
	spiderling_summon = { base = "summon", count = 8, ids = { "rat_runner", "fuse_mouse" } },
	laser_sweep = {
		base = "line_sweep",
		damage = 20,
		lines = 4,
		gap = 0.3,
		length = 70,
		halfWidth = 2,
		rotate = 12,
		windup = 0.9,
		aim = "target",
	},
	laser_sweep_cross = {
		base = "line_sweep",
		damage = 20,
		lines = 3,
		gap = 0.6,
		length = 70,
		halfWidth = 2,
		rotate = 22.5,
		windup = 0.8,
		directions = 4,
	},

	-- Green Gorilla
	chest_pound = { base = "slam", damage = 24, radius = 14, at = "self", windup = 1.0 },
	barrel_roll = { base = "charge", damage = 22, speed = 50, distance = 50, count = 1, width = 1.2 },
	boulder_toss = { base = "slam", damage = 20, radius = 7, at = "all", windup = 1.1, count = 1 },
	banana_burst = {
		base = "radial_burst",
		damage = 9,
		count = 14,
		speed = 22,
		rings = 2,
		ringGap = 0.5,
		proj = "banana",
	},
	rage_charge = { base = "charge", damage = 22, speed = 58, distance = 50, count = 3, gap = 0.3 },
	chest_pound_shockwave = {
		base = "slam",
		damage = 24,
		radius = 12,
		at = "self",
		windup = 0.9,
		ring = 18,
		ringSpeed = 22,
	},
	boulder_toss_big = {
		base = "rain",
		damage = 22,
		count = 6,
		radius = 8,
		spread = 10,
		stagger = 0.25,
		windup = 1.1,
	},

	-- Paper Dinosaur
	paper_stomp = { base = "leap", damage = 22, radius = 9, hops = 1, windup = 1.0 },
	origami_spiral = {
		base = "spiral",
		damage = 8,
		arms = 3,
		rate = 6,
		duration = 3.5,
		turn = 65,
		speed = 19,
		proj = "crane",
	},
	papercut_sweep = {
		base = "line_sweep",
		damage = 17,
		lines = 4,
		gap = 0.35,
		length = 55,
		halfWidth = 1.6,
		rotate = 25,
		windup = 0.75,
	},
	crane_volley = {
		base = "aimed_volley",
		damage = 9,
		shots = 4,
		spread = 28,
		speed = 30,
		volleys = 2,
		gap = 0.6,
		proj = "crane",
		targets = "all",
	},
	fold_charge = { base = "charge", damage = 22, speed = 56, distance = 46, count = 2, gap = 0.35 },
	origami_spiral_dense = {
		base = "spiral",
		damage = 8,
		arms = 5,
		rate = 5,
		duration = 4,
		turn = -60,
		speed = 18,
		proj = "crane",
	},
	confetti_burst = {
		base = "radial_burst",
		damage = 8,
		count = 26,
		speed = 20,
		rings = 3,
		ringGap = 0.45,
		proj = "confetti",
		projR = 0.9,
	},

	-- Dark Hematite Snake
	iron_charge = { base = "charge", damage = 22, speed = 52, distance = 46, count = 1 },
	shard_spiral = {
		base = "spiral",
		damage = 8,
		arms = 3,
		rate = 7,
		duration = 3,
		turn = 85,
		speed = 23,
		proj = "shard",
	},
	magnet_slam = { base = "slam", damage = 22, radius = 8, at = "all", windup = 1.0, count = 2, gap = 0.3 },
	ore_burst = {
		base = "radial_burst",
		damage = 10,
		count = 16,
		speed = 24,
		rings = 2,
		ringGap = 0.45,
		proj = "ore",
	},
	iron_charge_chain = { base = "charge", damage = 22, speed = 58, distance = 46, count = 3, gap = 0.25 },
	shard_spiral_double = {
		base = "spiral",
		damage = 8,
		arms = 6,
		rate = 5,
		duration = 3.5,
		turn = -80,
		speed = 22,
		proj = "shard",
	},
	rust_pools = {
		base = "hazard",
		damage = 7,
		count = 4,
		radius = 6,
		duration = 6,
		tick = 0.5,
		zone = "rust",
	},

	-- Ancient Ice Dragon
	frost_breath = { base = "cone", damage = 18, range = 30, angle = 50, count = 1, windup = 0.9 },
	icicle_rain = {
		base = "rain",
		damage = 18,
		count = 8,
		radius = 5,
		spread = 14,
		stagger = 0.15,
		windup = 1.0,
	},
	wing_gust = {
		base = "radial_burst",
		damage = 10,
		count = 18,
		speed = 26,
		rings = 2,
		ringGap = 0.4,
		proj = "snow",
		projR = 1.3,
	},
	glacier_charge = { base = "charge", damage = 24, speed = 50, distance = 48, count = 1, trail = "ice" },
	frost_breath_sweep = {
		base = "cone",
		damage = 18,
		range = 32,
		angle = 50,
		count = 3,
		gap = 0.5,
		rotate = 45,
		windup = 0.8,
	},
	blizzard_spiral = {
		base = "spiral",
		damage = 8,
		arms = 5,
		rate = 6,
		duration = 4,
		turn = 60,
		speed = 20,
		proj = "snow",
	},
	icicle_storm = {
		base = "rain",
		damage = 20,
		count = 14,
		radius = 5,
		spread = 16,
		stagger = 0.1,
		windup = 0.9,
	},

	-- Void Cat
	void_blink = { base = "blink", damage = 20, radius = 7, hops = 1, windup = 0.9 },
	void_spiral = {
		base = "spiral",
		damage = 8,
		arms = 3,
		rate = 7,
		duration = 3,
		turn = 100,
		speed = 21,
		proj = "void",
	},
	laser_eyes = {
		base = "line_sweep",
		damage = 20,
		lines = 2,
		gap = 0.5,
		length = 65,
		halfWidth = 2,
		rotate = 15,
		windup = 0.85,
		aim = "target",
	},
	yarn_portal_summon = { base = "summon", count = 8, ids = { "mouse", "rat_runner", "crumb_slinger" } },
	void_blink_triple = {
		base = "blink",
		damage = 20,
		radius = 7,
		hops = 3,
		windup = 0.75,
		gap = 0.3,
		ring = 8,
		ringSpeed = 20,
	},
	void_spiral_dense = {
		base = "spiral",
		damage = 8,
		arms = 6,
		rate = 6,
		duration = 4,
		turn = -95,
		speed = 21,
		proj = "void",
	},
	laser_eyes_cross = {
		base = "line_sweep",
		damage = 20,
		lines = 3,
		gap = 0.7,
		length = 70,
		halfWidth = 2,
		rotate = 30,
		windup = 0.85,
		directions = 4,
	},

	-- Zoomzola the Swift Cheese
	zoom_dash = {
		base = "charge",
		damage = 18,
		speed = 70,
		distance = 50,
		count = 3,
		gap = 0.2,
		trail = "gorgonzola",
	},
	stink_burst = {
		base = "radial_burst",
		damage = 9,
		count = 20,
		speed = 22,
		rings = 2,
		ringGap = 0.4,
		proj = "stink",
		projR = 1.4,
	},
	wheel_volley = {
		base = "aimed_volley",
		damage = 12,
		shots = 1,
		spread = 0,
		speed = 36,
		volleys = 4,
		gap = 0.45,
		proj = "cheese_wheel",
		projR = 2.2,
		targets = "all",
	},
	gorgonzola_puddles = {
		base = "hazard",
		damage = 6,
		count = 4,
		radius = 5.5,
		duration = 5,
		tick = 0.5,
		zone = "gorgonzola",
	},
	zoom_frenzy = {
		base = "charge",
		damage = 18,
		speed = 78,
		distance = 55,
		count = 5,
		gap = 0.15,
		trail = "gorgonzola",
	},
	stink_spiral = {
		base = "spiral",
		damage = 8,
		arms = 4,
		rate = 6,
		duration = 3.5,
		turn = 110,
		speed = 21,
		proj = "stink",
	},
}
BossPatterns.DEFS = DEFS

-- Helpers ---------------------------------------------------------------------------

local function windupOf(P: Params, default: number?): number
	return math.max(BossPatterns.MIN_TELEGRAPH, P.windup or default or 0.8)
end

local function dmgOf(w: any, P: Params): number
	return (P.damage or 10) * (w.mods.bossDamageMult or 1)
end

local function dirTo(fx: number, fz: number, tx: number, tz: number, rng: any): (number, number)
	local dx, dz = tx - fx, tz - fz
	local m = math.sqrt(dx * dx + dz * dz)
	if m < 1e-3 then
		local a = rng:range(0, TAU)
		return math.cos(a), math.sin(a)
	end
	return dx / m, dz / m
end

local function rotate(dx: number, dz: number, deg: number): (number, number)
	local a = math.rad(deg)
	local c, s = math.cos(a), math.sin(a)
	return dx * c - dz * s, dx * s + dz * c
end

-- Aim point: nearest standing player, else a random arena spot.
local function aimPoint(w: any, caster: any): (number, number)
	local p = w:nearestStanding(caster.x, caster.z)
	if p then
		return p.x, p.z
	end
	return w:randomArenaPoint(6)
end

local function targetsOf(w: any, caster: any, mode: string?): { { x: number, z: number } }
	local list = {}
	if mode == "all" then
		for _, p in w:standingPlayers() do
			table.insert(list, { x = p.x, z = p.z })
		end
	end
	if #list == 0 then
		local x, z = aimPoint(w, caster)
		table.insert(list, { x = x, z = z })
	end
	return list
end

local function fireRing(w: any, caster: any, P: Params, n: number, speed: number, offset: number)
	local dmg = dmgOf(w, P)
	local r = P.projR or 1
	local ttl = P.ttl or 3.5
	for i = 0, n - 1 do
		local a = offset + i * TAU / n
		local dx, dz = math.cos(a), math.sin(a)
		w:spawnEnemyProjectile(
			caster.x + dx * caster.r,
			caster.z + dz * caster.r,
			dx * speed,
			dz * speed,
			r,
			dmg,
			ttl,
			P.proj or "orb"
		)
	end
end

-- Bases -----------------------------------------------------------------------------
-- Each returns the pattern duration from `now` (the boss stays busy that long).

local BASES: { [string]: (w: any, caster: any, P: Params, now: number) -> number } = {}
BossPatterns.BASES = BASES

-- Dash in a straight line toward the nearest player. Telegraph: line of the boss's width.
BASES.charge = function(w, caster, P, now)
	local count = P.count or 1
	local windup = windupOf(P, 0.8)
	local speed = P.speed or 55
	local dist = P.distance or 40
	local gap = P.gap or 0.4
	local dashTime = dist / speed
	local per = windup + dashTime + gap
	for i = 0, count - 1 do
		local t0 = now + i * per
		w:schedule(t0, caster, function(tnow: number)
			local tx, tz = aimPoint(w, caster)
			local dx, dz = dirTo(caster.x, caster.z, tx, tz, w.bossRng)
			local halfW = caster.r * (P.width or 1)
			w:telegraph(caster, {
				t = "tele",
				shape = "line",
				x = caster.x,
				z = caster.z,
				dx = dx,
				dz = dz,
				len = dist,
				r = halfW,
				delay = windup,
			})
			caster.lockedUntil = tnow + windup
			w:schedule(tnow + windup, caster, function(t2: number)
				caster.dash = {
					dx = dx,
					dz = dz,
					speed = speed,
					untilT = t2 + dashTime,
					dmg = dmgOf(w, P),
					halfW = halfW,
					trail = P.trail,
					nextTrail = t2,
				}
				w:emit({ t = "dash", id = caster.id, dx = dx, dz = dz, speed = speed, dur = dashTime })
			end)
		end)
	end
	return count * per
end

-- Rings of projectiles from the boss. Telegraph: circle on the boss.
BASES.radial_burst = function(w, caster, P, now)
	local windup = windupOf(P, 0.7)
	local rings = P.rings or 1
	local ringGap = P.ringGap or 0.5
	local n = P.count or 16
	w:telegraph(caster, {
		t = "tele",
		shape = "circle",
		x = caster.x,
		z = caster.z,
		r = caster.r + 4,
		delay = windup,
		style = "burst",
	})
	caster.lockedUntil = now + windup + (rings - 1) * ringGap
	local base = w.bossRng:range(0, TAU)
	for k = 0, rings - 1 do
		w:schedule(now + windup + k * ringGap, caster, function()
			fireRing(w, caster, P, n, P.speed or 22, base + (k % 2) * (math.pi / n))
		end)
	end
	return windup + (rings - 1) * ringGap + 0.5
end

-- Fans of aimed shots. Each volley telegraphs lines toward its targets first.
BASES.aimed_volley = function(w, caster, P, now)
	local windup = windupOf(P, 0.7)
	local volleys = P.volleys or 1
	local gap = P.gap or 0.6
	local shots = P.shots or 3
	local spread = P.spread or 20
	local speed = P.speed or 30
	local ttl = P.ttl or 3
	local per = windup + gap
	for v = 0, volleys - 1 do
		w:schedule(now + v * per, caster, function(tnow: number)
			local aims = {}
			for _, tgt in targetsOf(w, caster, P.targets) do
				local dx, dz = dirTo(caster.x, caster.z, tgt.x, tgt.z, w.bossRng)
				table.insert(aims, { dx, dz })
				w:telegraph(caster, {
					t = "tele",
					shape = "cone",
					x = caster.x,
					z = caster.z,
					dx = dx,
					dz = dz,
					r = math.min(speed * ttl, 45),
					len = math.min(speed * ttl, 45),
					angle = math.max(spread, 6),
					delay = windup,
				})
			end
			caster.lockedUntil = tnow + windup
			w:schedule(tnow + windup, caster, function()
				local dmg = dmgOf(w, P)
				for _, a in aims do
					for s = 0, shots - 1 do
						local off = if shots > 1 then -spread / 2 + spread * s / (shots - 1) else 0
						local dx, dz = rotate(a[1], a[2], off)
						w:spawnEnemyProjectile(
							caster.x + dx * caster.r,
							caster.z + dz * caster.r,
							dx * speed,
							dz * speed,
							P.projR or 1,
							dmg,
							ttl,
							P.proj or "orb",
							P.slow
						)
					end
				end
			end)
		end)
	end
	return volleys * per + 0.3
end

-- Circle slams on the boss, on the nearest player, or on every player.
BASES.slam = function(w, caster, P, now)
	local windup = windupOf(P, 0.9)
	local count = P.count or 1
	local gap = P.gap or 0.4
	local radius = P.radius or 10
	local per = windup + gap
	for i = 0, count - 1 do
		w:schedule(now + i * per, caster, function(tnow: number)
			local spots: { { x: number, z: number } } = {}
			if P.at == "self" then
				spots = { { x = caster.x, z = caster.z } }
			elseif P.at == "all" then
				spots = targetsOf(w, caster, "all")
			else
				spots = targetsOf(w, caster, nil)
			end
			for _, s in spots do
				w:telegraph(
					caster,
					{ t = "tele", shape = "circle", x = s.x, z = s.z, r = radius, delay = windup }
				)
			end
			if P.at == "self" then
				caster.lockedUntil = tnow + windup
			end
			w:schedule(tnow + windup, caster, function()
				local dmg = dmgOf(w, P)
				for _, s in spots do
					w:damagePlayersCircle(s.x, s.z, radius, dmg)
					w:emit({ t = "slam", x = s.x, z = s.z, r = radius })
				end
				if P.ring then
					fireRing(
						w,
						caster,
						{ damage = (P.damage or 10) * 0.45, proj = "shock" },
						P.ring,
						P.ringSpeed or 20,
						w.bossRng:range(0, TAU)
					)
				end
			end)
		end)
	end
	return count * per + 0.4
end

-- Jump onto the nearest player's position (lerped over the windup), then slam.
BASES.leap = function(w, caster, P, now)
	local hops = P.hops or 1
	local windup = windupOf(P, 0.9)
	local gap = P.gap or 0.3
	local radius = P.radius or 8
	local per = windup + gap
	for i = 0, hops - 1 do
		w:schedule(now + i * per, caster, function(tnow: number)
			local tx, tz = aimPoint(w, caster)
			tx, tz = w:clampToArena(tx, tz, caster.r + 1)
			w:telegraph(caster, { t = "tele", shape = "circle", x = tx, z = tz, r = radius, delay = windup })
			caster.leap = { fx = caster.x, fz = caster.z, tx = tx, tz = tz, t0 = tnow, t1 = tnow + windup }
			w:emit({ t = "leap", id = caster.id, x = tx, z = tz, dur = windup })
			w:schedule(tnow + windup, caster, function()
				caster.leap = nil
				caster.x, caster.z = tx, tz
				w:damagePlayersCircle(tx, tz, radius, dmgOf(w, P))
				w:emit({ t = "slam", x = tx, z = tz, r = radius })
			end)
		end)
	end
	return hops * per + 0.3
end

-- Teleport next to a player (destination telegraphed) and slam on arrival.
BASES.blink = function(w, caster, P, now)
	local hops = P.hops or 1
	local windup = windupOf(P, 0.9)
	local gap = P.gap or 0.3
	local radius = P.radius or 7
	local per = windup + gap
	for i = 0, hops - 1 do
		w:schedule(now + i * per, caster, function(tnow: number)
			local tx, tz = aimPoint(w, caster)
			local a = w.bossRng:range(0, TAU)
			tx, tz = w:clampToArena(tx + math.cos(a) * 3, tz + math.sin(a) * 3, caster.r + 1)
			w:telegraph(caster, { t = "tele", shape = "circle", x = tx, z = tz, r = radius, delay = windup })
			w:emit({ t = "blink", id = caster.id, x = tx, z = tz, delay = windup })
			caster.lockedUntil = tnow + windup
			w:schedule(tnow + windup, caster, function()
				caster.x, caster.z = tx, tz
				w:damagePlayersCircle(tx, tz, radius, dmgOf(w, P))
				w:emit({ t = "slam", x = tx, z = tz, r = radius })
				if P.ring then
					fireRing(
						w,
						caster,
						{ damage = (P.damage or 10) * 0.45, proj = "void" },
						P.ring,
						P.ringSpeed or 20,
						a
					)
				end
			end)
		end)
	end
	return hops * per + 0.3
end

-- Summon mice (or boss minions when P.minion) around the boss.
BASES.summon = function(w, caster, P, now)
	local windup = windupOf(P, 0.8)
	local count = P.count or 6
	if P.minion then
		local alive = w:countMinions(caster)
		count = math.max(0, math.min(count, (P.maxAlive or count) - alive))
	end
	local spots = {}
	for i = 1, count do
		local a = (i / math.max(1, count)) * TAU + w.bossRng:range(-0.3, 0.3)
		local d = caster.r + (if P.minion then 6 else w.bossRng:range(4, 10))
		local x, z = w:clampToArena(caster.x + math.cos(a) * d, caster.z + math.sin(a) * d, 3)
		table.insert(spots, { x = x, z = z })
		w:telegraph(caster, {
			t = "tele",
			shape = "circle",
			x = x,
			z = z,
			r = if P.minion then 3.5 else 2,
			delay = windup,
			style = "summon",
		})
	end
	caster.lockedUntil = now + windup
	w:schedule(now + windup, caster, function()
		for _, s in spots do
			if P.minion then
				w:spawnMinion(caster, P.hpFrac or 0.25, P.minionPatterns or {}, s.x, s.z)
			else
				local id = if P.ids then w.bossRng:pick(P.ids) else nil
				w:spawnEnemy(id, s.x, s.z, false)
			end
		end
	end)
	return windup + 0.6
end

-- Rotating streams of projectiles. Telegraph: circle on the boss.
BASES.spiral = function(w, caster, P, now)
	local windup = windupOf(P, 0.7)
	local arms = P.arms or 3
	local rate = P.rate or 6
	local duration = P.duration or 3
	local turn = math.rad(P.turn or 70)
	local speed = P.speed or 20
	w:telegraph(caster, {
		t = "tele",
		shape = "circle",
		x = caster.x,
		z = caster.z,
		r = caster.r + 4,
		delay = windup,
		style = "spiral",
	})
	caster.lockedUntil = now + windup + duration
	local a0 = w.bossRng:range(0, TAU)
	local shots = math.max(1, math.floor(duration * rate))
	local dmg = dmgOf(w, P)
	for s = 0, shots - 1 do
		local t = s / rate
		w:schedule(now + windup + t, caster, function()
			for k = 0, arms - 1 do
				local a = a0 + turn * t + k * TAU / arms
				local dx, dz = math.cos(a), math.sin(a)
				w:spawnEnemyProjectile(
					caster.x + dx * caster.r,
					caster.z + dz * caster.r,
					dx * speed,
					dz * speed,
					P.projR or 1,
					dmg,
					P.ttl or 3.5,
					P.proj or "orb"
				)
			end
		end)
	end
	return windup + duration + 0.3
end

-- Telegraphed beams from the boss, one after another, rotating each time.
BASES.line_sweep = function(w, caster, P, now)
	local windup = windupOf(P, 0.8)
	local lines = P.lines or 3
	local gap = P.gap or 0.45
	local len = P.length or 50
	local halfW = P.halfWidth or 2.5
	local rot = P.rotate or 30
	local dirs = P.directions or 1
	local tx, tz = aimPoint(w, caster)
	local bdx, bdz = dirTo(caster.x, caster.z, tx, tz, w.bossRng)
	-- start the sweep before the target so the beams pass over it
	if P.aim ~= "target" and lines > 1 then
		bdx, bdz = rotate(bdx, bdz, -rot * (lines - 1) / 2)
	end
	caster.lockedUntil = now + (lines - 1) * gap + windup
	for i = 0, lines - 1 do
		w:schedule(now + i * gap, caster, function(tnow: number)
			local dx, dz = bdx, bdz
			if P.retarget then
				local ax, az = aimPoint(w, caster)
				dx, dz = dirTo(caster.x, caster.z, ax, az, w.bossRng)
			else
				dx, dz = rotate(bdx, bdz, rot * i)
			end
			local ox, oz = caster.x, caster.z
			local beams = {}
			for k = 0, dirs - 1 do
				local bx, bz = rotate(dx, dz, k * 360 / dirs)
				table.insert(beams, { bx, bz })
				w:telegraph(caster, {
					t = "tele",
					shape = "line",
					x = ox,
					z = oz,
					dx = bx,
					dz = bz,
					len = len,
					r = halfW,
					delay = windup,
				})
			end
			w:schedule(tnow + windup, caster, function()
				local dmg = dmgOf(w, P)
				for _, b in beams do
					w:damagePlayersLine(ox, oz, b[1], b[2], len, halfW, dmg)
					w:emit({
						t = "strike",
						shape = "line",
						x = ox,
						z = oz,
						dx = b[1],
						dz = b[2],
						len = len,
						r = halfW,
					})
				end
			end)
		end)
	end
	return (lines - 1) * gap + windup + 0.4
end

-- Breath / spray cones toward the nearest player.
BASES.cone = function(w, caster, P, now)
	local windup = windupOf(P, 0.8)
	local count = P.count or 1
	local gap = P.gap or 0.45
	local range = P.range or 25
	local angle = P.angle or 50
	local rot = P.rotate or 0
	local tx, tz = aimPoint(w, caster)
	local bdx, bdz = dirTo(caster.x, caster.z, tx, tz, w.bossRng)
	if count > 1 and rot ~= 0 then
		bdx, bdz = rotate(bdx, bdz, -rot * (count - 1) / 2)
	end
	caster.lockedUntil = now + (count - 1) * gap + windup
	for i = 0, count - 1 do
		w:schedule(now + i * gap, caster, function(tnow: number)
			local dx, dz = rotate(bdx, bdz, rot * i)
			local ox, oz = caster.x, caster.z
			w:telegraph(caster, {
				t = "tele",
				shape = "cone",
				x = ox,
				z = oz,
				dx = dx,
				dz = dz,
				r = range,
				len = range,
				angle = angle,
				delay = windup,
			})
			w:schedule(tnow + windup, caster, function()
				w:damagePlayersCone(ox, oz, dx, dz, range, angle, dmgOf(w, P))
				w:emit({
					t = "strike",
					shape = "cone",
					x = ox,
					z = oz,
					dx = dx,
					dz = dz,
					r = range,
					angle = angle,
					style = P.zone,
				})
			end)
		end)
	end
	return (count - 1) * gap + windup + 0.4
end

-- Many circles raining around players (and a few random spots).
BASES.rain = function(w, caster, P, now)
	local windup = windupOf(P, 0.9)
	local count = P.count or 8
	local radius = P.radius or 5
	local spread = P.spread or 12
	local stagger = P.stagger or 0.15
	local players = w:standingPlayers()
	local rng = w.bossRng
	for i = 0, count - 1 do
		w:schedule(now + i * stagger, caster, function(tnow: number)
			local x, z
			if #players > 0 and i % 4 ~= 3 then
				local p = players[(i % #players) + 1]
				-- first drop of each player lands right on them, later ones scatter
				local d = if i < #players then 0 else rng:range(0, spread)
				local a = rng:range(0, TAU)
				x, z = p.x + math.cos(a) * d, p.z + math.sin(a) * d
			else
				x, z = w:randomArenaPoint(radius)
			end
			x, z = w:clampToArena(x, z, 1)
			w:telegraph(caster, { t = "tele", shape = "circle", x = x, z = z, r = radius, delay = windup })
			w:schedule(tnow + windup, caster, function()
				w:damagePlayersCircle(x, z, radius, dmgOf(w, P))
				w:emit({ t = "slam", x = x, z = z, r = radius })
			end)
		end)
	end
	return (count - 1) * stagger + windup + 0.4
end

-- Lingering damage zones near players (telegraphed before they arm).
BASES.hazard = function(w, caster, P, now)
	local windup = windupOf(P, 0.9)
	local count = P.count or 3
	local radius = P.radius or 6
	local players = w:standingPlayers()
	local rng = w.bossRng
	local spots = {}
	for i = 1, count do
		local x, z
		if #players > 0 and i <= count - 1 then
			local p = players[((i - 1) % #players) + 1]
			local a = rng:range(0, TAU)
			local d = rng:range(0, radius)
			x, z = p.x + math.cos(a) * d, p.z + math.sin(a) * d
		else
			x, z = w:randomArenaPoint(radius)
		end
		x, z = w:clampToArena(x, z, 1)
		table.insert(spots, { x = x, z = z })
		w:telegraph(
			caster,
			{ t = "tele", shape = "circle", x = x, z = z, r = radius, delay = windup, style = P.zone }
		)
	end
	caster.lockedUntil = now + windup
	w:schedule(now + windup, caster, function()
		for _, s in spots do
			w:spawnHostileZone(
				s.x,
				s.z,
				radius,
				dmgOf(w, P),
				P.duration or 5,
				P.tick or 0.5,
				P.zone or "hazard"
			)
		end
	end)
	return windup + 0.8
end

-- The wheel landed on nothing: a harmless puff (the witch's "gamba" dud).
BASES.fizzle = function(w, caster, _P, _now)
	w:emit({ t = "fizzle", id = caster.id, x = caster.x, z = caster.z })
	return 0.8
end

-- Random spell roulette: reveal (Fx "roulette"), then cast the chosen spell.
BASES.spell_roulette = function(w, caster, P, now)
	local spells: { string } = P.spells or {}
	if #spells == 0 then
		return 0.5
	end
	local pick = w.bossRng:pick(spells)
	if #spells > 1 and pick == caster.lastSpell then
		pick = w.bossRng:pick(spells)
	end
	caster.lastSpell = pick
	local reveal = P.reveal or 0.9
	w:emit({ t = "roulette", id = caster.id, spell = pick, options = table.clone(spells), reveal = reveal })
	caster.lockedUntil = now + reveal
	w:schedule(now + reveal, caster, function(tnow: number)
		local d = BossPatterns.run(w, caster, pick, tnow)
		caster.busyUntil = math.max(caster.busyUntil or 0, tnow + d)
	end)
	return reveal + 0.1 -- extended by the spell itself once cast
end

-- Spider Machine: choose stomp / webs / laser from the distance to the nearest player.
BASES.adaptive = function(w, caster, P, now)
	local p = w:nearestStanding(caster.x, caster.z)
	local mode, pick = "mid", P.mid
	if p then
		local d = math.sqrt((p.x - caster.x) ^ 2 + (p.z - caster.z) ^ 2) - caster.r
		if d < (P.nearDist or 14) then
			mode, pick = "near", P.near
		elseif d > (P.farDist or 32) then
			mode, pick = "far", P.far
		end
	end
	w:emit({ t = "adapt", id = caster.id, mode = mode, pattern = pick })
	return BossPatterns.run(w, caster, pick, now)
end

-- Public -----------------------------------------------------------------------------

function BossPatterns.get(id: string): Def?
	return DEFS[id]
end

function BossPatterns.has(id: string): boolean
	local d = DEFS[id]
	return d ~= nil and BASES[d.base] ~= nil
end

-- All pattern ids a def can reach (roulette spells, adaptive branches), for validation.
function BossPatterns.reachable(id: string, out: { [string]: boolean }?): { [string]: boolean }
	local seen = out or {}
	if seen[id] then
		return seen
	end
	seen[id] = true
	local d = DEFS[id]
	if d then
		for _, s in d.spells or {} do
			BossPatterns.reachable(s, seen)
		end
		for _, k in { "near", "mid", "far" } do
			if d[k] then
				BossPatterns.reachable(d[k], seen)
			end
		end
		for _, s in d.minionPatterns or {} do
			BossPatterns.reachable(s, seen)
		end
	end
	return seen
end

-- Starts pattern `id` for `caster` at time `now`; returns how long the caster stays busy.
function BossPatterns.run(w: any, caster: any, id: string, now: number): number
	local def = DEFS[id]
	if not def then
		return 0.5
	end
	local base = BASES[def.base]
	if not base then
		return 0.5
	end
	return base(w, caster, def, now)
end

return BossPatterns
