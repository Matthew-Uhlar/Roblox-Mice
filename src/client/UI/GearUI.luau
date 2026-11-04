--!strict
-- Run-only gear (GDD-v2 §3): three slots (weapon mod / armor / trinket) with
-- rarity frames, primitive icons and live tooltips, plus the 4 s swap prompt
-- when a pickup lands on a full slot.
--
-- Reads State "inventory" (Net.S2C.Inventory {weapon?, armor?, trinket?,
-- swapOffer? = {item, slot, endsAt}}).
-- Sends Net.C2S.SwapGear(keep) through State.answerSwap:
--   true  = equip the NEW item (the old one stays on the ground),
--   false = keep the current item.
-- Keys: F = equip new, G = keep current (InputController); gamepad L1 / R1;
-- touch / mouse: the two buttons.

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local GearInfo = require(script.Parent.GearInfo)
local Device = require(Client.Util.Device)
local State = require(Client.Controllers.State)

local GearUI = {}

local C = Theme.C
local make = Theme.make

export type Handle = { row: Frame, prompt: Frame, destroy: () -> () }

-- `row` is the bottom-centre horizontal list the slots go into (HudUI owns it,
-- so the ability widget can sit next to them). `promptParent` is the root.
function GearUI.build(row: Frame, promptParent: Instance): Handle
	local unsubs: { () -> () } = {}
	local conns: { RBXScriptConnection } = {}
	local touch = Theme.TOUCH
	local slotSize = math.max(64, math.floor(touch * 0.92))

	type Slot = { button: TextButton, iconBox: Frame, iconKey: string, tag: TextLabel, rarity: TextLabel }
	local slots: { [string]: Slot } = {}
	local iconSize = math.floor(slotSize * 0.56)

	for i, slot in GearInfo.SLOTS do
		local b = make("TextButton", {
			Name = "Gear_" .. slot,
			LayoutOrder = i,
			Size = UDim2.fromOffset(slotSize, slotSize),
			BackgroundColor3 = C.rind,
			BackgroundTransparency = 0.15,
			AutoButtonColor = false,
			Text = "",
			Selectable = false,
			Parent = row,
		}) :: TextButton
		Theme.corner(12).Parent = b
		Theme.gradient(b, Color3.fromRGB(255, 240, 220), Color3.fromRGB(140, 120, 100))
		local iconBox = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.46),
			Size = UDim2.fromOffset(iconSize, iconSize),
			BackgroundTransparency = 1,
			ZIndex = 3,
			Parent = b,
		}) :: Frame
		local tag = Theme.label({
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -2),
			Size = UDim2.new(1, -4, 0, 14),
			TextSize = Theme.TYPE.micro,
			TextColor3 = C.textDim,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Text = string.upper(slot),
			ZIndex = 6,
			Parent = b,
		})
		Theme.textStroke(C.shade, 1).Parent = tag
		local rarity = Theme.badge("", C.grey, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, 0),
			Size = UDim2.fromOffset(0, 16),
			Visible = false,
			ZIndex = 7,
			Parent = b,
		})
		Theme.rarityFrame(b, "Common")
		Theme.hover(b, 1.06)
		Theme.tooltip(b, function()
			local inv = State.get("inventory")
			return GearInfo.tooltip(if type(inv) == "table" then inv[slot] else nil, slot)
		end)
		slots[slot] = { button = b, iconBox = iconBox, iconKey = "", tag = tag, rarity = rarity }
	end

	local function setSlotIcon(s: Slot, kind: string, color: Color3, dim: boolean)
		local key = kind .. "|" .. color:ToHex() .. (if dim then "|dim" else "")
		if s.iconKey == key then
			return
		end
		s.iconKey = key
		for _, ch in s.iconBox:GetChildren() do
			ch:Destroy()
		end
		local ic = Theme.icon(kind, iconSize, color, { Parent = s.iconBox })
		if dim then
			for _, d in ic:GetDescendants() do
				if d:IsA("Frame") and d.BackgroundTransparency < 1 then
					d.BackgroundTransparency = 0.6
				end
			end
		end
	end

	local function renderSlots(inv: any)
		for slot, s in slots do
			local item = if type(inv) == "table" then inv[slot] else nil
			local info = GearInfo.describe(item)
			if info then
				setSlotIcon(s, info.icon, info.color, false)
				Theme.rarityFrame(s.button, info.rarity)
				s.rarity.Text = string.upper(info.rarity)
				s.rarity.BackgroundColor3 = info.color
				s.rarity.Visible = true
				s.tag.Text = string.upper(info.name)
				s.tag.TextColor3 = C.cream
			else
				setSlotIcon(s, Theme.Icons.forSlot(slot), C.greyDark, true)
				Theme.rarityFrame(s.button, "Common").Color = C.rindLight
				s.rarity.Visible = false
				s.tag.Text = string.upper(slot)
				s.tag.TextColor3 = C.textDim
			end
		end
	end

	------------------------------------------------------------------
	-- Swap prompt
	------------------------------------------------------------------
	local promptH = 44 + 78 + touch + 30
	local prompt = Theme.card({
		Name = "SwapPrompt",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -(slotSize + 40)),
		Size = UDim2.fromOffset(470, promptH),
		Visible = false,
		Parent = promptParent,
	})
	Theme.padding(12, 10).Parent = prompt
	local pTitle = Theme.label({
		Size = UDim2.new(1, -60, 0, 26),
		TextSize = Theme.TYPE.heading,
		TextColor3 = C.gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Slot full: swap gear?",
		Parent = prompt,
	})
	Theme.textStroke(C.shade, 1.5).Parent = pTitle
	local pTimer = Theme.label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(60, 26),
		TextSize = Theme.TYPE.heading,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "4",
		Parent = prompt,
	})
	Theme.textStroke(C.shade, 1.5).Parent = pTimer
	local timeBar = Theme.bar({
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 0, 8),
		Parent = prompt,
	}, C.gold)
	timeBar.text.Visible = false

	local function itemCard(x: number, label: string): (Frame, TextLabel, TextLabel, Frame)
		local f = make("Frame", {
			Position = UDim2.new(x, if x > 0 then 6 else 0, 0, 44),
			Size = UDim2.new(0.5, -6, 0, 72),
			BackgroundColor3 = C.rindLight,
			BackgroundTransparency = 0.2,
			Parent = prompt,
		}) :: Frame
		Theme.corner(10).Parent = f
		local iconBox = make("Frame", {
			Position = UDim2.fromOffset(6, 12),
			Size = UDim2.fromOffset(48, 48),
			BackgroundTransparency = 1,
			Parent = f,
		}) :: Frame
		local cap = Theme.label({
			Position = UDim2.fromOffset(60, 4),
			Size = UDim2.new(1, -64, 0, 14),
			TextSize = Theme.TYPE.micro,
			TextColor3 = C.textDim,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = label,
			Parent = f,
		})
		local name = Theme.label({
			Position = UDim2.fromOffset(60, 18),
			Size = UDim2.new(1, -64, 0, 20),
			TextSize = Theme.TYPE.body,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Parent = f,
		})
		Theme.textStroke(C.shade, 1).Parent = name
		local desc = Theme.label({
			Position = UDim2.fromOffset(60, 38),
			Size = UDim2.new(1, -64, 0, 32),
			TextSize = Theme.TYPE.micro,
			Font = Theme.FONT_BODY,
			TextColor3 = C.cream,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = f,
		})
		Theme.textStroke(C.shade, 1).Parent = cap
		return f, name, desc, iconBox
	end
	local newCard, newName, newDesc, newIcon = itemCard(0, "NEW")
	local curCard, curName, curDesc, curIcon = itemCard(0.5, "CURRENT")

	local takeButton = Theme.button("Equip new [F]", C.green, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(0.5, -6, 0, touch),
		TextSize = Theme.TYPE.heading,
		TextColor3 = C.white,
		Parent = prompt,
	}, function()
		State.answerSwap(true)
	end)
	Theme.textStroke(C.brownDark, 1.5).Parent = takeButton
	local keepButton = Theme.button("Keep current [G]", C.cream, {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, 0),
		Size = UDim2.new(0.5, -6, 0, touch),
		TextSize = Theme.TYPE.heading,
		Parent = prompt,
	}, function()
		State.answerSwap(false)
	end)

	local function setIcon(box: Frame, info: any)
		for _, ch in box:GetChildren() do
			ch:Destroy()
		end
		if info then
			Theme.icon(info.icon, 44, info.color, {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Parent = box,
			})
		end
	end

	local function keyHints()
		local mode = Device.mode()
		if mode == "gamepad" then
			takeButton.Text = "Equip new [L1]"
			keepButton.Text = "Keep current [R1]"
		elseif mode == "touch" then
			takeButton.Text = "Equip new"
			keepButton.Text = "Keep current"
		else
			takeButton.Text = "Equip new [F]"
			keepButton.Text = "Keep current [G]"
		end
	end
	local modeConn = Device.modeChanged:Connect(keyHints)
	table.insert(unsubs, function()
		modeConn:Disconnect()
	end)

	local shownOffer: any = nil
	local offerTotal = 4
	local function renderPrompt(inv: any)
		local offer = if type(inv) == "table" then inv.swapOffer else nil
		if type(offer) ~= "table" then
			if prompt.Visible and GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(prompt) then
				GuiService.SelectedObject = nil
			end
			prompt.Visible = false
			shownOffer = nil
			return
		end
		if offer == shownOffer then
			return
		end
		shownOffer = offer
		offerTotal = math.clamp((tonumber(offer.endsAt) or 0) - State.serverNow(), 0.5, 4)
		local new = GearInfo.describe(offer.item)
		local cur = GearInfo.describe(offer.current or (inv :: any)[offer.slot])
		pTitle.Text = string.format("%s slot full: swap?", GearInfo.SLOT_NAME[offer.slot] or "Gear")
		newName.Text = if new then new.name else "???"
		newName.TextColor3 = if new then new.color else C.cream
		newDesc.Text = if new then new.rarity .. " · " .. new.text else ""
		curName.Text = if cur then cur.name else "(empty)"
		curName.TextColor3 = if cur then cur.color else C.textDim
		curDesc.Text = if cur then cur.rarity .. " · " .. cur.text else ""
		Theme.rarityFrame(newCard, if new then new.rarity else "Common")
		Theme.rarityFrame(curCard, if cur then cur.rarity else "Common")
		setIcon(newIcon, new)
		setIcon(curIcon, cur)
		keyHints()
		prompt.Visible = true
		Theme.popIn(prompt)
		if Device.mode() == "gamepad" then
			GuiService.SelectedObject = takeButton
		end
	end

	table.insert(
		unsubs,
		State.subscribe("inventory", function(inv)
			renderSlots(inv)
			renderPrompt(inv)
		end, true)
	)

	table.insert(
		conns,
		RunService.RenderStepped:Connect(function()
			local phase = State.phase()
			row.Visible = phase ~= nil and phase ~= "Lobby" and phase ~= "Results"
			if not prompt.Visible then
				return
			end
			local inv = State.get("inventory")
			local offer = if type(inv) == "table" then inv.swapOffer else nil
			if type(offer) ~= "table" then
				prompt.Visible = false
				return
			end
			local rem = (tonumber(offer.endsAt) or 0) - State.serverNow()
			if rem <= -0.5 then
				-- Expired without an answer: the server keeps the current item.
				inv.swapOffer = nil
				State.set("inventory", inv)
				return
			end
			pTimer.Text = tostring(math.max(0, math.ceil(rem)))
			pTimer.TextColor3 = if rem < 1.5 then C.red else C.cream
			timeBar.set(math.clamp(rem / offerTotal, 0, 1))
		end)
	)

	return {
		row = row,
		prompt = prompt,
		destroy = function()
			for _, u in unsubs do
				u()
			end
			for _, c in conns do
				c:Disconnect()
			end
			prompt:Destroy()
		end,
	}
end

return GearUI
