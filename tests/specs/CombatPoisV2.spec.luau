--!strict
-- v2 contested POIs and the new POIs (docs/GDD-v2.md §4).
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local Pois = require("../../src/shared/Combat/Pois")
local Config = require("../../src/shared/Config/Pois")
local Maps = require("../../src/shared/Config/Maps")
local Gear = require("../../src/shared/Run/Gear")
local serde = (require :: any)("@lune/serde")

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

local function addHero(w: any, id: number, x: number, z: number, squad: number)
	w:addPlayer(id, Defaults.stats(), harmless(), Defaults.ability("burst"), x, z, squad)
end

local function run(w: any, seconds: number): ({ any }, { any })
	local fx, evs = {}, {}
	local t = w.now
	for _ = 1, math.floor(seconds / DT + 0.5) do
		t += DT
		for _, f in w:step(DT, t) do
			table.insert(fx, f)
		end
		for _, e in w:drainEvents() do
			table.insert(evs, e)
		end
	end
	return fx, evs
end

local function of(list: { any }, key: string, val: string): { any }
	local out = {}
	for _, e in list do
		if e[key] == val then
			table.insert(out, e)
		end
	end
	return out
end

local function poiOf(w: any, id: number): any
	for _, p in w:pois() do
		if p.id == id then
			return p
		end
	end
	return nil
end

local function live(w: any)
	w:startWaves(300)
	run(w, 0.05)
end

T.describe("Contested channels", function()
	T.it("two squads inside hold the progress; the reward goes to the channelling squad", function()
		local w = newWorld(1)
		addHero(w, 1, 0, 0, 1)
		addHero(w, 2, 0, 1, 1)
		addHero(w, 3, 60, 0, 2)
		addHero(w, 4, 80, 0, 3)
		local id = w:addPoi({ kind = "cheese_cache", x = 0, z = 0 })
		live(w)
		run(w, 1)
		local p = poiOf(w, id).progress
		T.truthy(p > 0)
		T.eq(poiOf(w, id).squad, 1)
		w:setPlayerPosition(3, 2, 0)
		local fx = run(w, 1)
		T.near(poiOf(w, id).progress, p, 0.02, "held while contested")
		T.truthy(poiOf(w, id).contested)
		local st = of(fx, "t", "poi")
		T.truthy(#st > 0 and st[#st].contested == true, "state Fx says contested")
		w:setPlayerPosition(3, 60, 0)
		local _, evs = run(w, 3)
		local r = of(evs, "type", "poiReward")
		T.eq(#r, 1)
		T.eq(r[1].squad, 1)
		table.sort(r[1].ids)
		T.deepEq(r[1].ids, { 1, 2 }, "only the channelling squad")
	end)
	T.it("another squad first drains the old squad's progress, then fills its own", function()
		local w = newWorld(2)
		addHero(w, 1, 0, 0, 1)
		addHero(w, 2, 60, 0, 2)
		local id = w:addPoi({ kind = "cheese_cache", x = 0, z = 0 })
		live(w)
		run(w, 1.5)
		local p = poiOf(w, id).progress
		w:setPlayerPosition(1, -60, 0)
		w:setPlayerPosition(2, 0, 0)
		run(w, 0.5)
		T.truthy(poiOf(w, id).progress < p, "draining")
		T.eq(poiOf(w, id).squad, 1, "still squad 1's progress")
		run(w, 6)
		T.eq(poiOf(w, id).squad, 2)
		T.eq(poiOf(w, id).state, "done")
	end)
	T.it("damage interrupts the channel", function()
		local w = newWorld(3)
		addHero(w, 1, 0, 0, 1)
		local id = w:addPoi({ kind = "cheese_cache", x = 0, z = 0 })
		live(w)
		run(w, 1)
		local p = poiOf(w, id).progress
		for _ = 1, 8 do
			w.players[1].iframeUntil = 0
			w:damagePlayer(w.players[1], 1, "contact")
			run(w, 0.25)
		end
		T.near(poiOf(w, id).progress, p, 0.03)
	end)
	T.it("Mending heals only the channelling squad", function()
		local w = newWorld(4)
		addHero(w, 1, 0, 0, 1)
		addHero(w, 2, 60, 0, 2)
		w.players[1].hp = 50
		w.players[2].hp = 50
		w:addPoi({ kind = "shrine_mending", x = 0, z = 0 })
		live(w)
		run(w, 1.5)
		T.truthy(w:getPlayer(1).hp > 50)
		T.eq(w:getPlayer(2).hp, 50)
	end)
end)

T.describe("New POIs", function()
	T.it("Armory Crate: 4 s channel -> 1 gear item to the channeller (Rare+ from stage 3)", function()
		local w = newWorld(5, { stage = 3 })
		addHero(w, 1, 0, 0, 1)
		addHero(w, 2, 70, 0, 2)
		local id = w:addPoi({ kind = "armory", x = 0, z = 0 })
		live(w)
		local _, early = run(w, 3)
		T.eq(#of(early, "type", "poiReward"), 0)
		local _, evs = run(w, 1.5)
		local r = of(evs, "type", "poiReward")
		T.eq(#r, 1)
		T.eq(r[1].kind, "armory")
		T.eq(r[1].poi, id)
		T.eq(#r[1].items, 1)
		T.truthy(Gear.rank(r[1].items[1]) >= 2, "Rare or better at stage 3")
		local slot = r[1].items[1].slot
		T.eq(w:gearOf(1)[slot].id, r[1].items[1].id, "equipped")
	end)
	T.it("Cheese Vault: 8 s, announced to everyone, 2 items + a big pot", function()
		local w = newWorld(6)
		addHero(w, 1, 0, 0, 1)
		addHero(w, 2, 70, 0, 2)
		local id = w:addPoi({ kind = "cheese_vault", x = 0, z = 0 })
		w:startWaves(300)
		local fx, evs = run(w, 0.5)
		local alert = of(evs, "type", "poiAlert")
		T.eq(#alert, 1)
		T.eq(alert[1].squad, 1)
		local vfx = of(fx, "t", "vault")
		T.eq(#vfx, 1)
		T.eq(vfx[1].phase, "start")
		local fx2, evs2 = run(w, 8)
		local r = of(evs2, "type", "poiReward")
		T.eq(#r, 1)
		T.eq(r[1].kind, "vault")
		T.eq(r[1].cheese, Config.vaultCheese(1, 1))
		T.eq(#r[1].items, 2)
		T.eq(#of(fx2, "t", "vault"), 1, "phase done")
		T.eq(poiOf(w, id).state, "done")
		-- the second item went to the ground (hero 1's slot may be taken) or to a slot
		local held = 0
		for _ in w:gearOf(1) do
			held += 1
		end
		T.truthy(held >= 1)
	end)
	T.it("Power Totem: capture, +15% squad damage, contest, neutralise and recapture", function()
		local w = newWorld(7)
		addHero(w, 1, 0, 0, 1)
		addHero(w, 2, 70, 0, 2)
		local id = w:addPoi({ kind = "power_totem", x = 0, z = 0 })
		live(w)
		local fx, evs = run(w, Config.get("power_totem").channel + 0.5)
		local cap = of(evs, "kind", "totem_owner")
		T.eq(#cap, 1)
		T.eq(cap[1].squad, 1)
		T.eq(w:squadDamageMult(1), Config.TOTEM_DAMAGE_MULT)
		T.eq(w:squadDamageMult(2), 1)
		T.eq(#of(fx, "t", "totem"), 1)
		T.eq(poiOf(w, id).owner, 1)
		-- the buff changes damage: same base hit, more damage dealt by squad 1
		w.cap = 10
		local m = w:spawnEnemy("chonk", 50, 50)
		m.hp, m.maxHp = 1e5, 1e5
		w.rng = Rng.new(1)
		local Weapons = require("../../src/shared/Combat/Weapons")
		w.players[1].stats.critChance = 0
		T.near(Weapons.hit(w, w.players[1], m, 10, nil), 11.5, 1e-9)
		-- the owner leaves; squad 2 holds the zone -> neutralised, then theirs
		w:setPlayerPosition(1, -70, 0)
		w:setPlayerPosition(2, 0, 0)
		local _, evs2 = run(w, Config.get("power_totem").channel + 0.3)
		T.eq(#of(evs2, "type", "totemLost"), 1)
		T.eq(w:squadDamageMult(1), 1)
		local _, evs3 = run(w, Config.get("power_totem").channel + 0.3)
		local cap2 = of(evs3, "kind", "totem_owner")
		T.eq(#cap2, 1)
		T.eq(cap2[1].squad, 2)
		T.eq(cap2[1].prev, nil)
		-- both squads inside: contested, held
		w:setPlayerPosition(1, 1, 0)
		run(w, 3)
		T.truthy(poiOf(w, id).contested)
		T.eq(poiOf(w, id).owner, 2)
	end)
	T.it("Shop Cart: opens per hero with 3 priced offers; takeCartOffer sells each once", function()
		local w = newWorld(8, { stage = 2 })
		addHero(w, 1, 0, 0, 1)
		local id = w:addPoi({ kind = "shop_cart", x = 0, z = 0 })
		live(w)
		local fx, evs = run(w, 1.3)
		local open = of(evs, "kind", "shop_cart_open")
		T.eq(#open, 1)
		T.eq(open[1].poi, id)
		T.eq(open[1].by, 1)
		T.eq(#open[1].offers, 3)
		T.eq(#open[1].prices, 3)
		T.eq(#of(fx, "t", "cart"), 1)
		-- standing still does not re-open it
		local _, again = run(w, 2)
		T.eq(#of(again, "kind", "shop_cart_open"), 0)
		local it, price = w:takeCartOffer(id, 2)
		T.truthy(it and Gear.valid(it))
		T.eq(price, open[1].prices[2])
		T.eq(w:takeCartOffer(id, 2), nil, "sold once")
		T.eq(w:takeCartOffer(id, 9), nil)
		T.eq(w:cartOffers(id).sold[2], true)
		w:takeCartOffer(id, 1)
		w:takeCartOffer(id, 3)
		T.eq(poiOf(w, id).state, "done")
		-- leave and come back: a sold-out cart stays shut
		w:setPlayerPosition(1, 30, 0)
		run(w, 0.3)
		w:setPlayerPosition(1, 0, 0)
		local _, evs4 = run(w, 1.5)
		T.eq(#of(evs4, "kind", "shop_cart_open"), 0)
	end)
	T.it("Elite Camp chest goes to the killer's squad and spills a gear item", function()
		local w = newWorld(9)
		w:addPlayer(1, Defaults.stats(), Defaults.weapon("bolt"), Defaults.ability("burst"), 0, 0, 1)
		addHero(w, 2, 0, 3, 2)
		local id = w:addPoi({ kind = "elite_camp", x = 0, z = 0 })
		live(w)
		run(w, 0.1)
		local pack = {}
		for _, e in w.enemies do
			if e.alive and e.poiId == id then
				table.insert(pack, e)
			end
		end
		T.truthy(#pack > 0)
		local _ = w:drainEvents()
		for _, e in pack do
			w:damageEnemy(e, 1e6, w.players[1])
		end
		run(w, 0.05)
		local evs = w:drainEvents()
		local fx = {}
		local r = nil
		for _, e in evs do
			if e.type == "poiReward" then
				r = e
			end
		end
		T.truthy(r ~= nil or poiOf(w, id).state == "done")
		T.eq(poiOf(w, id).squad, 1)
		T.truthy(#w:groundItems() >= 1 or next(w:gearOf(1)) ~= nil or next(w:gearOf(2)) ~= nil, "a gear item")
		local _ = fx
	end)
	T.it("every v2 POI Fx is JSON-safe", function()
		local w = newWorld(10)
		addHero(w, 1, 0, 0, 1)
		addHero(w, 2, 20, 0, 2)
		for _, kind in { "armory", "cheese_vault", "power_totem", "shop_cart" } do
			w:addPoi({ kind = kind, x = 0, z = 0 })
		end
		live(w)
		local fx = run(w, 9)
		for _, f in fx do
			local ok = pcall(serde.encode, "json", f)
			T.truthy(ok, tostring(f.t))
		end
	end)
end)

T.describe("Stage specials", function()
	T.it("at most one Power Totem, Cheese Vault and Shop Cart per stage; armory in every table", function()
		local seen = { power_totem = 0, cheese_vault = 0, shop_cart = 0 }
		for seed = 1, 400 do
			local ids = Pois.rollStage(Rng.new(seed), "plains")
			local count = { power_totem = 0, cheese_vault = 0, shop_cart = 0 }
			for _, k in ids do
				if count[k] then
					count[k] += 1
				end
			end
			for k, n in count do
				T.truthy(n <= 1, k)
				seen[k] += n
			end
		end
		T.truthy(seen.power_totem > 260 and seen.power_totem < 380, tostring(seen.power_totem))
		T.truthy(seen.shop_cart > 60 and seen.shop_cart < 150, tostring(seen.shop_cart))
		for _, mapId in Maps.ORDER do
			local found = false
			for _, e in (Maps.get(mapId) :: any).poiTable do
				if e.id == "armory" then
					found = true
				end
			end
			T.truthy(found, mapId)
		end
	end)
end)

return T.finish()
