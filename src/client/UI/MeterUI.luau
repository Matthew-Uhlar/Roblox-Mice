--!strict
-- Run stats HUD (iteration 5 Phase B):
--   #1 Damage meter: a live panel (State "meter", Net.S2C.Meter ~1 Hz) sorted
--      by damage, your squad highlighted, you marked, bots tagged 🤖. Opens
--      with Tab (InputController), while Back / Select is HELD on a gamepad,
--      or the small 📊 button on touch screens. MeterUI.table(parent) builds
--      the full table the results screen shows (Results.meter).
--   #6 Overtime strip: wave, best wave and the scaling while State
--      "overtime".active (Net.S2C.Overtime {active, wave, best, endsAt?}), with
--      an "Extract now" button (X / D-pad down / tap) that votes
--      ExtractVote("Extract") directly and then shows "Waiting for squad vote".
-- Missing fields read as 0; with no meter data the panel says so.

local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local MeterModel = require(Client.Util.MeterModel)
local Device = require(Client.Util.Device)
local UiSizes = require(Client.Util.UiSizes)
local Format = require(Client.Util.Format)
local Remotes = require(Client.Util.Remotes)
local State = require(Client.Controllers.State)

local MeterUI = {}

-- Votes to extract from Overtime (true if sent). Set by init.
MeterUI.extractNow = function(): boolean
	return false
end

local C = Theme.C
local make = Theme.make

local ACTION_EXTRACT = "TrunkfallOvertimeExtract"
local LIVE_ROWS = 8
local ROW_H = 24

local screen: any = nil
local unsubs: { () -> () } = {}
local conns: { RBXScriptConnection } = {}

type Line = {
	frame: Frame,
	bar: Frame,
	name: TextLabel,
	cols: { TextLabel },
}

-- Column sets: live (compact) and full (results).
local LIVE_COLS = { { "dmg", "Dmg", 62 }, { "kills", "K", 34 }, { "deaths", "D", 30 } }
local FULL_COLS = {
	{ "dmg", "Damage", 70 },
	{ "pve", "PvE", 60 },
	{ "pvp", "PvP", 56 },
	{ "heal", "Heal", 56 },
	{ "taken", "Taken", 60 },
	{ "kills", "K", 34 },
	{ "deaths", "D", 30 },
}

local function squadColor(id: number?): Color3?
	if id == nil then
		return nil
	end
	local ok, _, col = pcall(Theme.squad, id)
	return if ok and typeof(col) == "Color3" then col else nil
end

-- Builds a pooled meter table inside `parent` (a vertical list). Returns
-- set(rows) and the header frame.
local function buildTable(
	parent: GuiObject,
	cols: { { any } },
	textSize: number
): (({ MeterModel.Row }) -> (), Frame)
	local lines: { Line } = {}
	local colW = 0
	for _, c in cols do
		colW += c[3]
	end
	local header = make("Frame", {
		LayoutOrder = 0,
		Size = UDim2.new(1, 0, 0, ROW_H - 4),
		BackgroundTransparency = 1,
		Parent = parent,
	}) :: Frame
	Theme.label({
		Size = UDim2.new(1, -colW, 1, 0),
		TextSize = textSize - 1,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Hero",
		Parent = header,
	})
	local x = 0
	for _, c in cols do
		Theme.label({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -x, 0, 0),
			Size = UDim2.new(0, c[3], 1, 0),
			TextSize = textSize - 1,
			Font = Theme.FONT_BODY,
			TextColor3 = C.brown,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = c[2],
			Parent = header,
		})
		x += c[3]
	end
	local function line(i: number): Line
		local l = lines[i]
		if l then
			return l
		end
		local f = make("Frame", {
			LayoutOrder = i,
			Size = UDim2.new(1, 0, 0, ROW_H),
			BackgroundColor3 = C.cream,
			BackgroundTransparency = 0.2,
			Parent = parent,
		}) :: Frame
		Theme.corner(6).Parent = f
		local bar = make("Frame", {
			Size = UDim2.fromScale(0, 1),
			BackgroundColor3 = C.cheese,
			BackgroundTransparency = 0.45,
			BorderSizePixel = 0,
			Parent = f,
		}) :: Frame
		Theme.corner(6).Parent = bar
		local name = Theme.label({
			Position = UDim2.fromOffset(6, 0),
			Size = UDim2.new(1, -(colW + 8), 1, 0),
			TextSize = textSize,
			TextColor3 = C.ink,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 3,
			Parent = f,
		})
		local labels: { TextLabel } = {}
		local cx = 4
		for ci, c in cols do
			labels[ci] = Theme.label({
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -cx, 0, 0),
				Size = UDim2.new(0, c[3] - 2, 1, 0),
				TextSize = textSize,
				TextColor3 = C.ink,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextWrapped = false,
				ZIndex = 3,
				Parent = f,
			})
			cx += c[3]
		end
		l = { frame = f, bar = bar, name = name, cols = labels }
		lines[i] = l
		return l
	end
	local function set(rows: { MeterModel.Row })
		for i, r in rows do
			local l = line(i)
			l.frame.Visible = true
			l.name.Text = string.format("%d. %s", r.rank, MeterModel.label(r))
			l.name.TextColor3 = if r.me then C.goldDeep else C.ink
			l.frame.BackgroundColor3 = if r.me then C.goldLight elseif r.mine then C.cream else C.creamDark
			l.bar.Size = UDim2.fromScale(r.frac, 1)
			l.bar.BackgroundColor3 = squadColor(r.squad) or C.cheese
			for ci, c in cols do
				local v = (r :: any)[c[1]]
				l.cols[ci].Text = if c[1] == "kills" or c[1] == "deaths"
					then tostring(v or 0)
					else MeterModel.short(tonumber(v) or 0)
			end
		end
		for i = #rows + 1, #lines do
			lines[i].frame.Visible = false
		end
	end
	return set, header
end

-- Full results table (ResultsUI): a card with every hero, or nil-safe empty.
-- Returns (card, set(meterPayload)).
function MeterUI.table(parent: Instance, order: number): (Frame, (any) -> ())
	local card = make("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.creamDark,
		Visible = false,
		Parent = parent,
	}) :: Frame
	Theme.corner(12).Parent = card
	Theme.padding(12, 8).Parent = card
	Theme.list(Enum.FillDirection.Vertical, 3).Parent = card
	Theme.label({
		LayoutOrder = -1,
		Size = UDim2.new(1, 0, 0, 24),
		TextSize = 18,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "📊 Damage meter",
		Parent = card,
	})
	local set = buildTable(card, FULL_COLS, 13)
	return card,
		function(meter: any)
			local rows = MeterModel.rows(meter, State.mySquad(), State.localUserId(), function(id)
				return State.isBot(id)
			end)
			card.Visible = #rows > 0
			set(rows)
		end
end

function MeterUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallMeter", 22)
	local root: Frame = screen.root
	local dense = Theme.dense()
	local touch = Theme.TOUCH
	local Z = UiSizes.hud(dense, touch)

	------------------------------------------------------------------
	-- Live damage panel (left, middle)
	------------------------------------------------------------------
	local W = 300
	local panel = make("Frame", {
		Name = "Meter",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, Z.margin or 10, 0.5, 0),
		Size = UDim2.fromOffset(W, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.shade,
		BackgroundTransparency = 0.35,
		Visible = false,
		Parent = root,
	}) :: Frame
	Theme.corner(10).Parent = panel
	Theme.stroke(C.gold, 2, 0.4).Parent = panel
	Theme.padding(8, 6).Parent = panel
	Theme.list(Enum.FillDirection.Vertical, 3).Parent = panel
	local head = Theme.label({
		LayoutOrder = -2,
		Size = UDim2.new(1, 0, 0, 20),
		TextSize = 15,
		TextColor3 = C.goldLight,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "📊 Damage",
		Parent = panel,
	})
	Theme.textStroke(C.shade, 1).Parent = head
	local body = make("Frame", {
		LayoutOrder = -1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = panel,
	})
	Theme.list(Enum.FillDirection.Vertical, 2).Parent = body
	local setLive = buildTable(body, LIVE_COLS, 13)
	local empty = Theme.label({
		LayoutOrder = 99,
		Size = UDim2.new(1, 0, 0, 18),
		TextSize = 12,
		Font = Theme.FONT_BODY,
		TextColor3 = C.cream,
		Text = "No damage yet",
		Visible = false,
		Parent = panel,
	})

	local function inRun(): boolean
		local ph = State.phase()
		return ph ~= nil and ph ~= "Lobby" and ph ~= "Results"
	end

	local function render()
		local open = State.get("meterOpen") == true and inRun()
		panel.Visible = open
		if not open then
			return
		end
		local rows = MeterModel.rows(State.get("meter"), State.mySquad(), State.localUserId(), function(id)
			return State.isBot(id)
		end)
		local shown = MeterModel.top(rows, LIVE_ROWS)
		setLive(shown)
		empty.Visible = #shown == 0
		head.Text =
			string.format("📊 Damage · %s", if Device.mode() == "gamepad" then "hold Back" else "Tab")
	end
	table.insert(unsubs, State.subscribe("meter", render))
	table.insert(unsubs, State.subscribe("meterOpen", render, true))
	table.insert(unsubs, State.subscribe("run", render))

	-- Phone: a small 📊 button (left edge, above the thumbstick zone)
	if Device.hasTouch() then
		local size = math.max(44, math.floor(touch * 0.75))
		local b = Theme.button("📊", C.cream, {
			Name = "MeterButton",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, Z.margin or 10, 0.5, -(size + 40)),
			Size = UDim2.fromOffset(size, size),
			TextSize = math.floor(size * 0.5),
			Visible = false,
			Parent = root,
		}, function()
			State.set("meterOpen", State.get("meterOpen") ~= true)
		end)
		Theme.round().Parent = b
		table.insert(
			unsubs,
			State.subscribe("run", function()
				b.Visible = inRun()
			end, true)
		)
		-- the open panel sits under the button
		panel.Position = UDim2.new(0, Z.margin or 10, 0.5, -20)
		panel.AnchorPoint = Vector2.new(0, 0)
	end

	------------------------------------------------------------------
	-- Overtime strip (top-centre)
	------------------------------------------------------------------
	local slim = Theme.SLIM
	local y = if dense then UiSizes.barSlotY(dense, touch, slim, 2) else UiSizes.underHeader(dense, touch)
	local strip = make("Frame", {
		Name = "Overtime",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, y),
		Size = UDim2.fromOffset(if dense then 360 else 420, slim),
		BackgroundColor3 = Color3.fromRGB(214, 84, 40),
		Visible = false,
		Parent = root,
	}) :: Frame
	Theme.corner(10).Parent = strip
	Theme.gloss(strip, 1, 0.8)
	Theme.goldStroke(2).Parent = strip
	local stripText = Theme.label({
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(8, 0),
		TextSize = if dense then 16 else 18,
		TextColor3 = C.white,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = strip,
	})
	Theme.textStroke(C.brownDark, 2).Parent = stripText

	-- QC MAJOR 2: leaving Overtime. The extract panel is closed by then, so this
	-- button votes ExtractVote("Extract") directly (X key, D-pad down on a
	-- gamepad, tap on a phone). The squad leaves when a majority of its
	-- standing humans vote; a downed hero can't vote.
	local votedAt = -math.huge
	local VOTE_SHOW = 10 -- seconds the "waiting" line stays after a vote
	local exitButton = Theme.button("🌀 Extract now", Color3.fromRGB(160, 120, 255), {
		Name = "OvertimeExtract",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 6),
		Size = UDim2.fromOffset(if dense then 260 else 300, math.max(slim, math.floor(touch * 0.8))),
		TextSize = if dense then 15 else 17,
		TextColor3 = C.white,
		Parent = strip,
	}, function()
		MeterUI.extractNow()
	end)
	local function downed(): boolean
		local hud = State.get("hud")
		return type(hud) == "table" and hud.downed == true
	end
	local function renderExit()
		local key = if Device.mode() == "gamepad" then " [D-pad ↓]" elseif Device.mode() == "kbm" then " [X]" else ""
		if downed() then
			exitButton.Text = "Downed: you can't vote"
			Theme.setEnabled(exitButton, false)
		elseif os.clock() - votedAt < VOTE_SHOW then
			exitButton.Text = "⏳ Waiting for squad vote…"
			Theme.setEnabled(exitButton, true)
		else
			exitButton.Text = "🌀 Extract now" .. key
			Theme.setEnabled(exitButton, true)
		end
	end
	MeterUI.extractNow = function(): boolean
		local ot = State.get("overtime")
		if type(ot) ~= "table" or ot.active ~= true or downed() or not Remotes.C2S.ExtractVote then
			return false
		end
		votedAt = os.clock()
		Remotes.fire(Remotes.C2S.ExtractVote, "Extract")
		renderExit()
		return true
	end
	ContextActionService:BindActionAtPriority(ACTION_EXTRACT, function(_n, st: Enum.UserInputState, input: InputObject)
		if st ~= Enum.UserInputState.Begin or not strip.Visible or UserInputService:GetFocusedTextBox() then
			return Enum.ContextActionResult.Pass
		end
		-- D-pad down rerolls while the upgrade strip is up
		if input.KeyCode == Enum.KeyCode.DPadDown and State.get("upgradeShown") == true then
			return Enum.ContextActionResult.Pass
		end
		return if MeterUI.extractNow() then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
	end, false, Enum.ContextActionPriority.Medium.Value, Enum.KeyCode.X, Enum.KeyCode.DPadDown)
	table.insert(unsubs, function()
		ContextActionService:UnbindAction(ACTION_EXTRACT)
	end)
	table.insert(unsubs, State.subscribe("hud", function()
		if strip.Visible then
			renderExit()
		end
	end))
	local lastWave = -1
	local function renderOvertime()
		local ot = State.get("overtime")
		local on = type(ot) == "table" and ot.active == true and inRun()
		strip.Visible = on
		if not on then
			return
		end
		local wave = math.max(0, math.floor(tonumber(ot.wave) or 0))
		local best = math.max(0, math.floor(tonumber(ot.best) or 0))
		local text = string.format("🔥 OVERTIME · Wave %d", wave)
		if best > 0 then
			text ..= if wave > best then " · NEW BEST!" else string.format(" · Best %d", best)
		end
		local scaling = tonumber(ot.scale) or tonumber(ot.mult)
		if scaling and scaling > 0 then
			text ..= string.format(" · ×%.1f", scaling)
		end
		local endsAt = tonumber(ot.endsAt)
		if endsAt then
			local left = endsAt - State.serverNow()
			if left > 0 and left < 3600 then
				text ..= " · " .. Format.clock(left)
			end
		end
		stripText.Text = text
		if (tonumber(ot.wave) or 0) ~= lastWave then
			lastWave = tonumber(ot.wave) or 0
		end
		renderExit()
	end
	table.insert(unsubs, State.subscribe("overtime", renderOvertime, true))
	table.insert(unsubs, State.subscribe("run", renderOvertime))
	local acc = 0
	table.insert(
		conns,
		RunService.Heartbeat:Connect(function(dt)
			acc += dt
			if acc < 0.5 or not strip.Visible then
				return
			end
			acc = 0
			renderOvertime() -- the endsAt clock
		end)
	)
end

function MeterUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	for _, c in conns do
		c:Disconnect()
	end
	table.clear(conns)
	if screen then
		screen.destroy()
		screen = nil
	end
end

return MeterUI
