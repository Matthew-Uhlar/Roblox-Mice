--!strict
-- FxFilter: per-client culling of a step's Fx batch (bandwidth, Testing team #7).
-- Pure; CombatService calls FxFilter.forViewer once per tracked player per step.
--
-- Point events far from the viewer (> RADIUS studs; plain damage numbers
-- > HIT_RADIUS) are dropped: damage numbers,
-- deaths, explosions, melee swings, chains, crumb spawns, slams and hurt flashes of
-- OTHER players. Projectiles are dropped only when their whole path (x, z) ->
-- (x + vx*ttl, z + vz*ttl) stays out of range, so a shot that will fly into view is
-- always sent. Mousetrap snaps (`trap`) are point events too. Everything else
-- (telegraphs, zones, boss / phase / enrage events, orbit, revive, down,
-- pickupTaken, projEnd, surge, clear, POI state `poi` / `poiProgress` /
-- `poiDone`, `portal`, ...) is always sent: those are rare, or carry state the
-- client must not miss (POI progress is already quantised to 10% steps).
-- Merging damage numbers per enemy already happens in World.damageEnemy.

local FxFilter = {}

FxFilter.RADIUS = 100 -- studs; ~ the far corners at max zoom (default zoom shows ~65)
FxFilter.HIT_RADIUS = 60 -- damage numbers are unreadable further out
FxFilter.SNAPSHOT_RADIUS = 110 -- enemies further away are not sent (bosses always are)
FxFilter.BOSS_KIND = 200 -- EnemySnap.kind >= this is a boss body

local POINT_CULL: { [string]: boolean } = {
	hit = true,
	die = true,
	boom = true,
	melee = true,
	pickup = true,
	slam = true,
	hurt = true,
	trap = true, -- Mousetrap Field snap (the telegraph before it is always sent)
}

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Distance from (px, pz) to the segment (ax, az) -> (bx, bz).
local function segDist(px: number, pz: number, ax: number, az: number, bx: number, bz: number): number
	local dx, dz = bx - ax, bz - az
	local l2 = dx * dx + dz * dz
	local t = if l2 > 1e-9 then math.clamp(((px - ax) * dx + (pz - az) * dz) / l2, 0, 1) else 0
	local cx, cz = ax + dx * t, az + dz * t
	return math.sqrt((px - cx) ^ 2 + (pz - cz) ^ 2)
end
FxFilter.segDist = segDist

-- Should this event reach a viewer standing at (vx, vz)? `viewerId` keeps the
-- viewer's own events (their hurt flash) regardless of distance.
function FxFilter.relevant(fx: any, vx: number, vz: number, radius: number, viewerId: number?): boolean
	local t = fx.t
	if viewerId ~= nil and fx.id == viewerId and (t == "hurt" or t == "melee") then
		return true
	end
	if POINT_CULL[t] then
		if not finite(fx.x) or not finite(fx.z) then
			return true
		end
		local pad = if finite(fx.r) then fx.r else 0
		local lim = if t == "hit" and not fx.crit then math.min(radius, FxFilter.HIT_RADIUS) else radius
		return (fx.x - vx) ^ 2 + (fx.z - vz) ^ 2 <= (lim + pad) ^ 2
	elseif t == "chain" then
		if not (finite(fx.x1) and finite(fx.z1) and finite(fx.x2) and finite(fx.z2)) then
			return true
		end
		return segDist(vx, vz, fx.x1, fx.z1, fx.x2, fx.z2) <= radius
	elseif t == "proj" then
		if not (finite(fx.x) and finite(fx.z) and finite(fx.vx) and finite(fx.vz) and finite(fx.ttl)) then
			return true
		end
		local ttl = math.clamp(fx.ttl, 0, 30)
		local pad = if finite(fx.r) then fx.r else 0
		return segDist(vx, vz, fx.x, fx.z, fx.x + fx.vx * ttl, fx.z + fx.vz * ttl) <= radius + pad
	end
	return true
end

-- The part of `batch` worth sending to a viewer at (vx, vz). Returns the same
-- table when nothing was culled (no copy), or when the viewer position is unknown.
function FxFilter.forViewer(
	batch: { any },
	vx: number?,
	vz: number?,
	radius: number?,
	viewerId: number?
): { any }
	if not finite(vx) or not finite(vz) then
		return batch
	end
	local r = radius or FxFilter.RADIUS
	local out: { any }? = nil
	for i, fx in batch do
		local keep = FxFilter.relevant(fx, vx :: number, vz :: number, r, viewerId)
		if not keep and not out then
			out = table.move(batch, 1, i - 1, 1, {})
		elseif keep and out then
			table.insert(out, fx)
		end
	end
	return out or batch
end

-- Snapshot entries for a viewer at (vx, vz): bosses always, other enemies
-- within `radius` (default SNAPSHOT_RADIUS). Same table when nothing is culled.
function FxFilter.snapshotForViewer(snaps: { any }, vx: number?, vz: number?, radius: number?): { any }
	if not finite(vx) or not finite(vz) then
		return snaps
	end
	local r = radius or FxFilter.SNAPSHOT_RADIUS
	local r2 = r * r
	local out: { any }? = nil
	for i, e in snaps do
		local keep = (e.kind or 0) >= FxFilter.BOSS_KIND
			or not (finite(e.x) and finite(e.z))
			or (e.x - (vx :: number)) ^ 2 + (e.z - (vz :: number)) ^ 2 <= r2
		if not keep and not out then
			out = table.move(snaps, 1, i - 1, 1, {})
		elseif keep and out then
			table.insert(out, e)
		end
	end
	return out or snaps
end

return FxFilter
