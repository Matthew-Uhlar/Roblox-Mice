--!strict
-- Party votes (Net.S2C.VoteOpen / VoteTally / VoteClosed -> State "vote").
--   route: 3 RouteCards (Low green / Mid yellow / High red) with map, boss,
--          curse (+ duration), blessing, reward mult, cleanse and epic chance.
--   bank:  "Continue" / "DoubleOrNothing" with a risk explainer.
--   cycle: "GoHome" / "NextCycle".
-- Live tallies (dense array from the server), a countdown and your own pick
-- highlighted. Clicking sends Net.C2S.Vote(optionIndex).
-- The panel is capped to the screen and the cards scroll if they don't fit.
-- New players get a one-line explainer on their first route vote (Onboarding).
-- v2 (squads): VoteOpen kind "route" only reaches the squad that won the boss,
-- titled "Your squad won the boss! Choose the next route"; every other squad
-- sees a small banner "<Squad> is choosing the route…" from Match.routeChooser.

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local Device = require(Client.Util.Device)
local State = require(Client.Controllers.State)
local Onboarding = require(script.Parent.Onboarding)

local VoteUI = {}

local C = Theme.C
local make = Theme.make

type OptionView = {
	button: TextButton,
	stroke: UIStroke,
	tally: TextLabel,
	pick: TextLabel,
}

local screen: any = nil
local panel: Frame? = nil
local titleLabel: TextLabel? = nil
local timerLabel: TextLabel? = nil
local hintLabel: TextLabel? = nil
local optionRow: ScrollingFrame? = nil
local unsubResize: (() -> ())? = nil
local views: { OptionView } = {}
local shownVote: any = nil
local unsub: (() -> ())? = nil
local renderConn: RBXScriptConnection? = nil
local hideToken = 0
local chooserUnsubs: { () -> () } = {}

local BANK_TEXT: { [string]: { title: string, body: string, color: Color3, icon: string } } = {
	Continue = {
		title = "Continue",
		body = "Next stage with normal rewards. Your pending cheese stays pending.",
		color = Theme.TIER.Low,
		icon = "➡️",
	},
	DoubleOrNothing = {
		title = "Double or Nothing ×2",
		body = "Next stage rewards ×2 AND the pending pot ×1.5 if you win.\n⚠ If the party wipes, ALL pending cheese is lost.",
		color = Theme.TIER.High,
		icon = "🎲",
	},
	GoHome = {
		title = "Go Home — bank 100%",
		body = "End the run as a WIN and bank every pending cheese. Safe and sound.",
		color = Theme.TIER.Low,
		icon = "🏠",
	},
	NextCycle = {
		title = "Next Cycle",
		body = "Bank 50% now, carry the rest. Harder mice, bigger rewards.",
		color = Theme.TIER.High,
		icon = "🔥",
	},
}

local TIER_TITLE: { [string]: string } = { Low = "LOW RISK", Mid = "MID RISK", High = "HIGH RISK" }

local function clearOptions()
	for _, v in views do
		v.button:Destroy()
	end
	table.clear(views)
end

local function line(
	parent: Instance,
	order: number,
	text: string,
	size: number?,
	color: Color3?,
	font: Enum.Font?
): TextLabel
	return Theme.label({
		LayoutOrder = order,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		Text = text,
		TextSize = size or 16,
		TextColor3 = color or C.ink,
		Font = font or Theme.FONT_BODY,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = parent,
	})
end

local function optionShell(
	index: number,
	width: number,
	height: number,
	accent: Color3
): (TextButton, UIStroke, Frame)
	local button = make("TextButton", {
		Name = "Option" .. index,
		LayoutOrder = index,
		Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = C.cream,
		AutoButtonColor = false,
		Text = "",
		Selectable = true,
		Parent = optionRow,
	}) :: TextButton
	Theme.corner(16).Parent = button
	Theme.gloss(button, 1, 0.9)
	local stroke = Theme.stroke(accent, 5)
	stroke.Parent = button
	Theme.hover(button, 1.03)
	local band = make("Frame", {
		BackgroundColor3 = accent,
		Size = UDim2.new(1, 0, 0, 46),
		BorderSizePixel = 0,
		Parent = button,
	})
	Theme.corner(14).Parent = band
	Theme.gloss(band, 1, 0.75)
	local body = make("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 50),
		Size = UDim2.new(1, 0, 1, -100),
		Parent = button,
	})
	Theme.padding(12, 4).Parent = body
	Theme.list(Enum.FillDirection.Vertical, 5, Enum.HorizontalAlignment.Left).Parent = body
	return button, stroke, body
end

local function footer(button: TextButton): (TextLabel, TextLabel)
	local tally = Theme.label({
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -8),
		Size = UDim2.new(0.5, -12, 0, 34),
		TextSize = 22,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "🗳 0",
		Parent = button,
	})
	local pick = Theme.label({
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -10, 1, -8),
		Size = UDim2.new(0.55, 0, 0, 34),
		TextSize = 18,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
		Parent = button,
	})
	return tally, pick
end

local function buildRouteCard(index: number, card: any): OptionView
	local tier = tostring(card.tier or "Low")
	local accent = Theme.TIER[tier] or C.cheese
	local button, stroke, body = optionShell(index, 292, 380, accent)
	local head = Theme.label({
		Size = UDim2.new(1, 0, 0, 46),
		TextSize = 24,
		Text = TIER_TITLE[tier] or string.upper(tier),
		TextColor3 = C.white,
		Parent = button,
	})
	Theme.textStroke().Parent = head

	local map = Defs.get("Maps", card.mapId)
	local mapName = Defs.name(map, card.mapId)
	if map and map.cheese then
		mapName ..= " (" .. tostring(map.cheese) .. ")"
	end
	line(body, 1, "🗺 " .. mapName, 20, C.ink, Theme.FONT)
	local boss = Defs.get("Bosses", card.bossId)
	line(body, 2, "👑 Boss: " .. Defs.name(boss, card.bossId), 17)

	if card.curseId then
		local curse = Defs.get("Modifiers", card.curseId)
		local duration = if tier == "High" then "whole run" else "this stage"
		line(body, 3, string.format("☠ %s (%s)", Defs.name(curse, card.curseId), duration), 16, C.red)
		if curse and curse.description then
			line(body, 4, tostring(curse.description), 13, C.brown)
		end
	else
		line(body, 3, "☠ No curse", 16, C.green)
	end
	if card.blessingId then
		local blessing = Defs.get("Modifiers", card.blessingId)
		line(body, 5, "✨ " .. Defs.name(blessing, card.blessingId), 16, Color3.fromRGB(40, 130, 50))
		if blessing and blessing.description then
			line(body, 6, tostring(blessing.description), 13, C.brown)
		end
	end
	line(body, 7, "🧀 Reward " .. Format.mult(card.rewardMult), 19, C.ink, Theme.FONT)
	if card.cleanse == true then
		line(body, 8, "🧼 Cleanse: removes a run-long curse", 15, C.blue)
	end
	local epic = tonumber(card.epicChance) or 0
	if epic > 0 then
		line(body, 9, "💎 Epic drop chance " .. Format.pct(epic), 15, C.purple)
	end

	local tally, pick = footer(button)
	return { button = button, stroke = stroke, tally = tally, pick = pick }
end

local function buildChoiceCard(index: number, option: string): OptionView
	local info = BANK_TEXT[option] or { title = tostring(option), body = "", color = C.cheese, icon = "🧀" }
	local button, stroke, body = optionShell(index, 400, 260, info.color)
	local head = Theme.label({
		Size = UDim2.new(1, 0, 0, 46),
		TextSize = 24,
		Text = info.icon .. " " .. info.title,
		TextColor3 = C.white,
		Parent = button,
	})
	Theme.textStroke().Parent = head
	line(body, 1, info.body, 17)
	local run = State.get("run")
	if type(run) == "table" then
		local pending = tonumber(run.pendingCheese) or 0
		local note = ""
		if option == "DoubleOrNothing" then
			note = string.format("At stake: 🧀 %s pending", Format.int(pending))
		elseif option == "GoHome" then
			note = string.format("Bank now: 🧀 %s", Format.int(pending))
		elseif option == "NextCycle" then
			note = string.format("Bank now: 🧀 %s", Format.int(math.floor(pending * 0.5)))
		end
		if note ~= "" then
			line(body, 2, note, 18, C.ink, Theme.FONT)
		end
	end
	local tally, pick = footer(button)
	return { button = button, stroke = stroke, tally = tally, pick = pick }
end

local function updateTallies(vote: any)
	for i, v in views do
		local n = tonumber(vote.tally and vote.tally[i]) or 0
		v.tally.Text = "🗳 " .. tostring(n) .. (if n == 1 then " vote" else " votes")
		local mine = vote.myPick == i
		local won = vote.closed and vote.winner == i
		if won then
			v.pick.Text = "✅ CHOSEN!"
			v.stroke.Color = C.green
			v.stroke.Thickness = 8
		elseif mine then
			v.pick.Text = "⭐ YOUR PICK"
			v.stroke.Color = C.brownDark
			v.stroke.Thickness = 8
		else
			v.pick.Text = if vote.closed then "" else "Tap to vote"
			v.stroke.Thickness = 5
		end
		v.button.BackgroundColor3 = if mine or won then Color3.fromRGB(255, 236, 170) else C.cream
		v.button.Active = not vote.closed
	end
end

local function hide()
	local p = panel
	if p then
		p.Visible = false
	end
	shownVote = nil
	clearOptions()
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(screen.gui) then
		GuiService.SelectedObject = nil
	end
end

local function render(vote: any)
	local p = panel
	if not p then
		return
	end
	if type(vote) ~= "table" then
		hide()
		return
	end
	if vote ~= shownVote then
		hideToken += 1
		clearOptions()
		shownVote = vote
		local kind = tostring(vote.kind)
		local title = titleLabel :: TextLabel
		if kind == "route" then
			local run = State.get("run")
			local firstStage = type(run) == "table"
				and (tonumber(run.cycle) or 1) == 1
				and (tonumber(run.stageInCycle) or 1) == 1
			title.Text = if State.isSquadMatch() and not firstStage
				then "Your squad won the boss! Choose the next route"
				elseif firstStage then "Pick your first map!"
				else "Choose your route!"
		elseif kind == "bank" then
			title.Text = "Bank it… or Double or Nothing?"
		elseif kind == "cycle" then
			title.Text = "Cycle complete! Go home or go deeper?"
		else
			title.Text = "Vote!"
		end
		local hint = hintLabel :: TextLabel
		local row = optionRow :: ScrollingFrame
		local showHint = kind == "route" and Onboarding.claim("route")
		hint.Visible = showHint
		if showHint then
			hint.Text = if Device.mode() == "touch"
				then "Tap a card to vote. 🟢 Low = safe · 🔴 High = harder mice, more 🧀"
				else "Click a card to vote. 🟢 Low = safe · 🔴 High = harder mice, more 🧀"
		end
		row.Position = UDim2.fromOffset(0, if showHint then 88 else 60)
		row.Size = UDim2.new(1, 0, 1, if showHint then -96 else -68)
		row.CanvasPosition = Vector2.zero
		for i, opt in vote.options do
			local v: OptionView
			if type(opt) == "table" then
				v = buildRouteCard(i, opt)
			else
				v = buildChoiceCard(i, tostring(opt))
			end
			v.button.Activated:Connect(function()
				local cur = State.get("vote")
				if cur and not cur.closed then
					State.castVote(i)
				end
			end)
			table.insert(views, v)
		end
		p.Visible = true
		Theme.popIn(p)
		if Device.mode() == "gamepad" and views[1] then
			GuiService.SelectedObject = views[1].button
		end
	end
	updateTallies(vote)
	if vote.closed then
		hideToken += 1
		local token = hideToken
		task.delay(1.6, function()
			if token == hideToken and State.get("vote") == vote then
				hide()
			end
		end)
	end
end

function VoteUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallVote", 30)
	local p = Theme.card({
		Name = "VotePanel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.56),
		Size = UDim2.fromOffset(960, 480),
		Visible = false,
		Parent = screen.root,
	}, { stroke = 3 })
	unsubResize = Theme.fitFrame(screen, p, 960, 480, 8)
	panel = p
	local title = Theme.label({
		Position = UDim2.fromOffset(20, 10),
		Size = UDim2.new(1, -200, 0, 40),
		TextSize = 32,
		TextColor3 = C.cheese,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = p,
	})
	Theme.textStroke().Parent = title
	titleLabel = title
	local timer = Theme.label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -20, 0, 10),
		Size = UDim2.fromOffset(170, 40),
		TextSize = 30,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = p,
	})
	Theme.textStroke().Parent = timer
	timerLabel = timer
	local hint = Theme.label({
		Position = UDim2.fromOffset(20, 54),
		Size = UDim2.new(1, -40, 0, 28),
		TextSize = 18,
		Font = Theme.FONT_BODY,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = true,
		Visible = false,
		Parent = p,
	})
	make("UITextSizeConstraint", { MaxTextSize = 18, MinTextSize = 12, Parent = hint })
	hintLabel = hint
	-- Cards keep their size; if the capped panel is too small they scroll.
	local row = Theme.scroller({
		Name = "Options",
		Position = UDim2.fromOffset(0, 60),
		Size = UDim2.new(1, 0, 1, -68),
		ScrollingDirection = Enum.ScrollingDirection.XY,
		AutomaticCanvasSize = Enum.AutomaticSize.XY,
		ScrollBarImageColor3 = C.cheese,
		ScrollBarThickness = 8,
		Parent = p,
	})
	Theme.list(Enum.FillDirection.Horizontal, 18, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top).Parent =
		row
	optionRow = row

	-- Route chosen by another squad: a slim banner, no cards.
	local waitCard = Theme.card({
		Name = "RouteChooser",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 300),
		Size = UDim2.fromOffset(520, 64),
		Visible = false,
		Parent = screen.root,
	})
	local waitStripe = make("Frame", {
		Size = UDim2.new(0, 8, 1, 0),
		BackgroundColor3 = C.cheese,
		BorderSizePixel = 0,
		Parent = waitCard,
	})
	Theme.corner(6).Parent = waitStripe
	Theme.icon("crown", 34, C.gold, { Position = UDim2.fromOffset(18, 15), Parent = waitCard })
	local waitText = Theme.label({
		Position = UDim2.fromOffset(62, 6),
		Size = UDim2.new(1, -72, 0, 30),
		TextSize = Theme.TYPE.heading,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = waitCard,
	})
	Theme.textStroke(C.shade, 1.5).Parent = waitText
	Theme.label({
		Position = UDim2.fromOffset(62, 36),
		Size = UDim2.new(1, -72, 0, 20),
		TextSize = Theme.TYPE.caption,
		Font = Theme.FONT_BODY,
		TextColor3 = C.textDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "They won the boss, so they pick the next route for everyone.",
		Parent = waitCard,
	})
	local function renderChooser()
		local m = State.get("match")
		local chooser = if type(m) == "table" then m.routeChooser else nil
		local v = State.get("vote")
		local voting = type(v) == "table" and v.kind == "route" and not v.closed
		local show = chooser ~= nil and chooser ~= State.mySquad() and not voting
		if show and not waitCard.Visible then
			Theme.popIn(waitCard)
		end
		waitCard.Visible = show
		if show then
			local sq = State.squad(chooser)
			local name, col = Theme.squad(chooser)
			if sq then
				name, col = sq.name, Color3.fromRGB(sq.color[1], sq.color[2], sq.color[3])
			end
			waitText.Text = name .. " is choosing the route…"
			waitText.TextColor3 = col:Lerp(C.white, 0.3)
			waitStripe.BackgroundColor3 = col
		end
	end
	chooserUnsubs = {
		State.subscribe("match", renderChooser, true),
		State.subscribe("vote", renderChooser),
	}

	unsub = State.subscribe("vote", render, true)
	renderConn = RunService.RenderStepped:Connect(function()
		local v = shownVote
		if not v or not timerLabel then
			return
		end
		if v.closed then
			timerLabel.Text = "Decided!"
			return
		end
		local endsAt = tonumber(v.endsAt)
		if endsAt then
			local rem = endsAt - State.serverNow()
			timerLabel.Text = "⏱ " .. Format.clock(rem)
			timerLabel.TextColor3 = if rem <= 5 then C.red else C.cream
		else
			timerLabel.Text = ""
		end
	end)
end

function VoteUI.destroy()
	for _, u in chooserUnsubs do
		u()
	end
	table.clear(chooserUnsubs)
	if unsub then
		unsub()
		unsub = nil
	end
	if unsubResize then
		unsubResize()
		unsubResize = nil
	end
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	clearOptions()
	if screen then
		screen.destroy()
		screen = nil
	end
	panel = nil
end

return VoteUI
