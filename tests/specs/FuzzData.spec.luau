--!strict
-- Fuzz tests for the pure Data modules (Testing team): garbage profiles, replayed
-- receipts, shop buys, daily claims, run awards and run tokens. Nothing may throw
-- and currencies must never go negative (or non-finite).
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local Receipts = require("../../src/shared/Data/Receipts")
local Shop = require("../../src/shared/Data/Shop")
local Daily = require("../../src/shared/Data/Daily")
local Award = require("../../src/shared/Data/Award")
local RunTokens = require("../../src/shared/Data/RunTokens")
local ShopConfig = require("../../src/shared/Config/Shop")
local Talents = require("../../src/shared/Config/Talents")
local Cosmetics = require("../../src/shared/Config/Cosmetics")
local Monetization = require("../../src/shared/Config/Monetization")

local copy = ProfileSchema.deepCopy
local NAN = 0 / 0
local INF = math.huge
local FIELDS = {}
for k in ProfileSchema.default() do
	table.insert(FIELDS, k)
end
table.sort(FIELDS)
local NUMS = { 0, -1, 1, 0.5, -0.5, 1e308, -1e308, NAN, INF, -INF, 2 ^ 53, 2 ^ 31, -2 ^ 31, 1e9, 1e12 }

-- Random junk value, nested up to `depth`.
local function junk(rng: any, depth: number): any
	local r = rng:nextInt(1, if depth > 0 then 9 else 6)
	if r == 1 then
		return nil
	elseif r == 2 then
		return rng:pick(NUMS)
	elseif r == 3 then
		return rng:range(-1e6, 1e6)
	elseif r == 4 then
		return rng:chance(0.5)
	elseif r == 5 then
		local n = rng:pick({ 0, 1, 8, 64, 65, 200 })
		local chars = table.create(n, "")
		for i = 1, n do
			chars[i] = string.char(rng:nextInt(32, 126))
		end
		return table.concat(chars)
	elseif r == 6 then
		return rng:pick({ "elephante", "fizzante", "vip", "trail_streak", "hat_club_cap", "", "__index" })
	end
	local t = {}
	for _ = 1, rng:nextInt(0, 8) do
		local key: any
		local kr = rng:nextInt(1, 4)
		if kr == 1 then
			key = rng:pick(FIELDS)
		elseif kr == 2 then
			key = rng:nextInt(-3, 10)
		elseif kr == 3 then
			key = rng:pick({ "trail", "hat", "tint", "ranked", "wins", "streak", "cheese2xUntil", "version" })
		else
			key = junk(rng, 0)
			if type(key) ~= "string" and type(key) ~= "boolean" then
				key = "k" .. tostring(rng:nextInt(1, 99))
			end
		end
		t[key] = junk(rng, depth - 1)
	end
	return t
end

-- A profile-shaped table with junk in random fields.
local function junkProfile(rng: any): any
	local p: any = copy(ProfileSchema.default())
	for _ = 1, rng:nextInt(1, 10) do
		p[rng:pick(FIELDS)] = junk(rng, 3)
	end
	if rng:chance(0.3) then
		p.version = rng:pick({ 1, 2, 3, 0, -5, NAN, INF, -INF, 1.5, "2", 1e9 })
	end
	return p
end

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= INF and v ~= -INF
end

local function intIn(v: any, lo: number, hi: number, what: string)
	T.truthy(
		finite(v) and v == math.floor(v) and v >= lo and v <= hi,
		what .. " out of range: " .. tostring(v)
	)
end

-- Every number anywhere in the profile is finite.
local function allFinite(v: any, path: string, seen: { [any]: boolean }?)
	local s = seen or {}
	if type(v) == "number" then
		T.truthy(finite(v), "non-finite number at " .. path)
	elseif type(v) == "table" then
		T.falsy(s[v], "cycle at " .. path)
		s[v] = true
		for k, x in v do
			allFinite(x, path .. "." .. tostring(k), s)
		end
		s[v] = nil
	end
end

local MAXC = ProfileSchema.MAX_CURRENCY
local MAXT = ProfileSchema.MAX_TOKENS

local function checkProfile(p: any)
	T.eq(type(p), "table")
	T.eq(p.version, ProfileSchema.VERSION)
	intIn(p.cheese, 0, MAXC, "cheese")
	intIn(p.goldenCheese, 0, MAXC, "goldenCheese")
	intIn(p.xp, 0, MAXC, "xp")
	intIn(p.level, 1, Award.MAX_LEVEL, "level")
	intIn(p.secondWindTokens, 0, MAXT, "secondWindTokens")
	intIn(p.rerollTokens, 0, MAXT, "rerollTokens")
	for _, id in ShopConfig.freeClassIds() do
		T.eq(p.unlockedClasses[id], true, "free class " .. id)
	end
	T.eq(p.unlockedClasses[p.selectedClass], true, "selected class unlocked")
	for id, lvl in p.talents do
		local def = Talents.get(id)
		intIn(lvl, 1, if def then def.maxLevel else 100, "talent " .. tostring(id))
	end
	for slot, id in p.equipped do
		T.eq(p.cosmetics[id], true, "equipped " .. tostring(slot) .. " owned")
	end
	local n = 0
	for _ in p.purchaseHistory do
		n += 1
	end
	T.eq(n, #p.purchaseOrder, "history map == order list")
	T.truthy(#p.purchaseOrder <= Monetization.RULES.purchaseHistoryMax, "history pruned")
	for _, id in p.purchaseOrder do
		T.eq(p.purchaseHistory[id], true)
	end
	for _, k in { "runs", "wins", "deepestCycle", "bossesKilled" } do
		intIn(p.stats[k], 0, MAXC, "stats." .. k)
	end
	allFinite(p, "profile")
end

local function noThrow(fn: () -> any, what: string): any
	local ok, a, b = pcall(fn)
	T.truthy(ok, what .. " threw: " .. tostring(a))
	return a, b
end

T.describe("Fuzz › ProfileSchema.migrate", function()
	T.it("accepts scalars and odd types", function()
		for _, raw in
			{ nil, true, false, 0, -1, NAN, INF, "", "profile", print, buffer.create(4), {} } :: { any }
		do
			local p, info = noThrow(function()
				return ProfileSchema.migrate(raw)
			end, "migrate(" .. tostring(raw) .. ")")
			checkProfile(p)
			T.eq(type(info), "table")
		end
	end)

	T.it("survives 3000 random junk profiles (and re-migrating is stable)", function()
		local rng = Rng.new(1234)
		for i = 1, 3000 do
			local raw = if i % 3 == 0 then junk(rng, 4) else junkProfile(rng)
			local p, info = noThrow(function()
				return ProfileSchema.migrate(raw)
			end, "migrate #" .. i)
			checkProfile(p)
			if not info.futureVersion then
				local again = ProfileSchema.migrate(copy(p))
				T.deepEq(again, p, "migrate is idempotent (#" .. i .. ")")
			end
			noThrow(function()
				return ProfileSchema.view(p, { today = 20000, now = 1.7e9 })
			end, "view #" .. i)
		end
	end)

	T.it("handles future, NaN and fractional versions", function()
		for _, v in { NAN, INF, -INF, 0, -3, 1.9, 2, 3, 1e300, "2" } :: { any } do
			local p, info = ProfileSchema.migrate({ version = v, cheese = 50 })
			checkProfile(p)
			T.eq(p.cheese, 50)
			T.eq(info.futureVersion, type(v) == "number" and v == v and math.floor(v) > ProfileSchema.VERSION)
		end
	end)

	T.it("handles self-referencing tables", function()
		local raw: any = { version = 2, cheese = 10 }
		raw.stats = raw
		raw.boosts = { self = raw }
		raw.talents = raw
		raw.settings = raw
		local p = noThrow(function()
			return ProfileSchema.migrate(raw)
		end, "cyclic migrate")
		checkProfile(p)
	end)

	-- [BUG] src/shared/Data/ProfileSchema.luau:199-200 prunes purchaseOrder with
	-- table.remove(order, 1) in a loop: O(n^2). 40k ids take ~2.5 s, 80k ~15 s, so
	-- an oversized saved history stalls the DataStore load. Left failing on purpose.
	T.it(
		"[BUG ProfileSchema:199] caps huge maps quickly (100k cosmetics / talents / settings, 20k+20k purchase ids)",
		function()
			local cos, tal, set, order, hist = {}, {}, {}, {}, {}
			for i = 1, 100000 do
				cos["c" .. i] = true
				tal["t" .. i] = 3
				set["s" .. i] = i
			end
			for i = 1, 20000 do
				order[i] = "purchase_" .. i
				hist["legacy_" .. i] = true
			end
			local raw = {
				version = 2,
				cosmetics = cos,
				talents = tal,
				settings = set,
				purchaseOrder = order,
				purchaseHistory = hist,
				unlockedClasses = cos,
			}
			local t0 = os.clock()
			local p = noThrow(function()
				return ProfileSchema.migrate(raw)
			end, "huge migrate")
			local ms = (os.clock() - t0) * 1000
			print(string.format("  huge profile migrate: %.0f ms", ms))
			checkProfile(p)
			local n = 0
			for _ in p.cosmetics do
				n += 1
			end
			T.truthy(n <= ProfileSchema.MAX_MAP_ENTRIES, "cosmetics capped")
			local s = 0
			for _ in p.settings do
				s += 1
			end
			T.truthy(s <= ProfileSchema.MAX_SETTINGS, "settings capped")
			-- 40k purchase ids pruned to 200: must not be quadratic (DataStore load path).
			T.truthy(ms < 2000, string.format("migrate of a 40k-id purchase history took %.0f ms", ms))
		end
	)
end)

local PRODUCTS = {}
for _, item in Monetization.ALL do
	if item.kind == "product" and Receipts.hasHandler(item.key) then
		table.insert(PRODUCTS, item.key)
	end
end

T.describe("Fuzz › Receipts", function()
	local CTX = { now = 1.75e9, day = 20250 }

	T.it("out-of-order + duplicated delivery grants each PurchaseId exactly once", function()
		local rng = Rng.new(99)
		for round = 1, 20 do
			local unique = {}
			local n = rng:nextInt(1, Monetization.RULES.purchaseHistoryMax - 1)
			for i = 1, n do
				unique[i] = { id = string.format("r%d-%d", round, i), key = rng:pick(PRODUCTS) }
			end
			-- Reference: each receipt once, in order.
			local ref: any = ProfileSchema.default()
			for _, rc in unique do
				T.eq((Receipts.apply(ref, rc.id, rc.key, CTX)), "granted")
			end
			-- Delivery: 1-4 copies each, shuffled.
			local deliveries = {}
			for _, rc in unique do
				for _ = 1, rng:nextInt(1, 4) do
					table.insert(deliveries, rc)
				end
			end
			rng:shuffle(deliveries)
			local p: any = ProfileSchema.default()
			local granted, dup = 0, 0
			for _, rc in deliveries do
				local status = noThrow(function()
					return Receipts.apply(p, rc.id, rc.key, CTX)
				end, "apply")
				if status == "granted" then
					granted += 1
				elseif status == "duplicate" then
					dup += 1
				else
					error("unexpected status " .. tostring(status))
				end
				T.truthy(p.cheese >= 0 and p.goldenCheese >= 0 and p.secondWindTokens >= 0)
			end
			T.eq(granted, n)
			T.eq(dup, #deliveries - n)
			-- Same totals as the in-order reference (order of purchaseOrder differs).
			for _, k in { "cheese", "goldenCheese", "secondWindTokens", "rerollTokens" } do
				T.eq(p[k], ref[k], k)
			end
			T.deepEq(p.boosts, ref.boosts, "boosts")
			T.deepEq(p.ads, ref.ads, "ads")
			T.deepEq(p.purchaseHistory, ref.purchaseHistory, "history")
			checkProfile(ProfileSchema.migrate(copy(p)))
		end
	end)

	T.it("garbage receipts are rejected without touching the profile", function()
		local p: any = ProfileSchema.default()
		Receipts.apply(p, "seed", "golden_s", CTX)
		local before = copy(p)
		local ids: { any } = { nil, 0, NAN, "", string.rep("x", 129), {}, true }
		local keys: { any } = { nil, 5, "", "unknown", "vip", "cheese_club", "__index", {}, "golden_s" }
		local ctxs: { any } = { CTX, nil, {}, { now = "x", day = 1 }, 7 }
		for _, id in ids do
			for _, key in keys do
				for _, ctx in ctxs do
					local status = noThrow(function()
						return Receipts.apply(p, id, key, ctx)
					end, "garbage apply")
					T.eq(status, "rejected")
				end
			end
		end
		-- Valid id, bad product or ctx.
		for _, key in keys do
			if key ~= "golden_s" then
				T.eq((Receipts.apply(p, "fresh-id", key, CTX)), "rejected")
			end
		end
		for _, ctx in ctxs do
			if ctx ~= CTX then
				T.eq((Receipts.apply(p, "fresh-id", "golden_s", ctx)), "rejected")
			end
		end
		T.deepEq(p, before, "rejected receipts change nothing")
		T.eq((Receipts.apply(p, "seed", "golden_s", CTX)), "duplicate")
	end)

	T.it("a duplicate inside the history window is never granted again", function()
		local p: any = ProfileSchema.default()
		Receipts.apply(p, "first", "golden_xl", CTX)
		local golden = p.goldenCheese
		for i = 1, Monetization.RULES.purchaseHistoryMax - 1 do
			Receipts.apply(p, "later" .. i, "cheese_feast", CTX)
		end
		T.eq((Receipts.apply(p, "first", "golden_xl", CTX)), "duplicate")
		T.eq(p.goldenCheese, golden)
	end)
end)

-- Every catalog id plus garbage.
local ITEM_IDS: { any } = {}
for _, e in ShopConfig.list() do
	table.insert(ITEM_IDS, e.itemId)
end
for _, g in
	{
		"class:elephante",
		"class:nope",
		"class:",
		"class:fizzante:golden",
		"talent:nope",
		"talent:__index",
		"cosmetic:nope",
		"cosmetic:trail_streak",
		"cosmetic:hat_club_cap:golden",
		"cosmetic:__index:golden",
		"bundle:__index",
		"bundle:nope",
		"x:y",
		"::",
		"",
		string.rep("a", 65),
		"class:../../etc",
		"talent:hp\0",
	}
do
	table.insert(ITEM_IDS, g)
end
local NON_STRINGS: { any } = { nil, 1, NAN, true, {}, print }

T.describe("Fuzz › Shop", function()
	T.it("5000 random buys: never throws, never negative, failures change nothing", function()
		local rng = Rng.new(7)
		local fails: { [string]: number } = {}
		for round = 1, 50 do
			local p: any = ProfileSchema.default()
			p.cheese = rng:pick({ 0, 1, 99, 300, 2500, 4000, 50000, MAXC })
			p.goldenCheese = rng:pick({ 0, 1, 50, 500, MAXC })
			p.rerollTokens = rng:pick({ 0, 29, 30 })
			p.secondWindTokens = rng:pick({ 0, 9, 10 })
			local club = { club = rng:chance(0.5) }
			for _ = 1, 100 do
				local id = if rng:chance(0.1) then rng:pick(NON_STRINGS) else rng:pick(ITEM_IDS)
				local before = copy(p)
				local can = noThrow(function()
					return Shop.canBuy(p, id, club)
				end, "canBuy " .. tostring(id))
				local ok, reason = noThrow(function()
					return Shop.buy(p, id, club)
				end, "buy " .. tostring(id))
				T.eq(ok, can, "canBuy and buy agree for " .. tostring(id))
				T.truthy(p.cheese >= 0 and p.goldenCheese >= 0, "negative currency after " .. tostring(id))
				T.truthy(p.cheese == math.floor(p.cheese), "fractional cheese after " .. tostring(id))
				if ok then
					local price = (before.cheese - p.cheese) + (before.goldenCheese - p.goldenCheese)
					T.truthy(price > 0, "a successful buy costs something: " .. tostring(id))
				else
					T.deepEq(p, before, "failed buy (" .. tostring(reason) .. ") changed the profile")
					fails[tostring(reason)] = (fails[tostring(reason)] or 0) + 1
				end
				T.truthy(
					p.rerollTokens <= ShopConfig.TOKEN_CAPS.rerollTokens
						or p.rerollTokens == before.rerollTokens
				)
				T.truthy(
					p.secondWindTokens <= ShopConfig.TOKEN_CAPS.secondWindTokens
						or p.secondWindTokens == before.secondWindTokens
				)
				_ = round
			end
			checkProfile(ProfileSchema.migrate(copy(p)))
		end
		T.truthy((fails.insufficient_funds or 0) > 0, "insufficient funds exercised")
		T.truthy((fails.unknown_item or 0) + (fails.bad_id or 0) > 0, "unknown ids exercised")
	end)

	T.it("insufficient funds is refused for every catalog item at 0 balance", function()
		for _, e in ShopConfig.list() do
			local p: any = ProfileSchema.default()
			local ok, reason = Shop.buy(p, e.itemId)
			T.falsy(ok, e.itemId)
			T.eq(reason, "insufficient_funds", e.itemId)
			T.eq(p.cheese, 0)
			T.eq(p.goldenCheese, 0)
		end
	end)

	T.it("equip / canSelectClass accept garbage", function()
		local p: any = ProfileSchema.default()
		for _, slot in { "trail", "hat", "tint", "boots", 1, nil } :: { any } do
			for _, id in ITEM_IDS do
				noThrow(function()
					return Shop.equip(p, slot, id)
				end, "equip")
			end
			for _, id in NON_STRINGS do
				noThrow(function()
					return Shop.equip(p, slot, id)
				end, "equip")
				noThrow(function()
					return Shop.canSelectClass(p, id)
				end, "canSelectClass")
			end
		end
		checkProfile(ProfileSchema.migrate(copy(p)))
	end)
end)

T.describe("Fuzz › Daily, Award, RunTokens", function()
	T.it("random daily claims (gaps, clock going back, garbage days)", function()
		local rng = Rng.new(31)
		for _ = 1, 30 do
			local p: any = ProfileSchema.default()
			local day = rng:nextInt(1, 20000)
			for _ = 1, 60 do
				local d: any = day
				local r = rng:nextInt(1, 10)
				if r == 1 then
					d = rng:pick({ NAN, INF, -1, 0, 1.5, 1e7, "5", nil })
				elseif r == 2 then
					d = day - rng:nextInt(1, 5) -- clock went backwards
				else
					day += rng:nextInt(0, 3)
					d = day
				end
				local beforeLast = p.daily.lastClaimDay
				local ok = noThrow(function()
					return Daily.claim(p, d, { vip = rng:chance(0.5) })
				end, "claim")
				if ok then
					T.truthy(d > beforeLast, "claims only move forward")
					T.truthy(p.daily.streak >= 1)
				end
				T.truthy(p.cheese >= 0 and p.goldenCheese >= 0)
			end
			checkProfile(ProfileSchema.migrate(copy(p)))
		end
	end)

	T.it("Award.applyRun with garbage numbers stays in range", function()
		local rng = Rng.new(5)
		local p: any = ProfileSchema.default()
		for _ = 1, 500 do
			local r: any = {
				cheese = rng:pick(NUMS),
				xp = rng:pick(NUMS),
				won = rng:chance(0.5),
				cycle = rng:pick(NUMS),
				bosses = rng:pick(NUMS),
				cycle1Time = rng:pick(NUMS),
				ranked = rng:chance(0.5),
				day = rng:pick({ nil, 1, 2, NAN }),
			}
			noThrow(function()
				return Award.applyRun(p, r)
			end, "applyRun")
			T.truthy(finite(p.cheese) and p.cheese >= 0 and p.cheese <= MAXC, "cheese " .. tostring(p.cheese))
			T.truthy(p.level >= 1 and p.level <= Award.MAX_LEVEL)
		end
		checkProfile(ProfileSchema.migrate(copy(p)))
	end)

	T.it("RunTokens never spends a token the profile does not have", function()
		local rng = Rng.new(8)
		for _ = 1, 200 do
			local st = RunTokens.new()
			local p: any = ProfileSchema.default()
			p.secondWindTokens = rng:nextInt(0, 3)
			p.rerollTokens = rng:nextInt(0, 3)
			for _ = 1, 30 do
				local key: any = rng:pick({ "s1", "s2", "s3", "", string.rep("k", 40), nil, 4 })
				local ctx: any =
					rng:pick({ nil, { doubleOrNothing = true }, { bossHpFrac = 0.05 }, { bossHpFrac = NAN } })
				noThrow(function()
					return RunTokens.useSecondWind(st, p, key, ctx)
				end, "useSecondWind")
				noThrow(function()
					return RunTokens.useReroll(st, p, key)
				end, "useReroll")
				T.truthy(p.secondWindTokens >= 0 and p.rerollTokens >= 0)
				T.truthy(st.tokenRevives <= Monetization.RULES.maxTokenRevivesPerRun)
			end
		end
	end)
end)

_ = Cosmetics
return T.finish()
