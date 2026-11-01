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
-- Bot ids are negative integers -1, -2, ... (docs/ARCHITECTURE.md "Team F").
-- `takenIds` (optional) lists ids already in use: Studio local-server test
-- players have negative UserIds (-1, -2, ...), so ids in that list are skipped.

local Rng = require("../Util/Rng")
local Classes = require("../Config/Classes")
local Ids = require("../Util/Ids")

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
