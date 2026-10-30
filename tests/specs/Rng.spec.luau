local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")

T.describe("Rng", function()
	T.it("is deterministic for a seed", function()
		local a, b = Rng.new(42), Rng.new(42)
		for _ = 1, 100 do
			T.eq(a:nextU32(), b:nextU32())
		end
	end)
	T.it("nextFloat stays in [0,1)", function()
		local r = Rng.new(7)
		for _ = 1, 5000 do
			local f = r:nextFloat()
			T.truthy(f >= 0 and f < 1)
		end
	end)
	T.it("nextInt covers the inclusive range roughly uniformly", function()
		local r = Rng.new(99)
		local counts = { 0, 0, 0, 0 }
		for _ = 1, 8000 do
			local i = r:nextInt(1, 4)
			counts[i] += 1
		end
		for i = 1, 4 do
			T.truthy(counts[i] > 1700 and counts[i] < 2300, "bucket " .. i .. " = " .. counts[i])
		end
	end)
	T.it("shuffle keeps every element", function()
		local r = Rng.new(1)
		local list = r:shuffle({ 1, 2, 3, 4, 5, 6 })
		table.sort(list)
		T.deepEq(list, { 1, 2, 3, 4, 5, 6 })
	end)
	T.it("weightedIndex never picks zero weights", function()
		local r = Rng.new(3)
		for _ = 1, 2000 do
			T.truthy(r:weightedIndex({ 0, 5, 0, 1 }) ~= 1)
		end
	end)
	T.it("fork is reproducible", function()
		T.eq(Rng.new(5):fork(10):nextU32(), Rng.new(5):fork(10):nextU32())
	end)
end)

return T.finish()
