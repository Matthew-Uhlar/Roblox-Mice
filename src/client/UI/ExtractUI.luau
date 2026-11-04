--!strict
-- Extraction window (GDD-v2 §1.4): the Rind Gate is open for 20 s and each
-- squad decides by majority (bots follow their humans). Three cards, each
-- stating its risk and its reward in plain words:
--   Extract          bank 100% of the squad pot now and leave with your rewards
--   Stay             next stage, the pot keeps growing (+25% "brave" bonus when
--                    2+ squads have already extracted)
--   Double or Nothing  stay; the pot ×1.5 on your next boss kill, lost if your
--                    squad is eliminated
-- Shows the squad's votes per card, your pick and a countdown bar.
-- Reads State "extract" (Net.S2C.Extract {endsAt, options, votes, yourChoice})
-- and "match" (pot, extracted squads). Sends Net.C2S.ExtractVote(choice).

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Format = require(Client.Util.Format)
local Device = require(Client.Util.Device)
local State = require(Client.Controllers.State)

local ExtractUI = {}

local C = Theme.C
local T = Theme.TYPE
local make = Theme.make

local WINDOW = 20

type Info = {
	title: string,
	icon: string,
	color: Color3,
	risk: number, -- 0..3 pips
	riskText: string,
	reward: (pot: number, brave: boolean) -> string,
	body: string,
}

local INFO: { [string]: Info } = {
	Extract = {
		title = "Extract",
		icon = "portal",
		color = Theme.TIER.Low,
		risk = 0,
		riskText = "None. You leave safely now.",
		reward = function(pot)
			return string.format("Bank 🧀 %s (100%% of the pot)", Format.int(pot))
		end,
		body = "Leave the run with your cheese and class XP (×1.5 XP for extracting). Gear stays behind.",
	},
	Stay = {
		title = "Stay",
		icon = "shield",
		color = Theme.TIER.Mid,
		risk = 2,
		riskText = "Enemy squads and a tougher stage. Fallen heroes drop 30% of their share.",
		reward = function(_pot, brave)
			return if brave
				then "Pot keeps growing, +25% brave bonus active!"
				else "Pot keeps growing next stage"
		end,
		body = "Fight on. Your pending cheese is not banked yet.",
	},
	DoubleOrNothing = {
		title = "Double or Nothing",
		icon = "star",
		color = Theme.TIER.High,
		risk = 3,
		riskText = "If your squad is eliminated, you lose the WHOLE pot.",
		reward = function(pot)
			return string.format(
				"Pot ×1.5 on your next boss kill: 🧀 %s",
				Format.int(math.floor(pot * 1.5))
			)
		end,
		body = "Stay and gamble the pot. Cheese only, never Robux.",
	},
}

local ORDER = { "Extract", "Stay", "DoubleOrNothing" }

local screen: any = nil
local unsubs: { () -> () } = {}
local renderConn: RBXScriptConnection? = nil

function ExtractUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallExtract", 31)
	local root: Frame = screen.root
	local touch = Theme.TOUCH
	local CARD_W, CARD_H = 300, 300 + touch
	local PANEL_W, PANEL_H = 3 * CARD_W + 4 * 16, CARD_H + 110

	local panel = Theme.card({
		Name = "Extract",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.56),
		Size = UDim2.fromOffset(PANEL_W, PANEL_H),
		Visible = false,
		Parent = root,
	}, { stroke = 3 })
	table.insert(unsubs, Theme.fitFrame(screen, panel, PANEL_W, PANEL_H, 8))
	Theme.icon(
		"portal",
		40,
		Color3.fromRGB(160, 120, 255),
		{ Position = UDim2.fromOffset(16, 10), Parent = panel }
	)
	local title = Theme.label({
		Position = UDim2.fromOffset(64, 8),
		Size = UDim2.new(1, -230, 0, 34),
		TextSize = T.title,
		TextColor3 = C.gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "The Rind Gate is open!",
		Parent = panel,
	})
	Theme.textStroke(C.shade, 2).Parent = title
	local sub = Theme.label({
		Position = UDim2.fromOffset(64, 42),
		Size = UDim2.new(1, -230, 0, 18),
		TextSize = T.caption,
		Font = Theme.FONT_BODY,
		TextColor3 = C.textDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Your squad votes. Majority decides; 🤖 bots follow their humans.",
		Parent = panel,
	})
	local timer = Theme.label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -18, 0, 10),
		Size = UDim2.fromOffset(150, 36),
		TextSize = T.title,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = panel,
	})
	Theme.textStroke(C.shade, 2).Parent = timer
	local timeBar = Theme.bar({
		Position = UDim2.fromOffset(16, 66),
		Size = UDim2.new(1, -32, 0, 10),
		Parent = panel,
	}, Color3.fromRGB(160, 120, 255))
	timeBar.text.Visible = false

	local row = Theme.scroller({
		Position = UDim2.fromOffset(0, 86),
		Size = UDim2.new(1, 0, 1, -92),
		ScrollingDirection = Enum.ScrollingDirection.XY,
		AutomaticCanvasSize = Enum.AutomaticSize.XY,
		ScrollBarImageColor3 = C.gold,
		ScrollBarThickness = 8,
		Parent = panel,
	})
	Theme.list(Enum.FillDirection.Horizontal, 16, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top).Parent =
		row

	type View = {
		button: TextButton,
		stroke: UIStroke,
		reward: TextLabel,
		votes: TextLabel,
		pick: TextLabel,
		pips: { Frame },
	}
	local views: { [string]: View } = {}

	local function line(
		parent: Instance,
		order: number,
		text: string,
		size: number,
		color: Color3,
		font: Enum.Font?
	): TextLabel
		return Theme.label({
			LayoutOrder = order,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			Text = text,
			TextSize = size,
			TextColor3 = color,
			Font = font or Theme.FONT_BODY,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = parent,
		})
	end

	for i, key in ORDER do
		local info = INFO[key]
		local b = make("TextButton", {
			Name = key,
			LayoutOrder = i,
			Size = UDim2.fromOffset(CARD_W, CARD_H),
			BackgroundColor3 = C.cream,
			AutoButtonColor = false,
			Text = "",
			Selectable = true,
			Parent = row,
		}) :: TextButton
		Theme.corner(16).Parent = b
		Theme.gloss(b, 1, 0.9)
		local stroke = Theme.stroke(info.color, 4)
		stroke.Parent = b
		Theme.hover(b, 1.03)
		local band = make("Frame", {
			Size = UDim2.new(1, 0, 0, 52),
			BackgroundColor3 = info.color,
			BorderSizePixel = 0,
			Parent = b,
		})
		Theme.corner(14).Parent = band
		Theme.gloss(band, 1, 0.75)
		Theme.icon(info.icon, 34, C.white, { Position = UDim2.fromOffset(12, 9), Parent = band })
		local head = Theme.label({
			Position = UDim2.fromOffset(54, 0),
			Size = UDim2.new(1, -60, 1, 0),
			TextSize = T.heading + 2,
			TextColor3 = C.white,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = info.title,
			Parent = band,
		})
		Theme.textStroke(C.brownDark, 2).Parent = head
		local body = make("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, 58),
			Size = UDim2.new(1, 0, 1, -(58 + touch + 16)),
			Parent = b,
		})
		Theme.padding(12, 2).Parent = body
		Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = body
		-- Reward
		line(body, 1, "REWARD", T.micro, C.greenDark, Theme.FONT)
		local reward = line(body, 2, "", T.body + 1, C.ink, Theme.FONT)
		-- Risk + pips
		local riskRow = make("Frame", {
			LayoutOrder = 3,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 16),
			Parent = body,
		})
		Theme.list(
			Enum.FillDirection.Horizontal,
			4,
			Enum.HorizontalAlignment.Left,
			Enum.VerticalAlignment.Center
		).Parent =
			riskRow
		Theme.label({
			LayoutOrder = 0,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 16),
			TextSize = T.micro,
			TextColor3 = C.red,
			TextWrapped = false,
			Text = "RISK ",
			Parent = riskRow,
		})
		local pips: { Frame } = {}
		for p = 1, 3 do
			local pip = make("Frame", {
				LayoutOrder = p,
				Size = UDim2.fromOffset(18, 8),
				BackgroundColor3 = if p <= info.risk then C.red else C.creamDark,
				Parent = riskRow,
			}) :: Frame
			Theme.corner(4).Parent = pip
			pips[p] = pip
		end
		line(body, 4, info.riskText, T.caption, C.brown)
		line(body, 5, info.body, T.caption, C.ink)
		-- Footer: votes + pick
		local footer = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -8),
			Size = UDim2.new(1, -16, 0, touch),
			BackgroundColor3 = info.color,
			Parent = b,
		})
		Theme.corner(12).Parent = footer
		Theme.gloss(footer, 1, 0.8)
		local votes = Theme.label({
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(0.45, -12, 1, 0),
			TextSize = T.heading,
			TextColor3 = C.white,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "0 votes",
			Parent = footer,
		})
		Theme.textStroke(C.brownDark, 1.5).Parent = votes
		local pick = Theme.label({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 0),
			Size = UDim2.new(0.55, -10, 1, 0),
			TextSize = T.body,
			TextColor3 = C.white,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = "Vote",
			Parent = footer,
		})
		Theme.textStroke(C.brownDark, 1.5).Parent = pick
		b.Activated:Connect(function()
			local e = State.get("extract")
			if type(e) == "table" and not e.closed then
				State.castExtract(key)
			end
		end)
		views[key] = { button = b, stroke = stroke, reward = reward, votes = votes, pick = pick, pips = pips }
	end

	local shown: any = nil
	local hideToken = 0

	local function render(e: any)
		if type(e) ~= "table" then
			if
				panel.Visible
				and GuiService.SelectedObject
				and GuiService.SelectedObject:IsDescendantOf(panel)
			then
				GuiService.SelectedObject = nil
			end
			panel.Visible = false
			shown = nil
			return
		end
		local sq = State.squad(State.mySquad())
		local pot = if sq then sq.pending else tonumber((State.get("run") or {}).pendingCheese) or 0
		local extracted = 0
		local match = State.get("match")
		if type(match) == "table" then
			for _, s in match.squads do
				if s.extracted then
					extracted += 1
				end
			end
		end
		local brave = extracted >= 2
		local mine = e.myPick or e.yourChoice
		local total = 0
		for _, n in e.votes do
			total += n
		end
		local size = math.max(e.squadSize or 0, if sq then #sq.members else 3, total)
		for _, key in ORDER do
			local v = views[key]
			local offered = table.find(e.options, key) ~= nil
			v.button.Visible = offered
			v.reward.Text = INFO[key].reward(pot, brave)
			local n = e.votes[key] or 0
			v.votes.Text = string.format("%d / %d", n, size)
			local chosen = e.closed and (e.result == key)
			if chosen then
				v.pick.Text = "CHOSEN!"
			elseif mine == key then
				v.pick.Text = "★ YOUR PICK"
			else
				v.pick.Text = if e.closed
					then ""
					elseif Device.mode() == "touch" then "Tap to vote"
					else "Click to vote"
			end
			v.stroke.Thickness = if mine == key or chosen then 8 else 4
			v.stroke.Color = if chosen then C.gold elseif mine == key then C.brownDark else INFO[key].color
			v.button.BackgroundColor3 = if mine == key or chosen then C.goldLight else C.cream
			v.button.Active = not e.closed
		end
		sub.Text = if brave
			then "2+ squads have extracted: staying earns the +25% brave bonus!"
			else "Your squad votes. Majority decides; 🤖 bots follow their humans."
		if e ~= shown then
			local fresh = shown == nil
			shown = e
			if fresh then
				panel.Visible = true
				Theme.popIn(panel)
				local ok, Onboarding = pcall(require, script.Parent.Onboarding)
				if ok and type(Onboarding.extractSeen) == "function" then
					pcall(Onboarding.extractSeen)
				end
				if Device.mode() == "gamepad" then
					GuiService.SelectedObject = views.Extract.button
				end
			end
		end
		panel.Visible = true
		if e.closed then
			hideToken += 1
			local token = hideToken
			task.delay(1.6, function()
				if token == hideToken and State.get("extract") == e then
					State.set("extract", nil)
				end
			end)
		end
	end

	table.insert(unsubs, State.subscribe("extract", render, true))

	renderConn = RunService.RenderStepped:Connect(function()
		local e = shown
		if not e or not panel.Visible then
			return
		end
		if e.closed then
			timer.Text = "Decided!"
			return
		end
		local endsAt = tonumber(e.endsAt)
		if not endsAt then
			timer.Text = ""
			return
		end
		local rem = endsAt - State.serverNow()
		if rem < -2 then
			State.set("extract", nil) -- the server never closed it: don't leave it stuck
			return
		end
		timer.Text = "⏱ " .. Format.clock(math.max(0, rem))
		timer.TextColor3 = if rem <= 5 then C.red else C.cream
		timeBar.set(math.clamp(rem / WINDOW, 0, 1))
	end)
end

function ExtractUI.destroy()
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

return ExtractUI
