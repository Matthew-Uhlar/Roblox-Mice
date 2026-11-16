--!strict
-- (v6) One way to give a fixed reward to a profile (Team P). Pure.
-- Used by Herd Contracts, the Herd Pass, achievements, the Mousepedia and account
-- level rewards. A reward is a table of optional fields:
--   cheese, goldenCheese, rerollTokens, passXp     added (currencies clamped)
--   cosmetic                                       Config/Cosmetics id (owned set)
--   title                                          Config/Cosmetics.EARNED_TITLES id (profile.titles)
-- A cosmetic or title the profile already owns is skipped (no duplicate, nothing
-- else in its place: these rewards are free). Pass XP goes through Data/HerdPass.

local Types = require("../Types")
local Cosmetics = require("../Config/Cosmetics")
local Award = require("./Award")

type Profile = Types.Profile

export type Reward = {
	cheese: number?,
	goldenCheese: number?,
	rerollTokens: number?,
	passXp: number?,
	cosmetic: string?,
	title: string?,
}

local Grant = {}

Grant.MAX_TOKENS = 100_000

local function n(v: any): number
	if type(v) ~= "number" or v ~= v or v <= 0 or v == math.huge then
		return 0
	end
	return math.floor(v)
end

local function set(profile: Profile, field: string): { [string]: boolean }
	local p = profile :: any
	if type(p[field]) ~= "table" then
		p[field] = {}
	end
	return p[field]
end

-- Adds `out[k] += v` for summaries.
local function add(out: { [string]: any }, k: string, v: number)
	if v > 0 then
		out[k] = (out[k] or 0) + v
	end
end

-- Applies a reward in place. `addPassXp(profile, xp)` (optional) applies Pass XP;
-- without it Pass XP is reported but not applied. Returns what was actually given.
function Grant.apply(
	profile: Profile,
	reward: Reward?,
	addPassXp: ((Profile, number) -> ())?,
	out: { [string]: any }?
): { [string]: any }
	local given: { [string]: any } = out or {}
	if type(reward) ~= "table" then
		return given
	end
	local cheese = n(reward.cheese)
	if cheese > 0 then
		profile.cheese = Award.clampCurrency(profile.cheese + cheese)
		add(given, "cheese", cheese)
	end
	local golden = n(reward.goldenCheese)
	if golden > 0 then
		profile.goldenCheese = Award.clampCurrency(profile.goldenCheese + golden)
		add(given, "goldenCheese", golden)
	end
	local rerolls = n(reward.rerollTokens)
	if rerolls > 0 then
		profile.rerollTokens = math.min(Grant.MAX_TOKENS, profile.rerollTokens + rerolls)
		add(given, "rerollTokens", rerolls)
	end
	local xp = n(reward.passXp)
	if xp > 0 then
		if addPassXp then
			addPassXp(profile, xp)
		end
		add(given, "passXp", xp)
	end
	local cos = reward.cosmetic
	if type(cos) == "string" and Cosmetics.get(cos) and not profile.cosmetics[cos] then
		profile.cosmetics[cos] = true
		given.cosmetics = given.cosmetics or {}
		table.insert(given.cosmetics, cos)
	end
	local title = reward.title
	if type(title) == "string" and Cosmetics.EARNED_TITLES[title] then
		local titles = set(profile, "titles")
		if not titles[title] then
			titles[title] = true
			given.titles = given.titles or {}
			table.insert(given.titles, title)
		end
	end
	return given
end

-- Short player-facing text ("+300 cheese, +10 Golden Cheese, Snow Cap").
function Grant.describe(given: { [string]: any }?): string
	if type(given) ~= "table" then
		return ""
	end
	local parts = {}
	if given.cheese then
		table.insert(parts, string.format("+%d cheese", given.cheese))
	end
	if given.goldenCheese then
		table.insert(parts, string.format("+%d Golden Cheese", given.goldenCheese))
	end
	if given.passXp then
		table.insert(parts, string.format("+%d Pass XP", given.passXp))
	end
	if given.rerollTokens then
		table.insert(parts, string.format("+%d Reroll Tokens", given.rerollTokens))
	end
	for _, id in given.cosmetics or {} do
		local def = Cosmetics.get(id)
		table.insert(parts, if def then def.name else id)
	end
	for _, id in given.titles or {} do
		local t = Cosmetics.EARNED_TITLES[id]
		table.insert(parts, "title " .. (if t then t.text else id))
	end
	return table.concat(parts, ", ")
end

return Grant
