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
	UseAbility = "UseAbility", -- (aimX: number, aimZ: number, slot: number?) world-space aim point; iter5: slot 1-3 (default 1)
	UseSecondWind = "UseSecondWind", -- () while downed
	BuyShopItem = "BuyShopItem", -- (itemId: string) soft-currency shop
	Equip = "Equip", -- (slot: "trail" | "hat" | "tint", cosmeticId: string?)
	ClaimDaily = "ClaimDaily", -- ()
	PromptProduct = "PromptProduct", -- (key: string) asks server to prompt a dev product/pass
	SetPressure = "SetPressure", -- (modId: string, rank: number) party leader edits the Pressure board (GDD §3.7)
	-- v2 squad PvPvE (docs/ARCHITECTURE-v2.md)
	ExtractVote = "ExtractVote", -- (choice: "Extract" | "Stay" | "DoubleOrNothing" | "Overtime") iter5: "Overtime" only after the final boss
	SwapGear = "SwapGear", -- (takeNew: boolean) true = equip the offered item, false = keep current
	BuyCartItem = "BuyCartItem", -- (poiId: number, index: number) Shop Cart POI, pending cheese only
	SelectPerk = "SelectPerk", -- (classId: string, perkId: string)
	ResetPerks = "ResetPerks", -- (classId: string) respec for cheese
	SelectAbility = "SelectAbility", -- (classId: string, abilityId: string, slot: number?) iter5: slot 1-3 (default 1)
	SelectSkin = "SelectSkin", -- (classId: string, skinId: string)
	-- v4 (docs/V4-PLAN.md)
	Ping = "Ping", -- (kind: string, x: number, z: number) squad-only context ping
	QuickChat = "QuickChat", -- (index: number) preset line, no free text
	SetBusy = "SetBusy", -- (busy: boolean) in shop/perk tree: not pulled into a Ready countdown
	ClaimQuest = "ClaimQuest", -- (questId: string)
	RerollQuest = "RerollQuest", -- (questId: string) 1 free per day
	ClaimPassTier = "ClaimPassTier", -- (tier: number, track: "free" | "premium")
	ClaimPassAll = "ClaimPassAll", -- () iter6: claim every claimable Herd Pass tier (free, plus premium if owned) in one request; one summary toast
	PlayAgain = "PlayAgain", -- () teleport self (+ party) to a fresh server
	ClaimAccountReward = "ClaimAccountReward", -- (level: number)
	-- v5 (docs/V5-PLAN.md): Zombie-World-style progression
	BuyRank = "BuyRank", -- (stat: string) rinds -> stat rank (upgrade menu, V)
	BuyStallBuff = "BuyStallBuff", -- (stallId: string, buffId: string) whey buff at a stall pad
	BuyUltimate = "BuyUltimate", -- (id: string) Big Cheese Altar (stage 3+)
	Swap = "Swap", -- (dir: "toWhey" | "toRinds", amount: number)
	SetEvo = "SetEvo", -- (classId: string, stage: number)
	EquipCharm = "EquipCharm", -- (slot: number, charmId: number?)
	SalvageCharm = "SalvageCharm", -- (charmId: number)
	-- Liberty alignment (docs/iter/2/PLAN.md)
	SetTier = "SetTier", -- (tier: number) lobby leader picks the difficulty ladder tier (M2)
	SetPace = "SetPace", -- (pace: "normal" | "fast") iter6: lobby leader picks the match pace; saved in settings.pace
	SetSkipWave = "SetSkipWave", -- (pct: number) Early Horn threshold 0 | 50 | 70 | 90 (P saves it)
	CallHorn = "CallHorn", -- () call the next wave early when the horn is ready (M2)
	Prestige = "Prestige", -- (classId: string) prestige a level-30 class (P)
	UpgradeGem = "UpgradeGem", -- (gemId: number) spend Crumb Dust (P)
	FeedGems = "FeedGems", -- (targetId: number, ids: {number}) iter6: sacrifice up to 50 unequipped gems into one gem (their dust upgrades it)
	SalvageGems = "SalvageGems", -- (ids: {number}) iter6: bulk salvage up to 100 unequipped, unlocked gems to Crumb Dust
	LockGem = "LockGem", -- (gemId: number, locked: boolean) iter6: a locked gem cannot be salvaged or fed
	UnlockAscension = "UnlockAscension", -- (classId: string, node: number) (P; no-op if auto)
	GiftRinds = "GiftRinds", -- (targetUserId: number) give 100 rinds to a human squadmate (M2)
	-- iteration 4: auto-attack aim
	SetAimMode = "SetAimMode", -- (mode: "nearest" | "cursor") saved setting
	AimAt = "AimAt", -- (x: number, z: number) cursor/stick aim point, <= 15/s, only used in "cursor" mode
	SetSetting = "SetSetting", -- (key: string, value: boolean | string) allowlisted profile.settings flags, e.g. "hints"; iter5 strings: fx = "full"|"reduced"|"off", decor = "full"|"low"
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
	-- v4
	Storm = "Storm", -- ({cx, cz, r, toR, closeStart, closeEnd, dps, now})
	PingShown = "PingShown", -- ({by, squad, kind, x, z, t})
	Quests = "Quests", -- (quest view)
	Pass = "Pass", -- (Herd Pass view)
	Awards = "Awards", -- ({mvp, accolades, you})
	Leaderboards = "Leaderboards", -- ({[board] = {{name, value}}})
	Redeploy = "Redeploy", -- ({untilT})
	-- v5
	Wallet = "Wallet", -- ({rinds, whey, ranks, buffs, ultimates})
	Stalls = "Stalls", -- ({stalls = {{id, x, z, offers, class}}, altar = {x, z, open}, swap = {x, z}, zones})
	Results = "Results", -- ({ outcome, cheeseEarned, xpEarned, cycle, stage, bossesKilled, duration })
	-- iteration 5
	Meter = "Meter", -- ({ [heroId]: { name, squad, dmg, pveDmg, pvpDmg, heal, taken, kills, deaths } }) about 1 Hz; also in Results as `meter`
	Overtime = "Overtime", -- ({ active, wave, best, endsAt? }) overtime state for the HUD
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
