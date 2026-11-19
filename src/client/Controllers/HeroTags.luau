--!strict
-- HeroTags (team CLARITY, client): one BillboardGui over every hero's head
-- during a run (player characters and workspace.Bots models), owned and pooled
-- here. The lobby keeps the server's name tags; in a run this controller turns
-- those off LOCALLY (Enabled = false on this client only) and puts them back
-- when the run ends or the hero leaves it.
--
-- What each tag shows (colours: Config/SquadColors, maths: Util/HeroTagMath):
--   * squadmate: a bright ally ▼ chevron, "Name · Lv N" (🤖 for bots), a green
--     health bar framed in the squad colour; AlwaysOnTop (seen through walls),
--     a lime ground ring at the feet and, for up to 2 mates, a Highlight
--     outline (Roblox caps Highlights at 31; FxController already outlines up
--     to 9 enemies).
--   * enemy: a small pill in its squad colour with the squad's name, the name,
--     a red bar framed in the squad colour. Occluded by walls; shrinks and
--     fades past ~70 studs, ~half size / half alpha at 120, gone by 180.
--   * you: a slim green bar only, no name. You know who you are; your full HP
--     is in the HUD, and a thin bar above your head keeps your eyes on the
--     fight without a second big label covering your own hero.
--   * downed: the bar turns grey, full width, with 🩹 (own squad: revive) or
--     💀 (enemy: finish). Dead / spectating / gone: no tag.
-- The fill eases to the new HP in ~0.15 s; a white damage chip holds where
-- the fill was, then drains and fades.
--
-- Data sources (all already replicated; nothing new on the wire):
--   HP / max HP  players: Humanoid.Health / MaxHealth (CombatService mirrors
--                World hp every step); bots: model attributes "Hp" / "MaxHp"
--                (BotService, every step). Both are the server World's numbers.
--   squad        attribute "Squad" on the character / bot model (CombatService,
--                BotService); State.squadOf as a fallback.
--   downed/dead  attribute "Downed" (both); dead = "Spectator" (players) /
--                "Dead" (bots).
--   level        State "party" (PartyHud: your own squad only), so squadmates
--                show "Lv N" and enemies none.
--
-- Performance: one RenderStep binding; heroes are rescanned 4x a second; tags,
-- rings and highlights are pooled (no per-frame instance creation) and GUI
-- properties are only written when their (quantized) value changes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local State = require(script.Parent.State)
local PrestigeFrames: any = nil
do
	local ok, mod = pcall(function()
		return require(script.Parent.Parent.Visuals.PrestigeFrames) :: any
	end)
	PrestigeFrames = if ok then mod else nil
end
local Format = require(Client.Util.Format)
local HeroTagMath = require(Client.Util.HeroTagMath)
local SquadColors = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("SquadColors")
) :: any

local HeroTags = {}

HeroTags.FOLDER = "TrunkfallHeroTags"
HeroTags.TAG_NAME = "HeroTag"
HeroTags.SCAN_EVERY = 0.25
HeroTags.MAX_HIGHLIGHTS = 2
-- the server-side name tags this hides in runs (CosmeticsService / BotModel)
HeroTags.SERVER_TAGS = { "TrunkfallNameTag", "NameTag" }

local BIND_NAME = "TrunkfallHeroTags"
local W, H = 140, 50 -- design px of a full tag
local SELF_W, SELF_H = 64, 9 -- your own slim bar
local PLAYER_OFFSET = 3.1 -- studs above the head (clears the elephant hood)
local SUIT_EXTRA = 4 -- studs higher while the character wears the Herd Suit (attribute HerdSuit)
local BOT_OFFSET = 3.6 -- x RigScale (BotModel: 0.65)

local function c3(rgb: { number }): Color3
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

local ALLY = c3(SquadColors.ALLY)
local BAR_BG = Color3.fromRGB(22, 22, 28)
local CHIP = c3(SquadColors.CHIP)
local BADGE_TEXT = Color3.fromRGB(20, 20, 26)

----------------------------------------------------------------------
-- Pooled instances
----------------------------------------------------------------------

type Tag = {
	gui: BillboardGui,
	marker: TextLabel,
	badge: Frame,
	badgeText: TextLabel,
	name: TextLabel,
	bar: Frame,
	stroke: UIStroke,
	chip: Frame,
	fill: Frame,
	icon: TextLabel,
}

type Entry = {
	key: Instance,
	id: number,
	isBot: boolean,
	isSelf: boolean,
	head: BasePart?,
	root: BasePart?,
	hum: Humanoid?,
	tag: Tag?,
	ring: CylinderHandleAdornment?,
	hl: Highlight?,
	bar: HeroTagMath.Bar,
	relation: string,
	suit: boolean?, -- character attribute HerdSuit (the taller elephant suit)
	prestige: string?, -- "<prestige>:<wheel>" from the player's attributes (G PrestigeFrames)
	squad: number?,
	target: number,
	downed: boolean,
	dead: boolean,
	label: string,
	seen: number,
	-- last values written (only write on change)
	wScale: number,
	wAlpha: number,
	wFill: number,
	wChip: number,
	wChipA: number,
	wDowned: boolean?,
	wTop: boolean?,
}

local folder: Folder? = nil
local tagPool: { Tag } = {}
local ringPool: { CylinderHandleAdornment } = {}
local hlPool: { Highlight } = {}
local entries: { [Instance]: Entry } = {}
-- server tags turned off on this client -> their Enabled before
local hiddenTags: { [BillboardGui]: boolean } = {}
local hiddenHums: { [Humanoid]: Enum.HumanoidHealthDisplayType } = {}
local scanAcc = math.huge
local scanSeq = 0
local active = false
local bound = false
local unsubs: { () -> () } = {}

local function getFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = HeroTags.FOLDER
	nf.Parent = workspace
	folder = nf
	return nf
end

local function label(parent: Instance, name: string, font: Enum.Font): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = font
	l.TextScaled = true
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextStrokeColor3 = Color3.new(0, 0, 0)
	l.TextStrokeTransparency = 0.3
	l.Parent = parent
	return l
end

local function newTag(): Tag
	local gui = Instance.new("BillboardGui")
	gui.Name = HeroTags.TAG_NAME
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.ClipsDescendants = false
	gui.Enabled = false

	local marker = label(gui, "Marker", Enum.Font.GothamBlack)
	marker.Position = UDim2.fromScale(0, 0)
	marker.Size = UDim2.fromScale(1, 0.3)
	marker.Text = "▼"
	marker.TextColor3 = ALLY

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0.5, 0)
	badge.Position = UDim2.fromScale(0.5, 0.02)
	badge.Size = UDim2.fromScale(0.46, 0.26)
	badge.BorderSizePixel = 0
	badge.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = badge
	local badgeText = label(badge, "Squad", Enum.Font.GothamBold)
	badgeText.Size = UDim2.fromScale(1, 1)
	badgeText.TextColor3 = BADGE_TEXT
	badgeText.TextStrokeTransparency = 1

	local name = label(gui, "Name", Enum.Font.FredokaOne)
	name.Position = UDim2.fromScale(0, 0.28)
	name.Size = UDim2.fromScale(1, 0.36)

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.BackgroundColor3 = BAR_BG
	bar.BackgroundTransparency = 0.2
	bar.BorderSizePixel = 0
	bar.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Parent = bar

	local chip = Instance.new("Frame")
	chip.Name = "Chip"
	chip.BackgroundColor3 = CHIP
	chip.BorderSizePixel = 0
	chip.Size = UDim2.fromScale(0, 1)
	chip.ZIndex = 2
	chip.Parent = bar
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(1, 1)
	fill.ZIndex = 3
	fill.Parent = bar

	local icon = label(gui, "Icon", Enum.Font.GothamBold)
	icon.Position = UDim2.fromScale(0, 0.6)
	icon.Size = UDim2.fromScale(0.13, 0.36)
	icon.Visible = false

	gui.Parent = getFolder()
	return {
		gui = gui,
		marker = marker,
		badge = badge,
		badgeText = badgeText,
		name = name,
		bar = bar,
		stroke = stroke,
		chip = chip,
		fill = fill,
		icon = icon,
	}
end

local function takeTag(): Tag
	return table.remove(tagPool) or newTag()
end

local function freeTag(t: Tag?)
	if t then
		t.gui.Enabled = false
		t.gui.Adornee = nil
		table.insert(tagPool, t)
	end
end

local function takeRing(): CylinderHandleAdornment
	local r = table.remove(ringPool)
	if r then
		return r
	end
	local n = Instance.new("CylinderHandleAdornment")
	n.Name = "AllyRing"
	n.Height = 0.06
	n.AlwaysOnTop = false
	n.ZIndex = 0
	n.Color3 = ALLY
	n.Transparency = 0.15
	n.Visible = false
	n.Parent = getFolder()
	return n
end

local function freeRing(r: CylinderHandleAdornment?)
	if r then
		r.Visible = false
		r.Adornee = nil
		table.insert(ringPool, r)
	end
end

local function takeHighlight(): Highlight
	local h = table.remove(hlPool)
	if h then
		return h
	end
	local n = Instance.new("Highlight")
	n.Name = "AllyHighlight"
	n.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	n.FillColor = ALLY
	n.OutlineColor = ALLY
	n.FillTransparency = 0.9
	n.OutlineTransparency = 0.15
	n.Enabled = false
	n.Parent = getFolder()
	return n
end

local function freeHighlight(h: Highlight?)
	if h then
		h.Enabled = false
		h.Adornee = nil
		table.insert(hlPool, h)
	end
end

----------------------------------------------------------------------
-- Server tags (hidden locally during runs)
----------------------------------------------------------------------

local function hideServerTags(e: Entry)
	local head = e.head
	if head then
		for _, n in HeroTags.SERVER_TAGS do
			local g = head:FindFirstChild(n)
			if g and g:IsA("BillboardGui") and g.Enabled then
				if hiddenTags[g] == nil then
					hiddenTags[g] = true
				end
				g.Enabled = false
			end
		end
	end
	local hum = e.hum
	if hum and hum.HealthDisplayType ~= Enum.HumanoidHealthDisplayType.AlwaysOff then
		if hiddenHums[hum] == nil then
			hiddenHums[hum] = hum.HealthDisplayType
		end
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end
end

local function restoreServerTags()
	for g, was in hiddenTags do
		if g.Parent then
			g.Enabled = was
		end
	end
	table.clear(hiddenTags)
	for hum, was in hiddenHums do
		if hum.Parent then
			hum.HealthDisplayType = was
		end
	end
	table.clear(hiddenHums)
end

----------------------------------------------------------------------
-- Entries
----------------------------------------------------------------------

local function dropEntry(key: Instance)
	local e = entries[key]
	if e then
		freeTag(e.tag)
		freeRing(e.ring)
		freeHighlight(e.hl)
		entries[key] = nil
	end
end

local function viewerSquad(): number?
	local s = State.mySquad()
	if s then
		return s
	end
	local me = Players.LocalPlayer
	local a = me and me:GetAttribute("Squad")
	return if type(a) == "number" then a else nil
end

local function levelOf(id: number): number?
	local party = State.get("party")
	local p = if type(party) == "table" then party[id] else nil
	return if type(p) == "table" then tonumber(p.level) else nil
end

local function nameOf(e: Entry): string
	if e.isBot then
		local dn = e.key:GetAttribute("DisplayName")
		return Format.botName(if type(dn) == "string" then dn else State.nameOf(e.id))
	end
	return State.nameOf(e.id)
end

local function feetY(e: Entry): number
	local root = e.root
	if not root then
		return 0
	end
	if e.isBot then
		return 0.05
	end
	local hum = e.hum
	local hip = if hum then hum.HipHeight else 0
	if hip <= 0.01 then
		hip = 2 -- R6 legs
	end
	return -(hip + root.Size.Y / 2) + 0.05
end

-- Lays the tag out for the hero's relation (once per bind / relation change).
local function layout(e: Entry)
	local t = e.tag
	if not t then
		return
	end
	local rel = e.relation
	local isSelf = rel == "self"
	t.gui.AlwaysOnTop = rel ~= "enemy" and rel ~= "neutral"
	t.gui.StudsOffsetWorldSpace = Vector3.new(
		0,
		(if e.isBot then BOT_OFFSET * (tonumber(e.key:GetAttribute("RigScale")) or 0.65) else PLAYER_OFFSET)
			+ (if e.suit then SUIT_EXTRA else 0),
		0
	)
	t.marker.Visible = rel == "ally"
	t.marker.Text = HeroTagMath.marker(rel)
	t.badge.Visible = rel == "enemy"
	if rel == "enemy" then
		local sq = State.squad(e.squad)
		t.badge.BackgroundColor3 = c3(SquadColors.rgb(e.squad))
		t.badgeText.Text = if sq and sq.name then tostring(sq.name) else SquadColors.name(e.squad)
	end
	t.name.Visible = not isSelf
	t.name.Text = e.label
	if PrestigeFrames then
		local pr, wheel = string.match(e.prestige or "0:false", "^(%d+):(%a+)$")
		pcall(PrestigeFrames.apply, t.name, PrestigeFrames.frameFor(tonumber(pr) or 0, wheel == "true"))
	end
	if isSelf then
		t.bar.Position = UDim2.fromScale(0, 0)
		t.bar.Size = UDim2.fromScale(1, 1)
		t.stroke.Thickness = 1.5
	else
		t.bar.Position = UDim2.fromScale(0.14, 0.68)
		t.bar.Size = UDim2.fromScale(0.72, 0.2)
		t.stroke.Thickness = 2
	end
	t.stroke.Color = c3(SquadColors.rgb(e.squad))
	t.icon.Text = HeroTagMath.downIcon(rel)
	e.wScale, e.wAlpha, e.wFill, e.wChip, e.wChipA = -1, -1, -1, -1, -1
	e.wDowned = nil
end

local function bind(key: Instance, id: number, isBot: boolean, isSelf: boolean): Entry
	local e: Entry = {
		key = key,
		id = id,
		isBot = isBot,
		isSelf = isSelf,
		head = nil,
		root = nil,
		hum = nil,
		tag = nil,
		ring = nil,
		hl = nil,
		bar = HeroTagMath.newBar(1),
		relation = "",
		suit = nil,
		prestige = nil,
		squad = nil,
		target = 1,
		downed = false,
		dead = false,
		label = "",
		seen = scanSeq,
		wScale = -1,
		wAlpha = -1,
		wFill = -1,
		wChip = -1,
		wChipA = -1,
	}
	entries[key] = e
	return e
end

-- Refreshes an entry from the model (scan rate): parts, squad, relation, name.
local function refresh(e: Entry, mySquad: number?)
	local key = e.key
	if e.isBot then
		local m = key :: Model
		e.root = m.PrimaryPart
		local head = if e.head and e.head.Parent then e.head else m:FindFirstChild("Head", true)
		e.head = if head and head:IsA("BasePart") then head else nil
	else
		local root = key:FindFirstChild("HumanoidRootPart")
		e.root = if root and root:IsA("BasePart") then root else nil
		local head = key:FindFirstChild("Head")
		e.head = if head and head:IsA("BasePart") then head else nil
		e.hum = key:FindFirstChildOfClass("Humanoid")
	end
	local sq = key:GetAttribute("Squad")
	e.squad = if type(sq) == "number" then sq else State.squadOf(e.id)
	local rel = SquadColors.relation(mySquad, e.squad, e.isSelf)
	local lbl = HeroTagMath.label(nameOf(e), if rel == "ally" then levelOf(e.id) else nil)
	e.dead = key:GetAttribute(if e.isBot then "Dead" else "Spectator") == true
	local adornee = e.head or e.root
	if e.dead or not adornee then
		freeTag(e.tag)
		e.tag = nil
	else
		if not e.tag then
			e.tag = takeTag()
			e.relation = ""
		end
		local t = e.tag :: Tag
		if t.gui.Adornee ~= adornee then
			t.gui.Adornee = adornee
		end
		local suit = key:GetAttribute("HerdSuit") == true
		-- Prestige nameplate frame (player attributes "Prestige" / "WheelFrame")
		local owner = if e.isBot then nil else Players:GetPlayerFromCharacter(key :: Model)
		local pres = if owner
			then tostring(owner:GetAttribute("Prestige") or 0) .. ":" .. tostring(owner:GetAttribute("WheelFrame") == true)
			else "0:false"
		if rel ~= e.relation or lbl ~= e.label or suit ~= e.suit or pres ~= e.prestige then
			e.relation = rel
			e.label = lbl
			e.suit = suit
			e.prestige = pres
			layout(e)
		end
		t.gui.Enabled = true
	end
	e.relation = rel
	hideServerTags(e)
	-- ally ground ring
	local wantRing = rel == "ally" and not e.dead and e.root ~= nil
	if wantRing then
		local r = e.ring or takeRing()
		e.ring = r
		local base = if e.isBot then 3.4 else 2.6 -- outside HeroFx's squad ring
		if r.Adornee ~= e.root then
			r.Adornee = e.root
			r.Radius = base + 0.75
			r.InnerRadius = base + 0.4
			r.CFrame = CFrame.new(0, feetY(e), 0) * CFrame.Angles(math.pi / 2, 0, 0)
		end
		r.Visible = true
	elseif e.ring then
		freeRing(e.ring)
		e.ring = nil
	end
end

-- Hands the (at most MAX_HIGHLIGHTS) ally outlines to the standing squadmates
-- with the lowest ids (stable from scan to scan).
local function assignHighlights()
	local mates: { Entry } = {}
	for _, e in entries do
		if e.relation == "ally" and not e.dead then
			table.insert(mates, e)
		elseif e.hl then
			freeHighlight(e.hl)
			e.hl = nil
		end
	end
	table.sort(mates, function(a, b)
		return a.id < b.id
	end)
	for i, e in mates do
		if i <= HeroTags.MAX_HIGHLIGHTS then
			local h = e.hl or takeHighlight()
			e.hl = h
			if h.Adornee ~= e.key then
				h.Adornee = e.key
			end
			h.OutlineTransparency = if e.downed then 0.55 else 0.15
			h.Enabled = true
		elseif e.hl then
			freeHighlight(e.hl)
			e.hl = nil
		end
	end
end

local function scan()
	scanSeq += 1
	local mySquad = viewerSquad()
	local me = Players.LocalPlayer
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		if char and char:GetAttribute("Squad") ~= nil then
			local e = entries[char] or bind(char, plr.UserId, false, plr == me)
			e.seen = scanSeq
			refresh(e, mySquad)
		end
	end
	local bots = workspace:FindFirstChild("Bots")
	if bots then
		for _, m in bots:GetChildren() do
			local id = tonumber(m:GetAttribute("BotId"))
			if id and m:IsA("Model") then
				local e = entries[m] or bind(m, id, true, false)
				e.seen = scanSeq
				refresh(e, mySquad)
			end
		end
	end
	for key, e in entries do
		if e.seen ~= scanSeq or not key.Parent then
			dropEntry(key)
		end
	end
	assignHighlights()
end

----------------------------------------------------------------------
-- Per frame
----------------------------------------------------------------------

local function readTarget(e: Entry)
	local key = e.key
	e.downed = key:GetAttribute("Downed") == true
	local hp, maxHp
	if e.isBot then
		hp, maxHp = tonumber(key:GetAttribute("Hp")), tonumber(key:GetAttribute("MaxHp"))
	elseif e.hum then
		hp, maxHp = e.hum.Health, e.hum.MaxHealth
	end
	if hp and maxHp and maxHp > 0 then
		e.target = math.clamp(hp / maxHp, 0, 1)
	end
end

local function setAlpha(t: Tag, a: number)
	local tr = 1 - a
	t.name.TextTransparency = tr
	t.name.TextStrokeTransparency = 0.3 + 0.7 * tr
	t.badge.BackgroundTransparency = 0.1 + 0.9 * tr
	t.badgeText.TextTransparency = tr
	t.marker.TextTransparency = tr
	t.bar.BackgroundTransparency = 0.2 + 0.8 * tr
	t.stroke.Transparency = tr
	t.fill.BackgroundTransparency = tr
	t.icon.TextTransparency = tr
end

local function myPosition(): Vector3?
	local me = Players.LocalPlayer
	local ch = me and me.Character
	local r = ch and ch:FindFirstChild("HumanoidRootPart")
	if r and r:IsA("BasePart") then
		return r.Position
	end
	local cam = workspace.CurrentCamera
	return if cam then cam.Focus.Position else nil
end

local function stepEntry(e: Entry, dt: number, from: Vector3?)
	local t = e.tag
	if not t then
		return
	end
	readTarget(e)
	-- size / fade by distance (enemies only)
	local dist = 0
	local root = e.root
	if from and root then
		local p = root.Position
		dist = math.sqrt((p.X - from.X) ^ 2 + (p.Z - from.Z) ^ 2)
	end
	local scale, alpha = HeroTagMath.fade(e.relation, dist)
	scale = HeroTagMath.quantize(scale, 20)
	alpha = HeroTagMath.quantize(alpha, 20)
	if alpha <= 0 then
		if t.gui.Enabled then
			t.gui.Enabled = false
		end
		return
	elseif not t.gui.Enabled then
		t.gui.Enabled = true
	end
	if scale ~= e.wScale then
		e.wScale = scale
		local isSelf = e.relation == "self"
		t.gui.Size = UDim2.fromOffset(
			math.floor((if isSelf then SELF_W else W) * scale + 0.5),
			math.floor((if isSelf then SELF_H else H) * scale + 0.5)
		)
	end
	if alpha ~= e.wAlpha then
		e.wAlpha = alpha
		setAlpha(t, alpha)
		e.wChipA = -1
	end
	-- downed: a full grey bar with the icon; the bar restarts from empty
	if e.downed ~= e.wDowned then
		e.wDowned = e.downed
		t.fill.BackgroundColor3 = c3(SquadColors.barColor(e.relation, e.downed))
		t.icon.Visible = e.downed and e.relation ~= "self"
		if e.downed then
			e.bar = HeroTagMath.newBar(0)
			t.fill.Size = UDim2.fromScale(1, 1)
			t.chip.Visible = false
			e.wFill = 1
		else
			t.chip.Visible = true
			e.wFill = -1
		end
	end
	if e.downed then
		return
	end
	local chipA = HeroTagMath.stepBar(e.bar, e.target, dt)
	local fill = math.floor(e.bar.shown * 200 + 0.5) / 200
	if fill ~= e.wFill then
		e.wFill = fill
		t.fill.Size = UDim2.fromScale(fill, 1)
	end
	local chip = math.floor(e.bar.chip * 200 + 0.5) / 200
	if chip ~= e.wChip then
		e.wChip = chip
		t.chip.Size = UDim2.fromScale(chip, 1)
	end
	local ca = HeroTagMath.quantize(chipA * alpha, 10)
	if ca ~= e.wChipA then
		e.wChipA = ca
		t.chip.BackgroundTransparency = 1 - ca
	end
end

local function deactivate()
	for key in entries do
		dropEntry(key)
	end
	restoreServerTags()
end

local function inRun(): boolean
	if State.inLobby() then
		return false
	end
	return viewerSquad() ~= nil or type(State.get("match")) == "table"
end

local function render(dt: number)
	local want = inRun()
	if want ~= active then
		active = want
		scanAcc = math.huge
		if not want then
			deactivate()
		end
	end
	if not active then
		return
	end
	scanAcc += dt
	if scanAcc >= HeroTags.SCAN_EVERY then
		scanAcc = 0
		scan()
	end
	local from = myPosition()
	for _, e in entries do
		stepEntry(e, dt, from)
	end
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

-- Live tags (for tests / debugging): {id, relation, name, visible}.
function HeroTags.snapshot(): { { [string]: any } }
	local out = {}
	for _, e in entries do
		table.insert(out, {
			id = e.id,
			relation = e.relation,
			name = e.label,
			squad = e.squad,
			visible = e.tag ~= nil and e.tag.gui.Enabled,
			highlight = e.hl ~= nil,
			ring = e.ring ~= nil,
		})
	end
	return out
end

function HeroTags.init()
	if bound then
		return
	end
	bound = true
	getFolder()
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 4, render)
end

function HeroTags.destroy()
	if not bound then
		return
	end
	bound = false
	pcall(function()
		RunService:UnbindFromRenderStep(BIND_NAME)
	end)
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	deactivate()
	active = false
end

return HeroTags
