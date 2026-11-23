--!strict
-- Which animated icon (UI/IconAtlas key) each menu button and shop item uses.
-- Pure data + lookups (no Roblox APIs); tests/specs/ClientIcons.spec.luau
-- checks every menu key and every shop item id of the live configs maps to an
-- icon that exists in the atlas.
--
--   IconMap.menu(menuKey) -> iconKey?
--   IconMap.item(kind, id) -> iconKey?
--       kind: "product" (Config/Monetization key), "cosmetic" (cosmetic slot),
--             "skin" (class skin), "talent" (Config/Talents id), "bundle"
--             (Config/Shop bundle id), "rank" / "buff" / "ultimate"
--             (Config/RunShop ids), "classBuff" (any class id), "swap", "gear" (slot)
--   IconMap.explicit(kind, id) -> iconKey?   the table entry only (no fallbacks)

local IconMap = {}

-- Menu keys, grouped by the UI that owns the button.
IconMap.MENU = {
	-- LobbyUI dock
	["lobby.hero"] = "hero",
	["lobby.bots"] = "bots",
	["lobby.shop"] = "shop",
	["lobby.sound_on"] = "sound_on",
	["lobby.sound_off"] = "sound_off",
	["lobby.settings"] = "settings",
	["lobby.look_suit"] = "look_suit",
	["lobby.look_avatar"] = "look_avatar",
	-- ProgressUI lobby strip
	["strip.herd"] = "herd",
	["strip.gems"] = "gems",
	-- LadderUI
	["ladder.open"] = "ladder",
	["ladder.horn"] = "horn",
	["ladder.fast"] = "boosts",
	-- ShopUI header, tabs (ShopModel.TABS) and cosmetic filters
	["shop.daily"] = "daily",
	["shop.tab.Featured"] = "featured",
	["shop.tab.Cosmetics"] = "cosmetics",
	["shop.tab.Passes"] = "passes",
	["shop.tab.Golden Cheese"] = "golden",
	["shop.tab.Boosts"] = "boosts",
	["shop.tab.Herd Pass"] = "herd_pass",
	["shop.tab.Cheese Shop"] = "cheese_shop",
	["shop.filter.All"] = "filter_all",
	["shop.filter.Hats"] = "hats",
	["shop.filter.Trails"] = "trails",
	["shop.filter.Tints"] = "tints",
	["shop.filter.Skins"] = "skins",
	["shop.filter.Owned"] = "owned",
	-- ProgressUI tabs
	["progress.tab.Contracts"] = "contracts",
	["progress.tab.Herd Pass"] = "herd_pass",
	["progress.tab.Challenges"] = "challenges",
	["progress.tab.Mousepedia"] = "mousepedia",
	["progress.tab.Levels"] = "levels",
	["progress.tab.Boards"] = "boards",
	-- HeroUI tabs
	["hero.tab.Level & Perks"] = "perks",
	["hero.tab.Prestige & Ascension"] = "prestige",
	["hero.tab.Abilities"] = "abilities",
	["hero.tab.Skins"] = "skins",
	-- RunShopUI (V menu tabs, the phone 🛠 button)
	["run.tab.Ranks"] = "ranks",
	["run.tab.Levels"] = "levels",
	["run.tab.What's left"] = "whats_left",
	["run.tools"] = "tools",
	-- SettingsUI rows
	["settings.fx"] = "fx",
	["settings.decor"] = "decor",
} :: { [string]: string }

-- Menu keys each UI must wire (the spec checks they all resolve).
IconMap.MENU_KEYS = {} :: { string }
for k in IconMap.MENU do
	table.insert(IconMap.MENU_KEYS, k)
end
table.sort(IconMap.MENU_KEYS)

local ITEMS: { [string]: { [string]: string } } = {
	product = {
		vip = "vip",
		double_xp = "double_xp",
		herd_leader = "herd_leader",
		founders = "founders",
		wardrobe = "wardrobe",
		wardrobe_plus = "wardrobe_plus",
		skins_gilded = "skins_gilded",
		skins_neon = "skins_neon",
		herd_pass_s1 = "herd_pass",
		golden_xs = "golden_s",
		golden_s = "golden_s",
		golden_m = "golden_m",
		golden_l = "golden_l",
		golden_xl = "golden_l",
		second_wind_1 = "second_wind",
		second_wind_3 = "second_wind",
		cheese_rush = "cheese_rush",
		cheese_feast = "cheese_feast",
		respec_token = "respec",
		starter_pack = "starter_pack",
		skin_bundle = "skins",
		emote_pack = "emotes",
		cheese_club = "cheese_club",
		ad_reward = "daily", -- never listed in the shop (ad-only), mapped anyway
	},
	cosmetic = { hat = "hats", trail = "trails", tint = "tints", skin = "skins" },
	talent = {
		thick_hide = "hide",
		heavy_trunk = "might",
		quick_feet = "stride",
		crumb_magnet = "magnet",
		cheese_nose = "cheese_nose",
		quick_study = "quick_study",
		second_breath = "second_wind",
		lucky_tusk = "lucky_tusk",
	},
	bundle = {
		reroll_3 = "reroll",
		reroll_10 = "reroll",
		secondwind_1 = "second_wind",
		secondwind_3 = "second_wind",
	},
	rank = {
		might = "might",
		hide = "hide",
		plating = "plating",
		mending = "mending",
		frenzy = "frenzy",
		stride = "stride",
		reach = "reach",
		focus = "focus",
		quick_study = "quick_study",
	},
	buff = {
		rush = "rush",
		thick_skin = "thick_skin",
		keen = "keen",
		leech = "leech",
		bloom = "bloom",
		greed = "greed",
		scholar = "scholar",
		bulwark = "bulwark",
		rally = "rally",
	},
	ultimate = { titan = "titan", cataclysm = "cataclysm", overdrive = "overdrive", herdguard = "herdguard" },
	gear = { weapon = "weapon", armor = "armor", trinket = "trinket" },
}
IconMap.ITEMS = ITEMS

-- Kinds whose every id shares one icon.
local WHOLE_KIND: { [string]: string } = { skin = "skins", classBuff = "class_buff", swap = "swap" }

function IconMap.menu(key: string): string?
	return IconMap.MENU[key]
end

function IconMap.explicit(kind: string, id: any): string?
	local whole = WHOLE_KIND[kind]
	if whole then
		return whole
	end
	local t = ITEMS[kind]
	return if t then t[tostring(id)] else nil
end

-- Explicit entry, else a sensible family icon for ids added later.
function IconMap.item(kind: string, id: any): string?
	local hit = IconMap.explicit(kind, id)
	if hit then
		return hit
	end
	local s = string.lower(tostring(id or ""))
	if kind == "product" then
		if string.find(s, "golden", 1, true) then
			return "golden_m"
		elseif string.find(s, "herd_pass", 1, true) then
			return "herd_pass"
		elseif string.find(s, "skin", 1, true) then
			return "skins"
		end
		return "passes"
	elseif kind == "cosmetic" then
		return "cosmetics"
	elseif kind == "buff" then
		return "class_buff"
	elseif kind == "bundle" then
		return if string.find(s, "wind", 1, true) then "second_wind" else "reroll"
	end
	return nil
end

return IconMap
