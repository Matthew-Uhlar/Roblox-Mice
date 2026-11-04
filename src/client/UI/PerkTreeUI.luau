--!strict
-- Perk Tree screen (GDD-v2 §5): 3 branches x 5 tiers per class, drawn as a
-- node graph from Frames (Util/PerkTree.layout does the maths). Node states:
--   taken      gold, check mark
--   available  cream with a pulsing gold ring (enough free points, previous tier taken)
--   locked     dark, padlock (earlier tier first / not enough points)
-- A tier-t perk costs t points (Config/ClassPerks). Tooltips explain each node.
-- Header: class level, free points, Respec. The first tap arms it for 3 s and
-- shows the payment choice: "Pay 🧀 N" (cheese) and, when the player owns any,
-- "Use token" (a Perk Respec Token). A token is only spent when that button is
-- pressed: never silently (QC-A minor 4 / QC-B V2-m5).
-- Sends Net.C2S.SelectPerk(classId, perkId) and
-- Net.C2S.ResetPerks(classId, "cheese" | "token") (two taps to confirm).
-- Opened from the lobby (LobbyUI): PerkTreeUI.open(classId).

local GuiService = game:GetService("GuiService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local ClassInfo = require(script.Parent.ClassInfo)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local PerkTree = require(Client.Util.PerkTree)
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

local screen: any = nil
local unsubs: { () -> () } = {}
local classId: string? = nil
local optimistic: { [string]: number } = {} -- perkId -> os.clock() of the SelectPerk
local respecArmedAt = 0

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
	render()
	if changed then
		table.clear(optimistic)
	end
end

function PerkTreeUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallPerks", 25)
	local root: Frame = screen.root
	local touch = Theme.TOUCH
	local head = math.max(64, touch + 10)
	-- Touch (QC-B V2-m6): a wider panel and the rows layout (one row per
	-- branch) so nodes stay >= 48 screen px on a 667x375 phone.
	local wide = Device.mode() == "touch"
	local PW, PH = PerkTree.panelSize(wide)

	local p = Theme.panel({
		Name = "PerkTree",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(PW, PH),
		Visible = false,
		Parent = root,
	})
	panel = p
	table.insert(unsubs, Theme.fitFrame(screen, p, PW, PH, 8))

	Theme.icon("tree", 40, C.green, { Position = UDim2.fromOffset(16, 10), Parent = p })
	local title = Theme.label({
		Position = UDim2.fromOffset(64, 6),
		Size = UDim2.new(1, -(touch + 300), 0, 34),
		TextSize = T.title,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = p,
	})
	local sub = Theme.label({
		Position = UDim2.fromOffset(64, 40),
		Size = UDim2.new(1, -(touch + 300), 0, 20),
		TextSize = T.caption,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = p,
	})
	local pointsBadge = Theme.badge("0 POINTS", C.green, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(touch + 214), 0, 14),
		Size = UDim2.fromOffset(0, 30),
		TextSize = T.body,
		Parent = p,
	})
	local respec = Theme.button("Respec", C.creamDark, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(touch + 20), 0, 6),
		Size = UDim2.fromOffset(186, touch),
		TextSize = T.body,
		Parent = p,
	})
	Theme.tooltip(
		respec,
		"Refund every perk point of this class. Costs cheese (never Robux) or, only if you pick it, a respec token."
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

	local canvas = make("Frame", {
		Name = "Canvas",
		Position = UDim2.fromOffset(16, head + 4),
		Size = UDim2.new(1, -32, 1, -(head + 40)),
		BackgroundColor3 = C.rind,
		BackgroundTransparency = 0.05,
		Parent = p,
	}) :: Frame
	Theme.corner(14).Parent = canvas
	Theme.gradient(canvas, Color3.fromRGB(255, 240, 220), Color3.fromRGB(150, 130, 110))
	Theme.goldStroke(2).Parent = canvas
	local footer = Theme.label({
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 20, 1, -8),
		Size = UDim2.new(1, -40, 0, 22),
		TextSize = T.caption,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = p,
	})

	type Node = {
		button: TextButton,
		stroke: UIStroke,
		icons: { [string]: Frame },
		name: TextLabel,
		cost: TextLabel,
		pulse: Tween?,
		branch: number,
		tier: number,
	}
	local nodes: { [number]: { [number]: Node } } = {}
	local links: { Frame } = {}
	local headers: { TextLabel } = {}
	local builtFor: string? = nil
	local tree: PerkTree.Tree = PerkTree.normalise(nil)

	local function takenSet(): { [string]: boolean }
		local id = classId
		local st = if id then State.classState(id) else nil
		local set: { [string]: boolean } = if st then table.clone(st.perks) else {}
		local now = os.clock()
		for perkId, at in optimistic do
			if set[perkId] or now - at > 3 then
				optimistic[perkId] = nil
			else
				set[perkId] = true
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
		local spentOptimistic = 0
		for perkId in optimistic do
			for b = 1, #tree.branches do
				for _, perk in tree.branches[b].perks do
					if perk.id == perkId then
						spentOptimistic += perk.cost
					end
				end
			end
		end
		return math.max(0, pr.free - spentOptimistic)
	end

	local function layoutNodes()
		local abs = canvas.AbsoluteSize
		local s = math.max(Theme.scale(), 0.05)
		local w, h = abs.X / s, abs.Y / s
		if w < 10 or h < 10 then
			w, h = PW - 32, PH - head - 44
		end
		local L = PerkTree.screenLayout(wide, w, h)
		for b, col in nodes do
			for t, n in col do
				local pos = L.nodes[b][t]
				n.button.Position = UDim2.fromOffset(pos.x, pos.y)
				n.button.Size = UDim2.fromOffset(L.node, L.node)
				local lr = L.labels and L.labels[b] and L.labels[b][t]
				if lr then
					n.name.Size = UDim2.fromOffset(lr.w, lr.h)
				end
			end
		end
		for i, link in L.links do
			local f = links[i]
			if f then
				if link.w then
					f.Position = UDim2.fromOffset(link.x, link.y - 3)
					f.Size = UDim2.fromOffset(link.w, 6)
				else
					f.Position = UDim2.fromOffset(link.x - 3, link.y)
					f.Size = UDim2.fromOffset(6, link.h)
				end
			end
		end
		for b, hd in headers do
			local band = L.bands and L.bands[b]
			if band then
				hd.Position = UDim2.fromOffset(band.x, band.y)
				hd.Size = UDim2.fromOffset(band.w, band.h)
				hd.TextWrapped = true
			else
				hd.Position = UDim2.fromOffset(L.colW * (b - 1), 6)
				hd.Size = UDim2.fromOffset(L.colW, 30)
			end
		end
	end
	table.insert(
		unsubs,
		screen.onResize(function()
			task.defer(layoutNodes)
		end)
	)
	canvas:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutNodes)

	local function build()
		for _, ch in canvas:GetChildren() do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		table.clear(nodes)
		table.clear(links)
		table.clear(headers)
		for b = 1, PerkTree.BRANCHES do
			for t = 1, PerkTree.TIERS - 1 do
				local link = make("Frame", {
					Name = "Link",
					BackgroundColor3 = C.greyDark,
					BorderSizePixel = 0,
					Parent = canvas,
				}) :: Frame
				Theme.corner(3).Parent = link
				link:SetAttribute("Branch", b)
				link:SetAttribute("Tier", t)
				table.insert(links, link)
			end
		end
		for b, br in tree.branches do
			local hd = Theme.label({
				TextSize = T.heading,
				TextColor3 = BRANCH_COLORS[b] or C.gold,
				Text = string.upper(br.name),
				Parent = canvas,
			})
			Theme.textStroke(C.shade, 1.5).Parent = hd
			headers[b] = hd
			nodes[b] = {}
			for t = 1, PerkTree.TIERS do
				local perk = br.perks[t]
				local btn = make("TextButton", {
					Name = "Perk_" .. b .. "_" .. t,
					BackgroundColor3 = C.greyDark,
					AutoButtonColor = false,
					Text = "",
					Selectable = true,
					ZIndex = 3,
					Parent = canvas,
				}) :: TextButton
				Theme.round().Parent = btn
				Theme.gloss(btn, 1, 0.75)
				local stroke = Theme.stroke(C.shade, 3)
				stroke.Parent = btn
				Theme.hover(btn, 1.08)
				local icons: { [string]: Frame } = {}
				for _, k in { "check", "lock", "plus" } do
					icons[k] = Theme.icon(k, 26, if k == "lock" then C.grey else C.white, {
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.42),
						Visible = false,
						ZIndex = 4,
						Parent = btn,
					})
				end
				local cost = Theme.label({
					AnchorPoint = Vector2.new(0.5, 1),
					Position = UDim2.new(0.5, 0, 1, -3),
					Size = UDim2.new(1, 0, 0, 14),
					TextSize = T.micro,
					Text = if perk then tostring(perk.cost) .. " PT" else "",
					ZIndex = 5,
					Parent = btn,
				})
				Theme.textStroke(C.shade, 1).Parent = cost
				local name = Theme.label({
					AnchorPoint = Vector2.new(0.5, 0),
					Position = UDim2.new(0.5, 0, 1, 2),
					Size = UDim2.fromOffset(170, 16),
					TextSize = T.micro,
					TextColor3 = C.cream,
					TextTruncate = Enum.TextTruncate.AtEnd,
					TextWrapped = false,
					Text = if perk then perk.name else "???",
					Parent = btn,
				})
				Theme.textStroke(C.shade, 1).Parent = name
				local node: Node = {
					button = btn,
					stroke = stroke,
					icons = icons,
					name = name,
					cost = cost,
					pulse = nil,
					branch = b,
					tier = t,
				}
				nodes[b][t] = node
				Theme.tooltip(btn, function()
					local pk = tree.branches[b] and tree.branches[b].perks[t]
					if not pk then
						return "<b>Coming soon</b>\nThis perk tree arrives with the class progression update."
					end
					local st, why = PerkTree.nodeState(tree, b, t, takenSet(), freeNow())
					local status = if st == "taken"
						then '<font color="#FFD65C">Taken</font>'
						elseif st == "available" then '<font color="#7CE07C">Available: tap to take</font>'
						elseif why == "tier" then '<font color="#FF8A7A">Locked: take tier '
							.. (t - 1)
							.. " of this branch first</font>"
						else '<font color="#FF8A7A">Locked: needs ' .. pk.cost .. " free point" .. (if pk.cost
								== 1
							then ""
							else "s") .. "</font>"
					return string.format(
						"<b>%s</b>  (tier %d · %d pt%s)\n%s\n%s",
						pk.name,
						t,
						pk.cost,
						if pk.cost == 1 then "" else "s",
						pk.description,
						status
					)
				end)
				btn.Activated:Connect(function()
					local id = classId
					local pk = tree.branches[b] and tree.branches[b].perks[t]
					if not id or not pk then
						return
					end
					local st = PerkTree.nodeState(tree, b, t, takenSet(), freeNow())
					if st ~= "available" then
						return
					end
					optimistic[pk.id] = os.clock()
					Remotes.fire(Remotes.C2S.SelectPerk, id, pk.id)
					render()
					task.delay(3.1, render) -- drop the optimistic mark if the server said no
				end)
			end
		end
		layoutNodes()
	end

	local function styleNode(n: Node, st: string, color: Color3)
		if n.pulse then
			n.pulse:Cancel()
			n.pulse = nil
		end
		n.icons.check.Visible = st == "taken"
		n.icons.lock.Visible = st == "locked"
		n.icons.plus.Visible = st == "available"
		if st == "taken" then
			n.button.BackgroundColor3 = color
			n.stroke.Color = C.gold
			n.stroke.Thickness = 4
			n.stroke.Transparency = 0
			n.name.TextColor3 = C.goldLight
		elseif st == "available" then
			n.button.BackgroundColor3 = color:Lerp(C.rind, 0.55)
			n.stroke.Color = C.gold
			n.stroke.Thickness = 4
			n.pulse = Theme.pulse(n.stroke, 0, 0.7, 0.75)
			n.name.TextColor3 = C.cream
		else
			n.button.BackgroundColor3 = C.greyDark:Lerp(C.rind, 0.4)
			n.stroke.Color = C.shade
			n.stroke.Thickness = 2
			n.stroke.Transparency = 0
			n.name.TextColor3 = C.textDim
		end
	end

	local function doRespec(payWith: string?)
		local id = classId
		if not id then
			return
		end
		local pr = ClassInfo.progress(id)
		if pr.spent <= 0 then
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
		-- the player picked how to pay; the default is cheese, never the token
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
		local newTree = ClassInfo.tree(id)
		if builtFor ~= id or (tree.placeholder and not newTree.placeholder) then
			tree = newTree
			builtFor = id
			build()
		end
		local def = Defs.get("Classes", id)
		local pr = ClassInfo.progress(id)
		local free = freeNow()
		local taken = takenSet()
		title.Text = Defs.name(def, id) .. " perk tree"
		sub.Text = string.format(
			"Class level %d · %d point%s spent · 1 point per level after the first",
			pr.level,
			pr.spent,
			if pr.spent == 1 then "" else "s"
		)
		pointsBadge.Text = string.format("%d FREE POINT%s", free, if free == 1 then "" else "S")
		pointsBadge.BackgroundColor3 = if free > 0 then C.green else C.greyDark
		for b, col in nodes do
			local color = BRANCH_COLORS[b] or C.gold
			for t, n in col do
				local st = PerkTree.nodeState(tree, b, t, taken, free)
				styleNode(n, st, color)
			end
		end
		for _, link in links do
			local b, t = link:GetAttribute("Branch") :: number, link:GetAttribute("Tier") :: number
			local below = tree.branches[b] and tree.branches[b].perks[t + 1]
			link.BackgroundColor3 = if below and taken[below.id]
				then C.gold
				elseif
					tree.branches[b]
					and tree.branches[b].perks[t]
					and taken[tree.branches[b].perks[t].id]
				then (BRANCH_COLORS[b] or C.gold):Lerp(C.rind, 0.3)
				else C.greyDark
		end
		-- Respec button
		local profile = State.get("profile")
		local tokens = if type(profile) == "table" then tonumber(profile.respecTokens) or 0 else 0
		local cost = pr.respecCost or ClassInfo.respecCost(pr.level)
		local cheese = if type(profile) == "table" then tonumber(profile.cheese) or 0 else 0
		local armed = os.clock() - respecArmedAt <= 3 and pr.spent > 0
		local canCheese = cost == nil or cheese >= cost
		local showToken = armed and tokens > 0
		respecToken.Visible = showToken
		pointsBadge.Visible = not showToken
		title.Size = UDim2.new(1, -(touch + (if showToken then 450 else 300)), 0, 34)
		if showToken then
			respecToken.Text = string.format("Use token (×%d)", tokens)
			Theme.setEnabled(respecToken, true)
		end
		if pr.spent <= 0 then
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
		if tree.placeholder then
			footer.Text = "Perk trees are loading: nodes show as locked until the class data arrives."
			footer.TextColor3 = C.red
		elseif free > 0 then
			footer.Text = string.format(
				"%s a glowing node to take it. A tier-t perk costs t points and needs the tier above it.",
				if Device.mode() == "touch" then "Tap" else "Click"
			)
			footer.TextColor3 = C.brown
		else
			footer.Text = "No free points: level this class up in runs to earn more (1 per level)."
			footer.TextColor3 = C.brown
		end
	end

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
