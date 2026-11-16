--!strict
-- Every Robux item in Trunkfall (Team D). Source: docs/research/monetization.md
-- §4, adapted to systems that exist in this game. docs/MONETIZATION.md is the
-- human-readable catalog and the Creator Dashboard checklist.
--
-- Hard rules (enforced by tests/specs/DataConfig.spec.luau):
--   * NO paid random items: every item grants a fixed, listed result (`random = false`).
--   * Robux never touches Double or Nothing: no item is usable on the vote or loss
--     screen, and cheese multipliers are applied to the *final banked* payout only.
--   * Robux never sells in-run upgrades, in-run stats or upgrade rerolls (reroll tokens
--     are cheese-only). Robux CAN speed up account progression (cheese boosts feed
--     cheese-bought talents; Founders unlocks earnable classes early) and Second Wind
--     tokens are a capped, unranked paid continue. See docs/MONETIZATION.md.
--   * Every perk listed in `benefit` must be delivered in game. Cosmetics, the VIP
--     nametag and titles are drawn by Services/CosmeticsService.
--   * Timed boosts never take Robux for nothing: MonetizationService refuses the prompt
--     when a full boost would pass its cap, and a receipt that still overflows (two
--     purchases in flight) refunds the cut-off time as Golden Cheese.
--   * (v5, GDD-v2 §7) Class progression is never sold: class XP is not Robux-boosted,
--     perks and alternate abilities are earned only, and earned class skins stay
--     earn-only. Robux can buy EXTRA cosmetic class skins (`skins_*` passes grant a
--     set, Config/ClassSkins source = "paid") and a Perk Respec Token (convenience:
--     the same respec always costs cheese). Gear can never be bought.
--   * Second Wind tokens: max 1 self-revive per stage, 2 token revives per run, and a
--     revive grants no extra rewards (see RULES and Data/RunTokens).
--   * `fallbackPrice` is for offline/Studio display only. The UI MUST fetch the real
--     (regional) price at runtime with MarketplaceService:GetProductInfoAsync.
--
-- TODO(dashboard): every `assetId = 0` is a placeholder. Create the item in Creator
-- Dashboard -> Monetization (Passes / Developer Products / Subscriptions) and paste
-- its id here. Subscriptions use a string id like "EXP-1234567890". Items with
-- assetId 0 are never prompted and never granted.
-- An item whose assetId here is 0 uses its id from Config/ProductIds.luau, which
-- `scripts/publish.py products` generates (docs/publishing/SETUP.md). An id typed
-- here wins over the generated one.

export type Kind = "pass" | "product" | "subscription"

export type Item = {
	key: string,
	kind: Kind,
	assetId: number | string, -- TODO(dashboard): 0 = not created yet
	fallbackPrice: number, -- Robux, display fallback only
	name: string,
	benefit: string,
	random: boolean, -- always false (policy); tests assert it
	adOnly: boolean?, -- product granted only through a rewarded video ad
	-- pass perks applied to the profile (idempotent set-state, never increments)
	cosmetics: { string }?,
	unlockAllClasses: boolean?,
	skinSet: string?, -- (v5) pass grants the Config/ClassSkins paid set with this passKey
	-- product grants (see Data/Receipts.HANDLERS)
	goldenCheese: number?,
	secondWindTokens: number?,
	boostSeconds: number?,
	respecTokens: number?, -- (v5) Perk Respec Tokens (Data/ClassProgress.resetPerks)
	-- (v6) bundle products (Data/Receipts "bundle" handler). Fixed contents, never random.
	oneTime: boolean?, -- one per account (profile.entitlements[key]); the prompt refuses a second
	skinPasses: { string }?, -- grants every paid class skin of these skin passes (Config/ClassSkins.forPass)
	emotes: { string }?, -- Config/Cosmetics.EMOTES ids
	covers: { string }?, -- pass keys whose whole content this bundle includes: those passes
	--                      are refused as "owned" after the bundle, and the bundle is refused
	--                      while the player owns one of them (no paying twice)
	dupeGolden: number?, -- Golden Cheese given for each listed item the player already owns
	feature: string?, -- M.FEATURES key that must be true before the item can be prompted
	passSeason: number?, -- (v6) Herd Pass premium game pass for this season (Config/Pass)
}

local ProductIds = require("./ProductIds") :: { [string]: number | string }
local Cosmetics = require("./Cosmetics")

local M = {}

-- (v6) Content switches. An item with `feature = X` is never prompted while
-- FEATURES[X] is false (shown as "coming soon"), even once its id exists.
--   emotes  the emote player (a remote + client animation) is not built yet.
M.FEATURES = {
	emotes = false,
}

M.RULES = {
	-- Cheese multipliers (additive bonuses; see Data/Boosts.cheeseMult)
	herdLeaderBonus = 0.15, -- whole server while a Herd Leader owner is present, does not stack
	feastBonus = 0.5, -- whole server while a Cheese Feast is active
	feastSeconds = 30 * 60,
	feastMaxStackSeconds = 2 * 60 * 60, -- several feasts extend the timer up to this
	premiumBonus = 0.10, -- Roblox Premium / Plus members
	cheeseRushBonus = 1.0, -- personal 2x cheese
	cheeseRushMaxStackSeconds = 24 * 60 * 60,
	-- Golden Cheese refunded per FULL unit of boost time cut off by a cap (pro rata,
	-- rounded up). Priced like the matching Golden Cheese pack (99 R$ ~ 200 GC).
	cheeseRushOverflowGolden = 200, -- per 60 min of Rush
	feastOverflowGolden = 300, -- per 30 min of Feast
	doubleXpMult = 2, -- Fast Learner: account XP only

	-- Second Wind / reroll tokens (Data/RunTokens)
	freeSecondWindsPerRun = 1,
	maxSelfRevivesPerStage = 1, -- free or token
	maxTokenRevivesPerRun = 2,
	tokenReviveBlockedBelowBossHp = 0.10, -- no token revive in the last 10% of a boss
	-- v2 PvP (QC-B V2-M1): no token revive while this many squads (or more) are
	-- still in the run, and no Second Wind purchase prompts for run members
	tokenReviveBlockedFromSquads = 2,
	maxTokenRerollsPerStage = 2,

	-- Rewarded video ads (13+ only, non-random reward through ProcessReceipt)
	adDailyCap = 3,
	adBonusFrac = 0.5, -- +50% of the last run's cheese
	adBonusMin = 25,
	adBonusMax = 500,

	-- Cheese Club subscription
	clubDailyGolden = 40,
	clubDailySecondWinds = 1,
	clubShopDiscount = 0.10, -- cosmetic shop only
	clubMonthlyCosmetics = { "trail_club_swirl", "hat_club_cap", "tint_club_teal" },

	-- VIP daily bonus (fixed contents)
	vipDailyCheese = 150,
	vipDailyGolden = 5,

	purchaseHistoryMax = 200,
}

local PASSES: { Item } = {
	{
		key = "vip",
		kind = "pass",
		assetId = 0, -- TODO(dashboard): Pass id for "VIP Herd"
		fallbackPrice = 399,
		name = "VIP Herd",
		benefit = "Gold nametag with a VIP title, VIP chat tag, Golden Tusk trail, VIP Crown hat, and a fixed daily VIP bonus of 150 cheese + 5 Golden Cheese when you claim your daily reward.",
		random = false,
		cosmetics = { "trail_golden_tusk", "hat_vip_crown" },
	},
	{
		key = "double_xp",
		kind = "pass",
		assetId = 0, -- TODO(dashboard): Pass id for "Fast Learner"
		fallbackPrice = 249,
		name = "Fast Learner",
		benefit = "2x account XP (levels and level cosmetics come faster). No effect on in-run stats.",
		random = false,
	},
	{
		key = "herd_leader",
		kind = "pass",
		assetId = 0, -- TODO(dashboard): Pass id for "Herd Leader"
		fallbackPrice = 349,
		name = "Herd Leader",
		benefit = "While you are in the server, EVERY player earns +15% cheese (does not stack with other Herd Leaders).",
		random = false,
	},
	{
		key = "founders",
		kind = "pass",
		assetId = 0, -- TODO(dashboard): Pass id for "Founders' Stampede" (launch window only, no countdown UI)
		fallbackPrice = 499,
		name = "Founders' Stampede",
		benefit = "Unlocks all 7 classes now (all are also earnable with cheese), Founder's Plume hat, Founder Gold tint and a Founder title on your nametag.",
		random = false,
		unlockAllClasses = true,
		cosmetics = { "hat_founder", "tint_founder_gold" },
	},
	{
		key = "wardrobe",
		kind = "pass",
		assetId = 0, -- TODO(dashboard): Pass id for "Cheese Wardrobe"
		fallbackPrice = 99,
		name = "Cheese Wardrobe",
		benefit = "6 cosmetics: Viking, Pirate and Flower hats; Bubblegum, Lagoon and Lava tints.",
		random = false,
		cosmetics = { "hat_viking", "hat_pirate", "hat_flower", "tint_bubblegum", "tint_lagoon", "tint_lava" },
	},
	{
		key = "skins_gilded",
		kind = "pass",
		assetId = 0, -- TODO(dashboard): Pass id for "Gilded Herd Skins"
		fallbackPrice = 199,
		name = "Gilded Herd Skins",
		benefit = "7 Gilded class skins, one for every class (gold colours and a Gilded Regalia collar). Cosmetic only: no stats. Every skin is also sold alone for Golden Cheese.",
		random = false,
		skinSet = "skins_gilded",
	},
	{
		key = "skins_neon",
		kind = "pass",
		assetId = 0, -- TODO(dashboard): Pass id for "Neon Herd Skins"
		fallbackPrice = 149,
		name = "Neon Herd Skins",
		benefit = "7 Neon class skins, one for every class (dark colours with a glowing Neon Visor). Cosmetic only: no stats. Every skin is also sold alone for Golden Cheese.",
		random = false,
		skinSet = "skins_neon",
	},
	{
		-- (v6) One game pass per Herd Pass season (Config/Pass.SEASONS[n].premiumKey).
		-- A new season adds a new entry here; `scripts/publish.py products` creates it.
		key = "herd_pass_s1",
		kind = "pass",
		assetId = 0, -- generated: Config/ProductIds.herd_pass_s1
		fallbackPrice = 399,
		name = "Herd Pass: Winter Rind",
		benefit = "Premium track of Herd Pass season 1 (Winter Rind): 8 cosmetics (Snow Cap, Snowfall, Frostbite, Earmuffs, Aurora, Aurora Glow, Ice Crown, Winter Monarch) and 600 Golden Cheese over 30 tiers. Tiers you already reached unlock right away, and anything unclaimed is given to you when the season ends. Cosmetics and Golden Cheese only: no stats, no class XP, and tiers can't be bought.",
		random = false,
		passSeason = 1,
	},
}

local PRODUCTS: { Item } = {
	{
		key = "golden_xs",
		kind = "product",
		assetId = 0, -- TODO(dashboard): Developer Product id
		fallbackPrice = 49,
		name = "Golden Cheese x100",
		benefit = "100 Golden Cheese for the cosmetic shop.",
		random = false,
		goldenCheese = 100,
	},
	{
		key = "golden_s",
		kind = "product",
		assetId = 0, -- TODO(dashboard): Developer Product id
		fallbackPrice = 99,
		name = "Golden Cheese x210",
		benefit = "210 Golden Cheese (200 + 5% bonus).",
		random = false,
		goldenCheese = 210,
	},
	{
		key = "golden_m",
		kind = "product",
		assetId = 0, -- TODO(dashboard): Developer Product id
		fallbackPrice = 249,
		name = "Golden Cheese x550",
		benefit = "550 Golden Cheese (500 + 10% bonus).",
		random = false,
		goldenCheese = 550,
	},
	{
		key = "golden_l",
		kind = "product",
		assetId = 0, -- TODO(dashboard): Developer Product id
		fallbackPrice = 499,
		name = "Golden Cheese x1150",
		benefit = "1,150 Golden Cheese (1,000 + 15% bonus).",
		random = false,
		goldenCheese = 1150,
	},
	{
		key = "golden_xl",
		kind = "product",
		assetId = 0, -- TODO(dashboard): Developer Product id
		fallbackPrice = 999,
		name = "Golden Cheese x2400",
		benefit = "2,400 Golden Cheese (2,000 + 20% bonus).",
		random = false,
		goldenCheese = 2400,
	},
	{
		key = "second_wind_1",
		kind = "product",
		assetId = 0, -- TODO(dashboard): Developer Product id
		fallbackPrice = 49,
		name = "Second Wind",
		benefit = "1 Second Wind token (self-revive). Tokens work only once you are the last squad left in the run: never while another squad is still in it, so a token never beats another player. Not usable on Double-or-Nothing stages or in a boss's last 10%. Max 1 revive per stage, 2 token revives per run; grants no extra rewards; runs that use one are not ranked. Can't be bought during a run.",
		random = false,
		secondWindTokens = 1,
	},
	{
		key = "second_wind_3",
		kind = "product",
		assetId = 0, -- TODO(dashboard): Developer Product id
		fallbackPrice = 129,
		name = "Second Wind x3",
		benefit = "3 Second Wind tokens. Same rules as a single token: only usable once your squad is the last one left in the run. Can't be bought during a run.",
		random = false,
		secondWindTokens = 3,
	},
	{
		key = "cheese_rush",
		kind = "product",
		assetId = 0, -- TODO(dashboard): Developer Product id
		fallbackPrice = 99,
		name = "Cheese Rush",
		benefit = "2x cheese for you for 60 minutes of real time (extends an active Rush, up to 24 h). Applied to banked payouts only. Can't be bought when the full hour would pass 24 h; if it still does, the cut-off time is refunded as Golden Cheese (200 per hour).",
		random = false,
		boostSeconds = 60 * 60,
	},
	{
		key = "cheese_feast",
		kind = "product",
		assetId = 0, -- TODO(dashboard): Developer Product id
		fallbackPrice = 149,
		name = "Cheese Feast",
		benefit = "+50% cheese for EVERYONE in the server for 30 minutes, with a thank-you shout-out to the buyer. Feasts stack up to 2 h; can't be bought when the full 30 minutes would pass that, and any cut-off time is refunded as Golden Cheese (300 per 30 min).",
		random = false,
		boostSeconds = 30 * 60,
	},
	{
		key = "respec_token",
		kind = "product",
		assetId = 0, -- TODO(dashboard): Developer Product id for "Perk Respec Token"
		fallbackPrice = 49,
		name = "Perk Respec Token",
		benefit = "1 Perk Respec Token: reset one class's perk tree and get every point back. Convenience only: the same respec always costs cheese, and it never gives perk points, levels or stats.",
		random = false,
		respecTokens = 1,
	},
	{
		key = "starter_pack",
		kind = "product",
		assetId = 0, -- generated: Config/ProductIds.starter_pack
		fallbackPrice = 99,
		name = "Starter Herd Pack",
		benefit = "Once per account: 300 Golden Cheese, the Rookie Bandana hat, the Rookie Dust trail and 1 Perk Respec Token. A cosmetic you already own is replaced by 100 Golden Cheese. Cosmetic and currency only.",
		random = false,
		oneTime = true,
		goldenCheese = 300,
		cosmetics = Cosmetics.forBundle("starter_pack"),
		respecTokens = 1,
		dupeGolden = 100,
	},
	{
		key = "skin_bundle",
		kind = "product",
		assetId = 0, -- generated: Config/ProductIds.skin_bundle
		fallbackPrice = 299,
		name = "Skin Collector Bundle",
		benefit = "All 14 paid class skins: the 7 Gilded and the 7 Neon skins (the Gilded Herd Skins and Neon Herd Skins passes together, for less). A skin you already own is replaced by 40 Golden Cheese. Not sold while you own either skin pass. Cosmetic only: no stats.",
		random = false,
		skinPasses = { "skins_gilded", "skins_neon" },
		covers = { "skins_gilded", "skins_neon" },
		dupeGolden = 40,
	},
	{
		key = "wardrobe_plus",
		kind = "product",
		assetId = 0, -- generated: Config/ProductIds.wardrobe_plus
		fallbackPrice = 199,
		name = "Wardrobe+ Bundle",
		benefit = "10 cosmetics: everything in Cheese Wardrobe (Viking, Pirate and Flower hats; Bubblegum, Lagoon and Lava tints) plus the Sombrero, Jester Cap, Detective Hat and Antlers. Not sold while you own Cheese Wardrobe. A cosmetic you already own is replaced by 40 Golden Cheese.",
		random = false,
		cosmetics = {
			"hat_viking",
			"hat_pirate",
			"hat_flower",
			"tint_bubblegum",
			"tint_lagoon",
			"tint_lava",
			"hat_sombrero",
			"hat_jester",
			"hat_detective",
			"hat_antlers",
		},
		covers = { "wardrobe" },
		dupeGolden = 40,
	},
	{
		key = "emote_pack",
		kind = "product",
		assetId = 0, -- generated: Config/ProductIds.emote_pack
		fallbackPrice = 199,
		name = "Emote Pack",
		benefit = "6 emotes to play in the lobby: Stomp Dance, Trunk Trumpet, Cheese Juggle, Belly Flop, Mouse Shoo and Victory Spray. An emote you already own is replaced by 40 Golden Cheese. Cosmetic only.",
		random = false,
		emotes = table.clone(Cosmetics.EMOTE_ORDER),
		dupeGolden = 40,
		feature = "emotes",
	},
	{
		key = "ad_reward",
		kind = "product",
		assetId = 0, -- TODO(dashboard): Developer Product id used with AdService:CreateAdRewardFromDevProductId
		fallbackPrice = 0,
		name = "Snack Break (rewarded ad)",
		benefit = "Watch an optional ad (13+ only) for +50% of your last run's cheese (min 25, max 500). Max 3 per day. Never random.",
		random = false,
		adOnly = true,
	},
}

local SUBSCRIPTIONS: { Item } = {
	{
		key = "cheese_club",
		kind = "subscription",
		assetId = 0, -- TODO(dashboard): Subscription id string, e.g. "EXP-1234567890"
		fallbackPrice = 249, -- per month, Robux-priced subscription
		name = "Cheese Club",
		benefit = "Daily: 40 Golden Cheese + 1 Second Wind token, granted on login (tokens only work once your squad is the last one left in a run, never against other players). Monthly: one exclusive cosmetic you keep forever. 10% off the cosmetic shop. Cheese Club title on your nametag and a Club chat tag. No combat stats and no PvP advantage.",
		random = false,
	},
}

M.PASSES = PASSES
M.PRODUCTS = PRODUCTS
M.SUBSCRIPTIONS = SUBSCRIPTIONS

M.byKey = {} :: { [string]: Item }
M.ALL = {} :: { Item }
for _, list in { M.PASSES, M.PRODUCTS, M.SUBSCRIPTIONS } do
	for _, item in list do
		local generated = ProductIds[item.key]
		if item.assetId == 0 and generated ~= nil and generated ~= 0 then
			item.assetId = generated
		end
		table.insert(M.ALL, item)
		M.byKey[item.key] = item
	end
end

function M.get(key: string): Item?
	return M.byKey[key]
end

-- True when the item has a real Creator Dashboard id.
function M.isConfigured(item: Item): boolean
	local id = item.assetId
	if type(id) == "number" then
		return id > 0
	end
	return type(id) == "string" and #id > 0 and id ~= "0"
end

-- Pure purchase-prompt rule (QC-B V2-M1): Second Wind tokens are never sold
-- to a player who is in a run (no buying a revive in the middle of a fight).
-- Returns (reason, toast text) when the prompt must be refused, else nil.
function M.promptRefusal(item: Item?, inRun: boolean?): (string?, string?)
	if item and inRun and (item :: any).secondWindTokens ~= nil then
		return "in_run", "Second Wind tokens can't be bought during a run. Visit the shop in the lobby."
	end
	return nil, nil
end

-- (v6) Is the item's feature switched on (FEATURES)? Items without one always are.
function M.featureOn(item: Item?): boolean
	local f = item and item.feature
	return f == nil or (M.FEATURES :: any)[f] == true
end

-- (v6) Bundle products whose `covers` includes this pass key.
function M.bundlesCovering(passKey: string): { string }
	local out = {}
	for _, item in M.ALL do
		if item.covers and table.find(item.covers, passKey) then
			table.insert(out, item.key)
		end
	end
	return out
end

-- (v6) The Herd Pass premium game pass of a season, or nil (Config/Pass uses it).
function M.seasonPassKey(season: number): string?
	for _, item in M.PASSES do
		if item.passSeason == season then
			return item.key
		end
	end
	return nil
end

-- (v6) Pure prompt rule for one-time and covering bundles. `entitlements` is
-- profile.entitlements, `ownsPass(key)` the server's verified pass ownership.
-- Returns (reason, toast) when the prompt must be refused, else nil.
function M.bundleRefusal(
	item: Item?,
	entitlements: { [string]: any }?,
	ownsPass: ((string) -> boolean)?
): (string?, string?)
	if not item then
		return nil, nil
	end
	local ent = entitlements or {}
	if item.oneTime and ent[item.key] then
		return "owned", "You already have the " .. item.name .. "."
	end
	if item.kind == "pass" then
		for _, bundleKey in M.bundlesCovering(item.key) do
			if ent[bundleKey] then
				local b = M.byKey[bundleKey]
				return "owned",
					"You already have everything in " .. item.name .. " from the " .. b.name .. "."
			end
		end
	elseif item.covers and ownsPass then
		for _, passKey in item.covers do
			if ownsPass(passKey) then
				local pass = M.byKey[passKey]
				return "owns_pass",
					"You own "
						.. (if pass then pass.name else passKey)
						.. " already, so the "
						.. item.name
						.. " would give you items twice."
			end
		end
	end
	return nil, nil
end

-- Reverse lookup used by ProcessReceipt / PromptGamePassPurchaseFinished.
function M.keyForAsset(kind: Kind, assetId: number | string): string?
	for _, item in M.ALL do
		if item.kind == kind and M.isConfigured(item) and item.assetId == assetId then
			return item.key
		end
	end
	return nil
end

return M
