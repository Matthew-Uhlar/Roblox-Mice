--!strict
-- Small display formatters shared by the UIs.

local Format = {}

-- 12345 -> "12,345"
function Format.int(n: number?): string
	local v = math.floor((tonumber(n) or 0) + 0.5)
	local neg = v < 0
	local s = tostring(math.abs(v))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return (if neg then "-" else "") .. out
end

-- Compact: 1234 -> "1.2k"
function Format.short(n: number?): string
	local v = tonumber(n) or 0
	if math.abs(v) >= 1e6 then
		return string.format("%.1fM", v / 1e6)
	elseif math.abs(v) >= 1e4 then
		return string.format("%.1fk", v / 1e3)
	end
	return Format.int(v)
end

-- seconds -> "m:ss"
function Format.clock(seconds: number?): string
	local s = math.max(0, math.ceil(tonumber(seconds) or 0))
	return string.format("%d:%02d", s // 60, s % 60)
end

-- 0.15 -> "15%"
function Format.pct(f: number?): string
	local v = (tonumber(f) or 0) * 100
	if v > 0 and v < 1 then
		return string.format("%.1f%%", v)
	end
	return string.format("%d%%", math.floor(v + 0.5))
end

-- 1.5 -> "×1.5", 2 -> "×2"
function Format.mult(m: number?): string
	local v = tonumber(m) or 1
	if math.abs(v - math.floor(v)) < 0.001 then
		return "×" .. tostring(math.floor(v))
	end
	return "×" .. string.format("%.2f", v):gsub("0+$", "")
end

-- {r, g, b} 0..255 (or {r=, g=, b=}) -> Color3, with fallback.
function Format.rgb(t: any, fallback: Color3?): Color3
	if typeof(t) == "Color3" then
		return t
	end
	if type(t) == "table" then
		local r = tonumber(t[1] or t.r or t.R)
		local g = tonumber(t[2] or t.g or t.G)
		local b = tonumber(t[3] or t.b or t.B)
		if r and g and b then
			return Color3.fromRGB(r, g, b)
		end
	end
	return fallback or Color3.fromRGB(200, 200, 200)
end

-- Converts a map whose keys may have become strings over the network
-- (e.g. {["123"] = v}) back to numeric keys where possible.
function Format.numericKeys(t: any): { [number]: any }
	local out = {}
	if type(t) ~= "table" then
		return out
	end
	for k, v in t do
		local n = tonumber(k)
		if n then
			out[n] = v
		end
	end
	return out
end

return Format
