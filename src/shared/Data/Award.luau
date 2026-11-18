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
-- "first run of the day" doubles cheese up to this bonus. (v4, QC-C M11 cheese
-- inflation) 1,000 -> 500: Herd Contracts and the Herd Pass now pay daily cheese too.
Award.FIRST_RUN_BONUS_CAP = 500
-- (v4 plan) a match counts as a WIN (stats.wins, the wins board) only for the Last
-- Herd or an extraction after at least this many stage clears (QC-C M1).
Award.WIN_MIN_STAGES = 3
Award.FULL_CLEAR_STAGES = 4
Award.PRESSURE_UNLOCK_RUNS = 3 -- (iter 1) runs finished before Pressure can unlock -- stages in one match (MatchState.CONFIG.STAGES)
-- (v4 plan, Rookie Run) the first extraction ever pays this once.
Award.FIRST_EXTRACT_BONUS = table.freeze({ cheese = 500, goldenCheese = 50 })

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
	-- (v6) v4 fields (RunDirector / M2)
	extracted: boolean?, -- extracted or Last Herd (defaults to `won`)
	stagesCleared: number?, -- stage clears this match (defaults to `bosses`)
	fullClear: boolean?, -- cleared all 4 stages (defaults to stagesCleared >= 4 and extracted)
	championKills: number?, -- Mouse Champions killed with squad credit this match
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
	win: boolean, -- (v6) counted as a win (Last Herd, or extracted after 3+ stage clears)
	firstExtractBonus: { cheese: number, goldenCheese: number }?, -- (v6) Rookie Run bonus, once
	bestStage: number?, -- (v6) new best stages cleared in one match (only when it went up)
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

	-- (v6) what this match was: extraction, stages, full clear, win (QC-C M1/B1/B3)
	local lastHerdFlag = r.lastHerd == true or (type(r.lastHerd) == "number" and r.lastHerd > 0)
	local extracted = if r.extracted ~= nil then r.extracted == true else r.won == true
	extracted = extracted or lastHerdFlag
	local cleared = if r.stagesCleared ~= nil then safe(r.stagesCleared, 100) else bosses
	local fullClear = if r.fullClear ~= nil
		then r.fullClear == true
		else extracted and cleared >= Award.FULL_CLEAR_STAGES
	local win = lastHerdFlag or (extracted and cleared >= Award.WIN_MIN_STAGES)
	local champs = safe(r.championKills, 10_000)

	local st = profile.stats
	local sx: any = st
	local firstRun = st.runs == 0
	st.runs += 1
	if win then
		st.wins += 1
	end
	if extracted then
		sx.extractions = clampCurrency((sx.extractions or 0) + 1)
	end
	local prevBest = sx.bestStage or 0
	sx.bestStage = math.max(prevBest, cleared)
	sx.championKills = clampCurrency((sx.championKills or 0) + champs)

	-- (v6) Rookie Run: the first extraction ever pays a one-time bonus.
	local firstExtract = nil
	local px: any = profile
	if extracted and px.firstExtractPaid ~= true then
		px.firstExtractPaid = true
		local B = Award.FIRST_EXTRACT_BONUS
		profile.cheese = clampCurrency(profile.cheese + B.cheese)
		profile.goldenCheese = clampCurrency(profile.goldenCheese + B.goldenCheese)
		firstExtract = { cheese = B.cheese, goldenCheese = B.goldenCheese }
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
		local rx: any = rk
		if win then
			rk.wins += 1
		end
		rx.bestStage = math.max(rx.bestStage or 0, cleared)
		rx.championKills = clampCurrency((rx.championKills or 0) + champs)
		rk.deepestCycle = math.max(rk.deepestCycle, cycle)
		if validTime then
			rk.fastestCycle1 = if rk.fastestCycle1 then math.min(rk.fastestCycle1, t :: number) else t
		end
	end

	-- Pressure (GDD §3.7): the first extraction unlocks the board. The record
	-- (highestCleared) rises only on a FULL 4-stage clear (v4 plan, QC-C B1).
	local anyProfile: any = profile
	local pp = Pressure.sanitizeProfile(anyProfile.pressure)
	-- (iter 1, H5) Rookie Run: Pressure stays hidden before run 3; from run 3 any past
	-- extraction unlocks it (so "Pressure unlocked!" never shows to a rookie).
	local everExtracted = extracted or (sx.extractions or 0) > 0
	local canUnlock = everExtracted and st.runs >= Award.PRESSURE_UNLOCK_RUNS
	local unlockedNow = canUnlock and pp.unlocked ~= true
	if canUnlock then
		pp.unlocked = true
	end
	local wasUnlocked = pp.unlocked == true
	local _, newRecord = Pressure.recordRun(pp, fullClear, r.pressurePoints)
	pp.unlocked = wasUnlocked or canUnlock -- recordRun never unlocks a rookie's board
	profile.pressure = pp

	-- (v5) PvP stats (GDD-v2 §2, §8): hero downs and Last Herd Standing.
	local downs = safe(r.heroDowns, 10_000)
	local lastHerd = if lastHerdFlag then 1 else 0
	local sv: any = st
	sv.heroDowns = Award.clampCurrency((sv.heroDowns or 0) + downs)
	sv.lastHerd = Award.clampCurrency((sv.lastHerd or 0) + lastHerd)
	if r.ranked then
		local rk: any = st.ranked
		rk.heroDowns = Award.clampCurrency((rk.heroDowns or 0) + downs)
		rk.lastHerd = Award.clampCurrency((rk.lastHerd or 0) + lastHerd)
	end

	-- (iter 1, P-2) every finished match pays at least MIN_RUN_XP class XP, and the
	-- first match ever always reaches class level 2.
	local classAward = nil
	if r.classId then
		local cxp = math.max(safe(r.classXp, ClassProgress.MAX_RUN_XP), ClassProgress.MIN_RUN_XP)
		if firstRun then
			local cs = ClassProgress.ensure(profile, r.classId)
			if cs and cs.level <= 1 then
				cxp = math.max(cxp, ClassProgress.xpToNext(1) - cs.xp)
			end
		end
		classAward = ClassProgress.award(profile, r.classId, cxp)
	end

	local lv = Award.addXp(profile, xp)
	return {
		win = win,
		firstExtractBonus = firstExtract,
		bestStage = if cleared > prevBest then cleared else nil,
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
