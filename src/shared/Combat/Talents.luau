--!strict
-- (iteration 6, team Talents) Run-time talent keystones and ascension mechanics. Pure:
-- operates on a Combat/World instance (typed `any`, no require cycle: World requires
-- this module, this module requires Weapons) and its hero records.
--
-- The mechanics are numeric stat fields (Config/Keystones.FIELDS: `tk*` from perk
-- nodes, `asc*` from Ascension nodes). Talents.refresh(p) runs on every stat change
-- (World._setStats) and builds p.tk (nil when the hero has no mechanic, so the hot
-- paths cost one nil check). World hooks, each guarded by `if p.tk`:
--   Talents.preWeapon(w, p, dt, now)    before Weapons.update (timers, auras, orbs,
--                                       novas, stomps; swaps in an empowered weapon)
--   Talents.postWeapon(w, p, now)       after it (counts attacks, frenzy attack speed)
--   Talents.onCast(w, p, a, slot, t, readyAt, aimX, aimZ) -> readyAt   (charges, combo,
--                                       guard, overcharge, shockwave, echo ghost)
--   Talents.onKill(w, by, e, fromExplosion)   (frenzy, heals, cooldown refunds, shards)
--   Talents.takenMult(p, now) -> number  (guard: damage from mice only)
--   Talents.onHurt(w, p, pvp, now)       (last stand, second wind, retaliate)
--   Talents.hitAmount(w, p, e, amount) -> number  (PvE hits only: combo, frenzy, execute)
--
-- Every mechanic's DAMAGE hits mice / champions / bosses only (forEnemiesInCircle,
-- never forFoesInCircle) and goes through Weapons.hit (pveDamageMult, lifesteal,
-- the meter) with fromExplosion = true (no kill-burst cascades).
-- Fx: {t = "tk", k = kind, id = hero, x?, z?, ...} (Visuals/TalentFx on the client);
-- k = "state" (no position, always sent) carries the persistent look: orbs, aura
-- radius, trail, frenzy, charges.

local K = require("../Config/Keystones")
local Weapons = require("./Weapons")

local Talents = {}

Talents.STATE_RESEND = 8 -- s between "state" Fx re-sends (late joiners)

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function standing(p: any): boolean
	return not p.downed and not p.dead
end

-- Rebuilds p.tk from p.stats (keeps the running timers).
function Talents.refresh(p: any)
	local s = p.stats
	if type(s) ~= "table" then
		p.tk = nil
		return
	end
	local c: { [string]: number }? = nil
	for field, lim in K.FIELDS do
		local v = s[field]
		if finite(v) and v > 0 then
			c = c or {}
			;(c :: any)[field] = math.clamp(v, lim[1], lim[2])
		end
	end
	if not c then
		if p.tk then
			p.tk = nil
			p.tkCleared = true -- the next step sends an empty "state"
		end
		return
	end
	local cfg = c :: { [string]: number }
	local tk = p.tk or {
		shots = 0,
		charged = 0,
		frenzy = 0,
		frenzyUntil = 0,
		auraAt = 0,
		orbAt = 0,
		novaAt = 0,
		stompAt = 0,
		lastStandAt = -math.huge,
		secondWindAt = -math.huge,
		retaliateAt = 0,
		comboUntil = 0,
		lastSlot = 0,
		lastCastAt = -math.huge,
		guardUntil = 0,
		cdBudget = 0,
		cdBudgetAt = 0,
		healKills = 0,
		healAt = 0,
		kills = {},
		killHead = 0,
		ascFrenzyUntil = 0,
		charges = 0,
		chargeRefillAt = 0,
		empUntil = 0,
		stateAt = 0,
		stateKey = "",
	}
	tk.c = cfg
	tk.empEvery = math.floor(cfg.tkEmpower or 0)
	tk.chargeN = math.floor((cfg.tkCharge or 0) + (cfg.ascOvercharge or 0))
	tk.orbs = math.floor((cfg.tkOrbs or 0) + (cfg.ascSpirit or 0))
	tk.maxCharges = math.floor(cfg.tkCharges or 0)
	if tk.charges > tk.maxCharges then
		tk.charges = tk.maxCharges
	end
	tk.orbit = p.weapon and p.weapon.kind == "orbit"
	tk.empSrc = nil -- the empowered weapon is rebuilt from the new p.derived
	p.tk = tk
end

-- Damage helpers ---------------------------------------------------------------------------

local function weaponDamage(p: any): number
	local d = p.derived
	local v = if d then (if p.weapon and p.weapon.kind == "orbit" then d.orbitDamage else d.damage) else 0
	return if finite(v) and v > 0 then v else 0
end

local function areaScale(p: any): number
	local a = p.stats and p.stats.areaMult
	return if finite(a) and a > 0 then math.sqrt(a) else 1
end

-- A circle of mechanic damage (mice only) with optional knockback; Fx kind `k`.
local function blast(w: any, p: any, x: number, z: number, r: number, dmg: number, knock: number, k: string)
	w:emit({ t = "tk", k = k, id = p.id, x = x, z = z, r = r })
	if dmg <= 0 and knock <= 0 then
		return
	end
	w:forEnemiesInCircle(x, z, r, function(e: any)
		if dmg > 0 then
			Weapons.hit(w, p, e, dmg, { knock = knock, fromX = x, fromZ = z, fromExplosion = true })
		elseif knock > 0 and e.alive and type(w.knockEnemy) == "function" then
			local dx, dz = e.x - x, e.z - z
			local m = math.sqrt(dx * dx + dz * dz)
			if m > 1e-6 then
				w:knockEnemy(e, dx / m, dz / m, knock)
			end
		end
	end)
end
Talents.blast = blast

-- Weapon empowerment ----------------------------------------------------------------------

local function empowered(tk: any, d: any): any
	if tk.empSrc ~= d or not tk.empDerived then
		local e = table.clone(d)
		e.damage = d.damage * K.EMPOWER_DAMAGE
		e.orbitDamage = d.orbitDamage * K.EMPOWER_DAMAGE
		e.radius = d.radius * K.EMPOWER_AREA
		e.bladeRadius = d.bladeRadius * K.EMPOWER_AREA
		e.knockback = d.knockback + 2
		tk.empSrc, tk.empDerived = d, e
	end
	return tk.empDerived
end

local function sendState(w: any, p: any, tk: any, now: number, force: boolean?)
	local c = tk.c
	local aura = if (c.tkAura or 0) > 0 then K.AURA_RADIUS * areaScale(p) else 0
	local frenzy = if now < tk.ascFrenzyUntil then 2 elseif tk.frenzy >= K.FRENZY_MAX then 1 else 0
	local key = string.format(
		"%d|%d|%d|%d|%d|%d|%d",
		tk.orbs,
		math.floor(aura * 10),
		if (c.ascTrail or 0) > 0 then 1 else 0,
		frenzy,
		tk.charges,
		if (c.ascSpirit or 0) > 0 then 1 else 0,
		if (c.ascStomp or 0) > 0 then 1 else 0
	)
	if not force and key == tk.stateKey and now < tk.stateAt then
		return
	end
	tk.stateKey = key
	tk.stateAt = now + Talents.STATE_RESEND
	w:emit({
		t = "tk",
		k = "state",
		id = p.id,
		orbs = tk.orbs,
		spirit = (c.ascSpirit or 0) > 0,
		aura = aura,
		trail = (c.ascTrail or 0) > 0,
		frenzy = frenzy,
		charges = tk.charges,
		ancient = (c.ascStomp or 0) > 0,
	})
end

-- Per-step timers (called from preWeapon) ----------------------------------------------

local function nearestTarget(w: any, p: any, range: number): any
	local list = w:nearestEnemies(p.x, p.z, range, 1)
	return list[1]
end

local function updateTimers(w: any, p: any, tk: any, now: number)
	local c = tk.c
	-- frenzy stacks fall off together
	if tk.frenzy > 0 and now >= tk.frenzyUntil then
		tk.frenzy = 0
	end
	-- charge refill (one at a time)
	if tk.charges < tk.maxCharges and tk.chargeRefillAt > 0 and now >= tk.chargeRefillAt then
		tk.charges += 1
		tk.chargeRefillAt = if tk.charges < tk.maxCharges then now + (tk.chargeCd or 8) else 0
		w:emit({ t = "tk", k = "charge", id = p.id, x = p.x, z = p.z, n = tk.charges })
	end
	-- aura
	local aura = c.tkAura or 0
	if aura > 0 and now >= tk.auraAt then
		tk.auraAt = now + K.AURA_TICK
		local dmg = weaponDamage(p) * aura * K.AURA_TICK
		if dmg > 0 then
			local r = K.AURA_RADIUS * areaScale(p)
			w:forEnemiesInCircle(p.x, p.z, r, function(e: any)
				Weapons.hit(w, p, e, dmg, { fromExplosion = true, noCrit = true })
			end)
		end
	end
	-- orbs / spirit calves: zap the nearest mouse
	if tk.orbs > 0 and now >= tk.orbAt then
		tk.orbAt = now + K.ORB_EVERY / tk.orbs
		local e = nearestTarget(w, p, K.ORB_RANGE)
		if e then
			local spirit = (c.ascSpirit or 0) > 0 and (tk.orbFlip or false)
			tk.orbFlip = not tk.orbFlip
			w:emit({ t = "tk", k = "orb", id = p.id, x = e.x, z = e.z, spirit = spirit })
			Weapons.hit(w, p, e, weaponDamage(p) * K.ORB_DAMAGE, { fromExplosion = true })
		end
	end
	-- nova
	local nova = c.tkNova or 0
	if nova > 0 then
		if tk.novaAt == 0 then
			tk.novaAt = now + nova
		elseif now >= tk.novaAt then
			tk.novaAt = now + nova
			blast(
				w,
				p,
				p.x,
				p.z,
				K.NOVA_RADIUS * areaScale(p),
				weaponDamage(p) * K.NOVA_DAMAGE,
				K.NOVA_KNOCK,
				"nova"
			)
		end
	end
	-- Ancient Stomp
	if (c.ascStomp or 0) > 0 then
		if tk.stompAt == 0 then
			tk.stompAt = now + K.STOMP_EVERY
		elseif now >= tk.stompAt then
			tk.stompAt = now + K.STOMP_EVERY
			blast(
				w,
				p,
				p.x,
				p.z,
				K.STOMP_RADIUS * areaScale(p),
				weaponDamage(p) * K.STOMP_DAMAGE,
				K.STOMP_KNOCK,
				"stomp"
			)
		end
	end
	sendState(w, p, tk, now)
end

-- Weapon hooks ------------------------------------------------------------------------------

function Talents.preWeapon(w: any, p: any, _dt: number, now: number)
	local tk = p.tk
	if not tk then
		if p.tkCleared then
			p.tkCleared = nil
			w:emit({ t = "tk", k = "state", id = p.id, orbs = 0, aura = 0, frenzy = 0, charges = 0 })
		end
		return
	end
	updateTimers(w, p, tk, now)
	tk.preReady = p.weaponReadyAt
	tk.empOn = false
	if p.derived == nil then
		return
	end
	local emp = false
	if tk.orbit then
		emp = now < tk.empUntil
	elseif now >= p.weaponReadyAt then
		emp = tk.charged > 0 or (tk.empEvery > 0 and (tk.shots + 1) % tk.empEvery == 0)
	end
	if emp then
		tk.baseDerived = p.derived
		p.derived = empowered(tk, p.derived)
		tk.empOn = true
	end
end

function Talents.postWeapon(w: any, p: any, now: number)
	local tk = p.tk
	if not tk then
		return
	end
	local wasEmp = tk.empOn
	if wasEmp then
		tk.empOn = false
		if p.derived == tk.empDerived then
			p.derived = tk.baseDerived
		end
	end
	if p.weaponReadyAt == tk.preReady then
		return -- did not fire
	end
	tk.shots += 1
	if wasEmp and not tk.orbit then
		if tk.charged > 0 then
			tk.charged -= 1
		end
		w:emit({ t = "tk", k = "emp", id = p.id, x = p.x, z = p.z })
	end
	local bonus = (tk.c.tkFrenzy or 0) * tk.frenzy
	if now < tk.ascFrenzyUntil then
		bonus += K.ASC_FRENZY_SPEED
	end
	if bonus > 0 and p.weaponReadyAt > now then
		p.weaponReadyAt = now + (p.weaponReadyAt - now) / (1 + bonus)
	end
end

-- Ability hook: returns the (possibly shorter) ready time of the cast slot.
function Talents.onCast(
	w: any,
	p: any,
	a: any,
	slot: number,
	t: number,
	readyAt: number,
	_aimX: number,
	_aimZ: number
): number
	local tk = p.tk
	if not tk then
		return readyAt
	end
	local c = tk.c
	-- extra charges of slot 1: spend one for a quick recast
	if slot == 1 and tk.maxCharges > 0 then
		tk.chargeCd = readyAt - t
		if tk.charges > 0 then
			tk.charges -= 1
			readyAt = t + K.CHARGE_GAP
			if tk.chargeRefillAt == 0 then
				tk.chargeRefillAt = t + tk.chargeCd
			end
		elseif tk.chargeRefillAt == 0 then
			tk.chargeRefillAt = t + tk.chargeCd
		end
	end
	-- empowered attacks after a cast (Momentum, Overcharge, ...)
	if tk.chargeN > 0 then
		if tk.orbit then
			tk.empUntil = math.max(tk.empUntil, t + tk.chargeN)
		else
			tk.charged = math.max(tk.charged, tk.chargeN)
		end
		w:emit({ t = "tk", k = "charged", id = p.id, x = p.x, z = p.z, n = tk.chargeN })
	end
	if (c.tkGuard or 0) > 0 then
		tk.guardUntil = t + K.GUARD_TIME
		w:emit({ t = "tk", k = "guard", id = p.id, x = p.x, z = p.z, dur = K.GUARD_TIME })
	end
	if (c.tkCombo or 0) > 0 and tk.lastSlot ~= 0 and slot ~= tk.lastSlot and t - tk.lastCastAt <= K.COMBO_WINDOW then
		tk.comboUntil = t + K.COMBO_TIME
		w:emit({ t = "tk", k = "combo", id = p.id, x = p.x, z = p.z, dur = K.COMBO_TIME })
	end
	tk.lastSlot, tk.lastCastAt = slot, t
	-- Ascension node 2: a shockwave ring from the hero
	if (c.ascWave or 0) > 0 then
		blast(
			w,
			p,
			p.x,
			p.z,
			K.WAVE_RADIUS * areaScale(p),
			weaponDamage(p) * K.WAVE_DAMAGE,
			K.WAVE_KNOCK,
			"wave"
		)
	end
	-- Ascension node 5: the echo shows as a ghostly double (World schedules the cast)
	if (c.ascEcho or 0) > 0 and finite(p.stats.abilityEcho) and p.stats.abilityEcho > 0 then
		local kind = if type(a) == "table" then a.kind else nil
		w:schedule(t + 0.5, p, function(_at: number)
			if standing(p) then
				w:emit({ t = "tk", k = "echo", id = p.id, x = p.x, z = p.z, ability = kind })
			end
		end)
	end
	return readyAt
end

-- Kill hook ---------------------------------------------------------------------------------

function Talents.onKill(w: any, by: any, e: any, fromExplosion: boolean?)
	local tk = by.tk
	if not tk or not standing(by) then
		return
	end
	local c = tk.c
	local now = w.now
	if (c.tkFrenzy or 0) > 0 then
		local was = tk.frenzy
		tk.frenzy = math.min(K.FRENZY_MAX, tk.frenzy + 1)
		tk.frenzyUntil = now + K.FRENZY_TIME
		if tk.frenzy == K.FRENZY_MAX and was < K.FRENZY_MAX then
			sendState(w, by, tk, now, true)
		end
	end
	local heal = c.tkKillHeal or 0
	if heal > 0 then
		if now >= tk.healAt then
			tk.healAt, tk.healKills = now + 1, 0
		end
		if tk.healKills < K.KILLHEAL_CAP then
			tk.healKills += 1
			w:_heal(by, by.maxHp * heal)
		end
	end
	local cut = c.tkCdKill or 0
	if cut > 0 then
		if now >= tk.cdBudgetAt then
			tk.cdBudgetAt, tk.cdBudget = now + 1, K.CDKILL_CAP
		end
		local s = math.min(cut, tk.cdBudget)
		if s > 0 then
			tk.cdBudget -= s
			by.abilityReadyAt = math.max(now, by.abilityReadyAt - s)
			if type(by.slotReadyAt) == "table" then
				for k, at in by.slotReadyAt do
					by.slotReadyAt[k] = math.max(now, at - s)
				end
			end
		end
	end
	if (c.ascFrenzy or 0) > 0 and now >= tk.ascFrenzyUntil then
		local n = K.ASC_FRENZY_KILLS
		tk.killHead = (tk.killHead % n) + 1
		tk.kills[tk.killHead] = now
		local oldest = tk.kills[(tk.killHead % n) + 1]
		if oldest and now - oldest <= K.ASC_FRENZY_WINDOW then
			tk.ascFrenzyUntil = now + K.ASC_FRENZY_TIME
			table.clear(tk.kills)
			w:emit({ t = "tk", k = "frenzy", id = by.id, x = by.x, z = by.z, dur = K.ASC_FRENZY_TIME })
			sendState(w, by, tk, now, true)
		end
	end
	local shards = math.floor(c.tkShards or 0)
	if shards > 0 and not fromExplosion then
		local dmg = weaponDamage(by) * K.SHARD_DAMAGE
		local got = {}
		w:forEnemiesInCircle(e.x, e.z, K.SHARD_RANGE, function(o: any)
			if #got < shards and o ~= e and o.alive then
				table.insert(got, o)
			end
		end)
		if #got > 0 then
			local to = {}
			for _, o in got do
				table.insert(to, math.floor(o.x * 10 + 0.5) / 10)
				table.insert(to, math.floor(o.z * 10 + 0.5) / 10)
			end
			w:emit({ t = "tk", k = "shard", id = by.id, x = e.x, z = e.z, to = to })
			for _, o in got do
				Weapons.hit(w, by, o, dmg, { fromExplosion = true })
			end
		end
	end
end

-- Damage taken ----------------------------------------------------------------------------

-- x damage from mice / champions / bosses (guard). 1 without talents.
function Talents.takenMult(p: any, now: number): number
	local tk = p.tk
	if tk and now < tk.guardUntil then
		return 1 - (tk.c.tkGuard or 0)
	end
	return 1
end

-- After a hero lost HP (still standing).
function Talents.onHurt(w: any, p: any, pvp: boolean, now: number)
	local tk = p.tk
	if not tk or p.hp <= 0 then
		return
	end
	local c = tk.c
	local frac = p.hp / math.max(1, p.maxHp)
	if (c.ascSecondWind or 0) > 0 and frac < K.SECOND_WIND_BELOW and now - tk.secondWindAt >= K.SECOND_WIND_CD then
		tk.secondWindAt = now
		w:_heal(p, p.maxHp * K.SECOND_WIND_HEAL)
		p.invulnUntil = math.max(p.invulnUntil or 0, now + K.SECOND_WIND_INVULN)
		blast(w, p, p.x, p.z, K.SECOND_WIND_RADIUS, weaponDamage(p), 9, "secondWind")
		return
	end
	local ls = c.tkLastStand or 0
	if ls > 0 and frac < K.LASTSTAND_BELOW and now - tk.lastStandAt >= K.LASTSTAND_CD then
		tk.lastStandAt = now
		w:_heal(p, p.maxHp * ls)
		p.invulnUntil = math.max(p.invulnUntil or 0, now + K.LASTSTAND_INVULN)
		blast(w, p, p.x, p.z, K.LASTSTAND_RADIUS, 0, 8, "lastStand")
		return
	end
	local ret = c.tkRetaliate or 0
	if ret > 0 and not pvp and now >= tk.retaliateAt then
		tk.retaliateAt = now + K.RETALIATE_CD
		blast(w, p, p.x, p.z, K.RETALIATE_RADIUS * areaScale(p), weaponDamage(p) * ret, 4, "retaliate")
	end
end

-- PvE hit amount (Weapons.hit, after crits; never called for heroes).
function Talents.hitAmount(w: any, p: any, e: any, amount: number): number
	local tk = p.tk
	if not tk then
		return amount
	end
	local c = tk.c
	local now = w.now
	if now < tk.comboUntil then
		amount *= 1 + (c.tkCombo or 0)
	end
	if now < tk.ascFrenzyUntil then
		amount *= 1 + K.ASC_FRENZY_DAMAGE
	end
	local ex = c.tkExecute or 0
	if ex > 0 and not e.isBoss and not e.isChampion and finite(e.maxHp) and e.hp - amount < e.maxHp * ex then
		if amount < e.hp then
			amount = e.hp
			w:emit({ t = "tk", k = "execute", id = p.id, x = e.x, z = e.z })
		end
	end
	return amount
end

return Talents
