-- Lightweight Instance emulation backed by Lune's Roblox reflection database.
--
-- * Properties: every property the reflection database knows for the class (and
--   its superclasses) can be read and written. Reads return the stored value, a
--   computed value (Position from CFrame, AbsoluteSize, LocalPlayer, ...) or the
--   class default. Writes are type-checked against the property's datatype, and
--   read-only properties refuse writes, as in Roblox.
-- * Unknown members: a name that is not a property, an emulated method/event or a
--   (visible) child raises "X is not a valid member of Class "Full.Name"", exactly
--   like Roblox, and is also recorded as a possible EMULATOR GAP for triage.
-- * Visibility: an instance created by a client exists only for that client, and
--   children of ServerScriptService/ServerStorage are invisible to clients.

local roblox = require("@lune/roblox")
local Core = require("./Core")
local Signal = require("./Signal")

local Vector3 = roblox.Vector3
local Vector2 = roblox.Vector2
local CFrame = roblox.CFrame
local Color3 = roblox.Color3
local UDim2 = roblox.UDim2
local UDim = roblox.UDim
local Enum = roblox.Enum

local NIL = Core.NIL
local typeOf = Core.typeof
local db = roblox.getReflectionDatabase()

local Inst = {}

export type Data = {
	proxy: any,
	cls: any,
	className: string,
	name: string,
	parent: any,
	children: { any },
	props: { [string]: any },
	attrs: { [string]: any },
	tags: { [string]: boolean },
	sig: { [string]: any },
	propSig: { [string]: any },
	attrSig: { [string]: any },
	vis: any,
	serverVisible: boolean,
	parentLocked: boolean,
	destroyed: boolean,
	extra: { [string]: any },
	overlay: { [any]: { [string]: any } }?,
	attrOverlay: { [any]: { [string]: any } }?,
}

local D: { [any]: Data } = {}
Inst.D = D

-- Class behaviour registries (filled here and by Services.luau) -----------------------

Inst.METHODS = {} :: { [string]: { [string]: any } }
Inst.EVENTS = {} :: { [string]: { [string]: any } } -- [class][event] = opts table or true
Inst.GETTERS = {} :: { [string]: { [string]: any } }
Inst.SETTERS = {} :: { [string]: { [string]: any } }
Inst.CALLBACKS = {} :: { [string]: { [string]: any } } -- [class][name] = { serverOnly?, clientOnly? }
Inst.EXTRA_PROPS = {} :: { [string]: { [string]: any } } -- props missing from the database
Inst.DEFAULTS = {} :: { [string]: { [string]: any } } -- default overrides
Inst.ON_CREATE = {} :: { [string]: (Data) -> () }

local function reg(tbl, cls)
	local t = tbl[cls]
	if not t then
		t = {}
		tbl[cls] = t
	end
	return t
end
Inst.reg = reg

-- Reflection ------------------------------------------------------------------------------

local classCache: { [string]: any } = {}

local function dbClass(name: string): any
	local ok, c = pcall(db.GetClass, db, name)
	if ok then
		return c
	end
	return nil
end

local function fallbackDefault(dt: string?): any
	if dt == nil then
		return nil
	elseif dt == "Bool" then
		return false
	elseif dt == "String" or dt == "Content" or dt == "ContentId" or dt == "BinaryString" then
		return ""
	elseif dt == "Float32" or dt == "Float64" or dt == "Int32" or dt == "Int64" then
		return 0
	elseif dt == "Vector3" then
		return Vector3.zero
	elseif dt == "Vector2" then
		return Vector2.zero
	elseif dt == "CFrame" or dt == "OptionalCFrame" then
		return CFrame.identity
	elseif dt == "Color3" or dt == "Color3uint8" then
		return Color3.new(0, 0, 0)
	elseif dt == "UDim2" then
		return UDim2.new()
	elseif dt == "UDim" then
		return UDim.new()
	elseif dt == "NumberRange" then
		return roblox.NumberRange.new(0)
	elseif dt == "NumberSequence" then
		return roblox.NumberSequence.new(0)
	elseif dt == "ColorSequence" then
		return roblox.ColorSequence.new(Color3.new(1, 1, 1))
	elseif dt == "Rect" then
		return roblox.Rect.new(0, 0, 0, 0)
	elseif dt == "Font" then
		return roblox.Font.new("rbxasset://fonts/families/LegacyArial.json")
	elseif string.sub(dt, 1, 5) == "Enum." then
		local ok, e = pcall(function()
			return (Enum :: any)[string.sub(dt, 6)]
		end)
		if ok and e then
			local items = e:GetEnumItems()
			table.sort(items, function(a, b)
				return a.Value < b.Value
			end)
			return items[1]
		end
	end
	return nil
end

local function classDesc(name: string): any
	local cached = classCache[name]
	if cached then
		return cached
	end
	local c = dbClass(name)
	if not c then
		return nil
	end
	local chain = {}
	local x = c
	while x do
		table.insert(chain, x.Name)
		x = if x.Superclass then dbClass(x.Superclass) else nil
	end
	local desc = {
		name = name,
		chain = chain,
		isA = {},
		props = {},
		defaults = {},
		methods = {},
		events = {},
		getters = {},
		setters = {},
		callbacks = {},
		tags = {},
		notScriptable = {},
	}
	for _, t in c.Tags do
		desc.tags[t] = true
	end
	for _, n in chain do
		desc.isA[n] = true
	end
	-- most-derived wins: walk from the root down
	for i = #chain, 1, -1 do
		local cn = chain[i]
		local cc = dbClass(cn)
		if cc then
			for pname, prop in cc.Properties do
				if prop.Scriptability == "None" then
					-- In the database but not scriptable on Roblox (Terrain.Decoration,
					-- Lighting.Technology's write, ...): scripts get Roblox's error, and
					-- it is NOT an emulator gap.
					desc.notScriptable[pname] = true
				else
					local tags = {}
					for _, t in prop.Tags do
						tags[t] = true
					end
					desc.props[pname] = {
						dt = prop.Datatype,
						readOnly = tags.ReadOnly == true or prop.Scriptability == "Read",
						deprecated = tags.Deprecated == true,
					}
				end
			end
		end
		for pname, info in Inst.EXTRA_PROPS[cn] or {} do
			desc.props[pname] = info
		end
		for k, v in Inst.METHODS[cn] or {} do
			desc.methods[k] = v
		end
		for k, v in Inst.EVENTS[cn] or {} do
			desc.events[k] = v
		end
		for k, v in Inst.GETTERS[cn] or {} do
			desc.getters[k] = v
		end
		for k, v in Inst.SETTERS[cn] or {} do
			desc.setters[k] = v
		end
		for k, v in Inst.CALLBACKS[cn] or {} do
			desc.callbacks[k] = v
		end
	end
	for pname, v in c.DefaultProperties do
		desc.defaults[pname] = v
	end
	for i = #chain, 1, -1 do
		for k, v in Inst.DEFAULTS[chain[i]] or {} do
			desc.defaults[k] = v
		end
	end
	for pname, info in desc.props do
		if desc.defaults[pname] == nil then
			local v = fallbackDefault(info.dt)
			if v ~= nil then
				desc.defaults[pname] = v
			end
		end
	end
	classCache[name] = desc
	return desc
end
Inst.classDesc = classDesc

function Inst.classIsA(className: string, other: string): boolean
	local desc = classDesc(className)
	return desc ~= nil and desc.isA[other] == true
end

-- Visibility -------------------------------------------------------------------------------

local function visibleTo(cd: Data, ctx: any): boolean
	local vis = cd.vis
	if vis ~= nil then
		if ctx == nil or ctx.isServer then
			return cd.serverVisible
		end
		return vis == ctx
	end
	if ctx ~= nil and ctx.isClient then
		local pd = cd.parent and D[cd.parent]
		if pd and pd.extra.serverContainer then
			return false
		end
	end
	return true
end
Inst.visibleTo = visibleTo

function Inst.isVisible(inst: any, ctx: any): boolean
	local d = D[inst]
	if not d then
		return true
	end
	-- visible only if the whole ancestry is visible
	while d do
		if not visibleTo(d, ctx) then
			return false
		end
		d = d.parent and D[d.parent]
	end
	return true
end

-- Type checking for property writes --------------------------------------------------------

local NUMERIC = { Float32 = true, Float64 = true, Int32 = true, Int64 = true }

local function coerce(dt: string?, v: any): (boolean, any)
	if dt == nil then
		return true, v
	end
	local tv = typeOf(v)
	if NUMERIC[dt] then
		if tv == "number" then
			if (dt == "Int32" or dt == "Int64") and v == v and v ~= math.huge and v ~= -math.huge then
				return true, if v >= 0 then math.floor(v) else math.ceil(v)
			end
			return true, v
		end
		if tv == "string" and tonumber(v) then
			return true, tonumber(v)
		end
		return false, nil
	elseif dt == "Bool" then
		if tv == "boolean" then
			return true, v
		end
		if v == nil then
			return true, false
		end
		return false, nil
	elseif dt == "String" or dt == "Content" or dt == "ContentId" then
		if tv == "string" then
			return true, v
		elseif tv == "number" then
			return true, tostring(v)
		end
		return false, nil
	elseif dt == "Ref" then
		if v == nil or tv == "Instance" then
			return true, v
		end
		return false, nil
	elseif dt == "Color3uint8" then
		return tv == "Color3", v
	elseif dt == "OptionalCFrame" then
		return v == nil or tv == "CFrame", v
	elseif string.sub(dt, 1, 5) == "Enum." then
		local enumName = string.sub(dt, 6)
		if tv == "EnumItem" then
			return tostring(v.EnumType) == "Enum." .. enumName or tostring(v.EnumType) == enumName, v
		end
		local okE, e = pcall(function()
			return (Enum :: any)[enumName]
		end)
		if not okE or not e then
			return true, v
		end
		for _, item in e:GetEnumItems() do
			if (tv == "number" and item.Value == v) or (tv == "string" and item.Name == v) then
				return true, item
			end
		end
		return false, nil
	elseif
		dt == "Vector3"
		or dt == "Vector2"
		or dt == "CFrame"
		or dt == "Color3"
		or dt == "UDim2"
		or dt == "UDim"
		or dt == "NumberRange"
		or dt == "NumberSequence"
		or dt == "ColorSequence"
		or dt == "Rect"
		or dt == "Font"
		or dt == "BrickColor"
	then
		if tv == dt then
			return true, v
		end
		if dt == "NumberSequence" and tv == "number" then
			return false, nil
		end
		return false, nil
	end
	return true, v
end

-- Helpers ----------------------------------------------------------------------------------

local function fullName(d: Data): string
	local parts = { d.name }
	local p = d.parent
	while p do
		local pd = D[p]
		if pd.className == "DataModel" then
			break
		end
		table.insert(parts, 1, pd.name)
		p = pd.parent
	end
	return table.concat(parts, ".")
end
Inst.fullName = fullName

local function getSig(d: Data, name: string): any
	local s = d.sig[name]
	if s then
		return s
	end
	local opts = d.cls.events[name]
	local o = if type(opts) == "table" then opts else {}
	local proxyOpts = { engine = o.engine, guard = o.guard, onConnect = nil, filter = nil }
	if o.makeOpts then
		for k, v in o.makeOpts(d) do
			proxyOpts[k] = v
		end
	end
	if o.instanceArg then
		-- ChildAdded and friends: a context only hears about instances it can see.
		proxyOpts.filter = function(ctx, inst)
			return Inst.isVisible(inst, ctx)
		end
	end
	local _, sd = Signal.new(name, proxyOpts)
	d.sig[name] = sd
	return sd
end
Inst.getSig = getSig

local function fireIf(d: Data, name: string, ...: any)
	local sd = d.sig[name]
	if sd then
		Signal.fire(sd, nil, nil, ...)
	end
end
Inst.fireIf = fireIf

local function firePropChanged(d: Data, prop: string)
	local sd = d.sig.Changed
	if sd then
		if d.cls.isA.ValueBase and prop == "Value" then
			Signal.fire(sd, nil, nil, d.props.Value)
		elseif not d.cls.isA.ValueBase then
			Signal.fire(sd, nil, nil, prop)
		end
	end
	local ps = d.propSig[prop]
	if ps then
		Signal.fire(ps, nil, nil)
	end
end
Inst.firePropChanged = firePropChanged

-- Client-local changes to server-owned instances do not replicate in Roblox: they
-- live in a per-client overlay that only that client reads.
Inst.overlayCtx = nil :: any

local function rawGet(d: Data, k: string): any
	local ov = d.overlay
	if ov then
		local o = ov[Core.S.current]
		if o then
			local x = o[k]
			if x ~= nil then
				return if x == NIL then nil else x
			end
		end
	end
	local v = d.props[k]
	if v == nil then
		return d.cls.defaults[k]
	elseif v == NIL then
		return nil
	end
	return v
end
Inst.rawGet = rawGet

-- Sets a property without checks; fires change signals when the value changed.
local function rawSet(d: Data, k: string, v: any)
	local old = rawGet(d, k)
	local octx = Inst.overlayCtx
	if octx then
		d.overlay = d.overlay or {}
		local o = d.overlay[octx]
		if not o then
			o = {}
			d.overlay[octx] = o
		end
		o[k] = if v == nil then NIL else v
		if old ~= v then
			local ps = d.propSig[k]
			if ps then
				Signal.fire(ps, octx, nil)
			end
			local sd = d.sig.Changed
			if sd and not d.cls.isA.ValueBase then
				Signal.fire(sd, octx, nil, k)
			end
		end
		return
	end
	d.props[k] = if v == nil then NIL else v
	if old ~= v then
		firePropChanged(d, k)
	end
end
Inst.rawSet = rawSet

local function hasAnyDescendantSignal(d: Data): boolean
	local p = d.parent
	while p do
		local pd = D[p]
		if pd.sig.DescendantAdded or pd.sig.DescendantRemoving then
			return true
		end
		p = pd.parent
	end
	return false
end

local function forEachDescendant(d: Data, fn: (Data) -> ())
	for _, c in d.children do
		local cd = D[c]
		fn(cd)
		forEachDescendant(cd, fn)
	end
end

local function isDescendantOf(d: Data, ancestor: any): boolean
	local p = d.parent
	while p do
		if p == ancestor then
			return true
		end
		p = D[p].parent
	end
	return false
end

local function setParent(d: Data, newParent: any)
	if d.parentLocked then
		error(
			string.format(
				"The Parent property of %s is locked, current parent: NULL, new parent %s",
				d.name,
				if newParent then D[newParent].name else "NULL"
			),
			3
		)
	end
	if newParent ~= nil and typeOf(newParent) ~= "Instance" then
		error("invalid argument #3 (Instance expected, got " .. typeOf(newParent) .. ")", 3)
	end
	if newParent == d.proxy then
		error("Attempt to set " .. fullName(d) .. " as its own parent", 3)
	end
	if newParent and isDescendantOf(D[newParent], d.proxy) then
		error(
			string.format(
				"Attempt to set parent of %s to %s would result in circular reference",
				fullName(d),
				fullName(D[newParent])
			),
			3
		)
	end
	local old = d.parent
	if old == newParent then
		return
	end
	local actx = Core.S and Core.S.current
	if actx and actx.isClient and d.vis == nil and old ~= nil then
		-- Roblox would do this only on that client; the emulator applies it to the shared tree
		Inst.noteClientLocal(actx, d, "REPARENT/DESTROY (applied globally by the emulator)")
	end
	if old then
		local od = D[old]
		if hasAnyDescendantSignal(d) then
			local p = old
			while p do
				local pd = D[p]
				if pd.sig.DescendantRemoving then
					Signal.fire(pd.sig.DescendantRemoving, nil, nil, d.proxy)
					forEachDescendant(d, function(x)
						Signal.fire(pd.sig.DescendantRemoving, nil, nil, x.proxy)
					end)
				end
				p = pd.parent
			end
		end
		local i = table.find(od.children, d.proxy)
		if i then
			table.remove(od.children, i)
		end
		fireIf(od, "ChildRemoved", d.proxy)
	end
	d.parent = newParent
	if newParent then
		table.insert(D[newParent].children, d.proxy)
	end
	-- AncestryChanged on self and all descendants
	fireIf(d, "AncestryChanged", d.proxy, newParent)
	forEachDescendant(d, function(x)
		fireIf(x, "AncestryChanged", d.proxy, newParent)
	end)
	firePropChanged(d, "Parent")
	if newParent then
		local nd = D[newParent]
		fireIf(nd, "ChildAdded", d.proxy)
		if hasAnyDescendantSignal(d) then
			local p = newParent
			while p do
				local pd = D[p]
				if pd.sig.DescendantAdded then
					Signal.fire(pd.sig.DescendantAdded, nil, nil, d.proxy)
					forEachDescendant(d, function(x)
						Signal.fire(pd.sig.DescendantAdded, nil, nil, x.proxy)
					end)
				end
				p = pd.parent
			end
		end
		-- WaitForChild waiters
		local waiters = nd.extra.childWaiters
		if waiters and waiters[d.name] then
			local list = waiters[d.name]
			waiters[d.name] = nil
			for _, w in list do
				if not w.done then
					w.done = true
					Core.S:defer(w.co, d.proxy)
				end
			end
		end
	end
	if Inst.onParented then
		Inst.onParented(d, old, newParent)
	end
end

-- Index / newindex ------------------------------------------------------------------------

local function memberError(d: Data, k: any, level: number): never
	if type(k) == "string" and d.cls.notScriptable[k] and not d.cls.props[k] then
		error(string.format("The current thread cannot access '%s' (lacking capability NotAccessible)", k), level + 1)
	end
	local msg = string.format('%s is not a valid member of %s "%s"', tostring(k), d.className, fullName(d))
	if type(k) == "string" and string.match(k, "^%u") then
		-- Could be a missing child (a real bug) or a Roblox method/event the emulator
		-- lacks. Record it so the spec can tell them apart.
		Core.S:recordGap(
			string.format("member %s.%s (not a property, emulated method/event, or child)", d.className, k)
		)
	end
	error(msg, level + 1)
end

local function findVisibleChild(d: Data, name: string, ctx: any): any
	for _, c in d.children do
		local cd = D[c]
		if cd.name == name and visibleTo(cd, ctx) then
			return c
		end
	end
	return nil
end
Inst.findVisibleChild = findVisibleChild

local function INDEX(p: any, k: any): any
	local d = D[p]
	local cls = d.cls
	if k == "Name" then
		return d.name
	elseif k == "Parent" then
		local par = d.parent
		if par and not visibleTo(D[par], Core.current()) then
			return nil
		end
		return par
	elseif k == "ClassName" then
		return d.className
	end
	local m = cls.methods[k]
	if m then
		return m
	end
	local g = cls.getters[k]
	if g then
		return g(d)
	end
	local pr = cls.props[k]
	if pr then
		return rawGet(d, k)
	end
	if cls.events[k] then
		return getSig(d, k).proxy
	end
	if cls.callbacks[k] then
		error(
			string.format(
				"%s is a callback member of %s; you can only set the callback value, get is not available",
				k,
				d.className
			),
			2
		)
	end
	if type(k) == "string" then
		local c = findVisibleChild(d, k, Core.current())
		if c then
			return c
		end
	end
	return memberError(d, k, 2)
end

local function NEWINDEX(p: any, k: any, v: any)
	local d = D[p]
	local cls = d.cls
	if k == "Parent" then
		setParent(d, v)
		return
	elseif k == "Name" then
		if type(v) ~= "string" then
			if type(v) == "number" then
				v = tostring(v)
			else
				error("invalid value for Name (string expected, got " .. typeOf(v) .. ")", 2)
			end
		end
		if d.name ~= v then
			d.name = v
			firePropChanged(d, "Name")
		end
		return
	end
	local cb = cls.callbacks[k]
	if cb then
		if v ~= nil and type(v) ~= "function" then
			error(string.format("%s must be a function or nil", k), 2)
		end
		local ctx = Core.current()
		if cb.serverOnly and ctx and ctx.isClient then
			error(k .. " can only be set on the server", 2)
		end
		if cb.clientOnly and ctx and ctx.isServer then
			error(k .. " can only be set on the client", 2)
		end
		d.extra.callbacks = d.extra.callbacks or {}
		d.extra.callbacks[k] = d.extra.callbacks[k] or {}
		d.extra.callbacks[k][ctx or "driver"] = { fn = v, ctx = ctx }
		return
	end
	local setter = cls.setters[k]
	local pr = cls.props[k]
	if not pr and not setter then
		if cls.getters[k] or cls.methods[k] or cls.events[k] then
			error(string.format("Unable to assign property %s. Property is read only", tostring(k)), 2)
		end
		memberError(d, k, 2)
	end
	if pr then
		if pr.readOnly and not setter then
			error(string.format("Unable to assign property %s. Property is read only", tostring(k)), 2)
		end
		local ok, cv = coerce(pr.dt, v)
		if not ok then
			error(
				string.format(
					"Unable to assign property %s. %s expected, got %s",
					tostring(k),
					tostring(pr.dt),
					typeOf(v)
				),
				2
			)
		end
		v = cv
	end
	local ctx = Core.S.current
	if ctx and ctx.isClient and d.vis == nil and not Inst.replicatesFromClient(d, k, ctx) then
		Inst.noteClientLocal(ctx, d, "property " .. tostring(k))
		Inst.overlayCtx = ctx
		local ok, err = pcall(function()
			if setter then
				setter(d, v)
			else
				rawSet(d, k, v)
			end
		end)
		Inst.overlayCtx = nil
		if not ok then
			error(err, 2)
		end
		return
	end
	if setter then
		setter(d, v)
	else
		rawSet(d, k, v)
	end
end

local PHYSICS_PROPS = {
	CFrame = true,
	Position = true,
	Orientation = true,
	Rotation = true,
	AssemblyLinearVelocity = true,
	AssemblyAngularVelocity = true,
	Velocity = true,
	MoveDirection = true,
	Jump = true,
	Sit = true,
}

-- Does a client write to this server-owned instance replicate? Only physics of the
-- client's own character (network ownership) does.
function Inst.replicatesFromClient(d: Data, k: string, ctx: any): boolean
	if not PHYSICS_PROPS[k] then
		return false
	end
	local player = ctx.player
	local char = player and rawGet(D[player], "Character")
	if not char then
		return false
	end
	local x = d.proxy
	while x do
		if x == char then
			return true
		end
		x = D[x].parent
	end
	return false
end

Inst.clientLocal = {} :: { [string]: number }
function Inst.noteClientLocal(_ctx: any, d: Data, what: string)
	local key = d.className .. " " .. what
	Inst.clientLocal[key] = (Inst.clientLocal[key] or 0) + 1
end

local function TOSTRING(p: any): string
	return D[p].name
end

-- Construction -----------------------------------------------------------------------------

local function make(className: string, opts: { [string]: any }?): any
	local cls = classDesc(className)
	if not cls then
		error('Unable to create an Instance of type "' .. tostring(className) .. '"', 3)
	end
	local p = Core.proxy("Instance", INDEX, NEWINDEX, TOSTRING)
	local ctx = Core.current()
	local d: Data = {
		proxy = p,
		cls = cls,
		className = className,
		name = className,
		parent = nil,
		children = {},
		props = {},
		attrs = {},
		tags = {},
		sig = {},
		propSig = {},
		attrSig = {},
		vis = if ctx and ctx.isClient then ctx else nil,
		serverVisible = false,
		parentLocked = false,
		destroyed = false,
		extra = {},
	}
	D[p] = d
	for i = #cls.chain, 1, -1 do
		local hook = Inst.ON_CREATE[cls.chain[i]]
		if hook then
			hook(d)
		end
	end
	if opts and opts.name then
		d.name = opts.name
	end
	return p
end
Inst.make = make

-- Instance.new: creatable classes only.
function Inst.new(className: any, parent: any?): any
	if type(className) ~= "string" then
		error("invalid argument #1 to 'new' (string expected, got " .. typeOf(className) .. ")", 2)
	end
	local cls = classDesc(className)
	if not cls or cls.tags.NotCreatable or cls.tags.Service then
		error('Unable to create an Instance of type "' .. className .. '"', 2)
	end
	local p = make(className)
	if parent ~= nil then
		p.Parent = parent
	end
	return p
end

function Inst.data(p: any): Data
	return D[p]
end

function Inst.is(p: any): boolean
	return D[p] ~= nil
end

-- Base methods ---------------------------------------------------------------------------

local M = reg(Inst.METHODS, "Instance")

local function self_(p: any, method: string): Data
	local d = D[p]
	if not d then
		error("Expected ':' not '.' calling member function " .. method, 3)
	end
	return d
end
Inst.self = self_

function M.FindFirstChild(p, name, recursive)
	local d = self_(p, "FindFirstChild")
	if type(name) ~= "string" then
		error("Argument 1 missing or nil", 2)
	end
	local ctx = Core.current()
	local c = findVisibleChild(d, name, ctx)
	if c or not recursive then
		return c
	end
	for _, child in d.children do
		local cd = D[child]
		if visibleTo(cd, ctx) then
			local r = M.FindFirstChild(child, name, true)
			if r then
				return r
			end
		end
	end
	return nil
end

function M.FindFirstChildOfClass(p, className)
	local d = self_(p, "FindFirstChildOfClass")
	local ctx = Core.current()
	for _, c in d.children do
		local cd = D[c]
		if cd.className == className and visibleTo(cd, ctx) then
			return c
		end
	end
	return nil
end

function M.FindFirstChildWhichIsA(p, className, recursive)
	local d = self_(p, "FindFirstChildWhichIsA")
	local ctx = Core.current()
	for _, c in d.children do
		local cd = D[c]
		if visibleTo(cd, ctx) then
			if cd.cls.isA[className] then
				return c
			end
		end
	end
	if recursive then
		for _, c in d.children do
			local cd = D[c]
			if visibleTo(cd, ctx) then
				local r = M.FindFirstChildWhichIsA(c, className, true)
				if r then
					return r
				end
			end
		end
	end
	return nil
end

function M.FindFirstDescendant(p, name)
	return M.FindFirstChild(p, name, true)
end

function M.FindFirstAncestor(p, name)
	local d = self_(p, "FindFirstAncestor")
	local a = d.parent
	while a do
		local ad = D[a]
		if ad.name == name then
			return a
		end
		a = ad.parent
	end
	return nil
end

function M.FindFirstAncestorOfClass(p, className)
	local d = self_(p, "FindFirstAncestorOfClass")
	local a = d.parent
	while a do
		local ad = D[a]
		if ad.className == className then
			return a
		end
		a = ad.parent
	end
	return nil
end

function M.FindFirstAncestorWhichIsA(p, className)
	local d = self_(p, "FindFirstAncestorWhichIsA")
	local a = d.parent
	while a do
		local ad = D[a]
		if ad.cls.isA[className] then
			return a
		end
		a = ad.parent
	end
	return nil
end

function M.GetChildren(p)
	local d = self_(p, "GetChildren")
	local ctx = Core.current()
	local out = {}
	for _, c in d.children do
		if visibleTo(D[c], ctx) then
			table.insert(out, c)
		end
	end
	return out
end
M.getChildren = M.GetChildren

function M.GetDescendants(p)
	local d = self_(p, "GetDescendants")
	local ctx = Core.current()
	local out = {}
	local function walk(x: Data)
		for _, c in x.children do
			local cd = D[c]
			if visibleTo(cd, ctx) then
				table.insert(out, c)
				walk(cd)
			end
		end
	end
	walk(d)
	return out
end

function M.IsA(p, className)
	local d = self_(p, "IsA")
	return d.cls.isA[className] == true
end

function M.IsDescendantOf(p, ancestor)
	local d = self_(p, "IsDescendantOf")
	if ancestor == nil then
		return false
	end
	return isDescendantOf(d, ancestor)
end

function M.IsAncestorOf(p, descendant)
	self_(p, "IsAncestorOf")
	if descendant == nil then
		return false
	end
	return isDescendantOf(D[descendant], p)
end

function M.GetFullName(p)
	return fullName(self_(p, "GetFullName"))
end

function M.WaitForChild(p, name, timeout)
	local d = self_(p, "WaitForChild")
	if type(name) ~= "string" then
		error("Argument 1 missing or nil", 2)
	end
	local S = Core.S
	local ctx = S.current
	local c = findVisibleChild(d, name, ctx)
	if c then
		return c
	end
	local co, isMain = coroutine.running()
	if isMain or not coroutine.isyieldable() then
		error(
			"WaitForChild cannot yield here (no script thread) waiting for " .. fullName(d) .. "." .. name,
			2
		)
	end
	local w = { co = co, done = false }
	local waiters = d.extra.childWaiters or {}
	d.extra.childWaiters = waiters
	waiters[name] = waiters[name] or {}
	table.insert(waiters[name], w)
	if type(timeout) == "number" then
		S:schedule(
			coroutine.create(function()
				if not w.done then
					w.done = true
					S:resume(co, nil)
				end
			end),
			S.now + timeout
		)
	else
		local full = fullName(d)
		S:schedule(
			coroutine.create(function()
				if not w.done then
					Core.S:recordWarning(
						ctx,
						string.format("Infinite yield possible on '%s:WaitForChild(\"%s\")'", full, name)
					)
				end
			end),
			S.now + 5
		)
	end
	-- a child may be added that this context can't see: keep waiting for a visible one
	while true do
		local got = S:yieldCurrent("WaitForChild")
		if got == nil then
			return nil
		end
		if D[got].parent == p and visibleTo(D[got], ctx) then
			return got
		end
		w.done = false
		waiters[name] = waiters[name] or {}
		table.insert(waiters[name], w)
	end
end

local function destroy(d: Data)
	if d.destroyed then
		return
	end
	fireIf(d, "Destroying")
	d.destroyed = true
	local kids = table.clone(d.children)
	for _, c in kids do
		destroy(D[c])
	end
	if d.parent then
		d.parentLocked = false
		setParent(d, nil)
	end
	d.parentLocked = true
	for _, sd in d.sig do
		Signal.disconnectAll(sd)
	end
	for _, sd in d.propSig do
		Signal.disconnectAll(sd)
	end
	for _, sd in d.attrSig do
		Signal.disconnectAll(sd)
	end
	if Inst.onDestroyed then
		Inst.onDestroyed(d)
	end
end
Inst.destroy = destroy

function M.Destroy(p)
	destroy(self_(p, "Destroy"))
end
M.destroy = M.Destroy
M.Remove = function(p)
	local d = self_(p, "Remove")
	setParent(d, nil)
end

function M.ClearAllChildren(p)
	local d = self_(p, "ClearAllChildren")
	for _, c in table.clone(d.children) do
		destroy(D[c])
	end
end

local REF_PROPS = { "PrimaryPart", "Part0", "Part1", "Attachment0", "Attachment1", "Adornee", "Value" }

function M.Clone(p)
	local root = self_(p, "Clone")
	if not rawGet(root, "Archivable") then
		return nil
	end
	local map = {}
	local function cloneData(d: Data): any
		local np = make(d.className)
		local nd = D[np]
		nd.name = d.name
		for k, v in d.props do
			nd.props[k] = v
		end
		for k, v in d.attrs do
			nd.attrs[k] = v
		end
		for k, v in d.tags do
			nd.tags[k] = v
		end
		if d.extra.source then
			nd.extra.source = d.extra.source
			nd.extra.path = d.extra.path
		end
		map[d.proxy] = np
		for _, c in d.children do
			local cd = D[c]
			if rawGet(cd, "Archivable") then
				local nc = cloneData(cd)
				D[nc].parent = np
				table.insert(nd.children, nc)
			end
		end
		return np
	end
	local np = cloneData(root)
	-- remap internal references (PrimaryPart, weld parts, ...)
	for old, new in map do
		local nd = D[new]
		for _, k in REF_PROPS do
			local v = nd.props[k]
			if v ~= nil and v ~= NIL and map[v] then
				nd.props[k] = map[v]
			end
		end
		local _ = old
	end
	return np
end

-- Attributes --------------------------------------------------------------------------------

local ATTR_TYPES = {
	["nil"] = true,
	boolean = true,
	number = true,
	string = true,
	UDim = true,
	UDim2 = true,
	BrickColor = true,
	Color3 = true,
	Vector2 = true,
	Vector3 = true,
	CFrame = true,
	NumberSequence = true,
	ColorSequence = true,
	NumberRange = true,
	Rect = true,
	Font = true,
	EnumItem = true,
}

function M.SetAttribute(p, name, value)
	local d = self_(p, "SetAttribute")
	if type(name) ~= "string" then
		error("Argument 1 missing or nil", 2)
	end
	if #name > 100 or not string.match(name, "^[%w_]+$") or string.sub(name, 1, 3) == "RBX" then
		error("Attribute name '" .. name .. "' is invalid", 2)
	end
	local t = typeOf(value)
	if not ATTR_TYPES[t] then
		error(t .. " is not a supported attribute type", 2)
	end
	local ctx = Core.S.current
	if ctx and ctx.isClient and d.vis == nil then
		-- client-side attribute on a server instance: local to that client
		Inst.noteClientLocal(ctx, d, "attribute " .. name)
		d.attrOverlay = d.attrOverlay or {}
		local o = d.attrOverlay[ctx] or {}
		d.attrOverlay[ctx] = o
		local old = M.GetAttribute(p, name)
		o[name] = if value == nil then NIL else value
		if old ~= value then
			local sd = d.sig.AttributeChanged
			if sd then
				Signal.fire(sd, ctx, nil, name)
			end
			local s = d.attrSig[name]
			if s then
				Signal.fire(s, ctx, nil)
			end
		end
		return
	end
	local old = d.attrs[name]
	d.attrs[name] = value
	if old ~= value then
		fireIf(d, "AttributeChanged", name)
		local s = d.attrSig[name]
		if s then
			Signal.fire(s, nil, nil)
		end
	end
end

function M.GetAttribute(p, name)
	local d = self_(p, "GetAttribute")
	local ov = d.attrOverlay
	if ov then
		local o = ov[Core.S.current]
		if o and o[name] ~= nil then
			return if o[name] == NIL then nil else o[name]
		end
	end
	return d.attrs[name]
end

function M.GetAttributes(p)
	local d = self_(p, "GetAttributes")
	local out = table.clone(d.attrs)
	local ov = d.attrOverlay
	local o = ov and ov[Core.S.current]
	for k, v in o or {} do
		out[k] = if v == NIL then nil else v
	end
	return out
end

function M.GetAttributeChangedSignal(p, name)
	local d = self_(p, "GetAttributeChangedSignal")
	local s = d.attrSig[name]
	if not s then
		local _, sd = Signal.new("AttributeChanged:" .. name)
		s = sd
		d.attrSig[name] = s
	end
	return s.proxy
end

function M.GetPropertyChangedSignal(p, prop)
	local d = self_(p, "GetPropertyChangedSignal")
	if
		prop ~= "Name"
		and prop ~= "Parent"
		and not d.cls.props[prop]
		and not d.cls.getters[prop]
		and not d.cls.setters[prop]
	then
		error(string.format("%s is not a valid property name.", tostring(prop)), 2)
	end
	local s = d.propSig[prop]
	if not s then
		local _, sd = Signal.new("PropertyChanged:" .. prop)
		s = sd
		d.propSig[prop] = s
	end
	return s.proxy
end

-- Tags (also used by CollectionService)
function M.AddTag(p, tag)
	local d = self_(p, "AddTag")
	if not d.tags[tag] then
		d.tags[tag] = true
		if Inst.onTag then
			Inst.onTag(d, tag, true)
		end
	end
end
function M.RemoveTag(p, tag)
	local d = self_(p, "RemoveTag")
	if d.tags[tag] then
		d.tags[tag] = nil
		if Inst.onTag then
			Inst.onTag(d, tag, false)
		end
	end
end
function M.HasTag(p, tag)
	return self_(p, "HasTag").tags[tag] == true
end
function M.GetTags(p)
	local out = {}
	for t in self_(p, "GetTags").tags do
		table.insert(out, t)
	end
	return out
end
function M.GetActor(_p)
	return nil
end
function M.GetDebugId(p)
	return tostring(p)
end

local E = reg(Inst.EVENTS, "Instance")
E.Changed = true
E.ChildAdded = { instanceArg = true }
E.ChildRemoved = { instanceArg = true }
E.DescendantAdded = { instanceArg = true }
E.DescendantRemoving = { instanceArg = true }
E.AncestryChanged = true
E.Destroying = true
E.AttributeChanged = true

return Inst
