--!strict
-- Developer-product grants (Team D). Pure. MonetizationService.ProcessReceipt calls
-- Receipts.apply inside the session-locked profile, then saves; it returns
-- PurchaseGranted only after that save succeeds.
--
-- Idempotency: the PurchaseId is recorded in the SAME profile mutation as the grant.
-- A PurchaseId already in purchaseHistory is a "duplicate" and grants nothing.
-- History is pruned oldest-first to the last RULES.purchaseHistoryMax ids; Roblox
-- retries an unacknowledged receipt within days, so recent ids are always present.

local Types = require("../Types")
local Monetization = require("../Config/Monetization")
local ShopConfig = require("../Config/Shop")
local Cosmetics = require("../Config/Cosmetics")
local Award = require("./Award")
local Boosts = require("./Boosts")

type Profile = Types.Profile

export type Ctx = {
	now: number, -- unix seconds (os.time on the server)
	day: number, -- UTC day number
}

-- What a grant did, for toasts and server-side effects.
export type GrantResult = {
	cheese: number?,
	goldenCheese: number?,
	secondWindTokens: number?,
	boostUntil: number?,
	feast: boolean?,
}

type Handler = (Profile, Ctx, Monetization.Item) -> GrantResult

local Receipts = {}

local function goldenPack(profile: Profile, _ctx: Ctx, item: Monetization.Item): GrantResult
	local n = item.goldenCheese or 0
	profile.goldenCheese = Award.clampCurrency(profile.goldenCheese + n)
	return { goldenCheese = n }
end

local function secondWinds(profile: Profile, _ctx: Ctx, item: Monetization.Item): GrantResult
	local n = item.secondWindTokens or 0
	profile.secondWindTokens += n -- paid tokens ignore the cheese-shop holding cap
	return { secondWindTokens = n }
end

local HANDLERS: { [string]: Handler } = {
	golden_xs = goldenPack,
	golden_s = goldenPack,
	golden_m = goldenPack,
	golden_l = goldenPack,
	golden_xl = goldenPack,
	second_wind_1 = secondWinds,
	second_wind_3 = secondWinds,
	cheese_rush = function(profile, ctx, item)
		local R = Monetization.RULES
		local untilT = Boosts.extendUntil(
			profile.boosts.cheese2xUntil,
			ctx.now,
			item.boostSeconds or 3600,
			R.cheeseRushMaxStackSeconds
		)
		profile.boosts.cheese2xUntil = untilT
		return { boostUntil = untilT }
	end,
	cheese_feast = function(profile, _ctx, _item)
		-- Stored on the profile so a server crash between save and broadcast can't lose
		-- it: MonetizationService starts pending feasts after the save and on join.
		profile.boosts.feastPending += 1
		return { feast = true }
	end,
	ad_reward = function(profile, ctx, _item)
		local R = Monetization.RULES
		if profile.ads.day ~= ctx.day then
			profile.ads.day = ctx.day
			profile.ads.count = 0
		end
		profile.ads.count += 1
		local amount = R.adBonusMin
		if not profile.lastRun.adClaimed then
			amount =
				math.clamp(math.floor(profile.lastRun.cheese * R.adBonusFrac), R.adBonusMin, R.adBonusMax)
			profile.lastRun.adClaimed = true
		end
		profile.cheese = Award.clampCurrency(profile.cheese + amount)
		return { cheese = amount }
	end,
}
Receipts.HANDLERS = HANDLERS

function Receipts.hasHandler(key: string): boolean
	return HANDLERS[key] ~= nil
end

local function validId(purchaseId: any): boolean
	return type(purchaseId) == "string" and #purchaseId > 0 and #purchaseId <= 128
end

function Receipts.isProcessed(profile: Profile, purchaseId: string): boolean
	return profile.purchaseHistory[purchaseId] == true
end

-- Records a PurchaseId and prunes the oldest ids beyond the cap.
function Receipts.record(profile: Profile, purchaseId: string)
	if profile.purchaseHistory[purchaseId] then
		return
	end
	profile.purchaseHistory[purchaseId] = true
	table.insert(profile.purchaseOrder, purchaseId)
	local max = Monetization.RULES.purchaseHistoryMax
	while #profile.purchaseOrder > max do
		local old = table.remove(profile.purchaseOrder, 1) :: string
		profile.purchaseHistory[old] = nil
	end
end

export type Status = "granted" | "duplicate" | "rejected"

-- Applies a developer-product receipt. Returns:
--   "granted", GrantResult     grant applied + PurchaseId recorded (caller must save)
--   "duplicate", nil           already processed: grant nothing (caller still saves, then acks)
--   "rejected", reason         bad id / unknown product / not a product: nothing changed
function Receipts.apply(profile: Profile, purchaseId: any, productKey: any, ctx: Ctx): (Status, any)
	if not validId(purchaseId) then
		return "rejected", "bad_purchase_id"
	end
	if profile.purchaseHistory[purchaseId] then
		return "duplicate", nil
	end
	if type(productKey) ~= "string" then
		return "rejected", "unknown_product"
	end
	local item = Monetization.get(productKey)
	local handler = HANDLERS[productKey]
	if not item or item.kind ~= "product" or not handler then
		return "rejected", "unknown_product"
	end
	if type(ctx) ~= "table" or type(ctx.now) ~= "number" or type(ctx.day) ~= "number" then
		return "rejected", "bad_ctx"
	end
	-- Record first, grant second, both in the same in-memory mutation (one save).
	Receipts.record(profile, purchaseId)
	local result = handler(profile, ctx, item)
	return "granted", result
end

-- Applies a game pass's profile perks (cosmetics / class unlocks). Idempotent: it
-- only sets states. Returns true if anything changed.
function Receipts.applyPass(profile: Profile, passKey: string): boolean
	local item = Monetization.get(passKey)
	if not item or item.kind ~= "pass" then
		return false
	end
	local changed = false
	for _, id in item.cosmetics or {} do
		if Cosmetics.get(id) and not profile.cosmetics[id] then
			profile.cosmetics[id] = true
			changed = true
		end
	end
	if item.unlockAllClasses then
		for _, id in ShopConfig.classIds() do
			if not profile.unlockedClasses[id] then
				profile.unlockedClasses[id] = true
				changed = true
			end
		end
	end
	return changed
end

-- Cheese Club monthly cosmetic for month index (year * 12 + month - 1). Once per month;
-- kept forever. Returns the cosmetic id granted, or nil.
function Receipts.applyClubMonthly(profile: Profile, monthIndex: number): string?
	if type(monthIndex) ~= "number" or monthIndex ~= monthIndex or monthIndex < 0 then
		return nil
	end
	local mk = tostring(math.floor(monthIndex))
	if profile.club.monthsGranted[mk] then
		return nil
	end
	local list = Monetization.RULES.clubMonthlyCosmetics
	-- First the next cosmetic in rotation the member doesn't own yet.
	local start = math.floor(monthIndex) % #list
	local chosen: string? = nil
	for i = 0, #list - 1 do
		local id = list[((start + i) % #list) + 1]
		if not profile.cosmetics[id] then
			chosen = id
			break
		end
	end
	profile.club.monthsGranted[mk] = true
	if chosen then
		profile.cosmetics[chosen] = true
	else
		-- Owns them all already: fixed fallback instead of a duplicate.
		profile.goldenCheese = Award.clampCurrency(profile.goldenCheese + 300)
	end
	return chosen
end

return Receipts
