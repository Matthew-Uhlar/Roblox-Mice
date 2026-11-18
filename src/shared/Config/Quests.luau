--!strict
-- Herd Contracts: daily and weekly quests (v4 plan, research §4.3). Pure data.
--
-- Every day (UTC) a player gets 3 dailies: one Easy, one Medium, one Hard, picked
-- deterministically from the pool (Data/Quests). Every week (Monday 00:00 UTC) all
-- WEEKLY contracts are active. 1 free reroll a day; more cost cheese (a repeatable
-- cheese sink), never Robux.
--
-- Policy (asserted by DataQuests.spec): no contract needs Robux, a friend, Double or
-- Nothing, or downing a human. Solo play with bots can finish every contract.
--
-- Progress `kind`s and who feeds them (docs/MONETIZATION.md "Integration API"):
--   fed by DataService.awardRun from the end-of-run stats (never send these live):
--     match        1 per finished match
--     stage        stages cleared this match
--     clearMax     stages cleared in ONE match ("max" contracts: progress = best match)
--     extract      1 if the squad extracted or was the Last Herd
--     boss         bosses defeated (= stages cleared)
--     champion     Mouse Champions killed with squad credit (stats.championKills)
--     pois         POIs activated (summary.pois)
--     bank         cheese banked this match (before Robux multipliers)
--     classRun     the class played ("distinct" contracts count different classes)
--   fed live by M2 with DataService.questEvent(player, kind, n):
--     mice         mice stomped
--     ability      ability uses
--     revive       squadmates revived
--     gear         gear items picked up
--     vault        Cheese Vaults opened
--     lair         Lair Champions killed (squad credit)
--     carrier      golden carrier mice caught
--     totem        seconds holding a Power Totem

export type Tier = "Easy" | "Medium" | "Hard" | "Weekly" | "Rookie"
export type Mode = "sum" | "max" | "distinct"

export type QuestDef = {
	id: string,
	text: string, -- shown to the player; "%d" is replaced by the target
	kind: string,
	target: number,
	tier: Tier,
	mode: Mode?, -- default "sum"
	passXp: number,
	cheese: number,
}

local Q = {}

-- Kinds DataService.questEvent accepts from game code (live events). The others
-- come only from the end-of-run award so nothing is counted twice.
Q.LIVE_KINDS = table.freeze({
	runLevel = true, -- (iter 1) the hero's in-run level ("max": send the new level on level-up)
	mice = true,
	ability = true,
	revive = true,
	gear = true,
	vault = true,
	lair = true,
	carrier = true,
	totem = true,
})
Q.RUN_KINDS = table.freeze({
	match = true,
	stage = true,
	clearMax = true,
	extract = true,
	boss = true,
	champion = true,
	pois = true,
	bank = true,
	classRun = true,
})
Q.MAX_EVENT = 100_000 -- one questEvent call adds at most this much

Q.REWARD = table.freeze({
	Easy = { passXp = 150, cheese = 100 },
	Medium = { passXp = 250, cheese = 150 },
	Hard = { passXp = 350, cheese = 200 },
	Rookie = { passXp = 150, cheese = 100 }, -- (iter 1)
})

Q.DAILY_COUNT = 3
-- (iter 1, P-11) players with fewer finished matches than this get 3 contracts from
-- the ROOKIE pool instead (Easy rewards), dealt at the next daily deal.
Q.ROOKIE_RUNS = 6
Q.FREE_REROLLS_PER_DAY = 1
Q.EXTRA_REROLL_CHEESE = 150 -- repeatable cheese sink
Q.MAX_EXTRA_REROLLS_PER_DAY = 3

local function d(id: string, text: string, kind: string, target: number, tier: Tier, mode: Mode?): QuestDef
	local r = (Q.REWARD :: any)[tier]
	return {
		id = id,
		text = text,
		kind = kind,
		target = target,
		tier = tier,
		mode = mode,
		passXp = r.passXp,
		cheese = r.cheese,
	}
end

Q.DAILY = {
	-- Easy
	d("d_mice", "Stomp %d mice", "mice", 300, "Easy"), -- (iter 1, P-11) was 1,200
	d("d_matches", "Finish %d matches", "match", 2, "Easy"),
	d("d_pois", "Activate %d POIs", "pois", 3, "Easy"),
	d("d_ability", "Use your ability %d times", "ability", 30, "Easy"),
	d("d_revive", "Revive squadmates %d times", "revive", 2, "Easy"),
	d("d_gear", "Pick up %d gear items", "gear", 2, "Easy"), -- (iter 1, P-11) was 4
	-- Medium
	d("d_champ2", "Help defeat %d Mouse Champions", "champion", 2, "Medium"),
	d("d_extract", "Extract %d time", "extract", 1, "Medium"),
	d("d_clear3", "Clear %d stages in one match", "clearMax", 3, "Medium", "max"),
	d("d_bank", "Bank %d cheese", "bank", 1000, "Medium"),
	d("d_stages", "Clear %d stages", "stage", 4, "Medium"),
	d("d_carrier", "Catch %d golden carrier mice", "carrier", 2, "Medium"),
	-- Hard
	d("d_vault", "Open %d Cheese Vault", "vault", 1, "Hard"),
	d("d_lair", "Help defeat %d Lair Champion", "lair", 1, "Hard"),
	d("d_boss", "Defeat %d bosses", "boss", 3, "Hard"),
	d("d_clear4", "Clear all %d stages in one match", "clearMax", 4, "Hard", "max"),
	d("d_champ4", "Help defeat %d Mouse Champions", "champion", 4, "Hard"),
	d("d_bank2", "Bank %d cheese", "bank", 2500, "Hard"),
} :: { QuestDef }

local function w(
	id: string,
	text: string,
	kind: string,
	target: number,
	passXp: number,
	mode: Mode?
): QuestDef
	return {
		id = id,
		text = text,
		kind = kind,
		target = target,
		tier = "Weekly",
		mode = mode,
		passXp = passXp,
		cheese = 300,
	}
end

Q.WEEKLY = {
	w("w_extract", "Extract %d times", "extract", 5, 500),
	w("w_champs", "Help defeat %d Mouse Champions", "champion", 12, 500),
	w("w_bosses", "Defeat %d bosses", "boss", 8, 500),
	w("w_classes", "Finish matches with %d different classes", "classRun", 3, 500, "distinct"),
	w("w_pois", "Activate %d POIs", "pois", 20, 500),
	w("w_bank", "Bank %d cheese", "bank", 6000, 600),
} :: { QuestDef }

Q.byId = {} :: { [string]: QuestDef }
for _, list in { Q.DAILY, Q.WEEKLY } do
	for _, def in list do
		Q.byId[def.id] = def
	end
end

function Q.get(id: any): QuestDef?
	if type(id) ~= "string" then
		return nil
	end
	return Q.byId[id]
end

-- (iter 1) Rookie pool: short goals a first-day player finishes in 1-3 matches.
Q.ROOKIE = {
	d("r_matches", "Finish %d matches", "match", 2, "Rookie"),
	d("r_mice", "Stomp %d mice", "mice", 150, "Rookie"),
	d("r_pois", "Activate %d POIs", "pois", 2, "Rookie"),
	d("r_level", "Reach level %d in a match", "runLevel", 5, "Rookie", "max"),
} :: { QuestDef }
for _, def in Q.ROOKIE do
	Q.byId[def.id] = def
end

-- Daily pool of one tier, in config order (tier "Rookie" = the ROOKIE pool).
function Q.dailyPool(tier: Tier): { QuestDef }
	if tier == "Rookie" then
		return table.clone(Q.ROOKIE)
	end
	local out = {}
	for _, def in Q.DAILY do
		if def.tier == tier then
			table.insert(out, def)
		end
	end
	return out
end

-- Text with the target filled in.
function Q.describe(def: QuestDef): string
	local n = def.target
	local s = if n >= 1000 then string.format("%d,%03d", n // 1000, n % 1000) else tostring(n)
	return (string.gsub(def.text, "%%d", s))
end

-- UTC week number (weeks start on Monday 00:00 UTC). Day 0 (1970-01-01) was a Thursday.
function Q.weekFor(day: number): number
	return math.floor((math.floor(day) + 3) / 7)
end

return Q
