local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local UpgradeOffers = require("../../src/shared/Run/UpgradeOffers")
local Upgrades = require("../../src/shared/Config/Upgrades")

local function rarityShare(luck: number, n: number): { [string]: number }
	local rng = Rng.new(1234)
	local counts = { Common = 0, Rare = 0, Epic = 0, Legendary = 0 }
	for _ = 1, n do
		local cards = UpgradeOffers.roll(rng, "elephante", {}, luck, 1)
		counts[cards[1].rarity] += 1
	end
	for k, v in counts do
		counts[k] = v / n
	end
	return counts
end

T.describe("UpgradeOffers.rarityWeights", function()
	T.it("matches the GDD at luck 0", function()
		local w = UpgradeOffers.rarityWeights(0)
		T.eq(w.Common, 60)
		T.eq(w.Rare, 30)
		T.eq(w.Epic, 9)
		T.eq(w.Legendary, 1)
	end)
	T.it("luck shifts weight from Common to the rarer tiers", function()
		local base = UpgradeOffers.rarityWeights(0)
		local lucky = UpgradeOffers.rarityWeights(3)
		T.truthy(lucky.Common < base.Common)
		T.truthy(lucky.Rare > base.Rare)
		T.truthy(lucky.Epic > base.Epic)
		T.truthy(lucky.Legendary > base.Legendary)
		local unlucky = UpgradeOffers.rarityWeights(-3)
		T.truthy(unlucky.Common > base.Common)
		T.truthy(unlucky.Legendary < base.Legendary)
		for _, v in unlucky do
			T.truthy(v > 0)
		end
	end)
	T.it("nil and NaN luck mean 0", function()
		T.deepEq(UpgradeOffers.rarityWeights(nil), UpgradeOffers.rarityWeights(0))
		T.deepEq(UpgradeOffers.rarityWeights(0 / 0), UpgradeOffers.rarityWeights(0))
	end)
end)

T.describe("UpgradeOffers.roll", function()
	T.it("offers 3 unique cards by default", function()
		local rng = Rng.new(5)
		for _ = 1, 200 do
			local cards = UpgradeOffers.roll(rng, "elephante", {}, 0)
			T.eq(#cards, 3)
			T.truthy(cards[1].id ~= cards[2].id and cards[2].id ~= cards[3].id and cards[1].id ~= cards[3].id)
		end
	end)
	T.it("respects count", function()
		T.eq(#UpgradeOffers.roll(Rng.new(1), "elephante", {}, 0, 5), 5)
		T.eq(#UpgradeOffers.roll(Rng.new(1), "elephante", {}, 0, 0), 0)
	end)
	T.it("is deterministic for the same seed", function()
		local a = UpgradeOffers.roll(Rng.new(77), "filet", { twin_shot = 1 }, 1)
		local b = UpgradeOffers.roll(Rng.new(77), "filet", { twin_shot = 1 }, 1)
		for i = 1, 3 do
			T.eq(a[i].id, b[i].id)
		end
	end)
	T.it("rarity frequencies follow the weights", function()
		local share = rarityShare(0, 6000)
		T.truthy(share.Common > 0.55 and share.Common < 0.65, "common " .. share.Common)
		T.truthy(share.Rare > 0.26 and share.Rare < 0.34, "rare " .. share.Rare)
		T.truthy(share.Epic > 0.06 and share.Epic < 0.12, "epic " .. share.Epic)
		T.truthy(share.Legendary < 0.03, "legendary " .. share.Legendary)
	end)
	T.it("luck makes Epic and Legendary cards more common", function()
		local base = rarityShare(0, 4000)
		local lucky = rarityShare(5, 4000)
		T.truthy(lucky.Epic > base.Epic * 2)
		T.truthy(lucky.Legendary > base.Legendary * 2)
		T.truthy(lucky.Common < base.Common)
	end)
	T.it("never offers maxed upgrades", function()
		local stacks = {}
		for _, u in Upgrades.list do
			if u.rarity == "Common" then
				stacks[u.id] = u.maxStacks
			end
		end
		local rng = Rng.new(9)
		for _ = 1, 300 do
			for _, c in UpgradeOffers.roll(rng, "elephante", stacks, 0) do
				T.truthy(c.rarity ~= "Common", "offered maxed " .. c.id)
			end
		end
	end)
	T.it("never offers another class's class-only upgrade, but does offer your own", function()
		local rng = Rng.new(21)
		local sawOwn = false
		for _ = 1, 800 do
			for _, c in UpgradeOffers.roll(rng, "ellie_fawn", {}, 2) do
				T.truthy(c.classOnly == nil or c.classOnly == "ellie_fawn", "offered " .. c.id)
				if c.classOnly == "ellie_fawn" then
					sawOwn = true
				end
			end
		end
		T.truthy(sawOwn)
	end)
	T.it("returns fewer cards when the pool is nearly exhausted", function()
		local stacks = {}
		for _, u in Upgrades.list do
			stacks[u.id] = u.maxStacks
		end
		stacks.heavy_hitter = 0
		stacks.twin_shot = 0
		local cards = UpgradeOffers.roll(Rng.new(3), "elephante", stacks, 0)
		T.eq(#cards, 2)
		local ids = { cards[1].id, cards[2].id }
		table.sort(ids)
		T.deepEq(ids, { "heavy_hitter", "twin_shot" })
	end)
	T.it("returns an empty list when everything is maxed", function()
		local stacks = {}
		for _, u in Upgrades.list do
			stacks[u.id] = u.maxStacks
		end
		T.deepEq(UpgradeOffers.roll(Rng.new(3), "elephante", stacks, 0), {})
	end)
	T.it("falls back to other rarities when one is empty", function()
		local stacks = {}
		for _, u in Upgrades.list do
			if u.rarity ~= "Legendary" then
				stacks[u.id] = u.maxStacks
			end
		end
		local cards = UpgradeOffers.roll(Rng.new(8), "elephante", stacks, 0)
		T.eq(#cards, 3)
		for _, c in cards do
			T.eq(c.rarity, "Legendary")
		end
	end)
	T.it("eligible counts class-only upgrades per class", function()
		local generic = 0
		for _, u in Upgrades.list do
			if u.classOnly == nil then
				generic += 1
			end
		end
		T.truthy(#UpgradeOffers.eligible("ellie_fawn", {}) > generic)
		T.eq(#UpgradeOffers.eligible("unknown_class", {}), generic)
	end)
end)

return T.finish()
