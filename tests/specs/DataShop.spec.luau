local T = require("../lib/Test")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local Shop = require("../../src/shared/Data/Shop")
local ShopConfig = require("../../src/shared/Config/Shop")
local Talents = require("../../src/shared/Config/Talents")

local function rich()
	local p = ProfileSchema.default()
	p.cheese = 1_000_000
	p.goldenCheese = 10_000
	return p
end

T.describe("Shop.parse", function()
	T.it("parses valid ids and rejects garbage", function()
		local x = Shop.parse("cosmetic:trail_lava:golden")
		T.eq(x and x.kind, "cosmetic")
		T.eq(x and x.ref, "trail_lava")
		T.eq(x and x.currency, "golden")
		T.eq((Shop.parse("talent:thick_hide") :: any).currency, nil)
		for _, bad in
			{ nil, 5, "", "nocolon", "a:b:c:d", "class:../x", string.rep("a", 80) .. ":b", "class: x" }
		do
			T.eq(Shop.parse(bad), nil, tostring(bad))
		end
	end)
end)

T.describe("Shop classes", function()
	T.it("unlocks a paid class for its Config/Classes cost", function()
		local p = ProfileSchema.default()
		p.cheese = 2600
		local cost = ShopConfig.classCost("le_fante")
		T.eq(cost, 2500)
		T.truthy(Shop.buy(p, "class:le_fante"))
		T.eq(p.cheese, 100)
		T.truthy(p.unlockedClasses.le_fante)
		local ok, why = Shop.buy(p, "class:le_fante")
		T.falsy(ok)
		T.eq(why, "owned")
	end)
	T.it("refuses free, unknown and unaffordable classes", function()
		local p = ProfileSchema.default()
		T.eq(select(2, Shop.canBuy(p, "class:elephante")), "not_for_sale")
		T.eq(select(2, Shop.canBuy(p, "class:dumbo")), "unknown_item")
		T.eq(select(2, Shop.canBuy(p, "class:jumbo")), "insufficient_funds")
		T.eq(p.cheese, 0)
	end)
end)

T.describe("Shop talents", function()
	T.it("buys levels in order with rising costs up to max", function()
		local p = rich()
		local def = Talents.get("quick_feet") :: any
		local spent = 0
		for lvl = 1, def.maxLevel do
			local price = Shop.price(p, "talent:quick_feet") :: any
			T.eq(price.amount, def.costs[lvl])
			spent += price.amount
			T.truthy(Shop.buy(p, "talent:quick_feet"))
			T.eq(p.talents.quick_feet, lvl)
		end
		T.eq(p.cheese, 1_000_000 - spent)
		local ok, why = Shop.buy(p, "talent:quick_feet")
		T.falsy(ok)
		T.eq(why, "max_level")
	end)
	T.it("rejects unknown talents", function()
		T.eq(select(2, Shop.canBuy(rich(), "talent:godmode")), "unknown_item")
	end)
end)

T.describe("Shop cosmetics", function()
	T.it("buys with cheese or golden depending on the id", function()
		local p = rich()
		T.truthy(Shop.buy(p, "cosmetic:trail_stardust:golden"))
		T.eq(p.goldenCheese, 10_000 - 800)
		T.eq(p.cheese, 1_000_000)
		T.eq(select(2, Shop.buy(p, "cosmetic:trail_stardust")), "owned")
		T.truthy(Shop.buy(p, "cosmetic:hat_party"))
		T.eq(p.cheese, 1_000_000 - 800)
	end)
	T.it("refuses a currency the item isn't priced in", function()
		T.eq(select(2, Shop.canBuy(rich(), "cosmetic:trail_lava")), "not_for_sale")
		T.eq(select(2, Shop.canBuy(rich(), "cosmetic:hat_party:golden")), "not_for_sale")
		T.eq(select(2, Shop.canBuy(rich(), "cosmetic:hat_party:robux")), "bad_id")
	end)
	T.it("never sells pass, daily, club, level or epic cosmetics", function()
		for _, id in { "trail_golden_tusk", "trail_streak", "hat_club_cap", "hat_top", "tint_shadow" } do
			T.eq(select(2, Shop.canBuy(rich(), "cosmetic:" .. id)), "not_for_sale", id)
			T.eq(select(2, Shop.canBuy(rich(), "cosmetic:" .. id .. ":golden")), "not_for_sale", id)
		end
	end)
	T.it("gives Cheese Club members 10% off cosmetics only", function()
		local p = rich()
		local price = Shop.price(p, "cosmetic:trail_lava:golden", { club = true }) :: any
		T.eq(price.amount, 360)
		local bundle = Shop.price(p, "bundle:reroll_3", { club = true }) :: any
		T.eq(bundle.amount, 300)
	end)
end)

T.describe("Shop bundles", function()
	T.it("grants tokens and respects holding caps", function()
		local p = rich()
		T.truthy(Shop.buy(p, "bundle:reroll_10"))
		T.truthy(Shop.buy(p, "bundle:reroll_10"))
		T.truthy(Shop.buy(p, "bundle:reroll_10"))
		T.eq(p.rerollTokens, 30)
		T.eq(select(2, Shop.buy(p, "bundle:reroll_3")), "cap_reached")
		p.secondWindTokens = 9
		T.eq(select(2, Shop.buy(p, "bundle:secondwind_3")), "cap_reached")
		T.truthy(Shop.buy(p, "bundle:secondwind_1"))
		T.eq(p.secondWindTokens, 10)
	end)
	T.it("does not change the profile on failure", function()
		local p = ProfileSchema.default()
		p.cheese = 299
		local before = ProfileSchema.deepCopy(p)
		T.falsy(Shop.buy(p, "bundle:reroll_3"))
		T.deepEq(p, before)
	end)
end)

T.describe("Shop.equip", function()
	T.it("equips owned cosmetics in the right slot only", function()
		local p = rich()
		T.eq(select(2, Shop.equip(p, "hat", "hat_party")), "not_owned")
		Shop.buy(p, "cosmetic:hat_party")
		T.eq(select(2, Shop.equip(p, "trail", "hat_party")), "wrong_slot")
		T.eq(select(2, Shop.equip(p, "shoes", "hat_party")), "bad_slot")
		T.eq(select(2, Shop.equip(p, "hat", 12)), "bad_id")
		T.truthy(Shop.equip(p, "hat", "hat_party"))
		T.eq(p.equipped.hat, "hat_party")
		T.truthy(Shop.equip(p, "hat", nil))
		T.eq(p.equipped.hat, nil)
	end)
end)

T.describe("Shop catalog", function()
	T.it("lists every entry as buyable by a rich new profile", function()
		local list = ShopConfig.list()
		T.truthy(#list > 20)
		for _, e in list do
			local p = rich()
			local ok, why = Shop.canBuy(p, e.itemId)
			T.truthy(ok, e.itemId .. " " .. tostring(why))
			local price = Shop.price(p, e.itemId) :: any
			T.eq(price.amount, e.price, e.itemId)
			T.eq(price.currency, e.currency, e.itemId)
		end
	end)
end)

return T.finish()
