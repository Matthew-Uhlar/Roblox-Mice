--!strict
-- Soft-currency shop catalog (Team D). Logic lives in Data/Shop.luau.
--
-- Item ids (the string sent with Net.C2S.BuyShopItem):
--   "class:<classId>"       unlock a class for its Config/Classes unlockCost (cheese)
--   "talent:<talentId>"     buy the next level of a talent (cheese, Config/Talents costs)
--   "cosmetic:<id>"         buy a cosmetic with cheese (priceCheese)
--   "cosmetic:<id>:golden"  buy a cosmetic with Golden Cheese (priceGolden)
--   "bundle:<bundleId>"     reroll / Second Wind token bundles for cheese
--   "skin:<skinId>:golden"  (v5) one paid class skin (Config/ClassSkins source "paid")
--                           for Golden Cheese. Cosmetic only; earned skins are never sold.
-- Everything has a fixed, displayed price and a fixed result. Nothing is random.

local Talents = require("./Talents")
local Cosmetics = require("./Cosmetics")
local ClassSkins = require("./ClassSkins")

export type Currency = "cheese" | "golden"

export type BundleDef = {
	id: string,
	name: string,
	price: number, -- cheese
	rerollTokens: number?,
	secondWindTokens: number?,
}

export type ShopEntry = {
	itemId: string,
	kind: "class" | "talent" | "cosmetic" | "bundle" | "skin",
	refId: string,
	name: string,
	currency: Currency,
	price: number, -- for talents: price of level 1 (Data/Shop.price gives the next level's)
}

local S = {}

S.MAX_ITEM_ID_LEN = 64

-- Holding caps for tokens bought with cheese (Robux grants and daily rewards ignore them,
-- so a paid token is never lost).
S.TOKEN_CAPS = {
	rerollTokens = 30,
	secondWindTokens = 10,
}

S.BUNDLES = {
	reroll_3 = { id = "reroll_3", name = "3 Reroll Tokens", price = 300, rerollTokens = 3 },
	reroll_10 = { id = "reroll_10", name = "10 Reroll Tokens", price = 900, rerollTokens = 10 },
	secondwind_1 = { id = "secondwind_1", name = "1 Second Wind", price = 1000, secondWindTokens = 1 },
	secondwind_3 = { id = "secondwind_3", name = "3 Second Winds", price = 2700, secondWindTokens = 3 },
} :: { [string]: BundleDef }

S.BUNDLE_ORDER = { "reroll_3", "reroll_10", "secondwind_1", "secondwind_3" }

-- Team A writes Config/Classes concurrently; load it lazily and survive its absence.
local classesCache: any = nil
local classesTried = false
function S.classes(): any
	if not classesTried then
		classesTried = true
		local ok, mod = pcall(function()
			return require("./Classes") :: any
		end)
		if ok and type(mod) == "table" then
			classesCache = mod
		end
	end
	return classesCache
end

-- Unlock cost of a class, or nil if unknown.
function S.classCost(classId: string): number?
	local Classes = S.classes()
	if not Classes then
		return nil
	end
	local def = if type(Classes.get) == "function"
		then Classes.get(classId)
		else (Classes.defs or {})[classId]
	if type(def) ~= "table" or type(def.unlockCost) ~= "number" then
		return nil
	end
	return def.unlockCost
end

-- Every class id, in display order (falls back to an empty list without Classes).
function S.classIds(): { string }
	local Classes = S.classes()
	if Classes and type(Classes.ORDER) == "table" then
		return Classes.ORDER
	end
	return {}
end

-- Free class ids (unlockCost == 0).
function S.freeClassIds(): { string }
	local out = {}
	for _, id in S.classIds() do
		if S.classCost(id) == 0 then
			table.insert(out, id)
		end
	end
	return out
end

-- Full catalog for the shop UI.
function S.list(): { ShopEntry }
	local out: { ShopEntry } = {}
	for _, id in S.classIds() do
		local cost = S.classCost(id)
		if cost and cost > 0 then
			local Classes = S.classes()
			local def = Classes.get and Classes.get(id)
			table.insert(out, {
				itemId = "class:" .. id,
				kind = "class",
				refId = id,
				name = if def then def.name else id,
				currency = "cheese",
				price = cost,
			})
		end
	end
	for _, id in Talents.ORDER do
		local def = Talents.get(id)
		if def then
			table.insert(out, {
				itemId = "talent:" .. id,
				kind = "talent",
				refId = id,
				name = def.name,
				currency = "cheese",
				price = def.costs[1],
			})
		end
	end
	for _, def in Cosmetics.LIST do
		if def.source == "shop" then
			if def.priceCheese then
				table.insert(out, {
					itemId = "cosmetic:" .. def.id,
					kind = "cosmetic",
					refId = def.id,
					name = def.name,
					currency = "cheese",
					price = def.priceCheese,
				})
			end
			if def.priceGolden then
				table.insert(out, {
					itemId = "cosmetic:" .. def.id .. ":golden",
					kind = "cosmetic",
					refId = def.id,
					name = def.name,
					currency = "golden",
					price = def.priceGolden,
				})
			end
		end
	end
	for _, def in ClassSkins.LIST do
		if def.source == "paid" and def.priceGolden then
			table.insert(out, {
				itemId = "skin:" .. def.id .. ":golden",
				kind = "skin",
				refId = def.id,
				name = def.name,
				currency = "golden",
				price = def.priceGolden,
			})
		end
	end
	for _, id in S.BUNDLE_ORDER do
		local b = S.BUNDLES[id]
		table.insert(out, {
			itemId = "bundle:" .. id,
			kind = "bundle",
			refId = id,
			name = b.name,
			currency = "cheese",
			price = b.price,
		})
	end
	return out
end

return S
