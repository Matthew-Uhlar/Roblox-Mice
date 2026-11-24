--!strict
-- Gem Vault (iter6, team Gems; was the iteration-2 Cheese Gems list). Lobby modal,
-- opened from the 💎 button on the account strip (UI/ProgressUI) or GemsUI.open().
--
--   Vault      a grid of gem cards: sort (tier / power / each stat / newest / level),
--              filters (tier range, unique, equipped, locked, unique type). The detail
--              panel shows each stat as a bar inside its tier's min-max roll range, the
--              power score, the unique, the level, a compare against each socket, and
--              Equip 1 / 2, Lock, Upgrade (Crumb Dust), Sacrifice into, Salvage.
--   Sacrifice  pick a target, multi-select fodder (or "below tier N" / "lower power"),
--              preview the new level, stats, power and leftover dust, confirm twice.
--              Rule (server, Config/Gems.feedResult): the fodder's salvage dust buys
--              the target's levels in order up to the max; the rest goes to your dust.
--   Salvage    the same selection, bulk salvage to Crumb Dust, confirm twice.
-- Equipped and locked gems are never fodder. Remotes: EquipCharm(slot, id?),
-- UpgradeGem(id), SalvageCharm(id), FeedGems(target, ids), SalvageGems(ids),
-- LockGem(id, locked). Pure maths: Util/GemVaultModel. Never Robux.
-- Effects setting (State "gfx".fx): full = card pops, stat bars fill, absorb effect;
-- reduced = bars + a target flash only; off = no animation.

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Remotes = require(Client.Util.Remotes)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local GemModel = require(Client.Util.GemModel)
local V = require(Client.Util.GemVaultModel)
local UiSizes = require(Client.Util.UiSizes)
local State = require(Client.Controllers.State)

local GemsUI = {}

local function optional(folder: Instance?, name: string): any
	local ok, mod = pcall(function()
		local inst = folder and folder:FindFirstChild(name)
		return if inst then require(inst :: any) :: any else nil
	end)
	return if ok then mod else nil
end
local GemArt = optional(Client:FindFirstChild("Visuals"), "GemArt") -- team G
local AnimatedIcon = optional(script.Parent, "AnimatedIcon") -- team Icons

local C = Theme.C
local make = Theme.make
local M = UiSizes.MENU -- menu readability (iteration 6): rows 12x10, title 18, body 15
local U = V.UI -- the vault's fixed boxes (~1.7x their text size)
type Gem = GemModel.Gem

-- UI state ----------------------------------------------------------------------
local screen: any = nil
local modal: Frame? = nil
local header: TextLabel? = nil
local toolbar: ScrollingFrame? = nil
local filterBar: ScrollingFrame? = nil
local grid: ScrollingFrame? = nil
local detail: ScrollingFrame? = nil
local unsubs: { () -> () } = {}

local mode = "vault" -- "vault" | "sacrifice" | "salvage"
local sortKey = "tier"
local filtersOpen = false
local filt =
	{ minTier = 1, maxTier = 12, unique = "any", equipped = "any", locked = "any", uniqueId = nil :: string? }
local selected: number? = nil -- vault: the gem in the detail panel; sacrifice: the target
local picks: { [number]: boolean } = {} -- sacrifice fodder / salvage selection
local belowTier = 6
local armed: string? = nil -- two-step confirms: "feed" | "salvage" | "salvage1"
local armedAt = 0
local popNext = true -- card pop on open / mode change
local cardOf: { [number]: GuiObject } = {}
local detailIcon: GuiObject? = nil

local TRI = { "any", "yes", "no" }
local TRI_LABEL = { any = "Any", yes = "Yes", no = "No" } :: { [string]: string }

local function fx(): string
	local ok, g = pcall(State.gfx)
	return if ok and type(g) == "table" and type(g.fx) == "string" then g.fx else "full"
end

local function cfg(): any
	return Defs.module("Gems")
end

local function profile(): any
	local p = State.get("profile")
	return if type(p) == "table" then p else {}
end

local function tierColor(t: number): Color3
	if GemArt then
		return GemArt.color(t)
	end
	local c = GemModel.tierColor(t)
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function tierName(t: number): string
	local c = cfg()
	local n = type(c) == "table" and type(c.TIER_NAMES) == "table" and c.TIER_NAMES[t]
	return if type(n) == "string" then n else "Tier " .. t
end

local function isArmed(key: string): boolean
	return armed == key and os.clock() - armedAt < 4
end

local function arm(key: string)
	armed, armedAt = key, os.clock()
end

local function fire(name: string, ...: any)
	local r = (Remotes.C2S :: any)[name]
	if r then
		Remotes.fire(r, ...)
	end
end

local function clearChildren(f: Instance?)
	if not f then
		return
	end
	for _, ch in f:GetChildren() do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
end

local function label(props: { [string]: any }): TextLabel
	local base: { [string]: any } = {
		TextSize = M.body,
		Font = Theme.FONT_BODY,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		BackgroundTransparency = 1,
	}
	for k, v in props do
		base[k] = v
	end
	return Theme.label(base)
end

-- Gem icon: GemArt's uploaded tier icon, else team Icons' animated gem, else a drawn gem,
-- on a round chip in the tier colour.
local function gemIcon(parent: Instance, tier: number, size: number, props: { [string]: any }?): Frame
	local chip = make("Frame", {
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = tierColor(tier),
		Parent = parent,
	}) :: Frame
	if props then
		for k, v in props do
			(chip :: any)[k] = v
		end
	end
	Theme.round().Parent = chip
	Theme.stroke(C.brownDark, 2).Parent = chip
	local img = if GemArt then GemArt.icon(tier) else nil
	if img then
		make(
			"ImageLabel",
			{ Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Image = img, Parent = chip }
		)
	elseif AnimatedIcon and AnimatedIcon.has("gems") then
		local ic = AnimatedIcon.new("gems", math.floor(size * 0.78))
		if ic then
			ic.AnchorPoint = Vector2.new(0.5, 0.5)
			ic.Position = UDim2.fromScale(0.5, 0.5)
			ic.Parent = chip
		end
	else
		local ic = Theme.icon("gem", math.floor(size * 0.7), C.white)
		ic.AnchorPoint = Vector2.new(0.5, 0.5)
		ic.Position = UDim2.fromScale(0.5, 0.5)
		ic.Parent = chip
	end
	return chip
end

-- A stat bar: the roll inside the tier's min-max range; fills when shown.
local function statBar(parent: Instance, order: number, text: string, frac: number, color: Color3)
	local row = make("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, -6, 0, U.statBox + 16),
		BackgroundTransparency = 1,
		Parent = parent,
	})
	label({
		Size = UDim2.new(1, 0, 0, U.statBox),
		TextSize = U.statText,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = text,
		Parent = row,
	})
	local bar = make("Frame", {
		Position = UDim2.fromOffset(0, U.statBox + 2),
		Size = UDim2.new(1, 0, 0, 11),
		BackgroundColor3 = C.shade,
		BackgroundTransparency = 0.3,
		Parent = row,
	})
	Theme.corner(5).Parent = bar
	local fill = make("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = color,
		Parent = bar,
	})
	Theme.corner(5).Parent = fill
	local goal = UDim2.fromScale(math.clamp(frac, 0.02, 1), 1)
	if fx() == "off" then
		fill.Size = goal
	else
		Theme.tween(fill, 0.35 + 0.05 * order, { Size = goal }, Enum.EasingStyle.Quart)
	end
end

local function gemTitle(g: Gem): string
	return string.format(
		"Tier %d %s%s",
		g.tier,
		tierName(g.tier),
		if g.level > 0 then " +" .. g.level else ""
	)
end

local function uniqueLine(g: Gem): string?
	return g.uniqueText or GemModel.uniqueName(g.unique, cfg())
end

local function pctSigned(v: number): string
	local s = GemModel.pct(math.abs(v))
	return (if v >= 0 then "+" else "-") .. s
end

-- Model -------------------------------------------------------------------------
local function model(): (GemModel.Gems, { [number]: Gem })
	local p = profile()
	local gv = GemModel.view(p.gems, p, cfg())
	local byId: { [number]: Gem } = {}
	for _, g in gv.inv do
		byId[g.id] = g
	end
	return gv, byId
end

local function pickedList(byId: { [number]: Gem }): { Gem }
	local out = {}
	for id in picks do
		local g = byId[id]
		if g then
			table.insert(out, g)
		else
			picks[id] = nil -- gone (fed / salvaged)
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

local function pickCount(): number
	local n = 0
	for _ in picks do
		n += 1
	end
	return n
end

local function idsOf(list: { Gem }): { number }
	local out = {}
	for _, g in list do
		table.insert(out, g.id)
	end
	return out
end

-- Effects -----------------------------------------------------------------------
-- Fodder cards fly into the target icon and the target flashes (Effects setting).
local function absorb(ids: { number })
	local m, target = modal, detailIcon
	local level = fx()
	if not m or level == "off" then
		return
	end
	if target and target.Parent then
		local s = make("UIScale", { Scale = 1.35, Parent = target })
		Theme.tween(s, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
		task.delay(0.5, function()
			s:Destroy()
		end)
	end
	if level ~= "full" or not target then
		return
	end
	local mPos, mSize = m.AbsolutePosition, m.AbsoluteSize
	if mSize.X <= 0 or mSize.Y <= 0 then
		return
	end
	local function rel(obj: GuiObject): UDim2
		local c = obj.AbsolutePosition + obj.AbsoluteSize / 2 - mPos
		return UDim2.fromScale(c.X / mSize.X, c.Y / mSize.Y)
	end
	local goal = rel(target)
	for i, id in ids do
		if i > 14 then
			break
		end
		local card = cardOf[id]
		if card and card.Parent then
			local dot = make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = rel(card),
				Size = UDim2.fromOffset(26, 26),
				BackgroundColor3 = card:GetAttribute("TierColor") or C.gold,
				ZIndex = 50,
				Parent = m,
			})
			Theme.round().Parent = dot
			task.delay(0.03 * i, function()
				Theme.tween(dot, 0.45, {
					Position = goal,
					Size = UDim2.fromOffset(8, 8),
					BackgroundTransparency = 0.6,
				}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				task.delay(0.5, function()
					dot:Destroy()
				end)
			end)
		end
	end
end

-- Grid --------------------------------------------------------------------------
local function card(parent: Instance, g: Gem, order: number, onClick: () -> ())
	local isSel = (mode == "vault" or mode == "sacrifice") and selected == g.id
	local isPick = picks[g.id] == true
	local tc = tierColor(g.tier)
	local b = make("TextButton", {
		LayoutOrder = order,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = if isPick
			then Color3.fromRGB(255, 214, 200)
			elseif isSel then C.goldLight
			else C.cream,
		Parent = parent,
	}) :: TextButton
	b:SetAttribute("TierColor", tc)
	Theme.corner(10).Parent = b
	Theme.stroke(if isSel then C.goldDeep elseif isPick then C.red else tc, if isSel or isPick then 3 else 2).Parent =
		b
	Theme.skinCard(b, if g.tier >= 9 then "Legendary" elseif g.tier >= 6 then "Epic" else nil)
	gemIcon(b, g.tier, U.icon, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 18) })
	label({
		Position = UDim2.new(0, 2, 0, 18 + U.icon + 2),
		Size = UDim2.new(1, -4, 0, U.tierBox),
		TextSize = U.tierText,
		Font = Theme.FONT,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		Text = string.format("T%d%s", g.tier, if g.level > 0 then " +" .. g.level else ""),
		Parent = b,
	})
	label({
		Position = UDim2.new(0, 2, 0, 18 + U.icon + 2 + U.tierBox),
		Size = UDim2.new(1, -4, 0, U.powerBox),
		TextSize = U.powerText,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		Text = "⚡" .. V.power(g, cfg()),
		Parent = b,
	})
	-- corner badges: socket, lock, unique, picked
	local badges = {}
	if g.equipped then
		table.insert(badges, "S" .. g.equipped)
	end
	if g.locked then
		table.insert(badges, "🔒")
	end
	if g.unique then
		table.insert(badges, "★")
	end
	if isPick then
		table.insert(badges, "✓")
	end
	if #badges > 0 then
		label({
			Position = UDim2.fromOffset(4, 0),
			Size = UDim2.new(1, -8, 0, U.badgeBox),
			TextSize = U.badgeText,
			Font = Theme.FONT,
			TextColor3 = if isPick then C.red else C.brownDark,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextWrapped = false,
			Text = table.concat(badges, ""),
			ZIndex = 3,
			Parent = b,
		})
	end
	Theme.hover(b)
	b.Activated:Connect(onClick)
	cardOf[g.id] = b
	if popNext and order <= 30 and fx() == "full" then
		local s = make("UIScale", { Scale = 0.6, Parent = b })
		task.delay(0.015 * order, function()
			Theme.tween(s, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
	end
end

-- Detail panels -------------------------------------------------------------------
local dOrder = 0
local function dAdd(): number
	dOrder += 1
	return dOrder
end

-- `size` >= 16 = a heading (MENU.title), else body text (MENU.body).
local function dLabel(text: string, size: number?, color: Color3?, font: Enum.Font?, rich: boolean?)
	label({
		LayoutOrder = dAdd(),
		Size = UDim2.new(1, -6, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextSize = if (size or 0) >= 16 then M.title else M.body,
		TextColor3 = color or C.ink,
		Font = font or Theme.FONT_BODY,
		RichText = rich == true,
		Text = text,
		Parent = detail,
	})
end

-- A padded list row (MENU paddings, title 18 / body 15) that is never shorter than its
-- text (Theme.rowMinHeight).
local function dRow(title: string, body: string?, titleColor: Color3?, rich: boolean?)
	local f = make("Frame", {
		LayoutOrder = dAdd(),
		Size = UDim2.new(1, -6, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.cream,
		Parent = detail,
	})
	Theme.corner(10).Parent = f
	Theme.stroke(C.brown, 1, 0.4).Parent = f
	Theme.padding(M.padX, M.padY).Parent = f
	Theme.list(Enum.FillDirection.Vertical, M.gap, Enum.HorizontalAlignment.Left).Parent = f
	label({
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextSize = M.title,
		Font = Theme.FONT,
		TextColor3 = titleColor or C.ink,
		RichText = rich == true,
		Text = title,
		Parent = f,
	})
	if body and body ~= "" then
		label({
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextSize = M.body,
			TextColor3 = C.brown,
			RichText = rich == true,
			Text = body,
			Parent = f,
		})
	end
	Theme.rowMinHeight(f, title, body)
end

local function dButtons(list: { { text: string, color: Color3, enabled: boolean, onClick: () -> () } })
	local row = make("Frame", {
		LayoutOrder = dAdd(),
		Size = UDim2.new(1, -6, 0, Theme.TOUCH),
		BackgroundTransparency = 1,
		Parent = detail,
	})
	Theme.list(Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Left).Parent = row
	local n = #list
	for _, spec in list do
		local bt = Theme.button(spec.text, spec.color, {
			Size = UDim2.new(1 / n, -4, 1, 0),
			TextSize = U.btnText,
			Parent = row,
		}, spec.onClick)
		Theme.setEnabled(bt, spec.enabled)
	end
end

local function dHeader(g: Gem)
	local top = make("Frame", {
		LayoutOrder = dAdd(),
		Size = UDim2.new(1, -6, 0, U.headTitleBox + U.headSubBox + 2),
		BackgroundTransparency = 1,
		Parent = detail,
	})
	detailIcon = gemIcon(top, g.tier, 60, { Position = UDim2.fromOffset(0, 4) })
	label({
		Position = UDim2.fromOffset(68, 0),
		Size = UDim2.new(1, -68, 0, U.headTitleBox),
		TextSize = U.headTitle,
		Font = Theme.FONT,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = gemTitle(g),
		Parent = top,
	})
	label({
		Position = UDim2.fromOffset(68, U.headTitleBox + 2),
		Size = UDim2.new(1, -68, 0, U.headSubBox),
		TextSize = U.headSub,
		TextColor3 = C.brown,
		Text = string.format(
			"⚡ Power %d · Level %d/%d%s%s",
			V.power(g, cfg()),
			g.level,
			GemModel.MAX_LEVEL,
			if g.equipped then " · Socket " .. g.equipped else "",
			if g.locked then " · 🔒" else ""
		),
		Parent = top,
	})
end

local function dStats(g: Gem, preview: { [string]: number }?)
	local c = cfg()
	local lo, hi = V.range(g.tier, c)
	dLabel(string.format("Rolls (tier range %d-%d)", lo, hi), 11, C.brown)
	for _, k in GemModel.STATS do
		local info = GemModel.STAT_INFO[k]
		local now = GemModel.statValue(g, k, c)
		local text = string.format(
			"%s %s %d · %s%s",
			info.icon,
			info.name,
			g.stats[k] or 0,
			info.sign,
			GemModel.pct(now)
		)
		if preview and preview[k] and preview[k] > now + 1e-9 then
			text ..= "  →  " .. info.sign .. GemModel.pct(preview[k])
		end
		statBar(detail :: any, dAdd(), text, V.quality(g, k, c), tierColor(g.tier))
	end
	if g.unique then
		local c2 = cfg()
		local d = type(c2) == "table" and c2.unique and c2.unique(g.unique)
		if d then
			dRow("★ " .. tostring(d.name), tostring(d.text), C.purple)
		else
			dRow("★ Unique", uniqueLine(g))
		end
	end
end

local function dCompare(g: Gem, gv: GemModel.Gems, byId: { [number]: Gem })
	for slot = 1, #gv.socketLevels do
		local other = byId[gv.sockets[slot] or 0]
		if other and other.id ~= g.id then
			local d = V.compare(g, other, cfg())
			local parts = {}
			for _, k in GemModel.STATS do
				local v = d[k]
				if math.abs(v) > 1e-6 then
					local col = if v > 0 then "#2E9E40" else "#D23C3C"
					table.insert(
						parts,
						string.format(
							'<font color="%s">%s%s</font>',
							col,
							GemModel.STAT_INFO[k].icon,
							pctSigned(v)
						)
					)
				end
			end
			local dp = V.power(g, cfg()) - V.power(other, cfg())
			dRow(
				string.format(
					"vs Socket %d (T%d): ⚡%s%d",
					slot,
					other.tier,
					if dp >= 0 then "+" else "",
					dp
				),
				if #parts > 0 then table.concat(parts, "  ") else "Same stats.",
				nil,
				true
			)
		elseif not other and slot <= gv.open then
			dLabel(string.format("Socket %d is empty.", slot), 11, C.brown)
		end
	end
end

local function setMode(m: string)
	if mode ~= m then
		mode = m
		table.clear(picks)
		armed = nil
		popNext = true
	end
	GemsUI.render()
end

local function renderVaultDetail(gv: GemModel.Gems, byId: { [number]: Gem }, can: boolean)
	local g = selected and byId[selected]
	if not g then
		dLabel(
			"Tap a gem to see its rolls, compare it with your sockets, and equip, lock or upgrade it.",
			12,
			C.brown
		)
		local parts = {}
		for _, k in GemModel.STATS do
			local v = gv.totals[k]
			if v and v > 0 then
				local info = GemModel.STAT_INFO[k]
				table.insert(parts, string.format("%s %s%s", info.icon, info.sign, GemModel.pct(v)))
			end
		end
		dLabel(
			"Your sockets give you: " .. (if #parts > 0 then table.concat(parts, " · ") else "nothing yet"),
			12
		)
		dRow(
			"How gems work",
			"Gems drop when you complete a round (extract or full clear), and the first time you clear "
				.. "a difficulty tier you get a guaranteed gem of that tier. The tier is the difficulty you "
				.. "played. Equipped gems (2 sockets: account level 1 / 10) boost you from the start of "
				.. "every round. Sacrifice spare gems into your best ones, or salvage them for Crumb Dust."
		)
		return
	end
	local gem = g :: Gem
	dHeader(gem)
	dStats(gem, nil)
	dCompare(gem, gv, byId)
	local buttons = {}
	for slot = 1, #gv.socketLevels do
		local open = slot <= gv.open
		table.insert(buttons, {
			text = if gem.equipped == slot
				then "Unequip"
				elseif open then "Socket " .. slot
				else "🔒 Lv " .. tostring(gv.socketLevels[slot]),
			color = if gem.equipped == slot then C.creamDark else C.green,
			enabled = can and open,
			onClick = function()
				fire("EquipCharm", slot, if gem.equipped == slot then nil else gem.id)
			end,
		})
	end
	dButtons(buttons)
	local cost = GemModel.upgradeCost(gem)
	dButtons({
		{
			text = if gem.locked then "🔓 Unlock" else "🔒 Lock",
			color = C.creamDark,
			enabled = can,
			onClick = function()
				fire("LockGem", gem.id, not gem.locked)
			end,
		},
		{
			text = if cost then "⬆ ✨" .. cost else "MAX",
			color = C.orange,
			enabled = can and cost ~= nil and gv.dust >= cost,
			onClick = function()
				fire("UpgradeGem", gem.id)
				absorb({})
			end,
		},
	})
	local dust = GemModel.salvageDust(gem)
	local free = gem.equipped == nil and not gem.locked
	dButtons({
		{
			text = "Sacrifice into",
			color = C.purple,
			enabled = can and gem.level < GemModel.MAX_LEVEL,
			onClick = function()
				setMode("sacrifice")
				selected = gem.id
				belowTier = gem.tier
				GemsUI.render()
			end,
		},
		{
			text = if isArmed("salvage1") then "Sure? ✨" .. dust else "Salvage ✨" .. dust,
			color = if isArmed("salvage1") then C.red else C.creamDark,
			enabled = can and free,
			onClick = function()
				if isArmed("salvage1") then
					armed = nil
					fire("SalvageCharm", gem.id)
					selected = nil
				else
					arm("salvage1")
					GemsUI.render()
				end
			end,
		},
	})
end

local function quickPicks(gv: GemModel.Gems, target: Gem?, cap: number)
	dButtons({
		{
			text = "−",
			color = C.creamDark,
			enabled = belowTier > 2,
			onClick = function()
				belowTier = math.max(2, belowTier - 1)
				GemsUI.render()
			end,
		},
		{
			text = "All below T" .. belowTier,
			color = C.cheese,
			enabled = true,
			onClick = function()
				table.clear(picks)
				for _, id in
					V.selectBelowTier(gv.inv, belowTier, if target then target.id else nil, cap, cfg())
				do
					picks[id] = true
				end
				armed = nil
				GemsUI.render()
			end,
		},
		{
			text = "+",
			color = C.creamDark,
			enabled = belowTier < 13,
			onClick = function()
				belowTier = math.min(13, belowTier + 1)
				GemsUI.render()
			end,
		},
	})
	dButtons({
		{
			text = if target then "Unlocked, lower power" else "All shown",
			color = C.cheese,
			enabled = true,
			onClick = function()
				table.clear(picks)
				if target then
					for _, id in V.selectLowerPower(gv.inv, target, cap, cfg()) do
						picks[id] = true
					end
				else
					local n = 0
					for _, g in V.filter(gv.inv, filt :: any) do
						if n < cap and V.eligible(g, nil) then
							picks[g.id] = true
							n += 1
						end
					end
				end
				armed = nil
				GemsUI.render()
			end,
		},
		{
			text = "Clear",
			color = C.creamDark,
			enabled = pickCount() > 0,
			onClick = function()
				table.clear(picks)
				armed = nil
				GemsUI.render()
			end,
		},
	})
end

local function renderSacrificeDetail(gv: GemModel.Gems, byId: { [number]: Gem }, can: boolean)
	local target = selected and byId[selected]
	if not target then
		dRow(
			"🔥 Sacrifice",
			"1. Tap the gem you want to make stronger.\n2. Tap the spare gems to sacrifice (up to "
				.. V.FEED_MAX
				.. ").\nTheir salvage dust buys the target's upgrade levels (+10% stats each, up to +"
				.. GemModel.MAX_LEVEL
				.. "). Dust left over goes to your Crumb Dust. Equipped and locked gems are never used."
		)
		return
	end
	local t = target :: Gem
	dHeader(t)
	local fodder = pickedList(byId)
	local pv = V.feedPreview(t, fodder, cfg())
	dStats(t, if #fodder > 0 then pv.values else nil)
	if #fodder == 0 then
		dLabel("Tap spare gems in the grid to sacrifice them into this one.", 12, C.brown)
	else
		dRow(
			string.format("%d gems → ✨%d dust", #fodder, pv.dust),
			string.format(
				"Level +%d → +%d · ⚡%d → %d\nSpent ✨%d · left over ✨%d to your dust",
				pv.from,
				pv.level,
				V.power(t, cfg()),
				pv.power,
				pv.spent,
				pv.leftover
			)
		)
		if pv.level == pv.from then
			dLabel(
				string.format(
					"Not enough for a level: the next one costs ✨%d. All of it goes to your dust.",
					V.cost(t.tier, t.level + 1, cfg())
				),
				11,
				C.red
			)
		end
	end
	quickPicks(gv, t, V.FEED_MAX)
	local okToGo = can and pv.ok and #fodder <= V.FEED_MAX
	dButtons({
		{
			text = "Change target",
			color = C.creamDark,
			enabled = true,
			onClick = function()
				selected = nil
				table.clear(picks)
				armed = nil
				GemsUI.render()
			end,
		},
		{
			text = if isArmed("feed") then "Sure? Sacrifice " .. #fodder else "🔥 Sacrifice " .. #fodder,
			color = if isArmed("feed") then C.red else C.purple,
			enabled = okToGo,
			onClick = function()
				if isArmed("feed") then
					armed = nil
					local ids = idsOf(fodder)
					absorb(ids)
					fire("FeedGems", t.id, ids)
					table.clear(picks)
				else
					arm("feed")
					GemsUI.render()
				end
			end,
		},
	})
	if t.level >= GemModel.MAX_LEVEL then
		dLabel("This gem is at max level. Pick another target.", 11, C.red)
	end
end

local function renderSalvageDetail(gv: GemModel.Gems, byId: { [number]: Gem }, can: boolean)
	local list = pickedList(byId)
	local dust = V.salvageTotal(list)
	dRow(
		"♻ Bulk salvage",
		string.format(
			"Tap gems to select them (up to %d). Equipped and locked gems are skipped.\nSelected: %d → ✨%d Crumb Dust (you have ✨%s).",
			V.SALVAGE_MAX,
			#list,
			dust,
			Format.int(gv.dust)
		)
	)
	quickPicks(gv, nil, V.SALVAGE_MAX)
	dButtons({
		{
			text = if isArmed("salvage") then "Sure? Salvage " .. #list else "♻ Salvage " .. #list,
			color = if isArmed("salvage") then C.red else C.orange,
			enabled = can and #list > 0 and #list <= V.SALVAGE_MAX,
			onClick = function()
				if isArmed("salvage") then
					armed = nil
					local ids = idsOf(list)
					fire("SalvageGems", ids)
					if fx() ~= "off" then
						for _, id in ids do
							local cd = cardOf[id]
							if cd and cd.Parent then
								local s = make("UIScale", { Parent = cd })
								Theme.tween(
									s,
									0.25,
									{ Scale = 0.2 },
									Enum.EasingStyle.Back,
									Enum.EasingDirection.In
								)
							end
						end
					end
					table.clear(picks)
				else
					arm("salvage")
					GemsUI.render()
				end
			end,
		},
	})
end

-- Toolbars ------------------------------------------------------------------------
local function renderToolbar()
	local tb = toolbar
	if not tb then
		return
	end
	clearChildren(tb)
	local h = Theme.TOUCH
	-- Theme.tab: MENU.tabText labels, widths from UiSizes.tabWidth; the active one is cheese
	local function btn(text: string, color: Color3, _w: number, onClick: () -> ())
		local b = Theme.tab(text, {
			Size = UDim2.fromOffset(UiSizes.tabWidth(text, Theme.renderedText), h),
			Parent = tb,
		}, onClick)
		if color == C.cheese then
			b.BackgroundColor3 = C.cheese
		end
		return b
	end
	btn("💎 Vault", if mode == "vault" then C.cheese else C.creamDark, 104, function()
		setMode("vault")
	end)
	btn("🔥 Sacrifice", if mode == "sacrifice" then C.cheese else C.creamDark, 124, function()
		setMode("sacrifice")
	end)
	btn("♻ Salvage", if mode == "salvage" then C.cheese else C.creamDark, 110, function()
		setMode("salvage")
	end)
	btn("Sort: " .. V.SORT_LABEL[sortKey], C.cream, 132, function()
		local i = table.find(V.SORTS, sortKey) or 0
		sortKey = V.SORTS[i % #V.SORTS + 1]
		popNext = true
		GemsUI.render()
	end)
	btn(if filtersOpen then "Filters ▲" else "Filters ▼", C.cream, 112, function()
		filtersOpen = not filtersOpen
		GemsUI.render()
	end)
end

local function renderFilters()
	local fb = filterBar
	if not fb then
		return
	end
	fb.Visible = filtersOpen
	clearChildren(fb)
	if not filtersOpen then
		return
	end
	local h = Theme.TOUCH - 6
	local function pill(text: string, _w: number, onClick: () -> ())
		local w = math.ceil(UiSizes.textWidth(text, Theme.renderedText(U.pillText)) + 2 * M.padX)
		Theme.button(text, C.cream, {
			Size = UDim2.fromOffset(w, h),
			TextSize = U.pillText,
			TextWrapped = false,
			Parent = fb,
		}, function()
			onClick()
			popNext = true
			GemsUI.render()
		end)
	end
	pill(string.format("Tier ≥ %d", filt.minTier), 82, function()
		filt.minTier = filt.minTier % 12 + 1
		filt.maxTier = math.max(filt.maxTier, filt.minTier)
	end)
	pill(string.format("Tier ≤ %d", filt.maxTier), 82, function()
		filt.maxTier = if filt.maxTier <= filt.minTier then 12 else filt.maxTier - 1
	end)
	local function cycle(key: string, name: string, w: number)
		local cur = (filt :: any)[key]
		pill(name .. ": " .. TRI_LABEL[cur], w, function()
			local i = table.find(TRI, cur) or 1
			(filt :: any)[key] = TRI[i % #TRI + 1]
		end)
	end
	cycle("unique", "★ Unique", 104)
	cycle("equipped", "Equipped", 106)
	cycle("locked", "🔒", 70)
	local c = cfg()
	local order = if type(c) == "table" and type(c.UNIQUE_ORDER) == "table" then c.UNIQUE_ORDER else {}
	local uname = "Any"
	if filt.uniqueId then
		local d = type(c) == "table" and c.unique and c.unique(filt.uniqueId)
		uname = if d then d.name else filt.uniqueId :: string
	end
	pill("Type: " .. uname, 150, function()
		local i = if filt.uniqueId then table.find(order, filt.uniqueId) or 0 else 0
		filt.uniqueId = order[i + 1]
	end)
	pill("Reset", 64, function()
		filt.minTier, filt.maxTier = 1, 12
		filt.unique, filt.equipped, filt.locked, filt.uniqueId = "any", "any", "any", nil
	end)
end

-- Render --------------------------------------------------------------------------
function GemsUI.render()
	local m = modal
	if not m or not m.Visible then
		return
	end
	local gv, byId = model()
	local can = State.inLobby()
	if selected and not byId[selected] then
		selected = nil
	end
	if header then
		header.Text = string.format(
			"💎 Gem Vault · %d / %d · ✨ %s Crumb Dust",
			#gv.inv,
			gv.capacity,
			Format.int(gv.dust)
		)
	end
	renderToolbar()
	renderFilters()
	local top = math.max(52, Theme.TOUCH + 10) + Theme.TOUCH + 6
	local filterH = if filtersOpen then Theme.TOUCH + 2 else 0
	if grid then
		grid.Position = UDim2.fromOffset(12, top + filterH)
		grid.Size = UDim2.new(U.split, -16, 1, -(top + filterH + 10))
	end
	if detail then
		detail.Position = UDim2.new(U.split, 4, 0, top + filterH)
		detail.Size = UDim2.new(1 - U.split, -16, 1, -(top + filterH + 10))
	end

	-- grid
	local gpos = if grid then grid.CanvasPosition else Vector2.zero
	clearChildren(grid)
	table.clear(cardOf)
	local list = V.sort(V.filter(gv.inv, filt :: any), sortKey, cfg())
	if #list == 0 and grid then
		label({
			LayoutOrder = 1,
			Size = UDim2.fromOffset(2 * U.cardW + 6, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextColor3 = C.brown,
			Text = if #gv.inv == 0
				then "No gems yet. Complete a round to find one! 💎"
				else "No gem matches these filters.",
			Parent = grid,
		})
	end
	for i, g in list do
		card(grid :: any, g, i, function()
			if mode == "vault" then
				selected = if selected == g.id then nil else g.id
				armed = nil
			elseif mode == "sacrifice" then
				if not selected then
					if g.level < GemModel.MAX_LEVEL then
						selected = g.id
						belowTier = g.tier
					end
				elseif g.id ~= selected and V.eligible(g, selected) then
					if picks[g.id] then
						picks[g.id] = nil
					elseif pickCount() < V.FEED_MAX then
						picks[g.id] = true
					end
					armed = nil
				end
			else
				if V.eligible(g, nil) then
					if picks[g.id] then
						picks[g.id] = nil
					elseif pickCount() < V.SALVAGE_MAX then
						picks[g.id] = true
					end
					armed = nil
				end
			end
			GemsUI.render()
		end)
	end
	popNext = false
	if grid then
		grid.CanvasPosition = gpos
	end

	-- detail
	local dpos = if detail then detail.CanvasPosition else Vector2.zero
	clearChildren(detail)
	dOrder = 0
	detailIcon = nil
	if mode == "vault" then
		renderVaultDetail(gv, byId, can)
	elseif mode == "sacrifice" then
		renderSacrificeDetail(gv, byId, can)
	else
		renderSalvageDetail(gv, byId, can)
	end
	if detail then
		detail.CanvasPosition = dpos
	end
end

function GemsUI.open()
	if not modal or not State.inLobby() then
		return
	end
	modal.Visible = true
	State.setBusy("gems", true)
	popNext = true
	if fx() ~= "off" then
		Theme.popIn(modal)
	end
	GemsUI.render()
end

function GemsUI.close()
	if modal then
		modal.Visible = false
	end
	table.clear(picks)
	armed = nil
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
		Size = UDim2.fromOffset(U.modalW, U.modalH),
		Visible = false,
		Parent = screen.root,
	})
	table.insert(unsubs, Theme.fitFrame(screen, m, U.modalW, U.modalH, 10))
	Theme.compact(m)
	modal = m
	local h = Theme.label({
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, -(touch + 40), 0, 36),
		TextSize = 22,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "💎 Gem Vault",
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
	-- horizontal scrollers: bigger tab text on phones must never clip a tab
	local function hScroll(props: { [string]: any }): ScrollingFrame
		local base: { [string]: any } = {
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 4,
			ScrollingDirection = Enum.ScrollingDirection.X,
			AutomaticCanvasSize = Enum.AutomaticSize.X,
			CanvasSize = UDim2.new(),
			Parent = m,
		}
		for k, v in props do
			base[k] = v
		end
		return make("ScrollingFrame", base) :: ScrollingFrame
	end
	local tb = hScroll({
		Position = UDim2.fromOffset(12, top),
		Size = UDim2.new(1, -24, 0, touch + 4),
	})
	Theme.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left).Parent = tb
	toolbar = tb
	local fb = hScroll({
		Position = UDim2.fromOffset(12, top + touch + 6),
		Size = UDim2.new(1, -24, 0, touch - 2),
		Visible = false,
	})
	Theme.list(Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Left).Parent = fb
	filterBar = fb
	local g = Theme.scroller({ Parent = m })
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(U.cardW, U.cardH),
		CellPadding = UDim2.fromOffset(6, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = g,
	})
	Theme.padding(4, 4).Parent = g
	grid = g
	local d = Theme.scroller({ Parent = m })
	Theme.list(Enum.FillDirection.Vertical, 5, Enum.HorizontalAlignment.Left).Parent = d
	Theme.padding(3, 3).Parent = d
	detail = d
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
	grid = nil
	detail = nil
	toolbar = nil
	filterBar = nil
	header = nil
end

return GemsUI
