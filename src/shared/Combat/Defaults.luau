--!strict
-- Combat-side defaults. World uses these to fill any field a caller leaves out
-- (e.g. WorldMods from an older Stats.worldMods), and tests use them as fixtures.
-- Run/Stats.luau (Team A) is the source of truth for real player stats.

local Types = require("../Types")

type PlayerStats = Types.PlayerStats
type WorldMods = Types.WorldMods
type WeaponDef = Types.WeaponDef
type AbilityDef = Types.AbilityDef

local Defaults = {}

Defaults.STATS = {
	maxHp = 100,
	moveSpeed = 16,
	armor = 0,
	regen = 0,
	damageMult = 1,
	attackSpeedMult = 1,
	cooldownMult = 1,
	areaMult = 1,
	projectileBonus = 0,
	pierceBonus = 0,
	critChance = 0.05,
	critMult = 1.5,
	pickupRadius = 8,
	xpMult = 1,
	cheeseMult = 1,
	luck = 0,
	chain = 0,
	explodeOnKill = 0,
	lifesteal = 0,
	extraOrbiters = 0,
} :: PlayerStats

Defaults.MODS = {
	enemyHpMult = 1,
	enemyDamageMult = 1,
	enemySpeedMult = 1,
	enemyProjectileSpeedMult = 1,
	spawnRateMult = 1,
	eliteChance = 0,
	bossDamageMult = 1,
	bossHpMult = 1,
	oneHitKO = false,
	fallingRocks = false,
	healingMult = 1,
	-- Pressure (GDD §3.7, Team G1); optional in Types.WorldMods
	eliteSpeedMult = 1,
	eliteSizeMult = 1,
	lateSpawnMult = 1,
	rangedExtraProjectiles = 0,
} :: WorldMods

-- Sample weapons per kind (mirrors the GDD classes; Team A's Classes.luau is canonical).
Defaults.WEAPONS = {
	melee_arc = {
		kind = "melee_arc",
		damage = 14,
		cooldown = 0.9,
		range = 9,
		count = 1,
		speed = 0,
		pierce = 0,
		area = 8,
		knockback = 3,
	},
	bolt = {
		kind = "bolt",
		damage = 11,
		cooldown = 0.8,
		range = 40,
		count = 1,
		speed = 60,
		pierce = 1,
		area = 0.8,
		knockback = 0.5,
	},
	spread = {
		kind = "spread",
		damage = 8,
		cooldown = 0.9,
		range = 34,
		count = 3,
		speed = 50,
		pierce = 0,
		area = 30,
		knockback = 0.5,
	},
	cone = {
		kind = "cone",
		damage = 9,
		cooldown = 0.45,
		range = 10,
		count = 1,
		speed = 0,
		pierce = 0,
		area = 40,
		knockback = 1,
	},
	orbit = {
		kind = "orbit",
		damage = 12,
		cooldown = 0.5,
		range = 7,
		count = 2,
		speed = 22,
		pierce = 0,
		area = 1.8,
		knockback = 1.5,
	},
	lob = {
		kind = "lob",
		damage = 16,
		cooldown = 1.3,
		range = 30,
		count = 1,
		speed = 30,
		pierce = 0,
		area = 5,
		knockback = 1,
	},
	puddle = {
		kind = "puddle",
		damage = 5,
		cooldown = 1.6,
		range = 24,
		count = 1,
		speed = 0,
		pierce = 0,
		area = 5,
		knockback = 0,
		duration = 3,
	},
} :: { [string]: WeaponDef }

Defaults.ABILITIES = {
	dash = {
		kind = "dash",
		name = "Stampede",
		description = "",
		cooldown = 6,
		damage = 25,
		area = 4,
		distance = 18,
	},
	burst = {
		kind = "burst",
		name = "Geyser",
		description = "",
		cooldown = 7,
		damage = 40,
		area = 8,
		distance = 30,
	},
	ring = {
		kind = "ring",
		name = "Thorn Ring",
		description = "",
		cooldown = 8,
		damage = 20,
		area = 10,
		duration = 3,
	},
	shield = {
		kind = "shield",
		name = "Riposte",
		description = "",
		cooldown = 9,
		damage = 35,
		area = 9,
		duration = 1.2,
	},
	puddle = {
		kind = "puddle",
		name = "Sizzle",
		description = "",
		cooldown = 8,
		damage = 8,
		area = 7,
		distance = 24,
		duration = 4,
	},
	hover = {
		kind = "hover",
		name = "Updraft",
		description = "",
		cooldown = 10,
		damage = 10,
		area = 8,
		duration = 2,
	},
	field = {
		kind = "field",
		name = "Soda Geyser",
		description = "",
		cooldown = 12,
		damage = 4,
		area = 12,
		distance = 28,
		duration = 5,
	},
} :: { [string]: AbilityDef }

-- Returns a full PlayerStats: `partial` fields over Defaults.STATS (never mutates either).
function Defaults.stats(partial: { [string]: any }?): PlayerStats
	local s = table.clone(Defaults.STATS) :: any
	if partial then
		for k, v in partial do
			s[k] = v
		end
	end
	return s :: PlayerStats
end

function Defaults.mods(partial: { [string]: any }?): WorldMods
	local m = table.clone(Defaults.MODS) :: any
	if partial then
		for k, v in partial do
			m[k] = v
		end
	end
	return m :: WorldMods
end

-- Fills missing fields of a stats/mods table from defaults (returns a new table).
function Defaults.fillStats(s: any): PlayerStats
	local out = table.clone(Defaults.STATS) :: any
	if type(s) == "table" then
		for k, v in s do
			out[k] = v
		end
	end
	return out :: PlayerStats
end

function Defaults.fillMods(m: any): WorldMods
	local out = table.clone(Defaults.MODS) :: any
	if type(m) == "table" then
		for k, v in m do
			out[k] = v
		end
	end
	return out :: WorldMods
end

function Defaults.weapon(kind: string): WeaponDef
	return table.clone(Defaults.WEAPONS[kind]) :: WeaponDef
end

function Defaults.ability(kind: string): AbilityDef
	return table.clone(Defaults.ABILITIES[kind]) :: AbilityDef
end

return Defaults
