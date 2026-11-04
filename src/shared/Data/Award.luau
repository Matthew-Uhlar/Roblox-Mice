--!strict
-- Pure end-of-run award + account levelling (Team D). DataService.awardRun wraps it.
-- Time/day numbers are passed in; nothing here reads a clock.

local Types = require("../Types")
local Cosmetics = require("../Config/Cosmetics")
local Pressure = require("../Run/Pressure")
local ClassProgress = require("./ClassProgress")

type Profile = Types.Profile

local Award = {}

Award.MAX_LEVEL = 100
Award.MAX_CURRENCY = 1_000_000_000
Award.FIRST_RUN_BONUS_CAP = 1000 -- "first run of the day" doubles cheese up to this bonus

-- Account XP needed to go from `level` to level + 1.
function Award.xpToNext(level: number): number
	return 200 + 50 * (math.max(1, level) - 1)
end

local function clampCurrency(n: number): number
	if n ~= n then
		return 0
	end
	return math.clamp(math.floor(n), 0, Award.MAX_CURRENCY)
end
Award.clampCurrency = clampCurrency

-- Adds account XP, levels up and grants level cosmetics.
function Award.addXp(profile: Profile, amount: number): { levelsGained: number, cosmetics: { string } }
	local gained = 0
	local unlocked: { string } = {}
	if amount ~= amount or amount <= 0 then
		return { levelsGained = 0, cosmetics = unlocked }
	end
	profile.xp = clampCurrency(profile.xp + amount)
	while profile.level < Award.MAX_LEVEL and profile.xp >= Award.xpToNext(profile.level) do
		profile.xp -= Award.xpToNext(profile.level)
		profile.level += 1
		gained += 1
		for _, id in Cosmetics.forLevel(profile.level) do
			if not profile.cosmetics[id] then
				profile.cosmetics[id] = true
				table.insert(unlocked, id)
			end
		end
	end
	if profile.level >= Award.MAX_LEVEL then
		profile.xp = math.min(profile.xp, Award.xpToNext(Award.MAX_LEVEL))
	end
	return { levelsGained = gained, cosmetics = unlocked }
end

export type RunAward = {
	cheese: number, -- already multiplied by MonetizationService.cheeseMult (final banked payout)
	xp: number, -- already multiplied by the account XP multiplier
	won: boolean,
	cycle: number, -- deepest cycle reached this run
	bosses: number,
	cycle1Time: number?, -- seconds, only when cycle 1 was cleared
	ranked: boolean, -- false when a Second Wind token was used
	day: number?, -- UTC day number, enables the first-run-of-the-day bonus
	pressurePoints: number?, -- the run's Pressure points (RunState:pressurePoints())
	-- (v5, GDD-v2 §5) class progression and PvP stats
	classId: string?, -- the class played this run
	classXp: number?, -- class XP (Data/ClassProgress.runXp), never Robux-multiplied
	heroDowns: number?, -- enemy heroes this player downed
	lastHerd: (boolean | number)?, -- the player's squad was the Last Herd Standing
}

export type RunAwardResult = {
	cheese: number,
	firstRunBonus: number,
	xp: number,
	levelsGained: number,
	cosmetics: { string },
	pressureUnlocked: boolean, -- this win unlocked the Pressure board
	pressureRecord: number?, -- new highest Pressure cleared (set only when it went up)
	class: ClassProgress.ClassAward?, -- (v5) class XP, levels and unlocks
}

local function safe(n: any, max: number): number
	if type(n) ~= "number" or n ~= n then
		return 0
	end
	return math.clamp(math.floor(n), 0, max)
end

function Award.applyRun(profile: Profile, r: RunAward): RunAwardResult
	local cheese = safe(r.cheese, Award.MAX_CURRENCY)
	local xp = safe(r.xp, Award.MAX_CURRENCY)
	local cycle = safe(r.cycle, 10_000)
	local bosses = safe(r.bosses, 10_000)

	local bonus = 0
	if r.day and cheese > 0 and profile.firstRunDay ~= r.day then
		bonus = math.min(cheese, Award.FIRST_RUN_BONUS_CAP)
		profile.firstRunDay = r.day
	end
	profile.cheese = clampCurrency(profile.cheese + cheese + bonus)
	profile.lastRun = { cheese = cheese, adClaimed = false }

	local st = profile.stats
	st.runs += 1
	if r.won then
		st.wins += 1
	end
	st.deepestCycle = math.max(st.deepestCycle, cycle)
	st.bossesKilled += bosses
	local t = r.cycle1Time
	local validTime = type(t) == "number" and t == t and t > 0 and t < 1e6
	if validTime then
		st.fastestCycle1 = if st.fastestCycle1 then math.min(st.fastestCycle1, t :: number) else t
	end
	if r.ranked then
		local rk = st.ranked
		if r.won then
			rk.wins += 1
		end
		rk.deepestCycle = math.max(rk.deepestCycle, cycle)
		if validTime then
			rk.fastestCycle1 = if rk.fastestCycle1 then math.min(rk.fastestCycle1, t :: number) else t
		end
	end

	-- Pressure (GDD §3.7): only a win (Go Home) counts. The first one unlocks
	-- the board; the run's points raise highestCleared.
	local anyProfile: any = profile
	local pp = Pressure.sanitizeProfile(anyProfile.pressure)
	local unlockedNow, newRecord = Pressure.recordRun(pp, r.won == true, r.pressurePoints)
	profile.pressure = pp

	-- (v5) PvP stats (GDD-v2 §2, §8): hero downs and Last Herd Standing.
	local downs = safe(r.heroDowns, 10_000)
	local lastHerd = if r.lastHerd == true then 1 else safe(r.lastHerd, 1)
	local sv: any = st
	sv.heroDowns = Award.clampCurrency((sv.heroDowns or 0) + downs)
	sv.lastHerd = Award.clampCurrency((sv.lastHerd or 0) + lastHerd)
	if r.ranked then
		local rk: any = st.ranked
		rk.heroDowns = Award.clampCurrency((rk.heroDowns or 0) + downs)
		rk.lastHerd = Award.clampCurrency((rk.lastHerd or 0) + lastHerd)
	end

	local classAward = if r.classId then ClassProgress.award(profile, r.classId, safe(r.classXp, ClassProgress.MAX_RUN_XP)) else nil

	local lv = Award.addXp(profile, xp)
	return {
		class = classAward,
		pressureUnlocked = unlockedNow,
		pressureRecord = if newRecord then pp.highestCleared else nil,
		cheese = cheese + bonus,
		firstRunBonus = bonus,
		xp = xp,
		levelsGained = lv.levelsGained,
		cosmetics = lv.cosmetics,
	}
end

return Award
