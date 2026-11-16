--!strict
-- (v6) Account level rewards (Team P). Pure. Content: Config/AccountRewards.
-- profile.accountRewards = {[tostring(level)] = true} for claimed levels.

local Types = require("../Types")
local Config = require("../Config/AccountRewards")
local Grant = require("./Grant")

type Profile = Types.Profile

local AccountRewards = {}

function AccountRewards.sanitize(raw: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(raw) ~= "table" then
		return out
	end
	for k, x in raw do
		local lvl = tonumber(k)
		if x == true and lvl and Config.get(lvl) then
			out[tostring(lvl)] = true
		end
	end
	return out
end

local function claimed(profile: Profile): { [string]: boolean }
	local p = profile :: any
	if type(p.accountRewards) ~= "table" then
		p.accountRewards = {}
	end
	return p.accountRewards
end

-- Reasons: "bad_level" | "not_reached" | "claimed"
function AccountRewards.claim(profile: Profile, level: any): (boolean, any)
	local reward = Config.get(level)
	if not reward then
		return false, "bad_level"
	end
	if profile.level < level then
		return false, "not_reached"
	end
	local c = claimed(profile)
	local k = tostring(level)
	if c[k] then
		return false, "claimed"
	end
	c[k] = true
	return true, Grant.apply(profile, reward)
end

function AccountRewards.claimable(profile: Profile): number
	local c = claimed(profile)
	local n = 0
	for _, lvl in Config.levels() do
		if lvl <= profile.level and not c[tostring(lvl)] then
			n += 1
		end
	end
	return n
end

-- For the profile view: [{level, reward, claimed, reached}].
function AccountRewards.view(profile: Profile): { { [string]: any } }
	local c = claimed(profile)
	local out = {}
	for _, lvl in Config.levels() do
		table.insert(out, {
			level = lvl,
			reward = table.clone(Config.REWARDS[lvl]),
			claimed = c[tostring(lvl)] == true,
			reached = lvl <= profile.level,
		})
	end
	return out
end

return AccountRewards
