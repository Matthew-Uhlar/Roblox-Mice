--!strict
-- v4 PvP time-to-kill (docs/V4-PLAN.md "PvP channel", V4-A H3). Measures how long
-- attackers take to down a rival hero of the same class and build in an empty World
-- (no mice), standing at weapon range and casting their ability whenever it is ready.
--
-- Build ("even level", the V4-A stage-2 average): class base stats, then damage x1.9,
-- attack speed x1.15, max HP x1.8, armor +2, regen 0.8 hp/s (paused by PvP damage).
-- Targets: see the describe block (retuned for match health in v4).
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Stats = require("../../src/shared/Run/Stats")
local Classes = require("../../src/shared/Config/Classes")

local DT = 1 / 30
local LIMIT = 60

-- (iteration 6, team Talents) TALENTED: every hero has a full 45-point talent tree (three
-- keystones) and all 8 Ascension nodes (World.setAscension)
local TALENTED = false
local ClassProgress = require("../../src/shared/Data/ClassProgress")
local function fullTree(classId: string): any
	local perks = {}
	for bi = 1, 3 do
		for k in ClassProgress.autoSpec(classId, 16, bi).perks do
			perks[k] = true
		end
	end
	return { perks = perks, level = 30, prestige = 16 }
end

local function build(classId: string): (any, any, any)
	local s, w, a = Stats.compute(classId, {}, {}, nil, nil, if TALENTED then fullTree(classId) else nil)
	s = table.clone(s)
	s.damageMult *= 1.9
	s.attackSpeedMult *= 1.15
	s.maxHp *= 1.8
	s.armor += 2
	s.regen += 0.8
	return s, table.clone(w), a
end

local function rangeOf(weapon: any): number
	if weapon.kind == "orbit" then
		return weapon.range
	end
	return math.max(3, math.min(weapon.range * 0.8, 9))
end

-- Seconds until hero 0 (victim) is downed by `attackers` (class ids), or LIMIT.
local function ttk(victimClass: string, attackers: { string }, seed: number): number
	local w = World.new({
		rng = Rng.new(seed),
		mods = Stats.defaultWorldMods(),
		arenaRadius = 200,
		obstacles = {},
		enemyCap = 0,
		champions = false,
		carriers = false,
	})
	local vs, vw, va = build(victimClass)
	vw.damage = 0
	w:addPlayer(100, vs, vw, va, 0, 0, 2)
	if TALENTED then
		w:setAscension(100, victimClass, 8)
	end
	local pos = {}
	for i, c in attackers do
		local s, wpn, a = build(c)
		local d = rangeOf(wpn)
		local ang = (i - 1) * (math.pi * 2 / 3) + 0.3
		pos[i] = { x = math.cos(ang) * d, z = math.sin(ang) * d }
		w:addPlayer(i, s, wpn, a, pos[i].x, pos[i].z, 1)
		if TALENTED then
			w:setAscension(i, c, 8)
		end
	end
	local now = 0
	now += DT
	w:step(DT, now)
	for id = 1, #attackers do
		w:protect(id, 0)
	end
	w:protect(100, 0)
	local t0 = now
	while now - t0 < LIMIT do
		now += DT
		for i = 1, #attackers do
			-- (iteration 7) only when slot 1 is ready: a recast of Dig In (Trunkillery) digs out
			local info = w:getPlayer(i)
			if info and now >= (info.abilityReadyAt or 0) then
				w:useAbility(i, 0, 0, now)
			end
		end
		w:step(DT, now)
		w:drainEvents()
		local v = w:getPlayer(100)
		if v.downed or v.dead then
			return now - t0
		end
		w:setPlayerPosition(100, 0, 0)
		for i, p in pos do
			w:setPlayerPosition(i, p.x, p.z)
		end
	end
	return LIMIT
end

local function median(list: { number }): number
	local c = table.clone(list)
	table.sort(c)
	return c[math.ceil(#c / 2)]
end

local results: any = nil
local function measure(): any
	if results then
		return results
	end
	local one, two, three, rows = {}, {}, {}, {}
	local worst, worstPair = 0, ""
	for ai, a in Classes.ORDER do
		local row = {}
		for vi, v in Classes.ORDER do
			local t1 = ttk(v, { a }, ai * 31 + vi)
			local t2 = ttk(v, { a, a }, ai * 41 + vi)
			local t3 = ttk(v, { a, a, a }, ai * 37 + vi)
			table.insert(one, t1)
			table.insert(two, t2)
			table.insert(three, t3)
			table.insert(row, t1)
			if t1 > worst then
				worst, worstPair = t1, a .. " -> " .. v
			end
		end
		rows[a] = row
	end
	results = {
		one = median(one),
		two = median(two),
		three = median(three),
		rows = rows,
		worst = worst,
		worstPair = worstPair,
	}
	print(
		string.format(
			"\n  [ttk] median 1v1 %.2f s, 2v1 %.2f s, 3v1 %.2f s; slowest 1v1 %.1f s (%s)",
			results.one,
			results.two,
			results.three,
			worst,
			worstPair
		)
	)
	for _, a in Classes.ORDER do
		local line = string.format("  [ttk] %-10s", a)
		for _, t in rows[a] do
			line ..= string.format(" %5.1f", t)
		end
		print(line .. string.format("   median %.1f", median(rows[a])))
	end
	return results
end

T.describe("PvP time to kill (v4)", function()
	-- The plan's 6-9 s (1v1) / 2.5-4 s (3v1) wiped 85% of solo humans in stage 1 in
	-- tests/sim/v4-report (48 seeds), so M1 retuned for match health: these bands
	-- guard the tuned channel (docs/COMBAT-API.md "v4 PvP channel").
	T.it("1v1 median is 15-28 s at even builds", function()
		local r = measure()
		T.truthy(r.one >= 15 and r.one <= 28, string.format("1v1 median %.2f s", r.one))
	end)
	T.it("focus fire pays: 2v1 at least 10% and 3v1 at least 25% faster than 1v1", function()
		local r = measure()
		T.truthy(r.two <= r.one * 0.9, string.format("2v1 %.2f s vs 1v1 %.2f s", r.two, r.one))
		T.truthy(r.three <= r.one * 0.75, string.format("3v1 %.2f s vs 1v1 %.2f s", r.three, r.one))
	end)
	T.it("no 1v1 pairing takes more than 45 s", function()
		local r = measure()
		T.truthy(r.worst <= 45, string.format("%s takes %.1f s", r.worstPair, r.worst))
	end)
	T.it("class balance: every median 1v1 within 15-30 s, slowest / fastest <= 1.6", function()
		local r = measure()
		local lo, hi = math.huge, 0
		for _, a in Classes.ORDER do
			local m = median(r.rows[a])
			lo, hi = math.min(lo, m), math.max(hi, m)
			T.truthy(m >= 15 and m <= 30, string.format("%s median %.1f s", a, m))
		end
		T.truthy(hi / lo <= 1.6, string.format("spread %.2f", hi / lo))
	end)
end)

-- (iteration 6, team Talents) long-term power stays out of PvP: maxed talents + all
-- Ascension nodes on BOTH sides keep the 1v1 time-to-kill near the even build
T.describe("PvP TTK with maxed talents and Ascension (iteration 6)", function()
	T.it("median 1v1 stays within 0.75x..1.35x of the base", function()
		local base, tal = {}, {}
		for ai, a in Classes.ORDER do
			for vi, v in Classes.ORDER do
				if (ai + vi) % 3 == 0 then
					TALENTED = false
					table.insert(base, ttk(v, { a }, ai * 31 + vi))
					TALENTED = true
					table.insert(tal, ttk(v, { a }, ai * 31 + vi))
				end
			end
		end
		TALENTED = false
		local mb, mt = median(base), median(tal)
		print(
			string.format(
				"  [ttk] talents+ascension: median 1v1 %.2f s vs base %.2f s (x%.2f)",
				mt,
				mb,
				mt / mb
			)
		)
		T.truthy(mt / mb >= 0.75 and mt / mb <= 1.35, string.format("x%.2f", mt / mb))
	end)
end)

return T.finish()
