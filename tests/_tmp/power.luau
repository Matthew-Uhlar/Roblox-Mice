local Stats = require("../../src/shared/Run/Stats")
local ClassPerks = require("../../src/shared/Config/ClassPerks")
local Classes = require("../../src/shared/Config/Classes")

local function abilityPower(a)
	local p = a.damage * math.sqrt(a.area) / a.cooldown
	if a.duration and a.duration > 0 then p *= math.sqrt(a.duration) end
	if a.distance then p *= a.distance ^ 0.25 end
	return p
end

local function power(classId, s0, w0, a0, s, w, a)
	local function crit(x) return 1 + x.critChance * (x.critMult - 1) end
	local function cnt(x, ww) return ww.count + x.projectileBonus end
	local off = (s.damageMult / s0.damageMult) * (s.attackSpeedMult / s0.attackSpeedMult) * (crit(s) / crit(s0))
		* (1 + 0.5 * (s.areaMult / s0.areaMult - 1))
		* (1 + 0.5 * (cnt(s, w) / cnt(s0, w0) - 1))
		* (w.damage / w0.damage)
		* (1 + 0.06 * (s.pierceBonus - s0.pierceBonus))
		* (1 + 0.08 * (s.chain - s0.chain))
		* (1 + 0.015 * (s.explodeOnKill - s0.explodeOnKill))
		* (1 + 0.15 * (s.extraOrbiters - s0.extraOrbiters))
		* (1 + 0.25 * (abilityPower(a) * (s0.cooldownMult / s.cooldownMult) / abilityPower(a0) - 1))
	local def = (s.maxHp / s0.maxHp) * (1 + 0.04 * (s.armor - s0.armor)) * (1 + 0.05 * (s.regen - s0.regen))
		* (1 + 2 * (s.lifesteal - s0.lifesteal)) * (1 + 0.5 * (s.moveSpeed / s0.moveSpeed - 1))
	return off ^ 0.6 * def ^ 0.4, off, def
end

local COST = { 0, 1, 3, 6, 10, 15 }
for _, cid in Classes.ORDER do
	local s0, w0, a0 = Stats.compute(cid, {}, {})
	local br = ClassPerks.branches(cid)
	local best, worst, bestK, worstK = 0, 99, "", ""
	local fulls = {}
	for d1 = 0, 5 do for d2 = 0, 5 do for d3 = 0, 5 do
		local c = COST[d1+1] + COST[d2+1] + COST[d3+1]
		if c <= 29 and c >= 25 then
			local perks = {}
			for bi, d in { d1, d2, d3 } do
				for t = 1, d do perks[br[bi].perks[t].id] = true end
			end
			local s, w, a = Stats.compute(cid, {}, {}, nil, nil, { perks = perks, level = 30 })
			local pw = power(cid, s0, w0, a0, s, w, a)
			if pw > best then best = pw; bestK = d1 .. d2 .. d3 end
			if pw < worst then worst = pw; worstK = d1 .. d2 .. d3 end
		end
	end end end
	local line = string.format("%-11s best %.3f (%s) worst %.3f (%s) |", cid, best, bestK, worst, worstK)
	for bi = 1, 3 do
		local perks = {}
		for t = 1, 5 do perks[br[bi].perks[t].id] = true end
		local s, w, a = Stats.compute(cid, {}, {}, nil, nil, { perks = perks, level = 30 })
		line ..= string.format(" %s %.3f", br[bi].id, (power(cid, s0, w0, a0, s, w, a)))
	end
	print(line)
end
