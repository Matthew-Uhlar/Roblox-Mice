--!strict
-- Iteration 4 sim guard (docs/iter/4/PLAN.md, "In-round strength like Liberty"): by
-- stage 3 the V menu (stat ranks) gives the hero more power than the level-up cards.
-- Power = damage x attack speed x max HP (+ armor as a little EHP), as a ratio over the
-- class's bare stats; one solo human stand-in + bots, the Headless sim, to stage 3.
local T = require("../lib/Test")
local H = require("../sim/Headless")
local Stats = require("../../src/shared/Run/Stats")
local RunShop = require("../../src/shared/Config/RunShop")
local Leveling = require("../../src/shared/Run/Leveling")
local Classes = require("../../src/shared/Config/Classes")

local SEEDS = 8
local HUMAN = 1001

local function power(s: any): number
	local dmg = (s.damageMult or 1) * (s.pveDamageMult or 1)
	local ehp = (s.maxHp or 100) * (1 + math.max(0, s.armor or 0) * 0.02)
	return dmg * (s.attackSpeedMult or 1) * ehp
end

local function base(classId: string): (any, any)
	local s, w = Stats.compute(classId, {}, {}, {}, nil)
	local st = table.clone(s) :: any
	st.pveDamageMult = st.pveDamageMult or 1
	return st, table.clone(w)
end

local function ratio(classId: string, delta: any?, stacks: any?): number
	local b0, _ = base(classId)
	local p0 = power(b0)
	local s, w
	if stacks then
		s, w = Stats.compute(classId, stacks, {}, {}, nil)
		s = table.clone(s) :: any
		s.pveDamageMult = s.pveDamageMult or 1
	else
		s, w = base(classId)
	end
	if delta then
		Stats.applyDelta(s, w, delta, 1)
	end
	return power(s) / p0
end

local function median(list: { number }): number
	table.sort(list)
	return list[math.max(1, math.ceil(#list / 2))]
end

T.describe("IntegrationStrength", function()
	T.it("milestone picks every 5 levels; fixed per-level gains", function()
		T.eq(Leveling.milestones(1, 4), 0)
		T.eq(Leveling.milestones(4, 5), 1)
		T.eq(Leveling.milestones(3, 16), 3)
		local d = Leveling.levelDelta(11)
		T.near(d.mul.maxHp, 1.3, 1e-9)
		T.near(d.mul.damageMult, 1.2, 1e-9)
		T.eq(d.add.armor, 2)
		local k = RunShop.RANK_PRICE_SCALE -- iteration 6
		T.eq(RunShop.rankCost("might", 0), math.floor(RunShop.RANKS.might.base * k + 0.5))
		T.eq(
			RunShop.rankCost("might", 10),
			math.floor((RunShop.RANKS.might.base + 10 * RunShop.RANKS.might.step) * k + 0.5)
		)
		T.near(RunShop.effectiveRank(120), 50 + 25 + 5, 1e-9, "soft past 50, harder past 100")
	end)

	T.it("at stage 3 the V menu out-powers the cards", function()
		local vMenu, cards, levels, ranks = {}, {}, {}, {}
		for i = 1, SEEDS do
			local classId = Classes.ORDER[(i - 1) % #Classes.ORDER + 1]
			local sim = H.new({ seed = 4100 + i * 13, humans = { { classId = classId } }, maxStages = 3 })
			sim:playRun()
			local m = sim.byId[HUMAN]
			local w = sim.wallets[HUMAN]
			if m and w then
				table.insert(vMenu, ratio(classId, RunShop.rankDelta(w.ranks)))
				table.insert(cards, ratio(classId, nil, m.stacks))
				table.insert(levels, m.level)
				local n = 0
				for _, r in w.ranks do
					n += r
				end
				table.insert(ranks, n)
			end
		end
		T.truthy(#vMenu >= SEEDS / 2, "the human stand-in is found")
		local v, c = median(vMenu), median(cards)
		print(
			string.format(
				"  [STRENGTH] stage 3 medians: V menu x%.2f, cards x%.2f, level %d, ranks %d",
				v,
				c,
				median(levels),
				median(ranks)
			)
		)
		T.truthy(v > c, string.format("V menu x%.2f > cards x%.2f", v, c))
	end)
end)

return T.finish()
