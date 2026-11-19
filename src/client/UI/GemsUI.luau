--!strict
-- Cheese Gems screen (iteration 2; ALIGNMENT §2c A2). Lobby modal, opened
-- from the 💎 button on the account strip (UI/ProgressUI) or GemsUI.open().
--
--   sockets    3 (account level 1 / 10 / 25). Equipped gems boost your whole
--              squad; the squad sums every member's gems (with caps).
--   inventory  up to 200: tier, 5 rolled stats, an optional unique, +0..5.
--   upgrade    +1 level costs (level+1) × tier Crumb Dust (+10% stats a level).
--   salvage    gives tier dust (+tier with a unique); two taps to confirm.
-- Remotes (refused during a run; buttons grey out outside the lobby):
--   EquipCharm(slot, gemId?)   SalvageCharm(gemId)   UpgradeGem(gemId) (when Net has it)
-- Reads profile.gems (Team P), see Util/GemModel. Never Robux.

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Remotes = require(Client.Util.Remotes)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local GemModel = require(Client.Util.GemModel)
local State = require(Client.Controllers.State)

local GemsUI = {}

local C = Theme.C
local make = Theme.make

local screen: any = nil
local modal: Frame? = nil
local body: ScrollingFrame? = nil
local header: TextLabel? = nil
local unsubs: { () -> () } = {}
local salvageArmed: number? = nil
local salvageAt = 0
local order = 0

local function profile(): any
	local p = State.get("profile")
	return if type(p) == "table" then p else {}
end

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function clear()
	local b = body
	if not b then
		return
	end
	for _, ch in b:GetChildren() do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	order = 0
end

local function heading(text: string, sub: string?)
	local b = body
	if not b then
		return
	end
	order += 1
	Theme.label({
		LayoutOrder = order,
		Size = UDim2.new(1, -8, 0, 24),
		TextSize = 18,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
		Parent = b,
	})
	if sub then
		order += 1
		Theme.label({
			LayoutOrder = order,
			Size = UDim2.new(1, -8, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextSize = 12,
			Font = Theme.FONT_BODY,
			TextColor3 = C.brown,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = sub,
			Parent = b,
		})
	end
end

type Btn = { text: string, color: Color3, enabled: boolean, onClick: () -> () }

-- Gem card: tier chip, name line, stat line, buttons (absolute layout so it
-- can carry the skin).
local function gemRow(g: GemModel.Gem?, title: string, sub: string, buttons: { Btn }, highlight: boolean?)
	local b = body
	if not b then
		return
	end
	order += 1
	local touch = Theme.TOUCH
	local h = math.max(64, touch + 16)
	local btnW = 108
	local f = make("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, -8, 0, h),
		BackgroundColor3 = if highlight then Color3.fromRGB(255, 236, 170) else C.cream,
		Parent = b,
	})
	Theme.corner(10).Parent = f
	Theme.stroke(if highlight then C.cheeseDark else C.brown, 2).Parent = f
	Theme.skinCard(f, if g and g.tier >= 9 then "Legendary" elseif g and g.tier >= 6 then "Epic" else nil)
	local chip = make("TextLabel", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 8, 0.5, 0),
		Size = UDim2.fromOffset(40, 40),
		BackgroundColor3 = if g then rgb(GemModel.tierColor(g.tier)) else C.greyDark,
		Font = Theme.FONT,
		TextSize = 16,
		TextColor3 = C.ink,
		Text = if g then (if g.tier == 12 then "★" else tostring(g.tier)) else "·",
		Parent = f,
	})
	Theme.round().Parent = chip
	Theme.stroke(C.brownDark, 2).Parent = chip
	local textW = -(56 + #buttons * (btnW + 6) + 10)
	Theme.label({
		Position = UDim2.fromOffset(56, 4),
		Size = UDim2.new(1, textW, 0, math.floor(h * 0.42)),
		TextSize = 15,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = title,
		Parent = f,
	})
	Theme.label({
		Position = UDim2.new(0, 56, 0.42, 2),
		Size = UDim2.new(1, textW, 0.58, -6),
		TextSize = 11,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = sub,
		Parent = f,
	})
	for i, spec in buttons do
		local bt = Theme.button(spec.text, spec.color, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8 - (#buttons - i) * (btnW + 6), 0.5, 0),
			Size = UDim2.fromOffset(btnW, math.min(touch, h - 12)),
			TextSize = 13,
			Parent = f,
		}, spec.onClick)
		Theme.setEnabled(bt, spec.enabled)
	end
end

local function gemTitle(g: GemModel.Gem, cfg: any): string
	local u = GemModel.uniqueName(g.unique, cfg)
	return string.format(
		"%s Tier %d gem%s%s",
		if g.tier == 12 then "🌟" else "💎",
		g.tier,
		if g.level > 0 then " +" .. g.level else "",
		if u then " · " .. u else ""
	)
end

function GemsUI.render()
	local m = modal
	if not m or not m.Visible then
		return
	end
	local b = body
	local pos = if b then b.CanvasPosition else Vector2.zero
	clear()
	local cfg = Defs.module("Gems")
	local p = profile()
	local gv = GemModel.view(p.gems, p, cfg)
	local can = State.inLobby()
	if header then
		header.Text = string.format("💎 Cheese Gems · %d / %d · ✨ %s Crumb Dust", #gv.inv, gv.capacity, Format.int(gv.dust))
	end
	-- your bonus to the squad
	local parts = {}
	for _, k in GemModel.STATS do
		local v = gv.totals[k]
		if v and v > 0 then
			local info = GemModel.STAT_INFO[k]
			table.insert(parts, string.format("%s %s%s %s", info.icon, info.sign, GemModel.pct(v), string.lower(info.name)))
		end
	end
	heading(
		"Sockets",
		"Equipped gems boost your whole squad (bots too); the squad adds up every member's gems, up to the caps."
			.. (if #parts > 0 then "\nYour gems give: " .. table.concat(parts, " · ") else "")
	)
	local byId: { [number]: GemModel.Gem } = {}
	for _, g in gv.inv do
		byId[g.id] = g
	end
	local function freeSlot(): number
		for slot = 1, gv.open do
			if (gv.sockets[slot] or 0) == 0 then
				return slot
			end
		end
		return 1
	end
	for slot = 1, #gv.socketLevels do
		local g = byId[gv.sockets[slot] or 0]
		local open = slot <= gv.open
		gemRow(
			g,
			if g then string.format("Socket %d · %s", slot, gemTitle(g, cfg)) else string.format("Socket %d", slot),
			if not open
				then string.format("🔒 Opens at account level %s", tostring(gv.socketLevels[slot]))
				elseif g then table.concat(GemModel.lines(g, cfg), "  ")
				else "Empty: equip a gem below",
			if g
				then {
					{
						text = "Unequip",
						color = C.creamDark,
						enabled = can,
						onClick = function()
							Remotes.fire(Remotes.C2S.EquipCharm, slot, nil)
						end,
					},
				}
				else {},
			g ~= nil
		)
	end
	heading(
		"Inventory",
		"Gems drop from bosses and clears; their tier is the difficulty you beat. Upgrade the keepers with Crumb Dust."
	)
	if #gv.inv == 0 then
		heading("No gems yet. Beat a boss to find one! 💎")
	end
	local upgrade = Remotes.C2S.UpgradeGem
	for _, g in gv.inv do
		local cost = GemModel.upgradeCost(g)
		local dust = GemModel.salvageDust(g)
		local armed = salvageArmed == g.id and os.clock() - salvageAt < 4
		local buttons: { Btn } = {
			{
				text = if g.equipped then "Socket " .. g.equipped else "Equip",
				color = C.green,
				enabled = can and g.equipped == nil and gv.open > 0,
				onClick = function()
					Remotes.fire(Remotes.C2S.EquipCharm, freeSlot(), g.id)
				end,
			},
		}
		if upgrade then
			table.insert(buttons, {
				text = if cost then "⬆ ✨" .. cost else "+5 MAX",
				color = C.orange,
				enabled = can and cost ~= nil and gv.dust >= cost,
				onClick = function()
					Remotes.fire(upgrade, g.id)
				end,
			})
		end
		table.insert(buttons, {
			text = if armed then "Sure?" else "Salvage ✨" .. dust,
			color = if armed then C.red else C.creamDark,
			enabled = can and g.equipped == nil,
			onClick = function()
				if salvageArmed == g.id and os.clock() - salvageAt < 4 then
					salvageArmed = nil
					Remotes.fire(Remotes.C2S.SalvageCharm, g.id)
				else
					salvageArmed, salvageAt = g.id, os.clock()
					GemsUI.render()
				end
			end,
		})
		gemRow(g, gemTitle(g, cfg), table.concat(GemModel.lines(g, cfg), "  "), buttons, g.equipped ~= nil)
	end
	if b then
		b.CanvasPosition = pos
	end
end

function GemsUI.open()
	if not modal or not State.inLobby() then
		return
	end
	modal.Visible = true
	State.setBusy("gems", true)
	Theme.popIn(modal)
	GemsUI.render()
end

function GemsUI.close()
	if modal then
		modal.Visible = false
	end
	State.setBusy("gems", false)
end

function GemsUI.toggle()
	if modal and modal.Visible then
		GemsUI.close()
	else
		GemsUI.open()
	end
end

function GemsUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallGems", 37)
	local touch = Theme.TOUCH
	local m = Theme.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(780, 540),
		Visible = false,
		Parent = screen.root,
	})
	table.insert(unsubs, Theme.fitFrame(screen, m, 780, 560, 10))
	Theme.compact(m)
	modal = m
	local h = Theme.label({
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, -(touch + 40), 0, 36),
		TextSize = 22,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "💎 Cheese Gems",
		Parent = m,
	})
	Theme.header(h)
	header = h
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		Size = UDim2.fromOffset(touch, touch),
		TextColor3 = C.white,
		Parent = m,
	}, GemsUI.close)
	local top = math.max(52, touch + 10)
	local b = Theme.scroller({
		Position = UDim2.fromOffset(12, top),
		Size = UDim2.new(1, -24, 1, -(top + 10)),
		Parent = m,
	})
	Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = b
	Theme.padding(3, 3).Parent = b
	body = b
	table.insert(unsubs, State.subscribe("profile", GemsUI.render))
	table.insert(
		unsubs,
		State.subscribe("run", function()
			if not State.inLobby() and modal and modal.Visible then
				GemsUI.close()
			end
		end)
	)
end

function GemsUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	State.setBusy("gems", false)
	if screen then
		screen.destroy()
		screen = nil
	end
	modal = nil
	body = nil
end

return GemsUI
