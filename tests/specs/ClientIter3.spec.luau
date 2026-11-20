-- Iteration 3 Phase B pure client helpers (team U): the Results loot column
-- (T-12), the Prestige banner (T-14) and the Custom tile gate (T-17).
local T = require("../lib/Test")
local ResultsModel = require("../../src/client/Util/ResultsModel")
local ToastQueue = require("../../src/client/Util/ToastQueue")
local LadderModel = require("../../src/client/Util/LadderModel")

T.describe("T-12 loot column", function()
	local before = {
		gems = { inv = { { id = 1, tier = 2 } } },
		ladder = { unlocked = 3, bestSolo = 2, bestSoloTime = 900 },
		challenges = {
			list = { { id = "a", name = "Bare Trunk", done = true }, { id = "b", name = "Speed Herd" } },
		},
	}
	T.it("diffs the run-start profile with the paid-out one", function()
		local after = {
			gems = { inv = { { id = 1, tier = 2 }, { id = 2, tier = 3 } } },
			ladder = { unlocked = 4, bestSolo = 3, bestSoloTime = 1000 },
			challenges = {
				list = {
					{ id = "a", name = "Bare Trunk", done = true },
					{ id = "b", name = "Speed Herd", done = true },
				},
			},
		}
		local l = ResultsModel.loot({}, before, after)
		T.eq(#l.gems, 1)
		T.eq(l.gems[1].id, 2)
		T.eq(l.tierUnlocked, 4)
		T.eq(l.bestSolo, 3)
		T.eq(l.bestSoloSeconds, 1000)
		T.eq(#l.challenges, 1)
		T.eq(l.challenges[1], "Speed Herd")
	end)
	T.it("a faster Best Solo on the same tier counts; no change = nothing", function()
		local after = {
			gems = before.gems,
			ladder = { unlocked = 3, bestSolo = 2, bestSoloTime = 700 },
			challenges = before.challenges,
		}
		local l = ResultsModel.loot({}, before, after)
		T.eq(l.bestSolo, 2)
		local none = ResultsModel.loot({}, before, before)
		T.eq(#none.gems, 0)
		T.eq(none.tierUnlocked, nil)
		T.eq(none.bestSolo, nil)
		T.eq(#ResultsModel.loot(nil, nil, nil).gems, 0)
	end)
	T.it("a server `loot` table wins", function()
		local l = ResultsModel.loot(
			{ loot = { gems = { { id = 9 } }, tierUnlocked = 5, challenges = { { name = "X" } } } },
			nil,
			nil
		)
		T.eq(#l.gems, 1)
		T.eq(l.tierUnlocked, 5)
		T.eq(l.challenges[1], "X")
	end)
	T.it("extractions read 'Extracted · secured X' instead of a placement", function()
		T.eq(
			ResultsModel.placementText({ result = "extracted", secured = 120 }),
			"Extracted · secured 🧀 120"
		)
		T.eq(ResultsModel.placementText({ lastHerd = true }), "Extracted")
		T.eq(ResultsModel.placementText({ result = "eliminated" }), nil)
	end)
end)

T.describe("T-14 Prestige banner", function()
	T.it("title, bonus and an Ascension line", function()
		local title, lines = ToastQueue.prestige(3, 2)
		T.eq(title, "⭐ PRESTIGE 3!")
		T.truthy(string.find(lines[1], "+1 perk point", 1, true) ~= nil)
		T.truthy(string.find(lines[3], "Ascension node 2", 1, true) ~= nil)
		local _, l2 = ToastQueue.prestige(20, nil)
		T.falsy(string.find(l2[1], "perk point", 1, true))
		T.eq(#l2, 2)
		-- the server's Prestige toast joins an open banner
		local q = ToastQueue.new()
		q:beginBanner()
		T.eq(q:push("⭐ Prestige 3! +300 cheese", "good", false), "banner")
	end)
end)

T.describe("T-17 Custom tile", function()
	T.it("opens once Sharp is cleared (tier 4 unlocked)", function()
		T.falsy(LadderModel.customOpen({ ladder = { unlocked = 3 } }))
		T.truthy(LadderModel.customOpen({ ladder = { unlocked = 4 } }))
		T.falsy(LadderModel.customOpen(nil))
		for _, t in LadderModel.FALLBACK do
			T.falsy(string.find(t.blurb, "Pressure", 1, true), t.name)
		end
	end)
end)

return T.finish()
