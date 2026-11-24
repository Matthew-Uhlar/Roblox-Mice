-- Iteration 7 client maths (team Client): hold-to-aim preview geometry
-- (Util/AimPreview), game feel (Util/GameFeel: hit-stop, shakes, settings, cast
-- sounds), the death recap card (Util/RecapModel), downed-squadmate edge
-- arrows (Util/SquadAlerts), talent presets (Util/TalentPresets) and gem tiers 13-14.
local T = require("../lib/Test")
local AimPreview = require("../../src/client/Util/AimPreview")
local GameFeel = require("../../src/client/Util/GameFeel")
local RecapModel = require("../../src/client/Util/RecapModel")
local SquadAlerts = require("../../src/client/Util/SquadAlerts")
local TalentPresets = require("../../src/client/Util/TalentPresets")
local GemModel = require("../../src/client/Util/GemModel")
local Layout = require("../../src/client/Util/Layout")
local Classes = require("../../src/shared/Config/Classes")
local ClassAbilities = require("../../src/shared/Config/ClassAbilities")
local Gems = require("../../src/shared/Config/Gems")

T.describe("AimPreview shapes", function()
	T.it("maps every kind to its form", function()
		local cases = {
			{ "burst", "circle" },
			{ "vortex", "circle" },
			{ "mark", "circle" },
			{ "field", "circle" },
			{ "puddle", "circle" },
			{ "dash", "line" },
			{ "lance", "line" },
			{ "chain", "path" },
			{ "tether", "path" },
			{ "leap", "leap" },
			{ "turret", "ghost" },
			{ "barricade", "ghost" },
			{ "cone", "cone" },
			{ "ring", "self" },
			{ "shield", "self" },
			{ "hover", "self" },
			{ "repair", "self" },
			{ "anchor", "self" },
		}
		for _, c in cases do
			T.eq(AimPreview.shapeFor({ kind = c[1], area = 6 }).form, c[2], c[1])
		end
		T.eq(AimPreview.shapeFor({ kind = "brandnew", area = 5, distance = 20 }).form, "circle")
		T.eq(AimPreview.shapeFor({ kind = "brandnew", area = 5 }).form, "self")
		T.eq(AimPreview.shapeFor(nil).form, "circle")
	end)

	T.it("reads ranges, widths and defaults from the def", function()
		local lance = AimPreview.shapeFor({ kind = "lance", area = 1.5, distance = 90 })
		T.eq(lance.range, 90)
		T.eq(lance.width, 3)
		local dash = AimPreview.shapeFor({ kind = "dash", area = 6 })
		T.eq(dash.range, AimPreview.DEFAULT_RANGE.dash)
		T.eq(dash.width, 12)
		local leap = AimPreview.shapeFor({ kind = "leap", area = 9, distance = 28 })
		T.eq(leap.range, 28)
		T.eq(leap.radius, 9)
		local ring = AimPreview.shapeFor({ kind = "ring", area = 14 })
		T.eq(ring.range, 14)
		local anchor = AimPreview.shapeFor({ kind = "anchor", area = 0 })
		T.truthy(anchor.radius > 0, "a stance still shows a footprint")
		local turret = AimPreview.shapeFor({ kind = "turret", area = 40, distance = 30 })
		T.eq(turret.ghost, "turret")
		T.eq(turret.range, 30)
		local cone = AimPreview.shapeFor({ kind = "cone", area = 70 })
		T.eq(cone.angle, 70)
	end)

	T.it("covers every ability in the configs", function()
		local n = 0
		for _, id in Classes.ORDER do
			for _, e in ClassAbilities.forClass(id) do
				local d = e.def :: any
				local s = AimPreview.shapeFor(d)
				T.truthy(s.range >= 0 and s.radius >= 0, tostring(d.kind))
				-- aimed kinds always have a real cast range
				if s.form ~= "self" then
					T.truthy(s.range > 0, "range for " .. tostring(d.id))
				end
				n += 1
			end
		end
		T.truthy(n >= 50, "every class ability seen (" .. n .. ")")
	end)
end)

T.describe("AimPreview geometry", function()
	T.it("clamps an area to the cast range", function()
		local s = AimPreview.shapeFor({ kind = "burst", area = 12, distance = 40 })
		local g = AimPreview.geometry(s, 0, 0, 0, 100)
		T.near(g.cx, 0, 1e-9)
		T.near(g.cz, 40, 1e-9)
		T.eq(g.radius, 12)
		g = AimPreview.geometry(s, 0, 0, 3, 4)
		T.near(g.cx, 3, 1e-9)
		T.near(g.cz, 4, 1e-9)
		T.near(g.length, 5, 1e-9)
	end)

	T.it("draws a fixed-length line for dash and lance", function()
		local s = AimPreview.shapeFor({ kind = "lance", area = 1.5, distance = 90 })
		local g = AimPreview.geometry(s, 10, 10, 13, 14) -- close aim: still the full line
		T.near(g.length, 90, 1e-9)
		T.near(g.toX, 10 + 90 * 0.6, 1e-6)
		T.near(g.toZ, 10 + 90 * 0.8, 1e-6)
		T.near(g.yaw, math.atan2(3, 4), 1e-9)
	end)

	T.it("ends a path / landing at the clamped aim", function()
		local leap = AimPreview.shapeFor({ kind = "leap", area = 9, distance = 26 })
		local g = AimPreview.geometry(leap, 0, 0, 100, 0)
		T.near(g.cx, 26, 1e-9)
		T.near(g.toX, 26, 1e-9)
		T.eq(g.form, "leap")
		local chain = AimPreview.shapeFor({ kind = "chain", area = 13, distance = 36 })
		g = AimPreview.geometry(chain, 0, 0, 0, -10)
		T.near(g.cz, -10, 1e-9)
		T.eq(g.radius, 13)
	end)

	T.it("keeps self shapes on the hero", function()
		local s = AimPreview.shapeFor({ kind = "ring", area = 14 })
		local g = AimPreview.geometry(s, 5, 6, 50, 50)
		T.eq(g.cx, 5)
		T.eq(g.cz, 6)
		T.eq(g.radius, 14)
	end)

	T.it("opens a cone symmetric around the aim", function()
		local s = AimPreview.shapeFor({ kind = "cone", area = 90, distance = 20 })
		local g = AimPreview.geometry(s, 0, 0, 0, 5)
		local lx, lz, rx, rz = AimPreview.coneEdges(g)
		T.near(lx, -rx, 1e-6)
		T.near(lz, rz, 1e-6)
		T.near(math.sqrt(lx * lx + lz * lz), 20, 1e-6)
	end)

	T.it("tells a tap from a hold", function()
		T.falsy(AimPreview.isHold(0.05))
		T.falsy(AimPreview.isHold(AimPreview.HOLD_TIME - 0.01))
		T.truthy(AimPreview.isHold(AimPreview.HOLD_TIME))
		T.truthy(AimPreview.isHold(1))
	end)

	T.it("scales a stick / drag aim into the range", function()
		local x, z = AimPreview.stickPoint(0, 0, 1, 0, 1, 30)
		T.near(x :: number, 30, 1e-9)
		T.near(z :: number, 0, 1e-9)
		x = AimPreview.stickPoint(0, 0, 2, 0, 0.5, 30)
		T.near(x :: number, 15, 1e-9)
		x = AimPreview.stickPoint(0, 0, 1, 0, 0, 30)
		T.near(x :: number, AimPreview.MIN_STICK, 1e-9)
		x = AimPreview.stickPoint(0, 0, 1, 0, 5, 30)
		T.near(x :: number, 30, 1e-9, "deflection clamps to 1")
		T.eq(AimPreview.stickPoint(0, 0, 0, 0, 1, 30), nil)
	end)

	T.it("always keeps the outline; only the fill follows Effects", function()
		T.eq(AimPreview.fillAlpha("off"), nil)
		T.truthy(AimPreview.fillAlpha("reduced") ~= nil)
		T.truthy((AimPreview.fillAlpha("full") :: number) < (AimPreview.fillAlpha("reduced") :: number))
	end)
end)

T.describe("GameFeel", function()
	T.it("respects the shake setting and Effects off", function()
		T.eq(GameFeel.shakeMult("full", "full"), 1)
		T.truthy(GameFeel.shakeMult("low", "full") > 0 and GameFeel.shakeMult("low", "full") < 1)
		T.eq(GameFeel.shakeMult("off", "full"), 0)
		T.eq(GameFeel.shakeMult("full", "off"), 0)
		T.eq(GameFeel.shakeMult("full", "reduced"), 1)
		T.eq(GameFeel.shake("weird"), "full")
		T.eq(GameFeel.shake("off"), "off")
	end)

	T.it("reads the setting from the profile, a local pick wins", function()
		T.deepEq(GameFeel.fromProfile(nil, nil), { shake = "full", castSfx = "full" })
		T.deepEq(
			GameFeel.fromProfile({ settings = { shake = "low", castSfx = "off" } }, nil),
			{ shake = "low", castSfx = "off" }
		)
		T.deepEq(
			GameFeel.fromProfile({ settings = { shake = "low" } }, { shake = "off" }),
			{ shake = "off", castSfx = "full" }
		)
	end)

	T.it("hit-stops only on own big hits and big kills", function()
		local me = 7
		T.eq(GameFeel.hitStopFor({ t = "hit", by = 8, amount = 999, crit = true }, me), 0)
		T.eq(GameFeel.hitStopFor({ t = "hit", by = me, amount = 10, crit = true }, me), 0)
		T.eq(GameFeel.hitStopFor({ t = "hit", by = me, amount = 80, crit = true }, me), GameFeel.HITSTOP_HIT)
		T.eq(GameFeel.hitStopFor({ t = "hit", by = me, amount = 80 }, me), 0)
		T.eq(GameFeel.hitStopFor({ t = "die", by = me, kind = "squeaker" }, me), 0)
		T.eq(GameFeel.hitStopFor({ t = "die", by = me, kind = "x" }, me, true), GameFeel.HITSTOP_KILL)
		T.truthy(GameFeel.HITSTOP_KILL <= GameFeel.HITSTOP_MAX)
		T.falsy(GameFeel.mayStop(10, 10.1))
		T.truthy(GameFeel.mayStop(10, 10 + GameFeel.HITSTOP_MIN_GAP))
	end)

	T.it("scales impact shakes, small and capped", function()
		T.eq(GameFeel.impactShake(0), 0)
		T.eq(GameFeel.impactShake(5), 0)
		local a = GameFeel.impactShake(60)
		local b = GameFeel.impactShake(150)
		T.truthy(b > a and a > 0)
		T.truthy(GameFeel.impactShake(60, true) > a)
		T.eq(GameFeel.impactShake(1e6), GameFeel.SHAKE_MAX)
		T.truthy(GameFeel.impactShake(20, false, true) > GameFeel.impactShake(20, false, false))
	end)

	T.it("gives each kind and class its own cast sound", function()
		local seen = {}
		for kind, pair in GameFeel.KIND_SOUND do
			local key = pair[1] .. "@" .. tostring(pair[2])
			T.falsy(seen[key], "duplicate sound for " .. kind)
			seen[key] = true
		end
		local own = GameFeel.castSounds("leap", "elephante", true)
		T.eq(#own, 2)
		T.eq(own[2].key, "trumpet")
		T.eq(#GameFeel.castSounds("leap", "elephante", false), 1)
		local pitches = {}
		for id, p in GameFeel.CLASS_PITCH do
			T.falsy(pitches[p], "two classes share a trumpet pitch: " .. id)
			pitches[p] = true
		end
		for _, id in Classes.ORDER do
			T.truthy(GameFeel.CLASS_PITCH[id] ~= nil, "class signature for " .. id)
		end
		T.eq(GameFeel.castSounds("unknown", "newclass", true)[1].key, "boom")
		T.eq(GameFeel.castVolume("off"), 0)
	end)
end)

T.describe("Death recap card", function()
	local sample = {
		eliminated = false,
		by = { cat = "champion", name = "Rat King", kind = "rat_king" },
		top = {
			{ cat = "mouse", name = "Squeaker", amount = 40.4 },
			{ cat = "champion", name = "Rat King", amount = 120 },
			{ cat = "hero", name = "Bob", isBot = true, id = -1001, amount = 75 },
			{ cat = "storm", name = "The Melt (storm)", amount = 5 },
		},
		window = 10,
		t = 100,
	}

	T.it("renders from a sample payload", function()
		local v = RecapModel.view(sample) :: any
		T.truthy(v ~= nil)
		T.eq(v.title, "🩹 Downed by Rat King")
		T.eq(#v.rows, 3)
		T.eq(v.rows[1].name, "Rat King")
		T.eq(v.rows[1].frac, 1)
		T.eq(v.rows[2].name, "🤖 Bob", "bots are labelled")
		T.eq(v.rows[3].amount, 40)
		T.eq(v.sub, "Top damage, last 10s")
	end)

	T.it("names the killer when eliminated, and tolerates junk", function()
		local v = RecapModel.view({
			eliminated = true,
			by = { cat = "mouse", name = "Squeaker" },
			killer = { cat = "hero", name = "Alice" },
		}) :: any
		T.eq(v.title, "💀 Eliminated by Alice")
		T.eq(#v.rows, 0)
		T.eq(v.sub, "No damage recorded")
		T.eq(RecapModel.view(nil), nil)
		T.truthy(RecapModel.view({ top = { "x", { amount = "y" } } }) ~= nil)
	end)

	T.it("keeps the card readable", function()
		local U = RecapModel.UI
		for _, pair in { { U.titleText, U.titleBox }, { U.subText, U.subBox }, { U.rowText, U.rowH } } do
			T.truthy(pair[1] >= Layout.MENU_MIN_TEXT_PX, "text >= 13 px")
			T.truthy(pair[2] >= pair[1] * 1.3, "box fits its text")
		end
		T.truthy(RecapModel.height(3) > RecapModel.height(1))
	end)
end)

T.describe("Downed squadmate arrows", function()
	T.it("lists downed mates but never me", function()
		local party = {
			[1] = { name = "Me", downed = true },
			[2] = { name = "Ann", downed = true, downedUntil = 50 },
			[3] = { name = "Ben", downed = false },
			["4"] = { name = "Cid", downed = true },
		}
		local list = SquadAlerts.downedMates(party, 1)
		T.eq(#list, 2)
		T.eq(list[1].name, "Ann")
		T.eq(list[1].downedUntil, 50)
		T.eq(list[2].id, 4)
		T.eq(#SquadAlerts.downedMates(nil, 1), 0)
	end)

	T.it("finds the newest revive ping", function()
		local pings = {
			{ kind = "revive", by = 2, x = 1, z = 1, t = 90 },
			{ kind = "revive", by = 2, x = 5, z = 6, t = 95 },
			{ kind = "go", by = 2, x = 9, z = 9, t = 99 },
		}
		local x, z = SquadAlerts.revivePos(pings, 2, 100)
		T.eq(x, 5)
		T.eq(z, 6)
		T.eq(SquadAlerts.revivePos(pings, 2, 200), nil, "stale pings are ignored")
		T.eq(SquadAlerts.revivePos(pings, 3, 100), nil)
	end)

	T.it("clamps arrows to the screen edge", function()
		local w, h, m = 1280, 720, 34
		T.eq(SquadAlerts.arrow(640, 360, false, w, h, m), nil, "on screen: no arrow")
		local x, y, ang = SquadAlerts.arrow(5000, 360, false, w, h, m)
		T.near(x :: number, w - m, 1e-6)
		T.near(y :: number, 360, 1e-6)
		T.near(ang :: number, 0, 1e-6)
		x, y = SquadAlerts.arrow(640, -9000, false, w, h, m)
		T.near(y :: number, m, 1e-6)
		x, y = SquadAlerts.arrow(-300, 2000, false, w, h, m, 40, 60)
		T.truthy((x :: number) >= m and (x :: number) <= w - m)
		T.truthy((y :: number) >= m + 40 and (y :: number) <= h - m - 60, "safe bands")
		-- behind the camera: flipped, still on the edge
		x, y = SquadAlerts.arrow(640, 100, true, w, h, m)
		T.near(y :: number, h - m, 1e-6)
		T.eq(SquadAlerts.label("Ann", 41.6, 59.2, 50), "Ann · 42m · 10s")
		T.eq(SquadAlerts.label("Ann", nil, nil, nil), "Ann")
	end)
end)

T.describe("Talent presets", function()
	T.it("shows empty, saved, current and invalid slots", function()
		local view = {
			presets = {
				{ perks = { a = true, b = true }, points = 2, valid = true },
				{},
			},
		}
		local s = TalentPresets.slots(view, { a = true, b = true })
		T.eq(#s, 2)
		T.truthy(s[1].current)
		T.eq(s[1].text, "Build 1 · 2 pts")
		T.truthy(s[2].empty)
		T.eq(s[2].text, "Build 2 · empty")
		T.falsy(TalentPresets.canLoad(s[1], true), "already current")
		T.falsy(TalentPresets.canLoad(s[2], true), "empty")
		local s2 = TalentPresets.slots(view, { a = true })
		T.truthy(TalentPresets.canLoad(s2[1], true))
		T.falsy(TalentPresets.canLoad(s2[1], false), "lobby only")
		T.truthy(TalentPresets.needsConfirm(s2[1]))
		T.falsy(TalentPresets.needsConfirm(s2[2]))
		local bad = TalentPresets.slots(
			{ presets = { { perks = { a = true }, points = 1, valid = false } } },
			{}
		)
		T.falsy(TalentPresets.canLoad(bad[1], true), "no longer fits")
		T.eq(#TalentPresets.slots(nil, nil), 2)
	end)
end)

T.describe("Gem tiers 13-14", function()
	T.it("parses, colours and names the new tiers", function()
		T.eq(GemModel.MAX_TIER, math.max(14, Gems.MAX_TIER))
		local g = GemModel.gem({ id = 1, tier = 14 })
		T.eq((g :: any).tier, 14)
		T.eq((GemModel.gem({ id = 2, tier = 99 }) :: any).tier, GemModel.MAX_TIER)
		local c13, c14, c12 = GemModel.tierColor(13), GemModel.tierColor(14), GemModel.tierColor(12)
		T.falsy(c13[1] == c12[1] and c13[2] == c12[2], "13 differs from 12")
		T.falsy(c14[1] == c13[1] and c14[2] == c13[2], "14 differs from 13")
		if Gems.TIER_NAMES then
			T.eq(Gems.TIER_NAMES[13], "Midnight Wheel")
			T.eq(Gems.TIER_NAMES[14], "Eternal Wheel")
		end
	end)
end)

return T.finish()
