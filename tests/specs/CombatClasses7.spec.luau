--!strict
-- Iteration 7 (docs/iter/7/PLAN.md §A, team Classes): the 9th-11th classes, Ele Vation
-- (Marksman, `lance`), Elephaid (Field Medic, `tether`) and Trunkillery (Artillery,
-- `anchor`). Kits are wired through every per-class table, the new kinds behave in the
-- World (PvP rules included) and BotBrain uses them.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Weapons = require("../../src/shared/Combat/Weapons")
local Defaults = require("../../src/shared/Combat/Defaults")
local Stats = require("../../src/shared/Run/Stats")
local Classes = require("../../src/shared/Config/Classes")
local ClassAbilities = require("../../src/shared/Config/ClassAbilities")
local ClassPerks = require("../../src/shared/Config/ClassPerks")
local ClassSkins = require("../../src/shared/Config/ClassSkins")
local AscensionNodes = require("../../src/shared/Config/AscensionNodes")
local RunShop = require("../../src/shared/Config/RunShop")
local Evolutions = require("../../src/shared/Config/Evolutions")
local Challenges = require("../../src/shared/Config/Challenges")
local Gems = require("../../src/shared/Config/Gems")
local GemEffects = require("../../src/shared/Config/GemEffects")
local BotRoster = require("../../src/shared/Bots/BotRoster")
local BotBrain = require("../../src/shared/Bots/BotBrain")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local Passes = require("../../src/shared/Data/Passes")
local Ids = require("../../src/shared/Util/Ids")

local DT = 1 / 30
local NEW = { "ele_vation", "elephaid", "trunkillery" }
local KIND = { ele_vation = "lance", elephaid = "tether", trunkillery = "anchor" }
local AUTO_AIM_RANGE = 70 -- client/Controllers/InputController AUTO_AIM_RANGE

local function newWorld(seed: number?): any
	return World.new({
		rng = Rng.new(seed or 7),
		mods = Defaults.mods(),
		arenaRadius = 300,
		obstacles = {},
		enemyPool = { "mouse" },
		cycle = 1,
		stage = 1,
		enemyCap = 200,
		champions = false,
		carriers = false,
	})
end

-- A hero of `classId` with these ability ids in its slots (default: the base only).
local function addHero(
	w: any,
	classId: string,
	id: number,
	x: number,
	z: number,
	squad: number?,
	abilityIds: { string }?,
	harmless: boolean?
): any
	local s, wpn, a = Stats.compute(classId, {}, {})
	wpn = table.clone(wpn)
	if harmless then
		wpn.damage = 0
	end
	w:addPlayer(id, s, wpn, a, x, z, squad or 1)
	if abilityIds then
		local list = {}
		for _, aid in abilityIds do
			table.insert(list, ClassAbilities.defCopy(aid) :: any)
		end
		w:setPlayerAbilities(id, list)
	end
	w:protect(id, 0)
	return w.players[id]
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

local function abilityFx(list: { any }, kind: string): { any }
	local out = {}
	for _, f in list do
		if f.t == "ability" and f.kind == kind then
			table.insert(out, f)
		end
	end
	return out
end

local function tank(e: any): any
	e.hp, e.maxHp = 1e6, 1e6
	e.speed = 0
	return e
end

T.describe("Iteration 7 class kits", function()
	T.it("are classes 9-11: cheese 6000 or the stomp track, never a Robux pass", function()
		for i, cid in NEW do
			T.eq(Classes.ORDER[8 + i], cid)
			local def = Classes.get(cid) :: any
			T.eq(def.unlockCost, 6000, cid)
			T.truthy(def.noPassUnlock, cid)
			T.eq(def.ability.kind, KIND[cid], cid)
			local free = nil
			for _, u in Evolutions.FREE_UNLOCKS do
				if u.classId == cid then
					free = u
				end
			end
			T.truthy(free and free.stomps > 80000, cid .. " free stomp unlock")
		end
		local p = ProfileSchema.default()
		Passes.apply(p, "founders")
		for _, cid in NEW do
			T.falsy(p.unlockedClasses[cid], cid .. " never granted by Founders")
		end
	end)
	T.it("have 7 abilities each (base, L5, L15, L25, P3, P10, ascended) with one new kind", function()
		for _, cid in NEW do
			local list = ClassAbilities.forClass(cid)
			T.eq(#list, 7, cid)
			T.eq(list[1].def.kind, KIND[cid])
			T.truthy((list[7].def :: any).ascended, cid .. " signature")
			local newKinds = 0
			for _, e in list do
				T.eq(e.classId, cid)
				T.truthy(Weapons.ABILITY[e.def.kind] ~= nil, e.id .. " kind implemented")
				if e.def.kind == "lance" or e.def.kind == "tether" or e.def.kind == "anchor" then
					T.eq(e.def.kind, KIND[cid], e.id .. ": only the class's own new kind")
					newKinds += 1
				end
			end
			T.truthy(newKinds >= 1, cid)
		end
		T.eq(ClassAbilities.forClass("ele_vation")[7].def.kind, "lance")
		T.eq(ClassAbilities.forClass("elephaid")[7].def.kind, "tether")
		T.eq((ClassAbilities.forClass("elephaid")[7].def :: any).revive, 1)
	end)
	T.it("have a passive, a 3 x 9 talent tree with keystones and 8 ascension flavours", function()
		for _, cid in NEW do
			local def = Classes.get(cid) :: any
			T.truthy(#def.passiveText > 10, cid)
			local branches = ClassPerks.branches(cid)
			T.eq(#branches, 3, cid)
			for _, b in branches do
				T.eq(#b.nodes, 9, cid .. " " .. b.id)
				T.eq(b.keystone.kind, "keystone")
				T.truthy(#b.keystone.description > 0)
			end
			for n = 1, 8 do
				T.truthy(AscensionNodes.node(cid, n), cid .. " node " .. n)
				T.truthy(#AscensionNodes.describe(cid, n) > 0)
			end
			T.truthy(RunShop.CLASS_BUFFS[cid], cid .. " class buff")
			T.truthy(BotRoster.CLASS_ROLES[cid], cid .. " bot role")
		end
		local s = Stats.compute("ele_vation", {}, {})
		T.near(s.steadyAim :: number, 0.3)
		local m = Stats.compute("elephaid", {}, {})
		T.near(m.allyHealShare :: number, 0.15)
		T.near(m.reviveSpeedMult :: number, 2)
		local a = Stats.compute("trunkillery", {}, {})
		T.eq(a.unshakable, 1)
		T.near(a.areaMult, 1.15)
	end)
	T.it("have a class gem unique each (and the Tinkerphant now has one)", function()
		for _, cid in { "tinkerphant", "ele_vation", "elephaid", "trunkillery" } do
			local u = Gems.unique("u_" .. cid)
			T.truthy(u, cid)
			T.eq((u :: any).classId, cid)
			T.truthy(GemEffects.UNIQUES["u_" .. cid], cid .. " effect")
		end
	end)
	T.it("have 4 earned skins each and no paid sets; a Lone Tusk challenge each", function()
		for _, cid in NEW do
			local list = ClassSkins.forClass(cid)
			T.eq(#list, 4, cid)
			for _, sk in list do
				T.eq(sk.source, "level")
				T.truthy(ClassSkins.ACCESSORIES[sk.accessory], sk.id)
			end
			T.truthy(ClassSkins.NO_PAID[cid])
			local found = false
			for _, c in Challenges.LIST do
				if c.id == "lone_tusk_" .. cid then
					found = true
				end
			end
			T.truthy(found, cid .. " challenge")
		end
	end)
	T.it("keep weapon ranges inside the client's ability auto-aim range", function()
		for _, cid in NEW do
			local r = (Classes.get(cid) :: any).weapon.range
			T.truthy(r <= AUTO_AIM_RANGE, cid)
		end
		local r = (Classes.get("ele_vation") :: any).weapon.range * (1 + Weapons.STEADY_RANGE)
		T.truthy(r <= AUTO_AIM_RANGE, "Steady Trunk range " .. r)
	end)
end)

T.describe("lance (Ele Vation)", function()
	T.it("telegraphs, then hits every mouse on the line once (and nothing off it)", function()
		local w = newWorld(1)
		local p = addHero(w, "ele_vation", 1, 0, 0, 1, nil, true)
		local on, off = {}, {}
		for k = 1, 6 do
			table.insert(on, tank(w:spawnEnemy("mouse", 12 * k, 0)))
		end
		table.insert(off, tank(w:spawnEnemy("mouse", 40, 15)))
		run(w, 0.1)
		T.truthy(w:useAbility(1, 100, 0, w.now))
		local fx = run(w, 0.2)
		T.eq(#abilityFx(fx, "lance_aim"), 1, "the laser sight (rivals see it)")
		for _, e in on do
			T.eq(e.hp, 1e6, "no damage during the laser sight")
		end
		fx = run(w, 0.3)
		T.eq(#abilityFx(fx, "lance"), 1)
		for _, e in on do
			T.truthy(e.hp < 1e6, "hit on the line")
		end
		for _, e in off do
			T.eq(e.hp, 1e6, "off the line")
		end
		T.truthy(p.abilityReadyAt > w.now)
	end)
	T.it("the ascended Sky Splitter leaves a burning line", function()
		local w = newWorld(2)
		addHero(w, "ele_vation", 1, 0, 0, 1, { "ele_vation_sky_splitter" }, true)
		local fx = run(w, 0.1)
		T.truthy(w:useAbility(1, 100, 0, w.now))
		fx = run(w, 0.5)
		local shot = abilityFx(fx, "lance")[1]
		T.truthy(shot and shot.burn == 3 and shot.ascended, "burn + ascended on the Fx")
		local e = tank(w:spawnEnemy("mouse", 60, 0))
		run(w, 1.2)
		T.truthy(e.hp < 1e6, "the burning line ticks")
	end)
	T.it("hits enemy heroes with the class pvpMult, never squadmates", function()
		local w = newWorld(3)
		addHero(w, "ele_vation", 1, 0, 0, 1, nil, true)
		local mate = addHero(w, "elephante", 2, 20, 0, 1, nil, true)
		local foe = addHero(w, "elephante", 3, 40, 0, 2, nil, true)
		run(w, 0.1)
		T.truthy(w:useAbility(1, 100, 0, w.now))
		run(w, 0.5)
		T.eq(mate.hp, mate.maxHp, "no friendly fire")
		local lost = foe.maxHp - foe.hp
		local s = Stats.compute("ele_vation", {}, {})
		local expect = 70
			* s.damageMult
			* World.PVP_MULT
			* World.PVP_DAMAGE
			* (Classes.get("ele_vation") :: any).weapon.pvpMult
		T.truthy(lost > 0 and lost <= expect + 0.5, string.format("PvP hit %.1f (max %.1f)", lost, expect))
	end)
end)

T.describe("tether (Elephaid)", function()
	T.it("heals the linked squadmate every tick; links to herself at half rate when alone", function()
		local w = newWorld(4)
		addHero(w, "elephaid", 1, 0, 0, 1, nil, true)
		local mate = addHero(w, "elephante", 2, 10, 0, 1, nil, true)
		run(w, 0.1)
		mate.hp = mate.maxHp * 0.3
		T.truthy(w:useAbility(1, 10, 0, w.now))
		local fx = run(w, 1.05)
		local link = abilityFx(fx, "tether")
		T.truthy(#link == 0 or link[1].target == 2)
		T.near(mate.hp, mate.maxHp * (0.3 + 0.04 * 2), 0.5, "2 ticks of 4%")
		-- alone: the caster heals herself at TETHER_SELF
		local w2 = newWorld(5)
		local me = addHero(w2, "elephaid", 1, 0, 0, 1, nil, true)
		run(w2, 0.1)
		me.hp = me.maxHp * 0.5
		T.truthy(w2:useAbility(1, 30, 0, w2.now))
		run(w2, 1.05)
		T.near(me.hp, me.maxHp * (0.5 + 0.04 * Weapons.TETHER_SELF * 2), 0.5)
	end)
	T.it("breaks beyond the break range and never heals an enemy hero", function()
		local w = newWorld(6)
		addHero(w, "elephaid", 1, 0, 0, 1, nil, true)
		local mate = addHero(w, "elephante", 2, 10, 0, 1, nil, true)
		local foe = addHero(w, "elephante", 3, 5, 0, 2, nil, true)
		run(w, 0.1)
		mate.hp, foe.hp = 50, 50
		T.truthy(w:useAbility(1, 10, 0, w.now))
		run(w, 0.55)
		local after1 = mate.hp
		T.truthy(after1 > 50)
		w:setPlayerPosition(2, 80, 0)
		local fx = run(w, 1)
		T.near(mate.hp, after1, 0.01, "no heal once broken")
		local ends = abilityFx(fx, "tether_end")
		T.truthy(#ends == 1 and ends[1].reason == "broken")
		T.eq(foe.hp, 50, "enemy heroes are never healed")
	end)
	T.it("heals a hero hit by a rival at half rate (PvP heal rule)", function()
		local w = newWorld(7)
		addHero(w, "elephaid", 1, 0, 0, 1, nil, true)
		local mate = addHero(w, "elephante", 2, 10, 0, 1, nil, true)
		run(w, 0.1)
		mate.hp = 50
		mate.pvpRegenUntil = w.now + 10
		T.truthy(w:useAbility(1, 10, 0, w.now))
		run(w, 0.55)
		T.near(mate.hp, 50 + mate.maxHp * 0.04 * Weapons.PVP_HEAL_MULT, 0.3)
	end)
	T.it("the ascended link revives one downed squadmate (once per 90 s) and clears slows", function()
		local w = newWorld(8)
		addHero(w, "elephaid", 1, 0, 0, 1, { "elephaid_herd_heartbeat" }, true)
		local a = addHero(w, "elephante", 2, 10, 0, 1, nil, true)
		local b = addHero(w, "elephante", 3, -10, 0, 1, nil, true)
		run(w, 0.1)
		w:_down(a, nil)
		b.slowUntil = w.now + 10
		T.truthy(a.downed)
		T.truthy(w:useAbility(1, 0, 0, w.now))
		local fx = run(w, 0.1)
		T.falsy(a.downed, "revived")
		T.truthy(b.slowUntil <= w.now, "slow cleared")
		T.eq(#abilityFx(fx, "tether_revive"), 1)
		w:_down(a, nil)
		run(w, 20)
		T.truthy(w:useAbility(1, 0, 0, w.now))
		run(w, 0.1)
		T.truthy(a.downed or a.dead, "no second revive inside the cooldown")
	end)
	T.it(
		"Bedside Manner: her damage heals the lowest-HP squadmate nearby; Rescue Hop helps revives",
		function()
			local w = newWorld(9)
			local me = addHero(w, "elephaid", 1, 0, 0, 1)
			local mate = addHero(w, "elephante", 2, 8, 0, 1, nil, true)
			for k = 1, 8 do
				tank(w:spawnEnemy("mouse", 15 + k, 5))
			end
			run(w, 0.1)
			mate.hp = mate.maxHp * 0.5
			local before = mate.hp
			run(w, 3)
			T.truthy(mate.hp > before, "healed by her shots")
			T.truthy(w:meter()[1].heal > 0, "credited to the medic's meter")
			-- Rescue Hop
			local w2 = newWorld(10)
			addHero(w2, "elephaid", 1, 0, 0, 1, { "elephaid_rescue_hop" }, true)
			local down = addHero(w2, "elephante", 2, 25, 0, 1, nil, true)
			run(w2, 0.1)
			w2:_down(down, nil)
			T.truthy(w2:useAbility(1, 25, 0, w2.now))
			run(w2, 0.6)
			T.truthy(
				down.reviveProgress >= World.REVIVE_TIME * 0.5 or not down.downed,
				"half a revive on landing"
			)
			local _ = me
		end
	)
end)

T.describe("anchor (Trunkillery)", function()
	T.it("roots the hero, boosts the mortar and armour, and a recast digs out", function()
		local w = newWorld(11)
		local p = addHero(w, "trunkillery", 1, 0, 0, 1, nil, true)
		run(w, 0.1)
		local d0 = p.derived
		T.truthy(w:useAbility(1, 0, 0, w.now))
		T.truthy(w:getPlayer(1).anchored)
		local d = Weapons.stanceDerived(w, p, d0, w.now)
		T.near(d.range, d0.range * 1.6, 0.01)
		T.near(d.damage, d0.damage * 1.5, 0.01)
		T.near(d.radius, d0.radius * 1.3, 0.01)
		T.eq(Weapons.anchorArmor(p, w.now), 3)
		local x, z = w:setPlayerPosition(1, 10, 0)
		T.eq(x, 0, "rooted")
		T.eq(z, 0)
		-- mice hit for 3 less
		local taken = w:damagePlayer(p, 20, "contact")
		T.near(taken, 20 - (p.stats.armor + 3), 0.01)
		run(w, 1)
		T.falsy(w:useAbility(1, 0, 0, w.now), "a recast digs out; it is not a cast (no quest tick)")
		run(w, Weapons.ANCHOR_UNROOT + 0.1)
		T.falsy(w:getPlayer(1).anchored, "dug out")
		x = w:setPlayerPosition(1, 10, 0)
		T.eq(x, 10, "walks again")
		T.truthy(w.now < p.abilityReadyAt, "the dig-out does not reset the cooldown")
	end)
	T.it("expires after its duration; a leap digs out", function()
		local w = newWorld(12)
		local p =
			addHero(w, "trunkillery", 1, 0, 0, 1, { "trunkillery_dig_in", "trunkillery_recoil_hop" }, true)
		run(w, 0.1)
		T.truthy(w:useAbility(1, 0, 0, w.now))
		local fx = run(w, 8.2)
		T.falsy(w:getPlayer(1).anchored)
		T.truthy(#abilityFx(fx, "anchor_end") >= 1)
		run(w, 2)
		T.truthy(w:useAbility(1, 0, 0, w.now))
		T.truthy(w:useAbility(1, 20, 0, w.now, 2), "Recoil Hop")
		T.falsy(w:getPlayer(1).anchored)
		run(w, 0.7)
		T.truthy(p.x < -15, "hopped away from the aim point: " .. p.x)
	end)
	T.it("Grand Bombardment hits harder while dug in", function()
		local function zoneDmg(dug: boolean): number
			local w = newWorld(13)
			addHero(
				w,
				"trunkillery",
				1,
				0,
				0,
				1,
				{ "trunkillery_dig_in", "trunkillery_grand_bombardment" },
				true
			)
			run(w, 0.1)
			if dug then
				w:useAbility(1, 0, 0, w.now)
			end
			T.truthy(w:useAbility(1, 30, 0, w.now, 2))
			local z = w.zones[#w.zones]
			return z.dmg
		end
		T.near(zoneDmg(true) / zoneDmg(false), 1.35, 0.01)
	end)
end)

T.describe("Steady Trunk (Ele Vation)", function()
	T.it(
		"PvP: the cap is fixed at fire time (steady shot then moving stays capped; Long Shot is never cut)",
		function()
			local function shot(steadyAim: number, moveAfter: boolean, lance: boolean): number
				local w = newWorld(41)
				local p = addHero(w, "ele_vation", 1, 0, 0, 1)
				p.stats = table.clone(p.stats)
				p.stats.steadyAim = steadyAim
				p.stats.critChance = 0
				local foe = addHero(w, "elephante", 2, 30, 0, 2, nil, true)
				foe.stats = table.clone(foe.stats)
				foe.stats.armor = 0
				if lance then
					p.weaponReadyAt = math.huge
					run(w, 1.2)
					w:useAbility(1, 30, 0, w.now)
					run(w, 0.5)
				else
					run(w, 1.2) -- steady on, the rifle fires
					if moveAfter then
						w:setPlayerPosition(1, 0, 3)
					end
					run(w, 0.4)
				end
				return foe.maxHp - foe.hp
			end
			local capped = shot(0.3, false, false)
			T.truthy(capped > 0, "the steady shot landed")
			T.near(
				shot(0.9, true, false),
				capped,
				0.05,
				"extra steadyAim adds nothing to heroes, even after moving"
			)
			T.near(shot(0.9, false, true), shot(0.3, false, true), 0.05, "Long Shot is not cut by the cap")
		end
	)
	T.it("+30% weapon damage and +15% range after 1 s standing still; moving ends it", function()
		local w = newWorld(14)
		local p = addHero(w, "ele_vation", 1, 0, 0, 1, nil, true)
		w:setPlayerPosition(1, 1, 0)
		local d0 = p.derived
		T.eq(Weapons.stanceDerived(w, p, d0, w.now), d0, "just moved")
		local fx = run(w, 1.2)
		local d = Weapons.stanceDerived(w, p, d0, w.now)
		T.near(d.damage, d0.damage * 1.3, 0.01)
		T.near(d.range, d0.range * 1.15, 0.01)
		local on = false
		for _, f in fx do
			if f.t == "steady" and f.id == 1 and f.on then
				on = true
			end
		end
		T.truthy(on, "steady Fx")
		T.truthy(w:getPlayer(1).steady)
		w:setPlayerPosition(1, 5, 0)
		T.eq(Weapons.stanceDerived(w, p, d0, w.now), d0)
	end)
end)

T.describe("BotBrain plays the new classes", function()
	local function view(enemies: { any }, extra: { [string]: any }?): any
		local v: any = {
			self = {
				x = 0,
				z = 0,
				hp = 100,
				maxHp = 100,
				downed = false,
				abilityReady = true,
				abilityReadySlots = { true },
				squad = 1,
			},
			allies = {},
			enemies = enemies,
			arenaRadius = 300,
			now = 10,
		}
		for k, x in extra or {} do
			v[k] = x
		end
		return v
	end
	local function line(n: number, dx: number, dz: number, from: number): { any }
		local out = {}
		for i = 1, n do
			table.insert(
				out,
				{ id = i, kind = 1, x = dx * (from + 4 * i), z = dz * (from + 4 * i), hpFrac = 1, flags = 0 }
			)
		end
		return out
	end
	local function brain(cid: string): any
		local b = BotBrain.new(Ids.botId(1), cid, Rng.new(1))
		b:setAbilities({ (Classes.get(cid) :: any).ability })
		return b
	end
	T.it("Ele Vation lines Long Shot up through a lane and stands still to shoot", function()
		local b = brain("ele_vation")
		local mice = line(5, 0, 1, 20)
		local aim = b:_ability(view(mice), nil)
		assert(aim, "aim")
		T.truthy(math.abs(aim.x) < 0.5 and aim.z > 20, "down the lane")
		T.falsy(b:_ability(view(line(2, 0, 1, 20)), nil), "two mice: hold it")
		local intent = b:think(view(mice), DT)
		T.eq(intent.speedFrac, 0, "Steady Trunk: stand still")
		local close = view({ { id = 1, kind = 1, x = 5, z = 0, hpFrac = 1, flags = 0 } })
		T.truthy(not b:_steadyHold(close), "a mouse within 15: keep moving")
	end)
	T.it("Elephaid tethers the lowest-HP squadmate, herself when hurt and alone", function()
		local b = brain("elephaid")
		local allies = {
			{ id = 2, x = 10, z = 0, downed = false, isBot = true, squad = 1, hpFrac = 0.6 },
			{ id = 3, x = -10, z = 0, downed = false, isBot = true, squad = 1, hpFrac = 0.3 },
			{ id = 4, x = 0, z = 10, downed = false, isBot = true, squad = 2, hpFrac = 0.1 },
		}
		local aim = b:_ability(view({}, { allies = allies }), nil)
		assert(aim, "aim")
		T.eq(aim.x, -10, "the lowest squadmate, not the rival")
		T.falsy(b:_ability(view({}), nil), "everyone fine: hold")
		local hurt = view({})
		hurt.self.hp = 30
		T.truthy(b:_ability(hurt, nil), "self link")
	end)
	T.it("Trunkillery digs in at a big pack, not near a rival, and digs out when low", function()
		local b = brain("trunkillery")
		local pack = line(9, 1, 0, 10)
		T.truthy(b:_ability(view(pack), nil))
		T.falsy(b:_ability(view(line(4, 1, 0, 20)), nil))
		local foe = { id = 9, x = 10, z = 0, downed = false, isBot = true, squad = 2 }
		T.falsy(b:_ability(view(pack), foe), "a rival hero close: stay mobile")
		local dug = view(pack)
		dug.self.anchored = true
		T.falsy(b:_ability(dug, nil), "dug in and healthy: stay")
		dug.self.hp = 30
		T.truthy(b:_ability(dug, nil), "low: recast to dig out")
	end)
	T.it("a bot match: each new class casts its new kind against mice", function()
		for _, cid in NEW do
			local w = newWorld(31)
			local bid = Ids.botId(1)
			addHero(w, cid, bid, 0, 0, 1)
			local mate = addHero(w, "elephante", 2, 6, 0, 1, nil, true)
			local b = brain(cid)
			for k = 1, 14 do
				tank(w:spawnEnemy("mouse", 22 + k * 2, (k % 3) - 1))
			end
			mate.hp = mate.maxHp * 0.4
			local kinds = {}
			for _ = 1, 30 * 6 do
				local info = w:getPlayer(bid)
				local v = view(w:snapshot(), { now = w.now })
				v.self.x, v.self.z = info.x, info.z
				v.self.hp, v.self.maxHp = info.hp, info.maxHp
				v.self.anchored = info.anchored
				v.self.abilityReady = w.now >= info.abilityReadyAt
				v.self.abilityReadySlots = { v.self.abilityReady }
				v.allies = {
					{
						id = 2,
						x = mate.x,
						z = mate.z,
						downed = false,
						isBot = false,
						squad = 1,
						hpFrac = mate.hp / mate.maxHp,
					},
				}
				local intent = b:think(v, DT)
				if intent.ability then
					w:useAbility(bid, intent.ability.x, intent.ability.z, w.now, intent.ability.slot)
				end
				for _, f in w:step(DT, w.now + DT) do
					if f.t == "ability" and f.id == bid then
						kinds[f.kind] = true
					end
				end
			end
			T.truthy(kinds[KIND[cid]], cid .. " cast its " .. KIND[cid])
		end
	end)
end)

return T.finish()
