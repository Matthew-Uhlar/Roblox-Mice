--!strict
-- Extraction window (GDD-v2 §1.4): the Rind Gate is open for 20 s and each
-- squad decides by majority (bots follow their humans). Three cards, each
-- stating its risk and its reward in plain words:
--   Extract          bank your own share now (x Portal Charm) and leave with
--                    your rewards
--   Stay             next stage, your share keeps growing (+25% "brave" bonus
--                    when 2+ squads have already extracted)
--   Double or Nothing  stay; your share ×2 (v4: a champion or boss kill on that stage), lost if
--                    your squad is eliminated
-- Shows the squad's votes per card, your pick and a countdown bar.
-- PvP keeps going during the window (QC-B V2-m7), so the panel minimises to a
-- slim bar ("▾" button, and automatically once your vote is in); the bar
-- shows the timer and your pick, and "Open" brings the cards back.
-- v3 compact: small cards (full risk / body text in each card's tooltip), and
-- on PC the window STARTS minimised as the slim bar, top-centre under the
-- toasts; hovering the bar opens the cards (they fold again when the mouse
-- leaves), clicking it keeps them open. Touch starts open (compact). Sizes:
-- Util/UiSizes.extract. The panel sits above the level-up strip when both show.
-- Reads State "extract" (Net.S2C.Extract {endsAt, options, votes, yourChoice})
-- and "match" (pot, extracted squads). Sends Net.C2S.ExtractVote(choice).

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Format = require(Client.Util.Format)
local Device = require(Client.Util.Device)
local UiSizes = require(Client.Util.UiSizes)
local State = require(Client.Controllers.State)
local Progression = require(Client.Util.Progression)

local ExtractUI = {}

local C = Theme.C
local make = Theme.make

local WINDOW = 20

type Info = {
	title: string,
	icon: string,
	color: Color3,
	risk: number, -- 0..3 pips
	riskText: string,
	riskShort: string,
	reward: (share: number, brave: boolean, bank: number) -> string,
	body: string,
}

local INFO: { [string]: Info } = {
	Extract = {
		title = "Extract",
		icon = "portal",
		color = Theme.TIER.Low,
		risk = 0,
		riskText = "None. You leave safely now.",
		riskShort = "None: leave safely",
		reward = function(_share, _brave, bank)
			-- iteration 1 #16: a player who never extracted sees the first-extraction bonus
			local p = State.get("profile")
			local rk = if type(p) == "table" then p.rookie else nil
			local first = type(rk) == "table" and rk.firstExtractPaid == false
			return string.format("Bank 🧀 %s (your share)", Format.int(bank))
				.. (if first then " + FIRST EXTRACTION 🧀500 ✨50" else "")
		end,
		body = "Leave the run with your cheese and class XP (×1.5 XP for extracting). Gear stays behind.",
	},
	Stay = {
		title = "Stay",
		icon = "shield",
		color = Theme.TIER.Mid,
		risk = 2,
		riskText = "Enemy squads and a tougher stage. Fallen heroes drop 30% of their share.",
		riskShort = "Rivals + tougher stage",
		reward = function(_share, brave)
			return if brave
				then "Share keeps growing, +25% brave bonus!"
				else "Your share keeps growing next stage"
		end,
		body = "Fight on. Your pending cheese is not banked yet.",
	},
	DoubleOrNothing = {
		title = "Double or Nothing",
		icon = "star",
		color = Theme.TIER.High,
		risk = 3,
		riskText = "Your squad must survive this stage AND kill a champion or the boss. Otherwise the WHOLE pot is lost.",
		riskShort = "Wipe or no champion kill = lose ALL",
		reward = function(share)
			return string.format(
				"Pot ×2 → 🧀 %s if you survive + kill a champion or the boss",
				Format.int(math.floor(share * 2))
			)
		end,
		body = "Your pot doubles ONLY if your squad survives this stage and kills a champion or the boss. Fail either and the whole pot is gone. Cheese only, never Robux.",
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
	local dense = Theme.dense()
	local E = UiSizes.extract(dense, touch, Theme.SLIM)
	local CARD_W, CARD_H = E.cardW, E.cardH
	local PANEL_W, PANEL_H = E.panelW, E.panelH
	-- PC: the slim bar and the panel open in place top-centre (slot 1 under
	-- the header), so hovering the bar keeps the pointer on the cards. Phones:
	-- bottom-centre above the gear row and above the level-up strip.
	local topY = UiSizes.barSlotY(dense, touch, Theme.SLIM, 1)
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
	local panel = Theme.card({
		Name = "Extract",
		Size = UDim2.fromOffset(PANEL_W, PANEL_H),
		Visible = false,
		Parent = root,
	}, { stroke = 2 })
	place(panel, 0)
	table.insert(unsubs, Theme.fitFrame(screen, panel, PANEL_W, PANEL_H, 8))
	Theme.icon(
		"portal",
		E.headIcon,
		Color3.fromRGB(160, 120, 255),
		{ Position = UDim2.fromOffset(10, (E.headH - E.headIcon) // 2), Parent = panel }
	)
	local tabW = if E.tabInside then E.slim else touch
	local title = Theme.label({
		Position = UDim2.fromOffset(E.headIcon + 18, 0),
		Size = UDim2.new(1, -(E.headIcon + 18 + tabW + 110), 0, E.headH),
		TextSize = E.titleText,
		TextColor3 = C.gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "The Rind Gate is open!",
		Parent = panel,
	})
	Theme.textStroke(C.shade, 1.5).Parent = title
	local subText = "Your squad votes. Majority decides; 🤖 bots follow their humans."
	Theme.tooltip(title, function()
		return subText
	end)
	local timer = Theme.label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(tabW + 16), 0, 0),
		Size = UDim2.fromOffset(100, E.headH),
		TextSize = E.timerText,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextWrapped = false,
		Parent = panel,
	})
	Theme.textStroke(C.shade, 1.5).Parent = timer
	local timeBar = Theme.bar({
		Position = UDim2.fromOffset(E.pad, E.headH),
		Size = UDim2.new(1, -2 * E.pad, 0, E.timeBarH),
		Parent = panel,
	}, Color3.fromRGB(160, 120, 255))
	timeBar.text.Visible = false

	-- Slim bar (minimised panel): timer + your pick + Open; hover (PC) or
	-- click opens the cards in place.
	local minimised = false
	local hoverOpened = false
	local autoMinimisedFor: any = nil
	local barPick = "Your pick: not voted"
	local BAR_W, BAR_H = E.barW, E.barH
	local bar = Theme.card({
		Name = "ExtractBar",
		Size = UDim2.fromOffset(BAR_W, BAR_H),
		Visible = false,
		Parent = root,
	}, { stroke = 2, accent = Color3.fromRGB(160, 120, 255) })
	place(bar, 0)
	table.insert(unsubs, Theme.fitFrame(screen, bar, BAR_W, BAR_H, 8))
	local barText = Theme.label({
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -(E.openW + 28), 1, 0),
		TextSize = E.barText,
		TextColor3 = C.cream,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "🌀 Rind Gate",
		Parent = bar,
	})
	Theme.textStroke(C.shade, 1.5).Parent = barText
	local function setMinimised(on: boolean)
		minimised = on
		hoverOpened = false
		local e = State.get("extract")
		local open = type(e) == "table"
		panel.Visible = open and not on
		bar.Visible = open and on
		if on and GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(panel) then
			GuiService.SelectedObject = nil
		end
	end
	Theme.button("▴ Open", Color3.fromRGB(160, 120, 255), {
		Name = "OpenExtract",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(E.openW, E.slim),
		TextSize = E.barText,
		TextColor3 = C.white,
		Parent = bar,
	}, function()
		setMinimised(false)
	end)
	Theme.button("▾", C.brown, {
		Name = "MinimiseExtract",
		AnchorPoint = Vector2.new(1, if E.tabInside then 0.5 else 0.6),
		Position = if E.tabInside then UDim2.new(1, -6, 0, E.headH / 2) else UDim2.new(1, -8, 0, 0),
		Size = UDim2.fromOffset(tabW, tabW),
		TextSize = if E.tabInside then 18 else 26,
		TextColor3 = C.white,
		ZIndex = 4,
		Parent = panel,
	}, function()
		setMinimised(true)
	end)
	ExtractUI.setMinimised = setMinimised
	ExtractUI.isMinimised = function(): boolean
		return minimised
	end

	-- Hover (mouse): the bar opens the cards in place while the pointer is
	-- over them; they fold back ~0.6 s after it leaves (RenderStepped below).
	-- A click on Open pins them open.
	local lastOver = 0
	bar.MouseEnter:Connect(function()
		if Device.mode() ~= "kbm" or not bar.Visible then
			return
		end
		setMinimised(false)
		hoverOpened = true
		lastOver = os.clock()
	end)

	local row = make("Frame", {
		Name = "Cards",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, E.cardsY),
		Size = UDim2.new(1, 0, 0, CARD_H),
		Parent = panel,
	})
	Theme.list(
		Enum.FillDirection.Horizontal,
		E.gap,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Top
	).Parent =
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
		Theme.corner(12).Parent = b
		Theme.gloss(b, 1, 0.9)
		local stroke = Theme.stroke(info.color, 3)
		stroke.Parent = b
		Theme.hover(b, 1.03)
		Theme.tooltip(b, function()
			return string.format("%s\nRisk: %s\n%s", info.title, info.riskText, info.body)
		end)
		local band = make("Frame", {
			Size = UDim2.new(1, 0, 0, E.bandH),
			BackgroundColor3 = info.color,
			BorderSizePixel = 0,
			Parent = b,
		})
		Theme.corner(10).Parent = band
		Theme.gloss(band, 1, 0.75)
		Theme.icon(
			info.icon,
			E.bandIcon,
			C.white,
			{ Position = UDim2.fromOffset(8, (E.bandH - E.bandIcon) // 2), Parent = band }
		)
		local head = Theme.label({
			Position = UDim2.fromOffset(E.bandIcon + 14, 0),
			Size = UDim2.new(1, -(E.bandIcon + 18), 1, 0),
			TextSize = E.bandText,
			TextColor3 = C.white,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = info.title,
			Parent = band,
		})
		Theme.textStroke(C.brownDark, 1.5).Parent = head
		-- Reward (up to two lines)
		local reward = Theme.label({
			Position = UDim2.fromOffset(10, E.rewardY),
			Size = UDim2.new(1, -20, 0, E.rewardH),
			TextSize = E.rewardText,
			TextColor3 = C.ink,
			Font = Theme.FONT,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = b,
		})
		-- Risk pips + one short line (full text in the tooltip)
		local riskRow = make("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(10, E.riskY),
			Size = UDim2.new(1, -20, 0, E.riskH),
			Parent = b,
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
			Size = UDim2.fromOffset(0, E.riskH),
			TextSize = E.riskText,
			TextColor3 = C.red,
			TextWrapped = false,
			Text = "RISK ",
			Parent = riskRow,
		})
		local pips: { Frame } = {}
		for p = 1, 3 do
			local pip = make("Frame", {
				LayoutOrder = p,
				Size = UDim2.fromOffset(if dense then 14 else 18, if dense then 6 else 8),
				BackgroundColor3 = if p <= info.risk then C.red else C.creamDark,
				Parent = riskRow,
			}) :: Frame
			Theme.corner(3).Parent = pip
			pips[p] = pip
		end
		Theme.label({
			Position = UDim2.fromOffset(10, E.riskLineY),
			Size = UDim2.new(1, -20, 0, E.riskLineH),
			TextSize = E.riskLineText,
			Font = Theme.FONT_BODY,
			TextColor3 = C.brown,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = info.riskShort,
			Parent = b,
		})
		-- Footer: votes + pick
		local footer = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -6),
			Size = UDim2.new(1, -12, 0, E.footerH),
			BackgroundColor3 = info.color,
			Parent = b,
		})
		Theme.corner(8).Parent = footer
		Theme.gloss(footer, 1, 0.8)
		local votes = Theme.label({
			Position = UDim2.fromOffset(8, 0),
			Size = UDim2.new(0.4, -8, 1, 0),
			TextSize = E.votesText,
			TextColor3 = C.white,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = false,
			Text = "0 votes",
			Parent = footer,
		})
		Theme.textStroke(C.brownDark, 1.5).Parent = votes
		local pick = Theme.label({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 0),
			Size = UDim2.new(0.6, -8, 1, 0),
			TextSize = E.pickText,
			TextColor3 = C.white,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = "Vote",
			Parent = footer,
		})
		Theme.textStroke(C.brownDark, 1.5).Parent = pick
		b.Activated:Connect(function()
			local e = State.get("extract")
			if type(e) == "table" and not e.closed then
				hoverOpened = false -- a vote pins nothing; the server echo folds it
				State.castExtract(key)
			end
		end)
		views[key] = { button = b, stroke = stroke, reward = reward, votes = votes, pick = pick, pips = pips }
	end

	-- Keep the open panel above the level-up strip when both are on screen.
	local function upgradeLift(): number
		local gui = screen and screen.gui
		local pg = gui and gui.Parent
		local up = pg and pg:FindFirstChild("TrunkfallUpgrades")
		local strip = up and up:FindFirstChild("UpgradePanel", true)
		local shownStrip = strip ~= nil and strip:IsA("GuiObject") and strip.Visible
		local rootH = if screen then screen.rootSize().Y else 620
		return UiSizes.stackLift(dense, touch, rootH, PANEL_H, shownStrip)
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
			bar.Visible = false
			minimised = false
			autoMinimisedFor = nil
			shown = nil
			return
		end
		local sq = State.squad(State.mySquad())
		-- each member banks their OWN share (x Portal Charm), not the squad pot
		local share = tonumber(e.share) or tonumber((State.get("run") or {}).pendingCheese) or 0
		local bank = tonumber(e.bank) or share
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
			-- v4 Rookie Run: Double or Nothing stays hidden until run 3
			local offered = table.find(e.options, key) ~= nil
				and not (key == "DoubleOrNothing" and Progression.isRookie(State.get("profile")))
			v.button.Visible = offered
			v.reward.Text = INFO[key].reward(share, brave, bank)
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
			v.stroke.Thickness = if mine == key or chosen then 5 else 3
			v.stroke.Color = if chosen then C.gold elseif mine == key then C.brownDark else INFO[key].color
			v.button.BackgroundColor3 = if mine == key or chosen then C.goldLight else C.cream
			v.button.Active = not e.closed
		end
		subText = if brave
			then "2+ squads have extracted: staying earns the +25% brave bonus!"
			else "Your squad votes. Majority decides; 🤖 bots follow their humans."
		if e ~= shown then
			local fresh = shown == nil
			shown = e
			if fresh then
				-- iteration 1 #16 (C-5, P-27): opens full-size on every device;
				-- on PC it folds to the slim bar after 4 s unless hovered.
				minimised = false
				hoverOpened = false
				autoMinimisedFor = nil
				local openedFor = e.endsAt
				task.delay(4, function()
					local cur = State.get("extract")
					if
						type(cur) ~= "table"
						or cur.endsAt ~= openedFor
						or minimised
						or Device.mode() ~= "kbm"
						or Progression.isRookie(State.get("profile")) -- rookies keep it open
					then
						return
					end
					if Theme.pointerOver(panel) then
						hoverOpened = true
						return
					end
					minimised = true
					panel.Visible = false
					bar.Visible = true
				end)
				if not minimised then
					panel.Visible = true
					Theme.popIn(panel)
				else
					bar.Visible = true
					Theme.popIn(bar)
				end
				local ok, Onboarding = pcall(require, script.Parent.Onboarding)
				if ok and type(Onboarding.extractSeen) == "function" then
					pcall(Onboarding.extractSeen)
				end
				if Device.mode() == "gamepad" then
					GuiService.SelectedObject = views.Extract.button
				end
			end
		end
		-- your vote is in (server echo): fold to the compact bar once per window
		if e.yourChoice and not e.closed and autoMinimisedFor ~= e.endsAt then
			autoMinimisedFor = e.endsAt
			minimised = true
			hoverOpened = false
		end
		local pickName = if mine and INFO[mine] then INFO[mine].title else "not voted"
		barPick = if e.closed
			then "Decided: " .. (if e.result and INFO[e.result] then INFO[e.result].title else "done")
			else "Your pick: " .. pickName
		barText.Text = "🌀 " .. barPick
		panel.Visible = not minimised
		bar.Visible = minimised
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
		if not e or not (panel.Visible or bar.Visible) then
			return
		end
		if not dense then
			local lift = upgradeLift()
			place(panel, lift)
			place(bar, lift)
		end
		if hoverOpened and panel.Visible then
			if Theme.pointerOver(panel) then
				lastOver = os.clock()
			elseif os.clock() - lastOver > 0.6 then
				setMinimised(true)
			end
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
		if bar.Visible then
			barText.Text = "🌀 ⏱ " .. Format.clock(math.max(0, rem)) .. " · " .. barPick
		end
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
