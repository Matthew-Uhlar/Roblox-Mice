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
	local max = num(cfg.MAX_RANK, 25)
	if not def or rank >= max then
		return nil
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
	local max = math.floor(num(cfg.MAX_RANK, 25))
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
-- every 10 levels +1 armor. Returns the total so far and the next milestones.
function RunShopModel.levels(level: number?): ({ string }, { string })
	local lv = math.max(1, math.floor(num(level, 1)))
	local gained = lv - 1
	local fives = lv // 5
	local tens = lv // 10
	local have = {
		string.format("+%d max HP (+2 per level)", gained * 2),
		string.format("+%d%% damage (+3%% every 5 levels)", fives * 3),
		string.format("+%d armor (+1 every 10 levels)", tens),
	}
	local nextFive = (fives + 1) * 5
	local nextTen = (tens + 1) * 10
	local nextUp = {
		string.format("Level %d: +2 max HP", lv + 1),
		string.format("Level %d: +3%% damage", nextFive),
		string.format("Level %d: +1 armor", nextTen),
	}
	return have, nextUp
end

return RunShopModel
