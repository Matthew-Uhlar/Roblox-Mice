--!strict
-- BotModel (R4 Graphics): a detailed part-built elephant hero for party-fill bots
-- (GDD-v2 §6). BotService (R2) calls it instead of building its own model.
--
--   BotModel.build(spec, squad?, opts?) -> Model
--       spec = {id, name, classId, isBot?, skinId?}
--       opts.showcase = true: a lobby statue (no bot tag, no glow ring, no BotId)
--
-- v3: ~95 smooth parts (balls / eggs / cylinders), rigged: see finish(). The
-- model is built around the origin (ground at Y = 0, facing -Z), and
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

-- Rig (v3): every visible part is welded to the anchored Root with a Weld
-- named "RigWeld" (C0 = its rest offset in model space), so BotService's
-- PivotTo moves ONE anchored part (only the Root's CFrame replicates) and the
-- client poses the bones by rewriting C0 locally (Visuals/BotAnimator). Each
-- part names its bone in the "Bone" attribute; the model stores the skeleton as
-- attributes "Bone_<name>" (CFrame pivot, model space) and "BoneParent_<name>".
local function finish(model: Model, root: BasePart)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			if d ~= root then
				d.Anchored = false
				local w = Instance.new("Weld")
				w.Name = "RigWeld"
				w.Part0 = root
				w.Part1 = d
				w.C0 = root.CFrame:ToObjectSpace(d.CFrame)
				w.Parent = d
			else
				d.Anchored = true
			end
			if d.Name ~= "Root" and d:GetAttribute("Glow") == nil then
				d:SetAttribute("BaseColor", d.Color)
				d:SetAttribute("BaseTransparency", d.Transparency)
			end
		end
	end
end

BotModel.BONES = {
	body = { CF(0, 3.3, 0.3), nil },
	head = { CF(0, 4.6, -1.9), "body" },
	earL = { CF(-1.85, 5.6, -2.55), "head" },
	earR = { CF(1.85, 5.6, -2.55), "head" },
	trunk = { CF(0, 4.35, -4.55), "head" },
	trunk2 = { CF(0, 3.25, -5.05), "trunk" },
	trunk3 = { CF(0, 2.35, -5.2), "trunk2" },
	tail = { CF(0, 4.0, 3.05), "body" },
	legFL = { CF(-1.35, 2.5, -1.5), nil },
	legFR = { CF(1.35, 2.5, -1.5), nil },
	legBL = { CF(-1.35, 2.5, 1.9), nil },
	legBR = { CF(1.35, 2.5, 1.9), nil },
}

local function tagBone(parts: { BasePart }, bone: string)
	for _, p in parts do
		p:SetAttribute("Bone", bone)
	end
end

-- Builds the elephant body into `m` (chibi proportions: big round head, flappy
-- ears, glossy eyes with two highlights, a curled trunk holding the class
-- weapon, stubby rounded legs). Returns the head part.
local function body(m: Model, colors: any, sash: Color3, classId: string, desat: boolean): BasePart
	local skin = if desat then SKIN else colors.body:Lerp(SKIN, 0.55)
	local dark = skin:Lerp(SKIN_DARK, 0.6)
	local light = skin:Lerp(rgb(255, 255, 255), 0.12)
	local cur: { BasePart } = {}
	local function grab(p: BasePart): BasePart
		table.insert(cur, p)
		return p
	end
	local function bone(name: string)
		tagBone(cur, name)
		table.clear(cur)
	end
	-- legs: rounded columns with soft feet and toenails
	for _, side in { -1, 1 } do
		for _, front in { -1, 1 } do
			local x, z = side * 1.35, if front < 0 then -1.5 else 1.9
			grab(Build.egg(m, V3(1.55, 2.7, 1.6), CF(x, 1.35, z), skin, M.SmoothPlastic, { name = "Leg" }))
			grab(Build.ucyl(m, 0.45, 1.75, CF(x, 0.22, z - 0.05), dark, M.SmoothPlastic, { name = "Foot" }))
			if front < 0 then
				for k = -1, 1 do
					grab(Build.ball(m, 0.36, CF(x + k * 0.42, 0.26, z - 0.78), TUSK, M.SmoothPlastic, {
						name = "Toe",
						shadow = false,
					}))
				end
			end
			bone("leg" .. (if front < 0 then "F" else "B") .. (if side < 0 then "L" else "R"))
		end
	end
	-- torso + belly + rump, saddle blanket and sash
	grab(Build.egg(m, V3(4.5, 3.9, 5.6), CF(0, 3.45, 0.4), skin, M.SmoothPlastic, { name = "Body" }))
	grab(Build.egg(m, V3(3.7, 2.7, 4.5), CF(0, 2.75, 0.1), light, M.SmoothPlastic, { name = "Belly" }))
	grab(Build.egg(m, V3(4.6, 1.3, 3.4), CF(0, 5.1, 0.7), colors.body, M.Fabric, { name = "Saddle" }))
	grab(Build.egg(m, V3(4.75, 0.5, 3.6), CF(0, 4.6, 0.7), colors.accent, M.Fabric, { name = "SaddleTrim" }))
	for _, s in { -1, 1 } do
		grab(Build.ball(m, 0.5, CF(s * 2.2, 4.55, 0.7), colors.trim, M.Metal, { name = "Stud", shadow = false }))
	end
	grab(Build.egg(m, V3(4.75, 0.55, 1.15), CF(0, 3.6, -1.35) * ANG(0, 0, rad(32)), sash, M.Fabric, { name = "Sash" }))
	grab(Build.ball(m, 0.75, CF(0, 3.65, -2.05), colors.trim, M.Metal, { name = "Buckle", shadow = false }))
	for _, p in ClassGear.back(m, CF(0, 5.7, 1.8) * ANG(rad(-90), 0, 0), 2.6, classId, colors) do
		grab(p)
	end
	bone("body")
	-- tail with a tuft
	grab(Build.ucyl(m, 1.6, 0.32, CF(0, 3.45, 3.55) * ANG(rad(-35), 0, 0), skin, M.SmoothPlastic, { name = "Tail" }))
	grab(Build.egg(m, V3(0.55, 0.85, 0.55), CF(0, 2.75, 4.05), dark, M.Fabric, { name = "TailTuft", shadow = false }))
	bone("tail")
	-- head: a big round dome, puffy cheeks, brow
	local head = grab(Build.ball(m, 4.1, CF(0, 5.4, -2.95), skin, M.SmoothPlastic, { name = "Head" }))
	grab(Build.egg(m, V3(3.7, 2.3, 2.4), CF(0, 4.55, -3.45), skin, M.SmoothPlastic, { name = "Cheeks" }))
	for _, side in { -1, 1 } do
		-- glossy eyes: white, big pupil, two highlights; rosy blush
		local e = CF(side * 0.82, 5.6, -4.72) * ANG(0, rad(side * -12), 0)
		grab(Build.egg(m, V3(0.95, 1.2, 0.5), e, rgb(255, 255, 255), M.SmoothPlastic, { name = "Eye", shadow = false }))
		grab(Build.egg(m, V3(0.66, 0.88, 0.32), e * CF(0, -0.06, -0.2), rgb(30, 28, 40), M.SmoothPlastic, {
			name = "Pupil",
			shadow = false,
		}))
		grab(Build.ball(m, 0.28, e * CF(side * -0.14, 0.18, -0.36), rgb(255, 255, 255), M.Neon, {
			name = "Glint",
			shadow = false,
		}))
		grab(Build.ball(m, 0.13, e * CF(side * 0.12, -0.2, -0.36), rgb(255, 255, 255), M.Neon, {
			name = "Glint",
			shadow = false,
		}))
		grab(Build.egg(m, V3(0.8, 0.4, 0.25), CF(side * 1.45, 4.75, -4.25) * ANG(0, rad(side * -30), 0), EAR_IN, M.SmoothPlastic, {
			name = "Blush",
			shadow = false,
			transparency = 0.3,
		}))
		grab(Build.egg(m, V3(1.2, 0.3, 0.5), CF(side * 0.85, 6.45, -4.35) * ANG(0, 0, rad(side * -10)), dark, M.SmoothPlastic, {
			name = "Brow",
			shadow = false,
		}))
	end
	-- tusks
	for _, side in { -1, 1 } do
		local tk = CF(side * 0.9, 4.05, -4.55) * ANG(rad(-55), 0, rad(side * -14))
		grab(Build.ucyl(m, 1.1, 0.36, tk * CF(0, 0.5, 0), TUSK, M.Marble, { name = "Tusk" }))
		grab(Build.ball(m, 0.34, tk * CF(0, 1.05, 0), TUSK, M.Marble, { name = "TuskTip", shadow = false }))
	end
	for _, p in ClassGear.hat(m, CF(0, 7.35, -2.95), 3.0, classId, colors) do
		grab(p)
	end
	for _, p in ClassGear.face(m, CF(0, 5.55, -5.0), 3.0, classId, colors) do
		grab(p)
	end
	bone("head")
	-- ears: big rounded flaps with pink insides, hinged at the head
	for _, side in { -1, 1 } do
		local ear = CF(side * 2.65, 5.05, -2.45) * ANG(0, rad(side * -30), rad(side * 12))
		grab(Build.egg(m, V3(3.5, 4.0, 0.42), ear, skin, M.SmoothPlastic, { name = "Ear" }))
		grab(Build.egg(m, V3(2.6, 3.0, 0.3), ear * CF(0, -0.12, -0.12), EAR_IN, M.SmoothPlastic, {
			name = "EarInner",
			shadow = false,
		}))
		bone(if side < 0 then "earL" else "earR")
	end
	-- trunk: smooth ball chain down from the face, curling up at the tip
	local path = {
		{ CF(0, 4.35, -4.75), 1.35, "trunk" },
		{ CF(0, 3.8, -5.0), 1.2, "trunk" },
		{ CF(0, 3.25, -5.1), 1.08, "trunk2" },
		{ CF(0, 2.75, -5.2), 0.96, "trunk2" },
		{ CF(0, 2.35, -5.35), 0.86, "trunk3" },
		{ CF(0, 2.15, -5.75), 0.78, "trunk3" },
	}
	local last = ""
	for i, seg in path do
		if seg[3] ~= last and last ~= "" then
			bone(last)
		end
		last = seg[3]
		grab(Build.ball(m, seg[2], seg[1], skin, M.SmoothPlastic, { name = "Trunk", shadow = i == 1 }))
		local nxt = path[i + 1]
		if nxt then
			local a, b = seg[1].Position, nxt[1].Position
			local mid = (a + b) / 2
			local len = (b - a).Magnitude
			grab(Build.cyl(m, len, (seg[2] + nxt[2]) / 2 * 0.95, CFrame.lookAt(mid, b) * ANG(0, rad(90), 0), skin, M.SmoothPlastic, {
				name = "Trunk",
				shadow = false,
			}))
		end
	end
	local tip = CF(0, 2.3, -6.15) * ANG(rad(-70), 0, 0)
	grab(Build.ucyl(m, 0.3, 0.8, tip, dark, M.SmoothPlastic, { name = "TrunkTip", shadow = false }))
	-- the class weapon, gripped in the trunk curl
	local weapon = ClassGear.weapon(m, CF(0, 2.35, -6.0) * ANG(rad(-35), 0, 0), 1.6, classId, colors)
	for _, p in weapon do
		p.Name = "Weapon"
		grab(p)
	end
	bone(last)
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
		-- the squad ground ring is drawn by the client (Visuals/HeroFx), like heroes'
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
	for name, b in BotModel.BONES do
		model:SetAttribute("Bone_" .. name, b[1])
		if b[2] then
			model:SetAttribute("BoneParent_" .. name, b[2])
		end
	end
	model:SetAttribute("RigStyle", "elephant")
	finish(model, root)
	model.WorldPivot = CF(0, 0, 0)
	return model
end

return BotModel
