--!strict
-- Shop Cart POI (GDD-v2 §4): 3 gear offers priced in your squad's PENDING
-- cheese, the in-run soft currency. It is never Robux: there is no Robux
-- symbol anywhere on this panel and the price line says "pending cheese".
-- Reads State "shopCart" (Net.S2C.ShopCart {poi, offers, prices}) and the
-- squad pot from "match". Sends Net.C2S.BuyCartItem(poiId, index) via
-- State.buyCart. The panel sits on the right so you can keep moving.

local GuiService = game:GetService("GuiService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local GearInfo = require(script.Parent.GearInfo)
local Format = require(Client.Util.Format)
local Device = require(Client.Util.Device)
local State = require(Client.Controllers.State)

local ShopCartUI = {}

local C = Theme.C
local T = Theme.TYPE
local make = Theme.make

local screen: any = nil
local unsubs: { () -> () } = {}

local function pot(): number
	local sq = State.squad(State.mySquad())
	if sq then
		return sq.pending
	end
	local run = State.get("run")
	return if type(run) == "table" then tonumber(run.pendingCheese) or 0 else 0
end

function ShopCartUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallShopCart", 33)
	local root: Frame = screen.root
	local touch = Theme.TOUCH
	local ROW_H = math.max(96, touch + 20)
	local PANEL_W, PANEL_H = 420, 96 + 3 * (ROW_H + 8)

	local panel = Theme.card({
		Name = "ShopCart",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.55, 0),
		Size = UDim2.fromOffset(PANEL_W, PANEL_H),
		Visible = false,
		Parent = root,
	}, { stroke = 3 })
	table.insert(unsubs, Theme.fitFrame(screen, panel, PANEL_W, PANEL_H, 10))
	Theme.icon("cart", 36, C.cheese, { Position = UDim2.fromOffset(14, 10), Parent = panel })
	local title = Theme.label({
		Position = UDim2.fromOffset(58, 8),
		Size = UDim2.new(1, -(touch + 70), 0, 30),
		TextSize = T.title - 4,
		TextColor3 = C.gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Shop Cart",
		Parent = panel,
	})
	Theme.textStroke(C.shade, 2).Parent = title
	local balance = Theme.label({
		Position = UDim2.fromOffset(58, 38),
		Size = UDim2.new(1, -(touch + 70), 0, 18),
		TextSize = T.caption,
		TextColor3 = C.cream,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = panel,
	})
	Theme.label({
		Position = UDim2.fromOffset(14, 60),
		Size = UDim2.new(1, -28, 0, 30),
		TextSize = T.micro,
		Font = Theme.FONT_BODY,
		TextColor3 = C.textDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "Paid with your squad's pending cheese (in-run only, never Robux). Gear is lost when the run ends.",
		Parent = panel,
	})
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 8),
		Size = UDim2.fromOffset(touch, touch),
		TextColor3 = C.white,
		Parent = panel,
	}, function()
		State.closeShopCart()
	end)
	local list = Theme.scroller({
		Position = UDim2.fromOffset(10, 92),
		Size = UDim2.new(1, -20, 1, -100),
		ScrollBarThickness = 8,
		Parent = panel,
	})
	Theme.list(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Left).Parent = list

	type Row = { frame: Frame, iconBox: Frame, name: TextLabel, desc: TextLabel, buy: TextButton }
	local rows: { Row } = {}
	for i = 1, 3 do
		local f = make("Frame", {
			LayoutOrder = i,
			Size = UDim2.new(1, -8, 0, ROW_H),
			BackgroundColor3 = C.rindLight,
			BackgroundTransparency = 0.2,
			Parent = list,
		}) :: Frame
		Theme.corner(12).Parent = f
		local iconBox = make("Frame", {
			Position = UDim2.fromOffset(8, 10),
			Size = UDim2.fromOffset(52, 52),
			BackgroundColor3 = C.rind,
			Parent = f,
		}) :: Frame
		Theme.corner(10).Parent = iconBox
		local name = Theme.label({
			Position = UDim2.fromOffset(70, 6),
			Size = UDim2.new(1, -(80 + 130), 0, 22),
			TextSize = T.body + 1,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Parent = f,
		})
		Theme.textStroke(C.shade, 1).Parent = name
		local desc = Theme.label({
			Position = UDim2.fromOffset(70, 30),
			Size = UDim2.new(1, -(80 + 130), 1, -34),
			TextSize = T.micro,
			Font = Theme.FONT_BODY,
			TextColor3 = C.cream,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = f,
		})
		local buy = Theme.button("Buy", C.cheese, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(124, touch),
			TextSize = T.body,
			Parent = f,
		}, function()
			State.buyCart(i)
		end)
		rows[i] = { frame = f, iconBox = iconBox, name = name, desc = desc, buy = buy }
	end

	local shownPoi: any = nil
	local function render(cart: any)
		if type(cart) ~= "table" then
			if
				panel.Visible
				and GuiService.SelectedObject
				and GuiService.SelectedObject:IsDescendantOf(panel)
			then
				GuiService.SelectedObject = nil
			end
			panel.Visible = false
			shownPoi = nil
			return
		end
		local have = pot()
		balance.Text = string.format("Squad pot: 🧀 %s pending", Format.int(have))
		for i, r in rows do
			local item = cart.offers[i]
			local info = GearInfo.describe(item)
			r.frame.Visible = info ~= nil
			if info then
				for _, ch in r.iconBox:GetChildren() do
					if ch:IsA("Frame") then
						ch:Destroy()
					end
				end
				Theme.icon(info.icon, 44, info.color, {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Parent = r.iconBox,
				})
				Theme.rarityFrame(r.iconBox, info.rarity)
				r.name.Text = info.name
				r.name.TextColor3 = info.color
				r.desc.Text = string.format(
					"%s %s · %s",
					info.rarity,
					GearInfo.SLOT_NAME[info.slot] or info.slot,
					info.text
				)
				local price = cart.prices[i] or 0
				local sold = cart.sold[i]
				if sold == true then
					r.buy.Text = "Sold"
					r.buy.BackgroundColor3 = C.grey
					Theme.setEnabled(r.buy, false)
				elseif sold == "pending" then
					r.buy.Text = "Buying…"
					Theme.setEnabled(r.buy, false)
				else
					r.buy.Text = "🧀 " .. Format.int(price) .. " pending"
					r.buy.BackgroundColor3 = if have >= price then C.cheese else C.creamDark
					Theme.setEnabled(r.buy, have >= price)
				end
			end
		end
		if cart.poi ~= shownPoi then
			shownPoi = cart.poi
			panel.Visible = true
			Theme.slideIn(panel, 120, 0)
			if Device.mode() == "gamepad" then
				GuiService.SelectedObject = rows[1].buy
			end
		end
		panel.Visible = true
	end
	table.insert(unsubs, State.subscribe("shopCart", render, true))
	table.insert(
		unsubs,
		State.subscribe("match", function()
			if panel.Visible then
				render(State.get("shopCart"))
			end
		end)
	)
	-- The server confirms with a fresh ShopCart / Inventory; a "Buying…" row
	-- that hears nothing for 3 s becomes buyable again.
	table.insert(
		unsubs,
		State.subscribe("shopCart", function(cart)
			if type(cart) ~= "table" then
				return
			end
			for i, v in cart.sold do
				if v == "pending" then
					task.delay(3, function()
						local cur = State.get("shopCart")
						if cur == cart and cur.sold[i] == "pending" then
							cur.sold[i] = nil
							State.set("shopCart", cur)
						end
					end)
				end
			end
		end)
	)
	table.insert(
		unsubs,
		State.subscribe("run", function(run)
			local phase = if type(run) == "table" then run.phase else nil
			if State.get("shopCart") ~= nil and phase ~= "Waves" and phase ~= "Boss" then
				State.closeShopCart()
			end
		end)
	)
end

function ShopCartUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	if screen then
		screen.destroy()
		screen = nil
	end
end

return ShopCartUI
