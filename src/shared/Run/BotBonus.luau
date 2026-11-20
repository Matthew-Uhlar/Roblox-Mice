--!strict
-- Iteration 4 (lead decision): bot squadmates scale to their humans. Gems are
-- personal, so a bot in a squad with humans gets BotBonus.FRACTION of the AVERAGE
-- human squadmate's long-term run bonus (Data/RunBonus.Resolved from
-- DataService.runBonuses: Prestige, Ascension and gem stats), never their uniques
-- or economy extras. Applied at stage start (RunDirector.refreshRunBonuses, the
-- Headless sim). Stats.compute keeps its damage PvE-only and World caps its max HP
-- in PvP, as for humans. Pure.
--
-- `aura` (optional) = DataService.squadGemAura(humans): the squad's node-8 PvE aura
-- the bot gets in full. The humans' own `pve` already holds that aura, so it is
-- taken out before scaling.

local BotBonus = {}

BotBonus.FRACTION = 0.6

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function BotBonus.scaled(humans: { any }, aura: any?, fraction: number?): any
	local f = if finite(fraction) then fraction :: number else BotBonus.FRACTION
	local auraPve = if type(aura) == "table" and finite(aura.pve) then aura.pve else 0
	local add, mulSum, n = {}, {}, 0
	local pve, resist = 0, 0
	for _, b in humans do
		if type(b) == "table" then
			n += 1
			local d = if type(b.delta) == "table" then b.delta else {}
			for k, v in d.add or {} do
				if finite(v) then
					add[k] = (add[k] or 0) + v
				end
			end
			for k, v in d.mul or {} do
				if finite(v) then
					mulSum[k] = (mulSum[k] or 0) + (v - 1)
				end
			end
			pve += (if finite(b.pve) then b.pve else 0) - auraPve
			local ex = b.extras
			resist += if type(ex) == "table" and finite(ex.pveResist) then ex.pveResist else 0
		end
	end
	local out = {
		delta = { add = {}, mul = {} },
		pve = auraPve,
		extras = {
			rindMult = 1,
			wheyMult = 1,
			pveResist = 0,
			redeployCut = 0,
			startRinds = 0,
			startWhey = 0,
			ascNodes = 0,
		},
		uniques = {},
	}
	if type(aura) == "table" and type(aura.delta) == "table" then
		for k, v in aura.delta.add or {} do
			out.delta.add[k] = v
		end
		for k, v in aura.delta.mul or {} do
			out.delta.mul[k] = v
		end
	end
	if n == 0 then
		return out
	end
	for k, v in add do
		out.delta.add[k] = (out.delta.add[k] or 0) + f * v / n
	end
	for k, v in mulSum do
		out.delta.mul[k] = (out.delta.mul[k] or 1) * (1 + f * v / n)
	end
	out.pve += f * math.max(0, pve) / n
	out.extras.pveResist = f * resist / n
	return out
end

return BotBonus
