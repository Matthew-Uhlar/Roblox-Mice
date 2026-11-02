-- Roblox datatypes for scripts under test. Most come from @lune/roblox; the ones
-- Lune does not ship (Random, TweenInfo, DateTime, RaycastParams, OverlapParams)
-- are implemented here. Random is deterministic (seeded from a counter when no
-- seed is given) so runtime scenarios are reproducible.

local roblox = require("@lune/roblox")
local Core = require("./Core")

local Datatypes = {}

local proxy = Core.proxy

-- Random (PCG-ish 32-bit LCG + xorshift output) ------------------------------------

local autoSeed = 12345

local function makeRandom(seed: number?): any
	if seed == nil then
		autoSeed += 7919
		seed = autoSeed
	end
	local state = math.floor(math.abs(seed :: number)) % 4294967296
	if state == 0 then
		state = 0x9E3779B9
	end
	local function nextU32(): number
		-- xorshift32
		local x = state
		x = bit32.bxor(x, bit32.lshift(x, 13))
		x = bit32.bxor(x, bit32.rshift(x, 17))
		x = bit32.bxor(x, bit32.lshift(x, 5))
		state = x
		return x
	end
	local function nextFloat(): number
		return nextU32() / 4294967296
	end
	local methods = {}
	function methods.NextInteger(_, min: number, max: number): number
		if type(min) ~= "number" or type(max) ~= "number" then
			error("invalid argument to NextInteger (number expected)", 2)
		end
		if max < min then
			error("invalid argument #2 to 'NextInteger' (interval is empty)", 2)
		end
		return min + math.floor(nextFloat() * (max - min + 1))
	end
	function methods.NextNumber(_, min: number?, max: number?): number
		local lo, hi = min or 0, max or 1
		return lo + nextFloat() * (hi - lo)
	end
	function methods.NextUnitVector(_)
		local z = nextFloat() * 2 - 1
		local t = nextFloat() * math.pi * 2
		local r = math.sqrt(1 - z * z)
		return roblox.Vector3.new(r * math.cos(t), r * math.sin(t), z)
	end
	function methods.Shuffle(_, t: { any })
		for i = #t, 2, -1 do
			local j = 1 + math.floor(nextFloat() * i)
			t[i], t[j] = t[j], t[i]
		end
	end
	function methods.Clone(_)
		local r = makeRandom(1)
		return r
	end
	return proxy("Random", function(_, k)
		local m = methods[k]
		if m then
			return m
		end
		error(tostring(k) .. " is not a valid member of Random", 2)
	end)
end

Datatypes.Random = table.freeze({ new = makeRandom })

-- TweenInfo -------------------------------------------------------------------------

local function makeTweenInfo(
	time: number?,
	style: any?,
	dir: any?,
	repeatCount: number?,
	reverses: boolean?,
	delay: number?
)
	local fields = {
		Time = time or 1,
		EasingStyle = style or roblox.Enum.EasingStyle.Quad,
		EasingDirection = dir or roblox.Enum.EasingDirection.Out,
		RepeatCount = repeatCount or 0,
		Reverses = reverses or false,
		DelayTime = delay or 0,
	}
	if type(fields.Time) ~= "number" then
		error("TweenInfo.new: time must be a number", 2)
	end
	if Core.typeof(fields.EasingStyle) ~= "EnumItem" or Core.typeof(fields.EasingDirection) ~= "EnumItem" then
		error("TweenInfo.new: easing style/direction must be Enum items", 2)
	end
	return proxy(
		"TweenInfo",
		function(_, k)
			local v = fields[k]
			if v == nil and k ~= "Reverses" then
				error(tostring(k) .. " is not a valid member of TweenInfo", 2)
			end
			return v
		end,
		nil,
		function()
			return string.format("TweenInfo(%s)", tostring(fields.Time))
		end
	)
end

Datatypes.TweenInfo = table.freeze({ new = makeTweenInfo })

-- DateTime ---------------------------------------------------------------------------

local function makeDateTime(ms: number)
	local fields = {
		UnixTimestampMillis = ms,
		UnixTimestamp = math.floor(ms / 1000),
	}
	local methods = {}
	function methods.ToIsoDate(_)
		return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(ms / 1000))
	end
	function methods.ToUniversalTime(_)
		local t = os.date("!*t", math.floor(ms / 1000)) :: any
		return {
			Year = t.year,
			Month = t.month,
			Day = t.day,
			Hour = t.hour,
			Minute = t.min,
			Second = t.sec,
			Millisecond = ms % 1000,
		}
	end
	methods.ToLocalTime = methods.ToUniversalTime
	function methods.FormatUniversalTime(_, _fmt, _locale)
		return os.date("!%Y-%m-%d %H:%M:%S", math.floor(ms / 1000))
	end
	methods.FormatLocalTime = methods.FormatUniversalTime
	return proxy("DateTime", function(_, k)
		if fields[k] ~= nil then
			return fields[k]
		end
		local m = methods[k]
		if m then
			return m
		end
		error(tostring(k) .. " is not a valid member of DateTime", 2)
	end)
end

Datatypes.DateTime = table.freeze({
	now = function()
		local S = Core.S
		return makeDateTime(math.floor((S.epoch + S.now) * 1000))
	end,
	fromUnixTimestamp = function(t: number)
		return makeDateTime(math.floor(t * 1000))
	end,
	fromUnixTimestampMillis = function(t: number)
		return makeDateTime(math.floor(t))
	end,
})

-- RaycastParams / OverlapParams (plain mutable bags) ------------------------------------

local function bag(typeName: string, defaults: { [string]: any })
	return function()
		local fields = table.clone(defaults)
		local methods = {
			AddToFilter = function(_, x)
				if Core.typeof(x) == "Instance" then
					table.insert(fields.FilterDescendantsInstances, x)
				elseif type(x) == "table" then
					for _, i in x do
						table.insert(fields.FilterDescendantsInstances, i)
					end
				end
			end,
		}
		fields.FilterDescendantsInstances = {}
		return proxy(typeName, function(_, k)
			if methods[k] then
				return methods[k]
			end
			if fields[k] == nil and defaults[k] == nil and k ~= "FilterDescendantsInstances" then
				error(tostring(k) .. " is not a valid member of " .. typeName, 2)
			end
			return fields[k]
		end, function(_, k, v)
			if defaults[k] == nil and k ~= "FilterDescendantsInstances" then
				error(tostring(k) .. " is not a valid member of " .. typeName, 2)
			end
			fields[k] = v
		end)
	end
end

Datatypes.RaycastParams = table.freeze({
	new = bag("RaycastParams", {
		FilterType = roblox.Enum.RaycastFilterType.Exclude,
		IgnoreWater = false,
		CollisionGroup = "Default",
		RespectCanCollide = false,
		BruteForceAllSlow = false,
	}),
})
Datatypes.OverlapParams = table.freeze({
	new = bag("OverlapParams", {
		FilterType = roblox.Enum.RaycastFilterType.Exclude,
		MaxParts = 0,
		CollisionGroup = "Default",
		RespectCanCollide = false,
		BruteForceAllSlow = false,
	}),
})

Datatypes.typeof = Core.typeof

return Datatypes
