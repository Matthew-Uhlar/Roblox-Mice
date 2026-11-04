--!strict
-- v2 squad-aware bots (docs/GDD-v2.md §2-4): BotBrain with squads, foes, gear,
-- loot bags, the Power Totem and the extraction choice.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local BotBrain = require("../../src/shared/Bots/BotBrain")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local Ids = require("../../src/shared/Util/Ids")

local ME = Ids.botId(5) -- -1005

local function view(overrides: { [string]: any }?): any
	local v: { [string]: any } = {
		self = { x = 0, z = 0, hp = 100, maxHp = 100, downed = false, abilityReady = false, squad = 1 },
		allies = {},
		enemies = {},
		pickups = {},
		arenaRadius = 120,
		obstacles = {},
		now = 10,
	}
	for k, x in overrides or {} do
		v[k] = x
	end
	return v
end

local function hero(id: number, x: number, z: number, squad: number, extra: { [string]: any }?): any
	local h: any = { id = id, x = x, z = z, downed = false, isBot = Ids.isBot(id), squad = squad }
	for k, v in extra or {} do
		h[k] = v
	end
	return h
end

local function dot(intent: any, x: number, z: number): number
	local m = math.sqrt(x * x + z * z)
	return intent.moveX * x / m + intent.moveZ * z / m
end

local function brain(classId: string?): any
	return BotBrain.new(ME, classId or "ele_fonte", Rng.new(3))
end

T.describe("BotBrain squads › sticking together", function()
	T.it("leashes to its squad's human, not a closer enemy human", function()
		local v = view({
			allies = {
				hero(ME, 0, 0, 1),
				hero(50, -40, 0, 1), -- my squad's human, far
				hero(60, 30, 30, 2), -- enemy human (outside the 18-stud engage radius)
			},
		})
		local i = brain():think(v, 0.1)
		T.truthy(dot(i, -1, 0) > 0.7, string.format("toward the squad human: %.2f %.2f", i.moveX, i.moveZ))
	end)
	T.it("a bot-only squad follows its leader (the highest id); the leader roams", function()
		local leader = Ids.botId(1) -- -1001 > -1005
		local v = view({
			allies = { hero(ME, 0, 0, 1), hero(leader, 0, 40, 1) },
		})
		local i = brain():think(v, 0.1)
		T.truthy(dot(i, 0, 1) > 0.7, "follows the leader")
		local lb = BotBrain.new(leader, "ele_fonte", Rng.new(3))
		local lv = view({
			self = { x = 60, z = 0, hp = 100, maxHp = 100, downed = false, abilityReady = false, squad = 1 },
			allies = { hero(leader, 60, 0, 1), hero(ME, 0, 0, 1) },
		})
		local li = lb:think(lv, 0.1)
		T.truthy(dot(li, -1, 0) > 0.5, "the leader drifts toward the middle, not to its follower's leash")
	end)
	T.it("without squads in the view it behaves as in v1 (no foes)", function()
		local v = view({
			self = { x = 0, z = 0, hp = 100, maxHp = 100, downed = false, abilityReady = false },
			allies = { { id = 50, x = -40, z = 0, downed = false, isBot = false, squad = 2 } },
		})
		local i = brain():think(v, 0.1)
		T.truthy(dot(i, -1, 0) > 0.7, "follows any human as before")
	end)
end)

T.describe("BotBrain squads › fighting heroes", function()
	T.it("engages an enemy hero within 18 studs, ignores one further away", function()
		local near = view({ allies = { hero(ME, 0, 0, 1), hero(60, 16, 0, 2) } })
		local i = brain():think(near, 0.1)
		T.truthy(dot(i, 1, 0) > 0.5, "closes in to weapon range")
		local far = view({ allies = { hero(ME, 0, 0, 1), hero(60, 30, 0, 2), hero(70, -40, 0, 1) } })
		local j = brain():think(far, 0.1)
		T.truthy(dot(j, -1, 0) > 0.5, "leaves a far hero alone (keeps following its human)")
	end)
	T.it("engages a far hero that hit its squad recently", function()
		local v = view({
			allies = {
				hero(ME, 0, 0, 1),
				hero(Ids.botId(9), -3, 0, 1, { lastHitBy = 60, lastHitAt = 9 }),
				hero(60, 35, 0, 2),
				hero(70, -40, 0, 1),
			},
		})
		local i = brain():think(v, 0.1)
		T.truthy(dot(i, 1, 0) > 0.5, "goes after the attacker")
		v.now = 30 -- long ago
		local j = brain():think(v, 0.1)
		T.truthy(dot(j, -1, 0) > 0.5, "an old attack is forgotten")
	end)
	T.it("aims its ability at an engaged hero; ignores spawn-protected ones", function()
		local b = BotBrain.new(ME, "ele_fonte", Rng.new(3))
		local v = view({
			self = { x = 0, z = 0, hp = 100, maxHp = 100, downed = false, abilityReady = true, squad = 1 },
			allies = { hero(ME, 0, 0, 1), hero(60, 8, 0, 2) },
		})
		local i = b:think(v, 0.1)
		T.truthy(i.ability and math.abs(i.ability.x - 8) < 1e-6, "ability at the foe")
		v.allies[2].protected = true
		local j = b:think(v, 0.1)
		T.eq(j.ability, nil)
	end)
	T.it("flees when low with a foe near (toward its squad)", function()
		local v = view({
			self = { x = 0, z = 0, hp = 20, maxHp = 100, downed = false, abilityReady = false, squad = 1 },
			allies = { hero(ME, 0, 0, 1), hero(60, 10, 0, 2), hero(Ids.botId(9), -20, 0, 1) },
		})
		local i = brain():think(v, 0.1)
		T.truthy(dot(i, -1, 0) > 0.8, "runs away")
	end)
end)

T.describe("BotBrain squads › POIs, totem, gear and bags", function()
	local function poi(kind: string, x: number, z: number, extra: { [string]: any }?): any
		local p: any =
			{ id = 1, kind = kind, x = x, z = z, r = 6, state = "idle", active = true, progress = 0 }
		for k, v in extra or {} do
			p[k] = v
		end
		return p
	end
	T.it("captures a Power Totem it does not own; leaves an owned, quiet one", function()
		local v = view({
			allies = { hero(ME, 0, 0, 1), hero(70, -25, 0, 1) }, -- the totem is 37 studs from the human
			pois = { poi("power_totem", 12, 0, { mode = "totem", r = 8 }) },
		})
		T.truthy(dot(brain():think(v, 0.1), 1, 0) > 0.6, "goes to capture")
		v.pois[1].owner = 1
		v.pois[1].progress = 1
		v.pois[1].state = "active"
		T.truthy(dot(brain():think(v, 0.1), -1, 0) > 0.5, "nothing to do at a held totem")
		v.pois[1].capSquad = 3
		v.pois[1].progress = 0.6
		T.truthy(dot(brain():think(v, 0.1), 1, 0) > 0.6, "defends it")
	end)
	T.it("contests a POI another squad is channelling", function()
		local v = view({
			allies = { hero(ME, 0, 0, 1), hero(60, 60, 60, 2) },
			pois = {
				poi("cheese_vault", 25, 0, { mode = "channel", squad = 2, progress = 0.3, state = "active" }),
			},
		})
		T.truthy(dot(brain():think(v, 0.1), 1, 0) > 0.6)
	end)
	T.it("walks to ground gear that beats its slot and to loot bags", function()
		local v = view({
			self = {
				x = 0,
				z = 0,
				hp = 100,
				maxHp = 100,
				downed = false,
				abilityReady = false,
				squad = 1,
				gear = { armor = { id = "rind_plate", slot = "armor", rarity = "Epic" } },
			},
			allies = { hero(ME, 0, 0, 1), hero(70, -30, 0, 1) },
			gear = { { id = 1, x = 20, z = 0, item = { id = "bark_hide", slot = "armor", rarity = "Rare" } } },
		})
		T.truthy(dot(brain():think(v, 0.1), -1, 0) > 0.5, "a worse item is ignored")
		v.gear[1].item.rarity = "Legendary"
		T.truthy(dot(brain():think(v, 0.1), 1, 0) > 0.6, "a better item is fetched")
		v.gear = {}
		v.bags = { { id = 3, x = 0, z = -20 } }
		T.truthy(dot(brain():think(v, 0.1), 0, -1) > 0.6, "a loot bag is fetched")
	end)
end)

T.describe("BotBrain squads › choices", function()
	T.it("chooseVote extract: follows its squad's humans; bot-only squads use pot / HP", function()
		local opts = { "Extract", "Stay", "DoubleOrNothing" }
		local rng = Rng.new(1)
		T.eq(BotBrain.chooseVote("extract", opts, { 0, 0, 2 }, rng), 3, "follows a human Double or Nothing")
		T.eq(BotBrain.chooseVote("extract", opts, { 1, 1, 0 }, rng), 1, "a human tie goes to Extract")
		T.eq(
			BotBrain.chooseVote("extract", opts, {}, rng, { pot = 50, hpFrac = 0.9 }),
			2,
			"small pot, healthy: Stay"
		)
		T.eq(
			BotBrain.chooseVote("extract", opts, {}, rng, { pot = 500, hpFrac = 0.9 }),
			1,
			"big pot: Extract"
		)
		T.eq(BotBrain.chooseVote("extract", opts, {}, rng, { pot = 50, hpFrac = 0.2 }), 1, "hurt: Extract")
		for seed = 1, 50 do
			T.truthy(
				BotBrain.chooseVote("extract", opts, {}, Rng.new(seed), { pot = 0 }) ~= 3,
				"never DoN alone"
			)
		end
	end)
	T.it("chooseSwap takes rarer gear only; chooseCartItem buys an affordable upgrade", function()
		local c = { id = "rind_plate", slot = "armor", rarity = "Rare" }
		T.truthy(BotBrain.chooseSwap(c, { id = "bark_hide", slot = "armor", rarity = "Epic" }))
		T.falsy(BotBrain.chooseSwap(c, { id = "bark_hide", slot = "armor", rarity = "Rare" }))
		T.truthy(BotBrain.chooseSwap(nil, c))
		local offers = {
			{ id = "rapid_tusks", slot = "weapon", rarity = "Legendary" },
			{ id = "bark_hide", slot = "armor", rarity = "Epic" },
			{ id = "lucky_cheese", slot = "trinket", rarity = "Common" },
		}
		local prices = { 400, 220, 60 }
		T.eq(
			BotBrain.chooseCartItem(offers, prices, nil, 500, { armor = c }),
			2,
			"Epic armor (Legendary too pricey)"
		)
		T.eq(BotBrain.chooseCartItem(offers, prices, { false, true, false }, 500, { armor = c }), 3)
		T.eq(BotBrain.chooseCartItem(offers, prices, nil, 50, {}), 0, "cannot afford anything")
	end)
end)

T.describe("Perf › BotBrain with 12 heroes, gear, bags and 220 mice", function()
	T.it("think() < 1 ms (9 bots per 0.1 s stay well under a frame)", function()
		local rng = Rng.new(5)
		local enemies = {}
		for i = 1, 220 do
			table.insert(
				enemies,
				{ id = i, kind = 1, x = rng:range(-60, 60), z = rng:range(-60, 60), hpFrac = 1, flags = 0 }
			)
		end
		local allies = {}
		for sq = 1, 4 do
			for k = 1, 3 do
				table.insert(allies, hero(Ids.botId(sq * 10 + k), rng:range(-50, 50), rng:range(-50, 50), sq))
			end
		end
		local gear, bags = {}, {}
		for i = 1, 20 do
			table.insert(
				gear,
				{
					id = i,
					x = rng:range(-50, 50),
					z = rng:range(-50, 50),
					item = { id = "wax_coat", slot = "armor", rarity = "Rare" },
				}
			)
			table.insert(bags, { id = i, x = rng:range(-80, 80), z = rng:range(-80, 80) })
		end
		local b = BotBrain.new(Ids.botId(11), "fizzante", rng)
		local v = view({
			self = {
				x = allies[1].x,
				z = allies[1].z,
				hp = 60,
				maxHp = 100,
				downed = false,
				abilityReady = true,
				squad = 1,
			},
			allies = allies,
			enemies = enemies,
			gear = gear,
			bags = bags,
		})
		local n = 300
		local t0 = os.clock()
		for _ = 1, n do
			b:think(v, 0.1)
		end
		local ms = (os.clock() - t0) * 1000 / n
		print(string.format("  [perf] BotBrain:think, 12 heroes + 220 mice + loot: %.3f ms", ms))
		T.truthy(ms < 1, string.format("%.3f ms", ms))
	end)
end)

T.describe("BotBrain squads › in a real World", function()
	T.it("two bot squads drift together and fight: both sides take PvP damage", function()
		local w = World.new({
			rng = Rng.new(9),
			mods = Defaults.mods(),
			arenaRadius = 80,
			obstacles = {},
			enemyPool = { "mouse" },
			enemyCap = 0,
		})
		local bots = {}
		for sq = 1, 2 do
			for k = 1, 2 do
				local id = Ids.botId(sq * 10 + k)
				local x = if sq == 1 then -12 else 12
				w:addPlayer(
					id,
					Defaults.stats(),
					Defaults.weapon("bolt"),
					Defaults.ability("burst"),
					x,
					k * 2,
					sq
				)
				w:protect(id, 0)
				table.insert(bots, { id = id, brain = BotBrain.new(id, "ele_fonte", Rng.new(id)) })
			end
		end
		local hurt = { [1] = false, [2] = false }
		local t = 0
		for step = 1, 300 do
			t += 1 / 30
			if step % 3 == 1 then
				local all = {}
				for id, p in w:getPlayers() do
					table.insert(all, {
						id = id,
						x = p.x,
						z = p.z,
						downed = p.downed,
						isBot = true,
						squad = p.squad,
						protected = p.protected,
						lastHitBy = p.lastHitBy,
						lastHitAt = p.lastHitAt,
					})
				end
				for _, b in bots do
					local info = w:getPlayer(b.id)
					local i = b.brain:think({
						self = {
							x = info.x,
							z = info.z,
							hp = info.hp,
							maxHp = info.maxHp,
							downed = info.downed,
							abilityReady = t >= info.abilityReadyAt,
							squad = info.squad,
							gear = info.gear,
						},
						allies = all,
						enemies = {},
						arenaRadius = 80,
						now = t,
					}, 0.1)
					if not info.downed and not info.dead then
						w:setPlayerPosition(
							b.id,
							info.x + i.moveX * 16 * i.speedFrac * 0.1,
							info.z + i.moveZ * 16 * i.speedFrac * 0.1
						)
					end
				end
			end
			w:step(1 / 30, t)
			for _, e in w:drainEvents() do
				if e.type == "damaged" and e.by then
					hurt[w:squadOf(e.id)] = true
				end
			end
		end
		T.truthy(hurt[1] and hurt[2], "both squads traded hits")
	end)
end)

return T.finish()
