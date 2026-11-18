--!strict
-- Charms (v5 B3, simplified by iteration 1 Z-7 / Z-20). Pure data; Data/Charms holds
-- the rules. Fortune and Luck charms are dropped (they touched cheese and loot).
--
-- * Drops are FREE game rewards (never sold, never rerolled for Robux, not in any shop):
--   one per member of the top-damage squad for each boss, plus an end-of-match chance
--   by stage reached. The rarity roll is weighted, with a FLOOR from the Pressure band of
--   the run (a charm's `tier`): higher Pressure gives better charms.
-- * Fuse: 3 charms of the same type and rarity make 1 of the next rarity.
-- * Salvage: a charm becomes a little cheese.
-- * Equipped charms are a SQUAD aura: every member of the squad (bots too) gets the
--   bonus. The same type from several squadmates doesn't stack: the highest rarity wins.
-- * Damage bonuses are PvE-only (stats.pveDamageMult); Warding is PvE damage taken.

export type CharmType = {
	id: string,
	name: string,
	text: string, -- "%s" = the value
	values: { number }, -- by rarity 1..4 (Common, Rare, Epic, Legendary)
	effect: "pve" | "pctStat" | "addStat" | "cutStat" | "extra",
	field: string?,
}

local C = {}

C.RARITIES = { "Common", "Rare", "Epic", "Legendary" }
C.WEIGHTS = { 70, 22, 7, 1 }
C.INVENTORY = 60
C.SOCKET_LEVELS = { 1, 10, 25 } -- account level that opens socket 1 / 2 / 3
C.SALVAGE_CHEESE = { 25, 100, 400, 1500 }
C.FUSE_COUNT = 3
C.STAGE_DROP_CHANCE = { 0.25, 0.45, 0.70, 1.0 } -- end of match, by stage reached
C.RARE_FROM_STAGE = 4 -- reaching stage 4 guarantees Rare+
C.MAX_GRANTS_PER_DAY = 80 -- logged above this (dupe watch, Z-17); never refused
-- Pressure band -> tier (1..5) and its rarity floor (Z-7)
C.TIER_FLOOR = { 1, 1, 2, 2, 3 }

local function c(
	id: string,
	name: string,
	text: string,
	values: { number },
	effect: any,
	field: string?
): CharmType
	return { id = id, name = name, text = text, values = values, effect = effect, field = field }
end

C.TYPES = {
	c("might", "Might", "+%s damage to mice, champions and bosses", { 0.02, 0.04, 0.06, 0.09 }, "pve"),
	c("vigor", "Vigor", "+%s max HP", { 0.03, 0.05, 0.08, 0.12 }, "pctStat", "maxHp"),
	c("swiftness", "Swiftness", "+%s move speed", { 0.02, 0.03, 0.05, 0.07 }, "pctStat", "moveSpeed"),
	c("wisdom", "Wisdom", "+%s in-run XP", { 0.05, 0.08, 0.12, 0.18 }, "addStat", "xpMult"),
	c("plenty", "Plenty", "+%s rinds", { 0.04, 0.07, 0.10, 0.15 }, "extra", "rindMult"),
	c("spring", "Spring", "+%s whey", { 0.04, 0.07, 0.10, 0.15 }, "extra", "wheyMult"),
	c("mending", "Mending", "+%s HP/s regeneration", { 0.2, 0.3, 0.5, 0.8 }, "addStat", "regen"),
	c("focus", "Focus", "-%s ability cooldown", { 0.03, 0.05, 0.07, 0.10 }, "cutStat", "cooldownMult"),
	c("haste", "Haste", "+%s attack speed", { 0.02, 0.03, 0.05, 0.07 }, "addStat", "attackSpeedMult"),
	c(
		"warding",
		"Warding",
		"-%s damage taken from mice and bosses",
		{ 0.02, 0.03, 0.05, 0.07 },
		"extra",
		"pveResist"
	),
} :: { CharmType }

C.byId = {} :: { [string]: CharmType }
C.ORDER = {} :: { string }
for _, def in C.TYPES do
	C.byId[def.id] = def
	table.insert(C.ORDER, def.id)
end

function C.get(id: any): CharmType?
	if type(id) ~= "string" then
		return nil
	end
	return C.byId[id]
end

-- Tier (1..5) of a run at `pressure` points (the Herd Talent weekly bands).
function C.tierFor(pressure: number): number
	local p = if type(pressure) == "number" and pressure == pressure then math.floor(pressure) else 0
	return math.clamp(math.floor(p / 5) + 1, 1, 5)
end

return C
