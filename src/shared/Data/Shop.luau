--!strict
-- Soft-currency shop logic (Team D). Pure. Item ids are documented in Config/Shop.
-- Every function validates its input and never throws on garbage.
--
-- Reasons returned on failure:
--   "bad_id" | "unknown_item" | "owned" | "max_level" | "not_for_sale"
--   "insufficient_funds" | "cap_reached" | "not_owned" | "wrong_slot" | "bad_slot"

local Types = require("../Types")
local ShopConfig = require("../Config/Shop")
local Talents = require("../Config/Talents")
local Cosmetics = require("../Config/Cosmetics")
local Monetization = require("../Config/Monetization")
local ClassSkins = require("../Config/ClassSkins")
local ClassProgress = require("./ClassProgress")

type Profile = Types.Profile

local Shop = {}

export type Ctx = {
	club: boolean?, -- Cheese Club member: 10% off cosmetics
}

export type Parsed = { kind: string, ref: string, currency: string? }

-- "kind:ref" or "kind:ref:currency". Returns nil for anything malformed.
function Shop.parse(itemId: any): Parsed?
	if type(itemId) ~= "string" or #itemId == 0 or #itemId > ShopConfig.MAX_ITEM_ID_LEN then
		return nil
	end
	if not string.match(itemId, "^[%w_:]+$") then
		return nil
	end
	local kind, ref, currency = string.match(itemId, "^(%a+):([%w_]+):?(%a*)$")
	if not kind or not ref then
		return nil
	end
	if currency == "" then
		currency = nil
	end
	return { kind = kind, ref = ref, currency = currency }
end

export type Price = { currency: ShopConfig.Currency, amount: number }

-- Price of the item for this profile (talents: next level). (nil, reason) if not buyable at all.
function Shop.price(profile: Profile, itemId: any, ctx: Ctx?): (Price?, string?)
	local p = Shop.parse(itemId)
	if not p then
		return nil, "bad_id"
	end
	if p.kind == "class" and p.currency == nil then
		local cost = ShopConfig.classCost(p.ref)
		if cost == nil then
			return nil, "unknown_item"
		end
		if cost <= 0 then
			return nil, "not_for_sale"
		end
		return { currency = "cheese", amount = cost }, nil
	elseif p.kind == "talent" and p.currency == nil then
		local def = Talents.get(p.ref)
		if not def then
			return nil, "unknown_item"
		end
		local cost = Talents.costFor(p.ref, profile.talents[p.ref] or 0)
		if not cost then
			return nil, "max_level"
		end
		return { currency = "cheese", amount = cost }, nil
	elseif p.kind == "cosmetic" then
		local def = Cosmetics.get(p.ref)
		if not def then
			return nil, "unknown_item"
		end
		if def.source ~= "shop" then
			return nil, "not_for_sale"
		end
		local amount: number?
		local currency: ShopConfig.Currency
		if p.currency == nil then
			amount, currency = def.priceCheese, "cheese"
		elseif p.currency == "golden" then
			amount, currency = def.priceGolden, "golden"
		else
			return nil, "bad_id"
		end
		if not amount then
			return nil, "not_for_sale"
		end
		if ctx and ctx.club then
			amount = math.ceil(amount * (1 - Monetization.RULES.clubShopDiscount))
		end
		return { currency = currency, amount = amount :: number }, nil
	elseif p.kind == "bundle" and p.currency == nil then
		local b = ShopConfig.BUNDLES[p.ref]
		if not b then
			return nil, "unknown_item"
		end
		return { currency = "cheese", amount = b.price }, nil
	elseif p.kind == "skin" then
		-- (v5) paid class skins, Golden Cheese only ("skin:<skinId>:golden"). Cosmetic only.
		local def = ClassSkins.get(p.ref)
		if not def then
			return nil, "unknown_item"
		end
		if def.source ~= "paid" or not def.priceGolden then
			return nil, "not_for_sale"
		end
		if p.currency ~= "golden" then
			return nil, "bad_id"
		end
		local amount = def.priceGolden :: number
		if ctx and ctx.club then
			amount = math.ceil(amount * (1 - Monetization.RULES.clubShopDiscount))
		end
		return { currency = "golden", amount = amount }, nil
	end
	return nil, "unknown_item"
end

local function balance(profile: Profile, currency: string): number
	return if currency == "golden" then profile.goldenCheese else profile.cheese
end

function Shop.canBuy(profile: Profile, itemId: any, ctx: Ctx?): (boolean, string?)
	local price, reason = Shop.price(profile, itemId, ctx)
	if not price then
		return false, reason
	end
	local p = Shop.parse(itemId) :: Parsed
	if p.kind == "class" and profile.unlockedClasses[p.ref] then
		return false, "owned"
	elseif p.kind == "cosmetic" and profile.cosmetics[p.ref] then
		return false, "owned"
	elseif
		p.kind == "skin"
		and type((profile :: any).ownedSkins) == "table"
		and (profile :: any).ownedSkins[p.ref]
	then
		return false, "owned"
	elseif p.kind == "bundle" then
		local b = ShopConfig.BUNDLES[p.ref]
		local caps = ShopConfig.TOKEN_CAPS
		if b.rerollTokens and profile.rerollTokens + b.rerollTokens > caps.rerollTokens then
			return false, "cap_reached"
		end
		if b.secondWindTokens and profile.secondWindTokens + b.secondWindTokens > caps.secondWindTokens then
			return false, "cap_reached"
		end
	end
	if balance(profile, price.currency) < price.amount then
		return false, "insufficient_funds"
	end
	return true, nil
end

-- Buys the item in place. (true, nil) on success, otherwise (false, reason) with no change.
function Shop.buy(profile: Profile, itemId: any, ctx: Ctx?): (boolean, string?)
	local ok, reason = Shop.canBuy(profile, itemId, ctx)
	if not ok then
		return false, reason
	end
	local price = Shop.price(profile, itemId, ctx) :: Price
	local p = Shop.parse(itemId) :: Parsed
	if price.currency == "golden" then
		profile.goldenCheese -= price.amount
	else
		profile.cheese -= price.amount
	end
	if p.kind == "class" then
		profile.unlockedClasses[p.ref] = true
		ClassProgress.ensure(profile, p.ref) -- (v5) class progression block
	elseif p.kind == "skin" then
		local anyP = profile :: any
		if type(anyP.ownedSkins) ~= "table" then
			anyP.ownedSkins = {}
		end
		anyP.ownedSkins[p.ref] = true
	elseif p.kind == "talent" then
		profile.talents[p.ref] = (profile.talents[p.ref] or 0) + 1
	elseif p.kind == "cosmetic" then
		profile.cosmetics[p.ref] = true
	elseif p.kind == "bundle" then
		local b = ShopConfig.BUNDLES[p.ref]
		profile.rerollTokens += b.rerollTokens or 0
		profile.secondWindTokens += b.secondWindTokens or 0
	end
	return true, nil
end

-- Equip (or unequip with cosmeticId = nil) a cosmetic the profile owns.
function Shop.equip(profile: Profile, slot: any, cosmeticId: any): (boolean, string?)
	if slot ~= "trail" and slot ~= "hat" and slot ~= "tint" then
		return false, "bad_slot"
	end
	if cosmeticId == nil then
		(profile.equipped :: any)[slot] = nil
		return true, nil
	end
	if type(cosmeticId) ~= "string" or #cosmeticId > ShopConfig.MAX_ITEM_ID_LEN then
		return false, "bad_id"
	end
	local def = Cosmetics.get(cosmeticId)
	if not def then
		return false, "unknown_item"
	end
	if def.slot ~= slot then
		return false, "wrong_slot"
	end
	if not profile.cosmetics[cosmeticId] then
		return false, "not_owned"
	end
	(profile.equipped :: any)[slot] = cosmeticId
	return true, nil
end

-- Whether the profile may select this class (unlocked and known).
function Shop.canSelectClass(profile: Profile, classId: any): boolean
	return type(classId) == "string"
		and #classId <= ShopConfig.MAX_ITEM_ID_LEN
		and profile.unlockedClasses[classId] == true
end

return Shop
