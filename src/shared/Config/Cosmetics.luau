--!strict
-- Elephant cosmetics (Team D): trails, hats and colour tints. Pure data.
--
-- `source` says how a cosmetic is obtained:
--   "shop"   buy with cheese (priceCheese) and/or Golden Cheese (priceGolden)
--   "pass"   granted by a game pass (passKey) - see Config/Monetization
--   "daily"  granted by the 7-day login streak (Data/Daily)
--   "club"   Cheese Club monthly cosmetic (kept forever)
--   "level"  granted at account level `unlockLevel` (every 5 levels, Data/Award)
--   "epic"   free Epic boss drop (High-tier routes); RunDirector grants one it picks
-- Everything sold is shown with its exact price; nothing is random.
-- `color` is {r, g, b} 0..255 (plain table so it loads in Lune).

local Types = require("../Types")

export type Slot = "trail" | "hat" | "tint"
export type Source = "shop" | "pass" | "daily" | "club" | "level" | "epic"

export type CosmeticDef = {
	id: string,
	name: string,
	slot: Slot,
	source: Source,
	color: Types.Rgb?,
	priceCheese: number?,
	priceGolden: number?,
	passKey: string?,
	unlockLevel: number?,
	description: string?,
}

local C = {}

C.SLOTS = { "trail", "hat", "tint" } :: { Slot }

local list: { CosmeticDef } = {
	-- Trails ---------------------------------------------------------------
	{
		id = "trail_crumbs",
		name = "Cheese Crumbs",
		slot = "trail",
		source = "shop",
		color = { 250, 210, 80 },
		priceCheese = 1500,
	},
	{
		id = "trail_bubbles",
		name = "Bubbles",
		slot = "trail",
		source = "shop",
		color = { 140, 210, 255 },
		priceCheese = 2500,
	},
	{
		id = "trail_lava",
		name = "Lava Drips",
		slot = "trail",
		source = "shop",
		color = { 255, 90, 30 },
		priceGolden = 400,
	},
	{
		id = "trail_stardust",
		name = "Mozzarella Stardust",
		slot = "trail",
		source = "shop",
		color = { 235, 235, 255 },
		priceCheese = 8000,
		priceGolden = 800,
	},
	{
		id = "trail_golden_tusk",
		name = "Golden Tusk",
		slot = "trail",
		source = "pass",
		passKey = "vip",
		color = { 255, 200, 40 },
	},
	{
		id = "trail_streak",
		name = "Streak Sparks",
		slot = "trail",
		source = "daily",
		color = { 255, 150, 60 },
	},
	{
		id = "trail_sparkle",
		name = "Sparkle",
		slot = "trail",
		source = "level",
		unlockLevel = 15,
		color = { 255, 255, 180 },
	},
	{
		id = "trail_rainbow",
		name = "Rainbow Rind",
		slot = "trail",
		source = "level",
		unlockLevel = 30,
		color = { 255, 120, 200 },
	},
	{ id = "trail_embers", name = "Boss Embers", slot = "trail", source = "epic", color = { 255, 110, 40 } },
	{
		id = "trail_club_swirl",
		name = "Club Swirl",
		slot = "trail",
		source = "club",
		color = { 60, 200, 180 },
	},

	-- Hats -----------------------------------------------------------------
	{ id = "hat_party", name = "Party Hat", slot = "hat", source = "shop", priceCheese = 800 },
	{ id = "hat_chef", name = "Chef's Toque", slot = "hat", source = "shop", priceCheese = 1200 },
	{ id = "hat_beret", name = "Beret", slot = "hat", source = "shop", priceCheese = 1500 },
	{ id = "hat_wizard", name = "Wizard Hat", slot = "hat", source = "shop", priceGolden = 300 },
	{
		id = "hat_astronaut",
		name = "Moon Helmet",
		slot = "hat",
		source = "shop",
		priceCheese = 6000,
		priceGolden = 600,
	},
	{ id = "hat_vip_crown", name = "VIP Crown", slot = "hat", source = "pass", passKey = "vip" },
	{ id = "hat_founder", name = "Founder's Plume", slot = "hat", source = "pass", passKey = "founders" },
	{ id = "hat_viking", name = "Viking Helm", slot = "hat", source = "pass", passKey = "wardrobe" },
	{ id = "hat_pirate", name = "Pirate Hat", slot = "hat", source = "pass", passKey = "wardrobe" },
	{ id = "hat_flower", name = "Flower Crown", slot = "hat", source = "pass", passKey = "wardrobe" },
	{ id = "hat_cheese_wedge", name = "Cheese Wedge", slot = "hat", source = "level", unlockLevel = 5 },
	{ id = "hat_top", name = "Top Hat", slot = "hat", source = "level", unlockLevel = 20 },
	{ id = "hat_boss_horns", name = "Boss Horns", slot = "hat", source = "epic" },
	{ id = "hat_club_cap", name = "Club Cap", slot = "hat", source = "club" },

	-- Tints ----------------------------------------------------------------
	{ id = "tint_sunny", name = "Sunny", slot = "tint", source = "daily", color = { 255, 220, 120 } },
	{
		id = "tint_mint",
		name = "Mint",
		slot = "tint",
		source = "shop",
		color = { 160, 230, 190 },
		priceCheese = 600,
	},
	{
		id = "tint_blush",
		name = "Blush",
		slot = "tint",
		source = "shop",
		color = { 245, 170, 190 },
		priceCheese = 600,
	},
	{
		id = "tint_midnight",
		name = "Midnight",
		slot = "tint",
		source = "shop",
		color = { 50, 50, 100 },
		priceGolden = 300,
	},
	{
		id = "tint_cheddar",
		name = "Cheddar",
		slot = "tint",
		source = "shop",
		color = { 250, 160, 40 },
		priceCheese = 3000,
		priceGolden = 300,
	},
	{
		id = "tint_founder_gold",
		name = "Founder Gold",
		slot = "tint",
		source = "pass",
		passKey = "founders",
		color = { 230, 185, 60 },
	},
	{
		id = "tint_bubblegum",
		name = "Bubblegum",
		slot = "tint",
		source = "pass",
		passKey = "wardrobe",
		color = { 255, 140, 210 },
	},
	{
		id = "tint_lagoon",
		name = "Lagoon",
		slot = "tint",
		source = "pass",
		passKey = "wardrobe",
		color = { 40, 180, 200 },
	},
	{
		id = "tint_lava",
		name = "Lava",
		slot = "tint",
		source = "pass",
		passKey = "wardrobe",
		color = { 200, 60, 30 },
	},
	{
		id = "tint_moss",
		name = "Moss",
		slot = "tint",
		source = "level",
		unlockLevel = 10,
		color = { 110, 150, 70 },
	},
	{
		id = "tint_royal",
		name = "Royal",
		slot = "tint",
		source = "level",
		unlockLevel = 25,
		color = { 110, 60, 180 },
	},
	{ id = "tint_shadow", name = "Shadow", slot = "tint", source = "epic", color = { 40, 40, 50 } },
	{ id = "tint_club_teal", name = "Club Teal", slot = "tint", source = "club", color = { 0, 160, 160 } },
}

C.LIST = list
C.byId = {} :: { [string]: CosmeticDef }
for _, def in list do
	C.byId[def.id] = def
end

function C.get(id: string): CosmeticDef?
	return C.byId[id]
end

-- Cosmetics unlocked when reaching `level` (exactly that level).
function C.forLevel(level: number): { string }
	local out = {}
	for _, def in list do
		if def.source == "level" and def.unlockLevel == level then
			table.insert(out, def.id)
		end
	end
	return out
end

-- Free Epic-drop pool (RunDirector picks one with its run Rng; it's a free drop, not a paid item).
function C.epicPool(): { string }
	local out = {}
	for _, def in list do
		if def.source == "epic" then
			table.insert(out, def.id)
		end
	end
	return out
end

return C
