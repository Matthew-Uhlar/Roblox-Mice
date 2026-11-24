-- Iteration 8 client maths (team Client): keybinds (Util/Keybinds over Shared
-- Data/Settings), phone smart-cast (Util/SmartCast), rind income on Results
-- (ResultsModel.rindLine), key hints that follow the binds (AbilitySlots) and
-- the 12th difficulty tier (LadderModel).
local T = require("../lib/Test")
local Keybinds = require("../../src/client/Util/Keybinds")
local SmartCast = require("../../src/client/Util/SmartCast")
local ResultsModel = require("../../src/client/Util/ResultsModel")
local AbilitySlots = require("../../src/client/Util/AbilitySlots")
local LadderModel = require("../../src/client/Util/LadderModel")
local Settings = require("../../src/shared/Data/Settings")
local Difficulty = require("../../src/shared/Config/Difficulty")

T.describe("Keybinds", function()
	T.it("labels every action and starts from the defaults", function()
		for _, a in Settings.BIND_ACTIONS do
			T.truthy(Keybinds.LABEL[a], "label for " .. a)
		end
		local d = Keybinds.defaults(Settings)
		T.eq(d.ability1, "Space")
		T.eq(d.ability2, "E")
		T.eq(d.meter, "Tab")
		T.eq(next(Keybinds.conflicts(Settings, d)), nil, "defaults never conflict")
		T.eq(Keybinds.encode(Settings, d), nil, "defaults are stored as nil")
	end)

	T.it("swaps on a conflict, refuses unknown keys, round-trips", function()
		local d = Keybinds.defaults(Settings)
		local m, swapped = Keybinds.assign(Settings, d, "ability2", "R")
		T.eq(m.ability2, "R")
		T.eq(swapped, "ability3")
		T.eq(m.ability3, "E", "the other action takes the old key")
		T.eq(next(Keybinds.conflicts(Settings, m)), nil)
		local same = Keybinds.assign(Settings, d, "ability2", "W") -- movement: not bindable
		T.eq(same.ability2, "E")
		local s = Keybinds.encode(Settings, m) :: string
		T.truthy(Settings.validBinds(s))
		local back = Keybinds.fromProfile(Settings, { settings = { binds = s } }, nil)
		T.eq(back.ability2, "R")
		T.eq(back.ability3, "E")
		-- a local pick wins over the profile
		T.eq(
			Keybinds.fromProfile(Settings, { settings = { binds = s } }, Settings.DEFAULT_BINDS).ability2,
			"E"
		)
	end)

	T.it("finds conflicts in a hand-made map", function()
		local d = Keybinds.defaults(Settings)
		d.ping = "Tab"
		local c = Keybinds.conflicts(Settings, d)
		T.eq(c.ping, "meter")
		T.eq(c.meter, "ping")
	end)

	T.it("short key labels and hints per device", function()
		T.eq(Keybinds.keyLabel("Comma"), ",")
		T.eq(Keybinds.keyLabel("LeftShift"), "LShift")
		T.eq(Keybinds.keyLabel("Five"), "5")
		T.eq(Keybinds.keyLabel("V"), "V")
		local d = Keybinds.defaults(Settings)
		T.eq(Keybinds.hint(d, "runShop", "kbm"), "V")
		T.eq(Keybinds.hint(d, "runShop", "touch"), "")
		T.eq(Keybinds.hint(d, "runShop", "gamepad", "Y"), "Y")
	end)

	T.it("ability key hints follow the binds", function()
		T.eq(AbilitySlots.keyHint(2, "kbm"), "E")
		T.eq(AbilitySlots.keyHint(1, "kbm", true), "Space/Q")
		local labels = AbilitySlots.bindLabels(function(action: string, fallback: string?): string
			return if action == "ability2"
				then "F1"
				elseif action == "ability1" then "LShift"
				else fallback or "?"
		end)
		T.eq(AbilitySlots.keyHint(2, "kbm", false, labels), "F1")
		T.eq(AbilitySlots.keyHint(1, "kbm", false, labels), "LShift / Q / RMB")
		T.eq(AbilitySlots.keyHint(2, "gamepad", false, labels), "Y")
	end)
end)

T.describe("SmartCast", function()
	local base = {
		enabled = true,
		touch = true,
		inCombat = true,
		downed = false,
		ready = true,
		targetDist = 10,
		rivalDist = nil,
		sinceManual = 10,
	}
	local function with(over: { [string]: any }): any
		local t = table.clone(base)
		for k, v in over do
			t[k] = v
		end
		return t
	end
	T.it("casts at a target in range", function()
		T.truthy(SmartCast.shouldCast(base))
	end)
	T.it("stays off when it should", function()
		T.falsy(SmartCast.shouldCast(with({ enabled = false })))
		T.falsy(SmartCast.shouldCast(with({ touch = false })))
		T.falsy(SmartCast.shouldCast(with({ downed = true })))
		T.falsy(SmartCast.shouldCast(with({ ready = false })))
		T.falsy(SmartCast.shouldCast(with({ targetDist = SmartCast.RANGE + 1 })))
		T.falsy(SmartCast.shouldCast(with({ sinceManual = 0.2 })), "right after a manual cast")
		T.falsy(SmartCast.shouldCast(with({ rivalDist = 20 })), "off in a PvP fight")
		T.truthy(SmartCast.shouldCast(with({ rivalDist = SmartCast.PVP_RADIUS + 5 })))
		local none = with({})
		none.targetDist = nil
		T.falsy(SmartCast.shouldCast(none))
	end)
	T.it("is saved as a boolean setting", function()
		T.truthy(table.find(Settings.BOOL_KEYS, "smartCast"))
		T.eq(select(2, Settings.validate("smartCast", true)), true)
		T.eq((Settings.validate("smartCast", "on")), false)
	end)
end)

T.describe("Results rind income", function()
	T.it("lists the top 3 sources", function()
		local line = ResultsModel.rindLine({
			rindsEarned = 400,
			rindSources = { kill = 210, share = 80, miniboss = 60, champion = 50 },
		})
		T.eq(line, "🧀 Rinds 400: stomps 210 · squad share 80 · minibosses 60")
	end)
	T.it("falls back to the total, or nothing", function()
		T.eq(ResultsModel.rindLine({ rindsEarned = 123 }), "🧀 Rinds earned: 123")
		T.eq(ResultsModel.rindLine({}), nil)
		T.eq(ResultsModel.rindLine(nil), nil)
		T.eq(ResultsModel.rindLine({ rindSources = { newKind = 5 } }), "🧀 Rinds 5: newKind 5")
	end)
end)

T.describe("Difficulty ladder: 12 tiers", function()
	T.it("the fallback and the config both reach tier 12 with a colour", function()
		T.eq(#LadderModel.FALLBACK, 12)
		local tiers = LadderModel.tiers(Difficulty)
		local top = tiers[#tiers]
		T.truthy(top.tier >= 11)
		for _, t in tiers do
			T.eq(type(t.color), "table", "colour for tier " .. t.tier)
			T.eq(#t.color, 3)
		end
		if top.tier == 12 then
			T.eq(LadderModel.name(Difficulty, 12), top.name)
		end
	end)
end)

return T.finish()
