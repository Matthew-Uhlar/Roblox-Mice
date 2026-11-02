-- Runtime emulator, extra scenario: a veteran who owns every game pass (VIP, ...)
-- and has a rich saved profile plays with a new friend. Covers the paths the solo
-- scenario never reaches: pass verification + perks, CosmeticsService (trail, hat,
-- tint, nametag, chat tag), the client's TextChatService.OnIncomingMessage hook,
-- the soft-currency shop and Equip through ShopUI, the daily reward, and the party
-- leader's Pressure board feeding the run. Zero errors, gaps, unexpected warnings
-- and DataStore queue warnings.
--
-- Test-only setup: fake asset ids for every Config/Monetization item (they are 0
-- until the Creator Dashboard step) in the SERVER context, a seeded profile, and
-- the Driver.powerUp / WAVE_SECONDS knobs.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")
local Driver = require("../runtime/Driver")
local Inst = require("../runtime/Instance")

local VET, FRIEND = 6001, 6002
local rt = Runtime.new({ root = ".", dt = 1 / 30 })
local Monetization = rt:serverModule("ReplicatedStorage.Shared.Config.Monetization")
rt.config.ownedPasses[VET] = {}
local nextId = 7000
for _, item in Monetization.ALL do
	nextId += 1
	item.assetId = if item.kind == "subscription" then "EXP-" .. nextId else nextId
	if item.kind == "pass" then
		rt.config.ownedPasses[VET][nextId] = true
	end
end
local ProfileSchema = rt:serverModule("ReplicatedStorage.Shared.Data.ProfileSchema")
local profile = ProfileSchema.default()
profile.cheese = 250000
profile.goldenCheese = 9000
profile.level = 30
profile.pressure = { unlocked = true, highestCleared = 4, board = {} }
for _, id in { "trail_crumbs", "hat_party", "tint_mint" } do
	profile.cosmetics[id] = true
end
profile.equipped = { trail = "trail_crumbs", hat = "hat_party", tint = "tint_mint" }
rt:seedDataStore("TrunkfallProfiles_v1", "u_" .. VET, { data = profile, savedAt = 0 })
rt:startServer()
local RD = rt:serverModule("ServerScriptService.Server.Services.RunDirector")
local DataService = rt:serverModule("ServerScriptService.Server.Services.DataService")
RD.WAVE_SECONDS = 15
Driver.powerUp(rt, 25)
rt:advance(1)

local function chatHook(client: any): any
	local tcs = rt.game:GetService("TextChatService")
	local cbs = Inst.D[tcs].extra.callbacks and Inst.D[tcs].extra.callbacks.OnIncomingMessage
	return cbs and cbs[client]
end

-- Delivers a chat message from `from` to `client`'s OnIncomingMessage hook.
local function incoming(client: any, from: any, text: string): any
	local hook = chatHook(client)
	assert(hook and hook.fn, "client has no OnIncomingMessage hook")
	local msg = rt:runIn(client, function()
		local m = Inst.make("TextChatMessage")
		local source = Inst.make("TextSource")
		Inst.rawSet(Inst.D[source], "UserId", from.UserId)
		Inst.rawSet(Inst.D[m], "TextSource", source)
		Inst.rawSet(Inst.D[m], "PrefixText", from.Name .. ":")
		Inst.rawSet(Inst.D[m], "Text", text)
		return m
	end)
	return rt:runIn(client, hook.fn, msg)
end

T.describe("RuntimeVeteran", function()
	local vet, vc, friend, fc
	T.it("passes are verified; cosmetics and the VIP chat tag are drawn", function()
		vet, vc = rt:addPlayer({ userId = VET, name = "Vet" })
		friend, fc = rt:addPlayer({ userId = FRIEND, name = "Friend" })
		rt:advance(10)
		T.eq(vet:GetAttribute("ChatTag"), "VIP", "VIP chat tag attribute")
		local props = incoming(fc, vet, "hi")
		T.truthy(
			props and string.find(props.PrefixText, "[VIP]", 1, true),
			"friend sees [VIP] before Vet's name"
		)
		T.eq(incoming(vc, friend, "hey"), nil, "no tag for the friend")
		local cos = vet.Character:FindFirstChild("TrunkfallCosmetics")
		T.truthy(cos, "cosmetics folder on the character")
		T.truthy(cos:FindFirstChildWhichIsA("Trail", true), "trail")
		rt:assertClean(nil, "veteran join")
	end)

	T.it("shop: buy a cosmetic with cheese and equip it through ShopUI", function()
		local before = DataService.get(vet).cheese
		local owned = 0
		for _ in DataService.get(vet).cosmetics do
			owned += 1
		end
		rt:click(vc, Driver.findButton(rt, vc, "TrunkfallLobby", "Shop"))
		rt:advance(0.5)
		local tab = Driver.findButton(rt, vc, "TrunkfallShop", "Cosmetics")
		T.truthy(tab, "Cosmetics tab")
		rt:click(vc, tab)
		rt:advance(0.5)
		local buy = Driver.findButton(rt, vc, "TrunkfallShop", "🧀")
		T.truthy(buy, "a cheese price button")
		rt:click(vc, buy)
		rt:advance(1)
		T.truthy(DataService.get(vet).cheese < before, "cheese spent")
		local after = 0
		for _ in DataService.get(vet).cosmetics do
			after += 1
		end
		T.eq(after, owned + 1, "one more cosmetic owned")
		local equip = Driver.findButton(rt, vc, "TrunkfallShop", "Equip")
		T.truthy(equip, "Equip button")
		rt:click(vc, equip)
		rt:advance(1)
		T.truthy((rt.serverInbox.Equip and rt.serverInbox.Equip.count or 0) > 0, "Equip sent")
		local close = Driver.findButton(rt, vc, "TrunkfallShop", "✕")
		if close then
			rt:click(vc, close)
		end
		rt:advance(1)
		rt:assertClean(nil, "shop")
	end)

	T.it("daily reward through the shop header", function()
		rt:click(fc, Driver.findButton(rt, fc, "TrunkfallLobby", "Shop"))
		rt:advance(0.5)
		local daily = Driver.findButton(rt, fc, "TrunkfallShop", "Claim daily")
		T.truthy(daily, "daily button for the friend")
		rt:click(fc, daily)
		rt:advance(1)
		local close = Driver.findButton(rt, fc, "TrunkfallShop", "✕")
		if close then
			rt:click(fc, close)
		end
		T.eq(DataService.get(friend).daily.streak, 1, "streak")
		rt:assertClean(nil, "daily")
	end)

	T.it("the leader sets Pressure and the run uses it", function()
		rt:click(vc, Driver.findButton(rt, vc, "TrunkfallLobby", "READY"))
		rt:advance(1)
		local edit = Driver.findButton(rt, vc, "TrunkfallLobby", "board")
		T.truthy(edit, "Pressure board button")
		rt:click(vc, edit)
		rt:advance(0.5)
		local plus = Driver.findButton(rt, vc, "TrunkfallLobby", "+")
		T.truthy(plus, "+ rank button")
		rt:click(vc, plus)
		rt:advance(1)
		local State = rt:clientModule(fc, "Client.Controllers.State")
		T.truthy(State.get("lobby").pressure.points > 0, "friend sees the Pressure points")
		for _, pair in { { vet, vc }, { friend, fc } } do
			rt:setWalker(pair[1], Driver.circleWalker(rt, 16, 10))
			Driver.autoplay(rt, pair[2], function(kind)
				return if kind == "route" then "risk" elseif kind == "bank" then "Continue" else nil
			end)
		end
		local ready = Driver.findButton(rt, fc, "TrunkfallLobby", "READY")
		if ready then
			rt:click(fc, ready)
		end
		T.truthy(
			rt:runUntil(function()
				return RD.getPhase() == "Waves"
			end, 40),
			"run started"
		)
		local pub = vc.inbox.RunState.last[1]
		T.truthy(pub.pressurePoints > 0, "run has Pressure")
		T.truthy(
			rt:runUntil(function()
				return RD.getPhase() == "BankVote"
			end, 120),
			"stage 1 cleared"
		)
		rt:assertClean(nil, "pressure run")
		T.eq(#rt.dataStoreThrottles, 0, "no DataStore queueing")
	end)
end)

return T.finish()
