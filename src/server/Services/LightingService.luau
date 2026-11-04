--!strict
-- LightingService (R4 Graphics, GDD-v2 §6): one mood preset per map and the lobby.
--
--   LightingService.apply(mapId | "lobby")   RunDirector calls it every stage
--                                            (ArenaBuilder.build also calls it), and
--                                            with "lobby" when a run ends.
--   LightingService.PRESETS[id]              the tuning tables
--   LightingService.current() -> string?
--
-- Each preset sets Lighting (ClockTime, Brightness, ambients, colour shift,
-- exposure, environment scales), an Atmosphere (which replaces classic fog), the
-- built-in Roblox Sky (default skybox textures; only sun / moon / stars are tuned),
-- Bloom, ColorCorrection (the colour grade), SunRays and DepthOfField, plus the
-- Terrain material tints, water colour and Clouds for that world.
--
-- Lighting.Technology is NOT scriptable (RobloxScriptSecurity, deprecated): the
-- place file must set it (default.project.json, see the R4 report). Its scriptable
-- successors LightingStyle = Realistic + PrioritizeLightingQuality = true are set
-- here too. DepthOfField is created enabled; the client turns it off on mobile
-- (src/client/Visuals/DetailLevel) and drives its focus from the camera.

local Lighting = game:GetService("Lighting")

local Terra = require(script.Parent.Parent:WaitForChild("Visuals"):WaitForChild("Terra")) :: any

local LightingService = {}

local rgb = Color3.fromRGB
local M = Enum.Material

export type Preset = {
	clock: number,
	brightness: number,
	ambient: Color3,
	outdoor: Color3,
	shiftTop: Color3,
	shiftBottom: Color3?,
	exposure: number,
	diffuse: number,
	specular: number,
	latitude: number?,
	shadowSoftness: number?,
	atmosphere: { density: number, offset: number, color: Color3, decay: Color3, glare: number, haze: number },
	sky: { stars: number, celestial: boolean, sun: number?, moon: number? },
	bloom: { intensity: number, size: number, threshold: number },
	grade: { brightness: number, contrast: number, saturation: number, tint: Color3 },
	sunRays: { intensity: number, spread: number },
	dof: { far: number, near: number, radius: number },
	terrain: { [Enum.Material]: Color3 },
	water: { color: Color3, transparency: number, reflectance: number, waveSize: number, waveSpeed: number }?,
	clouds: { cover: number, density: number, color: Color3 }?,
}

local WATER =
	{ color = rgb(40, 140, 170), transparency = 0.35, reflectance = 0.6, waveSize = 0.12, waveSpeed = 8 }

LightingService.PRESETS = {
	lobby = {
		clock = 16.6,
		brightness = 3,
		ambient = rgb(120, 100, 90),
		outdoor = rgb(150, 130, 115),
		shiftTop = rgb(255, 214, 160),
		exposure = 0.1,
		diffuse = 1,
		specular = 1,
		latitude = 35,
		atmosphere = {
			density = 0.3,
			offset = 0.2,
			color = rgb(255, 214, 170),
			decay = rgb(140, 110, 160),
			glare = 0.4,
			haze = 1.2,
		},
		sky = { stars = 400, celestial = true, sun = 14 },
		bloom = { intensity = 0.7, size = 28, threshold = 1.6 },
		grade = { brightness = 0.02, contrast = 0.1, saturation = 0.15, tint = rgb(255, 242, 225) },
		sunRays = { intensity = 0.12, spread = 0.6 },
		dof = { far = 0.25, near = 0, radius = 50 },
		terrain = {
			[M.Grass] = rgb(112, 178, 72),
			[M.LeafyGrass] = rgb(92, 158, 66),
			[M.Ground] = rgb(150, 112, 74),
			[M.Rock] = rgb(150, 140, 125),
			[M.Sandstone] = rgb(214, 182, 128),
			[M.Sand] = rgb(220, 200, 150),
		},
		water = WATER,
		clouds = { cover = 0.45, density = 0.35, color = rgb(255, 236, 214) },
	},
	plains = {
		clock = 13.2,
		brightness = 3.2,
		ambient = rgb(110, 115, 120),
		outdoor = rgb(140, 145, 150),
		shiftTop = rgb(255, 245, 220),
		exposure = 0,
		diffuse = 1,
		specular = 1,
		atmosphere = {
			density = 0.28,
			offset = 0.15,
			color = rgb(205, 230, 255),
			decay = rgb(120, 160, 210),
			glare = 0.2,
			haze = 1,
		},
		sky = { stars = 0, celestial = true, sun = 12 },
		bloom = { intensity = 0.5, size = 24, threshold = 1.8 },
		grade = { brightness = 0.02, contrast = 0.08, saturation = 0.18, tint = rgb(255, 252, 240) },
		sunRays = { intensity = 0.06, spread = 0.5 },
		dof = { far = 0.2, near = 0, radius = 50 },
		terrain = {
			[M.Grass] = rgb(118, 186, 74),
			[M.LeafyGrass] = rgb(96, 166, 62),
			[M.Ground] = rgb(156, 118, 78),
			[M.Rock] = rgb(150, 148, 140),
			[M.Sand] = rgb(226, 206, 150),
		},
		water = WATER,
		clouds = { cover = 0.55, density = 0.4, color = rgb(255, 255, 255) },
	},
	forest = {
		clock = 9.4,
		brightness = 2.6,
		ambient = rgb(80, 95, 80),
		outdoor = rgb(110, 130, 105),
		shiftTop = rgb(255, 225, 170),
		exposure = 0,
		diffuse = 1,
		specular = 0.8,
		latitude = 40,
		atmosphere = {
			density = 0.38,
			offset = 0.1,
			color = rgb(190, 215, 175),
			decay = rgb(90, 120, 90),
			glare = 0.6,
			haze = 1.6,
		},
		sky = { stars = 0, celestial = true, sun = 16 },
		bloom = { intensity = 0.6, size = 30, threshold = 1.5 },
		grade = { brightness = 0, contrast = 0.12, saturation = 0.12, tint = rgb(250, 255, 235) },
		sunRays = { intensity = 0.22, spread = 0.8 },
		dof = { far = 0.25, near = 0, radius = 45 },
		terrain = {
			[M.LeafyGrass] = rgb(70, 132, 56),
			[M.Grass] = rgb(84, 148, 60),
			[M.Mud] = rgb(92, 72, 52),
			[M.Ground] = rgb(120, 90, 60),
			[M.Rock] = rgb(120, 122, 112),
			[M.Sand] = rgb(190, 175, 130),
		},
		water = {
			color = rgb(50, 110, 100),
			transparency = 0.3,
			reflectance = 0.5,
			waveSize = 0.1,
			waveSpeed = 6,
		},
		clouds = { cover = 0.4, density = 0.3, color = rgb(240, 245, 235) },
	},
	jungle = {
		clock = 15.4,
		brightness = 2.8,
		ambient = rgb(90, 105, 80),
		outdoor = rgb(120, 140, 100),
		shiftTop = rgb(255, 230, 180),
		exposure = 0.05,
		diffuse = 1,
		specular = 1,
		atmosphere = {
			density = 0.45,
			offset = 0.05,
			color = rgb(200, 230, 190),
			decay = rgb(90, 140, 100),
			glare = 0.3,
			haze = 2.2,
		},
		sky = { stars = 0, celestial = true, sun = 14 },
		bloom = { intensity = 0.6, size = 26, threshold = 1.6 },
		grade = { brightness = 0.01, contrast = 0.14, saturation = 0.28, tint = rgb(245, 255, 235) },
		sunRays = { intensity = 0.15, spread = 0.7 },
		dof = { far = 0.25, near = 0, radius = 45 },
		terrain = {
			[M.LeafyGrass] = rgb(54, 128, 54),
			[M.Grass] = rgb(70, 150, 58),
			[M.Mud] = rgb(98, 70, 46),
			[M.Rock] = rgb(105, 118, 96),
			[M.Sand] = rgb(190, 170, 120),
		},
		water = {
			color = rgb(40, 130, 110),
			transparency = 0.3,
			reflectance = 0.5,
			waveSize = 0.12,
			waveSpeed = 7,
		},
		clouds = { cover = 0.7, density = 0.5, color = rgb(235, 245, 235) },
	},
	beach = {
		clock = 12,
		brightness = 3.6,
		ambient = rgb(125, 120, 115),
		outdoor = rgb(160, 160, 165),
		shiftTop = rgb(255, 250, 235),
		exposure = 0,
		diffuse = 1,
		specular = 1,
		atmosphere = {
			density = 0.25,
			offset = 0.2,
			color = rgb(200, 235, 255),
			decay = rgb(110, 180, 230),
			glare = 0.3,
			haze = 0.8,
		},
		sky = { stars = 0, celestial = true, sun = 11 },
		bloom = { intensity = 0.45, size = 24, threshold = 1.9 },
		grade = { brightness = 0.03, contrast = 0.06, saturation = 0.22, tint = rgb(255, 252, 245) },
		sunRays = { intensity = 0.05, spread = 0.4 },
		dof = { far = 0.15, near = 0, radius = 55 },
		terrain = {
			[M.Sand] = rgb(206, 180, 124),
			[M.Sandstone] = rgb(196, 150, 96),
			[M.Salt] = rgb(236, 226, 204),
			[M.Grass] = rgb(140, 180, 90),
		},
		water = {
			color = rgb(30, 170, 200),
			transparency = 0.45,
			reflectance = 0.7,
			waveSize = 0.18,
			waveSpeed = 10,
		},
		clouds = { cover = 0.35, density = 0.35, color = rgb(255, 255, 255) },
	},
	tundra = {
		clock = 8.2,
		brightness = 2.4,
		ambient = rgb(120, 135, 160),
		outdoor = rgb(150, 165, 190),
		shiftTop = rgb(220, 235, 255),
		exposure = -0.1,
		diffuse = 1,
		specular = 1,
		latitude = 60,
		atmosphere = {
			density = 0.42,
			offset = 0.12,
			color = rgb(215, 230, 250),
			decay = rgb(140, 160, 210),
			glare = 0.5,
			haze = 2,
		},
		sky = { stars = 200, celestial = true, sun = 18 },
		bloom = { intensity = 0.5, size = 30, threshold = 1.6 },
		grade = { brightness = 0, contrast = 0.1, saturation = -0.05, tint = rgb(235, 245, 255) },
		sunRays = { intensity = 0.12, spread = 0.6 },
		dof = { far = 0.25, near = 0, radius = 45 },
		terrain = {
			[M.Snow] = rgb(222, 232, 246),
			[M.Glacier] = rgb(130, 185, 228),
			[M.Ice] = rgb(175, 215, 240),
			[M.Slate] = rgb(110, 118, 132),
			[M.Rock] = rgb(120, 128, 140),
			[M.Sand] = rgb(170, 175, 180),
		},
		water = {
			color = rgb(60, 110, 150),
			transparency = 0.4,
			reflectance = 0.8,
			waveSize = 0.06,
			waveSpeed = 4,
		},
		clouds = { cover = 0.75, density = 0.6, color = rgb(230, 238, 250) },
	},
	volcano = {
		clock = 19.2,
		brightness = 1.6,
		ambient = rgb(110, 60, 50),
		outdoor = rgb(140, 80, 60),
		shiftTop = rgb(255, 140, 80),
		shiftBottom = rgb(255, 80, 30),
		exposure = 0.15,
		diffuse = 0.8,
		specular = 0.8,
		atmosphere = {
			density = 0.5,
			offset = 0.05,
			color = rgb(160, 90, 70),
			decay = rgb(90, 40, 40),
			glare = 0.8,
			haze = 2.5,
		},
		sky = { stars = 300, celestial = true, sun = 20 },
		bloom = { intensity = 1, size = 32, threshold = 1.2 },
		grade = { brightness = 0, contrast = 0.18, saturation = 0.15, tint = rgb(255, 225, 205) },
		sunRays = { intensity = 0.18, spread = 0.8 },
		dof = { far = 0.3, near = 0, radius = 45 },
		terrain = {
			[M.Basalt] = rgb(62, 52, 52),
			[M.CrackedLava] = rgb(200, 80, 30),
			[M.Slate] = rgb(80, 70, 68),
			[M.Rock] = rgb(70, 62, 60),
		},
		clouds = { cover = 0.8, density = 0.7, color = rgb(90, 60, 55) },
	},
	swamp = {
		clock = 17.6,
		brightness = 2.3,
		ambient = rgb(80, 95, 75),
		outdoor = rgb(95, 115, 85),
		shiftTop = rgb(200, 230, 160),
		exposure = 0.1,
		diffuse = 0.9,
		specular = 0.6,
		atmosphere = {
			density = 0.45,
			offset = 0,
			color = rgb(160, 185, 130),
			decay = rgb(80, 100, 76),
			glare = 0.2,
			haze = 2.4,
		},
		sky = { stars = 500, celestial = true, moon = 14 },
		bloom = { intensity = 0.9, size = 32, threshold = 1.3 },
		grade = { brightness = 0, contrast = 0.12, saturation = 0.05, tint = rgb(235, 255, 225) },
		sunRays = { intensity = 0.05, spread = 0.5 },
		dof = { far = 0.3, near = 0, radius = 40 },
		terrain = {
			[M.Mud] = rgb(86, 82, 58),
			[M.LeafyGrass] = rgb(88, 112, 56),
			[M.Slate] = rgb(84, 92, 78),
			[M.Ground] = rgb(104, 90, 64),
			[M.Sand] = rgb(110, 105, 80),
		},
		water = {
			color = rgb(70, 95, 55),
			transparency = 0.15,
			reflectance = 0.3,
			waveSize = 0.05,
			waveSpeed = 3,
		},
		clouds = { cover = 0.85, density = 0.6, color = rgb(160, 175, 150) },
	},
	moon = {
		clock = 0.6,
		brightness = 2.2,
		ambient = rgb(118, 118, 132),
		outdoor = rgb(138, 138, 152),
		shiftTop = rgb(225, 228, 245),
		exposure = 0.2,
		diffuse = 0.6,
		specular = 1,
		atmosphere = {
			density = 0.12,
			offset = 0.3,
			color = rgb(120, 130, 170),
			decay = rgb(40, 40, 80),
			glare = 0,
			haze = 0.2,
		},
		sky = { stars = 5000, celestial = true, moon = 22 },
		bloom = { intensity = 0.8, size = 26, threshold = 1.4 },
		grade = { brightness = 0.04, contrast = 0.2, saturation = -0.1, tint = rgb(235, 240, 255) },
		sunRays = { intensity = 0, spread = 0.2 },
		dof = { far = 0.2, near = 0, radius = 50 },
		terrain = {
			[M.Rock] = rgb(196, 196, 204),
			[M.Slate] = rgb(150, 150, 162),
			[M.Basalt] = rgb(120, 120, 132),
		},
	},
	ocean = {
		clock = 11,
		brightness = 2,
		ambient = rgb(70, 120, 150),
		outdoor = rgb(80, 140, 170),
		shiftTop = rgb(150, 220, 255),
		exposure = 0.05,
		diffuse = 0.9,
		specular = 1,
		atmosphere = {
			density = 0.45,
			offset = 0,
			color = rgb(80, 150, 180),
			decay = rgb(25, 75, 120),
			glare = 0,
			haze = 2.2,
		},
		sky = { stars = 0, celestial = false },
		bloom = { intensity = 0.8, size = 34, threshold = 1.3 },
		grade = { brightness = 0, contrast = 0.12, saturation = 0.05, tint = rgb(222, 240, 255) },
		sunRays = { intensity = 0.25, spread = 1 },
		dof = { far = 0.35, near = 0, radius = 40 },
		terrain = {
			[M.Sand] = rgb(200, 196, 160),
			[M.Ground] = rgb(130, 120, 100),
			[M.Pebble] = rgb(150, 160, 150),
			[M.Salt] = rgb(220, 230, 225),
			[M.Rock] = rgb(90, 120, 128),
		},
		water = {
			color = rgb(20, 90, 140),
			transparency = 0.25,
			reflectance = 0.4,
			waveSize = 0.2,
			waveSpeed = 6,
		},
	},
} :: { [string]: Preset }

local currentId: string? = nil

local function ensure(className: string, name: string): any
	local inst = Lighting:FindFirstChild(name)
	if inst and inst.ClassName ~= className then
		inst:Destroy()
		inst = nil
	end
	if not inst then
		inst = Instance.new(className)
		inst.Name = name
		inst.Parent = Lighting
	end
	return inst
end

function LightingService.current(): string?
	return currentId
end

function LightingService.apply(id: string)
	local p = LightingService.PRESETS[id] or LightingService.PRESETS.plains
	currentId = if LightingService.PRESETS[id] then id else "plains"

	pcall(function()
		-- Future-class lighting via the scriptable successors of Technology.
		(Lighting :: any).LightingStyle = Enum.LightingStyle.Realistic;
		(Lighting :: any).PrioritizeLightingQuality = true
	end)
	Lighting.ClockTime = p.clock
	Lighting.GeographicLatitude = p.latitude or 30
	Lighting.Brightness = p.brightness
	Lighting.Ambient = p.ambient
	Lighting.OutdoorAmbient = p.outdoor
	Lighting.ColorShift_Top = p.shiftTop
	Lighting.ColorShift_Bottom = p.shiftBottom or Color3.new(0, 0, 0)
	Lighting.ExposureCompensation = p.exposure
	Lighting.EnvironmentDiffuseScale = p.diffuse
	Lighting.EnvironmentSpecularScale = p.specular
	Lighting.ShadowSoftness = p.shadowSoftness or 0.25
	Lighting.GlobalShadows = true

	local a = ensure("Atmosphere", "TrunkfallAtmosphere") :: Atmosphere
	a.Density = p.atmosphere.density
	a.Offset = p.atmosphere.offset
	a.Color = p.atmosphere.color
	a.Decay = p.atmosphere.decay
	a.Glare = p.atmosphere.glare
	a.Haze = p.atmosphere.haze

	-- Built-in Roblox skybox: a Sky keeps the default textures unless they are set.
	local sky = ensure("Sky", "TrunkfallSky") :: Sky
	sky.StarCount = p.sky.stars
	sky.CelestialBodiesShown = p.sky.celestial
	sky.SunAngularSize = p.sky.sun or 21
	sky.MoonAngularSize = p.sky.moon or 11

	local bloom = ensure("BloomEffect", "TrunkfallBloom") :: BloomEffect
	bloom.Intensity = p.bloom.intensity
	bloom.Size = p.bloom.size
	bloom.Threshold = p.bloom.threshold
	bloom.Enabled = true

	local cc = ensure("ColorCorrectionEffect", "TrunkfallGrade") :: ColorCorrectionEffect
	cc.Brightness = p.grade.brightness
	cc.Contrast = p.grade.contrast
	cc.Saturation = p.grade.saturation
	cc.TintColor = p.grade.tint
	cc.Enabled = true

	local rays = ensure("SunRaysEffect", "TrunkfallSunRays") :: SunRaysEffect
	rays.Intensity = p.sunRays.intensity
	rays.Spread = p.sunRays.spread
	rays.Enabled = p.sunRays.intensity > 0

	local dof = ensure("DepthOfFieldEffect", "TrunkfallDepth") :: DepthOfFieldEffect
	dof.FarIntensity = p.dof.far
	dof.NearIntensity = p.dof.near
	dof.InFocusRadius = p.dof.radius
	dof.FocusDistance = 60 -- the client re-focuses on the hero every frame
	dof.Enabled = true
	dof:SetAttribute("Default", true)

	Terra.colors(p.terrain)
	if p.water then
		Terra.water(p.water)
	end
	Terra.clouds(p.clouds)
	Lighting:SetAttribute("Mood", currentId)
end

return LightingService
