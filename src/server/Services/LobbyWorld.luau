--!strict
-- LobbyWorld (R4 Graphics): the "Herd Sanctuary" lobby island (GDD-v2 §6).
--
--   LobbyWorld.build(center?: Vector3) -> {
--       spawn: SpawnLocation, readyPad: BasePart, squadPads: {[1..4] = BasePart},
--       statusLabel: TextLabel, model: Model, center: Vector3 }
--   Builds once (a second call returns the same parts). LobbyService (R1) calls it
--   instead of building its own pad: recolour `readyPad` for the ready state and
--   write `statusLabel.Text`. Default centre = LobbyService.CENTER (0, 0, -400).
--
-- Terrain island (grass, flat at Y = 0 inside the plaza ring) with a cheese plaza
-- (Sandstone tinted cheese-gold by the lobby lighting preset), the ready pad in
-- the middle (radius 10, the bots stand on a ring of 12 around it), 4 squad pads
-- with banners on the diagonals, a class showcase podium with a statue of every
-- class (BotModel showcase), the TRUNKFALL sign, lamp posts, gardens, a rim of
-- hills with trees and water beyond, and an invisible wall ring at 44 studs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Visuals = script.Parent.Parent:WaitForChild("Visuals")
local Build = require(Visuals:WaitForChild("Build")) :: any
local Props = require(Visuals:WaitForChild("Props")) :: any
local Terra = require(Visuals:WaitForChild("Terra")) :: any
local BotModel = require(Visuals:WaitForChild("BotModel")) :: any
local AssetLoader = require(Visuals:WaitForChild("AssetLoader")) :: any

local LobbyWorld = {}

LobbyWorld.NAME = "LobbyWorld"
LobbyWorld.DEFAULT_CENTER = Vector3.new(0, 0, -400)
LobbyWorld.WALL_RADIUS = 44
LobbyWorld.READY_RADIUS = 10

local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local M = Enum.Material
local rgb = Color3.fromRGB

local GOLD = rgb(255, 201, 60)
local RIND = rgb(214, 120, 40)

local function optional(path: { string }): any
	local ok, mod = pcall(function()
		local cur: Instance = ReplicatedStorage:WaitForChild("Shared")
		for _, seg in path do
			local nxt = cur:FindFirstChild(seg)
			if not nxt then
				return nil
			end
			cur = nxt
		end
		return if cur:IsA("ModuleScript") then require(cur) :: any else nil
	end)
	return if ok then mod else nil
end

local Classes: any = optional({ "Config", "Classes" })
local Squads: any = optional({ "Util", "Squads" })
local RngMod: any = optional({ "Util", "Rng" })

local built: any = nil

local PAL = {
	rock = rgb(160, 150, 135),
	rockDark = rgb(115, 108, 98),
	moss = rgb(110, 170, 70),
	leaves = { rgb(86, 168, 68), rgb(118, 190, 80), rgb(150, 210, 95) },
	trunk = rgb(120, 82, 50),
	accent = GOLD,
	glow = rgb(255, 220, 130),
	flower = { rgb(255, 255, 255), rgb(255, 210, 60), rgb(255, 130, 170), rgb(170, 140, 255) },
}

local function squadColor(i: number): Color3
	local s = Squads and type(Squads.get) == "function" and Squads.get(i)
	return Build.rgb(s and s.color, ({ rgb(255, 200, 60), rgb(245, 240, 220), rgb(80, 150, 255), rgb(235, 70, 60) })[i])
end

local function squadName(i: number): string
	local s = Squads and type(Squads.get) == "function" and Squads.get(i)
	return if s and type(s.name) == "string" then s.name else ("Squad " .. i)
end

local function signText(part: BasePart, face: Enum.NormalId, title: string, sub: string?): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = part
	local t = Instance.new("TextLabel")
	t.Name = "Title"
	t.Size = UDim2.fromScale(1, if sub then 0.55 else 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.TextColor3 = rgb(255, 214, 102)
	t.TextStrokeTransparency = 0.2
	t.TextStrokeColor3 = rgb(91, 58, 30)
	t.Text = title
	t.Parent = gui
	local s = Instance.new("TextLabel")
	s.Name = "Status"
	s.Position = UDim2.fromScale(0, 0.55)
	s.Size = UDim2.fromScale(1, 0.45)
	s.BackgroundTransparency = 1
	s.Font = Enum.Font.FredokaOne
	s.TextScaled = true
	s.TextColor3 = Color3.new(1, 1, 1)
	s.TextStrokeTransparency = 0.3
	s.Text = sub or ""
	s.Visible = sub ~= nil
	s.Parent = gui
	return s
end

local function lamp(m: Instance, cf: CFrame)
	Build.ucyl(m, 0.4, 1.4, cf * CF(0, 0.2, 0), rgb(70, 70, 76), M.Slate)
	Build.ucyl(m, 6, 0.4, cf * CF(0, 3.2, 0), rgb(60, 55, 52), M.Metal)
	Build.cyl(m, 1.6, 0.2, cf * CF(0.6, 6, 0), rgb(60, 55, 52), M.Metal)
	local glass = Build.block(m, V3(0.9, 1.1, 0.9), cf * CF(1.3, 5.3, 0), rgb(255, 225, 150), M.Neon, { shadow = false })
	Build.wedge(m, V3(1.2, 0.5, 1.2), cf * CF(1.3, 6.1, 0), rgb(60, 55, 52), M.Metal)
	Build.light(glass, rgb(255, 210, 140), 18, 1.4, true)
end

function LobbyWorld.build(center: Vector3?): any
	if built and built.model and built.model.Parent then
		return built
	end
	local c = center or LobbyWorld.DEFAULT_CENTER
	local o = CF(c)
	local rng = if RngMod then RngMod.new(4242) else nil

	local model = Instance.new("Model")
	model.Name = LobbyWorld.NAME
	pcall(AssetLoader.preload) -- generated meshes (if any) for the client renderers

	-- Lighting first (also tints the terrain materials used below).
	local ls = script.Parent:FindFirstChild("LightingService")
	if ls and ls:IsA("ModuleScript") then
		local ok, mod = pcall(require, ls)
		if ok and type(mod) == "table" and type((mod :: any).apply) == "function" then
			pcall((mod :: any).apply, "lobby")
		end
	end

	-- Terrain island ------------------------------------------------------------------
	Terra.clearBox(c + V3(0, 30, 0), V3(300, 120, 300))
	Terra.cylinder(o * CF(0, -12, 0), 20, 112, M.Rock)
	Terra.cylinder(o * CF(0, -6, 0), 10, 140, M.Air)
	Terra.cylinder(o * CF(0, -8, 0), 4, 140, M.Sand)
	Terra.cylinder(o * CF(0, -4.5, 0), 5, 140, M.Water)
	Terra.cylinder(o * CF(0, -4, 0), 8, 100, M.Sand)
	Terra.cylinder(o * CF(0, -2, 0), 4, 96, M.Grass)
	Terra.paint(c.X, c.Z, 38, M.Sandstone)
	for i = 0, 3 do
		local a = math.rad(45 + i * 90)
		for k = 0, 8 do
			local d = 40 + k * 4
			Terra.paint(c.X + math.cos(a) * d, c.Z + math.sin(a) * d, 3, M.Ground)
		end
	end
	-- rim hills (outside the wall ring)
	for i = 0, 23 do
		local a = i / 24 * math.pi * 2
		local d = 70 + (if rng then rng:range(-6, 8) else 0)
		local r = 14 + (if rng then rng:range(-3, 6) else 0)
		Terra.ball(c + V3(math.cos(a) * d, -r * 0.45, math.sin(a) * d), r, M.Grass)
	end
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2 + 0.2
		Terra.ball(c + V3(math.cos(a) * 78, 2, math.sin(a) * 78), 9, M.Rock)
	end

	-- Plaza ---------------------------------------------------------------------------
	-- Safety floor (invisible) so the lobby works even without terrain.
	Build.ucyl(model, 2, 100, o * CF(0, -1.05, 0), rgb(255, 214, 102), M.SmoothPlastic, {
		name = "Floor",
		collide = true,
		transparency = if Terra.ok() then 1 else 0,
		shadow = false,
	})
	local plaza = Build.model(model, "Plaza")
	for i, r in { 36, 30.5, 22 } do
		local col = ({ RIND, GOLD, rgb(240, 190, 80) })[i]
		Build.ucyl(plaza, 0.12 + i * 0.02, r * 2, o * CF(0, 0.05 + i * 0.02, 0), col, if i == 2 then M.Marble else M.Sandstone, {
			shadow = false,
		})
	end
	-- cheese holes inlaid in the plaza
	if rng then
		for _ = 1, 22 do
			local a, d = rng:range(0, 6.28), rng:range(13, 29)
			local s = rng:range(1, 2.4)
			Build.ucyl(plaza, 0.06, s, o * CF(math.cos(a) * d, 0.13, math.sin(a) * d), Props.HOLE, M.SmoothPlastic, { shadow = false })
		end
	end
	-- brass compass inlay
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		local p = c + V3(math.cos(a) * 16, 0.16, math.sin(a) * 16)
		Build.block(plaza, V3(if i % 2 == 0 then 6 else 3, 0.05, 0.4), CFrame.lookAt(p, c + V3(0, 0.16, 0)), rgb(200, 150, 60), M.Metal, {
			shadow = false,
		})
	end

	-- Ready pad (LobbyService recolours it)
	Build.ucyl(model, 0.3, LobbyWorld.READY_RADIUS * 2 + 2, o * CF(0, 0.16, 0), rgb(110, 80, 50), M.Wood, { shadow = false })
	local readyPad = Build.ucyl(model, 0.32, LobbyWorld.READY_RADIUS * 2, o * CF(0, 0.2, 0), rgb(120, 120, 120), M.Neon, {
		name = "ReadyCircle",
		shadow = false,
	})
	Build.ucyl(model, 0.34, LobbyWorld.READY_RADIUS * 1.2, o * CF(0, 0.22, 0), GOLD, M.Marble, { shadow = false, name = "ReadyEmblem" })
	Props.cheeseWedge(model, o * CF(0, 0.3, 1.5), 6, 0.35, rng)
	Build.emitter(readyPad, {
		name = "ReadyGlow",
		texture = Build.TEX.sparkles,
		color = Build.cs(GOLD, Color3.new(1, 1, 1)),
		size = Build.ns(0.5, 0),
		lifetime = NumberRange.new(1.2, 2),
		rate = 6,
		speed = NumberRange.new(1.5, 3),
		lightEmission = 1,
		shape = Enum.ParticleEmitterShape.Cylinder,
		shapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
	})

	-- Squad pads on the diagonals, banners behind them
	local squadPads = {}
	for i = 1, 4 do
		local a = math.rad(({ 225, 315, 45, 135 })[i])
		local dir = V3(math.cos(a), 0, math.sin(a))
		local p = c + dir * 25
		local col = squadColor(i)
		local pm = Build.model(model, "SquadPad" .. i)
		pm:SetAttribute("Squad", i)
		Build.ucyl(pm, 0.4, 13, CF(p) * CF(0, 0.2, 0), rgb(90, 85, 80), M.Slate, { shadow = false })
		local pad = Build.ucyl(pm, 0.44, 11, CF(p) * CF(0, 0.24, 0), col, M.Neon, {
			name = "Pad",
			transparency = 0.25,
			shadow = false,
		})
		pad:SetAttribute("Squad", i)
		squadPads[i] = pad
		for _, s in { -1, 1 } do
			local side = V3(-dir.Z, 0, dir.X)
			local bp = p + dir * 7 + side * s * 4
			Props.banner(pm, CFrame.lookAt(bp, bp - dir), col, 9)
		end
		local plate = Build.block(pm, V3(6, 1.4, 0.3), CFrame.lookAt(p + dir * 7 + V3(0, 1, 0), p + V3(0, 1, 0)), rgb(110, 76, 44), M.Wood)
		signText(plate, Enum.NormalId.Front, squadName(i))
	end

	-- Class showcase podium (north side, facing the plaza)
	local podium = Build.model(model, "ClassShowcase")
	local ids = if Classes and type(Classes.ORDER) == "table" then Classes.ORDER else { "elephante" }
	local n = #ids
	Build.block(podium, V3(64, 1, 12), o * CF(0, 0.5, -40), rgb(200, 190, 170), M.Marble)
	Build.block(podium, V3(60, 1, 9), o * CF(0, 1.5, -41), rgb(225, 215, 195), M.Marble)
	Build.block(podium, V3(64.2, 0.3, 0.6), o * CF(0, 1.05, -34), GOLD, M.Metal, { shadow = false })
	for i, cid in ids do
		local x = (i - (n + 1) / 2) * 8.4
		local base = o * CF(x, 2, -41)
		Build.ucyl(podium, 1.2, 6.4, base * CF(0, 0.6, 0), rgb(240, 232, 215), M.Marble)
		local def = Classes and type(Classes.get) == "function" and Classes.get(cid)
		local col = Build.rgb(def and def.color, GOLD)
		Build.ucyl(podium, 0.15, 6.6, base * CF(0, 1.25, 0), col, M.Neon, { shadow = false })
		local ok, statue = pcall(BotModel.build, { id = -1, name = cid, classId = cid }, nil, { showcase = true })
		if ok and statue then
			statue:PivotTo(base * CF(0, 1.3, 0) * ANG(0, math.pi, 0))
			statue.Parent = podium
		end
		local plaque = Build.block(podium, V3(5.4, 1, 0.25), base * CF(0, 0.6, 3.25), rgb(110, 76, 44), M.Wood, { shadow = false })
		signText(plaque, Enum.NormalId.Back, if def and type(def.name) == "string" then def.name else cid)
		local spot = Build.block(podium, V3(0.4, 0.4, 0.4), base * CF(0, 12, 3), col, M.SmoothPlastic, { transparency = 1, shadow = false })
		local sl = Instance.new("SpotLight")
		sl.Face = Enum.NormalId.Bottom
		sl.Angle = 50
		sl.Range = 16
		sl.Brightness = 2
		sl.Color = col:Lerp(Color3.new(1, 1, 1), 0.5)
		sl.Parent = spot
	end

	-- TRUNKFALL sign above the showcase
	local signM = Build.model(model, "Sign")
	for _, s in { -1, 1 } do
		Build.ucyl(signM, 16, 1, o * CF(s * 13, 8, -48), rgb(110, 76, 44), M.Wood)
	end
	local sign = Build.block(signM, V3(26, 9, 1), o * CF(0, 13, -48), rgb(120, 82, 46), M.WoodPlanks, { name = "Sign" })
	Build.block(signM, V3(27, 0.8, 1.4), o * CF(0, 17.8, -48), GOLD, M.Metal)
	Props.cheeseWedge(signM, o * CF(0, 18.2, -48) * ANG(0, math.pi, 0), 5, 2.4, rng)
	local statusLabel = signText(sign, Enum.NormalId.Back, "TRUNKFALL", "Pick a class and READY UP")
	signText(sign, Enum.NormalId.Front, "TRUNKFALL", "Herd Sanctuary")

	-- Lamp posts round the plaza, cheese sculptures and gardens
	local deco = Build.model(model, "Decor")
	deco:AddTag("Decor")
	for i = 0, 11 do
		local a = (i + 0.5) / 12 * math.pi * 2
		local p = c + V3(math.cos(a) * 37.5, 0, math.sin(a) * 37.5)
		if math.abs(p.Z - (c.Z - 40)) > 6 then
			lamp(deco, CFrame.lookAt(p, c) * ANG(0, math.pi / 2, 0))
		end
	end
	if rng then
		for i = 1, 60 do
			local a, d = rng:range(0, 6.28), rng:range(39, 58)
			local x, z = c.X + math.cos(a) * d, c.Z + math.sin(a) * d
			local kind = if i % 3 == 0 then "grass" else "flower"
			Props.DECOR[kind](deco, x, z, rng:range(0.9, 1.4), rng, PAL)
		end
		local far = Build.model(model, "Backdrop")
		far:AddTag("DecorFar")
		for i = 0, 17 do
			local a = (i + rng:range(-0.3, 0.3)) / 18 * math.pi * 2
			local d = rng:range(50, 62)
			local x, z = c.X + math.cos(a) * d, c.Z + math.sin(a) * d
			local m = Build.model(far, "Tree" .. i)
			if i % 4 == 0 then
				Props.OBSTACLES.rock(m, x, z, rng:range(3, 5), rng, PAL, false)
			else
				Props.OBSTACLES.tree(m, x, z, rng:range(3.5, 5), rng, PAL, false)
			end
		end
		-- giant cheese wedges flanking the spawn path
		for _, s in { -1, 1 } do
			Props.cheeseRock(deco, c.X + s * 30, c.Z + 30, 4, rng, PAL, false)
		end
	end

	-- Invisible wall ring
	local walls = Instance.new("Folder")
	walls.Name = "Walls"
	walls.Parent = model
	local nW = 32
	local wr = LobbyWorld.WALL_RADIUS
	for i = 0, nW - 1 do
		local a = (i + 0.5) / nW * math.pi * 2
		local p = c + V3(math.cos(a) * wr, 12, math.sin(a) * wr)
		Build.block(walls, V3(2 * math.pi * wr / nW + 0.6, 26, 1), CFrame.lookAt(p, c + V3(0, 12, 0)), Color3.new(1, 1, 1), M.SmoothPlastic, {
			name = "Wall",
			collide = true,
			transparency = 1,
			shadow = false,
		})
	end

	-- Spawn (south side, facing the sign)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = V3(8, 1, 8)
	spawn.CFrame = o * CF(0, 0.5, 22)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CanQuery = false
	local decal = spawn:FindFirstChildOfClass("Decal")
	if decal then
		decal:Destroy()
	end
	spawn.Parent = model

	model.WorldPivot = o
	model.Parent = Workspace
	built = {
		spawn = spawn,
		readyPad = readyPad,
		squadPads = squadPads,
		statusLabel = statusLabel,
		model = model,
		center = c,
	}
	return built
end

return LobbyWorld
