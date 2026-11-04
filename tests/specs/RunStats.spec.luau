local T = require("../lib/Test")
local Stats = require("../../src/shared/Run/Stats")
local Leveling = require("../../src/shared/Run/Leveling")
local Classes = require("../../src/shared/Config/Classes")
local Upgrades = require("../../src/shared/Config/Upgrades")

T.describe("Stats.compute", function()
	T.it("returns class base stats with no upgrades", function()
		local s, w, a = Stats.compute("elephante", {}, {})
		T.eq(s.maxHp, 125)
		T.eq(s.moveSpeed, Stats.DEFAULT.moveSpeed)
		T.eq(w.kind, "melee_arc")
		T.eq(a.kind, "dash")
		T.eq(w.damage, Classes.get("elephante").weapon.damage)
	end)
	T.it("does not mutate DEFAULT or the class def", function()
		local s, w, a = Stats.compute("ellie_fawn", { twin_shot = 3, full_quiver = 2, mega_ability = 1 }, {})
		s.maxHp = 1
		w.damage = 999
		a.area = 999
		T.eq(Stats.DEFAULT.maxHp, 100)
		T.eq(Classes.get("ellie_fawn").weapon.count, 3)
		T.eq(Classes.get("ellie_fawn").weapon.damage, 9)
		T.eq(Classes.get("ellie_fawn").ability.area, 14)
		T.truthy(table.isfrozen(Stats.DEFAULT))
	end)
	T.it("unknown class falls back to the default class", function()
		local s, w = Stats.compute("not_a_class", {}, {})
		T.eq(s.maxHp, 125)
		T.eq(w.kind, "melee_arc")
	end)
	T.it("applies additive upgrades times their stacks", function()
		local s = Stats.compute("elephante", { twin_shot = 2, static_trunk = 1 }, {})
		T.eq(s.projectileBonus, 2)
		T.eq(s.chain, 2)
	end)
	T.it("multiplicative stacks compound", function()
		local s = Stats.compute("elephante", { big_trunk = 2 }, {})
		T.near(s.areaMult, 1.4 * 1.4)
	end)
	T.it("adds are applied before muls regardless of order", function()
		-- thick_hide (x1.5 maxHp) with talent +20 maxHp: (125 + 20) * 1.5
		local talentDefs = { hp = { perLevel = { add = { maxHp = 10 } } } }
		local s = Stats.compute("elephante", { thick_hide = 1 }, {}, { hp = 2 }, talentDefs)
		T.near(s.maxHp, (125 + 20) * 1.5)
	end)
	T.it("clamps stacks to maxStacks", function()
		local def = Upgrades.get("twin_shot")
		assert(def, "missing def")
		local s = Stats.compute("elephante", { twin_shot = 99 }, {})
		T.eq(s.projectileBonus, def.maxStacks)
	end)
	T.it("ignores unknown upgrade ids and zero / negative stacks", function()
		local s = Stats.compute("elephante", { nope = 3, twin_shot = 0, static_trunk = -2 }, {})
		T.eq(s.projectileBonus, 0)
		T.eq(s.chain, 0)
	end)
	T.it("skips another class's class-only upgrade", function()
		local _, w = Stats.compute("elephante", { full_quiver = 1 }, {})
		T.eq(w.count, 1)
		local _, w2 = Stats.compute("ellie_fawn", { full_quiver = 1 }, {})
		T.eq(w2.count, 6)
		T.eq(w2.area, 50)
	end)
	T.it("weapon deltas are additive and clamped", function()
		local _, w = Stats.compute("le_fante", { flurry = 2 }, {})
		T.near(w.cooldown, 0.35 - 0.2)
		local s2, w2 = Stats.compute("filet", { knife_block = 2 }, {})
		T.eq(w2.count, 6)
		T.eq(w2.range, 14)
		T.eq(s2.regen, 1)
	end)
	T.it("applies blessings (one each, duplicates stack)", function()
		local s = Stats.compute(
			"elephante",
			{},
			{ "bless_extra_projectile", "bless_extra_projectile", "bless_hyper_cooldown" }
		)
		T.eq(s.projectileBonus, 2)
		T.near(s.cooldownMult, 0.5)
	end)
	T.it("ignores curse ids and unknown ids in the blessing list", function()
		local s = Stats.compute("elephante", {}, { "curse_one_shot", "bless_missing" })
		T.eq(s.maxHp, 125)
	end)
	T.it("Jumbo Abilities doubles ability size", function()
		local base = Classes.get("fizzante").ability.area
		local _, _, a = Stats.compute("fizzante", {}, { "bless_jumbo_abilities" })
		T.eq(a.area, base * 2)
		local _, _, a2 = Stats.compute("fizzante", { mega_ability = 1 }, { "bless_jumbo_abilities" })
		T.eq(a2.area, base * 4)
		T.near(a2.damage, Classes.get("fizzante").ability.damage * 1.5)
	end)
	T.it("talents apply perLevel times level; missing defs are ignored", function()
		local defs = { dmg = { perLevel = { mul = { damageMult = 1.05 } } } }
		local s = Stats.compute("elephante", {}, {}, { dmg = 3, unknown = 5 }, defs)
		T.near(s.damageMult, 1.05 ^ 3)
		local s2 = Stats.compute("elephante", {}, {}, { dmg = 3 })
		T.eq(s2.damageMult, 1, "talents without defs are ignored")
	end)
	T.it("clamps stats to limits", function()
		local s = Stats.compute(
			"le_fante",
			{ lucky_tusk = 3, crushing_blow = 2, cheese_vampire = 2, bloodthirst = 1 },
			{ "bless_vampire_herd" }
		)
		T.eq(s.critChance, 1)
		T.truthy(s.lifesteal <= 1)
		local s2 = Stats.compute(
			"elephante",
			{ short_fuse = 3, ability_spam = 2, time_warp = 1 },
			{ "bless_hyper_cooldown" }
		)
		T.eq(s2.cooldownMult, Stats.LIMITS.cooldownMult[1])
	end)
	T.it("trade-off cards reduce the downside stat", function()
		local s = Stats.compute("elephante", { glass_tusks = 1 }, {})
		T.near(s.maxHp, 125 * 0.75)
		T.near(s.damageMult, 1.6)
	end)
	T.it("is deterministic for the same input", function()
		local stacks = { heavy_hitter = 2, big_trunk = 1, giant_elephant = 1, glass_tusks = 2 }
		local a = Stats.compute("jumbo", stacks, { "bless_big_stomps" })
		local b = Stats.compute("jumbo", stacks, { "bless_big_stomps" })
		T.deepEq(a, b)
	end)
end)

T.describe("Stats.applyDelta", function()
	T.it("applies add then mul in place, `times` times", function()
		local s = table.clone(Stats.DEFAULT)
		local w = table.clone(Classes.get("elephante").weapon)
		Stats.applyDelta(s, w, { add = { maxHp = 10 }, mul = { maxHp = 2 }, weapon = { count = 1 } }, 2)
		T.eq(s.maxHp, (100 + 20) * 4)
		T.eq(w.count, 3)
	end)
	T.it("ignores zero/NaN times, unknown fields, and heal", function()
		local s = table.clone(Stats.DEFAULT)
		local w = table.clone(Classes.get("elephante").weapon)
		Stats.applyDelta(s, w, { add = { maxHp = 10 } }, 0)
		Stats.applyDelta(s, w, { add = { maxHp = 10 } }, 0 / 0)
		Stats.applyDelta(s, w, { add = { bogus = 10 } :: any, heal = 1 }, 1)
		T.eq(s.maxHp, 100)
		T.eq((s :: any).bogus, nil)
	end)
	T.it("sets a missing weapon duration", function()
		local s = table.clone(Stats.DEFAULT)
		local w = table.clone(Classes.get("elephante").weapon)
		Stats.applyDelta(s, w, { weapon = { duration = 2 } }, 1)
		T.eq(w.duration, 2)
	end)
	T.it("clamps weapon cooldown and count", function()
		local s = table.clone(Stats.DEFAULT)
		local w = table.clone(Classes.get("le_fante").weapon)
		Stats.applyDelta(s, w, { weapon = { cooldown = -5, count = 100 } }, 1)
		T.eq(w.cooldown, Stats.WEAPON_LIMITS.cooldown[1])
		T.eq(w.count, Stats.WEAPON_LIMITS.count[2])
	end)
end)

T.describe("Stats.worldMods", function()
	T.it("is neutral on cycle 1 stage 1 solo", function()
		local m = Stats.worldMods(1, 1, {}, 1)
		T.deepEq(m, Stats.defaultWorldMods())
	end)
	T.it("elites appear from global stage 2", function()
		T.eq(Stats.worldMods(1, 1, {}, 1).eliteChance, 0)
		T.truthy(Stats.worldMods(1, 2, {}, 1).eliteChance > 0)
		T.truthy(Stats.worldMods(9, 4, {}, 1).eliteChance <= Stats.DIFFICULTY.eliteCap)
	end)
	T.it("each cycle is harder than the last", function()
		local prev = Stats.worldMods(1, 1, {}, 1)
		for c = 2, 5 do
			local m = Stats.worldMods(c, 1, {}, 1)
			T.truthy(m.enemyHpMult > prev.enemyHpMult, "hp cycle " .. c)
			T.truthy(m.enemyDamageMult > prev.enemyDamageMult, "dmg cycle " .. c)
			T.truthy(m.spawnRateMult > prev.spawnRateMult, "density cycle " .. c)
			T.truthy(m.bossHpMult > prev.bossHpMult, "boss cycle " .. c)
			prev = m
		end
		T.near(Stats.worldMods(2, 1, {}, 1).enemyHpMult, 1 + Stats.DIFFICULTY.hpPerCycle)
	end)
	T.it("stage 4 of a cycle is harder than stage 1 but easier than the next cycle's stage 1 HP", function()
		local s1 = Stats.worldMods(1, 1, {}, 1)
		local s4 = Stats.worldMods(1, 4, {}, 1)
		local n1 = Stats.worldMods(2, 1, {}, 1)
		T.truthy(s4.enemyHpMult > s1.enemyHpMult)
		T.truthy(n1.enemyHpMult > s4.enemyHpMult)
	end)
	T.it("scales with party size and clamps playerCount", function()
		local solo = Stats.worldMods(1, 1, {}, 1)
		local four = Stats.worldMods(1, 1, {}, 4)
		T.truthy(four.enemyHpMult > solo.enemyHpMult)
		T.truthy(four.spawnRateMult > solo.spawnRateMult)
		T.truthy(four.bossHpMult > four.enemyHpMult)
		T.deepEq(Stats.worldMods(1, 1, {}, 40), four)
		T.deepEq(Stats.worldMods(1, 1, {}, 0), solo)
	end)
	T.it("applies curses: mults multiply, booleans set, eliteChance adds", function()
		local m = Stats.worldMods(1, 1, { "curse_tough_mice", "curse_mega_horde" }, 1)
		T.near(m.enemyHpMult, 1.3 * 1.3)
		T.near(m.spawnRateMult, 1.6)
		local m2 = Stats.worldMods(1, 1, { "curse_one_shot", "curse_cheese_hail" }, 1)
		T.eq(m2.oneHitKO, true)
		T.eq(m2.fallingRocks, true)
		local base = Stats.worldMods(1, 3, {}, 1).eliteChance
		T.near(Stats.worldMods(1, 3, { "curse_elite_pack" }, 1).eliteChance, base + 0.25)
	end)
	T.it("ignores unknown curse ids and blessing ids", function()
		T.deepEq(Stats.worldMods(1, 1, { "nope", "bless_hearty_meal" }, 1), Stats.defaultWorldMods())
	end)
	T.it("survives NaN inputs", function()
		local m = Stats.worldMods(0 / 0, 0 / 0, {}, 0 / 0)
		T.eq(m.enemyHpMult, 1)
	end)
	T.it("takes a fractional party size: solo + 2 bots (2.2) sits between 2 and 3", function()
		local two = Stats.worldMods(1, 1, {}, 2)
		local mid = Stats.worldMods(1, 1, {}, 2.2)
		local three = Stats.worldMods(1, 1, {}, 3)
		T.truthy(mid.enemyHpMult > two.enemyHpMult and mid.enemyHpMult < three.enemyHpMult)
		T.truthy(mid.bossHpMult > two.bossHpMult and mid.bossHpMult < three.bossHpMult)
		T.near(mid.bossHpMult, 1 + Stats.DIFFICULTY.bossHpPerExtraPlayer * 1.2)
	end)
	T.it("bosses scale with the run's global stage (capped), damage too", function()
		local D = Stats.DIFFICULTY
		local prev = Stats.worldMods(1, 1, {}, 1)
		for st = 2, 4 do
			local m = Stats.worldMods(1, st, {}, 1)
			T.truthy(m.bossHpMult > prev.bossHpMult, "boss hp stage " .. st)
			T.truthy(m.bossDamageMult > prev.bossDamageMult, "boss dmg stage " .. st)
			prev = m
		end
		local s4 = Stats.worldMods(1, 4, {}, 1)
		T.near(s4.bossHpMult, (1 + D.hpPerStage * 3) * (1 + D.bossHpPerStage * 3))
		-- the next cycle's first boss is not easier than the last one
		T.truthy(Stats.worldMods(2, 1, {}, 1).bossHpMult > s4.bossHpMult)
		-- the stage term stops growing at bossStageCap
		local capA = Stats.worldMods(3, 4, {}, 1).bossHpMult / Stats.worldMods(3, 4, {}, 1).enemyHpMult
		local capB = Stats.worldMods(5, 4, {}, 1).bossHpMult / Stats.worldMods(5, 4, {}, 1).enemyHpMult
		T.near(capA, capB, 1e-9)
	end)
end)

T.describe("Leveling", function()
	T.it("xpToNext grows with level", function()
		T.eq(Leveling.xpToNext(1), 10)
		for l = 1, 50 do
			T.truthy(Leveling.xpToNext(l + 1) > Leveling.xpToNext(l))
		end
		T.eq(Leveling.xpToNext(0), 10)
	end)
	T.it("addXp below the threshold keeps the level", function()
		local l, x, g = Leveling.addXp(1, 0, 9)
		T.eq(l, 1)
		T.eq(x, 9)
		T.eq(g, 0)
	end)
	T.it("addXp levels up exactly at the threshold and carries the rest", function()
		local l, x, g = Leveling.addXp(1, 5, 5)
		T.eq(l, 2)
		T.eq(x, 0)
		T.eq(g, 1)
		local l2, x2, g2 = Leveling.addXp(1, 0, 10 + 18 + 3)
		T.eq(l2, 3)
		T.eq(x2, 3)
		T.eq(g2, 2)
	end)
	T.it("ignores negative and NaN gains", function()
		local l, x, g = Leveling.addXp(3, 4, -100)
		T.eq(l, 3)
		T.eq(x, 4)
		T.eq(g, 0)
		local l2, x2 = Leveling.addXp(3, 4, 0 / 0)
		T.eq(l2, 3)
		T.eq(x2, 4)
	end)
	T.it("caps at MAX_LEVEL, even with a huge gain", function()
		local l, x = Leveling.addXp(1, 0, math.huge)
		T.eq(l, Leveling.MAX_LEVEL)
		T.eq(x, 0)
		local l2, x2, g2 = Leveling.addXp(Leveling.MAX_LEVEL, 0, 500)
		T.eq(l2, Leveling.MAX_LEVEL)
		T.eq(x2, 0)
		T.eq(g2, 0)
	end)
end)

T.describe("Stats.compute: class perks and abilities (6th argument)", function()
	local ClassPerks = require("../../src/shared/Config/ClassPerks")
	local ClassAbilities = require("../../src/shared/Config/ClassAbilities")
	T.it("without a classState the result is identical to v1 (no ability id)", function()
		for _, cid in Classes.ORDER do
			local s1, w1, a1 = Stats.compute(cid, { twin_shot = 1 }, { "bless_hyper_cooldown" })
			local s2, w2, a2 = Stats.compute(
				cid,
				{ twin_shot = 1 },
				{ "bless_hyper_cooldown" },
				nil,
				nil,
				nil
			)
			T.deepEq(s1, s2)
			T.deepEq(w1, w2)
			T.deepEq(a2, a1)
			T.eq(a1.id, nil)
		end
		local _, _, a = Stats.compute("elephante", {}, {})
		for k, v in Classes.get("elephante").ability do
			T.eq((a :: any)[k], v)
		end
	end)
	T.it("an empty classState gives the base ability with its id and unchanged stats", function()
		local s0 = Stats.compute("jumbo", {}, {})
		local s, _, a = Stats.compute("jumbo", {}, {}, nil, nil, { perks = {}, level = 1 })
		T.deepEq(s, s0)
		T.eq(a.id, "jumbo_updraft")
		T.eq(a.kind, "hover")
	end)
	T.it("applies taken perks: muls, adds, weapon deltas and abilityMul", function()
		local perks = {
			elephante_bulwark_1 = true, -- maxHp x1.08
			elephante_bulwark_2 = true, -- +1 armor
			elephante_trumpeter_1 = true, -- area x1.06
			elephante_trumpeter_2 = true, -- dmg x1.05
			elephante_trumpeter_3 = true, -- attack speed x1.04, knockback +2
			elephante_stampede_1 = true, -- ability distance x1.12
		}
		local s, w, a = Stats.compute("elephante", {}, {}, nil, nil, { perks = perks, level = 30 })
		T.near(s.maxHp, 125 * 1.08)
		T.eq(s.armor, 2)
		T.near(s.areaMult, 1.06)
		T.near(s.damageMult, 1.05)
		T.near(s.attackSpeedMult, 1.04)
		T.eq(w.knockback, Classes.get("elephante").weapon.knockback + 2)
		T.near(a.distance :: number, 24 * 1.12)
	end)
	T.it("perks stack with talents and upgrades the same way (adds, then muls)", function()
		local talentDefs = { hp = { perLevel = { add = { maxHp = 10 } } } }
		local s = Stats.compute(
			"elephante",
			{ thick_hide = 1 },
			{},
			{ hp = 2 },
			talentDefs,
			{ perks = { elephante_bulwark_1 = true }, level = 2 }
		)
		T.near(s.maxHp, (125 + 20) * 1.5 * 1.08)
	end)
	T.it("behaviour perks set the World stat fields", function()
		local function full(cid: string, bi: number): any
			local perks = {}
			for _, def in ClassPerks.branches(cid)[bi].perks do
				perks[def.id] = true
			end
			return { perks = perks, level = 30 }
		end
		T.eq((Stats.compute("elephante", {}, {}, nil, nil, full("elephante", 3))).chain, 1)
		T.eq((Stats.compute("elephante", {}, {}, nil, nil, full("elephante", 2))).explodeOnKill, 4)
		T.near((Stats.compute("filet", {}, {}, nil, nil, full("filet", 3))).lifesteal, 0.03)
		T.eq((Stats.compute("le_fante", {}, {}, nil, nil, full("le_fante", 3))).extraOrbiters, 1)
		T.eq((Stats.compute("ele_fonte", {}, {}, nil, nil, full("ele_fonte", 1))).pierceBonus, 2)
	end)
	T.it("ignores perks of another class, out of order, or over the level's points", function()
		local s0 = Stats.compute("elephante", {}, {})
		local cases = {
			{ perks = { jumbo_gale_1 = true }, level = 30 },
			{ perks = { elephante_bulwark_2 = true }, level = 30 },
			{ perks = { elephante_bulwark_1 = true }, level = 1 },
			{ perks = "junk" :: any, level = 30 },
		}
		for i, cs in cases do
			local s = Stats.compute("elephante", {}, {}, nil, nil, cs)
			T.deepEq(s, s0, "case " .. i)
		end
	end)
	T.it("returns the chosen alternate only when unlocked; abilityMul applies to it", function()
		local _, _, a = Stats.compute(
			"le_fante",
			{},
			{},
			nil,
			nil,
			{ perks = {}, ability = "le_fante_fleche", level = 5 }
		)
		T.eq(a.id, "le_fante_fleche")
		T.eq(a.kind, "dash")
		local _, _, locked = Stats.compute(
			"le_fante",
			{},
			{},
			nil,
			nil,
			{ perks = {}, ability = "le_fante_blade_flurry", level = 14 }
		)
		T.eq(locked.id, "le_fante_riposte")
		local _, _, foreign = Stats.compute(
			"le_fante",
			{},
			{},
			nil,
			nil,
			{ perks = {}, ability = "jumbo_dive_bomb", level = 30 }
		)
		T.eq(foreign.id, "le_fante_riposte")
		local _, _, buffed = Stats.compute("le_fante", { mega_ability = 1 }, {}, nil, nil, {
			perks = { le_fante_en_garde_1 = true, le_fante_en_garde_2 = true },
			ability = "le_fante_blade_flurry",
			level = 15,
		})
		local base = (ClassAbilities.get("le_fante_blade_flurry") :: any).def
		T.eq(buffed.kind, "ring")
		T.near(buffed.damage, base.damage * 1.1 * 1.5)
		T.truthy((buffed.duration :: number) > base.duration, "duration perk")
		T.eq(base.damage, 9, "config def is never mutated")
		-- the classState's level defaults to max (server data is trusted)
		local _, _, noLevel = Stats.compute(
			"jumbo",
			{},
			{},
			nil,
			nil,
			{ perks = {}, ability = "jumbo_ear_cyclone" }
		)
		T.eq(noLevel.id, "jumbo_ear_cyclone")
	end)
	T.it("is deterministic and does not mutate the classState", function()
		local cs = {
			perks = { fizzante_volatile_1 = true, fizzante_volatile_2 = true },
			ability = "fizzante_shaken_can",
			level = 9,
		}
		local a1, b1, c1 = Stats.compute("fizzante", {}, {}, nil, nil, cs)
		local a2, b2, c2 = Stats.compute("fizzante", {}, {}, nil, nil, cs)
		T.deepEq(a1, a2)
		T.deepEq(b1, b2)
		T.deepEq(c1, c2)
		T.deepEq(cs.perks, { fizzante_volatile_1 = true, fizzante_volatile_2 = true })
	end)
end)

return T.finish()
