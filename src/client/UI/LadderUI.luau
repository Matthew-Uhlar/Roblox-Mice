--!strict
-- Difficulty ladder card for the lobby (iteration 2; ALIGNMENT §2c A1, §3).
-- LadderUI.buildCard(parent, order) is placed by UI/LobbyUI in its top-left
-- column. It shows "Tier 6 · Smoked", the reward ×, the gem tier and your Best
-- Solo / Best Squad. The party leader (👑) steps the tier with ◀ ▶ among the
-- tiers they have unlocked; everyone else sees it read-only. A "Ladder"
-- button opens the full 11-tier grid. The same card holds the Early Horn
-- ("Skip Wave At": Off / 50 / 70 / 90 %; the match uses the leader's).
-- Remotes (when Net has them): SetTier(tier), SetSkipWave(pct).
-- Tier names come from Config/Difficulty (Util/LadderModel fallback).

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Remotes = require(Client.Util.Remotes)
local Defs = require(Client.Util.Defs)
local LadderModel = require(Client.Util.LadderModel)
local State = require(Client.Controllers.State)

local LadderUI = {}

local C = Theme.C
local make = Theme.make

local unsubs: { () -> () } = {}
local localTier: number? = nil
local localTierAt = 0
local localSkip: number? = nil
local localPace: string? = nil
local localPaceAt = 0

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function profile(): any
	local p = State.get("profile")
	return if type(p) == "table" then p else {}
end

local function myClass(): string?
	local lobby = State.get("lobby")
	local me = State.localUserId()
	local e = type(lobby) == "table" and type(lobby.players) == "table" and lobby.players[me]
	return if type(e) == "table" and e.classId then tostring(e.classId) else nil
end

local function currentTier(): number
	local server = LadderModel.lobbyTier(State.get("lobby"))
	if localTier and (os.clock() - localTierAt < 2 or server == nil) then
		return localTier
	end
	return server or 2
end

local function canPick(): boolean
	return State.isLeader() and Remotes.C2S.SetTier ~= nil
end

-- iteration 6: the lobby's pace; an optimistic local pick wins for 2 s.
local function currentPace(): string
	local lobby = State.get("lobby")
	local server = LadderModel.lobbyPace(lobby, profile())
	if localPace and os.clock() - localPaceAt < 2 then
		return localPace
	end
	return server
end

local function canPickPace(): boolean
	return State.isLeader() and Remotes.C2S.SetPace ~= nil and not LadderModel.paceLocked(State.get("lobby"))
end

function LadderUI.buildCard(parent: Instance, layoutOrder: number?): Frame
	local touch = Theme.TOUCH
	local card = Theme.card({
		Name = "LadderCard",
		LayoutOrder = layoutOrder or 0,
		Size = UDim2.fromOffset(300, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = parent,
	}, { shadow = false })
	local inner = make("Frame", {
		Name = "Inner",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = card,
	})
	Theme.padding(8, 6).Parent = inner
	Theme.list(Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Left).Parent = inner

	local top = make("Frame", {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, Theme.SLIM),
		BackgroundTransparency = 1,
		Parent = inner,
	})
	local prev = Theme.button("◀", C.creamDark, {
		Size = UDim2.fromOffset(Theme.SLIM, Theme.SLIM),
		TextSize = 16,
		Parent = top,
	})
	local title = Theme.label({
		Position = UDim2.fromOffset(Theme.SLIM + 6, 0),
		Size = UDim2.new(1, -(2 * Theme.SLIM + 12), 1, 0),
		TextSize = 17,
		TextColor3 = C.gold,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = top,
	})
	Theme.textStroke(C.shade, 1.5).Parent = title
	local nextB = Theme.button("▶", C.creamDark, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(Theme.SLIM, Theme.SLIM),
		TextSize = 16,
		Parent = top,
	})
	local info = Theme.label({
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextSize = 12,
		Font = Theme.FONT_BODY,
		TextColor3 = C.cream,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = inner,
	})
	Theme.textStroke(C.shade, 1).Parent = info
	local row = make("Frame", {
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, touch),
		BackgroundTransparency = 1,
		Parent = inner,
	})
	Theme.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left).Parent = row
	local ladderButton = Theme.button("🪜 Ladder", C.cheese, {
		LayoutOrder = 1,
		Size = UDim2.new(0.5, -3, 0, touch),
		TextSize = 15,
		Parent = row,
	})
	local hornButton = Theme.button("📯 Horn: Off", C.creamDark, {
		LayoutOrder = 2,
		Size = UDim2.new(0.5, -3, 0, touch),
		TextSize = 14,
		Parent = row,
	})
	Theme.tooltip(
		hornButton,
		"Early Horn: call the next wave as soon as this much of the current one is stomped. Skipped seconds pay rinds. The match uses the leader's setting."
	)

	-- iteration 6: Pace (Normal / Fast), a two-way switch the leader sets
	local paceRow = make("Frame", {
		Name = "Pace",
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, Theme.SLIM),
		BackgroundTransparency = 1,
		Parent = inner,
	})
	Theme.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent =
		paceRow
	local paceLabel = Theme.label({
		LayoutOrder = 1,
		Size = UDim2.new(0.3, -6, 1, 0),
		TextSize = 14,
		TextColor3 = C.cream,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "⏱ Pace",
		Parent = paceRow,
	})
	Theme.textStroke(C.shade, 1).Parent = paceLabel
	local paceButtons: { [string]: TextButton } = {}
	for i, p in LadderModel.PACES do
		paceButtons[p] = Theme.button(if p == "fast" then "⚡ Fast" else "Normal", C.creamDark, {
			LayoutOrder = 1 + i,
			Size = UDim2.new(0.35, -3, 1, 0),
			TextSize = 14,
			Parent = paceRow,
		})
	end
	Theme.tooltip(paceButtons.fast, function()
		local base =
			"Fast pace: shorter wave timers, more mice per second and a shorter storm, for ×1.15 cheese and class XP. Records still count per tier."
		if LadderModel.paceLocked(State.get("lobby")) then
			return base .. "\nOpens after a few runs: a rookie leader plays Normal."
		elseif not State.isLeader() then
			return base .. "\nThe party leader 👑 picks the pace."
		end
		return base
	end)
	Theme.tooltip(paceButtons.normal, "Normal pace: the standard wave timers.")

	-- full ladder grid (a modal on the lobby screen root)
	local root = parent:FindFirstAncestorWhichIsA("ScreenGui")
	local rootFrame = if root then root:FindFirstChild("Root") else nil
	local grid = Theme.panel({
		Name = "LadderGrid",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(760, 470),
		Visible = false,
		ZIndex = 6,
		Parent = rootFrame or parent,
	})
	Theme.compact(grid)
	local gt = Theme.label({
		Position = UDim2.fromOffset(16, 6),
		Size = UDim2.new(1, -(touch + 40), 0, 36),
		TextSize = 22,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "🪜 The Cheese Ladder",
		ZIndex = 7,
		Parent = grid,
	})
	Theme.header(gt)
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		Size = UDim2.fromOffset(touch, touch),
		TextColor3 = C.white,
		ZIndex = 7,
		Parent = grid,
	}, function()
		grid.Visible = false
	end)
	local tilesTop = math.max(48, touch + 8)
	local tiles = Theme.scroller({
		Position = UDim2.fromOffset(12, tilesTop),
		Size = UDim2.new(1, -24, 1, -(tilesTop + 10)),
		ZIndex = 7,
		Parent = grid,
	})
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(170, 104),
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = tiles,
	})

	local function setTier(t: number)
		local remote = Remotes.C2S.SetTier
		if not remote or not State.isLeader() then
			return
		end
		localTier, localTierAt = t, os.clock()
		Remotes.fire(remote, t)
	end

	local renderGrid: () -> ()
	local function render()
		local cfg = Defs.module("Difficulty")
		local tiles0 = LadderModel.view(cfg, profile(), State.get("lobby"), myClass())
		local unlocked, bestSolo, bestSquad = LadderModel.record(profile(), myClass())
		local t = currentTier()
		-- T-7: tier 0 is Custom (the Pressure board), never "Medium"
		local tier = if t == 0
			then LadderModel.customTile(State.get("lobby"), cfg)
			else (tiles0[t] or tiles0[2] or tiles0[1])
		if tier then
			title.Text = if tier.tier == 0
				then "⚙ " .. tier.name
				else string.format("Tier %d · %s", tier.tier, tier.name)
			title.TextColor3 = rgb(tier.color)
			info.Text = (if tier.tier == 0 then tier.blurb .. "\n" else "")
				.. string.format(
					"Reward ×%s · gems tier %d\nBest Solo: %s · Best Squad: %s%s",
					string.format("%.2f", tier.reward):gsub("%.?0+$", ""),
					tier.gemTier,
					if bestSolo > 0 then LadderModel.name(cfg, bestSolo) else "—",
					if bestSquad > 0 then LadderModel.name(cfg, bestSquad) else "—",
					if canPick()
						then "\n👑 You pick the tier (" .. unlocked .. " unlocked)"
						elseif State.isLeader() then ""
						else "\nThe party leader 👑 picks the tier"
				)
		end
		local pick = canPick()
		prev.Visible = pick
		nextB.Visible = pick
		Theme.setEnabled(prev, pick and t > 1)
		Theme.setEnabled(nextB, pick and t < unlocked and t < #tiles0)
		local skip = localSkip or LadderModel.skipWaveAt(profile())
		hornButton.Text = "📯 Horn: " .. LadderModel.skipLabel(skip)
		Theme.setEnabled(hornButton, Remotes.C2S.SetSkipWave ~= nil)
		local pace = currentPace()
		local pacePick = canPickPace()
		for p, b in paceButtons do
			local on = p == pace
			b.BackgroundColor3 = if on then (if p == "fast" then C.orange else C.cheese) else C.creamDark
			-- non-leaders see the current pace only (read-only)
			Theme.setEnabled(b, on or pacePick)
		end
		if grid.Visible then
			renderGrid()
		end
	end

	renderGrid = function()
		for _, ch in tiles:GetChildren() do
			if ch:IsA("GuiButton") then
				ch:Destroy()
			end
		end
		local cfg = Defs.module("Difficulty")
		local t = currentTier()
		for _, tile in LadderModel.view(cfg, profile(), State.get("lobby"), myClass()) do
			local b = make("TextButton", {
				LayoutOrder = tile.tier,
				BackgroundColor3 = if tile.locked then C.greyDark else rgb(tile.color),
				AutoButtonColor = false,
				Text = "",
				ZIndex = 8,
				Parent = tiles,
			}) :: TextButton
			Theme.corner(10).Parent = b
			Theme.stroke(if tile.tier == t then C.gold else C.brownDark, if tile.tier == t then 4 else 2).Parent =
				b
			Theme.label({
				Position = UDim2.fromOffset(8, 4),
				Size = UDim2.new(1, -16, 0, 26),
				TextSize = 17,
				TextColor3 = C.ink,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = string.format("%s%d · %s", if tile.locked then "🔒 " else "", tile.tier, tile.name),
				ZIndex = 9,
				Parent = b,
			})
			Theme.label({
				Position = UDim2.fromOffset(8, 30),
				Size = UDim2.new(1, -16, 1, -34),
				TextSize = 12,
				Font = Theme.FONT_BODY,
				TextColor3 = C.ink,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				Text = string.format(
					"Reward ×%s · gems %d\n%s%s%s",
					string.format("%.2f", tile.reward):gsub("%.?0+$", ""),
					tile.gemTier,
					tile.blurb,
					if tile.isBestSolo then "\n🏅 Your Best Solo" else "",
					if tile.isBestSquad then "\n👥 Your Best Squad" else ""
				),
				ZIndex = 9,
				Parent = b,
			})
			b.Activated:Connect(function()
				if not tile.locked and canPick() then
					setTier(tile.tier)
					render()
				end
			end)
		end
		-- T-17: the Custom tile (the leader's own Pressure board), after Sharp
		local customOpen = LadderModel.customOpen(profile())
		local cb = make("TextButton", {
			LayoutOrder = 99,
			BackgroundColor3 = if customOpen then Color3.fromRGB(200, 180, 255) else C.greyDark,
			AutoButtonColor = false,
			Text = "",
			ZIndex = 8,
			Parent = tiles,
		}) :: TextButton
		Theme.corner(10).Parent = cb
		Theme.stroke(if t == 0 then C.gold else C.brownDark, if t == 0 then 4 else 2).Parent = cb
		Theme.label({
			Position = UDim2.fromOffset(8, 4),
			Size = UDim2.new(1, -16, 0, 26),
			TextSize = 17,
			TextColor3 = C.ink,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = (if customOpen then "" else "🔒 ") .. "⚙ Custom",
			ZIndex = 9,
			Parent = cb,
		})
		Theme.label({
			Position = UDim2.fromOffset(8, 30),
			Size = UDim2.new(1, -16, 1, -34),
			TextSize = 12,
			Font = Theme.FONT_BODY,
			TextColor3 = C.ink,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Text = if customOpen
				then "Build your own difficulty on the Pressure board."
				else "Clear Sharp to open it.",
			ZIndex = 9,
			Parent = cb,
		})
		cb.Activated:Connect(function()
			if customOpen and canPick() then
				setTier(0)
				render()
			end
		end)
	end

	prev.Activated:Connect(function()
		setTier(currentTier() - 1)
		render()
	end)
	nextB.Activated:Connect(function()
		setTier(currentTier() + 1)
		render()
	end)
	ladderButton.Activated:Connect(function()
		grid.Visible = not grid.Visible
		if grid.Visible then
			Theme.popIn(grid)
			renderGrid()
		end
	end)
	hornButton.Activated:Connect(function()
		local remote = Remotes.C2S.SetSkipWave
		if not remote then
			return
		end
		local nextV = LadderModel.nextSkip(localSkip or LadderModel.skipWaveAt(profile()))
		localSkip = nextV
		Remotes.fire(remote, nextV)
		render()
	end)

	for p, b in paceButtons do
		b.Activated:Connect(function()
			local remote = Remotes.C2S.SetPace
			if not remote or not canPickPace() or currentPace() == p then
				return
			end
			localPace, localPaceAt = p, os.clock()
			Remotes.fire(remote, p)
			render()
		end)
	end

	for _, key in { "lobby", "profile" } do
		table.insert(
			unsubs,
			State.subscribe(key, function()
				if key == "profile" then
					localSkip = nil -- the saved setting wins once it arrives
				end
				render()
			end, key == "lobby")
		)
	end
	return card
end

function LadderUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
end

return LadderUI
