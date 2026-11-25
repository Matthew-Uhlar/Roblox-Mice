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
Bosses.STAGE_HP = { 0.6, 1.0, 1.4, 1.2 } -- iteration 4: BOSS_SECONDS 120 + x1.35 maps (was 1.3 / 2.8 / 4.5 / 6)
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
		lore = "It has been growing cheese-scented acorns for 600 years and wants its grove back.",
		tip = "Watch for the root slam ring: step out of the glowing circle before the roots burst up.",
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
		lore = "Ate a whole wheel of brie in one gulp and has been grumpy about the burps ever since.",
		tip = "Watch for the belly flop: its shadow grows where it lands, so move before it drops.",
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
		lore = "Three sisters, one fang between them, and they still argue about whose turn it is.",
		tip = "Watch for the coil charge: the line telegraph shows where a sister will slither.",
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
		lore = "She knitted the mice tiny sweaters and now expects them to win.",
		tip = "Watch for the slipper slam: it lands on the marked spot, and the soup spill puddles stay hot.",
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
		lore = "Spins her Gamba Wheel for fun and never pays out the jackpot.",
		tip = "Watch for the roulette: the wheel shows which spell is coming, so read it and dodge.",
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
		lore = "Escaped from the county fair with a sugar rush and a grudge against ketchup.",
		tip = "Watch for the bunny hop: every landing leaves a ring, so keep moving sideways.",
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
		lore = "A clockwork spider that learns your tricks and copies them back.",
		tip = "Watch for the adaptive mode: it switches to counter whoever hits it hardest.",
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
		lore = "Crowned himself king of the banana stand and taxes every peel.",
		tip = "Watch for the chest pound: the shockwave follows it, so jump the ring as it passes.",
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
		lore = "Folded from a thousand homework pages, and still roaring about the bad grades.",
		tip = "Watch for the papercut sweep: the cone telegraph shows its reach, so stay behind it.",
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
		lore = "Made of iron ore and very proud of being magnetic.",
		tip = "Watch for the magnet slam: it pulls you in first, so walk away before the slam.",
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
		lore = "Sneezed once and froze a whole cheese cellar solid.",
		tip = "Watch for the glacier charge: it leaves an ice trail, and the frost breath cone is wide.",
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
		lore = "Knocked the moon off the table to see what would happen.",
		tip = "Watch for the void blink: it vanishes and reappears behind you, then the laser eyes fire.",
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
		lore = "The fastest, smelliest cheese in the land, and it never stops for a shower.",
		tip = "Watch for the zoom dash line, and stay out of the green gorgonzola puddles.",
		hp = 4500,
		speed = 12,
		radius = 3.5,
		contactDamage = 16,
		patterns = { "zoom_dash", "stink_burst", "wheel_volley", "gorgonzola_puddles" },
		phase2Patterns = { "zoom_frenzy", "stink_spiral", "stink_burst", "wheel_volley" },
		color = { 90, 120, 170 },
	},
} :: { [string]: BossDef }

-- Iteration 8 (team Gameplay): boss variety. Each boss gets one new attack (Combat/
-- BossPatterns, from the existing bases) in both phases, and a rare EPIC variant:
-- rolled per stage from the route card's tier (EPIC.chance), it has x hpMult HP,
-- x damageMult damage and its own look (snapshot flag / Fx `epic = true`). Only when it
-- is KILLED (not fled): a bigger chest (x chestMult cheese) on any route, and on a High
-- route the guaranteed epic drop (QC M1: never farmable on Low / Mid routes).
Bosses.NEW_PATTERNS = table.freeze({
	giant_tree = "tree_leaf_storm",
	froggus = "froggus_lily_leap",
	serpent_sisters = "sisters_twin_cone",
	my_grandma = "grandma_knit_sweep",
	floating_witch = "witch_cauldron_rain",
	corndog_bunny = "bunny_carrot_volley",
	spider_machine = "spider_web_field",
	green_gorilla = "gorilla_ground_pound",
	paper_dinosaur = "dino_paper_charge",
	hematite_snake = "snake_ore_rain",
	ice_dragon = "dragon_frost_ring",
	void_cat = "cat_shadow_sweep",
	zoomzola = "zoomzola_cheese_wheel",
})
for id, pat in Bosses.NEW_PATTERNS do
	local def = Bosses.byId[id]
	if def then
		table.insert(def.patterns, pat)
		if def.phase2Patterns then
			table.insert(def.phase2Patterns, pat)
		end
	end
end

Bosses.EPIC = table.freeze({
	chance = table.freeze({ Low = 0.03, Mid = 0.06, High = 0.12 }),
	hpMult = 1.5,
	damageMult = 1.2,
	chestMult = 1.5,
	color = table.freeze({ 200, 90, 255 }), -- the epic tint (client)
})

-- The Epic chance for a route card tier ("Low" | "Mid" | "High"; anything else: Low).
function Bosses.epicChance(tier: any): number
	return Bosses.EPIC.chance[tier] or Bosses.EPIC.chance.Low
end

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

-- Iteration 1 (C-29): distinct pose data per boss for the renderer (team G). Pure
-- numbers, all optional for the client:
--   stance: idle silhouette, one of "upright" | "crouch" | "coil" | "hover" | "hunch" | "rear"
--   lean: forward lean in degrees (negative = leans back); crouch: 0..1 body drop
--   bob: idle bob amplitude (studs) and bobHz its rate; sway: side sway in degrees
--   windup: the telegraph pose ("raise" | "rear" | "coil" | "spread" | "crouch" | "spin")
--   strike: the hit pose ("slam" | "lunge" | "lash" | "cast" | "pounce" | "stomp")
--   phase2: the enraged pose change ("hunch" | "flare" | "rear" | "glow" | "split")
export type BossPose = {
	stance: string,
	lean: number,
	crouch: number,
	bob: number,
	bobHz: number,
	sway: number,
	windup: string,
	strike: string,
	phase2: string,
}

Bosses.POSES = table.freeze({
	giant_tree = {
		stance = "upright",
		lean = -4,
		crouch = 0,
		bob = 0.2,
		bobHz = 0.3,
		sway = 6,
		windup = "raise",
		strike = "slam",
		phase2 = "flare",
	},
	froggus = {
		stance = "crouch",
		lean = 10,
		crouch = 0.45,
		bob = 0.6,
		bobHz = 0.9,
		sway = 2,
		windup = "crouch",
		strike = "pounce",
		phase2 = "flare",
	},
	serpent_sisters = {
		stance = "coil",
		lean = 0,
		crouch = 0.2,
		bob = 0.3,
		bobHz = 0.7,
		sway = 14,
		windup = "coil",
		strike = "lunge",
		phase2 = "split",
	},
	my_grandma = {
		stance = "hunch",
		lean = 18,
		crouch = 0.15,
		bob = 0.15,
		bobHz = 0.5,
		sway = 4,
		windup = "raise",
		strike = "slam",
		phase2 = "glow",
	},
	floating_witch = {
		stance = "hover",
		lean = 6,
		crouch = 0,
		bob = 1.2,
		bobHz = 0.4,
		sway = 8,
		windup = "spread",
		strike = "cast",
		phase2 = "glow",
	},
	corndog_bunny = {
		stance = "crouch",
		lean = 12,
		crouch = 0.35,
		bob = 0.8,
		bobHz = 1.4,
		sway = 3,
		windup = "crouch",
		strike = "pounce",
		phase2 = "rear",
	},
	spider_machine = {
		stance = "crouch",
		lean = 0,
		crouch = 0.5,
		bob = 0.25,
		bobHz = 1.1,
		sway = 2,
		windup = "rear",
		strike = "stomp",
		phase2 = "glow",
	},
	green_gorilla = {
		stance = "hunch",
		lean = 22,
		crouch = 0.25,
		bob = 0.35,
		bobHz = 0.6,
		sway = 5,
		windup = "raise",
		strike = "slam",
		phase2 = "rear",
	},
	paper_dinosaur = {
		stance = "upright",
		lean = 14,
		crouch = 0.1,
		bob = 0.3,
		bobHz = 0.5,
		sway = 7,
		windup = "rear",
		strike = "lunge",
		phase2 = "flare",
	},
	hematite_snake = {
		stance = "coil",
		lean = 4,
		crouch = 0.3,
		bob = 0.2,
		bobHz = 0.6,
		sway = 16,
		windup = "coil",
		strike = "lash",
		phase2 = "glow",
	},
	ice_dragon = {
		stance = "rear",
		lean = -8,
		crouch = 0,
		bob = 0.9,
		bobHz = 0.35,
		sway = 6,
		windup = "spread",
		strike = "lunge",
		phase2 = "flare",
	},
	void_cat = {
		stance = "crouch",
		lean = 8,
		crouch = 0.4,
		bob = 0.2,
		bobHz = 0.8,
		sway = 10,
		windup = "crouch",
		strike = "pounce",
		phase2 = "split",
	},
	zoomzola = {
		stance = "upright",
		lean = 20,
		crouch = 0.1,
		bob = 0.5,
		bobHz = 1.8,
		sway = 9,
		windup = "spin",
		strike = "lunge",
		phase2 = "glow",
	},
} :: { [string]: BossPose })

-- The pose of a boss (a neutral one for an unknown id).
function Bosses.pose(id: string): BossPose
	return Bosses.POSES[id]
		or {
			stance = "upright",
			lean = 0,
			crouch = 0,
			bob = 0.3,
			bobHz = 0.5,
			sway = 4,
			windup = "raise",
			strike = "slam",
			phase2 = "flare",
		}
end

return Bosses
