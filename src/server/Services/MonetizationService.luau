--!strict
-- MonetizationService (Team D): the ONLY place Robux purchases are handled.
--
-- ProcessReceipt (docs/research/monetization.md §5, all 8 rules):
--   1. Exactly one ProcessReceipt callback, assigned here, in one server script.
--   2. Player not in the server -> NotProcessedYet.
--   3. Waits for the session-locked profile; not loaded / read-only -> NotProcessedYet.
--   4. Idempotent by PurchaseId: already in purchaseHistory -> make sure it is saved,
--      then PurchaseGranted without granting again.
--   5. Otherwise record the PurchaseId and grant in the SAME profile mutation (Data/Receipts).
--   6. PurchaseGranted only after DataService.save confirms the write; any error -> NotProcessedYet.
--   7. All DataStore work is pcall-wrapped with bounded waits (DataService).
--   8. Never grants from the client or from PromptProductPurchaseFinished (UI only).
--   9. Never acks a receipt that granted nothing: Receipts.apply rolls back and rejects
--      an empty or failed grant, and timed boosts refund capped time (QC2 M4).
--
-- Game passes (QC2 M5): PromptGamePassPurchaseFinished is treated as a UI hint only.
-- Nothing is granted until MarketplaceService:UserOwnsGamePassAsync confirms the pass.
-- Saved pass perks record their source (Data/Passes); on join, a pass that Roblox
-- says is no longer owned (refund / chargeback) has its saved perks removed.
-- Prices shown in UI must come from MarketplaceService:GetProductInfoAsync at runtime
-- (regional pricing); Config/Monetization fallbackPrice is only a fallback.
-- Never auto-prompt: prompt() runs only on an explicit client request (Net.C2S.PromptProduct).
--
-- Public API:
--   MonetizationService.init()
--   MonetizationService.hasPass(player, key) -> boolean
--   MonetizationService.cheeseMult(player) -> number      -- apply to the FINAL banked payout only
--   MonetizationService.xpMult(player) -> number          -- account XP (Fast Learner pass)
--   MonetizationService.extraRerolls(player) -> number    -- per-stage token-reroll allowance
--   MonetizationService.prompt(player, key) -> (boolean, reason?)  -- also "refresh" and "roblox_plus"
--   MonetizationService.onEntitlementsChanged(fn: (Player) -> ())  -- passes / Club changed
--   MonetizationService.isClubMember(player) -> boolean
--   MonetizationService.refreshPasses(player, force: boolean?)
--   MonetizationService.refreshClub(player, force: boolean?)  -- unforced calls: 45 s cooldown
--   MonetizationService.feastSecondsLeft() -> number
--   MonetizationService.paidRandomItemsRestricted(player) -> boolean  -- PolicyService (future use)
--   MonetizationService.showRewardedAd(player) -> boolean -- TODO stub, see below

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Config = Shared:WaitForChild("Config")
local DataFolder = Shared:WaitForChild("Data")
local Monetization = require(Config:WaitForChild("Monetization")) :: any
local Receipts = require(DataFolder:WaitForChild("Receipts")) :: any
local Boosts = require(DataFolder:WaitForChild("Boosts")) :: any
local Daily = require(DataFolder:WaitForChild("Daily")) :: any
local Passes = require(DataFolder:WaitForChild("Passes")) :: any

local DataService = require(script.Parent:WaitForChild("DataService")) :: any
local Guard = require(script.Parent:WaitForChild("Guard")) :: any

local MonetizationService = {}

local R = Monetization.RULES
local MAX_CURRENCY = 1_000_000_000 -- Data/Award.MAX_CURRENCY
local isRealPlayer = DataService.isRealPlayer -- false for bots (ids <= 0, no Player object)

-- TODO(ads): flip to true once the experience is ads-eligible (Minimal/Mild maturity,
-- good standing) and the ad_reward product id is set. Rewarded ads only reach 13+.
MonetizationService.ADS_ENABLED = false
MonetizationService.PROMPT_COOLDOWN = 1.5 -- real purchase prompts only
MonetizationService.REFRESH_COOLDOWN = 30 -- PromptProduct("refresh") (shop opened), its own bucket
MonetizationService.PASS_RECHECK_COOLDOWN = 10
MonetizationService.CLUB_POLL_INTERVAL = 600
MonetizationService.CLUB_REFRESH_COOLDOWN = 45 -- unforced refreshClub (shop "refresh" spam, QC2 Minor 2)
-- Seconds after a purchase at which ownership is re-asked before giving up (M5).
MonetizationService.PASS_VERIFY_DELAYS = { 0, 2, 2, 6, 20 }
MonetizationService.RECEIPT_PROFILE_TIMEOUT = 20

type PolicyInfo = { paidRandomRestricted: boolean }

local owned: { [Player]: { [string]: boolean } } = {}
local lastPassCheck: { [Player]: number } = {}
local passStatus: { [Player]: { [string]: string } } = {} -- "owned" | "not_owned" from Roblox
local verifying: { [Player]: { [string]: boolean } } = {}
local lastClubCheck: { [Player]: number } = {}
local entitlementCallbacks: { (Player) -> () } = {}
local feastBusy = false
local premium: { [Player]: boolean } = {}
local club: { [Player]: boolean } = {}
local policy: { [Player]: PolicyInfo } = {}
local lastPrompt: { [Player]: number } = {}
local lastRefresh: { [Player]: number } = {}
local receiptBusy: { [number]: boolean } = {}
local feastUntil = 0
local initialized = false
local toastRemote: any = nil

local function toast(player: Player, text: string, kind: string?)
	if toastRemote then
		pcall(function()
			toastRemote:FireClient(player, text, kind or "info")
		end)
	end
end

local function toastAll(text: string, kind: string?)
	if toastRemote then
		pcall(function()
			toastRemote:FireAllClients(text, kind or "info")
		end)
	end
end

local function pushAll()
	for _, p in Players:GetPlayers() do
		DataService.push(p)
	end
end

local function monthIndex(): number
	local t = os.date("!*t") :: any
	return t.year * 12 + (t.month - 1)
end

-- Passes ---------------------------------------------------------------------

function MonetizationService.hasPass(player: Player, key: string): boolean
	if not isRealPlayer(player) then
		return false
	end
	local set = owned[player]
	return set ~= nil and set[key] == true
end

-- Called whenever a player's passes or Club status change (CosmeticsService redraws
-- the nametag, hat, trail and chat tag).
function MonetizationService.onEntitlementsChanged(fn: (Player) -> ())
	table.insert(entitlementCallbacks, fn)
end

local function notifyEntitlements(player: Player)
	for _, fn in entitlementCallbacks do
		task.spawn(function()
			local ok, err = pcall(fn, player)
			if not ok then
				warn("[Monetization] entitlement callback errored: " .. tostring(err))
			end
		end)
	end
end

-- Saves a VERIFIED pass's perks on the profile, with their source recorded.
local function applyPassPerks(player: Player, key: string)
	local changed = false
	DataService.update(player, function(profile)
		changed = Receipts.applyPass(profile, key)
	end)
	if changed then
		task.spawn(DataService.save, player)
		DataService.push(player)
	end
end

-- Removes the saved perks of a pass Roblox says this player no longer owns.
local function revokePassPerks(player: Player, key: string)
	local removed: any = nil
	DataService.update(player, function(profile)
		removed = Passes.revoke(profile, key)
	end)
	if removed and (#removed.cosmetics > 0 or #removed.classes > 0) then
		local item = Monetization.get(key)
		warn(
			string.format(
				"[Monetization] %d no longer owns %s: removed %d cosmetics, %d classes",
				player.UserId,
				key,
				#removed.cosmetics,
				#removed.classes
			)
		)
		toast(
			player,
			(if item then item.name else key) .. " is no longer on your account, so its items were removed.",
			"info"
		)
		task.spawn(DataService.save, player)
		DataService.push(player)
		notifyEntitlements(player)
	end
end

-- Only call after UserOwnsGamePassAsync returned true.
local function setOwned(player: Player, key: string)
	local set = owned[player]
	if not set then
		set = {}
		owned[player] = set
	end
	local was = set[key]
	set[key] = true
	local st = passStatus[player]
	if st then
		st[key] = "owned"
	end
	if not was then
		task.spawn(function()
			if DataService.waitFor(player) then
				applyPassPerks(player, key)
			end
			pushAll() -- Herd Leader changes everyone's multiplier
			notifyEntitlements(player)
		end)
	end
end

-- (ok, owns): ok = false when the ownership API errored (unknown, change nothing).
local function ownsPass(player: Player, item: any): (boolean, boolean)
	local ok, has = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, item.assetId)
	end)
	if not ok then
		return false, false
	end
	return true, has == true
end

-- After PromptGamePassPurchaseFinished(purchased = true): confirm with Roblox before
-- granting anything (that signal is a UI hint, not proof of purchase).
local function verifyPurchase(player: Player, key: string)
	local item = Monetization.get(key)
	if not item or MonetizationService.hasPass(player, key) then
		return
	end
	local v = verifying[player]
	if not v then
		v = {}
		verifying[player] = v
	end
	if v[key] then
		return
	end
	v[key] = true
	for _, delay in MonetizationService.PASS_VERIFY_DELAYS do
		if delay > 0 then
			task.wait(delay)
		end
		if player.Parent ~= Players then
			break
		end
		local ok, has = ownsPass(player, item)
		if ok and has then
			setOwned(player, key)
			toast(player, "Thank you! " .. item.name .. " is active.", "good")
			v[key] = nil
			return
		end
	end
	v[key] = nil
	if player.Parent == Players then
		toast(
			player,
			"We couldn't confirm "
				.. item.name
				.. " with Roblox yet. It turns on by itself when you reopen the shop or rejoin.",
			"info"
		)
	end
end

-- Checks every configured pass not yet owned this session and remembers Roblox's
-- answer in passStatus. Ownership only upgrades during a session; the join check
-- (onJoin) uses a definite "not_owned" to revoke saved perks.
function MonetizationService.refreshPasses(player: Player, force: boolean?)
	if not isRealPlayer(player) then
		return
	end
	local now = os.clock()
	if
		not force
		and lastPassCheck[player]
		and now - lastPassCheck[player] < MonetizationService.PASS_RECHECK_COOLDOWN
	then
		return
	end
	lastPassCheck[player] = now
	local st = passStatus[player]
	if not st then
		st = {}
		passStatus[player] = st
	end
	for _, item in Monetization.PASSES do
		if Monetization.isConfigured(item) and not MonetizationService.hasPass(player, item.key) then
			local ok, has = ownsPass(player, item)
			if ok and player.Parent == Players then
				if has then
					setOwned(player, item.key)
				else
					st[item.key] = "not_owned"
				end
			end
		end
	end
end

local function herdLeaderPresent(): boolean
	for _, p in Players:GetPlayers() do
		if MonetizationService.hasPass(p, "herd_leader") then
			return true
		end
	end
	return false
end

-- Multipliers ----------------------------------------------------------------

function MonetizationService.feastSecondsLeft(): number
	return math.max(0, feastUntil - os.time())
end

function MonetizationService.cheeseMult(player: Player): number
	if not isRealPlayer(player) then
		return 1
	end
	local profile = DataService.get(player)
	return Boosts.cheeseMult({
		herdLeader = herdLeaderPresent(),
		feast = feastUntil > os.time(),
		premium = premium[player] == true,
		rush = profile ~= nil and profile.boosts.cheese2xUntil > os.time(),
	})
end

function MonetizationService.xpMult(player: Player): number
	if not isRealPlayer(player) then
		return 1
	end
	return Boosts.xpMult(MonetizationService.hasPass(player, "double_xp"))
end

-- Per-stage allowance of token rerolls (tokens are cheese-only; RunDirector spends them).
function MonetizationService.extraRerolls(player: Player): number
	local profile = DataService.get(player)
	if not profile then
		return 0
	end
	return math.max(0, math.min(profile.rerollTokens, R.maxTokenRerollsPerStage))
end

-- Server-wide Cheese Feast ---------------------------------------------------

-- Feast time bought on this server but not started yet (pending on profiles).
local function queuedFeastSeconds(): number
	local n = 0
	for _, p in Players:GetPlayers() do
		local profile = DataService.get(p)
		if profile then
			n += profile.boosts.feastPending
		end
	end
	return n * R.feastSeconds
end

-- Starts the buyer's pending feasts. The pending count is cleared (and any time the
-- 2 h cap cuts off is refunded as Golden Cheese) and saved BEFORE the boost starts,
-- so a feast can never start twice; if the save fails everything stays pending.
-- Serialised server-wide so two buyers can't both compute against the same timer.
local function startPendingFeasts(player: Player)
	local t0 = os.clock()
	while feastBusy do
		if os.clock() - t0 > 30 then
			return -- stays pending; retried on the next receipt or rejoin
		end
		task.wait(0.1)
	end
	feastBusy = true
	local ok, err = pcall(function()
		local n, refund = 0, 0
		local ext: any = nil
		local now = os.time()
		DataService.update(player, function(profile)
			n = profile.boosts.feastPending
			if n <= 0 then
				return
			end
			ext = Boosts.extend(feastUntil, now, R.feastSeconds * n, R.feastMaxStackSeconds)
			refund = Boosts.overflowRefund(ext.lost, R.feastSeconds, R.feastOverflowGolden)
			profile.boosts.feastPending = 0
			profile.goldenCheese = math.min(profile.goldenCheese + refund, MAX_CURRENCY)
		end)
		if n <= 0 or not ext then
			return
		end
		if not DataService.save(player) then
			DataService.update(player, function(profile)
				profile.boosts.feastPending += n
				profile.goldenCheese = math.max(0, profile.goldenCheese - refund)
			end)
			return
		end
		feastUntil = math.max(feastUntil, ext.untilT)
		local name = player.DisplayName
		local minutes = math.floor(ext.applied / 60)
		if minutes > 0 then
			toastAll(
				string.format(
					"%s started a Cheese Feast! Everyone earns +%d%% cheese for %d more minutes. Thank you, %s!",
					name,
					math.floor(R.feastBonus * 100 + 0.5),
					minutes,
					name
				),
				"good"
			)
		end
		if refund > 0 then
			toast(
				player,
				string.format(
					"The Cheese Feast was already at its 2 h maximum, so %d Golden Cheese was added instead for the time that didn't fit.",
					refund
				),
				"info"
			)
		end
		pushAll()
	end)
	feastBusy = false
	if not ok then
		warn("[Monetization] starting a Cheese Feast failed: " .. tostring(err))
	end
end

-- Receipts -------------------------------------------------------------------

local function describeGrant(key: string, result: any): string
	local item = Monetization.get(key)
	local name = if item then item.name else key
	if type(result) ~= "table" then
		return "Thanks for buying " .. name .. "!"
	end
	if result.boostUntil then
		local mins = math.floor((result.boostSeconds or 0) / 60)
		if result.refundGolden then
			return string.format(
				"Thank you! Cheese Rush +%d min (the 24 h maximum was reached); +%d Golden Cheese for the rest.",
				mins,
				result.refundGolden
			)
		end
		return string.format("Thank you! Cheese Rush +%d min: 2x cheese.", mins)
	elseif result.feast then
		return "Thank you! Your Cheese Feast is starting."
	elseif result.goldenCheese then
		return string.format("Thank you! +%d Golden Cheese.", result.goldenCheese)
	elseif result.secondWindTokens then
		return string.format("Thank you! +%d Second Wind.", result.secondWindTokens)
	elseif result.cheese then
		return string.format("Thanks for watching! +%d cheese.", result.cheese)
	end
	return "Thank you for buying " .. name .. "!"
end

local function handleReceipt(receipt: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local key = Monetization.keyForAsset("product", receipt.ProductId)
	if not key then
		warn("[Monetization] receipt for unknown product id " .. tostring(receipt.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local profile = DataService.waitFor(player, MonetizationService.RECEIPT_PROFILE_TIMEOUT)
	if not profile or DataService.isReadOnly(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local status, result = nil, nil
	local updated = DataService.update(player, function(p)
		status, result =
			Receipts.apply(p, receipt.PurchaseId, key, { now = os.time(), day = DataService.today() })
	end)
	if not updated or status == nil or status == "rejected" then
		warn(
			string.format(
				"[Monetization] receipt %s (%s) not applied: %s",
				tostring(receipt.PurchaseId),
				key,
				tostring(result)
			)
		)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- "granted" or "duplicate": the record (and grant) must be durable before we ack.
	if not DataService.save(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if status == "granted" then
		toast(player, describeGrant(key, result), "good")
		if result and result.feast then
			task.spawn(startPendingFeasts, player)
		end
		DataService.push(player)
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function processReceipt(receipt: any): Enum.ProductPurchaseDecision
	local userId = receipt.PlayerId
	-- One receipt at a time per player so two grants never interleave with a save.
	local t0 = os.clock()
	while receiptBusy[userId] do
		if os.clock() - t0 > 30 then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		task.wait(0.1)
	end
	receiptBusy[userId] = true
	local ok, decision = pcall(handleReceipt, receipt)
	receiptBusy[userId] = nil
	if not ok then
		warn("[Monetization] ProcessReceipt errored: " .. tostring(decision))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return decision
end

-- Subscriptions (Cheese Club) ------------------------------------------------

function MonetizationService.isClubMember(player: Player): boolean
	if not isRealPlayer(player) then
		return false
	end
	return club[player] == true
end

-- verify: GetUserSubscriptionStatusAsync(player, subscriptionId) -> { IsSubscribed, IsRenewing }
-- per the 2026 docs; the shape is pcall-guarded and a failure keeps the last known state.
function MonetizationService.refreshClub(player: Player, force: boolean?)
	if not isRealPlayer(player) then
		return
	end
	local now = os.clock()
	local last = lastClubCheck[player]
	if not force and last and now - last < MonetizationService.CLUB_REFRESH_COOLDOWN then
		return
	end
	lastClubCheck[player] = now
	local item = Monetization.get("cheese_club")
	if not item or not Monetization.isConfigured(item) then
		club[player] = false
		return
	end
	local wasMember = club[player] == true
	local ok, status = pcall(function()
		return (MarketplaceService :: any):GetUserSubscriptionStatusAsync(player, item.assetId)
	end)
	if ok and type(status) == "table" then
		club[player] = status.IsSubscribed == true
	elseif not ok then
		warn("[Monetization] subscription check failed: " .. tostring(status))
	end
	if (club[player] == true) ~= wasMember then
		notifyEntitlements(player) -- Club title and chat tag
	end
	if not club[player] or not DataService.waitFor(player) then
		return
	end
	local dailyOk, monthly = false, nil
	DataService.update(player, function(profile)
		dailyOk = Daily.claimClub(profile, DataService.today())
		monthly = Receipts.applyClubMonthly(profile, monthIndex())
	end)
	if dailyOk then
		toast(
			player,
			string.format(
				"Cheese Club: +%d Golden Cheese and +%d Second Wind today!",
				R.clubDailyGolden,
				R.clubDailySecondWinds
			),
			"good"
		)
	end
	if monthly then
		toast(player, "Cheese Club: this month's cosmetic is yours to keep!", "good")
	end
	if dailyOk or monthly then
		task.spawn(DataService.save, player)
	end
	DataService.push(player)
end

-- Policy ---------------------------------------------------------------------

local function refreshPolicy(player: Player)
	local ok, info = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	if ok and type(info) == "table" then
		policy[player] = { paidRandomRestricted = info.ArePaidRandomItemsRestricted == true }
	else
		policy[player] = { paidRandomRestricted = true } -- fail safe
	end
end

-- We sell no paid random items. Gate any future one on this returning false.
function MonetizationService.paidRandomItemsRestricted(player: Player): boolean
	if not isRealPlayer(player) then
		return true
	end
	local p = policy[player]
	return p == nil or p.paidRandomRestricted
end

-- Rewarded ads (stub) --------------------------------------------------------

-- TODO(ads): finish once eligible. Notes:
--   * Viewers must be 13+; AdService reports "unavailable" for everyone else, and the
--     UI must hide the button then. Under-13s get the same kind of reward without ads
--     (daily streak Second Wind, first-run-of-the-day 2x cheese).
--   * The reward is NOT granted here. AdService grants the ad_reward developer product,
--     which arrives through ProcessReceipt (Data/Receipts "ad_reward": fixed +50% of
--     the last run's cheese, min 25 / max 500). Never random. Max 3 per day.
--   * Optional, results screen only, never required to progress.
-- verify: AdService method names/enum (GetAdAvailabilityNowAsync, CreateAdRewardFromDevProductId,
-- ShowRewardedVideoAdAsync, Enum.AdFormat.RewardedVideo) against the current reference.
function MonetizationService.showRewardedAd(player: Player): boolean
	if not isRealPlayer(player) then
		return false
	end
	if not MonetizationService.ADS_ENABLED then
		toast(player, "Ads aren't available right now.", "info")
		return false
	end
	local item = Monetization.get("ad_reward")
	if not item or not Monetization.isConfigured(item) then
		return false
	end
	local profile = DataService.get(player)
	if not profile then
		return false
	end
	if profile.ads.day == DataService.today() and profile.ads.count >= R.adDailyCap then
		toast(player, "That's all the snack breaks for today!", "info")
		return false
	end
	local ok, err = pcall(function()
		local AdService = game:GetService("AdService") :: any
		local availability = AdService:GetAdAvailabilityNowAsync((Enum :: any).AdFormat.RewardedVideo)
		if
			not availability
			or availability.AdAvailabilityResult ~= (Enum :: any).AdAvailabilityResult.IsAvailable
		then
			error("unavailable")
		end
		local reward = AdService:CreateAdRewardFromDevProductId(item.assetId)
		AdService:ShowRewardedVideoAdAsync(player, reward, "results_snack_break")
	end)
	if not ok then
		warn("[Monetization] rewarded ad not shown: " .. tostring(err))
		return false
	end
	return true
end

-- Prompts --------------------------------------------------------------------

local function promptPlus(player: Player)
	-- verify: Roblox Plus prompt API name (research: PromptRobloxSubscriptionPurchase).
	local ok = pcall(function()
		(MarketplaceService :: any):PromptRobloxSubscriptionPurchase(player)
	end)
	if not ok then
		pcall(function()
			MarketplaceService:PromptPremiumPurchase(player)
		end)
	end
end

-- Refuses a timed boost whose full duration would pass its cap (QC2 M4).
-- Returns (true) or (false, reason, toastText).
local function boostHeadroom(player: Player, key: string, item: any): (boolean, string?, string?)
	local now = os.time()
	if key == "cheese_rush" then
		local profile = DataService.get(player)
		if not profile then
			return false, "no_profile", "Your profile is still loading."
		end
		local fits, over = Boosts.fits(
			profile.boosts.cheese2xUntil,
			now,
			item.boostSeconds or 3600,
			R.cheeseRushMaxStackSeconds
		)
		if not fits then
			return false,
				"rush_cap",
				string.format(
					"Your Cheese Rush is near its 24 h maximum, so a full hour won't fit yet. Try again in %d min.",
					Boosts.minutesUntilFits(over)
				)
		end
	elseif key == "cheese_feast" then
		local fits, over = Boosts.fits(
			feastUntil,
			now,
			item.boostSeconds or R.feastSeconds,
			R.feastMaxStackSeconds,
			queuedFeastSeconds()
		)
		if not fits then
			return false,
				"feast_cap",
				string.format(
					"This server's Cheese Feast is near its 2 h maximum, so 30 more minutes won't fit yet. Try again in %d min.",
					Boosts.minutesUntilFits(over)
				)
		end
	end
	return true, nil, nil
end

-- Prompts a pass / product / subscription for an explicit player request. Never call
-- this from a timer, a death screen or the Double-or-Nothing vote.
-- Returns (true) when a prompt (or refresh) was started, else (false, reason). Every
-- refusal the player should know about is also sent as a Toast.
--   reasons: "bot" | "bad_key" | "cooldown" | "unknown" | "coming_soon" | "owned"
--            | "member" | "no_profile" | "rush_cap" | "feast_cap" | "ad"
function MonetizationService.prompt(player: Player, key: any): (boolean, string?)
	if not isRealPlayer(player) then
		return false, "bot"
	end
	if type(key) ~= "string" or #key == 0 or #key > 32 then
		return false, "bad_key"
	end
	local now = os.clock()
	if key == "refresh" then
		-- The shop UI opened: catch website purchases. Its own cooldown, so a buy
		-- click right after opening the shop is never swallowed by this.
		if lastRefresh[player] and now - lastRefresh[player] < MonetizationService.REFRESH_COOLDOWN then
			return false, "cooldown"
		end
		lastRefresh[player] = now
		task.spawn(MonetizationService.refreshPasses, player, false)
		task.spawn(MonetizationService.refreshClub, player, false)
		return true, nil
	end
	if lastPrompt[player] and now - lastPrompt[player] < MonetizationService.PROMPT_COOLDOWN then
		return false, "cooldown"
	end
	lastPrompt[player] = now

	if key == "roblox_plus" then
		promptPlus(player)
		return true, nil
	end

	local item = Monetization.get(key)
	if not item then
		return false, "unknown"
	end
	if not Monetization.isConfigured(item) then
		toast(player, item.name .. " is coming soon!", "info")
		return false, "coming_soon"
	end
	if item.kind == "pass" then
		if MonetizationService.hasPass(player, key) then
			toast(player, "You already own " .. item.name .. ".", "info")
			return false, "owned"
		end
		pcall(function()
			MarketplaceService:PromptGamePassPurchase(player, item.assetId)
		end)
	elseif item.kind == "product" then
		if item.adOnly then
			MonetizationService.showRewardedAd(player)
			return true, "ad"
		end
		local fits, reason, text = boostHeadroom(player, key, item)
		if not fits then
			toast(player, text or "You can't buy that right now.", "info")
			return false, reason
		end
		pcall(function()
			MarketplaceService:PromptProductPurchase(player, item.assetId)
		end)
	elseif item.kind == "subscription" then
		if MonetizationService.isClubMember(player) then
			toast(player, "You're already in the " .. item.name .. "!", "info")
			return false, "member"
		end
		pcall(function()
			(MarketplaceService :: any):PromptSubscriptionPurchase(player, item.assetId)
		end)
	end
	return true, nil
end

-- View decorator: what the shop/HUD needs on top of ProfileSchema.view.
local function decorate(player: Player, view: { [string]: any })
	view.passes = table.clone(owned[player] or {})
	view.club = club[player] == true
	view.premium = premium[player] == true
	view.cheeseMult = MonetizationService.cheeseMult(player)
	view.feastSecondsLeft = MonetizationService.feastSecondsLeft()
	view.herdLeaderActive = herdLeaderPresent()
	local profile = DataService.get(player)
	if profile then
		local used = if profile.ads.day == DataService.today() then profile.ads.count else 0
		view.adsLeftToday = if MonetizationService.ADS_ENABLED then math.max(0, R.adDailyCap - used) else 0
	end
end

-- Lifecycle ------------------------------------------------------------------

local function onJoin(player: Player)
	if not isRealPlayer(player) then
		return
	end
	premium[player] = player.MembershipType == Enum.MembershipType.Premium
	owned[player] = owned[player] or {}
	refreshPolicy(player)
	MonetizationService.refreshPasses(player, true)
	if not DataService.waitFor(player) then
		return
	end
	for key in owned[player] or {} do
		applyPassPerks(player, key) -- idempotent; re-applies in case of an earlier failed save
	end
	-- Refunded / charged-back passes: Roblox definitely says "not owned" (an API error
	-- never revokes), so drop the perks that pass saved on the profile.
	local st = passStatus[player] or {}
	local profile = DataService.get(player)
	if profile then
		for _, key in Passes.recordedKeys(profile) do
			if st[key] == "not_owned" and not MonetizationService.hasPass(player, key) then
				revokePassPerks(player, key)
			end
		end
	end
	MonetizationService.refreshClub(player, true)
	startPendingFeasts(player) -- a feast bought before a crash/leave starts now
	DataService.push(player)
	notifyEntitlements(player)
end

local function onLeave(player: Player)
	local hadHerdLeader = MonetizationService.hasPass(player, "herd_leader")
	owned[player] = nil
	lastPassCheck[player] = nil
	passStatus[player] = nil
	verifying[player] = nil
	lastClubCheck[player] = nil
	premium[player] = nil
	club[player] = nil
	policy[player] = nil
	lastPrompt[player] = nil
	lastRefresh[player] = nil
	if hadHerdLeader then
		task.defer(pushAll)
	end
end

function MonetizationService.init()
	if initialized then
		return
	end
	initialized = true
	toastRemote = Net.get(Net.S2C.Toast)

	-- The ONE ProcessReceipt handler in the game.
	MarketplaceService.ProcessReceipt = processReceipt

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, purchased: boolean)
			if not purchased then
				return -- quiet: respects parental spend limits, no re-prompt
			end
			local key = Monetization.keyForAsset("pass", passId)
			if not key then
				return
			end
			if not isRealPlayer(player) then
				return
			end
			-- UI hint only: grant nothing until Roblox confirms ownership (QC2 M5).
			local item = Monetization.get(key)
			toast(player, "Thank you! Activating " .. (if item then item.name else key) .. "...", "good")
			task.spawn(verifyPurchase, player, key)
		end
	)

	Players.PlayerMembershipChanged:Connect(function(player: Player)
		premium[player] = player.MembershipType == Enum.MembershipType.Premium
		DataService.push(player)
	end)

	-- verify: event name/signature for subscription changes.
	pcall(function()
		(Players :: any).UserSubscriptionStatusChanged:Connect(
			function(player: Player, _subscriptionId: string)
				MonetizationService.refreshClub(player, true)
			end
		)
	end)

	DataService.addViewDecorator(decorate)

	Guard.connect(
		Net.C2S.PromptProduct,
		{ args = { Guard.T.string(32) }, rate = 1, burst = 3 },
		function(player: Player, key: string)
			MonetizationService.prompt(player, key)
		end
	)

	Players.PlayerAdded:Connect(function(player)
		task.spawn(onJoin, player)
	end)
	Players.PlayerRemoving:Connect(onLeave)
	for _, player in Players:GetPlayers() do
		task.spawn(onJoin, player)
	end

	task.spawn(function()
		while true do
			task.wait(MonetizationService.CLUB_POLL_INTERVAL)
			for _, player in Players:GetPlayers() do
				task.spawn(MonetizationService.refreshClub, player, true)
			end
		end
	end)
end

return MonetizationService
