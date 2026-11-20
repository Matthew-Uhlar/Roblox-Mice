--!strict
-- Pure model of the v5 in-run shop UI (docs/V5-PLAN.md §A, iteration 1 §D).
-- No Roblox APIs: `cfg` is Config/RunShop (passed in), so specs run in Lune.
--
--   ranks(cfg, wallet)                upgrade menu rows (8 stats, 25 ranks)
--   stall(cfg, stall, wallet, class)  a stall's 2 offers (or the class buff)
--   altar(cfg, altar, wallet, stage)  the 4 ultimates
--   swapPreview(cfg, rinds)           whey you get for N rinds (rinds -> whey only)
--   whatsLeft(cfg, shops, wallet, x, z, stage, class)  "What's left to buy" list (B)
--   levels(level)                     the in-run level buffs (Levels list)
--   short(n)                          12345 -> "12.3k"

local RunShopModel = {}

local function num(v: any, d: number): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return d
	end
	return n
end

function RunShopModel.short(n: number?): string
	local v = num(n, 0)
	if math.abs(v) >= 1e6 then
		return string.format("%.1fM", v / 1e6)
	elseif math.abs(v) >= 1e4 then
		return string.format("%.1fk", v / 1e3)
	end
	return tostring(math.floor(v))
end

local function has(list: any, id: string): boolean
	return type(list) == "table" and table.find(list, id) ~= nil
end

local function rankCost(cfg: any, stat: string, rank: number): number?
	if type(cfg) ~= "table" then
		return nil
	end
	if type(cfg.rankCost) == "function" then
		local ok, c = pcall(cfg.rankCost, stat, rank)
		return if ok then tonumber(c) else nil
	end
	local def = cfg.RANKS and cfg.RANKS[stat]
	local max = num(cfg.MAX_RANK, 100)
	if not def or rank >= max then
		return nil
	end
	if def.step ~= nil or cfg.RANK_STEP ~= nil then
		-- iteration 4: the linear curve, base + step · rank
		return math.ceil(num(def.base, 20) + num(def.step or cfg.RANK_STEP, 0) * rank)
	end
	return math.ceil(num(def.base, 20) * num(cfg.RANK_GROWTH, 1.14) ^ rank)
end
RunShopModel.rankCost = rankCost

export type RankRow = {
	id: string,
	name: string,
	text: string,
	rank: number,
	max: number,
	cost: number?, -- nil = maxed
	canBuy: boolean,
}

function RunShopModel.ranks(cfg: any, wallet: any): { RankRow }
	local out: { RankRow } = {}
	if type(cfg) ~= "table" or type(cfg.RANKS) ~= "table" then
		return out
	end
	local w = if type(wallet) == "table" then wallet else {}
	local ranks = if type(w.ranks) == "table" then w.ranks else {}
	local rinds = num(w.rinds, 0)
	local max = math.floor(num(cfg.MAX_RANK, 100)) -- iteration 4: uncapped (soft cap 100)
	for _, id in (cfg.RANK_ORDER or {}) do
		local def = cfg.RANKS[id]
		if def then
			local r = math.floor(num(ranks[id], 0))
			local cost = if r < max then rankCost(cfg, id, r) else nil
			table.insert(out, {
				id = id,
				name = tostring(def.name or id),
				text = tostring(def.description or ""),
				rank = r,
				max = max,
				cost = cost,
				canBuy = cost ~= nil and rinds >= cost,
			})
		end
	end
	return out
end

-- Buy up to `n` ranks of `stat` from `rank` with `rinds`: (count, total cost).
-- The V menu's ×5 (and Shift-click) uses it to show what 5 would cost.
function RunShopModel.multiCost(
	cfg: any,
	stat: string,
	rank: number,
	n: number,
	rinds: number
): (number, number)
	local count, total = 0, 0
	local r = math.floor(num(rank, 0))
	for _ = 1, math.max(0, math.floor(n)) do
		local c = rankCost(cfg, stat, r)
		if c == nil or total + c > num(rinds, 0) then
			break
		end
		total += c
		count += 1
		r += 1
	end
	return count, total
end

-- Any stat rank affordable now? (drives the V-menu pulse)
function RunShopModel.anyAffordable(cfg: any, wallet: any): boolean
	for _, r in RunShopModel.ranks(cfg, wallet) do
		if r.canBuy then
			return true
		end
	end
	return false
end

export type Offer = {
	id: string, -- buff id ("class" for the class buff)
	name: string,
	text: string,
	cost: number, -- whey
	owned: boolean,
	canBuy: boolean,
}

local function buffOffer(cfg: any, id: string, wallet: any, classId: string?): Offer?
	local w = if type(wallet) == "table" then wallet else {}
	local whey = num(w.whey, 0)
	local def, cost
	if id == "class" then
		def = type(cfg.CLASS_BUFFS) == "table" and classId and cfg.CLASS_BUFFS[classId] or nil
		cost = num(cfg.CLASS_BUFF_COST, 500)
	else
		def = type(cfg.BUFFS) == "table" and cfg.BUFFS[id] or nil
		cost = num(cfg.BUFF_COST, 250)
	end
	if not def then
		if id ~= "class" then
			return nil
		end
		def = { name = "Class buff", description = "Your class's signature, amplified" }
	end
	local owned = has(w.buffs, id)
	return {
		id = id,
		name = tostring(def.name or id),
		text = tostring(def.description or ""),
		cost = cost,
		owned = owned,
		canBuy = not owned and whey >= cost,
	}
end

function RunShopModel.stall(cfg: any, stall: any, wallet: any, classId: string?): { Offer }
	local out: { Offer } = {}
	if type(cfg) ~= "table" or type(stall) ~= "table" or type(stall.offers) ~= "table" then
		return out
	end
	for _, id in stall.offers do
		local o = buffOffer(cfg, tostring(id), wallet, classId)
		if o then
			table.insert(out, o)
		end
	end
	return out
end

export type Ult = {
	id: string,
	name: string,
	text: string,
	rinds: number,
	whey: number,
	owned: boolean,
	canBuy: boolean,
	why: string?, -- "stage" | "max" | "owned" | "funds" | nil
}

function RunShopModel.altar(cfg: any, altar: any, wallet: any, stage: number?): { Ult }
	local out: { Ult } = {}
	if type(cfg) ~= "table" or type(cfg.ULTIMATES) ~= "table" then
		return out
	end
	local w = if type(wallet) == "table" then wallet else {}
	local cost = if type(cfg.ULTIMATE_COST) == "table" then cfg.ULTIMATE_COST else {}
	local cr, cw = num(cost.rinds, 6000), num(cost.whey, 600)
	local owned = if type(w.ultimates) == "table" then #w.ultimates else 0
	local open = (type(altar) == "table" and altar.open == true)
		or num(stage, 0) >= num(cfg.ALTAR_FROM_STAGE, 3)
	for _, id in (cfg.ULTIMATE_ORDER or {}) do
		local def = cfg.ULTIMATES[id]
		if def then
			local mine = has(w.ultimates, id)
			local why: string? = nil
			if mine then
				why = "owned"
			elseif not open then
				why = "stage"
			elseif owned >= num(cfg.ULTIMATE_MAX, 2) then
				why = "max"
			elseif num(w.rinds, 0) < cr or num(w.whey, 0) < cw then
				why = "funds"
			end
			table.insert(out, {
				id = id,
				name = tostring(def.name or id),
				text = tostring(def.description or ""),
				rinds = cr,
				whey = cw,
				owned = mine,
				canBuy = why == nil,
				why = why,
			})
		end
	end
	return out
end

-- Whey you get for `rinds` at the Swap Stand (rinds -> whey only, with the fee).
function RunShopModel.swapPreview(cfg: any, rinds: number): number
	local rate = num(type(cfg) == "table" and cfg.SWAP_RATE, 10)
	local fee = num(type(cfg) == "table" and cfg.SWAP_FEE, 0.2)
	if rate <= 0 then
		return 0
	end
	return math.max(0, math.floor(num(rinds, 0) / rate * (1 - fee)))
end

export type LeftRow = { kind: string, id: string, text: string, dist: number, cost: string, canBuy: boolean }

-- "What's left to buy" (Zombie World `-status`): unbought stall offers with
-- distance and cost, then the Altar. Nearest first; affordable first on ties.
function RunShopModel.whatsLeft(
	cfg: any,
	shops: any,
	wallet: any,
	x: number,
	z: number,
	stage: number?,
	classId: string?
): { LeftRow }
	local out: { LeftRow } = {}
	if type(shops) ~= "table" then
		return out
	end
	local function dist(px: any, pz: any): number
		return math.sqrt((num(px, 0) - x) ^ 2 + (num(pz, 0) - z) ^ 2)
	end
	for _, st in (if type(shops.stalls) == "table" then shops.stalls else {}) do
		for _, o in RunShopModel.stall(cfg, st, wallet, classId) do
			if not o.owned then
				table.insert(out, {
					kind = if st.class then "class" else "stall",
					id = tostring(st.id) .. ":" .. o.id,
					text = o.name,
					dist = dist(st.x, st.z),
					cost = tostring(o.cost) .. " whey",
					canBuy = o.canBuy,
				})
			end
		end
	end
	local altar = shops.altar
	if type(altar) == "table" then
		local ults = RunShopModel.altar(cfg, altar, wallet, stage)
		local left, can = 0, false
		for _, u in ults do
			if not u.owned and u.why ~= "max" then
				left += 1
				can = can or u.canBuy
			end
		end
		if left > 0 then
			local cost = if type(cfg) == "table" and type(cfg.ULTIMATE_COST) == "table"
				then cfg.ULTIMATE_COST
				else {}
			table.insert(out, {
				kind = "altar",
				id = "altar",
				text = if altar.open == true
						or num(stage, 0) >= num(type(cfg) == "table" and cfg.ALTAR_FROM_STAGE, 3)
					then string.format("Big Cheese Altar (%d left)", left)
					else "Big Cheese Altar (opens at stage 3)",
				dist = dist(altar.x, altar.z),
				cost = RunShopModel.short(num(cost.rinds, 6000)) .. " rinds + " .. tostring(
					num(cost.whey, 600)
				) .. " whey",
				canBuy = can,
			})
		end
	end
	table.sort(out, function(a, b)
		if math.abs(a.dist - b.dist) > 1 then
			return a.dist < b.dist
		end
		if a.canBuy ~= b.canBuy then
			return a.canBuy
		end
		return a.id < b.id
	end)
	return out
end

-- In-run level buffs (V5 A7): every level +2 max HP, every 5 levels +3% damage,
-- In-run level gains (iteration 4, Liberty-style): every level gives fixed
-- stats, from Config/RunShop.LEVEL_GAINS when M2 adds it:
--   {hpPct = 0.03, dmgPct = 0.02, armor = 1, armorEvery = 5, pickEvery = 5}
-- Upgrade cards become milestone picks every `pickEvery` levels.
local DEFAULT_GAINS = { hpPct = 0.03, dmgPct = 0.02, armor = 1, armorEvery = 5, pickEvery = 5 }

local function gainsOf(cfg: any): any
	local g = if type(cfg) == "table" and type(cfg.LEVEL_GAINS) == "table" then cfg.LEVEL_GAINS else {}
	return {
		hpPct = num(g.hpPct, DEFAULT_GAINS.hpPct),
		dmgPct = num(g.dmgPct, DEFAULT_GAINS.dmgPct),
		armor = num(g.armor, DEFAULT_GAINS.armor),
		armorEvery = math.max(1, math.floor(num(g.armorEvery, DEFAULT_GAINS.armorEvery))),
		pickEvery = math.max(1, math.floor(num(g.pickEvery, DEFAULT_GAINS.pickEvery))),
	}
end

local function pct(f: number): string
	local v = f * 100
	if math.abs(v - math.floor(v + 0.5)) < 1e-6 then
		return tostring(math.floor(v + 0.5)) .. "%"
	end
	return string.format("%.1f%%", v)
end

-- Totals so far and what the next level brings.
function RunShopModel.levels(level: number?, cfg: any): ({ string }, { string })
	local g = gainsOf(cfg)
	local lv = math.max(1, math.floor(num(level, 1)))
	local gained = lv - 1
	local armorSteps = lv // g.armorEvery
	local have = {
		string.format("+%s max HP (+%s per level)", pct(gained * g.hpPct), pct(g.hpPct)),
		string.format("+%s damage (+%s per level)", pct(gained * g.dmgPct), pct(g.dmgPct)),
		string.format("+%d armor (+%d every %d levels)", armorSteps * g.armor, g.armor, g.armorEvery),
	}
	local nextArmor = (armorSteps + 1) * g.armorEvery
	local nextPick = (lv // g.pickEvery + 1) * g.pickEvery
	local nextUp = {
		string.format("Level %d: +%s max HP, +%s damage", lv + 1, pct(g.hpPct), pct(g.dmgPct)),
		string.format("Level %d: +%d armor", nextArmor, g.armor),
		string.format("Level %d: an upgrade pick", nextPick),
	}
	return have, nextUp
end

export type LevelRow = { level: number, text: string, reached: boolean }

-- The Levels list: one row per level with its gains, `ahead` levels past now.
function RunShopModel.levelRows(level: number?, cfg: any, ahead: number?): { LevelRow }
	local g = gainsOf(cfg)
	local lv = math.max(1, math.floor(num(level, 1)))
	local out: { LevelRow } = {}
	for l = 2, lv + math.max(0, math.floor(num(ahead, 5))) do
		local parts = { "+" .. pct(g.hpPct) .. " HP", "+" .. pct(g.dmgPct) .. " dmg" }
		if l % g.armorEvery == 0 then
			table.insert(parts, string.format("+%d armor", g.armor))
		end
		if l % g.pickEvery == 0 then
			table.insert(parts, "🃏 upgrade pick")
		end
		table.insert(out, { level = l, text = table.concat(parts, " · "), reached = l <= lv })
	end
	return out
end

return RunShopModel
