--!strict
-- PoiModels (R4 Graphics): the 3D dressing of every point of interest (GDD §3.8,
-- GDD-v2 §4). Pure visuals: Combat/World runs the POI at the same (x, z); the client
-- FxController draws the pooled ground ring + progress fill on top.
--
--   PoiModels.build(m: Model, id: string, x, z, accent: Color3, glow: Color3, rng, entry?)
--
-- Everything is anchored and non-colliding (POIs are zones you stand in). Ids are
-- matched exactly first, then by keyword, so the v2 POIs (armory / vault / totem /
-- cart) render even if Config/Pois names them slightly differently.

local Build = require(script.Parent.Build)
local Props = require(script.Parent.Props)

local PoiModels = {}

local rad = math.rad
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local M = Enum.Material

local WOOD = Color3.fromRGB(150, 100, 58)
local WOOD_DARK = Color3.fromRGB(105, 68, 38)
local STONE = Color3.fromRGB(200, 196, 184)
local STONE_DARK = Color3.fromRGB(150, 146, 136)
local METAL = Color3.fromRGB(150, 155, 165)
local GOLD = Color3.fromRGB(255, 200, 70)
local CHEESE = Props.CHEESE

type Rng = any
type Builder = (m: Model, x: number, z: number, accent: Color3, glow: Color3, rng: Rng, entry: any?) -> ()

local function sparkle(parent: Instance, color: Color3, rate: number, spread: number?)
	Build.emitter(parent, {
		name = "Glint",
		texture = Build.TEX.sparkles,
		color = Build.cs(color, Color3.new(1, 1, 1)),
		size = Build.ns(0.5, 0),
		transparency = Build.ns(0, 1),
		lifetime = NumberRange.new(0.8, 1.6),
		rate = rate,
		speed = NumberRange.new(1, 3),
		spread = Vector2.new(spread or 180, spread or 180),
		lightEmission = 1,
		shape = Enum.ParticleEmitterShape.Sphere,
	})
end

local function anchorPart(m: Instance, at: CFrame): Part
	return Build.block(m, V3(0.3, 0.3, 0.3), at, Color3.new(1, 1, 1), M.SmoothPlastic, {
		name = "FxAnchor",
		transparency = 1,
		shadow = false,
	})
end

local function wheel(m: Instance, cf: CFrame, d: number, h: number, col: Color3)
	Build.ucyl(m, h, d, cf, col, M.SmoothPlastic)
	Build.ucyl(m, h * 0.6, d + 0.12, cf, Props.RIND, M.SmoothPlastic, { shadow = false })
	-- a cut wedge out of the top wheel reads as cheese
	Build.ball(m, d * 0.16, cf * CF(d * 0.28, h * 0.5, 0), Props.HOLE, M.SmoothPlastic, { shadow = false })
	Build.ball(
		m,
		d * 0.1,
		cf * CF(-d * 0.2, h * 0.5, d * 0.18),
		Props.HOLE,
		M.SmoothPlastic,
		{ shadow = false }
	)
end

local function pallet(m: Instance, cf: CFrame, w: number, l: number)
	for i = -1, 1 do
		Build.block(m, V3(w, 0.25, l / 3 - 0.15), cf * CF(0, 0.55, i * l / 3), WOOD, M.WoodPlanks)
	end
	for i = -1, 1, 2 do
		Build.block(m, V3(0.5, 0.45, l), cf * CF(i * (w / 2 - 0.3), 0.22, 0), WOOD_DARK, M.Wood)
	end
end

local B: { [string]: Builder } = {}

B.cheese_cache = function(m, x, z, _accent, _glow, rng)
	local cf = CF(x, 0, z) * ANG(0, rng:range(0, 6.28), 0)
	pallet(m, cf, 5, 5)
	wheel(m, cf * CF(-1.1, 1.4, -0.9), 2.6, 1.2, CHEESE)
	wheel(m, cf * CF(1.2, 1.4, 0.8), 2.4, 1.2, Props.CHEESE_DARK)
	wheel(m, cf * CF(0, 2.6, 0), 2.6, 1.2, CHEESE)
	Props.cheeseWedge(m, cf * CF(0.3, 3.2, 0.2) * ANG(0, 0.7, 0), 1.8, 0.9, rng)
	sparkle(anchorPart(m, cf * CF(0, 3, 0)), GOLD, 4)
end

local function shrine(m: Model, x: number, z: number, glow: Color3, topper: string)
	local cf = CF(x, 0, z)
	Build.ucyl(m, 0.5, 6.4, cf * CF(0, 0.25, 0), STONE_DARK, M.Marble)
	Build.ucyl(m, 0.5, 5, cf * CF(0, 0.75, 0), STONE, M.Marble)
	Build.ucyl(m, 0.08, 5.4, cf * CF(0, 1.02, 0), glow, M.Neon, { shadow = false, transparency = 0.2 })
	for i = 0, 3 do
		local a = i / 4 * math.pi * 2 + math.pi / 4
		local p = cf * CF(math.cos(a) * 2.2, 0, math.sin(a) * 2.2)
		Build.block(m, V3(0.7, 3.2, 0.7), p * CF(0, 2.6, 0), STONE, M.Marble)
		Build.block(m, V3(0.9, 0.3, 0.9), p * CF(0, 4.3, 0), STONE_DARK, M.Marble)
		Build.ball(m, 0.6, p * CF(0, 4.75, 0), glow, M.Neon, { shadow = false })
	end
	Build.ucyl(m, 3.2, 1.2, cf * CF(0, 2.6, 0), STONE, M.Marble)
	Build.ucyl(m, 0.4, 2, cf * CF(0, 4.3, 0), STONE_DARK, M.Marble)
	local orb = Build.ball(m, 1.8, cf * CF(0, 5.7, 0), glow, M.Neon, { shadow = false })
	Build.ball(m, 2.8, cf * CF(0, 5.7, 0), glow, M.ForceField, { shadow = false, transparency = 0.3 })
	Build.light(orb, glow, 18, 2.2, false)
	sparkle(orb, glow, 6)
	if topper == "wings" then
		for _, s in { -1, 1 } do
			Build.wedge(
				m,
				V3(0.15, 1.2, 2.2),
				cf * CF(s * 1.5, 5.9, 0) * ANG(0, rad(90 * s), 0) * ANG(rad(20), 0, 0),
				Color3.new(1, 1, 1),
				M.SmoothPlastic,
				{
					shadow = false,
				}
			)
		end
	elseif topper == "blade" then
		Build.block(m, V3(0.25, 2.6, 0.6), cf * CF(0, 7.8, 0), METAL, M.Metal)
		Build.block(m, V3(1.4, 0.25, 0.4), cf * CF(0, 6.7, 0), GOLD, M.Metal, { shadow = false })
	else
		for k = 0, 1 do
			Build.block(
				m,
				V3(if k == 0 then 1.6 else 0.5, if k == 0 then 0.5 else 1.6, 0.3),
				cf * CF(0, 7.4, 0),
				Color3.new(1, 1, 1),
				M.Neon,
				{
					shadow = false,
				}
			)
		end
	end
end

B.shrine_swift = function(m, x, z, _accent, glow, _rng)
	shrine(m, x, z, glow, "wings")
end
B.shrine_might = function(m, x, z, _accent, glow, _rng)
	shrine(m, x, z, glow, "blade")
end
B.shrine_mending = function(m, x, z, _accent, glow, _rng)
	shrine(m, x, z, glow, "cross")
end

B.elite_camp = function(m, x, z, _accent, glow, rng)
	local cf = CF(x, 0, z) * ANG(0, rng:range(0, 6.28), 0)
	local cloth = Color3.fromRGB(170, 52, 48)
	-- A-frame tent: two wedges back to back
	for _, s in { -1, 1 } do
		Build.wedge(
			m,
			V3(4.6, 3.6, 2.4),
			cf * CF(s * 1.2, 1.8, -2.5) * ANG(0, rad(-90 * s), 0),
			cloth,
			M.Fabric
		)
	end
	Build.block(m, V3(0.3, 3.8, 0.3), cf * CF(0, 1.9, -4.8), WOOD_DARK, M.Wood)
	-- campfire
	local fire = cf * CF(0, 0, 1.4)
	for i = 0, 3 do
		Build.cyl(m, 2, 0.45, fire * ANG(0, i * math.pi / 4, 0) * CF(0, 0.25, 0), WOOD_DARK, M.Wood)
	end
	for i = 0, 7 do
		local a = i / 8 * 6.28
		Build.ball(
			m,
			0.6,
			fire * CF(math.cos(a) * 1.3, 0.2, math.sin(a) * 1.3),
			STONE_DARK,
			M.Slate,
			{ shadow = false }
		)
	end
	local flame =
		Build.egg(m, V3(0.9, 1.4, 0.9), fire * CF(0, 0.9, 0), Color3.fromRGB(255, 150, 40), M.Neon, {
			shadow = false,
			transparency = 0.2,
		})
	Build.light(flame, Color3.fromRGB(255, 140, 50), 20, 2.5, true)
	Build.emitter(flame, {
		name = "Fire",
		texture = Build.TEX.fire,
		color = Build.cs(Color3.fromRGB(255, 200, 80), Color3.fromRGB(255, 70, 20)),
		size = Build.ns(1.4, 0.2),
		transparency = Build.ns(0.2, 1),
		lifetime = NumberRange.new(0.5, 0.9),
		rate = 18,
		speed = NumberRange.new(2, 4),
		spread = Vector2.new(10, 10),
		lightEmission = 1,
		rotSpeed = NumberRange.new(-60, 60),
	})
	-- spiked palisade
	for i = 0, 6 do
		local a = rad(200) + i / 6 * rad(140)
		local p = cf * CF(math.cos(a) * 5.4, 0, math.sin(a) * 5.4)
		Build.ucyl(m, 2.6, 0.5, p * CF(0, 1.3, 0), WOOD, M.Wood)
		Build.wedge(m, V3(0.5, 0.8, 0.5), p * CF(0, 2.9, 0), WOOD_DARK, M.Wood, { shadow = false })
	end
	-- war banner
	Props.banner(m, cf * CF(3.6, 0, -2.6), Color3.fromRGB(200, 40, 40), 7)
	-- treasure chest
	local chest = cf * CF(-3, 0, 1.2) * ANG(0, 0.4, 0)
	Build.block(m, V3(2, 1.2, 1.3), chest * CF(0, 0.6, 0), WOOD, M.WoodPlanks)
	Build.cyl(m, 2, 1.3, chest * CF(0, 1.2, 0), WOOD_DARK, M.WoodPlanks)
	Build.block(m, V3(2.1, 0.2, 1.4), chest * CF(0, 1.1, 0), GOLD, M.Metal, { shadow = false })
	Build.block(m, V3(0.3, 0.4, 0.1), chest * CF(0, 0.95, -0.7), GOLD, M.Metal, { shadow = false })
	local _ = glow
end

B.crumb_fountain = function(m, x, z, _accent, glow, _rng)
	local cf = CF(x, 0, z)
	Build.ucyl(m, 0.8, 8, cf * CF(0, 0.4, 0), STONE_DARK, M.Cobblestone)
	Build.ucyl(m, 0.3, 7, cf * CF(0, 0.75, 0), glow, M.Neon, { transparency = 0.35, shadow = false })
	Build.ucyl(m, 2.2, 1.6, cf * CF(0, 1.9, 0), STONE, M.Marble)
	Build.ucyl(m, 0.5, 4.2, cf * CF(0, 3.1, 0), STONE_DARK, M.Marble)
	Build.ucyl(m, 0.2, 3.6, cf * CF(0, 3.32, 0), glow, M.Neon, { transparency = 0.3, shadow = false })
	Build.ucyl(m, 1.2, 0.8, cf * CF(0, 3.9, 0), STONE, M.Marble)
	local crumb = Build.ball(m, 1.3, cf * CF(0, 5, 0), CHEESE, M.Neon, { shadow = false })
	Build.light(crumb, glow, 16, 1.6)
	Build.emitter(crumb, {
		name = "Spray",
		texture = Build.TEX.sparkles,
		color = Build.cs(glow:Lerp(Color3.new(1, 1, 1), 0.5)),
		size = Build.ns(0.4, 0.1),
		transparency = Build.ns(0.1, 1),
		lifetime = NumberRange.new(0.8, 1.2),
		rate = 16,
		speed = NumberRange.new(5, 7),
		spread = Vector2.new(35, 35),
		accel = Vector3.new(0, -18, 0),
		lightEmission = 0.8,
	})
	for i = 0, 5 do
		local a = i / 6 * 6.28
		Build.block(
			m,
			V3(0.5, 0.4, 0.5),
			cf * CF(math.cos(a) * 3.4, 0.95, math.sin(a) * 3.4) * ANG(0, a, 0.4),
			CHEESE,
			M.SmoothPlastic,
			{
				shadow = false,
			}
		)
	end
end

B.mousetrap_field = function(m, x, z, _accent, _glow, rng, entry)
	local r = if entry and tonumber(entry.r) then entry.r else 12
	-- scattered loose planks instead of one disc
	for i = 1, 6 do
		local a = i / 6 * 6.28 + rng:range(-0.3, 0.3)
		local d = r * rng:range(0.2, 0.8)
		Build.block(
			m,
			V3(1.2, 0.12, r * 0.6),
			CF(x + math.cos(a) * d, 0.06, z + math.sin(a) * d) * ANG(0, rng:range(0, 3.14), 0),
			WOOD,
			M.WoodPlanks,
			{
				shadow = false,
			}
		)
	end
	local spots = if entry and type(entry.traps) == "table" then entry.traps else { { x = x, z = z } }
	for _, t in spots do
		local tx, tz = tonumber(t.x) or x, tonumber(t.z) or z
		local cf = CF(tx, 0, tz) * ANG(0, rng:range(0, 3.14), 0)
		Build.block(
			m,
			V3(3.2, 0.3, 2),
			cf * CF(0, 0.15, 0),
			Color3.fromRGB(205, 165, 110),
			M.Wood,
			{ shadow = false }
		)
		Build.block(m, V3(2.9, 0.12, 0.12), cf * CF(0, 0.38, -0.7), METAL, M.Metal, { shadow = false })
		Build.block(m, V3(2.9, 0.12, 0.12), cf * CF(0, 0.38, 0.7), METAL, M.Metal, { shadow = false })
		Build.cyl(
			m,
			2.9,
			0.22,
			cf * CF(0, 0.42, 0),
			Color3.fromRGB(120, 120, 130),
			M.Metal,
			{ shadow = false }
		)
		Build.block(m, V3(0.12, 0.12, 1.4), cf * CF(1.3, 0.4, 0), METAL, M.Metal, { shadow = false })
		Props.cheeseWedge(m, cf * CF(-0.6, 0.3, 0.2), 0.9, 0.4, nil)
	end
end

B.grandmas_pantry = function(m, x, z, accent, glow, rng)
	local cf = CF(x, 0, z) * ANG(0, rng:range(0, 6.28), 0)
	local wood = Color3.fromRGB(160, 102, 64)
	Build.block(m, V3(5.2, 6, 3), cf * CF(0, 3, 0), wood, M.WoodPlanks)
	Build.block(m, V3(5.6, 0.4, 3.4), cf * CF(0, 6.2, 0), Build.shade(wood, -0.2), M.Wood)
	for _, s in { -1, 1 } do
		Build.block(m, V3(2.3, 3.2, 0.15), cf * CF(s * 1.25, 2.2, -1.55), Build.shade(wood, 0.12), M.Wood)
		Build.ball(m, 0.3, cf * CF(s * 0.35, 2.4, -1.7), GOLD, M.Metal, { shadow = false })
	end
	Build.block(
		m,
		V3(5, 0.25, 0.2),
		cf * CF(0, 4.3, -1.5),
		Build.shade(wood, -0.2),
		M.Wood,
		{ shadow = false }
	)
	Build.block(m, V3(5.4, 0.12, 3.2), cf * CF(0, 6.45, 0), accent, M.Fabric, { shadow = false })
	Build.ucyl(m, 0.7, 2.6, cf * CF(-1, 6.9, 0), Color3.fromRGB(235, 175, 90), M.SmoothPlastic)
	Build.ucyl(
		m,
		0.2,
		2.2,
		cf * CF(-1, 7.3, 0),
		Color3.fromRGB(200, 120, 60),
		M.SmoothPlastic,
		{ shadow = false }
	)
	for i = 0, 2 do
		local jar = cf * CF(0.8 + i * 0.8, 6.9, 0.3 * (i - 1))
		Build.ucyl(m, 1.1, 0.7, jar, Color3.fromRGB(200, 235, 255), M.Glass, { transparency = 0.35 })
		Build.ucyl(
			m,
			0.25,
			0.75,
			jar * CF(0, 0.65, 0),
			Color3.fromRGB(220, 60, 60),
			M.Fabric,
			{ shadow = false }
		)
		Build.ucyl(
			m,
			0.7,
			0.55,
			jar * CF(0, -0.1, 0),
			if i == 1 then CHEESE else Color3.fromRGB(240, 120, 150),
			M.SmoothPlastic,
			{
				shadow = false,
			}
		)
	end
	sparkle(anchorPart(m, cf * CF(0, 7.5, 0)), glow, 5)
end

B.lost_herd_statue = function(m, x, z, _accent, glow, _rng)
	local cf = CF(x, 0, z)
	local stone = Color3.fromRGB(225, 220, 205)
	Build.block(m, V3(7, 0.6, 7), cf * CF(0, 0.3, 0), Build.shade(stone, -0.25), M.Marble)
	Build.block(m, V3(5.8, 0.8, 5.8), cf * CF(0, 1, 0), Build.shade(stone, -0.15), M.Marble)
	Build.egg(m, V3(4.4, 3.8, 5.4), cf * CF(0, 3.6, 0.3), stone, M.Marble)
	Build.ball(m, 3, cf * CF(0, 5.2, -2.3), stone, M.Marble)
	for _, s in { -1, 1 } do
		Build.egg(m, V3(0.4, 2.8, 2.4), cf * CF(s * 1.7, 5.3, -1.9) * ANG(0, rad(s * 20), 0), stone, M.Marble)
		Build.ucyl(m, 1.6, 1.1, cf * CF(s * 1.2, 2.2, -1.6), stone, M.Marble)
		Build.ucyl(m, 1.6, 1.1, cf * CF(s * 1.2, 2.2, 2), stone, M.Marble)
		Build.cyl(
			m,
			1.4,
			0.35,
			cf * CF(s * 0.7, 4.3, -3.4) * ANG(0, rad(90), rad(-20)),
			Color3.fromRGB(255, 250, 235),
			M.Marble,
			{
				shadow = false,
			}
		)
	end
	Build.ucyl(m, 2.4, 0.8, cf * CF(0, 3.9, -3.9) * ANG(rad(25), 0, 0), stone, M.Marble)
	Build.ucyl(m, 1.4, 0.65, cf * CF(0, 2.6, -4.6) * ANG(rad(-10), 0, 0), stone, M.Marble)
	local halo = Build.cyl(
		m,
		0.2,
		4,
		cf * CF(0, 7.6, -2.3) * Build.UPRIGHT,
		glow,
		M.Neon,
		{ transparency = 0.25, shadow = false }
	)
	Build.light(halo, glow, 20, 2)
	sparkle(halo, glow, 5)
end

-- v2 POIs --------------------------------------------------------------------------------------

B.armory_crate = function(m, x, z, _accent, glow, rng)
	local cf = CF(x, 0, z) * ANG(0, rng:range(0, 6.28), 0)
	local box = cf * CF(0, 1.4, 0)
	Build.block(m, V3(4, 2.6, 3), box, WOOD, M.WoodPlanks)
	for _, s in { -1, 1 } do
		Build.block(m, V3(4.1, 0.3, 3.1), box * CF(0, s * 0.9, 0), METAL, M.DiamondPlate, { shadow = false })
		Build.block(m, V3(0.3, 2.7, 3.1), box * CF(s * 1.6, 0, 0), METAL, M.Metal, { shadow = false })
	end
	-- lid propped open with a glow inside
	Build.block(
		m,
		V3(4, 0.3, 3),
		box * CF(0, 1.4, 1.5) * ANG(rad(55), 0, 0) * CF(0, 0, -1.5),
		Build.shade(WOOD, -0.1),
		M.WoodPlanks
	)
	local inner = Build.block(m, V3(3.6, 0.2, 2.6), box * CF(0, 1.25, 0), glow, M.Neon, { shadow = false })
	Build.light(inner, glow, 14, 2)
	sparkle(inner, glow, 8, 25)
	-- emblem: crossed blade + round shield
	Build.cyl(
		m,
		0.15,
		1.6,
		box * CF(0, 0, -1.55) * ANG(0, rad(90), 0),
		Color3.fromRGB(190, 60, 50),
		M.Metal,
		{ shadow = false }
	)
	Build.block(
		m,
		V3(0.25, 2, 0.1),
		box * CF(0, 0, -1.65) * ANG(0, 0, rad(40)),
		METAL,
		M.Metal,
		{ shadow = false }
	)
	-- smaller crates around it
	for i = 1, 2 do
		local c2 = cf
			* CF(if i == 1 then 2.8 else -2.6, 0.6, if i == 1 then 1.2 else -1)
			* ANG(0, rng:range(0, 1), 0)
		Build.block(m, V3(1.4, 1.2, 1.4), c2, Build.shade(WOOD, -0.15), M.WoodPlanks)
		Build.block(m, V3(1.5, 0.15, 1.5), c2 * CF(0, 0.45, 0), METAL, M.Metal, { shadow = false })
	end
end

B.cheese_vault = function(m, x, z, _accent, glow, rng)
	local cf = CF(x, 0, z) * ANG(0, rng:range(0, 6.28), 0)
	-- stone bunker
	Build.block(m, V3(7, 5.4, 3), cf * CF(0, 2.7, 0.6), STONE_DARK, M.Slate)
	Build.block(m, V3(7.6, 0.6, 3.6), cf * CF(0, 5.6, 0.6), Build.shade(STONE_DARK, -0.15), M.Slate)
	-- round vault door
	local door = cf * CF(0, 2.8, -0.95)
	Build.cyl(m, 0.5, 4.6, door * ANG(0, rad(90), 0), METAL, M.DiamondPlate)
	Build.cyl(m, 0.6, 5, door * CF(0, 0, 0.05) * ANG(0, rad(90), 0), GOLD, M.Metal, { shadow = false })
	Build.cyl(
		m,
		0.7,
		1,
		door * CF(0, 0, -0.35) * ANG(0, rad(90), 0),
		Build.shade(METAL, -0.2),
		M.Metal,
		{ shadow = false }
	)
	for i = 0, 2 do
		Build.block(
			m,
			V3(3, 0.22, 0.22),
			door * CF(0, 0, -0.55) * ANG(0, 0, i * math.pi / 3),
			GOLD,
			M.Metal,
			{ shadow = false }
		)
	end
	for i = 0, 7 do
		local a = i / 8 * 6.28
		Build.ball(
			m,
			0.32,
			door * CF(math.cos(a) * 1.95, math.sin(a) * 1.95, -0.3),
			GOLD,
			M.Metal,
			{ shadow = false }
		)
	end
	local ring = Build.cyl(
		m,
		0.1,
		5.4,
		door * CF(0, 0, 0.25) * ANG(0, rad(90), 0),
		glow,
		M.Neon,
		{ shadow = false, transparency = 0.2 }
	)
	Build.light(ring, glow, 18, 2)
	-- cheese hoard either side
	for _, s in { -1, 1 } do
		wheel(m, cf * CF(s * 4.6, 0.6, -0.4), 2.2, 1.2, CHEESE)
		wheel(m, cf * CF(s * 4.6, 1.8, -0.4), 2, 1.2, Props.CHEESE_DARK)
	end
	sparkle(anchorPart(m, cf * CF(0, 4, -1.5)), GOLD, 6)
end

B.power_totem = function(m, x, z, _accent, glow, _rng)
	local cf = CF(x, 0, z)
	Build.ucyl(m, 0.6, 5, cf * CF(0, 0.3, 0), STONE_DARK, M.Slate)
	local colors = { Color3.fromRGB(190, 90, 50), Color3.fromRGB(80, 140, 170), Color3.fromRGB(220, 170, 60) }
	for i = 0, 2 do
		local seg = cf * CF(0, 1.6 + i * 2.1, 0)
		Build.block(m, V3(2.2, 2, 2.2), seg, colors[i + 1], M.Wood)
		for _, s in { -1, 1 } do
			Build.block(
				m,
				V3(0.5, 0.35, 0.12),
				seg * CF(s * 0.5, 0.35, -1.12),
				glow,
				M.Neon,
				{ shadow = false }
			)
		end
		Build.block(
			m,
			V3(1.3, 0.25, 0.12),
			seg * CF(0, -0.5, -1.12),
			Build.shade(colors[i + 1], -0.4),
			M.Wood,
			{ shadow = false }
		)
		Build.wedge(
			m,
			V3(2.2, 0.5, 0.6),
			seg * CF(0, 0.2, -1.35) * ANG(0, 0, 0),
			Build.shade(colors[i + 1], -0.2),
			M.Wood,
			{
				shadow = false,
			}
		)
	end
	for _, s in { -1, 1 } do
		Build.wedge(
			m,
			V3(0.3, 1.6, 3),
			cf * CF(s * 2.2, 7.4, 0) * ANG(0, rad(90 * s), 0),
			Color3.fromRGB(230, 210, 170),
			M.Wood
		)
	end
	local top = Build.ball(m, 1.6, cf * CF(0, 8.6, 0), glow, M.Neon, { shadow = false })
	Build.light(top, glow, 22, 2.5)
	Build.emitter(top, {
		name = "Aura",
		texture = Build.TEX.sparkles,
		color = Build.cs(glow, Color3.new(1, 1, 1)),
		size = Build.ns(0.6, 0),
		lifetime = NumberRange.new(1.5, 2.5),
		rate = 10,
		speed = NumberRange.new(0.5, 1.5),
		accel = Vector3.new(0, 2, 0),
		lightEmission = 1,
		shape = Enum.ParticleEmitterShape.Sphere,
	})
	-- capture ring stones
	for i = 0, 7 do
		local a = i / 8 * 6.28
		Build.block(
			m,
			V3(0.9, 0.8, 0.9),
			cf * CF(math.cos(a) * 6.5, 0.4, math.sin(a) * 6.5) * ANG(0, a, 0),
			STONE,
			M.Slate,
			{
				shadow = false,
			}
		)
		Build.block(
			m,
			V3(0.3, 0.12, 0.3),
			cf * CF(math.cos(a) * 6.5, 0.86, math.sin(a) * 6.5),
			glow,
			M.Neon,
			{ shadow = false }
		)
	end
end

B.shop_cart = function(m, x, z, _accent, glow, rng)
	local cf = CF(x, 0, z) * ANG(0, rng:range(0, 6.28), 0)
	local body = cf * CF(0, 1.9, 0)
	Build.block(m, V3(5, 1.6, 2.8), body, Color3.fromRGB(170, 100, 60), M.WoodPlanks)
	Build.block(m, V3(5.2, 0.25, 3), body * CF(0, 0.9, 0), WOOD_DARK, M.Wood, { shadow = false })
	for _, s in { -1, 1 } do
		local w = body * CF(s * 1.4, -0.9, -1.55)
		Build.cyl(m, 0.3, 2.2, w * ANG(0, rad(90), 0), WOOD_DARK, M.Wood)
		Build.cyl(m, 0.34, 0.6, w * ANG(0, rad(90), 0), GOLD, M.Metal, { shadow = false })
		Build.cyl(m, 0.3, 2.2, body * CF(s * 1.4, -0.9, 1.55) * ANG(0, rad(90), 0), WOOD_DARK, M.Wood)
		Build.block(m, V3(0.25, 3.2, 0.25), body * CF(s * 2.4, 2.3, 1.2), WOOD_DARK, M.Wood)
		Build.block(m, V3(0.25, 3.2, 0.25), body * CF(s * 2.4, 2.3, -1.2), WOOD_DARK, M.Wood)
	end
	-- striped awning
	for i = 0, 5 do
		local col = if i % 2 == 0 then Color3.fromRGB(230, 60, 60) else Color3.fromRGB(255, 245, 225)
		Build.block(
			m,
			V3(5.4 / 6, 0.15, 3.4),
			body * CF(-2.25 + i * 0.9, 3.95, 0) * ANG(rad(-6), 0, 0),
			col,
			M.Fabric
		)
	end
	-- wares: gear on display
	Build.block(
		m,
		V3(1, 0.7, 0.8),
		body * CF(-1.4, 1.35, 0),
		Color3.fromRGB(78, 168, 255),
		M.Glass,
		{ transparency = 0.15 }
	)
	Build.ball(
		m,
		0.9,
		body * CF(0, 1.45, 0.2),
		Color3.fromRGB(179, 107, 255),
		M.Glass,
		{ transparency = 0.15 }
	)
	Build.block(
		m,
		V3(0.9, 0.9, 0.3),
		body * CF(1.3, 1.45, -0.2) * ANG(0, 0.5, 0),
		Color3.fromRGB(255, 154, 46),
		M.Metal
	)
	Props.cheeseWedge(m, body * CF(1.6, 1, 0.8), 0.9, 0.4, nil)
	local lantern = Build.ucyl(
		m,
		0.6,
		0.45,
		body * CF(2.4, 3.35, -1.4),
		Color3.fromRGB(255, 220, 140),
		M.Neon,
		{ shadow = false }
	)
	Build.light(lantern, Color3.fromRGB(255, 210, 130), 14, 1.6)
	-- sign post
	Build.block(m, V3(1.8, 1, 0.15), cf * CF(-3.4, 1.8, 0) * ANG(0, rad(80), 0), WOOD, M.WoodPlanks)
	Build.block(m, V3(0.2, 2.2, 0.2), cf * CF(-3.4, 1.1, 0), WOOD_DARK, M.Wood)
	sparkle(lantern, glow, 3)
end

-- Landmarks (one per map, GDD §3.2) ----------------------------------------------------------------

local function landmarkBase(m: Model, cf: CFrame, glow: Color3, rng: Rng)
	B.cheese_cache(m, cf.X + 3.5, cf.Z + 2.5, glow, glow, rng)
end

B.giant_cowbell = function(m, x, z, accent, glow, rng)
	local cf = CF(x, 0, z)
	Build.block(m, V3(0.5, 7, 0.5), cf * CF(-2.6, 3.5, 0), WOOD_DARK, M.Wood)
	Build.block(m, V3(0.5, 7, 0.5), cf * CF(2.6, 3.5, 0), WOOD_DARK, M.Wood)
	Build.block(m, V3(6, 0.6, 0.6), cf * CF(0, 7, 0), WOOD, M.Wood)
	local bell = cf * CF(0, 4.3, 0)
	Build.ucyl(m, 3.2, 3.2, bell, GOLD, M.Metal)
	Build.ucyl(m, 0.5, 3.8, bell * CF(0, -1.6, 0), Build.shade(GOLD, -0.2), M.Metal)
	Build.ball(m, 0.9, bell * CF(0, -2.2, 0), METAL, M.Metal)
	Build.ucyl(m, 0.6, 3.3, bell * CF(0, 0.4, 0), Color3.fromRGB(200, 40, 40), M.Fabric, { shadow = false })
	Build.light(anchorPart(m, bell * CF(0, -1, -2)), accent, 16, 1.5)
	landmarkBase(m, cf, glow, rng)
end

B.gouda_wheel_hut = function(m, x, z, _accent, glow, rng)
	local cf = CF(x, 0, z)
	Build.ucyl(m, 4.5, 8, cf * CF(0, 2.25, 0), Color3.fromRGB(240, 170, 60), M.SmoothPlastic)
	Build.ucyl(m, 0.8, 8.4, cf * CF(0, 4.6, 0), Color3.fromRGB(200, 60, 40), M.SmoothPlastic)
	Props.cone(m, cf * CF(0, 5, 0), 4.8, 3.4, 9, Color3.fromRGB(200, 60, 40), M.Fabric)
	Build.block(m, V3(1.8, 2.8, 0.3), cf * CF(0, 1.4, -4), WOOD_DARK, M.Wood)
	for _, s in { -1, 1 } do
		local win = Build.ucyl(
			m,
			0.3,
			1.2,
			cf * CF(s * 2.6, 3, -3.1) * ANG(rad(90), 0, 0),
			Color3.fromRGB(255, 220, 140),
			M.Neon,
			{
				shadow = false,
			}
		)
		if s == 1 then
			Build.light(win, Color3.fromRGB(255, 210, 120), 12, 1.2)
		end
	end
	Build.ucyl(m, 2.2, 0.8, cf * CF(2, 7.2, 1), STONE_DARK, M.Brick)
	local _ = glow
	local __ = rng
end

B.pepper_idol = function(m, x, z, _accent, glow, rng)
	local cf = CF(x, 0, z)
	Build.block(m, V3(6, 1, 6), cf * CF(0, 0.5, 0), STONE_DARK, M.Slate)
	Build.block(m, V3(4.6, 1, 4.6), cf * CF(0, 1.5, 0), STONE, M.Slate)
	Build.egg(m, V3(3, 5, 3), cf * CF(0, 4.6, 0), Color3.fromRGB(210, 40, 40), M.SmoothPlastic)
	Build.ucyl(
		m,
		1.2,
		0.6,
		cf * CF(0, 7.6, 0) * ANG(0, 0, rad(15)),
		Color3.fromRGB(60, 140, 50),
		M.SmoothPlastic
	)
	for _, s in { -1, 1 } do
		local eye = Build.ball(m, 0.6, cf * CF(s * 0.6, 5.3, -1.35), glow, M.Neon, { shadow = false })
		if s == 1 then
			Build.light(eye, Color3.fromRGB(255, 90, 40), 14, 2)
		end
	end
	Build.block(
		m,
		V3(1.4, 0.3, 0.2),
		cf * CF(0, 4.2, -1.45),
		Color3.fromRGB(60, 20, 20),
		M.SmoothPlastic,
		{ shadow = false }
	)
	for i = 0, 3 do
		local a = i / 4 * 6.28 + 0.78
		local p = cf * CF(math.cos(a) * 2.6, 2.6, math.sin(a) * 2.6)
		local fl =
			Build.egg(m, V3(0.5, 0.9, 0.5), p, Color3.fromRGB(255, 150, 40), M.Neon, { shadow = false })
		Build.emitter(fl, {
			name = "Fire",
			texture = Build.TEX.fire,
			color = Build.cs(Color3.fromRGB(255, 200, 80), Color3.fromRGB(255, 60, 20)),
			size = Build.ns(0.7, 0.1),
			transparency = Build.ns(0.2, 1),
			lifetime = NumberRange.new(0.4, 0.7),
			rate = 10,
			speed = NumberRange.new(1.5, 3),
			spread = Vector2.new(8, 8),
			lightEmission = 1,
		})
	end
	local _ = rng
end

B.message_bottle = function(m, x, z, _accent, glow, rng)
	local cf = CF(x, 0, z) * ANG(0, rng:range(0, 6.28), 0)
	local bottle = cf * CF(0, 1.4, 0) * ANG(0, 0, rad(80))
	Build.ucyl(m, 5, 2.6, bottle, Color3.fromRGB(120, 200, 170), M.Glass, { transparency = 0.35 })
	Build.ucyl(
		m,
		1.6,
		1.1,
		bottle * CF(0, 3.2, 0),
		Color3.fromRGB(120, 200, 170),
		M.Glass,
		{ transparency = 0.35 }
	)
	Build.ucyl(m, 0.8, 1.15, bottle * CF(0, 4.2, 0), Color3.fromRGB(150, 110, 70), M.Wood)
	Build.cyl(
		m,
		2.6,
		1.2,
		bottle * CF(0, 0, 0) * Build.UPRIGHT,
		Color3.fromRGB(245, 230, 190),
		M.Fabric,
		{ shadow = false }
	)
	Build.block(
		m,
		V3(0.3, 0.8, 0.3),
		bottle * CF(0, 0.4, 0.1),
		Color3.fromRGB(200, 40, 40),
		M.Fabric,
		{ shadow = false }
	)
	sparkle(anchorPart(m, cf * CF(0, 2.5, 0)), glow, 4)
end

B.frozen_mammoth = function(m, x, z, _accent, glow, _rng)
	local cf = CF(x, 0, z)
	local fur = Color3.fromRGB(120, 80, 55)
	Build.egg(m, V3(4, 3.8, 5.6), cf * CF(0, 3.2, 0), fur, M.Fabric)
	Build.ball(m, 2.8, cf * CF(0, 4.4, -2.8), fur, M.Fabric)
	for _, s in { -1, 1 } do
		Build.ucyl(m, 2.2, 1.2, cf * CF(s * 1.2, 1.1, -1.5), fur, M.Fabric)
		Build.ucyl(m, 2.2, 1.2, cf * CF(s * 1.2, 1.1, 1.6), fur, M.Fabric)
		for k = 0, 2 do
			Build.ucyl(
				m,
				1.2,
				0.4 - k * 0.08,
				cf * CF(s * (0.9 + k * 0.25), 3.2 - k * 0.4, -4.1 - k * 0.6) * ANG(rad(70 + k * 25), 0, 0),
				Color3.fromRGB(250, 245, 230),
				M.Marble,
				{
					shadow = false,
				}
			)
		end
	end
	Build.ucyl(m, 2.4, 0.8, cf * CF(0, 2.6, -4) * ANG(rad(15), 0, 0), fur, M.Fabric)
	Build.block(
		m,
		V3(6.4, 7, 8.2),
		cf * CF(0, 3.4, -0.6) * ANG(0, rad(8), 0),
		Color3.fromRGB(170, 220, 255),
		M.Ice,
		{ transparency = 0.55 }
	)
	Build.light(anchorPart(m, cf * CF(0, 6, -5)), glow, 18, 1.5)
end

B.molten_fondue = function(m, x, z, _accent, glow, _rng)
	local cf = CF(x, 0, z)
	for i = 0, 2 do
		local a = i / 3 * 6.28
		Build.block(
			m,
			V3(0.5, 3.2, 0.5),
			cf
				* CF(math.cos(a) * 2.4, 1.6, math.sin(a) * 2.4)
				* ANG(math.sin(a) * 0.25, 0, -math.cos(a) * 0.25),
			METAL,
			M.CorrodedMetal
		)
	end
	Build.ucyl(m, 2.6, 5.2, cf * CF(0, 3.3, 0), Color3.fromRGB(60, 50, 50), M.CorrodedMetal)
	Build.ucyl(m, 0.4, 5.6, cf * CF(0, 4.6, 0), Color3.fromRGB(90, 70, 60), M.Metal, { shadow = false })
	local melt =
		Build.ucyl(m, 0.3, 4.6, cf * CF(0, 4.65, 0), Color3.fromRGB(255, 170, 40), M.Neon, { shadow = false })
	Build.light(melt, Color3.fromRGB(255, 140, 40), 20, 2.5)
	Build.emitter(melt, {
		name = "Steam",
		texture = Build.TEX.smoke,
		color = Build.cs(Color3.fromRGB(255, 220, 160), Color3.fromRGB(180, 170, 160)),
		size = Build.ns(1, 3),
		transparency = Build.ns(0.4, 1),
		lifetime = NumberRange.new(1.5, 2.5),
		rate = 4,
		speed = NumberRange.new(2, 3),
		spread = Vector2.new(15, 15),
	})
	for i = 0, 2 do
		local a = i / 3 * 6.28 + 0.5
		Build.cyl(
			m,
			5,
			0.18,
			cf * CF(math.cos(a) * 1.5, 5.6, math.sin(a) * 1.5) * ANG(0, -a, rad(60)),
			METAL,
			M.Metal,
			{ shadow = false }
		)
	end
	local fire = Build.egg(
		m,
		V3(2, 1.4, 2),
		cf * CF(0, 0.7, 0),
		Color3.fromRGB(255, 120, 30),
		M.Neon,
		{ shadow = false, transparency = 0.2 }
	)
	Build.emitter(fire, {
		name = "Fire",
		texture = Build.TEX.fire,
		color = Build.cs(Color3.fromRGB(255, 200, 80), Color3.fromRGB(255, 60, 20)),
		size = Build.ns(1.2, 0.2),
		transparency = Build.ns(0.2, 1),
		lifetime = NumberRange.new(0.4, 0.8),
		rate = 14,
		speed = NumberRange.new(1, 2.5),
		lightEmission = 1,
	})
	local _ = glow
end

B.witch_hut = function(m, x, z, _accent, glow, rng)
	local cf = CF(x, 0, z) * ANG(0, rng:range(0, 6.28), 0)
	for _, s in { -1, 1 } do
		for _, t in { -1, 1 } do
			Build.ucyl(m, 2, 0.5, cf * CF(s * 2, 1, t * 2), WOOD_DARK, M.Wood)
		end
	end
	Build.block(
		m,
		V3(5, 3.6, 5),
		cf * CF(0, 3.8, 0) * ANG(0, 0, rad(4)),
		Color3.fromRGB(110, 90, 70),
		M.WoodPlanks
	)
	Props.cone(
		m,
		cf * CF(0, 5.5, 0) * ANG(rad(-6), 0, rad(5)),
		3.8,
		5,
		6,
		Color3.fromRGB(70, 50, 90),
		M.Fabric
	)
	local win = Build.block(m, V3(1.2, 1.2, 0.2), cf * CF(0, 4, -2.55), glow, M.Neon, { shadow = false })
	Build.light(win, glow, 16, 1.8)
	local cauldron = cf * CF(3.6, 0, -2.4)
	Build.ball(m, 2.2, cauldron * CF(0, 1, 0), Color3.fromRGB(40, 40, 45), M.Metal)
	local brew = Build.ucyl(m, 0.2, 1.9, cauldron * CF(0, 1.8, 0), glow, M.Neon, { shadow = false })
	Build.emitter(brew, {
		name = "Bubbles",
		texture = Build.TEX.sparkles,
		color = Build.cs(glow),
		size = Build.ns(0.5, 0.1),
		lifetime = NumberRange.new(1, 2),
		rate = 6,
		speed = NumberRange.new(1, 2),
		lightEmission = 1,
	})
end

B.crashed_rocket = function(m, x, z, _accent, glow, rng)
	local cf = CF(x, 0, z) * ANG(0, rng:range(0, 6.28), 0)
	local body = cf * CF(0, 2.6, 0) * ANG(rad(-35), 0, 0)
	Build.ucyl(m, 7, 2.6, body, Color3.fromRGB(235, 235, 240), M.Metal)
	for k = 0, 3 do
		Build.ucyl(
			m,
			0.9,
			2.6 - k * 0.6,
			body * CF(0, 4 + k * 0.7, 0),
			if k % 2 == 0 then Color3.fromRGB(220, 50, 50) else Color3.fromRGB(235, 235, 240),
			M.Metal
		)
	end
	for i = 0, 2 do
		Build.wedge(
			m,
			V3(0.2, 2, 1.6),
			body * ANG(0, i / 3 * 6.28, 0) * CF(0, -2.8, -1.6),
			Color3.fromRGB(220, 50, 50),
			M.Metal
		)
	end
	Build.ucyl(
		m,
		0.2,
		1.4,
		body * CF(0, 1, -1.3) * ANG(rad(90), 0, 0),
		Color3.fromRGB(140, 210, 255),
		M.Glass,
		{ shadow = false }
	)
	local smoke = anchorPart(m, body * CF(0, -3.6, 0))
	Build.emitter(smoke, {
		name = "Smoke",
		texture = Build.TEX.smoke,
		color = Build.cs(Color3.fromRGB(120, 120, 130)),
		size = Build.ns(1, 3),
		transparency = Build.ns(0.5, 1),
		lifetime = NumberRange.new(2, 3),
		rate = 3,
		speed = NumberRange.new(1, 2),
	})
	Props.DECOR.crater(
		m,
		x,
		z,
		2.5,
		rng,
		{
			rock = Color3.fromRGB(170, 170, 178),
			rockDark = Color3.fromRGB(120, 120, 130),
			moss = Color3.new(),
			leaves = {},
			trunk = Color3.new(),
			accent = Color3.new(),
			glow = glow,
			flower = {},
		} :: any
	)
end

B.sunken_chest = function(m, x, z, _accent, glow, rng)
	local cf = CF(x, 0, z) * ANG(0, rng:range(0, 6.28), 0)
	Build.block(m, V3(4, 2.2, 2.6), cf * CF(0, 1.1, 0) * ANG(0, 0, rad(6)), WOOD_DARK, M.WoodPlanks)
	Build.cyl(m, 4, 2.6, cf * CF(0, 2.2, 0.5) * ANG(rad(-30), 0, 0), WOOD, M.WoodPlanks)
	for _, s in { -1, 0, 1 } do
		Build.block(m, V3(0.3, 2.4, 2.7), cf * CF(s * 1.5, 1.2, 0), GOLD, M.Metal, { shadow = false })
	end
	for i = 1, 6 do
		Build.cyl(
			m,
			0.15,
			0.6,
			cf * CF(rng:range(-1.4, 1.4), 2.25, rng:range(-0.8, 0.6)) * Build.UPRIGHT,
			GOLD,
			M.Metal,
			{ shadow = false }
		)
		local _ = i
	end
	local glowPart = Build.block(
		m,
		V3(3.6, 0.2, 2.2),
		cf * CF(0, 2.25, 0),
		glow,
		M.Neon,
		{ shadow = false, transparency = 0.3 }
	)
	Build.light(glowPart, GOLD, 16, 2)
	sparkle(glowPart, GOLD, 6, 30)
end

-- Fallback: a golden landmark spire.
local function fallback(m: Model, x: number, z: number, accent: Color3, glow: Color3, _rng: Rng)
	local cf = CF(x, 0, z)
	Build.ucyl(m, 1, 6, cf * CF(0, 0.5, 0), accent, M.Marble)
	Build.block(m, V3(1.2, 8, 1.2), cf * CF(0, 5, 0) * ANG(0, rad(45), 0), GOLD, M.Neon, { shadow = false })
	Build.light(anchorPart(m, cf * CF(0, 6, 0)), glow, 16, 1.5)
end

local KEYWORDS = {
	{ "armory", "armory_crate" },
	{ "crate", "armory_crate" },
	{ "vault", "cheese_vault" },
	{ "totem", "power_totem" },
	{ "cart", "shop_cart" },
	{ "shop", "shop_cart" },
	{ "shrine", "shrine_might" },
	{ "cache", "cheese_cache" },
	{ "camp", "elite_camp" },
	{ "fountain", "crumb_fountain" },
	{ "trap", "mousetrap_field" },
}

function PoiModels.resolve(id: string): string?
	if B[id] then
		return id
	end
	for _, kw in KEYWORDS do
		if string.find(id, kw[1], 1, true) then
			return kw[2]
		end
	end
	return nil
end

function PoiModels.build(
	m: Model,
	id: string,
	x: number,
	z: number,
	accent: Color3,
	glow: Color3,
	rng: Rng,
	entry: any?
)
	local key = PoiModels.resolve(id)
	local fn = if key then B[key] else nil
	if fn then
		fn(m, x, z, accent, glow, rng, entry)
	else
		fallback(m, x, z, accent, glow, rng)
	end
end

PoiModels.KINDS = B

return PoiModels
