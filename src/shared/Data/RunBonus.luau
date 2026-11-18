--!strict
-- (v5) Run bonuses from long-term progression: the Herd Talent Board, Evolutions and
-- the squad charm aura (Team P). Pure. One accumulator, turned into:
--   delta   Types.StatDelta {add, mul} for Run/Stats.compute (7th param `runBonus`)
--   pve     additive fraction for stats.pveDamageMult (PvE-only damage)
--   extras  run values M2 / M1 read directly:
--             rindMult, wheyMult  (1 + fraction)   rinds / whey earned
--             pveResist           0..0.5          less damage taken from mice and bosses
--             redeployCut         seconds          off the Herd Call delay
--             startRinds, startWhey                 at the start of a match

local Types = require("../Types")

export type Bonus = {
	add: { [string]: number },
	pct: { [string]: number }, -- summed fractions, one multiplier (1 + sum)
	cut: { [string]: number }, -- summed fractions, one multiplier (1 - sum)
	pve: number,
	extras: { [string]: number },
}

local RunBonus = {}

RunBonus.CAPS = table.freeze({
	cut = 0.5, -- at most -50% cooldown from progression
	pveResist = 0.5,
	pve = 2, -- +200% PvE damage
})

function RunBonus.new(): Bonus
	return { add = {}, pct = {}, cut = {}, pve = 0, extras = {} }
end

local function bump(t: { [string]: number }, k: string, v: number)
	t[k] = (t[k] or 0) + v
end

-- Adds one effect (Config/HerdTalents or Config/Charms effect kinds).
function RunBonus.add(b: Bonus, effect: string, field: string?, value: number)
	if type(value) ~= "number" or value ~= value or value == 0 then
		return
	end
	if effect == "pve" then
		b.pve += value
	elseif field then
		if effect == "addStat" then
			bump(b.add, field, value)
		elseif effect == "pctStat" then
			bump(b.pct, field, value)
		elseif effect == "cutStat" then
			bump(b.cut, field, value)
		elseif effect == "extra" then
			bump(b.extras, field, value)
		end
	end
end

function RunBonus.merge(into: Bonus, from: Bonus?)
	if not from then
		return
	end
	for k, v in from.add do
		bump(into.add, k, v)
	end
	for k, v in from.pct do
		bump(into.pct, k, v)
	end
	for k, v in from.cut do
		bump(into.cut, k, v)
	end
	into.pve += from.pve
	for k, v in from.extras do
		bump(into.extras, k, v)
	end
end

export type Resolved = {
	delta: Types.StatDelta,
	pve: number,
	extras: {
		rindMult: number,
		wheyMult: number,
		pveResist: number,
		redeployCut: number,
		startRinds: number,
		startWhey: number,
	},
}

-- The final shapes. Run/Stats.compute applies `delta` and adds `pve` to pveDamageMult.
function RunBonus.resolve(b: Bonus?): Resolved
	local bb = b or RunBonus.new()
	local add: { [string]: number } = table.clone(bb.add)
	local mul: { [string]: number } = {}
	for k, v in bb.pct do
		mul[k] = (mul[k] or 1) * (1 + v)
	end
	for k, v in bb.cut do
		mul[k] = (mul[k] or 1) * (1 - math.min(RunBonus.CAPS.cut, v))
	end
	local e = bb.extras
	return {
		delta = { add = add, mul = mul },
		pve = math.min(RunBonus.CAPS.pve, bb.pve),
		extras = {
			rindMult = 1 + (e.rindMult or 0),
			wheyMult = 1 + (e.wheyMult or 0),
			pveResist = math.min(RunBonus.CAPS.pveResist, e.pveResist or 0),
			redeployCut = e.redeployCut or 0,
			startRinds = math.floor(e.startRinds or 0),
			startWhey = math.floor(e.startWhey or 0),
		},
	}
end

return RunBonus
