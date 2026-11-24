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
local Keystones = require("./Keystones") -- (iteration 6, team Talents)
local Classes = require("./Classes")

type StatDelta = Types.StatDelta

-- (iteration 6, team Talents) `mech` = the node's visible mechanic (Config/Keystones
-- `asc*` fields; Combat/Talents runs it, Visuals/TalentFx draws it). It is added by
-- World.setAscension for every unlocked node (with the BEHAVIOUR deltas).
export type Node = { delta: StatDelta, look: string?, squadAura: StatDelta?, mech: { [string]: number }? }

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
	-- (iteration 7, team Classes)
	ele_vation = { add = { pierceBonus = 1 } },
	elephaid = { add = { projectileBonus = 1 } },
	trunkillery = { mul = { areaMult = 1.15 } },
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
	-- (iteration 7, team Classes); Steady Trunk's extra damage stays out of PvP
	-- (Weapons.STEADY_PVP_MAX)
	ele_vation = { add = { steadyAim = 0.3 } },
	elephaid = { add = { allyHealShare = 0.15 } },
	trunkillery = { add = { armor = 2 }, mul = { areaMult = 1.15 } },
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

-- (iteration 6, team Talents) the visible mechanic of each node (Config/Keystones).
AscensionNodes.MECH = table.freeze({
	{ ascSecondWind = 1 }, -- 1 Second Wind
	{ ascWave = 1 }, -- 2 Bull: a shockwave with every cast
	{ ascTrail = 1 }, -- 3 Ascended Weapon: glowing weapon trail
	{ ascSpirit = 1 }, -- 4 Matriarch: a spirit calf that zaps mice
	{ ascEcho = 1 }, -- 5 Echo: the ghostly double
	{ ascOvercharge = Keystones.OVERCHARGE }, -- 6 Overcharge
	{ ascFrenzy = 1 }, -- 7 Frenzy
	{ ascStomp = 1 }, -- 8 Ancient Stomp
})
AscensionNodes.NAMES = table.freeze({
	"Second Wind",
	"Bull",
	"Ascended Weapon",
	"Matriarch",
	"Echo",
	"Overcharge",
	"Frenzy",
	"Ancient",
})

-- Node n (1..8) of a class: {delta, look?, squadAura?, mech}; nil for an unknown class / node.
function AscensionNodes.node(classId: string, n: number): Node?
	if not WEAPON[classId] or type(n) ~= "number" or n < 1 or n > AscensionNodes.COUNT then
		return nil
	end
	local i = math.floor(n)
	local look = AscensionNodes.LOOKS[i]
	local mech = AscensionNodes.MECH[i]
	if i == 1 then
		return { delta = { mul = { maxHp = 1.08 } }, mech = mech }
	elseif i == 2 then
		return { delta = { mul = { abilityAreaMult = 1.2 } }, look = look, mech = mech }
	elseif i == 3 then
		return { delta = WEAPON[classId], mech = mech }
	elseif i == 4 then
		return { delta = PASSIVE[classId], look = look, mech = mech }
	elseif i == 5 then
		return { delta = { add = { abilityEcho = 0.5 } }, mech = mech }
	elseif i == 6 then
		return { delta = { mul = { cooldownMult = 0.9 } }, mech = mech }
	elseif i == 7 then
		local cb = RunShop.CLASS_BUFFS[classId]
		return { delta = scaled(cb and cb.delta, 0.5), mech = mech }
	end
	return { delta = {}, look = look, squadAura = { add = { pveDamageMult = 0.05 } }, mech = mech }
end

-- (iteration 6, team Talents) The full text of node n for a class, exact numbers.
local WEAPON_TEXT: { [string]: string } = {
	elephante = "trunk swings +15% wider",
	ele_fonte = "jets pierce 1 more mouse",
	ellie_fawn = "+1 peanut per volley",
	le_fante = "thrusts +15% wider",
	filet = "+1 cleaver",
	jumbo = "gusts +15% wider",
	fizzante = "+1 bomb per throw",
	tinkerphant = "rivets and turret shots pierce 1 more mouse",
	-- (iteration 7, team Classes)
	ele_vation = "rifle shots pierce 1 more mouse",
	elephaid = "+1 spritz per shot",
	trunkillery = "shells burst +15% wider",
}
function AscensionNodes.describe(classId: string, n: number): string
	local i = math.floor(n)
	local mech = AscensionNodes.MECH[i]
	local field, value = next(mech or {})
	local m = if field then Keystones.phrase(field :: string, value :: number) or "" else ""
	local cls = Classes.get(classId)
	if i == 1 then
		return "+8% max HP. " .. m .. "."
	elseif i == 2 then
		return "Bull look; abilities +20% area. " .. m .. "."
	elseif i == 3 then
		return string.format("Weapon: %s. %s.", WEAPON_TEXT[classId] or "+1 projectile, pierce or arc", m)
	elseif i == 4 then
		local passive = if cls and cls.passiveText then cls.passiveText else "your class passive"
		return "Matriarch look; class passive doubled (" .. passive .. "). " .. m .. "."
	elseif i == 5 then
		return "Your ability echoes at 50% damage 0.5s later: " .. m .. "."
	elseif i == 6 then
		return "-10% ability cooldowns. " .. m .. "."
	elseif i == 7 then
		local cb = RunShop.CLASS_BUFFS[classId]
		return string.format(
			"Your Class-Stall buff (%s) at half strength, always. %s.",
			if cb then cb.name else "class buff",
			m
		)
	end
	return "Ancient look; your squad +5% damage to mice and bosses. " .. m .. "."
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
			for k, v in node.mech or {} do
				acc.add[k] = (acc.add[k] or 0) + v
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
		local node = AscensionNodes.node(classId, i)
		if node and AscensionNodes.BEHAVIOUR[i] then
			for k, v in node.delta.add or {} do
				acc.add[k] = (acc.add[k] or 0) + v
			end
			for k, v in node.delta.mul or {} do
				acc.mul[k] = (acc.mul[k] or 1) * v
			end
		end
		-- (iteration 6, team Talents) every node's visible mechanic
		for k, v in (node and node.mech) or {} do
			acc.add[k] = (acc.add[k] or 0) + v
		end
	end
	return acc
end

return AscensionNodes
