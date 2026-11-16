local H = require("./Headless")
local Classes = require("../../src/shared/Config/Classes")
local process = require("@lune/process")
local n = tonumber(process.args[1]) or 6
local rows = {}
for i = 1, n do
	local seed = 500 + i * 7
	local sim = H.new({ seed = seed, humans = { { classId = Classes.ORDER[(i - 1) % #Classes.ORDER + 1] } } })
	local r = sim:playRun()
	for _, st in r.stages do
		for _, k in st.champLog do
			table.insert(
				rows,
				{ stage = st.stage, at = k.at, fight = k.fight, hp = k.hp, lair = k.lair, id = k.champId }
			)
		end
	end
end
table.sort(rows, function(a, b)
	return a.stage * 1000 + a.at < b.stage * 1000 + b.at
end)
for _, k in rows do
	print(
		string.format(
			"st%d at %5.0f %-14s %s hp %6.0f fight %5.1f dps %6.0f",
			k.stage,
			k.at,
			k.id,
			k.lair and "L" or " ",
			k.hp,
			k.fight,
			k.hp / math.max(0.5, k.fight)
		)
	)
end
