local T = require("../lib/Test")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local Passes = require("../../src/shared/Data/Passes")
local Receipts = require("../../src/shared/Data/Receipts")
local ShopConfig = require("../../src/shared/Config/Shop")

-- QC2 M5: pass perks record their source and can be revoked when Roblox says the
-- pass is no longer owned (refund / chargeback).

T.describe("Passes.apply", function()
	T.it("records the source of every pass cosmetic", function()
		local p = ProfileSchema.default()
		T.truthy(Passes.apply(p, "vip"))
		local g = Passes.grants(p).vip
		T.truthy(g.cosmetics.hat_vip_crown and g.cosmetics.trail_golden_tusk)
		T.falsy(Passes.apply(p, "vip"), "idempotent")
	end)
	T.it("Founders records only classes that were still locked", function()
		local p = ProfileSchema.default()
		p.unlockedClasses.jumbo = true -- bought with cheese earlier
		Passes.apply(p, "founders")
		local g = Passes.grants(p).founders
		T.eq(g.classes.jumbo, nil, "a cheese purchase is never attributed to the pass")
		for _, free in ShopConfig.freeClassIds() do
			T.eq(g.classes[free], nil, "free classes are not pass grants")
		end
		for _, id in ShopConfig.classIds() do
			T.truthy(p.unlockedClasses[id], id)
		end
	end)
	T.it("records a cosmetic the profile already had from the same pass (pre-tracking saves)", function()
		local p = ProfileSchema.default()
		p.cosmetics.hat_viking = true
		Passes.apply(p, "wardrobe")
		T.truthy(Passes.grants(p).wardrobe.cosmetics.hat_viking)
	end)
	T.it("ignores products and unknown keys", function()
		local p = ProfileSchema.default()
		T.falsy(Passes.apply(p, "golden_xs"))
		T.falsy(Passes.apply(p, "nope"))
		T.deepEq(Passes.grants(p), {})
	end)
	T.it("Receipts.applyPass goes through the tracked path", function()
		local p = ProfileSchema.default()
		Receipts.applyPass(p, "founders")
		T.truthy(Passes.grants(p).founders.cosmetics.hat_founder)
	end)
end)

T.describe("Passes.revoke", function()
	T.it("removes the pass's cosmetics and unequips them", function()
		local p = ProfileSchema.default()
		Passes.apply(p, "vip")
		p.cosmetics.hat_party = true
		p.equipped.hat = "hat_vip_crown"
		p.equipped.trail = "trail_golden_tusk"
		local r = Passes.revoke(p, "vip")
		T.deepEq(r.cosmetics, { "hat_vip_crown", "trail_golden_tusk" })
		T.eq(p.cosmetics.hat_vip_crown, nil)
		T.eq(p.equipped.hat, nil)
		T.eq(p.equipped.trail, nil)
		T.truthy(p.cosmetics.hat_party, "other cosmetics stay")
		T.eq(Passes.grants(p).vip, nil, "record cleared")
	end)
	T.it("removes Founders classes but keeps cheese-bought and free ones, and fixes the selection", function()
		local p = ProfileSchema.default()
		p.unlockedClasses.jumbo = true
		Passes.apply(p, "founders")
		local granted = {}
		for id in Passes.grants(p).founders.classes do
			table.insert(granted, id)
		end
		T.truthy(#granted > 0)
		p.selectedClass = granted[1]
		local r = Passes.revoke(p, "founders")
		T.eq(#r.classes, #granted)
		T.truthy(p.unlockedClasses.jumbo, "cheese purchase kept")
		for _, free in ShopConfig.freeClassIds() do
			T.truthy(p.unlockedClasses[free], free)
		end
		T.truthy(p.unlockedClasses[p.selectedClass], "selection moved to an unlocked class")
		T.eq(p.cosmetics.hat_founder, nil)
	end)
	T.it("does nothing without a record", function()
		local p = ProfileSchema.default()
		p.cosmetics.hat_vip_crown = true -- untracked: nothing to revoke
		local before = ProfileSchema.deepCopy(p)
		local r = Passes.revoke(p, "vip")
		T.eq(#r.cosmetics + #r.classes, 0)
		T.deepEq(p, before)
	end)
	T.it("survives a save/load round trip and still revokes", function()
		local p = ProfileSchema.default()
		Passes.apply(p, "wardrobe")
		local loaded = ProfileSchema.migrate(ProfileSchema.deepCopy(p))
		T.deepEq(Passes.recordedKeys(loaded), { "wardrobe" })
		local r = Passes.revoke(loaded, "wardrobe")
		T.eq(#r.cosmetics, 6)
		local again = ProfileSchema.migrate(ProfileSchema.deepCopy(loaded))
		T.deepEq(Passes.recordedKeys(again), {})
	end)
end)

return T.finish()
