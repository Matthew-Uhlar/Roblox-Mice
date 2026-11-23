--!strict
-- Run/LobbyVote (iteration 6, owner request): with 2+ humans in the lobby, every
-- player votes the match's difficulty tier (C2S.SetTier = "my vote") and pace
-- (C2S.SetPace). Pure; LobbyService validates each vote against the voter's own
-- unlocks (rookie rules kept) before it is counted here.
--
--   * tier: most votes wins; a tie goes to the LOWER tier (Custom = 0 counts as
--     the highest for the tie-break: a tie never picks the leader's board over a
--     real tier); no votes -> `fallback` (the leader's saved tier, as before).
--   * pace: most votes wins; a tie -> "normal"; no votes -> `fallback`.
--   * A leaver's vote is simply gone (the caller drops it with the entry).
-- Solo lobbies don't vote: LobbyService keeps the single player's pick as before.

local LobbyVote = {}

LobbyVote.MIN_PLAYERS = 2 -- humans in the lobby for the vote to apply
LobbyVote.PACE_TIE = "normal"

export type Result = {
	winner: any,
	tallies: { [string]: number }, -- tostring(option) -> votes
	votes: number, -- counted votes
	tie: boolean, -- the winner came from a tie-break
}

local function tierRank(t: number): number
	return if t == 0 then math.huge else t -- Custom loses every tie
end

-- Counts `votes` ({[voterKey] = option}); `valid(option)` filters (optional).
local function tally(
	votes: { [any]: any },
	valid: ((any) -> boolean)?
): ({ [string]: number }, { any }, number)
	local counts: { [string]: number } = {}
	local options: { any } = {}
	local n = 0
	for _, v in votes do
		if v ~= nil and (valid == nil or valid(v)) then
			local k = tostring(v)
			if counts[k] == nil then
				counts[k] = 0
				table.insert(options, v)
			end
			counts[k] += 1
			n += 1
		end
	end
	return counts, options, n
end

-- The match tier from tier votes. `fallback` when nobody voted.
function LobbyVote.tier(votes: { [any]: number }, fallback: number): Result
	local counts, options, n = tally(votes, function(v: any): boolean
		return type(v) == "number" and v == v and v % 1 == 0 and v >= 0
	end)
	if n == 0 then
		return { winner = fallback, tallies = counts, votes = 0, tie = false }
	end
	local best, bestN, tie = nil, -1, false
	for _, t in options do
		local c = counts[tostring(t)]
		if c > bestN then
			best, bestN, tie = t, c, false
		elseif c == bestN then
			tie = true
			if tierRank(t) < tierRank(best :: number) then
				best = t
			end
		end
	end
	return { winner = best, tallies = counts, votes = n, tie = tie }
end

-- The match pace from pace votes ("normal" | "fast"). `fallback` when nobody voted.
function LobbyVote.pace(votes: { [any]: string }, fallback: string, valid: ((any) -> boolean)?): Result
	local counts, options, n = tally(votes, valid or function(v: any): boolean
		return type(v) == "string"
	end)
	if n == 0 then
		return { winner = fallback, tallies = counts, votes = 0, tie = false }
	end
	local best, bestN, tie = nil, -1, false
	for _, p in options do
		local c = counts[p]
		if c > bestN then
			best, bestN, tie = p, c, false
		elseif c == bestN then
			tie = true
		end
	end
	if tie then
		-- a tie on the top count goes to normal when normal is among the leaders
		local top = 0
		for _, c in counts do
			top = math.max(top, c)
		end
		if (counts[LobbyVote.PACE_TIE] or 0) == top then
			best = LobbyVote.PACE_TIE
		end
	end
	return { winner = best, tallies = counts, votes = n, tie = tie }
end

return LobbyVote
