--!strict
-- Pure readers for the v5 long-term screens (Team P profile view, iteration 1
-- §D). No Roblox APIs; specs run them in Lune.
--
--   HerdModel.talents(view)            profile.herdTalents -> board rows
--   HerdModel.evolution(view, cls, stages)   profile.evolution -> one class's track
--   HerdModel.charms(view)             profile.charms -> inventory, sockets, fusable sets

local HerdModel = {}

local function num(v: any, d: number): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return d
	end
	return n
end

export type TalentRow = {
	id: string,
	name: string,
	rank: number,
	max: number,
	cost: number?,
	canBuy: boolean,
	text: string,
	nextText: string?,
}

function HerdModel.talents(view: any): ({ TalentRow }, number, boolean)
	local out: { TalentRow } = {}
	if type(view) ~= "table" then
		return out, 0, false
	end
	local points = math.floor(num(view.points, 0))
	for _, t in (if type(view.talents) == "table" then view.talents else {}) do
		if type(t) == "table" and t.id ~= nil then
			local cost = tonumber(t.nextCost)
			table.insert(out, {
				id = tostring(t.id),
				name = tostring(t.name or t.id),
				rank = math.floor(num(t.rank, 0)),
				max = math.floor(num(t.maxRank, 50)),
				cost = cost,
				canBuy = cost ~= nil and points >= cost,
				text = tostring(t.text or ""),
				nextText = if t.nextText ~= nil then tostring(t.nextText) else nil,
			})
		end
	end
	return out, points, view.freeRespec == true
end

export type EvoStage = { stage: number, name: string, stomps: number, unlocked: boolean, shown: boolean }
export type Evo = {
	stomps: number,
	stage: number,
	display: number,
	pips: number,
	nextStomps: number?,
	stages: { EvoStage },
}

-- `stages` = Config/Evolutions.STAGES ({stage, name, stomps}).
function HerdModel.evolution(view: any, classId: string?, stages: any): Evo
	local c = if type(view) == "table"
			and type(view.classes) == "table"
			and classId
		then view.classes[classId]
		else nil
	local e = if type(c) == "table" then c else {}
	local stage = math.max(1, math.floor(num(e.stage, 1)))
	local display = math.floor(num(e.display, stage))
	local out: Evo = {
		stomps = math.floor(num(e.stomps, 0)),
		stage = stage,
		display = display,
		pips = math.floor(num(e.pips, 0)),
		nextStomps = tonumber(e.nextStomps),
		stages = {},
	}
	for _, s in (if type(stages) == "table" then stages else {}) do
		if type(s) == "table" then
			local n = math.floor(num(s.stage, 0))
			table.insert(out.stages, {
				stage = n,
				name = tostring(s.name or ("Stage " .. n)),
				stomps = math.floor(num(s.stomps, 0)),
				unlocked = n <= stage,
				shown = n == display,
			})
		end
	end
	return out
end

export type Charm = {
	id: number,
	type: string,
	name: string,
	rarity: number,
	rarityName: string,
	text: string,
	equipped: number?,
}
export type FuseSet = { type: string, rarity: number, name: string, rarityName: string, count: number }
export type Charms = {
	inv: { Charm },
	sockets: { number }, -- charm id per slot (0 = empty)
	open: number,
	socketLevels: { number },
	capacity: number,
	fusable: { FuseSet },
	salvage: { number },
}

HerdModel.FUSE_COUNT = 3
HerdModel.MAX_RARITY = 4

function HerdModel.charms(view: any): Charms
	local v = if type(view) == "table" then view else {}
	local sockets: { number } = {}
	local eq = if type(v.equipped) == "table" then v.equipped else {}
	local levels = if type(v.socketLevels) == "table" then v.socketLevels else { 1, 10, 25 }
	local slotOf: { [number]: number } = {}
	for slot = 1, #levels do
		local id = math.floor(num(eq[slot] or eq[tostring(slot)], 0))
		sockets[slot] = id
		if id > 0 then
			slotOf[id] = slot
		end
	end
	local inv: { Charm } = {}
	local groups: { [string]: FuseSet } = {}
	for _, ch in (if type(v.inv) == "table" then v.inv else {}) do
		if type(ch) == "table" and tonumber(ch.id) then
			local id = math.floor(tonumber(ch.id) :: number)
			local rarity = math.floor(num(ch.rarity, 1))
			local e: Charm = {
				id = id,
				type = tostring(ch.type or "?"),
				name = tostring(ch.name or ch.type or "Charm"),
				rarity = rarity,
				rarityName = tostring(ch.rarityName or ""),
				text = tostring(ch.text or ""),
				equipped = slotOf[id],
			}
			table.insert(inv, e)
			-- equipped charms don't count towards a fuse
			if e.equipped == nil and rarity < HerdModel.MAX_RARITY then
				local k = e.type .. ":" .. rarity
				local g = groups[k]
				if not g then
					g =
						{ type = e.type, rarity = rarity, name = e.name, rarityName = e.rarityName, count = 0 }
					groups[k] = g
				end
				g.count += 1
			end
		end
	end
	table.sort(inv, function(a, b)
		if (a.equipped ~= nil) ~= (b.equipped ~= nil) then
			return a.equipped ~= nil
		end
		if a.rarity ~= b.rarity then
			return a.rarity > b.rarity
		end
		if a.type ~= b.type then
			return a.type < b.type
		end
		return a.id < b.id
	end)
	local fusable: { FuseSet } = {}
	for _, g in groups do
		if g.count >= HerdModel.FUSE_COUNT then
			table.insert(fusable, g)
		end
	end
	table.sort(fusable, function(a, b)
		if a.rarity ~= b.rarity then
			return a.rarity > b.rarity
		end
		return a.type < b.type
	end)
	return {
		inv = inv,
		sockets = sockets,
		open = math.floor(num(v.socketsOpen, 1)),
		socketLevels = levels,
		capacity = math.floor(num(v.capacity, 60)),
		fusable = fusable,
		salvage = if type(v.salvageCheese) == "table" then v.salvageCheese else { 25, 100, 400, 1500 },
	}
end

return HerdModel
