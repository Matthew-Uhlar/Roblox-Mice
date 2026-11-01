--!strict
-- Defensive access to Shared.Config.* modules. Other teams write those modules
-- in parallel, so the client never assumes one exact table layout: it accepts
-- `ORDER` + by-id maps, plain arrays, or maps of defs keyed by id. Missing
-- modules return nil and are retried later (no yielding).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local Defs = {}

local RETRY_SECONDS = 5
local cache: { [string]: any } = {}
local missingUntil: { [string]: number } = {}

local function configFolder(): Instance?
	return Shared:FindFirstChild("Config")
end

-- Returns the required Shared.Config.<name> module table, or nil.
function Defs.module(name: string): any
	local m = cache[name]
	if m ~= nil then
		return m
	end
	local now = os.clock()
	if (missingUntil[name] or 0) > now then
		return nil
	end
	local folder = configFolder()
	local inst = folder and folder:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, res = pcall(require, inst)
		if ok and type(res) == "table" then
			cache[name] = res
			return res
		end
		warn("[Trunkfall] failed to load Config." .. name .. ": " .. tostring(res))
	end
	missingUntil[name] = now + RETRY_SECONDS
	return nil
end

local MAP_FIELDS = { "byId", "BY_ID", "ById", "defs", "DEFS", "Defs", "map", "MAP" }
local LIST_FIELDS = { "LIST", "list", "ALL", "all", "items", "ITEMS", "Items", "entries" }

-- Finds the def with `id` in a config module of unknown layout.
function Defs.find(mod: any, id: any): any
	if type(mod) ~= "table" or id == nil then
		return nil
	end
	for _, f in MAP_FIELDS do
		local t = mod[f]
		if type(t) == "table" and type(t[id]) == "table" then
			return t[id]
		end
	end
	local direct = mod[id]
	if type(direct) == "table" and type(id) == "string" then
		return direct
	end
	for _, f in LIST_FIELDS do
		local t = mod[f]
		if type(t) == "table" then
			for _, d in t do
				if type(d) == "table" and d.id == id then
					return d
				end
			end
		end
	end
	for _, d in ipairs(mod) do
		if type(d) == "table" and d.id == id then
			return d
		end
	end
	return nil
end

local function sortKey(d: any): (number, string)
	local order = tonumber(d.order or d.sortOrder) or 1e9
	return order, tostring(d.id or d.key or d.name or "")
end

-- Returns an ordered array of defs from a config module of unknown layout.
function Defs.list(mod: any): { any }
	local out = {}
	if type(mod) ~= "table" then
		return out
	end
	if type(mod.ORDER) == "table" then
		for _, id in ipairs(mod.ORDER) do
			local d = Defs.find(mod, id)
			if d then
				table.insert(out, d)
			end
		end
		if #out > 0 then
			return out
		end
	end
	if #mod > 0 then
		for _, d in ipairs(mod) do
			if type(d) == "table" then
				table.insert(out, d)
			end
		end
		return out
	end
	for _, f in LIST_FIELDS do
		local t = mod[f]
		if type(t) == "table" and #t > 0 then
			for _, d in ipairs(t) do
				if type(d) == "table" then
					table.insert(out, d)
				end
			end
			return out
		end
	end
	local seen = {}
	local function collect(t: any)
		for k, d in t do
			if
				type(d) == "table"
				and type(k) == "string"
				and (d.id ~= nil or d.name ~= nil)
				and not seen[d]
			then
				seen[d] = true
				if d.id == nil then
					-- keyed by id without an id field
					local copy = table.clone(d)
					copy.id = k
					table.insert(out, copy)
				else
					table.insert(out, d)
				end
			end
		end
	end
	for _, f in MAP_FIELDS do
		if type(mod[f]) == "table" then
			collect(mod[f])
		end
	end
	if #out == 0 then
		collect(mod)
	end
	table.sort(out, function(a, b)
		local oa, ia = sortKey(a)
		local ob, ib = sortKey(b)
		if oa ~= ob then
			return oa < ob
		end
		return ia < ib
	end)
	return out
end

-- Shortcut: def by id from Shared.Config.<moduleName>.
function Defs.get(moduleName: string, id: any): any
	return Defs.find(Defs.module(moduleName), id)
end

-- Shortcut: ordered defs from Shared.Config.<moduleName>.
function Defs.all(moduleName: string): { any }
	return Defs.list(Defs.module(moduleName))
end

-- Resolves an EnemySnap.kind into its def.
-- Returns (def?, isBoss, id?). kind < 200 indexes Enemies.ORDER, 200+ indexes Bosses.ORDER.
function Defs.enemyKind(kind: number): (any, boolean, string?)
	local isBoss = kind >= 200
	local mod = Defs.module(if isBoss then "Bosses" else "Enemies")
	local idx = if isBoss then kind - 200 else kind
	local id: string? = nil
	if type(mod) == "table" and type(mod.ORDER) == "table" then
		id = mod.ORDER[idx]
	end
	if id == nil then
		return nil, isBoss, nil
	end
	return Defs.find(mod, id), isBoss, id
end

-- Display name for a def, or the id prettified.
function Defs.name(d: any, fallbackId: any): string
	if type(d) == "table" then
		local n = d.name or d.displayName or d.title
		if n then
			return tostring(n)
		end
	end
	if fallbackId == nil then
		return "???"
	end
	local s = tostring(fallbackId):gsub("_", " ")
	return (s:gsub("^%l", string.upper))
end

-- Robux/dev-product catalog from Shared.Config.Monetization (Team D).
-- Returns nil if the module is missing, else a list of
-- { key, name, description, price, kind = "pass" | "product" }.
function Defs.products(): { any }?
	local mod = Defs.module("Monetization")
	if type(mod) ~= "table" then
		return nil
	end
	local out = {}
	local seen: { [string]: boolean } = {}
	local function priceOf(d: any): number?
		return tonumber(d.fallbackPrice or d.price or d.robux or d.priceRobux or d.cost)
	end
	local function isConfigured(d: any): boolean
		if type(mod.isConfigured) == "function" then
			local ok, res = pcall(mod.isConfigured, d)
			return ok and res == true
		end
		return d.assetId ~= nil and d.assetId ~= 0
	end
	-- Team D layout: M.ALL = { Item } with key, kind, assetId, fallbackPrice, name, benefit, adOnly.
	if type(mod.ALL) == "table" and #mod.ALL > 0 then
		for _, d in ipairs(mod.ALL) do
			if type(d) == "table" and d.key ~= nil and not d.adOnly then
				table.insert(out, {
					key = tostring(d.key),
					name = tostring(d.name or d.key),
					description = tostring(d.benefit or d.description or ""),
					price = priceOf(d),
					kind = tostring(d.kind or "product"),
					assetId = d.assetId,
					configured = isConfigured(d),
				})
			end
		end
		return out
	end
	local function visit(groupName: string, group: any)
		local kind = if string.find(string.lower(groupName), "pass") then "pass" else "product"
		for k, d in group do
			if type(d) == "table" and (d.name or d.displayName or d.title) then
				local key = d.key or (if type(k) == "string" then k else nil) or d.id
				if key ~= nil and not seen[tostring(key)] then
					seen[tostring(key)] = true
					table.insert(out, {
						key = tostring(key),
						name = tostring(d.name or d.displayName or d.title),
						description = tostring(d.description or d.desc or ""),
						price = priceOf(d),
						kind = d.kind or d.type or kind,
						icon = d.icon or d.emoji,
					})
				end
			end
		end
	end
	for k, v in mod do
		if type(k) == "string" and type(v) == "table" and k ~= "ORDER" then
			visit(k, v)
		end
	end
	table.sort(out, function(a, b)
		local pa, pb = a.price or 1e9, b.price or 1e9
		if pa ~= pb then
			return pa < pb
		end
		return a.name < b.name
	end)
	return out
end

return Defs
