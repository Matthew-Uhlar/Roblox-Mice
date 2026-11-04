--!strict
-- Run-only gear logic (docs/GDD-v2.md §3, docs/ARCHITECTURE-v2.md). Pure.
-- Config/Gear.luau holds the 31 item defs.
--
--   Gear.apply(stats, weapon, ability, items) -> (stats, weapon, ability)
--       Copies with every equipped item's effects applied. `items` is
--       world:gearOf(id) ({weapon?, armor?, trinket?}) or a plain list. The stats
--       copy carries `gearApplied = true`, so Combat/World knows the caller already
--       applied gear and does not apply it a second time.
--       Lua truncates a call in the middle of an argument list, so write it as
--         local s, w, a = Stats.compute(...)
--         s, w, a = Gear.apply(s, w, a, world:gearOf(id))
--       Gear.apply(stats, items) (two arguments) also works and returns
--       (stats, nil, nil).
--   Gear.roll(rng, tier, stage, opts?) -> item
--       tier = "Low" | "Mid" | "High" | 0..2 | nil; opts = {minRarity?, slot?, luck?}
--   Gear.rarityWeights(tier, stage, luck?) -> {Common, Rare, Epic, Legendary}
--   Gear.make(id, rarity) -> item?   Gear.valid(item) -> boolean
--   Gear.rank(item | rarity) -> 0..4  Gear.better(a, b) -> boolean
--   Gear.describe(item) -> string    Gear.bossChest(rng, tier, stage) -> {item}
--   Gear.cartOffers(rng, tier, stage) -> (offers, prices)
--   Gear.clean(items) -> {weapon?, armor?, trinket?} (validated copies)

local Types = require("../Types")
local Rng = require("../Util/Rng")
local Config = require("../Config/Gear")

type PlayerStats = Types.PlayerStats
type WeaponDef = Types.WeaponDef
type AbilityDef = Types.AbilityDef
type Rng = Rng.Rng
export type GearItem = Config.GearItem

local Gear = {}

Gear.CHEST_ITEMS = 2 -- boss chest
Gear.CHEST_MIN = "Rare"
Gear.CART_OFFERS = 3

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Items ------------------------------------------------------------------------------

function Gear.make(id: string, rarity: string?): GearItem?
	local def = Config.get(id)
	local r = rarity or "Common"
	if not def or not Config.rarityIndex(r) then
		return nil
	end
	return { id = def.id, slot = def.slot, rarity = r :: any }
end

-- A well-formed item whose id, slot and rarity agree with Config/Gear.
function Gear.valid(item: any): boolean
	if type(item) ~= "table" or type(item.id) ~= "string" then
		return false
	end
	local def = Config.get(item.id)
	return def ~= nil and item.slot == def.slot and Config.rarityIndex(item.rarity) ~= nil
end

function Gear.rank(x: any): number
	if type(x) == "table" then
		x = x.rarity
	end
	return Config.rarityIndex(x) or 0
end

-- Is `a` an upgrade over `b` (higher rarity; anything beats nothing)?
function Gear.better(a: any, b: any): boolean
	return Gear.rank(a) > Gear.rank(b)
end

-- {weapon?, armor?, trinket?} from a slot map or a list; invalid entries dropped,
-- later duplicates of a slot replace earlier ones.
function Gear.clean(items: any): { [string]: GearItem }
	local out: { [string]: GearItem } = {}
	if type(items) ~= "table" then
		return out
	end
	local function take(it: any)
		if Gear.valid(it) then
			out[it.slot] = { id = it.id, slot = it.slot, rarity = it.rarity }
		end
	end
	for _, slot in Config.SLOTS do
		take(items[slot])
	end
	for _, it in ipairs(items) do
		take(it)
	end
	return out
end

-- Apply ---------------------------------------------------------------------------------

local function applyEffect(t: { [string]: any }, field: string, op: string, v: number, default: number)
	local cur = t[field]
	if not finite(cur) then
		cur = default
	end
	if op == "add" then
		t[field] = cur + v
	elseif op == "mul" then
		t[field] = cur * v
	elseif op == "max" then
		t[field] = math.max(cur, v)
	end
end

-- Defaults for fields an older stats table may lack (multipliers start at 1).
local MUL_DEFAULT: { [string]: number } = {
	heroDamageMult = 1,
	reviveSpeedMult = 1,
	channelSpeedMult = 1,
	damageMult = 1,
	attackSpeedMult = 1,
	cooldownMult = 1,
	areaMult = 1,
	xpMult = 1,
	cheeseMult = 1,
	critMult = 1.5,
	pickupRadius = 8,
	moveSpeed = 16,
	maxHp = 100,
}

local function isItemSet(v: any): boolean
	if type(v) ~= "table" or v.kind ~= nil then
		return false
	end
	if #v > 0 then
		return Gear.valid(v[1])
	end
	if v.weapon ~= nil or v.armor ~= nil or v.trinket ~= nil then
		return true
	end
	return next(v) == nil
end

function Gear.apply(
	stats: PlayerStats,
	weapon: any,
	ability: any,
	items: any
): (PlayerStats, WeaponDef?, AbilityDef?)
	if items == nil and ability == nil and isItemSet(weapon) then
		-- Gear.apply(stats, items)
		items, weapon = weapon, nil
	end
	local s = table.clone(stats) :: any
	local w = if type(weapon) == "table" then table.clone(weapon) :: any else nil
	local a = if type(ability) == "table" then table.clone(ability) :: any else nil
	for _, it in Gear.clean(items) do
		local def = Config.get(it.id)
		local idx = Config.rarityIndex(it.rarity)
		if def and idx then
			for _, e in def.effects do
				local v = e.values[idx]
				if finite(v) then
					local target = if e.target == "stats" then s elseif e.target == "weapon" then w else a
					if target then
						applyEffect(
							target,
							e.field,
							e.op,
							v,
							MUL_DEFAULT[e.field] or (if e.op == "mul" then 1 else 0)
						)
					end
				end
			end
		end
	end
	if finite(s.maxHp) then
		s.maxHp = math.floor(s.maxHp + 0.5)
	end
	s.gearApplied = true
	return s :: PlayerStats, w :: WeaponDef?, a :: AbilityDef?
end

-- Rolls -------------------------------------------------------------------------------

local function tierShift(tier: any): number
	if type(tier) == "number" and finite(tier) then
		return math.clamp(tier, 0, 3)
	end
	return Config.TIER_SHIFT[tier] or 0
end

function Gear.rarityWeights(tier: any, stage: number?, luck: number?): { number }
	local st = if finite(stage) then math.max(1, stage :: number) else 1
	local shift = tierShift(tier)
		+ Config.STAGE_SHIFT * (st - 1)
		+ Config.LUCK_SHIFT * (if finite(luck) then math.max(0, luck :: number) else 0)
	local out = {}
	for i, r in Config.RARITIES do
		local w = Config.BASE_WEIGHTS[r] + Config.SHIFT_WEIGHTS[r] * shift
		if r == "Common" then
			w = math.max(Config.MIN_COMMON_WEIGHT, w)
		end
		out[i] = math.max(0, w)
	end
	return out
end

export type RollOpts = { minRarity: string?, slot: string?, luck: number? }

function Gear.roll(rng: Rng, tier: any, stage: number?, opts: RollOpts?): GearItem
	local o: RollOpts = opts or {}
	local weights = Gear.rarityWeights(tier, stage, o.luck)
	local minIdx = Config.rarityIndex(o.minRarity) or 1
	for i = 1, minIdx - 1 do
		weights[i] = 0
	end
	local ri = rng:weightedIndex(weights)
	local pool = if o.slot and Config.bySlot[o.slot] then Config.bySlot[o.slot] else nil
	local def
	if pool and #pool > 0 then
		def = pool[rng:nextInt(1, #pool)]
	else
		def = Config.get(Config.ORDER[rng:nextInt(1, #Config.ORDER)])
	end
	assert(def, "Gear.roll: no defs")
	return { id = def.id, slot = def.slot, rarity = Config.RARITIES[ri] }
end

-- Boss chest for the killing squad (RunDirector): CHEST_ITEMS items, Rare or better.
function Gear.bossChest(rng: Rng, tier: any, stage: number?): { GearItem }
	local out = {}
	for _ = 1, Gear.CHEST_ITEMS do
		table.insert(out, Gear.roll(rng, tier, stage, { minRarity = Gear.CHEST_MIN }))
	end
	return out
end

-- Shop Cart stock: one item per slot (weapon, armor, trinket) and their prices.
function Gear.cartOffers(rng: Rng, tier: any, stage: number?): ({ GearItem }, { number })
	local offers, prices = {}, {}
	for i = 1, Gear.CART_OFFERS do
		local slot = Config.SLOTS[(i - 1) % #Config.SLOTS + 1]
		local it = Gear.roll(rng, tier, stage, { slot = slot })
		table.insert(offers, it)
		table.insert(prices, Config.price(it.rarity, stage))
	end
	return offers, prices
end

-- Text -------------------------------------------------------------------------------------

local function fmtNum(v: number): string
	if math.abs(v - math.floor(v + 0.5)) < 1e-6 then
		return tostring(math.floor(v + 0.5))
	end
	return string.format("%.1f", v)
end

-- "+2 projectiles, -20% weapon damage" for an item (UI tooltips).
function Gear.describe(item: any): string
	if not Gear.valid(item) then
		return ""
	end
	local def = Config.get(item.id) :: Config.GearDef
	local idx = Config.rarityIndex(item.rarity) :: number
	local parts = {}
	for _, e in def.effects do
		local v = e.values[idx]
		local text
		if e.op == "mul" then
			local pct = math.floor((v - 1) * 100 + 0.5)
			text = string.format("%s%d%% %s", if pct >= 0 then "+" else "-", math.abs(pct), e.label)
		elseif e.pct then
			local pct = math.floor(v * 100 + 0.5)
			local sign = if e.field == "projectileResist" or e.field == "heroResist" then "-" else "+"
			text = string.format("%s%d%% %s", sign, pct, e.label)
		elseif e.op == "max" and (e.field == "reviveSpeedMult" or e.field == "channelSpeedMult") then
			text = string.format("x%s %s", fmtNum(v), e.label)
		else
			text = string.format("+%s %s", fmtNum(v), e.label)
		end
		table.insert(parts, text)
	end
	return table.concat(parts, ", ")
end

return Gear
