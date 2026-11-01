--!strict
-- Tiny client-side signal. Handlers run in order and errors are caught per
-- handler, so one broken UI subscriber can't break the others.

local Signal = {}

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal = {
	Connect: (self: Signal, fn: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	DisconnectAll: (self: Signal) -> (),
}

function Signal.new(): Signal
	local handlers: { any } = {}
	local self = {} :: any

	function self.Connect(_: any, fn: (...any) -> ()): Connection
		local conn = { Connected = true } :: any
		conn.fn = fn
		function conn.Disconnect(c: any)
			if not c.Connected then
				return
			end
			c.Connected = false
			local i = table.find(handlers, c)
			if i then
				table.remove(handlers, i)
			end
		end
		table.insert(handlers, conn)
		return conn
	end

	function self.Fire(_: any, ...: any)
		local snapshot = table.clone(handlers)
		for _, c in snapshot do
			if c.Connected then
				local ok, err = pcall(c.fn, ...)
				if not ok then
					warn("[Trunkfall] signal handler error: " .. tostring(err))
				end
			end
		end
	end

	function self.DisconnectAll(_: any)
		for _, c in table.clone(handlers) do
			c:Disconnect()
		end
	end

	return self
end

return Signal
