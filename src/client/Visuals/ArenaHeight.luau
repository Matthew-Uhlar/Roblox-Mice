--!strict
-- ArenaHeight (iter4, team G, client): ground height of the current arena.
--
--   ArenaHeight.at(x, z) -> number   0 on flat ground; plateau / ramp height
--                                    otherwise (decoded from workspace.Arena's
--                                    "Heights" attribute, cached per arena)
-- The 2-D sim ignores height; this lifts what the client draws for the sim
-- (mice, loot) onto the raised plateaus the server built (server Visuals/Biomes).
-- Mirrors Biomes.heightAt (same encoding and ramp rule).

local ArenaHeight = {}

ArenaHeight.RAMP_LEN = 16

type Plateau = { x: number, z: number, r: number, h: number, rw: number, ramps: { number } }

local cachedFor: Instance? = nil
local cachedStr: string? = nil
local list: { Plateau } = {}

local function decode(str: string): { Plateau }
	local out = {}
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

local checkAt = 0
local function refresh()
	local now = os.clock()
	if now < checkAt then
		return
	end
	checkAt = now + 0.5
	local arena = workspace:FindFirstChild("Arena")
	local str = arena and arena:GetAttribute("Heights")
	if arena ~= cachedFor or str ~= cachedStr then
		cachedFor = arena
		cachedStr = if type(str) == "string" then str else nil
		list = if cachedStr then decode(cachedStr) else {}
	end
end

function ArenaHeight.at(x: number, z: number): number
	refresh()
	if #list == 0 then
		return 0
	end
	local best = 0
	for _, p in list do
		local dx, dz = x - p.x, z - p.z
		local d2 = dx * dx + dz * dz
		local outer = p.r + ArenaHeight.RAMP_LEN
		if d2 <= outer * outer then
			local d = math.sqrt(d2)
			if d <= p.r then
				best = math.max(best, p.h)
			else
				local a = math.atan2(dz, dx)
				for _, ra in p.ramps do
					local da = math.abs((a - ra + math.pi) % (2 * math.pi) - math.pi)
					if da * p.r <= p.rw / 2 then
						best = math.max(best, p.h * (1 - (d - p.r) / ArenaHeight.RAMP_LEN))
					end
				end
			end
		end
	end
	return best
end

function ArenaHeight.hasAny(): boolean
	refresh()
	return #list > 0
end

return ArenaHeight
