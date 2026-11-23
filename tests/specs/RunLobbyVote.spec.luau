--!strict
-- Run/LobbyVote (iteration 6): the lobby's tier and pace votes; plus the client's
-- Util/LobbyVoteModel (tallies, player tags, the countdown headline).
local T = require("../lib/Test")
local LobbyVote = require("../../src/shared/Run/LobbyVote")
local LobbyVoteModel = require("../../src/client/Util/LobbyVoteModel")

T.describe("LobbyVote.tier", function()
	T.it("most votes wins", function()
		local r = LobbyVote.tier({ a = 5, b = 5, c = 3 }, 2)
		T.eq(r.winner, 5)
		T.eq(r.tallies["5"], 2)
		T.eq(r.tallies["3"], 1)
		T.eq(r.votes, 3)
		T.eq(r.tie, false)
	end)
	T.it("a tie goes to the lower tier; Custom loses ties", function()
		T.eq(LobbyVote.tier({ a = 7, b = 4 }, 2).winner, 4)
		T.eq(LobbyVote.tier({ a = 4, b = 7, c = 9, d = 9, e = 4 }, 2).winner, 4)
		T.eq(LobbyVote.tier({ a = 0, b = 6 }, 2).winner, 6, "Custom vs Tier 6: the real tier")
		T.eq(LobbyVote.tier({ a = 0, b = 0, c = 6 }, 2).winner, 0, "Custom with more votes wins")
		T.eq(LobbyVote.tier({ a = 7, b = 4 }, 2).tie, true)
	end)
	T.it("no votes -> the fallback (the leader's saved tier); junk votes are ignored", function()
		local r = LobbyVote.tier({}, 3)
		T.eq(r.winner, 3)
		T.eq(r.votes, 0)
		T.eq(LobbyVote.tier({ a = 0 / 0, b = -1, c = 2.5 } :: any, 1).winner, 1)
	end)
	T.it("a leaver's vote is gone with them", function()
		local votes = { a = 8, b = 8, c = 2 }
		T.eq(LobbyVote.tier(votes, 2).winner, 8)
		votes.a = nil -- a left
		T.eq(LobbyVote.tier(votes, 2).winner, 2, "1-1: the lower tier")
	end)
end)

T.describe("LobbyVote.pace", function()
	T.it("most votes wins; a tie -> normal; no votes -> fallback; a filter drops locked votes", function()
		T.eq(LobbyVote.pace({ a = "fast", b = "fast", c = "normal" }, "normal").winner, "fast")
		T.eq(LobbyVote.pace({ a = "fast", b = "normal" }, "fast").winner, "normal")
		T.eq(LobbyVote.pace({}, "fast").winner, "fast")
		local r = LobbyVote.pace({ a = "fast", b = "normal", c = "fast" }, "normal", function(v)
			return v == "normal" -- e.g. rookies may not vote fast
		end)
		T.eq(r.winner, "normal")
		T.eq(r.tallies.fast, nil)
	end)
end)

T.describe("Util/LobbyVoteModel", function()
	local lobby = {
		startsAt = 100,
		countdownKind = "ready",
		vote = {
			tier = 4,
			pace = "normal",
			tierTallies = { ["4"] = 2, ["7"] = 1 },
			paceTallies = { normal = 2, fast = 1 },
			yourTier = 7,
		},
	}
	T.it("tallies, winners and my vote", function()
		T.truthy(LobbyVoteModel.isVoting(lobby))
		T.eq(LobbyVoteModel.isVoting({}), false, "solo: no vote")
		T.eq(LobbyVoteModel.tierCount(lobby, 4), 2)
		T.eq(LobbyVoteModel.tierCount(lobby, 9), 0)
		T.eq(LobbyVoteModel.paceCount(lobby, "fast"), 1)
		T.eq(LobbyVoteModel.winningTier(lobby), 4)
		T.eq(LobbyVoteModel.winningPace(lobby), "normal")
		T.eq(LobbyVoteModel.yourTier(lobby), 7)
		T.eq(LobbyVoteModel.countLabel(1), "(1 vote)")
		T.eq(LobbyVoteModel.countLabel(2), "(2 votes)")
		T.eq(LobbyVoteModel.countLabel(0), "")
	end)
	T.it("player tags and the countdown headline", function()
		T.eq(LobbyVoteModel.playerTag({ tierVote = 3, paceVote = "fast" }), " · 🗳 T3 ⚡")
		T.eq(LobbyVoteModel.playerTag({ tierVote = 0 }), " · 🗳 ⚙")
		T.eq(LobbyVoteModel.playerTag({}), "")
		T.eq(LobbyVoteModel.countdownText(lobby, 41), "Starting in 0:59")
		T.eq(LobbyVoteModel.countdownText(lobby, 100), nil)
		T.eq(
			LobbyVoteModel.countdownText({ startsAt = 10, countdownKind = "all" }, 9.5),
			"All ready, starting!"
		)
		T.eq(LobbyVoteModel.countdownText({}, 0), nil)
	end)
end)

return T.finish()
