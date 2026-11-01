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

-- How many whole minutes until `seconds` more would fit (at least 1).
function Boosts.minutesUntilFits(overSeconds: number): number
	return math.max(1, math.ceil(overSeconds / 60))
end

function Boosts.xpMult(doubleXp: boolean): number
	return if doubleXp then Monetization.RULES.doubleXpMult else 1
end

-- Extends a timed boost: time stacks, the bonus does not. Result is capped at now + maxStack.
function Boosts.extendUntil(currentUntil: number, now: number, seconds: number, maxStack: number): number
	local base = math.max(currentUntil, now)
	return math.min(base + seconds, now + maxStack)
end

export type Extension = {
	untilT: number, -- new end time
	applied: number, -- seconds actually added
	lost: number, -- seconds cut off by the cap (0 when it all fits)
}

-- Like extendUntil, but also says how much of `seconds` the cap swallowed.
function Boosts.extend(currentUntil: number, now: number, seconds: number, maxStack: number): Extension
	local base = math.max(currentUntil, now)
	local untilT = math.max(base, math.min(base + seconds, now + maxStack))
	local applied = untilT - base
	return { untilT = untilT, applied = applied, lost = math.max(0, seconds - applied) }
end

-- Whether a whole `seconds` extension fits under the cap right now. When it does
-- not, the second value is how long until it would (for the "try again in" toast).
-- `queued` is boost time already bought but not started yet (pending Feasts).
function Boosts.fits(
	currentUntil: number,
	now: number,
	seconds: number,
	maxStack: number,
	queued: number?
): (boolean, number)
	local base = math.max(currentUntil, now) + math.max(0, queued or 0)
	local over = base + seconds - (now + maxStack)
	if over <= 0 then
		return true, 0
	end
	return false, over
end

-- Golden Cheese refunded for boost time the cap cut off: pro rata against the
-- price of one full unit (`unitGolden` per `unitSeconds`), rounded up so any
-- loss refunds at least 1. Disclosed in the product's benefit text.
function Boosts.overflowRefund(lostSeconds: number, unitSeconds: number, unitGolden: number): number
	if lostSeconds ~= lostSeconds or lostSeconds <= 0 or unitSeconds <= 0 or unitGolden <= 0 then
		return 0
	end
	return math.ceil(lostSeconds / unitSeconds * unitGolden - 1e-9)
end

return Boosts
