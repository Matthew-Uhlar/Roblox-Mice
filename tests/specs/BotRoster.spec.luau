local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local Classes = require("../../src/shared/Config/Classes")
local BotRoster = require("../../src/shared/Bots/BotRoster")

local function ids(list: { any }): { number }
	local out = {}
	for _, b in list do
		table.insert(out, b.id)
	end
	return out
end

T.describe("BotRoster.fill counts", function()
	T.it("0 humans -> 3 bots (lobby only spawns bots with >= 1 human)", function()
		T.eq(#BotRoster.fill(0, 4, 3, {}, Rng.new(1)), 3)
	end)
	T.it("solo path: 1 human -> 2 bots, so a lone player always gets a full party", function()
		local bots = BotRoster.fill(1, 4, 3, { "elephante" }, Rng.new(7))
		T.eq(#bots, 2)
		T.eq(1 + #bots, 3, "party size")
		for _, b in bots do
			T.truthy(b.isBot)
			T.truthy(b.id < 0, "negative id")
			T.truthy(string.find(b.name, "🤖", 1, true), "name carries the bot tag")
			T.truthy(Classes.isFree(b.classId), "free class " .. b.classId)
		end
	end)
	T.it("solo with defaults (no optional args) still gives 2 bots", function()
		T.eq(#BotRoster.fill(1), 2)
	end)
	T.it("2 humans -> 1 bot", function()
		T.eq(#BotRoster.fill(2, 4, 3, {}, Rng.new(1)), 1)
	end)
	T.it("3 or 4 humans -> 0 bots", function()
		T.eq(#BotRoster.fill(3, 4, 3, {}, Rng.new(1)), 0)
		T.eq(#BotRoster.fill(4, 4, 3, {}, Rng.new(1)), 0)
		T.eq(#BotRoster.fill(6, 4, 3, {}, Rng.new(1)), 0)
	end)
	T.it("never exceeds maxParty", function()
		T.eq(#BotRoster.fill(1, 2, 3, {}, Rng.new(1)), 1)
		T.eq(#BotRoster.fill(0, 4, 4, {}, Rng.new(1)), 4)
		T.eq(BotRoster.botCount(1), 2)
	end)
end)

T.describe("BotRoster.fill ids, names and classes", function()
	T.it("ids are unique and in the bot band -1001, -1002, ...", function()
		T.deepEq(ids(BotRoster.fill(0, 4, 3, {}, Rng.new(3))), { -1001, -1002, -1003 })
	end)
	T.it("skips ids already taken", function()
		local got = ids(BotRoster.fill(1, 4, 3, {}, Rng.new(3), { -1001 }))
		T.deepEq(got, { -1002, -1003 })
	end)
	T.it("never collides with Studio test players (negative UserIds -1..-8)", function()
		for _, b in BotRoster.fill(0, 4, 3, {}, Rng.new(4)) do
			T.truthy(BotRoster.isBotId(b.id), "bot id in bot band")
		end
		for uid = -8, -1 do
			T.falsy(BotRoster.isBotId(uid), "studio player " .. uid .. " is not a bot")
		end
	end)
	T.it("names are unique", function()
		local seen = {}
		for _, b in BotRoster.fill(0, 4, 4, {}, Rng.new(9)) do
			T.falsy(seen[b.name], "duplicate " .. b.name)
			seen[b.name] = true
		end
	end)
	T.it("covers the roles the humans are missing", function()
		local bots = BotRoster.fill(1, 4, 3, { "elephante" }, Rng.new(5))
		local roles = {}
		for _, b in bots do
			roles[b.role] = true
			T.truthy(b.classId ~= "elephante", "tank already covered")
		end
		T.truthy(roles.ranged, "ranged covered")
		T.truthy(roles.support, "support covered")
	end)
	T.it("with no humans covers tank, ranged and support", function()
		local roles = {}
		for _, b in BotRoster.fill(0, 4, 3, {}, Rng.new(11)) do
			roles[b.role] = true
		end
		T.truthy(roles.tank and roles.ranged and roles.support)
	end)
	T.it("only uses free classes even when paid classes would cover a role", function()
		for seed = 1, 20 do
			for _, b in BotRoster.fill(0, 4, 4, { "jumbo" }, Rng.new(seed)) do
				T.truthy(Classes.isFree(b.classId), b.classId)
			end
		end
	end)
	T.it("is deterministic for the same seed", function()
		T.deepEq(BotRoster.fill(1, 4, 3, {}, Rng.new(42)), BotRoster.fill(1, 4, 3, {}, Rng.new(42)))
	end)
end)

local Squads = require("../../src/shared/Util/Squads")
local Ids = require("../../src/shared/Util/Ids")

local function humans(list: { any }): { any }
	local out = {}
	for _, h in list do
		table.insert(out, if type(h) == "number" then { id = h } else h)
	end
	return out
end

local function squadOfId(squads: any, id: number): number?
	for s = 1, 4 do
		for _, m in squads[s] or {} do
			if m.id == id then
				return s
			end
		end
	end
	return nil
end

T.describe("BotRoster.partyIds", function()
	T.it("groups linked players; partyId is the smallest id of the group", function()
		local p = BotRoster.partyIds({ 5, 3, 9, 7, 2 }, { { 5, 3 }, { 9, 5 }, { 7, 2 } })
		T.eq(p[5], 3)
		T.eq(p[3], 3)
		T.eq(p[9], 3)
		T.eq(p[7], 2)
		T.eq(p[2], 2)
	end)
	T.it("ignores links to players who are not present; loners are their own party", function()
		local p = BotRoster.partyIds({ 1, 2 }, { { 1, 99 } })
		T.eq(p[1], 1)
		T.eq(p[2], 2)
	end)
end)

T.describe("BotRoster.partition", function()
	T.it("friends share a squad", function()
		local sq = BotRoster.partition(humans({
			{ id = 1, partyId = 1 },
			{ id = 2 },
			{ id = 3, partyId = 1 },
			{ id = 4, partyId = 4 },
			{ id = 5, partyId = 4 },
		}))
		local where = {}
		for i, list in sq do
			for _, h in list do
				where[h.id] = i
			end
		end
		T.eq(where[1], where[3], "party 1 together")
		T.eq(where[4], where[5], "party 4 together")
		T.truthy(where[1] ~= where[4], "two pairs need two squads")
		T.truthy(where[2] == where[1] or where[2] == where[4], "the solo fills a gap next to a pair")
	end)
	T.it("strangers are packed together (best fit) before a new squad opens", function()
		local sq = BotRoster.partition(humans({ 1, 2, 3, 4 }))
		T.eq(#sq[1], 3)
		T.eq(#sq[2], 1)
		T.eq(#sq[3], 0)
	end)
	T.it("a party bigger than a squad is split into squad-sized chunks", function()
		local list = {}
		for i = 1, 5 do
			table.insert(list, { id = i, partyId = 1 })
		end
		local sq = BotRoster.partition(list)
		T.eq(#sq[1], 3)
		T.eq(#sq[2], 2)
	end)
	T.it("five pairs: one pair is split over the gaps; nobody is dropped", function()
		local list = {}
		for i = 1, 10 do
			table.insert(list, { id = i, partyId = math.ceil(i / 2) })
		end
		local sq, overflow = BotRoster.partition(list)
		T.eq(#overflow, 0)
		local n = 0
		for _, l in sq do
			T.truthy(#l <= 3)
			n += #l
		end
		T.eq(n, 10)
	end)
	T.it("more than 12 humans: the rest overflow", function()
		local list = {}
		for i = 1, 14 do
			table.insert(list, { id = i })
		end
		local _, overflow = BotRoster.partition(list)
		T.eq(#overflow, 2)
	end)
	T.it("duplicate ids are seated once", function()
		local sq = BotRoster.partition(humans({ 1, 1, 2 }))
		T.eq(#sq[1], 2)
	end)
end)

T.describe("BotRoster.fillSquads", function()
	T.it("solo: 2 bot mates and 3 full bot squads (12 seats)", function()
		local squads = BotRoster.fillSquads(humans({ { id = 77, classId = "elephante" } }), Rng.new(1))
		local total, bots = 0, 0
		for s = 1, Squads.MAX do
			T.eq(#squads[s], Squads.SIZE, "squad " .. s .. " is full")
			for _, m in squads[s] do
				total += 1
				T.eq(m.squad, s)
				if m.isBot then
					bots += 1
					T.truthy(Ids.isBot(m.id), "bot id band")
					T.truthy(string.find(m.name, "🤖", 1, true), "labelled")
				end
			end
		end
		T.eq(total, 12)
		T.eq(bots, 11)
		local s = squadOfId(squads, 77) :: number
		local mates = 0
		for _, m in squads[s] do
			if m.isBot then
				mates += 1
			end
		end
		T.eq(mates, 2)
	end)
	T.it("bot ids are Ids.botId(n), unique, and skip taken ids", function()
		local squads = BotRoster.fillSquads(humans({ 1 }), Rng.new(2), { takenIds = { Ids.botId(1) } })
		local seen = {}
		local list = {}
		for _, m in BotRoster.flatten(squads) do
			if m.isBot then
				T.falsy(seen[m.id], "duplicate id")
				seen[m.id] = true
				table.insert(list, m.id)
			end
		end
		T.falsy(seen[Ids.botId(1)], "taken id skipped")
		T.truthy(seen[Ids.botId(2)] and seen[Ids.botId(12)])
		T.eq(#list, 11)
	end)
	T.it("every bot squad covers tank, ranged and support", function()
		for seed = 1, 10 do
			local squads = BotRoster.fillSquads(humans({ 1 }), Rng.new(seed))
			for s = 1, 4 do
				local allBots = true
				local roles = {}
				for _, m in squads[s] do
					allBots = allBots and m.isBot
					if m.role then
						roles[m.role] = true
					end
					if m.isBot then
						T.truthy(Classes.isFree(m.classId), m.classId)
					end
				end
				if allBots then
					T.truthy(roles.tank and roles.ranged and roles.support, "seed " .. seed .. " squad " .. s)
				end
			end
		end
	end)
	T.it("bot mates cover the roles their humans miss", function()
		local squads = BotRoster.fillSquads(humans({ { id = 1, classId = "elephante" } }), Rng.new(4))
		local s = squadOfId(squads, 1) :: number
		local roles = {}
		for _, m in squads[s] do
			roles[m.role] = true
		end
		T.truthy(roles.tank and roles.ranged and roles.support)
	end)
	T.it("friends are seated together and humans keep their fields", function()
		local squads = BotRoster.fillSquads(
			humans({ { id = 10, partyId = 10, classId = "jumbo" }, { id = 11 }, { id = 12, partyId = 10 } }),
			Rng.new(5)
		)
		T.eq(squadOfId(squads, 10), squadOfId(squads, 12))
		for _, m in BotRoster.flatten(squads) do
			if m.id == 10 then
				T.eq(m.classId, "jumbo")
				T.eq(m.partyId, 10)
				T.eq(m.isBot, false)
			end
		end
	end)
	T.it("12 humans: no bots", function()
		local list = {}
		for i = 1, 12 do
			table.insert(list, { id = i })
		end
		for _, m in BotRoster.flatten(BotRoster.fillSquads(list, Rng.new(1))) do
			T.falsy(m.isBot)
		end
	end)
	T.it("mates = false: human squads get no bots, the other squads still fill", function()
		local squads = BotRoster.fillSquads(humans({ 1 }), Rng.new(6), { mates = false })
		local s = squadOfId(squads, 1) :: number
		T.eq(#squads[s], 1)
		local total = #BotRoster.flatten(squads)
		T.eq(total, 10)
	end)
	T.it("bot names are unique across the match", function()
		local seen = {}
		for _, m in BotRoster.flatten(BotRoster.fillSquads({}, Rng.new(8))) do
			T.falsy(seen[m.name], "duplicate " .. tostring(m.name))
			seen[m.name] = true
		end
	end)
	T.it("is deterministic for a seed", function()
		local a = BotRoster.fillSquads(humans({ 1, 2 }), Rng.new(42))
		local b = BotRoster.fillSquads(humans({ 1, 2 }), Rng.new(42))
		T.deepEq(BotRoster.flatten(a)[5], BotRoster.flatten(b)[5])
		T.eq(squadOfId(a, 1), squadOfId(b, 1))
	end)
	T.it("works as MatchState participants", function()
		local MatchState = require("../../src/shared/Run/MatchState")
		local list = BotRoster.flatten(BotRoster.fillSquads(humans({ 1, 2, 3, 4, 5 }), Rng.new(9)))
		local m = MatchState.new(9, list)
		m:begin()
		T.eq(#m:squadsInRun(), 4)
		T.eq(m:humansInRun(), 5)
	end)
end)

return T.finish()
