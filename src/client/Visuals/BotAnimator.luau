--!strict
-- BotAnimator (v3 Graphics, client): procedural animation for the server's
-- part-built bot elephants (server Visuals/BotModel, workspace.Bots).
--
--   BotAnimator.step(dt, focus: Vector3?)       FxController calls it every frame
--   BotAnimator.attack(botId, classId?)         auto-attack pose (melee swing /
--                                               trunk aim + recoil / thrust / gust)
--   BotAnimator.cast(botId)                     ability pose (rear up, ears flare)
--   BotAnimator.revive(botId)                   stand-up hop
--   BotAnimator.compile(model) -> Rigged?       (also used by the preview tool)
--   BotAnimator.apply(r, D, A)                  writes the posed C0s
--
-- BotModel welds every part to the anchored Root ("RigWeld", C0 = rest offset)
-- and stores the skeleton in attributes (Bone_<name>, BoneParent_<name>, part
-- attribute Bone). The server only moves the Root (PivotTo), so the client can
-- rewrite each weld's C0 locally every frame: walk cycle from the Root's ground
-- speed (legs, body bob, trunk sway, ear flaps), class attack poses, the
-- ability rear-up, the downed slump (server attribute Downed) and the revive
-- hop. LOD: full skeleton within FULL studs of the camera focus (at most
-- FULL_CAP bots), legs only up to SIMPLE, rest pose beyond.

--
-- iter1 (team G):
--   * the SAME animation drives players wearing the Herd Suit (the character's
--     "HerdSuit" model, server Visuals/HeroDecor): BotAnimator.attack / cast /
--     revive / hit take a user id too. Suits are found on Players' characters.
--   * BotAnimator.hit(id) is a hit react (flinch, ears flare); the root pose
--     (flinch push, revive hop) is applied through the solve.
--   * smooth bots (VERIFIED #7): the server's Root CFrame updates are buffered
--     (GetPropertyChangedSignal) and the client draws the Root INTERP_DELAY
--     behind with a position + yaw lerp, overriding the replicated value
--     locally every frame; a jump > SNAP_DISTANCE snaps. Works with the current
--     per-Heartbeat PivotTo and with a 10-20 Hz server rate.

local Players = game:GetService("Players")

local Rig = require(script.Parent.Rig)

local BotAnimator = {}

BotAnimator.FULL = 60
BotAnimator.SIMPLE = 120
BotAnimator.FULL_CAP = 6
BotAnimator.RESCAN = 1
BotAnimator.INTERP_MIN = 0.05 -- seconds behind the newest server sample (adapts
BotAnimator.INTERP_MAX = 0.16 -- to 1.6x the measured server update interval)
BotAnimator.SNAP_DISTANCE = 30
BotAnimator.SUIT = "HerdSuit"

local IDENT = CFrame.identity
local B = Rig.B

-- Fx weapon kind of each class (Config/Classes weapon.kind) -> attack pose.
local SWING: { [string]: string } = {
	elephante = "melee",
	ele_fonte = "shoot",
	ellie_fawn = "shoot",
	le_fante = "thrust",
	filet = "melee",
	jumbo = "gust",
	fizzante = "lob",
	tinkerphant = "shoot", -- iteration 6: rivet bolts
	-- iteration 7 (team Mesh): the new classes
	ele_vation = "snipe", -- marksman: long steady aim-hold, hard recoil kick
	elephaid = "shoot", -- medic: light trunk bolts
	trunkillery = "mortar", -- artillery: squat, heavy upward lob, bounce back
}
BotAnimator.SWING = SWING

export type Rigged = {
	model: Model,
	root: BasePart,
	welds: { Weld },
	rest: { CFrame },
	rig: Rig.Compiled,
	legMask: { boolean },
	st: Rig.State,
	D: { CFrame },
	A: { CFrame },
	lastPos: Vector3?,
	posed: boolean,
	classId: string,
	detail: number,
	scale: number, -- v4: model attribute RigScale (bots are built at 0.65)
	-- iter1 smoothing (bots only: a suit's Root is welded to the character)
	smooth: boolean,
	samples: { { t: number, cf: CFrame } },
	interval: number,
	writing: boolean,
	conn: RBXScriptConnection?,
	owner: Model, -- the bot model, or the character wearing the suit
	rootPosed: boolean,
	lastYaw: number?,
}

local rigs: { [Model]: Rigged } = {}
local byId: { [number]: Model } = {}
local scanAt = 0

local LEG_BONES = { [B.legFL] = true, [B.legFR] = true, [B.legBL] = true, [B.legBR] = true }

function BotAnimator.compile(model: Model): Rigged?
	local root = model.PrimaryPart or model:FindFirstChild("Root")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local bones: { [string]: any } = {}
	for _, name in Rig.BONES do
		local pv = model:GetAttribute("Bone_" .. name)
		if typeof(pv) == "CFrame" then
			local parent = model:GetAttribute("BoneParent_" .. name)
			bones[name] = { pivot = pv, parent = if type(parent) == "string" then parent else nil }
		end
	end
	if next(bones) == nil then
		return nil
	end
	local specs, welds, rest = {}, {}, {}
	for _, d in model:GetDescendants() do
		if d:IsA("Weld") and d.Name == "RigWeld" and d.Part0 == root then
			local p = d.Part1
			local bone = p and p:GetAttribute("Bone")
			if p and type(bone) == "string" then
				table.insert(welds, d)
				table.insert(rest, d.C0)
				table.insert(specs, { offset = d.C0, bone = bone })
			end
		end
	end
	if #welds == 0 then
		return nil
	end
	local rig = Rig.compile(specs, bones)
	local legMask = {}
	for i = 1, #welds do
		legMask[i] = LEG_BONES[rig.partBone[i]] == true
	end
	local cid = model:GetAttribute("ClassId")
	return {
		model = model,
		root = root,
		welds = welds,
		rest = rest,
		rig = rig,
		legMask = legMask,
		st = Rig.newState(math.random() * 10),
		D = Rig.newPose(),
		A = {},
		lastPos = nil,
		posed = false,
		classId = if type(cid) == "string" then cid else "elephante",
		detail = 0,
		scale = tonumber(model:GetAttribute("RigScale")) or 1,
		smooth = false,
		samples = {},
		interval = 1 / 30,
		writing = false,
		conn = nil,
		owner = model,
		rootPosed = false,
	}
end

-- Writes the posed C0 of every weld (`legsOnly`: just the leg bones).
function BotAnimator.apply(r: Rigged, legsOnly: boolean?, rootCF: CFrame?)
	local base = rootCF or IDENT
	Rig.solve(r.rig, base, r.D, r.A)
	local pb, pl, A = r.rig.partBone, r.rig.partLocal, r.A
	for i, w in r.welds do
		if not legsOnly or r.legMask[i] then
			local b = pb[i]
			if b ~= 0 then
				w.C0 = A[b] * pl[i]
			elseif rootCF or r.rootPosed then
				w.C0 = base * r.rest[i]
			end
		end
	end
	r.rootPosed = rootCF ~= nil
	r.posed = true
end

local function restore(r: Rigged)
	if r.posed then
		r.posed = false
		r.rootPosed = false
		for i, w in r.welds do
			w.C0 = r.rest[i]
		end
	end
end

local function startSmoothing(r: Rigged)
	if r.smooth or not r.root.Anchored then
		return
	end
	r.smooth = true
	local root = r.root
	table.insert(r.samples, { t = os.clock(), cf = root.CFrame })
	r.conn = root:GetPropertyChangedSignal("CFrame"):Connect(function()
		if r.writing then
			return
		end
		local now = os.clock()
		local last = r.samples[#r.samples]
		if last then
			local gap = now - last.t
			if gap > 0.004 and gap < 1 then
				r.interval += (gap - r.interval) * 0.2
			end
			if (root.CFrame.Position - last.cf.Position).Magnitude > BotAnimator.SNAP_DISTANCE then
				table.clear(r.samples) -- teleport (redeploy, new arena): snap
			end
		end
		table.insert(r.samples, { t = now, cf = root.CFrame })
		if #r.samples > 8 then
			table.remove(r.samples, 1)
		end
	end)
end

local function dropRig(m: Model)
	local r = rigs[m]
	if r and r.conn then
		r.conn:Disconnect()
	end
	rigs[m] = nil
end

local function addRig(m: Model, id: number?, owner: Model, smooth: boolean)
	if id then
		byId[id] = m
	end
	if not rigs[m] then
		local ok, r = pcall(BotAnimator.compile, m)
		if ok and r then
			r.owner = owner
			rigs[m] = r
			if smooth then
				startSmoothing(r)
			end
		end
	end
end

-- iteration 8 (team Mesh): heroes / bots / statues carry both looks (server
-- Visuals/MeshSuit); show the mesh or the Classic parts on this client.
local MeshModels: any = nil
do
	local inst = script.Parent:FindFirstChild("MeshModels")
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		MeshModels = if ok then mod else nil
	end
end
local meshApplied: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
function BotAnimator.applyMeshSets(force: boolean?)
	if not MeshModels then
		return
	end
	local allowed = MeshModels.allowed()
	for _, m in game:GetService("CollectionService"):GetTagged(MeshModels.SET_TAG) do
		if force or meshApplied[m] ~= allowed then
			meshApplied[m] = allowed
			MeshModels.applySets(m, false, allowed)
		end
	end
end

local function scan()
	BotAnimator.applyMeshSets()
	local folder = workspace:FindFirstChild("Bots")
	for m in rigs do
		if not m.Parent then
			dropRig(m)
		end
	end
	table.clear(byId)
	if folder then
		for _, m in folder:GetChildren() do
			if m:IsA("Model") and m:GetAttribute("RigStyle") == "elephant" then
				addRig(m, tonumber(m:GetAttribute("BotId")), m, true)
			end
		end
	end
	-- players wearing the Herd Suit
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		local suit = char and char:FindFirstChild(BotAnimator.SUIT)
		if suit and suit:IsA("Model") and char then
			addRig(suit, plr.UserId, char, false)
		end
	end
end

-- Interpolated Root CFrame `delay` behind the newest sample.
local function sampleCF(r: Rigged, now: number): CFrame?
	local list = r.samples
	local n = #list
	if n == 0 then
		return nil
	end
	local delay = math.clamp(r.interval * 1.6, BotAnimator.INTERP_MIN, BotAnimator.INTERP_MAX)
	local rt = now - delay
	if n == 1 or rt <= list[1].t then
		return list[1].cf
	end
	for i = n, 2, -1 do
		local a, b = list[i - 1], list[i]
		if rt >= a.t then
			if rt >= b.t then
				return b.cf -- hold the newest (no extrapolation)
			end
			local f = (rt - a.t) / math.max(1e-3, b.t - a.t)
			return a.cf:Lerp(b.cf, f)
		end
	end
	return list[n].cf
end

local function rigOf(id: number?): Rigged?
	local m = if id then byId[id] else nil
	return if m then rigs[m] else nil
end

function BotAnimator.attack(id: number?, classId: string?)
	local r = rigOf(id)
	if r and r.st.swing <= 0 then
		r.st.swingKind = SWING[classId or r.classId] or "melee"
		r.st.swing = 0.001
	end
end

-- kind: the ability kind (Rig.CAST: lance aim-hold, tether channel, anchor
-- dig-in, ...; nil or unknown = the generic rear-up); dur: seconds a held
-- cast keeps its pose (the ability's duration, capped at 10 s).
function BotAnimator.cast(id: number?, kind: string?, dur: number?)
	local r = rigOf(id)
	if r then
		local ck = if kind then Rig.CAST[kind] else nil
		r.st.cast = 0.001
		r.st.castKind = if ck then kind else nil
		r.st.castHold = if ck and ck.hold then math.clamp(tonumber(dur) or 0, 0, 10) else 0
	end
end

function BotAnimator.revive(id: number?)
	local r = rigOf(id)
	if r then
		r.st.revive = 0.001
	end
end

-- Hit react: a short flinch (players and bots).
function BotAnimator.hit(id: number?)
	local r = rigOf(id)
	if r and r.st.flinch <= 0 then
		r.st.flinch = 0.001
	end
end

-- True when `id` is drawn by this animator (a bot, or a player in the Herd Suit).
function BotAnimator.has(id: number?): boolean
	return rigOf(id) ~= nil
end

function BotAnimator.step(dt: number, focus: Vector3?)
	local now = os.clock()
	if now >= scanAt then
		scanAt = now + BotAnimator.RESCAN
		scan()
	end
	local full = 0
	for m, r in rigs do
		if not m.Parent then
			continue
		end
		if r.smooth then
			local cf = sampleCF(r, now)
			if cf then
				r.writing = true
				r.root.CFrame = cf
				r.writing = false
			end
		end
		local pos = r.root.Position
		local d2 = if focus then (pos - focus).Magnitude else 0
		local dead = r.owner:GetAttribute("Dead") == true
		if dead or d2 > BotAnimator.SIMPLE then
			restore(r)
			r.lastPos = pos
			continue
		end
		local st = r.st
		local last = r.lastPos or pos
		r.lastPos = pos
		local flat = Vector3.new(pos.X - last.X, 0, pos.Z - last.Z)
		local speed = if dt > 0 then flat.Magnitude / dt else 0
		local moving = if speed > 1.5 then 1 else 0
		st.moving += (moving - st.moving) * math.min(1, dt * 8)
		-- iter3: turn lean from the yaw rate (eased)
		local lv = r.root.CFrame.LookVector
		local yaw = math.atan2(-lv.X, -lv.Z)
		local dyaw = (yaw - (r.lastYaw or yaw) + math.pi) % (2 * math.pi) - math.pi
		r.lastYaw = yaw
		local want = if dt > 0 then math.clamp(dyaw / dt * 0.25, -1, 1) else 0
		st.lean += (want - st.lean) * math.min(1, dt * 6)
		local downed = r.owner:GetAttribute("Downed") == true
		st.downed += ((if downed then 1 else 0) - st.downed) * math.min(1, dt * 5)
		Rig.step(st, dt, math.min(speed, 40), r.scale, 5.5 * r.scale)
		local detail = 2
		if d2 <= BotAnimator.FULL and full < BotAnimator.FULL_CAP then
			detail = 1
			full += 1
		end
		Rig.pose("elephant", st, r.D, r.scale, detail)
		if detail == 2 then
			-- keep the body rigid at range: only the legs walk
			r.D[B.body] = IDENT
			if r.detail == 1 then
				restore(r) -- drop the last full pose of the head, ears, trunk
			end
		end
		r.detail = detail
		local rp = if detail == 1 then Rig.rootPose("elephant", st, r.scale) else IDENT
		BotAnimator.apply(r, detail == 2, if rp ~= IDENT then rp else nil)
	end
end

function BotAnimator.clear()
	for _, r in rigs do
		restore(r)
		if r.conn then
			r.conn:Disconnect()
		end
	end
	table.clear(rigs)
	table.clear(byId)
end

return BotAnimator
