--!strict
-- StallModels (iter1, team G): the v5 run-economy world models (V5-PLAN A3-A6).
--
--   StallModels.layout(R, rng, clear) -> Layout      pure placement (ArenaBuilder)
--       Layout = { stalls = {{id, x, z, class = false}} (4-6 at 0.55 R),
--                  classStall = {id = "class", x, z},  (near the centre)
--                  altar = {x, z}, swap = {x, z} }      (just north of the boss pad)
--       clear(x, z, r) -> boolean keeps stalls off POIs / corners.
--   StallModels.stall(parent, x, z, id, color) -> Model     buff stall pad
--   StallModels.classStall(parent, x, z) -> Model           the Class Stall
--   StallModels.altar(parent, x, z) -> Model                Big Cheese Altar
--   StallModels.swap(parent, x, z) -> Model                 Swap Stand
--   StallModels.zone(parent, kind, x, z, r) -> Model        boost zone (rind_mill |
--                                                           whey_spring | golden_glade)
--
-- Every model is anchored and non-colliding (the 2-D sim owns movement), carries
-- attributes Kind / StallId / X / Z, and has a ProximityPrompt the client and
-- RunDirector can find (names in StallModels.PROMPTS; HoldDuration 0, no line of
-- sight, attribute StallId). The prompt only opens a popup (team U); every buy
-- is validated on the server (team M2). Part costs: stall ~22, class stall ~30,
-- altar ~46, swap ~18, zone ~14.

local Build = require(script.Parent.Build)
local Props = require(script.Parent.Props)

local StallModels = {}

StallModels.STALLS_MIN = 4
StallModels.STALLS_MAX = 6
StallModels.RING = 0.55 -- stall ring radius / R
StallModels.ALTAR_OFFSET = 9 -- studs north of the boss pad edge
StallModels.PROMPTS = {
	stall = "StallPad",
	class = "ClassStall",
	altar = "BigCheeseAltar",
	swap = "SwapStand",
	zone = "BoostZone",
}
StallModels.WHEY = Color3.fromRGB(150, 220, 255)
StallModels.RIND = Color3.fromRGB(214, 140, 52)

local M = Enum.Material
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local rgb = Color3.fromRGB
local NOSH = { shadow = false }
local GOLD = rgb(255, 201, 60)

export type Spot = { id: string, x: number, z: number, class: boolean? }
export type Layout = {
	stalls: { Spot },
	classStall: Spot,
	altar: { x: number, z: number },
	swap: { x: number, z: number },
}

function StallModels.layout(
	R: number,
	rng: any,
	clear: (number, number, number) -> boolean,
	padR: number?
): Layout
	local n = math.clamp(math.floor(R / 90), StallModels.STALLS_MIN, StallModels.STALLS_MAX)
	local a0 = rng:range(0, math.pi * 2)
	local ring = R * StallModels.RING
	local stalls = {}
	for i = 1, n do
		local base = a0 + (i - 1) / n * math.pi * 2
		local placed = false
		for k = 0, 23 do
			local da = (if k % 2 == 0 then 1 else -1) * math.floor((k + 1) / 2) * 0.035
			local dr = (if k % 3 == 0 then 0 elseif k % 3 == 1 then 0.06 else -0.06) * R
			local a = base + da
			local x, z = math.cos(a) * (ring + dr), math.sin(a) * (ring + dr)
			if clear(x, z, 9) then
				table.insert(stalls, { id = "stall" .. i, x = x, z = z, class = false })
				placed = true
				break
			end
		end
		if not placed then
			table.insert(
				stalls,
				{ id = "stall" .. i, x = math.cos(base) * ring, z = math.sin(base) * ring, class = false }
			)
		end
	end
	local pad = padR or 14
	local d = pad + StallModels.ALTAR_OFFSET
	local ca = math.rad(35) + rng:range(-0.2, 0.2)
	return {
		stalls = stalls,
		classStall = {
			id = "class",
			x = math.cos(ca) * (pad + 16),
			z = math.sin(ca) * (pad + 16),
			class = true,
		},
		altar = { x = 0, z = -d },
		swap = { x = 9, z = -d - 2 },
	}
end

local function prompt(parent: Instance, name: string, action: string, object: string, id: string)
	local p = Instance.new("ProximityPrompt")
	p.Name = name
	p.ActionText = action
	p.ObjectText = object
	p.HoldDuration = 0
	p.MaxActivationDistance = 12
	p.RequiresLineOfSight = false
	p.KeyboardKeyCode = Enum.KeyCode.E
	p:SetAttribute("StallId", id)
	p.Parent = parent
	return p
end

local function base(parent: Instance, name: string, kind: string, id: string, x: number, z: number): Model
	local m = Instance.new("Model")
	m.Name = name
	m:SetAttribute("Kind", kind)
	m:SetAttribute("StallId", id)
	m:SetAttribute("X", x)
	m:SetAttribute("Z", z)
	m.Parent = parent
	return m
end

-- hexagonal stone pad with a coloured inlay and a thin neon rim
local function pad(m: Model, o: CFrame, r: number, color: Color3)
	for k = 0, 5 do
		local a = k / 6 * math.pi * 2
		Build.block(
			m,
			V3(r * 1.05, 0.3, r * 1.75),
			o * ANG(0, a, 0) * CF(0, 0.15, 0),
			rgb(190, 180, 160),
			M.Slate,
			NOSH
		)
	end
	Build.ucyl(
		m,
		0.34,
		r * 1.5,
		o * CF(0, 0.18, 0),
		color:Lerp(rgb(255, 255, 255), 0.25),
		M.SmoothPlastic,
		NOSH
	)
	Build.ucyl(m, 0.36, r * 0.5, o * CF(0, 0.2, 0), color, M.Neon, NOSH)
end

local function awning(m: Model, o: CFrame, w: number, d: number, h: number, a: Color3, b: Color3)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			Build.ucyl(m, h, 0.35, o * CF(sx * w / 2, h / 2, sz * d / 2), rgb(110, 76, 44), M.Wood)
		end
	end
	local stripes = 5
	for k = 0, stripes - 1 do
		Build.wedge(
			m,
			V3(w / stripes, 1.2, d + 0.6),
			o * CF(-w / 2 + (k + 0.5) * w / stripes, h + 0.6, 0),
			if k % 2 == 0 then a else b,
			M.Fabric,
			NOSH
		)
	end
	-- scalloped front fringe
	for k = 0, stripes - 1 do
		Build.ball(
			m,
			w / stripes * 0.8,
			o * CF(-w / 2 + (k + 0.5) * w / stripes, h - 0.05, -d / 2 - 0.3),
			if k % 2 == 0 then a else b,
			M.Fabric,
			NOSH
		)
	end
end

function StallModels.stall(parent: Instance, x: number, z: number, id: string, color: Color3?): Model
	local m = base(parent, "Stall_" .. id, "stall", id, x, z)
	local c = color or StallModels.WHEY
	local o = CFrame.lookAt(V3(x, 0, z), V3(0, 0, 0))
	pad(m, o, 5, c)
	local back = o * CF(0, 0, 3.4)
	awning(m, back, 6, 3.2, 4.2, c, rgb(250, 244, 230))
	local counter = Build.block(m, V3(5.4, 1.6, 1.4), back * CF(0, 0.8, -1), rgb(160, 110, 60), M.WoodPlanks)
	Build.block(m, V3(5.6, 0.2, 1.6), back * CF(0, 1.7, -1), GOLD, M.SmoothPlastic, NOSH)
	-- whey jugs and a cheese wheel on the counter
	for k, dx in { -1.8, -0.6 } do
		Build.ucyl(
			m,
			1.1,
			0.8,
			back * CF(dx, 2.35, -1),
			StallModels.WHEY,
			M.Glass,
			{ shadow = false, transparency = 0.15 }
		)
		Build.ucyl(m, 0.3, 0.4, back * CF(dx, 3.05, -1), rgb(240, 240, 250), M.SmoothPlastic, NOSH)
		local _ = k
	end
	Build.cyl(
		m,
		0.7,
		1.6,
		back * CF(1.4, 2.6, -1) * ANG(0, 0, math.pi / 2),
		rgb(255, 210, 80),
		M.SmoothPlastic,
		NOSH
	)
	local sign = Build.block(m, V3(3, 1, 0.2), back * CF(0, 5.6, -1.7), rgb(120, 82, 46), M.WoodPlanks, NOSH)
	Build.ball(m, 0.8, back * CF(0, 6.4, -1.7), c, M.Neon, NOSH)
	local _ = sign
	prompt(counter, StallModels.PROMPTS.stall, "Buy buff", "Whey Stall", id)
	return m
end

function StallModels.classStall(parent: Instance, x: number, z: number): Model
	local m = base(parent, "ClassStall", "class", "class", x, z)
	local o = CFrame.lookAt(V3(x, 0, z), V3(0, 0, 0))
	pad(m, o, 6, rgb(179, 107, 255))
	local back = o * CF(0, 0, 4)
	awning(m, back, 8, 3.6, 5, rgb(179, 107, 255), GOLD)
	local counter = Build.block(m, V3(7, 1.8, 1.6), back * CF(0, 0.9, -1.2), rgb(90, 60, 110), M.WoodPlanks)
	Build.block(m, V3(7.2, 0.2, 1.8), back * CF(0, 1.9, -1.2), GOLD, M.Metal, NOSH)
	-- seven class banners on a rail (one per elephant class)
	local cols = {
		rgb(255, 201, 60),
		rgb(90, 185, 255),
		rgb(110, 210, 90),
		rgb(235, 80, 70),
		rgb(250, 240, 220),
		rgb(150, 235, 90),
		rgb(190, 120, 240),
	}
	Build.cyl(m, 7.6, 0.2, back * CF(0, 4.6, -1.9), rgb(110, 76, 44), M.Wood, NOSH)
	for k, col in cols do
		Build.block(m, V3(0.8, 1.6, 0.1), back * CF(-3.3 + (k - 1) * 1.1, 3.7, -1.9), col, M.Fabric, NOSH)
	end
	-- a spinning trophy elephant head (the class emblem)
	local head = Build.ball(m, 1.8, back * CF(0, 3.2, -1.2), rgb(158, 160, 172), M.SmoothPlastic, NOSH)
	for _, s in { -1, 1 } do
		Build.egg(
			m,
			V3(1.4, 1.6, 0.2),
			back * CF(s * 1.1, 3.3, -1.1),
			rgb(236, 170, 182),
			M.SmoothPlastic,
			NOSH
		)
	end
	Build.light(head, rgb(200, 150, 255), 14, 1.2)
	prompt(counter, StallModels.PROMPTS.class, "Class buff", "Class Stall", "class")
	return m
end

function StallModels.altar(parent: Instance, x: number, z: number): Model
	local m = base(parent, "BigCheeseAltar", "altar", "altar", x, z)
	local o = CF(x, 0, z)
	-- three stepped marble tiers with gold trim
	for i, r in { 7, 5.6, 4.2 } do
		local y = (i - 1) * 0.7
		Build.ucyl(m, 0.7, r * 2, o * CF(0, y + 0.35, 0), rgb(232, 224, 205), M.Marble)
		Build.ucyl(m, 0.12, r * 2 + 0.2, o * CF(0, y + 0.72, 0), GOLD, M.Metal, NOSH)
	end
	-- the Big Cheese: a giant wheel with a wedge cut out and glowing holes
	local top = o * CF(0, 2.1, 0)
	local wheel =
		Build.cyl(m, 2.6, 6, top * CF(0, 1.3, 0) * ANG(0, 0, math.pi / 2), rgb(255, 205, 70), M.SmoothPlastic)
	Build.cyl(
		m,
		2.7,
		5.2,
		top * CF(0, 1.3, 0) * ANG(0, 0, math.pi / 2),
		rgb(255, 225, 120),
		M.SmoothPlastic,
		NOSH
	)
	Build.wedge(
		m,
		V3(1.6, 2.8, 3),
		top * CF(0, 1.3, -1.6) * ANG(0, math.pi, 0),
		rgb(255, 160, 40),
		M.Neon,
		NOSH
	)
	for k = 0, 4 do
		local a = k / 5 * math.pi * 2
		Build.ball(
			m,
			0.7,
			top * CF(math.cos(a) * 2.2, 2.62, math.sin(a) * 2.2),
			rgb(230, 150, 30),
			M.Neon,
			NOSH
		)
	end
	-- four rind pillars with floating cheese crystals
	for k = 0, 3 do
		local a = (k + 0.5) / 4 * math.pi * 2
		local p = o * CF(math.cos(a) * 6.2, 0, math.sin(a) * 6.2)
		Build.ucyl(m, 5, 1.1, p * CF(0, 2.5, 0), rgb(214, 140, 52), M.SmoothPlastic)
		Build.ucyl(m, 0.3, 1.5, p * CF(0, 5.1, 0), GOLD, M.Metal, NOSH)
		Build.wedge(m, V3(0.7, 1.2, 0.7), p * CF(0, 6.1, 0) * ANG(0, a, 0), GOLD, M.Neon, NOSH)
	end
	-- rune ring on the floor
	for k = 0, 15 do
		local a = k / 16 * math.pi * 2
		local p = V3(x + math.cos(a) * 7.6, 0.1, z + math.sin(a) * 7.6)
		Build.block(
			m,
			V3(if k % 2 == 0 then 1.4 else 0.5, 0.05, 0.3),
			CFrame.lookAt(p, V3(x, 0.1, z)) * ANG(0, math.pi / 2, 0),
			GOLD,
			M.Neon,
			NOSH
		)
	end
	Build.light(wheel, rgb(255, 200, 90), 24, 1.6)
	Build.emitter(wheel, {
		name = "Glow",
		texture = Build.TEX.sparkles,
		color = Build.cs(GOLD, rgb(255, 255, 255)),
		size = Build.ns(0.5, 0),
		transparency = Build.ns(0.1, 1),
		lifetime = NumberRange.new(1.2, 2),
		rate = 8,
		speed = NumberRange.new(1, 3),
		lightEmission = 1,
	})
	prompt(wheel, StallModels.PROMPTS.altar, "Ultimates", "Big Cheese Altar", "altar")
	return m
end

function StallModels.swap(parent: Instance, x: number, z: number): Model
	local m = base(parent, "SwapStand", "swap", "swap", x, z)
	local o = CF(x, 0, z)
	Build.ucyl(m, 0.3, 4.6, o * CF(0, 0.15, 0), rgb(190, 180, 160), M.Slate, NOSH)
	Build.ucyl(m, 3.2, 0.5, o * CF(0, 1.9, 0), rgb(160, 120, 60), M.Metal)
	local beam = Build.block(m, V3(4.4, 0.25, 0.25), o * CF(0, 3.5, 0) * ANG(0, 0, 0.12), GOLD, M.Metal)
	-- two pans on chains: rinds (left) and whey (right)
	for _, s in { -1, 1 } do
		local hang = o * CF(s * 2.1, 3.5 - s * 0.26, 0)
		Build.cyl(
			m,
			1.6,
			0.08,
			hang * CF(0, -0.8, 0) * ANG(0, 0, math.pi / 2),
			rgb(120, 120, 120),
			M.Metal,
			NOSH
		)
		local pan = hang * CF(0, -1.7, 0)
		Build.ucyl(m, 0.2, 1.8, pan, rgb(200, 160, 70), M.Metal, NOSH)
		if s < 0 then
			Props.cheeseWedge(m, pan * CF(0, 0.3, 0), 1, 0.6, nil)
		else
			Build.ball(
				m,
				0.9,
				pan * CF(0, 0.45, 0),
				StallModels.WHEY,
				M.Glass,
				{ shadow = false, transparency = 0.1 }
			)
		end
	end
	Build.ball(m, 0.6, o * CF(0, 3.9, 0), GOLD, M.Neon, NOSH)
	prompt(beam, StallModels.PROMPTS.swap, "Swap rinds / whey", "Swap Stand", "swap")
	return m
end

local ZONE = {
	rind_mill = { color = StallModels.RIND, name = "Rind Mill" },
	whey_spring = { color = StallModels.WHEY, name = "Whey Spring" },
	golden_glade = { color = GOLD, name = "Golden Glade" },
}
StallModels.ZONES = ZONE

function StallModels.zone(parent: Instance, kind: string, x: number, z: number, r: number?): Model
	local def = ZONE[kind] or ZONE.golden_glade
	local m = base(parent, "Zone_" .. kind, "zone", kind, x, z)
	local rr = r or 10
	local o = CF(x, 0, z)
	Build.ucyl(
		m,
		0.12,
		rr * 2,
		o * CF(0, 0.07, 0),
		def.color,
		M.ForceField,
		{ shadow = false, transparency = 0.55 }
	)
	for k = 0, 11 do
		local a = k / 12 * math.pi * 2
		local p = V3(x + math.cos(a) * rr, 0.15, z + math.sin(a) * rr)
		Build.block(
			m,
			V3(2 * math.pi * rr / 12 * 0.55, 0.12, 0.45),
			CFrame.lookAt(p, V3(x, 0.15, z)) * ANG(0, math.pi / 2, 0),
			def.color,
			M.Neon,
			NOSH
		)
	end
	-- the centrepiece: a mill wheel, a spring basin or a golden sapling
	if kind == "rind_mill" then
		Build.block(m, V3(2.4, 4, 2.4), o * CF(0, 2, 0), rgb(150, 110, 70), M.WoodPlanks)
		for k = 0, 3 do
			Build.block(
				m,
				V3(0.4, 5, 0.9),
				o * CF(0, 4.6, -1.3) * ANG(0, 0, k * math.pi / 4),
				rgb(230, 220, 200),
				M.Fabric,
				NOSH
			)
		end
	elseif kind == "whey_spring" then
		Build.ucyl(m, 1, 4, o * CF(0, 0.5, 0), rgb(200, 200, 210), M.Marble)
		Build.ucyl(
			m,
			0.2,
			3.2,
			o * CF(0, 1.05, 0),
			def.color,
			M.Glass,
			{ shadow = false, transparency = 0.2 }
		)
		Build.ball(m, 1, o * CF(0, 1.8, 0), def.color, M.Neon, NOSH)
	else
		Build.ucyl(m, 3, 0.5, o * CF(0, 1.5, 0), rgb(120, 82, 46), M.Wood)
		Build.ball(m, 3, o * CF(0, 3.6, 0), GOLD, M.SmoothPlastic)
		Build.ball(m, 1.2, o * CF(0.9, 4.4, 0.4), rgb(255, 230, 140), M.Neon, NOSH)
	end
	local flag = Build.block(
		m,
		V3(0.2, 0.2, 0.2),
		o * CF(0, 6, 0),
		def.color,
		M.SmoothPlastic,
		{ transparency = 1, shadow = false }
	)
	prompt(flag, StallModels.PROMPTS.zone, "Capture", def.name, kind).Enabled = false -- capture is by standing in it
	return m
end

return StallModels
