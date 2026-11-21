--!strict
-- Iteration 5 Phase B (team Abilities): damage meter (#1), Whey / Crumb Totems (#4),
-- Quick Study rank (#5), Squad Stall shared whey buff (#9).
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Weapons = require("../../src/shared/Combat/Weapons")
local Defaults = require("../../src/shared/Combat/Defaults")
local PoiConfig = require("../../src/shared/Config/Pois")
local Pois = require("../../src/shared/Combat/Pois")
local Maps = require("../../src/shared/Config/Maps")
local RunShop = require("../../src/shared/Config/RunShop")
local RunWallet = require("../../src/shared/Run/RunWallet")

local DT = 1 / 30

local function newWorld(seed: number): any
	return World.new({
		rng = Rng.new(seed),
		mods = Defaults.mods(),
		arenaRadius = 120,
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

local function addHero(w: any, id: number, x: number, z: number, squad: number)
	w:addPlayer(id, Defaults.stats(), harmless(), Defaults.ability("burst"), x, z, squad)
end

local function run(w: any, seconds: number): { any }
	local evs = {}
	local t = w.now
	for _ = 1, math.floor(seconds / DT + 0.5) do
		t += DT
		w:step(DT, t)
		for _, e in w:drainEvents() do
			table.insert(evs, e)
		end
	end
	return evs
end

T.describe("#1 damage meter", function()
	T.it("tracks PvE / PvP damage, heal, taken, kills and deaths per hero", function()
		local w = newWorld(3)
		addHero(w, 1, 0, 0, 1)
		addHero(w, 2, 60, 0, 2)
		run(w, DT)
		w.players[1].stats.critChance = 0
		w.cap = 10
		local e = w:spawnEnemy("mouse", 30, 30)
		e.hp, e.maxHp = 100, 100
		Weapons.hit(w, w.players[1], e, 40, nil)
		local m = w:meter()[1]
		T.truthy(m.pveDmg >= 40 and m.dmg == m.pveDmg, "pve " .. m.pveDmg)
		Weapons.hit(w, w.players[1], e, 1e6, nil) -- overkill counts only the HP left
		m = w:meter()[1]
		T.near(m.pveDmg, 100 * (w.players[1].stats.pveDamageMult or 1) ^ 0, 101)
		T.eq(m.kills, 1)
		-- PvP: hero 1 hits hero 2
		w.players[1].protectUntil, w.players[2].protectUntil = 0, 0
		local hp0 = w.players[2].hp
		w:damageHeroFrom(w.players[2], 20, w.players[1])
		local lost = hp0 - w.players[2].hp
		T.truthy(lost > 0, "pvp lands")
		local m1, m2 = w:meter()[1], w:meter()[2]
		T.near(m1.pvpDmg, lost, 1)
		T.near(m2.taken, lost, 1)
		T.eq(m1.dmg, m1.pveDmg + m1.pvpDmg)
		-- heal counts HP restored only
		w:healPlayer(2, 0.05)
		T.truthy(w:meter()[2].heal > 0)
		-- death + the killer's kill
		w:_kill(w.players[2], 1)
		T.eq(w:meter()[2].deaths, 1)
		T.eq(w:meter()[1].kills, 2)
		-- survives a re-add in the same World
		addHero(w, 2, 60, 0, 2)
		T.eq(w:meter()[2].deaths, 1)
	end)
end)

T.describe("#4 Whey / Crumb Totems", function()
	T.it("config: totem kinds, at most one of each per stage", function()
		T.eq(PoiConfig.totemKind("power_totem"), "power")
		T.eq(PoiConfig.totemKind("whey_totem"), "whey")
		T.eq(PoiConfig.totemKind("crumb_totem"), "crumb")
		T.eq(PoiConfig.totemKind("cheese_cache"), nil)
		for seed = 1, 200 do
			local ids = Pois.rollStage(Rng.new(seed), Maps.ORDER[(seed % #Maps.ORDER) + 1])
			local n = { whey_totem = 0, crumb_totem = 0 }
			for _, id in ids do
				if n[id] then
					n[id] += 1
				end
			end
			T.truthy(n.whey_totem <= 1 and n.crumb_totem <= 1, "seed " .. seed)
		end
	end)

	T.it("the owner squad gets x whey and x XP; the Power Totem's damage stays apart", function()
		local w = newWorld(5)
		addHero(w, 1, 0, 0, 1)
		addHero(w, 2, 90, 0, 2)
		w:addPoi({ kind = "whey_totem", x = 0, z = 0 })
		w:startWaves(300)
		local evs = run(w, PoiConfig.get("whey_totem").channel + 0.5)
		local got = nil
		for _, e in evs do
			if e.kind == "totem_owner" then
				got = e
			end
		end
		T.truthy(got, "captured")
		T.eq(got.totem, "whey")
		T.eq(got.mult, PoiConfig.WHEY_TOTEM_MULT)
		T.eq(w:squadDamageMult(1), 1, "no damage buff")
		w:drainEvents()
		w:_grantWhey(w.players[1], 10, "test")
		w:_grantWhey(w.players[2], 10, "test")
		local whey = {}
		for _, e in w:drainEvents() do
			if e.type == "whey" then
				whey[e.id] = e.amount
			end
		end
		T.near(whey[1], 10 * PoiConfig.WHEY_TOTEM_MULT, 1e-9)
		T.near(whey[2], 10, 1e-9)

		local w2 = newWorld(6)
		addHero(w2, 1, 0, 0, 1)
		w2:addPoi({ kind = "crumb_totem", x = 0, z = 0 })
		w2:startWaves(300)
		run(w2, PoiConfig.get("crumb_totem").channel + 0.5)
		T.near(w2:_xpMult(w2.players[1]), PoiConfig.CRUMB_TOTEM_XP_MULT, 1e-9)
	end)
end)

T.describe("#5 Quick Study", function()
	T.it("is a rank with the usual linear price and raises xpMult (capped)", function()
		local def = RunShop.RANKS.quick_study
		T.truthy(def, "rank exists")
		T.truthy(RunWallet.rankCost("quick_study", 0) ~= nil)
		T.eq(RunWallet.rankCost("quick_study", 3), def.base + def.step * 3)
		local d = RunShop.rankDelta({ quick_study = 5 })
		T.near(d.mul.xpMult, 1 + 5 * def.pct.xpMult, 1e-9)
		local big = RunShop.rankDelta({ quick_study = 250 })
		T.near(big.mul.xpMult, 1 + def.cap.xpMult, 1e-9)
		-- through the World's run layer into XP gain
		local w = newWorld(8)
		addHero(w, 1, 0, 0, 1)
		w:setRunMods(1, RunShop.rankDelta({ quick_study = 5 }))
		T.near(w:_xpMult(w.players[1]), 1 + 5 * def.pct.xpMult, 1e-9)
	end)
end)

T.describe("#9 Squad Stall", function()
	T.it("a squad buff reaches standing squadmates within 30 studs, once, never foes", function()
		local def = RunShop.BUFFS.rally
		T.truthy(def and def.squad, "rally is a squad buff")
		T.truthy(table.find(RunShop.BUFF_ORDER, "rally") ~= nil, "offered at stalls")
		local w = newWorld(9)
		addHero(w, 1, 0, 0, 1)
		addHero(w, 2, 20, 0, 1) -- squadmate, near
		addHero(w, 3, 0, 50, 1) -- squadmate, far
		addHero(w, 4, 10, 0, 2) -- foe, near
		local regen0 = w.players[2].stats.regen
		local mods = RunShop.combine({}, { "rally" }, {}, nil, false)
		T.deepEq((mods :: any).share, { "rally" })
		w:setRunMods(1, mods)
		run(w, DT)
		T.deepEq(w:sharedBuffs(2), { "rally" })
		T.deepEq(w:sharedBuffs(3), {})
		T.deepEq(w:sharedBuffs(4), {})
		T.deepEq(w:sharedBuffs(1), {}, "the owner has its own copy")
		T.near(w.players[2].stats.regen, regen0 + 0.5, 1e-9)
		-- two owners: still one copy for the mate
		w:setRunMods(3, mods)
		w:setPlayerPosition(3, 25, 5)
		run(w, World.SHARE_TICK + DT)
		T.deepEq(w:sharedBuffs(2), { "rally" })
		T.near(w.players[2].stats.regen, regen0 + 0.5, 1e-9)
		-- the mate walks away: the share ends at the next refresh
		w:setPlayerPosition(2, -60, 0)
		run(w, World.SHARE_TICK + DT)
		T.deepEq(w:sharedBuffs(2), {})
		T.near(w.players[2].stats.regen, regen0, 1e-9)
		-- RunWallet keeps the share list
		local wl = RunWallet.new()
		wl.buffs = { "rally" }
		T.deepEq((RunWallet.deltas(wl, nil) :: any).share, { "rally" })
	end)
end)

return T.finish()
