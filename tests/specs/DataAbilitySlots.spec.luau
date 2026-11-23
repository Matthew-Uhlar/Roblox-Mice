-- Iteration 5, A3: ability slots by class level (Data/ClassProgress, Run/Stats,
-- Combat/World per-slot cooldowns, BotBrain uses every slot).
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local ClassProgress = require("../../src/shared/Data/ClassProgress")
local ClassAbilities = require("../../src/shared/Config/ClassAbilities")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local Stats = require("../../src/shared/Run/Stats")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local BotBrain = require("../../src/shared/Bots/BotBrain")

local CLASS = "elephante"
local BASE = "elephante_stampede"
local ALT1 = "elephante_trunk_quake" -- level 5
local ALT2 = "elephante_iron_hide" -- level 15

local function profileAt(level: number, extra: { [string]: any }?): any
	local p = ProfileSchema.default()
	p.unlockedClasses[CLASS] = true
	local st: { [string]: any } = { xp = 0, level = level, perks = {} }
	for k, v in extra or {} do
		st[k] = v
	end
	p.classes[CLASS] = st
	return p
end

T.describe("ClassProgress ability slots", function()
	T.it("slots: 1 at level 1, 2 at level 10, 3 at level 20; Prestige keeps all 3", function()
		T.eq(ClassProgress.slotCount(1), 1)
		T.eq(ClassProgress.slotCount(9), 1)
		T.eq(ClassProgress.slotCount(10), 2)
		T.eq(ClassProgress.slotCount(19), 2)
		T.eq(ClassProgress.slotCount(20), 3)
		T.eq(ClassProgress.slotCount(30), 3)
		T.eq(ClassProgress.slotCount(1, 1), 3, "prestige keeps all slots")
		T.eq(ClassProgress.slotCount(0 / 0, 0 / 0), 1, "junk is safe")
		T.eq(ClassProgress.slotLevel(2), 10)
		T.eq(ClassProgress.slotLevel(3), 20)
	end)

	T.it("loadout fills every unlocked slot (picks first, then unlock order)", function()
		T.deepEq(ClassProgress.loadout(CLASS, { level = 1 }), { BASE })
		T.deepEq(ClassProgress.loadout(CLASS, { level = 12 }), { BASE, ALT1 })
		T.deepEq(ClassProgress.loadout(CLASS, { level = 12, ability = ALT1 }), { ALT1, BASE })
		T.deepEq(ClassProgress.loadout(CLASS, { level = 25 }), { BASE, ALT1, ALT2 })
		T.deepEq(
			ClassProgress.loadout(CLASS, { level = 25, ability = ALT2, abilities = { ALT2, BASE, ALT1 } }),
			{ ALT2, BASE, ALT1 }
		)
		-- `ability` is authoritative for slot 1 (an older server only wrote that)
		T.deepEq(
			ClassProgress.loadout(CLASS, { level = 25, ability = ALT1, abilities = { BASE, ALT1, ALT2 } }),
			{ ALT1, BASE, ALT2 }
		)
		-- junk and other classes' ids are dropped, no duplicates
		T.deepEq(
			ClassProgress.loadout(
				CLASS,
				{ level = 25, abilities = { "ele_fonte_riptide", ALT2, ALT2, 7, BASE } :: any }
			),
			{ BASE, ALT2, ALT1 }
		)
	end)

	T.it("migrates the old single `ability` (slot 1) and stays round-trip stable", function()
		local old = ClassProgress.sanitize(CLASS, { xp = 0, level = 25, perks = {}, ability = ALT1 })
		T.eq(old.ability, ALT1)
		T.eq(old.abilities, nil, "a one-pick loadout is `ability` alone")
		T.deepEq(ClassProgress.loadout(CLASS, old), { ALT1, BASE, ALT2 })
		local saved = ClassProgress.sanitize(
			CLASS,
			{ xp = 0, level = 25, perks = {}, ability = ALT1, abilities = { ALT1, ALT2 } }
		)
		T.deepEq(saved.abilities, { ALT1, ALT2 })
		T.deepEq(ClassProgress.sanitize(CLASS, saved), saved, "idempotent")
		-- a locked ability in the saved list is dropped
		local low =
			ClassProgress.sanitize(CLASS, { xp = 0, level = 6, perks = {}, abilities = { BASE, ALT2 } })
		T.eq(low.abilities, nil)
	end)

	T.it("selectAbility validates the slot, the unlock and swaps instead of duplicating", function()
		local p = profileAt(12)
		T.deepEq({ ClassProgress.selectAbility(p, CLASS, ALT1, 3) }, { false, "ability_slot_locked" })
		T.deepEq({ ClassProgress.selectAbility(p, CLASS, ALT1, 4) }, { false, "ability_slot_locked" })
		T.deepEq({ ClassProgress.selectAbility(p, CLASS, ALT1, 5) }, { false, "bad_ability_slot" })
		T.deepEq({ ClassProgress.selectAbility(p, CLASS, ALT1, 1.5) }, { false, "bad_ability_slot" })
		T.deepEq({ ClassProgress.selectAbility(p, CLASS, ALT1, 0 / 0) }, { false, "bad_ability_slot" })
		T.deepEq({ ClassProgress.selectAbility(p, CLASS, ALT2, 2) }, { false, "ability_locked" })
		T.deepEq(
			{ ClassProgress.selectAbility(p, CLASS, "ele_fonte_riptide", 2) },
			{ false, "unknown_ability" }
		)
		-- ALT1 is in slot 2 by default; putting it in slot 1 swaps
		T.deepEq(ClassProgress.loadout(CLASS, p.classes[CLASS]), { BASE, ALT1 })
		T.truthy(ClassProgress.selectAbility(p, CLASS, ALT1, 1))
		T.deepEq(ClassProgress.loadout(CLASS, p.classes[CLASS]), { ALT1, BASE })
		T.eq(p.classes[CLASS].ability, ALT1, "`ability` stays slot 1")
		-- the old 2-argument call still sets slot 1 (nil = base)
		T.truthy(ClassProgress.selectAbility(p, CLASS, nil))
		T.deepEq(ClassProgress.loadout(CLASS, p.classes[CLASS]), { BASE, ALT1 })
		T.eq(p.classes[CLASS].ability, nil)
		-- the view carries the loadout for the lobby
		local v = ClassProgress.view(p)[CLASS]
		T.deepEq(v.abilities, { BASE, ALT1 })
		T.eq(v.abilitySlots, 2)
		T.deepEq(v.slotLevels, { 1, 10, 20 })
	end)

	T.it("a level-1 Prestige hero keeps 3 slots; the award reports new slots", function()
		local p = profileAt(30, { prestige = 1 })
		T.truthy(ClassProgress.selectAbility(p, CLASS, ALT2, 3))
		T.deepEq(ClassProgress.loadout(CLASS, p.classes[CLASS]), { BASE, ALT1, ALT2 })
		T.eq(ClassProgress.view(p)[CLASS].abilitySlots, 3)
		local q = profileAt(9)
		local a = ClassProgress.award(q, CLASS, 20000) :: any
		T.truthy(a.level >= 10 and a.level < 20, "level " .. a.level)
		T.deepEq(a.slots, { 2 })
		local b = ClassProgress.award(q, CLASS, 20000) :: any
		T.truthy(b.level >= 20, "level " .. b.level)
		T.deepEq(b.slots, { 3 })
	end)

	T.it("survives a migrate round-trip through ProfileSchema", function()
		local p = profileAt(25)
		ClassProgress.selectAbility(p, CLASS, ALT2, 2)
		local m = ProfileSchema.migrate(p)
		T.deepEq(ClassProgress.loadout(CLASS, m.classes[CLASS]), { BASE, ALT2, ALT1 })
		T.deepEq(ProfileSchema.migrate(m), m, "stable")
	end)
end)

T.describe("Stats.compute abilities", function()
	T.it("returns every slot; ability == abilities[1]; no classState = one slot", function()
		local _, _, a, list = Stats.compute(CLASS, {}, {})
		T.eq(#list, 1)
		T.eq(list[1], a)
		local _, _, a2, list2 = Stats.compute(
			CLASS,
			{},
			{},
			nil,
			nil,
			{ perks = {}, level = 25, ability = ALT1, abilities = { ALT1, ALT2 } }
		)
		T.eq(#list2, 3)
		T.eq(list2[1], a2)
		T.eq(a2.id, ALT1)
		T.eq(list2[2].id, ALT2)
		T.eq(list2[3].id, BASE)
		local _, _, _, list3 = Stats.compute(CLASS, {}, {}, nil, nil, { perks = {}, level = 12 })
		T.eq(#list3, 2)
	end)

	T.it("abilityMul (upgrades) applies to every slot; slot cooldown mults are applied", function()
		local cs = { perks = {}, level = 25 }
		local _, _, _, plain = Stats.compute(CLASS, {}, {}, nil, nil, cs)
		local _, _, _, buffed = Stats.compute(CLASS, { mega_ability = 1 }, {}, nil, nil, cs)
		for k = 1, 3 do
			T.truthy(buffed[k].damage > plain[k].damage, "slot " .. k .. " damage")
			local m = ClassAbilities.SLOT_COOLDOWN_MULT[k] or 1
			local base = (ClassAbilities.get(plain[k].id) :: any).def.cooldown
			T.near(
				plain[k].cooldown,
				math.max(Stats.ABILITY_MIN_COOLDOWN, base * m),
				1e-9,
				"slot " .. k .. " cd"
			)
		end
	end)
end)

local function newWorld(): any
	return World.new({ rng = Rng.new(3), mods = Defaults.mods(), arenaRadius = 120, enemyPool = { "mouse" } })
end

T.describe("World per-slot ability cooldowns", function()
	T.it("each slot has its own cooldown; cooldownMult applies to every slot", function()
		local w = newWorld()
		local burst, ring = Defaults.ability("burst"), Defaults.ability("ring")
		w:addPlayer(1, Defaults.stats({ cooldownMult = 0.5 }), Defaults.weapon("bolt"), burst, 0, 0)
		w:setPlayerAbilities(1, { burst, ring })
		w:step(1 / 30, 1)
		local t = w.now
		T.eq(w:abilitySlots(1), 2)
		T.falsy(w:useAbility(1, 5, 0, t, 3), "slot 3 not equipped")
		T.falsy(w:useAbility(1, 5, 0, t, 0), "slot 0")
		T.falsy(w:useAbility(1, 5, 0, t, 1.5 :: any), "fractional slot")
		T.truthy(w:useAbility(1, 5, 0, t, 2))
		T.falsy(w:useAbility(1, 5, 0, t, 2), "slot 2 on cooldown")
		T.truthy(w:useAbility(1, 5, 0, t), "slot 1 is independent")
		local info = w:getPlayer(1)
		T.near(info.abilityReadyAts[1], t + burst.cooldown * 0.5, 1e-9)
		T.near(info.abilityReadyAts[2], t + ring.cooldown * 0.5, 1e-9)
		T.eq(info.abilityReadyAt, info.abilityReadyAts[1])
		T.near(info.abilityCooldowns[2], ring.cooldown * 0.5, 1e-9)
		T.eq(#info.abilityNames, 2)
		T.eq(#w:getPlayers()[1].abilityReadyAts, 2)
		-- shrinking the loadout drops the slot
		w:setPlayerAbilities(1, { burst })
		T.eq(w:abilitySlots(1), 1)
		T.falsy(w:useAbility(1, 5, 0, w.now + 100, 2))
	end)

	T.it("Cataclysm repeats only the slot that was cast", function()
		local w = newWorld()
		local burst, ring = Defaults.ability("burst"), Defaults.ability("ring")
		w:addPlayer(1, Defaults.stats({ abilityRepeat = 1 } :: any), Defaults.weapon("bolt"), burst, 0, 0)
		w:setPlayerAbilities(1, { burst, ring })
		w:step(1 / 30, 1)
		T.truthy(w:useAbility(1, 5, 0, w.now, 2))
		local kinds = {}
		local t = w.now
		for _ = 1, 30 do
			t += 1 / 30
			for _, f in w:step(1 / 30, t) do
				if f.t == "ability" then
					kinds[f.kind] = (kinds[f.kind] or 0) + 1
				end
			end
		end
		T.eq(kinds.ring, 2, "the cast + one repeat")
		T.eq(kinds.burst, nil, "slot 1 never fires")
	end)

	T.it("gear and stat changes keep every slot", function()
		local w = newWorld()
		local burst, ring, dash =
			Defaults.ability("burst"), Defaults.ability("ring"), Defaults.ability("dash")
		w:addPlayer(1, Defaults.stats(), Defaults.weapon("bolt"), burst, 0, 0)
		w:setPlayerAbilities(1, { burst, ring, dash })
		w:updatePlayer(1, Defaults.stats({ cooldownMult = 0.8 }), Defaults.weapon("bolt"))
		T.eq(w:abilitySlots(1), 3)
		w:setPlayerAbility(1, dash)
		T.eq(w:abilitySlots(1), 3)
		T.eq(w:getPlayer(1).abilityIds[1], "dash")
	end)
end)

T.describe("BotBrain uses every slot", function()
	local function cluster(cx: number, cz: number, n: number): { any }
		local out = {}
		for i = 1, n do
			table.insert(out, {
				id = i,
				kind = 1,
				x = cx + (i % 3) * 0.5,
				z = cz + math.floor(i / 3) * 0.5,
				hpFrac = 1,
				flags = 0,
			})
		end
		return out
	end
	local function view(ready1: boolean, slots: { boolean }?): any
		return {
			self = {
				x = 0,
				z = 0,
				hp = 100,
				maxHp = 100,
				downed = false,
				abilityReady = ready1,
				abilityReadySlots = slots,
			},
			allies = {},
			enemies = cluster(4, 0, 8),
			pickups = {},
			arenaRadius = 100,
			obstacles = {},
			now = 0,
		}
	end

	T.it("casts slot 1 first, then the next ready slot", function()
		local brain = BotBrain.new(-1001, CLASS, Rng.new(1))
		brain:setAbilities({
			Defaults.ability("ring"),
			Defaults.ability("burst"),
			Defaults.ability("ring"),
		})
		local i1 = brain:think(view(true, { true, true, true }), 0.1)
		T.eq(i1.ability and i1.ability.slot, 1)
		local i2 = brain:think(view(false, { false, true, true }), 0.1)
		T.eq(i2.ability and i2.ability.slot, 2)
		local i3 = brain:think(view(false, { false, false, true }), 0.1)
		T.eq(i3.ability and i3.ability.slot, 3)
		local i4 = brain:think(view(false, { false, false, false }), 0.1)
		T.eq(i4.ability, nil)
		-- without setAbilities only slot 1 exists (old behaviour)
		local old = BotBrain.new(-1002, CLASS, Rng.new(1))
		T.eq(old:think(view(false, { false, true, true }), 0.1).ability, nil)
	end)
end)

T.finish()
