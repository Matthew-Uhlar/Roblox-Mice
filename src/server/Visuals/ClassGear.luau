--!strict
-- ClassGear (R4 Graphics): part-built class gear shared by BotModel (part elephants)
-- and HeroDecor (player avatars).
--
--   ClassGear.hat(parent, top: CFrame, s, classId, colors) -> {BasePart}
--       `top` = centre of the top of the head, -Z forward; s = head height.
--   ClassGear.face(parent, face: CFrame, s, classId, colors) -> {BasePart}
--       `face` = centre of the front of the head (class goggles etc.).
--   ClassGear.back(parent, back: CFrame, s, classId, colors) -> {BasePart}
--       `back` = centre of the upper back surface, -Z = toward the body.
--   ClassGear.accessory(parent, at: {top, face, back, neck}, s, accessoryId, colors) -> {BasePart}
--       Config/ClassSkins.ACCESSORIES ids (built from parts by attach point).
--   ClassGear.colors(classId, skinId?) -> {body, accent, trim}
--
-- Parts are created anchored; HeroDecor un-anchors and welds them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Build = require(script.Parent.Build)

local ClassGear = {}

local rad = math.rad
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local M = Enum.Material
local rgb = Color3.fromRGB

export type Colors = { body: Color3, accent: Color3, trim: Color3 }

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
local ClassSkins: any = optional({ "Config", "ClassSkins" })

local DEFAULT_ACCENT: { [string]: Color3 } = {
	elephante = rgb(200, 60, 50),
	ele_fonte = rgb(230, 245, 255),
	ellie_fawn = rgb(140, 95, 50),
	le_fante = rgb(250, 240, 230),
	filet = rgb(250, 250, 250),
	jumbo = rgb(120, 80, 50),
	fizzante = rgb(90, 210, 255),
}

function ClassGear.colors(classId: string, skinId: string?): Colors
	if skinId and ClassSkins and type(ClassSkins.get) == "function" then
		local ok, skin = pcall(ClassSkins.get, skinId)
		if ok and type(skin) == "table" and type(skin.colors) == "table" then
			return {
				body = Build.rgb(skin.colors.body, rgb(150, 150, 165)),
				accent = Build.rgb(skin.colors.accent, rgb(255, 200, 60)),
				trim = Build.rgb(skin.colors.trim, rgb(255, 255, 255)),
			}
		end
	end
	local body = rgb(150, 150, 165)
	if Classes and type(Classes.get) == "function" then
		local ok, def = pcall(Classes.get, classId)
		if ok and type(def) == "table" then
			body = Build.rgb(def.color, body)
		end
	end
	return { body = body, accent = DEFAULT_ACCENT[classId] or rgb(255, 200, 60), trim = rgb(255, 205, 70) }
end

function ClassGear.accessoryOf(skinId: string?): (string?, string?)
	if skinId and ClassSkins and type(ClassSkins.get) == "function" then
		local ok, skin = pcall(ClassSkins.get, skinId)
		if ok and type(skin) == "table" and type(skin.accessory) == "string" then
			local acc = ClassSkins.ACCESSORIES and ClassSkins.ACCESSORIES[skin.accessory]
			return skin.accessory, if acc then acc.attach else nil
		end
	end
	return nil, nil
end

type Out = { BasePart }

local function add(out: Out, p: BasePart): BasePart
	table.insert(out, p)
	return p
end

-- Default class hats ---------------------------------------------------------------------

local HATS: { [string]: (Instance, CFrame, number, Colors, Out) -> () } = {}

HATS.elephante = function(m, t, s, c, out) -- banded brawler helm with a crest
	add(out, Build.egg(m, V3(1.05, 0.55, 1.05) * s, t * CF(0, 0.05 * s, 0), c.body, M.Metal))
	add(out, Build.block(m, V3(1.08, 0.12, 1.08) * s, t * CF(0, -0.12 * s, 0), c.accent, M.Fabric))
	add(out, Build.block(m, V3(0.12, 0.35, 0.8) * s, t * CF(0, 0.38 * s, 0), c.accent, M.Fabric))
end

HATS.ele_fonte = function(m, t, s, c, out) -- crown of water droplets
	add(out, Build.ucyl(m, 0.12 * s, 0.95 * s, t * CF(0, 0, 0), c.accent, M.Metal))
	for i = 0, 4 do
		local a = i / 5 * math.pi * 2
		add(out, Build.egg(m, V3(0.2, 0.36, 0.2) * s, t * CF(math.cos(a) * 0.42 * s, 0.2 * s, math.sin(a) * 0.42 * s), rgb(90, 190, 255), M.Glass, {
			transparency = 0.2,
		}))
	end
end

HATS.ellie_fawn = function(m, t, s, c, out) -- ranger hat with a feather
	add(out, Build.ucyl(m, 0.06 * s, 1.5 * s, t * CF(0, 0, 0), c.body, M.Fabric))
	add(out, Build.ucyl(m, 0.4 * s, 0.85 * s, t * CF(0, 0.2 * s, 0), c.body, M.Fabric))
	add(out, Build.ucyl(m, 0.1 * s, 0.88 * s, t * CF(0, 0.06 * s, 0), c.accent, M.Fabric))
	add(out, Build.egg(m, V3(0.1, 0.7, 0.2) * s, t * CF(0.4 * s, 0.35 * s, 0.1 * s) * ANG(0, 0, rad(-30)), rgb(230, 80, 60), M.Fabric))
end

HATS.le_fante = function(m, t, s, c, out) -- beret with a stalk
	add(out, Build.egg(m, V3(1.25, 0.3, 1.15) * s, t * CF(0.12 * s, 0.05 * s, 0) * ANG(0, 0, rad(-10)), c.body, M.Fabric))
	add(out, Build.ucyl(m, 0.15 * s, 0.1 * s, t * CF(0.12 * s, 0.25 * s, 0), c.body, M.Fabric))
end

HATS.filet = function(m, t, s, c, out) -- chef toque
	add(out, Build.ucyl(m, 0.7 * s, 0.85 * s, t * CF(0, 0.35 * s, 0), c.accent, M.Fabric))
	for i = 0, 3 do
		local a = i / 4 * math.pi * 2 + 0.4
		add(out, Build.ball(m, 0.55 * s, t * CF(math.cos(a) * 0.22 * s, 0.8 * s, math.sin(a) * 0.22 * s), c.accent, M.Fabric))
	end
	add(out, Build.ucyl(m, 0.12 * s, 0.9 * s, t * CF(0, 0.04 * s, 0), c.body, M.Fabric))
end

HATS.jumbo = function(m, t, s, c, out) -- aviator cap with ear flaps
	add(out, Build.egg(m, V3(1.08, 0.6, 1.1) * s, t * CF(0, -0.02 * s, 0.03 * s), c.accent, M.Leather))
	for _, side in { -1, 1 } do
		add(out, Build.egg(m, V3(0.18, 0.55, 0.35) * s, t * CF(side * 0.5 * s, -0.4 * s, 0), c.accent, M.Leather))
	end
	for _, side in { -1, 1 } do
		add(out, Build.cyl(m, 0.12 * s, 0.32 * s, t * CF(side * 0.2 * s, 0.12 * s, -0.48 * s) * ANG(0, rad(90), 0), rgb(140, 220, 255), M.Glass))
	end
end

HATS.fizzante = function(m, t, s, c, out) -- bottle-cap crown with a bubble
	add(out, Build.ucyl(m, 0.18 * s, 0.9 * s, t * CF(0, 0.06 * s, 0), c.body, M.Metal))
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		add(out, Build.block(m, V3(0.12, 0.2, 0.12) * s, t * CF(math.cos(a) * 0.45 * s, 0.06 * s, math.sin(a) * 0.45 * s), c.body, M.Metal, {
			shadow = false,
		}))
	end
	add(out, Build.ball(m, 0.22 * s, t * CF(0.1 * s, 0.32 * s, 0), c.accent, M.Glass, { transparency = 0.2 }))
end

function ClassGear.hat(parent: Instance, top: CFrame, s: number, classId: string, colors: Colors): { BasePart }
	local out = {}
	local fn = HATS[classId] or HATS.elephante
	fn(parent, top, s, colors, out)
	return out
end

-- Face gear (Fizzante goggles) --------------------------------------------------------------

function ClassGear.face(parent: Instance, face: CFrame, s: number, classId: string, colors: Colors): { BasePart }
	local out = {}
	if classId == "fizzante" then
		add(out, Build.block(parent, V3(1.05, 0.14, 0.12) * s, face * CF(0, 0.15 * s, 0), rgb(60, 50, 45), M.Leather))
		for _, side in { -1, 1 } do
			add(out, Build.cyl(parent, 0.14 * s, 0.34 * s, face * CF(side * 0.2 * s, 0.15 * s, -0.06 * s) * ANG(0, rad(90), 0), colors.accent, M.Glass, {
				transparency = 0.1,
			}))
		end
	end
	return out
end

-- Back gear (class weapon / pack) ------------------------------------------------------------

local BACKS: { [string]: (Instance, CFrame, number, Colors, Out) -> () } = {}

BACKS.elephante = function(m, b, s, c, out) -- round shield with a boss
	add(out, Build.cyl(m, 0.15 * s, 1.5 * s, b * CF(0, 0, 0.1 * s) * ANG(0, rad(90), 0), c.body, M.Wood))
	add(out, Build.cyl(m, 0.17 * s, 1.0 * s, b * CF(0, 0, 0.12 * s) * ANG(0, rad(90), 0), c.accent, M.Metal))
	add(out, Build.ball(m, 0.35 * s, b * CF(0, 0, 0.22 * s), c.trim, M.Metal))
end

BACKS.ele_fonte = function(m, b, s, c, out) -- water tank with a hose
	add(out, Build.ucyl(m, 1.1 * s, 0.6 * s, b * CF(0, 0, 0.35 * s), rgb(90, 190, 255), M.Glass, { transparency = 0.25 }))
	add(out, Build.ucyl(m, 0.15 * s, 0.65 * s, b * CF(0, 0.6 * s, 0.35 * s), c.trim, M.Metal))
	add(out, Build.cyl(m, 0.9 * s, 0.12 * s, b * CF(0.35 * s, 0.4 * s, 0.1 * s) * ANG(0, 0, rad(-60)), c.body, M.Rubber))
end

BACKS.ellie_fawn = function(m, b, s, c, out) -- quiver of peanuts
	local q = b * CF(0, 0.1 * s, 0.25 * s) * ANG(0, 0, rad(25))
	add(out, Build.ucyl(m, 1.2 * s, 0.42 * s, q, c.accent, M.Leather))
	for i = 0, 2 do
		add(out, Build.egg(m, V3(0.2, 0.36, 0.2) * s, q * CF((i - 1) * 0.11 * s, 0.7 * s, 0), rgb(215, 170, 110), M.SmoothPlastic))
	end
end

BACKS.le_fante = function(m, b, s, c, out) -- rapier in a scabbard
	local r = b * CF(0, 0, 0.18 * s) * ANG(0, 0, rad(40))
	add(out, Build.block(m, V3(0.14, 1.6, 0.14) * s, r, c.body, M.Leather))
	add(out, Build.block(m, V3(0.5, 0.08, 0.1) * s, r * CF(0, 0.82 * s, 0), c.trim, M.Metal))
	add(out, Build.ball(m, 0.22 * s, r * CF(0, 1.0 * s, 0), c.trim, M.Metal))
end

BACKS.filet = function(m, b, s, c, out) -- crossed cleavers
	for _, side in { -1, 1 } do
		local r = b * CF(0, 0, 0.16 * s) * ANG(0, 0, rad(35 * side))
		add(out, Build.block(m, V3(0.45, 0.6, 0.06) * s, r * CF(0, 0.45 * s, 0), rgb(200, 205, 215), M.Metal))
		add(out, Build.block(m, V3(0.1, 0.5, 0.1) * s, r * CF(0, -0.1 * s, 0), c.body, M.Wood))
	end
end

BACKS.jumbo = function(m, b, s, c, out) -- little flight wings
	for _, side in { -1, 1 } do
		add(out, Build.wedge(m, V3(0.08, 0.5, 1.1) * s, b * CF(side * 0.6 * s, 0.1 * s, 0.2 * s) * ANG(0, rad(90 * side), rad(-15 * side)), c.trim, M.SmoothPlastic))
	end
	add(out, Build.ball(m, 0.3 * s, b * CF(0, 0, 0.15 * s), c.accent, M.Leather))
end

BACKS.fizzante = function(m, b, s, c, out) -- soda bottle pack
	for _, side in { -1, 1 } do
		local bt = b * CF(side * 0.22 * s, 0, 0.3 * s)
		add(out, Build.ucyl(m, 0.9 * s, 0.38 * s, bt, c.body, M.Glass, { transparency = 0.15 }))
		add(out, Build.ucyl(m, 0.3 * s, 0.2 * s, bt * CF(0, 0.58 * s, 0), c.body, M.Glass, { transparency = 0.15 }))
		add(out, Build.ucyl(m, 0.08 * s, 0.24 * s, bt * CF(0, 0.76 * s, 0), c.trim, M.Metal))
	end
end

function ClassGear.back(parent: Instance, back: CFrame, s: number, classId: string, colors: Colors): { BasePart }
	local out = {}
	local fn = BACKS[classId] or BACKS.elephante
	fn(parent, back, s, colors, out)
	return out
end

-- Skin accessories (Config/ClassSkins.ACCESSORIES) ---------------------------------------------

export type Anchors = { top: CFrame, face: CFrame, back: CFrame, neck: CFrame }
local ACC: { [string]: (Instance, Anchors, number, Colors, Out) -> () } = {}

local function ring(m: Instance, at: CFrame, r: number, n: number, size: Vector3, color: Color3, mat: Enum.Material, out: Out)
	for i = 0, n - 1 do
		local a = i / n * math.pi * 2
		add(out, Build.egg(m, size, at * CF(math.cos(a) * r, 0, math.sin(a) * r) * ANG(0, -a, 0), color, mat))
	end
end

ACC.war_paint = function(m, at, s, c, out)
	for _, side in { -1, 1 } do
		for k = 0, 1 do
			add(out, Build.block(m, V3(0.32, 0.06, 0.04) * s, at.face * CF(side * 0.3 * s, (-0.05 - k * 0.12) * s, 0), c.accent, M.SmoothPlastic, {
				shadow = false,
			}))
		end
	end
end
ACC.iron_helm = function(m, at, s, c, out)
	add(out, Build.egg(m, V3(1.1, 0.7, 1.1) * s, at.top * CF(0, 0, 0), c.accent, M.Metal))
	add(out, Build.block(m, V3(0.12, 0.45, 0.08) * s, at.face * CF(0, 0.05 * s, -0.04 * s), c.accent, M.Metal))
end
ACC.gladiator_crest = function(m, at, s, c, out)
	add(out, Build.egg(m, V3(1.1, 0.65, 1.1) * s, at.top, c.accent, M.Metal))
	for k = 0, 4 do
		add(out, Build.block(m, V3(0.12, 0.5, 0.18) * s, at.top * CF(0, 0.45 * s, (k - 2) * 0.17 * s), c.body, M.Fabric))
	end
end
ACC.mammoth_crown = function(m, at, s, c, out)
	add(out, Build.ucyl(m, 0.3 * s, 1.0 * s, at.top * CF(0, 0.05 * s, 0), c.accent, M.Fabric))
	ring(m, at.top * CF(0, 0.3 * s, 0), 0.38 * s, 5, V3(0.16, 0.3, 0.16) * s, c.trim, M.Metal, out)
	for _, side in { -1, 1 } do
		add(out, Build.cyl(m, 0.6 * s, 0.14 * s, at.top * CF(side * 0.55 * s, 0, -0.15 * s) * ANG(0, rad(30 * side), rad(30)), rgb(250, 245, 230), M.Marble))
	end
end
ACC.rain_cloud = function(m, at, s, _c, out)
	for i = 0, 3 do
		add(out, Build.ball(m, (0.45 + (i % 2) * 0.15) * s, at.top * CF((i - 1.5) * 0.3 * s, 0.7 * s, 0), rgb(235, 240, 250), M.SmoothPlastic))
	end
	for i = 0, 2 do
		add(out, Build.egg(m, V3(0.06, 0.18, 0.06) * s, at.top * CF((i - 1) * 0.3 * s, 0.35 * s, 0), rgb(90, 170, 255), M.Glass))
	end
end
ACC.coral_crown = function(m, at, s, c, out)
	add(out, Build.ucyl(m, 0.12 * s, 0.95 * s, at.top, c.accent, M.Pebble))
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2
		add(out, Build.ucyl(m, 0.45 * s, 0.1 * s, at.top * CF(math.cos(a) * 0.42 * s, 0.22 * s, math.sin(a) * 0.42 * s) * ANG(math.sin(a) * 0.3, 0, -math.cos(a) * 0.3), c.body, M.Pebble))
	end
end
ACC.wave_cape = function(m, at, s, c, out)
	add(out, Build.block(m, V3(1.2, 1.4, 0.08) * s, at.back * CF(0, -0.5 * s, 0.2 * s), c.body, M.Fabric))
	add(out, Build.egg(m, V3(1.3, 0.35, 0.3) * s, at.back * CF(0, -1.2 * s, 0.25 * s), c.accent, M.Fabric))
end
ACC.trident_halo = function(m, at, s, c, out)
	ring(m, at.top * CF(0, 0.5 * s, 0), 0.5 * s, 8, V3(0.16, 0.08, 0.22) * s, c.trim, M.Neon, out)
	for k = -1, 1 do
		add(out, Build.block(m, V3(0.06, 0.4, 0.06) * s, at.top * CF(k * 0.2 * s, 0.75 * s, -0.5 * s), c.accent, M.Metal))
	end
end
ACC.leaf_cap = function(m, at, s, c, out)
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2
		add(out, Build.egg(m, V3(0.5, 0.1, 0.7) * s, at.top * CF(math.cos(a) * 0.25 * s, 0.05 * s, math.sin(a) * 0.25 * s) * ANG(0, -a, rad(20)), c.body, M.Grass))
	end
end
ACC.moon_hood = function(m, at, s, c, out)
	add(out, Build.egg(m, V3(1.2, 0.9, 1.2) * s, at.top * CF(0, -0.15 * s, 0.1 * s), c.body, M.Fabric))
	add(out, Build.ball(m, 0.3 * s, at.top * CF(0, 0.1 * s, -0.58 * s), c.trim, M.Neon))
end
ACC.antler_circlet = function(m, at, s, c, out)
	add(out, Build.ucyl(m, 0.08 * s, 1.0 * s, at.top, c.accent, M.Wood))
	for _, side in { -1, 1 } do
		local base = at.top * CF(side * 0.35 * s, 0.3 * s, 0) * ANG(0, 0, rad(-25 * side))
		add(out, Build.ucyl(m, 0.6 * s, 0.08 * s, base, c.trim, M.Wood))
		add(out, Build.ucyl(m, 0.3 * s, 0.07 * s, base * CF(0, 0.1 * s, 0) * ANG(0, 0, rad(45 * side)) * CF(0, 0.15 * s, 0), c.trim, M.Wood))
	end
end
ACC.blossom_crown = function(m, at, s, c, out)
	ring(m, at.top * CF(0, 0.05 * s, 0), 0.45 * s, 5, V3(0.28, 0.14, 0.28) * s, c.body, M.SmoothPlastic, out)
	ring(m, at.top * CF(0, 0.12 * s, 0), 0.45 * s, 5, V3(0.1, 0.1, 0.1) * s, c.trim, M.SmoothPlastic, out)
end
ACC.feather_hat = function(m, at, s, c, out)
	add(out, Build.ucyl(m, 0.06 * s, 1.7 * s, at.top, c.body, M.Fabric))
	add(out, Build.ucyl(m, 0.35 * s, 0.9 * s, at.top * CF(0, 0.2 * s, 0), c.body, M.Fabric))
	add(out, Build.egg(m, V3(0.12, 1.0, 0.25) * s, at.top * CF(0.45 * s, 0.5 * s, 0.2 * s) * ANG(rad(20), 0, rad(-35)), c.trim, M.Fabric))
end
ACC.masquerade_mask = function(m, at, s, c, out)
	add(out, Build.block(m, V3(0.9, 0.22, 0.06) * s, at.face * CF(0, 0.12 * s, 0), c.body, M.SmoothPlastic))
	for _, side in { -1, 1 } do
		add(out, Build.wedge(m, V3(0.06, 0.25, 0.3) * s, at.face * CF(side * 0.55 * s, 0.22 * s, 0) * ANG(0, rad(90 * side), 0), c.trim, M.SmoothPlastic))
	end
end
ACC.duelist_cape = function(m, at, s, c, out)
	add(out, Build.block(m, V3(1.3, 0.9, 0.08) * s, at.back * CF(0, -0.25 * s, 0.2 * s), c.body, M.Fabric))
	add(out, Build.block(m, V3(1.35, 0.1, 0.1) * s, at.back * CF(0, 0.2 * s, 0.2 * s), c.trim, M.Metal))
end
ACC.laurel_wreath = function(m, at, s, c, out)
	ring(m, at.top * CF(0, -0.1 * s, 0), 0.5 * s, 10, V3(0.12, 0.08, 0.25) * s, c.trim, M.Metal, out)
end
ACC.bandana = function(m, at, s, c, out)
	add(out, Build.egg(m, V3(1.08, 0.4, 1.08) * s, at.top * CF(0, -0.05 * s, 0), c.body, M.Fabric))
	add(out, Build.egg(m, V3(0.15, 0.3, 0.4) * s, at.top * CF(0, -0.25 * s, 0.6 * s), c.body, M.Fabric))
end
ACC.tall_toque = function(m, at, s, c, out)
	add(out, Build.ucyl(m, 1.3 * s, 0.85 * s, at.top * CF(0, 0.65 * s, 0), c.accent, M.Fabric))
	add(out, Build.ball(m, 0.95 * s, at.top * CF(0, 1.35 * s, 0), c.accent, M.Fabric))
end
ACC.iron_apron = function(m, at, s, c, out)
	add(out, Build.block(m, V3(0.9, 1.1, 0.08) * s, at.neck * CF(0, -0.6 * s, -0.05 * s), c.accent, M.DiamondPlate))
end
ACC.star_toque = function(m, at, s, c, out)
	HATS.filet(m, at.top, s, c, out)
	add(out, Build.ball(m, 0.25 * s, at.top * CF(0, 0.4 * s, -0.44 * s), c.trim, M.Neon))
end
ACC.circus_hat = function(m, at, s, c, out)
	for k = 0, 3 do
		add(out, Build.ucyl(m, 0.2 * s, (0.6 - k * 0.13) * s, at.top * CF(0, (0.1 + k * 0.2) * s, 0), if k % 2 == 0 then c.body else c.accent, M.Fabric))
	end
	add(out, Build.ball(m, 0.25 * s, at.top * CF(0, 0.95 * s, 0), c.trim, M.Fabric))
end
ACC.aviator_goggles = function(m, at, s, c, out)
	add(out, Build.block(m, V3(1.05, 0.14, 0.1) * s, at.face * CF(0, 0.15 * s, 0), rgb(80, 55, 35), M.Leather))
	for _, side in { -1, 1 } do
		add(out, Build.cyl(m, 0.14 * s, 0.34 * s, at.face * CF(side * 0.2 * s, 0.15 * s, -0.06 * s) * ANG(0, rad(90), 0), c.trim, M.Glass))
	end
end
ACC.storm_wings = function(m, at, s, c, out)
	for _, side in { -1, 1 } do
		for k = 0, 1 do
			add(out, Build.wedge(m, V3(0.06, 0.6, 1.0) * s, at.back * CF(side * (0.6 + k * 0.3) * s, (0.2 - k * 0.3) * s, 0.25 * s) * ANG(0, rad(90 * side), rad(-20 * side)), if k == 0 then c.body else c.trim, M.Neon))
		end
	end
end
ACC.cloud_crown = function(m, at, s, _c, out)
	ring(m, at.top * CF(0, 0.55 * s, 0), 0.55 * s, 6, V3(0.35, 0.25, 0.35) * s, rgb(240, 245, 255), M.SmoothPlastic, out)
end
ACC.soda_cap = function(m, at, s, c, out)
	add(out, Build.ucyl(m, 0.25 * s, 1.1 * s, at.top * CF(0, 0.1 * s, 0), c.body, M.Metal))
	ring(m, at.top * CF(0, 0.1 * s, 0), 0.56 * s, 10, V3(0.12, 0.26, 0.12) * s, c.body, M.Metal, out)
	add(out, Build.ucyl(m, 0.03 * s, 0.6 * s, at.top * CF(0, 0.24 * s, 0), c.trim, M.SmoothPlastic))
end
ACC.lab_goggles = function(m, at, s, c, out)
	add(out, Build.block(m, V3(0.85, 0.3, 0.15) * s, at.face * CF(0, 0.15 * s, -0.04 * s), c.trim, M.Glass, { transparency = 0.2 }))
	add(out, Build.block(m, V3(1.05, 0.1, 0.1) * s, at.face * CF(0, 0.15 * s, 0.02 * s), c.body, M.Rubber))
end
ACC.gas_mask = function(m, at, s, c, out)
	add(out, Build.egg(m, V3(0.55, 0.45, 0.35) * s, at.face * CF(0, -0.15 * s, -0.12 * s), c.body, M.Rubber))
	for _, side in { -1, 1 } do
		add(out, Build.cyl(m, 0.2 * s, 0.25 * s, at.face * CF(side * 0.3 * s, -0.25 * s, -0.15 * s) * ANG(0, rad(90 + 30 * side), 0), c.accent, M.Metal))
	end
end
ACC.flask_halo = function(m, at, s, c, out)
	for i = 0, 2 do
		local a = i / 3 * math.pi * 2
		local p = at.top * CF(math.cos(a) * 0.6 * s, 0.4 * s, math.sin(a) * 0.6 * s)
		add(out, Build.ball(m, 0.25 * s, p, c.body, M.Glass, { transparency = 0.15 }))
		add(out, Build.ucyl(m, 0.15 * s, 0.1 * s, p * CF(0, 0.18 * s, 0), c.trim, M.Glass))
	end
end
ACC.gilded_regalia = function(m, at, s, c, out)
	add(out, Build.ucyl(m, 0.15 * s, 1.1 * s, at.neck, rgb(255, 200, 60), M.Metal))
	add(out, Build.ball(m, 0.22 * s, at.neck * CF(0, -0.15 * s, -0.5 * s), c.trim, M.Glass))
end
ACC.neon_visor = function(m, at, s, c, out)
	add(out, Build.block(m, V3(1.0, 0.16, 0.08) * s, at.face * CF(0, 0.15 * s, -0.02 * s), c.trim, M.Neon))
end

function ClassGear.accessory(parent: Instance, at: Anchors, s: number, accessoryId: string, colors: Colors): { BasePart }
	local out = {}
	local fn = ACC[accessoryId]
	if fn then
		fn(parent, at, s, colors, out)
	end
	return out
end

ClassGear.ACCESSORY_BUILDERS = ACC

return ClassGear
