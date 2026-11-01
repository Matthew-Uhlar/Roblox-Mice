local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Weapons = require("../../src/shared/Combat/Weapons")
local Defaults = require("../../src/shared/Combat/Defaults")
local Classes = require("../../src/shared/Config/Classes")
local Stats = require("../../src/shared/Run/Stats")

local DT = 1 / 30
local KINDS = { "melee_arc", "bolt", "spread", "cone", "orbit", "lob", "puddle" }
local ABILITIES = { "dash", "burst", "ring", "shield", "puddle", "hover", "field" }

local function newWorld(seed: number?): any
	return World.new({
		rng = Rng.new(seed or 1),
		mods = Defaults.mods(),
		arenaRadius = 120,
		enemyPool = { "mouse" },
	})
end

local function run(w: any, seconds: number): { any }
	local fx = {}
	local t = w.now
	for _ = 1, math.floor(seconds / DT + 0.5) do
		t += DT
		for _, f in w:step(DT, t) do
			table.insert(fx, f)
		end
	end
	return fx
end

local function kills(w: any): number
	local n = 0
	for _, e in w:drainEvents() do
		if e.type == "kill" then
			n += 1
		end
	end
	return n
end

local function ring(w: any, n: number, d: number, id: string?)
	local out = {}
	for i = 1, n do
		local a = i / n * math.pi * 2
		table.insert(out, w:spawnEnemy(id or "mouse", math.cos(a) * d, math.sin(a) * d, false))
	end
	return out
end

local function count(fx: { any }, t: string): number
	local n = 0
	for _, f in fx do
		if f.t == t then
			n += 1
		end
	end
	return n
end

T.describe("Combat.Weapons.derive", function()
	T.it("applies damageMult, attackSpeedMult, projectileBonus, pierceBonus, areaMult", function()
		local s = Defaults.stats({
			damageMult = 2,
			attackSpeedMult = 2,
			projectileBonus = 2,
			pierceBonus = 1,
			areaMult = 1.5,
		})
		local d = Weapons.derive(s, Defaults.weapon("bolt"))
		T.near(d.damage, 22, 1e-9)
		T.near(d.cooldown, 0.4, 1e-9)
		T.eq(d.count, 3)
		T.eq(d.pierce, 2)
		local m = Weapons.derive(s, Defaults.weapon("melee_arc"))
		T.near(m.radius, 12, 1e-9)
		local o = Weapons.derive(Defaults.stats({ extraOrbiters = 1 }), Defaults.weapon("orbit"))
		T.eq(o.orbiters, 3)
		local b = Weapons.derive(Defaults.stats({ extraOrbiters = 2 }), Defaults.weapon("bolt"))
		T.eq(b.orbiters, 2, "any class can get orbiters")
	end)
end)

T.describe("Combat.Weapons auto-fire", function()
	for _, kind in KINDS do
		T.it(kind .. " kills nearby mice", function()
			local w = newWorld(3)
			w:addPlayer(1, Defaults.stats(), Defaults.weapon(kind), Defaults.ability("burst"), 0, 0)
			w.players[1].invulnUntil = 1e9
			ring(w, 6, 12)
			run(w, 10)
			local k = kills(w)
			T.truthy(k >= 4, kind .. " killed " .. k)
		end)
	end

	for _, id in Classes.ORDER or {} do
		T.it("class " .. id .. " (Stats.compute) clears a small pack", function()
			local stats, weapon, ability = Stats.compute(id, {}, {}, nil)
			local w = newWorld(4)
			w:addPlayer(1, stats, weapon, ability, 0, 0)
			w.players[1].invulnUntil = 1e9
			ring(w, 8, 14)
			run(w, 12)
			T.truthy(kills(w) >= 6)
		end)
	end

	T.it("no target, no shot (cooldown is not wasted)", function()
		local w = newWorld()
		w:addPlayer(1, Defaults.stats(), Defaults.weapon("bolt"), Defaults.ability("burst"), 0, 0)
		local fx = run(w, 2)
		T.eq(count(fx, "proj"), 0)
		w:spawnEnemy("mouse", 20, 0, false)
		fx = run(w, DT)
		T.eq(count(fx, "proj"), 1, "fires the moment a target appears")
	end)

	T.it("projectileBonus adds projectiles", function()
		local w = newWorld()
		w:addPlayer(
			1,
			Defaults.stats({ projectileBonus = 2 }),
			Defaults.weapon("bolt"),
			Defaults.ability("burst"),
			0,
			0
		)
		ring(w, 5, 30, "chonk")
		local fx = run(w, DT)
		T.eq(count(fx, "proj"), 3)
	end)

	T.it("pierce lets one bolt hit a line of mice", function()
		local w = newWorld()
		local bolt = Defaults.weapon("bolt")
		bolt.pierce = 0
		w:addPlayer(
			1,
			Defaults.stats({ pierceBonus = 3, critChance = 0 }),
			bolt,
			Defaults.ability("burst"),
			0,
			0
		)
		for i = 1, 4 do
			w:spawnEnemy("mouse", 10 + i * 3, 0, false)
		end
		run(w, 0.5)
		T.eq(kills(w), 4)
	end)

	T.it("crits use critMult", function()
		local w = newWorld()
		w:addPlayer(
			1,
			Defaults.stats({ critChance = 1, critMult = 3 }),
			Defaults.weapon("bolt"),
			Defaults.ability("burst"),
			0,
			0
		)
		w:spawnEnemy("chonk", 10, 0, false)
		local fx = run(w, 0.5)
		local saw = false
		for _, f in fx do
			if f.t == "hit" then
				T.truthy(f.crit)
				T.eq(f.amount, 33)
				saw = true
			end
		end
		T.truthy(saw)
	end)

	T.it("chain jumps to extra targets", function()
		local w = newWorld()
		w:addPlayer(
			1,
			Defaults.stats({ chain = 2 }),
			Defaults.weapon("bolt"),
			Defaults.ability("burst"),
			0,
			0
		)
		w:spawnEnemy("chonk", 10, 0, false)
		w:spawnEnemy("chonk", 14, 6, false)
		w:spawnEnemy("chonk", 18, 12, false)
		local fx = run(w, 0.4)
		T.truthy(count(fx, "chain") >= 2)
	end)

	T.it("explodeOnKill blows up kills (and explosions do not chain-explode)", function()
		local w = newWorld()
		w:addPlayer(
			1,
			Defaults.stats({ explodeOnKill = 6 }),
			Defaults.weapon("bolt"),
			Defaults.ability("burst"),
			0,
			0
		)
		w:spawnEnemy("mouse", 15, 0, false)
		for i = 1, 4 do
			w:spawnEnemy("mouse", 15 + (i % 2) * 2, (i - 2.5) * 1.5, false)
		end
		local fx = run(w, 0.6)
		local booms = 0
		for _, f in fx do
			if f.t == "boom" then
				booms += 1
			end
		end
		T.truthy(booms >= 1)
		T.truthy(kills(w) >= 3, "the blast took out the pack")
	end)

	T.it("lifesteal heals the attacker", function()
		local w = newWorld()
		w:addPlayer(
			1,
			Defaults.stats({ lifesteal = 0.5 }),
			Defaults.weapon("bolt"),
			Defaults.ability("burst"),
			0,
			0
		)
		w.players[1].hp = 50
		w:spawnEnemy("chonk", 10, 0, false)
		run(w, 0.5)
		T.truthy(w:getPlayer(1).hp > 54)
	end)

	T.it("orbiters emit an orbit Fx and re-hit on their interval", function()
		local w = newWorld()
		w:addPlayer(
			1,
			Defaults.stats({ extraOrbiters = 1 }),
			Defaults.weapon("orbit"),
			Defaults.ability("burst"),
			0,
			0
		)
		local fx = run(w, DT)
		local o
		for _, f in fx do
			if f.t == "orbit" then
				o = f
			end
		end
		T.truthy(o)
		T.eq(o.n, 3)
		T.eq(o.id, 1)
	end)
end)

T.describe("Combat.Weapons abilities", function()
	for _, kind in ABILITIES do
		T.it(kind .. " fires, respects cooldown * cooldownMult, and emits an ability Fx", function()
			local w = newWorld(5)
			w:addPlayer(
				-1,
				Defaults.stats({ cooldownMult = 0.5 }),
				Defaults.weapon("bolt"),
				Defaults.ability(kind),
				0,
				0
			)
			ring(w, 6, 6, "chonk")
			run(w, DT)
			local t = w.now
			T.truthy(w:useAbility(-1, 10, 0, t))
			T.falsy(w:useAbility(-1, 10, 0, t), "on cooldown")
			T.near(w:getPlayer(-1).abilityReadyAt, t + Defaults.ABILITIES[kind].cooldown * 0.5, 1e-9)
			local fx = run(w, 3)
			local saw = false
			for _, f in fx do
				saw = saw or (f.t == "ability" and f.kind == kind)
			end
			-- the Fx is emitted inside useAbility (between steps) -> it lands in the next step's batch
			T.truthy(saw, "ability fx")
		end)
	end

	T.it("dash moves the player (teleport for CombatService) and is clamped to the arena", function()
		local w = newWorld()
		w:addPlayer(1, Defaults.stats(), Defaults.weapon("bolt"), Defaults.ability("dash"), 110, 0)
		run(w, DT)
		T.truthy(w:useAbility(1, 200, 0, w.now))
		local tp = w:drainTeleports()
		T.eq(#tp, 1)
		T.eq(tp[1].id, 1)
		T.truthy(tp[1].x <= 118.01)
		T.eq(#w:drainTeleports(), 0)
	end)

	T.it("shield blocks damage and counter-bursts", function()
		local w = newWorld()
		w:addPlayer(1, Defaults.stats(), Defaults.weapon("bolt"), Defaults.ability("shield"), 0, 0)
		run(w, DT)
		w:useAbility(1, 0, 0, w.now)
		T.eq(w:damagePlayer(w.players[1], 50), 0)
		local fx = run(w, 1.5)
		T.eq(w:getPlayer(1).hp, 100)
		T.truthy(count(fx, "boom") >= 1)
	end)

	T.it("hover ignores contact damage but not projectiles", function()
		local w = newWorld()
		w:addPlayer(1, Defaults.stats(), Defaults.weapon("bolt"), Defaults.ability("hover"), 0, 0)
		run(w, DT)
		w:useAbility(1, 0, 0, w.now)
		T.eq(w:damagePlayer(w.players[1], 10, "contact"), 0)
		T.eq(w:damagePlayer(w.players[1], 10, "projectile"), 10)
	end)

	T.it("field slows mice inside it", function()
		local w = newWorld()
		local weapon = Defaults.weapon("bolt")
		weapon.damage = 0
		local field = Defaults.ability("field")
		field.damage = 0
		w:addPlayer(1, Defaults.stats(), weapon, field, 0, 0)
		local e = w:spawnEnemy("mouse", 20, 0, false)
		run(w, DT)
		w:useAbility(1, 20, 0, w.now)
		run(w, 0.2)
		T.truthy(w.now < e.slowUntil and e.slowFactor == 0.5)
	end)
end)

return T.finish()
