--!strict
-- Juice (v4, team G): extra feedback effects for FxController.
--
--   Juice.levelUp(pos: Vector3, particles)       gold column, ground ring, sparkles,
--                                                and a popping "LEVEL UP!" billboard
--   Juice.bossArrive(x, z, name?, particles)     red pillar, double shockwave and a
--                                                big "BOSS!" billboard
--   Juice.arrivalPop(pos, particles)             tiny glint where a crumb lands on a hero
--   Juice.step(dt)                               advances the timed effects
--   Juice.isMine(hx, hz, me: Vector3?, others: {Vector3}) -> boolean
--       damage-number ownership when the hit Fx has no `by`: the hit is "yours"
--       when your hero is within OWN_RANGE and no other hero is closer to it
--   Juice.clear()
-- Every effect owns at most a handful of parts, made on demand and destroyed
-- when done (level-ups and boss arrivals are rare). Low-spec devices skip the
-- billboard pop and half the particles.

local Juice = {}

Juice.OWN_RANGE = 20
Juice.GOLD = Color3.fromRGB(255, 201, 60)
Juice.GOLD_STROKE = Color3.fromRGB(91, 58, 30)
Juice.RED = Color3.fromRGB(255, 75, 62)

type Fx = { t: number, life: number, update: (f: number) -> (), parts: { Instance } }
local active: { Fx } = {}
local low = false
local folder: Folder? = nil

function Juice.setLowSpec(on: boolean)
	low = on
end

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "TrunkfallJuice"
	f.Parent = workspace
	folder = f
	return f
end

local function part(
	shape: Enum.PartType,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	transparency: number
): Part
	local p = Instance.new("Part")
	p.Shape = shape
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.Neon
	p.Transparency = transparency
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = getFolder()
	return p
end

local function add(life: number, parts: { Instance }, update: (f: number) -> ())
	if #active >= (if low then 6 else 16) then
		local old = table.remove(active, 1)
		if old then
			for _, p in old.parts do
				p:Destroy()
			end
		end
	end
	table.insert(active, { t = 0, life = life, update = update, parts = parts })
end

local function billboard(at: Vector3, text: string, color: Color3, w: number, h: number): (Part, TextLabel)
	local anchor = part(Enum.PartType.Block, Vector3.one * 0.2, CFrame.new(at), color, 1)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(w, h)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 220
	gui.Adornee = anchor
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeColor3 = Juice.GOLD_STROKE
	label.TextStrokeTransparency = 0
	label.Parent = gui
	gui.Parent = anchor
	return anchor, label
end

local UP = CFrame.Angles(0, 0, math.pi / 2)

function Juice.levelUp(pos: Vector3, particles: any)
	local ground = Vector3.new(pos.X, 0.1, pos.Z)
	local column = part(
		Enum.PartType.Cylinder,
		Vector3.new(14, 0.4, 0.4),
		CFrame.new(ground + Vector3.new(0, 7, 0)) * UP,
		Juice.GOLD,
		0.2
	)
	local ring =
		part(Enum.PartType.Cylinder, Vector3.new(0.15, 2, 2), CFrame.new(ground) * UP, Juice.GOLD, 0.25)
	local parts: { Instance } = { column, ring }
	local label: TextLabel? = nil
	if not low then
		local anchor, l = billboard(ground + Vector3.new(0, 7, 0), "LEVEL UP!", Juice.GOLD, 220, 64)
		table.insert(parts, anchor)
		label = l
	end
	if particles then
		pcall(particles.burst, "glint", pos + Vector3.new(0, 1.5, 0), if low then 12 else 24, Juice.GOLD)
		pcall(particles.burstDir, "pillar", ground, Vector3.yAxis, if low then 8 else 16, Juice.GOLD)
	end
	add(1.1, parts, function(f)
		column.Transparency = 0.2 + 0.8 * math.clamp(f / 0.55, 0, 1)
		column.Size = Vector3.new(14 + 4 * f, 0.4 + 1.2 * (1 - f), 0.4 + 1.2 * (1 - f))
		local rf = math.clamp(f / 0.32, 0, 1)
		local d = 2 + 16 * (1 - (1 - rf) ^ 2)
		ring.Size = Vector3.new(0.15, d, d)
		ring.Transparency = 0.25 + 0.75 * rf
		if label then
			local pop = if f < 0.15 then 1.4 - (f / 0.15) * 0.4 else 1
			label.Size = UDim2.fromScale(pop, pop)
			label.Position = UDim2.fromScale((1 - pop) / 2, (1 - pop) / 2 - f * 0.6)
			local fade = math.clamp((f - 0.7) / 0.3, 0, 1)
			label.TextTransparency = fade
			label.TextStrokeTransparency = fade
		end
	end)
end

function Juice.bossArrive(x: number, z: number, name: string?, particles: any)
	local ground = Vector3.new(x, 0.1, z)
	local pillar = part(
		Enum.PartType.Cylinder,
		Vector3.new(80, 10, 10),
		CFrame.new(ground + Vector3.new(0, 40, 0)) * UP,
		Juice.RED,
		0.4
	)
	local ring1 =
		part(Enum.PartType.Cylinder, Vector3.new(0.2, 4, 4), CFrame.new(ground) * UP, Juice.RED, 0.2)
	local ring2 =
		part(Enum.PartType.Cylinder, Vector3.new(0.2, 4, 4), CFrame.new(ground) * UP, Juice.GOLD, 0.3)
	local parts: { Instance } = { pillar, ring1, ring2 }
	local label: TextLabel? = nil
	if not low then
		local anchor, l =
			billboard(ground + Vector3.new(0, 14, 0), "⚠ " .. (name or "BOSS") .. "!", Juice.RED, 360, 80)
		table.insert(parts, anchor)
		label = l
	end
	if particles then
		pcall(particles.burst, "boomShock", ground + Vector3.new(0, 2, 0), 2, Juice.RED)
		pcall(particles.burstDir, "pillar", ground, Vector3.yAxis, if low then 12 else 30, Juice.RED)
	end
	add(2.2, parts, function(f)
		pillar.Transparency = 0.4 + 0.6 * math.clamp(f / 0.6, 0, 1)
		local w = 10 * (1 - f)
		pillar.Size = Vector3.new(80, math.max(0.5, w), math.max(0.5, w))
		local a = math.clamp(f / 0.4, 0, 1)
		local d1 = 4 + 60 * (1 - (1 - a) ^ 2)
		ring1.Size = Vector3.new(0.2, d1, d1)
		ring1.Transparency = 0.2 + 0.8 * a
		local b = math.clamp((f - 0.15) / 0.45, 0, 1)
		local d2 = 4 + 44 * (1 - (1 - b) ^ 2)
		ring2.Size = Vector3.new(0.2, d2, d2)
		ring2.Transparency = if f < 0.15 then 1 else 0.3 + 0.7 * b
		if label then
			local pop = if f < 0.08 then 1.5 - (f / 0.08) * 0.5 else 1
			label.Size = UDim2.fromScale(pop, pop)
			label.Position = UDim2.fromScale((1 - pop) / 2, (1 - pop) / 2)
			local fade = math.clamp((f - 0.75) / 0.25, 0, 1)
			label.TextTransparency = fade
			label.TextStrokeTransparency = fade
		end
	end)
end

function Juice.arrivalPop(pos: Vector3, particles: any)
	if particles and not low then
		pcall(particles.burst, "glint", pos, 2, Juice.GOLD)
	end
end

function Juice.isMine(hx: number, hz: number, me: Vector3?, others: { Vector3 }): boolean
	if not me then
		return false
	end
	local dm = (me.X - hx) ^ 2 + (me.Z - hz) ^ 2
	if dm > Juice.OWN_RANGE * Juice.OWN_RANGE then
		return false
	end
	for _, o in others do
		if (o.X - hx) ^ 2 + (o.Z - hz) ^ 2 < dm then
			return false
		end
	end
	return true
end

function Juice.step(dt: number)
	local i = 1
	while i <= #active do
		local e = active[i]
		e.t += dt
		local f = e.t / e.life
		if f >= 1 then
			for _, p in e.parts do
				p:Destroy()
			end
			table.remove(active, i)
		else
			local ok = pcall(e.update, f)
			if not ok then
				for _, p in e.parts do
					p:Destroy()
				end
				table.remove(active, i)
			else
				i += 1
			end
		end
	end
end

function Juice.clear()
	for _, e in active do
		for _, p in e.parts do
			p:Destroy()
		end
	end
	table.clear(active)
end

return Juice
