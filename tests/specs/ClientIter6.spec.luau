-- Iteration 6 client maths (team Client): the Tinkerphant's builds
-- (Util/BuildMath: placement ghost, build Fx intake, HUD counter) and the
-- Normal / Fast pace (Util/LadderModel).
local T = require("../lib/Test")
local BuildMath = require("../../src/client/Util/BuildMath")
local LadderModel = require("../../src/client/Util/LadderModel")
local Classes = require("../../src/shared/Config/Classes")
local ClassAbilities = require("../../src/shared/Config/ClassAbilities")

T.describe("BuildMath kinds", function()
	T.it("reads placement kinds from defs, ids and names", function()
		T.eq(BuildMath.placementKind({ kind = "turret" }), "turret")
		T.eq(BuildMath.placementKind({ kind = "barricade" }), "barricade")
		T.eq(BuildMath.placementKind({ def = { kind = "barricade" } }), "barricade")
		T.eq(BuildMath.placementKind({ kind = "x", id = "tinkerphant_deploy_turret" }), "turret")
		T.eq(BuildMath.placementKind({ kind = "repair" }), nil)
		T.eq(BuildMath.placementKind({ kind = "burst" }), nil)
		T.eq(BuildMath.placementKind(nil), nil)
		T.truthy(BuildMath.isRepair("repair"))
		T.falsy(BuildMath.isRepair("ring"))
	end)

	T.it("matches the Tinkerphant config when it is there", function()
		local def = Classes.get("tinkerphant")
		if def == nil then
			return -- team Builder's class not merged yet
		end
		T.eq(BuildMath.placementKind(def.ability), "turret")
		local alts = ClassAbilities.forClass and ClassAbilities.forClass("tinkerphant") or {}
		local kinds = {}
		for _, e in alts do
			local d = if type(e.def) == "table" then e.def else e
			kinds[tostring(d.kind)] = true
		end
		if next(kinds) then
			T.truthy(kinds.barricade and kinds.repair, "barricade and repair alternates")
		end
	end)
end)

T.describe("BuildMath placement", function()
	T.it("clamps the aim point to the cast range", function()
		local x, z, yaw = BuildMath.placement(0, 0, 0, 50, 30)
		T.near(x, 0, 1e-9)
		T.near(z, 30, 1e-9)
		T.near(yaw, 0, 1e-9)
		x, z = BuildMath.placement(10, 10, 13, 14, 30)
		T.near(x, 13, 1e-9)
		T.near(z, 14, 1e-9)
		local _, _, y2 = BuildMath.placement(0, 0, 5, 0, 30)
		T.near(y2, math.pi / 2, 1e-9)
		local x0, z0, y0 = BuildMath.placement(3, 4, 3, 4, 30)
		T.eq(x0, 3)
		T.eq(z0, 4)
		T.eq(y0, 0)
	end)

	T.it("spans a barricade across the aim line", function()
		local ax, az, bx, bz = BuildMath.barricadeEnds(0, 0, 0, 14)
		-- facing +Z: the wall runs along X
		T.near(math.abs(ax - bx), 14, 1e-9)
		T.near(az, 0, 1e-9)
		T.near(bz, 0, 1e-9)
		ax, az, bx, bz = BuildMath.barricadeEnds(5, 5, math.pi / 2, 10)
		T.near(math.abs(az - bz), 10, 1e-9)
		T.near(ax, 5, 1e-9)
	end)

	T.it("formats the HUD counter and HP bands", function()
		T.eq(BuildMath.counterText("turret", 1, 2), "Turrets 1/2")
		T.eq(BuildMath.counterText("barricade", 0, nil), "Barricades 0/2")
		T.eq(BuildMath.hpBand(1), "high")
		T.eq(BuildMath.hpBand(0.5), "mid")
		T.eq(BuildMath.hpBand(0.1), "low")
	end)
end)

T.describe("BuildMath structure set", function()
	T.it("adds, updates and removes from Fx", function()
		local set = BuildMath.newSet()
		local a, id = BuildMath.applyFx(
			set,
			{ t = "turret", id = 7, owner = 5, x = 1, z = 2, hp = 50, maxHp = 100, ttl = 20 },
			100
		)
		T.eq(a, "add")
		T.eq(id, "7")
		local s = set.items["7"]
		T.eq(s.kind, "turret")
		T.eq(s.owner, 5)
		T.near(s.hpFrac, 0.5)
		T.near(s.expiresAt :: number, 120)
		a = BuildMath.applyFx(set, { t = "turret", id = 7, hpFrac = 0.25 }, 101)
		T.eq(a, "update")
		T.near(set.items["7"].hpFrac, 0.25)
		T.eq(set.items["7"].x, 1)
		a = BuildMath.applyFx(set, { t = "turretGone", id = 7 }, 102)
		T.eq(a, "remove")
		T.eq(set.items["7"], nil)
	end)

	T.it("takes the generic build shape and ignores other Fx", function()
		local set = BuildMath.newSet()
		T.eq(
			BuildMath.applyFx(
				set,
				{ t = "build", kind = "barricade", id = "b1", x = 0, z = 0, dx = 1, dz = 0 },
				0
			),
			"add"
		)
		T.near(set.items.b1.yaw, math.pi / 2, 1e-9)
		T.eq(set.items.b1.len, BuildMath.BARRICADE_LENGTH)
		T.eq(
			BuildMath.applyFx(set, { t = "build", kind = "barricade", id = "b1", phase = "dead" }, 1),
			"remove"
		)
		-- the cast Fx is not a structure
		T.eq(BuildMath.applyFx(set, { t = "ability", kind = "turret", id = 3, x = 0, z = 0 }, 0), nil)
		T.eq(BuildMath.applyFx(set, { t = "hit", id = 3, x = 0, z = 0 }, 0), nil)
		T.eq(BuildMath.applyFx(set, { t = "turret", x = 0, z = 0 }, 0), nil)
		T.eq(next(set.items), nil)
	end)

	T.it("reads Combat/World's build / buildHp / buildEnd Fx", function()
		local set = BuildMath.newSet()
		local spawn = {
			t = "build",
			id = 12,
			kind = "barricade",
			owner = 4,
			squad = 1,
			x = 10,
			z = -3,
			r = 1,
			dx = 1,
			dz = 0,
			half = 7,
			range = 0,
			hpFrac = 1,
			untilT = 50,
		}
		T.eq(BuildMath.applyFx(set, spawn, 38), "add")
		local b = set.items["12"]
		T.eq(b.len, 14)
		T.eq(b.squad, 1)
		T.near(b.expiresAt :: number, 50)
		-- the wall runs along (dx, dz) = +X
		local ax, az, bx, bz = BuildMath.barricadeEnds(b.x, b.z, b.yaw, b.len)
		T.near(math.abs(ax - bx), 14, 1e-9)
		T.near(az - bz, 0, 1e-9)
		T.eq(BuildMath.applyFx(set, { t = "buildHp", id = 12, hpFrac = 0.4 }, 39), "update")
		T.near(set.items["12"].hpFrac, 0.4)
		T.eq(BuildMath.applyFx(set, spawn, 40), "update") -- the 2 s resync
		T.eq(BuildMath.applyFx(set, { t = "buildHp", id = 99, hpFrac = 0.4 }, 39), nil)
		T.eq(
			BuildMath.applyFx(set, { t = "buildEnd", id = 12, kind = "barricade", reason = "destroyed" }, 41),
			"remove"
		)
		T.eq(
			BuildMath.applyFx(set, {
				t = "build",
				id = 5,
				kind = "turret",
				x = 0,
				z = 0,
				dx = 0,
				dz = 0,
				half = 0,
				range = 40,
				hpFrac = 1,
				untilT = 20,
			}, 0),
			"add"
		)
		T.eq(set.items["5"].range, 40)
	end)

	T.it("expires and counts per owner, oldest first", function()
		local set = BuildMath.newSet()
		BuildMath.applyFx(set, { t = "turret", id = 1, owner = 9, x = 0, z = 0, ttl = 5 }, 0)
		BuildMath.applyFx(set, { t = "turret", id = 2, owner = 9, x = 1, z = 0, ttl = 20 }, 1)
		BuildMath.applyFx(set, { t = "barricade", id = 3, owner = 9, x = 2, z = 0, ttl = 12 }, 2)
		BuildMath.applyFx(set, { t = "turret", id = 4, owner = 8, x = 3, z = 0, ttl = 20 }, 3)
		local mine = BuildMath.owned(set, 9, "turret")
		T.eq(#mine, 2)
		T.eq(mine[1].id, "1")
		T.eq(#BuildMath.owned(set, 9, nil), 3)
		T.eq(#BuildMath.expire(set, 5.2, nil), 0) -- a short grace for the server's buildEnd
		local gone = BuildMath.expire(set, 6, nil)
		T.eq(#gone, 1)
		T.eq(gone[1], "1")
		T.eq(#BuildMath.owned(set, 9, "turret"), 1)
	end)

	T.it("reads the HUD counts in several shapes", function()
		local n, cap = BuildMath.hudCount({ turrets = 1, turretCap = 2 }, "turret")
		T.eq(n, 1)
		T.eq(cap, 2)
		n, cap = BuildMath.hudCount({ structures = { turret = { count = 2, max = 2 } } }, "turret")
		T.eq(n, 2)
		T.eq(cap, 2)
		n = BuildMath.hudCount({ builds = { barricades = 1 } }, "barricade")
		T.eq(n, 1)
		n, cap = BuildMath.hudCount({}, "turret")
		T.eq(n, nil)
		T.eq(cap, nil)
	end)
end)

T.describe("Pace (Normal / Fast)", function()
	T.it("normalises pace values", function()
		T.eq(LadderModel.pace("fast"), "fast")
		T.eq(LadderModel.pace("Fast"), "fast")
		T.eq(LadderModel.pace("normal"), "normal")
		T.eq(LadderModel.pace(true), "fast")
		T.eq(LadderModel.pace("turbo"), nil)
		T.eq(LadderModel.pace(nil), nil)
		T.eq(LadderModel.paceLabel("fast"), "Fast")
		T.eq(LadderModel.paceLabel(nil), "Normal")
	end)

	T.it("reads the lobby pace, then the saved setting", function()
		T.eq(LadderModel.lobbyPace({ pace = "fast" }, nil), "fast")
		T.eq(LadderModel.lobbyPace({ ladder = { pace = "fast" } }, nil), "fast")
		T.eq(LadderModel.lobbyPace({}, { settings = { pace = "fast" } }), "fast")
		T.eq(LadderModel.lobbyPace({ pace = "normal" }, { settings = { pace = "fast" } }), "normal")
		T.eq(LadderModel.lobbyPace(nil, nil), "normal")
		-- team Flow's Lobby payload: pace = Run/Pace.view {id, name, fast?, locked?}
		T.eq(LadderModel.lobbyPace({ pace = { id = "fast", name = "Fast", fast = true } }, nil), "fast")
		T.eq(LadderModel.lobbyPace({ pace = { id = "normal" }, ladder = { pace = "fast" } }, nil), "normal")
		T.truthy(LadderModel.paceLocked({ pace = { id = "normal", locked = true } }))
		T.falsy(LadderModel.paceLocked({ pace = "normal" }))
	end)

	T.it("says Fast for a fast Match / Results", function()
		T.truthy(LadderModel.isFast({ pace = "fast" }))
		T.truthy(LadderModel.isFast(nil, { fast = true }))
		T.falsy(LadderModel.isFast({ pace = "normal" }, { pace = "fast" }))
		T.truthy(LadderModel.isFast({}, { pace = "fast" }))
		T.falsy(LadderModel.isFast(nil, nil))
		T.truthy(LadderModel.isFast({ pace = { id = "fast", fast = true } }))
	end)
end)

return T.finish()
