--!strict
-- Network contract: every remote's name, direction and payload lives here.
-- The server creates ReplicatedStorage.Remotes via Net.setupServer(); clients
-- call Net.client(name). Validation of client payloads is the server's job
-- (see src/server/Services/*), never trust a client value.

local Net = {}

-- Client -> Server (RemoteEvent unless noted)
Net.C2S = {
	SelectClass = "SelectClass", -- (classId: string)
	SetReady = "SetReady", -- (ready: boolean)
	SetBotFill = "SetBotFill", -- (enabled: boolean) party-fill bots on/off for the next run
	Vote = "Vote", -- (optionIndex: number) for the currently open vote
	ChooseUpgrade = "ChooseUpgrade", -- (offerId: number, cardIndex: number)
	RerollUpgrade = "RerollUpgrade", -- (offerId: number)
	UseAbility = "UseAbility", -- (aimX: number, aimZ: number) world-space aim point
	UseSecondWind = "UseSecondWind", -- () while downed
	BuyShopItem = "BuyShopItem", -- (itemId: string) soft-currency shop
	Equip = "Equip", -- (slot: "trail" | "hat" | "tint", cosmeticId: string?)
	ClaimDaily = "ClaimDaily", -- ()
	PromptProduct = "PromptProduct", -- (key: string) asks server to prompt a dev product/pass
	SetPressure = "SetPressure", -- (modId: string, rank: number) party leader edits the Pressure board (GDD §3.7)
	-- v2 squad PvPvE (docs/ARCHITECTURE-v2.md)
	ExtractVote = "ExtractVote", -- (choice: "Extract" | "Stay" | "DoubleOrNothing")
	SwapGear = "SwapGear", -- (takeNew: boolean) true = equip the offered item, false = keep current
	BuyCartItem = "BuyCartItem", -- (poiId: number, index: number) Shop Cart POI, pending cheese only
	SelectPerk = "SelectPerk", -- (classId: string, perkId: string)
	ResetPerks = "ResetPerks", -- (classId: string) respec for cheese
	SelectAbility = "SelectAbility", -- (classId: string, abilityId: string)
	SelectSkin = "SelectSkin", -- (classId: string, skinId: string)
	SetSetting = "SetSetting", -- (key: string, value: boolean) allowlisted profile.settings flags, e.g. "hints"
}

-- Server -> Client
Net.S2C = {
	Snapshot = "Snapshot", -- UnreliableRemoteEvent: (buf: buffer) from Combat/SnapshotCodec
	Fx = "Fx", -- ({FxEvent}) batched visual events
	RunState = "RunState", -- (PublicRunState)
	VoteOpen = "VoteOpen", -- ({ kind: "route"|"bank"|"cycle", options: {any}, endsAt: number })
	VoteTally = "VoteTally", -- ({ [number]: number }) votes per option
	VoteClosed = "VoteClosed", -- (winningIndex: number)
	UpgradeOffer = "UpgradeOffer", -- ({ offerId: number, cards: {UpgradeDef}, rerollsLeft: number })
	PlayerHud = "PlayerHud", -- ({ hp, maxHp, level, xp, xpToNext, abilityReadyAt, downed, downedUntil, secondWinds })
	PartyHud = "PartyHud", -- ({ [userId]: { name, classId, hp, maxHp, downed, level } })
	Profile = "Profile", -- (ProfileView) safe subset of the profile for UI
	Lobby = "Lobby", -- ({ players: { [userId]: { classId, ready } }, startsAt: number? })
	Toast = "Toast", -- (text: string, kind: "info"|"good"|"bad"?)
	-- v2 squad PvPvE
	Match = "Match", -- ({ phase, stage, squads = {[1..4] = {...}}, routeChooser? })
	KillFeed = "KillFeed", -- ({ killer, victim, killerSquad, victimSquad, kind })
	Inventory = "Inventory", -- ({ weapon?, armor?, trinket?, swapOffer? })
	Extract = "Extract", -- ({ endsAt, options, votes, yourChoice? })
	ShopCart = "ShopCart", -- ({ poi, offers, prices })
	Results = "Results", -- ({ outcome, cheeseEarned, xpEarned, cycle, stage, bossesKilled, duration })
}

local UNRELIABLE = {
	[Net.S2C.Snapshot] = true,
}

local FOLDER = "Remotes"

local function allNames(): { string }
	local names = {}
	for _, n in Net.C2S do
		table.insert(names, n)
	end
	for _, n in Net.S2C do
		table.insert(names, n)
	end
	return names
end

function Net.setupServer(): Folder
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local folder = ReplicatedStorage:FindFirstChild(FOLDER) :: Folder?
	if not folder then
		local f = Instance.new("Folder")
		f.Name = FOLDER
		f.Parent = ReplicatedStorage
		folder = f
	end
	assert(folder, "Remotes folder missing")
	for _, name in allNames() do
		if not folder:FindFirstChild(name) then
			local r = Instance.new(if UNRELIABLE[name] then "UnreliableRemoteEvent" else "RemoteEvent")
			r.Name = name
			r.Parent = folder
		end
	end
	return folder
end

-- Works on both sides; waits on the client until the server has created it.
function Net.get(name: string): any
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local RunService = game:GetService("RunService")
	local folder = if RunService:IsServer() then Net.setupServer() else ReplicatedStorage:WaitForChild(FOLDER)
	return folder:WaitForChild(name)
end

return Net
