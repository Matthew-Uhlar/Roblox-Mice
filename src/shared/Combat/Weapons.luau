--!strict
-- Player auto-weapons and abilities. Pure: operates on a Combat/World instance
-- (typed `any` to avoid a require cycle) and a World player record.
--
-- Stat rules (PlayerStats):
--   damage   = weapon.damage * damageMult, crit roll per hit (critChance, critMult)
--   cooldown = weapon.cooldown / attackSpeedMult
--   count    = weapon.count + projectileBonus  (orbit: + extraOrbiters too)
--   pierce   = weapon.pierce + pierceBonus
--   areaMult scales arc / AoE / puddle / blade radii and cone length
--   chain    = extra jumps (60% damage, 12 studs) from each primary hit
--   explodeOnKill = radius of a kill explosion (World queues it; never chains)
--   lifesteal = fraction of damage dealt healed (x healingMult)
--   extraOrbiters = orbiting blades for any class (60% weapon damage)
-- Abilities use AbilityDef.damage * damageMult, area * areaMult, cooldown * cooldownMult.
--
-- v2 PvP (GDD-v2 §2): every shape (sweeps, projectiles, explosions, zones, orbit
-- blades, chains, dash lines, rings) also hits ENEMY-SQUAD heroes through
-- world:forFoesInCircle / forFoesInLine (a no-op with one squad, or on a world
-- without those methods: every v2 hook below is optional). Weapons.hit
-- routes a hero record (`isHero`) to Weapons.hitHero -> world:damageHeroFrom
-- (x World.PVP_MULT x PVP_DAMAGE, crits at half bonus, no knockback; v4).
-- stats.pveDamageMult (talents) multiplies damage to non-heroes only. Auto-weapons aim with
-- world:targetsFor, which prefers mice but takes an enemy hero that is the
-- closest target or within World.HERO_AGGRO studs.
-- v2 gear stats: burnDps (3 s burn, x damageMult), slowOnHit (1.2 s), and the
-- owning squad of a Power Totem deals world.squadDmg[squad] more damage.

local Types = require("../Types")

type PlayerStats = Types.PlayerStats
type WeaponDef = Types.WeaponDef
type AbilityDef = Types.AbilityDef

local Weapons = {}

Weapons.MELEE_ARC_DEG = 150
Weapons.CHAIN_RANGE = 12
Weapons.CHAIN_FALLOFF = 0.6
Weapons.EXTRA_ORBIT_RADIUS = 7
Weapons.EXTRA_ORBIT_DAMAGE = 0.6
Weapons.ORBIT_FX_REFRESH = 5
Weapons.MIN_COOLDOWN = 0.08
Weapons.BURN_TIME = 3 -- gear burn (stats.burnDps) lasts this long; ticks every BURN_TICK
Weapons.BURN_TICK = 0.5
Weapons.SLOW_TIME = 1.2 -- gear slow (stats.slowOnHit)
Weapons.HOVER_HERO_SLOW = 0.6 -- v4: s of slow the Updraft gust puts on rival heroes

export type Derived = {
	cooldown: number,
	damage: number,
	count: number,
	pierce: number,
	radius: number, -- arc / AoE / puddle radius, or projectile radius for bolt/spread
	angle: number, -- spread / cone angle (deg)
	range: number,
	speed: number,
	knockback: number,
	duration: number,
	orbiters: number,
	orbitRadius: number,
	bladeRadius: number,
	orbitDamage: number,
	orbitOmega: number,
	orbitRehit: number,
}

local function n(v: any, default: number): number
	return if type(v) == "number" and v == v then v else default
end

function Weapons.derive(stats: PlayerStats, weapon: WeaponDef): Derived
	local dmgMult = n(stats.damageMult, 1)
	local asMult = math.max(0.1, n(stats.attackSpeedMult, 1))
	local areaMult = math.max(0.1, n(stats.areaMult, 1))
	local kind = weapon.kind
	local baseCount = math.max(1, math.floor(n(weapon.count, 1) + n(stats.projectileBonus, 0)))
	local area = n(weapon.area, 0)
	local range = n(weapon.range, 10)

	local radius: number
	if kind == "bolt" or kind == "spread" then
		radius = math.min(4, (if area > 0 and kind == "bolt" then area else 0.8) * math.sqrt(areaMult))
	elseif kind == "melee_arc" then
		radius = (if area > 0 then area else range) * areaMult
	elseif kind == "cone" then
		radius = range * areaMult
	else
		radius = (if area > 0 then area else 4) * areaMult
	end

	local orbiters = math.max(0, math.floor(n(stats.extraOrbiters, 0)))
	local orbitRadius = Weapons.EXTRA_ORBIT_RADIUS * (1 + (areaMult - 1) * 0.5)
	local bladeRadius = 1.6 * areaMult
	local orbitDamage = n(weapon.damage, 5) * Weapons.EXTRA_ORBIT_DAMAGE * dmgMult
	local orbitOmega = 3
	local orbitRehit = 0.6 / asMult
	if kind == "orbit" then
		orbiters += baseCount
		orbitRadius = range * (1 + (areaMult - 1) * 0.5)
		bladeRadius = (if area > 0 then area else 1.6) * areaMult
		orbitDamage = n(weapon.damage, 5) * dmgMult
		local spd = n(weapon.speed, 0)
		orbitOmega = if spd > 0 then spd / math.max(1, orbitRadius) else 3
		orbitRehit = math.max(Weapons.MIN_COOLDOWN, n(weapon.cooldown, 0.5) / asMult)
	end

	return {
		cooldown = math.max(Weapons.MIN_COOLDOWN, n(weapon.cooldown, 1) / asMult),
		damage = n(weapon.damage, 5) * dmgMult,
		count = baseCount,
		pierce = math.max(0, math.floor(n(weapon.pierce, 0) + n(stats.pierceBonus, 0))),
		radius = radius,
		angle = if area > 0 then area else (if kind == "spread" then 30 else 45),
		range = range,
		speed = n(weapon.speed, 0),
		knockback = n(weapon.knockback, 0),
		duration = n(weapon.duration, 3),
		orbiters = orbiters,
		orbitRadius = orbitRadius,
		bladeRadius = bladeRadius,
		orbitDamage = orbitDamage,
		orbitOmega = orbitOmega,
		orbitRehit = orbitRehit,
	}
end

-- v2 world hooks, tolerant of a world without them (an older or stub world):
-- targets fall back to the nearest mice, and there are no foes to hit.
local function nearestTargets(w: any, p: any, range: number, count: number): { any }
	if type(w.targetsFor) == "function" then
		return w:targetsFor(p, range, count)
	end
	return w:nearestEnemies(p.x, p.z, range, count)
end

-- Iteration 4 aim toggle: weapons that point somewhere (projectiles, lobs, cones) fire at
-- the hero's cursor point in "cursor" mode (World.setAim), clamped to their range. They
-- still fire only while something is in range; melee arcs, orbits and puddles stay
-- hero-centred. Bots always aim at the nearest target.
Weapons.AIMABLE = table.freeze({ bolt = true, spread = true, lob = true, cone = true })
local function targetsFor(w: any, p: any, range: number, count: number): { any }
	local list = nearestTargets(w, p, range, count)
	if p.aimMode ~= "cursor" or #list == 0 or not Weapons.AIMABLE[p.weapon.kind] then
		return list
	end
	local ax, az = p.aimX, p.aimZ
	if type(ax) ~= "number" or type(az) ~= "number" then
		return list
	end
	local dx, dz = ax - p.x, az - p.z
	local d = math.sqrt(dx * dx + dz * dz)
	if d < 0.5 then
		return list -- the cursor on the hero: no direction, keep the nearest
	end
	if d > range then
		ax, az = p.x + dx / d * range, p.z + dz / d * range
	end
	return { { x = ax, z = az, alive = true } }
end
Weapons.targetsFor = targetsFor

local function foesInCircle(w: any, p: any, x: number, z: number, r: number, fn: (any, number) -> ())
	if type(w.forFoesInCircle) == "function" then
		w:forFoesInCircle(p, x, z, r, fn)
	end
end

local function foesInLine(
	w: any,
	p: any,
	x: number,
	z: number,
	dx: number,
	dz: number,
	len: number,
	halfW: number,
	fn: (any) -> ()
)
	if type(w.forFoesInLine) == "function" then
		w:forFoesInLine(p, x, z, dx, dz, len, halfW, fn)
	end
end

local function rotate(dx: number, dz: number, deg: number): (number, number)
	local a = math.rad(deg)
	local c, s = math.cos(a), math.sin(a)
	return dx * c - dz * s, dx * s + dz * c
end

local function unit(dx: number, dz: number): (number, number, number)
	local m = math.sqrt(dx * dx + dz * dz)
	if m < 1e-6 then
		return 1, 0, 0
	end
	return dx / m, dz / m, m
end

-- Hits -------------------------------------------------------------------------------

export type HitOpts = {
	knock: number?,
	fromX: number?,
	fromZ: number?,
	chain: boolean?,
	fromExplosion: boolean?,
	noCrit: boolean?,
	projectile: boolean?, -- PvP: counts as projectile damage (gear projectileResist)
}

-- PvP: one damage instance from player p to enemy-squad hero h. No crit, no
-- knockback; World applies PVP_MULT, spawn protection, safe zones and resists.
function Weapons.hitHero(w: any, p: any, h: any, base: number, opts: HitOpts?): number
	if type(w.damageHeroFrom) ~= "function" then
		return 0
	end
	-- v4: crits land on heroes at PVP_CRIT_BONUS of the bonus (Le F'ante duels)
	local s0 = p.stats
	if
		not (opts and opts.noCrit)
		and n(s0.critChance, 0) > 0
		and w.rng
		and w.rng:chance(n(s0.critChance, 0))
	then
		base *= 1 + (n(s0.critMult, 1.5) - 1) * n(w.PVP_CRIT_BONUS, 0.5)
	end
	local dealt = w:damageHeroFrom(h, base, p, if opts and opts.projectile then "projectile" else nil)
	if dealt <= 0 then
		return 0
	end
	local s = p.stats
	local now = w.now
	local burn = n(s.burnDps, 0)
	if burn > 0 and not h.dead then
		local burning = (h.burnUntil or 0) > now
		h.burnDps = math.max(if burning then n(h.burnDps, 0) else 0, burn * n(s.damageMult, 1))
		if not burning then
			h.burnTick = now + Weapons.BURN_TICK
		end
		h.burnUntil = now + Weapons.BURN_TIME
		h.burnBy = p
	end
	local slow = n(s.slowOnHit, 0)
	if slow > 0 then
		h.slowUntil = math.max(h.slowUntil or 0, now + Weapons.SLOW_TIME)
	end
	local ls = n(s.lifesteal, 0)
	if ls > 0 then
		w:_heal(p, dealt * ls)
	end
	if opts and opts.chain then
		local jumps = math.floor(n(s.chain, 0))
		if jumps > 0 then
			Weapons.chainFrom(w, p, h, base, jumps)
		end
	end
	return dealt
end

-- One damage instance from player p to enemy e (or an enemy hero: Weapons.hitHero).
-- Handles crit, knockback, lifesteal, chain, gear burn / slow and the totem buff.
function Weapons.hit(w: any, p: any, e: any, base: number, opts: HitOpts?): number
	if e.isBuild then
		-- (iteration 6) an enemy turret / barricade (World builds): no crit, no on-hit effects
		return if type(w.damageBuildFrom) == "function" then w:damageBuildFrom(e, base, p) else 0
	end
	if e.isHero then
		return Weapons.hitHero(w, p, e, base, opts)
	end
	if not e.alive then
		return 0
	end
	local s = p.stats
	local crit = not (opts and opts.noCrit) and w.rng:chance(n(s.critChance, 0))
	local amount = base * (if crit then n(s.critMult, 1.5) else 1)
	local pve = s.pveDamageMult -- v4 talents: PvE-only damage (never against heroes)
	if pve and pve == pve and pve > 0 then
		amount *= pve
	end
	local lucky = s.luckyCrumb -- iteration 2 gem unique: a chance of x2 PvE damage
	if lucky and lucky > 0 and w.rng and w.rng:chance(math.min(lucky, 1)) then
		amount *= 2
	end
	local sqd = w.squadDmg
	if sqd then
		local sq = sqd[p.squad]
		if sq then
			amount *= sq
		end
	end
	local tk = p.tk -- (iteration 6, team Talents) combo / frenzy / execute (PvE only)
	if tk and type(w.talentHit) == "function" then
		amount = w:talentHit(p, e, amount)
	end
	local dealt = w:damageEnemy(e, amount, p, crit, opts and opts.fromExplosion)
	if dealt <= 0 then
		return 0
	end
	-- v2 gear (hot path: plain field reads, nothing extra without gear)
	local burn = s.burnDps
	if burn and burn > 0 and e.alive then
		local now = w.now
		e.burnDps = math.max(
			if (e.burnUntil or 0) > now then n(e.burnDps, 0) else 0,
			burn * n(s.damageMult, 1) * n(s.pveDamageMult, 1)
		)
		if (e.burnUntil or 0) <= now then
			e.burnTick = now + Weapons.BURN_TICK
		end
		e.burnUntil = now + Weapons.BURN_TIME
		e.burnBy = p
	end
	local slow = s.slowOnHit
	if slow and slow > 0 and e.alive and not e.isBoss then
		e.slowUntil = w.now + Weapons.SLOW_TIME
		e.slowFactor = 1 - math.clamp(slow, 0, 0.8)
	end
	if opts and opts.knock and opts.knock > 0 and e.alive then
		local dx, dz = unit(e.x - (opts.fromX or p.x), e.z - (opts.fromZ or p.z))
		w:knockEnemy(e, dx, dz, opts.knock)
	end
	local ls = n(s.lifesteal, 0)
	if ls > 0 then
		w:_heal(p, dealt * ls)
	end
	if opts and opts.chain then
		local jumps = math.floor(n(s.chain, 0))
		if jumps > 0 then
			Weapons.chainFrom(w, p, e, base, jumps)
		end
	end
	return dealt
end

function Weapons.chainFrom(w: any, p: any, first: any, base: number, jumps: number)
	local seen = { [first] = true }
	local cur = first
	local dmg = base * Weapons.CHAIN_FALLOFF
	for _ = 1, jumps do
		local best, bestD = nil, math.huge
		local function consider(e: any, d2: number)
			if not seen[e] and d2 < bestD then
				best, bestD = e, d2
			end
		end
		w:forEnemiesInCircle(cur.x, cur.z, Weapons.CHAIN_RANGE, consider)
		foesInCircle(w, p, cur.x, cur.z, Weapons.CHAIN_RANGE, consider)
		if not best then
			return
		end
		seen[best] = true
		w:emit({ t = "chain", x1 = cur.x, z1 = cur.z, x2 = best.x, z2 = best.z, id = p.id })
		Weapons.hit(w, p, best, dmg, nil)
		cur = best
	end
end

-- Circle of damage (lob landings, bursts, kill explosions).
function Weapons.explode(w: any, p: any, x: number, z: number, r: number, dmg: number, opts: HitOpts?)
	w:emit({ t = "boom", x = x, z = z, r = r, id = p.id })
	local o: HitOpts = opts or {}
	local first = o.chain
	local function visit(e: any)
		Weapons.hit(w, p, e, dmg, {
			knock = o.knock,
			fromX = x,
			fromZ = z,
			chain = first,
			fromExplosion = o.fromExplosion,
		})
		first = false
	end
	w:forEnemiesInCircle(x, z, r, visit)
	foesInCircle(w, p, x, z, r, visit)
end

-- Arc / cone sweep from the player. Returns enemies hit.
local function sweep(
	w: any,
	p: any,
	dx: number,
	dz: number,
	radius: number,
	arcDeg: number,
	dmg: number,
	knock: number
): number
	local cosHalf = math.cos(math.rad(arcDeg / 2))
	local hits = 0
	local px, pz = p.x, p.z
	local function visit(e: any, _d2: number)
		local ex, ez = e.x - px, e.z - pz
		local m = math.sqrt(ex * ex + ez * ez)
		if m <= e.r + 1 or (ex * dx + ez * dz) / m >= cosHalf then
			hits += 1
			Weapons.hit(w, p, e, dmg, { knock = knock, fromX = px, fromZ = pz, chain = hits == 1 })
		end
	end
	w:forEnemiesInCircle(px, pz, radius, visit)
	foesInCircle(w, p, px, pz, radius, visit)
	return hits
end

-- Auto-fire per kind. Each returns true if it fired (cooldown starts only then).
local FIRE: { [string]: (w: any, p: any, d: Derived, now: number) -> boolean } = {}

FIRE.melee_arc = function(w, p, d, _now)
	local targets = targetsFor(w, p, d.radius + 1.5, 1)
	local t = targets[1]
	if not t then
		return false
	end
	local dx, dz = unit(t.x - p.x, t.z - p.z)
	for k = 0, d.count - 1 do
		local sx, sz = rotate(dx, dz, k * 360 / d.count)
		w:emit({
			t = "melee",
			id = p.id,
			x = p.x,
			z = p.z,
			dx = sx,
			dz = sz,
			r = d.radius,
			arc = Weapons.MELEE_ARC_DEG,
		})
		sweep(w, p, sx, sz, d.radius, Weapons.MELEE_ARC_DEG, d.damage, d.knockback)
	end
	return true
end

FIRE.cone = function(w, p, d, _now)
	local targets = targetsFor(w, p, d.radius + 1, d.count)
	if #targets == 0 then
		return false
	end
	for k = 1, d.count do
		local t = targets[((k - 1) % #targets) + 1]
		local dx, dz = unit(t.x - p.x, t.z - p.z)
		if k > #targets then
			dx, dz = rotate(dx, dz, (k - #targets) * 25 * (if k % 2 == 0 then 1 else -1))
		end
		w:emit({
			t = "melee",
			id = p.id,
			x = p.x,
			z = p.z,
			dx = dx,
			dz = dz,
			r = d.radius,
			arc = d.angle,
			style = "cone",
		})
		sweep(w, p, dx, dz, d.radius, d.angle, d.damage, d.knockback)
	end
	return true
end

local function fireProjectile(w: any, p: any, d: Derived, dx: number, dz: number, kind: string)
	local speed = if d.speed > 0 then d.speed else 50
	w:spawnPlayerProjectile({
		owner = p,
		-- spawned at the player's centre so mice already in contact still get hit
		x = p.x,
		z = p.z,
		vx = dx * speed,
		vz = dz * speed,
		r = d.radius,
		dmg = d.damage,
		pierce = d.pierce,
		ttl = d.range * 1.15 / speed,
		kind = kind,
		knock = d.knockback,
	})
end

FIRE.bolt = function(w, p, d, _now)
	local targets = targetsFor(w, p, d.range, d.count)
	if #targets == 0 then
		return false
	end
	for k = 1, d.count do
		local t = targets[((k - 1) % #targets) + 1]
		local dx, dz = unit(t.x - p.x, t.z - p.z)
		if k > #targets then
			dx, dz = rotate(dx, dz, math.ceil((k - #targets) / 2) * 10 * (if k % 2 == 0 then 1 else -1))
		end
		fireProjectile(w, p, d, dx, dz, "bolt")
	end
	return true
end

FIRE.spread = function(w, p, d, _now)
	local targets = targetsFor(w, p, d.range, 1)
	local t = targets[1]
	if not t then
		return false
	end
	local dx, dz = unit(t.x - p.x, t.z - p.z)
	local angle = math.max(d.angle, (d.count - 1) * 6)
	for k = 0, d.count - 1 do
		local off = if d.count > 1 then -angle / 2 + angle * k / (d.count - 1) else 0
		local sx, sz = rotate(dx, dz, off)
		fireProjectile(w, p, d, sx, sz, "spread")
	end
	return true
end

FIRE.lob = function(w, p, d, now)
	local targets = targetsFor(w, p, d.range, d.count)
	if #targets == 0 then
		return false
	end
	for k = 1, d.count do
		local t = targets[((k - 1) % #targets) + 1]
		local tx, tz = t.x, t.z
		if k > #targets then
			local a = w.rng:range(0, math.pi * 2)
			tx, tz = tx + math.cos(a) * d.radius, tz + math.sin(a) * d.radius
		end
		local dist = math.sqrt((tx - p.x) ^ 2 + (tz - p.z) ^ 2)
		local flight = math.clamp(dist / (if d.speed > 0 then d.speed else 30), 0.35, 1.2)
		w:spawnPlayerProjectile({
			owner = p,
			x = p.x,
			z = p.z,
			vx = (tx - p.x) / flight,
			vz = (tz - p.z) / flight,
			r = d.radius,
			dmg = d.damage,
			pierce = 0,
			ttl = flight,
			kind = "lob",
			knock = d.knockback,
			lob = true,
			tx = tx,
			tz = tz,
			landAt = now + flight,
		})
	end
	return true
end

FIRE.puddle = function(w, p, d, now)
	local targets = targetsFor(w, p, d.range, d.count)
	if #targets == 0 then
		return false
	end
	for k = 1, d.count do
		local t = targets[((k - 1) % #targets) + 1]
		w:spawnPlayerZone({
			owner = p,
			x = t.x,
			z = t.z,
			r = d.radius,
			dmg = d.damage,
			tick = 0.5,
			untilT = now + d.duration,
			kind = "puddle",
		})
	end
	return true
end

FIRE.orbit = function(_w, _p, _d, _now)
	return false -- orbiters are continuous (Weapons.updateOrbit)
end

function Weapons.updateOrbit(w: any, p: any, d: Derived, now: number)
	local nOrb = d.orbiters
	if nOrb <= 0 then
		return
	end
	if p.orbitDirty or now >= (p.orbitFxAt or 0) then
		p.orbitDirty = false
		p.orbitFxAt = now + Weapons.ORBIT_FX_REFRESH
		-- blade i angle at time t = omega * (t - t0) + i * 2pi / n
		w:emit({
			t = "orbit",
			id = p.id,
			n = nOrb,
			r = d.orbitRadius,
			blade = d.bladeRadius,
			omega = d.orbitOmega,
			t0 = p.orbitT0,
		})
	end
	local base = d.orbitOmega * (now - p.orbitT0)
	local pid = p.id
	for i = 0, nOrb - 1 do
		local a = base + i * math.pi * 2 / nOrb
		local bx, bz = p.x + math.cos(a) * d.orbitRadius, p.z + math.sin(a) * d.orbitRadius
		local function blade(e: any)
			local hits = e.orbitHit
			if not hits then
				hits = {}
				e.orbitHit = hits
			end
			if (hits[pid] or 0) <= now then
				hits[pid] = now + d.orbitRehit
				Weapons.hit(
					w,
					p,
					e,
					d.orbitDamage,
					{ knock = (p.weapon.knockback or 0), fromX = p.x, fromZ = p.z }
				)
			end
		end
		w:forEnemiesInCircle(bx, bz, d.bladeRadius, blade)
		foesInCircle(w, p, bx, bz, d.bladeRadius, blade)
	end
end

-- Called by World each step for each standing player.
function Weapons.update(w: any, p: any, _dt: number, now: number)
	local d: Derived = p.derived
	Weapons.updateOrbit(w, p, d, now)
	if now >= p.weaponReadyAt then
		local fire = FIRE[p.weapon.kind]
		if fire and fire(w, p, d, now) then
			p.weaponReadyAt = now + d.cooldown
		end
	end
end

-- Abilities ----------------------------------------------------------------------------

local function aimDir(p: any, aimX: number, aimZ: number): (number, number, number)
	local dx, dz, m = unit(aimX - p.x, aimZ - p.z)
	if m < 0.5 then
		return p.faceX or 1, p.faceZ or 0, 0
	end
	return dx, dz, m
end

local function aimPoint(p: any, aimX: number, aimZ: number, maxDist: number): (number, number)
	local dx, dz, m = aimDir(p, aimX, aimZ)
	local d = math.min(m, maxDist)
	return p.x + dx * d, p.z + dz * d
end

-- (iteration 6 QC) `replay` = an echo / Cataclysm repeat (dash and leap replay their damage only)
local ABILITY: {
	[string]: (
		w: any,
		p: any,
		a: AbilityDef,
		aimX: number,
		aimZ: number,
		now: number,
		replay: boolean?
	) -> (),
} =
	{}

-- Stampede: dash toward aim, damaging + knocking back along the path; brief invulnerability.
ABILITY.dash = function(w, p, a, aimX, aimZ, now, replay)
	local s = p.stats
	local line = p.dashLine
	if replay then
		-- (iteration 6 QC) echo / Cataclysm replay the same line's damage: no second
		-- teleport and no fresh invulnerability
		if line then
			local dmg = n(a.damage, 0) * n(s.damageMult, 1)
			local function hitLine(e: any)
				Weapons.hit(w, p, e, dmg, { knock = 6, fromX = line.sx, fromZ = line.sz, chain = false })
			end
			w:forEnemiesInLine(line.sx, line.sz, line.dx, line.dz, line.len, line.halfW, hitLine)
			foesInLine(w, p, line.sx, line.sz, line.dx, line.dz, line.len, line.halfW, hitLine)
			w:emit({
				t = "ability",
				id = p.id,
				kind = "dash",
				x = line.ex,
				z = line.ez,
				r = line.halfW,
				fromX = line.sx,
				fromZ = line.sz,
				replay = true,
			})
		end
		return
	end
	local dx, dz = aimDir(p, aimX, aimZ)
	local dist = n(a.distance, 16)
	local ex, ez = w:clampToArena(p.x + dx * dist, p.z + dz * dist, 2)
	ex, ez = w:pushOutOfObstacles(ex, ez, 2)
	local sx, sz = p.x, p.z
	local len = math.sqrt((ex - sx) ^ 2 + (ez - sz) ^ 2)
	local halfW = n(a.area, 4) * n(s.areaMult, 1)
	local dmg = n(a.damage, 0) * n(s.damageMult, 1)
	p.invulnUntil = math.max(p.invulnUntil, now + 0.35)
	local function visit(e: any)
		Weapons.hit(w, p, e, dmg, { knock = 6, fromX = sx, fromZ = sz, chain = false })
	end
	w:forEnemiesInLine(sx, sz, dx, dz, len, halfW, visit)
	foesInLine(w, p, sx, sz, dx, dz, len, halfW, visit)
	w:teleportPlayer(p, ex, ez)
	p.dashLine = { sx = sx, sz = sz, dx = dx, dz = dz, len = len, halfW = halfW, ex = ex, ez = ez }
	w:emit({ t = "ability", id = p.id, kind = "dash", x = ex, z = ez, r = halfW, fromX = sx, fromZ = sz })
end

-- Geyser: AoE burst at the aim point.
ABILITY.burst = function(w, p, a, aimX, aimZ, _now)
	local s = p.stats
	local x, z = aimPoint(p, aimX, aimZ, n(a.distance, 30))
	local r = n(a.area, 8) * n(s.areaMult, 1)
	w:emit({ t = "ability", id = p.id, kind = "burst", x = x, z = z, r = r })
	Weapons.explode(w, p, x, z, r, n(a.damage, 0) * n(s.damageMult, 1), { knock = 4, chain = true })
end

-- Thorn Ring: damage ring around the player, then a lingering ring that follows them.
ABILITY.ring = function(w, p, a, _aimX, _aimZ, now)
	local s = p.stats
	local r = n(a.area, 10) * n(s.areaMult, 1)
	local dmg = n(a.damage, 0) * n(s.damageMult, 1)
	w:emit({ t = "ability", id = p.id, kind = "ring", x = p.x, z = p.z, r = r })
	local function visit(e: any)
		Weapons.hit(w, p, e, dmg, { knock = 5, fromX = p.x, fromZ = p.z })
	end
	w:forEnemiesInCircle(p.x, p.z, r, visit)
	foesInCircle(w, p, p.x, p.z, r, visit)
	local dur = n(a.duration, 0)
	if dur > 0 then
		-- AbilityDef.damage is per tick for ring (Classes.luau convention)
		w:spawnPlayerZone({
			owner = p,
			x = p.x,
			z = p.z,
			r = r,
			dmg = dmg,
			tick = 0.5,
			untilT = now + dur,
			kind = "ring",
			follow = true,
			nextTick = now + 0.5,
		})
	end
end

-- Riposte: invulnerable for `duration`, then a counter-burst (+25% per blocked hit, max +100%).
ABILITY.shield = function(w, p, a, _aimX, _aimZ, now)
	local s = p.stats
	local dur = n(a.duration, 1.2)
	p.invulnUntil = math.max(p.invulnUntil, now + dur)
	p.shield = {
		untilT = now + dur,
		dmg = n(a.damage, 0) * n(s.damageMult, 1),
		r = n(a.area, 9) * n(s.areaMult, 1),
		blocked = 0,
	}
	w:emit({ t = "ability", id = p.id, kind = "shield", x = p.x, z = p.z, r = p.shield.r, dur = dur })
end

-- Called by World when a shield expires.
function Weapons.shieldBurst(w: any, p: any)
	local sh = p.shield
	p.shield = nil
	if not sh then
		return
	end
	local mult = 1 + 0.25 * math.min(sh.blocked, 4)
	Weapons.explode(w, p, p.x, p.z, sh.r, sh.dmg * mult, { knock = 5, chain = true })
end

-- Sizzle: fire puddle at the aim point.
ABILITY.puddle = function(w, p, a, aimX, aimZ, now)
	local s = p.stats
	local x, z = aimPoint(p, aimX, aimZ, n(a.distance, 24))
	local r = n(a.area, 7) * n(s.areaMult, 1)
	w:emit({ t = "ability", id = p.id, kind = "puddle", x = x, z = z, r = r })
	w:spawnPlayerZone({
		owner = p,
		x = x,
		z = z,
		r = r,
		dmg = n(a.damage, 0) * n(s.damageMult, 1),
		tick = 0.4,
		untilT = now + n(a.duration, 4),
		kind = "fire",
	})
end

-- Updraft: hover, immune to contact damage; gust knocks nearby mice away.
ABILITY.hover = function(w, p, a, _aimX, _aimZ, now)
	local s = p.stats
	local dur = n(a.duration, 2)
	p.hoverUntil = math.max(p.hoverUntil, now + dur)
	local r = n(a.area, 8) * n(s.areaMult, 1)
	w:emit({ t = "ability", id = p.id, kind = "hover", x = p.x, z = p.z, r = r, dur = dur })
	local dmg = n(a.damage, 0) * n(s.damageMult, 1)
	w:forEnemiesInCircle(p.x, p.z, r, function(e)
		if dmg > 0 then
			Weapons.hit(w, p, e, dmg, { knock = 7, fromX = p.x, fromZ = p.z })
		else
			local dx, dz = unit(e.x - p.x, e.z - p.z)
			w:knockEnemy(e, dx, dz, 7)
		end
	end)
	foesInCircle(w, p, p.x, p.z, r, function(h)
		if dmg > 0 then
			Weapons.hit(w, p, h, dmg, nil)
		end
		-- v4: the take-off gust slows rival heroes (Jumbo PvP, V4-A M3)
		h.slowUntil = math.max(h.slowUntil or 0, now + Weapons.HOVER_HERO_SLOW)
	end)
end

-- Soda Geyser: big slow field (50% slow) with light damage ticks.
ABILITY.field = function(w, p, a, aimX, aimZ, now)
	local s = p.stats
	local x, z = aimPoint(p, aimX, aimZ, n(a.distance, 28))
	local r = n(a.area, 12) * n(s.areaMult, 1)
	w:emit({ t = "ability", id = p.id, kind = "field", x = x, z = z, r = r })
	w:spawnPlayerZone({
		owner = p,
		x = x,
		z = z,
		r = r,
		dmg = n(a.damage, 0) * n(s.damageMult, 1),
		tick = 0.5,
		untilT = now + n(a.duration, 5),
		kind = "soda",
		slow = 0.5,
	})
end

-- (iteration 6, team Builder) Tinkerphant ------------------------------------------------------
Weapons.REPAIR_BUILD_MULT = 3 -- Repair Pulse heals builds this x the squadmates' share
Weapons.REPAIR_SELF = true -- the caster is one of the squadmates it heals

-- Deploy Turret: a World build at the aim point (World.spawnBuild).
ABILITY.turret = function(w, p, a, aimX, aimZ, _now)
	local x, z = aimPoint(p, aimX, aimZ, n(a.distance, 30))
	if type(w.spawnBuild) ~= "function" then
		return
	end
	local b = w:spawnBuild(p, "turret", a, x, z)
	if b then
		w:emit({ t = "ability", id = p.id, kind = "turret", x = b.x, z = b.z, r = b.range, build = b.id })
	end
end

-- Barricade: a wall across the aim line, centred on the aim point.
ABILITY.barricade = function(w, p, a, aimX, aimZ, _now)
	local dx, dz = aimDir(p, aimX, aimZ)
	local x, z = aimPoint(p, aimX, aimZ, n(a.distance, 22))
	if type(w.spawnBuild) ~= "function" then
		return
	end
	local b = w:spawnBuild(p, "barricade", a, x, z, -dz, dx)
	if b then
		w:emit({ t = "ability", id = p.id, kind = "barricade", x = b.x, z = b.z, r = b.half, build = b.id })
	end
end

-- Repair Pulse: heals squadmates (and the caster) around the caster by `heal` x max HP,
-- and the squad's builds there by REPAIR_BUILD_MULT x that.
ABILITY.repair = function(w, p, a, _aimX, _aimZ, _now)
	local s = p.stats
	local r = n(a.area, 16) * n(s.areaMult, 1)
	local frac = math.max(0, n(a.heal, 0.12))
	w:emit({ t = "ability", id = p.id, kind = "repair", x = p.x, z = p.z, r = r })
	local r2 = (r + 1.6) * (r + 1.6)
	for _, q in w.playerList or {} do
		if
			q.squad == p.squad
			and (q ~= p or Weapons.REPAIR_SELF)
			and not q.downed
			and not q.dead
			and (q.x - p.x) ^ 2 + (q.z - p.z) ^ 2 <= r2
		then
			w:_heal(q, q.maxHp * frac)
			w:emit({ t = "heal", id = q.id, x = q.x, z = q.z, by = p.id })
		end
	end
	if type(w.repairBuilds) == "function" then
		w:repairBuilds(p, p.x, p.z, r, frac * Weapons.REPAIR_BUILD_MULT)
	end
end
-- (end iteration 6, team Builder)

-- (iteration 6, team Abilities) advanced ability kinds -----------------------------------------
-- Fx (all t = "ability", id = caster; `ascended = true` on the signature abilities):
--   chain       {kind="chain", x, z, pts = {{x, z}, ...}}   the path (first target first)
--   vortex      {kind="vortex", x, z, r, dur}                then World pulls / ticks
--   leap        {kind="leap", fromX, fromZ, x, z, r, dur}    take-off (immune in the air)
--   leap_land   {kind="leap_land", x, z, r}                  landing slam after `dur`
--   mark        {kind="mark", x, z, r, dur, n}               n marked; then per pop:
--   mark_pop    {kind="mark_pop", x, z, r}                   (at most MARK_FX_CAP per cast)
Weapons.CHAIN_ABILITY_FALLOFF = 0.85 -- each jump deals this x the previous one
Weapons.VORTEX_TICK = 0.5
Weapons.MARK_POP_RADIUS = 5
Weapons.MARK_MAX = 30 -- marks per cast (cost cap)
Weapons.MARK_FX_CAP = 12

local function asc(a: AbilityDef): boolean?
	return if (a :: any).ascended then true else nil
end

-- Chain: hits the target nearest the aim point within reach, then jumps `jumps` times.
ABILITY.chain = function(w, p, a, aimX, aimZ, _now)
	local s = p.stats
	local reach = n(a.distance, 36)
	local jump = n(a.area, 13) * n(s.areaMult, 1)
	local ax, az = aimPoint(p, aimX, aimZ, reach)
	local first, bestD = nil, math.huge
	local function consider(e: any, _d2: number?)
		local d2 = (e.x - ax) ^ 2 + (e.z - az) ^ 2
		if d2 < bestD and (e.x - p.x) ^ 2 + (e.z - p.z) ^ 2 <= (reach + 4) ^ 2 then
			first, bestD = e, d2
		end
	end
	w:forEnemiesInCircle(ax, az, jump * 1.5, consider)
	foesInCircle(w, p, ax, az, jump * 1.5, consider)
	if not first then
		w:forEnemiesInCircle(p.x, p.z, reach, consider)
		foesInCircle(w, p, p.x, p.z, reach, consider)
	end
	local pts = {}
	if first then
		local dmg = n(a.damage, 0) * n(s.damageMult, 1)
		local seen = { [first] = true }
		local cur = first
		for _ = 0, math.max(0, math.floor(n(a.jumps, 4))) do
			table.insert(pts, { x = cur.x, z = cur.z })
			Weapons.hit(w, p, cur, dmg, { knock = 2, fromX = p.x, fromZ = p.z })
			dmg *= Weapons.CHAIN_ABILITY_FALLOFF
			local nxt, nd = nil, math.huge
			local function pick(e: any, _d2: number?)
				local d2 = (e.x - cur.x) ^ 2 + (e.z - cur.z) ^ 2
				if not seen[e] and d2 < nd then
					nxt, nd = e, d2
				end
			end
			w:forEnemiesInCircle(cur.x, cur.z, jump, pick)
			foesInCircle(w, p, cur.x, cur.z, jump, pick)
			if not nxt then
				break
			end
			seen[nxt] = true
			cur = nxt
		end
	end
	w:emit({ t = "ability", id = p.id, kind = "chain", x = ax, z = az, pts = pts, ascended = asc(a) })
end

-- Vortex: a zone at the aim point that pulls mice toward its centre (rival heroes are
-- slowed instead) and damages everything inside every VORTEX_TICK for `duration`.
ABILITY.vortex = function(w, p, a, aimX, aimZ, now)
	local s = p.stats
	local x, z = aimPoint(p, aimX, aimZ, n(a.distance, 30))
	local r = n(a.area, 12) * n(s.areaMult, 1)
	local dur = n(a.duration, 3)
	local pull = n((a :: any).pull, 3)
	w:emit({ t = "ability", id = p.id, kind = "vortex", x = x, z = z, r = r, dur = dur, ascended = asc(a) })
	local ticks = math.max(1, math.floor(dur / Weapons.VORTEX_TICK + 0.5))
	for k = 1, ticks do
		w:schedule(now + k * Weapons.VORTEX_TICK, p, function(_at: number)
			local dmg = n(a.damage, 0) * n(p.stats.damageMult, 1)
			w:forEnemiesInCircle(x, z, r, function(e: any)
				local dx, dz, d = unit(x - e.x, z - e.z)
				if d > 0.5 then
					w:knockEnemy(e, dx, dz, math.min(pull, d))
				end
				Weapons.hit(w, p, e, dmg, nil)
			end)
			-- rival heroes are never moved by the server (their client owns the walk):
			-- they are slowed inside instead
			foesInCircle(w, p, x, z, r, function(h: any)
				h.slowUntil = math.max(h.slowUntil or 0, now + Weapons.VORTEX_TICK * (k + 1))
				Weapons.hit(w, p, h, dmg, nil)
			end)
		end)
	end
end

-- Leap: immune in the air for `duration`, then lands at the aim point (arena / rocks
-- clamped) and slams the landing area.
ABILITY.leap = function(w, p, a, aimX, aimZ, now, replay)
	local s = p.stats
	local r = n(a.area, 10) * n(s.areaMult, 1)
	if replay then
		-- (iteration 6 QC) echo / Cataclysm replay only the landing slam at the landing
		-- point: no second leap, no fresh invulnerability
		local lt = p.leapTarget
		if lt then
			w:emit({
				t = "ability",
				id = p.id,
				kind = "leap_land",
				x = lt.x,
				z = lt.z,
				r = r,
				ascended = asc(a),
				replay = true,
			})
			Weapons.explode(w, p, lt.x, lt.z, r, n(a.damage, 0) * n(s.damageMult, 1), { knock = 6 })
		end
		return
	end
	local tx, tz = aimPoint(p, aimX, aimZ, n(a.distance, 26))
	tx, tz = w:clampToArena(tx, tz, 2)
	tx, tz = w:pushOutOfObstacles(tx, tz, 2)
	-- never leap from inside the storm circle to outside it (step back toward the hero)
	if type(w.insideZone) == "function" and w:insideZone(p.x, p.z, 0) and not w:insideZone(tx, tz, 2) then
		local ox, oz = tx, tz
		for k = 1, 8 do
			local f = 1 - k / 8
			tx, tz = p.x + (ox - p.x) * f, p.z + (oz - p.z) * f
			if w:insideZone(tx, tz, 2) then
				break
			end
		end
	end
	p.leapTarget = { x = tx, z = tz }
	local dur = math.clamp(n(a.duration, 0.5), 0.1, 1.5)
	p.invulnUntil = math.max(p.invulnUntil, now + dur)
	p.hoverUntil = math.max(p.hoverUntil, now + dur)
	w:emit({
		t = "ability",
		id = p.id,
		kind = "leap",
		fromX = p.x,
		fromZ = p.z,
		x = tx,
		z = tz,
		r = r,
		dur = dur,
		ascended = asc(a),
	})
	w:schedule(now + dur, p, function(_at: number)
		if p.downed or p.dead then
			return
		end
		w:teleportPlayer(p, tx, tz)
		w:emit({ t = "ability", id = p.id, kind = "leap_land", x = tx, z = tz, r = r, ascended = asc(a) })
		Weapons.explode(w, p, tx, tz, r, n(a.damage, 0) * n(p.stats.damageMult, 1), { knock = 6 })
	end)
end

-- Mark: marks up to MARK_MAX mice / foes in the area; after `duration` each one still
-- alive takes `damage`, and its pop splashes unmarked ones within MARK_POP_RADIUS for
-- half (each target is hit once at most, so dense packs don't multiply it).
ABILITY.mark = function(w, p, a, aimX, aimZ, now)
	local s = p.stats
	local x, z = aimPoint(p, aimX, aimZ, n(a.distance, 34))
	local r = n(a.area, 12) * n(s.areaMult, 1)
	local dur = n(a.duration, 1.5)
	local marked = {}
	local function add(e: any)
		if #marked < Weapons.MARK_MAX then
			table.insert(marked, e)
		end
	end
	w:forEnemiesInCircle(x, z, r, add)
	foesInCircle(w, p, x, z, r, add)
	w:emit({
		t = "ability",
		id = p.id,
		kind = "mark",
		x = x,
		z = z,
		r = r,
		dur = dur,
		n = #marked,
		ascended = asc(a),
	})
	if #marked == 0 then
		return
	end
	w:schedule(now + dur, p, function(_at: number)
		local dmg = n(a.damage, 0) * n(p.stats.damageMult, 1)
		local pr = Weapons.MARK_POP_RADIUS * n(p.stats.areaMult, 1)
		local fx = 0
		local hit: { [any]: boolean } = {}
		for _, e in marked do
			hit[e] = true
		end
		for _, e in marked do
			local live = e.alive ~= false and not e.dead
			if live then
				if fx < Weapons.MARK_FX_CAP then
					fx += 1
					w:emit({
						t = "ability",
						id = p.id,
						kind = "mark_pop",
						x = e.x,
						z = e.z,
						r = pr,
						ascended = asc(a),
					})
				end
				local ex, ez = e.x, e.z
				Weapons.hit(w, p, e, dmg, { knock = 3, fromX = x, fromZ = z })
				local function splash(o: any)
					if not hit[o] then
						hit[o] = true
						Weapons.hit(w, p, o, dmg * 0.5, { knock = 3, fromX = ex, fromZ = ez })
					end
				end
				w:forEnemiesInCircle(ex, ez, pr, splash)
				foesInCircle(w, p, ex, ez, pr, splash)
			end
		end
	end)
end
-- (end iteration 6, team Abilities)

function Weapons.abilityCooldown(stats: PlayerStats, a: AbilityDef): number
	return math.max(0.5, n(a.cooldown, 8) * n(stats.cooldownMult, 1))
end

-- Fires the player's ability (caller checks cooldown/standing). Returns false for an unknown kind.
-- (iteration 5) `ability` = the def of the slot being cast (default p.ability, slot 1).
function Weapons.useAbility(
	w: any,
	p: any,
	aimX: number,
	aimZ: number,
	now: number,
	ability: AbilityDef?,
	replay: boolean? -- (iteration 6 QC) an echo / Cataclysm repeat
): boolean
	local a: AbilityDef? = ability or p.ability
	if type(a) ~= "table" then
		return false
	end
	local fn = ABILITY[a.kind]
	if not fn then
		return false
	end
	fn(w, p, a, aimX, aimZ, now, replay)
	return true
end

Weapons.FIRE = FIRE
Weapons.ABILITY = ABILITY

return Weapons
