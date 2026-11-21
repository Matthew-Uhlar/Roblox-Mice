--!strict
-- Damage meter rows (iteration 5 Phase B #1). Pure: no Roblox APIs,
-- unit-tested under Lune (tests/specs/ClientIter5.spec.luau).
--
-- Input: Net.S2C.Meter / Results.meter
--   { [heroId]: { name, squad, dmg, pveDmg, pvpDmg, heal, taken, kills, deaths } }
-- (keys may arrive as strings; any field may be missing). Output: rows sorted
-- by damage (then kills, then name), with your squad / you flagged and bots
-- marked (ids <= -1001, Util/Ids).

local MeterModel = {}

export type Row = {
	id: number,
	name: string,
	squad: number?,
	dmg: number,
	pve: number,
	pvp: number,
	heal: number,
	taken: number,
	kills: number,
	deaths: number,
	bot: boolean,
	mine: boolean, -- in your squad
	me: boolean,
	frac: number, -- dmg / top dmg (bar width), 0..1
	rank: number,
}

local function num(v: any): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return 0
	end
	return math.max(0, n)
end

function MeterModel.isBot(id: number): boolean
	return id <= -1001
end

function MeterModel.rows(meter: any, mySquad: any, myId: any, isBot: ((number) -> boolean)?): { Row }
	local out: { Row } = {}
	if type(meter) ~= "table" then
		return out
	end
	local sq = tonumber(mySquad)
	local me = tonumber(myId)
	local botFn = isBot or MeterModel.isBot
	for k, e in meter do
		local id = tonumber(k) or (if type(e) == "table" then tonumber(e.id) else nil)
		if id and type(e) == "table" then
			local pve, pvp = num(e.pveDmg), num(e.pvpDmg)
			local dmg = if e.dmg ~= nil then num(e.dmg) else pve + pvp
			local s = tonumber(e.squad)
			table.insert(out, {
				id = id,
				name = if e.name ~= nil then tostring(e.name) else ("Hero " .. tostring(id)),
				squad = s,
				dmg = dmg,
				pve = pve,
				pvp = pvp,
				heal = num(e.heal),
				taken = num(e.taken),
				kills = math.floor(num(e.kills)),
				deaths = math.floor(num(e.deaths)),
				bot = e.isBot == true or botFn(id),
				mine = sq ~= nil and s == sq,
				me = me ~= nil and id == me,
				frac = 0,
				rank = 0,
			})
		end
	end
	table.sort(out, function(a, b)
		if a.dmg ~= b.dmg then
			return a.dmg > b.dmg
		elseif a.kills ~= b.kills then
			return a.kills > b.kills
		elseif a.name ~= b.name then
			return a.name < b.name
		end
		return a.id < b.id
	end)
	local top = if out[1] then out[1].dmg else 0
	for i, r in out do
		r.rank = i
		r.frac = if top > 0 then math.clamp(r.dmg / top, 0, 1) else 0
	end
	return out
end

-- The rows to show in a short live panel: the top `n`, plus you (and your
-- squad) when you are below the cut.
function MeterModel.top(rows: { Row }, n: number): { Row }
	local out: { Row } = {}
	for i, r in rows do
		if i <= n then
			table.insert(out, r)
		end
	end
	for i, r in rows do
		if i > n and (r.me or r.mine) then
			table.insert(out, r)
		end
	end
	return out
end

-- Compact number: 950, 12.3k, 4.5M.
function MeterModel.short(n: number): string
	local a = math.abs(n)
	if a >= 1e6 then
		return string.format("%.1fM", n / 1e6)
	elseif a >= 1e4 then
		return string.format("%.0fk", n / 1e3)
	elseif a >= 1e3 then
		return string.format("%.1fk", n / 1e3)
	end
	return tostring(math.floor(n + 0.5))
end

-- Display name with the bot tag (bots are always labelled 🤖).
function MeterModel.label(r: Row): string
	return (if r.bot then "🤖 " else "") .. r.name .. (if r.me then " (you)" else "")
end

return MeterModel
