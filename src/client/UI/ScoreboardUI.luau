--!strict
-- Full squad scoreboard (Tab on PC, View/Back on gamepad, tap the HUD strip on
-- touch). Squads are ranked with Util/Scoreboard (eliminated last, then pending
-- cheese, kills, heroes alive); each card lists the members with their class
-- and state when known (PartyHud covers your own squad).
-- Reads State "match", "party", "scoreboardOpen". Rows are pooled (4 cards x 3
-- member lines), never rebuilt.

local GuiService = game:GetService("GuiService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local Scoreboard = require(Client.Util.Scoreboard)
local Device = require(Client.Util.Device)
local State = require(Client.Controllers.State)

local ScoreboardUI = {}

local C = Theme.C
local T = Theme.TYPE
local make = Theme.make

local screen: any = nil
local unsubs: { () -> () } = {}

function ScoreboardUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallScoreboard", 35)
	local root: Frame = screen.root
	local touch = Theme.TOUCH

	local panel = Theme.panel({
		Name = "Board",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(760, 470),
		Visible = false,
		Parent = root,
	})
	table.insert(unsubs, Theme.fitFrame(screen, panel, 760, 470, 10))
	local title = Theme.label({
		Position = UDim2.fromOffset(20, 10),
		Size = UDim2.new(1, -(touch + 40), 0, 36),
		TextSize = T.title,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Squads",
		Parent = panel,
	})
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		Size = UDim2.fromOffset(touch, touch),
		TextColor3 = C.white,
		Parent = panel,
	}, function()
		State.toggleScoreboard(false)
	end)
	local hint = Theme.label({
		Position = UDim2.fromOffset(20, 46),
		Size = UDim2.new(1, -(touch + 40), 0, 18),
		TextSize = T.caption,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = panel,
	})
	local list = Theme.scroller({
		Position = UDim2.fromOffset(12, math.max(70, touch + 12)),
		Size = UDim2.new(1, -24, 1, -(math.max(70, touch + 12) + 10)),
		ScrollBarThickness = 8,
		Parent = panel,
	})
	Theme.padding(4, 4).Parent = list
	Theme.list(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Left).Parent = list

	type Member = { frame: Frame, name: TextLabel, info: TextLabel, dot: Frame }
	type Card = {
		frame: Frame,
		stroke: UIStroke,
		rank: TextLabel,
		band: Frame,
		name: TextLabel,
		stats: TextLabel,
		badge: TextLabel,
		members: { Member },
	}
	local cards: { Card } = {}
	for i = 1, 4 do
		local f = Theme.card({
			LayoutOrder = i,
			Size = UDim2.new(1, -8, 0, 92),
			Parent = list,
		}, { shadow = false, accent = C.rindLight })
		local stroke = f:FindFirstChildOfClass("UIStroke") :: UIStroke
		local band = make("Frame", {
			Size = UDim2.new(0, 8, 1, 0),
			BackgroundColor3 = C.cheese,
			BorderSizePixel = 0,
			Parent = f,
		}) :: Frame
		Theme.corner(6).Parent = band
		local rank = Theme.label({
			Position = UDim2.fromOffset(16, 0),
			Size = UDim2.fromOffset(52, 92),
			TextSize = T.title,
			TextColor3 = C.gold,
			Text = "1st",
			Parent = f,
		})
		Theme.textStroke(C.shade, 1.5).Parent = rank
		local name = Theme.label({
			Position = UDim2.fromOffset(74, 6),
			Size = UDim2.new(0.5, -74, 0, 26),
			TextSize = T.heading,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Parent = f,
		})
		Theme.textStroke(C.shade, 1.5).Parent = name
		local stats = Theme.label({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -12, 0, 8),
			Size = UDim2.new(0.5, -12, 0, 22),
			TextSize = T.body,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextWrapped = false,
			Parent = f,
		})
		Theme.textStroke(C.shade, 1).Parent = stats
		local badge = Theme.badge("", C.green, {
			Position = UDim2.fromOffset(74, 34),
			Visible = false,
			Parent = f,
		})
		local memberRow = make("Frame", {
			Position = UDim2.fromOffset(74, 56),
			Size = UDim2.new(1, -86, 0, 30),
			BackgroundTransparency = 1,
			Parent = f,
		})
		Theme.list(
			Enum.FillDirection.Horizontal,
			8,
			Enum.HorizontalAlignment.Left,
			Enum.VerticalAlignment.Center
		).Parent =
			memberRow
		local members: { Member } = {}
		for m = 1, 3 do
			local mf = make("Frame", {
				LayoutOrder = m,
				Size = UDim2.new(1 / 3, -6, 1, 0),
				BackgroundColor3 = C.rindLight,
				BackgroundTransparency = 0.3,
				Parent = memberRow,
			}) :: Frame
			Theme.corner(8).Parent = mf
			local dot = make("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 6, 0.5, 0),
				Size = UDim2.fromOffset(10, 10),
				BackgroundColor3 = C.green,
				Parent = mf,
			}) :: Frame
			Theme.round().Parent = dot
			local mn = Theme.label({
				Position = UDim2.fromOffset(20, 0),
				Size = UDim2.new(0.6, -20, 1, 0),
				TextSize = T.caption,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextWrapped = false,
				Parent = mf,
			})
			local info = Theme.label({
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -6, 0, 0),
				Size = UDim2.new(0.4, -6, 1, 0),
				TextSize = T.micro,
				Font = Theme.FONT_BODY,
				TextColor3 = C.textDim,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextWrapped = false,
				Parent = mf,
			})
			members[m] = { frame = mf, name = mn, info = info, dot = dot }
		end
		cards[i] = {
			frame = f,
			stroke = stroke,
			rank = rank,
			band = band,
			name = name,
			stats = stats,
			badge = badge,
			members = members,
		}
	end

	local function render()
		local open = State.get("scoreboardOpen") == true
		local match = State.get("match")
		local squads = if type(match) == "table" then match.squads else nil
		if not open or type(squads) ~= "table" or #squads == 0 then
			if
				panel.Visible
				and GuiService.SelectedObject
				and GuiService.SelectedObject:IsDescendantOf(panel)
			then
				GuiService.SelectedObject = nil
			end
			panel.Visible = false
			return
		end
		local wasVisible = panel.Visible
		panel.Visible = true
		if not wasVisible then
			Theme.popIn(panel)
		end
		title.Text = string.format("Squads · Stage %s/4", tostring(match.stage or "?"))
		hint.Text = if Device.mode() == "touch"
			then "Ranked by squad pot, then kills. Tap ✕ to close."
			elseif Device.mode() == "gamepad" then "Ranked by squad pot, then kills. Back / View closes."
			else "Ranked by squad pot, then kills. Tab closes."
		local party = State.get("party")
		local sorted = Scoreboard.sort(squads)
		for i, card in cards do
			local s = sorted[i]
			card.frame.Visible = s ~= nil
			if s then
				local col = Color3.fromRGB(s.color[1], s.color[2], s.color[3])
				card.band.BackgroundColor3 = col
				card.rank.Text = Scoreboard.ordinal(i)
				card.rank.TextColor3 = if i == 1 then C.gold else C.cream
				card.name.Text = s.name .. (if s.isYou then "  (you)" else "")
				card.name.TextColor3 = col:Lerp(C.white, 0.3)
				card.stats.Text = string.format(
					"🧀 %s   ☠ %d   ♥ %d/%d",
					Format.int(s.pending),
					s.kills,
					s.alive,
					math.max(#s.members, 3)
				)
				card.stroke.Color = if s.isYou then C.gold else C.rindLight
				card.stroke.Thickness = if s.isYou then 3 else 2
				card.badge.Visible = s.extracted or s.eliminated or s.doubleOrNothing
				if s.eliminated then
					card.badge.Text = "ELIMINATED"
					card.badge.BackgroundColor3 = C.red
				elseif s.extracted then
					card.badge.Text = "EXTRACTED"
					card.badge.BackgroundColor3 = C.greenDark
				else
					card.badge.Text = "DOUBLE OR NOTHING"
					card.badge.BackgroundColor3 = C.orange
				end
				for m, row in card.members do
					local id = s.members[m]
					row.frame.Visible = id ~= nil
					if id then
						local e = if type(party) == "table" then party[id] else nil
						local bot = State.isBot(id, e)
						row.name.Text = (if bot and type(e) == "table" then "🤖 " else "")
							.. State.nameOf(id)
						row.name.TextColor3 = if id == State.localUserId() then C.gold else C.cream
						local classDef = if type(e) == "table" then Defs.get("Classes", e.classId) else nil
						local stateText, dotColor = "", C.green
						if s.eliminated or (type(e) == "table" and e.dead == true and not s.extracted) then
							stateText, dotColor = "out", C.grey
						elseif s.extracted then
							stateText, dotColor = "safe", Color3.fromRGB(160, 120, 255)
						elseif type(e) == "table" and e.downed == true then
							stateText, dotColor = "down", C.red
						end
						row.info.Text = if classDef
							then Defs.name(classDef, e.classId) .. (if stateText ~= ""
								then " · " .. stateText
								else "")
							else stateText
						row.dot.BackgroundColor3 = dotColor
					end
				end
			end
		end
	end

	table.insert(unsubs, State.subscribe("scoreboardOpen", render, true))
	table.insert(unsubs, State.subscribe("match", render))
	table.insert(
		unsubs,
		State.subscribe("party", function()
			if panel.Visible then
				render()
			end
		end)
	)
end

function ScoreboardUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	if screen then
		screen.destroy()
		screen = nil
	end
end

return ScoreboardUI
