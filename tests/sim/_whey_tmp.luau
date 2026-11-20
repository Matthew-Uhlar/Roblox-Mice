local H = require("./Headless")
local Shop = require("../../src/shared/Config/RunShop")
local rows = {}
for i = 1, 12 do
	local sim = H.new({ seed = 9000 + i * 17, humans = { { classId = "elephante" } } })
	local r = sim:playRun()
	local st = #r.stages
	table.insert(rows, string.format("seed %d stages %d whey %d rinds %d  buffs/stage %.2f  altar(%d+%d)=%s",
		i, st, r.wheyEarned or 0, r.rindsEarned or 0, (r.wheyEarned or 0) / Shop.BUFF_COST / math.max(1, st),
		Shop.ULTIMATE_COST.rinds, Shop.ULTIMATE_COST.whey, tostring((r.wheyEarned or 0) >= Shop.ULTIMATE_COST.whey and (r.rindsEarned or 0) >= Shop.ULTIMATE_COST.rinds)))
end
print(table.concat(rows, "\n"))
