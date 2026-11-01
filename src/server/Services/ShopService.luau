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
-- Every handler pushes the updated profile view (Net.S2C.Profile) and a Toast.
-- A successful Equip redraws the character's cosmetics (CosmeticsService.refresh).

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
	end
	return itemId
end

local function onBuy(player: Player, itemId: string)
	if not Shop.parse(itemId) then
		fail(player, "bad_id")
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
	else
		toast(player, "Unlocked: " .. itemName(itemId), "good")
	end
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
			Guard.T.enum({ "trail", "hat", "tint" }),
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

	Guard.connect(Net.C2S.ClaimDaily, {
		args = {},
		rate = 1,
		burst = 2,
	}, onClaimDaily)
end

return ShopService
