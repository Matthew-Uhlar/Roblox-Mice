--!strict
-- (v5 / iteration 2) Lifetime Stomps and free class unlocks by stomps (Team P). Pure.
-- Content: Config/Evolutions. (The evolution stages merged into Ascension in iteration 2:
-- Data/Ascension, Config/Ascension.)
--   classes[id].stomps   mice this player stomped with that class (x the tier reward)
--   stats.stomps         account total (Total Stomps leaderboard)

local Types = require("../Types")
local E = require("../Config/Evolutions")
local ClassProgress = require("./ClassProgress")

type Profile = Types.Profile

local Evolution = {}

Evolution.MAX_STOMPS = 1_000_000_000

local function n(v: any): number
	return if type(v) == "number" and v == v and v > 0 and math.abs(v) ~= math.huge then math.floor(v) else 0
end

-- Stomps of one match: mice x the difficulty tier's reward multiplier (Config/Difficulty).
function Evolution.matchStomps(mice: number?, tierReward: number?): number
	local m = math.min(n(mice), 100_000)
	local r = if type(tierReward) == "number"
			and tierReward == tierReward
			and tierReward > 0
		then math.min(tierReward, 10)
		else 1
	return math.floor(m * r)
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

export type Added = { stomps: number, unlocked: { string } }

-- Adds a match's stomps to the class and the account. Returns the classes the account
-- total just unlocked for free.
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
		st.stomps = math.min(Evolution.MAX_STOMPS, n(st.stomps) + a)
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

-- Lifetime class XP of a saved v6 class block (levels + xp + Mastery Star XP).
function Evolution.lifetimeXp(st: any): number
	if type(st) ~= "table" then
		return 0
	end
	local level = math.clamp(n(st.level), 1, ClassProgress.MAX_LEVEL)
	-- a v6 save: its level and xp are on the legacy curve; one Mastery Star = 12,000 XP
	return ClassProgress.legacyTotalXpFor(level)
		+ n(st.xp)
		+ n(st.stars) * ClassProgress.PRESTIGE_XP
		+ n(st.starXp)
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

-- Profile view `stomps`: account total, per class, and the free-unlock ladder.
function Evolution.view(profile: Profile): { [string]: any }
	local classes = {}
	local cl = (profile :: any).classes
	if type(cl) == "table" then
		for id, st in cl do
			if type(st) == "table" then
				classes[id] = n(st.stomps)
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
