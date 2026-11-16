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

local Rig = require(script.Parent.Rig)

local BotAnimator = {}

BotAnimator.FULL = 60
BotAnimator.SIMPLE = 120
BotAnimator.FULL_CAP = 6
BotAnimator.RESCAN = 1

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
	}
end

-- Writes the posed C0 of every weld (`legsOnly`: just the leg bones).
function BotAnimator.apply(r: Rigged, legsOnly: boolean?)
	Rig.solve(r.rig, IDENT, r.D, r.A)
	local pb, pl, A = r.rig.partBone, r.rig.partLocal, r.A
	for i, w in r.welds do
		if not legsOnly or r.legMask[i] then
			local b = pb[i]
			if b ~= 0 then
				w.C0 = A[b] * pl[i]
			end
		end
	end
	r.posed = true
end

local function restore(r: Rigged)
	if r.posed then
		r.posed = false
		for i, w in r.welds do
			w.C0 = r.rest[i]
		end
	end
end

local function scan()
	local folder = workspace:FindFirstChild("Bots")
	for m in rigs do
		if not m.Parent then
			rigs[m] = nil
		end
	end
	table.clear(byId)
	if not folder then
		return
	end
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("RigStyle") == "elephant" then
			local id = tonumber(m:GetAttribute("BotId"))
			if id then
				byId[id] = m
			end
			if not rigs[m] then
				local ok, r = pcall(BotAnimator.compile, m)
				if ok and r then
					rigs[m] = r
				end
			end
		end
	end
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

function BotAnimator.cast(id: number?)
	local r = rigOf(id)
	if r then
		r.st.cast = 0.001
	end
end

function BotAnimator.revive(id: number?)
	local r = rigOf(id)
	if r then
		r.st.revive = 0.001
	end
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
		local pos = r.root.Position
		local d2 = if focus then (pos - focus).Magnitude else 0
		local dead = m:GetAttribute("Dead") == true
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
		local downed = m:GetAttribute("Downed") == true
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
		BotAnimator.apply(r, detail == 2)
	end
end

function BotAnimator.clear()
	for _, r in rigs do
		restore(r)
	end
	table.clear(rigs)
	table.clear(byId)
end

return BotAnimator
