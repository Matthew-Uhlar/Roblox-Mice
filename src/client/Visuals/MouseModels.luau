--!strict
-- MouseModels (v3 Graphics, client): rigged part models for every enemy kind.
--
--   MouseModels.build(kindId, def, scale, elite?) ->
--     { parts, low, lod, radius, bones, style = "mouse", stride }
--     parts  full model, ~20-26 parts, every part owned by a bone (Spec.bone)
--     low    low-spec / mid-distance model, 8-10 parts (same bones)
--     lod    3 parts, static: drawn beyond the far LOD distance
--     bones  skeleton for Visuals/Rig: body, head, earL/R, tail, tail2,
--            legFL/FR/BL/BR, weapon
--   Chibi proportions (STYLE.md "toy-like"): a big round head with big ears,
--   glossy bead eyes with a Neon glint, a pink nose and a little muzzle, stubby
--   egg legs, a three-segment curling tail. Silhouette first, colour second:
--   Mouse is the baseline; Rat Runner is long and lean with a red headband and
--   a long tail; Chonk is a ball hugging a cheese wedge; Crumb Slinger carries a
--   slingshot (raised on attack) and a crumb sack; Fuse Mouse has a bomb with a
--   lit fuse on its back; the golden Carrier hauls a treasure sack. Built at
--   unit radius 1.2 and scaled to the enemy's hitbox radius.

local Spec = require(script.Parent.Spec)

local MouseModels = {}

MouseModels.LOD_DISTANCE = 120 -- beyond this: the 3-part LOD, no animation
MouseModels.ANIM_FULL = 60 -- full rig animation within this
MouseModels.STRIDE = 2.2 -- studs per run cycle at scale 1
MouseModels.SHADOW_SCALE = 2.3 -- contact shadow diameter / radius (v4)

local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local rad = math.rad
local M = Enum.Material
local rgb = Color3.fromRGB

local PINK = rgb(246, 170, 186)
local PINK_DARK = rgb(232, 112, 138)
local EYE = rgb(26, 20, 26)
local WHITE = rgb(255, 255, 255)
local GOLD = rgb(255, 196, 40)
local SHADOW = rgb(30, 20, 15)

type Look = {
	body: Color3,
	belly: Color3,
	bodySize: Vector3,
	headSize: Vector3,
	ear: number,
	tail: number,
	legs: number,
	snout: number,
}

local LOOKS: { [string]: Look } = {
	mouse = {
		body = rgb(96, 62, 44), -- v4 readability: darker warm brown (V4-B S1-6)
		belly = rgb(236, 214, 186),
		bodySize = V3(1.6, 1.35, 1.85),
		headSize = V3(1.45, 1.3, 1.3),
		ear = 0.95,
		tail = 1,
		legs = 1,
		snout = 1,
	},
	rat_runner = {
		body = rgb(84, 74, 76), -- v4: darker
		belly = rgb(200, 186, 178),
		bodySize = V3(1.2, 1.05, 2.5),
		headSize = V3(1.1, 1.0, 1.45),
		ear = 0.7,
		tail = 1.55,
		legs = 1.3,
		snout = 1.5,
	},
	chonk = {
		body = rgb(92, 64, 104), -- v4: plum, never confused with grey elephants
		belly = rgb(232, 228, 240),
		bodySize = V3(2.2, 1.95, 2.15),
		headSize = V3(1.5, 1.3, 1.25),
		ear = 0.75,
		tail = 0.7,
		legs = 0.75,
		snout = 0.8,
	},
	crumb_slinger = {
		body = rgb(132, 96, 62), -- v4: darker; red accent below
		belly = rgb(248, 230, 196),
		bodySize = V3(1.5, 1.3, 1.75),
		headSize = V3(1.4, 1.28, 1.28),
		ear = 1.0,
		tail = 1,
		legs = 1,
		snout = 1,
	},
	carrier = {
		body = rgb(255, 200, 64),
		belly = rgb(255, 244, 200),
		bodySize = V3(1.5, 1.3, 1.8),
		headSize = V3(1.4, 1.28, 1.28),
		ear = 1.0,
		tail = 1.1,
		legs = 1.1,
		snout = 1,
	},
	fuse_mouse = {
		body = rgb(204, 96, 72),
		belly = rgb(248, 200, 170),
		bodySize = V3(1.55, 1.3, 1.8),
		headSize = V3(1.4, 1.28, 1.28),
		ear = 0.95,
		tail = 1,
		legs = 1,
		snout = 1,
	},
}
MouseModels.LOOKS = LOOKS

local function lookFor(id: string, def: any): Look
	if LOOKS[id] then
		return LOOKS[id]
	end
	local b = if type(def) == "table" then def.behavior else nil
	if b == "tank" then
		return LOOKS.chonk
	elseif b == "ranged" then
		return LOOKS.crumb_slinger
	elseif b == "fuse" then
		return LOOKS.fuse_mouse
	end
	return LOOKS.mouse
end

type Frame = {
	bodyY: number,
	bodyZ: number,
	headY: number,
	headZ: number,
	len: number,
	legH: number,
}

local function frameOf(L: Look): Frame
	local legH = 0.55 * L.legs
	local bodyY = legH + L.bodySize.Y * 0.38
	local len = L.bodySize.Z
	local headZ = -len / 2 - L.headSize.Z * 0.2
	local headY = bodyY + L.bodySize.Y * 0.42 + L.headSize.Y * 0.1
	return { bodyY = bodyY, bodyZ = 0.1, headY = headY, headZ = headZ, len = len, legH = legH }
end

local function tailBase(L: Look, F: Frame): CFrame
	return CF(0, F.bodyY + L.bodySize.Y * 0.05, F.len / 2)
end

local function tailEnd1(L: Look, F: Frame): CFrame
	return tailBase(L, F) * ANG(rad(-6), 0, 0) * CF(0, 0, 0.62 * L.tail)
end

local function skeleton(L: Look, F: Frame): Spec.Skeleton
	local bones: Spec.Skeleton = {
		body = { pivot = CF(0, F.bodyY, F.bodyZ) },
		head = { pivot = CF(0, F.headY - L.headSize.Y * 0.3, F.headZ + L.headSize.Z * 0.3), parent = "body" },
		tail = { pivot = tailBase(L, F), parent = "body" },
		tail2 = { pivot = tailEnd1(L, F), parent = "tail" },
		weapon = { pivot = CF(0.55, F.bodyY + 0.1, -F.len / 2 + 0.1), parent = "body" },
	}
	for _, s in { -1, 1 } do
		bones[if s < 0 then "earL" else "earR"] = {
			pivot = CF(s * L.headSize.X * 0.3, F.headY + L.headSize.Y * 0.36, F.headZ + 0.1),
			parent = "head",
		}
	end
	for _, side in { -1, 1 } do
		for _, front in { -1, 1 } do
			local name = "leg" .. (if front < 0 then "F" else "B") .. (if side < 0 then "L" else "R")
			bones[name] = {
				pivot = CF(side * L.bodySize.X * 0.27, F.legH + 0.05, front * F.len * 0.27 + F.bodyZ),
			}
		end
	end
	return bones
end

local function bodyParts(l: Spec.List, L: Look, F: Frame)
	Spec.bone("body")
	Spec.egg(l, L.bodySize, CF(0, F.bodyY, F.bodyZ), L.body, M.SmoothPlastic, { tint = true })
	Spec.egg(
		l,
		L.bodySize * V3(0.72, 0.72, 0.8),
		CF(0, F.bodyY - L.bodySize.Y * 0.13, F.bodyZ - L.bodySize.Z * 0.12),
		L.belly,
		M.SmoothPlastic,
		{ tint = true }
	)
end

local function headParts(l: Spec.List, L: Look, F: Frame, full: boolean)
	local hy, hz = F.headY, F.headZ
	local H = L.headSize
	Spec.bone("head")
	Spec.egg(l, H, CF(0, hy, hz), L.body, M.SmoothPlastic, { tint = true })
	-- muzzle + nose
	local mz = hz - H.Z * 0.42 - 0.1 * L.snout
	Spec.egg(
		l,
		V3(H.X * 0.52, H.Y * 0.42, H.Z * 0.42 * L.snout),
		CF(0, hy - H.Y * 0.16, mz),
		L.belly,
		M.SmoothPlastic,
		{ tint = true }
	)
	Spec.ball(l, 0.26, CF(0, hy - H.Y * 0.06, mz - H.Z * 0.2 * L.snout), PINK_DARK, M.SmoothPlastic)
	-- glossy bead eyes
	for _, s in { -1, 1 } do
		local e = CF(s * H.X * 0.22, hy + H.Y * 0.1, hz - H.Z * 0.42)
		Spec.egg(l, V3(0.3, 0.38, 0.2), e, EYE, M.SmoothPlastic)
		if full then
			Spec.ball(l, 0.11, e * CF(-s * 0.04, 0.08, -0.09), WHITE, M.Neon)
		end
	end
	if full then
		-- rosy cheeks + whisker tufts
		for _, s in { -1, 1 } do
			Spec.egg(
				l,
				V3(0.32, 0.2, 0.12),
				CF(s * H.X * 0.33, hy - H.Y * 0.12, hz - H.Z * 0.36) * ANG(0, rad(s * 25), 0),
				PINK,
				M.SmoothPlastic,
				{ t = 0.25 }
			)
			-- iter1 detail: a pair of whiskers per side
			Spec.block(
				l,
				V3(0.9 * L.snout, 0.04, 0.04),
				CF(s * (H.X * 0.32 + 0.3), hy - H.Y * 0.1, mz - 0.05) * ANG(0, rad(s * -12), rad(s * 8)),
				rgb(245, 235, 225),
				M.SmoothPlastic
			)
		end
		-- buck teeth
		Spec.block(
			l,
			V3(0.2, 0.16, 0.06),
			CF(0, hy - H.Y * 0.3, mz - H.Z * 0.16 * L.snout),
			WHITE,
			M.SmoothPlastic
		)
	end
end

local function earParts(l: Spec.List, L: Look, F: Frame, inner: boolean)
	for _, s in { -1, 1 } do
		Spec.bone(if s < 0 then "earL" else "earR")
		local at = CF(s * L.headSize.X * 0.34, F.headY + L.headSize.Y * 0.36 + L.ear * 0.38, F.headZ + 0.12)
			* ANG(rad(-8), rad(s * 12), rad(-s * 22))
		Spec.egg(
			l,
			V3(L.ear, L.ear * 0.95, 0.16),
			at,
			L.body:Lerp(PINK, 0.2),
			M.SmoothPlastic,
			{ tint = true }
		)
		if inner then
			Spec.egg(l, V3(L.ear * 0.7, L.ear * 0.66, 0.1), at * CF(0, -0.02, -0.05), PINK, M.SmoothPlastic)
		end
	end
end

local function legParts(l: Spec.List, L: Look, F: Frame)
	local c = L.body:Lerp(EYE, 0.2)
	for _, side in { -1, 1 } do
		for _, front in { -1, 1 } do
			local name = "leg" .. (if front < 0 then "F" else "B") .. (if side < 0 then "L" else "R")
			Spec.bone(name)
			local x, z = side * L.bodySize.X * 0.27, front * F.len * 0.27 + F.bodyZ
			Spec.egg(
				l,
				V3(0.42, F.legH + 0.25, 0.48),
				CF(x, (F.legH + 0.25) / 2, z - 0.05),
				c,
				M.SmoothPlastic,
				{
					tint = true,
				}
			)
		end
	end
end

local function tailParts(l: Spec.List, L: Look, F: Frame, segs: number)
	local cf = tailBase(L, F)
	local segLen = 0.62 * L.tail
	for i = 1, segs do
		Spec.bone(if i == 1 then "tail" else "tail2")
		cf = cf * ANG(rad(if i == 1 then -6 else -16), 0, 0)
		Spec.cyl(
			l,
			segLen + 0.08,
			math.max(0.1, 0.2 - i * 0.03),
			cf * CF(0, 0, segLen / 2) * ANG(0, rad(90), 0),
			PINK
		)
		cf = cf * CF(0, 0, segLen) -- segment 1 ends at the tail2 pivot (tailEnd1)
	end
end

local function crown(l: Spec.List, L: Look, F: Frame)
	Spec.bone("head")
	local top = CF(0, F.headY + L.headSize.Y * 0.5, F.headZ)
	Spec.ucyl(l, 0.32, 0.7, top, GOLD, M.Neon, { cond = "elite" })
	for i = 0, 2 do
		local a = i / 3 * math.pi * 2
		Spec.ball(
			l,
			0.16,
			top * CF(math.cos(a) * 0.3, 0.24, math.sin(a) * 0.3),
			GOLD,
			M.Neon,
			{ cond = "elite" }
		)
	end
end

local function extras(l: Spec.List, id: string, L: Look, F: Frame, full: boolean)
	local back = CF(0, F.bodyY + L.bodySize.Y * 0.48, F.bodyZ + 0.15)
	if id == "rat_runner" then
		Spec.bone("head")
		Spec.ucyl(
			l,
			0.18,
			L.headSize.X * 1.04,
			CF(0, F.headY + 0.18, F.headZ + 0.05) * ANG(rad(-14), 0, 0),
			rgb(225, 50, 45),
			M.Fabric
		)
		if full then
			Spec.egg(
				l,
				V3(0.18, 0.5, 0.14),
				CF(0.1, F.headY + 0.1, F.headZ + L.headSize.Z * 0.55) * ANG(rad(40), 0, rad(-20)),
				rgb(225, 50, 45),
				M.Fabric
			)
		end
	elseif id == "chonk" then
		Spec.bone("body")
		local front = CF(0, F.bodyY - 0.2, F.bodyZ - L.bodySize.Z * 0.48)
		Spec.wedge(l, V3(1.2, 0.7, 1.0), front * ANG(rad(-10), rad(180), 0), rgb(255, 205, 60))
		if full then
			Spec.ball(l, 0.22, front * CF(0.3, 0.05, -0.2), rgb(225, 170, 40))
			Spec.ball(l, 0.18, front * CF(-0.25, -0.1, -0.35), rgb(225, 170, 40))
		end
	elseif id == "crumb_slinger" then
		Spec.bone("weapon")
		local hand = CF(0.55, F.bodyY + 0.1, -F.len / 2 + 0.1) * ANG(rad(-25), 0, 0)
		Spec.ucyl(l, 0.7, 0.12, hand * CF(0, 0.3, 0), rgb(130, 86, 48), M.Wood)
		Spec.block(l, V3(0.55, 0.1, 0.1), hand * CF(0, 0.66, 0), rgb(130, 86, 48), M.Wood)
		if full then
			for _, s in { -1, 1 } do
				Spec.ucyl(l, 0.3, 0.09, hand * CF(s * 0.24, 0.82, 0), rgb(130, 86, 48), M.Wood)
			end
			Spec.block(l, V3(0.5, 0.05, 0.05), hand * CF(0, 0.92, 0.05), rgb(240, 120, 110), M.Fabric)
		end
		-- v4 readability: a red-orange headband + sling pouch (STYLE accent #FF5A4E)
		Spec.bone("head")
		Spec.ucyl(
			l,
			0.2,
			L.headSize.X * 1.05,
			CF(0, F.headY + 0.2, F.headZ + 0.05) * ANG(rad(-14), 0, 0),
			rgb(255, 90, 78),
			M.SmoothPlastic
		)
		Spec.bone("body")
		Spec.egg(l, V3(0.85, 0.85, 0.75), back * CF(0, 0.25, 0.25), rgb(255, 90, 78), M.Fabric)
		if full then
			Spec.ucyl(l, 0.12, 0.5, back * CF(0, 0.7, 0.25), rgb(150, 110, 70), M.Fabric)
		end
	elseif id == "fuse_mouse" then
		Spec.bone("body")
		local bomb = back * CF(0, 0.5, 0.15)
		Spec.ball(l, 1.0, bomb, rgb(40, 38, 48), M.Metal)
		Spec.ucyl(l, 0.22, 0.4, bomb * CF(0, 0.5, 0), rgb(70, 70, 80), M.Metal)
		Spec.ucyl(l, 0.4, 0.09, bomb * CF(0.1, 0.75, 0) * ANG(0, 0, rad(-25)), rgb(150, 120, 80), M.Fabric)
		Spec.ball(l, 0.3, bomb * CF(0.2, 0.97, 0), rgb(255, 196, 70), M.Neon, { anim = Spec.pulse(0.6, 22) })
	elseif id == "carrier" then
		Spec.bone("body")
		local sack = back * CF(0, 0.45, 0.2)
		Spec.egg(l, V3(1.05, 1.0, 0.95), sack, rgb(150, 100, 60), M.Fabric)
		Spec.ucyl(l, 0.18, 0.5, sack * CF(0, 0.52, 0), rgb(255, 210, 70), M.Fabric)
		if full then
			Spec.ball(
				l,
				0.24,
				sack * CF(0.22, 0.6, -0.1),
				rgb(255, 230, 120),
				M.Neon,
				{ anim = Spec.pulse(0.5, 7) }
			)
			Spec.ball(
				l,
				0.18,
				sack * CF(-0.2, 0.62, 0.1),
				rgb(255, 230, 120),
				M.Neon,
				{ anim = Spec.pulse(0.5, 9) }
			)
		end
	end
end

function MouseModels.build(
	id: string,
	def: any,
	scale: number?,
	elite: boolean?
): {
	parts: Spec.List,
	low: Spec.List,
	lod: Spec.List,
	radius: number,
	bones: Spec.Skeleton,
	style: string,
	stride: number,
}
	local L = lookFor(id, def)
	local r = math.max(0.4, tonumber(if type(def) == "table" then def.radius else nil) or 1.2) * (scale or 1)
	local F = frameOf(L)
	local bones = skeleton(L, F)

	local full: Spec.List = {}
	bodyParts(full, L, F)
	headParts(full, L, F, true)
	earParts(full, L, F, true)
	legParts(full, L, F)
	tailParts(full, L, F, if id == "rat_runner" then 4 else 3)
	extras(full, id, L, F, true)
	crown(full, L, F)

	local low: Spec.List = {}
	Spec.bone("body")
	Spec.egg(low, L.bodySize, CF(0, F.bodyY, F.bodyZ), L.body, M.SmoothPlastic, { tint = true })
	headParts(low, L, F, false)
	earParts(low, L, F, false)
	Spec.bone("tail")
	Spec.cyl(
		low,
		1.3 * L.tail,
		0.18,
		CF(0, F.bodyY, F.len / 2 + 0.55 * L.tail) * ANG(rad(-20), rad(90), 0),
		PINK,
		M.SmoothPlastic
	)
	extras(low, id, L, F, false)
	crown(low, L, F)

	Spec.bone(nil)
	local lod: Spec.List = {}
	Spec.egg(lod, L.bodySize, CF(0, F.bodyY, F.bodyZ), L.body, M.SmoothPlastic, { tint = true })
	Spec.egg(lod, L.headSize, CF(0, F.headY, F.headZ), L.body, M.SmoothPlastic, { tint = true })
	Spec.egg(
		lod,
		V3(L.headSize.X * 1.5, L.ear * 0.75, 0.16),
		CF(0, F.headY + L.headSize.Y * 0.5, F.headZ + 0.12),
		L.body:Lerp(PINK, 0.35),
		M.SmoothPlastic,
		{ tint = true }
	)
	Spec.bone(nil)

	-- v4 readability (V4-B S1-6): a dark contact-shadow disc under every mouse
	-- (#1E140F, 0.45 transparency, 2.3 x radius) on the full and low models; the
	-- far LOD (beyond 120 studs) has none.
	Spec.bone(nil)
	for _, list in { full, low } do
		Spec.ucyl(list, 0.05, 1.2 * MouseModels.SHADOW_SCALE, CF(0, 0.07, 0), SHADOW, M.SmoothPlastic, {
			t = 0.45,
			bone = "",
			ground = true,
		})
	end

	local k = r / 1.2 -- the unit model is a radius-1.2 mouse
	local _ = elite
	return {
		parts = Spec.scaled(full, k),
		low = Spec.scaled(low, k),
		lod = Spec.scaled(lod, k),
		radius = r,
		bones = Spec.scaledBones(bones, k),
		style = "mouse",
		stride = MouseModels.STRIDE * L.legs,
	}
end

return MouseModels
