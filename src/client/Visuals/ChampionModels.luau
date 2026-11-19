--!strict
-- ChampionModels (v3 Graphics, client): rigged part models for the Mouse
-- Champions (Config/Champions; snapshot kinds 100 + Champions.ORDER index).
--
--   ChampionModels.build(champId, def?) ->
--     { parts, bones, style = "biped", radius, height, k, stride, accent }
--   ChampionModels.ORDER   the six known ids (preview / fallback order)
--
-- Every champion is a bipedal hero-mouse 1.5-2.5x mouse size with a readable
-- silhouette prop (STYLE.md: silhouette first): Captain Whiskers (armour,
-- round shield, sword, red cape), the Cheese Golem (a holey cheese-block body),
-- the Rat King (crown, ermine robe, orb sceptre), Sniper Squeak (hood, long
-- rifle with a glinting scope), the Mad Chemist (goggles, lab coat, bubbling
-- flasks) and the Thunder Hamster (a spiky ball of fur in an electric aura).
-- Designed at unit radius 2.4 (k = 1) and scaled to the hitbox. The skeleton
-- (Visuals/Rig "biped"): body, head, jaw, earL/R, armL/R, weapon (in the right
-- hand), legFL/FR (left / right leg), tail, tail2, cape, extra (orbiting bits).
-- HordeRenderer adds the name tag + HP bar billboard and the hit / enrage glow.

local Spec = require(script.Parent.Spec)

local ChampionModels = {}

ChampionModels.ORDER = {
	"champ_captain",
	"champ_golem",
	"champ_ratking",
	"champ_sniper",
	"champ_chemist",
	"champ_thunder",
}
ChampionModels.UNIT_RADIUS = 2.4
ChampionModels.STRIDE = 3.2

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
local STEEL = rgb(186, 194, 206)

type L = Spec.List

local HIP_Y, BODY_Y, SHOULDER_Y, NECK_Y = 1.25, 2.15, 2.85, 3.05

local function skeleton(): Spec.Skeleton
	return {
		body = { pivot = CF(0, HIP_Y + 0.05, 0.1) },
		head = { pivot = CF(0, NECK_Y, 0), parent = "body" },
		jaw = { pivot = CF(0, 3.3, -0.85), parent = "head" },
		earL = { pivot = CF(-0.55, 4.25, -0.1), parent = "head" },
		earR = { pivot = CF(0.55, 4.25, -0.1), parent = "head" },
		armL = { pivot = CF(-1.05, SHOULDER_Y, 0.05), parent = "body" },
		armR = { pivot = CF(1.05, SHOULDER_Y, 0.05), parent = "body" },
		weapon = { pivot = CF(1.15, 1.6, -0.15), parent = "armR" },
		legFL = { pivot = CF(-0.55, HIP_Y, 0.1) },
		legFR = { pivot = CF(0.55, HIP_Y, 0.1) },
		tail = { pivot = CF(0, 1.55, 0.85), parent = "body" },
		tail2 = { pivot = CF(0, 1.75, 2.0), parent = "tail" },
		cape = { pivot = CF(0, SHOULDER_Y + 0.15, 0.6), parent = "body" },
		extra = { pivot = CF(0, BODY_Y, 0), parent = "body" },
	}
end

type Look = { fur: Color3, belly: Color3, ear: number, snout: number, noTail: boolean? }

-- The shared hero-mouse body: legs, torso, belly, arms, head, ears, tail.
local function mouseBody(l: L, look: Look, skip: { [string]: boolean }?)
	local sk = skip or {}
	local fur, belly = look.fur, look.belly
	local dark = fur:Lerp(EYE, 0.25)
	-- legs + feet
	for _, s in { -1, 1 } do
		Spec.bone(if s < 0 then "legFL" else "legFR")
		if not sk.legs then
			Spec.egg(l, V3(0.68, 1.25, 0.72), CF(s * 0.55, 0.72, 0.1), fur, M.SmoothPlastic, { tint = true })
		end
		Spec.egg(l, V3(0.78, 0.4, 1.05), CF(s * 0.58, 0.2, -0.12), dark, M.SmoothPlastic, { tint = true })
	end
	-- torso
	Spec.bone("body")
	if not sk.torso then
		Spec.egg(l, V3(1.95, 2.05, 1.65), CF(0, BODY_Y, 0.1), fur, M.SmoothPlastic, { tint = true })
		Spec.egg(l, V3(1.35, 1.5, 0.9), CF(0, BODY_Y - 0.15, -0.38), belly, M.SmoothPlastic, { tint = true })
	end
	-- arms + hands
	for _, s in { -1, 1 } do
		Spec.bone(if s < 0 then "armL" else "armR")
		Spec.egg(
			l,
			V3(0.52, 1.3, 0.52),
			CF(s * 1.12, SHOULDER_Y - 0.6, 0.0) * ANG(0, 0, rad(s * 8)),
			fur,
			M.SmoothPlastic,
			{
				tint = true,
			}
		)
		Spec.ball(l, 0.55, CF(s * 1.17, 1.6, -0.08), belly, M.SmoothPlastic, { tint = true })
	end
	-- head
	Spec.bone("head")
	local hy, hz = 3.75, -0.15
	if not sk.head then
		Spec.egg(l, V3(1.8, 1.62, 1.6), CF(0, hy, hz), fur, M.SmoothPlastic, { tint = true })
		local mz = hz - 0.78 - 0.12 * look.snout
		Spec.egg(
			l,
			V3(0.95, 0.68, 0.75 * look.snout),
			CF(0, hy - 0.28, mz),
			belly,
			M.SmoothPlastic,
			{ tint = true }
		)
		Spec.ball(l, 0.3, CF(0, hy - 0.12, mz - 0.38 * look.snout), PINK_DARK, M.SmoothPlastic)
		for _, s in { -1, 1 } do
			local e = CF(s * 0.38, hy + 0.15, hz - 0.68)
			Spec.egg(l, V3(0.36, 0.46, 0.22), e, EYE)
			Spec.ball(l, 0.13, e * CF(-s * 0.05, 0.1, -0.1), WHITE, M.Neon)
			Spec.egg(
				l,
				V3(0.36, 0.22, 0.12),
				CF(s * 0.58, hy - 0.22, hz - 0.6) * ANG(0, rad(s * 25), 0),
				PINK,
				M.SmoothPlastic,
				{
					t = 0.25,
				}
			)
		end
		Spec.bone("jaw")
		Spec.egg(l, V3(0.5, 0.2, 0.3), CF(0, hy - 0.58, mz + 0.05), rgb(120, 40, 50))
	end
	-- ears
	if not sk.ears then
		for _, s in { -1, 1 } do
			Spec.bone(if s < 0 then "earL" else "earR")
			local at = CF(s * (0.55 + look.ear * 0.3), 4.25 + look.ear * 0.4, -0.1)
				* ANG(rad(-6), rad(s * 10), rad(-s * 20))
			Spec.egg(
				l,
				V3(look.ear, look.ear * 0.95, 0.18),
				at,
				fur:Lerp(PINK, 0.2),
				M.SmoothPlastic,
				{ tint = true }
			)
			Spec.egg(l, V3(look.ear * 0.7, look.ear * 0.66, 0.1), at * CF(0, -0.02, -0.06), PINK)
		end
	end
	-- tail
	if not look.noTail then
		Spec.bone("tail")
		Spec.cyl(l, 1.3, 0.24, CF(0, 1.62, 1.45) * ANG(rad(-10), rad(90), 0), PINK)
		Spec.bone("tail2")
		Spec.cyl(l, 1.2, 0.18, CF(0, 2.0, 2.45) * ANG(rad(-35), rad(90), 0), PINK)
	end
end

local B: { [string]: (l: L) -> (Color3, number) } = {}
-- Bipeds that aim level (rifles) instead of winding up overhead.
ChampionModels.AIM = { champ_sniper = 1 }

B.champ_captain = function(l)
	local fur = rgb(150, 132, 118)
	mouseBody(l, { fur = fur, belly = rgb(236, 220, 200), ear = 1.05, snout = 1 })
	Spec.bone("body")
	-- breastplate + belt
	Spec.egg(l, V3(2.1, 1.75, 1.75), CF(0, BODY_Y + 0.2, 0.05), STEEL, M.Metal)
	Spec.egg(l, V3(0.9, 0.7, 0.3), CF(0, BODY_Y + 0.35, -0.8), GOLD, M.Metal)
	Spec.ucyl(l, 0.3, 2.0, CF(0, BODY_Y - 0.65, 0.1), rgb(110, 70, 40), M.Fabric)
	Spec.block(l, V3(0.5, 0.4, 0.15), CF(0, BODY_Y - 0.65, -0.85), GOLD, M.Metal)
	-- pauldrons
	for _, s in { -1, 1 } do
		Spec.bone(if s < 0 then "armL" else "armR")
		Spec.egg(l, V3(0.95, 0.65, 0.95), CF(s * 1.15, SHOULDER_Y + 0.05, 0.05), STEEL, M.Metal)
		Spec.ucyl(l, 0.18, 0.6, CF(s * 1.15, SHOULDER_Y + 0.38, 0.05), GOLD, M.Metal)
	end
	-- round shield on the left arm
	Spec.bone("armL")
	local sh = CF(-1.55, 1.95, -0.25) * ANG(0, rad(75), 0)
	Spec.cyl(l, 0.22, 2.0, sh, rgb(200, 40, 45), M.Metal)
	Spec.cyl(l, 0.26, 1.55, sh * CF(0.03, 0, 0), STEEL, M.Metal)
	Spec.ball(l, 0.55, sh * CF(0.12, 0, 0), GOLD, M.Metal)
	-- sword
	Spec.bone("weapon")
	local hand = CF(1.17, 1.6, -0.15)
	Spec.ucyl(l, 0.55, 0.2, hand * CF(0, 0.05, 0), rgb(90, 60, 40), M.Wood)
	Spec.block(l, V3(0.85, 0.15, 0.2), hand * CF(0, 0.35, 0), GOLD, M.Metal)
	Spec.block(l, V3(0.22, 2.3, 0.08), hand * CF(0, 1.55, 0), rgb(225, 232, 240), M.Metal)
	Spec.wedge(
		l,
		V3(0.08, 0.3, 0.22),
		hand * CF(0, 2.85, 0) * ANG(0, rad(90), 0),
		rgb(225, 232, 240),
		M.Metal
	)
	-- helmet + plume
	Spec.bone("head")
	Spec.egg(l, V3(1.9, 1.0, 1.75), CF(0, 4.25, -0.1), STEEL, M.Metal)
	Spec.block(l, V3(0.18, 0.5, 1.4), CF(0, 4.85, 0.0), rgb(220, 40, 45), M.Fabric)
	Spec.egg(l, V3(0.35, 0.9, 1.6), CF(0, 5.15, 0.25) * ANG(rad(-15), 0, 0), rgb(235, 55, 60), M.Fabric)
	-- moustache (whiskers)
	for _, s in { -1, 1 } do
		Spec.egg(l, V3(0.7, 0.18, 0.18), CF(s * 0.42, 3.45, -1.15) * ANG(0, 0, rad(s * -12)), rgb(80, 60, 50))
	end
	-- cape
	Spec.bone("cape")
	Spec.wedge(
		l,
		V3(2.1, 2.5, 0.25),
		CF(0, SHOULDER_Y - 1.1, 0.95) * ANG(rad(8), 0, 0),
		rgb(200, 35, 45),
		M.Fabric
	)
	Spec.block(
		l,
		V3(2.1, 2.3, 0.12),
		CF(0, SHOULDER_Y - 1.05, 0.98) * ANG(rad(6), 0, 0),
		rgb(170, 25, 35),
		M.Fabric
	)
	return rgb(255, 80, 70), 5.6
end

B.champ_golem = function(l)
	local cheese = rgb(255, 204, 70)
	local rind = rgb(236, 160, 40)
	local hole = rgb(206, 140, 30)
	-- block legs
	for _, s in { -1, 1 } do
		Spec.bone(if s < 0 then "legFL" else "legFR")
		Spec.block(l, V3(0.95, 1.3, 1.0), CF(s * 0.7, 0.68, 0.1), cheese, M.SmoothPlastic, { tint = true })
		Spec.block(l, V3(1.1, 0.3, 1.3), CF(s * 0.7, 0.15, -0.05), rind, M.SmoothPlastic, { tint = true })
	end
	-- the big holey cheese block
	Spec.bone("body")
	local torso = CF(0, 2.45, 0.1)
	Spec.block(l, V3(3.0, 2.6, 2.2), torso, cheese, M.SmoothPlastic, { tint = true })
	Spec.block(l, V3(3.06, 0.35, 2.26), torso * CF(0, 1.2, 0), rind, M.SmoothPlastic, { tint = true })
	Spec.wedge(l, V3(3.0, 0.9, 1.0), torso * CF(0, 1.75, 0.55), cheese, M.SmoothPlastic, { tint = true })
	local holes = {
		{ 0.75, 0.4, -1.1, 0.7 },
		{ -0.7, -0.5, -1.1, 0.55 },
		{ -0.1, 0.8, -1.1, 0.4 },
		{ 0.5, -0.75, -1.1, 0.42 },
		{ 1.5, 0.3, 0.3, 0.6 },
		{ -1.5, -0.2, -0.2, 0.55 },
		{ -1.5, 0.7, 0.5, 0.35 },
		{ 0.2, 0.3, 1.1, 0.6 },
	}
	for _, h in holes do
		Spec.ball(l, h[4], torso * CF(h[1], h[2], h[3]), hole, M.SmoothPlastic)
	end
	-- glowing core visible through a hole
	Spec.ball(l, 0.4, torso * CF(0.75, 0.4, -1.0), rgb(255, 120, 40), M.Neon, { anim = Spec.pulse(0.4, 3) })
	-- block arms + fists
	for _, s in { -1, 1 } do
		Spec.bone(if s < 0 then "armL" else "armR")
		Spec.block(l, V3(0.85, 1.5, 0.85), CF(s * 1.85, 2.6, 0.05), cheese, M.SmoothPlastic, { tint = true })
		Spec.block(l, V3(1.15, 1.0, 1.15), CF(s * 1.9, 1.5, -0.05), rind, M.SmoothPlastic, { tint = true })
		Spec.ball(l, 0.35, CF(s * 2.3, 1.6, -0.3), hole)
	end
	-- wedge head with angry eyes
	Spec.bone("head")
	local head = CF(0, 4.25, -0.1)
	Spec.wedge(l, V3(1.7, 1.2, 1.6), head * ANG(0, rad(180), 0), cheese, M.SmoothPlastic, { tint = true })
	for _, s in { -1, 1 } do
		Spec.ball(l, 0.36, head * CF(s * 0.38, -0.05, -0.55), rgb(255, 90, 30), M.Neon)
		Spec.block(
			l,
			V3(0.5, 0.12, 0.12),
			head * CF(s * 0.38, 0.22, -0.62) * ANG(0, 0, rad(s * -20)),
			rgb(120, 70, 20)
		)
	end
	Spec.bone("jaw")
	Spec.block(l, V3(0.9, 0.18, 0.15), CF(0, 3.85, -0.92), rgb(120, 70, 20))
	-- crumbs floating round it
	Spec.bone("extra")
	for i = 0, 3 do
		local a = i / 4 * math.pi * 2
		Spec.block(
			l,
			V3(0.35, 0.3, 0.3),
			CF(math.cos(a) * 2.3, 0.8 + (i % 2) * 0.5, math.sin(a) * 2.3) * ANG(a, a, 0),
			cheese
		)
	end
	return rgb(255, 180, 40), 5.0
end

B.champ_ratking = function(l)
	local fur = rgb(120, 110, 112)
	mouseBody(l, { fur = fur, belly = rgb(210, 196, 190), ear = 0.85, snout = 1.45 }, { torso = true })
	local robe = rgb(110, 40, 150)
	Spec.bone("body")
	-- robe: a flared gown + ermine collar
	Spec.egg(l, V3(2.3, 2.4, 2.0), CF(0, BODY_Y, 0.1), robe, M.Fabric, { tint = true })
	Spec.egg(l, V3(3.0, 1.9, 2.8), CF(0, 0.95, 0.15), robe:Lerp(EYE, 0.15), M.Fabric, { tint = true })
	Spec.ucyl(l, 0.22, 2.75, CF(0, 0.35, 0.15), GOLD, M.Fabric)
	Spec.egg(l, V3(2.3, 0.7, 1.9), CF(0, SHOULDER_Y + 0.15, 0.05), rgb(250, 248, 240), M.Fabric)
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2
		Spec.ball(l, 0.16, CF(math.cos(a) * 1.0, SHOULDER_Y + 0.35, math.sin(a) * 0.85 + 0.05), EYE)
	end
	Spec.block(l, V3(0.5, 1.6, 0.12), CF(0, BODY_Y - 0.2, -0.95), GOLD, M.Fabric)
	-- crown with gems
	Spec.bone("head")
	local top = CF(0, 4.5, -0.15)
	Spec.ucyl(l, 0.5, 1.35, top, GOLD, M.Metal)
	for i = 0, 4 do
		local a = i / 5 * math.pi * 2
		local p = top * CF(math.cos(a) * 0.6, 0.45, math.sin(a) * 0.6)
		Spec.wedge(l, V3(0.25, 0.5, 0.3), p * ANG(0, -a + rad(90), 0), GOLD, M.Metal)
		Spec.ball(
			l,
			0.2,
			top * CF(math.cos(a) * 0.68, 0.05, math.sin(a) * 0.68),
			if i % 2 == 0 then rgb(230, 40, 60) else rgb(60, 140, 255),
			M.Neon
		)
	end
	-- orb sceptre
	Spec.bone("weapon")
	local hand = CF(1.17, 1.6, -0.15)
	Spec.ucyl(l, 3.0, 0.2, hand * CF(0, 0.5, 0), GOLD, M.Metal)
	Spec.ball(l, 0.75, hand * CF(0, 2.15, 0), rgb(170, 90, 255), M.Neon, { anim = Spec.pulse(0.3, 4) })
	Spec.ucyl(l, 0.2, 0.5, hand * CF(0, 1.75, 0), GOLD, M.Metal)
	-- royal train (cape)
	Spec.bone("cape")
	Spec.wedge(
		l,
		V3(2.4, 2.8, 0.3),
		CF(0, SHOULDER_Y - 1.3, 1.05) * ANG(rad(10), 0, 0),
		rgb(180, 30, 60),
		M.Fabric
	)
	return rgb(190, 110, 255), 5.6
end

B.champ_sniper = function(l)
	local fur = rgb(170, 140, 110)
	mouseBody(l, { fur = fur, belly = rgb(240, 225, 200), ear = 0.95, snout = 1.1 })
	local hood = rgb(70, 110, 60)
	Spec.bone("body")
	Spec.egg(
		l,
		V3(2.05, 2.0, 1.75),
		CF(0, BODY_Y + 0.05, 0.1),
		hood:Lerp(EYE, 0.1),
		M.Fabric,
		{ tint = true }
	)
	-- bandolier
	Spec.block(l, V3(0.35, 2.4, 1.8), CF(0, BODY_Y, 0.1) * ANG(0, 0, rad(40)), rgb(110, 75, 45), M.Fabric)
	for i = -2, 2 do
		Spec.ucyl(l, 0.28, 0.14, CF(i * 0.22, BODY_Y + i * 0.2, -0.86) * ANG(0, 0, rad(40)), GOLD, M.Metal)
	end
	-- hood + scarf
	Spec.bone("head")
	Spec.egg(l, V3(2.0, 1.75, 1.85), CF(0, 3.95, 0.05), hood, M.Fabric)
	Spec.wedge(l, V3(1.2, 0.8, 1.0), CF(0, 4.5, 0.85) * ANG(rad(-30), 0, 0), hood, M.Fabric)
	Spec.ucyl(l, 0.45, 1.6, CF(0, 3.12, 0.0), rgb(200, 70, 50), M.Fabric)
	Spec.block(
		l,
		V3(0.4, 1.1, 0.15),
		CF(0.3, 2.6, 0.8) * ANG(rad(15), 0, rad(10)),
		rgb(200, 70, 50),
		M.Fabric
	)
	-- long rifle with a scope
	Spec.bone("weapon")
	local hand = CF(1.17, 1.7, -0.15)
	Spec.block(l, V3(0.35, 0.5, 1.2), hand * CF(0, 0, 0.45), rgb(110, 70, 40), M.Wood)
	Spec.cyl(l, 3.6, 0.22, hand * CF(0, 0.1, -1.6) * ANG(0, rad(90), 0), rgb(70, 72, 80), M.Metal)
	Spec.cyl(l, 1.1, 0.34, hand * CF(0, 0.5, -0.6) * ANG(0, rad(90), 0), rgb(40, 42, 50), M.Metal)
	Spec.ball(l, 0.26, hand * CF(0, 0.5, -1.15), rgb(140, 220, 255), M.Neon, { anim = Spec.pulse(0.5, 2.5) })
	Spec.block(l, V3(0.12, 0.35, 0.12), hand * CF(0, -0.25, -0.2), rgb(40, 42, 50), M.Metal)
	-- leaf camouflage on the back
	Spec.bone("cape")
	for i = 0, 3 do
		Spec.egg(
			l,
			V3(0.7, 0.18, 0.5),
			CF((i - 1.5) * 0.45, SHOULDER_Y - 0.4 - (i % 2) * 0.5, 0.95) * ANG(rad(70), rad(i * 25), 0),
			rgb(90, 150, 60),
			M.Grass
		)
	end
	return rgb(140, 220, 255), 5.3
end

B.champ_chemist = function(l)
	local fur = rgb(176, 168, 186)
	mouseBody(l, { fur = fur, belly = rgb(236, 226, 232), ear = 1.0, snout = 1.0 })
	Spec.bone("body")
	-- lab coat
	Spec.egg(l, V3(2.15, 2.15, 1.8), CF(0, BODY_Y + 0.05, 0.1), rgb(250, 252, 255), M.Fabric, { tint = true })
	Spec.block(l, V3(0.12, 1.8, 0.1), CF(0, BODY_Y - 0.1, -0.88), rgb(150, 160, 175))
	for i = 0, 2 do
		Spec.ball(l, 0.14, CF(0.18, BODY_Y + 0.5 - i * 0.45, -0.9), rgb(100, 110, 130))
	end
	-- belt with flasks
	Spec.ucyl(l, 0.25, 2.1, CF(0, BODY_Y - 0.6, 0.1), rgb(90, 60, 40), M.Fabric)
	for i, c in { rgb(120, 255, 120), rgb(255, 90, 200), rgb(255, 230, 80) } do
		local a = rad(-60 + i * 50)
		local p = CF(math.sin(a) * 1.08, BODY_Y - 0.7, -math.cos(a) * 0.9 + 0.1)
		Spec.ball(l, 0.42, p, c, M.Neon, { t = 0.2 })
		Spec.ucyl(l, 0.2, 0.18, p * CF(0, 0.28, 0), rgb(150, 110, 70), M.Wood)
	end
	-- goggles + wild hair
	Spec.bone("head")
	Spec.ucyl(l, 0.22, 1.9, CF(0, 4.15, -0.15) * ANG(rad(-12), 0, 0), rgb(60, 50, 50), M.Fabric)
	for _, s in { -1, 1 } do
		Spec.cyl(l, 0.3, 0.6, CF(s * 0.38, 4.25, -0.98) * ANG(0, rad(90), 0), rgb(150, 110, 60), M.Metal)
		Spec.cyl(
			l,
			0.12,
			0.45,
			CF(s * 0.38, 4.25, -1.1) * ANG(0, rad(90), 0),
			rgb(120, 255, 140),
			M.Neon,
			{ t = 0.3 }
		)
	end
	for i = 0, 4 do
		local a = i / 5 * math.pi - math.pi / 2
		Spec.egg(
			l,
			V3(0.5, 0.75, 0.5),
			CF(math.sin(a) * 0.6, 4.6 + math.cos(a) * 0.1, 0.25 + math.cos(a) * 0.3)
				* ANG(rad(-20), 0, a * 0.6),
			rgb(245, 245, 250)
		)
	end
	-- bubbling flask in the hand
	Spec.bone("weapon")
	local hand = CF(1.17, 1.6, -0.15)
	Spec.ball(l, 0.95, hand * CF(0, 0.55, -0.1), rgb(140, 255, 120), M.Glass, { t = 0.35 })
	Spec.ball(
		l,
		0.7,
		hand * CF(0, 0.5, -0.1),
		rgb(120, 255, 100),
		M.Neon,
		{ t = 0.15, anim = Spec.pulse(0.35, 6) }
	)
	Spec.ucyl(l, 0.5, 0.3, hand * CF(0, 1.15, -0.1), rgb(200, 230, 210), M.Glass, { t = 0.3 })
	-- bubbles orbiting the head
	Spec.bone("extra")
	for i = 0, 3 do
		local a = i / 4 * math.pi * 2
		Spec.ball(
			l,
			0.3 + (i % 2) * 0.12,
			CF(math.cos(a) * 1.5, 2.6 + i * 0.35, math.sin(a) * 1.5),
			rgb(160, 255, 140),
			M.Neon,
			{
				t = 0.35,
			}
		)
	end
	-- coat tails
	Spec.bone("cape")
	Spec.wedge(l, V3(2.0, 1.8, 0.2), CF(0, 1.2, 0.95) * ANG(rad(6), 0, 0), rgb(240, 242, 248), M.Fabric)
	return rgb(120, 255, 120), 5.2
end

B.champ_thunder = function(l)
	local fur = rgb(240, 170, 70)
	local cream = rgb(255, 236, 200)
	mouseBody(
		l,
		{ fur = fur, belly = cream, ear = 0.75, snout = 0.7, noTail = true },
		{ torso = true, head = true }
	)
	-- a round, puffed ball of fur
	Spec.bone("body")
	Spec.ball(l, 3.0, CF(0, 2.45, 0.1), fur, M.SmoothPlastic, { tint = true })
	Spec.egg(l, V3(2.1, 2.2, 1.0), CF(0, 2.3, -0.85), cream, M.SmoothPlastic, { tint = true })
	-- spiky fur tufts all round
	for i = 0, 9 do
		local a = i / 10 * math.pi * 2
		local p = V3(math.cos(a) * 1.45, 2.6 + math.sin(a * 2) * 0.3, math.sin(a) * 1.45 + 0.1)
		Spec.wedge(
			l,
			V3(0.5, 0.8, 0.6),
			CFrame.lookAt(p, p * V3(2, 1, 2)) * ANG(rad(-60), 0, 0),
			fur:Lerp(rgb(255, 230, 120), 0.3),
			M.SmoothPlastic,
			{
				tint = true,
			}
		)
	end
	-- lightning-bolt tail
	for i = 0, 2 do
		Spec.block(
			l,
			V3(0.25, 0.75, 0.3),
			CF((if i % 2 == 0 then 0.2 else -0.2), 1.9 + i * 0.55, 1.75)
				* ANG(0, 0, rad(if i % 2 == 0 then 30 else -30)),
			rgb(255, 235, 60),
			M.Neon
		)
	end
	-- head: blended into the ball, big cheeks with electric spots
	Spec.bone("head")
	local hy, hz = 3.75, -0.35
	Spec.egg(l, V3(2.0, 1.6, 1.6), CF(0, hy, hz), fur, M.SmoothPlastic, { tint = true })
	Spec.egg(l, V3(0.9, 0.6, 0.6), CF(0, hy - 0.35, hz - 0.72), cream, M.SmoothPlastic, { tint = true })
	Spec.ball(l, 0.3, CF(0, hy - 0.18, hz - 1.0), PINK_DARK)
	for _, s in { -1, 1 } do
		local e = CF(s * 0.42, hy + 0.15, hz - 0.7)
		Spec.egg(l, V3(0.38, 0.5, 0.22), e, EYE)
		Spec.ball(l, 0.14, e * CF(-s * 0.05, 0.1, -0.1), WHITE, M.Neon)
		Spec.ball(
			l,
			0.5,
			CF(s * 0.78, hy - 0.3, hz - 0.45),
			rgb(255, 80, 60),
			M.Neon,
			{ anim = Spec.pulse(0.4, 9) }
		)
	end
	for _, s in { -1, 1 } do
		Spec.wedge(
			l,
			V3(0.25, 0.7, 0.4),
			CF(s * 0.45, hy + 0.85, hz + 0.1) * ANG(rad(-20), 0, rad(-s * 25)),
			fur:Lerp(rgb(255, 230, 120), 0.3)
		)
	end
	Spec.bone("jaw")
	Spec.egg(l, V3(0.5, 0.22, 0.3), CF(0, hy - 0.62, hz - 0.62), rgb(120, 40, 50))
	-- electric aura: tilted neon rings + sparks orbiting
	Spec.bone("extra")
	Spec.ball(l, 4.8, CF(0, 2.5, 0.1), rgb(120, 220, 255), M.ForceField, { t = 0.2 })
	for i = 0, 3 do
		local a = i / 4 * math.pi * 2
		Spec.ball(
			l,
			0.3,
			CF(math.cos(a) * 2.2, 0.6 + (i % 2) * 0.8, math.sin(a) * 2.2),
			rgb(255, 250, 140),
			M.Neon,
			{
				anim = Spec.pulse(0.6, 14 + i),
			}
		)
	end
	return rgb(255, 235, 60), 5.0
end

-- Unknown ids: an armoured champion in the def's colour.
local function generic(l: L, color: Color3): (Color3, number)
	mouseBody(
		l,
		{ fur = color:Lerp(rgb(150, 120, 90), 0.5), belly = rgb(236, 220, 200), ear = 1.0, snout = 1 }
	)
	Spec.bone("body")
	Spec.egg(l, V3(2.1, 1.7, 1.75), CF(0, BODY_Y + 0.2, 0.05), color, M.Metal)
	Spec.bone("head")
	Spec.ucyl(l, 0.4, 1.3, CF(0, 4.5, -0.15), GOLD, M.Neon)
	return color, 5.0
end

function ChampionModels.build(
	id: string,
	def: any
): {
	parts: Spec.List,
	bones: Spec.Skeleton,
	style: string,
	radius: number,
	height: number,
	k: number,
	stride: number,
	accent: Color3,
	aim: number,
}
	local r = tonumber(if type(def) == "table" then (def.radius or def.r) else nil) or 2.4
	r = math.clamp(r, 1.2, 6)
	local l: L = {}
	local accent: Color3, h: number
	local fn = B[id]
	if fn then
		accent, h = fn(l)
	else
		local c = rgb(200, 120, 60)
		if type(def) == "table" and type(def.color) == "table" then
			c = rgb(def.color[1] or 200, def.color[2] or 120, def.color[3] or 60)
		end
		accent, h = generic(l, c)
	end
	-- iter2 detail (every champion): a war banner on the back in the champion's
	-- accent with a gold emblem (reads from the top-down camera), and a thin
	-- accent ring at the feet under the contact shadow
	Spec.bone("body")
	local top = math.max(3.2, h * 0.92)
	Spec.ucyl(l, top, 0.14, CF(0.55, top / 2 + 0.6, 1.0), rgb(110, 76, 44), M.Wood)
	Spec.block(l, V3(0.06, 1.0, 1.1), CF(0.55, top + 0.15, 1.6), accent, M.Fabric)
	Spec.wedge(l, V3(0.06, 0.5, 0.6), CF(0.55, top - 0.6, 2.0) * ANG(math.pi, 0, 0), accent, M.Fabric)
	Spec.ball(l, 0.4, CF(0.5, top + 0.2, 1.55), GOLD, M.Metal)
	Spec.bone(nil)
	Spec.egg(l, V3(3.6, 0.05, 3.6), CF(0, 0.03, 0.1), EYE, M.SmoothPlastic, { t = 0.6 })
	Spec.ucyl(l, 0.04, 4.2, CF(0, 0.05, 0.1), accent, M.Neon, { t = 0.55 })
	local k = r / ChampionModels.UNIT_RADIUS
	return {
		parts = Spec.scaled(l, k),
		bones = Spec.scaledBones(skeleton(), k),
		style = "biped",
		radius = r,
		height = h * k,
		k = k,
		stride = ChampionModels.STRIDE,
		accent = accent,
		aim = ChampionModels.AIM[id] or 0,
	}
end

ChampionModels.IDS = B

return ChampionModels
