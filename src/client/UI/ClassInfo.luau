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
}

function ClassInfo.progress(classId: string): Progress
	local st = State.classState(classId)
	local cp = ClassInfo.progressModule()
	local toNext = tonumber(call(cp, "xpToNext", st.level)) or ClassMath.xpToNext(st.level)
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
	local free = tonumber(call(cp, "perkPointsFree", {
		xp = st.xp,
		level = st.level,
		perks = st.perks,
		perkPoints = st.perkPoints,
	}))
	if free == nil then
		free = PerkTree.freePoints(st.level, spent, st.perkPoints)
	end
	local maxed = st.level >= ClassMath.MAX_LEVEL
	return {
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
	local unlocked = unlockedSet("unlockedAbilities", classId, level)
	local out: { Choice } = {}
	local function push(d: any, i: number, placeholder: boolean)
		local lv = tonumber(d.unlockLevel or d.level) or ClassMath.ABILITY_LEVELS[i] or 1
		local id = tostring(d.id or (if i == 1 then "base" else "alt" .. (i - 1)))
		local open = if unlocked then (unlocked[id] == true or (i == 1 and lv <= 1)) else level >= lv
		table.insert(out, {
			id = id,
			name = tostring(d.name or (if i == 1 then "Base ability" else "Alternate " .. (i - 1))),
			description = tostring(d.description or d.desc or ""),
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
			push({ id = base.id or "base", name = base.name, description = base.description, unlockLevel = 1 }, 1, false)
		end
		for _, d in list do
			if #out >= 3 then
				break
			end
			push(d, #out + 1, false)
		end
	elseif base then
		push({ id = base.id or "base", name = base.name, description = base.description, unlockLevel = 1 }, 1, false)
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

-- Default look + class skins (unlock at levels 3, 10, 20, 30).
function ClassInfo.skins(classId: string, level: number, selected: string?): { Choice }
	local classDef = Defs.get("Classes", classId)
	local list = flatten(perClass(Defs.module("ClassSkins"), classId))
	local unlocked = unlockedSet("unlockedSkins", classId, level)
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
	for i, d in list do
		if tostring(d.id) ~= "default" then
			local lv = tonumber(d.unlockLevel or d.level) or ClassMath.SKIN_LEVELS[i] or 30
			local id = tostring(d.id)
			local open = if unlocked then unlocked[id] == true else level >= lv
			local col = d.color or d.primary or (type(d.colors) == "table" and d.colors[1]) or nil
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
