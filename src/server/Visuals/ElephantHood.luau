--!strict
-- ElephantHood (v4, team G): makes a player's avatar read as an elephant during
-- runs (V4-B S1-2; the store sells "Elephant Heroes").
--
--   ElephantHood.build(folder, head: BasePart) -> {BasePart}
--       big flappy ears (grey ellipsoids with a pink inner disc), a curled
--       4-segment trunk and two small tusks, sized from the head (h = head
--       height) and posed at the head's CURRENT frame. The caller welds the
--       returned parts to the head (HeroDecor.weldAll), so they follow it.
--   ElephantHood.tint(character, on: boolean)
--       on: BodyColors -> herd grey #9AA3AD (originals saved as attributes on
--       the BodyColors instance); off: originals restored. Idempotent.
--   ElephantHood.GREY, ElephantHood.EAR_INNER
--
-- Shapes follow BotModel (the bots' ears / trunk) so heroes and bots are one
-- family; the ears are 15% larger and tilted up-out so they still read as an
-- elephant from the top-down camera.

local Build = require(script.Parent.Build)

local ElephantHood = {}

ElephantHood.GREY = Color3.fromRGB(154, 163, 173) -- #9AA3AD herd grey
ElephantHood.GREY_DARK = Color3.fromRGB(128, 136, 148)
ElephantHood.EAR_INNER = Color3.fromRGB(242, 167, 181) -- #F2A7B5
ElephantHood.TUSK = Color3.fromRGB(250, 246, 232)

local CF = CFrame.new
local ANG = CFrame.Angles
local V3 = Vector3.new
local rad = math.rad
local M = Enum.Material

function ElephantHood.build(folder: Instance, head: BasePart): { BasePart }
	local h = math.clamp(head.Size.Y, 0.6, 3)
	local w = math.clamp(head.Size.X, 0.6, 3)
	local hcf = head.CFrame
	local parts: { BasePart } = {}
	local function keep(p: BasePart): BasePart
		p.Name = "Elephant" .. p.Name
		table.insert(parts, p)
		return p
	end
	-- ears: flat ellipsoids beside the head, swept back 25 deg, tipped up-out 14 deg
	for _, s in { -1, 1 } do
		local ear = hcf * CF(s * (w * 0.5 + 0.5 * h), 0.08 * h, 0.12 * h) * ANG(0, s * rad(-25), s * rad(-14))
		keep(Build.egg(folder, V3(1.45 * h, 1.7 * h, 0.22 * h), ear, ElephantHood.GREY, M.SmoothPlastic, {
			name = "Ear",
		}))
		keep(
			Build.egg(
				folder,
				V3(1.05 * h, 1.25 * h, 0.1 * h),
				ear * CF(s * 0.05 * h, -0.04 * h, -0.08 * h),
				ElephantHood.EAR_INNER,
				M.SmoothPlastic,
				{ name = "EarInner", shadow = false }
			)
		)
	end
	-- trunk: 4 balls from the face, curling down and then forward
	local trunk = {
		{ 0, -0.12, -0.56, 0.6 },
		{ 0, -0.42, -0.72, 0.5 },
		{ 0, -0.7, -0.78, 0.42 },
		{ 0, -0.9, -0.95, 0.36 },
	}
	for i, t in trunk do
		keep(
			Build.ball(
				folder,
				t[4] * h,
				hcf * CF(t[1] * h, t[2] * h, t[3] * h),
				if i == #trunk then ElephantHood.GREY_DARK else ElephantHood.GREY,
				M.SmoothPlastic,
				{ name = "Trunk" }
			)
		)
	end
	-- tusks: small ivory wedges either side of the trunk root, pointing forward
	for _, s in { -1, 1 } do
		keep(
			Build.wedge(
				folder,
				V3(0.12 * h, 0.14 * h, 0.4 * h),
				hcf * CF(s * 0.26 * h, -0.36 * h, -0.62 * h) * ANG(rad(-20), 0, 0),
				ElephantHood.TUSK,
				M.SmoothPlastic,
				{ name = "Tusk", shadow = false }
			)
		)
	end
	return parts
end

local PROPS = {
	"HeadColor3",
	"LeftArmColor3",
	"RightArmColor3",
	"LeftLegColor3",
	"RightLegColor3",
	"TorsoColor3",
}

function ElephantHood.tint(character: Model, on: boolean)
	local bc = character:FindFirstChildOfClass("BodyColors")
	if not bc then
		if not on then
			return
		end
		bc = Instance.new("BodyColors")
		assert(bc, "BodyColors")
		for _, prop in PROPS do
			-- no BodyColors: remember the parts' own colour (head stands in)
			local head = character:FindFirstChild("Head")
			local c = if head and head:IsA("BasePart") then head.Color else ElephantHood.GREY
			bc:SetAttribute("TF_" .. prop, c)
		end
		bc.Parent = character
	end
	local saved = bc:GetAttribute("TF_Saved") == true
	if on then
		if not saved then
			for _, prop in PROPS do
				if bc:GetAttribute("TF_" .. prop) == nil then
					bc:SetAttribute("TF_" .. prop, (bc :: any)[prop])
				end
			end
			bc:SetAttribute("TF_Saved", true)
		end
		for _, prop in PROPS do
			(bc :: any)[prop] = ElephantHood.GREY
		end
	elseif saved then
		for _, prop in PROPS do
			local c = bc:GetAttribute("TF_" .. prop)
			if typeof(c) == "Color3" then
				(bc :: any)[prop] = c
			end
			bc:SetAttribute("TF_" .. prop, nil)
		end
		bc:SetAttribute("TF_Saved", nil)
	end
end

return ElephantHood
