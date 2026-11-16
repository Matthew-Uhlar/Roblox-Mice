local H = require("./Headless")
local Classes = require("../../src/shared/Config/Classes")
local process = require("@lune/process")
local SEEDS = { 3, 14, 15, 92, 65, 35, 89, 79, 32, 38, 46, 26 }
local pots = { {}, {}, {}, {} }
for i, seed in SEEDS do
	local sim
	sim = H.new({
		seed = seed,
		humans = { { classId = Classes.ORDER[(i - 1) % #Classes.ORDER + 1] } },
		extractPolicy = function(squad, s)
			table.insert(pots[s.match.stage], s:_memberPot(squad))
			return nil
		end,
	})
	sim:playRun()
end
for st = 1, 4 do
	table.sort(pots[st])
	local l = pots[st]
	print(
		string.format(
			"stage %d gate: n %d  median pot %s  p75 %s",
			st,
			#l,
			tostring(l[math.max(1, math.ceil(#l / 2))]),
			tostring(l[math.max(1, math.ceil(#l * 3 / 4))])
		)
	)
end
