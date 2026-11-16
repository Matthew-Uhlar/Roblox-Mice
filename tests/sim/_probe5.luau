local H = require("./Headless")
local Classes = require("../../src/shared/Config/Classes")
local process = require("@lune/process")
local SEEDS = { 3, 14, 15, 92, 65, 35, 89, 79, 32, 38, 46, 26, 43, 138, 27, 95, 2, 88, 41, 97, 16, 93, 99, 37 }
local pick = {}
for _, a in process.args do pick[tonumber(a)] = true end
for i, seed in SEEDS do
	if next(pick) and not pick[seed] then continue end
	local sim = H.new({ seed = seed, humans = { { classId = Classes.ORDER[(i - 1) % #Classes.ORDER + 1] } } })
	-- count downs of the human squad by cause
	local hs = sim.human.squad
	local pve, pvp = 0, 0
	local origHandle = sim._handleEvents
	local r = sim:playRun()
	print(string.format("seed %d %s stages %d humanSquad %d", seed, r.outcome, #r.stages, hs))
	for _, st in r.stages do
		print(H.formatStage(st))
		local by = {}
		for q, c in st.champBySquad do table.insert(by, q .. "=" .. c) end
		print(string.format("     champs %d/%d lair %d/%d by [%s] peak %d", st.champKilled, st.champSpawned, st.lairKilled, st.lairSpawned, table.concat(by, " "), st.enemyPeak))
	end
end
