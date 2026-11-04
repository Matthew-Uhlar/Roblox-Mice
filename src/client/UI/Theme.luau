--!strict
-- Shared look & feel ("premium cheese"): a gold / cream / rind-brown palette,
-- one typography scale, and component builders with gradients, strokes,
-- rounded corners, drop shadows and tweened hover / press states. Icons are
-- drawn from UI primitives (UI/Icons). Every ScreenGui gets a design-space
-- root frame scaled by a UIScale computed from the safe viewport
-- (Util/Layout), so layouts are authored once at 1100x620 design pixels and
-- always fit, down to small phones. Touch targets follow a separate rule
-- (Theme.TOUCH, see Layout), and text never renders under the Layout text floor.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Device = require(Client.Util.Device)
local Layout = require(Client.Util.Layout)
local Icons = require(script.Parent.Icons)

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
do
	local w, h = cameraViewport()
	if w and h then
		currentScale = Layout.fitScale(w, h)
		Theme.TOUCH = Layout.touchSize(currentScale, Device.hasTouch())
	end
end

function Theme.scale(): number
	return currentScale
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
	if obj:GetAttribute("HasShadow") then
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
		if obj.AutomaticSize ~= Enum.AutomaticSize.None then
			local s = math.max(currentScale, 0.05)
			local abs = obj.AbsoluteSize
			local parentScale = 1
			local ps = obj:FindFirstChild("PopScale")
			if ps and ps:IsA("UIScale") then
				parentScale = math.max(ps.Scale, 0.05)
			end
			sh.Size = UDim2.fromOffset(abs.X / s / parentScale, abs.Y / s / parentScale)
		else
			sh.Size = obj.Size
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
	obj.Destroying:Connect(function()
		sh:Destroy()
	end)
	task.defer(sync)
	return sh
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

-- Hover / press feedback for any GuiButton: a scale tween plus a light (hover)
-- or dark (press) overlay. Works with buttons whose colour code changes later.
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
	local hovering = false
	local function to(s: number, color: Color3, alpha: number)
		TweenService:Create(sc, info, { Scale = s }):Play()
		overlay.BackgroundColor3 = color
		TweenService:Create(overlay, info, { BackgroundTransparency = alpha }):Play()
	end
	b.MouseEnter:Connect(function()
		hovering = true
		if b.Active then
			to(up, Theme.C.white, 0.86)
		end
	end)
	b.MouseLeave:Connect(function()
		hovering = false
		to(1, Theme.C.white, 1)
	end)
	b.MouseButton1Down:Connect(function()
		if b.Active then
			to(0.95, Theme.C.shadow, 0.82)
		end
	end)
	b.MouseButton1Up:Connect(function()
		if hovering and b.Active then
			to(up, Theme.C.white, 0.86)
		else
			to(1, Theme.C.white, 1)
		end
	end)
	b.SelectionGained:Connect(function()
		to(up, Theme.C.white, 0.86)
	end)
	b.SelectionLost:Connect(function()
		to(1, Theme.C.white, 1)
	end)
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
	Theme.dropShadow(f, 7, 0.6)
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
	if o.shadow ~= false then
		Theme.dropShadow(f, 5, 0.6)
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
	return l
end

-- Chunky glossy button with hover / press feedback. `onClick` fires on Activated.
function Theme.button(
	text: string,
	color: Color3?,
	props: { [string]: any }?,
	onClick: (() -> ())?
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
	local b = make("TextButton", {
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 34),
		BackgroundColor3 = color,
		AutoButtonColor = false,
		Font = Theme.FONT,
		Text = text,
		TextColor3 = Theme.C.white,
		TextSize = 18,
	}) :: TextButton
	Theme.corner(17).Parent = b
	Theme.padding(12, 0).Parent = b
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
function Theme.icon(kind: string, size: number, color: Color3?, props: { [string]: any }?): Frame
	return Icons.make(kind, size, color, props)
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
	label.TextSize = math.floor(16 * math.max(currentScale, 0.85))
	label.Size = UDim2.fromOffset(math.floor(300 * math.max(currentScale, 0.85)), 0)
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
		local want = Layout.textSize(design, currentScale, Device.hasTouch())
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
	sc.Scale = 0.85
	TweenService
		:Create(sc, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
end

return Theme
