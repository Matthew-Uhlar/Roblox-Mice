--!strict
-- Thin wrapper over Shared.Net for the client. Net.get yields until the server
-- has created ReplicatedStorage.Remotes, so `on` and `fire` never block the
-- caller: they connect or send as soon as the remote exists.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any

local Remotes = {}
Remotes.Net = Net
Remotes.C2S = Net.C2S :: { [string]: string }
Remotes.S2C = Net.S2C :: { [string]: string }

local cache: { [string]: any } = {}

-- Yields until the remote exists. Returns nil if Net.get errors.
function Remotes.get(name: string): any
	local r = cache[name]
	if r then
		return r
	end
	local ok, res = pcall(Net.get, name)
	if ok and res then
		cache[name] = res
		return res
	end
	warn("[Trunkfall] remote unavailable: " .. tostring(name) .. " " .. tostring(res))
	return nil
end

export type Handle = { Disconnect: () -> () }

-- Connects `fn` to a server->client remote. Returns a handle with Disconnect().
function Remotes.on(name: string, fn: (...any) -> ()): Handle
	local dead = false
	local conn: RBXScriptConnection? = nil
	task.spawn(function()
		local r = Remotes.get(name)
		if r and not dead then
			conn = r.OnClientEvent:Connect(function(...)
				local ok, err = pcall(fn, ...)
				if not ok then
					warn("[Trunkfall] " .. name .. " handler error: " .. tostring(err))
				end
			end)
		end
	end)
	return {
		Disconnect = function()
			dead = true
			if conn then
				conn:Disconnect()
				conn = nil
			end
		end,
	}
end

-- Fires a client->server remote without yielding the caller.
function Remotes.fire(name: string, ...: any)
	local r = cache[name]
	if r then
		r:FireServer(...)
		return
	end
	local args = table.pack(...)
	task.spawn(function()
		local r2 = Remotes.get(name)
		if r2 then
			r2:FireServer(table.unpack(args, 1, args.n))
		end
	end)
end

return Remotes
