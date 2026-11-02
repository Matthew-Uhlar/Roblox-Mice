-- Runtime emulator, scenario (d): a developer product purchase. The client asks
-- for a prompt (C2S.PromptProduct), the server prompts through MarketplaceService,
-- then Roblox calls ProcessReceipt twice with the SAME PurchaseId (a retry):
-- the product is granted once, saved, and both calls return PurchaseGranted.
--
-- Test-only setup: Config/Monetization asset ids are still 0 (not created on the
-- Creator Dashboard), so the test gives `golden_s` a fake product id in the SERVER
-- context's config table.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")
local roblox = require("@lune/roblox")

local USER_ID = 5150
local PRODUCT_ID = 98765
local rt = Runtime.new({ root = ".", dt = 1 / 30 })
local Monetization = rt:serverModule("ReplicatedStorage.Shared.Config.Monetization")
local item
for _, it in Monetization.ALL do
	if it.key == "golden_s" then
		item = it
	end
end
assert(item, "golden_s product")
item.assetId = PRODUCT_ID
rt:startServer()
local DataService = rt:serverModule("ServerScriptService.Server.Services.DataService")
rt:advance(1)

T.describe("RuntimePurchase", function()
	local player, client
	T.it("the client's prompt request reaches MarketplaceService", function()
		player, client = rt:addPlayer({ userId = USER_ID, name = "Buyer" })
		rt:advance(4)
		local Remotes = rt:clientModule(client, "Client.Util.Remotes")
		rt:runIn(client, function()
			Remotes.fire(Remotes.C2S.PromptProduct, "golden_s")
		end)
		rt:advance(1)
		local prompt = rt.prompts[#rt.prompts]
		T.truthy(prompt, "a prompt was shown")
		T.eq(prompt.kind, "product")
		T.eq(prompt.id, PRODUCT_ID)
		T.eq(prompt.userId, USER_ID)
		rt:assertClean(nil, "prompt")
	end)

	T.it("ProcessReceipt twice with one PurchaseId grants once", function()
		local before = DataService.get(player).goldenCheese
		local receipt = {
			PlayerId = USER_ID,
			ProductId = PRODUCT_ID,
			PurchaseId = "purchase-0001",
			CurrencySpent = 99,
			CurrencyType = roblox.Enum.CurrencyType.Robux,
			PlaceIdWherePurchased = rt.config.placeId,
		}
		-- Tight timing on purpose: the profile load just wrote this key and the retry
		-- comes at once. DataService paces writes (1 per key per 6 s, Roblox's limit),
		-- so this must not produce DataStore queue warnings.
		local d1 = rt:processReceipt(receipt)
		T.eq(d1, roblox.Enum.ProductPurchaseDecision.PurchaseGranted, "first call")
		local after1 = DataService.get(player).goldenCheese
		T.truthy(after1 > before, string.format("granted: %d -> %d", before, after1))
		local d2 = rt:processReceipt(receipt)
		T.eq(d2, roblox.Enum.ProductPurchaseDecision.PurchaseGranted, "retry")
		T.eq(DataService.get(player).goldenCheese, after1, "not granted twice")
		-- durable before the ack
		local saved = rt:dataStoreValue("TrunkfallProfiles_v1", "u_" .. USER_ID)
		T.eq(saved.data.goldenCheese, after1, "saved")
		rt:advance(1)
		local thanks = 0
		for _, args in client.inbox.Toast and client.inbox.Toast.list or {} do
			if string.find(tostring(args[1]), "Thank you", 1, true) then
				thanks += 1
			end
		end
		T.eq(thanks, 1, "one thank-you toast (the retry grants nothing)")
		rt:assertClean(nil, "receipt")
	end)

	T.it("a receipt for a player who left is NotProcessedYet", function()
		rt:removePlayer(player)
		rt:runUntil(function()
			local v = rt:dataStoreValue("TrunkfallProfiles_v1", "u_" .. USER_ID)
			return v and v.lock == nil
		end, 15)
		T.eq(rt:dataStoreValue("TrunkfallProfiles_v1", "u_" .. USER_ID).lock, nil, "released on leave")
		local d =
			rt:processReceipt({ PlayerId = USER_ID, ProductId = PRODUCT_ID, PurchaseId = "purchase-0002" })
		T.eq(d, roblox.Enum.ProductPurchaseDecision.NotProcessedYet)
		rt:assertClean(nil, "left")
	end)
end)

return T.finish()
