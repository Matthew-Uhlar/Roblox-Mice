--!strict
-- Shop Cart purchase rules (GDD-v2 §4, QC-A M3, QC-B V2-m3). Pure: RunDirector
-- calls CartRules.check before it takes the item from the World's stock.
--
-- Owner decision: the cart charges the buyer's OWN pending share (never the
-- squad pot, never Robux). A buy also needs:
--   * the cart opened by the buyer's squad;
--   * the item not bought yet (`cart.bought[index]`);
--   * the Waves phase (the cart closes at the boss);
--   * the buyer standing within CartRules.RANGE studs of the cart.

local CartRules = {}

CartRules.RANGE = 14

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- cart = {offers, prices, squad, bought, x?, z?}; pos = {x, z} (World state) or
-- nil when unknown. Returns ok, reason ("no_cart" | "sold" | "phase" | "far" |
-- "funds"), and the price.
function CartRules.check(
	cart: any,
	squad: any,
	phase: any,
	pos: any,
	share: any,
	index: any
): (boolean, string?, number?)
	if type(cart) ~= "table" or cart.squad ~= squad then
		return false, "no_cart", nil
	end
	local item = if type(cart.offers) == "table" then cart.offers[index] else nil
	local price = if type(cart.prices) == "table" then cart.prices[index] else nil
	if item == nil or not finite(price) or (type(cart.bought) == "table" and cart.bought[index]) then
		return false, "sold", nil
	end
	if phase ~= "Waves" then
		return false, "phase", price
	end
	if finite(cart.x) and finite(cart.z) then
		if type(pos) ~= "table" or not finite(pos.x) or not finite(pos.z) then
			return false, "far", price
		end
		local r = CartRules.RANGE
		if (pos.x - cart.x) ^ 2 + (pos.z - cart.z) ^ 2 > r * r then
			return false, "far", price
		end
	end
	if not finite(share) or share < price then
		return false, "funds", price
	end
	return true, nil, price
end

return CartRules
