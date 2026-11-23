--!strict
-- Iteration 2 (docs/iter/2/ALIGNMENT.md §2a "Ascension"): the 8 x 8 node effects
-- (iteration 6: Tinkerphant's node 5 echo makes its builds last longer, World builds).
-- P owns the data (which nodes a class has unlocked: Prestige milestone + class
-- stomps, the `asc` 8-bit string); M1 owns what each node does in combat.
--
-- Node template (class flavour per node):
--   1 +8% max HP                         5 the ability echoes at 50% (abilityEcho)
--   2 Bull look, ability +20% area       6 -10% cooldowns
--   3 weapon +1 projectile / pierce / arc 7 the class's Class-Stall buff at half strength
--   4 Matriarch look, passive doubled    8 Ancient look + squad aura +5% PvE damage
-- Every delta is a meta layer: World.setMetaMods(id, combine(...)) (damage counts PvE
-- only, max HP at most +25% against heroes); node 8's aura goes into setSquadAura.

local Types = require("../Types")
local RunShop = require("./RunShop")

type StatDelta = Types.StatDelta

export type Node = { delta: StatDelta, look: string?, squadAura: StatDelta? }

local AscensionNodes = {}

AscensionNodes.COUNT = 8
AscensionNodes.LOOKS = table.freeze({ [2] = "bull", [4] = "matriarch", [8] = "ancient" })

-- Node 3: the weapon's extra (+1 projectile / pierce, or a wider arc).
local WEAPON: { [string]: StatDelta } = {
	elephante = { mul = { areaMult = 1.15 } },
	ele_fonte = { add = { pierceBonus = 1 } },
	ellie_fawn = { add = { projectileBonus = 1 } },
	le_fante = { mul = { areaMult = 1.15 } },
	filet = { add = { projectileBonus = 1 } },
	jumbo = { mul = { areaMult = 1.15 } },
	fizzante = { add = { projectileBonus = 1 } },
	tinkerphant = { add = { pierceBonus = 1 } }, -- (iteration 6) rivets and turret shots pierce
}

-- Node 4: the class passive (Config/Classes passiveText) once more.
local PASSIVE: { [string]: StatDelta } = {
	elephante = { mul = { maxHp = 1.25 } },
	ele_fonte = { add = { pierceBonus = 1 } },
	ellie_fawn = { mul = { moveSpeed = 1.15 } },
	le_fante = { add = { critChance = 0.15 } },
	filet = { add = { regen = 1 } },
	jumbo = { mul = { pickupRadius = 1.3 } },
	fizzante = { mul = { areaMult = 1.2 } },
	tinkerphant = { mul = { buildHpMult = 1.25 } }, -- (iteration 6) Sturdy Builds again
}

-- A delta at `f` strength (add x f; mul 1 + (m - 1) x f).
local function scaled(d: StatDelta?, f: number): StatDelta
	local out = { add = {}, mul = {} }
	if d then
		for k, v in d.add or {} do
			out.add[k] = v * f
		end
		for k, v in d.mul or {} do
			out.mul[k] = 1 + (v - 1) * f
		end
	end
	return out
end

-- Node n (1..8) of a class: {delta, look?, squadAura?}; nil for an unknown class / node.
function AscensionNodes.node(classId: string, n: number): Node?
	if not WEAPON[classId] or type(n) ~= "number" or n < 1 or n > AscensionNodes.COUNT then
		return nil
	end
	local i = math.floor(n)
	local look = AscensionNodes.LOOKS[i]
	if i == 1 then
		return { delta = { mul = { maxHp = 1.08 } } }
	elseif i == 2 then
		return { delta = { mul = { abilityAreaMult = 1.2 } }, look = look }
	elseif i == 3 then
		return { delta = WEAPON[classId] }
	elseif i == 4 then
		return { delta = PASSIVE[classId], look = look }
	elseif i == 5 then
		return { delta = { add = { abilityEcho = 0.5 } } }
	elseif i == 6 then
		return { delta = { mul = { cooldownMult = 0.9 } } }
	elseif i == 7 then
		local cb = RunShop.CLASS_BUFFS[classId]
		return { delta = scaled(cb and cb.delta, 0.5) }
	end
	return { delta = {}, look = look, squadAura = { add = { pveDamageMult = 0.05 } } }
end

-- Which nodes are on: `asc` is the 8-char "10110000" string (P's save), or a count n
-- meaning nodes 1..n.
local function owned(asc: any): { boolean }
	local out = table.create(AscensionNodes.COUNT, false)
	if type(asc) == "number" then
		for i = 1, math.clamp(math.floor(asc), 0, AscensionNodes.COUNT) do
			out[i] = true
		end
	elseif type(asc) == "string" then
		for i = 1, AscensionNodes.COUNT do
			out[i] = string.sub(asc, i, i) == "1"
		end
	end
	return out
end

-- The meta StatDelta of a class's unlocked nodes (for World.setMetaMods), its squad
-- aura (node 8; nil without it) and the looks unlocked.
function AscensionNodes.combine(classId: string, asc: any): (StatDelta, StatDelta?, { string })
	local acc = { add = {}, mul = {} }
	local aura: StatDelta? = nil
	local looks = {}
	for i, on in owned(asc) do
		local node = if on then AscensionNodes.node(classId, i) else nil
		if node then
			for k, v in node.delta.add or {} do
				acc.add[k] = (acc.add[k] or 0) + v
			end
			for k, v in node.delta.mul or {} do
				acc.mul[k] = (acc.mul[k] or 1) * v
			end
			if node.squadAura then
				aura = node.squadAura
			end
			if node.look then
				table.insert(looks, node.look)
			end
		end
	end
	return acc, aura, looks
end

-- Iteration 2 with P's Data/RunBonus: Prestige and the NUMBER nodes (1 HP, 6 cooldowns,
-- 8 squad PvE) already come in the stats; World adds only the BEHAVIOUR nodes
-- (2 ability area, 3 weapon extra, 4 passive, 5 echo, 7 stall buff) for nodes 1..n.
AscensionNodes.BEHAVIOUR = table.freeze({ [2] = true, [3] = true, [4] = true, [5] = true, [7] = true })
function AscensionNodes.behaviours(classId: string, n: number): StatDelta
	local acc = { add = {}, mul = {} }
	local count = if type(n) == "number" then math.clamp(math.floor(n), 0, AscensionNodes.COUNT) else 0
	for i = 1, count do
		local node = if AscensionNodes.BEHAVIOUR[i] then AscensionNodes.node(classId, i) else nil
		if node then
			for k, v in node.delta.add or {} do
				acc.add[k] = (acc.add[k] or 0) + v
			end
			for k, v in node.delta.mul or {} do
				acc.mul[k] = (acc.mul[k] or 1) * v
			end
		end
	end
	return acc
end

return AscensionNodes
