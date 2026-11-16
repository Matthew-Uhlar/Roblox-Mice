--!strict
-- Particles (R4 Graphics, client): pooled ParticleEmitter bursts and loops for
-- FxController, using only textures that ship with every Roblox client
-- (rbxasset://textures/particles/*: the legacy Sparkles / Fire / Smoke /
-- Explosion / ForceField objects use them).
--
--   Particles.burst(kind, position: Vector3, count?, color?: Color3)
--   Particles.burstDir(kind, position, direction: Vector3, count?, color?)
--       emits along `direction` (the preset's cone; EmissionDirection Front of an
--       attachment looking that way): directional hit sparks, water jets, gusts.
--   Particles.loop(kind, color?) -> Loop   { move(cf), stop() }  (pooled)
--   Particles.clear()
--
-- One anchored, invisible host part sits at the origin; each preset lives on its
-- own Attachment. A burst moves that attachment and calls :Emit(n) (emitted
-- particles stay in world space), so a whole battle needs one emitter per
-- preset. Low-spec devices emit 40% of the particles and every device has a
-- per-second particle budget (LOW 300/s, else 900/s).

local Particles = {}

local TEX = {
	sparkles = "rbxasset://textures/particles/sparkles_main.dds",
	fire = "rbxasset://textures/particles/fire_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	implosion = "rbxasset://textures/particles/explosion01_implosion_main.dds",
	core = "rbxasset://textures/particles/explosion01_core_main.dds",
	shockwave = "rbxasset://textures/particles/explosion01_shockwave_main.dds",
}
Particles.TEX = TEX

local rgb = Color3.fromRGB

local LOW = false
local BUDGET = 900
local MULT = 1

function Particles.setLowSpec(low: boolean)
	LOW = low
	BUDGET = if low then 300 else 900
	MULT = if low then 0.4 else 1
end

local function ns(a: number, b: number?): NumberSequence
	if b == nil then
		return NumberSequence.new(a)
	end
	return NumberSequence.new(a, b)
end

type Preset = {
	texture: string,
	color: Color3,
	color2: Color3?,
	size: NumberSequence,
	transparency: NumberSequence,
	lifetime: NumberRange,
	speed: NumberRange,
	spread: number,
	accel: Vector3?,
	drag: number?,
	rotSpeed: NumberRange?,
	light: number,
	count: number,
	rate: number?, -- loops
	orientation: Enum.ParticleOrientation?,
	shape: Enum.ParticleEmitterShape?,
	zOffset: number?,
	front: boolean?, -- emit along the attachment's look vector (burstDir)
}

local PRESETS: { [string]: Preset } = {
	spark = {
		texture = TEX.sparkles,
		color = rgb(255, 240, 180),
		color2 = rgb(255, 170, 60),
		size = ns(0.55, 0),
		transparency = ns(0, 1),
		lifetime = NumberRange.new(0.18, 0.32),
		speed = NumberRange.new(9, 16),
		spread = 180,
		accel = Vector3.new(0, -30, 0),
		light = 1,
		count = 6,
	},
	poof = {
		texture = TEX.smoke,
		color = rgb(255, 244, 214),
		size = ns(1, 3.2),
		transparency = ns(0.35, 1),
		lifetime = NumberRange.new(0.35, 0.6),
		speed = NumberRange.new(2, 5),
		spread = 180,
		drag = 4,
		rotSpeed = NumberRange.new(-90, 90),
		light = 0.2,
		count = 5,
	},
	crumbs = {
		texture = TEX.sparkles,
		color = rgb(255, 204, 51),
		color2 = rgb(235, 160, 30),
		size = ns(0.6, 0.2),
		transparency = ns(0, 0.8),
		lifetime = NumberRange.new(0.4, 0.7),
		speed = NumberRange.new(6, 11),
		spread = 70,
		accel = Vector3.new(0, -40, 0),
		light = 0.3,
		count = 8,
	},
	boomCore = {
		texture = TEX.core,
		color = rgb(255, 200, 90),
		color2 = rgb(255, 90, 30),
		size = ns(3, 7),
		transparency = ns(0, 1),
		lifetime = NumberRange.new(0.25, 0.4),
		speed = NumberRange.new(0, 2),
		spread = 180,
		rotSpeed = NumberRange.new(-120, 120),
		light = 1,
		count = 3,
	},
	boomShock = {
		texture = TEX.shockwave,
		color = rgb(255, 230, 180),
		size = ns(2, 12),
		transparency = ns(0.2, 1),
		lifetime = NumberRange.new(0.3, 0.35),
		speed = NumberRange.new(0, 0),
		spread = 0,
		light = 0.8,
		count = 1,
	},
	boomSmoke = {
		texture = TEX.smoke,
		color = rgb(90, 80, 75),
		size = ns(2, 5),
		transparency = ns(0.4, 1),
		lifetime = NumberRange.new(0.8, 1.3),
		speed = NumberRange.new(3, 6),
		spread = 180,
		drag = 3,
		rotSpeed = NumberRange.new(-60, 60),
		light = 0,
		count = 4,
	},
	glint = {
		texture = TEX.sparkles,
		color = rgb(255, 230, 120),
		color2 = rgb(255, 255, 255),
		size = ns(0.9, 0),
		transparency = ns(0, 1),
		lifetime = NumberRange.new(0.6, 1.0),
		speed = NumberRange.new(1, 4),
		spread = 180,
		rotSpeed = NumberRange.new(-180, 180),
		light = 1,
		count = 10,
	},
	implode = {
		texture = TEX.implosion,
		color = rgb(255, 220, 120),
		size = ns(8, 1),
		transparency = ns(0.2, 1),
		lifetime = NumberRange.new(0.5, 0.6),
		speed = NumberRange.new(0, 0),
		spread = 0,
		light = 1,
		count = 2,
	},
	dodge = {
		texture = TEX.smoke,
		color = rgb(220, 240, 255),
		size = ns(0.8, 2),
		transparency = ns(0.3, 1),
		lifetime = NumberRange.new(0.3, 0.45),
		speed = NumberRange.new(2, 4),
		spread = 180,
		drag = 5,
		light = 0.4,
		count = 6,
	},
	heal = {
		texture = TEX.sparkles,
		color = rgb(130, 255, 140),
		size = ns(0.6, 0),
		transparency = ns(0, 1),
		lifetime = NumberRange.new(0.6, 1),
		speed = NumberRange.new(2, 4),
		spread = 30,
		light = 1,
		count = 8,
	},
	fire = {
		texture = TEX.fire,
		color = rgb(255, 120, 60),
		color2 = rgb(255, 40, 30),
		size = ns(3, 0.5),
		transparency = ns(0.25, 1),
		lifetime = NumberRange.new(0.5, 0.9),
		speed = NumberRange.new(3, 6),
		spread = 25,
		rotSpeed = NumberRange.new(-60, 60),
		light = 1,
		count = 4,
		rate = 24,
		shape = Enum.ParticleEmitterShape.Disc,
	},
	-- v3: directional / class presets ------------------------------------------
	sparkDir = {
		texture = TEX.sparkles,
		color = rgb(255, 245, 200),
		color2 = rgb(255, 160, 50),
		size = ns(0.5, 0),
		transparency = ns(0, 1),
		lifetime = NumberRange.new(0.15, 0.3),
		speed = NumberRange.new(14, 24),
		spread = 35,
		accel = Vector3.new(0, -25, 0),
		light = 1,
		count = 6,
		front = true,
	},
	critStar = {
		texture = TEX.sparkles,
		color = rgb(255, 235, 90),
		color2 = rgb(255, 255, 255),
		size = ns(2.6, 0),
		transparency = ns(0, 1),
		lifetime = NumberRange.new(0.22, 0.3),
		speed = NumberRange.new(0, 0.5),
		spread = 0,
		rotSpeed = NumberRange.new(-200, 200),
		light = 1,
		count = 2,
		zOffset = 2,
	},
	critRay = {
		texture = TEX.sparkles,
		color = rgb(255, 230, 80),
		color2 = rgb(255, 120, 40),
		size = ns(0.9, 0),
		transparency = ns(0, 1),
		lifetime = NumberRange.new(0.25, 0.4),
		speed = NumberRange.new(18, 30),
		spread = 180,
		drag = 6,
		light = 1,
		count = 12,
	},
	water = {
		texture = TEX.sparkles,
		color = rgb(150, 215, 255),
		color2 = rgb(60, 150, 240),
		size = ns(0.7, 0.2),
		transparency = ns(0.1, 1),
		lifetime = NumberRange.new(0.5, 0.9),
		speed = NumberRange.new(14, 24),
		spread = 18,
		accel = Vector3.new(0, -60, 0),
		light = 0.4,
		count = 18,
	},
	splash = {
		texture = TEX.smoke,
		color = rgb(200, 235, 255),
		size = ns(1.2, 3),
		transparency = ns(0.3, 1),
		lifetime = NumberRange.new(0.35, 0.55),
		speed = NumberRange.new(4, 8),
		spread = 180,
		drag = 5,
		light = 0.3,
		count = 6,
	},
	flame = {
		texture = TEX.fire,
		color = rgb(255, 200, 80),
		color2 = rgb(255, 70, 30),
		size = ns(2.4, 0.4),
		transparency = ns(0.15, 1),
		lifetime = NumberRange.new(0.4, 0.7),
		speed = NumberRange.new(4, 9),
		spread = 30,
		accel = Vector3.new(0, 6, 0),
		rotSpeed = NumberRange.new(-90, 90),
		light = 1,
		count = 10,
	},
	fizz = {
		texture = TEX.sparkles,
		color = rgb(170, 255, 120),
		color2 = rgb(255, 120, 220),
		size = ns(0.6, 1.1),
		transparency = ns(0.1, 1),
		lifetime = NumberRange.new(0.6, 1.1),
		speed = NumberRange.new(4, 10),
		spread = 50,
		accel = Vector3.new(0, 8, 0),
		drag = 2,
		light = 1,
		count = 16,
	},
	gust = {
		texture = TEX.smoke,
		color = rgb(235, 245, 255),
		size = ns(0.8, 2.6),
		transparency = ns(0.4, 1),
		lifetime = NumberRange.new(0.35, 0.6),
		speed = NumberRange.new(16, 26),
		spread = 22,
		drag = 3,
		rotSpeed = NumberRange.new(-120, 120),
		light = 0.2,
		count = 8,
		front = true,
	},
	leaves = {
		texture = TEX.sparkles,
		color = rgb(120, 210, 90),
		color2 = rgb(200, 160, 80),
		size = ns(0.7, 0.3),
		transparency = ns(0, 1),
		lifetime = NumberRange.new(0.6, 1.0),
		speed = NumberRange.new(6, 12),
		spread = 180,
		accel = Vector3.new(0, -12, 0),
		rotSpeed = NumberRange.new(-200, 200),
		light = 0.3,
		count = 14,
	},
	coins = {
		texture = TEX.sparkles,
		color = rgb(255, 220, 80),
		color2 = rgb(255, 170, 30),
		size = ns(0.9, 0.4),
		transparency = ns(0, 0.9),
		lifetime = NumberRange.new(0.9, 1.4),
		speed = NumberRange.new(16, 28),
		spread = 40,
		accel = Vector3.new(0, -45, 0),
		rotSpeed = NumberRange.new(-300, 300),
		light = 1,
		count = 24,
	},
	pillar = {
		texture = TEX.sparkles,
		color = rgb(255, 230, 150),
		size = ns(1.4, 0),
		transparency = ns(0, 1),
		lifetime = NumberRange.new(1.2, 2),
		speed = NumberRange.new(18, 34),
		spread = 6,
		light = 1,
		count = 20,
	},
	-- v3 sprint: a soft dust trail at a sprinting hero's feet (loop)
	sprintDust = {
		texture = TEX.smoke,
		color = rgb(214, 190, 150),
		color2 = rgb(170, 150, 120),
		size = ns(0.7, 1.8),
		transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(1, 1),
		}),
		lifetime = NumberRange.new(0.35, 0.6),
		speed = NumberRange.new(0.8, 2.2),
		spread = 50,
		accel = Vector3.new(0, 1.5, 0),
		drag = 2,
		light = 0,
		count = 3,
		rate = 16,
		zOffset = 0,
	},
	sparkleLoop = {
		texture = TEX.sparkles,
		color = rgb(255, 230, 120),
		size = ns(0.6, 0),
		transparency = ns(0, 1),
		lifetime = NumberRange.new(0.8, 1.4),
		speed = NumberRange.new(0.5, 2),
		spread = 180,
		light = 1,
		count = 4,
		rate = 6,
		shape = Enum.ParticleEmitterShape.Sphere,
	},
}
Particles.PRESETS = PRESETS

local host: BasePart? = nil
local attachments: { [string]: Attachment } = {}
local emitters: { [string]: ParticleEmitter } = {}
local loopPool: { [string]: { any } } = {}
local spentAt = 0
local spent = 0

local function getHost(): BasePart
	local h = host
	if h and h.Parent then
		return h
	end
	local p = Instance.new("Part")
	p.Name = "TrunkfallParticles"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.CFrame = CFrame.new(0, 0, 0)
	p.Parent = workspace
	host = p
	table.clear(attachments)
	table.clear(emitters)
	table.clear(loopPool)
	return p
end

local function makeEmitter(parent: Instance, pr: Preset, color: Color3?): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = pr.texture
	local c1 = color or pr.color
	e.Color =
		ColorSequence.new(c1, if color then color:Lerp(Color3.new(1, 1, 1), 0.3) else (pr.color2 or pr.color))
	e.Size = pr.size
	e.Transparency = pr.transparency
	e.Lifetime = pr.lifetime
	e.Speed = pr.speed
	e.SpreadAngle = Vector2.new(pr.spread, pr.spread)
	e.Acceleration = pr.accel or Vector3.zero
	e.Drag = pr.drag or 0
	e.RotSpeed = pr.rotSpeed or NumberRange.new(0, 0)
	e.Rotation = NumberRange.new(0, 360)
	e.LightEmission = pr.light
	e.LightInfluence = 0
	if pr.orientation then
		e.Orientation = pr.orientation
	end
	if pr.shape then
		e.Shape = pr.shape
	end
	e.ZOffset = pr.zOffset or 0.5
	e.EmissionDirection = if pr.front then Enum.NormalId.Front else Enum.NormalId.Top
	e.Rate = pr.rate or 0
	e.Enabled = false
	e.Parent = parent
	return e
end

local function budget(n: number): number
	local now = os.clock()
	if now - spentAt > 1 then
		spentAt = now
		spent = 0
	end
	local k = math.max(0, math.min(n, BUDGET - spent))
	spent += k
	return k
end

local function emitAt(kind: string, cf: CFrame, count: number?, color: Color3?)
	local pr = PRESETS[kind]
	if not pr then
		return
	end
	local h = getHost()
	local a = attachments[kind]
	local e = emitters[kind]
	if not a or not e then
		local na = Instance.new("Attachment")
		na.Name = kind
		na.Parent = h
		a = na
		attachments[kind] = na
		e = makeEmitter(na, pr, nil)
		emitters[kind] = e
	end
	local n = budget(math.max(1, math.floor((count or pr.count) * MULT + 0.5)))
	if n <= 0 then
		return
	end
	local em = e :: ParticleEmitter
	if color then
		em.Color = ColorSequence.new(color, color:Lerp(Color3.new(1, 1, 1), 0.35))
	else
		em.Color = ColorSequence.new(pr.color, pr.color2 or pr.color)
	end
	(a :: Attachment).CFrame = cf
	em:Emit(n)
end

function Particles.burst(kind: string, position: Vector3, count: number?, color: Color3?)
	emitAt(kind, CFrame.new(position), count, color)
end

-- Emits along `dir` (presets with `front`; others spray as usual).
function Particles.burstDir(kind: string, position: Vector3, dir: Vector3, count: number?, color: Color3?)
	local cf = if dir.Magnitude > 1e-3 then CFrame.lookAt(position, position + dir) else CFrame.new(position)
	emitAt(kind, cf, count, color)
end

export type Loop = { move: (CFrame) -> (), stop: () -> () }

function Particles.loop(kind: string, color: Color3?): Loop?
	local pr = PRESETS[kind]
	if not pr then
		return nil
	end
	local h = getHost()
	local pool = loopPool[kind]
	if not pool then
		pool = {}
		loopPool[kind] = pool
	end
	local item: any = table.remove(pool)
	if not item then
		local a = Instance.new("Attachment")
		a.Name = kind .. "Loop"
		a.Parent = h
		item = { a = a, e = makeEmitter(a, pr, color) }
	end
	local e: ParticleEmitter = item.e
	local c = color or pr.color
	e.Color = ColorSequence.new(c, if color then c:Lerp(Color3.new(1, 1, 1), 0.3) else (pr.color2 or c))
	e.Rate = (pr.rate or 5) * MULT
	e.Enabled = true
	local stopped = false
	return {
		move = function(cf: CFrame)
			item.a.CFrame = cf
		end,
		stop = function()
			if stopped then
				return
			end
			stopped = true
			e.Enabled = false
			table.insert(pool, item)
		end,
	}
end

function Particles.clear()
	for _, e in emitters do
		e:Clear()
	end
	for _, pool in loopPool do
		for _, item in pool do
			item.e:Clear()
		end
	end
end

local _ = LOW

return Particles
