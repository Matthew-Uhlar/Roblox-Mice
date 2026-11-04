--!strict
-- Run-only gear (docs/GDD-v2.md §3). Pure data: Run/Gear.luau applies and rolls
-- it, Combat/World owns ground items, swap offers and loot bags.
--
-- Every hero has 3 slots (weapon mod, armor, trinket). An item instance is a
-- plain, JSON-safe table {id, slot, rarity} (rarity = Types.Rarity). The numbers
-- come from the def's `effects`, one value per rarity (Common, Rare, Epic,
-- Legendary), so every tier is strictly better than the one below.
--
-- An effect targets "stats" (Types.PlayerStats, including the v2 optional
-- fields World reads: burnDps, slowOnHit, projectileResist, heroDamageMult,
-- heroResist, reviveSpeedMult, extractBonus, channelSpeedMult, downedHitsBonus,
-- downedTimeBonus, thorns, dodge), "weapon" (Types.WeaponDef) or "ability"
-- (Types.AbilityDef):
--   op "add"  field += v       op "mul"  field *= v       op "max"  field = max(field, v)
-- Gear can never be bought with Robux (GDD-v2 §7): the Shop Cart sells it for
-- in-run pending cheese only (PRICE below).

local Types = require("../Types")

type Rarity = Types.Rarity

export type GearSlot = "weapon" | "armor" | "trinket"
export type GearEffect = {
	target: "stats" | "weapon" | "ability",
	field: string,
	op: "add" | "mul" | "max",
	values: { number }, -- Common, Rare, Epic, Legendary
	label: string, -- "projectiles", "weapon damage", ...
	pct: boolean?, -- show an "add" value as a percentage (0.15 -> +15%)
}
export type GearDef = {
	id: string,
	name: string,
	slot: GearSlot,
	flavor: string,
	effects: { GearEffect },
}
export type GearItem = { id: string, slot: GearSlot, rarity: Rarity }

local Gear = {}

Gear.SLOTS = { "weapon", "armor", "trinket" } :: { GearSlot }
Gear.RARITIES = { "Common", "Rare", "Epic", "Legendary" } :: { Rarity }
Gear.RANK = table.freeze({ Common = 1, Rare = 2, Epic = 3, Legendary = 4 }) :: { [string]: number }
Gear.COLORS = table.freeze({
	Common = { 200, 200, 200 },
	Rare = { 80, 160, 255 },
	Epic = { 190, 90, 255 },
	Legendary = { 255, 170, 40 },
})

-- Rarity roll (Run/Gear.rarityWeights): base weights, shifted by the route tier,
-- the stage and luck. shift = TIER_SHIFT[tier] + STAGE_SHIFT * (stage - 1) + LUCK_SHIFT * luck
Gear.BASE_WEIGHTS = table.freeze({ Common = 60, Rare = 28, Epic = 10, Legendary = 2 })
Gear.SHIFT_WEIGHTS = table.freeze({ Common = -12, Rare = 4, Epic = 5, Legendary = 2 }) -- per point of shift
Gear.MIN_COMMON_WEIGHT = 10
Gear.TIER_SHIFT = table.freeze({ Low = 0, Mid = 1, High = 2 })
Gear.STAGE_SHIFT = 0.5
Gear.LUCK_SHIFT = 0.5

-- Shop Cart price in pending cheese: PRICE[rarity] * (1 + PRICE_PER_STAGE * (stage - 1))
Gear.PRICE = table.freeze({ Common = 60, Rare = 120, Epic = 220, Legendary = 400 })
Gear.PRICE_PER_STAGE = 0.2

local function fx(
	target: "stats" | "weapon" | "ability",
	field: string,
	op: "add" | "mul" | "max",
	values: { number },
	label: string,
	pct: boolean?
): GearEffect
	return { target = target, field = field, op = op, values = values, label = label, pct = pct }
end

local LIST: { GearDef } = {
	-- Weapon mods: change the auto-weapon --------------------------------------------
	{
		id = "splitting_shots",
		name = "Splitting Shots",
		slot = "weapon",
		flavor = "More projectiles, each a little weaker.",
		effects = {
			fx("stats", "projectileBonus", "add", { 1, 2, 2, 3 }, "projectiles"),
			fx("weapon", "damage", "mul", { 0.85, 0.8, 0.9, 0.9 }, "weapon damage"),
		},
	},
	{
		id = "cheddar_rounds",
		name = "Cheddar Rounds",
		slot = "weapon",
		flavor = "Hits set mice (and rivals) on fire for 3 s.",
		effects = { fx("stats", "burnDps", "max", { 3, 5, 8, 12 }, "burn damage per second") },
	},
	{
		id = "heavy_trunk",
		name = "Heavy Trunk",
		slot = "weapon",
		flavor = "Bigger, heavier swings.",
		effects = {
			fx("weapon", "knockback", "mul", { 1.3, 1.5, 1.75, 2 }, "knockback"),
			fx("stats", "areaMult", "mul", { 1.1, 1.15, 1.2, 1.3 }, "area"),
		},
	},
	{
		id = "rapid_tusks",
		name = "Rapid Tusks",
		slot = "weapon",
		flavor = "Your weapon fires faster.",
		effects = { fx("stats", "attackSpeedMult", "mul", { 1.1, 1.15, 1.22, 1.3 }, "attack speed") },
	},
	{
		id = "ivory_piercer",
		name = "Ivory Piercer",
		slot = "weapon",
		flavor = "Shots pass through more mice.",
		effects = {
			fx("stats", "pierceBonus", "add", { 1, 1, 2, 3 }, "pierce"),
			fx("weapon", "damage", "mul", { 1, 1.05, 1.05, 1.1 }, "weapon damage"),
		},
	},
	{
		id = "static_peanut",
		name = "Static Peanut",
		slot = "weapon",
		flavor = "Hits arc to nearby targets.",
		effects = { fx("stats", "chain", "add", { 1, 1, 2, 2 }, "chain jumps") },
	},
	{
		id = "sharp_tusk",
		name = "Sharp Tusk",
		slot = "weapon",
		flavor = "More and bigger critical hits (never against heroes).",
		effects = {
			fx("stats", "critChance", "add", { 0.05, 0.08, 0.12, 0.16 }, "crit chance", true),
			fx("stats", "critMult", "add", { 0.1, 0.2, 0.3, 0.5 }, "crit damage", true),
		},
	},
	{
		id = "leech_fang",
		name = "Leech Fang",
		slot = "weapon",
		flavor = "Heal for part of the damage you deal.",
		effects = { fx("stats", "lifesteal", "add", { 0.02, 0.03, 0.05, 0.07 }, "lifesteal", true) },
	},
	{
		id = "volatile_crumbs",
		name = "Volatile Crumbs",
		slot = "weapon",
		flavor = "Mice you kill explode.",
		effects = { fx("stats", "explodeOnKill", "max", { 3, 4, 5, 6 }, "stud kill explosions") },
	},
	{
		id = "frost_spray",
		name = "Frost Spray",
		slot = "weapon",
		flavor = "Hits slow their target for 1.2 s.",
		effects = { fx("stats", "slowOnHit", "max", { 0.2, 0.25, 0.3, 0.4 }, "slow on hit", true) },
	},
	{
		id = "hunters_mark",
		name = "Hunter's Mark",
		slot = "weapon",
		flavor = "Deal more damage to rival heroes.",
		effects = { fx("stats", "heroDamageMult", "mul", { 1.1, 1.15, 1.22, 1.3 }, "damage to heroes") },
	},
	-- Armor: defence -------------------------------------------------------------------
	{
		id = "rind_plate",
		name = "Rind Plate",
		slot = "armor",
		flavor = "Thick cheese rind: more max HP.",
		effects = { fx("stats", "maxHp", "mul", { 1.1, 1.18, 1.25, 1.35 }, "max HP") },
	},
	{
		id = "swiss_mesh",
		name = "Swiss Mesh",
		slot = "armor",
		flavor = "Projectiles slip through the holes.",
		effects = {
			fx("stats", "projectileResist", "add", { 0.15, 0.22, 0.3, 0.4 }, "projectile damage taken", true),
		},
	},
	{
		id = "bark_hide",
		name = "Bark Hide",
		slot = "armor",
		flavor = "Flat damage reduction on every hit.",
		effects = { fx("stats", "armor", "add", { 1, 2, 3, 4 }, "armor") },
	},
	{
		id = "wax_coat",
		name = "Wax Coat",
		slot = "armor",
		flavor = "Slowly heals you.",
		effects = { fx("stats", "regen", "add", { 0.5, 1, 1.5, 2.5 }, "HP per second") },
	},
	{
		id = "padded_boots",
		name = "Padded Boots",
		slot = "armor",
		flavor = "Move faster.",
		effects = { fx("stats", "moveSpeed", "mul", { 1.05, 1.08, 1.12, 1.16 }, "move speed") },
	},
	{
		id = "tusk_guard",
		name = "Tusk Guard",
		slot = "armor",
		flavor = "Take less damage from rival heroes.",
		effects = { fx("stats", "heroResist", "add", { 0.1, 0.15, 0.2, 0.28 }, "damage from heroes", true) },
	},
	{
		id = "stubborn_hide",
		name = "Stubborn Hide",
		slot = "armor",
		flavor = "Harder to finish off while downed.",
		effects = {
			fx("stats", "downedHitsBonus", "add", { 1, 1, 2, 2 }, "hits to finish you"),
			fx("stats", "downedTimeBonus", "add", { 3, 5, 6, 8 }, "s downed timer"),
		},
	},
	{
		id = "brie_padding",
		name = "Brie Padding",
		slot = "armor",
		flavor = "Soft but sturdy: HP and armor.",
		effects = {
			fx("stats", "maxHp", "mul", { 1.05, 1.08, 1.12, 1.16 }, "max HP"),
			fx("stats", "armor", "add", { 1, 1, 2, 2 }, "armor"),
		},
	},
	{
		id = "thorn_mail",
		name = "Thorn Mail",
		slot = "armor",
		flavor = "Mice that bump into you take damage back.",
		effects = { fx("stats", "thorns", "add", { 0.5, 0.8, 1.2, 1.6 }, "contact damage reflected", true) },
	},
	{
		id = "feather_fluff",
		name = "Feather Fluff",
		slot = "armor",
		flavor = "A chance to dodge any hit.",
		effects = { fx("stats", "dodge", "add", { 0.05, 0.08, 0.11, 0.15 }, "dodge chance", true) },
	},
	-- Trinkets: utility --------------------------------------------------------------------
	{
		id = "mouse_whistle",
		name = "Mouse Whistle",
		slot = "trinket",
		flavor = "More XP from crumbs.",
		effects = { fx("stats", "xpMult", "mul", { 1.1, 1.18, 1.3, 1.4 }, "XP") },
	},
	{
		id = "lucky_cheese",
		name = "Lucky Cheese",
		slot = "trinket",
		flavor = "Better upgrade cards.",
		effects = { fx("stats", "luck", "add", { 0.5, 1, 1.5, 2 }, "luck") },
	},
	{
		id = "portal_charm",
		name = "Portal Charm",
		slot = "trinket",
		flavor = "Extracting keeps more cheese.",
		effects = {
			fx("stats", "extractBonus", "max", { 0.05, 0.08, 0.12, 0.15 }, "cheese on Extract", true),
		},
	},
	{
		id = "revive_bell",
		name = "Revive Bell",
		slot = "trinket",
		flavor = "Revive squad-mates (and get revived) faster.",
		effects = { fx("stats", "reviveSpeedMult", "max", { 1.3, 1.5, 1.75, 2 }, "revive speed") },
	},
	{
		id = "crumb_magnet",
		name = "Crumb Magnet",
		slot = "trinket",
		flavor = "Pick up crumbs from further away.",
		effects = { fx("stats", "pickupRadius", "mul", { 1.25, 1.4, 1.6, 1.8 }, "pickup radius") },
	},
	{
		id = "sand_hourglass",
		name = "Sand Hourglass",
		slot = "trinket",
		flavor = "Your ability recharges faster.",
		effects = { fx("stats", "cooldownMult", "mul", { 0.92, 0.88, 0.84, 0.78 }, "ability cooldown") },
	},
	{
		id = "treasure_nose",
		name = "Treasure Nose",
		slot = "trinket",
		flavor = "Channel POIs and loot bags faster.",
		effects = { fx("stats", "channelSpeedMult", "max", { 1.2, 1.3, 1.45, 1.6 }, "channel speed") },
	},
	{
		id = "echo_horn",
		name = "Echo Horn",
		slot = "trinket",
		flavor = "A bigger, harder-hitting ability.",
		effects = {
			fx("ability", "area", "mul", { 1.1, 1.15, 1.22, 1.3 }, "ability area"),
			fx("ability", "damage", "mul", { 1.1, 1.15, 1.22, 1.3 }, "ability damage"),
		},
	},
	{
		id = "cheese_coin",
		name = "Cheese Coin",
		slot = "trinket",
		flavor = "A little more cheese from everything.",
		effects = { fx("stats", "cheeseMult", "mul", { 1.05, 1.08, 1.12, 1.15 }, "cheese") },
	},
	{
		id = "war_drum",
		name = "War Drum",
		slot = "trinket",
		flavor = "All your damage is a bit higher.",
		effects = { fx("stats", "damageMult", "mul", { 1.04, 1.06, 1.09, 1.12 }, "damage") },
	},
}

local byId: { [string]: GearDef } = {}
local bySlot: { [string]: { GearDef } } = { weapon = {}, armor = {}, trinket = {} }
Gear.ORDER = {} :: { string }
for _, def in LIST do
	assert(byId[def.id] == nil, "Config/Gear: duplicate id " .. def.id)
	byId[def.id] = def
	table.insert(bySlot[def.slot], def)
	table.insert(Gear.ORDER, def.id)
end
Gear.defs = byId
Gear.bySlot = bySlot

function Gear.get(id: string): GearDef?
	return byId[id]
end

-- Index into an effect's `values` for a rarity (1..4), or nil for an unknown one.
function Gear.rarityIndex(rarity: any): number?
	return if type(rarity) == "string" then Gear.RANK[rarity] else nil
end

-- Shop Cart price (pending cheese) of an item on this stage.
function Gear.price(rarity: string, stage: number?): number
	local base = Gear.PRICE[rarity] or Gear.PRICE.Common
	local s = math.max(1, math.floor(stage or 1))
	return math.floor(base * (1 + Gear.PRICE_PER_STAGE * (s - 1)) + 0.5)
end

return Gear
