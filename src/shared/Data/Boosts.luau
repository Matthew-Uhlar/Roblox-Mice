--!strict
-- Pure multiplier maths for MonetizationService (Team D). Bonuses are additive so
-- stacking stays bounded: the maximum is 1 + 0.15 + 0.5 + 0.1 + 1.0 = 2.75x.
-- RunDirector applies cheeseMult to the FINAL banked payout only, never to the
-- Double-or-Nothing pot, so Robux never enters a stake.

local Monetization = require("../Config/Monetization")

local Boosts = {}

export type CheeseParts = {
	herdLeader: boolean?, -- a Herd Leader owner is in the server
	feast: boolean?, -- a Cheese Feast is active on this server
	premium: boolean?, -- Roblox Premium / Plus member
	rush: boolean?, -- personal Cheese Rush active
}

function Boosts.cheeseMult(parts: CheeseParts): number
	local R = Monetization.RULES
	local m = 1
	if parts.herdLeader then
		m += R.herdLeaderBonus
	end
	if parts.feast then
		m += R.feastBonus
	end
	if parts.premium then
		m += R.premiumBonus
	end
	if parts.rush then
		m += R.cheeseRushBonus
	end
	return m
end

function Boosts.xpMult(doubleXp: boolean): number
	return if doubleXp then Monetization.RULES.doubleXpMult else 1
end

-- Extends a timed boost: time stacks, the bonus does not. Result is capped at now + maxStack.
function Boosts.extendUntil(currentUntil: number, now: number, seconds: number, maxStack: number): number
	local base = math.max(currentUntil, now)
	return math.min(base + seconds, now + maxStack)
end

return Boosts
