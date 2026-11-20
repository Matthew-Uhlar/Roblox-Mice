--!strict
-- Pure Results-screen model (iteration 1 #12, #14, #18: P-8, P-9, P-10, P-28).
-- No Roblox APIs; specs run it in Lune.
--
-- Breakdown rows, so the headline matches what the profile gained:
--   run pot share, secured cheese, FIRST EXTRACTION bonus, contracts,
--   achievements, Double or Nothing (won ×2 / lost), pass XP, class XP.
-- Payload fields read (Team M2 / P; every one optional):
--   cheeseEarned, secured, totalCheese?,
--   firstExtract = {cheese, golden} | firstExtractBonus = {cheese, goldenCheese},
--   contracts = {cheese, passXp, count} | contractCheese,
--   achievements = {cheese, golden, count},
--   don = {won = bool, mult?, amount?} | donWon / donLost (number),
--   passXp, classXp,
--   mice, championKills | championAssists | champions, pois, kills (rivals downed),
--   breakdown = {{label, amount}} (a server-made list wins over all of the above).

local ResultsModel = {}

export type Row = { icon: string, label: string, value: string, highlight: boolean? }

local function num(v: any): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return 0
	end
	return n
end

local function int(n: number): string
	local v = math.floor(n + 0.5)
	local s = tostring(math.abs(v))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return (if v < 0 then "-" else "") .. out
end
ResultsModel.int = int

-- "+37" / "-37" (T-11: never "+-37")
local function signed(n: number): string
	return (if n < 0 then "" else "+") .. int(n)
end
ResultsModel.signed = signed

-- First-extraction bonus as (cheese, golden), or (0, 0).
function ResultsModel.firstExtract(r: any): (number, number)
	if type(r) ~= "table" then
		return 0, 0
	end
	local fe = r.firstExtract or r.firstExtractBonus
	if type(fe) == "table" then
		return num(fe.cheese), num(fe.golden or fe.goldenCheese)
	end
	return 0, 0
end

-- Double or Nothing outcome: "won" | "lost" | nil, and the amount.
function ResultsModel.don(r: any): (string?, number)
	if type(r) ~= "table" then
		return nil, 0
	end
	local d = r.don or r.doubleOrNothing
	if type(d) == "table" then
		if d.won == true then
			return "won", num(d.amount)
		elseif d.won == false or d.lost ~= nil then
			return "lost", num(d.amount or d.lost)
		end
	end
	if num(r.donWon) > 0 then
		return "won", num(r.donWon)
	elseif num(r.donLost) > 0 then
		return "lost", num(r.donLost)
	end
	return nil, 0
end

-- Total cheese the profile gained from this run (the headline).
function ResultsModel.total(r: any): number
	if type(r) ~= "table" then
		return 0
	end
	if r.totalCheese ~= nil then
		return num(r.totalCheese)
	end
	local t = num(r.cheeseEarned)
	local fe = ResultsModel.firstExtract(r)
	t += fe
	local c = r.contracts
	t += if type(c) == "table" then num(c.cheese) else num(r.contractCheese)
	local a = r.achievements
	if type(a) == "table" then
		t += num(a.cheese)
	end
	return t
end

function ResultsModel.rows(r: any): { Row }
	local out: { Row } = {}
	if type(r) ~= "table" then
		return out
	end
	if type(r.breakdown) == "table" and #r.breakdown > 0 then
		for _, b in r.breakdown do
			if type(b) == "table" then
				local amount = tonumber(b.amount)
				table.insert(out, {
					icon = tostring(b.icon or "🧀"),
					label = tostring(b.label or b.id or ""),
					value = if amount then signed(amount) else tostring(b.text or b.value or ""),
					highlight = b.highlight == true,
				})
			end
		end
		return out
	end
	local pot = num(r.cheeseEarned)
	local secured = num(r.secured)
	table.insert(out, { icon = "🧀", label = "Run cheese (your share)", value = signed(pot) })
	if secured > 0 then
		table.insert(
			out,
			{ icon = "🔒", label = "  of which secured during the run", value = int(secured) }
		)
	end
	local kind, amount = ResultsModel.don(r)
	if kind == "won" then
		table.insert(out, {
			icon = "🎲",
			label = "Double or Nothing won: pot ×2",
			value = if amount > 0 then signed(amount) else "×2",
			highlight = true,
		})
	elseif kind == "lost" then
		table.insert(out, {
			icon = "🎲",
			label = "Double or Nothing lost",
			value = if amount > 0 then "-" .. int(amount) else "pot lost",
		})
	end
	local fc, fg = ResultsModel.firstExtract(r)
	if fc > 0 or fg > 0 then
		table.insert(out, {
			icon = "🎉",
			label = "FIRST EXTRACTION bonus",
			value = signed(fc) .. (if fg > 0 then "  ✨" .. int(fg) else ""),
			highlight = true,
		})
	end
	local c = r.contracts
	local cc = if type(c) == "table" then num(c.cheese) else num(r.contractCheese)
	if cc > 0 then
		local n = if type(c) == "table" then num(c.count) else 0
		table.insert(out, {
			icon = "📜",
			label = if n > 0 then string.format("Contracts done (%d)", n) else "Contracts",
			value = signed(cc),
		})
	end
	local a = r.achievements
	if type(a) == "table" and (num(a.cheese) > 0 or num(a.golden) > 0) then
		table.insert(out, {
			icon = "🏅",
			label = "Achievements",
			value = signed(num(a.cheese))
				.. (if num(a.golden) > 0 then "  ✨" .. int(num(a.golden)) else ""),
		})
	end
	local px = num(r.passXp) + (if type(c) == "table" then num(c.passXp) else 0)
	if px > 0 then
		table.insert(out, { icon = "⭐", label = "Herd Pass XP", value = signed(px) })
	end
	if num(r.classXp) > 0 then
		table.insert(out, { icon = "🐘", label = "Class XP", value = signed(num(r.classXp)) })
	end
	return out
end

-- Run stats (P-9): mice and champions first, PvP last.
function ResultsModel.stats(r: any): { string }
	if type(r) ~= "table" then
		return {}
	end
	local champs = num(r.championKills or r.championAssists or r.champions)
	return {
		"🐭 Mice: " .. int(num(r.mice or r.miceKilled or r.stomps)),
		"👑 Champions: " .. int(champs),
		"✨ POIs: " .. int(num(r.pois)),
		"⚔ Rivals downed: " .. int(num(r.kills)),
	}
end

-- Loot column (iteration 3 T-12): gems found, a tier unlocked, a new Best
-- Solo and challenges done this run. A server `loot` table wins; otherwise
-- the profile snapshot from the run start is diffed with the profile the
-- server pushed with the payout (awardRun pushes it before Results).
--   loot = {gems = {gemView}, tierUnlocked?, bestSolo?, bestSoloSeconds?, challenges = {name}}
export type Loot = {
	gems: { any },
	tierUnlocked: number?,
	bestSolo: number?,
	bestSoloSeconds: number?,
	challenges: { string },
}

local function gemIds(p: any): { [number]: boolean }
	local out: { [number]: boolean } = {}
	local g = if type(p) == "table" then p.gems else nil
	if type(g) == "table" and type(g.inv) == "table" then
		for _, e in g.inv do
			if type(e) == "table" and tonumber(e.id) then
				out[tonumber(e.id) :: number] = true
			end
		end
	end
	return out
end

local function ladderOf(p: any): any
	if type(p) ~= "table" then
		return {}
	end
	return if type(p.ladder) == "table"
		then p.ladder
		elseif type(p.difficulty) == "table" then p.difficulty
		else {}
end

local function doneChallenges(p: any): { [string]: string }
	local out: { [string]: string } = {}
	local c = if type(p) == "table" then p.challenges else nil
	local list = if type(c) == "table" and type(c.list) == "table" then c.list else nil
	for _, e in list or {} do
		if type(e) == "table" and e.done == true and e.id ~= nil then
			out[tostring(e.id)] = tostring(e.name or e.id)
		end
	end
	return out
end

function ResultsModel.loot(r: any, before: any, after: any): Loot
	local out: Loot =
		{ gems = {}, tierUnlocked = nil, bestSolo = nil, bestSoloSeconds = nil, challenges = {} }
	local l = if type(r) == "table" then r.loot else nil
	if type(l) == "table" then
		out.gems = if type(l.gems) == "table" then l.gems else {}
		out.tierUnlocked = tonumber(l.tierUnlocked)
		out.bestSolo = tonumber(l.bestSolo)
		out.bestSoloSeconds = tonumber(l.bestSoloSeconds)
		for _, c in (if type(l.challenges) == "table" then l.challenges else {}) do
			table.insert(out.challenges, if type(c) == "table" then tostring(c.name or c.id) else tostring(c))
		end
		return out
	end
	if type(before) ~= "table" or type(after) ~= "table" then
		return out
	end
	local had = gemIds(before)
	local g = after.gems
	if type(g) == "table" and type(g.inv) == "table" then
		for _, e in g.inv do
			if type(e) == "table" and tonumber(e.id) and not had[tonumber(e.id) :: number] then
				table.insert(out.gems, e)
			end
		end
	end
	local lb, la = ladderOf(before), ladderOf(after)
	local ub, ua = num(lb.unlocked), num(la.unlocked)
	if ua > ub and ub > 0 then
		out.tierUnlocked = math.floor(ua)
	end
	local sb, sa = num(lb.bestSolo), num(la.bestSolo)
	if
		sa > sb
		or (sa > 0 and sa == sb and num(la.bestSoloTime) > 0 and num(la.bestSoloTime) < num(lb.bestSoloTime))
	then
		out.bestSolo = math.floor(sa)
		out.bestSoloSeconds = tonumber(la.bestSoloTime)
	end
	local cb = doneChallenges(before)
	for id, name in doneChallenges(after) do
		if not cb[id] then
			table.insert(out.challenges, name)
		end
	end
	table.sort(out.challenges)
	return out
end

-- Headline under the title (T-12): an extraction says "Extracted · secured X"
-- instead of a squad placement.
function ResultsModel.placementText(r: any): string?
	if type(r) ~= "table" then
		return nil
	end
	local kind = if type(r.result) == "string" then string.lower(r.result) else nil
	if kind == "extracted" or kind == "lastherd" or r.lastHerd == true then
		local s = num(r.secured)
		return "Extracted" .. (if s > 0 then " · secured 🧀 " .. int(s) else "")
	end
	return nil
end

return ResultsModel
