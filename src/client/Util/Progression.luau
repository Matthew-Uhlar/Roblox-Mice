--!strict
-- Pure, nil-safe readers for the v4 progression views (docs/V4-PLAN.md,
-- docs/qa/V4-C-progression.md §5). No Roblox APIs: specs run them in Lune
-- (tests/specs/ClientV4.spec.luau).
--
-- Every reader accepts the server shape it was written for AND a few likely
-- variants, because Team P builds the views in parallel. Anything unknown
-- becomes a safe default, never an error.
--
--   Progression.quests(view)        Net.S2C.Quests  -> { daily, weekly, rerollsLeft, ... }
--   Progression.pass(view)          Net.S2C.Pass    -> { tier, xp, premium, tiers, ... }
--   Progression.reward(r)           any reward      -> { kind, amount, id?, text }
--   Progression.accountRewards(profile, defs)       -> {{level, reward, claimed, claimable}}
--   Progression.boosts(profile, now)                -> {{key, text, seconds?}} (live timers)
--   Progression.dots(profile, quests, pass, defs)   -> {shop, contracts, pass, levels, daily, any}
--   Progression.isRookie(profile)                   runs 0-2 (DoN / Pressure hidden)

local Progression = {}

Progression.ROOKIE_RUNS = 3 -- Double or Nothing and Pressure show from run 3 (V4-PLAN "Rookie Run")
Progression.PASS_TIERS = 30
Progression.PASS_XP_PER_TIER = 1000

local function num(v: any, default: number): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return default
	end
	return n
end

local function str(v: any): string?
	if v == nil then
		return nil
	end
	local s = tostring(v)
	return if s == "" then nil else s
end

-- A set from {[id] = true}, {id, id}, or {[id] = {claimed = true}}.
local function idSet(v: any, field: string?): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(v) ~= "table" then
		return out
	end
	for k, x in v do
		if type(x) == "string" or type(x) == "number" then
			out[tostring(x)] = true
		elseif x == true or (type(x) == "table" and field ~= nil and x[field] == true) then
			out[tostring(k)] = true
		end
	end
	return out
end
Progression.idSet = idSet

----------------------------------------------------------------------
-- Rookie / first-run simplification
----------------------------------------------------------------------

function Progression.runs(profile: any): number?
	if type(profile) ~= "table" then
		return nil
	end
	local st = if type(profile.stats) == "table" then profile.stats else {}
	return math.max(0, math.floor(num(st.runs, 0)))
end

-- Runs 0-2: Double or Nothing, Pressure and other advanced UI stay hidden.
-- An unknown profile counts as a rookie (show less, not more).
function Progression.isRookie(profile: any): boolean
	local r = Progression.runs(profile)
	if r == nil then
		return true
	end
	local rk = profile.rookie
	if type(rk) == "boolean" then
		return rk
	elseif type(rk) == "table" and type(rk.isRookie) == "boolean" then
		return rk.isRookie -- Team P profile view: rookie = {runs, isRookie, firstExtractPaid}
	end
	return r < Progression.ROOKIE_RUNS
end

----------------------------------------------------------------------
-- Rewards
----------------------------------------------------------------------

export type Reward = { kind: string, amount: number, id: string?, text: string, icon: string }

local ICONS: { [string]: string } = {
	cheese = "🧀",
	golden = "✨",
	passXp = "⭐",
	cosmetic = "🎩",
	title = "🏷",
	skin = "🐘",
	token = "🎟",
	gem = "💎",
	dust = "✨",
	none = "·",
}

-- Optional display-name lookup for cosmetic / title ids (UIs set it to a
-- Config lookup; pure specs leave it nil and get the id).
local namer: ((kind: string, id: string) -> string?)? = nil
function Progression.setNamer(fn: ((kind: string, id: string) -> string?)?)
	namer = fn
end

local function nameOf(kind: string, id: string): string
	local n = namer
	if n then
		local ok, res = pcall(n, kind, id)
		if ok and type(res) == "string" and res ~= "" then
			return res
		end
	end
	return id
end

-- Accepts {kind, amount, id, name}, {cheese = n, golden = n, passXp = n, cosmetic = id},
-- a number (cheese) or a string (cosmetic id). Returns the first meaningful
-- reward plus a one-line text for the whole thing.
function Progression.reward(r: any): Reward
	if type(r) == "number" then
		return { kind = "cheese", amount = r, text = "🧀 " .. tostring(math.floor(r)), icon = ICONS.cheese }
	elseif type(r) == "string" then
		return { kind = "cosmetic", amount = 1, id = r, text = "🎩 " .. r, icon = ICONS.cosmetic }
	elseif type(r) ~= "table" then
		return { kind = "none", amount = 0, text = "", icon = ICONS.none }
	end
	local parts: { string } = {}
	local first: Reward? = nil
	local function add(kind: string, amount: number, id: string?, label: string)
		local icon = ICONS[kind] or "🎁"
		table.insert(parts, icon .. " " .. label)
		if not first then
			first = { kind = kind, amount = amount, id = id, text = "", icon = icon }
		end
	end
	local name = str(r.name or r.label) -- (r.title is an id; nameOf() resolves it below)
	local kind = str(r.kind or r.type)
	if kind then
		local amount = num(r.amount or r.value or r.n, 1)
		local id = str(r.id or r.cosmetic or r.skin)
		if kind == "gold" or kind == "goldenCheese" or kind == "gc" then
			kind = "golden"
		elseif kind == "xp" or kind == "pass_xp" then
			kind = "passXp"
		end
		local label = if kind == "cheese"
				or kind == "golden"
				or kind == "passXp"
			then tostring(math.floor(amount)) .. (if kind == "passXp" then " XP" else "")
			else name or id or kind
		add(kind, amount, id, label)
	else
		local cheese = num(r.cheese, 0)
		local golden = num(r.golden or r.goldenCheese or r.gc, 0)
		local xp = num(r.passXp or r.xp, 0)
		if xp > 0 then
			add("passXp", xp, nil, tostring(math.floor(xp)) .. " XP")
		end
		if cheese > 0 then
			add("cheese", cheese, nil, tostring(math.floor(cheese)))
		end
		if golden > 0 then
			add("golden", golden, nil, tostring(math.floor(golden)))
		end
		-- iteration 2: Cheese Gems (tier) and Crumb Dust
		local gem = num(r.gem or r.gemTier, 0)
		if gem > 0 then
			add(
				"gem",
				1,
				nil,
				string.format("tier-%d gem", math.floor(gem)) .. (if r.unique then " (unique)" else "")
			)
		end
		local dust = num(r.dust or r.crumbDust, 0)
		if dust > 0 then
			add("dust", dust, nil, tostring(math.floor(dust)) .. " dust")
		end
		local tokens = num(r.rerollTokens, 0)
		if tokens > 0 then
			add("token", tokens, nil, tostring(math.floor(tokens)) .. " reroll tokens")
		end
		local sw = num(r.secondWindTokens, 0)
		if sw > 0 then
			add("token", sw, nil, tostring(math.floor(sw)) .. " Second Wind")
		end
		local cos = str(r.cosmetic or r.skin or r.title)
		if cos then
			local k = if r.cosmetic then "cosmetic" elseif r.skin then "skin" else "title"
			add(k, 1, cos, name or nameOf(k, cos))
		end
	end
	local out: Reward = first or { kind = "none", amount = 0, text = "", icon = ICONS.none }
	out.text = table.concat(parts, "  ")
	return out
end

----------------------------------------------------------------------
-- Herd Contracts (Net.S2C.Quests)
----------------------------------------------------------------------

export type Quest = {
	id: string,
	text: string,
	progress: number,
	goal: number,
	done: boolean,
	claimed: boolean,
	claimable: boolean,
	period: string, -- "daily" | "weekly"
	tier: string?,
	reward: Reward,
	canReroll: boolean,
}

local function quest(q: any, period: string, key: any): Quest?
	if type(q) ~= "table" then
		return nil
	end
	local id = str(q.id or q.questId or q.key) or (if type(key) == "string" then key else nil)
	if not id then
		return nil
	end
	local goal = math.max(1, num(q.goal or q.target or q.need or q.count, 1))
	local progress = math.clamp(num(q.progress or q.have or q.value, 0), 0, goal)
	local claimed = q.claimed == true
	local done = q.done == true or q.complete == true or q.completed == true or progress >= goal
	local rewardSrc = q.reward
	if rewardSrc == nil then
		rewardSrc = { passXp = q.passXp or q.xp, cheese = q.cheese, golden = q.golden }
	end
	return {
		id = id,
		text = str(q.text or q.desc or q.description or q.name or q.title) or id,
		progress = progress,
		goal = goal,
		done = done,
		claimed = claimed,
		claimable = done and not claimed,
		period = str(q.period or q.kind) or period,
		tier = str(q.tier or q.difficulty),
		reward = Progression.reward(rewardSrc),
		canReroll = not claimed and not done and q.canReroll ~= false,
	}
end

local function questList(src: any, period: string): { Quest }
	local out: { Quest } = {}
	if type(src) ~= "table" then
		return out
	end
	for k, q in src do
		local e = quest(q, period, k)
		if e then
			table.insert(out, e)
		end
	end
	table.sort(out, function(a, b)
		-- claimable first, then open, then claimed; stable by id
		local ra = if a.claimable then 0 elseif a.claimed then 2 else 1
		local rb = if b.claimable then 0 elseif b.claimed then 2 else 1
		if ra ~= rb then
			return ra < rb
		end
		return a.id < b.id
	end)
	return out
end

export type QuestsView = {
	known: boolean,
	daily: { Quest },
	weekly: { Quest },
	rerollsLeft: number,
	rerollCost: number?, -- nil: no reroll left today; 0: free; n: cheese
	dailyResetsIn: number?,
	claimable: number,
	dailyResetAt: number?,
	weeklyResetAt: number?,
	bonus: Reward?,
}

function Progression.quests(view: any): QuestsView
	local out: QuestsView = {
		known = type(view) == "table",
		daily = {},
		weekly = {},
		rerollsLeft = 0,
		rerollCost = nil,
		dailyResetsIn = nil,
		claimable = 0,
		dailyResetAt = nil,
		weeklyResetAt = nil,
		bonus = nil,
	}
	if type(view) ~= "table" then
		return out
	end
	if view.daily ~= nil or view.weekly ~= nil or view.dailies ~= nil or view.weeklies ~= nil then
		out.daily = questList(view.daily or view.dailies, "daily")
		out.weekly = questList(view.weekly or view.weeklies, "weekly")
	elseif type(view.quests) == "table" or type(view.list) == "table" then
		for _, q in questList(view.quests or view.list, "daily") do
			table.insert(if q.period == "weekly" then out.weekly else out.daily, q)
		end
	end
	-- Team P view: rerollCost (0 = free, n = cheese, nil = none left today) and
	-- freeRerollLeft. Older shapes: rerollsLeft / rerolls.
	local cost = tonumber(view.rerollCost)
	out.rerollCost = cost
	if view.rerollsLeft ~= nil or view.rerolls ~= nil or view.freeRerolls ~= nil then
		out.rerollsLeft =
			math.max(0, math.floor(num(view.rerollsLeft or view.rerolls or view.freeRerolls, 0)))
	elseif cost ~= nil then
		out.rerollsLeft = if cost == 0 or view.freeRerollLeft == true then 1 else 0
	end
	local canReroll = out.rerollsLeft > 0 or cost ~= nil
	out.dailyResetAt = tonumber(view.dailyResetAt or view.dayEndsAt or view.dailyEndsAt)
	out.dailyResetsIn = tonumber(view.dailyResetsIn)
	out.weeklyResetAt = tonumber(view.weeklyResetAt or view.weekEndsAt or view.weeklyEndsAt)
	if view.bonus ~= nil then
		out.bonus = Progression.reward(view.bonus)
	end
	for _, list in { out.daily, out.weekly } do
		for _, q in list do
			if q.claimable then
				out.claimable += 1
			end
			if not canReroll or q.period == "weekly" then
				q.canReroll = false -- weeklies never reroll (Data/Quests.reroll)
			end
		end
	end
	return out
end

----------------------------------------------------------------------
-- Herd Pass (Net.S2C.Pass)
----------------------------------------------------------------------

export type PassTier = {
	tier: number,
	free: Reward?,
	premium: Reward?,
	unlocked: boolean,
	freeClaimed: boolean,
	premiumClaimed: boolean,
	freeClaimable: boolean,
	premiumClaimable: boolean,
}

export type PassView = {
	known: boolean,
	season: string?,
	seasonName: string?,
	tier: number, -- tiers reached (0..30)
	xp: number, -- XP into the next tier
	xpPerTier: number,
	premium: boolean,
	tiers: { PassTier },
	claimable: number,
	endsAt: number?,
	premiumKey: string?, -- Monetization key to buy premium
}

local function claimedMap(src: any): { [number]: boolean }
	local out: { [number]: boolean } = {}
	if type(src) ~= "table" then
		return out
	end
	for k, v in src do
		if v == true then
			local n = tonumber(k)
			if n then
				out[n] = true
			end
		elseif tonumber(v) then
			out[tonumber(v) :: number] = true
		end
	end
	return out
end

function Progression.pass(view: any, cfg: any): PassView
	local out: PassView = {
		known = type(view) == "table",
		season = nil,
		seasonName = nil,
		tier = 0,
		xp = 0,
		xpPerTier = Progression.PASS_XP_PER_TIER,
		premium = false,
		tiers = {},
		claimable = 0,
		endsAt = nil,
		premiumKey = nil,
	}
	local v = if type(view) == "table" then view else {}
	local c = if type(cfg) == "table" then cfg else {}
	out.season = str(v.season or v.seasonId or c.SEASON or c.season)
	out.seasonName = str(v.seasonName or v.name or c.SEASON_NAME or c.seasonName)
	out.xpPerTier =
		math.max(1, num(v.xpPerTier or c.XP_PER_TIER or c.xpPerTier, Progression.PASS_XP_PER_TIER))
	local maxTiers =
		math.max(1, math.floor(num(v.maxTier or v.tierCount or c.TIERS or c.tiers, Progression.PASS_TIERS)))
	local totalXp = tonumber(v.totalXp)
	if totalXp then
		out.tier = math.floor(totalXp / out.xpPerTier)
		out.xp = totalXp - out.tier * out.xpPerTier
	else
		out.tier = math.floor(num(v.tier or v.level, 0))
		-- Team P: `xp` is the season total, `tierXp` the progress inside the tier
		out.xp = if v.tierXp ~= nil then num(v.tierXp, 0) else num(v.xp, 0)
	end
	out.tier = math.clamp(out.tier, 0, maxTiers)
	if out.tier >= maxTiers then
		out.xp = out.xpPerTier
	end
	out.premium = v.premium == true or v.hasPremium == true or v.owned == true
	out.endsAt = tonumber(v.endsAt or v.seasonEndsAt)
	out.premiumKey = str(v.premiumKey or c.PREMIUM_KEY or c.premiumKey)
	local claimed = if type(v.claimed) == "table" then v.claimed else {}
	local freeClaimed = claimedMap(claimed.free or v.freeClaimed)
	local premClaimed = claimedMap(claimed.premium or v.premiumClaimed)
	-- reward rows: view.tiers / view.rewards, else the config's list
	local rows = v.tiers or v.rewards or c.TRACK or c.REWARDS or c.tiers
	local byTier: { [number]: any } = {}
	if type(rows) == "table" then
		for k, row in rows do
			if type(row) == "table" then
				local t = tonumber(row.tier or row.level) or tonumber(k)
				if t then
					byTier[math.floor(t)] = row
				end
			end
		end
	end
	for t = 1, maxTiers do
		local row = byTier[t] or {}
		local free = if row.free ~= nil then Progression.reward(row.free) else nil
		local prem = if row.premium ~= nil then Progression.reward(row.premium) else nil
		local unlocked = if row.reached ~= nil then row.reached == true else t <= out.tier
		local fc = freeClaimed[t] == true or row.freeClaimed == true
		local pc = premClaimed[t] == true or row.premiumClaimed == true
		local e: PassTier = {
			tier = t,
			free = if free and free.kind ~= "none" then free else nil,
			premium = if prem and prem.kind ~= "none" then prem else nil,
			unlocked = unlocked,
			freeClaimed = fc,
			premiumClaimed = pc,
			freeClaimable = false,
			premiumClaimable = false,
		}
		e.freeClaimable = unlocked and e.free ~= nil and not fc
		e.premiumClaimable = unlocked and out.premium and e.premium ~= nil and not pc
		if e.freeClaimable then
			out.claimable += 1
		end
		if e.premiumClaimable then
			out.claimable += 1
		end
		table.insert(out.tiers, e)
	end
	return out
end

----------------------------------------------------------------------
-- Account level rewards (Config/AccountRewards + profile.accountRewards)
----------------------------------------------------------------------

export type AccountReward = { level: number, reward: Reward, claimed: boolean, claimable: boolean }

function Progression.accountRewards(profile: any, defs: any): { AccountReward }
	local p = if type(profile) == "table" then profile else {}
	local level = math.max(1, math.floor(num(p.level, 1)))
	local ar = p.accountRewards
	-- Team P profile view: accountRewards = {{level, reward, claimed, reached}}
	if type(ar) == "table" and type(ar[1]) == "table" and tonumber(ar[1].level) then
		local rows: { AccountReward } = {}
		for _, e in ar do
			if type(e) == "table" and tonumber(e.level) then
				local lv = math.floor(tonumber(e.level) :: number)
				local reached = if type(e.reached) == "boolean" then e.reached else lv <= level
				local isClaimed = e.claimed == true
				table.insert(rows, {
					level = lv,
					reward = Progression.reward(e.reward),
					claimed = isClaimed,
					claimable = reached and not isClaimed,
				})
			end
		end
		table.sort(rows, function(a, b)
			return a.level < b.level
		end)
		return rows
	end
	local claimed: { [number]: boolean } = {}
	if type(ar) == "table" then
		claimed = claimedMap(if type(ar.claimed) == "table" then ar.claimed else ar)
	end
	local list: { any } = {}
	local src = defs
	if type(defs) == "table" then
		src = defs.LIST or defs.REWARDS or defs.list or defs.rewards or defs
	end
	if type(src) == "table" then
		for k, d in src do
			if type(d) == "table" then
				local lv = tonumber(d.level) or tonumber(k)
				if lv then
					table.insert(list, { level = math.floor(lv), raw = d.reward or d })
				end
			end
		end
	end
	table.sort(list, function(a, b)
		return a.level < b.level
	end)
	local out: { AccountReward } = {}
	for _, e in list do
		local isClaimed = claimed[e.level] == true
		table.insert(out, {
			level = e.level,
			reward = Progression.reward(e.raw),
			claimed = isClaimed,
			claimable = e.level <= level and not isClaimed,
		})
	end
	return out
end

----------------------------------------------------------------------
-- Collection book (Mousepedia) and achievements
----------------------------------------------------------------------

export type BookEntry = { id: string, name: string, found: boolean, color: any? }
export type BookPage = { id: string, name: string, icon: string, entries: { BookEntry }, found: number }

-- Is `id` (on `pageId`) in the profile's collection? Accepts
-- {[page] = {[id] = true}}, {[id] = true}, {["page:id"] = true} and lists.
function Progression.found(collection: any, pageId: string, id: string): boolean
	if type(collection) ~= "table" then
		return false
	end
	local page = collection[pageId]
	if type(page) == "table" and (page[id] == true or table.find(page, id) ~= nil) then
		return true
	end
	if collection[id] == true or collection[pageId .. ":" .. id] == true then
		return true
	end
	return table.find(collection, id) ~= nil or table.find(collection, pageId .. ":" .. id) ~= nil
end

-- `pages` = {{id, name, icon?, entries = {{id, name?, color?}}}} (Config/Collection,
-- or the client's fallback built from the existing configs).
function Progression.book(pages: any, collection: any): ({ BookPage }, number, number)
	local out: { BookPage } = {}
	local total, found = 0, 0
	if type(pages) ~= "table" then
		return out, 0, 0
	end
	for _, pg in pages do
		if type(pg) == "table" and pg.id ~= nil and type(pg.entries) == "table" then
			local pid = tostring(pg.id)
			local page: BookPage = {
				id = pid,
				name = tostring(pg.name or pid),
				icon = tostring(pg.icon or "📖"),
				entries = {},
				found = 0,
			}
			for _, e in pg.entries do
				local eid = if type(e) == "table" then e.id else e
				if eid ~= nil then
					local sid = tostring(eid)
					-- Team P's profile.book pages carry `found` per entry
					local f = if type(e) == "table" and type(e.found) == "boolean"
						then e.found
						else Progression.found(collection, pid, sid)
					table.insert(page.entries, {
						id = sid,
						name = if type(e) == "table" then tostring(e.name or e.displayName or sid) else sid,
						found = f,
						color = if type(e) == "table" then e.color else nil,
					})
					total += 1
					if f then
						page.found += 1
						found += 1
					end
				end
			end
			table.insert(out, page)
		end
	end
	return out, found, total
end

export type Achievement = {
	id: string,
	name: string,
	text: string,
	progress: number,
	goal: number,
	done: boolean,
	claimed: boolean,
	reward: Reward,
}

-- Config/Achievements defs + profile.achievements ({[id] = true} or
-- {[id] = {progress, done, claimed}}). Done first, then by progress.
function Progression.achievements(defs: { any }?, state: any): { Achievement }
	local out: { Achievement } = {}
	local st = if type(state) == "table" then state else {}
	for _, d in defs or {} do
		if type(d) == "table" and d.id ~= nil then
			local id = tostring(d.id)
			local s = st[id]
			if s == nil and type(d.done) == "boolean" then
				s = d.done -- Team P's profile.book.achievements rows
			end
			local goal = math.max(1, num(d.goal or d.target or d.count, 1))
			local progress, done, claimed = 0, false, false
			if s == true then
				done, claimed, progress = true, true, goal
			elseif type(s) == "table" then
				progress = math.clamp(num(s.progress, 0), 0, goal)
				done = s.done == true or s.unlocked == true or progress >= goal
				claimed = s.claimed == true or (done and s.claimed == nil)
			elseif tonumber(s) then
				progress = math.clamp(tonumber(s) :: number, 0, goal)
				done = progress >= goal
				claimed = done
			end
			table.insert(out, {
				id = id,
				name = tostring(d.name or d.title or id),
				text = tostring(d.desc or d.description or d.text or ""),
				progress = if done then goal else progress,
				goal = goal,
				done = done,
				claimed = claimed,
				reward = Progression.reward(d.reward),
			})
		end
	end
	table.sort(out, function(a, b)
		if a.done ~= b.done then
			return a.done
		end
		local fa, fb = a.progress / a.goal, b.progress / b.goal
		if fa ~= fb then
			return fa > fb
		end
		return a.id < b.id
	end)
	return out
end

----------------------------------------------------------------------
-- Challenges (iteration 2: 30 one-time feats; Achievements show as Milestones)
----------------------------------------------------------------------

export type Challenge =
	{ id: string, name: string, text: string, done: boolean, reward: Reward, order: number }

-- profile.challenges = {list = {{id, name, text, done, reward}}, done?, total?}
-- or the list itself; Config/Challenges defs + a done set also work.
function Progression.challenges(view: any, defs: any): ({ Challenge }, number, number)
	local out: { Challenge } = {}
	local list = if type(view) == "table" and type(view.list) == "table" then view.list else view
	local doneSet: { [string]: boolean } = {}
	if type(view) == "table" and type(view.done) == "table" then
		doneSet = idSet(view.done, nil)
	end
	local src = list
	if (type(src) ~= "table" or #src == 0) and type(defs) == "table" then
		src = defs.LIST or defs
	end
	if type(src) ~= "table" then
		return out, 0, 0
	end
	local n = 0
	for i, c in src do
		if type(c) == "table" and c.id ~= nil then
			local id = tostring(c.id)
			local done = c.done == true or doneSet[id] == true
			table.insert(out, {
				id = id,
				name = tostring(c.name or c.title or id),
				text = tostring(c.text or c.desc or c.requirement or ""),
				done = done,
				reward = Progression.reward(c.reward),
				order = math.floor(num(c.order or c.n, if type(i) == "number" then i else 999)),
			})
			if done then
				n += 1
			end
		end
	end
	table.sort(out, function(a, b)
		if a.done ~= b.done then
			return not a.done -- open feats first
		end
		return a.order < b.order
	end)
	return out, n, #out
end

----------------------------------------------------------------------
-- Boost timers (profile view decorations, MonetizationService)
----------------------------------------------------------------------

-- "42 min", "1 h 05 min", "18 s"
function Progression.duration(seconds: number?): string
	local s = math.max(0, math.floor(num(seconds, 0)))
	if s >= 3600 then
		return string.format("%d h %02d min", s // 3600, (s % 3600) // 60)
	elseif s >= 60 then
		return string.format("%d min", math.ceil(s / 60))
	end
	return string.format("%d s", s)
end

export type Boost = { key: string, text: string, seconds: number? }

-- Live boosts from the profile view. `elapsed` is seconds since the view
-- arrived (so timers tick between pushes).
function Progression.boosts(profile: any, elapsed: number?): { Boost }
	local out: { Boost } = {}
	if type(profile) ~= "table" then
		return out
	end
	local e = math.max(0, num(elapsed, 0))
	local b = if type(profile.boosts) == "table" then profile.boosts else {}
	local rush = tonumber(b.rushSecondsLeft)
	if rush then
		rush -= e
		if rush > 0 then
			table.insert(out, {
				key = "rush",
				text = "Cheese Rush ×2: " .. Progression.duration(rush) .. " left",
				seconds = rush,
			})
		end
	end
	local feast = tonumber(profile.feastSecondsLeft)
	if feast then
		feast -= e
		if feast > 0 then
			table.insert(out, {
				key = "feast",
				text = "Server Feast +50%: " .. Progression.duration(feast),
				seconds = feast,
			})
		end
	end
	if profile.herdLeaderActive == true then
		table.insert(out, { key = "herd_leader", text = "Herd Leader in server: +15% cheese", seconds = nil })
	end
	return out
end

----------------------------------------------------------------------
-- Account level badge
----------------------------------------------------------------------

function Progression.level(profile: any): (number, number, number)
	local p = if type(profile) == "table" then profile else {}
	local lv = math.max(1, math.floor(num(p.level, 1)))
	local xp = math.max(0, num(p.xp, 0))
	local toNext = math.max(1, num(p.xpToNext, 200 + 50 * (lv - 1)))
	return lv, xp, toNext
end

----------------------------------------------------------------------
-- Daily reward
----------------------------------------------------------------------

function Progression.dailyClaimable(profile: any, today: number?): boolean
	if type(profile) ~= "table" or type(profile.daily) ~= "table" then
		return false
	end
	local d = profile.daily
	if type(d.claimable) == "boolean" then
		return d.claimable
	end
	local day = today or math.floor(os.time() / 86400)
	return tonumber(d.lastClaimDay) ~= day
end

----------------------------------------------------------------------
-- Dots: only for something new or claimable (never a sale or a timer)
----------------------------------------------------------------------

export type Dots = {
	daily: boolean,
	contracts: number,
	pass: number,
	levels: number,
	shop: boolean, -- the HUD shop button
	progress: boolean, -- the Herd button (contracts, pass, levels)
}

function Progression.dots(
	profile: any,
	questsView: any,
	passView: any,
	accountDefs: any,
	today: number?
): Dots
	local q = Progression.quests(questsView)
	local pv = Progression.pass(passView, nil)
	local levels = 0
	for _, r in Progression.accountRewards(profile, accountDefs) do
		if r.claimable then
			levels += 1
		end
	end
	local daily = Progression.dailyClaimable(profile, today)
	return {
		daily = daily,
		contracts = q.claimable,
		pass = pv.claimable,
		levels = levels,
		-- the shop holds the daily claim and the Herd Pass tab
		shop = daily or pv.claimable > 0,
		progress = q.claimable > 0 or pv.claimable > 0 or levels > 0,
	}
end

return Progression
