--!strict
-- Run/RunWallet: the v5 in-run economy of one hero (docs/V5-PLAN.md §A, with the
-- iteration-1 corrections in docs/iter/1/PLAN.md §D). Pure: no Roblox, no clocks.
--
-- Two run currencies, both reset every run and never paid out as cheese:
--   * rinds: from kills (RunWallet.rindsFor; the World's `rinds` events when team
--     M1 sends them). Every RINDS_PER_WHEY (25) rinds earned also give 1 whey.
--   * whey: POIs, champion kills, stages survived (RunWallet.WHEY).
-- Spending (RunDirector validates the place and the phase; this module the money):
--   * Stat Ranks (8 stats, the V menu; iteration 4: no real cap, soft past 50 / 100):
--     base + step * rank rinds. Kept on death.
--   * Stall buffs (BUFF_COST whey), once per life; the Class Stall's class buff.
--   * Big Cheese Altar ultimates (stage 3+): ULTIMATE_COST, at most 2.
--   * Swap Stand: rinds -> whey only at SWAP_RATE.
--   * (iteration 4) the hero level's fixed gains (Run/Leveling) join deltas().
-- Knockout (dead, not just downed): every whey buff and ultimate is lost.
--
-- Prices, rates and deltas come from Config/RunShop (team M1). RunWallet.deltas(w) is the combined
-- Types.StatDelta (add / mul) that World applies as a stat layer
-- (world:setRunMods) or RunDirector folds into the hero's stats.

local Types = require("../Types")
local RunShop = require("../Config/RunShop")
local Leveling = require("./Leveling")

type StatDelta = Types.StatDelta

local RunWallet = {}

RunWallet.Shop = RunShop

export type Wallet = {
	rinds: number,
	whey: number,
	rindsEarned: number, -- lifetime this run (the 1-whey-per-25 counter and the sim guard)
	wheyEarned: number,
	wheyCarry: number, -- rinds towards the next bonus whey
	ranks: { [string]: number },
	buffs: { string }, -- whey buffs bought this life (ids; "class" = the class buff)
	ultimates: { string },
	spent: { rinds: number, whey: number },
	level: number?, -- iteration 4: the hero level (Leveling.levelDelta joins the layer)
}

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function RunWallet.new(): Wallet
	return {
		rinds = 0,
		whey = 0,
		rindsEarned = 0,
		wheyEarned = 0,
		wheyCarry = 0,
		ranks = {},
		buffs = {},
		ultimates = {},
		spent = { rinds = 0, whey = 0 },
		level = 1,
	}
end

-- Iteration 4: the hero's level, for the fixed per-level gains. True when it changed.
function RunWallet.setLevel(w: Wallet, level: number): boolean
	local l = if finite(level) then math.max(1, math.floor(level)) else 1
	if (w.level or 1) == l then
		return false
	end
	w.level = l
	return true
end

-- Earning ---------------------------------------------------------------------------------

-- Rinds for a kill of `kind` ("mouse" | "elite" | "champion" | "boss") at `stage`
-- (Config/RunShop; champion / boss amounts are split by damage share by the caller).
function RunWallet.rindsFor(kind: string, stage: number?): number
	return RunShop.rindsFor(kind, stage)
end

function RunWallet.hasBuff(w: Wallet, id: string): boolean
	return table.find(w.buffs, id) ~= nil
end

-- The hero's own rind multiplier (Greed). The World already applies it to its
-- `rinds` events; RunDirector's kill fallback passes it to earnRinds.
function RunWallet.rindMult(w: Wallet): number
	local add = 0
	for _, id in w.buffs do
		local def = RunShop.BUFFS[id]
		local a = def and def.delta.add and (def.delta.add :: any).rindMult
		if finite(a) then
			add += a
		end
	end
	return 1 + add
end

-- Adds rinds (x `mult`, default 1). Every WHEY_PER_RINDS earned also gives 1 whey,
-- unless `noTrickle` (the World already sends that whey as `whey` events).
-- Returns (rinds added, whey added).
function RunWallet.earnRinds(w: Wallet, amount: number, mult: number?, noTrickle: boolean?): (number, number)
	if not finite(amount) or amount <= 0 then
		return 0, 0
	end
	local n = amount * (if finite(mult) and (mult :: number) > 0 then mult :: number else 1)
	w.rinds += n
	w.rindsEarned += n
	if noTrickle then
		return n, 0
	end
	w.wheyCarry += n
	local whey = 0
	while w.wheyCarry >= RunShop.WHEY_PER_RINDS do
		w.wheyCarry -= RunShop.WHEY_PER_RINDS
		whey += 1
	end
	if whey > 0 then
		w.whey += whey
		w.wheyEarned += whey
	end
	return n, whey
end

function RunWallet.earnWhey(w: Wallet, amount: number): number
	if not finite(amount) or amount <= 0 then
		return 0
	end
	w.whey += amount
	w.wheyEarned += amount
	return amount
end

-- Spending --------------------------------------------------------------------------------

function RunWallet.rankCost(stat: string, rank: number): number?
	return RunShop.rankCost(stat, rank)
end

local function pay(w: Wallet, rinds: number, whey: number): boolean
	if w.rinds + 1e-9 < rinds or w.whey + 1e-9 < whey then
		return false
	end
	w.rinds -= rinds
	w.whey -= whey
	w.spent.rinds += rinds
	w.spent.whey += whey
	return true
end

-- Returns (ok, why?, cost?). why: "unknown" | "max" | "funds"
function RunWallet.buyRank(w: Wallet, stat: string): (boolean, string?, number?)
	if not RunShop.RANKS[stat] then
		return false, "unknown", nil
	end
	local rank = w.ranks[stat] or 0
	local cost = RunShop.rankCost(stat, rank)
	if cost == nil then
		return false, "max", nil
	end
	if not pay(w, cost, 0) then
		return false, "funds", cost
	end
	w.ranks[stat] = rank + 1
	return true, nil, cost
end

-- A stall buff ("class" = the class buff at the Class Stall). Once per life.
-- `offered` = the stall's offer list (nil: anything).
-- why: "unknown" | "offer" | "owned" | "funds"
function RunWallet.buyBuff(w: Wallet, buffId: string, offered: { string }?): (boolean, string?, number?)
	local isClass = buffId == "class"
	if not isClass and not RunShop.BUFFS[buffId] then
		return false, "unknown", nil
	end
	if offered and not table.find(offered, buffId) then
		return false, "offer", nil
	end
	if RunWallet.hasBuff(w, buffId) then
		return false, "owned", nil
	end
	local price = if isClass then RunShop.CLASS_BUFF_COST else RunShop.BUFF_COST
	if not pay(w, 0, price) then
		return false, "funds", price
	end
	table.insert(w.buffs, buffId)
	return true, nil, price
end

-- why: "unknown" | "stage" | "owned" | "max" | "funds"
function RunWallet.buyUltimate(w: Wallet, id: string, stage: number): (boolean, string?)
	if not RunShop.ULTIMATES[id] then
		return false, "unknown"
	end
	if not finite(stage) or stage < RunShop.ALTAR_FROM_STAGE then
		return false, "stage"
	end
	if table.find(w.ultimates, id) then
		return false, "owned"
	end
	if #w.ultimates >= RunShop.ULTIMATE_MAX then
		return false, "max"
	end
	local cost = RunShop.ULTIMATE_COST
	if not pay(w, cost.rinds, cost.whey) then
		return false, "funds"
	end
	table.insert(w.ultimates, id)
	return true, nil
end

-- Swap Stand (rinds -> whey only): spends up to `rinds` rinds. Returns (whey
-- gained, rinds spent); (0, 0) when it cannot buy a single whey.
function RunWallet.swapToWhey(w: Wallet, rinds: number): (number, number)
	if not finite(rinds) or rinds <= 0 then
		return 0, 0
	end
	local whey, spent = RunShop.swap(math.min(rinds, w.rinds))
	if whey < 1 or not pay(w, spent, 0) then
		return 0, 0
	end
	w.whey += whey
	return whey, spent
end

-- Knocked out (dead, not just downed): every whey buff and ultimate is lost.
-- Rinds, whey and ranks stay. Returns the lost ids.
function RunWallet.knockout(w: Wallet): { string }
	local lost = {}
	for _, id in w.buffs do
		table.insert(lost, id)
	end
	for _, id in w.ultimates do
		table.insert(lost, id)
	end
	w.buffs = {}
	w.ultimates = {}
	return lost
end

-- Stat layer ------------------------------------------------------------------------------

-- The combined StatDelta of ranks, buffs (class buff for `classId`) and ultimates
-- (RunShop.combine): what World.setRunMods(id, delta) layers on the hero.
function RunWallet.deltas(w: Wallet, classId: string?): StatDelta
	local buffs = {}
	for _, id in w.buffs do
		if id ~= "class" then
			table.insert(buffs, id)
		end
	end
	local d = RunShop.combine(w.ranks, buffs, w.ultimates, classId, RunWallet.hasBuff(w, "class"))
	-- iteration 4: the fixed per-level gains ride on the same layer
	local lvl = Leveling.levelDelta(w.level or 1)
	local add, mul = d.add or {}, d.mul or {}
	for k, v in lvl.add do
		add[k] = (add[k] or 0) + v
	end
	for k, v in lvl.mul do
		mul[k] = (mul[k] or 1) * v
	end
	return { add = add, mul = mul }
end

-- The S2C Wallet payload.
function RunWallet.view(w: Wallet): { [string]: any }
	return {
		rinds = math.floor(w.rinds),
		whey = math.floor(w.whey),
		ranks = table.clone(w.ranks),
		buffs = table.clone(w.buffs),
		ultimates = table.clone(w.ultimates),
		rindsEarned = math.floor(w.rindsEarned),
		level = w.level or 1,
	}
end

-- Stall layout ----------------------------------------------------------------------------

export type Stall = { id: string, x: number, z: number, offers: { string }, class: boolean }

RunWallet.STALL_COUNT = 5
RunWallet.STALL_RING = 0.55 -- x R from the centre
RunWallet.CLASS_STALL_OFFSET = 0.12 -- x R
RunWallet.SWAP_OFFSET = 10 -- studs from the Altar
RunWallet.STALL_RADIUS = 10 -- interaction range (studs)
RunWallet.ALTAR_RADIUS = 14

-- Deterministic per stage: `rng` (Util/Rng) picks each stall's 2 offers and the
-- ring's rotation. Returns stalls (class stall last), altar {x, z}, swap {x, z}.
function RunWallet.layout(
	rng: any,
	R: number,
	cx: number?,
	cz: number?
): ({ Stall }, { x: number, z: number }, { x: number, z: number })
	local ox, oz = cx or 0, cz or 0
	local stalls: { Stall } = {}
	local rot = rng:range(0, math.pi * 2)
	local n = RunWallet.STALL_COUNT
	for i = 1, n do
		local a = rot + (i - 1) * math.pi * 2 / n
		local pool = table.clone(RunShop.BUFF_ORDER)
		rng:shuffle(pool)
		table.insert(stalls, {
			id = "s" .. i,
			x = ox + math.cos(a) * R * RunWallet.STALL_RING,
			z = oz + math.sin(a) * R * RunWallet.STALL_RING,
			offers = { pool[1], pool[2] },
			class = false,
		})
	end
	local ca = rot + math.pi / n
	table.insert(stalls, {
		id = "class",
		x = ox + math.cos(ca) * R * RunWallet.CLASS_STALL_OFFSET,
		z = oz + math.sin(ca) * R * RunWallet.CLASS_STALL_OFFSET,
		offers = { "class" },
		class = true,
	})
	return stalls, { x = ox, z = oz }, { x = ox + RunWallet.SWAP_OFFSET, z = oz }
end

function RunWallet.near(x: number, z: number, px: number, pz: number, r: number): boolean
	return (x - px) ^ 2 + (z - pz) ^ 2 <= r * r
end

return RunWallet
