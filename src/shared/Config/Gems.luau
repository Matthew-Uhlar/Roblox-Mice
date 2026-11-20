--!strict
-- Cheese Gems and Crumb Dust (iteration 2, ALIGNMENT §2c A2; replace the v5 charms that
-- never shipped). Pure data; Data/Gems holds the rules.
--
-- A gem drops at a TIER (the difficulty it dropped on, 1-11; 12 = Golden Wheel) with 5
-- rolled integer stats in that tier's range, maybe a unique perk, and an upgrade level
-- 0-5 paid in Crumb Dust. Equipped gems (3 sockets, account level 1 / 10 / 25) are a
-- SQUAD aura: the squad gets the SUM of every member's equipped gems, within squad caps.
-- Free drops only: never sold, rerolled or upgraded with Robux or Golden Cheese.
-- Damage (Bite) is PvE-only; Hide counts toward World's +25% PvP meta-HP cap.

export type UniqueDef = { id: string, name: string, text: string, classId: string? }

local G = {}

-- Stat order of `s` = {rinds, bite, hide, plating, stride}
G.STATS = { "rinds", "bite", "hide", "plating", "stride" }
G.STAT_NAMES = { rinds = "Rinds", bite = "Bite", hide = "Hide", plating = "Plating", stride = "Stride" }
-- Value of one stat point (fraction)
G.POINT = { rinds = 0.001, bite = 0.0005, hide = 0.0002, plating = 0.0003, stride = 0.0001 }
-- Squad caps on the summed aura (fractions)
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
}
G.MAX_TIER = #G.RANGES
-- Chance of a unique perk by tier
G.UNIQUE_CHANCE = { 0.02, 0.036, 0.052, 0.068, 0.084, 0.10, 0.13, 0.16, 0.19, 0.22, 0.25, 0.40 }

-- (iteration 3, T-11) Rookies (runs 0-2) never get a gem below this tier.
G.ROOKIE_MIN_TIER = 2
G.ROOKIE_RUNS = 3

G.MAX_LEVEL = 5
G.LEVEL_BONUS = 0.10 -- each upgrade level: +10% to every rolled stat
G.INVENTORY = 200
G.SOCKET_LEVELS = { 1, 10, 25 }
G.MAX_GRANTS_PER_DAY = 80 -- logged above this (dupe watch, Z-17); never refused
G.MAX_DUST = 1_000_000

-- Drop chances (M2 rolls with DataService.rollGem; P rolls the end-of-match ones).
G.DROP = table.freeze({
	boss = 0.35, -- bosses 1-3, top-damage squad, humans only
	finalBoss = 1.0,
	donMult = 2, -- a won Double or Nothing on that stage doubles the boss chance
	lair = 0.10, -- lair champion: a gem at tier - 1
	extract = 0.5, -- extracting at stage >= EXTRACT_STAGE: a gem at tier - 1
	extractStage = 2,
})

-- Upgrading to level n costs n x tier Crumb Dust.
function G.upgradeCost(tier: number, toLevel: number): number
	return math.max(1, math.floor(toLevel)) * math.clamp(math.floor(tier), 1, G.MAX_TIER)
end

-- Salvage: tier dust, +tier more with a unique.
function G.salvageDust(tier: number, hasUnique: boolean): number
	local t = math.clamp(math.floor(tier), 1, G.MAX_TIER)
	return t + (if hasUnique then t else 0)
end

local function u(id: string, name: string, text: string, classId: string?): UniqueDef
	return { id = id, name = name, text = text, classId = classId }
end

-- 11 uniques: one per class (applies to that class in your squad) + 4 generic.
-- M1 applies them (World / Stats); the text is what the UI shows.
G.UNIQUES = {
	u("u_elephante", "Stampede Heart", "Elephante in your squad: +25% ability area.", "elephante"),
	u("u_ele_fonte", "Spring Source", "Ele Fonte in your squad: heals 30% more.", "ele_fonte"),
	u("u_ellie_fawn", "True Aim", "Ellie Fawn in your squad: +1 projectile.", "ellie_fawn"),
	u("u_le_fante", "Iron Brow", "Le Fante in your squad: +15% armor.", "le_fante"),
	u("u_filet", "Quick Cut", "Filet in your squad: +15% attack speed.", "filet"),
	u("u_jumbo", "Mountain", "Jumbo in your squad: +10% max HP.", "jumbo"),
	u("u_fizzante", "Fizz Burst", "Fizzante in your squad: ability cooldown -15%.", "fizzante"),
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
}

return G
