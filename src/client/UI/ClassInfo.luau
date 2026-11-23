--!strict
-- Per-class progression for the UI (GDD-v2 §5): level, XP, mastery, perk
-- points, the perk tree, alternate abilities and skins. The authorities are
-- Shared.Data.ClassProgress and Shared.Config.{ClassPerks, ClassAbilities,
-- ClassSkins} (Team R3), written in parallel: each is pcall-required and every
-- answer falls back to Util/ClassMath (the GDD numbers) or to a labelled
-- placeholder, so the lobby never breaks while those modules are missing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Defs = require(Client.Util.Defs)
local ClassMath = require(Client.Util.ClassMath)
local PerkTree = require(Client.Util.PerkTree)
local AbilitySlots = require(Client.Util.AbilitySlots)
local State = require(Client.Controllers.State)

local ClassInfo = {}

local RETRY = 5
local progressMod: any = nil
local progressRetryAt = 0

-- Shared.Data.ClassProgress (pure, R3), or nil.
function ClassInfo.progressModule(): any
	if progressMod then
		return progressMod
	end
	if os.clock() < progressRetryAt then
		return nil
	end
	progressRetryAt = os.clock() + RETRY
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local data = shared and shared:FindFirstChild("Data")
	local inst = data and data:FindFirstChild("ClassProgress")
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		if ok and type(mod) == "table" then
			progressMod = mod
			return mod
		end
	end
	return nil
end

local function call(mod: any, fname: string, ...: any): any
	if type(mod) ~= "table" or type(mod[fname]) ~= "function" then
		return nil
	end
	local ok, res = pcall(mod[fname], ...)
	return if ok then res else nil
end

export type Progress = {
	classId: string,
	level: number,
	xp: number,
	toNext: number,
	frac: number,
	maxed: boolean,
	mastery: string, -- "none" | "bronze" | "silver" | "gold"
	masteryName: string?,
	perks: { [string]: boolean },
	spent: number,
	free: number,
	ability: string?,
	skin: string?,
	known: boolean, -- the profile has a block for this class
	prestige: number, -- iteration 2
	shown: number, -- the level to show (displayLevel after a Prestige)
	shownText: string, -- "Lv 7", or "Lv 30 ⭐3" after a Prestige (T-15)
	prestigePct: number?, -- % of the way to the next Prestige
	respecCost: number?,
	unlockedAbilities: { [string]: boolean }?,
	unlockedSkins: { [string]: boolean }?,
}

function ClassInfo.progress(classId: string): Progress
	local st = State.classState(classId)
	local cp = ClassInfo.progressModule()
	local toNext = st.xpToNext or tonumber(call(cp, "xpToNext", st.level)) or ClassMath.xpToNext(st.level)
	local mastery = st.mastery or call(cp, "mastery", st.level)
	if type(mastery) ~= "string" then
		mastery = ClassMath.mastery(st.level)
	end
	local tree = ClassInfo.tree(classId)
	local spent = PerkTree.spent(tree, st.perks)
	if tree.placeholder then
		for _ in st.perks do
			spent += 1
		end
	end
	local free = st.perkPointsFree
		or tonumber(call(cp, "perkPointsFree", {
			xp = st.xp,
			level = st.level,
			perks = st.perks,
			perkPoints = st.perkPoints,
		}))
	if free == nil then
		free = PerkTree.freePoints(st.level, spent, nil)
	end
	local maxed = st.level >= (st.maxLevel or ClassMath.MAX_LEVEL)
	-- T-15: a prestiged hero is level 30 with ⭐N; the re-climb shows as a percent
	local shown = math.max(1, math.floor(st.displayLevel or st.level))
	local pPct: number? = nil
	if st.prestige > 0 then
		shown = ClassMath.MAX_LEVEL
		local need = st.prestigeXpToNext or 12000
		pPct = math.clamp(math.floor((st.prestigeXp or 0) / math.max(1, need) * 100), 0, 100)
	end
	return {
		prestige = st.prestige,
		shown = shown,
		prestigePct = pPct,
		shownText = "Lv " .. shown .. (if st.prestige > 0 then " ⭐" .. st.prestige else ""),
		classId = classId,
		level = st.level,
		xp = st.xp,
		toNext = toNext,
		frac = if maxed then 1 else math.clamp(st.xp / math.max(1, toNext), 0, 1),
		maxed = maxed,
		mastery = mastery,
		masteryName = ClassMath.masteryName(mastery),
		perks = st.perks,
		spent = spent,
		free = math.max(0, math.floor(free :: number)),
		ability = st.ability,
		skin = st.skin,
		known = st.known,
		respecCost = st.respecCost,
		unlockedAbilities = st.unlockedAbilities,
		unlockedSkins = st.unlockedSkins,
	}
end

----------------------------------------------------------------------
-- Config readers (unknown layouts)
----------------------------------------------------------------------

-- Per-class list from a config module: functions, by-class maps or a flat list.
local function perClass(mod: any, classId: string): { any }?
	if type(mod) ~= "table" then
		return nil
	end
	for _, f in { "forClass", "get", "list", "ofClass", "byClassId" } do
		local r = call(mod, f, classId)
		if type(r) == "table" then
			return r
		end
	end
	for _, field in { "byClass", "BY_CLASS", "CLASSES", "classes" } do
		local t = mod[field]
		if type(t) == "table" and type(t[classId]) == "table" then
			return t[classId]
		end
	end
	if type(mod[classId]) == "table" then
		return mod[classId]
	end
	for _, field in { "LIST", "ALL", "list", "all" } do
		local t = mod[field]
		if type(t) == "table" then
			local out = {}
			for _, d in t do
				if type(d) == "table" and tostring(d.classId or d.class) == classId then
					table.insert(out, d)
				end
			end
			if #out > 0 then
				return out
			end
		end
	end
	return nil
end

-- Flattens {base = …, alternates = {…}} / {…} into an ordered array of defs.
local function flatten(t: any): { any }
	local out = {}
	if type(t) ~= "table" then
		return out
	end
	if #t > 0 then
		for _, d in ipairs(t) do
			if type(d) == "table" then
				table.insert(out, d)
			elseif type(d) == "string" then
				table.insert(out, { id = d })
			end
		end
		return out
	end
	local base = t.base or t.default
	if type(base) == "table" then
		table.insert(out, base)
	end
	local alts = t.alternates or t.alts or t.alternate
	if type(alts) == "table" then
		for _, d in ipairs(alts) do
			if type(d) == "table" then
				table.insert(out, d)
			end
		end
	end
	if #out == 0 then
		for k, d in t do
			if type(d) == "table" then
				local c = table.clone(d)
				c.id = c.id or k
				table.insert(out, c)
			end
		end
		table.sort(out, function(a, b)
			local la = tonumber(a.unlockLevel or a.level) or 0
			local lb = tonumber(b.unlockLevel or b.level) or 0
			if la ~= lb then
				return la < lb
			end
			return tostring(a.id) < tostring(b.id)
		end)
	end
	return out
end

local function unlockedSet(fname: string, classId: string, level: number): { [string]: boolean }?
	local r = call(ClassInfo.progressModule(), fname, classId, level)
	if type(r) ~= "table" then
		return nil
	end
	local set: { [string]: boolean } = {}
	for k, v in r do
		if v == true then
			set[tostring(k)] = true
		elseif type(v) == "string" then
			set[v] = true
		elseif type(v) == "table" and v.id then
			set[tostring(v.id)] = true
		end
	end
	return set
end

export type Choice = {
	id: string,
	name: string,
	description: string,
	unlockLevel: number,
	unlocked: boolean,
	selected: boolean,
	placeholder: boolean,
	color: { number }?,
}

-- Base ability + 2 alternates (unlock at class levels 5 and 15).
function ClassInfo.abilities(classId: string, level: number, selected: string?): { Choice }
	local classDef = Defs.get("Classes", classId)
	local base = classDef and classDef.ability
	local list = flatten(perClass(Defs.module("ClassAbilities"), classId))
	local unlocked = State.classState(classId).unlockedAbilities
		or unlockedSet("unlockedAbilities", classId, level)
	local out: { Choice } = {}
	local function push(d: any, i: number, placeholder: boolean)
		-- R3 entries are {id, classId, slot, unlockLevel, def = AbilityDef}.
		local ad = if type(d.def) == "table" then d.def else d
		local lv = tonumber(d.unlockLevel or d.level) or ClassMath.ABILITY_LEVELS[i] or 1
		local id = tostring(d.id or (if i == 1 then "base" else "alt" .. (i - 1)))
		local open = if unlocked then (unlocked[id] == true or (i == 1 and lv <= 1)) else level >= lv
		table.insert(out, {
			id = id,
			name = tostring(
				ad.name or d.name or (if i == 1 then "Base ability" else "Alternate " .. (i - 1))
			),
			description = tostring(ad.description or d.description or d.desc or ""),
			unlockLevel = lv,
			unlocked = open and not placeholder,
			selected = false,
			placeholder = placeholder,
		})
	end
	if #list > 0 then
		-- The config may or may not list the base ability first.
		local firstLv = tonumber(list[1].unlockLevel or list[1].level) or 1
		if firstLv > 1 and base then
			push(
				{ id = base.id or "base", name = base.name, description = base.description, unlockLevel = 1 },
				1,
				false
			)
		end
		for _, d in list do
			if #out >= 3 then
				break
			end
			push(d, #out + 1, false)
		end
	elseif base then
		push(
			{ id = base.id or "base", name = base.name, description = base.description, unlockLevel = 1 },
			1,
			false
		)
	end
	while #out < 3 do
		local i = #out + 1
		push({
			id = "locked" .. i,
			name = if i == 1 then "Base ability" else "Alternate ability",
			description = "Coming soon: alternate abilities are on their way.",
			unlockLevel = ClassMath.ABILITY_LEVELS[i],
		}, i, i > 1)
		if i == 1 then
			out[1].unlocked = true
		end
	end
	local sel = out[1].id
	for _, c in out do
		if c.id == selected and c.unlocked then
			sel = c.id
		end
	end
	for _, c in out do
		c.selected = c.id == sel
	end
	return out
end

-- iteration 5 (A3): display name of an ability id (nil = the class's base ability).
function ClassInfo.abilityName(classId: string, abilityId: string?): string
	local classDef = Defs.get("Classes", classId)
	local base = classDef and classDef.ability
	if abilityId ~= nil then
		local e = Defs.get("ClassAbilities", abilityId)
		local ad = if type(e) == "table" then (if type(e.def) == "table" then e.def else e) else nil
		if ad and ad.name then
			return tostring(ad.name)
		end
		if type(base) == "table" and base.id == abilityId and base.name then
			return tostring(base.name)
		end
	end
	return if type(base) == "table" and base.name then tostring(base.name) else "Ability"
end

-- iteration 6: the AbilityDef of an ability id (nil = the class's base
-- ability), or nil. Used for the ability icons and the builder's placement
-- ghost (kind / distance).
function ClassInfo.abilityDef(classId: string, abilityId: string?): any
	local classDef = Defs.get("Classes", classId)
	local base = classDef and classDef.ability
	if abilityId ~= nil then
		local e = Defs.get("ClassAbilities", abilityId)
		local ad = if type(e) == "table" then (if type(e.def) == "table" then e.def else e) else nil
		if type(ad) == "table" then
			return ad
		end
		if type(base) == "table" and base.id ~= nil and base.id ~= abilityId then
			return nil
		end
	end
	return if type(base) == "table" then base else nil
end

-- iteration 6: account stomps that unlock a class for free
-- (Config/Evolutions.FREE_UNLOCKS), or nil.
function ClassInfo.freeUnlockStomps(classId: string): number?
	local evo = Defs.module("Evolutions")
	local list = if type(evo) == "table" then evo.FREE_UNLOCKS else nil
	if type(list) ~= "table" then
		return nil
	end
	for _, u in list do
		if type(u) == "table" and u.classId == classId then
			return tonumber(u.stomps)
		end
	end
	return nil
end

export type SlotView = {
	slot: number,
	unlocked: boolean,
	lockText: string?, -- "Level 10" / "Level 20" while locked
	id: string?, -- equipped ability id (nil = base / empty)
	name: string,
}

-- iteration 5 (A3): the 3 ability slots of a class for the loadout row. The
-- profile view's `abilities` / `abilitySlots` win; an older profile (single
-- `ability`) is resolved with Shared.Data.ClassProgress.loadout when it has
-- one, else shows slot 1 only filled.
function ClassInfo.loadout(classId: string): { SlotView }
	local st = State.classState(classId)
	local n = math.clamp(
		tonumber(st.abilitySlots) or AbilitySlots.count(st.level, st.prestige),
		1,
		AbilitySlots.MAX
	)
	local picks: { [number]: string? } = if type(st.abilities) == "table" then st.abilities else {}
	if picks[2] == nil and n >= 2 then
		local filled = call(ClassInfo.progressModule(), "loadout", classId, {
			level = st.level,
			prestige = st.prestige,
			ability = st.ability,
			abilities = if type(st.abilities) == "table" then st.abilities else nil,
		})
		if type(filled) == "table" then
			local copy: { [number]: string? } = {}
			for i = 1, AbilitySlots.MAX do
				copy[i] = if type(filled[i]) == "string" then filled[i] else picks[i]
			end
			picks = copy
		end
	end
	local base = ClassInfo.abilities(classId, st.level, nil)[1]
	local out: { SlotView } = {}
	for i = 1, AbilitySlots.MAX do
		local open = i <= n
		local id = if open then picks[i] else nil
		if open and i == 1 and id == nil and base then
			id = base.id
		end
		table.insert(out, {
			slot = i,
			unlocked = open,
			lockText = if open then nil else AbilitySlots.lockText(i),
			id = id,
			name = if open
				then (if id ~= nil or i == 1 then ClassInfo.abilityName(classId, id) else "Empty")
				else "Locked",
		})
	end
	return out
end

-- iteration 5 (A3): equip `abilityId` in `slot` (SelectAbility(classId, abilityId, slot)).
-- The server swaps when the ability is already in another slot.
function ClassInfo.equip(classId: string, abilityId: string, slot: number)
	local base = ClassInfo.abilities(classId, 1, nil)[1]
	local Remotes = require(Client.Util.Remotes)
	Remotes.fire(
		Remotes.C2S.SelectAbility,
		table.unpack(AbilitySlots.selectArgs(classId, abilityId, slot, if base then base.id else nil))
	)
end

-- Default look + class skins (unlock at levels 3, 10, 20, 30).
function ClassInfo.skins(classId: string, level: number, selected: string?): { Choice }
	local classDef = Defs.get("Classes", classId)
	local list = flatten(perClass(Defs.module("ClassSkins"), classId))
	local unlocked = State.classState(classId).unlockedSkins or unlockedSet("unlockedSkins", classId, level)
	local out: { Choice } = {
		{
			id = "default",
			name = "Classic",
			description = "The standard herd look.",
			unlockLevel = 1,
			unlocked = true,
			selected = false,
			placeholder = false,
			color = if classDef and type(classDef.color) == "table" then classDef.color else nil,
		},
	}
	local profile = State.get("profile")
	local owned = if type(profile) == "table" and type(profile.ownedSkins) == "table"
		then profile.ownedSkins
		else {}
	for i, d in list do
		local id = tostring(d.id)
		local paid = d.source == "paid"
		-- Paid skins (cosmetic, R3) only show once owned; level skins always show.
		if id ~= "default" and (not paid or owned[id] == true) then
			local lv = tonumber(d.unlockLevel or d.level)
				or (if paid then 1 else ClassMath.SKIN_LEVELS[i] or 30)
			local open = if paid then true elseif unlocked then unlocked[id] == true else level >= lv
			local col = d.color
				or d.primary
				or (type(d.colors) == "table" and (d.colors.body or d.colors[1]))
				or nil
			table.insert(out, {
				id = id,
				name = tostring(d.name or Defs.name(nil, id)),
				description = tostring(d.description or ""),
				unlockLevel = lv,
				unlocked = open,
				selected = false,
				placeholder = false,
				color = if type(col) == "table" then col else nil,
			})
		end
	end
	if #out == 1 then
		for i, lv in ClassMath.SKIN_LEVELS do
			table.insert(out, {
				id = "locked" .. i,
				name = "Skin " .. i,
				description = "Coming soon: class skins are on their way.",
				unlockLevel = lv,
				unlocked = false,
				selected = false,
				placeholder = true,
			})
		end
	end
	local found = false
	for _, c in out do
		if c.id == selected and c.unlocked then
			c.selected = true
			found = true
		end
	end
	if not found then
		out[1].selected = true
	end
	return out
end

-- Normalised perk tree for a class (placeholder when Config/ClassPerks is missing).
function ClassInfo.tree(classId: string): PerkTree.Tree
	return PerkTree.normalise(PerkTree.extract(Defs.module("ClassPerks"), classId))
end

-- Respec cost in cheese, or nil if unknown.
function ClassInfo.respecCost(level: number): number?
	local c = tonumber(call(ClassInfo.progressModule(), "respecCost", level))
	if c then
		return math.max(0, math.floor(c))
	end
	local mod = Defs.module("ClassPerks")
	if type(mod) == "table" then
		local f = call(mod, "respecCost", level)
		if tonumber(f) then
			return math.floor(tonumber(f) :: number)
		end
		local base = tonumber(mod.RESPEC_BASE or mod.respecBase)
		local per = tonumber(mod.RESPEC_PER_LEVEL or mod.respecPerLevel)
		if base then
			return math.floor(base + (per or 0) * level)
		end
	end
	return nil
end

-- Can the server be expected to accept SelectPerk? (ClassProgress.canTake if present.)
function ClassInfo.canTake(classId: string, perkId: string): boolean?
	local cp = ClassInfo.progressModule()
	if type(cp) ~= "table" or type(cp.canTake) ~= "function" then
		return nil
	end
	local st = State.classState(classId)
	local ok, res = pcall(cp.canTake, classId, st, perkId)
	return if ok then res == true else nil
end

function ClassInfo.masteryColor(mastery: string): Color3?
	if mastery == "bronze" then
		return Color3.fromRGB(205, 127, 50)
	elseif mastery == "silver" then
		return Color3.fromRGB(200, 208, 220)
	elseif mastery == "gold" then
		return Color3.fromRGB(255, 204, 51)
	end
	return nil
end

return ClassInfo
