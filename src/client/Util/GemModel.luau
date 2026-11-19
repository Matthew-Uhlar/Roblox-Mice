--!strict
-- Pure model of Cheese Gems and Crumb Dust (iteration 2; ALIGNMENT §2c A2).
-- No Roblox APIs. Reads Team P's profile view `gems` defensively:
--   gems = { inv = {{id, tier, s = {5 ints} | stats, u = unique?, lv}}, equipped = {[1..3] = id|0},
--            socketsOpen, socketLevels, capacity, dust }
-- Config/Gems (P) wins for point values, caps and unique names when present.

local GemModel = {}

local function num(v: any, d: number): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return d
	end
	return n
end

GemModel.STATS = { "rinds", "bite", "hide", "plating", "stride" }
GemModel.STAT_INFO = {
	rinds = { name = "Rinds", per = 0.001, icon = "🔶", sign = "+" },
	bite = { name = "Bite", per = 0.0005, icon = "🦷", sign = "+" },
	hide = { name = "Hide", per = 0.0002, icon = "❤", sign = "+" },
	plating = { name = "Plating", per = 0.0003, icon = "🛡", sign = "-" },
	stride = { name = "Stride", per = 0.0001, icon = "👟", sign = "+" },
} :: { [string]: { name: string, per: number, icon: string, sign: string } }
-- squad caps on the summed bonus (ALIGNMENT A2)
GemModel.CAPS = { rinds = 1.0, bite = 0.6, hide = 0.25, plating = 0.3, stride = 0.08 } :: { [string]: number }
GemModel.MAX_LEVEL = 5
GemModel.LEVEL_BONUS = 0.10 -- +10% to every rolled stat per upgrade level

export type Gem = {
	id: number,
	tier: number,
	stats: { [string]: number }, -- raw rolled points
	values: { [string]: number }?, -- server-computed fractions (Team P gemView), when sent
	uniqueText: string?,
	upgrade: number?, -- server upgrade cost
	salvage: number?, -- server salvage dust
	unique: string?,
	level: number,
	equipped: number?,
}

-- One gem from the view: {id, tier|t, s = {5}|stats = {name = n}, u|unique, lv|level}.
function GemModel.gem(g: any): Gem?
	if type(g) ~= "table" or tonumber(g.id) == nil then
		return nil
	end
	local stats: { [string]: number } = {}
	local values: { [string]: number }? = nil
	local raw = g.stats or g.s
	if type(raw) == "table" then
		for i, k in GemModel.STATS do
			local e = raw[k] or raw[i]
			if type(e) == "table" then
				-- Team P: {stat, name, roll, value} (value = fraction after the level bonus)
				local key = tostring(e.stat or k)
				stats[key] = math.max(0, num(e.roll, 0))
				if e.value ~= nil then
					local vv = values or {}
					vv[key] = math.max(0, num(e.value, 0))
					values = vv
				end
			else
				stats[k] = math.max(0, num(e, 0))
			end
		end
	end
	local u = g.unique or g.u
	local uid, utext = nil, nil
	if type(u) == "table" then
		uid = if u.id ~= nil then tostring(u.id) else nil
		utext = if u.name then tostring(u.name) .. (if u.text then ": " .. tostring(u.text) else "") else nil
	elseif u ~= nil and u ~= "" and u ~= 0 then
		uid = tostring(u)
	end
	return {
		id = math.floor(tonumber(g.id) :: number),
		tier = math.clamp(math.floor(num(g.tier or g.t, 1)), 1, 12),
		stats = stats,
		values = values,
		unique = uid,
		uniqueText = utext,
		upgrade = tonumber(g.upgradeCost),
		salvage = tonumber(g.salvageDust),
		level = math.clamp(math.floor(num(g.lv or g.level, 0)), 0, GemModel.MAX_LEVEL),
		equipped = nil,
	}
end

-- A stat's bonus fraction after upgrade levels (e.g. rinds 100 points at +2 -> 0.12).
function GemModel.statValue(g: Gem, stat: string, cfg: any): number
	if g.values and g.values[stat] ~= nil then
		return g.values[stat]
	end
	local info = GemModel.STAT_INFO[stat]
	local points = type(cfg) == "table" and (cfg.POINT or cfg.PER)
	local per = num(type(points) == "table" and points[stat], info and info.per or 0)
	return (g.stats[stat] or 0) * per * (1 + GemModel.LEVEL_BONUS * g.level)
end

local function pct(f: number): string
	local v = f * 100
	if v >= 10 then
		return string.format("%d%%", math.floor(v + 0.5))
	end
	return string.format("%.1f%%", v)
end
GemModel.pct = pct

-- "🔶 +4.5% rinds · 🦷 +1.2% bite · …"
function GemModel.lines(g: Gem, cfg: any): { string }
	local out = {}
	for _, k in GemModel.STATS do
		local v = GemModel.statValue(g, k, cfg)
		if v > 0 then
			local info = GemModel.STAT_INFO[k]
			table.insert(
				out,
				string.format("%s %s%s %s", info.icon, info.sign, pct(v), string.lower(info.name))
			)
		end
	end
	return out
end

-- Upgrade cost: level n costs n × tier dust (nil at +5).
function GemModel.upgradeCost(g: Gem): number?
	if g.level >= GemModel.MAX_LEVEL then
		return nil
	end
	return g.upgrade or (g.level + 1) * g.tier
end

-- Salvage: tier dust, +tier if it has a unique.
function GemModel.salvageDust(g: Gem): number
	return g.salvage or (g.tier + (if g.unique then g.tier else 0))
end

function GemModel.uniqueName(u: string?, cfg: any): string?
	if u == nil then
		return nil
	end
	local defs = type(cfg) == "table" and (cfg.UNIQUE_BY_ID or cfg.UNIQUES or cfg.uniques)
	local d = type(defs) == "table" and defs[u]
	if type(d) == "table" and d.name then
		return tostring(d.name) .. (if d.text then ": " .. tostring(d.text) else "")
	end
	return (u:gsub("_", " "):gsub("^%l", string.upper))
end

export type Gems = {
	inv: { Gem },
	sockets: { number },
	open: number,
	socketLevels: { number },
	capacity: number,
	dust: number,
	totals: { [string]: number }, -- your equipped gems, before squad caps
}

function GemModel.view(view: any, profile: any, cfg: any): Gems
	local v = if type(view) == "table" then view else {}
	local levels = if type(v.socketLevels) == "table" then v.socketLevels else { 1, 10, 25 }
	local eq = if type(v.equipped) == "table" then v.equipped else {}
	local sockets: { number } = {}
	local slotOf: { [number]: number } = {}
	for slot = 1, #levels do
		local id = math.floor(num(eq[slot] or eq[tostring(slot)], 0))
		sockets[slot] = id
		if id > 0 then
			slotOf[id] = slot
		end
	end
	local open = tonumber(v.socketsOpen)
	if open == nil then
		local lv = if type(profile) == "table" then num(profile.level, 1) else 1
		open = 0
		for _, need in levels do
			if lv >= num(need, 1) then
				open += 1
			end
		end
	end
	local inv: { Gem } = {}
	local totals: { [string]: number } = {}
	for _, raw in (if type(v.inv) == "table" then v.inv else {}) do
		local g = GemModel.gem(raw)
		if g then
			g.equipped = slotOf[g.id]
			table.insert(inv, g)
			if g.equipped then
				for _, k in GemModel.STATS do
					totals[k] = (totals[k] or 0) + GemModel.statValue(g, k, cfg)
				end
			end
		end
	end
	table.sort(inv, function(a, b)
		if (a.equipped ~= nil) ~= (b.equipped ~= nil) then
			return a.equipped ~= nil
		end
		if a.tier ~= b.tier then
			return a.tier > b.tier
		end
		if (a.unique ~= nil) ~= (b.unique ~= nil) then
			return a.unique ~= nil
		end
		if a.level ~= b.level then
			return a.level > b.level
		end
		return a.id < b.id
	end)
	local dust = v.dust
	if dust == nil and type(profile) == "table" then
		dust = profile.crumbDust or profile.dust
	end
	return {
		inv = inv,
		sockets = sockets,
		open = math.floor(num(open, 1)),
		socketLevels = levels,
		capacity = math.floor(num(v.capacity, 200)),
		dust = math.floor(num(dust, 0)),
		totals = totals,
	}
end

-- Squad total with caps, from a list of per-member totals.
function GemModel.squadTotals(list: { { [string]: number } }): { [string]: number }
	local out: { [string]: number } = {}
	for _, t in list do
		for k, v in t do
			out[k] = (out[k] or 0) + v
		end
	end
	for k, cap in GemModel.CAPS do
		if out[k] then
			out[k] = math.min(out[k], cap)
		end
	end
	return out
end

-- Tier colour (1 pale cheese -> 11 purple, 12 gold).
function GemModel.tierColor(tier: number): { number }
	local t = math.clamp(math.floor(tier), 1, 12)
	if t == 12 then
		return { 255, 205, 40 }
	end
	local a = (t - 1) / 10
	return {
		math.floor(250 - 110 * a + 0.5),
		math.floor(225 - 165 * a + 0.5),
		math.floor(140 + 70 * a + 0.5),
	}
end

return GemModel
