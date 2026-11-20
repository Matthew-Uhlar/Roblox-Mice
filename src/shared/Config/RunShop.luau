--!strict
-- v5 in-round upgrading (docs/V5-PLAN.md §A, corrected by docs/iter/1/PLAN.md §D).
-- Pure data + pure helpers, no state: Run/RunWallet (M2) keeps the balances and
-- purchases, Combat/World (M1) drops the currencies and applies the stat layer.
--
-- Currencies (reset every run, never payout cheese):
--   rinds: RINDS per kill x (1 + STAGE_SCALE x (stage - 1)) x the killer's rindMult
--          (x TOTEM_RIND_MULT while the squad holds a Power Totem). Squadmates within
--          SHARE_RADIUS of the killer get SHARE of it. Champions and bosses split their
--          amount by squad damage share (each member of a squad gets its squad's part).
--   whey:  +1 per WHEY_PER_RINDS rinds earned, WHEY.champion* per champion kill,
--          WHEY.poi per POI, WHEY.stage per stage survived (the last two: RunDirector).
-- Spending: stat ranks (rinds), whey buffs and the class buff (whey, at stalls), the
-- Big Cheese Altar's ultimates (rinds + whey, from ALTAR_FROM_STAGE), the Swap Stand
-- (rinds -> whey only, SWAP_RATE : 1 minus SWAP_FEE).
--
-- Every bonus is a Types.StatDelta {add, mul}: RunShop.combine(...) builds the one
-- delta that World.setRunMods(id, delta) layers on top of the hero's stats.
-- Optional stat keys read by World (Types.PlayerStats): rindMult, wheyMult,
-- damageTakenMult, abilityRepeat, herdguard, sizeMult.

local Types = require("../Types")

type StatDelta = Types.StatDelta

local RunShop = {}

-- Economy -------------------------------------------------------------------------------
RunShop.RINDS = table.freeze({ mouse = 1.9, elite = 6, champion = 75, boss = 285 }) -- iteration 2: x1.5 (4-stage median 6.5k vs 8-15k)
RunShop.STAGE_SCALE = 0.25 -- x (1 + this x (stage - 1))
RunShop.SHARE = 0.5 -- squadmates near the killer get this fraction...
RunShop.SHARE_RADIUS = 45 -- ...within this many studs
RunShop.TOTEM_RIND_MULT = 1.6 -- while the squad holds a Power Totem (PLAN §D: replaces boost zones)
RunShop.WHEY_PER_RINDS = 20 -- +1 whey per this many rinds earned (iter 3: was 25, then 10; 20 keeps a full run near ~1k whey)
RunShop.WHEY = table.freeze({
	poi = 40,
	championTop = 60,
	championOther = 30,
	stage = 50,
	-- iteration 4 objectives: fallbacks when the poiReward carries no `whey` (RunDirector)
	beaconChain = 60, -- the squad that lights a chain's last beacon
	rescue = 40,
	escort = 50,
})
-- Iteration 4 objectives: rinds per squad member (x the stage scale), on top of the kills
RunShop.OBJECTIVE_RINDS = table.freeze({ beaconChain = 120, rescue = 60, escort = 150 })
RunShop.XP_SHARE = 0.5 -- squadmates within XP_SHARE_RADIUS get this share of crumb XP
RunShop.XP_SHARE_RADIUS = 45

-- Stat ranks (rinds): the V menu, iteration 4's main source of in-round power ----------
-- Like Zombie World Liberty: no real cap (MAX_RANK is a safety stop), a linear price
-- `base + step * rank`, big per-rank values with diminishing returns past SOFT_RANK
-- (each rank counts SOFT_FACTOR) and past SOFT_CAP (each counts HARD_FACTOR).
RunShop.MAX_RANK = 250
RunShop.SOFT_RANK = 50
RunShop.SOFT_CAP = 100
RunShop.SOFT_FACTOR = 0.5
RunShop.HARD_FACTOR = 0.25

export type RankDef = {
	id: string,
	name: string,
	base: number, -- rind cost of rank 1
	step: number, -- + this per rank already owned
	add: { [string]: number }?, -- per (effective) rank, additive
	pct: { [string]: number }?, -- per (effective) rank, x (1 + pct x ranks)
	cap: { [string]: number }?, -- cap on the total pct (absolute value)
	description: string,
}

RunShop.RANK_ORDER = { "might", "hide", "plating", "mending", "frenzy", "stride", "reach", "focus" }
RunShop.RANKS = table.freeze({
	might = {
		id = "might",
		name = "Might",
		base = 20,
		step = 6,
		add = { pveDamageMult = 0.06, heroDamageMult = 0.025 },
		description = "+6% damage to mice and bosses, +2.5% to heroes",
	},
	hide = {
		id = "hide",
		name = "Hide",
		base = 20,
		step = 6,
		pct = { maxHp = 0.07 },
		description = "+7% max HP",
	},
	plating = {
		id = "plating",
		name = "Plating",
		base = 30,
		step = 9,
		add = { armor = 1 },
		description = "+1 armor (x0.35 against heroes)",
	},
	mending = {
		id = "mending",
		name = "Mending",
		base = 25,
		step = 7,
		add = { regen = 0.4 },
		description = "+0.4 HP/s",
	},
	frenzy = {
		id = "frenzy",
		name = "Frenzy",
		base = 30,
		step = 9,
		pct = { attackSpeedMult = 0.035 },
		description = "+3.5% attack speed",
	},
	stride = {
		id = "stride",
		name = "Stride",
		base = 25,
		step = 8,
		pct = { moveSpeed = 0.015 },
		cap = { moveSpeed = 0.3 },
		description = "+1.5% move speed (max +30%)",
	},
	reach = {
		id = "reach",
		name = "Reach",
		base = 15,
		step = 4,
		pct = { pickupRadius = 0.08 },
		cap = { pickupRadius = 3 },
		description = "+8% pickup range",
	},
	focus = {
		id = "focus",
		name = "Focus",
		base = 35,
		step = 10,
		pct = { cooldownMult = -0.025 },
		cap = { cooldownMult = 0.45 },
		description = "-2.5% ability cooldown (max -45%)",
	},
} :: { [string]: RankDef })

-- Whey buffs (stalls), class buffs (Class Stall), ultimates (Altar) ------------------------
export type BuffDef = { id: string, name: string, delta: StatDelta, description: string }

RunShop.BUFF_COST = 150 -- whey (iteration 3 T-10: was 250)
RunShop.CLASS_BUFF_COST = 300 -- whey (iteration 3 T-10: was 500)
RunShop.BUFF_ORDER = { "rush", "thick_skin", "keen", "leech", "bloom", "greed", "scholar", "bulwark" }
RunShop.BUFFS = table.freeze({
	rush = {
		id = "rush",
		name = "Rush",
		delta = { mul = { moveSpeed = 1.15 } },
		description = "+15% move speed",
	},
	thick_skin = {
		id = "thick_skin",
		name = "Thick Skin",
		delta = { mul = { maxHp = 1.2 } },
		description = "+20% max HP",
	},
	keen = {
		id = "keen",
		name = "Keen",
		delta = { add = { critChance = 0.1 } },
		description = "+10% crit chance",
	},
	leech = {
		id = "leech",
		name = "Leech",
		delta = { add = { lifesteal = 0.02 } },
		description = "Heal 2% of damage dealt",
	},
	bloom = { id = "bloom", name = "Bloom", delta = { mul = { areaMult = 1.25 } }, description = "+25% area" },
	greed = { id = "greed", name = "Greed", delta = { add = { rindMult = 0.3 } }, description = "+30% rinds" },
	scholar = {
		id = "scholar",
		name = "Scholar",
		delta = { mul = { xpMult = 1.3 } },
		description = "+30% XP",
	},
	bulwark = {
		id = "bulwark",
		name = "Bulwark",
		delta = { mul = { damageTakenMult = 0.85 } },
		description = "-15% damage taken",
	},
} :: { [string]: BuffDef })

-- One per class: that class's signature, amplified (keyed by class id).
RunShop.CLASS_BUFFS = table.freeze({
	elephante = {
		id = "elephante",
		name = "Thunder Tusks",
		delta = { mul = { areaMult = 1.3 }, add = { armor = 1 } },
		description = "+30% slam area, +1 armor",
	},
	ele_fonte = {
		id = "ele_fonte",
		name = "Deluge",
		delta = { add = { projectileBonus = 1, pierceBonus = 1 } },
		description = "+1 water jet, +1 pierce",
	},
	ellie_fawn = {
		id = "ellie_fawn",
		name = "Thornstorm",
		delta = { add = { projectileBonus = 2 } },
		description = "+2 peanuts per volley",
	},
	le_fante = {
		id = "le_fante",
		name = "Coup de Grace",
		delta = { add = { critChance = 0.15, critMult = 0.5 } },
		description = "+15% crit chance, +50% crit damage",
	},
	filet = {
		id = "filet",
		name = "Extra Cleaver",
		delta = { add = { projectileBonus = 1, regen = 1 } },
		description = "+1 orbiting cleaver, +1 HP/s",
	},
	jumbo = {
		id = "jumbo",
		name = "Gale Ears",
		delta = { mul = { areaMult = 1.3, cooldownMult = 0.8 } },
		description = "+30% gust area, -20% Updraft cooldown",
	},
	fizzante = {
		id = "fizzante",
		name = "Big Fizz",
		delta = { mul = { areaMult = 1.3 }, add = { explodeOnKill = 4 } },
		description = "+30% splash, mice pop on death",
	},
} :: { [string]: BuffDef })

RunShop.ALTAR_FROM_STAGE = 3
RunShop.ULTIMATE_MAX = 2 -- per hero
RunShop.ULTIMATE_COST = table.freeze({ rinds = 3000, whey = 300 }) -- iteration 3 T-10: was 6000 + 600
RunShop.HERDGUARD_RADIUS = 20 -- squadmates this close to a Herdguard hero...
RunShop.HERDGUARD_MULT = 0.88 -- ...take this much damage
RunShop.ULTIMATE_ORDER = { "titan", "cataclysm", "overdrive", "herdguard" }
RunShop.ULTIMATES = table.freeze({
	titan = {
		id = "titan",
		name = "Titan",
		delta = { mul = { maxHp = 1.4, sizeMult = 1.15 } },
		description = "+40% max HP, +15% size",
	},
	cataclysm = {
		id = "cataclysm",
		name = "Cataclysm",
		delta = { add = { abilityRepeat = 1 } },
		description = "Your ability hits twice",
	},
	overdrive = {
		id = "overdrive",
		name = "Overdrive",
		delta = { mul = { attackSpeedMult = 1.35 } },
		description = "+35% attack speed",
	},
	herdguard = {
		id = "herdguard",
		name = "Herdguard",
		delta = { add = { herdguard = 1 } },
		description = "Your squad takes -12% damage near you",
	},
} :: { [string]: BuffDef })

RunShop.SWAP_RATE = 5 -- rinds per whey... (iteration 3 T-10: was 10)
RunShop.SWAP_FEE = 0 -- ...minus this fee (rinds -> whey only; iteration 3 T-10: was 0.2)

-- Helpers ------------------------------------------------------------------------------------

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Rind cost of buying rank `rank + 1` of `statId`: base + step x rank (iteration 4,
-- linear). nil at MAX_RANK or for an unknown stat.
function RunShop.rankCost(statId: string, rank: number): number?
	local def = RunShop.RANKS[statId]
	local r = if finite(rank) then math.max(0, math.floor(rank)) else 0
	if not def or r >= RunShop.MAX_RANK then
		return nil
	end
	return def.base + def.step * r
end

-- Total rind cost of ranks 1..n of one stat.
function RunShop.rankTotal(statId: string, n: number): number
	local total = 0
	for r = 0, math.min(n, RunShop.MAX_RANK) - 1 do
		total += RunShop.rankCost(statId, r) or 0
	end
	return total
end

-- The ranks that count after diminishing returns: full up to SOFT_RANK, then
-- SOFT_FACTOR each up to SOFT_CAP, then HARD_FACTOR each.
function RunShop.effectiveRank(n: number): number
	local r = if finite(n) then math.clamp(math.floor(n), 0, RunShop.MAX_RANK) else 0
	local soft, cap = RunShop.SOFT_RANK, RunShop.SOFT_CAP
	return math.min(r, soft)
		+ RunShop.SOFT_FACTOR * math.clamp(r - soft, 0, cap - soft)
		+ RunShop.HARD_FACTOR * math.max(0, r - cap)
end

-- Rinds for a kill: kind = "mouse" | "elite" | "champion" | "boss".
function RunShop.rindsFor(kind: string, stage: number?): number
	local base = RunShop.RINDS[kind] or 0
	local st = if finite(stage) then math.max(1, stage :: number) else 1
	return base * (1 + RunShop.STAGE_SCALE * (st - 1))
end

-- Whey for rinds via the Swap Stand: (whey, rinds actually spent).
function RunShop.swap(rinds: number): (number, number)
	if not finite(rinds) or rinds <= 0 then
		return 0, 0
	end
	local whey = math.floor(rinds / RunShop.SWAP_RATE * (1 - RunShop.SWAP_FEE))
	return whey, math.ceil(whey * RunShop.SWAP_RATE / (1 - RunShop.SWAP_FEE))
end

-- Adds delta `d` into the accumulator `acc` (add: summed; mul: multiplied).
local function fold(acc: { add: { [string]: number }, mul: { [string]: number } }, d: StatDelta?)
	if not d then
		return
	end
	for k, v in d.add or {} do
		if finite(v) then
			acc.add[k] = (acc.add[k] or 0) + v
		end
	end
	for k, v in d.mul or {} do
		if finite(v) then
			acc.mul[k] = (acc.mul[k] or 1) * v
		end
	end
end

-- The StatDelta of a set of stat ranks {[statId] = n}.
function RunShop.rankDelta(ranks: { [string]: number }?): StatDelta
	local acc = { add = {}, mul = {} }
	for id, n in ranks or {} do
		local def = RunShop.RANKS[id]
		local r = RunShop.effectiveRank(n)
		if def and r > 0 then
			for k, per in def.add or {} do
				acc.add[k] = (acc.add[k] or 0) + per * r
			end
			for k, per in def.pct or {} do
				local total = per * r
				local cap = def.cap and def.cap[k]
				if cap then
					total = math.clamp(total, -cap, cap)
				end
				acc.mul[k] = (acc.mul[k] or 1) * (1 + total)
			end
		end
	end
	return acc
end

-- The one StatDelta for World.setRunMods: ranks + whey buffs (ids) + the class buff
-- (classBuff = true and classId) + ultimates (ids; at most ULTIMATE_MAX count).
function RunShop.combine(
	ranks: { [string]: number }?,
	buffs: { string }?,
	ultimates: { string }?,
	classId: string?,
	classBuff: boolean?
): StatDelta
	local acc = { add = {}, mul = {} }
	fold(acc, RunShop.rankDelta(ranks))
	local seen = {}
	for _, id in buffs or {} do
		local def = RunShop.BUFFS[id]
		if def and not seen[id] then
			seen[id] = true -- buffs stack with each other, never with themselves
			fold(acc, def.delta)
		end
	end
	if classBuff and classId and RunShop.CLASS_BUFFS[classId] then
		fold(acc, RunShop.CLASS_BUFFS[classId].delta)
	end
	local n = 0
	for _, id in ultimates or {} do
		local def = RunShop.ULTIMATES[id]
		if def and not seen["ult:" .. id] and n < RunShop.ULTIMATE_MAX then
			seen["ult:" .. id] = true
			n += 1
			fold(acc, def.delta)
		end
	end
	return acc
end

return RunShop
