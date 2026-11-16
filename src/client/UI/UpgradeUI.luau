--!strict
-- Level-up offers (Net.S2C.UpgradeOffer -> State "offers"). A compact bottom
-- strip (v3; Util/UiSizes.upgrade) with 3 rarity-framed cards that never
-- blocks movement. Pick with a click,
-- tap, keys 1/2/3 or DPad Left/Up/Right; reroll with the button, R or DPad
-- Down. Sends Net.C2S.ChooseUpgrade(offerId, cardIndex) and
-- Net.C2S.RerollUpgrade(offerId). Queued levels show as a "+N" badge.

local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Remotes = require(Client.Util.Remotes)
local Device = require(Client.Util.Device)
local UiSizes = require(Client.Util.UiSizes)
local State = require(Client.Controllers.State)

local UpgradeUI = {}

local C = Theme.C
local make = Theme.make

local PICK_KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.KeypadOne] = 1,
	[Enum.KeyCode.KeypadTwo] = 2,
	[Enum.KeyCode.KeypadThree] = 3,
	[Enum.KeyCode.DPadLeft] = 1,
	[Enum.KeyCode.DPadUp] = 2,
	[Enum.KeyCode.DPadRight] = 3,
}
local REROLL_KEYS: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.R] = true,
	[Enum.KeyCode.DPadDown] = true,
}

-- Three cards plus a full-height reroll button, so every target is big on touch.
local U = UiSizes.upgrade(false)
-- Touch ability button (InputController): 150 px + 36 px margin from the right edge.
local TOUCH_BUTTON_CLEARANCE = 200

local screen: any = nil
local panel: Frame? = nil
local cardRow: Frame? = nil
local rerollButton: TextButton? = nil
local queueBadge: TextLabel? = nil
local titleLabel: TextLabel? = nil
local current: any = nil
local lockedUntil = 0
local connections: { any } = {}

local function keyHint(i: number): string
	if Device.mode() == "gamepad" then
		return ({ "◀", "▲", "▶" })[i] or ""
	elseif Device.mode() == "touch" then
		return ""
	end
	return "[" .. tostring(i) .. "]"
end

local function choose(index: number)
	local offer = current
	if not offer or os.clock() < lockedUntil then
		return
	end
	if not offer.cards[index] then
		return
	end
	lockedUntil = os.clock() + 0.35
	Remotes.fire(Remotes.C2S.ChooseUpgrade, offer.offerId, index)
	State.removeOffer(offer.offerId) -- optimistic; the server sends the next queued offer
end

local function reroll()
	local offer = current
	if not offer or os.clock() < lockedUntil or (offer.rerollsLeft or 0) <= 0 then
		return
	end
	lockedUntil = os.clock() + 0.5
	Remotes.fire(Remotes.C2S.RerollUpgrade, offer.offerId)
end

local function buildCard(i: number, card: any)
	local rarity = tostring(card.rarity or "Common")
	local color = Theme.RARITY[rarity] or Theme.RARITY.Common
	local b = make("TextButton", {
		Name = "Card" .. i,
		LayoutOrder = i,
		Size = UDim2.fromOffset(U.cardW, U.cardH),
		BackgroundColor3 = C.cream,
		AutoButtonColor = false,
		Text = "",
		Selectable = true,
		Parent = cardRow,
	}) :: TextButton
	Theme.corner(12).Parent = b
	Theme.stroke(color, if rarity == "Legendary" or rarity == "Epic" then U.stroke + 2 else U.stroke).Parent =
		b
	local band = make("Frame", {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, U.bandH),
		Parent = b,
	})
	Theme.corner(10).Parent = band
	local rar = Theme.label({
		Position = UDim2.fromOffset(8, 0),
		Size = UDim2.new(1, -50, 0, U.bandH),
		TextSize = U.bandText,
		TextWrapped = false,
		TextColor3 = C.white,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = string.upper(rarity),
		Parent = band,
	})
	Theme.textStroke(C.brownDark, 1.5).Parent = rar
	local hint = Theme.label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 0),
		Size = UDim2.fromOffset(40, U.bandH),
		TextSize = U.bandText,
		TextColor3 = C.white,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = keyHint(i),
		Parent = band,
	})
	Theme.textStroke(C.brownDark, 1.5).Parent = hint
	Theme.label({
		Position = UDim2.fromOffset(8, U.nameY),
		Size = UDim2.new(1, -16, 0, U.nameH),
		TextSize = U.nameText,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Text = tostring(card.name or card.id or "Upgrade"),
		Parent = b,
	})
	Theme.label({
		Position = UDim2.fromOffset(8, U.descY),
		Size = UDim2.new(1, -16, 0, U.descH),
		TextSize = U.descText,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = tostring(card.description or ""),
		Parent = b,
	})
	Theme.tooltip(b, function()
		return if Device.mode() == "touch"
			then ""
			else tostring(card.name or card.id or "Upgrade") .. "\n" .. tostring(card.description or "")
	end)
	b.Activated:Connect(function()
		choose(i)
	end)
	Theme.popIn(b)
end

local function render(offers: any)
	local p = panel
	if not p then
		return
	end
	local offer = if type(offers) == "table" then offers[1] else nil
	local phase = State.phase()
	if offer == nil or phase == "Results" or phase == "Lobby" then
		p.Visible = false
		current = nil
		return
	end
	local changed = current == nil or current.offerId ~= offer.offerId or current.cards ~= offer.cards
	current = offer
	p.Visible = true
	if changed then
		lockedUntil = os.clock() + 0.25 -- avoid accidental double-picks into the next offer
		for _, ch in (cardRow :: Frame):GetChildren() do
			if ch:IsA("GuiButton") then
				ch:Destroy()
			end
		end
		for i, card in offer.cards do
			if i > 3 then
				break
			end
			if type(card) == "table" then
				buildCard(i, card)
			end
		end
	end
	local rb = rerollButton :: TextButton
	local left = tonumber(offer.rerollsLeft) or 0
	rb.Text = string.format("🎲 Reroll\n(%d)%s", left, if Device.mode() == "kbm" then " [R]" else "")
	Theme.setEnabled(rb, left > 0)
	if titleLabel then
		-- Bonus picks from POIs (GDD §3.8) say where they came from.
		titleLabel.Text = if offer.source == "pantry"
			then "🥧 GRANDMA'S PANTRY! Pick an Epic"
			elseif offer.source == "chest" then "🎁 ELITE CHEST! Bonus pick"
			else "⬆ LEVEL UP! Pick one"
	end
	local waiting = (tonumber(offer.queued) or 0) + math.max(0, #offers - 1)
	local badge = queueBadge :: TextLabel
	badge.Visible = waiting > 0
	badge.Text = string.format("+%d more", waiting)
end

function UpgradeUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallUpgrades", 25)
	local touchDevice = Device.hasTouch()
	local dense = Theme.dense()
	U = UiSizes.upgrade(dense)
	local PANEL_W, PANEL_H, GAP = U.panelW, U.panelH, U.gap
	local hud = UiSizes.hud(dense, Theme.TOUCH)
	local p = make("Frame", {
		Name = "UpgradePanel",
		AnchorPoint = Vector2.new(0.5, 1),
		-- Above the PC ability widget (and its key hint); on touch the bottom
		-- centre is free.
		Position = if touchDevice
			then UDim2.new(0.5, 0, 1, -12)
			else UDim2.new(0.5, 0, 1, -(hud.rowH + hud.bottomY + hud.abilityHintH + 10)),
		Size = UDim2.fromOffset(PANEL_W, PANEL_H),
		BackgroundColor3 = C.brownDark,
		BackgroundTransparency = 0.25,
		Visible = false,
		Parent = screen.root,
	})
	if touchDevice then
		-- On narrow (4:3) screens, slide left so the panel never covers the
		-- touch ability button in the bottom-right corner.
		local stop = screen.onResize(function(size: Vector2)
			local centre = size.X / 2
			local maxCentre = size.X - TOUCH_BUTTON_CLEARANCE - PANEL_W / 2
			p.Position = UDim2.new(0, math.max(PANEL_W / 2 + 8, math.min(centre, maxCentre)), 1, -12)
		end)
		table.insert(connections, { Disconnect = stop })
	end
	Theme.corner(if dense then 12 else 18).Parent = p
	Theme.stroke(C.cheese, if dense then 2 else 3).Parent = p
	panel = p
	local title = Theme.label({
		Position = UDim2.fromOffset(12, U.titleY),
		Size = UDim2.fromOffset(if dense then 260 else 330, U.titleH),
		TextSize = U.titleText,
		TextWrapped = false,
		TextColor3 = C.cheese,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "⬆ LEVEL UP! Pick one",
		Parent = p,
	})
	Theme.textStroke().Parent = title
	titleLabel = title
	local badge = Theme.label({
		Position = UDim2.fromOffset(if dense then 276 else 340, U.titleY),
		Size = UDim2.fromOffset(U.badgeW, U.titleH),
		TextSize = U.badgeText,
		BackgroundTransparency = 0,
		BackgroundColor3 = C.red,
		TextColor3 = C.white,
		Visible = false,
		Parent = p,
	})
	Theme.corner(U.titleH // 2).Parent = badge
	queueBadge = badge
	local rb = Theme.button("🎲 Reroll (0)", C.cheese, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -GAP, 0, U.cardsY),
		Size = UDim2.fromOffset(U.rerollW, U.cardH),
		TextSize = U.rerollText,
		Parent = p,
	}, reroll)
	rerollButton = rb
	local row = make("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(GAP, U.cardsY),
		Size = UDim2.new(1, -(U.rerollW + 3 * GAP), 0, U.cardH),
		Parent = p,
	})
	Theme.list(
		Enum.FillDirection.Horizontal,
		GAP,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Top
	).Parent =
		row
	cardRow = row

	table.insert(connections, { Disconnect = State.subscribe("offers", render, true) })
	table.insert(connections, {
		Disconnect = State.subscribe("run", function()
			render(State.get("offers"))
		end),
	})
	local inputConn = UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not current then
			return
		end
		local idx = PICK_KEYS[input.KeyCode]
		if idx then
			choose(idx)
		elseif REROLL_KEYS[input.KeyCode] then
			reroll()
		end
	end)
	table.insert(connections, {
		Disconnect = function()
			inputConn:Disconnect()
		end,
	})
	local modeConn = Device.modeChanged:Connect(function()
		if current then
			local snapshot = current
			current = nil -- force card rebuild so key hints match the input mode
			render(State.get("offers"))
			if current == nil then
				current = snapshot
			end
		end
	end)
	table.insert(connections, {
		Disconnect = function()
			modeConn:Disconnect()
		end,
	})
end

function UpgradeUI.destroy()
	for _, c in connections do
		c.Disconnect()
	end
	table.clear(connections)
	if screen then
		screen.destroy()
		screen = nil
	end
	panel = nil
	current = nil
end

return UpgradeUI
