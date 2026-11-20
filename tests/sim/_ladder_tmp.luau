local H = require("./Headless")
local RunShop = require("../../src/shared/Config/RunShop")
local Leveling = require("../../src/shared/Run/Leveling")
local Classes = require("../../src/shared/Config/Classes")
local process = require("@lune/process")
local stepK = tonumber(process.args[1]) or 1
local valK = tonumber(process.args[2]) or 1
local lvlK = tonumber(process.args[3]) or 1
local tier = tonumber(process.args[4]) or 2
Leveling.HP_PER_LEVEL *= lvlK
Leveling.DAMAGE_PER_LEVEL *= lvlK
local ranks = {}
for id, d in RunShop.RANKS do
	local n = table.clone(d) :: any
	n.step = d.step * stepK
	if d.add then n.add = {} for k, v in d.add do n.add[k] = v * valK end end
	if d.pct then n.pct = {} for k, v in d.pct do n.pct[k] = v * valK end end
	ranks[id] = n
end
RunShop.RANKS = ranks
local clears = 0
for i = 1, 12 do
	local class = Classes.ORDER[(i - 1) % #Classes.ORDER + 1]
	local sim = H.new({ seed = 7100 + i * 31, humans = { { classId = class } }, difficulty = tier })
	local r = sim:playRun()
	local po = r.payout
	if po and (po.fullClear or po.lastHerd) then clears += 1 end
end
print(string.format("step x%.2f val x%.2f lvl x%.2f tier %d: clears %d/12", stepK, valK, lvlK, tier, clears))
