--!strict
-- Rig (v3 Graphics, client): procedural skeletal animation for part-built models
-- (mice, champions, bot elephants). No Motor6Ds, no AnimationTracks: a model is
-- a list of part specs, each owned by a named bone; every frame a pose function
-- writes one local rotation / offset per bone, Rig.solve walks the bones parent
-- first and the caller places each part at  bone * partLocal.
--
--   Rig.compile(specs, skeleton) -> Compiled      once per model (shared by the pool)
--   Rig.newState() -> State                        per animated instance
--   Rig.pose(style, st, D, k, detail)              style = "mouse" | "biped" | "elephant"
--   Rig.solve(c, root, D, A)                       A[bone] = posed bone frame
--   Rig.place(c, i, root, A) -> CFrame             posed frame of part i
--   Rig.rootPose(style, st, k) -> CFrame           whole-body offset (lunge, death roll)
--
-- `k` is the model scale (1 = the unit model) so translations follow the size.
-- `detail` 1 = full (every bone), 2 = simplified (body bob + legs only: the
-- 60-120 stud band), 0 = none (caller skips posing). Bone indices are fixed
-- (Rig.B), so pose functions write D[...] directly without lookups.
-- Pure datatypes (CFrame / Vector3 / math): scripts/render-preview.luau runs it
-- under Lune to render the idle / walk / attack poses.

local Rig = {}

Rig.BONES = {
	"body",
	"head",
	"earL",
	"earR",
	"tail",
	"tail2",
	"legFL",
	"legFR",
	"legBL",
	"legBR",
	"armL",
	"armR",
	"weapon",
	"cape",
	"jaw",
	"trunk",
	"trunk2",
	"trunk3",
	"extra",
}
local NB = #Rig.BONES
Rig.COUNT = NB
Rig.INDEX = {} :: { [string]: number }
for i, n in Rig.BONES do
	Rig.INDEX[n] = i
end
local I = Rig.INDEX
local BODY, HEAD, EARL, EARR, TAIL, TAIL2 = I.body, I.head, I.earL, I.earR, I.tail, I.tail2
local LFL, LFR, LBL, LBR = I.legFL, I.legFR, I.legBL, I.legBR
local ARML, ARMR, WEAPON, CAPE, JAW = I.armL, I.armR, I.weapon, I.cape, I.jaw
local TR1, TR2, TR3, EXTRA = I.trunk, I.trunk2, I.trunk3, I.extra
Rig.B = I

local IDENT = CFrame.identity
local ANG = CFrame.Angles
local sin, cos, abs, pi = math.sin, math.cos, math.abs, math.pi

export type Compiled = {
	has: { boolean },
	parent: { number },
	rel: { CFrame },
	order: { number },
	partBone: { number },
	partLocal: { CFrame },
	n: number,
}

export type State = {
	t: number, -- seconds (+ a per-instance phase)
	gait: number, -- gait phase in radians, advanced by distance walked
	moving: number, -- 0..1
	lunge: number, -- 0..1 progress of an attack lunge (0 = none)
	flinch: number, -- 0..1 progress of a hit flinch
	windup: number, -- 0..1 raise of a telegraphed attack
	strike: number, -- 0..1 progress of the strike after a wind-up
	roar: number, -- 0..1 progress of a phase-change roar
	cast: number, -- 0..1 progress of an ability / cast pose
	swing: number, -- 0..1 progress of an auto-attack (bots)
	swingKind: string, -- "melee" | "shoot" | "lob" | "thrust" | "gust" | iter7: "snipe" | "mortar"
	castKind: string?, -- iter7: ability kind of the cast (Rig.CAST), nil = generic rear-up
	castHold: number, -- iter7: seconds the cast pose is held (tether channel, anchor dig-in)
	dead: number, -- 0..1 death progress
	downed: number, -- 0..1 blend into the downed pose (bots)
	revive: number, -- 0..1 progress of a stand-up hop (bots)
	enraged: boolean,
	side: number, -- +1 / -1: which way a death roll tips
	aim: number, -- bipeds: 0 = overhead wind-up (swing / throw), 1 = level aim (rifles)
	lean: number, -- iter3: -1..1 turn lean (elephants), set by the animator from the yaw rate
	variant: string?, -- iter1 bosses: "slam" | "charge" | "spin" | "hop" | "sway" (Rig.BOSS_VARIANTS)
}

function Rig.newState(phase: number?): State
	return {
		t = phase or 0,
		gait = (phase or 0) * 3,
		moving = 0,
		lunge = 0,
		flinch = 0,
		windup = 0,
		strike = 0,
		roar = 0,
		cast = 0,
		swing = 0,
		swingKind = "melee",
		castKind = nil,
		castHold = 0,
		dead = 0,
		downed = 0,
		revive = 0,
		enraged = false,
		side = if (phase or 0) % 2 < 1 then 1 else -1,
		aim = 0,
		lean = 0,
	}
end

-- Compiles a spec list + skeleton into flat arrays (bone 0 = the model root).
function Rig.compile(specs: { any }, skeleton: { [string]: any }?): Compiled
	local sk = skeleton or {}
	local has, parent, rel, pivots = {}, {}, {}, {}
	for i = 1, NB do
		has[i] = false
		parent[i] = 0
		rel[i] = IDENT
	end
	for name, b in sk do
		local idx = I[name]
		if idx and typeof(b.pivot) == "CFrame" then
			has[idx] = true
			pivots[idx] = b.pivot
		end
	end
	for name, b in sk do
		local idx = I[name]
		if idx and has[idx] then
			local p = if type(b.parent) == "string" then I[b.parent] else nil
			parent[idx] = if p and has[p] and p ~= idx then p else 0
		end
	end
	-- depth-sorted order (parents first)
	local depth = {}
	local function d(i: number, guard: number): number
		if guard > NB then
			return 0
		end
		local p = parent[i]
		return if p == 0 then 0 else 1 + d(p, guard + 1)
	end
	local order = {}
	for i = 1, NB do
		if has[i] then
			depth[i] = d(i, 0)
			table.insert(order, i)
		end
	end
	table.sort(order, function(a, b)
		if depth[a] ~= depth[b] then
			return depth[a] < depth[b]
		end
		return a < b
	end)
	for _, i in order do
		local p = parent[i]
		rel[i] = if p == 0 then pivots[i] else pivots[p]:ToObjectSpace(pivots[i])
	end
	local partBone, partLocal = {}, {}
	for i, s in specs do
		local b = if type(s.bone) == "string" then I[s.bone] else nil
		if b and has[b] then
			partBone[i] = b
			partLocal[i] = pivots[b]:ToObjectSpace(s.offset)
		else
			partBone[i] = 0
			partLocal[i] = s.offset
		end
	end
	return {
		has = has,
		parent = parent,
		rel = rel,
		order = order,
		partBone = partBone,
		partLocal = partLocal,
		n = #specs,
	}
end

function Rig.newPose(): { CFrame }
	local D = table.create(NB, IDENT)
	return D
end

function Rig.solve(c: Compiled, root: CFrame, D: { CFrame }, A: { CFrame })
	local parent, rel = c.parent, c.rel
	for _, b in c.order do
		local p = parent[b]
		local base = if p == 0 then root else A[p]
		local dd = D[b]
		A[b] = if dd == IDENT then base * rel[b] else base * rel[b] * dd
	end
end

function Rig.place(c: Compiled, i: number, root: CFrame, A: { CFrame }): CFrame
	local b = c.partBone[i]
	return (if b == 0 then root else A[b]) * c.partLocal[i]
end

-- Rest pose (every bone identity): the frame of each part = root * offset.
function Rig.reset(D: { CFrame })
	for i = 1, NB do
		D[i] = IDENT
	end
end

----------------------------------------------------------------------
-- Curves
----------------------------------------------------------------------

local function smooth(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end
Rig.smooth = smooth

-- 0 -> 1 fast, then back to 0 (attack lunges, flinches).
local function punch(x: number, peak: number): number
	if x <= 0 or x >= 1 then
		return 0
	end
	if x < peak then
		return smooth(x / peak)
	end
	return 1 - smooth((x - peak) / (1 - peak))
end
Rig.punch = punch

----------------------------------------------------------------------
-- Root-level pose (whole body): lunge / flinch / strike / death / roar
----------------------------------------------------------------------

-- iter1 (C-29): each boss gets its own wind-up / strike body language.
Rig.BOSS_VARIANTS = {
	my_grandma = "slam",
	giant_tree = "slam",
	green_gorilla = "slam",
	corndog_bunny = "hop",
	froggus = "hop",
	hematite_snake = "charge",
	ice_dragon = "charge",
	paper_dinosaur = "charge",
	serpent_sisters = "spin",
	spider_machine = "spin",
	zoomzola = "spin",
	floating_witch = "sway",
	void_cat = "sway",
}

-- iter2 full boss pose sets: one clip per pattern base, picked from the
-- telegraph (style first, then shape); bosses keep their own default otherwise.
Rig.CLIP_FOR_STYLE = {
	slam = "slam",
	rock = "slam",
	burst = "slam",
	fuse = "slam",
	stomp = "slam",
	line = "charge",
	charge = "charge",
	dash = "charge",
	cone = "breath",
	breath = "breath",
	volley = "volley",
	spiral = "volley",
	chain = "volley",
	trap = "volley",
	summon = "summon",
	rally = "summon",
	champIntro = "summon",
	bossIntro = "summon",
	roulette = "roulette",
	circle = nil,
}
function Rig.clipFor(bossId: string?, style: string?, shape: string?): string
	local c = (style and Rig.CLIP_FOR_STYLE[style]) or (shape and Rig.CLIP_FOR_STYLE[shape])
	return c or Rig.BOSS_VARIANTS[bossId or ""] or "slam"
end

local function variantPose(v: string, st: State, k: number): (number, number, number, number, number, number)
	local w = if st.strike <= 0 then smooth(st.windup) else 0
	local s = st.strike
	local x, y, z, rx, ry, rz = 0, 0, 0, 0, 0, 0
	if v == "slam" then
		-- rear up high and hold, then crash down with a bounce
		rx += w * 0.32
		y += w * 0.35 * k
		if s > 0 then
			local c = punch(s, 0.18)
			rx -= c * 0.3
			y -= c * 0.25 * k
			y += math.max(0, math.sin(s * pi * 3)) * 0.08 * k * (1 - s)
		end
	elseif v == "charge" then
		-- coil back low, then a long lunge
		z += w * 0.6 * k
		y -= w * 0.15 * k
		rx -= w * 0.08
		if s > 0 then
			local c = punch(s, 0.25)
			z -= c * 1.4 * k
			rx -= c * 0.12
		end
	elseif v == "spin" then
		-- wind-up twist, then a full spin
		ry -= w * 0.6
		if s > 0 then
			ry += -0.6 + smooth(s / 0.7) * (2 * pi + 0.6)
			y += punch(s, 0.3) * 0.15 * k
		end
	elseif v == "hop" then
		-- squat, then a big jump and squash on landing
		y -= w * 0.3 * k
		if s > 0 then
			y += math.sin(math.min(1, s / 0.6) * pi) * 1.3 * k
			rx += math.sin(math.min(1, s / 0.6) * pi) * 0.15
		end
	elseif v == "volley" then
		-- rear back, then three quick spits forward
		rx += w * 0.18
		z += w * 0.25 * k
		if s > 0 then
			local burst = math.max(0, math.sin(s * pi * 6)) * (1 - s)
			z += burst * 0.35 * k
			rx -= burst * 0.12
		end
	elseif v == "summon" then
		-- rise and spread, a shimmering hover, then a stamp
		y += w * 0.6 * k
		rz += math.sin(st.t * 9) * 0.05 * w
		x += math.sin(st.t * 23) * 0.03 * k * w
		if s > 0 then
			local c = punch(s, 0.2)
			y -= c * 0.4 * k
			rx -= c * 0.1
		end
	elseif v == "roulette" then
		-- a slow wobbling spin while the wheel turns, then a pointed stop
		ry += w * st.t * 2.5 % (2 * pi)
		rz += math.sin(st.t * 5) * 0.08 * w
		if s > 0 then
			ry += (1 - smooth(s)) * 0.8
			rx -= punch(s, 0.25) * 0.15
		end
	elseif v == "breath" then
		-- head thrown back, then a long forward-shaking exhale
		rx += w * 0.3
		y += w * 0.15 * k
		if s > 0 then
			local c = 1 - smooth((s - 0.6) / 0.4)
			rx -= c * 0.18
			x += math.sin(st.t * 40) * 0.05 * k * c
			z -= c * 0.2 * k
		end
	elseif v == "sway" then
		-- float up, sway while channeling, recoil on the cast
		y += w * 0.5 * k
		rz += math.sin(st.t * 3) * 0.12 * w
		if s > 0 then
			local c = punch(s, 0.2)
			z += c * 0.5 * k
			rx += c * 0.2
		end
	end
	return x, y, z, rx, ry, rz
end

function Rig.rootPose(style: string, st: State, k: number): CFrame
	local x, y, z, rx, rz = 0, 0, 0, 0, 0
	local ry = 0
	local variant = st.variant
	if variant and style == "boss" and (st.windup > 0 or st.strike > 0) then
		local vx, vy, vz, vrx, vry, vrz = variantPose(variant, st, k)
		x, y, z, rx, ry, rz = vx, vy, vz, vrx, vry, vrz
	end
	if st.lunge > 0 then
		-- iter1: a hop-lunge (crouch, spring up and forward, land)
		local c = punch(st.lunge, 0.35)
		local crouch = if st.lunge < 0.2
			then smooth(st.lunge / 0.2) * (1 - smooth((st.lunge - 0.1) / 0.1))
			else 0
		z -= c * 0.85 * k
		y += math.sin(math.min(1, st.lunge / 0.7) * pi) * 0.45 * k - crouch * 0.12 * k
		rx -= c * 0.12
	end
	if st.flinch > 0 then
		local c = punch(st.flinch, 0.25)
		z += c * 0.22 * k
		rx += c * 0.18
	end
	if st.strike > 0 and not (variant and style == "boss") then
		local c = punch(st.strike, 0.3)
		z -= c * (if style == "biped" then 0.55 else 0.35) * k
		rx -= c * 0.06
	end
	if st.windup > 0 and st.strike <= 0 and not (variant and style == "boss") then
		local w = smooth(st.windup)
		rx += w * 0.1
		z += w * 0.12 * k
		-- trembling hold at full wind-up
		x += sin(st.t * 40) * 0.04 * k * w
	end
	if st.roar > 0 then
		local c = punch(st.roar, 0.25)
		rx += c * 0.22
		y += c * 0.2 * k
		x += sin(st.t * 35) * 0.05 * k * c
	end
	if st.revive > 0 then
		local c = punch(st.revive, 0.4)
		y += c * 0.9 * k
	end
	if st.dead > 0 then
		local d = smooth(st.dead / 0.6)
		local hop = sin(math.min(1, st.dead / 0.5) * pi)
		if style == "boss" then
			-- big collapse: shudder, keel over sideways, sink into the ground
			local c = smooth(st.dead / 0.7)
			x += sin(st.t * 30) * 0.06 * k * (1 - c)
			rz += c * 1.15 * st.side
			rx -= c * 0.2
			y -= smooth((st.dead - 0.35) / 0.65) * 0.9 * k
		elseif style == "biped" then
			-- topple backwards, then sink
			rx += d * 1.45
			y += hop * 0.5 * k - smooth((st.dead - 0.6) / 0.4) * 0.6 * k
		else
			-- pop up, roll onto the back
			rz += d * 2.4 * st.side
			y += hop * 0.9 * k
			x += d * 0.4 * k * st.side
		end
	end
	if x == 0 and y == 0 and z == 0 and rx == 0 and rz == 0 and ry == 0 then
		return IDENT
	end
	return CFrame.new(x, y, z) * ANG(rx, ry, rz)
end

----------------------------------------------------------------------
-- Pose styles
----------------------------------------------------------------------

-- Four-legged mice: run cycle (diagonal legs), body bob, tail sway, ear flop;
-- attack lunge; flinch; death curl.
local function poseMouse(st: State, D: { CFrame }, _k: number, detail: number)
	local m, g, t = st.moving, st.gait, st.t
	local sg = sin(g)
	local legA = sg * 0.95 * m
	local lunge = punch(st.lunge, 0.35)
	local curl = smooth(st.dead / 0.5) * 1.3
	D[LFL] = ANG(legA + lunge * 0.9 + curl, 0, 0)
	D[LBR] = ANG(legA - curl * 0.6, 0, 0)
	D[LFR] = ANG(-legA + lunge * 0.9 + curl, 0, 0)
	D[LBL] = ANG(-legA - curl * 0.6, 0, 0)
	local breath = sin(t * 2.4) * 0.025
	local bob = abs(sg) * 0.1 * m + breath
	local flinch = punch(st.flinch, 0.25)
	D[BODY] = CFrame.new(0, bob, 0) * ANG(-0.1 * m - lunge * 0.18 + flinch * 0.25, 0, sin(g) * 0.06 * m)
	if detail >= 2 then
		D[HEAD], D[EARL], D[EARR], D[TAIL], D[TAIL2], D[WEAPON] = IDENT, IDENT, IDENT, IDENT, IDENT, IDENT
		return
	end
	local look = sin(t * 0.8) * 0.3 * (1 - m)
	D[HEAD] = ANG(sin(g * 2) * 0.07 * m + lunge * 0.12 + flinch * 0.4 + cos(t * 1.7) * 0.04, look, 0)
	local flop = sin(g - 1.1) * 0.35 * m + sin(t * 5.3) * 0.06 + lunge * 0.2
	local back = 0.35 * m + lunge * 0.7 + flinch * 0.6 + curl * 0.4
	D[EARL] = ANG(back, 0, flop)
	D[EARR] = ANG(back, 0, -flop)
	local wag = sin(t * 4.2) * 0.35 + sin(g) * 0.35 * m
	D[TAIL] = ANG(0.15 * m, wag, 0)
	D[TAIL2] = ANG(-0.1, sin(t * 4.2 - 0.9) * 0.5, 0)
	D[WEAPON] = ANG(-lunge * 1.4, 0, 0)
end

-- Bipeds (champions): walk cycle with counter-swinging arms, breathing, cape
-- and tail secondary motion; telegraphed wind-up -> strike; roar; topple.
local function poseBiped(st: State, D: { CFrame }, _k: number, detail: number)
	local m, g, t = st.moving, st.gait, st.t
	local sg = sin(g)
	local enr = if st.enraged then 1.6 else 1
	D[LFL] = ANG(sg * 0.7 * m, 0, 0)
	D[LFR] = ANG(-sg * 0.7 * m, 0, 0)
	local breath = sin(t * 1.9 * enr) * 0.035
	local bob = abs(cos(g)) * 0.09 * m + breath
	local w = smooth(st.windup)
	local s = punch(st.strike, 0.3)
	local r = punch(st.roar, 0.25)
	local dead = smooth(st.dead / 0.6)
	local aim = st.aim
	D[BODY] = CFrame.new(0, bob, 0)
		* ANG(-0.06 * m + w * 0.18 * (1 - aim) - s * 0.15 + r * 0.25, sg * 0.08 * m - w * aim * 0.25, 0)
	-- arms: swing, wind-up overhead (or a level aim), strike forward, roar spread
	local swing = -sg * 0.55 * m * (1 - w)
	local idle = sin(t * 1.9 * enr) * 0.06
	local armR = swing
		+ idle
		+ w * (2.5 - 1.05 * aim)
		- s * (1.2 - 0.9 * aim)
		+ punch(st.lunge, 0.35) * 1.6
		- r * 0.4
		+ dead * 1.2
	local armL = -swing + idle + w * (0.9 + 0.5 * aim) + s * 0.4 - r * 0.4 + dead * 1.2
	D[ARMR] = ANG(armR, 0, -r * 1.1 - 0.05)
	D[ARML] = ANG(armL, 0, r * 1.1 + 0.05)
	if detail >= 2 then
		D[HEAD], D[EARL], D[EARR], D[TAIL], D[TAIL2], D[CAPE], D[JAW], D[WEAPON], D[EXTRA] =
			IDENT, IDENT, IDENT, IDENT, IDENT, IDENT, IDENT, IDENT, IDENT
		return
	end
	local look = sin(t * 0.7) * 0.35 * (1 - m) * (1 - w)
	D[HEAD] = ANG(-r * 0.5 + w * 0.1 - s * 0.15 + sin(g * 2) * 0.05 * m, look, 0)
	D[JAW] = ANG(r * 0.6 + w * 0.15, 0, 0)
	local flop = sin(g - 1.1) * 0.3 * m + sin(t * 4.1) * 0.05
	D[EARL] = ANG(0.25 * m + r * 0.5, 0, flop)
	D[EARR] = ANG(0.25 * m + r * 0.5, 0, -flop)
	D[TAIL] = ANG(0.1, sin(t * 3.4) * 0.4 + sg * 0.3 * m, 0)
	D[TAIL2] = ANG(-0.1, sin(t * 3.4 - 0.8) * 0.5, 0)
	D[CAPE] = ANG(-0.12 - 0.45 * m - sin(t * 3.1 + 0.4) * 0.07 - s * 0.3, 0, sin(t * 2.3) * 0.05)
	D[WEAPON] = ANG(w * (0.5 - 1.9 * aim) - s * 0.4, 0, 0) -- aiming: keep the barrel level
	D[EXTRA] = CFrame.new(0, sin(t * 2.6) * 0.06, 0) * ANG(0, t * 1.5, 0)
end

-- iter1 shared hero animation (players' Herd Suit and bots): an attack lasts
-- SWING_TIME; its first 30% is the anticipation (lean back, crouch = squash),
-- 30-50% the hit (lunge, stretch, trunk / weapon arc > 90 deg), the rest an
-- eased recovery. Returns (wind, hit) in 0..1.
Rig.SWING_TIME = 0.4
local function attackPhases(x: number): (number, number)
	if x <= 0 or x >= 1 then
		return 0, 0
	end
	if x < 0.3 then
		return smooth(x / 0.3), 0
	elseif x < 0.5 then
		local f = smooth((x - 0.3) / 0.2)
		return 1 - f, f
	end
	return 0, 1 - smooth((x - 0.5) / 0.5)
end
Rig.attackPhases = attackPhases

-- iter7 (team Mesh): per-ability-kind cast poses for elephants (bots and Herd
-- Suit heroes; BotAnimator.cast(id, kind, dur)). Each entry: time = seconds of
-- the cast curve, hold = true keeps the pose for the ability's duration (the
-- channel / anchored state), and the shape weights read by poseElephant:
--   rear (generic rear-up), crouch (drop + splayed legs), aim (trunk level,
--   steady body), reach (trunk / head forward), spin (body turn), hop (jump),
--   tap (trunk hammering down), whip (trunk lash), ears (spread), recoil.
Rig.CAST = {
	lance = { time = 0.8, aim = 1, recoil = 1, ears = 0.4 }, -- ele_vation: aim-hold, then the lance kick
	mark = { time = 0.6, aim = 0.7, reach = 0.3, ears = 0.3 },
	tether = { time = 0.6, hold = true, reach = 1, ears = 0.8, crouch = 0.15 }, -- elephaid: channel
	anchor = { time = 0.7, hold = true, crouch = 1, aim = 0.5, ears = -0.3 }, -- trunkillery: dig in
	chain = { time = 0.5, whip = 1, ears = 0.5 },
	vortex = { time = 0.7, spin = 1, ears = 1 },
	leap = { time = 0.6, hop = 1, rear = 0.4, ears = 0.6 },
	turret = { time = 0.6, tap = 1, crouch = 0.4 },
	barricade = { time = 0.6, tap = 1, crouch = 0.5 },
	repair = { time = 0.6, hold = true, tap = 1, crouch = 0.3 },
} :: { [string]: { [string]: any } }

-- Bot elephants: walk (legs, trunk sway, ear flaps), class auto-attack
-- (melee trunk swing / ranged trunk aim + recoil / gust ear flap / thrust),
-- ability rear-up, downed slump, revive hop.
local function poseElephant(st: State, D: { CFrame }, _k: number, detail: number)
	local m, g, t = st.moving, st.gait, st.t
	local sg = sin(g)
	local down = smooth(st.downed)
	-- run cycle (eased by st.moving) or, when downed, a slow crawl paddle
	local legA = sg * 0.55 * m * (1 - down) + sin(g * 0.5) * 0.3 * m * down
	local cp = punch(st.cast, 0.3)
	-- iter7: per-kind cast shapes (Rig.CAST); a held cast stays at full weight
	local ck = if st.castKind then Rig.CAST[st.castKind] else nil
	local cw = if ck and (st.castHold or 0) > 0 then 1 else cp
	local c = if ck then cw * (ck.rear or 0) else cp
	local cCrouch = if ck then cw * (ck.crouch or 0) else 0
	local cAim = if ck then cw * (ck.aim or 0) else 0
	local cReach = if ck then cw * (ck.reach or 0) else 0
	local cSpin = if ck and ck.spin then smooth(st.cast) * (ck.spin * 2 * pi) else 0
	local cHop = if ck and ck.hop then sin(math.clamp(st.cast, 0, 1) * pi) * ck.hop else 0
	local cTap = if ck and ck.tap then cw * ck.tap * abs(sin(t * 14)) else 0
	local cWhip = if ck and ck.whip then sin(math.clamp(st.cast, 0, 1) * pi * 2) * ck.whip else 0
	local cEars = if ck then cw * (ck.ears or 0) else cp * 0.5
	local cKick = if ck
			and ck.recoil
			and st.cast > 0.7
		then punch((st.cast - 0.7) / 0.3, 0.2) * ck.recoil
		else 0
	local limp = down * 0.5
	local splay = cCrouch * 0.35
	D[LFL] = ANG(legA + c * 1.1 + limp - cCrouch * 0.25, 0, -splay)
	D[LBR] = ANG(legA - c * 0.15 - limp * 0.4 + cCrouch * 0.2, 0, splay)
	D[LFR] = ANG(-legA + c * 1.1 + limp - cCrouch * 0.25, 0, splay)
	D[LBL] = ANG(-legA - c * 0.15 - limp * 0.4 + cCrouch * 0.2, 0, -splay)
	local breath = sin(t * (if down > 0.5 then 1.2 else 2)) * 0.04
	local bob = abs(cos(g)) * 0.12 * m + breath
	local sw = st.swing
	local kind = st.swingKind
	local wind, hit = attackPhases(sw)
	local thrust = if kind == "thrust" then hit else 0
	local melee0 = kind == "melee" or kind == "thrust"
	-- iter7: marksman ("snipe": long steady aim, hard kick) and artillery
	-- ("mortar": squat, heavy upward lob and a bounce back)
	local snipeAim = if kind == "snipe" then (if sw > 0 then 1 - smooth((sw - 0.75) / 0.25) else 0) else 0
	local mortar = if kind == "mortar" then hit else 0
	-- anticipation: rear back and crouch (squash); hit: lunge forward and rise (stretch)
	local leanA = if melee0 then wind * 0.22 - hit * 0.28 else -hit * 0.1
	local crouch = wind * (if melee0 then 0.25 else 0.1) - hit * 0.12
	local push = if melee0
		then -hit * 0.55
		else hit
			* (if kind == "snipe" then 0.5 elseif kind == "mortar" then 0.4 else 0.25) -- ranged: recoil back
	crouch += mortar * 0.25 + wind * (if kind == "mortar" then 0.2 else 0)
	local fl = punch(st.flinch, 0.25)
	-- iter3 (T-30) less stiff: lean into turns, an idle weight shift, and a
	-- landing squash at the end of the revive hop and after a flinch
	local lean = st.lean or 0
	local idle = 1 - m
	local shift = sin(t * 0.9) * 0.035 * idle
	local land = if st.revive > 0.75 then punch((st.revive - 0.75) / 0.25, 0.4) * 0.22 else 0
	local squash = land + fl * 0.1
	D[BODY] = CFrame.new(
		shift * 3 * (1 - snipeAim),
		bob - c * 0.3 - crouch - squash - cCrouch * 0.45 + cHop * 1.2,
		push - thrust * 0.3 + cKick * 0.5 - cReach * 0.15
	) * ANG(
		c * 0.45 + leanA + fl * 0.15 - cCrouch * 0.08 + cKick * 0.12 + cHop * 0.25,
		lean * 0.08 + cSpin,
		sg * 0.04 * m + fl * 0.08 * st.side - lean * 0.14 * m + shift
	)
	if detail >= 2 then
		D[HEAD], D[EARL], D[EARR], D[TAIL], D[TR1], D[TR2], D[TR3] =
			IDENT, IDENT, IDENT, IDENT, IDENT, IDENT, IDENT
		return
	end
	local shoot = if kind == "shoot" or kind == "lob" or kind == "snipe" or kind == "mortar" then hit else 0
	shoot = math.max(shoot, snipeAim * 0.9, cAim)
	local gust = if kind == "gust" then punch(sw, 0.3) else 0
	-- melee: wind the trunk / weapon back during the anticipation, whip it
	-- across (~110 deg) on the hit, ease back during the recovery
	local swipe = 0
	if kind == "melee" and sw > 0 then
		swipe = -wind * 0.85 + hit * 1.1
	end
	local nod = sin(g * 2) * 0.05 * m
	D[HEAD] = ANG(
		nod + shoot * 0.12 + c * 0.2 - down * 0.25 + wind * 0.1 - hit * 0.08 - cReach * 0.15 + cCrouch * 0.1,
		swipe * 0.35 + sin(t * 0.6) * 0.15 * (1 - m) * (1 - math.max(snipeAim, cAim)) + lean * 0.25,
		-lean * 0.06
	)
	local flap = sin(t * 3.2) * 0.12
		+ sin(g) * 0.25 * m
		+ gust * 1.1 * sin(t * 30)
		+ cEars
		+ fl * 0.6
		+ wind * 0.25
	D[EARL] = ANG(0, -flap - gust * 0.6, 0)
	D[EARR] = ANG(0, flap + gust * 0.6, 0)
	-- trunk: idle sway, raised to aim when shooting, swiping for melee, droop when downed
	local sway = sin(t * 1.7) * 0.18 + sin(g) * 0.15 * m
	local steady = 1 - math.max(snipeAim, cAim, cReach) * 0.85 -- aiming / channeling: no idle sway
	sway *= steady
	local raise = shoot * 1.1
		+ c * 0.9
		+ thrust * 0.5
		+ mortar * 0.6
		+ cReach * 0.8
		- cTap * 0.9
		+ cKick * 0.5
	local lash = cWhip * 0.9
	D[TR1] = ANG(raise * 0.45 - down * 0.3, sway + swipe + lash, 0)
	D[TR2] = ANG(raise * 0.4 - down * 0.2 + cReach * 0.1, sway * 0.6 + swipe * 0.5 + lash * 0.7, 0)
	D[TR3] =
		ANG(raise * 0.5 + shoot * 0.4 - cTap * 0.4 + sin(t * 5) * 0.08 * cReach, sway * 0.4 + lash * 0.5, 0)
	D[TAIL] = ANG(-cCrouch * 0.5, sin(t * 3) * 0.4 * (1 - cCrouch * 0.7), sin(t * 2.1) * 0.2)
end

local STYLES: { [string]: (State, { CFrame }, number, number) -> () } = {
	mouse = poseMouse,
	biped = poseBiped,
	elephant = poseElephant,
}
Rig.STYLES = STYLES

function Rig.pose(style: string, st: State, D: { CFrame }, k: number, detail: number)
	local fn = STYLES[style] or poseMouse
	fn(st, D, k, detail)
end

-- Advances the timers of a state by dt. `speed` = ground speed (studs/s) and
-- `stride` = studs per gait cycle at k = 1.
function Rig.step(st: State, dt: number, speed: number, k: number, stride: number)
	st.t += dt * (if st.enraged then 1.5 else 1)
	st.gait += speed * dt / math.max(0.2, stride * k) * 2 * pi
	if st.lunge > 0 then
		st.lunge += dt / 0.32
		if st.lunge >= 1 then
			st.lunge = 0
		end
	end
	if st.flinch > 0 then
		st.flinch += dt / 0.2
		if st.flinch >= 1 then
			st.flinch = 0
		end
	end
	if st.strike > 0 then
		st.strike += dt / 0.45
		if st.strike >= 1 then
			st.strike = 0
		end
	end
	if st.roar > 0 then
		st.roar += dt / 1.2
		if st.roar >= 1 then
			st.roar = 0
		end
	end
	if st.cast > 0 then
		local ck = if st.castKind then Rig.CAST[st.castKind] else nil
		if (st.castHold or 0) > 0 then
			-- iter7: held casts (channel, dig-in) stay at full pose, then release
			st.castHold = math.max(0, st.castHold - dt)
			st.cast = math.min(st.cast + dt / (if ck then ck.time else 0.6), 0.5)
		else
			st.cast += dt / (if ck then ck.time else 0.6)
			if st.cast >= 1 then
				st.cast = 0
				st.castKind = nil
			end
		end
	end
	if st.swing > 0 then
		st.swing += dt / Rig.SWING_TIME
		if st.swing >= 1 then
			st.swing = 0
		end
	end
	if st.revive > 0 then
		st.revive += dt / 0.6
		if st.revive >= 1 then
			st.revive = 0
		end
	end
end

return Rig
