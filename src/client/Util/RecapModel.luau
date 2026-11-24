--!strict
-- RecapModel (iteration 7 §B4, team Client): the death recap card's view from
-- the S2C DeathRecap payload (team Systems, src/shared/Run/DeathRecap.luau):
--   { eliminated, by?, killer?, top = {{cat, name, kind?, id?, isBot?, squad?, amount}},
--     window, t }
-- Pure (Lune-tested, ClientIter7.spec). Tolerates missing fields.

local RecapModel = {}

RecapModel.SHOW_SECONDS = 9 -- the card fades after this (or on revive / respawn)
RecapModel.MAX_ROWS = 3

RecapModel.CAT_ICON = table.freeze({
	hero = "⚔",
	mouse = "🐭",
	champion = "👑",
	boss = "💀",
	storm = "🌪",
	hazard = "⚠",
} :: { [string]: string })

RecapModel.CAT_COLOR = table.freeze({
	hero = { 226, 72, 58 },
	mouse = { 170, 150, 120 },
	champion = { 179, 107, 255 },
	boss = { 235, 45, 45 },
	storm = { 120, 170, 255 },
	hazard = { 255, 170, 40 },
} :: { [string]: { number } })

export type Row = { icon: string, name: string, amount: number, frac: number, color: { number }, cat: string }
export type View = { title: string, sub: string, rows: { Row }, eliminated: boolean, total: number }

local function nameOf(src: any): string
	if type(src) ~= "table" then
		return "Unknown"
	end
	local n = if type(src.name) == "string" and src.name ~= "" then src.name else "Unknown"
	if src.isBot == true then
		n = "🤖 " .. n -- bots are always labelled
	end
	return n
end

function RecapModel.view(p: any): View?
	if type(p) ~= "table" then
		return nil
	end
	local eliminated = p.eliminated == true
	local rows: { Row } = {}
	local total = 0
	local top = if type(p.top) == "table" then p.top else {}
	for _, s in top do
		if type(s) == "table" then
			local amount = math.max(0, math.floor((tonumber(s.amount) or 0) + 0.5))
			local cat = if type(s.cat) == "string" then s.cat else "hazard"
			table.insert(rows, {
				icon = RecapModel.CAT_ICON[cat] or "⚠",
				name = nameOf(s),
				amount = amount,
				frac = 0,
				color = RecapModel.CAT_COLOR[cat] or RecapModel.CAT_COLOR.hazard,
				cat = cat,
			})
			total += amount
		end
		if #rows >= RecapModel.MAX_ROWS then
			break
		end
	end
	table.sort(rows, function(a, b)
		return a.amount > b.amount
	end)
	local maxA = if rows[1] then math.max(1, rows[1].amount) else 1
	for _, r in rows do
		r.frac = r.amount / maxA
	end
	local by = if type(p.killer) == "table" and eliminated then p.killer else p.by
	local who = if type(by) == "table" then nameOf(by) else nil
	local title = if eliminated then "💀 Eliminated" else "🩹 Downed"
	if who then
		title ..= " by " .. who
	end
	local window = tonumber(p.window) or 10
	local sub = if #rows > 0
		then string.format("Top damage, last %ds", math.floor(window + 0.5))
		else "No damage recorded"
	return { title = title, sub = sub, rows = rows, eliminated = eliminated, total = total }
end

-- Design sizes of the card (UI/DeathRecapUI), checked by the readability spec:
-- every text is >= 13 px and fits its box.
RecapModel.UI = table.freeze({
	w = 340,
	titleText = 20,
	titleBox = 28,
	subText = 14,
	subBox = 20,
	rowH = 30,
	rowText = 15,
	pad = 10,
})

function RecapModel.height(rows: number): number
	local U = RecapModel.UI
	return U.pad * 2 + U.titleBox + U.subBox + 6 + math.max(1, rows) * (U.rowH + 4)
end

return RecapModel
