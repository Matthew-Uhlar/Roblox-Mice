--!strict
-- HeroDecor (R4 Graphics, GDD-v2 §6 Characters): class gear on player avatars.
--
--   HeroDecor.apply(character, classId, skinId?, squad?)
--       Idempotent: removes its previous decor first, so CosmeticsService can call
--       it on every redraw. skinId nil (or ClassSkins.DEFAULT_ID) = the class's
--       default look.
--   HeroDecor.clear(character)
--
-- Builds, welded to the avatar (unanchored, massless, non-colliding parts in the
-- folder "TrunkfallHeroDecor"):
--   * the class hat (or the skin's head / face / aura accessory instead),
--   * class face gear (Fizzante's goggles) when the skin adds no face piece,
--   * the class back item (shield, water tank, quiver, rapier, cleavers, wings,
--     soda pack) and the skin's back / neck accessory,
--   * a sash across the torso in the squad colour (skin accent when no squad).
-- Skin colours {body, accent, trim} and the accessory id come from
-- Config/ClassSkins (via ClassGear). It also adds a disabled Highlight named
-- "SquadHighlight" and sets the character attribute "Squad": the CLIENT decides
-- who sees it and in which colour (FxController enables it on enemy-squad heroes).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Build = require(script.Parent.Build)
local ClassGear = require(script.Parent.ClassGear)

local HeroDecor = {}

HeroDecor.FOLDER = "TrunkfallHeroDecor"
HeroDecor.HIGHLIGHT = "SquadHighlight"

local CF = CFrame.new
local ANG = CFrame.Angles
local V3 = Vector3.new

local Squads: any = nil
do
	local ok, mod = pcall(function()
		local util = ReplicatedStorage:WaitForChild("Shared"):FindFirstChild("Util")
		local inst = util and util:FindFirstChild("Squads")
		return if inst and inst:IsA("ModuleScript") then require(inst) :: any else nil
	end)
	Squads = if ok then mod else nil
end

local function squadColor(squad: number?): Color3?
	if squad and Squads and type(Squads.get) == "function" then
		local s = Squads.get(squad)
		if s then
			return Build.rgb(s.color, Color3.new(1, 1, 1))
		end
	end
	return nil
end

local function weldAll(parts: { BasePart }, anchor: BasePart, folder: Instance)
	for _, p in parts do
		p.Anchored = false
		p.Massless = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		local w = Instance.new("Weld")
		w.Part0 = anchor
		w.Part1 = p
		w.C0 = anchor.CFrame:ToObjectSpace(p.CFrame)
		w.Parent = p
		p.Parent = folder
	end
end

function HeroDecor.clear(character: Model)
	local old = character:FindFirstChild(HeroDecor.FOLDER)
	if old then
		old:Destroy()
	end
	local hl = character:FindFirstChild(HeroDecor.HIGHLIGHT)
	if hl then
		hl:Destroy()
	end
end

function HeroDecor.apply(character: Model, classId: string, skinId: string?, squad: number?)
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		return
	end
	HeroDecor.clear(character)
	local head = character:FindFirstChild("Head")
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if not head or not head:IsA("BasePart") then
		return
	end
	local cid = if type(classId) == "string" then classId else "elephante"
	local sid = if type(skinId) == "string" and skinId ~= "default" then skinId else nil
	local colors = ClassGear.colors(cid, sid)
	local accId, attach = ClassGear.accessoryOf(sid)

	local folder = Instance.new("Folder")
	folder.Name = HeroDecor.FOLDER

	-- Anchor frames in world space at the avatar's current pose.
	local s = math.clamp(head.Size.Y, 0.6, 3)
	local hcf = head.CFrame
	local top = hcf * CF(0, head.Size.Y / 2, 0)
	local face = hcf * CF(0, 0, -head.Size.Z / 2)
	local tp: BasePart? = if torso and torso:IsA("BasePart") then torso else nil
	local back = if tp then tp.CFrame * CF(0, tp.Size.Y * 0.15, tp.Size.Z / 2) * ANG(0, math.pi, 0) else hcf * CF(0, -s, s * 0.5)
	local neck = if tp then tp.CFrame * CF(0, tp.Size.Y / 2, 0) else hcf * CF(0, -head.Size.Y / 2, 0)
	local anchors = { top = top, face = face, back = back, neck = neck }

	local headParts: { BasePart } = {}
	local bodyParts: { BasePart } = {}
	local function into(list: { BasePart }, parts: { BasePart })
		for _, p in parts do
			table.insert(list, p)
		end
	end

	-- Head: the skin accessory replaces the class hat (head / aura), face pieces add.
	if accId and (attach == "head" or attach == "aura") then
		into(headParts, ClassGear.accessory(folder, anchors, s, accId, colors))
	else
		into(headParts, ClassGear.hat(folder, top, s, cid, colors))
	end
	if accId and attach == "face" then
		into(headParts, ClassGear.accessory(folder, anchors, s, accId, colors))
	else
		into(headParts, ClassGear.face(folder, face, s, cid, colors))
	end
	-- Body: class back item always; back / neck accessories add to it.
	if tp then
		into(bodyParts, ClassGear.back(folder, back, s, cid, colors))
		if accId and (attach == "back" or attach == "neck") then
			into(bodyParts, ClassGear.accessory(folder, anchors, s, accId, colors))
		end
		-- Sash across the torso (front and back) in the squad colour.
		local sash = squadColor(squad) or colors.accent
		local w = math.sqrt(tp.Size.X ^ 2 + tp.Size.Y ^ 2) * 1.02
		local band = Build.block(folder, V3(w, 0.28 * s, tp.Size.Z + 0.12), tp.CFrame * ANG(0, 0, math.rad(48)), sash, Enum.Material.Fabric, {
			name = "Sash",
		})
		table.insert(bodyParts, band)
		local buckle = Build.block(folder, V3(0.3, 0.3, 0.1) * s, tp.CFrame * CF(0, 0, -tp.Size.Z / 2 - 0.07), colors.trim, Enum.Material.Metal, {
			name = "Buckle",
		})
		table.insert(bodyParts, buckle)
	end

	weldAll(headParts, head, folder)
	if tp then
		weldAll(bodyParts, tp, folder)
	end
	folder.Parent = character

	local hl = Instance.new("Highlight")
	hl.Name = HeroDecor.HIGHLIGHT
	hl.Adornee = character
	hl.Enabled = false
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.FillTransparency = 0.85
	hl.OutlineTransparency = 0.1
	hl.Parent = character
	if squad then
		character:SetAttribute("Squad", squad)
	end
	character:SetAttribute("HeroClass", cid)
end

return HeroDecor
