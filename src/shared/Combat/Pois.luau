--!strict
-- Points of interest: pure logic (GDD §3.8, GDD-v2 §4). Config/Pois.luau holds the data.
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
--   totem    (v2) capture-and-hold; the owner squad gets Config.TOTEM_DAMAGE_MULT
--            (World._refreshTotems -> world.squadDmg). Two squads inside hold it.
--   cart     (v2) Shop Cart: a hero standing in it CART_OPEN s gets a personal
--            poiReward "shop_cart_open"; RunDirector sells via world:takeCartOffer.
-- Every channel is CONTESTED (v2): only one squad progresses at a time (two
-- squads inside: hold; a new squad drains the old one's progress first), a
-- recently hurt hero does not channel, and the reward goes to that squad.
-- Nothing runs while the waves are not active (Boss, StageClear, votes).
--
-- World events (world:drainEvents):
--   {type="poiProgress", poi, kind, amount}            each 10% step
--   {type="poiActivated", poi, kind, by, x, z}         channel done / camp woken / chest opened
--   {type="poiReward", poi, kind, poiKind, by, x, z, ids, squad, cheese?, buff?, xp?,
--     revived?, cards?, items?}                          ids = the rewarded squad's members
--   v2: kind "armory" / "vault" (items, vault cheese), "totem_owner" {squad, prev},
--   "shop_cart_open" {offers, prices, sold}; {type="poiAlert", poi, kind, squad}
--   when a Cheese Vault channel starts; {type="totemLost", poi, squad, by}.
-- Fx: {t="poi", id, kind, x, z, r, state, active, p}, {t="poiProgress", id, p},
--     {t="poiDone", id, kind, x, z, by, squad, dur?, untilT?, chest?, cheese?, items?},
--     {t="trap", id, x, z, r}, v2: {t="vault", id, x, z, phase="start"|"contested"|"done",
--     squad, by?}, {t="totem", id, x, z, r, owner, prev, by, p}, {t="cart", id, x, z, by?, left}
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
	local taken: { [number]: boolean } = {}
	for _, rare in Config.RARES do
		acc += rare.chance
		if roll < acc then
			local i = rng:nextInt(1, #ids)
			ids[i] = rare.id
			taken[i] = true
			break
		end
	end
	-- v2 specials (Power Totem, Cheese Vault, Shop Cart): at most one each, never
	-- on the rare's slot. Rolled after the rare, so the rare rates are unchanged.
	for _, sp in Config.SPECIALS do
		if rng:nextFloat() < sp.chance then
			local free = {}
			for i = 1, #ids do
				if not taken[i] then
					table.insert(free, i)
				end
			end
			if #free > 0 then
				local i = free[rng:nextInt(1, #free)]
				ids[i] = sp.id
				taken[i] = true
			end
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
		-- v2 contest state
		squad = nil :: number?, -- squad channelling (or owning / capturing a totem)
		contested = false,
		owner = nil :: number?, -- totem owner squad
		capSquad = nil :: number?, -- totem: squad whose capture progress this is
		lastKiller = nil :: number?, -- camp: hero who killed the latest elite
		announce = def ~= nil and def.announce == true,
		openT = {} :: { [number]: number }, -- cart: per-hero open timer
		opened = {} :: { [number]: boolean }, -- cart: opened for this hero (until they leave)
		offers = nil :: any, -- cart stock (rolled on first open)
		prices = nil :: any,
		sold = nil :: any,
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
		squad = e.squad,
		contested = e.contested == true,
		owner = e.owner,
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
		squad = e.squad,
		contested = e.contested == true,
		owner = e.owner,
		capSquad = e.capSquad,
		left = if e.mode == "cart" then (if e.offers then Pois.cartLeft(e) else 3) else nil,
	}
end

-- Update (called from World.step) ------------------------------------------------------

local function squadOfHero(p: any): number
	return p.squad or 1
end

-- Ids of every member of `squad` (downed and dead included); every participant
-- when squad is nil.
local function squadIds(w: any, squad: number?): { number }
	local ids = {}
	for _, p in w.playerList do
		if squad == nil or squadOfHero(p) == squad then
			table.insert(ids, p.id)
		end
	end
	return ids
end
Pois.squadIds = squadIds

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
		w:emit({ t = "poiProgress", id = e.id, p = math.floor(p * 100 + 0.5) / 100, squad = e.squad })
		w:event({ type = "poiProgress", poi = e.id, kind = e.kind, amount = p, squad = e.squad })
	end
end

local function setState(w: any, e: any, state: string)
	if e.state ~= state then
		e.state = state
		w:emit(Pois.stateFx(e))
	end
end

local function setContested(w: any, e: any, contested: boolean)
	if e.contested ~= contested then
		e.contested = contested
		w:emit(Pois.stateFx(e))
		if contested and e.announce and e.progress > 0 then
			w:emit({ t = "vault", id = e.id, x = e.x, z = e.z, phase = "contested", squad = e.squad })
		end
	end
end

-- Best channel speed bonus among the heroes channelling (gear: Treasure Nose).
local function channelMult(list: { any }): number
	local m = 1
	for _, p in list do
		local v = p.stats and p.stats.channelSpeedMult
		if finite(v) and v > m then
			m = v
		end
	end
	return m
end

-- The single squad among `list`, and whether two or more squads are present.
local function soleSquad(list: { any }): (number?, boolean)
	local sq: number? = nil
	for _, p in list do
		local s = squadOfHero(p)
		if sq == nil then
			sq = s
		elseif s ~= sq then
			return nil, true
		end
	end
	return sq, false
end

-- Gear rolled by the world's gear stream (World._rollGear); nil when unavailable.
local function rollGear(w: any, def: any): any?
	if type(w._rollGear) ~= "function" then
		return nil
	end
	local minRarity = nil
	if def and def.gearMinRarity and w.stage >= (def.gearMinStage or 1) then
		minRarity = def.gearMinRarity
	end
	return w:_rollGear(minRarity)
end

-- World-side reward of a finished channel / opened chest, then the events.
-- `fled`: an Elite Camp whose pack was still alive when the waves ended.
local function complete(w: any, e: any, by: number?, fled: boolean?, channellers: { any }?)
	local def = Config.get(e.kind)
	e.progress = 1
	e.state = "done"
	local now = w.now
	local squad = e.squad
	if squad == nil and by ~= nil then
		local p = w.players[by]
		squad = if p then squadOfHero(p) else nil
	end
	e.squad = squad
	local reward: { [string]: any } = {
		type = "poiReward",
		poi = e.id,
		kind = e.kind,
		poiKind = e.kind,
		by = by,
		x = e.x,
		z = e.z,
		ids = squadIds(w, squad),
		squad = squad,
		fled = if fled then true else nil,
	}
	local done: { [string]: any } =
		{ t = "poiDone", id = e.id, kind = e.kind, x = e.x, z = e.z, by = by, squad = squad }
	local kindOfReward = if def then def.reward else "none"
	if kindOfReward == "cheese" then
		reward.cheese = Config.cacheCheese(e.kind, w.cycle, w.stage)
		done.cheese = reward.cheese
	elseif kindOfReward == "buff" and def then
		if def.heal and def.heal > 0 then
			for _, p in w.playerList do
				if squad == nil or squadOfHero(p) == squad then
					w:healPlayer(p.id, def.heal)
				end
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
			if squad == nil or squadOfHero(p) == squad then
				if p.downed or p.dead then
					revived += 1
					w:_revive(p, w.REVIVE_HP or 0.4, "statue")
				end
				p.secondWindUsed = false
			end
		end
		reward.revived = revived
	elseif kindOfReward == "elite_chest" then
		done.chest = true
		-- v2: an Elite Camp chest also spills one gear item (any squad can grab it)
		local item = rollGear(w, def)
		if item and type(w.dropGear) == "function" then
			w:dropGear(item, e.x, e.z)
			reward.items = { item }
		end
	elseif kindOfReward == "epic_pick" then
		reward.cards = Config.EPIC_CARDS
	elseif kindOfReward == "gear" or kindOfReward == "vault" then
		-- Armory Crate / Cheese Vault: items go to the channellers (by first).
		local takers: { number } = {}
		if by then
			table.insert(takers, by)
		end
		for _, p in channellers or {} do
			if not table.find(takers, p.id) then
				table.insert(takers, p.id)
			end
		end
		local items = {}
		for i = 1, (def and def.gearItems) or 1 do
			local item = rollGear(w, def)
			if item then
				table.insert(items, item)
				local taker = if #takers > 0 then takers[(i - 1) % #takers + 1] else nil
				if taker and type(w.giveGear) == "function" then
					w:giveGear(taker, item)
				elseif type(w.dropGear) == "function" then
					w:dropGear(item, e.x, e.z)
				end
			end
		end
		reward.items = items
		done.items = #items
		if kindOfReward == "vault" then
			reward.kind = "vault" -- the contract's reward kind (poiKind = "cheese_vault")
			reward.cheese = Config.vaultCheese(w.cycle, w.stage)
			done.cheese = reward.cheese
			w:emit({ t = "vault", id = e.id, x = e.x, z = e.z, phase = "done", squad = squad, by = by })
		end
	end
	w:emit(Pois.stateFx(e))
	w:emit(done)
	if e.mode ~= "camp" then
		w:event({ type = "poiActivated", poi = e.id, kind = e.kind, by = by, x = e.x, z = e.z, squad = squad })
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

local function announce(w: any, e: any)
	w:emit({ t = "vault", id = e.id, x = e.x, z = e.z, phase = "start", squad = e.squad })
	w:event({ type = "poiAlert", poi = e.id, kind = e.kind, squad = e.squad, x = e.x, z = e.z })
end

-- Contested channel (GDD-v2 §4): one squad at a time; two squads inside hold the
-- progress; a new squad first drains the old squad's progress (STEAL_RATE).
local function updateChannel(w: any, e: any, dt: number, now: number)
	if e.state == "done" then
		return
	end
	local inside, channelling = inRangeOf(w, e, now)
	local sq, contested = soleSquad(inside)
	local before = e.progress
	local beforeSquad = e.squad
	setContested(w, e, contested)
	if not contested then
		local mult = channelMult(channelling)
		if sq and e.squad and sq ~= e.squad and e.progress > 0 then
			if #channelling > 0 then
				local rate = Pois.channelRate(#channelling) * mult * Config.STEAL_RATE
				e.progress = math.max(0, e.progress - dt / math.max(0.05, e.channel) * rate)
				if e.progress <= 0 then
					e.squad = sq
					table.clear(e.usedBy)
				end
			end
		else
			if sq and #channelling > 0 then
				e.squad = sq
			end
			e.progress = Pois.advance(e.progress, e.channel / mult, #channelling, #inside, dt)
			for _, p in channelling do
				markUser(e, p.id)
			end
			if e.progress <= 0 and #inside == 0 then
				e.squad = nil
			end
		end
	end
	if e.progress >= 1 then
		local by = if #channelling > 0 then channelling[1].id else e.usedBy[1]
		complete(w, e, by, nil, channelling)
		return
	end
	if e.announce and e.progress > 0 and (before == 0 or beforeSquad ~= e.squad) then
		announce(w, e)
	end
	if e.progress > 0 and before == 0 then
		setState(w, e, "active")
	elseif e.progress <= 0 and before > 0 then
		setState(w, e, "idle")
	elseif beforeSquad ~= e.squad then
		w:emit(Pois.stateFx(e))
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
	local p = w.players[by]
	e.squad = if p then squadOfHero(p) else nil
	setState(w, e, "active")
	w:event({ type = "poiActivated", poi = e.id, kind = e.kind, by = by, x = e.x, z = e.z, squad = e.squad })
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
-- The chest goes to the squad of the hero who killed the last elite (else the waker's).
function Pois.onPackKill(w: any, enemy: any, by: any?)
	local e = w.poiById and w.poiById[enemy.poiId]
	if not e or e.state ~= "active" then
		return
	end
	e.pack = math.max(0, e.pack - 1)
	if by and type(by.id) == "number" and w.players[by.id] then
		e.lastKiller = by.id
	end
	if e.pack == 0 and e.active then
		local killer = e.lastKiller or e.usedBy[1]
		local kp = killer and w.players[killer]
		e.squad = if kp then squadOfHero(kp) else e.squad
		complete(w, e, killer)
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

-- Power Totem ---------------------------------------------------------------------------

local function totemFx(e: any, prev: number?, by: number?): { [string]: any }
	return {
		t = "totem",
		id = e.id,
		x = e.x,
		z = e.z,
		r = e.r,
		owner = e.owner,
		prev = prev,
		by = by,
		p = math.floor(e.progress * 100 + 0.5) / 100,
	}
end

local function setOwner(w: any, e: any, squad: number?, by: number?)
	local prev = e.owner
	if prev == squad then
		return
	end
	e.owner = squad
	if type(w._refreshTotems) == "function" then
		w:_refreshTotems()
	end
	w:emit(totemFx(e, prev, by))
	w:emit(Pois.stateFx(e))
	if squad then
		w:event({ type = "poiActivated", poi = e.id, kind = e.kind, by = by, x = e.x, z = e.z, squad = squad })
		w:event({
			type = "poiReward",
			poi = e.id,
			kind = "totem_owner",
			poiKind = e.kind,
			squad = squad,
			prev = prev,
			by = by,
			x = e.x,
			z = e.z,
			ids = squadIds(w, squad),
			mult = Config.TOTEM_DAMAGE_MULT,
		})
	else
		w:event({ type = "totemLost", poi = e.id, kind = e.kind, squad = prev, by = by, x = e.x, z = e.z })
	end
end

-- Capture-and-hold: one squad alone inside fills (neutral) or drains (someone
-- else's) the totem; two squads inside hold it. The owner keeps it until it is
-- neutralised: the buff lasts through the boss fight.
local function updateTotem(w: any, e: any, dt: number, now: number)
	local inside, channelling = inRangeOf(w, e, now)
	local sq, contested = soleSquad(inside)
	local before = e.progress
	setContested(w, e, contested)
	if not contested then
		if sq == nil then
			if e.owner == nil and e.progress > 0 then
				e.progress = math.max(0, e.progress - Config.TOTEM_DECAY * dt)
				if e.progress <= 0 then
					e.capSquad = nil
				end
			end
		elseif #channelling > 0 then
			local rate = dt
				/ math.max(0.05, e.channel)
				* Pois.channelRate(#channelling)
				* channelMult(channelling)
			local by = channelling[1].id
			if e.owner == sq then
				e.progress = math.min(1, e.progress + rate)
			elseif e.owner ~= nil then
				e.progress = math.max(0, e.progress - rate)
				if e.progress <= 0 then
					setOwner(w, e, nil, by)
					e.capSquad = sq
				end
			elseif e.capSquad ~= nil and e.capSquad ~= sq and e.progress > 0 then
				e.progress = math.max(0, e.progress - rate)
				if e.progress <= 0 then
					e.capSquad = sq
				end
			else
				e.capSquad = sq
				e.progress = math.min(1, e.progress + rate)
				for _, p in channelling do
					markUser(e, p.id)
				end
				if e.progress >= 1 then
					setOwner(w, e, sq, by)
				end
			end
		end
	end
	e.squad = e.owner or e.capSquad
	local state = if e.owner ~= nil or e.progress > 0 then "active" else "idle"
	setState(w, e, state)
	if before ~= e.progress then
		reportProgress(w, e)
	end
end

-- Shop Cart -------------------------------------------------------------------------------

local function cartStock(w: any, e: any)
	if e.offers then
		return
	end
	if type(w._cartStock) == "function" then
		e.offers, e.prices = w:_cartStock()
	else
		e.offers, e.prices = {}, {}
	end
	e.sold = {}
	for i = 1, #e.offers do
		e.sold[i] = false
	end
end

function Pois.cartLeft(e: any): number
	local n = 0
	for i = 1, #(e.offers or {}) do
		if not e.sold[i] then
			n += 1
		end
	end
	return n
end

-- A hero who stands in the cart (unhurt) for `channel` s opens it: a personal
-- poiReward {kind = "shop_cart_open", poi, by, offers, prices, sold}. They must
-- step out before it opens for them again.
local function updateCart(w: any, e: any, dt: number, now: number)
	if e.state == "done" then
		return
	end
	local inside, channelling = inRangeOf(w, e, now)
	local present: { [number]: boolean } = {}
	for _, p in inside do
		present[p.id] = true
	end
	for id in e.openT do
		if not present[id] then
			e.openT[id] = nil
			e.opened[id] = nil
		end
	end
	for _, p in channelling do
		if not e.opened[p.id] then
			local m = channelMult({ p })
			e.openT[p.id] = (e.openT[p.id] or 0) + dt * m
			if e.openT[p.id] >= e.channel then
				e.opened[p.id] = true
				cartStock(w, e)
				markUser(e, p.id)
				local offers = {}
				for i, it in e.offers do
					offers[i] = table.clone(it)
				end
				w:emit({ t = "cart", id = e.id, x = e.x, z = e.z, by = p.id, left = Pois.cartLeft(e) })
				w:event({
					type = "poiReward",
					poi = e.id,
					kind = "shop_cart_open",
					poiKind = e.kind,
					by = p.id,
					squad = squadOfHero(p),
					x = e.x,
					z = e.z,
					ids = { p.id },
					offers = offers,
					prices = table.clone(e.prices),
					sold = table.clone(e.sold),
				})
				setState(w, e, "active")
			end
		end
	end
end

-- Sells offer `index` of cart `e` (RunDirector charges the cheese first).
-- Returns the item, or nil when it is sold out / unknown.
function Pois.takeCartOffer(w: any, e: any, index: number): any?
	if not e or e.mode ~= "cart" or not e.offers or type(index) ~= "number" then
		return nil
	end
	local it = e.offers[index]
	if not it or e.sold[index] then
		return nil
	end
	e.sold[index] = true
	w:emit({ t = "cart", id = e.id, x = e.x, z = e.z, left = Pois.cartLeft(e) })
	if Pois.cartLeft(e) == 0 then
		e.state = "done"
		w:emit(Pois.stateFx(e))
	end
	return table.clone(it)
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
					complete(w, e, e.lastKiller or e.usedBy[1], true)
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
		local mode = e.mode
		if mode == "channel" then
			updateChannel(w, e, dt, now)
		elseif mode == "camp" then
			updateCamp(w, e, now)
		elseif mode == "hazard" then
			updateHazard(w, e, now)
		elseif mode == "totem" then
			updateTotem(w, e, dt, now)
		elseif mode == "cart" then
			updateCart(w, e, dt, now)
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
