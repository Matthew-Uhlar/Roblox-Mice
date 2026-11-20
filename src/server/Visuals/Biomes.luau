--!strict
-- Biomes (iter4, team G): real terrain complexity for the bigger maps
-- (docs/iter/4/PLAN.md "Bigger, richer maps").
--
--   Biomes.build(ctx) -> { heights = {Plateau}, bridges = {{x, z, a}}, colliders = n }
--     ctx = { model, themeId, R, rng, th (ArenaBuilder theme), clear(x, z, r) -> bool,
--             addObstacle(x, z, r) }   (ArenaBuilder supplies them)
--   Biomes.LAYOUTS[themeId]   per-map biome recipe
--   Biomes.heightAt(plateaus, x, z) -> number     pure: ground height (plateaus +
--                                                  ramps), also used by the client
--   Biomes.encode(plateaus) / Biomes.decode(str)  the arena attribute "Heights"
--
-- Features (terrain is free in the part budget; gameplay blocking is done with
-- the 2-D sim's own obstacle circles, so the server sim and the world agree):
--   * DEEP RIVERS (water / lava / murk) cross the map rim to rim; impassable
--     except at BRIDGES (2-3 walkable crossings = chokepoints). Each blocked
--     stretch is a chain of invisible collider cylinders registered as sim
--     obstacles; bridges are part-built (deck, rails, posts).
--   * RIDGES: cliff walls 6-12 studs high, impassable, also collider chains;
--     cover lanes for PvP and for kiting the horde.
--   * PLATEAUS: raised mesas (3.5 studs) with 1-2 ramps, walkable by heroes;
--     the sim ignores height, so the client draws mice / loot on top with
--     Biomes.heightAt (attribute "Heights" on workspace.Arena) and the server
--     can place bots with ArenaBuilder.heightAt.
--   * Forests and ruins stay with Regions (obstacles there are already cover).
-- Part cost: bridges ~12 parts each; colliders 1 part per ~8 studs of wall.

local Build = require(script.Parent.Build)
local Terra = require(script.Parent.Terra)

local Biomes = {}

local M = Enum.Material
local V3 = Vector3.new
local CF = CFrame.new
local rgb = Color3.fromRGB

export type Plateau = { x: number, z: number, r: number, h: number, ramps: { number }, rw: number }

type Layout = {
	river: string?, -- "water" | "lava" | "murk" | nil
	bridges: number,
	ridges: number,
	plateaus: number,
	ridgeMat: Enum.Material?,
	topMat: Enum.Material?,
}

Biomes.LAYOUTS = {
	plains = { river = "water", bridges = 3, ridges = 2, plateaus = 2 },
	forest = { river = "water", bridges = 3, ridges = 1, plateaus = 2 },
	jungle = { river = "water", bridges = 2, ridges = 2, plateaus = 1 },
	beach = { river = nil, bridges = 0, ridges = 2, plateaus = 3, ridgeMat = M.Sandstone, topMat = M.Sand },
	tundra = { river = "water", bridges = 2, ridges = 3, plateaus = 2, ridgeMat = M.Glacier, topMat = M.Snow },
	volcano = {
		river = "lava",
		bridges = 2,
		ridges = 3,
		plateaus = 1,
		ridgeMat = M.Basalt,
		topMat = M.CrackedLava,
	},
	swamp = { river = "murk", bridges = 3, ridges = 1, plateaus = 2 },
	moon = { river = nil, bridges = 0, ridges = 3, plateaus = 3, ridgeMat = M.Slate, topMat = M.Rock },
	ocean = { river = "water", bridges = 3, ridges = 2, plateaus = 2 },
} :: { [string]: Layout }

Biomes.RIVER_WIDTH = 12
Biomes.COLLIDER_STEP = 7
Biomes.PLATEAU_H = 3.5
Biomes.RAMP_LEN = 16

-- Pure height lookup (plateau top inside r; ramps fall linearly outside).
function Biomes.heightAt(list: { Plateau }?, x: number, z: number): number
	if not list then
		return 0
	end
	local best = 0
	for _, p in list do
		local dx, dz = x - p.x, z - p.z
		local d = math.sqrt(dx * dx + dz * dz)
		if d <= p.r then
			best = math.max(best, p.h)
		elseif d <= p.r + Biomes.RAMP_LEN then
			local a = math.atan2(dz, dx)
			for _, ra in p.ramps do
				local da = math.abs((a - ra + math.pi) % (2 * math.pi) - math.pi)
				-- inside the ramp's width (measured at the rim)
				if da * p.r <= p.rw / 2 then
					local f = 1 - (d - p.r) / Biomes.RAMP_LEN
					best = math.max(best, p.h * f)
				end
			end
		end
	end
	return best
end

function Biomes.encode(list: { Plateau }): string
	local parts = {}
	for _, p in list do
		local ramps = {}
		for _, a in p.ramps do
			table.insert(ramps, string.format("%.3f", a))
		end
		table.insert(
			parts,
			string.format("%.1f,%.1f,%.1f,%.2f,%.1f,%s", p.x, p.z, p.r, p.h, p.rw, table.concat(ramps, ":"))
		)
	end
	return table.concat(parts, ";")
end

function Biomes.decode(str: any): { Plateau }
	local out = {}
	if type(str) ~= "string" then
		return out
	end
	for item in string.gmatch(str, "[^;]+") do
		local f = string.split(item, ",")
		local x, z, r, h, rw = tonumber(f[1]), tonumber(f[2]), tonumber(f[3]), tonumber(f[4]), tonumber(f[5])
		if x and z and r and h and rw then
			local ramps = {}
			for a in string.gmatch(f[6] or "", "[^:]+") do
				local n = tonumber(a)
				if n then
					table.insert(ramps, n)
				end
			end
			table.insert(out, { x = x, z = z, r = r, h = h, rw = rw, ramps = ramps })
		end
	end
	return out
end

local function collider(parent: Instance, x: number, z: number, r: number, h: number)
	local c = Build.ucyl(parent, h, r * 2, CF(x, h / 2, z), Color3.new(1, 1, 1), M.SmoothPlastic, {
		name = "Collider",
		collide = true,
		transparency = 1,
		shadow = false,
	})
	c:SetAttribute("Collider", true)
end

-- A meandering line across the map (rim to rim, missing the centre).
local function crossLine(R: number, rng: any): { Vector3 }
	local a = rng:range(0, math.pi * 2)
	local off = rng:range(0.25, 0.4) * R * (if rng:nextFloat() < 0.5 then 1 else -1)
	local dir = V3(math.cos(a), 0, math.sin(a))
	local side = V3(-dir.Z, 0, dir.X)
	local pts = {}
	local n = math.floor(2 * R / 10)
	local ph = rng:range(0, 6.28)
	for i = 0, n do
		local t = i / n * 2 - 1
		local p = dir * (t * R) + side * (off + math.sin(t * 3.1 + ph) * R * 0.08)
		if p.Magnitude <= R + 30 then
			table.insert(pts, p)
		end
	end
	return pts
end

local function bridge(parent: Instance, at: Vector3, along: Vector3, width: number, th: any)
	local m = Instance.new("Model")
	m.Name = "Bridge"
	m.Parent = parent
	local look = CFrame.lookAt(at, at + along)
	local wood = rgb(130, 90, 55)
	local len = width + 8
	-- deck planks (visual; the walkable surface is the terrain under them)
	for k = 0, 3 do
		Build.block(
			m,
			V3(7, 0.4, len / 4 - 0.15),
			look * CF(0, 0.35, (k - 1.5) * len / 4),
			wood:Lerp(rgb(90, 60, 35), (k % 2) * 0.3),
			M.WoodPlanks,
			{ shadow = false }
		)
	end
	for _, s in { -1, 1 } do
		Build.block(m, V3(0.35, 0.35, len), look * CF(s * 3.6, 1.6, 0), wood, M.Wood)
		for _, e in { -1, 1 } do
			Build.ucyl(
				m,
				2.2,
				0.55,
				look * CF(s * 3.6, 1.1, e * len / 2),
				(th and th.pal and th.pal.rockDark) or rgb(110, 105, 100),
				M.Slate
			)
		end
	end
	return m
end

function Biomes.build(ctx: any): any
	local layout: Layout = Biomes.LAYOUTS[ctx.themeId] or Biomes.LAYOUTS.plains
	local R: number = ctx.R
	local rng = ctx.rng
	local th = ctx.th
	local folder = Instance.new("Folder")
	folder.Name = "Biome"
	folder.Parent = ctx.model
	local out = { heights = {} :: { Plateau }, bridges = {}, colliders = 0 }
	local blocked: { { x: number, z: number, r: number } } = {}

	-- deep river with bridges
	if layout.river then
		local pts = crossLine(R, rng)
		local w = Biomes.RIVER_WIDTH
		local nB = layout.bridges
		local bridgeIdx: { [number]: boolean } = {}
		for b = 1, nB do
			local i = math.floor(#pts * (b / (nB + 1)) + rng:range(-2, 2))
			bridgeIdx[i] = true
		end
		local liquid = if layout.river == "lava" then M.CrackedLava else M.Water
		local bed = if layout.river == "murk" then M.Mud else (th and th.sub) or M.Rock
		for i, p in pts do
			local inside = p.Magnitude < R - 6
			local clear = ctx.clear(p.X, p.Z, w / 2 + 2)
			if bridgeIdx[i] then
				continue -- the bridge sections keep their ground: the crossing
			end
			if clear and inside then
				table.insert(blocked, { x = p.X, z = p.Z, r = w / 2 })
			end
		end
		-- banks first (every point), then carve the channel, its bed and the liquid
		-- 2 studs below the floor (a second pass, so no bank refills a channel)
		for _, b in blocked do
			Terra.paint(b.x, b.z, w / 2 + 3, M.Mud)
		end
		for _, b in blocked do
			Terra.cylinder(CF(b.x, -1.5, b.z), 5, w / 2 + 1, M.Air)
			Terra.cylinder(CF(b.x, -4.5, b.z), 2, w / 2 + 1, bed)
			Terra.cylinder(CF(b.x, -2.6, b.z), 1.4, w / 2, if layout.river == "murk" then M.Water else liquid)
		end
		-- bridges: one per bridge run, across the channel
		local runs = {}
		local i = 1
		while i <= #pts do
			if bridgeIdx[i] then
				local s = i
				while bridgeIdx[i + 1] do
					i += 1
				end
				table.insert(runs, { s, i })
			end
			i += 1
		end
		for _, run in runs do
			local mid = math.floor((run[1] + run[2]) / 2)
			local p = pts[mid]
			if p and p.Magnitude < R - 10 then
				local nxt = pts[math.min(#pts, mid + 1)] - pts[math.max(1, mid - 1)]
				bridge(folder, p, V3(-nxt.Z, 0, nxt.X).Unit, w, th) -- the deck spans the river
				table.insert(out.bridges, { x = p.X, z = p.Z, a = math.atan2(nxt.Z, nxt.X) })
			end
		end
		-- colliders along the channel, one per COLLIDER_STEP
		local lastX, lastZ = math.huge, math.huge
		for _, b in blocked do
			if (b.x - lastX) ^ 2 + (b.z - lastZ) ^ 2 >= Biomes.COLLIDER_STEP ^ 2 then
				collider(folder, b.x, b.z, b.r, 6)
				ctx.addObstacle(b.x, b.z, b.r)
				out.colliders += 1
				lastX, lastZ = b.x, b.z
			end
		end
	end

	-- ridges: cliff walls (impassable)
	local ridgeMat = layout.ridgeMat or (th and th.cliff) or M.Rock
	local topMat = layout.topMat or (th and th.cliffTop) or M.Grass
	for _ = 1, layout.ridges do
		for _try = 1, 20 do
			local a = rng:range(0, math.pi * 2)
			local d = rng:range(0.3, 0.75) * R
			local c = V3(math.cos(a) * d, 0, math.sin(a) * d)
			local len = rng:range(40, 80)
			local dir = V3(-math.sin(a), 0, math.cos(a)) -- tangential: walls you walk round
			dir = (dir + V3(rng:range(-0.4, 0.4), 0, rng:range(-0.4, 0.4))).Unit
			local ok = true
			local n = math.floor(len / Biomes.COLLIDER_STEP)
			for k = 0, n do
				local p = c + dir * (k / n - 0.5) * len
				if not ctx.clear(p.X, p.Z, 7) or p.Magnitude > R - 15 then
					ok = false
					break
				end
			end
			if ok then
				for k = 0, n do
					local p = c + dir * (k / n - 0.5) * len
					local h = rng:range(6, 12) * (1 - math.abs(k / n - 0.5) * 0.8)
					local r = rng:range(4, 5.5)
					Terra.ball(V3(p.X, h * 0.35, p.Z), r + 1, ridgeMat)
					Terra.cylinder(CF(p.X, h / 2, p.Z), h, r, ridgeMat)
					Terra.cylinder(CF(p.X, h - 0.5, p.Z), 1.2, r - 0.6, topMat)
					collider(folder, p.X, p.Z, r, h + 2)
					ctx.addObstacle(p.X, p.Z, r)
					out.colliders += 1
				end
				break
			end
		end
	end

	-- plateaus with ramps (walkable; heights for the client / bots)
	for _ = 1, layout.plateaus do
		for _try = 1, 25 do
			local a = rng:range(0, math.pi * 2)
			local d = rng:range(0.25, 0.7) * R
			local x, z = math.cos(a) * d, math.sin(a) * d
			local r = rng:range(18, 30)
			if ctx.clear(x, z, r + Biomes.RAMP_LEN) and d + r + Biomes.RAMP_LEN < R - 10 then
				local h = Biomes.PLATEAU_H
				local mat = topMat
				Terra.cylinder(CF(x, h / 2 - 0.5, z), h + 1, r, ridgeMat)
				Terra.cylinder(CF(x, h - 0.75, z), 1.5, r - 0.5, mat)
				local ramps = {}
				local nr = if rng:nextFloat() < 0.6 then 2 else 1
				local ra0 = rng:range(0, math.pi * 2)
				local rw = 12
				for k = 1, nr do
					local ra = ra0 + (k - 1) * math.pi * rng:range(0.7, 1.3)
					table.insert(ramps, ra)
					local dir = V3(math.cos(ra), 0, math.sin(ra))
					local mid = V3(x, 0, z) + dir * (r + Biomes.RAMP_LEN / 2 - 1)
					-- terrain wedge: the slope faces outward (FillWedge: slope on the cf's -Z / look side)
					Terra.wedge(
						CFrame.lookAt(mid + V3(0, h / 2 - 0.25, 0), mid + V3(0, h / 2 - 0.25, 0) + dir),
						V3(rw, h + 0.5, Biomes.RAMP_LEN + 2),
						mat
					)
				end
				table.insert(out.heights, { x = x, z = z, r = r, h = h, rw = rw, ramps = ramps })
				-- a cliff lip of boulders round the rim between the ramps
				for k = 0, 9 do
					local ka = k / 10 * math.pi * 2
					local onRamp = false
					for _, ra in ramps do
						if math.abs((ka - ra + math.pi) % (2 * math.pi) - math.pi) * r < rw * 0.75 then
							onRamp = true
						end
					end
					if not onRamp then
						Terra.ball(V3(x + math.cos(ka) * r, h * 0.6, z + math.sin(ka) * r), 2.2, ridgeMat)
					end
				end
				break
			end
		end
	end
	return out
end

return Biomes
