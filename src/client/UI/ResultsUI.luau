--!strict
-- End-of-run screen (Net.S2C.Results -> State "results"): outcome, cheese
-- earned (with the multiplier if provided), xp, cycle/stage reached, bosses
-- killed and duration.
--
-- "Play Again" sends SetReady(true): during Results the server treats that as
-- "play again" and brings the player back to the lobby already readied (and
-- in the lobby it simply readies them). "Lobby" only closes the panel.
-- The panel is capped to the screen; its stats scroll and the buttons stay
-- pinned at the bottom, so they are never clipped on small phones.

local GuiService = game:GetService("GuiService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Format = require(Client.Util.Format)
local Remotes = require(Client.Util.Remotes)
local Device = require(Client.Util.Device)
local State = require(Client.Controllers.State)

local ResultsUI = {}

local C = Theme.C
local make = Theme.make

local screen: any = nil
local unsubs: { () -> () } = {}

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
		Size = UDim2.fromOffset(560, 500),
		Parent = shade,
	})
	local footerH = touch + 18
	table.insert(unsubs, Theme.fitFrame(screen, panel, 560, 330 + footerH, 10))

	local content = Theme.scroller({
		Position = UDim2.fromOffset(0, 8),
		Size = UDim2.new(1, 0, 1, -(footerH + 8)),
		Parent = panel,
	})
	Theme.padding(20, 8).Parent = content
	Theme.list(Enum.FillDirection.Vertical, 8).Parent = content

	local title = Theme.label({
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 56),
		TextSize = 46,
		TextColor3 = C.cheese,
		Parent = content,
	})
	Theme.textStroke(C.brownDark, 3).Parent = title
	local subtitle = Theme.label({
		LayoutOrder = 2,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 26),
		TextSize = 18,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		Parent = content,
	})
	local cheeseBig = Theme.label({
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, 52),
		TextSize = 42,
		TextColor3 = C.ink,
		Parent = content,
	})
	local multLine = Theme.label({
		LayoutOrder = 4,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 24),
		TextSize = 18,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		Parent = content,
	})
	local stats = make("Frame", {
		LayoutOrder = 5,
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
	Theme.list(Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent =
		footer
	local function close()
		State.set("results", nil)
	end
	local playAgain = Theme.button("🐘 Play Again", C.green, {
		LayoutOrder = 1,
		Size = UDim2.new(0.62, -6, 0, touch + 6),
		TextSize = 30,
		TextColor3 = C.white,
		Parent = footer,
	}, function()
		Remotes.fire(Remotes.C2S.SetReady, true)
		close()
	end)
	Theme.textStroke(C.brownDark, 2).Parent = playAgain
	Theme.button("Lobby", C.creamDark, {
		LayoutOrder = 2,
		Size = UDim2.new(0.38, -6, 0, touch + 6),
		TextSize = 24,
		Parent = footer,
	}, close)

	local function render(r: any)
		if type(r) ~= "table" then
			shade.Visible = false
			if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(shade) then
				GuiService.SelectedObject = nil
			end
			return
		end
		local win = r.outcome == "Win"
		title.Text = if win then "🏆 VICTORY!" else "💥 WIPED OUT"
		title.TextColor3 = if win then C.cheese else C.red
		subtitle.Text = if win
			then "The herd made it home with the cheese!"
			else "The mice win this round… you kept your banked cheese."
		cheeseBig.Text = "🧀 +" .. Format.int(r.cheeseEarned)
		local mult = tonumber(r.cheeseMult)
		local parts = {}
		if mult and math.abs(mult - 1) > 0.001 then
			table.insert(parts, "Cheese bonus " .. Format.mult(mult) .. " (boosts / passes / talents)")
		end
		-- Optional itemised breakdown: { {label=, mult=} } or { [label] = mult }.
		if type(r.breakdown) == "table" then
			for k, v in r.breakdown do
				if type(v) == "table" then
					table.insert(parts, tostring(v.label or k) .. " " .. Format.mult(v.mult or v.value))
				elseif tonumber(v) then
					table.insert(parts, tostring(k) .. " " .. Format.mult(tonumber(v)))
				end
			end
		end
		multLine.Text = table.concat(parts, " · ")
		multLine.Visible = #parts > 0
		statLabels[1].Text = "⭐ XP +" .. Format.int(r.xpEarned)
		statLabels[2].Text = string.format("🗺 Cycle %d · Stage %d", tonumber(r.cycle) or 1, tonumber(r.stage) or 1)
		statLabels[3].Text = "👑 Bosses: " .. Format.int(r.bossesKilled)
		statLabels[4].Text = "⏱ " .. Format.clock(r.duration)
		content.CanvasPosition = Vector2.zero
		shade.Visible = true
		Theme.popIn(panel)
		if Device.mode() == "gamepad" then
			GuiService.SelectedObject = playAgain
		end
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
