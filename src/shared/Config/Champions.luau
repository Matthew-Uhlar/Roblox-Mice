--!strict
-- Mouse Champions (GDD-v2 §4b): frequent, high-impact squad objectives on the
-- big maps. Pure data; Combat/Champions.luau runs the director, the AI and the
-- rewards, Combat/World.luau owns the bodies, Combat/BossPatterns.luau holds
-- their attacks (every damaging attack is telegraphed >= 0.6 s).
--
-- Ids are a contract with the graphics team (models) and the UI (names/icons):
-- never rename them. Snapshot kind = KIND_OFFSET (100) + index into ORDER
-- (append only). Mice are 1..n, champions 100+, bosses 200+.
--
-- Director (per stage, only while the waves run): the first champion appears
-- FIRST s into the waves, then one every INTERVAL s, at a free Champion Site
-- (Pois.layout "champion_site" entries, on a middle ring between the squads),
-- with at most MAX_ALIVE alive (MAX_ALIVE_SMALL on arenas under LARGE_ARENA).
-- Each Champion Lair ("champion_lair", 1-2 per map near the centre) wakes ONE
-- tougher lair champion per stage at LAIR_AT[i] s (LAIR_* multipliers, a
-- better drop). No new champion in the last CUTOFF s of the waves; the ones
-- alive when the boss arrives leave (Fx champ phase "dead", escaped = true).
--
-- Reward (to the squad that lands the killing blow; with no hero killer, the
-- squad with the most damage): every member gets one gear item of at least
-- GEAR.min (GEAR.late from GEAR.lateStage; lairs use LAIR_GEAR), XP_BY_STAGE xp
-- (x xpMult), CHEESE_BY_STAGE pending cheese each (Pressure applied by the
-- server), and the champion's timed squad buff (stacks up to BUFF_STACKS).

local Types = require("../Types")

type Rgb = Types.Rgb

export type ChampionBuff = {
	kind: string, -- stack base kind (Combat/Champions.addSquadBuff appends #1 / #2)
	name: string,
	stat: string, -- PlayerStats field
	mul: number,
	duration: number, -- seconds
}

export type ChampionDef = {
	id: string,
	name: string,
	title: string,
	hp: number, -- baseline; x WorldMods.bossHpMult (stage + squad size) x HP_SCALE
	speed: number,
	radius: number,
	contactDamage: number, -- x WorldMods.bossDamageMult
	damageMult: number?, -- extra multiplier on its pattern damage
	patterns: { string }, -- Combat/BossPatterns ids; the first one opens the fight
	phase2Patterns: { string }, -- after the enrage (ENRAGE_FRAC hp)
	color: Rgb,
	buff: ChampionBuff,
	keepDistance: number?, -- ranged: holds this distance to its target
	evadeRange: number?, -- teleports away (pattern "sniper_evade") when a hero gets this close
	splitAt: number?, -- splits into CLONES clones at this hp fraction (the enrage)
	description: string,
}

local Champions = {}

Champions.KIND_OFFSET = 100

Champions.ORDER = {
	"champ_captain",
	"champ_golem",
	"champ_ratking",
	"champ_sniper",
	"champ_chemist",
	"champ_thunder",
} :: { string }

-- Director ---------------------------------------------------------------------------
-- Every director time below is for the REFERENCE_WAVE (150 s) waves; shorter
-- waves scale them down (Combat/Champions.timeScale), never up.
Champions.REFERENCE_WAVE = 150
Champions.FIRST = { 35, 45 } -- s into the waves before the first champion (v4: was 25-35)
Champions.INTERVAL = { 30, 40 } -- s between champions
Champions.MAX_ALIVE = 3 -- regular champions alive at once on a big map...
Champions.MAX_ALIVE_SMALL = 2 -- ...and on an arena with radius < LARGE_ARENA
Champions.LARGE_ARENA = 250
Champions.CUTOFF = 25 -- no new champion in the last CUTOFF s of the waves
Champions.LAIR_AT = { 70, 112 } -- s into the waves: lair i wakes its champion (+-JITTER; v4: was 55 / 95)
Champions.LAIR_JITTER = 8
Champions.LAIR_HP_MULT = 1.8
Champions.LAIR_DAMAGE_MULT = 1.2
Champions.LAIR_RADIUS_MULT = 1.25
Champions.LAIR_SPEED_MULT = 1.05

-- Body / AI ----------------------------------------------------------------------------
-- HP = def.hp x WorldMods.bossHpMult (stage + squad-sized party) x HP_SCALE
--      x (1 + HP_WAVE_GROWTH x waves elapsed / waves duration): heroes level up
-- fast inside a stage, so a late champion is tougher (sim: a squad needs about
-- 20-35 s at any point of any stage; Config tuned 2026-11 with tests/sim).
Champions.HP_SCALE = 2.1 -- v4.1: run-shop ranks + run bonuses made fights 11 s; ~20 s median (IntegrationSquads 12-45 s)
Champions.HP_WAVE_GROWTH = 1.6 -- v4: was 2.5 (hero level now carries most of the growth)
-- v4 (V4-A M7, target a 20-30 s fight): HP also x clamp(1 + LEVEL_HP_SLOPE x
-- (average hero level - LEVEL_HP_REF), LEVEL_HP_MIN, LEVEL_HP_MAX) (World.avgHeroLevel).
Champions.LEVEL_HP_SLOPE = 0.04
Champions.LEVEL_HP_REF = 8
Champions.LEVEL_HP_MIN = 0.8
Champions.LEVEL_HP_MAX = 2.0
Champions.MAX_ALIVE_STAGE1 = 2 -- v4: regular champions alive at once in stage 1
Champions.INTRO = 1.5 -- s invulnerable after spawning (telegraphed landing)
Champions.AGGRO = 38 -- studs: it attacks heroes this close to its body...
Champions.LEASH = 36 -- ...that are also within LEASH + AGGRO of its site; else it walks home
Champions.REGEN_DELAY = 6 -- s without a target before it heals...
Champions.REGEN_RATE = 0.05 -- ...this fraction of max HP per second
Champions.GAP = 1.4 -- s between patterns (x ENRAGE_GAP once enraged)
Champions.ENRAGE_FRAC = 0.5
Champions.ENRAGE_SPEED = 1.2
Champions.ENRAGE_GAP = 0.7
Champions.SHIELD_MULT = 0.35 -- damage taken while a shield charge runs
Champions.EVADE_COOLDOWN = 7
Champions.CLONES = 2 -- Mad Chemist split
Champions.CLONE_HP_FRAC = 0.2 -- of the chemist's max HP, each
Champions.CLONE_RADIUS_MULT = 0.65
Champions.KNOCK_RESIST = 0.15
Champions.RALLY_SPEED = 1.35 -- Captain Whiskers' rally: nearby mice move faster...
Champions.RALLY_DAMAGE = 1.3 -- ...and hit harder
-- Iteration 6 (team Flow, balance): roaming. A regular champion with nobody to fight for
-- ROAM_AFTER s walks its leash home toward the nearest standing hero within ROAM_SEEK
-- (ROAM_SPEED studs/s, stopping ROAM_STOP short), so squads meet it during the waves
-- (sim: 5.3 spawned but 0.3 killed per stage before; most were never touched).
Champions.ROAM_AFTER = 6
Champions.ROAM_SPEED = 5
Champions.ROAM_SEEK = 220
Champions.ROAM_STOP = 20

-- Rewards ------------------------------------------------------------------------------
Champions.XP_BY_STAGE = { 90, 180, 300, 450 } -- per member (x xpMult); past the end: the last
Champions.CHEESE_BY_STAGE = { 25, 35, 50, 65 } -- pending cheese per member (x Pressure)
Champions.LAIR_REWARD_MULT = 1.5 -- lair: xp and cheese
Champions.LAIR_BUFF_MULT = 1.5 -- lair: buff duration
Champions.GEAR = table.freeze({ min = "Rare", late = "Epic", lateStage = 3 })
Champions.LAIR_GEAR = table.freeze({ min = "Epic", late = "Legendary", lateStage = 3 })
Champions.BUFF_STACKS = 2

local MIGHT: ChampionBuff = {
	kind = "champ_might",
	name = "Champion's Might",
	stat = "damageMult",
	mul = 1.25,
	duration = 90,
}
local SWIFT: ChampionBuff = {
	kind = "champ_swift",
	name = "Champion's Stride",
	stat = "moveSpeed",
	mul = 1.2,
	duration = 90,
}

local defs: { [string]: ChampionDef } = {
	champ_captain = {
		id = "champ_captain",
		name = "Captain Whiskers",
		title = "Shield of the Horde",
		description = "Charges behind his shield and rallies nearby mice: faster and fiercer.",
		hp = 1000,
		speed = 7.5,
		radius = 3,
		contactDamage = 14,
		patterns = { "captain_shield_charge", "captain_rally", "captain_bash" },
		phase2Patterns = { "captain_shield_charge_double", "captain_rally", "captain_bash" },
		color = { 70, 110, 200 },
		buff = MIGHT,
	},
	champ_golem = {
		id = "champ_golem",
		name = "Cheese Golem",
		title = "The Walking Wheel",
		description = "Slow and tanky: telegraphed ground slams and quakes.",
		hp = 1250, -- v4: was 1500 (slowest fight, V4-A M7)
		speed = 4.5,
		radius = 4,
		contactDamage = 18,
		patterns = { "golem_slam", "golem_stomp", "golem_quake" },
		phase2Patterns = { "golem_slam_ring", "golem_stomp", "golem_quake" },
		color = { 240, 200, 70 },
		buff = MIGHT,
	},
	champ_ratking = {
		id = "champ_ratking",
		name = "Rat King",
		title = "Crown of a Thousand Tails",
		description = "Summons waves of rats and hurls his crown.",
		hp = 950,
		speed = 6.5,
		radius = 3,
		contactDamage = 12,
		patterns = { "ratking_summon", "ratking_crown_burst", "ratking_scepter" },
		phase2Patterns = { "ratking_summon_big", "ratking_crown_burst_double", "ratking_scepter" },
		color = { 150, 90, 160 },
		buff = MIGHT,
	},
	champ_sniper = {
		id = "champ_sniper",
		name = "Sniper Squeak",
		title = "Never Misses Twice",
		description = "Long-range telegraphed shots; teleports away when you get close.",
		hp = 750,
		speed = 7,
		radius = 2.4,
		contactDamage = 8,
		patterns = { "sniper_shot", "sniper_volley", "sniper_shot" },
		phase2Patterns = { "sniper_shot_double", "sniper_volley", "sniper_shot" },
		color = { 90, 140, 80 },
		buff = MIGHT,
		keepDistance = 26,
		evadeRange = 11,
	},
	champ_chemist = {
		id = "champ_chemist",
		name = "Mad Chemist",
		title = "Brewer of Bad Ideas",
		description = "Lobs poison puddles and splits into two clones at half health.",
		hp = 950,
		speed = 6,
		radius = 2.8,
		contactDamage = 10,
		patterns = { "chemist_lob", "chemist_flask_burst", "chemist_lob" },
		phase2Patterns = { "chemist_lob_wide", "chemist_flask_burst", "chemist_lob" },
		color = { 120, 220, 90 },
		buff = MIGHT,
		splitAt = 0.5,
	},
	champ_thunder = {
		id = "champ_thunder",
		name = "Thunder Hamster",
		title = "Static in a Fluffy Coat",
		description = "Fast: lightning dashes and chain lightning between heroes.",
		hp = 850,
		speed = 11,
		radius = 2.6,
		contactDamage = 12,
		patterns = { "thunder_dash", "thunder_chain", "thunder_burst" },
		phase2Patterns = { "thunder_dash_triple", "thunder_chain", "thunder_burst" },
		color = { 255, 230, 80 },
		buff = SWIFT,
	},
}
Champions.defs = defs

local INDEX: { [string]: number } = {}
for i, id in Champions.ORDER do
	INDEX[id] = i
end
Champions.INDEX = INDEX

function Champions.get(id: string): ChampionDef?
	return defs[id]
end

function Champions.indexOf(id: string): number?
	return INDEX[id]
end

-- Snapshot kind (100 + index), or nil for an unknown id.
function Champions.kindOf(id: string): number?
	local i = INDEX[id]
	return if i then Champions.KIND_OFFSET + i else nil
end

-- The champion id for a snapshot kind (100 + index), or nil.
function Champions.idOfKind(kind: number): string?
	if type(kind) ~= "number" then
		return nil
	end
	return Champions.ORDER[kind - Champions.KIND_OFFSET]
end

local function byStage(list: { number }, stage: number): number
	local s = math.clamp(math.floor(if stage == stage then stage else 1), 1, #list)
	return list[s]
end

-- XP per member for a kill on this stage (before xpMult).
function Champions.xpReward(stage: number, lair: boolean?): number
	return math.floor(
		byStage(Champions.XP_BY_STAGE, stage) * (if lair then Champions.LAIR_REWARD_MULT else 1)
	)
end

-- Pending cheese per member for a kill on this stage (before Pressure).
function Champions.cheeseReward(stage: number, lair: boolean?): number
	return math.floor(
		byStage(Champions.CHEESE_BY_STAGE, stage) * (if lair then Champions.LAIR_REWARD_MULT else 1)
	)
end

-- Minimum gear rarity of the per-member drop.
function Champions.gearRarity(stage: number, lair: boolean?): string
	local g = if lair then Champions.LAIR_GEAR else Champions.GEAR
	return if stage >= g.lateStage then g.late else g.min
end

-- Regular champions alive at once on an arena of this radius.
function Champions.maxAlive(arenaRadius: number, stage: number?): number
	local n = if arenaRadius >= Champions.LARGE_ARENA then Champions.MAX_ALIVE else Champions.MAX_ALIVE_SMALL
	if type(stage) == "number" and stage <= 1 then
		n = math.min(n, Champions.MAX_ALIVE_STAGE1)
	end
	return n
end

-- v4: the champion HP factor for an average hero level.
function Champions.levelHpMult(avgLevel: number?): number
	local lv = if type(avgLevel) == "number" and avgLevel == avgLevel
		then avgLevel
		else Champions.LEVEL_HP_REF
	return math.clamp(
		1 + Champions.LEVEL_HP_SLOPE * (lv - Champions.LEVEL_HP_REF),
		Champions.LEVEL_HP_MIN,
		Champions.LEVEL_HP_MAX
	)
end

-- Iteration 4 roaming minibosses (Liberty corner-style camps; Config/Maps minibossCamps,
-- POI kind miniboss_camp). A camp's miniboss is a champion body under its own name:
-- MINIBOSS.hpMult of the champion's HP, patrols a PATROL_R circle round the camp,
-- respawns RESPAWN s after it falls (only while the waves run). The top-damage squad's
-- members each get rinds (x the stage scale and their rind mult), whey and XP.
Champions.MINIBOSS = table.freeze({
	firstAt = 20, -- s into the waves
	respawn = 90,
	hpMult = 0.6,
	patrolR = 24,
	patrolSpeed = 5, -- studs/s along the circle
	rinds = 60,
	whey = 25,
	xp = 60,
})
Champions.MINIBOSSES = table.freeze({
	table.freeze({ name = "Sergeant Squeakers", champId = "champ_captain" }),
	table.freeze({ name = "Brickjaw", champId = "champ_golem" }),
	table.freeze({ name = "The Rat Baron", champId = "champ_ratking" }),
	table.freeze({ name = "Longshot Lou", champId = "champ_sniper" }),
	table.freeze({ name = "Doc Fizzle", champId = "champ_chemist" }),
	table.freeze({ name = "Static Stan", champId = "champ_thunder" }),
})

return Champions
