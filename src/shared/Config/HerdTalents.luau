--!strict
-- Herd Talent Board (v5 B1, iteration 1 corrections Z-2 / Z-3 / Z-12 / Z-13 / Z-15).
-- Pure data. Data/HerdTalents holds the rules.
--
-- ONE board for the whole account (switching class is never punished). Talent points
-- (TP, shown on the ×10 scale of Z-3) are earned in matches; ranks cost 10 / 20 / 30 TP
-- (ranks 1-10 / 11-30 / 31+). Never sold for Robux; nothing here is random.
-- Damage from the board is PvE-only (stats.pveDamageMult): long-term grind never
-- decides PvP. Other stats apply as listed.
--
-- `stat` effects (Run/Stats via Data/HerdTalents.bonuses):
--   pve         + per rank to stats.pveDamageMult (additive fraction)
--   addStat     + per rank to a PlayerStats field (add)
--   pctStat     + per rank as a fraction of a PlayerStats field (one multiplier)
--   cutStat     - per rank as a fraction of a PlayerStats field (cooldownMult)
--   extra       + per rank to a run bonus M2 reads (rindMult, wheyMult, redeployCut,
--               startRinds, startWhey; Data/HerdTalents.bonuses().extras)

export type TalentDef = {
	id: string,
	name: string,
	text: string, -- "%s" = the total at the current rank
	maxRank: number,
	per: number,
	effect: "pve" | "addStat" | "pctStat" | "cutStat" | "extra",
	field: string?, -- PlayerStats field or extras key
	field2: string?, -- a second extras key with the same value (Scavenger: rinds and whey)
}

local H = {}

-- Rank costs: COSTS[i] = {fromRank, tp}. Rank r costs the tp of the last entry with fromRank <= r.
H.COSTS = { { 1, 10 }, { 11, 20 }, { 31, 30 } }

-- Talent-point income per match (Data/HerdTalents.runPoints).
H.INCOME = table.freeze({
	boss = 30, -- per boss defeated (stage cleared) while in the run
	champion = 10, -- per Mouse Champion killed with squad credit
	stageAlive = 10, -- per stage cleared alive
	extract = 20,
	win = 50, -- Data/Award win rule (Last Herd, or extraction after 3+ clears)
	pressurePerPoint = 0.2, -- x (1 + 0.2 x Pressure points of the run)
	outcomeExtract = 1.5, -- x1.5 for extracting (or Last Herd)
	outcomeFullClear = 2, -- x2 for a full 4-stage clear (replaces x1.5)
	firstOfDayBonusCap = 100, -- the first match of the UTC day pays double, up to +100
})

-- Weekly full-clear bonus by Pressure band, once per band per UTC week (Monday).
H.WEEKLY_BANDS = {
	{ min = 0, max = 4, tp = 100 },
	{ min = 5, max = 9, tp = 250 },
	{ min = 10, max = 14, tp = 500 },
	{ min = 15, max = 19, tp = 900 },
	{ min = 20, max = 21, tp = 1500 },
}

-- Respec: free once per UTC day, otherwise RESPEC_CHEESE.
H.RESPEC_CHEESE = 2000

local function t(
	id: string,
	name: string,
	text: string,
	maxRank: number,
	per: number,
	effect: any,
	field: string?,
	field2: string?
): TalentDef
	return {
		id = id,
		name = name,
		text = text,
		maxRank = maxRank,
		per = per,
		effect = effect,
		field = field,
		field2 = field2,
	}
end

H.LIST = {
	t("brawn", "Brawn", "+%s damage to mice, champions and bosses", 50, 0.005, "pve"),
	t("bulk", "Bulk", "+%s max HP", 50, 0.006, "pctStat", "maxHp"),
	t("guard", "Guard", "+%s armor", 50, 0.1, "addStat", "armor"),
	t("vigor", "Vigor", "+%s HP/s regeneration", 50, 0.03, "addStat", "regen"),
	t("haste", "Haste", "+%s attack speed", 50, 0.0025, "addStat", "attackSpeedMult"),
	t("fleet", "Fleet", "+%s move speed", 50, 0.0015, "pctStat", "moveSpeed"),
	t("insight", "Insight", "+%s in-run XP", 50, 0.006, "addStat", "xpMult"),
	t("scavenger", "Scavenger", "+%s rinds and whey", 50, 0.008, "extra", "rindMult", "wheyMult"),
	t("focus", "Focus", "-%s ability cooldown", 25, 0.002, "cutStat", "cooldownMult"),
	t("homing_call", "Homing Call", "-%s s Herd Call (redeploy) delay", 20, 0.15, "extra", "redeployCut"),
	t("packed_lunch", "Packed Lunch", "+%s rinds at the start of a match", 20, 20, "extra", "startRinds"),
	t("canteen", "Canteen", "+%s whey at the start of a match", 10, 5, "extra", "startWhey"),
} :: { TalentDef }

H.byId = {} :: { [string]: TalentDef }
for _, def in H.LIST do
	H.byId[def.id] = def
end

function H.get(id: any): TalentDef?
	if type(id) ~= "string" then
		return nil
	end
	return H.byId[id]
end

-- TP cost of buying rank `rank` (1-based).
function H.rankCost(rank: number): number
	local cost = H.COSTS[1][2]
	for _, c in H.COSTS do
		if rank >= c[1] then
			cost = c[2]
		end
	end
	return cost
end

-- TP spent to reach `rank` from 0.
function H.totalCost(rank: number): number
	local n = 0
	for r = 1, math.max(0, math.floor(rank)) do
		n += H.rankCost(r)
	end
	return n
end

-- Weekly band of a Pressure value (1..#WEEKLY_BANDS).
function H.bandFor(pressure: number): number
	local p = if type(pressure) == "number" and pressure == pressure then math.floor(pressure) else 0
	for i, b in H.WEEKLY_BANDS do
		if p >= b.min and p <= b.max then
			return i
		end
	end
	return if p > 21 then #H.WEEKLY_BANDS else 1
end

return H
