--!strict
-- HeroFx (v3 Graphics, client): hero-side visuals that FxController drives.
--
--   HeroFx.step(dt, focus?)                        every frame (rings, weapon flicks)
--   HeroFx.attack(id, weaponKind?, dx?, dz?)       auto-attack: weapon flick + trail
--                                                  (players) / BotAnimator pose (bots)
--   HeroFx.swoosh(x, z, dx, dz, r, arc, color)     curved swing ribbon (Beams)
--   HeroFx.thrust(x, z, dx, dz, len, color)        straight lunge ribbon
--   HeroFx.clear()
--
-- * Squad ground ring: every hero (player characters with the "Squad"
--   attribute, bots in workspace.Bots) gets a CylinderHandleAdornment ring at
--   its feet in its squad colour (Shared.Util.Squads), adorned to the root so
--   it follows for free; your own hero gets a brighter ring with a soft inner
--   disc. Grey while downed, hidden when out. Rescanned twice a second.
-- * Weapon flick: HeroDecor welds the class weapon to the right hand with the
--   Weld "GripWeld"; an attack rotates its C0 about the grip (wind back, swing
--   through, recover over 0.28 s) and turns its "SwingTrail" on meanwhile.
--   Ranged classes recoil instead. Bot elephants pose through BotAnimator.
-- * Swing ribbons: pooled Beams on one invisible host part, drawn as a short
--   polyline arc that widens and fades (no textures needed).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HeroFx = {}

HeroFx.RING_RADIUS = 2.6
HeroFx.BOT_RING_RADIUS = 3.4
HeroFx.RESCAN = 0.5
HeroFx.FLICK_TIME = 0.28

local BotAnimator: any = nil
do
	local inst = script.Parent:FindFirstChild("BotAnimator")
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		BotAnimator = if ok then mod else nil
	end
end

local Squads: any = nil
do
	local ok, mod = pcall(function()
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		local util = shared and shared:FindFirstChild("Util")
		local inst = util and util:FindFirstChild("Squads")
		return if inst and inst:IsA("ModuleScript") then require(inst) :: any else nil
	end)
	Squads = if ok then mod else nil
end

local GREY = Color3.fromRGB(120, 120, 130)
local FALLBACK = {
	Color3.fromRGB(255, 200, 60),
	Color3.fromRGB(245, 240, 220),
	Color3.fromRGB(80, 150, 255),
	Color3.fromRGB(235, 70, 60),
}
local RANGED: { [string]: boolean } = { bolt = true, spread = true, lob = true, shoot = true }

local folder: Folder? = nil
local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "TrunkfallHeroFx"
	f.Parent = workspace
	folder = f
	return f
end

local function squadColor(squad: any): Color3
	local i = tonumber(squad)
	if i and Squads and type(Squads.get) == "function" then
		local s = Squads.get(i)
		if s and type(s.color) == "table" then
			return Color3.fromRGB(s.color[1] or 255, s.color[2] or 200, s.color[3] or 60)
		end
	end
	return FALLBACK[i or 1] or FALLBACK[1]
end

----------------------------------------------------------------------
-- Squad rings
----------------------------------------------------------------------

type Ring = {
	adornee: BasePart,
	owner: Instance,
	ring: CylinderHandleAdornment,
	disc: CylinderHandleAdornment?,
	color: Color3?,
	seen: number,
	mine: boolean,
}
local rings: { [Instance]: Ring } = {}
local ringPool: { CylinderHandleAdornment } = {}
local ringsOk = true
local scanAt = 0
local scanSeq = 0

local function newAdornment(): CylinderHandleAdornment?
	if not ringsOk then
		return nil
	end
	local a = table.remove(ringPool)
	if a then
		return a
	end
	local ok, made = pcall(function()
		local n = Instance.new("CylinderHandleAdornment")
		n.Name = "SquadRing"
		n.Height = 0.08
		n.AlwaysOnTop = false
		n.ZIndex = 0
		n.Parent = getFolder()
		return n
	end)
	if not ok then
		ringsOk = false
		return nil
	end
	return made
end

local function freeAdornment(a: CylinderHandleAdornment?)
	if a then
		a.Visible = false
		a.Adornee = nil
		table.insert(ringPool, a)
	end
end

local function dropRing(key: Instance)
	local r = rings[key]
	if r then
		freeAdornment(r.ring)
		freeAdornment(r.disc)
		rings[key] = nil
	end
end

local function feetOffset(owner: Instance, root: BasePart, isBot: boolean): number
	if isBot then
		return 0.06
	end
	local hum = owner:FindFirstChildOfClass("Humanoid")
	local hip = if hum then hum.HipHeight else 0
	if hip <= 0.01 then
		hip = 2 -- R6: the legs are 2 studs
	end
	return -(hip + root.Size.Y / 2) + 0.06
end

local function ensureRing(owner: Instance, root: BasePart, isBot: boolean, mine: boolean)
	local r = rings[owner]
	if r and r.adornee ~= root then
		dropRing(owner)
		r = nil
	end
	if not r then
		local a = newAdornment()
		if not a then
			return
		end
		local radius = if isBot then HeroFx.BOT_RING_RADIUS else HeroFx.RING_RADIUS
		local y = feetOffset(owner, root, isBot)
		a.Adornee = root
		a.Radius = radius
		a.InnerRadius = radius - (if mine then 0.45 else 0.3)
		a.CFrame = CFrame.new(0, y, 0) * CFrame.Angles(math.pi / 2, 0, 0)
		a.Transparency = if mine then 0.1 else 0.3
		a.Visible = true
		local disc: CylinderHandleAdornment? = nil
		if mine then
			disc = newAdornment()
			if disc then
				disc.Adornee = root
				disc.Radius = radius - 0.45
				disc.InnerRadius = 0
				disc.CFrame = CFrame.new(0, y - 0.01, 0) * CFrame.Angles(math.pi / 2, 0, 0)
				disc.Transparency = 0.82
				disc.Visible = true
			end
		end
		r = { adornee = root, owner = owner, ring = a, disc = disc, color = nil, seen = scanSeq, mine = mine }
		rings[owner] = r
	end
	local rr = r :: Ring
	rr.seen = scanSeq
	local down = owner:GetAttribute("Downed") == true
	local dead = owner:GetAttribute("Dead") == true
	local color = if down then GREY else squadColor(owner:GetAttribute("Squad"))
	if rr.color ~= color then
		rr.color = color
		rr.ring.Color3 = color
		if rr.disc then
			rr.disc.Color3 = color
		end
	end
	rr.ring.Visible = not dead
	if rr.disc then
		rr.disc.Visible = not dead
	end
end

local function scan()
	scanSeq += 1
	local me = Players.LocalPlayer
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if char and root and root:IsA("BasePart") and (char:GetAttribute("Squad") ~= nil or plr == me) then
			ensureRing(char, root, false, plr == me)
		end
	end
	local bots = workspace:FindFirstChild("Bots")
	if bots then
		for _, m in bots:GetChildren() do
			local root = if m:IsA("Model") then m.PrimaryPart else nil
			if root then
				ensureRing(m, root, true, false)
			end
		end
	end
	for key, r in rings do
		if r.seen ~= scanSeq or not key.Parent then
			dropRing(key)
		end
	end
end

----------------------------------------------------------------------
-- Weapon flicks
----------------------------------------------------------------------

type Flick = { weld: Weld, base: CFrame, pivot: Vector3, t: number, ranged: boolean, trail: Trail? }
local flicks: { [Weld]: Flick } = {}
local baseC0: { [Weld]: CFrame } = setmetatable({}, { __mode = "k" }) :: any

local function characterOf(id: number): Model?
	local plr = Players:GetPlayerByUserId(id)
	return if plr then plr.Character else nil
end

function HeroFx.attack(id: number?, kind: string?, _dx: number?, _dz: number?)
	if not id then
		return
	end
	if id <= -1000 then
		if BotAnimator then
			BotAnimator.attack(id, nil)
		end
		return
	end
	local char = characterOf(id)
	local decor = char and char:FindFirstChild("TrunkfallHeroDecor")
	local grip = decor and decor:FindFirstChild("WeaponGrip")
	local weld = grip and grip:FindFirstChild("GripWeld")
	if not weld or not weld:IsA("Weld") then
		return
	end
	if flicks[weld] then
		flicks[weld].t = 0
		return
	end
	local base = baseC0[weld] or weld.C0
	baseC0[weld] = base
	local trail = (grip :: Instance):FindFirstChild("SwingTrail")
	local tr: Trail? = if trail and trail:IsA("Trail") then trail else nil
	if tr then
		tr.Enabled = true
	end
	flicks[weld] = {
		weld = weld,
		base = base,
		pivot = base.Position,
		t = 0,
		ranged = RANGED[kind or ""] == true,
		trail = tr,
	}
end

local function flickAngle(f: Flick, x: number): number
	if f.ranged then
		-- recoil: kick up, settle
		return if x < 0.3 then x / 0.3 * 0.45 else 0.45 * (1 - (x - 0.3) / 0.7)
	end
	-- wind back, swing through, recover
	if x < 0.2 then
		return x / 0.2 * 0.7
	elseif x < 0.5 then
		return 0.7 - (x - 0.2) / 0.3 * 2.4
	end
	return -1.7 * (1 - (x - 0.5) / 0.5)
end

local function stepFlicks(dt: number)
	for weld, f in flicks do
		f.t += dt
		local x = f.t / HeroFx.FLICK_TIME
		if x >= 1 or not weld.Parent then
			weld.C0 = f.base
			if f.trail then
				f.trail.Enabled = false
			end
			flicks[weld] = nil
		else
			local a = flickAngle(f, x)
			weld.C0 = CFrame.new(f.pivot) * CFrame.Angles(a, 0, 0) * CFrame.new(-f.pivot) * f.base
		end
	end
end

----------------------------------------------------------------------
-- Swing ribbons (Beams)
----------------------------------------------------------------------

local SEGMENTS = 5
type Ribbon = { atts: { Attachment }, beams: { Beam }, t: number, life: number, color: Color3, alpha: number }
local host: BasePart? = nil
local ribbonPool: { Ribbon } = {}
local ribbons: { Ribbon } = {}
local RIBBON_CAP = 24

local function getHost(): BasePart
	local h = host
	if h and h.Parent then
		return h
	end
	local p = Instance.new("Part")
	p.Name = "RibbonHost"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.one * 0.2
	p.CFrame = CFrame.identity
	p.Parent = getFolder()
	host = p
	table.clear(ribbonPool)
	return p
end

local function getRibbon(): Ribbon
	local r = table.remove(ribbonPool)
	if r then
		return r
	end
	local h = getHost()
	local atts, beams = {}, {}
	for i = 1, SEGMENTS + 1 do
		local a = Instance.new("Attachment")
		a.Parent = h
		atts[i] = a
	end
	for i = 1, SEGMENTS do
		local b = Instance.new("Beam")
		b.Attachment0 = atts[i]
		b.Attachment1 = atts[i + 1]
		b.FaceCamera = true
		b.LightEmission = 1
		b.LightInfluence = 0
		b.Segments = 1
		b.Enabled = false
		b.Parent = h
		beams[i] = b
	end
	return { atts = atts, beams = beams, t = 0, life = 0.2, color = Color3.new(1, 1, 1), alpha = 0.2 }
end

local function showRibbon(r: Ribbon, pts: { Vector3 }, w0: number, w1: number, color: Color3, life: number)
	if #ribbons >= RIBBON_CAP then
		local old = table.remove(ribbons, 1)
		if old then
			for _, b in old.beams do
				b.Enabled = false
			end
			table.insert(ribbonPool, old)
		end
	end
	for i, a in r.atts do
		a.Position = pts[math.min(i, #pts)]
	end
	for i, b in r.beams do
		local f0, f1 = (i - 1) / SEGMENTS, i / SEGMENTS
		b.Width0 = w0 + (w1 - w0) * f0
		b.Width1 = w0 + (w1 - w0) * f1
		b.Color = ColorSequence.new(color)
		b.Transparency = NumberSequence.new(0.2)
		b.Enabled = i < #pts
	end
	r.t, r.life, r.color = 0, life, color
	table.insert(ribbons, r)
end

function HeroFx.swoosh(
	x: number,
	z: number,
	dx: number,
	dz: number,
	radius: number,
	arc: number,
	color: Color3
)
	local yaw = math.atan2(dx, dz)
	local rr = math.max(1.5, radius * 0.85)
	local half = math.clamp(arc, 0.3, math.pi * 1.6) / 2
	local pts = {}
	for i = 0, SEGMENTS do
		local a = yaw - half + (2 * half) * i / SEGMENTS
		pts[i + 1] = Vector3.new(x + math.sin(a) * rr, 2.3 + i * 0.08, z + math.cos(a) * rr)
	end
	showRibbon(getRibbon(), pts, 0.25, math.clamp(radius * 0.35, 0.8, 2.4), color, 0.22)
end

function HeroFx.thrust(x: number, z: number, dx: number, dz: number, len: number, color: Color3)
	local pts = {}
	for i = 0, SEGMENTS do
		local f = i / SEGMENTS
		pts[i + 1] = Vector3.new(x + dx * len * f, 2.4, z + dz * len * f)
	end
	showRibbon(getRibbon(), pts, math.clamp(len * 0.2, 0.8, 3), 0.15, color, 0.2)
end

local function stepRibbons(dt: number)
	local i = 1
	while i <= #ribbons do
		local r = ribbons[i]
		r.t += dt
		local f = r.t / r.life
		if f >= 1 then
			for _, b in r.beams do
				b.Enabled = false
			end
			table.remove(ribbons, i)
			table.insert(ribbonPool, r)
		else
			local tr = NumberSequence.new(0.15 + 0.85 * f, 0.5 + 0.5 * f)
			for _, b in r.beams do
				b.Transparency = tr
			end
			i += 1
		end
	end
end

----------------------------------------------------------------------

function HeroFx.step(dt: number, focus: Vector3?)
	local now = os.clock()
	if now >= scanAt then
		scanAt = now + HeroFx.RESCAN
		pcall(scan)
	end
	stepFlicks(dt)
	stepRibbons(dt)
	if BotAnimator then
		BotAnimator.step(dt, focus)
	end
end

function HeroFx.clear()
	for key in rings do
		dropRing(key)
	end
	for weld, f in flicks do
		weld.C0 = f.base
		if f.trail then
			f.trail.Enabled = false
		end
	end
	table.clear(flicks)
	for _, r in ribbons do
		for _, b in r.beams do
			b.Enabled = false
		end
		table.insert(ribbonPool, r)
	end
	table.clear(ribbons)
end

return HeroFx
