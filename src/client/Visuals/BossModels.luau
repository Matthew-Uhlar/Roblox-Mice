--!strict
-- BossModels (R4 Graphics, client): part specs for the 13 bosses (GDD-v2 §6).
--
--   BossModels.build(bossId, def) -> { parts, radius, height }
--   Each boss is 30-120 parts, designed at unit footprint radius and scaled to the
--   boss hitbox (def.radius), facing -Z. Every boss keeps its one exaggerated,
--   instantly readable feature (STYLE.md): the Giant Tree's face and canopy,
--   Froggus's belly and eyes, the Serpent Sisters' hooded coils, Grandma's
--   slipper and glasses, the Witch's hat and spell wheel, the Corndog Bunny's
--   stick, the Spider Machine's eight legs and laser eye, the Gorilla's fists,
--   the origami Dinosaur's folds, the Hematite Snake's iron segments, the Ice
--   Dragon's wings, the Void Cat's galaxy eyes and Zoomzola's speeding wheel.
--   Idle animation channels (Spec anim): breathing bobs, swaying heads, flapping
--   wings, spinning wheels, walking legs.

local Spec = require(script.Parent.Spec)

local BossModels = {}

local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local rad = math.rad
local M = Enum.Material
local rgb = Color3.fromRGB

local WHITE = rgb(255, 255, 255)
local BLACK = rgb(24, 20, 24)
local CHEESE = rgb(255, 201, 60)

type L = Spec.List
type Builder = (l: L, c: Color3) -> number -- returns model height (units)

local function eyes(l: L, at: CFrame, gap: number, d: number, iris: Color3?, x: { [string]: any }?)
	for _, s in { -1, 1 } do
		local e = at * CF(s * gap, 0, 0)
		Spec.ball(l, d, e, WHITE, M.SmoothPlastic, x)
		Spec.ball(l, d * 0.55, e * CF(0, 0, -d * 0.3), iris or BLACK, if iris then M.Neon else M.SmoothPlastic, x)
		Spec.ball(l, d * 0.18, e * CF(-s * d * 0.08, d * 0.15, -d * 0.47), WHITE, M.Neon, x)
	end
end

local B: { [string]: Builder } = {}

B.giant_tree = function(l, c)
	local bark = c
	local breathe = Spec.bob(0.04, 1.6)
	Spec.ucyl(l, 2.4, 1.3, CF(0, 1.2, 0), bark, M.Wood, { tint = true, anim = breathe })
	Spec.ucyl(l, 0.8, 1.7, CF(0, 0.4, 0), bark:Lerp(BLACK, 0.15), M.Wood, { tint = true })
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2
		local dir = V3(math.cos(a), 0, math.sin(a))
		local p = dir * 0.9 + V3(0, 0.25, 0)
		Spec.wedge(l, V3(0.35, 0.6, 0.8), CFrame.lookAt(p, p + dir), bark:Lerp(BLACK, 0.2), M.Wood, { tint = true })
	end
	-- face
	eyes(l, CF(0, 1.75, -0.62), 0.28, 0.34, rgb(255, 200, 60), { anim = breathe })
	Spec.block(l, V3(0.7, 0.12, 0.1), CF(0, 2.05, -0.62) * ANG(0, 0, rad(-8)), BLACK, M.Wood, { anim = breathe })
	Spec.egg(l, V3(0.6, 0.3, 0.2), CF(0, 1.3, -0.62), rgb(60, 30, 20), M.SmoothPlastic, { anim = breathe })
	-- branches (arms) that sway
	for _, s in { -1, 1 } do
		local sh = CF(s * 0.6, 1.9, 0)
		local arm = Spec.roll(0.15, 1.3, s, sh)
		Spec.cyl(l, 1.3, 0.3, sh * ANG(0, 0, rad(s * 30)) * CF(s * 0.6, 0, 0), bark, M.Wood, { tint = true, anim = arm })
		Spec.egg(l, V3(0.8, 0.6, 0.8), sh * ANG(0, 0, rad(s * 30)) * CF(s * 1.3, 0.1, 0), rgb(80, 150, 60), M.Grass, { anim = arm })
	end
	-- canopy: layered blobs + acorns
	local greens = { rgb(64, 132, 52), rgb(84, 158, 62), rgb(110, 180, 72) }
	for tier = 0, 2 do
		local n = 6 - tier
		for i = 1, n do
			local a = i / n * math.pi * 2 + tier
			local rr = 1.0 - tier * 0.32
			Spec.egg(l, V3(1.1, 0.85, 1.1) * (1.2 - tier * 0.2), CF(math.cos(a) * rr, 2.7 + tier * 0.45, math.sin(a) * rr), greens[tier + 1], M.Grass, {
				anim = Spec.bob(0.05, 1.2, i),
			})
		end
	end
	for i = 1, 6 do
		local a = i / 6 * math.pi * 2 + 0.4
		Spec.egg(l, V3(0.22, 0.28, 0.22), CF(math.cos(a) * 1.1, 2.45, math.sin(a) * 1.1), rgb(150, 100, 50), M.Wood)
		Spec.ucyl(l, 0.08, 0.24, CF(math.cos(a) * 1.1, 2.6, math.sin(a) * 1.1), rgb(100, 70, 40), M.Wood)
	end
	return 4
end

B.froggus = function(l, c)
	local breathe = Spec.bob(0.05, 2.2)
	Spec.egg(l, V3(2, 1.5, 1.9), CF(0, 0.85, 0), c, M.SmoothPlastic, { tint = true, anim = breathe })
	Spec.egg(l, V3(1.5, 1.1, 1.2), CF(0, 0.7, -0.4), rgb(240, 230, 170), M.SmoothPlastic, { tint = true, anim = breathe })
	Spec.egg(l, V3(1.7, 0.8, 1.2), CF(0, 1.55, -0.45), c, M.SmoothPlastic, { tint = true, anim = breathe })
	-- eye domes on top
	for _, s in { -1, 1 } do
		Spec.ball(l, 0.62, CF(s * 0.52, 2.0, -0.6), c, M.SmoothPlastic, { tint = true, anim = breathe })
	end
	eyes(l, CF(0, 2.05, -0.82), 0.52, 0.42, nil, { anim = breathe })
	-- wide mouth + tongue
	Spec.block(l, V3(1.4, 0.07, 0.1), CF(0, 1.35, -1.0) * ANG(0, 0, 0), rgb(80, 30, 40), M.SmoothPlastic, { anim = breathe })
	Spec.egg(l, V3(0.35, 0.12, 0.5), CF(0, 1.25, -1.05), rgb(240, 110, 130), M.SmoothPlastic, { anim = breathe })
	-- spots
	for i = 1, 6 do
		local a = i * 1.1
		Spec.egg(l, V3(0.3, 0.12, 0.3), CF(math.cos(a) * 0.8, 1.3 + (i % 2) * 0.2, 0.3 + math.sin(a) * 0.5) * ANG(math.sin(a) * 0.6, 0, -math.cos(a) * 0.6), c:Lerp(BLACK, 0.3), M.SmoothPlastic, {
			tint = true,
		})
	end
	-- legs: big back thighs, front arms, webbed feet
	for _, s in { -1, 1 } do
		Spec.egg(l, V3(0.7, 0.8, 1.2), CF(s * 0.95, 0.45, 0.5), c, M.SmoothPlastic, { tint = true })
		Spec.egg(l, V3(0.6, 0.15, 0.8), CF(s * 1.1, 0.07, 0.2), c:Lerp(rgb(255, 240, 150), 0.3), M.SmoothPlastic)
		Spec.ucyl(l, 0.7, 0.3, CF(s * 0.6, 0.35, -0.75), c, M.SmoothPlastic, { tint = true, anim = Spec.swing(0.2, 2, s, CF(s * 0.6, 0.7, -0.75)) })
		Spec.egg(l, V3(0.5, 0.12, 0.5), CF(s * 0.65, 0.06, -0.9), c:Lerp(rgb(255, 240, 150), 0.3), M.SmoothPlastic)
	end
	-- lily pad + crown
	Spec.ucyl(l, 0.06, 2.8, CF(0, 0.03, 0), rgb(70, 150, 70), M.Grass)
	Spec.ucyl(l, 0.3, 0.6, CF(0, 2.4, -0.3), CHEESE, M.Neon)
	return 2.7
end

B.serpent_sisters = function(l, c)
	-- stacked coils
	for i = 0, 11 do
		local a = i / 12 * math.pi * 4
		local rr = 0.85 - i * 0.04
		Spec.ball(l, 0.75 - i * 0.02, CF(math.cos(a) * rr, 0.35 + i * 0.12, math.sin(a) * rr), if i % 2 == 0 then c else c:Lerp(WHITE, 0.15), M.SmoothPlastic, {
			tint = true,
			anim = Spec.bob(0.04, 2, i * 0.3),
		})
	end
	-- rising neck and hooded head that sways
	local neck = CF(0, 1.6, -0.2)
	local sway = Spec.sway(0.35, 1.4, 0, neck)
	for k = 1, 4 do
		Spec.ball(l, 0.55 - k * 0.03, neck * CF(0, k * 0.3, -k * 0.08), c, M.SmoothPlastic, { tint = true, anim = sway })
	end
	local head = neck * CF(0, 1.5, -0.4)
	Spec.egg(l, V3(1.6, 1.3, 0.25), head * CF(0, 0, 0.25), c:Lerp(BLACK, 0.2), M.SmoothPlastic, { tint = true, anim = sway })
	Spec.egg(l, V3(1.1, 0.9, 0.18), head * CF(0, 0, 0.18), rgb(230, 200, 120), M.SmoothPlastic, { anim = sway })
	Spec.egg(l, V3(0.7, 0.5, 0.9), head * CF(0, 0, -0.25), c, M.SmoothPlastic, { tint = true, anim = sway })
	eyes(l, head * CF(0, 0.15, -0.55), 0.22, 0.22, rgb(255, 220, 60), { anim = sway })
	for _, s in { -1, 1 } do
		Spec.wedge(l, V3(0.06, 0.25, 0.08), head * CF(s * 0.12, -0.25, -0.62) * ANG(math.pi, 0, 0), WHITE, M.SmoothPlastic, { anim = sway })
	end
	Spec.block(l, V3(0.05, 0.04, 0.4), head * CF(0, -0.2, -0.85), rgb(230, 60, 80), M.SmoothPlastic, { anim = sway })
	-- tail rattle
	Spec.ucyl(l, 0.4, 0.25, CF(0.9, 0.3, 0.6), rgb(230, 200, 120), M.SmoothPlastic, { anim = Spec.roll(0.3, 12, 0, CF(0.9, 0.1, 0.6)) })
	-- three sister charms on the coils
	for i = 0, 2 do
		local a = i / 3 * math.pi * 2
		Spec.ball(l, 0.22, CF(math.cos(a) * 0.95, 0.9, math.sin(a) * 0.95), rgb(120, 255, 200), M.Neon)
	end
	return 3.4
end

B.my_grandma = function(l, c)
	local breathe = Spec.bob(0.03, 1.8)
	local dress = c
	-- skirt, cardigan, apron
	Spec.ucyl(l, 1.2, 1.9, CF(0, 0.6, 0), dress, M.Fabric, { tint = true })
	Spec.egg(l, V3(1.8, 0.5, 1.8), CF(0, 1.2, 0), dress, M.Fabric, { tint = true })
	Spec.egg(l, V3(1.5, 1.3, 1.2), CF(0, 1.75, 0), rgb(150, 110, 170), M.Fabric, { tint = true, anim = breathe })
	Spec.block(l, V3(0.9, 1.1, 0.06), CF(0, 1.1, -0.92), WHITE, M.Fabric)
	for k = 0, 3 do
		Spec.ball(l, 0.09, CF(0, 1.5 + k * 0.17, -0.62), rgb(240, 220, 120), M.Metal, { anim = breathe })
	end
	-- head, bun, glasses, smile
	local h = CF(0, 2.75, -0.1)
	Spec.ball(l, 0.95, h, rgb(250, 215, 190), M.SmoothPlastic, { tint = true, anim = breathe })
	Spec.ball(l, 0.95, h * CF(0, 0.22, 0.12), rgb(230, 230, 235), M.SmoothPlastic, { anim = breathe })
	Spec.ball(l, 0.5, h * CF(0, 0.62, 0.25), rgb(230, 230, 235), M.SmoothPlastic, { anim = breathe })
	Spec.ucyl(l, 0.1, 0.22, h * CF(0.12, 0.72, 0.3), rgb(255, 120, 150), M.SmoothPlastic, { anim = breathe })
	for _, s in { -1, 1 } do
		Spec.cyl(l, 0.06, 0.32, h * CF(s * 0.2, 0.05, -0.47) * ANG(0, rad(90), 0), rgb(220, 240, 255), M.Glass, { anim = breathe, t = 0.2 })
		Spec.cyl(l, 0.07, 0.36, h * CF(s * 0.2, 0.05, -0.46) * ANG(0, rad(90), 0), rgb(200, 160, 60), M.Metal, { anim = breathe, t = 0.5 })
		Spec.ball(l, 0.09, h * CF(s * 0.2, 0.05, -0.5), BLACK, M.SmoothPlastic, { anim = breathe })
		Spec.egg(l, V3(0.18, 0.1, 0.05), h * CF(s * 0.28, -0.15, -0.44), rgb(255, 160, 170), M.SmoothPlastic, { anim = breathe })
	end
	Spec.block(l, V3(0.12, 0.03, 0.05), h * CF(0, 0.05, -0.5), rgb(200, 160, 60), M.Metal, { anim = breathe })
	Spec.block(l, V3(0.3, 0.05, 0.05), h * CF(0, -0.25, -0.46), rgb(180, 80, 90), M.SmoothPlastic, { anim = breathe })
	-- arms: the slipper raised high in the right hand, yarn ball in the left
	local shR = CF(0.75, 2.05, 0)
	local wave = Spec.roll(0.25, 2.4, 0, shR)
	Spec.cyl(l, 0.9, 0.32, shR * ANG(0, 0, rad(60)) * CF(0.45, 0, 0), rgb(150, 110, 170), M.Fabric, { tint = true, anim = wave })
	local hand = shR * ANG(0, 0, rad(60)) * CF(0.95, 0, 0)
	Spec.ball(l, 0.28, hand, rgb(250, 215, 190), M.SmoothPlastic, { anim = wave })
	local slip = hand * CF(0.15, 0.35, 0) * ANG(0, 0, rad(-20))
	Spec.egg(l, V3(0.5, 1.2, 0.25), slip, rgb(240, 110, 150), M.Fabric, { anim = wave })
	Spec.egg(l, V3(0.42, 0.5, 0.3), slip * CF(0, 0.35, 0.05), rgb(255, 255, 255), M.Fabric, { anim = wave })
	Spec.egg(l, V3(0.45, 1.1, 0.06), slip * CF(0, 0, 0.14), rgb(120, 70, 60), M.Rubber, { anim = wave })
	local shL = CF(-0.75, 2.0, 0)
	Spec.cyl(l, 0.8, 0.3, shL * ANG(0, 0, rad(-120)) * CF(0.4, 0, 0), rgb(150, 110, 170), M.Fabric, { tint = true })
	Spec.ball(l, 0.55, CF(-1.1, 1.35, -0.3), rgb(230, 80, 90), M.Fabric)
	Spec.cyl(l, 0.7, 0.04, CF(-1.1, 1.35, -0.3) * ANG(0, 0, rad(30)), rgb(255, 230, 230), M.Fabric)
	Spec.ucyl(l, 0.06, 0.8, CF(0, 0.03, 0), rgb(200, 60, 60), M.Fabric) -- rug
	return 3.4
end

B.floating_witch = function(l, c)
	local float = Spec.bob(0.18, 1.5)
	-- robe (floating), arms, head, hat
	for i = 0, 6 do
		local a = i / 7 * math.pi * 2
		local dir = V3(math.cos(a), 0, math.sin(a))
		local p = V3(0, 1.4, 0) + dir * 0.45
		Spec.wedge(l, V3(0.85, 1.9, 0.9), CFrame.lookAt(p, p + dir), if i % 2 == 0 then c else c:Lerp(BLACK, 0.15), M.Fabric, {
			tint = true,
			anim = float,
		})
	end
	Spec.egg(l, V3(1.3, 1.0, 1.1), CF(0, 2.2, 0), c:Lerp(BLACK, 0.2), M.Fabric, { tint = true, anim = float })
	Spec.ball(l, 0.85, CF(0, 2.85, 0), rgb(150, 210, 130), M.SmoothPlastic, { tint = true, anim = float })
	Spec.egg(l, V3(0.18, 0.18, 0.4), CF(0, 2.78, -0.48) * ANG(rad(30), 0, 0), rgb(120, 190, 110), M.SmoothPlastic, { anim = float })
	eyes(l, CF(0, 2.95, -0.36), 0.18, 0.2, rgb(255, 230, 80), { anim = float })
	Spec.ucyl(l, 0.08, 1.9, CF(0, 3.2, 0), rgb(40, 30, 50), M.Fabric, { anim = float })
	for k = 0, 3 do
		Spec.ucyl(l, 0.35, 1.0 - k * 0.23, CF(0, 3.4 + k * 0.32, 0.06 * k) * ANG(rad(-6 * k), 0, 0), rgb(50, 36, 64), M.Fabric, { anim = float })
	end
	Spec.ball(l, 0.18, CF(0, 4.55, 0.35), CHEESE, M.Neon, { anim = float })
	Spec.ucyl(l, 0.1, 1.02, CF(0, 3.42, 0), rgb(255, 200, 60), M.Fabric, { anim = float })
	for _, s in { -1, 1 } do
		Spec.cyl(l, 0.8, 0.25, CF(s * 0.75, 2.1, -0.2) * ANG(0, rad(s * 30), rad(s * -30)), c, M.Fabric, { tint = true, anim = float })
		Spec.ball(l, 0.2, CF(s * 1.1, 1.85, -0.45), rgb(150, 210, 130), M.SmoothPlastic, { anim = float })
	end
	-- broom under her
	Spec.cyl(l, 2.6, 0.14, CF(0, 0.85, 0) * ANG(0, rad(90), 0), rgb(130, 90, 50), M.Wood, { anim = float })
	Spec.egg(l, V3(0.6, 0.6, 0.8), CF(0, 0.85, 1.4), rgb(220, 180, 90), M.Fabric, { anim = float })
	-- the spell wheel behind her: 8 coloured wedges on a rim, spinning
	local hub = CF(0, 2.6, 1.1) * ANG(rad(90), 0, 0)
	local cols = { rgb(255, 80, 80), rgb(255, 200, 60), rgb(90, 200, 255), rgb(140, 230, 110) }
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		Spec.wedge(l, V3(0.06, 0.6, 1.0), hub * ANG(0, a, 0) * CF(0, 0, -0.5) * ANG(rad(90), 0, 0), cols[(i % 4) + 1], M.Neon, {
			anim = Spec.spin(1.6, hub),
		})
		Spec.ball(l, 0.12, hub * ANG(0, a, 0) * CF(0, 0, -1.08), WHITE, M.Neon, { anim = Spec.spin(1.6, hub) })
	end
	Spec.cyl(l, 0.12, 0.3, hub * ANG(0, 0, rad(90)), rgb(255, 210, 80), M.Metal)
	return 4.6
end

B.corndog_bunny = function(l, _c)
	local hop = Spec.bob(0.1, 4)
	local fur = rgb(245, 235, 220)
	Spec.egg(l, V3(1.6, 1.7, 1.5), CF(0, 1.1, 0.1), fur, M.Fabric, { tint = true, anim = hop })
	Spec.egg(l, V3(1.1, 1.1, 0.8), CF(0, 1.0, -0.35), rgb(255, 250, 240), M.Fabric, { anim = hop })
	Spec.ball(l, 1.25, CF(0, 2.2, -0.15), fur, M.Fabric, { tint = true, anim = hop })
	eyes(l, CF(0, 2.35, -0.68), 0.25, 0.3, rgb(220, 40, 40), { anim = hop })
	Spec.ball(l, 0.18, CF(0, 2.1, -0.78), rgb(255, 130, 150), M.SmoothPlastic, { anim = hop })
	for _, s in { -1, 1 } do
		Spec.egg(l, V3(0.18, 0.06, 0.02), CF(s * 0.1, 1.95, -0.78), WHITE, M.SmoothPlastic, { anim = hop })
		-- tall ears that flop
		local base = CF(s * 0.3, 2.75, -0.05)
		local flop = Spec.roll(0.2, 3, s, base)
		Spec.egg(l, V3(0.35, 1.5, 0.22), base * ANG(0, 0, rad(-s * 10)) * CF(0, 0.7, 0), fur, M.Fabric, { tint = true, anim = flop })
		Spec.egg(l, V3(0.2, 1.1, 0.1), base * ANG(0, 0, rad(-s * 10)) * CF(0, 0.7, -0.08), rgb(255, 170, 185), M.Fabric, { anim = flop })
		Spec.egg(l, V3(0.6, 0.35, 1.0), CF(s * 0.55, 0.17, -0.15), fur, M.Fabric, { tint = true })
	end
	Spec.ball(l, 0.55, CF(0, 0.9, 0.9), WHITE, M.Fabric, { anim = hop })
	-- THE STICK: a giant corndog held like a club
	local arm = CF(0.8, 1.4, -0.3)
	local swing = Spec.swing(0.35, 2.5, 0, arm)
	Spec.egg(l, V3(0.35, 0.8, 0.35), arm * CF(0.1, -0.1, -0.2) * ANG(rad(-40), 0, 0), fur, M.Fabric, { tint = true, anim = swing })
	local stick = arm * CF(0.15, 0.2, -0.55) * ANG(rad(-20), 0, rad(-15))
	Spec.ucyl(l, 2.6, 0.12, stick * CF(0, 0.6, 0), rgb(210, 180, 130), M.Wood, { anim = swing })
	Spec.egg(l, V3(0.55, 1.5, 0.55), stick * CF(0, 1.6, 0), rgb(214, 150, 70), M.SmoothPlastic, { anim = swing, tint = true })
	for k = 0, 2 do
		Spec.block(l, V3(0.06, 0.06, 0.5), stick * CF(0, 1.2 + k * 0.35, -0.27) * ANG(0, 0, rad(30)), rgb(250, 210, 40), M.SmoothPlastic, { anim = swing })
	end
	Spec.block(l, V3(0.06, 0.06, 0.5), stick * CF(0, 1.4, -0.27) * ANG(0, 0, rad(-30)), rgb(220, 50, 40), M.SmoothPlastic, { anim = swing })
	return 3.8
end

B.spider_machine = function(l, c)
	local hum = Spec.bob(0.06, 3)
	local steel = c
	Spec.egg(l, V3(1.9, 0.9, 2.1), CF(0, 1.6, 0.1), steel, M.Metal, { tint = true, anim = hum })
	Spec.egg(l, V3(1.3, 0.6, 1.4), CF(0, 2.05, 0.2), steel:Lerp(WHITE, 0.2), M.DiamondPlate, { tint = true, anim = hum })
	Spec.egg(l, V3(1.2, 0.8, 0.9), CF(0, 1.55, -0.9), steel:Lerp(BLACK, 0.25), M.Metal, { tint = true, anim = hum })
	-- cockpit dome with a mouse pilot
	Spec.ball(l, 0.8, CF(0, 2.25, 0.4), rgb(150, 220, 255), M.Glass, { t = 0.35, anim = hum })
	Spec.ball(l, 0.35, CF(0, 2.2, 0.4), rgb(139, 107, 78), M.SmoothPlastic, { anim = hum })
	-- laser eye cluster
	Spec.ball(l, 0.42, CF(0, 1.6, -1.32), rgb(255, 50, 40), M.Neon, { anim = Spec.pulse(0.3, 6) })
	for _, s in { -1, 1 } do
		Spec.ball(l, 0.2, CF(s * 0.35, 1.75, -1.25), rgb(255, 120, 60), M.Neon, { anim = hum })
		Spec.cyl(l, 0.6, 0.15, CF(s * 0.25, 1.3, -1.35) * ANG(0, rad(90), 0), rgb(60, 60, 66), M.Metal, { anim = hum })
	end
	-- antenna
	Spec.ucyl(l, 0.7, 0.05, CF(0.4, 2.55, 0.8), rgb(60, 60, 66), M.Metal, { anim = hum })
	Spec.ball(l, 0.12, CF(0.4, 2.92, 0.8), rgb(255, 60, 60), M.Neon, { anim = Spec.pulse(0.5, 8) })
	-- 8 legs: upper + lower segments, joints, feet; alternating gait
	for i = 0, 3 do
		for _, s in { -1, 1 } do
			local z = -0.7 + i * 0.5
			local hip = CF(s * 0.8, 1.6, z)
			local phase = (i + (if s > 0 then 0 else 1)) % 2 * math.pi
			local gait = Spec.sway(0.22, 4, phase, hip)
			local out = ANG(0, rad(s * (i - 1.5) * -18), 0)
			local upper = hip * out * ANG(0, 0, rad(s * 35))
			Spec.cyl(l, 1.0, 0.16, upper * CF(s * 0.5, 0, 0), steel, M.Metal, { tint = true, anim = gait })
			local knee = hip * out * CF(s * 0.82, 0.57, 0)
			Spec.ball(l, 0.24, knee, rgb(255, 200, 60), M.Metal, { anim = gait })
			local lower = knee * ANG(0, 0, rad(-s * 70))
			Spec.cyl(l, 2.2, 0.13, lower * CF(s * 1.1, 0, 0), steel:Lerp(BLACK, 0.2), M.Metal, { tint = true, anim = gait })
			Spec.ball(l, 0.2, lower * CF(s * 2.2, 0, 0), rgb(60, 60, 66), M.Metal, { anim = gait })
		end
	end
	return 3
end

B.green_gorilla = function(l, c)
	local breathe = Spec.bob(0.05, 1.7)
	local fur = c
	local skin = rgb(70, 90, 70)
	Spec.egg(l, V3(2.1, 1.9, 1.5), CF(0, 2, 0.1), fur, M.Fabric, { tint = true, anim = breathe })
	Spec.egg(l, V3(1.3, 1.2, 0.5), CF(0, 2, -0.55), skin, M.SmoothPlastic, { tint = true, anim = breathe })
	Spec.egg(l, V3(1.5, 1, 1.1), CF(0, 1.05, 0.2), fur, M.Fabric, { tint = true })
	-- head with brow and muzzle
	local h = CF(0, 3.2, -0.25)
	Spec.ball(l, 1.0, h, fur, M.Fabric, { tint = true, anim = breathe })
	Spec.egg(l, V3(0.8, 0.6, 0.5), h * CF(0, -0.15, -0.35), skin, M.SmoothPlastic, { anim = breathe })
	Spec.egg(l, V3(0.9, 0.2, 0.3), h * CF(0, 0.2, -0.42), fur:Lerp(BLACK, 0.3), M.Fabric, { anim = breathe })
	eyes(l, h * CF(0, 0.07, -0.47), 0.17, 0.16, rgb(255, 210, 60), { anim = breathe })
	for _, s in { -1, 1 } do
		Spec.ball(l, 0.08, h * CF(s * 0.1, -0.12, -0.6), BLACK, M.SmoothPlastic, { anim = breathe })
	end
	-- banana crown
	for i = 0, 4 do
		local a = i / 5 * math.pi * 2
		Spec.egg(l, V3(0.15, 0.45, 0.15), h * CF(math.cos(a) * 0.3, 0.55, math.sin(a) * 0.3) * ANG(math.sin(a) * 0.4, 0, -math.cos(a) * 0.4), rgb(255, 225, 70), M.SmoothPlastic, {
			anim = breathe,
		})
	end
	-- huge arms and fists (chest pound)
	for _, s in { -1, 1 } do
		local sh = CF(s * 1.15, 2.6, 0)
		local pound = Spec.swing(0.25, 2.2, if s > 0 then 0 else math.pi, sh)
		Spec.egg(l, V3(0.75, 1.4, 0.75), sh * CF(s * 0.15, -0.55, 0), fur, M.Fabric, { tint = true, anim = pound })
		Spec.egg(l, V3(0.6, 1.2, 0.6), sh * CF(s * 0.3, -1.5, -0.1), fur, M.Fabric, { tint = true, anim = pound })
		Spec.ball(l, 0.8, sh * CF(s * 0.35, -2.25, -0.15), skin, M.SmoothPlastic, { anim = pound })
		Spec.egg(l, V3(0.5, 0.9, 0.55), CF(s * 0.55, 0.45, 0.25), fur, M.Fabric, { tint = true })
		Spec.egg(l, V3(0.6, 0.25, 0.8), CF(s * 0.6, 0.1, 0.05), skin, M.SmoothPlastic)
	end
	-- banana bandolier
	Spec.block(l, V3(0.25, 2.2, 0.1), CF(0, 2, -0.62) * ANG(0, 0, rad(35)), rgb(120, 80, 40), M.Leather, { anim = breathe })
	for k = -2, 2 do
		Spec.egg(l, V3(0.14, 0.35, 0.12), CF(k * 0.22, 2 + k * 0.32, -0.68) * ANG(0, 0, rad(35)), rgb(255, 225, 70), M.SmoothPlastic, {
			anim = breathe,
		})
	end
	return 4
end

B.paper_dinosaur = function(l, c)
	local paper = c
	local fold = c:Lerp(rgb(180, 175, 165), 0.5)
	local stomp = Spec.bob(0.06, 2.6)
	-- faceted origami body: wedges in pairs
	for _, s in { -1, 1 } do
		Spec.wedge(l, V3(0.75, 1.4, 1.6), CF(s * 0.38, 1.6, 0.2) * ANG(0, math.pi, 0), if s > 0 then paper else fold, M.SmoothPlastic, {
			tint = true,
			anim = stomp,
		})
		Spec.wedge(l, V3(0.75, 1.0, 1.4), CF(s * 0.38, 1.6, 1.4), if s > 0 then fold else paper, M.SmoothPlastic, { tint = true, anim = stomp })
		Spec.corner(l, V3(0.7, 0.8, 0.9), CF(s * 0.35, 2.6, -0.2) * ANG(0, if s > 0 then 0 else math.pi / 2, 0), paper, M.SmoothPlastic, {
			tint = true,
			anim = stomp,
		})
	end
	-- tail: tapering folded wedges
	for k = 1, 4 do
		Spec.wedge(l, V3(0.9 - k * 0.18, 0.7 - k * 0.12, 0.8), CF(0, 1.5 - k * 0.12, 1.6 + k * 0.7) * ANG(rad(-8), 0, 0), if k % 2 == 0 then paper else fold, M.SmoothPlastic, {
			tint = true,
			anim = Spec.sway(0.2, 1.8, k * 0.4, CF(0, 1.5, 1.6)),
		})
	end
	-- neck + head: a boxy origami rex skull with a jaw
	local neck = CF(0, 2.6, -0.6)
	local look = Spec.sway(0.25, 1.1, 0, neck)
	Spec.block(l, V3(0.7, 0.8, 0.7), neck * CF(0, 0.3, -0.3) * ANG(rad(25), 0, 0), fold, M.SmoothPlastic, { tint = true, anim = look })
	local head = neck * CF(0, 0.8, -0.85)
	Spec.wedge(l, V3(0.9, 0.6, 1.4), head * ANG(0, 0, 0), paper, M.SmoothPlastic, { tint = true, anim = look })
	Spec.block(l, V3(0.9, 0.35, 0.6), head * CF(0, -0.05, 0.4), paper, M.SmoothPlastic, { tint = true, anim = look })
	Spec.wedge(l, V3(0.8, 0.25, 1.2), head * CF(0, -0.45, -0.05) * ANG(math.pi, math.pi, 0), fold, M.SmoothPlastic, { tint = true, anim = look })
	for k = 0, 3 do
		Spec.wedge(l, V3(0.08, 0.15, 0.1), head * CF(-0.3 + k * 0.2, -0.3, -0.55) * ANG(math.pi, 0, 0), WHITE, M.SmoothPlastic, { anim = look })
	end
	eyes(l, head * CF(0, 0.2, 0.25), 0.38, 0.18, rgb(255, 60, 60), { anim = look })
	-- tiny arms, big legs
	for _, s in { -1, 1 } do
		Spec.block(l, V3(0.12, 0.12, 0.5), CF(s * 0.5, 2.0, -0.7) * ANG(rad(40), 0, 0), fold, M.SmoothPlastic, { anim = stomp })
		local hip = CF(s * 0.6, 1.3, 0.6)
		local walk = Spec.swing(0.25, 2.6, if s > 0 then 0 else math.pi, hip)
		Spec.wedge(l, V3(0.45, 1.0, 0.8), hip * CF(0, -0.4, 0), paper, M.SmoothPlastic, { tint = true, anim = walk })
		Spec.block(l, V3(0.35, 0.8, 0.35), hip * CF(0, -0.95, 0.1), fold, M.SmoothPlastic, { tint = true, anim = walk })
		Spec.wedge(l, V3(0.5, 0.25, 0.7), hip * CF(0, -1.2, -0.15), paper, M.SmoothPlastic, { anim = walk })
	end
	-- back spikes
	for k = 0, 4 do
		Spec.wedge(l, V3(0.06, 0.4, 0.4), CF(0, 2.3 - k * 0.15, -0.2 + k * 0.45), rgb(255, 90, 90), M.SmoothPlastic, { anim = stomp })
	end
	return 3.8
end

B.hematite_snake = function(l, c)
	local iron = c
	-- segmented iron body in an S curve, each segment with a red seam
	for i = 0, 13 do
		local t = i / 13
		local x = math.sin(t * math.pi * 2) * 0.9
		local z = 1.6 - t * 3.0
		local d = 0.6 + math.sin(t * math.pi) * 0.35
		local seg = CF(x, d / 2 + 0.05, z)
		local w = Spec.sway(0.12, 2.5, i * 0.5, CF(0, 0, 0))
		Spec.ball(l, d, seg, if i % 2 == 0 then iron else iron:Lerp(WHITE, 0.15), M.Metal, { tint = true, anim = w })
		if i % 2 == 0 then
			Spec.ball(l, d * 0.22, seg * CF(0, d * 0.45, 0), rgb(220, 50, 40), M.Neon, { anim = w })
		end
	end
	-- raised head
	local neck = CF(0, 0.6, -1.5)
	local strike = Spec.swing(0.15, 1.5, 0, neck)
	for k = 1, 3 do
		Spec.ball(l, 0.7 - k * 0.04, neck * CF(0, k * 0.35, -k * 0.12), iron, M.Metal, { tint = true, anim = strike })
	end
	local head = neck * CF(0, 1.4, -0.6)
	Spec.egg(l, V3(1.0, 0.6, 1.3), head, iron:Lerp(BLACK, 0.2), M.Metal, { tint = true, anim = strike })
	for _, s in { -1, 1 } do
		Spec.wedge(l, V3(0.12, 0.35, 0.6), head * CF(s * 0.35, 0.35, 0.3), iron:Lerp(WHITE, 0.3), M.Metal, { anim = strike })
		Spec.ball(l, 0.22, head * CF(s * 0.3, 0.18, -0.4), rgb(255, 40, 40), M.Neon, { anim = strike })
	end
	Spec.block(l, V3(0.05, 0.04, 0.45), head * CF(0, -0.15, -0.8), rgb(255, 120, 60), M.Neon, { anim = strike })
	-- magnet horseshoe floating overhead
	local mag = CF(0, 3.1, -1.9)
	for _, s in { -1, 1 } do
		Spec.block(l, V3(0.25, 0.6, 0.25), mag * CF(s * 0.3, -0.3, 0), rgb(220, 50, 50), M.Metal, { anim = Spec.bob(0.15, 2) })
		Spec.block(l, V3(0.25, 0.2, 0.25), mag * CF(s * 0.3, -0.7, 0), rgb(220, 220, 230), M.Metal, { anim = Spec.bob(0.15, 2) })
	end
	Spec.block(l, V3(0.85, 0.25, 0.25), mag, rgb(220, 50, 50), M.Metal, { anim = Spec.bob(0.15, 2) })
	return 3.2
end

B.ice_dragon = function(l, c)
	local ice = c
	local breathe = Spec.bob(0.05, 1.5)
	Spec.egg(l, V3(2.1, 1.7, 2.9), CF(0, 1.55, 0.2), ice, M.SmoothPlastic, { tint = true, anim = breathe })
	Spec.egg(l, V3(1.5, 1.1, 2.3), CF(0, 1.25, 0), rgb(230, 245, 255), M.SmoothPlastic, { tint = true, anim = breathe })
	-- neck + horned head
	local neck = CF(0, 2.0, -1.0)
	local look = Spec.sway(0.2, 1.0, 0, neck)
	for k = 1, 3 do
		Spec.ball(l, 0.7 - k * 0.06, neck * CF(0, k * 0.32, -k * 0.22), ice, M.SmoothPlastic, { tint = true, anim = look })
	end
	local head = neck * CF(0, 1.25, -1.0)
	Spec.egg(l, V3(0.8, 0.65, 1.3), head, ice, M.SmoothPlastic, { tint = true, anim = look })
	Spec.egg(l, V3(0.6, 0.3, 0.8), head * CF(0, -0.25, -0.35), rgb(230, 245, 255), M.SmoothPlastic, { anim = look })
	eyes(l, head * CF(0, 0.18, -0.35), 0.24, 0.2, rgb(90, 200, 255), { anim = look })
	for _, s in { -1, 1 } do
		Spec.wedge(l, V3(0.12, 0.7, 0.3), head * CF(s * 0.25, 0.55, 0.35) * ANG(rad(-35), 0, 0), rgb(200, 240, 255), M.Ice, { anim = look })
		Spec.ball(l, 0.1, head * CF(s * 0.15, -0.05, -0.68), rgb(120, 220, 255), M.Neon, { anim = look })
	end
	-- frost breath glow
	Spec.ball(l, 0.35, head * CF(0, -0.15, -0.85), rgb(170, 230, 255), M.Neon, { t = 0.3, anim = Spec.pulse(0.4, 3) })
	-- wings: a raised arm bone with three fanned membrane panels each, flapping
	for _, sd in { -1, 1 } do
		local sh = CF(sd * 0.8, 2.3, -0.1)
		local flap = Spec.roll(0.4, 1.7, if sd > 0 then 0 else math.pi, sh)
		local arm = sh * ANG(0, 0, rad(sd * 30))
		Spec.cyl(l, 2.8, 0.18, arm * CF(sd * 1.4, 0, 0), ice:Lerp(BLACK, 0.25), M.SmoothPlastic, { tint = true, anim = flap })
		Spec.ball(l, 0.3, arm * CF(sd * 2.8, 0, 0), rgb(200, 240, 255), M.Ice, { anim = flap })
		for k = 0, 2 do
			Spec.egg(l, V3(1.5, 0.06, 1.5 - k * 0.2), arm * CF(sd * (0.8 + k * 0.85), -0.1, 0.55 + k * 0.1) * ANG(0, rad(sd * (10 + k * 12)), 0), rgb(170, 220, 250), M.Glass, {
				t = 0.2,
				anim = flap,
			})
		end
	end
	-- legs + claws
	for _, s in { -1, 1 } do
		for _, f in { -1, 1 } do
			local hip = CF(s * 0.65, 1.1, f * 0.7 + 0.2)
			Spec.ucyl(l, 1.0, 0.45, hip * CF(0, -0.5, 0), ice, M.SmoothPlastic, { tint = true, anim = Spec.swing(0.15, 1.5, s * f, hip) })
			Spec.egg(l, V3(0.55, 0.25, 0.7), hip * CF(0, -1.0, -0.1), ice:Lerp(BLACK, 0.15), M.SmoothPlastic)
		end
	end
	-- back spikes of ice + tail
	for k = 0, 5 do
		Spec.wedge(l, V3(0.08, 0.5, 0.45), CF(0, 2.15 - k * 0.12, -0.4 + k * 0.4), rgb(200, 240, 255), M.Ice, { t = 0.1, anim = breathe })
	end
	for k = 1, 4 do
		Spec.ball(l, 0.6 - k * 0.1, CF(math.sin(k) * 0.2, 1.3 - k * 0.15, 1.3 + k * 0.45), ice, M.SmoothPlastic, {
			tint = true,
			anim = Spec.sway(0.25, 1.4, k * 0.4, CF(0, 1.3, 1.3)),
		})
	end
	return 3.8
end

B.void_cat = function(l, c)
	local void = c
	local stars = rgb(200, 160, 255)
	local breathe = Spec.bob(0.05, 1.4)
	Spec.egg(l, V3(1.5, 1.4, 2.2), CF(0, 1.0, 0.3), void, M.SmoothPlastic, { tint = true, anim = breathe })
	for i = 1, 8 do
		local a = i * 2.3
		Spec.ball(l, 0.09, CF(math.cos(a) * 0.55, 1.2 + math.sin(i) * 0.4, 0.3 + math.sin(a) * 0.9), stars, M.Neon, { anim = breathe })
	end
	-- sitting head with ears
	local head = CF(0, 2.1, -0.6)
	local tilt = Spec.roll(0.12, 0.9, 0, head)
	Spec.ball(l, 1.3, head, void, M.SmoothPlastic, { tint = true, anim = tilt })
	for _, s in { -1, 1 } do
		Spec.wedge(l, V3(0.15, 0.7, 0.6), head * CF(s * 0.38, 0.75, 0.05) * ANG(0, rad(s * 90), rad(s * -10)), void, M.SmoothPlastic, {
			tint = true,
			anim = tilt,
		})
		Spec.wedge(l, V3(0.08, 0.45, 0.35), head * CF(s * 0.38, 0.7, 0.02) * ANG(0, rad(s * 90), rad(s * -10)), rgb(140, 70, 200), M.Neon, {
			anim = tilt,
		})
		-- galaxy eyes
		Spec.egg(l, V3(0.38, 0.42, 0.1), head * CF(s * 0.3, 0.1, -0.6), rgb(150, 255, 230), M.Neon, { anim = tilt })
		Spec.egg(l, V3(0.08, 0.32, 0.1), head * CF(s * 0.3, 0.1, -0.64), BLACK, M.SmoothPlastic, { anim = tilt })
		for k = 0, 1 do
			Spec.block(l, V3(0.5, 0.02, 0.02), head * CF(s * 0.6, -0.15 - k * 0.08, -0.5) * ANG(0, 0, rad(s * (8 - k * 16))), rgb(230, 220, 255), M.Neon, {
				anim = tilt,
			})
		end
	end
	Spec.wedge(l, V3(0.15, 0.1, 0.12), head * CF(0, -0.1, -0.64) * ANG(math.pi, 0, 0), rgb(255, 140, 200), M.SmoothPlastic, { anim = tilt })
	-- paws, tail curling with a star tip
	for _, s in { -1, 1 } do
		Spec.ucyl(l, 0.9, 0.35, CF(s * 0.35, 0.45, -0.75), void, M.SmoothPlastic, { tint = true })
		Spec.ball(l, 0.42, CF(s * 0.35, 0.15, -0.9), void, M.SmoothPlastic, { tint = true })
	end
	for k = 1, 6 do
		local a = k / 6 * math.pi * 1.2
		Spec.ball(l, 0.35 - k * 0.025, CF(0.8 + math.sin(a) * 0.6, 0.3 + k * 0.28, 1.2 - math.cos(a) * 0.5), void, M.SmoothPlastic, {
			tint = true,
			anim = Spec.sway(0.3, 1.3, k * 0.3, CF(0.6, 0.3, 1.2)),
		})
	end
	Spec.ball(l, 0.3, CF(1.2, 2.1, 1.6), stars, M.Neon, { anim = Spec.sway(0.3, 1.3, 2, CF(0.6, 0.3, 1.2)) })
	-- the knocked-off moon floating nearby, and a void ring under it
	Spec.ball(l, 0.8, CF(-1.3, 2.9, 0.4), rgb(240, 240, 225), M.Slate, { anim = Spec.bob(0.2, 1) })
	Spec.ucyl(l, 0.05, 3.2, CF(0, 0.03, 0), rgb(120, 60, 200), M.Neon, { t = 0.4 })
	return 3.2
end

B.zoomzola = function(l, c)
	local blue = c
	local cheese = rgb(230, 235, 245)
	local wheelHub = CF(0, 1.4, 0) * ANG(0, 0, rad(90))
	-- a rolling blue-cheese wheel body (spins about X while racing)
	Spec.cyl(l, 1.2, 2.6, wheelHub * ANG(0, 0, rad(-90)) * ANG(0, rad(90), 0), cheese, M.SmoothPlastic, { tint = true })
	Spec.cyl(l, 1.24, 2.3, wheelHub * ANG(0, 0, rad(-90)) * ANG(0, rad(90), 0), cheese:Lerp(WHITE, 0.3), M.SmoothPlastic, { tint = true })
	for i = 0, 9 do
		local a = i / 10 * math.pi * 2
		local p = CF(0, 1.4 + math.sin(a) * 0.85, math.cos(a) * 0.85)
		Spec.ball(l, 0.28 + (i % 3) * 0.06, p * CF(if i % 2 == 0 then 0.62 else -0.62, 0, 0), blue, M.SmoothPlastic, { tint = true })
	end
	-- face on the wheel front
	eyes(l, CF(0, 1.75, -1.05), 0.3, 0.38, nil, nil)
	for _, s in { -1, 1 } do
		Spec.block(l, V3(0.4, 0.08, 0.08), CF(s * 0.3, 2.05, -1.12) * ANG(0, 0, rad(s * -18)), BLACK, M.SmoothPlastic)
	end
	Spec.egg(l, V3(0.6, 0.25, 0.1), CF(0, 1.25, -1.15), rgb(90, 40, 50), M.SmoothPlastic)
	-- running legs + sneakers
	for _, s in { -1, 1 } do
		local hip = CF(s * 0.45, 0.6, 0)
		local run = Spec.swing(0.9, 10, if s > 0 then 0 else math.pi, hip)
		Spec.ucyl(l, 0.6, 0.18, hip * CF(0, -0.3, 0), blue, M.SmoothPlastic, { anim = run })
		Spec.egg(l, V3(0.38, 0.25, 0.7), hip * CF(0, -0.58, -0.15), rgb(240, 60, 60), M.SmoothPlastic, { anim = run })
		Spec.block(l, V3(0.4, 0.06, 0.4), hip * CF(0, -0.68, -0.15), WHITE, M.SmoothPlastic, { anim = run })
	end
	-- speed streaks + stink puffs behind
	for k = 0, 3 do
		Spec.block(l, V3(0.06, 0.06, 1.2 + k * 0.3), CF(-0.6 + k * 0.4, 1.0 + (k % 2) * 0.7, 1.6), rgb(200, 230, 255), M.Neon, {
			t = 0.3,
			anim = Spec.pulse(0.5, 9),
		})
	end
	for k = 0, 2 do
		Spec.ball(l, 0.5 + k * 0.15, CF(0.3 * (k - 1), 2.4 + k * 0.2, 0.9 + k * 0.3), rgb(150, 200, 110), M.SmoothPlastic, {
			t = 0.35,
			anim = Spec.bob(0.15, 2, k),
		})
	end
	Spec.ucyl(l, 0.35, 0.5, CF(0, 2.85, 0), rgb(255, 200, 60), M.Neon)
	return 3
end

local function fallback(l: L, c: Color3): number
	Spec.egg(l, V3(2, 1.7, 2), CF(0, 0.9, 0), c, M.SmoothPlastic, { tint = true, anim = Spec.bob(0.05, 2) })
	eyes(l, CF(0, 1.3, -0.9), 0.36, 0.4)
	Spec.ucyl(l, 0.45, 0.9, CF(0, 1.9, 0), CHEESE, M.Neon)
	return 2.2
end

function BossModels.build(id: string, def: any): { parts: Spec.List, radius: number, height: number }
	local r = math.max(2, tonumber(if type(def) == "table" then def.radius else nil) or 4)
	local c = rgb(150, 110, 190)
	if type(def) == "table" and type(def.color) == "table" then
		c = rgb(def.color[1] or 150, def.color[2] or 110, def.color[3] or 190)
	end
	local l: L = {}
	local fn = B[id] or fallback
	local h = fn(l, c)
	return { parts = Spec.scaled(l, r), radius = r, height = h * r }
end

BossModels.IDS = B

return BossModels
