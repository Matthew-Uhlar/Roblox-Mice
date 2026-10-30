--!strict
-- Deterministic xorshift32 RNG. Pure Luau (bit32 only) so runs replay the same
-- in Studio and in Lune tests. Use one Rng per concern (route rolls, spawns,
-- loot) via :fork(salt) so adding a roll in one system doesn't shift another.

local Rng = {}
Rng.__index = Rng

export type Rng = typeof(setmetatable({} :: { state: number }, Rng))

local function mix(seed: number): number
	-- Scramble the seed so nearby seeds diverge quickly; never return 0.
	local s = bit32.band(math.floor(seed) % 4294967296, 0xFFFFFFFF)
	s = bit32.bxor(s, 0x9E3779B9)
	s = bit32.bxor(s, bit32.lshift(s, 13))
	s = bit32.bxor(s, bit32.rshift(s, 17))
	s = bit32.bxor(s, bit32.lshift(s, 5))
	if s == 0 then
		s = 0x6D2B79F5
	end
	return s
end

function Rng.new(seed: number?): Rng
	return setmetatable({ state = mix(seed or os.time()) }, Rng)
end

function Rng.nextU32(self: Rng): number
	local s = self.state
	s = bit32.bxor(s, bit32.lshift(s, 13))
	s = bit32.bxor(s, bit32.rshift(s, 17))
	s = bit32.bxor(s, bit32.lshift(s, 5))
	self.state = s
	return s
end

-- Float in [0, 1).
function Rng.nextFloat(self: Rng): number
	return self:nextU32() / 4294967296
end

-- Float in [lo, hi).
function Rng.range(self: Rng, lo: number, hi: number): number
	return lo + (hi - lo) * self:nextFloat()
end

-- Integer in [lo, hi] inclusive.
function Rng.nextInt(self: Rng, lo: number, hi: number): number
	assert(hi >= lo, "Rng.nextInt: hi < lo")
	return lo + math.floor(self:nextFloat() * (hi - lo + 1))
end

function Rng.chance(self: Rng, p: number): boolean
	return self:nextFloat() < p
end

function Rng.pick<T>(self: Rng, list: { T }): T
	assert(#list > 0, "Rng.pick: empty list")
	return list[self:nextInt(1, #list)]
end

-- Fisher–Yates, in place; returns the same table for chaining.
function Rng.shuffle<T>(self: Rng, list: { T }): { T }
	for i = #list, 2, -1 do
		local j = self:nextInt(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

-- Returns the index chosen proportionally to weights[i] (all >= 0, sum > 0).
function Rng.weightedIndex(self: Rng, weights: { number }): number
	local total = 0
	for _, w in weights do
		total += w
	end
	assert(total > 0, "Rng.weightedIndex: weights sum to 0")
	local roll = self:nextFloat() * total
	for i, w in weights do
		roll -= w
		if roll < 0 then
			return i
		end
	end
	return #weights
end

-- Independent child stream; same parent state + salt always gives the same child.
function Rng.fork(self: Rng, salt: number): Rng
	return Rng.new(bit32.bxor(self:nextU32(), mix(salt)))
end

return Rng
