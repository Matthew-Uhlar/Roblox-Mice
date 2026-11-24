--!strict
-- UI skin layer: custom textures (assets/ui, made by scripts/make-ui-textures.py)
-- drawn behind Theme's panels, buttons, tabs, cards, bars, headers and icons.
--
-- Ids come from Shared.Config.AssetIds (written by the "Upload assets"
-- workflow). A texture whose id is missing or 0 is "not uploaded": every
-- function here then returns nil / false and Theme keeps its original look
-- exactly. Slice data is the generated UI/SkinSlices table.
--
--   Skin.has(name) -> boolean            uploaded?
--   Skin.uri(name) -> string?            "rbxassetid://<id>"
--   Skin.layer(obj, name, opts?) -> ImageLabel?
--       a 9-slice ImageLabel filling `obj` (plus the texture's shadow pad),
--       below obj's other children; SliceScale follows obj's size
--   Skin.setLayer(layer, name)           swaps the texture (button states)
--   Skin.ownBackground(obj, layer, opts?) the object's own background is hidden;
--       later BackgroundTransparency / BackgroundColor3 writes go to the image
--   Skin.caption(button) -> Frame?       text drawn above the texture (see below)
--   Skin.iconImage(name, size, props?) -> ImageLabel?
--
-- Text on a TextButton renders BELOW the button's children, so a skinned
-- button hides its own text (TextTransparency 1) and mirrors Text, colour,
-- font, size, alignment and transparency onto a child "SkinContent" label.
-- Code that reads or writes button.Text keeps working unchanged. A leading
-- emoji with an icon texture ("🧀 120") becomes an icon image + "120".
--
-- Texture sets: code always names the ui_ texture ("ui_btn_primary"). Once
-- set 2 is uploaded (its marker ui2_panel has an id), Skin.resolve maps each
-- name to its ui2_ twin when that one is uploaded too (icons and emblems have
-- no twin and stay ui_). Until then everything resolves to the ui_ set, so
-- the live look is unchanged. Skin.set() tells Theme which set is active.

local Client = script.Parent.Parent
local Assets = require(Client.Visuals.Assets)
local SkinMath = require(script.Parent.SkinMath)
local SkinSlices = require(script.Parent.SkinSlices)
local IconMath = require(script.Parent.IconMath)

local Skin = {}

Skin.Math = SkinMath
Skin.SLICES = SkinSlices.slices :: { [string]: SkinMath.Slice }

-- Lowest ZIndex for skin images: under any child a UI builds (children default to 1).
Skin.Z = -2

local override: { [string]: number }? = nil
local scaleOfFn: (Instance) -> number = function(_obj: Instance)
	return 1
end
local denseFn: () -> boolean = function()
	return false
end

-- Theme hands over its scale helpers (avoids a require cycle).
function Skin.bind(scaleOf: (Instance) -> number, dense: () -> boolean)
	scaleOfFn = scaleOf
	denseFn = dense
end

-- Test hook: pretend these textures are uploaded (nil restores AssetIds).
function Skin.setIds(ids: { [string]: number }?)
	override = ids
end

local function rawId(name: string): number?
	local ids = override or Assets.ids()
	local v = ids[name]
	if type(v) == "number" and v > 0 then
		return v
	end
	return nil
end

Skin.SET2_MARKER = "ui2_panel"

-- "ui2" once the second set is uploaded, else "ui".
function Skin.set(): string
	return if rawId(Skin.SET2_MARKER) then "ui2" else "ui"
end

-- The texture actually drawn for a ui_ name (see the header).
function Skin.resolve(name: string): string
	if string.sub(name, 1, 3) == "ui_" and rawId(Skin.SET2_MARKER) then
		local twin = "ui2_" .. string.sub(name, 4)
		if rawId(twin) then
			return twin
		end
	end
	return name
end

function Skin.id(name: string): number?
	return rawId(Skin.resolve(name))
end

-- Slice data of the texture drawn for `name`.
function Skin.slice(name: string): SkinMath.Slice?
	return Skin.SLICES[Skin.resolve(name)]
end

function Skin.has(name: string): boolean
	return Skin.id(name) ~= nil
end

function Skin.uri(name: string): string?
	local id = Skin.id(name)
	return if id then "rbxassetid://" .. tostring(id) else nil
end

local function make(className: string, props: { [string]: any }): any
	local inst = Instance.new(className) :: any
	local parent = props.Parent
	for k, v in props do
		if k ~= "Parent" then
			inst[k] = v
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

----------------------------------------------------------------------
-- 9-slice layers
----------------------------------------------------------------------

export type LayerOpts = {
	name: string?, -- child name (default "Skin")
	z: number?, -- ZIndex (default Skin.Z)
	tint: Color3?, -- ImageColor3
	mul: number?, -- SliceScale multiplier
	outset: number?, -- draw this many design px wider on each side (a UIPadding on obj)
	fit: boolean?, -- ScaleType.Fit (round textures like the close button)
	grow: number?, -- Fit only: draw this much bigger than the object
}

-- What the skin changed on an object, so Skin.revert can restore the flat look.
type State = {
	conns: { RBXScriptConnection },
	layers: { Instance },
	stripped: { Instance },
}
local states: { [Instance]: State } = setmetatable({}, { __mode = "k" }) :: any

local function stateOf(obj: Instance): State
	local st = states[obj]
	if not st then
		st = { conns = {}, layers = {}, stripped = {} }
		states[obj] = st
	end
	return st :: State
end

local function hasLayout(obj: Instance): boolean
	return obj:FindFirstChildWhichIsA("UIGridStyleLayout") ~= nil
end

local function designSize(obj: GuiObject): Vector2
	local s = scaleOfFn(obj)
	local a = obj.AbsoluteSize
	if a.X < 1 and a.Y < 1 then
		-- not laid out yet: use the offset size
		return Vector2.new(obj.Size.X.Offset, obj.Size.Y.Offset)
	end
	return Vector2.new(a.X / s, a.Y / s)
end

-- Live readability fix (iteration 6): a UIPadding on the skinned frame insets
-- every child, the background layer too, so the card texture drew smaller than
-- the frame and the text sat on (or past) its border. The layer grows back out
-- by the padding: (left, top, left + right, top + bottom) offsets.
local function padOf(obj: Instance): (number, number, number, number)
	local p = obj:FindFirstChildOfClass("UIPadding")
	if not p then
		return 0, 0, 0, 0
	end
	local l, t = p.PaddingLeft.Offset, p.PaddingTop.Offset
	return l, t, l + p.PaddingRight.Offset, t + p.PaddingBottom.Offset
end

-- Places / scales `layer` for its parent's current size.
local function fitLayer(layer: ImageLabel)
	local obj = layer.Parent
	if not (obj and obj:IsA("GuiObject")) then
		return
	end
	local pl, pt, pw, ph = padOf(obj)
	local name = layer:GetAttribute("SkinTexture")
	if type(name) ~= "string" then
		return
	end
	if layer:GetAttribute("SkinFit") then
		local g = layer:GetAttribute("SkinGrow")
		local grow = if type(g) == "number" then g else 1
		layer.AnchorPoint = Vector2.new(0.5, 0.5)
		layer.Position = UDim2.new(0.5, pw / 2 - pl, 0.5, ph / 2 - pt)
		layer.Size = UDim2.new(grow, pw * grow, grow, ph * grow)
		return
	end
	local slice = Skin.slice(name)
	if not slice then
		layer.Position = UDim2.fromOffset(-pl, -pt)
		layer.Size = UDim2.new(1, pw, 1, ph)
		return
	end
	local m = layer:GetAttribute("SkinMul")
	local d = designSize(obj :: GuiObject)
	local s = SkinMath.sliceScale(slice, d.X, d.Y, denseFn(), if type(m) == "number" then m else nil)
	local x, y, ew, eh = SkinMath.frameRect(slice, s)
	layer.SliceScale = s
	local out = layer:GetAttribute("SkinOutset")
	local ox = if type(out) == "number" then out else 0
	layer.Position = UDim2.fromOffset(x - ox - pl, y - pt)
	layer.Size = UDim2.new(1, ew + 2 * ox + pw, 1, eh + ph)
end

-- Sets the texture of a layer (keeps its size logic).
function Skin.setLayer(layer: ImageLabel, name: string)
	local uri = Skin.uri(name)
	if not uri then
		return
	end
	if layer:GetAttribute("SkinTexture") == name then
		return
	end
	layer:SetAttribute("SkinTexture", name)
	layer.Image = uri
	local slice = Skin.slice(name)
	if slice and not layer:GetAttribute("SkinFit") then
		layer.ScaleType = Enum.ScaleType.Slice
		local c = slice.center
		layer.SliceCenter = Rect.new(c[1], c[2], c[3], c[4])
	else
		layer.ScaleType = Enum.ScaleType.Fit
	end
	fitLayer(layer)
end

-- nil when the texture is not uploaded, or when obj lays out its children
-- (a UIListLayout / UIGridLayout would move the image into a layout slot).
function Skin.layer(obj: GuiObject, name: string, opts: LayerOpts?): ImageLabel?
	if not Skin.has(name) or hasLayout(obj) then
		return nil
	end
	local o = opts or {}
	local childName = o.name or "Skin"
	local existing = obj:FindFirstChild(childName)
	if existing and existing:IsA("ImageLabel") then
		Skin.setLayer(existing, name)
		return existing
	end
	local layer = make("ImageLabel", {
		Name = childName,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Active = false,
		Selectable = false,
		ZIndex = o.z or Skin.Z,
		ImageColor3 = o.tint or Color3.new(1, 1, 1),
		Size = UDim2.fromScale(1, 1),
	}) :: ImageLabel
	if o.outset then
		layer:SetAttribute("SkinOutset", o.outset)
	end
	if o.mul then
		layer:SetAttribute("SkinMul", o.mul)
	end
	if o.fit then
		layer:SetAttribute("SkinFit", true)
		layer:SetAttribute("SkinGrow", o.grow or 1)
	end
	layer.Parent = obj
	Skin.setLayer(layer, name)
	local st = stateOf(obj)
	table.insert(st.layers, layer)
	table.insert(
		st.conns,
		obj:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			fitLayer(layer)
		end)
	)
	-- a UIPadding added after the skin (Theme.padding after skinCard) refits it
	table.insert(
		st.conns,
		obj.ChildAdded:Connect(function(ch)
			if ch:IsA("UIPadding") then
				fitLayer(layer)
				table.insert(st.conns, ch.Changed:Connect(function()
					fitLayer(layer)
				end))
			end
		end)
	)
	obj:SetAttribute("Skinned", true)
	return layer
end

----------------------------------------------------------------------
-- Background ownership
----------------------------------------------------------------------

-- Hides obj's own background; its BackgroundTransparency (now and later)
-- becomes the layer's ImageTransparency. With opts.tintFromColor the layer's
-- ImageColor3 follows obj.BackgroundColor3. `onColor` sees every colour change.
function Skin.ownBackground(
	obj: GuiObject,
	layer: ImageLabel,
	opts: { tintFromColor: boolean?, onColor: ((Color3) -> ())?, maxAlpha: number? }?
)
	local o = opts or {}
	local function alpha()
		local t = obj.BackgroundTransparency
		if t < 0.999 then
			obj:SetAttribute("SkinAlpha", t)
			obj.BackgroundTransparency = 1
		end
		local a = obj:GetAttribute("SkinAlpha")
		local v = if type(a) == "number" then a else 0
		layer.ImageTransparency = math.min(v, o.maxAlpha or 1)
	end
	local function color()
		if o.tintFromColor then
			layer.ImageColor3 = obj.BackgroundColor3
		end
		if o.onColor then
			o.onColor(obj.BackgroundColor3)
		end
	end
	alpha()
	color()
	local st = stateOf(obj)
	table.insert(st.conns, obj:GetPropertyChangedSignal("BackgroundTransparency"):Connect(alpha))
	table.insert(st.conns, obj:GetPropertyChangedSignal("BackgroundColor3"):Connect(color))
end

-- Turns off obj's border strokes, gradients and glow children Theme added for
-- the flat look (the texture has them baked in).
function Skin.stripFlat(obj: GuiObject)
	local st = stateOf(obj)
	for _, ch in obj:GetChildren() do
		local border = ch:IsA("UIStroke") and ch.ApplyStrokeMode == Enum.ApplyStrokeMode.Border
		if (border or ch:IsA("UIGradient")) and (ch :: any).Enabled then
			(ch :: any).Enabled = false
			table.insert(st.stripped, ch)
		end
	end
end

-- Undoes the skin of a frame: the flat look comes back exactly (background
-- transparency, border strokes, gradients). Returns true if it was skinned.
function Skin.revert(obj: GuiObject): boolean
	local st = states[obj]
	if not st then
		return false
	end
	states[obj] = nil
	for _, c in st.conns do
		c:Disconnect()
	end
	for _, l in st.layers do
		l:Destroy()
	end
	for _, ch in st.stripped do
		(ch :: any).Enabled = true
	end
	local a = obj:GetAttribute("SkinAlpha")
	if type(a) == "number" then
		obj.BackgroundTransparency = a
	end
	obj:SetAttribute("SkinAlpha", nil)
	obj:SetAttribute("Skinned", nil)
	return true
end

-- Frames that get a UIListLayout / UIGridLayout after they were skinned go
-- back to the flat look (`after` runs then, e.g. to add the drop shadow).
function Skin.revertOnLayout(obj: GuiObject, after: (() -> ())?)
	local conn: RBXScriptConnection? = nil
	conn = obj.ChildAdded:Connect(function(ch)
		if ch:IsA("UIGridStyleLayout") then
			if conn then
				conn:Disconnect()
			end
			if Skin.revert(obj) and after then
				after()
			end
		end
	end)
end

----------------------------------------------------------------------
-- Icons
----------------------------------------------------------------------

function Skin.iconImage(name: string, size: number, props: { [string]: any }?): ImageLabel?
	local uri = Skin.uri(name)
	if not uri then
		return nil
	end
	local base: { [string]: any } = {
		Name = "SkinIcon",
		BackgroundTransparency = 1,
		Image = uri,
		ScaleType = Enum.ScaleType.Fit,
		Size = UDim2.fromOffset(size, size),
	}
	if props then
		for k, v in props do
			base[k] = v
		end
	end
	return make("ImageLabel", base)
end

----------------------------------------------------------------------
-- Button captions
----------------------------------------------------------------------

local MIRROR = {
	"Text",
	"TextColor3",
	"Font",
	"TextXAlignment",
	"TextYAlignment",
	"TextScaled",
	"TextWrapped",
	"RichText",
	"TextTruncate",
	"LineHeight",
	"TextSize",
	"TextTransparency",
	"TextStrokeColor3",
	"TextStrokeTransparency",
}

local H_ALIGN = {
	[Enum.TextXAlignment.Left] = Enum.HorizontalAlignment.Left,
	[Enum.TextXAlignment.Right] = Enum.HorizontalAlignment.Right,
	[Enum.TextXAlignment.Center] = Enum.HorizontalAlignment.Center,
}

-- Builds (once) the caption of a skinned TextButton. `lip` = design px the
-- caption sits above the centre (the button's bottom lip). Returns the
-- content frame (hide it for icon-only textures such as the close button).
-- Works for TextLabels too (Theme.badge); `hpad` = side padding (default 6).
-- Animated icons (UI/AnimatedIcon sets this hook): for a button with the
-- "AnimIcon" attribute it returns (icon frame, the text without its leading
-- emoji), or nil while that icon's atlas is not uploaded (caption unchanged).
Skin.captionIcon = nil :: ((GuiObject, string, number) -> (Frame?, string))?

-- Design px size of a caption's animated icon: about 1.45x the text, or ~62%
-- of the button when the icon stands alone (emoji-only buttons).
function Skin.captionIconSize(textSize: number, height: number, alone: boolean): number
	local h = if height > 0 then height else textSize * 2
	if alone then
		return math.floor(math.max(textSize * 1.4, h * 0.62) + 0.5)
	end
	return math.floor(math.clamp(textSize * 1.45, 14, math.max(14, h - 6)) + 0.5)
end

function Skin.caption(b: TextButton, lip: number?, hpad: number?): Frame
	local existing = b:FindFirstChild("SkinContent")
	if existing and existing:IsA("Frame") then
		return existing
	end
	local content = make("Frame", {
		Name = "SkinContent",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = b.ZIndex + 1,
		Active = false,
	}) :: Frame
	make("UIPadding", {
		PaddingLeft = UDim.new(0, hpad or 6),
		PaddingRight = UDim.new(0, hpad or 6),
		PaddingBottom = UDim.new(0, lip or 3),
		Parent = content,
	})
	local list = make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 5),
		Parent = content,
	}) :: UIListLayout
	local icon = make("ImageLabel", {
		Name = "Icon",
		LayoutOrder = 1,
		BackgroundTransparency = 1,
		ScaleType = Enum.ScaleType.Fit,
		Visible = false,
		ZIndex = content.ZIndex,
		Parent = content,
	}) :: ImageLabel
	local label = make("TextLabel", {
		Name = "Label",
		LayoutOrder = 2,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = content.ZIndex,
		Parent = content,
	}) :: TextLabel
	local defaultStroke = make("UIStroke", {
		Name = "SkinTextStroke",
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = label,
	}) :: UIStroke
	-- caps the label's width next to an animated icon (see sync)
	local labelMax = make("UISizeConstraint", {
		Name = "SkinLabelMax",
		Parent = label,
	}) :: UISizeConstraint
	local hasCallerStroke = false

	local function adopt(ch: Instance)
		if ch:IsA("UIStroke") and ch.ApplyStrokeMode == Enum.ApplyStrokeMode.Contextual then
			ch.Parent = label
			hasCallerStroke = true
			defaultStroke.Enabled = false
		elseif ch:IsA("UITextSizeConstraint") then
			ch.Parent = label
		end
	end

	local function sync()
		local textAlpha = b.TextTransparency
		if textAlpha < 0.999 then
			b:SetAttribute("SkinTextAlpha", textAlpha)
			b.TextTransparency = 1
		end
		local a = b:GetAttribute("SkinTextAlpha")
		label.TextTransparency = if type(a) == "number" then a else 0
		local iconName, rest = SkinMath.splitIcon(b.Text)
		local iconUri = if iconName then Skin.uri(iconName) else nil
		local anim: Frame? = nil
		local animRest = b.Text
		local hook = Skin.captionIcon
		if hook and b:GetAttribute("AnimIcon") ~= nil then
			local designTs = b:GetAttribute("DesignTextSize")
			local ts = if type(designTs) == "number" then designTs else b.TextSize
			local alone = IconMath.stripLead(b.Text) == ""
			anim, animRest = hook(b, b.Text, Skin.captionIconSize(ts, b.Size.Y.Offset, alone))
		end
		if anim then
			iconUri = nil
		end
		label.Text = if anim then animRest elseif iconUri then rest else b.Text
		label.TextColor3 = b.TextColor3
		label.Font = b.Font
		label.TextYAlignment = b.TextYAlignment
		label.TextXAlignment = b.TextXAlignment
		label.TextScaled = b.TextScaled
		label.RichText = b.RichText
		label.TextTruncate = b.TextTruncate
		label.LineHeight = b.LineHeight
		label.TextStrokeColor3 = b.TextStrokeColor3
		label.TextStrokeTransparency = b.TextStrokeTransparency
		-- Text floor (Theme.screen): the caption gets the button's design size,
		-- so the floor renders both at the same size.
		local design = b:GetAttribute("DesignTextSize")
		local ds = if type(design) == "number" then design else b.TextSize
		label:SetAttribute("DesignTextSize", ds)
		label.TextSize = b.TextSize
		list.HorizontalAlignment = H_ALIGN[b.TextXAlignment] or Enum.HorizontalAlignment.Center
		label.Visible = true
		labelMax.MaxSize = Vector2.new(math.huge, math.huge)
		if anim then
			-- animated icon (UI/AnimatedIcon) in place of the emoji; the label
			-- never pushes past the button (truncates instead)
			icon.Visible = false
			anim.LayoutOrder = 1
			anim.ZIndex = content.ZIndex
			anim.Parent = content
			label.TextWrapped = false
			label.AutomaticSize = Enum.AutomaticSize.X
			label.Size = UDim2.new(0, 0, 1, 0)
			label.TextTruncate = Enum.TextTruncate.AtEnd
			label.Visible = animRest ~= ""
			local w = b.Size.X
			if w.Scale == 0 and w.Offset > 0 then
				local pad = 2 * (hpad or 6) + anim.Size.X.Offset + 5
				labelMax.MaxSize = Vector2.new(math.max(10, w.Offset - pad), math.huge)
			end
		elseif iconUri then
			icon.Image = iconUri
			icon.Visible = true
			local sz = math.floor(b.TextSize * 1.25 + 0.5)
			icon.Size = UDim2.fromOffset(sz, sz)
			label.TextWrapped = false
			label.AutomaticSize = Enum.AutomaticSize.X
			label.Size = UDim2.new(0, 0, 1, 0)
		else
			icon.Visible = false
			label.TextWrapped = b.TextWrapped
			label.AutomaticSize = Enum.AutomaticSize.None
			label.Size = UDim2.fromScale(1, 1)
		end
		if not hasCallerStroke then
			local c = b.TextColor3
			if SkinMath.isLight(c.R * 255, c.G * 255, c.B * 255) then
				defaultStroke.Color = Color3.fromRGB(62, 38, 22)
				defaultStroke.Thickness = 1.5
				defaultStroke.Transparency = 0
			else
				defaultStroke.Color = Color3.fromRGB(255, 248, 228)
				defaultStroke.Thickness = 1
				defaultStroke.Transparency = 0.55
			end
		end
	end

	for _, prop in MIRROR do
		b:GetPropertyChangedSignal(prop):Connect(sync)
	end
	b:GetAttributeChangedSignal("DesignTextSize"):Connect(sync)
	b:GetAttributeChangedSignal("AnimIcon"):Connect(sync)
	b:GetPropertyChangedSignal("ZIndex"):Connect(function()
		content.ZIndex = b.ZIndex + 1
		icon.ZIndex = content.ZIndex
		label.ZIndex = content.ZIndex
		local ai = content:FindFirstChild("AnimIcon")
		if ai and ai:IsA("GuiObject") then
			ai.ZIndex = content.ZIndex
		end
	end)
	for _, ch in b:GetChildren() do
		adopt(ch)
	end
	b.ChildAdded:Connect(adopt)
	content.Parent = b
	sync()
	return content
end

return Skin
