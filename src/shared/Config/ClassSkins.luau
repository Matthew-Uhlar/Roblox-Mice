--!strict
-- Class skins and mastery (GDD-v2 §5, team R3). Pure data.
--
-- A skin is a colour set plus one accessory id for R4's Visuals/HeroDecor:
--   colors.body    main colour (sash, hat body, held-weapon prop)
--   colors.accent  secondary colour (trim, stripes)
--   colors.trim    small details (buckles, gems, eyes of the hat)
--   accessory      an id from ClassSkins.ACCESSORIES (HeroDecor builds it from parts)
-- Skins are cosmetic only: they never change stats or hitboxes.
--
-- Sources:
--   "level"  earned at class level 3, 10, 20 and 30 (always earnable, never sold)
--   "paid"   optional extra skins: a game pass grants a whole set (`passKey`, see
--            Config/Monetization) or one skin is bought with Golden Cheese in the
--            cosmetic shop ("skin:<id>:golden", `priceGolden`). Cosmetic only.
-- nil (no skin chosen) = the class's default look (Config/Classes `color`).
-- Mastery titles (Bronze / Silver / Gold Herd) unlock at class levels 10 / 20 / 30
-- and show on the nameplate (Data/Looks, Services/CosmeticsService).

local Types = require("../Types")

type Rgb = Types.Rgb

export type Source = "level" | "paid"

export type SkinColors = { body: Rgb, accent: Rgb, trim: Rgb }

export type SkinDef = {
	id: string,
	classId: string,
	name: string,
	source: Source,
	unlockLevel: number?, -- "level" skins
	passKey: string?, -- "paid" skins: the pass that grants the set
	priceGolden: number?, -- "paid" skins: Golden Cheese price for this one skin
	colors: SkinColors,
	accessory: string,
	description: string,
}

export type AccessoryDef = {
	id: string,
	name: string,
	attach: "head" | "back" | "face" | "aura" | "neck",
	description: string, -- what HeroDecor should build
}

export type MasteryTier = "bronze" | "silver" | "gold"
export type MasteryDef = {
	tier: MasteryTier,
	level: number,
	title: string,
	color: Rgb,
	badgeId: number, -- TODO(dashboard): Roblox badge id, 0 = not created (never awarded)
}

local S = {}

S.UNLOCK_LEVELS = table.freeze({ 3, 10, 20, 30 })
S.DEFAULT_ID = "default" -- what the client sends to go back to the default look

S.MASTERY = {
	{ tier = "bronze", level = 10, title = "Bronze Herd", color = { 205, 127, 50 }, badgeId = 0 },
	{ tier = "silver", level = 20, title = "Silver Herd", color = { 200, 205, 215 }, badgeId = 0 },
	{ tier = "gold", level = 30, title = "Gold Herd", color = { 255, 200, 40 }, badgeId = 0 },
} :: { MasteryDef }

S.ACCESSORIES = {
	war_paint = {
		id = "war_paint",
		name = "War Paint",
		attach = "face",
		description = "Two bold stripes across each cheek.",
	},
	iron_helm = {
		id = "iron_helm",
		name = "Iron Helm",
		attach = "head",
		description = "Rounded helm with a nose guard.",
	},
	gladiator_crest = {
		id = "gladiator_crest",
		name = "Gladiator Crest",
		attach = "head",
		description = "Helm with a tall brush crest.",
	},
	mammoth_crown = {
		id = "mammoth_crown",
		name = "Mammoth Crown",
		attach = "head",
		description = "Fur-lined crown with two curled tusks.",
	},
	rain_cloud = {
		id = "rain_cloud",
		name = "Rain Cloud",
		attach = "head",
		description = "A small cloud of balls floating above the head.",
	},
	coral_crown = {
		id = "coral_crown",
		name = "Coral Crown",
		attach = "head",
		description = "Branching coral spikes in a ring.",
	},
	wave_cape = {
		id = "wave_cape",
		name = "Wave Cape",
		attach = "back",
		description = "A cape shaped like a curling wave.",
	},
	trident_halo = {
		id = "trident_halo",
		name = "Trident Halo",
		attach = "aura",
		description = "A floating ring with three prongs.",
	},
	leaf_cap = {
		id = "leaf_cap",
		name = "Leaf Cap",
		attach = "head",
		description = "A cap made of overlapping leaves.",
	},
	moon_hood = {
		id = "moon_hood",
		name = "Moon Hood",
		attach = "head",
		description = "A hood with a crescent moon badge.",
	},
	antler_circlet = {
		id = "antler_circlet",
		name = "Antler Circlet",
		attach = "head",
		description = "A thin band with two branching antlers.",
	},
	blossom_crown = {
		id = "blossom_crown",
		name = "Blossom Crown",
		attach = "head",
		description = "A ring of five flowers.",
	},
	feather_hat = {
		id = "feather_hat",
		name = "Musketeer Hat",
		attach = "head",
		description = "Wide-brim hat with a long feather.",
	},
	masquerade_mask = {
		id = "masquerade_mask",
		name = "Masquerade Mask",
		attach = "face",
		description = "An eye mask with pointed wings.",
	},
	duelist_cape = {
		id = "duelist_cape",
		name = "Duelist Cape",
		attach = "back",
		description = "A short shoulder cape.",
	},
	laurel_wreath = {
		id = "laurel_wreath",
		name = "Laurel Wreath",
		attach = "head",
		description = "A ring of leaves around the head.",
	},
	bandana = {
		id = "bandana",
		name = "Bandana",
		attach = "head",
		description = "A knotted cloth head wrap.",
	},
	tall_toque = {
		id = "tall_toque",
		name = "Tall Toque",
		attach = "head",
		description = "A very tall pleated chef hat.",
	},
	iron_apron = {
		id = "iron_apron",
		name = "Iron Apron",
		attach = "neck",
		description = "A plated apron hanging from the neck.",
	},
	star_toque = {
		id = "star_toque",
		name = "Star Toque",
		attach = "head",
		description = "A chef hat with a star on the front.",
	},
	circus_hat = {
		id = "circus_hat",
		name = "Circus Hat",
		attach = "head",
		description = "A small striped cone with a pompom.",
	},
	aviator_goggles = {
		id = "aviator_goggles",
		name = "Aviator Goggles",
		attach = "face",
		description = "Round goggles on a strap.",
	},
	storm_wings = {
		id = "storm_wings",
		name = "Storm Wings",
		attach = "back",
		description = "Two jagged wing shapes.",
	},
	cloud_crown = {
		id = "cloud_crown",
		name = "Cloud Crown",
		attach = "aura",
		description = "A ring of small clouds over the head.",
	},
	soda_cap = {
		id = "soda_cap",
		name = "Bottle Cap",
		attach = "head",
		description = "A giant crimped bottle cap.",
	},
	lab_goggles = {
		id = "lab_goggles",
		name = "Lab Goggles",
		attach = "face",
		description = "Square safety goggles.",
	},
	gas_mask = {
		id = "gas_mask",
		name = "Gas Mask",
		attach = "face",
		description = "A snout mask with two filters.",
	},
	flask_halo = {
		id = "flask_halo",
		name = "Flask Halo",
		attach = "aura",
		description = "Three small flasks circling the head.",
	},
	gilded_regalia = {
		id = "gilded_regalia",
		name = "Gilded Regalia",
		attach = "neck",
		description = "A gold collar with a gem (paid Gilded set).",
	},
	neon_visor = {
		id = "neon_visor",
		name = "Neon Visor",
		attach = "face",
		description = "A glowing Neon visor band (paid Neon set).",
	},
	-- (iteration 6, team Builder) Tinkerphant
	work_cap = {
		id = "work_cap",
		name = "Work Cap",
		attach = "head",
		description = "A short-brimmed work cap with a pencil tucked in.",
	},
	welding_mask = {
		id = "welding_mask",
		name = "Welding Mask",
		attach = "face",
		description = "A flip-up welding mask with a tinted window.",
	},
	gear_crown = {
		id = "gear_crown",
		name = "Gear Crown",
		attach = "aura",
		description = "Three brass cogs turning above the head.",
	},
	golden_hardhat = {
		id = "golden_hardhat",
		name = "Golden Hard Hat",
		attach = "head",
		description = "A gleaming hard hat with a lamp.",
	},
	-- (iteration 7, team Classes) Ele Vation
	scout_beret = {
		id = "scout_beret",
		name = "Scout Beret",
		attach = "head",
		description = "A tilted beret with a small badge.",
	},
	ghillie_hood = {
		id = "ghillie_hood",
		name = "Ghillie Hood",
		attach = "head",
		description = "A shaggy hood of leaves and grass strips.",
	},
	scope_monocle = {
		id = "scope_monocle",
		name = "Scope Monocle",
		attach = "face",
		description = "A brass rifle-scope monocle over one eye with a glowing lens.",
	},
	eagle_crest = {
		id = "eagle_crest",
		name = "Eagle Crest",
		attach = "aura",
		description = "Golden eagle wings spread above the head.",
	},
	-- (iteration 7, team Classes) Elephaid
	nurse_cap = {
		id = "nurse_cap",
		name = "Nurse Cap",
		attach = "head",
		description = "A folded white cap with a red cross.",
	},
	herb_satchel = {
		id = "herb_satchel",
		name = "Herb Satchel",
		attach = "back",
		description = "A leather satchel bursting with green herbs.",
	},
	stetho_scarf = {
		id = "stetho_scarf",
		name = "Stethoscope Scarf",
		attach = "neck",
		description = "A soft scarf with a stethoscope draped over it.",
	},
	angel_halo = {
		id = "angel_halo",
		name = "Angel Halo",
		attach = "aura",
		description = "A glowing golden halo.",
	},
	-- (iteration 7, team Classes) Trunkillery
	field_cap = {
		id = "field_cap",
		name = "Field Cap",
		attach = "head",
		description = "A boxy artillery field cap with a peak.",
	},
	shell_bandolier = {
		id = "shell_bandolier",
		name = "Shell Bandolier",
		attach = "neck",
		description = "A sash of coconut shells across the chest.",
	},
	iron_visor = {
		id = "iron_visor",
		name = "Iron Visor",
		attach = "face",
		description = "A riveted iron visor with a narrow slit.",
	},
	cannon_crown = {
		id = "cannon_crown",
		name = "Cannon Crown",
		attach = "head",
		description = "A crown ringed with tiny brass cannons.",
	},
} :: { [string]: AccessoryDef }

local function c(r: number, g: number, b: number): Rgb
	return { r, g, b }
end

-- Earned skins: { name, accessory, body, accent, trim } for levels 3 / 10 / 20 / 30.
local EARNED: { [string]: { { any } } } = {
	elephante = {
		{ "Field Grey", "war_paint", c(120, 120, 130), c(200, 60, 50), c(240, 240, 240) },
		{ "Ironclad", "iron_helm", c(90, 95, 105), c(170, 175, 185), c(60, 60, 70) },
		{ "Gladiator", "gladiator_crest", c(150, 40, 40), c(220, 170, 60), c(250, 230, 200) },
		{ "Mammoth King", "mammoth_crown", c(110, 70, 40), c(240, 225, 200), c(255, 200, 40) },
	},
	ele_fonte = {
		{ "Rain Cloud", "rain_cloud", c(150, 170, 200), c(240, 245, 255), c(80, 120, 200) },
		{ "Coral Reef", "coral_crown", c(255, 120, 110), c(60, 200, 200), c(255, 230, 180) },
		{ "Tsunami", "wave_cape", c(20, 80, 170), c(230, 250, 255), c(40, 180, 220) },
		{ "Ocean Sovereign", "trident_halo", c(10, 50, 110), c(255, 200, 60), c(120, 240, 255) },
	},
	ellie_fawn = {
		{ "Autumn", "leaf_cap", c(200, 110, 40), c(240, 190, 60), c(120, 70, 30) },
		{ "Moonlit", "moon_hood", c(60, 70, 120), c(220, 225, 255), c(150, 160, 220) },
		{ "Thornwarden", "antler_circlet", c(70, 100, 50), c(150, 100, 60), c(200, 230, 150) },
		{ "Elder Grove", "blossom_crown", c(60, 140, 80), c(255, 180, 210), c(255, 240, 150) },
	},
	le_fante = {
		{ "Musketeer", "feather_hat", c(40, 60, 140), c(230, 200, 80), c(240, 240, 240) },
		{ "Masquerade", "masquerade_mask", c(30, 30, 40), c(200, 40, 120), c(230, 200, 90) },
		{ "Crimson Duelist", "duelist_cape", c(170, 20, 40), c(30, 20, 20), c(230, 210, 160) },
		{ "Grand Maitre", "laurel_wreath", c(250, 250, 245), c(230, 190, 60), c(120, 40, 140) },
	},
	filet = {
		{ "Line Cook", "bandana", c(230, 230, 230), c(200, 50, 50), c(60, 60, 60) },
		{ "Pastry Chef", "tall_toque", c(255, 220, 230), c(250, 250, 250), c(200, 120, 160) },
		{ "Iron Chef", "iron_apron", c(70, 70, 80), c(190, 190, 200), c(230, 90, 40) },
		{ "Michelin Star", "star_toque", c(250, 250, 250), c(200, 30, 40), c(255, 205, 60) },
	},
	jumbo = {
		{ "Circus Star", "circus_hat", c(230, 60, 80), c(250, 250, 250), c(60, 120, 230) },
		{ "Aviator", "aviator_goggles", c(110, 80, 50), c(60, 90, 60), c(200, 170, 120) },
		{ "Storm Rider", "storm_wings", c(70, 80, 110), c(255, 240, 100), c(180, 200, 230) },
		{ "Sky Emperor", "cloud_crown", c(250, 250, 255), c(150, 200, 255), c(255, 205, 60) },
	},
	fizzante = {
		{ "Lemon Lime", "soda_cap", c(200, 240, 60), c(250, 250, 120), c(60, 160, 60) },
		{ "Root Beer", "lab_goggles", c(110, 60, 30), c(240, 220, 190), c(180, 120, 60) },
		{ "Toxic Fizz", "gas_mask", c(120, 230, 50), c(60, 40, 80), c(200, 255, 120) },
		{ "Grand Alchemist", "flask_halo", c(80, 30, 120), c(255, 200, 60), c(120, 255, 230) },
	},
	-- (iteration 6, team Builder) default look = Config/Classes color; these are earned
	tinkerphant = {
		{ "Apprentice", "work_cap", c(230, 180, 60), c(70, 90, 140), c(200, 200, 210) },
		{ "Welder", "welding_mask", c(60, 70, 80), c(255, 140, 40), c(170, 220, 255) },
		{ "Clockwork", "gear_crown", c(150, 100, 50), c(220, 190, 110), c(90, 60, 30) },
		{ "Master Builder", "golden_hardhat", c(250, 210, 70), c(60, 60, 70), c(255, 255, 255) },
	},
	-- (iteration 7, team Classes) earned only (S.NO_PAID)
	ele_vation = {
		{ "Scout", "scout_beret", c(110, 130, 90), c(200, 60, 50), c(230, 220, 180) },
		{ "Ghillie", "ghillie_hood", c(80, 110, 60), c(140, 120, 70), c(190, 210, 120) },
		{ "Longshot", "scope_monocle", c(60, 65, 80), c(200, 160, 80), c(120, 230, 255) },
		{ "Eagle Eye", "eagle_crest", c(245, 240, 225), c(255, 200, 60), c(120, 60, 30) },
	},
	elephaid = {
		{ "Volunteer", "nurse_cap", c(250, 250, 250), c(220, 50, 60), c(200, 220, 255) },
		{ "Herbalist", "herb_satchel", c(120, 170, 100), c(150, 100, 60), c(240, 230, 170) },
		{ "Head Physician", "stetho_scarf", c(170, 210, 230), c(60, 80, 120), c(230, 230, 240) },
		{ "Guardian Angel", "angel_halo", c(255, 245, 230), c(255, 210, 90), c(255, 255, 255) },
	},
	trunkillery = {
		{ "Gunner", "field_cap", c(100, 110, 70), c(160, 120, 60), c(220, 200, 150) },
		{ "Shellshock", "shell_bandolier", c(140, 100, 60), c(80, 60, 40), c(240, 210, 160) },
		{ "Ironside", "iron_visor", c(80, 85, 95), c(150, 155, 165), c(255, 120, 40) },
		{ "Grand Battery", "cannon_crown", c(60, 40, 40), c(220, 170, 60), c(255, 230, 150) },
	},
}

-- Paid sets (cosmetic only). Each pass grants its whole set; every skin can also be
-- bought alone with Golden Cheese.
S.PAID_SETS = {
	{
		id = "gilded",
		name = "Gilded",
		passKey = "skins_gilded",
		accessory = "gilded_regalia",
		priceGolden = 200, -- (v4 repricing; was 450, QC M4)
		colors = { body = c(240, 190, 50), accent = c(255, 240, 180), trim = c(160, 30, 50) },
	},
	{
		id = "neon",
		name = "Neon",
		passKey = "skins_neon",
		accessory = "neon_visor",
		priceGolden = 150, -- (v4 repricing; was 350, QC M4)
		colors = { body = c(30, 30, 45), accent = c(0, 255, 200), trim = c(255, 60, 220) },
	},
}

-- (iteration 6) classes without the paid sets: their earned skins only
S.NO_PAID = table.freeze({ tinkerphant = true, ele_vation = true, elephaid = true, trunkillery = true }) :: {
	[string]: boolean,
}

local CLASS_ORDER = {
	"elephante",
	"ele_fonte",
	"ellie_fawn",
	"le_fante",
	"filet",
	"jumbo",
	"fizzante",
	"tinkerphant",
	"ele_vation", -- (iteration 7, team Classes)
	"elephaid",
	"trunkillery",
}
local CLASS_NAMES: { [string]: string } = {
	elephante = "Elephante",
	ele_fonte = "Ele Fonte",
	ellie_fawn = "Ellie Fawn",
	le_fante = "Le F'ante",
	filet = "Filet",
	jumbo = "Jumbo",
	fizzante = "Fizzante",
	tinkerphant = "Tinkerphant",
	ele_vation = "Ele Vation", -- (iteration 7, team Classes)
	elephaid = "Elephaid",
	trunkillery = "Trunktillery", -- display name (Classes.luau)
}

local list: { SkinDef } = {}
local byId: { [string]: SkinDef } = {}
local byClass: { [string]: { SkinDef } } = {}

local function slug(name: string): string
	local s = string.gsub(string.lower(name), "[^%w]+", "_")
	s = string.gsub(s, "^_+", "")
	s = string.gsub(s, "_+$", "")
	return s
end

for _, classId in CLASS_ORDER do
	local mine: { SkinDef } = {}
	for i, e in EARNED[classId] or {} do
		local name = e[1] :: string
		local def: SkinDef = {
			id = classId .. "_" .. slug(name),
			classId = classId,
			name = name,
			source = "level",
			unlockLevel = S.UNLOCK_LEVELS[i],
			colors = { body = e[3] :: Rgb, accent = e[4] :: Rgb, trim = e[5] :: Rgb },
			accessory = e[2] :: string,
			description = string.format("Reach %s level %d.", CLASS_NAMES[classId], S.UNLOCK_LEVELS[i]),
		}
		table.insert(mine, def)
	end
	for _, set in S.PAID_SETS do
		if S.NO_PAID[classId] then
			continue -- (iteration 6) the Robux skin passes / bundles keep their fixed contents
		end
		local def: SkinDef = {
			id = classId .. "_" .. set.id,
			classId = classId,
			name = set.name .. " " .. CLASS_NAMES[classId],
			source = "paid",
			passKey = set.passKey,
			priceGolden = set.priceGolden,
			colors = set.colors,
			accessory = set.accessory,
			description = "Cosmetic only: no stats.",
		}
		table.insert(mine, def)
	end
	for _, def in mine do
		table.insert(list, def)
		byId[def.id] = def
	end
	byClass[classId] = mine
end

S.LIST = list
S.byId = byId

function S.get(skinId: any): SkinDef?
	if type(skinId) ~= "string" then
		return nil
	end
	return byId[skinId]
end

-- Every skin of a class: the 4 earned ones (level order), then the paid ones.
function S.forClass(classId: string): { SkinDef }
	return byClass[classId] or {}
end

-- Ids of the paid skins a pass grants (its whole set, every class).
function S.forPass(passKey: string): { string }
	local out = {}
	for _, def in list do
		if def.source == "paid" and def.passKey == passKey then
			table.insert(out, def.id)
		end
	end
	return out
end

-- Mastery def for a level (nil below Bronze).
function S.masteryFor(level: number): MasteryDef?
	local best: MasteryDef? = nil
	for _, m in S.MASTERY do
		if level >= m.level then
			best = m
		end
	end
	return best
end

function S.masteryByTier(tier: any): MasteryDef?
	for _, m in S.MASTERY do
		if m.tier == tier then
			return m
		end
	end
	return nil
end

return S
