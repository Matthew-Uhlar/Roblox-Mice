--!strict
-- Level-up offers (Net.S2C.UpgradeOffer -> State "offers"). A bottom panel
-- with 3 rarity-framed cards that never blocks movement. Pick with a click,
-- tap, keys 1/2/3 or DPad Left/Up/Right; reroll with the button, R or DPad
-- Down. Sends Net.C2S.ChooseUpgrade(offerId, cardIndex) and
-- Net.C2S.RerollUpgrade(offerId). Queued levels show as a "+N" badge.

local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Remotes = require(Client.Util.Remotes)
local Device = require(Client.Util.Device)
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
local CARD_W, CARD_H, GAP = 220, 168, 12
local REROLL_W = 120
local PANEL_W = 3 * CARD_W + 3 * GAP + REROLL_W + 2 * GAP
local PANEL_H = 58 + CARD_H + 12
-- Touch ability button (InputController): 150 px + 36 px margin from the right edge.
local TOUCH_BUTTON_CLEARANCE = 200

local screen: any = nil
local panel: Frame? = nil
local cardRow: Frame? = nil
local rerollButton: TextButton? = nil
local queueBadge: TextLabel? = nil
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
		Size = UDim2.fromOffset(CARD_W, CARD_H),
		BackgroundColor3 = C.cream,
		AutoButtonColor = false,
		Text = "",
		Selectable = true,
		Parent = cardRow,
	}) :: TextButton
	Theme.corner(14).Parent = b
	Theme.stroke(color, if rarity == "Legendary" or rarity == "Epic" then 6 else 4).Parent = b
	local band = make("Frame", {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 30),
		Parent = b,
	})
	Theme.corner(12).Parent = band
	local rar = Theme.label({
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.new(1, -60, 0, 30),
		TextSize = 17,
		TextColor3 = C.white,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = string.upper(rarity),
		Parent = band,
	})
	Theme.textStroke(C.brownDark, 1.5).Parent = rar
	local hint = Theme.label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 0),
		Size = UDim2.fromOffset(50, 30),
		TextSize = 18,
		TextColor3 = C.white,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = keyHint(i),
		Parent = band,
	})
	Theme.textStroke(C.brownDark, 1.5).Parent = hint
	Theme.label({
		Position = UDim2.fromOffset(10, 34),
		Size = UDim2.new(1, -20, 0, 30),
		TextSize = 22,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Text = tostring(card.name or card.id or "Upgrade"),
		Parent = b,
	})
	Theme.label({
		Position = UDim2.fromOffset(10, 66),
		Size = UDim2.new(1, -20, 1, -72),
		TextSize = 15,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = tostring(card.description or ""),
		Parent = b,
	})
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
	rb.Text = string.format("🎲\nReroll\n(%d)%s", left, if Device.mode() == "kbm" then "\n[R]" else "")
	Theme.setEnabled(rb, left > 0)
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
	local p = make("Frame", {
		Name = "UpgradePanel",
		AnchorPoint = Vector2.new(0.5, 1),
		-- Above the PC ability widget; on touch the bottom centre is free.
		Position = if touchDevice then UDim2.new(0.5, 0, 1, -12) else UDim2.new(0.5, 0, 1, -136),
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
	Theme.corner(18).Parent = p
	Theme.stroke(C.cheese, 3).Parent = p
	panel = p
	local title = Theme.label({
		Position = UDim2.fromOffset(16, 6),
		Size = UDim2.fromOffset(330, 40),
		TextSize = 26,
		TextColor3 = C.cheese,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "⬆ LEVEL UP! Pick one",
		Parent = p,
	})
	Theme.textStroke().Parent = title
	local badge = Theme.label({
		Position = UDim2.fromOffset(340, 10),
		Size = UDim2.fromOffset(110, 32),
		TextSize = 18,
		BackgroundTransparency = 0,
		BackgroundColor3 = C.red,
		TextColor3 = C.white,
		Visible = false,
		Parent = p,
	})
	Theme.corner(16).Parent = badge
	queueBadge = badge
	local rb = Theme.button("🎲 Reroll (0)", C.cheese, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -GAP, 0, 58),
		Size = UDim2.fromOffset(REROLL_W, CARD_H),
		TextSize = 20,
		Parent = p,
	}, reroll)
	rerollButton = rb
	local row = make("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(GAP, 58),
		Size = UDim2.new(1, -(REROLL_W + 3 * GAP), 0, CARD_H),
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
