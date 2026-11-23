--!strict
-- Data/LifetimeStats (iter 5 #8 time played + lifetime stats, #6 the Overtime record):
-- additive profile fields, run accounting, the ProfileView card.
local T = require("../lib/Test")
local LifetimeStats = require("../../src/shared/Data/LifetimeStats")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")

local function fresh(): any
	return ProfileSchema.default()
end

local function someClass(p: any): string
	for id in p.classes do
		return id
	end
	error("no class")
end

T.describe("Data/LifetimeStats", function()
	T.it("new profiles start at zero; old saves gain the fields (additive)", function()
		local p = fresh()
		T.eq(p.stats.seconds, 0)
		T.eq(p.stats.damage, 0)
		T.eq(next(p.stats.overtimeBest), nil)
		local old = ProfileSchema.migrate({ version = 7, stats = { runs = 5, stomps = 40 } })
		T.eq(old.stats.seconds, 0)
		T.eq(old.stats.damage, 0)
		T.eq(type(old.stats.clears), "table")
		T.eq(old.stats.stomps, 40, "existing totals kept")
	end)

	T.it("applyRun adds time (account + class), damage, clears and the Overtime best", function()
		local p = fresh()
		local cid = someClass(p)
		local r = LifetimeStats.applyRun(p, {
			seconds = 600.7,
			damage = 12345.6,
			classId = cid,
			tier = 3,
			clear = true,
			overtimeWaves = 4,
		})
		T.eq(p.stats.seconds, 600)
		T.eq(p.stats.damage, 12345)
		T.eq(p.classes[cid].seconds, 600)
		T.eq(p.stats.clears["3"], 1)
		T.eq(p.stats.overtimeBest["3"], 4)
		T.eq(r.overtimeBest, 4, "a new record")
		r = LifetimeStats.applyRun(
			p,
			{ seconds = 60, classId = cid, tier = 3, clear = true, overtimeWaves = 2 }
		)
		T.eq(r.overtimeBest, nil, "not a record")
		T.eq(p.stats.overtimeBest["3"], 4)
		T.eq(p.stats.clears["3"], 2)
		T.eq(p.classes[cid].seconds, 660)
		T.eq(LifetimeStats.bestOvertime(p), 4)
	end)

	T.it("garbage and Custom runs record nothing bad", function()
		local p = fresh()
		LifetimeStats.applyRun(p, { seconds = 0 / 0, damage = -5, tier = 0, clear = true, overtimeWaves = 3 })
		T.eq(p.stats.seconds, 0)
		T.eq(p.stats.damage, 0)
		T.eq(next(p.stats.clears), nil, "Custom (tier 0): no tier entries")
		T.eq(next(p.stats.overtimeBest), nil)
		LifetimeStats.applyRun(p, { seconds = 1e12, tier = 99 })
		T.eq(p.stats.seconds, LifetimeStats.MAX_RUN_SECONDS, "one run is capped")
		LifetimeStats.applyRun(p, { classId = "notAClass", seconds = 5 })
		T.eq(p.stats.seconds, LifetimeStats.MAX_RUN_SECONDS + 5)
	end)

	T.it("reconcile keeps valid values, drops junk, keeps tier maps DataStore-safe", function()
		local base = fresh()
		local cid = someClass(base)
		local raw = ProfileSchema.deepCopy(base)
		raw.stats.seconds = 900
		raw.stats.damage = "lots"
		raw.stats.overtimeBest = { ["2"] = 7, [5] = 3, x = 9, ["12"] = 4, ["4"] = -1 }
		raw.stats.clears = { ["1"] = 2.9 }
		raw.classes[cid].seconds = 120
		local p = ProfileSchema.migrate(raw)
		T.eq(p.stats.seconds, 900)
		T.eq(p.stats.damage, 0)
		T.eq(p.stats.overtimeBest["2"], 7)
		T.eq(p.stats.overtimeBest["5"], 3, "number keys become strings")
		T.eq(p.stats.overtimeBest.x, nil)
		T.eq(p.stats.overtimeBest["12"], nil)
		T.eq(p.stats.overtimeBest["4"], nil)
		T.eq(p.stats.clears["1"], 2)
		T.eq(p.classes[cid].seconds, 120)
		for k in p.stats.overtimeBest do
			T.eq(type(k), "string")
		end
	end)

	T.it("the ProfileView carries the lifetime card and per-class seconds", function()
		local p = fresh()
		local cid = someClass(p)
		p.stats.stomps = 77
		LifetimeStats.applyRun(
			p,
			{ seconds = 300, damage = 999, classId = cid, tier = 5, clear = true, overtimeWaves = 6 }
		)
		local v = ProfileSchema.view(p)
		T.eq(v.lifetime.seconds, 300)
		T.eq(v.lifetime.damage, 999)
		T.eq(v.lifetime.stomps, 77)
		T.eq(v.lifetime.overtimeBest["5"], 6)
		T.eq(v.lifetime.overtimeBestAny, 6)
		T.eq(v.lifetime.clears["5"], 1)
		T.eq(v.lifetime.classSeconds[cid], 300)
		T.eq(v.classes[cid].seconds, 300)
		T.eq(v.stats.seconds, 300, "stats copy too")
	end)
end)

T.describe("ProfileSchema v8 (iteration 5)", function()
	T.it("v7 saves migrate to v8 with the new fields; nothing else changes", function()
		local p, info = ProfileSchema.migrate({ version = 7, cheese = 55, stats = { runs = 3, stomps = 9 } })
		T.eq(ProfileSchema.VERSION, 8)
		T.eq(p.version, 8)
		T.eq(info.fromVersion, 7)
		T.eq(info.futureVersion, false)
		T.eq(p.cheese, 55)
		T.eq(p.stats.stomps, 9)
		T.eq(p.stats.seconds, 0)
	end)
	T.it("a save from a newer server opens read-only and keeps unknown fields in memory", function()
		local raw = ProfileSchema.deepCopy(ProfileSchema.default())
		raw.version = 9
		raw.stats.seconds = 77
		local p, info = ProfileSchema.migrate(raw)
		T.eq(info.futureVersion, true)
		T.eq(ProfileSchema.sessionMode(raw, info), "readOnly", "never saved over")
		T.eq(p.stats.seconds, 77)
	end)
	T.it("a v7 server would open a v8 save read-only (the futureVersion path)", function()
		-- simulate the old server: its VERSION is 7, the save is 8
		local old = ProfileSchema.VERSION
		ProfileSchema.VERSION = 7
		local raw = ProfileSchema.deepCopy(ProfileSchema.default())
		raw.version = 8
		local ok, p, info = pcall(ProfileSchema.migrate, raw)
		ProfileSchema.VERSION = old
		T.truthy(ok, tostring(p))
		T.eq(info.futureVersion, true)
		T.eq(ProfileSchema.sessionMode(raw, info), "readOnly")
	end)
end)

return T.finish()
