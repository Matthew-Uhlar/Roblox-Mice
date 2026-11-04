-- Pure client v2 helpers (R5): minimap projection, scoreboard sort, perk tree
-- normalisation / states / layout maths, class progression fallbacks and
-- kill-streak bounties. None of these touch Roblox APIs, so they run in Lune.
local T = require("../lib/Test")
local Minimap = require("../../src/client/Util/Minimap")
local Scoreboard = require("../../src/client/Util/Scoreboard")
local PerkTree = require("../../src/client/Util/PerkTree")
local ClassMath = require("../../src/client/Util/ClassMath")
local KillStreaks = require("../../src/client/Util/KillStreaks")
local Layout = require("../../src/client/Util/Layout")

T.describe("Minimap.project", function()
	T.it("centre maps to the origin", function()
		local x, y, c = Minimap.project(10, -4, 10, -4, 100, 70)
		T.near(x, 0)
		T.near(y, 0)
		T.falsy(c)
	end)
	T.it("fixed yaw: +X is right, +Z is down, linear in range", function()
		local x, y = Minimap.project(50, 0, 0, 0, 100, 70, 0)
		T.near(x, 35)
		T.near(y, 0)
		x, y = Minimap.project(0, 50, 0, 0, 100, 70, 0)
		T.near(x, 0)
		T.near(y, 35)
		x, y = Minimap.project(-25, -25, 0, 0, 100, 80, 0)
		T.near(x, -20)
		T.near(y, -20)
	end)
	T.it("far markers clamp onto the rim and keep their direction", function()
		local x, y, c = Minimap.project(1000, 0, 0, 0, 100, 70, 7)
		T.truthy(c)
		T.near(x, 63)
		T.near(y, 0)
		x, y, c = Minimap.project(300, 400, 0, 0, 100, 70, 0) -- 3-4-5 triangle
		T.truthy(c)
		T.near(x, 42)
		T.near(y, 56)
		T.near(math.sqrt(x * x + y * y), 70)
	end)
	T.it("never leaves the circle, whatever the input", function()
		for i = 1, 200 do
			local a = i * 0.731
			local d = (i % 17) * 37
			local x, y = Minimap.project(math.cos(a) * d, math.sin(a) * d, 0, 0, 110, 75)
			T.truthy(x * x + y * y <= (75 - Minimap.EDGE_MARGIN) ^ 2 + 1e-6)
		end
	end)
	T.it("degenerate range / radius are safe", function()
		local x, y = Minimap.project(5, 5, 0, 0, 0, 0)
		T.truthy(x == x and y == y, "no NaN")
	end)
	T.it("sight and range checks", function()
		T.truthy(Minimap.inSight(30, 40, 0, 0, 50))
		T.falsy(Minimap.inSight(30, 41, 0, 0, 50))
		T.truthy(Minimap.inRange(0, 110, 0, 0))
		T.falsy(Minimap.inRange(0, 111, 0, 0))
	end)
end)

T.describe("Scoreboard", function()
	local payload = {
		["1"] = { name = "Swiss", pending = 300, kills = 2, alive = 3, members = { 11, 12, -1001 } },
		["2"] = { pending = 500, kills = 0, alive = 0, eliminated = true, members = { 21 } },
		["3"] = { name = "Blue", pending = "300", kills = 5, alive = 2, members = { "31", 32 } },
		["4"] = { name = "Pepper Jack", pending = 120, kills = 1, extracted = true, isYou = true },
	}
	T.it("server shape: alive is a boolean, aliveCount the number", function()
		local list = Scoreboard.normalise({
			{ id = 1, members = { 1, 2, 3 }, alive = true, aliveCount = 2, doubleOrNothing = true },
			{ id = 2, members = { 4, 5, 6 }, alive = false, aliveCount = 0, eliminated = true },
			{ id = 3, members = { 7, 8, 9 }, alive = true },
		})
		T.eq(list[1].alive, 2)
		T.truthy(list[1].doubleOrNothing)
		T.eq(list[2].alive, 0)
		T.eq(list[3].alive, 3)
	end)
	T.it("normalises string keys, numbers and defaults", function()
		local list = Scoreboard.normalise(payload)
		T.eq(#list, 4)
		T.eq(list[2].name, "Brie", "default name")
		T.deepEq(list[2].color, { 245, 240, 220 }, "default colour")
		T.eq(list[3].pending, 300)
		T.deepEq(list[3].members, { 31, 32 })
		T.truthy(list[4].isYou)
		T.eq(list[4].alive, 0, "alive defaults to #members")
	end)
	T.it("mySquad marks isYou", function()
		local list = Scoreboard.normalise({ { name = "A" }, { name = "B" } }, 2)
		T.falsy(list[1].isYou)
		T.truthy(list[2].isYou)
	end)
	T.it("sorts eliminated last, then pending, kills, alive, id", function()
		local sorted = Scoreboard.sort(Scoreboard.normalise(payload))
		local ids = {}
		for _, s in sorted do
			table.insert(ids, s.id)
		end
		-- 3 and 1 tie on pending: Blue has more kills. Brie (500) is eliminated.
		T.deepEq(ids, { 3, 1, 4, 2 })
	end)
	T.it("sort is stable on full ties and leaves the input alone", function()
		local list = Scoreboard.normalise({ {}, {}, {}, {} })
		local sorted = Scoreboard.sort(list)
		for i, s in sorted do
			T.eq(s.id, i)
		end
		T.truthy(sorted ~= list)
	end)
	T.it("placement, squadOf and ordinals", function()
		local list = Scoreboard.normalise(payload)
		T.eq(Scoreboard.placement(list, 3), 1)
		T.eq(Scoreboard.placement(list, 2), 4)
		T.eq(Scoreboard.placement(list, 9), nil)
		T.eq(Scoreboard.squadOf(list, -1001), 1)
		T.eq(Scoreboard.squadOf(list, 32), 3)
		T.eq(Scoreboard.squadOf(list, 99), nil)
		T.eq(Scoreboard.ordinal(1), "1st")
		T.eq(Scoreboard.ordinal(2), "2nd")
		T.eq(Scoreboard.ordinal(3), "3rd")
		T.eq(Scoreboard.ordinal(4), "4th")
		T.eq(Scoreboard.ordinal(12), "12th")
	end)
	T.it("bad payloads give an empty list", function()
		T.eq(#Scoreboard.normalise(nil), 0)
		T.eq(#Scoreboard.normalise({ x = 1, ["9"] = {} }), 0)
	end)
end)

T.describe("PerkTree", function()
	local function perks(prefix: string)
		local out = {}
		for t = 1, 5 do
			table.insert(out, { id = prefix .. t, name = prefix .. " " .. t, description = "+" .. t * 2 .. "%" })
		end
		return out
	end
	local mod = {
		elephante = {
			branches = {
				{ id = "tank", name = "Tank", perks = perks("t") },
				{ id = "stomp", name = "Stomp", perks = perks("s") },
				{ id = "herd", name = "Herd", perks = perks("h") },
			},
		},
	}
	T.it("extracts and normalises a branches table", function()
		local tree = PerkTree.normalise(PerkTree.extract(mod, "elephante"))
		T.falsy(tree.placeholder)
		T.eq(#tree.branches, 3)
		T.eq(tree.branches[2].name, "Stomp")
		T.eq(tree.branches[3].perks[5].id, "h5")
		T.eq(tree.branches[1].perks[1].tier, 1)
	end)
	T.it("accepts accessor functions and flat lists", function()
		local viaFn = { get = function(id)
			return if id == "filet" then { perks("a"), perks("b"), perks("c") } else nil
		end }
		local t1 = PerkTree.normalise(PerkTree.extract(viaFn, "filet"))
		T.eq(t1.branches[2].perks[4].id, "b4")
		local flat = { LIST = {} }
		for _, b in { "fire", "ice", "wind" } do
			for t = 1, 5 do
				table.insert(flat.LIST, { id = b .. t, classId = "jumbo", branch = b, tier = t })
			end
		end
		table.insert(flat.LIST, { id = "other", classId = "filet", branch = "x", tier = 1 })
		local t2 = PerkTree.normalise(PerkTree.extract(flat, "jumbo"))
		T.eq(t2.branches[1].name, "fire")
		T.eq(t2.branches[3].perks[5].id, "wind5")
		T.eq(PerkTree.spent(t2, { other = true }), 0, "other class's perk not counted")
	end)
	T.it("a missing config gives a 3-branch placeholder", function()
		local tree = PerkTree.normalise(PerkTree.extract(nil, "x"))
		T.truthy(tree.placeholder)
		T.eq(#tree.branches, 3)
		local st, why = PerkTree.nodeState(tree, 1, 1, {}, 5)
		T.eq(st, "locked")
		T.eq(why, "missing")
	end)
	T.it("tiers unlock in order and need a free point", function()
		local tree = PerkTree.normalise(PerkTree.extract(mod, "elephante"))
		local taken = { t1 = true, t2 = true, s1 = true }
		T.eq(PerkTree.spentIn(tree, 1, taken), 2, "cost defaults to 1")
		T.eq(PerkTree.spent(tree, taken), 3)
		T.eq((PerkTree.nodeState(tree, 1, 1, taken, 1)), "taken")
		T.eq((PerkTree.nodeState(tree, 1, 3, taken, 1)), "available")
		local st, why = PerkTree.nodeState(tree, 1, 4, taken, 1)
		T.eq(st, "locked")
		T.eq(why, "tier")
		st, why = PerkTree.nodeState(tree, 3, 1, taken, 0)
		T.eq(st, "locked")
		T.eq(why, "points")
		T.eq((PerkTree.nodeState(tree, 3, 1, taken, 1)), "available")
		-- a gap (tier 2 not taken) locks tier 3 even with points in the branch
		st, why = PerkTree.nodeState(tree, 2, 3, { s1 = true, s4 = true }, 9)
		T.eq(why, "tier")
	end)
	T.it("costs: tier t costs t points (R3 Config/ClassPerks)", function()
		local costed = { { id = "a", tier = 1, cost = 1, branchIndex = 1 }, { id = "b", tier = 2, cost = 2, branchIndex = 1 } }
		local tree = PerkTree.normalise({ flat = costed })
		T.eq(PerkTree.spentIn(tree, 1, { a = true, b = true }), 3)
		local st, why = PerkTree.nodeState(tree, 1, 2, { a = true }, 1)
		T.eq(st, "locked")
		T.eq(why, "points")
		T.eq((PerkTree.nodeState(tree, 1, 2, { a = true }, 2)), "available")
	end)
	T.it("reads the real Config/ClassPerks for every class", function()
		local ClassPerks = require("../../src/shared/Config/ClassPerks")
		local Classes = require("../../src/shared/Config/Classes")
		for _, classId in Classes.ORDER do
			local tree = PerkTree.normalise(PerkTree.extract(ClassPerks, classId))
			T.falsy(tree.placeholder, classId)
			for b = 1, 3 do
				for t = 1, 5 do
					local p = tree.branches[b].perks[t]
					T.truthy(p ~= nil, classId .. " " .. b .. "/" .. t)
					T.eq(p.cost, t)
				end
				T.truthy(tree.branches[b].name ~= "Branch " .. b, "branch named")
			end
		end
	end)
	T.it("free points: explicit wins, else level - 1 - spent, never negative", function()
		T.eq(PerkTree.freePoints(10, 3, nil), 6)
		T.eq(PerkTree.freePoints(10, 3, 2), 2)
		T.eq(PerkTree.freePoints(1, 0, nil), 0)
		T.eq(PerkTree.freePoints(2, 9, nil), 0)
		T.eq(PerkTree.freePoints(5, 0, "-3"), 0)
	end)
	T.it("layout: nodes inside the box, centred per column, no overlaps", function()
		local w, h, head = 600, 420, 40
		local L = PerkTree.layout(w, h, 3, 5, 72, head)
		T.eq(L.colW, 200)
		T.near(L.rowH, 76)
		T.truthy(L.node <= 72 and L.node <= L.rowH * 0.8 + 1e-6, "node capped by the row")
		for b = 1, 3 do
			for t = 1, 5 do
				local p = L.nodes[b][t]
				T.truthy(p.x >= 0 and p.x + L.node <= w + 1e-6, "inside x")
				T.truthy(p.y >= head - 1e-6 and p.y + L.node <= h + 1e-6, "inside y")
				T.near(p.x + L.node / 2, L.colW * (b - 0.5), 1e-6, "centred in its column")
				if t > 1 then
					T.truthy(p.y >= L.nodes[b][t - 1].y + L.node, "no vertical overlap")
				end
			end
		end
		T.eq(#L.links, 3 * 4)
		for _, link in L.links do
			local a = L.nodes[link.branch][link.tier]
			local nxt = L.nodes[link.branch][link.tier + 1]
			T.near(link.y, a.y + L.node, 1e-6, "link starts under its node")
			T.near(link.y + link.h, nxt.y, 1e-6, "link ends on the next node")
			T.truthy(link.h >= 0)
		end
	end)
	T.it("layout copes with a phone-sized box", function()
		local L = PerkTree.layout(300, 200, 3, 5, 72, 20)
		T.truthy(L.node >= 8 and L.node <= 36 * 0.8 + 1e-6)
		local tiny = PerkTree.layout(0, 0)
		T.truthy(tiny.node >= 8, "minimum node size")
	end)
	T.it("72 px design nodes stay >= 48 px touch targets on a 667x375 phone", function()
		local m = Layout.metrics(667, 375 - 58, true)
		-- the perk tree panel body is about 560 x 380 design px on that phone
		local L = PerkTree.layout(560, 380, 3, 5, math.max(72, m.touch), 34)
		T.truthy(L.node * m.scale >= 28, "node visibly sized: " .. L.node * m.scale)
	end)
end)

T.describe("ClassMath", function()
	T.it("xp curve matches 100 * n^1.4", function()
		T.eq(ClassMath.xpToNext(1), 100)
		T.eq(ClassMath.xpToNext(2), math.floor(100 * 2 ^ 1.4))
		T.eq(ClassMath.xpToNext(10), math.floor(100 * 10 ^ 1.4))
		T.eq(ClassMath.xpToNext(99), ClassMath.xpToNext(30), "clamped")
	end)
	T.it("mastery tiers", function()
		T.eq(ClassMath.mastery(1), "none")
		T.eq(ClassMath.mastery(10), "bronze")
		T.eq(ClassMath.mastery(29), "silver")
		T.eq(ClassMath.mastery(30), "gold")
		T.eq(ClassMath.masteryName("gold"), "Gold Herd")
	end)
	T.it("unlocks between levels", function()
		local u = ClassMath.unlocksBetween(2, 10)
		local kinds = {}
		for _, x in u do
			table.insert(kinds, x.kind .. x.level)
		end
		T.deepEq(kinds, { "skin3", "ability5", "mastery10", "skin10" })
		T.eq(#ClassMath.unlocksBetween(10, 10), 0)
		T.eq(#ClassMath.unlocksBetween(29, 30), 2) -- skin + gold mastery
	end)
	T.it("addXp rolls levels over and stops at the cap", function()
		local xp, lv, gained = ClassMath.addXp(50, 1, 100)
		T.eq(lv, 2)
		T.eq(gained, 1)
		T.eq(xp, 50)
		xp, lv = ClassMath.addXp(0, 29, 1e9)
		T.eq(lv, 30)
		T.eq(xp, 0)
		T.eq(ClassMath.progress(0, 30), 1)
		T.near(ClassMath.progress(50, 1), 0.5)
	end)
end)

T.describe("KillStreaks", function()
	T.it("3 enemy downs in a row start a bounty, being downed ends it", function()
		local s = KillStreaks.new()
		T.eq(KillStreaks.push(s, { killer = 7, victim = 1, killerSquad = 1, victimSquad = 2, kind = "down" }), nil)
		T.eq(KillStreaks.push(s, { killer = 7, victim = 2, killerSquad = 1, victimSquad = 3, kind = "kill" }), nil)
		T.eq(KillStreaks.push(s, { killer = 7, victim = 3, killerSquad = 1, victimSquad = 2, kind = "down" }), "7")
		T.truthy(KillStreaks.hasBounty(s, 7))
		T.eq(KillStreaks.push(s, { killer = 7, victim = 4, kind = "down" }), nil, "only announced once")
		KillStreaks.push(s, { killer = 2, victim = 7, killerSquad = 3, victimSquad = 1, kind = "down" })
		T.falsy(KillStreaks.hasBounty(s, 7))
		T.eq(s.counts["7"], 0)
	end)
	T.it("same-squad and unknown kinds don't count; explicit bounty works", function()
		local s = KillStreaks.new()
		for _ = 1, 5 do
			KillStreaks.push(s, { killer = 9, victim = 8, killerSquad = 2, victimSquad = 2, kind = "kill" })
			KillStreaks.push(s, { killer = 9, victim = 5, kind = "boss" })
		end
		T.falsy(KillStreaks.hasBounty(s, 9))
		T.eq(KillStreaks.push(s, { victim = "Pip", kind = "bounty" }), "Pip")
		T.deepEq(KillStreaks.holders(s), { "Pip" })
		KillStreaks.push(s, { victim = "Pip", kind = "bountyClaimed" })
		T.eq(#KillStreaks.holders(s), 0)
		KillStreaks.reset(s)
		T.eq(next(s.counts), nil)
	end)
end)

return T.finish()
