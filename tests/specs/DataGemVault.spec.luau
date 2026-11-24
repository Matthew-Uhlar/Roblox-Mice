-- iter6 Gem Vault (team Gems): FeedGems / SalvageGems / LockGem rules (Data/Gems).
local T = require("../lib/Test")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local Gems = require("../../src/shared/Data/Gems")
local G = require("../../src/shared/Config/Gems")

local function profileWith(gems: { any }, equipped: { [string]: number }?, dust: number?): any
	local p = ProfileSchema.default() :: any
	p.level = 20
	p.gems = Gems.sanitize({ inv = gems, equipped = equipped or {}, dust = dust or 0, nextId = 1000 })
	return p
end

local function gem(id: number, t: number, lv: number?, u: string?, lk: boolean?): any
	return { id = id, t = t, s = { 30, 30, 30, 30, 30 }, lv = lv or 0, u = u, lk = lk }
end

local function ids(p: any): { [number]: boolean }
	local out = {}
	for _, g in p.gems.inv do
		out[g.id] = true
	end
	return out
end

T.describe("feedResult", function()
	T.it("buys levels in order and leaves the rest", function()
		-- tier 4: +1 costs 4, +2 costs 8, +3 costs 12
		local lv, spent, left = G.feedResult(4, 0, 15)
		T.eq(lv, 2)
		T.eq(spent, 12)
		T.eq(left, 3)
	end)
	T.it("stops at max level", function()
		local lv, spent, left = G.feedResult(2, 3, 1000)
		T.eq(lv, G.MAX_LEVEL)
		T.eq(spent, G.upgradeCost(2, 4) + G.upgradeCost(2, 5))
		T.eq(left, 1000 - spent)
	end)
end)

T.describe("Gems.feed", function()
	T.it("sacrifices fodder into the target and banks leftover dust", function()
		local p = profileWith({ gem(1, 4), gem(2, 6), gem(3, 6, 0, G.UNIQUE_ORDER[1]), gem(4, 1) }, nil, 5)
		-- fodder dust: 6 + 12 + 1 = 19 -> tier 4 target: +1 (4) +2 (8) = 12, left 7
		local ok, r = Gems.feed(p, 1, { 2, 3, 4 })
		T.truthy(ok)
		T.eq(r.level, 2)
		T.eq(r.levels, 2)
		T.eq(r.dust, 19)
		T.eq(r.leftover, 7)
		T.eq(p.gems.dust, 12)
		T.eq(#p.gems.inv, 1)
		T.eq(p.gems.inv[1].lv, 2)
	end)
	T.it("refuses the whole request on any bad fodder (atomic)", function()
		local base = { gem(1, 4), gem(2, 6), gem(3, 6, 0, nil, true), gem(4, 3), gem(5, 3) }
		local cases: { { any } } = {
			{ { 2, 3 }, "locked" },
			{ { 2, 4 }, "equipped" },
			{ { 2, 1 }, "self" },
			{ { 2, 99 }, "unknown_gem" },
			{ { 2, 2 }, "bad_ids" },
			{ { 2, 0 / 0 }, "bad_ids" },
			{ { 2, 2.5 }, "bad_ids" },
			{ { 2, -1 }, "bad_ids" },
			{ {}, "bad_ids" },
			{ { 2, "5" }, "bad_ids" },
			{ { [1] = 2, [3] = 5 }, "bad_ids" },
		}
		for _, c in cases do
			local p = profileWith(base, { ["1"] = 4 }, 10)
			local ok, why = Gems.feed(p, 1, c[1])
			T.eq(ok, false)
			T.eq(why, c[2])
			T.eq(#p.gems.inv, 5)
			T.eq(p.gems.dust, 10)
			T.eq(p.gems.inv[1].lv, 0)
		end
		local p = profileWith(base, nil, 0)
		local mixed: any = { 2 }
		mixed.x = 5
		T.eq(select(2, Gems.feed(p, 1, mixed)), "bad_ids")
		T.eq(select(2, Gems.feed(p, 1, "nope")), "bad_ids")
		T.eq(select(2, Gems.feed(p, 77, { 2 })), "unknown_gem")
	end)
	T.it("caps the request size and refuses a max-level target", function()
		local list = { gem(1, 1) }
		local fodder = {}
		for i = 2, G.FEED_MAX + 2 do
			table.insert(list, gem(i, 1))
			table.insert(fodder, i)
		end
		local p = profileWith(list)
		T.eq(select(2, Gems.feed(p, 1, fodder)), "bad_ids")
		table.remove(fodder)
		T.truthy((Gems.feed(p, 1, fodder)))
		local q = profileWith({ gem(1, 3, G.MAX_LEVEL), gem(2, 3) })
		T.eq(select(2, Gems.feed(q, 1, { 2 })), "gem_max")
	end)
	T.it("a replayed request cannot dupe dust", function()
		local p = profileWith({ gem(1, 12), gem(2, 12), gem(3, 12) })
		T.truthy((Gems.feed(p, 1, { 2, 3 })))
		local dust, lv = p.gems.dust, p.gems.inv[1].lv
		local ok, why = Gems.feed(p, 1, { 2, 3 })
		T.eq(ok, false)
		T.eq(why, "unknown_gem")
		T.eq(p.gems.dust, dust)
		T.eq(p.gems.inv[1].lv, lv)
	end)
end)

T.describe("Gems.salvageMany", function()
	T.it("salvages a selection atomically", function()
		local p = profileWith(
			{ gem(1, 4), gem(2, 6, 0, G.UNIQUE_ORDER[2]), gem(3, 2, 0, nil, true), gem(4, 5) },
			{
				["1"] = 4,
			}
		)
		T.eq(select(2, Gems.salvageMany(p, { 1, 3 })), "locked")
		T.eq(select(2, Gems.salvageMany(p, { 1, 4 })), "equipped")
		T.eq(#p.gems.inv, 4)
		local ok, r = Gems.salvageMany(p, { 1, 2 })
		T.truthy(ok)
		T.eq(r.dust, 4 + 12)
		T.eq(r.count, 2)
		T.eq(p.gems.dust, 16)
		local left = ids(p)
		T.truthy(left[3] and left[4] and not left[1] and not left[2])
		T.eq(select(2, Gems.salvageMany(p, { 1 })), "unknown_gem")
		local big = {}
		for i = 1, G.SALVAGE_MAX + 1 do
			big[i] = i
		end
		T.eq(select(2, Gems.salvageMany(p, big)), "bad_ids")
	end)
end)

T.describe("Gems.setLocked", function()
	T.it("toggles an additive flag that survives sanitize", function()
		local p = profileWith({ gem(1, 4) })
		T.eq(p.gems.inv[1].lk, nil)
		T.truthy((Gems.setLocked(p, 1, true)))
		T.eq(Gems.gemView(p.gems.inv[1]).locked, true)
		T.eq(select(2, Gems.salvage(p, 1)), "locked")
		local again = Gems.sanitize(p.gems)
		T.eq(again.inv[1].lk, true)
		T.truthy((Gems.setLocked(p, 1, false)))
		T.eq(p.gems.inv[1].lk, nil)
		T.eq(select(2, Gems.setLocked(p, 1, "yes")), "bad_flag")
		T.eq(select(2, Gems.setLocked(p, 9, true)), "unknown_gem")
		-- an old save (no lk) loads unlocked
		T.eq(Gems.sanitize({ inv = { gem(5, 3) } }).inv[1].lk, nil)
	end)
	T.it("power score", function()
		T.eq(G.power(4, { 30, 30, 30, 30, 30 }, 0, false), 150)
		T.eq(G.power(4, { 30, 30, 30, 30, 30 }, 2, true), 180 + G.RANGES[4][2])
	end)
end)

return T.finish()
