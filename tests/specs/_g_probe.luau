-- usage: lune run probe.luau <repoRoot> [radiusScale]
local process = require("@lune/process")
local root = process.args[1]
local scale = tonumber(process.args[2]) or 0
local Runtime = require("../runtime/Runtime")
local rt = Runtime.new({ root = root, dt = 1 / 30 })
rt:startServer()
rt:advance(2)
local ArenaBuilder = rt:serverModule("ServerScriptService.Server.Services.ArenaBuilder")
local Maps = rt:serverModule("ReplicatedStorage.Shared.Config.Maps")
local Pois = rt:serverModule("ReplicatedStorage.Shared.Combat.Pois")
local Rng = rt:serverModule("ReplicatedStorage.Shared.Util.Rng")
local clock = os.clock()
for i, id in Maps.ORDER do
	local t0 = os.clock()
	local info = rt:asServer(function()
		local def = Maps.get(id)
		local R = if scale > 0 then math.clamp(480 * def.size / 350 * scale, 300, 760) else nil
		local layout = Pois.layout(Rng.new(i):fork(0x9017), id, Pois.arenaRadius(id))
		local inf = ArenaBuilder.build(id, i, { pois = layout, radius = R })
		ArenaBuilder.buildPortal(0, 0)
		return inf
	end)
	local per = {}
	local total, lights = 0, 0
	rt:runIn(nil, function()
		for _, c in info.model:GetChildren() do
			local n = 0
			for _, d in c:GetDescendants() do
				if d:IsA("BasePart") then n += 1 end
				if d:IsA("PointLight") then lights += 1 end
			end
			if c:IsA("BasePart") then n += 1 end
			per[c.Name] = (per[c.Name] or 0) + n
			total += n
		end
	end)
	local keys = {}
	for k, v in per do
		if v > 20 then table.insert(keys, k .. "=" .. v) end
	end
	table.sort(keys)
	print(string.format("%-8s R=%d total=%d lights=%d obst=%d bridges=%d plateaus=%d %.1fs  %s", id, info.radius, total, lights, #info.obstacles, info.biome and #info.biome.bridges or -1, info.biome and #info.biome.heights or -1, os.clock() - t0, table.concat(keys, " ")))
end
print("warnings:", #rt.S.warnings)
for i, w in rt.S.warnings do if i <= 5 then print("  ", w.message) end end
