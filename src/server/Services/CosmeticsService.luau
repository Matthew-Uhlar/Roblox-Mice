--!strict
-- CosmeticsService (Team D): draws what players bought and equipped (QC2 B1).
--
-- On CharacterAdded / CharacterAppearanceLoaded, on profile load, after every Equip
-- (ShopService) and whenever passes or the Cheese Club change (MonetizationService
-- .onEntitlementsChanged), the player's Look (pure: Data/Looks.resolve) is rebuilt:
--   trail     Trail between two Attachments on the HumanoidRootPart (Config/Cosmetics
--             colours, C.TRAIL tuning)
--   hat       part-built hat welded on top of the Head (C.HAT_SHAPES geometry)
--   tint      Highlight over the character (C.TINT tuning)
--   nametag   BillboardGui over the Head: DisplayName (gold for VIP) plus titles
--             (VIP / Founder / Cheese Club). Roblox's own name label is hidden.
--   chat tag  player attributes "ChatTag" (string) and "ChatTagColor" (Color3).
--             The CLIENT shows them with TextChatService.OnIncomingMessage (see
--             docs/MONETIZATION.md, "Chat tag client hook").
-- Everything lives in a "TrunkfallCosmetics" folder in the character (plus two
-- attachments on the root and the nametag on the head) and is rebuilt idempotently.
-- Bots never reach this service: they are not Player objects.
--
-- API:
--   CosmeticsService.init()
--   CosmeticsService.refresh(player)              -- redraw soon (coalesced, safe to spam)
--   CosmeticsService.suspendTrail(player, seconds?) -- call right BEFORE teleporting a
--                                                  character so the trail doesn't streak
--   CosmeticsService.lookFor(player) -> Look

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local DataFolder = Shared:WaitForChild("Data")
local Cosmetics = require(Config:WaitForChild("Cosmetics")) :: any
local Looks = require(DataFolder:WaitForChild("Looks")) :: any

local DataService = require(script.Parent:WaitForChild("DataService")) :: any

local CosmeticsService = {}

CosmeticsService.FOLDER = "TrunkfallCosmetics"
CosmeticsService.NAMETAG = "TrunkfallNameTag"
CosmeticsService.TRAIL_A0 = "TrunkfallTrailA0"
CosmeticsService.TRAIL_A1 = "TrunkfallTrailA1"
CosmeticsService.HEAD_REFERENCE = 1.2 -- C.HAT_SHAPES units are for a head this tall
CosmeticsService.TELEPORT_JUMP = 30 -- studs in one frame = teleport: hide the trail briefly
CosmeticsService.TRAIL_SUSPEND = 0.3
CosmeticsService.CHAT_TAG_MAX = 20 -- bytes; the client truncates longer tags

type Look = any

local MonetizationService: any = nil
local initialized = false
local generation: { [Player]: number } = {}
local scheduled: { [Player]: boolean } = {}
local trails: { [Player]: { trail: Trail, root: BasePart, last: Vector3, resumeAt: number } } = {}

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function monetization(): any
	if MonetizationService == nil then
		local ok, mod = pcall(function()
			return require(script.Parent:FindFirstChild("MonetizationService") :: ModuleScript) :: any
		end)
		MonetizationService = if ok and type(mod) == "table" then mod else false
	end
	return MonetizationService or nil
end

local function status(player: Player): { vip: boolean, founder: boolean, club: boolean, herdKeeper: boolean? }
	local m = monetization()
	local function call(fn: string, ...: any): boolean
		if not m or type(m[fn]) ~= "function" then
			return false
		end
		local ok, v = pcall(m[fn], ...)
		return ok and v == true
	end
	return {
		vip = call("hasPass", player, "vip"),
		founder = call("hasPass", player, "founders"),
		club = call("isClubMember", player),
	}
end

function CosmeticsService.lookFor(player: Player): Look
	local profile = DataService.get(player)
	local st = status(player)
	local disc = if profile then (profile :: any).discoveries else nil
	st.herdKeeper = type(disc) == "table" and disc.lost_herd_statue ~= nil and disc.lost_herd_statue ~= false
	return Looks.resolve(
		if profile then profile.equipped else nil,
		if profile then profile.cosmetics else nil,
		st
	)
end

-- Building ----------------------------------------------------------------------

local function clear(character: Model, root: BasePart?, head: BasePart?)
	local old = character:FindFirstChild(CosmeticsService.FOLDER)
	if old then
		old:Destroy()
	end
	if root then
		for _, name in { CosmeticsService.TRAIL_A0, CosmeticsService.TRAIL_A1 } do
			local a = root:FindFirstChild(name)
			if a then
				a:Destroy()
			end
		end
	end
	if head then
		local tag = head:FindFirstChild(CosmeticsService.NAMETAG)
		if tag then
			tag:Destroy()
		end
	end
end

local function decorPart(part: BasePart, color: Color3)
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Color = color
end

local function buildTrail(player: Player, folder: Folder, root: BasePart, look: Look)
	local T = Cosmetics.TRAIL
	local a0 = Instance.new("Attachment")
	a0.Name = CosmeticsService.TRAIL_A0
	a0.Position = Vector3.new(-T.halfWidth, T.height, T.back)
	a0.Parent = root
	local a1 = Instance.new("Attachment")
	a1.Name = CosmeticsService.TRAIL_A1
	a1.Position = Vector3.new(T.halfWidth, T.height, T.back)
	a1.Parent = root

	local trail = Instance.new("Trail")
	trail.Name = "Trail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(rgb(look.trail.color), rgb(look.trail.color2))
	trail.Transparency = NumberSequence.new(T.startTransparency, 1)
	trail.Lifetime = T.lifetime
	trail.LightEmission = T.lightEmission
	trail.FaceCamera = false
	trail.MinLength = 0.05
	trail.Parent = folder
	trails[player] = { trail = trail, root = root, last = root.Position, resumeAt = 0 }
end

local function buildHat(folder: Folder, head: BasePart, look: Look)
	local shape = Cosmetics.HAT_SHAPES[look.hat.shape]
	if not shape then
		return
	end
	local scale = math.clamp(head.Size.Y / CosmeticsService.HEAD_REFERENCE, 0.6, 2.5)
	local top = CFrame.new(0, head.Size.Y / 2, 0)
	local main, accent = rgb(look.hat.color), rgb(look.hat.accent)
	local model = Instance.new("Model")
	model.Name = "Hat_" .. look.hat.id
	for i, spec in shape do
		local size = Vector3.new(spec.size[1], spec.size[2], spec.size[3]) * scale
		local rot = spec.rot or { 0, 0, 0 }
		local cf = top
			* CFrame.new(spec.at[1] * scale, spec.at[2] * scale, spec.at[3] * scale)
			* CFrame.Angles(math.rad(rot[1]), math.rad(rot[2]), math.rad(rot[3]))
		local part: BasePart
		if spec.form == "wedge" then
			part = Instance.new("WedgePart")
			part.Size = size
		elseif spec.form == "cyl" then
			local p = Instance.new("Part")
			p.Shape = Enum.PartType.Cylinder
			-- A Roblox cylinder's axis is X: stand it up.
			p.Size = Vector3.new(size.Y, size.X, size.Z)
			cf *= CFrame.Angles(0, 0, math.rad(90))
			part = p
		else
			local p = Instance.new("Part")
			p.Size = size
			if spec.form == "ball" then
				local mesh = Instance.new("SpecialMesh")
				mesh.MeshType = Enum.MeshType.Sphere -- ellipsoid that fills the part
				mesh.Parent = p
			end
			part = p
		end
		part.Name = "HatPart" .. i
		decorPart(part, if spec.accent then accent else main)
		part.CFrame = head.CFrame * cf
		local weld = Instance.new("Weld")
		weld.Part0 = head
		weld.Part1 = part
		weld.C0 = cf
		weld.Parent = part
		part.Parent = model
	end
	model.Parent = folder
end

local function buildTint(folder: Folder, character: Model, look: Look)
	local T = Cosmetics.TINT
	local c = rgb(look.tint.color)
	local h = Instance.new("Highlight")
	h.Name = "Tint"
	h.Adornee = character
	h.FillColor = c
	h.OutlineColor = c:Lerp(Color3.new(0, 0, 0), 0.4)
	h.FillTransparency = T.fillTransparency
	h.OutlineTransparency = T.outlineTransparency
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Parent = folder
end

local function label(name: string, text: string, color: Color3, y: number, h: number): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Position = UDim2.new(0, 0, y, 0)
	l.Size = UDim2.new(1, 0, h, 0)
	l.Font = Enum.Font.FredokaOne
	l.TextScaled = true
	l.Text = text
	l.TextColor3 = color
	l.TextStrokeColor3 = Color3.new(0, 0, 0)
	l.TextStrokeTransparency = 0.35
	return l
end

local function buildNameplate(player: Player, head: BasePart, humanoid: Humanoid?, look: Look)
	local np = look.nameplate
	local gui = Instance.new("BillboardGui")
	gui.Name = CosmeticsService.NAMETAG
	gui.Adornee = head
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 140
	gui.StudsOffset = Vector3.new(0, 3.4, 0) -- clears the tallest hat
	if np.title then
		gui.Size = UDim2.fromOffset(220, 54)
		label("Name", player.DisplayName, rgb(np.nameColor), 0, 0.58).Parent = gui
		label("Title", np.title, rgb(np.titleColor or np.nameColor), 0.6, 0.4).Parent = gui
	else
		gui.Size = UDim2.fromOffset(220, 32)
		label("Name", player.DisplayName, rgb(np.nameColor), 0, 1).Parent = gui
	end
	gui.Parent = head
	if humanoid then
		-- Hide Roblox's own name label (ours replaces it); keep the health bar.
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Subject
		humanoid.NameDisplayDistance = 0
	end
end

local function setChatAttributes(player: Player, look: Look)
	local tag = look.chatTag
	-- The client hook reads exactly these two attributes (ChatTag <= 20 chars).
	player:SetAttribute(
		"ChatTag",
		if tag then string.sub(tag.text, 1, CosmeticsService.CHAT_TAG_MAX) else nil
	)
	player:SetAttribute("ChatTagColor", if tag then rgb(tag.color) else nil)
	player:SetAttribute("NameTitle", look.nameplate.title)
end

local function applyNow(player: Player)
	if player.Parent ~= Players or not DataService.isRealPlayer(player) then
		return
	end
	local gen = (generation[player] or 0) + 1
	generation[player] = gen
	local look = CosmeticsService.lookFor(player)
	setChatAttributes(player, look)

	local character = player.Character
	if not character then
		return
	end
	local head = character:FindFirstChild("Head") or character:WaitForChild("Head", 5)
	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)
	if generation[player] ~= gen or player.Character ~= character or character.Parent == nil then
		return -- a newer apply (or a new character) took over while we waited
	end
	local headPart: BasePart? = if head and head:IsA("BasePart") then head else nil
	local rootPart: BasePart? = if root and root:IsA("BasePart") then root else nil
	clear(character, rootPart, headPart)
	trails[player] = nil

	local folder = Instance.new("Folder")
	folder.Name = CosmeticsService.FOLDER
	folder.Parent = character
	local function try(what: string, fn: () -> ())
		local ok, err = pcall(fn)
		if not ok then
			warn(string.format("[Cosmetics] %s failed for %s: %s", what, player.Name, tostring(err)))
		end
	end
	if look.trail and rootPart then
		try("trail", function()
			buildTrail(player, folder, rootPart, look)
		end)
	end
	if look.hat and headPart then
		try("hat", function()
			buildHat(folder, headPart, look)
		end)
	end
	if look.tint then
		try("tint", function()
			buildTint(folder, character, look)
		end)
	end
	if headPart then
		try("nametag", function()
			buildNameplate(player, headPart, character:FindFirstChildOfClass("Humanoid"), look)
		end)
	end
end

-- Redraws the player's cosmetics on the next resumption point. Many calls in one
-- frame (equip spam, several entitlement changes) build once.
function CosmeticsService.refresh(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") or scheduled[player] then
		return
	end
	scheduled[player] = true
	task.defer(function()
		scheduled[player] = nil
		local ok, err = pcall(applyNow, player)
		if not ok then
			warn("[Cosmetics] apply failed for " .. player.Name .. ": " .. tostring(err))
		end
	end)
end

-- Hides the trail for a moment so a teleport doesn't draw a ribbon across the map.
function CosmeticsService.suspendTrail(player: Player, seconds: number?)
	local t = trails[player]
	if not t or not t.trail.Parent then
		return
	end
	t.trail.Enabled = false
	t.resumeAt = os.clock() + (seconds or CosmeticsService.TRAIL_SUSPEND)
end

-- Fallback for teleports nobody announced: a one-frame jump also suspends the trail.
local function watchTrails()
	local now = os.clock()
	for player, t in trails do
		if not t.trail.Parent or not t.root.Parent then
			trails[player] = nil
			continue
		end
		local pos = t.root.Position
		if (pos - t.last).Magnitude > CosmeticsService.TELEPORT_JUMP then
			t.trail.Enabled = false
			t.trail:Clear()
			t.resumeAt = now + CosmeticsService.TRAIL_SUSPEND
		elseif not t.trail.Enabled and now >= t.resumeAt then
			t.trail.Enabled = true
		end
		t.last = pos
	end
end

-- Lifecycle ---------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	if not DataService.isRealPlayer(player) then
		return
	end
	player.CharacterAdded:Connect(function()
		CosmeticsService.refresh(player)
	end)
	-- Avatar loading can swap the head / body parts after CharacterAdded.
	player.CharacterAppearanceLoaded:Connect(function()
		CosmeticsService.refresh(player)
	end)
	if player.Character then
		CosmeticsService.refresh(player)
	end
end

function CosmeticsService.init()
	if initialized then
		return
	end
	initialized = true
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		generation[player] = nil
		scheduled[player] = nil
		trails[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	DataService.onLoaded(function(player: Player)
		CosmeticsService.refresh(player)
	end)
	local m = monetization()
	if m and type(m.onEntitlementsChanged) == "function" then
		m.onEntitlementsChanged(function(player: Player)
			CosmeticsService.refresh(player)
		end)
	end
	RunService.Heartbeat:Connect(watchTrails)
end

return CosmeticsService
