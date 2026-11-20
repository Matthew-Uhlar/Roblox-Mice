--!strict
-- End-of-run screen v2 (Net.S2C.Results -> State "results").
--
--   * Extracted / Last Herd Standing / Eliminated (v1: Victory / Wiped out)
--   * squad placement ("2nd of 4 squads") from the final Match standings
--   * cheese earned with a count-up and a breakdown (payload `breakdown`, or
--     built from cheeseMult / lastHerd)
--   * class XP gained with an animated bar that rolls over levels and a
--     LEVEL UP! pop, plus the unlocks it brought (alternate ability, skin,
--     mastery) from Util/ClassMath + UI/ClassInfo
--   * "Gear is lost at the end of the run" with the run's gear crossed out
--   * kills / downs / stages / duration
--
-- Payload fields read: outcome, result, squad, classId, classXp, cheeseEarned,
-- cheeseMult, breakdown?, placement?, xpEarned, kills, downs, stagesCleared,
-- lastHerd, cycle, stage, bossesKilled, duration.
-- v4 (V4-PLAN "Match features", review R §4.7):
--   * MVP + your Herd Awards card (Net.S2C.Awards -> State "awards"; may land
--     before or after Results)
--   * secured cheese (banked during the run, kept even on a wipe) on its own line
--     (payload `secured` / `securedCheese`)
--   * a non-modal "View in shop" card under the class XP card, only on a WIN
--     (extracted / Last Herd), at most once per session. It only opens the
--     shop's Featured tab: no prompt, and nothing on a loss.
--   * footer: Play Again (Net.C2S.PlayAgain: a fresh server with your party;
--     only once you are out: eliminated or extracted), Share (game invite
--     prompt) and Lobby (closes the panel). Buttons stay pinned; content scrolls.

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local ClassInfo = require(script.Parent.ClassInfo)
local GearInfo = require(script.Parent.GearInfo)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local Remotes = require(Client.Util.Remotes)
local Device = require(Client.Util.Device)
local ClassMath = require(Client.Util.ClassMath)
local Scoreboard = require(Client.Util.Scoreboard)
local HudMath = require(Client.Util.HudMath)
local ResultsModel = require(Client.Util.ResultsModel)
local GemModel = require(Client.Util.GemModel)
local LadderModel = require(Client.Util.LadderModel)
local HeroModel = require(Client.Util.HeroModel)
local ShopModel = require(Client.Util.ShopModel)
local State = require(Client.Controllers.State)

local ResultsUI = {}

local C = Theme.C
local T = Theme.TYPE
local make = Theme.make

local screen: any = nil
local unsubs: { () -> () } = {}
local animConn: RBXScriptConnection? = nil
local shopCardShown = false -- the win-only shop card shows at most once per session

-- Name of today's first featured cosmetic, for the win card.
local function featuredName(): string?
	local mod = Defs.module("Shop")
	if type(mod) ~= "table" or type(mod.list) ~= "function" then
		return nil
	end
	local ok, list = pcall(mod.list)
	if not ok or type(list) ~= "table" then
		return nil
	end
	local picks = ShopModel.featuredCosmetics(list, math.floor(os.time() / 86400), mod)
	local e = picks[1]
	return if e then tostring(e.name or e.refId) else nil
end

local function stopAnim()
	if animConn then
		animConn:Disconnect()
		animConn = nil
	end
end

function ResultsUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallResults", 50)
	local root: Frame = screen.root
	local touch = Theme.TOUCH
	local shade = make("Frame", {
		BackgroundColor3 = C.shade,
		BackgroundTransparency = 0.45,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = root,
	})
	local panel = Theme.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(620, 560),
		Parent = shade,
	})
	local footerH = touch + 18
	-- v3: 10% smaller on PC on top of the smaller screen scale (Theme.compact).
	local rest = Theme.compact(panel)
	table.insert(unsubs, Theme.fitFrame(screen, panel, 620, 330 + footerH + 230, 10 / rest))

	local content = Theme.scroller({
		Position = UDim2.fromOffset(0, 8),
		Size = UDim2.new(1, 0, 1, -(footerH + 8)),
		Parent = panel,
	})
	Theme.padding(20, 8).Parent = content
	Theme.list(Enum.FillDirection.Vertical, 8).Parent = content

	local function line(order: number, size: number, color: Color3, font: Enum.Font?): TextLabel
		return Theme.label({
			LayoutOrder = order,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, size + 4),
			TextSize = size,
			TextColor3 = color,
			Font = font or Theme.FONT,
			Parent = content,
		})
	end

	local title = line(1, T.display, C.cheese)
	Theme.textStroke(C.brownDark, 3).Parent = title
	local placeRow = make("Frame", {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		Parent = content,
	})
	Theme.list(
		Enum.FillDirection.Horizontal,
		8,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	).Parent =
		placeRow
	local placeBadge =
		Theme.badge("", C.gold, { Size = UDim2.fromOffset(0, 28), TextSize = T.body, Parent = placeRow })
	local subtitle = line(3, T.body, C.brown, Theme.FONT_BODY)

	-- Cheese
	local cheeseRow = make("Frame", {
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, 52),
		BackgroundTransparency = 1,
		Parent = content,
	})
	Theme.list(
		Enum.FillDirection.Horizontal,
		10,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	).Parent =
		cheeseRow
	Theme.icon("cheese", 44, C.cheese, { LayoutOrder = 1, Parent = cheeseRow })
	local cheeseBig = Theme.label({
		LayoutOrder = 2,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 50),
		TextSize = 42,
		TextColor3 = C.ink,
		TextWrapped = false,
		Parent = cheeseRow,
	})
	local breakdown = make("Frame", {
		LayoutOrder = 5,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.creamDark,
		Parent = content,
	})
	Theme.corner(10).Parent = breakdown
	Theme.padding(14, 8).Parent = breakdown
	Theme.list(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Left).Parent = breakdown
	local breakdownRows: { TextLabel } = {}
	for i = 1, 14 do
		breakdownRows[i] = Theme.label({
			LayoutOrder = i,
			Size = UDim2.new(1, 0, 0, 20),
			TextSize = T.caption + 1,
			Font = Theme.FONT_BODY,
			TextColor3 = C.ink,
			TextXAlignment = Enum.TextXAlignment.Left,
			Visible = false,
			Parent = breakdown,
		})
	end

	-- Class XP card
	-- Secured cheese (v4): banked during the run, shown apart from the pot.
	local securedLine = line(6, T.body, C.greenDark, Theme.FONT_BODY)

	-- MVP + your awards (v4)
	local awardsCard = make("Frame", {
		LayoutOrder = 7,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.rind,
		Visible = false,
		Parent = content,
	})
	Theme.corner(12).Parent = awardsCard
	Theme.goldStroke(2).Parent = awardsCard
	Theme.padding(12, 8).Parent = awardsCard
	Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center).Parent = awardsCard
	local mvpLabel = Theme.label({
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 26),
		TextSize = T.heading,
		TextColor3 = C.gold,
		Parent = awardsCard,
	})
	Theme.textStroke(C.shade, 1.5).Parent = mvpLabel
	local awardRow = make("Frame", {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = awardsCard,
	})
	Theme.list(
		Enum.FillDirection.Horizontal,
		6,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	).Parent =
		awardRow

	-- Loot (iteration 3 T-12): gems found, a tier unlocked, a Best Solo, challenges
	local lootCard = make("Frame", {
		LayoutOrder = 8,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.cream,
		Visible = false,
		Parent = content,
	})
	Theme.corner(12).Parent = lootCard
	Theme.stroke(C.goldDeep, 2).Parent = lootCard
	local lootInner = make("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = lootCard,
	})
	Theme.padding(12, 8).Parent = lootInner
	Theme.list(Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Left).Parent = lootInner

	local classCard = make("Frame", {
		LayoutOrder = 12,
		Size = UDim2.new(1, 0, 0, 118),
		BackgroundColor3 = C.rind,
		Parent = content,
	}) :: Frame
	Theme.corner(12).Parent = classCard
	Theme.goldStroke(2).Parent = classCard
	Theme.gradient(classCard, Color3.fromRGB(255, 240, 220), Color3.fromRGB(150, 130, 110))
	local classTitle = Theme.label({
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.new(1, -160, 0, 24),
		TextSize = T.heading,
		TextColor3 = C.gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = classCard,
	})
	Theme.textStroke(C.shade, 1.5).Parent = classTitle
	local levelBadge = Theme.badge("LV 1", C.goldDeep, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 8),
		Size = UDim2.fromOffset(0, 26),
		TextSize = T.body,
		Parent = classCard,
	})
	local classBar = Theme.bar({
		Position = UDim2.fromOffset(14, 40),
		Size = UDim2.new(1, -28, 0, 20),
		Parent = classCard,
	}, C.xp)
	classBar.text.TextSize = T.caption
	local levelUp = Theme.label({
		Position = UDim2.fromOffset(14, 64),
		Size = UDim2.new(1, -28, 0, 24),
		TextSize = T.heading,
		TextColor3 = C.green,
		Text = "",
		Parent = classCard,
	})
	Theme.textStroke(C.shade, 1.5).Parent = levelUp
	local unlockRow = make("Frame", {
		Position = UDim2.fromOffset(14, 90),
		Size = UDim2.new(1, -28, 0, 24),
		BackgroundTransparency = 1,
		Parent = classCard,
	})
	Theme.list(
		Enum.FillDirection.Horizontal,
		6,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	).Parent =
		unlockRow

	-- Gear lost
	-- "View in shop" (WIN only, once per session, never a prompt)
	local shopCard = make("Frame", {
		LayoutOrder = 13,
		Size = UDim2.new(1, 0, 0, touch + 16),
		BackgroundColor3 = C.creamDark,
		Visible = false,
		Parent = content,
	})
	Theme.corner(10).Parent = shopCard
	local shopText = Theme.label({
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -190, 1, 0),
		TextSize = T.caption + 1,
		Font = Theme.FONT_BODY,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = shopCard,
	})

	local gearCard = make("Frame", {
		LayoutOrder = 14,
		Size = UDim2.new(1, 0, 0, 64),
		BackgroundColor3 = C.creamDark,
		Parent = content,
	})
	Theme.corner(10).Parent = gearCard
	local gearIcons = make("Frame", {
		Position = UDim2.fromOffset(10, 8),
		Size = UDim2.fromOffset(150, 48),
		BackgroundTransparency = 1,
		Parent = gearCard,
	})
	Theme.list(Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent =
		gearIcons
	Theme.label({
		Position = UDim2.fromOffset(166, 6),
		Size = UDim2.new(1, -176, 1, -12),
		TextSize = T.caption + 1,
		Font = Theme.FONT_BODY,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Gear is lost at the end of the run. You keep your cheese and XP.",
		Parent = gearCard,
	})

	-- Stats grid
	local stats = make("Frame", {
		LayoutOrder = 15,
		BackgroundColor3 = C.creamDark,
		Size = UDim2.new(1, 0, 0, 104),
		Parent = content,
	})
	Theme.corner(12).Parent = stats
	Theme.padding(16, 10).Parent = stats
	make("UIGridLayout", {
		CellSize = UDim2.new(0.5, -6, 0, 34),
		CellPadding = UDim2.fromOffset(12, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = stats,
	})
	local statLabels: { TextLabel } = {}
	for i = 1, 4 do
		statLabels[i] = Theme.label({
			LayoutOrder = i,
			TextSize = 20,
			TextColor3 = C.ink,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextScaled = true,
			Parent = stats,
		})
		make("UITextSizeConstraint", { MaxTextSize = 20, MinTextSize = 12, Parent = statLabels[i] })
	end

	-- Footer: always visible, outside the scrolling content.
	local footer = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(1, -24, 0, touch + 6),
		BackgroundTransparency = 1,
		Parent = panel,
	})
	Theme.list(
		Enum.FillDirection.Horizontal,
		12,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	).Parent =
		footer
	local function close()
		stopAnim()
		State.set("results", nil)
	end
	Theme.button("View in shop", C.cheese, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(170, touch),
		TextSize = 17,
		Parent = shopCard,
	}, function()
		close()
		local ok, Shop = pcall(require, script.Parent.ShopUI)
		if ok and type(Shop) == "table" and Shop.openWhenLobby then
			Shop.openWhenLobby("Featured")
		end
	end)

	local playAgain = Theme.button("🐘 Play Again", C.green, {
		LayoutOrder = 1,
		Size = UDim2.new(0.44, -8, 0, touch + 6),
		TextSize = 24,
		TextColor3 = C.white,
		Parent = footer,
	}, function()
		-- a fresh server with your party (never automatic)
		Remotes.fire(Remotes.C2S.PlayAgain)
		close()
	end)
	Theme.textStroke(C.brownDark, 2).Parent = playAgain
	Theme.tooltip(playAgain, "Start a new match on a fresh server, with your party.")
	local shareButton = Theme.button("📣 Share", C.blue, {
		LayoutOrder = 2,
		Size = UDim2.new(0.28, -8, 0, touch + 6),
		TextSize = 20,
		TextColor3 = C.white,
		Parent = footer,
	}, function()
		task.spawn(function()
			local SocialService = game:GetService("SocialService")
			local player = game:GetService("Players").LocalPlayer
			local okCan, can = pcall(function()
				return SocialService:CanSendGameInviteAsync(player)
			end)
			if okCan and can then
				pcall(function()
					SocialService:PromptGameInvite(player)
				end)
			else
				State.toast:Fire("Invites aren't available on this account.", "info")
			end
		end)
	end)
	Theme.textStroke(C.brownDark, 1.5).Parent = shareButton
	local lobbyButton = Theme.button("Lobby", C.creamDark, {
		LayoutOrder = 3,
		Size = UDim2.new(0.28, -8, 0, touch + 6),
		TextSize = 22,
		Parent = footer,
	}, close)

	-- MVP / awards (Awards may arrive after Results).
	local function renderAwards()
		for _, ch in awardRow:GetChildren() do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		local res = State.get("results")
		local a = HudMath.awards(
			State.get("awards"),
			State.localUserId(),
			if type(res) == "table" then tonumber(res.mice or res.miceKilled) else nil
		)
		if not a or State.get("results") == nil then
			awardsCard.Visible = false
			return
		end
		local mvpName = a.mvpName
		if mvpName == nil and a.mvpId ~= nil then
			mvpName = State.nameOf(a.mvpId)
		end
		mvpLabel.Text = (
			if a.mvpIsYou
				then "⭐ YOU are the MVP!"
				elseif mvpName then "⭐ MVP: " .. mvpName
				else "⭐ Herd Awards"
		) .. (if a.topBotName then "   ·   Top 🤖: " .. a.topBotName else "")
		for i, acc in a.yours do
			local b = Theme.badge(
				acc.icon .. " " .. acc.text .. (if acc.value then " · " .. acc.value else ""),
				if i == 1 then C.goldDeep else C.rindLight,
				{
					LayoutOrder = i,
					Size = UDim2.fromOffset(0, 26),
					TextSize = T.caption + 1,
					Parent = awardRow,
				}
			)
			Theme.popIn(b)
		end
		awardRow.Visible = #a.yours > 0
		awardsCard.Visible = true
	end
	table.insert(unsubs, State.subscribe("awards", renderAwards))

	local function chip(text: string, kind: string, color: Color3)
		local b =
			Theme.badge(text, color, { Size = UDim2.fromOffset(0, 22), TextSize = 13, Parent = unlockRow })
		b.Name = "Unlock_" .. kind
		Theme.popIn(b)
	end

	local function unlockName(classId: string, u: ClassMath.Unlock, level: number): string
		if u.kind == "ability" then
			local list = ClassInfo.abilities(classId, level, nil)
			local a = list[u.index]
			return "New ability: " .. (if a then a.name else "alternate " .. (u.index - 1))
		elseif u.kind == "skin" then
			for _, sk in ClassInfo.skins(classId, level, nil) do
				if sk.unlockLevel == u.level and not sk.placeholder then
					return "New skin: " .. sk.name
				end
			end
			return "New skin unlocked"
		end
		local m = ClassMath.MASTERY[u.index]
		return "Mastery: " .. (if m then m.name else "unlocked")
	end

	local function render(r: any)
		stopAnim()
		if type(r) ~= "table" then
			shade.Visible = false
			if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(shade) then
				GuiService.SelectedObject = nil
			end
			return
		end
		local result = if type(r.result) == "string" then string.lower(r.result) else nil
		local v2 = result ~= nil or r.squad ~= nil or r.classId ~= nil
		local extracted = result == "extracted" or result == "lastherd" or r.lastHerd == true
		local eliminated = result == "eliminated"
		local win = r.outcome == "Win"
		if r.lastHerd == true or result == "lastherd" then
			title.Text = "LAST HERD STANDING!"
			title.TextColor3 = C.cheese
		elseif extracted then
			title.Text = "EXTRACTED!"
			title.TextColor3 = C.green
		elseif eliminated then
			title.Text = "ELIMINATED"
			title.TextColor3 = C.red
		elseif v2 then
			title.Text = "RUN OVER"
			title.TextColor3 = C.cheese
		else
			title.Text = if win then "🏆 VICTORY!" else "💥 WIPED OUT"
			title.TextColor3 = if win then C.cheese else C.red
		end
		subtitle.Text = if extracted
			then "Your squad made it out through the Rind Gate with the pot!"
			elseif eliminated then "Your squad was eliminated. The pot is lost; class XP still counts."
			elseif v2 then "The run is over."
			elseif win then "The herd made it home with the cheese!"
			else "The mice win this round… you kept your banked cheese."

		-- Placement
		local match = State.get("resultsMatch") or State.get("match")
		local squadId = tonumber(r.squad) or (if type(match) == "table" then match.mySquad else nil)
		local place = tonumber(r.placement)
		if place == nil and squadId and type(match) == "table" then
			place = Scoreboard.placement(match.squads, squadId)
		end
		placeRow.Visible = place ~= nil
		if place then
			local name, col = Theme.squad(squadId)
			local sq = if type(match) == "table" then State.squad(squadId) else nil
			if sq then
				name, col = sq.name, Color3.fromRGB(sq.color[1], sq.color[2], sq.color[3])
			end
			local n = if type(match) == "table" then math.max(#match.squads, 1) else 4
			placeBadge.Text = string.format("%s · %s of %d squads", name, Scoreboard.ordinal(place), n)
			placeBadge.BackgroundColor3 = col:Lerp(C.brownDark, 0.25)
		end
		-- T-12: an extraction says "Extracted · secured X", not a placement
		local exText = ResultsModel.placementText(r)
		if exText then
			placeRow.Visible = true
			placeBadge.Text = exText
			placeBadge.BackgroundColor3 = C.greenDark
		end
		-- T-12: name the tier played
		local prof0 = State.get("profile")
		local tierN = tonumber(r.tier)
			or (if type(match) == "table" then tonumber(match.tier) else nil)
			or (if type(prof0) == "table" then tonumber(prof0.lastTier) else nil)
		if tierN ~= nil then
			subtitle.Text ..= "\n" .. (if tierN == 0
				then "⚙ Custom difficulty"
				else string.format(
					"Tier %d · %s",
					tierN,
					LadderModel.name(Defs.module("Difficulty"), tierN)
				))
		end

		-- Cheese breakdown (iteration 1 #14): the headline is everything the
		-- profile gained from this run, and each part has its own row.
		local earned = ResultsModel.total(r)
		local rows: { string } = {}
		local highlights: { [number]: boolean } = {}
		if v2 or r.secured ~= nil or r.totalCheese ~= nil or type(r.breakdown) == "table" then
			-- T-12: cheese rows first, then the XP rows under their own heading
			local xpRows = {}
			for _, row in ResultsModel.rows(r) do
				local text = string.format("%s %s   %s", row.icon, row.label, row.value)
				if string.find(row.label, "XP", 1, true) then
					table.insert(xpRows, text)
				else
					table.insert(rows, text)
					if row.highlight then
						highlights[#rows] = true
					end
				end
			end
			if #xpRows > 0 then
				table.insert(rows, "— Experience —")
				for _, t in xpRows do
					table.insert(rows, t)
				end
			end
			if not extracted and v2 and ResultsModel.don(r) == nil then
				table.insert(rows, "💀 Pot lost: only the secured part is kept")
			end
		end
		local mult = tonumber(r.cheeseMult)
		if r.lastHerd == true then
			table.insert(rows, "🏆 Last Herd Standing bonus ×1.5")
		end
		if mult and math.abs(mult - 1) > 0.001 then
			table.insert(rows, "⚡ Cheese bonus " .. Format.mult(mult) .. " (boosts / passes / talents)")
		end
		for i, l in breakdownRows do
			l.Visible = rows[i] ~= nil
			l.Text = rows[i] or ""
			l.TextColor3 = if highlights[i] then C.greenDark else C.ink
		end
		breakdown.Visible = #rows > 0
		local secured = HudMath.secured(r)
		securedLine.Visible = secured > 0 and #rows == 0
		securedLine.Text =
			string.format("🔒 Secured during the run: 🧀 %s (always kept)", Format.int(secured))
		renderAwards()
		-- Loot column (T-12)
		for _, ch in lootInner:GetChildren() do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		local loot = ResultsModel.loot(r, State.get("profileAtStart"), State.get("profile"))
		local lootLines: { any } = {}
		local diff = Defs.module("Difficulty")
		for _, g in loot.gems do
			local gm = GemModel.gem(g)
			if gm then
				local u = gm.uniqueText or (if gm.unique then "unique" else nil)
				table.insert(lootLines, {
					string.format(
						"💎 New gem: Tier %d %s%s",
						gm.tier,
						LadderModel.name(diff, gm.tier),
						if u then " · " .. u else ""
					),
					C.ink,
				})
			end
		end
		if loot.tierUnlocked then
			table.insert(lootLines, {
				"🔓 New difficulty unlocked: " .. LadderModel.name(diff, loot.tierUnlocked) .. "!",
				C.greenDark,
			})
		end
		if loot.bestSolo then
			local secs = math.floor(tonumber(loot.bestSoloSeconds) or 0)
			table.insert(lootLines, {
				"🏅 New Best Solo: " .. LadderModel.name(diff, loot.bestSolo) .. (if secs > 0
					then string.format(" · %d:%02d", secs // 60, secs % 60)
					else ""),
				C.goldDeep,
			})
		end
		for _, name in loot.challenges do
			table.insert(lootLines, { "🏆 Challenge done: " .. name, C.purple })
		end
		for i, ln in lootLines do
			local l = Theme.label({
				LayoutOrder = i,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextSize = T.body,
				Font = Theme.FONT,
				TextColor3 = ln[2],
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = ln[1],
				Parent = lootInner,
			})
			Theme.popIn(l)
		end
		lootCard.Visible = #lootLines > 0
		-- WIN only, once per session; hidden on any loss
		local showShop = HudMath.isWin(r) and not shopCardShown
		if showShop then
			local name = featuredName()
			showShop = name ~= nil
			shopText.Text = "Today in the Market: " .. (name or "")
		end
		shopCard.Visible = showShop
		if showShop then
			shopCardShown = true
		end
		playAgain.Visible = HudMath.canPlayAgain(r)
		lobbyButton.Size = UDim2.new(if playAgain.Visible then 0.28 else 0.5, -8, 0, touch + 6)
		shareButton.Size = UDim2.new(if playAgain.Visible then 0.28 else 0.5, -8, 0, touch + 6)

		-- Class XP
		local classId = if r.classId ~= nil then tostring(r.classId) else nil
		local gain = tonumber(r.classXp) or 0
		classCard.Visible = classId ~= nil
		for _, ch in unlockRow:GetChildren() do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		levelUp.Text = ""
		local startXp, startLv = 0, 1
		-- iteration 2: a prestiged hero re-climbs its shown level (prestigeXp)
		local pmode = false
		local pStart, pTotal, pNum = 0, HeroModel.PRESTIGE_XP, 0
		if classId then
			local before = State.get("classesAtStart")
			local b = if type(before) == "table" then before[classId] else nil
			if type(b) == "table" and (tonumber(b.prestige) or 0) > 0 then
				pmode = true
				pNum = math.floor(tonumber(b.prestige) or 0)
				pStart = tonumber(b.prestigeXp) or 0
				pTotal = tonumber(b.prestigeXpToNext) or HeroModel.PRESTIGE_XP
			end
			if type(b) == "table" then
				startXp, startLv = tonumber(b.xp) or 0, math.max(1, tonumber(b.level) or 1)
			else
				-- No snapshot: derive "before" from the current profile minus the gain.
				local now = ClassInfo.progress(classId)
				startXp, startLv = now.xp, now.level
				gain = 0
			end
			classTitle.Text = string.format(
				"%s · +%s class XP",
				Defs.name(Defs.get("Classes", classId), classId),
				Format.int(tonumber(r.classXp) or 0)
			)
			levelBadge.Text = "LV " .. startLv
			classBar.set(
				ClassMath.progress(startXp, startLv),
				string.format("%s / %s XP", Format.int(startXp), Format.int(ClassMath.xpToNext(startLv)))
			)
			if pmode then
				local _, _, frac = HeroModel.reclimb(pStart, pTotal)
				levelBadge.Text = string.format("LV 30 ⭐%d", pNum)
				classBar.set(frac, string.format("%d%% to ⭐%d", math.floor(frac * 100), pNum + 1))
			end
		end
		local pShown = if pmode then select(2, HeroModel.reclimb(pStart, pTotal)) else 0

		-- Gear lost
		local inv = State.get("resultsInventory")
		for _, ch in gearIcons:GetChildren() do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		local anyGear = false
		for _, slot in GearInfo.SLOTS do
			local info = GearInfo.describe(if type(inv) == "table" then inv[slot] else nil)
			local box = make("Frame", {
				Size = UDim2.fromOffset(44, 44),
				BackgroundColor3 = C.rind,
				BackgroundTransparency = 0.2,
				Parent = gearIcons,
			})
			Theme.corner(8).Parent = box
			Theme.icon(
				if info then info.icon else Theme.Icons.forSlot(slot),
				34,
				if info then info.color else C.greyDark,
				{
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Parent = box,
				}
			)
			if info then
				anyGear = true
				Theme.icon("cross", 40, C.red, {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					ZIndex = 4,
					Parent = box,
				})
				Theme.tooltip(box, info.name .. " (" .. info.rarity .. "): left behind in the arena.")
			end
		end
		gearCard.Visible = v2 or anyGear

		-- Stats
		if v2 then
			-- P-9: mice and champions first; PvP downs last
			local st = ResultsModel.stats(r)
			for i = 1, 4 do
				statLabels[i].Text = st[i]
			end
		else
			statLabels[1].Text = "⭐ XP +" .. Format.int(r.xpEarned)
			statLabels[2].Text =
				string.format("🗺 Cycle %d · Stage %d", tonumber(r.cycle) or 1, tonumber(r.stage) or 1)
			statLabels[3].Text = "👑 Bosses: " .. Format.int(r.bossesKilled)
			statLabels[4].Text = "⏱ " .. Format.clock(r.duration)
		end

		content.CanvasPosition = Vector2.zero
		shade.Visible = true
		Theme.popIn(panel)
		if Device.mode() == "gamepad" then
			GuiService.SelectedObject = if playAgain.Visible then playAgain else lobbyButton
		end

		-- Animations: cheese count-up, then the class XP bar rolling over levels.
		local t0 = os.clock()
		local CHEESE_T, XP_T = 1.0, 1.6
		local shownLevel = startLv
		cheeseBig.Text = "+0"
		animConn = RunService.RenderStepped:Connect(function()
			local t = os.clock() - t0
			local a = math.clamp(t / CHEESE_T, 0, 1)
			local eased = 1 - (1 - a) ^ 3
			cheeseBig.Text = ResultsModel.signed(earned * eased)
			if classId and gain > 0 and pmode then
				-- Prestige re-climb: the shown level rises 1 -> 30 over the Prestige XP
				local b = math.clamp((t - CHEESE_T * 0.6) / XP_T, 0, 1)
				local e2 = 1 - (1 - b) ^ 2
				local _, lv, frac = HeroModel.reclimb(pStart + gain * e2, pTotal)
				-- T-15: progress toward the next Prestige, in percent
				classBar.set(
					frac,
					if frac >= 1
						then string.format("Ready to Prestige ⭐%d!", pNum + 1)
						else string.format("%d%% to ⭐%d", math.floor(frac * 100), pNum + 1)
				)
				if frac >= 1 and lv > pShown then
					pShown = lv
					levelUp.Text = string.format("⭐ Prestige %d is ready in the Hero screen!", pNum + 1)
					Theme.popIn(levelUp)
				end
				if b >= 1 and a >= 1 then
					stopAnim()
				end
			elseif classId and gain > 0 then
				local b = math.clamp((t - CHEESE_T * 0.6) / XP_T, 0, 1)
				local e2 = 1 - (1 - b) ^ 2
				local xp, lv = ClassMath.addXp(startXp, startLv, gain * e2)
				local toNext = ClassMath.xpToNext(lv)
				classBar.set(
					ClassMath.progress(xp, lv),
					if lv >= ClassMath.MAX_LEVEL
						then "MAX LEVEL"
						else string.format("%s / %s XP", Format.int(xp), Format.int(toNext))
				)
				if lv > shownLevel then
					for _, u in ClassMath.unlocksBetween(shownLevel, lv) do
						chip(
							unlockName(classId, u, lv),
							u.kind,
							if u.kind == "mastery"
								then C.goldDeep
								elseif u.kind == "skin" then C.purple
								else C.blue
						)
					end
					shownLevel = lv
					levelBadge.Text = "LV " .. lv
					levelUp.Text = string.format(
						"LEVEL UP! Lv %d → %d  ·  +%d perk point%s",
						startLv,
						lv,
						lv - startLv,
						if lv - startLv == 1 then "" else "s"
					)
					Theme.popIn(levelBadge)
					Theme.popIn(levelUp)
				end
				if b >= 1 and a >= 1 then
					stopAnim()
				end
			elseif a >= 1 then
				stopAnim()
			end
		end)
	end

	table.insert(unsubs, State.subscribe("results", render, true))
	-- A new run started (e.g. the lobby auto-start) while the panel was open.
	table.insert(
		unsubs,
		State.subscribe("run", function(run)
			local phase = if type(run) == "table" then run.phase else nil
			if State.get("results") ~= nil and phase ~= nil and phase ~= "Results" and phase ~= "Lobby" then
				close()
			end
		end)
	)
end

function ResultsUI.destroy()
	stopAnim()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	if screen then
		screen.destroy()
		screen = nil
	end
end

return ResultsUI
