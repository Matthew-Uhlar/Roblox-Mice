--!strict
-- Party vote (route / bank / cycle votes, GDD §3.1). Pure; the 15 s timer
-- lives in RunDirector.
--   * Only listed voters may vote; a voter may change their vote (last wins).
--   * resolve: most votes wins; ties are broken with the rng; no votes at all
--     -> `default` (1 when omitted, i.e. the Low card / Continue / Go Home).
--   * With zero voters allVoted() is true, so the vote can close at once.
--   * removeVoter (extra API) drops a player who left, and their vote.
--   * resolve(rng, default, needsHuman?): options listed in needsHuman (the risky
--     Double or Nothing / Next Cycle) only count if at least one HUMAN voted for
--     them (QC2 M3). Bot votes alone never stake a human's pot. Humans are every
--     voter id that is not Ids.isBot (Studio test players -1..-8 are humans).

local Rng = require("../Util/Rng")
local Ids = require("../Util/Ids")

local Vote = {}
Vote.__index = Vote

type VoteData = {
	optionCount: number,
	voters: { [number]: boolean },
	votes: { [number]: number }, -- voterId -> option
}

export type Vote = typeof(setmetatable({} :: VoteData, Vote))

function Vote.new(optionCount: number, voterIds: { number }): Vote
	assert(type(optionCount) == "number" and optionCount >= 1, "Vote.new: optionCount must be >= 1")
	local voters = {}
	for _, id in voterIds do
		voters[id] = true
	end
	return setmetatable({
		optionCount = math.floor(optionCount),
		voters = voters,
		votes = {},
	}, Vote)
end

function Vote.cast(self: Vote, voterId: number, option: number): boolean
	if not self.voters[voterId] then
		return false
	end
	if type(option) ~= "number" or option ~= option or option % 1 ~= 0 then
		return false
	end
	if option < 1 or option > self.optionCount then
		return false
	end
	self.votes[voterId] = option
	return true
end

function Vote.removeVoter(self: Vote, voterId: number)
	self.voters[voterId] = nil
	self.votes[voterId] = nil
end

function Vote.tally(self: Vote): { [number]: number }
	local counts = {}
	for i = 1, self.optionCount do
		counts[i] = 0
	end
	for _, option in self.votes do
		counts[option] += 1
	end
	return counts
end

function Vote.allVoted(self: Vote): boolean
	for id in self.voters do
		if self.votes[id] == nil then
			return false
		end
	end
	return true
end

-- Human (non-bot) votes for `option`.
function Vote.humanVotes(self: Vote, option: number): number
	local n = 0
	for id, o in self.votes do
		if o == option and not Ids.isBot(id) then
			n += 1
		end
	end
	return n
end

-- Option names that need a human vote to win (RunState bank / cycle options).
Vote.RISKY = table.freeze({ DoubleOrNothing = true, NextCycle = true })

-- Indices of the risky options in an option list (strings; route cards are never risky).
function Vote.riskyIndices(options: { any }): { number }
	local out = {}
	for i, o in options do
		if type(o) == "string" and Vote.RISKY[o] then
			table.insert(out, i)
		end
	end
	return out
end

function Vote.resolve(self: Vote, rng: Rng.Rng, default: number?, needsHuman: { number }?): number
	local fallback = math.clamp(math.floor(default or 1), 1, self.optionCount)
	local counts = self:tally()
	for _, i in needsHuman or {} do
		if counts[i] and self:humanVotes(i) == 0 then
			counts[i] = 0 -- bot-only support does not count
		end
	end
	local best = 0
	local tied: { number } = {}
	for i = 1, self.optionCount do
		local c = counts[i]
		if c > best then
			best = c
			tied = { i }
		elseif c == best and c > 0 then
			table.insert(tied, i)
		end
	end
	if best == 0 then
		return fallback
	end
	if #tied == 1 then
		return tied[1]
	end
	return rng:pick(tied)
end

return Vote
