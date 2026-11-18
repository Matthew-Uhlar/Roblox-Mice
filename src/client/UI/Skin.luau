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

local Client = script.Parent.Parent
local Assets = require(Client.Visuals.Assets)
local SkinMath = require(script.Parent.SkinMath)
local SkinSlices = require(script.Parent.SkinSlices)

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

function Skin.id(name: string): number?
	local ids = override or Assets.ids()
	local v = ids[name]
	if type(v) == "number" and v > 0 then
		return v
	end
	return nil
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

-- Places / scales `layer` for its parent's current size.
local function fitLayer(layer: ImageLabel)
	local obj = layer.Parent
	if not (obj and obj:IsA("GuiObject")) then
		return
	end
	local name = layer:GetAttribute("SkinTexture")
	if type(name) ~= "string" then
		return
	end
	if layer:GetAttribute("SkinFit") then
		local g = layer:GetAttribute("SkinGrow")
		local grow = if type(g) == "number" then g else 1
		layer.AnchorPoint = Vector2.new(0.5, 0.5)
		layer.Position = UDim2.fromScale(0.5, 0.5)
		layer.Size = UDim2.fromScale(grow, grow)
		return
	end
	local slice = Skin.SLICES[name]
	if not slice then
		layer.Size = UDim2.fromScale(1, 1)
		return
	end
	local m = layer:GetAttribute("SkinMul")
	local d = designSize(obj :: GuiObject)
	local s = SkinMath.sliceScale(slice, d.X, d.Y, denseFn(), if type(m) == "number" then m else nil)
	local x, y, ew, eh = SkinMath.frameRect(slice, s)
	layer.SliceScale = s
	layer.Position = UDim2.fromOffset(x, y)
	layer.Size = UDim2.new(1, ew, 1, eh)
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
	local slice = Skin.SLICES[name]
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
function Skin.caption(b: TextButton, lip: number?): Frame
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
		PaddingLeft = UDim.new(0, 6),
		PaddingRight = UDim.new(0, 6),
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
		label.Text = if iconUri then rest else b.Text
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
		if iconUri then
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
	b:GetPropertyChangedSignal("ZIndex"):Connect(function()
		content.ZIndex = b.ZIndex + 1
		icon.ZIndex = content.ZIndex
		label.ZIndex = content.ZIndex
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
