--!strict
-- Per-class permanent progression (GDD-v2 §5, team R3). Pure: no clock, no Rng.
--
-- profile.classes[classId] = { xp, level, perks = {[perkId] = true}, ability?, skin? }
-- (Types.ClassState). Mastery is derived from level (mastery()).
--
-- Contract functions (docs/ARCHITECTURE-v2.md "Class progression"):
--   xpToNext(level)                          XP to go from `level` to level + 1: floor(100 * level^1.4); 0 at MAX_LEVEL
--   addXp(state, xp) -> (state, levelsGained) in place
--   perkPointsFree(state)                    points earned (level - 1) minus points spent
--   canTake(classId, state, perkId) -> (ok, reason?)
--   respecCost(level)                        cheese
--   unlockedAbilities(classId, level)        ability ids, base first
--   unlockedSkins(classId, level)            EARNED skin ids (paid skins: ownsSkin)
--   mastery(level) -> "none" | "bronze" | "silver" | "gold"
--   runXp(summary)                           summary = {stagesSurvived, bossDamageShare, heroDowns, pois, extracted}
-- Profile-level operations (ShopService remotes call these, so the rules are tested here):
--   selectPerk(profile, classId, perkId)           -> (ok, reason?, perkDef?)
--   resetPerks(profile, classId, payWith?)         -> (ok, reason?, {paid, cost?, refunded})
--   selectAbility(profile, classId, abilityId?)    -> (ok, reason?)
--   selectSkin(profile, classId, skinId?)          -> (ok, reason?)
-- Helpers: defaultState, ensure, sanitize, sanitizeClasses, classState (for Stats),
-- abilityFor, skinFor, autoSpec (bots), view.
--
-- Class XP is never multiplied by Robux (Fast Learner is account XP only): class
-- levels buy perks, and perks are power.

local Types = require("../Types")
local ClassPerks = require("../Config/ClassPerks")
local ClassAbilities = require("../Config/ClassAbilities")
local ClassSkins = require("../Config/ClassSkins")
local Classes = require("../Config/Classes")

type Profile = Types.Profile
type ClassState = Types.ClassState
type AbilityDef = Types.AbilityDef

local ClassProgress = {}

ClassProgress.MAX_LEVEL = 30
ClassProgress.XP_BASE = 100
ClassProgress.XP_EXP = 1.4
ClassProgress.MAX_RUN_XP = 5000 -- sanity cap for one run's class XP
ClassProgress.MAX_STAT = 1_000_000

-- runXp weights (GDD-v2 §5). bossDamageShare is the hero's share of each boss's
-- damage, summed over the run's bosses (0..stages); heroDowns are enemy heroes downed.
ClassProgress.RUN_XP = table.freeze({
	perStage = 60,
	perBossShare = 200, -- x share (a hero who deals 25% of one boss gets 50)
	perHeroDown = 25,
	perPoi = 15,
	extractMult = 1.5,
	maxStages = 8,
	maxBossShare = 8,
	maxHeroDowns = 30,
	maxPois = 30,
})

-- Respec cheese: RESPEC_PER_LEVEL x class level, at least RESPEC_MIN.
ClassProgress.RESPEC_PER_LEVEL = 100
ClassProgress.RESPEC_MIN = 200

local MASTERY_NONE = "none"

local function finite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function clampInt(n: any, lo: number, hi: number, default: number): number
	if not finite(n) then
		return default
	end
	return math.clamp(math.floor(n), lo, hi)
end

local function isClass(classId: any): boolean
	return type(classId) == "string" and Classes.get(classId) ~= nil
end
ClassProgress.isClass = isClass

-- XP ----------------------------------------------------------------------------

function ClassProgress.xpToNext(level: number): number
	local l = clampInt(level, 1, ClassProgress.MAX_LEVEL, 1)
	if l >= ClassProgress.MAX_LEVEL then
		return 0
	end
	return math.floor(ClassProgress.XP_BASE * l ^ ClassProgress.XP_EXP + 0.5)
end

-- Total XP from level 1 to `level`.
function ClassProgress.totalXpFor(level: number): number
	local t = 0
	for l = 1, clampInt(level, 1, ClassProgress.MAX_LEVEL, 1) - 1 do
		t += ClassProgress.xpToNext(l)
	end
	return t
end

function ClassProgress.defaultState(): ClassState
	return { xp = 0, level = 1, perks = {} }
end

-- Adds class XP in place. Returns (state, levelsGained). Overflow at MAX_LEVEL is dropped.
function ClassProgress.addXp(state: ClassState, xp: number): (ClassState, number)
	if not finite(xp) or xp <= 0 then
		return state, 0
	end
	local gained = 0
	state.level = clampInt(state.level, 1, ClassProgress.MAX_LEVEL, 1)
	state.xp = clampInt(state.xp, 0, ClassProgress.MAX_STAT, 0)
		+ math.floor(math.min(xp, ClassProgress.MAX_STAT))
	while state.level < ClassProgress.MAX_LEVEL and state.xp >= ClassProgress.xpToNext(state.level) do
		state.xp -= ClassProgress.xpToNext(state.level)
		state.level += 1
		gained += 1
	end
	if state.level >= ClassProgress.MAX_LEVEL then
		state.xp = 0
	end
	return state, gained
end

export type RunSummary = {
	stagesSurvived: number?,
	bossDamageShare: number?,
	heroDowns: number?,
	pois: number?,
	extracted: boolean?,
}

function ClassProgress.runXp(summary: any): number
	if type(summary) ~= "table" then
		return 0
	end
	local W = ClassProgress.RUN_XP
	local function num(v: any, hi: number): number
		if not finite(v) or v <= 0 then
			return 0
		end
		return math.min(v, hi)
	end
	local xp = W.perStage * math.floor(num(summary.stagesSurvived, W.maxStages))
		+ W.perBossShare * num(summary.bossDamageShare, W.maxBossShare)
		+ W.perHeroDown * math.floor(num(summary.heroDowns, W.maxHeroDowns))
		+ W.perPoi * math.floor(num(summary.pois, W.maxPois))
	if summary.extracted == true then
		xp *= W.extractMult
	end
	return math.clamp(math.floor(xp + 0.5), 0, ClassProgress.MAX_RUN_XP)
end

-- Perks -------------------------------------------------------------------------

function ClassProgress.perkPoints(level: number): number
	return clampInt(level, 1, ClassProgress.MAX_LEVEL, 1) - 1
end

function ClassProgress.perkPointsSpent(state: ClassState): number
	local n = 0
	if type(state.perks) == "table" then
		for id, taken in state.perks do
			local def = ClassPerks.get(id)
			if taken == true and def then
				n += def.cost
			end
		end
	end
	return n
end

function ClassProgress.perkPointsFree(state: ClassState): number
	return math.max(0, ClassProgress.perkPoints(state.level) - ClassProgress.perkPointsSpent(state))
end

-- Points spent in one branch of a class.
function ClassProgress.branchSpent(classId: string, state: ClassState, branchId: string): number
	local n = 0
	for id, taken in state.perks do
		local def = ClassPerks.get(id)
		if taken == true and def and def.classId == classId and def.branch == branchId then
			n += def.cost
		end
	end
	return n
end

-- Reasons: "unknown_perk" | "wrong_class" | "taken" | "locked_tier" | "no_points"
function ClassProgress.canTake(classId: string, state: ClassState, perkId: any): (boolean, string?)
	local def = ClassPerks.get(perkId)
	if not def then
		return false, "unknown_perk"
	end
	if def.classId ~= classId then
		return false, "wrong_class"
	end
	if type(state) ~= "table" or type(state.perks) ~= "table" then
		return false, "no_points"
	end
	if state.perks[def.id] then
		return false, "taken"
	end
	local prev = ClassPerks.previous(def)
	if prev and not state.perks[prev.id] then
		return false, "locked_tier"
	end
	if ClassProgress.branchSpent(classId, state, def.branch) < def.tier - 1 then
		return false, "locked_tier"
	end
	if ClassProgress.perkPointsFree(state) < def.cost then
		return false, "no_points"
	end
	return true, nil
end

function ClassProgress.takePerk(classId: string, state: ClassState, perkId: any): (boolean, string?)
	local ok, reason = ClassProgress.canTake(classId, state, perkId)
	if ok then
		state.perks[perkId] = true
	end
	return ok, reason
end

-- Valid perks only, in tier order, within the level's points. Over budget (after a
-- config change), the most expensive tops of branches are dropped first.
function ClassProgress.sanitizePerks(classId: string, level: number, raw: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(raw) ~= "table" then
		return out
	end
	local depth: { number } = {}
	for bi, b in ClassPerks.branches(classId) do
		local d = 0
		for _, def in b.perks do
			if raw[def.id] == true then
				d = def.tier
			else
				break
			end
		end
		depth[bi] = d
	end
	local points = ClassProgress.perkPoints(level)
	local branches = ClassPerks.branches(classId)
	local function spent(): number
		local n = 0
		for bi = 1, #branches do
			for t = 1, depth[bi] or 0 do
				n += ClassPerks.COST[t]
			end
		end
		return n
	end
	while spent() > points do
		local worst, worstTier = 0, 0
		for bi = 1, #branches do
			local d = depth[bi] or 0
			if d > 0 and d >= worstTier then
				worst, worstTier = bi, d
			end
		end
		if worst == 0 then
			break
		end
		depth[worst] -= 1
	end
	for bi, b in branches do
		for t = 1, depth[bi] or 0 do
			out[b.perks[t].id] = true
		end
	end
	return out
end

function ClassProgress.respecCost(level: number): number
	local l = clampInt(level, 1, ClassProgress.MAX_LEVEL, 1)
	return math.max(ClassProgress.RESPEC_MIN, ClassProgress.RESPEC_PER_LEVEL * l)
end

-- Unlocks -----------------------------------------------------------------------

function ClassProgress.unlockedAbilities(classId: string, level: number): { string }
	local out = {}
	local l = clampInt(level, 1, ClassProgress.MAX_LEVEL, 1)
	for _, e in ClassAbilities.forClass(classId) do
		if e.unlockLevel <= l then
			table.insert(out, e.id)
		end
	end
	return out
end

function ClassProgress.isAbilityUnlocked(classId: string, level: number, abilityId: any): boolean
	local e = ClassAbilities.get(abilityId)
	return e ~= nil
		and e.classId == classId
		and e.unlockLevel <= clampInt(level, 1, ClassProgress.MAX_LEVEL, 1)
end

-- Earned (level) skins only. Paid skins are owned through profile.ownedSkins.
function ClassProgress.unlockedSkins(classId: string, level: number): { string }
	local out = {}
	local l = clampInt(level, 1, ClassProgress.MAX_LEVEL, 1)
	for _, def in ClassSkins.forClass(classId) do
		if def.source == "level" and (def.unlockLevel or math.huge) <= l then
			table.insert(out, def.id)
		end
	end
	return out
end

-- Whether a skin may be worn on this class: earned by level, or a paid skin owned.
function ClassProgress.skinAllowed(
	classId: string,
	level: number,
	skinId: any,
	ownedSkins: { [string]: boolean }?
): boolean
	local def = ClassSkins.get(skinId)
	if not def or def.classId ~= classId then
		return false
	end
	if def.source == "level" then
		return (def.unlockLevel or math.huge) <= clampInt(level, 1, ClassProgress.MAX_LEVEL, 1)
	end
	return type(ownedSkins) == "table" and ownedSkins[def.id] == true
end

function ClassProgress.mastery(level: number): string
	local m = ClassSkins.masteryFor(clampInt(level, 1, ClassProgress.MAX_LEVEL, 1))
	return if m then m.tier else MASTERY_NONE
end

-- State helpers -------------------------------------------------------------------

-- Sanitises one saved class block (never throws). `ownedSkins` must be sanitised first.
function ClassProgress.sanitize(classId: string, raw: any, ownedSkins: { [string]: boolean }?): ClassState
	local r: { [any]: any } = if type(raw) == "table" then raw else {}
	local level = clampInt(r.level, 1, ClassProgress.MAX_LEVEL, 1)
	local cap = math.max(0, ClassProgress.xpToNext(level) - 1)
	local state: ClassState = {
		level = level,
		xp = clampInt(r.xp, 0, cap, 0),
		perks = ClassProgress.sanitizePerks(classId, level, r.perks),
	}
	local base = ClassAbilities.baseId(classId)
	if r.ability ~= base and ClassProgress.isAbilityUnlocked(classId, level, r.ability) then
		state.ability = r.ability
	end
	if ClassProgress.skinAllowed(classId, level, r.skin, ownedSkins) then
		state.skin = r.skin
	end
	return state
end

-- Sanitises profile.classes: known classes only; every unlocked class gets a block.
function ClassProgress.sanitizeClasses(
	raw: any,
	unlocked: { [string]: boolean },
	ownedSkins: { [string]: boolean }?
): { [string]: ClassState }
	local r: { [any]: any } = if type(raw) == "table" then raw else {}
	local out: { [string]: ClassState } = {}
	for _, id in Classes.ORDER do
		if type(r[id]) == "table" or unlocked[id] then
			out[id] = ClassProgress.sanitize(id, r[id], ownedSkins)
		end
	end
	return out
end

-- The profile's block for a class, created on first use (nil for an unknown class).
function ClassProgress.ensure(profile: Profile, classId: string): ClassState?
	if not isClass(classId) then
		return nil
	end
	local p = profile :: any
	if type(p.classes) ~= "table" then
		p.classes = {}
	end
	local st = p.classes[classId]
	if type(st) ~= "table" then
		st = ClassProgress.defaultState()
		p.classes[classId] = st
	end
	if type(st.perks) ~= "table" then
		st.perks = {}
	end
	return st
end

local function ownedSkins(profile: Profile): { [string]: boolean }
	local o = (profile :: any).ownedSkins
	return if type(o) == "table" then o else {}
end

-- Resolved ability id (the chosen one if still unlocked, else the base).
function ClassProgress.abilityId(classId: string, state: ClassState?): string?
	if state and ClassProgress.isAbilityUnlocked(classId, state.level, state.ability) then
		return state.ability
	end
	return ClassAbilities.baseId(classId)
end

-- AbilityDef copy for the resolved ability.
function ClassProgress.abilityFor(classId: string, state: ClassState?): AbilityDef?
	local id = ClassProgress.abilityId(classId, state)
	return if id then ClassAbilities.defCopy(id) else nil
end

-- Resolved skin id (nil = default look).
function ClassProgress.skinFor(profile: Profile?, classId: string): string?
	if not profile then
		return nil
	end
	local classes = (profile :: any).classes
	local st = if type(classes) == "table" then classes[classId] else nil
	if type(st) ~= "table" then
		return nil
	end
	if ClassProgress.skinAllowed(classId, st.level, st.skin, ownedSkins(profile)) then
		return st.skin
	end
	return nil
end

export type StatsClassState = { perks: { [string]: boolean }, ability: string?, level: number }

-- A copy of the class block for Run/Stats.compute's 6th argument. RunDirector should
-- take it once at run start, so lobby changes can't alter a hero mid-run.
function ClassProgress.classState(profile: Profile?, classId: string): StatsClassState?
	if not profile or not isClass(classId) then
		return nil
	end
	local classes = (profile :: any).classes
	local st = if type(classes) == "table" then classes[classId] else nil
	if type(st) ~= "table" then
		return { perks = {}, level = 1 }
	end
	local clean = ClassProgress.sanitize(classId, st, ownedSkins(profile))
	return { perks = clean.perks, ability = clean.ability, level = clean.level }
end

-- Deterministic preset for bots (or tests): fills branches 1, 2, 3 in tier order
-- (starting at branch `first`) with the points of `level`.
function ClassProgress.autoSpec(classId: string, level: number, first: number?): StatsClassState
	local state: ClassState = { xp = 0, level = clampInt(level, 1, ClassProgress.MAX_LEVEL, 1), perks = {} }
	local branches = ClassPerks.branches(classId)
	local n = #branches
	local start = clampInt(first, 1, math.max(1, n), 1)
	for k = 0, n - 1 do
		local b = branches[((start - 1 + k) % n) + 1]
		for _, def in b.perks do
			if not ClassProgress.takePerk(classId, state, def.id) then
				break
			end
		end
	end
	return { perks = state.perks, level = state.level }
end

-- Profile operations (ShopService) ------------------------------------------------
-- Reasons: "bad_class" | "class_locked" | plus canTake reasons | "nothing_to_reset"
-- | "insufficient_funds" | "no_token" | "ability_locked" | "unknown_ability"
-- | "skin_locked" | "unknown_skin"

local function ownedClassState(profile: Profile, classId: any): (ClassState?, string?)
	if not isClass(classId) then
		return nil, "bad_class"
	end
	if not profile.unlockedClasses[classId] then
		return nil, "class_locked"
	end
	return ClassProgress.ensure(profile, classId), nil
end

function ClassProgress.selectPerk(profile: Profile, classId: any, perkId: any): (boolean, string?, any)
	local st, why = ownedClassState(profile, classId)
	if not st then
		return false, why, nil
	end
	local ok, reason = ClassProgress.takePerk(classId, st, perkId)
	if not ok then
		return false, reason, nil
	end
	return true, nil, ClassPerks.get(perkId)
end

export type RespecResult = { paid: "cheese" | "token", cost: number, refunded: number }

-- payWith: "token" | "cheese" | nil (nil = a Respec Token if the player has one, else cheese).
function ClassProgress.resetPerks(
	profile: Profile,
	classId: any,
	payWith: any
): (boolean, string?, RespecResult?)
	local st, why = ownedClassState(profile, classId)
	if not st then
		return false, why, nil
	end
	local refunded = ClassProgress.perkPointsSpent(st)
	if next(st.perks) == nil then
		return false, "nothing_to_reset", nil
	end
	local p = profile :: any
	local tokens = if finite(p.respecTokens) then math.max(0, math.floor(p.respecTokens)) else 0
	local useToken = payWith == "token" or (payWith ~= "cheese" and tokens > 0)
	local result: RespecResult
	if useToken then
		if tokens <= 0 then
			return false, "no_token", nil
		end
		p.respecTokens = tokens - 1
		result = { paid = "token", cost = 1, refunded = refunded }
	else
		local cost = ClassProgress.respecCost(st.level)
		if profile.cheese < cost then
			return false, "insufficient_funds", nil
		end
		profile.cheese -= cost
		result = { paid = "cheese", cost = cost, refunded = refunded }
	end
	st.perks = {}
	return true, nil, result
end

-- abilityId nil (or the base id) goes back to the base ability.
function ClassProgress.selectAbility(profile: Profile, classId: any, abilityId: any): (boolean, string?)
	local st, why = ownedClassState(profile, classId)
	if not st then
		return false, why
	end
	local base = ClassAbilities.baseId(classId)
	if abilityId == nil or abilityId == base then
		st.ability = nil
		return true, nil
	end
	local e = ClassAbilities.get(abilityId)
	if not e or e.classId ~= classId then
		return false, "unknown_ability"
	end
	if e.unlockLevel > st.level then
		return false, "ability_locked"
	end
	st.ability = e.id
	return true, nil
end

-- skinId nil (or ClassSkins.DEFAULT_ID) goes back to the default look.
function ClassProgress.selectSkin(profile: Profile, classId: any, skinId: any): (boolean, string?)
	local st, why = ownedClassState(profile, classId)
	if not st then
		return false, why
	end
	if skinId == nil or skinId == ClassSkins.DEFAULT_ID then
		st.skin = nil
		return true, nil
	end
	local def = ClassSkins.get(skinId)
	if not def or def.classId ~= classId then
		return false, "unknown_skin"
	end
	if not ClassProgress.skinAllowed(classId, st.level, skinId, ownedSkins(profile)) then
		return false, "skin_locked"
	end
	st.skin = def.id
	return true, nil
end

-- Run award --------------------------------------------------------------------

export type ClassAward = {
	classId: string,
	xp: number,
	level: number,
	levelsGained: number,
	abilities: { string }, -- newly unlocked ability ids
	skins: { string }, -- newly unlocked earned skin ids
	mastery: string?, -- new mastery tier reached this run
	perkPoints: number, -- points gained this run
}

-- Adds class XP for `classId` and reports what unlocked. nil for an unknown class.
function ClassProgress.award(profile: Profile, classId: any, xp: number): ClassAward?
	if not isClass(classId) then
		return nil
	end
	local st = ClassProgress.ensure(profile, classId) :: ClassState
	local before = st.level
	local amount = if finite(xp) then math.clamp(math.floor(xp), 0, ClassProgress.MAX_RUN_XP) else 0
	local _, gained = ClassProgress.addXp(st, amount)
	local out: ClassAward = {
		classId = classId,
		xp = amount,
		level = st.level,
		levelsGained = gained,
		abilities = {},
		skins = {},
		perkPoints = ClassProgress.perkPoints(st.level) - ClassProgress.perkPoints(before),
	}
	if gained > 0 then
		for _, e in ClassAbilities.forClass(classId) do
			if e.unlockLevel > before and e.unlockLevel <= st.level then
				table.insert(out.abilities, e.id)
			end
		end
		for _, def in ClassSkins.forClass(classId) do
			local u = def.unlockLevel
			if def.source == "level" and u and u > before and u <= st.level then
				table.insert(out.skins, def.id)
			end
		end
		local m0, m1 = ClassProgress.mastery(before), ClassProgress.mastery(st.level)
		if m1 ~= m0 then
			out.mastery = m1
		end
	end
	return out
end

-- Client view -------------------------------------------------------------------

local function copySet(t: any): { [string]: boolean }
	local out = {}
	if type(t) == "table" then
		for k, v in t do
			if v == true then
				out[k] = true
			end
		end
	end
	return out
end

-- profile.classes for Net.S2C.Profile: resolved choices plus derived numbers.
function ClassProgress.view(profile: Profile): { [string]: any }
	local out: { [string]: any } = {}
	local classes = (profile :: any).classes
	if type(classes) ~= "table" then
		return out
	end
	local owned = ownedSkins(profile)
	for _, id in Classes.ORDER do
		local st = classes[id]
		if type(st) == "table" then
			out[id] = {
				level = st.level,
				xp = st.xp,
				xpToNext = ClassProgress.xpToNext(st.level),
				maxLevel = ClassProgress.MAX_LEVEL,
				perks = copySet(st.perks),
				perkPoints = ClassProgress.perkPoints(st.level),
				perkPointsFree = ClassProgress.perkPointsFree(st),
				ability = ClassProgress.abilityId(id, st),
				skin = if ClassProgress.skinAllowed(id, st.level, st.skin, owned) then st.skin else nil,
				mastery = ClassProgress.mastery(st.level),
				respecCost = ClassProgress.respecCost(st.level),
				unlockedAbilities = ClassProgress.unlockedAbilities(id, st.level),
				unlockedSkins = ClassProgress.unlockedSkins(id, st.level),
			}
		end
	end
	return out
end

return ClassProgress
