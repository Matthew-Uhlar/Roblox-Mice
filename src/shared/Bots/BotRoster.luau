--!strict
-- Party-fill bot roster (GDD §3.6). Pure: no Instances, deterministic with an Rng.
--
--   BotRoster.fill(humanCount, maxParty?, minParty?, takenClassIds?, rng?, takenIds?)
--     -> { BotSpec }
--
-- Fills the party up to `minParty` (default 3) heroes and never past `maxParty`
-- (default 4), so bots never take a slot from a real player. A solo player gets
-- 2 bots; 3 or 4 humans get none. Bots pick FREE classes only, preferring
-- roles nobody in the party covers yet (tank -> ranged -> support).
--
-- Bot ids live in their own band, Ids.botId(n) = -1001, -1002, ... (Util/Ids,
-- docs/ARCHITECTURE.md "Team F"); Studio test players (-1..-8) are humans.
-- `takenIds` (optional) lists ids already in use; ids in that list are skipped.
--
-- v2 squads (docs/GDD-v2.md §1: 12 seats = 4 squads x 3):
--
--   BotRoster.partyIds(ids, links) -> {[id] = partyId}
--     Union-find over "came together" links (Roblox join data, FollowUserId,
--     IsFriendsWith). partyId = the smallest id in the group.
--   BotRoster.partition(humans, squadCount?, size?) -> (squads, overflow)
--     Seats humans ({id, partyId?, ...}) so friends share a squad. Groups larger
--     than a squad are split into squad-sized chunks; groups are placed largest
--     first into the fullest squad that still fits them (best fit), so strangers
--     are grouped up too. A group that fits nowhere is split over the squads with
--     room; anyone beyond the seats is returned in `overflow`.
--   BotRoster.fillSquads(humans, rng?, opts?) -> ({[squad] = {SquadMember}}, overflow)
--     partition + a bot in every empty seat, so all 4 squads exist (a solo
--     player gets 2 bot mates and 3 bot squads). Bot classes keep each squad
--     diverse (its missing roles first, then classes unused in the match).
--     Squad colours are assigned to the packed squads in a seeded random order.
--     opts: { squads = 4, size = 3, mates = true, takenIds = {} }. mates = false:
--     squads that hold humans get no bot mates (the v1 "bot teammates" toggle);
--     every other seat is still filled.

local Rng = require("../Util/Rng")
local Classes = require("../Config/Classes")
local Ids = require("../Util/Ids")
local Squads = require("../Util/Squads")

type Rng = Rng.Rng

export type BotSpec = {
	id: number,
	name: string,
	classId: string,
	isBot: boolean,
	role: string,
}

local BotRoster = {}

BotRoster.MAX_PARTY = 4
BotRoster.MIN_PARTY = 3
BotRoster.TAG = "🤖"

-- Party roles bots try to cover, in priority order.
BotRoster.ROLE_ORDER = { "tank", "ranged", "support" }

-- Class id -> party role. Unknown classes count as "ranged".
BotRoster.CLASS_ROLES = {
	elephante = "tank",
	ele_fonte = "ranged",
	ellie_fawn = "support",
	le_fante = "tank",
	filet = "support",
	jumbo = "support",
	fizzante = "ranged",
} :: { [string]: string }

-- Used only when Config/Classes is missing or has no free classes.
BotRoster.FALLBACK_FREE = { "elephante", "ele_fonte", "ellie_fawn" }

-- Kid-friendly, original elephant names (no licensed characters).
BotRoster.NAMES = {
	"Peanut",
	"Tusky",
	"Wrinkles",
	"Ellie",
	"Trunky",
	"Pachy",
	"Bumble",
	"Noodle",
	"Pebble",
	"Waffles",
	"Mosey",
	"Tootles",
	"Biscuit",
	"Puddle",
	"Rumble",
	"Dumpling",
	"Squeaky",
	"Marshmallow",
	"Stompy",
	"Clover",
}

function BotRoster.roleOf(classId: string): string
	return BotRoster.CLASS_ROLES[classId] or "ranged"
end

-- Free class ids in config order (unlockCost 0).
function BotRoster.freeClassIds(): { string }
	local out: { string } = {}
	local ok, ids = pcall(function()
		return (Classes :: any).freeIds()
	end)
	if ok and type(ids) == "table" then
		for _, id in ids do
			if type(id) == "string" then
				table.insert(out, id)
			end
		end
	end
	if #out == 0 then
		for _, id in BotRoster.FALLBACK_FREE do
			table.insert(out, id)
		end
	end
	return out
end

local function count(humanCount: number, maxParty: number, minParty: number): number
	local humans = math.max(0, math.floor(humanCount))
	local want = math.max(0, minParty - humans)
	local room = math.max(0, maxParty - humans)
	return math.min(want, room)
end

-- Number of bots `fill` would add.
function BotRoster.botCount(humanCount: number, maxParty: number?, minParty: number?): number
	return count(humanCount, maxParty or BotRoster.MAX_PARTY, minParty or BotRoster.MIN_PARTY)
end

function BotRoster.isBotId(id: any): boolean
	return Ids.isBot(id)
end

export type SquadMember = {
	id: number,
	squad: number,
	isBot: boolean,
	classId: string?,
	name: string?,
	partyId: number?,
	role: string?,
}

-- Picks a free class for a bot: the squad's first uncovered role (preferring a
-- class nobody in the match uses yet), else a class unused in the squad / match.
local function pickClass(
	r: Rng,
	free: { string },
	covered: { [string]: boolean },
	usedInSquad: { [string]: boolean },
	usedInMatch: { [string]: number }
): string
	local function score(cid: string): number
		return (if usedInSquad[cid] then 100 else 0) + (usedInMatch[cid] or 0)
	end
	local function best(list: { string }): string?
		if #list == 0 then
			return nil
		end
		local lo = math.huge
		for _, cid in list do
			lo = math.min(lo, score(cid))
		end
		local pool = {}
		for _, cid in list do
			if score(cid) == lo then
				table.insert(pool, cid)
			end
		end
		return r:pick(pool)
	end
	for _, role in BotRoster.ROLE_ORDER do
		if not covered[role] then
			local ofRole = {}
			for _, cid in free do
				if BotRoster.roleOf(cid) == role then
					table.insert(ofRole, cid)
				end
			end
			local choice = best(ofRole)
			if choice then
				return choice
			end
		end
	end
	return best(free) :: string
end

function BotRoster.partyIds(ids: { number }, links: { { number } }?): { [number]: number }
	local parent: { [number]: number } = {}
	for _, id in ids do
		parent[id] = id
	end
	local function find(x: number): number
		while parent[x] ~= x do
			parent[x] = parent[parent[x]]
			x = parent[x]
		end
		return x
	end
	for _, link in links or {} do
		local a, b = link[1], link[2]
		if parent[a] ~= nil and parent[b] ~= nil then
			local ra, rb = find(a), find(b)
			if ra ~= rb then
				-- the smaller id becomes the root, so partyId = min id of the group
				if ra < rb then
					parent[rb] = ra
				else
					parent[ra] = rb
				end
			end
		end
	end
	local out: { [number]: number } = {}
	for _, id in ids do
		out[id] = find(id)
	end
	return out
end

function BotRoster.partition(humans: { any }, squadCount: number?, size: number?): ({ { any } }, { any })
	local nSquads = squadCount or Squads.MAX
	local cap = size or Squads.SIZE
	-- Groups by partyId in first-appearance order (no partyId = a group of one).
	local groups: { { any } } = {}
	local byParty: { [any]: { any } } = {}
	local seen: { [any]: boolean } = {}
	for _, h in humans do
		if type(h) == "table" and h.id ~= nil and not seen[h.id] then
			seen[h.id] = true
			local key = if h.partyId ~= nil then h.partyId else { h.id }
			local g = byParty[key]
			if not g then
				g = {}
				byParty[key] = g
				table.insert(groups, g)
			end
			table.insert(g, h)
		end
	end
	-- Split groups bigger than a squad.
	local chunks: { { any } } = {}
	for _, g in groups do
		local i = 1
		while i <= #g do
			table.insert(chunks, table.move(g, i, math.min(#g, i + cap - 1), 1, {}))
			i += cap
		end
	end
	-- Largest first; stable on the original order.
	local order = {}
	for i = 1, #chunks do
		order[i] = i
	end
	table.sort(order, function(a, b)
		if #chunks[a] ~= #chunks[b] then
			return #chunks[a] > #chunks[b]
		end
		return a < b
	end)
	local squads: { { any } } = {}
	for i = 1, nSquads do
		squads[i] = {}
	end
	local overflow = {}
	for _, ci in order do
		local chunk = chunks[ci]
		local bestI, bestRoom = nil, math.huge
		for i, sq in squads do
			local room = cap - #sq
			if room >= #chunk and room < bestRoom then
				bestI, bestRoom = i, room
			end
		end
		if bestI then
			for _, h in chunk do
				table.insert(squads[bestI], h)
			end
		else
			-- Fits nowhere whole: split over the squads with the most room.
			for _, h in chunk do
				local roomI, room = nil, 0
				for i, sq in squads do
					if cap - #sq > room then
						roomI, room = i, cap - #sq
					end
				end
				if roomI then
					table.insert(squads[roomI], h)
				else
					table.insert(overflow, h)
				end
			end
		end
	end
	return squads, overflow
end

function BotRoster.fillSquads(
	humans: { any },
	rng: Rng?,
	opts: { squads: number?, size: number?, mates: boolean?, takenIds: { number }? }?
): ({ [number]: { SquadMember } }, { any })
	local o = opts or {}
	local nSquads = o.squads or Squads.MAX
	local cap = o.size or Squads.SIZE
	local r: Rng = rng or Rng.new(1)
	local packed, overflow = BotRoster.partition(humans, nSquads, cap)

	-- Colours: packed squads take the squad ids in a seeded random order.
	local slots = {}
	for i = 1, nSquads do
		slots[i] = i
	end
	r:shuffle(slots)

	local usedIds: { [number]: boolean } = {}
	for _, id in o.takenIds or {} do
		usedIds[id] = true
	end
	for _, h in humans do
		if type(h) == "table" and type(h.id) == "number" then
			usedIds[h.id] = true
		end
	end
	local free = BotRoster.freeClassIds()
	local names = r:shuffle(table.clone(BotRoster.NAMES))
	local usedInMatch: { [string]: number } = {}
	for _, list in packed do
		for _, h in list do
			if type(h.classId) == "string" then
				usedInMatch[h.classId] = (usedInMatch[h.classId] or 0) + 1
			end
		end
	end
	local n = 0 -- bot counter (Ids.botId(n))
	local made = 0 -- bots made (names)
	local out: { [number]: { SquadMember } } = {}
	for i, list in packed do
		local squad = slots[i]
		local members: { SquadMember } = {}
		local covered: { [string]: boolean } = {}
		local usedInSquad: { [string]: boolean } = {}
		for _, h in list do
			local cid = if type(h.classId) == "string" then h.classId else nil
			if cid then
				covered[BotRoster.roleOf(cid)] = true
				usedInSquad[cid] = true
			end
			table.insert(members, {
				id = h.id,
				squad = squad,
				isBot = false,
				classId = cid,
				name = if type(h.name) == "string" then h.name else nil,
				partyId = h.partyId,
				role = if cid then BotRoster.roleOf(cid) else nil,
			})
		end
		local wantBots = if #list > 0 and o.mates == false then 0 else cap - #list
		for _ = 1, wantBots do
			local classId = pickClass(r, free, covered, usedInSquad, usedInMatch)
			covered[BotRoster.roleOf(classId)] = true
			usedInSquad[classId] = true
			usedInMatch[classId] = (usedInMatch[classId] or 0) + 1
			repeat
				n += 1
			until not usedIds[Ids.botId(n)]
			local id = Ids.botId(n)
			usedIds[id] = true
			made += 1
			local base = names[((made - 1) % #names) + 1]
			if made > #names then
				base ..= " " .. tostring(math.floor((made - 1) / #names) + 1)
			end
			table.insert(members, {
				id = id,
				squad = squad,
				isBot = true,
				classId = classId,
				name = base .. " " .. BotRoster.TAG,
				role = BotRoster.roleOf(classId),
			})
		end
		out[squad] = members
	end
	return out, overflow
end

-- Flattens fillSquads' result into a list, squad 1 first.
function BotRoster.flatten(squads: { [number]: { SquadMember } }): { SquadMember }
	local list = {}
	for s = 1, Squads.MAX do
		for _, m in squads[s] or {} do
			table.insert(list, m)
		end
	end
	return list
end

function BotRoster.fill(
	humanCount: number,
	maxParty: number?,
	minParty: number?,
	takenClassIds: { string }?,
	rng: Rng?,
	takenIds: { number }?
): { BotSpec }
	local n = count(humanCount, maxParty or BotRoster.MAX_PARTY, minParty or BotRoster.MIN_PARTY)
	local out: { BotSpec } = {}
	if n == 0 then
		return out
	end
	local r: Rng = rng or Rng.new(1)

	-- Roles already covered (humans' classes, then each bot as it is added).
	local covered: { [string]: boolean } = {}
	local usedClass: { [string]: boolean } = {}
	for _, cid in takenClassIds or {} do
		covered[BotRoster.roleOf(cid)] = true
		usedClass[cid] = true
	end

	local free = BotRoster.freeClassIds()
	local names = r:shuffle(table.clone(BotRoster.NAMES))
	local usedIds: { [number]: boolean } = {}
	for _, id in takenIds or {} do
		usedIds[id] = true
	end
	local nextId = Ids.botId(1)

	for i = 1, n do
		-- 1. A free class for the first uncovered role (prefer unused classes).
		local choice: string? = nil
		for _, role in BotRoster.ROLE_ORDER do
			if not covered[role] then
				local fresh, any = {}, {}
				for _, cid in free do
					if BotRoster.roleOf(cid) == role then
						table.insert(any, cid)
						if not usedClass[cid] then
							table.insert(fresh, cid)
						end
					end
				end
				if #fresh > 0 then
					choice = r:pick(fresh)
				elseif #any > 0 then
					choice = r:pick(any)
				end
				if choice then
					break
				end
			end
		end
		-- 2. Every role covered: a free class nobody uses yet, else any free class.
		if not choice then
			local fresh = {}
			for _, cid in free do
				if not usedClass[cid] then
					table.insert(fresh, cid)
				end
			end
			choice = r:pick(if #fresh > 0 then fresh else free)
		end
		local classId = choice :: string
		covered[BotRoster.roleOf(classId)] = true
		usedClass[classId] = true

		while usedIds[nextId] do
			nextId -= 1
		end
		local id = nextId
		usedIds[id] = true
		nextId -= 1

		local base = names[((i - 1) % #names) + 1]
		if i > #names then
			base ..= " " .. tostring(math.floor((i - 1) / #names) + 1)
		end
		table.insert(out, {
			id = id,
			name = base .. " " .. BotRoster.TAG,
			classId = classId,
			isBot = true,
			role = BotRoster.roleOf(classId),
		})
	end
	return out
end

return BotRoster
