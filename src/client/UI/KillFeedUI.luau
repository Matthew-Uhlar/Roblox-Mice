--!strict
-- Kill feed (top-right, under the minimap): at most 4 short rows (v3).
-- Reads State "killfeed" (Net.S2C.KillFeed entries {killer, victim,
-- killerSquad, victimSquad, kind}); names are resolved by State.nameOf and
-- coloured by squad. Rows are pooled (ROWS frames, reused newest-first), slide
-- in from the right and slide out after SHOW_SECONDS.
--
-- kind: "kill" (skull), "down" (bolt), "eliminated" (squad wiped, cross),
-- "extracted" (portal), "boss" (crown), "bounty" (target), v3 "champion"
-- ("<killer> slew <Champion>" with a gold LAIR badge for lair champions; names
-- from Config/Champions.defs); others read as a kill.

local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local State = require(Client.Controllers.State)
local ChampView = require(Client.Util.ChampView)

local ChampDefs: any = nil
do
	local ok, mod = pcall(function()
		return require(
			game:GetService("ReplicatedStorage")
				:WaitForChild("Shared")
				:WaitForChild("Config")
				:WaitForChild("Champions") :: any
		)
	end)
	ChampDefs = if ok then mod else nil
end

local KillFeedUI = {}

local C = Theme.C
local make = Theme.make

local SHOW_SECONDS = 6

local KIND_ICON: { [string]: { string } } = {
	kill = { "skull", "white" },
	killed = { "skull", "white" },
	down = { "bolt", "gold" },
	downed = { "bolt", "gold" },
	eliminated = { "cross", "red" },
	extracted = { "portal", "purple" },
	extract = { "portal", "purple" },
	boss = { "crown", "gold" },
	champion = { "star", "gold" },
	bounty = { "target", "red" },
	bountyClaimed = { "target", "gold" },
}

local function iconColor(key: string): Color3
	if key == "gold" then
		return C.gold
	elseif key == "red" then
		return C.red
	elseif key == "purple" then
		return Color3.fromRGB(160, 120, 255)
	end
	return C.cream
end

export type Handle = { frame: Frame, destroy: () -> () }

-- `z` = Util/UiSizes.hud(...) (killRows, killW, killH, killGap, killText,
-- killNameMax, killIcon, margin); nil uses the phone sizes.
function KillFeedUI.build(parent: Instance, top: number, z: any?): Handle
	local unsubs: { () -> () } = {}
	local conns: { RBXScriptConnection } = {}
	local Z = z
		or {
			killRows = 4,
			killW = 280,
			killH = 28,
			killGap = 4,
			killText = 15,
			killNameMax = 116,
			killIcon = 18,
			margin = 14,
		}
	local ROWS, ROW_W, ROW_H = Z.killRows, Z.killW, Z.killH

	local list = make("Frame", {
		Name = "KillFeed",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -Z.margin, 0, top),
		Size = UDim2.fromOffset(ROW_W, ROWS * (ROW_H + Z.killGap)),
		BackgroundTransparency = 1,
		Parent = parent,
	}) :: Frame
	Theme.list(Enum.FillDirection.Vertical, Z.killGap, Enum.HorizontalAlignment.Right).Parent = list

	type Row = {
		holder: Frame,
		content: Frame,
		stroke: UIStroke,
		left: TextLabel,
		right: TextLabel,
		rightMax: UISizeConstraint,
		leftMax: UISizeConstraint,
		badge: TextLabel,
		icons: { [string]: Frame },
		seq: number,
		shownAt: number,
		leaving: boolean,
	}
	local rows: { Row } = {}

	local function newRow(i: number): Row
		local holder = make("Frame", {
			Name = "Row" .. i,
			LayoutOrder = i,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(ROW_W, ROW_H),
			Visible = false,
			Parent = list,
		}) :: Frame
		local content = Theme.card({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 0.25,
			Parent = holder,
		}, { shadow = false, accent = C.rindLight, stroke = 1.5 })
		local stroke = content:FindFirstChildOfClass("UIStroke") :: UIStroke
		Theme.padding(if ROW_H < 26 then 6 else 8, 0).Parent = content
		local row = make("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Parent = content,
		})
		Theme.list(
			Enum.FillDirection.Horizontal,
			6,
			Enum.HorizontalAlignment.Right,
			Enum.VerticalAlignment.Center
		).Parent =
			row
		local function name(order: number): (TextLabel, UISizeConstraint)
			local l = Theme.label({
				LayoutOrder = order,
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromOffset(0, ROW_H - 4),
				TextSize = Z.killText,
				TextWrapped = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = row,
			})
			local sc = make("UISizeConstraint", { MaxSize = Vector2.new(Z.killNameMax, 40), Parent = l })
			Theme.textStroke(C.shade, 1.5).Parent = l
			return l, sc
		end
		local left, leftMax = name(1)
		local iconBox = make("Frame", {
			LayoutOrder = 2,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(Z.killIcon, Z.killIcon),
			Parent = row,
		})
		local icons: { [string]: Frame } = {}
		for _, spec in KIND_ICON do
			local kind = spec[1]
			if not icons[kind] then
				icons[kind] =
					Theme.icon(kind, Z.killIcon, iconColor(spec[2]), { Visible = false, Parent = iconBox })
			end
		end
		local right, rightMax = name(3)
		local badge = Theme.label({
			LayoutOrder = 4,
			Size = UDim2.fromOffset(math.floor(Z.killText * 2.6), ROW_H - 8),
			BackgroundColor3 = C.goldDeep,
			BackgroundTransparency = 0,
			TextSize = math.max(10, Z.killText - 3),
			TextColor3 = C.white,
			Text = "LAIR",
			Visible = false,
			Parent = row,
		})
		Theme.corner(4).Parent = badge
		Theme.stroke(C.goldLight, 1).Parent = badge
		return {
			holder = holder,
			content = content,
			stroke = stroke,
			left = left,
			right = right,
			rightMax = rightMax,
			leftMax = leftMax,
			badge = badge,
			icons = icons,
			seq = -1,
			shownAt = 0,
			leaving = false,
		}
	end
	for i = 1, ROWS do
		rows[i] = newRow(i)
	end

	local function squadText(sq: number?): (string, Color3)
		local s = State.squad(sq)
		if s then
			return s.name, Color3.fromRGB(s.color[1], s.color[2], s.color[3])
		end
		return Theme.squad(sq)
	end

	local function nameColor(sq: number?): Color3
		if sq == nil then
			return C.cream
		end
		local _, col = squadText(sq)
		return col
	end

	local function fill(row: Row, e: any)
		local kind = tostring(e.kind)
		local spec = KIND_ICON[kind] or KIND_ICON.kill
		for k, ic in row.icons do
			ic.Visible = k == spec[1]
		end
		local me = State.localUserId()
		local killerIsMe = tonumber(e.killer) == me
		local victimIsMe = tonumber(e.victim) == me
		row.badge.Visible = false
		row.leftMax.MaxSize = Vector2.new(Z.killNameMax, 40)
		row.rightMax.MaxSize = Vector2.new(Z.killNameMax, 40)
		if kind == "champion" then
			local text, lair = ChampView.feedText(ChampDefs, e)
			row.left.Text = if e.killer ~= nil then State.nameOf(e.killer) else squadText(e.killerSquad)
			row.left.TextColor3 = nameColor(e.killerSquad)
			row.right.Text = text
			row.right.TextColor3 = C.gold
			row.badge.Visible = lair
			-- the champion's name gets the room: killer names stay short
			local leftW = math.floor(Z.killNameMax * 0.7)
			local rest = ROW_W - leftW - Z.killIcon - 18 - 16 - (if lair then Z.killText * 2.6 + 6 else 0)
			row.leftMax.MaxSize = Vector2.new(leftW, 40)
			row.rightMax.MaxSize = Vector2.new(math.max(Z.killNameMax, rest), 40)
		elseif kind == "eliminated" or kind == "extracted" or kind == "extract" then
			local sq = e.victimSquad or e.killerSquad
			local name, col = squadText(sq)
			row.left.Text = name
			row.left.TextColor3 = col
			row.right.Text = if kind == "eliminated" then "ELIMINATED" else "EXTRACTED"
			row.right.TextColor3 = if kind == "eliminated" then C.red else Color3.fromRGB(180, 150, 255)
		elseif kind == "boss" then
			row.left.Text = if e.killer ~= nil then State.nameOf(e.killer) else squadText(e.killerSquad)
			row.left.TextColor3 = nameColor(e.killerSquad)
			row.right.Text = if e.victim ~= nil then tostring(e.victim) else "the boss"
			row.right.TextColor3 = C.gold
		elseif kind == "bounty" then
			row.left.Text = "BOUNTY"
			row.left.TextColor3 = C.red
			row.right.Text = State.nameOf(e.victim or e.killer)
			row.right.TextColor3 = nameColor(e.victimSquad or e.killerSquad)
		else
			row.left.Text = if e.killer ~= nil then State.nameOf(e.killer) else "The horde"
			row.left.TextColor3 = if e.killer ~= nil then nameColor(e.killerSquad) else C.textDim
			row.right.Text = State.nameOf(e.victim)
			row.right.TextColor3 = nameColor(e.victimSquad)
		end
		row.stroke.Color = if killerIsMe then C.gold elseif victimIsMe then C.red else C.rindLight
		row.stroke.Thickness = if killerIsMe or victimIsMe then 2.5 else 1.5
	end

	local lastSeq = 0
	local function render(kf: any)
		if type(kf) ~= "table" or type(kf.entries) ~= "table" then
			return
		end
		local entries = kf.entries
		if #entries == 0 then
			for _, r in rows do
				r.holder.Visible = false
				r.seq = -1
			end
			lastSeq = 0
			return
		end
		local now = os.clock()
		-- Newest first: row 1 shows the newest entry.
		for i = 1, ROWS do
			local e = entries[#entries - i + 1]
			local row = rows[i]
			if e and now - e.at < SHOW_SECONDS then
				if row.seq ~= e.seq then
					row.seq = e.seq
					row.shownAt = e.at
					row.leaving = false
					fill(row, e)
					row.holder.Visible = true
					row.content.Position = UDim2.fromScale(1, 0)
					if e.seq > lastSeq and i == 1 then
						Theme.slideIn(row.content, 80, 0, 0.2)
					end
				end
			else
				row.holder.Visible = false
				row.seq = -1
			end
		end
		lastSeq = math.max(lastSeq, entries[#entries].seq)
	end
	table.insert(unsubs, State.subscribe("killfeed", render, true))

	-- Expire rows (slide out to the right, then hide).
	table.insert(
		conns,
		RunService.Heartbeat:Connect(function()
			local now = os.clock()
			for _, r in rows do
				if r.holder.Visible and not r.leaving and now - r.shownAt >= SHOW_SECONDS then
					r.leaving = true
					local tw = Theme.tween(r.content, 0.25, { Position = UDim2.new(1, ROW_W + 20, 0, 0) })
					local seq = r.seq
					tw.Completed:Connect(function()
						if r.seq == seq then
							r.holder.Visible = false
							r.seq = -1
						end
					end)
				end
			end
		end)
	)

	list.Visible = true
	local function visibility(run: any)
		local phase = if type(run) == "table" then run.phase else nil
		list.Visible = phase ~= nil and phase ~= "Lobby" and phase ~= "Results"
	end
	table.insert(unsubs, State.subscribe("run", visibility, true))

	return {
		frame = list,
		destroy = function()
			for _, u in unsubs do
				u()
			end
			for _, c in conns do
				c:Disconnect()
			end
			list:Destroy()
		end,
	}
end

return KillFeedUI
