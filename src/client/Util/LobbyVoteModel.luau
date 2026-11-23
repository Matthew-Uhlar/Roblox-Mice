--!strict
-- Util/LobbyVoteModel (iteration 6, team Lobby): pure helpers for the lobby vote
-- and the start countdown, read from the S2C Lobby payload (Lune-tested).
--
-- Lobby payload (LobbyService.broadcast), iteration 6:
--   countdown      seconds left (ceil) while a start countdown runs, else nil
--   countdownKind  "ready" (60 s from the first Ready) | "all" (everyone ready: starting)
--   vote           nil in a solo lobby; with 2+ humans:
--                  { tier, pace (the winners), tierTallies = {[tostring(tier)] = n},
--                    paceTallies = {normal = n, fast = n}, tierVotes, paceVotes,
--                    yourTier?, yourPace? }
--   players[id].tierVote / paceVote   each human's valid vote (vote mode only)

local LobbyVoteModel = {}

function LobbyVoteModel.vote(lobby: any): any?
	if type(lobby) == "table" and type(lobby.vote) == "table" then
		return lobby.vote
	end
	return nil
end

function LobbyVoteModel.isVoting(lobby: any): boolean
	return LobbyVoteModel.vote(lobby) ~= nil
end

-- Votes for `tier` (0 = Custom).
function LobbyVoteModel.tierCount(lobby: any, tier: number): number
	local v = LobbyVoteModel.vote(lobby)
	local t = v and v.tierTallies
	return if type(t) == "table" then tonumber(t[tostring(tier)]) or 0 else 0
end

function LobbyVoteModel.paceCount(lobby: any, pace: string): number
	local v = LobbyVoteModel.vote(lobby)
	local t = v and v.paceTallies
	return if type(t) == "table" then tonumber(t[pace]) or 0 else 0
end

-- The winning tier / pace (nil outside vote mode).
function LobbyVoteModel.winningTier(lobby: any): number?
	local v = LobbyVoteModel.vote(lobby)
	return if v and type(v.tier) == "number" then v.tier else nil
end

function LobbyVoteModel.winningPace(lobby: any): string?
	local v = LobbyVoteModel.vote(lobby)
	return if v and type(v.pace) == "string" then v.pace else nil
end

function LobbyVoteModel.yourTier(lobby: any): number?
	local v = LobbyVoteModel.vote(lobby)
	return if v and type(v.yourTier) == "number" then v.yourTier else nil
end

-- " · 🗳 T3 ⚡" for a player row (empty when the player has not voted).
function LobbyVoteModel.playerTag(entry: any): string
	if type(entry) ~= "table" then
		return ""
	end
	local parts = {}
	if type(entry.tierVote) == "number" then
		table.insert(parts, if entry.tierVote == 0 then "⚙" else "T" .. entry.tierVote)
	end
	if entry.paceVote == "fast" then
		table.insert(parts, "⚡")
	elseif entry.paceVote == "normal" then
		table.insert(parts, "🐢")
	end
	return if #parts > 0 then " · 🗳 " .. table.concat(parts, " ") else ""
end

-- "(2 votes)" / "(1 vote)" / "".
function LobbyVoteModel.countLabel(n: number): string
	if n <= 0 then
		return ""
	end
	return string.format("(%d vote%s)", n, if n == 1 then "" else "s")
end

-- The headline while a start countdown runs: "All ready, starting!" or
-- "Starting in 0:59"; nil when nothing counts down.
function LobbyVoteModel.countdownText(lobby: any, now: number): string?
	if type(lobby) ~= "table" then
		return nil
	end
	local startsAt = tonumber(lobby.startsAt)
	if lobby.countdownKind == "all" and startsAt ~= nil then
		return "All ready, starting!"
	end
	if startsAt == nil or startsAt <= now then
		return nil
	end
	local s = math.max(0, math.ceil(startsAt - now))
	return string.format("Starting in %d:%02d", s // 60, s % 60)
end

return LobbyVoteModel
