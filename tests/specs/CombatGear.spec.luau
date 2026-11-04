--!strict
-- v2 run-only gear (docs/GDD-v2.md §3): Config/Gear, Run/Gear and World's
-- ground items, swap offers, loot bags and golden carriers.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local Weapons = require("../../src/shared/Combat/Weapons")
local GearCfg = require("../../src/shared/Config/Gear")
local Gear = require("../../src/shared/Run/Gear")
local Enemies = require("../../src/shared/Config/Enemies")

local DT = 1 / 30

local function newWorld(seed: number, extra: { [string]: any }?): any
	local o: any = {
		rng = Rng.new(seed),
		mods = Defaults.mods(),
		arenaRadius = 120,
		obstacles = {},
		enemyPool = { "mouse" },
		cycle = 1,
		stage = 1,
		enemyCap = 0,
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
	local t = w.now
	for _ = 1, math.floor(seconds / DT + 0.5) do
		t += DT
		for _, f in w:step(DT, t) do
			table.insert(all, f)
		end
	end
	return all
end

local function eventsOf(list: { any }, typ: string): { any }
	local out = {}
	for _, e in list do
		if e.type == typ then
			table.insert(out, e)
		end
	end
	return out
end

local function item(id: string, rarity: string?): any
	return Gear.make(id, rarity or "Common")
end

T.describe("Config.Gear", function()
	T.it("about 30 items over 3 slots; the headline effect improves at each rarity", function()
		T.truthy(#GearCfg.ORDER >= 28 and #GearCfg.ORDER <= 34, tostring(#GearCfg.ORDER))
		local slots = { weapon = 0, armor = 0, trinket = 0 }
		for _, id in GearCfg.ORDER do
			local def = GearCfg.get(id) :: any
			slots[def.slot] += 1
			T.truthy(#def.name > 0 and #def.flavor > 0, id)
			for k, e in def.effects do
				T.eq(#e.values, 4, id .. "." .. e.field)
				for i = 2, if k == 1 then 4 else 1 do
					local better = if e.op == "mul"
							and e.values[1] < 1
							and e.field ~= "damage"
						then e.values[i] <= e.values[i - 1]
						else e.values[i] >= e.values[i - 1]
					T.truthy(better, id .. "." .. e.field .. " tier " .. i)
				end
			end
		end
		for slot, n in slots do
			T.truthy(n >= 9, slot .. " has " .. n)
		end
		T.eq(GearCfg.price("Legendary", 1), 400)
		T.truthy(GearCfg.price("Rare", 4) > GearCfg.price("Rare", 1))
	end)
	T.it(
		"the GDD examples exist: Splitting Shots, Cheddar Rounds, Heavy Trunk, Rind Plate, Swiss Mesh, trinkets",
		function()
			for _, id in
				{
					"splitting_shots",
					"cheddar_rounds",
					"heavy_trunk",
					"rind_plate",
					"swiss_mesh",
					"mouse_whistle",
					"lucky_cheese",
					"portal_charm",
					"revive_bell",
				}
			do
				T.truthy(GearCfg.get(id), id)
			end
		end
	)
end)

T.describe("Run.Gear", function()
	T.it("apply: copies with effects applied and the gearApplied marker", function()
		local stats = Defaults.stats()
		local weapon = Defaults.weapon("bolt")
		local ability = Defaults.ability("burst")
		local s, w, a = Gear.apply(stats, weapon, ability, {
			weapon = item("splitting_shots", "Rare"),
			armor = item("rind_plate", "Epic"),
			trinket = item("echo_horn", "Legendary"),
		})
		T.eq(stats.projectileBonus, 0, "input untouched")
		T.eq(s.projectileBonus, 2)
		T.near((w :: any).damage, weapon.damage * 0.8, 1e-9)
		T.eq(s.maxHp, 125)
		T.near((a :: any).area, ability.area * 1.3, 1e-9)
		T.eq((s :: any).gearApplied, true)
		-- two-argument form and lists
		local s2 = Gear.apply(stats, { item("mouse_whistle", "Epic"), item("bark_hide", "Rare") })
		T.near(s2.xpMult, 1.3, 1e-9)
		T.eq(s2.armor, 2)
		-- a later item of the same slot replaces the earlier one
		local s4 = Gear.apply(stats, { item("mouse_whistle", "Epic"), item("lucky_cheese", "Rare") })
		T.eq(s4.xpMult, 1)
		T.eq(s4.luck, 1)
		-- invalid items are ignored
		local s3 =
			Gear.apply(stats, weapon, ability, { weapon = { id = "nope", slot = "weapon", rarity = "Epic" } })
		T.eq(s3.projectileBonus, 0)
	end)
	T.it("roll: deterministic, valid, respects minRarity / slot, rarer on higher tiers", function()
		local a, b = Gear.roll(Rng.new(5), "Mid", 2), Gear.roll(Rng.new(5), "Mid", 2)
		T.deepEq(a, b)
		local rng = Rng.new(6)
		local lowLeg, highLeg = 0, 0
		for _ = 1, 2000 do
			local it = Gear.roll(rng, "Low", 1)
			T.truthy(Gear.valid(it))
			if it.rarity == "Legendary" then
				lowLeg += 1
			end
			if Gear.roll(rng, "High", 4).rarity == "Legendary" then
				highLeg += 1
			end
			T.truthy(Gear.rank(Gear.roll(rng, "Low", 1, { minRarity = "Rare" })) >= 2)
			T.eq(Gear.roll(rng, nil, 1, { slot = "armor" }).slot, "armor")
		end
		T.truthy(highLeg > lowLeg * 2, string.format("legendaries low %d high %d", lowLeg, highLeg))
	end)
	T.it("describe, bossChest, cartOffers", function()
		T.eq(Gear.describe(item("splitting_shots", "Rare")), "+2 projectiles, -20% weapon damage")
		T.eq(Gear.describe(item("swiss_mesh", "Epic")), "-30% projectile damage taken")
		T.eq(Gear.describe(item("portal_charm", "Legendary")), "+15% cheese on Extract")
		local chest = Gear.bossChest(Rng.new(1), "Low", 1)
		T.eq(#chest, Gear.CHEST_ITEMS)
		for _, it in chest do
			T.truthy(Gear.rank(it) >= 2)
		end
		local offers, prices = Gear.cartOffers(Rng.new(2), "Mid", 2)
		T.eq(#offers, 3)
		T.deepEq({ offers[1].slot, offers[2].slot, offers[3].slot }, { "weapon", "armor", "trinket" })
		T.eq(prices[1], GearCfg.price(offers[1].rarity, 2))
	end)
end)

T.describe("World gear: equip, swap, ground, effects", function()
	T.it("giveGear equips an empty slot, offers a swap when full, never loses items", function()
		local w = newWorld(10)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		run(w, 0.1)
		local ok, offer = w:giveGear(1, item("rind_plate", "Common"))
		T.truthy(ok and not offer)
		T.eq(w:getPlayer(1).maxHp, 110, "World applies gear itself")
		local evs = w:drainEvents()
		T.eq(#eventsOf(evs, "gearPickup"), 1)
		ok, offer = w:giveGear(1, item("bark_hide", "Epic"))
		T.truthy(not ok and offer)
		local so = w:swapOffer(1)
		T.eq(so.item.id, "bark_hide")
		T.eq(so.current.id, "rind_plate")
		T.eq(#eventsOf(w:drainEvents(), "gearSwapOffer"), 1)
		-- a third item while an offer is open drops at the hero's feet
		ok, offer = w:giveGear(1, item("wax_coat", "Rare"))
		T.truthy(not ok and not offer)
		T.eq(#w:groundItems(), 1)
		-- takeNew = true: the offered item is equipped, the old one drops
		T.truthy(w:resolveSwap(1, true))
		T.eq(w:gearOf(1).armor.id, "bark_hide")
		T.eq(w:getPlayer(1).maxHp, 100)
		T.eq(#w:groundItems(), 2)
		local ev = eventsOf(w:drainEvents(), "gearPickup")[1]
		T.eq(ev.replaced.id, "rind_plate")
		T.falsy(w:resolveSwap(1, true), "no offer left")
	end)
	T.it("takeNew = false keeps the current item; an offer expires after SWAP_TIME", function()
		local w = newWorld(11)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		run(w, 0.1)
		w:giveGear(1, item("rind_plate"))
		w:giveGear(1, item("bark_hide"))
		T.truthy(w:resolveSwap(1, false))
		T.eq(w:gearOf(1).armor.id, "rind_plate")
		T.eq(w:groundItems()[1].item.id, "bark_hide")
		-- the declined item is not offered again while the hero stands on it
		run(w, 1)
		T.eq(w:swapOffer(1), nil)
		w:dropGear(item("wax_coat"), 30, 0)
		w:setPlayerPosition(1, 30, 0)
		run(w, 0.1)
		T.truthy(w:swapOffer(1) ~= nil, "walking onto ground gear offers it")
		run(w, World.SWAP_TIME + 0.2)
		T.eq(w:swapOffer(1), nil)
		T.eq(w:gearOf(1).armor.id, "rind_plate")
	end)
	T.it("walking over ground gear auto-equips an empty slot", function()
		local w = newWorld(12)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		local gid = w:dropGear(item("mouse_whistle", "Rare"), 20, 0)
		T.truthy(gid)
		T.eq(
			w:dropGear({ id = "fake", slot = "weapon", rarity = "Epic" }, 0, 0),
			nil,
			"invalid items rejected"
		)
		run(w, 0.1)
		T.eq(#w:groundItems(), 1)
		w:setPlayerPosition(1, 19, 0)
		local fx = run(w, 0.1)
		T.eq(#w:groundItems(), 0)
		T.eq(w:gearOf(1).trinket.id, "mouse_whistle")
		local gone = false
		for _, f in fx do
			if f.t == "gearGone" and f.id == gid then
				gone = true
			end
		end
		T.truthy(gone)
	end)
	T.it("external mode: stats marked by Gear.apply are used as-is (no double apply)", function()
		local w = newWorld(13)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:giveGear(1, item("rind_plate", "Epic"))
		T.eq(w:getPlayer(1).maxHp, 125)
		local s = Gear.apply(Defaults.stats(), harmless(), Defaults.ability("burst"), w:gearOf(1))
		w:updatePlayer(1, s, harmless())
		T.eq(w:getPlayer(1).maxHp, 125, "not 156")
		-- setGear restores gear (stage carry-over) without events
		local w2 = newWorld(14)
		w2:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w2:setGear(1, w:gearOf(1))
		T.eq(w2:getPlayer(1).maxHp, 125)
		T.eq(#eventsOf(w2:drainEvents(), "gearPickup"), 0)
	end)
	T.it(
		"gear changes combat: projectiles, burn, knockback, armour, projectile resist, XP, revive, extract",
		function()
			-- projectile count
			local w = newWorld(15)
			w:addPlayer(1, Defaults.stats(), Defaults.weapon("bolt"), Defaults.ability("burst"), 0, 0, 1)
			local base = w.players[1].derived.count
			w:giveGear(1, item("splitting_shots", "Legendary"))
			T.eq(w.players[1].derived.count, base + 3)
			-- knockback
			w:setGear(1, { weapon = item("heavy_trunk", "Legendary") })
			T.near(w.players[1].derived.knockback, Defaults.weapon("bolt").knockback * 2, 1e-9)
			-- burn DoT keeps hurting after the hit
			local wb = newWorld(16, { enemyCap = 10 })
			local wpn = Defaults.weapon("bolt")
			wpn.cooldown = 100
			wb:addPlayer(1, Defaults.stats(), wpn, Defaults.ability("burst"), 0, 0, 1)
			wb:giveGear(1, item("cheddar_rounds", "Legendary"))
			run(wb, 0.05)
			local m = wb:spawnEnemy("chonk", 10, 0)
			m.hp, m.maxHp, m.speed = 1000, 1000, 0
			run(wb, 0.5)
			local after = m.hp
			T.truthy(m.burnUntil ~= nil, "burning")
			run(wb, 2)
			T.near(after - m.hp, 12 * 2, 6.1, "burn ticks ~12 dps")
			-- armour + projectile resist
			local wa = newWorld(17)
			wa:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
			wa:setGear(1, { armor = item("swiss_mesh", "Legendary") })
			run(wa, 0.1)
			T.near(wa:damagePlayer(wa.players[1], 10, "projectile"), 6, 1e-9)
			run(wa, 0.6)
			T.near(wa:damagePlayer(wa.players[1], 10, "contact"), 10, 1e-9)
			wa:setGear(1, { armor = item("bark_hide", "Legendary") })
			run(wa, 0.6)
			T.near(wa:damagePlayer(wa.players[1], 10, "contact"), 6, 1e-9)
			-- XP and luck, extract bonus
			wa:setGear(1, { trinket = item("mouse_whistle", "Epic") })
			T.near(wa.players[1].stats.xpMult, 1.3, 1e-9)
			wa:setGear(1, { trinket = item("portal_charm", "Legendary") })
			T.near(wa:extractBonusOf(1), 0.15, 1e-9)
			T.near(wa:getPlayer(1).extractBonus, 0.15, 1e-9)
			-- revive speed: a Revive Bell (x2) revives in REVIVE_TIME / 2
			local wr = newWorld(18)
			wr:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
			wr:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 3, 0, 1)
			wr:setGear(2, { trinket = item("revive_bell", "Legendary") })
			run(wr, 0.1)
			wr:damagePlayer(wr.players[1], 1e6, "contact")
			run(wr, World.REVIVE_TIME / 2 + 0.1)
			T.falsy(wr:getPlayer(1).downed, "revived in 1.5 s")
		end
	)
	T.it("Weapons burn constants", function()
		T.eq(Weapons.BURN_TIME, 3)
	end)
end)

T.describe("World loot bags", function()
	T.it("a killed hero drops a bag with all their gear; addLootBag merges the cheese share", function()
		local w = newWorld(20)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 50, 0, 2)
		w:addPlayer(3, Defaults.stats(), harmless(), Defaults.ability("burst"), 90, 0, 2)
		for id = 1, 3 do
			w:protect(id, 0)
		end
		run(w, 0.1)
		w:setGear(2, { weapon = item("rapid_tusks", "Rare"), armor = item("rind_plate", "Epic") })
		w:damageHeroFrom(w.players[2], 1e6, w.players[1])
		run(w, World.DOWNED_TIME + 0.2)
		local k = eventsOf(w:drainEvents(), "heroKilled")[1]
		T.truthy(k and k.bag, "heroKilled carries the bag id")
		T.deepEq(w:gearOf(2), {})
		local same = w:addLootBag(k.x, k.z, w:gearOf(2), 40)
		T.eq(same, k.bag, "merged into the fresh gear bag")
		T.eq(w:lootBags()[1].cheese, 40)
		T.eq(w:lootBags()[1].n, 2)
		T.truthy(w:addBagCheese(k.bag, 10))
		-- picking it up: 1.5 s channel, damage interrupts it
		w:setPlayerPosition(1, k.x + 1, k.z)
		run(w, 1)
		w:damagePlayer(w.players[1], 1, "contact")
		run(w, 0.4)
		T.eq(#w:lootBags(), 1, "interrupted")
		run(w, World.BAG_CHANNEL + 0.8)
		T.eq(#w:lootBags(), 0)
		local lb = eventsOf(w:drainEvents(), "lootBag")
		T.eq(#lb, 1)
		T.eq(lb[1].by, 1)
		T.eq(lb[1].squad, 1)
		T.eq(lb[1].cheese, 50)
		T.eq(#lb[1].gear, 2)
		T.eq(w:gearOf(1).weapon.id, "rapid_tusks")
		T.eq(w:gearOf(1).armor.id, "rind_plate")
	end)
	T.it("two squads on a bag hold the channel", function()
		local w = newWorld(21)
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:addPlayer(2, Defaults.stats(), harmless(), Defaults.ability("burst"), 1, 1, 2)
		w:addLootBag(0.5, 0, { item("wax_coat") }, 0)
		run(w, 3)
		T.eq(#w:lootBags(), 1)
	end)
end)

T.describe("Golden carrier mice", function()
	T.it("spawn during waves, flee heroes, drop gear when killed, escape otherwise", function()
		local w = newWorld(30, { enemyCap = 30, enemyPool = { "mouse" } })
		w:addPlayer(
			1,
			Defaults.stats({ maxHp = 1e6, regen = 1e4 }),
			harmless(),
			Defaults.ability("burst"),
			0,
			0,
			1
		)
		w:startWaves(200)
		local fx = run(w, World.CARRIER_FIRST + 0.5)
		local carrier = nil
		for _, e in w.enemies do
			if e.alive and e.carrier then
				carrier = e
			end
		end
		T.truthy(carrier, "a carrier spawned")
		local spawnFx = 0
		for _, f in fx do
			if f.t == "carrier" then
				spawnFx += 1
			end
		end
		T.eq(spawnFx, 1)
		T.eq(carrier.kind, Enemies.INDEX.carrier)
		-- flees: move the hero next to it, it gets further away
		w:setPlayerPosition(1, carrier.x + 6, carrier.z)
		local d0 = math.sqrt((carrier.x - w.players[1].x) ^ 2 + (carrier.z - w.players[1].z) ^ 2)
		run(w, 0.5)
		local d1 = math.sqrt((carrier.x - w.players[1].x) ^ 2 + (carrier.z - w.players[1].z) ^ 2)
		T.truthy(d1 > d0, "runs away")
		local before = #w:groundItems()
		w:damageEnemy(carrier, 1e6, w.players[1])
		T.eq(#w:groundItems(), before + 1, "dropped a gear item")
		-- the next one escapes after its lifetime
		w.nextCarrierAt = w.now
		run(w, 0.1)
		local c2 = nil
		for _, e in w.enemies do
			if e.alive and e.carrier then
				c2 = e
			end
		end
		T.truthy(c2)
		local items = #w:groundItems()
		local fx2 = run(w, (Enemies.get("carrier") :: any).lifetime + 0.5)
		T.falsy(c2.alive)
		local escaped = false
		for _, f in fx2 do
			if f.t == "carrierEscape" and f.id == c2.id then
				escaped = true
			end
		end
		T.truthy(escaped)
		T.truthy(#w:groundItems() <= items + 1, "an escape drops nothing")
	end)
	T.it("never in quiet worlds (enemyCap 0) or with carriers = false", function()
		local w = newWorld(31, { enemyCap = 50, carriers = false })
		w:addPlayer(1, Defaults.stats(), harmless(), Defaults.ability("burst"), 0, 0, 1)
		w:startWaves(100)
		run(w, World.CARRIER_FIRST + 5)
		for _, e in w.enemies do
			T.falsy(e.carrier)
		end
	end)
end)

return T.finish()
