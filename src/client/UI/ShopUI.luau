--!strict
-- Lobby shop v2 (docs/V4-PLAN.md "Robux shop v2", review C §4). Tabs, from
-- Util/ShopModel.TABS:
--   Featured       today's cosmetics (the same for everyone, no timers), packs
--                  and bundles, the Herd Pass. Nothing ticks, nothing "leaves".
--   Cosmetics      cheese / Golden Cheese cosmetics with filters (Hats, Trails,
--                  Tints, Skins, Owned) and Equip / Unequip; paid class skins.
--   Passes         permanent game passes: "✔ Owned" when owned, benefits as
--                  bullets plus "Details" with the full text (never clipped).
--   Golden Cheese  the packs (+ Cheese Club only once it is live).
--   Boosts         active boost timers (Rush, Feast, Herd Leader) on top, then
--                  Rush / Feast / Respec Token, Second Wind last with its rules.
--   Herd Pass      season progress and the premium track (opens UI/ProgressUI).
--   Cheese Shop    talents and token bundles (cheese only).
-- Header: balances and the daily reward claim (Net.C2S.ClaimDaily) with a dot.
--
-- Rules: never auto-prompt; a Robux prompt only follows a click on a price
-- button. Owned items never show a price. Prices are only the live
-- GetProductInfoAsync price ("R$ —" until known).
--
-- Entry points (all just open the shop; none prompts):
--   * the lobby bar's 🛒 button (UI/LobbyUI; dot = daily ready / pass tier claimable)
--   * the lobby kiosk: any ProximityPrompt named "ShopKiosk" or with the
--     attribute OpenShop = true (optional attribute ShopTab = "<tab name>")
--     opens the shop when triggered (ProximityPromptService.PromptTriggered).
--   * the "View in shop" card on a WIN results screen (UI/ResultsUI)
--   * ShopUI.open(tab?) from other UIs.
-- While open the player is "busy" (State.setBusy -> Net.C2S.SetBusy), so the
-- lobby auto-start does not pull them into a match (V4-PLAN M8).

local MarketplaceService = game:GetService("MarketplaceService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Remotes = require(Client.Util.Remotes)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local ShopModel = require(Client.Util.ShopModel)
local Progression = require(Client.Util.Progression)
local State = require(Client.Controllers.State)

local ShopUI = {}

local C = Theme.C
local make = Theme.make

local TABS = ShopModel.TABS
local COSMETIC_FILTERS = { "All", "Hats", "Trails", "Tints", "Skins", "Owned" }
local SOURCE_TEXT: { [string]: string } = {
	pass = "From a game pass",
	daily = "Daily streak reward",
	club = "Cheese Club reward",
	level = "Account level reward",
	epic = "Epic boss drop",
	season = "Herd Pass reward",
	achievement = "Achievement reward",
}

local screen: any = nil
local modal: Frame? = nil
local content: ScrollingFrame? = nil
local detailsPanel: Frame? = nil
local detailsTitle: TextLabel? = nil
local detailsText: TextLabel? = nil
local tabButtons: { [string]: TextButton } = {}
local tabDots: { [string]: Frame } = {}
local balanceLabel: TextLabel? = nil
local busyNote: TextLabel? = nil
local dailyButton: TextButton? = nil
local dailyDot: Frame? = nil
local currentTab = TABS[1]
local cosmeticFilter = "All"
local unsubs: { () -> () } = {}
local conns: { RBXScriptConnection } = {}
local robuxPrices: { [string]: number } = {}
local priceRequestedAt: { [string]: number } = {}
local PRICE_RETRY_SECONDS = 60
local boostLabels: { { label: TextLabel, key: string } } = {}
local allProducts: { any } = {} -- last product list (ShopModel.blocked checks bundles)

-- The server applies one PromptProduct cooldown (1.5 s) to "refresh" and to
-- real purchase prompts, so: refresh at most every 30 s, and hold back a buy
-- click that comes right after a refresh until the cooldown has passed.
local REFRESH_EVERY = 30
local PROMPT_COOLDOWN = 1.6
local lastPromptAt = -math.huge
local lastRefreshAt = -math.huge
local pendingPrompt: string? = nil

local function sendPrompt(key: string)
	local remaining = lastPromptAt + PROMPT_COOLDOWN - os.clock()
	if remaining <= 0 then
		lastPromptAt = os.clock()
		Remotes.fire(Remotes.C2S.PromptProduct, key)
		return
	end
	-- Only the latest click matters; one delayed send at a time.
	local scheduled = pendingPrompt ~= nil
	pendingPrompt = key
	if not scheduled then
		task.delay(remaining, function()
			local k = pendingPrompt
			pendingPrompt = nil
			if k then
				lastPromptAt = os.clock()
				Remotes.fire(Remotes.C2S.PromptProduct, k)
			end
		end)
	end
end

local function refreshOwnership()
	local now = os.clock()
	if now - lastRefreshAt < REFRESH_EVERY or now - lastPromptAt < PROMPT_COOLDOWN then
		return
	end
	lastRefreshAt = now
	lastPromptAt = now
	Remotes.fire(Remotes.C2S.PromptProduct, "refresh")
end

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

local function today(): number
	return math.floor(os.time() / 86400)
end

----------------------------------------------------------------------
-- Building blocks (all children of the scrolling `content` list)
----------------------------------------------------------------------

local order = 0
local function nextOrder(): number
	order += 1
	return order
end

local function clearContent()
	local c = content
	if not c then
		return
	end
	for _, ch in c:GetChildren() do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	table.clear(boostLabels)
	order = 0
	c.CanvasPosition = Vector2.zero
end

local function section(title: string, sub: string?)
	local c = content
	if not c then
		return
	end
	local f = make("Frame", {
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = c,
	})
	Theme.list(Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Left).Parent = f
	Theme.label({
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 26),
		TextSize = 20,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = title,
		Parent = f,
	})
	if sub then
		Theme.label({
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextSize = 13,
			Font = Theme.FONT_BODY,
			TextColor3 = C.brown,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = sub,
			Parent = f,
		})
	end
end

local function note(text: string)
	local c = content
	if not c then
		return
	end
	Theme.label({
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextSize = 16,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		Text = text,
		Parent = c,
	})
end

local CELL_W = 228
local function gridHolder(): Frame?
	local c = content
	if not c then
		return nil
	end
	local f = make("Frame", {
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = c,
	})
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(CELL_W, 96 + Theme.TOUCH),
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = f,
	})
	return f
end

type ButtonSpec = { text: string, color: Color3, enabled: boolean, onClick: () -> (), width: number? }

local function buttonRow(parent: Instance, buttons: { ButtonSpec }, width: number, props: { [string]: any })
	local row = make("Frame", {
		Size = UDim2.new(1, -16, 0, Theme.TOUCH),
		BackgroundTransparency = 1,
		Parent = parent,
	})
	for k, v in props do
		(row :: any)[k] = v
	end
	Theme.list(
		Enum.FillDirection.Horizontal,
		6,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	).Parent =
		row
	local each = math.floor((width - 6 * (#buttons - 1)) / math.max(1, #buttons))
	for i, spec in buttons do
		local b = Theme.button(spec.text, spec.color, {
			LayoutOrder = i,
			Size = UDim2.fromOffset(spec.width or each, Theme.TOUCH),
			TextSize = 15,
			Parent = row,
		}, spec.onClick)
		Theme.setEnabled(b, spec.enabled)
	end
	return row
end

-- Grid card (cosmetics, talents, bundles): title, a short wrapped line, buttons.
local function gridCard(
	g: Frame?,
	title: string,
	subtitle: string,
	swatch: Color3?,
	buttons: { ButtonSpec },
	opts: { highlight: boolean?, owned: boolean?, sort: number? }?
)
	if not g then
		return
	end
	local o = opts or {}
	local f = make("Frame", {
		LayoutOrder = o.sort or 0,
		BackgroundColor3 = if o.highlight then Color3.fromRGB(255, 236, 170) else C.cream,
		Parent = g,
	})
	Theme.corner(10).Parent = f
	Theme.stroke(if o.highlight then C.cheeseDark else C.brown, 2).Parent = f
	Theme.skinCard(f, if o.highlight then "Legendary" else nil) -- texture once uploaded
	if swatch then
		local sw = make("Frame", {
			Position = UDim2.fromOffset(8, 8),
			Size = UDim2.fromOffset(26, 26),
			BackgroundColor3 = swatch,
			Parent = f,
		})
		Theme.round().Parent = sw
		Theme.stroke(C.brownDark, 2).Parent = sw
	end
	Theme.label({
		Position = UDim2.fromOffset(if swatch then 40 else 8, 6),
		Size = UDim2.new(1, if swatch then -48 else -16, 0, 28),
		TextSize = 17,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Text = title,
		Parent = f,
	})
	Theme.label({
		Position = UDim2.fromOffset(8, 36),
		Size = UDim2.new(1, -16, 1, -(36 + Theme.TOUCH + 12)),
		TextSize = 12,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = subtitle,
		Parent = f,
	})
	if o.owned then
		Theme.badge("OWNED", C.greenDark, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, -8),
			Size = UDim2.fromOffset(0, 18),
			TextSize = 11,
			ZIndex = 3,
			Parent = f,
		})
	end
	buttonRow(f, buttons, CELL_W - 16, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 8, 1, -6),
	})
end

local function openDetails(title: string, text: string)
	local d, t, x = detailsPanel, detailsTitle, detailsText
	if not (d and t and x) then
		return
	end
	t.Text = title
	x.Text = text
	d.Visible = true
	Theme.popIn(d)
end

----------------------------------------------------------------------
-- Robux rows
----------------------------------------------------------------------

local function fetchRobuxPrice(item: any)
	if robuxPrices[item.key] or not item.configured or type(item.assetId) ~= "number" then
		return
	end
	local last = priceRequestedAt[item.key]
	if last and os.clock() - last < PRICE_RETRY_SECONDS then
		return
	end
	priceRequestedAt[item.key] = os.clock()
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
			if modal and modal.Visible then
				renderTab()
			end
		end
	end)
end

-- Full-width row: name, up to 4 benefit bullets (wrapped, never clipped),
-- "Details" for the full text, and the price / Owned button.
local function robuxRow(item: any)
	local c = content
	if not c then
		return
	end
	fetchRobuxPrice(item)
	local owned = ShopModel.owned(item, profile())
	local blocked = if owned then nil else ShopModel.blocked(item, profile(), allProducts)
	local available = item.configured ~= false
	local f = make("Frame", {
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = if owned then Color3.fromRGB(226, 244, 214) else C.cream,
		Parent = c,
	})
	Theme.corner(10).Parent = f
	Theme.stroke(if owned then C.greenDark else C.brown, 2).Parent = f
	Theme.skinCard(f, if owned then "Uncommon" else "Rare") -- texture once uploaded
	Theme.padding(10, 8).Parent = f
	local rightW = 150
	local left = make("Frame", {
		Size = UDim2.new(1, -(rightW + 10), 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = f,
	})
	Theme.list(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Left).Parent = left
	Theme.label({
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 24),
		TextSize = 18,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = (if owned then "✔ " else "") .. tostring(item.name),
		Parent = left,
	})
	local bullets, more = ShopModel.bullets(item.description, 4)
	for i, b in bullets do
		Theme.label({
			LayoutOrder = 1 + i,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextSize = 13,
			Font = Theme.FONT_BODY,
			TextColor3 = C.brown,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "• " .. b,
			Parent = left,
		})
	end
	local right = make("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(rightW, Theme.TOUCH * 2 + 6),
		BackgroundTransparency = 1,
		Parent = f,
	})
	Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Right).Parent = right
	local buy = Theme.button(
		blocked or ShopModel.robuxLabel(owned, available, robuxPrices[item.key]),
		if owned then C.creamDark else C.green,
		{ LayoutOrder = 1, Size = UDim2.fromOffset(rightW, Theme.TOUCH), TextSize = 17, Parent = right },
		function()
			if not owned and not blocked and available then
				sendPrompt(tostring(item.key))
			end
		end
	)
	Theme.setEnabled(buy, available and not owned and blocked == nil)
	if more or #bullets == 0 then
		Theme.button("Details", C.creamDark, {
			LayoutOrder = 2,
			Size = UDim2.fromOffset(rightW, Theme.TOUCH),
			TextSize = 15,
			Parent = right,
		}, function()
			openDetails(tostring(item.name), tostring(item.description or ""))
		end)
	end
end

----------------------------------------------------------------------
-- Cosmetic cards (shared by Featured and Cosmetics)
----------------------------------------------------------------------

local function cosmeticPrices(): ({ [string]: number }, { [string]: number })
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
	return cheesePrice, goldenPrice
end

local function cosmeticCard(g: Frame?, def: any, sortBase: number)
	local p = profile()
	local owned = if type(p.cosmetics) == "table" then p.cosmetics else {}
	local equipped = if type(p.equipped) == "table" then p.equipped else {}
	local cheese = tonumber(p.cheese) or 0
	local golden = tonumber(p.goldenCheese) or 0
	local cheesePrice, goldenPrice = cosmeticPrices()
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
			local can = golden >= gp
			table.insert(buttons, {
				text = "✨ " .. Format.short(gp),
				color = C.orange,
				enabled = true,
				onClick = function()
					if can then
						Remotes.fire(Remotes.C2S.BuyShopItem, "cosmetic:" .. id .. ":golden")
					else
						-- not enough: show where Golden Cheese comes from (never prompts)
						currentTab = "Golden Cheese"
						renderTab()
					end
				end,
			})
		end
		if not cp and not gp then
			local src = SOURCE_TEXT[tostring(def.source)] or "Not for sale"
			if def.source == "level" and def.unlockLevel then
				src = "Unlocks at account level " .. tostring(def.unlockLevel)
			end
			subtitle = src .. " · " .. subtitle
		end
	end
	gridCard(
		g,
		(if isEquipped then "✔ " else "") .. Defs.name(def, id),
		subtitle,
		if def.color then Format.rgb(def.color) else nil,
		buttons,
		{ highlight = isEquipped, owned = isOwned, sort = sortBase }
	)
end

local function skinCard(g: Frame?, e: any, sortBase: number)
	local p = profile()
	local ownedSkins = if type(p.ownedSkins) == "table" then p.ownedSkins else {}
	local golden = tonumber(p.goldenCheese) or 0
	local skinId = tostring(e.refId)
	local def = Defs.get("ClassSkins", skinId)
	local classDef = def and Defs.get("Classes", def.classId)
	local price = tonumber(e.price) or 0
	local isOwned = ownedSkins[skinId] == true
	local color = if def
			and type(def.colors) == "table"
			and def.colors.body
		then Format.rgb(def.colors.body)
		else nil
	gridCard(
		g,
		tostring(e.name or skinId),
		string.format(
			"%s skin · cosmetic only%s",
			if classDef then Defs.name(classDef, def.classId) else "Class",
			if isOwned then " · pick it in the class picker" else ""
		),
		color,
		if isOwned
			then {}
			else {
				{
					text = "✨ " .. Format.short(price),
					color = C.orange,
					enabled = true,
					onClick = function()
						if golden >= price then
							Remotes.fire(Remotes.C2S.BuyShopItem, tostring(e.itemId))
						else
							currentTab = "Golden Cheese"
							renderTab()
						end
					end,
				},
			},
		{ owned = isOwned, sort = sortBase }
	)
end

----------------------------------------------------------------------
-- Tabs
----------------------------------------------------------------------

local function productsFor(tab: string): { any }
	local products = Defs.products() or {}
	-- Defs.products drops item fields the model needs; re-attach from the config.
	local mod = Defs.module("Monetization")
	if type(mod) == "table" and type(mod.get) == "function" then
		for _, it in products do
			local ok, raw = pcall(mod.get, it.key)
			if ok and type(raw) == "table" then
				for _, f in
					{
						"boostSeconds",
						"secondWindTokens",
						"respecTokens",
						"goldenCheese",
						"tab",
						"shopTab",
						"herdPass",
						"bundle",
						"oncePerAccount",
						"oneTime",
						"covers",
						"cosmetics",
						"emotes",
						"skinPasses",
						"passSeason",
					}
				do
					if it[f] == nil then
						it[f] = raw[f]
					end
				end
			end
		end
	end
	allProducts = products
	local list = ShopModel.itemsFor(tab, products, profile())
	if tab == "Herd Pass" then
		-- only this season's premium track (Pass view `premiumKey`)
		local pv = State.get("pass")
		local key = if type(pv) == "table" then pv.premiumKey else nil
		if key ~= nil then
			local only = {}
			for _, it in list do
				if it.key == key then
					table.insert(only, it)
				end
			end
			list = only
		end
	end
	return list
end

local function renderFeatured()
	-- No timers, no countdowns, nothing "leaving": just today's picks.
	section("★ Today's picks", "The same for every player today.")
	local entries = shopEntries()
	local picks = ShopModel.featuredCosmetics(entries, today(), Defs.module("Shop"))
	if #picks > 0 then
		local g = gridHolder()
		for i, e in picks do
			if e.kind == "skin" then
				skinCard(g, e, i)
			else
				local def = Defs.get("Cosmetics", e.refId or e.id)
				if def then
					cosmeticCard(g, def, i)
				end
			end
		end
	end
	local packs = productsFor("Featured")
	if #packs > 0 then
		section("🎁 Packs & bundles", "Fixed contents. Nothing is random.")
		for _, it in packs do
			robuxRow(it)
		end
	end
	local pass = productsFor("Herd Pass")
	if #pass > 0 then
		section("🐘 Herd Pass")
		for _, it in pass do
			robuxRow(it)
		end
	end
	if #picks == 0 and #packs == 0 and #pass == 0 then
		note("New things are on the way! 🧀")
	end
end

local function slotMatches(def: any, filter: string, ownedSet: { [string]: any }): boolean
	local slot = tostring(def.slot or "hat")
	if filter == "All" then
		return true
	elseif filter == "Hats" then
		return slot == "hat"
	elseif filter == "Trails" then
		return slot == "trail"
	elseif filter == "Tints" then
		return slot == "tint"
	elseif filter == "Owned" then
		return ownedSet[tostring(def.id)] == true
	end
	return false
end

local function renderCosmetics()
	local c = content
	if not c then
		return
	end
	-- filter chips
	local bar = make("Frame", {
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, -8, 0, Theme.SLIM),
		BackgroundTransparency = 1,
		Parent = c,
	})
	Theme.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent =
		bar
	for i, name in COSMETIC_FILTERS do
		Theme.button(name, if name == cosmeticFilter then C.cheese else C.creamDark, {
			LayoutOrder = i,
			Size = UDim2.fromOffset(96, Theme.SLIM),
			TextSize = 14,
			Parent = bar,
		}, function()
			cosmeticFilter = name
			renderTab()
		end)
	end
	local p = profile()
	local ownedSet = if type(p.cosmetics) == "table" then p.cosmetics else {}
	local defs = Defs.all("Cosmetics")
	local g = gridHolder()
	local n = 0
	if cosmeticFilter ~= "Skins" then
		for i, def in defs do
			if slotMatches(def, cosmeticFilter, ownedSet) then
				n += 1
				cosmeticCard(g, def, (if ownedSet[tostring(def.id)] then 0 else 1000) + i)
			end
		end
	end
	if cosmeticFilter == "All" or cosmeticFilter == "Skins" or cosmeticFilter == "Owned" then
		local ownedSkins = if type(p.ownedSkins) == "table" then p.ownedSkins else {}
		local k = 0
		for _, e in shopEntries() do
			if e.kind == "skin" and e.refId then
				k += 1
				if cosmeticFilter ~= "Owned" or ownedSkins[tostring(e.refId)] == true then
					n += 1
					skinCard(g, e, 2000 + k)
				end
			end
		end
	end
	if n == 0 then
		note(if cosmeticFilter == "Owned" then "Nothing here yet." else "Cosmetics are coming soon! 🧀")
	end
end

local function renderRobuxTab(tab: string, empty: string)
	local items = productsFor(tab)
	if #items == 0 then
		note(empty)
		return
	end
	for _, it in items do
		robuxRow(it)
	end
end

local function renderBoosts()
	-- Live timers first (M3). Updated every second while the tab is open.
	local boosts = Progression.boosts(profile(), os.clock() - (State.get("profileAt") or os.clock()))
	if #boosts > 0 then
		section("⚡ Active now")
		local c = content
		for _, b in boosts do
			if c then
				local l = Theme.label({
					LayoutOrder = nextOrder(),
					Size = UDim2.new(1, -8, 0, 22),
					TextSize = 16,
					Font = Theme.FONT_BODY,
					TextColor3 = C.greenDark,
					TextXAlignment = Enum.TextXAlignment.Left,
					Text = "● " .. b.text,
					Parent = c,
				})
				table.insert(boostLabels, { label = l, key = b.key })
			end
		end
	end
	local items = productsFor("Boosts")
	-- Second Wind last, with its rules in full.
	table.sort(items, function(a, b)
		local sa, sb = a.secondWindTokens ~= nil, b.secondWindTokens ~= nil
		if sa ~= sb then
			return not sa
		end
		return (tonumber(a.price) or 0) < (tonumber(b.price) or 0)
	end)
	section("Boosts")
	if #items == 0 then
		note("Boosts are coming soon! 🧀")
	end
	for _, it in items do
		robuxRow(it)
	end
end

local function renderHerdPass()
	local pv = Progression.pass(State.get("pass"), Defs.module("Pass"))
	section(
		string.format("🐘 Herd Pass%s", if pv.seasonName then " · " .. pv.seasonName else ""),
		"Earn Pass XP from Herd Contracts and runs. Rewards are cosmetics and currency only."
	)
	local c = content
	if c then
		local bar = Theme.bar({
			LayoutOrder = nextOrder(),
			Size = UDim2.new(1, -8, 0, 22),
			Parent = c,
		}, C.xp)
		bar.set(
			pv.xp / pv.xpPerTier,
			string.format(
				"Tier %d / %d · %s / %s XP",
				pv.tier,
				#pv.tiers,
				Format.int(pv.xp),
				Format.int(pv.xpPerTier)
			)
		)
		local row = make("Frame", {
			LayoutOrder = nextOrder(),
			Size = UDim2.new(1, -8, 0, Theme.TOUCH),
			BackgroundTransparency = 1,
			Parent = c,
		})
		Theme.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left).Parent = row
		Theme.button(
			if pv.claimable > 0
				then string.format("Open Herd Pass (%d to claim)", pv.claimable)
				else "Open Herd Pass",
			C.green,
			{
				LayoutOrder = 1,
				Size = UDim2.fromOffset(320, Theme.TOUCH),
				TextSize = 17,
				TextColor3 = C.white,
				Parent = row,
			},
			function()
				local ok, P = pcall(require, script.Parent.ProgressUI)
				if ok and type(P) == "table" and P.open then
					ShopUI.close()
					P.open("Herd Pass")
				end
			end
		)
	end
	if pv.premium then
		note("✔ You own this season's premium track.")
	end
	for _, it in productsFor("Herd Pass") do
		robuxRow(it)
	end
end

local function renderCheeseShop()
	local p = profile()
	local levels = if type(p.talents) == "table" then p.talents else {}
	local cheese = tonumber(p.cheese) or 0
	local mod = Defs.module("Talents")
	local defs = Defs.list(mod)
	section("🧀 Talents", "Permanent upgrades, bought with cheese.")
	local g = gridHolder()
	for i, def in defs do
		local id = tostring(def.id)
		local lvl = tonumber(levels[id]) or 0
		local maxLevel = tonumber(def.maxLevel) or (if type(def.costs) == "table" then #def.costs else 1)
		local cost: number? = nil
		if mod and type(mod.costFor) == "function" then
			local ok, cst = pcall(mod.costFor, id, lvl)
			if ok then
				cost = tonumber(cst)
			end
		elseif type(def.costs) == "table" then
			cost = tonumber(def.costs[lvl + 1])
		end
		local maxed = lvl >= maxLevel or cost == nil
		gridCard(
			g,
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
			},
			{ sort = i }
		)
	end
	local bundles = {}
	for _, e in shopEntries() do
		if e.kind == "bundle" then
			table.insert(bundles, e)
		end
	end
	if #bundles > 0 then
		section("🎟 Token bundles")
		local g2 = gridHolder()
		for i, e in bundles do
			local price = tonumber(e.price) or 0
			gridCard(g2, tostring(e.name), "Bought with cheese", nil, {
				{
					text = "🧀 " .. Format.short(price),
					color = C.cheese,
					enabled = cheese >= price,
					onClick = function()
						Remotes.fire(Remotes.C2S.BuyShopItem, tostring(e.itemId))
					end,
				},
			}, { sort = i })
		end
	end
	note("New classes are in the class picker (🐘 button in the lobby bar).")
end

renderTab = function()
	if not modal or not modal.Visible then
		return
	end
	clearContent()
	for name, b in tabButtons do
		b.BackgroundColor3 = if name == currentTab then C.cheese else C.creamDark
	end
	if currentTab == "Featured" then
		renderFeatured()
	elseif currentTab == "Cosmetics" then
		renderCosmetics()
	elseif currentTab == "Passes" then
		renderRobuxTab("Passes", "Passes are coming soon! 🧀")
	elseif currentTab == "Golden Cheese" then
		section("✨ Golden Cheese", "Buys cosmetics and class skins. Never stats.")
		renderRobuxTab("Golden Cheese", "Golden Cheese packs are coming soon! 🧀")
	elseif currentTab == "Boosts" then
		renderBoosts()
	elseif currentTab == "Herd Pass" then
		renderHerdPass()
	else
		renderCheeseShop()
	end
end

local function renderHeader()
	local p = profile()
	if balanceLabel then
		balanceLabel.Text =
			string.format("🧀 %s   ✨ %s", Format.short(p.cheese), Format.short(p.goldenCheese))
	end
	local dots = Progression.dots(p, State.get("quests"), State.get("pass"), Defs.module("AccountRewards"))
	local db = dailyButton
	if db then
		local daily = if type(p.daily) == "table" then p.daily else {}
		local streak = tonumber(daily.streak) or 0
		db.Text = if dots.daily
			then string.format("🎁 Claim daily (day %d)", math.min(7, streak + 1))
			else string.format("🎁 Streak %d ✔", streak)
		Theme.setEnabled(db, dots.daily)
	end
	if dailyDot then
		dailyDot.Visible = dots.daily
	end
	local passDot = tabDots["Herd Pass"]
	if passDot then
		passDot.Visible = dots.pass > 0
	end
	local bn = busyNote
	if bn then
		local lobby = State.get("lobby")
		bn.Visible = type(lobby) == "table" and lobby.startsAt ~= nil and not lobby.runActive
	end
end

-- Ticks the boost timer lines (no re-render).
local function tickBoosts()
	if #boostLabels == 0 then
		return
	end
	local list = Progression.boosts(profile(), os.clock() - (State.get("profileAt") or os.clock()))
	local byKey: { [string]: string } = {}
	for _, b in list do
		byKey[b.key] = b.text
	end
	for _, e in boostLabels do
		local t = byKey[e.key]
		e.label.Text = if t then "● " .. t else "● Ended"
	end
end

local function dot(parent: Instance): Frame
	local d = make("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 3, 0, -3),
		Size = UDim2.fromOffset(12, 12),
		BackgroundColor3 = C.cheese,
		Visible = false,
		ZIndex = 6,
		Parent = parent,
	}) :: Frame
	Theme.round().Parent = d
	Theme.stroke(C.brownDark, 2).Parent = d
	Theme.skinDot(d) -- texture once uploaded
	return d
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function ShopUI.isOpen(): boolean
	return modal ~= nil and (modal :: Frame).Visible
end

function ShopUI.open(tab: string?)
	if not modal or not State.inLobby() then
		return
	end
	if tab and table.find(TABS, tab) then
		currentTab = tab
	end
	modal.Visible = true
	if detailsPanel then
		detailsPanel.Visible = false
	end
	State.setBusy("shop", true)
	Theme.popIn(modal)
	refreshOwnership()
	renderHeader()
	renderTab()
end

-- Opens now in the lobby, else as soon as the player is back in the lobby
-- (the Results "View in shop" card). Still never prompts.
local pendingTab: string? = nil
function ShopUI.openWhenLobby(tab: string?)
	if State.inLobby() then
		ShopUI.open(tab)
	else
		pendingTab = tab or "Featured"
	end
end

function ShopUI.close()
	if modal then
		modal.Visible = false
	end
	State.setBusy("shop", false)
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
	local touch = Theme.TOUCH
	local headH = math.max(56, touch + 8)
	local tabH = Theme.SLIM + 4
	local m = Theme.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(1000, 560),
		Visible = false,
		Parent = screen.root,
	})
	-- Capped to the screen; the content below the tabs scrolls.
	table.insert(unsubs, Theme.fitFrame(screen, m, 1000, 600, 10))
	Theme.compact(m) -- v3: 10% smaller on PC
	modal = m
	Theme.header(Theme.label({
		Position = UDim2.fromOffset(16, 6),
		Size = UDim2.fromOffset(120, 40),
		TextSize = 28,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "🛒 Shop",
		Parent = m,
	})) -- ribbon once uploaded
	balanceLabel = Theme.label({
		Position = UDim2.fromOffset(136, 10),
		Size = UDim2.fromOffset(220, 34),
		TextSize = 18,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = m,
	})
	busyNote = Theme.label({
		Position = UDim2.fromOffset(136, 38),
		Size = UDim2.fromOffset(330, 16),
		TextSize = 11,
		Font = Theme.FONT_LIGHT,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "You'll join the next match when you close the shop.",
		Visible = false,
		Parent = m,
	})
	local db = Theme.button("🎁 Daily", C.green, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(touch + 22), 0, 6),
		Size = UDim2.fromOffset(230, touch),
		TextSize = 17,
		Parent = m,
	}, function()
		Remotes.fire(Remotes.C2S.ClaimDaily)
	end)
	dailyButton = db
	dailyDot = dot(db)
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 6),
		Size = UDim2.fromOffset(touch, touch),
		TextColor3 = C.white,
		Parent = m,
	}, ShopUI.close)

	-- Tabs: a horizontal scroller so all seven fit on any phone.
	local tabs = make("ScrollingFrame", {
		Position = UDim2.fromOffset(12, headH),
		Size = UDim2.new(1, -24, 0, tabH + 6),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(),
		Parent = m,
	})
	Theme.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top).Parent =
		tabs
	Theme.padding(4, 3).Parent = tabs
	for i, name in TABS do
		local b = Theme.tab(ShopModel.SHORT[name] or name, {
			LayoutOrder = i,
			Size = UDim2.fromOffset(132, tabH),
			TextSize = 15,
			Parent = tabs,
		}, function()
			currentTab = name
			renderTab()
		end)
		tabButtons[name] = b
		tabDots[name] = dot(b)
	end

	local top = headH + tabH + 12
	local c = Theme.scroller({
		Position = UDim2.fromOffset(12, top),
		Size = UDim2.new(1, -24, 1, -(top + 10)),
		Parent = m,
	})
	Theme.list(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Left).Parent = c
	Theme.padding(4, 4).Parent = c
	content = c

	-- Details overlay: the full benefit text, scrollable (fixes M9).
	local d = Theme.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.55),
		Size = UDim2.new(0.8, 0, 0.7, 0),
		Visible = false,
		ZIndex = 10,
		Parent = m,
	})
	detailsPanel = d
	detailsTitle = Theme.label({
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, -(touch + 40), 0, 32),
		TextSize = 22,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 11,
		Parent = d,
	})
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		Size = UDim2.fromOffset(touch, touch),
		TextColor3 = C.white,
		ZIndex = 11,
		Parent = d,
	}, function()
		d.Visible = false
	end)
	local ds = Theme.scroller({
		Position = UDim2.fromOffset(16, touch + 12),
		Size = UDim2.new(1, -32, 1, -(touch + 20)),
		ZIndex = 11,
		Parent = d,
	})
	detailsText = Theme.label({
		Size = UDim2.new(1, -12, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextSize = 16,
		Font = Theme.FONT_BODY,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 11,
		Parent = ds,
	})

	table.insert(
		unsubs,
		State.subscribe("profile", function()
			if modal and modal.Visible then
				renderHeader()
				renderTab()
			end
		end)
	)
	for _, key in { "pass", "quests", "lobby" } do
		table.insert(
			unsubs,
			State.subscribe(key, function()
				if modal and modal.Visible then
					renderHeader()
					if key == "pass" and currentTab == "Herd Pass" then
						renderTab()
					end
				end
			end)
		)
	end
	table.insert(
		unsubs,
		State.subscribe("run", function()
			if not State.inLobby() and modal and modal.Visible then
				ShopUI.close()
			elseif State.inLobby() and pendingTab then
				local t = pendingTab
				pendingTab = nil
				task.defer(ShopUI.open, t)
			end
		end)
	)

	-- Lobby kiosk (Team G builds it): a ProximityPrompt named "ShopKiosk" or
	-- with attribute OpenShop = true. Optional attribute ShopTab picks the tab.
	table.insert(
		conns,
		ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt)
			if prompt.Name == "ShopKiosk" or prompt:GetAttribute("OpenShop") == true then
				local tab = prompt:GetAttribute("ShopTab")
				ShopUI.open(if type(tab) == "string" then tab else "Featured")
			end
		end)
	)

	-- Boost timers tick once a second while the Boosts tab is open.
	task.spawn(function()
		while screen do
			task.wait(1)
			if modal and modal.Visible and currentTab == "Boosts" then
				tickBoosts()
			end
		end
	end)
end

function ShopUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	for _, cn in conns do
		cn:Disconnect()
	end
	table.clear(conns)
	State.setBusy("shop", false)
	if screen then
		screen.destroy()
		screen = nil
	end
	modal = nil
	content = nil
	detailsPanel = nil
	table.clear(tabButtons)
	table.clear(tabDots)
end

return ShopUI
