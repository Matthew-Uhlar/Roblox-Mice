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

return T.finish()
