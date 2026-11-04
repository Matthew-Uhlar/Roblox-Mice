--!strict
-- The 9 cheese worlds (GDD §6). Layouts are hand-designed by ArenaBuilder;
-- the per-run randomness is which POI fills each slot (GDD §3.2).
--
-- POI ids (Config/Pois.luau defines them) shared by every map: cheese_cache,
-- shrine_swift, shrine_might, shrine_mending, elite_camp, crumb_fountain,
-- mousetrap_field, armory (v2 Armory Crate). Each map also has one
-- map-unique landmark (weight 2 of ~108)
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
			{ "cheese_cache", 26 },
			{ "shrine_swift", 9 },
			{ "shrine_might", 9 },
			{ "shrine_mending", 9 },
			{ "elite_camp", 13 },
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
		poiTable = pois("pepper_idol", { mousetrap_field = 16, cheese_cache = 22 }),
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
		poiTable = pois("molten_fondue", { mousetrap_field = 18, elite_camp = 16, cheese_cache = 20 }),
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
		poiTable = pois("witch_hut", { crumb_fountain = 18, shrine_mending = 12, cheese_cache = 21 }),
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
		poiTable = pois("crashed_rocket", { shrine_swift = 13, mousetrap_field = 8 }),
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
		poiTable = pois("sunken_chest", { elite_camp = 16, cheese_cache = 23 }),
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
