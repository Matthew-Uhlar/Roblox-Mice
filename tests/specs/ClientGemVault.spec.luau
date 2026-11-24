-- iter6 Gem Vault (team Gems): client sorting, filtering and the sacrifice preview
-- (Util/GemVaultModel) against the server rules (Data/Gems.feed).
local T = require("../lib/Test")
local GemModel = require("../../src/client/Util/GemModel")
local V = require("../../src/client/Util/GemVaultModel")
local G = require("../../src/shared/Config/Gems")
local Gems = require("../../src/shared/Data/Gems")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")

local RAW = {
	{ id = 1, t = 4, s = { 20, 14, 30, 14, 14 }, lv = 1 },
	{ id = 2, t = 9, s = { 35, 90, 35, 35, 35 }, lv = 0, u = G.UNIQUE_ORDER[3] },
	{ id = 3, t = 2, s = { 22, 10, 10, 10, 10 }, lv = 0, lk = true },
	{ id = 4, t = 6, s = { 50, 50, 50, 50, 50 }, lv = 2 },
	{ id = 5, t = 1, s = { 10, 10, 10, 10, 20 }, lv = 0 },
	{ id = 6, t = 3, s = { 12, 12, 12, 12, 12 }, lv = 0 },
}

local function setup(): (any, { GemModel.Gem })
	local p = ProfileSchema.default() :: any
	p.level = 20
	p.gems = Gems.sanitize({ inv = RAW, equipped = { ["1"] = 4 }, dust = 7 })
	local gv = GemModel.view(Gems.view(p), p, G)
	return p, gv.inv
end

local function idsOf(list: { GemModel.Gem }): { number }
	local out = {}
	for _, g in list do
		table.insert(out, g.id)
	end
	return out
end

local function j(t: { number }): string
	return table.concat(t, ",")
end

local function byId(list: { GemModel.Gem }, id: number): GemModel.Gem
	for _, g in list do
		if g.id == id then
			return g
		end
	end
	error("no gem " .. id)
end

T.describe("Gem Vault sorting", function()
	T.it("tier, power, stat, newest, level", function()
		local _, inv = setup()
		T.eq(j(idsOf(V.sort(inv, "tier", G))), "2,4,1,6,3,5")
		T.eq(V.sort(inv, "power", G)[1].id, 2)
		T.eq(V.sort(inv, "bite", G)[1].id, 2)
		T.eq(V.sort(inv, "rinds", G)[1].id, 4)
		T.eq(V.sort(inv, "stride", G)[1].id, 4)
		T.eq(j(idsOf(V.sort(inv, "newest", G))), "6,5,4,3,2,1")
		T.eq(V.sort(inv, "level", G)[1].id, 4)
		-- the server power score reaches the client
		T.eq(byId(inv, 2).power, G.power(9, RAW[2].s, 0, true))
		T.eq(V.power(byId(inv, 2), G), V.power(byId(inv, 2), nil))
	end)
end)

T.describe("Gem Vault filters", function()
	T.it("tier range, unique, equipped, locked, unique type", function()
		local _, inv = setup()
		T.eq(#V.filter(inv, { minTier = 3, maxTier = 6 }), 3)
		T.eq(j(idsOf(V.filter(inv, { unique = "yes" }))), "2")
		T.eq(#V.filter(inv, { unique = "no" }), 5)
		T.eq(j(idsOf(V.filter(inv, { equipped = "yes" }))), "4")
		T.eq(j(idsOf(V.filter(inv, { locked = "yes" }))), "3")
		T.eq(j(idsOf(V.filter(inv, { uniqueId = G.UNIQUE_ORDER[3] }))), "2")
		T.eq(#V.filter(inv, nil), 6)
		T.eq(byId(inv, 3).locked, true)
	end)
	T.it("stat bar quality against the tier range", function()
		local _, inv = setup()
		T.eq(V.quality(byId(inv, 2), "bite", G), 1)
		T.eq(V.quality(byId(inv, 2), "rinds", G), 0)
		T.near(V.quality(byId(inv, 1), "hide", G), 1, 1e-9)
	end)
end)

T.describe("Gem Vault sacrifice", function()
	T.it("quick selections skip the target, equipped and locked gems", function()
		local _, inv = setup()
		local below = V.selectBelowTier(inv, 5, 1, nil, G)
		table.sort(below)
		T.eq(j(below), "5,6") -- 3 locked, 1 target
		local lower = V.selectLowerPower(inv, byId(inv, 2), nil, G)
		table.sort(lower)
		T.eq(j(lower), "1,5,6") -- 4 equipped, 3 locked
		T.eq(#V.selectBelowTier(inv, 13, nil, 1, G), 1)
	end)
	T.it("the preview matches the server feed exactly", function()
		local cases = { { 1, { 5, 6 } }, { 2, { 1, 5, 6 } }, { 6, { 5 } }, { 5, { 1, 2, 6 } } }
		for _, c in cases do
			local p, inv = setup()
			local fodder = {}
			for _, id in c[2] do
				table.insert(fodder, byId(inv, id))
			end
			local target = byId(inv, c[1])
			local pv = V.feedPreview(target, fodder, G)
			T.truthy(pv.ok)
			local ok, r = Gems.feed(p, c[1], c[2])
			T.truthy(ok)
			T.eq(pv.level, r.level)
			T.eq(pv.dust, r.dust)
			T.eq(pv.spent, r.spent)
			T.eq(pv.leftover, r.leftover)
			T.eq(p.gems.dust, 7 + pv.leftover)
			-- stats after the feed match the server view
			local after = GemModel.view(Gems.view(p), p, G)
			local t2 = byId(after.inv, c[1])
			for _, k in GemModel.STATS do
				T.near(pv.values[k], GemModel.statValue(t2, k, G), 1e-9)
			end
			T.eq(pv.power, t2.power)
			-- the fallback maths (no cfg) agree too
			local lv, spent, left = V.feedResult(target.tier, target.level, pv.dust, nil)
			T.eq(lv, pv.level)
			T.eq(spent, pv.spent)
			T.eq(left, pv.leftover)
		end
	end)
	T.it("flags bad picks like the server", function()
		local _, inv = setup()
		T.eq(V.feedPreview(byId(inv, 1), { byId(inv, 3) }, G).reason, "locked")
		T.eq(V.feedPreview(byId(inv, 1), { byId(inv, 4) }, G).reason, "equipped")
		T.eq(V.feedPreview(byId(inv, 1), {}, G).reason, "none")
		T.eq(V.salvageTotal({ byId(inv, 2), byId(inv, 5) }), 18 + 1)
		local d = V.compare(byId(inv, 2), byId(inv, 4), G)
		T.truthy(d.bite > 0 and d.rinds < 0)
	end)
end)

return T.finish()
