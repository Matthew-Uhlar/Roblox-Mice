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
--   * (R3, GDD-v2 §5) Optional 6th param `classState = {perks, ability, level?}`
--     (Types.ClassState, or Data/ClassProgress.classState(profile, classId)):
--     the class's taken perks (Config/ClassPerks) are applied like talents (their
--     `delta` adds/muls/weapon deltas plus `abilityMul`), and the third result is
--     the chosen Config/ClassAbilities ability, or the base one when none is chosen
--     or it isn't unlocked at `level`. Perks of another class, perks out of tier
--     order and perks over the level's points are ignored (Data/ClassProgress
--     .sanitizePerks). `level` defaults to ClassProgress.MAX_LEVEL (server data is
--     trusted). Without the 6th param the result is exactly the v1 result.
--     (v6) classState.stars (Mastery Stars) adds the 30th perk point at level 30.
--   * (v5) Optional 7th param `runBonus` = Data/RunBonus.resolve(...) (the Herd Talent
--     Board, the class's Evolution and the squad charm aura; DataService.runBonuses):
--     `delta` is applied like a talent (adds, then muls) and `pve` is added to
--     pveDamageMult. Its damage never reaches damageMult (PvE-only).
--   * (v4 plan, QC-C M12) Talents are PvE-only for damage: a talent's `damageMult`
--     delta (add or mul) does NOT change stats.damageMult. It builds
--     stats.pveDamageMult = (1 + talent adds) * talent muls instead, which
--     Combat/World applies only to damage against mice, champions and bosses, never
--     against heroes. Perks, upgrades, blessings and gear still use damageMult.

local Types = require("../Types")
local Classes = require("../Config/Classes")
local Upgrades = require("../Config/Upgrades")
local Modifiers = require("../Config/Modifiers")
local ClassPerks = require("../Config/ClassPerks")
local ClassProgress = require("../Data/ClassProgress")

type PlayerStats = Types.PlayerStats
type WeaponDef = Types.WeaponDef
type AbilityDef = Types.AbilityDef
type StatDelta = Types.StatDelta
type WorldMods = Types.WorldMods

export type TalentDefs = { [string]: { perLevel: StatDelta } }
export type ClassState =
	{ perks: { [string]: boolean }?, ability: string?, level: number?, prestige: number? }

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
	pveDamageMult = 1, -- (v4) talents' damage, PvE only (Combat/World)
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
	pveDamageMult = { 0.1, 10 },
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
	bossHpPerStage = 1.2,
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
	talentDefs: TalentDefs?,
	classState: ClassState?,
	runBonus: { delta: StatDelta?, pve: number? }?
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

	if type(classState) == "table" then
		local level = if type(classState.level) == "number" then classState.level else ClassProgress.MAX_LEVEL
		local chosen = ClassProgress.abilityFor(
			class.id,
			{ xp = 0, level = level, perks = {}, ability = classState.ability }
		)
		if chosen then
			ability = chosen
		end
		-- (iteration 2) Prestige adds perk points (old saves' classState.stars read the same)
		local cs: any = classState
		local prestige = if type(cs.prestige) == "number"
			then cs.prestige
			elseif type(cs.stars) == "number" then cs.stars
			else nil
		local perks = ClassProgress.sanitizePerks(class.id, level, classState.perks, prestige)
		for _, def in ClassPerks.forClass(class.id) do
			if perks[def.id] then
				table.insert(entries, { delta = def.delta, times = 1, abilityMul = def.abilityMul })
			end
		end
	end

	-- Talents: their damageMult parts go to pveDamageMult (QC-C M12), the rest as usual.
	local pveAdd, pveMul = 0, 1
	if talents and talentDefs then
		for _, id in sortedKeys(talents) do
			local def = talentDefs[id]
			local level = math.floor(talents[id] or 0)
			if def and def.perLevel and level > 0 then
				local d = def.perLevel
				local rest: StatDelta = { weapon = d.weapon }
				if d.add then
					local add = {}
					for k, v in d.add do
						if k == "damageMult" then
							pveAdd += v * level
						else
							add[k] = v
						end
					end
					rest.add = add
				end
				if d.mul then
					local mul = {}
					for k, v in d.mul do
						if k == "damageMult" then
							pveMul *= v ^ level
						else
							mul[k] = v
						end
					end
					rest.mul = mul
				end
				table.insert(entries, { delta = rest, times = level })
			end
		end
	end
	-- (v5) long-term run bonus: stats as a talent-like entry, damage PvE-only
	if type(runBonus) == "table" then
		local d = runBonus.delta
		if type(d) == "table" then
			local add, mul = {}, {}
			for k, v in d.add or {} do
				if k == "damageMult" then
					pveAdd += v
				else
					add[k] = v
				end
			end
			for k, v in d.mul or {} do
				if k == "damageMult" then
					pveMul *= v
				else
					mul[k] = v
				end
			end
			table.insert(entries, { delta = { add = add, mul = mul }, times = 1 })
		end
		if type(runBonus.pve) == "number" and runBonus.pve == runBonus.pve then
			pveAdd += runBonus.pve
		end
	end
	s.pveDamageMult = (1 + pveAdd) * pveMul

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
		-- Pressure fields (Config/Pressure, GDD §3.7); Combat/World reads them.
		eliteSpeedMult = 1,
		eliteSizeMult = 1,
		lateSpawnMult = 1,
		rangedExtraProjectiles = 0,
		enemyXpMult = 1,
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
