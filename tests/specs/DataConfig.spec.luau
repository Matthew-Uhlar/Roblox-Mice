local T = require("../lib/Test")
local Monetization = require("../../src/shared/Config/Monetization")
local Cosmetics = require("../../src/shared/Config/Cosmetics")
local Talents = require("../../src/shared/Config/Talents")
local ShopConfig = require("../../src/shared/Config/Shop")
local Receipts = require("../../src/shared/Data/Receipts")
local Daily = require("../../src/shared/Data/Daily")

T.describe("Benefits are delivered (QC2 B1)", function()
	T.it("pass benefits mention every pass cosmetic by name", function()
		for _, item in Monetization.PASSES do
			for _, id in item.cosmetics or {} do
				local def = Cosmetics.get(id) :: any
				local short = string.match(def.name, "^(%S+)") :: string
				T.truthy(string.find(item.benefit, short, 1, true), item.key .. " lists " .. def.name)
			end
		end
	end)
	T.it("timed boosts disclose the cap and the Golden Cheese fallback", function()
		for _, key in { "cheese_rush", "cheese_feast" } do
			local item = Monetization.get(key) :: any
			T.truthy(string.find(item.benefit, "refunded as Golden Cheese", 1, true), key)
		end
		T.truthy(Monetization.RULES.cheeseRushOverflowGolden > 0)
		T.truthy(Monetization.RULES.feastOverflowGolden > 0)
	end)
end)

T.describe("Talent levels players paid for are never lowered (QC2 Minor 8)", function()
	-- Lowering maxLevel would clamp paid levels on load (ProfileSchema talentMap) and
	-- the cheese is gone. To lower one, add a ProfileSchema migration that refunds the
	-- clamped levels at the OLD prices first, then update this table.
	local SHIPPED_MAX = {
		thick_hide = 5,
		heavy_trunk = 5,
		quick_feet = 4,
		crumb_magnet = 4,
		cheese_nose = 5,
		quick_study = 5,
		second_breath = 4,
		lucky_tusk = 4,
	}
	T.it("every shipped talent keeps at least its shipped maxLevel", function()
		for id, max in SHIPPED_MAX do
			local def = Talents.get(id)
			T.truthy(def, "talent removed: " .. id)
			T.truthy((def :: any).maxLevel >= max, id .. " maxLevel lowered")
		end
	end)
end)

T.describe("Config/Monetization", function()
	T.it("has unique keys and valid kinds", function()
		local seen = {}
		for _, item in Monetization.ALL do
			T.falsy(seen[item.key], "duplicate key " .. item.key)
			seen[item.key] = true
			T.truthy(item.kind == "pass" or item.kind == "product" or item.kind == "subscription", item.key)
			T.truthy(type(item.name) == "string" and #item.name > 0, item.key)
			T.truthy(type(item.benefit) == "string" and #item.benefit > 10, item.key)
			T.eq(Monetization.get(item.key), item)
		end
	end)
	T.it("marks no item random", function()
		for _, item in Monetization.ALL do
			T.eq(item.random, false, item.key .. " must declare random = false")
		end
	end)
	T.it("has a positive fallback price for every Robux item", function()
		for _, item in Monetization.ALL do
			if item.adOnly then
				T.eq(item.kind, "product", item.key)
			else
				T.truthy(type(item.fallbackPrice) == "number" and item.fallbackPrice > 0, item.key)
			end
		end
	end)
	T.it("subscription price respects the 49 R$ minimum", function()
		for _, item in Monetization.SUBSCRIPTIONS do
			T.truthy(item.fallbackPrice >= 49, item.key)
		end
	end)
	T.it("every developer product has a grant handler", function()
		for _, item in Monetization.PRODUCTS do
			T.truthy(Receipts.hasHandler(item.key), "no handler for " .. item.key)
		end
		for key in Receipts.HANDLERS do
			local item = Monetization.get(key)
			T.truthy(item and item.kind == "product", "handler without product " .. key)
		end
	end)
	T.it("ids come from Monetization or the generated ProductIds; 0 never resolves", function()
		local ProductIds = require("../../src/shared/Config/ProductIds") :: { [string]: number | string }
		for _, item in Monetization.ALL do
			T.truthy(ProductIds[item.key] ~= nil, "ProductIds.luau lacks " .. item.key)
			T.eq(Monetization.isConfigured(item), item.assetId ~= 0, item.key)
		end
		T.eq(Monetization.keyForAsset("product", 0), nil)
	end)
	T.it("pass cosmetics exist and point back at their pass", function()
		for _, item in Monetization.PASSES do
			for _, id in item.cosmetics or {} do
				local def = Cosmetics.get(id)
				T.truthy(def, id)
				T.eq((def :: any).source, "pass", id)
				T.eq((def :: any).passKey, item.key, id)
			end
		end
	end)
	T.it("club monthly cosmetics exist and are club-only", function()
		for _, id in Monetization.RULES.clubMonthlyCosmetics do
			T.eq((Cosmetics.get(id) :: any).source, "club", id)
		end
	end)
	T.it("[QC-B V2-M1] Second Wind prompts are refused for run members only", function()
		for _, key in { "second_wind_1", "second_wind_3" } do
			local item = Monetization.get(key)
			T.eq((Monetization.promptRefusal(item, true)), "in_run", key .. " in a run")
			T.eq((Monetization.promptRefusal(item, false)), nil, key .. " in the lobby")
			local _, text = Monetization.promptRefusal(item, true)
			T.truthy(type(text) == "string" and #text > 10, "a clear toast")
		end
		for _, key in { "cheese_rush", "golden_s", "respec_token", "cheese_club" } do
			T.eq((Monetization.promptRefusal(Monetization.get(key), true)), nil, key .. " is not a revive")
		end
	end)
	T.it("[QC-B V2-M1] Second Wind and Club texts disclose the PvP rule", function()
		for _, key in { "second_wind_1", "second_wind_3", "cheese_club" } do
			local b = string.lower((Monetization.get(key) :: any).benefit)
			T.truthy(string.find(b, "last squad", 1, true) or string.find(b, "last one left", 1, true), key)
		end
		T.truthy(
			string.find((Monetization.get("second_wind_1") :: any).benefit, "Double-or-Nothing", 1, true)
		)
		T.eq(Monetization.RULES.tokenReviveBlockedFromSquads, 2)
	end)
	T.it("Golden Cheese bonus grows with pack size", function()
		local last = 0
		for _, key in { "golden_xs", "golden_s", "golden_m", "golden_l", "golden_xl" } do
			local item = Monetization.get(key) :: any
			local rate = item.goldenCheese / item.fallbackPrice
			T.truthy(rate >= last, key)
			last = rate
		end
	end)
end)

T.describe("Config/Cosmetics", function()
	T.it("has unique ids, valid slots and sane prices", function()
		local seen = {}
		for _, def in Cosmetics.LIST do
			T.falsy(seen[def.id], def.id)
			seen[def.id] = true
			T.truthy(def.slot == "trail" or def.slot == "hat" or def.slot == "tint", def.id)
			if def.source == "shop" then
				T.truthy((def.priceCheese or 0) > 0 or (def.priceGolden or 0) > 0, def.id)
			else
				T.eq(def.priceCheese, nil, def.id)
				T.eq(def.priceGolden, nil, def.id)
			end
			if def.source == "pass" then
				local pass = Monetization.get(def.passKey :: string)
				T.truthy(pass and pass.kind == "pass", def.id)
			end
			if def.source == "level" then
				T.truthy(def.unlockLevel and def.unlockLevel % 5 == 0, def.id)
			end
			if def.color then
				T.eq(#def.color, 3, def.id)
			end
		end
	end)
	T.it("daily cosmetics exist", function()
		for _, r in Daily.REWARDS do
			if r.cosmetic then
				T.eq((Cosmetics.get(r.cosmetic) :: any).source, "daily", r.cosmetic)
			end
		end
	end)
end)

T.describe("Config/Talents", function()
	T.it("has 6-8 well-formed talents", function()
		T.truthy(#Talents.ORDER >= 6 and #Talents.ORDER <= 8)
		for _, id in Talents.ORDER do
			local def = Talents.get(id) :: any
			T.truthy(def, id)
			T.eq(def.id, id)
			T.eq(#def.costs, def.maxLevel, id)
			local last = 0
			for _, c in def.costs do
				T.truthy(c > last, id .. " costs rise")
				last = c
			end
			T.truthy(def.perLevel.add ~= nil, id)
			for stat, v in def.perLevel.add do
				T.truthy(type(stat) == "string" and v > 0, id)
			end
			T.eq(Talents.costFor(id, def.maxLevel), nil)
		end
	end)
	T.it("talent stats are real PlayerStats fields (when Stats exists)", function()
		local ok, Stats = pcall(function()
			return require("../../src/shared/Run/Stats") :: any
		end)
		if not ok or type(Stats) ~= "table" or type(Stats.DEFAULT) ~= "table" then
			return -- Team A's module not written yet
		end
		for _, id in Talents.ORDER do
			for stat in (Talents.get(id) :: any).perLevel.add do
				T.truthy(Stats.DEFAULT[stat] ~= nil, id .. "." .. stat)
			end
		end
	end)
end)

T.describe("Config/Shop", function()
	T.it("lists class unlocks priced from Config/Classes", function()
		local found = 0
		for _, e in ShopConfig.list() do
			if e.kind == "class" then
				found += 1
				T.eq(e.price, ShopConfig.classCost(e.refId))
				T.truthy(e.price > 0)
			end
		end
		T.eq(found, 4, "4 paid classes")
	end)
	T.it("has unique item ids and positive prices", function()
		local seen = {}
		for _, e in ShopConfig.list() do
			T.falsy(seen[e.itemId], e.itemId)
			seen[e.itemId] = true
			T.truthy(e.price > 0, e.itemId)
			T.truthy(#e.itemId <= ShopConfig.MAX_ITEM_ID_LEN, e.itemId)
		end
	end)
	T.it("bundles sell only cheese-currency tokens", function()
		for _, b in ShopConfig.BUNDLES do
			T.truthy((b.rerollTokens or 0) + (b.secondWindTokens or 0) > 0, b.id)
		end
	end)
end)

return T.finish()
