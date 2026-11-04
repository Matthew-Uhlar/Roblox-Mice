local T = require("../lib/Test")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local Award = require("../../src/shared/Data/Award")

T.describe("ProfileSchema.default", function()
	T.it("has the current version and starter classes", function()
		local p = ProfileSchema.default()
		T.eq(p.version, ProfileSchema.VERSION)
		T.eq(p.cheese, 0)
		T.eq(p.goldenCheese, 0)
		T.eq(p.level, 1)
		T.truthy(p.unlockedClasses[p.selectedClass], "selected class is unlocked")
		T.truthy(p.unlockedClasses.elephante)
		T.falsy(p.unlockedClasses.jumbo, "paid classes start locked")
	end)
	T.it("returns fresh tables each call", function()
		local a, b = ProfileSchema.default(), ProfileSchema.default()
		a.cosmetics.x = true
		T.eq(b.cosmetics.x, nil)
	end)
	T.it("round-trips through migrate unchanged", function()
		local p = ProfileSchema.default()
		local m = ProfileSchema.migrate(ProfileSchema.deepCopy(p))
		T.deepEq(m, p)
	end)
end)

T.describe("ProfileSchema.migrate", function()
	T.it("turns nil and garbage into a default profile", function()
		for _, raw in { nil, 5, "hello", true } do
			local p, info = ProfileSchema.migrate(raw)
			T.eq(p.version, ProfileSchema.VERSION)
			T.truthy(info.fresh)
		end
	end)
	T.it("migrates a v1 profile and keeps its data", function()
		local v1 = {
			version = 1,
			cheese = 1234,
			xp = 50,
			level = 3,
			unlockedClasses = { elephante = true, jumbo = true },
			selectedClass = "jumbo",
			talents = { thick_hide = 2 },
			cosmetics = { hat_party = true },
			equipped = { hat = "hat_party" },
			secondWindTokens = 2,
			rerollTokens = 4,
			daily = { lastClaimDay = 100, streak = 3 },
			stats = { runs = 10, wins = 2, deepestCycle = 3, bossesKilled = 20, fastestCycle1 = 900 },
			purchaseHistory = { a = true, b = true },
			boosts = { cheese2xUntil = 0 },
			settings = { music = false },
		}
		local p, info = ProfileSchema.migrate(v1)
		T.eq(info.fromVersion, 1)
		T.falsy(info.futureVersion)
		T.eq(p.version, ProfileSchema.VERSION)
		T.eq(p.cheese, 1234)
		T.eq(p.goldenCheese, 0)
		T.eq(p.selectedClass, "jumbo")
		T.eq(p.talents.thick_hide, 2)
		T.eq(p.equipped.hat, "hat_party")
		T.eq(p.stats.ranked.wins, 2)
		T.eq(p.stats.ranked.deepestCycle, 3)
		T.eq(p.stats.ranked.fastestCycle1, 900)
		T.truthy(p.purchaseHistory.a and p.purchaseHistory.b)
		T.eq(#p.purchaseOrder, 2)
		T.eq(p.boosts.feastPending, 0)
		T.eq(p.settings.music, false)
		T.truthy(p.unlockedClasses.ele_fonte, "free classes are re-added")
	end)
	T.it("treats a missing version as v1", function()
		local p, info = ProfileSchema.migrate({ cheese = 7 })
		T.eq(info.fromVersion, 1)
		T.eq(p.cheese, 7)
	end)
	T.it("repairs wrong types, NaN, inf and negatives", function()
		local p = ProfileSchema.migrate({
			version = 2,
			cheese = 0 / 0,
			goldenCheese = -50,
			xp = math.huge,
			level = "ten",
			unlockedClasses = "all",
			selectedClass = { 1 },
			talents = { thick_hide = 99, heavy_trunk = -1, bogus = 0 / 0, [5] = 1 },
			cosmetics = { hat_party = "yes", trail_crumbs = true },
			equipped = { hat = "trail_crumbs", trail = "trail_crumbs", tint = "tint_nope" },
			secondWindTokens = 2.7,
			daily = 3,
			stats = { runs = -4, ranked = "x" },
			purchaseHistory = { [1] = true, ok = true },
			purchaseOrder = { 1, 2, "ok", "ok" },
			settings = { [1] = 2, big = string.rep("a", 100), fine = 3 },
		})
		T.eq(p.cheese, 0)
		T.eq(p.goldenCheese, 0)
		T.eq(p.level, 1)
		T.eq(p.selectedClass, "elephante")
		T.eq(p.talents.thick_hide, 5, "clamped to maxLevel")
		T.eq(p.talents.heavy_trunk, nil)
		T.eq(p.talents.bogus, nil)
		T.eq(p.cosmetics.hat_party, nil)
		T.truthy(p.cosmetics.trail_crumbs)
		T.eq(p.equipped.hat, nil, "wrong slot dropped")
		T.eq(p.equipped.trail, "trail_crumbs")
		T.eq(p.equipped.tint, nil)
		T.eq(p.secondWindTokens, 2)
		T.eq(p.daily.streak, 0)
		T.eq(p.stats.runs, 0)
		T.eq(p.stats.ranked.wins, 0)
		T.deepEq(p.purchaseOrder, { "ok" })
		T.eq(p.settings.big, nil)
		T.eq(p.settings.fine, 3)
	end)
	T.it("drops a selected class that isn't unlocked", function()
		local p = ProfileSchema.migrate({ version = 2, selectedClass = "jumbo", unlockedClasses = {} })
		T.eq(p.selectedClass, "elephante")
	end)
	T.it("flags profiles saved by a newer server", function()
		local p, info = ProfileSchema.migrate({ version = 99, cheese = 5 })
		T.truthy(info.futureVersion)
		T.eq(p.cheese, 5)
	end)
	T.it("does not mutate the raw table's version on migrate", function()
		local raw = { version = 1, cheese = 1 }
		ProfileSchema.migrate(raw)
		T.eq(raw.version, 1)
	end)
	T.it("prunes an oversized purchase history to the cap", function()
		local order = {}
		for i = 1, 300 do
			order[i] = "p" .. i
		end
		local p = ProfileSchema.migrate({ version = 2, purchaseOrder = order })
		T.eq(#p.purchaseOrder, 200)
		T.eq(p.purchaseOrder[1], "p101")
		T.truthy(p.purchaseHistory.p300)
		T.eq(p.purchaseHistory.p1, nil)
	end)
end)

T.describe("ProfileSchema: unreadable saves are never treated as fresh (QC2 M6)", function()
	local function withBrokenReconcile(fn: () -> ())
		local original = ProfileSchema.reconcile
		ProfileSchema.reconcile = function(_raw: any): any
			error("reconcile exploded")
		end
		local ok, err = pcall(fn)
		ProfileSchema.reconcile = original
		if not ok then
			error(err, 0)
		end
	end
	T.it("a reconcile error on a non-empty save is 'failed' and opens a corrupt (no-save) session", function()
		withBrokenReconcile(function()
			local raw = { version = 2, cheese = 5000, cosmetics = { hat_party = true } }
			local p, info = ProfileSchema.migrate(raw)
			T.truthy(info.failed, "failed flag")
			T.falsy(info.fresh, "not fresh")
			T.truthy(type(info.error) == "string" and string.find(info.error, "reconcile") ~= nil)
			T.eq(ProfileSchema.sessionMode(raw, info), "corrupt")
			T.eq(p.cheese, 0, "the placeholder profile is blank, which is why it must never be saved")
			T.eq(raw.cheese, 5000, "raw data untouched")
		end)
	end)
	T.it("a reconcile error on a future-version save is also corrupt", function()
		withBrokenReconcile(function()
			local raw = { version = 99, cheese = 1 }
			local _, info = ProfileSchema.migrate(raw)
			T.truthy(info.failed)
			T.eq(ProfileSchema.sessionMode(raw, info), "corrupt")
		end)
	end)
	T.it("a throwing migration step is corrupt, not a half-migrated profile", function()
		local original = ProfileSchema.MIGRATIONS[1]
		ProfileSchema.MIGRATIONS[1] = function(_raw: any)
			error("step exploded")
		end
		local raw = { version = 1, cheese = 77 }
		local ok, p, info = pcall(ProfileSchema.migrate, raw)
		ProfileSchema.MIGRATIONS[1] = original
		T.truthy(ok, "migrate never throws")
		T.truthy(info.failed)
		T.eq(ProfileSchema.sessionMode(raw, info), "corrupt")
		T.eq(p.version, ProfileSchema.VERSION)
	end)
	T.it("no save at all is a writable fresh profile", function()
		withBrokenReconcile(function()
			local _, info = ProfileSchema.migrate(nil)
			T.truthy(info.fresh)
			T.falsy(info.failed)
			T.eq(ProfileSchema.sessionMode(nil, info), "writable")
		end)
		-- an empty table is not data either
		withBrokenReconcile(function()
			local raw = {}
			local _, info = ProfileSchema.migrate(raw)
			T.falsy(info.failed)
			T.eq(ProfileSchema.sessionMode(raw, info), "writable")
		end)
	end)
	T.it("a healthy save is writable and a newer-version save is read-only", function()
		local raw = { version = ProfileSchema.VERSION, cheese = 3 }
		local _, info = ProfileSchema.migrate(raw)
		T.eq(ProfileSchema.sessionMode(raw, info), "writable")
		local future = { version = ProfileSchema.VERSION + 1, cheese = 3 }
		local _, finfo = ProfileSchema.migrate(future)
		T.eq(ProfileSchema.sessionMode(future, finfo), "readOnly")
	end)
	T.it("a blank profile for a non-empty save is corrupt even without the failed flag", function()
		local raw = { version = 2, cheese = 10 }
		T.eq(
			ProfileSchema.sessionMode(
				raw,
				{ fromVersion = 2, futureVersion = false, fresh = true, failed = false }
			),
			"corrupt"
		)
	end)
end)

T.describe("ProfileSchema v3: pass grant sources", function()
	T.it("v2 -> v3 records owned pass cosmetics under their pass, but not class unlocks", function()
		local p = ProfileSchema.migrate({
			version = 2,
			cosmetics = { hat_vip_crown = true, trail_golden_tusk = true, hat_party = true, tint_lava = true },
			unlockedClasses = { elephante = true, jumbo = true },
		})
		local g = (p :: any).passGrants
		T.truthy(g.vip and g.vip.cosmetics.hat_vip_crown and g.vip.cosmetics.trail_golden_tusk)
		T.truthy(g.wardrobe and g.wardrobe.cosmetics.tint_lava)
		T.eq(g.founders, nil, "class unlocks can't be attributed, so they are never revocable")
		T.eq(g.vip.cosmetics.hat_party, nil, "shop cosmetics are not pass grants")
	end)
	T.it("sanitises saved grants: unknown passes, unowned ids and junk are dropped", function()
		local p = ProfileSchema.migrate({
			version = 3,
			cosmetics = { hat_vip_crown = true },
			unlockedClasses = { jumbo = true },
			passGrants = {
				vip = { cosmetics = { hat_vip_crown = true, trail_golden_tusk = true }, classes = 5 },
				founders = { classes = { jumbo = true, nope = true } },
				golden_xs = { cosmetics = { hat_vip_crown = true } },
				bogus = "x",
			},
		})
		local g = (p :: any).passGrants
		T.truthy(g.vip.cosmetics.hat_vip_crown)
		T.eq(g.vip.cosmetics.trail_golden_tusk, nil, "not owned any more")
		T.truthy(g.founders.classes.jumbo)
		T.eq(g.founders.classes.nope, nil)
		T.eq(g.golden_xs, nil, "products don't hold grants")
		T.eq(g.bogus, nil)
	end)
end)

T.describe("ProfileSchema.view", function()
	T.it("hides purchase internals and copies tables", function()
		local p = ProfileSchema.default()
		p.purchaseHistory.secret = true
		table.insert(p.purchaseOrder, "secret")
		local v = ProfileSchema.view(p, { today = 5, now = 100 })
		T.eq(v.purchaseHistory, nil)
		T.eq(v.purchaseOrder, nil)
		T.eq(v.ads, nil)
		T.eq(v.club, nil)
		T.eq(v.passGrants, nil)
		T.eq(v.daily.claimable, true)
		T.eq(v.xpToNext, Award.xpToNext(1))
		v.cosmetics.hacked = true
		T.eq(p.cosmetics.hacked, nil)
	end)
end)

T.describe("Award", function()
	T.it("levels up and grants level cosmetics", function()
		local p = ProfileSchema.default()
		local total = 0
		for lv = 1, 4 do
			total += Award.xpToNext(lv)
		end
		local r = Award.addXp(p, total + 10)
		T.eq(p.level, 5)
		T.eq(p.xp, 10)
		T.eq(r.levelsGained, 4)
		T.truthy(p.cosmetics.hat_cheese_wedge)
	end)
	T.it("applies a run: stats, ranked stats and the first-run bonus", function()
		local p = ProfileSchema.default()
		local r = Award.applyRun(p, {
			cheese = 300,
			xp = 0,
			won = true,
			cycle = 2,
			bosses = 4,
			cycle1Time = 1200,
			ranked = true,
			day = 10,
		})
		T.eq(r.firstRunBonus, 300)
		T.eq(p.cheese, 600)
		T.eq(p.stats.wins, 1)
		T.eq(p.stats.ranked.deepestCycle, 2)
		T.eq(p.stats.fastestCycle1, 1200)
		T.eq(p.lastRun.cheese, 300)
		T.falsy(p.lastRun.adClaimed)
		local r2 = Award.applyRun(p, {
			cheese = 300,
			xp = 0,
			won = true,
			cycle = 5,
			bosses = 1,
			cycle1Time = 1000,
			ranked = false,
			day = 10,
		})
		T.eq(r2.firstRunBonus, 0, "once per day")
		T.eq(p.stats.deepestCycle, 5)
		T.eq(p.stats.ranked.deepestCycle, 2, "unranked run not counted")
		T.eq(p.stats.ranked.wins, 1)
		T.eq(p.stats.fastestCycle1, 1000)
		T.eq(p.stats.ranked.fastestCycle1, 1200)
	end)
	T.it("ignores NaN and negative awards", function()
		local p = ProfileSchema.default()
		Award.applyRun(p, { cheese = 0 / 0, xp = -5, won = false, cycle = -1, bosses = 0 / 0, ranked = true })
		T.eq(p.cheese, 0)
		T.eq(p.xp, 0)
		T.eq(p.stats.deepestCycle, 0)
		T.eq(p.stats.bossesKilled, 0)
	end)
end)

T.describe("ProfileSchema v4: Pressure + discoveries", function()
	local function v3Save(): { [string]: any }
		return {
			version = 3,
			cheese = 4321,
			goldenCheese = 12,
			xp = 77,
			level = 6,
			unlockedClasses = { elephante = true, jumbo = true },
			selectedClass = "jumbo",
			talents = { thick_hide = 2 },
			cosmetics = { hat_party = true, hat_vip_crown = true },
			equipped = { hat = "hat_party" },
			secondWindTokens = 3,
			rerollTokens = 5,
			daily = { lastClaimDay = 200, streak = 4 },
			stats = {
				runs = 30,
				wins = 7,
				deepestCycle = 4,
				bossesKilled = 90,
				fastestCycle1 = 840,
				ranked = { wins = 6, deepestCycle = 3, fastestCycle1 = 900 },
			},
			purchaseHistory = { r1 = true, r2 = true },
			purchaseOrder = { "r1", "r2" },
			boosts = { cheese2xUntil = 5000, feastPending = 1 },
			club = { lastDailyDay = 199, monthsGranted = { ["2026-10"] = true } },
			ads = { day = 200, count = 2 },
			lastRun = { cheese = 400, adClaimed = false },
			firstRunDay = 200,
			settings = { hints = false },
			passGrants = { vip = { cosmetics = { hat_vip_crown = true }, classes = {} } },
		}
	end

	T.it("defaults: locked board, nothing cleared, no discoveries", function()
		local p = ProfileSchema.default()
		T.truthy(ProfileSchema.VERSION >= 4)
		T.deepEq(p.pressure, { unlocked = false, highestCleared = 0, board = {} })
		T.deepEq(p.discoveries, {})
	end)

	T.it("v3 -> v4 adds pressure and discoveries and keeps every v3 field", function()
		local raw = v3Save()
		local p, info = ProfileSchema.migrate(raw)
		T.eq(info.fromVersion, 3)
		T.falsy(info.failed)
		T.eq(ProfileSchema.sessionMode(raw, info), "writable")
		T.eq(p.version, ProfileSchema.VERSION)
		-- this v3 save has 7 wins, so the veteran rule unlocks the board
		T.deepEq(p.pressure, { unlocked = true, highestCleared = 0, board = {} })
		T.deepEq(p.discoveries, {})
		-- every v3 field survives
		T.eq(p.cheese, 4321)
		T.eq(p.goldenCheese, 12)
		T.eq(p.xp, 77)
		T.eq(p.level, 6)
		T.truthy(p.unlockedClasses.jumbo)
		T.eq(p.selectedClass, "jumbo")
		T.eq(p.talents.thick_hide, 2)
		T.truthy(p.cosmetics.hat_party and p.cosmetics.hat_vip_crown)
		T.eq(p.equipped.hat, "hat_party")
		T.eq(p.secondWindTokens, 3)
		T.eq(p.rerollTokens, 5)
		T.deepEq(p.daily, { lastClaimDay = 200, streak = 4 })
		for k, v in raw.stats do
			if k ~= "ranked" then
				T.eq((p.stats :: any)[k], v, "stats." .. k)
			end
		end
		for k, v in raw.stats.ranked or {} do
			T.eq((p.stats.ranked :: any)[k], v, "stats.ranked." .. k)
		end
		T.deepEq(p.purchaseOrder, { "r1", "r2" })
		T.truthy(p.purchaseHistory.r1 and p.purchaseHistory.r2)
		T.deepEq(p.boosts, { cheese2xUntil = 5000, feastPending = 1 })
		T.eq(p.club.lastDailyDay, 199)
		T.truthy(p.club.monthsGranted["2026-10"])
		T.deepEq(p.ads, { day = 200, count = 2 })
		T.deepEq(p.lastRun, { cheese = 400, adClaimed = false })
		T.eq(p.firstRunDay, 200)
		T.eq(p.settings.hints, false)
		T.truthy((p :: any).passGrants.vip.cosmetics.hat_vip_crown)
		T.eq(raw.version, 3, "the caller's table is not mutated")
		T.eq(raw.pressure, nil)
	end)

	T.it("v3 -> v4 unlocks Pressure for veterans who already won a run", function()
		local raw = v3Save()
		raw.stats = raw.stats or {}
		raw.stats.wins = 2
		local p = ProfileSchema.migrate(raw)
		T.truthy(p.pressure.unlocked, "veteran unlocked")
		T.eq(p.pressure.highestCleared, 0)
		local fresh = v3Save()
		fresh.stats = fresh.stats or {}
		fresh.stats.wins = 0
		T.falsy(ProfileSchema.migrate(fresh).pressure.unlocked, "no wins stays locked")
	end)
	T.it("v1 and v2 saves migrate all the way to the current version", function()
		for _, v in { 1, 2 } do
			local p = ProfileSchema.migrate({ version = v, cheese = 10 })
			T.eq(p.version, ProfileSchema.VERSION)
			T.eq(p.cheese, 10)
			T.falsy(p.pressure.unlocked)
			T.deepEq(p.discoveries, {})
		end
	end)

	T.it("a v4 save round-trips: board, record and discoveries are kept", function()
		local p = ProfileSchema.default()
		p.pressure = { unlocked = true, highestCleared = 9, board = { stampede = 2, no_snacks = 1 } }
		p.discoveries = { grandmas_pantry = true }
		local m = ProfileSchema.migrate(ProfileSchema.deepCopy(p))
		T.deepEq(m, p)
	end)

	T.it("repairs a corrupted pressure block and discoveries", function()
		local raw = v3Save()
		raw.version = 4
		raw.pressure =
			{ unlocked = 1, highestCleared = 1e9, board = { stampede = 50, bogus = 2, rush_hour = -1 } }
		raw.discoveries = { lost_herd = true, junk = "x", [5] = true, day_found = 20500, nan = 0 / 0 }
		local p = ProfileSchema.migrate(raw)
		T.deepEq(p.pressure, { unlocked = false, highestCleared = 21, board = { stampede = 3 } })
		T.eq(p.discoveries.lost_herd, true)
		T.eq(p.discoveries.junk, nil)
		T.eq((p.discoveries :: any)[5], nil)
		T.eq((p.discoveries :: any).day_found, 20500, "a positive number per id is tolerated")
		T.eq(p.discoveries.nan, nil)
		local garbage = ProfileSchema.migrate({ version = 4, pressure = "x", discoveries = 7 })
		T.deepEq(garbage.pressure, { unlocked = false, highestCleared = 0, board = {} })
		T.deepEq(garbage.discoveries, {})
	end)

	T.it("the client view shows pressure and discoveries as copies", function()
		local p = ProfileSchema.default()
		p.pressure.unlocked = true
		p.pressure.board.hot_crumbs = 2
		p.discoveries.grandmas_pantry = true
		local v = ProfileSchema.view(p)
		T.deepEq(v.pressure, p.pressure)
		T.truthy(v.discoveries.grandmas_pantry)
		v.pressure.board.hot_crumbs = 3
		T.eq(p.pressure.board.hot_crumbs, 2)
	end)
end)

T.describe("Award: Pressure unlock and highestCleared", function()
	local function run(won: boolean, points: any): any
		return { cheese = 0, xp = 0, won = won, cycle = 1, bosses = 4, ranked = true, pressurePoints = points }
	end

	T.it("the first Go Home win unlocks the board", function()
		local p = ProfileSchema.default()
		local r = Award.applyRun(p, run(false, 0))
		T.falsy(r.pressureUnlocked)
		T.falsy(p.pressure.unlocked, "a wipe doesn't unlock")
		r = Award.applyRun(p, run(true, nil))
		T.truthy(r.pressureUnlocked)
		T.eq(r.pressureRecord, nil)
		T.truthy(p.pressure.unlocked)
		r = Award.applyRun(p, run(true, 0))
		T.falsy(r.pressureUnlocked, "only the first win reports the unlock")
	end)

	T.it("highestCleared rises only on wins and never falls", function()
		local p = ProfileSchema.default()
		p.pressure.unlocked = true
		local r = Award.applyRun(p, run(true, 6))
		T.eq(r.pressureRecord, 6)
		T.eq(p.pressure.highestCleared, 6)
		r = Award.applyRun(p, run(false, 15))
		T.eq(r.pressureRecord, nil)
		T.eq(p.pressure.highestCleared, 6, "a wipe at 15 is not a clear")
		r = Award.applyRun(p, run(true, 3))
		T.eq(r.pressureRecord, nil)
		T.eq(p.pressure.highestCleared, 6)
		r = Award.applyRun(p, run(true, 12))
		T.eq(r.pressureRecord, 12)
	end)

	T.it("clamps garbage points and keeps the saved board", function()
		local p = ProfileSchema.default()
		p.pressure.board = { stampede = 2 }
		Award.applyRun(p, run(true, 1e12))
		T.eq(p.pressure.highestCleared, 21)
		T.deepEq(p.pressure.board, { stampede = 2 })
		local p2 = ProfileSchema.default()
		Award.applyRun(p2, run(true, 0 / 0))
		T.eq(p2.pressure.highestCleared, 0)
		Award.applyRun(p2, run(true, "9"))
		T.eq(p2.pressure.highestCleared, 0)
	end)

	T.it("repairs a profile missing its pressure block", function()
		local p = ProfileSchema.default() :: any
		p.pressure = nil
		local r = Award.applyRun(p, run(true, 4))
		T.truthy(r.pressureUnlocked)
		T.deepEq(p.pressure, { unlocked = true, highestCleared = 4, board = {} })
	end)
end)

return T.finish()
