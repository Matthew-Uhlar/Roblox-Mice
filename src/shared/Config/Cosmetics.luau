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
--   "season" (v6) Herd Pass track reward (Config/Pass, `season` = season number)
--   "bundle" (v6) granted by a Robux bundle product (`bundleKey`, Config/Monetization)
--   "reward" (v6) achievement / Mousepedia / account-level reward (Config/Achievements,
--            Config/Collection, Config/AccountRewards)
-- (v6) `rotation = true` puts a "shop" cosmetic in the shared daily Featured rotation
-- (Data/Shop.featured). Rotation is a spotlight only: every shop item stays buyable.
-- Everything sold is shown with its exact price; nothing is random.
-- `color` is {r, g, b} 0..255 (plain table so it loads in Lune).
--
-- How each slot is drawn in game (Services/CosmeticsService via Data/Looks):
--   trail  a Trail between two Attachments on the HumanoidRootPart, gradient
--          `color` -> `color2` (or a lighter `color`). Tuning: C.TRAIL.
--   hat    a part-built hat welded on top of the Head. `shape` names an entry of
--          C.HAT_SHAPES (pure geometry, studs for a 1.2-stud head, scaled to the
--          real head); parts use `color`, or `accent` when the part says so.
--   tint   a Highlight over the character in `color`. Tuning: C.TINT.
-- Every cosmetic of every slot must be drawable: DataConfig.spec asserts it.
local Types = require("../Types")

export type Slot = "trail" | "hat" | "tint"
export type Source = "shop" | "pass" | "daily" | "club" | "level" | "epic" | "season" | "bundle" | "reward"

export type CosmeticDef = {
	id: string,
	name: string,
	slot: Slot,
	source: Source,
	color: Types.Rgb?,
	color2: Types.Rgb?, -- trails: gradient end colour (default: a lighter `color`)
	accent: Types.Rgb?, -- hats: colour of the parts marked `accent`
	shape: string?, -- hats: key into C.HAT_SHAPES
	priceCheese: number?,
	priceGolden: number?,
	passKey: string?,
	unlockLevel: number?,
	description: string?,
	rotation: boolean?, -- (v6) in the daily Featured rotation pool (source "shop")
	season: number?, -- (v6) source "season": the Herd Pass season that awards it
	bundleKey: string?, -- (v6) source "bundle": the Config/Monetization product key
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
		color2 = { 255, 200, 60 },
		priceGolden = 300,
	},
	{
		id = "trail_stardust",
		name = "Mozzarella Stardust",
		slot = "trail",
		source = "shop",
		color = { 235, 235, 255 },
		color2 = { 170, 190, 255 },
		priceCheese = 8000,
		priceGolden = 500,
	},
	{
		id = "trail_golden_tusk",
		name = "Golden Tusk",
		slot = "trail",
		source = "pass",
		passKey = "vip",
		color = { 255, 200, 40 },
		color2 = { 255, 245, 200 },
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
		color2 = { 120, 200, 255 },
	},
	{ id = "trail_embers", name = "Boss Embers", slot = "trail", source = "epic", color = { 255, 110, 40 } },
	{
		id = "trail_club_swirl",
		name = "Club Swirl",
		slot = "trail",
		source = "club",
		color = { 60, 200, 180 },
		color2 = { 240, 250, 255 },
	},

	-- Hats -----------------------------------------------------------------
	{
		id = "hat_party",
		name = "Party Hat",
		slot = "hat",
		source = "shop",
		priceCheese = 800,
		shape = "cone",
		color = { 255, 90, 140 },
		accent = { 255, 230, 90 },
	},
	{
		id = "hat_chef",
		name = "Chef's Toque",
		slot = "hat",
		source = "shop",
		priceCheese = 1200,
		shape = "toque",
		color = { 250, 250, 250 },
		accent = { 225, 225, 230 },
	},
	{
		id = "hat_beret",
		name = "Beret",
		slot = "hat",
		source = "shop",
		priceCheese = 1500,
		shape = "beret",
		color = { 200, 40, 60 },
		accent = { 70, 25, 35 },
	},
	{
		id = "hat_wizard",
		name = "Wizard Hat",
		slot = "hat",
		source = "shop",
		priceGolden = 200,
		shape = "wizard",
		color = { 70, 60, 170 },
		accent = { 255, 220, 90 },
	},
	{
		id = "hat_astronaut",
		name = "Moon Helmet",
		slot = "hat",
		source = "shop",
		priceCheese = 6000,
		priceGolden = 400,
		shape = "helmet",
		color = { 235, 240, 250 },
		accent = { 90, 160, 255 },
	},
	{
		id = "hat_vip_crown",
		name = "VIP Crown",
		slot = "hat",
		source = "pass",
		passKey = "vip",
		shape = "crown",
		color = { 255, 200, 40 },
		accent = { 220, 40, 80 },
	},
	{
		id = "hat_founder",
		name = "Founder's Plume",
		slot = "hat",
		source = "pass",
		passKey = "founders",
		shape = "plume",
		color = { 40, 50, 110 },
		accent = { 230, 185, 60 },
	},
	{
		id = "hat_viking",
		name = "Viking Helm",
		slot = "hat",
		source = "pass",
		passKey = "wardrobe",
		shape = "viking",
		color = { 150, 150, 160 },
		accent = { 245, 235, 210 },
	},
	{
		id = "hat_pirate",
		name = "Pirate Hat",
		slot = "hat",
		source = "pass",
		passKey = "wardrobe",
		shape = "tricorn",
		color = { 40, 35, 35 },
		accent = { 245, 245, 235 },
	},
	{
		id = "hat_flower",
		name = "Flower Crown",
		slot = "hat",
		source = "pass",
		passKey = "wardrobe",
		shape = "flowers",
		color = { 255, 150, 190 },
		accent = { 255, 230, 90 },
	},
	{
		id = "hat_cheese_wedge",
		name = "Cheese Wedge",
		slot = "hat",
		source = "level",
		unlockLevel = 5,
		shape = "wedge",
		color = { 250, 200, 60 },
		accent = { 225, 160, 40 },
	},
	{
		id = "hat_top",
		name = "Top Hat",
		slot = "hat",
		source = "level",
		unlockLevel = 20,
		shape = "tophat",
		color = { 30, 30, 35 },
		accent = { 200, 40, 60 },
	},
	{
		id = "hat_boss_horns",
		name = "Boss Horns",
		slot = "hat",
		source = "epic",
		shape = "horns",
		color = { 90, 30, 30 },
		accent = { 245, 235, 210 },
	},
	{
		id = "hat_club_cap",
		name = "Club Cap",
		slot = "hat",
		source = "club",
		shape = "cap",
		color = { 0, 160, 160 },
		accent = { 250, 250, 250 },
	},

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
		priceGolden = 120,
	},
	{
		id = "tint_cheddar",
		name = "Cheddar",
		slot = "tint",
		source = "shop",
		color = { 250, 160, 40 },
		priceCheese = 3000,
		priceGolden = 120,
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

	-- (v6) Daily-rotation shop pool (source "shop", rotation = true). GC prices follow
	-- the v4 repricing: hats 150-250, trails 250-400, tints 100-150. Cheese prices are
	-- the repeatable cheese sink for long-time players (M11).
	{
		id = "hat_beanie",
		name = "Cheese Beanie",
		slot = "hat",
		source = "shop",
		rotation = true,
		shape = "beanie",
		color = { 250, 200, 70 },
		accent = { 255, 245, 210 },
		priceGolden = 150,
		priceCheese = 4000,
	},
	{
		id = "hat_bucket",
		name = "Bucket Hat",
		slot = "hat",
		source = "shop",
		rotation = true,
		shape = "bucket",
		color = { 120, 170, 110 },
		priceGolden = 180,
		priceCheese = 5000,
	},
	{
		id = "hat_propeller",
		name = "Propeller Cap",
		slot = "hat",
		source = "shop",
		rotation = true,
		shape = "propeller",
		color = { 70, 130, 230 },
		accent = { 255, 90, 80 },
		priceGolden = 220,
	},
	{
		id = "hat_halo",
		name = "Cheese Halo",
		slot = "hat",
		source = "shop",
		rotation = true,
		shape = "halo",
		color = { 255, 230, 120 },
		priceGolden = 250,
	},
	{
		id = "hat_bandana_red",
		name = "Red Bandana",
		slot = "hat",
		source = "shop",
		rotation = true,
		shape = "bandana",
		color = { 210, 50, 50 },
		accent = { 250, 250, 250 },
		priceCheese = 3000,
	},
	{
		id = "hat_crown_tin",
		name = "Tin Crown",
		slot = "hat",
		source = "shop",
		rotation = true,
		shape = "crown",
		color = { 170, 175, 185 },
		accent = { 90, 160, 220 },
		priceGolden = 200,
		priceCheese = 6000,
	},
	{
		id = "trail_mint_swirl",
		name = "Mint Swirl",
		slot = "trail",
		source = "shop",
		rotation = true,
		color = { 120, 230, 190 },
		color2 = { 230, 255, 245 },
		priceGolden = 250,
		priceCheese = 5000,
	},
	{
		id = "trail_ember_dust",
		name = "Ember Dust",
		slot = "trail",
		source = "shop",
		rotation = true,
		color = { 255, 120, 50 },
		color2 = { 255, 230, 120 },
		priceGolden = 300,
	},
	{
		id = "trail_bluecheese",
		name = "Blue Cheese Veins",
		slot = "trail",
		source = "shop",
		rotation = true,
		color = { 90, 120, 200 },
		color2 = { 235, 235, 220 },
		priceGolden = 350,
		priceCheese = 7000,
	},
	{
		id = "trail_confetti",
		name = "Confetti",
		slot = "trail",
		source = "shop",
		rotation = true,
		color = { 255, 120, 200 },
		color2 = { 120, 220, 255 },
		priceGolden = 400,
	},
	{
		id = "tint_brie",
		name = "Brie",
		slot = "tint",
		source = "shop",
		rotation = true,
		color = { 245, 235, 200 },
		priceGolden = 100,
		priceCheese = 2500,
	},
	{
		id = "tint_gouda",
		name = "Gouda",
		slot = "tint",
		source = "shop",
		rotation = true,
		color = { 230, 160, 40 },
		priceGolden = 120,
		priceCheese = 3000,
	},
	{
		id = "tint_lilac",
		name = "Lilac",
		slot = "tint",
		source = "shop",
		rotation = true,
		color = { 190, 150, 230 },
		priceGolden = 130,
	},
	{
		id = "tint_jade",
		name = "Jade",
		slot = "tint",
		source = "shop",
		rotation = true,
		color = { 60, 170, 120 },
		priceGolden = 150,
		priceCheese = 4000,
	},

	-- (v6) Herd Pass season 1 "Winter Rind" (Config/Pass). Free track: Icy Rind, Frost Crumbs.
	{
		id = "tint_icy_rind",
		name = "Icy Rind",
		slot = "tint",
		source = "season",
		season = 1,
		color = { 170, 220, 255 },
	},
	{
		id = "trail_frost_crumbs",
		name = "Frost Crumbs",
		slot = "trail",
		source = "season",
		season = 1,
		color = { 200, 235, 255 },
		color2 = { 255, 255, 255 },
	},
	-- Premium track (8 cosmetics)
	{
		id = "hat_snow_cap",
		name = "Snow Cap",
		slot = "hat",
		source = "season",
		season = 1,
		shape = "beanie",
		color = { 235, 245, 255 },
		accent = { 120, 180, 240 },
	},
	{
		id = "trail_snowfall",
		name = "Snowfall",
		slot = "trail",
		source = "season",
		season = 1,
		color = { 240, 248, 255 },
		color2 = { 170, 210, 255 },
	},
	{
		id = "tint_frostbite",
		name = "Frostbite",
		slot = "tint",
		source = "season",
		season = 1,
		color = { 110, 180, 230 },
	},
	{
		id = "hat_earmuffs",
		name = "Earmuffs",
		slot = "hat",
		source = "season",
		season = 1,
		shape = "earmuffs",
		color = { 230, 80, 90 },
		accent = { 250, 250, 250 },
	},
	{
		id = "trail_aurora",
		name = "Aurora",
		slot = "trail",
		source = "season",
		season = 1,
		color = { 90, 240, 170 },
		color2 = { 170, 110, 255 },
	},
	{
		id = "tint_aurora",
		name = "Aurora Glow",
		slot = "tint",
		source = "season",
		season = 1,
		color = { 120, 230, 200 },
	},
	{
		id = "hat_ice_crown",
		name = "Ice Crown",
		slot = "hat",
		source = "season",
		season = 1,
		shape = "crown",
		color = { 200, 235, 255 },
		accent = { 120, 200, 255 },
	},
	{
		id = "trail_winter_monarch",
		name = "Winter Monarch",
		slot = "trail",
		source = "season",
		season = 1,
		color = { 150, 210, 255 },
		color2 = { 255, 255, 255 },
	},

	-- (v6) Robux bundle products (Config/Monetization)
	{
		id = "hat_rookie_bandana",
		name = "Rookie Bandana",
		slot = "hat",
		source = "bundle",
		bundleKey = "starter_pack",
		shape = "bandana",
		color = { 90, 150, 230 },
		accent = { 255, 220, 90 },
	},
	{
		id = "trail_rookie_dust",
		name = "Rookie Dust",
		slot = "trail",
		source = "bundle",
		bundleKey = "starter_pack",
		color = { 210, 190, 150 },
		color2 = { 255, 240, 200 },
	},
	{
		id = "hat_sombrero",
		name = "Sombrero",
		slot = "hat",
		source = "bundle",
		bundleKey = "wardrobe_plus",
		shape = "sombrero",
		color = { 225, 190, 110 },
		accent = { 200, 60, 60 },
	},
	{
		id = "hat_jester",
		name = "Jester Cap",
		slot = "hat",
		source = "bundle",
		bundleKey = "wardrobe_plus",
		shape = "jester",
		color = { 160, 60, 200 },
		accent = { 255, 210, 60 },
	},
	{
		id = "hat_detective",
		name = "Detective Hat",
		slot = "hat",
		source = "bundle",
		bundleKey = "wardrobe_plus",
		shape = "bucket",
		color = { 140, 110, 80 },
		accent = { 60, 45, 35 },
	},
	{
		id = "hat_antlers",
		name = "Antlers",
		slot = "hat",
		source = "bundle",
		bundleKey = "wardrobe_plus",
		shape = "horns",
		color = { 150, 105, 60 },
		accent = { 200, 160, 110 },
	},

	-- (v6) Earned rewards: achievements, Mousepedia, account levels (Config/AccountRewards)
	{
		id = "hat_golden_rind",
		name = "Golden Rind",
		slot = "hat",
		source = "reward",
		shape = "wedge",
		color = { 255, 205, 60 },
		accent = { 255, 240, 170 },
	},
	{
		id = "trail_archivist",
		name = "Archivist",
		slot = "trail",
		source = "reward",
		color = { 180, 140, 90 },
		color2 = { 255, 235, 190 },
	},
	{
		id = "trail_half_century",
		name = "Half Century",
		slot = "trail",
		source = "reward",
		color = { 220, 220, 230 },
		color2 = { 255, 215, 120 },
	},
	{
		id = "hat_laurel",
		name = "Laurel Wreath",
		slot = "hat",
		source = "reward",
		shape = "halo",
		color = { 110, 170, 70 },
		accent = { 250, 220, 90 },
	},
	{
		id = "trail_centennial",
		name = "Centennial Herd",
		slot = "trail",
		source = "reward",
		color = { 255, 200, 60 },
		color2 = { 255, 120, 220 },
	},
}

-- Rendering (Services/CosmeticsService) -------------------------------------

-- Trail tuning. Attachments sit near the feet, left and right of the root, so the
-- ribbon lies flat and reads well from the top-down camera.
C.TRAIL = {
	lifetime = 0.55,
	halfWidth = 0.9, -- studs either side of the root
	height = -2.4, -- studs below the HumanoidRootPart centre
	back = 0.6, -- studs behind the root
	lightEmission = 0.4,
	startTransparency = 0.15,
}

-- Tint tuning (Highlight over the whole character).
C.TINT = {
	fillTransparency = 0.55,
	outlineTransparency = 0.35,
}

export type HatForm = "block" | "ball" | "cyl" | "wedge"

-- One part of a hat. Units are studs for a 1.2-stud head; the origin is the top
-- centre of the head, +Y is up and -Z is the face. `size` is {x, y, z}; a "cyl"
-- stands upright with diameter size[1] and height size[2]. `rot` is degrees
-- (x, y, z) applied in the part's own frame. `accent` uses the def's accent colour.
export type HatPart = {
	form: HatForm,
	size: { number },
	at: { number },
	rot: { number }?,
	accent: boolean?,
}

local function ring(n: number, radius: number, y: number, size: number, alternate: boolean): { HatPart }
	local out: { HatPart } = {}
	for i = 0, n - 1 do
		local a = (i / n) * math.pi * 2
		table.insert(out, {
			form = "ball",
			size = { size, size, size },
			at = { math.cos(a) * radius, y, math.sin(a) * radius },
			accent = alternate and i % 2 == 1,
		})
	end
	return out
end

local function crown(): { HatPart }
	local parts: { HatPart } = { { form = "cyl", size = { 1.1, 0.32, 1.1 }, at = { 0, 0.16, 0 } } }
	for i = 0, 4 do
		local a = (i / 5) * math.pi * 2 - math.pi / 2
		local x, z = math.cos(a) * 0.45, math.sin(a) * 0.45
		table.insert(parts, { form = "block", size = { 0.18, 0.3, 0.18 }, at = { x, 0.45, z } })
		table.insert(
			parts,
			{ form = "ball", size = { 0.16, 0.16, 0.16 }, at = { x, 0.64, z }, accent = true }
		)
	end
	return parts
end

C.HAT_SHAPES = {
	cone = {
		{ form = "cyl", size = { 1.0, 0.4, 1.0 }, at = { 0, 0.2, 0 } },
		{ form = "cyl", size = { 0.72, 0.4, 0.72 }, at = { 0, 0.6, 0 } },
		{ form = "cyl", size = { 0.44, 0.4, 0.44 }, at = { 0, 1.0, 0 } },
		{ form = "ball", size = { 0.32, 0.32, 0.32 }, at = { 0, 1.3, 0 }, accent = true },
	},
	wizard = {
		{ form = "cyl", size = { 1.9, 0.12, 1.9 }, at = { 0, 0.06, 0 } },
		{ form = "cyl", size = { 1.0, 0.5, 1.0 }, at = { 0, 0.35, 0 } },
		{ form = "cyl", size = { 0.7, 0.5, 0.7 }, at = { 0, 0.85, 0 } },
		{ form = "cyl", size = { 0.4, 0.5, 0.4 }, at = { 0, 1.35, 0 } },
		{ form = "ball", size = { 0.26, 0.26, 0.26 }, at = { 0, 1.68, 0 }, accent = true },
	},
	toque = {
		{ form = "cyl", size = { 1.0, 0.55, 1.0 }, at = { 0, 0.27, 0 } },
		{ form = "cyl", size = { 1.03, 0.12, 1.03 }, at = { 0, 0.1, 0 }, accent = true },
		{ form = "ball", size = { 1.35, 0.8, 1.35 }, at = { 0, 0.8, 0 } },
	},
	beret = {
		{ form = "cyl", size = { 1.45, 0.24, 1.45 }, at = { 0.1, 0.1, 0 }, rot = { 0, 0, -8 } },
		{ form = "ball", size = { 0.2, 0.2, 0.2 }, at = { 0, 0.28, 0 }, accent = true },
	},
	helmet = {
		{ form = "ball", size = { 1.7, 1.1, 1.7 }, at = { 0, 0.05, 0 } },
		{ form = "cyl", size = { 1.75, 0.14, 1.75 }, at = { 0, -0.15, 0 }, accent = true },
		{ form = "block", size = { 0.06, 0.3, 0.06 }, at = { 0, 0.62, 0 } },
		{ form = "ball", size = { 0.2, 0.2, 0.2 }, at = { 0, 0.8, 0 }, accent = true },
	},
	crown = crown(),
	plume = {
		{ form = "cyl", size = { 1.12, 0.22, 1.12 }, at = { 0, 0.11, 0 } },
		{
			form = "block",
			size = { 0.12, 1.1, 0.38 },
			at = { 0.3, 0.75, 0.15 },
			rot = { 0, 0, -18 },
			accent = true,
		},
		{ form = "ball", size = { 0.2, 0.2, 0.2 }, at = { 0.3, 0.22, -0.5 }, accent = true },
	},
	viking = {
		{ form = "ball", size = { 1.4, 0.9, 1.4 }, at = { 0, 0.12, 0 } },
		{ form = "cyl", size = { 1.42, 0.14, 1.42 }, at = { 0, -0.1, 0 } },
		{
			form = "cyl",
			size = { 0.24, 0.7, 0.24 },
			at = { 0.72, 0.35, 0 },
			rot = { 0, 0, -50 },
			accent = true,
		},
		{
			form = "cyl",
			size = { 0.24, 0.7, 0.24 },
			at = { -0.72, 0.35, 0 },
			rot = { 0, 0, 50 },
			accent = true,
		},
	},
	tricorn = {
		{ form = "cyl", size = { 1.8, 0.12, 1.8 }, at = { 0, 0.06, 0 } },
		{ form = "block", size = { 1.15, 0.5, 0.95 }, at = { 0, 0.35, 0 } },
		{ form = "ball", size = { 0.26, 0.26, 0.1 }, at = { 0, 0.38, -0.5 }, accent = true },
	},
	flowers = ring(6, 0.56, 0.05, 0.36, true),
	wedge = {
		{ form = "block", size = { 1.0, 0.12, 1.1 }, at = { 0, 0.06, 0 }, accent = true },
		{ form = "wedge", size = { 1.0, 0.6, 1.1 }, at = { 0, 0.42, 0 } },
	},
	tophat = {
		{ form = "cyl", size = { 1.6, 0.1, 1.6 }, at = { 0, 0.05, 0 } },
		{ form = "cyl", size = { 1.0, 1.0, 1.0 }, at = { 0, 0.55, 0 } },
		{ form = "cyl", size = { 1.03, 0.16, 1.03 }, at = { 0, 0.2, 0 }, accent = true },
	},
	horns = {
		{ form = "cyl", size = { 0.3, 0.8, 0.3 }, at = { 0.5, 0.3, 0 }, rot = { 0, 0, -30 } },
		{ form = "cyl", size = { 0.3, 0.8, 0.3 }, at = { -0.5, 0.3, 0 }, rot = { 0, 0, 30 } },
		{ form = "ball", size = { 0.22, 0.22, 0.22 }, at = { 0.7, 0.65, 0 }, accent = true },
		{ form = "ball", size = { 0.22, 0.22, 0.22 }, at = { -0.7, 0.65, 0 }, accent = true },
	},
	-- (v6) shapes for the rotation, season and bundle hats
	beanie = {
		{ form = "ball", size = { 1.3, 0.9, 1.3 }, at = { 0, 0.12, 0 } },
		{ form = "cyl", size = { 1.32, 0.18, 1.32 }, at = { 0, -0.12, 0 }, accent = true },
		{ form = "ball", size = { 0.3, 0.3, 0.3 }, at = { 0, 0.62, 0 }, accent = true },
	},
	bucket = {
		{ form = "cyl", size = { 1.7, 0.1, 1.7 }, at = { 0, 0.05, 0 } },
		{ form = "cyl", size = { 1.15, 0.5, 1.15 }, at = { 0, 0.3, 0 } },
		{ form = "cyl", size = { 1.17, 0.1, 1.17 }, at = { 0, 0.15, 0 }, accent = true },
	},
	propeller = {
		{ form = "ball", size = { 1.28, 0.7, 1.28 }, at = { 0, 0.05, 0 } },
		{ form = "block", size = { 0.06, 0.3, 0.06 }, at = { 0, 0.5, 0 } },
		{ form = "block", size = { 1.0, 0.04, 0.16 }, at = { 0, 0.66, 0 }, accent = true },
	},
	halo = ring(10, 0.62, 0.55, 0.16, false),
	bandana = {
		{ form = "ball", size = { 1.32, 0.6, 1.32 }, at = { 0, 0.0, 0 } },
		{
			form = "block",
			size = { 0.3, 0.3, 0.12 },
			at = { 0.2, 0.0, 0.66 },
			rot = { 0, 0, 30 },
			accent = true,
		},
		{
			form = "block",
			size = { 0.3, 0.3, 0.12 },
			at = { -0.2, 0.0, 0.66 },
			rot = { 0, 0, -30 },
			accent = true,
		},
	},
	earmuffs = {
		{ form = "block", size = { 1.4, 0.1, 0.16 }, at = { 0, 0.12, 0 }, rot = { 0, 0, 0 } },
		{ form = "ball", size = { 0.45, 0.45, 0.45 }, at = { 0.7, -0.15, 0 }, accent = true },
		{ form = "ball", size = { 0.45, 0.45, 0.45 }, at = { -0.7, -0.15, 0 }, accent = true },
	},
	sombrero = {
		{ form = "cyl", size = { 2.3, 0.1, 2.3 }, at = { 0, 0.05, 0 } },
		{ form = "cyl", size = { 0.9, 0.6, 0.9 }, at = { 0, 0.4, 0 } },
		{ form = "cyl", size = { 0.92, 0.12, 0.92 }, at = { 0, 0.18, 0 }, accent = true },
	},
	jester = {
		{ form = "cyl", size = { 1.15, 0.3, 1.15 }, at = { 0, 0.15, 0 } },
		{ form = "cyl", size = { 0.3, 0.8, 0.3 }, at = { 0.45, 0.6, 0 }, rot = { 0, 0, -40 } },
		{ form = "cyl", size = { 0.3, 0.8, 0.3 }, at = { -0.45, 0.6, 0 }, rot = { 0, 0, 40 } },
		{ form = "ball", size = { 0.22, 0.22, 0.22 }, at = { 0.75, 0.9, 0 }, accent = true },
		{ form = "ball", size = { 0.22, 0.22, 0.22 }, at = { -0.75, 0.9, 0 }, accent = true },
	},
	cap = {
		{ form = "ball", size = { 1.28, 0.7, 1.28 }, at = { 0, 0.05, 0 } },
		{ form = "block", size = { 1.0, 0.08, 0.7 }, at = { 0, 0.0, -0.78 } },
		{ form = "ball", size = { 0.14, 0.14, 0.14 }, at = { 0, 0.42, 0 }, accent = true },
	},
} :: { [string]: { HatPart } }

-- Nametag titles and chat tags for paid status (Data/Looks picks them; the server
-- shows the nametag and sets the ChatTag / ChatTagColor player attributes that the
-- client's TextChatService.OnIncomingMessage hook reads). Lower `order` shows first.
export type Badge = { text: string, color: Types.Rgb, order: number }

C.NAME_COLOR = { 255, 255, 255 } :: Types.Rgb
C.VIP_NAME_COLOR = { 255, 205, 60 } :: Types.Rgb -- VIP Herd: gold nametag

C.TITLES = {
	vip = { text = "VIP", color = { 255, 205, 60 }, order = 1 },
	founders = { text = "Founder", color = { 230, 185, 60 }, order = 2 },
	club = { text = "Cheese Club", color = { 0, 190, 180 }, order = 3 },
	herd_keeper = { text = "Herd Keeper", color = { 150, 220, 255 }, order = 4 }, -- Lost Herd Statue discovery
	-- (v5) class mastery (Config/ClassSkins.MASTERY): the played class's level 10 / 20 / 30
	mastery_bronze = { text = "Bronze Herd", color = { 205, 127, 50 }, order = 5 },
	mastery_silver = { text = "Silver Herd", color = { 200, 205, 215 }, order = 5 },
	mastery_gold = { text = "Gold Herd", color = { 255, 200, 40 }, order = 5 },
} :: { [string]: Badge }

-- (v6) Earned titles (achievements, Mousepedia, account levels, Herd Pass). Saved in
-- profile.titles; the player shows ONE with Equip("title", id) (profile.equipped.title).
-- Never sold for Robux.
C.EARNED_TITLES = {
	title_last_herd = { text = "Last Herd", color = { 255, 170, 60 }, order = 6 },
	title_herdmaster = { text = "Herdmaster", color = { 200, 160, 255 }, order = 6 },
	title_champion_slayer = { text = "Champion Slayer", color = { 255, 120, 90 }, order = 6 },
	title_cartographer = { text = "Cartographer", color = { 120, 210, 160 }, order = 6 },
	title_boss_hunter = { text = "Boss Hunter", color = { 255, 90, 90 }, order = 6 },
	title_pressured = { text = "Pressured", color = { 255, 210, 120 }, order = 6 },
	title_squeezed = { text = "Squeezed", color = { 255, 170, 90 }, order = 6 },
	title_crushed = { text = "Crushed", color = { 255, 120, 70 }, order = 6 },
	title_unbreakable = { text = "Unbreakable", color = { 255, 70, 70 }, order = 6 },
	title_collector = { text = "Collector", color = { 170, 220, 255 }, order = 6 },
	title_mouseologist = { text = "Mouseologist", color = { 220, 220, 160 }, order = 6 },
	title_streak_keeper = { text = "Streak Keeper", color = { 255, 150, 60 }, order = 6 },
	title_veteran = { text = "Veteran", color = { 190, 200, 210 }, order = 6 },
	title_elder = { text = "Herd Elder", color = { 230, 200, 140 }, order = 6 },
	title_legend = { text = "Living Legend", color = { 255, 215, 90 }, order = 6 },
	title_centennial = { text = "Centennial", color = { 255, 200, 60 }, order = 6 },
	title_winter_herd = { text = "Winter Herd", color = { 170, 220, 255 }, order = 6 },
	title_star_herd = { text = "Star Herd", color = { 255, 235, 120 }, order = 6 },
	-- (iteration 2) Challenges (Config/Challenges)
	title_bare_trunk = { text = "Bare Trunk", color = { 210, 200, 180 }, order = 6 },
	title_paper_elephant = { text = "Paper Elephant", color = { 240, 240, 240 }, order = 6 },
	title_snatcher = { text = "Snatcher", color = { 255, 150, 90 }, order = 6 },
	title_bounty_breaker = { text = "Bounty Breaker", color = { 255, 110, 110 }, order = 6 },
	title_speed_herd = { text = "Speed Herd", color = { 140, 220, 255 }, order = 6 },
	title_peacekeeper = { text = "Peacekeeper", color = { 170, 240, 190 }, order = 6 },
	title_jeweler = { text = "Jeweler", color = { 200, 160, 255 }, order = 6 },
	title_golden_wheel = { text = "Golden Wheel", color = { 255, 215, 60 }, order = 6 },
	title_wheel_of_legends = { text = "Wheel of Legends", color = { 255, 190, 40 }, order = 6 },
} :: { [string]: Badge }

-- (v6) Nametag name colours: a REPEATABLE cheese sink ("dye:<id>" in the cheese shop,
-- Data/Shop). Every change costs the price again; "dye:default" goes back for free.
export type DyeDef = { id: string, name: string, color: Types.Rgb, price: number }
C.DYE_ORDER = { "cheddar", "mint", "rose", "sky", "lilac", "ember", "snow" }
C.DYES = {
	cheddar = { id = "cheddar", name = "Cheddar", color = { 255, 200, 80 }, price = 1000 },
	mint = { id = "mint", name = "Mint", color = { 140, 240, 190 }, price = 1000 },
	rose = { id = "rose", name = "Rose", color = { 255, 150, 180 }, price = 1000 },
	sky = { id = "sky", name = "Sky", color = { 140, 200, 255 }, price = 1000 },
	lilac = { id = "lilac", name = "Lilac", color = { 200, 165, 255 }, price = 1500 },
	ember = { id = "ember", name = "Ember", color = { 255, 130, 80 }, price = 1500 },
	snow = { id = "snow", name = "Snow", color = { 235, 245, 255 }, price = 1500 },
} :: { [string]: DyeDef }

-- (v6) Emotes (Emote Pack product, profile.emotes). Data only for now: the emote
-- player (a remote + client animation) is not built yet, so Config/Monetization keeps
-- the pack unsellable (FEATURES.emotes = false) until it is. Never sell an emote that
-- can't be played.
export type EmoteDef = { id: string, name: string }
C.EMOTE_ORDER = {
	"emote_stomp_dance",
	"emote_trunk_trumpet",
	"emote_cheese_juggle",
	"emote_belly_flop",
	"emote_mouse_shoo",
	"emote_victory_spray",
}
C.EMOTES = {
	emote_stomp_dance = { id = "emote_stomp_dance", name = "Stomp Dance" },
	emote_trunk_trumpet = { id = "emote_trunk_trumpet", name = "Trunk Trumpet" },
	emote_cheese_juggle = { id = "emote_cheese_juggle", name = "Cheese Juggle" },
	emote_belly_flop = { id = "emote_belly_flop", name = "Belly Flop" },
	emote_mouse_shoo = { id = "emote_mouse_shoo", name = "Mouse Shoo" },
	emote_victory_spray = { id = "emote_victory_spray", name = "Victory Spray" },
} :: { [string]: EmoteDef }

C.CHAT_TAGS = {
	vip = { text = "VIP", color = { 255, 205, 60 }, order = 1 },
	club = { text = "Club", color = { 0, 190, 180 }, order = 2 },
} :: { [string]: Badge }

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

-- (v6) The daily Featured rotation pool, by slot, in list order.
function C.rotationPool(slot: Slot): { string }
	local out = {}
	for _, def in list do
		if def.source == "shop" and def.rotation == true and def.slot == slot then
			table.insert(out, def.id)
		end
	end
	return out
end

-- (v6) Cosmetics of a Robux bundle product, in list order.
function C.forBundle(bundleKey: string): { string }
	local out = {}
	for _, def in list do
		if def.source == "bundle" and def.bundleKey == bundleKey then
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
