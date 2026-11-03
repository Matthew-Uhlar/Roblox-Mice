--!strict
-- Icons drawn from UI primitives only (Frames, UICorner, UIStroke, UIGradient):
-- no uploaded images, so they ship with the place and stay crisp at any UI
-- scale. Every icon is a transparent square holder; parts are laid out in
-- scale units (0..1 of the holder), so `size` is the only number that matters.
--
--   Icons.make(kind, size, color?, props?) -> Frame
--
-- Kinds: sword, shield, gem, cheese, skull, crown, portal, target, star, lock,
-- check, cross, bot, heart, bolt, hero, cart, tree, coin, plus, poi, arrow.
-- `color` tints the main shape; details use darker / lighter shades of it.

local Icons = {}

local WHITE = Color3.fromRGB(255, 255, 255)
local INK = Color3.fromRGB(48, 30, 18)
local STEEL = Color3.fromRGB(214, 222, 232)
local WOOD = Color3.fromRGB(120, 78, 44)
local GOLD = Color3.fromRGB(255, 204, 51)

local function new(className: string, props: { [string]: any }): any
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

local function darker(c: Color3, f: number?): Color3
	return c:Lerp(Color3.new(0, 0, 0), f or 0.35)
end

local function lighter(c: Color3, f: number?): Color3
	return c:Lerp(WHITE, f or 0.45)
end

-- A filled shape centred at (cx, cy) with size (w, h), all in holder scale.
-- `round` = corner radius as a fraction of the shape (0.5 = circle / pill).
local function shape(
	parent: Instance,
	cx: number,
	cy: number,
	w: number,
	h: number,
	color: Color3,
	round: number?,
	rot: number?,
	z: number?
): Frame
	local f = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(cx, cy),
		Size = UDim2.fromScale(w, h),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Rotation = rot or 0,
		ZIndex = z or 1,
		Parent = parent,
	})
	if round and round > 0 then
		new("UICorner", { CornerRadius = UDim.new(round, 0), Parent = f })
	end
	return f
end

-- A ring: transparent circle with a stroke `thick` px wide.
local function ring(parent: Instance, cx: number, cy: number, d: number, color: Color3, thick: number): Frame
	local f = shape(parent, cx, cy, d, d, color, 0.5)
	f.BackgroundTransparency = 1
	new("UIStroke", {
		Color = color,
		Thickness = thick,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = f,
	})
	return f
end

-- Soft top-light gradient that gives a shape some volume.
local function shade(f: GuiObject, amount: number?)
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(WHITE, Color3.new(1, 1, 1):Lerp(Color3.new(0, 0, 0), amount or 0.28)),
		Parent = f,
	})
end

type Builder = (holder: Frame, color: Color3, px: number) -> ()

local BUILD: { [string]: Builder } = {}

BUILD.sword = function(h, color, px)
	local blade = color
	local g = new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Rotation = 45,
		Parent = h,
	})
	local b = shape(g, 0.5, 0.4, 0.17, 0.56, blade, 0.2)
	shade(b, 0.35)
	shape(g, 0.5, 0.12, 0.17, 0.17, blade, 0.1, 45)
	shape(g, 0.47, 0.4, 0.04, 0.5, lighter(blade, 0.6), 0.5)
	shape(g, 0.5, 0.7, 0.5, 0.09, GOLD, 0.5)
	shape(g, 0.5, 0.82, 0.11, 0.17, WOOD, 0.3)
	shape(g, 0.5, 0.93, 0.15, 0.15, GOLD, 0.5)
	local _ = px
end

BUILD.shield = function(h, color, px)
	local body = shape(h, 0.5, 0.4, 0.72, 0.58, color, 0.22)
	shade(body)
	local tip = shape(h, 0.5, 0.62, 0.5, 0.5, color, 0.12, 45)
	shade(tip)
	local inner = shape(h, 0.5, 0.46, 0.42, 0.42, lighter(color, 0.35), 0.18, 45, 2)
	inner.BackgroundTransparency = 0.25
	shape(h, 0.5, 0.46, 0.1, 0.5, lighter(color, 0.7), 0.5, 0, 3)
	new("UIStroke", { Color = darker(color, 0.45), Thickness = math.max(1, px * 0.05), Parent = body })
end

BUILD.gem = function(h, color, px)
	local g = shape(h, 0.5, 0.5, 0.6, 0.6, color, 0.12, 45)
	shade(g, 0.4)
	new("UIStroke", { Color = darker(color, 0.4), Thickness = math.max(1, px * 0.05), Parent = g })
	shape(h, 0.5, 0.5, 0.28, 0.28, lighter(color, 0.4), 0.1, 45, 2)
	shape(h, 0.38, 0.34, 0.12, 0.12, WHITE, 0.5, 0, 3).BackgroundTransparency = 0.2
end

BUILD.cheese = function(h, color, px)
	local body = shape(h, 0.5, 0.6, 0.86, 0.5, color, 0.16)
	shade(body, 0.25)
	new("UIStroke", { Color = darker(color, 0.45), Thickness = math.max(1, px * 0.05), Parent = body })
	local top = shape(h, 0.5, 0.36, 0.86, 0.12, lighter(color, 0.35), 0.5, -8)
	top.ZIndex = 2
	local hole = darker(color, 0.25)
	shape(h, 0.3, 0.6, 0.16, 0.16, hole, 0.5, 0, 2)
	shape(h, 0.6, 0.7, 0.12, 0.12, hole, 0.5, 0, 2)
	shape(h, 0.7, 0.52, 0.1, 0.1, hole, 0.5, 0, 2)
end

BUILD.skull = function(h, color, _px)
	local head = shape(h, 0.5, 0.42, 0.74, 0.66, color, 0.5)
	shade(head, 0.2)
	shape(h, 0.5, 0.74, 0.44, 0.24, color, 0.25)
	local eye = INK
	shape(h, 0.34, 0.44, 0.2, 0.22, eye, 0.5, 0, 2)
	shape(h, 0.66, 0.44, 0.2, 0.22, eye, 0.5, 0, 2)
	shape(h, 0.5, 0.6, 0.08, 0.1, eye, 0.3, 45, 2)
	shape(h, 0.42, 0.79, 0.05, 0.14, eye, 0.5, 0, 2)
	shape(h, 0.58, 0.79, 0.05, 0.14, eye, 0.5, 0, 2)
end

BUILD.crown = function(h, color, px)
	local base = shape(h, 0.5, 0.7, 0.74, 0.24, color, 0.15)
	shade(base)
	for _, x in { 0.22, 0.5, 0.78 } do
		local s = shape(h, x, if x == 0.5 then 0.44 else 0.5, 0.24, 0.24, color, 0.1, 45)
		shade(s)
		shape(h, x, if x == 0.5 then 0.3 else 0.36, 0.1, 0.1, lighter(color, 0.5), 0.5, 0, 2)
	end
	shape(h, 0.5, 0.7, 0.12, 0.12, Color3.fromRGB(226, 72, 58), 0.5, 0, 3)
	new("UIStroke", { Color = darker(color, 0.45), Thickness = math.max(1, px * 0.04), Parent = base })
end

BUILD.portal = function(h, color, px)
	local glow = shape(h, 0.5, 0.5, 0.9, 0.9, color, 0.5)
	glow.BackgroundTransparency = 0.7
	ring(h, 0.5, 0.5, 0.8, color, math.max(2, px * 0.12))
	ring(h, 0.5, 0.5, 0.46, lighter(color, 0.5), math.max(1, px * 0.07))
	shape(h, 0.5, 0.5, 0.16, 0.16, WHITE, 0.5, 0, 2)
end

BUILD.target = function(h, color, px)
	ring(h, 0.5, 0.5, 0.78, color, math.max(2, px * 0.09))
	ring(h, 0.5, 0.5, 0.4, color, math.max(1, px * 0.07))
	shape(h, 0.5, 0.5, 0.14, 0.14, color, 0.5)
	for _, p in { { 0.5, 0.06, 0.08, 0.2 }, { 0.5, 0.94, 0.08, 0.2 }, { 0.06, 0.5, 0.2, 0.08 }, { 0.94, 0.5, 0.2, 0.08 } } do
		shape(h, p[1], p[2], p[3], p[4], color, 0.5)
	end
end

BUILD.star = function(h, color, px)
	local a = shape(h, 0.5, 0.5, 0.6, 0.6, color, 0.08)
	local b = shape(h, 0.5, 0.5, 0.6, 0.6, color, 0.08, 45)
	shade(a)
	shade(b)
	new("UIStroke", { Color = darker(color, 0.4), Thickness = math.max(1, px * 0.04), Parent = a })
	shape(h, 0.5, 0.5, 0.3, 0.3, lighter(color, 0.45), 0.5, 0, 2)
end

BUILD.lock = function(h, color, px)
	ring(h, 0.5, 0.36, 0.44, darker(color, 0.15), math.max(2, px * 0.1))
	local body = shape(h, 0.5, 0.66, 0.66, 0.46, color, 0.18, 0, 2)
	shade(body)
	shape(h, 0.5, 0.62, 0.13, 0.13, INK, 0.5, 0, 3)
	shape(h, 0.5, 0.72, 0.06, 0.14, INK, 0.5, 0, 3)
end

BUILD.check = function(h, color, _px)
	shape(h, 0.34, 0.58, 0.16, 0.38, color, 0.5, -45)
	shape(h, 0.6, 0.48, 0.16, 0.66, color, 0.5, 38)
end

BUILD.cross = function(h, color, _px)
	shape(h, 0.5, 0.5, 0.16, 0.8, color, 0.5, 45)
	shape(h, 0.5, 0.5, 0.16, 0.8, color, 0.5, -45)
end

BUILD.plus = function(h, color, _px)
	shape(h, 0.5, 0.5, 0.16, 0.7, color, 0.5)
	shape(h, 0.5, 0.5, 0.7, 0.16, color, 0.5)
end

BUILD.bot = function(h, color, _px)
	shape(h, 0.5, 0.14, 0.06, 0.2, darker(color, 0.3), 0.5)
	shape(h, 0.5, 0.08, 0.14, 0.14, Color3.fromRGB(226, 72, 58), 0.5)
	local head = shape(h, 0.5, 0.56, 0.78, 0.6, color, 0.25)
	shade(head)
	shape(h, 0.34, 0.54, 0.16, 0.16, INK, 0.5, 0, 2)
	shape(h, 0.66, 0.54, 0.16, 0.16, INK, 0.5, 0, 2)
	shape(h, 0.5, 0.74, 0.34, 0.06, INK, 0.5, 0, 2)
end

BUILD.heart = function(h, color, _px)
	shape(h, 0.33, 0.38, 0.42, 0.42, color, 0.5)
	shape(h, 0.67, 0.38, 0.42, 0.42, color, 0.5)
	local tip = shape(h, 0.5, 0.56, 0.5, 0.5, color, 0.1, 45)
	shade(tip, 0.2)
	shape(h, 0.3, 0.32, 0.12, 0.12, lighter(color, 0.6), 0.5, 0, 2)
end

BUILD.bolt = function(h, color, _px)
	shape(h, 0.56, 0.3, 0.2, 0.5, color, 0.15, 20)
	shape(h, 0.44, 0.7, 0.2, 0.5, color, 0.15, 20)
	shape(h, 0.5, 0.5, 0.42, 0.14, color, 0.3, -20)
end

BUILD.hero = function(h, color, _px)
	local head = shape(h, 0.5, 0.3, 0.42, 0.42, color, 0.5)
	shade(head, 0.2)
	local body = shape(h, 0.5, 0.82, 0.78, 0.5, color, 0.45)
	shade(body, 0.3)
end

BUILD.cart = function(h, color, px)
	local body = shape(h, 0.52, 0.48, 0.72, 0.4, color, 0.15)
	shade(body)
	shape(h, 0.14, 0.3, 0.2, 0.08, darker(color, 0.3), 0.5, 20)
	ring(h, 0.34, 0.8, 0.2, INK, math.max(1, px * 0.06))
	ring(h, 0.7, 0.8, 0.2, INK, math.max(1, px * 0.06))
	shape(h, 0.52, 0.42, 0.5, 0.06, lighter(color, 0.5), 0.5, 0, 2)
end

BUILD.tree = function(h, color, _px)
	shape(h, 0.5, 0.78, 0.14, 0.38, WOOD, 0.3)
	local a = shape(h, 0.5, 0.32, 0.5, 0.5, color, 0.5)
	local b = shape(h, 0.3, 0.5, 0.42, 0.42, color, 0.5)
	local c = shape(h, 0.7, 0.5, 0.42, 0.42, color, 0.5)
	shade(a)
	shade(b)
	shade(c)
end

BUILD.coin = function(h, color, px)
	local c = shape(h, 0.5, 0.5, 0.82, 0.82, color, 0.5)
	shade(c, 0.35)
	new("UIStroke", { Color = darker(color, 0.45), Thickness = math.max(1, px * 0.06), Parent = c })
	ring(h, 0.5, 0.5, 0.56, darker(color, 0.2), math.max(1, px * 0.05))
end

BUILD.poi = function(h, color, px)
	local d = shape(h, 0.5, 0.5, 0.62, 0.62, color, 0.15, 45)
	shade(d, 0.3)
	new("UIStroke", { Color = WHITE, Thickness = math.max(1, px * 0.07), Parent = d })
end

BUILD.arrow = function(h, color, _px)
	shape(h, 0.5, 0.42, 0.5, 0.5, color, 0.1, 45)
	shape(h, 0.5, 0.7, 0.2, 0.4, color, 0.3)
end

Icons.KINDS = {}
for k in BUILD do
	table.insert(Icons.KINDS, k)
end
table.sort(Icons.KINDS)

-- Builds an icon. Unknown kinds draw a gem so a typo never errors.
function Icons.make(kind: string, size: number, color: Color3?, props: { [string]: any }?): Frame
	local holder = new("Frame", {
		Name = "Icon_" .. kind,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
	}) :: Frame
	local build = BUILD[kind] or BUILD.gem
	build(holder, color or STEEL, size)
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

-- Icon for a gear slot.
function Icons.forSlot(slot: string?): string
	if slot == "weapon" then
		return "sword"
	elseif slot == "armor" then
		return "shield"
	end
	return "gem"
end

return Icons
