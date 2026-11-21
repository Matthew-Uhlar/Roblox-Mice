--!strict
-- Data/LifetimeStats (iter 5 #8 time played + lifetime stats card, #6 the Overtime
-- record). Pure. ADDITIVE profile fields (no version bump: reconcile fills them):
--
--   profile.stats.seconds        number   account seconds played in runs
--   profile.stats.damage         number   lifetime damage dealt (the World's meter)
--   profile.stats.overtimeBest   {[tierKey]: wave}  best Overtime wave per ladder tier
--   profile.stats.clears         {[tierKey]: n}     full clears (final boss / Last Herd) per tier
--   profile.classes[id].seconds  number   seconds played with that class
--
-- tierKey = tostring(tier) ("1".."11"): string keys keep the maps DataStore-safe
-- (no sparse arrays). Custom runs (tier 0 / nil) record no tier entries.
-- The card (view) also reuses the existing totals: stats.stomps, runs, wins,
-- extractions, bossesKilled, championKills, bestStage.

local LifetimeStats = {}

LifetimeStats.MAX_SECONDS = 1e10
LifetimeStats.MAX_DAMAGE = 1e13
LifetimeStats.MAX_RUN_SECONDS = 6 * 3600 -- one run can't add more than this
LifetimeStats.MAX_RUN_DAMAGE = 1e9
LifetimeStats.MAX_TIER = 11
LifetimeStats.MAX_WAVE = 10000

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function clampNum(v: any, hi: number): number
	if not finite(v) then
		return 0
	end
	return math.clamp(math.floor(v), 0, hi)
end

-- A valid tier key ("1".."11") from a number or a string, else nil.
function LifetimeStats.tierKey(tier: any): string?
	local n = if type(tier) == "string" then tonumber(tier) else tier
	if not finite(n) or n % 1 ~= 0 or n < 1 or n > LifetimeStats.MAX_TIER then
		return nil
	end
	return tostring(math.floor(n))
end

local function tierMap(v: any, hi: number): { [string]: number }
	local out: { [string]: number } = {}
	if type(v) ~= "table" then
		return out
	end
	for k, x in v do
		local key = LifetimeStats.tierKey(k)
		local n = clampNum(x, hi)
		if key and n > 0 then
			out[key] = n
		end
	end
	return out
end

-- reconcile: fills the fields on the reconciled profile `p` from the raw save.
-- Call after p.stats and p.classes are built.
function LifetimeStats.sanitize(p: any, raw: any)
	local st = if type(raw) == "table" and type(raw.stats) == "table" then raw.stats else {}
	local sx = p.stats
	sx.seconds = clampNum(st.seconds, LifetimeStats.MAX_SECONDS)
	sx.damage = clampNum(st.damage, LifetimeStats.MAX_DAMAGE)
	sx.overtimeBest = tierMap(st.overtimeBest, LifetimeStats.MAX_WAVE)
	sx.clears = tierMap(st.clears, 1e9)
	local rawClasses = if type(raw) == "table" and type(raw.classes) == "table" then raw.classes else {}
	if type(p.classes) == "table" then
		for id, cs in p.classes do
			local rc = rawClasses[id]
			if type(cs) == "table" then
				local secs =
					clampNum(if type(rc) == "table" then rc.seconds else nil, LifetimeStats.MAX_SECONDS)
				cs.seconds = if secs > 0 then secs else nil
			end
		end
	end
end

export type RunInput = {
	seconds: number?, -- time played this run
	damage: number?, -- damage dealt this run
	classId: string?,
	tier: number?, -- the effective ladder tier (nil / 0 = Custom: no tier records)
	clear: boolean?, -- a full clear (final boss, or Last Herd)
	overtimeWaves: number?, -- Overtime waves survived
}

export type RunResult = {
	overtimeBest: number?, -- set when this run set a new best Overtime wave on its tier
}

-- After a run: adds time and damage, counts a clear and records the Overtime best.
function LifetimeStats.applyRun(profile: any, r: RunInput): RunResult
	local res: RunResult = {}
	local st = profile.stats
	if type(st) ~= "table" then
		return res
	end
	local secs = clampNum(r.seconds, LifetimeStats.MAX_RUN_SECONDS)
	st.seconds = math.min(clampNum(st.seconds, LifetimeStats.MAX_SECONDS) + secs, LifetimeStats.MAX_SECONDS)
	st.damage = math.min(
		clampNum(st.damage, LifetimeStats.MAX_DAMAGE) + clampNum(r.damage, LifetimeStats.MAX_RUN_DAMAGE),
		LifetimeStats.MAX_DAMAGE
	)
	local cid = r.classId
	local cs = if type(cid) == "string" and type(profile.classes) == "table"
		then profile.classes[cid]
		else nil
	if type(cs) == "table" and secs > 0 then
		cs.seconds =
			math.min(clampNum(cs.seconds, LifetimeStats.MAX_SECONDS) + secs, LifetimeStats.MAX_SECONDS)
	end
	local key = LifetimeStats.tierKey(r.tier)
	if key then
		if r.clear == true then
			st.clears = if type(st.clears) == "table" then st.clears else {}
			st.clears[key] = clampNum(st.clears[key], 1e9) + 1
		end
		local waves = clampNum(r.overtimeWaves, LifetimeStats.MAX_WAVE)
		if waves > 0 then
			st.overtimeBest = if type(st.overtimeBest) == "table" then st.overtimeBest else {}
			if waves > clampNum(st.overtimeBest[key], LifetimeStats.MAX_WAVE) then
				st.overtimeBest[key] = waves
				res.overtimeBest = waves
			end
		end
	end
	return res
end

-- The best Overtime wave on any tier (0 = none).
function LifetimeStats.bestOvertime(profile: any): number
	local best = 0
	local st = if type(profile) == "table" then profile.stats else nil
	for _, w in (if type(st) == "table" and type(st.overtimeBest) == "table" then st.overtimeBest else {}) do
		if finite(w) and w > best then
			best = w
		end
	end
	return best
end

-- The lifetime stats card (ProfileView.lifetime).
function LifetimeStats.view(profile: any): { [string]: any }
	local st = if type(profile) == "table" and type(profile.stats) == "table" then profile.stats else {}
	local classSeconds: { [string]: number } = {}
	if type(profile) == "table" and type(profile.classes) == "table" then
		for id, cs in profile.classes do
			if type(cs) == "table" and finite(cs.seconds) and cs.seconds > 0 then
				classSeconds[id] = cs.seconds
			end
		end
	end
	local function n(v: any): number
		return if finite(v) then v else 0
	end
	return {
		seconds = n(st.seconds),
		damage = n(st.damage),
		stomps = n(st.stomps),
		runs = n(st.runs),
		wins = n(st.wins),
		extractions = n(st.extractions),
		bossesKilled = n(st.bossesKilled),
		championKills = n(st.championKills),
		bestStage = n(st.bestStage),
		overtimeBest = table.clone(if type(st.overtimeBest) == "table" then st.overtimeBest else {}),
		overtimeBestAny = LifetimeStats.bestOvertime(profile),
		clears = table.clone(if type(st.clears) == "table" then st.clears else {}),
		classSeconds = classSeconds,
	}
end

return LifetimeStats
