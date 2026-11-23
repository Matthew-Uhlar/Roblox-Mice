--!strict
-- Mouse Champions: pure logic (GDD-v2 §4b). Config/Champions.luau holds the data.
-- Combat/World owns the bodies (enemy records with isChampion = true) and calls:
--
--   Champions.newState()                 World.new
--   Champions.start(w) / Champions.stop(w)   World.startWaves / World.stopSpawning
--   Champions.update(w, dt, now)          World.step (director + leash / aggro / regen / evade)
--   Champions.onDamaged(w, e, dealt, by)  World.damageEnemy (squad damage, enrage, split)
--   Champions.onDeath(w, e, by)           World._killEnemy (rewards, Fx, events)
--   Champions.clear(w)                    World.clearEnemies (the boss start: champions leave)
--   Champions.list(w)                     World.champions (Match payload, bots, tests)
--   Champions.addSquadBuff(buffs, buff, now)  RunDirector + the headless sim (stacking buff)
--
-- Sites: the World's POI entities with mode "champion" (Pois.layout entries of
-- kind "champion_site" / "champion_lair"). A World without sites never spawns
-- champions (v1 worlds, tests, the sim with POIs off), and `opts.champions =
-- false` turns them off.
--
-- Body AI: a champion only attacks standing heroes within AGGRO of its body
-- that are also within LEASH + AGGRO of its site (`e.target`, BossPatterns sees
-- the same set through `aggro`). Nobody there: it walks home and, after
-- REGEN_DELAY s, heals (and forgets the squad damage once full). At
-- ENRAGE_FRAC hp it enrages once (phase-2 patterns, faster); the Mad Chemist
-- also splits into CLONES clones (champion bodies with `champOf`, snapshot
-- flag bit 3). Sniper Squeak teleports away when a hero gets within evadeRange.
--
-- Events (world:drainEvents; champion entity ids go in `champ`, never `id`):
--   championSpawn  {champ, champId, lair, x, z, site}
--   championEnrage {champ, champId, lair, x, z}
--   championDead   {champ, champId, lair, x, z, by?, squad?, killerSquad?, damageBySquad,
--                   ids (rewarded members), xp, cheese, buff = {kind, name, stat, mul,
--                   duration, untilT}, items = {item...}, stage, fightTime?}
--   (plus `xp` events per rewarded member, and gearPickup / gearSwapOffer from giveGear)
-- Fx (always sent): {t="champ", id, champId, x, z, phase="spawn"|"enrage"|"dead",
--   lair, name, site? (spawn), squad?/by? (dead: the rewarded squad), escaped? (dead:
--   left when the boss came)}, and {t="rally", id, x, z, r, dur, n} (Captain Whiskers).

local Config = require("../Config/Champions")
local PoiConfig = require("../Config/Pois")
local BossPatterns = require("./BossPatterns")
local Pois = require("./Pois")

local Champions = {}

-- Tunables World reads on its hot paths (Config/Champions is the source).
Champions.KNOCK_RESIST = Config.KNOCK_RESIST
Champions.SHIELD_MULT = Config.SHIELD_MULT
Champions.RALLY_SPEED = Config.RALLY_SPEED
Champions.RALLY_DAMAGE = Config.RALLY_DAMAGE

local TAU = math.pi * 2

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

export type State = {
	active: boolean,
	nextAt: number?, -- wave elapsed time of the next regular spawn
	lairAt: { number }, -- wave elapsed time per lair
	lairDone: { [number]: boolean },
	bodies: { any }, -- live main bodies (clones are not listed)
	spawned: number,
	killed: number,
}

function Champions.newState(): State
	return {
		active = false,
		nextAt = nil,
		lairAt = {},
		lairDone = {},
		bodies = {},
		spawned = 0,
		killed = 0,
	}
end

-- Sites -------------------------------------------------------------------------------------

-- The world's champion sites: (regular, lairs), POI entities in add order.
function Champions.sites(w: any): ({ any }, { any })
	local regular, lairs = {}, {}
	for _, e in w.poiList or {} do
		if e.mode == "champion" then
			local def = PoiConfig.get(e.kind)
			if def and def.lair then
				table.insert(lairs, e)
			else
				table.insert(regular, e)
			end
		end
	end
	return regular, lairs
end

local function siteState(w: any, site: any, busy: boolean)
	if not site then
		return
	end
	local state = if busy then "active" else "idle"
	if site.state ~= state then
		site.state = state
		w:emit(Pois.stateFx(site))
	end
end

-- Director -------------------------------------------------------------------------------------

-- Director times are tuned for REFERENCE_WAVE s waves; shorter waves (tests, a
-- short live-ops mode) scale them down so champions still appear.
function Champions.timeScale(w: any): number
	local d = if w.wave and finite(w.wave.duration) then w.wave.duration else Config.REFERENCE_WAVE
	return math.clamp(d / Config.REFERENCE_WAVE, 0.05, 1)
end

function Champions.start(w: any)
	local st: State = w.champ
	if w.champsOff then
		return
	end
	st.active = true
	local rng = w.champRng
	local k = Champions.timeScale(w)
	st.nextAt = rng:range(Config.FIRST[1], Config.FIRST[2]) * k
	st.lairAt = {}
	st.lairDone = {}
	for i, t in Config.LAIR_AT do
		st.lairAt[i] = (t + rng:range(-Config.LAIR_JITTER, Config.LAIR_JITTER)) * k
	end
end

function Champions.stop(w: any)
	local st: State = w.champ
	st.active = false
end

local function busySites(st: State): { [any]: boolean }
	local busy = {}
	for _, e in st.bodies do
		if e.alive and e.site then
			busy[e.site] = true
		end
	end
	return busy
end

local function aliveRegular(st: State): number
	local n = 0
	for _, e in st.bodies do
		if e.alive and not e.lair and not e.miniboss then
			n += 1
		end
	end
	return n
end

-- A champion type that is not alive right now (variety), else any.
local function pickType(w: any, st: State): string
	local alive = {}
	for _, e in st.bodies do
		if e.alive then
			alive[e.defId] = true
		end
	end
	local free = {}
	for _, id in Config.ORDER do
		if not alive[id] then
			table.insert(free, id)
		end
	end
	local list = if #free > 0 then free else Config.ORDER
	return w.champRng:pick(list)
end

-- Spawns champion `champId` at `site` (a POI entity, or {x, z}). Returns the body.
function Champions.spawn(w: any, champId: string, site: any, lair: boolean?): any?
	local def = Config.get(champId)
	if not def then
		return nil
	end
	local st: State = w.champ
	local mods = w.mods
	local isLair = lair == true
	local wave = w.wave
	local frac = if wave and wave.duration > 0 then math.clamp(wave.elapsed / wave.duration, 0, 1) else 0
	local hp = def.hp
		* (if finite(mods.bossHpMult) then mods.bossHpMult else 1)
		* Config.HP_SCALE
		* (1 + Config.HP_WAVE_GROWTH * frac)
		* (if isLair then Config.LAIR_HP_MULT else 1)
		* Config.levelHpMult(if type(w.levelForScaling) == "function" then w:levelForScaling() else nil)
	local dmgMult = (if finite(mods.bossDamageMult) then mods.bossDamageMult else 1)
		* (def.damageMult or 1)
		* (if isLair then Config.LAIR_DAMAGE_MULT else 1)
	local r = def.radius * (if isLair then Config.LAIR_RADIUS_MULT else 1)
	local x, z =
		w:clampToArena(if finite(site.x) then site.x else 0, if finite(site.z) then site.z else 0, r + 1)
	x, z = w:pushOutOfObstacles(x, z, r + 0.5)
	local now = w.now
	local e = {
		defId = def.id,
		def = def,
		kind = Config.KIND_OFFSET + (Config.INDEX[def.id] or 1),
		behavior = "champion",
		isChampion = true,
		lair = isLair,
		site = if site.id ~= nil then site else nil,
		homeX = x,
		homeZ = z,
		leash = Config.LEASH,
		aggro = Config.AGGRO,
		rng = w.champRng,
		dmgMult = dmgMult,
		elite = false,
		x = x,
		z = z,
		kvx = 0,
		kvz = 0,
		r = r,
		hp = hp,
		maxHp = hp,
		speed = def.speed * (if isLair then Config.LAIR_SPEED_MULT else 1),
		contact = def.contactDamage * dmgMult,
		xp = 0,
		slowUntil = 0,
		slowFactor = 1,
		phase = 1,
		patternList = def.patterns,
		openerDone = false,
		introUntil = now + Config.INTRO,
		introDone = false,
		busyUntil = now + Config.INTRO,
		gap = Config.GAP,
		gapMult = 1,
		lockedUntil = 0,
		telegraphUntil = now + Config.INTRO,
		dmgBySquad = {},
		target = nil :: any,
		idleSince = now,
		evadeReadyAt = 0,
		enraged = false,
	}
	w:_addEnemy(e) -- champions ignore the enemy cap (like camp packs)
	table.insert(st.bodies, e)
	st.spawned += 1
	siteState(w, e.site, true)
	w:emit({
		t = "tele",
		shape = "circle",
		x = x,
		z = z,
		r = r + 4,
		delay = Config.INTRO,
		style = "champIntro",
		src = e.id,
	})
	w:emit({
		t = "champ",
		id = e.id,
		champId = def.id,
		x = x,
		z = z,
		phase = "spawn",
		lair = isLair,
		name = def.name,
		site = if e.site then e.site.id else nil,
	})
	w:event({
		type = "championSpawn",
		champ = e.id,
		champId = def.id,
		lair = isLair,
		x = x,
		z = z,
		site = if e.site then e.site.id else nil,
	})
	return e
end

-- v4: champions spawn only inside the storm's next circle (toR), with their site
-- radius to spare. No storm: anywhere.
function Champions.inNextCircle(w: any, site: any): boolean
	local z = w.zoneState
	if not z then
		return true
	end
	local r = math.min(z.r, z.toR) - (site.r or 0)
	return (site.x - z.cx) ^ 2 + (site.z - z.cz) ^ 2 <= r * r
end

-- Iteration 1 (P-12): champions come to the squads. Of the free sites, one of the
-- NEAR_SITES nearest to a standing hero (random among them); no heroes: any.
Champions.NEAR_SITES = 2
function Champions.pickSite(w: any, free: { any }): any
	local standing = w.standing or {}
	if #standing == 0 or #free <= 1 then
		return w.champRng:pick(free)
	end
	local ranked = {}
	for _, s in free do
		local best = math.huge
		for _, p in standing do
			local d = (p.x - s.x) ^ 2 + (p.z - s.z) ^ 2
			if d < best then
				best = d
			end
		end
		table.insert(ranked, { s = s, d = best })
	end
	table.sort(ranked, function(a, b)
		return a.d < b.d
	end)
	return ranked[w.champRng:nextInt(1, math.min(Champions.NEAR_SITES, #ranked))].s
end

local function director(w: any, st: State)
	local wave = w.wave
	if not st.active or not wave.active then
		return
	end
	local t = wave.elapsed
	local k = Champions.timeScale(w)
	local last = wave.duration - Config.CUTOFF * k
	if t > last then
		return
	end
	local regular, lairs = Champions.sites(w)
	if #regular == 0 and #lairs == 0 then
		return
	end
	local busy = busySites(st)
	if st.nextAt and t >= st.nextAt and #regular > 0 then
		if aliveRegular(st) < Config.maxAlive(w.arenaRadius, w.stage) then
			local free = {}
			for _, s in regular do
				if not busy[s] and Champions.inNextCircle(w, s) then
					table.insert(free, s)
				end
			end
			if #free > 0 then
				local site = Champions.pickSite(w, free)
				Champions.spawn(w, pickType(w, st), site, false)
				busy[site] = true
				st.nextAt = t + w.champRng:range(Config.INTERVAL[1], Config.INTERVAL[2]) * k
			else
				st.nextAt = t + 3
			end
		else
			st.nextAt = t + 3 -- full: try again soon after one dies
		end
	end
	for i, site in lairs do
		local at = st.lairAt[i]
		if at and not st.lairDone[i] and t >= at and not busy[site] and Champions.inNextCircle(w, site) then
			st.lairDone[i] = true
			Champions.spawn(w, pickType(w, st), site, true)
		end
	end
end

-- Body AI --------------------------------------------------------------------------------------

-- The standing hero this champion fights: within AGGRO of its body and within
-- LEASH + AGGRO of its site; the nearest one.
local function pickTarget(w: any, e: any): any?
	local lim = e.aggro or Config.AGGRO
	local home = (e.leash or Config.LEASH) + lim
	local l2, h2 = lim * lim, home * home
	local best, bestD = nil, math.huge
	for _, p in w.standing do
		if not p.downed and not p.dead then
			local d = (p.x - e.x) ^ 2 + (p.z - e.z) ^ 2
			if d <= l2 and d < bestD and (p.x - e.homeX) ^ 2 + (p.z - e.homeZ) ^ 2 <= h2 then
				best, bestD = p, d
			end
		end
	end
	return best
end

-- Iteration 6 (team Flow): a regular champion idle for ROAM_AFTER s drifts its leash home
-- toward the nearest standing hero (Config ROAM_*). Minibosses patrol; clones follow.
local function roam(w: any, e: any, dt: number, now: number)
	if
		e.champOf
		or e.miniboss
		or not e.introDone
		or now - (e.idleSince or now) < (Config.ROAM_AFTER or math.huge)
	then
		return
	end
	local seek = Config.ROAM_SEEK or 0
	local best, bestD = nil, seek * seek
	for _, p in w.standing do
		if not p.downed and not p.dead then
			local d = (p.x - e.homeX) ^ 2 + (p.z - e.homeZ) ^ 2
			if d < bestD then
				best, bestD = p, d
			end
		end
	end
	if not best then
		return
	end
	local d = math.sqrt(bestD)
	local stop = Config.ROAM_STOP or 0
	if d <= stop then
		return
	end
	local step = math.min(d - stop, (Config.ROAM_SPEED or 0) * dt)
	local hx, hz = e.homeX + (best.x - e.homeX) / d * step, e.homeZ + (best.z - e.homeZ) / d * step
	if type(w.clampToArena) == "function" then
		hx, hz = w:clampToArena(hx, hz, e.r + 1)
	end
	e.homeX, e.homeZ = hx, hz
end

local function bodyAI(w: any, e: any, dt: number, now: number)
	local target = pickTarget(w, e)
	e.target = target
	if not target then
		roam(w, e, dt, now)
	end
	if target then
		e.idleSince = now
	elseif now - (e.idleSince or now) >= Config.REGEN_DELAY and e.hp < e.maxHp and not e.champOf then
		e.hp = math.min(e.maxHp, e.hp + e.maxHp * Config.REGEN_RATE * dt)
		if e.hp >= e.maxHp then
			e.dmgBySquad = {} -- fully healed: the fight starts over
			e.engagedAt = nil
		end
	end
	-- Sniper Squeak: a hero this close -> teleport away (cooldown)
	local evade = e.def.evadeRange
	if
		target
		and finite(evade)
		and now >= (e.evadeReadyAt or 0)
		and now >= (e.lockedUntil or 0)
		and not e.dash
		and not e.leap
		and e.introDone
		and (target.x - e.x) ^ 2 + (target.z - e.z) ^ 2 <= (evade + e.r) ^ 2
	then
		e.evadeReadyAt = now + Config.EVADE_COOLDOWN
		local d = BossPatterns.run(w, e, "sniper_evade", now)
		e.busyUntil = math.max(e.busyUntil or 0, now + d)
	end
end

-- Iteration 4 miniboss camps: spawn / respawn and patrol (Config/Champions.MINIBOSS).
local function minibossDirector(w: any, st: State, dt: number, now: number)
	if not st.active or not w.wave.active then
		return
	end
	local M = Config.MINIBOSS
	local k = Champions.timeScale(w)
	local idx = 0
	for _, camp in w.poiList or {} do
		if camp.mode == "miniboss" then
			idx += 1
			local body = camp.body
			if body and body.alive then
				-- patrol: the leash home walks round the camp
				camp.patrolA = (camp.patrolA or 0) + dt * M.patrolSpeed / M.patrolR
				body.homeX = camp.x + math.cos(camp.patrolA) * M.patrolR
				body.homeZ = camp.z + math.sin(camp.patrolA) * M.patrolR
			else
				if camp.respawnAt == nil then
					camp.respawnAt = now + M.firstAt * k
				end
				if now >= camp.respawnAt then
					local pick = camp.mbPick
					if not pick then
						pick =
							Config.MINIBOSSES[(idx + w.champRng:nextInt(0, #Config.MINIBOSSES - 1)) % #Config.MINIBOSSES + 1]
						camp.mbPick = pick
					end
					local e = Champions.spawn(w, pick.champId, camp, false)
					if e then
						e.miniboss = true
						e.name = pick.name
						e.camp = camp
						e.hp *= M.hpMult
						e.maxHp *= M.hpMult
						camp.body = e
						camp.respawnAt = math.huge
						w:emit({
							t = "champ",
							id = e.id,
							champId = pick.champId,
							x = e.x,
							z = e.z,
							phase = "miniboss",
							name = pick.name,
							site = camp.id,
						})
					end
				end
			end
		end
	end
end

-- A miniboss fell: rinds / whey / XP to every member of the top-damage squad, the camp
-- respawns it MINIBOSS.respawn s later. Event minibossDead.
function Champions.onMinibossDeath(w: any, e: any, by: any?)
	local M = Config.MINIBOSS
	local dmg, top = Champions.damageBySquad(e)
	local squad = top or (if by and type(by.squad) == "number" then by.squad else nil)
	local ids = {}
	if squad ~= nil then
		local rinds = M.rinds * (1 + 0.25 * ((w.stage or 1) - 1))
		for _, p in w.playerList do
			if p.squad == squad then
				table.insert(ids, p.id)
				if type(w._grantRinds) == "function" then
					w:_grantRinds(p, rinds * w:_rindMult(p), "miniboss")
					w:_grantWhey(p, M.whey, "miniboss")
				end
				w:event({ type = "xp", id = p.id, amount = M.xp * w:_xpMult(p) })
			end
		end
	end
	local camp = e.camp
	if camp then
		camp.body = nil
		camp.respawnAt = w.now + M.respawn
	end
	siteState(w, camp, false)
	w:emit({
		t = "champ",
		id = e.id,
		champId = e.defId,
		x = e.x,
		z = e.z,
		phase = "dead",
		squad = squad,
		by = if by then by.id else nil,
		miniboss = true,
	})
	w:event({
		type = "minibossDead",
		champ = e.id,
		champId = e.defId,
		name = e.name,
		x = e.x,
		z = e.z,
		by = if by then by.id else nil,
		squad = squad,
		damageBySquad = dmg,
		ids = ids,
		camp = if camp then camp.id else nil,
	})
end

function Champions.update(w: any, dt: number, now: number)
	local st: State = w.champ
	director(w, st)
	minibossDirector(w, st, dt, now)
	if #st.bodies == 0 then
		return
	end
	local keep = {}
	for _, e in st.bodies do
		if e.alive then
			table.insert(keep, e)
		end
	end
	st.bodies = keep
	for _, e in w.enemies do
		if e.alive and e.isChampion then
			bodyAI(w, e, dt, now)
		end
	end
end

-- Movement intent for World._moveEnemy: (mx, mz) unit or 0.
function Champions.steer(_w: any, e: any): (number, number)
	local target = e.target
	local x, z = e.x, e.z
	if target then
		local dx, dz = target.x - x, target.z - z
		local d = math.sqrt(dx * dx + dz * dz)
		if d < 1e-4 then
			return 0, 0
		end
		local keepD = e.def and e.def.keepDistance
		if finite(keepD) then
			if d > keepD then
				return dx / d, dz / d
			elseif d < keepD * 0.6 then
				return -dx / d, -dz / d
			end
			local side = if e.id % 2 == 0 then 1 else -1
			return -dz / d * 0.4 * side, dx / d * 0.4 * side
		end
		if d > e.r + 1.6 + 0.5 then
			return dx / d, dz / d
		end
		return 0, 0
	end
	-- nobody near: walk home
	local hx, hz = (e.homeX or x) - x, (e.homeZ or z) - z
	local hd = math.sqrt(hx * hx + hz * hz)
	if hd > 3 then
		return hx / hd, hz / hd
	end
	return 0, 0
end

-- Damage / enrage / death ------------------------------------------------------------------------

local function spawnClones(w: any, e: any)
	local def = e.def
	for i = 1, Config.CLONES do
		local a = i / Config.CLONES * TAU + w.champRng:range(-0.4, 0.4)
		local x, z = w:clampToArena(e.x + math.cos(a) * (e.r + 4), e.z + math.sin(a) * (e.r + 4), 3)
		x, z = w:pushOutOfObstacles(x, z, e.r * Config.CLONE_RADIUS_MULT)
		local hp = e.maxHp * Config.CLONE_HP_FRAC
		local c = {
			defId = e.defId,
			def = def,
			kind = e.kind,
			behavior = "champion",
			isChampion = true,
			champOf = e,
			lair = e.lair,
			site = nil,
			homeX = e.homeX,
			homeZ = e.homeZ,
			leash = e.leash,
			aggro = e.aggro,
			rng = w.champRng,
			dmgMult = e.dmgMult,
			elite = false,
			x = x,
			z = z,
			kvx = 0,
			kvz = 0,
			r = e.r * Config.CLONE_RADIUS_MULT,
			hp = hp,
			maxHp = hp,
			speed = e.speed * 1.15,
			contact = e.contact * 0.6,
			xp = 0,
			slowUntil = 0,
			slowFactor = 1,
			phase = 2,
			patternList = { "chemist_lob_small" },
			openerDone = true,
			busyUntil = w.now + 1,
			gap = Config.GAP * 1.5,
			gapMult = 1,
			lockedUntil = 0,
			telegraphUntil = 0,
			dmgBySquad = {},
			target = nil :: any,
			idleSince = w.now,
			evadeReadyAt = 0,
			enraged = true,
			introDone = true,
		}
		w:_addEnemy(c)
		w:emit({ t = "minion", id = c.id, of = e.id, x = x, z = z })
	end
end

function Champions.enrage(w: any, e: any)
	if e.enraged or e.champOf then
		return
	end
	e.enraged = true
	e.phase = 2
	e.patternList = e.def.phase2Patterns or e.def.patterns
	e.openerDone = false
	e.speed *= Config.ENRAGE_SPEED
	e.gapMult = (e.gapMult or 1) * Config.ENRAGE_GAP
	e.gap = Config.GAP * e.gapMult
	e.busyUntil = math.max(e.busyUntil or 0, w.now + 0.8)
	e.telegraphUntil = math.max(e.telegraphUntil or 0, w.now + 0.8)
	w:emit({
		t = "champ",
		id = e.id,
		champId = e.defId,
		x = e.x,
		z = e.z,
		phase = "enrage",
		lair = e.lair == true,
	})
	w:event({
		type = "championEnrage",
		champ = e.id,
		champId = e.defId,
		lair = e.lair == true,
		x = e.x,
		z = e.z,
	})
	if finite(e.def.splitAt) then
		spawnClones(w, e)
	end
end

-- World.damageEnemy, after the hp change: squad damage (credited to the main
-- body for clones) and the one-time enrage.
function Champions.onDamaged(w: any, e: any, dealt: number, by: any?)
	local main = e.champOf or e
	if by and type(by.squad) == "number" and dealt > 0 then
		main.dmgBySquad[by.squad] = (main.dmgBySquad[by.squad] or 0) + dealt
		main.engagedAt = main.engagedAt or w.now
	end
	main.idleSince = w.now
	if not e.champOf and not e.enraged and e.hp > 0 and e.hp <= e.maxHp * Config.ENRAGE_FRAC then
		Champions.enrage(w, e)
	end
end

-- Damage per squad ({[squad] = number}, copy) and the top squad.
function Champions.damageBySquad(e: any): ({ [number]: number }, number?)
	local out, top, topD = {}, nil, 0
	for sq, d in (e.dmgBySquad or {}) :: any do
		out[sq] = d
		if d > topD then
			top, topD = sq, d
		end
	end
	return out, top
end

-- World._killEnemy for a champion body. Clones just die. The main body pays
-- its squad reward (World side: gear and xp; RunDirector: cheese and the buff).
function Champions.onDeath(w: any, e: any, by: any?)
	if e.champOf then
		return
	end
	if e.miniboss then
		for _, c in w.enemies do
			if c.alive and c.champOf == e then
				w:_killEnemy(c, nil, true, true)
			end
		end
		Champions.onMinibossDeath(w, e, by)
		return
	end
	for _, c in w.enemies do
		if c.alive and c.champOf == e then
			w:_killEnemy(c, nil, true, true)
		end
	end
	local st: State = w.champ
	st.killed += 1
	siteState(w, e.site, false)
	local dmg, top = Champions.damageBySquad(e)
	local killerSquad = if by and type(by.squad) == "number" then by.squad else nil
	-- v4 (V4-A M2): the top-damage squad is rewarded (the killer's squad only when
	-- no squad dealt damage); RunDirector pays a different killer's Snatch bonus.
	local squad = top or killerSquad
	local stage = w.stage or 1
	local def = e.def
	local lair = e.lair == true
	local ids, items = {}, {}
	local xp = Config.xpReward(stage, lair)
	local cheese = Config.cheeseReward(stage, lair)
	local b = def.buff
	local duration = b.duration * (if lair then Config.LAIR_BUFF_MULT else 1)
	if squad ~= nil then
		local minRarity = Config.gearRarity(stage, lair)
		for _, p in w.playerList do
			if p.squad == squad then
				table.insert(ids, p.id)
				w:event({ type = "xp", id = p.id, amount = xp * w:_xpMult(p) })
				local item = if type(w._rollGear) == "function" then w:_rollGear(minRarity) else nil
				if item then
					table.insert(items, item)
					if p.dead then
						-- v4: dead members keep their share; World hands it over when they come back
						p.pendingGear = p.pendingGear or {}
						table.insert(p.pendingGear, item)
					else
						w:giveGear(p.id, item)
					end
				end
			end
		end
	end
	w:emit({
		t = "champ",
		id = e.id,
		champId = def.id,
		x = e.x,
		z = e.z,
		phase = "dead",
		lair = lair,
		squad = squad,
		by = if by then by.id else nil,
	})
	w:event({
		type = "championDead",
		champ = e.id,
		champId = def.id,
		lair = lair,
		x = e.x,
		z = e.z,
		by = if by then by.id else nil,
		squad = squad,
		killerSquad = killerSquad,
		damageBySquad = dmg,
		ids = ids,
		xp = if squad ~= nil then xp else 0,
		cheese = if squad ~= nil then cheese else 0,
		buff = if squad ~= nil
			then {
				kind = b.kind,
				name = b.name,
				stat = b.stat,
				mul = b.mul,
				duration = duration,
				untilT = w.now + duration,
			}
			else nil,
		items = items,
		stage = stage,
		fightTime = if e.engagedAt then w.now - e.engagedAt else nil, -- first hero hit -> death
		maxHp = e.maxHp,
	})
end

-- World.clearEnemies (the boss arrives): every champion still alive leaves, no reward.
function Champions.clear(w: any)
	local st: State = w.champ
	for _, e in st.bodies do
		if e.alive then
			w:emit({
				t = "champ",
				id = e.id,
				champId = e.defId,
				x = e.x,
				z = e.z,
				phase = "dead",
				lair = e.lair == true,
				escaped = true,
			})
			siteState(w, e.site, false)
		end
	end
	st.bodies = {}
end

-- Captain Whiskers' rally: mice (not bosses, not champions) within r get faster
-- and fiercer for `dur` s (World._moveEnemy / _contactDamage read rallyUntil).
function Champions.rally(w: any, caster: any, x: number, z: number, r: number, dur: number)
	local n = 0
	local untilT = w.now + dur
	local r2 = r * r
	for _, e in w.enemies do
		if e.alive and not e.isBoss and not e.isMinion and not e.isChampion then
			if (e.x - x) ^ 2 + (e.z - z) ^ 2 <= r2 then
				e.rallyUntil = untilT
				n += 1
			end
		end
	end
	w:emit({ t = "rally", id = caster and caster.id or nil, x = x, z = z, r = r, dur = dur, n = n })
	return n
end

-- Live champions (main bodies) for the Match payload, bots and tests.
function Champions.list(w: any): { { [string]: any } }
	local out = {}
	local st: State = w.champ
	for _, e in st.bodies do
		if e.alive then
			local dmg, top = Champions.damageBySquad(e)
			table.insert(out, {
				id = e.id,
				champId = e.defId,
				x = e.x,
				z = e.z,
				hpFrac = math.clamp(e.hp / e.maxHp, 0, 1),
				lair = e.lair == true,
				enraged = e.enraged == true,
				site = if e.site then e.site.id else nil,
				damageBySquad = dmg,
				topSquad = top,
			})
		end
	end
	return out
end

-- Stacking squad buff (Champion's Might stacks up to BUFF_STACKS): each stack is
-- its own Pois buff kind "<kind>#<n>" (Pois.applyBuffs never stacks one kind).
-- A free stack is filled; with every stack active the one expiring first is
-- refreshed. Returns the number of active stacks after the change.
function Champions.addSquadBuff(buffs: { any }, buff: any, now: number): number
	local base = tostring(buff.kind)
	local active: { [number]: any } = {}
	for _, b in buffs do
		if b.untilT > now then
			local k = tostring(b.kind)
			local n = tonumber(string.match(k, "^" .. base:gsub("%p", "%%%0") .. "#(%d+)$"))
			if n then
				active[n] = b
			end
		end
	end
	local slot = nil
	for i = 1, Config.BUFF_STACKS do
		if not active[i] then
			slot = i
			break
		end
	end
	if slot == nil then
		local soonest = math.huge
		for i = 1, Config.BUFF_STACKS do
			if active[i].untilT < soonest then
				soonest, slot = active[i].untilT, i
			end
		end
	end
	Pois.addBuff(buffs, {
		kind = base .. "#" .. tostring(slot),
		stat = buff.stat,
		mul = buff.mul,
		untilT = buff.untilT,
	}, now)
	local n = 0
	for _, b in buffs do
		if b.untilT > now and string.match(tostring(b.kind), "^" .. base:gsub("%p", "%%%0") .. "#%d+$") then
			n += 1
		end
	end
	return n
end

return Champions
