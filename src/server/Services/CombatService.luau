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
--   CombatService.stats                   { stepMs, steps } rolling server-cost numbers
--
-- Participants: ids > 0 are real players (UserId) and are synced from their
-- HumanoidRootPart. Any other id (bots, negative) is left alone: BotService drives
-- those through world:setPlayerPosition, and they have no Humanoid to manage here.
--
-- World owns life and death. Humanoids are display only: Health mirrors world hp,
-- the Dead state is disabled, BreakJointsOnDeath is false and the default "Health"
-- regen script is removed. WalkSpeed = moveSpeed (x0.3 downed, x0.6 slowed, 0 spectator).
--
-- Network: Snapshot (UnreliableRemoteEvent) ~15 Hz as SnapshotCodec chunks (<= 850 B
-- each, one FireAllClients per chunk); Fx (reliable) once per sim step with that step's
-- batch, only when non-empty.

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

local CombatService = {}

CombatService.STEP = 1 / 30 -- fixed sim step
CombatService.MAX_STEPS_PER_FRAME = 4 -- catch-up limit after a hitch
CombatService.SNAPSHOT_HZ = 15
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

local function syncPositions()
	for _, player in tracked do
		local id = player.UserId
		if player.Parent == Players then
			local hrp = rootOf(player)
			if hrp then
				local p = hrp.Position
				if finite(p.X) and finite(p.Z) then
					world:setPlayerPosition(id, p.X, p.Z)
				end
			end
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

local function applyTeleports()
	for _, tp in world:drainTeleports() do
		if not Ids.isBot(tp.id) then
			local player = Players:GetPlayerByUserId(tp.id)
			local hrp = if player then rootOf(player) else nil
			if player and hrp and player.Character then
				local cur = hrp.CFrame
				local target = CFrame.new(tp.x, cur.Position.Y, tp.z) * cur.Rotation
				player.Character:PivotTo(target)
			end
		end
	end
end

local function broadcastSnapshot(now: number)
	local chunks = SnapshotCodec.encodeChunks(world:snapshot(), now)
	local bytes = 0
	for _, buf in chunks do
		bytes += buffer.len(buf)
		snapshotRemote:FireAllClients(buf)
	end
	CombatService.stats.snapshotBytes = bytes
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
	syncPositions()
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
			warn("[CombatService] world:step failed:", fxOrErr)
			break
		end
		local fx = fxOrErr :: { any }
		if #fx > 0 then
			fxRemote:FireAllClients(fx)
		end
		applyTeleports()
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

-- Lifecycle ---------------------------------------------------------------------------------

function CombatService.start(w: any, players: { Player })
	CombatService.stop()
	world = w
	tracked = table.clone(players or {})
	accumulator = 0
	lastSnapshotAt = 0
	snapshotRemote = Net.get(Net.S2C.Snapshot)
	fxRemote = Net.get(Net.S2C.Fx)
	for _, player in tracked do
		local _, hum, character = rootOf(player)
		if hum and character then
			prepareCharacter(character, hum)
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
	world = nil
	tracked = {}
end

return CombatService
