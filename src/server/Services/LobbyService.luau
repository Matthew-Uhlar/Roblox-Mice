--!strict
-- LobbyService: who is in the server, which class they picked, ready state,
-- the start countdown, and the lobby pad they stand on between runs.
--
-- One party per server (GDD §10). The cap of 4 is a PLACE SETTING
-- (Game Settings > Places > Max Players = 4); scripts may not set
-- Players.MaxPlayers. If more than 4 players are present anyway (Studio
-- tests), the first 4 (ready players first) start the run and the rest wait in
-- the lobby for the next one.
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
-- Bots (Team F, GDD §3.6): the party is filled up to 3 heroes with bot
-- elephants (BotRoster). Bots are ON by default; each human can toggle
-- C2S.SetBotFill, and bots are used if ANY human in the party has fill on (solo
-- with fill off is a 1-player run). Bots appear in the Lobby payload with
-- isBot = true and ready = true but never count toward (or block) the
-- countdown. Run members may press Ready during Results ("Play again"): they
-- come back to the lobby already readied, which starts the 5 s countdown with
-- bots re-filled.
--
-- API:
--   LobbyService.init()
--   LobbyService.onStart(fn(players: {Player}, classes: {[number]: string}, bots: {BotSpec}))  -- classes keyed by UserId
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

local LobbyService = {}

LobbyService.MAX_PARTY = LobbyRules.MAX_PARTY
LobbyService.ALL_READY_SECONDS = LobbyRules.ALL_READY_SECONDS
LobbyService.SOME_READY_SECONDS = LobbyRules.SOME_READY_SECONDS
LobbyService.AUTO_START_SECONDS = LobbyRules.AUTO_START_SECONDS -- nobody ready: start anyway (bots fill the party)
LobbyService.UPDATE_DEBOUNCE = 0.25 -- seconds; coalesces Ready / class / bot-fill spam
LobbyService.MIN_PARTY = 3 -- bots fill the party up to this many heroes
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
}
type BotSpec = { id: number, name: string, classId: string, isBot: boolean, role: string? }

local entries: { [Player]: Entry } = {}
local runActive = false
local runMembers: { [Player]: boolean } = {}
local countdownEndsAt: number? = nil
local countdownKind: string? = nil -- "ready" | "auto"
local countdownToken = 0
local startCallbacks: { (players: { Player }, classes: { [number]: string }, bots: { BotSpec }) -> () } = {}
local botRoster: { BotSpec } = {}
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

function LobbyService.spawnPosition(slot: number): Vector3
	local angle = (slot - 1) * (math.pi * 2 / 6)
	return LobbyService.CENTER + Vector3.new(math.cos(angle) * 12, 0, math.sin(angle) * 12)
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

-- Bot specs for this party of humans (deterministic per rosterSeed, so the
-- bots shown in the lobby are the ones that start the run).
local function rosterFor(humans: { Player }): { BotSpec }
	if not BotRoster or #humans == 0 or not botsEnabled(humans) then
		return {}
	end
	local taken, ids = {}, {}
	for _, p in humans do
		local e = entries[p]
		table.insert(taken, if e then e.classId else defaultClass())
		table.insert(ids, p.UserId)
	end
	local ok, specs = pcall(
		BotRoster.fill,
		math.min(#humans, LobbyService.MAX_PARTY),
		LobbyService.MAX_PARTY,
		LobbyService.MIN_PARTY,
		taken,
		Rng.new(rosterSeed),
		ids
	)
	if not ok or type(specs) ~= "table" then
		warn("[LobbyService] BotRoster.fill failed: " .. tostring(specs))
		return {}
	end
	return specs
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
		lastRosterSig = nil -- the run took the bot models; re-place them afterwards
		return
	end
	botRoster = rosterFor(nextParty())
	-- Only touch the bot models when the roster changed (QC2 minor 9).
	local sig = {}
	for _, b in botRoster do
		table.insert(sig, string.format("%d:%s:%s", b.id, b.classId, b.name))
	end
	local key = table.concat(sig, "|")
	if key == lastRosterSig then
		return
	end
	lastRosterSig = key
	if BotService and type(BotService.placeInLobby) == "function" then
		local positions = {}
		for i = 1, #botRoster do
			table.insert(positions, LobbyService.spawnPosition(3 + i))
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

function LobbyService.broadcast()
	refreshBots()
	local players: { [string]: any } = {}
	local nReady, nTotal = 0, 0
	local anyFill = false
	for p, e in entries do
		if p.Parent == Players then
			local inRun = runActive and runMembers[p] == true
			players[tostring(p.UserId)] = {
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
	-- Bots ride along, always "ready"; they never count toward the countdown.
	for _, b in botRoster do
		players[tostring(b.id)] =
			{ name = b.name, classId = b.classId, ready = true, inRun = false, isBot = true }
	end
	-- Per-recipient payload: `botFill` is the receiving player's own toggle;
	-- `botFillAny` says whether bots will come at all (any lobby human has fill on).
	for _, p in Players:GetPlayers() do
		local e = entries[p]
		local payload: any = {
			players = players,
			startsAt = countdownEndsAt, -- workspace:GetServerTimeNow() based; also set for the auto-start
			runActive = runActive,
			autoStart = countdownKind == "auto",
			botFill = if e then e.botFill else true,
			botFillAny = anyFill,
			botCount = #botRoster,
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
	local bots = rosterFor(party)
	for _, cb in startCallbacks do
		task.spawn(cb, party, classes, bots)
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
	bots: { BotSpec }
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
function LobbyService.returnToLobby(players: { Player })
	for i, p in players do
		local e = entries[p]
		if e then
			e.idleRuns = LobbyRules.afterRun(e.idleRuns, e.autoPulled, e.inputThisRun)
			e.autoPulled = false
			e.inputThisRun = false
			e.ready = e.playAgain
			e.playAgain = false
			e.sitOut = false
		end
		if p.Parent == Players then
			task.spawn(LobbyService.teleportCharacter, p, LobbyService.spawnPosition(i))
		end
	end
end

-- Remote handlers ------------------------------------------------------------------

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
			requestUpdate()
		end
		return
	end
	if e.ready == ready then
		return
	end
	-- Un-ready = sit out this start; it never cancels or lengthens the countdown.
	LobbyRules.setReady(e, ready)
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
	}
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

	-- Restore the saved class once the profile loads.
	if DataService and type(DataService.waitFor) == "function" then
		task.spawn(function()
			local ok, profile = pcall(DataService.waitFor, player)
			local e = entries[player]
			if not ok or not profile or not e then
				return
			end
			local saved = profile.selectedClass
			if type(saved) == "string" and saved ~= e.classId and isUnlocked(player, saved) then
				e.classId = saved
				requestUpdate()
			end
		end)
	end
end

local function onPlayerRemoving(player: Player)
	if not entries[player] then
		return
	end
	entries[player] = nil
	runMembers[player] = nil
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
	LobbyService.buildPad()

	local classIds = classOrder()
	Guard.connect(Net.C2S.SelectClass, { rate = 3, burst = 4, args = { Guard.T.string(32) } }, onSelectClass)
	Guard.connect(Net.C2S.SetReady, { rate = 2, burst = 3, args = { Guard.T.boolean() } }, onSetReady)
	Guard.onInput(noteInput)
	Guard.connect(Net.C2S.SetBotFill, { rate = 2, burst = 3, args = { Guard.T.boolean() } }, onSetBotFill)
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
