--!strict
-- Every Robux item in Trunkfall (Team D). Source: docs/research/monetization.md
-- §4, adapted to systems that exist in this game. docs/MONETIZATION.md is the
-- human-readable catalog and the Creator Dashboard checklist.
--
-- Hard rules (enforced by tests/specs/DataConfig.spec.luau):
--   * NO paid random items: every item grants a fixed, listed result (`random = false`).
--   * Robux never touches Double or Nothing: no item is usable on the vote or loss
--     screen, and cheese multipliers are applied to the *final banked* payout only.
--   * Robux never buys in-run power or upgrade rerolls. Reroll tokens are cheese-only.
--   * Second Wind tokens: max 1 self-revive per stage, 2 token revives per run, and a
--     revive grants no extra rewards (see RULES and Data/RunTokens).
--   * `fallbackPrice` is for offline/Studio display only. The UI MUST fetch the real
--     (regional) price at runtime with MarketplaceService:GetProductInfoAsync.
--
-- TODO(dashboard): every `assetId = 0` is a placeholder. Create the item in Creator
-- Dashboard -> Monetization (Passes / Developer Products / Subscriptions) and paste
-- its id here. Subscriptions use a string id like "EXP-1234567890". Items with
-- assetId 0 are never prompted and never granted.

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
	-- product grants (see Data/Receipts.HANDLERS)
	goldenCheese: number?,
	secondWindTokens: number?,
	boostSeconds: number?,
}

local M = {}

M.RULES = {
	-- Cheese multipliers (additive bonuses; see Data/Boosts.cheeseMult)
	herdLeaderBonus = 0.15, -- whole server while a Herd Leader owner is present, does not stack
	feastBonus = 0.5, -- whole server while a Cheese Feast is active
	feastSeconds = 30 * 60,
	feastMaxStackSeconds = 2 * 60 * 60, -- several feasts extend the timer up to this
	premiumBonus = 0.10, -- Roblox Premium / Plus members
	cheeseRushBonus = 1.0, -- personal 2x cheese
	cheeseRushMaxStackSeconds = 24 * 60 * 60,
	doubleXpMult = 2, -- Fast Learner: account XP only

	-- Second Wind / reroll tokens (Data/RunTokens)
	freeSecondWindsPerRun = 1,
	maxSelfRevivesPerStage = 1, -- free or token
	maxTokenRevivesPerRun = 2,
	tokenReviveBlockedBelowBossHp = 0.10, -- no token revive in the last 10% of a boss
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
		benefit = "Gold nametag, Golden Tusk trail, VIP Crown hat, and a fixed daily VIP bonus of 150 cheese + 5 Golden Cheese.",
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
		benefit = "Unlocks all 7 classes now (all are also earnable with cheese), Founder hat and Founder Gold tint.",
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
		benefit = "1 Second Wind token (self-revive). Max 1 revive per stage, 2 token revives per run; grants no extra rewards; runs that use one are not ranked.",
		random = false,
		secondWindTokens = 1,
	},
	{
		key = "second_wind_3",
		kind = "product",
		assetId = 0, -- TODO(dashboard): Developer Product id
		fallbackPrice = 129,
		name = "Second Wind x3",
		benefit = "3 Second Wind tokens. Same caps as a single token.",
		random = false,
		secondWindTokens = 3,
	},
	{
		key = "cheese_rush",
		kind = "product",
		assetId = 0, -- TODO(dashboard): Developer Product id
		fallbackPrice = 99,
		name = "Cheese Rush",
		benefit = "2x cheese for you for 60 minutes of real time (extends an active Rush, up to 24 h). Applied to banked payouts only.",
		random = false,
		boostSeconds = 60 * 60,
	},
	{
		key = "cheese_feast",
		kind = "product",
		assetId = 0, -- TODO(dashboard): Developer Product id
		fallbackPrice = 149,
		name = "Cheese Feast",
		benefit = "+50% cheese for EVERYONE in the server for 30 minutes, with a thank-you shout-out to the buyer.",
		random = false,
		boostSeconds = 30 * 60,
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
		benefit = "Daily: 40 Golden Cheese + 1 Second Wind on login claim. Monthly: one exclusive cosmetic you keep forever. 10% off the cosmetic shop. Club chat tag. No combat stats.",
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
