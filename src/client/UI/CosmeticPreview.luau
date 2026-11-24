--!strict
-- CosmeticPreview (iteration 6, team Preview, client): a ViewportFrame showroom
-- that shows YOUR hero wearing a skin / cosmetic before you buy or equip it.
--
--   local p = CosmeticPreview.panel(parent, props?, opts?)   -- the side panel
--       p.select(ref, info?)   tap / click: try the item on (sticks)
--       p.hover(ref)           mouse over a card: try it on while hovered
--       p.unhover()            back to the selected item
--       p.clear()              back to "your hero" (nothing tried on)
--       p.setMode("side" | "overlay")   overlay: a sheet over the list (narrow
--                                       screens); it opens on select, ✕ folds it
--       p.setActive(on)        the owner screen opened / closed: closed = paused
--                              and the 3-D models are released (no leaks)
--       p.destroy()
--     info = { title?, status?, buttons? = { {text, color, enabled, onClick} } }
--   CosmeticPreview.bindCard(p, card, ref, info?)  hover + tap on a list card
--   CosmeticPreview.showroom(parent) -> Showroom   just the 3-D view (p uses it)
--
-- The hero is built by the SAME code the game uses: ReplicatedStorage.HeroVisuals
-- .BotModel (server Visuals, copied there by Boot) in Herd Suit mode, with your
-- class, skin and Ascension look. Fallbacks: a clone of the lobby statue
-- "Showcase_<class>" (body recoloured for a skin), then a 10-part stand-in.
-- Hats are built like the server's CosmeticsService (Visuals/CosmeticParts).
-- ViewportFrames draw no Trails / Highlights / Billboards, so a trail is a
-- looping ribbon sweep, a tint blends the part colours, and nametags, titles,
-- name dyes, chat tags and Prestige frames are UI overlays on the view.
--
-- Motion (Util/PreviewRecipe.motion): slow turntable, drag to rotate, the
-- BotAnimator idle (plus a swing now and then). Effects "off" = still hero.
-- Paused whenever the view is hidden; at most CACHE built heroes are kept.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local State = require(Client.Controllers.State)
local Defs = require(Client.Util.Defs)
local PreviewRecipe = require(Client.Util.PreviewRecipe)
local CosmeticParts = require(Client.Visuals.CosmeticParts)

local CosmeticPreview = {}

local C = Theme.C
local make = Theme.make

local function visual(name: string): any
	local ok, mod = pcall(function()
		local inst = Client.Visuals:FindFirstChild(name)
		return if inst and inst:IsA("ModuleScript") then require(inst) :: any else nil
	end)
	return if ok then mod else nil
end
local Rig = visual("Rig")
local BotAnimator = visual("BotAnimator")
local PrestigeFrames = visual("PrestigeFrames")

CosmeticPreview.CACHE = 3 -- built heroes kept while the screen is open
CosmeticPreview.HOVER_DELAY = 0.12 -- s of hover before a card is tried on
CosmeticPreview.DRAG_RESUME = 1.6 -- s after a drag before the turntable resumes
CosmeticPreview.SWING_EVERY = 5 -- s between idle swings
CosmeticPreview.BUILDER_FOLDER = "HeroVisuals"
CosmeticPreview.FOV = 30

local looksMod: any = nil
local function Looks(): any
	if looksMod == nil then
		local ok, mod = pcall(function()
			local shared = ReplicatedStorage:FindFirstChild("Shared")
			local data = shared and shared:FindFirstChild("Data")
			local inst = data and data:FindFirstChild("Looks")
			return if inst and inst:IsA("ModuleScript") then require(inst) :: any else nil
		end)
		looksMod = if ok and mod then mod else false
	end
	return looksMod or nil
end

function CosmeticPreview.cfg(): PreviewRecipe.Cfg
	return {
		Cosmetics = Defs.module("Cosmetics"),
		ClassSkins = Defs.module("ClassSkins"),
		Looks = Looks(),
		Ascension = Defs.module("Ascension"),
	}
end

function CosmeticPreview.recipe(ref: string?): PreviewRecipe.Recipe?
	if ref == nil then
		return nil
	end
	return PreviewRecipe.resolve(ref, CosmeticPreview.cfg())
end

----------------------------------------------------------------------
-- What you wear now
----------------------------------------------------------------------

local function profile(): any
	local p = State.get("profile")
	return if type(p) == "table" then p else {}
end

function CosmeticPreview.baseOutfit(classId: string?): PreviewRecipe.Outfit
	local p = profile()
	local cid = classId
		or State.myClassId()
		or (if p.selectedClass then tostring(p.selectedClass) else "elephante")
	local skin: string? = nil
	local ok, cs = pcall(State.classState, cid)
	if ok and type(cs) == "table" and type(cs.skin) == "string" and cs.skin ~= "default" then
		skin = cs.skin
	end
	local asc: string? = nil
	local cl = type(p.classes) == "table" and p.classes[cid] or nil
	local av = type(cl) == "table" and cl.ascension or nil
	if type(av) == "table" and type(av.look) == "string" and av.look ~= "base" then
		asc = av.look
	end
	local o: PreviewRecipe.Outfit = { classId = cid, skinId = skin, ascLook = asc, focus = "body" }
	local L = Looks()
	if L and type(L.resolve) == "function" then
		local okL, look = pcall(L.resolve, p.equipped, p.cosmetics, { nameDye = p.nameDye })
		if okL and type(look) == "table" then
			o.hat, o.trail, o.tint = look.hat, look.trail, look.tint
			if look.nameplate and p.nameDye then
				o.nameColor = look.nameplate.nameColor
			end
		end
	end
	local plr = Players.LocalPlayer
	if plr then
		local title = plr:GetAttribute("NameTitle")
		if type(title) == "string" and title ~= "" then
			o.title = { text = title, color = { 255, 205, 60 } }
		end
		local tag, tagColor = plr:GetAttribute("ChatTag"), plr:GetAttribute("ChatTagColor")
		if type(tag) == "string" and tag ~= "" then
			local col = if typeof(tagColor) == "Color3"
				then {
					math.floor(tagColor.R * 255 + 0.5),
					math.floor(tagColor.G * 255 + 0.5),
					math.floor(tagColor.B * 255 + 0.5),
				}
				else { 255, 205, 60 }
			o.chatTag = { text = tag, color = col }
		end
		local pres = tonumber(plr:GetAttribute("Prestige")) or 0
		local wheel = plr:GetAttribute("WheelFrame") == true
		if wheel or pres >= 1 then
			o.frame = { key = if wheel then "wheel" else "p", prestige = pres, wheel = wheel }
		end
	end
	return o
end

----------------------------------------------------------------------
-- Building the hero
----------------------------------------------------------------------

local builderRetryAt = 0
local builderMod: any = nil
-- ReplicatedStorage.HeroVisuals.BotModel: the server's own hero builder.
function CosmeticPreview.builder(): any
	if builderMod then
		return builderMod
	end
	if os.clock() < builderRetryAt then
		return nil
	end
	builderRetryAt = os.clock() + 3
	local folder = ReplicatedStorage:FindFirstChild(CosmeticPreview.BUILDER_FOLDER)
	local inst = folder and folder:FindFirstChild("BotModel")
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		if ok and type(mod) == "table" and type(mod.build) == "function" then
			builderMod = mod
			return mod
		end
	end
	return nil
end

local statues: { [string]: Model } = {}
local function statue(classId: string): Model?
	local s = statues[classId]
	if s and s.Parent then
		return s
	end
	local found = workspace:FindFirstChild("Showcase_" .. classId, true)
	if found and found:IsA("Model") then
		statues[classId] = found
		return found
	end
	return nil
end

local function skinColors(classId: string, skinId: string?): (Color3, Color3)
	local S = Defs.module("ClassSkins")
	local def = if skinId and S and type(S.get) == "function" then S.get(skinId) else nil
	if type(def) == "table" and type(def.colors) == "table" then
		return CosmeticParts.rgb(def.colors.body), CosmeticParts.rgb(def.colors.accent)
	end
	local cd = Defs.get("Classes", classId)
	return CosmeticParts.rgb(cd and cd.color, Color3.fromRGB(150, 150, 165)), C.cheese
end

export type Hero = { model: Model, source: string, rig: any, height: number, key: string }

-- Builds the hero for (class, skin, look). source = "builder" | "statue" | "standin".
function CosmeticPreview.buildHero(classId: string, skinId: string?, ascLook: string?): Hero
	local key = classId .. "|" .. tostring(skinId) .. "|" .. tostring(ascLook)
	local model: Model? = nil
	local source = "standin"
	local B = CosmeticPreview.builder()
	if B then
		local plr = Players.LocalPlayer
		local ok, m = pcall(B.build, {
			id = 0,
			name = if plr then plr.DisplayName else "You",
			classId = classId,
			skinId = skinId,
			ascLook = ascLook,
		}, nil, { suit = true })
		if ok and typeof(m) == "Instance" and m:IsA("Model") then
			model = m
			source = "builder"
			-- iteration 8 (team Mesh): keep only the look this player chose (mesh / Classic)
			pcall(function()
				local inst = script.Parent.Parent:FindFirstChild("Visuals")
				local mm = inst and inst:FindFirstChild("MeshModels")
				if mm and mm:IsA("ModuleScript") then
					(require(mm) :: any).applySets(m, true)
				end
			end)
		end
	end
	if not model and not ascLook then
		local st = statue(classId)
		if st then
			local was = st.Archivable
			st.Archivable = true
			local ok, m = pcall(function()
				return st:Clone()
			end)
			st.Archivable = was
			if ok and m then
				model = m
				source = "statue"
				if skinId then
					-- colours only: the skin's accessory needs the shared builder
					local cd = Defs.get("Classes", classId)
					local classBody = CosmeticParts.rgb(cd and cd.color, Color3.fromRGB(150, 150, 165))
					local body = skinColors(classId, skinId)
					for _, d in m:GetDescendants() do
						if d:IsA("BasePart") then
							local base = d:GetAttribute("BaseColor")
							if typeof(base) == "Color3" then
								local diff = math.abs(base.R - classBody.R)
									+ math.abs(base.G - classBody.G)
									+ math.abs(base.B - classBody.B)
								if diff < 0.02 then
									d.Color = body
								end
							end
						end
					end
				end
			end
		end
	end
	if not model then
		local body, accent = skinColors(classId, skinId)
		model = CosmeticParts.standIn(body, accent)
	end
	local m = model :: Model
	m.Name = "PreviewHero"
	m:PivotTo(CFrame.new())
	local _, size = m:GetBoundingBox()
	local rig: any = nil
	if BotAnimator and type(BotAnimator.compile) == "function" then
		local ok, r = pcall(BotAnimator.compile, m)
		rig = if ok then r else nil
	end
	return { model = m, source = source, rig = rig, height = math.max(2, size.Y), key = key }
end

----------------------------------------------------------------------
-- Showroom (the 3-D view + overlays)
----------------------------------------------------------------------

export type Showroom = {
	frame: Frame,
	show: (outfit: PreviewRecipe.Outfit) -> (),
	setActive: (on: boolean) -> (),
	release: () -> (),
	destroy: () -> (),
	isBuilt: () -> boolean,
	heroSource: () -> string?,
	partCount: () -> number,
	motion: () -> PreviewRecipe.Motion,
}

local function hex(c: { number }): string
	return string.format("#%02X%02X%02X", c[1] or 255, c[2] or 255, c[3] or 255)
end

local function shownChain(obj: GuiObject): boolean
	local cur: Instance? = obj
	while cur do
		if cur:IsA("GuiObject") and not (cur :: GuiObject).Visible then
			return false
		elseif cur:IsA("ScreenGui") then
			return (cur :: ScreenGui).Enabled
		end
		cur = cur.Parent
	end
	return false
end

function CosmeticPreview.showroom(parent: Instance, props: { [string]: any }?): Showroom
	local frame = make("Frame", {
		Name = "Showroom",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(255, 236, 196),
		ClipsDescendants = true,
		Parent = parent,
	}) :: Frame
	if props then
		for k, v in props do
			(frame :: any)[k] = v
		end
	end
	Theme.corner(10).Parent = frame
	Theme.stroke(C.brown, 2).Parent = frame
	Theme.gradient(frame, Color3.fromRGB(255, 246, 222), Color3.fromRGB(232, 196, 140), 90)

	local vp: ViewportFrame? = nil
	local world: WorldModel? = nil
	local cam: Camera? = nil
	local overlay: Folder? = nil
	local ribbon: CosmeticParts.Ribbon? = nil
	local restoreTint: () -> () = function() end
	local heroes: { Hero } = {}
	local hero: Hero? = nil
	local outfit: PreviewRecipe.Outfit? = nil
	local yaw = math.rad(20)
	local t = 0
	local swingAt = CosmeticPreview.SWING_EVERY
	local dragging = false
	local dragX = 0
	local resumeAt = 0
	local active = false
	local hb: RBXScriptConnection? = nil
	local conns: { RBXScriptConnection } = {}
	local unsubs: { () -> () } = {}
	local checkAt = 0
	local destroyed = false
	local motion = PreviewRecipe.motion(State.gfx().fx)

	-- UI overlays (built with the frame: cheap labels)
	local plate = make("Frame", {
		Name = "Nameplate",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.new(0.86, 0, 0, 40),
		BackgroundColor3 = C.rind,
		BackgroundTransparency = 0.35,
		ZIndex = 4,
		Parent = frame,
	}) :: Frame
	Theme.corner(8).Parent = plate
	local nameLabel = Theme.label({
		Name = "Name",
		Size = UDim2.new(1, -8, 0.58, 0),
		Position = UDim2.fromOffset(4, 1),
		TextSize = 16,
		TextColor3 = C.white,
		ZIndex = 5,
		Parent = plate,
	})
	Theme.textStroke(C.shade, 1).Parent = nameLabel
	local titleLabel = Theme.label({
		Name = "Title",
		Position = UDim2.new(0, 4, 0.58, 0),
		Size = UDim2.new(1, -8, 0.4, 0),
		TextSize = 11,
		Font = Theme.FONT_BODY,
		TextColor3 = C.gold,
		ZIndex = 5,
		Parent = plate,
	})
	local chat = Theme.label({
		Name = "ChatBubble",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 8, 1, -8),
		Size = UDim2.new(1, -16, 0, 22),
		BackgroundColor3 = C.white,
		BackgroundTransparency = 0.1,
		TextSize = 12,
		Font = Theme.FONT_BODY,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		RichText = true,
		Visible = false,
		ZIndex = 5,
		Parent = frame,
	})
	Theme.corner(8).Parent = chat
	Theme.padding(6, 0).Parent = chat
	local hint = Theme.label({
		Name = "DragHint",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -6, 1, -4),
		Size = UDim2.fromOffset(110, 14),
		TextSize = 10,
		Font = Theme.FONT_LIGHT,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "↔ drag to turn",
		ZIndex = 4,
		Parent = frame,
	})

	local function stopLoop()
		if hb then
			hb:Disconnect()
			hb = nil
		end
	end

	local function frameCamera()
		local c, h = cam, hero
		if not c or not h then
			return
		end
		local o = outfit
		local focus = if o then o.focus else "body"
		local H = h.height
		local target = Vector3.new(0, H * 0.5, 0)
		local dist = (H * 0.68) / math.tan(math.rad(CosmeticPreview.FOV / 2))
		local lift = H * 0.16
		if focus == "head" then
			local head = h.model:FindFirstChild("Head", true)
			if head and head:IsA("BasePart") then
				target = Vector3.new(0, head.Position.Y + head.Size.Y * 0.45, head.Position.Z * 0.5)
				dist = (head.Size.Y * 1.9) / math.tan(math.rad(CosmeticPreview.FOV / 2))
				lift = head.Size.Y * 0.35
			end
		elseif focus == "feet" then
			target = Vector3.new(0, H * 0.32, 0)
			dist *= 1.2
			lift = H * 0.7
		end
		c.FieldOfView = CosmeticPreview.FOV
		c.CFrame = CFrame.lookAt(target + Vector3.new(0, lift, -dist), target)
	end

	local function place()
		local h = hero
		if h then
			h.model:PivotTo(CFrame.Angles(0, yaw, 0))
		end
	end

	local function step(dt: number)
		if destroyed or not hero then
			return
		end
		local now = os.clock()
		if now >= checkAt then
			checkAt = now + 0.25
			if not shownChain(frame) then
				stopLoop() -- paused while hidden; setActive / show resume it
				return
			end
		end
		t += dt
		if motion.rotate and not dragging and now >= resumeAt then
			yaw += dt * motion.spin
			place()
		end
		local h = hero :: Hero
		if motion.animate and h.rig and Rig then
			local r = h.rig
			local st = r.st
			swingAt -= dt
			if swingAt <= 0 then
				swingAt = CosmeticPreview.SWING_EVERY
				st.swingKind = (BotAnimator and BotAnimator.SWING[h.model:GetAttribute("ClassId")]) or "melee"
				st.swing = 0.001
			end
			Rig.step(st, dt, 0, r.scale, 5.5 * r.scale)
			Rig.pose("elephant", st, r.D, r.scale, 1)
			local rp = Rig.rootPose("elephant", st, r.scale)
			pcall(BotAnimator.apply, r, false, if rp ~= CFrame.identity then rp else nil)
		end
		local rb = ribbon
		if rb and motion.sweep then
			rb.set(t, true)
		end
	end

	local function startLoop()
		if hb or destroyed or not active or not hero then
			return
		end
		if not (motion.rotate or motion.animate or motion.sweep) and not dragging then
			return -- Effects off: a still hero, no per-frame work
		end
		checkAt = 0
		hb = RunService.Heartbeat:Connect(step)
	end

	local function ensureWorld()
		if vp then
			return
		end
		local v = make("ViewportFrame", {
			Name = "View",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Ambient = Color3.fromRGB(150, 140, 128),
			LightColor = Color3.fromRGB(255, 244, 222),
			LightDirection = Vector3.new(-0.6, -1.3, 0.7),
			ZIndex = 2,
			Parent = frame,
		}) :: ViewportFrame
		local w = Instance.new("WorldModel")
		w.Parent = v
		local cm = Instance.new("Camera")
		cm.FieldOfView = CosmeticPreview.FOV
		cm.Parent = v
		v.CurrentCamera = cm
		-- pedestal: 3 parts
		local st = Instance.new("Model")
		st.Name = "Pedestal"
		local function disc(name: string, r: number, h: number, y: number, col: Color3, tr: number)
			local p = Instance.new("Part")
			p.Name = name
			p.Shape = Enum.PartType.Cylinder
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.Material = Enum.Material.SmoothPlastic
			p.Size = Vector3.new(h, r * 2, r * 2)
			p.CFrame = CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.rad(90))
			p.Color = col
			p.Transparency = tr
			p.Parent = st
		end
		disc("Floor", 9, 0.1, -0.45, Color3.fromRGB(214, 176, 120), 0.35)
		disc("Rim", 3.7, 0.36, -0.2, C.cheeseDark, 0)
		disc("Top", 3.5, 0.4, -0.18, Color3.fromRGB(245, 236, 214), 0)
		st.Parent = w
		local ov = Instance.new("Folder")
		ov.Name = "Cosmetics"
		ov.Parent = w
		vp, world, cam, overlay = v, w, cm, ov
		-- drag to rotate (mouse or touch) on the view
		table.insert(
			conns,
			v.InputBegan:Connect(function(input: InputObject)
				local ut = input.UserInputType
				if ut == Enum.UserInputType.MouseButton1 or ut == Enum.UserInputType.Touch then
					dragging = true
					dragX = input.Position.X
					startLoop()
				end
			end)
		)
		table.insert(
			conns,
			UserInputService.InputChanged:Connect(function(input: InputObject)
				if not dragging then
					return
				end
				local ut = input.UserInputType
				if ut == Enum.UserInputType.MouseMovement or ut == Enum.UserInputType.Touch then
					local dx = input.Position.X - dragX
					dragX = input.Position.X
					yaw += dx * 0.014
					place()
				end
			end)
		)
		table.insert(
			conns,
			UserInputService.InputEnded:Connect(function(input: InputObject)
				local ut = input.UserInputType
				if dragging and (ut == Enum.UserInputType.MouseButton1 or ut == Enum.UserInputType.Touch) then
					dragging = false
					resumeAt = os.clock() + CosmeticPreview.DRAG_RESUME
					if not (motion.rotate or motion.animate or motion.sweep) then
						stopLoop()
					end
				end
			end)
		)
	end

	-- Hats live in the hero (welded to its head); the overlay folder keeps an
	-- ObjectValue per hat so clearing removes them too.
	local function clearCosmetics()
		restoreTint()
		restoreTint = function() end
		ribbon = nil
		local ov = overlay
		if ov then
			for _, ch in ov:GetChildren() do
				if ch:IsA("ObjectValue") and ch.Value then
					ch.Value:Destroy()
				end
			end
			ov:ClearAllChildren()
		end
	end

	local function heroFor(o: PreviewRecipe.Outfit): Hero
		local key = o.classId .. "|" .. tostring(o.skinId) .. "|" .. tostring(o.ascLook)
		for i, h in heroes do
			if h.key == key then
				table.remove(heroes, i)
				table.insert(heroes, h)
				return h
			end
		end
		local h = CosmeticPreview.buildHero(o.classId, o.skinId, o.ascLook)
		table.insert(heroes, h)
		while #heroes > CosmeticPreview.CACHE do
			local old = table.remove(heroes, 1) :: Hero
			if old ~= hero then
				old.model:Destroy()
			else
				table.insert(heroes, 1, old)
				break
			end
		end
		return h
	end

	local function drawOverlays(o: PreviewRecipe.Outfit)
		local plr = Players.LocalPlayer
		nameLabel.Text = if plr then plr.DisplayName else "You"
		nameLabel.TextColor3 = if o.nameColor then CosmeticParts.rgb(o.nameColor) else C.white
		local title = o.title
		titleLabel.Visible = title ~= nil
		titleLabel.Text = if title then title.text else ""
		titleLabel.TextColor3 = if title then CosmeticParts.rgb(title.color) else C.gold
		nameLabel.Size = if title then UDim2.new(1, -8, 0.58, 0) else UDim2.new(1, -8, 1, -2)
		if PrestigeFrames then
			local fr = o.frame
			local f = if fr then PrestigeFrames.frameFor(fr.prestige, fr.wheel) else nil
			pcall(PrestigeFrames.apply, plate, f)
		end
		local tag = o.chatTag
		chat.Visible = tag ~= nil
		if tag then
			chat.Text = string.format(
				'<font color="%s">[%s]</font> %s: Hi herd! 🐘',
				hex(tag.color),
				tag.text,
				if plr then plr.DisplayName else "You"
			)
		end
		hint.Visible = not chat.Visible
	end

	local self: Showroom = {} :: any
	self.frame = frame

	function self.show(o: PreviewRecipe.Outfit)
		if destroyed then
			return
		end
		ensureWorld()
		outfit = o
		local h = heroFor(o)
		local w = world :: WorldModel
		if hero ~= h then
			if hero then
				clearCosmetics()
				hero.model.Parent = nil
			end
			hero = h
			h.model.Parent = w
		else
			clearCosmetics()
		end
		place()
		local Cos = Defs.module("Cosmetics")
		local shapes = if Cos and type(Cos.HAT_SHAPES) == "table" then Cos.HAT_SHAPES else {}
		local ov = overlay :: Folder
		if o.hat then
			local head = h.model:FindFirstChild("Head", true)
			if head and head:IsA("BasePart") then
				pcall(CosmeticParts.hat, h.model, head, o.hat, shapes)
				local hatModel = h.model:FindFirstChild("Hat_" .. tostring(o.hat.id))
				if hatModel then
					local tag = Instance.new("ObjectValue")
					tag.Name = "HatRef"
					tag.Value = hatModel
					tag.Parent = ov
				end
			end
		end
		if o.trail then
			local okR, rb = pcall(CosmeticParts.ribbon, ov, o.trail, Cos and Cos.TRAIL)
			ribbon = if okR then rb else nil
		end
		if o.tint then
			restoreTint = CosmeticParts.tint(h.model, o.tint, Cos and Cos.TINT)
		end
		drawOverlays(o)
		frameCamera()
		if ribbon then
			ribbon.set(t, false)
		end
		startLoop()
	end

	function self.setActive(on: boolean)
		active = on
		if on then
			motion = PreviewRecipe.motion(State.gfx().fx)
			startLoop()
		else
			stopLoop()
			self.release()
		end
	end

	function self.release()
		stopLoop()
		clearCosmetics()
		for _, h in heroes do
			h.model:Destroy()
		end
		table.clear(heroes)
		hero = nil
	end

	function self.isBuilt(): boolean
		return vp ~= nil and hero ~= nil
	end

	function self.heroSource(): string?
		return if hero then hero.source else nil
	end

	function self.partCount(): number
		local n = 0
		local w = world
		if w then
			for _, d in w:GetDescendants() do
				if d:IsA("BasePart") then
					n += 1
				end
			end
		end
		return n
	end

	function self.motion(): PreviewRecipe.Motion
		return motion
	end

	function self.destroy()
		if destroyed then
			return
		end
		self.release()
		destroyed = true
		for _, cn in conns do
			cn:Disconnect()
		end
		table.clear(conns)
		for _, u in unsubs do
			u()
		end
		table.clear(unsubs)
		frame:Destroy()
		vp, world, cam, overlay = nil, nil, nil, nil
	end

	table.insert(
		unsubs,
		State.subscribe("gfx", function()
			motion = PreviewRecipe.motion(State.gfx().fx)
			if not (motion.rotate or motion.animate or motion.sweep) then
				stopLoop()
				if ribbon then
					ribbon.set(t, false)
				end
			else
				startLoop()
			end
		end)
	)
	return self
end

----------------------------------------------------------------------
-- Panel (showroom + item name + Buy / Equip buttons)
----------------------------------------------------------------------

export type ButtonSpec = { text: string, color: Color3?, enabled: boolean, onClick: () -> () }
export type Info = { title: string?, status: string?, buttons: { ButtonSpec }? }

export type Panel = {
	frame: Frame,
	showroom: Showroom,
	select: (ref: string?, info: Info?) -> (),
	hover: (ref: string) -> (),
	unhover: () -> (),
	clear: () -> (),
	refresh: () -> (),
	selected: () -> string?,
	setMode: (mode: string) -> (),
	setClass: (classId: string?) -> (),
	setActive: (on: boolean) -> (),
	destroy: () -> (),
}

function CosmeticPreview.panel(parent: Instance, props: { [string]: any }?): Panel
	local touch = Theme.TOUCH
	local f = make("Frame", {
		Name = "CosmeticPreview",
		BackgroundColor3 = C.cream,
		ZIndex = 8,
		Parent = parent,
	}) :: Frame
	if props then
		for k, v in props do
			(f :: any)[k] = v
		end
	end
	Theme.corner(12).Parent = f
	Theme.stroke(C.brown, 2).Parent = f
	local head = Theme.label({
		Name = "Header",
		Position = UDim2.fromOffset(10, 4),
		Size = UDim2.new(1, -(touch + 20), 0, 26),
		TextSize = 17,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "👀 Your hero",
		ZIndex = 9,
		Parent = f,
	})
	local tryBadge = Theme.badge("TRY ON", C.purple, {
		Name = "TryOn",
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.fromOffset(12, 36),
		Size = UDim2.fromOffset(0, 18),
		TextSize = 11,
		Visible = false,
		ZIndex = 12,
		Parent = f,
	})
	local closeBtn = Theme.button("✕", C.creamDark, {
		Name = "Fold",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -4, 0, 2),
		Size = UDim2.fromOffset(touch, math.min(touch, 34)),
		TextSize = 16,
		ZIndex = 9,
		Visible = false,
		Parent = f,
	})
	local nameH, statusH = 24, 30
	local btnH = touch
	local bottom = nameH + statusH + btnH + 18
	local roomHolder = make("Frame", {
		Name = "Room",
		Position = UDim2.fromOffset(8, 32),
		Size = UDim2.new(1, -16, 1, -(32 + bottom)),
		BackgroundTransparency = 1,
		ZIndex = 9,
		Parent = f,
	})
	local room = CosmeticPreview.showroom(roomHolder)
	local nameLabel = Theme.label({
		Name = "ItemName",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -(statusH + btnH + 12)),
		Size = UDim2.new(1, -20, 0, nameH),
		TextSize = 16,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Text = "",
		ZIndex = 9,
		Parent = f,
	})
	local statusLabel = Theme.label({
		Name = "Status",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -(btnH + 10)),
		Size = UDim2.new(1, -20, 0, statusH),
		TextSize = 12,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "Tap an item to try it on.",
		ZIndex = 9,
		Parent = f,
	})
	local btnRow = make("Frame", {
		Name = "Actions",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 8, 1, -6),
		Size = UDim2.new(1, -16, 0, btnH),
		BackgroundTransparency = 1,
		ZIndex = 9,
		Parent = f,
	})
	Theme.list(
		Enum.FillDirection.Horizontal,
		6,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	).Parent =
		btnRow

	local selectedRef: string? = nil
	local selectedInfo: Info? = nil
	local hoverRef: string? = nil
	local hoverToken = 0
	local classId: string? = nil
	local mode = "side"
	local active = false
	local shownRef: string? = nil
	local dirty = true

	local function buttons(list: { ButtonSpec }?)
		for _, ch in btnRow:GetChildren() do
			if ch:IsA("GuiButton") then
				ch:Destroy()
			end
		end
		if not list or #list == 0 then
			return
		end
		for i, spec in list do
			local b = Theme.button(spec.text, spec.color or C.green, {
				LayoutOrder = i,
				Size = UDim2.new(1 / #list, -6, 0, btnH),
				TextSize = 15,
				ZIndex = 10,
				Parent = btnRow,
			}, spec.onClick)
			Theme.setEnabled(b, spec.enabled)
			b:SetAttribute("PreviewAction", true)
		end
	end

	local function render(ref: string?, info: Info?, isHover: boolean)
		local recipe = CosmeticPreview.recipe(ref)
		if dirty or ref ~= shownRef then
			shownRef = ref
			dirty = not active
			local base = CosmeticPreview.baseOutfit(classId)
			if active then
				room.show(PreviewRecipe.outfit(base, recipe))
			end
		end
		tryBadge.Visible = recipe ~= nil
		head.Text = if recipe then "👀 Trying on" else "👀 Your hero"
		nameLabel.Text = if info and info.title then info.title elseif recipe then recipe.name else "Your hero"
		if isHover then
			statusLabel.Text = "Tap to pick it."
			buttons(nil)
		else
			statusLabel.Text = if info and info.status
				then info.status
				elseif recipe then "Previewing on your hero."
				else "Tap an item to try it on. Drag to turn."
			buttons(info and info.buttons)
		end
	end

	local self: Panel = {} :: any
	self.frame = f
	self.showroom = room

	function self.select(ref: string?, info: Info?)
		selectedRef, selectedInfo = ref, info
		hoverRef = nil
		hoverToken += 1
		if mode == "overlay" and ref ~= nil then
			f.Visible = true
		end
		render(ref, info, false)
	end

	function self.refresh()
		dirty = true
		render(hoverRef or selectedRef, if hoverRef then nil else selectedInfo, hoverRef ~= nil)
	end

	function self.hover(ref: string)
		if mode == "overlay" or ref == selectedRef then
			return -- touch / sheet: taps select instead
		end
		hoverRef = ref
		hoverToken += 1
		local tok = hoverToken
		task.delay(CosmeticPreview.HOVER_DELAY, function()
			if tok == hoverToken and hoverRef == ref and f.Parent then
				render(ref, nil, true)
			end
		end)
	end

	function self.unhover()
		if hoverRef == nil then
			return
		end
		hoverRef = nil
		hoverToken += 1
		local tok = hoverToken
		task.delay(CosmeticPreview.HOVER_DELAY, function()
			if tok == hoverToken and f.Parent then
				render(selectedRef, selectedInfo, false)
			end
		end)
	end

	function self.clear()
		self.select(nil, nil)
	end

	function self.selected(): string?
		return selectedRef
	end

	function self.setMode(m: string)
		mode = if m == "overlay" then "overlay" else "side"
		closeBtn.Visible = mode == "overlay"
		if mode == "overlay" and selectedRef == nil then
			f.Visible = false
		elseif mode == "side" then
			f.Visible = true
		end
	end

	function self.setClass(cid: string?)
		if cid ~= classId then
			classId = cid
			dirty = true
			if active then
				render(selectedRef, selectedInfo, false)
			end
		end
	end

	function self.setActive(on: boolean)
		if on == active then
			return
		end
		active = on
		room.setActive(on)
		dirty = true
		if on then
			render(selectedRef, selectedInfo, false)
		else
			hoverRef = nil
			hoverToken += 1
		end
	end

	function self.destroy()
		hoverToken += 1
		room.destroy()
		f:Destroy()
	end

	closeBtn.Activated:Connect(function()
		f.Visible = false
	end)
	return self
end

-- Hover (mouse) and tap / click on a list card try the item on. The card's own
-- buttons keep working: the hit area sits under them (ZIndex 0).
function CosmeticPreview.bindCard(p: Panel?, card: GuiObject?, ref: string, info: Info?)
	if not p or not card then
		return
	end
	local hit = make("TextButton", {
		Name = "PreviewHit",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		ZIndex = 0,
		AutoButtonColor = false,
		Parent = card,
	}) :: TextButton
	hit:SetAttribute("PreviewRef", ref)
	card:SetAttribute("PreviewRef", ref)
	hit.Activated:Connect(function()
		p.select(ref, info)
	end)
	card.MouseEnter:Connect(function()
		p.hover(ref)
	end)
	card.MouseLeave:Connect(function()
		p.unhover()
	end)
end

return CosmeticPreview
