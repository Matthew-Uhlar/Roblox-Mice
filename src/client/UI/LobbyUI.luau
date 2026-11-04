--!strict
-- Lobby (run phase nil or "Lobby"). Kept compact so a new player can ready
-- up in seconds: a bottom bar (class, bot teammates toggle, shop, READY), a
-- party list with ready states and 🤖 bot tags, a big countdown (auto-start
-- or ready countdown, plus how many bots will join), and an on-demand class
-- picker (7 classes, locked ones show cost + Buy).
--
-- Pressure (GDD §3.7): a summary card (top-left) opens an 8-row board with
-- − / + per modifier, the points total and the reward preview. Only the
-- party leader (👑, first to READY) can edit it, and only once their
-- Pressure is unlocked (first Go Home win); everyone else sees it read-only.
--
-- Reads State "lobby": players (sittingOut / needsReady / leader per entry),
-- startsAt, runActive, autoStart, botFill (own toggle), botFillAny (bots come
-- at all), botCount (bots on the pad), pressure {board, points, leaderId,
-- unlocked, youUnlocked}.
-- Sends: SelectClass(classId), SetReady(bool), SetBotFill(bool),
--        BuyShopItem("class:<id>"), SetPressure(modId, rank).
--
-- v2 (GDD-v2 §1, §5): the party list becomes a squads view (4 squad pads x 3
-- seats from State lobby.squads, bots tagged 🤖, empty seats say a bot fills
-- them at start). The class picker shows each class's level, XP bar and
-- mastery badge, an ability selector (base + 2 alternates, locked until class
-- levels 5 / 15) and a skin selector, and opens the Perk Tree (UI/PerkTreeUI).
-- Sends: SelectAbility(classId, abilityId?), SelectSkin(classId, skinId?).

local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Remotes = require(Client.Util.Remotes)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local State = require(Client.Controllers.State)
local ClassInfo = require(script.Parent.ClassInfo)
local PerkTreeUI = require(script.Parent.PerkTreeUI)
local PressureMath = require(
	game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Run"):WaitForChild("Pressure")
) :: any

local LobbyUI = {}

local C = Theme.C
local make = Theme.make

local WEAPON_TEXT: { [string]: string } = {
	melee_arc = "Melee arc",
	bolt = "Piercing bolt",
	spread = "Spread shot",
	cone = "Cone thrust",
	orbit = "Orbiting blades",
	lob = "Lobbed bomb",
	puddle = "Puddle",
}

local screen: any = nil
local unsubs: { () -> () } = {}
local renderConn: RBXScriptConnection? = nil

-- Local, optimistic UI state.
local readyLocal: boolean? = nil
local readyLocalAt = 0
local botFill = true -- default On (server is told on toggle)
local previewId: string? = nil
-- Optimistic Pressure edits (the server's board wins once it matches or after 2 s).
local localBoard: { [string]: number }? = nil
local localBoardAt = 0

local function myEntry(): any
	local lobby = State.get("lobby")
	if type(lobby) == "table" and type(lobby.players) == "table" then
		return lobby.players[State.localUserId()]
	end
	return nil
end

local function selectedClassId(): string
	local e = myEntry()
	if e and e.classId then
		return tostring(e.classId)
	end
	local profile = State.get("profile")
	if type(profile) == "table" and profile.selectedClass then
		return tostring(profile.selectedClass)
	end
	local mod = Defs.module("Classes")
	return if mod and mod.DEFAULT_ID then tostring(mod.DEFAULT_ID) else "elephante"
end

local function isUnlocked(def: any): boolean
	if (tonumber(def.unlockCost) or 0) <= 0 then
		return true
	end
	local profile = State.get("profile")
	return type(profile) == "table"
		and type(profile.unlockedClasses) == "table"
		and profile.unlockedClasses[def.id] == true
end

local function cheese(): number
	local profile = State.get("profile")
	return if type(profile) == "table" then tonumber(profile.cheese) or 0 else 0
end

local function isReady(): boolean
	if readyLocal ~= nil and os.clock() - readyLocalAt < 2 then
		return readyLocal
	end
	local e = myEntry()
	return e ~= nil and e.ready == true
end

-- Bots that will join the next run: the server's botCount, else counted from
-- the player list. Returns (count, botsEnabledAtAll).
local function botInfo(lobby: any): (number, boolean)
	if type(lobby) ~= "table" then
		return 0, botFill
	end
	local count = tonumber(lobby.botCount)
	if count == nil then
		count = 0
		if type(lobby.players) == "table" then
			for id, e in lobby.players do
				if State.isBot(id, e) then
					count += 1
				end
			end
		end
	end
	local any = if type(lobby.botFillAny) == "boolean" then lobby.botFillAny else botFill
	return math.max(0, math.floor(count or 0)), any
end

-- Countdown kind: the server says whether it is the idle auto-start; older
-- servers did not, so fall back to "nobody human is ready".
local function isAutoStart(lobby: any): boolean
	if type(lobby.autoStart) == "boolean" then
		return lobby.autoStart
	end
	for id, e in lobby.players or {} do
		if not State.isBot(id, e) and e.ready == true and e.inRun ~= true then
			return false
		end
	end
	return true
end

local function lobbyPressure(): any
	local lobby = State.get("lobby")
	if type(lobby) == "table" and type(lobby.pressure) == "table" then
		return lobby.pressure
	end
	return State.normalisePressure(nil)
end

local function sameBoard(a: { [string]: number }, b: { [string]: number }): boolean
	for k, v in a do
		if b[k] ~= v then
			return false
		end
	end
	for k, v in b do
		if a[k] ~= v then
			return false
		end
	end
	return true
end

-- The board to show: an optimistic local edit for up to 2 s, else the server's.
local function shownBoard(): { [string]: number }
	local server = lobbyPressure().board or {}
	local lb = localBoard
	if lb and os.clock() - localBoardAt < 2 and not sameBoard(lb, server) then
		return lb
	end
	localBoard = nil
	return server
end

local function leaderName(): string?
	local pr = lobbyPressure()
	local lobby = State.get("lobby")
	local id = pr.leaderId
	if id == nil or type(lobby) ~= "table" or type(lobby.players) ~= "table" then
		return nil
	end
	local e = lobby.players[id]
	return if type(e) == "table" and e.name then tostring(e.name) else "Player"
end

-- Can I edit the board right now?
local function canEditPressure(): boolean
	local e = myEntry()
	return State.isLeader() and lobbyPressure().unlocked == true and not (e and e.inRun == true)
end

function LobbyUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallLobby", 20)
	local root: Frame = screen.root

	------------------------------------------------------------------
	-- Countdown (top-centre)
	------------------------------------------------------------------
	-- Width leaves room for the party panel on the right (300 + margins).
	local countdown = Theme.label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 14),
		Size = UDim2.fromOffset(620, 50),
		TextSize = 38,
		TextScaled = true,
		TextWrapped = false,
		TextColor3 = C.cheese,
		Parent = root,
	})
	make("UITextSizeConstraint", { MaxTextSize = 38, MinTextSize = 18, Parent = countdown })
	Theme.textStroke(C.brownDark, 3).Parent = countdown
	local subtitle = Theme.label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 64),
		Size = UDim2.fromOffset(620, 52),
		TextSize = 20,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = root,
	})
	Theme.textStroke().Parent = subtitle
	table.insert(
		unsubs,
		screen.onResize(function(size: Vector2)
			local w = math.clamp(size.X - 2 * 330, 360, 620)
			countdown.Size = UDim2.fromOffset(w, 50)
			subtitle.Size = UDim2.fromOffset(w, 52)
		end)
	)

	------------------------------------------------------------------
	-- Squads view (top-right): 4 squad pads x 3 seats (v1: one party pad)
	------------------------------------------------------------------
	local touch0 = Theme.TOUCH
	local party = Theme.panel({
		Name = "Squads",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 14),
		Size = UDim2.fromOffset(300, 470),
		BackgroundTransparency = 0.05,
		Parent = root,
	})
	table.insert(unsubs, Theme.fitFrame(screen, party, 300, 470, 14, touch0 + 44))
	local partyTitle = Theme.label({
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -24, 0, 28),
		TextSize = 22,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Squads",
		Parent = party,
	})
	local padList = Theme.scroller({
		Position = UDim2.fromOffset(8, 36),
		Size = UDim2.new(1, -16, 1, -44),
		ScrollBarThickness = 6,
		Parent = party,
	})
	Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = padList

	type Seat = { frame: Frame, name: TextLabel, sub: TextLabel, mark: TextLabel }
	type Pad = { frame: Frame, band: Frame, title: TextLabel, count: TextLabel, seats: { Seat } }
	local pads: { Pad } = {}
	for i = 1, 4 do
		local f = make("Frame", {
			LayoutOrder = i,
			Size = UDim2.new(1, -6, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = C.creamDark,
			Parent = padList,
		}) :: Frame
		Theme.corner(10).Parent = f
		local stroke = Theme.stroke(C.brown, 2)
		stroke.Name = "PadStroke"
		stroke.Parent = f
		Theme.list(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Left).Parent = f
		Theme.padding(0, 0).Parent = f
		local band = make("Frame", {
			LayoutOrder = 0,
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundColor3 = C.cheese,
			Parent = f,
		}) :: Frame
		Theme.corner(10).Parent = band
		Theme.gloss(band, 1, 0.8)
		local title = Theme.label({
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.new(1, -70, 1, 0),
			TextSize = 18,
			TextColor3 = C.ink,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = band,
		})
		local count = Theme.label({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 0),
			Size = UDim2.fromOffset(60, 26),
			TextSize = 16,
			TextColor3 = C.ink,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = band,
		})
		local seats: { Seat } = {}
		for k = 1, 4 do
			local row = make("Frame", {
				LayoutOrder = k,
				Size = UDim2.new(1, 0, 0, 34),
				BackgroundTransparency = 1,
				Parent = f,
			}) :: Frame
			local name = Theme.label({
				Position = UDim2.fromOffset(10, 1),
				Size = UDim2.new(1, -50, 0, 18),
				TextSize = 15,
				TextColor3 = C.ink,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextWrapped = false,
				Parent = row,
			})
			local sub = Theme.label({
				Position = UDim2.fromOffset(10, 18),
				Size = UDim2.new(1, -50, 0, 14),
				TextSize = 12,
				Font = Theme.FONT_BODY,
				TextColor3 = C.brown,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextWrapped = false,
				Parent = row,
			})
			local mark = Theme.label({
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -8, 0.5, 0),
				Size = UDim2.fromOffset(36, 26),
				TextSize = 20,
				Parent = row,
			})
			seats[k] = { frame = row, name = name, sub = sub, mark = mark }
		end
		pads[i] = { frame = f, band = band, title = title, count = count, seats = seats }
	end

	local function fillSeat(seat: Seat, id: number?, e: any, me: number)
		seat.frame.Visible = true
		if id == nil then
			seat.name.Text = "Empty seat"
			seat.name.TextColor3 = C.grey
			seat.sub.Text = "🤖 a bot fills it at the start"
			seat.mark.Text = ""
			return
		end
		local bot = State.isBot(id, e)
		local entry = if type(e) == "table" then e else {}
		local classDef = Defs.get("Classes", entry.classId)
		local seatName = if entry.name then tostring(entry.name) else State.nameOf(id)
		seat.name.Text = (
			if bot
				then Format.botName(seatName)
				elseif entry.leader == true then "👑 " .. seatName
				else seatName
		) .. (if id == me then " (you)" else "")
		seat.name.TextColor3 = if id == me then C.goldDeep else C.ink
		local lvText = ""
		if id == me and entry.classId then
			lvText = " · Lv " .. tostring(ClassInfo.progress(tostring(entry.classId)).level)
		end
		seat.sub.Text = (if bot then "Bot · " else "")
			.. Defs.name(classDef, entry.classId)
			.. lvText
			.. (
				if entry.inRun == true
					then " · in a run"
					elseif entry.sittingOut == true then " · sitting out"
					elseif entry.needsReady == true then " · press READY"
					else ""
			)
		seat.mark.Text = if bot then "🤖" elseif entry.ready == true then "✔" else "…"
		seat.mark.TextColor3 = if entry.ready == true then C.green else C.grey
	end

	local function renderParty()
		local lobby = State.get("lobby")
		local players = if type(lobby) == "table" and type(lobby.players) == "table"
			then lobby.players
			else {}
		local me = State.localUserId()
		local humans, bots = 0, 0
		for id, e in players do
			if State.isBot(id, e) then
				bots += 1
			else
				humans += 1
			end
		end
		local squads = if type(lobby) == "table" then lobby.squads else nil
		if type(squads) == "table" then
			local mine = State.mySquad()
			for i, pad in pads do
				local sq = squads[i]
				pad.frame.Visible = sq ~= nil
				if sq then
					local col = Format.rgb(sq.color, C.cheese)
					pad.band.BackgroundColor3 = col
					pad.title.Text = sq.name .. (if i == mine then "  ★ your squad" else "")
					pad.title.TextColor3 = Theme.onColor(col)
					pad.count.TextColor3 = Theme.onColor(col)
					pad.count.Text = string.format("%d/3", math.min(#sq.members, 3))
					local st = pad.frame:FindFirstChild("PadStroke") :: UIStroke?
					if st then
						st.Color = if i == mine then C.goldDeep else C.brown
						st.Thickness = if i == mine then 3 else 2
					end
					for k, seat in pad.seats do
						if k > 3 then
							seat.frame.Visible = false
						else
							local id = sq.members[k]
							fillSeat(seat, id, if id then players[id] else nil, me)
						end
					end
				end
			end
			partyTitle.Text = if bots > 0
				then string.format("Squads (%d + %d 🤖)", humans, bots)
				else string.format("Squads (%d player%s)", humans, if humans == 1 then "" else "s")
		else
			-- v1 server: one party pad.
			local ids = {}
			for id in players do
				table.insert(ids, id)
			end
			table.sort(ids, function(a, b)
				local ba, bb = State.isBot(a, players[a]), State.isBot(b, players[b])
				if ba ~= bb then
					return not ba
				end
				if a == me or b == me then
					return a == me
				end
				return a < b
			end)
			for i, pad in pads do
				pad.frame.Visible = i == 1
			end
			local pad = pads[1]
			pad.band.BackgroundColor3 = C.cheese
			pad.title.Text = "Your party"
			pad.title.TextColor3 = C.ink
			pad.count.Text = tostring(#ids)
			for k, seat in pad.seats do
				local id = ids[k]
				if id then
					fillSeat(seat, id, players[id], me)
				else
					seat.frame.Visible = false
				end
			end
			local botCount = botInfo(lobby)
			bots = math.max(bots, botCount)
			partyTitle.Text = if bots > 0
				then string.format("Party (%d + %d 🤖 bot%s)", humans, bots, if bots == 1 then "" else "s")
				else string.format("Party (%d)", humans)
		end
	end

	------------------------------------------------------------------
	-- Bottom bar
	------------------------------------------------------------------
	-- Contents: 230 + 140 + 190 + 130 + 100 + 170 + 5 x 10 gaps + 2 x 12 padding =
	-- 1034 design px. The bar is 1040 wide; a UIScale shrinks it if the root is
	-- ever narrower (only below Layout.MIN_SCALE), so READY never leaves the screen.
	local BAR_W = 1040
	local touch = Theme.TOUCH
	local bar = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(BAR_W, touch + 30),
		BackgroundColor3 = C.brownDark,
		BackgroundTransparency = 0.15,
		Parent = root,
	})
	local barScale = make("UIScale", { Parent = bar }) :: UIScale
	table.insert(
		unsubs,
		screen.onResize(function(size: Vector2)
			barScale.Scale = math.min(1, (size.X - 28) / BAR_W)
		end)
	)
	Theme.corner(18).Parent = bar
	Theme.stroke(C.cheese, 3).Parent = bar
	Theme.padding(12, 12).Parent = bar
	Theme.list(
		Enum.FillDirection.Horizontal,
		10,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	).Parent =
		bar

	local classButton = Theme.button("Elephante", C.cream, {
		LayoutOrder = 1,
		Size = UDim2.fromOffset(230, touch),
		TextSize = 20,
		Parent = bar,
	})
	local perksButton = Theme.button("🌳 Perks", C.green, {
		LayoutOrder = 2,
		Size = UDim2.fromOffset(140, touch),
		TextSize = 20,
		TextColor3 = C.white,
		Parent = bar,
	})
	Theme.textStroke(C.brownDark, 1.5).Parent = perksButton
	local perksBadge = Theme.badge("0", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 6, 0, -8),
		Size = UDim2.fromOffset(0, 22),
		TextSize = 14,
		Visible = false,
		ZIndex = 8,
		Parent = perksButton,
	})
	Theme.tooltip(
		perksButton,
		"Spend perk points for this class: 3 branches × 5 tiers. You earn 1 point per class level."
	)
	local botButton = Theme.button("🤖 Bot fill: On", C.creamDark, {
		LayoutOrder = 3,
		Size = UDim2.fromOffset(190, touch),
		TextSize = 18,
		Parent = bar,
	})
	Theme.tooltip(
		botButton,
		"AI bot teammates fill empty party slots so every run has at least 3 heroes. Bots are clearly tagged 🤖."
	)
	local shopButton = Theme.button("🛒 Shop", C.cheese, {
		LayoutOrder = 4,
		Size = UDim2.fromOffset(130, touch),
		TextSize = 22,
		Parent = bar,
	})
	local cheeseLabel = Theme.label({
		LayoutOrder = 5,
		Size = UDim2.fromOffset(100, touch),
		TextSize = 20,
		Text = "🧀 0",
		Parent = bar,
	})
	Theme.textStroke().Parent = cheeseLabel
	local readyButton = Theme.button("READY!", C.green, {
		LayoutOrder = 6,
		Size = UDim2.fromOffset(170, touch + 6),
		TextSize = 30,
		TextColor3 = C.white,
		Parent = bar,
	})
	Theme.textStroke(C.brownDark, 2).Parent = readyButton

	------------------------------------------------------------------
	-- Class picker (modal, on demand)
	------------------------------------------------------------------
	-- Capped to the screen; the tile grid and the detail text scroll, and the
	-- Select / Buy button stays pinned under the detail text.
	local head = math.max(60, touch + 12)
	local picker = Theme.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(960, 440),
		Visible = false,
		ZIndex = 5,
		Parent = root,
	})
	table.insert(unsubs, Theme.fitFrame(screen, picker, 960, 440 + head - 60, 10))
	Theme.label({
		Position = UDim2.fromOffset(20, 8),
		Size = UDim2.fromOffset(500, 40),
		TextSize = 30,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Choose your elephant",
		Parent = picker,
	})
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		Size = UDim2.fromOffset(touch, touch),
		TextColor3 = C.white,
		Parent = picker,
	}, function()
		picker.Visible = false
	end)
	local grid = Theme.scroller({
		Position = UDim2.fromOffset(16, head),
		Size = UDim2.new(0, 440, 1, -(head + 14)),
		ScrollBarThickness = 8,
		Parent = picker,
	})
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(206, math.max(82, touch)),
		CellPadding = UDim2.fromOffset(10, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	Theme.padding(4, 4).Parent = grid
	local detailBox = make("Frame", {
		Position = UDim2.fromOffset(470, head),
		Size = UDim2.new(1, -486, 1, -(head + 14)),
		BackgroundColor3 = C.creamDark,
		Parent = picker,
	})
	Theme.corner(12).Parent = detailBox
	local detail = Theme.scroller({
		Position = UDim2.fromOffset(0, 4),
		Size = UDim2.new(1, 0, 1, -(touch + 18)),
		ScrollBarThickness = 8,
		Parent = detailBox,
	})
	Theme.padding(14, 6).Parent = detail
	Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = detail
	local function dline(order: number, size: number, color: Color3, font: Enum.Font?): TextLabel
		return Theme.label({
			LayoutOrder = order,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			TextSize = size,
			TextColor3 = color,
			Font = font or Theme.FONT_BODY,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = detail,
		})
	end
	local dName = dline(1, 30, C.ink, Theme.FONT)
	local dRole = dline(2, 18, C.brown, Theme.FONT)
	local dDesc = dline(3, 15, C.ink)
	local dWeapon = dline(4, 16, C.ink)
	local dAbility = dline(5, 16, C.ink)
	local dPassive = dline(6, 16, C.ink)

	-- v2 class progression card: level, XP bar, mastery badge, perk points.
	local progCard = make("Frame", {
		LayoutOrder = 7,
		Size = UDim2.new(1, 0, 0, 74),
		BackgroundColor3 = C.rind,
		Parent = detail,
	}) :: Frame
	Theme.corner(12).Parent = progCard
	Theme.goldStroke(2).Parent = progCard
	Theme.gradient(progCard, Color3.fromRGB(255, 240, 220), Color3.fromRGB(150, 130, 110))
	local progLevel = Theme.label({
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -150, 0, 26),
		TextSize = 22,
		TextColor3 = C.gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = progCard,
	})
	Theme.textStroke(C.shade, 1.5).Parent = progLevel
	local masteryBadge = Theme.badge("", C.goldDeep, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 8),
		Size = UDim2.fromOffset(0, 22),
		TextSize = 13,
		Parent = progCard,
	})
	local progBar = Theme.bar({
		Position = UDim2.fromOffset(12, 36),
		Size = UDim2.new(1, -24, 0, 16),
		Parent = progCard,
	}, C.xp)
	progBar.text.TextSize = 12
	local progNote = Theme.label({
		Position = UDim2.fromOffset(12, 54),
		Size = UDim2.new(1, -24, 0, 16),
		TextSize = 12,
		Font = Theme.FONT_BODY,
		TextColor3 = C.textDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = progCard,
	})

	-- Ability selector: base + 2 alternates (class levels 5 / 15).
	dline(8, 18, C.ink, Theme.FONT).Text = "Ability"
	type Choice = {
		button: TextButton,
		title: TextLabel,
		info: TextLabel,
		stroke: UIStroke,
		id: string,
		unlocked: boolean,
	}
	local abilityChoices: { Choice } = {}
	for i = 1, 3 do
		local b = make("TextButton", {
			LayoutOrder = 8 + i,
			Size = UDim2.new(1, 0, 0, math.max(58, touch * 0.8)),
			BackgroundColor3 = C.cream,
			AutoButtonColor = false,
			Text = "",
			Selectable = true,
			Parent = detail,
		}) :: TextButton
		Theme.corner(10).Parent = b
		local st = Theme.stroke(C.brown, 2)
		st.Parent = b
		Theme.hover(b, 1.02)
		local t = Theme.label({
			Position = UDim2.fromOffset(10, 4),
			Size = UDim2.new(1, -20, 0, 22),
			TextSize = 17,
			TextColor3 = C.ink,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Parent = b,
		})
		local info = Theme.label({
			Position = UDim2.fromOffset(10, 26),
			Size = UDim2.new(1, -20, 1, -28),
			TextSize = 13,
			Font = Theme.FONT_BODY,
			TextColor3 = C.brown,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = b,
		})
		local choice: Choice = { button = b, title = t, info = info, stroke = st, id = "", unlocked = false }
		abilityChoices[i] = choice
		b.Activated:Connect(function()
			local cid = previewId or selectedClassId()
			local def = Defs.get("Classes", cid)
			if not choice.unlocked or not def or not isUnlocked(def) then
				return
			end
			-- The base ability is "no alternate": send nil (R3 SelectAbility(classId, abilityId?)).
			Remotes.fire(Remotes.C2S.SelectAbility, cid, if i == 1 then nil else choice.id)
		end)
	end

	-- Skin selector: Classic + level skins (3 / 10 / 20 / 30) + owned paid skins.
	dline(12, 18, C.ink, Theme.FONT).Text = "Skin"
	local skinRow = make("Frame", {
		LayoutOrder = 13,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = detail,
	})
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(math.max(64, touch), math.max(64, touch)),
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = skinRow,
	})
	type Swatch = {
		button: TextButton,
		stroke: UIStroke,
		lock: Frame,
		label: TextLabel,
		id: string,
		unlocked: boolean,
	}
	local swatches: { Swatch } = {}
	local function swatch(i: number): Swatch
		local sw = swatches[i]
		if sw then
			return sw
		end
		local b = make("TextButton", {
			LayoutOrder = i,
			BackgroundColor3 = C.grey,
			AutoButtonColor = false,
			Text = "",
			Selectable = true,
			Parent = skinRow,
		}) :: TextButton
		Theme.corner(12).Parent = b
		Theme.gloss(b, 1, 0.7)
		local st = Theme.stroke(C.brown, 2)
		st.Parent = b
		Theme.hover(b, 1.06)
		local lock = Theme.icon("lock", 26, C.cream, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.4),
			Parent = b,
		})
		local label = Theme.label({
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -2),
			Size = UDim2.new(1, -4, 0, 14),
			TextSize = 11,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Parent = b,
		})
		Theme.textStroke(C.shade, 1).Parent = label
		local s2: Swatch = { button = b, stroke = st, lock = lock, label = label, id = "", unlocked = false }
		swatches[i] = s2
		b.Activated:Connect(function()
			local cid = previewId or selectedClassId()
			local def = Defs.get("Classes", cid)
			if not s2.unlocked or not def or not isUnlocked(def) then
				return
			end
			Remotes.fire(Remotes.C2S.SelectSkin, cid, if s2.id == "default" then nil else s2.id)
		end)
		return s2
	end

	local perkTreeButton = Theme.button("🌳 Open perk tree", C.green, {
		LayoutOrder = 14,
		Size = UDim2.new(1, 0, 0, touch),
		TextSize = 20,
		TextColor3 = C.white,
		Parent = detail,
	}, function()
		local cid = previewId or selectedClassId()
		PerkTreeUI.open(cid)
	end)
	Theme.textStroke(C.brownDark, 1.5).Parent = perkTreeButton

	local function renderProgress(id: string, def: any)
		local pr = ClassInfo.progress(id)
		progLevel.Text = string.format("Class level %d", pr.level)
		if pr.maxed then
			progBar.set(1, "MAX LEVEL")
		else
			progBar.set(pr.frac, string.format("%s / %s XP", Format.int(pr.xp), Format.int(pr.toNext)))
		end
		local mc = ClassInfo.masteryColor(pr.mastery)
		masteryBadge.Visible = mc ~= nil
		if mc then
			masteryBadge.Text = "★ " .. string.upper(pr.masteryName or pr.mastery)
			masteryBadge.BackgroundColor3 = mc
		end
		progNote.Text = string.format(
			"%d free perk point%s · class XP comes from runs as %s (×1.5 when you extract)",
			pr.free,
			if pr.free == 1 then "" else "s",
			Defs.name(def, id)
		)
		local owned = isUnlocked(def)
		for i, a in ClassInfo.abilities(id, pr.level, pr.ability) do
			local c = abilityChoices[i]
			if c then
				c.id = a.id
				c.unlocked = a.unlocked and owned
				c.title.Text = (if a.selected then "✔ " elseif not a.unlocked then "🔒 " else "")
					.. a.name
					.. (if i == 1 then "  (base)" else "")
				c.info.Text = if a.unlocked
					then a.description
					else string.format("Unlocks at class level %d. %s", a.unlockLevel, a.description)
				c.button.BackgroundColor3 = if a.selected
					then C.goldLight
					elseif a.unlocked then C.cream
					else C.creamDark
				c.stroke.Color = if a.selected then C.goldDeep else C.brown
				c.stroke.Thickness = if a.selected then 3 else 2
				c.title.TextColor3 = if a.unlocked then C.ink else C.grey
			end
		end
		local skins = ClassInfo.skins(id, pr.level, pr.skin)
		for i, sk in skins do
			local sw = swatch(i)
			sw.button.Visible = true
			sw.id = sk.id
			sw.unlocked = sk.unlocked and owned
			sw.button.BackgroundColor3 = if sk.color
				then Format.rgb(sk.color, C.grey)
				else Format.rgb(def.color, C.grey)
			sw.lock.Visible = not sk.unlocked
			sw.label.Text = if sk.unlocked then sk.name else "Lv " .. sk.unlockLevel
			sw.stroke.Color = if sk.selected then C.goldDeep else C.brown
			sw.stroke.Thickness = if sk.selected then 4 else 2
		end
		for i = #skins + 1, #swatches do
			swatches[i].button.Visible = false
		end
		perkTreeButton.Text = if pr.free > 0
			then string.format("🌳 Perk tree (%d free point%s)", pr.free, if pr.free == 1 then "" else "s")
			else "🌳 Open perk tree"
	end
	local actionButton = Theme.button("Select", C.green, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(1, -28, 0, touch),
		TextColor3 = C.white,
		Parent = detailBox,
	})
	Theme.textStroke(C.brownDark, 2).Parent = actionButton

	local tiles: { [string]: TextButton } = {}

	local function renderDetail()
		local id = previewId or selectedClassId()
		local def = Defs.get("Classes", id)
		if not def then
			dName.Text = "Classes loading…"
			return
		end
		dName.Text = Defs.name(def, id)
		dRole.Text = tostring(def.role or "")
		dDesc.Text = tostring(def.description or "")
		local w = def.weapon or {}
		dWeapon.Text = string.format(
			"⚔ Auto-weapon: %s · %s dmg",
			WEAPON_TEXT[tostring(w.kind)] or tostring(w.kind or "?"),
			tostring(w.damage or "?")
		)
		local a = def.ability or {}
		dAbility.Text = string.format(
			"💥 %s (%ss): %s",
			tostring(a.name or "Ability"),
			tostring(a.cooldown or "?"),
			tostring(a.description or "")
		)
		dPassive.Text = "🌟 " .. tostring(def.passiveText or "")
		renderProgress(id, def)
		local unlocked = isUnlocked(def)
		local selected = id == selectedClassId()
		if selected then
			actionButton.Text = "✔ Selected"
			actionButton.BackgroundColor3 = C.grey
			Theme.setEnabled(actionButton, false)
		elseif unlocked then
			actionButton.Text = "Select"
			actionButton.BackgroundColor3 = C.green
			Theme.setEnabled(actionButton, true)
		else
			local cost = tonumber(def.unlockCost) or 0
			actionButton.Text = "Buy 🧀 " .. Format.int(cost)
			actionButton.BackgroundColor3 = C.cheeseDark
			Theme.setEnabled(actionButton, cheese() >= cost)
		end
	end

	local function renderTiles()
		local defs = Defs.all("Classes")
		local sel = selectedClassId()
		for i, def in defs do
			local id = tostring(def.id)
			local tile = tiles[id]
			if not tile then
				local t = make("TextButton", {
					LayoutOrder = i,
					BackgroundColor3 = Format.rgb(def.color, C.cream),
					AutoButtonColor = false,
					Text = "",
					Selectable = true,
					Parent = grid,
				}) :: TextButton
				Theme.corner(12).Parent = t
				Theme.stroke(C.brownDark, 3).Parent = t
				local n = Theme.label({
					Name = "NameLabel",
					Position = UDim2.fromOffset(10, 6),
					Size = UDim2.new(1, -20, 0, 28),
					TextSize = 22,
					TextXAlignment = Enum.TextXAlignment.Left,
					Text = Defs.name(def, id),
					Parent = t,
				})
				Theme.textStroke().Parent = n
				local s = Theme.label({
					Name = "SubLabel",
					Position = UDim2.fromOffset(10, 38),
					Size = UDim2.new(1, -20, 0, 32),
					TextSize = 15,
					Font = Theme.FONT_BODY,
					TextXAlignment = Enum.TextXAlignment.Left,
					Parent = t,
				})
				Theme.textStroke(C.brownDark, 1.5).Parent = s
				Theme.gloss(t, 1, 0.8)
				Theme.hover(t, 1.03)
				Theme.badge("LV 1", C.rind, {
					Name = "LevelBadge",
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, -8, 0, 8),
					Size = UDim2.fromOffset(0, 20),
					Parent = t,
				})
				local xpTrack = make("Frame", {
					Name = "XpTrack",
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.new(0, 10, 1, -6),
					Size = UDim2.new(1, -20, 0, 6),
					BackgroundColor3 = C.shade,
					BackgroundTransparency = 0.3,
					Parent = t,
				})
				Theme.round().Parent = xpTrack
				local xpFill = make("Frame", {
					Name = "XpFill",
					Size = UDim2.fromScale(0, 1),
					BackgroundColor3 = C.xp,
					Parent = xpTrack,
				})
				Theme.round().Parent = xpFill
				t.Activated:Connect(function()
					previewId = id
					renderDetail()
					renderTiles()
				end)
				tiles[id] = t
				tile = t
			end
			local tt = tile :: TextButton
			local sub = tt:FindFirstChild("SubLabel") :: TextLabel
			local unlocked = isUnlocked(def)
			if id == sel then
				sub.Text = "✔ " .. tostring(def.role or "")
			elseif unlocked then
				sub.Text = tostring(def.role or "")
			else
				sub.Text = "🔒 🧀 " .. Format.int(def.unlockCost)
			end
			local pr = ClassInfo.progress(id)
			local badge = tt:FindFirstChild("LevelBadge") :: TextLabel?
			if badge then
				local mc = ClassInfo.masteryColor(pr.mastery)
				badge.Text = (if mc then "★ " else "") .. "LV " .. tostring(pr.level)
				badge.BackgroundColor3 = mc or C.rind
			end
			local track = tt:FindFirstChild("XpTrack")
			local fill = track and track:FindFirstChild("XpFill") :: Frame?
			if fill then
				fill.Size = UDim2.fromScale(pr.frac, 1)
			end
			local stroke = tt:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Thickness = if id == (previewId or sel) then 6 else 3
				stroke.Color = if id == (previewId or sel) then C.cheese else C.brownDark
			end
		end
	end

	actionButton.Activated:Connect(function()
		if not actionButton.Active then
			return
		end
		local id = previewId or selectedClassId()
		local def = Defs.get("Classes", id)
		if not def then
			return
		end
		if isUnlocked(def) then
			Remotes.fire(Remotes.C2S.SelectClass, id)
			picker.Visible = false
		else
			Remotes.fire(Remotes.C2S.BuyShopItem, "class:" .. id)
		end
	end)

	classButton.Activated:Connect(function()
		picker.Visible = not picker.Visible
		if picker.Visible then
			previewId = selectedClassId()
			renderTiles()
			renderDetail()
			Theme.popIn(picker)
		end
	end)
	perksButton.Activated:Connect(function()
		picker.Visible = false
		PerkTreeUI.open(selectedClassId())
	end)
	shopButton.Activated:Connect(function()
		local ok, Shop = pcall(require, script.Parent.ShopUI)
		if ok and Shop.toggle then
			picker.Visible = false
			Shop.toggle()
		end
	end)

	local function renderBot()
		botButton.Text = if botFill then "🤖 Bot fill: On" else "🤖 Bot fill: Off"
		botButton.BackgroundColor3 = if botFill then Color3.fromRGB(190, 230, 180) else C.creamDark
	end
	botButton.Activated:Connect(function()
		botFill = not botFill
		renderBot()
		local name = Remotes.C2S.SetBotFill
		if name then
			Remotes.fire(name, botFill)
		end
	end)

	local function renderReady()
		local ready = isReady()
		readyButton.Text = if ready then "READY ✔" else "READY!"
		readyButton.BackgroundColor3 = if ready then C.grey else C.green
	end
	readyButton.Activated:Connect(function()
		-- During an active run, readying queues us for the next one.
		local want = not isReady()
		readyLocal = want
		readyLocalAt = os.clock()
		Remotes.fire(Remotes.C2S.SetReady, want)
		renderReady()
	end)

	------------------------------------------------------------------
	-- Pressure: summary card (top-left) + board modal (GDD §3.7)
	------------------------------------------------------------------
	local pBox = Theme.panel({
		Position = UDim2.fromOffset(14, 14),
		Size = UDim2.fromOffset(300, 64),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 0.05,
		Parent = root,
	})
	Theme.padding(12, 10).Parent = pBox
	Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = pBox
	local pTitle = Theme.label({
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 28),
		TextSize = 22,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "🔥 Pressure",
		Parent = pBox,
	})
	local pInfo = Theme.label({
		LayoutOrder = 2,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		TextSize = 15,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = pBox,
	})
	local pOpen = Theme.button("View board", C.cheese, {
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, touch),
		TextSize = 20,
		Parent = pBox,
	})
	Theme.tooltip(
		pOpen,
		"Pressure: stack difficulty modifiers before a run for more cheese, luck and Epic drops. The party leader (👑, first to READY) sets it."
	)

	local board = Theme.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(760, 560),
		Visible = false,
		ZIndex = 5,
		Parent = root,
	})
	table.insert(unsubs, Theme.fitFrame(screen, board, 760, 560 + head - 60, 10))
	Theme.label({
		Position = UDim2.fromOffset(20, 8),
		Size = UDim2.new(1, -(touch + 40), 0, 40),
		TextSize = 30,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "🔥 Pressure",
		Parent = board,
	})
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		Size = UDim2.fromOffset(touch, touch),
		TextColor3 = C.white,
		Parent = board,
	}, function()
		board.Visible = false
	end)
	local bSummary = Theme.label({
		Position = UDim2.fromOffset(20, head),
		Size = UDim2.new(1, -40, 0, 30),
		TextSize = 22,
		TextScaled = true,
		TextWrapped = false,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = board,
	})
	make("UITextSizeConstraint", { MaxTextSize = 22, MinTextSize = 12, Parent = bSummary })
	local bNote = Theme.label({
		Position = UDim2.fromOffset(20, head + 32),
		Size = UDim2.new(1, -40, 0, 40),
		TextSize = 16,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = board,
	})
	local rowsBox = Theme.scroller({
		Position = UDim2.fromOffset(12, head + 76),
		Size = UDim2.new(1, -24, 1, -(head + 88)),
		ScrollBarThickness = 8,
		Parent = board,
	})
	Theme.padding(4, 4).Parent = rowsBox
	Theme.list(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Left).Parent = rowsBox

	type PressureRow = { minus: TextButton, plus: TextButton, rank: TextLabel, maxRank: number }
	local pRows: { [string]: PressureRow } = {}
	local renderPressure: () -> () = function() end

	local function bump(id: string, delta: number, maxRank: number)
		if not canEditPressure() then
			return
		end
		local cur = shownBoard()
		local was = cur[id] or 0
		local r = math.clamp(was + delta, 0, maxRank)
		if r == was then
			return
		end
		local nb = table.clone(cur)
		nb[id] = if r > 0 then r else nil
		localBoard = nb
		localBoardAt = os.clock()
		Remotes.fire(Remotes.C2S.SetPressure, id, r)
		renderPressure()
	end

	local function buildRows()
		if next(pRows) ~= nil then
			return
		end
		local cfg = Defs.module("Pressure")
		if type(cfg) ~= "table" or type(cfg.LIST) ~= "table" then
			return
		end
		local rankW = 84
		local right = 2 * touch + rankW + 24
		for i, def in cfg.LIST do
			local id = tostring(def.id)
			local maxRank = math.max(1, math.floor(tonumber(def.maxRank) or 1))
			local row = make("Frame", {
				LayoutOrder = i,
				BackgroundColor3 = C.creamDark,
				Size = UDim2.new(1, -8, 0, touch + 12),
				Parent = rowsBox,
			})
			Theme.corner(10).Parent = row
			Theme.label({
				Position = UDim2.fromOffset(12, 4),
				Size = UDim2.new(1, -(right + 16), 0, 28),
				TextSize = 20,
				TextColor3 = C.ink,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextWrapped = false,
				Text = tostring(def.icon or "") .. " " .. Defs.name(def, id),
				Parent = row,
			})
			Theme.label({
				Position = UDim2.fromOffset(12, 32),
				Size = UDim2.new(1, -(right + 16), 1, -36),
				TextSize = 14,
				Font = Theme.FONT_BODY,
				TextColor3 = C.brown,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				Text = tostring(def.description or "") .. " per rank",
				Parent = row,
			})
			local plus = Theme.button("+", C.green, {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -8, 0.5, 0),
				Size = UDim2.fromOffset(touch, touch),
				TextSize = 34,
				TextColor3 = C.white,
				Parent = row,
			})
			local rank = Theme.label({
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -(12 + touch), 0.5, 0),
				Size = UDim2.fromOffset(rankW, 44),
				TextSize = 22,
				TextColor3 = C.ink,
				Parent = row,
			})
			local minus = Theme.button("−", C.red, {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -(16 + touch + rankW), 0.5, 0),
				Size = UDim2.fromOffset(touch, touch),
				TextSize = 34,
				TextColor3 = C.white,
				Parent = row,
			})
			minus.Activated:Connect(function()
				if minus.Active then
					bump(id, -1, maxRank)
				end
			end)
			plus.Activated:Connect(function()
				if plus.Active then
					bump(id, 1, maxRank)
				end
			end)
			pRows[id] = { minus = minus, plus = plus, rank = rank, maxRank = maxRank }
		end
	end

	renderPressure = function()
		local pr = lobbyPressure()
		local b = shownBoard()
		local ok, pv = pcall(PressureMath.preview, b)
		local preview = if ok and type(pv) == "table"
			then pv
			else { points = pr.points or 0, cheesePct = 0, luck = 0, epicPct = 0 }
		local maxPoints = tonumber(PressureMath.MAX_POINTS) or 21
		local unlocked = pr.unlocked == true
		local editable = canEditPressure()
		local isLeader = State.isLeader()
		local lname = leaderName()
		local rewardLine = string.format(
			"+%d%% 🧀 cheese · +%s luck · +%d%% Epic chance",
			preview.cheesePct,
			string.format("%.2f", preview.luck),
			preview.epicPct
		)

		-- Summary card
		pTitle.Text = if unlocked then string.format("🔥 Pressure %d", preview.points) else "🔒 Pressure"
		local lockText = "Win a run (Go Home) to unlock Pressure"
		if not unlocked then
			if isLeader or pr.youUnlocked ~= true then
				pInfo.Text = "🔒 " .. lockText
			else
				pInfo.Text = string.format("🔒 👑 %s hasn't unlocked Pressure yet", lname or "The leader")
			end
		elseif preview.points == 0 then
			pInfo.Text = if isLeader
				then "Off. You're the leader: stack modifiers for more rewards!"
				else string.format("Off · set by 👑 %s", lname or "the leader")
		else
			pInfo.Text = rewardLine
				.. (
					if isLeader
						then "\nYou're the leader 👑"
						else string.format("\nSet by 👑 %s", lname or "the leader")
				)
		end
		pOpen.Text = if editable then "Edit board" else "View board"

		-- Board modal
		bSummary.Text = string.format("Pressure %d / %d  ·  %s", preview.points, maxPoints, rewardLine)
		if not unlocked then
			bNote.Text = if isLeader or pr.youUnlocked ~= true
				then "🔒 " .. lockText .. ". Until then the board is read-only."
				else string.format(
					"🔒 👑 %s (the party leader) hasn't unlocked Pressure yet. %s.",
					lname or "The leader",
					lockText
				)
			bNote.TextColor3 = C.red
		elseif editable then
			bNote.Text =
				"You're the party leader 👑: tap − / + to set Pressure. Everyone sees it; 🤖 bots accept it."
			bNote.TextColor3 = C.brown
		elseif pr.leaderId == nil then
			bNote.Text = "The first player to READY becomes the party leader 👑 and sets Pressure."
			bNote.TextColor3 = C.brown
		else
			bNote.Text = string.format(
				"Read-only: 👑 %s sets Pressure (first to READY). It applies to the whole party.",
				lname or "the leader"
			)
			bNote.TextColor3 = C.brown
		end
		buildRows()
		for id, row in pRows do
			local r = math.clamp(b[id] or 0, 0, row.maxRank)
			row.rank.Text = string.rep("●", r) .. string.rep("○", row.maxRank - r)
			row.rank.TextColor3 = if r > 0 then C.orange else C.grey
			Theme.setEnabled(row.minus, editable and r > 0)
			Theme.setEnabled(row.plus, editable and r < row.maxRank)
		end
	end

	pOpen.Activated:Connect(function()
		board.Visible = not board.Visible
		if board.Visible then
			picker.Visible = false
			renderPressure()
			Theme.popIn(board)
		end
	end)
	classButton.Activated:Connect(function()
		board.Visible = false
	end)

	------------------------------------------------------------------
	-- Wiring
	------------------------------------------------------------------
	local function renderVisibility()
		local results = State.get("results")
		root.Visible = State.inLobby() and results == nil
		if not root.Visible then
			picker.Visible = false
			board.Visible = false
		end
	end

	local function renderAll()
		local def = Defs.get("Classes", selectedClassId())
		local pr = ClassInfo.progress(selectedClassId())
		classButton.Text = string.format("🐘 %s Lv %d ▾", Defs.name(def, selectedClassId()), pr.level)
		perksBadge.Visible = pr.free > 0
		perksBadge.Text = tostring(pr.free)
		cheeseLabel.Text = "🧀 " .. Format.short(cheese())
		local lobby = State.get("lobby")
		if type(lobby) == "table" and type(lobby.botFill) == "boolean" then
			botFill = lobby.botFill
		end
		renderBot()
		renderReady()
		renderParty()
		renderPressure()
		if picker.Visible then
			renderTiles()
			renderDetail()
		end
		renderVisibility()
	end

	table.insert(
		unsubs,
		State.subscribe("lobby", function()
			readyLocal = nil -- server state wins once it arrives
			renderAll()
		end, true)
	)
	table.insert(unsubs, State.subscribe("profile", renderAll, true))
	table.insert(unsubs, State.subscribe("run", renderVisibility, true))
	table.insert(unsubs, State.subscribe("results", renderVisibility, true))

	renderConn = RunService.RenderStepped:Connect(function()
		if not root.Visible then
			return
		end
		local lobby = State.get("lobby")
		if type(lobby) ~= "table" then
			countdown.Text = "Trunkfall"
			subtitle.Text = "Connecting to the herd…"
			return
		end
		if lobby.runActive then
			local e = myEntry()
			if not (e and e.inRun) then
				-- one match per server (QC-A minor 6): say when the next one can start
				local info = if type(lobby.runInfo) == "table" then lobby.runInfo else nil
				local endsAt = info and tonumber(info.endsAt)
				countdown.Text = "Match in progress"
				if endsAt then
					local left = math.max(0, endsAt - State.serverNow())
					subtitle.Text = string.format(
						"Stage %s/%s · about %s left.\nThe next match starts when this one ends. Ready up!",
						tostring(info.stage or "?"),
						tostring(info.stages or 4),
						Format.clock(left)
					)
				else
					subtitle.Text = "The next match starts when this one ends. Ready up!"
				end
				return
			end
		end
		local startsAt = tonumber(lobby.startsAt)
		local now = State.serverNow()
		local nBots, botsOn = botInfo(lobby)
		local botLine: string
		if not botsOn then
			botLine = "Bots off: no 🤖 teammates will join"
		elseif nBots > 0 then
			botLine =
				string.format("+ %d 🤖 bot teammate%s will join", nBots, if nBots == 1 then "" else "s")
		else
			botLine = ""
		end
		local function withBots(text: string): string
			return if botLine ~= "" then text .. "\n" .. botLine else text
		end
		-- Fix-team lobby flags: an AFK-capped player is no longer auto-started,
		-- and an un-readied one sits out the next start.
		local me = myEntry()
		local standBy: string? = nil
		if me and not isReady() then
			if me.needsReady == true then
				standBy = "Press READY to play"
			elseif me.sittingOut == true then
				standBy = "You're sitting out this start · Press READY to play"
			end
		end
		if startsAt and startsAt > now then
			local auto = isAutoStart(lobby)
			countdown.Text = (if auto then "Auto-start in " else "Starting in ")
				.. Format.clock(startsAt - now)
			subtitle.Text = withBots(
				if isReady()
					then "Get ready to stomp!"
					elseif standBy then standBy
					elseif auto then "Press READY to start sooner"
					else "Press READY to jump in"
			)
		else
			countdown.Text = "Pick an elephant and READY UP!"
			subtitle.Text = withBots(standBy or "Stomp the mouse horde with your friends 🐘🧀")
		end
	end)
end

function LobbyUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	if screen then
		screen.destroy()
		screen = nil
	end
end

return LobbyUI
