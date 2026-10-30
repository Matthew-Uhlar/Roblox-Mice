--!strict
-- Minimal test harness for Lune. Each spec file:
--   local T = require("../lib/Test")
--   T.describe("thing", function() T.it("does x", function() T.eq(1, 1) end) end)
--   return T.finish()
-- scripts/test.sh runs every tests/specs/*.spec.luau and fails on any failure.

local T = {}

local passed, failed = 0, 0
local failures: { string } = {}
local prefix: { string } = {}

local function fmt(v: any): string
	if type(v) == "string" then
		return string.format("%q", v)
	elseif type(v) == "table" then
		local parts = {}
		local n = 0
		for k, x in v do
			n += 1
			if n > 12 then
				table.insert(parts, "…")
				break
			end
			table.insert(parts, tostring(k) .. "=" .. tostring(x))
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(v)
end

function T.describe(name: string, fn: () -> ())
	table.insert(prefix, name)
	fn()
	table.remove(prefix)
end

function T.it(name: string, fn: () -> ())
	local full = table.concat(prefix, " › ") .. " › " .. name
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, full .. "\n      " .. tostring(err))
	end
end

function T.eq(actual: any, expected: any, msg: string?)
	if actual ~= expected then
		error(
			string.format("%sexpected %s, got %s", msg and (msg .. ": ") or "", fmt(expected), fmt(actual)),
			2
		)
	end
end

function T.near(actual: number, expected: number, eps: number?, msg: string?)
	if math.abs(actual - expected) > (eps or 1e-6) then
		error(
			string.format(
				"%sexpected ≈%s, got %s",
				msg and (msg .. ": ") or "",
				tostring(expected),
				tostring(actual)
			),
			2
		)
	end
end

function T.truthy(v: any, msg: string?)
	if not v then
		error((msg or "expected truthy") .. ", got " .. fmt(v), 2)
	end
end

function T.falsy(v: any, msg: string?)
	if v then
		error((msg or "expected falsy") .. ", got " .. fmt(v), 2)
	end
end

function T.throws(fn: () -> (), msg: string?)
	local ok = pcall(fn)
	if ok then
		error(msg or "expected function to throw", 2)
	end
end

function T.deepEq(a: any, b: any, msg: string?)
	local function same(x: any, y: any): boolean
		if type(x) ~= type(y) then
			return false
		end
		if type(x) ~= "table" then
			return x == y
		end
		for k, v in x do
			if not same(v, y[k]) then
				return false
			end
		end
		for k in y do
			if x[k] == nil then
				return false
			end
		end
		return true
	end
	if not same(a, b) then
		error(string.format("%sdeep mismatch: %s vs %s", msg and (msg .. ": ") or "", fmt(a), fmt(b)), 2)
	end
end

-- Call at the end of each spec file: `return T.finish()`.
function T.finish()
	for _, f in failures do
		print("  ✗ " .. f)
	end
	print(string.format("  %d passed, %d failed", passed, failed))
	if failed > 0 then
		local process = (require :: any)("@lune/process")
		process.exit(1)
	end
	return nil
end

return T
