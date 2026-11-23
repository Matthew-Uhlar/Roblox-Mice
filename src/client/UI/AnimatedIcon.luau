--!strict
-- Animated icons (owner: "custom animated icons on all menu items and shop
-- items"). Sprite frames come from the generated atlases (UI/IconAtlas, made
-- by scripts/make-icons.py, uploaded as the icon_atlas_* manifest Images);
-- UI/IconMap says which icon each menu key / shop item uses; the maths is the
-- pure UI/IconMath.
--
--   AnimatedIcon.has(key) -> boolean          icon known AND its atlas uploaded
--   AnimatedIcon.new(key, size, props?) -> Frame?
--       a size x size holder with the sprite (and a hover glow) inside; nil
--       while the atlas has no id, so callers keep their emoji / UI/Icons
--   AnimatedIcon.decorate(button, key | (text) -> key?) -> boolean
--       puts the icon in a Theme button's caption (UI/Skin.caption) in place
--       of its leading emoji, or before its text; hover / press react. A
--       resolver function picks the key from the current text (toggles).
--       No-op (false) while the atlas is missing: the button looks as before.
--   AnimatedIcon.react(icon, state)          "normal" | "hover" | "pressed"
--   AnimatedIcon.bindHover(icon, button)     react to a button's hover / press
--   AnimatedIcon.forMenu(key) / forItem(kind, id) -> iconKey?   (UI/IconMap)
--   AnimatedIcon.setFx(fx?)                  test hook (nil: State "gfx")
--   AnimatedIcon.step(dt)                    one driver tick (tests)
--   AnimatedIcon.count() -> number           registered icons (tests / leaks)
--   AnimatedIcon.refresh() -> number         re-applies decorated buttons (new ids)
--   AnimatedIcon.addIndex(index) -> boolean  another generated atlas index (same schema)
--
-- One shared Heartbeat driver animates every icon, connected only while at
-- least one icon exists. Each icon steps its frames (ImageRectOffset) and its
-- idle motion (bob / pulse / tilt), and is skipped while it or an ancestor is
-- hidden (checked a few times a second). An icon leaves the driver when it is
-- destroyed (Destroying) or has been out of the DataModel for a while; its
-- connections are disconnected then.

local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Skin = require(script.Parent.Skin)
local IconAtlas = require(script.Parent.IconAtlas)
local IconMath = require(script.Parent.IconMath)
local IconMap = require(script.Parent.IconMap)

local AnimatedIcon = {}

AnimatedIcon.Math = IconMath
AnimatedIcon.Map = IconMap
AnimatedIcon.ATLAS = IconAtlas

-- Atlas indexes (same schema: cell, glow {x, y}, atlases, icons): ours
-- (UI/IconAtlas) plus any other generated set, e.g. team Preview's
-- UI/CosmeticIconAtlas (scripts/make-cosmetic-icons.py), when present.
-- Earlier indexes win on a key clash.
export type Index = {
	cell: number,
	glow: { x: number, y: number },
	atlases: { string }?,
	icons: { [string]: any },
}
local INDEXES: { Index } = { IconAtlas :: any }

function AnimatedIcon.addIndex(index: any): boolean
	if
		type(index) ~= "table"
		or type(index.icons) ~= "table"
		or type(index.cell) ~= "number"
		or type(index.glow) ~= "table"
		or table.find(INDEXES, index)
	then
		return false
	end
	table.insert(INDEXES, index)
	return true
end

do
	local mod = script.Parent:FindFirstChild("CosmeticIconAtlas")
	if mod and mod:IsA("ModuleScript") then
		local ok, idx = pcall(require, mod)
		if ok then
			AnimatedIcon.addIndex(idx)
		end
	end
end

-- (entry, its index) for a key
local function lookup(key: string?): (IconMath.Entry?, Index?)
	if not key then
		return nil, nil
	end
	for _, idx in INDEXES do
		local e = idx.icons[key]
		if type(e) == "table" then
			return e :: any, idx
		end
	end
	return nil, nil
end
local TICK = 1 / 30 -- motion updates at most 30x a second
local VIS_EVERY = 0.25 -- visibility re-check interval
local ORPHAN_SECONDS = 8 -- out of the DataModel this long: dropped

type Rec = {
	key: string,
	entry: IconMath.Entry,
	cell: number,
	holder: Frame,
	image: ImageLabel,
	glow: ImageLabel,
	scale: UIScale,
	phase: number,
	frame: number,
	state: string,
	visible: boolean,
	visAt: number,
	orphanSince: number?,
	conns: { RBXScriptConnection },
}

local recs: { [Frame]: Rec } = {}
local nrecs = 0
local driver: RBXScriptConnection? = nil
local clock = 0
local acc = 0
local fxOverride: string? = nil
local fxLive = "full"
local fxBound = false

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
-- Effects setting
----------------------------------------------------------------------

local function bindFx()
	if fxBound then
		return
	end
	fxBound = true
	local ok, State = pcall(function()
		return require(Client.Controllers.State) :: any
	end)
	if not ok or type(State) ~= "table" or type(State.gfx) ~= "function" then
		return
	end
	local function read()
		local okG, g = pcall(State.gfx)
		fxLive = if okG and type(g) == "table" and type(g.fx) == "string" then g.fx else "full"
	end
	read()
	if type(State.subscribe) == "function" then
		State.subscribe("gfx", read)
		State.subscribe("profile", read)
	end
end

function AnimatedIcon.fx(): string
	return fxOverride or fxLive
end

function AnimatedIcon.setFx(fx: string?)
	fxOverride = fx
end

----------------------------------------------------------------------
-- Lookups
----------------------------------------------------------------------

local function atlasUri(entry: IconMath.Entry): string?
	-- Skin.uri honours Skin.setIds (tests) and AssetIds; icon_ names pass through
	return Skin.uri(entry.atlas)
end

function AnimatedIcon.entry(key: string?): IconMath.Entry?
	return (lookup(key))
end

function AnimatedIcon.has(key: string?): boolean
	local e = AnimatedIcon.entry(key)
	return e ~= nil and atlasUri(e) ~= nil
end

AnimatedIcon.forMenu = IconMap.menu
AnimatedIcon.forItem = IconMap.item

----------------------------------------------------------------------
-- Driver
----------------------------------------------------------------------

local function remove(holder: Frame)
	local r = recs[holder]
	if not r then
		return
	end
	recs[holder] = nil
	nrecs -= 1
	for _, c in r.conns do
		c:Disconnect()
	end
	table.clear(r.conns)
	if nrecs <= 0 and driver then
		driver:Disconnect()
		driver = nil
	end
end

-- Visible on screen? (every ancestor GuiObject visible, its LayerCollector enabled)
local function shown(obj: Instance): boolean
	local cur: Instance? = obj
	while cur do
		if cur:IsA("GuiObject") then
			if not (cur :: GuiObject).Visible then
				return false
			end
		elseif cur:IsA("LayerCollector") then
			return (cur :: any).Enabled ~= false
		end
		cur = cur.Parent
	end
	return false
end

local function apply(r: Rec, fx: string)
	local f = IconMath.frame(r.entry, clock, fx, r.phase)
	if f ~= r.frame then
		r.frame = f
		local x, y = IconMath.rect(r.entry, f, r.cell)
		r.image.ImageRectOffset = Vector2.new(x, y)
	end
	local dy, s, rot = IconMath.motion(r.entry, clock, fx, r.phase)
	r.image.Position = UDim2.new(0.5, 0, 0.5 + dy, 0)
	r.image.Rotation = rot
	local rs = IconMath.react(r.state, fx)
	r.scale.Scale = s * rs
end

function AnimatedIcon.step(dt: number)
	clock += dt
	acc += dt
	if acc < TICK then
		return
	end
	acc = 0
	local fx = AnimatedIcon.fx()
	local dead: { Frame } = {}
	for holder, r in recs do
		if clock >= r.visAt then
			r.visAt = clock + VIS_EVERY
			if holder:IsDescendantOf(game) then
				r.orphanSince = nil
				r.visible = shown(holder)
			else
				r.visible = false
				local since = r.orphanSince
				if not since then
					r.orphanSince = clock
				elseif clock - since > ORPHAN_SECONDS then
					table.insert(dead, holder)
				end
			end
		end
		if r.visible then
			apply(r, fx)
		end
	end
	for _, h in dead do
		remove(h)
	end
end

local function ensureDriver()
	if driver then
		return
	end
	driver = RunService.Heartbeat:Connect(AnimatedIcon.step)
end

function AnimatedIcon.count(): number
	return nrecs
end

----------------------------------------------------------------------
-- Icons
----------------------------------------------------------------------

function AnimatedIcon.new(key: string?, size: number, props: { [string]: any }?): Frame?
	local entry, index = lookup(key)
	local uri = if entry then atlasUri(entry) else nil
	if not entry or not index or not uri or not key then
		return nil
	end
	bindFx()
	local CELL = index.cell
	local holder = make("Frame", {
		Name = "AnimIcon",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Active = false,
	}) :: Frame
	holder:SetAttribute("IconKey", key)
	local g = entry.glow
	local glowImg = make("ImageLabel", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1.7, 1.7),
		BackgroundTransparency = 1,
		Image = uri,
		ImageRectOffset = Vector2.new(index.glow.x, index.glow.y),
		ImageRectSize = Vector2.new(CELL, CELL),
		ImageColor3 = Color3.fromRGB(g[1] or 255, g[2] or 220, g[3] or 120),
		ImageTransparency = 1,
		ZIndex = holder.ZIndex,
		Parent = holder,
	}) :: ImageLabel
	local x, y = IconMath.rect(entry, 0, CELL)
	local image = make("ImageLabel", {
		Name = "Sprite",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Image = uri,
		ImageRectOffset = Vector2.new(x, y),
		ImageRectSize = Vector2.new(CELL, CELL),
		ScaleType = Enum.ScaleType.Fit,
		ZIndex = holder.ZIndex,
		Parent = holder,
	}) :: ImageLabel
	local scale = make("UIScale", { Name = "IconScale", Scale = 1, Parent = image }) :: UIScale
	local r: Rec = {
		key = key,
		entry = entry,
		cell = CELL,
		holder = holder,
		image = image,
		glow = glowImg,
		scale = scale,
		phase = IconMath.phase(key),
		frame = 0,
		state = "normal",
		visible = false,
		visAt = 0,
		orphanSince = nil,
		conns = {},
	}
	table.insert(
		r.conns,
		holder.Destroying:Connect(function()
			remove(holder)
		end)
	)
	-- children follow the holder's ZIndex (captions raise theirs above the skin)
	table.insert(
		r.conns,
		holder:GetPropertyChangedSignal("ZIndex"):Connect(function()
			image.ZIndex = holder.ZIndex
			glowImg.ZIndex = holder.ZIndex
		end)
	)
	recs[holder] = r
	nrecs += 1
	ensureDriver()
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

function AnimatedIcon.react(icon: Frame, state: string)
	local r = recs[icon]
	if not r then
		return
	end
	r.state = state
	local fx = AnimatedIcon.fx()
	local s, glowAlpha = IconMath.react(state, fx)
	local _, ms = IconMath.motion(r.entry, clock, fx, r.phase)
	r.scale.Scale = ms * s
	r.glow.ImageTransparency = glowAlpha
end

-- Hover / press reactions from a button (connections live with the icon).
function AnimatedIcon.bindHover(icon: Frame, button: GuiButton)
	local r = recs[icon]
	if not r then
		return
	end
	local hovering = false
	local function to(state: string)
		AnimatedIcon.react(icon, if (button :: any).Active == false and state ~= "normal" then "normal" else state)
	end
	table.insert(
		r.conns,
		button.MouseEnter:Connect(function()
			hovering = true
			to("hover")
		end)
	)
	table.insert(
		r.conns,
		button.MouseLeave:Connect(function()
			hovering = false
			to("normal")
		end)
	)
	table.insert(
		r.conns,
		button.MouseButton1Down:Connect(function()
			to("pressed")
		end)
	)
	table.insert(
		r.conns,
		button.MouseButton1Up:Connect(function()
			to(if hovering then "hover" else "normal")
		end)
	)
	table.insert(
		r.conns,
		button.SelectionGained:Connect(function()
			to("hover")
		end)
	)
	table.insert(
		r.conns,
		button.SelectionLost:Connect(function()
			to("normal")
		end)
	)
end

----------------------------------------------------------------------
-- Buttons (through UI/Skin.caption)
----------------------------------------------------------------------

type Resolver = string | (string) -> string?
local resolvers: { [Instance]: Resolver } = setmetatable({}, { __mode = "k" }) :: any
local buttonIcons: { [Instance]: Frame } = setmetatable({}, { __mode = "k" }) :: any

local function keyFor(b: Instance, text: string): string?
	local res = resolvers[b]
	if type(res) == "function" then
		local ok, k = pcall(res, text)
		return if ok and type(k) == "string" then k else nil
	end
	return if type(res) == "string" then res else nil
end

-- Called by Skin.caption's sync: (icon to show, text to keep) or nil.
local function captionHook(b: GuiObject, text: string, size: number): (Frame?, string)
	local key = keyFor(b, text)
	if not key or not AnimatedIcon.has(key) then
		local old = buttonIcons[b]
		if old then
			old.Visible = false
		end
		return nil, text
	end
	local icon = buttonIcons[b]
	if icon and icon:GetAttribute("IconKey") ~= key then
		icon:Destroy()
		buttonIcons[b] = nil
		icon = nil
	end
	if not icon then
		icon = AnimatedIcon.new(key, size)
		if not icon then
			return nil, text
		end
		buttonIcons[b] = icon
		if b:IsA("GuiButton") then
			AnimatedIcon.bindHover(icon, b :: GuiButton)
		end
	end
	local ic = icon :: Frame
	ic.Visible = true
	ic.Size = UDim2.fromOffset(size, size)
	return ic, IconMath.stripLead(text)
end

Skin.captionIcon = captionHook

function AnimatedIcon.decorate(button: GuiObject, key: Resolver): boolean
	resolvers[button] = key
	-- the caption re-syncs on this attribute (cleared first so a new resolver
	-- with the same marker still refreshes it)
	button:SetAttribute("AnimIcon", nil)
	button:SetAttribute("AnimIcon", if type(key) == "string" then key else "dynamic")
	local k = keyFor(button, (button :: any).Text or "")
	if not k or not AnimatedIcon.has(k) then
		return false
	end
	Skin.caption(button :: any)
	return true
end

-- Re-applies every decorated button (after the ids change: tests, Skin.setIds).
function AnimatedIcon.refresh(): number
	local n = 0
	for b, res in resolvers do
		if b.Parent ~= nil and AnimatedIcon.decorate(b :: any, res) then
			n += 1
		end
	end
	return n
end

-- The icon a decorated button shows (tests).
function AnimatedIcon.iconOf(button: Instance): Frame?
	return buttonIcons[button]
end

return AnimatedIcon
