--!strict
-- In-run HUD: own HP / XP / level / second winds, ability cooldown radial
-- (PC + gamepad; touch uses InputController's big button), party frames,
-- run header (cycle/stage, phase + timer, pending/banked cheese, Double or
-- Nothing badge, curse/blessing chips with tooltips) and the boss bar.

local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local Device = require(Client.Util.Device)
local State = require(Client.Controllers.State)

local HudUI = {}

local C = Theme.C
local make = Theme.make

local PHASE_TEXT: { [string]: string } = {
	Lobby = "Lobby",
	RouteVote = "Choose your route!",
	Waves = "Survive the horde!",
	Boss = "BOSS FIGHT!",
	StageClear = "Stage clear!",
	BankVote = "Bank it or gamble?",
	CycleVote = "Go home or go deeper?",
	Results = "Run over",
}

local screen: any = nil
local unsubs: { () -> () } = {}
local renderConn: RBXScriptConnection? = nil

function HudUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallHud", 10)
	local root: Frame = screen.root

	------------------------------------------------------------------
	-- Own status (top-left)
	------------------------------------------------------------------
	local status = make("Frame", {
		Name = "Status",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 10),
		Size = UDim2.fromOffset(320, 110),
		Parent = root,
	})
	local levelBadge = make("TextLabel", {
		BackgroundColor3 = C.cheese,
		Size = UDim2.fromOffset(56, 56),
		Font = Theme.FONT,
		TextSize = 26,
		TextColor3 = C.ink,
		Text = "1",
		Parent = status,
	})
	Theme.round().Parent = levelBadge
	Theme.stroke(C.brownDark, 3).Parent = levelBadge
	local hpBar = Theme.bar({ Position = UDim2.fromOffset(64, 2), Size = UDim2.fromOffset(250, 30), Parent = status }, C.hp)
	local xpBar =
		Theme.bar({ Position = UDim2.fromOffset(64, 36), Size = UDim2.fromOffset(250, 18), Parent = status }, C.xp)
	xpBar.text.TextSize = 14
	local windLabel = Theme.label({
		Position = UDim2.fromOffset(0, 62),
		Size = UDim2.fromOffset(320, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 20,
		Text = "",
		Parent = status,
	})
	Theme.textStroke().Parent = windLabel
	Theme.tooltip(windLabel, "Second Wind: get back up by yourself while downed (max 1 per stage).")

	------------------------------------------------------------------
	-- Party frames (under status)
	------------------------------------------------------------------
	local partyList = make("Frame", {
		Name = "Party",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 122),
		Size = UDim2.fromOffset(250, 220),
		Parent = root,
	})
	Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = partyList
	local partyFrames: { [number]: any } = {}

	local function partyFrame(id: number): any
		local pf = partyFrames[id]
		if pf then
			return pf
		end
		local frame = make("Frame", {
			BackgroundColor3 = C.brownDark,
			BackgroundTransparency = 0.25,
			Size = UDim2.fromOffset(250, 52),
			Parent = partyList,
		})
		Theme.corner(10).Parent = frame
		local name = Theme.label({
			Position = UDim2.fromOffset(10, 3),
			Size = UDim2.new(1, -20, 0, 22),
			TextSize = 18,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = frame,
		})
		local bar = Theme.bar({ Position = UDim2.fromOffset(10, 28), Size = UDim2.new(1, -20, 0, 16), Parent = frame }, C.hp)
		bar.text.TextSize = 12
		local tag = Theme.label({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 3),
			Size = UDim2.fromOffset(90, 22),
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = C.red,
			Parent = frame,
		})
		pf = { frame = frame, name = name, bar = bar, tag = tag }
		partyFrames[id] = pf
		return pf
	end

	local function renderParty(party: any)
		local me = State.localUserId()
		local seen: { [number]: boolean } = {}
		if type(party) == "table" then
			local order = 0
			for id, e in party do
				if id ~= me and type(e) == "table" then
					seen[id] = true
					order += 1
					local pf = partyFrame(id)
					pf.frame.LayoutOrder = if State.isBot(id, e) then 100 + order else order
					local classDef = Defs.get("Classes", e.classId)
					local botTag = if State.isBot(id, e) then "🤖 Bot · " else ""
					pf.name.Text = string.format(
						"%s%s  Lv%d %s",
						botTag,
						tostring(e.name or "Teammate"),
						tonumber(e.level) or 1,
						if classDef then "· " .. Defs.name(classDef, e.classId) else ""
					)
					local hp, maxHp = tonumber(e.hp) or 0, math.max(1, tonumber(e.maxHp) or 1)
					pf.bar.set(hp / maxHp, string.format("%d/%d", math.floor(hp), math.floor(maxHp)))
					pf.bar.setColor(if hp / maxHp < 0.3 then C.hpLow else C.hp)
					if e.dead == true then
						pf.tag.Text = "👻 OUT"
						pf.tag.TextColor3 = C.grey
					elseif e.downed == true then
						pf.tag.Text = "💫 DOWN"
						pf.tag.TextColor3 = C.red
					else
						pf.tag.Text = ""
					end
					pf.frame.BackgroundColor3 = if e.downed == true then Color3.fromRGB(110, 30, 25) else C.brownDark
				end
			end
		end
		for id, pf in partyFrames do
			if not seen[id] then
				pf.frame:Destroy()
				partyFrames[id] = nil
			end
		end
	end

	------------------------------------------------------------------
	-- Run header (top-centre)
	------------------------------------------------------------------
	local header = make("Frame", {
		Name = "Header",
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.fromOffset(560, 200),
		Parent = root,
	})
	Theme.list(Enum.FillDirection.Vertical, 4).Parent = header
	local titleRow = Theme.label({
		LayoutOrder = 1,
		Size = UDim2.fromOffset(560, 30),
		TextSize = 26,
		TextColor3 = C.cheese,
		Parent = header,
	})
	Theme.textStroke(C.brownDark, 2.5).Parent = titleRow
	local phaseRow = Theme.label({
		LayoutOrder = 2,
		Size = UDim2.fromOffset(560, 26),
		TextSize = 22,
		Parent = header,
	})
	Theme.textStroke().Parent = phaseRow
	local cheeseRow = make("Frame", {
		LayoutOrder = 3,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(560, 34),
		Parent = header,
	})
	Theme.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent =
		cheeseRow
	local cheeseLabel = Theme.label({
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 30),
		TextSize = 21,
		TextWrapped = false,
		Parent = cheeseRow,
	})
	Theme.textStroke().Parent = cheeseLabel
	Theme.tooltip(cheeseLabel, "Pending cheese is at risk until you bank it. Banked cheese is safe.")
	local donBadge = Theme.chip("×2 DOUBLE OR NOTHING", C.red, "Next stage rewards ×2 and the pending pot ×1.5 if you win. Wipe = lose ALL pending cheese.")
	donBadge.LayoutOrder = 2
	donBadge.Visible = false
	donBadge.Parent = cheeseRow
	local chipsRow = make("Frame", {
		LayoutOrder = 4,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(560, 36),
		Parent = header,
	})
	Theme.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent =
		chipsRow

	-- Boss bar
	local bossFrame = make("Frame", {
		LayoutOrder = 5,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(520, 58),
		Visible = false,
		Parent = header,
	})
	local bossName = Theme.label({
		Size = UDim2.new(1, 0, 0, 26),
		TextSize = 24,
		TextColor3 = C.cheese,
		Parent = bossFrame,
	})
	Theme.textStroke(C.brownDark, 2.5).Parent = bossName
	local bossBar = Theme.bar({ Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, 0, 0, 24), Parent = bossFrame }, C.red)

	local chipKey = ""
	local function renderChips(run: any)
		local curses = if type(run.activeCurses) == "table" then run.activeCurses else {}
		local blessings = if type(run.activeBlessings) == "table" then run.activeBlessings else {}
		local key = table.concat(curses, ",") .. "|" .. table.concat(blessings, ",")
		if key == chipKey then
			return
		end
		chipKey = key
		for _, ch in chipsRow:GetChildren() do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		local function add(id: string, isCurse: boolean, order: number)
			local def = Defs.get("Modifiers", id)
			local name = Defs.name(def, id)
			local desc = if def and def.description then tostring(def.description) else ""
			local tier = if def and def.tier then tostring(def.tier) .. " " else ""
			local tip = string.format(
				"%s%s: %s\n%s",
				tier,
				if isCurse then "Curse" else "Blessing",
				name,
				desc
			)
			local chip = Theme.chip((if isCurse then "☠ " else "✨ ") .. name, if isCurse then C.red else C.green, tip)
			chip.LayoutOrder = order
			chip.Parent = chipsRow
		end
		for i, id in curses do
			add(tostring(id), true, i)
		end
		for i, id in blessings do
			add(tostring(id), false, 100 + i)
		end
	end

	local function renderRun(run: any)
		local inRun = type(run) == "table" and run.phase ~= nil and run.phase ~= "Lobby"
		header.Visible = inRun
		status.Visible = inRun and run.phase ~= "Results"
		partyList.Visible = status.Visible
		if not inRun then
			return
		end
		local map = Defs.get("Maps", run.mapId)
		local mapText = if map then " · " .. Defs.name(map, run.mapId) else ""
		titleRow.Text = string.format(
			"Cycle %d · Stage %d/4%s",
			tonumber(run.cycle) or 1,
			tonumber(run.stageInCycle) or 1,
			mapText
		)
		cheeseLabel.Text = string.format(
			"🧀 %s pending  ·  %s banked",
			Format.int(run.pendingCheese),
			Format.int(run.bankedCheese)
		)
		donBadge.Visible = run.doubleOrNothing == true
		renderChips(run)
	end

	------------------------------------------------------------------
	-- Ability widget (bottom-centre; hidden on touch devices)
	------------------------------------------------------------------
	local ability = make("Frame", {
		Name = "Ability",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
		Size = UDim2.fromOffset(96, 96),
		BackgroundColor3 = C.cheese,
		Parent = root,
	})
	Theme.round().Parent = ability
	Theme.stroke(C.brownDark, 4).Parent = ability
	local abilityRadial = Theme.radial(ability, C.shade, 0.4)
	local abilityText = Theme.label({
		Size = UDim2.fromScale(1, 1),
		TextSize = 34,
		Text = "💥",
		ZIndex = 5,
		Parent = ability,
	})
	Theme.textStroke().Parent = abilityText
	local abilityHint = Theme.label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, -30),
		Size = UDim2.fromOffset(240, 24),
		TextSize = 16,
		Parent = ability,
	})
	Theme.textStroke().Parent = abilityHint
	local function renderAbilityHint()
		local mode = Device.mode()
		abilityHint.Text = if mode == "gamepad" then "Ability [X]" else "Ability [Space / Q / Right-click]"
	end
	renderAbilityHint()
	Device.modeChanged:Connect(renderAbilityHint)
	local function abilityTooltip()
		local profile = State.get("profile")
		local lobby = State.get("lobby")
		local me = State.localUserId()
		local classId = if type(lobby) == "table" and lobby.players and lobby.players[me]
			then lobby.players[me].classId
			elseif type(profile) == "table" then profile.selectedClass
			else nil
		local def = Defs.get("Classes", classId)
		if def and def.ability then
			abilityHint.Text = tostring(def.ability.name or "Ability")
				.. (if Device.mode() == "gamepad" then " [X]" else " [Space / Q / RMB]")
		end
	end

	------------------------------------------------------------------
	-- Downed overlay (centre)
	------------------------------------------------------------------
	local downed = make("Frame", {
		Name = "Downed",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.62),
		Size = UDim2.fromOffset(420, 170),
		BackgroundColor3 = Color3.fromRGB(90, 25, 20),
		BackgroundTransparency = 0.15,
		Visible = false,
		Parent = root,
	})
	Theme.corner(16).Parent = downed
	Theme.stroke(C.brownDark, 4).Parent = downed
	local downTitle = Theme.label({
		Position = UDim2.fromOffset(0, 8),
		Size = UDim2.new(1, 0, 0, 36),
		TextSize = 32,
		Text = "💫 You're down!",
		Parent = downed,
	})
	Theme.textStroke().Parent = downTitle
	local downSub = Theme.label({
		Position = UDim2.fromOffset(10, 44),
		Size = UDim2.new(1, -20, 0, 26),
		TextSize = 18,
		Font = Theme.FONT_BODY,
		Text = "A teammate can revive you by standing close.",
		Parent = downed,
	})
	local windButton = Theme.button("💨 Second Wind [E]", C.cheese, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.fromOffset(300, Theme.TOUCH),
		Parent = downed,
	}, function()
		local okIc, Input = pcall(require, Client.Controllers.InputController)
		if okIc then
			Input.useSecondWind()
		end
	end)

	local function renderHud(hud: any)
		if type(hud) ~= "table" then
			return
		end
		local hp, maxHp = tonumber(hud.hp) or 0, math.max(1, tonumber(hud.maxHp) or 1)
		hpBar.set(hp / maxHp, string.format("%d / %d", math.floor(hp + 0.5), math.floor(maxHp + 0.5)))
		hpBar.setColor(if hp / maxHp < 0.3 then C.hpLow else C.hp)
		local xp, toNext = tonumber(hud.xp) or 0, math.max(1, tonumber(hud.xpToNext) or 1)
		xpBar.set(xp / toNext, string.format("XP %d / %d", math.floor(xp), math.floor(toNext)))
		levelBadge.Text = tostring(tonumber(hud.level) or 1)
		local winds = tonumber(hud.secondWinds) or 0
		windLabel.Text = string.format("💨 Second Wind ×%d", winds)
		local canWind = hud.downed == true and winds > 0 and hud.secondWindReady ~= false
		downed.Visible = hud.downed == true
		windButton.Visible = canWind
		downed.Size = UDim2.fromOffset(420, if canWind then 170 else 90)
		if hud.downed == true and winds > 0 and hud.secondWindReady == false then
			downSub.Text = "Second Wind already used this stage. Hold on!"
		elseif hud.downed == true then
			downSub.Text = "A teammate can revive you by standing close."
		end
	end

	local function renderBoss(boss: any)
		if type(boss) ~= "table" then
			bossFrame.Visible = false
			return
		end
		bossFrame.Visible = true
		local def = boss.def
		local title = if type(def) == "table" and def.title then " — " .. tostring(def.title) else ""
		bossName.Text = Defs.name(def, boss.bossId) .. title
		bossBar.set(tonumber(boss.hpFrac) or 0, Format.pct(boss.hpFrac))
	end

	table.insert(unsubs, State.subscribe("run", renderRun, true))
	table.insert(unsubs, State.subscribe("hud", renderHud, true))
	table.insert(unsubs, State.subscribe("party", renderParty, true))
	table.insert(unsubs, State.subscribe("boss", renderBoss, true))
	table.insert(unsubs, State.subscribe("lobby", abilityTooltip, true))
	table.insert(unsubs, State.subscribe("profile", abilityTooltip))

	-- Per-frame: timers and cooldown radial.
	renderConn = RunService.RenderStepped:Connect(function()
		local run = State.get("run")
		if type(run) ~= "table" or run.phase == nil or run.phase == "Lobby" then
			ability.Visible = false
			return
		end
		local now = State.serverNow()
		local phaseText = PHASE_TEXT[run.phase] or tostring(run.phase)
		local endsAt = tonumber(run.phaseEndsAt)
		if endsAt and endsAt > now then
			phaseRow.Text = phaseText .. "  ⏱ " .. Format.clock(endsAt - now)
		else
			phaseRow.Text = phaseText
		end

		local inCombat = run.phase == "Waves" or run.phase == "Boss" or run.phase == "StageClear"
		ability.Visible = inCombat and not Device.hasTouch()
		if ability.Visible then
			local rem, total = State.abilityCooldown()
			abilityRadial.set(if rem > 0 then rem / total else 0)
			abilityText.Text = if rem > 0 then tostring(math.ceil(rem)) else "💥"
		end

		if downed.Visible then
			local hud = State.get("hud")
			local untilT = if type(hud) == "table" then tonumber(hud.downedUntil) else nil
			if untilT and untilT > now then
				downTitle.Text = "💫 You're down! " .. Format.clock(untilT - now)
			else
				downTitle.Text = "💫 You're down!"
			end
		end
	end)
end

function HudUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	if screen then
		screen.destroy()
		screen = nil
	end
end

return HudUI
