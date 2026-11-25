--!strict
-- Cheese Gems and Crumb Dust (iteration 2, ALIGNMENT §2c A2; replace the v5 charms that
-- never shipped). Pure data; Data/Gems holds the rules.
--
-- A gem drops at a TIER (the difficulty it dropped on, 1-11; 12 = Golden Wheel) with 5
-- rolled integer stats in that tier's range, maybe a unique perk, and an upgrade level
-- 0-5 paid in Crumb Dust. (iteration 4) Equipped gems (2 sockets, account level 1 / 10)
-- boost their OWNER only, from the start of the round (no squad aura).
-- Free drops only: never sold, rerolled or upgraded with Robux or Golden Cheese.
-- Damage (Bite) is PvE-only; Hide counts toward World's +25% PvP meta-HP cap.

export type UniqueDef = { id: string, name: string, text: string, classId: string? }

local G = {}

-- Stat order of `s` = {rinds, bite, hide, plating, stride}
G.STATS = { "rinds", "bite", "hide", "plating", "stride" }
G.STAT_NAMES = { rinds = "Rinds", bite = "Bite", hide = "Hide", plating = "Plating", stride = "Stride" }
-- Value of one stat point (fraction)
G.POINT = { rinds = 0.001, bite = 0.0005, hide = 0.0002, plating = 0.0003, stride = 0.0001 }
-- Caps on one hero's summed gems (fractions). (iteration 4: gems are personal, not a
-- squad aura; with 2 sockets these caps are rarely reached.)
G.SQUAD_CAP = { rinds = 1.0, bite = 0.60, hide = 0.25, plating = 0.30, stride = 0.08 }

-- Rolled range {min, max} per tier (Liberty's ranges); tier 12 = Golden Wheel.
-- (iteration 3, T-11) The low tiers are raised so a Mild gem is never worthless: tier 1
-- rolls at least 10 points (Rinds +1%). Ranges only ever go UP (Data/Gems.sanitize clamps
-- saved stats into the range, so a saved gem can only gain).
G.RANGES = {
	{ 10, 20 },
	{ 10, 22 },
	{ 12, 25 },
	{ 14, 30 },
	{ 15, 40 },
	{ 20, 50 },
	{ 25, 60 },
	{ 30, 75 },
	{ 35, 90 },
	{ 40, 105 },
	{ 50, 125 },
	{ 75, 170 },
	{ 75, 170 }, -- 13 (iteration 7, team Systems): Liberty's tier 13, Overtime milestones only
	{ 90, 200 }, -- 14 (iteration 7): Liberty's tier 14, deep Overtime only
}
G.MAX_TIER = #G.RANGES
-- Chance of a unique perk by tier
G.UNIQUE_CHANCE = { 0.02, 0.036, 0.052, 0.068, 0.084, 0.10, 0.13, 0.16, 0.19, 0.22, 0.25, 0.40, 0.45, 0.50 }

-- (iteration 3, T-11) Rookies (runs 0-2) never get a gem below this tier.
G.ROOKIE_MIN_TIER = 2
G.ROOKIE_RUNS = 3

G.MAX_LEVEL = 5
G.LEVEL_BONUS = 0.10 -- each upgrade level: +10% to every rolled stat
G.INVENTORY = 200
-- (iteration 4) 2 sockets (account level 1 / 10). A save with a gem in the old 3rd socket
-- just loses the socket: the gem stays in the inventory (Data/Gems.sanitize).
G.SOCKET_LEVELS = { 1, 10 }
G.MAX_GRANTS_PER_DAY = 80 -- logged above this (dupe watch, Z-17); never refused
G.MAX_DUST = 1_000_000

-- (iteration 4) Drops happen ONLY when a round is completed (extraction or full clear),
-- rolled by Data/Progress.afterRun at the match tier:
--   chance = min(CAP, (BASE + PER_STAGE x stages cleared) x the tier's reward)
-- plus a GUARANTEED gem of the tier the first time the account clears it (once per tier,
-- Data/Ladder). No boss, lair or Double-or-Nothing drops.
G.DROP = table.freeze({
	base = 0.06,
	perStage = 0.02,
	cap = 0.20,
})

-- ===== iteration 7 (team Systems) =====
-- Gem tiers 13-14 drop ONLY from Overtime wave milestones on the top two difficulty
-- tiers (Config/Difficulty COUNT - 1 and COUNT), rolled at the end of the run by
-- Data/Progress.afterRun: one roll per milestone reached (`wave` = Overtime waves
-- survived), at `chance`, for a gem of `tier`. Free drops only (never Robux).
G.OVERTIME_TOP_TIERS = 2 -- (kept for reference; iteration 8 QC: OVERTIME_MIN_TIER decides)
G.OVERTIME_MIN_TIER = 10 -- Overtime milestone gems: Moldy (10), Doomwheel (11) and Cosmic Curd (12)
G.OVERTIME_MILESTONES = table.freeze({
	{ wave = 10, tier = 13, chance = 0.12 },
	{ wave = 15, tier = 13, chance = 0.12 },
	{ wave = 20, tier = 14, chance = 0.08 },
	{ wave = 25, tier = 14, chance = 0.08 },
	{ wave = 30, tier = 14, chance = 0.08 },
	{ wave = 40, tier = 14, chance = 0.08 },
	{ wave = 50, tier = 14, chance = 0.08 },
})
-- Miniboss (Mouse Champion) first kills: Crumb Dust per kill credited to the player's
-- squad, for the first `dailyKills` kills per account per UTC day.
G.MINIBOSS_DUST = table.freeze({ perKill = 5, dailyKills = 10 })
-- ===== end iteration 7 =====

-- The round-completion drop chance.
function G.roundChance(stagesCleared: number, tierReward: number): number
	local s = if type(stagesCleared) == "number" and stagesCleared == stagesCleared
		then math.max(0, stagesCleared)
		else 0
	local r = if type(tierReward) == "number"
			and tierReward == tierReward
			and tierReward > 0
		then tierReward
		else 1
	return math.min(G.DROP.cap, (G.DROP.base + G.DROP.perStage * s) * r)
end

-- Upgrading to level n costs n x tier Crumb Dust.
function G.upgradeCost(tier: number, toLevel: number): number
	return math.max(1, math.floor(toLevel)) * math.clamp(math.floor(tier), 1, G.MAX_TIER)
end

-- Salvage: tier dust, +tier more with a unique.
function G.salvageDust(tier: number, hasUnique: boolean): number
	local t = math.clamp(math.floor(tier), 1, G.MAX_TIER)
	return t + (if hasUnique then t else 0)
end

-- ===== iter6 Gem Vault (team Gems): feed / bulk salvage / power (shared by server + client) =====
G.FEED_MAX = 50 -- fodder gems per FeedGems request
G.SALVAGE_MAX = 100 -- gems per SalvageGems request

-- Feeding: the fodder's total salvage dust buys the target's upgrade levels in order
-- (level n costs upgradeCost(tier, n)) as far as it pays, up to MAX_LEVEL. What is not
-- spent goes to the dust balance. Returns (newLevel, spent, leftover).
function G.feedResult(tier: number, level: number, dust: number): (number, number, number)
	local lv = math.clamp(math.floor(level), 0, G.MAX_LEVEL)
	local left = math.max(0, math.floor(dust))
	local spent = 0
	while lv < G.MAX_LEVEL do
		local cost = G.upgradeCost(tier, lv + 1)
		if left < cost then
			break
		end
		left -= cost
		spent += cost
		lv += 1
	end
	return lv, spent, left
end

-- Power score (sorting / compare): effective stat points (rolled x the level bonus)
-- plus the tier's max roll for a unique.
function G.power(tier: number, stats: { number }, level: number, hasUnique: boolean): number
	local t = math.clamp(math.floor(tier), 1, G.MAX_TIER)
	local sum = 0
	for i = 1, #G.STATS do
		sum += stats[i] or 0
	end
	local pw = sum * (1 + G.LEVEL_BONUS * math.clamp(math.floor(level), 0, G.MAX_LEVEL))
	return math.floor(pw + (if hasUnique then G.RANGES[t][2] else 0) + 0.5)
end
-- ===== end iter6 Gem Vault =====

local function u(id: string, name: string, text: string, classId: string?): UniqueDef
	return { id = id, name = name, text = text, classId = classId }
end

-- 16 uniques (iteration 7): one per class (applies while the OWNER plays that class; iteration 4: gems
-- are personal) + 5 generic.
-- M1 applies them (World / Stats); the text is what the UI shows.
G.UNIQUES = {
	u("u_elephante", "Stampede Heart", "As Elephante: +25% ability area.", "elephante"),
	u("u_ele_fonte", "Spring Source", "As Ele Fonte: heals 30% more.", "ele_fonte"),
	u("u_ellie_fawn", "True Aim", "As Ellie Fawn: +1 projectile.", "ellie_fawn"),
	u("u_le_fante", "Iron Brow", "As Le F'ante: +15% armor.", "le_fante"),
	u("u_filet", "Quick Cut", "As Filet: +15% attack speed.", "filet"),
	u("u_jumbo", "Mountain", "As Jumbo: +10% max HP.", "jumbo"),
	u("u_fizzante", "Fizz Burst", "As Fizzante: ability cooldown -15%.", "fizzante"),
	-- (iteration 7, team Classes) the Tinkerphant's missing unique + the 3 new classes
	u("u_tinkerphant", "Master Mechanic", "As Tinkerphant: +20% turret and barricade HP.", "tinkerphant"),
	u("u_ele_vation", "Hawk Eye", "As Ele Vation: rifle shots pierce 1 more mouse.", "ele_vation"),
	u("u_elephaid", "Gentle Hands", "As Elephaid: +10% of your damage heals squadmates.", "elephaid"),
	u("u_trunkillery", "Bunker Buster", "As Trunktillery: +15% area.", "trunkillery"),
	u("u_cooldowns", "Quick Wits", "Ability cooldowns -10%."),
	u("u_stride", "Fleet Hooves", "+6% move speed."),
	u("u_glass_tusk", "Glass Tusk", "-15% max HP, +20% damage to mice and bosses."),
	u("u_lucky_crumb", "Lucky Crumb", "20% chance of double damage to mice and bosses."),
	u("u_unshakable", "Unshakable", "Immune to slows and stuns from mice and bosses."),
} :: { UniqueDef }

G.UNIQUE_BY_ID = {} :: { [string]: UniqueDef }
G.UNIQUE_ORDER = {} :: { string }
for _, def in G.UNIQUES do
	G.UNIQUE_BY_ID[def.id] = def
	table.insert(G.UNIQUE_ORDER, def.id)
end

function G.unique(id: any): UniqueDef?
	if type(id) ~= "string" then
		return nil
	end
	return G.UNIQUE_BY_ID[id]
end

G.TIER_NAMES = {
	"Mild",
	"Medium",
	"Sharp",
	"Extra Sharp",
	"Aged",
	"Smoked",
	"Pungent",
	"Stinky",
	"Scorched",
	"Moldy",
	"Doomwheel",
	"Golden Wheel",
	"Midnight Wheel", -- 13 (iteration 7)
	"Eternal Wheel", -- 14 (iteration 7)
}

return G
