--!strict
-- The Herd panel (lobby modal) and the lobby account strip (docs/V4-PLAN.md
-- "Progression", review C M2 / M3 / M7 / m7 and §5).
--
-- Modal tabs:
--   Contracts     Herd Contracts: 3 dailies + weeklies, progress, Claim
--                 (Net.C2S.ClaimQuest(id)) and the free daily Reroll
--                 (Net.C2S.RerollQuest(id)). View: State "quests".
--   Herd Pass     30 tiers, free + premium tracks, Claim per track
--                 (Net.C2S.ClaimPassTier(tier, track)). View: State "pass".
--                 "Get premium" only opens the shop's Herd Pass tab.
--   Mousepedia    the collection book: pages from Config/Collection, else
--                 bosses / champions / mice / gear / maps / classes from the
--                 existing configs; found entries from profile.collection.
--   Achievements  Config/Achievements + profile.achievements.
--   Levels        account level, XP and the level rewards
--                 (Net.C2S.ClaimAccountReward(level), Config/AccountRewards).
--   Boards        Net.S2C.Leaderboards tops.
--
-- Account strip (ProgressUI.buildStrip, placed by UI/LobbyUI top-left): the
-- account level badge with an XP bar, the "🐘 Herd" button with a dot (a
-- contract, pass tier or level reward to claim), and live boost timers.
-- The panel marks the player busy while open (State.setBusy).

local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Remotes = require(Client.Util.Remotes)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local Progression = require(Client.Util.Progression)
local State = require(Client.Controllers.State)

local ProgressUI = {}

local C = Theme.C
local make = Theme.make

-- iteration 2: 6 tabs (Talents / Evolution / Charms are gone: Gems have their
-- own screen, Prestige and Ascension live on the Hero screen).
local TABS = { "Contracts", "Herd Pass", "Challenges", "Mousepedia", "Levels", "Boards" }
local TAB_LABEL: { [string]: string } = {
	Contracts = "📜 Contracts",
	["Herd Pass"] = "🐘 Herd Pass",
	Mousepedia = "📖 Mousepedia",
	Achievements = "🏅 Achievements",
	Levels = "⭐ Levels",
	Boards = "🏆 Boards",
	Challenges = "🏅 Challenges",
}

local screen: any = nil
local modal: Frame? = nil
local content: ScrollingFrame? = nil
local tabButtons: { [string]: TextButton } = {}
local tabDots: { [string]: Frame } = {}
local currentTab = TABS[1]
local bookPage = 1
local unsubs: { () -> () } = {}
local stripConn: RBXScriptConnection? = nil

local function profile(): any
	local p = State.get("profile")
	return if type(p) == "table" then p else {}
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
	return d
end

local function dots(): Progression.Dots
	return Progression.dots(profile(), State.get("quests"), State.get("pass"), Defs.module("AccountRewards"))
end

----------------------------------------------------------------------
-- Content helpers
----------------------------------------------------------------------

local order = 0
local function nextOrder(): number
	order += 1
	return order
end

local function clear()
	local c = content
	if not c then
		return
	end
	for _, ch in c:GetChildren() do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	order = 0
end

local function heading(text: string, sub: string?)
	local c = content
	if not c then
		return
	end
	Theme.label({
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, -8, 0, 26),
		TextSize = 20,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
		Parent = c,
	})
	if sub then
		Theme.label({
			LayoutOrder = nextOrder(),
			Size = UDim2.new(1, -8, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextSize = 13,
			Font = Theme.FONT_BODY,
			TextColor3 = C.brown,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = sub,
			Parent = c,
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
		TextSize = 15,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		Text = text,
		Parent = c,
	})
end

type Btn = { text: string, color: Color3, enabled: boolean, onClick: () -> () }

-- A row card: title + sub on the left (wrapping), optional bar, buttons right.
local function rowCard(
	title: string,
	sub: string?,
	frac: number?,
	barText: string?,
	buttons: { Btn },
	done: boolean?
)
	local c = content
	if not c then
		return
	end
	local touch = Theme.TOUCH
	local btnW = 120
	local f = make("Frame", {
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = if done then Color3.fromRGB(226, 244, 214) else C.cream,
		Parent = c,
	})
	Theme.corner(10).Parent = f
	Theme.stroke(if done then C.greenDark else C.brown, 2).Parent = f
	Theme.skinCard(f)
	Theme.padding(10, 6).Parent = f
	local rightW = #buttons * (btnW + 6)
	local left = make("Frame", {
		Size = UDim2.new(1, -rightW, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = f,
	})
	Theme.list(Enum.FillDirection.Vertical, 3, Enum.HorizontalAlignment.Left).Parent = left
	Theme.label({
		LayoutOrder = 1,
		Size = UDim2.new(1, -6, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextSize = 16,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = title,
		Parent = left,
	})
	if sub and sub ~= "" then
		Theme.label({
			LayoutOrder = 2,
			Size = UDim2.new(1, -6, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextSize = 13,
			Font = Theme.FONT_BODY,
			TextColor3 = C.brown,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = sub,
			Parent = left,
		})
	end
	if frac then
		local bar = Theme.bar({ LayoutOrder = 3, Size = UDim2.new(1, -6, 0, 16), Parent = left }, C.xp)
		bar.text.TextSize = 12
		bar.set(math.clamp(frac, 0, 1), barText)
	end
	if #buttons > 0 then
		local right = make("Frame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.fromScale(1, 0.5),
			Size = UDim2.fromOffset(rightW, touch),
			BackgroundTransparency = 1,
			Parent = f,
		})
		Theme.list(
			Enum.FillDirection.Horizontal,
			6,
			Enum.HorizontalAlignment.Right,
			Enum.VerticalAlignment.Center
		).Parent =
			right
		for i, b in buttons do
			local btn = Theme.button(b.text, b.color, {
				LayoutOrder = i,
				Size = UDim2.fromOffset(btnW, touch),
				TextSize = 15,
				Parent = right,
			}, b.onClick)
			Theme.setEnabled(btn, b.enabled)
		end
		-- keep the row at least one button tall
		make("UISizeConstraint", { MinSize = Vector2.new(0, touch + 12), Parent = f })
	end
end

----------------------------------------------------------------------
-- Tabs
----------------------------------------------------------------------

local rerollLabel = "🎲 Reroll"
local function questRow(q: Progression.Quest, allowReroll: boolean)
	local buttons: { Btn } = {}
	if q.claimable then
		table.insert(buttons, {
			text = "Claim",
			color = C.green,
			enabled = true,
			onClick = function()
				Remotes.fire(Remotes.C2S.ClaimQuest, q.id)
			end,
		})
	elseif q.claimed then
		table.insert(
			buttons,
			{ text = "✔ Done", color = C.creamDark, enabled = false, onClick = function() end }
		)
	elseif allowReroll and q.canReroll then
		table.insert(buttons, {
			text = rerollLabel,
			color = C.creamDark,
			enabled = true,
			onClick = function()
				Remotes.fire(Remotes.C2S.RerollQuest, q.id)
			end,
		})
	end
	rowCard(
		q.text,
		q.reward.text,
		q.progress / q.goal,
		string.format("%s / %s", Format.int(q.progress), Format.int(q.goal)),
		buttons,
		q.claimed
	)
end

local function renderContracts()
	local q = Progression.quests(State.get("quests"))
	if not q.known then
		note("Herd Contracts are loading… 📜")
		return
	end
	local cost = q.rerollCost
	rerollLabel = if cost == nil or cost == 0 then "🎲 Reroll" else "🎲 🧀" .. Format.short(cost)
	local resets = if q.dailyResetsIn
		then " New ones in " .. Progression.duration(q.dailyResetsIn) .. "."
		else ""
	heading(
		"📜 Daily contracts",
		(
			if cost == 0
				then "Your first reroll today is free."
				elseif cost ~= nil then "Rerolls cost 🧀 " .. Format.int(cost) .. " now."
				else "No rerolls left today."
		) .. resets
	)
	if #q.daily == 0 then
		note("No dailies right now.")
	end
	for _, quest in q.daily do
		questRow(quest, true)
	end
	if q.bonus and q.bonus.kind ~= "none" then
		note("Finish all 3 dailies: " .. q.bonus.text)
	end
	heading("🗓 Weekly contracts")
	if #q.weekly == 0 then
		note("No weeklies right now.")
	end
	for _, quest in q.weekly do
		questRow(quest, false)
	end
end

local function renderPass()
	local pv = Progression.pass(State.get("pass"), Defs.module("Pass"))
	heading(
		"🐘 Herd Pass" .. (if pv.seasonName then " · " .. pv.seasonName else ""),
		"Pass XP comes from contracts, runs and new Mousepedia entries. Unclaimed rewards are granted at season end."
	)
	local c = content
	if not c then
		return
	end
	local bar = Theme.bar({ LayoutOrder = nextOrder(), Size = UDim2.new(1, -8, 0, 22), Parent = c }, C.xp)
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
	if not pv.premium then
		rowCard(
			"Premium track",
			"8 cosmetics and 600 Golden Cheese across the season. Earlier tiers fill in when you upgrade.",
			nil,
			nil,
			{
				{
					text = "View",
					color = C.cheese,
					enabled = true,
					onClick = function()
						local ok, Shop = pcall(require, script.Parent.ShopUI)
						if ok and type(Shop) == "table" and Shop.open then
							ProgressUI.close()
							Shop.open("Herd Pass")
						end
					end,
				},
			}
		)
	end
	if not pv.known then
		note("The Herd Pass is loading… 🐘")
		return
	end
	for _, t in pv.tiers do
		local buttons: { Btn } = {}
		local function claimBtn(track: string, can: boolean, claimed: boolean, has: boolean): Btn?
			if not has then
				return nil
			end
			if claimed then
				return { text = "✔", color = C.creamDark, enabled = false, onClick = function() end }
			end
			return {
				text = if track == "premium" and not pv.premium then "🔒 Premium" else "Claim",
				color = if track == "premium" then C.orange else C.green,
				enabled = can,
				onClick = function()
					Remotes.fire(Remotes.C2S.ClaimPassTier, t.tier, track)
				end,
			}
		end
		local fb = claimBtn("free", t.freeClaimable, t.freeClaimed, t.free ~= nil)
		local pb = claimBtn("premium", t.premiumClaimable, t.premiumClaimed, t.premium ~= nil)
		if fb then
			table.insert(buttons, fb)
		end
		if pb then
			table.insert(buttons, pb)
		end
		local parts = {}
		if t.free then
			table.insert(parts, "Free: " .. t.free.text)
		end
		if t.premium then
			table.insert(parts, "Premium: " .. t.premium.text)
		end
		rowCard(
			string.format("%sTier %d", if t.unlocked then "" else "🔒 ", t.tier),
			table.concat(parts, "   ·   "),
			nil,
			nil,
			buttons,
			t.unlocked
				and (t.free == nil or t.freeClaimed)
				and (t.premium == nil or t.premiumClaimed or not pv.premium)
		)
	end
end

-- Mousepedia pages: Config/Collection when Team P ships it, else built from
-- the configs that already exist (ids match what the server records).
local function bookPages(): { any }
	local cfg = Defs.module("Collection")
	if type(cfg) == "table" then
		local pages = cfg.PAGES or cfg.pages
		if type(pages) == "table" then
			return pages
		end
	end
	local function page(id: string, name: string, icon: string, module: string): any
		local entries = {}
		for _, d in Defs.all(module) do
			if d.id ~= nil and d.hidden ~= true then
				table.insert(entries, { id = tostring(d.id), name = Defs.name(d, d.id), color = d.color })
			end
		end
		return { id = id, name = name, icon = icon, entries = entries }
	end
	return {
		page("bosses", "Bosses", "👑", "Bosses"),
		page("champions", "Champions", "🏆", "Champions"),
		page("mice", "Mice", "🐭", "Enemies"),
		page("gear", "Gear", "🛡", "Gear"),
		page("maps", "Maps", "🗺", "Maps"),
		page("classes", "Classes", "🐘", "Classes"),
	}
end

-- Team P sends the book in the profile view (`book.pages`, entries {id, found});
-- names come from the configs each page lists.
local PAGE_MODULE: { [string]: string } = {
	bosses = "Bosses",
	champions = "Champions",
	mice = "Enemies",
	gear = "Gear",
	maps = "Maps",
	classes = "Classes",
}
local PAGE_ICON: { [string]: string } =
	{ bosses = "👑", champions = "🏆", mice = "🐭", gear = "🛡", maps = "🗺", classes = "🐘" }
local function serverBookPages(p: any): { any }?
	local book = p.book
	if type(book) ~= "table" or type(book.pages) ~= "table" or #book.pages == 0 then
		return nil
	end
	local out = {}
	for _, pg in book.pages do
		if type(pg) == "table" and pg.id ~= nil and type(pg.entries) == "table" then
			local pid = tostring(pg.id)
			local modName = PAGE_MODULE[pid]
			local entries = {}
			for _, e in pg.entries do
				local id = if type(e) == "table" then e.id else e
				if id ~= nil then
					local def = if modName then Defs.get(modName, id) else nil
					table.insert(entries, {
						id = id,
						name = if def then Defs.name(def, id) else tostring(id),
						color = if def then def.color else nil,
						found = if type(e) == "table" then e.found == true else nil,
					})
				end
			end
			table.insert(
				out,
				{ id = pid, name = pg.name or pid, icon = PAGE_ICON[pid] or "📖", entries = entries }
			)
		end
	end
	return out
end

local function renderBook()
	local p = profile()
	local pages, found, total = Progression.book(serverBookPages(p) or bookPages(), p.collection)
	heading(
		string.format("📖 Mousepedia · %d / %d found", found, total),
		"Every new entry: +5 ✨ Golden Cheese and +50 Pass XP."
	)
	local c = content
	if not c or #pages == 0 then
		note("The Mousepedia is coming soon! 📖")
		return
	end
	bookPage = math.clamp(bookPage, 1, #pages)
	local chips = make("Frame", {
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = c,
	})
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(140, Theme.SLIM),
		CellPadding = UDim2.fromOffset(6, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = chips,
	})
	for i, pg in pages do
		Theme.button(
			string.format("%s %s %d/%d", pg.icon, pg.name, pg.found, #pg.entries),
			if i == bookPage then C.cheese else C.creamDark,
			{
				LayoutOrder = i,
				TextSize = 13,
				Parent = chips,
			},
			function()
				bookPage = i
				ProgressUI.render()
			end
		)
	end
	local pg = pages[bookPage]
	local grid = make("Frame", {
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = c,
	})
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(160, 64),
		CellPadding = UDim2.fromOffset(6, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	for i, e in pg.entries do
		local f = make("Frame", {
			LayoutOrder = i,
			BackgroundColor3 = if e.found then C.cream else C.creamDark,
			Parent = grid,
		})
		Theme.corner(8).Parent = f
		Theme.stroke(if e.found then C.goldDeep else C.grey, 2).Parent = f
		local sw = make("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 8, 0.5, 0),
			Size = UDim2.fromOffset(26, 26),
			BackgroundColor3 = if e.found then Format.rgb(e.color, C.gold) else C.greyDark,
			Parent = f,
		})
		Theme.round().Parent = sw
		Theme.label({
			Position = UDim2.fromOffset(40, 4),
			Size = UDim2.new(1, -46, 1, -8),
			TextSize = 13,
			TextColor3 = if e.found then C.ink else C.greyDark,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = if e.found then e.name else "???",
			Parent = f,
		})
	end
end

-- iteration 2: 30 Challenges, with the old Achievements below as Milestones.
local renderAchievements: () -> ()
local function renderChallenges()
	local list, done, total = Progression.challenges(profile().challenges, Defs.module("Challenges"))
	heading(
		string.format("🏅 Challenges · %d / %d", done, total),
		"Hard, one-time feats. Each pays a title, a gem or Crumb Dust. All 30 earn the Wheel of Legends frame."
	)
	if #list == 0 then
		note("Challenges are coming soon! 🏅")
	end
	for _, c in list do
		rowCard(
			(if c.done then "✔ " else "") .. c.name,
			c.text .. (if c.reward.text ~= "" then "  ·  " .. c.reward.text else ""),
			nil,
			nil,
			{},
			c.done
		)
	end
	renderAchievements()
end

renderAchievements = function()
	local book = profile().book
	local list = if type(book) == "table" and type(book.achievements) == "table"
		then Progression.achievements(book.achievements, nil)
		else Progression.achievements(Defs.list(Defs.module("Achievements")), profile().achievements)
	local done = 0
	for _, a in list do
		if a.done then
			done += 1
		end
	end
	heading(string.format("🎖 Milestones · %d / %d", done, #list))
	if #list == 0 then
		note("Milestones are coming soon! 🎖")
		return
	end
	for _, a in list do
		rowCard(
			(if a.done then "✔ " else "") .. a.name,
			a.text .. (if a.reward.text ~= "" then "  ·  " .. a.reward.text else ""),
			if a.done or a.goal <= 1 then nil else a.progress / a.goal,
			if a.done or a.goal <= 1
				then nil
				else string.format("%s / %s", Format.int(a.progress), Format.int(a.goal)),
			{},
			a.done
		)
	end
end

local function renderLevels()
	local p = profile()
	local lv, xp, toNext = Progression.level(p)
	heading(
		string.format("⭐ Account level %d", lv),
		"Account XP comes from every run. Every 5 levels brings a reward."
	)
	local c = content
	if c then
		local bar = Theme.bar({ LayoutOrder = nextOrder(), Size = UDim2.new(1, -8, 0, 22), Parent = c }, C.xp)
		bar.set(xp / toNext, string.format("%s / %s XP", Format.int(xp), Format.int(toNext)))
	end
	local list = Progression.accountRewards(p, Defs.module("AccountRewards"))
	if #list == 0 then
		note("Level rewards are coming soon! ⭐")
		return
	end
	for _, r in list do
		rowCard(
			string.format("%sLevel %d", if r.level <= lv then "" else "🔒 ", r.level),
			r.reward.text,
			nil,
			nil,
			if r.claimable
				then {
					{
						text = "Claim",
						color = C.green,
						enabled = true,
						onClick = function()
							Remotes.fire(Remotes.C2S.ClaimAccountReward, r.level)
						end,
					},
				}
				elseif r.claimed then {
					{ text = "✔", color = C.creamDark, enabled = false, onClick = function() end },
				}
				else {},
			r.claimed
		)
	end
end

local BOARD_NAMES: { [string]: string } = {
	cheese = "🧀 Top Cheese",
	cheeseWeek = "🧀 Top Cheese this week",
	weeklyCheese = "🧀 Top Cheese this week",
	mice = "🐭 Most Mice Stomped",
	stomps = "🐭 Most Stomps",
	kills = "🐭 Most Mice Stomped",
	wins = "🏆 Most Wins",
	level = "⭐ Highest Level",
}

local function renderBoards()
	local lb = State.get("leaderboards")
	heading("🏆 Leaderboards")
	if type(lb) ~= "table" or next(lb) == nil then
		note("Leaderboards are loading… 🏆")
		return
	end
	local names = {}
	for k in lb do
		table.insert(names, tostring(k))
	end
	table.sort(names)
	for _, k in names do
		local rows = lb[k]
		local lines = {}
		if type(rows) == "table" then
			for i, r in rows do
				if i > 10 then
					break
				end
				if type(r) == "table" then
					table.insert(
						lines,
						string.format(
							"%d. %s  %s",
							i,
							tostring(r.name or r[1] or "?"),
							Format.int(tonumber(r.value or r[2]) or 0)
						)
					)
				end
			end
		end
		rowCard(
			BOARD_NAMES[k] or k,
			if #lines > 0 then table.concat(lines, "\n") else "No entries yet.",
			nil,
			nil,
			{}
		)
	end
end

function ProgressUI.render()
	if not modal or not modal.Visible then
		return
	end
	clear()
	for name, b in tabButtons do
		b.BackgroundColor3 = if name == currentTab then C.cheese else C.creamDark
	end
	local d = dots()
	if tabDots.Contracts then
		tabDots.Contracts.Visible = d.contracts > 0
	end
	if tabDots["Herd Pass"] then
		tabDots["Herd Pass"].Visible = d.pass > 0
	end
	if tabDots.Levels then
		tabDots.Levels.Visible = d.levels > 0
	end
	if currentTab == "Contracts" then
		renderContracts()
	elseif currentTab == "Herd Pass" then
		renderPass()
	elseif currentTab == "Mousepedia" then
		renderBook()
	elseif currentTab == "Achievements" then
		renderAchievements()
	elseif currentTab == "Levels" then
		renderLevels()
	elseif currentTab == "Challenges" then
		renderChallenges()
	else
		renderBoards()
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function ProgressUI.open(tab: string?)
	if not modal or not State.inLobby() then
		return
	end
	if tab and table.find(TABS, tab) then
		currentTab = tab
	else
		-- open where something is waiting
		local d = dots()
		currentTab = if d.contracts > 0
			then "Contracts"
			elseif d.pass > 0 then "Herd Pass"
			elseif d.levels > 0 then "Levels"
			else currentTab
	end
	modal.Visible = true
	State.setBusy("progress", true)
	Theme.popIn(modal)
	ProgressUI.render()
end

function ProgressUI.close()
	if modal then
		modal.Visible = false
	end
	State.setBusy("progress", false)
end

function ProgressUI.toggle()
	if modal and modal.Visible then
		ProgressUI.close()
	else
		ProgressUI.open()
	end
end

-- Account strip for the lobby (top-left column): level badge + XP, the Herd
-- button with a dot, and live boost timers (M2, M3). Returns the frame.
function ProgressUI.buildStrip(parent: Instance, layoutOrder: number?): Frame
	local touch = Theme.TOUCH
	local strip = Theme.card({
		Name = "AccountStrip",
		LayoutOrder = layoutOrder or 0,
		Size = UDim2.fromOffset(300, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = parent,
	}, { shadow = false })
	-- the layout lives on an inner frame so the strip itself can carry the skin
	local stripInner = make("Frame", {
		Name = "Inner",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = strip,
	})
	Theme.padding(8, 6).Parent = stripInner
	Theme.list(Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Left).Parent = stripInner
	local top = make("Frame", {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, touch),
		BackgroundTransparency = 1,
		Parent = stripInner,
	})
	local badge = Theme.badge("LV 1", C.goldDeep, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(0, 26),
		TextSize = 16,
		Parent = top,
	})
	Theme.tooltip(badge, "Account level: rises with every run and unlocks rewards every 5 levels.")
	local bar = Theme.bar({
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 70, 0.5, 0),
		Size = UDim2.new(1, -(70 + 112 + (if Theme.dense() then touch + 6 else 0)), 0, 14),
		Parent = top,
	}, C.xp)
	bar.text.TextSize = 11
	local herd = Theme.button("🐘 Herd", C.cheese, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(104, touch),
		TextSize = 17,
		Parent = top,
	}, function()
		ProgressUI.toggle()
	end)
	Theme.tooltip(herd, "Contracts, Herd Pass, Challenges, Mousepedia, level rewards and leaderboards.")
	-- iteration 2: Cheese Gems have their own screen
	-- inline on PC; on phones (big touch targets) it gets its own row
	local inline = Theme.dense()
	local gemsRow = if inline
		then top
		else make("Frame", {
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, touch),
			BackgroundTransparency = 1,
			Parent = stripInner,
		})
	local gems = Theme.button(if inline then "💎" else "💎 Gems", C.cream, {
		AnchorPoint = if inline then Vector2.new(1, 0.5) else Vector2.new(0, 0),
		Position = if inline then UDim2.new(1, -110, 0.5, 0) else UDim2.fromScale(0, 0),
		Size = if inline then UDim2.fromOffset(touch, touch) else UDim2.new(1, 0, 0, touch),
		TextSize = 18,
		Parent = gemsRow,
	}, function()
		local okG, GemsUI = pcall(require, script.Parent.GemsUI)
		if okG and type(GemsUI) == "table" and GemsUI.toggle then
			GemsUI.toggle()
		end
	end)
	Theme.tooltip(gems, "Cheese Gems: sockets, upgrades and Crumb Dust.")
	local herdDot = dot(herd)
	local boostBox = make("Frame", {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = false,
		Parent = stripInner,
	})
	Theme.list(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Left).Parent = boostBox
	local boostLines: { TextLabel } = {}
	for i = 1, 3 do
		local l = Theme.label({
			LayoutOrder = i,
			Size = UDim2.new(1, 0, 0, 16),
			TextSize = 12,
			Font = Theme.FONT_BODY,
			TextColor3 = C.goldLight,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Visible = false,
			Parent = boostBox,
		})
		Theme.textStroke(C.shade, 1).Parent = l
		boostLines[i] = l
	end

	local function render()
		local p = profile()
		local lv, xp, toNext = Progression.level(p)
		badge.Text = "LV " .. lv
		-- v5: account stomps ride on the XP bar caption
		local st = (if type(p.stomps) == "table" then tonumber(p.stomps.total) else nil)
			or (if type(p.stats) == "table" then tonumber(p.stats.stomps) else nil)
		bar.set(
			xp / toNext,
			string.format("%s / %s", Format.short(xp), Format.short(toNext))
				.. (if st and st > 0 then "  ·  🐭 " .. Format.short(st) else "")
		)
		herdDot.Visible = dots().progress
		local boosts = Progression.boosts(p, os.clock() - (State.get("profileAt") or os.clock()))
		boostBox.Visible = #boosts > 0
		for i, l in boostLines do
			local b = boosts[i]
			l.Visible = b ~= nil
			l.Text = if b then "⚡ " .. b.text else ""
		end
	end
	for _, key in { "profile", "quests", "pass" } do
		table.insert(unsubs, State.subscribe(key, render, key == "profile"))
	end
	-- Boost timers tick once a second.
	local acc = 0
	stripConn = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 1 then
			acc = 0
			if strip.Visible then
				render()
			end
		end
	end)
	return strip
end

-- Cosmetic / title ids -> display names for reward text.
local function rewardName(kind: string, id: string): string?
	if kind == "title" then
		local mod = Defs.module("Cosmetics")
		local t = type(mod) == "table" and type(mod.EARNED_TITLES) == "table" and mod.EARNED_TITLES[id]
		return if type(t) == "table" and t.text then "Title: " .. tostring(t.text) else nil
	end
	local def = Defs.get(if kind == "skin" then "ClassSkins" else "Cosmetics", id)
	return if def then Defs.name(def, id) else nil
end

function ProgressUI.init()
	if screen then
		return
	end
	Progression.setNamer(rewardName)
	screen = Theme.screen("TrunkfallHerd", 36)
	local touch = Theme.TOUCH
	local headH = math.max(52, touch + 8)
	local tabH = Theme.SLIM + 4
	local m = Theme.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(900, 560),
		Visible = false,
		Parent = screen.root,
	})
	table.insert(unsubs, Theme.fitFrame(screen, m, 900, 580, 10))
	Theme.compact(m)
	modal = m
	Theme.label({
		Position = UDim2.fromOffset(16, 6),
		Size = UDim2.new(1, -(touch + 40), 0, 40),
		TextSize = 28,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "🐘 The Herd",
		Parent = m,
	})
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 6),
		Size = UDim2.fromOffset(touch, touch),
		TextColor3 = C.white,
		Parent = m,
	}, ProgressUI.close)
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
		local b = Theme.button(TAB_LABEL[name] or name, C.creamDark, {
			LayoutOrder = i,
			Size = UDim2.fromOffset(140, tabH),
			TextSize = 15,
			Parent = tabs,
		}, function()
			currentTab = name
			ProgressUI.render()
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
	Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = c
	Theme.padding(4, 4).Parent = c
	content = c

	for _, key in { "profile", "quests", "pass", "leaderboards" } do
		table.insert(
			unsubs,
			State.subscribe(key, function()
				if modal and modal.Visible then
					local pos = c.CanvasPosition
					ProgressUI.render()
					c.CanvasPosition = pos -- a claim keeps your place in the list
				end
			end)
		)
	end
	table.insert(
		unsubs,
		State.subscribe("run", function()
			if not State.inLobby() and modal and modal.Visible then
				ProgressUI.close()
			end
		end)
	)
end

function ProgressUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	if stripConn then
		stripConn:Disconnect()
		stripConn = nil
	end
	State.setBusy("progress", false)
	if screen then
		screen.destroy()
		screen = nil
	end
	modal = nil
	content = nil
	table.clear(tabButtons)
	table.clear(tabDots)
end

return ProgressUI
