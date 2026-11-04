--!strict
-- Pure kill-feed bookkeeping (no Roblox APIs; tested in tests/specs/ClientV2.spec.luau).
--
-- GDD-v2 §2: a hero on a 3-kill streak carries a bounty until someone downs
-- them. The server may also say so explicitly (KillFeed kind = "bounty", or
-- Match.bounties); this module only derives streaks from the kill feed so the
-- bounty marker still works when it doesn't.

local KillStreaks = {}

KillStreaks.THRESHOLD = 3

export type Streaks = { counts: { [string]: number }, bounty: { [string]: boolean } }

function KillStreaks.new(): Streaks
	return { counts = {}, bounty = {} }
end

local function key(id: any): string?
	if id == nil then
		return nil
	end
	return tostring(id)
end

-- Kinds that count towards a streak (a down or a kill of an enemy hero).
local COUNTS: { [string]: boolean } =
	{ kill = true, down = true, downed = true, killed = true, eliminate = true }
-- Kinds that end the victim's streak.
local ENDS: { [string]: boolean } =
	{ kill = true, down = true, downed = true, killed = true, eliminate = true, death = true }

-- Applies one KillFeed entry. Returns the killer key if this entry just
-- started a bounty on them (for a "BOUNTY!" banner), else nil.
function KillStreaks.push(s: Streaks, entry: any): string?
	if type(entry) ~= "table" then
		return nil
	end
	local kind = tostring(entry.kind or "kill")
	local killer, victim = key(entry.killer), key(entry.victim)
	if kind == "bounty" then
		-- Explicit server bounty on `victim` (or `killer` when that's all it sends).
		local who = victim or killer
		if who and not s.bounty[who] then
			s.bounty[who] = true
			return who
		end
		return nil
	end
	if kind == "bountyClaimed" or kind == "bountyEnd" then
		if victim then
			s.bounty[victim] = nil
			s.counts[victim] = 0
		end
		return nil
	end
	if victim and ENDS[kind] then
		s.counts[victim] = 0
		s.bounty[victim] = nil
	end
	-- Friendly fire is off, so same-squad entries are never PvP kills.
	local sameSquad = entry.killerSquad ~= nil and entry.killerSquad == entry.victimSquad
	if killer and killer ~= victim and COUNTS[kind] and not sameSquad then
		local n = (s.counts[killer] or 0) + 1
		s.counts[killer] = n
		if n >= KillStreaks.THRESHOLD and not s.bounty[killer] then
			s.bounty[killer] = true
			return killer
		end
	end
	return nil
end

function KillStreaks.hasBounty(s: Streaks, id: any): boolean
	local k = key(id)
	return k ~= nil and s.bounty[k] == true
end

-- Bounty holders as a list of keys (sorted, for stable rendering).
function KillStreaks.holders(s: Streaks): { string }
	local out = {}
	for k in s.bounty do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

function KillStreaks.reset(s: Streaks)
	table.clear(s.counts)
	table.clear(s.bounty)
end

return KillStreaks
