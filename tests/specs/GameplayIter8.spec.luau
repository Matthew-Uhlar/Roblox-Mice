--!strict
-- Iteration 8 §B (team Gameplay): the Epic boss variant and each boss's new attack.
-- (Cosmic Curd: RunDifficulty.spec; the cleanse choice: RunState.spec.)
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local Bosses = require("../../src/shared/Config/Bosses")
local BossPatterns = require("../../src/shared/Combat/BossPatterns")
local MatchState = require("../../src/shared/Run/MatchState")

local DT = 1 / 30

local function world(): any
	local w = World.new({
		rng = Rng.new(8),
		mods = Defaults.mods(),
		arenaRadius = 110,
		obstacles = {},
		enemyPool = { "mouse" },
	})
	local weapon = Defaults.weapon("bolt")
	weapon.damage = 0
	w:addPlayer(1, Defaults.stats({ maxHp = 1e7 }), weapon, Defaults.ability("burst"), 0, 25)
	w:step(DT, DT)
	return w
end

T.describe("Iteration 8 › boss variety", function()
	T.it("every boss has one new attack in both phases, and it telegraphs", function()
		for _, id in Bosses.ORDER do
			local def = Bosses.get(id) :: any
			local pat = Bosses.NEW_PATTERNS[id]
			T.truthy(pat ~= nil, id .. " has a new attack")
			T.truthy(table.find(def.patterns, pat) ~= nil, id .. " phase 1")
			T.truthy(table.find(def.phase2Patterns, pat) ~= nil, id .. " phase 2")
			T.truthy(BossPatterns.has(pat), pat)
			local d = BossPatterns.get(pat) :: any
			T.truthy(d.windup == nil or d.windup >= BossPatterns.MIN_TELEGRAPH, pat .. " windup")
			T.truthy(def.patterns[1] ~= pat, id .. ": the opener is unchanged")
		end
	end)

	T.it("an Epic boss: x hpMult HP, x damageMult damage, snapshot bit 0, Fx epic", function()
		local w1, w2 = world(), world()
		local plain = w1:spawnBoss("froggus", 0, 0)
		local epic = w2:spawnBoss("froggus", 0, 0, { epic = true })
		T.near(epic.maxHp, plain.maxHp * Bosses.EPIC.hpMult, 1e-6)
		T.near(epic.contact, plain.contact * Bosses.EPIC.damageMult, 1e-6)
		T.eq(epic.epic, true)
		T.eq(plain.epic, nil)
		local function bossSnap(w: any): any
			for _, s in w:snapshot() do
				if s.kind >= Bosses.KIND_OFFSET then
					return s
				end
			end
			return nil
		end
		T.eq(bossSnap(w2).flags % 2, 1, "bit 0 marks the Epic boss")
		T.eq(bossSnap(w1).flags % 2, 0)
		local saw = false
		for _, f in w2:step(DT, w2.now + DT) do
			if f.t == "boss" and f.epic then
				saw = true
			end
		end
		T.truthy(saw, "the boss intro Fx carries epic = true")
	end)

	T.it("an Epic boss pays a bigger chest and always the epic drop", function()
		local participants = {}
		for i = 1, 12 do
			table.insert(participants, { id = i, squad = (i - 1) % 4 + 1, isBot = i > 1 })
		end
		local function stageOne(epicBoss: boolean): any
			local m = MatchState.new(5, participants, {})
			m:begin()
			local route = (m.run :: any).route -- the live route (currentRoute returns a copy)
			route.epicBoss = epicBoss or nil
			m:startBoss()
			return m:bossDefeated(1, { [1] = 100 }, false)
		end
		local a, b = stageOne(false), stageOne(true)
		T.truthy(b.epic == true, "the epic drop")
		T.truthy(Bosses.EPIC.chestMult > 1)
		T.eq(b.stageCheese, a.stageCheese, "stage cheese unchanged")
	end)
end)

return T.finish()
