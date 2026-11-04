--!strict
-- BotModel (R4 Graphics): a detailed part-built elephant hero for party-fill bots
-- (GDD-v2 §6). BotService (R2) calls it instead of building its own model.
--
--   BotModel.build(spec, squad?, opts?) -> Model
--       spec = {id, name, classId, isBot?, skinId?}
--       opts.showcase = true: a lobby statue (no bot tag, no glow ring, no BotId)
--
-- The model is ~50 parts, built around the origin (ground at Y = 0, facing -Z), and
-- returned UNPARENTED (the caller parents it). Contract kept from BotService:
--   * attributes IsBot, BotId, ClassId, DisplayName (+ Squad)
--   * PrimaryPart = "Root" (invisible, at the origin) so PivotTo(cf) places the
--     feet at cf; Head is a part named "Head" with a BillboardGui "NameTag"
--     holding TextLabels "Name" and "BotTag" (🤖 BOT, never hidden).
--   * every VISIBLE part carries attributes BaseColor (Color3) and
--     BaseTransparency (number): mode changes (downed / dead tint) should only
--     touch parts that have BaseColor and restore BaseTransparency, so the
--     invisible Root and the glow ring keep their look.
--   * a disabled Highlight "SquadHighlight" (the client enables it on enemy squads).
-- Bots are drawn slightly desaturated (STYLE.md) so they never pass as players.

local Build = require(script.Parent.Build)
local ClassGear = require(script.Parent.ClassGear)

local BotModel = {}

BotModel.TAG_COLOR = Color3.fromRGB(90, 210, 255)

local rad = math.rad
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local M = Enum.Material
local rgb = Color3.fromRGB

local SKIN = rgb(158, 160, 172)
local SKIN_DARK = rgb(132, 134, 148)
local EAR_IN = rgb(236, 170, 182)
local TUSK = rgb(250, 246, 232)

type Spec = { id: number, name: string, classId: string, isBot: boolean?, skinId: string? }

local SQUAD_COLORS = { rgb(255, 200, 60), rgb(245, 240, 220), rgb(80, 150, 255), rgb(235, 70, 60) }

local function squadColor(squad: number?): Color3?
	if not squad then
		return nil
	end
	local ok, Squads = pcall(function()
		local util = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):FindFirstChild("Util")
		local inst = util and util:FindFirstChild("Squads")
		return if inst and inst:IsA("ModuleScript") then require(inst) :: any else nil
	end)
	local s = ok and Squads and type(Squads.get) == "function" and Squads.get(squad)
	return Build.rgb(s and s.color, SQUAD_COLORS[squad] or rgb(255, 200, 60))
end

local function finish(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			if d.Name ~= "Root" and d:GetAttribute("Glow") == nil then
				d:SetAttribute("BaseColor", d.Color)
				d:SetAttribute("BaseTransparency", d.Transparency)
			end
		end
	end
end

-- Builds the elephant body into `m`. Returns the head part.
local function body(m: Model, colors: any, sash: Color3, classId: string, desat: boolean): BasePart
	local skin = if desat then SKIN else colors.body:Lerp(SKIN, 0.55)
	local dark = skin:Lerp(SKIN_DARK, 0.6)
	-- torso + belly + rump
	Build.egg(m, V3(4.4, 3.6, 6.2), CF(0, 3.5, 0.2), skin, M.SmoothPlastic, { name = "Body" })
	Build.egg(m, V3(3.6, 2.4, 4.6), CF(0, 2.7, 0), skin:Lerp(rgb(255, 255, 255), 0.08), M.SmoothPlastic, { name = "Belly" })
	Build.egg(m, V3(4, 3.2, 2.6), CF(0, 3.6, 2.4), skin, M.SmoothPlastic, { name = "Rump" })
	-- legs with toenails
	for _, side in { -1, 1 } do
		for _, front in { -1, 1 } do
			local x, z = side * 1.35, front * 2.0 + 0.2
			Build.ucyl(m, 2.6, 1.5, CF(x, 1.3, z), skin, M.SmoothPlastic, { name = "Leg" })
			Build.ucyl(m, 0.4, 1.7, CF(x, 0.2, z), dark, M.SmoothPlastic, { name = "Foot" })
			for k = -1, 1 do
				Build.ball(m, 0.32, CF(x + k * 0.38, 0.22, z - 0.75), TUSK, M.SmoothPlastic, { name = "Toe", shadow = false })
			end
		end
	end
	-- head, cheeks, brow
	local head = Build.ball(m, 3.6, CF(0, 5.1, -3.3), skin, M.SmoothPlastic, { name = "Head" })
	Build.egg(m, V3(3.4, 2, 2.2), CF(0, 4.3, -3.9), skin, M.SmoothPlastic, { name = "Cheeks" })
	Build.egg(m, V3(2.8, 0.7, 1.2), CF(0, 6.1, -4.5), dark, M.SmoothPlastic, { name = "Brow" })
	-- ears: big flaps with pink inner
	for _, side in { -1, 1 } do
		local ear = CF(side * 2.3, 5.2, -2.6) * ANG(0, rad(side * 28), rad(side * -8))
		Build.egg(m, V3(0.5, 3.8, 3.4), ear, skin, M.SmoothPlastic, { name = "Ear" })
		Build.egg(m, V3(0.3, 3.0, 2.6), ear * CF(side * -0.18, -0.1, -0.1), EAR_IN, M.SmoothPlastic, { name = "EarInner", shadow = false })
	end
	-- eyes: white, pupil, highlight
	for _, side in { -1, 1 } do
		local e = CF(side * 0.85, 5.45, -4.95)
		Build.ball(m, 0.85, e, rgb(255, 255, 255), M.SmoothPlastic, { name = "Eye", shadow = false })
		Build.ball(m, 0.5, e * CF(0, -0.02, -0.25), rgb(25, 25, 35), M.SmoothPlastic, { name = "Pupil", shadow = false })
		Build.ball(m, 0.18, e * CF(side * -0.1, 0.12, -0.42), rgb(255, 255, 255), M.Neon, { name = "Glint", shadow = false })
	end
	-- trunk: 5 tapering segments curling forward and up, with a tip
	local t = CF(0, 4.4, -4.95) * ANG(rad(-75), 0, 0)
	for i = 1, 5 do
		local d = 1.25 - i * 0.13
		Build.ucyl(m, 1.0, d, t * CF(0, 0.45, 0), skin, M.SmoothPlastic, { name = "Trunk" })
		Build.ball(m, d, t * CF(0, 0.95, 0), skin, M.SmoothPlastic, { name = "TrunkJoint", shadow = false })
		t = t * CF(0, 0.95, 0) * ANG(rad(if i < 4 then -12 else 28), 0, 0)
	end
	Build.ucyl(m, 0.25, 0.7, t * CF(0, 0.05, 0), dark, M.SmoothPlastic, { name = "TrunkTip", shadow = false })
	-- tusks
	for _, side in { -1, 1 } do
		local tk = CF(side * 0.85, 3.9, -4.7) * ANG(rad(-60), 0, rad(side * -12))
		Build.ucyl(m, 1.3, 0.38, tk * CF(0, 0.6, 0), TUSK, M.Marble, { name = "Tusk" })
		Build.ball(m, 0.36, tk * CF(0, 1.25, 0), TUSK, M.Marble, { name = "TuskTip", shadow = false })
	end
	-- tail with a tuft
	Build.ucyl(m, 1.8, 0.3, CF(0, 3.6, 3.75) * ANG(rad(-35), 0, 0), skin, M.SmoothPlastic, { name = "Tail" })
	Build.egg(m, V3(0.5, 0.8, 0.5), CF(0, 2.8, 4.3), dark, M.Fabric, { name = "TailTuft", shadow = false })
	-- squad sash (diagonal band with a buckle) and saddle cloth in class colours
	Build.block(m, V3(4.7, 0.6, 1.1), CF(0, 3.7, -1.2) * ANG(0, 0, rad(35)), sash, M.Fabric, { name = "Sash" })
	Build.block(m, V3(4.7, 0.6, 1.1), CF(0, 3.7, -1.2) * ANG(0, 0, rad(-35)), sash, M.Fabric, { name = "Sash" })
	Build.block(m, V3(0.7, 0.7, 0.3), CF(0, 3.7, -1.8), colors.trim, M.Metal, { name = "Buckle", shadow = false })
	Build.egg(m, V3(4.6, 1.2, 3.2), CF(0, 5.05, 0.6), colors.body, M.Fabric, { name = "Saddle" })
	Build.block(m, V3(4.65, 0.3, 3.0), CF(0, 4.6, 0.6), colors.accent, M.Fabric, { name = "SaddleTrim" })
	-- class gear: hat on the head, item on the back
	local top = CF(0, 6.9, -3.3)
	ClassGear.hat(m, top, 3.0, classId, colors)
	ClassGear.face(m, CF(0, 5.1, -5.05), 3.0, classId, colors)
	ClassGear.back(m, CF(0, 5.6, 1.8) * ANG(rad(-90), 0, 0) * ANG(0, 0, 0), 2.6, classId, colors)
	return head
end

local function nameTag(head: BasePart, spec: Spec)
	local gui = Instance.new("BillboardGui")
	gui.Name = "NameTag"
	gui.Adornee = head
	gui.Size = UDim2.fromOffset(200, 52)
	gui.StudsOffset = Vector3.new(0, 3.6, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 160
	gui.ResetOnSpawn = false

	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, 0, 0.55, 0)
	name.Font = Enum.Font.FredokaOne
	name.TextScaled = true
	name.TextColor3 = Color3.new(1, 1, 1)
	name.TextStrokeTransparency = 0.3
	name.Text = spec.name
	name.Parent = gui

	local tag = Instance.new("TextLabel")
	tag.Name = "BotTag"
	tag.AnchorPoint = Vector2.new(0.5, 0)
	tag.Position = UDim2.new(0.5, 0, 0.58, 0)
	tag.Size = UDim2.new(0.5, 0, 0.42, 0)
	tag.BackgroundColor3 = Color3.fromRGB(20, 50, 80)
	tag.BackgroundTransparency = 0.15
	tag.Font = Enum.Font.FredokaOne
	tag.TextScaled = true
	tag.TextColor3 = BotModel.TAG_COLOR
	tag.Text = "🤖 BOT"
	tag.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = tag
	gui.Parent = head
end

function BotModel.build(spec: Spec, squad: number?, opts: { showcase: boolean? }?): Model
	local showcase = opts ~= nil and opts.showcase == true
	local model = Instance.new("Model")
	model.Name = if showcase then "Showcase_" .. tostring(spec.classId) else "Bot_" .. tostring(-spec.id)
	if not showcase then
		model:SetAttribute("IsBot", true)
		model:SetAttribute("BotId", spec.id)
		model:SetAttribute("DisplayName", spec.name)
	end
	model:SetAttribute("ClassId", spec.classId)
	if squad then
		model:SetAttribute("Squad", squad)
	end

	local root = Build.block(model, V3(1, 1, 1), CF(0, 0, 0), Color3.new(1, 1, 1), M.SmoothPlastic, {
		name = "Root",
		transparency = 1,
		shadow = false,
	})
	model.PrimaryPart = root

	local colors = ClassGear.colors(spec.classId, spec.skinId)
	local sash = squadColor(squad) or colors.accent
	local head = body(model, colors, sash, spec.classId, not showcase)

	if not showcase then
		-- squad glow ring at the feet + soft light
		local ring = Build.ucyl(model, 0.1, 6.4, CF(0, 0.08, 0), sash, M.Neon, {
			name = "GlowRing",
			transparency = 0.55,
			shadow = false,
		})
		ring:SetAttribute("Glow", true)
		Build.light(ring, sash, 10, 0.8)
		nameTag(head, spec)
		local hl = Instance.new("Highlight")
		hl.Name = "SquadHighlight"
		hl.Adornee = model
		hl.Enabled = false
		hl.DepthMode = Enum.HighlightDepthMode.Occluded
		hl.FillTransparency = 0.85
		hl.OutlineTransparency = 0.1
		hl.Parent = model
	end
	finish(model)
	model.WorldPivot = CF(0, 0, 0)
	return model
end

return BotModel
