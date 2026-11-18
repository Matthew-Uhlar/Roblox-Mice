--!strict
-- (v5) Charms: inventory, drops, sockets, fuse, salvage and the squad aura (Team P).
-- Pure: the caller passes a seed for drops (the server makes one per grant) and the day.
-- Content: Config/Charms. Free rewards only: never sold, never rerolled for Robux.
--
-- profile.charms = {
--   inv = { {id, type, rarity, tier} },   at most Config/Charms.INVENTORY
--   equipped = { [1..3] = charmId? },    sockets open at account level 1 / 10 / 25
--   nextId = number,
--   day = number, granted = number,      grants today (dupe watch, Z-17)
-- }

local Types = require("../Types")
local C = require("../Config/Charms")
local Rng = require("../Util/Rng")
local RunBonus = require("./RunBonus")

type Profile = Types.Profile

export type Charm = { id: number, type: string, rarity: number, tier: number }
export type State = {
	inv: { Charm },
	equipped: { [string]: number },
	nextId: number,
	day: number,
	granted: number,
}

local Charms = {}

function Charms.default(): State
	return { inv = {}, equipped = {}, nextId = 1, day = 0, granted = 0 }
end

local function int(v: any, lo: number, hi: number): number?
	if type(v) ~= "number" or v ~= v or math.abs(v) == math.huge then
		return nil
	end
	local i = math.floor(v)
	if i < lo or i > hi then
		return nil
	end
	return i
end

-- Repairs a saved block: real types, rarities 1..4, unique ids, inventory cap, equipped
-- ids that exist (each charm in one socket at most).
function Charms.sanitize(raw: any): State
	local r: { [any]: any } = if type(raw) == "table" then raw else {}
	local st = Charms.default()
	local ids: { [number]: boolean } = {}
	local maxId = 0
	if type(r.inv) == "table" then
		for _, ch in r.inv do
			if #st.inv >= C.INVENTORY then
				break
			end
			if type(ch) == "table" then
				local id = int(ch.id, 1, 1e9)
				local rarity = int(ch.rarity, 1, #C.RARITIES)
				if id and rarity and C.get(ch.type) and not ids[id] then
					ids[id] = true
					maxId = math.max(maxId, id)
					table.insert(
						st.inv,
						{ id = id, type = ch.type, rarity = rarity, tier = int(ch.tier, 1, 5) or 1 }
					)
				end
			end
		end
	end
	local used: { [number]: boolean } = {}
	if type(r.equipped) == "table" then
		for slot = 1, #C.SOCKET_LEVELS do
			local id = int(r.equipped[tostring(slot)] or r.equipped[slot], 1, 1e9)
			if id and ids[id] and not used[id] then
				used[id] = true
				st.equipped[tostring(slot)] = id
			end
		end
	end
	st.nextId = math.max(int(r.nextId, 1, 1e9) or 1, maxId + 1)
	st.day = int(r.day, 0, 1e7) or 0
	st.granted = int(r.granted, 0, 1e6) or 0
	return st
end

function Charms.state(profile: Profile): State
	local p = profile :: any
	if type(p.charms) ~= "table" or type(p.charms.inv) ~= "table" or type(p.charms.equipped) ~= "table" then
		p.charms = Charms.sanitize(p.charms)
	end
	return p.charms
end

local function find(st: State, id: any): (Charm?, number?)
	for i, ch in st.inv do
		if ch.id == id then
			return ch, i
		end
	end
	return nil, nil
end

-- Rolls one charm: a weighted rarity, raised to the run's tier floor (and to Rare at
-- stage >= RARE_FROM_STAGE), and a type. Deterministic for a seed.
function Charms.roll(
	seed: number,
	pressure: number?,
	stage: number?
): { type: string, rarity: number, tier: number }
	local rng = Rng.new(seed)
	local tier = C.tierFor(pressure or 0)
	local rarity = rng:weightedIndex(C.WEIGHTS)
	rarity = math.max(rarity, C.TIER_FLOOR[tier] or 1)
	if type(stage) == "number" and stage >= C.RARE_FROM_STAGE then
		rarity = math.max(rarity, 2)
	end
	return { type = rng:pick(C.ORDER), rarity = rarity, tier = tier }
end

-- How many end-of-match drops (0 or 1) for the stage reached, deterministic for a seed.
function Charms.matchDrop(seed: number, stageReached: number?): boolean
	local s = if type(stageReached) == "number" and stageReached == stageReached
		then math.floor(stageReached)
		else 0
	if s < 1 then
		return false
	end
	local chance = C.STAGE_DROP_CHANCE[math.min(s, #C.STAGE_DROP_CHANCE)]
	return Rng.new(seed):nextFloat() < chance
end

-- Adds a charm. A full inventory salvages the new charm into cheese instead (never lost
-- silently). Returns (charm?, salvagedCheese, overDailyWatch).
function Charms.grant(
	profile: Profile,
	charm: { type: string, rarity: number, tier: number },
	day: number
): (Charm?, number, boolean)
	local st = Charms.state(profile)
	local d = math.floor(day)
	if st.day ~= d then
		st.day = d
		st.granted = 0
	end
	st.granted += 1
	local watch = st.granted > C.MAX_GRANTS_PER_DAY
	if not C.get(charm.type) then
		return nil, 0, watch
	end
	local rarity = math.clamp(math.floor(charm.rarity), 1, #C.RARITIES)
	if #st.inv >= C.INVENTORY then
		local cheese = C.SALVAGE_CHEESE[rarity]
		profile.cheese = math.min(1_000_000_000, profile.cheese + cheese)
		return nil, cheese, watch
	end
	local ch: Charm =
		{ id = st.nextId, type = charm.type, rarity = rarity, tier = math.clamp(charm.tier, 1, 5) }
	st.nextId += 1
	table.insert(st.inv, ch)
	return ch, 0, watch
end

-- Sockets open at account levels 1 / 10 / 25.
function Charms.socketsOpen(profile: Profile): number
	local n = 0
	for _, lvl in C.SOCKET_LEVELS do
		if profile.level >= lvl then
			n += 1
		end
	end
	return n
end

-- Equips (or empties with charmId = nil) a socket. Reasons: "bad_slot" | "slot_locked"
-- | "unknown_charm"
function Charms.equip(profile: Profile, slot: any, charmId: any): (boolean, string?)
	local st = Charms.state(profile)
	if type(slot) ~= "number" or slot ~= math.floor(slot) or slot < 1 or slot > #C.SOCKET_LEVELS then
		return false, "bad_slot"
	end
	if slot > Charms.socketsOpen(profile) then
		return false, "slot_locked"
	end
	local key = tostring(slot)
	if charmId == nil then
		st.equipped[key] = nil
		return true, nil
	end
	if not find(st, charmId) then
		return false, "unknown_charm"
	end
	for k, id in st.equipped do
		if id == charmId then
			st.equipped[k] = nil -- moving a charm to another socket
		end
	end
	st.equipped[key] = charmId
	return true, nil
end

local function unequip(st: State, id: number)
	for k, eq in st.equipped do
		if eq == id then
			st.equipped[k] = nil
		end
	end
end

-- Fuses FUSE_COUNT unequipped-first charms of one type and rarity into one of the next
-- rarity (the best tier of the three). Reasons: "unknown_type" | "max_rarity" | "not_enough"
function Charms.fuse(profile: Profile, charmType: any, rarity: any): (boolean, any)
	local st = Charms.state(profile)
	if not C.get(charmType) then
		return false, "unknown_type"
	end
	if type(rarity) ~= "number" or rarity ~= math.floor(rarity) or rarity < 1 or rarity > #C.RARITIES then
		return false, "bad_rarity"
	end
	if rarity >= #C.RARITIES then
		return false, "max_rarity"
	end
	local equippedSet: { [number]: boolean } = {}
	for _, id in st.equipped do
		equippedSet[id] = true
	end
	local picks: { Charm } = {}
	-- unequipped first, then equipped ones
	for pass = 1, 2 do
		for _, ch in st.inv do
			if #picks < C.FUSE_COUNT and ch.type == charmType and ch.rarity == rarity then
				local eq = equippedSet[ch.id] == true
				if (pass == 1 and not eq) or (pass == 2 and eq) then
					table.insert(picks, ch)
				end
			end
		end
	end
	if #picks < C.FUSE_COUNT then
		return false, "not_enough"
	end
	local tier = 1
	for _, ch in picks do
		tier = math.max(tier, ch.tier)
		unequip(st, ch.id)
		local _, i = find(st, ch.id)
		if i then
			table.remove(st.inv, i)
		end
	end
	local made: Charm = { id = st.nextId, type = charmType, rarity = rarity + 1, tier = tier }
	st.nextId += 1
	table.insert(st.inv, made)
	return true, made
end

-- Turns a charm into cheese. Reasons: "unknown_charm"
function Charms.salvage(profile: Profile, charmId: any): (boolean, any)
	local st = Charms.state(profile)
	local ch, i = find(st, charmId)
	if not ch or not i then
		return false, "unknown_charm"
	end
	unequip(st, ch.id)
	table.remove(st.inv, i)
	local cheese = C.SALVAGE_CHEESE[ch.rarity]
	profile.cheese = math.min(1_000_000_000, profile.cheese + cheese)
	return true, { cheese = cheese }
end

-- The equipped charms of one profile: {[type] = best rarity} (open sockets only).
function Charms.equippedBest(profile: Profile): { [string]: number }
	local st = Charms.state(profile)
	local open = Charms.socketsOpen(profile)
	local out: { [string]: number } = {}
	for k, id in st.equipped do
		local slot = tonumber(k)
		local ch = find(st, id)
		if ch and slot and slot <= open then
			out[ch.type] = math.max(out[ch.type] or 0, ch.rarity)
		end
	end
	return out
end

-- The squad aura from the members' equipped charms: per type the highest rarity wins
-- (no stacking of one type). Every squad member, bots included, gets it.
function Charms.aura(members: { { [string]: number } }): RunBonus.Bonus
	local best: { [string]: number } = {}
	for _, m in members do
		for t, r in m do
			best[t] = math.max(best[t] or 0, r)
		end
	end
	local b = RunBonus.new()
	for t, r in best do
		local def = C.get(t)
		if def and def.values[r] then
			RunBonus.add(b, def.effect, def.field, def.values[r])
		end
	end
	return b
end

-- Profile view `charms`.
function Charms.view(profile: Profile): { [string]: any }
	local st = Charms.state(profile)
	local inv = {}
	for _, ch in st.inv do
		local def = C.get(ch.type) :: C.CharmType
		local v = def.values[ch.rarity]
		local shown = if def.field == "regen"
			then string.format("%.1f", v)
			else string.format("%d%%", math.floor(v * 100 + 0.5))
		table.insert(inv, {
			id = ch.id,
			type = ch.type,
			name = def.name,
			rarity = ch.rarity,
			rarityName = C.RARITIES[ch.rarity],
			tier = ch.tier,
			text = (string.gsub(def.text, "%%s", (string.gsub(shown, "%%", "%%%%")))),
		})
	end
	local equipped = {}
	for slot = 1, #C.SOCKET_LEVELS do
		equipped[slot] = st.equipped[tostring(slot)] or 0 -- 0 = empty (arrays can't hold nil over a remote)
	end
	return {
		inv = inv,
		equipped = equipped,
		socketsOpen = Charms.socketsOpen(profile),
		socketLevels = table.clone(C.SOCKET_LEVELS),
		capacity = C.INVENTORY,
		salvageCheese = table.clone(C.SALVAGE_CHEESE),
	}
end

return Charms
