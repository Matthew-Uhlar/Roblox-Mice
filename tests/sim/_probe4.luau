local H = require("./Headless")
local Classes = require("../../src/shared/Config/Classes")
local SEEDS = { 3, 14, 15, 92, 65, 35, 89, 79, 32, 38, 46, 26 }
local src = {}
local function total(m)
	local t = 0
	for s = 1, 4 do t += m:squadPending(s) end
	return t
end
local function wrap(name, key)
	local orig = (H :: any)[name]
	if not orig then return end
	(H :: any)[name] = function(self, e, ...)
		local before = total(self.match)
		local r = orig(self, e, ...)
		local k = key or (name .. ":" .. tostring(e and e.kind))
		src[k] = (src[k] or 0) + (total(self.match) - before)
		return r
	end
end
wrap("_poiReward")
wrap("_championDead", "champion")
local stagesN = 0
for i, seed in SEEDS do
	local sim = H.new({ seed = seed, humans = { { classId = Classes.ORDER[(i - 1) % #Classes.ORDER + 1] } } })
	local origBD = sim.match.bossDefeated
	sim.match.bossDefeated = function(m, ...)
		local before = total(m)
		local r = origBD(m, ...)
		src.bossDefeated = (src.bossDefeated or 0) + (total(m) - before)
		stagesN += 1
		return r
	end
	sim:playRun()
end
for k, v in src do
	print(string.format("%-30s %8.0f  per stage %6.0f", k, v, v / math.max(1, stagesN)))
end
