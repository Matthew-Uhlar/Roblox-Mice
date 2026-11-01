--!strict
-- Lobby shop (modal). Tabs:
--   Cosmetics        cheese / Golden Cheese buys (Shop item ids "cosmetic:<id>" and
--                    "cosmetic:<id>:golden") + Equip / Unequip for owned items.
--   Boosts & Passes  Robux items from Config.Monetization (Net.C2S.PromptProduct(key))
--                    plus cheese token bundles ("bundle:<id>"). "Coming soon" if the
--                    module is missing or an item has no asset id yet.
--   Talents          permanent upgrades ("talent:<id>").
-- Header: cheese balances and the daily reward claim (Net.C2S.ClaimDaily).

local MarketplaceService = game:GetService("MarketplaceService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Remotes = require(Client.Util.Remotes)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local State = require(Client.Controllers.State)

local ShopUI = {}

local C = Theme.C
local make = Theme.make

local TABS = { "Cosmetics", "Boosts & Passes", "Talents" }
local SOURCE_TEXT: { [string]: string } = {
	pass = "From a game pass",
	daily = "Daily streak reward",
	club = "Cheese Club reward",
	level = "Account level reward",
	epic = "Epic boss drop",
}

local screen: any = nil
local modal: Frame? = nil
local grid: ScrollingFrame? = nil
local tabButtons: { [string]: TextButton } = {}
local balanceLabel: TextLabel? = nil
local dailyButton: TextButton? = nil
local currentTab = TABS[1]
local unsubs: { () -> () } = {}
local robuxPrices: { [string]: number } = {}
local priceRequested: { [string]: boolean } = {}

local renderTab: () -> ()

local function profile(): any
	local p = State.get("profile")
	return if type(p) == "table" then p else {}
end

local function shopEntries(): { any }
	local mod = Defs.module("Shop")
	if type(mod) == "table" and type(mod.list) == "function" then
		local ok, list = pcall(mod.list)
		if ok and type(list) == "table" then
			return list
		end
	end
	return {}
end

type ButtonSpec = { text: string, color: Color3, enabled: boolean, onClick: () -> () }

local function card(
	order: number,
	title: string,
	subtitle: string,
	swatch: Color3?,
	buttons: { ButtonSpec },
	highlight: boolean?
)
	local g = grid
	if not g then
		return
	end
	local f = make("Frame", {
		LayoutOrder = order,
		BackgroundColor3 = if highlight then Color3.fromRGB(255, 236, 170) else C.cream,
		Parent = g,
	})
	Theme.corner(12).Parent = f
	Theme.stroke(if highlight then C.cheeseDark else C.brown, 3).Parent = f
	if swatch then
		local sw = make("Frame", {
			Position = UDim2.fromOffset(10, 10),
			Size = UDim2.fromOffset(28, 28),
			BackgroundColor3 = swatch,
			Parent = f,
		})
		Theme.round().Parent = sw
		Theme.stroke(C.brownDark, 2).Parent = sw
	end
	Theme.label({
		Position = UDim2.fromOffset(if swatch then 46 else 10, 8),
		Size = UDim2.new(1, if swatch then -56 else -20, 0, 30),
		TextSize = 20,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Text = title,
		Parent = f,
	})
	Theme.label({
		Position = UDim2.fromOffset(10, 40),
		Size = UDim2.new(1, -20, 0, 54),
		TextSize = 14,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = subtitle,
		Parent = f,
	})
	local row = make("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 8, 1, -8),
		Size = UDim2.new(1, -16, 0, 56),
		BackgroundTransparency = 1,
		Parent = f,
	})
	Theme.list(
		Enum.FillDirection.Horizontal,
		6,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	).Parent =
		row
	local width = math.floor((240 - 16 - 6 * (#buttons - 1)) / math.max(1, #buttons))
	for i, spec in buttons do
		local b = Theme.button(spec.text, spec.color, {
			LayoutOrder = i,
			Size = UDim2.fromOffset(width, 54),
			TextSize = 16,
			Parent = row,
		}, spec.onClick)
		Theme.setEnabled(b, spec.enabled)
	end
end

local function clearGrid()
	local g = grid
	if not g then
		return
	end
	for _, ch in g:GetChildren() do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	g.CanvasPosition = Vector2.zero
end

local function note(text: string)
	local g = grid
	if not g then
		return
	end
	Theme.label({
		LayoutOrder = 0,
		TextSize = 22,
		TextColor3 = C.ink,
		Text = text,
		Parent = g,
	})
end

----------------------------------------------------------------------
-- Tabs
----------------------------------------------------------------------

local function renderCosmetics()
	local p = profile()
	local owned = if type(p.cosmetics) == "table" then p.cosmetics else {}
	local equipped = if type(p.equipped) == "table" then p.equipped else {}
	local cheese = tonumber(p.cheese) or 0
	local golden = tonumber(p.goldenCheese) or 0
	-- Prices from the shop catalog (by cosmetic id).
	local cheesePrice: { [string]: number } = {}
	local goldenPrice: { [string]: number } = {}
	for _, e in shopEntries() do
		if e.kind == "cosmetic" and e.refId then
			if e.currency == "golden" then
				goldenPrice[e.refId] = tonumber(e.price) or 0
			else
				cheesePrice[e.refId] = tonumber(e.price) or 0
			end
		end
	end
	local defs = Defs.all("Cosmetics")
	if #defs == 0 then
		note("Cosmetics are coming soon! 🧀")
		return
	end
	for i, def in defs do
		local id = tostring(def.id)
		local slot = tostring(def.slot or "hat")
		local isOwned = owned[id] == true
		local isEquipped = equipped[slot] == id
		local buttons: { ButtonSpec } = {}
		local subtitle = string.upper(slot:sub(1, 1)) .. slot:sub(2)
		if def.description then
			subtitle ..= " · " .. tostring(def.description)
		end
		if isOwned then
			table.insert(buttons, {
				text = if isEquipped then "Unequip" else "Equip",
				color = if isEquipped then C.creamDark else C.green,
				enabled = true,
				onClick = function()
					Remotes.fire(Remotes.C2S.Equip, slot, if isEquipped then nil else id)
				end,
			})
		else
			local cp, gp = cheesePrice[id], goldenPrice[id]
			if cp then
				table.insert(buttons, {
					text = "🧀 " .. Format.short(cp),
					color = C.cheese,
					enabled = cheese >= cp,
					onClick = function()
						Remotes.fire(Remotes.C2S.BuyShopItem, "cosmetic:" .. id)
					end,
				})
			end
			if gp then
				table.insert(buttons, {
					text = "✨ " .. Format.short(gp),
					color = C.orange,
					enabled = golden >= gp,
					onClick = function()
						Remotes.fire(Remotes.C2S.BuyShopItem, "cosmetic:" .. id .. ":golden")
					end,
				})
			end
			if not cp and not gp then
				local src = SOURCE_TEXT[tostring(def.source)] or "Not for sale"
				if def.source == "level" and def.unlockLevel then
					src = "Unlocks at level " .. tostring(def.unlockLevel)
				end
				subtitle ..= "\n" .. src
			end
		end
		card(
			(if isOwned then 0 else 1000) + i,
			(if isEquipped then "✔ " else "") .. Defs.name(def, id),
			subtitle,
			if def.color then Format.rgb(def.color) else nil,
			buttons,
			isEquipped
		)
	end
end

local function fetchRobuxPrice(item: any)
	if priceRequested[item.key] or not item.configured or type(item.assetId) ~= "number" then
		return
	end
	priceRequested[item.key] = true
	task.spawn(function()
		local infoType = if item.kind == "pass" then Enum.InfoType.GamePass else Enum.InfoType.Product
		local ok, info = pcall(function()
			return (MarketplaceService :: any):GetProductInfoAsync(item.assetId, infoType)
		end)
		if not ok then
			ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(item.assetId, infoType)
			end)
		end
		if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
			robuxPrices[item.key] = tonumber(info.PriceInRobux) :: number
			if currentTab == "Boosts & Passes" and modal and modal.Visible then
				renderTab()
			end
		end
	end)
end

local function renderBoosts()
	local products = Defs.products()
	local order = 0
	if products == nil or #products == 0 then
		note("Boosts & Passes are coming soon! 🧀")
	else
		for _, item in products do
			order += 1
			fetchRobuxPrice(item)
			local price = robuxPrices[item.key] or item.price
			local available = item.configured ~= false
			card(order, tostring(item.name), tostring(item.description or ""), nil, {
				{
					text = if not available
						then "Coming soon"
						elseif price then "R$ " .. Format.int(price)
						else "Buy",
					color = C.green,
					enabled = available,
					onClick = function()
						Remotes.fire(Remotes.C2S.PromptProduct, item.key)
					end,
				},
			})
		end
	end
	-- Cheese token bundles (soft currency).
	local cheese = tonumber(profile().cheese) or 0
	for _, e in shopEntries() do
		if e.kind == "bundle" then
			order += 1
			local price = tonumber(e.price) or 0
			card(order + 500, tostring(e.name), "Token bundle (cheese)", nil, {
				{
					text = "🧀 " .. Format.short(price),
					color = C.cheese,
					enabled = cheese >= price,
					onClick = function()
						Remotes.fire(Remotes.C2S.BuyShopItem, tostring(e.itemId))
					end,
				},
			})
		end
	end
end

local function renderTalents()
	local p = profile()
	local levels = if type(p.talents) == "table" then p.talents else {}
	local cheese = tonumber(p.cheese) or 0
	local mod = Defs.module("Talents")
	local defs = Defs.list(mod)
	if #defs == 0 then
		note("Talents are coming soon! 🧀")
		return
	end
	for i, def in defs do
		local id = tostring(def.id)
		local lvl = tonumber(levels[id]) or 0
		local maxLevel = tonumber(def.maxLevel) or (if type(def.costs) == "table" then #def.costs else 1)
		local cost: number? = nil
		if mod and type(mod.costFor) == "function" then
			local ok, c = pcall(mod.costFor, id, lvl)
			if ok then
				cost = tonumber(c)
			end
		elseif type(def.costs) == "table" then
			cost = tonumber(def.costs[lvl + 1])
		end
		local maxed = lvl >= maxLevel or cost == nil
		card(
			i,
			string.format("%s  %d/%d", Defs.name(def, id), lvl, maxLevel),
			tostring(def.description or ""),
			nil,
			{
				{
					text = if maxed then "MAX" else "🧀 " .. Format.short(cost),
					color = if maxed then C.creamDark else C.cheese,
					enabled = not maxed and cheese >= (cost or math.huge),
					onClick = function()
						Remotes.fire(Remotes.C2S.BuyShopItem, "talent:" .. id)
					end,
				},
			}
		)
	end
end

renderTab = function()
	if not modal or not modal.Visible then
		return
	end
	clearGrid()
	for name, b in tabButtons do
		b.BackgroundColor3 = if name == currentTab then C.cheese else C.creamDark
	end
	if currentTab == "Cosmetics" then
		renderCosmetics()
	elseif currentTab == "Boosts & Passes" then
		renderBoosts()
	else
		renderTalents()
	end
end

local function renderHeader()
	local p = profile()
	if balanceLabel then
		balanceLabel.Text =
			string.format("🧀 %s   ✨ %s", Format.int(p.cheese), Format.int(p.goldenCheese))
	end
	local db = dailyButton
	if db then
		local daily = if type(p.daily) == "table" then p.daily else {}
		local claimable: boolean
		if type(daily.claimable) == "boolean" then
			claimable = daily.claimable
		else
			claimable = tonumber(daily.lastClaimDay) ~= math.floor(os.time() / 86400)
		end
		local streak = tonumber(daily.streak) or 0
		db.Text = if claimable
			then string.format("🎁 Claim daily (day %d)", math.min(7, streak + 1))
			else string.format("🎁 Streak %d · come back tomorrow", streak)
		Theme.setEnabled(db, claimable)
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function ShopUI.open()
	if not modal then
		return
	end
	modal.Visible = true
	Theme.popIn(modal)
	renderHeader()
	renderTab()
end

function ShopUI.close()
	if modal then
		modal.Visible = false
	end
end

function ShopUI.toggle()
	if modal and modal.Visible then
		ShopUI.close()
	else
		ShopUI.open()
	end
end

function ShopUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallShop", 35)
	local m = Theme.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(1000, 540),
		Visible = false,
		Parent = screen.root,
	})
	modal = m
	Theme.label({
		Position = UDim2.fromOffset(20, 8),
		Size = UDim2.fromOffset(200, 44),
		TextSize = 34,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "🛒 Shop",
		Parent = m,
	})
	balanceLabel = Theme.label({
		Position = UDim2.fromOffset(170, 12),
		Size = UDim2.fromOffset(260, 40),
		TextSize = 22,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = m,
	})
	dailyButton = Theme.button("🎁 Daily", C.green, {
		Position = UDim2.fromOffset(440, 6),
		Size = UDim2.fromOffset(400, 58),
		TextSize = 20,
		Parent = m,
	}, function()
		Remotes.fire(Remotes.C2S.ClaimDaily)
	end)
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 6),
		Size = UDim2.fromOffset(Theme.TOUCH, 58),
		TextColor3 = C.white,
		Parent = m,
	}, ShopUI.close)

	local tabs = make("Frame", {
		Position = UDim2.fromOffset(16, 72),
		Size = UDim2.new(1, -32, 0, Theme.TOUCH - 6),
		BackgroundTransparency = 1,
		Parent = m,
	})
	Theme.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left).Parent = tabs
	for i, name in TABS do
		tabButtons[name] = Theme.button(name, C.creamDark, {
			LayoutOrder = i,
			Size = UDim2.fromOffset(240, Theme.TOUCH - 6),
			TextSize = 22,
			Parent = tabs,
		}, function()
			currentTab = name
			renderTab()
		end)
	end

	local g = make("ScrollingFrame", {
		Position = UDim2.fromOffset(16, 72 + Theme.TOUCH + 6),
		Size = UDim2.new(1, -32, 1, -(72 + Theme.TOUCH + 20)),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 10,
		ScrollBarImageColor3 = C.brown,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = m,
	}) :: ScrollingFrame
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(240, 168),
		CellPadding = UDim2.fromOffset(10, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = g,
	})
	Theme.padding(4, 4).Parent = g
	grid = g

	table.insert(
		unsubs,
		State.subscribe("profile", function()
			if modal and modal.Visible then
				renderHeader()
				renderTab()
			end
		end)
	)
	table.insert(
		unsubs,
		State.subscribe("run", function()
			if not State.inLobby() then
				ShopUI.close()
			end
		end)
	)
end

function ShopUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	if screen then
		screen.destroy()
		screen = nil
	end
	modal = nil
	grid = nil
	table.clear(tabButtons)
end

return ShopUI
