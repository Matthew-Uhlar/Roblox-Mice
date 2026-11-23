--!strict
-- CosmeticIcon (iteration 6, team Preview, client): an animated icon for any
-- skin / cosmetic ref (Util/PreviewRecipe: "cosmetic:<id>", "skin:<id>",
-- "look:<name>", "title:<id>", "dye:<id>", "chattag:<id>", "frame:<key>").
--
--   CosmeticIcon.make(ref, size, props?) -> Frame?    nil for an unknown ref
--   CosmeticIcon.liveCount() -> number                animated icons still alive
--
-- Art, best first:
--   1. the rendered thumbnail of the real item from the cosmetic icon atlas
--      (scripts/make-cosmetic-icons.py -> assets/icons/icon_cos_atlas_<n>.png +
--      UI/CosmeticIconAtlas), once the sheet's id is in Config/AssetIds;
--   2. drawn in code from the item's colours: a colourway roundel for skins and
--      looks, a hat / tint swatch, a trail swoosh, a text chip for titles, dyes,
--      chat tags and frames.
-- Motion: a slow shine sweep and a small bob (a trail's gradient flows). One
-- Heartbeat drives every live icon, only while some are on screen; Effects
-- "off" keeps them still. Team Icons' UI/AnimatedIcon, when present, may take
-- over the motion of atlas icons (CosmeticIcon.useAnimatedIcon).

local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Defs = require(Client.Util.Defs)
local State = require(Client.Controllers.State)
local PreviewRecipe = require(Client.Util.PreviewRecipe)
local CosmeticPreview = require(script.Parent.CosmeticPreview)

local CosmeticIcon = {}

local C = Theme.C
local make = Theme.make

CosmeticIcon.SHINE_PERIOD = 2.8 -- s per shine sweep
CosmeticIcon.useAnimatedIcon = true

local GLYPH: { [string]: string } = {
	hat = "🎩",
	trail = "✨",
	tint = "🎨",
	skin = "🐘",
	look = "🦣",
	title = "🏷",
	dye = "🖌",
	chattag = "💬",
	frame = "⭐",
}

local function optional(parent: Instance, name: string): any
	local inst = parent:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		return if ok then mod else nil
	end
	return nil
end
local Atlas: any = optional(script.Parent, "CosmeticIconAtlas")
local AnimatedIcon: any = nil
local animatedChecked = false
local function animated(): any
	if not animatedChecked then
		animatedChecked = true
		AnimatedIcon = optional(script.Parent, "AnimatedIcon")
	end
	return AnimatedIcon
end

local function rgb(c: any, fallback: Color3): Color3
	if type(c) == "table" and type(c[1]) == "number" then
		return Color3.fromRGB(c[1], c[2] or 0, c[3] or 0)
	end
	return fallback
end

-- The atlas entry of an icon name and its image, or nil until the sheet is uploaded.
-- entry = { atlas, x, y, frames, fps, ... } (UI/CosmeticIconAtlas, IconAtlas schema)
function CosmeticIcon.atlasEntry(name: string): (any, string?)
	if type(Atlas) ~= "table" or type(Atlas.icons) ~= "table" then
		return nil, nil
	end
	local e = Atlas.icons[name]
	if type(e) ~= "table" then
		return nil, nil
	end
	local ids = Defs.module("AssetIds")
	local id = if type(ids) == "table" then tonumber(ids[e.atlas]) else nil
	if not id or id <= 0 then
		return e, nil
	end
	return e, "rbxassetid://" .. tostring(math.floor(id))
end

----------------------------------------------------------------------
-- Animation (one loop for all icons)
----------------------------------------------------------------------

type Live = {
	frame: Frame,
	shine: UIGradient?,
	flow: UIGradient?,
	bob: GuiObject?,
	phase: number,
	sprite: ImageLabel?, -- atlas frames stepped with ImageRectOffset
	entry: any,
}
local live: { Live } = {}
local hb: RBXScriptConnection? = nil
local t = 0
local checkAt = 0
local shown: { [Frame]: boolean } = {}

local function CELL(): number
	return if type(Atlas) == "table" then tonumber(Atlas.cell) or 128 else 128
end

local function onScreen(obj: GuiObject): boolean
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

local function step(dt: number)
	t += dt
	local now = os.clock()
	local recheck = now >= checkAt
	if recheck then
		checkAt = now + 0.5
	end
	local still = State.gfx().fx == "off"
	for i = #live, 1, -1 do
		local e = live[i]
		if e.frame.Parent == nil then
			shown[e.frame] = nil
			table.remove(live, i)
			continue
		end
		if recheck then
			shown[e.frame] = onScreen(e.frame)
		end
		if still or not shown[e.frame] then
			if still and e.sprite and e.entry then
				e.sprite.ImageRectOffset = Vector2.new(e.entry.x, e.entry.y) -- frame 0: the still look
			end
			continue
		end
		local sp, en = e.sprite, e.entry
		if sp and en then
			local frames = math.max(1, tonumber(en.frames) or 1)
			local k = math.floor((t + e.phase) * (tonumber(en.fps) or 4)) % frames
			sp.ImageRectOffset = Vector2.new(en.x + k * CELL(), en.y)
		end
		local k = ((t + e.phase) % CosmeticIcon.SHINE_PERIOD) / CosmeticIcon.SHINE_PERIOD
		if e.shine then
			e.shine.Offset = Vector2.new(-1.2 + k * 2.4, 0)
		end
		if e.flow then
			e.flow.Offset = Vector2.new(math.sin((t + e.phase) * 2) * 0.25, 0)
		end
		if e.bob then
			e.bob.Position = UDim2.new(0.5, 0, 0.5, math.floor(math.sin((t + e.phase) * 2.2) * 2 + 0.5))
		end
	end
	if #live == 0 and hb then
		hb:Disconnect()
		hb = nil
	end
end

local function register(e: Live)
	table.insert(live, e)
	shown[e.frame] = true
	if not hb then
		checkAt = 0
		hb = RunService.Heartbeat:Connect(step)
	end
end

function CosmeticIcon.liveCount(): number
	local n = 0
	for _, e in live do
		if e.frame.Parent ~= nil then
			n += 1
		end
	end
	return n
end

----------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------

local function shineLayer(parent: GuiObject): UIGradient
	local layer = make("Frame", {
		Name = "Shine",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.white,
		BackgroundTransparency = 0,
		ZIndex = (parent.ZIndex or 1) + 3,
		Parent = parent,
	}) :: Frame
	Theme.corner(8).Parent = layer
	return make("UIGradient", {
		Rotation = 25,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.45, 1),
			NumberSequenceKeypoint.new(0.5, 0.6),
			NumberSequenceKeypoint.new(0.55, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Offset = Vector2.new(-1.2, 0),
		Parent = layer,
	}) :: UIGradient
end

function CosmeticIcon.make(ref: string, size: number, props: { [string]: any }?): Frame?
	local r = CosmeticPreview.recipe(ref)
	if not r then
		return nil
	end
	local recipe = r :: PreviewRecipe.Recipe
	local main = rgb(recipe.swatch, C.cheese)
	local second = rgb(recipe.swatch2, main:Lerp(C.white, 0.5))
	local z = 1
	if props and type(props.ZIndex) == "number" then
		z = props.ZIndex
	end
	local f = make("Frame", {
		Name = "CosmeticIcon",
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = C.cream,
		ClipsDescendants = true,
		ZIndex = z,
	}) :: Frame
	f:SetAttribute("PreviewRef", recipe.ref)
	f:SetAttribute("IconName", recipe.icon)
	Theme.corner(8).Parent = f
	Theme.stroke(C.brownDark, 2).Parent = f
	local e: Live = { frame = f, phase = (#recipe.ref % 7) * 0.37 }

	local entry, image = CosmeticIcon.atlasEntry(recipe.icon)
	if entry and image then
		f:SetAttribute("IconSource", "atlas")
		local n = CELL()
		local img = make("ImageLabel", {
			Name = "Art",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Image = image,
			ImageRectOffset = Vector2.new(entry.x, entry.y),
			ImageRectSize = Vector2.new(n, n),
			ZIndex = z + 1,
			Parent = f,
		}) :: ImageLabel
		Theme.corner(8).Parent = img
		local A = if CosmeticIcon.useAnimatedIcon then animated() else nil
		local handled = false
		if type(A) == "table" and type(A.attachEntry) == "function" then
			local ok, res = pcall(A.attachEntry, img, entry)
			handled = ok and res ~= false
		end
		if not handled then
			e.sprite, e.entry = img, entry
		end
	else
		f:SetAttribute("IconSource", "drawn")
		local slot = recipe.slot
		local text = slot == "title" or slot == "dye" or slot == "chattag" or slot == "frame"
		f.BackgroundColor3 = if text then C.rind else main:Lerp(C.cream, 0.7)
		if slot == "trail" then
			local bar = make("Frame", {
				Name = "Swoosh",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.62),
				Size = UDim2.new(1.1, 0, 0.32, 0),
				Rotation = -18,
				BackgroundColor3 = C.white,
				ZIndex = z + 1,
				Parent = f,
			})
			Theme.round().Parent = bar
			e.flow = make("UIGradient", {
				Color = ColorSequence.new(main, second),
				Transparency = NumberSequence.new(0, 0.85),
				Parent = bar,
			}) :: UIGradient
		elseif slot == "skin" or slot == "look" then
			local disc = make("Frame", {
				Name = "Colourway",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.82, 0.82),
				BackgroundColor3 = C.white,
				ZIndex = z + 1,
				Parent = f,
			})
			Theme.round().Parent = disc
			Theme.stroke(C.brownDark, 2).Parent = disc
			make("UIGradient", {
				Rotation = 45,
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, main),
					ColorSequenceKeypoint.new(0.62, main),
					ColorSequenceKeypoint.new(0.66, second),
					ColorSequenceKeypoint.new(1, second),
				}),
				Parent = disc,
			})
		elseif slot == "hat" or slot == "tint" then
			local disc = make("Frame", {
				Name = "Swatch",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.72, 0.72),
				BackgroundColor3 = main,
				ZIndex = z + 1,
				Parent = f,
			})
			Theme.round().Parent = disc
			Theme.stroke(second, 3).Parent = disc
		end
		local glyph = Theme.label({
			Name = "Glyph",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.9, 0.9),
			TextSize = math.max(12, math.floor(size * (if text then 0.26 else 0.42))),
			TextColor3 = if text then main else C.ink,
			TextScaled = text,
			Text = if slot == "title"
				then (recipe.title and recipe.title.text or "")
				elseif slot == "chattag" then "[" .. (recipe.chatTag and recipe.chatTag.text or "") .. "]"
				elseif slot == "dye" then "Aa"
				else GLYPH[slot] or "★",
			ZIndex = z + 2,
			Parent = f,
		})
		if slot == "frame" then
			local stroke = Theme.stroke(C.gold, 3)
			stroke.Parent = f
			glyph.Text = "⭐"
		end
		e.bob = glyph
		e.shine = shineLayer(f)
	end
	if props then
		for k, v in props do
			(f :: any)[k] = v
		end
	end
	if e.bob or e.shine or e.flow or e.sprite then
		register(e)
	end
	return f
end

return CosmeticIcon
