--!strict
-- Iteration 2 combat hooks (docs/iter/2/PLAN.md M1, ALIGNMENT §2): the meta layer
-- (PvE-only damage, +25% PvP HP cap), gem class auras and uniques, Ascension nodes,
-- numbered waves (fronts from the storm edge, mix / HP / ramp by wave) and
-- Storm.zoneForWave.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local WaveDirector = require("../../src/shared/Combat/WaveDirector")
local Weapons = require("../../src/shared/Combat/Weapons")
local Defaults = require("../../src/shared/Combat/Defaults")
local Storm = require("../../src/shared/Config/Storm")
local AscensionNodes = require("../../src/shared/Config/AscensionNodes")
local Classes = require("../../src/shared/Config/Classes")

local DT = 1 / 30

local function newWorld(seed: number, extra: { [string]: any }?): any
	local o: any = {
		rng = Rng.new(seed),
		mods = Defaults.mods(),
		arenaRadius = 300,
		obstacles = {},
		enemyPool = { "mouse", "rat_runner", "chonk" },
		cycle = 1,
		stage = 1,
		enemyCap = 0,
		champions = false,
		carriers = false,
	}
	for k, v in extra or {} do
		o[k] = v
	end
	return World.new(o)
end

local function harmless(): any
	local w = Defaults.weapon("bolt")
	w.damage = 0
	return w
end

local function run(w: any, seconds: number): { any }
	local all = {}
	for _ = 1, math.floor(seconds / DT + 0.5) do
		for _, f in w:step(DT, w.now + DT) do
			table.insert(all, f)
		end
	end
	return all
end

T.describe("Meta layer (Prestige, Ascension, gems)", function()
	T.it("damage in a meta layer is PvE only; run mods keep damageMult", function()
		local w = newWorld(1)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:setMetaMods(1, { mul = { damageMult = 1.5 } })
		local s = w.players[1].stats
		T.eq(s.damageMult, 1)
		T.near(s.pveDamageMult, 1.5, 1e-9)
	end)
	T.it("meta max HP counts at most +25% against heroes", function()
		local w = newWorld(2)
		w:addPlayer(1, Defaults.stats({ maxHp = 100 }), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 5, 0, 2)
		w:setMetaMods(1, { mul = { maxHp = 1.6 } })
		run(w, 0.1)
		w:protect(1, 0)
		w:protect(2, 0)
		local p = w.players[1]
		T.near(p.maxHp, 160, 1e-6)
		local took = w:damageHeroFrom(p, 100, w.players[2])
		T.near(took, 100 * World.PVP_MULT * World.PVP_DAMAGE * 1.6 / World.META_HP_PVP_CAP, 1e-6)
		-- run-shop HP (not meta) is not capped
		w:setMetaMods(1, nil)
		w:setRunMods(1, { mul = { maxHp = 1.6 } })
		run(w, World.PVP_LOCKOUT + 0.05)
		T.near(w:damageHeroFrom(p, 100, w.players[2]), 100 * World.PVP_MULT * World.PVP_DAMAGE, 1e-6)
	end)
	T.it("class squad auras reach only that class in the squad (setHeroClass)", function()
		local w = newWorld(3)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 5, 0, 1)
		w:setHeroClass(1, "jumbo")
		w:setHeroClass(2, "filet")
		w:setSquadAura(1, { add = { regen = 1 } }, { jumbo = { mul = { maxHp = 1.1 } } })
		T.near(w.players[1].maxHp, 110, 1e-6)
		T.eq(w.players[2].maxHp, 100)
		T.eq(w.players[2].stats.regen, 1)
	end)
end)

T.describe("Gem uniques and Ascension behaviours", function()
	T.it("Lucky Crumb doubles PvE hits at its chance; never against heroes", function()
		local w = newWorld(4, { enemyCap = 10 })
		w:addPlayer(
			1,
			Defaults.stats({ luckyCrumb = 1 } :: any),
			harmless(),
			Defaults.ability("burst"),
			0,
			0,
			1
		)
		run(w, 0.1)
		local e = w:spawnEnemy("mouse", 8, 0)
		e.hp, e.maxHp = 1000, 1000
		w.players[1].stats.critChance = 0
		T.near(Weapons.hit(w, w.players[1], e, 10, nil), 20, 1e-9)
	end)
	T.it("Unshakable ignores slowing projectiles", function()
		for _, un in { 0, 1 } do
			local w = newWorld(5)
			w:addPlayer(
				1,
				Defaults.stats({ maxHp = 1000, unshakable = un } :: any),
				harmless(),
				Defaults.ability("burst"),
				0,
				0,
				1
			)
			run(w, 0.1)
			w:spawnEnemyProjectile(5, 0, -20, 0, 1, 5, 2, "crumb", true)
			run(w, 0.5)
			T.eq(w:getPlayer(1).slowed, un == 0, "unshakable " .. un)
		end
	end)
	T.it("abilityAreaMult grows the ability; abilityEcho casts it again", function()
		local w = newWorld(6)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		local base = w.players[1].ability.area
		w:setMetaMods(1, { mul = { abilityAreaMult = 1.2 }, add = { abilityEcho = 0.5 } })
		T.near(w.players[1].ability.area, base * 1.2, 1e-9)
		run(w, 0.1)
		T.truthy(w:useAbility(1, 10, 0, w.now))
		local casts = 0
		for _, f in run(w, 1) do
			if f.t == "ability" then
				casts += 1
			end
		end
		T.eq(casts, 2, "the cast and its echo")
	end)
	T.it("Ascension nodes: 8 per class, looks on 2 / 4 / 8, node 8 squad aura", function()
		for _, cls in Classes.ORDER do
			for n = 1, 8 do
				T.truthy(AscensionNodes.node(cls, n) ~= nil, cls .. " " .. n)
			end
		end
		local d, aura, looks = AscensionNodes.combine("elephante", "11110000")
		T.near(d.mul.maxHp, 1.08 * 1.25, 1e-9)
		T.near(d.mul.abilityAreaMult, 1.2, 1e-9)
		T.eq(aura, nil)
		T.eq(#looks, 2)
		local _, aura8, looks8 = AscensionNodes.combine("filet", 8)
		T.near(aura8.add.pveDamageMult, 0.05, 1e-9)
		T.eq(#looks8, 3)
		T.eq(AscensionNodes.node("nope", 1), nil)
	end)
end)

T.describe("Numbered waves (iteration 2)", function()
	T.it("startWave: fronts pour in from the storm edge toward the squads", function()
		local w = newWorld(7, { enemyCap = 300 })
		w:addPlayer(1, Defaults.stats({ maxHp = 1e6 }), harmless(), Defaults.ability("burst"), 50, 0, 1)
		w:addPlayer(2, Defaults.stats({ maxHp = 1e6 }), harmless(), Defaults.ability("burst"), -50, 0, 2)
		w:startWaves(150)
		w.wave.budget = -1e9 -- only the fronts
		w.wave.seeded = true
		w:setZone({ cx = 0, cz = 0, r = 200, toR = 200, closeStart = 0, closeEnd = 0, dps = 0 })
		local n = w:startWave(1)
		T.truthy(n > 0, "front mice " .. n)
		run(w, 0.1)
		local first = w:enemyCount()
		T.truthy(first > 0 and first < n, "the first burst only")
		for _, e in w.enemies do
			local d = math.sqrt(e.x ^ 2 + e.z ^ 2)
			T.truthy(d > 150 and d <= 200, "at the storm edge " .. d)
		end
		run(w, World.FRONT_TIME)
		T.truthy(w:enemyCount() >= n - 2, "all bursts arrived")
		T.eq(w:startWave(5), 0, "boss wave: no fronts")
	end)
	T.it("mix, HP and ramp follow the wave number", function()
		local w = newWorld(8, { enemyCap = 50 })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:startWave(1)
		for _ = 1, 30 do
			T.eq(w.wave:pickKind(), "mouse", "wave 1: plain mice only")
		end
		T.eq(w.wave:waveRamp(), 1)
		w:startWave(4)
		local e = w:spawnEnemy("mouse", 20, 0)
		T.near(e.maxHp, e.def.hp * (1 + World.WAVE_HP_STEP * 3), 1e-6)
		local saw = false
		for _ = 1, 100 do
			saw = saw or w.wave:pickKind() == "chonk"
		end
		T.truthy(saw, "wave 4 unlocks the tough mice")
		w:startWave(19)
		T.near(w.wave:waveRamp(), WaveDirector.PER_HERO_RAMP, 1e-9)
		T.eq(w.stageWave, 4)
	end)
	T.it("Storm.zoneForWave: circles close during waves 2-4; the boss wave holds", function()
		local R = 400
		local z1 = Storm.zoneForWave(R, 1, 1, 3)
		T.eq(z1.r, R)
		T.eq(Storm.radiusAt(z1, 20), R)
		local z2 = Storm.zoneForWave(R, 1, 2, 3)
		T.eq(z2.r, R)
		T.near(z2.toR, 0.65 * R, 1e-9)
		T.eq(z2.closeEnd, Storm.WAVE_SECONDS)
		local z4 = Storm.zoneForWave(R, 1, 4, 3)
		T.near(z4.r, 0.4 * R, 1e-9)
		T.near(z4.toR, 0.22 * R, 1e-9)
		T.eq(z4.dps, 0.08)
		local z5 = Storm.zoneForWave(R, 1, 5, 3)
		T.near(z5.r, 0.22 * R, 1e-9)
	end)
end)

return T.finish()
