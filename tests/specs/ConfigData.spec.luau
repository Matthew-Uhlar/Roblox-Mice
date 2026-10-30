local T = require("../lib/Test")
local fs = require("@lune/fs")
local Classes = require("../../src/shared/Config/Classes")
local Upgrades = require("../../src/shared/Config/Upgrades")
local Modifiers = require("../../src/shared/Config/Modifiers")
local Maps = require("../../src/shared/Config/Maps")
local Stats = require("../../src/shared/Run/Stats")
local RunState = require("../../src/shared/Run/RunState")
local Rng = require("../../src/shared/Util/Rng")

local WEAPON_KINDS =
	{ melee_arc = true, bolt = true, spread = true, cone = true, orbit = true, lob = true, puddle = true }
local ABILITY_KINDS =
	{ dash = true, burst = true, ring = true, shield = true, puddle = true, hover = true, field = true }
local RARITIES = { Common = true, Rare = true, Epic = true, Legendary = true }
local TIERS = { Low = true, Mid = true, High = true }
local WEAPON_FIELDS = {
	damage = true,
	cooldown = true,
	range = true,
	count = true,
	speed = true,
	pierce = true,
	area = true,
	knockback = true,
	duration = true,
}
local ABILITY_NUM_FIELDS = { cooldown = true, damage = true, area = true, distance = true, duration = true }
local WORLD_DEFAULT = Stats.defaultWorldMods()

local function isRgb(c: any): boolean
	if type(c) ~= "table" or #c ~= 3 then
		return false
	end
	for i = 1, 3 do
		if type(c[i]) ~= "number" or c[i] < 0 or c[i] > 255 or c[i] % 1 ~= 0 then
			return false
		end
	end
	return true
end

local function count(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

-- Every key in a StatDelta must exist in Stats.DEFAULT / WeaponDef.
local function checkDelta(where: string, delta: any)
	T.truthy(type(delta) == "table", where .. ": delta must be a table")
	for key in delta do
		T.truthy(
			key == "add" or key == "mul" or key == "weapon" or key == "heal",
			where .. ": unknown delta key " .. key
		)
	end
	for _, part in { "add", "mul" } do
		if delta[part] then
			for k, v in delta[part] do
				T.truthy(
					(Stats.DEFAULT :: any)[k] ~= nil,
					where .. ": stat '" .. k .. "' not in Stats.DEFAULT"
				)
				T.eq(type(v), "number", where .. "." .. k)
				if part == "mul" then
					T.truthy(v > 0 and v ~= 1, where .. ": mul " .. k .. " must be > 0 and not 1")
				else
					T.truthy(v ~= 0, where .. ": add " .. k .. " must not be 0")
				end
			end
		end
	end
	if delta.weapon then
		for k, v in delta.weapon do
			T.truthy(WEAPON_FIELDS[k], where .. ": weapon field '" .. k .. "' unknown")
			T.eq(type(v), "number", where .. ".weapon." .. k)
		end
	end
	if delta.heal ~= nil then
		T.truthy(delta.heal > 0 and delta.heal <= 1, where .. ": heal must be in (0, 1]")
	end
end

local function checkAbilityMul(where: string, mul: any)
	if mul == nil then
		return
	end
	for k, v in mul do
		T.truthy(ABILITY_NUM_FIELDS[k], where .. ": abilityMul field '" .. k .. "' unknown")
		T.truthy(type(v) == "number" and v > 0, where .. ": abilityMul must be > 0")
	end
end

local function deltaIsEmpty(delta: any, abilityMul: any): boolean
	return (delta.add == nil or next(delta.add) == nil)
		and (delta.mul == nil or next(delta.mul) == nil)
		and (delta.weapon == nil or next(delta.weapon) == nil)
		and delta.heal == nil
		and (abilityMul == nil or next(abilityMul) == nil)
end

T.describe("Config.Classes", function()
	T.it("has the 7 GDD classes in ORDER with matching defs", function()
		T.deepEq(
			Classes.ORDER,
			{ "elephante", "ele_fonte", "ellie_fawn", "le_fante", "filet", "jumbo", "fizzante" }
		)
		T.eq(count(Classes.defs), 7)
		for _, id in Classes.ORDER do
			local def = Classes.get(id)
			T.truthy(def, id)
			assert(def)
			T.eq(def.id, id)
		end
	end)
	T.it("get returns nil for unknown ids", function()
		T.eq(Classes.get("dumbo"), nil)
	end)
	T.it("has 3 free classes and 4 paid ones", function()
		T.deepEq(Classes.freeIds(), { "elephante", "ele_fonte", "ellie_fawn" })
		T.eq(Classes.get("le_fante").unlockCost, 2500)
		T.eq(Classes.get("filet").unlockCost, 2500)
		T.eq(Classes.get("jumbo").unlockCost, 4000)
		T.eq(Classes.get("fizzante").unlockCost, 4000)
		T.truthy(Classes.isFree("elephante"))
		T.falsy(Classes.isFree("jumbo"))
		T.falsy(Classes.isFree("nope"))
	end)
	T.it("every class has valid text, color, weapon and ability", function()
		for _, id in Classes.ORDER do
			local def = Classes.get(id) :: any
			for _, field in { "name", "role", "description", "passiveText" } do
				T.truthy(type(def[field]) == "string" and #def[field] > 0, id .. "." .. field)
			end
			T.truthy(isRgb(def.color), id .. ": color must be {r,g,b} 0..255")
			T.truthy(def.unlockCost >= 0, id .. ": unlockCost")
			for k, v in def.baseStats do
				T.truthy(
					(Stats.DEFAULT :: any)[k] ~= nil,
					id .. ": baseStat " .. k .. " not in Stats.DEFAULT"
				)
				T.eq(type(v), "number")
			end
			local w = def.weapon
			T.truthy(WEAPON_KINDS[w.kind], id .. ": weapon kind " .. tostring(w.kind))
			for _, f in { "damage", "cooldown", "range", "count", "speed", "pierce", "area", "knockback" } do
				T.truthy(type(w[f]) == "number" and w[f] >= 0, id .. ".weapon." .. f)
			end
			T.truthy(w.damage > 0 and w.cooldown > 0 and w.count >= 1, id .. ": weapon must do something")
			if w.kind == "bolt" or w.kind == "spread" or w.kind == "lob" or w.kind == "orbit" then
				T.truthy(w.speed > 0, id .. ": projectile weapons need speed")
			end
			local a = def.ability
			T.truthy(ABILITY_KINDS[a.kind], id .. ": ability kind " .. tostring(a.kind))
			T.truthy(#a.name > 0 and #a.description > 0, id .. ": ability text")
			T.truthy(a.cooldown > 0, id .. ": ability cooldown")
		end
	end)
	T.it("passives match the GDD numbers", function()
		T.eq(Classes.get("elephante").baseStats.maxHp, Stats.DEFAULT.maxHp * 1.25)
		T.eq(Classes.get("ele_fonte").baseStats.pierceBonus, 1)
		T.near(Classes.get("ellie_fawn").baseStats.moveSpeed, Stats.DEFAULT.moveSpeed * 1.15)
		T.near(Classes.get("le_fante").baseStats.critChance, Stats.DEFAULT.critChance + 0.15)
		T.near(Classes.get("jumbo").baseStats.pickupRadius, Stats.DEFAULT.pickupRadius * 1.3)
		T.near(Classes.get("fizzante").baseStats.areaMult, 1.2)
		T.eq(Classes.get("ellie_fawn").weapon.count, 3)
	end)
	T.it("ability kinds follow the GDD table", function()
		local expect = {
			elephante = "dash",
			ele_fonte = "burst",
			ellie_fawn = "ring",
			le_fante = "shield",
			filet = "puddle",
			jumbo = "hover",
			fizzante = "field",
		}
		for id, kind in expect do
			T.eq(Classes.get(id).ability.kind, kind, id)
		end
	end)
end)

T.describe("Config.Upgrades", function()
	T.it("has about 40 upgrades with unique ids", function()
		T.truthy(#Upgrades.list >= 36 and #Upgrades.list <= 60, "count " .. #Upgrades.list)
		local seen = {}
		for _, u in Upgrades.list do
			T.falsy(seen[u.id], "duplicate " .. u.id)
			seen[u.id] = true
			T.eq(Upgrades.get(u.id), u)
		end
	end)
	T.it("every upgrade is well formed", function()
		for _, u in Upgrades.list do
			T.truthy(#u.name > 0 and #u.description > 0, u.id .. ": text")
			T.truthy(RARITIES[u.rarity], u.id .. ": rarity")
			T.truthy(u.maxStacks >= 1 and u.maxStacks % 1 == 0, u.id .. ": maxStacks")
			if u.classOnly then
				T.truthy(
					Classes.get(u.classOnly),
					u.id .. ": classOnly " .. u.classOnly .. " does not resolve"
				)
			end
			checkDelta("upgrade " .. u.id, u.delta)
			checkAbilityMul("upgrade " .. u.id, u.abilityMul)
			T.falsy(deltaIsEmpty(u.delta, u.abilityMul), u.id .. ": does nothing")
		end
	end)
	T.it("spreads across all rarities", function()
		local n = { Common = 0, Rare = 0, Epic = 0, Legendary = 0 }
		for _, u in Upgrades.list do
			n[u.rarity] += 1
		end
		T.truthy(n.Common >= 10, "Common " .. n.Common)
		T.truthy(n.Rare >= 8, "Rare " .. n.Rare)
		T.truthy(n.Epic >= 5, "Epic " .. n.Epic)
		T.truthy(n.Legendary >= 2, "Legendary " .. n.Legendary)
	end)
	T.it("has class-only upgrades for several classes", function()
		local classes = {}
		for _, u in Upgrades.list do
			if u.classOnly then
				classes[u.classOnly] = true
			end
		end
		T.truthy(count(classes) >= 5)
	end)
	T.it("covers the big-change stat fields", function()
		local used = {}
		for _, u in Upgrades.list do
			for _, part in { "add", "mul" } do
				local p = (u.delta :: any)[part]
				if p then
					for k in p do
						used[k] = true
					end
				end
			end
		end
		for _, k in { "chain", "explodeOnKill", "lifesteal", "extraOrbiters", "projectileBonus" } do
			T.truthy(used[k], "no upgrade uses " .. k)
		end
	end)
	T.it("no tiny % stats (pillar 2)", function()
		for _, u in Upgrades.list do
			local d = u.delta :: any
			if d.mul then
				for k, v in d.mul do
					-- Buffs must be >= 20%; small downsides on trade-off cards are fine.
					local isBuff = if k == "cooldownMult" then v < 1 else v > 1
					if isBuff then
						T.truthy(math.abs(v - 1) >= 0.2 - 1e-9, u.id .. ": mul " .. k .. " too small")
					end
				end
			end
			if d.add then
				for k, v in d.add do
					if k == "critChance" or k == "lifesteal" then
						T.truthy(v >= 0.08, u.id .. ": " .. k .. " too small")
					end
				end
			end
		end
	end)
end)

T.describe("Config.Modifiers", function()
	T.it("has unique ids and a valid tier/kind for each", function()
		local seen = {}
		for _, m in Modifiers.list do
			T.falsy(seen[m.id], "duplicate " .. m.id)
			seen[m.id] = true
			T.truthy(TIERS[m.tier], m.id .. ": tier")
			T.truthy(m.kind == "curse" or m.kind == "blessing", m.id .. ": kind")
			T.truthy(#m.name > 0 and #m.description > 0, m.id .. ": text")
			T.eq(Modifiers.get(m.id), m)
		end
	end)
	T.it("has at least 4 curses and 4 blessings per tier", function()
		for tier in TIERS do
			T.truthy(#Modifiers.ids("curse", tier :: any) >= 4, "curses " .. tier)
			T.truthy(#Modifiers.ids("blessing", tier :: any) >= 4, "blessings " .. tier)
		end
	end)
	T.it("curses only touch real WorldMods fields with the right types", function()
		for _, m in Modifiers.list do
			if m.kind == "curse" then
				T.truthy(m.world ~= nil and next(m.world :: any) ~= nil, m.id .. ": curse needs world")
				T.eq(m.delta, nil, m.id .. ": curse must not have delta")
				for k, v in m.world :: any do
					local cur = (WORLD_DEFAULT :: any)[k]
					T.truthy(cur ~= nil, m.id .. ": world field '" .. k .. "' not in WorldMods")
					T.eq(type(v), type(cur), m.id .. "." .. k)
					if type(v) == "number" and string.sub(k, -4) == "Mult" then
						T.truthy(v > 0, m.id .. "." .. k .. " must be > 0")
					end
				end
			end
		end
	end)
	T.it("blessings carry a valid delta", function()
		for _, m in Modifiers.list do
			if m.kind == "blessing" then
				T.eq(m.world, nil, m.id .. ": blessing must not have world")
				checkDelta("blessing " .. m.id, m.delta)
				checkAbilityMul("blessing " .. m.id, m.abilityMul)
				T.falsy(deltaIsEmpty(m.delta, m.abilityMul), m.id .. ": does nothing")
			end
		end
	end)
	T.it("includes the brainstorm modifiers", function()
		local oneHit, rocks, fast = false, false, false
		for _, m in Modifiers.list do
			local w = m.world :: any
			if w then
				oneHit = oneHit or w.oneHitKO == true
				rocks = rocks or w.fallingRocks == true
				fast = fast or (w.enemySpeedMult or 1) > 1
			end
		end
		T.truthy(oneHit and rocks and fast)
		local high = Modifiers.ids("blessing", "High")
		local function has(id: string): boolean
			return table.find(high, id) ~= nil
		end
		T.truthy(has("bless_extra_projectile"))
		T.truthy(has("bless_jumbo_abilities"))
		T.truthy(has("bless_hyper_cooldown"))
		T.eq(Modifiers.get("bless_hyper_cooldown").delta.mul.cooldownMult, 0.5)
		T.eq(Modifiers.get("bless_jumbo_abilities").abilityMul.area, 2)
	end)
	T.it("curse durations: High is run-long, others stage-only", function()
		T.eq(Modifiers.curseDuration("Low"), "stage")
		T.eq(Modifiers.curseDuration("Mid"), "stage")
		T.eq(Modifiers.curseDuration("High"), "run")
	end)
	T.it("ids() returns a copy", function()
		local a = Modifiers.ids("curse", "Low")
		table.insert(a, "junk")
		T.eq(table.find(Modifiers.ids("curse", "Low"), "junk"), nil)
	end)
end)

T.describe("Config.Maps", function()
	T.it("has the 9 GDD maps in ORDER", function()
		T.eq(#Maps.ORDER, 9)
		T.eq(count(Maps.defs), 9)
		local seen = {}
		for _, id in Maps.ORDER do
			T.falsy(seen[id])
			seen[id] = true
			local def = Maps.get(id)
			T.truthy(def, id)
			assert(def)
			T.eq(def.id, id)
		end
		for _, id in Maps.LAUNCH do
			T.truthy(Maps.get(id), "launch map " .. id)
		end
	end)
	T.it("every map is well formed", function()
		local cheeses = {}
		for _, id in Maps.ORDER do
			local def = Maps.get(id) :: any
			T.truthy(#def.name > 0 and #def.cheese > 0, id .. ": text")
			T.falsy(cheeses[def.cheese], id .. ": cheese theme repeats")
			cheeses[def.cheese] = true
			T.truthy(isRgb(def.groundColor) and isRgb(def.accentColor), id .. ": colors")
			T.truthy(def.size >= 60, id .. ": size")
			T.truthy(def.obstacleCount >= 0 and def.obstacleCount % 1 == 0, id .. ": obstacleCount")
			T.truthy(def.poiSlots >= 8 and def.poiSlots <= 12, id .. ": poiSlots must be 8-12 (GDD)")
			T.truthy(#def.poiTable >= 2, id .. ": poiTable")
			local poiSeen = {}
			for _, p in def.poiTable do
				T.truthy(type(p.id) == "string" and #p.id > 0, id .. ": poi id")
				T.falsy(poiSeen[p.id], id .. ": duplicate poi " .. p.id)
				poiSeen[p.id] = true
				T.truthy(p.weight > 0, id .. ": poi weight")
			end
			T.truthy(#def.enemyPool >= 1, id .. ": enemyPool")
			T.truthy(table.find(def.enemyPool, "mouse") ~= nil, id .. ": every map has basic mice")
		end
	end)
	T.it("enemy pools reference known enemy ids", function()
		local known = {}
		if fs.isFile("src/shared/Config/Enemies.luau") then
			local Enemies = (require :: any)("../../src/shared/Config/Enemies")
			for _, id in Enemies.ORDER do
				known[id] = true
			end
		else
			for _, id in Maps.ENEMY_IDS do
				known[id] = true
			end
		end
		for _, id in Maps.ORDER do
			for _, e in (Maps.get(id) :: any).enemyPool do
				T.truthy(known[e], id .. ": unknown enemy " .. e)
			end
		end
		for _, e in Maps.ENEMY_IDS do
			T.truthy(known[e], "Maps.ENEMY_IDS has unknown " .. e)
		end
	end)
	T.it("rollPois fills every slot deterministically", function()
		local a = Maps.rollPois(Rng.new(4), "swamp")
		local b = Maps.rollPois(Rng.new(4), "swamp")
		T.eq(#a, Maps.get("swamp").poiSlots)
		T.deepEq(a, b)
		local valid = {}
		for _, p in Maps.get("swamp").poiTable do
			valid[p.id] = true
		end
		for _, p in a do
			T.truthy(valid[p])
		end
		T.throws(function()
			Maps.rollPois(Rng.new(1), "atlantis")
		end)
	end)
	T.it("rare POIs show up, but rarely", function()
		local rng = Rng.new(11)
		local rare, total = 0, 0
		for _ = 1, 300 do
			for _, p in Maps.rollPois(rng, "ocean") do
				total += 1
				if p == "sunken_chest" then
					rare += 1
				end
			end
		end
		T.truthy(rare > 0 and rare / total < 0.08, "rare share " .. rare / total)
	end)
end)

T.describe("Config.Bosses cross-check", function()
	T.it("default boss ids are 13 unique ids and match Config/Bosses when present", function()
		local ids = RunState.DEFAULT_BOSS_IDS
		T.eq(#ids, 13)
		local seen = {}
		for _, id in ids do
			T.falsy(seen[id])
			seen[id] = true
		end
		if fs.isFile("src/shared/Config/Bosses.luau") then
			local Bosses = (require :: any)("../../src/shared/Config/Bosses")
			for _, id in ids do
				T.truthy(table.find(Bosses.ORDER, id) ~= nil, "Bosses.ORDER lacks " .. id)
			end
		end
	end)
end)

T.describe("Config.Talents cross-check", function()
	T.it("talent deltas only use Stats.DEFAULT fields and compute cleanly", function()
		if not fs.isFile("src/shared/Config/Talents.luau") then
			return
		end
		local Talents = (require :: any)("../../src/shared/Config/Talents")
		local levels = {}
		for _, id in Talents.ORDER do
			local def = Talents.get(id)
			T.truthy(def and def.perLevel, "talent " .. id)
			checkDelta("talent " .. id, def.perLevel)
			levels[id] = def.maxLevel
		end
		local base = Stats.compute("elephante", {}, {})
		local maxed = Stats.compute("elephante", {}, {}, levels, Talents.defs)
		T.truthy(maxed.maxHp >= base.maxHp)
	end)
end)

return T.finish()
