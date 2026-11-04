--!strict
-- POIs + portal in whole headless v2 matches (tests/sim/Headless.luau, POIs on
-- by default), mirroring RunDirector: bots walk to and channel the contested
-- POIs, rewards land on the finding squad, the portal pulls the heroes into the
-- next arena.
local T = require("../lib/Test")
local H = require("../sim/Headless")
local RunState = require("../../src/shared/Run/RunState")
local Pois = require("../../src/shared/Combat/Pois")

local SEEDS = { 11, 22, 33, 44, 55, 66 }

local function stay(): string
	return "Stay"
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
			local sim = H.new({ seed = seed, maxStages = 2 })
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
	T.it("cache cheese goes to every member of the finding squad at once (Pressure applied)", function()
		local sim = H.new({ seed = 12, maxStages = 1, onTick = quickWin(), extractPolicy = stay })
		sim:playRun()
		local h = sim.human
		T.truthy(sim.match:isInRun(h.id), "the human's squad stayed")
		local poisBefore = sim.match:member(h.id).pois
		local before = {}
		for _, m in sim.members do
			before[m.id] = sim.match:shareOf(m.id)
		end
		sim:_poiReward({ type = "poiReward", kind = "cheese_cache", by = h.id, cheese = 40 })
		local amount = RunState.applyPressureCheese(40, sim.match:pressurePoints())
		for _, m in sim.members do
			local want = if m.squad == h.squad and sim.match:isInRun(m.id)
				then before[m.id] + amount
				else before[m.id]
			T.eq(sim.match:shareOf(m.id), want, "share of " .. m.id)
		end
		T.eq(sim.match:member(h.id).pois, poisBefore + 1, "the POI counts for the finder's class XP")
	end)
	T.it("same seed, same run (with POIs)", function()
		local function go(): string
			return H.digest(
				H.new({ seed = 77, humans = { { classId = "ele_fonte" } }, maxStages = 2 }):playRun()
			)
		end
		T.eq(go(), go())
	end)
end)

T.describe("Integration › shrine buffs and rewards", function()
	T.it("a shrine buff raises the finding squad's stats in the world and expires", function()
		local sim = H.new({ seed = 5, maxStages = 1, onTick = quickWin(), extractPolicy = stay })
		sim:playRun()
		local m = sim.human
		local base = m.stats.moveSpeed
		sim:_poiReward({
			type = "poiReward",
			kind = "shrine_swift",
			by = m.id,
			buff = { kind = "shrine_swift", stat = "moveSpeed", mul = 1.25, untilT = sim.now + 45 },
		})
		T.near(sim.world:getPlayer(m.id).moveSpeed, base * 1.25, 1e-6)
		for _, o in sim.members do
			if o.squad ~= m.squad and sim.world:getPlayer(o.id) and sim.match:isInRun(o.id) then
				T.near(sim.world:getPlayer(o.id).moveSpeed, o.stats.moveSpeed, 1e-6, "other squads unchanged")
			end
		end
		sim.now += 46
		T.truthy(Pois.pruneBuffs(sim.buffs[m.squad], sim.now))
		sim:_refreshStats()
		T.near(sim.world:getPlayer(m.id).moveSpeed, base, 1e-6)
	end)
	T.it("elite chest and Pantry give the finding squad a pick; the statue refills Second Wind", function()
		local sim = H.new({
			seed = 6,
			humans = { { classId = "elephante" } },
			maxStages = 1,
			onTick = quickWin(),
			extractPolicy = stay,
		})
		sim:playRun()
		local h = sim.human
		local picks = {}
		for _, m in sim.members do
			picks[m.id] = #m.picks
		end
		local function mine(m: any): boolean
			return m.squad == h.squad and sim.match:isInRun(m.id)
		end
		sim:_poiReward({ type = "poiReward", kind = "elite_camp", by = h.id })
		for _, m in sim.members do
			T.eq(#m.picks, picks[m.id] + (if mine(m) then 1 else 0), "chest pick for " .. m.id)
		end
		sim:_poiReward({ type = "poiReward", kind = "grandmas_pantry", cards = 3, by = h.id })
		for _, m in sim.members do
			if mine(m) then
				local last = m.picks[#m.picks]
				T.eq(#m.picks, picks[m.id] + 2)
				local def = (require :: any)("../../src/shared/Config/Upgrades").get(last)
				T.eq(def.rarity, "Epic", "Pantry pick is Epic")
			end
		end
		h.freeSecondWindUsed = true
		sim:_poiReward({ type = "poiReward", kind = "lost_herd_statue", revived = 0, by = h.id })
		T.eq(h.freeSecondWindUsed, false)
	end)
end)

T.describe("Integration › portal", function()
	T.it("opens after the boss, pulls the heroes in, and the next arena follows", function()
		local seen =
			{ open = false, pulled = false, startD = nil :: number?, endD = nil :: number?, leaked = false }
		local sim = H.new({
			seed = 9,
			maxStages = 2,
			extractPolicy = stay,
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
					local p = s.world:getPlayer(s.human.id)
					local d = math.sqrt((p.x - portal.x) ^ 2 + (p.z - portal.z) ^ 2)
					seen.startD = seen.startD or d
					seen.endD = d
				end
			end),
		})
		local r = sim:playRun()
		T.eq(#r.stages, 2)
		T.truthy(seen.open, "portal opened after the boss")
		T.truthy(seen.pulled, "the heroes were pulled")
		T.truthy((seen.endD :: number) < (seen.startD :: number), "bots walk into the portal")
		T.falsy(seen.leaked, "a fresh arena has no portal during its waves")
	end)
end)

return T.finish()
