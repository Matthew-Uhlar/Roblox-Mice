--!strict
-- StormWall (v4, team G): "The Melt" storm visuals on the client.
--
--   StormWall.set(payload)     Fx {t = "storm", cx, cz, r, toR, closeStart,
--                              closeEnd, dps, now} or the S2C Storm payload
--   StormWall.step(dt, hero: Vector3?, focus: Vector3?)   every frame (FxController)
--   StormWall.radiusAt(p, t) -> number                    pure: radius at world time t
--   StormWall.clear()
--   StormWall.state() -> {cx, cz, r, outside} | nil
--
-- Draws a translucent melting-cheese wall: a ring of tall Glass panels whose
-- radius lerps from r to toR between closeStart and closeEnd (times on the
-- payload's own clock: `now` maps it to the client's server time when it
-- arrives), a drip lip of Neon blobs at the top, ground edge particles on the
-- arc nearest the camera, and a warm tint + vignette when the hero is outside
-- the circle. Payload times are optional: with no close window the wall sits
-- at `r`. Panels are anchored, non-colliding and non-queryable; only the arc
-- within VISIBLE_ARC studs of the camera is drawn at full detail.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")

local StormWall = {}

StormWall.SEGMENTS = 48
StormWall.SEGMENTS_LOW = 28
StormWall.HEIGHT = 34
StormWall.EMITTERS = 5
StormWall.CHEESE = Color3.fromRGB(255, 196, 64)
StormWall.CHEESE_DARK = Color3.fromRGB(230, 140, 30)
StormWall.TINT = Color3.fromRGB(255, 214, 150)

local PARK = CFrame.new(0, -5000, 0)

type Payload = {
	cx: number,
	cz: number,
	r: number,
	toR: number,
	closeStart: number?,
	closeEnd: number?,
	dps: number,
	clockOffset: number, -- payload clock = client server time + clockOffset
}

local current: Payload? = nil
local low = false
local folder: Folder? = nil
local panels: { BasePart } = {}
local drips: { BasePart } = {}
local emitters: { BasePart } = {}
local cc: ColorCorrectionEffect? = nil
local vignette: ScreenGui? = nil
local vignetteFrame: Frame? = nil
local outside = false
local outsideT = 0
local lastR = -1
local lastState: { [string]: any }? = nil

local function num(v: any, d: number?): number?
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return d
	end
	return n
end

local function serverNow(): number
	local ok, t = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	return if ok then t else os.clock()
end

-- Pure: the circle radius at payload time t.
function StormWall.radiusAt(p: any, t: number): number
	local r = num(p.r, 0) :: number
	local toR = num(p.toR, r) :: number
	local a, b = num(p.closeStart), num(p.closeEnd)
	if not a or not b or b <= a then
		return if a and t >= a then toR else r
	end
	if t <= a then
		return r
	elseif t >= b then
		return toR
	end
	local f = (t - a) / (b - a)
	return r + (toR - r) * f
end

function StormWall.setLowSpec(on: boolean)
	low = on
end

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "TrunkfallStorm"
	f.Parent = workspace
	folder = f
	return f
end

local function part(
	shape: Enum.PartType,
	color: Color3,
	material: Enum.Material,
	transparency: number
): BasePart
	local p = Instance.new("Part")
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Color = color
	p.Material = material
	p.Transparency = transparency
	p.CFrame = PARK
	p.Parent = getFolder()
	return p
end

local function ensureParts()
	if #panels > 0 then
		return
	end
	local n = if low then StormWall.SEGMENTS_LOW else StormWall.SEGMENTS
	for i = 1, n do
		local p = part(Enum.PartType.Block, StormWall.CHEESE, Enum.Material.Glass, 0.55)
		p.Name = "MeltPanel"
		p.Reflectance = 0.05
		panels[i] = p
		-- a melting lip: neon cheese blobs hanging off the top edge
		local d = part(Enum.PartType.Ball, StormWall.CHEESE_DARK, Enum.Material.Neon, 0.25)
		d.Name = "MeltDrip"
		drips[i] = d
	end
	if not low then
		for i = 1, StormWall.EMITTERS do
			local a = part(Enum.PartType.Block, StormWall.CHEESE, Enum.Material.SmoothPlastic, 1)
			a.Name = "MeltEdge"
			a.Size = Vector3.new(14, 0.2, 2)
			local e = Instance.new("ParticleEmitter")
			e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
			e.Color = ColorSequence.new(StormWall.CHEESE, StormWall.CHEESE_DARK)
			e.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.9),
				NumberSequenceKeypoint.new(1, 0.1),
			})
			e.Transparency = NumberSequence.new(0.2, 1)
			e.Lifetime = NumberRange.new(0.8, 1.6)
			e.Rate = 10
			e.Speed = NumberRange.new(2, 5)
			e.SpreadAngle = Vector2.new(20, 20)
			e.EmissionDirection = Enum.NormalId.Top
			e.LightEmission = 0.6
			e.Parent = a
			emitters[i] = a
		end
	end
end

local function ensureScreen()
	if not cc or not cc.Parent then
		local c = Instance.new("ColorCorrectionEffect")
		c.Name = "TrunkfallStormTint"
		c.Enabled = false
		c.Parent = Lighting
		cc = c
	end
	if vignette and vignette.Parent then
		return
	end
	local lp = Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	local g = Instance.new("ScreenGui")
	g.Name = "TrunkfallStormVignette"
	g.IgnoreGuiInset = true
	g.ResetOnSpawn = false
	g.DisplayOrder = -5
	g.Enabled = false
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = StormWall.CHEESE_DARK
	f.BorderSizePixel = 0
	f.BackgroundTransparency = 0
	local grad = Instance.new("UIGradient")
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(0.18, 0.92),
		NumberSequenceKeypoint.new(0.82, 0.92),
		NumberSequenceKeypoint.new(1, 0.45),
	})
	grad.Parent = f
	f.Parent = g
	g.Parent = pg
	vignette = g
	vignetteFrame = f
end

function StormWall.set(p: any)
	if type(p) ~= "table" then
		return
	end
	local r = num(p.r)
	if not r or r <= 0 then
		StormWall.clear()
		return
	end
	local pnow = num(p.now)
	current = {
		cx = num(p.cx, 0) :: number,
		cz = num(p.cz, 0) :: number,
		r = r,
		toR = num(p.toR, r) :: number,
		closeStart = num(p.closeStart),
		closeEnd = num(p.closeEnd),
		dps = num(p.dps, 0) :: number,
		clockOffset = if pnow then pnow - serverNow() else 0,
	}
	lastR = -1
	ensureParts()
end

function StormWall.state(): { [string]: any }?
	return lastState
end

local function hide()
	for _, p in panels do
		p.CFrame = PARK
	end
	for _, d in drips do
		d.CFrame = PARK
	end
	for _, e in emitters do
		e.CFrame = PARK
		local pe = e:FindFirstChildOfClass("ParticleEmitter")
		if pe then
			pe.Enabled = false
		end
	end
	if cc then
		cc.Enabled = false
	end
	if vignette then
		vignette.Enabled = false
	end
end

function StormWall.step(dt: number, hero: Vector3?, focus: Vector3?)
	local p = current
	if not p then
		return
	end
	local t = serverNow() + p.clockOffset
	local R = StormWall.radiusAt(p, t)
	lastState = { cx = p.cx, cz = p.cz, r = R, toR = p.toR, outside = outside, dps = p.dps }
	local clock = os.clock()
	local n = #panels
	local H = StormWall.HEIGHT
	-- panels: resized only when the radius changes
	if math.abs(R - lastR) > 0.05 then
		lastR = R
		local w = 2 * math.pi * R / n + 0.4
		for _, pp in panels do
			pp.Size = Vector3.new(w, H, 0.6)
		end
		for _, d in drips do
			d.Size = Vector3.one * math.clamp(w * 0.35, 1.6, 5)
		end
	end
	local parts: { BasePart } = {}
	local cfs: { CFrame } = {}
	local wob = 0.6
	for i = 1, n do
		local a = (i - 0.5) / n * math.pi * 2
		local c, s = math.cos(a), math.sin(a)
		local pos = Vector3.new(p.cx + c * R, H / 2 - 1, p.cz + s * R)
		local look = CFrame.lookAt(pos, Vector3.new(p.cx, pos.Y, p.cz))
		table.insert(parts, panels[i])
		table.insert(cfs, look)
		-- drips sag and stretch slowly: the wall is melting
		local sag = math.sin(clock * 0.9 + i * 1.7) * wob
		table.insert(parts, drips[i])
		table.insert(cfs, look * CFrame.new(0, H / 2 - 1.2 + sag, 0))
	end
	-- ground edge particles on the arc nearest the camera
	local fx = focus or hero
	if fx and #emitters > 0 then
		local base = math.atan2(fx.Z - p.cz, fx.X - p.cx)
		for i, e in emitters do
			local a = base + (i - (#emitters + 1) / 2) * (24 / math.max(R, 24))
			local pos = Vector3.new(p.cx + math.cos(a) * R, 0.2, p.cz + math.sin(a) * R)
			table.insert(parts, e)
			table.insert(cfs, CFrame.lookAt(pos, Vector3.new(p.cx, 0.2, p.cz)))
			local pe = e:FindFirstChildOfClass("ParticleEmitter")
			if pe then
				pe.Enabled = true
			end
		end
	end
	workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)

	-- outside tint
	local out = false
	if hero then
		local dx, dz = hero.X - p.cx, hero.Z - p.cz
		out = dx * dx + dz * dz > R * R
	end
	outside = out
	outsideT = math.clamp(outsideT + (if out then dt * 3 else -dt * 3), 0, 1)
	ensureScreen()
	if cc then
		cc.Enabled = outsideT > 0.01
		cc.TintColor = Color3.new(1, 1, 1):Lerp(StormWall.TINT, outsideT)
		cc.Saturation = -0.25 * outsideT
		cc.Contrast = 0.08 * outsideT
	end
	if vignette and vignetteFrame then
		vignette.Enabled = outsideT > 0.01
		local pulse = 0.5 + 0.5 * math.sin(clock * 5)
		vignetteFrame.BackgroundTransparency = 1 - outsideT * (0.55 + 0.25 * pulse)
	end
end

function StormWall.isOutside(): boolean
	return outside
end

function StormWall.clear()
	current = nil
	lastState = nil
	outside = false
	outsideT = 0
	hide()
end

function StormWall.destroy()
	StormWall.clear()
	if folder then
		folder:Destroy()
		folder = nil
	end
	table.clear(panels)
	table.clear(drips)
	table.clear(emitters)
	if cc then
		cc:Destroy()
		cc = nil
	end
	if vignette then
		vignette:Destroy()
		vignette, vignetteFrame = nil, nil
	end
end

return StormWall
