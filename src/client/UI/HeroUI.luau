--!strict
-- Hero screen (iteration 2 PLAN, ALIGNMENT §4 item 9). Each class is a hero.
-- Lobby modal, opened from the lobby bar's 🐘 Hero button. Tabs:
--   Level & Perks          level, XP, mastery, free perk points, opens the perk tree
--   Prestige & Ascension   Prestige at level 30 (level restarts at 1, nothing is
--                          lost) and the 8 Ascension nodes (Prestige + class stomps)
--   Abilities              base + 2 alternates (class levels 5 / 15)
--   Skins                  level skins + owned paid skins
-- Remotes: SelectAbility(classId, abilityId?), SelectSkin(classId, skinId?), and,
-- when Net has them, Prestige(classId) and UnlockAscension(classId, node).
-- Everything is refused during a run, so buttons grey out outside the lobby.

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local ClassInfo = require(script.Parent.ClassInfo)
local PerkTreeUI = require(script.Parent.PerkTreeUI)
local Remotes = require(Client.Util.Remotes)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local HeroModel = require(Client.Util.HeroModel)
local State = require(Client.Controllers.State)

local HeroUI = {}

local C = Theme.C
local make = Theme.make

local TABS = { "Level & Perks", "Prestige & Ascension", "Abilities", "Skins" }

local screen: any = nil
local modal: Frame? = nil
local body: ScrollingFrame? = nil
local chipRow: Frame? = nil
local titleLabel: TextLabel? = nil
local tabButtons: { [string]: TextButton } = {}
local currentTab = TABS[1]
local heroId: string? = nil
local unsubs: { () -> () } = {}
local order = 0
local prestigeArmedAt = 0

local function profile(): any
	local p = State.get("profile")
	return if type(p) == "table" then p else {}
end

local function selectedClass(): string
	local lobby = State.get("lobby")
	local me = State.localUserId()
	local e = type(lobby) == "table" and type(lobby.players) == "table" and lobby.players[me]
	if type(e) == "table" and e.classId then
		return tostring(e.classId)
	end
	return tostring(profile().selectedClass or "elephante")
end

local function isUnlocked(id: string): boolean
	local u = profile().unlockedClasses
	if type(u) ~= "table" then
		return true
	end
	return u[id] == true or table.find(u, id) ~= nil
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

local function text(t: string, size: number?, color: Color3?, font: Enum.Font?)
	local b = body
	if not b then
		return
	end
	order += 1
	Theme.label({
		LayoutOrder = order,
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextSize = size or 14,
		Font = font or Theme.FONT_BODY,
		TextColor3 = color or C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = t,
		Parent = b,
	})
end

local function bar(frac: number, caption: string)
	local b = body
	if not b then
		return
	end
	order += 1
	local br = Theme.bar({ LayoutOrder = order, Size = UDim2.new(1, -8, 0, 22), Parent = b }, C.xp)
	br.set(math.clamp(frac, 0, 1), caption)
end

type Btn = { text: string, color: Color3?, enabled: boolean, onClick: () -> () }

-- Row card with one button (absolute layout, skinned).
local function row(title: string, sub: string, btn: Btn?, done: boolean?, swatch: Color3?)
	local b = body
	if not b then
		return
	end
	order += 1
	local touch = Theme.TOUCH
	local h = math.max(58, touch + 12)
	local f = make("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, -8, 0, h),
		BackgroundColor3 = if done then Color3.fromRGB(226, 244, 214) else C.cream,
		Parent = b,
	})
	Theme.corner(10).Parent = f
	Theme.stroke(if done then C.greenDark else C.brown, 2).Parent = f
	Theme.skinCard(f)
	local x = 10
	if swatch then
		local sw = make("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 10, 0.5, 0),
			Size = UDim2.fromOffset(28, 28),
			BackgroundColor3 = swatch,
			Parent = f,
		})
		Theme.round().Parent = sw
		Theme.stroke(C.brownDark, 2).Parent = sw
		x = 46
	end
	local btnW = if btn then 130 else 0
	Theme.label({
		Position = UDim2.fromOffset(x, 4),
		Size = UDim2.new(1, -(x + btnW + 18), 0, math.floor(h * 0.45)),
		TextSize = 16,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = title,
		Parent = f,
	})
	Theme.label({
		Position = UDim2.new(0, x, 0.45, 2),
		Size = UDim2.new(1, -(x + btnW + 18), 0.55, -6),
		TextSize = 12,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = sub,
		Parent = f,
	})
	if btn then
		local bt = Theme.button(btn.text, btn.color or C.green, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(btnW, math.min(touch, h - 10)),
			TextSize = 14,
			Parent = f,
		}, btn.onClick)
		Theme.setEnabled(bt, btn.enabled)
	end
end

local function classView(id: string): any
	local cl = profile().classes
	return if type(cl) == "table" and type(cl[id]) == "table" then cl[id] else {}
end

----------------------------------------------------------------------
-- Tabs
----------------------------------------------------------------------

local function renderLevel(id: string)
	local pr = ClassInfo.progress(id)
	local hero = HeroModel.view(classView(id), id, Defs.module("Ascension"))
	text(
		string.format(
			"%sLevel %d%s",
			if hero.prestige > 0 then string.format("⭐%d · ", hero.prestige) else "",
			hero.shownLevel,
			if pr.masteryName then " · " .. pr.masteryName else ""
		),
		20,
		C.ink,
		Theme.FONT
	)
	if hero.shownLevel >= HeroModel.MAX_LEVEL then
		bar(1, "MAX LEVEL: Prestige is ready on the next tab")
	else
		bar(hero.frac, string.format("%s / %s XP", Format.int(hero.xp), Format.int(hero.toNext)))
	end
	text(
		"Class XP comes from every mouse you stomp with this hero, plus clears and extractions.",
		12,
		C.brown
	)
	row(
		"🌳 Perk tree",
		string.format(
			"%d free perk point%s · 3 branches × 5 tiers",
			pr.free,
			if pr.free == 1 then "" else "s"
		),
		{
			text = "Open",
			enabled = isUnlocked(id),
			onClick = function()
				HeroUI.close()
				PerkTreeUI.open(id)
			end,
		},
		false
	)
	text(string.format("🐭 %s stomps with this hero", Format.int(hero.stomps)), 14)
end

local function renderPrestige(id: string)
	local hero = HeroModel.view(classView(id), id, Defs.module("Ascension"))
	local can = State.inLobby()
	text(string.format("⭐ Prestige %d / %d", hero.prestige, HeroModel.MAX_PRESTIGE), 20, C.ink, Theme.FONT)
	text("Now: " .. HeroModel.prestigeBonus(hero.prestige), 13, C.greenDark)
	text(
		"At level 30 you can Prestige: the shown level restarts at 1 and climbs again. You keep every perk, ability and skin."
			.. (
				if hero.nextFrame
					then string.format(" Next nameplate frame at ⭐%d.", hero.nextFrame)
					else ""
			),
		12,
		C.brown
	)
	local remote = Remotes.C2S.Prestige
	local armed = os.clock() - prestigeArmedAt < 4
	row(
		"⭐ Prestige " .. tostring(hero.prestige + 1),
		if hero.canPrestige
			then "Next: " .. HeroModel.prestigeBonus(hero.prestige + 1)
			else string.format("Reach level 30 first (now %d)", hero.shownLevel),
		{
			text = if armed then "Sure?" else "Prestige",
			color = if armed then C.red else C.cheese,
			enabled = can and hero.canPrestige and remote ~= nil,
			onClick = function()
				if not remote then
					return
				end
				if os.clock() - prestigeArmedAt < 4 then
					prestigeArmedAt = 0
					Remotes.fire(remote, id)
				else
					prestigeArmedAt = os.clock()
					HeroUI.render()
				end
			end,
		},
		false
	)
	text(
		string.format("🦣 Ascension · 🐭 %s class stomps", Format.int(hero.stomps)),
		18,
		C.ink,
		Theme.FONT
	)
	local unlock = Remotes.C2S.UnlockAscension
	for _, n in hero.nodes do
		local need = string.format("⭐%d + %s stomps", n.prestige, Format.short(n.stomps))
		local sub = n.text
			.. "  ·  "
			.. (
				if n.owned
					then "unlocked"
					elseif n.why == "order" then "unlock the node before it"
					elseif n.why then "needs " .. need
					else "ready!"
			)
		row(
			string.format(
				"%s%d · %s",
				if n.owned then "✔ " elseif n.canUnlock then "✨ " else "🔒 ",
				n.index,
				n.name
			),
			sub,
			if unlock and not n.owned
				then {
					text = "Unlock",
					enabled = can and n.canUnlock,
					onClick = function()
						Remotes.fire(unlock, id, n.index)
					end,
				}
				else nil,
			n.owned
		)
	end
end

local function renderAbilities(id: string)
	local pr = ClassInfo.progress(id)
	local can = State.inLobby() and isUnlocked(id)
	text("Abilities unlock at class levels 5 and 15.", 12, C.brown)
	for i, ch in ClassInfo.abilities(id, pr.level, pr.ability) do
		row(
			(if ch.selected then "✔ " else "") .. ch.name,
			ch.description
				.. (if ch.unlocked then "" else string.format("  ·  unlocks at level %d", ch.unlockLevel)),
			{
				text = if ch.selected then "Selected" else "Select",
				color = if ch.selected then C.creamDark else C.green,
				enabled = can and ch.unlocked and not ch.selected,
				onClick = function()
					Remotes.fire(Remotes.C2S.SelectAbility, id, if i == 1 then nil else ch.id)
				end,
			},
			ch.selected
		)
	end
end

local function renderSkins(id: string)
	local pr = ClassInfo.progress(id)
	local can = State.inLobby() and isUnlocked(id)
	text("Skins unlock at class levels 3, 10, 20 and 30. Paid skins are in the shop.", 12, C.brown)
	for _, ch in ClassInfo.skins(id, pr.level, pr.skin) do
		if not ch.placeholder then
			row(
				(if ch.selected then "✔ " else "") .. ch.name,
				if ch.unlocked then ch.description else string.format("Unlocks at level %d", ch.unlockLevel),
				{
					text = if ch.selected then "Wearing" else "Wear",
					color = if ch.selected then C.creamDark else C.green,
					enabled = can and ch.unlocked and not ch.selected,
					onClick = function()
						Remotes.fire(Remotes.C2S.SelectSkin, id, if ch.id == "default" then nil else ch.id)
					end,
				},
				ch.selected,
				if ch.color then Format.rgb(ch.color) else nil
			)
		end
	end
end

function HeroUI.render()
	local m = modal
	if not m or not m.Visible then
		return
	end
	local id = heroId or selectedClass()
	for name, b in tabButtons do
		b.BackgroundColor3 = if name == currentTab then C.cheese else C.creamDark
	end
	local def = Defs.get("Classes", id)
	if titleLabel then
		titleLabel.Text = "🐘 " .. Defs.name(def, id)
	end
	-- hero chips
	local row0 = chipRow
	if row0 then
		for _, ch in row0:GetChildren() do
			if ch:IsA("GuiButton") then
				ch:Destroy()
			end
		end
		for i, d in Defs.all("Classes") do
			local cid = tostring(d.id)
			Theme.tab(Defs.name(d, cid) .. (if isUnlocked(cid) then "" else " 🔒"), {
				LayoutOrder = i,
				BackgroundColor3 = if cid == id then C.cheese else C.creamDark,
				Size = UDim2.fromOffset(118, Theme.SLIM),
				TextSize = 13,
				Parent = row0,
			}, function()
				heroId = cid
				HeroUI.render()
			end)
		end
	end
	local b = body
	local pos = if b then b.CanvasPosition else Vector2.zero
	clear()
	if currentTab == "Level & Perks" then
		renderLevel(id)
	elseif currentTab == "Prestige & Ascension" then
		renderPrestige(id)
	elseif currentTab == "Abilities" then
		renderAbilities(id)
	else
		renderSkins(id)
	end
	if b then
		b.CanvasPosition = pos
	end
end

function HeroUI.open(tab: string?, classId: string?)
	if not modal or not State.inLobby() then
		return
	end
	if tab and table.find(TABS, tab) then
		currentTab = tab
	end
	heroId = classId
	modal.Visible = true
	State.setBusy("hero", true)
	Theme.popIn(modal)
	HeroUI.render()
end

function HeroUI.close()
	if modal then
		modal.Visible = false
	end
	State.setBusy("hero", false)
end

function HeroUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallHero", 36)
	local touch = Theme.TOUCH
	local m = Theme.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(820, 560),
		Visible = false,
		Parent = screen.root,
	})
	table.insert(unsubs, Theme.fitFrame(screen, m, 820, 580, 10))
	Theme.compact(m)
	modal = m
	local t = Theme.label({
		Position = UDim2.fromOffset(16, 6),
		Size = UDim2.new(1, -(touch + 40), 0, 38),
		TextSize = 26,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "🐘 Hero",
		Parent = m,
	})
	Theme.header(t)
	titleLabel = t
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		Size = UDim2.fromOffset(touch, touch),
		TextColor3 = C.white,
		Parent = m,
	}, HeroUI.close)
	local y = math.max(50, touch + 8)
	local chips = make("ScrollingFrame", {
		Position = UDim2.fromOffset(12, y),
		Size = UDim2.new(1, -24, 0, Theme.SLIM + 8),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(),
		Parent = m,
	})
	Theme.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left).Parent = chips
	chipRow = chips
	y += Theme.SLIM + 12
	local tabs = make("ScrollingFrame", {
		Position = UDim2.fromOffset(12, y),
		Size = UDim2.new(1, -24, 0, Theme.SLIM + 8),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(),
		Parent = m,
	})
	Theme.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left).Parent = tabs
	for i, name in TABS do
		tabButtons[name] = Theme.tab(name, {
			LayoutOrder = i,
			Size = UDim2.fromOffset(if i == 2 then 230 else 160, Theme.SLIM + 2),
			TextSize = 15,
			Parent = tabs,
		}, function()
			currentTab = name
			HeroUI.render()
		end)
	end
	y += Theme.SLIM + 14
	local b = Theme.scroller({
		Position = UDim2.fromOffset(12, y),
		Size = UDim2.new(1, -24, 1, -(y + 10)),
		Parent = m,
	})
	Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = b
	Theme.padding(3, 3).Parent = b
	body = b
	for _, key in { "profile", "lobby" } do
		table.insert(unsubs, State.subscribe(key, HeroUI.render))
	end
	table.insert(
		unsubs,
		State.subscribe("run", function()
			if not State.inLobby() and modal and modal.Visible then
				HeroUI.close()
			end
		end)
	)
end

function HeroUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	State.setBusy("hero", false)
	if screen then
		screen.destroy()
		screen = nil
	end
	modal = nil
	body = nil
	table.clear(tabButtons)
end

return HeroUI
