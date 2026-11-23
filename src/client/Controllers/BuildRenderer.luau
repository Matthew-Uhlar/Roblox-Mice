--!strict
-- BuildRenderer (iteration 6, team Client): draws the builder elephant's
-- turrets and barricades, their small HP bars, the placement ghost and the
-- HUD counter data.
--
--  * Structures come from Net.S2C.Fx (Util/BuildMath.applyFx: Combat/World's
--    build / buildHp / buildEnd events) and, if SnapshotCodec ever gets a structure kind band
--    (kindClass -> "turret" / "barricade"), from the enemy snapshots too.
--    Lifetimes expire locally as a fallback (BuildMath.expire).
--  * Models are Visuals/BuildModels, pooled per kind, low-detail on low-spec
--    devices and past LOD_DISTANCE from the camera focus.
--  * Turret heads turn toward the nearest mouse in range (HordeRenderer.nearest)
--    and flash on a shot Fx ({t = "buildShot", id, tx, tz}).
--  * Placement ghost: while a ready ability slot holds a placement ability
--    (BuildMath.placementKind: Deploy Turret / Barricade), a see-through model
--    sits at the aim point clamped to the cast range (InputController.previewAim:
--    the mouse, a deflected right stick, or a phone drag on that slot's button).
--  * State "buildCount" = {turret = {n, cap}, barricade = {n, cap}, builder = bool}
--    for the HUD ("Turrets 1/2"): PlayerHud counts win, else the drawn ones.
--  * BuildRenderer.repairPulse(x, z, r): green flash on the structures in r
--    (FxController calls it for the Repair Pulse ability Fx).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Remotes = require(Client.Util.Remotes)
local Device = require(Client.Util.Device)
local Defs = require(Client.Util.Defs)
local BuildMath = require(Client.Util.BuildMath)
local BuildModels = require(Client.Visuals.BuildModels)
local State = require(script.Parent.State)

local BuildRenderer = {}

BuildRenderer.LOD_DISTANCE = 110 -- full detail within this of the camera focus
BuildRenderer.AIM_HZ = 8
BuildRenderer.MAX_DRAWN = 40 -- hard cap (PvP: 2 per hero x 10 heroes x 2 kinds)

local LOW = Device.lowSpec()
local GHOST_OK = Color3.fromRGB(255, 220, 90)
local REPAIR = Color3.fromRGB(110, 235, 120)
local BAR_ALLY = Color3.fromRGB(110, 220, 90)
local BAR_ENEMY = Color3.fromRGB(235, 70, 60)
local BAR_NEUTRAL = Color3.fromRGB(245, 170, 60)
local HP_HEIGHT = { turret = 4.1, barricade = 4.4 }

type Drawn = {
	s: BuildMath.Structure,
	built: BuildModels.Built,
	bar: BuildModels.HpBar,
	low: boolean,
	headYaw: number,
	targetYaw: number,
	flashUntil: number,
	repairUntil: number,
	shownHp: number,
	placed: boolean,
}

local set = BuildMath.newSet()
local drawn: { [string]: Drawn } = {}
local folder: Folder? = nil
local connections: { any } = {}
local unsubs: { () -> () } = {}
local ghost: { [string]: BuildModels.Built } = {}
local ghostRing: BasePart? = nil
local aimAcc = 0
local lastCountSig = ""

local codec: any = nil
local structKindCache: { [number]: string | false } = {}

local function loadCodec(): any
	if codec == nil then
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		local combat = shared and shared:FindFirstChild("Combat")
		local mod = combat and combat:FindFirstChild("SnapshotCodec")
		local ok, res = false, nil
		if mod and mod:IsA("ModuleScript") then
			ok, res = pcall(require, mod)
		end
		codec = if ok and type(res) == "table" then res else false
	end
	return codec or nil
end

-- "turret" | "barricade" | nil for a snapshot kind (SnapshotCodec.kindClass).
function BuildRenderer.snapshotKind(kind: number): string?
	local cached = structKindCache[kind]
	if cached ~= nil then
		return cached or nil
	end
	local c = loadCodec()
	local out: string? = nil
	if c and type(c.kindClass) == "function" then
		local ok, cls = pcall(c.kindClass, kind)
		if ok then
			out = BuildMath.structureKind(cls)
			if out == nil and cls == "structure" and type(c.structureKind) == "function" then
				local ok2, k2 = pcall(c.structureKind, kind)
				out = if ok2 then BuildMath.structureKind(k2) else nil
			end
		end
	end
	structKindCache[kind] = out or false
	return out
end

local arenaHeight: any = nil
local function groundY(x: number, z: number): number
	if arenaHeight == nil then
		local ok, mod = pcall(function()
			return require(Client.Visuals:FindFirstChild("ArenaHeight") :: any) :: any
		end)
		arenaHeight = if ok and type(mod) == "table" then mod else false
	end
	if arenaHeight then
		local ok, h = pcall(arenaHeight.at, x, z)
		if ok and type(h) == "number" then
			return h
		end
	end
	return 0
end

local hordeMod: any = nil
local function horde(): any
	if hordeMod == nil then
		local ok, mod = pcall(require, script.Parent.HordeRenderer)
		hordeMod = if ok and type(mod) == "table" then mod else false
	end
	return hordeMod or nil
end

local function getFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "TrunkfallBuilds"
	nf.Parent = workspace
	folder = nf
	return nf
end

local function squadsMod(): any
	return Defs.module("SquadColors")
end

-- The structure's owner as seen by me: "self" | "ally" | "enemy" | "neutral".
local function relation(s: BuildMath.Structure): string
	local me = State.localUserId()
	if s.owner ~= nil and s.owner == me then
		return "self"
	end
	local mine = State.mySquad()
	local theirs = s.squad or (if s.owner ~= nil then State.squadOf(s.owner) else nil)
	if mine == nil or theirs == nil then
		-- PvE / unknown owner: friendly unless PvP says otherwise
		return if s.owner == nil then "ally" else "neutral"
	end
	return if mine == theirs then "ally" else "enemy"
end

local function stripeColor(s: BuildMath.Structure): Color3
	local sq = s.squad or (if s.owner ~= nil then State.squadOf(s.owner) else nil)
	local mod = squadsMod()
	if sq ~= nil and mod and type(mod.rgb) == "function" then
		local ok, c = pcall(mod.rgb, sq)
		if ok and type(c) == "table" then
			return Color3.fromRGB(c[1] or 255, c[2] or 204, c[3] or 51)
		end
	end
	return Color3.fromRGB(255, 204, 51)
end

local function barColor(rel: string): Color3
	if rel == "self" or rel == "ally" then
		return BAR_ALLY
	elseif rel == "enemy" then
		return BAR_ENEMY
	end
	return BAR_NEUTRAL
end

local function focusPos(): Vector3?
	local cam = workspace.CurrentCamera
	return if cam then cam.Focus.Position else nil
end

local function wantLow(s: BuildMath.Structure): boolean
	if LOW then
		return true
	end
	local f = focusPos()
	if not f then
		return false
	end
	local dx, dz = s.x - f.X, s.z - f.Z
	return dx * dx + dz * dz > BuildRenderer.LOD_DISTANCE * BuildRenderer.LOD_DISTANCE
end

local function build(s: BuildMath.Structure, low: boolean): BuildModels.Built
	local opts = { low = low, color = stripeColor(s), len = s.len }
	local b = if s.kind == "barricade" then BuildModels.barricade(opts) else BuildModels.turret(opts)
	b.model.Parent = getFolder()
	return b
end

local function removeDrawn(id: string, puff: boolean)
	local d = drawn[id]
	if not d then
		return
	end
	drawn[id] = nil
	if puff then
		local okP, Particles = pcall(require, Client.Visuals.Particles)
		if okP and type(Particles) == "table" and type(Particles.burst) == "function" then
			pcall(Particles.burst, "boomSmoke", Vector3.new(d.s.x, groundY(d.s.x, d.s.z) + 1.5, d.s.z), 3)
		end
	end
	d.built.model:Destroy()
end

local function count(): number
	local n = 0
	for _ in drawn do
		n += 1
	end
	return n
end

local function ensureDrawn(s: BuildMath.Structure): Drawn?
	local d = drawn[s.id]
	local low = wantLow(s)
	if d and d.low ~= low and d.s.kind == s.kind then
		-- LOD switch: rebuild at the other detail
		d.built.model:Destroy()
		d.built = build(s, low)
		d.bar = BuildModels.hpBar(d.built.root, HP_HEIGHT[s.kind] or 4, if s.kind == "barricade" then 4 else 3)
		d.low = low
		d.placed = false
		d.shownHp = -1
	end
	if d then
		return d
	end
	if count() >= BuildRenderer.MAX_DRAWN then
		return nil
	end
	local b = build(s, low)
	local nd: Drawn = {
		s = s,
		built = b,
		bar = BuildModels.hpBar(b.root, HP_HEIGHT[s.kind] or 4, if s.kind == "barricade" then 4 else 3),
		low = low,
		headYaw = s.yaw,
		targetYaw = s.yaw,
		flashUntil = 0,
		repairUntil = 0,
		shownHp = -1,
		placed = false,
	}
	drawn[s.id] = nd
	-- a little "built!" pop
	local okP, Particles = pcall(require, Client.Visuals.Particles)
	if okP and type(Particles) == "table" and type(Particles.burst) == "function" then
		pcall(Particles.burst, "boomSmoke", Vector3.new(s.x, groundY(s.x, s.z) + 0.5, s.z), 2)
	end
	return nd
end

----------------------------------------------------------------------
-- Intake
----------------------------------------------------------------------

local function onFx(batch: any)
	if type(batch) ~= "table" then
		return
	end
	local now = State.serverNow()
	for _, ev in batch do
		if type(ev) ~= "table" then
			continue
		end
		local t = ev.t
		if t == "buildShot" or t == "turretShot" or t == "turretFire" then
			local d = if ev.id ~= nil then drawn[tostring(ev.id)] else nil
			if d then
				d.flashUntil = os.clock() + 0.12
				local tx, tz = tonumber(ev.tx), tonumber(ev.tz)
				if tx and tz then
					d.targetYaw = math.atan2(tx - d.s.x, tz - d.s.z)
				end
			end
			continue
		end
		local action, id = BuildMath.applyFx(set, ev, now)
		if action == "remove" and id then
			removeDrawn(id, true)
		end
	end
end

local function onSnapshot(buf: any)
	if typeof(buf) ~= "buffer" then
		return
	end
	local c = loadCodec()
	if not c or type(c.kindClass) ~= "function" or type(c.decode) ~= "function" then
		return
	end
	local ok, serverTime, snaps = pcall(c.decode, buf)
	if not ok or type(snaps) ~= "table" then
		return
	end
	local now = if type(serverTime) == "number" and serverTime > 0 then serverTime else State.serverNow()
	for _, e in snaps do
		local kind = tonumber(e.kind)
		local sk = if kind then BuildRenderer.snapshotKind(kind) else nil
		if sk then
			BuildMath.applySnapshot(set, e, sk, now)
		end
	end
end

----------------------------------------------------------------------
-- Placement ghost
----------------------------------------------------------------------

local inputMod: any = nil
local function input(): any
	if inputMod == nil then
		local ok, mod = pcall(require, script.Parent.InputController)
		inputMod = if ok and type(mod) == "table" then mod else false
	end
	return inputMod or nil
end

local classInfoMod: any = nil
local function classInfo(): any
	if classInfoMod == nil then
		local ok, mod = pcall(require, Client.UI.ClassInfo)
		classInfoMod = if ok and type(mod) == "table" then mod else false
	end
	return classInfoMod or nil
end

type SlotPlace = { slot: number, kind: string, range: number, len: number, reach: number }

-- Placement abilities in my live slots: { {slot, kind, range, len} }.
local slotCacheSig = ""
local slotCache: { SlotPlace } = {}
local function placementSlots(): { SlotPlace }
	local classId = State.myClassId()
	local ci = classInfo()
	if not classId or not ci then
		return {}
	end
	local slots = State.abilitySlots()
	local sig = classId
	for _, s in slots do
		sig ..= "|" .. tostring(s.id)
	end
	if sig == slotCacheSig then
		return slotCache
	end
	local out: { SlotPlace } = {}
	for _, s in slots do
		local okD, def = pcall(ci.abilityDef, classId, s.id)
		local kind = if okD then BuildMath.placementKind(def) else nil
		if kind and type(def) == "table" then
			table.insert(out, {
				slot = s.slot,
				kind = kind,
				range = tonumber(def.distance) or BuildMath.CAST_RANGE,
				-- Config/ClassAbilities: barricade area = half length, turret area = targeting range
				len = if kind == "barricade" and tonumber(def.area)
					then 2 * (tonumber(def.area) :: number)
					else BuildMath.BARRICADE_LENGTH,
				reach = if kind == "turret" then tonumber(def.area) or BuildMath.TURRET_RANGE else 0,
			})
		end
	end
	slotCacheSig, slotCache = sig, out
	return out
end

local function hideGhosts()
	for _, g in ghost do
		g.model.Parent = nil
	end
	if ghostRing then
		ghostRing.Parent = nil
	end
end

local function ghostFor(kind: string, len: number): BuildModels.Built
	local g = ghost[kind]
	if g and (kind ~= "barricade" or math.abs((g.model:GetAttribute("Len") or 0) - len) < 0.01) then
		return g
	end
	if g then
		g.model:Destroy()
	end
	local ng = if kind == "barricade"
		then BuildModels.barricade({ low = true, len = len })
		else BuildModels.turret({ low = LOW })
	BuildModels.ghostify(ng, GHOST_OK)
	ng.model:SetAttribute("Len", len)
	ghost[kind] = ng
	return ng
end

local function ensureRing(): BasePart
	local r = ghostRing
	if r then
		return r
	end
	local p = Instance.new("Part")
	p.Name = "TurretRangeGhost"
	p.Shape = Enum.PartType.Cylinder
	p.Material = Enum.Material.Neon
	p.Color = GHOST_OK
	p.Transparency = 0.9
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	ghostRing = p
	return p
end

local function rootPart(): BasePart?
	local char = Players.LocalPlayer and Players.LocalPlayer.Character
	local r = char and char:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function updateGhost()
	if not State.inCombat() then
		hideGhosts()
		return
	end
	local places = placementSlots()
	local ic = input()
	local root = rootPart()
	if #places == 0 or not ic or type(ic.previewAim) ~= "function" or not root then
		hideGhosts()
		return
	end
	local hud = State.get("hud")
	if type(hud) == "table" and hud.downed == true then
		hideGhosts()
		return
	end
	local ax, az, slot = ic.previewAim()
	if ax == nil or az == nil then
		hideGhosts()
		return
	end
	local pick: SlotPlace? = nil
	for _, p in places do
		local ready = State.abilityCooldown(p.slot) <= 0.15
		if slot ~= nil then
			if p.slot == slot then
				pick = p
				break
			end
		elseif ready then
			pick = p
			break
		end
	end
	if not pick then
		hideGhosts()
		return
	end
	local pos = root.Position
	local x, z, yaw = BuildMath.placement(pos.X, pos.Z, ax, az, pick.range)
	local y = groundY(x, z)
	for kind, g in ghost do
		if kind ~= pick.kind then
			g.model.Parent = nil
		end
	end
	local g = ghostFor(pick.kind, pick.len)
	g.model.Parent = getFolder()
	BuildModels.place(g, x, y, z, yaw)
	local ring = ensureRing()
	if pick.kind == "turret" then
		local d = pick.reach * 2
		ring.Size = Vector3.new(0.1, d, d)
		ring.CFrame = CFrame.new(x, y + 0.06, z) * CFrame.Angles(0, 0, math.pi / 2)
		ring.Parent = getFolder()
	else
		ring.Parent = nil
	end
end

----------------------------------------------------------------------
-- Per frame
----------------------------------------------------------------------

local function publishCount()
	local me = State.localUserId()
	local hud = State.get("hud")
	local out: { [string]: any } = { builder = #placementSlots() > 0 }
	for _, kind in { "turret", "barricade" } do
		local n, cap = BuildMath.hudCount(hud, kind)
		if n == nil then
			n = #BuildMath.owned(set, me, kind)
		end
		out[kind] = {
			n = n,
			cap = cap or (if kind == "turret" then BuildMath.TURRET_CAP else BuildMath.BARRICADE_CAP),
		}
	end
	local sig = string.format(
		"%s|%d/%d|%d/%d",
		tostring(out.builder),
		out.turret.n,
		out.turret.cap,
		out.barricade.n,
		out.barricade.cap
	)
	if sig ~= lastCountSig then
		lastCountSig = sig
		State.set("buildCount", out)
	end
end

local function render(dt: number)
	local now = State.serverNow()
	for _, id in BuildMath.expire(set, now, 1.5) do
		removeDrawn(id, true)
	end
	for id in drawn do
		if set.items[id] == nil then
			removeDrawn(id, false)
		end
	end
	aimAcc += dt
	local retarget = aimAcc >= 1 / BuildRenderer.AIM_HZ
	if retarget then
		aimAcc = 0
	end
	local clock = os.clock()
	local h = horde()
	for _, s in set.items do
		local d = ensureDrawn(s)
		if not d then
			continue
		end
		d.s = s
		local y = groundY(s.x, s.z)
		local rp = d.built.root.Position
		if not d.placed or math.abs(rp.X - s.x) + math.abs(rp.Z - s.z) > 0.05 or math.abs(d.built.yaw - s.yaw) > 1e-3 then
			BuildModels.place(d.built, s.x, y, s.z, s.yaw)
			BuildModels.aim(d.built, d.headYaw)
			d.placed = true
		end
		if s.kind == "turret" then
			if retarget and h and type(h.nearest) == "function" then
				local reach = if s.range > 0 then s.range else BuildMath.TURRET_RANGE
				local ok, ex, ez = pcall(h.nearest, s.x, s.z, reach)
				if ok and ex and ez then
					d.targetYaw = math.atan2(ex - s.x, ez - s.z)
				end
			end
			local diff = (d.targetYaw - d.headYaw + math.pi) % (2 * math.pi) - math.pi
			if math.abs(diff) > 1e-3 then
				d.headYaw += diff * math.min(1, dt * 10)
				BuildModels.aim(d.built, d.headYaw)
			end
			local eye = d.built.eye
			if eye then
				local flash = clock < d.flashUntil
				local want = if flash then Color3.new(1, 1, 1) else Color3.fromRGB(255, 204, 51)
				if eye.Color ~= want then
					eye.Color = want
				end
			end
		end
		local rel = relation(s)
		local hp = s.hpFrac
		local repairing = clock < d.repairUntil
		if math.abs(hp - d.shownHp) > 0.004 or repairing then
			d.shownHp = hp
			d.bar.set(hp, if repairing then REPAIR else barColor(rel))
		end
	end
	updateGhost()
	publishCount()
end

-- Repair Pulse: a green flash on the HP bars of the structures within r.
function BuildRenderer.repairPulse(x: number, z: number, r: number)
	local untilT = os.clock() + 0.6
	for _, d in drawn do
		local dx, dz = d.s.x - x, d.s.z - z
		if dx * dx + dz * dz <= (r + 2) * (r + 2) then
			d.repairUntil = untilT
			d.shownHp = -1
		end
	end
end

-- Live structure positions (minimap / tests): { {kind, x, z, owner?} }.
function BuildRenderer.list(): { { kind: string, x: number, z: number, owner: number? } }
	local out = {}
	for _, s in set.items do
		table.insert(out, { kind = s.kind, x = s.x, z = s.z, owner = s.owner })
	end
	return out
end

function BuildRenderer.clear()
	for id in drawn do
		removeDrawn(id, false)
	end
	table.clear(set.items)
	hideGhosts()
end

function BuildRenderer.init()
	table.insert(connections, Remotes.on(Remotes.S2C.Fx, onFx))
	table.insert(connections, Remotes.on(Remotes.S2C.Snapshot, onSnapshot))
	table.insert(
		connections,
		RunService.RenderStepped:Connect(function(dt)
			local ok, err = pcall(render, dt)
			if not ok then
				warn("[Trunkfall] BuildRenderer: " .. tostring(err))
			end
		end)
	)
	-- a new run / the lobby: nothing carries over
	local lastPhase: string? = nil
	table.insert(
		unsubs,
		State.subscribe("run", function()
			local p = State.phase()
			if p ~= lastPhase and (p == nil or p == "Lobby" or p == "Results") then
				BuildRenderer.clear()
			end
			lastPhase = p
		end, true)
	)
end

function BuildRenderer.destroy()
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	BuildRenderer.clear()
	for _, g in ghost do
		g.model:Destroy()
	end
	table.clear(ghost)
	if ghostRing then
		ghostRing:Destroy()
		ghostRing = nil
	end
	if folder then
		folder:Destroy()
		folder = nil
	end
end

return BuildRenderer
