--!strict
-- Lobby (run phase nil or "Lobby"). Kept compact so a new player can ready
-- up in seconds: a bottom bar (class, bot teammates toggle, shop, READY), a
-- party list with ready states and 🤖 bot tags, a big countdown, and an
-- on-demand class picker (7 classes, locked ones show cost + Buy).
--
-- Sends: SelectClass(classId), SetReady(bool), SetBotFill(bool),
--        BuyShopItem("class:<id>").

local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Remotes = require(Client.Util.Remotes)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local State = require(Client.Controllers.State)

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
	return type(profile) == "table" and type(profile.unlockedClasses) == "table" and profile.unlockedClasses[def.id] == true
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

function LobbyUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallLobby", 20)
	local root: Frame = screen.root

	------------------------------------------------------------------
	-- Countdown (top-centre)
	------------------------------------------------------------------
	local countdown = Theme.label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 14),
		Size = UDim2.fromOffset(620, 50),
		TextSize = 38,
		TextColor3 = C.cheese,
		Parent = root,
	})
	Theme.textStroke(C.brownDark, 3).Parent = countdown
	local subtitle = Theme.label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 64),
		Size = UDim2.fromOffset(620, 28),
		TextSize = 20,
		Parent = root,
	})
	Theme.textStroke().Parent = subtitle

	------------------------------------------------------------------
	-- Party list (top-right)
	------------------------------------------------------------------
	local party = Theme.panel({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 14),
		Size = UDim2.fromOffset(300, 64),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 0.05,
		Parent = root,
	})
	Theme.padding(12, 10).Parent = party
	Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = party
	local partyTitle = Theme.label({
		LayoutOrder = 0,
		Size = UDim2.new(1, 0, 0, 28),
		TextSize = 22,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Party",
		Parent = party,
	})

	local function renderParty()
		for _, ch in party:GetChildren() do
			if ch:IsA("Frame") then
				ch:Destroy()
			end
		end
		local lobby = State.get("lobby")
		local players = if type(lobby) == "table" and type(lobby.players) == "table" then lobby.players else {}
		local ids = {}
		for id in players do
			table.insert(ids, id)
		end
		-- Real players first (you on top), bots last.
		local me = State.localUserId()
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
		local humans, bots = 0, 0
		for i, id in ids do
			local e = players[id]
			local bot = State.isBot(id, e)
			if bot then
				bots += 1
			else
				humans += 1
			end
			local row = make("Frame", {
				LayoutOrder = i,
				BackgroundColor3 = if id == me then Color3.fromRGB(255, 236, 170) else C.creamDark,
				Size = UDim2.new(1, 0, 0, 46),
				Parent = party,
			})
			Theme.corner(10).Parent = row
			local classDef = Defs.get("Classes", e.classId)
			local name = tostring(e.name or (if bot then "Bot" else "Player"))
			Theme.label({
				Position = UDim2.fromOffset(10, 2),
				Size = UDim2.new(1, -70, 0, 24),
				TextSize = 18,
				TextColor3 = C.ink,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextWrapped = false,
				Text = (if bot then "🤖 Bot · " else "") .. name .. (if id == me then " (you)" else ""),
				Parent = row,
			})
			Theme.label({
				Position = UDim2.fromOffset(10, 24),
				Size = UDim2.new(1, -70, 0, 18),
				TextSize = 14,
				Font = Theme.FONT_BODY,
				TextColor3 = C.brown,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = Defs.name(classDef, e.classId) .. (if e.inRun == true then " · in a run" else ""),
				Parent = row,
			})
			Theme.label({
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -8, 0.5, 0),
				Size = UDim2.fromOffset(56, 30),
				TextSize = 24,
				TextColor3 = if e.ready == true then C.green else C.grey,
				Text = if bot then "🤖" elseif e.ready == true then "✔" else "…",
				Parent = row,
			})
		end
		partyTitle.Text = if bots > 0
			then string.format("Party (%d + %d 🤖 bots)", humans, bots)
			else string.format("Party (%d)", humans)
	end

	------------------------------------------------------------------
	-- Bottom bar
	------------------------------------------------------------------
	local bar = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(1000, 96),
		BackgroundColor3 = C.brownDark,
		BackgroundTransparency = 0.15,
		Parent = root,
	})
	Theme.corner(18).Parent = bar
	Theme.stroke(C.cheese, 3).Parent = bar
	Theme.padding(12, 12).Parent = bar
	Theme.list(Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent =
		bar

	local classButton = Theme.button("Elephante", C.cream, {
		LayoutOrder = 1,
		Size = UDim2.fromOffset(270, Theme.TOUCH),
		TextSize = 22,
		Parent = bar,
	})
	local botButton = Theme.button("🤖 Bot teammates: On", C.creamDark, {
		LayoutOrder = 2,
		Size = UDim2.fromOffset(230, Theme.TOUCH),
		TextSize = 18,
		Parent = bar,
	})
	Theme.tooltip(botButton, "AI bot teammates fill empty party slots so every run has at least 3 heroes. Bots are clearly tagged 🤖.")
	local shopButton = Theme.button("🛒 Shop", C.cheese, {
		LayoutOrder = 3,
		Size = UDim2.fromOffset(150, Theme.TOUCH),
		TextSize = 22,
		Parent = bar,
	})
	local cheeseLabel = Theme.label({
		LayoutOrder = 4,
		Size = UDim2.fromOffset(110, Theme.TOUCH),
		TextSize = 20,
		Text = "🧀 0",
		Parent = bar,
	})
	Theme.textStroke().Parent = cheeseLabel
	local readyButton = Theme.button("READY!", C.green, {
		LayoutOrder = 5,
		Size = UDim2.fromOffset(170, Theme.TOUCH + 6),
		TextSize = 30,
		TextColor3 = C.white,
		Parent = bar,
	})
	Theme.textStroke(C.brownDark, 2).Parent = readyButton

	------------------------------------------------------------------
	-- Class picker (modal, on demand)
	------------------------------------------------------------------
	local picker = Theme.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.46),
		Size = UDim2.fromOffset(960, 440),
		Visible = false,
		ZIndex = 5,
		Parent = root,
	})
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
		Position = UDim2.new(1, -10, 0, 8),
		Size = UDim2.fromOffset(Theme.TOUCH, Theme.TOUCH - 10),
		TextColor3 = C.white,
		Parent = picker,
	}, function()
		picker.Visible = false
	end)
	local grid = make("ScrollingFrame", {
		Position = UDim2.fromOffset(16, 60),
		Size = UDim2.fromOffset(440, 366),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = picker,
	})
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(206, 82),
		CellPadding = UDim2.fromOffset(10, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	Theme.padding(4, 4).Parent = grid
	local detail = make("Frame", {
		Position = UDim2.fromOffset(470, 60),
		Size = UDim2.fromOffset(474, 366),
		BackgroundColor3 = C.creamDark,
		Parent = picker,
	})
	Theme.corner(12).Parent = detail
	Theme.padding(14, 10).Parent = detail
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
	local actionButton = Theme.button("Select", C.green, {
		LayoutOrder = 7,
		Size = UDim2.fromOffset(300, Theme.TOUCH),
		TextColor3 = C.white,
		Parent = detail,
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
	shopButton.Activated:Connect(function()
		local ok, Shop = pcall(require, script.Parent.ShopUI)
		if ok and Shop.toggle then
			picker.Visible = false
			Shop.toggle()
		end
	end)

	local function renderBot()
		botButton.Text = if botFill then "🤖 Bot teammates: On" else "🤖 Bot teammates: Off"
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
	-- Wiring
	------------------------------------------------------------------
	local function renderVisibility()
		local results = State.get("results")
		root.Visible = State.inLobby() and results == nil
		if not root.Visible then
			picker.Visible = false
		end
	end

	local function renderAll()
		local def = Defs.get("Classes", selectedClassId())
		classButton.Text = "🐘 " .. Defs.name(def, selectedClassId()) .. "  ▾"
		cheeseLabel.Text = "🧀 " .. Format.short(cheese())
		local lobby = State.get("lobby")
		if type(lobby) == "table" and type(lobby.botFill) == "boolean" then
			botFill = lobby.botFill
		end
		renderBot()
		renderReady()
		renderParty()
		if picker.Visible then
			renderTiles()
			renderDetail()
		end
		renderVisibility()
	end

	table.insert(unsubs, State.subscribe("lobby", function()
		readyLocal = nil -- server state wins once it arrives
		renderAll()
	end, true))
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
				countdown.Text = "Run in progress"
				subtitle.Text = "You'll join the next one. Ready up!"
				return
			end
		end
		local startsAt = tonumber(lobby.startsAt)
		local now = State.serverNow()
		if startsAt and startsAt > now then
			local anyReady = false
			for id, e in lobby.players do
				if not State.isBot(id, e) and e.ready == true then
					anyReady = true
				end
			end
			countdown.Text = (if anyReady then "Starting in " else "Auto-start in ") .. Format.clock(startsAt - now)
			subtitle.Text = if isReady() then "Get ready to stomp!" else "Press READY to jump in now"
		else
			countdown.Text = "Pick an elephant and READY UP!"
			subtitle.Text = "Stomp the mouse horde with your friends 🐘🧀"
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
