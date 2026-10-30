--!strict
-- Shared type contracts. Every team codes against these; change them only via
-- docs/ARCHITECTURE.md and tell the other owners.

export type Rgb = { number }
export type Rarity = "Common" | "Rare" | "Epic" | "Legendary"
export type Tier = "Low" | "Mid" | "High"

-- Final, aggregated stats for one player (computed by Run/Stats.luau).
export type PlayerStats = {
	maxHp: number,
	moveSpeed: number, -- studs/s (applied to Humanoid.WalkSpeed on the server)
	armor: number, -- flat damage reduction per hit (min 1 damage taken)
	regen: number, -- hp/s
	damageMult: number, -- multiplies all outgoing damage
	attackSpeedMult: number, -- >1 means faster weapon cooldowns
	cooldownMult: number, -- ability cooldown multiplier (<1 is better)
	areaMult: number,
	projectileBonus: number, -- extra projectiles added to weapon count
	pierceBonus: number,
	critChance: number, -- 0..1
	critMult: number, -- e.g. 1.5
	pickupRadius: number, -- studs
	xpMult: number,
	cheeseMult: number,
	luck: number, -- 0 = baseline; shifts upgrade rarity weights
	chain: number, -- extra chain targets on hit
	explodeOnKill: number, -- 0 = off, else explosion radius in studs
	lifesteal: number, -- 0..1 fraction of damage dealt healed
	extraOrbiters: number,
}

-- World / enemy-side modifiers produced by curses and difficulty.
export type WorldMods = {
	enemyHpMult: number,
	enemyDamageMult: number,
	enemySpeedMult: number,
	enemyProjectileSpeedMult: number,
	spawnRateMult: number,
	eliteChance: number, -- 0..1
	bossDamageMult: number,
	bossHpMult: number,
	oneHitKO: boolean, -- players die to any hit (shields still block)
	fallingRocks: boolean, -- periodic telegraphed AoE on random spots
	healingMult: number,
}

export type WeaponKind = "melee_arc" | "bolt" | "spread" | "cone" | "orbit" | "lob" | "puddle"

export type WeaponDef = {
	kind: WeaponKind,
	damage: number,
	cooldown: number, -- seconds between auto-fires at attackSpeedMult 1
	range: number, -- targeting range / arc radius / lob distance
	count: number, -- projectiles or orbiters
	speed: number, -- projectile speed studs/s (0 for instant)
	pierce: number,
	area: number, -- radius (studs) for arcs/AoE/puddles, spread angle (deg) for spread/cone
	knockback: number,
	duration: number?, -- puddle / orbit lifetime
}

export type AbilityKind = "dash" | "burst" | "ring" | "shield" | "puddle" | "hover" | "field"

export type AbilityDef = {
	kind: AbilityKind,
	name: string,
	description: string,
	cooldown: number,
	damage: number,
	area: number,
	distance: number?,
	duration: number?,
}

export type ClassDef = {
	id: string,
	name: string,
	role: string,
	description: string,
	color: Rgb?, -- {r, g, b} 0..255 (plain table so configs load in Lune)
	unlockCost: number, -- 0 = free
	baseStats: { [string]: number }, -- overrides on top of Stats.DEFAULT
	weapon: WeaponDef,
	ability: AbilityDef,
	passiveText: string,
}

export type StatDelta = {
	add: { [string]: number }?, -- additive to PlayerStats fields
	mul: { [string]: number }?, -- multiplicative to PlayerStats fields
	weapon: { [string]: number }?, -- additive deltas on WeaponDef numeric fields
	heal: number?, -- instant heal as fraction of max hp
}

export type UpgradeDef = {
	id: string,
	name: string,
	description: string,
	rarity: Rarity,
	maxStacks: number,
	classOnly: string?, -- limit to one class id
	delta: StatDelta,
}

export type ModifierDef = {
	id: string,
	name: string,
	description: string,
	tier: Tier,
	kind: "curse" | "blessing",
	-- curses: fields of WorldMods to set/multiply; blessings: StatDelta for every player
	world: { [string]: number | boolean }?,
	delta: StatDelta?,
}

export type MapDef = {
	id: string,
	name: string,
	cheese: string,
	groundColor: Rgb?, -- {r, g, b} 0..255 (plain table so configs load in Lune)
	accentColor: Rgb?, -- {r, g, b} 0..255 (plain table so configs load in Lune)
	size: number, -- arena radius in studs
	obstacleCount: number,
	poiSlots: number,
	poiTable: { { id: string, weight: number } },
	enemyPool: { string }, -- enemy ids that spawn here
}

export type BossDef = {
	id: string,
	name: string,
	title: string,
	hp: number,
	speed: number,
	radius: number,
	contactDamage: number,
	patterns: { string }, -- ids from Combat/BossPatterns
	phase2Patterns: { string }?,
	color: Rgb?, -- {r, g, b} 0..255 (plain table so configs load in Lune)
}

export type EnemyDef = {
	id: string,
	name: string,
	hp: number,
	speed: number,
	radius: number,
	contactDamage: number,
	xp: number,
	behavior: "chase" | "ranged" | "fuse" | "tank",
	rangedRange: number?,
	rangedCooldown: number?,
	projectileSpeed: number?,
	projectileDamage: number?,
	fuseRadius: number?,
	fuseDamage: number?,
}

-- Route card offered at the start of a stage.
export type RouteCard = {
	tier: Tier,
	mapId: string,
	bossId: string,
	curseId: string?,
	blessingId: string?,
	rewardMult: number,
	cleanse: boolean,
	epicChance: number,
}

export type RunPhase =
	"Lobby"
	| "RouteVote"
	| "Waves"
	| "Boss"
	| "StageClear"
	| "BankVote" -- continue / double-or-nothing
	| "CycleVote" -- go home / next cycle
	| "Results"

-- Public, replicated view of the run (sent to clients on change).
export type PublicRunState = {
	phase: RunPhase,
	cycle: number, -- 1-based
	stageInCycle: number, -- 1..4
	mapId: string?,
	bossId: string?,
	pendingCheese: number,
	bankedCheese: number,
	doubleOrNothing: boolean,
	activeCurses: { string },
	activeBlessings: { string },
	phaseEndsAt: number?, -- workspace:GetServerTimeNow() based
	outcome: ("Win" | "Wipe")?,
}

-- Combat world snapshot entry (encoded by Combat/SnapshotCodec).
export type EnemySnap = {
	id: number, -- 1..65535
	kind: number, -- index into Enemies.ORDER (bosses use 200 + index into Bosses.ORDER)
	x: number,
	z: number,
	hpFrac: number, -- 0..1
	flags: number, -- bit0 elite, bit1 telegraphing, bit2 stunned
}

-- Visual event emitted by the combat world each step (sent reliably in batches).
export type FxEvent = {
	t: string, -- "proj" | "hit" | "die" | "tele" | "slam" | "heal" | "down" | "revive" | "pickup" | "boom"
	[string]: any,
}

-- Persistent player profile (Data/ProfileSchema owns defaults + migrations).
export type Profile = {
	version: number,
	cheese: number,
	xp: number,
	level: number,
	unlockedClasses: { [string]: boolean },
	selectedClass: string,
	talents: { [string]: number },
	cosmetics: { [string]: boolean },
	equipped: { trail: string?, hat: string?, tint: string? },
	secondWindTokens: number,
	rerollTokens: number,
	daily: { lastClaimDay: number, streak: number },
	stats: { runs: number, wins: number, deepestCycle: number, bossesKilled: number, fastestCycle1: number? },
	purchaseHistory: { [string]: boolean }, -- receipt PurchaseId -> processed
	boosts: { cheese2xUntil: number },
	settings: { [string]: any },
}

return {}
