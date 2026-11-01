--!strict
-- Player stat aggregation and world (enemy-side) difficulty. Pure, no Roblox.
--
-- Interpretation notes (Team A, see docs/ARCHITECTURE.md "Team A"):
--   * Stats.compute order: class baseStats are ABSOLUTE overrides on DEFAULT;
--     then every `add` and `weapon` delta (talents, upgrades, blessings) is
--     summed, then every `mul` is applied, then `abilityMul`. So the result is
--     (base + adds) * muls, independent of pick order. Stats are clamped last.
--   * compute does NOT fold PlayerStats multipliers into the returned WeaponDef
--     / AbilityDef. The combat world applies damageMult, attackSpeedMult,
--     cooldownMult, areaMult, projectileBonus and pierceBonus at fire time.
--     Only flat `weapon` deltas and `abilityMul` change the defs themselves.
--   * `delta.heal` is an on-pick effect; RunDirector applies it. compute and
--     applyDelta ignore it.
--   * Unknown upgrade / blessing / talent ids are skipped. Upgrade stacks are
--     clamped to the upgrade's maxStacks, and class-only upgrades for another
--     class are skipped. An unknown classId falls back to Classes.DEFAULT_ID.
--   * Optional 5th param `talentDefs` = {[talentId] = {perLevel: StatDelta}}
--     (Team D's Config/Talents), so this module does not require their file.
--   * worldMods: curse `world` booleans are set, "*Mult" numbers multiply and
--     other numbers (eliteChance) add, clamped to 0..1.

local Types = require("../Types")
local Classes = require("../Config/Classes")
local Upgrades = require("../Config/Upgrades")
local Modifiers = require("../Config/Modifiers")

type PlayerStats = Types.PlayerStats
type WeaponDef = Types.WeaponDef
type AbilityDef = Types.AbilityDef
type StatDelta = Types.StatDelta
type WorldMods = Types.WorldMods

export type TalentDefs = { [string]: { perLevel: StatDelta } }

local Stats = {}

Stats.DEFAULT = table.freeze({
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
}) :: PlayerStats

-- {min, max} per PlayerStats field. Keeps stacked builds sane for the server.
local LIMITS: { [string]: { number } } = {
	maxHp = { 1, 100000 },
	moveSpeed = { 4, 60 },
	armor = { 0, 1000 },
	regen = { 0, 1000 },
	damageMult = { 0.1, 1000 },
	attackSpeedMult = { 0.1, 6 },
	cooldownMult = { 0.1, 5 },
	areaMult = { 0.1, 8 },
	projectileBonus = { 0, 12 },
	pierceBonus = { 0, 99 },
	critChance = { 0, 1 },
	critMult = { 1, 20 },
	pickupRadius = { 1, 200 },
	xpMult = { 0, 20 },
	cheeseMult = { 0, 20 },
	luck = { -10, 50 },
	chain = { 0, 16 },
	explodeOnKill = { 0, 40 },
	lifesteal = { 0, 1 },
	extraOrbiters = { 0, 8 },
}
Stats.LIMITS = table.freeze(LIMITS)

local WEAPON_LIMITS: { [string]: { number } } = {
	damage = { 0, 1e6 },
	cooldown = { 0.05, 30 },
	range = { 1, 300 },
	count = { 1, 24 },
	speed = { 0, 500 },
	pierce = { 0, 99 },
	area = { 0, 360 },
	knockback = { 0, 100 },
	duration = { 0, 60 },
}
Stats.WEAPON_LIMITS = table.freeze(WEAPON_LIMITS)

Stats.ABILITY_MIN_COOLDOWN = 0.5

-- Difficulty scaling per cycle (+1 difficulty level each cycle, GDD §3.2),
-- a gentler ramp inside a cycle, and party-size scaling.
Stats.DIFFICULTY = table.freeze({
	hpPerCycle = 0.6, -- enemy and boss HP +60% per cycle after the first
	damagePerCycle = 0.3,
	speedPerCycle = 0.05,
	speedCap = 1.3,
	spawnPerCycle = 0.25,
	hpPerStage = 0.12, -- within a cycle, per stage after the first
	damagePerStage = 0.08,
	spawnPerStage = 0.1,
	hpPerExtraPlayer = 0.35,
	spawnPerExtraPlayer = 0.4,
	bossHpPerExtraPlayer = 0.6,
	-- Bosses also scale with the RUN's global stage (the party's levels carry
	-- over between stages and cycles), capped so deep cycles lean on hpPerCycle.
	bossHpPerStage = 0.7,
	bossDamagePerStage = 0.1,
	bossStageCap = 8, -- global stages counted for the two lines above
	eliteStart = 0.03, -- elites from global stage 2 (GDD §3.3)
	elitePerStage = 0.02,
	eliteCap = 0.35,
	stagesPerCycle = 4,
	maxPlayers = 4,
})

local function clamp(x: number, lo: number, hi: number): number
	if x ~= x then
		return lo
	end
	return math.max(lo, math.min(hi, x))
end

local function clampStats(stats: PlayerStats)
	local s = stats :: any
	for k, lim in Stats.LIMITS do
		if type(s[k]) == "number" then
			s[k] = clamp(s[k], lim[1], lim[2])
		end
	end
end

local function clampWeapon(weapon: WeaponDef)
	local w = weapon :: any
	for k, lim in Stats.WEAPON_LIMITS do
		if type(w[k]) == "number" then
			w[k] = clamp(w[k], lim[1], lim[2])
		end
	end
	w.count = math.floor(w.count + 0.5)
end

local function addPart(stats: PlayerStats, weapon: WeaponDef, delta: StatDelta, times: number)
	local s = stats :: any
	local w = weapon :: any
	if delta.add then
		for k, v in delta.add do
			if type(s[k]) == "number" then
				s[k] += v * times
			end
		end
	end
	if delta.weapon then
		for k, v in delta.weapon do
			if type(w[k]) == "number" then
				w[k] += v * times
			elseif k == "duration" and w[k] == nil then
				w[k] = v * times
			end
		end
	end
end

local function mulPart(stats: PlayerStats, delta: StatDelta, times: number)
	local s = stats :: any
	if delta.mul then
		for k, v in delta.mul do
			if type(s[k]) == "number" then
				s[k] *= v ^ times
			end
		end
	end
end

local function abilityPart(ability: AbilityDef, mul: { [string]: number }?, times: number)
	if not mul then
		return
	end
	local a = ability :: any
	for k, v in mul do
		if type(a[k]) == "number" then
			a[k] *= v ^ times
		end
	end
	a.cooldown = math.max(Stats.ABILITY_MIN_COOLDOWN, a.cooldown)
end

-- Applies `delta` `times` times, in place: adds first, then multipliers.
-- Results are clamped to Stats.LIMITS / Stats.WEAPON_LIMITS.
function Stats.applyDelta(stats: PlayerStats, weapon: WeaponDef, delta: StatDelta, times: number)
	if times ~= times or times <= 0 then
		return
	end
	addPart(stats, weapon, delta, times)
	mulPart(stats, delta, times)
	clampStats(stats)
	clampWeapon(weapon)
end

-- Multiplies AbilityDef numeric fields in place (extension used by
-- `abilityMul` on upgrades and blessings).
function Stats.applyAbilityMul(ability: AbilityDef, mul: { [string]: number }, times: number)
	abilityPart(ability, mul, times)
end

local function sortedKeys(t: { [string]: number }): { string }
	local keys = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

type Entry = { delta: StatDelta, times: number, abilityMul: { [string]: number }? }

function Stats.compute(
	classId: string,
	upgradeStacks: { [string]: number },
	blessingIds: { string },
	talents: { [string]: number }?,
	talentDefs: TalentDefs?
): (PlayerStats, WeaponDef, AbilityDef)
	local class = Classes.get(classId) or Classes.get(Classes.DEFAULT_ID)
	assert(class, "Stats.compute: no default class")

	local stats = table.clone(Stats.DEFAULT) :: PlayerStats
	local s = stats :: any
	for k, v in class.baseStats do
		if type(s[k]) == "number" then
			s[k] = v
		end
	end
	local weapon = table.clone(class.weapon)
	local ability = table.clone(class.ability)

	local entries: { Entry } = {}

	if talents and talentDefs then
		for _, id in sortedKeys(talents) do
			local def = talentDefs[id]
			local level = math.floor(talents[id] or 0)
			if def and def.perLevel and level > 0 then
				table.insert(entries, { delta = def.perLevel, times = level })
			end
		end
	end

	for _, id in sortedKeys(upgradeStacks) do
		local def = Upgrades.get(id)
		if def and (def.classOnly == nil or def.classOnly == class.id) then
			local n = math.min(math.floor(upgradeStacks[id] or 0), def.maxStacks)
			if n > 0 then
				table.insert(entries, { delta = def.delta, times = n, abilityMul = def.abilityMul })
			end
		end
	end

	for _, id in blessingIds do
		local def = Modifiers.get(id)
		if def and def.kind == "blessing" then
			table.insert(entries, { delta = def.delta or {}, times = 1, abilityMul = def.abilityMul })
		end
	end

	for _, e in entries do
		addPart(stats, weapon, e.delta, e.times)
	end
	for _, e in entries do
		mulPart(stats, e.delta, e.times)
	end
	for _, e in entries do
		abilityPart(ability, e.abilityMul, e.times)
	end

	clampStats(stats)
	clampWeapon(weapon)
	return stats, weapon, ability
end

function Stats.defaultWorldMods(): WorldMods
	return {
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
	}
end

-- Applies one curse's `world` table onto mods in place.
function Stats.applyCurse(mods: WorldMods, world: { [string]: number | boolean })
	local m = mods :: any
	for k, v in world do
		local cur = m[k]
		if type(v) == "boolean" then
			if type(cur) == "boolean" then
				m[k] = cur or v
			end
		elseif type(v) == "number" and type(cur) == "number" then
			if string.sub(k, -4) == "Mult" then
				m[k] = cur * v
			else
				m[k] = cur + v
			end
		end
	end
	mods.eliteChance = clamp(mods.eliteChance, 0, 1)
end

function Stats.worldMods(
	cycle: number,
	stageInCycle: number,
	curseIds: { string },
	playerCount: number
): WorldMods
	local D = Stats.DIFFICULTY
	local c = math.max(1, math.floor(if cycle == cycle then cycle else 1))
	local st = math.max(1, math.floor(if stageInCycle == stageInCycle then stageInCycle else 1))
	-- Fractional party size (a bot counts 0.6): solo + 2 bots = 2.2, not 3.
	local pc = clamp(playerCount, 1, D.maxPlayers)
	local d = c - 1
	local inCycle = st - 1
	local extra = pc - 1
	local globalStage = d * D.stagesPerCycle + st

	local hpCycle = (1 + D.hpPerCycle * d) * (1 + D.hpPerStage * inCycle)
	local dmgCycle = (1 + D.damagePerCycle * d) * (1 + D.damagePerStage * inCycle)
	local speed = math.min(D.speedCap, 1 + D.speedPerCycle * d)

	local mods = Stats.defaultWorldMods()
	mods.enemyHpMult = hpCycle * (1 + D.hpPerExtraPlayer * extra)
	mods.enemyDamageMult = dmgCycle
	mods.enemySpeedMult = speed
	mods.enemyProjectileSpeedMult = speed
	mods.spawnRateMult = (1 + D.spawnPerCycle * d)
		* (1 + D.spawnPerStage * inCycle)
		* (1 + D.spawnPerExtraPlayer * extra)
	mods.eliteChance = if globalStage >= 2
		then math.min(D.eliteCap, D.eliteStart + D.elitePerStage * (globalStage - 2))
		else 0
	local bossStage = math.min(globalStage, D.bossStageCap) - 1
	mods.bossHpMult = hpCycle * (1 + D.bossHpPerExtraPlayer * extra) * (1 + D.bossHpPerStage * bossStage)
	mods.bossDamageMult = dmgCycle * (1 + D.bossDamagePerStage * bossStage)

	for _, id in curseIds do
		local def = Modifiers.get(id)
		if def and def.kind == "curse" and def.world then
			Stats.applyCurse(mods, def.world)
		end
	end
	return mods
end

return Stats
