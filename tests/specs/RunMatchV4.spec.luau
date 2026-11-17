--!strict
-- Run/MatchState v4 (docs/V4-PLAN.md "Match"): secured cheese, Snatch, the bot
-- extraction rule, Herd Call redeploys, late joiners, Rival Herd, rookies, awards.
local T = require("../lib/Test")
local MatchState = require("../../src/shared/Run/MatchState")
local Ids = require("../../src/shared/Util/Ids")

local C = MatchState.CONFIG

local function bot(n: number): number
	return Ids.botId(n)
end

-- squad 1 = human 1 + 2 bots; squads 2-4 = bots
local function lobby(): { any }
	local list = {}
	local nBot = 0
	for s = 1, 4 do
		for seat = 1, 3 do
			if s == 1 and seat == 1 then
				table.insert(list, { id = 1, squad = 1, isBot = false })
			else
				nBot += 1
				table.insert(list, { id = bot(nBot), squad = s, isBot = true })
			end
		end
	end
	return list
end

local function newMatch(seed: number?): any
	local m = MatchState.new(seed or 1, lobby())
	m:begin()
	return m
end

local function dmg(a: number, b: number, c: number, d: number): { [number]: number }
	return { [1] = a, [2] = b, [3] = c, [4] = d }
end

T.describe("MatchState v4 rewards", function()
	T.it("addSquadReward secures 25% at once, dead members included", function()
		local m = newMatch()
		m:heroKilled(1, bot(3))
		local total = m:addSquadReward(1, 100)
		T.eq(total, 300)
		T.eq(m:member(1).banked, 25)
		T.eq(m:member(1).secured, 25)
		T.eq(m:shareOf(1) - 0, 75 - math.floor(0)) -- bag taken before the reward
	end)
	T.it("championKilled: top damage gets it all, the killer squad snatches 50%", function()
		local m = newMatch()
		local r = m:championKilled(dmg(5, 80, 0, 0), 3, 3, 120)
		T.eq(r.winner, 2)
		T.eq(r.snatch, 3)
		T.eq(r.cheese, 120)
		T.eq(r.snatchCheese, 60)
		T.eq(m:member(bot(3)).share + m:member(bot(3)).banked, 120)
		T.eq(m:member(bot(6)).share + m:member(bot(6)).banked, 60)
		T.eq(m:member(bot(3)).championKills, 1)
		T.eq(m:member(bot(6)).championKills, 1, "the snatch counts as a kill (DoN)")
		T.truthy(m:squad(2).stageKill and m:squad(3).stageKill)
		T.falsy(m:squad(1).stageKill)
	end)
	T.it("championKilled without damage falls back to the killer, then the World's squad", function()
		local m = newMatch()
		T.eq(m:championKilled({}, 4, nil, 10).winner, 4)
		T.eq(m:championKilled(nil, nil, 2, 10).winner, 2)
		T.eq(m:championKilled(nil, nil, nil, 10).winner, nil)
	end)
	T.it("the payout floor is 40 per stage reached", function()
		local m = newMatch()
		m:eliminateSquad(1)
		T.eq(m:payout(1).cheese, C.STAGE_FLOOR)
		T.eq(m:payout(1).bestStage, 1)
		T.eq(m:payout(1).won, false)
	end)
	T.it("[M1] a stage-1 extraction is not a win; stage 3 is", function()
		local m = newMatch()
		m:startBoss()
		m:bossDefeated(1, dmg(1, 0, 0, 0))
		m:chooseRoute(1, 1)
		m:resolveExtraction({ [1] = "Extract" })
		T.eq(m:payout(1).extracted, true)
		T.eq(m:payout(1).won, false)
		local m2 = newMatch(2)
		for _ = 1, 3 do
			m2:startBoss()
			m2:bossDefeated(1, dmg(1, 1, 1, 1))
			m2:chooseRoute(1, nil)
			if m2.stage == 3 then
				m2:resolveExtraction({ [1] = "Extract" })
			else
				m2:resolveExtraction({})
			end
		end
		T.eq(m2:payout(1).stage, 3)
		T.eq(m2:payout(1).won, true)
		T.eq(m2:payout(1).fullClear, false, "[B1] not a full clear")
	end)
end)

T.describe("MatchState v4 bots and rookies", function()
	T.it("bot-only squads never extract before the stage-2 gate, then at 330 / 420", function()
		T.eq(MatchState.botExtractRule(1, 99999), "Stay")
		T.eq(MatchState.botExtractRule(2, 329), "Stay")
		T.eq(MatchState.botExtractRule(2, 330), "Extract")
		T.eq(MatchState.botExtractRule(3, 419), "Stay")
		T.eq(MatchState.botExtractRule(3, 420), "Extract")
		T.eq(MatchState.botExtractRule(4, 500), "Extract")
	end)
	T.it("rookies never carry a bounty", function()
		local m = newMatch()
		m:setRookie(1, true)
		for _, v in { bot(3), bot(6), bot(9) } do
			m:heroKilled(v, 1)
		end
		T.eq(m:member(1).streak, 3)
		T.falsy(m:member(1).bounty)
		T.deepEq(m:bountyIds(), {})
		T.eq(m:payout(1).rookie, true)
	end)
end)

T.describe("MatchState v4 Herd Call", function()
	T.it("starts on a death with a standing mate; 20 s on stage 1; cuts; completes once", function()
		local m = newMatch()
		T.eq(m:startRedeploy(1, 100, true, 250), nil, "not dead yet")
		m:heroKilled(1, bot(3))
		T.eq(m:startRedeploy(1, 100, false, 250), nil, "needs a standing squadmate")
		T.eq(m:startRedeploy(1, 100, true, 250), 120)
		T.deepEq(m:cutRedeploy(1, C.REDEPLOY_CUT_CHAMPION), { 1 })
		T.eq(m:member(1).redeployAt, 117)
		m:championKilled(dmg(9, 0, 0, 0), 1, 1, 0)
		T.eq(m:member(1).redeployAt, 114, "a champion kill cuts 3 s")
		T.deepEq(m:dueRedeploys(113, 250), {})
		T.deepEq(m:dueRedeploys(114, 250), { 1 })
		T.truthy(m:completeRedeploy(1))
		T.falsy(m:member(1).dead)
		m:heroKilled(1, bot(3)) -- a second death this stage
		T.eq(m:member(1).dead, true)
		T.eq(m:startRedeploy(1, 130, true, 250), nil, "1 redeploy per stage")
	end)
	T.it("one redeploy per stage; none in the last 20 s or outside the waves", function()
		local m = newMatch()
		m:heroKilled(1, bot(3))
		T.eq(m:startRedeploy(1, 231, true, 250), nil, "last 20 s")
		T.eq(m:startRedeploy(1, 100, true, 250), 120)
		T.deepEq(m:dueRedeploys(240, 250), {}, "frozen in the last 20 s")
		m:completeRedeploy(1)
		m.members[1].dead = true
		T.eq(m:startRedeploy(1, 140, true, 250), nil, "1 per stage")
		m:startBoss()
		T.deepEq(m:dueRedeploys(999, nil), {}, "never during the boss")
	end)
	T.it("delays by stage and cancel", function()
		T.eq(MatchState.redeployDelay(1), 20)
		T.eq(MatchState.redeployDelay(2), 25)
		T.eq(MatchState.redeployDelay(3), 30)
		T.eq(MatchState.redeployDelay(4), 35)
		local m = newMatch()
		m:heroKilled(bot(1), bot(3))
		m:startRedeploy(bot(1), 0, true, 150)
		T.deepEq(m:cancelRedeploys(), { bot(1) })
		T.eq(m:member(bot(1)).redeployAt, nil)
	end)
end)

T.describe("MatchState v4 seats", function()
	T.it("a late joiner takes a bot's seat with its share", function()
		local m = newMatch()
		m:addMemberCheese(bot(1), 50)
		T.truthy(m:replaceSeat(bot(1), 77))
		T.eq(m:member(bot(1)), nil)
		T.eq(m:squadOf(77), 1)
		T.eq(m:shareOf(77), 50)
		T.eq(m:humansInRun(), 2)
		T.truthy(table.find(m:squad(1).members, 77) ~= nil)
		T.falsy(m:replaceSeat(1, 78), "only bots give up a seat")
		T.falsy(m:replaceSeat(bot(2), 77), "id already seated")
	end)
	T.it("a Rival Herd enters only with <= 1 squad left and takes a bot-only slot first", function()
		local m = newMatch()
		T.falsy(m:needsRival())
		m:eliminateSquad(2)
		m:eliminateSquad(3)
		T.falsy(m:needsRival(), "2 squads left")
		m:eliminateSquad(4)
		T.truthy(m:needsRival())
		T.eq(m:rivalSlot(), 2)
		local s = m:addRivalSquad({ { id = bot(50) }, { id = bot(51) }, { id = bot(52) } }, "Rival Herd")
		T.eq(s, 2)
		T.deepEq(m:squadsInRun(), { 1, 2 })
		T.eq(m:squad(2).rival, true)
		T.eq(#m:activeMembers(2), 3)
		T.falsy(m:isInRun(bot(3)), "the old squad's bots stay out")
		T.eq(m:payout(bot(3)).result, "eliminated")
		T.falsy(m:needsRival())
	end)
	T.it("no Rival Herd without a human in the run", function()
		local m = newMatch()
		m:eliminateSquad(1)
		m:eliminateSquad(2)
		m:eliminateSquad(3)
		T.falsy(m:needsRival())
	end)
end)

T.describe("MatchState v4 QC fixes", function()
	T.it("[QC MAJOR 1] a joiner taking a dead bot's seat is alive, with no timer or bag state", function()
		local m = newMatch()
		m:heroKilled(bot(1), bot(3))
		T.truthy(m:startRedeploy(bot(1), 0, true, 150) ~= nil)
		T.truthy(m:replaceSeat(bot(1), 77))
		local h = m:member(77)
		T.eq(h.dead, false)
		T.eq(h.redeployAt, nil)
		T.eq(h.redeploys, 0)
		T.eq(h.bagDropped, false)
		T.deepEq(m:dueRedeploys(999, nil), {}, "no free Herd Call")
		T.deepEq(
			m:fallenSquads(function()
				return true
			end),
			{},
			"the squad is not fallen"
		)
		local k = m:heroKilled(77, bot(3))
		T.truthy(k and k.killer == bot(3), "a later death gives kill credit")
		T.truthy(k.bagKey ~= nil, "and drops a bag")
	end)
	T.it("[QC minor 4] a returning player retakes a bot seat", function()
		local m = newMatch()
		m:addMemberCheese(1, 30)
		m:removeMember(1)
		T.falsy(m:isInRun(1))
		T.truthy(m:replaceSeat(bot(1), 1), "the old id may sit again")
		T.truthy(m:isInRun(1))
		T.eq(m:member(1).banked, 0, "the old record was paid on leaving")
		local count = 0
		for _, id in m.order do
			count += if id == 1 then 1 else 0
		end
		T.eq(count, 1, "listed once")
	end)
	T.it("[QC minor 2] a boss that flees is no kill for Double or Nothing", function()
		local m = newMatch(2)
		m:startBoss()
		m:bossDefeated(1, dmg(1, 0, 0, 0))
		m:chooseRoute(1, 1)
		m:resolveExtraction({ [1] = "DoubleOrNothing" })
		m:startBoss()
		local r = m:bossDefeated(nil, dmg(9, 0, 0, 0), true)
		T.eq(r.winner, 1, "the chest still goes to the top damage")
		T.truthy(r.potLost[1] ~= nil, "but the DoN pot is lost")
		T.eq(r.potBonus[1], nil)
	end)
end)

T.describe("MatchState v4 leavers (QC minor 3)", function()
	T.it("a leaver who never played gets no floor; one who did keeps it", function()
		local m = newMatch()
		local p = m:removeMember(1)
		T.eq(p.cheese, 0)
		T.eq(p.engaged, false)
		local m2 = newMatch()
		m2:markEngaged(1)
		local p2 = m2:removeMember(1)
		T.eq(p2.cheese, C.STAGE_FLOOR)
		T.eq(p2.engaged, true)
	end)
end)

T.describe("MatchState v4 awards", function()
	T.it("MVP by score; up to 3 accolades by percentile", function()
		local entries = {
			{
				id = 1,
				mice = 300,
				championShare = 1,
				heroDowns = 2,
				revives = 1,
				bossDamagePct = 40,
				extracted = true,
				damageTaken = 100,
				stormDamage = 0,
			},
			{
				id = bot(1),
				mice = 100,
				championShare = 0,
				heroDowns = 0,
				revives = 0,
				bossDamagePct = 10,
				damageTaken = 500,
				stormDamage = 50,
			},
			{
				id = bot(2),
				mice = 50,
				championShare = 0,
				heroDowns = 1,
				revives = 3,
				bossDamagePct = 0,
				damageTaken = 300,
				stormDamage = 10,
			},
		}
		local a = MatchState.awards(entries)
		T.eq(a.mvp.id, 1)
		T.near(a.mvp.score, 30 + 40 + 50 + 30 + 80 + 50)
		T.eq(#a.accolades[1], 3)
		T.truthy(table.find(a.accolades[1], "mouse_masher") ~= nil)
		T.truthy(table.find(a.accolades[bot(2)], "clutch_reviver") ~= nil)
		T.falsy(table.find(a.accolades[bot(1)], "iron_trunk"), "most damage taken: no Iron Trunk")
		T.falsy(table.find(a.accolades[bot(1)], "melt_dodger"))
		T.truthy(table.find(a.accolades[1], "iron_trunk") ~= nil or #a.accolades[1] == 3)
	end)
	T.it("a lone hero gets no percentile accolades but can be MVP", function()
		local a = MatchState.awards({ { id = 5, mice = 10 } })
		T.eq(a.mvp.id, 5)
		T.deepEq(a.accolades[5], {})
	end)
end)

return T.finish()
