--!strict
-- Builder class maths for the client (iteration 6 §1/§4, team Client). Pure:
-- no Roblox APIs, unit-tested under Lune (tests/specs/ClientIter6.spec.luau).
--
-- The builder elephant places World entities: turrets (Deploy Turret, slot
-- ability kind "turret") and barricades (kind "barricade"); Repair Pulse
-- (kind "repair") heals them. The server side (team Builder) is written in
-- parallel, so every reader here takes several shapes:
--
--   Fx (team Builder, Combat/World builds; the shape the server sends):
--       {t = "build", id, kind = "turret" | "barricade", owner, squad, x, z, r,
--        dx, dz (the barricade's WALL direction), half (half length), range
--        (turret targeting), hpFrac, untilT}   spawn + every 2 s (late joiners)
--       {t = "buildHp", id, hpFrac}           HP changes
--       {t = "buildShot", id, tx, tz}         a turret fired (BuildRenderer)
--       {t = "buildEnd", id, kind, x, z, reason}
--   Older / alternative shapes also read:
--       {t = "turret" | "barricade" | "struct" | "structure",
--        id, kind?, owner? (userId), x, z, yaw? | dx, dz?, hp?, maxHp?, hpFrac?,
--        ttl? | expiresAt? | untilT?, len? | length?, r?, squad?, phase?}
--       phase "gone" / "dead" / "expire" / "despawn" (or t = "<t>Gone") removes;
--       a re-send of a known id updates it (HP, position).
--   PlayerHud  turrets = n | {count, max} ; barricades likewise; or
--       structures = {turret = n, barricade = n} (the HUD counter wins over
--       counting the drawn models).

local BuildMath = {}

BuildMath.TURRET_CAP = 2 -- PLAN §1: at most 2 alive per hero (the oldest despawns)
BuildMath.BARRICADE_CAP = 2
BuildMath.TURRET_RANGE = 40 -- targeting range (the ghost shows it)
BuildMath.CAST_RANGE = 30 -- default cast range when the def has no `distance`
BuildMath.BARRICADE_LENGTH = 14
BuildMath.TURRET_TTL = 20
BuildMath.BARRICADE_TTL = 12

local KINDS = { turret = true, barricade = true }

local function num(v: any): number?
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return n
end

-- "turret" | "barricade" | nil for a kind / name / id string ("builder_barricade",
-- "Deploy Turret", "wall" ...).
function BuildMath.structureKind(v: any): string?
	if type(v) ~= "string" then
		return nil
	end
	local s = string.lower(v)
	if KINDS[s] then
		return s
	end
	if string.find(s, "turret", 1, true) then
		return "turret"
	end
	if string.find(s, "barricade", 1, true) or s == "wall" then
		return "barricade"
	end
	return nil
end

-- The placement kind of an ability def (AbilityDef or a ClassAbilities entry):
-- "turret" | "barricade" | nil (not a placement: no ghost).
function BuildMath.placementKind(def: any): string?
	if type(def) ~= "table" then
		return nil
	end
	local d = if type(def.def) == "table" then def.def else def
	return BuildMath.structureKind(d.kind)
		or BuildMath.structureKind(d.place)
		or BuildMath.structureKind(d.id)
		or BuildMath.structureKind(d.name)
end

-- True for Repair Pulse style abilities (kind "repair" / "repair_pulse" / "pulse").
function BuildMath.isRepair(kind: any): boolean
	if type(kind) ~= "string" then
		return false
	end
	local s = string.lower(kind)
	return string.find(s, "repair", 1, true) ~= nil
end

-- Where a placement lands: the aim point clamped to `range` from the hero
-- (Combat/Weapons aimPoint), and the facing yaw (radians, atan2(dx, dz) of
-- hero -> aim: a barricade spans across that line, a turret faces it).
function BuildMath.placement(
	heroX: number,
	heroZ: number,
	aimX: number,
	aimZ: number,
	range: number?
): (number, number, number)
	local dx, dz = aimX - heroX, aimZ - heroZ
	local d = math.sqrt(dx * dx + dz * dz)
	local r = math.max(0, range or BuildMath.CAST_RANGE)
	local x, z = aimX, aimZ
	if d > r and d > 1e-6 then
		x, z = heroX + dx / d * r, heroZ + dz / d * r
	end
	local yaw = if d > 1e-6 then math.atan2(dx, dz) else 0
	return x, z, yaw
end

-- The two ends of a barricade of `len` centred at (x, z) that spans across `yaw`.
function BuildMath.barricadeEnds(
	x: number,
	z: number,
	yaw: number,
	len: number?
): (number, number, number, number)
	local h = (len or BuildMath.BARRICADE_LENGTH) / 2
	-- perpendicular to the facing (sin, cos) is (cos, -sin)
	local px, pz = math.cos(yaw), -math.sin(yaw)
	return x - px * h, z - pz * h, x + px * h, z + pz * h
end

-- "Turrets 1/2"
function BuildMath.counterText(kind: string, n: number, cap: number?): string
	local label = if kind == "barricade" then "Barricades" else "Turrets"
	return string.format("%s %d/%d", label, math.max(0, math.floor(n)), math.max(1, math.floor(cap or 2)))
end

-- HP bar colour band for a fraction: "high" | "mid" | "low".
function BuildMath.hpBand(frac: number): string
	if frac > 0.6 then
		return "high"
	elseif frac > 0.3 then
		return "mid"
	end
	return "low"
end

----------------------------------------------------------------------
-- Structure set: what the renderer draws (fed by Fx and snapshots)
----------------------------------------------------------------------

export type Structure = {
	id: string,
	kind: string, -- "turret" | "barricade"
	owner: number?,
	squad: number?,
	x: number,
	z: number,
	yaw: number,
	len: number,
	range: number, -- turret targeting range (0 = unknown / a barricade)
	hpFrac: number,
	expiresAt: number?, -- server time
	seq: number, -- placement order (oldest first)
	seenAt: number, -- server time of the last update
}

export type Set = {
	items: { [string]: Structure },
	seq: number,
}

function BuildMath.newSet(): Set
	return { items = {}, seq = 0 }
end

local GONE =
	{ gone = true, dead = true, expire = true, expired = true, despawn = true, remove = true, destroy = true }

-- The structure kind an Fx event is about, or nil when it is not one.
function BuildMath.fxKind(ev: any): string?
	if type(ev) ~= "table" then
		return nil
	end
	local t = if type(ev.t) == "string" then string.lower(ev.t) else ""
	if t == "buildhp" or t == "buildend" then
		-- may carry no kind: "?" = whatever the id already is
		return BuildMath.structureKind(ev.kind) or "?"
	end
	local base = string.gsub(t, "gone$", "")
	local k = BuildMath.structureKind(ev.kind) or BuildMath.structureKind(ev.structure)
	if k then
		if
			base == "struct"
			or base == "structure"
			or base == "build"
			or base == "turret"
			or base == "barricade"
		then
			return k
		end
		return nil
	end
	if base == "turret" or base == "barricade" then
		return base
	end
	return nil
end

-- True when the Fx event removes its structure.
function BuildMath.fxGone(ev: any): boolean
	if type(ev) ~= "table" then
		return false
	end
	local t = if type(ev.t) == "string" then string.lower(ev.t) else ""
	if string.sub(t, -4) == "gone" or t == "buildend" then
		return true
	end
	local ph = if type(ev.phase) == "string" then string.lower(ev.phase) else nil
	return (ph ~= nil and GONE[ph] == true) or ev.gone == true or ev.dead == true
end

local function hpFracOf(ev: any): number?
	local f = num(ev.hpFrac)
	if f == nil then
		local hp, max = num(ev.hp), num(ev.maxHp)
		if hp and max and max > 0 then
			f = hp / max
		elseif hp and max == nil and hp <= 1 then
			f = hp
		end
	end
	return if f then math.clamp(f, 0, 1) else nil
end

local function yawOf(ev: any): number?
	local yaw = num(ev.yaw) or num(ev.angle) or num(ev.rot)
	if yaw then
		-- degrees when clearly not radians
		return if math.abs(yaw) > 2 * math.pi + 0.01 then math.rad(yaw) else yaw
	end
	local dx, dz = num(ev.dx), num(ev.dz)
	if dx and dz and (dx ~= 0 or dz ~= 0) then
		if ev.half ~= nil then
			-- World builds: (dx, dz) runs ALONG the wall; the facing is across it
			-- (barricadeEnds: the wall direction is (cos yaw, -sin yaw))
			return math.atan2(-dz, dx)
		end
		return math.atan2(dx, dz)
	end
	return nil
end

local function lenOf(ev: any): number?
	local half = num(ev.half)
	if half and half > 0 then
		return 2 * half
	end
	return num(ev.len) or num(ev.length)
end

-- Applies one Fx event. Returns ("add" | "update" | "remove" | nil, id).
function BuildMath.applyFx(set: Set, ev: any, now: number): (string?, string?)
	local kind = BuildMath.fxKind(ev)
	if kind == nil or ev.id == nil then
		return nil, nil
	end
	local id = tostring(ev.id)
	if BuildMath.fxGone(ev) then
		if set.items[id] then
			set.items[id] = nil
			return "remove", id
		end
		return nil, id
	end
	local s = set.items[id]
	if kind == "?" then
		-- buildHp: an update of a known build only
		if s == nil then
			return nil, id
		end
		kind = s.kind
	end
	local x, z = num(ev.x), num(ev.z)
	local ttl = num(ev.ttl) or num(ev.life) or num(ev.dur)
	local exp = num(ev.expiresAt) or num(ev.untilT) or num(ev["until"])
	if exp == nil and ttl then
		exp = now + ttl
	end
	if s then
		s.x, s.z = x or s.x, z or s.z
		s.yaw = yawOf(ev) or s.yaw
		s.hpFrac = hpFracOf(ev) or s.hpFrac
		s.expiresAt = exp or s.expiresAt
		s.len = lenOf(ev) or s.len
		s.range = num(ev.range) or s.range
		s.seenAt = now
		return "update", id
	end
	if x == nil or z == nil then
		return nil, id
	end
	set.seq += 1
	set.items[id] = {
		id = id,
		kind = kind,
		owner = num(ev.owner) or num(ev.ownerId) or num(ev.by) or num(ev.uid),
		squad = num(ev.squad),
		x = x,
		z = z,
		yaw = yawOf(ev) or 0,
		len = lenOf(ev) or (if kind == "barricade" then BuildMath.BARRICADE_LENGTH else 0),
		range = num(ev.range) or 0,
		hpFrac = hpFracOf(ev) or 1,
		expiresAt = exp
			or (now + (if kind == "turret" then BuildMath.TURRET_TTL else BuildMath.BARRICADE_TTL) + 2),
		seq = set.seq,
		seenAt = now,
	}
	return "add", id
end

-- Removes expired entries (`grace` s past their end, default 0.5: the
-- server's buildEnd normally comes first). Returns the removed ids.
function BuildMath.expire(set: Set, now: number, grace: number?): { string }
	local out = {}
	for id, s in set.items do
		if s.expiresAt ~= nil and now > s.expiresAt + (grace or 0.5) then
			table.insert(out, id)
		end
	end
	for _, id in out do
		set.items[id] = nil
	end
	return out
end

-- Live structures of an owner (and kind), oldest first.
function BuildMath.owned(set: Set, owner: number, kind: string?): { Structure }
	local out = {}
	for _, s in set.items do
		if s.owner == owner and (kind == nil or s.kind == kind) then
			table.insert(out, s)
		end
	end
	table.sort(out, function(a, b)
		return a.seq < b.seq
	end)
	return out
end

-- The HUD's count for a kind: (n, cap) from PlayerHud when it says, else nil.
function BuildMath.hudCount(hud: any, kind: string): (number?, number?)
	if type(hud) ~= "table" then
		return nil, nil
	end
	local plural = kind .. "s"
	local v = hud[plural]
	if v == nil and type(hud.structures) == "table" then
		v = hud.structures[kind] or hud.structures[plural]
	end
	if v == nil and type(hud.builds) == "table" then
		v = hud.builds[kind] or hud.builds[plural]
	end
	if type(v) == "table" then
		return num(v.count or v.n or v.alive or v[1]), num(v.max or v.cap or v[2])
	end
	local n = num(v)
	local cap = num(hud[kind .. "Cap"]) or num(hud[kind .. "Max"])
	return n, cap
end

return BuildMath
