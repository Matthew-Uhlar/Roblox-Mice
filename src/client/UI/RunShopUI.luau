--!strict
-- v5 in-run shop UI (docs/V5-PLAN.md §A, iteration 1 §D). Pure maths in
-- Util/RunShopModel; numbers from Config/RunShop.
--
--   wallet HUD    a pill under the minimap: 🔶 rinds · 🥛 whey · 🐭 stomps
--                 (State "wallet" from Net.S2C.Wallet). Click (PC) / the
--                 phone 🛠 button opens the upgrade menu.
--   upgrade menu  V (or the phone 🛠 button). Tabs:
--                   Ranks        8 stat ranks, 25 each: Net.C2S.BuyRank(stat)
--                   Levels       the in-run level buffs you have and the next ones
--                   What's left  unbought stall buffs (distance, cost) and the Altar
--   stall popup   opens by itself while you stand at a stall pad, the Class
--                 Stall, the Big Cheese Altar or the Swap Stand (State "stalls"
--                 from Net.S2C.Stalls; ranges from Run/RunWallet), and closes
--                 when you walk off. A ProximityPrompt with attribute StallId
--                 (stall id, "altar" or "swap") re-opens it if you closed it.
--                 Sends BuyStallBuff(stallId, buffId), BuyUltimate(id),
--                 Swap("toWhey", rinds).
--   What's left   B toggles a small list (mid-left) of what is still for sale.
-- Nothing here touches Robux.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local UiSizes = require(Client.Util.UiSizes)
local Defs = require(Client.Util.Defs)
local Device = require(Client.Util.Device)
local Remotes = require(Client.Util.Remotes)
local RunShopModel = require(Client.Util.RunShopModel)
local State = require(Client.Controllers.State)

local RunShopUI = {}

local C = Theme.C
local make = Theme.make

local STALL_RADIUS = 10 -- Run/RunWallet.STALL_RADIUS
local ALTAR_RADIUS = 14 -- Run/RunWallet.ALTAR_RADIUS
local RIND = "🔶"
-- iteration 4: number keys buy ranks in the V menu; a held key repeats
local RANK_KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.KeypadOne] = 1,
	[Enum.KeyCode.KeypadTwo] = 2,
	[Enum.KeyCode.KeypadThree] = 3,
	[Enum.KeyCode.KeypadFour] = 4,
	[Enum.KeyCode.KeypadFive] = 5,
	[Enum.KeyCode.KeypadSix] = 6,
	[Enum.KeyCode.KeypadSeven] = 7,
	[Enum.KeyCode.KeypadEight] = 8,
}
local HOLD_DELAY = 0.35
local HOLD_REPEAT = 0.13 -- under the server's BuyRank rate (8/s)
local WHEY = "🥛"

local screen: any = nil
local conns: { any } = {}
local unsubs: { () -> () } = {}
local menu: Frame? = nil
local menuTab = "Ranks"
local renderMenu: () -> () = function() end

local function cfg(): any
	return Defs.module("RunShop")
end

local function myRoot(): BasePart?
	local p = Players.LocalPlayer
	local ch = p and p.Character
	local r = ch and ch:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function inRun(): boolean
	local ph = State.phase()
	return ph ~= nil and ph ~= "Lobby" and ph ~= "Results"
end

local function myClass(): string?
	local party = State.get("party")
	local me = State.localUserId()
	if type(party) == "table" and type(party[me]) == "table" and party[me].classId then
		return tostring(party[me].classId)
	end
	local lobby = State.get("lobby")
	local e = type(lobby) == "table" and type(lobby.players) == "table" and lobby.players[me]
	return if type(e) == "table" and e.classId then tostring(e.classId) else nil
end

local function stage(): number
	local m = State.get("match")
	return if type(m) == "table" then tonumber(m.stage) or 1 else 1
end

-- Row card: title + text on the left, one button on the right (absolute
-- layout, so the skin can sit on the frame itself).
type RowSpec = {
	title: string,
	text: string,
	button: string,
	enabled: boolean,
	onClick: () -> (),
	done: boolean?,
	extra: { text: string, enabled: boolean, onClick: () -> () }?, -- a second, smaller button (×5)
}
local function row(parent: Instance, order: number, spec: RowSpec, h: number, btnW: number)
	local f = make("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, -6, 0, h),
		BackgroundColor3 = if spec.done then Color3.fromRGB(226, 244, 214) else C.cream,
		Parent = parent,
	})
	Theme.corner(10).Parent = f
	Theme.stroke(if spec.done then C.greenDark else C.brown, 2).Parent = f
	Theme.skinCard(f)
	Theme.label({
		Position = UDim2.fromOffset(10, 4),
		Size = UDim2.new(1, -(btnW + 24), 0, math.floor(h * 0.48)),
		TextSize = 16,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = spec.title,
		Parent = f,
	})
	Theme.label({
		Position = UDim2.new(0, 10, 0.5, 0),
		Size = UDim2.new(1, -(btnW + 24), 0.5, -4),
		TextSize = 12,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = spec.text,
		Parent = f,
	})
	local b = Theme.button(spec.button, if spec.done then C.creamDark else C.green, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(btnW, math.min(h - 10, Theme.TOUCH)),
		TextSize = 15,
		Parent = f,
	}, spec.onClick)
	Theme.setEnabled(b, spec.enabled)
	local ex = spec.extra
	if ex then
		local exW = math.max(64, Theme.SLIM + 12)
		local xb = Theme.button(ex.text, C.cheese, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -(btnW + 14), 0.5, 0),
			Size = UDim2.fromOffset(exW, math.min(h - 10, Theme.TOUCH)),
			TextSize = 13,
			Parent = f,
		}, ex.onClick)
		Theme.setEnabled(xb, ex.enabled)
	end
	return f
end

local function clear(f: Instance)
	for _, ch in f:GetChildren() do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
end

----------------------------------------------------------------------
-- Upgrade menu (V)
----------------------------------------------------------------------

function RunShopUI.isMenuOpen(): boolean
	return menu ~= nil and (menu :: Frame).Visible
end

function RunShopUI.toggleMenu(tab: string?)
	local m = menu
	if not m then
		return
	end
	if m.Visible and (tab == nil or tab == menuTab) then
		m.Visible = false
		return
	end
	if not inRun() then
		return
	end
	if tab then
		menuTab = tab
	end
	m.Visible = true
	Theme.popIn(m)
	renderMenu()
end

function RunShopUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallRunShop", 28)
	local root: Frame = screen.root
	local touch = Theme.TOUCH
	local dense = Theme.dense()
	local Z = UiSizes.hud(dense, touch)
	local K = UiSizes.combat(dense, touch)

	------------------------------------------------------------------
	-- Wallet pill (right column, under the minimap + storm pill)
	------------------------------------------------------------------
	local walletY = 10 + Z.minimap + math.ceil(K.stormH / 2) + 4
	local wallet = Theme.button("", C.rind, {
		Name = "Wallet",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -Z.margin, 0, walletY),
		Size = UDim2.fromOffset(math.max(Z.minimap, K.walletW), K.walletH),
		TextSize = K.walletText,
		TextColor3 = C.cream,
		Visible = false,
		Parent = root,
	}, function()
		RunShopUI.toggleMenu("Ranks")
	end)
	Theme.textStroke(C.shade, 1).Parent = wallet
	-- iteration 2: the pill pulses gold while a stat rank is affordable ("V: spend rinds")
	local walletStroke: UIStroke? = nil
	for _, ch in wallet:GetChildren() do
		if ch:IsA("UIStroke") and ch.ApplyStrokeMode == Enum.ApplyStrokeMode.Border then
			walletStroke = ch
		end
	end
	local pulse: Tween? = nil
	local function setPulse(on: boolean)
		if on and not pulse and walletStroke then
			walletStroke.Color = C.gold
			walletStroke.Thickness = 3
			pulse = Theme.pulse(walletStroke, 0, 0.7, 0.6)
		elseif not on and pulse then
			pulse:Cancel()
			pulse = nil
			if walletStroke then
				walletStroke.Color = C.brownDark
				walletStroke.Thickness = 3
				walletStroke.Transparency = 0
			end
		end
	end
	Theme.tooltip(wallet, function()
		return "Rinds buy stat ranks (V). Whey buys stall buffs. Both are for this run only."
			.. (if Device.mode() == "kbm" then "  [V] upgrades · [B] what's left" else "")
	end)
	local stomps = 0
	local function renderWallet()
		local w = State.get("wallet")
		local shown = inRun() and type(w) == "table"
		wallet.Visible = shown
		if shown then
			local st = tonumber(w.stomps) or stomps
			local ready = RunShopModel.anyAffordable(cfg(), w)
			wallet.Text = string.format(
				"%s%s %s  %s %s  🐭 %s",
				if ready and Device.mode() == "kbm" then "[V] " else "",
				RIND,
				RunShopModel.short(w.rinds),
				WHEY,
				RunShopModel.short(w.whey),
				RunShopModel.short(st)
			)
			setPulse(ready)
		else
			setPulse(false)
		end
	end
	table.insert(unsubs, State.subscribe("wallet", renderWallet, true))
	table.insert(
		unsubs,
		State.subscribe("run", function()
			if not inRun() then
				stomps = 0
			end
			renderWallet()
		end)
	)
	-- stomp counter: mice that die near you (Wallet `stomps` wins once M2 sends it)
	table.insert(
		conns,
		Remotes.on(Remotes.S2C.Fx, function(batch)
			if type(batch) ~= "table" or not State.inCombat() then
				return
			end
			local r = myRoot()
			if not r then
				return
			end
			local px, pz = r.Position.X, r.Position.Z
			local got = 0
			for _, ev in batch do
				if type(ev) == "table" and ev.t == "die" then
					local x, z = tonumber(ev.x), tonumber(ev.z)
					if x and z and (x - px) ^ 2 + (z - pz) ^ 2 <= 22 * 22 then
						got += 1
					end
				end
			end
			if got > 0 then
				stomps += got
				renderWallet()
			end
		end)
	)

	------------------------------------------------------------------
	-- Upgrade menu
	------------------------------------------------------------------
	local m = Theme.panel({
		Name = "UpgradeMenu",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(640, 460),
		Visible = false,
		ZIndex = 5,
		Parent = root,
	})
	table.insert(unsubs, Theme.fitFrame(screen, m, 640, 460, 10))
	Theme.compact(m)
	menu = m
	-- other UIs (UpgradeUI's 1/2/3 keys) stand aside while the V menu is open
	m:GetPropertyChangedSignal("Visible"):Connect(function()
		State.set("vmenuOpen", m.Visible)
	end)
	local title = Theme.label({
		Position = UDim2.fromOffset(16, 6),
		Size = UDim2.fromOffset(250, 36),
		TextSize = 24,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "🛠 Upgrades",
		Parent = m,
	})
	Theme.header(title)
	local purse = Theme.label({
		Position = UDim2.fromOffset(250, 10),
		Size = UDim2.new(1, -(250 + touch + 30), 0, 30),
		TextSize = 18,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = m,
	})
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		Size = UDim2.fromOffset(touch, touch),
		TextColor3 = C.white,
		Parent = m,
	}, function()
		m.Visible = false
	end)
	local tabH = Theme.SLIM + 2
	local headH = math.max(48, touch + 8)
	local tabs = make("Frame", {
		Position = UDim2.fromOffset(12, headH),
		Size = UDim2.new(1, -24, 0, tabH),
		BackgroundTransparency = 1,
		Parent = m,
	})
	Theme.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left).Parent = tabs
	local tabButtons: { [string]: TextButton } = {}
	for i, name in { "Ranks", "Levels", "What's left" } do
		tabButtons[name] = Theme.tab(name, {
			LayoutOrder = i,
			Size = UDim2.fromOffset(150, tabH),
			TextSize = 16,
			Parent = tabs,
		}, function()
			menuTab = name
			renderMenu()
		end)
	end
	local top = headH + tabH + 8
	local body = Theme.scroller({
		Position = UDim2.fromOffset(12, top),
		Size = UDim2.new(1, -24, 1, -(top + 10)),
		Parent = m,
	})
	Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = body
	Theme.padding(3, 3).Parent = body
	local rowH = math.max(56, touch + 12)

	renderMenu = function()
		if not m.Visible then
			return
		end
		for name, b in tabButtons do
			b.BackgroundColor3 = if name == menuTab then C.cheese else C.creamDark
		end
		local w = State.get("wallet")
		local wt = if type(w) == "table" then w else {}
		purse.Text = string.format(
			"%s %s rinds   %s %s whey",
			RIND,
			RunShopModel.short(wt.rinds),
			WHEY,
			RunShopModel.short(wt.whey)
		)
		local pos = body.CanvasPosition
		clear(body)
		local shop = cfg()
		if menuTab == "Ranks" then
			for i, r in RunShopModel.ranks(shop, wt) do
				local n5, cost5 = RunShopModel.multiCost(shop, r.id, r.rank, 5, tonumber(wt.rinds) or 0)
				local function buy(n: number)
					for _ = 1, n do
						Remotes.fire(Remotes.C2S.BuyRank, r.id)
					end
				end
				row(body, i, {
					title = (if Device.mode() == "kbm" and i <= 8 then string.format("[%d] ", i) else "")
						.. (
							if r.max >= 100
								then string.format("%s · rank %d", r.name, r.rank)
								else string.format("%s  %d/%d", r.name, r.rank, r.max)
						),
					text = r.text,
					button = if r.cost then RIND .. " " .. RunShopModel.short(r.cost) else "MAX",
					enabled = r.canBuy,
					done = r.cost == nil,
					onClick = function()
						-- Shift-click buys up to 5 (PC)
						local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
							or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
						buy(if shift then math.max(1, n5) else 1)
					end,
					extra = if r.cost
						then {
							text = if n5 > 1
								then string.format("×%d %s", n5, RunShopModel.short(cost5))
								else "×5",
							enabled = n5 > 1,
							onClick = function()
								buy(n5)
							end,
						}
						else nil,
				}, rowH, 120)
			end
			Theme.label({
				LayoutOrder = 100,
				Size = UDim2.new(1, -6, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextSize = 12,
				Font = Theme.FONT_BODY,
				TextColor3 = C.brown,
				Text = "Ranks last the whole run, even if you are knocked out."
					.. (if Device.mode() == "kbm" then " Keys 1-8 buy; hold a key to keep buying." else ""),
				Parent = body,
			})
		elseif menuTab == "Levels" then
			local hud = State.get("hud")
			-- iteration 4: the Wallet view carries the hero level
			local lv = tonumber(wt.level) or (if type(hud) == "table" then tonumber(hud.level) else nil) or 1
			local okL, Leveling = pcall(function()
				return require(game:GetService("ReplicatedStorage").Shared.Run.Leveling) :: any
			end)
			local lvCfg = if okL and type(Leveling) == "table"
				then {
					LEVEL_GAINS = {
						hpPct = Leveling.HP_PER_LEVEL,
						dmgPct = Leveling.DAMAGE_PER_LEVEL,
						armorEvery = Leveling.ARMOR_EVERY,
						pickEvery = Leveling.MILESTONE_EVERY,
					},
				}
				else shop
			local have, nextUp = RunShopModel.levels(lv, lvCfg)
			local lines = { string.format("⬆ Level %d · your level gains so far:", lv) }
			for _, s in have do
				table.insert(lines, "   • " .. s)
			end
			table.insert(lines, "Next:")
			for _, s in nextUp do
				table.insert(lines, "   • " .. s)
			end
			table.insert(lines, "Levels are kept through a Herd Call.")
			Theme.label({
				LayoutOrder = 1,
				Size = UDim2.new(1, -6, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextSize = 15,
				Font = Theme.FONT_BODY,
				TextColor3 = C.ink,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = table.concat(lines, "\n"),
				Parent = body,
			})
			-- iteration 4: the per-level list (the last 6 levels and the next 5)
			local gl = if okL
					and type(Leveling) == "table"
					and type(Leveling.gainsList) == "function"
				then Leveling.gainsList(lv + 5)
				else nil
			local rowsL = RunShopModel.levelRows(lv, shop, 5, gl)
			local from = math.max(1, #rowsL - 10)
			for k = from, #rowsL do
				local e = rowsL[k]
				Theme.label({
					LayoutOrder = 1 + k,
					Size = UDim2.new(1, -6, 0, 20),
					TextSize = 13,
					Font = Theme.FONT_BODY,
					TextColor3 = if e.reached then C.greenDark else C.brown,
					TextXAlignment = Enum.TextXAlignment.Left,
					Text = string.format(
						"%s Lv %d · %s",
						if e.reached then "✔" else "▫",
						e.level,
						e.text
					),
					Parent = body,
				})
			end
		else
			local r = myRoot()
			local list = if r
				then RunShopModel.whatsLeft(
					shop,
					State.get("stalls"),
					wt,
					r.Position.X,
					r.Position.Z,
					stage(),
					myClass()
				)
				else {}
			if #list == 0 then
				Theme.label({
					LayoutOrder = 1,
					Size = UDim2.new(1, -6, 0, 40),
					TextSize = 15,
					Font = Theme.FONT_BODY,
					TextColor3 = C.brown,
					Text = "Nothing left to buy on this stage. 🧀",
					Parent = body,
				})
			end
			for i, e in list do
				Theme.label({
					LayoutOrder = i,
					Size = UDim2.new(1, -6, 0, 24),
					TextSize = 15,
					Font = Theme.FONT_BODY,
					TextColor3 = if e.canBuy then C.greenDark else C.ink,
					TextXAlignment = Enum.TextXAlignment.Left,
					Text = string.format(
						"%s %s · %dm · %s",
						if e.canBuy then "✅" else "▫",
						e.text,
						math.floor(e.dist),
						e.cost
					),
					Parent = body,
				})
			end
		end
		body.CanvasPosition = pos
	end
	for _, key in { "wallet", "stalls", "hud" } do
		table.insert(
			unsubs,
			State.subscribe(key, function()
				renderMenu()
			end)
		)
	end

	------------------------------------------------------------------
	-- Stall / Altar / Swap popup (bottom-centre, above the gear row)
	------------------------------------------------------------------
	local popW = if dense then 460 else 560
	local pop = Theme.card({
		Name = "StallPopup",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -(Z.rowH + Z.bottomY + 14)),
		Size = UDim2.fromOffset(popW, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		ZIndex = 4,
		Parent = root,
	}, { stroke = 2 })
	local popInner = make("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = pop,
	})
	Theme.padding(10, 8).Parent = popInner
	Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center).Parent = popInner
	local popKey: string? = nil -- "stall:<id>" | "altar" | "swap"
	local dismissed: { [string]: boolean } = {}

	local function popTitle(text: string)
		local l = Theme.label({
			LayoutOrder = 0,
			Size = UDim2.new(1, -(touch + 6), 0, 26),
			TextSize = 19,
			TextColor3 = C.gold,
			Text = text,
			ZIndex = 5,
			Parent = popInner,
		})
		Theme.textStroke(C.shade, 1.5).Parent = l
	end

	local function renderPop()
		clear(popInner)
		Theme.padding(10, 8).Parent = popInner
		Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center).Parent = popInner
		local key = popKey
		local shops = State.get("stalls")
		if not key or type(shops) ~= "table" then
			pop.Visible = false
			return
		end
		local w = State.get("wallet")
		local shop = cfg()
		local h = math.max(52, touch + 8)
		if string.sub(key, 1, 6) == "stall:" then
			local id = string.sub(key, 7)
			local st = nil
			for _, s in (if type(shops.stalls) == "table" then shops.stalls else {}) do
				if tostring(s.id) == id then
					st = s
				end
			end
			if not st then
				pop.Visible = false
				return
			end
			popTitle(
				if st.class then "🐘 Class Stall · your class buff" else "🥛 Buff Stall · pick one"
			)
			for i, o in RunShopModel.stall(shop, st, w, myClass()) do
				row(popInner, i, {
					title = o.name,
					text = o.text .. " · lost if you are knocked out",
					button = if o.owned then "✔ Owned" else WHEY .. " " .. o.cost,
					enabled = o.canBuy,
					done = o.owned,
					onClick = function()
						Remotes.fire(Remotes.C2S.BuyStallBuff, tostring(st.id), o.id)
					end,
				}, h, 120)
			end
		elseif key == "altar" then
			popTitle("🧀 Big Cheese Altar · max 2 · everyone hears it")
			for i, u in RunShopModel.altar(shop, shops.altar, w, stage()) do
				row(popInner, i, {
					title = u.name,
					text = u.text .. (if u.why == "stage"
						then " · opens at stage 3"
						elseif u.why == "max" then " · you hold 2"
						else ""),
					button = if u.owned
						then "✔ Owned"
						else RunShopModel.short(u.rinds) .. RIND .. " " .. u.whey .. WHEY,
					enabled = u.canBuy,
					done = u.owned,
					onClick = function()
						Remotes.fire(Remotes.C2S.BuyUltimate, u.id)
					end,
				}, h, 150)
			end
		else
			popTitle("🔁 Swap Stand · rinds → whey")
			local rinds = math.floor(tonumber(type(w) == "table" and w.rinds) or 0)
			for i, amount in { 100, 1000, rinds } do
				if amount > 0 and (i < 3 or amount ~= 1000 and amount ~= 100) then
					local get = RunShopModel.swapPreview(shop, amount)
					row(popInner, i, {
						title = if i == 3
							then "All your rinds"
							else string.format("%s rinds", RunShopModel.short(amount)),
						text = string.format(
							"→ %d whey%s",
							get,
							if type(shop) == "table" and (tonumber(shop.SWAP_FEE) or 0) > 0
								then string.format(
									" (%d%% fee)",
									math.floor((tonumber(shop.SWAP_FEE) or 0) * 100 + 0.5)
								)
								else ""
						),
						button = "Swap",
						enabled = rinds >= amount and get >= 1,
						onClick = function()
							Remotes.fire(Remotes.C2S.Swap, "toWhey", amount)
						end,
					}, h, 110)
				end
			end
		end
		Theme.button("✕", C.red, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, 6),
			Size = UDim2.fromOffset(Theme.SLIM, Theme.SLIM),
			TextColor3 = C.white,
			TextSize = 16,
			ZIndex = 6,
			Parent = pop,
		}, function()
			if popKey then
				dismissed[popKey] = true
			end
			popKey = nil
			pop.Visible = false
		end)
		if not pop.Visible then
			pop.Visible = true
			Theme.popIn(pop)
		end
	end
	for _, key in { "wallet", "stalls" } do
		table.insert(
			unsubs,
			State.subscribe(key, function()
				if pop.Visible then
					renderPop()
				end
			end)
		)
	end

	-- Which shop am I standing at? (checked 5x a second)
	local function nearestShop(): string?
		local shops = State.get("stalls")
		local r = myRoot()
		if type(shops) ~= "table" or not r then
			return nil
		end
		local px, pz = r.Position.X, r.Position.Z
		local function near(t: any, rad: number): boolean
			return type(t) == "table"
				and tonumber(t.x) ~= nil
				and ((tonumber(t.x) :: number) - px) ^ 2 + ((tonumber(t.z) or 0) - pz) ^ 2 <= rad * rad
		end
		for _, s in (if type(shops.stalls) == "table" then shops.stalls else {}) do
			if near(s, STALL_RADIUS) then
				return "stall:" .. tostring(s.id)
			end
		end
		if near(shops.swap, ALTAR_RADIUS * 0.6) then
			return "swap"
		end
		if near(shops.altar, ALTAR_RADIUS) then
			return "altar"
		end
		return nil
	end

	-- A G-built ProximityPrompt (attribute StallId) re-opens a closed popup.
	table.insert(
		conns,
		ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt)
			local id = prompt:GetAttribute("StallId")
			if type(id) ~= "string" then
				return
			end
			local key = if id == "altar" or id == "swap" then id else "stall:" .. id
			dismissed[key] = nil
			popKey = key
			renderPop()
		end)
	)

	------------------------------------------------------------------
	-- What's left (B): small mid-left list
	------------------------------------------------------------------
	local left = Theme.card({
		Name = "WhatsLeft",
		Position = UDim2.new(0, Z.margin, 0.5, 20),
		Size = UDim2.fromOffset(if dense then 250 else 290, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		Parent = root,
	}, { shadow = false })
	local leftInner = make("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = left,
	})
	Theme.padding(8, 6).Parent = leftInner
	Theme.list(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Left).Parent = leftInner
	local leftLines: { TextLabel } = {}
	for i = 1, 7 do
		local l = Theme.label({
			LayoutOrder = i,
			Size = UDim2.new(1, 0, 0, 18),
			TextSize = if i == 1 then 14 else 12,
			Font = if i == 1 then Theme.FONT else Theme.FONT_BODY,
			TextColor3 = if i == 1 then C.gold else C.cream,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Parent = leftInner,
		})
		Theme.textStroke(C.shade, 1).Parent = l
		leftLines[i] = l
	end
	local showLeft = false
	local function renderLeft()
		local r = myRoot()
		left.Visible = showLeft and inRun() and r ~= nil
		if not left.Visible or not r then
			return
		end
		local list = RunShopModel.whatsLeft(
			cfg(),
			State.get("stalls"),
			State.get("wallet"),
			r.Position.X,
			r.Position.Z,
			stage(),
			myClass()
		)
		leftLines[1].Text = "📋 What's left" .. (if Device.mode() == "kbm" then "  [B]" else "")
		for i = 2, #leftLines do
			local e = list[i - 1]
			leftLines[i].Visible = e ~= nil or i == 2
			leftLines[i].Text = if e
				then string.format(
					"%s %s · %dm · %s",
					if e.canBuy then "✅" else "▫",
					e.text,
					math.floor(e.dist),
					e.cost
				)
				else "Nothing left on this stage"
		end
	end

	-- Phone: a 🛠 button above the 📍 ping button opens the menu.
	if Device.hasTouch() and K.pingButton > 0 then
		local tb = Theme.button("🛠", C.cheese, {
			Name = "UpgradeButton",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(
				1,
				-(36 + (150 - K.pingButton) / 2),
				1,
				-(44 + 150 + 18 + K.pingButton + 10)
			),
			Size = UDim2.fromOffset(K.pingButton, K.pingButton),
			TextSize = math.floor(K.pingButton * 0.45),
			Visible = false,
			Parent = root,
		}, function()
			RunShopUI.toggleMenu()
		end)
		Theme.round().Parent = tb
		table.insert(
			conns,
			RunService.Heartbeat:Connect(function()
				tb.Visible = inRun() and State.get("wallet") ~= nil
			end)
		)
	end

	-- Keys: V menu, B list (PC). Escape closes the menu.
	table.insert(
		conns,
		UserInputService.InputBegan:Connect(function(input, processed)
			if processed or not inRun() then
				return
			end
			if input.KeyCode == Enum.KeyCode.V then
				RunShopUI.toggleMenu()
			elseif input.KeyCode == Enum.KeyCode.B then
				showLeft = not showLeft
				renderLeft()
			elseif m.Visible and menuTab == "Ranks" and RANK_KEYS[input.KeyCode] then
				-- iteration 4: 1-8 buy that stat's next rank; holding the key repeats
				local idx = RANK_KEYS[input.KeyCode]
				local key = input.KeyCode
				local rows = RunShopModel.ranks(cfg(), State.get("wallet"))
				local row = rows[idx]
				if not row then
					return
				end
				Remotes.fire(Remotes.C2S.BuyRank, row.id)
				task.spawn(function()
					task.wait(HOLD_DELAY)
					while m.Visible and UserInputService:IsKeyDown(key) do
						local cur = RunShopModel.ranks(cfg(), State.get("wallet"))[idx]
						if not cur or not cur.canBuy then
							break
						end
						Remotes.fire(Remotes.C2S.BuyRank, cur.id)
						task.wait(HOLD_REPEAT)
					end
				end)
			end
		end)
	)

	-- 5 Hz: proximity popup, What's left distances, closing on phase change
	local acc = 0
	table.insert(
		conns,
		RunService.Heartbeat:Connect(function(dt)
			acc += dt
			if acc < 0.2 then
				return
			end
			acc = 0
			if not inRun() then
				m.Visible = false
				pop.Visible = false
				left.Visible = false
				popKey = nil
				table.clear(dismissed)
				return
			end
			local key = nearestShop()
			if key ~= popKey then
				if popKey then
					dismissed[popKey] = nil -- walking off resets "closed"
				end
				popKey = if key and not dismissed[key] then key else nil
				if popKey then
					renderPop()
				else
					pop.Visible = false
				end
			end
			if showLeft then
				renderLeft()
			end
			if m.Visible and menuTab == "What's left" then
				renderMenu()
			end
		end)
	)
end

function RunShopUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	for _, c in conns do
		if typeof(c) == "RBXScriptConnection" or (type(c) == "table" and c.Disconnect) then
			c:Disconnect()
		end
	end
	table.clear(conns)
	if screen then
		screen.destroy()
		screen = nil
	end
	menu = nil
end

return RunShopUI
