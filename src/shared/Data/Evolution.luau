--!strict
-- (v5) Lifetime Stomps, Evolutions and free class unlocks by stomps (Team P). Pure.
-- Content: Config/Evolutions.
--   classes[id].stomps   mice this player stomped with that class (x Pressure bonus)
--   classes[id].evo      the evolution stage the player DISPLAYS (nil = the highest)
--   stats.stomps         account total (leaderboard "stomps")
-- Bonuses always follow the highest UNLOCKED stage of the class played, whatever look
-- is displayed.

local Types = require("../Types")
local E = require("../Config/Evolutions")
local ClassProgress = require("./ClassProgress")
local RunBonus = require("./RunBonus")

type Profile = Types.Profile

local Evolution = {}

Evolution.MAX_STOMPS = 1_000_000_000

local function n(v: any): number
	return if type(v) == "number" and v == v and v > 0 and math.abs(v) ~= math.huge then math.floor(v) else 0
end

-- Stomps of one match: mice x (1 + 0.05 x Pressure). No outcome multiplier (Z-15).
function Evolution.matchStomps(mice: number?, pressure: number?): number
	local m = math.min(n(mice), 100_000)
	local p = math.min(n(pressure), 21)
	return math.floor(m * (1 + E.PRESSURE_PER_POINT * p))
end

-- Highest stage unlocked by `stomps` (1..#STAGES).
function Evolution.stageFor(stomps: number): number
	local s = n(stomps)
	local best = 1
	for _, def in E.STAGES do
		if s >= def.stomps then
			best = math.max(best, def.stage)
		end
	end
	return best
end

-- Pips (0..E.PIPS) toward the next stage: one per 20% (Z-16). Max stage: E.PIPS.
function Evolution.pips(stomps: number): number
	local s = n(stomps)
	local stage = Evolution.stageFor(s)
	local nextDef = E.STAGES[stage + 1]
	if not nextDef then
		return E.PIPS
	end
	local from = E.STAGES[stage].stomps
	local frac = (s - from) / math.max(1, nextDef.stomps - from)
	return math.clamp(math.floor(frac * (E.PIPS + 1)), 0, E.PIPS)
end

local function classBlock(profile: Profile, classId: string): any
	local classes = (profile :: any).classes
	return if type(classes) == "table" then classes[classId] else nil
end

function Evolution.classStomps(profile: Profile, classId: string): number
	local st = classBlock(profile, classId)
	return if type(st) == "table" then n(st.stomps) else 0
end

function Evolution.accountStomps(profile: Profile): number
	return n((profile.stats :: any).stomps)
end

export type Added = { stomps: number, stage: number?, unlocked: { string } }

-- Adds a match's stomps to the class and the account. Returns the new evolution stage
-- (only when it went up) and the classes the account total just unlocked for free.
function Evolution.addStomps(profile: Profile, classId: any, amount: number): Added
	local out: Added = { stomps = 0, unlocked = {} }
	local a = math.min(n(amount), 10_000_000)
	if a <= 0 then
		return out
	end
	out.stomps = a
	local sx: any = profile.stats
	sx.stomps = math.min(Evolution.MAX_STOMPS, n(sx.stomps) + a)
	if ClassProgress.isClass(classId) then
		local st: any = ClassProgress.ensure(profile, classId)
		local before = Evolution.stageFor(n(st.stomps))
		st.stomps = math.min(Evolution.MAX_STOMPS, n(st.stomps) + a)
		local after = Evolution.stageFor(st.stomps)
		if after > before then
			out.stage = after
		end
	end
	out.unlocked = Evolution.freeUnlocks(profile)
	return out
end

-- Unlocks (for free) every locked class whose account-stomp threshold is met. Returns
-- the ids unlocked now. Cheese purchase stays available as before.
function Evolution.freeUnlocks(profile: Profile): { string }
	local out = {}
	local total = Evolution.accountStomps(profile)
	for _, u in E.FREE_UNLOCKS do
		if
			total >= u.stomps
			and ClassProgress.isClass(u.classId)
			and not profile.unlockedClasses[u.classId]
		then
			profile.unlockedClasses[u.classId] = true
			ClassProgress.ensure(profile, u.classId)
			table.insert(out, u.classId)
		end
	end
	return out
end

-- Chooses the displayed stage (1..unlocked). Reasons: "bad_class" | "class_locked" | "bad_stage" | "evo_locked"
function Evolution.setEvo(profile: Profile, classId: any, stage: any): (boolean, string?)
	if not ClassProgress.isClass(classId) then
		return false, "bad_class"
	end
	if not profile.unlockedClasses[classId] then
		return false, "class_locked"
	end
	if type(stage) ~= "number" or stage ~= math.floor(stage) or stage < 1 or stage > #E.STAGES then
		return false, "bad_stage"
	end
	local st: any = ClassProgress.ensure(profile, classId)
	if stage > Evolution.stageFor(n(st.stomps)) then
		return false, "evo_locked"
	end
	st.evo = stage
	return true, nil
end

-- Displayed stage (the chosen one if still unlocked, else the highest).
function Evolution.displayStage(profile: Profile, classId: string): number
	local st = classBlock(profile, classId)
	local unlocked = Evolution.stageFor(if type(st) == "table" then n(st.stomps) else 0)
	local chosen = if type(st) == "table" then n(st.evo) else 0
	return if chosen >= 1 and chosen <= unlocked then chosen else unlocked
end

-- Run bonus of the class's highest unlocked stage (cumulative).
function Evolution.bonus(profile: Profile, classId: string): RunBonus.Bonus
	local b = RunBonus.new()
	local stage = Evolution.stageFor(Evolution.classStomps(profile, classId))
	for _, def in E.STAGES do
		if def.stage <= stage then
			RunBonus.add(b, "pctStat", "maxHp", def.maxHpPct or 0)
			RunBonus.add(b, "pve", nil, def.pvePct or 0)
			RunBonus.add(b, "addStat", "xpMult", def.xpPct or 0)
			RunBonus.add(b, "extra", "rindMult", def.rindPct or 0)
		end
	end
	return b
end

-- Lifetime class XP of a saved class block (levels + xp + Mastery Star XP).
function Evolution.lifetimeXp(st: any): number
	if type(st) ~= "table" then
		return 0
	end
	local level = math.clamp(n(st.level), 1, ClassProgress.MAX_LEVEL)
	return ClassProgress.totalXpFor(level) + n(st.xp) + n(st.stars) * ClassProgress.STAR_XP + n(st.starXp)
end

-- Veteran seed (profile v7 migration, Z-6): stomps = floor(1.2 x lifetime class XP)
-- for every class block without stomps; stats.stomps = the sum. Returns the total seeded.
function Evolution.seed(raw: any): number
	if type(raw) ~= "table" or type(raw.classes) ~= "table" then
		return 0
	end
	local total = 0
	for _, st in raw.classes do
		if type(st) == "table" then
			if type(st.stomps) ~= "number" then
				st.stomps = math.floor(E.SEED_PER_XP * Evolution.lifetimeXp(st))
			end
			total += n(st.stomps)
		end
	end
	return total
end

-- Profile view additions: per class {stomps, stage, display, pips, next}; account total;
-- the free-unlock ladder.
function Evolution.view(profile: Profile): { [string]: any }
	local classes = {}
	local cl = (profile :: any).classes
	if type(cl) == "table" then
		for id, st in cl do
			if type(st) == "table" then
				local s = n(st.stomps)
				local stage = Evolution.stageFor(s)
				local nextDef = E.STAGES[stage + 1]
				classes[id] = {
					stomps = s,
					stage = stage,
					display = Evolution.displayStage(profile, id),
					pips = Evolution.pips(s),
					nextStomps = if nextDef then nextDef.stomps else nil,
				}
			end
		end
	end
	local unlocks = {}
	for _, u in E.FREE_UNLOCKS do
		table.insert(unlocks, {
			classId = u.classId,
			stomps = u.stomps,
			unlocked = profile.unlockedClasses[u.classId] == true,
		})
	end
	return { total = Evolution.accountStomps(profile), classes = classes, freeUnlocks = unlocks }
end

return Evolution
