--!strict
-- MouseModels (R4 Graphics, client): part specs for every enemy kind (GDD-v2 §6).
--
--   MouseModels.build(kindId, def, scale, elite?) -> { parts, low, lod, radius }
--     parts  full model, 15-20 parts (crown spec has cond = "elite")
--     low    low-spec model, 7-9 parts
--     lod    3 parts: drawn beyond MouseModels.LOD_DISTANCE studs
--   Silhouette first, colour second (STYLE.md): Mouse is the baseline; Rat Runner
--   is long and lean with a long tail and a red headband; Chonk is round with a
--   cheese chunk; Crumb Slinger carries a slingshot and a crumb bag; Fuse Mouse
--   has a bomb on its back with a lit (pulsing Neon) fuse. Built at unit radius
--   and scaled to the enemy's hitbox radius.

local Spec = require(script.Parent.Spec)

local MouseModels = {}

MouseModels.LOD_DISTANCE = 80

local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local rad = math.rad
local M = Enum.Material
local rgb = Color3.fromRGB

local PINK = rgb(242, 167, 181)
local PINK_DARK = rgb(226, 120, 140)
local EYE = rgb(22, 18, 20)
local GOLD = rgb(255, 196, 40)

type Look = {
	body: Color3,
	belly: Color3,
	bodySize: Vector3,
	headSize: Vector3,
	ear: number,
	tail: number,
	legs: number,
}

local LOOKS: { [string]: Look } = {
	mouse = { body = rgb(139, 107, 78), belly = rgb(214, 190, 160), bodySize = V3(1.6, 1.3, 2.1), headSize = V3(1.15, 1, 1.2), ear = 0.8, tail = 1, legs = 1 },
	rat_runner = { body = rgb(112, 100, 96), belly = rgb(176, 160, 150), bodySize = V3(1.25, 1.0, 2.6), headSize = V3(0.95, 0.85, 1.35), ear = 0.62, tail = 1.6, legs = 1.25 },
	chonk = { body = rgb(118, 118, 134), belly = rgb(220, 214, 226), bodySize = V3(2.0, 1.75, 2.1), headSize = V3(1.2, 1.05, 1.1), ear = 0.6, tail = 0.7, legs = 0.8 },
	crumb_slinger = { body = rgb(186, 150, 104), belly = rgb(240, 220, 180), bodySize = V3(1.5, 1.3, 1.9), headSize = V3(1.1, 1, 1.15), ear = 0.85, tail = 1, legs = 1 },
	fuse_mouse = { body = rgb(196, 92, 70), belly = rgb(240, 190, 160), bodySize = V3(1.55, 1.3, 2.0), headSize = V3(1.1, 1, 1.15), ear = 0.8, tail = 1, legs = 1 },
}

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

local function head(l: Spec.List, L: Look, bodyLen: number): (number, number)
	local hz = -bodyLen / 2 - L.headSize.Z * 0.25
	local hy = L.bodySize.Y * 0.62 + 0.25
	local neck = CF(0, hy, hz + L.headSize.Z * 0.4)
	local sway = Spec.sway(0.18, 3.1, 0.7, neck)
	Spec.egg(l, L.headSize, CF(0, hy, hz), L.body, M.SmoothPlastic, { tint = true, anim = sway })
	Spec.egg(l, V3(0.6, 0.5, 0.65) * L.headSize.X, CF(0, hy - 0.15, hz - L.headSize.Z * 0.45), L.belly, M.SmoothPlastic, {
		tint = true,
		anim = sway,
	})
	Spec.ball(l, 0.24, CF(0, hy - 0.08, hz - L.headSize.Z * 0.72), PINK_DARK, M.SmoothPlastic, { anim = sway })
	for _, s in { -1, 1 } do
		Spec.ball(l, 0.22, CF(s * L.headSize.X * 0.24, hy + 0.15, hz - L.headSize.Z * 0.36), EYE, M.SmoothPlastic, { anim = sway })
	end
	return hy, hz
end

local function ears(l: Spec.List, L: Look, hy: number, hz: number, inner: boolean)
	for _, s in { -1, 1 } do
		local at = CF(s * L.headSize.X * 0.38, hy + L.headSize.Y * 0.5, hz + 0.1) * ANG(0, 0, rad(-s * 18))
		local flick = Spec.roll(0.25, 5.3, s, at * CF(0, -0.3, 0))
		Spec.egg(l, V3(0.12, L.ear, L.ear * 0.92), at * CF(0, L.ear * 0.25, 0), L.body:Lerp(PINK, 0.25), M.SmoothPlastic, {
			tint = true,
			anim = flick,
		})
		if inner then
			Spec.egg(l, V3(0.08, L.ear * 0.72, L.ear * 0.64), at * CF(0, L.ear * 0.25, -0.05), PINK, M.SmoothPlastic, { anim = flick })
		end
	end
end

local function legs(l: Spec.List, L: Look, len: number)
	local h = 0.5 * L.legs
	for _, side in { -1, 1 } do
		for i, front in { -1, 1 } do
			local x, z = side * L.bodySize.X * 0.3, front * len * 0.28
			local pivot = CF(x, h, z)
			Spec.ucyl(l, h, 0.28, CF(x, h / 2, z), L.body:Lerp(EYE, 0.25), M.SmoothPlastic, {
				anim = Spec.swing(0.7, 14, (if side * front > 0 then 0 else math.pi) + i * 0.1, pivot),
			})
		end
	end
end

local function tail(l: Spec.List, L: Look, len: number, segs: number)
	local base = CF(0, L.bodySize.Y * 0.35, len / 2 - 0.05)
	local sway = Spec.sway(0.45, 4.2, 0, base)
	local cf = base
	local segLen = 0.55 * L.tail
	for i = 1, segs do
		cf = cf * ANG(rad(-14 + i * 10), 0, 0)
		Spec.cyl(l, segLen, 0.18 - i * 0.025, cf * CF(0, 0, segLen / 2) * ANG(0, rad(90), 0), PINK, M.SmoothPlastic, { anim = sway })
		cf = cf * CF(0, 0, segLen)
	end
end

local function crown(l: Spec.List, hy: number, hz: number, L: Look)
	Spec.ucyl(l, 0.3, 0.6, CF(0, hy + L.headSize.Y * 0.55, hz + 0.05), GOLD, M.Neon, { cond = "elite" })
end

function MouseModels.build(id: string, def: any, scale: number?, elite: boolean?): { parts: Spec.List, low: Spec.List, lod: Spec.List, radius: number }
	local L = lookFor(id, def)
	local r = math.max(0.4, tonumber(if type(def) == "table" then def.radius else nil) or 1.2) * (scale or 1)
	local len = L.bodySize.Z
	local full: Spec.List = {}
	local extras = id == "crumb_slinger" or id == "fuse_mouse" or id == "chonk"

	-- body + belly
	Spec.egg(full, L.bodySize, CF(0, L.bodySize.Y * 0.62, 0.1), L.body, M.SmoothPlastic, { tint = true, anim = Spec.bob(0.05, 9) })
	Spec.egg(full, L.bodySize * V3(0.75, 0.7, 0.75), CF(0, L.bodySize.Y * 0.45, -0.05), L.belly, M.SmoothPlastic, {
		tint = true,
		anim = Spec.bob(0.05, 9),
	})
	local hy, hz = head(full, L, len)
	ears(full, L, hy, hz, not extras)
	legs(full, L, len)
	tail(full, L, len, if id == "rat_runner" then 4 else 3)

	if id == "rat_runner" then
		Spec.ucyl(full, 0.16, L.headSize.X * 1.02, CF(0, hy + 0.2, hz + 0.05) * ANG(rad(-12), 0, 0), rgb(220, 50, 45), M.Fabric)
	elseif id == "chonk" then
		Spec.wedge(full, V3(0.9, 0.55, 0.9), CF(0, L.bodySize.Y * 0.55, -len / 2 - 0.25) * ANG(0, 0, rad(90)), rgb(255, 201, 60), M.SmoothPlastic)
	elseif id == "crumb_slinger" then
		local hand = CF(0.55, L.bodySize.Y * 0.75, -len / 2 - 0.1)
		Spec.ucyl(full, 0.6, 0.1, hand, rgb(120, 80, 45), M.Wood)
		Spec.block(full, V3(0.5, 0.09, 0.09), hand * CF(0, 0.32, 0), rgb(120, 80, 45), M.Wood)
		Spec.egg(full, V3(0.7, 0.8, 0.6), CF(0, L.bodySize.Y * 1.05, 0.5), rgb(230, 210, 170), M.Fabric)
	elseif id == "fuse_mouse" then
		local bomb = CF(0, L.bodySize.Y * 1.15, 0.3)
		Spec.ball(full, 0.95, bomb, rgb(38, 36, 44), M.Metal)
		Spec.ucyl(full, 0.4, 0.1, bomb * CF(0.15, 0.6, 0) * ANG(0, 0, rad(-20)), rgb(150, 120, 80), M.Fabric)
		Spec.ball(full, 0.28, bomb * CF(0.25, 0.85, 0), rgb(255, 190, 60), M.Neon, { anim = Spec.pulse(0.6, 22) })
	end
	crown(full, hy, hz, L)

	-- low-spec: body, head, ears, one tail piece, nose, kind marker, crown
	local low: Spec.List = {}
	Spec.egg(low, L.bodySize, CF(0, L.bodySize.Y * 0.62, 0.1), L.body, M.SmoothPlastic, { tint = true })
	Spec.egg(low, L.headSize, CF(0, hy, hz), L.body, M.SmoothPlastic, { tint = true })
	for _, s in { -1, 1 } do
		Spec.egg(low, V3(0.12, L.ear, L.ear * 0.92), CF(s * L.headSize.X * 0.38, hy + L.headSize.Y * 0.62, hz + 0.1), L.body:Lerp(PINK, 0.35), M.SmoothPlastic, {
			tint = true,
		})
	end
	Spec.ball(low, 0.24, CF(0, hy - 0.08, hz - L.headSize.Z * 0.6), PINK_DARK)
	Spec.cyl(low, 1.2 * L.tail, 0.16, CF(0, L.bodySize.Y * 0.35, len / 2 + 0.5) * ANG(0, rad(90), rad(-15)), PINK, M.SmoothPlastic, {
		anim = Spec.sway(0.4, 4, 0, CF(0, L.bodySize.Y * 0.35, len / 2)),
	})
	if id == "fuse_mouse" then
		Spec.ball(low, 0.95, CF(0, L.bodySize.Y * 1.15, 0.3), rgb(38, 36, 44), M.Metal)
	elseif id == "rat_runner" then
		Spec.ucyl(low, 0.16, L.headSize.X * 1.02, CF(0, hy + 0.2, hz + 0.05), rgb(220, 50, 45), M.Fabric)
	end
	crown(low, hy, hz, L)

	-- LOD: 3 parts
	local lod: Spec.List = {}
	Spec.egg(lod, L.bodySize, CF(0, L.bodySize.Y * 0.62, 0.1), L.body, M.SmoothPlastic, { tint = true })
	Spec.egg(lod, L.headSize, CF(0, hy, hz), L.body, M.SmoothPlastic, { tint = true })
	Spec.egg(lod, V3(L.headSize.X * 1.35, L.ear * 0.8, 0.14), CF(0, hy + L.headSize.Y * 0.55, hz + 0.1), L.body:Lerp(PINK, 0.35), M.SmoothPlastic, {
		tint = true,
	})

	local k = r / 1.2 -- the unit model is a radius-1.2 mouse
	local _ = elite
	return { parts = Spec.scaled(full, k), low = Spec.scaled(low, k), lod = Spec.scaled(lod, k), radius = r }
end

return MouseModels
