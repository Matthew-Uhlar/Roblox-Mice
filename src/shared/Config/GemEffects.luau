--!strict
-- Iteration 2: what each Cheese Gem unique (Config/Gems.UNIQUES, team P) does in
-- combat (team M1). A unique is active once per squad (Data/Gems.aura lists them);
-- World.setSquadUniques(squad, ids) applies them as a meta layer (damage PvE-only,
-- max HP inside the +25% PvP cap). Class uniques reach only that class in the squad.

local Types = require("../Types")

type StatDelta = Types.StatDelta

export type Effect = { delta: StatDelta, classId: string? }

local GemEffects = {}

GemEffects.UNIQUES = table.freeze({
	u_elephante = { classId = "elephante", delta = { mul = { abilityAreaMult = 1.25 } } },
	u_ele_fonte = { classId = "ele_fonte", delta = { mul = { healMult = 1.3 } } },
	u_ellie_fawn = { classId = "ellie_fawn", delta = { add = { projectileBonus = 1 } } },
	u_le_fante = { classId = "le_fante", delta = { mul = { armor = 1.15 } } },
	u_filet = { classId = "filet", delta = { mul = { attackSpeedMult = 1.15 } } },
	u_jumbo = { classId = "jumbo", delta = { mul = { maxHp = 1.1 } } },
	u_fizzante = { classId = "fizzante", delta = { mul = { cooldownMult = 0.85 } } },
	u_cooldowns = { delta = { mul = { cooldownMult = 0.9 } } },
	u_stride = { delta = { mul = { moveSpeed = 1.06 } } },
	u_glass_tusk = { delta = { mul = { maxHp = 0.85 }, add = { pveDamageMult = 0.2 } } },
	u_lucky_crumb = { delta = { add = { luckyCrumb = 0.2 } } },
	u_unshakable = { delta = { add = { unshakable = 1 } } },
} :: { [string]: Effect })

local function fold(acc: any, d: StatDelta)
	for k, v in d.add or {} do
		acc.add[k] = (acc.add[k] or 0) + v
	end
	for k, v in d.mul or {} do
		acc.mul[k] = (acc.mul[k] or 1) * v
	end
end

-- The squad delta and the per-class deltas of a set of active unique ids (each id
-- counts once; unknown ids are ignored): (aura?, classAuras?).
function GemEffects.resolve(ids: { string }?): (StatDelta?, { [string]: StatDelta }?)
	local aura: any = nil
	local classes: any = nil
	local seen = {}
	for _, id in ids or {} do
		local e = GemEffects.UNIQUES[id]
		if e and not seen[id] then
			seen[id] = true
			if e.classId then
				classes = classes or {}
				classes[e.classId] = classes[e.classId] or { add = {}, mul = {} }
				fold(classes[e.classId], e.delta)
			else
				aura = aura or { add = {}, mul = {} }
				fold(aura, e.delta)
			end
		end
	end
	return aura, classes
end

return GemEffects
