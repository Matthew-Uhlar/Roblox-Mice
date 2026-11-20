--!strict
-- (iteration 2) Cheese Gems and Crumb Dust (Team P). Pure: the caller passes a seed
-- (the server makes one per drop) and the UTC day. Content: Config/Gems.
-- Free drops only: never sold, rerolled or upgraded with Robux or Golden Cheese.
--
-- profile.gems = {
--   inv = { {id, t, s = {rinds, bite, hide, plating, stride}, u?, lv} },   at most 200
--   equipped = { ["1".."3"] = gemId },   sockets open at account level 1 / 10 / 25
--   dust = number,                       Crumb Dust
--   nextId = number, day = number, granted = number   (grants today: dupe watch, Z-17)
-- }

local Types = require("../Types")
local G = require("../Config/Gems")
local Rng = require("../Util/Rng")
local RunBonus = require("./RunBonus")

type Profile = Types.Profile

export type Gem = { id: number, t: number, s: { number }, u: string?, lv: number }
export type State = {
	inv: { Gem },
	equipped: { [string]: number },
	dust: number,
	nextId: number,
	day: number,
	granted: number,
}

local Gems = {}

function Gems.default(): State
	return { inv = {}, equipped = {}, dust = 0, nextId = 1, day = 0, granted = 0 }
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

-- Clamps stats to the tier range x the level bonus (a corrupted save can't make a super gem).
local function cleanGem(g: any): Gem?
	if type(g) ~= "table" then
		return nil
	end
	local id = int(g.id, 1, 1e9)
	local t = int(g.t, 1, G.MAX_TIER)
	if not id or not t or type(g.s) ~= "table" then
		return nil
	end
	local range = G.RANGES[t]
	local s = {}
	for i = 1, #G.STATS do
		local v = int(g.s[i], 0, 1e6)
		s[i] = math.clamp(v or range[1], range[1], range[2])
	end
	local u = if type(g.u) == "string" and G.unique(g.u) then g.u else nil
	return { id = id, t = t, s = s, u = u, lv = int(g.lv, 0, G.MAX_LEVEL) or 0 }
end

function Gems.sanitize(raw: any): State
	local r: { [any]: any } = if type(raw) == "table" then raw else {}
	local st = Gems.default()
	local ids: { [number]: boolean } = {}
	local maxId = 0
	if type(r.inv) == "table" then
		for _, g in r.inv do
			if #st.inv >= G.INVENTORY then
				break
			end
			local gem = cleanGem(g)
			if gem and not ids[gem.id] then
				ids[gem.id] = true
				maxId = math.max(maxId, gem.id)
				table.insert(st.inv, gem)
			end
		end
	end
	local used: { [number]: boolean } = {}
	if type(r.equipped) == "table" then
		for slot = 1, #G.SOCKET_LEVELS do
			local id = int(r.equipped[tostring(slot)] or r.equipped[slot], 1, 1e9)
			if id and ids[id] and not used[id] then
				used[id] = true
				st.equipped[tostring(slot)] = id
			end
		end
	end
	st.dust = int(r.dust, 0, G.MAX_DUST) or 0
	st.nextId = math.max(int(r.nextId, 1, 1e9) or 1, maxId + 1)
	st.day = int(r.day, 0, 1e7) or 0
	st.granted = int(r.granted, 0, 1e6) or 0
	return st
end

function Gems.state(profile: Profile): State
	local p = profile :: any
	if type(p.gems) ~= "table" or type(p.gems.inv) ~= "table" or type(p.gems.equipped) ~= "table" then
		p.gems = Gems.sanitize(p.gems)
	end
	return p.gems
end

local function find(st: State, id: any): (Gem?, number?)
	for i, g in st.inv do
		if g.id == id then
			return g, i
		end
	end
	return nil, nil
end

export type Roll = { t: number, s: { number }, u: string? }

-- Rolls a gem at `tier`. opts.high = the High-route roll (top half of the range);
-- opts.unique = a unique is guaranteed. Deterministic for a seed.
-- (iteration 3) Independent sub-seed: the shared Rng's first draw is correlated for
-- nearby seeds, so rolls derived from one match seed (seed + k) are hashed first.
-- (a * m) mod 2^32 without losing precision (each partial product stays below 2^48).
local function mul32(a: number, m: number): number
	local lo, hi = a % 65536, a // 65536
	return (lo * m + ((hi * m) % 65536) * 65536) % 4294967296
end

function Gems.subSeed(seed: number, salt: number): number
	local x = bit32.bxor(math.floor(seed) % 4294967296, mul32(math.floor(salt) % 4294967296, 0x9E3779B1))
	x = bit32.bxor(x, bit32.rshift(x, 16))
	x = mul32(x, 0x85EBCA6B)
	x = bit32.bxor(x, bit32.rshift(x, 13))
	x = mul32(x, 0xC2B2AE35)
	return bit32.bxor(x, bit32.rshift(x, 16))
end

function Gems.roll(seed: number, tier: number, opts: { high: boolean?, unique: boolean? }?): Roll
	local o = opts or {}
	local rng = Rng.new(Gems.subSeed(seed, 1))
	local t = math.clamp(math.floor(if tier == tier then tier else 1), 1, G.MAX_TIER)
	local range = G.RANGES[t]
	local lo = if o.high then math.floor((range[1] + range[2]) / 2) else range[1]
	local s = {}
	for i = 1, #G.STATS do
		s[i] = rng:nextInt(lo, range[2])
	end
	local u = nil
	if o.unique or rng:nextFloat() < G.UNIQUE_CHANCE[t] then
		u = rng:pick(G.UNIQUE_ORDER)
	end
	return { t = t, s = s, u = u }
end

-- (iteration 3, T-11) The tier a drop rolls at for this profile: rookies (runs 0-2)
-- never get less than Config/Gems.ROOKIE_MIN_TIER. `counted` = this match is already in
-- stats.runs (end-of-match rolls run after Data/Award).
function Gems.dropTier(profile: Profile, tier: number, counted: boolean?): number
	local t = math.clamp(math.floor(if tier == tier then tier else 1), 1, G.MAX_TIER)
	local before = profile.stats.runs - (if counted then 1 else 0)
	if before < G.ROOKIE_RUNS then
		t = math.max(t, G.ROOKIE_MIN_TIER)
	end
	return t
end

-- Adds a gem. A full inventory salvages it into dust instead (a drop is never lost).
-- Returns (gem?, dustInstead, overDailyWatch).
function Gems.grant(profile: Profile, roll: Roll, day: number): (Gem?, number, boolean)
	local st = Gems.state(profile)
	local d = math.floor(day)
	if st.day ~= d then
		st.day = d
		st.granted = 0
	end
	st.granted += 1
	local watch = st.granted > G.MAX_GRANTS_PER_DAY
	local gem = cleanGem({ id = st.nextId, t = roll.t, s = roll.s, u = roll.u, lv = 0 })
	if not gem then
		return nil, 0, watch
	end
	if #st.inv >= G.INVENTORY then
		local dust = G.salvageDust(gem.t, gem.u ~= nil)
		st.dust = math.min(G.MAX_DUST, st.dust + dust)
		return nil, dust, watch
	end
	st.nextId += 1
	table.insert(st.inv, gem)
	return gem, 0, watch
end

function Gems.addDust(profile: Profile, amount: number): number
	local st = Gems.state(profile)
	local a = if type(amount) == "number" and amount == amount and amount > 0 then math.floor(amount) else 0
	st.dust = math.min(G.MAX_DUST, st.dust + a)
	return st.dust
end

function Gems.socketsOpen(profile: Profile): number
	local n = 0
	for _, lvl in G.SOCKET_LEVELS do
		if profile.level >= lvl then
			n += 1
		end
	end
	return n
end

-- Equips (or empties with gemId = nil) a socket. Reasons: "bad_slot" | "slot_locked" | "unknown_gem"
function Gems.equip(profile: Profile, slot: any, gemId: any): (boolean, string?)
	local st = Gems.state(profile)
	if type(slot) ~= "number" or slot ~= math.floor(slot) or slot < 1 or slot > #G.SOCKET_LEVELS then
		return false, "bad_slot"
	end
	if slot > Gems.socketsOpen(profile) then
		return false, "slot_locked"
	end
	local key = tostring(slot)
	if gemId == nil then
		st.equipped[key] = nil
		return true, nil
	end
	if not find(st, gemId) then
		return false, "unknown_gem"
	end
	for k, id in st.equipped do
		if id == gemId then
			st.equipped[k] = nil
		end
	end
	st.equipped[key] = gemId
	return true, nil
end

-- Upgrades a gem one level (n x tier dust for level n). Reasons: "unknown_gem" | "max_level" | "no_dust"
function Gems.upgrade(profile: Profile, gemId: any): (boolean, any)
	local st = Gems.state(profile)
	local g = find(st, gemId)
	if not g then
		return false, "unknown_gem"
	end
	if g.lv >= G.MAX_LEVEL then
		return false, "max_level"
	end
	local cost = G.upgradeCost(g.t, g.lv + 1)
	if st.dust < cost then
		return false, "no_dust"
	end
	st.dust -= cost
	g.lv += 1
	return true, { level = g.lv, cost = cost }
end

-- Salvages a gem into Crumb Dust (tier, +tier with a unique). Reasons: "unknown_gem"
function Gems.salvage(profile: Profile, gemId: any): (boolean, any)
	local st = Gems.state(profile)
	local g, i = find(st, gemId)
	if not g or not i then
		return false, "unknown_gem"
	end
	for k, id in st.equipped do
		if id == g.id then
			st.equipped[k] = nil
		end
	end
	table.remove(st.inv, i)
	local dust = G.salvageDust(g.t, g.u ~= nil)
	st.dust = math.min(G.MAX_DUST, st.dust + dust)
	return true, { dust = dust }
end

-- Effective stat points of a gem (rolled x (1 + 10% per level)).
function Gems.points(g: Gem): { number }
	local out = {}
	local mult = 1 + G.LEVEL_BONUS * g.lv
	for i = 1, #G.STATS do
		out[i] = g.s[i] * mult
	end
	return out
end

-- One profile's equipped gems (open sockets only).
function Gems.equipped(profile: Profile): { Gem }
	local st = Gems.state(profile)
	local open = Gems.socketsOpen(profile)
	local out = {}
	for k, id in st.equipped do
		local slot = tonumber(k)
		local g = find(st, id)
		if g and slot and slot <= open then
			table.insert(out, g)
		end
	end
	return out
end

export type Aura = { bonus: RunBonus.Bonus, uniques: { string } }

-- The squad aura: the SUM of every member's equipped gems, within the squad caps
-- (Config/Gems.SQUAD_CAP); each unique at most once. `members` = each member's equipped
-- gems (Gems.equipped). Bots get the aura but carry none.
function Gems.aura(members: { { Gem } }): Aura
	local sum = { 0, 0, 0, 0, 0 }
	local seen: { [string]: boolean } = {}
	local uniques = {}
	for _, gems in members do
		for _, g in gems do
			local pts = Gems.points(g)
			for i = 1, #G.STATS do
				sum[i] += pts[i]
			end
			if g.u and not seen[g.u] then
				seen[g.u] = true
				table.insert(uniques, g.u)
			end
		end
	end
	table.sort(uniques)
	local b = RunBonus.new()
	local function value(i: number): number
		local stat = G.STATS[i]
		return math.min(G.SQUAD_CAP[stat], sum[i] * G.POINT[stat])
	end
	RunBonus.add(b, "extra", "rindMult", value(1))
	RunBonus.add(b, "pve", nil, value(2))
	RunBonus.add(b, "pctStat", "maxHp", value(3))
	RunBonus.add(b, "extra", "pveResist", value(4))
	RunBonus.add(b, "pctStat", "moveSpeed", value(5))
	return { bonus = b, uniques = uniques }
end

local function gemView(g: Gem): { [string]: any }
	local pts = Gems.points(g)
	local stats = {}
	for i, stat in G.STATS do
		stats[i] = {
			stat = stat,
			name = G.STAT_NAMES[stat],
			roll = g.s[i],
			value = pts[i] * G.POINT[stat], -- fraction after the level bonus
		}
	end
	local u = if g.u then G.unique(g.u) else nil
	return {
		id = g.id,
		tier = g.t,
		tierName = G.TIER_NAMES[g.t],
		level = g.lv,
		stats = stats,
		unique = if u then { id = u.id, name = u.name, text = u.text, classId = u.classId } else nil,
		upgradeCost = if g.lv < G.MAX_LEVEL then G.upgradeCost(g.t, g.lv + 1) else nil,
		salvageDust = G.salvageDust(g.t, g.u ~= nil),
	}
end
Gems.gemView = gemView

-- Profile view `gems`.
function Gems.view(profile: Profile): { [string]: any }
	local st = Gems.state(profile)
	local inv = {}
	for _, g in st.inv do
		table.insert(inv, gemView(g))
	end
	local equipped = {}
	for slot = 1, #G.SOCKET_LEVELS do
		equipped[slot] = st.equipped[tostring(slot)] or 0 -- 0 = empty
	end
	return {
		inv = inv,
		equipped = equipped,
		dust = st.dust,
		socketsOpen = Gems.socketsOpen(profile),
		socketLevels = table.clone(G.SOCKET_LEVELS),
		capacity = G.INVENTORY,
	}
end

-- Checks for Challenges: best upgrade level and best tier owned.
function Gems.best(profile: Profile): (number, number)
	local st = Gems.state(profile)
	local lv, t = 0, 0
	for _, g in st.inv do
		lv = math.max(lv, g.lv)
		t = math.max(t, g.t)
	end
	return lv, t
end

return Gems
