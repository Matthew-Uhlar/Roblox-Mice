--!strict
-- v4 PvP time-to-kill (docs/V4-PLAN.md "PvP channel", V4-A H3). Measures how long
-- attackers take to down a rival hero of the same class and build in an empty World
-- (no mice), standing at weapon range and casting their ability whenever it is ready.
--
-- Build ("even level", the V4-A stage-2 average): class base stats, then damage x1.9,
-- attack speed x1.15, max HP x1.8, armor +2, regen 0.8 hp/s (paused by PvP damage).
-- Targets (median over all 49 class pairings): 1v1 6-9 s, 2v1 3.5-5 s, 3v1
-- 2.5-4 s; no 1v1 pairing above 20 s.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Stats = require("../../src/shared/Run/Stats")
local Classes = require("../../src/shared/Config/Classes")

local DT = 1 / 30
local LIMIT = 60

local function build(classId: string): (any, any, any)
	local s, w, a = Stats.compute(classId, {}, {}, nil)
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
	local pos = {}
	for i, c in attackers do
		local s, wpn, a = build(c)
		local d = rangeOf(wpn)
		local ang = (i - 1) * (math.pi * 2 / 3) + 0.3
		pos[i] = { x = math.cos(ang) * d, z = math.sin(ang) * d }
		w:addPlayer(i, s, wpn, a, pos[i].x, pos[i].z, 1)
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
			w:useAbility(i, 0, 0, now)
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
	T.it("1v1 median is 6-9 s at even builds", function()
		local r = measure()
		T.truthy(r.one >= 6 and r.one <= 9, string.format("1v1 median %.2f s", r.one))
	end)
	T.it("2v1 median is 3.5-5 s", function()
		local r = measure()
		T.truthy(r.two >= 3.5 and r.two <= 5, string.format("2v1 median %.2f s", r.two))
	end)
	T.it("3v1 median is 2.5-4 s (focus fire works: per-attacker lockout)", function()
		local r = measure()
		T.truthy(r.three >= 2.5 and r.three <= 4, string.format("3v1 median %.2f s", r.three))
	end)
	T.it("no 1v1 pairing takes more than 20 s", function()
		local r = measure()
		T.truthy(r.worst <= 20, string.format("%s takes %.1f s", r.worstPair, r.worst))
	end)
	T.it("every class's median 1v1 sits in 4-12 s (balance band)", function()
		local r = measure()
		for _, a in Classes.ORDER do
			local m = median(r.rows[a])
			T.truthy(m >= 4 and m <= 12, string.format("%s median %.1f s", a, m))
		end
	end)
end)

return T.finish()
