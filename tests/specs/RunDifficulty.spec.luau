--!strict
-- Run/Difficulty (the ladder) and Run/Waves (numbered waves + Early Horn): iteration 2.
local T = require("../lib/Test")
local Difficulty = require("../../src/shared/Run/Difficulty")
local Waves = require("../../src/shared/Run/Waves")
local Pressure = require("../../src/shared/Run/Pressure")
local RunState = require("../../src/shared/Run/RunState")
local MatchState = require("../../src/shared/Run/MatchState")

T.describe("Difficulty ladder", function()
	T.it("11 tiers; presets worth exactly their points", function()
		T.eq(Difficulty.MAX, 12) -- iteration 8: Cosmic Curd above Doomwheel
		for _, t in Difficulty.TIERS do
			T.eq(Pressure.points(Difficulty.preset(t.id)), t.points, t.name)
		end
		T.eq(Pressure.points(Difficulty.preset(9)), Pressure.MAX_POINTS, "Scorched = the full board")
	end)
	T.it(
		"base multipliers on tiers 1, 10, 11; Custom counts as the highest preset tier at or below",
		function()
			local mods = RunState.new(1, 1, { difficulty = 11 }):worldMods()
			local p0 = RunState.new(1, 1, { difficulty = 9 }):worldMods()
			-- the bases come from Config/Difficulty (team M1 tunes them)
			local Config = require("../../src/shared/Config/Difficulty")
			-- iteration 6: Scorched (9) has a base too, so the ratio is Doomwheel / Scorched
			local b9, b11 = Config.TIERS[9].base, Config.TIERS[11].base
			T.near(mods.enemyHpMult / p0.enemyHpMult, b11.hp / b9.hp, 1e-9)
			T.near(mods.spawnRateMult / p0.spawnRateMult, b11.spawn / b9.spawn, 1e-9)
			T.truthy(
				b11.hp > b9.hp and Config.TIERS[10].base.hp > b9.hp,
				"Moldy / Doomwheel tougher than Scorched"
			)
			for i = 3, 11 do
				local lo, hi = Config.TIERS[i - 1].base, Config.TIERS[i].base
				T.truthy(
					hi.hp >= lo.hp and hi.damage >= lo.damage and hi.spawn >= lo.spawn,
					"bases never fall: " .. i
				)
			end
			T.truthy(Config.TIERS[11].base.hp > 1, "Doomwheel is tougher")
			local mild = RunState.new(1, 1, { difficulty = 1 }):worldMods()
			local medium = RunState.new(1, 1, { difficulty = 2 }):worldMods()
			-- iteration 4: Medium has its own base too (team M1), so the ratio is Mild / Medium
			local mediumBase = if Config.TIERS[2].base then Config.TIERS[2].base.damage else 1
			T.near(
				mild.enemyDamageMult / medium.enemyDamageMult,
				Config.TIERS[1].base.damage / mediumBase,
				1e-9
			)
			T.truthy(Config.TIERS[1].base.damage < 1, "Mild is gentler")
			T.eq(Difficulty.forPoints(0), 2)
			T.eq(Difficulty.forPoints(10), 5, "10 points: Aged (8)")
			T.eq(Difficulty.forPoints(21), 9)
			T.eq(Difficulty.effective(0, Difficulty.preset(6)), 6)
		end
	)
	T.it("a ladder tier turns off the per-point cheese bonus (the reward x pays instead)", function()
		local tier = RunState.new(1, 1, { difficulty = 6 })
		T.eq(tier:cheesePoints(), 0)
		T.eq(tier:pressurePoints(), 11)
		local custom = RunState.new(1, 1, { pressure = Difficulty.preset(6) })
		T.eq(custom:cheesePoints(), 11, "no ladder: the v4 rules")
		local m = MatchState.new(1, { { id = 1, squad = 1 } }, { difficulty = 3 })
		T.eq(m:difficultyTier(), 3)
		T.eq(Difficulty.reward(11), 5)
	end)
	T.it("who may pick what; gem chance and tier", function()
		T.truthy(Difficulty.allowed(2, nil, 0), "Medium by default")
		T.falsy(Difficulty.allowed(3, 2, 1))
		T.truthy(Difficulty.allowed(3, 3, 2))
		T.falsy(Difficulty.allowed(0, 5, 2), "Custom needs a Sharp clear")
		T.truthy(Difficulty.allowed(0, 5, 3))
		T.near(Difficulty.gemChance(false, false), 0.35)
		T.near(Difficulty.gemChance(false, true), 0.7)
		T.eq(Difficulty.gemChance(true, false), 1)
		T.eq(Difficulty.gemTier(6, false, false), 6)
		T.eq(Difficulty.gemTier(11, true, true), 12, "the Golden Wheel")
		T.eq(Difficulty.gemTier(11, false, true), 11)
		T.eq(Difficulty.gemTier(12, false, false), 11, "Cosmic Curd drops Doomwheel-tier gems...")
		T.eq(Difficulty.gemTier(12, true, true), 13, "...and the Midnight Wheel on a won final DoN")
	end)
end)

T.describe("iteration 8: Cosmic Curd (tier 12)", function()
	T.it("sits above Doomwheel: tougher base, elite waves, enraged champions, its own colour", function()
		local Config = require("../../src/shared/Config/Difficulty")
		local top = Config.TIERS[12]
		T.eq(top.id, "cosmic_curd")
		T.truthy(top.reward > Config.TIERS[11].reward)
		T.truthy(top.base.hp >= Config.TIERS[11].base.hp and top.base.damage >= Config.TIERS[11].base.damage)
		T.eq(#top.color, 3)
		for i = 1, Config.COUNT do
			T.eq(#Config.TIERS[i].color, 3, "colour " .. i)
		end
		local dw = RunState.new(1, 1, { difficulty = 11 }):worldMods()
		local cc = RunState.new(1, 1, { difficulty = 12 }):worldMods()
		T.near(cc.eliteChance, math.min(1, dw.eliteChance + top.extras.eliteChance), 1e-9)
		T.eq(cc.championEnraged, true)
		T.eq(dw.championEnraged, nil)
		T.truthy(top.goldenChance > 0 and top.goldenChance < 1)
		T.eq(Difficulty.forPoints(21), 9, "Custom never counts as 10-12")
	end)
end)

T.describe("Waves + Early Horn", function()
	T.it("4 horde waves of 30 s with 4 s lulls, then the boss wave", function()
		local s = Waves.new(1, 0, 12)
		local events = {}
		for t = 1, 200 do
			local e = Waves.tick(s, t, 12)
			if e then
				table.insert(events, e .. "@" .. t)
			end
			if e == "boss" then
				break
			end
		end
		T.deepEq(events, { "lull@30", "wave@34", "lull@64", "wave@68", "lull@98", "wave@102", "boss@132" })
		T.eq(Waves.hordeSeconds(), 132)
		T.eq(Waves.index(2, 3), 8)
	end)
	T.it(
		"the horn: >= HORN_MIN_SECONDS in, the threshold stomped, 3 s warning, skipped seconds counted",
		function()
			local s = Waves.new(1, 0, 3)
			s.kills = math.ceil(s.budget * 0.7)
			local t = Waves.HORN_MIN_SECONDS + 1
			T.falsy(Waves.canHorn(s, Waves.HORN_MIN_SECONDS - 1, 70), "too early")
			T.falsy(Waves.canHorn(s, t, 90), "not enough stomped")
			T.falsy(Waves.canHorn(s, t, 0), "Off")
			T.truthy(Waves.canHorn(s, t, 70))
			T.truthy(Waves.canHorn(s, t, 0, true), "manual: half stomped")
			T.eq(Waves.horn(s, t), Waves.WAVE_SECONDS - t - Waves.HORN_WARN_SECONDS)
			T.eq(Waves.tick(s, t + 2, 3), nil)
			T.eq(Waves.tick(s, t + Waves.HORN_WARN_SECONDS, 3), "wave")
			T.eq(s.wave, 2)
			T.eq(s.kills, 0)
			T.eq(s.horns, 1)
			T.truthy(s.hornAll)
			T.near(
				Waves.waveTime(s, t + Waves.HORN_WARN_SECONDS),
				34,
				1e-9,
				"the storm clock jumps to wave 2"
			)
		end
	)
	T.it("settings: Off for rookies, 70 by default, only 0/50/70/90", function()
		T.eq(Waves.setting(nil, true), 0)
		T.eq(Waves.setting(nil, false), 70)
		T.eq(Waves.setting(90, true), 90)
		T.eq(Waves.setting(33, false), 70)
	end)
end)

return T.finish()
