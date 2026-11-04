-- Shop Cart purchase rules (Run/CartRules): QC-A M3 (the cart charges the
-- buyer's own share) and QC-B V2-m3 (Waves only, standing at the cart).
local T = require("../lib/Test")
local CartRules = require("../../src/shared/Run/CartRules")

local function cart(): any
	return {
		squad = 2,
		offers = { { id = "a" }, { id = "b" }, { id = "c" } },
		prices = { 60, 120, 220 },
		bought = { [3] = true },
		x = 10,
		z = -20,
	}
end

T.describe("CartRules.check", function()
	T.it("a buy at the cart in the waves with enough own share is OK", function()
		local ok, why, price = CartRules.check(cart(), 2, "Waves", { x = 12, z = -18 }, 100, 1)
		T.truthy(ok, tostring(why))
		T.eq(price, 60)
	end)
	T.it("the price is checked against the hero's OWN share, not the squad pot", function()
		-- squad pot would be 3 x 100 = 300; the hero's share is 100 < 120
		local ok, why = CartRules.check(cart(), 2, "Waves", { x = 10, z = -20 }, 100, 2)
		T.falsy(ok)
		T.eq(why, "funds")
		T.truthy((CartRules.check(cart(), 2, "Waves", { x = 10, z = -20 }, 120, 2)))
	end)
	T.it("another squad's cart, an unknown cart or index is refused", function()
		T.eq(select(2, CartRules.check(cart(), 1, "Waves", { x = 10, z = -20 }, 999, 1)), "no_cart")
		T.eq(select(2, CartRules.check(nil, 2, "Waves", { x = 10, z = -20 }, 999, 1)), "no_cart")
		T.eq(select(2, CartRules.check(cart(), 2, "Waves", { x = 10, z = -20 }, 999, 7)), "sold")
	end)
	T.it("a bought item stays sold", function()
		T.eq(select(2, CartRules.check(cart(), 2, "Waves", { x = 10, z = -20 }, 999, 3)), "sold")
	end)
	T.it("only during the Waves phase", function()
		for _, phase in { "Boss", "StageClear", "RouteChoice", "Extraction", "Lobby" } do
			T.eq(select(2, CartRules.check(cart(), 2, phase, { x = 10, z = -20 }, 999, 1)), "phase", phase)
		end
	end)
	T.it("the buyer must stand within RANGE studs of the cart", function()
		T.eq(CartRules.RANGE, 14)
		local r = CartRules.RANGE
		T.truthy((CartRules.check(cart(), 2, "Waves", { x = 10 + r - 0.1, z = -20 }, 999, 1)))
		T.eq(select(2, CartRules.check(cart(), 2, "Waves", { x = 10 + r + 0.1, z = -20 }, 999, 1)), "far")
		T.eq(select(2, CartRules.check(cart(), 2, "Waves", { x = 200, z = 200 }, 999, 1)), "far")
		T.eq(select(2, CartRules.check(cart(), 2, "Waves", nil, 999, 1)), "far", "unknown position")
		local noPos = cart()
		noPos.x, noPos.z = nil, nil
		T.truthy(
			(CartRules.check(noPos, 2, "Waves", nil, 999, 1)),
			"a cart without a position skips the range"
		)
	end)
end)

return T.finish()
