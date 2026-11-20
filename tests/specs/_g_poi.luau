local Runtime = require("../runtime/Runtime")
local rt = Runtime.new({ root = ".", dt = 1 / 30 })
rt:startServer()
rt:advance(1)
local Maps = rt:serverModule("ReplicatedStorage.Shared.Config.Maps")
local Pois = rt:serverModule("ReplicatedStorage.Shared.Combat.Pois")
local Rng = rt:serverModule("ReplicatedStorage.Shared.Util.Rng")
rt:asServer(function()
	for i, id in Maps.ORDER do
		local layout = Pois.layout(Rng.new(i):fork(0x9017), id, Pois.arenaRadius(id))
		local kinds = {}
		for _, e in layout do kinds[e.kind] = (kinds[e.kind] or 0) + 1 end
		local s = {}
		for k, v in kinds do table.insert(s, k .. "=" .. v) end
		table.sort(s)
		print(id, #layout, Pois.arenaRadius(id), table.concat(s, " "))
	end
end)
