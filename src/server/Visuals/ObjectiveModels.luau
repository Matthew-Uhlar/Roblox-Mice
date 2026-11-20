--!strict
-- ObjectiveModels (iter4, team G): models for the new objective POIs and the
-- miniboss camps (docs/iter/4/PLAN.md). PoiModels.build dispatches here for:
--
--   caravan        an escort cheese wagon (two wheels, canopy, cargo, lantern)
--   beacon         a capture beacon (stone pylon + brazier crystal); state via
--                  ObjectiveModels.setBeacon(model, color?) (nil = unlit)
--   rescue_cage    a cage of bars round a trapped (desaturated) elephant;
--                  ObjectiveModels.setFreed(model) drops the bars and wakes it
--   miniboss_camp  a Rat Warlord camp: palisade stakes, a war tent, bonfire,
--                  banners and a weapon rack (the miniboss itself is drawn by the
--                  client HordeRenderer like champions)
--   ObjectiveModels.lite(m, x, z, glow)   a ~4-part stand-in used when the arena's
--                  POI part budget is spent (ArenaBuilder.POI_BUDGET)
--
-- All parts anchored and non-colliding (the sim owns movement). Each model's
-- PrimaryPart is "Base" at the ground point, so M2 can PivotTo the caravan along
-- its route, and the model keeps attributes Kind / X / Z (set by ArenaBuilder).

local Build = require(script.Parent.Build)
local Props = require(script.Parent.Props)

local ObjectiveModels = {}

local M = Enum.Material
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local rad = math.rad
local rgb = Color3.fromRGB
local NOSH = { shadow = false }
local GOLD = rgb(255, 201, 60)
local WOOD = rgb(130, 90, 55)
local WOOD_DARK = rgb(90, 60, 35)

local function base(m: Model, x: number, z: number): BasePart
	local b = Build.block(m, V3(1, 0.2, 1), CF(x, 0.1, z), Color3.new(1, 1, 1), M.SmoothPlastic, {
		name = "Base",
		transparency = 1,
		shadow = false,
	})
	m.PrimaryPart = b
	return b
end

local B: { [string]: (m: Model, x: number, z: number, accent: Color3, glow: Color3, rng: any) -> () } = {}

B.caravan = function(m, x, z, accent, glow, _rng)
	base(m, x, z)
	local o = CF(x, 0, z)
	-- wagon bed and sides
	Build.block(m, V3(5, 0.5, 8), o * CF(0, 1.6, 0), WOOD, M.WoodPlanks)
	for _, s in { -1, 1 } do
		Build.block(m, V3(0.3, 1.2, 8), o * CF(s * 2.4, 2.4, 0), WOOD_DARK, M.WoodPlanks)
		-- wheels with hubs
		for _, e in { -1, 1 } do
			Build.cyl(m, 0.4, 2.8, o * CF(s * 2.75, 1.4, e * 2.6), WOOD_DARK, M.Wood)
			Build.cyl(m, 0.5, 0.7, o * CF(s * 2.95, 1.4, e * 2.6), GOLD, M.Metal, NOSH)
		end
	end
	Build.block(m, V3(5, 1.2, 0.3), o * CF(0, 2.4, 3.9), WOOD_DARK, M.WoodPlanks)
	-- canopy hoops + striped cloth
	for k = 0, 2 do
		local zz = -2.6 + k * 2.6
		Build.egg(m, V3(5, 3.4, 0.25), o * CF(0, 3.4, zz), rgb(250, 240, 220), M.Fabric)
	end
	Build.egg(m, V3(4.8, 3.2, 6.4), o * CF(0, 3.3, -0.2), accent:Lerp(rgb(255, 255, 255), 0.35), M.Fabric)
	-- cargo: cheese wheels peeking out the back, a lantern and the tongue
	for k, dx in { -1.2, 1.2 } do
		Build.cyl(m, 0.9, 2, o * CF(dx, 2.5, 3.2) * ANG(0, rad(90), 0), rgb(255, 205, 70), M.SmoothPlastic)
		local _ = k
	end
	Build.block(m, V3(0.3, 0.3, 4), o * CF(0, 1.3, -6), WOOD_DARK, M.Wood)
	local lantern = Build.block(m, V3(0.6, 0.8, 0.6), o * CF(0, 4.9, -3.6), glow, M.Neon, NOSH)
	Build.light(lantern, glow, 16, 1.4)
	-- an escort flag on a pole
	Build.ucyl(m, 4, 0.2, o * CF(2.2, 5, 3.4), WOOD_DARK, M.Wood)
	Build.block(m, V3(0.08, 1.2, 1.8), o * CF(2.2, 6.4, 2.5), accent, M.Fabric, NOSH)
end

B.beacon = function(m, x, z, accent, glow, _rng)
	base(m, x, z)
	local o = CF(x, 0, z)
	Build.ucyl(m, 0.6, 7, o * CF(0, 0.3, 0), rgb(170, 160, 145), M.Slate)
	-- a tapered stone pylon with gold bands
	for k, d in { 2.6, 2.2, 1.8 } do
		Build.block(
			m,
			V3(d, 2.4, d),
			o * CF(0, 1.8 + (k - 1) * 2.4, 0) * ANG(0, rad(45), 0),
			rgb(190, 180, 165),
			M.Slate
		)
		Build.block(
			m,
			V3(d + 0.15, 0.3, d + 0.15),
			o * CF(0, 0.7 + k * 2.4, 0) * ANG(0, rad(45), 0),
			GOLD,
			M.Metal,
			NOSH
		)
	end
	-- the brazier and its crystal (tinted by setBeacon)
	Build.ucyl(m, 0.6, 2.4, o * CF(0, 8.6, 0), rgb(80, 75, 70), M.Metal)
	local crystal = Build.block(
		m,
		V3(1.2, 2.2, 1.2),
		o * CF(0, 10.2, 0) * ANG(0, rad(45), rad(10)),
		rgb(120, 120, 130),
		M.Glass,
		{
			name = "Crystal",
			transparency = 0.2,
		}
	)
	local light = Build.light(crystal, glow, 22, 0)
	light.Name = "BeaconLight"
	-- the ring the squad stands in
	for k = 0, 11 do
		local a = k / 12 * math.pi * 2
		local p = V3(x + math.cos(a) * 7, 0.1, z + math.sin(a) * 7)
		local seg = Build.block(
			m,
			V3(2.4, 0.1, 0.4),
			CFrame.lookAt(p, V3(x, 0.1, z)) * ANG(0, math.pi / 2, 0),
			accent,
			M.Neon,
			{
				shadow = false,
				name = "BeaconRing",
				transparency = 0.5,
			}
		)
		local _ = seg
	end
end

function ObjectiveModels.setBeacon(m: Instance, color: Color3?)
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "Crystal" then
			d.Color = color or rgb(120, 120, 130)
			d.Material = if color then M.Neon else M.Glass
		elseif d:IsA("BasePart") and d.Name == "BeaconRing" then
			if color then
				d.Color = color
			end
			d.Transparency = if color then 0.1 else 0.5
		elseif d:IsA("PointLight") and d.Name == "BeaconLight" then
			d.Brightness = if color then 2 else 0
			if color then
				d.Color = color
			end
		end
	end
	m:SetAttribute("Lit", color ~= nil)
end

B.rescue_cage = function(m, x, z, accent, _glow, _rng)
	base(m, x, z)
	local o = CF(x, 0, z)
	Build.ucyl(m, 0.5, 8, o * CF(0, 0.25, 0), rgb(110, 100, 90), M.Slate)
	-- the trapped elephant: a desaturated, slumped mini elephant (4 parts)
	local grey = rgb(150, 150, 155)
	Build.egg(m, V3(3.4, 2.6, 4), o * CF(0, 1.8, 0.2), grey, M.SmoothPlastic, { name = "Captive" })
	Build.ball(m, 2.6, o * CF(0, 2.8, -1.8), grey, M.SmoothPlastic, { name = "Captive" })
	for _, s in { -1, 1 } do
		Build.egg(
			m,
			V3(2, 2.2, 0.25),
			o * CF(s * 1.5, 2.8, -1.6) * ANG(0, rad(s * -30), 0),
			grey,
			M.SmoothPlastic,
			{ name = "Captive" }
		)
	end
	-- bars, top ring and a padlock
	for k = 0, 9 do
		local a = k / 10 * math.pi * 2
		Build.ucyl(m, 6, 0.3, o * CF(math.cos(a) * 3.4, 3.25, math.sin(a) * 3.4), rgb(70, 70, 78), M.Metal, {
			name = "Bar",
		})
	end
	Build.cyl(
		m,
		0.4,
		7.4,
		o * CF(0, 6.3, 0) * ANG(0, 0, math.pi / 2),
		rgb(70, 70, 78),
		M.Metal,
		{ name = "Bar" }
	)
	Build.block(m, V3(0.9, 1, 0.4), o * CF(0, 2.6, -3.5), GOLD, M.Metal, { name = "Bar" })
	-- a call-for-help marker over it
	Build.ball(m, 1, o * CF(0, 8, 0), accent, M.Neon, NOSH)
end

function ObjectiveModels.setFreed(m: Instance)
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			if d.Name == "Bar" then
				d.Transparency = 1
			elseif d.Name == "Captive" then
				d.Color = rgb(158, 160, 172)
			end
		end
	end
	m:SetAttribute("Freed", true)
end

B.miniboss_camp = function(m, x, z, accent, glow, rng)
	base(m, x, z)
	local o = CF(x, 0, z)
	Build.ucyl(m, 0.12, 22, o * CF(0, 0.07, 0), rgb(110, 85, 60), M.Ground, NOSH)
	-- palisade of sharpened stakes with a gap facing the centre
	local gap = math.atan2(-z, -x)
	for k = 0, 17 do
		local a = k / 18 * math.pi * 2
		if math.abs((a - gap + math.pi) % (2 * math.pi) - math.pi) > 0.45 then
			local h = rng:range(3, 4.5)
			local p = o * CF(math.cos(a) * 11, h / 2, math.sin(a) * 11)
			Build.ucyl(
				m,
				h,
				0.6,
				p * ANG(rng:range(-0.12, 0.12), 0, rng:range(-0.12, 0.12)),
				WOOD_DARK,
				M.Wood
			)
		end
	end
	-- the war tent
	local t = o * CF(math.cos(gap + math.pi) * 5, 0, math.sin(gap + math.pi) * 5)
	Build.wedge(
		m,
		V3(6, 4, 3),
		t * CF(0, 2, -1.5) * ANG(0, 0, 0),
		accent:Lerp(rgb(80, 40, 30), 0.4),
		M.Fabric
	)
	Build.wedge(
		m,
		V3(6, 4, 3),
		t * CF(0, 2, 1.5) * ANG(0, math.pi, 0),
		accent:Lerp(rgb(80, 40, 30), 0.5),
		M.Fabric
	)
	Build.ucyl(m, 5.5, 0.3, t * CF(0, 2.75, 0), WOOD_DARK, M.Wood)
	-- bonfire
	Build.ucyl(m, 0.5, 3, o * CF(0, 0.25, 0), rgb(90, 85, 80), M.Slate)
	local fire = Build.egg(m, V3(1.6, 2.2, 1.6), o * CF(0, 1.4, 0), rgb(255, 140, 40), M.Neon, NOSH)
	Build.light(fire, rgb(255, 150, 60), 22, 1.8)
	Build.emitter(fire, {
		name = "Fire",
		texture = Build.TEX.fire,
		color = Build.cs(rgb(255, 200, 80), rgb(255, 80, 30)),
		size = Build.ns(1.4, 0.2),
		transparency = Build.ns(0.2, 1),
		lifetime = NumberRange.new(0.5, 0.9),
		rate = 12,
		speed = NumberRange.new(2, 4),
		lightEmission = 1,
	})
	-- two war banners and a weapon rack
	for _, s in { -1, 1 } do
		local bp = o * CF(math.cos(gap + s * 0.6) * 10.5, 0, math.sin(gap + s * 0.6) * 10.5)
		Props.banner(m, bp, accent, 8)
	end
	local rack = o * CF(math.cos(gap + math.pi / 2) * 7, 0, math.sin(gap + math.pi / 2) * 7)
	Build.block(m, V3(3, 0.3, 0.3), rack * CF(0, 2, 0), WOOD_DARK, M.Wood)
	for k = -1, 1 do
		Build.block(
			m,
			V3(0.15, 2.8, 0.15),
			rack * CF(k * 0.9, 1.7, 0) * ANG(0, 0, rad(k * 8)),
			rgb(200, 205, 215),
			M.Metal
		)
	end
	-- a cheese-rind trophy pile
	Props.cheeseWedge(
		m,
		o * CF(math.cos(gap - math.pi / 2) * 6, 0.3, math.sin(gap - math.pi / 2) * 6),
		2.5,
		1.2,
		rng
	)
end

function ObjectiveModels.lite(m: Model, x: number, z: number, glow: Color3)
	base(m, x, z)
	local o = CF(x, 0, z)
	Build.ucyl(m, 0.3, 6, o * CF(0, 0.15, 0), rgb(180, 170, 155), M.Slate, NOSH)
	Build.ucyl(m, 0.32, 3, o * CF(0, 0.17, 0), glow, M.Neon, NOSH)
	Build.block(
		m,
		V3(1, 3.5, 1),
		o * CF(0, 1.9, 0) * ANG(0, rad(45), 0),
		glow:Lerp(rgb(255, 255, 255), 0.3),
		M.SmoothPlastic
	)
end

ObjectiveModels.KINDS = B

function ObjectiveModels.has(id: string): boolean
	return B[id] ~= nil
end

function ObjectiveModels.build(
	m: Model,
	id: string,
	x: number,
	z: number,
	accent: Color3,
	glow: Color3,
	rng: any
): boolean
	local fn = B[id]
	if not fn then
		return false
	end
	fn(m, x, z, accent, glow, rng)
	return true
end

return ObjectiveModels
