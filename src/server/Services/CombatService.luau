--!strict
-- CombatService: Roblox-side wrapper around the pure Combat/World (Team B).
--
--   CombatService.start(world, players)   Heartbeat loop: sync positions -> fixed-step
--                                         world:step -> Humanoid display -> broadcast
--   CombatService.stop()
--   CombatService.events                  Signal: :Connect(fn(event)) fired once per drained
--                                         world event ({type, id?, amount?, kind?})
--   CombatService.now()                   the sim clock (workspace:GetServerTimeNow())
--   CombatService.getWorld()              current world or nil
--   CombatService.setPlayers(players)     replace the tracked player list
--   CombatService.placePlayer(player, x, z)  the server moved this character (respawn into
--                                         the arena): world + MoveGuard follow, with a grace
--   CombatService.stats                   { stepMs, steps } rolling server-cost numbers
--
-- Participants: the tracked list holds only real Players (run members, Studio test
-- players with UserId -1..-8 included); they are synced from their HumanoidRootPart.
-- Bots (Ids.isBot) are driven by BotService through world:setPlayerPosition.
--
-- Movement validation (QC2 M1): every synced position goes through Combat/MoveGuard
-- (moveSpeed x state factor x dt x 1.3 + slack; server dashes / spawns get a grace).
-- A violation clamps the world position, PivotTo's the character back and fires
-- {type = "moveViolation", id, amount = violations this stage}; RunDirector counts
-- them and marks the run unranked. A point inside a rock is pushed out by World; a
-- deep push also snaps the character.
--
-- Extra events on CombatService.events: "moveViolation" (above) and
-- {type = "fatal", kind = error} once after MAX_STEP_FAILURES consecutive failed
-- world steps (RunDirector treats it as a crash: wipe payout + teardown).
--
-- World owns life and death. Humanoids are display only: Health mirrors world hp,
-- the Dead state is disabled, BreakJointsOnDeath is false and the default "Health"
-- regen script is removed. WalkSpeed = moveSpeed (x0.3 downed, x0.6 slowed, 0 spectator).
--
-- Network (run members only, QC1 #14): Snapshot (UnreliableRemoteEvent) at 10 Hz as
-- SnapshotCodec chunks (<= 850 B each), culled per client to enemies within
-- FxFilter.SNAPSHOT_RADIUS (bosses always); Fx (reliable) once per sim step, culled per
-- client by FxFilter.forViewer, only when non-empty.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Combat = Shared:WaitForChild("Combat")
local SnapshotCodec = require(Combat:WaitForChild("SnapshotCodec")) :: any
local WorldModule = require(Combat:WaitForChild("World")) :: any
local Ids = require(Shared:WaitForChild("Util"):WaitForChild("Ids")) :: any
local MoveGuard = require(Combat:WaitForChild("MoveGuard")) :: any
local FxFilter = require(Combat:WaitForChild("FxFilter")) :: any
local Guard = require(script.Parent.Guard)

local CombatService = {}

CombatService.STEP = 1 / 30 -- fixed sim step
CombatService.MAX_STEPS_PER_FRAME = 4 -- catch-up limit after a hitch
CombatService.SNAPSHOT_HZ = 10 -- was 15: ~20 KB/s at the 220 cap instead of 30
CombatService.MAX_STEP_FAILURES = 30 -- consecutive failed steps -> "fatal" event
CombatService.ACTIVITY_DISTANCE = 6 -- studs walked that count as player input (AFK rule)
CombatService.ACTIVITY_INTERVAL = 5 -- seconds between activity notes per player
CombatService.DOWNED_SPEED = WorldModule.DOWNED_SPEED or 0.3
CombatService.SLOW_SPEED = WorldModule.PLAYER_SLOW or 0.6

-- Tiny Signal -------------------------------------------------------------------------------

type Connection = { Connected: boolean, Disconnect: (self: Connection) -> () }

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ handlers = {} :: { [any]: (...any) -> () } }, Signal)
end

function Signal:Connect(fn: (...any) -> ()): Connection
	local key = {}
	self.handlers[key] = fn
	local conn = { Connected = true }
	function conn.Disconnect(c: any)
		c.Connected = false
		self.handlers[key] = nil
	end
	return conn :: any
end

function Signal:Fire(...: any)
	for _, fn in self.handlers do
		local ok, err = pcall(fn, ...)
		if not ok then
			warn("[CombatService] event handler error:", err)
		end
	end
end

function Signal:Wait(): ...any
	local thread = coroutine.running()
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

CombatService.events = Signal.new()

-- State -------------------------------------------------------------------------------------

local world: any = nil
local tracked: { Player } = {}
local heartbeat: RBXScriptConnection? = nil
local removingConn: RBXScriptConnection? = nil
local accumulator = 0
local lastSnapshotAt = 0
local snapshotRemote: any = nil
local fxRemote: any = nil
local guard: any = nil -- MoveGuard for the current world
local stepFailures = 0
local fatalSent = false
local moved: { [number]: number } = {} -- studs walked since the last activity note
local lastActivity: { [number]: number } = {}

CombatService.stats = { stepMs = 0, steps = 0, snapshotBytes = 0 }

function CombatService.now(): number
	return Workspace:GetServerTimeNow()
end

function CombatService.getWorld(): any
	return world
end

function CombatService.setPlayers(players: { Player })
	tracked = table.clone(players)
end

-- Humanoid display --------------------------------------------------------------------------

local function prepareCharacter(character: Model, humanoid: Humanoid)
	if character:GetAttribute("TrunkfallCombatReady") then
		return
	end
	character:SetAttribute("TrunkfallCombatReady", true)
	humanoid.BreakJointsOnDeath = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	humanoid.RequiresNeck = false
	local regen = character:FindFirstChild("Health")
	if regen and regen:IsA("Script") then
		regen:Destroy() -- Roblox's default regen; World owns healing
	end
end

local function rootOf(player: Player): (BasePart?, Humanoid?, Model?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local hum = character:FindFirstChildOfClass("Humanoid")
	return if hrp and hrp:IsA("BasePart") then hrp else nil, hum, character
end

local function finite(v: number): boolean
	return v == v and v ~= math.huge and v ~= -math.huge
end

-- CosmeticsService (Fix Team 1) hides the trail across a teleport.
local function suspendTrail(player: Player)
	local mod = script.Parent:FindFirstChild("CosmeticsService")
	if not mod then
		return
	end
	local ok, C = pcall(require, mod)
	if ok and type(C) == "table" and type(C.suspendTrail) == "function" then
		pcall(C.suspendTrail, player)
	end
end

local function pivotCharacter(player: Player, x: number, z: number)
	local hrp = rootOf(player)
	local character = player.Character
	if not hrp or not character then
		return
	end
	suspendTrail(player)
	local cur = hrp.CFrame
	character:PivotTo(CFrame.new(x, cur.Position.Y, z) * cur.Rotation)
	hrp.AssemblyLinearVelocity = Vector3.zero
end

local function noteActivity(player: Player, id: number, dist: number, now: number)
	local m = (moved[id] or 0) + dist
	if
		m >= CombatService.ACTIVITY_DISTANCE
		and now - (lastActivity[id] or -math.huge) >= CombatService.ACTIVITY_INTERVAL
	then
		moved[id] = 0
		lastActivity[id] = now
		pcall(Guard.noteInput, player)
	else
		moved[id] = m
	end
end

local function syncPositions(now: number)
	for _, player in tracked do
		local id = player.UserId
		if player.Parent ~= Players then
			continue
		end
		local hrp = rootOf(player)
		local info = world:getPlayer(id)
		if not hrp or not info then
			continue
		end
		local p = hrp.Position
		if not (finite(p.X) and finite(p.Z)) then
			continue
		end
		local px, pz = guard:position(id)
		local ax, az, verdict = guard:check(id, p.X, p.Z, now, info.moveSpeed, MoveGuard.stateFactor(info))
		if verdict == "ignored" then
			continue -- stale sample after a server move: the world keeps its position
		end
		local wx, wz = world:setPlayerPosition(id, ax, az)
		if not wx or not wz then
			continue
		end
		guard:commit(id, wx, wz)
		if px and pz and verdict == "ok" then
			noteActivity(player, id, math.sqrt((wx - px) ^ 2 + (wz - pz) ^ 2), now)
		end
		if verdict == "violation" then
			pivotCharacter(player, wx, wz)
			CombatService.events:Fire({ type = "moveViolation", id = id, amount = guard:violations(id) })
		elseif (wx - ax) ^ 2 + (wz - az) ^ 2 > MoveGuard.PUSH_SNAP * MoveGuard.PUSH_SNAP then
			-- deep inside a rock (or outside the arena): put the character where the world has it
			pivotCharacter(player, wx, wz)
			guard:place(id, wx, wz, now, MoveGuard.SNAP_GRACE)
		end
	end
end

local function applyHumanoids()
	for _, player in tracked do
		local id = player.UserId
		if player.Parent ~= Players then
			continue
		end
		local info = world:getPlayer(id)
		local _, hum, character = rootOf(player)
		if not info or not hum or not character then
			continue
		end
		prepareCharacter(character, hum)
		local maxHp = math.max(1, info.maxHp)
		if hum.MaxHealth ~= maxHp then
			hum.MaxHealth = maxHp
		end
		-- never 0: the Humanoid must stay alive, World decides downed/dead
		local hp = math.clamp(info.hp, 0.01, maxHp)
		if math.abs(hum.Health - hp) > 0.01 then
			hum.Health = hp
		end
		local speed = info.moveSpeed or 16
		if info.dead then
			speed = 0
		elseif info.downed then
			speed *= CombatService.DOWNED_SPEED
		elseif info.slowed then
			speed *= CombatService.SLOW_SPEED
		end
		if math.abs(hum.WalkSpeed - speed) > 0.01 then
			hum.WalkSpeed = speed
		end
		character:SetAttribute("Downed", info.downed == true)
		character:SetAttribute("Spectator", info.dead == true)
	end
end

local function applyTeleports(now: number)
	for _, tp in world:drainTeleports() do
		if not Ids.isBot(tp.id) then
			local player = Players:GetPlayerByUserId(tp.id)
			if player and table.find(tracked, player) then
				-- a server-issued dash: the only legal "teleport" for a human
				guard:place(tp.id, tp.x, tp.z, now, MoveGuard.TELEPORT_GRACE)
				pivotCharacter(player, tp.x, tp.z)
			end
		end
	end
end

local function viewerPos(player: Player): (number?, number?)
	local info = world and world:getPlayer(player.UserId)
	if info then
		return info.x, info.z
	end
	return nil, nil
end

local function broadcastSnapshot(now: number)
	local snaps = world:snapshot()
	local bytes = 0
	for _, player in tracked do
		if player.Parent == Players then
			local vx, vz = viewerPos(player)
			local mine = FxFilter.snapshotForViewer(snaps, vx, vz)
			for _, buf in SnapshotCodec.encodeChunks(mine, now) do
				bytes += buffer.len(buf)
				snapshotRemote:FireClient(player, buf)
			end
		end
	end
	CombatService.stats.snapshotBytes = bytes
end

local function sendFx(fx: { any })
	for _, player in tracked do
		if player.Parent == Players then
			local vx, vz = viewerPos(player)
			local mine = FxFilter.forViewer(fx, vx, vz, nil, player.UserId)
			if #mine > 0 then
				fxRemote:FireClient(player, mine)
			end
		end
	end
end

local function fireEvents()
	for _, ev in world:drainEvents() do
		CombatService.events:Fire(ev)
	end
end

local function onHeartbeat(dt: number)
	if not world then
		return
	end
	accumulator = math.min(accumulator + dt, CombatService.STEP * CombatService.MAX_STEPS_PER_FRAME)
	if accumulator < CombatService.STEP then
		return
	end
	local okSync, syncErr = pcall(syncPositions, CombatService.now())
	if not okSync then
		warn("[CombatService] position sync failed:", syncErr)
	end
	while accumulator >= CombatService.STEP do
		accumulator -= CombatService.STEP
		local now = CombatService.now()
		local t0 = os.clock()
		local ok, fxOrErr = pcall(world.step, world, CombatService.STEP, now)
		local ms = (os.clock() - t0) * 1000
		local st = CombatService.stats
		st.steps += 1
		st.stepMs = st.stepMs * 0.95 + ms * 0.05
		if not ok then
			stepFailures += 1
			warn("[CombatService] world:step failed:", fxOrErr)
			if stepFailures >= CombatService.MAX_STEP_FAILURES and not fatalSent then
				-- the world is stuck (a bad pattern errors every frame): let RunDirector end the run
				fatalSent = true
				CombatService.events:Fire({ type = "fatal", kind = tostring(fxOrErr) })
			end
			accumulator = 0
			return
		end
		stepFailures = 0
		local fx = fxOrErr :: { any }
		if #fx > 0 then
			sendFx(fx)
		end
		applyTeleports(now)
		fireEvents()
		if not world then
			return -- a handler stopped combat
		end
	end
	applyHumanoids()
	local now = CombatService.now()
	if now - lastSnapshotAt >= 1 / CombatService.SNAPSHOT_HZ then
		lastSnapshotAt = now
		broadcastSnapshot(now)
	end
end

-- The server moved this run member's character (e.g. a respawn pivoted into the
-- arena): the world and the movement guard follow, with a grace for stale samples.
function CombatService.placePlayer(player: Player, x: number, z: number)
	if not world or not guard or not table.find(tracked, player) then
		return
	end
	if not (finite(x) and finite(z)) then
		return
	end
	local wx, wz = world:setPlayerPosition(player.UserId, x, z)
	if wx and wz then
		guard:place(player.UserId, wx, wz, CombatService.now(), MoveGuard.RESPAWN_GRACE)
	end
end

-- Movement violations this stage (RunDirector also counts the events).
function CombatService.violations(player: Player): number
	return if guard then guard:violations(player.UserId) else 0
end

-- Lifecycle ---------------------------------------------------------------------------------

function CombatService.start(w: any, players: { Player })
	CombatService.stop()
	world = w
	tracked = table.clone(players or {})
	accumulator = 0
	lastSnapshotAt = 0
	snapshotRemote = Net.get(Net.S2C.Snapshot)
	fxRemote = Net.get(Net.S2C.Fx)
	guard = MoveGuard.new()
	stepFailures = 0
	fatalSent = false
	moved, lastActivity = {}, {}
	local now = CombatService.now()
	for _, player in tracked do
		local _, hum, character = rootOf(player)
		if hum and character then
			prepareCharacter(character, hum)
		end
		-- the arena teleport may land a little after the world starts
		local info = w:getPlayer(player.UserId)
		if info then
			guard:place(player.UserId, info.x, info.z, now, MoveGuard.START_GRACE)
		end
	end
	removingConn = Players.PlayerRemoving:Connect(function(player)
		local i = table.find(tracked, player)
		if i then
			table.remove(tracked, i)
		end
		if world then
			pcall(world.removePlayer, world, player.UserId)
		end
		if guard then
			guard:remove(player.UserId)
		end
	end)
	heartbeat = RunService.Heartbeat:Connect(onHeartbeat)
end

function CombatService.stop()
	if heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
	if removingConn then
		removingConn:Disconnect()
		removingConn = nil
	end
	if world then
		-- deliver anything still queued (e.g. the bossDead of the final step)
		pcall(fireEvents)
	end
	-- Combat state must not leak into the lobby (QC1 #13).
	for _, player in tracked do
		pcall(function()
			local _, hum, character = rootOf(player)
			if character then
				character:SetAttribute("TrunkfallCombatReady", nil)
				character:SetAttribute("Downed", nil)
				character:SetAttribute("Spectator", nil)
			end
			if hum then
				hum.Health = hum.MaxHealth -- first: never re-enable Dead at 0.01 HP
				hum:SetStateEnabled(Enum.HumanoidStateType.Dead, true)
			end
		end)
	end
	world = nil
	guard = nil
	tracked = {}
end

return CombatService
