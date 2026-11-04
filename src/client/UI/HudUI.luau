--!strict
-- In-run HUD v2 (squad PvPvE, docs/GDD-v2.md). One ScreenGui:
--
--   top-left      own status card (level badge, class, HP with a damage trail,
--                 XP, Second Winds, bounty warning) and the squad panel (your
--                 2 mates: class, HP, down / out, in squad colours; v1: party)
--   top-centre    scoreboard strip (4 squads: colour, name, alive pips,
--                 pending cheese, kills, Extracted / Eliminated badges; tap or
--                 Tab for the full board), stage + map, phase timer, the
--                 Double or Nothing badge, curse / blessing chips, boss bar
--   top-right     minimap (UI/MinimapUI) and kill feed (UI/KillFeedUI)
--   bottom-centre gear slots + swap prompt (UI/GearUI) and the ability
--                 cooldown radial (PC / gamepad; touch uses InputController's button)
--   centre        downed overlay, POI progress ring, discovery / bounty banner
--
-- Reads State: run, hud, party, boss, match, killfeed, inventory, profile, lobby.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local MinimapUI = require(script.Parent.MinimapUI)
local KillFeedUI = require(script.Parent.KillFeedUI)
local GearUI = require(script.Parent.GearUI)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local Device = require(Client.Util.Device)
local State = require(Client.Controllers.State)
local Remotes = require(Client.Util.Remotes)

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

	------------------------------------------------------------------
	-- Own status card (top-left)
	------------------------------------------------------------------
	local status = Theme.card({
		Name = "Status",
		Position = UDim2.fromOffset(14, 10),
		Size = UDim2.fromOffset(330, 100),
		Parent = root,
	})
	local levelBadge = make("Frame", {
		Position = UDim2.fromOffset(10, 14),
		Size = UDim2.fromOffset(62, 62),
		BackgroundColor3 = C.cheese,
		Parent = status,
	})
	Theme.round().Parent = levelBadge
	Theme.gloss(levelBadge, 1, 0.75)
	Theme.stroke(C.brownDark, 3).Parent = levelBadge
	Theme.label({
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 14),
		TextSize = T.micro,
		TextColor3 = C.brownDark,
		Text = "LEVEL",
		Parent = levelBadge,
	})
	local levelText = Theme.label({
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, 36),
		TextSize = 30,
		TextColor3 = C.ink,
		Text = "1",
		Parent = levelBadge,
	})
	local classLine = Theme.label({
		Position = UDim2.fromOffset(84, 6),
		Size = UDim2.fromOffset(236, 18),
		TextSize = T.caption,
		TextColor3 = C.gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Text = "",
		Parent = status,
	})
	Theme.textStroke(C.shade, 1).Parent = classLine
	local hpBar = Theme.bar(
		{ Position = UDim2.fromOffset(84, 26), Size = UDim2.fromOffset(236, 26), Parent = status },
		C.hp,
		{ trail = true }
	)
	local xpBar = Theme.bar(
		{ Position = UDim2.fromOffset(84, 56), Size = UDim2.fromOffset(236, 14), Parent = status },
		C.xp
	)
	xpBar.text.TextSize = T.micro
	local windRow = make("Frame", {
		Position = UDim2.fromOffset(84, 74),
		Size = UDim2.fromOffset(236, 20),
		BackgroundTransparency = 1,
		Parent = status,
	})
	Theme.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent =
		windRow
	Theme.icon("heart", 16, C.hp, { LayoutOrder = 1, Parent = windRow })
	local windLabel = Theme.label({
		LayoutOrder = 2,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 20),
		TextSize = T.caption,
		TextWrapped = false,
		Text = "",
		Parent = windRow,
	})
	Theme.textStroke(C.shade, 1).Parent = windLabel
	Theme.tooltip(windLabel, "Second Wind: get back up by yourself while downed (max 1 per stage).")
	local bountyBadge =
		Theme.badge("🎯 BOUNTY ON YOU", C.red, { LayoutOrder = 3, Visible = false, Parent = windRow })
	Theme.tooltip(
		bountyBadge,
		"You're on a 3-down streak: you show on everyone's minimap, and whoever downs you earns +100 cheese."
	)

	------------------------------------------------------------------
	-- Squad panel (under the status card): your 2 mates (v1: the party)
	------------------------------------------------------------------
	local squadPanel = Theme.card({
		Name = "Squad",
		Position = UDim2.fromOffset(14, 120),
		Size = UDim2.fromOffset(270, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = root,
	})
	Theme.padding(8, 8).Parent = squadPanel
	Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = squadPanel
	local squadTitle = Theme.label({
		LayoutOrder = 0,
		Size = UDim2.new(1, 0, 0, 18),
		TextSize = T.caption,
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
			Size = UDim2.new(1, 0, 0, 50),
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
			Position = UDim2.fromOffset(10, 9),
			Size = UDim2.fromOffset(32, 32),
			BackgroundColor3 = C.rind,
			Parent = frame,
		}) :: Frame
		Theme.round().Parent = iconBox
		local icon = Theme.icon("hero", 24, C.cream, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Parent = iconBox,
		})
		local name = Theme.label({
			Position = UDim2.fromOffset(50, 3),
			Size = UDim2.new(1, -120, 0, 18),
			TextSize = T.caption + 1,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Parent = frame,
		})
		Theme.textStroke(C.shade, 1).Parent = name
		local sub = Theme.label({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 4),
			Size = UDim2.fromOffset(70, 16),
			TextSize = T.micro,
			Font = Theme.FONT_BODY,
			TextColor3 = C.textDim,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextWrapped = false,
			Parent = frame,
		})
		local bar = Theme.bar(
			{ Position = UDim2.fromOffset(50, 26), Size = UDim2.new(1, -60, 0, 16), Parent = frame },
			C.hp,
			{ trail = true }
		)
		bar.text.TextSize = T.micro
		local tag = Theme.label({
			Position = UDim2.fromOffset(50, 26),
			Size = UDim2.new(1, -60, 0, 16),
			TextSize = T.caption,
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
			r.name.Text = (if bot then "🤖 " else "")
				.. (if type(e) == "table" and e.name then tostring(e.name) else State.nameOf(id))
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
					r.tag.Text = "DOWN! Revive them"
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
	local HEADER_W = 560
	local header = make("Frame", {
		Name = "Header",
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.fromOffset(HEADER_W, 300),
		Parent = root,
	})
	Theme.list(Enum.FillDirection.Vertical, 4).Parent = header

	-- Scoreboard strip: 4 squad tiles.
	local TILE_W, TILE_H = 128, 56
	local strip = make("TextButton", {
		Name = "Scoreboard",
		LayoutOrder = 0,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromOffset(4 * TILE_W + 3 * 6, TILE_H),
		Visible = false,
		Selectable = false,
		Parent = header,
	}) :: TextButton
	Theme.list(
		Enum.FillDirection.Horizontal,
		6,
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
			Size = UDim2.new(1, 0, 0, 6),
			BackgroundColor3 = C.cheese,
			BorderSizePixel = 0,
			Parent = f,
		}) :: Frame
		Theme.corner(6).Parent = band
		local name = Theme.label({
			Position = UDim2.fromOffset(8, 8),
			Size = UDim2.new(1, -46, 0, 18),
			TextSize = T.caption,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Parent = f,
		})
		Theme.textStroke(C.shade, 1).Parent = name
		local pips: { Frame } = {}
		for p = 1, 3 do
			local pip = make("Frame", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -6 - (3 - p) * 11, 0, 12),
				Size = UDim2.fromOffset(8, 8),
				BackgroundColor3 = C.green,
				Parent = f,
			}) :: Frame
			Theme.round().Parent = pip
			Theme.stroke(C.shade, 1).Parent = pip
			pips[p] = pip
		end
		local row = make("Frame", {
			Position = UDim2.fromOffset(6, 30),
			Size = UDim2.new(1, -12, 0, 20),
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
		Theme.icon("cheese", 16, C.cheese, { LayoutOrder = 1, Parent = row })
		local pending = Theme.label({
			LayoutOrder = 2,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 18),
			TextSize = T.caption,
			TextWrapped = false,
			Parent = row,
		})
		Theme.textStroke(C.shade, 1).Parent = pending
		Theme.icon("skull", 14, C.cream, { LayoutOrder = 3, Parent = row })
		local kills = Theme.label({
			LayoutOrder = 4,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 18),
			TextSize = T.caption,
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
			Position = UDim2.fromScale(0.5, 0.62),
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
					tile.badge.Text = "×1.5 DOUBLE OR NOTHING"
					tile.badge.BackgroundColor3 = C.orange
				end
			end
		end
	end

	local titleRow = Theme.label({
		LayoutOrder = 1,
		Size = UDim2.fromOffset(HEADER_W, 28),
		TextSize = T.heading + 2,
		TextColor3 = C.cheese,
		Parent = header,
	})
	Theme.textStroke(C.brownDark, 2.5).Parent = titleRow
	local phaseRow = Theme.label({
		LayoutOrder = 2,
		Size = UDim2.fromOffset(HEADER_W, 24),
		TextSize = T.heading - 2,
		Parent = header,
	})
	Theme.textStroke().Parent = phaseRow
	local cheeseRow = make("Frame", {
		LayoutOrder = 3,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(HEADER_W, 32),
		Parent = header,
	})
	Theme.list(
		Enum.FillDirection.Horizontal,
		8,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	).Parent =
		cheeseRow
	Theme.icon("cheese", 24, C.cheese, { LayoutOrder = 0, Parent = cheeseRow })
	local cheeseLabel = Theme.label({
		LayoutOrder = 1,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 30),
		TextSize = T.heading - 2,
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
		"Next stage rewards ×2 and the pending pot ×1.5 if you win. Wipe = lose ALL pending cheese."
	)
	donBadge.LayoutOrder = 2
	donBadge.Visible = false
	donBadge.Parent = cheeseRow
	local chipsRow = make("Frame", {
		LayoutOrder = 4,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(HEADER_W, 36),
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
		Size = UDim2.fromOffset(520, 58),
		Visible = false,
		Parent = header,
	})
	local bossName = Theme.label({
		Position = UDim2.fromOffset(28, 0),
		Size = UDim2.new(1, -56, 0, 26),
		TextSize = T.heading + 2,
		TextColor3 = C.cheese,
		Parent = bossFrame,
	})
	Theme.textStroke(C.brownDark, 2.5).Parent = bossName
	Theme.icon("crown", 24, C.red, { Position = UDim2.fromOffset(0, 0), Parent = bossFrame })
	local bossBar = Theme.bar(
		{ Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, 0, 0, 24), Parent = bossFrame },
		C.red,
		{ trail = true }
	)

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
			donBadge.Text = "×1.5 DOUBLE OR NOTHING"
		else
			cheeseLabel.Text = string.format(
				"%s pending  ·  %s banked",
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
	local MAP_SIZE = 150
	table.insert(parts, MinimapUI.build(root, MAP_SIZE))
	table.insert(parts, KillFeedUI.build(root, MAP_SIZE + 22))

	------------------------------------------------------------------
	-- Bottom row: gear slots + ability (bottom-centre)
	------------------------------------------------------------------
	local touch = Theme.TOUCH
	local bottomRow = make("Frame", {
		Name = "BottomRow",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(560, math.max(96, touch)),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = root,
	}) :: Frame
	Theme.list(
		Enum.FillDirection.Horizontal,
		10,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Bottom
	).Parent =
		bottomRow
	table.insert(parts, GearUI.build(bottomRow, root))

	local ability = make("Frame", {
		Name = "Ability",
		LayoutOrder = 10,
		Size = UDim2.fromOffset(96, 96),
		BackgroundColor3 = C.cheese,
		Parent = bottomRow,
	})
	Theme.round().Parent = ability
	Theme.gloss(ability, 1, 0.72)
	Theme.goldStroke(4).Parent = ability
	local abilityRadial = Theme.radial(ability, C.shade, 0.4)
	local abilityText = Theme.label({
		Size = UDim2.fromScale(1, 1),
		TextSize = 34,
		Text = "",
		ZIndex = 5,
		Parent = ability,
	})
	Theme.textStroke().Parent = abilityText
	local abilityIcon = Theme.icon("bolt", 44, C.brownDark, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		ZIndex = 4,
		Parent = ability,
	})
	local abilityHint = Theme.label({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -4),
		Size = UDim2.fromOffset(240, 20),
		TextSize = T.caption,
		Parent = ability,
	})
	Theme.textStroke().Parent = abilityHint
	local abilityName = "Ability"
	local function renderAbilityHint()
		local mode = Device.mode()
		abilityHint.Text = abilityName
			.. (if mode == "gamepad" then " [X]" elseif mode == "touch" then "" else " [Space / Q / RMB]")
	end
	local modeConn = Device.modeChanged:Connect(renderAbilityHint)
	table.insert(unsubs, function()
		modeConn:Disconnect()
	end)
	local function abilityTooltip()
		local profile = State.get("profile")
		local lobby = State.get("lobby")
		local me = State.localUserId()
		local classId = if type(lobby) == "table"
				and lobby.players
				and lobby.players[me]
			then lobby.players[me].classId
			elseif type(profile) == "table" then profile.selectedClass
			else nil
		local def = Defs.get("Classes", classId)
		abilityName = if def and def.ability then tostring(def.ability.name or "Ability") else "Ability"
		-- v2: the chosen alternate ability (Config/ClassAbilities).
		if classId then
			local st = State.classState(tostring(classId))
			local entry = if st.ability then Defs.get("ClassAbilities", st.ability) else nil
			local ad = entry and (entry.def or entry)
			if ad and ad.name then
				abilityName = tostring(ad.name)
			end
			if def then
				classLine.Text = string.upper(Defs.name(def, classId)) .. " · " .. abilityName
			end
		end
		renderAbilityHint()
	end

	------------------------------------------------------------------
	-- Downed overlay (centre)
	------------------------------------------------------------------
	local downedFull = 82 + touch + 12
	local downed = Theme.card({
		Name = "Downed",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.6),
		Size = UDim2.fromOffset(420, downedFull),
		BackgroundColor3 = Color3.fromRGB(110, 28, 22),
		BackgroundTransparency = 0.1,
		Visible = false,
		Parent = root,
	}, { accent = C.red, stroke = 3 })
	local downTitle = Theme.label({
		Position = UDim2.fromOffset(0, 8),
		Size = UDim2.new(1, 0, 0, 36),
		TextSize = T.title,
		Text = "You're down!",
		Parent = downed,
	})
	Theme.textStroke().Parent = downTitle
	local downSub = Theme.label({
		Position = UDim2.fromOffset(10, 44),
		Size = UDim2.new(1, -20, 0, 26),
		TextSize = T.body,
		Font = Theme.FONT_BODY,
		Text = "A squadmate can revive you by standing close.",
		Parent = downed,
	})
	local windButton = Theme.button("Second Wind [E]", C.cheese, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.fromOffset(300, touch),
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
		xpBar.set(xp / toNext, string.format("XP %d / %d", math.floor(xp), math.floor(toNext)))
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
		downed.Size = UDim2.fromOffset(420, if canWind then downedFull else 90)
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
		Position = UDim2.new(0.5, 0, 1, -(math.max(96, touch) + 60)),
		Size = UDim2.fromOffset(64, 64),
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
		TextSize = 18,
		Text = "",
		ZIndex = 5,
		Parent = poiRing,
	})
	Theme.textStroke().Parent = poiPct
	local poiName = Theme.label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 2),
		Size = UDim2.fromOffset(220, 22),
		TextSize = 16,
		Text = "",
		Parent = poiRing,
	})
	Theme.textStroke().Parent = poiName

	local buffList = make("Frame", {
		Name = "Buffs",
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -14, 0, MAP_SIZE + 22 + 5 * 32 + 6),
		Size = UDim2.fromOffset(220, 120),
		Parent = root,
	})
	Theme.list(Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Right).Parent = buffList
	local buffLabels: { [string]: TextLabel } = {}

	local banner = Theme.label({
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 250),
		Size = UDim2.fromOffset(620, 44),
		TextSize = 34,
		TextColor3 = C.cheese,
		Text = "",
		Visible = false,
		Parent = root,
	})
	Theme.textStroke(C.brownDark, 3).Parent = banner
	local bannerUntil = 0
	local function showBanner(text: string, color: Color3)
		banner.Text = text
		banner.TextColor3 = color
		banner.Visible = true
		bannerUntil = os.clock() + 4
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

	local function renderBuffs(now: number)
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
					Size = UDim2.fromOffset(220, 24),
					TextSize = 18,
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
			local name = if def then tostring(def.name):gsub("^Shrine of ", "") else kind;
			(lbl :: TextLabel).Text =
				string.format("%s %s %s", BUFF_ICONS[kind] or "✨", name, Format.clock(left))
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
		end
	end

	table.insert(unsubs, State.subscribe("run", resetPois))
	table.insert(unsubs, State.subscribe("run", renderRun, true))
	table.insert(unsubs, State.subscribe("hud", renderHud, true))
	table.insert(unsubs, State.subscribe("party", renderSquad, true))
	table.insert(unsubs, State.subscribe("boss", renderBoss, true))
	table.insert(unsubs, State.subscribe("lobby", abilityTooltip, true))
	table.insert(unsubs, State.subscribe("profile", abilityTooltip))

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
		local endsAt = tonumber(run.phaseEndsAt)
		if endsAt and endsAt > now then
			phaseRow.Text = phaseText .. "  ⏱ " .. Format.clock(endsAt - now)
		else
			phaseRow.Text = phaseText
		end
		phaseRow.TextColor3 = if run.phase == "Boss" then C.red else C.cream

		local inCombat = run.phase == "Waves" or run.phase == "Boss" or run.phase == "StageClear"
		bottomRow.Visible = run.phase ~= "Results"
		ability.Visible = inCombat and not Device.hasTouch()
		if ability.Visible then
			local rem, total = State.abilityCooldown()
			abilityRadial.set(if rem > 0 then rem / total else 0)
			abilityText.Text = if rem > 0 then tostring(math.ceil(rem)) else ""
			abilityIcon.Visible = rem <= 0
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
