-- RBXScriptSignal / RBXScriptConnection emulation.
--
-- Each connection remembers the context that connected it, and its handler runs in
-- that context in a new thread (so errors are recorded, not propagated to the
-- firer). Script-fired signals follow Workspace.SignalBehavior (Deferred by default,
-- like new Roblox places); engine events (Heartbeat, remote delivery) run at once.

local Core = require("./Core")

local Signal = {}

export type SignalData = {
	name: string,
	conns: { any },
	waiters: { any },
	engine: boolean,
	filter: ((ctx: any, ...any) -> boolean)?,
	guard: ((ctx: any) -> ())?,
	onConnect: ((conn: any) -> ())?,
	proxy: any,
}

local dataOf: { [any]: SignalData } = {}
Signal.dataOf = dataOf

local function connProxy(conn)
	local p
	p = Core.proxy("RBXScriptConnection", function(_, k)
		if k == "Connected" then
			return conn.connected
		elseif k == "Disconnect" or k == "disconnect" then
			return function()
				conn.connected = false
			end
		end
		error(tostring(k) .. " is not a valid member of RBXScriptConnection", 2)
	end)
	return p
end

local function connect(d: SignalData, fn: any, once: boolean)
	if type(fn) ~= "function" then
		error("Attempt to connect failed: Passed value is not a function", 3)
	end
	local ctx = Core.current()
	if d.guard then
		d.guard(ctx)
	end
	local conn = { fn = fn, ctx = ctx, connected = true, once = once }
	table.insert(d.conns, conn)
	-- prune dead connections occasionally
	if #d.conns > 64 then
		local live = {}
		for _, c in d.conns do
			if c.connected and not (c.ctx and c.ctx.dead) then
				table.insert(live, c)
			end
		end
		d.conns = live
	end
	if d.onConnect then
		d.onConnect(conn)
	end
	return connProxy(conn)
end

function Signal.new(name: string, opts: { [string]: any }?): (any, SignalData)
	local o = opts or {}
	local d: SignalData = {
		name = name,
		conns = {},
		waiters = {},
		engine = o.engine == true,
		filter = o.filter,
		guard = o.guard,
		onConnect = o.onConnect,
		proxy = nil,
	}
	local methods = {
		Connect = function(_, fn)
			return connect(d, fn, false)
		end,
		ConnectParallel = function(_, fn)
			return connect(d, fn, false)
		end,
		Once = function(_, fn)
			return connect(d, fn, true)
		end,
		Wait = function(_)
			local S = Core.S
			if d.guard then
				d.guard(S.current)
			end
			local co = coroutine.running()
			table.insert(d.waiters, { co = co, ctx = S.current })
			return S:yieldCurrent("Signal:Wait()")
		end,
	}
	methods.connect = methods.Connect
	methods.wait = methods.Wait
	local p = Core.proxy(
		"RBXScriptSignal",
		function(_, k)
			local m = methods[k]
			if m then
				return m
			end
			error(tostring(k) .. " is not a valid member of RBXScriptSignal", 2)
		end,
		nil,
		function()
			return "Signal " .. name
		end
	)
	d.proxy = p
	dataOf[p] = d
	return p, d
end

function Signal.hasConnections(d: SignalData, ctx: any?): boolean
	for _, c in d.conns do
		if c.connected and not (c.ctx and c.ctx.dead) and (ctx == nil or c.ctx == ctx) then
			return true
		end
	end
	return #d.waiters > 0
end

-- Fires the signal. `onlyCtx` limits delivery to connections made in that context.
-- `immediate` forces immediate handler execution (engine events).
function Signal.fire(d: SignalData, onlyCtx: any?, immediate: boolean?, ...: any)
	local S = Core.S
	local deferred = not (immediate or d.engine) and S.signalBehavior == "Deferred"
	local n = #d.conns
	if n > 0 then
		local snapshot = table.move(d.conns, 1, n, 1, {})
		for _, c in snapshot do
			if c.connected and not (c.ctx and c.ctx.dead) and (onlyCtx == nil or c.ctx == onlyCtx) then
				if d.filter == nil or d.filter(c.ctx, ...) then
					if c.once then
						c.connected = false
					end
					S:dispatch(c.fn, c.ctx, deferred, ...)
				end
			end
		end
	end
	if #d.waiters > 0 then
		local keep = {}
		local ws = d.waiters
		d.waiters = keep
		for _, w in ws do
			if (onlyCtx == nil or w.ctx == onlyCtx) and (d.filter == nil or d.filter(w.ctx, ...)) then
				if deferred then
					S:defer(w.co, ...)
				else
					S:resume(w.co, ...)
				end
			else
				table.insert(keep, w)
			end
		end
	end
end

function Signal.disconnectAll(d: SignalData)
	for _, c in d.conns do
		c.connected = false
	end
	d.conns = {}
end

return Signal
