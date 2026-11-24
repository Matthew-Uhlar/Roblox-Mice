--!strict
-- (iteration 6, team Talents) Talent trees: validity of every class's tree, legacy perk
-- ids, point totals, and the keystone mechanics in a World.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local Classes = require("../../src/shared/Config/Classes")
local ClassPerks = require("../../src/shared/Config/ClassPerks")
local Keystones = require("../../src/shared/Config/Keystones")
local ClassProgress = require("../../src/shared/Data/ClassProgress")
local Stats = require("../../src/shared/Run/Stats")

local DT = 1 / 30

T.describe("Talent trees: structure", function()
	T.it("every class: 3 branches x 9 nodes, unique ids, 15 points a branch, 45 a tree", function()
		local seen: { [string]: boolean } = {}
		for _, cid in Classes.ORDER do
			local bs = ClassPerks.branches(cid)
			T.eq(#bs, 3, cid)
			local total = 0
			for _, b in bs do
				T.eq(#b.nodes, 9, cid .. " " .. b.id)
				local pts = 0
				for _, d in b.nodes do
					T.falsy(seen[d.id], "duplicate " .. d.id)
					seen[d.id] = true
					T.eq(ClassPerks.get(d.id), d)
					T.truthy(#d.description > 0, d.id .. " has a description")
					T.truthy(#d.name > 0, d.id .. " has a name")
					if d.key ~= "e2" then
						pts += d.maxRank * d.cost
					end
					for _, r in d.requires do
						local rd = ClassPerks.get(r)
						T.truthy(
							rd and rd.tier < d.tier and rd.branch == d.branch,
							d.id .. " requires a lower node"
						)
					end
				end
				T.eq(pts, ClassPerks.BRANCH_POINTS, cid .. " " .. b.id)
				T.eq(b.keystone.kind, "keystone")
				T.truthy(
					b.keystone.behaviour and Keystones.isField(b.keystone.behaviour),
					b.keystone.id .. " mechanic"
				)
				total += pts
			end
			T.eq(total, ClassPerks.TREE_POINTS)
			T.eq(ClassProgress.perkPoints(30, 16), ClassPerks.TREE_POINTS, "a full tree at L30 P16")
		end
	end)
	T.it("every node is reachable and every keystone obtainable (PATH and its e2 twin)", function()
		for _, cid in Classes.ORDER do
			for bi = 1, 3 do
				for _, choice in { "e1", "e2" } do
					local st: any = { xp = 0, level = 30, prestige = 16, perks = {} }
					for _, key in ClassPerks.PATH do
						local k = if key == "e1" then choice else key
						local d = ClassPerks.node(cid, bi, k) :: any
						local ok, why = ClassProgress.takePerk(cid, st, d.id)
						T.truthy(ok, cid .. " " .. bi .. " " .. k .. " " .. tostring(why))
					end
					for _, d in ClassPerks.branches(cid)[bi].nodes do
						local other = if choice == "e1" then "e2" else "e1"
						if d.key ~= other then
							T.eq(ClassPerks.rankOf(st.perks, d), d.maxRank, d.id .. " maxed")
						end
					end
					local other = ClassPerks.node(cid, bi, if choice == "e1" then "e2" else "e1") :: any
					local ok, why = ClassProgress.canTake(cid, st, other.id)
					T.falsy(ok)
					T.truthy(why == "exclusive" or why == "no_points", tostring(why))
				end
			end
		end
	end)
	T.it("gates: the row-3 choice needs 6 points in the branch's lower rows", function()
		local st: any = { xp = 0, level = 30, perks = {} }
		local function take(key: string): (boolean, string?)
			return ClassProgress.takePerk("elephante", st, (ClassPerks.node("elephante", 1, key) :: any).id)
		end
		T.eq(select(2, take("c")), "locked_tier")
		take("a")
		T.eq(select(2, take("c")), "locked_tier", "rows 1 need 3 points")
		take("a")
		take("a")
		T.truthy(take("c"))
		T.eq(select(2, take("e1")), "locked_tier")
		take("b")
		take("b")
		T.truthy(take("e1"))
		T.eq(select(2, take("e2")), "exclusive")
		T.eq(select(2, take("e1")), "taken")
	end)
end)

T.describe("Talent trees: saves", function()
	T.it("old ladder ids map to the same points in the same branch (full branch -> keystone)", function()
		for _, cid in Classes.ORDER do
			for bi, b in ClassPerks.branches(cid) do
				for d = 1, 5 do
					local raw = {}
					for t = 1, d do
						raw[cid .. "_" .. b.id .. "_" .. t] = true
						T.truthy(ClassPerks.legacy(cid .. "_" .. b.id .. "_" .. t), "legacy id known")
					end
					local clean = ClassProgress.sanitizePerks(cid, 30, raw, 16)
					local st: any = { level = 30, prestige = 16, perks = clean }
					T.eq(
						ClassProgress.perkPointsSpent(st),
						d * (d + 1) // 2,
						cid .. " " .. bi .. " depth " .. d
					)
					if d == 5 then
						T.eq(ClassPerks.rankOf(clean, b.keystone), 1, "old full branch keeps a keystone")
					end
				end
			end
		end
	end)
	T.it("an old full 3-branch save at L30 P16 becomes a full new tree; over budget drops tops", function()
		local raw = {}
		for _, b in ClassPerks.branches("jumbo") do
			for t = 1, 5 do
				raw["jumbo_" .. b.id .. "_" .. t] = true
			end
		end
		local full = ClassProgress.sanitizePerks("jumbo", 30, raw, 16)
		T.eq(ClassProgress.perkPointsSpent({ level = 30, perks = full } :: any), 45)
		local cut = ClassProgress.sanitizePerks("jumbo", 30, raw, 0)
		T.eq(ClassProgress.perkPointsSpent({ level = 30, perks = cut } :: any), 29)
		-- the kept set is legal: sanitising it again changes nothing
		T.deepEq(ClassProgress.sanitizePerks("jumbo", 30, cut, 0), cut)
	end)
	T.it("sanitize drops foreign, out-of-order, gap ranks and both choices", function()
		local e = function(k: string): string
			return (ClassPerks.node("elephante", 1, k) :: any).id
		end
		local raw = {
			jumbo_gale_a = true,
			[e("c")] = true, -- no a
			[e("a") .. "#2"] = true, -- rank 2 without rank 1
			["x#2"] = true,
		}
		T.deepEq(ClassProgress.sanitizePerks("elephante", 30, raw), {})
		local st: any = ClassProgress.autoSpec("elephante", 30, 1)
		local two = table.clone(st.perks)
		two[e("e2")] = true
		T.deepEq(ClassProgress.sanitizePerks("elephante", 30, two), st.perks, "only one choice kept")
	end)
	T.it("autoSpec spends every point and takes keystones; perks stay {[key] = true}", function()
		for _, cid in Classes.ORDER do
			local s = ClassProgress.autoSpec(cid, 30, 1)
			T.eq(ClassProgress.perkPointsSpent({ level = 30, perks = s.perks } :: any), 29, cid)
			for k, v in s.perks do
				T.eq(type(k), "string")
				T.eq(v, true)
			end
			local n = 0
			for _, ks in ClassPerks.keystones(cid) do
				n += ClassPerks.rankOf(s.perks, ks)
			end
			T.eq(n, 2, cid .. ": 29 points reach two keystones")
		end
	end)
	T.it("stat power of a full tree stays modest (PvP): damage <= +16%, max HP <= +30%", function()
		for _, cid in Classes.ORDER do
			local perks = {}
			for bi = 1, 3 do
				for k in ClassProgress.autoSpec(cid, 16, bi).perks do
					perks[k] = true
				end
			end
			local s0 = Stats.compute(cid, {}, {})
			local s = Stats.compute(cid, {}, {}, nil, nil, { perks = perks, level = 30, prestige = 16 })
			T.truthy(s.damageMult / s0.damageMult <= 1.16, cid .. " damage " .. s.damageMult)
			T.truthy(s.maxHp / s0.maxHp <= 1.3, cid .. " hp " .. s.maxHp / s0.maxHp)
		end
	end)
end)

-- World mechanics ----------------------------------------------------------------------------

local function newWorld(seed: number): any
	return World.new({
		rng = Rng.new(seed),
		mods = Defaults.mods(),
		arenaRadius = 300,
		obstacles = {},
		enemyPool = { "mouse" },
		cycle = 1,
		stage = 1,
		enemyCap = 0,
		champions = false,
		carriers = false,
	} :: any)
end

local function run(w: any, seconds: number): { any }
	local all = {}
	for _ = 1, math.floor(seconds / DT + 0.5) do
		for _, f in w:step(DT, w.now + DT) do
			table.insert(all, f)
		end
	end
	return all
end

local function tkFx(list: { any }, k: string): number
	local n = 0
	for _, f in list do
		if f.t == "tk" and f.k == k then
			n += 1
		end
	end
	return n
end

local function hero(w: any, extra: { [string]: number }, kind: string?): any
	local s: any = Defaults.stats()
	for k, v in extra do
		s[k] = v
	end
	w:addPlayer(1, s, Defaults.weapon(kind or "bolt"), Defaults.ability("burst"), 0, 0, 1)
	return w.players[1]
end

local function mice(w: any, n: number, r: number)
	for i = 1, n do
		local a = i / n * math.pi * 2
		local e = w:spawnEnemy("mouse", math.cos(a) * r, math.sin(a) * r)
		if e then
			e.hp, e.maxHp = 1e6, 1e6
		end
	end
end

T.describe("Talent mechanics in the World", function()
	T.it("no mechanic -> p.tk is nil (zero cost)", function()
		local w = newWorld(1)
		local p = hero(w, {})
		T.eq(p.tk, nil)
	end)
	T.it("empower: every 3rd attack sends an emp Fx", function()
		local w = newWorld(2)
		w.cap = 400
		hero(w, { tkEmpower = 3 })
		mice(w, 6, 6)
		local fx = run(w, 6)
		T.truthy(tkFx(fx, "emp") >= 2, "emp " .. tkFx(fx, "emp"))
	end)
	T.it("aura, orbs, nova and stomp damage mice around the hero (with Fx)", function()
		local w = newWorld(3)
		w.cap = 400
		hero(w, { tkAura = 0.5, tkOrbs = 2, tkNova = 2, ascStomp = 1, maxHp = 100000, armor = 1000 }, "orbit")
		mice(w, 6, 5)
		local fx = run(w, 13)
		T.truthy(tkFx(fx, "orb") >= 4, "orb zaps")
		T.truthy(tkFx(fx, "nova") >= 3, "novas")
		T.truthy(tkFx(fx, "stomp") >= 1, "stomp")
		T.truthy(tkFx(fx, "state") >= 1, "state for the client")
	end)
	T.it("charges: slot 1 recasts after CHARGE_GAP once, then waits the cooldown", function()
		local w = newWorld(4)
		local p = hero(w, { tkCharges = 1 })
		run(w, 0.1)
		T.truthy(w:useAbility(1, 5, 0, w.now))
		run(w, 1) -- wait for the first refill? no: charge starts full only after a refill
		local readyAt = p.abilityReadyAt
		T.truthy(readyAt > w.now, "on cooldown")
		run(w, readyAt - w.now + 0.1)
		T.eq(p.tk.charges, 1, "a charge refilled with the cooldown")
		T.truthy(w:useAbility(1, 5, 0, w.now))
		T.truthy(p.abilityReadyAt - w.now <= Keystones.CHARGE_GAP + 1e-6, "quick recast")
	end)
	T.it("guard: less damage from mice after a cast; last stand heals once", function()
		local w = newWorld(5)
		local p = hero(w, { tkGuard = 0.5, tkLastStand = 0.4 })
		run(w, 0.1)
		w:useAbility(1, 5, 0, w.now)
		local before = p.hp
		w:damagePlayer(p, 20, "contact")
		T.near(before - p.hp, 10, 1e-6)
		p.iframeUntil = 0
		p.invulnUntil = 0
		p.hp = p.maxHp * 0.35
		w:damagePlayer(p, 30, "contact")
		T.truthy(p.hp > p.maxHp * 0.5, "last stand healed")
		T.truthy(p.invulnUntil > w.now, "invulnerable")
	end)
	T.it("execute finishes weak mice, never bosses; kills feed frenzy and cooldown refunds", function()
		local w = newWorld(6)
		w.cap = 400
		local p = hero(w, { tkExecute = 0.2, tkFrenzy = 0.03, tkCdKill = 0.5 })
		run(w, 0.1)
		local e = w:spawnEnemy("mouse", 3, 0)
		e.maxHp, e.hp = 100, 25
		p.abilityReadyAt = w.now + 10
		local dealt = w:talentHit(p, e, 6)
		T.eq(dealt, 25, "executed")
		w:damageEnemy(e, dealt, p)
		T.falsy(e.alive)
		T.eq(p.tk.frenzy, 1)
		T.near(p.abilityReadyAt, w.now + 9.5, 1e-6)
		local b = { hp = 10, maxHp = 100, isBoss = true, x = 0, z = 0 }
		T.eq(w:talentHit(p, b, 6), 6)
	end)
	T.it("empowered attacks: bigger vs everyone, x damage vs mice only (never heroes)", function()
		local function rivalLoss(emp: boolean, kind: string): number
			local w = newWorld(21)
			local st: any = Defaults.stats()
			st.critChance = 0
			if emp then
				st.tkEmpower = 1 -- every attack empowered
			end
			w:addPlayer(1, st, Defaults.weapon(kind), Defaults.ability("burst"), 0, 0, 1)
			local vs: any = Defaults.stats()
			vs.maxHp = 100000
			local vw: any = Defaults.weapon("bolt")
			vw.damage = 0
			w:addPlayer(2, vs, vw, Defaults.ability("burst"), 4, 0, 2)
			run(w, 0.1)
			w:protect(1, 0)
			w:protect(2, 0)
			local q = w.players[2]
			local hp = q.hp
			run(w, 3)
			return hp - q.hp
		end
		for _, kind in { "bolt", "melee_arc" } do
			local plain, emp = rivalLoss(false, kind), rivalLoss(true, kind)
			T.truthy(plain > 0, kind .. " hits the rival")
			T.near(emp, plain, 1e-6, kind .. ": no PvP damage bonus")
		end
		-- vs a mouse the empowered hit is x EMPOWER_DAMAGE
		local w = newWorld(22)
		w.cap = 400
		local p = hero(w, { tkEmpower = 1 })
		run(w, 0.1)
		local e = w:spawnEnemy("mouse", 200, 0)
		e.hp, e.maxHp = 1e6, 1e6
		p.tk.empMul = Keystones.EMPOWER_DAMAGE
		T.near(w:talentHit(p, e, 10), 10 * Keystones.EMPOWER_DAMAGE, 1e-6)
		p.tk.empMul = nil
		T.near(w:talentHit(p, e, 10), 10, 1e-6)
	end)
	T.it("mechanic damage never hits enemy-squad heroes", function()
		local Talents = require("../../src/shared/Combat/Talents")
		local w = newWorld(7)
		local p = hero(w, { tkNova = 1 })
		w:addPlayer(2, Defaults.stats(), Defaults.weapon("bolt"), Defaults.ability("burst"), 3, 0, 2)
		local q = w.players[2]
		run(w, 0.1)
		local hp = q.hp
		Talents.blast(w, p, 0, 0, 20, 500, 5, "nova")
		T.eq(q.hp, hp, "rival untouched by mechanic damage")
	end)
end)

-- PerfWorld-style guard: 12 heroes with full trees + 8 Ascension nodes vs plain heroes
T.describe("Talent mechanics: per-step cost", function()
	T.it("12 maxed heroes at 250 mice cost at most 2x a plain World step", function()
		local CP = ClassProgress
		local function full(c)
			local perks = {}
			for bi = 1, 3 do
				for k in CP.autoSpec(c, 16, bi).perks do
					perks[k] = true
				end
			end
			return { perks = perks, level = 30, prestige = 16 }
		end
		local function bench(tal)
			local w = World.new({
				rng = Rng.new(5),
				mods = Stats.defaultWorldMods(),
				arenaRadius = 200,
				obstacles = {},
				enemyPool = { "mouse" },
				enemyCap = 300,
				champions = false,
				carriers = false,
			} :: any)
			for i = 1, 12 do
				local c = Classes.ORDER[(i - 1) % #Classes.ORDER + 1]
				local s, wp, a = Stats.compute(c, {}, {}, nil, nil, if tal then full(c) else nil)
				s = table.clone(s)
				s.maxHp *= 50
				w:addPlayer(i, s, wp, a, math.cos(i) * 30, math.sin(i) * 30, ((i - 1) % 4) + 1)
				if tal then
					w:setAscension(i, c, 8)
				end
			end
			local now, t = 0, 0
			for _ = 1, 1800 do
				while w.liveCount < 250 do
					local a = w.rng:range(0, 6.28)
					if not w:spawnEnemy("mouse", math.cos(a) * 40, math.sin(a) * 40) then
						break
					end
				end
				now += 1 / 30
				local c0 = os.clock()
				w:step(1 / 30, now)
				t += os.clock() - c0
				for i = 1, 12 do
					w:useAbility(i, 0, 0, now)
				end
			end
			return t / 1800 * 1000
		end
		local b, t = bench(false), bench(true)
		print(string.format("  [perf] talents: step %.3f ms (plain %.3f ms, x%.2f)", t, b, t / b))
		T.truthy(t / b <= 2, string.format("x%.2f", t / b))
	end)
end)

return T.finish()
