--!strict
-- (v6) Achievements and the Mousepedia collection book (Team P). Pure.
--
--   profile.achievements = {[id] = true}            done (and rewarded) markers:
--                                                   Config/Achievements ids, plus
--                                                   "page_<pageId>" and "collect_<pct>"
--   profile.collection   = {[pageId] = {[entryId] = true}}
--
-- collect() fills an entry (+5 Golden Cheese and +50 Pass XP the first time) and
-- rewards a finished page and the overall milestones. check() evaluates every
-- achievement against the profile and rewards the newly met ones. Both are
-- idempotent: a marker is set in the same mutation as its reward.

local Types = require("../Types")
local Config = require("../Config/Achievements")
local Collection = require("../Config/Collection")
local Pass = require("../Config/Pass")
local Classes = require("../Config/Classes")
local Grant = require("./Grant")

type Profile = Types.Profile
type AddXp = ((Profile, number) -> ())?

local Achievements = {}

local function set(profile: Profile, field: string): { [string]: any }
	local p = profile :: any
	if type(p[field]) ~= "table" then
		p[field] = {}
	end
	return p[field]
end

-- Repairs saved collection data: real pages and entries only.
function Achievements.sanitizeCollection(raw: any): { [string]: { [string]: boolean } }
	local out: { [string]: { [string]: boolean } } = {}
	if type(raw) ~= "table" then
		return out
	end
	for pageId, entries in raw do
		if Collection.get(pageId) and type(entries) == "table" then
			local page: { [string]: boolean } = {}
			for id, x in entries do
				-- Keep entries of ids a config rename removed? No: only real entries count.
				if x == true and Collection.isEntry(pageId, id) then
					page[id] = true
				end
			end
			out[pageId] = page
		end
	end
	return out
end

-- Repairs the done markers: short string keys only (unknown ids are kept, so a
-- removed achievement can never be rewarded twice if it comes back).
function Achievements.sanitizeDone(raw: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(raw) ~= "table" then
		return out
	end
	local n = 0
	for k, x in raw do
		if type(k) == "string" and #k > 0 and #k <= 64 and x == true then
			n += 1
			if n > 500 then
				break
			end
			out[k] = true
		end
	end
	return out
end

local function pageCount(profile: Profile, pageId: string): number
	local col = (profile :: any).collection
	local page = if type(col) == "table" then col[pageId] else nil
	local n = 0
	if type(page) == "table" then
		for id, x in page do
			if x == true and Collection.isEntry(pageId, id) then
				n += 1
			end
		end
	end
	return n
end

function Achievements.pageComplete(profile: Profile, pageId: string): boolean
	local def = Collection.get(pageId)
	return def ~= nil and #def.entries > 0 and pageCount(profile, pageId) >= #def.entries
end

-- Overall completion, 0..100 (floored).
function Achievements.completionPct(profile: Profile): number
	local total = Collection.totalEntries()
	if total <= 0 then
		return 0
	end
	local have = 0
	for _, page in Collection.PAGES do
		have += pageCount(profile, page.id)
	end
	return math.floor(have * 100 / total)
end

-- Page and milestone rewards not given yet.
local function collectionRewards(profile: Profile, addPassXp: AddXp, out: { [string]: any })
	local done = set(profile, "achievements")
	for _, page in Collection.PAGES do
		local key = "page_" .. page.id
		if not done[key] and Achievements.pageComplete(profile, page.id) then
			done[key] = true
			Grant.apply(profile, page.reward, addPassXp, out)
			out.pages = out.pages or {}
			table.insert(out.pages, page.id)
		end
	end
	local pct = Achievements.completionPct(profile)
	for _, m in Collection.MILESTONES do
		local key = "collect_" .. tostring(m.pct)
		if pct >= m.pct and not done[key] then
			done[key] = true
			Grant.apply(profile, m.reward, addPassXp, out)
		end
	end
end

-- Fills a Mousepedia entry. Returns (isNew, given). Unknown pages / entries: (false, nil).
function Achievements.collect(profile: Profile, pageId: any, entryId: any, addPassXp: AddXp): (boolean, any)
	if not Collection.isEntry(pageId, entryId) then
		return false, nil
	end
	local col = set(profile, "collection")
	local page = col[pageId]
	if type(page) ~= "table" then
		page = {}
		col[pageId] = page
	end
	if page[entryId] then
		return false, nil
	end
	page[entryId] = true
	local out: { [string]: any } = {}
	Grant.apply(
		profile,
		{ goldenCheese = Collection.ENTRY_GOLDEN, passXp = Pass.COLLECTION_XP },
		addPassXp,
		out
	)
	collectionRewards(profile, addPassXp, out)
	return true, out
end

-- Class entries: every class at class level >= CLASS_ENTRY_LEVEL.
function Achievements.collectClasses(profile: Profile, addPassXp: AddXp): { [string]: any }?
	local classes = (profile :: any).classes
	local out: { [string]: any } = {}
	local any = false
	if type(classes) == "table" then
		for _, id in Classes.ORDER do
			local st = classes[id]
			if
				type(st) == "table"
				and type(st.level) == "number"
				and st.level >= Collection.CLASS_ENTRY_LEVEL
			then
				local isNew, given = Achievements.collect(profile, "classes", id, addPassXp)
				if isNew then
					any = true
					for k, v in given do
						if type(v) == "number" then
							out[k] = (out[k] or 0) + v
						elseif type(v) == "table" then
							out[k] = out[k] or {}
							for _, x in v do
								table.insert(out[k], x)
							end
						end
					end
				end
			end
		end
	end
	return if any then out else nil
end

local function stars(profile: Profile): number
	-- Prestige lives in the class blocks (classes[id].prestige, Data/ClassProgress).
	local classes = (profile :: any).classes
	local n = 0
	if type(classes) == "table" then
		for _, st in classes do
			-- (iteration 2) Mastery Stars became Prestige: count prestige (or old stars)
			local v = if type(st) == "table" then (st.prestige or st.stars) else nil
			if type(v) == "number" and v == v then
				n += math.max(0, math.floor(v))
			end
		end
	end
	return n
end

local function classLevels(profile: Profile): (number, number, number)
	-- (best level, lowest level over ALL classes (0 if one is missing), classes unlocked)
	local classes = (profile :: any).classes
	local best, lowest = 0, math.huge
	for _, id in Classes.ORDER do
		local st = if type(classes) == "table" then classes[id] else nil
		local lvl = if type(st) == "table" and type(st.level) == "number" then st.level else 0
		best = math.max(best, lvl)
		lowest = math.min(lowest, lvl)
	end
	local owned = 0
	for _, x in profile.unlockedClasses do
		if x == true then
			owned += 1
		end
	end
	return best, if lowest == math.huge then 0 else lowest, owned
end

-- Is one achievement's requirement met?
function Achievements.met(profile: Profile, def: Config.AchievementDef): boolean
	local r = def.req
	local n = r.n or 0
	if r.kind == "stat" then
		local v = (profile.stats :: any)[r.field or ""]
		return type(v) == "number" and v >= n
	elseif r.kind == "classes" then
		local _, _, owned = classLevels(profile)
		return owned >= n
	elseif r.kind == "classLevel" then
		local best = classLevels(profile)
		return best >= n
	elseif r.kind == "allClasses" then
		local _, lowest = classLevels(profile)
		return lowest >= n
	elseif r.kind == "stars" then
		return stars(profile) >= n
	elseif r.kind == "pressure" then
		local pp = (profile :: any).pressure
		return type(pp) == "table" and type(pp.highestCleared) == "number" and pp.highestCleared >= n
	elseif r.kind == "streak" then
		return profile.daily.streak >= n
	elseif r.kind == "page" then
		return Achievements.pageComplete(profile, r.page or "")
	elseif r.kind == "discoveries" then
		local disc = (profile :: any).discoveries
		if type(disc) ~= "table" then
			return false
		end
		for _, id in r.ids or {} do
			if not disc[id] then
				return false
			end
		end
		return true
	elseif r.kind == "level" then
		return profile.level >= n
	end
	return false
end

-- Rewards every newly met achievement. Returns a list of {id, given}.
function Achievements.check(profile: Profile, addPassXp: AddXp): { { id: string, given: { [string]: any } } }
	local done = set(profile, "achievements")
	local out = {}
	for _, def in Config.LIST do
		if not done[def.id] and Achievements.met(profile, def) then
			done[def.id] = true
			local given = Grant.apply(profile, def.reward, addPassXp)
			table.insert(out, { id = def.id, given = given })
		end
	end
	return out
end

-- Mousepedia + achievements for the client (added to Net.S2C.Profile as `book`).
function Achievements.view(profile: Profile): { [string]: any }
	local done = set(profile, "achievements")
	local pages = {}
	for _, page in Collection.PAGES do
		local col = (profile :: any).collection
		local have = if type(col) == "table" and type(col[page.id]) == "table" then col[page.id] else {}
		local entries = {}
		for _, id in page.entries do
			table.insert(entries, { id = id, found = have[id] == true })
		end
		table.insert(pages, {
			id = page.id,
			name = page.name,
			found = pageCount(profile, page.id),
			total = #page.entries,
			complete = done["page_" .. page.id] == true,
			entries = entries,
			reward = table.clone(page.reward),
		})
	end
	local list = {}
	for _, def in Config.LIST do
		table.insert(list, {
			id = def.id,
			name = def.name,
			text = def.text,
			done = done[def.id] == true,
			reward = table.clone(def.reward),
		})
	end
	return { pages = pages, completion = Achievements.completionPct(profile), achievements = list }
end

return Achievements
