--!strict
-- Shared look & feel ("premium cheese"): a gold / cream / rind-brown palette,
-- one typography scale, and component builders with gradients, strokes,
-- rounded corners, drop shadows and tweened hover / press states. Icons are
-- drawn from UI primitives (UI/Icons). Every ScreenGui gets a design-space
-- root frame scaled by a UIScale computed from the safe viewport
-- (Util/Layout): a PC fits a 1600x900 design area at up to 1:1, a phone the
-- 1100x620 compact area, so every root is at least 1100x620 design px.
-- Touch targets follow a separate rule (Theme.TOUCH, see Layout), text never
-- renders under the Layout text floor, and on roomy ("dense") screens panels
-- use the compact v3 sizes from Util/UiSizes plus an optional rest scale
-- (Theme.compact) for the big lobby / results panels.
--
-- Skin (UI/Skin): once the UI textures are uploaded (Config/AssetIds), panels,
-- buttons, tabs, cards, bars, headers, dots and icons draw 9-slice textures;
-- while an id is missing / 0 every builder keeps exactly the flat look below.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Device = require(Client.Util.Device)
local Layout = require(Client.Util.Layout)
local UiSizes = require(Client.Util.UiSizes)
local Icons = require(script.Parent.Icons)
local Skin = require(script.Parent.Skin)
local SkinMath = require(script.Parent.SkinMath)

local SquadsOk, SquadsMod = pcall(function()
	return require(
		game:GetService("ReplicatedStorage")
			:WaitForChild("Shared")
			:WaitForChild("Util")
			:WaitForChild("Squads")
	)
end)

local Theme = {}

Theme.C = {
	cheese = Color3.fromRGB(255, 204, 51),
	cheeseDark = Color3.fromRGB(232, 162, 32),
	gold = Color3.fromRGB(255, 214, 92),
	goldLight = Color3.fromRGB(255, 240, 170),
	goldDeep = Color3.fromRGB(196, 128, 22),
	cream = Color3.fromRGB(255, 244, 214),
	creamDark = Color3.fromRGB(238, 222, 184),
	brown = Color3.fromRGB(110, 70, 40),
	brownDark = Color3.fromRGB(62, 38, 22),
	rind = Color3.fromRGB(44, 28, 17), -- dark HUD panels
	rindLight = Color3.fromRGB(78, 52, 32),
	ink = Color3.fromRGB(48, 30, 18),
	white = Color3.fromRGB(255, 255, 255),
	red = Color3.fromRGB(226, 72, 58),
	green = Color3.fromRGB(96, 190, 92),
	greenDark = Color3.fromRGB(52, 132, 60),
	blue = Color3.fromRGB(72, 142, 230),
	purple = Color3.fromRGB(160, 92, 224),
	curse = Color3.fromRGB(142, 92, 247),
	orange = Color3.fromRGB(255, 140, 40),
	grey = Color3.fromRGB(150, 150, 150),
	greyDark = Color3.fromRGB(88, 84, 80),
	hp = Color3.fromRGB(110, 210, 90),
	hpLow = Color3.fromRGB(235, 80, 60),
	xp = Color3.fromRGB(110, 190, 255),
	shade = Color3.fromRGB(20, 12, 6),
	shadow = Color3.fromRGB(10, 6, 3),
	textDim = Color3.fromRGB(214, 196, 160),
}

-- STYLE.md rarity colours.
Theme.RARITY = {
	Common = Color3.fromRGB(184, 184, 184),
	Uncommon = Color3.fromRGB(96, 190, 92),
	Rare = Color3.fromRGB(78, 168, 255),
	Epic = Color3.fromRGB(179, 107, 255),
	Legendary = Color3.fromRGB(255, 154, 46),
} :: { [string]: Color3 }

Theme.TIER = {
	Low = Color3.fromRGB(91, 209, 107),
	Mid = Color3.fromRGB(255, 201, 60),
	High = Color3.fromRGB(255, 90, 78),
} :: { [string]: Color3 }

Theme.FONT = Enum.Font.FredokaOne -- headings, numbers, buttons
Theme.FONT_BODY = Enum.Font.GothamBold -- descriptions
Theme.FONT_LIGHT = Enum.Font.GothamMedium -- captions, fine print

-- Typography scale (design px). Use these instead of ad-hoc sizes so every
-- screen reads the same; Theme.screen still floors them on small phones.
Theme.TYPE = {
	display = 44, -- results title, big countdowns
	title = 30, -- modal titles
	heading = 22, -- card titles, buttons
	body = 17, -- descriptions
	caption = 14, -- secondary lines
	micro = 12, -- badges, tiny counters
}

local currentScale = 1

-- Safe viewport (screen px) from the camera and the core-GUI inset. Only a
-- fallback: ScreenGuis use CoreUISafeInsets, so their AbsoluteSize is better.
local function cameraViewport(): (number?, number?)
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize
	if not vp or vp.X < 4 or vp.Y < 4 then
		return nil, nil
	end
	local ok, topLeft, bottomRight = pcall(function()
		return GuiService:GetGuiInset()
	end)
	if ok and typeof(topLeft) == "Vector2" and typeof(bottomRight) == "Vector2" then
		return Layout.safeViewport(vp.X, vp.Y, topLeft.X, topLeft.Y, bottomRight.X, bottomRight.Y)
	end
	return vp.X, vp.Y
end

-- Minimum touch / click target in design px (Layout.touchSize): at least
-- 48 screen px on touch devices whatever the UI scale. Recomputed whenever a
-- screen is fitted; UIs read it right after Theme.screen(), so their buttons
-- are built with the value for the current device.
Theme.TOUCH = Layout.BASE_TOUCH
-- Slim-bar control size (Layout.slimSize): touch target on touch devices,
-- otherwise just big enough to click.
Theme.SLIM = Layout.slimSize(1, false)
do
	local w, h = cameraViewport()
	if w and h then
		currentScale = Layout.fitScale(w, h)
		Theme.TOUCH = Layout.touchSize(currentScale, Device.hasTouch())
		Theme.SLIM = Layout.slimSize(currentScale, Device.hasTouch())
	end
end

function Theme.scale(): number
	return currentScale
end

-- True on roomy screens (PC / laptop): UIs build their compact v3 sizes
-- (Util/UiSizes). Read right after Theme.screen(), like Theme.TOUCH.
function Theme.dense(): boolean
	return Layout.dense(currentScale)
end

-- Rest scale of `obj` (Theme.compact), or 1.
local function baseScale(obj: Instance): number
	local b = obj:GetAttribute("BaseScale")
	return if type(b) == "number" and b > 0 then b else 1
end

-- Product of the compact rest scales of `obj` and its ancestors: the extra
-- shrink on top of the screen's UIScale (used by the text floor).
local function restScaleOf(obj: Instance): number
	local f = 1
	local cur: Instance? = obj
	while cur and not cur:IsA("LayerCollector") do
		f *= baseScale(cur)
		cur = cur.Parent
	end
	return f
end

-- Screen px per design px for content inside `obj` right now: the screen
-- scale times every PopScale (compact rest scale or a running pop-in) on the
-- way up. AbsoluteSize / scaleOf(obj) gives design px.
-- Live readability fix (iteration 6): menu screens get the higher menu text
-- floor (Layout.MENU_MIN_TEXT_PX); the in-run HUD screens keep the old one.
-- (TrunkfallGems = the Gem Vault, team Gems.)
Theme.MENU_SCREENS = {
	TrunkfallHerd = true,
	TrunkfallHero = true,
	TrunkfallLobby = true,
	TrunkfallShop = true,
	TrunkfallResults = true,
	TrunkfallRunShop = true,
	TrunkfallSettings = true,
	TrunkfallPerks = true,
	TrunkfallPass = true,
	TrunkfallGems = true, -- iter6 team Gems: the Gem Vault
	TrunkfallControls = true, -- iteration 8: keybinds + smart-cast (UI/ControlsUI)
} :: { [string]: boolean }

-- The design size `size` menu text renders at now (Theme's menu text floor:
-- Layout.textSize at the current scale).
function Theme.renderedText(size: number): number
	return Layout.textSize(size, currentScale, Device.hasTouch(), true)
end

-- A list row (`f`, AutomaticSize Y) that never comes out shorter than its
-- title + body need at their rendered size (UiSizes.rowHeight), in case
-- AutomaticSize under-measures wrapped text. `width` = the row's design width
-- (default: measured on the next frame), `rightW` = buttons on its right.
function Theme.rowMinHeight(f: GuiObject, title: string, body: string?, rightW: number?, width: number?)
	local function apply(w: number)
		local box = UiSizes.rowHeight(w, title, body, rightW, Theme.renderedText)
		local floor = f:GetAttribute("RowMinH") -- e.g. one button tall
		box.h = math.max(box.h, if type(floor) == "number" then floor else 0)
		local c = f:FindFirstChild("RowMin")
		if not (c and c:IsA("UISizeConstraint")) then
			c = Theme.make("UISizeConstraint", { Name = "RowMin", Parent = f })
		end
		local uc = c :: UISizeConstraint
		if math.abs(uc.MinSize.Y - box.h) > 0.5 then
			uc.MinSize = Vector2.new(0, box.h)
		end
	end
	if width then
		apply(width)
	end
	f:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local s = math.max(Theme.scaleOf(f), 0.05)
		local w = f.AbsoluteSize.X / s
		if w > 40 then
			apply(w)
		end
	end)
end

function Theme.scaleOf(obj: Instance): number
	local f = currentScale
	local cur: Instance? = obj
	while cur and not cur:IsA("LayerCollector") do
		local ps = cur:FindFirstChild("PopScale")
		if ps and ps:IsA("UIScale") then
			f *= math.max(ps.Scale, 0.05)
		end
		cur = cur.Parent
	end
	return math.max(f, 0.01)
end

-- Creates an Instance, assigns props (Parent last) and parents children.
function Theme.make(className: string, props: { [string]: any }?, children: { Instance }?): any
	local inst = Instance.new(className) :: any
	local parent = nil
	if props then
		for k, v in props do
			if k == "Parent" then
				parent = v
			else
				inst[k] = v
			end
		end
	end
	if children then
		for _, c in children do
			c.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local make = Theme.make

function Theme.corner(radius: number?): UICorner
	return make("UICorner", { CornerRadius = UDim.new(0, radius or 12) })
end

function Theme.round(): UICorner
	return make("UICorner", { CornerRadius = UDim.new(0.5, 0) })
end

function Theme.stroke(color: Color3?, thickness: number?, transparency: number?): UIStroke
	return make("UIStroke", {
		Color = color or Theme.C.brownDark,
		Thickness = thickness or 3,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function Theme.textStroke(color: Color3?, thickness: number?): UIStroke
	return make("UIStroke", {
		Color = color or Theme.C.brownDark,
		Thickness = thickness or 2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
	})
end

function Theme.padding(px: number, py: number?): UIPadding
	local y = py or px
	return make("UIPadding", {
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
		PaddingTop = UDim.new(0, y),
		PaddingBottom = UDim.new(0, y),
	})
end

function Theme.list(
	direction: Enum.FillDirection?,
	gap: number?,
	hAlign: Enum.HorizontalAlignment?,
	vAlign: Enum.VerticalAlignment?
): UIListLayout
	return make("UIListLayout", {
		FillDirection = direction or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap or 8),
		HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Center,
		VerticalAlignment = vAlign or Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
end

function Theme.aspect(ratio: number): UIAspectRatioConstraint
	return make("UIAspectRatioConstraint", { AspectRatio = ratio })
end

-- Text label with sensible defaults. props override.
function Theme.label(props: { [string]: any }): TextLabel
	local base: { [string]: any } = {
		BackgroundTransparency = 1,
		Font = Theme.FONT,
		TextColor3 = Theme.C.cream,
		TextSize = 22,
		TextWrapped = true,
		Text = "",
		Size = UDim2.new(1, 0, 0, 28),
	}
	for k, v in props do
		base[k] = v
	end
	return make("TextLabel", base)
end

----------------------------------------------------------------------
-- Gradients, shadows, transitions
----------------------------------------------------------------------

-- Vertical light-to-dark multiplier gradient: gives any fill some volume.
-- `top` / `bottom` are brightness multipliers (1 = the object's own colour).
function Theme.gloss(obj: GuiObject, top: number?, bottom: number?, rotation: number?): UIGradient
	local t = math.clamp(top or 1, 0, 1)
	local b = math.clamp(bottom or 0.82, 0, 1)
	return make("UIGradient", {
		Rotation = rotation or 90,
		Color = ColorSequence.new(Color3.new(t, t, t), Color3.new(b, b, b)),
		Parent = obj,
	})
end

-- Two-colour gradient (absolute colours; the object's colour should be white).
function Theme.gradient(obj: Instance, a: Color3, b: Color3, rotation: number?): UIGradient
	return make("UIGradient", {
		Rotation = rotation or 90,
		Color = ColorSequence.new(a, b),
		Parent = obj,
	})
end

-- Gold stroke with a light-to-deep gradient: the premium frame for HUD cards.
function Theme.goldStroke(thickness: number?, transparency: number?): UIStroke
	local s = make("UIStroke", {
		Color = Theme.C.white,
		Thickness = thickness or 2,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}) :: UIStroke
	make("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.C.goldLight),
			ColorSequenceKeypoint.new(0.5, Theme.C.gold),
			ColorSequenceKeypoint.new(1, Theme.C.goldDeep),
		}),
		Parent = s,
	})
	return s
end

-- Soft drop shadow behind a free-floating frame. The shadow is a sibling that
-- mirrors the frame's anchor, position, size, visibility and parent, so it
-- works with frames that are moved, tweened or auto-sized later. Skipped
-- inside list / grid layouts (a sibling would take a layout slot).
function Theme.dropShadow(obj: GuiObject, depth: number?, transparency: number?): Frame?
	if obj:GetAttribute("HasShadow") or obj:GetAttribute("Skinned") then
		return nil
	end
	obj:SetAttribute("HasShadow", true)
	local d = depth or 6
	local corner = obj:FindFirstChildOfClass("UICorner")
	local sh = make("Frame", {
		Name = obj.Name .. "Shadow",
		BackgroundColor3 = Theme.C.shadow,
		BackgroundTransparency = transparency or 0.55,
		BorderSizePixel = 0,
		Active = false,
	}) :: Frame
	make("UICorner", { CornerRadius = if corner then corner.CornerRadius else UDim.new(0, 14), Parent = sh })
	local function sync()
		local p = obj.Parent
		if p == nil or p:FindFirstChildWhichIsA("UIGridStyleLayout") then
			sh.Parent = nil
			return
		end
		sh.AnchorPoint = obj.AnchorPoint
		sh.Position = obj.Position + UDim2.fromOffset(0, d)
		sh.Rotation = obj.Rotation
		-- The shadow is a sibling: it gets the frame's compact rest scale
		-- (Theme.compact) but not a running pop-in.
		local base = baseScale(obj)
		if obj.AutomaticSize ~= Enum.AutomaticSize.None then
			local s = math.max(Theme.scaleOf(obj), 0.01)
			local abs = obj.AbsoluteSize
			sh.Size = UDim2.fromOffset(abs.X / s * base, abs.Y / s * base)
		else
			local z = obj.Size
			sh.Size = UDim2.new(z.X.Scale * base, z.X.Offset * base, z.Y.Scale * base, z.Y.Offset * base)
		end
		sh.Visible = obj.Visible
		sh.ZIndex = obj.ZIndex - 1
		sh.LayoutOrder = obj.LayoutOrder
		sh.Parent = p
	end
	for _, prop in { "Position", "Size", "AnchorPoint", "Visible", "ZIndex", "AbsoluteSize", "Rotation" } do
		obj:GetPropertyChangedSignal(prop):Connect(sync)
	end
	obj.AncestryChanged:Connect(sync)
	obj:GetAttributeChangedSignal("BaseScale"):Connect(sync)
	obj.Destroying:Connect(function()
		sh:Destroy()
	end)
	task.defer(sync)
	return sh
end

-- True while the mouse pointer is over `obj` (plus `margin` screen px).
-- Unknown pointer (no mouse API) counts as over, so nothing folds by mistake.
function Theme.pointerOver(obj: GuiObject, margin: number?): boolean
	local ok, m = pcall(function()
		return UserInputService:GetMouseLocation()
	end)
	if not ok or typeof(m) ~= "Vector2" then
		return true
	end
	local inset = Vector2.zero
	pcall(function()
		local topLeft = GuiService:GetGuiInset()
		if typeof(topLeft) == "Vector2" then
			inset = topLeft
		end
	end)
	local p = (m :: Vector2) - inset
	local a, z = obj.AbsolutePosition, obj.AbsoluteSize
	local g = margin or 16
	return p.X >= a.X - g and p.X <= a.X + z.X + g and p.Y >= a.Y - g and p.Y <= a.Y + z.Y + g
end

-- Tween helper: plays and returns the tween.
function Theme.tween(
	obj: Instance,
	seconds: number,
	props: { [string]: any },
	style: Enum.EasingStyle?,
	dir: Enum.EasingDirection?
): Tween
	local tw = TweenService:Create(
		obj,
		TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out),
		props
	)
	tw:Play()
	return tw
end

-- Slides a frame in from `dx, dy` design px away (it ends where it is now).
function Theme.slideIn(obj: GuiObject, dx: number, dy: number, seconds: number?)
	local target = obj:GetAttribute("SlideHome")
	local home = if typeof(target) == "UDim2" then target else obj.Position
	obj:SetAttribute("SlideHome", home)
	obj.Position = home + UDim2.fromOffset(dx, dy)
	Theme.tween(obj, seconds or 0.22, { Position = home }, Enum.EasingStyle.Back)
end

-- Gentle looping pulse of a stroke's transparency (e.g. "available" nodes).
function Theme.pulse(stroke: UIStroke, from: number?, to: number?, seconds: number?): Tween
	stroke.Transparency = from or 0
	local tw = TweenService:Create(
		stroke,
		TweenInfo.new(seconds or 0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = to or 0.6 }
	)
	tw:Play()
	return tw
end

local setSkinState: (b: GuiButton, state: string) -> ()

-- Hover / press feedback for any GuiButton: a scale tween (press: 0.95, back
-- with a soft overshoot) plus a light (hover) or dark (press) overlay, or the
-- hover / pressed texture on a skinned button. Works with buttons whose
-- colour code changes later.
function Theme.hover(b: GuiButton, scaleTo: number?)
	local scale = b:FindFirstChild("HoverScale") :: UIScale?
	if not scale then
		scale = make("UIScale", { Name = "HoverScale", Scale = 1, Parent = b })
	end
	local sc = scale :: UIScale
	local corner = b:FindFirstChildOfClass("UICorner")
	local overlay = make("Frame", {
		Name = "HoverOverlay",
		BackgroundColor3 = Theme.C.white,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = b.ZIndex + 4,
		Active = false,
		Parent = b,
	}) :: Frame
	make(
		"UICorner",
		{ CornerRadius = if corner then corner.CornerRadius else UDim.new(0, 14), Parent = overlay }
	)
	local up = scaleTo or 1.04
	local info = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local pressInfo = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local releaseInfo = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local hovering = false
	local pressed = false
	local function to(s: number, color: Color3, alpha: number, state: string)
		local wasPressed = pressed
		pressed = state == "pressed"
		local ti = if pressed then pressInfo elseif wasPressed then releaseInfo else info
		TweenService:Create(sc, ti, { Scale = s }):Play()
		if b:GetAttribute("SkinBase") then
			overlay.BackgroundTransparency = 1
			setSkinState(b, state)
			return
		end
		overlay.BackgroundColor3 = color
		TweenService:Create(overlay, info, { BackgroundTransparency = alpha }):Play()
	end
	b.MouseEnter:Connect(function()
		hovering = true
		if b.Active then
			to(up, Theme.C.white, 0.86, "hover")
		end
	end)
	b.MouseLeave:Connect(function()
		hovering = false
		to(1, Theme.C.white, 1, "normal")
	end)
	b.MouseButton1Down:Connect(function()
		if b.Active then
			to(0.95, Theme.C.shadow, 0.82, "pressed")
		end
	end)
	b.MouseButton1Up:Connect(function()
		if hovering and b.Active then
			to(up, Theme.C.white, 0.86, "hover")
		else
			to(1, Theme.C.white, 1, "normal")
		end
	end)
	b.SelectionGained:Connect(function()
		to(up, Theme.C.white, 0.86, "hover")
	end)
	b.SelectionLost:Connect(function()
		to(1, Theme.C.white, 1, "normal")
	end)
end

----------------------------------------------------------------------
-- Skin (textures; no-ops while the ids are 0, see UI/Skin)
----------------------------------------------------------------------

Theme.Skin = Skin

local WHITE = Color3.new(1, 1, 1)

local function luminance(c: Color3): number
	return 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
end

-- Texture behind a frame: true when the texture is uploaded and now draws
-- the frame (its flat background, border stroke and gradients are hidden).
-- `onRevert` runs if a list / grid layout is added to the frame later (the
-- skin then steps back to the flat look; see Skin.revertOnLayout).
local function skinFrame(
	f: GuiObject,
	name: string,
	opts: Skin.LayerOpts?,
	maxAlpha: number?,
	onRevert: (() -> ())?
): ImageLabel?
	local layer = Skin.layer(f, name, opts)
	if not layer then
		return nil
	end
	Skin.stripFlat(f)
	Skin.ownBackground(f, layer, { maxAlpha = maxAlpha })
	Skin.revertOnLayout(f, onRevert)
	return layer
end

-- Faint Swiss-cheese holes tiled over a parchment panel (inside the wood frame).
local PANEL_FRAME_PX = 50 -- texture px from the visible edge to the parchment
local function cheesePattern(layer: ImageLabel)
	local uri = Skin.uri("ui_pattern_cheese")
	local slice = Skin.slice("ui_panel")
	if not uri or not slice or Skin.set() ~= "ui" then -- set 2 is plain (no pattern)
		return
	end
	local pat = make("ImageLabel", {
		Name = "SkinPattern",
		BackgroundTransparency = 1,
		Image = uri,
		ImageTransparency = 0.86,
		ScaleType = Enum.ScaleType.Tile,
		TileSize = UDim2.fromOffset(110, 110),
		Active = false,
		Parent = layer,
	}) :: ImageLabel
	make("UICorner", { CornerRadius = UDim.new(0, 8), Parent = pat })
	local function place()
		local s = layer.SliceScale
		local l = (slice.pad[1] + PANEL_FRAME_PX) * s
		local t = (slice.pad[2] + PANEL_FRAME_PX) * s
		local r = (slice.pad[3] + PANEL_FRAME_PX) * s
		local btm = (slice.pad[4] + PANEL_FRAME_PX) * s
		pat.Position = UDim2.fromOffset(l, t)
		pat.Size = UDim2.new(1, -(l + r), 1, -(t + btm))
	end
	place()
	layer:GetPropertyChangedSignal("SliceScale"):Connect(place)
end

-- Panel texture: parchment in wood, or the dark modal for dark panels.
local function skinPanel(f: Frame, mul: number?, onRevert: (() -> ())?): boolean
	local dark = luminance(f.BackgroundColor3) < 0.35
	local layer = skinFrame(f, if dark then "ui_panel_dark" else "ui_panel", { mul = mul }, nil, onRevert)
	if not layer then
		return false
	end
	if not dark then
		cheesePattern(layer)
	end
	return true
end

-- Applies the current texture (base + hover / pressed state) of a skinned button.
local function applyButtonTexture(b: GuiButton)
	local layer = b:FindFirstChild("Skin")
	local base = b:GetAttribute("SkinBase")
	if not (layer and layer:IsA("ImageLabel") and type(base) == "string") then
		return
	end
	local st = b:GetAttribute("SkinState")
	local name = SkinMath.stateTexture(base, if type(st) == "string" then st else nil)
	if not Skin.has(name) then
		name = base
	end
	Skin.setLayer(layer, name)
	layer.ImageColor3 = if base == "ui_btn_tint" then b.BackgroundColor3 else WHITE
	local content = b:FindFirstChild("SkinContent")
	if content and content:IsA("Frame") then
		content.Position = UDim2.fromOffset(0, if st == "pressed" then 2 else 0)
	end
end

setSkinState = function(b: GuiButton, state: string)
	b:SetAttribute("SkinState", state)
	applyButtonTexture(b)
end

-- Skins a Theme.button / Theme.tab. `kind` "tab" uses the tab textures.
local function skinButton(b: TextButton, kind: string?)
	local function texture(): string
		local c = b.BackgroundColor3
		local t = SkinMath.buttonTexture(c.R * 255, c.G * 255, c.B * 255, b.Text, kind)
		-- Theme.squircle: the squircle shape where the active set has one (set 2)
		if kind == "squircle" and SkinMath.HAS_STATES[t .. "_sq"] and Skin.has(t .. "_sq") then
			t ..= "_sq"
		end
		return t
	end
	local base = texture()
	local isClose = base == "ui_close"
	local layer = Skin.layer(b, base, { fit = isClose, grow = if isClose then 1.25 else nil })
	if not layer then
		return
	end
	b:SetAttribute("SkinBase", base)
	b:SetAttribute("SkinKind", kind or "button")
	Skin.stripFlat(b)
	local content = Skin.caption(b, if kind == "tab" then 0 else 3)
	content.Visible = not isClose
	Skin.ownBackground(b, layer, {
		onColor = function()
			if isClose then
				applyButtonTexture(b)
				return
			end
			local nb = texture()
			if nb ~= "ui_close" and Skin.has(nb) then
				b:SetAttribute("SkinBase", nb)
			end
			applyButtonTexture(b)
		end,
	})
end

-- Tab button (shop tabs): a Theme.button that uses the tab textures. The
-- active tab is the one coloured C.cheese (same flat look as Theme.button).
function Theme.tab(text: string, props: { [string]: any }?, onClick: (() -> ())?): TextButton
	local b = Theme.button(text, Theme.C.creamDark, props, onClick, "tab")
	-- live readability fix (iteration 6): tab labels fill their buttons. At
	-- least UiSizes.MENU.tabText, and a fixed-width tab grows to hold it.
	local M = UiSizes.MENU
	if b.TextSize < M.tabText then
		b.TextSize = M.tabText
	end
	local sz = b.Size
	if sz.X.Scale == 0 and b.AutomaticSize == Enum.AutomaticSize.None then
		local want = UiSizes.tabWidth(text, Theme.renderedText)
		if want > sz.X.Offset then
			b.Size = UDim2.new(0, want, sz.Y.Scale, sz.Y.Offset)
		end
	end
	b.TextTruncate = Enum.TextTruncate.AtEnd
	return b
end

-- Iteration 4 (owner: "much cleaner UI, custom button shapes"): pill and
-- squircle buttons. The flat fallback gets the shape from its UICorner; with
-- the skin active, SkinMath.buttonTexture can key new textures on the kind.
local function shapeCorner(b: GuiObject, radius: UDim)
	local c = b:FindFirstChildOfClass("UICorner")
	if c then
		c.CornerRadius = radius
	end
	local st = b:FindFirstChildOfClass("UIStroke")
	if st and st.ApplyStrokeMode == Enum.ApplyStrokeMode.Border then
		st.Thickness = 2 -- a crisp, thinner outline
	end
end

function Theme.pill(text: string, color: Color3?, props: { [string]: any }?, onClick: (() -> ())?): TextButton
	local b = Theme.button(text, color, props, onClick, "pill")
	shapeCorner(b, UDim.new(0.5, 0))
	return b
end

function Theme.squircle(
	text: string,
	color: Color3?,
	props: { [string]: any }?,
	onClick: (() -> ())?
): TextButton
	local b = Theme.button(text, color, props, onClick, "squircle")
	shapeCorner(b, UDim.new(0.3, 0))
	return b
end

-- One clean dock (the lobby bottom bar, iteration 4): a dark rounded card with
-- a crisp gold outline and a soft shadow, the "ui_dock" texture once uploaded.
-- Returns (dock, inner): give `inner` the UIListLayout / padding, so the dock
-- itself never needs a mirrored sibling layer (the old wood strip did).
function Theme.dock(props: { [string]: any }): (Frame, Frame)
	local base: { [string]: any } = {
		BackgroundColor3 = Theme.C.rind,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
	}
	for k, v in props do
		base[k] = v
	end
	local dock = make("Frame", base) :: Frame
	Theme.corner(22).Parent = dock
	local stroke = Theme.stroke(Theme.C.gold, 2, 0.15)
	stroke.Parent = dock
	Theme.gradient(dock, Color3.fromRGB(255, 245, 230), Color3.fromRGB(190, 170, 150))
	local shadow = Theme.dropShadow(dock, 6, 0.55)
	if Skin.has("ui_dock") then
		local layer = Skin.layer(dock, "ui_dock", { name = "Skin" })
		if layer then
			Skin.stripFlat(dock)
			Skin.ownBackground(dock, layer, {})
			if shadow then
				shadow.BackgroundTransparency = 1 -- the texture has its own soft shadow
			end
		end
	end
	local inner = make("Frame", {
		Name = "Inner",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = dock,
	}) :: Frame
	return dock, inner
end

-- Ribbon banner behind a header label (a sibling image, so the label's text
-- stays on top). No-op while the ribbon is not uploaded.
function Theme.header(label: TextLabel): ImageLabel?
	local parent = label.Parent
	local uri = Skin.uri("ui_ribbon")
	local slice = Skin.slice("ui_ribbon")
	if not (uri and slice and parent and parent:IsA("GuiObject")) then
		return nil
	end
	local ribbon = make("ImageLabel", {
		Name = label.Name .. "Ribbon",
		BackgroundTransparency = 1,
		Image = uri,
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(slice.center[1], slice.center[2], slice.center[3], slice.center[4]),
		Active = false,
	}) :: ImageLabel
	local function sync()
		local h = label.Size.Y.Offset + 10
		local s = SkinMath.sliceScale(slice, 0, h, Theme.dense())
		local x, y, ew, eh = SkinMath.frameRect(slice, s)
		ribbon.SliceScale = s
		ribbon.AnchorPoint = label.AnchorPoint
		ribbon.Position = label.Position + UDim2.fromOffset(x - 14, y - 5)
		ribbon.Size = label.Size + UDim2.fromOffset(ew + 28, eh + 10)
		ribbon.Visible = label.Visible
		ribbon.ZIndex = label.ZIndex - 1
	end
	for _, prop in { "Position", "Size", "Visible", "ZIndex", "AnchorPoint" } do
		label:GetPropertyChangedSignal(prop):Connect(sync)
	end
	label.Destroying:Connect(function()
		ribbon:Destroy()
	end)
	sync()
	ribbon.Parent = parent
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextColor3 = Theme.C.cream
	Theme.textStroke(Theme.C.brownDark, 2).Parent = label
	return ribbon
end

-- Card frame on a hand-built card (shop grid / rows, lobby pads): a tinted
-- base in the card's own colour plus the rarity frame. No-op until uploaded.
function Theme.skinCard(f: GuiObject, rarity: any?): boolean
	local base = Skin.layer(f, "ui_card_base", { name = "Skin", tint = f.BackgroundColor3 })
	if not base then
		return false
	end
	Skin.stripFlat(f)
	Skin.ownBackground(f, base, { tintFromColor = true })
	Skin.revertOnLayout(f)
	local tex, tint = SkinMath.rarityTexture(rarity)
	local fr = Skin.layer(f, tex, { name = "RaritySkin", z = Skin.Z + 1 })
	if fr then
		fr.ImageColor3 = if tint then Color3.fromRGB(tint[1], tint[2], tint[3]) else WHITE
	end
	return true
end

-- Notification dot (a small round frame): the glowing dot texture.
function Theme.skinDot(d: GuiObject): boolean
	local layer = Skin.layer(d, "ui_dot", { fit = true, grow = 1.7 })
	if not layer then
		return false
	end
	Skin.stripFlat(d)
	Skin.ownBackground(d, layer, { maxAlpha = 0 })
	return true
end

-- Text field: `f` is a container (no layout) holding the TextBox `box`. Draws
-- the input texture (set 2), swapped to the focused one while `box` has focus.
-- No-op (flat look kept) until that texture is uploaded.
function Theme.skinInput(f: GuiObject, box: TextBox?): boolean
	local layer = Skin.layer(f, "ui_input")
	if not layer then
		return false
	end
	Skin.stripFlat(f)
	Skin.ownBackground(f, layer, { maxAlpha = 0 })
	if box then
		box.BackgroundTransparency = 1
		box.Focused:Connect(function()
			if Skin.has("ui_input_focus") then
				Skin.setLayer(layer, "ui_input_focus")
			end
		end)
		box.FocusLost:Connect(function()
			Skin.setLayer(layer, "ui_input")
		end)
	end
	return true
end

-- Wood plank background for a bar frame (lobby bar): the tiled wood strip.
-- A frame that lays out its children gets the wood as a sibling behind it
-- (mirroring position, size, visibility and its compact PopScale).
function Theme.skinWood(f: GuiObject): boolean
	-- set 1 only: set 2 has no wood (use Theme.dock for bars)
	local uri = if Skin.set() == "ui" then Skin.uri("ui_wood_strip") else nil
	local holder = f.Parent
	local sibling = f:FindFirstChildWhichIsA("UIGridStyleLayout") ~= nil
	if not uri or not holder or (sibling and holder:FindFirstChildWhichIsA("UIGridStyleLayout")) then
		return false
	end
	local corner = f:FindFirstChildOfClass("UICorner")
	local layer = make("ImageLabel", {
		Name = if sibling then f.Name .. "Wood" else "Skin",
		BackgroundTransparency = 1,
		Image = uri,
		ScaleType = Enum.ScaleType.Tile,
		ZIndex = if sibling then f.ZIndex - 1 else Skin.Z,
		Size = UDim2.fromScale(1, 1),
		Active = false,
	}) :: ImageLabel
	if corner then
		make("UICorner", { CornerRadius = corner.CornerRadius, Parent = layer })
	end
	local function tile()
		local h = math.max(8, f.AbsoluteSize.Y / Theme.scaleOf(f))
		layer.TileSize = UDim2.fromOffset(h * 8, h)
	end
	tile()
	f:GetPropertyChangedSignal("AbsoluteSize"):Connect(tile)
	if sibling then
		local scale = make("UIScale", { Parent = layer }) :: UIScale
		local function sync()
			layer.AnchorPoint = f.AnchorPoint
			layer.Position = f.Position
			layer.Size = f.Size
			layer.Visible = f.Visible
			layer.ZIndex = f.ZIndex - 1
			local ps = f:FindFirstChild("PopScale")
			scale.Scale = if ps and ps:IsA("UIScale") then ps.Scale else 1
		end
		for _, prop in { "AnchorPoint", "Position", "Size", "Visible", "ZIndex" } do
			f:GetPropertyChangedSignal(prop):Connect(sync)
		end
		local function watchScale(ch: Instance)
			if ch:IsA("UIScale") and ch.Name == "PopScale" then
				ch:GetPropertyChangedSignal("Scale"):Connect(sync)
				sync()
			end
		end
		for _, ch in f:GetChildren() do
			watchScale(ch)
		end
		f.ChildAdded:Connect(watchScale)
		f.Destroying:Connect(function()
			layer:Destroy()
		end)
		sync()
		layer.Parent = holder
	else
		layer.Parent = f
	end
	f:SetAttribute("Skinned", true)
	Skin.ownBackground(f, layer, { maxAlpha = 0 })
	return true
end

-- Icon texture by name ("ui_icon_cheese", "ui_class_filet", ...), or nil.
function Theme.iconImage(name: string, size: number, props: { [string]: any }?): ImageLabel?
	return Skin.iconImage(name, size, props)
end

-- Class emblem image for a class id, or nil until uploaded.
function Theme.classEmblem(classId: string, size: number, props: { [string]: any }?): ImageLabel?
	return Skin.iconImage("ui_class_" .. classId, size, props)
end

----------------------------------------------------------------------
-- Panels, cards, buttons
----------------------------------------------------------------------

-- Cream panel with a gradient, a rind-brown border and a drop shadow.
function Theme.panel(props: { [string]: any }): Frame
	local base: { [string]: any } = {
		BackgroundColor3 = Theme.C.cream,
		BorderSizePixel = 0,
	}
	for k, v in props do
		base[k] = v
	end
	local f = make("Frame", base)
	Theme.corner(16).Parent = f
	local stroke = Theme.stroke(Theme.C.brown, 4)
	stroke.Parent = f
	Theme.gradient(stroke, Theme.C.brown, Theme.C.brownDark)
	Theme.gloss(f, 1, 0.9)
	local function shadow()
		Theme.dropShadow(f, 7, 0.6)
	end
	if not skinPanel(f, nil, shadow) then
		shadow()
	end
	return f
end

-- Dark premium HUD card: rind-brown glass with a gold gradient frame.
-- `opts.accent` replaces the gold stroke with a flat accent colour;
-- `opts.shadow = false` skips the drop shadow (e.g. inside layouts).
function Theme.card(
	props: { [string]: any },
	opts: { accent: Color3?, shadow: boolean?, stroke: number? }?
): Frame
	local o = opts or {}
	local base: { [string]: any } = {
		BackgroundColor3 = Theme.C.rind,
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
	}
	for k, v in props do
		base[k] = v
	end
	local f = make("Frame", base)
	Theme.corner(14).Parent = f
	if o.accent then
		local s = Theme.stroke(o.accent, o.stroke or 2)
		s.Parent = f
	else
		Theme.goldStroke(o.stroke or 2, 0.1).Parent = f
	end
	Theme.gradient(f, Color3.fromRGB(255, 240, 220), Color3.fromRGB(150, 130, 110))
	-- Skin: the dark modal texture (thinner frame) for gold-framed cards.
	local function shadow()
		if o.shadow ~= false then
			Theme.dropShadow(f, 5, 0.6)
		end
	end
	local skinned = o.accent == nil and skinFrame(f, "ui_panel_dark", { mul = 0.55 }, nil, shadow) ~= nil
	if not skinned then
		shadow()
	end
	return f
end

-- Small rounded pill label ("EXTRACTED", "BOT", "LV 7"...).
function Theme.badge(text: string, color: Color3, props: { [string]: any }?): TextLabel
	local base: { [string]: any } = {
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 20),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Font = Theme.FONT,
		Text = text,
		TextColor3 = Theme.C.white,
		TextSize = Theme.TYPE.micro,
		TextWrapped = false,
	}
	if props then
		for k, v in props do
			base[k] = v
		end
	end
	local l = make("TextLabel", base) :: TextLabel
	Theme.round().Parent = l
	Theme.padding(8, 0).Parent = l
	Theme.gloss(l, 1, 0.8)
	Theme.textStroke(Theme.C.brownDark, 1).Parent = l
	-- Set 2 only (set 1 kept its flat badges): a tinted pill texture.
	if Skin.set() == "ui2" then
		local layer = Skin.layer(l, "ui_badge", { tint = color, outset = 8 })
		if layer then
			Skin.stripFlat(l)
			Skin.ownBackground(l, layer, { tintFromColor = true })
			Skin.caption(l :: any, 0, 0)
		end
	end
	return l
end

-- Chunky glossy button with hover / press feedback. `onClick` fires on Activated.
function Theme.button(
	text: string,
	color: Color3?,
	props: { [string]: any }?,
	onClick: (() -> ())?,
	kind: string?
): TextButton
	local bg = color or Theme.C.cheese
	local base: { [string]: any } = {
		BackgroundColor3 = bg,
		AutoButtonColor = false,
		Font = Theme.FONT,
		Text = text,
		TextColor3 = Theme.C.ink,
		TextSize = 26,
		TextWrapped = true,
		Size = UDim2.fromOffset(220, Theme.TOUCH),
		Selectable = true,
	}
	if props then
		for k, v in props do
			base[k] = v
		end
	end
	local b = make("TextButton", base) :: TextButton
	Theme.corner(14).Parent = b
	local stroke = Theme.stroke(Theme.C.brownDark, 3)
	stroke.Parent = b
	-- Top-lit gloss (text stays crisp: the gradient only dims the lower half a little).
	make("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(0.55, Color3.new(0.97, 0.97, 0.97)),
			ColorSequenceKeypoint.new(1, Color3.new(0.8, 0.8, 0.8)),
		}),
		Parent = b,
	})
	skinButton(b, kind)
	Theme.hover(b)
	if onClick then
		b.Activated:Connect(function()
			if b.Active then
				onClick()
			end
		end)
	end
	return b
end

-- Enables/disables a Theme.button visually.
function Theme.setEnabled(b: GuiButton, enabled: boolean)
	b.Active = enabled
	b.AutoButtonColor = false
	b.BackgroundTransparency = if enabled then 0 else 0.45
	if b:IsA("TextButton") then
		b.TextTransparency = if enabled then 0 else 0.4
	end
end

export type Bar = {
	frame: Frame,
	fill: Frame,
	text: TextLabel,
	set: (frac: number, text: string?) -> (),
	setColor: (c: Color3) -> (),
}

-- Horizontal progress bar with a centred caption, a glossy gradient fill and,
-- with `opts.trail`, a light "damage trail" that eases down after a drop.
function Theme.bar(props: { [string]: any }, fillColor: Color3?, opts: { trail: boolean? }?): Bar
	local base: { [string]: any } = {
		BackgroundColor3 = Theme.C.shade,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(260, 26),
		ClipsDescendants = false,
	}
	for k, v in props do
		base[k] = v
	end
	local frame = make("Frame", base) :: Frame
	Theme.corner(8).Parent = frame
	Theme.stroke(Theme.C.brownDark, 2).Parent = frame
	local trail: Frame? = nil
	if opts and opts.trail then
		local t = make("Frame", {
			Name = "Trail",
			BackgroundColor3 = Theme.C.cream,
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Parent = frame,
		}) :: Frame
		Theme.corner(8).Parent = t
		trail = t
	end
	local fill = make("Frame", {
		Name = "Fill",
		BackgroundColor3 = fillColor or Theme.C.hp,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	}) :: Frame
	Theme.corner(8).Parent = fill
	make("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(0.45, Color3.new(0.92, 0.92, 0.92)),
			ColorSequenceKeypoint.new(1, Color3.new(0.68, 0.68, 0.68)),
		}),
		Parent = fill,
	})
	-- Gloss highlight along the top edge.
	local shine = make("Frame", {
		Name = "Shine",
		BackgroundColor3 = Theme.C.white,
		BackgroundTransparency = 0.72,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 4, 0, 2),
		Size = UDim2.new(1, -8, 0.32, 0),
		Parent = fill,
	})
	Theme.round().Parent = shine
	local text = Theme.label({
		Size = UDim2.fromScale(1, 1),
		TextSize = 18,
		ZIndex = 3,
		Parent = frame,
	})
	Theme.textStroke().Parent = text
	-- Skin: wooden groove frame; the fill sits inside it as a tinted capsule.
	local frameLayer = skinFrame(frame, "ui_bar_frame", nil, 0)
	local fillLayer = if frameLayer
		then Skin.layer(fill, "ui_bar_fill", { tint = fill.BackgroundColor3 })
		else nil
	if frameLayer and fillLayer then
		local barSlice = Skin.slice("ui_bar_frame")
		local inset = barSlice and barSlice.inset
		local pad = make("UIPadding", { Name = "SkinInset", Parent = frame }) :: UIPadding
		local function place()
			local s = frameLayer.SliceScale
			local i = inset or { 8, 8, 8, 8 }
			pad.PaddingLeft = UDim.new(0, i[1] * s)
			pad.PaddingTop = UDim.new(0, i[2] * s)
			pad.PaddingRight = UDim.new(0, i[3] * s)
			pad.PaddingBottom = UDim.new(0, i[4] * s)
			-- the caption spans the whole bar, not just the groove
			text.Position = UDim2.fromOffset(-i[1] * s, -i[2] * s)
			text.Size = UDim2.new(1, (i[1] + i[3]) * s, 1, (i[2] + i[4]) * s)
		end
		place()
		frameLayer:GetPropertyChangedSignal("SliceScale"):Connect(place)
		Skin.stripFlat(fill)
		Skin.ownBackground(fill, fillLayer, { tintFromColor = true })
		shine.Visible = false
	end
	local last = -1
	local trailTween: Tween? = nil
	return {
		frame = frame,
		fill = fill,
		text = text,
		set = function(frac: number, caption: string?)
			local f = math.clamp(if frac == frac then frac else 0, 0, 1)
			if math.abs(f - last) > 0.001 then
				local dropped = last >= 0 and f < last
				last = f
				fill.Size = UDim2.fromScale(f, 1)
				fill.Visible = f > 0.001
				local tr = trail
				if tr then
					if trailTween then
						trailTween:Cancel()
					end
					if dropped then
						trailTween = TweenService:Create(
							tr,
							TweenInfo.new(
								0.45,
								Enum.EasingStyle.Quad,
								Enum.EasingDirection.Out,
								0,
								false,
								0.25
							),
							{ Size = UDim2.fromScale(f, 1) }
						);
						(trailTween :: Tween):Play()
					else
						tr.Size = UDim2.fromScale(f, 1)
					end
				end
			end
			if caption then
				text.Text = caption
			end
		end,
		setColor = function(c: Color3)
			fill.BackgroundColor3 = c
		end,
	}
end

export type Radial = { frame: Frame, set: (frac: number) -> () }

-- Clockwise radial fill overlay (frac 0..1 of the circle filled), built from
-- two clipped half-circles with rotated UIGradients. Fills its parent.
function Theme.radial(parent: GuiObject, color: Color3, transparency: number?): Radial
	local alpha = transparency or 0.35
	local frame = make("Frame", {
		Name = "Radial",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = (parent.ZIndex or 1) + 1,
		Parent = parent,
	}) :: Frame
	local function half(isRight: boolean): UIGradient
		local clip = make("Frame", {
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Position = if isRight then UDim2.fromScale(0.5, 0) else UDim2.fromScale(0, 0),
			Size = UDim2.fromScale(0.5, 1),
			ZIndex = frame.ZIndex,
			Parent = frame,
		})
		local circle = make("Frame", {
			BackgroundColor3 = color,
			BackgroundTransparency = alpha,
			BorderSizePixel = 0,
			Position = if isRight then UDim2.fromScale(-1, 0) else UDim2.fromScale(0, 0),
			Size = UDim2.fromScale(2, 1),
			ZIndex = frame.ZIndex,
			Parent = clip,
		})
		Theme.round().Parent = circle
		return make("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.4999, 0),
				NumberSequenceKeypoint.new(0.5, 1),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = circle,
		})
	end
	local right = half(true)
	local left = half(false)
	return {
		frame = frame,
		set = function(frac: number)
			local p = math.clamp(frac, 0, 1)
			frame.Visible = p > 0.001
			right.Rotation = math.clamp(p * 2, 0, 1) * 180
			left.Rotation = 180 + math.clamp(p * 2 - 1, 0, 1) * 180
		end,
	}
end

-- Small rounded chip with optional tooltip text.
function Theme.chip(text: string, color: Color3, tooltip: string?): TextButton
	local dense = Layout.dense(currentScale)
	local h = if dense then 24 else 34
	local b = make("TextButton", {
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, h),
		BackgroundColor3 = color,
		AutoButtonColor = false,
		Font = Theme.FONT,
		Text = text,
		TextColor3 = Theme.C.white,
		TextSize = if dense then 14 else 18,
	}) :: TextButton
	Theme.corner(h // 2).Parent = b
	Theme.padding(if dense then 9 else 12, 0).Parent = b
	Theme.stroke(Theme.C.brownDark, 2).Parent = b
	Theme.textStroke(Theme.C.brownDark, 1.5).Parent = b
	Theme.gloss(b, 1, 0.78)
	if tooltip and tooltip ~= "" then
		Theme.tooltip(b, tooltip)
	end
	return b
end

----------------------------------------------------------------------
-- Icons, rarity, squads
----------------------------------------------------------------------

-- Primitive-built icon (UI/Icons): kind, size in design px, tint.
-- Kinds with a texture (SkinMath.ICON_KINDS) use it once uploaded; a greyish
-- tint (a "not earned / locked" look) still greys the texture.
function Theme.icon(kind: string, size: number, color: Color3?, props: { [string]: any }?): Frame
	local tex = SkinMath.ICON_KINDS[kind]
	local img = if tex then Skin.iconImage(tex, size, { Size = UDim2.fromScale(1, 1) }) else nil
	if not img then
		return Icons.make(kind, size, color, props)
	end
	local holder = make("Frame", {
		Name = "Icon_" .. kind,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
	}) :: Frame
	if color then
		local _, sat, v = color:ToHSV()
		if sat < 0.15 and v < 0.8 then
			img.ImageColor3 = color:Lerp(WHITE, 0.3)
		end
	end
	img.Parent = holder
	if props then
		for k, v in props do
			if k ~= "Parent" then
				(holder :: any)[k] = v
			end
		end
		if props.Parent then
			holder.Parent = props.Parent
		end
	end
	return holder
end

Theme.Icons = Icons

function Theme.rarityColor(rarity: any): Color3
	local r = tostring(rarity or "Common")
	r = string.upper(string.sub(r, 1, 1)) .. string.lower(string.sub(r, 2))
	return Theme.RARITY[r] or Theme.RARITY.Common
end

-- Frames a slot / card in its rarity colour: a thick stroke and an inner glow.
function Theme.rarityFrame(obj: GuiObject, rarity: any): UIStroke
	local color = Theme.rarityColor(rarity)
	local stroke = obj:FindFirstChild("RarityStroke") :: UIStroke?
	if not stroke then
		local s = Theme.stroke(color, 3)
		s.Name = "RarityStroke"
		s.Parent = obj
		stroke = s
	end
	local glow = obj:FindFirstChild("RarityGlow") :: Frame?
	if not glow then
		local g = make("Frame", {
			Name = "RarityGlow",
			BackgroundColor3 = Theme.C.white,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			ZIndex = obj.ZIndex,
			Parent = obj,
		})
		local corner = obj:FindFirstChildOfClass("UICorner")
		make(
			"UICorner",
			{ CornerRadius = if corner then corner.CornerRadius else UDim.new(0, 12), Parent = g }
		)
		make("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.55, 0.85),
				NumberSequenceKeypoint.new(1, 0.45),
			}),
			Parent = g,
		})
		glow = g
	end
	local st = stroke :: UIStroke
	st.Color = color;
	(glow :: Frame).BackgroundColor3 = color
	-- Skin: the rarity card frame (gem corners on Legendary) replaces both.
	local tex, tint = SkinMath.rarityTexture(rarity)
	local fr = Skin.layer(obj, tex, { name = "RaritySkin", z = Skin.Z + 1 })
	if fr then
		fr.ImageColor3 = if tint then Color3.fromRGB(tint[1], tint[2], tint[3]) else WHITE
		st.Enabled = false
		(glow :: Frame).Visible = false
	end
	return st
end

-- Squad display info: (name, Color3) for squad id 1..4 (Util/Squads), with a
-- grey fallback for unknown ids.
function Theme.squad(id: any): (string, Color3)
	local n = tonumber(id)
	local def = if SquadsOk
			and n
			and type(SquadsMod) == "table"
			and SquadsMod.LIST
		then SquadsMod.LIST[n]
		else nil
	if def then
		local c = def.color
		return tostring(def.name), Color3.fromRGB(c[1], c[2], c[3])
	end
	return if n then "Squad " .. tostring(n) else "Squad", Theme.C.grey
end

-- Readable text colour on top of `bg` (ink on light colours, white on dark).
function Theme.onColor(bg: Color3): Color3
	local l = 0.299 * bg.R + 0.587 * bg.G + 0.114 * bg.B
	return if l > 0.62 then Theme.C.ink else Theme.C.white
end

----------------------------------------------------------------------
-- Tooltip (single shared label in its own ScreenGui)
----------------------------------------------------------------------

local tooltipGui: ScreenGui? = nil
local tooltipLabel: TextLabel? = nil
local tooltipOwner: GuiObject? = nil
local tooltipToken = 0

local function ensureTooltip(): TextLabel
	if tooltipLabel and tooltipGui and tooltipGui.Parent then
		return tooltipLabel
	end
	local player = Players.LocalPlayer
	local gui = make("ScreenGui", {
		Name = "TrunkfallTooltip",
		ResetOnSpawn = false,
		DisplayOrder = 100,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local label = make("TextLabel", {
		Visible = false,
		RichText = true,
		BackgroundColor3 = Theme.C.rind,
		BackgroundTransparency = 0.04,
		TextColor3 = Theme.C.cream,
		Font = Theme.FONT_BODY,
		TextSize = 16,
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromOffset(280, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = gui,
	})
	Theme.corner(8).Parent = label
	Theme.padding(10, 8).Parent = label
	Theme.goldStroke(2).Parent = label
	tooltipGui = gui
	tooltipLabel = label
	return label
end

local function showTooltip(owner: GuiObject, text: string)
	local label = ensureTooltip()
	tooltipOwner = owner
	tooltipToken += 1
	label.Text = text
	label.TextSize = math.floor(15 * math.max(currentScale, 0.85))
	label.Size = UDim2.fromOffset(math.floor(280 * math.max(currentScale, 0.85)), 0)
	local pos = owner.AbsolutePosition
	local size = owner.AbsoluteSize
	local gui = tooltipGui :: ScreenGui
	local maxX = gui.AbsoluteSize.X - label.Size.X.Offset - 8
	local x = math.clamp(pos.X, 8, math.max(8, maxX))
	-- Owners in the lower half get the tooltip above them, so it stays on screen.
	if pos.Y + size.Y / 2 > gui.AbsoluteSize.Y * 0.5 then
		label.AnchorPoint = Vector2.new(0, 1)
		label.Position = UDim2.fromOffset(x, pos.Y - 6)
	else
		label.AnchorPoint = Vector2.new(0, 0)
		label.Position = UDim2.fromOffset(x, pos.Y + size.Y + 6)
	end
	label.Visible = true
end

local function hideTooltip(owner: GuiObject?)
	if tooltipLabel and (owner == nil or owner == tooltipOwner) then
		tooltipLabel.Visible = false
		tooltipOwner = nil
	end
end

-- Hover (mouse) or tap (touch, auto-hides after 3 s) tooltip on any GuiObject.
-- `text` may be a function, read each time the tooltip opens (live gear,
-- perk states…); an empty result shows nothing.
function Theme.tooltip(obj: GuiObject, text: string | () -> string)
	local function resolve(): string
		if type(text) == "function" then
			local ok, res = pcall(text)
			return if ok and type(res) == "string" then res else ""
		end
		return text :: string
	end
	obj.MouseEnter:Connect(function()
		local t = resolve()
		if t ~= "" then
			showTooltip(obj, t)
		end
	end)
	obj.MouseLeave:Connect(function()
		hideTooltip(obj)
	end)
	if obj:IsA("GuiButton") then
		(obj :: GuiButton).Activated:Connect(function()
			if UserInputService.TouchEnabled then
				if tooltipOwner == obj and tooltipLabel and tooltipLabel.Visible then
					hideTooltip(obj)
					return
				end
				local t = resolve()
				if t == "" then
					return
				end
				showTooltip(obj, t)
				local token = tooltipToken
				task.delay(3, function()
					if tooltipToken == token then
						hideTooltip(obj)
					end
				end)
			end
		end)
	end
	obj.Destroying:Connect(function()
		hideTooltip(obj)
	end)
end

----------------------------------------------------------------------
-- ScreenGui + scaled root
----------------------------------------------------------------------

export type Screen = {
	gui: ScreenGui,
	root: Frame,
	destroy: () -> (),
	-- Current root size in design px.
	rootSize: () -> Vector2,
	-- Calls fn(rootSize) now and after every refit. Returns a disconnect function.
	onResize: (fn: (Vector2) -> ()) -> () -> (),
}

-- Creates a ScreenGui with a design-space root frame. Children of `root` use
-- design pixels; the UIScale maps them to the device. The ScreenGui respects
-- the core-UI and device safe insets (ScreenInsets.CoreUISafeInsets with
-- IgnoreGuiInset = false), so the root never sits under the top bar or a notch.
function Theme.screen(name: string, displayOrder: number?): Screen
	local menuScreen = Theme.MENU_SCREENS[name] == true
	local player = Players.LocalPlayer
	local gui = make("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = displayOrder or 10,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
	}) :: ScreenGui
	local root = make("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	}) :: Frame
	local uiScale = make("UIScale", { Parent = root }) :: UIScale
	local rootSize = Vector2.new(Layout.DESIGN_W, Layout.DESIGN_H)

	-- Text floor: every text object keeps its authored size as the
	-- "DesignTextSize" attribute and renders at Layout.textSize(...) so small
	-- phones still get readable text after the UIScale shrink.
	local applyingText = false
	local textConns: { RBXScriptConnection } = {}
	local function floorText(obj: Instance)
		if not (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")) then
			return
		end
		local t = obj :: any
		local design = t:GetAttribute("DesignTextSize")
		if type(design) ~= "number" then
			design = t.TextSize
			t:SetAttribute("DesignTextSize", design)
			table.insert(
				textConns,
				t:GetPropertyChangedSignal("TextSize"):Connect(function()
					if applyingText then
						return
					end
					-- Code changed the size: treat it as the new design size.
					t:SetAttribute("DesignTextSize", t.TextSize)
					floorText(t)
				end)
			)
		end
		local want = Layout.textSize(design, currentScale * restScaleOf(t), Device.hasTouch(), menuScreen)
		if t.TextSize ~= want then
			applyingText = true
			t.TextSize = want
			applyingText = false
		end
	end
	table.insert(
		textConns,
		root.DescendantAdded:Connect(function(obj)
			task.defer(floorText, obj)
		end)
	)
	local listeners: { [number]: (Vector2) -> () } = {}
	local nextListener = 0

	local function fit()
		local abs = gui.AbsoluteSize
		local w, h = abs.X, abs.Y
		if w < 4 or h < 4 then
			local cw, ch = cameraViewport()
			if not cw or not ch then
				return
			end
			w, h = cw, ch
		end
		local s = Layout.fitScale(w, h)
		currentScale = s
		Theme.TOUCH = Layout.touchSize(s, Device.hasTouch())
		Theme.SLIM = Layout.slimSize(s, Device.hasTouch())
		uiScale.Scale = s
		for _, obj in root:GetDescendants() do
			floorText(obj)
		end
		local rw, rh = Layout.rootSize(w, h, s)
		root.Size = UDim2.fromOffset(rw, rh)
		local size = Vector2.new(rw, rh)
		if (size - rootSize).Magnitude > 0.5 then
			rootSize = size
			for _, fn in listeners do
				task.spawn(fn, size)
			end
		end
	end
	local conn = gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	gui.Parent = player:WaitForChild("PlayerGui")
	fit()
	task.defer(fit)

	return {
		gui = gui,
		root = root,
		destroy = function()
			conn:Disconnect()
			for _, c in textConns do
				c:Disconnect()
			end
			table.clear(listeners)
			gui:Destroy()
		end,
		rootSize = function()
			return rootSize
		end,
		onResize = function(fn: (Vector2) -> ()): () -> ()
			nextListener += 1
			local id = nextListener
			listeners[id] = fn
			fn(rootSize)
			return function()
				listeners[id] = nil
			end
		end,
	}
end

-- Keeps `frame` at wantW x wantH design px, capped to the screen root minus
-- `margin` on each side (and `reserveY` extra height, e.g. a bottom bar).
-- Content inside should scroll (Theme.scroller) when the cap kicks in.
function Theme.fitFrame(
	screen: Screen,
	frame: GuiObject,
	wantW: number,
	wantH: number,
	margin: number?,
	reserveY: number?
): () -> ()
	return screen.onResize(function(size: Vector2)
		local m = margin or 10
		frame.Size =
			UDim2.fromOffset(Layout.cap(wantW, size.X, m), Layout.cap(wantH, size.Y - (reserveY or 0), m))
	end)
end

-- Vertical ScrollingFrame whose canvas grows with its content.
function Theme.scroller(props: { [string]: any }): ScrollingFrame
	local base: { [string]: any } = {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 10,
		ScrollBarImageColor3 = Theme.C.brown,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		Selectable = false,
	}
	for k, v in props do
		base[k] = v
	end
	return make("ScrollingFrame", base) :: ScrollingFrame
end

-- Pops a GuiObject in with a quick scale tween (adds a UIScale if needed).
function Theme.popIn(obj: GuiObject)
	local s = obj:FindFirstChild("PopScale") :: UIScale?
	if not s then
		local ns = make("UIScale", { Name = "PopScale", Parent = obj })
		s = ns
	end
	local sc = s :: UIScale
	local base = baseScale(obj)
	sc.Scale = 0.85 * base
	TweenService
		:Create(sc, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = base })
		:Play()
end

-- Rests a big panel at `factor` of its design size on dense (PC) screens
-- (v3: lobby, results, perk tree, scoreboard, shop, Shop Cart are 30-40%
-- smaller there). Phones keep 1: their text floor already binds. Uses the
-- panel's PopScale (pop-ins tween back to this rest scale), and the text
-- floor counts it, so text inside never renders under the floor.
function Theme.compact(obj: GuiObject, factor: number?): number
	local f = if Layout.dense(currentScale) then math.clamp(factor or UiSizes.PANEL_COMPACT, 0.5, 1) else 1
	obj:SetAttribute("BaseScale", f)
	local s = obj:FindFirstChild("PopScale") :: UIScale?
	if not s then
		s = make("UIScale", { Name = "PopScale", Parent = obj })
	end
	(s :: UIScale).Scale = f
	return f
end

Skin.bind(Theme.scaleOf, Theme.dense)

return Theme
