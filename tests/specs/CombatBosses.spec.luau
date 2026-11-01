local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local Bosses = require("../../src/shared/Config/Bosses")
local BossPatterns = require("../../src/shared/Combat/BossPatterns")

local DT = 1 / 30
local EPS = 1e-6

local function setup(seed: number, bossId: string): (any, any)
	local w = World.new({
		rng = Rng.new(seed),
		mods = Defaults.mods(),
		arenaRadius = 110,
		obstacles = { { x = 40, z = 40, r = 5 } },
		enemyPool = { "mouse", "rat_runner" },
	})
	local weapon = Defaults.weapon("bolt")
	weapon.damage = 0 -- keep the boss alive; we are testing its patterns
	w:addPlayer(1, Defaults.stats({ maxHp = 1e7 }), weapon, Defaults.ability("burst"), 0, 25)
	w:addPlayer(-1, Defaults.stats({ maxHp = 1e7 }), weapon, Defaults.ability("dash"), 0, -25)
	w:step(DT, DT)
	local b = w:spawnBoss(bossId, 0, 0)
	return w, b
end

-- Runs `seconds` of sim with the two participants circling; returns {time, fx} records.
local function run(w: any, seconds: number): { { t: number, f: any } }
	local out = {}
	local t = w.now
	for i = 1, math.floor(seconds / DT + 0.5) do
		t += DT
		local a = t * 0.6
		w:setPlayerPosition(1, math.cos(a) * 25, math.sin(a) * 25)
		w:setPlayerPosition(-1, math.cos(a + 2.5) * 35, math.sin(a + 2.5) * 35)
		for _, f in w:step(DT, t) do
			table.insert(out, { t = t, f = f })
		end
		if i % 30 == 0 then
			w:drainEvents()
		end
	end
	return out
end

-- Fairness: every slam / strike lands where a >= 0.6 s telegraph pointed, when it said;
-- every hostile projectile / zone / dash follows a telegraph from its caster.
local function checkTelegraphs(recs: { { t: number, f: any } }, label: string)
	local teles = {}
	for _, r in recs do
		if r.f.t == "tele" then
			T.truthy(r.f.delay >= BossPatterns.MIN_TELEGRAPH - EPS, label .. ": telegraph shorter than 0.6 s")
			table.insert(teles, r)
		end
	end
	local function matched(r: any, sameSpot: boolean): boolean
		for _, tr in teles do
			local tf = tr.f
			local lands = tr.t + tf.delay
			if tr.t <= r.t - BossPatterns.MIN_TELEGRAPH + DT + EPS and lands <= r.t + EPS then
				if sameSpot then
					if math.abs(tf.x - r.f.x) < 1e-6 and math.abs(tf.z - r.f.z) < 1e-6 and math.abs(lands - r.t) <= DT + EPS then
						return true
					end
				elseif r.t - tr.t <= 8 then
					return true
				end
			end
		end
		return false
	end
	for _, r in recs do
		local f = r.f
		if f.t == "slam" or f.t == "strike" then
			T.truthy(matched(r, true), string.format("%s: untelegraphed %s at t=%.2f", label, f.t, r.t))
		elseif (f.t == "proj" and f.hostile) or (f.t == "zone" and f.hostile) or f.t == "dash" then
			T.truthy(matched(r, false), string.format("%s: untelegraphed %s at t=%.2f", label, f.t, r.t))
		end
	end
end

local function patternIds(): { string }
	local ids = {}
	for id in BossPatterns.DEFS do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

T.describe("Combat.BossPatterns", function()
	for _, id in patternIds() do
		T.it(id .. " runs 30 s of sim, telegraphed and fair", function()
			local bossId = if id == "sister_summon" or id == "sister_spit" then "serpent_sisters" else "giant_tree"
			local w, b = setup(#id, bossId)
			w.forcePattern = id
			local recs = run(w, 33)
			T.truthy(b.alive)
			checkTelegraphs(recs, id)
			local enemies = w:enemyCount()
			T.truthy(enemies <= World.DEFAULT_CAP)
		end)
	end

	T.it("every damaging base actually hurts a player standing in it", function()
		for _, id in { "root_slam", "branch_sweep", "frost_breath", "belly_flop", "zoom_dash", "acorn_burst", "soup_spill" } do
			local w = World.new({ rng = Rng.new(2), mods = Defaults.mods(), arenaRadius = 110, enemyPool = { "mouse" } })
			local weapon = Defaults.weapon("bolt")
			weapon.damage = 0
			w:addPlayer(1, Defaults.stats({ maxHp = 1e6 }), weapon, Defaults.ability("burst"), 0, 14)
			w:step(DT, DT)
			w:spawnBoss("giant_tree", 0, 0)
			w.forcePattern = id
			local t = w.now
			local hurt = false
			for _ = 1, 30 * 12 do
				t += DT
				w:step(DT, t)
				for _, e in w:drainEvents() do
					if e.type == "damaged" and e.kind ~= "contact" then
						hurt = true
					end
				end
			end
			T.truthy(hurt, id .. " never hit a stationary player")
		end
	end)
end)

T.describe("Combat bosses", function()
	for _, bossId in Bosses.ORDER do
		T.it(bossId .. " fights through both phases for 40 s without error", function()
			local w, b = setup(1000 + #bossId, bossId)
			local used = {}
			local recs = run(w, 20)
			w:damageEnemy(b, b.maxHp * 0.55, w.players[1])
			T.eq(b.phase, 2)
			for _, r in run(w, 20) do
				table.insert(recs, r)
			end
			for _, r in recs do
				if r.f.t == "tele" or r.f.t == "roulette" or r.f.t == "adapt" then
					used[#used + 1] = r.f.t
				end
			end
			T.truthy(b.alive)
			T.truthy(#used > 5, "boss attacked")
			checkTelegraphs(recs, bossId)
		end)
	end

	T.it("Serpent Sisters raise two sister bodies (minion flag) and never more", function()
		local w, b = setup(5, "serpent_sisters")
		run(w, 6)
		local function sisters(): number
			local n = 0
			for _, s in w:snapshot() do
				if s.flags >= 8 and s.kind == b.kind then
					n += 1
				end
			end
			return n
		end
		T.eq(sisters(), 2)
		run(w, 30)
		T.truthy(sisters() <= 2)
		w:damageEnemy(b, 1e9, w.players[1])
		w:step(DT, w.now + DT)
		T.eq(sisters(), 0, "sisters die with the boss")
	end)

	T.it("Spider Machine adapts to the distance of the nearest player", function()
		local w, b = setup(6, "spider_machine")
		w:setPlayerPosition(1, 0, 9)
		w:setPlayerPosition(-1, 0, 9)
		local t = w.now
		local mode
		for _ = 1, 30 * 6 do
			t += DT
			for _, f in w:step(DT, t) do
				if f.t == "adapt" and not mode then
					mode = f.mode
				end
			end
			b.x, b.z = 0, 0
		end
		T.eq(mode, "near")
		local w2, b2 = setup(6, "spider_machine")
		w2:setPlayerPosition(1, 0, 60)
		w2:setPlayerPosition(-1, 0, 60)
		mode = nil
		t = w2.now
		for _ = 1, 30 * 6 do
			t += DT
			for _, f in w2:step(DT, t) do
				if f.t == "adapt" and not mode then
					mode = f.mode
				end
			end
			b2.x, b2.z = 0, 0
		end
		T.eq(mode, "far")
	end)

	T.it("Floating Witch spins a spell roulette", function()
		local w = setup(7, "floating_witch")
		local spells = {}
		for _, r in run(w, 40) do
			if r.f.t == "roulette" then
				spells[r.f.spell] = true
				T.truthy(#r.f.options >= 5)
			end
		end
		local n = 0
		for _ in spells do
			n += 1
		end
		T.truthy(n >= 2, "several different spells")
	end)

	T.it("boss intro: 3 s telegraph, invulnerable, then a landing slam", function()
		local w, b = setup(8, "green_gorilla")
		T.eq(w:damageEnemy(b, 10, w.players[1]), 0)
		local recs = run(w, 3.5)
		local slam = false
		for _, r in recs do
			if r.f.t == "slam" then
				slam = true
			end
		end
		T.truthy(slam)
		T.truthy(w:damageEnemy(b, 10, w.players[1]) > 0)
	end)

	T.it("killing the boss drops crumbs and vacuums the field to the party", function()
		local w, b = setup(9, "froggus")
		w:spawnPickup(80, 0, 1)
		run(w, 4)
		w:damageEnemy(b, 1e9, w.players[1])
		local xp = 0
		local t = w.now
		for _ = 1, 30 * 8 do
			t += DT
			w:step(DT, t)
			for _, e in w:drainEvents() do
				if e.type == "xp" then
					xp += e.amount
				end
			end
		end
		T.truthy(xp >= 80, "boss crumbs + far crumb collected: " .. xp)
		T.eq(w:pickupCount(), 0)
	end)
end)

return T.finish()
