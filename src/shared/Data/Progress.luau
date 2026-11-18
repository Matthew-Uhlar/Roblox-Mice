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
local Grant = require("./Grant")
local HerdTalents = require("./HerdTalents")
local Evolution = require("./Evolution")
local Charms = require("./Charms")

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
	pressure: number?, -- the run's Pressure points (talent points, stomps, charm tier)
	win: boolean?, -- Data/Award win
	fullClear: boolean?,
	stagesAlive: number?,
	charmDrops: number?, -- boss charms: bosses where the player's squad dealt the most damage
	stageReached: number?, -- for the end-of-match charm chance
	charmSeed: number?, -- the server's random seed for this match's charm rolls
}

export type Summary = {
	passXp: number,
	tiers: number, -- Herd Pass tiers gained
	completed: { string }, -- contract ids completed now
	collected: { { page: string, id: string } },
	achievements: { string },
	stars: number,
	starReward: { [string]: any }?,
	talentPoints: any?, -- (v5) Data/HerdTalents.Award
	stomps: any?, -- (v5) Data/Evolution.Added
	charms: { any }, -- (v5) charms granted {id, type, rarity, tier}
	charmCheese: number, -- (v5) charms salvaged because the inventory was full
	charmWatch: boolean, -- (v5) over the daily grant watch (log it)
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
		charms = {},
		charmCheese = 0,
		charmWatch = false,
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

	-- Mastery Star rewards
	local ca = info.classAward
	if type(ca) == "table" and type(ca.stars) == "number" and ca.stars > 0 then
		sum.stars = ca.stars
		local R = ClassProgress.STAR_REWARD
		sum.starReward =
			Grant.apply(profile, { cheese = R.cheese * ca.stars, goldenCheese = R.goldenCheese * ca.stars })
		merge(sum.given, sum.starReward)
	end

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

	-- (v5) Herd Talent points (account board), stomps, charms
	sum.talentPoints = HerdTalents.award(profile, {
		bosses = info.bosses,
		championKills = info.championKills,
		stagesAlive = info.stagesAlive,
		stagesCleared = cleared,
		extracted = finished,
		win = info.win,
		fullClear = info.fullClear,
		pressure = info.pressure,
	}, info.day)
	local stomps = Evolution.matchStomps(info.mice, info.pressure)
	if stomps > 0 then
		sum.stomps = Evolution.addStomps(profile, info.classId, stomps)
	end
	local seed = if type(info.charmSeed) == "number" and info.charmSeed == info.charmSeed
		then math.floor(info.charmSeed)
		else info.day * 7919 + info.userId
	local rolls = {}
	for i = 1, math.min(num(info.charmDrops), 4) do
		table.insert(rolls, Charms.roll(seed + i * 101, info.pressure, info.stageReached))
	end
	if Charms.matchDrop(seed + 7, info.stageReached) then
		table.insert(rolls, Charms.roll(seed + 13, info.pressure, info.stageReached))
	end
	for _, roll in rolls do
		local ch, cheese, watch = Charms.grant(profile, roll, info.day)
		if ch then
			table.insert(sum.charms, ch)
		end
		sum.charmCheese += cheese
		sum.charmWatch = sum.charmWatch or watch
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

-- Achievements only (after a daily claim, a class unlock, a discovery...).
function Progress.checkAchievements(profile: Profile): { { id: string, given: { [string]: any } } }
	return Achievements.check(profile, addPassXp)
end

return Progress
