--!strict
-- Iteration 6 §2 (team Flow): the Normal / Fast pace (Run/Pace) and its plumbing
-- through RunState / MatchState and the saved profile.settings.pace.
local T = require("../lib/Test")
local Pace = require("../../src/shared/Run/Pace")
local RunState = require("../../src/shared/Run/RunState")
local MatchState = require("../../src/shared/Run/MatchState")
local Difficulty = require("../../src/shared/Run/Difficulty")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-9
end

T.describe("Run/Pace", function()
	T.it("clamps any value to normal | fast", function()
		T.eq(Pace.clamp("fast"), "fast")
		T.eq(Pace.clamp("normal"), "normal")
		T.eq(Pace.clamp(nil), "normal")
		T.eq(Pace.clamp("FAST"), "normal")
		T.eq(Pace.clamp(2), "normal")
		T.truthy(Pace.isValid("fast") and Pace.isValid("normal"))
		T.truthy(not Pace.isValid("turbo") and not Pace.isValid(nil))
	end)

	T.it("Fast: waves x0.7, spawn x1.35, storm x0.8, boss HP x1, cheese / class XP x1.15", function()
		local f = Pace.get("fast")
		T.truthy(near(f.wave, 0.7) and near(f.spawn, 1.35) and near(f.storm, 0.8))
		T.truthy(near(f.bossHp, 1) and near(f.cheese, 1.15) and near(f.classXp, 1.15))
		local n = Pace.get("normal")
		T.truthy(n.wave == 1 and n.spawn == 1 and n.storm == 1 and n.cheese == 1 and n.classXp == 1)
		T.truthy(near(Pace.waveSeconds(132, "fast"), 92.4))
		T.eq(Pace.waveSeconds(132, "normal"), 132)
	end)

	T.it("the view and the stored value", function()
		local v = Pace.view("fast")
		T.eq(v.id, "fast")
		T.eq(v.name, "Fast")
		T.eq(v.fast, true)
		T.eq(Pace.view(nil).fast, nil)
		T.eq(Pace.stored("fast"), "fast")
		T.eq(Pace.stored("normal"), nil)
		T.eq(Pace.stored("junk"), nil)
	end)
end)

T.describe("Run/Pace › RunState and MatchState", function()
	T.it("Fast multiplies the world spawn rate x1.35 (on top of the tier)", function()
		local normal = RunState.new(5, 4, { difficulty = Difficulty.MEDIUM })
		local fast = RunState.new(5, 4, { difficulty = Difficulty.MEDIUM, pace = "fast" })
		T.eq(normal:paceId(), "normal")
		T.eq(fast:paceId(), "fast")
		local a, b = normal:worldMods(), fast:worldMods()
		T.truthy(near(b.spawnRateMult, a.spawnRateMult * 1.35), "spawn x1.35")
		T.truthy(near(b.bossHpMult, a.bossHpMult), "boss HP x1")
		T.truthy(near(b.enemyHpMult, a.enemyHpMult), "mouse HP unchanged")
	end)

	T.it("MatchState carries the pace into its public view", function()
		local participants = {}
		for i = 1, 12 do
			table.insert(participants, { id = i, squad = (i - 1) % 4 + 1, isBot = i > 1 })
		end
		local m = MatchState.new(9, participants, { difficulty = Difficulty.MEDIUM, pace = "fast" })
		T.eq(m:pace(), "fast")
		T.eq(m:getPublic(1).pace, "fast")
		local m2 = MatchState.new(9, participants, { difficulty = Difficulty.MEDIUM })
		T.eq(m2:pace(), "normal")
	end)
end)

T.describe("Run/Pace › profile.settings.pace (additive)", function()
	T.it("keeps fast, drops anything else, defaults to normal", function()
		local p = ProfileSchema.default()
		T.eq(ProfileSchema.lastPace(p), "normal")
		local raw: any = ProfileSchema.default()
		raw.settings.pace = "fast"
		local ok = ProfileSchema.migrate(raw)
		T.eq(ok.settings.pace, "fast")
		T.eq(ProfileSchema.lastPace(ok), "fast")
		local bad: any = ProfileSchema.default()
		bad.settings.pace = "turbo"
		local cleaned = ProfileSchema.migrate(bad)
		T.eq(cleaned.settings.pace, nil)
	end)
end)

return T.finish()
