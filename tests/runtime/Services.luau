-- In-memory service mocks: Players, RunService, Workspace/Camera, TweenService,
-- CollectionService, HttpService, DataStoreService, MessagingService,
-- MemoryStoreService, MarketplaceService, PolicyService, BadgeService,
-- TextChatService, TeleportService, GuiService, UserInputService,
-- ContextActionService, StarterGui, SocialService, AdService, Debris, ...
-- Test knobs live on `Core.rt.config` (see Runtime.luau).

local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local Core = require("./Core")
local Signal = require("./Signal")
local Inst = require("./Instance")
local Classes = require("./Classes")

local Vector3 = roblox.Vector3
local Vector2 = roblox.Vector2
local CFrame = roblox.CFrame
local Enum = roblox.Enum

local D = Inst.D
local reg = Inst.reg
local rawGet = Inst.rawGet
local typeOf = Core.typeof
local serverOnly, clientOnly = Classes.serverOnly, Classes.clientOnly

local Services = {}

local function methods(cls)
	return reg(Inst.METHODS, cls)
end
local function events(cls)
	return reg(Inst.EVENTS, cls)
end
local function getters(cls)
	return reg(Inst.GETTERS, cls)
end

-- Simulated latency of an async web call (DataStore, Marketplace, ...). Yields the
-- calling thread, so calling one from a non-yieldable place fails like on Roblox.
local function asyncCall(what: string)
	local S = Core.S
	local co, isMain = coroutine.running()
	if isMain or not coroutine.isyieldable() then
		error(what .. ": attempt to yield across metamethod/C-call boundary", 3)
	end
	local latency = Core.rt and Core.rt.config.asyncLatency or 0.05
	S:schedule(co, S.now + latency, "__wait")
	if S.threadCtx[co] == nil then
		S.threadCtx[co] = S.current
	end
	coroutine.yield()
end
Services.asyncCall = asyncCall

local function deepCopy(v: any, seen: { [any]: boolean }?): any
	if type(v) ~= "table" then
		return v
	end
	local s = seen or {}
	if s[v] then
		error("tables cannot be cyclic", 0)
	end
	s[v] = true
	local out = {}
	for k, x in v do
		out[deepCopy(k, s)] = deepCopy(x, s)
	end
	s[v] = nil
	return out
end
Services.deepCopy = deepCopy

-- DataModel -------------------------------------------------------------------------------

do
	local M = methods("DataModel")
	function M.GetService(p, name)
		local d = Inst.self(p, "GetService")
		local svc = Inst.findVisibleChild(d, name, nil)
		if svc and D[svc].cls.tags.Service then
			return svc
		end
		for _, c in d.children do
			if D[c].className == name then
				return c
			end
		end
		return Core.rt:createService(name)
	end
	M.FindService = function(p, name)
		local d = Inst.self(p, "FindService")
		for _, c in d.children do
			if D[c].className == name then
				return c
			end
		end
		return nil
	end
	function M.BindToClose(p, fn)
		local ctx = Core.current()
		if ctx and ctx.isClient then
			error("BindToClose can only be called on the server", 2)
		end
		table.insert(Core.rt.closeCallbacks, { fn = fn, ctx = ctx })
		local _ = p
	end
	function M.IsLoaded()
		return true
	end
	function M.GetJobsInfo()
		return {}
	end
	function M.GetMessage()
		return ""
	end
	function M.SetPlaceId() end
	local G = getters("DataModel")
	G.JobId = function()
		return Core.rt.config.jobId
	end
	G.PlaceId = function()
		return Core.rt.config.placeId
	end
	G.GameId = function()
		return Core.rt.config.gameId
	end
	G.PlaceVersion = function()
		return 1
	end
	G.CreatorId = function()
		return 1
	end
	G.PrivateServerId = function()
		return ""
	end
	G.PrivateServerOwnerId = function()
		return 0
	end
	G.Workspace = function()
		return Core.rt.workspace
	end
	events("DataModel").Loaded = true
	events("DataModel").Close = true
end

-- Players --------------------------------------------------------------------------------

do
	local M = methods("Players")
	function M.GetPlayers(p)
		local out = {}
		for _, c in D[p].children do
			if D[c].className == "Player" then
				table.insert(out, c)
			end
		end
		return out
	end
	function M.GetPlayerByUserId(p, userId)
		if type(userId) ~= "number" then
			error("Argument 1 missing or nil", 2)
		end
		for _, c in D[p].children do
			local cd = D[c]
			if cd.className == "Player" and rawGet(cd, "UserId") == userId then
				return c
			end
		end
		return nil
	end
	function M.GetPlayerFromCharacter(p, character)
		for _, c in D[p].children do
			local cd = D[c]
			if cd.className == "Player" and character ~= nil and rawGet(cd, "Character") == character then
				return c
			end
		end
		return nil
	end
	function M.GetNameFromUserIdAsync(_, userId)
		asyncCall("GetNameFromUserIdAsync")
		return "User" .. tostring(userId)
	end
	function M.GetUserIdFromNameAsync(_, name)
		asyncCall("GetUserIdFromNameAsync")
		return #tostring(name)
	end
	function M.GetUserThumbnailAsync()
		asyncCall("GetUserThumbnailAsync")
		return "rbxthumb://type=AvatarHeadShot&id=1&w=150&h=150", true
	end
	function M.GetFriendsAsync()
		Core.gap("Players:GetFriendsAsync", 2)
	end
	function M.GetHumanoidDescriptionFromUserId()
		return Inst.new("HumanoidDescription")
	end
	function M.CreateHumanoidModelFromDescription()
		Core.gap("Players:CreateHumanoidModelFromDescription", 2)
	end
	local G = getters("Players")
	G.LocalPlayer = function()
		local ctx = Core.current()
		return if ctx then ctx.player else nil
	end
	local E = events("Players")
	E.PlayerAdded = { instanceArg = true }
	E.PlayerRemoving = true
	E.PlayerMembershipChanged = true
	E.UserSubscriptionStatusChanged = true
	E.PlayerChatted = true
end

-- RunService -----------------------------------------------------------------------------

do
	local M = methods("RunService")
	function M.IsServer()
		local ctx = Core.current()
		return ctx == nil or ctx.isServer
	end
	function M.IsClient()
		local ctx = Core.current()
		return ctx ~= nil and ctx.isClient
	end
	function M.IsStudio()
		return Core.rt.config.isStudio == true
	end
	function M.IsRunning()
		return true
	end
	function M.IsRunMode()
		return false
	end
	function M.IsEdit()
		return false
	end
	function M.BindToRenderStep(_, name, priority, fn)
		local ctx = Core.current()
		if ctx == nil or not ctx.isClient then
			error("BindToRenderStep can only be called from a LocalScript", 2)
		end
		if type(name) ~= "string" or type(priority) ~= "number" or type(fn) ~= "function" then
			error("BindToRenderStep: invalid arguments", 2)
		end
		ctx.renderBindings[name] = { priority = priority, fn = fn }
	end
	function M.UnbindFromRenderStep(_, name)
		local ctx = Core.current()
		if ctx and ctx.renderBindings then
			ctx.renderBindings[name] = nil
		end
	end
	local E = events("RunService")
	E.Heartbeat = { engine = true }
	E.Stepped = { engine = true }
	E.PreSimulation = { engine = true }
	E.PostSimulation = { engine = true }
	E.RenderStepped = { engine = true, guard = clientOnly("RenderStepped") }
	E.PreRender = { engine = true, guard = clientOnly("PreRender") }
	E.PreAnimation = { engine = true }
end

-- Workspace & Camera ---------------------------------------------------------------------

do
	local M = methods("Workspace")
	function M.GetServerTimeNow()
		local S = Core.S
		return S.epoch + S.now
	end
	function M.BulkMoveTo(_, parts, cframes, _mode)
		if type(parts) ~= "table" or type(cframes) ~= "table" then
			error("BulkMoveTo: expected arrays of parts and CFrames", 2)
		end
		local setter = Inst.SETTERS.BasePart.CFrame
		for i, part in parts do
			local cf = cframes[i]
			if typeOf(part) ~= "Instance" or not D[part].cls.isA.BasePart then
				error("BulkMoveTo: element " .. i .. " is not a BasePart", 2)
			end
			if typeOf(cf) ~= "CFrame" then
				error("BulkMoveTo: CFrame " .. i .. " is missing", 2)
			end
			setter(D[part], cf)
		end
	end
	function M.Raycast(_, origin, direction, params)
		if typeOf(origin) ~= "Vector3" or typeOf(direction) ~= "Vector3" then
			error("Raycast: origin and direction must be Vector3", 2)
		end
		if params ~= nil and typeOf(params) ~= "RaycastParams" then
			error("Raycast: params must be RaycastParams", 2)
		end
		return nil
	end
	function M.Blockcast()
		return nil
	end
	function M.Spherecast()
		return nil
	end
	function M.Shapecast()
		return nil
	end
	function M.GetPartBoundsInBox()
		return {}
	end
	function M.GetPartBoundsInRadius()
		return {}
	end
	function M.GetPartsInPart()
		return {}
	end
	function M.ArePartsTouchingOthers()
		return false
	end
	function M.GetRealPhysicsFPS()
		return 60
	end
	function M.GetNumAwakeParts()
		return 0
	end
	function M.FindPartOnRay()
		return nil, Vector3.zero, Vector3.yAxis, Enum.Material.Air
	end
	M.FindPartOnRayWithIgnoreList = M.FindPartOnRay
	M.FindPartOnRayWithWhitelist = M.FindPartOnRay
	local G = getters("Workspace")
	G.CurrentCamera = function()
		local ctx = Core.current()
		if ctx and ctx.camera then
			return ctx.camera
		end
		return Core.rt.serverCamera
	end
	G.DistributedGameTime = function()
		return Core.S.now
	end
	Inst.reg(Inst.DEFAULTS, "Workspace").Gravity = 196.2

	local CM = methods("Camera")
	local function project(d, point)
		local cf = rawGet(d, "CFrame")
		local vp = Inst.GETTERS.Camera.ViewportSize(d)
		local fov = math.rad(rawGet(d, "FieldOfView"))
		local rel = cf:PointToObjectSpace(point)
		local depth = -rel.Z
		local h = 2 * math.tan(fov / 2)
		local aspect = vp.X / vp.Y
		local x = (rel.X / math.max(depth, 1e-6)) / (h * aspect) + 0.5
		local y = 0.5 - (rel.Y / math.max(depth, 1e-6)) / h
		return Vector3.new(x * vp.X, y * vp.Y, depth), depth > 0
	end
	local function ray(d, x, y)
		local cf = rawGet(d, "CFrame")
		local vp = Inst.GETTERS.Camera.ViewportSize(d)
		local fov = math.rad(rawGet(d, "FieldOfView"))
		local h = 2 * math.tan(fov / 2)
		local aspect = vp.X / vp.Y
		local dx = (x / vp.X - 0.5) * h * aspect
		local dy = (0.5 - y / vp.Y) * h
		local dir = cf:VectorToWorldSpace(Vector3.new(dx, dy, -1).Unit)
		return roblox.Ray.new(cf.Position, dir)
	end
	function CM.WorldToViewportPoint(p, point)
		return project(Inst.self(p, "WorldToViewportPoint"), point)
	end
	CM.WorldToScreenPoint = CM.WorldToViewportPoint
	function CM.ViewportPointToRay(p, x, y)
		return ray(Inst.self(p, "ViewportPointToRay"), x, y)
	end
	CM.ScreenPointToRay = CM.ViewportPointToRay
	function CM.GetPartsObscuringTarget()
		return {}
	end
	function CM.ZoomToExtents() end
	local CG = getters("Camera")
	CG.ViewportSize = function(d)
		local ctx = d.extra.ctx
		return if ctx and ctx.viewport then ctx.viewport else Vector2.new(1280, 720)
	end
	local CD = Inst.reg(Inst.DEFAULTS, "Camera")
	CD.FieldOfView = 70
	CD.CFrame = CFrame.new(0, 20, 20)
end

-- TweenService / Debris / CollectionService ---------------------------------------------

do
	local M = methods("TweenService")
	function M.Create(_, instance, info, goals)
		if typeOf(instance) ~= "Instance" then
			error("TweenService:Create: argument #1 must be an Instance", 2)
		end
		if typeOf(info) ~= "TweenInfo" then
			error("TweenService:Create: argument #2 must be a TweenInfo", 2)
		end
		if type(goals) ~= "table" then
			error("TweenService:Create: argument #3 must be a table", 2)
		end
		-- validate goal properties now (Roblox errors at Create for unknown/untweenable ones)
		local id = D[instance]
		for k, v in goals do
			local pr = id.cls.props[k]
			if not pr and not id.cls.setters[k] then
				error(
					string.format(
						"TweenService:Create property named '%s' cannot be tweened due to type mismatch (property is a 'nil', but given type is '%s')",
						tostring(k),
						typeOf(v)
					),
					2
				)
			end
			local cur = (instance :: any)[k]
			if typeOf(cur) ~= typeOf(v) and not (type(cur) == "number" and type(v) == "number") then
				error(
					string.format(
						"TweenService:Create property named '%s' cannot be tweened due to type mismatch (property is a '%s', but given type is '%s')",
						tostring(k),
						typeOf(cur),
						typeOf(v)
					),
					2
				)
			end
		end
		local t = Inst.make("Tween")
		local d = D[t]
		d.extra.instance = instance
		d.extra.info = info
		d.extra.goals = table.clone(goals)
		d.extra.state = "Begin"
		return t
	end
	function M.GetValue(_, alpha)
		return alpha
	end
	function M.SmoothDamp(_, current)
		return current, 0
	end

	methods("Debris").AddItem = function(_, item, lifetime)
		local S = Core.S
		local co = S:newThread(function()
			if D[item] and not D[item].destroyed then
				Inst.destroy(D[item])
			end
		end, Core.current())
		S:schedule(co, S.now + (tonumber(lifetime) or 10))
	end

	local tagged: { [string]: { [any]: boolean } } = {}
	local addedSig: { [string]: any } = {}
	local removedSig: { [string]: any } = {}
	local function sigFor(t, tag)
		local s = t[tag]
		if not s then
			local _, sd = Signal.new("Tag:" .. tag, {
				filter = function(ctx, inst)
					return Inst.isVisible(inst, ctx)
				end,
			})
			s = sd
			t[tag] = s
		end
		return s
	end
	Inst.onTag = function(d, tag, added)
		tagged[tag] = tagged[tag] or {}
		if added then
			tagged[tag][d.proxy] = true
			Signal.fire(sigFor(addedSig, tag), nil, nil, d.proxy)
		else
			tagged[tag][d.proxy] = nil
			Signal.fire(sigFor(removedSig, tag), nil, nil, d.proxy)
		end
	end
	local CS = methods("CollectionService")
	function CS.GetTagged(_, tag)
		local out = {}
		local ctx = Core.current()
		for inst in tagged[tag] or {} do
			local d = D[inst]
			if not d.destroyed and Inst.isVisible(inst, ctx) and d.parent then
				table.insert(out, inst)
			end
		end
		return out
	end
	function CS.AddTag(_, inst, tag)
		inst:AddTag(tag)
	end
	function CS.RemoveTag(_, inst, tag)
		inst:RemoveTag(tag)
	end
	function CS.HasTag(_, inst, tag)
		return inst:HasTag(tag)
	end
	function CS.GetTags(_, inst)
		return inst:GetTags()
	end
	function CS.GetInstanceAddedSignal(_, tag)
		return sigFor(addedSig, tag).proxy
	end
	function CS.GetInstanceRemovedSignal(_, tag)
		return sigFor(removedSig, tag).proxy
	end
	function CS.GetAllTags()
		local out = {}
		for t in tagged do
			table.insert(out, t)
		end
		return out
	end
end

-- HttpService ------------------------------------------------------------------------------

do
	local M = methods("HttpService")
	local guidN = 0
	function M.GenerateGUID(_, braces)
		guidN += 1
		local hex = string.format("%08X-0000-4000-8000-%012X", guidN, guidN * 7919)
		return if braces == false then hex else "{" .. hex .. "}"
	end
	local function checkJson(v, path, seen)
		local t = typeOf(v)
		if t == "table" then
			if seen[v] then
				error("Can't convert to JSON (cyclic table at " .. path .. ")", 0)
			end
			seen[v] = true
			for k, x in v do
				checkJson(x, path .. "." .. tostring(k), seen)
			end
			seen[v] = nil
		elseif t ~= "string" and t ~= "number" and t ~= "boolean" and t ~= "nil" then
			error("Can't convert to JSON (" .. t .. " at " .. path .. ")", 0)
		end
	end
	function M.JSONEncode(_, v)
		checkJson(v, "root", {})
		return serde.encode("json", v)
	end
	function M.JSONDecode(_, s)
		if type(s) ~= "string" then
			error("Can't parse JSON", 2)
		end
		local ok, v = pcall(serde.decode, "json", s)
		if not ok then
			error("Can't parse JSON", 2)
		end
		return v
	end
	function M.UrlEncode(_, s)
		return (
			string.gsub(tostring(s), "[^%w%-_%.~]", function(c)
				return string.format("%%%02X", string.byte(c))
			end)
		)
	end
	function M.GetAsync()
		error("Http requests are not enabled. Enable via game settings", 2)
	end
	M.PostAsync = M.GetAsync
	M.RequestAsync = M.GetAsync
end

-- DataStoreService --------------------------------------------------------------------------

-- Validates a value the way Roblox DataStores do (JSON-able, no mixed tables, no
-- non-string dictionary keys, no NaN/inf, valid UTF-8 strings).
local function validateStored(v: any, path: string)
	local t = typeOf(v)
	if t == "nil" or t == "boolean" then
		return
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			error("Cannot store " .. tostring(v) .. " in data store (" .. path .. ")", 0)
		end
	elseif t == "string" then
		if utf8.len(v) == nil then
			error("Cannot store invalid UTF-8 in data store (" .. path .. ")", 0)
		end
	elseif t == "table" then
		local n = #v
		local hasNumeric, hasString = false, false
		for k, x in v do
			if type(k) == "number" then
				hasNumeric = true
				if k < 1 or k > n or k % 1 ~= 0 then
					error(
						"Cannot store sparse array/numeric-keyed dictionary in data store (" .. path .. ")",
						0
					)
				end
			elseif type(k) == "string" then
				hasString = true
			else
				error("Cannot store table with " .. typeOf(k) .. " keys in data store (" .. path .. ")", 0)
			end
			validateStored(x, path .. "." .. tostring(k))
		end
		if hasNumeric and hasString then
			error("Cannot store mixed table (array + dictionary) in data store (" .. path .. ")", 0)
		end
	else
		error("Cannot store " .. t .. " in data store (" .. path .. ")", 0)
	end
end
Services.validateStored = validateStored

local function keyInfo(entry)
	return Core.proxy("DataStoreKeyInfo", function(_, k)
		if k == "Version" then
			return tostring(entry.version)
		elseif k == "CreatedTime" then
			return entry.created
		elseif k == "UpdatedTime" then
			return entry.updated
		elseif k == "GetUserIds" then
			return function()
				return entry.userIds or {}
			end
		elseif k == "GetMetadata" then
			return function()
				return {}
			end
		end
		error(tostring(k) .. " is not a valid member of DataStoreKeyInfo", 2)
	end)
end

local function makeStore(name: string, ordered: boolean)
	local rt = Core.rt
	local id = (if ordered then "ordered:" else "global:") .. name
	local data = rt.dataStores[id]
	if not data then
		data = { name = name, ordered = ordered, entries = {}, log = {} }
		rt.dataStores[id] = data
	end
	local cls = if ordered then "OrderedDataStore" else "DataStore"
	local store = Inst.make(cls)
	D[store].name = name
	D[store].extra.store = data
	return store
end

local function storeOf(p): any
	return D[p].extra.store
end

local function checkFail(what: string, key: string)
	local rt = Core.rt
	local f = rt.config.dataStoreFail
	if f and f(what, key) then
		error("502: API Services rejected request with error. HTTP 500 (Internal Server Error)", 0)
	end
end

-- Request budgets per Roblox's documented limits (per minute: base + perPlayer * players).
-- A request without budget is queued (with Roblox's warning) until the budget refills.
local BUDGETS = {
	GetAsync = { 60, 10 },
	SetIncrementAsync = { 60, 10 },
	UpdateAsync = { 60, 10 },
	GetSortedAsync = { 5, 2 },
	SetIncrementSortedAsync = { 30, 5 },
	OnUpdate = { 30, 5 },
	ListAsync = { 5, 2 },
	RemoveVersionAsync = { 5, 2 },
	GetVersionAsync = { 5, 2 },
}
Services.BUDGETS = BUDGETS
local budgetState: { [string]: { value: number, at: number } } = {}

local function budgetRate(kind: string): number
	local b = BUDGETS[kind] or { 60, 10 }
	return b[1] + b[2] * #Core.rt.players
end

local function currentBudget(kind: string): number
	local S = Core.S
	local st = budgetState[kind]
	local rate = budgetRate(kind)
	if not st then
		st = { value = rate, at = S.now }
		budgetState[kind] = st
	end
	st.value = math.min(rate * 3, st.value + (S.now - st.at) * rate / 60)
	st.at = S.now
	local override = Core.rt.config.dataStoreBudget
	if type(override) == "number" and override < st.value then
		return override
	end
	return st.value
end
Services.currentBudget = currentBudget

local WRITE_COOLDOWN = 6 -- seconds between writes to one key (Roblox: 1 write / 6 s / key)
local lastWrite: { [string]: number } = {}

-- Spends budget for one request (and the per-key write cooldown for writes),
-- waiting in Roblox's request queue when needed.
local function spend(kind: string, storeId: string, key: string, isWrite: boolean)
	local S = Core.S
	local queued = false
	local function note(why)
		if not queued then
			queued = true
			Core.warn(
				string.format(
					"DataStore request was added to queue (%s). If request queue fills, further requests will be dropped. Try sending fewer requests.Key = %s (store %s)",
					why,
					key,
					storeId
				)
			)
			table.insert(Core.rt.dataStoreThrottles, { kind = kind, key = key, why = why, at = S.now })
		end
	end
	while currentBudget(kind) < 1 do
		note("budget " .. kind)
		Services.asyncCall("budget wait")
	end
	budgetState[kind].value -= 1
	if isWrite then
		local wk = storeId .. "/" .. key
		local last = lastWrite[wk]
		if last and S.now - last < WRITE_COOLDOWN - 1e-6 then
			note("same key written within " .. WRITE_COOLDOWN .. " s")
			while S.now - last < WRITE_COOLDOWN - 1e-6 do
				Services.asyncCall("write cooldown")
			end
		end
		lastWrite[wk] = S.now
	end
end

local function checkKey(key)
	if type(key) ~= "string" or #key == 0 or #key > 50 then
		error("Key name is invalid (must be a 1-50 character string)", 3)
	end
end

do
	local function now()
		return math.floor((Core.S.epoch + Core.S.now) * 1000)
	end
	local function getEntry(s, key)
		return s.entries[key]
	end
	local function write(s, key, value, userIds)
		validateStored(value, key)
		local enc = serde.encode("json", if value == nil then false else value)
		if #enc > 4_194_304 then
			error("Value too large for data store (" .. #enc .. " bytes)", 0)
		end
		local e = s.entries[key]
		if not e then
			e = { version = 0, created = now() }
			s.entries[key] = e
		end
		e.version += 1
		e.updated = now()
		e.value = deepCopy(value)
		e.userIds = userIds
		table.insert(s.log, { op = "write", key = key, at = Core.S.now })
		return e
	end

	for _, cls in { "DataStore", "OrderedDataStore" } do
		local M = methods(cls)
		function M.GetAsync(p, key)
			local ctx = Core.current()
			if ctx and ctx.isClient then
				error("DataStore can't be accessed from client", 2)
			end
			checkKey(key)
			local s = storeOf(p)
			spend(if s.ordered then "GetAsync" else "GetAsync", s.name, key, false)
			asyncCall("GetAsync")
			checkFail("GetAsync", key)
			local e = getEntry(s, key)
			if not e or e.value == nil then
				return nil, nil
			end
			return deepCopy(e.value), keyInfo(e)
		end
		function M.SetAsync(p, key, value, userIds)
			checkKey(key)
			local s = storeOf(p)
			spend(if s.ordered then "SetIncrementSortedAsync" else "SetIncrementAsync", s.name, key, true)
			asyncCall("SetAsync")
			checkFail("SetAsync", key)
			if s.ordered and (type(value) ~= "number" or value % 1 ~= 0) then
				error("OrderedDataStore values must be integers", 2)
			end
			local e = write(s, key, value, userIds)
			return tostring(e.version)
		end
		function M.UpdateAsync(p, key, fn)
			checkKey(key)
			if type(fn) ~= "function" then
				error("UpdateAsync: argument #2 must be a function", 2)
			end
			local s = storeOf(p)
			spend(if s.ordered then "SetIncrementSortedAsync" else "UpdateAsync", s.name, key, true)
			asyncCall("UpdateAsync")
			checkFail("UpdateAsync", key)
			local e = getEntry(s, key)
			local old = if e then deepCopy(e.value) else nil
			-- the transform function must not yield
			local co = coroutine.create(fn)
			local ok, newValue, userIds = coroutine.resume(co, old, if e then keyInfo(e) else nil)
			if not ok then
				error(newValue, 0)
			end
			if coroutine.status(co) ~= "dead" then
				error("UpdateAsync: the transform function yielded (it must not yield)", 2)
			end
			if newValue == nil then
				return nil, nil
			end
			if s.ordered and (type(newValue) ~= "number" or newValue % 1 ~= 0) then
				error("OrderedDataStore values must be integers", 2)
			end
			local ne = write(s, key, newValue, userIds)
			return deepCopy(ne.value), keyInfo(ne)
		end
		function M.IncrementAsync(p, key, delta)
			checkKey(key)
			local s = storeOf(p)
			spend(if s.ordered then "SetIncrementSortedAsync" else "SetIncrementAsync", s.name, key, true)
			asyncCall("IncrementAsync")
			local e = getEntry(s, key)
			local v = (if e and type(e.value) == "number" then e.value else 0) + (delta or 1)
			write(s, key, v)
			return v
		end
		function M.RemoveAsync(p, key)
			checkKey(key)
			local s = storeOf(p)
			spend(if s.ordered then "SetIncrementSortedAsync" else "SetIncrementAsync", s.name, key, true)
			asyncCall("RemoveAsync")
			checkFail("RemoveAsync", key)
			local e = getEntry(s, key)
			s.entries[key] = nil
			if e then
				return deepCopy(e.value), keyInfo(e)
			end
			return nil, nil
		end
	end

	local OM = methods("OrderedDataStore")
	function OM.GetSortedAsync(p, ascending, pageSize, minValue, maxValue)
		if type(ascending) ~= "boolean" then
			error("GetSortedAsync: argument #1 must be a boolean", 2)
		end
		if type(pageSize) ~= "number" or pageSize < 1 or pageSize > 100 then
			error("GetSortedAsync: pageSize must be 1..100", 2)
		end
		local s = storeOf(p)
		spend("GetSortedAsync", s.name, "(sorted)", false)
		asyncCall("GetSortedAsync")
		local rows = {}
		for key, e in s.entries do
			local v = e.value
			if
				type(v) == "number"
				and (minValue == nil or v >= minValue)
				and (maxValue == nil or v <= maxValue)
			then
				table.insert(rows, { key = key, value = v })
			end
		end
		table.sort(rows, function(a, b)
			if a.value == b.value then
				return a.key < b.key
			end
			if ascending then
				return a.value < b.value
			end
			return a.value > b.value
		end)
		local pages = Inst.make("DataStorePages")
		local pd = D[pages]
		pd.extra.rows = rows
		pd.extra.page = 1
		pd.extra.size = pageSize
		return pages
	end
	local PM = methods("DataStorePages")
	function PM.GetCurrentPage(p)
		local x = D[p].extra
		local out = {}
		local start = (x.page - 1) * x.size
		for i = start + 1, math.min(start + x.size, #x.rows) do
			table.insert(out, { key = x.rows[i].key, value = x.rows[i].value })
		end
		return out
	end
	function PM.AdvanceToNextPageAsync(p)
		asyncCall("AdvanceToNextPageAsync")
		D[p].extra.page += 1
	end
	getters("DataStorePages").IsFinished = function(d)
		local x = d.extra
		return x.page * x.size >= #x.rows
	end

	local M = methods("DataStoreService")
	function M.GetDataStore(_, name, scope)
		local ctx = Core.current()
		if ctx and ctx.isClient then
			error("DataStoreService:GetDataStore() can only be called on the server", 2)
		end
		if type(name) ~= "string" or #name == 0 or #name > 50 then
			error("GetDataStore: name must be a 1-50 character string", 2)
		end
		if Core.rt.config.dataStoresDisabled then
			error("You must publish this place to the web to access DataStore.", 2)
		end
		return makeStore(name .. (if scope then "/" .. scope else ""), false)
	end
	function M.GetGlobalDataStore()
		return makeStore("__global", false)
	end
	function M.GetOrderedDataStore(_, name, scope)
		local ctx = Core.current()
		if ctx and ctx.isClient then
			error("DataStoreService:GetOrderedDataStore() can only be called on the server", 2)
		end
		if Core.rt.config.dataStoresDisabled then
			error("You must publish this place to the web to access DataStore.", 2)
		end
		return makeStore(name .. (if scope then "/" .. scope else ""), true)
	end
	function M.GetRequestBudgetForRequestType(_, requestType)
		if typeOf(requestType) ~= "EnumItem" then
			error("GetRequestBudgetForRequestType: argument must be an Enum.DataStoreRequestType", 2)
		end
		return math.floor(currentBudget(requestType.Name))
	end
	function M.ListDataStoresAsync()
		Core.gap("DataStoreService:ListDataStoresAsync", 2)
	end
end

-- MemoryStoreService (minimal sorted map + queue) ------------------------------------------

do
	local M = methods("MemoryStoreService")
	local maps = {}
	function M.GetSortedMap(_, name)
		local m = Inst.make("MemoryStoreSortedMap")
		maps[name] = maps[name] or {}
		D[m].extra.map = maps[name]
		return m
	end
	M.GetHashMap = M.GetSortedMap
	local SM = methods("MemoryStoreSortedMap")
	function SM.GetAsync(p, key)
		asyncCall("MemoryStore:GetAsync")
		local e = D[p].extra.map[key]
		return if e then deepCopy(e.value) else nil
	end
	function SM.SetAsync(p, key, value, _expiration)
		asyncCall("MemoryStore:SetAsync")
		D[p].extra.map[key] = { value = deepCopy(value) }
		return true
	end
	function SM.UpdateAsync(p, key, fn, _expiration)
		asyncCall("MemoryStore:UpdateAsync")
		local map = D[p].extra.map
		local e = map[key]
		local nv = fn(if e then deepCopy(e.value) else nil)
		if nv ~= nil then
			map[key] = { value = deepCopy(nv) }
		end
		return nv
	end
	function SM.RemoveAsync(p, key)
		asyncCall("MemoryStore:RemoveAsync")
		D[p].extra.map[key] = nil
	end
	function SM.GetRangeAsync(p)
		asyncCall("MemoryStore:GetRangeAsync")
		local out = {}
		for k, e in D[p].extra.map do
			table.insert(out, { key = k, value = deepCopy(e.value) })
		end
		return out
	end
	function M.GetQueue()
		Core.gap("MemoryStoreService:GetQueue", 2)
	end
end

-- MessagingService (in-process pub/sub) -------------------------------------------------------

do
	local M = methods("MessagingService")
	function M.PublishAsync(_, topic, message)
		local ctx = Core.current()
		if ctx and ctx.isClient then
			error("MessagingService can only be used on the server", 2)
		end
		if type(topic) ~= "string" then
			error("PublishAsync: topic must be a string", 2)
		end
		asyncCall("PublishAsync")
		local enc = serde.encode("json", message)
		if #enc > 1024 then
			error("PublishAsync: message too large (" .. #enc .. " > 1 kB)", 2)
		end
		local rt = Core.rt
		table.insert(rt.messagingLog, { topic = topic, message = deepCopy(message) })
		for _, sub in rt.messagingSubs[topic] or {} do
			if sub.connected then
				Core.S:dispatch(
					sub.fn,
					sub.ctx,
					true,
					{ Data = deepCopy(message), Sent = Core.S.epoch + Core.S.now }
				)
			end
		end
	end
	function M.SubscribeAsync(_, topic, fn)
		local ctx = Core.current()
		if ctx and ctx.isClient then
			error("MessagingService can only be used on the server", 2)
		end
		asyncCall("SubscribeAsync")
		local rt = Core.rt
		rt.messagingSubs[topic] = rt.messagingSubs[topic] or {}
		local sub = { fn = fn, ctx = ctx, connected = true }
		table.insert(rt.messagingSubs[topic], sub)
		return Core.proxy("RBXScriptConnection", function(_, k)
			if k == "Connected" then
				return sub.connected
			elseif k == "Disconnect" then
				return function()
					sub.connected = false
				end
			end
			error(tostring(k) .. " is not a valid member of RBXScriptConnection", 2)
		end)
	end
end

-- MarketplaceService ---------------------------------------------------------------------------

do
	reg(Inst.CALLBACKS, "MarketplaceService").ProcessReceipt = { serverOnly = true }
	local M = methods("MarketplaceService")
	local function playerId(player): number
		if typeOf(player) ~= "Instance" or not player:IsA("Player") then
			error("argument #1 must be a Player", 3)
		end
		return player.UserId
	end
	function M.UserOwnsGamePassAsync(_, userId, passId)
		if type(userId) ~= "number" or type(passId) ~= "number" then
			error("UserOwnsGamePassAsync: userId and gamePassId must be numbers", 2)
		end
		asyncCall("UserOwnsGamePassAsync")
		local owned = Core.rt.config.ownedPasses[userId]
		return owned ~= nil and owned[passId] == true
	end
	function M.PlayerOwnsAsset()
		asyncCall("PlayerOwnsAsset")
		return false
	end
	function M.PlayerOwnsBundle()
		asyncCall("PlayerOwnsBundle")
		return false
	end
	local function productInfo(id, infoType)
		asyncCall("GetProductInfo")
		if type(id) ~= "number" or id <= 0 then
			error("GetProductInfo: invalid asset id " .. tostring(id), 0)
		end
		local custom = Core.rt.config.productInfo[id]
		if custom then
			return deepCopy(custom)
		end
		return {
			Name = "Item " .. tostring(id),
			Description = "",
			PriceInRobux = 99,
			IsForSale = true,
			ProductId = id,
			AssetId = id,
			ProductType = tostring(infoType),
			IconImageAssetId = 0,
		}
	end
	function M.GetProductInfo(_, id, infoType)
		return productInfo(id, infoType)
	end
	function M.GetProductInfoAsync(_, id, infoType)
		return productInfo(id, infoType)
	end
	local function prompt(kind)
		return function(_, player, id, ...)
			local uid = playerId(player)
			table.insert(Core.rt.prompts, { kind = kind, userId = uid, id = id, args = table.pack(...) })
		end
	end
	M.PromptProductPurchase = prompt("product")
	M.PromptGamePassPurchase = prompt("gamepass")
	M.PromptPurchase = prompt("asset")
	M.PromptPremiumPurchase = function(_, player)
		table.insert(Core.rt.prompts, { kind = "premium", userId = playerId(player) })
	end
	M.PromptSubscriptionPurchase = prompt("subscription")
	M.PromptRobloxSubscriptionPurchase = function(_, player)
		table.insert(Core.rt.prompts, { kind = "robloxSubscription", userId = playerId(player) })
	end
	M.PromptBundlePurchase = prompt("bundle")
	function M.GetUserSubscriptionStatusAsync(_, player, subId)
		playerId(player)
		if type(subId) ~= "string" then
			error("GetUserSubscriptionStatusAsync: subscriptionId must be a string", 2)
		end
		asyncCall("GetUserSubscriptionStatusAsync")
		return { IsSubscribed = false, IsRenewing = false }
	end
	function M.GetSubscriptionProductInfoAsync(_, subId)
		asyncCall("GetSubscriptionProductInfoAsync")
		return { Name = "Sub " .. tostring(subId), DisplayPrice = "$4.99", IsForSale = true }
	end
	function M.GetDeveloperProductsAsync()
		Core.gap("MarketplaceService:GetDeveloperProductsAsync", 2)
	end
	local E = events("MarketplaceService")
	E.PromptGamePassPurchaseFinished = true
	E.PromptProductPurchaseFinished = true
	E.PromptPurchaseFinished = true
	E.PromptSubscriptionPurchaseFinished = true
	E.PromptPremiumPurchaseFinished = true
	E.PromptBundlePurchaseFinished = true
end

-- Small services -----------------------------------------------------------------------------

do
	methods("PolicyService").GetPolicyInfoForPlayerAsync = function(_, player)
		if typeOf(player) ~= "Instance" then
			error("GetPolicyInfoForPlayerAsync: argument #1 must be a Player", 2)
		end
		asyncCall("GetPolicyInfoForPlayerAsync")
		return deepCopy(Core.rt.config.policy)
	end
	methods("PolicyService").CanViewBrandProfileAsync = function()
		return true
	end

	local B = methods("BadgeService")
	function B.AwardBadge(_, userId, badgeId)
		asyncCall("AwardBadge")
		table.insert(Core.rt.badges, { userId = userId, badgeId = badgeId })
		return true
	end
	function B.AwardBadgeAsync(_, userId, badgeId)
		return B.AwardBadge(_, userId, badgeId)
	end
	function B.UserHasBadgeAsync(_, userId, badgeId)
		asyncCall("UserHasBadgeAsync")
		for _, b in Core.rt.badges do
			if b.userId == userId and b.badgeId == badgeId then
				return true
			end
		end
		return false
	end
	function B.GetBadgeInfoAsync(_, badgeId)
		asyncCall("GetBadgeInfoAsync")
		return { Name = "Badge " .. tostring(badgeId), IsEnabled = true, Description = "" }
	end

	local TC = reg(Inst.CALLBACKS, "TextChatService")
	TC.OnIncomingMessage = { clientOnly = true }
	TC.OnBubbleAdded = { clientOnly = true }
	TC.OnChatWindowAdded = { clientOnly = true }
	local TCE = events("TextChatService")
	TCE.MessageReceived = true
	TCE.SendingMessage = true
	methods("TextChatService").CanUserChatAsync = function()
		asyncCall("CanUserChatAsync")
		return true
	end
	methods("TextChatService").CanUsersChatAsync = function()
		asyncCall("CanUsersChatAsync")
		return true
	end
	reg(Inst.DEFAULTS, "TextChatService").ChatVersion = Enum.ChatVersion.TextChatService

	local T = methods("TeleportService")
	for _, n in
		{
			"Teleport",
			"TeleportAsync",
			"TeleportToPlaceInstance",
			"TeleportToPrivateServer",
			"TeleportPartyAsync",
		}
	do
		T[n] = function(_, ...)
			table.insert(Core.rt.teleports, { method = n, args = table.pack(...) })
		end
	end
	T.ReserveServer = function()
		asyncCall("ReserveServer")
		return "reserved-code", "private-id"
	end
	T.GetLocalPlayerTeleportData = function()
		return nil
	end
	T.SetTeleportGui = function() end
	events("TeleportService").TeleportInitFailed = true
	events("TeleportService").LocalPlayerArrivedFromTeleport = true

	local GS = methods("GuiService")
	function GS.GetGuiInset()
		return Vector2.new(0, 58), Vector2.new(0, 0)
	end
	function GS.IsTenFootInterface()
		return false
	end
	function GS.GetEmotesMenuOpen()
		return false
	end
	function GS.SetEmotesMenuOpen() end
	function GS.GetInspectMenuEnabled()
		return false
	end
	function GS.SetInspectMenuEnabled() end
	function GS.CloseInspectMenu() end
	function GS.Select() end
	getters("GuiService").TopbarInset = function()
		return roblox.Rect.new(0, 0, 1280, 58)
	end
	events("GuiService").MenuOpened = true
	events("GuiService").MenuClosed = true

	local UIS = methods("UserInputService")
	local function dev(key)
		return function()
			local ctx = Core.current()
			local device = ctx and ctx.device or {}
			return device[key] == true
		end
	end
	local UG = getters("UserInputService")
	UG.TouchEnabled = dev("touch")
	UG.KeyboardEnabled = dev("keyboard")
	UG.MouseEnabled = dev("mouse")
	UG.GamepadEnabled = dev("gamepad")
	UG.AccelerometerEnabled = dev("accelerometer")
	UG.GyroscopeEnabled = dev("gyro")
	UG.VREnabled = dev("vr")
	UG.PreferredInput = function()
		local ctx = Core.current()
		local device = ctx and ctx.device or {}
		return if device.touch then Enum.PreferredInput.Touch else Enum.PreferredInput.KeyboardAndMouse
	end
	function UIS.GetMouseLocation()
		local ctx = Core.current()
		return if ctx and ctx.mouse then ctx.mouse else Vector2.new(640, 360)
	end
	function UIS.GetLastInputType()
		local ctx = Core.current()
		local device = ctx and ctx.device or {}
		return if device.touch then Enum.UserInputType.Touch else Enum.UserInputType.Keyboard
	end
	function UIS.IsKeyDown(_, key)
		local ctx = Core.current()
		return ctx ~= nil and ctx.keysDown ~= nil and ctx.keysDown[key] == true
	end
	function UIS.IsMouseButtonPressed()
		return false
	end
	function UIS.GetKeysPressed()
		return {}
	end
	function UIS.GetConnectedGamepads()
		return {}
	end
	function UIS.GetGamepadConnected()
		return false
	end
	function UIS.GetNavigationGamepads()
		return {}
	end
	function UIS.GetFocusedTextBox()
		return nil
	end
	function UIS.GetStringForKeyCode(_, key)
		return key.Name
	end
	function UIS.GetMouseDelta()
		return Vector2.zero
	end
	function UIS.GetGamepadState()
		return {}
	end
	function UIS.GetSupportedGamepadKeyCodes()
		return {}
	end
	local UE = events("UserInputService")
	for _, n in
		{
			"InputBegan",
			"InputEnded",
			"InputChanged",
			"LastInputTypeChanged",
			"TouchPinch",
			"TouchStarted",
			"TouchMoved",
			"TouchEnded",
			"TouchTap",
			"TouchLongPress",
			"TouchPan",
			"TouchSwipe",
			"TouchRotate",
			"JumpRequest",
			"WindowFocused",
			"WindowFocusReleased",
			"GamepadConnected",
			"GamepadDisconnected",
			"TextBoxFocused",
			"TextBoxFocusReleased",
			"PointerAction",
			"DeviceRotationChanged",
		}
	do
		UE[n] = { guard = clientOnly("UserInputService." .. n) }
	end

	local CAS = methods("ContextActionService")
	local function bind(name, fn, createTouch, priority, inputs)
		local ctx = Core.current()
		if ctx == nil or not ctx.isClient then
			error("ContextActionService can only be used from a LocalScript", 3)
		end
		if type(name) ~= "string" or type(fn) ~= "function" then
			error("BindAction: invalid arguments", 3)
		end
		for i, input in inputs do
			if typeOf(input) ~= "EnumItem" then
				error("BindAction: input #" .. i .. " is not an Enum item", 3)
			end
		end
		ctx.actions[name] = { fn = fn, touch = createTouch, priority = priority, inputs = inputs }
	end
	function CAS.BindAction(_, name, fn, createTouch, ...)
		bind(name, fn, createTouch, 2000, { ... })
	end
	function CAS.BindActionAtPriority(_, name, fn, createTouch, priority, ...)
		bind(name, fn, createTouch, priority, { ... })
	end
	function CAS.UnbindAction(_, name)
		local ctx = Core.current()
		if ctx and ctx.actions then
			ctx.actions[name] = nil
		end
	end
	function CAS.UnbindAllActions()
		local ctx = Core.current()
		if ctx then
			ctx.actions = {}
		end
	end
	function CAS.GetButton()
		return nil
	end
	function CAS.SetTitle() end
	function CAS.SetImage() end
	function CAS.SetPosition() end
	function CAS.SetDescription() end
	function CAS.GetBoundActionInfo(_, name)
		local ctx = Core.current()
		return if ctx and ctx.actions[name] then {} else nil
	end
	function CAS.GetAllBoundActionInfo()
		return {}
	end

	local SG = methods("StarterGui")
	function SG.SetCoreGuiEnabled(_, guiType, enabled)
		local ctx = Core.current()
		if ctx == nil or not ctx.isClient then
			error("SetCoreGuiEnabled can only be called from a LocalScript", 2)
		end
		if typeOf(guiType) ~= "EnumItem" or type(enabled) ~= "boolean" then
			error("SetCoreGuiEnabled: invalid arguments", 2)
		end
		ctx.coreGui[guiType] = enabled
	end
	function SG.GetCoreGuiEnabled(_, guiType)
		local ctx = Core.current()
		if ctx and ctx.coreGui[guiType] ~= nil then
			return ctx.coreGui[guiType]
		end
		return true
	end
	function SG.SetCore(_, name, value)
		local ctx = Core.current()
		if ctx == nil or not ctx.isClient then
			error("SetCore can only be called from a LocalScript", 2)
		end
		ctx.core[name] = value
	end
	function SG.GetCore(_, name)
		local ctx = Core.current()
		return if ctx then ctx.core[name] else nil
	end
	SG.RegisterSetCore = function() end
	SG.RegisterGetCore = function() end

	local SS = methods("SocialService")
	function SS.CanSendGameInviteAsync()
		asyncCall("CanSendGameInviteAsync")
		return false
	end
	function SS.PromptGameInvite() end
	function SS.CanSendCallInviteAsync()
		return false
	end

	local AS = methods("AdService")
	function AS.GetAdAvailabilityNowAsync()
		asyncCall("GetAdAvailabilityNowAsync")
		return { AdAvailabilityResult = Enum.AdAvailabilityResult.NoFill }
	end
	function AS.CreateAdRewardFromDevProductId(_, id)
		return { DevProductId = id }
	end
	function AS.ShowRewardedVideoAdAsync()
		asyncCall("ShowRewardedVideoAdAsync")
		return false
	end

	methods("ContentProvider").PreloadAsync = function(_, list)
		if type(list) ~= "table" then
			error("PreloadAsync: argument must be an array", 2)
		end
		asyncCall("PreloadAsync")
	end
	getters("ContentProvider").RequestQueueSize = function()
		return 0
	end

	local PS = methods("PhysicsService")
	function PS.RegisterCollisionGroup() end
	function PS.CollisionGroupSetCollidable() end
	function PS.IsCollisionGroupRegistered()
		return true
	end
	function PS.CollisionGroupsAreCollidable()
		return true
	end
	function PS.UnregisterCollisionGroup() end

	local LS = methods("LocalizationService")
	function LS.GetTranslatorForPlayerAsync()
		asyncCall("GetTranslatorForPlayerAsync")
		return nil
	end
	function LS.GetCountryRegionForPlayerAsync()
		asyncCall("GetCountryRegionForPlayerAsync")
		return "US"
	end
	getters("LocalizationService").RobloxLocaleId = function()
		return "en-us"
	end
	getters("LocalizationService").SystemLocaleId = function()
		return "en-us"
	end

	methods("SoundService").PlayLocalSound = function() end
	methods("SoundService").SetListener = function() end

	methods("LogService").GetLogHistory = function()
		return {}
	end
	events("LogService").MessageOut = true

	methods("Chat").Chat = function() end
	methods("Chat").FilterStringForBroadcast = function(_, s)
		return s
	end

	local TS = methods("TextService")
	function TS.GetTextSize(_, text, size)
		return Vector2.new(#tostring(text) * size * 0.5, size)
	end
	function TS.FilterStringAsync(_, text)
		asyncCall("FilterStringAsync")
		local r = Core.proxy("TextFilterResult", function(_, k)
			if
				k == "GetNonChatStringForBroadcastAsync"
				or k == "GetChatForUserAsync"
				or k == "GetNonChatStringForUserAsync"
			then
				return function()
					return text
				end
			end
			error(tostring(k) .. " is not a valid member of TextFilterResult", 2)
		end)
		return r
	end

	methods("PathfindingService").CreatePath = function()
		Core.gap("PathfindingService:CreatePath", 2)
	end
end

local _unused = serverOnly
local _unused2 = CFrame

return Services
