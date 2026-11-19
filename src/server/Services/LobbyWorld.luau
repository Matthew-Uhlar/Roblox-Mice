--!strict
-- LobbyWorld (R4 Graphics): the "Herd Sanctuary" lobby island (GDD-v2 §6).
--
--   LobbyWorld.build(center?: Vector3) -> {
--       spawn: SpawnLocation, readyPad: BasePart, squadPads: {[1..4] = BasePart},
--       statusLabel: TextLabel, model: Model, center: Vector3 }
--   Builds once (a second call returns the same parts). LobbyService (R1) calls it
--   instead of building its own pad: recolour `readyPad` for the ready state and
--   write `statusLabel.Text`. Default centre (0, 0, -1400): v3 arenas reach ~520 studs; LobbyService adopts the returned spawn as its CENTER.
--
-- Terrain island (grass, flat at Y = 0 inside the plaza ring) with a cheese plaza
-- (Sandstone tinted cheese-gold by the lobby lighting preset), the ready pad in
-- the middle (radius 10, the bots stand on a ring of 12 around it), 4 squad pads
-- with banners on the diagonals, a class showcase podium with a statue of every
-- class (BotModel showcase), the TRUNKFALL sign, lamp posts, gardens, a rim of
-- hills with trees and water beyond, and an invisible wall ring at 44 studs.
--
-- v4 polish (team G):
--   * pads: the ready pad and squad pads are SmoothPlastic in their colour with a
--     thin Neon rim (no more bloom-blown white discs) and rising motes;
--   * a LEADERBOARD WALL on the east edge facing the plaza: 3 boards
--     (SurfaceGuis, top LeaderboardWall.ROWS rows). Fed server-side: every
--     LEADERBOARD_REFRESH s it reads LeaderboardService.getTop (whichever of
--     LobbyWorld.BOARD_PREFS exist), and LobbyWorld.setLeaderboards(payload)
--     accepts the S2C `Leaderboards` shape {[board] = {{name, value}}} directly;
--   * a SHOP KIOSK on the west edge: a cheese stall with a ProximityPrompt
--     named "ShopKiosk" (attributes OpenShop = true, ShopTab = "Featured").
--     The client (UI/ShopUI) opens the shop when it triggers; nothing is sold
--     by the prompt itself;
--   * a spawn plaza: a welcome arch over the spawn, planters and a cheese fountain.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Visuals = script.Parent.Parent:WaitForChild("Visuals")
local Build = require(Visuals:WaitForChild("Build")) :: any
local Props = require(Visuals:WaitForChild("Props")) :: any
local Terra = require(Visuals:WaitForChild("Terra")) :: any
local BotModel = require(Visuals:WaitForChild("BotModel")) :: any
local AssetLoader = require(Visuals:WaitForChild("AssetLoader")) :: any

local LobbyWorld = {}

LobbyWorld.NAME = "LobbyPad" -- kept: LobbyService and tests look for workspace.LobbyPad
LobbyWorld.DEFAULT_CENTER = Vector3.new(0, 0, -1400) -- v3: clear of the 400-stud arenas and their terrain
LobbyWorld.WALL_RADIUS = 44
LobbyWorld.READY_RADIUS = 10
LobbyWorld.KIOSK_PROMPT = "ShopKiosk" -- the client opens the shop on this prompt
LobbyWorld.LEADERBOARD_REFRESH = 60
LobbyWorld.LEADERBOARD_ROWS = 8
-- Boards shown on the wall, in order of preference (the first 3 that exist).
LobbyWorld.BOARD_PREFS = {
	{ id = "wins", title = "🏆 MOST WINS" },
	{ id = "bestStage", title = "🧭 DEEPEST RUN" },
	{ id = "championKills", title = "👑 CHAMPION SLAYERS" },
	{ id = "heroDowns", title = "⚔ TOP BRAWLERS" },
	{ id = "lastHerd", title = "🐘 LAST HERD" },
	{ id = "deepestCycle", title = "🧭 DEEPEST CYCLE" },
}

local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local M = Enum.Material
local rgb = Color3.fromRGB

local GOLD = rgb(255, 201, 60)

local function optional(path: { string }): any
	local ok, mod = pcall(function()
		local cur: Instance = ReplicatedStorage:WaitForChild("Shared")
		for _, seg in path do
			local nxt = cur:FindFirstChild(seg)
			if not nxt then
				return nil
			end
			cur = nxt
		end
		return if cur:IsA("ModuleScript") then require(cur) :: any else nil
	end)
	return if ok then mod else nil
end

local Classes: any = optional({ "Config", "Classes" })
local Squads: any = optional({ "Util", "Squads" })
local RngMod: any = optional({ "Util", "Rng" })

local built: any = nil

local PAL = {
	rock = rgb(160, 150, 135),
	rockDark = rgb(115, 108, 98),
	moss = rgb(110, 170, 70),
	leaves = { rgb(86, 168, 68), rgb(118, 190, 80), rgb(150, 210, 95) },
	trunk = rgb(120, 82, 50),
	accent = GOLD,
	glow = rgb(255, 220, 130),
	flower = { rgb(255, 255, 255), rgb(255, 210, 60), rgb(255, 130, 170), rgb(170, 140, 255) },
}

local function squadColor(i: number): Color3
	local s = Squads and type(Squads.get) == "function" and Squads.get(i)
	return Build.rgb(
		s and s.color,
		({ rgb(255, 200, 60), rgb(245, 240, 220), rgb(80, 150, 255), rgb(235, 70, 60) })[i]
	)
end

local function squadName(i: number): string
	local s = Squads and type(Squads.get) == "function" and Squads.get(i)
	return if s and type(s.name) == "string" then s.name else ("Squad " .. i)
end

local function signText(part: BasePart, face: Enum.NormalId, title: string, sub: string?): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = part
	local t = Instance.new("TextLabel")
	t.Name = "Title"
	t.Size = UDim2.fromScale(1, if sub then 0.55 else 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.TextColor3 = rgb(255, 214, 102)
	t.TextStrokeTransparency = 0.2
	t.TextStrokeColor3 = rgb(91, 58, 30)
	t.Text = title
	t.Parent = gui
	local s = Instance.new("TextLabel")
	s.Name = "Status"
	s.Position = UDim2.fromScale(0, 0.55)
	s.Size = UDim2.fromScale(1, 0.45)
	s.BackgroundTransparency = 1
	s.Font = Enum.Font.FredokaOne
	s.TextScaled = true
	s.TextColor3 = Color3.new(1, 1, 1)
	s.TextStrokeTransparency = 0.3
	s.Text = sub or ""
	s.Visible = sub ~= nil
	s.Parent = gui
	return s
end

local function lamp(m: Instance, cf: CFrame)
	Build.ucyl(m, 0.4, 1.4, cf * CF(0, 0.2, 0), rgb(70, 70, 76), M.Slate)
	Build.ucyl(m, 6, 0.4, cf * CF(0, 3.2, 0), rgb(60, 55, 52), M.Metal)
	Build.cyl(m, 1.6, 0.2, cf * CF(0.6, 6, 0), rgb(60, 55, 52), M.Metal)
	local glass = Build.block(
		m,
		V3(0.9, 1.1, 0.9),
		cf * CF(1.3, 5.3, 0),
		rgb(255, 225, 150),
		M.Neon,
		{ shadow = false }
	)
	Build.wedge(m, V3(1.2, 0.5, 1.2), cf * CF(1.3, 6.1, 0), rgb(60, 55, 52), M.Metal)
	Build.light(glass, rgb(255, 210, 140), 18, 1.4, true)
end

-- Leaderboard wall ------------------------------------------------------------------

local boardGuis: { [string]: { rows: { TextLabel }, title: TextLabel } } = {}
local boardOrder: { string } = {}

local function boardTitle(id: string): string
	for _, b in LobbyWorld.BOARD_PREFS do
		if b.id == id then
			return b.title
		end
	end
	return string.upper(id)
end

local function fmtValue(v: any): string
	local n = tonumber(v)
	if not n then
		return tostring(v or "")
	end
	n = math.floor(n + 0.5)
	local str = tostring(math.abs(n))
	local out = str:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return (if n < 0 then "-" else "") .. out
end

local function boardPanel(
	part: BasePart,
	slot: number,
	title: string
): { rows: { TextLabel }, title: TextLabel }
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Board" .. slot
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.Parent = part
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = rgb(40, 26, 16)
	frame.BackgroundTransparency = 0.15
	frame.Size = UDim2.fromScale(1 / 3 - 0.02, 0.96)
	frame.Position = UDim2.fromScale((slot - 1) / 3 + 0.01, 0.02)
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.04, 0)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = GOLD
	stroke.Thickness = 4
	stroke.Parent = frame
	local t = Instance.new("TextLabel")
	t.Name = "Title"
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(0.94, 0.14)
	t.Position = UDim2.fromScale(0.03, 0.02)
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.TextColor3 = GOLD
	t.TextStrokeTransparency = 0.3
	t.Text = title
	t.Parent = frame
	local rows = {}
	local n = LobbyWorld.LEADERBOARD_ROWS
	for i = 1, n do
		local r = Instance.new("TextLabel")
		r.Name = "Row" .. i
		r.BackgroundColor3 = if i % 2 == 0 then rgb(70, 48, 30) else rgb(58, 40, 24)
		r.BackgroundTransparency = 0.2
		r.BorderSizePixel = 0
		r.Size = UDim2.fromScale(0.94, 0.8 / n - 0.01)
		r.Position = UDim2.fromScale(0.03, 0.17 + (i - 1) * 0.8 / n)
		r.Font = Enum.Font.FredokaOne
		r.TextScaled = true
		r.TextXAlignment = Enum.TextXAlignment.Left
		r.TextColor3 = if i == 1 then GOLD elseif i <= 3 then rgb(235, 225, 210) else rgb(205, 190, 170)
		r.Text = if i == 1 then "  Be the first!" else ""
		r.Parent = frame
		table.insert(rows, r)
	end
	return { rows = rows, title = t }
end

-- payload: {[board] = {{name, value}}} (the S2C Leaderboards shape; getTop
-- entries {rank, userId, name, value} also work). Unknown boards are ignored.
function LobbyWorld.setLeaderboards(payload: any)
	if type(payload) ~= "table" then
		return
	end
	for id, list in payload do
		local b = boardGuis[tostring(id)]
		if b and type(list) == "table" then
			for i, row in b.rows do
				local e = list[i]
				if type(e) == "table" then
					local medal = if i == 1
						then "🥇"
						elseif i == 2 then "🥈"
						elseif i == 3 then "🥉"
						else tostring(i) .. "."
					row.Text =
						string.format("  %s %s  ·  %s", medal, tostring(e.name or "?"), fmtValue(e.value))
				else
					row.Text = if i == 1 and #list == 0 then "  Be the first!" else ""
				end
			end
		end
	end
end

local function refreshBoards()
	local inst = script.Parent:FindFirstChild("LeaderboardService")
	if not inst or not inst:IsA("ModuleScript") then
		return
	end
	local ok, LS = pcall(require, inst)
	if not ok or type(LS) ~= "table" or type((LS :: any).getTop) ~= "function" then
		return
	end
	local payload = {}
	for _, id in boardOrder do
		local okTop, top = pcall((LS :: any).getTop, id)
		if okTop and type(top) == "table" then
			payload[id] = top
		end
	end
	LobbyWorld.setLeaderboards(payload)
end

local function chooseBoards(): { string }
	local available: { [string]: boolean }? = nil
	local inst = script.Parent:FindFirstChild("LeaderboardService")
	if inst and inst:IsA("ModuleScript") then
		local ok, LS = pcall(require, inst)
		if ok and type(LS) == "table" and type((LS :: any).BOARDS) == "table" then
			available = {}
			for k in (LS :: any).BOARDS do
				(available :: any)[k] = true
			end
		end
	end
	local out = {}
	for _, b in LobbyWorld.BOARD_PREFS do
		if #out < 3 and (available == nil or available[b.id]) then
			table.insert(out, b.id)
		end
	end
	return out
end

local function leaderboardWall(model: Model, c: Vector3)
	local m = Build.model(model, "LeaderboardWall")
	local p = c + V3(39, 0, 0)
	local look = CFrame.lookAt(p, c)
	-- stone frame with a gold cornice, the boards on the inner face
	Build.block(m, V3(20, 0.8, 3), look * CF(0, 0.4, 0), rgb(150, 130, 100), M.Slate)
	for _, s in { -1, 1 } do
		Build.block(m, V3(1.4, 11, 1.6), look * CF(s * 9.6, 5.9, 0.2), rgb(120, 82, 46), M.WoodPlanks)
	end
	Build.block(m, V3(21, 1, 2), look * CF(0, 11.6, 0.2), GOLD, M.Metal, { shadow = false })
	Props.cheeseWedge(m, look * CF(0, 12.1, 0.2), 3, 1.6, nil)
	local panel = Build.block(m, V3(18.4, 10, 0.5), look * CF(0, 6.2, 0.4), rgb(70, 46, 26), M.Wood, {
		name = "BoardPanel",
	})
	boardOrder = chooseBoards()
	for i, id in boardOrder do
		boardGuis[id] = boardPanel(panel, i, boardTitle(id))
	end
	task.spawn(function()
		while true do
			pcall(refreshBoards)
			task.wait(LobbyWorld.LEADERBOARD_REFRESH)
			if not model:IsDescendantOf(game) then
				break
			end
		end
	end)
end

-- Shop kiosk ------------------------------------------------------------------------

local function shopKiosk(model: Model, c: Vector3, rng: any)
	local m = Build.model(model, "ShopKiosk")
	local p = c + V3(-37, 0, 0)
	local look = CFrame.lookAt(p, c)
	-- counter, posts, a striped awning and a big SHOP sign
	local counter = Build.block(m, V3(10, 3, 3), look * CF(0, 1.5, -0.5), rgb(160, 110, 60), M.WoodPlanks, {
		name = "Counter",
		collide = true,
	})
	Build.block(m, V3(10.4, 0.3, 3.4), look * CF(0, 3.15, -0.5), GOLD, M.SmoothPlastic)
	for _, s in { -1, 1 } do
		Build.ucyl(m, 8, 0.5, look * CF(s * 4.8, 4, 1.2), rgb(110, 76, 44), M.Wood)
	end
	for k = 0, 5 do
		local col = if k % 2 == 0 then rgb(214, 58, 52) else rgb(250, 240, 220)
		Build.wedge(
			m,
			V3(1.75, 1.4, 4.4),
			look * CF(-4.4 + k * 1.75, 8.6, -0.4) * ANG(0, math.pi, 0),
			col,
			M.Fabric,
			{ shadow = false }
		)
	end
	local sign = Build.block(m, V3(7, 2.2, 0.4), look * CF(0, 10.4, 1.1), rgb(120, 82, 46), M.WoodPlanks)
	signText(sign, Enum.NormalId.Front, "🛒 SHOP")
	-- goods on the counter
	Props.cheeseWedge(m, look * CF(-2.8, 3.3, -0.6), 1.6, 1, rng)
	Build.egg(m, V3(1.4, 1.2, 1.4), look * CF(0, 3.9, -0.6), rgb(255, 214, 102), M.Neon, { shadow = false })
	Build.ball(m, 1.1, look * CF(2.7, 3.85, -0.6), rgb(120, 200, 255), M.Glass, { shadow = false })
	local glow = Build.block(m, V3(0.4, 0.4, 0.4), look * CF(0, 6.5, -0.5), GOLD, M.SmoothPlastic, {
		transparency = 1,
		shadow = false,
	})
	Build.light(glow, rgb(255, 214, 140), 14, 1.2)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = LobbyWorld.KIOSK_PROMPT
	prompt.ActionText = "Open Shop"
	prompt.ObjectText = "Cheese Shop"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt:SetAttribute("OpenShop", true)
	prompt:SetAttribute("ShopTab", "Featured")
	prompt.Parent = counter
end

-- Spawn plaza: a welcome arch over the spawn path, planters and a fountain -------------

local function spawnPlaza(model: Model, c: Vector3, rng: any)
	local m = Build.model(model, "SpawnPlaza")
	m:AddTag("Decor")
	local p = c + V3(0, 0, 33)
	for _, s in { -1, 1 } do
		Build.block(m, V3(1.6, 10, 1.6), CF(p + V3(s * 6, 5, 0)), rgb(235, 220, 190), M.Sandstone)
		Build.ball(m, 2, CF(p + V3(s * 6, 10.6, 0)), GOLD, M.SmoothPlastic)
	end
	local beam = Build.block(m, V3(14, 1.6, 1.4), CF(p + V3(0, 9.4, 0)), rgb(120, 82, 46), M.WoodPlanks)
	signText(beam, Enum.NormalId.Back, "WELCOME TO THE HERD")
	-- planters along the path
	for _, s in { -1, 1 } do
		for k = 0, 1 do
			local q = c + V3(s * 8, 0, 14 + k * 10)
			Build.block(m, V3(3, 1, 3), CF(q + V3(0, 0.5, 0)), rgb(150, 100, 60), M.WoodPlanks)
			if rng then
				Props.DECOR.flower(m, q.X, q.Z, 1.2, rng, PAL)
			end
		end
	end
	-- cheese fountain (south-east, beside the path)
	local f = c + V3(16, 0, 30)
	Build.ucyl(m, 1.2, 8, CF(f + V3(0, 0.6, 0)), rgb(220, 205, 175), M.Marble)
	Build.ucyl(
		m,
		0.2,
		7,
		CF(f + V3(0, 1.2, 0)),
		rgb(255, 205, 80),
		M.Glass,
		{ transparency = 0.2, shadow = false }
	)
	Build.ucyl(m, 3, 1, CF(f + V3(0, 2.6, 0)), rgb(220, 205, 175), M.Marble)
	local spout = Build.ball(m, 1.4, CF(f + V3(0, 4.2, 0)), rgb(255, 214, 102), M.Neon, { shadow = false })
	Build.emitter(spout, {
		name = "Fountain",
		texture = Build.TEX.sparkles,
		color = Build.cs(rgb(255, 214, 102), rgb(255, 170, 40)),
		size = Build.ns(0.45, 0.1),
		lifetime = NumberRange.new(0.8, 1.2),
		rate = 18,
		speed = NumberRange.new(6, 9),
		spread = Vector2.new(25, 25),
		accel = Vector3.new(0, -18, 0),
		lightEmission = 0.5,
	})
end

-- iter2: the Cheese Ladder (difficulty tiers, docs/iter/2/ALIGNMENT.md A1) --------
-- A tower of 11 cheese wheels north-east of the plaza, Mild at the bottom and
-- Doomwheel at the top. The selected tier glows with a ring, a light and a sign.
-- Select with LobbyWorld.setTier(n, unlocked?) or the attribute "Tier" (and
-- "TierUnlocked") on workspace.LobbyPad (M2 / LobbyService set it).
LobbyWorld.TIERS = {
	{ name = "Mild", color = rgb(250, 238, 200) },
	{ name = "Medium", color = rgb(255, 222, 130) },
	{ name = "Sharp", color = rgb(255, 201, 60) },
	{ name = "Extra Sharp", color = rgb(250, 170, 40) },
	{ name = "Aged", color = rgb(225, 140, 40) },
	{ name = "Smoked", color = rgb(170, 105, 50) },
	{ name = "Pungent", color = rgb(150, 160, 70) },
	{ name = "Stinky", color = rgb(110, 140, 80) },
	{ name = "Scorched", color = rgb(200, 70, 40) },
	{ name = "Moldy", color = rgb(70, 120, 140) },
	{ name = "Doomwheel", color = rgb(90, 30, 40) },
}
local ladder: { wheels: { BasePart }, ring: BasePart, light: PointLight, label: TextLabel, sub: TextLabel }? =
	nil

function LobbyWorld.setTier(tier: number?, unlocked: number?)
	local l = ladder
	if not l then
		return
	end
	local n = math.clamp(math.floor(tonumber(tier) or 2), 1, #LobbyWorld.TIERS)
	local top = math.clamp(math.floor(tonumber(unlocked) or n), n, #LobbyWorld.TIERS)
	for i, w in l.wheels do
		local def = LobbyWorld.TIERS[i]
		w.Color = if i <= top then def.color else def.color:Lerp(rgb(70, 70, 70), 0.65)
		w.Material = if i == n then M.Neon else M.SmoothPlastic
	end
	local sel = l.wheels[n]
	l.ring.CFrame = sel.CFrame * CF(-0.05, 0, 0)
	l.light.Color = LobbyWorld.TIERS[n].color
	l.label.Text = string.upper(LobbyWorld.TIERS[n].name)
	l.label.TextColor3 = LobbyWorld.TIERS[n].color:Lerp(Color3.new(1, 1, 1), 0.3)
	l.sub.Text = string.format("Tier %d of %d", n, #LobbyWorld.TIERS)
end

local function cheeseLadder(model: Model, c: Vector3)
	local m = Build.model(model, "CheeseLadder")
	local a = math.rad(-32)
	local p = c + V3(math.cos(a) * 40, 0, math.sin(a) * 40)
	local look = CFrame.lookAt(p, c)
	Build.ucyl(m, 0.6, 7, look * CF(0, 0.3, 0), rgb(200, 190, 170), M.Marble)
	Build.ucyl(m, 12.5, 0.6, look * CF(0, 6.5, 1.2), rgb(120, 82, 46), M.Wood)
	local wheels = {}
	for i, def in LobbyWorld.TIERS do
		local d = 4.2 - i * 0.18
		local w = Build.cyl(
			m,
			0.9,
			d,
			look * CF(0, 0.95 + (i - 1) * 1.02, 0) * ANG(0, 0, math.pi / 2),
			def.color,
			M.SmoothPlastic,
			{
				name = "Tier" .. i,
			}
		)
		w:SetAttribute("Tier", i)
		table.insert(wheels, w)
		-- a notch (wedge cut) on alternate sides makes the stack read as cheese
		Build.wedge(
			m,
			V3(0.8, 0.86, d * 0.3),
			look * CF((i % 2 * 2 - 1) * d * 0.3, 0.95 + (i - 1) * 1.02, -d * 0.3),
			def.color:Lerp(rgb(255, 255, 255), 0.2),
			M.SmoothPlastic,
			{ shadow = false }
		)
	end
	local ring = Build.cyl(
		m,
		0.3,
		4.9,
		wheels[2].CFrame,
		GOLD,
		M.Neon,
		{ shadow = false, name = "TierRing", transparency = 0.25 }
	)
	local light = Build.light(ring, GOLD, 16, 2) :: PointLight
	local sign = Build.block(
		m,
		V3(7, 2.2, 0.3),
		look * CF(0, 13.5, 0.4),
		rgb(120, 82, 46),
		M.WoodPlanks,
		{ name = "TierSign" }
	)
	local sub = signText(sign, Enum.NormalId.Front, "MEDIUM", "Tier 2 of 11")
	local label = sub.Parent and sub.Parent:FindFirstChild("Title")
	ladder = {
		wheels = wheels,
		ring = ring,
		light = light,
		label = label :: TextLabel,
		sub = sub,
	}
	local function sync()
		LobbyWorld.setTier(model:GetAttribute("Tier") :: any, model:GetAttribute("TierUnlocked") :: any)
	end
	model:GetAttributeChangedSignal("Tier"):Connect(sync)
	model:GetAttributeChangedSignal("TierUnlocked"):Connect(sync)
	sync()
end

-- Thin neon rim ring on a pad (v4: the pad top is plain colour, the glow is the rim)
local function padRim(parent: Instance, center: CFrame, r: number, color: Color3, y: number, segs: number)
	for k = 0, segs - 1 do
		local a = k / segs * math.pi * 2
		local p = (center * CF(math.cos(a) * r, y, math.sin(a) * r)).Position
		local cpos = (center * CF(0, y, 0)).Position
		Build.block(
			parent,
			V3(2 * math.pi * r / segs * 0.8, 0.1, 0.6),
			CFrame.lookAt(p, cpos) * ANG(0, math.rad(90), 0),
			color,
			M.Neon,
			{ shadow = false, name = "Rim" }
		)
	end
end

function LobbyWorld.build(center: Vector3?): any
	if built and built.model and built.model.Parent then
		return built
	end
	local c = center or LobbyWorld.DEFAULT_CENTER
	local o = CF(c)
	local rng = if RngMod then RngMod.new(4242) else nil

	local model = Instance.new("Model")
	model.Name = LobbyWorld.NAME
	pcall(AssetLoader.preload) -- generated meshes (if any) for the client renderers

	-- Lighting first (also tints the terrain materials used below).
	local ls = script.Parent:FindFirstChild("LightingService")
	if ls and ls:IsA("ModuleScript") then
		local ok, mod = pcall(require, ls)
		if ok and type(mod) == "table" and type((mod :: any).apply) == "function" then
			pcall((mod :: any).apply, "lobby")
		end
	end

	-- Terrain island ------------------------------------------------------------------
	Terra.clearBox(c + V3(0, 30, 0), V3(300, 120, 300))
	Terra.cylinder(o * CF(0, -12, 0), 20, 112, M.Rock)
	Terra.cylinder(o * CF(0, -6, 0), 10, 140, M.Air)
	Terra.cylinder(o * CF(0, -8, 0), 4, 140, M.Sand)
	Terra.cylinder(o * CF(0, -4.5, 0), 5, 140, M.Water)
	Terra.cylinder(o * CF(0, -4, 0), 8, 100, M.Sand)
	Terra.cylinder(o * CF(0, -2, 0), 4, 96, M.Grass)
	Terra.paint(c.X, c.Z, 38, M.Sandstone)
	for i = 0, 3 do
		local a = math.rad(45 + i * 90)
		for k = 0, 8 do
			local d = 40 + k * 4
			Terra.paint(c.X + math.cos(a) * d, c.Z + math.sin(a) * d, 3, M.Ground)
		end
	end
	-- rim hills (outside the wall ring)
	for i = 0, 23 do
		local a = i / 24 * math.pi * 2
		local d = 70 + (if rng then rng:range(-6, 8) else 0)
		local r = 14 + (if rng then rng:range(-3, 6) else 0)
		Terra.ball(c + V3(math.cos(a) * d, -r * 0.45, math.sin(a) * d), r, M.Grass)
	end
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2 + 0.2
		Terra.ball(c + V3(math.cos(a) * 78, 2, math.sin(a) * 78), 9, M.Rock)
	end

	-- Plaza ---------------------------------------------------------------------------
	-- Safety floor (invisible) so the lobby works even without terrain.
	Build.ucyl(model, 2, 100, o * CF(0, -1.05, 0), rgb(255, 214, 102), M.SmoothPlastic, {
		name = "Floor",
		collide = true,
		transparency = if Terra.ok() then 1 else 0,
		shadow = false,
	})
	local plaza = Build.model(model, "Plaza")
	for i, r in { 36, 30.5, 22 } do
		local col = ({ rgb(206, 150, 84), rgb(246, 222, 160), rgb(238, 206, 140) })[i]
		Build.ucyl(
			plaza,
			0.12 + i * 0.02,
			r * 2,
			o * CF(0, 0.05 + i * 0.02, 0),
			col,
			if i == 2 then M.Marble else M.Sandstone,
			{
				shadow = false,
			}
		)
	end
	-- cheese holes inlaid in the plaza
	if rng then
		for _ = 1, 22 do
			local a, d = rng:range(0, 6.28), rng:range(13, 29)
			local s = rng:range(1, 2.4)
			Build.ucyl(
				plaza,
				0.06,
				s,
				o * CF(math.cos(a) * d, 0.13, math.sin(a) * d),
				Props.HOLE,
				M.SmoothPlastic,
				{ shadow = false }
			)
		end
	end
	-- brass compass inlay
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		local p = c + V3(math.cos(a) * 16, 0.16, math.sin(a) * 16)
		Build.block(
			plaza,
			V3(if i % 2 == 0 then 6 else 3, 0.05, 0.4),
			CFrame.lookAt(p, c + V3(0, 0.16, 0)),
			rgb(200, 150, 60),
			M.Metal,
			{
				shadow = false,
			}
		)
	end

	-- Ready pad (LobbyService recolours it)
	Build.ucyl(
		model,
		0.3,
		LobbyWorld.READY_RADIUS * 2 + 2,
		o * CF(0, 0.16, 0),
		rgb(110, 80, 50),
		M.Wood,
		{ shadow = false }
	)
	local readyPad = Build.ucyl(
		model,
		0.32,
		LobbyWorld.READY_RADIUS * 2,
		o * CF(0, 0.2, 0),
		rgb(120, 120, 120),
		M.SmoothPlastic,
		{
			name = "ReadyCircle",
			shadow = false,
		}
	)
	padRim(model, o, LobbyWorld.READY_RADIUS + 0.4, GOLD, 0.37, 28)
	Build.ucyl(
		model,
		0.34,
		LobbyWorld.READY_RADIUS * 1.2,
		o * CF(0, 0.22, 0),
		GOLD,
		M.Marble,
		{ shadow = false, name = "ReadyEmblem" }
	)
	Props.cheeseWedge(model, o * CF(0, 0.3, 1.5), 6, 0.35, rng)
	Build.emitter(readyPad, {
		name = "ReadyGlow",
		texture = Build.TEX.sparkles,
		color = Build.cs(GOLD, Color3.new(1, 1, 1)),
		size = Build.ns(0.5, 0),
		lifetime = NumberRange.new(1.2, 2),
		rate = 6,
		speed = NumberRange.new(1.5, 3),
		lightEmission = 1,
		shape = Enum.ParticleEmitterShape.Cylinder,
		shapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
	})

	-- Squad pads on the diagonals, banners behind them
	local squadPads = {}
	for i = 1, 4 do
		local a = math.rad(({ 225, 315, 45, 135 })[i])
		local dir = V3(math.cos(a), 0, math.sin(a))
		local p = c + dir * 25
		local col = squadColor(i)
		local pm = Build.model(model, "SquadPad" .. i)
		pm:SetAttribute("Squad", i)
		Build.ucyl(pm, 0.4, 13, CF(p) * CF(0, 0.2, 0), rgb(90, 85, 80), M.Slate, { shadow = false })
		local pad = Build.ucyl(pm, 0.44, 11, CF(p) * CF(0, 0.24, 0), col, M.SmoothPlastic, {
			name = "Pad",
			transparency = 0.1,
			shadow = false,
		})
		pad:SetAttribute("Squad", i)
		padRim(pm, CF(p), 5.8, col, 0.44, 16)
		Build.emitter(pad, {
			name = "Motes",
			texture = Build.TEX.sparkles,
			color = Build.cs(col, Color3.new(1, 1, 1)),
			size = Build.ns(0.35, 0),
			transparency = Build.ns(0.2, 1),
			lifetime = NumberRange.new(1.2, 1.8),
			rate = 6,
			speed = NumberRange.new(1.5, 2.5),
			lightEmission = 0.8,
			shape = Enum.ParticleEmitterShape.Disc,
			shapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
		})
		squadPads[i] = pad
		for _, s in { -1, 1 } do
			local side = V3(-dir.Z, 0, dir.X)
			local bp = p + dir * 7 + side * s * 4
			Props.banner(pm, CFrame.lookAt(bp, bp - dir), col, 9)
		end
		local plate = Build.block(
			pm,
			V3(6, 1.4, 0.3),
			CFrame.lookAt(p + dir * 7 + V3(0, 1, 0), p + V3(0, 1, 0)),
			rgb(110, 76, 44),
			M.Wood
		)
		signText(plate, Enum.NormalId.Front, squadName(i))
	end

	-- Class showcase podium (north side, facing the plaza)
	local podium = Build.model(model, "ClassShowcase")
	local ids = if Classes and type(Classes.ORDER) == "table" then Classes.ORDER else { "elephante" }
	local n = #ids
	Build.block(podium, V3(64, 1, 12), o * CF(0, 0.5, -40), rgb(200, 190, 170), M.Marble)
	Build.block(podium, V3(60, 1, 9), o * CF(0, 1.5, -41), rgb(225, 215, 195), M.Marble)
	Build.block(podium, V3(64.2, 0.3, 0.6), o * CF(0, 1.05, -34), GOLD, M.Metal, { shadow = false })
	for i, cid in ids do
		local x = (i - (n + 1) / 2) * 8.4
		local base = o * CF(x, 2, -41)
		Build.ucyl(podium, 1.2, 6.4, base * CF(0, 0.6, 0), rgb(240, 232, 215), M.Marble)
		local def = Classes and type(Classes.get) == "function" and Classes.get(cid)
		local col = Build.rgb(def and def.color, GOLD)
		Build.ucyl(podium, 0.15, 6.6, base * CF(0, 1.25, 0), col, M.Neon, { shadow = false })
		local ok, statue = pcall(
			BotModel.build,
			{ id = -1, name = cid, classId = cid },
			nil,
			{ showcase = true }
		)
		if ok and statue then
			statue:PivotTo(base * CF(0, 1.3, 0) * ANG(0, math.pi, 0))
			statue.Parent = podium
		end
		local plaque = Build.block(
			podium,
			V3(5.4, 1, 0.25),
			base * CF(0, 0.6, 3.25),
			rgb(110, 76, 44),
			M.Wood,
			{ shadow = false }
		)
		signText(plaque, Enum.NormalId.Back, if def and type(def.name) == "string" then def.name else cid)
		local spot = Build.block(
			podium,
			V3(0.4, 0.4, 0.4),
			base * CF(0, 12, 3),
			col,
			M.SmoothPlastic,
			{ transparency = 1, shadow = false }
		)
		local sl = Instance.new("SpotLight")
		sl.Face = Enum.NormalId.Bottom
		sl.Angle = 50
		sl.Range = 16
		sl.Brightness = 2
		sl.Color = col:Lerp(Color3.new(1, 1, 1), 0.5)
		sl.Parent = spot
	end

	-- TRUNKFALL sign above the showcase
	local signM = Build.model(model, "Sign")
	for _, s in { -1, 1 } do
		Build.ucyl(signM, 16, 1, o * CF(s * 13, 8, -48), rgb(110, 76, 44), M.Wood)
	end
	local sign = Build.block(
		signM,
		V3(26, 9, 1),
		o * CF(0, 13, -48),
		rgb(120, 82, 46),
		M.WoodPlanks,
		{ name = "Sign" }
	)
	Build.block(signM, V3(27, 0.8, 1.4), o * CF(0, 17.8, -48), GOLD, M.Metal)
	Props.cheeseWedge(signM, o * CF(0, 18.2, -48) * ANG(0, math.pi, 0), 5, 2.4, rng)
	local statusLabel = signText(sign, Enum.NormalId.Back, "TRUNKFALL", "Pick an elephant and READY UP")
	signText(sign, Enum.NormalId.Front, "TRUNKFALL", "Herd Sanctuary")

	-- Lamp posts round the plaza, cheese sculptures and gardens
	local deco = Build.model(model, "Decor")
	deco:AddTag("Decor")
	for i = 0, 11 do
		local a = (i + 0.5) / 12 * math.pi * 2
		local p = c + V3(math.cos(a) * 37.5, 0, math.sin(a) * 37.5)
		if math.abs(p.Z - (c.Z - 40)) > 6 then
			lamp(deco, CFrame.lookAt(p, c) * ANG(0, math.pi / 2, 0))
		end
	end
	if rng then
		for i = 1, 60 do
			local a, d = rng:range(0, 6.28), rng:range(39, 58)
			local x, z = c.X + math.cos(a) * d, c.Z + math.sin(a) * d
			local kind = if i % 3 == 0 then "grass" else "flower"
			Props.DECOR[kind](deco, x, z, rng:range(0.9, 1.4), rng, PAL)
		end
		local far = Build.model(model, "Backdrop")
		far:AddTag("DecorFar")
		for i = 0, 17 do
			local a = (i + rng:range(-0.3, 0.3)) / 18 * math.pi * 2
			local d = rng:range(50, 62)
			local x, z = c.X + math.cos(a) * d, c.Z + math.sin(a) * d
			local m = Build.model(far, "Tree" .. i)
			if i % 4 == 0 then
				Props.OBSTACLES.rock(m, x, z, rng:range(3, 5), rng, PAL, false)
			else
				Props.OBSTACLES.tree(m, x, z, rng:range(3.5, 5), rng, PAL, false)
			end
		end
		-- giant cheese wedges flanking the spawn path
		for _, s in { -1, 1 } do
			Props.cheeseRock(deco, c.X + s * 30, c.Z + 30, 4, rng, PAL, false)
		end
	end

	-- v4: leaderboard wall (east), shop kiosk (west), spawn plaza (south)
	leaderboardWall(model, c)
	pcall(cheeseLadder, model, c)
	shopKiosk(model, c, rng)
	spawnPlaza(model, c, rng)

	-- Invisible wall ring
	local walls = Instance.new("Folder")
	walls.Name = "Walls"
	walls.Parent = model
	local nW = 32
	local wr = LobbyWorld.WALL_RADIUS
	for i = 0, nW - 1 do
		local a = (i + 0.5) / nW * math.pi * 2
		local p = c + V3(math.cos(a) * wr, 12, math.sin(a) * wr)
		Build.block(
			walls,
			V3(2 * math.pi * wr / nW + 0.6, 26, 1),
			CFrame.lookAt(p, c + V3(0, 12, 0)),
			Color3.new(1, 1, 1),
			M.SmoothPlastic,
			{
				name = "Wall",
				collide = true,
				transparency = 1,
				shadow = false,
			}
		)
	end

	-- Spawn (south side, facing the sign)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = V3(8, 1, 8)
	spawn.CFrame = o * CF(0, 0.5, 22)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CanQuery = false
	local decal = spawn:FindFirstChildOfClass("Decal")
	if decal then
		decal:Destroy()
	end
	spawn.Parent = model

	model.WorldPivot = o
	model.Parent = Workspace
	built = {
		spawn = spawn,
		readyPad = readyPad,
		squadPads = squadPads,
		statusLabel = statusLabel,
		model = model,
		center = c,
	}
	return built
end

return LobbyWorld
