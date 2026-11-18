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
-- v3 compact: small single-line cards (full details in each card's tooltip).
-- On PC the vote STARTS minimised as a slim bar top-centre (slot 2 under the
-- header); hovering it opens the cards in place (they fold ~0.6 s after the
-- pointer leaves), clicking "Open" keeps them open, "▾" folds them. Touch and
-- gamepad start open (phones: bottom-centre, above the level-up strip).
-- Sizes: Util/UiSizes.vote.
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
local UiSizes = require(Client.Util.UiSizes)
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
local bar: Frame? = nil
local barText: TextLabel? = nil
local minimised = false
local OPEN_SECONDS = 4 -- iteration 1 #16: decisions open full-size this long
local hoverOpened = false
local lastOver = 0
local barCaption = "🗳 Vote"

local BANK_TEXT: { [string]: { title: string, body: string, color: Color3, icon: string } } = {
	Continue = {
		title = "Continue",
		body = "Next stage with normal rewards. Your pending cheese stays pending.",
		color = Theme.TIER.Low,
		icon = "➡️",
	},
	DoubleOrNothing = {
		title = "Double or Nothing ×2",
		body = "Your pot ×2 ONLY if your squad survives the stage and kills a champion or the boss.\n⚠ Otherwise ALL pending cheese is lost.",
		color = Theme.TIER.High,
		icon = "🎲",
	},
	GoHome = {
		title = "Extract — bank 100%",
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

local dense = false
local V: any = UiSizes.vote(false, 70, 70)

local function clearOptions()
	for _, v in views do
		v.button:Destroy()
	end
	table.clear(views)
end

-- One single-line text row on a card (full text lives in the card tooltip).
local function line(
	parent: Instance,
	y: number,
	h: number,
	text: string,
	size: number,
	color: Color3?,
	font: Enum.Font?
): TextLabel
	return Theme.label({
		Position = UDim2.fromOffset(10, y),
		Size = UDim2.new(1, -20, 0, h),
		Text = text,
		TextSize = size,
		TextColor3 = color or C.ink,
		Font = font or Theme.FONT_BODY,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = parent,
	})
end

local function optionShell(index: number, width: number, accent: Color3, tip: string): (TextButton, UIStroke)
	local button = make("TextButton", {
		Name = "Option" .. index,
		LayoutOrder = index,
		Size = UDim2.fromOffset(width, V.cardH),
		BackgroundColor3 = C.cream,
		AutoButtonColor = false,
		Text = "",
		Selectable = true,
		Parent = optionRow,
	}) :: TextButton
	Theme.corner(12).Parent = button
	Theme.gloss(button, 1, 0.9)
	local stroke = Theme.stroke(accent, 3)
	stroke.Parent = button
	Theme.hover(button, 1.03)
	if tip ~= "" then
		Theme.tooltip(button, tip)
	end
	local band = make("Frame", {
		BackgroundColor3 = accent,
		Size = UDim2.new(1, 0, 0, V.bandH),
		BorderSizePixel = 0,
		Parent = button,
	})
	Theme.corner(10).Parent = band
	Theme.gloss(band, 1, 0.75)
	return button, stroke
end

local function footer(button: TextButton): (TextLabel, TextLabel)
	local tally = Theme.label({
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -6),
		Size = UDim2.new(0.45, -10, 0, V.footerH),
		TextSize = V.tallyText,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		Text = "🗳 0",
		Parent = button,
	})
	local pick = Theme.label({
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -8, 1, -6),
		Size = UDim2.new(0.55, -8, 0, V.footerH),
		TextSize = V.pickText,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
		Parent = button,
	})
	return tally, pick
end

local function buildRouteCard(index: number, card: any): OptionView
	local tier = tostring(card.tier or "Low")
	local accent = Theme.TIER[tier] or C.cheese
	local map = Defs.get("Maps", card.mapId)
	local mapName = Defs.name(map, card.mapId)
	if map and map.cheese then
		mapName ..= " (" .. tostring(map.cheese) .. ")"
	end
	local boss = Defs.get("Bosses", card.bossId)
	local curse = if card.curseId then Defs.get("Modifiers", card.curseId) else nil
	local blessing = if card.blessingId then Defs.get("Modifiers", card.blessingId) else nil
	local duration = if tier == "High" then "whole run" else "this stage"
	-- Tooltip: the full details the compact card leaves out.
	local tip = { (TIER_TITLE[tier] or tier) .. ": " .. mapName, "Boss: " .. Defs.name(boss, card.bossId) }
	if curse then
		table.insert(
			tip,
			string.format(
				"Curse (%s): %s. %s",
				duration,
				Defs.name(curse, card.curseId),
				tostring(curse.description or "")
			)
		)
	end
	if blessing then
		table.insert(
			tip,
			string.format(
				"Blessing: %s. %s",
				Defs.name(blessing, card.blessingId),
				tostring(blessing.description or "")
			)
		)
	end
	local button, stroke = optionShell(index, V.routeW, accent, table.concat(tip, "\n"))
	local head = Theme.label({
		Size = UDim2.new(1, 0, 0, V.bandH),
		TextSize = V.bandText,
		Text = TIER_TITLE[tier] or string.upper(tier),
		TextColor3 = C.white,
		TextWrapped = false,
		Parent = button,
	})
	Theme.textStroke().Parent = head

	local y = V.lineY
	line(button, y, V.mapH, "🗺 " .. mapName, V.mapText, C.ink, Theme.FONT)
	y += V.mapH
	line(button, y, V.lineH, "👑 " .. Defs.name(boss, card.bossId), V.lineText)
	y += V.lineH
	if card.curseId then
		line(
			button,
			y,
			V.lineH,
			-- iteration 1 #16: the effect inline, not only in the tooltip
			string.format(
				"☠ %s (%s)%s",
				Defs.name(curse, card.curseId),
				duration,
				if curse and curse.description then ": " .. tostring(curse.description) else ""
			),
			V.lineText,
			C.red
		)
	else
		line(button, y, V.lineH, "☠ No curse", V.lineText, C.green)
	end
	y += V.lineH
	if card.blessingId then
		line(
			button,
			y,
			V.lineH,
			"✨ "
				.. Defs.name(blessing, card.blessingId)
				.. (if blessing and blessing.description then ": " .. tostring(blessing.description) else ""),
			V.lineText,
			Color3.fromRGB(40, 130, 50)
		)
	end
	y += V.lineH
	line(
		button,
		y,
		V.rewardH,
		"🧀 Reward " .. Format.mult(card.rewardMult),
		V.rewardText,
		C.ink,
		Theme.FONT
	)
	y += V.rewardH
	local extras = {}
	if card.cleanse == true then
		table.insert(extras, "🧼 Cleanse")
	end
	local epic = tonumber(card.epicChance) or 0
	if epic > 0 then
		table.insert(extras, "💎 Epic " .. Format.pct(epic))
	end
	if #extras > 0 then
		line(button, y, V.extraH, table.concat(extras, " · "), V.extraText, C.purple)
	end

	local tally, pick = footer(button)
	return { button = button, stroke = stroke, tally = tally, pick = pick }
end

local function buildChoiceCard(index: number, option: string): OptionView
	local info = BANK_TEXT[option] or { title = tostring(option), body = "", color = C.cheese, icon = "🧀" }
	local button, stroke = optionShell(index, V.choiceW, info.color, info.body)
	local head = Theme.label({
		Size = UDim2.new(1, 0, 0, V.bandH),
		TextSize = V.bandText,
		Text = info.icon .. " " .. info.title,
		TextColor3 = C.white,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = button,
	})
	Theme.textStroke().Parent = head
	Theme.label({
		Position = UDim2.fromOffset(10, V.lineY),
		Size = UDim2.new(1, -20, 0, V.bodyH),
		Text = info.body,
		TextSize = V.bodyText,
		TextColor3 = C.ink,
		Font = Theme.FONT_BODY,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = button,
	})
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
			line(button, V.lineY + V.bodyH + 2, V.noteH, note, V.noteText, C.ink, Theme.FONT)
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
			v.stroke.Thickness = 5
		elseif mine then
			v.pick.Text = "⭐ YOUR PICK"
			v.stroke.Color = C.brownDark
			v.stroke.Thickness = 5
		else
			v.pick.Text = if vote.closed
				then ""
				elseif Device.mode() == "touch" then "Tap to vote"
				else "Click to vote"
			v.stroke.Thickness = 3
		end
		v.button.BackgroundColor3 = if mine or won then Color3.fromRGB(255, 236, 170) else C.cream
		v.button.Active = not vote.closed
	end
end

local function setMinimised(on: boolean)
	minimised = on
	hoverOpened = false
	local v = State.get("vote")
	local open = type(v) == "table" and shownVote ~= nil
	if panel then
		(panel :: Frame).Visible = open and not on
	end
	if bar then
		(bar :: Frame).Visible = open and on
	end
	if
		on
		and panel
		and GuiService.SelectedObject
		and GuiService.SelectedObject:IsDescendantOf(panel :: Frame)
	then
		GuiService.SelectedObject = nil
	end
end
VoteUI.setMinimised = setMinimised

local function hide()
	local p = panel
	if p then
		p.Visible = false
	end
	if bar then
		(bar :: Frame).Visible = false
	end
	minimised = false
	hoverOpened = false
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
			title.Text = "Cycle complete! Extract or go deeper?"
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
		row.Position = UDim2.fromOffset(0, V.cardsY + (if showHint then V.hintH else 0))
		row.Size = UDim2.new(1, 0, 1, -(V.cardsY + (if showHint then V.hintH else 0) + 4))
		row.CanvasPosition = Vector2.zero
		if unsubResize then
			unsubResize()
		end
		unsubResize = Theme.fitFrame(screen, p, V.panelW, if showHint then V.panelHintH else V.panelH, 8)
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
		-- iteration 1 #16 (C-5): every device opens full-size; on PC it folds to
		-- the slim bar after OPEN_SECONDS unless the pointer is over it.
		minimised = false
		hoverOpened = false
		local openedFor = vote
		task.delay(OPEN_SECONDS, function()
			local cur = State.get("vote")
			if cur ~= openedFor or minimised or Device.mode() ~= "kbm" then
				return
			end
			local pp = panel
			if pp and Theme.pointerOver(pp) then
				hoverOpened = true -- leaving it folds it, as a hover-open does
				return
			end
			setMinimised(true)
		end)
		if minimised and bar then
			p.Visible = false
			(bar :: Frame).Visible = true
			Theme.popIn(bar :: Frame)
		else
			p.Visible = true
			if bar then
				(bar :: Frame).Visible = false
			end
			Theme.popIn(p)
		end
		if Device.mode() == "gamepad" and views[1] then
			GuiService.SelectedObject = views[1].button
		end
	end
	updateTallies(vote)
	-- your vote is in: fold to the slim bar (the tally stays readable there)
	if vote.myPick and not vote.closed and not minimised and Device.mode() == "kbm" and hoverOpened then
		setMinimised(true)
	end
	local btl = barText
	if btl then
		local mine = vote.myPick and views[vote.myPick]
		local kind = tostring(vote.kind)
		local what = if kind == "route" then "Route vote" elseif kind == "bank" then "Bank vote" else "Vote"
		barCaption = "🗳 "
			.. what
			.. (if vote.closed then " · decided" elseif mine then " · voted" else " · vote now")
		btl.Text = barCaption
	end
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
	local touch = Theme.TOUCH
	dense = Theme.dense()
	V = UiSizes.vote(dense, touch, Theme.SLIM)
	-- PC: bar + panel top-centre in slot 2 (open in place). Phones: bottom.
	local topY = UiSizes.barSlotY(dense, touch, Theme.SLIM, 2)
	local hud = UiSizes.hud(dense, touch)
	local baseBottom = hud.rowH + hud.bottomY + 12
	local function place(obj: GuiObject, lift: number)
		if dense then
			obj.AnchorPoint = Vector2.new(0.5, 0)
			obj.Position = UDim2.new(0.5, 0, 0, topY)
		else
			obj.AnchorPoint = Vector2.new(0.5, 1)
			obj.Position = UDim2.new(0.5, 0, 1, -(baseBottom + lift))
		end
	end
	local p = Theme.card({
		Name = "VotePanel",
		Size = UDim2.fromOffset(V.panelW, V.panelH),
		Visible = false,
		Parent = screen.root,
	}, { stroke = 2 })
	place(p, 0)
	unsubResize = Theme.fitFrame(screen, p, V.panelW, V.panelH, 8)
	panel = p
	local tabW = if V.tabInside then V.slim else touch
	local title = Theme.label({
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -(tabW + 140), 0, V.headH),
		TextSize = V.titleText,
		TextColor3 = C.cheese,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = p,
	})
	Theme.textStroke().Parent = title
	titleLabel = title
	local timer = Theme.label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(tabW + 16), 0, 0),
		Size = UDim2.fromOffset(110, V.headH),
		TextSize = V.timerText,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextWrapped = false,
		Parent = p,
	})
	Theme.textStroke().Parent = timer
	timerLabel = timer
	local hint = Theme.label({
		Position = UDim2.fromOffset(14, V.headH),
		Size = UDim2.new(1, -28, 0, V.hintH),
		TextSize = V.hintText,
		Font = Theme.FONT_BODY,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = true,
		Visible = false,
		Parent = p,
	})
	make("UITextSizeConstraint", { MaxTextSize = V.hintText, MinTextSize = 11, Parent = hint })
	hintLabel = hint
	Theme.button("▾", C.brown, {
		Name = "MinimiseVote",
		AnchorPoint = Vector2.new(1, if V.tabInside then 0.5 else 0.6),
		Position = if V.tabInside then UDim2.new(1, -6, 0, V.headH / 2) else UDim2.new(1, -8, 0, 0),
		Size = UDim2.fromOffset(tabW, tabW),
		TextSize = if V.tabInside then 18 else 26,
		TextColor3 = C.white,
		ZIndex = 4,
		Parent = p,
	}, function()
		setMinimised(true)
	end)
	-- Cards keep their size; if the capped panel is too small they scroll.
	local row = Theme.scroller({
		Name = "Options",
		Position = UDim2.fromOffset(0, V.cardsY),
		Size = UDim2.new(1, 0, 1, -(V.cardsY + 4)),
		ScrollingDirection = Enum.ScrollingDirection.XY,
		AutomaticCanvasSize = Enum.AutomaticSize.XY,
		ScrollBarImageColor3 = C.cheese,
		ScrollBarThickness = 6,
		Parent = p,
	})
	Theme.list(
		Enum.FillDirection.Horizontal,
		V.gap,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Top
	).Parent =
		row
	optionRow = row

	-- Slim bar (minimised vote): what is being voted + Open.
	local b = Theme.card({
		Name = "VoteBar",
		Size = UDim2.fromOffset(V.barW, V.barH),
		Visible = false,
		Parent = screen.root,
	}, { stroke = 2, accent = C.cheese })
	place(b, 0)
	bar = b
	local bt = Theme.label({
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -(V.openW + 28), 1, 0),
		TextSize = V.barText,
		TextColor3 = C.cream,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "🗳 Vote",
		Parent = b,
	})
	Theme.textStroke(C.shade, 1.5).Parent = bt
	barText = bt
	Theme.button("▴ Open", C.cheese, {
		Name = "OpenVote",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(V.openW, V.slim),
		TextSize = V.barText,
		Parent = b,
	}, function()
		setMinimised(false)
	end)
	b.MouseEnter:Connect(function()
		if Device.mode() ~= "kbm" or not b.Visible then
			return
		end
		setMinimised(false)
		hoverOpened = true
		lastOver = os.clock()
	end)

	-- Phones: keep the open panel above the level-up strip.
	local function upgradeLift(): number
		local gui = screen and screen.gui
		local pg = gui and gui.Parent
		local up = pg and pg:FindFirstChild("TrunkfallUpgrades")
		local strip = up and up:FindFirstChild("UpgradePanel", true)
		local shownStrip = strip ~= nil and strip:IsA("GuiObject") and strip.Visible
		local rootH = if screen then screen.rootSize().Y else 620
		return UiSizes.stackLift(dense, touch, rootH, p.Size.Y.Offset, shownStrip)
	end

	-- Route chosen by another squad: a slim banner, no cards.
	local waitCard = Theme.card({
		Name = "RouteChooser",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, if dense then topY else UiSizes.underHeader(dense, touch)),
		Size = UDim2.fromOffset(V.chooserW, V.chooserH),
		Visible = false,
		Parent = screen.root,
	})
	local waitStripe = make("Frame", {
		Size = UDim2.new(0, 6, 1, 0),
		BackgroundColor3 = C.cheese,
		BorderSizePixel = 0,
		Parent = waitCard,
	})
	Theme.corner(6).Parent = waitStripe
	Theme.icon(
		"crown",
		V.chooserIcon,
		C.gold,
		{ Position = UDim2.fromOffset(14, (V.chooserH - V.chooserIcon) // 2), Parent = waitCard }
	)
	local textX = V.chooserIcon + 24
	local waitText = Theme.label({
		Position = UDim2.fromOffset(textX, if dense then 3 else 6),
		Size = UDim2.new(1, -(textX + 10), 0, V.chooserText + 6),
		TextSize = V.chooserText,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = waitCard,
	})
	Theme.textStroke(C.shade, 1.5).Parent = waitText
	Theme.label({
		Position = UDim2.fromOffset(textX, V.chooserText + (if dense then 9 else 14)),
		Size = UDim2.new(1, -(textX + 10), 0, V.chooserSubText + 4),
		TextSize = V.chooserSubText,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
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
		if not dense then
			local lift = upgradeLift()
			place(p, lift)
			place(b, lift)
		end
		if hoverOpened and p.Visible then
			if Theme.pointerOver(p) then
				lastOver = os.clock()
			elseif os.clock() - lastOver > 0.6 then
				setMinimised(true)
			end
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
			if b.Visible then
				bt.Text = barCaption .. " · ⏱ " .. Format.clock(math.max(0, rem))
			end
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
	bar = nil
	barText = nil
end

return VoteUI
