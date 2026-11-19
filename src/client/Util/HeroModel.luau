--!strict
-- Pure model of Prestige and Ascension for the Hero screen (iteration 2;
-- ALIGNMENT §2a). No Roblox APIs. Reads Team P's class view defensively:
--   classes[id] = { level, xp, prestige, plevel, pxp, pxpToNext, canPrestige?,
--                   asc = "11000000" | {bool ×8}, stomps, ascLooks?, ... }
-- Config/Ascension (P / M1) wins for node gates and texts when present:
--   { NODES = {{prestige, stomps, name, text}} } or per class NODES[classId].

local HeroModel = {}

local function num(v: any, d: number): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return d
	end
	return n
end

HeroModel.MAX_LEVEL = 30
HeroModel.MAX_PRESTIGE = 99
HeroModel.FRAMES = { 1, 5, 10, 20, 40, 70, 99 } -- nameplate star frames

-- ALIGNMENT §2a node gates and template (M1 writes the class flavour).
HeroModel.NODES = {
	{ prestige = 1, stomps = 5000, name = "Thick Hide", text = "+8% max HP" },
	{ prestige = 3, stomps = 10000, name = "Bull", text = "Bull look · ability +20% area" },
	{ prestige = 5, stomps = 20000, name = "Extra Volley", text = "Weapon +1 projectile / pierce / arc" },
	{ prestige = 8, stomps = 35000, name = "Matriarch", text = "Matriarch look · passive doubled" },
	{ prestige = 12, stomps = 60000, name = "Aftershock", text = "Your ability leaves a second effect" },
	{ prestige = 16, stomps = 90000, name = "Quick Trunk", text = "-10% cooldowns" },
	{
		prestige = 20,
		stomps = 130000,
		name = "Stall Instinct",
		text = "Your Class-Stall buff at half strength, always",
	},
	{ prestige = 25, stomps = 200000, name = "Ancient", text = "Ancient look · squad aura +5% PvE damage" },
}

-- Prestige bonus text for P (ALIGNMENT: +0.5% PvE dmg, +0.25% HP per P up to
-- P40; +1 perk point up to P16).
function HeroModel.prestigeBonus(p: number): string
	local c = math.clamp(math.floor(p), 0, 40)
	local perks = math.clamp(math.floor(p), 0, 16)
	return string.format(
		"+%.1f%% PvE damage · +%.1f%% max HP · +%d perk point%s",
		c * 0.5,
		c * 0.25,
		perks,
		if perks == 1 then "" else "s"
	)
end

local function ascBits(v: any): { boolean }
	local out = {}
	if type(v) == "string" then
		for i = 1, 8 do
			out[i] = string.sub(v, i, i) == "1"
		end
	elseif type(v) == "table" then
		for i = 1, 8 do
			out[i] = v[i] == true or v[i] == 1 or v[tostring(i)] == true
		end
	else
		for i = 1, 8 do
			out[i] = false
		end
	end
	return out
end
HeroModel.ascBits = ascBits

export type Node = {
	index: number,
	name: string,
	text: string,
	prestige: number,
	stomps: number,
	owned: boolean,
	canUnlock: boolean, -- gates met and every earlier node owned
	why: string?, -- "prestige" | "stomps" | "order" | nil
}

export type Hero = {
	level: number, -- stored class level (unlocks), 1..30
	shownLevel: number, -- the displayed level (plevel after a prestige)
	prestige: number,
	xp: number,
	toNext: number,
	frac: number,
	canPrestige: boolean,
	stomps: number,
	nodes: { Node },
	nextFrame: number?,
}

local function nodeDefs(cfg: any, classId: string?): { any }
	if type(cfg) == "table" then
		local n = cfg.NODES or cfg.nodes
		if type(n) == "table" and classId and type(n[classId]) == "table" then
			return n[classId]
		end
		if type(n) == "table" and #n > 0 then
			return n
		end
	end
	return HeroModel.NODES
end

function HeroModel.view(classView: any, classId: string?, cfg: any): Hero
	local c = if type(classView) == "table" then classView else {}
	local level = math.clamp(math.floor(num(c.level, 1)), 1, HeroModel.MAX_LEVEL)
	local prestige = math.clamp(math.floor(num(c.prestige or c.stars, 0)), 0, HeroModel.MAX_PRESTIGE)
	-- Team P class view: displayLevel, prestigeXp, prestigeXpToNext (older: plevel, pxp)
	local shown = if prestige > 0
		then math.clamp(math.floor(num(c.displayLevel or c.plevel, 1)), 1, HeroModel.MAX_LEVEL)
		else level
	local xp = num(if prestige > 0 then (c.prestigeXp or c.pxp or c.xp) else c.xp, 0)
	local toNext = math.max(
		1,
		num(if prestige > 0 then (c.prestigeXpToNext or c.pxpToNext or c.xpToNext) else c.xpToNext, 1)
	)
	local canPrestige = if c.canPrestige ~= nil
		then c.canPrestige == true
		else (shown >= HeroModel.MAX_LEVEL and prestige < HeroModel.MAX_PRESTIGE)
	local stomps = math.floor(num(c.stomps, 0))
	local asc = c.asc
	if asc == nil and type(c.ascension) == "table" then
		asc = c.ascension.bits
	end
	local bits = ascBits(asc)
	local nodes: { Node } = {}
	local prevOwned = true
	for i, d in nodeDefs(cfg, classId) do
		if i > 8 then
			break
		end
		local fb = HeroModel.NODES[i] or HeroModel.NODES[8]
		local np = math.floor(num(d.prestige, fb.prestige))
		local ns = math.floor(num(d.stomps, fb.stomps))
		local owned = bits[i] == true
		local why: string? = nil
		if not owned then
			if not prevOwned then
				why = "order"
			elseif prestige < np then
				why = "prestige"
			elseif stomps < ns then
				why = "stomps"
			end
		end
		table.insert(nodes, {
			index = i,
			name = tostring(d.name or fb.name),
			text = tostring(d.text or d.description or fb.text),
			prestige = np,
			stomps = ns,
			owned = owned,
			canUnlock = not owned and why == nil,
			why = why,
		})
		prevOwned = owned
	end
	local nextFrame: number? = nil
	for _, f in HeroModel.FRAMES do
		if prestige < f then
			nextFrame = f
			break
		end
	end
	return {
		level = level,
		shownLevel = shown,
		prestige = prestige,
		xp = xp,
		toNext = toNext,
		frac = math.clamp(xp / toNext, 0, 1),
		canPrestige = canPrestige,
		stomps = stomps,
		nodes = nodes,
		nextFrame = nextFrame,
	}
end

-- Prestige re-climb (ALIGNMENT §2a): after a Prestige the shown level climbs
-- 1 -> 30 over `total` XP (Config/Ascension.PRESTIGE_XP, 12,000):
-- level = 1 + floor(29 * pxp / total). Returns (pxp, shownLevel, frac).
HeroModel.PRESTIGE_XP = 12000
function HeroModel.reclimb(pxp: number, total: number?): (number, number, number)
	local t = math.max(1, num(total, HeroModel.PRESTIGE_XP))
	local x = math.clamp(num(pxp, 0), 0, t)
	local lv = math.min(HeroModel.MAX_LEVEL, 1 + math.floor(29 * x / t))
	return x, lv, x / t
end

return HeroModel
