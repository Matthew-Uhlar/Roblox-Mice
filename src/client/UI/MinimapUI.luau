--!strict
-- Circular 2D minimap (no ViewportFrame): a player-centred radar drawn with
-- pooled Frames, refreshed at 10 Hz. It plots
--   * squad-mates (squad colour, clamped to the rim when far, so you can
--     always find them),
--   * enemy heroes in sight (Minimap.SIGHT studs; diamonds in their squad colour),
--   * POIs (Fx `poi`: kind colour, dimmed when done),
--   * the boss (Fx `boss` id -> HordeRenderer.position; crown, clamped),
--   * the Rind Gate portal (Fx `portal`; clamped),
--   * loot bags (Fx `bag` / `bagGone`), gear on the ground (Fx `gear` /
--     `gearGone`, rarity colour) and golden carrier mice (Fx `carrier` /
--     `carrierEscape`, followed through HordeRenderer.position),
--   * bounty holders (a pulsing target ring, plus a world BillboardGui over
--     their hero so everyone can see who carries it).
-- Hero positions come from characters (humans) and the workspace.Bots models
-- (bots: attribute BotId). Squads come from State "match" (v2) or the party (v1).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Remotes = require(Client.Util.Remotes)
local Minimap = require(Client.Util.Minimap)
local State = require(Client.Controllers.State)

local MinimapUI = {}

local C = Theme.C
local make = Theme.make

local PoiDefs: any = nil
do
	local ok, mod = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Pois"))
	end)
	if ok then
		PoiDefs = mod
	end
end

local UPDATE_EVERY = 0.1
local BOT_SCAN_EVERY = 1
local MAX_BILLBOARDS = 4

export type Handle = { frame: Frame, destroy: () -> () }

local function poiColor(kind: string): Color3
	local def = if PoiDefs and type(PoiDefs.get) == "function" then PoiDefs.get(kind) else nil
	local c = def and def.color
	if type(c) == "table" and tonumber(c[1]) and tonumber(c[2]) and tonumber(c[3]) then
		return Color3.fromRGB(c[1], c[2], c[3])
	end
	return C.cheese
end

-- Builds the minimap into `parent` (top-right corner). `size` = diameter.
function MinimapUI.build(parent: Instance, size: number): Handle
	local radius = size / 2
	local conns: { any } = {}

	local holder = make("Frame", {
		Name = "Minimap",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 10),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = C.rind,
		BackgroundTransparency = 0.2,
		Visible = false,
		Parent = parent,
	}) :: Frame
	Theme.round().Parent = holder
	Theme.goldStroke(3).Parent = holder
	Theme.gradient(holder, Color3.fromRGB(150, 130, 100), Color3.fromRGB(255, 240, 210), 90)
	Theme.dropShadow(holder, 5, 0.55)

	-- Range rings and a faint cross.
	for _, f in { 0.66, 0.33 } do
		local ring = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(f, f),
			BackgroundTransparency = 1,
			Parent = holder,
		})
		Theme.round().Parent = ring
		Theme.stroke(C.gold, 1, 0.7).Parent = ring
	end
	for _, v in { true, false } do
		make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = if v then UDim2.new(0, 1, 0.9, 0) else UDim2.new(0.9, 0, 0, 1),
			BackgroundColor3 = C.gold,
			BackgroundTransparency = 0.8,
			BorderSizePixel = 0,
			Parent = holder,
		})
	end
	local north = Theme.label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 3),
		Size = UDim2.fromOffset(20, 14),
		TextSize = Theme.TYPE.micro,
		TextColor3 = C.goldLight,
		Text = "N",
		Parent = holder,
	})
	Theme.textStroke(C.shade, 1).Parent = north

	local layer = make("Frame", {
		Name = "Markers",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = holder,
	}) :: Frame

	-- Self marker (centre).
	local me = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(12, 12),
		BackgroundColor3 = C.white,
		ZIndex = 8,
		Parent = layer,
	})
	Theme.round().Parent = me
	Theme.stroke(C.goldDeep, 2).Parent = me

	------------------------------------------------------------------
	-- Marker pools
	------------------------------------------------------------------
	type Pool = { items: { GuiObject }, used: number, make: () -> GuiObject }
	local pools: { [string]: Pool } = {}

	local function pool(kind: string, factory: () -> GuiObject)
		pools[kind] = { items = {}, used = 0, make = factory }
	end
	local function dot(d: number, z: number): () -> GuiObject
		return function()
			local f = make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(d, d),
				BorderSizePixel = 0,
				ZIndex = z,
				Parent = layer,
			})
			Theme.round().Parent = f
			Theme.stroke(C.white, 1.5).Parent = f
			return f
		end
	end
	pool("mate", dot(10, Minimap.LAYER.mate + 2))
	pool("enemy", function()
		local f = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(9, 9),
			Rotation = 45,
			BorderSizePixel = 0,
			ZIndex = Minimap.LAYER.enemy + 2,
			Parent = layer,
		})
		Theme.stroke(C.shade, 1.5).Parent = f
		return f
	end)
	pool("poi", function()
		local f = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(7, 7),
			Rotation = 45,
			BorderSizePixel = 0,
			ZIndex = Minimap.LAYER.poi + 2,
			Parent = layer,
		})
		Theme.corner(2).Parent = f
		return f
	end)
	pool("boss", function()
		return Theme.icon("crown", 18, C.red, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = Minimap.LAYER.boss + 2,
			Parent = layer,
		})
	end)
	pool("portal", function()
		return Theme.icon("portal", 18, Color3.fromRGB(150, 110, 255), {
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = Minimap.LAYER.portal + 2,
			Parent = layer,
		})
	end)
	pool("bag", function()
		return Theme.icon("coin", 12, C.gold, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = Minimap.LAYER.poi + 3,
			Parent = layer,
		})
	end)
	pool("gear", function()
		local f = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(6, 6),
			Rotation = 45,
			BorderSizePixel = 0,
			ZIndex = Minimap.LAYER.poi + 3,
			Parent = layer,
		})
		Theme.stroke(C.white, 1).Parent = f
		return f
	end)
	pool("carrier", function()
		local f = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(8, 8),
			BackgroundColor3 = C.gold,
			BorderSizePixel = 0,
			ZIndex = Minimap.LAYER.enemy + 2,
			Parent = layer,
		})
		Theme.round().Parent = f
		Theme.stroke(C.shade, 1.5).Parent = f
		return f
	end)
	pool("bounty", function()
		return Theme.icon("target", 20, C.red, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = Minimap.LAYER.bounty + 2,
			Parent = layer,
		})
	end)

	local function place(kind: string, px: number, py: number): GuiObject
		local p = pools[kind]
		p.used += 1
		local m = p.items[p.used]
		if not m then
			m = p.make()
			p.items[p.used] = m
		end
		m.Position = UDim2.new(0.5, px, 0.5, py)
		m.Visible = true
		return m
	end
	local function beginFrame()
		for _, p in pools do
			p.used = 0
		end
	end
	local function endFrame()
		for _, p in pools do
			for i = p.used + 1, #p.items do
				p.items[i].Visible = false
			end
		end
	end

	------------------------------------------------------------------
	-- World data from Fx
	------------------------------------------------------------------
	local pois: { [number]: { kind: string, x: number, z: number, done: boolean, active: boolean } } = {}
	local bossId: number? = nil
	local bossX, bossZ = 0, 0
	local portal: { x: number, z: number }? = nil
	local bags: { [number]: { x: number, z: number } } = {}
	local groundGear: { [number]: { x: number, z: number, rarity: string } } = {}
	local carriers: { [number]: { x: number, z: number, untilT: number? } } = {}

	table.insert(
		conns,
		Remotes.on(Remotes.S2C.Fx, function(batch)
			if type(batch) ~= "table" then
				return
			end
			for _, ev in batch do
				if type(ev) ~= "table" then
					continue
				end
				local t = ev.t
				if t == "poi" then
					local id = tonumber(ev.id)
					if id then
						pois[id] = {
							kind = tostring(ev.kind),
							x = tonumber(ev.x) or 0,
							z = tonumber(ev.z) or 0,
							done = ev.state == "done",
							active = ev.active == true,
						}
					end
				elseif t == "poiDone" then
					local e = pois[tonumber(ev.id) or -1]
					if e then
						e.done = true
					end
				elseif t == "boss" then
					bossId = tonumber(ev.id)
					bossX, bossZ = tonumber(ev.x) or bossX, tonumber(ev.z) or bossZ
				elseif t == "bag" then
					local id = tonumber(ev.id)
					if id then
						bags[id] = { x = tonumber(ev.x) or 0, z = tonumber(ev.z) or 0 }
					end
				elseif t == "bagGone" then
					bags[tonumber(ev.id) or -1] = nil
				elseif t == "gear" then
					local id = tonumber(ev.id)
					if id then
						local item = if type(ev.item) == "table" then ev.item else {}
						groundGear[id] = {
							x = tonumber(ev.x) or 0,
							z = tonumber(ev.z) or 0,
							rarity = tostring(item.rarity or "Common"),
						}
					end
				elseif t == "gearGone" then
					groundGear[tonumber(ev.id) or -1] = nil
				elseif t == "carrier" then
					local id = tonumber(ev.id)
					if id then
						carriers[id] = { x = tonumber(ev.x) or 0, z = tonumber(ev.z) or 0, untilT = tonumber(ev.untilT) }
					end
				elseif t == "carrierEscape" then
					carriers[tonumber(ev.id) or -1] = nil
				elseif t == "portal" then
					if ev.phase == "close" then
						portal = nil
					else
						portal = { x = tonumber(ev.x) or 0, z = tonumber(ev.z) or 0 }
					end
				end
			end
		end)
	)

	local horde: any = nil
	local function hordeRenderer(): any
		if horde == nil then
			local ok, mod = pcall(require, Client.Controllers.HordeRenderer)
			horde = if ok then mod else false
		end
		return horde or nil
	end

	------------------------------------------------------------------
	-- Hero positions
	------------------------------------------------------------------
	local botModels: { [number]: Model } = {}
	local nextBotScan = 0
	local function scanBots(now: number)
		if now < nextBotScan then
			return
		end
		nextBotScan = now + BOT_SCAN_EVERY
		table.clear(botModels)
		local folder = workspace:FindFirstChild("Bots")
		if folder then
			for _, m in folder:GetChildren() do
				local id = m:GetAttribute("BotId")
				if m:IsA("Model") and type(id) == "number" then
					botModels[id] = m
				end
			end
		end
	end

	local function rootOf(id: number): BasePart?
		local p = Players:GetPlayerByUserId(id)
		if p then
			local char = p.Character
			local r = char and char:FindFirstChild("HumanoidRootPart")
			return if r and r:IsA("BasePart") then r else nil
		end
		return nil
	end

	local function heroPos(id: number): (number?, number?, Instance?)
		local r = rootOf(id)
		if r then
			local pos = r.Position
			return pos.X, pos.Z, r.Parent
		end
		local m = botModels[id]
		if m and m.Parent then
			local ok, cf = pcall(m.GetPivot, m)
			if ok then
				return cf.Position.X, cf.Position.Z, m
			end
		end
		return nil, nil, nil
	end

	------------------------------------------------------------------
	-- World bounty markers (BillboardGui over the hero, pooled)
	------------------------------------------------------------------
	local billboards: { BillboardGui } = {}
	local function billboard(i: number): BillboardGui
		local b = billboards[i]
		if b then
			return b
		end
		local lp = Players.LocalPlayer
		local gui = make("BillboardGui", {
			Name = "TrunkfallBounty",
			AlwaysOnTop = true,
			LightInfluence = 0,
			Size = UDim2.fromOffset(120, 54),
			StudsOffsetWorldSpace = Vector3.new(0, 9, 0),
			MaxDistance = 220,
			ResetOnSpawn = false,
			Enabled = false,
			Parent = lp and lp:FindFirstChildOfClass("PlayerGui"),
		}) :: BillboardGui
		Theme.icon("target", 30, C.red, {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0),
			Parent = gui,
		})
		local label = make("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 1),
			Size = UDim2.fromOffset(120, 20),
			BackgroundTransparency = 1,
			Font = Theme.FONT,
			Text = "BOUNTY +100",
			TextColor3 = C.red,
			TextSize = 16,
			Parent = gui,
		})
		Theme.textStroke(C.white, 1.5).Parent = label
		billboards[i] = gui
		return gui
	end

	------------------------------------------------------------------
	-- Update loop
	------------------------------------------------------------------
	local acc = 0
	local function update(now: number)
		scanBots(now)
		beginFrame()
		local lp = Players.LocalPlayer
		local myRoot = lp and rootOf(lp.UserId)
		local cx, cz = 0, 0
		if myRoot then
			cx, cz = myRoot.Position.X, myRoot.Position.Z
		end
		local range = Minimap.RANGE
		local meId = State.localUserId()
		local match = State.get("match")
		local mine = State.mySquad()
		local bountyCount = 0
		local holders: { [string]: boolean } = {}
		for _, k in State.bountyHolders() do
			holders[k] = true
		end

		local function plotHero(id: number, color: Color3, isMate: boolean)
			local x, z, model = heroPos(id)
			if not x or not z then
				return
			end
			local bounty = holders[tostring(id)] == true
			if not isMate and not Minimap.inSight(x, z, cx, cz) and not bounty then
				return
			end
			local px, py, clamped = Minimap.project(x, z, cx, cz, range, radius)
			if clamped and not isMate and not bounty then
				return
			end
			local m = place(if isMate then "mate" else "enemy", px, py)
			m.BackgroundColor3 = color
			if bounty then
				place("bounty", px, py)
				if model and bountyCount < MAX_BILLBOARDS then
					bountyCount += 1
					local bb = billboard(bountyCount)
					bb.Adornee = if model:IsA("Model")
						then (model :: Model).PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
						else model :: any
					bb.Enabled = true
				end
			end
		end

		if type(match) == "table" and type(match.squads) == "table" then
			for _, s in match.squads do
				local col = Color3.fromRGB(s.color[1], s.color[2], s.color[3])
				local isMate = s.id == mine
				if not s.extracted then
					for _, id in s.members do
						if id ~= meId then
							plotHero(id, col, isMate)
						end
					end
				end
			end
		else
			local party = State.get("party")
			if type(party) == "table" then
				for id in party do
					if id ~= meId then
						plotHero(id, C.cheese, true)
					end
				end
			end
		end
		for i = bountyCount + 1, #billboards do
			billboards[i].Enabled = false
			billboards[i].Adornee = nil
		end

		for _, p in pois do
			if p.active or p.done then
				local px, py, clamped = Minimap.project(p.x, p.z, cx, cz, range, radius)
				if not clamped then
					local m = place("poi", px, py)
					m.BackgroundColor3 = poiColor(p.kind)
					m.BackgroundTransparency = if p.done then 0.65 else 0
				end
			end
		end
		for _, b in bags do
			local px, py, clamped = Minimap.project(b.x, b.z, cx, cz, range, radius)
			if not clamped then
				place("bag", px, py)
			end
		end
		for _, g in groundGear do
			local px, py, clamped = Minimap.project(g.x, g.z, cx, cz, range, radius)
			if not clamped then
				place("gear", px, py).BackgroundColor3 = Theme.rarityColor(g.rarity)
			end
		end
		local hr = hordeRenderer()
		local serverNow = State.serverNow()
		for id, cr in carriers do
			if cr.untilT and serverNow > cr.untilT + 1 then
				carriers[id] = nil
				continue
			end
			local x, z = cr.x, cr.z
			if hr and type(hr.position) == "function" then
				local ok, hx, hz = pcall(hr.position, id)
				if ok and hx and hz then
					x, z = hx, hz
				end
			end
			local px, py, clamped = Minimap.project(x, z, cx, cz, range, radius)
			if not clamped then
				place("carrier", px, py)
			end
		end
		local pt = portal
		if pt then
			local px, py = Minimap.project(pt.x, pt.z, cx, cz, range, radius)
			place("portal", px, py)
		end
		local bid = bossId
		if bid and State.get("boss") ~= nil then
			local h = hordeRenderer()
			local bx, bz = nil, nil
			if h and type(h.position) == "function" then
				local ok, x, z = pcall(h.position, bid)
				if ok then
					bx, bz = x, z
				end
			end
			if bx == nil then
				bx, bz = bossX, bossZ
			end
			local px, py = Minimap.project(bx :: number, bz :: number, cx, cz, range, radius)
			place("boss", px, py)
		end
		endFrame()
	end

	local function reset()
		table.clear(pois)
		table.clear(bags)
		table.clear(groundGear)
		table.clear(carriers)
		bossId = nil
		portal = nil
		for _, b in billboards do
			b.Enabled = false
			b.Adornee = nil
		end
	end

	table.insert(
		conns,
		RunService.RenderStepped:Connect(function(dt)
			local phase = State.phase()
			local show = phase ~= nil and phase ~= "Lobby" and phase ~= "Results"
			holder.Visible = show
			if not show then
				if phase == "Lobby" or phase == nil then
					reset()
				end
				return
			end
			acc += dt
			if acc < UPDATE_EVERY then
				return
			end
			acc = 0
			update(os.clock())
		end)
	)

	return {
		frame = holder,
		destroy = function()
			for _, c in conns do
				c:Disconnect()
			end
			table.clear(conns)
			for _, b in billboards do
				b:Destroy()
			end
			table.clear(billboards)
			holder:Destroy()
		end,
	}
end

return MinimapUI
