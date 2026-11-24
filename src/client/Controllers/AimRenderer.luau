--!strict
-- AimRenderer (iteration 7 §B1, team Client): draws the hold-to-aim ability
-- preview from InputController.holdPreview() and Util/AimPreview geometry.
--
--   * Essential outline (always, whatever the Effects setting): the cast-range
--     ring around the hero and the shape's edge (area circle, line / path strip
--     edges, landing ring, cone edges, self ring).
--   * Decoration (Effects full / reduced; none on "off"): a translucent fill.
--   * Turret / barricade: BuildRenderer draws the model ghost at the same point
--     (InputController.previewAim names the held slot); we add the range ring
--     and a footprint ring.
--   * Cheese yellow when the slot is ready, grey while it is on cooldown.
-- All parts are adornments on one invisible anchor at the origin (their CFrame
-- is world space), pooled; nothing is created per frame once warm.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local AimPreview = require(Client.Util.AimPreview)
local State = require(script.Parent.State)

local AimRenderer = {}

local READY = Color3.fromRGB(255, 220, 90)
local COOLING = Color3.fromRGB(170, 170, 175)
local EDGE_ALPHA = 0.15
local RING_ALPHA = 0.35
local EDGE_W = 0.35 -- studs: outline thickness
local LIFT = 0.12 -- studs above the ground
local ARC_SEGMENTS = 6

local folder: Folder? = nil
local anchor: BasePart? = nil
local conn: RBXScriptConnection? = nil
local supported = true
local warned = false

type Pool<T> = { items: { T }, used: number }
local rings: Pool<CylinderHandleAdornment> = { items = {}, used = 0 }
local boxes: Pool<BoxHandleAdornment> = { items = {}, used = 0 }

local inputMod: any = nil
local function input(): any
	if inputMod == nil then
		local ok, mod = pcall(require, script.Parent.InputController)
		inputMod = if ok and type(mod) == "table" then mod else false
	end
	return inputMod or nil
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

local function getAnchor(): BasePart
	local a = anchor
	if a and a.Parent then
		return a
	end
	local f = Instance.new("Folder")
	f.Name = "TrunkfallAimPreview"
	f.Parent = workspace
	folder = f
	local p = Instance.new("Part")
	p.Name = "AimAnchor"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.one * 0.1
	p.CFrame = CFrame.identity
	p.Parent = f
	anchor = p
	return p
end

local function ring(): CylinderHandleAdornment?
	rings.used += 1
	local a = rings.items[rings.used]
	if not a then
		local ok, made = pcall(function()
			local n = Instance.new("CylinderHandleAdornment")
			n.Name = "AimRing"
			n.Height = 0.08
			n.AlwaysOnTop = false
			n.ZIndex = 1
			n.Adornee = getAnchor()
			n.Parent = folder
			return n
		end)
		if not ok then
			supported = false
			rings.used -= 1
			return nil
		end
		a = made
		rings.items[rings.used] = a
	end
	a.Visible = true
	return a
end

local function box(): BoxHandleAdornment?
	boxes.used += 1
	local a = boxes.items[boxes.used]
	if not a then
		local ok, made = pcall(function()
			local n = Instance.new("BoxHandleAdornment")
			n.Name = "AimEdge"
			n.AlwaysOnTop = false
			n.ZIndex = 1
			n.Adornee = getAnchor()
			n.Parent = folder
			return n
		end)
		if not ok then
			supported = false
			boxes.used -= 1
			return nil
		end
		a = made
		boxes.items[boxes.used] = a
	end
	a.Visible = true
	return a
end

-- A ring (outline, inner > 0) or a disc (fill, inner = 0) at (x, z).
local function drawRing(x: number, z: number, r: number, inner: number, color: Color3, alpha: number)
	if r < 0.2 then
		return
	end
	local a = ring()
	if not a then
		return
	end
	a.Radius = r
	a.InnerRadius = math.clamp(inner, 0, r - 0.05)
	a.Color3 = color
	a.Transparency = alpha
	a.CFrame = CFrame.new(x, groundY(x, z) + LIFT, z) * CFrame.Angles(math.pi / 2, 0, 0)
end

-- A flat strip from (x1, z1) to (x2, z2), `w` wide.
local function drawStrip(
	x1: number,
	z1: number,
	x2: number,
	z2: number,
	w: number,
	color: Color3,
	alpha: number
)
	local dx, dz = x2 - x1, z2 - z1
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 0.1 then
		return
	end
	local a = box()
	if not a then
		return
	end
	local y = groundY(x1, z1) + LIFT
	local from = Vector3.new(x1, y, z1)
	a.Size = Vector3.new(w, 0.08, len)
	a.Color3 = color
	a.Transparency = alpha
	a.CFrame = CFrame.lookAt(from, Vector3.new(x2, y, z2)) * CFrame.new(0, 0, -len / 2)
end

-- The two long edges (outline) of a strip `w` wide, plus its fill.
local function drawLine(geo: AimPreview.Geo, color: Color3, fill: number?)
	local dx, dz = geo.toX - geo.fromX, geo.toZ - geo.fromZ
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 0.1 then
		return
	end
	local px, pz = -dz / len * geo.width / 2, dx / len * geo.width / 2
	drawStrip(geo.fromX + px, geo.fromZ + pz, geo.toX + px, geo.toZ + pz, EDGE_W, color, EDGE_ALPHA)
	drawStrip(geo.fromX - px, geo.fromZ - pz, geo.toX - px, geo.toZ - pz, EDGE_W, color, EDGE_ALPHA)
	-- the far end cap
	drawStrip(geo.toX + px, geo.toZ + pz, geo.toX - px, geo.toZ - pz, EDGE_W, color, EDGE_ALPHA)
	if fill then
		drawStrip(geo.fromX, geo.fromZ, geo.toX, geo.toZ, geo.width, color, fill)
	end
end

local function hideAll()
	for _, a in rings.items do
		a.Visible = false
	end
	for _, a in boxes.items do
		a.Visible = false
	end
	rings.used = 0
	boxes.used = 0
end

local function rootPart(): BasePart?
	local char = Players.LocalPlayer and Players.LocalPlayer.Character
	local r = char and char:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function render()
	hideAll()
	if not supported or not State.inCombat() then
		return
	end
	local ic = input()
	if not ic or type(ic.holdPreview) ~= "function" then
		return
	end
	local hud = State.get("hud")
	if type(hud) == "table" and hud.downed == true then
		return
	end
	local hv = ic.holdPreview()
	if not hv then
		return
	end
	local shape: AimPreview.Shape? = ic.slotShape(hv.slot)
	local root = rootPart()
	if not shape or not root then
		return
	end
	local ready = State.abilityCooldown(hv.slot) <= 0.15
	local color = if ready then READY else COOLING
	local okG, gfx = pcall(State.gfx)
	local fill = AimPreview.fillAlpha(if okG and type(gfx) == "table" then tostring(gfx.fx) else "full")
	local pos = root.Position
	local geo = AimPreview.geometry(shape, pos.X, pos.Z, hv.x, hv.z)
	-- essential: the cast-range ring (self shapes: their area)
	drawRing(pos.X, pos.Z, geo.range, geo.range - EDGE_W, color, RING_ALPHA)
	local f = geo.form
	if f == "self" then
		if fill then
			drawRing(pos.X, pos.Z, geo.radius, 0, color, fill)
		end
	elseif f == "circle" then
		drawRing(geo.cx, geo.cz, geo.radius, geo.radius - EDGE_W, color, EDGE_ALPHA)
		if fill then
			drawRing(geo.cx, geo.cz, geo.radius, 0, color, fill)
		end
	elseif f == "line" then
		drawLine(geo, color, fill)
	elseif f == "path" or f == "leap" then
		drawStrip(geo.fromX, geo.fromZ, geo.toX, geo.toZ, geo.width, color, EDGE_ALPHA + 0.2)
		drawRing(geo.cx, geo.cz, geo.radius, geo.radius - EDGE_W, color, EDGE_ALPHA)
		if f == "leap" then
			-- the landing ghost: a solid footprint where the hero lands
			drawRing(geo.cx, geo.cz, 2.2, 0, color, if fill then 0.45 else 0.6)
		end
		if fill and geo.radius > 0 then
			drawRing(geo.cx, geo.cz, geo.radius, 0, color, fill)
		end
	elseif f == "ghost" then
		drawRing(geo.cx, geo.cz, geo.radius, geo.radius - EDGE_W, color, EDGE_ALPHA)
	elseif f == "cone" then
		local lx, lz, rx, rz = AimPreview.coneEdges(geo)
		drawStrip(geo.fromX, geo.fromZ, lx, lz, EDGE_W, color, EDGE_ALPHA)
		drawStrip(geo.fromX, geo.fromZ, rx, rz, EDGE_W, color, EDGE_ALPHA)
		local half = math.rad(geo.angle) / 2
		local px, pz = lx, lz
		for i = 1, ARC_SEGMENTS do
			local a = geo.yaw - half + 2 * half * i / ARC_SEGMENTS
			local nx, nz = geo.fromX + math.sin(a) * geo.length, geo.fromZ + math.cos(a) * geo.length
			drawStrip(px, pz, nx, nz, EDGE_W, color, EDGE_ALPHA)
			px, pz = nx, nz
		end
	end
end

function AimRenderer.init()
	if conn then
		return
	end
	conn = RunService.RenderStepped:Connect(function()
		local ok, err = pcall(render)
		if not ok then
			if not warned then
				warned = true
				warn("[Trunkfall] AimRenderer: " .. tostring(err))
			end
			hideAll()
		end
	end)
end

function AimRenderer.destroy()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	hideAll()
	table.clear(rings.items)
	table.clear(boxes.items)
	if folder then
		folder:Destroy()
		folder = nil
	end
	anchor = nil
end

return AimRenderer
