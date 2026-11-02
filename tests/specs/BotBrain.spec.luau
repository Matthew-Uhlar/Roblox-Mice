local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local BotBrain = require("../../src/shared/Bots/BotBrain")

local function mouse(id: number, x: number, z: number): any
	return { id = id, kind = 1, x = x, z = z, hpFrac = 1, flags = 0 }
end

local function view(overrides: { [string]: any }?): any
	local v: { [string]: any } = {
		self = { x = 0, z = 0, hp = 100, maxHp = 100, downed = false, abilityReady = false },
		allies = {},
		enemies = {},
		pickups = {},
		arenaRadius = 100,
		obstacles = {},
		now = 0,
	}
	for k, x in overrides or {} do
		v[k] = x
	end
	return v
end

local function dot(intent: any, x: number, z: number): number
	local m = math.sqrt(x * x + z * z)
	return intent.moveX * x / m + intent.moveZ * z / m
end

T.describe("BotBrain.think", function()
	T.it("is deterministic for the same seed and view", function()
		local a = BotBrain.new(-1, "ele_fonte", Rng.new(5))
		local b = BotBrain.new(-1, "ele_fonte", Rng.new(5))
		local v = view({
			enemies = { mouse(1, 5, 2), mouse(2, 6, -1) },
			allies = { { id = 10, x = -8, z = 0, downed = false, isBot = false } },
		})
		for _ = 1, 5 do
			T.deepEq(a:think(v, 0.1), b:think(v, 0.1))
		end
	end)
	T.it("kites away from nearby mice", function()
		local brain = BotBrain.new(-1, "ele_fonte", Rng.new(1))
		local v = view({
			enemies = { mouse(1, 6, 0), mouse(2, 7, 2), mouse(3, 7, -2) },
			allies = { { id = 10, x = 0, z = 0, downed = false, isBot = false } },
		})
		local intent = brain:think(v, 0.1)
		T.truthy(dot(intent, -1, 0) > 0.8, "moves toward -x, got " .. intent.moveX .. "," .. intent.moveZ)
		T.truthy(intent.speedFrac > 0.5)
	end)
	T.it("kites harder at low HP", function()
		local v = view({ enemies = { mouse(1, 10, 0) } })
		local healthy = BotBrain.new(-1, "ele_fonte", Rng.new(1)):think(v, 0.1)
		v.self.hp = 10
		local hurt = BotBrain.new(-1, "ele_fonte", Rng.new(1)):think(v, 0.1)
		T.truthy(dot(hurt, -1, 0) >= dot(healthy, -1, 0) - 1e-6)
		T.truthy(hurt.speedFrac >= healthy.speedFrac)
	end)
	T.it("leash: returns toward a far human ally", function()
		local brain = BotBrain.new(-1, "ele_fonte", Rng.new(2))
		local v = view({ allies = { { id = 10, x = 0, z = 40, downed = false, isBot = false } } })
		local intent = brain:think(v, 0.1)
		T.truthy(dot(intent, 0, 1) > 0.9, "heads to the human")
		T.near(intent.speedFrac, 1, 1e-6)
	end)
	T.it("leash prefers the human over a closer bot", function()
		local brain = BotBrain.new(-1, "ele_fonte", Rng.new(2))
		local v = view({
			allies = {
				{ id = -2, x = 3, z = 0, downed = false, isBot = true },
				{ id = 10, x = -40, z = 0, downed = false, isBot = false },
			},
		})
		T.truthy(dot(brain:think(v, 0.1), -1, 0) > 0.8)
	end)
	T.it("walks to a downed ally to revive when it is safe", function()
		local brain = BotBrain.new(-1, "elephante", Rng.new(3))
		local v = view({
			allies = {
				{ id = 10, x = 0, z = -20, downed = true, isBot = false },
				{ id = 11, x = 10, z = 10, downed = false, isBot = false },
			},
		})
		T.truthy(dot(brain:think(v, 0.1), 0, -1) > 0.8)
	end)
	T.it("holds position near the downed ally once within revive range", function()
		local brain = BotBrain.new(-1, "elephante", Rng.new(3))
		local v = view({ allies = { { id = 10, x = 0, z = -3, downed = true, isBot = false } } })
		local intent = brain:think(v, 0.1)
		-- only wander remains: weak or no movement, and not running away
		T.truthy(intent.speedFrac <= 0.4)
	end)
	T.it("skips an unsafe revive when hurt", function()
		local enemies = {}
		for i = 1, 8 do
			table.insert(enemies, mouse(i, 30 + (i % 3), -20 + i * 0.5))
		end
		local brain = BotBrain.new(-1, "ele_fonte", Rng.new(3))
		local v = view({
			self = { x = 0, z = 0, hp = 30, maxHp = 100, downed = false, abilityReady = false },
			allies = {
				{ id = 10, x = 30, z = -18, downed = true, isBot = false },
				{ id = 11, x = 0, z = 5, downed = false, isBot = false },
			},
			enemies = enemies,
		})
		local intent = brain:think(v, 0.1)
		T.truthy(intent.speedFrac <= 0.4, "only wanders, does not charge into the crowd")
	end)
	T.it("downed: crawls toward the nearest standing ally", function()
		local brain = BotBrain.new(-1, "ele_fonte", Rng.new(4))
		local v = view({
			self = { x = 0, z = 0, hp = 0, maxHp = 100, downed = true, abilityReady = true },
			allies = {
				{ id = 10, x = 15, z = 0, downed = false, isBot = false },
				{ id = 11, x = -40, z = 0, downed = false, isBot = false },
			},
			enemies = { mouse(1, 5, 5), mouse(2, 5, 6), mouse(3, 6, 5), mouse(4, 4, 5), mouse(5, 5, 4) },
		})
		local intent = brain:think(v, 0.1)
		T.truthy(dot(intent, 1, 0) > 0.99)
		T.eq(intent.ability, nil, "no ability while downed")
	end)
	T.it("grabs a nearby crumb when safe", function()
		local brain = BotBrain.new(-1, "ele_fonte", Rng.new(6))
		local v = view({
			pickups = { { x = 0, z = 10 } },
			allies = { { id = 10, x = -6, z = 0, downed = false, isBot = false } },
		})
		T.truthy(dot(brain:think(v, 0.1), 0, 1) > 0.6)
	end)
	T.it("steers away from the arena edge", function()
		local brain = BotBrain.new(-1, "ele_fonte", Rng.new(7))
		local v =
			view({ self = { x = 98, z = 0, hp = 100, maxHp = 100, downed = false, abilityReady = false } })
		T.truthy(dot(brain:think(v, 0.1), -1, 0) > 0.8)
	end)
	T.it("steers out of an obstacle", function()
		local brain = BotBrain.new(-1, "ele_fonte", Rng.new(8))
		local v = view({ obstacles = { { x = 2, z = 0, r = 3 } } })
		T.truthy(dot(brain:think(v, 0.1), -1, 0) > 0.8)
	end)
end)

T.describe("BotBrain ability", function()
	local function cluster(cx: number, cz: number, n: number): { any }
		local out = {}
		for i = 1, n do
			local a = i / n * math.pi * 2
			table.insert(out, mouse(i, cx + math.cos(a) * 2, cz + math.sin(a) * 2))
		end
		return out
	end
	T.it("aimed ability fires at a cluster of 5+ and aims at its centre", function()
		local brain = BotBrain.new(-1, "ele_fonte", Rng.new(1)) -- burst, distance 40
		local v = view({ enemies = cluster(25, 0, 6) })
		v.self.abilityReady = true
		local intent = brain:think(v, 0.1)
		T.truthy(intent.ability, "casts")
		T.near(intent.ability.x, 25, 1.5)
		T.near(intent.ability.z, 0, 1.5)
	end)
	T.it("picks the densest cluster", function()
		local enemies = cluster(-20, 0, 3)
		for _, e in cluster(20, 10, 7) do
			e.id += 100
			table.insert(enemies, e)
		end
		local brain = BotBrain.new(-1, "ele_fonte", Rng.new(1))
		local v = view({ enemies = enemies })
		v.self.abilityReady = true
		local intent = brain:think(v, 0.1)
		T.truthy(intent.ability)
		T.near(intent.ability.x, 20, 2)
	end)
	T.it("holds the ability for small groups", function()
		local brain = BotBrain.new(-1, "ele_fonte", Rng.new(1))
		local v = view({ enemies = cluster(20, 0, 3) })
		v.self.abilityReady = true
		T.eq(brain:think(v, 0.1).ability, nil)
	end)
	T.it("does not cast when the ability is on cooldown", function()
		local brain = BotBrain.new(-1, "ele_fonte", Rng.new(1))
		local v = view({ enemies = cluster(20, 0, 8) })
		T.eq(brain:think(v, 0.1).ability, nil)
	end)
	T.it("casts at a nearby boss even alone", function()
		local brain = BotBrain.new(-1, "ele_fonte", Rng.new(1))
		local v = view({ enemies = { { id = 1, kind = 201, x = 15, z = 5, hpFrac = 1, flags = 0 } } })
		v.self.abilityReady = true
		local intent = brain:think(v, 0.1)
		T.truthy(intent.ability)
		T.eq(intent.ability.x, 15)
	end)
	T.it("self-centred ring only counts mice around the bot", function()
		local brain = BotBrain.new(-1, "ellie_fawn", Rng.new(1)) -- ring, area 14
		local v = view({ enemies = cluster(30, 0, 8) })
		v.self.abilityReady = true
		T.eq(brain:think(v, 0.1).ability, nil, "far cluster ignored")
		v.enemies = cluster(5, 0, 6)
		T.truthy(brain:think(v, 0.1).ability, "close cluster triggers")
	end)
end)

T.describe("BotBrain.chooseUpgrade", function()
	local function card(id: string, rarity: string): any
		return { id = id, name = id, description = "", rarity = rarity, maxStacks = 1, delta = {} }
	end
	T.it("takes the highest rarity", function()
		local cards = { card("a", "Common"), card("b", "Epic"), card("c", "Rare") }
		T.eq(BotBrain.chooseUpgrade(cards, Rng.new(1)), 2)
	end)
	T.it("breaks ties with the rng (both tied cards get picked over seeds)", function()
		local cards = { card("a", "Rare"), card("b", "Common"), card("c", "Rare") }
		local seen = {}
		for seed = 1, 40 do
			local i = BotBrain.chooseUpgrade(cards, Rng.new(seed))
			T.truthy(i == 1 or i == 3)
			seen[i] = true
		end
		T.truthy(seen[1] and seen[3])
	end)
	T.it("returns 0 for no cards", function()
		T.eq(BotBrain.chooseUpgrade({}, Rng.new(1)), 0)
	end)
end)

T.describe("BotBrain boss engage", function()
	local function boss(x: number, z: number): any
		return { id = 99, kind = 205, x = x, z = z, hpFrac = 1, flags = 0 }
	end
	T.it("closes in on a far boss instead of running circles around it", function()
		local brain = BotBrain.new(-1001, "ele_fonte", Rng.new(3))
		local v = view({
			enemies = { boss(60, 0) },
			allies = { { id = 10, x = 2, z = 0, downed = false, isBot = false } },
		})
		local intent = brain:think(v, 0.1)
		T.truthy(
			dot(intent, 1, 0) > 0.6,
			"moves toward the boss, got " .. intent.moveX .. "," .. intent.moveZ
		)
	end)
	T.it("does not engage at low HP or when already in range", function()
		local brain = BotBrain.new(-1001, "ele_fonte", Rng.new(3))
		local low = view({
			self = { x = 0, z = 0, hp = 10, maxHp = 100, downed = false, abilityReady = false },
			enemies = { boss(60, 0) },
			allies = { { id = 10, x = 2, z = 0, downed = false, isBot = false } },
		})
		T.truthy(dot(brain:think(low, 0.1), 1, 0) < 0.6, "low HP bot charges the boss")
		local brain2 = BotBrain.new(-1001, "ele_fonte", Rng.new(3))
		local near = view({
			enemies = { boss(15, 0) },
			allies = { { id = 10, x = 2, z = 0, downed = false, isBot = false } },
		})
		T.truthy(dot(brain2:think(near, 0.1), 1, 0) < 0.3, "a ranged bot in range keeps its distance")
	end)
end)

T.describe("BotBrain.chooseVote", function()
	local routes = { { tier = "High" }, { tier = "Low" }, { tier = "Mid" } }
	T.it("follows the human plurality", function()
		T.eq(BotBrain.chooseVote("route", routes, { 0, 0, 2 }, Rng.new(1)), 3)
		T.eq(BotBrain.chooseVote("bank", { "Continue", "DoubleOrNothing" }, { 0, 1 }, Rng.new(1)), 2)
	end)
	T.it("breaks human ties with the rng, never picking an unvoted option", function()
		for seed = 1, 20 do
			local i = BotBrain.chooseVote("route", routes, { 1, 0, 1 }, Rng.new(seed))
			T.truthy(i == 1 or i == 3)
		end
	end)
	T.it("with no human votes: route mostly safe, bank / cycle ALWAYS safe (QC2 M3)", function()
		local counts = { route = 0, bank = 0, cycle = 0 }
		for seed = 1, 200 do
			if BotBrain.chooseVote("route", routes, { 0, 0, 0 }, Rng.new(seed)) == 2 then
				counts.route += 1
			end
			if BotBrain.chooseVote("bank", { "Continue", "DoubleOrNothing" }, {}, Rng.new(seed)) == 1 then
				counts.bank += 1
			end
			if BotBrain.chooseVote("cycle", { "GoHome", "NextCycle" }, { 0, 0 }, Rng.new(seed)) == 1 then
				counts.cycle += 1
			end
		end
		T.truthy(counts.route >= 140 and counts.route < 200, "route safe " .. counts.route .. "/200")
		T.eq(counts.bank, 200, "bots never stake Double or Nothing on their own")
		T.eq(counts.cycle, 200, "bots never pick Next Cycle on their own")
	end)
	T.it("bank / cycle: follows a human risky vote, but a human tie goes to the safe option", function()
		T.eq(BotBrain.chooseVote("cycle", { "GoHome", "NextCycle" }, { 0, 2 }, Rng.new(1)), 2)
		for seed = 1, 50 do
			T.eq(BotBrain.chooseVote("bank", { "Continue", "DoubleOrNothing" }, { 1, 1 }, Rng.new(seed)), 1)
			T.eq(BotBrain.chooseVote("cycle", { "GoHome", "NextCycle" }, { 2, 2 }, Rng.new(seed)), 1)
		end
	end)
	T.it("the surprise pick is the option right after the safe one", function()
		for seed = 1, 100 do
			local i = BotBrain.chooseVote("route", routes, {}, Rng.new(seed))
			T.truthy(i == 2 or i == 3)
		end
	end)
end)

return T.finish()
