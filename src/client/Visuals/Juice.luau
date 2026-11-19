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

-- iter1 boss kill beat: a part-built treasure chest bursts out of the ground,
-- its lid flies open, and confetti rains (CONFETTI pieces, with gravity).
Juice.CONFETTI = 36
local CONFETTI_COLORS = {
	Color3.fromRGB(255, 201, 60),
	Color3.fromRGB(255, 90, 78),
	Color3.fromRGB(91, 209, 107),
	Color3.fromRGB(78, 168, 255),
	Color3.fromRGB(179, 107, 255),
	Color3.fromRGB(255, 255, 255),
}
function Juice.bossKill(x: number, z: number, particles: any)
	local ground = Vector3.new(x, 0, z)
	local wood = Color3.fromRGB(150, 96, 52)
	local box = part(
		Enum.PartType.Block,
		Vector3.new(4, 2.6, 2.8),
		CFrame.new(ground + Vector3.new(0, -2, 0)),
		wood,
		0
	)
	box.Material = Enum.Material.WoodPlanks
	local lid = part(
		Enum.PartType.Block,
		Vector3.new(4.1, 0.8, 2.9),
		CFrame.new(ground + Vector3.new(0, -0.4, 0)),
		wood,
		0
	)
	lid.Material = Enum.Material.WoodPlanks
	local bands: { Part } = {}
	for _, dx in { -1.4, 0, 1.4 } do
		local b = part(Enum.PartType.Block, Vector3.new(0.35, 2.7, 2.9), CFrame.new(ground), Juice.GOLD, 0)
		b.Material = Enum.Material.Metal
		table.insert(bands, b)
		b:SetAttribute("Dx", dx)
	end
	local glow = part(Enum.PartType.Block, Vector3.new(3.4, 0.3, 2.2), CFrame.new(ground), Juice.GOLD, 0.1)
	local parts: { Instance } = { box, lid, glow }
	for _, b in bands do
		table.insert(parts, b)
	end
	local bits: { { p: Part, v: Vector3, spin: Vector3 } } = {}
	local n = if low then math.floor(Juice.CONFETTI / 3) else Juice.CONFETTI
	for i = 1, n do
		local c = CONFETTI_COLORS[(i % #CONFETTI_COLORS) + 1]
		local p = part(
			Enum.PartType.Block,
			Vector3.new(0.5, 0.06, 0.3),
			CFrame.new(ground + Vector3.new(0, 3, 0)),
			c,
			0
		)
		p.Material = Enum.Material.SmoothPlastic
		local a = math.random() * math.pi * 2
		local sp = 6 + math.random() * 10
		table.insert(bits, {
			p = p,
			v = Vector3.new(math.cos(a) * sp, 18 + math.random() * 14, math.sin(a) * sp),
			spin = Vector3.new(math.random() * 12, math.random() * 12, math.random() * 12),
		})
		table.insert(parts, p)
	end
	if particles then
		pcall(particles.burst, "coins", ground + Vector3.new(0, 2, 0), if low then 10 else 30)
		pcall(particles.burst, "boomShock", ground + Vector3.new(0, 1, 0), 1, Juice.GOLD)
	end
	local life = 2.4
	local last = 0
	add(life, parts, function(f)
		local t = f * life
		local dt = t - last
		last = t
		-- chest: pop out of the ground (overshoot), lid swings open at 0.35 s
		local rise = math.clamp(t / 0.3, 0, 1)
		local y = -2
			+ 3.4 * (1 - (1 - rise) ^ 3)
			+ (if t > 0.3 then -0.2 * math.sin(math.min(1, (t - 0.3) / 0.2) * math.pi) else 0)
		local base = CFrame.new(ground + Vector3.new(0, y, 0))
		box.CFrame = base
		for _, b in bands do
			b.CFrame = base * CFrame.new(tonumber(b:GetAttribute("Dx")) or 0, 0, 0)
		end
		local open = math.clamp((t - 0.35) / 0.25, 0, 1)
		local hinge = base * CFrame.new(0, 1.3, 1.4)
		lid.CFrame = hinge * CFrame.Angles(-open * 1.9, 0, 0) * CFrame.new(0, 0.4, -1.45)
		glow.CFrame = base * CFrame.new(0, 1.25, 0)
		glow.Transparency = 1 - open * 0.9
		-- confetti after the lid opens
		for _, b in bits do
			if t < 0.4 then
				b.p.CFrame = base * CFrame.new(0, 1, 0)
			else
				b.v += Vector3.new(0, -30 * dt, 0)
				b.v *= 1 - math.min(0.9, dt * 1.6) -- paper drag
				local pos = b.p.Position + b.v * dt
				if pos.Y < 0.1 then
					pos = Vector3.new(pos.X, 0.1, pos.Z)
					b.v = Vector3.zero
				end
				b.p.CFrame = CFrame.new(pos) * CFrame.Angles(t * b.spin.X, t * b.spin.Y, t * b.spin.Z)
			end
			if f > 0.8 then
				b.p.Transparency = (f - 0.8) / 0.2
			end
		end
		if f > 0.85 then
			local a = (f - 0.85) / 0.15
			box.Transparency, lid.Transparency = a, a
			for _, b in bands do
				b.Transparency = a
			end
		end
	end)
end

-- iter2: a Cheese Gem drop. The gem bursts up out of the ground in its tier
-- colour, then hovers, bobbing and spinning, under a light beam until
-- Juice.gemGone(key) (picked up) or GEM_LIFE seconds. Tier 9+ gets a second
-- ring pulse; a unique gem gets a gold halo.
Juice.GEM_LIFE = 8
local gems: { [any]: { kill: boolean } } = {}
function Juice.gemDrop(key: any, x: number, z: number, tier: number, unique: boolean?, particles: any)
	local okA, GemArt = pcall(require, script.Parent:FindFirstChild("GemArt") :: any)
	if not okA or type(GemArt) ~= "table" then
		return
	end
	if key ~= nil and gems[key] then
		gems[key].kill = true
	end
	local col = GemArt.color(tier)
	local glow = GemArt.glow(tier)
	local holder = Instance.new("Model")
	holder.Name = "GemDrop"
	holder.Parent = getFolder()
	local origin = CFrame.new(x, 0, z)
	local gparts = GemArt.build(holder, tier, origin, 1.6, unique)
	local offsets = {}
	for i, p in gparts do
		offsets[i] = origin:ToObjectSpace(p.CFrame)
	end
	local beam = part(Enum.PartType.Cylinder, Vector3.new(24, 1.2, 1.2), CFrame.new(x, 12, z) * UP, glow, 0.6)
	local ring = part(Enum.PartType.Cylinder, Vector3.new(0.12, 2, 2), CFrame.new(x, 0.1, z) * UP, col, 0.2)
	local parts: { Instance } = { holder, beam, ring }
	if particles then
		pcall(particles.burst, "glint", Vector3.new(x, 2, z), if low then 10 else 26, glow)
		pcall(particles.burstDir, "pillar", Vector3.new(x, 0.5, z), Vector3.yAxis, if low then 6 else 14, col)
	end
	local state = { kill = false }
	if key ~= nil then
		gems[key] = state
	end
	local life = Juice.GEM_LIFE
	add(life, parts, function(f)
		if state.kill then
			error("gone") -- Juice.step drops the effect on an error
		end
		local t = f * life
		local rise = math.clamp(t / 0.35, 0, 1)
		local y = 0.3 + 2.4 * (1 - (1 - rise) ^ 3) + math.sin(t * 2.2) * 0.25
		local cf = CFrame.new(x, y, z) * CFrame.Angles(0, t * 1.8, 0)
		for i, p in gparts do
			p.CFrame = cf * offsets[i]
		end
		local pulse = (t * (if tier >= 9 then 1.6 else 1)) % 1
		local d = 2 + 7 * pulse
		ring.Size = Vector3.new(0.12, d, d)
		ring.Transparency = 0.2 + 0.8 * pulse
		beam.Transparency = 0.6 + 0.3 * math.sin(t * 3) ^ 2 + (if f > 0.9 then (f - 0.9) * 4 else 0)
	end)
end

function Juice.gemGone(key: any)
	local g = gems[key]
	if g then
		g.kill = true
		gems[key] = nil
	end
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
