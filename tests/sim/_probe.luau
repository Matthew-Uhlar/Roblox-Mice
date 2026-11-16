local H = require("./Headless")
local Classes = require("../../src/shared/Config/Classes")
local process = require("@lune/process")
local seeds = { 3, 14, 15, 92, 65, 35 }
local n = tonumber(process.args[1]) or #seeds
for i = 1, n do
	local seed = seeds[(i - 1) % #seeds + 1] + (if i > #seeds then 1000 else 0)
	local sim = H.new({ seed = seed, humans = { { classId = Classes.ORDER[(i - 1) % #Classes.ORDER + 1] } } })
	local t0 = os.clock()
	local r = sim:playRun()
	print(
		string.format(
			"seed %d outcome %s stages %d (%.1f s cpu)",
			seed,
			r.outcome,
			#r.stages,
			os.clock() - t0
		)
	)
	for _, st in r.stages do
		local times = {}
		for _, t in st.champTimes do
			table.insert(times, string.format("%.0f", t))
		end
		local by = {}
		for q, c in st.champBySquad do
			table.insert(by, q .. "=" .. c)
		end
		print(H.formatStage(st))
		print(
			string.format(
				"     champs spawned %d killed %d lair %d/%d  first kill %s  times [%s]  by [%s]  peak %d",
				st.champSpawned,
				st.champKilled,
				st.lairKilled,
				st.lairSpawned,
				tostring(st.firstChampKillAt and math.floor(st.firstChampKillAt)),
				table.concat(times, ","),
				table.concat(by, " "),
				st.enemyPeak
			)
		)
	end
end
