--!strict
-- TalentFx (iteration 6, team Talents, client): draws the talent keystone and Ascension
-- mechanics (Combat/Talents Fx {t = "tk", k = kind, id = hero, ...}). FxController
-- forwards every "tk" event to TalentFx.handle and calls TalentFx.step(dt) each frame.
--
-- Persistent ("state", re-sent every 8 s): orbs / spirit calves circling the hero, the
-- aura ring, the ascended weapon trail (node 3), the frenzy glow, the Ancient rune ring.
-- One-shots: emp (empowered attack), charged, orb (zap), shard, nova, stomp, wave,
-- retaliate, secondWind, lastStand, guard, combo, frenzy, echo, execute, charge.
-- Everything is pooled-light Parts under one folder; Effects "off" keeps only the
-- persistent pieces (they tell the player what their build does).

local Players = game:GetService("Players")

local TalentFx = {}

local Particles: any = nil
do
	local inst = script.Parent:FindFirstChild("Particles")
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		Particles = if ok then mod else nil
	end
end

local rgb = Color3.fromRGB
local COL = {
	emp = rgb(255, 214, 92),
	orb = rgb(150, 230, 255),
	spirit = rgb(210, 245, 255),
	shard = rgb(255, 190, 120),
	nova = rgb(120, 210, 255),
	stomp = rgb(110, 220, 255),
	wave = rgb(255, 170, 60),
	retaliate = rgb(235, 110, 70),
	secondWind = rgb(140, 255, 170),
	lastStand = rgb(255, 240, 160),
	guard = rgb(170, 200, 255),
	combo = rgb(200, 130, 255),
	frenzy = rgb(255, 80, 60),
	echo = rgb(200, 220, 255),
	execute = rgb(255, 60, 60),
	aura = rgb(120, 220, 110),
	trail = rgb(255, 200, 90),
}
TalentFx.COLORS = COL
-- every one-shot kind this module draws (tests read this list)
TalentFx.KINDS = {
	"state",
	"emp",
	"charged",
	"orb",
	"shard",
	"nova",
	"stomp",
	"wave",
	"retaliate",
	"secondWind",
	"lastStand",
	"guard",
	"combo",
	"frenzy",
	"echo",
	"execute",
	"charge",
}

local folder: Folder? = nil
local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "TrunkfallTalentFx"
	f.Parent = workspace
	folder = f
	return f
end

local function root(id: number): BasePart?
	local plr = Players:GetPlayerByUserId(id)
	local m: Instance? = plr and plr.Character
	if not m then
		local bots = workspace:FindFirstChild("Bots")
		if bots then
			for _, b in bots:GetChildren() do
				local attr = b:GetAttribute("BotId")
				if (attr ~= nil and tonumber(attr) == id) or b.Name == "Bot_" .. tostring(-id) then
					m = b
					break
				end
			end
		end
	end
	if not m then
		return nil
	end
	local r = m:FindFirstChild("HumanoidRootPart")
	if r and r:IsA("BasePart") then
		return r
	end
	if m:IsA("Model") and m.PrimaryPart then
		return m.PrimaryPart
	end
	return nil
end

local function part(shape: Enum.PartType, color: Color3, alpha: number): Part
	local p = Instance.new("Part")
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = alpha
	p.Size = Vector3.one * 0.2
	p.Parent = getFolder()
	return p
end

type Effect = { update: (dt: number) -> boolean, kill: () -> () }
local effects: { Effect } = {}
local MAX_EFFECTS = 60
local function add(e: Effect)
	if #effects >= MAX_EFFECTS then
		local old = table.remove(effects, 1)
		if old then
			old.kill()
		end
	end
	table.insert(effects, e)
end

local function num(v: any, d: number): number
	return if type(v) == "number" and v == v then v else d
end

-- Expanding flat ring / disc on the ground.
local function ring(x: number, z: number, r: number, color: Color3, life: number, alpha: number, y: number?)
	local p = part(Enum.PartType.Cylinder, color, alpha)
	local t = 0
	add({
		update = function(dt)
			t += dt
			local f = math.min(t / life, 1)
			local d = math.max(0.2, 2 * r * (1 - (1 - f) ^ 3))
			p.Size = Vector3.new(0.25, d, d)
			p.CFrame = CFrame.new(x, (y or 0.25), z) * CFrame.Angles(0, 0, math.pi / 2)
			p.Transparency = alpha + (1 - alpha) * f
			return f < 1
		end,
		kill = function()
			p:Destroy()
		end,
	})
end

-- A fading ball (bubble, ghost) at a hero / point.
local function ball(pos: Vector3, r: number, color: Color3, life: number, alpha: number, follow: number?)
	local p = part(Enum.PartType.Ball, color, alpha)
	p.Material = Enum.Material.ForceField
	local t = 0
	add({
		update = function(dt)
			t += dt
			local f = math.min(t / life, 1)
			local at = pos
			if follow then
				local rt = root(follow)
				if rt then
					at = rt.Position
				end
			end
			p.Size = Vector3.one * (2 * r * (0.85 + 0.15 * f))
			p.CFrame = CFrame.new(at)
			p.Transparency = alpha + (1 - alpha) * f * f
			return f < 1
		end,
		kill = function()
			p:Destroy()
		end,
	})
end

-- A thin glowing line (zaps, shards) that fades.
local function zap(a: Vector3, b: Vector3, color: Color3, life: number, width: number)
	local p = part(Enum.PartType.Block, color, 0.1)
	local len = (b - a).Magnitude
	p.Size = Vector3.new(width, width, math.max(0.2, len))
	p.CFrame = CFrame.lookAt((a + b) / 2, b)
	local t = 0
	add({
		update = function(dt)
			t += dt
			local f = math.min(t / life, 1)
			p.Transparency = 0.1 + 0.9 * f
			return f < 1
		end,
		kill = function()
			p:Destroy()
		end,
	})
end

local function burst(kind: string, pos: Vector3, n: number, color: Color3)
	if Particles and type(Particles.burst) == "function" then
		pcall(Particles.burst, kind, pos, n, color)
	end
end

-- Persistent per-hero state -------------------------------------------------------------

type HeroState = {
	orbs: { Part },
	spirit: boolean,
	aura: Part?,
	auraR: number,
	trail: Trail?,
	trailAtt: { Attachment },
	frenzy: boolean,
	ancient: Part?,
	t: number,
}
local heroes: { [number]: HeroState } = {}

local function clearHero(id: number)
	local h = heroes[id]
	if not h then
		return
	end
	for _, o in h.orbs do
		o:Destroy()
	end
	if h.aura then
		h.aura:Destroy()
	end
	if h.ancient then
		h.ancient:Destroy()
	end
	if h.trail then
		h.trail:Destroy()
	end
	for _, a in h.trailAtt do
		a:Destroy()
	end
	heroes[id] = nil
end

local function setState(ev: any)
	local id = tonumber(ev.id)
	if not id then
		return
	end
	local orbs = math.clamp(math.floor(num(ev.orbs, 0)), 0, 4)
	local aura = num(ev.aura, 0)
	local trail = ev.trail == true
	local ancient = ev.ancient == true
	if orbs == 0 and aura <= 0 and not trail and not ancient and num(ev.frenzy, 0) == 0 then
		clearHero(id)
		return
	end
	local h = heroes[id]
	if not h then
		h = {
			orbs = {},
			spirit = false,
			aura = nil,
			auraR = 0,
			trail = nil,
			trailAtt = {},
			frenzy = false,
			ancient = nil,
			t = 0,
		}
		heroes[id] = h
	end
	local hs = h :: HeroState
	hs.spirit = ev.spirit == true
	while #hs.orbs > orbs do
		local o = table.remove(hs.orbs)
		if o then
			o:Destroy()
		end
	end
	while #hs.orbs < orbs do
		local spirit = hs.spirit and #hs.orbs == 0
		local o =
			part(Enum.PartType.Ball, if spirit then COL.spirit else COL.orb, if spirit then 0.25 else 0.1)
		o.Size = Vector3.one * (if spirit then 1.4 else 0.9)
		local light = Instance.new("PointLight")
		light.Color = o.Color
		light.Range = 6
		light.Brightness = 1.2
		light.Parent = o
		table.insert(hs.orbs, o)
	end
	if aura > 0 then
		if not hs.aura then
			local a = part(Enum.PartType.Cylinder, COL.aura, 0.7)
			a.Material = Enum.Material.ForceField
			hs.aura = a
		end
		hs.auraR = aura
	elseif hs.aura then
		hs.aura:Destroy()
		hs.aura = nil
	end
	if ancient and not hs.ancient then
		local a = part(Enum.PartType.Cylinder, COL.stomp, 0.55)
		hs.ancient = a
	elseif not ancient and hs.ancient then
		hs.ancient:Destroy()
		hs.ancient = nil
	end
	hs.frenzy = num(ev.frenzy, 0) > 0
	-- node 3: the ascended weapon trail (attached to the hero's root)
	local rt = root(id)
	if trail and not hs.trail and rt then
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, 1.5, 0)
		a0.Parent = rt
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -0.5, 0)
		a1.Parent = rt
		local tr = Instance.new("Trail")
		tr.Attachment0, tr.Attachment1 = a0, a1
		tr.Color = ColorSequence.new(COL.trail, COL.emp)
		tr.Transparency = NumberSequence.new(0.3, 1)
		tr.Lifetime = 0.45
		tr.LightEmission = 1
		tr.FaceCamera = true
		tr.Parent = rt
		hs.trail = tr
		hs.trailAtt = { a0, a1 }
	elseif not trail and hs.trail then
		hs.trail:Destroy()
		hs.trail = nil
		for _, a in hs.trailAtt do
			a:Destroy()
		end
		hs.trailAtt = {}
	end
end

-- One-shots -------------------------------------------------------------------------------

local function at(ev: any): Vector3
	return Vector3.new(num(ev.x, 0), 1.5, num(ev.z, 0))
end

local ONE: { [string]: (ev: any) -> () } = {}
ONE.emp = function(ev)
	local p = at(ev)
	ring(p.X, p.Z, 5, COL.emp, 0.3, 0.3)
	burst("critStar", p + Vector3.new(0, 1, 0), 6, COL.emp)
end
ONE.charged = function(ev)
	local p = at(ev)
	burst("glint", p + Vector3.new(0, 1, 0), 10, COL.emp)
	ball(p, 3, COL.emp, 0.5, 0.5, tonumber(ev.id))
end
ONE.charge = function(ev)
	burst("glint", at(ev), 8, COL.combo)
end
ONE.orb = function(ev)
	local id = tonumber(ev.id)
	local h = if id then heroes[id] else nil
	local from = if h and #h.orbs > 0 then h.orbs[1].Position else nil
	if not from and id then
		local rt = root(id)
		from = if rt then rt.Position + Vector3.new(0, 3, 0) else nil
	end
	local to = at(ev)
	if from then
		zap(from, to, if ev.spirit then COL.spirit else COL.orb, 0.18, 0.35)
	end
	burst("spark", to, 4, COL.orb)
end
ONE.shard = function(ev)
	local from = at(ev)
	local to = if type(ev.to) == "table" then ev.to else {}
	for i = 1, #to - 1, 2 do
		zap(from, Vector3.new(num(to[i], 0), 1.5, num(to[i + 1], 0)), COL.shard, 0.22, 0.3)
	end
	burst("spark", from, 6, COL.shard)
end
local function nova(ev: any, color: Color3, life: number, extra: string?)
	local p = at(ev)
	local r = num(ev.r, 8)
	ring(p.X, p.Z, r, color, life, 0.25)
	ring(p.X, p.Z, r * 0.6, color:Lerp(Color3.new(1, 1, 1), 0.4), life * 0.8, 0.4)
	if extra then
		burst(extra, p, 12, color)
	end
end
ONE.nova = function(ev)
	nova(ev, COL.nova, 0.45, "gust")
end
ONE.wave = function(ev)
	nova(ev, COL.wave, 0.4, "boomShock")
end
ONE.retaliate = function(ev)
	nova(ev, COL.retaliate, 0.3, "crumbs")
end
ONE.stomp = function(ev)
	local p = at(ev)
	nova(ev, COL.stomp, 0.7, "boomShock")
	burst("pillar", p, 3, COL.stomp)
	burst("crumbs", p, 14, rgb(150, 110, 70))
end
ONE.secondWind = function(ev)
	nova(ev, COL.secondWind, 0.6, "heal")
	ball(at(ev), 4, COL.secondWind, 1.5, 0.4, tonumber(ev.id))
end
ONE.lastStand = function(ev)
	nova(ev, COL.lastStand, 0.5, "heal")
	ball(at(ev), 3.5, COL.lastStand, 1, 0.45, tonumber(ev.id))
end
ONE.guard = function(ev)
	ball(at(ev), 3.2, COL.guard, num(ev.dur, 3), 0.55, tonumber(ev.id))
end
ONE.combo = function(ev)
	local p = at(ev)
	ring(p.X, p.Z, 6, COL.combo, 0.4, 0.3)
	burst("critRay", p + Vector3.new(0, 1, 0), 6, COL.combo)
end
ONE.frenzy = function(ev)
	local p = at(ev)
	ring(p.X, p.Z, 7, COL.frenzy, 0.5, 0.2)
	burst("fire", p, 16, COL.frenzy)
end
ONE.echo = function(ev)
	-- the ghostly double: a pale silhouette that rises and fades where the hero stands
	local p = at(ev)
	local body = part(Enum.PartType.Ball, COL.echo, 0.55)
	body.Material = Enum.Material.ForceField
	local head = part(Enum.PartType.Ball, COL.echo, 0.55)
	head.Material = Enum.Material.ForceField
	local t = 0
	add({
		update = function(dt)
			t += dt
			local f = math.min(t / 0.8, 1)
			local y = 2.5 + f * 2
			body.Size = Vector3.new(5, 4, 6)
			body.CFrame = CFrame.new(p.X, y, p.Z)
			head.Size = Vector3.new(3, 3, 3)
			head.CFrame = CFrame.new(p.X, y + 1.5, p.Z - 3)
			body.Transparency = 0.55 + 0.45 * f
			head.Transparency = 0.55 + 0.45 * f
			return f < 1
		end,
		kill = function()
			body:Destroy()
			head:Destroy()
		end,
	})
	burst("implode", p, 10, COL.echo)
end
ONE.execute = function(ev)
	local p = at(ev)
	burst("critRay", p + Vector3.new(0, 1, 0), 8, COL.execute)
	ring(p.X, p.Z, 2.5, COL.execute, 0.25, 0.2)
end

function TalentFx.handle(ev: any)
	if type(ev) ~= "table" then
		return
	end
	local k = tostring(ev.k)
	if k == "state" then
		setState(ev)
		return
	end
	local fn = ONE[k]
	if fn then
		fn(ev)
	end
end

function TalentFx.step(dt: number)
	local k = 1
	while k <= #effects do
		local e = effects[k]
		local ok, alive = pcall(e.update, dt)
		if ok and alive then
			k += 1
		else
			pcall(e.kill)
			table.remove(effects, k)
		end
	end
	for id, h in heroes do
		h.t += dt
		local rt = root(id)
		if not rt then
			continue
		end
		local pos = rt.Position
		local n = #h.orbs
		for i, o in h.orbs do
			local a = h.t * 2.2 + (i - 1) * math.pi * 2 / math.max(1, n)
			local bob = math.sin(h.t * 3 + i) * 0.4
			o.CFrame = CFrame.new(pos.X + math.cos(a) * 4, pos.Y + 2.5 + bob, pos.Z + math.sin(a) * 4)
		end
		if h.aura then
			local d = 2 * h.auraR
			h.aura.Size = Vector3.new(0.15, d, d)
			h.aura.CFrame = CFrame.new(pos.X, 0.2, pos.Z) * CFrame.Angles(0, 0, math.pi / 2)
			h.aura.Transparency = 0.65 + 0.1 * math.sin(h.t * 4)
			h.aura.Color = if h.frenzy then COL.frenzy else COL.aura
		end
		if h.ancient then
			local d = 7 + math.sin(h.t * 2) * 0.4
			h.ancient.Size = Vector3.new(0.12, d, d)
			h.ancient.CFrame = CFrame.new(pos.X, 0.18, pos.Z) * CFrame.Angles(0, h.t, math.pi / 2)
			h.ancient.Color = if h.frenzy then COL.frenzy else COL.stomp
		end
		if h.frenzy and math.floor(h.t * 6) ~= math.floor((h.t - dt) * 6) then
			burst("fire", pos, 2, COL.frenzy)
		end
	end
end

function TalentFx.clear()
	for _, e in effects do
		pcall(e.kill)
	end
	table.clear(effects)
	for id in heroes do
		clearHero(id)
	end
end

return TalentFx
