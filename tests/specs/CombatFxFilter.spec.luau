--!strict
-- Combat/FxFilter: per-client Fx and snapshot culling (bandwidth).
local T = require("../lib/Test")
local FxFilter = require("../../src/shared/Combat/FxFilter")

local R = FxFilter.RADIUS

local function kinds(list: { any }): string
	local out = {}
	for _, f in list do
		table.insert(out, f.t .. (if f.tag then ":" .. f.tag else ""))
	end
	return table.concat(out, ",")
end

T.describe("FxFilter.forViewer", function()
	T.it("drops far point events, keeps near ones and every state event", function()
		local batch = {
			{ t = "die", x = 10, z = 0, tag = "near" },
			{ t = "die", x = R + 50, z = 0, tag = "far" },
			{ t = "boom", x = R + 3, z = 0, r = 5, tag = "edge" }, -- radius pad keeps it
			{ t = "tele", shape = "circle", x = 999, z = 0, r = 5, delay = 1 },
			{ t = "zone", id = 1, x = 999, z = 0, r = 4, ttl = 3, hostile = true },
			{ t = "enrage", id = 7, x = 999, z = 0 },
			{ t = "pickupTaken", id = 3, by = 2 },
		}
		T.eq(kinds(FxFilter.forViewer(batch, 0, 0)), "die:near,boom:edge,tele,zone,enrage,pickupTaken")
	end)
	T.it("plain damage numbers use the shorter HIT_RADIUS; crits use RADIUS", function()
		local far = FxFilter.HIT_RADIUS + 10
		local out = FxFilter.forViewer({
			{ t = "hit", x = far, z = 0, amount = 5, crit = false, tag = "plain" },
			{ t = "hit", x = far, z = 0, amount = 50, crit = true, tag = "crit" },
		}, 0, 0)
		T.eq(kinds(out), "hit:crit")
	end)
	T.it("a projectile is kept when its path enters the radius", function()
		local inbound = { t = "proj", x = R + 80, z = 0, vx = -40, vz = 0, ttl = 3, r = 1, tag = "in" }
		local away = { t = "proj", x = R + 80, z = 0, vx = 40, vz = 0, ttl = 3, r = 1, tag = "away" }
		T.eq(kinds(FxFilter.forViewer({ inbound, away }, 0, 0)), "proj:in")
	end)
	T.it("chains are kept when the segment passes near the viewer", function()
		local out = FxFilter.forViewer({
			{ t = "chain", x1 = -500, z1 = 0, x2 = 500, z2 = 0, tag = "through" },
			{ t = "chain", x1 = 500, z1 = 500, x2 = 510, z2 = 500, tag = "far" },
		}, 0, 0)
		T.eq(kinds(out), "chain:through")
	end)
	T.it("the viewer's own hurt flash is always kept", function()
		local out = FxFilter.forViewer({
			{ t = "hurt", id = 5, x = 900, z = 0, amount = 3, tag = "me" },
			{ t = "hurt", id = 6, x = 900, z = 0, amount = 3, tag = "other" },
		}, 0, 0, nil, 5)
		T.eq(kinds(out), "hurt:me")
	end)
	T.it(
		"other heroes' swings, chains, booms and hurt flashes use NEAR_RADIUS; attacker and victim always see theirs",
		function()
			local mid = (FxFilter.NEAR_RADIUS + R) / 2 -- between NEAR_RADIUS and RADIUS
			local batch = {
				{ t = "melee", id = 5, x = mid, z = 0, dx = 1, dz = 0, r = 4, arc = 150, tag = "other" },
				{ t = "melee", id = 9, x = mid, z = 0, dx = 1, dz = 0, r = 4, arc = 150, tag = "mine" },
				{ t = "chain", id = 5, x1 = mid, z1 = 0, x2 = mid + 5, z2 = 0, tag = "other" },
				{ t = "boom", id = 5, x = mid, z = 0, r = 4, tag = "hero" },
				{ t = "boom", x = mid, z = 0, r = 4, kind = "fuse", tag = "mouse" },
				{ t = "hurt", id = 5, by = 6, amount = 3, x = mid, z = 0, tag = "pvp" },
				{ t = "hurt", id = 5, by = 9, amount = 3, x = mid, z = 0, tag = "myHit" },
				{ t = "hurt", id = 9, by = 6, amount = 3, x = mid, z = 0, tag = "meHurt" },
				{ t = "dodge", id = 5, x = mid, z = 0, tag = "other" },
				{ t = "melee", id = 5, x = 10, z = 0, dx = 1, dz = 0, r = 4, arc = 150, tag = "near" },
			}
			T.eq(
				kinds(FxFilter.forViewer(batch, 0, 0, nil, 9)),
				"melee:mine,boom:mouse,hurt:myHit,hurt:meHurt,melee:near"
			)
		end
	)
	T.it("returns the same table when nothing is culled or the viewer is unknown", function()
		local batch = { { t = "die", x = 1, z = 1 }, { t = "die", x = 900, z = 0 } }
		local near = { { t = "die", x = 1, z = 1 } }
		T.eq(FxFilter.forViewer(near, 0, 0), near)
		T.eq(FxFilter.forViewer(batch, nil, nil), batch)
		T.eq(FxFilter.forViewer(batch, 0 / 0, 0), batch)
		T.eq(#batch, 2, "input untouched")
	end)
	T.it("keeps events with broken coordinates (never hides on bad data)", function()
		T.eq(#FxFilter.forViewer({ { t = "hit", x = 0 / 0, z = 0 } }, 0, 0), 1)
	end)
end)

T.describe("FxFilter.snapshotForViewer", function()
	T.it("keeps bosses everywhere and enemies within SNAPSHOT_RADIUS", function()
		local far = FxFilter.SNAPSHOT_RADIUS + 5
		local snaps = {
			{ id = 1, kind = 1, x = 5, z = 0 },
			{ id = 2, kind = 1, x = far, z = 0 },
			{ id = 3, kind = 205, x = far * 3, z = 0 },
		}
		local out = FxFilter.snapshotForViewer(snaps, 0, 0)
		T.eq(#out, 2)
		T.eq(out[1].id, 1)
		T.eq(out[2].id, 3)
		T.eq(#snaps, 3)
	end)
end)

return T.finish()
