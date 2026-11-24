--!strict
-- Gem Vault model (iter6, team Gems). Pure: no Roblox APIs, unit-tested under Lune
-- (tests/specs/ClientGemVault.spec.luau). Works on Util/GemModel gems; `cfg` is
-- Config/Gems (its feedResult / power / RANGES win; local copies are the fallback).
--
--   sort(list, key, cfg)            key: tier | power | rinds..stride | newest | level
--   filter(list, f)                 f: {minTier, maxTier, unique, equipped, locked: "any"|"yes"|"no", uniqueId?}
--   quality(g, stat, cfg) -> 0..1   the roll inside its tier's min-max range
--   eligible(g, targetId?)          may be fed / salvaged (not equipped, not locked, not the target)
--   selectBelowTier / selectLowerPower -> {id}   quick fodder picks (capped)
--   feedPreview(target, fodder, cfg) -> Preview   matches the server (Data/Gems.feed)
--   salvageTotal(list) -> dust
--   compare(g, other, cfg) -> {[stat]: delta fraction}

local GemModel = require("./GemModel")

type Gem = GemModel.Gem

local M = {}

M.SORTS = { "tier", "power", "rinds", "bite", "hide", "plating", "stride", "newest", "level" }
M.SORT_LABEL = {
	tier = "Tier",
	power = "Power",
	rinds = "Rinds",
	bite = "Bite",
	hide = "Hide",
	plating = "Plating",
	stride = "Stride",
	newest = "Newest",
	level = "Level",
} :: { [string]: string }
M.FEED_MAX = 50
-- Design sizes of the Gem Vault (UI/GemsUI), checked by the ClientLayout readability
-- spec: fixed-height boxes are ~1.7x their text size; rows use UiSizes.MENU.
M.UI = table.freeze({
	modalW = 860,
	modalH = 560,
	split = 0.5, -- grid | detail
	cardW = 104,
	cardH = 120,
	icon = 44,
	tierText = 15,
	tierBox = 26,
	powerText = 14,
	powerBox = 24,
	badgeText = 13,
	badgeBox = 22,
	statText = 15,
	statBox = 26,
	pillText = 15,
	btnText = 15,
	headTitle = 18,
	headTitleBox = 31,
	headSub = 15,
	headSubBox = 52, -- 2 lines
})
M.SALVAGE_MAX = 100

-- Fallback ranges (Config/Gems.RANGES) when no cfg is given.
local RANGES = {
	{ 10, 20 },
	{ 10, 22 },
	{ 12, 25 },
	{ 14, 30 },
	{ 15, 40 },
	{ 20, 50 },
	{ 25, 60 },
	{ 30, 75 },
	{ 35, 90 },
	{ 40, 105 },
	{ 50, 125 },
	{ 75, 170 },
}

function M.range(tier: number, cfg: any): (number, number)
	local r = (type(cfg) == "table" and type(cfg.RANGES) == "table" and cfg.RANGES[tier])
		or RANGES[tier]
		or RANGES[1]
	return r[1], r[2]
end

local function maxLevel(cfg: any): number
	return if type(cfg) == "table" and type(cfg.MAX_LEVEL) == "number"
		then cfg.MAX_LEVEL
		else GemModel.MAX_LEVEL
end

function M.cost(tier: number, toLevel: number, cfg: any): number
	if type(cfg) == "table" and type(cfg.upgradeCost) == "function" then
		return cfg.upgradeCost(tier, toLevel)
	end
	return math.max(1, toLevel) * tier
end

-- Same rule as Config/Gems.feedResult (used when cfg has none).
function M.feedResult(tier: number, level: number, dust: number, cfg: any): (number, number, number)
	if type(cfg) == "table" and type(cfg.feedResult) == "function" then
		return cfg.feedResult(tier, level, dust)
	end
	local lv, left, spent = math.floor(level), math.max(0, math.floor(dust)), 0
	while lv < maxLevel(cfg) do
		local c = M.cost(tier, lv + 1, cfg)
		if left < c then
			break
		end
		left -= c
		spent += c
		lv += 1
	end
	return lv, spent, left
end

local function rolls(g: Gem): { number }
	local out = {}
	for i, k in GemModel.STATS do
		out[i] = g.stats[k] or 0
	end
	return out
end

function M.power(g: Gem, cfg: any, level: number?): number
	if level == nil and g.power then
		return g.power
	end
	local lv = level or g.level
	if type(cfg) == "table" and type(cfg.power) == "function" then
		return cfg.power(g.tier, rolls(g), lv, g.unique ~= nil)
	end
	local sum = 0
	for _, v in rolls(g) do
		sum += v
	end
	local _, hi = M.range(g.tier, cfg)
	return math.floor(sum * (1 + GemModel.LEVEL_BONUS * lv) + (if g.unique then hi else 0) + 0.5)
end

function M.quality(g: Gem, stat: string, cfg: any): number
	local lo, hi = M.range(g.tier, cfg)
	if hi <= lo then
		return 1
	end
	return math.clamp(((g.stats[stat] or lo) - lo) / (hi - lo), 0, 1)
end

-- Sorted copy, best first (ties: newest first).
function M.sort(list: { Gem }, key: string, cfg: any): { Gem }
	local out = table.clone(list)
	local val: { [Gem]: number } = {}
	for _, g in out do
		val[g] = if key == "tier"
			then g.tier * 1e6 + M.power(g, cfg)
			elseif key == "power" then M.power(g, cfg)
			elseif key == "newest" then g.id
			elseif key == "level" then g.level * 1e6 + M.power(g, cfg)
			elseif GemModel.STAT_INFO[key] then GemModel.statValue(g, key, cfg)
			else g.id
	end
	table.sort(out, function(a, b)
		if val[a] ~= val[b] then
			return val[a] > val[b]
		end
		return a.id > b.id
	end)
	return out
end

export type Filter = {
	minTier: number?,
	maxTier: number?,
	unique: string?, -- "any" | "yes" | "no"
	equipped: string?,
	locked: string?,
	uniqueId: string?,
}

local function tri(mode: string?, v: boolean): boolean
	return mode == nil or mode == "any" or (mode == "yes") == v
end

function M.filter(list: { Gem }, f: Filter?): { Gem }
	local o: Filter = f or {}
	local out = {}
	for _, g in list do
		if
			g.tier >= (o.minTier or 1)
			and g.tier <= (o.maxTier or 99)
			and tri(o.unique, g.unique ~= nil)
			and tri(o.equipped, g.equipped ~= nil)
			and tri(o.locked, g.locked == true)
			and (o.uniqueId == nil or g.unique == o.uniqueId)
		then
			table.insert(out, g)
		end
	end
	return out
end

function M.eligible(g: Gem, targetId: number?): boolean
	return g.equipped == nil and not g.locked and g.id ~= targetId
end

-- Fodder below tier n (weakest first), capped.
function M.selectBelowTier(list: { Gem }, n: number, targetId: number?, cap: number?, cfg: any): { number }
	local out = {}
	for _, g in M.sort(list, "power", cfg) do
		if M.eligible(g, targetId) and g.tier < n then
			table.insert(out, g.id)
		end
	end
	local lim = cap or M.FEED_MAX
	local res = {}
	for i = #out, math.max(1, #out - lim + 1), -1 do
		table.insert(res, out[i])
	end
	return res
end

-- Unlocked gems with less power than the target (weakest first), capped.
function M.selectLowerPower(list: { Gem }, target: Gem, cap: number?, cfg: any): { number }
	local tp = M.power(target, cfg)
	local pool = {}
	for _, g in M.sort(list, "power", cfg) do
		if M.eligible(g, target.id) and M.power(g, cfg) < tp then
			table.insert(pool, g.id)
		end
	end
	local lim = cap or M.FEED_MAX
	local res = {}
	for i = #pool, math.max(1, #pool - lim + 1), -1 do
		table.insert(res, pool[i])
	end
	return res
end

function M.salvageTotal(list: { Gem }): number
	local d = 0
	for _, g in list do
		d += GemModel.salvageDust(g)
	end
	return d
end

export type Preview = {
	ok: boolean,
	reason: string?,
	dust: number,
	from: number,
	level: number,
	spent: number,
	leftover: number,
	power: number,
	values: { [string]: number }, -- stat fractions at the new level
}

-- What feeding `fodder` into `target` gives (Data/Gems.feed rules).
function M.feedPreview(target: Gem, fodder: { Gem }, cfg: any): Preview
	local dust = M.salvageTotal(fodder)
	local reason: string? = nil
	if #fodder == 0 then
		reason = "none"
	elseif #fodder > M.FEED_MAX then
		reason = "too_many"
	elseif target.level >= maxLevel(cfg) then
		reason = "gem_max"
	else
		for _, g in fodder do
			if not M.eligible(g, target.id) then
				reason = if g.id == target.id then "self" elseif g.locked then "locked" else "equipped"
				break
			end
		end
	end
	local lv, spent, left = M.feedResult(target.tier, target.level, dust, cfg)
	local after: Gem = table.clone(target)
	after.level = lv
	after.values = nil
	local values = {}
	for _, k in GemModel.STATS do
		values[k] = GemModel.statValue(after, k, cfg)
	end
	return {
		ok = reason == nil,
		reason = reason,
		dust = dust,
		from = target.level,
		level = lv,
		spent = spent,
		leftover = left,
		power = M.power(target, cfg, lv),
		values = values,
	}
end

-- Per-stat difference g - other (fractions after levels); other nil = vs nothing.
function M.compare(g: Gem, other: Gem?, cfg: any): { [string]: number }
	local out = {}
	for _, k in GemModel.STATS do
		out[k] = GemModel.statValue(g, k, cfg) - (if other then GemModel.statValue(other, k, cfg) else 0)
	end
	return out
end

return M
