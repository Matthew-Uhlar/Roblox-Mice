--!strict
-- (v6) Herd Pass state and rules (Team P). Pure: the caller passes the UTC day and
-- whether the player owns this season's premium game pass. Content: Config/Pass.
--
-- profile.pass = {
--   season: number,             the season this block belongs to
--   xp: number,                 Pass XP this season (0..Config/Pass.MAX_XP)
--   free: {[tier] = true},      claimed free rewards  (keys are tostring(tier))
--   premium: {[tier] = true},   claimed premium rewards
--   premiumOwned: boolean,      premium was active at some point this season
-- }
-- Rollover (sync): when the stored season is older than the current one, every
-- unclaimed reward of a reached tier (premium too, if premiumOwned) is granted, then
-- the block resets for the new season. Upgrading mid-season back-fills: premium
-- rewards of tiers already reached become claimable at once (claim checks the
-- tier reached, never when the pass was bought).

local Types = require("../Types")
local Pass = require("../Config/Pass")
local Grant = require("./Grant")

type Profile = Types.Profile

export type PassState = {
	season: number,
	xp: number,
	free: { [string]: boolean },
	premium: { [string]: boolean },
	premiumOwned: boolean,
}

local HerdPass = {}

function HerdPass.default(season: number?): PassState
	return { season = season or 1, xp = 0, free = {}, premium = {}, premiumOwned = false }
end

local function tierSet(v: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(v) ~= "table" then
		return out
	end
	for k, x in v do
		local t = tonumber(k)
		if x == true and t and t == math.floor(t) and t >= 1 and t <= Pass.TIERS then
			out[tostring(t)] = true
		end
	end
	return out
end

-- Repairs a saved block (never throws).
function HerdPass.sanitize(raw: any): PassState
	local r: { [any]: any } = if type(raw) == "table" then raw else {}
	local season = if type(r.season) == "number"
			and r.season == r.season
			and r.season >= 1
			and r.season < 1e6
		then math.floor(r.season)
		else 1
	local xp = if type(r.xp) == "number" and r.xp == r.xp
		then math.clamp(math.floor(r.xp), 0, Pass.MAX_XP)
		else 0
	return {
		season = season,
		xp = xp,
		free = tierSet(r.free),
		premium = tierSet(r.premium),
		premiumOwned = r.premiumOwned == true,
	}
end

-- The profile's block (created / repaired on first use; no rollover).
function HerdPass.state(profile: Profile): PassState
	local p = profile :: any
	if type(p.pass) ~= "table" or type(p.pass.free) ~= "table" or type(p.pass.premium) ~= "table" then
		p.pass = HerdPass.sanitize(p.pass)
	end
	return p.pass
end

local function grantTier(profile: Profile, reward: any, out: { [string]: any })
	-- Pass rewards never include Pass XP, so no addPassXp here.
	Grant.apply(profile, reward, nil, out)
end

-- Grants every unclaimed reached reward of the stored season. Returns what was given.
local function autoGrant(profile: Profile, st: PassState): { [string]: any }
	local out: { [string]: any } = {}
	local def = Pass.season(st.season)
	local reached = Pass.tierFor(st.xp)
	for tier = 1, reached do
		local k = tostring(tier)
		if def.free[tier] and not st.free[k] then
			st.free[k] = true
			grantTier(profile, def.free[tier], out)
		end
		if st.premiumOwned and def.premium[tier] and not st.premium[k] then
			st.premium[k] = true
			grantTier(profile, def.premium[tier], out)
		end
	end
	return out
end

-- Moves the block to the season of `day`, auto-granting the old season's unclaimed
-- rewards first. Returns (rolledOver, given) — given is nil when nothing was granted.
function HerdPass.sync(profile: Profile, day: number): (boolean, { [string]: any }?)
	local st = HerdPass.state(profile)
	local current = Pass.seasonFor(day)
	if st.season >= current then
		return false, nil
	end
	local given = autoGrant(profile, st)
	local p: any = profile
	p.pass = HerdPass.default(current)
	return true, if next(given) ~= nil then given else nil
end

-- Marks premium active for the stored season (the server verified the game pass).
function HerdPass.setPremium(profile: Profile, owned: boolean): boolean
	local st = HerdPass.state(profile)
	if owned and not st.premiumOwned then
		st.premiumOwned = true
		return true
	end
	return false
end

-- Adds Pass XP (capped at the season maximum). Returns tiers gained.
function HerdPass.addXp(profile: Profile, xp: number): number
	if type(xp) ~= "number" or xp ~= xp or xp <= 0 then
		return 0
	end
	local st = HerdPass.state(profile)
	local before = Pass.tierFor(st.xp)
	st.xp = math.min(Pass.MAX_XP, st.xp + math.floor(math.min(xp, Pass.MAX_XP)))
	return Pass.tierFor(st.xp) - before
end

-- Claims one reward. track = "free" | "premium". `premiumNow` = the server's current
-- ownership check for this season's game pass.
-- Reasons: "bad_track" | "bad_tier" | "not_reached" | "claimed" | "no_reward" | "no_premium"
function HerdPass.claim(profile: Profile, tier: any, track: any, premiumNow: boolean?): (boolean, any)
	if track ~= "free" and track ~= "premium" then
		return false, "bad_track"
	end
	if
		type(tier) ~= "number"
		or tier ~= tier
		or tier ~= math.floor(tier)
		or tier < 1
		or tier > Pass.TIERS
	then
		return false, "bad_tier"
	end
	local st = HerdPass.state(profile)
	if premiumNow then
		st.premiumOwned = true
	end
	if tier > Pass.tierFor(st.xp) then
		return false, "not_reached"
	end
	local def = Pass.season(st.season)
	local reward = (if track == "free" then def.free else def.premium)[tier]
	if not reward then
		return false, "no_reward"
	end
	if track == "premium" and not st.premiumOwned then
		return false, "no_premium"
	end
	local claimed = if track == "free" then st.free else st.premium
	local k = tostring(tier)
	if claimed[k] then
		return false, "claimed"
	end
	claimed[k] = true
	local out: { [string]: any } = {}
	grantTier(profile, reward, out)
	return true, out
end

-- Every claimable reward now (tiers reached, unclaimed). For the UI dot.
function HerdPass.claimable(profile: Profile): number
	local st = HerdPass.state(profile)
	local def = Pass.season(st.season)
	local n = 0
	for tier = 1, Pass.tierFor(st.xp) do
		local k = tostring(tier)
		if def.free[tier] and not st.free[k] then
			n += 1
		end
		if st.premiumOwned and def.premium[tier] and not st.premium[k] then
			n += 1
		end
	end
	return n
end

local function rewardView(r: any): { [string]: any }?
	if type(r) ~= "table" then
		return nil
	end
	return table.clone(r)
end

-- Net.S2C.Pass payload (docs/MONETIZATION.md "Herd Pass view").
function HerdPass.view(profile: Profile, day: number, premiumNow: boolean?): { [string]: any }
	local st = HerdPass.state(profile)
	local def = Pass.season(st.season)
	local _, lastDay = Pass.seasonDays(st.season)
	local tiers = {}
	local reached = Pass.tierFor(st.xp)
	for tier = 1, Pass.TIERS do
		local k = tostring(tier)
		tiers[tier] = {
			tier = tier,
			free = rewardView(def.free[tier]),
			premium = rewardView(def.premium[tier]),
			freeClaimed = st.free[k] == true,
			premiumClaimed = st.premium[k] == true,
			reached = tier <= reached,
		}
	end
	local premiumKey = Pass.premiumKey(st.season)
	return {
		season = st.season,
		name = def.name,
		xp = st.xp,
		tier = reached,
		xpPerTier = Pass.XP_PER_TIER,
		tierXp = st.xp - reached * Pass.XP_PER_TIER, -- progress inside the next tier
		maxTier = Pass.TIERS,
		premium = st.premiumOwned or premiumNow == true,
		premiumKey = premiumKey, -- PromptProduct(premiumKey); nil = premium not sold this season
		daysLeft = math.max(0, lastDay - math.floor(day) + 1),
		claimable = HerdPass.claimable(profile),
		tiers = tiers,
	}
end

return HerdPass
