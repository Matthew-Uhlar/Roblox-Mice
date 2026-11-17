--!strict
-- Boss definitions. Owned by Team B (Combat & Horde).
-- Every pattern id must exist in Combat/BossPatterns.DEFS (checked by CombatConfig.spec).
-- The first entry of `patterns` is always used as the opener; afterwards the boss
-- picks at random (never the same pattern twice in a row). At 50% HP the boss
-- switches to `phase2Patterns`.
-- Snapshot kind for a boss = 200 + index into Bosses.ORDER (append only).
-- hp is the cycle-1 baseline; WorldMods.bossHpMult/bossDamageMult scale it (by
-- cycle, run stage and party size). Tuned with tests/sim (2026-11): fights at
-- stage 1 ~40-60 s, a levelled stage-4 party ~45-90 s. Slow bosses with summons
-- (Giant Tree, Grandma, Spider Machine) sit lower.

local Types = require("../Types")

type BossDef = Types.BossDef

local Bosses = {}

Bosses.ORDER = {
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
} :: { string }

Bosses.KIND_OFFSET = 200

-- v4 (docs/V4-PLAN.md "Tuning", V4-A M8): boss HP also follows the fight that is
-- really happening. World.spawnBoss multiplies hp by Bosses.hpScale:
--   heroes  = HERO_HP_BASE + HERO_HP_PER_SQUAD x standing heroes / HERO_SQUAD
--   level   = clamp((average hero level / LEVEL_HP_REF) ^ LEVEL_HP_EXP, LEVEL_HP_MIN, LEVEL_HP_MAX)
--             (LEVEL_HP_EXP 0 = off: STAGE_HP carries the curve)
--   stage   = STAGE_HP[stage] (past the end: the last). WorldMods.bossHpMult already
--             grows ~6x from stage 1 to 4 (Run/Stats) while heroes outgrow it early
--             and fall behind late; this flattens it (tests/sim/v4-report, M1).
--   final   = FINAL_HP_MULT on the last stage, which also gets a third phase at
--             PHASE3_FRAC hp (phase-2 patterns, gaps x PHASE3_GAP_MULT, speed x PHASE3_SPEED_MULT).
-- Targets: 40-60 s fights on stages 1-3, 60-90 s on the final boss.
Bosses.HERO_HP_BASE = 1
Bosses.HERO_HP_PER_SQUAD = 0
Bosses.HERO_SQUAD = 3
Bosses.LEVEL_HP_REF = 8
Bosses.LEVEL_HP_EXP = 0
Bosses.LEVEL_HP_MIN = 0.6
Bosses.LEVEL_HP_MAX = 2
Bosses.STAGE_HP = { 1.3, 1.9, 2.7, 12 }
Bosses.FINAL_HP_MULT = 2.5
Bosses.PHASE3_FRAC = 0.25
Bosses.PHASE3_GAP_MULT = 0.7
Bosses.PHASE3_SPEED_MULT = 1.15

-- The v4 HP multiplier for `heroes` standing heroes of average level `avgLevel`
-- (nil: no level data, factor 1); `final` = the last stage's boss.
function Bosses.hpScale(heroes: number, avgLevel: number?, final: boolean?, stage: number?): number
	local n = if type(heroes) == "number" and heroes == heroes then math.max(1, heroes) else Bosses.HERO_SQUAD
	local hf = Bosses.HERO_HP_BASE + Bosses.HERO_HP_PER_SQUAD * n / Bosses.HERO_SQUAD
	local lf = 1
	if Bosses.LEVEL_HP_EXP ~= 0 and type(avgLevel) == "number" and avgLevel == avgLevel then
		lf = math.clamp(
			(math.max(1, avgLevel) / Bosses.LEVEL_HP_REF) ^ Bosses.LEVEL_HP_EXP,
			Bosses.LEVEL_HP_MIN,
			Bosses.LEVEL_HP_MAX
		)
	end
	local sf = 1
	if type(stage) == "number" and stage == stage and #Bosses.STAGE_HP > 0 then
		sf = Bosses.STAGE_HP[math.clamp(math.floor(stage), 1, #Bosses.STAGE_HP)]
	end
	return hf * lf * sf * (if final then Bosses.FINAL_HP_MULT else 1)
end

Bosses.byId = {
	giant_tree = {
		id = "giant_tree",
		name = "Giant Tree",
		title = "Elder of the Gouda Grove",
		hp = 5100,
		speed = 3.5,
		radius = 7,
		contactDamage = 20,
		patterns = { "root_slam", "acorn_burst", "branch_sweep", "sapling_summon" },
		phase2Patterns = { "root_eruption", "acorn_spiral", "branch_sweep_wide", "sapling_summon" },
		color = { 110, 78, 46 },
	},
	froggus = {
		id = "froggus",
		name = "Froggus",
		title = "The Big-Bellied Brawler",
		hp = 5400,
		speed = 6,
		radius = 5.5,
		contactDamage = 18,
		patterns = { "belly_flop", "tongue_lash", "bubble_volley", "tadpole_summon" },
		phase2Patterns = { "belly_flop_triple", "tongue_lash_triple", "lily_burst", "bubble_volley" },
		color = { 88, 168, 72 },
	},
	serpent_sisters = {
		id = "serpent_sisters",
		name = "Serpent Sisters",
		title = "Three Coils, One Grudge",
		hp = 4500,
		speed = 7.5,
		radius = 4,
		contactDamage = 16,
		-- sister_summon raises the two sister bodies (boss minions, flag bit3).
		patterns = { "sister_summon", "venom_volley", "coil_charge", "fang_burst" },
		phase2Patterns = { "sister_summon", "venom_spiral", "coil_charge_double", "fang_burst" },
		color = { 64, 140, 120 },
	},
	my_grandma = {
		id = "my_grandma",
		name = "My Grandma",
		title = "She Has Opinions",
		hp = 4500,
		speed = 5,
		radius = 4.5,
		contactDamage = 15,
		patterns = { "cookie_volley", "yarn_spiral", "slipper_slam", "soup_spill" },
		phase2Patterns = { "cookie_storm", "yarn_spiral_double", "rolling_pin_sweep", "soup_spill" },
		color = { 196, 150, 200 },
	},
	floating_witch = {
		id = "floating_witch",
		name = "Floating Witch",
		title = "Spinner of the Gamba Wheel",
		hp = 4800,
		speed = 6.5,
		radius = 4,
		contactDamage = 14,
		patterns = { "witch_roulette", "hex_bolts", "witch_blink" },
		phase2Patterns = { "witch_roulette_fast", "hex_bolts", "witch_blink", "witch_roulette_fast" },
		color = { 120, 70, 170 },
	},
	corndog_bunny = {
		id = "corndog_bunny",
		name = "Corndog Bunny",
		title = "Fair-Food Fury",
		hp = 4900,
		speed = 8,
		radius = 4.5,
		contactDamage = 16,
		patterns = { "bunny_hop", "mustard_spray", "ketchup_spiral", "kernel_burst" },
		phase2Patterns = { "bunny_hop_frenzy", "mustard_sweep", "relish_rain", "ketchup_spiral" },
		color = { 214, 150, 70 },
	},
	spider_machine = {
		id = "spider_machine",
		name = "Spider Machine",
		title = "Adaptive Assault Unit",
		hp = 5000,
		speed = 7,
		radius = 5.5,
		contactDamage = 18,
		-- spider_adaptive reads the distance to the nearest player and picks stomp / webs / laser.
		patterns = { "spider_adaptive", "web_volley", "leg_stomp", "spiderling_summon" },
		phase2Patterns = {
			"spider_adaptive_overdrive",
			"laser_sweep",
			"spiderling_summon",
			"spider_adaptive_overdrive",
		},
		color = { 120, 124, 136 },
	},
	green_gorilla = {
		id = "green_gorilla",
		name = "Green Gorilla",
		title = "Banana Republic Tyrant",
		hp = 6000,
		speed = 6.5,
		radius = 6,
		contactDamage = 22,
		patterns = { "chest_pound", "barrel_roll", "boulder_toss", "banana_burst" },
		phase2Patterns = { "rage_charge", "chest_pound_shockwave", "boulder_toss_big", "banana_burst" },
		color = { 60, 150, 70 },
	},
	paper_dinosaur = {
		id = "paper_dinosaur",
		name = "Paper Dinosaur",
		title = "The Origami Rex",
		hp = 5200,
		speed = 7,
		radius = 5.5,
		contactDamage = 18,
		patterns = { "paper_stomp", "origami_spiral", "papercut_sweep", "crane_volley" },
		phase2Patterns = { "fold_charge", "origami_spiral_dense", "confetti_burst", "papercut_sweep" },
		color = { 236, 232, 220 },
	},
	hematite_snake = {
		id = "hematite_snake",
		name = "Dark Hematite Snake",
		title = "The Iron Coil",
		hp = 5900,
		speed = 7.5,
		radius = 4.5,
		contactDamage = 20,
		patterns = { "iron_charge", "shard_spiral", "magnet_slam", "ore_burst" },
		phase2Patterns = { "iron_charge_chain", "shard_spiral_double", "rust_pools", "magnet_slam" },
		color = { 70, 60, 66 },
	},
	ice_dragon = {
		id = "ice_dragon",
		name = "Ancient Ice Dragon",
		title = "Frost of the Blue Peaks",
		hp = 6600,
		speed = 6,
		radius = 6.5,
		contactDamage = 22,
		patterns = { "frost_breath", "icicle_rain", "wing_gust", "glacier_charge" },
		phase2Patterns = { "frost_breath_sweep", "blizzard_spiral", "icicle_storm", "glacier_charge" },
		color = { 150, 210, 240 },
	},
	void_cat = {
		id = "void_cat",
		name = "Void Cat",
		title = "Knocked the Moon off the Table",
		hp = 5500,
		speed = 8,
		radius = 4.5,
		contactDamage = 18,
		patterns = { "void_blink", "void_spiral", "laser_eyes", "yarn_portal_summon" },
		phase2Patterns = {
			"void_blink_triple",
			"void_spiral_dense",
			"laser_eyes_cross",
			"yarn_portal_summon",
		},
		color = { 40, 24, 64 },
	},
	zoomzola = {
		id = "zoomzola",
		name = "Zoomzola the Swift Cheese",
		title = "Blink and You Smell It",
		hp = 4500,
		speed = 12,
		radius = 3.5,
		contactDamage = 16,
		patterns = { "zoom_dash", "stink_burst", "wheel_volley", "gorgonzola_puddles" },
		phase2Patterns = { "zoom_frenzy", "stink_spiral", "stink_burst", "wheel_volley" },
		color = { 90, 120, 170 },
	},
} :: { [string]: BossDef }

local INDEX: { [string]: number } = {}
for i, id in Bosses.ORDER do
	INDEX[id] = i
end
Bosses.INDEX = INDEX

function Bosses.get(id: string): BossDef?
	return Bosses.byId[id]
end

function Bosses.indexOf(id: string): number?
	return INDEX[id]
end

-- Snapshot kind number for a boss id (200 + index).
function Bosses.kindOf(id: string): number?
	local i = INDEX[id]
	return if i then Bosses.KIND_OFFSET + i else nil
end

return Bosses
