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
-- (x World.PVP_MULT, never crits, no knockback). Auto-weapons aim with
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
local function targetsFor(w: any, p: any, range: number, count: number): { any }
	if type(w.targetsFor) == "function" then
		return w:targetsFor(p, range, count)
	end
	return w:nearestEnemies(p.x, p.z, range, count)
end

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
	if e.isHero then
		return Weapons.hitHero(w, p, e, base, opts)
	end
	if not e.alive then
		return 0
	end
	local s = p.stats
	local crit = not (opts and opts.noCrit) and w.rng:chance(n(s.critChance, 0))
	local amount = base * (if crit then n(s.critMult, 1.5) else 1)
	local sq = w.squadDmg and w.squadDmg[p.squad]
	if sq then
		amount *= sq
	end
	local dealt = w:damageEnemy(e, amount, p, crit, opts and opts.fromExplosion)
	if dealt <= 0 then
		return 0
	end
	local burn = n(s.burnDps, 0)
	if burn > 0 and e.alive then
		local now = w.now
		e.burnDps =
			math.max(if (e.burnUntil or 0) > now then n(e.burnDps, 0) else 0, burn * n(s.damageMult, 1))
		if (e.burnUntil or 0) <= now then
			e.burnTick = now + Weapons.BURN_TICK
		end
		e.burnUntil = now + Weapons.BURN_TIME
		e.burnBy = p
	end
	local slow = n(s.slowOnHit, 0)
	if slow > 0 and e.alive and not e.isBoss then
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

local ABILITY: { [string]: (w: any, p: any, a: AbilityDef, aimX: number, aimZ: number, now: number) -> () } =
	{}

-- Stampede: dash toward aim, damaging + knocking back along the path; brief invulnerability.
ABILITY.dash = function(w, p, a, aimX, aimZ, now)
	local s = p.stats
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
	if dmg > 0 then
		foesInCircle(w, p, p.x, p.z, r, function(h)
			Weapons.hit(w, p, h, dmg, nil)
		end)
	end
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

function Weapons.abilityCooldown(stats: PlayerStats, a: AbilityDef): number
	return math.max(0.5, n(a.cooldown, 8) * n(stats.cooldownMult, 1))
end

-- Fires the player's ability (caller checks cooldown/standing). Returns false for an unknown kind.
function Weapons.useAbility(w: any, p: any, aimX: number, aimZ: number, now: number): boolean
	local a: AbilityDef = p.ability
	local fn = ABILITY[a.kind]
	if not fn then
		return false
	end
	fn(w, p, a, aimX, aimZ, now)
	return true
end

Weapons.FIRE = FIRE
Weapons.ABILITY = ABILITY

return Weapons
