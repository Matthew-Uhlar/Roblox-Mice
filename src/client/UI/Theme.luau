--!strict
-- Shared look & feel: cheese-yellow / cream / brown palette, fonts, and small
-- component builders. Every ScreenGui gets a design-space root frame scaled by
-- a UIScale computed from the safe viewport (Util/Layout), so layouts are
-- authored once at 1100x620 design pixels and always fit, down to small
-- phones. Touch targets follow a separate rule (Theme.TOUCH, see Layout).

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Device = require(Client.Util.Device)
local Layout = require(Client.Util.Layout)

local Theme = {}

Theme.C = {
	cheese = Color3.fromRGB(255, 204, 51),
	cheeseDark = Color3.fromRGB(232, 162, 32),
	cream = Color3.fromRGB(255, 244, 214),
	creamDark = Color3.fromRGB(238, 222, 184),
	brown = Color3.fromRGB(110, 70, 40),
	brownDark = Color3.fromRGB(62, 38, 22),
	ink = Color3.fromRGB(48, 30, 18),
	white = Color3.fromRGB(255, 255, 255),
	red = Color3.fromRGB(226, 72, 58),
	green = Color3.fromRGB(96, 190, 92),
	blue = Color3.fromRGB(72, 142, 230),
	purple = Color3.fromRGB(160, 92, 224),
	orange = Color3.fromRGB(255, 140, 40),
	grey = Color3.fromRGB(150, 150, 150),
	hp = Color3.fromRGB(110, 210, 90),
	hpLow = Color3.fromRGB(235, 80, 60),
	xp = Color3.fromRGB(110, 190, 255),
	shade = Color3.fromRGB(20, 12, 6),
}

Theme.RARITY = {
	Common = Color3.fromRGB(165, 165, 165),
	Rare = Color3.fromRGB(72, 142, 230),
	Epic = Color3.fromRGB(160, 92, 224),
	Legendary = Color3.fromRGB(255, 140, 40),
} :: { [string]: Color3 }

Theme.TIER = {
	Low = Color3.fromRGB(96, 190, 92),
	Mid = Color3.fromRGB(245, 196, 40),
	High = Color3.fromRGB(226, 72, 58),
} :: { [string]: Color3 }

Theme.FONT = Enum.Font.FredokaOne -- headings, numbers, buttons
Theme.FONT_BODY = Enum.Font.GothamBold -- descriptions

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

-- Cream panel with a brown border.
function Theme.panel(props: { [string]: any }): Frame
	local base: { [string]: any } = {
		BackgroundColor3 = Theme.C.cream,
		BorderSizePixel = 0,
	}
	for k, v in props do
		base[k] = v
	end
	local f = make("Frame", base)
	Theme.corner(14).Parent = f
	Theme.stroke(Theme.C.brown, 4).Parent = f
	return f
end

-- Chunky button with press feedback. `onClick` fires on Activated.
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
	local scale = make("UIScale", { Scale = 1, Parent = b })
	local hoverInfo = TweenInfo.new(0.08)
	b.MouseEnter:Connect(function()
		if b.Active then
			TweenService:Create(scale, hoverInfo, { Scale = 1.04 }):Play()
		end
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(scale, hoverInfo, { Scale = 1 }):Play()
	end)
	b.MouseButton1Down:Connect(function()
		if b.Active then
			TweenService:Create(scale, hoverInfo, { Scale = 0.94 }):Play()
		end
	end)
	b.MouseButton1Up:Connect(function()
		TweenService:Create(scale, hoverInfo, { Scale = 1 }):Play()
	end)
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

-- Horizontal progress bar with a centred caption.
function Theme.bar(props: { [string]: any }, fillColor: Color3?): Bar
	local base: { [string]: any } = {
		BackgroundColor3 = Theme.C.brownDark,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(260, 26),
	}
	for k, v in props do
		base[k] = v
	end
	local frame = make("Frame", base) :: Frame
	Theme.corner(8).Parent = frame
	Theme.stroke(Theme.C.brownDark, 2).Parent = frame
	local fill = make("Frame", {
		BackgroundColor3 = fillColor or Theme.C.hp,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	}) :: Frame
	Theme.corner(8).Parent = fill
	local text = Theme.label({
		Size = UDim2.fromScale(1, 1),
		TextSize = 18,
		ZIndex = 3,
		Parent = frame,
	})
	Theme.textStroke().Parent = text
	local last = -1
	return {
		frame = frame,
		fill = fill,
		text = text,
		set = function(frac: number, caption: string?)
			local f = math.clamp(frac, 0, 1)
			if math.abs(f - last) > 0.001 then
				last = f
				fill.Size = UDim2.fromScale(f, 1)
				fill.Visible = f > 0.001
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
	if tooltip and tooltip ~= "" then
		Theme.tooltip(b, tooltip)
	end
	return b
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
		BackgroundColor3 = Theme.C.brownDark,
		BackgroundTransparency = 0.05,
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
	Theme.stroke(Theme.C.cheese, 2).Parent = label
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
	label.Position = UDim2.fromOffset(math.clamp(pos.X, 8, math.max(8, maxX)), pos.Y + size.Y + 6)
	label.Visible = true
end

local function hideTooltip(owner: GuiObject?)
	if tooltipLabel and (owner == nil or owner == tooltipOwner) then
		tooltipLabel.Visible = false
		tooltipOwner = nil
	end
end

-- Hover (mouse) or tap (touch, auto-hides after 3 s) tooltip on any GuiObject.
function Theme.tooltip(obj: GuiObject, text: string)
	obj.MouseEnter:Connect(function()
		showTooltip(obj, text)
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
				showTooltip(obj, text)
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
		frame.Size = UDim2.fromOffset(
			Layout.cap(wantW, size.X, m),
			Layout.cap(wantH, size.Y - (reserveY or 0), m)
		)
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
