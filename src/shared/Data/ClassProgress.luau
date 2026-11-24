--!strict
-- Per-class permanent progression (GDD-v2 §5, team R3). Pure: no clock, no Rng.
--
-- profile.classes[classId] = { xp, level, perks = {[perkId] = true}, ability?, abilities?, skin? }
-- (Types.ClassState). Mastery is derived from level (mastery()).
--
-- (iteration 5, A3) Ability slots: 1 slot at class level 1, 2 at level 10, 3 at level 20;
-- Prestige >= 1 keeps all three (SLOT_LEVELS, slotCount). `abilities` = the saved picks
-- in slot order (dense, unique, unlocked ids of the class; saved only with 2+ entries,
-- so an old save migrates lazily). `ability` stays slot 1 (nil =
-- the base ability) and is AUTHORITATIVE for slot 1, so a save written by an older server
-- that only knew `ability` still resolves (sanitize moves it to the front). loadout()
-- resolves the slots: the saved picks first, then the remaining unlocked abilities in
-- unlock order fill any free slot (an unlocked slot is never empty).
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
--   (iteration 2) Prestige replaced Mastery Stars: past level 30, XP banks in `pxp`; the
--   Prestige action (doPrestige) resets the DISPLAYED level, keeps level 30, and gives
--   +1 perk point per Prestige up to P16 (perkPoints(level, prestige)), Config/Ascension.
-- Profile-level operations (ShopService remotes call these, so the rules are tested here):
--   selectPerk(profile, classId, perkId)           -> (ok, reason?, perkDef?)
--   resetPerks(profile, classId, payWith?)         -> (ok, reason?, {paid, cost?, refunded})
--   selectAbility(profile, classId, abilityId?, slot?) -> (ok, reason?)  (iter 5: slot 1-3, swaps)
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
local AscensionConfig = require("../Config/Ascension")
local Economy = require("../Config/Economy") -- iteration 6: the cheese grind (x0.6)

type Profile = Types.Profile
type ClassState = Types.ClassState
type AbilityDef = Types.AbilityDef

local ClassProgress = {}

ClassProgress.MAX_LEVEL = 30
-- (iteration 2) the gentler curve: xpToNext = floor(70 x level^1.35), ~85k XP to 30.
ClassProgress.XP_BASE = 70
ClassProgress.XP_EXP = 1.35
-- The v1-v6 curve, kept only for the profile v7 migration (levels recomputed upward).
ClassProgress.LEGACY_XP_BASE = 100
ClassProgress.LEGACY_XP_EXP = 1.4
ClassProgress.MAX_RUN_XP = 20000 -- sanity cap for one run's class XP
-- (iteration 2) Prestige replaces Mastery Stars (Config/Ascension). pxp = XP since the
-- last Prestige (or since reaching 30 at P0); the displayed level is derived from it.
ClassProgress.MAX_PRESTIGE = 99
ClassProgress.PRESTIGE_XP = 12_000
ClassProgress.PERK_PRESTIGE_CAP = 16
ClassProgress.PRESTIGE_REWARD = table.freeze({ cheese = Economy.cheese(300), goldenCheese = 10 })
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
	-- (iter 1, P-2 / H4) a wipe still pays: time played
	perMinute = 10, -- minutes in the match (waves + boss)
	maxMinutes = 30,
	-- (iteration 2) class XP from kills: +0.5 per stomp, no cap
	perStomp = 0.5,
	-- (iteration 2) the n-th champion your squad kills while you take part pays 50 x n
	-- (at most 250 each), counted up to maxChampions per match
	perChampionStep = 50,
	maxChampionXp = 250,
	maxChampions = 10,
})
-- (iter 1) every finished match pays at least this much class XP, and a player's first
-- match always reaches class level 2 (Data/Award).
ClassProgress.MIN_RUN_XP = 25

-- (iteration 5, A3) class level that unlocks each ability slot; Prestige >= 1 keeps all.
ClassProgress.SLOT_LEVELS = table.freeze({ 1, 10, 20 })
-- (iteration 6) a 4th slot: Ascension node 3 OR Prestige 5, whichever comes first
ClassProgress.SLOT4_PRESTIGE = 5
ClassProgress.SLOT4_NODE = 3
ClassProgress.MAX_SLOTS = 4

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

-- (iteration 2) The v1-v6 curve, for the profile v7 migration only.
function ClassProgress.legacyXpToNext(level: number): number
	local l = clampInt(level, 1, ClassProgress.MAX_LEVEL, 1)
	if l >= ClassProgress.MAX_LEVEL then
		return 0
	end
	return math.floor(ClassProgress.LEGACY_XP_BASE * l ^ ClassProgress.LEGACY_XP_EXP + 0.5)
end

function ClassProgress.legacyTotalXpFor(level: number): number
	local t = 0
	for l = 1, clampInt(level, 1, ClassProgress.MAX_LEVEL, 1) - 1 do
		t += ClassProgress.legacyXpToNext(l)
	end
	return t
end

-- (iteration 2) The level a lifetime XP reaches on the current curve, never below
-- `atLeast`. Returns (level, xp inside it, overflow past level 30).
function ClassProgress.levelForXp(lifetime: number, atLeast: number?): (number, number, number)
	local xp = if finite(lifetime) and lifetime > 0 then math.floor(lifetime) else 0
	local level = 1
	while level < ClassProgress.MAX_LEVEL and xp >= ClassProgress.xpToNext(level) do
		xp -= ClassProgress.xpToNext(level)
		level += 1
	end
	local overflow = 0
	if level >= ClassProgress.MAX_LEVEL then
		overflow = xp
		xp = 0
	end
	local floorLevel = clampInt(atLeast, 1, ClassProgress.MAX_LEVEL, 1)
	if floorLevel > level then
		return floorLevel, 0, 0
	end
	return level, xp, overflow
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

-- Adds class XP in place. Returns (state, levelsGained, overflow): XP past MAX_LEVEL is
-- not kept in `xp`; it is returned as `overflow` (award() turns it into Mastery Stars).
function ClassProgress.addXp(state: ClassState, xp: number): (ClassState, number, number)
	if not finite(xp) or xp <= 0 then
		return state, 0, 0
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
	local overflow = 0
	if state.level >= ClassProgress.MAX_LEVEL then
		overflow = state.xp
		state.xp = 0
	end
	return state, gained, overflow
end

-- (v6, read-only since iteration 2) Mastery Stars of a saved block: they became Prestige.
function ClassProgress.stars(state: any): number
	if type(state) ~= "table" then
		return 0
	end
	return clampInt(state.stars, 0, 99, 0)
end

-- (iteration 2) Prestige -----------------------------------------------------------

function ClassProgress.prestige(state: any): number
	if type(state) ~= "table" then
		return 0
	end
	return clampInt(state.prestige, 0, ClassProgress.MAX_PRESTIGE, 0)
end

-- XP toward the next Prestige (banked at level 30), 0..2 x PRESTIGE_XP.
function ClassProgress.pxp(state: any): number
	if type(state) ~= "table" then
		return 0
	end
	return clampInt(state.pxp, 0, 2 * ClassProgress.PRESTIGE_XP, 0)
end

-- The DISPLAYED level: the class level before the first Prestige, then the re-climb
-- 1..30 over PRESTIGE_XP. Unlocks always use the stored level (30 after a Prestige).
function ClassProgress.displayLevel(state: any): number
	if type(state) ~= "table" then
		return 1
	end
	local p = ClassProgress.prestige(state)
	if p <= 0 then
		return clampInt(state.level, 1, ClassProgress.MAX_LEVEL, 1)
	end
	local frac = ClassProgress.pxp(state) / ClassProgress.PRESTIGE_XP
	return math.clamp(1 + math.floor(frac * (ClassProgress.MAX_LEVEL - 1)), 1, ClassProgress.MAX_LEVEL)
end

function ClassProgress.canPrestige(state: any): boolean
	if
		type(state) ~= "table"
		or clampInt(state.level, 1, ClassProgress.MAX_LEVEL, 1) < ClassProgress.MAX_LEVEL
	then
		return false
	end
	local p = ClassProgress.prestige(state)
	if p >= ClassProgress.MAX_PRESTIGE then
		return false
	end
	return p == 0 or ClassProgress.pxp(state) >= ClassProgress.PRESTIGE_XP
end

-- Banks XP past level 30 toward the next Prestige.
function ClassProgress.addPrestigeXp(state: ClassState, xp: number): number
	if
		not finite(xp)
		or xp <= 0
		or clampInt(state.level, 1, ClassProgress.MAX_LEVEL, 1) < ClassProgress.MAX_LEVEL
	then
		return 0
	end
	local s = state :: any
	local before = ClassProgress.pxp(s)
	s.pxp = math.min(2 * ClassProgress.PRESTIGE_XP, before + math.floor(math.min(xp, ClassProgress.MAX_STAT)))
	return s.pxp - before
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
	-- M2 sends minutes (or seconds), mice (stomps) and champAssists (or championAssists:
	-- champions the squad killed while this hero took part), and tierReward
	-- (Config/Difficulty reward x, default 1).
	local minutes = if finite(summary.minutes)
		then summary.minutes
		elseif finite(summary.seconds) then summary.seconds / 60
		else 0
	local assists = if finite(summary.champAssists) then summary.champAssists else summary.championAssists
	local xp = W.perStage * math.floor(num(summary.stagesSurvived, W.maxStages))
		+ W.perBossShare * num(summary.bossDamageShare, W.maxBossShare)
		+ W.perHeroDown * math.floor(num(summary.heroDowns, W.maxHeroDowns))
		+ W.perPoi * math.floor(num(summary.pois, W.maxPois))
		+ W.perMinute * num(minutes, W.maxMinutes)
		+ W.perStomp * math.floor(num(summary.mice, 1e6))
		+ ClassProgress.championXp(num(assists, W.maxChampions))
	if summary.extracted == true then
		xp *= W.extractMult
	end
	local tier = if finite(summary.tierReward) and summary.tierReward > 0
		then math.min(summary.tierReward, 10)
		else 1
	xp *= tier
	-- a real match summary (it always has stagesSurvived) pays at least MIN_RUN_XP
	if finite(summary.stagesSurvived) then
		xp = math.max(xp, ClassProgress.MIN_RUN_XP)
	end
	return math.clamp(math.floor(xp + 0.5), 0, ClassProgress.MAX_RUN_XP)
end

-- (iteration 2) Escalating champion class XP: the n-th champion pays 50 x n (max 250).
function ClassProgress.championXp(count: number): number
	local W = ClassProgress.RUN_XP
	local n = if finite(count) and count > 0 then math.min(math.floor(count), W.maxChampions) else 0
	local xp = 0
	for i = 1, n do
		xp += math.min(W.perChampionStep * i, W.maxChampionXp)
	end
	return xp
end

-- Perks -------------------------------------------------------------------------
-- (iteration 6, team Talents) Talent trees (Config/ClassPerks): 3 branches x 9 nodes,
-- ranks, row gates (points in the branch's lower rows), requirements and exclusive
-- choices. Saved keys stay { [key] = true } (rank r >= 2 = "<id>#r"); old ladder ids are
-- migrated by sanitizePerks (same points, same branch, ClassPerks.PATH).

-- Perk points of a level: level - 1, plus (iteration 2) +1 per Prestige up to P16, so
-- the 45-point tree is full at P16 (P1 = the old "first star" 30th point).
function ClassProgress.perkPoints(level: number, prestige: number?): number
	local l = clampInt(level, 1, ClassProgress.MAX_LEVEL, 1)
	local p = if finite(prestige)
		then math.clamp(math.floor(prestige :: number), 0, ClassProgress.PERK_PRESTIGE_CAP)
		else 0
	local bonus = if l >= ClassProgress.MAX_LEVEL then p else 0
	return l - 1 + bonus
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
	return math.max(
		0,
		ClassProgress.perkPoints(state.level, ClassProgress.prestige(state))
			- ClassProgress.perkPointsSpent(state)
	)
end

-- Points spent in one branch of a class (rows below `belowRow` only, when given).
function ClassProgress.branchSpent(
	classId: string,
	state: ClassState,
	branchId: string,
	belowRow: number?
): number
	local n = 0
	for id, taken in state.perks do
		local def = ClassPerks.get(id)
		if
			taken == true
			and def
			and def.classId == classId
			and def.branch == branchId
			and (belowRow == nil or def.tier < belowRow)
		then
			n += def.cost
		end
	end
	return n
end

-- Current rank of a node (0..maxRank) in a class state.
function ClassProgress.rankOf(state: ClassState, perkId: any): number
	local def = ClassPerks.get(perkId)
	if not def or type(state) ~= "table" then
		return 0
	end
	return ClassPerks.rankOf(state.perks, def)
end

-- Taking the next rank of node `perkId` (a node id; a rank key means its node).
-- Reasons: "unknown_perk" | "wrong_class" | "taken" (maxed) | "locked_tier" (row gate
-- or requirement) | "exclusive" (the other choice is taken) | "no_points"
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
	if ClassPerks.rankOf(state.perks, def) >= def.maxRank then
		return false, "taken"
	end
	if #def.requires > 0 then
		local ok = false
		for _, rid in def.requires do
			if state.perks[rid] == true then
				ok = true
				break
			end
		end
		if not ok then
			return false, "locked_tier"
		end
	end
	if ClassProgress.branchSpent(classId, state, def.branch, def.tier) < def.gate then
		return false, "locked_tier"
	end
	if def.exclusive then
		for _, other in ClassPerks.forClass(classId) do
			if other ~= def and other.exclusive == def.exclusive and state.perks[other.id] == true then
				return false, "exclusive"
			end
		end
	end
	if ClassProgress.perkPointsFree(state) < def.cost then
		return false, "no_points"
	end
	return true, nil
end

function ClassProgress.takePerk(classId: string, state: ClassState, perkId: any): (boolean, string?)
	local ok, reason = ClassProgress.canTake(classId, state, perkId)
	if ok then
		local def = ClassPerks.get(perkId) :: any
		local r = ClassPerks.rankOf(state.perks, def)
		state.perks[ClassPerks.rankKey(def.id, r + 1)] = true
	end
	return ok, reason
end

-- Ranks per node id of one branch, valid in row order (gates, requirements, exclusive
-- choices, max ranks). `ranks` holds the wanted ranks; returns the legal ones.
local function legalBranch(b: any, ranks: { [string]: number }): { [string]: number }
	local out: { [string]: number } = {}
	local spentBelow = 0
	local row = 1
	local rowPoints = 0
	local taken: { [string]: boolean } = {}
	for _, def in b.nodes do
		if def.tier ~= row then
			spentBelow += rowPoints
			rowPoints = 0
			row = def.tier
		end
		local want = math.clamp(math.floor(ranks[def.id] or 0), 0, def.maxRank)
		if want > 0 and spentBelow >= def.gate then
			local reqOk = #def.requires == 0
			for _, rid in def.requires do
				if taken[rid] then
					reqOk = true
				end
			end
			local exclOk = true
			if def.exclusive then
				for id2 in taken do
					local d2 = ClassPerks.byId[id2]
					if d2 and d2.exclusive == def.exclusive then
						exclOk = false
					end
				end
			end
			if reqOk and exclOk then
				out[def.id] = want
				taken[def.id] = true
				rowPoints += want * def.cost
			end
		end
	end
	return out
end

-- Wanted ranks of a branch from the ClassPerks.PATH prefix worth `points` points.
local function pathRanks(b: any, points: number): { [string]: number }
	local ranks: { [string]: number } = {}
	local byKey: { [string]: any } = {}
	for _, def in b.nodes do
		byKey[def.key] = def
	end
	for i = 1, math.min(points, #ClassPerks.PATH) do
		local def = byKey[ClassPerks.PATH[i]]
		if def then
			ranks[def.id] = (ranks[def.id] or 0) + 1
		end
	end
	return ranks
end

-- Valid perks only (rows, gates, requirements, choices, max ranks) within the level's
-- points. Old ladder ids of a branch with no new nodes become the same points along
-- ClassPerks.PATH. Over budget (after a config change), the highest-row ranks go first.
function ClassProgress.sanitizePerks(
	classId: string,
	level: number,
	raw: any,
	stars: number?
): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(raw) ~= "table" then
		return out
	end
	local list = ClassPerks.branches(classId)
	local per: { { [string]: number } } = {}
	for bi, b in list do
		local ranks: { [string]: number } = {}
		local any = false
		for _, def in b.nodes do
			local r = ClassPerks.rankOf(raw, def)
			if r > 0 then
				ranks[def.id] = r
				any = true
			end
		end
		if not any then
			-- legacy ladder: tiers 1..d taken in order = d(d+1)/2 points
			local d = 0
			for t = 1, ClassPerks.LEGACY_TIERS do
				if raw[classId .. "_" .. b.id .. "_" .. t] == true then
					d = t
				else
					break
				end
			end
			if d > 0 then
				ranks = pathRanks(b, d * (d + 1) // 2)
			end
		end
		per[bi] = legalBranch(b, ranks)
	end
	local points = ClassProgress.perkPoints(level, stars)
	local function spent(): number
		local n = 0
		for bi = 1, #list do
			for _, r in per[bi] do
				n += r
			end
		end
		return n
	end
	while spent() > points do
		-- drop one rank of the highest-row node (latest node in its row) of any branch
		local worstBi, worstDef = 0, nil :: any
		for bi, b in list do
			for _, def in b.nodes do
				if (per[bi][def.id] or 0) > 0 and (worstDef == nil or def.tier >= worstDef.tier) then
					worstBi, worstDef = bi, def
				end
			end
		end
		if worstDef == nil then
			break
		end
		local r = per[worstBi][worstDef.id] - 1
		per[worstBi][worstDef.id] = if r > 0 then r else nil :: any
		per[worstBi] = legalBranch(list[worstBi], per[worstBi])
	end
	for bi in list do
		for id, r in per[bi] do
			for k = 1, r do
				out[ClassPerks.rankKey(id, k)] = true
			end
		end
	end
	return out
end

-- (iteration 6) The effective ranks of a sanitised set: { [nodeId] = rank }.
function ClassProgress.perkRanks(classId: string, perks: any): { [string]: number }
	local out: { [string]: number } = {}
	for _, def in ClassPerks.forClass(classId) do
		local r = ClassPerks.rankOf(perks, def)
		if r > 0 then
			out[def.id] = r
		end
	end
	return out
end

function ClassProgress.respecCost(level: number): number
	local l = clampInt(level, 1, ClassProgress.MAX_LEVEL, 1)
	return math.max(ClassProgress.RESPEC_MIN, ClassProgress.RESPEC_PER_LEVEL * l)
end

-- Unlocks -----------------------------------------------------------------------

-- (iteration 6) Ascension nodes (0..8) for a Prestige and lifetime class stomps: the
-- same derivation as Data/Ascension.nodes (Config/Ascension.NODES gates, in order).
-- Kept here so ability gates need no Data/Ascension require (it requires this module).
function ClassProgress.ascNodes(prestige: any, stomps: any): number
	local p = if finite(prestige) then math.floor(prestige) else 0
	local s = if finite(stomps) then stomps else 0
	local count = 0
	for _, node in AscensionConfig.NODES do
		if p >= node.prestige and s >= node.stomps then
			count = node.node
		else
			break
		end
	end
	return count
end

-- Whether entry `e` is open at (level, prestige?, nodes?) (iteration 6 gates).
local function gateOpen(e: any, level: number, prestige: number?, nodes: number?): boolean
	if e.unlockLevel > level then
		return false
	end
	if e.unlockPrestige and (prestige or 0) < e.unlockPrestige then
		return false
	end
	if e.unlockNode and (nodes or 0) < e.unlockNode then
		return false
	end
	return true
end

-- prestige / nodes (iteration 6) open the advanced abilities; without them only the
-- level-gated ones count.
function ClassProgress.unlockedAbilities(
	classId: string,
	level: number,
	prestige: number?,
	nodes: number?
): { string }
	local out = {}
	local l = clampInt(level, 1, ClassProgress.MAX_LEVEL, 1)
	for _, e in ClassAbilities.forClass(classId) do
		if gateOpen(e, l, prestige, nodes) then
			table.insert(out, e.id)
		end
	end
	return out
end

function ClassProgress.isAbilityUnlocked(
	classId: string,
	level: number,
	abilityId: any,
	prestige: number?,
	nodes: number?
): boolean
	local e = ClassAbilities.get(abilityId)
	return e ~= nil
		and e.classId == classId
		and gateOpen(e, clampInt(level, 1, ClassProgress.MAX_LEVEL, 1), prestige, nodes)
end

-- (iteration 6) (prestige, nodes) of a class block / class state.
function ClassProgress.gatesOf(st: any): (number, number)
	if type(st) ~= "table" then
		return 0, 0
	end
	local p = ClassProgress.prestige(st)
	return p, ClassProgress.ascNodes(p, st.stomps)
end

-- (iteration 5, A3) Ability slots ---------------------------------------------------

-- Number of ability slots at a (stored) class level; Prestige >= 1 keeps slots 1-3.
-- (iteration 6) slot 4: Prestige >= SLOT4_PRESTIGE or nodes >= SLOT4_NODE.
function ClassProgress.slotCount(level: any, prestige: any, nodes: any): number
	if
		(finite(prestige) and prestige >= ClassProgress.SLOT4_PRESTIGE)
		or (finite(nodes) and nodes >= ClassProgress.SLOT4_NODE)
	then
		return 4
	end
	if finite(prestige) and prestige >= 1 then
		return #ClassProgress.SLOT_LEVELS
	end
	local l = clampInt(level, 1, ClassProgress.MAX_LEVEL, 1)
	local n = 0
	for _, need in ClassProgress.SLOT_LEVELS do
		if l >= need then
			n += 1
		end
	end
	return math.max(1, n)
end

-- Class level that unlocks `slot` (nil for a slot that doesn't exist).
function ClassProgress.slotLevel(slot: any): number?
	if type(slot) ~= "number" then
		return nil
	end
	return ClassProgress.SLOT_LEVELS[slot]
end

-- The saved picks, cleaned: slot 1 = the resolved `ability` (authoritative), then the
-- `abilities` entries that are unlocked ids of this class, without duplicates (max 4).
function ClassProgress.sanitizeLoadout(
	classId: string,
	level: number,
	ability: any,
	abilities: any,
	prestige: number?,
	nodes: number?
): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local first = if ClassProgress.isAbilityUnlocked(classId, level, ability, prestige, nodes)
		then ability :: string
		else ClassAbilities.baseId(classId)
	if first then
		table.insert(out, first)
		seen[first] = true
	end
	if type(abilities) == "table" then
		for i = 1, ClassProgress.MAX_SLOTS do
			local id = abilities[i]
			if
				#out < ClassProgress.MAX_SLOTS
				and type(id) == "string"
				and not seen[id]
				and ClassProgress.isAbilityUnlocked(classId, level, id, prestige, nodes)
			then
				table.insert(out, id)
				seen[id] = true
			end
		end
	end
	return out
end

-- The equipped ability ids in slot order (length = unlocked slots, capped by the
-- abilities unlocked). `state` needs level; ability / abilities / prestige optional.
function ClassProgress.loadout(classId: string, state: any): { string }
	local st: { [any]: any } = if type(state) == "table" then state else {}
	local level = clampInt(st.level, 1, ClassProgress.MAX_LEVEL, 1)
	local prestige, nodes = ClassProgress.gatesOf(st)
	local n = ClassProgress.slotCount(level, prestige, nodes)
	local picks = ClassProgress.sanitizeLoadout(classId, level, st.ability, st.abilities, prestige, nodes)
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, id in picks do
		if #out >= n then
			break
		end
		table.insert(out, id)
		seen[id] = true
	end
	for _, id in ClassProgress.unlockedAbilities(classId, level, prestige, nodes) do
		if #out >= n then
			break
		end
		if not seen[id] then
			table.insert(out, id)
			seen[id] = true
		end
	end
	return out
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
	local atMax = level >= ClassProgress.MAX_LEVEL
	local prestige = if atMax then ClassProgress.prestige(r) else 0
	local state: ClassState = {
		level = level,
		xp = clampInt(r.xp, 0, cap, 0),
		perks = ClassProgress.sanitizePerks(classId, level, r.perks, prestige),
	}
	-- (v6) Mastery Stars: kept READ-ONLY for one release (they became Prestige)
	local stars = ClassProgress.stars(r)
	if stars > 0 then
		state.stars = stars
	end
	local sx = clampInt(r.starXp, 0, ClassProgress.PRESTIGE_XP, 0)
	if sx > 0 then
		state.starXp = sx
	end
	-- (v7) Prestige, the XP toward the next one, and the Prestiges already rewarded
	if prestige > 0 then
		state.prestige = prestige
	end
	local pxp = if atMax then ClassProgress.pxp(r) else 0
	if pxp > 0 then
		state.pxp = pxp
	end
	local paid = clampInt(r.prestigePaid, 0, ClassProgress.MAX_PRESTIGE, 0)
	if paid > 0 then
		state.prestigePaid = paid
	end
	-- (v7) lifetime stomps and the chosen ascension look (Data/Ascension)
	if finite(r.stomps) and r.stomps > 0 then
		state.stomps = math.min(1_000_000_000, math.floor(r.stomps))
	end
	if type(r.look) == "string" and #r.look <= 16 then
		state.look = r.look
	end
	local base = ClassAbilities.baseId(classId)
	local gp, gn = ClassProgress.gatesOf(state) -- (iteration 6) prestige / ascension gates
	if r.ability ~= base and ClassProgress.isAbilityUnlocked(classId, level, r.ability, gp, gn) then
		state.ability = r.ability
	end
	-- (iteration 5, A3) slot picks; the single `ability` is slot 1. Stored only when it
	-- holds more than slot 1 (a one-slot loadout is `ability` alone, as before).
	local picks = ClassProgress.sanitizeLoadout(classId, level, state.ability, r.abilities, gp, gn)
	if #picks > 1 then
		state.abilities = picks
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
	local gp, gn = ClassProgress.gatesOf(state)
	if state and ClassProgress.isAbilityUnlocked(classId, state.level, state.ability, gp, gn) then
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

export type StatsClassState = {
	perks: { [string]: boolean },
	ability: string?,
	abilities: { string }?, -- (iteration 5) saved slot picks (Stats resolves them with loadout)
	level: number,
	prestige: number?,
	stomps: number?, -- (iteration 6) for the Ascension-node ability / slot gates
}

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
	return {
		perks = clean.perks,
		ability = clean.ability,
		abilities = clean.abilities,
		level = clean.level,
		prestige = clean.prestige,
		stomps = clean.stomps,
	}
end

-- Deterministic preset for bots (or tests): fills branches 1, 2, 3 in tier order
-- (starting at branch `first`) with the points of `level`.
function ClassProgress.autoSpec(classId: string, level: number, first: number?): StatsClassState
	-- (iteration 6, team Talents) branch by branch along ClassPerks.PATH (keystones
	-- included); bots alternate the row-3 choice by starting branch
	local state: ClassState = { xp = 0, level = clampInt(level, 1, ClassProgress.MAX_LEVEL, 1), perks = {} }
	local branches = ClassPerks.branches(classId)
	local n = #branches
	local start = clampInt(first, 1, math.max(1, n), 1)
	for k = 0, n - 1 do
		local bi = ((start - 1 + k) % n) + 1
		for _, key in ClassPerks.PATH do
			local useKey = if key == "e1" and start % 2 == 0 then "e2" else key
			local def = ClassPerks.node(classId, bi, useKey)
			if not def or not ClassProgress.takePerk(classId, state, def.id) then
				break
			end
		end
	end
	return { perks = state.perks, level = state.level }
end

-- Profile operations (ShopService) ------------------------------------------------
-- Reasons: "bad_class" | "class_locked" | plus canTake reasons | "nothing_to_reset"
-- | "insufficient_funds" | "no_token" | "ability_locked" | "unknown_ability"
-- | "skin_locked" | "unknown_skin" | (iteration 5) "bad_ability_slot" | "ability_slot_locked"

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
	-- A Robux-bought token is spent only when asked for explicitly ("token");
	-- nil or "cheese" pays cheese (QC-A minor 4 / QC-B V2-m5).
	local useToken = payWith == "token"
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

-- Puts `abilityId` in `slot` (nil = 1). abilityId nil means the base ability. If the
-- ability is already in another slot, the two slots swap (no duplicates ever).
function ClassProgress.selectAbility(
	profile: Profile,
	classId: any,
	abilityId: any,
	slot: any
): (boolean, string?)
	local st, why = ownedClassState(profile, classId)
	if not st then
		return false, why
	end
	local s = if slot == nil then 1 else slot
	if type(s) ~= "number" or s ~= s or s % 1 ~= 0 or s < 1 or s > ClassProgress.MAX_SLOTS then
		return false, "bad_ability_slot"
	end
	local base = ClassAbilities.baseId(classId)
	local id = if abilityId == nil then base else abilityId
	local e = ClassAbilities.get(id)
	if not e or e.classId ~= classId then
		return false, "unknown_ability"
	end
	local gp, gn = ClassProgress.gatesOf(st)
	if not ClassProgress.isAbilityUnlocked(classId, st.level, e.id, gp, gn) then
		return false, "ability_locked"
	end
	if s > ClassProgress.slotCount(st.level, gp, gn) then
		return false, "ability_slot_locked"
	end
	local list = ClassProgress.loadout(classId, st)
	if s > #list + 1 then
		return false, "ability_slot_locked"
	end
	local at = table.find(list, e.id)
	if at ~= s then
		if at then
			list[at] = list[s] -- swap the two slots
		end
		list[s] = e.id
	end
	st.abilities = if #list > 1 then list else nil
	st.ability = if list[1] == base then nil else list[1]
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

-- (iteration 2) The Prestige action. Reasons: "bad_class" | "class_locked" | "not_ready".
-- The stored level stays 30 (every perk, ability and skin is kept); the displayed level
-- restarts at 1. XP banked past the requirement carries over (below one full re-climb).
-- Returns (ok, reason?, {prestige, reward?}); the reward is paid once per Prestige number.
function ClassProgress.doPrestige(profile: Profile, classId: any): (boolean, string?, any)
	local st, why = ownedClassState(profile, classId)
	if not st then
		return false, why, nil
	end
	if not ClassProgress.canPrestige(st) then
		return false, "not_ready", nil
	end
	local s = st :: any
	local before = ClassProgress.prestige(s)
	local banked = ClassProgress.pxp(s)
	local carry = if before == 0 then banked else banked - ClassProgress.PRESTIGE_XP
	s.prestige = before + 1
	-- (iteration 3, T-25) keep the whole bank (up to 2 x PRESTIGE_XP): a full extra
	-- re-climb makes the next Prestige available at once (multi-Prestige)
	s.pxp = math.clamp(carry, 0, 2 * ClassProgress.PRESTIGE_XP)
	if s.pxp == 0 then
		s.pxp = nil
	end
	local out: { [string]: any } = { prestige = s.prestige }
	-- (iteration 6) what this Prestige opened: advanced abilities and the 4th slot
	do
		local nodes0 = ClassProgress.ascNodes(before, s.stomps)
		local nodes1 = ClassProgress.ascNodes(s.prestige, s.stomps)
		local newIds = {}
		for _, e in ClassAbilities.forClass(classId) do
			local was = ClassProgress.isAbilityUnlocked(classId, s.level, e.id, before, nodes0)
			if not was and ClassProgress.isAbilityUnlocked(classId, s.level, e.id, s.prestige, nodes1) then
				table.insert(newIds, e.id)
			end
		end
		if #newIds > 0 then
			out.abilities = newIds
		end
		if
			ClassProgress.slotCount(s.level, s.prestige, nodes1)
			> ClassProgress.slotCount(s.level, before, nodes0)
		then
			out.slots = { ClassProgress.slotCount(s.level, s.prestige, nodes1) }
		end
	end
	local paid = clampInt(s.prestigePaid, 0, ClassProgress.MAX_PRESTIGE, 0)
	if s.prestige > paid then
		s.prestigePaid = s.prestige
		local R = ClassProgress.PRESTIGE_REWARD
		profile.cheese = math.min(1_000_000_000, profile.cheese + R.cheese)
		profile.goldenCheese = math.min(1_000_000_000, profile.goldenCheese + R.goldenCheese)
		out.reward = { cheese = R.cheese, goldenCheese = R.goldenCheese }
	end
	return true, nil, out
end

-- Run award --------------------------------------------------------------------

export type ClassAward = {
	classId: string,
	xp: number,
	level: number,
	levelsGained: number,
	abilities: { string }, -- newly unlocked ability ids
	slots: { number }?, -- (iteration 5) newly unlocked ability slots (2, 3)
	skins: { string }, -- newly unlocked earned skin ids
	mastery: string?, -- new mastery tier reached this run
	perkPoints: number, -- points gained this run
	plevel: number?, -- (iteration 2) the displayed level after this run (Prestige re-climb)
	plevelsGained: number?, -- displayed levels gained past level 30
	prestigeReady: boolean?, -- the Prestige action became available this run
}

-- Adds class XP for `classId` and reports what unlocked. nil for an unknown class.
function ClassProgress.award(profile: Profile, classId: any, xp: number): ClassAward?
	if not isClass(classId) then
		return nil
	end
	local st = ClassProgress.ensure(profile, classId) :: ClassState
	local before = st.level
	local plBefore = ClassProgress.displayLevel(st)
	local readyBefore = ClassProgress.canPrestige(st)
	local amount = if finite(xp) then math.clamp(math.floor(xp), 0, ClassProgress.MAX_RUN_XP) else 0
	local _, gained, overflow = ClassProgress.addXp(st, amount)
	ClassProgress.addPrestigeXp(st, overflow)
	local p = ClassProgress.prestige(st)
	local out: ClassAward = {
		classId = classId,
		xp = amount,
		level = st.level,
		levelsGained = gained,
		abilities = {},
		skins = {},
		perkPoints = ClassProgress.perkPoints(st.level, p) - ClassProgress.perkPoints(before, p),
	}
	if p > 0 then
		out.plevel = ClassProgress.displayLevel(st)
		out.plevelsGained = math.max(0, out.plevel - plBefore)
	end
	if ClassProgress.canPrestige(st) and not readyBefore then
		out.prestigeReady = true
	end
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
		local nodes = ClassProgress.ascNodes(p, (st :: any).stomps)
		local s0, s1 = ClassProgress.slotCount(before, p, nodes), ClassProgress.slotCount(st.level, p, nodes)
		if s1 > s0 then
			local slots = {}
			for k = s0 + 1, s1 do
				table.insert(slots, k)
			end
			out.slots = slots
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
				perkPoints = ClassProgress.perkPoints(st.level, ClassProgress.prestige(st)),
				-- (iteration 2) Prestige: displayLevel is what the UI shows as "Level"
				prestige = ClassProgress.prestige(st),
				displayLevel = ClassProgress.displayLevel(st),
				prestigeXp = ClassProgress.pxp(st),
				prestigeXpToNext = ClassProgress.PRESTIGE_XP,
				canPrestige = ClassProgress.canPrestige(st),
				maxPrestige = ClassProgress.MAX_PRESTIGE,
				stomps = (st :: any).stomps or 0,
				perkPointsFree = ClassProgress.perkPointsFree(st),
				ability = ClassProgress.abilityId(id, st),
				skin = if ClassProgress.skinAllowed(id, st.level, st.skin, owned) then st.skin else nil,
				mastery = ClassProgress.mastery(st.level),
				respecCost = ClassProgress.respecCost(st.level),
				unlockedAbilities = ClassProgress.unlockedAbilities(id, st.level, ClassProgress.gatesOf(st)),
				-- (iteration 5, A3) equipped ability ids in slot order (abilities[1] == ability),
				-- the unlocked slot count and the class level of each slot
				abilities = ClassProgress.loadout(id, st),
				abilitySlots = ClassProgress.slotCount(st.level, ClassProgress.gatesOf(st)),
				slotLevels = { table.unpack(ClassProgress.SLOT_LEVELS) },
				-- (iteration 6) slot 4's rule (no level): Prestige 5 or Ascension node 3
				slot4 = { prestige = ClassProgress.SLOT4_PRESTIGE, node = ClassProgress.SLOT4_NODE },
				unlockedSkins = ClassProgress.unlockedSkins(id, st.level),
			}
		end
	end
	return out
end

return ClassProgress
