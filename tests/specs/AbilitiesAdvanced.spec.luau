--!strict
-- Iteration 6 (team Abilities): 4 more abilities per class (level 25, Prestige 3,
-- Prestige 10, Ascension node 6), a 4th ability slot (Prestige 5 or node 3) and the new
-- ability kinds chain / vortex / leap / mark (Combat/Weapons).
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local ClassProgress = require("../../src/shared/Data/ClassProgress")
local ClassAbilities = require("../../src/shared/Config/ClassAbilities")
local AscensionConfig = require("../../src/shared/Config/Ascension")
local Classes = require("../../src/shared/Config/Classes")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local Stats = require("../../src/shared/Run/Stats")
local World = require("../../src/shared/Combat/World")
local Weapons = require("../../src/shared/Combat/Weapons")
local Defaults = require("../../src/shared/Combat/Defaults")
local BotBrain = require("../../src/shared/Bots/BotBrain")

local DT = 1 / 30
local NEW_KINDS = { chain = true, vortex = true, leap = true, mark = true }

-- stomps that open node n (and every node before it) at a high enough Prestige
local function nodeStomps(node: number): number
	return (AscensionConfig.NODES[node] :: any).stomps
end

T.describe("Config: 4 advanced abilities per class", function()
	T.it("every class: 7 abilities, gates L25 / P3 / P10 / node 6, the last one ascended", function()
		local kindsUsed = {}
		for _, cid in Classes.ORDER do
			local list = ClassAbilities.forClass(cid)
			T.eq(#list, 7, cid)
			local e4, e5, e6, e7 = list[4], list[5], list[6], list[7]
			T.eq(e4.unlockLevel, 25)
			T.eq(e4.unlockPrestige, nil)
			T.eq(e5.unlockPrestige, 3)
			T.eq(e6.unlockPrestige, 10)
			T.eq(e7.unlockNode, 6)
			T.truthy((e7.def :: any).ascended, cid .. " signature is ascended")
			local kinds = {}
			for i = 4, 7 do
				local d: any = list[i].def
				T.truthy(string.sub(d.id, 1, #cid + 1) == cid .. "_", d.id)
				-- (iteration 7) a heal link (Elephaid's ascended tether) deals no damage
				T.truthy(d.cooldown >= 6 and ((d.damage > 0 and d.area > 0) or (d.heal or 0) > 0), d.id)
				kinds[d.kind] = true
				kindsUsed[d.kind] = true
			end
			local n = 0
			for _ in kinds do
				n += 1
			end
			T.truthy(n >= 3, cid .. " advanced abilities feel different (" .. n .. " kinds)")
		end
		for k in NEW_KINDS do
			T.truthy(kindsUsed[k], "kind " .. k .. " is used")
			T.truthy(Weapons.ABILITY[k] ~= nil, "Weapons implements " .. k)
		end
	end)
end)

T.describe("ClassProgress gates and slot 4", function()
	local cid = "ele_fonte"
	local list = ClassAbilities.forClass(cid)
	local L25, P3, P10, ASC = list[4].id, list[5].id, list[6].id, list[7].id

	T.it("unlocks by level, Prestige and Ascension node", function()
		T.falsy(ClassProgress.isAbilityUnlocked(cid, 24, L25))
		T.truthy(ClassProgress.isAbilityUnlocked(cid, 25, L25))
		T.falsy(ClassProgress.isAbilityUnlocked(cid, 30, P3, 2, 0))
		T.truthy(ClassProgress.isAbilityUnlocked(cid, 30, P3, 3, 0))
		T.falsy(ClassProgress.isAbilityUnlocked(cid, 30, P10, 9, 0))
		T.truthy(ClassProgress.isAbilityUnlocked(cid, 30, P10, 10, 0))
		T.falsy(ClassProgress.isAbilityUnlocked(cid, 30, ASC, 99, 5))
		T.truthy(ClassProgress.isAbilityUnlocked(cid, 30, ASC, 99, 6))
		T.eq(ClassProgress.ascNodes(99, nodeStomps(6)), 6)
		T.eq(ClassProgress.ascNodes(99, nodeStomps(6) - 1), 5)
		T.eq(#ClassProgress.unlockedAbilities(cid, 30, 99, 8), 7)
		T.eq(#ClassProgress.unlockedAbilities(cid, 30), 4)
	end)

	T.it("slot 4 at Prestige 5 or Ascension node 3; slots 1-3 unchanged", function()
		T.eq(ClassProgress.slotCount(30, 1), 3)
		T.eq(ClassProgress.slotCount(30, 4), 3)
		T.eq(ClassProgress.slotCount(30, 5), 4)
		T.eq(ClassProgress.slotCount(30, 0, 3), 4)
		T.eq(ClassProgress.slotCount(9), 1)
		T.eq(ClassProgress.slotCount(20), 3)
	end)

	T.it("a Prestige 10 profile equips an advanced ability in slot 4 and saves it", function()
		local p = ProfileSchema.default()
		p.unlockedClasses[cid] = true
		p.classes[cid] = { xp = 0, level = 30, perks = {}, prestige = 10 } :: any
		T.truthy(ClassProgress.selectAbility(p, cid, P10, 4))
		local lo = ClassProgress.loadout(cid, p.classes[cid])
		T.eq(#lo, 4)
		T.eq(lo[4], P10)
		T.deepEq({ ClassProgress.selectAbility(p, cid, ASC, 2) }, { false, "ability_locked" })
		local m = ProfileSchema.migrate(p)
		T.deepEq(ClassProgress.loadout(cid, m.classes[cid]), lo, "survives migrate")
		local v = ClassProgress.view(p)[cid]
		T.eq(v.abilitySlots, 4)
		T.eq(#v.unlockedAbilities, 6)
		-- a Prestige 4 save keeps 3 slots and loses nothing it had
		local q = ProfileSchema.default()
		q.unlockedClasses[cid] = true
		q.classes[cid] = { xp = 0, level = 30, perks = {}, prestige = 4, abilities = lo } :: any
		T.eq(#ClassProgress.loadout(cid, ProfileSchema.migrate(q).classes[cid]), 3)
	end)

	T.it("doPrestige reports the abilities and the slot it opened", function()
		local p = ProfileSchema.default()
		p.unlockedClasses[cid] = true
		p.classes[cid] = { xp = 0, level = 30, perks = {}, prestige = 4, pxp = 24000 } :: any
		local ok, _, r = ClassProgress.doPrestige(p, cid)
		T.truthy(ok)
		T.deepEq(r.slots, { 4 })
	end)

	T.it("Stats.compute returns 4 slots; slot 4 cooldown x SLOT_COOLDOWN_MULT[4]", function()
		local cs =
			{ perks = {}, level = 30, prestige = 99, stomps = 1e7, abilities = { list[1].id, L25, P3, ASC } }
		local _, _, _, abilities = Stats.compute(cid, {}, {}, nil, nil, cs)
		T.eq(#abilities, 4)
		T.eq(abilities[4].id, ASC)
		T.eq(ClassAbilities.SLOT_COOLDOWN_MULT[4], 1.35)
		T.near(abilities[4].cooldown, list[7].def.cooldown * 1.35, 1e-9)
	end)
end)

local function newWorld(seed: number): any
	return World.new({
		rng = Rng.new(seed),
		mods = Defaults.mods(),
		arenaRadius = 150,
		obstacles = {},
		enemyPool = { "mouse" },
		cycle = 1,
		stage = 1,
		enemyCap = 0,
	} :: any)
end

local function harmless(): any
	local w = Defaults.weapon("bolt")
	w.damage = 0
	return w
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

local function mice(w: any, cx: number, cz: number, n: number, spread: number): { any }
	w.cap = 200
	local out = {}
	for i = 1, n do
		local a = i / n * math.pi * 2
		local e = w:spawnEnemy("mouse", cx + math.cos(a) * spread, cz + math.sin(a) * spread)
		e.hp, e.maxHp = 1e4, 1e4
		e.speed = 0
		table.insert(out, e)
	end
	w:_rebuildHash() -- the spatial hash sees new mice from the next step on
	return out
end

local function damaged(list: { any }): number
	local n = 0
	for _, e in list do
		if e.hp < 1e4 then
			n += 1
		end
	end
	return n
end

local function def(kind: string): any
	for _, cid in Classes.ORDER do
		for _, e in ClassAbilities.forClass(cid) do
			if e.def.kind == kind then
				return table.clone(e.def)
			end
		end
	end
	error("no " .. kind)
end

T.describe("Weapons: the new kinds", function()
	T.it("chain hits jumps + 1 targets with falling damage and a path fx", function()
		local w = newWorld(1)
		local a = def("chain")
		w:addPlayer(1, Defaults.stats(), harmless(), a, 0, 0)
		run(w, DT)
		local list = mice(w, 20, 0, 10, 4)
		w.players[1].stats.critChance = 0
		T.truthy(w:useAbility(1, 20, 0, w.now))
		local fx = run(w, DT)
		T.eq(damaged(list), math.min(10, a.jumps + 1))
		local seen = nil
		for _, f in fx do
			if f.t == "ability" and f.kind == "chain" then
				seen = f
			end
		end
		T.truthy(seen and #seen.pts == a.jumps + 1, "chain fx path")
	end)

	T.it("vortex pulls mice toward its centre and ticks damage", function()
		local w = newWorld(2)
		local a = def("vortex")
		w:addPlayer(1, Defaults.stats(), harmless(), a, 0, 0)
		run(w, DT)
		local list = mice(w, 25, 0, 8, a.area * 0.8)
		local d0 = 0
		for _, e in list do
			d0 += math.sqrt((e.x - 25) ^ 2 + e.z ^ 2)
		end
		T.truthy(w:useAbility(1, 25, 0, w.now))
		run(w, a.duration + 0.3)
		local d1 = 0
		for _, e in list do
			d1 += math.sqrt((e.x - 25) ^ 2 + e.z ^ 2)
		end
		T.truthy(d1 < d0 * 0.7, string.format("pulled %.1f -> %.1f", d0, d1))
		T.eq(damaged(list), #list)
		T.truthy(list[1].hp <= 1e4 - a.damage * 4, "several ticks")
	end)

	T.it("leap: immune in the air, lands at the aim point and slams it", function()
		local w = newWorld(3)
		local a = def("leap")
		w:addPlayer(1, Defaults.stats(), harmless(), a, 0, 0)
		run(w, DT)
		local list = mice(w, 15, 0, 6, 3)
		T.truthy(w:useAbility(1, 15, 0, w.now))
		T.truthy(w.players[1].invulnUntil > w.now)
		T.eq(damaged(list), 0, "nothing until the landing")
		run(w, a.duration + 0.1)
		T.near(w.players[1].x, 15, 2.5)
		T.eq(damaged(list), #list)
		local tp = w:drainTeleports()
		T.truthy(#tp >= 1, "CombatService moves the character")
	end)

	T.it("echo / Cataclysm replay only the slam: one leap / dash distance, no new immunity", function()
		for _, kind in { "leap", "dash" } do
			local w = newWorld(7)
			local a = if kind == "leap" then def("leap") else Defaults.ability("dash")
			w:addPlayer(
				1,
				Defaults.stats({ abilityRepeat = 3, abilityEcho = 0.5 } :: any),
				harmless(),
				a,
				0,
				0
			)
			run(w, DT)
			local list = mice(w, 15, 0, 6, 3)
			T.truthy(w:useAbility(1, 60, 0, w.now))
			local inv = w.players[1].invulnUntil
			run(w, 2.5)
			T.truthy(w.players[1].x <= (a.distance or 16) + 1, kind .. " moved " .. w.players[1].x)
			T.eq(w.players[1].invulnUntil, inv, kind .. ": repeats grant no immunity")
			local _ = list
		end
	end)

	T.it("mark: nothing at once, then each marked mouse pops once", function()
		local w = newWorld(4)
		local a = def("mark")
		w:addPlayer(1, Defaults.stats(), harmless(), a, 0, 0)
		run(w, DT)
		local list = mice(w, 20, 0, 12, 3)
		w.players[1].stats.critChance = 0
		T.truthy(w:useAbility(1, 20, 0, w.now))
		run(w, a.duration * 0.5)
		T.eq(damaged(list), 0, "the fuse")
		run(w, a.duration)
		T.eq(damaged(list), #list)
		for _, e in list do
			T.truthy(1e4 - e.hp <= a.damage * (w.players[1].stats.pveDamageMult or 1) + 1e-6, "one pop each")
		end
	end)

	T.it("PvP: chain reaches a rival hero; vortex slows rivals but never moves them", function()
		local w = newWorld(5)
		w:addPlayer(1, Defaults.stats(), harmless(), def("chain"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), def("burst"), 20, 0, 2)
		run(w, DT)
		w.players[1].protectUntil, w.players[2].protectUntil = 0, 0
		w.players[1].protectPending, w.players[2].protectPending = nil, nil
		local hp0 = w.players[2].hp
		T.truthy(w:useAbility(1, 20, 0, w.now))
		T.truthy(w.players[2].hp < hp0, "chain hit the rival")
		local w2 = newWorld(6)
		w2:addPlayer(1, Defaults.stats(), harmless(), def("vortex"), 0, 0, 1)
		w2:addPlayer(2, Defaults.stats(), harmless(), def("burst"), 22, 3, 2)
		run(w2, DT)
		w2.players[1].protectUntil, w2.players[2].protectUntil = 0, 0
		w2.players[1].protectPending, w2.players[2].protectPending = nil, nil
		T.truthy(w2:useAbility(1, 22, 0, w2.now))
		run(w2, 1.1)
		T.near(w2.players[2].x, 22, 1e-9)
		T.truthy(w2.players[2].slowUntil > w2.now, "slowed")
	end)
end)

T.describe("BotBrain uses slot 4", function()
	T.it("casts the 4th slot when it is the only one ready", function()
		local brain = BotBrain.new(-1001, "ele_fonte", Rng.new(1))
		local list = ClassAbilities.forClass("ele_fonte")
		brain:setAbilities({ list[1].def, list[2].def, list[3].def, list[4].def })
		local enemies = {}
		for i = 1, 8 do
			table.insert(
				enemies,
				{ id = i, kind = 1, x = 10 + (i % 3), z = math.floor(i / 3), hpFrac = 1, flags = 0 }
			)
		end
		local intent = brain:think(
			{
				self = {
					x = 0,
					z = 0,
					hp = 100,
					maxHp = 100,
					downed = false,
					abilityReady = false,
					abilityReadySlots = { false, false, false, true },
				},
				allies = {},
				enemies = enemies,
				pickups = {},
				arenaRadius = 100,
				obstacles = {},
				now = 0,
			} :: any,
			0.1
		)
		T.eq(intent.ability and intent.ability.slot, 4)
	end)
end)

return T.finish()
