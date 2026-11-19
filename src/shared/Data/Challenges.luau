--!strict
-- (iteration 2) The 30 Challenges (Team P). Pure. Content: Config/Challenges.
-- profile.challenges = {[id] = true} once done (and rewarded). M2 supplies the match
-- flags and counters (DataService.awardRun stats.challengeFlags); the gem ones are
-- checked from the profile. Rewards: a gem rolled by the caller's seed, Crumb Dust, a
-- title; all 30 add the "Wheel of Legends" title.

local Types = require("../Types")
local C = require("../Config/Challenges")
local Gems = require("./Gems")
local Grant = require("./Grant")

type Profile = Types.Profile

local Challenges = {}

export type Match = {
	tier: number?,
	clear: boolean?,
	solo: boolean?,
	classId: string?,
	lastHerd: boolean?,
	extracted: boolean?,
	extractStage: number?,
	clearSeconds: number?,
	flags: { [string]: any }?,
}

function Challenges.sanitize(raw: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(raw) == "table" then
		for k, x in raw do
			if x == true and C.get(k) then
				out[k] = true
			end
		end
	end
	return out
end

local function done(profile: Profile): { [string]: boolean }
	local p = profile :: any
	if type(p.challenges) ~= "table" then
		p.challenges = {}
	end
	return p.challenges
end

local function n(v: any): number
	return if type(v) == "number" and v == v then v else 0
end

-- Does a match (or nil: profile-only checks) meet a challenge's requirement?
function Challenges.met(profile: Profile, def: C.ChallengeDef, m: Match?): boolean
	local r = def.req
	if r.state then
		local lv, t = Gems.best(profile)
		if r.state == "gemLevel5" then
			return lv >= 5
		elseif r.state == "gemTier11" then
			return t >= 11
		elseif r.state == "gemTier12" then
			return t >= 12
		end
		return false
	end
	if not m then
		return false
	end
	local flags = if type(m.flags) == "table" then m.flags else {}
	if r.clear and m.clear ~= true then
		return false
	end
	if r.minTier and n(m.tier) < r.minTier then
		return false
	end
	if r.solo and m.solo ~= true then
		return false
	end
	if r.classId and m.classId ~= r.classId then
		return false
	end
	if r.lastHerd and m.lastHerd ~= true then
		return false
	end
	if r.extractStage and (m.extracted ~= true or n(m.extractStage) < r.extractStage) then
		return false
	end
	if r.flag and flags[r.flag] ~= true then
		return false
	end
	if r.count and n(flags[r.count[1]]) < r.count[2] then
		return false
	end
	if r.maxMinutes then
		local secs = n(m.clearSeconds)
		if secs <= 0 or secs > r.maxMinutes * 60 then
			return false
		end
	end
	return true
end

export type Done = { id: string, given: { [string]: any }, gemTier: number?, gemUnique: boolean? }

-- Marks every newly met challenge and gives its dust / title. Gem rewards are returned
-- (gemTier, gemUnique) for the caller to roll and grant (it owns the seed).
function Challenges.check(profile: Profile, m: Match?): { Done }
	local d = done(profile)
	local out: { Done } = {}
	for _, def in C.LIST do
		if not d[def.id] and Challenges.met(profile, def, m) then
			d[def.id] = true
			local given = Grant.apply(profile, { title = def.reward.title })
			if def.reward.dust then
				Gems.addDust(profile, def.reward.dust)
				given.dust = def.reward.dust
			end
			table.insert(
				out,
				{ id = def.id, given = given, gemTier = def.reward.gemTier, gemUnique = def.reward.gemUnique }
			)
		end
	end
	local all = true
	for _, def in C.LIST do
		if not d[def.id] then
			all = false
			break
		end
	end
	if all and #out > 0 then
		Grant.apply(profile, { title = C.ALL_TITLE })
	end
	return out
end

function Challenges.view(profile: Profile): { [string]: any }
	local d = done(profile)
	local list = {}
	local count = 0
	for _, def in C.LIST do
		if d[def.id] then
			count += 1
		end
		table.insert(list, {
			id = def.id,
			name = def.name,
			text = def.text,
			done = d[def.id] == true,
			reward = table.clone(def.reward),
		})
	end
	return { list = list, done = count, total = #C.LIST }
end

return Challenges
