local H = require("../sim/Headless")
local Classes = require("../../src/shared/Config/Classes")
local Difficulty = require("../../src/shared/Run/Difficulty")
local process = require("@lune/process")
local Weapons = require("../../src/shared/Combat/Weapons")
local World = require("../../src/shared/Combat/World")
if process.args[2] then
	for _, k in string.split(process.args[2], ",") do
		if k == "mice" then
			World.BUILD_MICE_MULT = 0 -- no effect placeholder
		else
			Weapons.ABILITY[k] = function() end
		end
	end
end
if process.args[1] == "without" then
	table.remove(Classes.ORDER, table.find(Classes.ORDER, "tinkerphant"))
end
for _, tier in { Difficulty.MEDIUM } do
	local c = 0
	for i = 1, 12 do
		local class = Classes.ORDER[(i - 1) % #Classes.ORDER + 1]
		local r = H.new({ seed = 7100 + i * 31, humans = { { classId = class } }, difficulty = tier }):playRun()
		local ok = r.payout and (r.payout.fullClear or r.payout.lastHerd)
		if ok then c += 1 end
		if tier == Difficulty.MAX and ok then print("clear", i, class, r.payout.fullClear, r.payout.lastHerd) end
	end
	print(process.args[1], tier, c)
end
