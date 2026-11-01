--!strict
-- MoveGuard: server-side speed / teleport check for client-owned characters
-- (QC2 M1). Pure: CombatService feeds it the HumanoidRootPart X/Z it reads each
-- frame and moves the character back when the guard says so.
--
--   local g = MoveGuard.new()
--   g:place(id, x, z, now, grace?)      -- the SERVER put the player here (spawn, dash, snap)
--   local x, z, verdict = g:check(id, rawX, rawZ, now, moveSpeed, MoveGuard.stateFactor(info))
--       verdict "ok"        accepted (x, z = the raw sample)
--               "ignored"   inside a placement grace and out of reach: a stale
--                           sample from before the server move; keep the old position
--               "violation" too far: (x, z) is the furthest legal point toward the
--                           sample. Snap the character there. Counted.
--   g:commit(id, x, z)                  -- the world adjusted the point (arena edge, rocks)
--   g:violations(id) -> number
--
-- Budget: per check a player may move moveSpeed x stateFactor x elapsed x TOLERANCE.
-- Unused allowance is banked (up to CARRY_SECONDS of movement) to absorb bursty
-- replication, and a one-off SLACK absorbs rounding; overshoot inside the slack is
-- paid back as debt, so the slack never adds up to a speed bonus.
-- WalkSpeed changes reach the client one round trip late, so after the limit DROPS
-- (downed, dead, slowed) the old limit still applies for LAG_GRACE seconds.
-- Only the X/Z plane is checked: the sim is 2-D and jumping/falling is fine.

local MoveGuard = {}
MoveGuard.__index = MoveGuard

MoveGuard.TOLERANCE = 1.3
MoveGuard.SLACK = 1.5 -- studs
MoveGuard.CARRY_SECONDS = 0.6 -- banked allowance cap, in seconds of movement
MoveGuard.MAX_ELAPSED = 1.0 -- a long server hitch counts at most this long
MoveGuard.LAG_GRACE = 0.6 -- seconds the previous (higher) limit still applies
MoveGuard.DOWNED_FACTOR = 0.3 -- World.DOWNED_SPEED
MoveGuard.DEFAULT_SPEED = 16
MoveGuard.SNAP_GRACE = 0.5 -- after a snap, stale samples are ignored this long
MoveGuard.START_GRACE = 3 -- stage start: the arena teleport may land late
MoveGuard.TELEPORT_GRACE = 0.75 -- server-issued dash
MoveGuard.RESPAWN_GRACE = 2 -- a new character pivoted into the arena
MoveGuard.PUSH_SNAP = 2 -- the world pushed the point this far out of a rock: snap
MoveGuard.UNRANKED_VIOLATIONS = 10 -- violations in one run -> the run is unranked

type PlayerState = {
	x: number,
	z: number,
	t: number,
	carry: number,
	limit: number?,
	lagLimit: number,
	lagUntil: number,
	graceUntil: number,
	violations: number,
}

export type MoveGuard = typeof(setmetatable({} :: { players: { [number]: PlayerState } }, MoveGuard))

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Speed factor for a World:getPlayer() view: dead 0, downed 0.3, else 1.
-- (Slowed is not applied: the slow ends unpredictably for the client, so it is
-- left to the tolerance. A slowed player moving at full speed gains little.)
function MoveGuard.stateFactor(info: any): number
	if type(info) ~= "table" then
		return 1
	end
	if info.dead then
		return 0
	elseif info.downed then
		return MoveGuard.DOWNED_FACTOR
	end
	return 1
end

function MoveGuard.new(): MoveGuard
	return setmetatable({ players = {} }, MoveGuard)
end

-- The server moved (or spawned) the player at (x, z). For `grace` seconds,
-- samples that are out of reach are treated as stale and ignored.
function MoveGuard.place(self: MoveGuard, id: number, x: number, z: number, now: number, grace: number?)
	if not finite(x) or not finite(z) then
		return
	end
	local t = if finite(now) then now else 0
	local st = self.players[id]
	if not st then
		st = {
			x = x,
			z = z,
			t = t,
			carry = 0,
			limit = nil,
			lagLimit = 0,
			lagUntil = -math.huge,
			graceUntil = -math.huge,
			violations = 0,
		}
		self.players[id] = st
	end
	st.x, st.z, st.t = x, z, t
	st.carry = 0
	st.graceUntil = if grace and finite(grace) and grace > 0 then t + grace else -math.huge
end

-- The world clamped / pushed the accepted point: track the stored position.
function MoveGuard.commit(self: MoveGuard, id: number, x: number, z: number)
	local st = self.players[id]
	if st and finite(x) and finite(z) then
		st.x, st.z = x, z
	end
end

function MoveGuard.remove(self: MoveGuard, id: number)
	self.players[id] = nil
end

function MoveGuard.violations(self: MoveGuard, id: number): number
	local st = self.players[id]
	return if st then st.violations else 0
end

function MoveGuard.position(self: MoveGuard, id: number): (number?, number?)
	local st = self.players[id]
	if st then
		return st.x, st.z
	end
	return nil, nil
end

function MoveGuard.check(
	self: MoveGuard,
	id: number,
	x: number,
	z: number,
	now: number,
	speed: number?,
	factor: number?
): (number, number, string)
	local st = self.players[id]
	if not st then
		-- first sight (no placement known): accept as the anchor
		self:place(id, x, z, now, 0)
		return x, z, "ok"
	end
	if not finite(x) or not finite(z) then
		return st.x, st.z, "ignored"
	end
	local t = if finite(now) then now else st.t
	local elapsed = math.clamp(t - st.t, 0, MoveGuard.MAX_ELAPSED)
	st.t = t

	local spd = if finite(speed) and (speed :: number) >= 0 then speed :: number else MoveGuard.DEFAULT_SPEED
	local f = if finite(factor) then math.clamp(factor :: number, 0, 1) else 1
	local limit = spd * f
	local prev = st.limit
	if prev and limit < prev - 1e-6 then
		-- the drop reaches the client a round trip late: keep the old limit a while
		st.lagLimit = math.max(prev, if t < st.lagUntil then st.lagLimit else 0)
		st.lagUntil = t + MoveGuard.LAG_GRACE
	end
	st.limit = limit
	local eff = if t < st.lagUntil then math.max(limit, st.lagLimit) else limit
	local rate = eff * MoveGuard.TOLERANCE
	local cap = rate * MoveGuard.CARRY_SECONDS
	local budget = rate * elapsed + st.carry

	local dx, dz = x - st.x, z - st.z
	local d = math.sqrt(dx * dx + dz * dz)
	if d <= budget + MoveGuard.SLACK then
		st.carry = math.clamp(budget - d, -MoveGuard.SLACK, cap)
		st.x, st.z = x, z
		return x, z, "ok"
	end
	if t < st.graceUntil then
		-- stale sample from before a server move: hold the server position
		st.carry = math.clamp(budget, -MoveGuard.SLACK, cap)
		return st.x, st.z, "ignored"
	end
	-- Violation: go as far as the budget allows toward the sample, then snap.
	local allow = math.max(0, budget)
	local nx, nz = st.x, st.z
	if d > 1e-6 and allow > 0 then
		nx, nz = st.x + dx / d * allow, st.z + dz / d * allow
	end
	st.x, st.z = nx, nz
	st.carry = 0
	st.violations += 1
	st.graceUntil = t + MoveGuard.SNAP_GRACE
	return nx, nz, "violation"
end

return MoveGuard
