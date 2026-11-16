--!nocheck
local Runtime = require("../tests/runtime/Runtime")
local process = require("@lune/process")
local rt = Runtime.new({ root = "." })
local only = process.args[1]
rt:asServer(function()
	local ArenaBuilder = rt:serverModule("ServerScriptService.Server.Services.ArenaBuilder")
	local Maps = rt:serverModule("ReplicatedStorage.Shared.Config.Maps")
	local Pois = rt:serverModule("ReplicatedStorage.Shared.Combat.Pois")
	local Rng = rt:serverModule("ReplicatedStorage.Shared.Util.Rng")
	for _, mapId in Maps.ORDER do
		if only and only ~= mapId then continue end
		local t0 = os.clock()
		local layout = Pois.layout(Rng.new(1234):fork(7), mapId, Pois.arenaRadius(mapId))
		local arena = ArenaBuilder.build(mapId, 1234, { pois = layout })
		local dt = os.clock() - t0
		local total, lights = 0, 0
		local per = {}
		for _, c in arena.model:GetChildren() do
			local n = if c:IsA("BasePart") then 1 else 0
			for _, d in c:GetDescendants() do
				if d:IsA("BasePart") then n += 1 elseif d:IsA("PointLight") then lights += 1 end
			end
			per[c.Name] = (per[c.Name] or 0) + n
			total += n
		end
		local parts = {}
		for k, v in per do table.insert(parts, k .. "=" .. v) end
		table.sort(parts)
		print(string.format("%-8s R=%d total=%d lights=%d obstacles=%d pois=%d build=%.2fs | %s", mapId, arena.radius, total, lights, #arena.obstacles, #arena.pois, dt, table.concat(parts, " ")))
		ArenaBuilder.clear()
	end
end)
