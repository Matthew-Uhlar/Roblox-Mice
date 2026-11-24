--!strict
-- Iteration 7 (team Systems), Liberty gap #4: the death recap card. Pure: turns
-- World:deathRecap(id) into the S2C DeathRecap payload with display names, and holds
-- the "needs revive" auto-ping rate limit (#5).
--
-- Payload (S2C DeathRecap, to the downed / eliminated human only):
--   { eliminated: boolean,          false = downed (can be revived), true = out
--     by: Source?,                  the hit that downed them
--     killer: Source?,              eliminated only: the hero that finished them (cat "hero")
--     top: { Source & {amount} },   <= 3 biggest damage sources over the last `window` s
--     window: number,               seconds summed (World.RECAP_WINDOW, 10)
--     t: number }                   server time (workspace:GetServerTimeNow())
--   Source = { cat: "hero"|"mouse"|"champion"|"boss"|"storm"|"hazard",
--              name: string,         display name ("Storm", "Rat Runner", a hero's name...)
--              kind: string?,        Enemies / Champions / Bosses def id, or the hazard
--              id: number?,          hero id (cat "hero")
--              isBot: boolean?,      cat "hero": a bot (label it)
--              squad: number? }      cat "hero": their squad

local Enemies = require("../Config/Enemies")
local Bosses = require("../Config/Bosses")
local Champions = require("../Config/Champions")

local DeathRecap = {}

DeathRecap.REVIVE_PING_GAP = 8 -- s between automatic "needs revive" pings per hero
DeathRecap.REVIVE_PING_KIND = "revive" -- PingShown kind of the automatic ping

local HAZARDS: { [string]: string } = {
	trap = "Trap",
	rock = "Falling rock",
	zone = "Hazard zone",
}

export type HeroInfo = { name: string, isBot: boolean?, squad: number? }

local function defName(get: (string) -> any?, kind: any, fallback: string): string
	if type(kind) == "string" then
		local ok, def = pcall(get, kind)
		if ok and type(def) == "table" and type(def.name) == "string" then
			return def.name
		end
	end
	return fallback
end

-- A display Source for one raw recap source {cat, kind?, id?}. heroInfo(id) gives a
-- hero's name / bot flag / squad (nil = unknown).
function DeathRecap.source(raw: any, heroInfo: ((number) -> HeroInfo?)?): { [string]: any }?
	if type(raw) ~= "table" or type(raw.cat) ~= "string" then
		return nil
	end
	local cat = raw.cat
	local out: { [string]: any } = { cat = cat, kind = if type(raw.kind) == "string" then raw.kind else nil }
	if cat == "hero" then
		out.id = if type(raw.id) == "number" then raw.id else nil
		local info = if heroInfo and out.id then heroInfo(out.id) else nil
		out.name = if info then info.name else "A rival hero"
		out.isBot = if info and info.isBot then true else nil
		out.squad = if info then info.squad else nil
	elseif cat == "boss" then
		out.name = defName(Bosses.get :: any, raw.kind, "A boss")
	elseif cat == "champion" then
		out.name = defName(Champions.get :: any, raw.kind, "A champion")
	elseif cat == "mouse" then
		out.name = defName(Enemies.get :: any, raw.kind, "Mice")
	elseif cat == "storm" then
		out.name = "The Melt (storm)"
	else
		out.name = HAZARDS[tostring(raw.kind)] or "Hazard"
	end
	return out
end

-- The S2C DeathRecap payload from World:deathRecap(id) (nil when there is none).
-- killerId: eliminated by this hero (heroKilled.by), if any.
function DeathRecap.view(
	recap: any,
	eliminated: boolean,
	killerId: number?,
	heroInfo: ((number) -> HeroInfo?)?,
	now: number?
): { [string]: any }?
	if type(recap) ~= "table" then
		return nil
	end
	local top = {}
	for _, s in (if type(recap.top) == "table" then recap.top else {}) :: { any } do
		local v = DeathRecap.source(s, heroInfo)
		if v and type(s.amount) == "number" and s.amount == s.amount then
			v.amount = math.max(0, math.floor(s.amount + 0.5))
			table.insert(top, v)
		end
		if #top >= 3 then
			break
		end
	end
	local by = DeathRecap.source(recap.by, heroInfo)
	if by == nil and type(recap.credit) == "number" then
		by = DeathRecap.source({ cat = "hero", id = recap.credit }, heroInfo)
	end
	local killer = if eliminated and type(killerId) == "number"
		then DeathRecap.source({ cat = "hero", id = killerId }, heroInfo)
		else nil
	return {
		eliminated = eliminated == true,
		by = by,
		killer = killer,
		top = top,
		window = if type(recap.window) == "number" then recap.window else 10,
		t = now or 0,
	}
end

-- Rate limit for the automatic "needs revive" ping: true (and records `now`) when hero
-- `id` may ping again. `log` is the caller's {[id] = last ping time}.
function DeathRecap.allowRevivePing(log: { [number]: number }, id: number, now: number): boolean
	local last = log[id]
	if last ~= nil and now - last < DeathRecap.REVIVE_PING_GAP then
		return false
	end
	log[id] = now
	return true
end

return DeathRecap
