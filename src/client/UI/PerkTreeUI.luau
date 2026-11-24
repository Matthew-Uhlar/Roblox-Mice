--!strict
-- Talent Tree screen (iteration 6, team Talents; replaces the 3 x 5 perk ladder view).
-- 3 branches side by side, each 5 rows x 3 columns (Config/ClassPerks, Util/TalentTree):
--   * nodes: round stat nodes with a rank pip "r/max", choice pairs (row 3, "OR" between
--     them), a big diamond KEYSTONE at the bottom with a gold frame;
--   * states: maxed (gold), partial / available (pulsing gold ring), locked (dark, why in
--     the tooltip: row gate, requirement, the other choice, points), capped;
--   * connecting lines between linked nodes (gold when both ends are learned);
--   * branch headers with points spent and the next row gate;
--   * hover / long-press tooltips with the exact numbers (per rank) and the state;
--   * header: free points counter, Respec (two taps: "Pay 🧀 N" or "Use token", a token
--     is only spent when that button is pressed, QC-A minor 4 / QC-B V2-m5), Zoom.
-- The tree sits in a ScrollingFrame (both axes) with a zoom toggle, so a 667x375 phone
-- scrolls it at full size or sees it whole at 0.6x.
-- Sends Net.C2S.SelectPerk(classId, nodeId) (one rank per tap) and
-- Net.C2S.ResetPerks(classId, "cheese" | "token"). Opened from the lobby / hero screen:
-- PerkTreeUI.open(classId).

local GuiService = game:GetService("GuiService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local ClassInfo = require(script.Parent.ClassInfo)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local TalentTree = require(Client.Util.TalentTree)
local Device = require(Client.Util.Device)
local Remotes = require(Client.Util.Remotes)
local State = require(Client.Controllers.State)

local PerkTreeUI = {}

local C = Theme.C
local T = Theme.TYPE
local make = Theme.make

local BRANCH_COLORS = {
	Color3.fromRGB(235, 96, 70),
	Color3.fromRGB(80, 160, 240),
	Color3.fromRGB(110, 200, 100),
}
local PW, PH = 900, 600

local screen: any = nil
local unsubs: { () -> () } = {}
local classId: string? = nil
local optimistic: { [string]: number } = {} -- rank key -> os.clock() of the SelectPerk
local respecArmedAt = 0
local zoomed = false

local panel: Frame? = nil
local render: () -> () = function() end

function PerkTreeUI.isOpen(): boolean
	return panel ~= nil and (panel :: Frame).Visible
end

function PerkTreeUI.close()
	local p = panel
	if p then
		if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(p) then
			GuiService.SelectedObject = nil
		end
		p.Visible = false
	end
end

function PerkTreeUI.open(id: string)
	if not screen then
		PerkTreeUI.init()
	end
	local changed = classId ~= id
	classId = id
	respecArmedAt = 0
	local p = panel :: Frame
	p.Visible = true
	Theme.popIn(p)
	if changed then
		table.clear(optimistic)
	end
	render()
end

local function perksModule(): any
	return Defs.module("ClassPerks")
end

function PerkTreeUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallPerks", 25)
	local root: Frame = screen.root
	local touch = Theme.TOUCH
	local head = math.max(64, touch + 10)
	local phone = Device.mode() == "touch"
	zoomed = phone -- phones start zoomed out (the whole tree in view)

	local p = Theme.panel({
		Name = "PerkTree",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(PW, PH),
		Visible = false,
		Parent = root,
	})
	panel = p
	p:GetPropertyChangedSignal("Visible"):Connect(function()
		State.setBusy("perks", p.Visible)
	end)
	table.insert(unsubs, Theme.fitFrame(screen, p, PW, PH, 8))
	Theme.compact(p)

	Theme.icon("tree", 40, C.green, { Position = UDim2.fromOffset(16, 10), Parent = p })
	local title = Theme.label({
		Position = UDim2.fromOffset(64, 6),
		Size = UDim2.new(1, -(touch + 420), 0, 34),
		TextSize = T.title,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = p,
	})
	local sub = Theme.label({
		Position = UDim2.fromOffset(64, 40),
		Size = UDim2.new(1, -(touch + 420), 0, 20),
		TextSize = T.caption,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = p,
	})
	local pointsBadge = Theme.badge("0 POINTS", C.green, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(touch + 214), 0, 14),
		Size = UDim2.fromOffset(0, 30),
		TextSize = T.body,
		Parent = p,
	})
	local zoomBtn = Theme.button("🔍", C.creamDark, {
		Name = "Zoom",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(touch + 214 + 150), 0, 6),
		Size = UDim2.fromOffset(touch, touch),
		TextSize = T.body,
		Parent = p,
	})
	Theme.tooltip(zoomBtn, "Zoom the tree in or out (drag or scroll to move around).")
	local respec = Theme.button("Respec", C.creamDark, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(touch + 20), 0, 6),
		Size = UDim2.fromOffset(186, touch),
		TextSize = T.body,
		Parent = p,
	})
	Theme.tooltip(
		respec,
		"Refund every talent point of this class. Costs cheese (never Robux) or, only if you pick it, a respec token."
	)
	local respecToken = Theme.button("Use token", C.purple, {
		Name = "RespecToken",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(touch + 214), 0, 6),
		Size = UDim2.fromOffset(160, touch),
		TextSize = T.body,
		TextColor3 = C.white,
		Visible = false,
		Parent = p,
	})
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		Size = UDim2.fromOffset(touch, touch),
		TextColor3 = C.white,
		Parent = p,
	}, PerkTreeUI.close)

	local frame = make("Frame", {
		Name = "TreeFrame",
		Position = UDim2.fromOffset(16, head + 4),
		Size = UDim2.new(1, -32, 1, -(head + 40)),
		BackgroundColor3 = C.rind,
		BackgroundTransparency = 0.05,
		ClipsDescendants = true,
		Parent = p,
	}) :: Frame
	Theme.corner(14).Parent = frame
	Theme.gradient(frame, Color3.fromRGB(255, 240, 220), Color3.fromRGB(150, 130, 110))
	Theme.goldStroke(2).Parent = frame
	local L = TalentTree.layout()
	local scroll = Theme.scroller({
		Name = "Scroll",
		Size = UDim2.fromScale(1, 1),
		ScrollingDirection = Enum.ScrollingDirection.XY,
		AutomaticCanvasSize = Enum.AutomaticSize.None,
		CanvasSize = UDim2.fromOffset(L.w, L.h),
		HorizontalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		ScrollBarThickness = if phone then 6 else 10,
		Parent = frame,
	})
	local canvas = make("Frame", {
		Name = "Canvas",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(L.w, L.h),
		Parent = scroll,
	}) :: Frame
	local zoomScale = make("UIScale", { Name = "Zoom", Parent = canvas }) :: UIScale
	local function applyZoom()
		local fit = 0.6
		local avail = frame.AbsoluteSize
		local s = Theme.scaleOf(frame)
		if avail.X > 10 and s > 0 then
			fit = math.clamp(math.min(avail.X / s / L.w, avail.Y / s / L.h), 0.45, 1)
		end
		local z = if zoomed then fit else 1
		zoomScale.Scale = z
		scroll.CanvasSize = UDim2.fromOffset(L.w * z, L.h * z)
	end
	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyZoom)
	zoomBtn.Activated:Connect(function()
		zoomed = not zoomed
		applyZoom()
	end)

	local footer = Theme.label({
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 20, 1, -8),
		Size = UDim2.new(1, -40, 0, 22),
		TextSize = T.caption,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Text = "",
		Parent = p,
	})

	type NodeUi = {
		button: TextButton,
		stroke: UIStroke,
		rank: TextLabel,
		name: TextLabel,
		icon: TextLabel,
		pulse: Tween?,
		id: string,
		bi: number,
	}
	type LinkUi = { frame: Frame, from: string, to: string, bi: number }
	local nodes: { [string]: NodeUi } = {}
	local links: { LinkUi } = {}
	local headers: { [number]: { name: TextLabel, info: TextLabel } } = {}
	local builtFor: string? = nil
	local model: TalentTree.Model = TalentTree.model(nil, "", {}, 0)

	local function takenSet(): { [string]: boolean }
		local id = classId
		local st = if id then State.classState(id) else nil
		local set: { [string]: boolean } = if st and type(st.perks) == "table"
			then table.clone(st.perks)
			else {}
		local now = os.clock()
		for key, at in optimistic do
			if set[key] or now - at > 3 then
				optimistic[key] = nil
			else
				set[key] = true
			end
		end
		return set
	end

	local function freeNow(): number
		local id = classId
		if not id then
			return 0
		end
		local pr = ClassInfo.progress(id)
		local n = 0
		for _ in optimistic do
			n += 1
		end
		return math.max(0, pr.free - n)
	end

	local KIND_ICON = { stat = "", minor = "✦", choice = "⚖", keystone = "★" }

	local function line(x1: number, y1: number, x2: number, y2: number): Frame
		local dx, dy = x2 - x1, y2 - y1
		local len = math.sqrt(dx * dx + dy * dy)
		local f = make("Frame", {
			Name = "Link",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2),
			Size = UDim2.fromOffset(len, 5),
			Rotation = math.deg(math.atan2(dy, dx)),
			BackgroundColor3 = C.greyDark,
			BorderSizePixel = 0,
			ZIndex = 2,
			Parent = canvas,
		}) :: Frame
		Theme.corner(3).Parent = f
		return f
	end

	local function build()
		for _, ch in canvas:GetChildren() do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		table.clear(nodes)
		table.clear(links)
		table.clear(headers)
		for bi, bv in model.branches do
			local color = BRANCH_COLORS[bi] or C.gold
			local x0 = TalentTree.pos(bi, 1, 1) - TalentTree.COL_W / 2
			local band = make("Frame", {
				Name = "Band" .. bi,
				Position = UDim2.fromOffset(x0 - 6, 4),
				Size = UDim2.fromOffset(L.branchW + 12, L.h - 8),
				BackgroundColor3 = color,
				BackgroundTransparency = 0.88,
				ZIndex = 1,
				Parent = canvas,
			}) :: Frame
			Theme.corner(12).Parent = band
			local hn = Theme.label({
				Position = UDim2.fromOffset(x0, 6),
				Size = UDim2.fromOffset(L.branchW, 24),
				TextSize = T.heading,
				TextColor3 = color,
				Text = string.upper(bv.def.name),
				ZIndex = 3,
				Parent = canvas,
			})
			Theme.textStroke(C.shade, 1.5).Parent = hn
			local hi = Theme.label({
				Position = UDim2.fromOffset(x0, 30),
				Size = UDim2.fromOffset(L.branchW, 18),
				TextSize = T.micro,
				TextColor3 = C.cream,
				Text = "",
				ZIndex = 3,
				Parent = canvas,
			})
			Theme.textStroke(C.shade, 1).Parent = hi
			headers[bi] = { name = hn, info = hi }
			Theme.tooltip(hn, function()
				return string.format("<b>%s</b>\n%s", bv.def.name, bv.def.theme or "")
			end)
			-- links first (under the nodes)
			for _, nv in bv.nodes do
				local d = nv.def
				for _, rid in d.requires or {} do
					local o = bv.byId[rid]
					if o then
						local x1, y1 = TalentTree.pos(bi, o.def.tier, o.def.col)
						local x2, y2 = TalentTree.pos(bi, d.tier, d.col)
						table.insert(links, { frame = line(x1, y1, x2, y2), from = rid, to = d.id, bi = bi })
					end
				end
			end
			-- "OR" between the two choices
			do
				local x1, y = TalentTree.pos(bi, 3, 1)
				local x2 = TalentTree.pos(bi, 3, 3)
				local orL = Theme.label({
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromOffset((x1 + x2) / 2, y),
					Size = UDim2.fromOffset(40, 20),
					TextSize = T.caption,
					TextColor3 = C.goldLight,
					Text = "OR",
					ZIndex = 4,
					Parent = canvas,
				})
				Theme.textStroke(C.shade, 1.5).Parent = orL
			end
			for _, nv in bv.nodes do
				local d = nv.def
				local key = d.kind == "keystone"
				local size = if key then TalentTree.KEYSTONE else TalentTree.NODE
				local x, y = TalentTree.pos(bi, d.tier, d.col)
				local btn = make("TextButton", {
					Name = "Talent_" .. d.id,
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromOffset(x, y - 6),
					Size = UDim2.fromOffset(size, size),
					Rotation = if key then 45 else 0,
					BackgroundColor3 = C.greyDark,
					AutoButtonColor = false,
					Text = "",
					Selectable = true,
					ZIndex = 5,
					Parent = canvas,
				}) :: TextButton
				if key then
					Theme.corner(10).Parent = btn
				else
					Theme.round().Parent = btn
				end
				Theme.gloss(btn, 1, 0.75)
				local stroke = Theme.stroke(C.shade, if key then 4 else 3)
				stroke.Parent = btn
				Theme.hover(btn, 1.08)
				local icon = Theme.label({
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.45),
					Size = UDim2.fromScale(1, 0.6),
					Rotation = if key then -45 else 0,
					TextSize = if key then T.title else T.heading,
					TextColor3 = C.white,
					Text = KIND_ICON[d.kind] or "",
					ZIndex = 6,
					Parent = btn,
				})
				Theme.textStroke(C.shade, 1.5).Parent = icon
				local rank = Theme.label({
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromOffset(x + size * 0.42, y + size * 0.22),
					Size = UDim2.fromOffset(34, 16),
					BackgroundColor3 = C.rind,
					BackgroundTransparency = 0.1,
					TextSize = T.micro,
					TextColor3 = C.cream,
					Text = "",
					ZIndex = 7,
					Parent = canvas,
				})
				Theme.corner(8).Parent = rank
				local name = Theme.label({
					AnchorPoint = Vector2.new(0.5, 0),
					Position = UDim2.fromOffset(x, y + size / 2 - 2 + (if key then 8 else 0)),
					Size = UDim2.fromOffset(TalentTree.COL_W + 20, 14),
					TextSize = T.micro,
					TextColor3 = C.cream,
					TextTruncate = Enum.TextTruncate.AtEnd,
					TextWrapped = false,
					Text = d.name,
					ZIndex = 6,
					Parent = canvas,
				})
				Theme.textStroke(C.shade, 1).Parent = name
				local ui: NodeUi = {
					button = btn,
					stroke = stroke,
					rank = rank,
					name = name,
					icon = icon,
					pulse = nil,
					id = d.id,
					bi = bi,
				}
				nodes[d.id] = ui
				Theme.tooltip(btn, function()
					local bvNow = model.branches[bi]
					local cur = bvNow and bvNow.byId[d.id]
					return if cur then TalentTree.tooltip(cur, bvNow.def.name) else d.name
				end)
				btn.Activated:Connect(function()
					local id = classId
					local bvNow = model.branches[bi]
					local cur = bvNow and bvNow.byId[d.id]
					if not id or not cur then
						return
					end
					if cur.state ~= "available" and cur.state ~= "partial" then
						return
					end
					local k = if cur.rank + 1 <= 1 then d.id else d.id .. "#" .. (cur.rank + 1)
					optimistic[k] = os.clock()
					Remotes.fire(Remotes.C2S.SelectPerk, id, d.id)
					render()
					task.delay(3.1, render) -- drop the optimistic mark if the server said no
				end)
			end
		end
		applyZoom()
	end

	local function styleNode(n: NodeUi, nv: any, color: Color3)
		if n.pulse then
			n.pulse:Cancel()
			n.pulse = nil
		end
		local st = nv.state
		local key = nv.def.kind == "keystone"
		n.rank.Text = string.format("%d/%d", nv.rank, nv.maxRank)
		n.rank.TextColor3 = if nv.rank >= nv.maxRank then C.gold else C.cream
		if st == "maxed" then
			n.button.BackgroundColor3 = color
			n.stroke.Color = C.gold
			n.stroke.Thickness = if key then 5 else 4
			n.stroke.Transparency = 0
			n.name.TextColor3 = C.goldLight
			n.icon.Text = if key then "★" elseif nv.def.kind == "stat" then "✔" else n.icon.Text
		elseif st == "partial" or st == "capped" then
			n.button.BackgroundColor3 = color:Lerp(C.rind, 0.25)
			n.stroke.Color = C.gold
			n.stroke.Thickness = 4
			n.stroke.Transparency = 0
			if st == "partial" then
				n.pulse = Theme.pulse(n.stroke, 0, 0.7, 0.75)
			end
			n.name.TextColor3 = C.cream
		elseif st == "available" then
			n.button.BackgroundColor3 = color:Lerp(C.rind, 0.55)
			n.stroke.Color = C.gold
			n.stroke.Thickness = 4
			n.pulse = Theme.pulse(n.stroke, 0, 0.7, 0.75)
			n.name.TextColor3 = C.cream
		else
			n.button.BackgroundColor3 = C.greyDark:Lerp(C.rind, 0.4)
			n.stroke.Color = if key then C.cheeseDark else C.shade
			n.stroke.Thickness = if key then 4 else 2
			n.stroke.Transparency = 0
			n.name.TextColor3 = C.textDim
		end
		if st ~= "maxed" then
			n.icon.Text = if nv.why == "exclusive"
				then "✕"
				elseif st == "locked" then "🔒"
				else (KIND_ICON[nv.def.kind] or "")
			if nv.def.kind == "stat" and st ~= "locked" then
				n.icon.Text = "+"
			end
		end
	end

	local function doRespec(payWith: string?)
		local id = classId
		if not id then
			return
		end
		if model.spent <= 0 then
			return
		end
		if os.clock() - respecArmedAt > 3 then
			if payWith == "token" then
				return -- the token button only exists while armed
			end
			respecArmedAt = os.clock()
			render()
			task.delay(3.05, render)
			return
		end
		respecArmedAt = 0
		Remotes.fire(Remotes.C2S.ResetPerks, id, if payWith == "token" then "token" else "cheese")
		table.clear(optimistic)
		render()
	end
	respec.Activated:Connect(function()
		if respec.Active then
			doRespec("cheese")
		end
	end)
	respecToken.Activated:Connect(function()
		if respecToken.Active and respecToken.Visible then
			doRespec("token")
		end
	end)

	render = function()
		local id = classId
		if not id or not p.Visible then
			return
		end
		local free = freeNow()
		model = TalentTree.model(perksModule(), id, takenSet(), free)
		local tag = id .. (if model.placeholder then ":wait" else "")
		if builtFor ~= tag then
			builtFor = tag
			build()
		end
		local def = Defs.get("Classes", id)
		local pr = ClassInfo.progress(id)
		title.Text = Defs.name(def, id) .. " talents"
		local keys = 0
		for _, bv in model.branches do
			for _, nv in bv.nodes do
				if nv.def.kind == "keystone" and nv.rank > 0 then
					keys += 1
				end
			end
		end
		sub.Text = string.format(
			"Class level %d · %d point%s spent · %d/3 keystones · 1 point per level, +1 per Prestige (to ⭐16)",
			pr.level,
			model.spent,
			if model.spent == 1 then "" else "s",
			keys
		)
		pointsBadge.Text = string.format("%d FREE POINT%s", free, if free == 1 then "" else "S")
		pointsBadge.BackgroundColor3 = if free > 0 then C.green else C.greyDark
		for bi, bv in model.branches do
			local color = BRANCH_COLORS[bi] or C.gold
			local hd = headers[bi]
			if hd then
				local nextGate: number? = nil
				for _, g in { 3, 6, 9, 12 } do
					if bv.spent < g then
						nextGate = g
						break
					end
				end
				hd.info.Text = string.format(
					"%d / 15 points%s",
					bv.spent,
					if nextGate
						then string.format(" · next row at %d", nextGate)
						else " · keystone row open"
				)
			end
			for _, nv in bv.nodes do
				local n = nodes[nv.def.id]
				if n then
					styleNode(n, nv, color)
				end
			end
		end
		for _, lk in links do
			local bv = model.branches[lk.bi]
			local a = bv and bv.byId[lk.from]
			local b = bv and bv.byId[lk.to]
			lk.frame.BackgroundColor3 = if a
					and b
					and a.rank > 0
					and b.rank > 0
				then C.gold
				elseif a and a.rank > 0 then (BRANCH_COLORS[lk.bi] or C.gold):Lerp(C.rind, 0.3)
				else C.greyDark
		end
		-- Respec button
		local profile = State.get("profile")
		local tokens = if type(profile) == "table" then tonumber(profile.respecTokens) or 0 else 0
		local cost = pr.respecCost or ClassInfo.respecCost(pr.level)
		local cheese = if type(profile) == "table" then tonumber(profile.cheese) or 0 else 0
		local armed = os.clock() - respecArmedAt <= 3 and model.spent > 0
		local canCheese = cost == nil or cheese >= cost
		local showToken = armed and tokens > 0
		respecToken.Visible = showToken
		pointsBadge.Visible = not showToken
		if showToken then
			respecToken.Text = string.format("Use token (×%d)", tokens)
			Theme.setEnabled(respecToken, true)
		end
		if model.spent <= 0 then
			respec.Text = "Respec"
			Theme.setEnabled(respec, false)
		elseif armed then
			respec.Text = if cost then "Pay 🧀 " .. Format.int(cost) else "Confirm"
			respec.BackgroundColor3 = C.orange
			Theme.setEnabled(respec, canCheese)
		else
			respec.Text = if cost then "Respec 🧀 " .. Format.int(cost) else "Respec"
			respec.BackgroundColor3 = C.creamDark
			Theme.setEnabled(respec, canCheese or tokens > 0)
		end
		if model.placeholder then
			footer.Text = "Talent trees are loading: nodes show as locked until the class data arrives."
			footer.TextColor3 = C.red
		elseif free > 0 then
			footer.Text = string.format(
				"%s a glowing talent to learn a rank. Rows open at 3 / 6 / 9 / 12 points in their branch; ★ keystones change how you play.",
				if phone then "Tap" else "Click"
			)
			footer.TextColor3 = C.brown
		else
			footer.Text = "No free points: level this class (1 per level) or Prestige (+1 each, up to ⭐16)."
			footer.TextColor3 = C.brown
		end
	end

	table.insert(
		unsubs,
		screen.onResize(function()
			task.defer(applyZoom)
		end)
	)
	table.insert(
		unsubs,
		State.subscribe("profile", function()
			render()
		end)
	)
	table.insert(
		unsubs,
		State.subscribe("run", function()
			if not State.inLobby() then
				PerkTreeUI.close()
			end
		end)
	)
end

function PerkTreeUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	if screen then
		screen.destroy()
		screen = nil
	end
	panel = nil
end

return PerkTreeUI
