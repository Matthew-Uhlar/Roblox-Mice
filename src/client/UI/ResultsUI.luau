--!strict
-- End-of-run screen (Net.S2C.Results -> State "results"): outcome, cheese
-- earned (with the multiplier if provided), xp, cycle/stage reached, bosses
-- killed and duration. "Play Again" closes it; the lobby takes over.

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Format = require(Client.Util.Format)
local State = require(Client.Controllers.State)

local ResultsUI = {}

local C = Theme.C
local make = Theme.make

local screen: any = nil
local unsub: (() -> ())? = nil

function ResultsUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallResults", 50)
	local root: Frame = screen.root
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
	Theme.padding(20, 16).Parent = panel
	Theme.list(Enum.FillDirection.Vertical, 8).Parent = panel

	local title = Theme.label({
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 56),
		TextSize = 46,
		TextColor3 = C.cheese,
		Parent = panel,
	})
	Theme.textStroke(C.brownDark, 3).Parent = title
	local subtitle = Theme.label({
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 26),
		TextSize = 18,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		Parent = panel,
	})
	local cheeseBig = Theme.label({
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, 52),
		TextSize = 42,
		TextColor3 = C.ink,
		Parent = panel,
	})
	local multLine = Theme.label({
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, 24),
		TextSize = 18,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		Parent = panel,
	})
	local stats = make("Frame", {
		LayoutOrder = 5,
		BackgroundColor3 = C.creamDark,
		Size = UDim2.new(1, 0, 0, 170),
		Parent = panel,
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
			Parent = stats,
		})
	end
	local button = Theme.button("🐘 Play Again", C.green, {
		LayoutOrder = 6,
		Size = UDim2.fromOffset(300, Theme.TOUCH + 6),
		TextSize = 30,
		TextColor3 = C.white,
		Parent = panel,
	}, function()
		State.set("results", nil)
	end)
	Theme.textStroke(C.brownDark, 2).Parent = button

	local function render(r: any)
		if type(r) ~= "table" then
			shade.Visible = false
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
		statLabels[2].Text =
			string.format("🗺 Cycle %d · Stage %d", tonumber(r.cycle) or 1, tonumber(r.stage) or 1)
		statLabels[3].Text = "👑 Bosses: " .. Format.int(r.bossesKilled)
		statLabels[4].Text = "⏱ " .. Format.clock(r.duration)
		shade.Visible = true
		Theme.popIn(panel)
	end

	unsub = State.subscribe("results", render, true)
end

function ResultsUI.destroy()
	if unsub then
		unsub()
		unsub = nil
	end
	if screen then
		screen.destroy()
		screen = nil
	end
end

return ResultsUI
