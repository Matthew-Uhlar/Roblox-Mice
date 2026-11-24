--!strict
-- SquadAlertsUI (iteration 7 §B 4-5, team Client):
--
--   * Death recap card: Net.S2C.DeathRecap (team Systems, Run/DeathRecap) shows
--     who downed / eliminated you and the top 3 damage sources of the last
--     window (Util/RecapModel). Top-centre, under the HUD; it hides when you
--     are revived, a new run starts, or after RecapModel.SHOW_SECONDS
--     (eliminated: while spectating, up to twice that). Tap / click closes it.
--   * Downed-squadmate edge arrows: PartyHud entries with downed = true get a
--     pink 💗 arrow on the screen edge when off screen (Util/SquadAlerts), with
--     name, distance and the bleed-out countdown. Position: the live character,
--     else the newest automatic "revive" ping (PingShown kind "revive", drawn
--     by CombatHudUI's ping markers through HudMath.PING_INFO.revive).
-- Both tolerate the remote / fields being absent.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Remotes = require(Client.Util.Remotes)
local RecapModel = require(Client.Util.RecapModel)
local SquadAlerts = require(Client.Util.SquadAlerts)
local State = require(Client.Controllers.State)

local SquadAlertsUI = {}

local C = Theme.C
local make = Theme.make
local REVIVE_COLOR = Color3.fromRGB(255, 90, 120)

local screen: any = nil
local arrowGui: ScreenGui? = nil
local card: Frame? = nil
local conns: { any } = {}
local unsubs: { () -> () } = {}
local shownAt = 0
local shownEliminated = false
local warned = false

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

----------------------------------------------------------------------
-- Death recap card
----------------------------------------------------------------------

local function hideCard()
	if card then
		card.Visible = false
	end
end

local function showRecap(payload: any)
	local view = RecapModel.view(payload)
	if not view or not screen then
		return
	end
	local U = RecapModel.UI
	if card then
		card:Destroy()
	end
	local h = RecapModel.height(#view.rows)
	local f = Theme.panel({
		Name = "DeathRecap",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 118),
		Size = UDim2.fromOffset(U.w, h),
		Parent = screen.root,
	})
	card = f
	local title = Theme.label({
		Position = UDim2.fromOffset(U.pad, U.pad),
		Size = UDim2.new(1, -2 * U.pad, 0, U.titleBox),
		TextSize = U.titleText,
		TextColor3 = if view.eliminated then C.red else C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Text = view.title,
		Parent = f,
	})
	Theme.header(title)
	Theme.label({
		Position = UDim2.fromOffset(U.pad, U.pad + U.titleBox),
		Size = UDim2.new(1, -2 * U.pad, 0, U.subBox),
		TextSize = U.subText,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = view.sub,
		Parent = f,
	})
	local y = U.pad + U.titleBox + U.subBox + 6
	for _, r in view.rows do
		local row = make("Frame", {
			Position = UDim2.fromOffset(U.pad, y),
			Size = UDim2.new(1, -2 * U.pad, 0, U.rowH),
			BackgroundColor3 = C.creamDark,
			Parent = f,
		})
		Theme.corner(6).Parent = row
		local fill = make("Frame", {
			Size = UDim2.fromScale(math.clamp(r.frac, 0.04, 1), 1),
			BackgroundColor3 = rgb(r.color),
			BackgroundTransparency = 0.55,
			Parent = row,
		})
		Theme.corner(6).Parent = fill
		Theme.label({
			Position = UDim2.fromOffset(8, 0),
			Size = UDim2.new(1, -86, 1, 0),
			TextSize = U.rowText,
			TextColor3 = C.ink,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Text = r.icon .. " " .. r.name,
			ZIndex = 2,
			Parent = row,
		})
		Theme.label({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 0),
			Size = UDim2.new(0, 74, 1, 0),
			TextSize = U.rowText,
			TextColor3 = C.ink,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = tostring(r.amount),
			ZIndex = 2,
			Parent = row,
		})
		y += U.rowH + 4
	end
	local close = make("TextButton", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		ZIndex = 5,
		Parent = f,
	}) :: TextButton
	close.Activated:Connect(hideCard)
	shownAt = os.clock()
	shownEliminated = view.eliminated
	pcall(Theme.popIn, f)
end

local function tickCard()
	local f = card
	if not f or not f.Visible then
		return
	end
	local age = os.clock() - shownAt
	local limit = RecapModel.SHOW_SECONDS * (if shownEliminated then 2 else 1)
	if age > limit then
		hideCard()
		return
	end
	if not shownEliminated then
		local hud = State.get("hud")
		if type(hud) == "table" and hud.downed ~= true and age > 0.5 then
			hideCard() -- revived
		end
	end
end

----------------------------------------------------------------------
-- Downed squadmate arrows
----------------------------------------------------------------------

type Arrow = { frame: Frame, icon: Frame?, label: TextLabel }
local arrows: { Arrow } = {}

local function arrowAt(i: number): Arrow
	local a = arrows[i]
	if a then
		return a
	end
	if not arrowGui then
		local lp = Players.LocalPlayer
		arrowGui = make("ScreenGui", {
			Name = "TrunkfallReviveArrows",
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			DisplayOrder = 5,
			Parent = lp and lp:FindFirstChildOfClass("PlayerGui"),
		}) :: ScreenGui
	end
	local f = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(40, 40),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = arrowGui,
	}) :: Frame
	local ok, icon = pcall(Theme.icon, "arrow", 24, REVIVE_COLOR, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Parent = f,
	})
	Theme.label({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(20, 20),
		TextSize = 15,
		Text = "💗",
		ZIndex = 3,
		Parent = f,
	})
	local label = Theme.label({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(150, 18),
		TextSize = 14,
		TextColor3 = C.cream,
		TextWrapped = false,
		Text = "",
		ZIndex = 3,
		Parent = f,
	})
	Theme.textStroke(C.shade, 1.5).Parent = label
	a = { frame = f, icon = if ok then icon else nil, label = label }
	arrows[i] = a
	return a
end

local function hideArrows(from: number)
	for i = from, #arrows do
		arrows[i].frame.Visible = false
	end
end

local function livePos(id: number): (number?, number?)
	local p = Players:GetPlayerByUserId(id)
	local char = p and p.Character
	local r = char and char:FindFirstChild("HumanoidRootPart")
	if r and r:IsA("BasePart") then
		return r.Position.X, r.Position.Z
	end
	return nil, nil
end

local function updateArrows()
	local cam = workspace.CurrentCamera
	if not cam or not State.inCombat() then
		hideArrows(1)
		return
	end
	local me = State.localUserId()
	local mates = SquadAlerts.downedMates(State.get("party"), me)
	local mx, mz = livePos(me)
	local now = State.serverNow()
	local pings = State.get("pings")
	local vp = cam.ViewportSize
	local used = 0
	for _, m in mates do
		if used >= SquadAlerts.MAX_ARROWS then
			break
		end
		local x, z = livePos(m.id)
		if x == nil then
			x, z = SquadAlerts.revivePos(pings, m.id, now)
		end
		if x and z then
			local sp = cam:WorldToViewportPoint(Vector3.new(x, 3, z))
			local ax, ay, ang = SquadAlerts.arrow(sp.X, sp.Y, sp.Z < 0, vp.X, vp.Y, nil, 40, 60)
			if ax and ay and ang then
				used += 1
				local a = arrowAt(used)
				a.frame.Position = UDim2.fromOffset(ax, ay)
				if a.icon then
					a.icon.Rotation = ang + 90
				end
				local dist = if mx and mz then math.sqrt((x - mx) ^ 2 + (z - (mz :: number)) ^ 2) else nil
				a.label.Text = SquadAlerts.label(m.name, dist, m.downedUntil, now)
				local r = math.rad(ang)
				a.label.Position = UDim2.new(0.5, -math.cos(r) * 70, 0.5, -math.sin(r) * 26)
				a.frame.Visible = true
			end
		end
	end
	hideArrows(used + 1)
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function SquadAlertsUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallSquadAlerts", 14)
	if Remotes.S2C.DeathRecap then
		table.insert(conns, Remotes.on(Remotes.S2C.DeathRecap, showRecap))
	end
	table.insert(
		unsubs,
		State.subscribe("run", function(run)
			local phase = if type(run) == "table" then run.phase else nil
			if phase == nil or phase == "Lobby" or phase == "Results" then
				hideCard()
			end
		end)
	)
	local acc = 0
	table.insert(
		conns,
		RunService.RenderStepped:Connect(function(dt)
			acc += dt
			if acc < 0.1 then
				return
			end
			acc = 0
			pcall(tickCard)
			local ok, err = pcall(updateArrows)
			if not ok then
				hideArrows(1)
				if not warned then
					warned = true
					warn("[Trunkfall] SquadAlertsUI: " .. tostring(err))
				end
			end
		end)
	)
end

-- Test / QA hook: show a card from a sample payload.
function SquadAlertsUI.showRecap(payload: any)
	showRecap(payload)
end

function SquadAlertsUI.destroy()
	for _, c in conns do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(conns)
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	if arrowGui then
		arrowGui:Destroy()
		arrowGui = nil
	end
	table.clear(arrows)
	if screen then
		screen.destroy()
		screen = nil
	end
	card = nil
end

return SquadAlertsUI
