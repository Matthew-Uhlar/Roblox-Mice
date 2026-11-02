--!strict
-- POIs + portal in whole headless runs (tests/sim/Headless.luau with opts.pois),
-- mirroring RunDirector: bots walk to and channel POIs, rewards land, the portal
-- pulls the party into the next arena.
local T = require("../lib/Test")
local H = require("../sim/Headless")
local Rng = require("../../src/shared/Util/Rng")
local RunState = require("../../src/shared/Run/RunState")
local BotRoster = require("../../src/shared/Bots/BotRoster")
local Pois = require("../../src/shared/Combat/Pois")

local SEEDS = { 11, 22, 33, 44, 55, 66 }

local function party(humanClasses: { string }, seed: number): { any }
	local out = {}
	for _, c in humanClasses do
		table.insert(out, { classId = c, isBot = false })
	end
	for _, b in BotRoster.fill(#humanClasses, 4, 3, humanClasses, Rng.new(seed)) do
		table.insert(out, { classId = b.classId, isBot = true })
	end
	return out
end

-- God mode + the boss dies 20 s after it spawns: stage flow without balance noise.
local function quickWin(extra: ((any, string) -> ())?)
	return function(sim: any, phase: string)
		for _, p in sim.world.playerList do
			if not p.downed and not p.dead then
				p.hp = p.maxHp
			end
		end
		local boss = sim.world.boss
		if phase == "Boss" and boss and boss.alive and sim.now - sim.bossSpawnAt >= 20 then
			sim.world:damageEnemy(boss, boss.hp + 1, nil)
		end
		if extra then
			extra(sim, phase)
		end
	end
end

local function sumMap(m: { [string]: number }): number
	local n = 0
	for _, v in m do
		n += v
	end
	return n
end

T.describe("Integration › POIs in whole runs", function()
	T.it("bots walk to and activate POIs in real (unassisted) runs", function()
		local runsWithActivation, total = 0, 0
		local byKind: { [string]: number } = {}
		for _, seed in SEEDS do
			local sim = H.new({ seed = seed, party = party({}, seed), pois = true, maxStages = 2 })
			local r = sim:playRun()
			local n = 0
			for _, s in r.stages do
				T.truthy(s.pois ~= nil and #s.pois >= 8, "every stage gets its POI slots")
				n += sumMap(s.poiActivated)
				for k, v in s.poiActivated do
					byKind[k] = (byKind[k] or 0) + v
				end
			end
			total += n
			if n > 0 then
				runsWithActivation += 1
			end
			print(string.format("  seed %d -> %s, %d POI activations", seed, r.outcome, n))
		end
		local kinds = {}
		for k, v in byKind do
			table.insert(kinds, k .. "=" .. v)
		end
		table.sort(kinds)
		print("  [pois] activations by kind: " .. table.concat(kinds, " "))
		T.truthy(
			runsWithActivation >= 3,
			"POIs activated in " .. runsWithActivation .. "/" .. #SEEDS .. " runs"
		)
		T.truthy(total > 0)
	end)
	T.it("cache cheese joins the pending pot at the boss kill", function()
		local found = false
		for _, seed in SEEDS do
			local sim = H.new({
				seed = seed,
				party = party({}, seed),
				pois = true,
				maxStages = 1,
				onTick = quickWin(),
				bankPolicy = function()
					return "Continue"
				end,
			})
			local r = sim:playRun()
			local s = r.stages[1]
			T.eq(s.pendingAfter, RunState.stageCheese(1, 1, 1.0, false) + s.poiCheese)
			if s.poiCheese > 0 then
				found = true
			end
		end
		T.truthy(found, "some run opened a cache")
	end)
	T.it("same seed, same run (with POIs)", function()
		local function go(): string
			return H.digest(
				H.new({ seed = 77, party = party({ "ele_fonte" }, 77), pois = true, maxStages = 2 }):playRun()
			)
		end
		T.eq(go(), go())
	end)
end)

T.describe("Integration › shrine buffs and rewards", function()
	T.it("a shrine buff raises the party's stats in the world and expires", function()
		local sim = H.new({ seed = 5, party = party({}, 5), pois = true, maxStages = 1, onTick = quickWin() })
		sim:playRun()
		-- drive one directly through the same reward path RunDirector uses
		local m = sim.members[1]
		local base = m.stats.moveSpeed
		sim:_poiReward({
			type = "poiReward",
			kind = "shrine_swift",
			buff = { kind = "shrine_swift", stat = "moveSpeed", mul = 1.25, untilT = sim.now + 45 },
		})
		T.near(sim.world:getPlayer(m.id).moveSpeed, base * 1.25, 1e-6)
		sim.now += 46
		T.truthy(Pois.pruneBuffs(sim.buffs, sim.now))
		sim:_refreshStats()
		T.near(sim.world:getPlayer(m.id).moveSpeed, base, 1e-6)
	end)
	T.it("elite chest and Pantry give every participant a pick; the statue refills Second Wind", function()
		local sim = H.new({
			seed = 6,
			party = party({ "elephante" }, 6),
			pois = true,
			maxStages = 1,
			onTick = quickWin(),
		})
		sim:playRun()
		local picks = {}
		for _, m in sim.members do
			picks[m.id] = #m.picks
		end
		sim:_poiReward({ type = "poiReward", kind = "elite_camp" })
		for _, m in sim.members do
			T.eq(#m.picks, picks[m.id] + 1, "chest pick")
		end
		sim:_poiReward({ type = "poiReward", kind = "grandmas_pantry", cards = 3 })
		for _, m in sim.members do
			local last = m.picks[#m.picks]
			T.eq(#m.picks, picks[m.id] + 2)
			local def = (require :: any)("../../src/shared/Config/Upgrades").get(last)
			T.eq(def.rarity, "Epic", "Pantry pick is Epic")
		end
		sim.members[1].freeSecondWindUsed = true
		sim:_poiReward({ type = "poiReward", kind = "lost_herd_statue", revived = 0 })
		T.eq(sim.members[1].freeSecondWindUsed, false)
	end)
end)

T.describe("Integration › portal", function()
	T.it("opens after the boss, pulls the party in, and the next arena follows", function()
		local seen =
			{ open = false, pulled = false, startD = nil :: number?, endD = nil :: number?, leaked = false }
		local sim = H.new({
			seed = 9,
			party = party({}, 9),
			pois = true,
			maxStages = 2,
			onTick = quickWin(function(s: any, phase: string)
				local portal = s.world:portal()
				if phase == "StageClear" and portal and portal.phase == "open" then
					seen.open = true
				end
				if phase == "Waves" and portal then
					seen.leaked = true
				end
				if phase == "Portal" and portal and portal.phase == "pull" then
					seen.pulled = true
					local p = s.world:getPlayer(s.members[1].id)
					local d = math.sqrt((p.x - portal.x) ^ 2 + (p.z - portal.z) ^ 2)
					seen.startD = seen.startD or d
					seen.endD = d
				end
			end),
			bankPolicy = function()
				return "Continue"
			end,
		})
		local r = sim:playRun()
		T.eq(#r.stages, 2)
		T.truthy(seen.open, "portal opened after the boss")
		T.truthy(seen.pulled, "the party was pulled")
		T.truthy((seen.endD :: number) < (seen.startD :: number), "bots walk into the portal")
		T.falsy(seen.leaked, "a fresh arena has no portal during its waves")
	end)
end)

return T.finish()
