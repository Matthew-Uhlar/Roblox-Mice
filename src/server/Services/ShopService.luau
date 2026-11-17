--!strict
-- ShopService (Team D): the soft-currency lobby shop, cosmetics equip and the daily
-- streak claim. All client intents go through Guard.connect (types, string caps,
-- token-bucket rate limits). Logic lives in the pure Data/Shop and Data/Daily modules.
--
-- Remotes (Net.C2S):
--   BuyShopItem(itemId: string)                       ids documented in Config/Shop
--   Equip(slot: "trail"|"hat"|"tint", cosmeticId: string?)   nil unequips
--   ClaimDaily()
--   SetSetting(key: string, value: boolean)          allowlisted keys only (SETTING_KEYS)
--   (v5, GDD-v2 §5, rules in the pure Data/ClassProgress):
--   SelectPerk(classId, perkId)                       ClassProgress.canTake (points, tier order)
--   ResetPerks(classId, payWith?: "cheese"|"token")   respec: cheese unless "token" is sent
--                                                     (or asked), else respecCost(level) cheese
--   SelectAbility(classId, abilityId?)                must be unlocked (class level 5 / 15); nil = base
--   SelectSkin(classId, skinId?)                      earned by level or owned (paid); nil/"default" = default
--   (v6, v4 plan) Herd Contracts / Herd Pass / account rewards (pure Data/Quests,
--   Data/HerdPass, Data/AccountRewards):
--   ClaimQuest(questId)                               a finished contract: cheese + Pass XP
--   RerollQuest(questId)                              1 free per day, then Config/Quests.EXTRA_REROLL_CHEESE
--   ClaimPassTier(tier, "free"|"premium")              a reached tier; premium needs this season's pass
--   ClaimAccountReward(level)                         every 5 account levels up to 100
--   Equip("title", titleId?)                          an earned title on the nametag
--   BuyShopItem("dye:<id>")                           nametag colour, repeatable cheese sink
-- Talent buys and respecs are refused while the player is in a run (QC-C m8), and
-- every spend asks for a save (QC-C m9).
-- Every handler pushes the updated profile view (Net.S2C.Profile) and a Toast.
-- A successful Equip / SelectSkin redraws the character's cosmetics (CosmeticsService.refresh).
-- RunDirector should snapshot ClassProgress.classState at run start, so these lobby
-- choices never change a hero in the middle of a run.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Config = Shared:WaitForChild("Config")
local DataFolder = Shared:WaitForChild("Data")
local ShopConfig = require(Config:WaitForChild("Shop")) :: any
local Talents = require(Config:WaitForChild("Talents")) :: any
local Cosmetics = require(Config:WaitForChild("Cosmetics")) :: any
local Shop = require(DataFolder:WaitForChild("Shop")) :: any
local Daily = require(DataFolder:WaitForChild("Daily")) :: any
local ClassProgress = require(DataFolder:WaitForChild("ClassProgress")) :: any
local ClassAbilities = require(Config:WaitForChild("ClassAbilities")) :: any
local ClassSkins = require(Config:WaitForChild("ClassSkins")) :: any
local QuestConfig = require(Config:WaitForChild("Quests")) :: any
local Quests = require(DataFolder:WaitForChild("Quests")) :: any
local HerdPass = require(DataFolder:WaitForChild("HerdPass")) :: any
local Progress = require(DataFolder:WaitForChild("Progress")) :: any
local AccountRewards = require(DataFolder:WaitForChild("AccountRewards")) :: any
local Grant = require(DataFolder:WaitForChild("Grant")) :: any

local DataService = require(script.Parent:WaitForChild("DataService")) :: any
local MonetizationService = require(script.Parent:WaitForChild("MonetizationService")) :: any
local Guard = require(script.Parent:WaitForChild("Guard")) :: any

local ShopService = {}

-- Profile settings the client may change (Net.C2S.SetSetting). Booleans only.
ShopService.SETTING_KEYS = { "hints" }

-- CosmeticsService is optional (Main inits it with initOptional); load it lazily.
local cosmetics: any = nil
local function refreshLooks(player: Player)
	if cosmetics == nil then
		local ok, mod = pcall(function()
			return require(script.Parent:FindFirstChild("CosmeticsService") :: ModuleScript) :: any
		end)
		cosmetics = if ok and type(mod) == "table" then mod else false
	end
	if cosmetics and type(cosmetics.refresh) == "function" then
		pcall(cosmetics.refresh, player)
	end
end

local initialized = false
local toastRemote: any = nil

local REASON_TEXT: { [string]: string } = {
	bad_id = "That item doesn't exist.",
	unknown_item = "That item doesn't exist.",
	owned = "You already own that.",
	max_level = "That talent is already maxed.",
	not_for_sale = "That item isn't sold here.",
	insufficient_funds = "Not enough cheese for that yet.",
	cap_reached = "You're holding the maximum of those tokens.",
	not_owned = "You don't own that cosmetic.",
	wrong_slot = "That cosmetic doesn't go in that slot.",
	bad_slot = "Unknown cosmetic slot.",
	already_claimed = "Daily reward already claimed. Come back tomorrow!",
	clock = "Daily reward isn't ready yet.",
	no_profile = "Your profile is still loading.",
	-- (v5) class progression
	bad_class = "That class doesn't exist.",
	class_locked = "Unlock that class first.",
	unknown_perk = "That perk doesn't exist.",
	wrong_class = "That perk belongs to another class.",
	taken = "You already have that perk.",
	locked_tier = "Take the perk before it in that branch first.",
	no_points = "Not enough perk points. Level this class up!",
	nothing_to_reset = "No perks to reset.",
	no_token = "You don't have a Perk Respec Token.",
	unknown_ability = "That ability doesn't exist.",
	ability_locked = "That ability unlocks at a higher class level.",
	unknown_skin = "That skin doesn't exist.",
	skin_locked = "You haven't unlocked that skin yet.",
	-- (v6)
	in_run = "You can't do that during a match. Visit the shop in the lobby.",
	unknown = "That contract isn't active any more.",
	claimed = "Already claimed.",
	not_done = "Finish the contract first.",
	weekly = "Weekly contracts can't be rerolled.",
	no_rerolls = "No rerolls left today.",
	no_alternative = "No other contract of that kind today.",
	bad_track = "Unknown reward track.",
	bad_tier = "Unknown tier.",
	not_reached = "Reach that tier first.",
	no_reward = "That tier has no reward on this track.",
	no_premium = "That reward is on the premium track.",
	bad_level = "There's no reward for that level.",
}

local function toast(player: Player, text: string, kind: string?)
	if toastRemote then
		pcall(function()
			toastRemote:FireClient(player, text, kind or "info")
		end)
	end
end

local function fail(player: Player, reason: string?)
	toast(player, REASON_TEXT[reason or ""] or "Can't do that right now.", "bad")
end

local function itemName(itemId: string): string
	local p = Shop.parse(itemId)
	if not p then
		return itemId
	end
	if p.kind == "class" then
		local Classes = ShopConfig.classes()
		local def = Classes and Classes.get and Classes.get(p.ref)
		return if def then def.name else p.ref
	elseif p.kind == "talent" then
		local def = Talents.get(p.ref)
		return if def then def.name else p.ref
	elseif p.kind == "cosmetic" then
		local def = Cosmetics.get(p.ref)
		return if def then def.name else p.ref
	elseif p.kind == "bundle" then
		local b = ShopConfig.BUNDLES[p.ref]
		return if b then b.name else p.ref
	elseif p.kind == "skin" then
		local def = ClassSkins.get(p.ref)
		return if def then def.name else p.ref
	elseif p.kind == "dye" then
		local dye = Cosmetics.DYES[p.ref]
		return if dye then dye.name .. " name colour" else "Default name colour"
	end
	return itemId
end

local function inRun(player: Player): boolean
	return type(MonetizationService.isRunMember) == "function"
		and MonetizationService.isRunMember(player) == true
end

local function onBuy(player: Player, itemId: string)
	local parsed = Shop.parse(itemId)
	if not parsed then
		fail(player, "bad_id")
		return
	end
	-- QC-C m8: talents change run stats, so they are never bought mid-run.
	if parsed.kind == "talent" and inRun(player) then
		fail(player, "in_run")
		return
	end
	if not DataService.get(player) or DataService.isReadOnly(player) then
		fail(player, "no_profile")
		return
	end
	local ctx = { club = MonetizationService.isClubMember(player) }
	local ok, reason = false, nil
	DataService.update(player, function(profile)
		ok, reason = Shop.buy(profile, itemId, ctx)
	end)
	if not ok then
		fail(player, reason)
		return
	end
	local p = Shop.parse(itemId)
	if p and p.kind == "talent" then
		local profile = DataService.get(player)
		local lvl = if profile then profile.talents[p.ref] or 0 else 0
		toast(player, string.format("%s is now level %d!", itemName(itemId), lvl), "good")
	elseif p and p.kind == "dye" then
		toast(player, "New name colour!", "good")
		refreshLooks(player)
	else
		toast(player, "Unlocked: " .. itemName(itemId), "good")
	end
	if p and p.kind == "class" then
		-- achievements like "Herd of Many" (unlock 5 classes)
		DataService.update(player, function(profile)
			Progress.checkAchievements(profile)
		end)
	end
	task.spawn(DataService.save, player) -- QC-C m9: a spend is saved right away
	DataService.push(player)
end

local function onEquip(player: Player, slot: string, cosmeticId: string?)
	if not DataService.get(player) or DataService.isReadOnly(player) then
		fail(player, "no_profile")
		return
	end
	local ok, reason = false, nil
	DataService.update(player, function(profile)
		ok, reason = Shop.equip(profile, slot, cosmeticId)
	end)
	if not ok then
		fail(player, reason)
		return
	end
	DataService.push(player)
	refreshLooks(player) -- B1: equipped cosmetics show on the character right away
end

local function describe(granted: any): string
	local parts = {}
	if granted.cheese then
		table.insert(parts, string.format("+%d cheese", granted.cheese))
	end
	if granted.goldenCheese then
		table.insert(parts, string.format("+%d Golden Cheese", granted.goldenCheese))
	end
	if granted.secondWindTokens then
		table.insert(parts, string.format("+%d Second Wind", granted.secondWindTokens))
	end
	if granted.rerollTokens then
		table.insert(parts, string.format("+%d Reroll Tokens", granted.rerollTokens))
	end
	if granted.cosmetic then
		local def = Cosmetics.get(granted.cosmetic)
		table.insert(parts, "new cosmetic: " .. (if def then def.name else granted.cosmetic))
	end
	return table.concat(parts, ", ")
end

local function onClaimDaily(player: Player)
	if not DataService.get(player) or DataService.isReadOnly(player) then
		fail(player, "no_profile")
		return
	end
	local ok, res = false, nil
	local vip = MonetizationService.hasPass(player, "vip")
	DataService.update(player, function(profile)
		ok, res = Daily.claim(profile, DataService.today(), { vip = vip })
		if ok then
			Progress.checkAchievements(profile) -- (v6) e.g. Streak Keeper
		end
	end)
	if not ok then
		fail(player, res)
		DataService.push(player)
		return
	end
	toast(player, string.format("Day %d reward: %s", res.day, describe(res.granted)), "good")
	task.spawn(DataService.save, player)
	DataService.push(player)
	-- Picks up a Cheese Club subscription bought mid-session (daily club grant).
	task.spawn(MonetizationService.refreshClub, player)
end

local function onSetSetting(player: Player, key: string, value: boolean)
	if not DataService.get(player) or DataService.isReadOnly(player) then
		return -- quiet: a settings toggle is not worth a toast
	end
	local changed = false
	DataService.update(player, function(profile)
		if profile.settings[key] ~= value then
			profile.settings[key] = value
			changed = true
		end
	end)
	if changed then
		DataService.push(player) -- saved with the next autosave / release
	end
end

-- Class progression (v5) ---------------------------------------------------------

-- Runs a ClassProgress profile operation; toasts the reason on failure.
local function classOp(player: Player, op: (any) -> (boolean, string?, any)): (boolean, any)
	if not DataService.get(player) or DataService.isReadOnly(player) then
		fail(player, "no_profile")
		return false, nil
	end
	local ok, reason, info = false, nil, nil
	DataService.update(player, function(profile)
		ok, reason, info = op(profile)
	end)
	if not ok then
		fail(player, reason)
		return false, nil
	end
	return true, info
end

local function onSelectPerk(player: Player, classId: string, perkId: string)
	local ok, def = classOp(player, function(profile)
		return ClassProgress.selectPerk(profile, classId, perkId)
	end)
	if ok then
		toast(player, "Perk learned: " .. (if def then def.name else perkId), "good")
		DataService.push(player)
	end
end

local function onResetPerks(player: Player, classId: string, payWith: string?)
	if inRun(player) then
		fail(player, "in_run") -- QC-C m8
		return
	end
	local ok, res = classOp(player, function(profile)
		return ClassProgress.resetPerks(profile, classId, payWith)
	end)
	if not ok or not res then
		return
	end
	if res.paid == "token" then
		toast(player, string.format("Perks reset with a Respec Token: %d points back.", res.refunded), "good")
	else
		toast(
			player,
			string.format("Perks reset for %d cheese: %d points back.", res.cost, res.refunded),
			"good"
		)
	end
	task.spawn(DataService.save, player) -- it spent a currency
	DataService.push(player)
end

local function onSelectAbility(player: Player, classId: string, abilityId: string?)
	local ok = classOp(player, function(profile)
		return ClassProgress.selectAbility(profile, classId, abilityId)
	end)
	if ok then
		local e = if abilityId then ClassAbilities.get(abilityId) else nil
		local id = if e then e.id else ClassAbilities.baseId(classId)
		local entry = if id then ClassAbilities.get(id) else nil
		toast(player, "Ability: " .. (if entry then entry.def.name else tostring(abilityId)), "info")
		DataService.push(player)
	end
end

local function onSelectSkin(player: Player, classId: string, skinId: string?)
	local ok = classOp(player, function(profile)
		return ClassProgress.selectSkin(profile, classId, skinId)
	end)
	if ok then
		DataService.push(player)
		refreshLooks(player)
	end
end

-- Herd Contracts / Herd Pass / account rewards (v6) -----------------------------

local function progressOp(player: Player, op: (any) -> (boolean, any)): (boolean, any)
	if not DataService.get(player) or DataService.isReadOnly(player) then
		fail(player, "no_profile")
		return false, nil
	end
	-- a claim made right after midnight applies to the new day's contracts
	DataService.syncProgress(player)
	local ok, res = false, nil
	DataService.update(player, function(profile)
		ok, res = op(profile)
	end)
	if not ok then
		fail(player, res)
		DataService.pushProgress(player)
		return false, nil
	end
	task.spawn(DataService.save, player)
	DataService.push(player)
	DataService.pushProgress(player)
	return true, res
end

local function onClaimQuest(player: Player, questId: string)
	local ok, given = progressOp(player, function(profile)
		return Quests.claim(profile, questId, Progress.addPassXp)
	end)
	if ok then
		toast(player, "Contract done: " .. Grant.describe(given), "good")
	end
end

local function onRerollQuest(player: Player, questId: string)
	local ok, res = progressOp(player, function(profile)
		return Quests.reroll(profile, questId, player.UserId)
	end)
	if ok and res then
		local def = QuestConfig.get(res.id)
		local text = if def then QuestConfig.describe(def) else res.id
		if res.cost > 0 then
			toast(player, string.format("New contract (-%d cheese): %s", res.cost, text), "info")
		else
			toast(player, "New contract: " .. text, "info")
		end
	end
end

local function onClaimPassTier(player: Player, tier: number, track: string)
	local profile = DataService.get(player)
	local prem = profile ~= nil and DataService.premiumNow(player, profile)
	local ok, given = progressOp(player, function(p)
		return HerdPass.claim(p, tier, track, prem)
	end)
	if ok then
		toast(player, string.format("Herd Pass tier %d: %s", tier, Grant.describe(given)), "good")
		if given and given.cosmetics then
			refreshLooks(player)
		end
	end
end

local function onClaimAccountReward(player: Player, level: number)
	local ok, given = progressOp(player, function(profile)
		return AccountRewards.claim(profile, level)
	end)
	if ok then
		toast(player, string.format("Level %d reward: %s", level, Grant.describe(given)), "good")
	end
end

-- Shop view additions (Net.S2C.Profile): the daily Featured shelf, dyes, reroll price.
local function decorate(_player: Player, view: { [string]: any })
	view.featured = Shop.featured(DataService.today())
	local dyes = {}
	for _, id in Cosmetics.DYE_ORDER do
		local d = Cosmetics.DYES[id]
		table.insert(dyes, { id = id, name = d.name, color = table.clone(d.color), price = d.price })
	end
	view.dyes = dyes
end

function ShopService.init()
	if initialized then
		return
	end
	initialized = true
	toastRemote = Net.get(Net.S2C.Toast)

	Guard.connect(Net.C2S.BuyShopItem, {
		args = { Guard.T.string(ShopConfig.MAX_ITEM_ID_LEN) },
		rate = 4,
		burst = 6,
	}, onBuy)

	Guard.connect(Net.C2S.Equip, {
		args = {
			Guard.T.enum({ "trail", "hat", "tint", "title" }),
			Guard.T.optional(Guard.T.string(ShopConfig.MAX_ITEM_ID_LEN)),
		},
		rate = 4,
		burst = 6,
	}, onEquip)

	Guard.connect(Net.C2S.SetSetting, {
		args = { Guard.T.enum(ShopService.SETTING_KEYS), Guard.T.boolean() },
		rate = 2,
		burst = 4,
	}, onSetSetting)

	-- (v5) class progression remotes
	local ID = ShopConfig.MAX_ITEM_ID_LEN
	if Net.C2S.SelectPerk then
		Guard.connect(Net.C2S.SelectPerk, {
			args = { Guard.T.string(32), Guard.T.string(ID) },
			rate = 4,
			burst = 8,
		}, onSelectPerk)
	end
	if Net.C2S.ResetPerks then
		Guard.connect(Net.C2S.ResetPerks, {
			args = { Guard.T.string(32), Guard.T.optional(Guard.T.enum({ "cheese", "token" })) },
			rate = 0.5,
			burst = 2,
		}, onResetPerks)
	end
	if Net.C2S.SelectAbility then
		Guard.connect(Net.C2S.SelectAbility, {
			args = { Guard.T.string(32), Guard.T.optional(Guard.T.string(ID)) },
			rate = 2,
			burst = 4,
		}, onSelectAbility)
	end
	if Net.C2S.SelectSkin then
		Guard.connect(Net.C2S.SelectSkin, {
			args = { Guard.T.string(32), Guard.T.optional(Guard.T.string(ID)) },
			rate = 2,
			burst = 4,
		}, onSelectSkin)
	end

	Guard.connect(Net.C2S.ClaimDaily, {
		args = {},
		rate = 1,
		burst = 2,
	}, onClaimDaily)

	-- (v6) Herd Contracts, Herd Pass, account rewards
	if Net.C2S.ClaimQuest then
		Guard.connect(
			Net.C2S.ClaimQuest,
			{ args = { Guard.T.string(32) }, rate = 2, burst = 6 },
			onClaimQuest
		)
	end
	if Net.C2S.RerollQuest then
		Guard.connect(
			Net.C2S.RerollQuest,
			{ args = { Guard.T.string(32) }, rate = 1, burst = 2 },
			onRerollQuest
		)
	end
	if Net.C2S.ClaimPassTier then
		Guard.connect(Net.C2S.ClaimPassTier, {
			args = { Guard.T.int(1, 30), Guard.T.enum({ "free", "premium" }) },
			rate = 4,
			burst = 10,
		}, onClaimPassTier)
	end
	if Net.C2S.ClaimAccountReward then
		Guard.connect(
			Net.C2S.ClaimAccountReward,
			{ args = { Guard.T.int(1, 100) }, rate = 2, burst = 6 },
			onClaimAccountReward
		)
	end
	DataService.addViewDecorator(decorate)
end

return ShopService
