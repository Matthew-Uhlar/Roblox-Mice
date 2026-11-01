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
--   MonetizationService.prompt(player, key)               -- also "refresh" (recheck passes) and "roblox_plus"
--   MonetizationService.isClubMember(player) -> boolean
--   MonetizationService.refreshPasses(player, force: boolean?)
--   MonetizationService.refreshClub(player)
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

local DataService = require(script.Parent:WaitForChild("DataService")) :: any
local Guard = require(script.Parent:WaitForChild("Guard")) :: any

local MonetizationService = {}

local R = Monetization.RULES
local isRealPlayer = DataService.isRealPlayer -- false for bots (ids <= 0, no Player object)

-- TODO(ads): flip to true once the experience is ads-eligible (Minimal/Mild maturity,
-- good standing) and the ad_reward product id is set. Rewarded ads only reach 13+.
MonetizationService.ADS_ENABLED = false
MonetizationService.PROMPT_COOLDOWN = 1.5
MonetizationService.PASS_RECHECK_COOLDOWN = 10
MonetizationService.CLUB_POLL_INTERVAL = 600
MonetizationService.RECEIPT_PROFILE_TIMEOUT = 20

type PolicyInfo = { paidRandomRestricted: boolean }

local owned: { [Player]: { [string]: boolean } } = {}
local lastPassCheck: { [Player]: number } = {}
local premium: { [Player]: boolean } = {}
local club: { [Player]: boolean } = {}
local policy: { [Player]: PolicyInfo } = {}
local lastPrompt: { [Player]: number } = {}
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

local function setOwned(player: Player, key: string)
	local set = owned[player]
	if not set then
		set = {}
		owned[player] = set
	end
	local was = set[key]
	set[key] = true
	if not was then
		task.spawn(function()
			if DataService.waitFor(player) then
				applyPassPerks(player, key)
			end
			pushAll() -- Herd Leader changes everyone's multiplier
		end)
	end
end

-- Checks every configured pass. Results only ever upgrade to owned during a session
-- (UserOwnsGamePassAsync can lag right after a purchase); a rejoin re-evaluates.
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
	for _, item in Monetization.PASSES do
		if Monetization.isConfigured(item) and not MonetizationService.hasPass(player, item.key) then
			local ok, has = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, item.assetId)
			end)
			if ok and has == true and player.Parent == Players then
				setOwned(player, item.key)
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

-- Starts the buyer's pending feasts. The pending count is cleared and saved BEFORE the
-- boost starts, so a feast can never start twice; if the save fails it stays pending.
local function startPendingFeasts(player: Player)
	local n = 0
	DataService.update(player, function(profile)
		n = profile.boosts.feastPending
		profile.boosts.feastPending = 0
	end)
	if n <= 0 then
		return
	end
	if not DataService.save(player) then
		DataService.update(player, function(profile)
			profile.boosts.feastPending += n
		end)
		return
	end
	feastUntil = Boosts.extendUntil(feastUntil, os.time(), R.feastSeconds * n, R.feastMaxStackSeconds)
	local name = player.DisplayName
	toastAll(
		string.format(
			"%s started a Cheese Feast! Everyone earns +%d%% cheese for %d minutes. Thank you, %s!",
			name,
			math.floor(R.feastBonus * 100 + 0.5),
			math.floor(R.feastSeconds * n / 60),
			name
		),
		"good"
	)
	pushAll()
end

-- Receipts -------------------------------------------------------------------

local function describeGrant(key: string, result: any): string
	local item = Monetization.get(key)
	local name = if item then item.name else key
	if type(result) ~= "table" then
		return "Thanks for buying " .. name .. "!"
	end
	if result.goldenCheese then
		return string.format("Thank you! +%d Golden Cheese.", result.goldenCheese)
	elseif result.secondWindTokens then
		return string.format("Thank you! +%d Second Wind.", result.secondWindTokens)
	elseif result.boostUntil then
		return "Thank you! Cheese Rush is active: 2x cheese."
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
function MonetizationService.refreshClub(player: Player)
	if not isRealPlayer(player) then
		return
	end
	local item = Monetization.get("cheese_club")
	if not item or not Monetization.isConfigured(item) then
		club[player] = false
		return
	end
	local ok, status = pcall(function()
		return (MarketplaceService :: any):GetUserSubscriptionStatusAsync(player, item.assetId)
	end)
	if ok and type(status) == "table" then
		club[player] = status.IsSubscribed == true
	elseif not ok then
		warn("[Monetization] subscription check failed: " .. tostring(status))
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

-- Prompts a pass / product / subscription for an explicit player request. Never call
-- this from a timer, a death screen or the Double-or-Nothing vote.
function MonetizationService.prompt(player: Player, key: any)
	if not isRealPlayer(player) then
		return
	end
	if type(key) ~= "string" or #key == 0 or #key > 32 then
		return
	end
	local now = os.clock()
	if lastPrompt[player] and now - lastPrompt[player] < MonetizationService.PROMPT_COOLDOWN then
		return
	end
	lastPrompt[player] = now

	if key == "refresh" then -- the shop UI opened: catch website purchases
		task.spawn(MonetizationService.refreshPasses, player, false)
		task.spawn(MonetizationService.refreshClub, player)
		return
	elseif key == "roblox_plus" then
		promptPlus(player)
		return
	end

	local item = Monetization.get(key)
	if not item then
		return
	end
	if not Monetization.isConfigured(item) then
		toast(player, item.name .. " is coming soon!", "info")
		return
	end
	if item.kind == "pass" then
		if MonetizationService.hasPass(player, key) then
			toast(player, "You already own " .. item.name .. ".", "info")
			return
		end
		pcall(function()
			MarketplaceService:PromptGamePassPurchase(player, item.assetId)
		end)
	elseif item.kind == "product" then
		if item.adOnly then
			MonetizationService.showRewardedAd(player)
			return
		end
		pcall(function()
			MarketplaceService:PromptProductPurchase(player, item.assetId)
		end)
	elseif item.kind == "subscription" then
		if MonetizationService.isClubMember(player) then
			toast(player, "You're already in the " .. item.name .. "!", "info")
			return
		end
		pcall(function()
			(MarketplaceService :: any):PromptSubscriptionPurchase(player, item.assetId)
		end)
	end
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
	MonetizationService.refreshClub(player)
	startPendingFeasts(player) -- a feast bought before a crash/leave starts now
	DataService.push(player)
end

local function onLeave(player: Player)
	local hadHerdLeader = MonetizationService.hasPass(player, "herd_leader")
	owned[player] = nil
	lastPassCheck[player] = nil
	premium[player] = nil
	club[player] = nil
	policy[player] = nil
	lastPrompt[player] = nil
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
			setOwned(player, key)
			local item = Monetization.get(key)
			toast(player, "Thank you! " .. (if item then item.name else key) .. " is yours.", "good")
			-- Re-verify after the ownership cache catches up.
			task.delay(MonetizationService.PASS_RECHECK_COOLDOWN, function()
				if player.Parent == Players then
					MonetizationService.refreshPasses(player, true)
				end
			end)
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
				MonetizationService.refreshClub(player)
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
				task.spawn(MonetizationService.refreshClub, player)
			end
		end
	end)
end

return MonetizationService
