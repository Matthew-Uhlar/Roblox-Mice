--!strict
-- Points of interest (GDD §3.8). Pure data: Combat/Pois.luau runs the logic,
-- Combat/World.luau owns the live entities, RunDirector pays the meta rewards.
--
-- Every map has 8-12 hand-placed POI slots (Config/Maps poiSlots). Each stage
-- fills them from the map's weighted poiTable (Maps.rollPois), then rolls the
-- two global rare POIs ONCE per stage (RARES below): Grandma's Pantry 3%,
-- Lost Herd Statue 2% (mutually exclusive). A rare replaces one random slot,
-- so a party sees one about every 20 stages: a few runs, as the brainstorm asked.
-- Each map's poiTable also holds one map-unique landmark (weight 2 of ~94 per
-- slot): a big cheese cache that is also recorded as a discovery.
--
-- Modes:
--   channel  stand inside `radius` for `channel` seconds (several heroes fill it
--            faster); used once, then "done".
--   camp     the first hero inside `radius` wakes an elite pack; killing every
--            elite opens the chest (reward once).
--   hazard   always armed during Waves: traps snap anything that steps on them,
--            mice AND heroes, after a telegraph. Never "done".
--   totem    (v2) capture-and-hold: one squad alone in the zone captures it over
--            `channel` s; the owner's squad deals TOTEM_DAMAGE_MULT damage until
--            another squad neutralises and recaptures it. Never "done".
--   cart     (v2) Shop Cart: a hero who stands in it for CART_OPEN s sees 3 gear
--            offers priced in pending cheese (RunDirector sells them). "done"
--            when sold out.
--
-- v2 (GDD-v2 §4): every POI is CONTESTED. Only one squad channels at a time:
-- with two squads inside, progress holds; another squad first drains the
-- channelling squad's progress (STEAL_RATE) before it fills its own. Damage
-- pauses a hero's channel (HURT_PAUSE). Rewards go to the channelling squad
-- (poiReward.ids / .squad). The v2 POIs (Armory Crate, Cheese Vault, Power
-- Totem, Shop Cart) are placed by Combat/Pois.rollStage from SPECIALS (at
-- most one of each per stage) and the Armory Crate also sits in every map's
-- weighted table.

local Types = require("../Types")

type Rgb = Types.Rgb

export type PoiMode = "channel" | "camp" | "hazard" | "totem" | "cart"
export type PoiReward =
	"cheese"
	| "buff"
	| "elite_chest"
	| "crumbs"
	| "epic_pick"
	| "revive"
	| "none"
	| "gear" -- v2 Armory Crate: GEAR_ITEMS gear items to the channeller
	| "vault" -- v2 Cheese Vault: gear items + a big cheese pot
	| "totem" -- v2 Power Totem: squad damage buff while owned
	| "cart" -- v2 Shop Cart: gear offers for pending cheese
export type PoiBuff = {
	stat: string, -- PlayerStats field
	mul: number?, -- multiplies the stat
	addFracMaxHp: number?, -- adds this fraction of max HP (e.g. regen per second)
	duration: number, -- seconds
}
export type PoiDef = {
	id: string,
	name: string,
	description: string,
	rarity: "common" | "uncommon" | "rare" | "landmark",
	mode: PoiMode,
	radius: number, -- studs: channel / trigger / hazard field radius
	channel: number?, -- seconds for one hero to fill the channel
	reward: PoiReward,
	color: Rgb,
	buff: PoiBuff?,
	heal: number?, -- instant heal (fraction of max HP) for every standing hero
	cheeseMult: number?, -- cache payout multiplier (landmarks pay x3)
	rare: boolean?, -- recorded in profile.discoveries for humans
	unlock: { cosmetic: boolean?, title: string? }?, -- first-discovery unlock
	gearItems: number?, -- v2: gear items granted (Armory 1, Vault 2)
	gearMinRarity: string?, -- v2: minimum rarity of those items...
	gearMinStage: number?, -- ...from this stage on (Armory: Rare+ at stage 3+)
	announce: boolean?, -- v2: channel start is announced to every squad (Fx "vault", event poiAlert)
}

local Pois = {}

-- Channel tuning ------------------------------------------------------------------
Pois.MULTI_USER_BONUS = 0.5 -- each extra hero in range adds +50% channel speed...
Pois.MULTI_USER_MAX = 2 -- ...up to x2 total
Pois.DECAY_RATE = 0.25 -- progress lost per second (fraction) while nobody is in range
Pois.HURT_PAUSE = 0.6 -- a hero who took damage this recently does not channel
Pois.PROGRESS_STEP = 0.1 -- poiProgress Fx/events fire when progress crosses a 10% step
Pois.RESYNC = 15 -- seconds between full POI state re-sends (Fx "poi")

-- Rewards --------------------------------------------------------------------------
-- Cheese Cache: pending cheese per player = floor((BASE + PER_STAGE*(stage-1)) * (1 + 0.5*(cycle-1)))
Pois.CACHE_BASE = 20
Pois.CACHE_PER_STAGE = 5
Pois.CACHE_CYCLE_STEP = 0.5
-- Crumb Fountain: total XP = (BASE + PER_STAGE*(stage-1)) * (1 + 0.5*(cycle-1)), split over CRUMBS crumbs
Pois.FOUNTAIN_XP = 30
Pois.FOUNTAIN_XP_PER_STAGE = 10
Pois.FOUNTAIN_CRUMBS = 12
-- Elite Camp: pack = BASE + floor(stage / 2) + (cycle - 1) elites, capped
Pois.CAMP_PACK = 3
Pois.CAMP_PACK_MAX = 8
Pois.CAMP_SPREAD = 7 -- elites appear this far from the camp centre
-- A camp does not wake in the last CAMP_WAKE_CUTOFF s of the waves. A pack still
-- alive when the waves end (the boss start clears the field) flees and leaves its
-- chest, so a woken camp's chest is never silently lost (FINAL-A m3).
Pois.CAMP_WAKE_CUTOFF = 20
-- Mousetrap Field
Pois.TRAPS = 6 -- traps per field
Pois.TRAP_RADIUS = 3 -- snap radius of one trap
Pois.TRAP_TRIGGER = 2.2 -- something this close to a trap's centre arms it
Pois.TRAP_DELAY = 0.8 -- telegraph before the snap (>= BossPatterns.MIN_TELEGRAPH)
Pois.TRAP_REARM = 3 -- seconds before a sprung trap can arm again
Pois.TRAP_ENEMY_DAMAGE = 60 -- x the world's enemyHpMult (mice scale, so traps do too)
Pois.TRAP_PLAYER_DAMAGE = 14 -- x the world's enemyDamageMult
-- Pantry
Pois.EPIC_CARDS = 3

-- v2 contested POIs (GDD-v2 §4) --------------------------------------------------------
Pois.STEAL_RATE = 0.5 -- another squad drains a channel at this fraction of its fill speed
Pois.TOTEM_DAMAGE_MULT = 1.15 -- owning squad's damage
Pois.TOTEM_DECAY = 0.1 -- unowned capture progress lost per second with nobody inside
Pois.CART_OPEN = 1 -- seconds a hero stands in a Shop Cart before it opens for them
-- Cheese Vault pot (pending cheese for the squad): VAULT_MULT x a cache's payout
Pois.VAULT_MULT = 4
-- At most one of each per stage, rolled after the rare (see Combat/Pois.rollStage).
-- Each hit replaces a random slot that holds neither the rare nor another special.
Pois.SPECIALS = table.freeze({
	table.freeze({ id = "power_totem", chance = 0.8 }),
	table.freeze({ id = "cheese_vault", chance = 0.5 }),
	table.freeze({ id = "shop_cart", chance = 0.25 }),
})

-- Global rare POIs: rolled once per stage, mutually exclusive (see header).
Pois.RARES = table.freeze({
	table.freeze({ id = "grandmas_pantry", chance = 0.03 }),
	table.freeze({ id = "lost_herd_statue", chance = 0.02 }),
})

local CHEESE: Rgb = { 255, 204, 51 }

local defs: { [string]: PoiDef } = {
	cheese_cache = {
		id = "cheese_cache",
		name = "Cheese Cache",
		description = "Stand on it for 3 s: bonus pending cheese for the party.",
		rarity = "common",
		mode = "channel",
		radius = 6,
		channel = 3,
		reward = "cheese",
		color = CHEESE,
		cheeseMult = 1,
	},
	shrine_swift = {
		id = "shrine_swift",
		name = "Shrine of Swiftness",
		description = "Touch it: the whole party moves 25% faster for 45 s.",
		rarity = "common",
		mode = "channel",
		radius = 5,
		channel = 1,
		reward = "buff",
		color = { 90, 200, 255 },
		buff = { stat = "moveSpeed", mul = 1.25, duration = 45 },
	},
	shrine_might = {
		id = "shrine_might",
		name = "Shrine of Might",
		description = "Touch it: the whole party deals 25% more damage for 45 s.",
		rarity = "common",
		mode = "channel",
		radius = 5,
		channel = 1,
		reward = "buff",
		color = { 255, 120, 80 },
		buff = { stat = "damageMult", mul = 1.25, duration = 45 },
	},
	shrine_mending = {
		id = "shrine_mending",
		name = "Shrine of Mending",
		description = "Touch it: the whole party heals 30% now, then regenerates for 45 s.",
		rarity = "common",
		mode = "channel",
		radius = 5,
		channel = 1,
		reward = "buff",
		color = { 110, 220, 110 },
		heal = 0.3,
		buff = { stat = "regen", addFracMaxHp = 0.005, duration = 45 },
	},
	elite_camp = {
		id = "elite_camp",
		name = "Elite Camp",
		description = "Wakes an elite pack. Clear it for a chest: a free upgrade pick for everyone.",
		rarity = "uncommon",
		mode = "camp",
		radius = 10,
		reward = "elite_chest",
		color = { 200, 40, 40 },
	},
	crumb_fountain = {
		id = "crumb_fountain",
		name = "Crumb Fountain",
		description = "Stand on it for 2 s: a burst of XP crumbs.",
		rarity = "uncommon",
		mode = "channel",
		radius = 6,
		channel = 2,
		reward = "crumbs",
		color = { 90, 220, 230 },
	},
	mousetrap_field = {
		id = "mousetrap_field",
		name = "Mousetrap Field",
		description = "Traps snap anything that steps on them: mice AND heroes. Lure the horde in!",
		rarity = "uncommon",
		mode = "hazard",
		radius = 12,
		reward = "none",
		color = { 150, 110, 70 },
	},
	grandmas_pantry = {
		id = "grandmas_pantry",
		name = "Grandma's Pantry",
		description = "Rare! Stand in it for 3 s: everyone picks 1 of 3 Epic upgrades.",
		rarity = "rare",
		mode = "channel",
		radius = 6,
		channel = 3,
		reward = "epic_pick",
		color = { 230, 120, 200 },
		rare = true,
		unlock = { cosmetic = true },
	},
	lost_herd_statue = {
		id = "lost_herd_statue",
		name = "Lost Herd Statue",
		description = "Rare! Stand in it for 3 s: every downed hero gets up and Second Wind refills.",
		rarity = "rare",
		mode = "channel",
		radius = 7,
		channel = 3,
		reward = "revive",
		color = { 255, 215, 90 },
		rare = true,
		unlock = { title = "Herd Keeper" },
	},
	-- v2 POIs (GDD-v2 §4) ------------------------------------------------------------
	armory = {
		id = "armory",
		name = "Armory Crate",
		description = "Channel 4 s for a random gear item (Rare or better from stage 3).",
		rarity = "common",
		mode = "channel",
		radius = 5,
		channel = 4,
		reward = "gear",
		color = { 150, 120, 90 },
		gearItems = 1,
		gearMinRarity = "Rare",
		gearMinStage = 3,
	},
	cheese_vault = {
		id = "cheese_vault",
		name = "Cheese Vault",
		description = "Channel 8 s (every squad is told!) for 2 gear items and a big cheese pot.",
		rarity = "uncommon",
		mode = "channel",
		radius = 7,
		channel = 8,
		reward = "vault",
		color = { 255, 190, 40 },
		gearItems = 2,
		gearMinRarity = "Rare",
		gearMinStage = 1,
		announce = true,
	},
	power_totem = {
		id = "power_totem",
		name = "Power Totem",
		description = "Capture and hold it: your squad deals 15% more damage while it is yours.",
		rarity = "uncommon",
		mode = "totem",
		radius = 8,
		channel = 6,
		reward = "totem",
		color = { 220, 60, 200 },
	},
	shop_cart = {
		id = "shop_cart",
		name = "Shop Cart",
		description = "Rare! Spend pending cheese on 1 of 3 gear items.",
		rarity = "rare",
		mode = "cart",
		radius = 5,
		channel = 1,
		reward = "cart",
		color = { 120, 200, 120 },
	},
}

-- Map-unique landmarks (Config/Maps poiTable): a big cheese cache, discovered once.
local LANDMARKS: { [string]: string } = {
	giant_cowbell = "Giant Cowbell",
	gouda_wheel_hut = "Gouda Wheel Hut",
	pepper_idol = "Pepper Idol",
	message_bottle = "Message in a Bottle",
	frozen_mammoth = "Frozen Mammoth",
	molten_fondue = "Molten Fondue",
	witch_hut = "Witch's Hut",
	crashed_rocket = "Crashed Rocket",
	sunken_chest = "Sunken Chest",
}
for id, name in LANDMARKS do
	defs[id] = {
		id = id,
		name = name,
		description = "A landmark of this world: stand on it for 3 s for a big cheese cache.",
		rarity = "landmark",
		mode = "channel",
		radius = 6,
		channel = 3,
		reward = "cheese",
		color = CHEESE,
		cheeseMult = 3,
		rare = true,
	}
end

Pois.defs = defs
Pois.LANDMARKS = table.freeze(LANDMARKS)

Pois.ORDER = {
	"cheese_cache",
	"shrine_swift",
	"shrine_might",
	"shrine_mending",
	"elite_camp",
	"crumb_fountain",
	"mousetrap_field",
	"grandmas_pantry",
	"lost_herd_statue",
	"armory",
	"cheese_vault",
	"power_totem",
	"shop_cart",
}

function Pois.get(id: string): PoiDef?
	return defs[id]
end

-- Cheese per player from a cache of this kind on this stage.
function Pois.cacheCheese(kind: string, cycle: number, stageInCycle: number): number
	local def = defs[kind]
	local mult = if def and def.cheeseMult then def.cheeseMult else 1
	local stage = math.max(1, stageInCycle)
	local base = Pois.CACHE_BASE + Pois.CACHE_PER_STAGE * (stage - 1)
	return math.floor(base * (1 + Pois.CACHE_CYCLE_STEP * (math.max(1, cycle) - 1)) * mult)
end

-- Cheese Vault pot (pending cheese for the channelling squad) on this stage.
function Pois.vaultCheese(cycle: number, stageInCycle: number): number
	return Pois.cacheCheese("cheese_cache", cycle, stageInCycle) * Pois.VAULT_MULT
end

-- Total XP in a Crumb Fountain burst on this stage.
function Pois.fountainXp(cycle: number, stageInCycle: number): number
	local stage = math.max(1, stageInCycle)
	local base = Pois.FOUNTAIN_XP + Pois.FOUNTAIN_XP_PER_STAGE * (stage - 1)
	return math.floor(base * (1 + 0.5 * (math.max(1, cycle) - 1)))
end

-- Elites in an Elite Camp pack on this stage.
function Pois.campPack(cycle: number, stageInCycle: number): number
	local n = Pois.CAMP_PACK + math.floor(math.max(1, stageInCycle) / 2) + (math.max(1, cycle) - 1)
	return math.min(n, Pois.CAMP_PACK_MAX)
end

return Pois
