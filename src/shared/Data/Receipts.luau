--!strict
-- Developer-product grants (Team D). Pure. MonetizationService.ProcessReceipt calls
-- Receipts.apply inside the session-locked profile, then saves; it returns
-- PurchaseGranted only after that save succeeds.
--
-- Atomicity and idempotency (QC2 Minor 1, M4):
--   * The grant runs FIRST, under pcall, against the live profile with a deep-copy
--     backup. If it throws, every field is restored and the receipt is "rejected"
--     (ProcessReceipt answers NotProcessedYet, Roblox retries later).
--   * Only after a successful, non-empty grant is the PurchaseId recorded, in the
--     same mutation, so grant + record reach the DataStore in ONE UpdateAsync
--     (DataService.save). A grant that would give nothing is rolled back and
--     rejected: we never acknowledge a receipt that granted nothing.
--   * A PurchaseId already in purchaseHistory is a "duplicate" and grants nothing.
-- History is pruned oldest-first to the last RULES.purchaseHistoryMax ids; Roblox
-- retries an unacknowledged receipt within days, so recent ids are always present.

local Types = require("../Types")
local Monetization = require("../Config/Monetization")
local Award = require("./Award")
local Boosts = require("./Boosts")
local Passes = require("./Passes")

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
	boostSeconds: number?, -- boost time actually added
	refundGolden: number?, -- Golden Cheese refunded for time a cap cut off
	feast: boolean?,
	respecTokens: number?, -- (v5)
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
	respec_token = function(profile, _ctx, item)
		-- (v5) convenience only: a respec refunds points the player earned, nothing more.
		local n = item.respecTokens or 1
		local p = profile :: any
		local have = if type(p.respecTokens) == "number" and p.respecTokens == p.respecTokens then p.respecTokens else 0
		p.respecTokens = math.max(0, math.floor(have)) + n
		return { respecTokens = n }
	end,
	cheese_rush = function(profile, ctx, item)
		local R = Monetization.RULES
		local seconds = item.boostSeconds or 3600
		local ext = Boosts.extend(profile.boosts.cheese2xUntil, ctx.now, seconds, R.cheeseRushMaxStackSeconds)
		profile.boosts.cheese2xUntil = ext.untilT
		local result: GrantResult = { boostUntil = ext.untilT, boostSeconds = ext.applied }
		-- The prompt refuses a Rush that would pass the cap, but two purchases can be
		-- in flight at once: refund whatever the cap cut off (disclosed in `benefit`).
		local refund = Boosts.overflowRefund(ext.lost, seconds, R.cheeseRushOverflowGolden)
		if refund > 0 then
			profile.goldenCheese = Award.clampCurrency(profile.goldenCheese + refund)
			result.refundGolden = refund
		end
		return result
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

-- True when a grant result actually gave the player something.
function Receipts.grantsSomething(result: any): boolean
	if type(result) ~= "table" then
		return false
	end
	for _, v in result do
		if v == true or (type(v) == "number" and v == v and v > 0) then
			return true
		end
	end
	return false
end

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

-- Puts every top-level field of `backup` back on `profile` (and drops new ones).
local function restore(profile: Profile, backup: { [any]: any })
	local p = profile :: any
	for k in table.clone(p) do
		if backup[k] == nil then
			p[k] = nil
		end
	end
	for k, v in backup do
		p[k] = v
	end
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
--   "rejected", reason         bad id / unknown product / not a product / the grant
--                              threw or gave nothing: the profile is unchanged
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
	-- Grant first (rolled back on error or an empty grant), then record the id.
	-- Both land in the same in-memory mutation, so one save persists both.
	local backup = deepCopy(profile)
	local ok, result = pcall(handler, profile, ctx, item)
	if not ok then
		restore(profile, backup)
		return "rejected", "grant_failed: " .. tostring(result)
	end
	if not Receipts.grantsSomething(result) then
		restore(profile, backup)
		return "rejected", "empty_grant"
	end
	Receipts.record(profile, purchaseId)
	return "granted", result
end

-- Applies a VERIFIED game pass's profile perks (cosmetics / class unlocks) and
-- records their source so a refunded pass can be revoked (Data/Passes). Idempotent.
-- Returns true if anything changed.
function Receipts.applyPass(profile: Profile, passKey: string): boolean
	return Passes.apply(profile, passKey)
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
