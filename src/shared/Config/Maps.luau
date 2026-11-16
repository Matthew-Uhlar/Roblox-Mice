--!strict
-- The 9 cheese worlds (GDD §6). Layouts are hand-designed by ArenaBuilder;
-- the per-run randomness is which POI fills each slot (GDD §3.2).
--
-- POI ids (Config/Pois.luau defines them) shared by every map: cheese_cache,
-- shrine_swift, shrine_might, shrine_mending, elite_camp, crumb_fountain,
-- mousetrap_field, armory (v2 Armory Crate). Each map also has one
-- map-unique landmark (weight 2 of ~111)
-- that players discover over many runs. The two global rare POIs (Grandma's
-- Pantry 3%, Lost Herd Statue 2%) are rolled once per STAGE on top of this
-- table by Combat/Pois.rollStage, not per slot, and so are the v2 specials
-- (Power Totem, Cheese Vault, Shop Cart: Config/Pois.SPECIALS, at most one each).
-- Enemy ids (defined by Team B in Config/Enemies.luau): mouse, rat_runner,
-- chonk, crumb_slinger, fuse_mouse.

local Types = require("../Types")
local Rng = require("../Util/Rng")

type MapDef = Types.MapDef

local Maps = {}

Maps.ORDER = {
	"plains",
	"forest",
	"jungle",
	"beach",
	"tundra",
	"volcano",
	"swamp",
	"moon",
	"ocean",
}

-- v3 big maps (owner feedback 2026-11): arena radius x2.5 (320-400 studs), POI
-- slots x3 (more of them objective-type: Elite Camps x2 per slot, up to 3 Power
-- Totems / Cheese Vaults per stage), 6 Mouse Champion sites on a middle ring and
-- 1-2 Champion Lairs near the centre (Pois.layout, Config/Champions).
-- The map takes longer to cross, so heroes SPRINT out of combat: x SPRINT.mult
-- move speed after SPRINT.calm s with no damage taken and no enemy within
-- SPRINT.clear studs (Combat/World; getPlayer().walkSpeed / .sprinting).
-- Combat speed is unchanged, so the horde balance is too.
Maps.SPRINT = table.freeze({ mult = 1.3, clear = 18, calm = 2.5 })

-- Launch subset (market research §4): one full cycle of 4 maps.
Maps.LAUNCH = { "plains", "beach", "volcano", "swamp" }

-- Enemy ids Team A expects Team B to define (ConfigData.spec checks them
-- against Config/Enemies.luau when that file exists).
Maps.ENEMY_IDS = { "mouse", "rat_runner", "chonk", "crumb_slinger", "fuse_mouse" }

-- `tweak` overrides a few weights so maps feel different (e.g. more traps on
-- the volcano, more fountains in the swamp).
local function pois(rareId: string, tweak: { [string]: number }?): { { id: string, weight: number } }
	local t = tweak or {}
	local out = {}
	for _, e in
		{
			{ "cheese_cache", 16 }, -- v3: 26 -> 16 (3x slots: about 1.6x the caches per map)
			{ "shrine_swift", 9 },
			{ "shrine_might", 9 },
			{ "shrine_mending", 9 },
			{ "elite_camp", 26 }, -- v3: x2 (was 13): objectives are 2x more common
			{ "crumb_fountain", 14 },
			{ "mousetrap_field", 12 },
			{ "armory", 14 }, -- v2 Armory Crate (common gear source, GDD-v2 §4)
		}
	do
		table.insert(out, { id = e[1], weight = t[e[1]] or e[2] })
	end
	table.insert(out, { id = rareId, weight = 2 })
	return out
end

local defs: { [string]: MapDef } = {
	plains = {
		id = "plains",
		name = "Swiss Highlands",
		cheese = "Swiss",
		groundColor = { 150, 200, 90 },
		accentColor = { 250, 220, 110 },
		size = 350, -- v3: x2.5 (was 140)
		obstacleCount = 30, -- v3: x2 (was 24)
		poiSlots = 30, -- v3: x3 (was 10)
		championSites = 6,
		championLairs = 1,
		poiTable = pois("giant_cowbell"),
		enemyPool = { "mouse", "rat_runner", "crumb_slinger" },
	},
	forest = {
		id = "forest",
		name = "Gouda Forest",
		cheese = "Gouda",
		groundColor = { 70, 130, 60 },
		accentColor = { 230, 170, 60 },
		size = 325, -- v3: x2.5 (was 130)
		obstacleCount = 80, -- v3: x2 (was 40)
		poiSlots = 30, -- v3: x3 (was 10)
		championSites = 6,
		championLairs = 1,
		poiTable = pois("gouda_wheel_hut"),
		enemyPool = { "mouse", "chonk", "crumb_slinger" },
	},
	jungle = {
		id = "jungle",
		name = "Pepper Jack Jungle",
		cheese = "Pepper Jack",
		groundColor = { 40, 120, 50 },
		accentColor = { 245, 230, 170 },
		size = 325, -- v3: x2.5 (was 130)
		obstacleCount = 90, -- v3: x2 (was 45)
		poiSlots = 33, -- v3: x3 (was 11)
		championSites = 6,
		championLairs = 1,
		poiTable = pois("pepper_idol", { mousetrap_field = 16, cheese_cache = 14 }),
		enemyPool = { "mouse", "rat_runner", "fuse_mouse" },
	},
	beach = {
		id = "beach",
		name = "Parmesan Isles",
		cheese = "Parmesan",
		groundColor = { 240, 225, 170 },
		accentColor = { 60, 170, 220 },
		size = 375, -- v3: x2.5 (was 150)
		obstacleCount = 36, -- v3: x2 (was 18)
		poiSlots = 27, -- v3: x3 (was 9)
		championSites = 6,
		championLairs = 2,
		poiTable = pois("message_bottle"),
		enemyPool = { "mouse", "rat_runner", "crumb_slinger" },
	},
	tundra = {
		id = "tundra",
		name = "Blue Cheese Tundra",
		cheese = "Blue",
		groundColor = { 220, 230, 240 },
		accentColor = { 90, 120, 190 },
		size = 350, -- v3: x2.5 (was 140)
		obstacleCount = 44, -- v3: x2 (was 22)
		poiSlots = 27, -- v3: x3 (was 9)
		championSites = 6,
		championLairs = 1,
		poiTable = pois("frozen_mammoth"),
		enemyPool = { "mouse", "chonk", "fuse_mouse" },
	},
	volcano = {
		id = "volcano",
		name = "Cheddar Volcano",
		cheese = "Cheddar",
		groundColor = { 90, 50, 40 },
		accentColor = { 255, 150, 30 },
		size = 325, -- v3: x2.5 (was 130)
		obstacleCount = 60, -- v3: x2 (was 30)
		poiSlots = 30, -- v3: x3 (was 10)
		championSites = 6,
		championLairs = 1,
		poiTable = pois("molten_fondue", { mousetrap_field = 18, elite_camp = 32, cheese_cache = 12 }),
		enemyPool = { "mouse", "fuse_mouse", "chonk", "crumb_slinger" },
	},
	swamp = {
		id = "swamp",
		name = "Moldy Swamp",
		cheese = "Moldy",
		groundColor = { 80, 100, 60 },
		accentColor = { 150, 200, 80 },
		size = 320, -- v3: x2.5 (was 125)
		obstacleCount = 70, -- v3: x2 (was 35)
		poiSlots = 36, -- v3: x3 (was 12)
		championSites = 6,
		championLairs = 1,
		poiTable = pois("witch_hut", { crumb_fountain = 18, shrine_mending = 12, cheese_cache = 13 }),
		enemyPool = { "mouse", "chonk", "fuse_mouse", "rat_runner" },
	},
	moon = {
		id = "moon",
		name = "Mozzarella Moon",
		cheese = "Mozzarella",
		groundColor = { 200, 200, 210 },
		accentColor = { 250, 250, 235 },
		size = 400, -- v3: x2.5 (was 160)
		obstacleCount = 40, -- v3: x2 (was 20)
		poiSlots = 24, -- v3: x3 (was 8)
		championSites = 6,
		championLairs = 2,
		poiTable = pois("crashed_rocket", { shrine_swift = 13, mousetrap_field = 8 }),
		enemyPool = { "mouse", "rat_runner", "crumb_slinger", "fuse_mouse" },
	},
	ocean = {
		id = "ocean",
		name = "Feta Deep",
		cheese = "Feta-in-brine",
		groundColor = { 20, 60, 110 },
		accentColor = { 240, 240, 230 },
		size = 340, -- v3: x2.5 (was 135)
		obstacleCount = 56, -- v3: x2 (was 28)
		poiSlots = 33, -- v3: x3 (was 11)
		championSites = 6,
		championLairs = 2,
		poiTable = pois("sunken_chest", { elite_camp = 32, cheese_cache = 14 }),
		enemyPool = { "mouse", "rat_runner", "chonk", "crumb_slinger", "fuse_mouse" },
	},
}

Maps.defs = defs

function Maps.get(id: string): MapDef?
	return defs[id]
end

-- Fills every POI slot of a map from its weighted table. Returns one POI id per
-- slot (array of length poiSlots). Deterministic for a given rng state.
function Maps.rollPois(rng: Rng.Rng, mapId: string): { string }
	local def = defs[mapId]
	assert(def, "Maps.rollPois: unknown map " .. tostring(mapId))
	local weights = {}
	for i, entry in def.poiTable do
		weights[i] = entry.weight
	end
	local out = {}
	for slot = 1, def.poiSlots do
		out[slot] = def.poiTable[rng:weightedIndex(weights)].id
	end
	return out
end

return Maps
