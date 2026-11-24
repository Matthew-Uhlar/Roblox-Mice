--!strict
-- Pure ability-slot helpers for the HUD, the input and the hero loadout row
-- (iteration 5 A3). No Roblox APIs: unit-tested under Lune
-- (tests/specs/ClientIter5.spec.luau).
--
-- Slots: 1 at class level 1, 2 at level 10, 3 at level 20; Prestige >= 1
-- keeps all three. Keys: slot 1 Space / Q (and a right-click), slot 2 E
-- (Second Wind keeps E while downed), slot 3 R; gamepad X / Y / B.
--
-- Every reader tolerates the old single-ability shapes (profile
-- classes[id].ability, PlayerHud abilityReadyAt) so the UI never errors while
-- the server side is half-way there, and the new ones:
--   profile classes[id].abilities = { slot1, slot2?, slot3? }
--   PlayerHud: abilityReadyAts = {n...} | abilities / abilitySlots = { {id?, readyAt} | n ... }
--   (abilityReadyAt stays slot 1).

local AbilitySlots = {}

AbilitySlots.MAX = 4
AbilitySlots.UNLOCK_LEVEL = { 1, 10, 20 } -- slots 1-3 by class level (Prestige >= 1 keeps them)
-- (iteration 6) slot 4: Prestige >= 5 OR >= 3 Ascension nodes (Data/ClassProgress
-- SLOT4_PRESTIGE / SLOT4_NODE; the profile view also sends slot4 = {prestige, node}).
AbilitySlots.SLOT4_PRESTIGE = 5
AbilitySlots.SLOT4_NODE = 3

-- Unlocked slot count for a class level / prestige (/ Ascension nodes owned).
function AbilitySlots.count(level: any, prestige: any, nodes: any): number
	local p = tonumber(prestige) or 0
	local n = 0
	if p >= 1 then
		n = #AbilitySlots.UNLOCK_LEVEL
	else
		local l = tonumber(level) or 1
		for _, need in AbilitySlots.UNLOCK_LEVEL do
			if l >= need then
				n += 1
			end
		end
	end
	if p >= AbilitySlots.SLOT4_PRESTIGE or (tonumber(nodes) or 0) >= AbilitySlots.SLOT4_NODE then
		n = AbilitySlots.MAX
	end
	return math.max(1, n)
end

function AbilitySlots.unlockLevel(slot: number): number
	return AbilitySlots.UNLOCK_LEVEL[slot] or math.huge
end

-- "Level 10" / "Level 20" label for a locked slot (nil when slot 1); slot 4
-- "Prestige 5 or Ascension 3" (the profile view's slot4 gate when given).
function AbilitySlots.lockText(slot: number, gate: any): string?
	if slot == 4 then
		local g = if type(gate) == "table" then gate else {}
		return string.format(
			"Prestige %d or Ascension %d",
			tonumber(g.prestige) or AbilitySlots.SLOT4_PRESTIGE,
			tonumber(g.node) or AbilitySlots.SLOT4_NODE
		)
	end
	local l = AbilitySlots.UNLOCK_LEVEL[slot]
	if l == nil or l <= 1 then
		return nil
	end
	return "Level " .. l
end

local function str(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	if type(v) == "table" then
		local id = v.id or v.abilityId
		if type(id) == "string" and id ~= "" then
			return id
		end
	end
	return nil
end

-- The saved loadout of a class block: { [slot]: abilityId? } for slots 1..3.
-- Slot 1 falls back to the old single `ability` field (nil = the base ability).
function AbilitySlots.loadout(classBlock: any): { [number]: string? }
	local out: { [number]: string? } = {}
	if type(classBlock) ~= "table" then
		return out
	end
	local list = classBlock.abilities
	if type(list) == "table" then
		for k, v in list do
			local i = tonumber(k)
			if i and i >= 1 and i <= AbilitySlots.MAX and i == math.floor(i) then
				out[i] = str(v)
			end
		end
	end
	if out[1] == nil then
		out[1] = str(classBlock.ability)
	end
	return out
end

-- Per-slot readyAt server times from a PlayerHud payload ({[slot]: number}).
function AbilitySlots.readyAts(hud: any): { [number]: number }
	local out: { [number]: number } = {}
	if type(hud) ~= "table" then
		return out
	end
	local function fromList(list: any)
		if type(list) ~= "table" then
			return
		end
		for k, v in list do
			local i = tonumber(k)
			if i and i >= 1 and i <= AbilitySlots.MAX then
				local t = if type(v) == "table"
					then tonumber(v.readyAt or v.abilityReadyAt or v.ready)
					else tonumber(v)
				if t then
					out[i] = t
				end
			end
		end
	end
	fromList(hud.abilityReadyAts)
	if next(out) == nil then
		fromList(hud.abilitySlots)
	end
	if next(out) == nil then
		fromList(hud.abilities)
	end
	if out[1] == nil then
		local t = tonumber(hud.abilityReadyAt)
		if t then
			out[1] = t
		end
	end
	return out
end

-- Effective per-slot cooldowns in seconds, when the server sends them
-- (World.getPlayer abilityCooldowns); {} otherwise.
function AbilitySlots.cooldowns(hud: any): { [number]: number }
	local out: { [number]: number } = {}
	local list = if type(hud) == "table" then hud.abilityCooldowns else nil
	if type(list) == "table" then
		for k, v in list do
			local i, n = tonumber(k), tonumber(v)
			if i and n and n > 0 and i >= 1 and i <= AbilitySlots.MAX then
				out[i] = n
			end
		end
	end
	return out
end

-- Unlocked slots of a profile class block: the server's `abilitySlots` count
-- when it sends one, else from level / prestige.
function AbilitySlots.classCount(classBlock: any): number
	if type(classBlock) ~= "table" then
		return 1
	end
	local n = if type(classBlock.abilitySlots) == "number" then classBlock.abilitySlots else nil
	if n then
		return math.clamp(math.floor(n), 1, AbilitySlots.MAX)
	end
	return AbilitySlots.count(classBlock.level, classBlock.prestige)
end

-- Ability ids the server says are in each slot this run ({} if it does not say).
function AbilitySlots.hudIds(hud: any): { [number]: string }
	local out: { [number]: string } = {}
	if type(hud) ~= "table" then
		return out
	end
	for _, key in { "abilityIds", "abilitySlots", "abilities" } do
		local list = hud[key]
		if type(list) == "table" then
			for k, v in list do
				local i = tonumber(k)
				local id = str(v)
				if i and id and i >= 1 and i <= AbilitySlots.MAX then
					out[i] = id
				end
			end
			if next(out) ~= nil then
				return out
			end
		end
	end
	return out
end

-- Number of slots the server says are live this run (nil if it does not say).
function AbilitySlots.hudCount(hud: any): number?
	if type(hud) ~= "table" then
		return nil
	end
	local n = tonumber(hud.abilitySlotCount)
		or (if type(hud.abilitySlots) == "number" then hud.abilitySlots else nil)
	if n then
		return math.clamp(math.floor(n), 1, AbilitySlots.MAX)
	end
	local best = 0
	for _, key in { "abilityReadyAts", "abilityIds", "abilitySlots", "abilities" } do
		local list = hud[key]
		if type(list) == "table" then
			for k in list do
				local i = tonumber(k)
				if i and i >= 1 and i <= AbilitySlots.MAX and i > best then
					best = math.floor(i)
				end
			end
		end
	end
	return if best > 0 then best else nil
end

-- Cooldown tracker: the HUD only sends readyAt, so each slot's total is
-- inferred when a new readyAt arrives. `track` is the caller's state table.
export type Track = { readyAt: { [number]: number }, total: { [number]: number } }

function AbilitySlots.newTrack(): Track
	return { readyAt = {}, total = {} }
end

function AbilitySlots.observe(
	track: Track,
	readyAts: { [number]: number },
	now: number,
	totals: { [number]: number }?
)
	for slot, t in readyAts do
		if t ~= track.readyAt[slot] then
			local rem = t - now
			if rem > 0.05 and rem < 600 then
				track.total[slot] = rem
			end
			track.readyAt[slot] = t
		end
	end
	if totals then
		for slot, n in totals do
			track.total[slot] = n -- the server's effective cooldown wins
		end
	end
end

-- (remaining, total) seconds for a slot; remaining 0 when ready.
function AbilitySlots.remaining(track: Track, slot: number, now: number): (number, number)
	local total = track.total[slot] or 1
	local rem = (track.readyAt[slot] or 0) - now
	if rem <= 0 or rem > 600 then
		return 0, total
	end
	return rem, math.max(total, rem)
end

-- Key hint for a slot in an input mode ("kbm" | "gamepad" | "touch").
function AbilitySlots.keyHint(slot: number, mode: string, dense: boolean?): string
	if mode == "touch" then
		return ""
	elseif mode == "gamepad" then
		return if slot == 1 then "X" elseif slot == 2 then "Y" elseif slot == 3 then "B" else "◀"
	end
	if slot == 1 then
		return if dense then "Space/Q" else "Space / Q / RMB"
	end
	return if slot == 2 then "E" elseif slot == 3 then "R" else "C"
end

-- Remote arguments for UseAbility: slot 1 keeps the old 2-arg form (an older
-- server rejects extra args); slots 2-3 add the slot.
function AbilitySlots.useArgs(aimX: number, aimZ: number, slot: number?): { any }
	local s = slot or 1
	if s <= 1 then
		return { aimX, aimZ }
	end
	return { aimX, aimZ, s }
end

-- Remote arguments for SelectAbility(classId, abilityId?, slot?). Slot 1 with
-- the base ability sends nil (the old "no alternate" form); other slots send
-- the id and the slot.
function AbilitySlots.selectArgs(classId: string, abilityId: string?, slot: number?, baseId: string?): { any }
	local s = slot or 1
	if s <= 1 then
		local id = if abilityId ~= nil and abilityId ~= baseId then abilityId else nil
		return if id then { classId, id } else { classId }
	end
	return { classId, abilityId, s }
end

-- Which slot already holds `abilityId` in a loadout (nil if none). The base
-- ability counts as slot 1 when slot 1 is empty.
function AbilitySlots.slotOf(loadout: { [number]: string? }, abilityId: string, baseId: string?): number?
	for i = 1, AbilitySlots.MAX do
		local cur = loadout[i]
		if cur == nil and i == 1 then
			cur = baseId
		end
		if cur == abilityId then
			return i
		end
	end
	return nil
end

return AbilitySlots
