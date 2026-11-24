local H = require("../sim/Headless")
local Classes = require("../../src/shared/Config/Classes")
local Difficulty = require("../../src/shared/Run/Difficulty")
local process = require("@lune/process")
if process.args[1] == "without" then
	table.remove(Classes.ORDER, table.find(Classes.ORDER, "tinkerphant"))
end
for _, tier in { Difficulty.MEDIUM, Difficulty.MAX } do
	local c = 0
	for i = 1, 12 do
		local class = Classes.ORDER[(i - 1) % #Classes.ORDER + 1]
		local r = H.new({ seed = 7100 + i * 31, humans = { { classId = class } }, difficulty = tier }):playRun()
		if r.payout and (r.payout.fullClear or r.payout.lastHerd) then c += 1 end
	end
	print(process.args[1], tier, c)
end
