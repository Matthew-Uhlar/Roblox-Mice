--!strict
-- LobbyService: who is in the server, which class they picked, ready state,
-- the start countdown, and the lobby pad they stand on between runs.
--
-- v2 (docs/GDD-v2.md §1): one match per server, 12 seats = 4 squads x 3. The
-- cap of 12 is a PLACE SETTING (Max Players = 12, set by the publish pipeline);
-- scripts may not set Players.MaxPlayers. If more than 12 players are present
-- anyway (Studio tests), the first 12 (ready players first) start and the rest
-- wait in the lobby for the next match.
--
-- Squads: humans who came together share a squad. "Together" = Roblox join
-- data (Player:GetJoinData().Members of a party teleport), FollowUserId (joined
-- by following a friend), else Player:IsFriendsWith with the players already
-- here. BotRoster.partyIds / fillSquads (pure, tested) seat everyone and fill
-- every empty seat with a labelled bot, so all 4 squads always exist. The lobby
-- shows 4 squad pads (LobbyWorld.build() from R4 when present, else simple
-- coloured pads) with each squad's bots standing on theirs.
--
-- Countdown (pure rules in Run/LobbyRules): everyone willing is ready -> 5 s (a
-- lone player who presses Ready starts in 5 s); some ready -> 20 s; nobody ready
-- -> an AUTO-START countdown of 30 s, so a player who just joins drops into a
-- game with bots without touching Ready. Once armed a countdown only gets
-- SHORTER (QC2 M2): un-readying makes that player sit out this start instead of
-- cancelling it, and leaving or joining never restarts it. Idle players are
-- pulled into the run when it ends (one party per server), except AFK ones: two
-- auto-started runs in a row without any input and a player must press Ready
-- (QC1 #15; any remote or real movement counts as input, via Guard.onInput).
-- Ready / class / bot-fill spam is coalesced: state changes apply at once, the
-- re-evaluate + Lobby broadcast run at most every UPDATE_DEBOUNCE seconds, and
-- bot models are only re-placed when the roster actually changes.
--
-- Bots (GDD-v2 §1): every empty seat gets a bot (BotRoster.fillSquads). The
-- C2S.SetBotFill toggle now only controls bot MATES: with fill off for every
-- human, squads that hold humans get no bots (the other squads still fill). Bots appear in the Lobby payload with
-- isBot = true and ready = true but never count toward (or block) the
-- countdown. Run members may press Ready during Results ("Play again"): they
-- come back to the lobby already readied, which starts the 5 s countdown with
-- bots re-filled.
--
-- Pressure (Team G1, GDD §3.7, Run/Pressure): the PARTY LEADER is the first
-- human to ready up (readyAt order), else the earliest-joined willing player,
-- else the earliest-joined player in the lobby (Pressure.pickLeader). Only the
-- leader may C2S.SetPressure(modId, rank), only once their profile has
-- Pressure unlocked (first Go Home win); ranks are clamped to the modifier's
-- max. Each player's last board is saved to profile.pressure.board and loaded
-- with the profile, so it is already in place when they become leader. The
-- Lobby payload carries `pressure = {board, points, leaderId, unlocked,
-- youUnlocked}` (board/points are the EFFECTIVE board: empty while the leader
-- is locked). Bots accept whatever the leader picks.
--
-- API:
--   LobbyService.init()
--   LobbyService.onStart(fn(players: {Player}, classes: {[number]: string}, bots: {BotSpec},
--                           pressure: {[modId]: rank}, squads: {[1..4]: {SquadMember}}))
--       classes keyed by UserId; bots carry `squad`; pressure is the leader's validated
--       board ({} = no Pressure); squads = BotRoster.fillSquads (humans + bots per squad)
--   LobbyService.getSquads() -> {[1..4]: {SquadMember}}  -- the seating a start would use now
--   LobbyService.leaveRun(players)  -- squad out mid-match: back to the lobby (AFK rules apply)
--   LobbyService.getPressure() -> ({[modId]: rank}, leader: Player?)  -- what a start would use now
--   LobbyService.getBotRoster() -> {BotSpec}   -- bots the lobby would bring right now
--   LobbyService.setRunActive(active: boolean, members: {Player}?)
--   LobbyService.returnToLobby(players: {Player})
--   LobbyService.getClass(player) -> string
--   LobbyService.isRunMember(player) -> boolean
--   LobbyService.teleportCharacter(player, position: Vector3)
--   LobbyService.spawnPosition(slot: number) -> Vector3
--   LobbyService.setCharacterOverride(fn(player, character) -> boolean)
--   LobbyService.broadcast()

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Guard = require(script.Parent.Guard)
local Remotes = require(script.Parent.Remotes)

local function optionalRequire(parent: Instance, name: string): any
	local inst = parent:FindFirstChild(name)
	if not inst or not inst:IsA("ModuleScript") then
		return nil
	end
	local ok, mod = pcall(require, inst)
	if not ok then
		warn(string.format("[LobbyService] failed to load %s: %s", name, tostring(mod)))
		return nil
	end
	return mod
end

local Classes: any = optionalRequire(Shared:WaitForChild("Config"), "Classes")
local DataService: any = optionalRequire(script.Parent, "DataService")
local BotRoster: any = optionalRequire(Shared:WaitForChild("Bots"), "BotRoster")
local BotService: any = optionalRequire(script.Parent, "BotService")
local Rng = require(Shared:WaitForChild("Util"):WaitForChild("Rng")) :: any
local LobbyRules = require(Shared:WaitForChild("Run"):WaitForChild("LobbyRules")) :: any
local Pressure = require(Shared:WaitForChild("Run"):WaitForChild("Pressure")) :: any
local Squads = require(Shared:WaitForChild("Util"):WaitForChild("Squads")) :: any
local LobbyWorld: any = optionalRequire(script.Parent, "LobbyWorld") -- R4

local LobbyService = {}

LobbyService.MAX_PARTY = LobbyRules.MAX_PARTY
LobbyService.ALL_READY_SECONDS = LobbyRules.ALL_READY_SECONDS
LobbyService.SOME_READY_SECONDS = LobbyRules.SOME_READY_SECONDS
LobbyService.AUTO_START_SECONDS = LobbyRules.AUTO_START_SECONDS -- nobody ready: start anyway (bots fill the party)
LobbyService.UPDATE_DEBOUNCE = 0.25 -- seconds; coalesces Ready / class / bot-fill spam
LobbyService.SEATS = LobbyRules.MAX_PARTY -- 12 = 4 squads x 3
LobbyService.FRIEND_CHECKS = 11 -- IsFriendsWith calls per joining player (fallback only)
LobbyService.CENTER = Vector3.new(0, 0, -400)
local PAD_SIZE = 64
local FALLBACK_CLASS = "elephante"

type Entry = {
	player: Player,
	classId: string,
	ready: boolean,
	joinedAt: number,
	botFill: boolean, -- this player's "Bot teammates" toggle (default on)
	playAgain: boolean, -- pressed Ready during a run's Results: come back readied
	sitOut: boolean, -- un-readied: left out of the next start (LobbyRules)
	idleRuns: number, -- consecutive auto-started runs without any input
	autoPulled: boolean, -- in the current run without having pressed Ready
	inputThisRun: boolean,
	readyAt: number?, -- os.clock() when they readied (party leader order); nil when not ready
	pressureBoard: { [string]: number }, -- this player's Pressure board (sanitized)
	boardLoaded: boolean, -- pressureBoard came from the saved profile
	links: { number }, -- UserIds this player came with (join data / follow / friends)
}
type BotSpec = { id: number, name: string, classId: string, isBot: boolean, role: string?, squad: number? }

local entries: { [Player]: Entry } = {}
local runActive = false
local runMembers: { [Player]: boolean } = {}
local countdownEndsAt: number? = nil
local countdownKind: string? = nil -- "ready" | "auto"
local countdownToken = 0
type PressureBoard = { [string]: number }
type StartCallback = (
	players: { Player },
	classes: { [number]: string },
	bots: { BotSpec },
	pressure: PressureBoard,
	squads: { [number]: { any } }
) -> ()
local startCallbacks: { StartCallback } = {}
local botRoster: { BotSpec } = {}
local seating: { [number]: { any } } = {} -- BotRoster.fillSquads result for the next start
local squadPads: { BasePart } = {}
local rosterSeed = math.floor(os.time() % 100000) + 1 -- new bots (names/classes) after each run
local characterOverride: ((Player, Model) -> boolean)? = nil
local statusLabel: TextLabel? = nil
local updateScheduled = false
local lastRosterSig: string? = nil
local readyCircle: BasePart? = nil

-- Config lookups (tolerant of several config shapes) ---------------------------

local function classDef(id: any): any
	if type(id) ~= "string" or type(Classes) ~= "table" then
		return nil
	end
	if type(Classes.get) == "function" then
		local ok, def = pcall(Classes.get, id)
		if ok and type(def) == "table" then
			return def
		end
	end
	local direct = Classes[id]
	if type(direct) == "table" and direct.id == id then
		return direct
	end
	for _, key in { "BY_ID", "byId", "DEFS", "defs" } do
		local t = Classes[key]
		if type(t) == "table" and type(t[id]) == "table" then
			return t[id]
		end
	end
	for _, key in { "LIST", "list", "ALL", "all" } do
		local t = Classes[key]
		if type(t) == "table" then
			for _, d in t do
				if type(d) == "table" and d.id == id then
					return d
				end
			end
		end
	end
	for _, d in Classes do
		if type(d) == "table" and d.id == id then
			return d
		end
	end
	return nil
end

local function classOrder(): { string }
	if type(Classes) ~= "table" then
		return {}
	end
	if type(Classes.ORDER) == "table" then
		return Classes.ORDER
	end
	local ids = {}
	for k, d in Classes do
		if type(d) == "table" and type(d.id) == "string" and k == d.id then
			table.insert(ids, d.id)
		end
	end
	table.sort(ids)
	return ids
end

local function isFree(def: any): boolean
	return def ~= nil and (def.unlockCost == nil or def.unlockCost <= 0)
end

local function defaultClass(): string
	if
		type(Classes) == "table"
		and type(Classes.DEFAULT_ID) == "string"
		and isFree(classDef(Classes.DEFAULT_ID))
	then
		return Classes.DEFAULT_ID
	end
	for _, id in classOrder() do
		if isFree(classDef(id)) then
			return id
		end
	end
	return classOrder()[1] or FALLBACK_CLASS
end

local function getProfile(player: Player): any
	if DataService and type(DataService.get) == "function" then
		local ok, p = pcall(DataService.get, player)
		if ok then
			return p
		end
	end
	return nil
end

local function isUnlocked(player: Player, classId: string): boolean
	local def = classDef(classId)
	if not def then
		return false
	end
	if isFree(def) then
		return true
	end
	local profile = getProfile(player)
	return profile ~= nil
		and type(profile.unlockedClasses) == "table"
		and profile.unlockedClasses[classId] == true
end

-- Lobby pad --------------------------------------------------------------------

local function makePart(props: { [string]: any }, parent: Instance): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

local function makeSign(part: BasePart, face: Enum.NormalId, title: string): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = part

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.fromScale(1, 0.55)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font = Enum.Font.FredokaOne
	titleLabel.TextScaled = true
	titleLabel.TextColor3 = Color3.fromRGB(255, 214, 102)
	titleLabel.TextStrokeTransparency = 0.2
	titleLabel.Text = title
	titleLabel.Parent = gui

	local status = Instance.new("TextLabel")
	status.Position = UDim2.fromScale(0, 0.55)
	status.Size = UDim2.fromScale(1, 0.45)
	status.BackgroundTransparency = 1
	status.Font = Enum.Font.FredokaOne
	status.TextScaled = true
	status.TextColor3 = Color3.new(1, 1, 1)
	status.TextStrokeTransparency = 0.3
	status.Text = "Pick a class and READY UP"
	status.Parent = gui
	return status
end

-- Builds (once) a simple lobby platform at Y=0 around CENTER: floor, invisible
-- walls, a ready circle, signage and a SpawnLocation so characters load here.
function LobbyService.buildPad(): Model
	local existing = Workspace:FindFirstChild("LobbyPad")
	if existing and existing:IsA("Model") then
		return existing
	end
	local c = LobbyService.CENTER
	local model = Instance.new("Model")
	model.Name = "LobbyPad"

	makePart({
		Name = "Floor",
		Size = Vector3.new(PAD_SIZE, 2, PAD_SIZE),
		Position = c - Vector3.new(0, 1, 0),
		Color = Color3.fromRGB(255, 214, 102),
		Material = Enum.Material.SmoothPlastic,
	}, model)

	-- Rim + invisible walls so nobody wanders off the pad.
	local half = PAD_SIZE / 2
	for i, off in
		{
			Vector3.new(half, 0, 0),
			Vector3.new(-half, 0, 0),
			Vector3.new(0, 0, half),
			Vector3.new(0, 0, -half),
		}
	do
		local alongX = off.X == 0
		local size = if alongX then Vector3.new(PAD_SIZE + 2, 1, 2) else Vector3.new(2, 1, PAD_SIZE + 2)
		makePart({
			Name = "Rim" .. i,
			Size = size,
			Position = c + off + Vector3.new(0, 0.5, 0),
			Color = Color3.fromRGB(230, 160, 40),
			Material = Enum.Material.SmoothPlastic,
		}, model)
		makePart({
			Name = "Wall" .. i,
			Size = size + Vector3.new(0, 24, 0),
			Position = c + off + Vector3.new(0, 12, 0),
			Transparency = 1,
			CanCollide = true,
		}, model)
	end

	local circle = makePart({
		Name = "ReadyCircle",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 20, 20),
		CFrame = CFrame.new(c + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(120, 120, 120),
		Material = Enum.Material.Neon,
		CanCollide = false,
		CanQuery = false,
	}, model)
	readyCircle = circle

	local sign = makePart({
		Name = "Sign",
		Size = Vector3.new(24, 10, 1),
		Position = c + Vector3.new(0, 8, -half + 4),
		Color = Color3.fromRGB(90, 60, 30),
		Material = Enum.Material.Wood,
	}, model)
	statusLabel = makeSign(sign, Enum.NormalId.Back, "TRUNKFALL")
	makeSign(sign, Enum.NormalId.Front, "TRUNKFALL")

	-- Squad pads (v2): one coloured pad per squad in the corners of the floor.
	squadPads = {}
	for i = 1, Squads.MAX do
		local def = Squads.get(i)
		local angle = math.rad(45 + 90 * (i - 1))
		local pos = c + Vector3.new(math.cos(angle) * (half - 9), 0.1, math.sin(angle) * (half - 9))
		local pad = makePart({
			Name = "SquadPad" .. i,
			Size = Vector3.new(12, 0.2, 12),
			Position = pos,
			Color = Color3.fromRGB(def.color[1], def.color[2], def.color[3]),
			Material = Enum.Material.SmoothPlastic,
			CanCollide = false,
			CanQuery = false,
		}, model)
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(160, 40)
		gui.StudsOffset = Vector3.new(0, 6, 0)
		gui.AlwaysOnTop = false
		gui.MaxDistance = 80
		gui.Parent = pad
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.TextColor3 = pad.Color
		label.TextStrokeTransparency = 0.2
		label.Text = def.name
		label.Parent = gui
		squadPads[i] = pad
	end

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = Vector3.new(8, 1, 8)
	spawn.Position = c + Vector3.new(0, 0.5, half - 10)
	spawn.Transparency = 1
	spawn.CanCollide = false
	local decal = spawn:FindFirstChildOfClass("Decal")
	if decal then
		decal:Destroy()
	end
	spawn.Parent = model

	model.Parent = Workspace
	return model
end

-- Builds the lobby: R4's LobbyWorld.build() -> {spawn, readyPad, squadPads[1..4]}
-- when it exists, else the simple pad above.
local function buildLobby()
	if LobbyWorld and type(LobbyWorld.build) == "function" then
		local ok, info = pcall(LobbyWorld.build)
		if ok and type(info) == "table" then
			local pads = {}
			if type(info.squadPads) == "table" then
				for i = 1, Squads.MAX do
					local pad = info.squadPads[i]
					if typeof(pad) == "Instance" and pad:IsA("BasePart") then
						pads[i] = pad
					end
				end
			end
			if #pads == Squads.MAX then
				squadPads = pads
				if typeof(info.readyPad) == "Instance" and info.readyPad:IsA("BasePart") then
					readyCircle = info.readyPad
				end
				if typeof(info.spawn) == "Vector3" then
					LobbyService.CENTER = info.spawn
				elseif typeof(info.spawn) == "Instance" and info.spawn:IsA("BasePart") then
					LobbyService.CENTER = info.spawn.Position
				end
				return
			end
			warn("[LobbyService] LobbyWorld.build() gave no 4 squad pads; using the built-in pad")
		else
			warn("[LobbyService] LobbyWorld.build failed: " .. tostring(info))
		end
	end
	LobbyService.buildPad()
end

function LobbyService.spawnPosition(slot: number): Vector3
	local n = math.max(6, LobbyService.SEATS)
	local angle = (slot - 1) * (math.pi * 2 / n)
	return LobbyService.CENTER + Vector3.new(math.cos(angle) * 12, 0, math.sin(angle) * 12)
end

-- Where seat `seat` (1..3) of squad `squad` stands in the lobby.
function LobbyService.squadPadPosition(squad: number, seat: number): Vector3
	local pad = squadPads[squad]
	local base: Vector3
	if pad then
		base = pad.Position + Vector3.new(0, pad.Size.Y / 2, 0)
	else
		local angle = math.rad(45 + 90 * (squad - 1))
		base = LobbyService.CENTER + Vector3.new(math.cos(angle) * 23, 0, math.sin(angle) * 23)
	end
	local a = (seat - 1) * (math.pi * 2 / 3)
	return base + Vector3.new(math.cos(a) * 3, 0, math.sin(a) * 3)
end

function LobbyService.teleportCharacter(player: Player, position: Vector3)
	local character = player.Character
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)
	if not root or not root:IsA("BasePart") then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local lift = if humanoid then humanoid.HipHeight + root.Size.Y / 2 + 0.5 else 3
	-- CosmeticsService (Fix Team 1): no trail streak across the map.
	local cosmetics = script.Parent:FindFirstChild("CosmeticsService")
	if cosmetics then
		local ok, C = pcall(require, cosmetics)
		if ok and type(C) == "table" and type(C.suspendTrail) == "function" then
			pcall(C.suspendTrail, player)
		end
	end
	character:PivotTo(CFrame.new(position + Vector3.new(0, lift, 0)))
	root.AssemblyLinearVelocity = Vector3.zero
end

-- State + broadcast -----------------------------------------------------------------

local function lobbyPlayers(): { Player }
	local list = {}
	for p in entries do
		if p.Parent == Players and not (runActive and runMembers[p]) then
			table.insert(list, p)
		end
	end
	table.sort(list, function(a, b)
		return entries[a].joinedAt < entries[b].joinedAt
	end)
	return list
end

local function updateSign(nReady: number, nTotal: number)
	if statusLabel then
		if runActive then
			statusLabel.Text = "Run in progress... next one soon!"
		elseif countdownEndsAt then
			statusLabel.Text = string.format("Starting! %d/%d ready", nReady, nTotal)
		else
			statusLabel.Text = string.format("Pick a class and READY UP (%d/%d)", nReady, nTotal)
		end
	end
	if readyCircle then
		readyCircle.Color = if countdownEndsAt
			then Color3.fromRGB(90, 220, 110)
			elseif nReady > 0 then Color3.fromRGB(255, 200, 60)
			else Color3.fromRGB(120, 120, 120)
	end
end

-- Pressure (GDD §3.7) -------------------------------------------------------------------

local function pressureUnlocked(player: Player?): boolean
	if not player then
		return false
	end
	local profile = getProfile(player)
	return profile ~= nil and Pressure.isUnlocked(profile.pressure)
end

-- Loads the player's saved board into their entry (once the profile exists).
local function loadBoard(player: Player)
	local e = entries[player]
	local profile = getProfile(player)
	if not e or not profile then
		return
	end
	local pp = profile.pressure
	e.pressureBoard = Pressure.sanitize(if type(pp) == "table" then pp.board else nil)
	e.boardLoaded = true
end

-- The leader among `list` (humans only): Pressure.pickLeader.
local function leaderAmong(list: { Player }): Player?
	local cands = {}
	local byId: { [number]: Player } = {}
	for _, p in list do
		local e = entries[p]
		if e then
			byId[p.UserId] = p
			table.insert(cands, {
				id = p.UserId,
				ready = e.ready,
				readyAt = e.readyAt,
				joinedAt = e.joinedAt,
				willing = LobbyRules.willing(e),
			})
		end
	end
	local id = Pressure.pickLeader(cands)
	return if id ~= nil then byId[id] else nil
end

local lastLeader: Player? = nil

-- The lobby's current party leader. Pre-loads a new leader's saved board.
local function currentLeader(): Player?
	local leader = leaderAmong(lobbyPlayers())
	if leader ~= lastLeader then
		lastLeader = leader
		local e = if leader then entries[leader] else nil
		if leader and e and not e.boardLoaded then
			loadBoard(leader)
		end
	end
	return leader
end

-- The board a run led by `leader` would use: theirs if unlocked, else none.
local function effectiveBoard(leader: Player?): PressureBoard
	local e = if leader then entries[leader] else nil
	if not e or not pressureUnlocked(leader) then
		return {}
	end
	return Pressure.sanitize(e.pressureBoard)
end

function LobbyService.getPressure(): (PressureBoard, Player?)
	local leader = currentLeader()
	return effectiveBoard(leader), leader
end

-- Bots ---------------------------------------------------------------------------------

-- Bots are on if ANY of these humans has fill enabled (the default).
local function botsEnabled(humans: { Player }): boolean
	for _, p in humans do
		local e = entries[p]
		if e and e.botFill then
			return true
		end
	end
	return false
end

-- Party ids for these humans (BotRoster.partyIds over everyone's links).
local function partyIdsFor(humans: { Player }): { [number]: number }
	local ids, links = {}, {}
	for _, p in humans do
		table.insert(ids, p.UserId)
		local e = entries[p]
		for _, other in (if e then e.links else {}) do
			table.insert(links, { p.UserId, other })
		end
	end
	if BotRoster and type(BotRoster.partyIds) == "function" then
		local ok, map = pcall(BotRoster.partyIds, ids, links)
		if ok and type(map) == "table" then
			return map
		end
	end
	return {}
end

-- Seats for this group of humans (deterministic per rosterSeed, so the squads
-- and bots shown in the lobby are the ones that start the match). Returns
-- (squads, bots): squads = {[1..4] = {SquadMember}}, bots carry `squad`.
local function rosterFor(humans: { Player }): ({ [number]: { any } }, { BotSpec })
	if not BotRoster or #humans == 0 or type(BotRoster.fillSquads) ~= "function" then
		return {}, {}
	end
	local partyOf = partyIdsFor(humans)
	local list = {}
	for _, p in humans do
		local e = entries[p]
		table.insert(list, {
			id = p.UserId,
			partyId = partyOf[p.UserId],
			classId = if e then e.classId else defaultClass(),
			name = p.DisplayName,
		})
	end
	local ok, squads = pcall(BotRoster.fillSquads, list, Rng.new(rosterSeed), { mates = botsEnabled(humans) })
	if not ok or type(squads) ~= "table" then
		warn("[LobbyService] BotRoster.fillSquads failed: " .. tostring(squads))
		return {}, {}
	end
	local bots: { BotSpec } = {}
	for s = 1, Squads.MAX do
		for _, m in squads[s] or {} do
			if m.isBot then
				table.insert(bots, m)
			end
		end
	end
	return squads, bots
end

-- The humans the next run would take (LobbyRules.party): ready first, then idle
-- players who are not sitting out or AFK-capped, capped at MAX_PARTY.
local function nextParty(): { Player }
	local list = {}
	for _, p in lobbyPlayers() do
		table.insert(list, entries[p])
	end
	local party: { Player } = {}
	for _, e in LobbyRules.party(list, LobbyService.MAX_PARTY) do
		table.insert(party, e.player)
	end
	return party
end

-- Recomputes the lobby's bot roster and stands the bots on the pad.
local function refreshBots()
	if runActive then
		botRoster = {}
		seating = {}
		lastRosterSig = nil -- the run took the bot models; re-place them afterwards
		return
	end
	seating, botRoster = rosterFor(nextParty())
	-- Only touch the bot models when the roster changed (QC2 minor 9).
	local sig = {}
	for _, b in botRoster do
		table.insert(sig, string.format("%d:%s:%s:%s", b.id, b.classId, b.name, tostring(b.squad)))
	end
	local key = table.concat(sig, "|")
	if key == lastRosterSig then
		return
	end
	lastRosterSig = key
	if BotService and type(BotService.placeInLobby) == "function" then
		-- Each bot stands on its squad's pad, at its seat.
		local positions = {}
		for _, b in botRoster do
			local seat = 1
			for i, m in seating[b.squad or 1] or {} do
				if m.id == b.id then
					seat = i
				end
			end
			table.insert(positions, LobbyService.squadPadPosition(b.squad or 1, seat))
		end
		local ok, err = pcall(BotService.placeInLobby, botRoster, positions, LobbyService.CENTER)
		if not ok then
			warn("[LobbyService] BotService.placeInLobby failed: " .. tostring(err))
		end
	end
end

function LobbyService.getBotRoster(): { BotSpec }
	return table.clone(botRoster)
end

function LobbyService.getSquads(): { [number]: { any } }
	local out = {}
	for s = 1, Squads.MAX do
		out[s] = table.clone(seating[s] or {})
	end
	return out
end

-- The recipient's class loadout (ability / skin, stored by R3 in profile.classes).
local function loadoutOf(player: Player, classId: string): (string?, string?)
	local profile = getProfile(player)
	local classes = if profile then profile.classes else nil
	local st = if type(classes) == "table" then classes[classId] else nil
	if type(st) ~= "table" then
		return nil, nil
	end
	return if type(st.ability) == "string" then st.ability else nil,
		if type(st.skin) == "string" then st.skin else nil
end

-- While a match runs, lobby players see when it should end (QC-A minor 6: one
-- match per server; an extracted player waits in the lobby for the next one).
-- RunDirector installs the provider: () -> {endsAt, stage, stages}?.
local runInfoProvider: (() -> any)? = nil

function LobbyService.setRunInfoProvider(fn: (() -> any)?)
	runInfoProvider = fn
end

local function runInfo(): any
	local fn = runInfoProvider
	if not runActive or not fn then
		return nil
	end
	local ok, info = pcall(fn)
	return if ok and type(info) == "table" then info else nil
end

function LobbyService.broadcast()
	refreshBots()
	local players: { [string]: any } = {}
	local nReady, nTotal = 0, 0
	local anyFill = false
	local squadOf: { [number]: number } = {}
	local partyOf: { [number]: number } = {}
	local squadList = {}
	for s = 1, Squads.MAX do
		local def = Squads.get(s)
		local ids = {}
		for _, m in seating[s] or {} do
			squadOf[m.id] = s
			partyOf[m.id] = m.partyId
			table.insert(ids, tostring(m.id))
		end
		squadList[s] = { id = s, name = def.name, color = table.clone(def.color), members = ids }
	end
	for p, e in entries do
		if p.Parent == Players then
			local inRun = runActive and runMembers[p] == true
			local ability, skin = loadoutOf(p, e.classId)
			players[tostring(p.UserId)] = {
				squad = squadOf[p.UserId],
				partyId = partyOf[p.UserId],
				ability = ability,
				skin = skin,
				name = p.DisplayName,
				classId = e.classId,
				ready = e.ready,
				inRun = inRun,
				isBot = false,
				botFill = e.botFill,
				playAgain = if inRun then e.playAgain else nil,
				sittingOut = if inRun then nil else e.sitOut,
				needsReady = if inRun then nil else (not e.ready and not LobbyRules.autoEligible(e)),
			}
			if not inRun then
				nTotal += 1
				if e.ready then
					nReady += 1
				end
				anyFill = anyFill or e.botFill
			end
		end
	end
	-- Pressure: the leader's effective board (bots accept it).
	local leader = currentLeader()
	local board = effectiveBoard(leader)
	local leaderUnlocked = pressureUnlocked(leader)
	if leader then
		local le = players[tostring(leader.UserId)]
		if le then
			le.leader = true
		end
	end
	-- Bots ride along, always "ready"; they never count toward the countdown.
	for _, b in botRoster do
		players[tostring(b.id)] =
			{ name = b.name, classId = b.classId, ready = true, inRun = false, isBot = true, squad = b.squad }
	end
	-- Per-recipient payload: `botFill` is the receiving player's own toggle;
	-- `botFillAny` says whether bots will come at all (any lobby human has fill on).
	local info = runInfo()
	for _, p in Players:GetPlayers() do
		local e = entries[p]
		local payload: any = {
			players = players,
			startsAt = countdownEndsAt, -- workspace:GetServerTimeNow() based; also set for the auto-start
			runActive = runActive,
			runInfo = info, -- {endsAt (estimate, server time), stage, stages} while a match runs
			autoStart = countdownKind == "auto",
			botFill = if e then e.botFill else true,
			botFillAny = anyFill,
			botCount = #botRoster,
			squads = squadList, -- v2: the 4 squads the next start would seat
			seats = LobbyService.SEATS,
			yourSquad = squadOf[p.UserId],
			pressure = {
				board = board,
				points = Pressure.points(board),
				leaderId = if leader then leader.UserId else nil,
				unlocked = leaderUnlocked, -- the leader's board is unlocked (Pressure applies)
				youUnlocked = pressureUnlocked(p), -- the recipient's own unlock
			},
		}
		Remotes.lobby(payload, p)
	end
	updateSign(nReady, nTotal)
end

local function cancelCountdown()
	countdownToken += 1
	countdownEndsAt = nil
	countdownKind = nil
end

local function fireStart()
	countdownEndsAt = nil
	countdownKind = nil
	-- Ready players first, then willing idle ones, capped at MAX_PARTY.
	local party = nextParty()
	local classes: { [number]: string } = {}
	for _, p in party do
		local e = entries[p]
		classes[p.UserId] = e.classId
		e.autoPulled = not e.ready
		e.inputThisRun = false
	end
	-- A new start: everyone who sat this one out is a normal idle player again.
	for _, e in entries do
		e.sitOut = false
	end
	if #party == 0 then
		LobbyService.broadcast()
		return
	end
	local squads, bots = rosterFor(party)
	-- The run's Pressure: the party leader's board (validated; {} if locked).
	local pressure = effectiveBoard(leaderAmong(party))
	for _, cb in startCallbacks do
		task.spawn(cb, party, classes, bots, table.clone(pressure), squads)
	end
end

local function armCountdown(seconds: number, kind: string)
	countdownToken += 1
	local token = countdownToken
	countdownEndsAt = Workspace:GetServerTimeNow() + seconds
	countdownKind = kind
	task.delay(seconds, function()
		if token == countdownToken and not runActive then
			fireStart()
		end
	end)
end

local function evaluate()
	if runActive then
		if countdownEndsAt then
			cancelCountdown()
		end
		LobbyService.broadcast()
		return
	end
	local list = {}
	for _, p in lobbyPlayers() do
		table.insert(list, entries[p])
	end
	local now = Workspace:GetServerTimeNow()
	local remaining = if countdownEndsAt then math.max(0, (countdownEndsAt :: number) - now) else nil
	local d = LobbyRules.countdown(list, remaining, countdownKind)
	if d.action == "arm" then
		armCountdown(d.seconds, d.kind)
	elseif d.action == "cancel" then
		cancelCountdown()
	elseif d.action == "keep" then
		countdownKind = d.kind -- never longer; "auto" may become "ready"
	end
	LobbyService.broadcast()
end

-- Coalesced evaluate + broadcast (Ready / class / bot-fill spam, joins, leaves).
local function requestUpdate()
	if updateScheduled then
		return
	end
	updateScheduled = true
	task.delay(LobbyService.UPDATE_DEBOUNCE, function()
		updateScheduled = false
		evaluate()
	end)
end

-- Any input from a player (Guard.onInput): resets their AFK counter.
local function noteInput(player: Player)
	local e = entries[player]
	if not e then
		return
	end
	local wasAfk = not LobbyRules.autoEligible(e) and not e.ready and not e.sitOut
	LobbyRules.noteInput(e)
	if runActive and runMembers[player] then
		e.inputThisRun = true
	elseif wasAfk then
		requestUpdate() -- an AFK-capped lobby player is auto-eligible again
	end
end

-- Public API ---------------------------------------------------------------------

function LobbyService.onStart(callback: (
	players: { Player },
	classes: { [number]: string },
	bots: { BotSpec },
	pressure: PressureBoard,
	squads: { [number]: { any } }
) -> ())
	table.insert(startCallbacks, callback)
end

function LobbyService.getClass(player: Player): string
	local e = entries[player]
	return if e then e.classId else defaultClass()
end

function LobbyService.isRunActive(): boolean
	return runActive
end

function LobbyService.isRunMember(player: Player): boolean
	return runActive and runMembers[player] == true
end

function LobbyService.setCharacterOverride(fn: (Player, Model) -> boolean)
	characterOverride = fn
end

function LobbyService.setRunActive(active: boolean, members: { Player }?)
	runActive = active
	runMembers = {}
	if active and members then
		for _, p in members do
			runMembers[p] = true
			local e = entries[p]
			if e then
				e.ready = false
				e.readyAt = nil
				e.playAgain = false
			end
		end
	end
	if not active then
		rosterSeed += 1 -- fresh bot names/classes for the next run
	end
	cancelCountdown()
	evaluate()
end

-- Brings run members back to the pad. Ready is cleared unless they pressed
-- "Play again" (Ready) during Results.
local function afterRun(players: { Player })
	for i, p in players do
		pcall(function()
			p:SetAttribute("Squad", nil) -- set by RunDirector for the match
		end)
		local e = entries[p]
		if e then
			e.idleRuns = LobbyRules.afterRun(e.idleRuns, e.autoPulled, e.inputThisRun)
			e.autoPulled = false
			e.inputThisRun = false
			e.ready = e.playAgain
			e.playAgain = false
			e.sitOut = false
			if not e.ready then
				e.readyAt = nil
			elseif e.readyAt == nil then
				e.readyAt = os.clock()
			end
		end
		if p.Parent == Players then
			task.spawn(LobbyService.teleportCharacter, p, LobbyService.spawnPosition(i))
		end
	end
end

function LobbyService.returnToLobby(players: { Player })
	afterRun(players)
end

-- A squad that left the match early (extracted / eliminated): its humans are
-- lobby players again (they wait there while the match goes on; the next
-- countdown arms when it ends). AFK accounting and "Play again" apply as usual.
function LobbyService.leaveRun(players: { Player })
	local back = {}
	for _, p in players do
		if runMembers[p] then
			runMembers[p] = nil
			table.insert(back, p)
		end
	end
	if #back > 0 then
		afterRun(back)
		requestUpdate()
		local info = runInfo()
		local mins = if info and tonumber(info.endsAt)
			then math.max(1, math.ceil((tonumber(info.endsAt) - Workspace:GetServerTimeNow()) / 60))
			else nil
		for _, p in back do
			Remotes.toast(
				p,
				if mins
					then string.format(
						"You're back in the lobby. The next match starts when this one ends (about %d min).",
						mins
					)
					else "You're back in the lobby. The next match starts when this one ends.",
				"info"
			)
		end
	end
end

-- Lets RunDirector push a fresh run estimate to lobby players (each stage start).
function LobbyService.refresh()
	requestUpdate()
end

-- Remote handlers ------------------------------------------------------------------

-- Player attribute ClassId (+ CosmeticsService.refresh, so class gear and skin redraw).
local function setClassAttribute(player: Player, classId: string)
	pcall(function()
		player:SetAttribute("ClassId", classId)
	end)
	local mod = script.Parent:FindFirstChild("CosmeticsService")
	if mod then
		local ok, C = pcall(require, mod)
		if ok and type(C) == "table" and type(C.refresh) == "function" then
			pcall(C.refresh, player)
		end
	end
end

local function onSelectClass(player: Player, classId: string)
	local e = entries[player]
	if not e then
		return
	end
	if LobbyService.isRunMember(player) then
		Remotes.toast(player, "You can't change class during a run.", "bad")
		return
	end
	if not classDef(classId) then
		Guard.reject(player, "SelectClass", "unknown class " .. classId, false)
		return
	end
	if not isUnlocked(player, classId) then
		Remotes.toast(player, "That class is locked. Unlock it with Cheese!", "bad")
		return
	end
	if e.classId == classId then
		return
	end
	e.classId = classId
	if DataService and type(DataService.update) == "function" then
		pcall(DataService.update, player, function(profile: any)
			profile.selectedClass = classId
		end)
	end
	setClassAttribute(player, classId)
	requestUpdate()
end

local function onSetReady(player: Player, ready: boolean)
	local e = entries[player]
	if not e then
		return
	end
	if LobbyService.isRunMember(player) then
		-- "Play again": remembered and applied when the run returns to the lobby.
		if e.playAgain ~= ready then
			e.playAgain = ready
			e.readyAt = if ready then os.clock() else nil -- leader order for the next lobby
			requestUpdate()
		end
		return
	end
	if e.ready == ready then
		return
	end
	-- Un-ready = sit out this start; it never cancels or lengthens the countdown.
	LobbyRules.setReady(e, ready)
	e.readyAt = if ready then os.clock() else nil
	requestUpdate()
end

LobbyService.PRESSURE_LOCK_SECONDS = 5

local function onSetPressure(player: Player, modId: string, rank: number)
	local e = entries[player]
	if not e then
		return
	end
	if Pressure.clampRank(modId, 1) == 0 then
		Guard.reject(player, "SetPressure", "unknown modifier " .. modId, false)
		return
	end
	if LobbyService.isRunMember(player) then
		Remotes.toast(player, "Pressure is set in the lobby between runs.", "bad")
		return
	end
	if currentLeader() ~= player then
		Remotes.toast(player, "Only the party leader (first to READY) sets Pressure.", "bad")
		return
	end
	if not pressureUnlocked(player) then
		Remotes.toast(player, "Win a run (Go Home) to unlock Pressure.", "bad")
		return
	end
	-- Freeze the board in the last seconds so nobody is surprised by a change
	-- they had no time to see (Final QC B, FB-m1).
	if
		countdownEndsAt
		and countdownEndsAt - Workspace:GetServerTimeNow() < LobbyService.PRESSURE_LOCK_SECONDS
	then
		Remotes.toast(player, "Pressure is locked: the run is about to start.", "bad")
		return
	end
	local board = Pressure.setRank(e.pressureBoard, modId, rank)
	if not board or (board[modId] or 0) == (e.pressureBoard[modId] or 0) then
		return
	end
	e.pressureBoard = board
	if DataService and type(DataService.update) == "function" then
		pcall(DataService.update, player, function(profile: any)
			if type(profile.pressure) == "table" then
				profile.pressure.board = table.clone(board)
			end
		end)
	end
	requestUpdate()
end

local function onSetBotFill(player: Player, enabled: boolean)
	local e = entries[player]
	if not e or e.botFill == enabled then
		return
	end
	e.botFill = enabled
	if not LobbyService.isRunMember(player) then
		Remotes.toast(
			player,
			if enabled then "Bot teammates ON" else "Bot teammates OFF (solo runs stay solo)",
			"info"
		)
	end
	requestUpdate()
end

-- Player lifecycle ---------------------------------------------------------------------

local function onCharacterAdded(player: Player, character: Model)
	task.defer(function()
		if character.Parent == nil then
			return
		end
		if characterOverride then
			local ok, handled = pcall(characterOverride, player, character)
			if ok and handled then
				return
			end
		end
		local slot = 1
		for i, p in lobbyPlayers() do
			if p == player then
				slot = i
			end
		end
		LobbyService.teleportCharacter(player, LobbyService.spawnPosition(slot))
	end)
end

-- UserIds `player` came with: a party teleport (GetJoinData().Members), the friend
-- they followed in (FollowUserId), else friends already in this server
-- (IsFriendsWith, a web call: pcall, capped). Studio / emulators may lack these.
local function findLinks(player: Player): { number }
	local links: { number } = {}
	local seen: { [number]: boolean } = { [player.UserId] = true }
	local function add(id: any)
		if type(id) == "number" and not seen[id] then
			seen[id] = true
			table.insert(links, id)
		end
	end
	local okJ, data = pcall(function()
		return (player :: any):GetJoinData()
	end)
	if okJ and type(data) == "table" and type(data.Members) == "table" then
		for _, id in data.Members do
			add(id)
		end
	end
	local okF, follow = pcall(function()
		return (player :: any).FollowUserId
	end)
	if okF and type(follow) == "number" and follow ~= 0 then
		add(follow)
	end
	if #links == 0 then
		local checks = 0
		for other in entries do
			if other ~= player and other.Parent == Players and checks < LobbyService.FRIEND_CHECKS then
				checks += 1
				local okW, friends = pcall(function()
					return player:IsFriendsWith(other.UserId)
				end)
				if okW and friends == true then
					add(other.UserId)
				end
			end
		end
	end
	return links
end

local function onPlayerAdded(player: Player)
	if entries[player] then
		return
	end
	entries[player] = {
		player = player,
		classId = defaultClass(),
		ready = false,
		joinedAt = os.clock(),
		botFill = true,
		playAgain = false,
		sitOut = false,
		idleRuns = 0,
		autoPulled = false,
		inputThisRun = false,
		readyAt = nil,
		pressureBoard = {},
		boardLoaded = false,
		links = {},
	}
	pcall(function()
		player:SetAttribute("ClassId", entries[player].classId)
	end)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
	if runActive then
		Remotes.toast(player, "A run is in progress. You'll join the next one!", "info")
	end
	evaluate()
	task.spawn(function()
		local links = findLinks(player)
		local e = entries[player]
		if e and #links > 0 then
			e.links = links
			requestUpdate()
		end
	end)

	-- Restore the saved class once the profile loads.
	if DataService and type(DataService.waitFor) == "function" then
		task.spawn(function()
			local ok, profile = pcall(DataService.waitFor, player)
			local e = entries[player]
			if not ok or not profile or not e then
				return
			end
			-- Pressure: this player's last board, ready for when they lead.
			loadBoard(player)
			local saved = profile.selectedClass
			if type(saved) == "string" and saved ~= e.classId and isUnlocked(player, saved) then
				e.classId = saved
				setClassAttribute(player, saved)
			end
			requestUpdate()
		end)
	end
end

local function onPlayerRemoving(player: Player)
	if not entries[player] then
		return
	end
	entries[player] = nil
	runMembers[player] = nil
	if lastLeader == player then
		lastLeader = nil
	end
	-- No cancel: the countdown keeps running (or is cancelled by the rules when
	-- nobody is left to start).
	evaluate()
end

local initialized = false

function LobbyService.init()
	if initialized then
		return
	end
	initialized = true
	buildLobby()

	local classIds = classOrder()
	Guard.connect(Net.C2S.SelectClass, { rate = 3, burst = 4, args = { Guard.T.string(32) } }, onSelectClass)
	Guard.connect(Net.C2S.SetReady, { rate = 2, burst = 3, args = { Guard.T.boolean() } }, onSetReady)
	Guard.onInput(noteInput)
	Guard.connect(Net.C2S.SetBotFill, { rate = 2, burst = 3, args = { Guard.T.boolean() } }, onSetBotFill)
	if Net.C2S.SetPressure then
		Guard.connect(
			Net.C2S.SetPressure,
			{ rate = 6, burst = 10, args = { Guard.T.string(32), Guard.T.number(-100, 100) } },
			onSetPressure
		)
	end
	if #classIds == 0 then
		warn("[LobbyService] Config.Classes missing or empty; class selection will reject everything")
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end
end

return LobbyService
