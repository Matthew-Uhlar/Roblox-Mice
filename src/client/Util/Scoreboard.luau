--!strict
-- Pure helpers for the squad scoreboard (no Roblox APIs; tested in
-- tests/specs/ClientV2.spec.luau).
--
-- Net.S2C.Match carries `squads = {[1..4] = {name, color, members = {id…},
-- pending, alive, extracted, eliminated, kills, isYou}}`. Over the network the
-- keys of a sparse table may arrive as strings, members may be missing, and
-- numbers may be strings; `normalise` copes with all of that.

local Scoreboard = {}

export type Squad = {
	id: number,
	name: string,
	color: { number },
	members: { number },
	pending: number,
	alive: number,
	extracted: boolean,
	eliminated: boolean,
	kills: number,
	isYou: boolean,
	doubleOrNothing: boolean,
}

-- v2 defaults (src/shared/Util/Squads.luau), duplicated here so this module
-- stays dependency-free for Lune.
Scoreboard.DEFAULTS = {
	{ name = "Swiss", color = { 255, 200, 60 } },
	{ name = "Brie", color = { 245, 240, 220 } },
	{ name = "Blue", color = { 80, 150, 255 } },
	{ name = "Pepper Jack", color = { 235, 70, 60 } },
}

local function num(v: any, default: number): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return default
	end
	return n
end

local function rgb(c: any, fallback: { number }): { number }
	if type(c) == "table" then
		local r = tonumber(c[1] or c.r or c.R)
		local g = tonumber(c[2] or c.g or c.G)
		local b = tonumber(c[3] or c.b or c.B)
		if r and g and b then
			return { r, g, b }
		end
	end
	return fallback
end

local function idList(t: any): { number }
	local out = {}
	if type(t) ~= "table" then
		return out
	end
	for _, v in t do
		local n = tonumber(v)
		if n then
			table.insert(out, n)
		elseif type(v) == "table" and tonumber(v.id) then
			table.insert(out, tonumber(v.id) :: number)
		end
	end
	return out
end

-- One squad entry from the payload (id = 1..4).
function Scoreboard.squad(id: number, s: any, mySquad: number?): Squad
	local d = Scoreboard.DEFAULTS[id] or { name = "Squad " .. tostring(id), color = { 200, 200, 200 } }
	local t = if type(s) == "table" then s else {}
	local members = idList(t.members)
	-- Server (R1): `alive` is a boolean (still in the run) and `aliveCount` the
	-- members standing; an older payload may send `alive` as the count.
	local alive = if tonumber(t.aliveCount)
		then num(t.aliveCount, 0)
		elseif type(t.alive) == "number" or tonumber(t.alive) then num(t.alive, 0)
		elseif t.alive == false or t.eliminated == true then 0
		else #members
	return {
		id = id,
		name = if type(t.name) == "string" and t.name ~= "" then t.name else d.name,
		color = rgb(t.color, d.color),
		members = members,
		pending = math.max(0, math.floor(num(t.pending, 0))),
		alive = math.max(0, math.floor(alive)),
		extracted = t.extracted == true,
		eliminated = t.eliminated == true,
		kills = math.max(0, math.floor(num(t.kills, 0))),
		isYou = t.isYou == true or (mySquad ~= nil and mySquad == id),
		doubleOrNothing = t.doubleOrNothing == true,
	}
end

-- Squads payload (array or map with string keys) -> array of Squad, by id.
function Scoreboard.normalise(squads: any, mySquad: number?): { Squad }
	local out = {}
	if type(squads) ~= "table" then
		return out
	end
	for k, s in squads do
		local id = tonumber(k)
		if type(s) == "table" and tonumber(s.id) then
			id = tonumber(s.id)
		end
		if id and id >= 1 and id <= 8 and id == math.floor(id) then
			table.insert(out, Scoreboard.squad(id, s, mySquad))
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

-- 0 = still in the run, 1 = extracted (safe, done), 2 = eliminated.
function Scoreboard.statusRank(s: Squad): number
	if s.eliminated then
		return 2
	elseif s.extracted then
		return 1
	end
	return 0
end

-- Ranking for the full scoreboard and the results placement:
--   1. squads not eliminated (in the run or extracted) above eliminated ones;
--   2. more pending cheese first (for extracted squads: what they banked);
--   3. more kills; 4. more heroes alive; 5. lower squad id (stable).
function Scoreboard.less(a: Squad, b: Squad): boolean
	local ea, eb = if a.eliminated then 1 else 0, if b.eliminated then 1 else 0
	if ea ~= eb then
		return ea < eb
	end
	if a.pending ~= b.pending then
		return a.pending > b.pending
	end
	if a.kills ~= b.kills then
		return a.kills > b.kills
	end
	if a.alive ~= b.alive then
		return a.alive > b.alive
	end
	return a.id < b.id
end

-- Returns a new, sorted array (the input is left untouched).
function Scoreboard.sort(list: { Squad }): { Squad }
	local out = table.clone(list)
	table.sort(out, Scoreboard.less)
	return out
end

-- 1-based placement of squad `id` in the sorted ranking (nil if absent).
function Scoreboard.placement(list: { Squad }, id: number): number?
	for i, s in Scoreboard.sort(list) do
		if s.id == id then
			return i
		end
	end
	return nil
end

-- Which squad has member `memberId` (nil if none).
function Scoreboard.squadOf(list: { Squad }, memberId: number): number?
	for _, s in list do
		for _, m in s.members do
			if m == memberId then
				return s.id
			end
		end
	end
	return nil
end

-- "1st", "2nd", "3rd", "4th"…
function Scoreboard.ordinal(n: number): string
	local v = math.floor(n)
	local tens = v % 100
	if tens >= 11 and tens <= 13 then
		return tostring(v) .. "th"
	end
	local last = v % 10
	return tostring(v)
		.. (if last == 1 then "st" elseif last == 2 then "nd" elseif last == 3 then "rd" else "th")
end

return Scoreboard
