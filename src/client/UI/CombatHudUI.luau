--!strict
-- v4 in-run HUD layer (docs/V4-PLAN.md "Interface" / "Feedback", review B
-- S2-1 / S2-2). Sits above UI/HudUI and adds:
--
--   storm pill      under the minimap: "🔥 Melt closes 0:42" / "Closing 0:12"
--                   (State "storm"; the ring itself is drawn by UI/MinimapUI)
--   melt warning    upper centre, pulsing red: you are outside the safe circle
--   Herd Call       upper centre: "back in 0:12" (State "redeploy" {untilT})
--   objective arrow a small gold arrow around the screen centre pointing at
--                   the next goal (gate > boss > nearest champion > POI >
--                   safe zone; Util/HudMath.objective over State.marks())
--   damage vignette red screen edges: a flash on each HP drop, a pulse below
--                   30% HP, held while downed (own ScreenGui, full screen)
--   kill streak     mid-left "×12 STOMP!" from Fx `die` near your hero; resets
--                   after 2 s without a kill, pops at 25 / 50 / 100
--   ping wheel      G (tap = stays open, hold + release = pick under the
--                   pointer), middle-click = instant context ping at the
--                   cursor, gamepad DPadUp, phone 📍 button. 6 ping kinds and
--                   a 💬 page of 8 preset lines (no free text). Sends
--                   Net.C2S.Ping(kind, x, z) / Net.C2S.QuickChat(index).
--   ping markers    world BillboardGuis for squad pings (State "pings");
--                   quick-chat lines show as a toast with the sender's name.
--
-- Input lives in Controllers/InputController, which sets State "pingWheel"
-- {open, x, z, at, released?}.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local UiSizes = require(Client.Util.UiSizes)
local HudMath = require(Client.Util.HudMath)
local Device = require(Client.Util.Device)
local Remotes = require(Client.Util.Remotes)
local State = require(Client.Controllers.State)
local Defs = require(Client.Util.Defs)

local CombatHudUI = {}

local C = Theme.C
local make = Theme.make

local STREAK_RANGE = 22 -- studs: a mouse dying this close counts as your stomp
local HOLD_PICK = 0.25 -- seconds: a longer G press picks on release

local screen: any = nil
local vignetteGui: ScreenGui? = nil
local unsubs: { () -> () } = {}
local conns: { any } = {}
local markerFolder: Folder? = nil

local function myRoot(): BasePart?
	local p = Players.LocalPlayer
	local ch = p and p.Character
	local r = ch and ch:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function inRun(): boolean
	local ph = State.phase()
	return ph ~= nil and ph ~= "Lobby" and ph ~= "Results"
end

----------------------------------------------------------------------
-- Ping wheel model (shared with InputController through State)
----------------------------------------------------------------------

type Slot = { text: string, icon: string, kind: string?, chat: number?, page: string? }

local PAGE_PINGS: { Slot } = {}
for _, k in HudMath.PING_KINDS do
	local info = HudMath.PING_INFO[k]
	table.insert(PAGE_PINGS, { text = info.text, icon = info.icon, kind = k })
end
table.insert(PAGE_PINGS, { text = "Chat", icon = "💬", page = "chat" })

local PAGE_CHAT: { Slot } = {}
for i, line in HudMath.QUICK_CHAT do
	table.insert(PAGE_CHAT, { text = line, icon = "💬", chat = i })
end

function CombatHudUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallCombat", 12)
	local root: Frame = screen.root
	local touch = Theme.TOUCH
	local dense = Theme.dense()
	local Z = UiSizes.hud(dense, touch)
	local K = UiSizes.combat(dense, touch)

	------------------------------------------------------------------
	-- Damage vignette (own full-screen gui so it reaches the true edges)
	------------------------------------------------------------------
	local vg = make("ScreenGui", {
		Name = "TrunkfallVignette",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ScreenInsets = Enum.ScreenInsets.None,
		DisplayOrder = 5,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	}) :: ScreenGui
	vignetteGui = vg
	local edges: { Frame } = {}
	local EDGE = 0.14
	local specs = {
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(1, EDGE), rot = 90 },
		{ pos = UDim2.fromScale(0, 1 - EDGE), size = UDim2.fromScale(1, EDGE), rot = -90 },
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(EDGE * 0.6, 1), rot = 0 },
		{ pos = UDim2.fromScale(1 - EDGE * 0.6, 0), size = UDim2.fromScale(EDGE * 0.6, 1), rot = 180 },
	}
	for _, sp in specs do
		local f = make("Frame", {
			Position = sp.pos,
			Size = sp.size,
			BackgroundColor3 = Color3.fromRGB(200, 30, 20),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = vg,
		}) :: Frame
		make("UIGradient", {
			Rotation = sp.rot,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.35),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = f,
		})
		table.insert(edges, f)
	end

	------------------------------------------------------------------
	-- Storm pill (straddles the minimap's bottom edge)
	------------------------------------------------------------------
	local stormPill = Theme.badge("", C.rind, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -(Z.margin + Z.minimap / 2), 0, 10 + Z.minimap),
		Size = UDim2.fromOffset(K.stormW, K.stormH),
		AutomaticSize = Enum.AutomaticSize.None,
		TextSize = K.stormText,
		Visible = false,
		ZIndex = 4,
		Parent = root,
	})
	local stormStroke = Theme.stroke(Color3.fromRGB(255, 90, 60), 2)
	stormStroke.Parent = stormPill
	Theme.tooltip(stormPill, "The Melt: stay inside the circle. Outside it you lose HP every second.")

	------------------------------------------------------------------
	-- Melt warning + Herd Call (upper centre)
	------------------------------------------------------------------
	local warn = Theme.label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, K.warnY),
		Size = UDim2.fromOffset(K.warnW, K.warnH),
		TextSize = K.warnText,
		TextColor3 = Color3.fromRGB(255, 96, 80),
		Text = "⚠ OUTSIDE THE MELT! Get inside the circle",
		Visible = false,
		Parent = root,
	})
	Theme.textStroke(C.shade, 2.5).Parent = warn
	local redeploy = Theme.badge("", C.greenDark, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, K.warnY, K.warnH + 8),
		Size = UDim2.fromOffset(K.redeployW, K.redeployH),
		AutomaticSize = Enum.AutomaticSize.None,
		TextSize = K.redeployText,
		Visible = false,
		Parent = root,
	})
	Theme.tooltip(
		redeploy,
		"Herd Call: a standing squadmate brings you back. Champion kills and POIs make it faster."
	)

	------------------------------------------------------------------
	-- Spectating bar (iteration 1 #17, C-21): while dead, a small bottom bar
	-- "👀 Spectating X · back in 0:12" with a ▸ button to cycle. The camera
	-- (Team G, CameraController) writes State "spectate" = {id, name}; the ▸
	-- button calls CameraController.cycleSpectate(). Without a target the bar
	-- names a standing squadmate.
	------------------------------------------------------------------
	local specBar = make("Frame", {
		Name = "Spectating",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -(Z.rowH + Z.bottomY + 18)),
		Size = UDim2.fromOffset(K.redeployW + touch + 8, math.max(K.redeployH, Theme.SLIM)),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = root,
	}) :: Frame
	Theme.list(
		Enum.FillDirection.Horizontal,
		8,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	).Parent =
		specBar
	local specLabel = Theme.badge("", C.rind, {
		LayoutOrder = 1,
		Size = UDim2.fromOffset(K.redeployW, K.redeployH),
		AutomaticSize = Enum.AutomaticSize.None,
		TextSize = K.redeployText - 2,
		Parent = specBar,
	})
	Theme.button("▸", C.cream, {
		LayoutOrder = 2,
		Size = UDim2.fromOffset(Theme.SLIM, Theme.SLIM),
		TextSize = 20,
		Parent = specBar,
	}, function()
		local ok, Cam = pcall(function()
			return require(Client.Controllers.CameraController) :: any
		end)
		if ok and type(Cam) == "table" and type(Cam.cycleSpectate) == "function" then
			Cam.cycleSpectate()
		end
	end)
	local function spectateName(): string?
		local sp = (State.get("spectate") or State.get("spectating"))
		if type(sp) == "table" and (sp.name or sp.id) then
			return if sp.name then tostring(sp.name) else State.nameOf(sp.id)
		end
		-- fallback: a standing squadmate
		local party = State.get("party")
		local me = State.localUserId()
		if type(party) == "table" then
			for id, e in party do
				if id ~= me and type(e) == "table" and e.downed ~= true and (tonumber(e.hp) or 1) > 0 then
					return State.nameOf(id)
				end
			end
		end
		return nil
	end

	------------------------------------------------------------------
	-- Kill streak (mid-left)
	------------------------------------------------------------------
	local streak = Theme.label({
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, Z.margin, K.streakY, 0),
		Size = UDim2.fromOffset(K.streakW, K.streakH),
		TextSize = K.streakText,
		TextColor3 = C.cheese,
		TextXAlignment = Enum.TextXAlignment.Left,
		Visible = false,
		Parent = root,
	})
	Theme.textStroke(C.brownDark, 2.5).Parent = streak
	local streakN = 0
	local lastKill = 0

	------------------------------------------------------------------
	-- Objective arrow (orbits the screen centre, where the camera keeps you)
	------------------------------------------------------------------
	local arrowHolder = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(K.arrow, K.arrow),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = root,
	}) :: Frame
	local arrow = Theme.label({
		Size = UDim2.fromScale(1, 1),
		TextSize = K.arrow,
		TextColor3 = C.gold,
		Text = "▲",
		TextTransparency = 0.15,
		Parent = arrowHolder,
	})
	Theme.textStroke(C.brownDark, 2).Parent = arrow
	local arrowLabel = Theme.label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 0),
		Size = UDim2.fromOffset(150, K.arrowText + 4),
		TextSize = K.arrowText,
		TextColor3 = C.goldLight,
		TextWrapped = false,
		Parent = arrowHolder,
	})
	Theme.textStroke(C.shade, 1.5).Parent = arrowLabel

	------------------------------------------------------------------
	-- Ping wheel
	------------------------------------------------------------------
	local wheelSize = 2 * K.wheelR + K.wheelSlot
	local wheel = make("Frame", {
		Name = "PingWheel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(wheelSize, wheelSize),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 20,
		Parent = root,
	}) :: Frame
	local disc = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(2 * K.wheelR + 20, 2 * K.wheelR + 20),
		BackgroundColor3 = C.rind,
		BackgroundTransparency = 0.35,
		ZIndex = 20,
		Parent = wheel,
	})
	Theme.round().Parent = disc
	Theme.goldStroke(2, 0.3).Parent = disc
	local slotButtons: { TextButton } = {}
	local page: { Slot } = PAGE_PINGS
	local pageName = "pings"
	local wheelX, wheelZ = 0, 0
	local wheelOpenedAt = 0
	local hovered: number? = nil

	local function closeWheel()
		wheel.Visible = false
		hovered = nil
	end

	local function choose(i: number)
		local s = page[i]
		if not s then
			return
		end
		if s.page == "chat" then
			page, pageName = PAGE_CHAT, "chat"
			CombatHudUI.layoutWheel()
			return
		end
		if s.chat then
			State.sendQuickChat(s.chat)
		elseif s.kind then
			State.sendPing(s.kind, wheelX, wheelZ)
		end
		closeWheel()
	end

	local centre = Theme.button("✕", C.creamDark, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(math.max(touch, 52), math.max(touch, 52)),
		TextSize = 20,
		ZIndex = 22,
		Parent = wheel,
	}, function()
		if pageName == "chat" then
			page, pageName = PAGE_PINGS, "pings"
			CombatHudUI.layoutWheel()
		else
			closeWheel()
		end
	end)
	Theme.round().Parent = centre

	function CombatHudUI.layoutWheel()
		for _, b in slotButtons do
			b.Visible = false
		end
		centre.Text = if pageName == "chat" then "↩" else "✕"
		local n = #page
		for i, s in page do
			local b = slotButtons[i]
			if not b then
				local idx = i
				b = Theme.button("", C.cream, {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Size = UDim2.fromOffset(K.wheelSlot, math.max(touch, 44)),
					TextSize = K.wheelText,
					ZIndex = 22,
					Parent = wheel,
				}, function()
					choose(idx)
				end)
				slotButtons[i] = b
			end
			local x, y = HudMath.wheelSlot(i, n, K.wheelR)
			b.Position = UDim2.new(0.5, x, 0.5, y)
			b.Text = s.icon .. " " .. s.text
			b.Visible = true
			b.BackgroundColor3 = if s.kind
				then (function()
					local col = HudMath.PING_INFO[s.kind].color
					return Color3.fromRGB(col[1], col[2], col[3]):Lerp(C.cream, 0.55)
				end)()
				else C.cream
		end
	end

	local function openWheel(x: number, z: number)
		if not inRun() then
			return
		end
		wheelX, wheelZ = x, z
		wheelOpenedAt = os.clock()
		page, pageName = PAGE_PINGS, "pings"
		CombatHudUI.layoutWheel()
		wheel.Visible = true
		Theme.popIn(wheel)
	end

	-- pointer offset from the wheel centre, in design px
	local function pointerSector(): number?
		local abs = wheel.AbsolutePosition + wheel.AbsoluteSize / 2
		local m = UserInputService:GetMouseLocation()
		local inset = game:GetService("GuiService"):GetGuiInset()
		local s = Theme.scaleOf(wheel)
		local dx, dy = (m.X - abs.X) / s, (m.Y - inset.Y - abs.Y) / s
		return HudMath.wheelSector(dx, dy, #page, 30)
	end

	table.insert(
		unsubs,
		State.subscribe("pingWheel", function(w)
			if type(w) ~= "table" then
				return
			end
			if w.open then
				if wheel.Visible and not w.released then
					closeWheel() -- G again closes
				else
					openWheel(tonumber(w.x) or 0, tonumber(w.z) or 0)
				end
			elseif w.released and wheel.Visible then
				-- hold + release picks the sector under the pointer
				if os.clock() - wheelOpenedAt >= HOLD_PICK and Device.mode() == "kbm" then
					local sec = pointerSector()
					if sec then
						choose(sec)
					end
				end
			end
		end)
	)

	-- Phone: a 📍 button above the touch ability button.
	if Device.hasTouch() and K.pingButton > 0 then
		local pb = Theme.button("📍", C.cream, {
			Name = "PingButton",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -(36 + (150 - K.pingButton) / 2), 1, -(44 + 150 + 18)),
			Size = UDim2.fromOffset(K.pingButton, K.pingButton),
			TextSize = math.floor(K.pingButton * 0.45),
			Visible = false,
			Parent = root,
		}, function()
			if wheel.Visible then
				closeWheel()
				return
			end
			local r = myRoot()
			if r then
				openWheel(r.Position.X, r.Position.Z)
			end
		end)
		Theme.round().Parent = pb
		table.insert(
			conns,
			RunService.Heartbeat:Connect(function()
				pb.Visible = State.inCombat()
					or State.phase() == "StageClear"
					or State.phase() == "Extraction"
			end)
		)
	end

	------------------------------------------------------------------
	-- World ping markers (pooled BillboardGuis on Terrain attachments)
	------------------------------------------------------------------
	local folder = Instance.new("Folder")
	folder.Name = "TrunkfallPings"
	markerFolder = folder
	type Marker = { att: Attachment, gui: BillboardGui, icon: TextLabel, text: TextLabel }
	local markers: { Marker } = {}
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	folder.Parent = playerGui
	local function marker(i: number): Marker
		local m = markers[i]
		if m then
			return m
		end
		local att = Instance.new("Attachment")
		att.Name = "PingAnchor" .. i
		att.Parent = workspace.Terrain
		local gui = make("BillboardGui", {
			Name = "Ping" .. i,
			Adornee = att,
			AlwaysOnTop = true,
			Size = UDim2.fromOffset(120, 54),
			StudsOffsetWorldSpace = Vector3.new(0, 5, 0),
			LightInfluence = 0,
			MaxDistance = 400,
			Enabled = false,
			Parent = folder,
		}) :: BillboardGui
		local icon = make("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.fromOffset(30, 30),
			BackgroundColor3 = C.gold,
			Font = Theme.FONT,
			TextSize = 18,
			Text = "📍",
			Parent = gui,
		}) :: TextLabel
		Theme.round().Parent = icon
		Theme.stroke(C.brownDark, 2).Parent = icon
		local text = make("TextLabel", {
			Position = UDim2.fromOffset(0, 32),
			Size = UDim2.new(1, 0, 0, 20),
			BackgroundTransparency = 1,
			Font = Theme.FONT,
			TextSize = 15,
			TextColor3 = C.white,
			Text = "",
			Parent = gui,
		}) :: TextLabel
		Theme.textStroke(C.shade, 1.5).Parent = text
		m = { att = att, gui = gui, icon = icon, text = text }
		markers[i] = m
		return m
	end

	local seenChat: { [any]: boolean } = {}
	local function renderPings()
		local list = State.livePings()
		local n = 0
		for _, pg in list do
			if pg.chat then
				-- quick-chat: a toast once per line
				if not seenChat[pg] then
					seenChat[pg] = true
					State.toast:Fire(string.format("💬 %s: %s", State.nameOf(pg.by), pg.chat), "info")
				end
			else
				n += 1
				local m = marker(n)
				m.att.WorldPosition = Vector3.new(pg.x, 0, pg.z)
				local col = Color3.fromRGB(pg.color[1], pg.color[2], pg.color[3])
				m.icon.BackgroundColor3 = col
				m.icon.Text = pg.icon
				m.text.Text = pg.text
				m.gui.Enabled = true
			end
		end
		for i = n + 1, #markers do
			markers[i].gui.Enabled = false
		end
		-- forget chat lines that expired
		for k in seenChat do
			if not table.find(list, k) then
				seenChat[k] = nil
			end
		end
	end
	table.insert(unsubs, State.subscribe("pings", renderPings))

	------------------------------------------------------------------
	-- Boss intro card (iteration 1 C-8): name, title, one lore line and one
	-- "watch for" tip, from Fx `boss` + Config/Bosses (`lore`, `tip` when
	-- Team P adds them; else the first attack pattern's name).
	------------------------------------------------------------------
	local introCard = Theme.card({
		Name = "BossIntro",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.17),
		Size = UDim2.fromOffset(if dense then 420 else 500, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		ZIndex = 6,
		Parent = root,
	}, { accent = C.red, stroke = 3 })
	Theme.padding(14, 10).Parent = introCard
	Theme.list(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Center).Parent = introCard
	local function introLine(order: number, size: number, color: Color3, font: Enum.Font?): TextLabel
		local l = Theme.label({
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextSize = size,
			TextColor3 = color,
			Font = font or Theme.FONT,
			ZIndex = 7,
			Parent = introCard,
		})
		Theme.textStroke(C.shade, 1.5).Parent = l
		return l
	end
	local introName = introLine(1, if dense then 30 else 34, C.red)
	local introTitle = introLine(2, if dense then 16 else 18, C.gold)
	local introLore = introLine(3, if dense then 13 else 15, C.cream, Theme.FONT_BODY)
	local introTip = introLine(4, if dense then 14 else 16, Color3.fromRGB(255, 200, 120), Theme.FONT_BODY)
	local introToken = 0
	local lastIntroAt = -math.huge
	local function showBossIntro(ev: any)
		local def = Defs.get("Bosses", ev.bossId)
		introName.Text = string.upper(tostring(ev.name or (def and def.name) or "Boss"))
		local title = ev.title or (def and def.title)
		introTitle.Text = if title then tostring(title) else ""
		introTitle.Visible = title ~= nil
		local lore = ev.lore or (def and (def.lore or def.flavor))
		introLore.Text = if lore then tostring(lore) else ""
		introLore.Visible = lore ~= nil
		local tip = ev.tip or (def and (def.tip or def.watch))
		if tip == nil and def and type(def.patterns) == "table" and def.patterns[1] then
			local pat = tostring(def.patterns[1]):gsub("_", " ")
			tip = pat:gsub("^%l", string.upper) .. ": dodge the red zones"
		end
		introTip.Text = if tip then "👀 Watch for: " .. tostring(tip) else ""
		introTip.Visible = tip ~= nil
		introCard.Visible = true
		Theme.popIn(introCard)
		introToken += 1
		local my = introToken
		task.delay(math.clamp((tonumber(ev.intro) or 3) + 1.5, 3, 7), function()
			if introToken == my then
				introCard.Visible = false
			end
		end)
	end

	------------------------------------------------------------------
	-- Kill streak from Fx `die` near the hero
	------------------------------------------------------------------
	table.insert(
		conns,
		Remotes.on(Remotes.S2C.Fx, function(batch)
			if type(batch) ~= "table" then
				return
			end
			for _, ev in batch do
				-- M2's `bossIntro` {bossId, name, title, lore, tip} (World `boss` as a fallback)
				if type(ev) == "table" and ev.t == "bossIntro" then
					lastIntroAt = os.clock()
					showBossIntro(ev)
				elseif
					type(ev) == "table"
					and ev.t == "boss"
					and ev.intro ~= nil
					and os.clock() - lastIntroAt > 15
				then
					showBossIntro(ev)
				elseif type(ev) == "table" and (ev.t == "bossKill" or ev.t == "stageClear") then
					introCard.Visible = false
				end
			end
			if not State.inCombat() then
				return
			end
			local r = myRoot()
			if not r then
				return
			end
			local px, pz = r.Position.X, r.Position.Z
			local got = 0
			for _, ev in batch do
				if type(ev) == "table" and ev.t == "die" then
					local x, z = tonumber(ev.x), tonumber(ev.z)
					if x and z and (x - px) ^ 2 + (z - pz) ^ 2 <= STREAK_RANGE * STREAK_RANGE then
						got += 1
					end
				end
			end
			if got > 0 then
				local now = os.clock()
				if now - lastKill > HudMath.STREAK_RESET then
					streakN = 0
				end
				local before = streakN
				streakN += got
				lastKill = now
				if streakN >= 5 then
					local text, _ = HudMath.streakLabel(streakN)
					streak.Text = text
					local wasVisible = streak.Visible
					streak.Visible = true
					-- pop on first show and when a milestone is crossed
					local crossed = false
					for _, ms in { 25, 50, 100, 150, 200, 250, 300 } do
						if before < ms and streakN >= ms then
							crossed = true
						end
					end
					if not wasVisible or crossed then
						Theme.popIn(streak)
					end
				end
			end
		end)
	)

	------------------------------------------------------------------
	-- Per frame
	------------------------------------------------------------------
	local lastHp: number? = nil
	local lastHitAt = -math.huge
	table.insert(
		unsubs,
		State.subscribe("hud", function(h)
			if type(h) ~= "table" then
				return
			end
			local hp = tonumber(h.hp)
			if hp and lastHp and hp < lastHp - 0.5 then
				lastHitAt = os.clock()
			end
			lastHp = hp
		end)
	)

	table.insert(
		conns,
		RunService.RenderStepped:Connect(function()
			local active = inRun()
			local hud = State.get("hud")
			local nowC = os.clock()
			-- vignette
			local alpha = 1
			if active and type(hud) == "table" then
				local maxHp = math.max(1, tonumber(hud.maxHp) or 1)
				local frac = (tonumber(hud.hp) or maxHp) / maxHp
				alpha = HudMath.vignette(nowC - lastHitAt, frac, nowC, hud.downed == true)
			end
			for _, e in edges do
				e.BackgroundTransparency = alpha
			end
			if not active then
				stormPill.Visible = false
				warn.Visible = false
				redeploy.Visible = false
				specBar.Visible = false
				streak.Visible = false
				arrowHolder.Visible = false
				if wheel.Visible then
					closeWheel()
				end
				return
			end
			local now = State.serverNow()
			local r = myRoot()
			-- storm
			local storm = State.get("storm")
			if type(storm) == "table" and r then
				local st = HudMath.stormStatus(storm, r.Position.X, r.Position.Z, now)
				stormPill.Visible = st.phase ~= "still" or st.outside
				stormPill.Text = if st.phase == "wait"
					then "🔥 Melt closes " .. HudMath.clock(st.seconds)
					elseif st.phase == "closing" then "🔥 Closing " .. HudMath.clock(st.seconds)
					else "🔥 The Melt"
				stormPill.BackgroundColor3 = if st.phase == "closing"
					then Color3.fromRGB(150, 40, 28)
					else C.rind
				warn.Visible = st.outside
				if st.outside then
					warn.TextTransparency = 0.15 + 0.25 * (0.5 + 0.5 * math.sin(nowC * 8))
				end
			else
				stormPill.Visible = false
				warn.Visible = false
			end
			-- Herd Call
			local left = HudMath.redeployLeft(State.get("redeploy"), now)
			local sp = (State.get("spectate") or State.get("spectating"))
			local dead = left ~= nil or (type(sp) == "table" and sp.id ~= nil)
			local watch = if dead then spectateName() else nil
			specBar.Visible = watch ~= nil
			if watch then
				specLabel.Text = "👀 Spectating "
					.. watch
					.. (if left and left > 0 then " · back in " .. HudMath.clock(left) else "")
			end
			redeploy.Visible = left ~= nil and watch == nil
			if left then
				redeploy.Text = if left > 0
					then "🐘 Herd Call: back in " .. HudMath.clock(left)
					else "🐘 Herd Call: coming back!"
			end
			-- streak timeout
			if streak.Visible and nowC - lastKill > HudMath.STREAK_RESET then
				streak.Visible = false
				streakN = 0
			end
			-- objective arrow
			local downed = type(hud) == "table" and hud.downed == true
			local goal: HudMath.Goal? = nil
			if r and not downed then
				local marks = State.marks()
				local match = State.get("match")
				local ctx = {
					phase = if type(match) == "table" and match.phase then match.phase else State.phase(),
					portal = if type(marks) == "table" then marks.portal else nil,
					boss = if type(marks) == "table" then marks.boss else nil,
					champions = if type(match) == "table" then match.champions else nil,
					pois = if type(marks) == "table" then marks.pois else nil,
					storm = storm,
					now = now,
				}
				goal = HudMath.objective(ctx, r.Position.X, r.Position.Z)
			end
			if goal and r then
				local dx, dz = goal.x - r.Position.X, goal.z - r.Position.Z
				local dist = math.sqrt(dx * dx + dz * dz)
				if dist > 30 then
					local a = HudMath.arrowAngle(r.Position.X, r.Position.Z, goal.x, goal.z)
					arrowHolder.Position =
						UDim2.new(0.5, math.sin(a) * K.arrowR, 0.5, -math.cos(a) * K.arrowR)
					arrow.Rotation = math.deg(a)
					arrowLabel.Text = string.format("%s %dm", goal.label, math.floor(dist))
					arrowHolder.Visible = true
				else
					arrowHolder.Visible = false
				end
			else
				arrowHolder.Visible = false
			end
			-- wheel hover highlight (mouse)
			if wheel.Visible and Device.mode() == "kbm" then
				local sec = pointerSector()
				if sec ~= hovered then
					if hovered and slotButtons[hovered] then
						slotButtons[hovered].BorderSizePixel = 0
						local st = slotButtons[hovered]:FindFirstChildOfClass("UIStroke")
						if st then
							st.Color = C.brownDark
						end
					end
					hovered = sec
					if sec and slotButtons[sec] then
						local st = slotButtons[sec]:FindFirstChildOfClass("UIStroke")
						if st then
							st.Color = C.gold
						end
					end
				end
			end
		end)
	)
	-- expire world pings even when no new ping arrives
	table.insert(
		conns,
		task.spawn(function()
			while screen do
				task.wait(0.5)
				if #markers > 0 then
					renderPings()
				end
			end
		end)
	)
end

function CombatHudUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	for _, c in conns do
		if typeof(c) == "RBXScriptConnection" or (type(c) == "table" and c.Disconnect) then
			c:Disconnect()
		elseif typeof(c) == "thread" then
			pcall(task.cancel, c)
		end
	end
	table.clear(conns)
	if markerFolder then
		markerFolder:Destroy()
		markerFolder = nil
	end
	for _, a in workspace.Terrain:GetChildren() do
		if a:IsA("Attachment") and string.sub(a.Name, 1, 10) == "PingAnchor" then
			a:Destroy()
		end
	end
	if vignetteGui then
		vignetteGui:Destroy()
		vignetteGui = nil
	end
	if screen then
		screen.destroy()
		screen = nil
	end
end

return CombatHudUI
