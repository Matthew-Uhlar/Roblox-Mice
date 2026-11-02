-- Shared state of the emulator: one runtime per Lune process (each spec runs in
-- its own process), so the modules reach the scheduler and runtime through here.

local Core = {}

Core.S = nil :: any -- Scheduler
Core.rt = nil :: any -- Runtime
Core.typeOf = setmetatable({}, { __mode = "k" }) :: { [any]: string } -- proxy -> typeof name
Core.NIL = newproxy(false) -- sentinel: property explicitly set to nil

local proxyTypes = Core.typeOf

-- typeof() that knows the emulator's proxies (Instance, RBXScriptSignal, Random, ...).
function Core.typeof(v: any): string
	if type(v) == "userdata" then
		local t = proxyTypes[v]
		if t then
			return t
		end
	end
	return typeof(v)
end

-- Creates a userdata proxy (so `type(x) == "userdata"`, as in Roblox) with a locked
-- metatable and a typeof() name.
function Core.proxy(typeName: string, index: any, newindex: any, tostr: any): any
	local p = newproxy(true)
	local mt = getmetatable(p)
	mt.__index = index
	mt.__newindex = newindex
		or function(_, k)
			error(string.format("%s cannot be assigned to (%s is read-only)", tostring(k), typeName), 2)
		end
	mt.__tostring = tostr or function()
		return typeName
	end
	mt.__metatable = "The metatable is locked"
	proxyTypes[p] = typeName
	return p
end

function Core.current(): any
	return Core.S and Core.S.current
end

-- Raises an "EMULATOR GAP" error and records it (even if the caller pcall's it).
function Core.gap(what: string, level: number?): never
	if Core.S then
		Core.S:recordGap(what)
	end
	error("EMULATOR GAP: " .. what, (level or 1) + 1)
end

function Core.warn(message: string)
	if Core.S then
		Core.S:recordWarning(Core.current(), message)
	else
		print("[warn] " .. message)
	end
end

return Core
