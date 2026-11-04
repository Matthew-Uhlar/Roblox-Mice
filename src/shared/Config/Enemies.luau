--!strict
-- Enemy (mouse) definitions. Owned by Team B (Combat & Horde).
-- Speeds are studs/s (player base walk speed is ~16, so only Rat Runners keep up).
-- Snapshot kind = index into Enemies.ORDER (never reorder; append only).

local Types = require("../Types")

type EnemyDef = Types.EnemyDef

local Enemies = {}

Enemies.ORDER = { "mouse", "rat_runner", "chonk", "crumb_slinger", "fuse_mouse", "carrier" } :: { string }

-- Mice the wave director may spawn. The golden carrier is World-spawned only
-- (World.CARRIER_*): it never comes from a map's enemy pool.
Enemies.WAVE_IDS = { "mouse", "rat_runner", "chonk", "crumb_slinger", "fuse_mouse" } :: { string }

Enemies.byId = {
	mouse = {
		id = "mouse",
		name = "Mouse",
		hp = 10,
		speed = 9,
		radius = 1.2,
		contactDamage = 6,
		xp = 1,
		behavior = "chase",
	},
	rat_runner = {
		id = "rat_runner",
		name = "Rat Runner",
		hp = 6,
		speed = 14.5,
		radius = 1.1,
		contactDamage = 5,
		xp = 1,
		behavior = "chase",
	},
	chonk = {
		id = "chonk",
		name = "Chonk",
		hp = 70,
		speed = 5.5,
		radius = 2.4,
		contactDamage = 14,
		xp = 5,
		behavior = "tank",
	},
	crumb_slinger = {
		id = "crumb_slinger",
		name = "Crumb Slinger",
		hp = 14,
		speed = 7.5,
		radius = 1.3,
		contactDamage = 4,
		xp = 2,
		behavior = "ranged",
		rangedRange = 34,
		rangedCooldown = 2.6,
		projectileSpeed = 26,
		projectileDamage = 7,
	},
	fuse_mouse = {
		id = "fuse_mouse",
		name = "Fuse Mouse",
		hp = 9,
		speed = 11,
		radius = 1.3,
		contactDamage = 3,
		xp = 2,
		behavior = "fuse",
		fuseRadius = 8,
		fuseDamage = 22,
	},
	-- v2 (GDD-v2 §3): a rare golden mouse that runs away from heroes and drops a
	-- run-only gear item when killed. It escapes after `lifetime` seconds.
	carrier = {
		id = "carrier",
		name = "Golden Carrier",
		hp = 60,
		speed = 12.5,
		radius = 1.4,
		contactDamage = 0,
		xp = 6,
		behavior = "chase",
		flee = true,
		carrier = true,
		lifetime = 30,
	},
} :: { [string]: EnemyDef }

-- Elite variants (GDD §7): tinted, 3x HP, more crumbs, a bit bigger and meaner.
Enemies.ELITE = {
	hpMult = 3,
	xpMult = 3,
	damageMult = 1.4,
	radiusMult = 1.3,
	speedMult = 1.05,
}

-- Fuse mice light their fuse when a player is this close (studs, edge to edge).
Enemies.FUSE_TRIGGER = 3.5
Enemies.FUSE_TIME = 1.0 -- GDD §7: explodes after a 1 s telegraph

local INDEX: { [string]: number } = {}
for i, id in Enemies.ORDER do
	INDEX[id] = i
end
Enemies.INDEX = INDEX

function Enemies.get(id: string): EnemyDef?
	return Enemies.byId[id]
end

function Enemies.indexOf(id: string): number?
	return INDEX[id]
end

return Enemies
