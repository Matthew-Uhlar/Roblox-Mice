--!strict
-- (v6) Account progression around a match (Team P). Pure: the caller passes the UTC
-- day and the userId. DataService calls these inside DataService.update.
--
--   sync(profile, day, userId)            day/week/season rollover (auto-grants finished work)
--   afterRun(profile, info)               after Data/Award.applyRun: Pass XP, contract
--                                         progress, Mastery Star rewards, Mousepedia, achievements
--   event(profile, kind, n, key?, ctx)    live contract progress (Config/Quests.LIVE_KINDS)
--   collect(profile, page, id, ctx)       one Mousepedia entry (+ achievements)
-- Every function returns a summary for toasts; nothing here reads a clock.

local Types = require("../Types")
local Q = require("../Config/Quests")
local Pass = require("../Config/Pass")
local ClassProgress = require("./ClassProgress")
local Quests = require("./Quests")
local HerdPass = require("./HerdPass")
local Achievements = require("./Achievements")
local Gems = require("./Gems")
local Ladder = require("./Ladder")
local Challenges = require("./Challenges")
local GemConfig = require("../Config/Gems")
local Difficulty = require("../Config/Difficulty")
local Evolution = require("./Evolution")

type Profile = Types.Profile

export type Ctx = { day: number, userId: number }

export type RunInfo = Ctx & {
	classId: string?,
	stagesCleared: number?,
	stagesSurvived: number?,
	extracted: boolean?, -- extracted or Last Herd
	championKills: number?,
	bosses: number?,
	pois: number?,
	banked: number?, -- cheese banked this match BEFORE Robux multipliers
	bossIds: { string }?, -- Mousepedia (Config/Collection pages)
	championIds: { string }?,
	mapIds: { string }?,
	classAward: any?, -- Data/ClassProgress.ClassAward of this match
	-- (v5) long-term progression
	mice: number?, -- mice this player stomped (stomps)
	pressure: number?, -- the run's Pressure points (unused since iteration 2; `tier` is used)
	win: boolean?, -- Data/Award win
	fullClear: boolean?,
	stagesAlive: number?,
	stageReached: number?,
	-- (iteration 2) the difficulty ladder, gems and challenges
	tier: number?, -- Config/Difficulty tier of the match (default Medium)
	clear: boolean?, -- full clear or Last Herd (unlocks the next tier)
	solo: boolean?, -- the only human in the server
	ranked: boolean?,
	clearSeconds: number?,
	extractStage: number?, -- the stage the squad extracted at
	lastHerd: boolean?,
	challengeFlags: { [string]: any }?, -- M2's match flags and counters (Config/Challenges)
	gemSeed: number?, -- the server's random seed for this match's gem rolls
}

export type Summary = {
	passXp: number,
	tiers: number, -- Herd Pass tiers gained
	completed: { string }, -- contract ids completed now
	collected: { { page: string, id: string } },
	achievements: { string },
	stars: number,
	starReward: { [string]: any }?,
	ladder: any?, -- (iteration 2) Data/Ladder.Result
	stomps: any?, -- (v5) Data/Evolution.Added
	gems: { any }, -- (iteration 2) gems granted (Data/Gems.Gem)
	gemDust: number, -- gems turned into dust because the bag was full
	gemWatch: boolean, -- over the daily grant watch (log it)
	challenges: { string }, -- challenges completed now
	given: { [string]: any }, -- currencies / items given by everything above (not the match payout)
}

local Progress = {}

local function addPassXp(profile: Profile, xp: number)
	HerdPass.addXp(profile, xp)
end
Progress.addPassXp = addPassXp

local function newSummary(): Summary
	return {
		passXp = 0,
		tiers = 0,
		completed = {},
		collected = {},
		achievements = {},
		stars = 0,
		given = {},
		gems = {},
		gemDust = 0,
		gemWatch = false,
		challenges = {},
	}
end

local function merge(into: { [string]: any }, from: { [string]: any }?)
	if type(from) ~= "table" then
		return
	end
	for k, v in from do
		if type(v) == "number" then
			into[k] = (into[k] or 0) + v
		elseif type(v) == "table" then
			into[k] = into[k] or {}
			for _, x in v do
				table.insert(into[k], x)
			end
		end
	end
end

local function passXp(profile: Profile, sum: Summary, xp: number)
	if xp > 0 then
		sum.tiers += HerdPass.addXp(profile, xp)
		sum.passXp += xp
	end
end

-- Rollover. Returns (questsAutoGranted?, passAutoGranted?).
function Progress.sync(profile: Profile, day: number, userId: number): (any, any)
	local _, passGiven = HerdPass.sync(profile, day)
	local _, questGiven = Quests.sync(profile, day, userId, addPassXp)
	return questGiven, passGiven
end

local function collectInto(profile: Profile, sum: Summary, page: string, id: any)
	local isNew, given = Achievements.collect(profile, page, id, addPassXp)
	if isNew then
		table.insert(sum.collected, { page = page, id = id })
		merge(sum.given, given)
		if given and given.passXp then
			sum.passXp += given.passXp
		end
	end
end

local function checkAchievements(profile: Profile, sum: Summary)
	for _, a in Achievements.check(profile, addPassXp) do
		table.insert(sum.achievements, a.id)
		merge(sum.given, a.given)
	end
end

local function questEvent(profile: Profile, sum: Summary, kind: string, n: number?, key: string?)
	for _, id in Quests.progress(profile, kind, n, key) do
		table.insert(sum.completed, id)
	end
end

function Progress.afterRun(profile: Profile, info: RunInfo): Summary
	local sum = newSummary()
	Progress.sync(profile, info.day, info.userId)
	local function num(v: any): number
		return if type(v) == "number" and v == v and v > 0 then math.floor(math.min(v, 1e9)) else 0
	end
	local cleared = num(info.stagesCleared)
	local survived = math.max(num(info.stagesSurvived), cleared)
	local finished = info.extracted == true

	-- Herd Pass XP for the match
	local before = HerdPass.state(profile).xp
	passXp(profile, sum, Pass.runXp(survived, finished))

	-- Herd Contracts (run kinds; see Config/Quests)
	questEvent(profile, sum, "match", 1)
	questEvent(profile, sum, "stage", cleared)
	questEvent(profile, sum, "clearMax", cleared)
	if finished then
		questEvent(profile, sum, "extract", 1)
	end
	questEvent(profile, sum, "boss", num(info.bosses))
	questEvent(profile, sum, "champion", num(info.championKills))
	questEvent(profile, sum, "pois", num(info.pois))
	questEvent(profile, sum, "bank", num(info.banked))
	if type(info.classId) == "string" and ClassProgress.isClass(info.classId) then
		questEvent(profile, sum, "classRun", 1, info.classId)
	end

	-- (iteration 2) Mastery Stars became Prestige: its reward is paid by the Prestige
	-- action (ClassProgress.doPrestige), never here.

	-- Mousepedia
	for _, id in info.bossIds or {} do
		collectInto(profile, sum, "bosses", id)
	end
	for _, id in info.championIds or {} do
		collectInto(profile, sum, "champions", id)
	end
	for _, id in info.mapIds or {} do
		collectInto(profile, sum, "maps", id)
	end
	local cls = Achievements.collectClasses(profile, addPassXp)
	if cls then
		merge(sum.given, cls)
		if cls.passXp then
			sum.passXp += cls.passXp
		end
	end

	-- (iteration 2) stomps x the tier reward, ladder records, gems, challenges
	local tierDef = Difficulty.get(info.tier)
	local stomps = Evolution.matchStomps(info.mice, tierDef.reward)
	if stomps > 0 then
		sum.stomps = Evolution.addStomps(profile, info.classId, stomps)
	end
	local clear = info.clear == true or info.fullClear == true or info.lastHerd == true
	sum.ladder = Ladder.record(profile, {
		tier = tierDef.tier,
		clear = clear,
		solo = info.solo,
		ranked = info.ranked,
		classId = info.classId,
		clearSeconds = info.clearSeconds,
		extracted = finished,
		extractStage = info.extractStage,
		day = info.day,
	})
	local seed = if type(info.gemSeed) == "number" and info.gemSeed == info.gemSeed
		then math.floor(info.gemSeed)
		else info.day * 7919 + info.userId
	local rolls = {}
	-- the first clear of a tier each UTC week: a guaranteed gem of that tier
	if sum.ladder.weeklyGem then
		table.insert(rolls, Gems.roll(seed + 1, sum.ladder.weeklyGem))
	end
	-- extracting at stage >= 2: 50% chance of a gem at tier - 1
	local exStage = num(info.extractStage)
	if finished and exStage >= GemConfig.DROP.extractStage and tierDef.gemTier > 1 then
		local Rng = require("../Util/Rng")
		if Rng.new(seed + 3):nextFloat() < GemConfig.DROP.extract then
			table.insert(rolls, Gems.roll(seed + 5, tierDef.gemTier - 1))
		end
	end
	-- challenges (match ones now; their gem rewards are rolled here)
	local done = Challenges.check(profile, {
		tier = tierDef.tier,
		clear = clear,
		solo = info.solo,
		classId = info.classId,
		lastHerd = info.lastHerd,
		extracted = finished,
		extractStage = info.extractStage,
		clearSeconds = info.clearSeconds,
		flags = info.challengeFlags,
	})
	for k, ch in done do
		table.insert(sum.challenges, ch.id)
		merge(sum.given, ch.given)
		if ch.gemTier then
			table.insert(rolls, Gems.roll(seed + 100 + k, ch.gemTier, { unique = ch.gemUnique }))
		end
	end
	for _, roll in rolls do
		local g, dust, watch = Gems.grant(profile, roll, info.day)
		if g then
			table.insert(sum.gems, g)
		end
		sum.gemDust += dust
		sum.gemWatch = sum.gemWatch or watch
	end
	-- gem challenges (a tier-11 gem just dropped, ...)
	for _, ch in Challenges.check(profile, nil) do
		table.insert(sum.challenges, ch.id)
		merge(sum.given, ch.given)
	end

	checkAchievements(profile, sum)
	-- tiers gained over everything above (contract XP is added on claim, not here)
	local Passx = HerdPass.state(profile).xp
	sum.tiers = Pass.tierFor(Passx) - Pass.tierFor(before)
	return sum
end

-- Live contract progress from game code. Unknown or run-only kinds are ignored, so
-- nothing is counted twice. Returns the contract ids completed now.
function Progress.event(profile: Profile, kind: any, n: any, ctx: Ctx): { string }
	if type(kind) ~= "string" or not Q.LIVE_KINDS[kind] then
		return {}
	end
	Progress.sync(profile, ctx.day, ctx.userId)
	return Quests.progress(profile, kind, n)
end

-- (iteration 2) One gem drop (M2: bosses, the final boss, lairs). Rolls `chance` and the
-- gem with `seed`. Returns (gem?, dustInstead, watch, challenges completed).
function Progress.dropGem(
	profile: Profile,
	seed: number,
	tier: number,
	chance: number?,
	opts: { high: boolean?, unique: boolean? }?,
	day: number
): (any, number, boolean, { string })
	local Rng = require("../Util/Rng")
	local c = if type(chance) == "number" and chance == chance then chance else 1
	if c < 1 and Rng.new(seed):nextFloat() >= c then
		return nil, 0, false, {}
	end
	local g, dust, watch = Gems.grant(profile, Gems.roll(seed + 1, tier, opts), day)
	local ids = {}
	for _, ch in Challenges.check(profile, nil) do
		table.insert(ids, ch.id)
	end
	return g, dust, watch, ids
end

-- One Mousepedia entry from game code. Returns the summary (nil when not new).
function Progress.collect(profile: Profile, page: any, id: any, ctx: Ctx): Summary?
	local sum = newSummary()
	Progress.sync(profile, ctx.day, ctx.userId)
	collectInto(profile, sum, page, id)
	if #sum.collected == 0 then
		return nil
	end
	checkAchievements(profile, sum)
	return sum
end

-- (iteration 2) Profile-only challenges (gem upgrades, gem tiers). Returns the ids done now.
function Progress.checkChallenges(profile: Profile): { string }
	local ids = {}
	for _, ch in Challenges.check(profile, nil) do
		table.insert(ids, ch.id)
	end
	return ids
end

-- Achievements only (after a daily claim, a class unlock, a discovery...).
function Progress.checkAchievements(profile: Profile): { { id: string, given: { [string]: any } } }
	return Achievements.check(profile, addPassXp)
end

return Progress
