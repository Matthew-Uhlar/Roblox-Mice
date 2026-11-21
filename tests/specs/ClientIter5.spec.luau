-- Iteration 5 client maths (team Client): the rotatable camera (Util/CameraMath,
-- the yaw-aware minimap and objective arrow) and the ability slots
-- (Util/AbilitySlots: unlock levels, old and new data shapes, remote args).
-- Phase B: the damage meter rows (Util/MeterModel), graphics settings
-- (Util/GfxSettings) and the two-way Swap Stand / extra ranks (Util/RunShopModel).
local T = require("../lib/Test")
local CameraMath = require("../../src/client/Util/CameraMath")
local AbilitySlots = require("../../src/client/Util/AbilitySlots")
local Minimap = require("../../src/client/Util/Minimap")
local HudMath = require("../../src/client/Util/HudMath")
local MeterModel = require("../../src/client/Util/MeterModel")
local GfxSettings = require("../../src/client/Util/GfxSettings")
local RunShopModel = require("../../src/client/Util/RunShopModel")
local RunShop = require("../../src/shared/Config/RunShop")

local PI = math.pi

T.describe("CameraMath", function()
	T.it("wraps angles to (-pi, pi]", function()
		T.near(CameraMath.wrap(0), 0)
		T.near(CameraMath.wrap(3 * PI), PI)
		T.near(CameraMath.wrap(-PI), PI)
		T.near(CameraMath.wrap(2 * PI + 0.5), 0.5)
		T.eq(CameraMath.wrap(0 / 0), 0)
	end)

	T.it("lerps the short way round", function()
		local a = CameraMath.lerpAngle(PI - 0.1, -PI + 0.1, 0.5)
		T.near(math.abs(a), PI, 1e-6)
		T.near(CameraMath.approach(0, 1, 1e6, 1), 1, 1e-6)
		T.near(CameraMath.approach(0.3, 1, 10, 0), 0.3, 1e-9)
	end)

	T.it("yaw 0 is the old fixed camera (north-up)", function()
		local x, y, z = CameraMath.offset(0, math.rad(55), 10)
		T.near(x, 0, 1e-9)
		T.truthy(y > 0 and z > 0, "camera above, on the +Z side")
		-- the camera looks toward -Z
		T.near(CameraMath.yawFromLook(0, -1), 0, 1e-9)
		T.eq(CameraMath.yawFromLook(0, 0), 0)
		-- screen right = +X, screen down = +Z
		local wx, wz = CameraMath.screenToWorld(1, 0, 0)
		T.near(wx, 1, 1e-9)
		T.near(wz, 0, 1e-9)
		wx, wz = CameraMath.screenToWorld(0, 1, 0)
		T.near(wx, 0, 1e-9)
		T.near(wz, 1, 1e-9)
	end)

	T.it("offset and look agree at any yaw", function()
		for _, yaw in { 0.4, -1.2, 2.9, PI } do
			local ox, _, oz = CameraMath.offset(yaw, math.rad(55), 20)
			-- the look vector points from the camera to the focus: -offset
			T.near(CameraMath.wrap(CameraMath.yawFromLook(-ox, -oz) - yaw), 0, 1e-9)
		end
	end)

	T.it("screen <-> world round-trips and rotates", function()
		for _, yaw in { 0, 0.7, -2.1, PI / 2 } do
			local wx, wz = CameraMath.screenToWorld(3, -4, yaw)
			local sx, sy = CameraMath.worldToScreen(wx, wz, yaw)
			T.near(sx, 3, 1e-9)
			T.near(sy, -4, 1e-9)
		end
		-- turned 90° left (yaw +pi/2): screen up (0,-1) now points to world -X
		local wx, wz = CameraMath.screenToWorld(0, -1, PI / 2)
		T.near(wx, -1, 1e-9)
		T.near(wz, 0, 1e-9)
		-- and the camera then sits on the +X side, looking toward -X
		local ox, _, oz = CameraMath.offset(PI / 2, math.rad(55), 10)
		T.truthy(ox > 0 and math.abs(oz) < 1e-9)
	end)

	T.it("screenAngle: 0 = up, clockwise", function()
		T.near(CameraMath.screenAngle(0, -1, 0), 0, 1e-9)
		T.near(CameraMath.screenAngle(1, 0, 0), PI / 2, 1e-9)
		-- after turning the view 90° right (yaw -pi/2), world +X is screen up
		T.near(CameraMath.screenAngle(1, 0, -PI / 2), 0, 1e-9)
	end)

	T.it("drag right / stick right turn the view right (yaw down)", function()
		T.truthy(CameraMath.dragYaw(10) < 0)
		T.truthy(CameraMath.stickYaw(1, 0.1) < 0)
		T.truthy(CameraMath.stickYaw(-1, 0.1) > 0)
		T.eq(CameraMath.stickYaw(0.2, 0.1), 0)
		T.near(CameraMath.stickYaw(1, 1), -CameraMath.STICK_SPEED, 1e-9)
	end)

	T.it("steps 45° and snaps to the grid", function()
		local s = CameraMath.STEP
		T.near(CameraMath.stepYaw(0, 1), -s, 1e-9)
		T.near(CameraMath.stepYaw(0, -1), s, 1e-9)
		-- slightly left of north: one step right lands on north first
		T.near(CameraMath.stepYaw(0.2, 1), 0, 1e-9)
		T.near(CameraMath.stepYaw(0.2, -1), s, 1e-9)
		-- eight steps go all the way round
		local y = 0
		for _ = 1, 8 do
			y = CameraMath.stepYaw(y, 1)
		end
		T.near(CameraMath.wrap(y), 0, 1e-6)
	end)

	T.it("touches on the thumbstick side never rotate; clicks vs drags", function()
		T.falsy(CameraMath.touchMayRotate(100, 1000))
		T.truthy(CameraMath.touchMayRotate(700, 1000))
		T.truthy(CameraMath.isClick(2, 0.1))
		T.falsy(CameraMath.isClick(30, 0.1))
		T.falsy(CameraMath.isClick(0, 1.5))
		T.near(CameraMath.twistAngle(0, 0, 1, 1), PI / 4, 1e-9)
	end)
end)

T.describe("Minimap and arrow follow the camera yaw", function()
	T.it("yaw 0 keeps the old projection", function()
		local px, py, clamped = Minimap.project(10, 5, 0, 0, 100, 50)
		local qx, qy, c2 = Minimap.project(10, 5, 0, 0, 100, 50, nil, 0)
		T.near(px, qx)
		T.near(py, qy)
		T.eq(clamped, c2)
	end)

	T.it("up on the radar is up on the screen", function()
		for _, yaw in { 0.5, -1.3, PI } do
			-- a point straight up the screen from the hero, 40 studs away
			local wx, wz = CameraMath.screenToWorld(0, -40, yaw)
			local px, py = Minimap.project(wx, wz, 0, 0, 100, 50, nil, yaw)
			T.near(px, 0, 1e-6)
			T.near(py, -20, 1e-6)
		end
	end)

	T.it("the N mark orbits the rim", function()
		local nx, ny = Minimap.northAt(50, 0)
		T.near(nx, 0, 1e-9)
		T.near(ny, -50, 1e-9)
		-- view turned 90° right: north is on the left of the screen
		nx, ny = Minimap.northAt(50, -PI / 2)
		T.near(nx, -50, 1e-9)
		T.near(ny, 0, 1e-9)
		-- and matches a projected far-north point's direction
		local px, py = Minimap.project(0, -1000, 0, 0, 100, 50, 0, 0.8)
		local mx, my = Minimap.northAt(50, 0.8)
		T.near(math.atan2(px, -py), math.atan2(mx, -my), 1e-6)
	end)

	T.it("objective arrow angle uses the yaw", function()
		T.near(HudMath.arrowAngle(0, 0, 0, -10), 0, 1e-9)
		T.near(HudMath.arrowAngle(0, 0, 10, 0), PI / 2, 1e-9)
		T.near(HudMath.arrowAngle(0, 0, 10, 0, -PI / 2), 0, 1e-9)
		for _, yaw in { 0.3, -2 } do
			T.near(HudMath.arrowAngle(1, 2, 7, -3, yaw), CameraMath.screenAngle(6, -5, yaw), 1e-9)
		end
	end)
end)

T.describe("AbilitySlots", function()
	T.it("unlocks slots at class levels 1 / 10 / 20, all at Prestige", function()
		T.eq(AbilitySlots.count(1, 0), 1)
		T.eq(AbilitySlots.count(9, 0), 1)
		T.eq(AbilitySlots.count(10, 0), 2)
		T.eq(AbilitySlots.count(19, nil), 2)
		T.eq(AbilitySlots.count(20, 0), 3)
		T.eq(AbilitySlots.count(1, 1), 3)
		T.eq(AbilitySlots.count(nil, nil), 1)
		T.eq(AbilitySlots.lockText(1), nil)
		T.eq(AbilitySlots.lockText(2), "Level 10")
		T.eq(AbilitySlots.lockText(3), "Level 20")
	end)

	T.it("reads old and new profile class blocks", function()
		T.deepEq(AbilitySlots.loadout(nil), {})
		T.deepEq(AbilitySlots.loadout({ ability = "alt_a" }), { "alt_a" })
		T.deepEq(AbilitySlots.loadout({ level = 3 }), {})
		local l = AbilitySlots.loadout({ ability = "x", abilities = { "base", "alt_b" } })
		T.eq(l[1], "base")
		T.eq(l[2], "alt_b")
		T.eq(AbilitySlots.loadout({ abilities = { [2] = "alt_b" }, ability = "alt_a" })[1], "alt_a")
		T.eq(AbilitySlots.loadout({ abilities = { "a", "b", "c", "d" } })[4], nil)
		T.eq(AbilitySlots.classCount({ level = 12 }), 2)
		T.eq(AbilitySlots.classCount({ level = 12, abilitySlots = 3 }), 3)
		T.eq(AbilitySlots.classCount({ level = 30, prestige = 2 }), 3)
		T.eq(AbilitySlots.classCount("junk"), 1)
	end)

	T.it("reads old and new HUD payloads", function()
		T.deepEq(AbilitySlots.readyAts({ abilityReadyAt = 12 }), { 12 })
		T.deepEq(
			AbilitySlots.readyAts({ abilityReadyAt = 12, abilityReadyAts = { 12, 15, 0 } }),
			{ 12, 15, 0 }
		)
		T.deepEq(
			AbilitySlots.readyAts({ abilities = { { id = "a", readyAt = 3 }, { id = "b", readyAt = 4 } } }),
			{ 3, 4 }
		)
		T.deepEq(AbilitySlots.readyAts(nil), {})
		T.eq(AbilitySlots.hudCount({ abilityReadyAt = 1 }), nil)
		T.eq(AbilitySlots.hudCount({ abilityReadyAts = { 1, 2 } }), 2)
		T.eq(AbilitySlots.hudCount({ abilitySlots = 3 }), 3)
		T.deepEq(AbilitySlots.hudIds({ abilityIds = { "a", "b" } }), { "a", "b" })
		T.deepEq(AbilitySlots.hudIds({ abilitySlots = 2 }), {})
		T.deepEq(AbilitySlots.cooldowns({ abilityCooldowns = { 8, 12.5 } }), { 8, 12.5 })
		T.deepEq(AbilitySlots.cooldowns({}), {})
	end)

	T.it("tracks a cooldown per slot", function()
		local tr = AbilitySlots.newTrack()
		AbilitySlots.observe(tr, { 110, 104 }, 100)
		local rem, total = AbilitySlots.remaining(tr, 1, 100)
		T.near(rem, 10)
		T.near(total, 10)
		rem, total = AbilitySlots.remaining(tr, 2, 102)
		T.near(rem, 2)
		T.near(total, 4)
		T.eq((AbilitySlots.remaining(tr, 3, 100)), 0)
		T.eq((AbilitySlots.remaining(tr, 1, 111)), 0)
		-- the server's effective cooldown wins over the inferred one
		AbilitySlots.observe(tr, { 110, 104 }, 101, { 12 })
		local _, t1 = AbilitySlots.remaining(tr, 1, 101)
		T.near(t1, 12)
	end)

	T.it("builds remote args an older server still accepts for slot 1", function()
		T.deepEq(AbilitySlots.useArgs(1, 2, nil), { 1, 2 })
		T.deepEq(AbilitySlots.useArgs(1, 2, 1), { 1, 2 })
		T.deepEq(AbilitySlots.useArgs(1, 2, 3), { 1, 2, 3 })
		T.deepEq(AbilitySlots.selectArgs("c", "base", 1, "base"), { "c" })
		T.deepEq(AbilitySlots.selectArgs("c", "alt", 1, "base"), { "c", "alt" })
		T.deepEq(AbilitySlots.selectArgs("c", "base", 2, "base"), { "c", "base", 2 })
	end)

	T.it("key hints per slot and mode", function()
		T.eq(AbilitySlots.keyHint(1, "kbm", true), "Space/Q")
		T.eq(AbilitySlots.keyHint(2, "kbm"), "E")
		T.eq(AbilitySlots.keyHint(3, "kbm"), "R")
		T.eq(AbilitySlots.keyHint(2, "gamepad"), "Y")
		T.eq(AbilitySlots.keyHint(3, "gamepad"), "B")
		T.eq(AbilitySlots.keyHint(1, "touch"), "")
		T.eq(AbilitySlots.slotOf({ nil, "b" } :: any, "base", "base"), 1)
		T.eq(AbilitySlots.slotOf({ "a", "b" }, "b", "base"), 2)
		T.eq(AbilitySlots.slotOf({ "a" }, "z", "base"), nil)
	end)
end)

T.describe("Phase B client models", function()
	T.it("meter rows: sorted, flagged, tolerant", function()
		local rows = MeterModel.rows({
			["12"] = { name = "Ann", squad = 1, dmg = 500, kills = 3 },
			["-1002"] = { name = "Bot", squad = 2, pveDmg = 300, pvpDmg = 400 },
			["7"] = { name = "Cy", squad = 1 },
			junk = "x",
		}, 1, 12)
		T.eq(#rows, 3)
		T.eq(rows[1].name, "Bot")
		T.eq(rows[1].dmg, 700)
		T.truthy(rows[1].bot)
		T.near(rows[1].frac, 1)
		T.eq(rows[2].name, "Ann")
		T.truthy(rows[2].me and rows[2].mine)
		T.near(rows[2].frac, 500 / 700)
		T.eq(rows[3].dmg, 0)
		T.eq(rows[3].rank, 3)
		T.eq(MeterModel.label(rows[1]), "🤖 Bot")
		T.eq(MeterModel.label(rows[2]), "Ann (you)")
		T.deepEq(MeterModel.rows(nil, 1, 1), {})
		T.eq(#MeterModel.rows({ [5] = { dmg = 0 / 0 } }, nil, nil), 1)
	end)

	T.it("meter top keeps you below the cut", function()
		local m = {}
		for i = 1, 12 do
			m[i] = { name = "H" .. i, dmg = 100 - i }
		end
		local rows = MeterModel.top(MeterModel.rows(m, nil, 12), 8)
		T.eq(#rows, 9)
		T.eq(rows[9].id, 12)
		T.eq(MeterModel.short(950), "950")
		T.eq(MeterModel.short(12345), "12k")
		T.eq(MeterModel.short(1500), "1.5k")
		T.eq(MeterModel.short(4.5e6), "4.5M")
	end)

	T.it("graphics settings", function()
		T.deepEq(GfxSettings.fromProfile(nil), { fx = "full", decor = "full" })
		T.deepEq(
			GfxSettings.fromProfile({ settings = { fx = "off", decor = "low" } }),
			{ fx = "off", decor = "low" }
		)
		T.deepEq(
			GfxSettings.fromProfile({ settings = { fx = "weird", decor = true } }),
			{ fx = "full", decor = "full" }
		)
		local m, b = GfxSettings.particles("full", false)
		T.eq(m, 1)
		T.eq(b, 900)
		m, b = GfxSettings.particles("reduced", true)
		T.near(m, 0.2)
		T.eq(b, 100)
		m, b = GfxSettings.particles("off", false)
		T.eq(m, 0)
		T.eq(b, 0)
		T.truthy(GfxSettings.lowFx("reduced", false))
		T.falsy(GfxSettings.lowFx("full", false))
		T.eq(GfxSettings.nextOf(GfxSettings.FX, "off"), "full")
	end)

	T.it("two-way swap preview and the fee", function()
		T.eq(RunShopModel.swapBackPreview(RunShop, 10), RunShop.swapBack(10))
		T.eq(RunShopModel.swapBackPreview(RunShop, 0), 0)
		T.eq(RunShopModel.swapBackPreview({ SWAP_RATE = 5 }, 10), nil) -- an older config: no way back
		T.eq(RunShopModel.swapBackPreview({ SWAP_RATE = 5, SWAP_BACK_RATE = 0.8 }, 10), 40)
		T.eq(RunShopModel.swapBackFeePct({ SWAP_BACK_RATE = 0.8 }), 20)
	end)

	T.it("ranks missing from RANK_ORDER are listed after it", function()
		local cfg = {
			RANK_ORDER = { "might" },
			RANKS = {
				might = { name = "Might", base = 10, step = 1 },
				quick_study = { name = "Quick Study", base = 10, step = 1 },
			},
			MAX_RANK = 100,
		}
		local rows = RunShopModel.ranks(cfg, { rinds = 50, ranks = {} })
		T.eq(#rows, 2)
		T.eq(rows[2].name, "Quick Study")
		T.truthy(#RunShopModel.ranks(RunShop, {}) >= #RunShop.RANK_ORDER)
	end)
end)

return T.finish()
