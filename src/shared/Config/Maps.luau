--!strict
-- The 9 cheese worlds (GDD §6). Layouts are hand-designed by ArenaBuilder;
-- the per-run randomness is which POI fills each slot (GDD §3.2).
--
-- POI ids shared by every map: shrine_power, shrine_speed, cheese_cache,
-- elite_camp, healing_spring. Each map also has one rare, map-unique POI
-- (weight 3 against ~100 total) that players discover over many runs.
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

-- Launch subset (market research §4): one full cycle of 4 maps.
Maps.LAUNCH = { "plains", "beach", "volcano", "swamp" }

-- Enemy ids Team A expects Team B to define (ConfigData.spec checks them
-- against Config/Enemies.luau when that file exists).
Maps.ENEMY_IDS = { "mouse", "rat_runner", "chonk", "crumb_slinger", "fuse_mouse" }

local function pois(rareId: string): { { id: string, weight: number } }
	return {
		{ id = "shrine_power", weight = 20 },
		{ id = "shrine_speed", weight = 20 },
		{ id = "cheese_cache", weight = 30 },
		{ id = "elite_camp", weight = 15 },
		{ id = "healing_spring", weight = 12 },
		{ id = rareId, weight = 3 },
	}
end

local defs: { [string]: MapDef } = {
	plains = {
		id = "plains",
		name = "Swiss Highlands",
		cheese = "Swiss",
		groundColor = { 150, 200, 90 },
		accentColor = { 250, 220, 110 },
		size = 140,
		obstacleCount = 24,
		poiSlots = 10,
		poiTable = pois("giant_cowbell"),
		enemyPool = { "mouse", "rat_runner", "crumb_slinger" },
	},
	forest = {
		id = "forest",
		name = "Gouda Forest",
		cheese = "Gouda",
		groundColor = { 70, 130, 60 },
		accentColor = { 230, 170, 60 },
		size = 130,
		obstacleCount = 40,
		poiSlots = 10,
		poiTable = pois("gouda_wheel_hut"),
		enemyPool = { "mouse", "chonk", "crumb_slinger" },
	},
	jungle = {
		id = "jungle",
		name = "Pepper Jack Jungle",
		cheese = "Pepper Jack",
		groundColor = { 40, 120, 50 },
		accentColor = { 245, 230, 170 },
		size = 130,
		obstacleCount = 45,
		poiSlots = 11,
		poiTable = pois("pepper_idol"),
		enemyPool = { "mouse", "rat_runner", "fuse_mouse" },
	},
	beach = {
		id = "beach",
		name = "Parmesan Isles",
		cheese = "Parmesan",
		groundColor = { 240, 225, 170 },
		accentColor = { 60, 170, 220 },
		size = 150,
		obstacleCount = 18,
		poiSlots = 9,
		poiTable = pois("message_bottle"),
		enemyPool = { "mouse", "rat_runner", "crumb_slinger" },
	},
	tundra = {
		id = "tundra",
		name = "Blue Cheese Tundra",
		cheese = "Blue",
		groundColor = { 220, 230, 240 },
		accentColor = { 90, 120, 190 },
		size = 140,
		obstacleCount = 22,
		poiSlots = 9,
		poiTable = pois("frozen_mammoth"),
		enemyPool = { "mouse", "chonk", "fuse_mouse" },
	},
	volcano = {
		id = "volcano",
		name = "Cheddar Volcano",
		cheese = "Cheddar",
		groundColor = { 90, 50, 40 },
		accentColor = { 255, 150, 30 },
		size = 130,
		obstacleCount = 30,
		poiSlots = 10,
		poiTable = pois("molten_fondue"),
		enemyPool = { "mouse", "fuse_mouse", "chonk", "crumb_slinger" },
	},
	swamp = {
		id = "swamp",
		name = "Moldy Swamp",
		cheese = "Moldy",
		groundColor = { 80, 100, 60 },
		accentColor = { 150, 200, 80 },
		size = 125,
		obstacleCount = 35,
		poiSlots = 12,
		poiTable = pois("witch_hut"),
		enemyPool = { "mouse", "chonk", "fuse_mouse", "rat_runner" },
	},
	moon = {
		id = "moon",
		name = "Mozzarella Moon",
		cheese = "Mozzarella",
		groundColor = { 200, 200, 210 },
		accentColor = { 250, 250, 235 },
		size = 160,
		obstacleCount = 20,
		poiSlots = 8,
		poiTable = pois("crashed_rocket"),
		enemyPool = { "mouse", "rat_runner", "crumb_slinger", "fuse_mouse" },
	},
	ocean = {
		id = "ocean",
		name = "Feta Deep",
		cheese = "Feta-in-brine",
		groundColor = { 20, 60, 110 },
		accentColor = { 240, 240, 230 },
		size = 135,
		obstacleCount = 28,
		poiSlots = 11,
		poiTable = pois("sunken_chest"),
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
