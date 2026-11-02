--!strict
-- Run/EpicDrop: epic boss drops pick an unowned epic cosmetic, else a reroll token.
local T = require("../lib/Test")
local Rng = require("../../src/shared/Util/Rng")
local EpicDrop = require("../../src/shared/Run/EpicDrop")
local Cosmetics = require("../../src/shared/Config/Cosmetics")

T.describe("EpicDrop", function()
	local pool = { "c_hat", "a_trail", "b_tint" }
	T.it("never picks an owned cosmetic", function()
		for seed = 1, 50 do
			local id = EpicDrop.pick(pool, { a_trail = true, c_hat = true }, Rng.new(seed))
			T.eq(id, "b_tint")
		end
	end)
	T.it("covers every unowned cosmetic and is deterministic per seed", function()
		local seen = {}
		for seed = 1, 60 do
			local id = EpicDrop.pick(pool, {}, Rng.new(seed)) :: string
			seen[id] = true
			T.eq(EpicDrop.pick(pool, {}, Rng.new(seed)), id)
		end
		T.truthy(seen.a_trail and seen.b_tint and seen.c_hat)
	end)
	T.it("does not depend on the pool order", function()
		for seed = 1, 20 do
			T.eq(
				EpicDrop.pick({ "b_tint", "c_hat", "a_trail" }, {}, Rng.new(seed)),
				EpicDrop.pick(pool, {}, Rng.new(seed))
			)
		end
	end)
	T.it("owning everything gives a reroll token instead", function()
		local drop = EpicDrop.roll(pool, { a_trail = true, b_tint = true, c_hat = true }, Rng.new(1))
		T.eq(drop.kind, "reroll")
		T.eq(EpicDrop.pick({}, nil, Rng.new(1)), nil)
		local d2 = EpicDrop.roll(pool, nil, Rng.new(1)) :: any
		T.eq(d2.kind, "cosmetic")
	end)
	T.it("the real epic pool is non-empty and made of known cosmetics", function()
		local real = Cosmetics.epicPool()
		T.truthy(#real > 0, "Cosmetics.epicPool() is empty")
		for _, id in real do
			T.truthy(Cosmetics.get(id) ~= nil, id)
		end
	end)
end)

return T.finish()
