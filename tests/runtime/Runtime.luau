-- Headless Roblox runtime emulator: builds the DataModel from default.project.json,
-- runs the server Script and one client context per fake player, wires remotes
-- between them, and drives everything with a deterministic virtual-time scheduler.
-- See tests/runtime/README.md.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")

local Core = require("./Core")
local Scheduler = require("./Scheduler")
local Signal = require("./Signal")
local Inst = require("./Instance")
local Datatypes = require("./Datatypes")
local Classes = require("./Classes")
local Services = require("./Services")

local D = Inst.D
local rawGet = Inst.rawGet
local typeOf = Core.typeof

local Runtime = {}
Runtime.__index = Runtime

local SERVER_CONTAINERS = { ServerScriptService = true, ServerStorage = true }
local STANDARD_SERVICES = {
	"Workspace",
	"Players",
	"Lighting",
	"ReplicatedStorage",
	"ReplicatedFirst",
	"ServerScriptService",
	"ServerStorage",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
	"SoundService",
	"Teams",
	"TextChatService",
	"RunService",
}

local UNRELIABLE_LIMIT = 900

-- Contexts ----------------------------------------------------------------------------------

local function newCtx(name: string, isServer: boolean): any
	return {
		name = name,
		isServer = isServer,
		isClient = not isServer,
		player = nil,
		dead = false,
		moduleCache = {},
		loading = {},
		waitingOn = {},
		shared = {},
		G = {},
		camera = nil,
		viewport = roblox.Vector2.new(1280, 720),
		device = { keyboard = true, mouse = true, touch = false },
		renderBindings = {},
		actions = {},
		coreGui = {},
		core = {},
		inbox = {},
		globals = nil,
	}
end

-- Construction ------------------------------------------------------------------------------

function Runtime.new(opts: { [string]: any }?)
	local o = opts or {}
	local self = setmetatable({}, Runtime)
	local S = Scheduler.new({ dt = o.dt, echo = o.echo, signalBehavior = o.signalBehavior })
	self.S = S
	Core.S = S
	Core.rt = self
	self.root = o.root or "."
	self.config = {
		isStudio = o.isStudio == true,
		jobId = "emulated-job-0001",
		placeId = 1234567,
		gameId = 7654321,
		asyncLatency = o.asyncLatency or 0.05,
		netLatency = o.netLatency or 0.05,
		dataStoreBudget = nil, -- number: caps every request budget (to test throttling)
		dataStoresDisabled = false,
		dataStoreFail = nil,
		ownedPasses = {},
		productInfo = {},
		friends = o.friends or {}, -- { {userIdA, userIdB} }: Player:IsFriendsWith
		policy = {
			ArePaidRandomItemsRestricted = false,
			AllowedExternalLinkReferences = {},
			IsPaidItemTradingAllowed = true,
			IsSubjectToChinaPolicies = false,
			IsContentSharingAllowed = true,
			AreAdsAllowed = true,
		},
	}
	self.players = {}
	self.clients = {}
	self.clientOf = {}
	self.dataStores = {}
	self.messagingSubs = {}
	self.messagingLog = {}
	self.prompts = {}
	self.badges = {}
	self.teleports = {}
	self.kicks = {}
	self.dataStoreThrottles = {}
	self.closeCallbacks = {}
	self.netQueue = {}
	self.pending = {}
	self.lossy = {}
	self.netStats = { s2c = {}, c2s = {}, dropped = {} }
	self.serverInbox = {}
	self.compileCache = {}
	self.walkers = {}
	self.mice = {}

	self.server = newCtx("server", true)
	S.current = self.server
	self:buildDataModel()
	S.current = nil

	table.insert(S.frameHooks, function(dt, phase)
		self:frame(dt, phase)
	end)
	return self
end

function Runtime:asServer(fn: (...any) -> ...any, ...: any): ...any
	local S = self.S
	local prev = S.current
	S.current = self.server
	local r = table.pack(pcall(fn, ...))
	S.current = prev
	if not r[1] then
		error(r[2], 0)
	end
	return table.unpack(r, 2, r.n)
end

function Runtime:createService(name: string): any
	local cls = Inst.classDesc(name)
	if not cls or not cls.tags.Service then
		error("'" .. tostring(name) .. "' is not a valid Service name", 3)
	end
	local prev = self.S.current
	self.S.current = nil
	local svc = Inst.make(name)
	self.S.current = prev
	local d = D[svc]
	if SERVER_CONTAINERS[name] then
		d.extra.serverContainer = true
	end
	D[svc].parent = self.game
	table.insert(D[self.game].children, svc)
	return svc
end

function Runtime:buildDataModel()
	local game = Inst.make("DataModel", { name = "Trunkfall" })
	self.game = game
	for _, name in STANDARD_SERVICES do
		self:createService(name)
	end
	local ws = game:GetService("Workspace")
	self.workspace = ws
	local terrain = Inst.make("Terrain", { name = "Terrain" })
	terrain.Parent = ws
	self.serverCamera = Inst.make("Camera", { name = "Camera" })
	self.serverCamera.Parent = ws
	local sp = game:GetService("StarterPlayer")
	local sps = Inst.make("StarterPlayerScripts", { name = "StarterPlayerScripts" })
	sps.Parent = sp
	local scs = Inst.make("StarterCharacterScripts", { name = "StarterCharacterScripts" })
	scs.Parent = sp
	self:loadProject()
end

-- Project tree (mirrors default.project.json) ------------------------------------------------------

local function stripSuffix(file: string): (string?, string?)
	for _, pair in
		{
			{ ".server.luau", "Script" },
			{ ".client.luau", "LocalScript" },
			{ ".server.lua", "Script" },
			{ ".client.lua", "LocalScript" },
			{ ".luau", "ModuleScript" },
			{ ".lua", "ModuleScript" },
		}
	do
		local suffix = pair[1]
		if #file > #suffix and string.sub(file, -#suffix) == suffix then
			return string.sub(file, 1, #file - #suffix), pair[2]
		end
	end
	return nil, nil
end

function Runtime:makeScript(className: string, name: string, path: string): any
	local inst = Inst.make(className, { name = name })
	local d = D[inst]
	d.extra.source = fs.readFile(path)
	d.extra.path = path
	return inst
end

function Runtime:loadPath(path: string, name: string): any
	local full = self.root .. "/" .. path
	if fs.isDir(full) then
		local entries = fs.readDir(full)
		table.sort(entries)
		local inst
		for _, initName in { "init.server.luau", "init.client.luau", "init.luau", "init.lua" } do
			if table.find(entries, initName) then
				local _, cls = stripSuffix(initName)
				inst = self:makeScript(cls :: string, name, full .. "/" .. initName)
				break
			end
		end
		inst = inst or Inst.make("Folder", { name = name })
		for _, entry in entries do
			if string.sub(entry, 1, 5) ~= "init." then
				local childPath = path .. "/" .. entry
				if fs.isDir(self.root .. "/" .. childPath) then
					self:loadPath(childPath, entry).Parent = inst
				else
					local base, cls = stripSuffix(entry)
					if base and cls then
						self:makeScript(cls, base, self.root .. "/" .. childPath).Parent = inst
					end
				end
			end
		end
		return inst
	end
	local base, cls = stripSuffix(string.match(path, "[^/]+$") :: string)
	assert(base and cls, "unsupported $path " .. path)
	return self:makeScript(cls, name, full)
end

function Runtime:applyNode(inst: any, node: { [string]: any })
	for k, v in node["$properties"] or {} do
		(inst :: any)[k] = v
	end
	for key, child in node do
		if string.sub(key, 1, 1) ~= "$" then
			local existing = Inst.findVisibleChild(D[inst], key, nil)
			local childInst
			if child["$path"] then
				childInst = self:loadPath(child["$path"], key)
				childInst.Parent = inst
			elseif existing then
				childInst = existing
			elseif inst == self.game then
				childInst = self.game:GetService(key)
			else
				childInst = Inst.make(child["$className"] or "Folder", { name = key })
				childInst.Parent = inst
			end
			self:applyNode(childInst, child)
		end
	end
end

function Runtime:loadProject()
	local project = serde.decode("json", fs.readFile(self.root .. "/default.project.json"))
	self.project = project
	self:applyNode(self.game, project.tree)
end

-- Globals and require ------------------------------------------------------------------------------

function Runtime:baseGlobals(): { [string]: any }
	if self._base then
		return self._base
	end
	local S = self.S
	local rt = self
	local function argsToString(...: any): string
		local n = select("#", ...)
		local parts = table.create(n)
		for i = 1, n do
			parts[i] = tostring((select(i, ...)))
		end
		return table.concat(parts, " ")
	end
	local taskLib = S:makeTask()
	local osLib = table.clone(os)
	osLib.clock = function()
		return S.now
	end
	osLib.time = function(t: any?)
		if t ~= nil then
			return os.time(t)
		end
		return S.epoch + math.floor(S.now)
	end
	osLib.date = function(fmt: string?, t: number?)
		return os.date(fmt or "%c", t or (S.epoch + math.floor(S.now)))
	end
	local debugLib = table.clone(debug)
	debugLib.profilebegin = function() end
	debugLib.profileend = function() end
	debugLib.setmemorycategory = function() end
	debugLib.resetmemorycategory = function() end
	debugLib.dumpcodesize = function() end
	local deprecated = function(name)
		return function()
			S:recordWarning(S.current, "DEPRECATED global used: " .. name .. "()")
		end
	end
	local noteWait, noteSpawn, noteDelay = deprecated("wait"), deprecated("spawn"), deprecated("delay")
	local base = {
		-- Luau standard library
		string = string,
		table = table,
		math = math,
		coroutine = coroutine,
		bit32 = bit32,
		utf8 = utf8,
		buffer = buffer,
		os = osLib,
		debug = debugLib,
		pairs = pairs,
		ipairs = ipairs,
		next = next,
		select = select,
		type = type,
		typeof = typeOf,
		tostring = tostring,
		tonumber = tonumber,
		rawget = rawget,
		rawset = rawset,
		rawequal = rawequal,
		rawlen = rawlen,
		setmetatable = setmetatable,
		getmetatable = getmetatable,
		pcall = pcall,
		xpcall = xpcall,
		error = error,
		assert = assert,
		unpack = table.unpack,
		newproxy = newproxy,
		gcinfo = gcinfo,
		collectgarbage = function(opt)
			if opt ~= "count" then
				error("collectgarbage must be called with 'count'", 2)
			end
			return gcinfo()
		end,
		-- Roblox globals
		print = function(...)
			table.insert(S.prints, { ctx = S:ctxName(S.current), message = argsToString(...) })
			if S.echo then
				print("[" .. S:ctxName(S.current) .. "]", ...)
			end
		end,
		warn = function(...)
			S:recordWarning(S.current, argsToString(...))
		end,
		tick = function()
			return S.epoch + S.now
		end,
		time = function()
			return S.now
		end,
		elapsedTime = function()
			return S.now
		end,
		task = taskLib,
		wait = function(t)
			noteWait()
			return taskLib.wait(t), S.now
		end,
		spawn = function(f)
			noteSpawn()
			taskLib.defer(f)
		end,
		delay = function(t, f)
			noteDelay()
			taskLib.delay(t, f)
		end,
		game = rt.game,
		Game = rt.game,
		workspace = rt.workspace,
		Workspace = rt.workspace,
		Instance = table.freeze({ new = Inst.new }),
		Enum = roblox.Enum,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		Vector3int16 = roblox.Vector3int16,
		Vector2int16 = roblox.Vector2int16,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		ColorSequence = roblox.ColorSequence,
		ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		NumberRange = roblox.NumberRange,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Rect = roblox.Rect,
		BrickColor = roblox.BrickColor,
		Font = roblox.Font,
		PhysicalProperties = roblox.PhysicalProperties,
		Ray = roblox.Ray,
		Region3 = roblox.Region3,
		Region3int16 = roblox.Region3int16,
		Axes = roblox.Axes,
		Faces = roblox.Faces,
		Random = Datatypes.Random,
		TweenInfo = Datatypes.TweenInfo,
		DateTime = Datatypes.DateTime,
		RaycastParams = Datatypes.RaycastParams,
		OverlapParams = Datatypes.OverlapParams,
		settings = function()
			Core.gap("settings()", 2)
		end,
		UserSettings = function()
			Core.gap("UserSettings()", 2)
		end,
	}
	self._base = base
	return base
end

function Runtime:ctxGlobals(ctx: any): { [string]: any }
	if not ctx.globals then
		ctx.globals = setmetatable({ _G = ctx.G, shared = ctx.shared }, { __index = self:baseGlobals() })
	end
	return ctx.globals
end

function Runtime:compile(inst: any): string
	local d = D[inst]
	local key = d.extra.path
	local bc = self.compileCache[key]
	if not bc then
		bc = luau.compile(d.extra.source, { optimizationLevel = 1, debugLevel = 1 })
		self.compileCache[key] = bc
	end
	return bc
end

function Runtime:loadChunk(inst: any, ctx: any): (...any) -> ...any
	local d = D[inst]
	if not d.extra.source then
		error("script " .. Inst.fullName(d) .. " has no source", 2)
	end
	local env = setmetatable({}, { __index = self:ctxGlobals(ctx) })
	env.script = inst
	env.require = self:makeRequire(inst, ctx)
	return luau.load(self:compile(inst), {
		debugName = "@" .. string.gsub(d.extra.path, "^%./", ""),
		environment = env,
		injectGlobals = false,
	})
end

-- Roblox require-by-string: paths resolve against the INSTANCE tree.
-- "./X" = script.Parent.X, "../X" = script.Parent.Parent.X, "@self/X" = script.X.
function Runtime:resolvePath(scriptInst: any, path: string, level: number): any
	local segs = string.split(path, "/")
	local cur
	local i = 1
	local first = segs[1]
	if first == "." then
		cur = D[scriptInst].parent
		i = 2
	elseif first == ".." then
		cur = D[scriptInst].parent
	elseif first == "@self" then
		cur = scriptInst
		i = 2
	elseif first == "@game" then
		cur = self.game
		i = 2
	else
		error(
			string.format("require path '%s' must start with './', '../' or an alias like '@self'", path),
			level + 1
		)
	end
	local ctx = self.S.current
	while i <= #segs do
		local seg = segs[i]
		i += 1
		if seg == "" or seg == "." then
			continue
		elseif seg == ".." then
			cur = cur and D[cur].parent
			if not cur then
				error(string.format("require path '%s' walks above the DataModel", path), level + 1)
			end
		else
			seg = string.gsub(seg, "%.luau$", "")
			seg = string.gsub(seg, "%.lua$", "")
			local nxt = cur and Inst.findVisibleChild(D[cur], seg, ctx)
			if not nxt then
				error(
					string.format(
						"Failed to require '%s' from %s: %s is not a valid member of %s",
						path,
						Inst.fullName(D[scriptInst]),
						seg,
						if cur then Inst.fullName(D[cur]) else "nil"
					),
					level + 1
				)
			end
			cur = nxt
		end
	end
	return cur
end

function Runtime:makeRequire(scriptInst: any, ctx: any)
	return function(target: any): any
		local mod
		if type(target) == "string" then
			mod = self:resolvePath(scriptInst, target, 2)
		elseif typeOf(target) == "Instance" then
			mod = target
		else
			error("Attempted to call require with invalid argument(s).", 2)
		end
		return self:requireModule(mod, ctx, 2)
	end
end

function Runtime:requireModule(mod: any, ctx: any, level: number?): any
	local lvl = (level or 1) + 1
	local d = D[mod]
	if not d or d.className ~= "ModuleScript" then
		error("Attempted to call require with invalid argument(s).", lvl)
	end
	local cached = ctx.moduleCache[mod]
	if cached then
		return cached.value
	end
	local S = self.S
	local co = coroutine.running()
	local loading = ctx.loading[mod]
	if loading then
		-- cycle? follow the chain of "thread waits for module" back to us
		local t = loading.thread
		local hops = 0
		while t and hops < 100 do
			if t == co then
				error(
					"Requested module was required recursively: " .. Inst.fullName(d) .. " (require cycle)",
					lvl
				)
			end
			local waitMod = ctx.waitingOn[t]
			local l2 = waitMod and ctx.loading[waitMod]
			t = l2 and l2.thread
			hops += 1
		end
		ctx.waitingOn[co] = mod
		table.insert(loading.waiters, co)
		S:yieldCurrent("require")
		ctx.waitingOn[co] = nil
		local c2 = ctx.moduleCache[mod]
		if c2 then
			return c2.value
		end
		error("Requested module experienced an error while loading", lvl)
	end
	local entry = { thread = co, waiters = {} }
	ctx.loading[mod] = entry
	local fn = self:loadChunk(mod, ctx)
	local results = table.pack(xpcall(fn, function(e)
		return { e = e, tb = debug.traceback(tostring(e), 2) }
	end))
	ctx.loading[mod] = nil
	for _, w in entry.waiters do
		S:defer(w)
	end
	if not results[1] then
		local err = results[2]
		if type(err) == "table" and err.tb then
			S:recordError(ctx, err.e, err.tb)
		else
			S:recordError(ctx, err, nil)
		end
		error("Requested module experienced an error while loading: " .. Inst.fullName(d), lvl)
	end
	if results.n ~= 2 then
		error("Module code did not return exactly one value: " .. Inst.fullName(d), lvl)
	end
	ctx.moduleCache[mod] = { value = results[2] }
	return results[2]
end

-- Runs a Script/LocalScript in ctx.
function Runtime:runScript(inst: any, ctx: any)
	self.S:dispatch(function()
		local fn = self:loadChunk(inst, ctx)
		fn()
	end, ctx, false)
end

function Runtime:startServer()
	local S = self.S
	local function runAll(root)
		for _, x in root:GetDescendants() do
			local d = D[x]
			if d.className == "Script" then
				local rc = rawGet(d, "RunContext")
				if rc == nil or rc.Name ~= "Client" then
					self:runScript(x, self.server)
				end
			end
		end
	end
	S.current = self.server
	local ok, err = pcall(function()
		runAll(self.game:GetService("ServerScriptService"))
		runAll(self.workspace)
	end)
	S.current = nil
	if not ok then
		error(err, 0)
	end
	S:flushDeferred()
end

-- Network ----------------------------------------------------------------------------------------

local function estimateSize(v: any, depth: number): number
	local t = type(v)
	if t == "nil" or t == "boolean" then
		return 1
	elseif t == "number" then
		return 9
	elseif t == "string" then
		return #v + 2
	elseif t == "buffer" then
		return buffer.len(v) + 3
	elseif t == "table" and depth < 50 then
		local n = 2
		for k, x in v do
			n += estimateSize(k, depth + 1) + estimateSize(x, depth + 1)
		end
		return n
	end
	return 16
end

-- Copies one remote argument the way Roblox serializes it: metatables and functions
-- are dropped, mixed tables lose their non-array part, non-string dictionary keys
-- become strings, instances the receiver can't see arrive as nil.
function Runtime:copyArg(v: any, toCtx: any, remote: string, path: string, seen: { [any]: boolean }): any
	local t = typeOf(v)
	if t == "nil" or t == "boolean" or t == "number" or t == "string" then
		return v
	elseif t == "buffer" then
		local b = buffer.create(buffer.len(v))
		buffer.copy(b, 0, v)
		return b
	elseif t == "Instance" then
		local d = D[v]
		local inGame = v == self.game or D[v].parent ~= nil and v:IsDescendantOf(self.game)
		if d.destroyed or not Inst.isVisible(v, toCtx) or (toCtx.isClient and not inGame) then
			self:noteLossy(remote, path, "Instance not visible to receiver -> nil")
			return nil
		end
		return v
	elseif t == "table" then
		if seen[v] then
			error("tables cannot be cyclic", 0)
		end
		seen[v] = true
		local out = {}
		if v[1] ~= nil then
			local n = 0
			while v[n + 1] ~= nil do
				n += 1
				out[n] = self:copyArg(v[n], toCtx, remote, path .. "[" .. n .. "]", seen)
			end
			for k in v do
				if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
					self:noteLossy(remote, path, "mixed/sparse table: key " .. tostring(k) .. " dropped")
				end
			end
		else
			for k, x in v do
				local key = k
				if type(k) ~= "string" then
					key = tostring(k)
					if type(k) ~= "number" then
						self:noteLossy(remote, path, "non-string key " .. typeOf(k) .. " converted to string")
					end
				end
				out[key] = self:copyArg(x, toCtx, remote, path .. "." .. tostring(key), seen)
			end
		end
		seen[v] = nil
		return out
	elseif
		t == "function"
		or t == "thread"
		or t == "userdata"
		or t == "RBXScriptSignal"
		or t == "RBXScriptConnection"
		or t == "Random"
	then
		self:noteLossy(remote, path, t .. " can't be sent -> nil")
		return nil
	end
	return v -- Roblox datatypes (Vector3, CFrame, EnumItem, ...) are values
end

function Runtime:noteLossy(remote: string, path: string, what: string)
	local key = remote .. " " .. path .. " " .. what
	if not self.lossy[key] then
		self.lossy[key] = true
		self.S:recordWarning(self.S.current, "REMOTE LOSSY " .. key)
	end
end

function Runtime:serialize(d: any, args: any, toCtx: any): any
	local out = { n = args.n }
	for i = 1, args.n do
		out[i] = self:copyArg(args[i], toCtx, d.name, "arg" .. i, {})
	end
	return out
end

local function bump(stats: any, name: string, bytes: number)
	local s = stats[name]
	if not s then
		s = { count = 0, bytes = 0 }
		stats[name] = s
	end
	s.count += 1
	s.bytes += bytes
end

function Runtime:checkUnreliable(d: any, args: any): boolean
	if d.className ~= "UnreliableRemoteEvent" then
		return true
	end
	local size = 0
	for i = 1, args.n do
		size += estimateSize(args[i], 0)
	end
	if size > UNRELIABLE_LIMIT then
		self.S:recordWarning(
			self.S.current,
			string.format(
				"UnreliableRemoteEvent %s payload of %d bytes exceeds %d and was dropped",
				d.name,
				size,
				UNRELIABLE_LIMIT
			)
		)
		bump(self.netStats.dropped, d.name, size)
		return false
	end
	return true
end

function Runtime:sendToClient(d: any, player: any, args: any)
	local client = self.clientOf[player]
	if not client or client.dead or D[player].parent == nil then
		return
	end
	if not self:checkUnreliable(d, args) then
		return
	end
	local payload = self:serialize(d, args, client)
	bump(self.netStats.s2c, d.name, estimateSize(payload, 0))
	table.insert(
		self.netQueue,
		{ at = self.S.now + self.config.netLatency, side = "client", d = d, ctx = client, args = payload }
	)
end

function Runtime:sendToServer(d: any, ctx: any, args: any)
	if not self:checkUnreliable(d, args) then
		return
	end
	local payload = self:serialize(d, args, self.server)
	bump(self.netStats.c2s, d.name, estimateSize(payload, 0))
	table.insert(
		self.netQueue,
		{ at = self.S.now + self.config.netLatency, side = "server", d = d, ctx = ctx, args = payload }
	)
end

local function inboxPush(inbox: any, name: string, args: any)
	local box = inbox[name]
	if not box then
		box = { count = 0, list = {} }
		inbox[name] = box
	end
	box.count += 1
	box.last = args
	table.insert(box.list, args)
	if #box.list > 200 then
		table.remove(box.list, 1)
	end
end

function Runtime:deliver(item: any)
	local d = item.d
	if d.destroyed then
		return
	end
	if item.side == "client" then
		local ctx = item.ctx
		if ctx.dead then
			return
		end
		inboxPush(ctx.inbox, d.name, item.args)
		local sd = Inst.getSig(d, "OnClientEvent")
		if Signal.hasConnections(sd, ctx) then
			Signal.fire(sd, ctx, true, table.unpack(item.args, 1, item.args.n))
		else
			self:queuePending(d, "client", ctx, item.args)
		end
	else
		local player = item.ctx.player
		if item.ctx.dead or D[player].parent == nil then
			return
		end
		inboxPush(self.serverInbox, d.name, item.args)
		local sd = Inst.getSig(d, "OnServerEvent")
		if Signal.hasConnections(sd, self.server) then
			Signal.fire(sd, self.server, true, player, table.unpack(item.args, 1, item.args.n))
		else
			local args = table.clone(item.args)
			table.insert(args, 1, player)
			args.n = item.args.n + 1
			self:queuePending(d, "server", self.server, args)
		end
	end
end

-- Roblox queues remote events that arrive before anything is connected and
-- delivers them to the first connection.
function Runtime:queuePending(d: any, side: string, ctx: any, args: any)
	self.pending[d] = self.pending[d] or {}
	local key = side .. ":" .. ctx.name
	local q = self.pending[d][key]
	if not q then
		q = {}
		self.pending[d][key] = q
	end
	table.insert(q, args)
	if #q == 257 then
		self.S:recordWarning(
			ctx,
			"Remote event invocation queue exhausted for "
				.. Inst.fullName(d)
				.. "; did you forget to implement "
				.. (if side == "client" then "OnClientEvent" else "OnServerEvent")
				.. "?"
		)
	end
end

function Runtime:flushPending(d: any, side: string, ctx: any)
	local byKey = self.pending[d]
	if not byKey or not ctx then
		return
	end
	local key = side .. ":" .. ctx.name
	local q = byKey[key]
	if not q then
		return
	end
	byKey[key] = nil
	local sd = Inst.getSig(d, if side == "client" then "OnClientEvent" else "OnServerEvent")
	local S = self.S
	local co = coroutine.create(function()
		for _, args in q do
			Signal.fire(sd, ctx, true, table.unpack(args, 1, args.n))
		end
	end)
	S.threadCtx[co] = nil
	S:defer(co)
end

function Runtime:invokeServer(_d: any, _ctx: any, _args: any)
	Core.gap("RemoteFunction:InvokeServer", 3)
end

-- Frame -----------------------------------------------------------------------------------------

function Runtime:frame(dt: number, phase: string)
	local S = self.S
	local rs = self.game:GetService("RunService")
	local rd = D[rs]
	if phase == "pre" then
		-- network
		if #self.netQueue > 0 then
			local q = self.netQueue
			local keep = {}
			self.netQueue = keep
			for _, item in q do
				if item.at <= S.now + 1e-9 then
					self:deliver(item)
				else
					table.insert(keep, item)
				end
			end
		end
		-- character "physics": walkers move HumanoidRootParts like a client would
		for player, walker in self.walkers do
			self:stepWalker(player, walker, dt)
		end
		-- client render step
		for _, ctx in self.clients do
			if not ctx.dead then
				local sd = rd.sig.RenderStepped
				if sd then
					Signal.fire(sd, ctx, true, dt)
				end
				local pr = rd.sig.PreRender
				if pr then
					Signal.fire(pr, ctx, true, dt)
				end
				local binds = {}
				for name, b in ctx.renderBindings do
					table.insert(binds, { name = name, b = b })
				end
				table.sort(binds, function(a, b)
					return a.b.priority < b.b.priority
				end)
				for _, x in binds do
					S:dispatch(x.b.fn, ctx, false, dt)
				end
			end
		end
		local st = rd.sig.Stepped
		if st then
			Signal.fire(st, nil, true, S.now, dt)
		end
		local ps = rd.sig.PreSimulation
		if ps then
			Signal.fire(ps, nil, true, dt)
		end
	else
		local hb = rd.sig.Heartbeat
		if hb then
			Signal.fire(hb, nil, true, dt)
		end
		local post = rd.sig.PostSimulation
		if post then
			Signal.fire(post, nil, true, dt)
		end
	end
end

-- Players and characters ----------------------------------------------------------------------------

function Runtime:addPlayer(opts: { [string]: any }): (any, any)
	local S = self.S
	local userId = opts.userId or 1
	local name = opts.name or ("Player" .. tostring(userId))
	local ctx = newCtx("client:" .. name, false)
	if opts.device then
		ctx.device = opts.device
	end
	if opts.viewport then
		ctx.viewport = opts.viewport
	end
	local players = self.game:GetService("Players")
	local prev = S.current
	S.current = nil
	local player = Inst.make("Player", { name = name })
	local pd = D[player]
	Inst.rawSet(pd, "UserId", userId)
	Inst.rawSet(pd, "DisplayName", opts.displayName or name)
	Inst.rawSet(pd, "MembershipType", opts.membership or roblox.Enum.MembershipType.None)
	Inst.rawSet(pd, "AccountAge", opts.accountAge or 365)
	Inst.rawSet(pd, "LocaleId", "en-us")
	if type(opts.followUserId) == "number" then
		Inst.rawSet(pd, "FollowUserId", opts.followUserId)
	end
	if type(opts.joinMembers) == "table" then
		pd.extra.joinMembers = table.clone(opts.joinMembers)
	end
	ctx.player = player
	self.clientOf[player] = ctx
	table.insert(self.clients, ctx)
	table.insert(self.players, player)

	local playerGui = Inst.make("PlayerGui", { name = "PlayerGui" })
	D[playerGui].vis = ctx
	D[playerGui].serverVisible = true
	playerGui.Parent = player
	local playerScripts = Inst.make("PlayerScripts", { name = "PlayerScripts" })
	D[playerScripts].vis = ctx
	D[playerScripts].serverVisible = false
	playerScripts.Parent = player
	local backpack = Inst.make("Backpack", { name = "Backpack" })
	backpack.Parent = player
	local cam = Inst.make("Camera", { name = "Camera" })
	D[cam].vis = ctx
	D[cam].extra.ctx = ctx
	cam.Parent = self.workspace
	ctx.camera = cam
	player.Parent = players
	Inst.fireIf(D[players], "PlayerAdded", player)
	S.current = prev

	-- the client boots once it has "replicated": StarterPlayerScripts -> PlayerScripts
	local boot = coroutine.create(function()
		local sps = self.game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts")
		for _, child in sps:GetChildren() do
			local c = child:Clone()
			c.Parent = playerScripts
		end
		for _, x in playerScripts:GetDescendants() do
			if D[x].className == "LocalScript" then
				self:runScript(x, ctx)
			end
		end
		local starterGui = self.game:GetService("StarterGui")
		for _, g in starterGui:GetChildren() do
			local c = g:Clone()
			if c then
				c.Parent = playerGui
			end
		end
	end)
	S.threadCtx[boot] = ctx
	S:schedule(boot, S.now + (opts.bootDelay or 0.1))

	local players2 = self.game:GetService("Players")
	if rawGet(D[players2], "CharacterAutoLoads") then
		local co = coroutine.create(function()
			if D[player].parent then
				self:spawnCharacter(player)
			end
		end)
		S:schedule(co, S.now + (opts.characterDelay or 0.3))
	end
	return player, ctx
end

local function findSpawn(root: any): any
	for _, x in root:GetDescendants() do
		local d = D[x]
		if d.className == "SpawnLocation" and rawGet(d, "Enabled") ~= false then
			return x
		end
	end
	return nil
end

function Runtime:spawnCharacter(player: any)
	local S = self.S
	local prev = S.current
	S.current = nil
	local pd = D[player]
	local old = rawGet(pd, "Character")
	if old then
		Inst.fireIf(pd, "CharacterRemoving", old)
		Inst.destroy(D[old])
		-- ScreenGuis with ResetOnSpawn = true are removed when the character respawns
		local gui = Inst.findVisibleChild(pd, "PlayerGui", self.clientOf[player])
		if gui then
			for _, g in table.clone(D[gui].children) do
				local gd = D[g]
				if gd.cls.isA.LayerCollector and rawGet(gd, "ResetOnSpawn") then
					Inst.destroy(gd)
				end
			end
		end
	end
	local model = Inst.make("Model", { name = pd.name })
	local hrp = Inst.make("Part", { name = "HumanoidRootPart" })
	hrp.Size = roblox.Vector3.new(2, 2, 1)
	hrp.Transparency = 1
	hrp.CanCollide = false
	local head = Inst.make("Part", { name = "Head" })
	head.Size = roblox.Vector3.new(2, 1, 1)
	local torso = Inst.make("Part", { name = "UpperTorso" })
	torso.Size = roblox.Vector3.new(2, 2, 1)
	local hum = Inst.make("Humanoid", { name = "Humanoid" })
	local animator = Inst.make("Animator", { name = "Animator" })
	animator.Parent = hum
	local spawn = findSpawn(self.workspace)
	local pos = if spawn then spawn.Position + roblox.Vector3.new(0, 4, 0) else roblox.Vector3.new(0, 10, 0)
	hrp.CFrame = roblox.CFrame.new(pos)
	head.CFrame = roblox.CFrame.new(pos + roblox.Vector3.new(0, 1.5, 0))
	torso.CFrame = roblox.CFrame.new(pos)
	hrp.Parent = model
	torso.Parent = model
	head.Parent = model
	hum.Parent = model
	-- Roblox's default character scripts (no source: never run here)
	local health = Inst.make("Script", { name = "Health" })
	health.Parent = model
	local animate = Inst.make("LocalScript", { name = "Animate" })
	animate.Parent = model
	model.PrimaryPart = hrp
	model.Archivable = false
	pd.extra.appearanceLoaded = false
	Inst.rawSet(pd, "Character", model)
	Inst.fireIf(pd, "CharacterAdded", model)
	model.Parent = self.workspace
	S.current = prev
	local co = coroutine.create(function()
		if rawGet(pd, "Character") == model then
			pd.extra.appearanceLoaded = true
			Inst.fireIf(pd, "CharacterAppearanceLoaded", model)
		end
	end)
	S:schedule(co, S.now + 0.2)
	return model
end

function Runtime:onHumanoidDied(hd: any)
	local players = self.game:GetService("Players")
	if not rawGet(D[players], "CharacterAutoLoads") then
		return
	end
	for _, player in self.players do
		local char = rawGet(D[player], "Character")
		if char and hd.parent == char then
			local delay = rawGet(D[players], "RespawnTime")
			local co = coroutine.create(function()
				if rawGet(D[player], "Character") == char and D[player].parent then
					self:spawnCharacter(player)
				end
			end)
			self.S:schedule(co, self.S.now + (delay or 5))
		end
	end
end

function Runtime:removePlayer(player: any)
	local S = self.S
	local pd = D[player]
	if not pd.parent then
		return
	end
	local players = self.game:GetService("Players")
	local prev = S.current
	S.current = nil
	Inst.fireIf(D[players], "PlayerRemoving", player)
	local char = rawGet(pd, "Character")
	if char then
		Inst.fireIf(pd, "CharacterRemoving", char)
		Inst.destroy(D[char])
	end
	player.Parent = nil
	S.current = prev
	local ctx = self.clientOf[player]
	if ctx then
		ctx.dead = true
		if ctx.camera then
			Inst.destroy(D[ctx.camera])
		end
	end
	local i = table.find(self.players, player)
	if i then
		table.remove(self.players, i)
	end
	self.walkers[player] = nil
end

function Runtime:kick(player: any, message: any)
	table.insert(self.kicks, { userId = rawGet(D[player], "UserId"), message = tostring(message) })
	self.S:recordWarning(self.S.current, "KICK " .. D[player].name .. ": " .. tostring(message))
	local co = coroutine.create(function()
		self:removePlayer(player)
	end)
	self.S:defer(co)
end

function Runtime:mouseFor(player: any): any
	local m = self.mice[player]
	if m then
		return m
	end
	local Vector3, CFrame = roblox.Vector3, roblox.CFrame
	local sigs = {}
	for _, n in
		{
			"Button1Down",
			"Button1Up",
			"Button2Down",
			"Button2Up",
			"Move",
			"WheelForward",
			"WheelBackward",
			"Idle",
		}
	do
		local _, sd = Signal.new(n)
		sigs[n] = sd
	end
	local fields = {
		Hit = CFrame.new(Vector3.zero),
		Target = nil,
		X = 640,
		Y = 360,
		Icon = "",
		UnitRay = roblox.Ray.new(Vector3.zero, Vector3.new(0, -1, 0)),
	}
	m = Core.proxy("Instance", function(_, k)
		if sigs[k] then
			return sigs[k].proxy
		end
		if
			k == "Hit"
			or k == "Target"
			or k == "X"
			or k == "Y"
			or k == "Icon"
			or k == "UnitRay"
			or k == "TargetFilter"
		then
			return fields[k]
		end
		error(tostring(k) .. " is not a valid member of PlayerMouse", 2)
	end, function(_, k, v)
		fields[k] = v
	end)
	self.mice[player] = m
	return m
end

-- Shutdown (BindToClose) -----------------------------------------------------------------------------

function Runtime:shutdown(timeout: number?)
	local S = self.S
	local remaining = #self.closeCallbacks
	for _, cb in self.closeCallbacks do
		S:dispatch(function()
			cb.fn()
			remaining -= 1
		end, cb.ctx, false)
	end
	S:runUntil(function()
		return remaining <= 0
	end, timeout or 30)
	return remaining <= 0
end

-- Driving helpers for specs ----------------------------------------------------------------------------

function Runtime:step()
	self.S:step()
end

function Runtime:advance(seconds: number)
	self.S:advance(seconds)
end

function Runtime:runUntil(pred: () -> any, timeout: number): any
	return self.S:runUntil(pred, timeout)
end

-- Runs fn in ctx's context as a script thread; returns its results if it finished
-- without yielding.
function Runtime:runIn(ctx: any, fn: (...any) -> ...any, ...: any): ...any
	local S = self.S
	local results
	S:dispatch(function(...)
		results = table.pack(fn(...))
	end, ctx, false, ...)
	S:flushDeferred()
	if results then
		return table.unpack(results, 1, results.n)
	end
	return nil
end

-- Requires a module inside a context (the cached instance the scripts use).
function Runtime:require(ctx: any, inst: any): any
	local S = self.S
	local prev = S.current
	S.current = ctx
	local co = coroutine.create(function()
		return self:requireModule(inst, ctx)
	end)
	S.threadCtx[co] = ctx
	local ok, v = coroutine.resume(co)
	S.current = prev
	if not ok then
		error(v, 0)
	end
	if coroutine.status(co) ~= "dead" then
		error("module yielded while being required from the test driver", 0)
	end
	return v
end

-- Finds an instance by dotted path from game ("ServerScriptService.Server.Services.RunDirector").
function Runtime:find(path: string, ctx: any?): any
	local cur = self.game
	for _, seg in string.split(path, ".") do
		cur = cur and Inst.findVisibleChild(D[cur], seg, ctx)
	end
	return cur
end

function Runtime:serverModule(path: string): any
	local inst = self:find(path)
	assert(inst, "no instance at " .. path)
	return self:require(self.server, inst)
end

function Runtime:clientModule(client: any, relPath: string): any
	local ps = Inst.findVisibleChild(D[client.player], "PlayerScripts", client)
	local cur = ps
	for _, seg in string.split(relPath, ".") do
		cur = cur and Inst.findVisibleChild(D[cur], seg, client)
	end
	assert(cur, "no client module at PlayerScripts." .. relPath)
	return self:require(client, cur)
end

function Runtime:playerGui(client: any): any
	return Inst.findVisibleChild(D[client.player], "PlayerGui", client)
end

-- Is this GUI object actually on screen for its client?
function Runtime:isShown(inst: any): boolean
	local d = D[inst]
	while d do
		if d.destroyed then
			return false
		end
		if d.cls.props.Visible and rawGet(d, "Visible") == false then
			return false
		end
		if d.className == "ScreenGui" then
			return rawGet(d, "Enabled") ~= false and d.parent ~= nil and D[d.parent].className == "PlayerGui"
		end
		d = d.parent and D[d.parent]
	end
	return false
end

-- All GuiButtons on screen for a client whose Text (or a descendant label's Text)
-- matches `pattern`.
function Runtime:findButtons(client: any, pattern: string): { any }
	local out = {}
	local gui = self:playerGui(client)
	if not gui then
		return out
	end
	local S = self.S
	local prev = S.current
	S.current = client
	for _, x in gui:GetDescendants() do
		local d = D[x]
		if d.cls.isA.GuiButton and self:isShown(x) then
			local texts = {}
			if d.cls.props.Text then
				table.insert(texts, rawGet(d, "Text"))
			end
			for _, y in x:GetDescendants() do
				local yd = D[y]
				if yd.cls.props.Text then
					table.insert(texts, rawGet(yd, "Text"))
				end
			end
			for _, t in texts do
				if string.find(string.lower(t), string.lower(pattern)) then
					table.insert(out, x)
					break
				end
			end
		end
	end
	S.current = prev
	return out
end

-- Simulates a click/tap on a GuiButton in the client's context.
function Runtime:click(client: any, button: any)
	local d = D[button]
	assert(d.cls.isA.GuiButton, "not a GuiButton: " .. Inst.fullName(d))
	if rawGet(d, "Active") == false and d.cls.props.Active then
		-- Roblox still fires Activated for inactive buttons? No: Active=false buttons ignore input.
		return false
	end
	local S = self.S
	local input = self:inputObject(client, {
		UserInputType = roblox.Enum.UserInputType.MouseButton1,
		UserInputState = roblox.Enum.UserInputState.End,
	})
	local prev = S.current
	S.current = client
	for _, n in { "MouseButton1Down", "MouseButton1Up", "MouseButton1Click" } do
		local sd = d.sig[n]
		if sd then
			Signal.fire(sd, client, true)
		end
	end
	local sd = d.sig.Activated
	if sd then
		Signal.fire(sd, client, true, input, 1)
	end
	S.current = prev
	S:flushDeferred()
	return true
end

function Runtime:inputObject(client: any, props: { [string]: any }): any
	local S = self.S
	local prev = S.current
	S.current = client
	local io = Inst.make("InputObject")
	S.current = prev
	local d = D[io]
	for k, v in props do
		Inst.rawSet(d, k, v)
	end
	return io
end

-- Fires a UserInputService event (InputBegan/InputEnded/...) on one client.
function Runtime:input(client: any, eventName: string, props: { [string]: any }, processed: boolean?)
	local uis = self.game:GetService("UserInputService")
	local io = self:inputObject(client, props)
	local sd = Inst.getSig(D[uis], eventName)
	Signal.fire(sd, client, true, io, processed == true)
	self.S:flushDeferred()
end

-- Invokes a ContextActionService action bound by a client.
function Runtime:action(client: any, name: string, state: any?, props: { [string]: any }?)
	local a = client.actions[name]
	assert(a, "no action bound: " .. name)
	local io = self:inputObject(client, props or {})
	self.S:dispatch(a.fn, client, false, name, state or roblox.Enum.UserInputState.Begin, io)
	self.S:flushDeferred()
end

-- Moves a player's character like a client walking: `targetFn(now) -> Vector3?`
-- gives the point to walk toward; speed is capped at the Humanoid's WalkSpeed.
function Runtime:setWalker(player: any, targetFn: ((now: number, pos: any) -> any)?)
	self.walkers[player] = if targetFn then { target = targetFn } else nil
end

-- Network conditions for one player's character replication (client -> server):
-- { rate = updates/s, latency = s, jitter = s, freezeEvery = s, freezeFor = s, seed }.
-- The walker moves the CLIENT's copy every frame; the shared HumanoidRootPart (what
-- the server reads) only follows at replication ticks, late and in bursts.
function Runtime:setNetConditions(player: any, cond: { [string]: any }?)
	local w = self.walkers[player]
	assert(w, "setWalker first")
	w.net = cond
	w.history = {}
	w.clientCF = nil
	w.nextTick = 0
	w.frozenUntil = 0
	w.nextFreeze = if cond and cond.freezeEvery then self.S.now + cond.freezeEvery else math.huge
	w.rng = if cond then Datatypes.Random.new(cond.seed or 1) else nil
end

function Runtime:replicate(walker: any, char: any, cf: any)
	local net = walker.net
	if not net then
		Inst.reg(Inst.METHODS, "Model").PivotTo(char, cf)
		return
	end
	if walker.lastApplied == nil then
		local hrp = Inst.findVisibleChild(D[char], "HumanoidRootPart", nil)
		walker.lastApplied = if hrp then rawGet(D[hrp], "CFrame").Position else nil
	end
	local S = self.S
	table.insert(walker.history, { t = S.now, cf = cf })
	if #walker.history > 600 then
		table.remove(walker.history, 1)
	end
	if S.now >= walker.nextFreeze then
		walker.frozenUntil = S.now + (net.freezeFor or 0.8)
		walker.nextFreeze = S.now + (net.freezeEvery or math.huge)
	end
	if S.now < walker.frozenUntil or S.now < walker.nextTick then
		return
	end
	walker.nextTick = S.now + 1 / (net.rate or 20)
	local lag = (net.latency or 0.1) + walker.rng:NextNumber(0, net.jitter or 0)
	-- physics replication never applies an older state after a newer one
	local want = math.max(S.now - lag, walker.lastWant or -math.huge)
	walker.lastWant = want
	local pick = nil
	for i = #walker.history, 1, -1 do
		if walker.history[i].t <= want then
			pick = walker.history[i]
			break
		end
	end
	if pick then
		Inst.reg(Inst.METHODS, "Model").PivotTo(char, pick.cf)
		local hrp = Inst.findVisibleChild(D[char], "HumanoidRootPart", nil)
		walker.lastApplied = if hrp then rawGet(D[hrp], "CFrame").Position else nil
	end
end

function Runtime:stepWalker(player: any, walker: any, dt: number)
	local char = rawGet(D[player], "Character")
	if not char or D[char].destroyed then
		return
	end
	local hrp = Inst.findVisibleChild(D[char], "HumanoidRootPart", nil)
	local hum = Inst.findVisibleChild(D[char], "Humanoid", nil)
	if not hrp or not hum then
		return
	end
	local hrpd, humd = D[hrp], D[hum]
	local serverCF = rawGet(hrpd, "CFrame")
	local serverPos = serverCF.Position
	-- with net conditions the client walks its own copy; when the SERVER moved the
	-- character (teleport, MoveGuard snap) the client accepts it and drops its history
	local pos = serverPos
	if walker.net and walker.clientCF then
		if walker.lastApplied and (serverPos - walker.lastApplied).Magnitude > 0.01 then
			walker.clientCF = serverCF
			walker.history = {}
			walker.lastWant = self.S.now
			walker.lastApplied = serverPos
		end
		pos = walker.clientCF.Position
	end
	local target = walker.target(self.S.now, pos)
	if not target then
		Inst.rawSet(humd, "MoveDirection", roblox.Vector3.zero)
		return
	end
	local flat = roblox.Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
	local dist = flat.Magnitude
	local speed = rawGet(humd, "WalkSpeed") * (walker.speedFactor or 0.9)
	if dist < 0.05 or speed <= 0 then
		Inst.rawSet(humd, "MoveDirection", roblox.Vector3.zero)
		return
	end
	local stepLen = math.min(dist, speed * dt)
	local dir = flat.Unit
	local newPos = pos + dir * stepLen
	local cf = roblox.CFrame.lookAt(newPos, newPos + dir)
	walker.clientCF = cf
	self:replicate(walker, char, cf)
	Inst.rawSet(humd, "MoveDirection", dir)
end

-- Reporting -----------------------------------------------------------------------------------------

-- What the server did to Workspace.Terrain (fill counts per method/material,
-- bounds, colours): tests/runtime/Classes.luau keeps no voxel grid.
function Runtime:terrainStats(): any
	local t = self.workspace:FindFirstChildOfClass("Terrain")
	return if t then Classes.terrainStats(t) else nil
end

function Runtime:errors(): { any }
	return self.S.errors
end

function Runtime:gaps(): { string }
	return self.S.gaps
end

-- Warnings not matching any allowed pattern.
function Runtime:unexpectedWarnings(allow: { string }?): { any }
	local out = {}
	for _, w in self.S.warnings do
		local ok = false
		for _, pat in allow or {} do
			if string.find(w.message, pat) then
				ok = true
				break
			end
		end
		if not ok then
			table.insert(out, w)
		end
	end
	return out
end

function Runtime:report(allow: { string }?): string
	local lines = {}
	for _, e in self.S.errors do
		table.insert(lines, string.format("ERROR [%s] %s\n%s", e.ctx, e.message, e.traceback))
	end
	for _, g in self.S.gaps do
		table.insert(lines, "GAP " .. g)
	end
	for _, w in self:unexpectedWarnings(allow) do
		table.insert(lines, string.format("WARN [%s] %s", w.ctx, w.message))
	end
	return table.concat(lines, "\n")
end

-- Asserts: zero script errors, zero emulator gaps, no unexpected warnings.
function Runtime:assertClean(allow: { string }?, label: string?)
	local errs = #self.S.errors
	local gaps = #self.S.gaps
	local warns = #self:unexpectedWarnings(allow)
	if errs + gaps + warns > 0 then
		error(
			string.format(
				"%s: %d script error(s), %d emulator gap(s), %d unexpected warning(s)\n%s",
				label or "runtime",
				errs,
				gaps,
				warns,
				self:report(allow)
			),
			2
		)
	end
end

-- Pre-seeds a DataStore key (e.g. a veteran profile) before anyone reads it.
function Runtime:seedDataStore(storeName: string, key: string, value: any)
	Services.validateStored(value, key)
	local id = "global:" .. storeName
	local s = self.dataStores[id]
	if not s then
		s = { name = storeName, ordered = false, entries = {}, log = {} }
		self.dataStores[id] = s
	end
	s.entries[key] = { version = 1, created = 0, updated = 0, value = Services.deepCopy(value) }
end

function Runtime:dataStoreValue(storeName: string, key: string): any
	local s = self.dataStores["global:" .. storeName]
	local e = s and s.entries[key]
	return if e then Services.deepCopy(e.value) else nil
end

-- Calls MarketplaceService.ProcessReceipt like Roblox does (in a server thread);
-- returns the decision once the callback finishes.
function Runtime:processReceipt(receipt: { [string]: any }, timeout: number?): any
	local mps = self.game:GetService("MarketplaceService")
	local cbs = D[mps].extra.callbacks and D[mps].extra.callbacks.ProcessReceipt
	local entry
	for _, e in cbs or {} do
		entry = e
	end
	assert(entry and entry.fn, "ProcessReceipt is not set")
	local done, decision = false, nil
	self.S:dispatch(function()
		decision = entry.fn(receipt)
		done = true
	end, entry.ctx, false)
	self:runUntil(function()
		return done
	end, timeout or 60)
	assert(done, "ProcessReceipt did not return")
	return decision
end

return Runtime
