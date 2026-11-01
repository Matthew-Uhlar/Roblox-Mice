local T = require("../lib/Test")
local Enemies = require("../../src/shared/Config/Enemies")
local Bosses = require("../../src/shared/Config/Bosses")
local BossPatterns = require("../../src/shared/Combat/BossPatterns")
local Weapons = require("../../src/shared/Combat/Weapons")
local Maps = require("../../src/shared/Config/Maps")
local Classes = require("../../src/shared/Config/Classes")

local BOSS_IDS = {
	"giant_tree",
	"froggus",
	"serpent_sisters",
	"my_grandma",
	"floating_witch",
	"corndog_bunny",
	"spider_machine",
	"green_gorilla",
	"paper_dinosaur",
	"hematite_snake",
	"ice_dragon",
	"void_cat",
	"zoomzola",
}

local function positive(v: any): boolean
	return type(v) == "number" and v > 0 and v == v
end

T.describe("Config.Enemies", function()
	T.it("ORDER lists the 5 mice and matches byId", function()
		T.deepEq(Enemies.ORDER, { "mouse", "rat_runner", "chonk", "crumb_slinger", "fuse_mouse" })
		for i, id in Enemies.ORDER do
			local d = Enemies.get(id)
			T.truthy(d, id)
			T.eq(d.id, id)
			T.eq(Enemies.indexOf(id), i)
			for _, k in { "hp", "speed", "radius", "contactDamage", "xp" } do
				T.truthy(positive((d :: any)[k]), id .. "." .. k)
			end
		end
		local n = 0
		for _ in Enemies.byId do
			n += 1
		end
		T.eq(n, #Enemies.ORDER)
		T.eq(Enemies.get("nope"), nil)
	end)

	T.it("behaviour-specific fields are present", function()
		local s = Enemies.get("crumb_slinger")
		T.eq(s.behavior, "ranged")
		T.truthy(
			positive(s.rangedRange)
				and positive(s.rangedCooldown)
				and positive(s.projectileSpeed)
				and positive(s.projectileDamage)
		)
		local f = Enemies.get("fuse_mouse")
		T.eq(f.behavior, "fuse")
		T.truthy(positive(f.fuseRadius) and positive(f.fuseDamage))
		T.eq(Enemies.FUSE_TIME, 1, "GDD §7: 1 s fuse")
		T.eq(Enemies.ELITE.hpMult, 3, "GDD §7: elites have 3x HP")
	end)

	T.it("players (walk speed 16) can outrun every mouse but the rat runner barely", function()
		for _, id in Enemies.ORDER do
			T.truthy(Enemies.get(id).speed < 16, id)
		end
	end)

	T.it("every map's enemy pool uses known enemies", function()
		for _, mapId in Maps.ORDER do
			local m = Maps.get and Maps.get(mapId) or nil
			if m then
				for _, e in m.enemyPool do
					T.truthy(Enemies.get(e), mapId .. " -> " .. e)
				end
			end
		end
	end)
end)

T.describe("Config.Bosses", function()
	T.it("has the 13 GDD bosses in a stable order", function()
		T.deepEq(Bosses.ORDER, BOSS_IDS)
		for i, id in Bosses.ORDER do
			T.eq(Bosses.get(id).id, id)
			T.eq(Bosses.kindOf(id), 200 + i)
			T.truthy(Bosses.kindOf(id) <= 255, "fits the u8 snapshot kind")
		end
		T.eq(Bosses.get("nope"), nil)
	end)

	T.it("each boss has sane stats and 3-5 known patterns per phase", function()
		for _, id in Bosses.ORDER do
			local b = Bosses.get(id)
			for _, k in { "hp", "speed", "radius", "contactDamage" } do
				T.truthy(positive((b :: any)[k]), id .. "." .. k)
			end
			T.truthy(type(b.name) == "string" and #b.name > 0)
			T.truthy(type(b.title) == "string" and #b.title > 0)
			T.truthy(#b.patterns >= 3 and #b.patterns <= 5, id .. " phase-1 count")
			T.truthy(
				b.phase2Patterns and #b.phase2Patterns >= 3 and #b.phase2Patterns <= 5,
				id .. " phase-2 count"
			)
			for _, p in b.patterns do
				T.truthy(BossPatterns.has(p), id .. " unknown pattern " .. p)
			end
			for _, p in b.phase2Patterns :: { string } do
				T.truthy(BossPatterns.has(p), id .. " unknown phase-2 pattern " .. p)
			end
		end
	end)

	T.it("phase 2 brings at least one new pattern for every boss", function()
		for _, id in Bosses.ORDER do
			local b = Bosses.get(id)
			local new = 0
			for _, p in b.phase2Patterns :: { string } do
				if not table.find(b.patterns, p) then
					new += 1
				end
			end
			T.truthy(new >= 1, id)
		end
	end)

	T.it("bosses are distinct: no two share a phase-1 pattern set", function()
		local seen = {}
		for _, id in Bosses.ORDER do
			local list = table.clone(Bosses.get(id).patterns)
			table.sort(list)
			local key = table.concat(list, ",")
			T.falsy(seen[key], id .. " duplicates " .. tostring(seen[key]))
			seen[key] = id
		end
	end)

	T.it("signature mechanics: witch roulette, sisters summon minions, spider adapts", function()
		T.eq(BossPatterns.get(Bosses.get("floating_witch").patterns[1]).base, "spell_roulette")
		local ss = BossPatterns.get(Bosses.get("serpent_sisters").patterns[1])
		T.eq(ss.base, "summon")
		T.truthy(ss.minion)
		T.eq(ss.count, 2)
		T.eq(BossPatterns.get(Bosses.get("spider_machine").patterns[1]).base, "adaptive")
	end)

	T.it("every reachable pattern (roulette spells, adaptive branches, minion attacks) exists", function()
		for _, id in Bosses.ORDER do
			local b = Bosses.get(id)
			local all = {}
			for _, p in b.patterns do
				BossPatterns.reachable(p, all)
			end
			for _, p in b.phase2Patterns :: { string } do
				BossPatterns.reachable(p, all)
			end
			for p in all do
				T.truthy(BossPatterns.has(p), id .. " reaches unknown " .. p)
			end
		end
	end)

	T.it("pattern windups honour the 0.6 s telegraph floor", function()
		for id, d in BossPatterns.DEFS do
			if d.windup ~= nil then
				T.truthy(d.windup >= BossPatterns.MIN_TELEGRAPH, id)
			end
		end
	end)
end)

T.describe("Config.Classes vs Combat", function()
	T.it("every class weapon and ability kind is implemented", function()
		for _, id in Classes.ORDER do
			local c = Classes.get(id)
			T.truthy(Weapons.FIRE[c.weapon.kind], id .. " weapon " .. c.weapon.kind)
			T.truthy(Weapons.ABILITY[c.ability.kind], id .. " ability " .. c.ability.kind)
		end
	end)
end)

return T.finish()
