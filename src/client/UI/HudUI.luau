--!strict
-- In-run HUD v2 (squad PvPvE, docs/GDD-v2.md). One ScreenGui:
--
--   top-left      own status card (level badge, class, HP with a damage trail,
--                 a slim XP bar, Second Winds, bounty warning) and the compact
--                 squad panel (your 2 mates: class, HP, down / out, in squad
--                 colours; v1: party)
--   top-centre    thin scoreboard bar (4 squads: colour, name, alive pips,
--                 pending cheese, kills, Extracted / Eliminated badges; tap or
--                 Tab for the full board), stage + map, phase timer, the
--                 Double or Nothing badge, curse / blessing chips, boss bar,
--                 and the short discovery / bounty banner under them
--   top-right     minimap (UI/MinimapUI) and kill feed (UI/KillFeedUI)
--   bottom-centre gear slots + swap prompt (UI/GearUI) and the ability
--                 cooldown radial (PC / gamepad; touch uses InputController's button)
--   centre        downed overlay, POI progress ring
--
-- v3 compact sizes (PC "dense" screens and phones) come from Util/UiSizes.hud.
-- Reads State: run, hud, party, boss, match, killfeed, inventory, profile, lobby.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local MinimapUI = require(script.Parent.MinimapUI)
local KillFeedUI = require(script.Parent.KillFeedUI)
local GearUI = require(script.Parent.GearUI)
local ClassInfo = require(script.Parent.ClassInfo)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local UiSizes = require(Client.Util.UiSizes)
local Device = require(Client.Util.Device)
local AbilitySlots = require(Client.Util.AbilitySlots)
local LadderModel = require(Client.Util.LadderModel)
local State = require(Client.Controllers.State)
local Remotes = require(Client.Util.Remotes)
local ChampView = require(Client.Util.ChampView)
local BuildMath = require(Client.Util.BuildMath)
local Icons = require(script.Parent.Icons)

local PoiDefs: any = nil
do
	local ok, mod = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Pois"))
	end)
	if ok then
		PoiDefs = mod
	end
end

local BUFF_ICONS: { [string]: string } = {
	shrine_swift = "💨",
	shrine_might = "💪",
	shrine_mending = "💚",
}

local HudUI = {}

local C = Theme.C
local T = Theme.TYPE
local make = Theme.make

local PHASE_TEXT: { [string]: string } = {
	Lobby = "Lobby",
	RouteVote = "Choose your route!",
	RouteChoice = "Route choice",
	Waves = "Survive the horde!",
	Boss = "BOSS FIGHT!",
	StageClear = "Stage clear!",
	Extraction = "The Rind Gate is open!",
	BankVote = "Bank it or gamble?",
	CycleVote = "Go home or go deeper?",
	Results = "Run over",
}

local screen: any = nil
local unsubs: { () -> () } = {}
local parts: { any } = {}
local renderConn: RBXScriptConnection? = nil

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

function HudUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallHud", 10)
	local root: Frame = screen.root
	local touch = Theme.TOUCH
	local dense = Theme.dense()
	local Z = UiSizes.hud(dense, touch)

	------------------------------------------------------------------
	-- Own status card (top-left)
	------------------------------------------------------------------
	local status = Theme.card({
		Name = "Status",
		Position = UDim2.fromOffset(Z.margin, Z.headerY + 2),
		Size = UDim2.fromOffset(Z.statusW, Z.statusH),
		Parent = root,
	})
	local levelBadge = make("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, (Z.barX - Z.badge) // 2, 0.5, 0),
		Size = UDim2.fromOffset(Z.badge, Z.badge),
		BackgroundColor3 = C.cheese,
		Parent = status,
	})
	Theme.round().Parent = levelBadge
	Theme.gloss(levelBadge, 1, 0.75)
	Theme.stroke(C.brownDark, if dense then 2 else 3).Parent = levelBadge
	if Z.showLevelCaption then
		Theme.label({
			Position = UDim2.fromOffset(0, 6),
			Size = UDim2.new(1, 0, 0, 14),
			TextSize = T.micro,
			TextColor3 = C.brownDark,
			Text = "LEVEL",
			Parent = levelBadge,
		})
	end
	local levelText = Theme.label({
		AnchorPoint = Vector2.new(0, 0.5),
		Position = if Z.showLevelCaption then UDim2.new(0, 0, 0.5, 4) else UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, 0, 0, Z.levelText + 6),
		TextSize = Z.levelText,
		TextColor3 = C.ink,
		Text = "1",
		Parent = levelBadge,
	})
	Theme.tooltip(levelBadge, "Run level: crumbs give XP, each level offers an upgrade.")
	local classLine = Theme.label({
		Position = UDim2.fromOffset(Z.barX, Z.classY),
		Size = UDim2.fromOffset(Z.barW, Z.classH),
		TextSize = Z.classText,
		TextColor3 = C.gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Text = "",
		Parent = status,
	})
	Theme.textStroke(C.shade, 1).Parent = classLine
	local hpBar = Theme.bar({
		Position = UDim2.fromOffset(Z.barX, Z.hpY),
		Size = UDim2.fromOffset(Z.barW, Z.hpH),
		Parent = status,
	}, C.hp, { trail = true })
	hpBar.text.TextSize = Z.hpText
	local xpBar = Theme.bar({
		Position = UDim2.fromOffset(Z.barX, Z.xpY),
		Size = UDim2.fromOffset(Z.barW, Z.xpH),
		Parent = status,
	}, C.xp)
	xpBar.text.TextSize = T.micro
	xpBar.text.Visible = Z.showXpText
	local xpCaption = ""
	Theme.tooltip(xpBar.frame, function()
		return xpCaption
	end)
	local windRow = make("Frame", {
		Position = UDim2.fromOffset(Z.barX, Z.windY),
		Size = UDim2.fromOffset(Z.barW, Z.windH),
		BackgroundTransparency = 1,
		Parent = status,
	})
	Theme.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent =
		windRow
	Theme.icon("heart", Z.windH - 4, C.hp, { LayoutOrder = 1, Parent = windRow })
	local windLabel = Theme.label({
		LayoutOrder = 2,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, Z.windH),
		TextSize = Z.windText,
		TextWrapped = false,
		Text = "",
		Parent = windRow,
	})
	Theme.textStroke(C.shade, 1).Parent = windLabel
	Theme.tooltip(windLabel, "Second Wind: get back up by yourself while downed (max 1 per stage).")
	local bountyBadge = Theme.badge(
		if dense then "🎯 BOUNTY" else "🎯 BOUNTY ON YOU",
		C.red,
		{ LayoutOrder = 3, Visible = false, Size = UDim2.fromOffset(0, Z.windH), Parent = windRow }
	)
	Theme.tooltip(
		bountyBadge,
		"You're on a 3-down streak: you show on everyone's minimap, and whoever downs you earns +100 cheese."
	)
	-- iteration 6: the Tinkerphant's live builds ("Turrets 1/2"), from BuildRenderer
	local buildBadge = Theme.badge("", C.rind, {
		LayoutOrder = 4,
		Visible = false,
		Size = UDim2.fromOffset(0, Z.windH),
		Parent = windRow,
	})
	Theme.tooltip(
		buildBadge,
		"Your turrets (and barricades) standing now. Placing one past the cap removes your oldest."
	)
	local function renderBuilds(bc: any)
		if type(bc) ~= "table" then
			buildBadge.Visible = false
			return
		end
		local tu = if type(bc.turret) == "table" then bc.turret else { n = 0, cap = 2 }
		local ba = if type(bc.barricade) == "table" then bc.barricade else { n = 0, cap = 2 }
		local show = bc.builder == true or (tonumber(tu.n) or 0) > 0 or (tonumber(ba.n) or 0) > 0
		buildBadge.Visible = show
		if not show then
			return
		end
		local text = "🔩 " .. BuildMath.counterText("turret", tonumber(tu.n) or 0, tonumber(tu.cap))
		if (tonumber(ba.n) or 0) > 0 then
			text ..= " · " .. BuildMath.counterText("barricade", tonumber(ba.n) or 0, tonumber(ba.cap))
		end
		if dense then
			text = (string.gsub(text, "Turrets ", ""))
			text = (string.gsub(text, "Barricades ", "🧱 "))
		end
		buildBadge.Text = text
		buildBadge.BackgroundColor3 = if (tonumber(tu.n) or 0) >= (tonumber(tu.cap) or 2)
			then C.goldDeep
			else C.rind
	end
	table.insert(unsubs, State.subscribe("buildCount", renderBuilds, true))

	------------------------------------------------------------------
	-- Squad panel (under the status card): your 2 mates (v1: the party)
	------------------------------------------------------------------
	local squadPanel = Theme.card({
		Name = "Squad",
		Position = UDim2.fromOffset(Z.margin, Z.headerY + 2 + Z.statusH + (if dense then 6 else 10)),
		Size = UDim2.fromOffset(Z.squadW, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = root,
	})
	Theme.padding(Z.squadPad, Z.squadPad).Parent = squadPanel
	Theme.list(Enum.FillDirection.Vertical, Z.squadGap, Enum.HorizontalAlignment.Left).Parent = squadPanel
	local squadTitle = Theme.label({
		LayoutOrder = 0,
		Size = UDim2.new(1, 0, 0, Z.squadTitleH),
		TextSize = Z.squadTitleText,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "SQUAD",
		Parent = squadPanel,
	})
	Theme.textStroke(C.shade, 1).Parent = squadTitle

	type MateRow = {
		frame: Frame,
		stripe: Frame,
		name: TextLabel,
		sub: TextLabel,
		tag: TextLabel,
		bar: any,
		icon: Frame,
	}
	local mateRows: { MateRow } = {}
	local function mateRow(i: number): MateRow
		local r = mateRows[i]
		if r then
			return r
		end
		local frame = make("Frame", {
			LayoutOrder = i,
			Size = UDim2.new(1, 0, 0, Z.mateH),
			BackgroundColor3 = C.rindLight,
			BackgroundTransparency = 0.35,
			Parent = squadPanel,
		}) :: Frame
		Theme.corner(10).Parent = frame
		local stripe = make("Frame", {
			Size = UDim2.new(0, 5, 1, 0),
			BackgroundColor3 = C.cheese,
			BorderSizePixel = 0,
			Parent = frame,
		}) :: Frame
		Theme.corner(3).Parent = stripe
		local iconBox = make("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 9, 0.5, 0),
			Size = UDim2.fromOffset(Z.mateIcon, Z.mateIcon),
			BackgroundColor3 = C.rind,
			Parent = frame,
		}) :: Frame
		Theme.round().Parent = iconBox
		local textX = 9 + Z.mateIcon + 8
		local icon = Theme.icon("hero", math.floor(Z.mateIcon * 0.75), C.cream, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Parent = iconBox,
		})
		local name = Theme.label({
			Position = UDim2.fromOffset(textX, 3),
			Size = UDim2.new(1, -(textX + Z.mateSubW + 4), 0, Z.mateNameH),
			TextSize = Z.mateNameText,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Parent = frame,
		})
		Theme.textStroke(C.shade, 1).Parent = name
		local sub = Theme.label({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, 3),
			Size = UDim2.fromOffset(Z.mateSubW, Z.mateNameH),
			TextSize = Z.mateSubText,
			Font = Theme.FONT_BODY,
			TextColor3 = C.textDim,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextWrapped = false,
			Parent = frame,
		})
		local bar = Theme.bar({
			Position = UDim2.fromOffset(textX, Z.mateBarY),
			Size = UDim2.new(1, -(textX + 8), 0, Z.mateBarH),
			Parent = frame,
		}, C.hp, { trail = true })
		bar.text.TextSize = Z.mateBarText
		local tag = Theme.label({
			Position = UDim2.fromOffset(textX, Z.mateBarY),
			Size = UDim2.new(1, -(textX + 8), 0, Z.mateBarH),
			TextSize = Z.mateBarText + 1,
			TextColor3 = C.red,
			ZIndex = 5,
			Parent = frame,
		})
		Theme.textStroke(C.shade, 1.5).Parent = tag
		r = { frame = frame, stripe = stripe, name = name, sub = sub, tag = tag, bar = bar, icon = icon }
		mateRows[i] = r
		return r
	end

	local function renderSquad()
		local party = State.get("party")
		local match = State.get("match")
		local me = State.localUserId()
		local ids: { number } = {}
		local squadColor = C.cheese
		local mine = State.mySquad()
		local sq = State.squad(mine)
		if sq then
			squadColor = rgb(sq.color)
			squadTitle.Text = string.upper(sq.name) .. " SQUAD"
			for _, id in sq.members do
				if id ~= me then
					table.insert(ids, id)
				end
			end
		else
			squadTitle.Text = if type(match) == "table" then "SQUAD" else "PARTY"
			if type(party) == "table" then
				for id in party do
					if id ~= me then
						table.insert(ids, id)
					end
				end
			end
			table.sort(ids, function(a, b)
				local ba, bb = State.isBot(a, nil), State.isBot(b, nil)
				if ba ~= bb then
					return not ba
				end
				return a < b
			end)
		end
		squadTitle.TextColor3 = squadColor
		local n = 0
		for _, id in ids do
			if n >= 3 then
				break
			end
			n += 1
			local r = mateRow(n)
			local e = if type(party) == "table" then party[id] else nil
			local bot = State.isBot(id, e)
			local classDef = Defs.get("Classes", if type(e) == "table" then e.classId else nil)
			r.frame.Visible = true
			r.stripe.BackgroundColor3 = squadColor
			local mateName = if type(e) == "table" and e.name then tostring(e.name) else State.nameOf(id)
			r.name.Text = if bot then Format.botName(mateName) else mateName
			r.name.TextColor3 = squadColor:Lerp(C.white, 0.35)
			r.sub.Text = if classDef
				then Defs.name(classDef, e.classId) .. " " .. tostring(tonumber(e.level) or 1)
				else ""
			for _, d in r.icon:GetDescendants() do
				if d:IsA("Frame") then
					d.BackgroundColor3 = if classDef then Format.rgb(classDef.color, C.cream) else C.cream
				end
			end
			if type(e) == "table" then
				local hp, maxHp = tonumber(e.hp) or 0, math.max(1, tonumber(e.maxHp) or 1)
				r.bar.set(hp / maxHp, string.format("%d / %d", math.floor(hp), math.floor(maxHp)))
				r.bar.setColor(if hp / maxHp < 0.3 then C.hpLow else C.hp)
				r.bar.frame.Visible = e.dead ~= true and e.downed ~= true
				if e.dead == true then
					r.tag.Text = "OUT"
					r.tag.TextColor3 = C.grey
				elseif e.downed == true then
					r.tag.Text = if dense then "DOWN! Revive" else "DOWN! Revive them"
					r.tag.TextColor3 = C.red
				else
					r.tag.Text = ""
				end
				r.frame.BackgroundColor3 = if e.downed == true
					then Color3.fromRGB(110, 30, 25)
					else C.rindLight
			else
				r.bar.frame.Visible = false
				r.tag.Text = "…"
				r.tag.TextColor3 = C.textDim
			end
		end
		for i = n + 1, #mateRows do
			mateRows[i].frame.Visible = false
		end
		squadPanel.Visible = n > 0 and status.Visible
	end

	------------------------------------------------------------------
	-- Header (top-centre): scoreboard strip + run rows
	------------------------------------------------------------------
	local HEADER_W = Z.headerW
	local header = make("Frame", {
		Name = "Header",
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(0.5, 0, 0, Z.headerY),
		Size = UDim2.fromOffset(HEADER_W, UiSizes.headerHeight(dense, touch)),
		Parent = root,
	})
	Theme.list(Enum.FillDirection.Vertical, Z.headerGap).Parent = header

	-- Scoreboard strip (a thin bar on PC): 4 squad tiles.
	local TILE_W, TILE_H = Z.tileW, Z.tileH
	local strip = make("TextButton", {
		Name = "Scoreboard",
		LayoutOrder = 0,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromOffset(4 * TILE_W + 3 * Z.tileGap, TILE_H),
		Visible = false,
		Selectable = false,
		Parent = header,
	}) :: TextButton
	Theme.list(
		Enum.FillDirection.Horizontal,
		Z.tileGap,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	).Parent =
		strip
	strip.Activated:Connect(function()
		State.toggleScoreboard()
	end)
	Theme.tooltip(strip, function()
		return if Device.mode() == "touch" then "" else "Squads in this match. Tab: full scoreboard."
	end)

	type Tile = {
		frame: Frame,
		stroke: UIStroke,
		band: Frame,
		name: TextLabel,
		pips: { Frame },
		pending: TextLabel,
		kills: TextLabel,
		badge: TextLabel,
		dim: Frame,
	}
	local tiles: { Tile } = {}
	for i = 1, 4 do
		local f = Theme.card({
			LayoutOrder = i,
			Size = UDim2.fromOffset(TILE_W, TILE_H),
			Active = false,
			Parent = strip,
		}, { shadow = false, accent = C.rindLight, stroke = 2 })
		local stroke = f:FindFirstChildOfClass("UIStroke") :: UIStroke
		local band = make("Frame", {
			Size = UDim2.new(1, 0, 0, Z.tileBand),
			BackgroundColor3 = C.cheese,
			BorderSizePixel = 0,
			Parent = f,
		}) :: Frame
		Theme.corner(Z.tileBand).Parent = band
		local line1 = Z.tileBand + (if dense then 1 else 2)
		local line2 = line1 + Z.tileLineH + (if dense then 1 else 4)
		local name = Theme.label({
			Position = UDim2.fromOffset(if dense then 6 else 8, line1),
			Size = UDim2.new(1, -(3 * (Z.tilePip + 3) + 12), 0, Z.tileLineH),
			TextSize = Z.tileText,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Parent = f,
		})
		Theme.textStroke(C.shade, 1).Parent = name
		local pips: { Frame } = {}
		for p = 1, 3 do
			local pip = make("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -6 - (3 - p) * (Z.tilePip + 3), 0, line1 + Z.tileLineH / 2),
				Size = UDim2.fromOffset(Z.tilePip, Z.tilePip),
				BackgroundColor3 = C.green,
				Parent = f,
			}) :: Frame
			Theme.round().Parent = pip
			Theme.stroke(C.shade, 1).Parent = pip
			pips[p] = pip
		end
		local row = make("Frame", {
			Position = UDim2.fromOffset(6, line2),
			Size = UDim2.new(1, -12, 0, Z.tileLineH),
			BackgroundTransparency = 1,
			Parent = f,
		})
		Theme.list(
			Enum.FillDirection.Horizontal,
			4,
			Enum.HorizontalAlignment.Left,
			Enum.VerticalAlignment.Center
		).Parent =
			row
		Theme.icon("cheese", Z.tileIcon, C.cheese, { LayoutOrder = 1, Parent = row })
		local pending = Theme.label({
			LayoutOrder = 2,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, Z.tileLineH),
			TextSize = Z.tileText,
			TextWrapped = false,
			Parent = row,
		})
		Theme.textStroke(C.shade, 1).Parent = pending
		Theme.icon("skull", Z.tileIcon - 2, C.cream, { LayoutOrder = 3, Parent = row })
		local kills = Theme.label({
			LayoutOrder = 4,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, Z.tileLineH),
			TextSize = Z.tileText,
			TextWrapped = false,
			Parent = row,
		})
		Theme.textStroke(C.shade, 1).Parent = kills
		local dim = make("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = C.shadow,
			BackgroundTransparency = 0.45,
			Visible = false,
			ZIndex = 8,
			Parent = f,
		}) :: Frame
		Theme.corner(14).Parent = dim
		local badge = Theme.badge("", C.green, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, if dense then 0.5 else 0.62),
			Size = UDim2.fromOffset(0, if dense then 18 else 20),
			Visible = false,
			ZIndex = 9,
			Parent = f,
		})
		tiles[i] = {
			frame = f,
			stroke = stroke,
			band = band,
			name = name,
			pips = pips,
			pending = pending,
			kills = kills,
			badge = badge,
			dim = dim,
		}
	end

	local function renderStrip(match: any)
		local squads = if type(match) == "table" then match.squads else nil
		strip.Visible = type(squads) == "table" and #squads > 0
		if not strip.Visible then
			return
		end
		for i, tile in tiles do
			local s = squads[i]
			tile.frame.Visible = s ~= nil
			if s then
				local col = rgb(s.color)
				tile.band.BackgroundColor3 = col
				tile.name.Text = (if s.isYou then "★ " else "") .. s.name
				tile.name.TextColor3 = col:Lerp(C.white, 0.25)
				tile.pending.Text = Format.short(s.pending)
				tile.kills.Text = tostring(s.kills)
				for p, pip in tile.pips do
					pip.BackgroundColor3 = if p <= s.alive then C.green else C.greyDark
				end
				tile.stroke.Color = if s.isYou then C.gold else col:Lerp(C.rind, 0.4)
				tile.stroke.Thickness = if s.isYou then 3 else 2
				tile.dim.Visible = s.extracted or s.eliminated
				tile.badge.Visible = s.extracted or s.eliminated or s.doubleOrNothing
				if s.eliminated then
					tile.badge.Text = "ELIMINATED"
					tile.badge.BackgroundColor3 = C.red
				elseif s.extracted then
					tile.badge.Text = "EXTRACTED"
					tile.badge.BackgroundColor3 = C.greenDark
				elseif s.doubleOrNothing then
					tile.badge.Text = if dense then "×2 D-or-N" else "×2 DOUBLE OR NOTHING"
					tile.badge.BackgroundColor3 = C.orange
				end
			end
		end
	end

	local titleRow = Theme.label({
		LayoutOrder = 1,
		Size = UDim2.fromOffset(HEADER_W, Z.titleH),
		TextSize = Z.titleText,
		TextColor3 = C.cheese,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = header,
	})
	Theme.textStroke(C.brownDark, if dense then 2 else 2.5).Parent = titleRow
	local phaseRow = Theme.label({
		LayoutOrder = 2,
		Size = UDim2.fromOffset(HEADER_W, Z.phaseH),
		TextSize = Z.phaseText,
		TextWrapped = false,
		Parent = header,
	})
	Theme.textStroke().Parent = phaseRow
	local cheeseRow = make("Frame", {
		LayoutOrder = 3,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(HEADER_W, Z.cheeseH),
		Parent = header,
	})
	Theme.list(
		Enum.FillDirection.Horizontal,
		8,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	).Parent =
		cheeseRow
	Theme.icon("cheese", Z.cheeseIcon, C.cheese, { LayoutOrder = 0, Parent = cheeseRow })
	local cheeseLabel = Theme.label({
		LayoutOrder = 1,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, Z.cheeseH - 2),
		TextSize = Z.cheeseText,
		TextWrapped = false,
		Parent = cheeseRow,
	})
	Theme.textStroke().Parent = cheeseLabel
	Theme.tooltip(cheeseLabel, function()
		if State.isSquadMatch() then
			return "Pending cheese is your squad's pot. Extract to bank it. Eliminated heroes drop 30% of their share in a loot bag."
		end
		return "Pending cheese is at risk until you bank it. Banked cheese is safe."
	end)
	local donBadge = Theme.chip(
		"×2 DOUBLE OR NOTHING",
		C.red,
		"Pot ×2 if your squad survives and kills a champion or the boss this stage. Wipe = lose ALL pending cheese."
	)
	donBadge.LayoutOrder = 2
	donBadge.Visible = false
	donBadge.Parent = cheeseRow
	local chipsRow = make("Frame", {
		LayoutOrder = 4,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(HEADER_W, Z.chipsH),
		Parent = header,
	})
	Theme.list(
		Enum.FillDirection.Horizontal,
		6,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	).Parent =
		chipsRow

	-- Boss bar
	local bossFrame = make("Frame", {
		LayoutOrder = 5,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(Z.bossW, Z.bossH),
		Visible = false,
		Parent = header,
	})
	local bossName = Theme.label({
		Position = UDim2.fromOffset(Z.bossNameH + 4, 0),
		Size = UDim2.new(1, -2 * (Z.bossNameH + 4), 0, Z.bossNameH),
		TextSize = Z.bossNameText,
		TextColor3 = C.cheese,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = bossFrame,
	})
	Theme.textStroke(C.brownDark, if dense then 2 else 2.5).Parent = bossName
	Theme.icon("crown", Z.bossNameH, C.red, { Position = UDim2.fromOffset(0, 0), Parent = bossFrame })
	local bossBar = Theme.bar({
		Position = UDim2.fromOffset(0, Z.bossBarY),
		Size = UDim2.new(1, 0, 0, Z.bossBarH),
		Parent = bossFrame,
	}, C.red, { trail = true })
	bossBar.text.TextSize = Z.bossBarText

	-- Short banner (discovery, bounty, last herd) under the header rows, so
	-- it never covers the fight and never overlaps the toasts below it.
	local banner = Theme.label({
		Name = "Banner",
		LayoutOrder = 6,
		Size = UDim2.fromOffset(Z.bannerW, Z.bannerH),
		TextSize = Z.bannerText,
		TextColor3 = C.cheese,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
		Visible = false,
		Parent = header,
	})
	Theme.textStroke(C.brownDark, if dense then 2 else 3).Parent = banner

	local chipKey = ""
	local function renderChips(run: any)
		local curses = if type(run.activeCurses) == "table" then run.activeCurses else {}
		local blessings = if type(run.activeBlessings) == "table" then run.activeBlessings else {}
		local key = table.concat(curses, ",") .. "|" .. table.concat(blessings, ",")
		if key == chipKey then
			return
		end
		chipKey = key
		for _, ch in chipsRow:GetChildren() do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		local function add(id: string, isCurse: boolean, order: number)
			local def = Defs.get("Modifiers", id)
			local name = Defs.name(def, id)
			local desc = if def and def.description then tostring(def.description) else ""
			local tier = if def and def.tier then tostring(def.tier) .. " " else ""
			local tip =
				string.format("%s%s: %s\n%s", tier, if isCurse then "Curse" else "Blessing", name, desc)
			local chip = Theme.chip(
				(if isCurse then "☠ " else "✨ ") .. name,
				if isCurse then C.curse else C.green,
				tip
			)
			chip.LayoutOrder = order
			chip.Parent = chipsRow
		end
		for i, id in curses do
			add(tostring(id), true, i)
		end
		for i, id in blessings do
			add(tostring(id), false, 100 + i)
		end
		chipsRow.Visible = #curses + #blessings > 0
	end

	local function renderRun(run: any)
		local inRun = type(run) == "table" and run.phase ~= nil and run.phase ~= "Lobby"
		header.Visible = inRun
		status.Visible = inRun and run.phase ~= "Results"
		if not inRun then
			squadPanel.Visible = false
			return
		end
		local map = Defs.get("Maps", run.mapId)
		local mapText = if map then " · " .. Defs.name(map, run.mapId) else ""
		local match = State.get("match")
		if type(match) == "table" then
			titleRow.Text =
				string.format("Stage %d/4%s", tonumber(match.stage or run.stageInCycle) or 1, mapText)
		else
			titleRow.Text = string.format(
				"Cycle %d · Stage %d/4%s",
				tonumber(run.cycle) or 1,
				tonumber(run.stageInCycle) or 1,
				mapText
			)
		end
		local sq = State.squad(State.mySquad())
		if sq then
			cheeseLabel.Text = string.format("%s squad pot", Format.int(sq.pending))
			donBadge.Visible = sq.doubleOrNothing
			donBadge.Text = "×2 DOUBLE OR NOTHING"
		else
			cheeseLabel.Text = string.format(
				if dense then "%s pending · %s banked" else "%s pending  ·  %s banked",
				Format.int(run.pendingCheese),
				Format.int(run.bankedCheese)
			)
			donBadge.Visible = run.doubleOrNothing == true
			donBadge.Text = "×2 DOUBLE OR NOTHING"
		end
		renderChips(run)
		renderSquad()
	end

	------------------------------------------------------------------
	-- Minimap + kill feed (top-right)
	------------------------------------------------------------------
	local MAP_SIZE = Z.minimap
	table.insert(parts, MinimapUI.build(root, MAP_SIZE, Z.margin))
	-- v4: the storm pill (UI/CombatHudUI) straddles the minimap's bottom edge
	local stormHalf = math.ceil(UiSizes.combat(dense, touch).stormH / 2)
	-- v5: the wallet pill (UI/RunShopUI) sits between the minimap and the kill feed
	local walletH = UiSizes.combat(dense, touch).walletH + 4
	local killTop = 10 + MAP_SIZE + stormHalf + walletH + (if dense then 6 else 8)
	table.insert(parts, KillFeedUI.build(root, killTop, Z))

	------------------------------------------------------------------
	-- Bottom row: gear slots + ability (bottom-centre)
	------------------------------------------------------------------
	local bottomRow = make("Frame", {
		Name = "BottomRow",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -Z.bottomY),
		Size = UDim2.fromOffset(if dense then 420 else 560, Z.rowH),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = root,
	}) :: Frame
	Theme.list(
		Enum.FillDirection.Horizontal,
		Z.rowGap,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Bottom
	).Parent =
		bottomRow
	table.insert(parts, GearUI.build(bottomRow, root, Z))

	-- iteration 5 (A3): one cooldown tile per live ability slot (State.abilitySlots):
	-- slot 1 Space / Q / RMB (X), slot 2 E (Y), slot 3 R (B). Phones use the
	-- touch buttons (InputController) instead.
	type Tile = {
		frame: Frame,
		radial: any,
		text: TextLabel,
		icon: GuiObject,
		iconKind: string,
		hint: TextLabel,
		slot: number,
	}
	local tiles: { Tile } = {}
	local tileIcons = { "bolt", "star", "target" }
	for slot = 1, AbilitySlots.MAX do
		local size = if slot == 1 then Z.ability else math.floor(Z.ability * 0.82)
		local f = make("Frame", {
			Name = if slot == 1 then "Ability" else "Ability" .. slot,
			LayoutOrder = 9 + slot,
			Size = UDim2.fromOffset(size, size),
			BackgroundColor3 = if slot == 1 then C.cheese else C.goldLight,
			Visible = false,
			Parent = bottomRow,
		}) :: Frame
		Theme.round().Parent = f
		Theme.gloss(f, 1, 0.72)
		Theme.goldStroke(if dense then 3 else 4).Parent = f
		local radial = Theme.radial(f, C.shade, 0.4)
		local cd = Theme.label({
			Size = UDim2.fromScale(1, 1),
			TextSize = if slot == 1 then Z.abilityText else math.floor(Z.abilityText * 0.85),
			Text = "",
			ZIndex = 5,
			Parent = f,
		})
		Theme.textStroke().Parent = cd
		local icon = Theme.icon(
			tileIcons[slot] or "bolt",
			if slot == 1 then Z.abilityIcon else math.floor(Z.abilityIcon * 0.82),
			C.brownDark,
			{
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				ZIndex = 4,
				Parent = f,
			}
		)
		local hint = Theme.label({
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 0, -3),
			Size = UDim2.fromOffset(
				if slot == 1 then (if dense then 200 else 240) else size + Z.rowGap + 40,
				Z.abilityHintH
			),
			TextSize = Z.abilityHintText,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = f,
		})
		Theme.textStroke().Parent = hint
		tiles[slot] = {
			frame = f,
			radial = radial,
			text = cd,
			icon = icon,
			iconKind = tileIcons[slot] or "bolt",
			hint = hint,
			slot = slot,
		}
	end
	bottomRow.Size =
		UDim2.fromOffset((if dense then 420 else 560) + 2 * (math.floor(Z.ability * 0.82) + Z.rowGap), Z.rowH)
	local tileNames: { string } = { "Ability", "Ability", "Ability" }
	local lastSlotSig = ""
	local liveSlots = 1
	local function renderAbilityHint()
		local mode = Device.mode()
		for _, t in tiles do
			local key = AbilitySlots.keyHint(t.slot, mode, dense or liveSlots > 1)
			-- several tiles: the key first, so a truncated name still shows it
			t.hint.Text = if key == ""
				then tileNames[t.slot]
				elseif liveSlots > 1 then "[" .. key .. "] " .. tileNames[t.slot]
				else tileNames[t.slot] .. " [" .. key .. "]"
		end
	end
	local modeConn = Device.modeChanged:Connect(renderAbilityHint)
	table.insert(unsubs, function()
		modeConn:Disconnect()
	end)
	-- iteration 6: abilities with their own icon (the Tinkerphant's turret /
	-- barricade / wrench) swap the tile's per-slot icon
	local function setTileIcon(t: Tile, kind: string)
		if t.iconKind == kind then
			return
		end
		local size = if t.slot == 1 then Z.abilityIcon else math.floor(Z.abilityIcon * 0.82)
		local visible = t.icon.Visible
		t.icon:Destroy()
		t.icon = Theme.icon(kind, size, C.brownDark, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			ZIndex = 4,
			Parent = t.frame,
		})
		t.icon.Visible = visible
		t.iconKind = kind
	end
	local function abilityTooltip()
		local classId = State.myClassId()
		local slots = State.abilitySlots()
		liveSlots = math.max(1, #slots)
		for i = 1, AbilitySlots.MAX do
			local info = slots[i]
			tileNames[i] = if classId
				then ClassInfo.abilityName(classId, if info then info.id else nil)
				else "Ability"
			local t = tiles[i]
			if t then
				local def = if classId
					then ClassInfo.abilityDef(classId, if info then info.id else nil)
					else nil
				local kind = Icons.forAbility(if type(def) == "table" then def.kind else nil)
				setTileIcon(t, kind or tileIcons[i] or "bolt")
			end
		end
		local def = if classId then Defs.get("Classes", classId) else nil
		if def and classId then
			classLine.Text = string.upper(Defs.name(def, classId)) .. " · " .. tileNames[1]
		end
		renderAbilityHint()
	end

	------------------------------------------------------------------
	-- Downed overlay (centre)
	------------------------------------------------------------------
	local downedFull = Z.downFullH
	local downed = Theme.card({
		Name = "Downed",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, if dense then 0.66 else 0.6),
		Size = UDim2.fromOffset(Z.downW, downedFull),
		BackgroundColor3 = Color3.fromRGB(110, 28, 22),
		BackgroundTransparency = 0.1,
		Visible = false,
		Parent = root,
	}, { accent = C.red, stroke = 3 })
	local downTitle = Theme.label({
		Position = UDim2.fromOffset(0, if dense then 5 else 8),
		Size = UDim2.new(1, 0, 0, Z.downTitleH),
		TextSize = Z.downTitleText,
		Text = "You're down!",
		Parent = downed,
	})
	Theme.textStroke().Parent = downTitle
	local downSub = Theme.label({
		Position = UDim2.fromOffset(10, Z.downSubY),
		Size = UDim2.new(1, -20, 0, Z.downSubH),
		TextSize = Z.downSubText,
		Font = Theme.FONT_BODY,
		Text = "A squadmate can revive you by standing close.",
		Parent = downed,
	})
	local windButton = Theme.button("Second Wind [E]", C.cheese, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, if dense then -10 else -12),
		Size = UDim2.fromOffset(Z.downButtonW, touch),
		TextSize = Z.downButtonText,
		Parent = downed,
	}, function()
		local okIc, Input = pcall(require, Client.Controllers.InputController)
		if okIc then
			Input.useSecondWind()
		end
	end)

	local lastLevel = 0
	local function renderHud(hud: any)
		if type(hud) ~= "table" then
			return
		end
		local hp, maxHp = tonumber(hud.hp) or 0, math.max(1, tonumber(hud.maxHp) or 1)
		hpBar.set(hp / maxHp, string.format("%d / %d", math.floor(hp + 0.5), math.floor(maxHp + 0.5)))
		hpBar.setColor(if hp / maxHp < 0.3 then C.hpLow else C.hp)
		local xp, toNext = tonumber(hud.xp) or 0, math.max(1, tonumber(hud.xpToNext) or 1)
		xpCaption = string.format("XP %d / %d", math.floor(xp), math.floor(toNext))
		xpBar.set(xp / toNext, xpCaption)
		local level = tonumber(hud.level) or 1
		levelText.Text = tostring(level)
		if level > lastLevel and lastLevel > 0 then
			Theme.popIn(levelBadge)
		end
		lastLevel = level
		local winds = tonumber(hud.secondWinds) or 0
		windLabel.Text = string.format("Second Wind ×%d", winds)
		local canWind = hud.downed == true and winds > 0 and hud.secondWindReady ~= false
		if hud.downed == true and not downed.Visible then
			Theme.popIn(downed)
		end
		downed.Visible = hud.downed == true
		windButton.Visible = canWind
		downed.Size = UDim2.fromOffset(Z.downW, if canWind then downedFull else Z.downShortH)
		if hud.downed == true and winds > 0 and hud.secondWindReady == false then
			downSub.Text = "Second Wind already used this stage. Hold on!"
		elseif hud.downed == true then
			downSub.Text = if State.isSquadMatch()
				then "A squadmate can revive you. Enemy heroes can finish you!"
				else "A teammate can revive you by standing close."
		end
	end

	local function renderBoss(boss: any)
		if type(boss) ~= "table" then
			bossFrame.Visible = false
			return
		end
		bossFrame.Visible = true
		local def = boss.def
		local title = if type(def) == "table" and def.title then " · " .. tostring(def.title) else ""
		bossName.Text = Defs.name(def, boss.bossId) .. title
		bossBar.set(tonumber(boss.hpFrac) or 0, Format.pct(boss.hpFrac))
	end

	------------------------------------------------------------------
	-- Points of interest: progress ring, buff timers, banners
	------------------------------------------------------------------
	local poiState: { [number]: { kind: string, x: number, z: number, r: number, state: string, active: boolean, p: number } } =
		{}
	local buffs: { [string]: number } = {}
	local bagChannel: { p: number, at: number }? = nil -- loot bag you are channelling
	local function poiDef(kind: any): any
		return if PoiDefs and type(PoiDefs.get) == "function" then PoiDefs.get(tostring(kind)) else nil
	end
	local function defColor(def: any): Color3
		local c = def and def.color
		if type(c) == "table" and tonumber(c[1]) and tonumber(c[2]) and tonumber(c[3]) then
			return Color3.fromRGB(c[1], c[2], c[3])
		end
		return C.cheese
	end

	local poiRing = make("Frame", {
		Name = "PoiRing",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -(Z.rowH + Z.bottomY + Z.abilityHintH + Z.poiNameH + 12)),
		Size = UDim2.fromOffset(Z.poiRing, Z.poiRing),
		BackgroundColor3 = C.rind,
		BackgroundTransparency = 0.25,
		Visible = false,
		Parent = root,
	})
	Theme.round().Parent = poiRing
	local poiStroke = Theme.stroke(C.cheese, 3)
	poiStroke.Parent = poiRing
	local poiRadial = Theme.radial(poiRing, C.cheese, 0.25)
	local poiPct = Theme.label({
		Size = UDim2.fromScale(1, 1),
		TextSize = Z.poiText,
		Text = "",
		ZIndex = 5,
		Parent = poiRing,
	})
	Theme.textStroke().Parent = poiPct
	local poiName = Theme.label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 2),
		Size = UDim2.fromOffset(220, Z.poiNameH),
		TextSize = Z.poiNameText,
		TextWrapped = false,
		Text = "",
		Parent = poiRing,
	})
	Theme.textStroke().Parent = poiName

	local buffList = make("Frame", {
		Name = "Buffs",
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -Z.margin, 0, killTop + Z.killRows * (Z.killH + Z.killGap) + 6),
		Size = UDim2.fromOffset(Z.buffW, 4 * (Z.buffH + 4)),
		Parent = root,
	})
	Theme.list(Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Right).Parent = buffList
	local buffLabels: { [string]: TextLabel } = {}

	local bannerUntil = 0
	local function showBanner(text: string, color: Color3)
		banner.Text = text
		banner.TextColor3 = color
		banner.Visible = true
		bannerUntil = os.clock() + Z.bannerSeconds
		pcall(Theme.popIn, banner)
	end

	local function onPoiFx(batch: any)
		if type(batch) ~= "table" then
			return
		end
		for _, ev in batch do
			if type(ev) ~= "table" then
				continue
			end
			local t = ev.t
			if t == "poi" then
				local id = tonumber(ev.id)
				if id then
					local old = poiState[id]
					local p = tonumber(ev.p) or (if old and old.kind == ev.kind then old.p else 0)
					poiState[id] = {
						kind = tostring(ev.kind),
						x = tonumber(ev.x) or 0,
						z = tonumber(ev.z) or 0,
						r = tonumber(ev.r) or 6,
						state = tostring(ev.state or "idle"),
						active = ev.active == true,
						p = p,
					}
				end
			elseif t == "poiProgress" then
				local e = poiState[tonumber(ev.id) or -1]
				if e then
					e.p = tonumber(ev.p) or e.p
				end
			elseif t == "poiDone" then
				local e = poiState[tonumber(ev.id) or -1]
				if e then
					e.state, e.p = "done", 1
				end
				local def = poiDef(ev.kind)
				local untilT = tonumber(ev.untilT)
				if def and def.buff and untilT then
					buffs[tostring(ev.kind)] = untilT
				end
			elseif t == "protect" and tonumber(ev.id) == State.localUserId() then
				-- Spawn protection (drop-in / revive): a shield timer in the buff list.
				local untilT = tonumber(ev.untilT)
				if untilT then
					buffs.protect = untilT
				end
			elseif t == "bagProgress" and tonumber(ev.by) == State.localUserId() then
				bagChannel = { p = math.clamp(tonumber(ev.p) or 0, 0, 1), at = os.clock() }
			elseif t == "bagGone" then
				bagChannel = nil
			elseif t == "discovered" and ev.isNew == true then
				local def = poiDef(ev.kind)
				if def then
					showBanner("Discovered: " .. tostring(def.name) .. "!", defColor(def))
				end
			end
		end
	end
	local fxConn = Remotes.on(Remotes.S2C.Fx, onPoiFx)
	table.insert(unsubs, function()
		fxConn.Disconnect()
	end)

	-- Bounty banner when someone (maybe you) starts a streak.
	local lastBountySeq = 0
	local function onKillFeed(kf: any)
		if type(kf) ~= "table" or type(kf.entries) ~= "table" then
			return
		end
		for _, e in kf.entries do
			if e.seq > lastBountySeq then
				lastBountySeq = e.seq
				if e.newBounty then
					local mine = tostring(State.localUserId()) == e.newBounty
					showBanner(
						if mine
							then "You have a BOUNTY! Everyone can see you."
							else "BOUNTY on " .. State.nameOf(e.newBounty) .. ": +100 cheese",
						C.red
					)
				elseif e.kind == "lastHerd" then
					showBanner("LAST HERD STANDING! +50% pot", C.gold)
				end
			end
		end
		bountyBadge.Visible = State.hasBounty(State.localUserId())
	end
	table.insert(unsubs, State.subscribe("killfeed", onKillFeed, true))
	table.insert(
		unsubs,
		State.subscribe("match", function(m)
			renderStrip(m)
			renderRun(State.get("run"))
			bountyBadge.Visible = State.hasBounty(State.localUserId())
		end, true)
	)

	-- v3 champion squad buffs (Match.buffs: champ_might#1/#2, champ_swift#1/#2):
	-- one small timed chip per buff with its stack count and a tooltip.
	type ChampChip = { frame: Frame, label: TextLabel, chip: any }
	local champChips: { [string]: ChampChip } = {}
	local champAcc = 0
	local function renderChampBuffs(now: number)
		local clock = os.clock()
		if clock < champAcc then
			return
		end
		champAcc = clock + 0.25
		local match = State.get("match")
		local list = ChampView.buffChips(if type(match) == "table" then match.buffs else nil, now)
		local seen: { [string]: boolean } = {}
		for _, c in list do
			seen[c.base] = true
			local cc = champChips[c.base]
			if not cc then
				local f = make("Frame", {
					Name = "Champ_" .. c.base,
					LayoutOrder = -1,
					Size = UDim2.fromOffset(math.floor(Z.buffW * 0.72), Z.buffH),
					BackgroundColor3 = C.rind,
					BackgroundTransparency = 0.25,
					Parent = buffList,
				}) :: Frame
				Theme.corner(math.floor(Z.buffH / 2)).Parent = f
				Theme.stroke(C.gold, 1.5).Parent = f
				Theme.padding(6, 0).Parent = f
				local l = Theme.label({
					Size = UDim2.fromScale(1, 1),
					TextSize = Z.buffText,
					TextWrapped = false,
					TextXAlignment = Enum.TextXAlignment.Right,
					TextColor3 = C.goldLight,
					Text = "",
					Parent = f,
				})
				Theme.textStroke().Parent = l
				local entry: ChampChip = { frame = f, label = l, chip = c }
				Theme.tooltip(f, function()
					local maxStacks = if Defs.module("Champions")
						then Defs.module("Champions").BUFF_STACKS
						else 2
					return ChampView.buffTooltip(Defs.module("Champions"), entry.chip, maxStacks)
				end)
				champChips[c.base] = entry
				cc = entry
			end
			local e = cc :: ChampChip
			e.chip = c
			e.label.Text = string.format(
				"%s %s%s %s",
				ChampView.BUFF_ICON[c.base] or "👑",
				ChampView.BUFF_SHORT[c.base] or c.base,
				if c.stacks > 1 then " ×" .. c.stacks else "",
				Format.clock(c.left)
			)
		end
		for base, cc in champChips do
			if not seen[base] then
				cc.frame:Destroy()
				champChips[base] = nil
			end
		end
	end

	local function renderBuffs(now: number)
		renderChampBuffs(now)
		for kind, untilT in buffs do
			local left = untilT - now
			local lbl = buffLabels[kind]
			if left <= 0 then
				buffs[kind] = nil
				if lbl then
					lbl:Destroy()
					buffLabels[kind] = nil
				end
				continue
			end
			if not lbl then
				local def = poiDef(kind)
				local l = Theme.label({
					Size = UDim2.fromOffset(Z.buffW, Z.buffH),
					TextSize = Z.buffText,
					TextWrapped = false,
					TextXAlignment = Enum.TextXAlignment.Right,
					TextColor3 = defColor(def),
					Parent = buffList,
				})
				Theme.textStroke().Parent = l
				if def then
					Theme.tooltip(l, tostring(def.description))
				end
				buffLabels[kind] = l
				lbl = l
			end
			local def = poiDef(kind)
			local name = if kind == "protect"
				then "Spawn protection"
				elseif def then tostring(def.name):gsub("^Shrine of ", "")
				else kind;
			(lbl :: TextLabel).Text = string.format(
				"%s %s %s",
				BUFF_ICONS[kind] or (if kind == "protect" then "🛡" else "✨"),
				name,
				Format.clock(left)
			)
		end
	end

	local poiHintSent = false
	local function poiHint()
		poiHintSent = true
		local ok, Onboarding = pcall(require, script.Parent:FindFirstChild("Onboarding") :: any)
		if ok and type(Onboarding) == "table" and type(Onboarding.poiSeen) == "function" then
			pcall(Onboarding.poiSeen)
		end
	end

	local function renderPoiRing()
		local lp = Players.LocalPlayer
		local char = lp and lp.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local best, bestP = nil, -1
		if hrp and hrp:IsA("BasePart") then
			local pos = hrp.Position
			if not poiHintSent then
				for _, e in poiState do
					if
						e.active
						and e.state ~= "done"
						and (pos.X - e.x) ^ 2 + (pos.Z - e.z) ^ 2 <= (e.r + 30) ^ 2
					then
						poiHint()
						break
					end
				end
			end
			for _, e in poiState do
				if e.active and e.state ~= "done" and e.p > 0 then
					local d2 = (pos.X - e.x) ^ 2 + (pos.Z - e.z) ^ 2
					if d2 <= (e.r + 1) ^ 2 and e.p > bestP then
						best, bestP = e, e.p
					end
				end
			end
		end
		local bc = bagChannel
		if bc and os.clock() - bc.at < 2.5 then
			poiRing.Visible = true
			poiStroke.Color = C.gold
			poiRadial.set(bc.p)
			poiPct.Text = string.format("%d%%", math.floor(bc.p * 100 + 0.5))
			poiName.Text = "Looting bag…"
			return
		end
		bagChannel = nil
		poiRing.Visible = best ~= nil
		if best then
			local def = poiDef(best.kind)
			local col = defColor(def)
			poiStroke.Color = col
			poiRadial.set(math.clamp(best.p, 0, 1))
			poiPct.Text = string.format("%d%%", math.floor(best.p * 100 + 0.5))
			poiName.Text = if def then tostring(def.name) else best.kind
		end
	end

	local function resetPois(run: any)
		local phase = if type(run) == "table" then run.phase else nil
		if phase ~= "Waves" and phase ~= "Boss" and phase ~= "StageClear" then
			table.clear(poiState)
		end
		if phase == nil or phase == "Lobby" or phase == "Results" then
			table.clear(buffs)
			for k, l in buffLabels do
				l:Destroy()
				buffLabels[k] = nil
			end
			for k, cc in champChips do
				cc.frame:Destroy()
				champChips[k] = nil
			end
		end
	end

	table.insert(unsubs, State.subscribe("run", resetPois))
	table.insert(unsubs, State.subscribe("run", renderRun, true))
	table.insert(unsubs, State.subscribe("hud", renderHud, true))
	table.insert(unsubs, State.subscribe("party", renderSquad, true))
	table.insert(unsubs, State.subscribe("boss", renderBoss, true))
	table.insert(unsubs, State.subscribe("lobby", abilityTooltip, true))
	table.insert(unsubs, State.subscribe("profile", abilityTooltip))
	table.insert(
		unsubs,
		State.subscribe("hud", function(hud: any)
			-- the server's slot list (iteration 5) may change the tiles mid-run
			local ids = AbilitySlots.hudIds(hud)
			local sig = tostring(AbilitySlots.hudCount(hud))
			for i = 1, AbilitySlots.MAX do
				sig ..= ":" .. tostring(ids[i])
			end
			if sig ~= lastSlotSig then
				lastSlotSig = sig
				abilityTooltip()
			end
		end)
	)

	-- Per-frame: timers and cooldown radial.
	renderConn = RunService.RenderStepped:Connect(function()
		local run = State.get("run")
		if type(run) ~= "table" or run.phase == nil or run.phase == "Lobby" then
			bottomRow.Visible = false
			poiRing.Visible = false
			banner.Visible = false
			return
		end
		local now = State.serverNow()
		renderPoiRing()
		renderBuffs(now)
		if banner.Visible and os.clock() >= bannerUntil then
			banner.Visible = false
		end
		local match = State.get("match")
		local phase = if type(match) == "table" and match.phase then match.phase else run.phase
		local phaseText = PHASE_TEXT[phase] or PHASE_TEXT[run.phase] or tostring(phase)
		-- iteration 2: numbered waves ("Wave 7 / 20", every 5th a boss wave)
		local wv = LadderModel.wave(match, run)
		if wv and (run.phase == "Waves" or run.phase == "Boss") then
			phaseText = string.format("Wave %d / %d", wv.wave, wv.waves)
				.. (if wv.boss then " · BOSS" else "")
		end
		-- iteration 6: a Fast-pace match says so next to the wave
		if LadderModel.isFast(match, run) then
			phaseText ..= " · ⚡ Fast"
		end
		local endsAt = tonumber(run.phaseEndsAt)
		if endsAt and endsAt > now then
			phaseRow.Text = phaseText .. "  ⏱ " .. Format.clock(endsAt - now)
		else
			phaseRow.Text = phaseText
		end
		phaseRow.TextColor3 = if run.phase == "Boss" then C.red else C.cream
		-- v4 phone diet (review B S2-6): no phase row during Waves on phones;
		-- the storm pill under the minimap carries the timer there.
		phaseRow.Visible = dense or run.phase ~= "Waves" or wv ~= nil

		local inCombat = run.phase == "Waves" or run.phase == "Boss" or run.phase == "StageClear"
		-- iteration 1 #19: phones hide the gear row while the upgrade strip is up
		bottomRow.Visible = run.phase ~= "Results"
			and not (Device.hasTouch() and State.get("upgradeShown") == true)
		local showTiles = inCombat and not Device.hasTouch()
		for _, t in tiles do
			t.frame.Visible = showTiles and t.slot <= liveSlots
			if t.frame.Visible then
				local rem, total = State.abilityCooldown(t.slot)
				t.radial.set(if rem > 0 then rem / total else 0)
				t.text.Text = if rem > 0 then tostring(math.ceil(rem)) else ""
				t.icon.Visible = rem <= 0
			end
		end

		if downed.Visible then
			local hud = State.get("hud")
			local untilT = if type(hud) == "table" then tonumber(hud.downedUntil) else nil
			if untilT and untilT > now then
				downTitle.Text = "You're down! " .. Format.clock(untilT - now)
			else
				downTitle.Text = "You're down!"
			end
		end
	end)
end

function HudUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	for _, p in parts do
		pcall(p.destroy)
	end
	table.clear(parts)
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	if screen then
		screen.destroy()
		screen = nil
	end
end

return HudUI
