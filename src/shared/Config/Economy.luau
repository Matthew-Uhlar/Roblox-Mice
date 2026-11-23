--!strict
-- Config/Economy (iteration 6, team Flow; owner decision "slower and pricier"): the
-- cheese grind. Pure data + helpers.
--
--   EARN_MULT        x every EARNED cheese source: run payouts (incl. secured cheese,
--                    Overtime waves, the first-run-of-the-day bonus), the first-extraction
--                    bonus, contracts / weekly quests, the daily streak, achievements,
--                    Mousepedia, account level rewards, prestige / ascension rewards and
--                    the Herd Pass FREE track. Never Robux (products, Golden Cheese), never
--                    the Cheese Rush / Cheese Feast multipliers (they still apply on top,
--                    unchanged), never existing balances.
--   ROOKIE_RUNS      runs 0..ROOKIE_RUNS-1 (the Rookie Run) are paid at x1: a new player's
--                    first runs still unlock their first Herd Upgrades and classes as before.
--   UPPER_PRICE_MULT the upper half of each Herd Upgrade (talent) track and every class
--                    unlock above the cheapest paid tier cost this much more (applied to the
--                    literals in Config/Talents and Config/Classes; cosmetics unchanged).

local Economy = {}

Economy.EARN_MULT = 0.6
Economy.ROOKIE_RUNS = 3
Economy.UPPER_PRICE_MULT = 1.5

-- A config cheese amount at the new rate, rounded to 5 (100 -> 60, 150 -> 90, 300 -> 180).
function Economy.cheese(amount: number): number
	return math.floor(amount * Economy.EARN_MULT / 5 + 0.5) * 5
end

-- The run-payout multiplier for a player with `runs` finished runs (nil = a veteran).
function Economy.runMult(runs: number?): number
	if type(runs) == "number" and runs == runs and runs < Economy.ROOKIE_RUNS then
		return 1
	end
	return Economy.EARN_MULT
end

return Economy
