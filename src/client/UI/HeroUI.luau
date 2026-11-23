--!strict
-- Hero screen (iteration 2 PLAN, ALIGNMENT §4 item 9). Each class is a hero.
-- Lobby modal, opened from the lobby bar's 🐘 Hero button. Tabs:
--   Level & Perks          level, XP, mastery, free perk points, opens the perk tree;
--                          iteration 5: the lifetime stats card (time played, totals, tiers)
--   Prestige & Ascension   Prestige at level 30 (level restarts at 1, nothing is
--                          lost) and the 8 Ascension nodes (Prestige + class stomps)
--   Abilities              base + 2 alternates (class levels 5 / 15); iteration 5:
--                          a loadout row of 3 slots (2nd at level 10, 3rd at 20)
--   Skins                  level skins + owned paid skins
-- Remotes: SelectAbility(classId, abilityId?, slot?), SelectSkin(classId, skinId?), and,
-- Prestige(classId) when Net has it, and SetEvo(classId, 1..4) for the look.
-- Ascension nodes unlock automatically (Prestige milestone + class stomps).
-- Everything is refused during a run, so buttons grey out outside the lobby.

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local AnimatedIcon = require(script.Parent.AnimatedIcon)
local ClassInfo = require(script.Parent.ClassInfo)
local Icons = require(script.Parent.Icons)
local PerkTreeUI = require(script.Parent.PerkTreeUI)
local Remotes = require(Client.Util.Remotes)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local Device = require(Client.Util.Device)
local AbilitySlots = require(Client.Util.AbilitySlots)
local HeroModel = require(Client.Util.HeroModel)
local LadderModel = require(Client.Util.LadderModel)
local State = require(Client.Controllers.State)

local HeroUI = {}

local function visual(name: string): any
	local ok, mod = pcall(function()
		return require(script.Parent.Parent.Visuals:FindFirstChild(name) :: any) :: any
	end)
	return if ok then mod else nil
end
local PrestigeFrames = visual("PrestigeFrames") -- team G nameplate frames

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
local editSlot = 1 -- iteration 5: the loadout slot the Abilities tab equips into

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

-- iteration 5 Phase B #7: lifetime stats (ProfileView.lifetime from
-- Data/LifetimeStats; falls back to profile.stats / classes[id].seconds).
-- Every field may be missing on an older server: it then reads 0 / is hidden.
local function duration(sec: number): string
	local s = math.max(0, math.floor(sec))
	local h, m = s // 3600, (s % 3600) // 60
	if h > 0 then
		return string.format("%dh %02dm", h, m)
	end
	return string.format("%dm", m)
end

local function lifetimeCard(id: string)
	local p = profile()
	local lt = if type(p.lifetime) == "table" then p.lifetime else nil
	local st = if type(p.stats) == "table" then p.stats else {}
	local function n(v: any): number
		local x = tonumber(v)
		return if x and x == x and x ~= math.huge then x else 0
	end
	local function field(k: string): number
		return n(if lt and lt[k] ~= nil then lt[k] else st[k])
	end
	local classSec = n(classView(id).seconds)
	if lt and type(lt.classSeconds) == "table" and lt.classSeconds[id] ~= nil then
		classSec = n(lt.classSeconds[id])
	end
	text("📈 Lifetime", 18, C.ink, Theme.FONT)
	local lines = {
		string.format("⏱ This hero: %s · all heroes: %s", duration(classSec), duration(field("seconds"))),
		string.format(
			"⚔ Damage %s · 🐭 %s stomps · 👑 %s bosses · 🏆 %s champions",
			Format.short(field("damage")),
			Format.short(field("stomps")),
			Format.int(field("bossesKilled")),
			Format.int(field("championKills"))
		),
		string.format(
			"🎮 %s runs · %s wins · 🌀 %s extractions",
			Format.int(field("runs")),
			Format.int(field("wins")),
			Format.int(field("extractions"))
		),
	}
	for _, l in lines do
		text(l, 13, C.ink)
	end
	-- per tier: clears and the best Overtime wave
	local clears = if lt and type(lt.clears) == "table"
		then lt.clears
		elseif type(st.clears) == "table" then st.clears
		else {}
	local ot = if lt and type(lt.overtimeBest) == "table"
		then lt.overtimeBest
		elseif type(st.overtimeBest) == "table" then st.overtimeBest
		else {}
	local tiers: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, map in { clears, ot } do
		for k in map do
			local t = tonumber(k)
			if t and not seen[t] then
				seen[t] = true
				table.insert(tiers, t)
			end
		end
	end
	table.sort(tiers)
	if #tiers == 0 then
		text("Clear a tier or survive Overtime waves to fill this in.", 12, C.brown)
		return
	end
	local diff = Defs.module("Difficulty")
	for _, t in tiers do
		local c = n(clears[tostring(t)] or clears[t])
		local w = n(ot[tostring(t)] or ot[t])
		text(
			string.format(
				"%s: %s clear%s%s",
				LadderModel.name(diff, t),
				Format.int(c),
				if c == 1 then "" else "s",
				if w > 0 then string.format(" · Overtime best wave %d", w) else ""
			),
			12,
			C.brown
		)
	end
end

local function renderLevel(id: string)
	local pr = ClassInfo.progress(id)
	local hero = HeroModel.view(classView(id), id, Defs.module("Ascension"))
	text(
		string.format(
			"Level %d%s%s",
			if hero.prestige > 0 then HeroModel.MAX_LEVEL else hero.shownLevel,
			if hero.prestige > 0 then " · ⭐" .. hero.prestige else "",
			if pr.masteryName then " · " .. pr.masteryName else ""
		),
		20,
		C.ink,
		Theme.FONT
	)
	if hero.prestige > 0 then
		-- T-15: progress toward the next Prestige, not a re-climbing level
		bar(
			hero.frac,
			if hero.canPrestige
				then "Ready: Prestige ⭐" .. (hero.prestige + 1) .. " on the next tab"
				else string.format("%d%% to ⭐%d", math.floor(hero.frac * 100), hero.prestige + 1)
		)
	elseif hero.shownLevel >= HeroModel.MAX_LEVEL then
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
	lifetimeCard(id)
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
	-- nodes unlock automatically once both gates are met (Team P)
	for _, n in hero.nodes do
		local need = string.format("⭐%d + %s stomps", n.prestige, Format.short(n.stomps))
		local sub = n.text
			.. "  ·  "
			.. (
				if n.owned
					then "unlocked"
					elseif n.why == "order" then "after the node before it"
					elseif n.why then "needs " .. need
					else "unlocks on your next match"
			)
		row(
			string.format(
				"%s%d · %s",
				if n.owned then "✔ " elseif n.canUnlock then "✨ " else "🔒 ",
				n.index,
				n.name
			),
			sub,
			nil,
			n.owned
		)
	end
	-- looks (Base, Bull, Matriarch, Ancient): SetEvo(classId, 1..4)
	local asc = classView(id).ascension
	local looks = if type(asc) == "table" and type(asc.looks) == "table" then asc.looks else {}
	local current = if type(asc) == "table" and type(asc.look) == "string" then asc.look else "base"
	text("🎨 Look", 18, C.ink, Theme.FONT)
	for i, lk in
		{ { "base", "Base" }, { "bull", "Bull" }, { "matriarch", "Matriarch" }, { "ancient", "Ancient" } }
	do
		local owned = i == 1 or table.find(looks, lk[1]) ~= nil or looks[lk[1]] == true
		local on = current == lk[1]
		row(
			(if on then "✔ " else "") .. lk[2],
			if owned then "Your hero's look in matches" else "Unlocks with Ascension",
			{
				text = if on then "Wearing" else "Wear",
				color = if on then C.creamDark else C.green,
				enabled = can and owned and not on,
				onClick = function()
					Remotes.fire(Remotes.C2S.SetEvo, id, i)
				end,
			},
			on
		)
	end
end

-- iteration 5 (A3): the loadout row (3 slot cards; locked ones say "Level 10" /
-- "Level 20", Prestige >= 1 opens all) above the ability list. Tap a slot,
-- then Equip an ability into it: SelectAbility(classId, abilityId, slot).
local function loadoutRow(id: string): { ClassInfo.SlotView }?
	local b = body
	if not b then
		return nil
	end
	local slots = ClassInfo.loadout(id)
	if not slots[editSlot] or not slots[editSlot].unlocked then
		editSlot = 1
	end
	order += 1
	local touch = Theme.TOUCH
	local h = math.max(74, touch + 22)
	local strip = make("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, -8, 0, h),
		BackgroundTransparency = 1,
		Parent = b,
	})
	make("UIGridLayout", {
		CellPadding = UDim2.fromOffset(8, 0),
		CellSize = UDim2.new(1 / 3, -6, 1, 0),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = strip,
	})
	for _, sv in slots do
		local on = sv.unlocked and sv.slot == editSlot
		local card = make("TextButton", {
			LayoutOrder = sv.slot,
			BackgroundColor3 = if on then C.goldLight elseif sv.unlocked then C.cream else C.creamDark,
			AutoButtonColor = false,
			Text = "",
			Selectable = sv.unlocked,
			Parent = strip,
		}) :: TextButton
		Theme.corner(10).Parent = card
		Theme.stroke(if on then C.goldDeep else C.brown, if on then 3 else 2).Parent = card
		Theme.skinCard(card)
		if sv.unlocked then
			Theme.hover(card, 1.02)
		end
		local keys = AbilitySlots.keyHint(sv.slot, Device.mode(), true)
		Theme.label({
			Position = UDim2.fromOffset(8, 4),
			Size = UDim2.new(1, -16, 0, 18),
			TextSize = 13,
			Font = Theme.FONT_BODY,
			TextColor3 = C.brown,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = string.format("Slot %d%s", sv.slot, if keys ~= "" then " · " .. keys else ""),
			Parent = card,
		})
		Theme.label({
			Position = UDim2.fromOffset(8, 22),
			Size = UDim2.new(1, -16, 1, -26),
			TextSize = 16,
			TextColor3 = if sv.unlocked then C.ink else C.grey,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Text = if sv.unlocked then sv.name else "🔒 " .. (sv.lockText or "Locked"),
			Parent = card,
		})
		-- iteration 6: the Tinkerphant's builds show their icon (turret / wall / wrench)
		local def = if sv.unlocked then ClassInfo.abilityDef(id, sv.id) else nil
		local iconKind = Icons.forAbility(if type(def) == "table" then def.kind else nil)
		if iconKind then
			Theme.icon(iconKind, 24, C.brownDark, {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -6, 0, 4),
				ZIndex = 3,
				Parent = card,
			})
		end
		card.Activated:Connect(function()
			if sv.unlocked and editSlot ~= sv.slot then
				editSlot = sv.slot
				HeroUI.render()
			end
		end)
	end
	return slots
end

local function renderAbilities(id: string)
	local pr = ClassInfo.progress(id)
	local can = State.inLobby() and isUnlocked(id)
	text("Loadout", 18, C.ink, Theme.FONT)
	text(
		"Ability slots open at class levels 10 and 20 (Prestige keeps all three). Pick a slot, then equip an ability.",
		12,
		C.brown
	)
	local slots = loadoutRow(id) or {}
	local where: { [string]: number } = {}
	for _, sv in slots do
		if sv.unlocked and sv.id then
			where[sv.id] = sv.slot
		end
	end
	text("Abilities unlock at class levels 5 and 15.", 12, C.brown)
	for _, ch in ClassInfo.abilities(id, pr.level, pr.ability) do
		local at = where[ch.id]
		local here = at == editSlot
		row(
			(if at then string.format("[%d] ", at) else "") .. ch.name,
			ch.description
				.. (if ch.unlocked then "" else string.format("  ·  unlocks at level %d", ch.unlockLevel)),
			{
				text = if here
					then "Equipped"
					elseif at then string.format("Swap to %d", editSlot)
					else string.format("Equip in %d", editSlot),
				color = if here then C.creamDark else C.green,
				enabled = can and ch.unlocked and not ch.placeholder and not here,
				onClick = function()
					ClassInfo.equip(id, ch.id, editSlot)
				end,
			},
			at ~= nil
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
		local cv = classView(id)
		local pres = math.floor(tonumber(cv.prestige) or 0)
		titleLabel.Text = "🐘 " .. Defs.name(def, id) .. (if pres > 0 then "  ⭐" .. pres else "")
		if PrestigeFrames then
			pcall(PrestigeFrames.apply, titleLabel, PrestigeFrames.frameFor(pres))
		end
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
		AnimatedIcon.decorate(tabButtons[name], AnimatedIcon.forMenu("hero.tab." .. name) :: string)
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
