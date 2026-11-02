--!strict
-- Points of interest: pure logic (GDD §3.8). Config/Pois.luau holds the data.
--
-- Stage setup (RunDirector, ArenaBuilder and the headless sim share these, so the
-- parts and the simulation agree on every position):
--   Pois.rollStage(rng, mapId) -> {kindId}        Maps.rollPois + one rare roll per stage
--   Pois.layout(rng, mapId, radius?) -> {{kind, x, z, r, slot}}
--
-- Live POIs are plain entities owned by Combat/World (world:addPoi / world:pois):
--   { id, kind, x, z, r, state = "idle" | "active" | "done", progress = 0..1,
--     usedBy = {participantId}, active = waves running, mode, pack?, traps? }
-- World.step calls Pois.update(world, dt, now), which drives:
--   channel  standing heroes in range fill `progress` (several fill it faster;
--            a hero hurt in the last HURT_PAUSE s does not count; with nobody in
--            range it decays). At 1: world-side reward + events, state "done".
--   camp     a hero in range wakes the pack (state "active"); the last elite's
--            death opens the chest (reward once, state "done").
--   hazard   traps arm when a mouse or a hero steps close, telegraph, then snap
--            everything in TRAP_RADIUS (both sides).
-- Nothing runs while the waves are not active (Boss, StageClear, votes).
--
-- World events (world:drainEvents):
--   {type="poiProgress", poi, kind, amount}            each 10% step
--   {type="poiActivated", poi, kind, by, x, z}         channel done / camp woken / chest opened
--   {type="poiReward", poi, kind, by, x, z, ids, cheese?, buff?, xp?, revived?, cards?}
-- Fx: {t="poi", id, kind, x, z, r, state, active, p}, {t="poiProgress", id, p},
--     {t="poiDone", id, kind, x, z, by, dur?, untilT?, chest?}, {t="trap", id, x, z, r}
--     and the trap telegraph {t="tele", shape="circle", style="trap", ...}.
--
-- Meta rewards (pending cheese, timed stat buffs, upgrade picks, discoveries) are
-- RunDirector's job; Pois.applyBuffs / Pois.epicCards are the shared helpers.

local Rng = require("../Util/Rng")
local Types = require("../Types")
local Maps = require("../Config/Maps")
local Config = require("../Config/Pois")
local UpgradeOffers = require("../Run/UpgradeOffers")

type Rng = Rng.Rng
type PlayerStats = Types.PlayerStats
type UpgradeDef = Types.UpgradeDef

export type LayoutEntry = {
	kind: string,
	x: number,
	z: number,
	r: number,
	slot: number,
	traps: { { x: number, z: number } }?, -- Mousetrap Field trap spots (ArenaBuilder builds them)
}
export type Buff = {
	kind: string,
	stat: string,
	mul: number?,
	addFracMaxHp: number?,
	untilT: number,
}

local Pois = {}

Pois.PLAYER_PAD = 0.8 -- a hero counts as "in" a POI when its centre is within r + this

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Stage setup ------------------------------------------------------------------------

-- Every slot from the map's table, then ONE rare roll for the whole stage
-- (Config.RARES, mutually exclusive): a hit replaces a random slot.
function Pois.rollStage(rng: Rng, mapId: string): { string }
	local ids = Maps.rollPois(rng, mapId)
	local roll = rng:nextFloat()
	local acc = 0
	for _, rare in Config.RARES do
		acc += rare.chance
		if roll < acc then
			ids[rng:nextInt(1, #ids)] = rare.id
			break
		end
	end
	return ids
end

-- Arena radius of a map, by ArenaBuilder's rule (size >= 40, else 120).
function Pois.arenaRadius(mapId: string): number
	local def = Maps.get(mapId)
	return if def and type(def.size) == "number" and def.size >= 40 then def.size else 120
end

-- Trap spots inside a Mousetrap Field (deterministic for the rng).
function Pois.trapLayout(rng: Rng, x: number, z: number, r: number, n: number): { { x: number, z: number } }
	local out = {}
	local inner = math.max(0, r - Config.TRAP_RADIUS)
	for i = 1, n do
		-- one in the middle, the rest on a jittered ring
		if i == 1 then
			table.insert(out, { x = x, z = z })
		else
			local a = (i - 2) / math.max(1, n - 1) * math.pi * 2 + rng:range(-0.3, 0.3)
			local d = inner * rng:range(0.55, 1)
			table.insert(out, { x = x + math.cos(a) * d, z = z + math.sin(a) * d })
		end
	end
	return out
end

-- Slots on a ring between the boss pad and the rim (0.55..0.8 R), evenly spread
-- with a little jitter; Mousetrap Fields get their trap spots too. ArenaBuilder
-- builds the parts and World:addPoi runs the logic at exactly these points.
function Pois.layout(rng: Rng, mapId: string, radius: number?): { LayoutEntry }
	local R = radius or Pois.arenaRadius(mapId)
	local ids = Pois.rollStage(rng, mapId)
	local out: { LayoutEntry } = {}
	local a0 = rng:range(0, math.pi * 2)
	for i, kind in ids do
		local a = a0 + (i - 1) / #ids * math.pi * 2 + rng:range(-0.15, 0.15)
		local d = R * rng:range(0.55, 0.8)
		local def = Config.get(kind)
		local x, z = math.cos(a) * d, math.sin(a) * d
		local r = if def then def.radius else 6
		local entry: LayoutEntry = { kind = kind, x = x, z = z, r = r, slot = i }
		if def and def.mode == "hazard" then
			entry.traps = Pois.trapLayout(rng, x, z, r, Config.TRAPS)
		end
		table.insert(out, entry)
	end
	return out
end

-- Pure channel maths ------------------------------------------------------------------

-- Channel speed multiplier for `n` heroes channelling together.
function Pois.channelRate(n: number): number
	if n <= 0 then
		return 0
	end
	return math.min(1 + Config.MULTI_USER_BONUS * (n - 1), Config.MULTI_USER_MAX)
end

-- New progress after `dt`: `contributing` heroes channel, `inRange` heroes stand
-- inside (a hurt hero is in range but not contributing: progress holds), nobody
-- in range -> decay.
function Pois.advance(
	progress: number,
	channel: number,
	contributing: number,
	inRange: number,
	dt: number
): number
	if contributing > 0 then
		return math.min(1, progress + dt / math.max(0.05, channel) * Pois.channelRate(contributing))
	elseif inRange > 0 then
		return progress
	end
	return math.max(0, progress - Config.DECAY_RATE * dt)
end

-- Entities -----------------------------------------------------------------------------

-- A fresh entity for world:addPoi. `id` is assigned by the world.
function Pois.newEntity(id: number, spec: any, rng: Rng): any
	local kind = tostring(spec.kind)
	local def = Config.get(kind)
	local r = if finite(spec.r) and spec.r > 0 then spec.r elseif def then def.radius else 6
	local e = {
		id = id,
		kind = kind,
		x = if finite(spec.x) then spec.x else 0,
		z = if finite(spec.z) then spec.z else 0,
		r = r,
		state = "idle",
		progress = 0,
		usedBy = {},
		active = false,
		mode = if def then def.mode else "channel",
		channel = if def and def.channel then def.channel else 3,
		step = 0, -- last reported progress step
		pack = 0,
		traps = nil :: any,
	}
	if e.mode == "hazard" then
		local traps = {}
		local spots = if type(spec.traps) == "table" and #spec.traps > 0
			then spec.traps
			else Pois.trapLayout(rng, e.x, e.z, r, Config.TRAPS)
		for _, t in spots do
			table.insert(traps, { x = t.x, z = t.z, armAt = nil :: number?, readyAt = 0 })
		end
		e.traps = traps
	end
	return e
end

-- JSON-safe state Fx for one POI.
function Pois.stateFx(e: any): { [string]: any }
	return {
		t = "poi",
		id = e.id,
		kind = e.kind,
		x = e.x,
		z = e.z,
		r = e.r,
		state = e.state,
		active = e.active,
		p = math.floor(e.progress * 100 + 0.5) / 100,
	}
end

-- Copy for world:pois() (bots, HUD, tests).
function Pois.copy(e: any): { [string]: any }
	local traps = nil
	if e.traps then
		traps = {}
		for _, t in e.traps do
			table.insert(traps, { x = t.x, z = t.z, armed = t.armAt ~= nil })
		end
	end
	return {
		id = e.id,
		kind = e.kind,
		x = e.x,
		z = e.z,
		r = e.r,
		state = e.state,
		progress = e.progress,
		usedBy = table.clone(e.usedBy),
		active = e.active,
		mode = e.mode,
		pack = e.pack,
		traps = traps,
	}
end

-- Update (called from World.step) ------------------------------------------------------

local function allIds(w: any): { number }
	local ids = {}
	for _, p in w.playerList do
		table.insert(ids, p.id)
	end
	return ids
end

local function markUser(e: any, id: number)
	if not table.find(e.usedBy, id) then
		table.insert(e.usedBy, id)
	end
end

local function reportProgress(w: any, e: any)
	local step = math.floor(e.progress / Config.PROGRESS_STEP + 1e-6)
	if step ~= e.step then
		e.step = step
		local p = step * Config.PROGRESS_STEP
		w:emit({ t = "poiProgress", id = e.id, p = math.floor(p * 100 + 0.5) / 100 })
		w:event({ type = "poiProgress", poi = e.id, kind = e.kind, amount = p })
	end
end

local function setState(w: any, e: any, state: string)
	if e.state ~= state then
		e.state = state
		w:emit(Pois.stateFx(e))
	end
end

-- World-side reward of a finished channel / opened chest, then the events.
-- `fled`: an Elite Camp whose pack was still alive when the waves ended.
local function complete(w: any, e: any, by: number?, fled: boolean?)
	local def = Config.get(e.kind)
	e.progress = 1
	e.state = "done"
	local now = w.now
	local reward: { [string]: any } = {
		type = "poiReward",
		poi = e.id,
		kind = e.kind,
		by = by,
		x = e.x,
		z = e.z,
		ids = allIds(w),
		fled = if fled then true else nil,
	}
	local done: { [string]: any } = { t = "poiDone", id = e.id, kind = e.kind, x = e.x, z = e.z, by = by }
	local kindOfReward = if def then def.reward else "none"
	if kindOfReward == "cheese" then
		reward.cheese = Config.cacheCheese(e.kind, w.cycle, w.stage)
		done.cheese = reward.cheese
	elseif kindOfReward == "buff" and def then
		if def.heal and def.heal > 0 then
			for _, p in w.playerList do
				w:healPlayer(p.id, def.heal)
			end
		end
		local b = def.buff
		if b then
			reward.buff = {
				kind = e.kind,
				stat = b.stat,
				mul = b.mul,
				addFracMaxHp = b.addFracMaxHp,
				duration = b.duration,
				untilT = now + b.duration,
			}
			done.dur = b.duration
			done.untilT = now + b.duration
		end
	elseif kindOfReward == "crumbs" then
		local total = Config.fountainXp(w.cycle, w.stage)
		local n = Config.FOUNTAIN_CRUMBS
		for i = 1, n do
			local a = i / n * math.pi * 2
			local d = 2.5 + (i % 3) * 1.5
			w:spawnPickup(e.x + math.cos(a) * d, e.z + math.sin(a) * d, total / n)
		end
		reward.xp = total
	elseif kindOfReward == "revive" then
		local revived = 0
		for _, p in w.playerList do
			if p.downed or p.dead then
				revived += 1
				w:_revive(p, w.REVIVE_HP or 0.4, "statue")
			end
			p.secondWindUsed = false
		end
		reward.revived = revived
	elseif kindOfReward == "elite_chest" then
		done.chest = true
	elseif kindOfReward == "epic_pick" then
		reward.cards = Config.EPIC_CARDS
	end
	w:emit({
		t = "poi",
		id = e.id,
		kind = e.kind,
		x = e.x,
		z = e.z,
		r = e.r,
		state = "done",
		active = e.active,
		p = 1,
	})
	w:emit(done)
	if e.mode ~= "camp" then
		w:event({ type = "poiActivated", poi = e.id, kind = e.kind, by = by, x = e.x, z = e.z })
	end
	w:event(reward)
end

local function inRangeOf(w: any, e: any, now: number): ({ any }, { any })
	local inside, channelling = {}, {}
	local rr = e.r + Pois.PLAYER_PAD
	local r2 = rr * rr
	for _, p in w.standing do
		if not p.downed and not p.dead and (p.x - e.x) ^ 2 + (p.z - e.z) ^ 2 <= r2 then
			table.insert(inside, p)
			if now - (p.lastHurtAt or -math.huge) >= Config.HURT_PAUSE then
				table.insert(channelling, p)
			end
		end
	end
	return inside, channelling
end

local function updateChannel(w: any, e: any, dt: number, now: number)
	if e.state == "done" then
		return
	end
	local inside, channelling = inRangeOf(w, e, now)
	local before = e.progress
	e.progress = Pois.advance(e.progress, e.channel, #channelling, #inside, dt)
	for _, p in channelling do
		markUser(e, p.id)
	end
	if e.progress >= 1 then
		local by = if #channelling > 0 then channelling[1].id else e.usedBy[1]
		complete(w, e, by)
		return
	end
	if e.progress > 0 and before == 0 then
		setState(w, e, "active")
	elseif e.progress <= 0 and before > 0 then
		setState(w, e, "idle")
	end
	reportProgress(w, e)
end

local function wakeCamp(w: any, e: any, by: number)
	local n = Config.campPack(w.cycle, w.stage)
	local spawned = 0
	local cap = w.cap
	w.cap = math.huge -- the pack is the camp's own, never refused by the wave cap
	for i = 1, n do
		local a = i / n * math.pi * 2
		local x = e.x + math.cos(a) * Config.CAMP_SPREAD
		local z = e.z + math.sin(a) * Config.CAMP_SPREAD
		local ok, enemy = pcall(w.spawnEnemy, w, nil, x, z, true)
		if ok and enemy then
			enemy.poiId = e.id
			spawned += 1
		end
	end
	w.cap = cap
	e.pack = spawned
	markUser(e, by)
	setState(w, e, "active")
	w:event({ type = "poiActivated", poi = e.id, kind = e.kind, by = by, x = e.x, z = e.z })
	if spawned == 0 then
		complete(w, e, by)
	end
end

local function updateCamp(w: any, e: any, now: number)
	if e.state ~= "idle" then
		return
	end
	local wave = w.wave
	if wave.duration - wave.elapsed < Config.CAMP_WAKE_CUTOFF then
		return -- too late in the waves to fight a pack (Config.CAMP_WAKE_CUTOFF)
	end
	local inside = inRangeOf(w, e, now)
	if #inside > 0 then
		wakeCamp(w, e, inside[1].id)
	end
end

-- Called by World._killEnemy for an enemy with poiId (any killer, traps included).
function Pois.onPackKill(w: any, enemy: any)
	local e = w.poiById and w.poiById[enemy.poiId]
	if not e or e.state ~= "active" then
		return
	end
	e.pack = math.max(0, e.pack - 1)
	if e.pack == 0 and e.active then
		complete(w, e, e.usedBy[1])
	end
end

local function updateHazard(w: any, e: any, now: number)
	local hpMult = w.mods.enemyHpMult or 1
	local dmgMult = w.mods.enemyDamageMult or 1
	local trig = Config.TRAP_TRIGGER
	for i, t in e.traps do
		if t.armAt then
			if now >= t.armAt then
				t.armAt = nil
				t.readyAt = now + Config.TRAP_REARM
				local r = Config.TRAP_RADIUS
				local victims = {}
				w:forEnemiesInCircle(t.x, t.z, r, function(en: any)
					if not en.isBoss then
						table.insert(victims, en)
					end
				end)
				for _, en in victims do
					w:damageEnemy(en, Config.TRAP_ENEMY_DAMAGE * hpMult, nil, false, true)
				end
				w:damagePlayersCircle(t.x, t.z, r, Config.TRAP_PLAYER_DAMAGE * dmgMult, "trap")
				w:emit({ t = "trap", id = e.id, n = i, x = t.x, z = t.z, r = r })
			end
		elseif now >= t.readyAt then
			local hit = false
			local pr = trig + Pois.PLAYER_PAD
			for _, p in w.standing do
				if (p.x - t.x) ^ 2 + (p.z - t.z) ^ 2 <= pr * pr then
					hit = true
					break
				end
			end
			if not hit then
				w:forEnemiesInCircle(t.x, t.z, trig, function(en: any)
					if not en.isBoss then
						hit = true
					end
				end)
			end
			if hit then
				t.armAt = now + Config.TRAP_DELAY
				w:telegraph(nil, {
					t = "tele",
					shape = "circle",
					x = t.x,
					z = t.z,
					r = Config.TRAP_RADIUS,
					delay = Config.TRAP_DELAY,
					style = "trap",
					poi = e.id,
				})
			end
		end
	end
end

function Pois.update(w: any, dt: number, now: number)
	local list = w.poiList
	if not list or #list == 0 then
		return
	end
	local live = w.wave.active == true
	if live ~= w.poisLive then
		w.poisLive = live
		for _, e in list do
			e.active = live
			if not live and e.traps then
				for _, t in e.traps do
					t.armAt = nil -- a trap armed as the waves end never snaps
				end
			end
			w:emit(Pois.stateFx(e))
		end
		if not live then
			-- Waves over: a woken camp's pack flees (the boss start clears the
			-- field) and leaves its chest rather than losing it silently.
			for _, e in list do
				if e.mode == "camp" and e.state == "active" then
					e.pack = 0
					complete(w, e, e.usedBy[1], true)
				end
			end
		end
		w.poiResyncAt = now + Config.RESYNC
	elseif live and now >= (w.poiResyncAt or 0) then
		-- periodic full state (a client that missed the first batch catches up).
		-- Only during waves: after them the old world keeps stepping through the
		-- boss and the votes, and a resync then would re-create marks the client
		-- already cleared for the next arena (ghost rings, FINAL-A m2).
		w.poiResyncAt = now + Config.RESYNC
		for _, e in list do
			w:emit(Pois.stateFx(e))
		end
	end
	if not live then
		return
	end
	for _, e in list do
		if e.mode == "channel" then
			updateChannel(w, e, dt, now)
		elseif e.mode == "camp" then
			updateCamp(w, e, now)
		elseif e.mode == "hazard" then
			updateHazard(w, e, now)
		end
	end
end

-- Meta helpers (RunDirector + headless sim) --------------------------------------------

-- Stats with the active timed buffs applied (a copy; `stats` is not touched).
-- Expired buffs (untilT <= now) are ignored. Same-kind buffs do not stack.
function Pois.applyBuffs(stats: PlayerStats, buffs: { Buff }?, now: number): PlayerStats
	if not buffs or #buffs == 0 then
		return stats
	end
	local out = table.clone(stats) :: any
	local seen: { [string]: boolean } = {}
	for _, b in buffs do
		if b.untilT > now and not seen[b.kind] then
			seen[b.kind] = true
			local v = out[b.stat]
			if type(v) == "number" then
				if b.mul then
					v *= b.mul
				end
				if b.addFracMaxHp then
					v += b.addFracMaxHp * (out.maxHp or 100)
				end
				out[b.stat] = v
			end
		end
	end
	return out :: PlayerStats
end

-- Adds or refreshes a buff (same kind: the later expiry wins). Drops expired ones.
function Pois.addBuff(buffs: { Buff }, buff: Buff, now: number)
	for i = #buffs, 1, -1 do
		local b = buffs[i]
		if b.untilT <= now or b.kind == buff.kind then
			table.remove(buffs, i)
		end
	end
	table.insert(buffs, buff)
end

-- True when any buff expired by `now` (the caller recomputes stats, then prunes).
function Pois.pruneBuffs(buffs: { Buff }, now: number): boolean
	local changed = false
	for i = #buffs, 1, -1 do
		if buffs[i].untilT <= now then
			table.remove(buffs, i)
			changed = true
		end
	end
	return changed
end

-- Grandma's Pantry: `count` Epic cards this hero can still take (Legendary then
-- Rare fill in when the Epic pool runs dry). Unique within the offer.
function Pois.epicCards(
	rng: Rng,
	classId: string,
	stacks: { [string]: number },
	count: number?
): { UpgradeDef }
	local want = count or Config.EPIC_CARDS
	local byRarity: { [string]: { UpgradeDef } } = { Epic = {}, Legendary = {}, Rare = {}, Common = {} }
	for _, def in UpgradeOffers.eligible(classId, stacks) do
		local bucket = byRarity[def.rarity]
		if bucket then
			table.insert(bucket, def :: any)
		end
	end
	local out: { UpgradeDef } = {}
	for _, rarity in { "Epic", "Legendary", "Rare", "Common" } do
		local bucket = byRarity[rarity]
		while #out < want and #bucket > 0 do
			table.insert(out, table.remove(bucket, rng:nextInt(1, #bucket)) :: UpgradeDef)
		end
	end
	return out
end

return Pois
