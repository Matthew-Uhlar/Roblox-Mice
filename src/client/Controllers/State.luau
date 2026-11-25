--!strict
-- Tiny client store. Holds the latest server-sent state and fires a change
-- signal per key. UIs subscribe instead of listening to remotes directly.
--
-- Keys:
--   run      PublicRunState                (Net.S2C.RunState)
--   hud      PlayerHud                     (Net.S2C.PlayerHud)
--   party    { [userId]: PartyEntry }      (Net.S2C.PartyHud, keys normalised to numbers;
--            bots have ids <= -1000, see Shared.Util.Ids; Studio test players are -1..-8)
--   profile  ProfileView                   (Net.S2C.Profile)
--   lobby    { players = { [userId]: { name, classId, ready, inRun?, isBot?, playAgain?,
--                                      sittingOut?, needsReady?, leader? } },
--              startsAt?, runActive, autoStart?, botFill?, botFillAny?, botCount?,
--              pressure = { board = {[modId]: rank}, points, leaderId?, unlocked, youUnlocked } }
--            (Net.S2C.Lobby; see State.normalisePressure)
--   vote     { kind, options, endsAt, tally, myPick, closed, winner } | nil (VoteOpen/Tally/Closed)
--   offers   { { offerId, cards, rerollsLeft, queued } } (Net.S2C.UpgradeOffer; server sends one
--            offer at a time plus `queued`, the client tolerates several)
--   results  Results payload | nil         (Net.S2C.Results)
--   boss     { id, bossId, def, hpFrac } | nil  (set by HordeRenderer from snapshots)
--
-- v2 squad PvPvE (docs/ARCHITECTURE-v2.md, Network table):
--   match      { phase, stage, squads = { Scoreboard.Squad } (by id), mySquad?, routeChooser?,
--                bounties = { [idKey]: true }, champions = {{id, champId, x, z, hpFrac, lair}},
--                buffs = {{kind, untilT, stat?, mul?}} }               (Net.S2C.Match)
--   killfeed   { entries = { {killer, victim, killerSquad, victimSquad, kind, at, seq} },
--                streaks = KillStreaks }                              (Net.S2C.KillFeed)
--   inventory  { weapon?, armor?, trinket?, swapOffer? = {item, slot, endsAt} } (Net.S2C.Inventory)
--   extract    { endsAt, options, votes = {[choice]: n}, yourChoice?, closed? } | nil (Net.S2C.Extract)
--   shopCart   { poi, offers = {item}, prices = {n}, sold = {[i]: true} } | nil     (Net.S2C.ShopCart)
--   lobby.squads  { [1..4] = { id, name, color, members = {id} } }  (Net.S2C.Lobby `squads`,
--                or derived from players[id].squad)
--   profile.classes  { [classId]: {xp, level, perks, ability, skin, perkPoints?} } (Net.S2C.Profile)
--   classesAtStart   copy of profile.classes when a run starts (ResultsUI level-up animation)
--   scoreboardOpen   boolean (Tab / View / tap on the strip)
--
-- v4 (docs/V4-PLAN.md):
--   storm        HudMath.Storm | nil (Net.S2C.Storm, or Fx t = "storm" via State.setStorm;
--                closeStart/closeEnd moved onto the State.serverNow clock)
--   pings        { HudMath.PingMark }  live squad pings / quick-chat lines (Net.S2C.PingShown)
--   quests       raw Herd Contracts view (Net.S2C.Quests; read with Util/Progression.quests)
--   pass         raw Herd Pass view (Net.S2C.Pass; Util/Progression.pass)
--   awards       raw {mvp, accolades, you} (Net.S2C.Awards) for the results screen
--   leaderboards { [board] = {{name, value}} } (Net.S2C.Leaderboards)
--   redeploy     { untilT } | nil (Net.S2C.Redeploy)
--   meter        { [heroId]: {name, squad, dmg, pveDmg, pvpDmg, heal, taken, kills, deaths} } | nil
--                (Net.S2C.Meter, iteration 5; Util/MeterModel reads it)
--   meterOpen    boolean (Tab / hold Back / the 📊 button)
--   overtime     { active, wave, best, endsAt? } | nil (Net.S2C.Overtime, iteration 5)
--   gfx          { fx = "full"|"reduced"|"off", decor = "full"|"low", models = "detailed"|"classic" } (Util/GfxSettings)
--   profileAt    os.clock() when the last profile arrived (boost timers tick from it)
--   busy         boolean: shop / perk tree / Herd panel open (Net.C2S.SetBusy sent on change)
--
-- v5 (docs/V5-PLAN.md, iteration 1 §D):
--   wallet       {rinds, whey, ranks = {[stat] = n}, buffs = {ids}, ultimates = {ids}, rindsEarned}
--                (Net.S2C.Wallet; nil outside a run)
--   stalls       {stalls = {{id, x, z, offers, class}}, altar = {x, z, open}, swap = {x, z}}
--                (Net.S2C.Stalls; nil outside a run)

local Players = game:GetService("Players")

local Client = script.Parent.Parent
local Signal = require(Client.Util.Signal)
local Remotes = require(Client.Util.Remotes)
local Format = require(Client.Util.Format)
local Scoreboard = require(Client.Util.Scoreboard)
local KillStreaks = require(Client.Util.KillStreaks)
local HudMath = require(Client.Util.HudMath)
local AbilitySlots = require(Client.Util.AbilitySlots)
local GfxSettings = require(Client.Util.GfxSettings)
local Ids = require(
	game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Ids")
)

local KILLFEED_MAX = 6
local PINGS_MAX = 12

local State = {}

local data: { [string]: any } = {}
local signals: { [string]: any } = {}

-- Fired for transient Toast messages: (text: string, kind: "info"|"good"|"bad")
State.toast = Signal.new()

local function signalFor(key: string): any
	local s = signals[key]
	if not s then
		s = Signal.new()
		signals[key] = s
	end
	return s
end

function State.get(key: string): any
	return data[key]
end

-- Sets a value and always notifies subscribers (tables are often mutated in place).
function State.set(key: string, value: any)
	data[key] = value
	signalFor(key):Fire(value)
end

-- Subscribes to a key. If `fireNow`, calls fn immediately with the current value.
-- Returns a disconnect function.
function State.subscribe(key: string, fn: (any) -> (), fireNow: boolean?): () -> ()
	local conn = signalFor(key):Connect(fn)
	if fireNow then
		task.spawn(fn, data[key])
	end
	return function()
		conn:Disconnect()
	end
end

function State.serverNow(): number
	return workspace:GetServerTimeNow()
end

function State.localUserId(): number
	local p = Players.LocalPlayer
	return if p then p.UserId else 0
end

function State.phase(): string?
	local run = data.run
	return if type(run) == "table" then run.phase else nil
end

-- Bot teammates (AI fill) have ids in the Ids.isBot band (<= -1000) and/or
-- `isBot = true` on their Lobby/PartyHud entry. Studio test players have small
-- negative UserIds (-1..-8) and are humans. Policy: always label bots in the UI.
function State.isBot(id: number?, entry: any): boolean
	if type(entry) == "table" and entry.isBot == true then
		return true
	end
	return Ids.isBot(id)
end

function State.inCombat(): boolean
	local p = State.phase()
	return p == "Waves" or p == "Boss"
end

function State.inLobby(): boolean
	local p = State.phase()
	return p == nil or p == "Lobby"
end

-- Ability cooldown tracking: PlayerHud gives readyAt server times (slot 1 =
-- abilityReadyAt; iteration 5: abilityReadyAts per slot, maybe the effective
-- abilityCooldowns), so a total is inferred when a new readyAt arrives.
-- ASSUMPTION: abilityReadyAt / downedUntil use workspace:GetServerTimeNow().
local cdTrack = AbilitySlots.newTrack()

-- Returns (remainingSeconds, totalSeconds) for a slot (default 1); remaining
-- is 0 when ready.
function State.abilityCooldown(slot: number?): (number, number)
	return AbilitySlots.remaining(cdTrack, slot or 1, State.serverNow())
end

-- iteration 5 (A3): the live ability slots of this run, in slot order:
-- { {slot, id?} }. The server's HUD list wins; else the profile loadout of
-- the selected class (slot count by class level / Prestige).
function State.abilitySlots(): { { slot: number, id: string? } }
	local hud = data.hud
	local ids = AbilitySlots.hudIds(hud)
	local n = AbilitySlots.hudCount(hud)
	local loadout: { [number]: string? } = {}
	if n == nil then
		local classId = State.myClassId()
		local p = data.profile
		local block = if type(p) == "table"
				and type(p.classes) == "table"
				and classId
			then p.classes[classId]
			else nil
		n = AbilitySlots.classCount(block)
		loadout = AbilitySlots.loadout(block)
		-- only slots that hold an ability (slot 1 always: nil = the base)
		local filled = 1
		for i = 2, n :: number do
			if loadout[i] ~= nil then
				filled = i
			end
		end
		n = filled
	end
	local out = {}
	for i = 1, n :: number do
		table.insert(out, { slot = i, id = ids[i] or loadout[i] })
	end
	return out
end

-- The local player's class: the lobby entry, else the profile's selection.
function State.myClassId(): string?
	local lobby = data.lobby
	local me = State.localUserId()
	if type(lobby) == "table" and type(lobby.players) == "table" then
		local e = lobby.players[me] or lobby.players[tostring(me)]
		if type(e) == "table" and e.classId ~= nil then
			return tostring(e.classId)
		end
	end
	local p = data.profile
	if type(p) == "table" and p.selectedClass ~= nil then
		return tostring(p.selectedClass)
	end
	return nil
end

-- iteration 5 Phase B #3: graphics settings. Applies at once (State "gfx")
-- and saves with SetSetting(key, value).
local gfxPickedAt = -math.huge
function State.gfx(): GfxSettings.Gfx
	local g = data.gfx
	if type(g) == "table" then
		return g
	end
	return GfxSettings.fromProfile(data.profile)
end

function State.setGfx(key: string, value: string)
	local g = table.clone(State.gfx())
	if key == "fx" then
		g.fx = GfxSettings.fx(value)
	elseif key == "decor" then
		g.decor = GfxSettings.decor(value)
	elseif key == "models" then -- iteration 7 (team Mesh)
		g.models = GfxSettings.models(value)
	else
		return
	end
	gfxPickedAt = os.clock()
	State.set("gfx", g)
	if Remotes.C2S.SetSetting then
		Remotes.fire(Remotes.C2S.SetSetting, key, (g :: any)[key])
	end
end

-- iteration 7 (§B2): game-feel settings (Util/GameFeel): "shake" (screen shake)
-- and "castSfx" (cast sounds), "full" | "low" | "off". Saved with SetSetting
-- when the server allowlists the key (Shared.Data.Settings.STRING_KEYS), else
-- kept for this session only (State "feel" holds the local picks).
local function settingAllowed(key: string, value: string): boolean
	local ok, allowed = pcall(function()
		local shared = game:GetService("ReplicatedStorage"):FindFirstChild("Shared")
		local dataFolder = shared and shared:FindFirstChild("Data")
		local mod = dataFolder and dataFolder:FindFirstChild("Settings")
		local Settings = if mod and mod:IsA("ModuleScript") then require(mod) :: any else nil
		local keys = Settings and Settings.STRING_KEYS
		return type(keys) == "table" and type(keys[key]) == "table" and table.find(keys[key], value) ~= nil
	end)
	return ok and allowed == true
end

function State.feel(): { shake: string, castSfx: string, castMode: string, smartCast: boolean }
	local GameFeel = require(Client.Util.GameFeel) :: any
	return GameFeel.fromProfile(data.profile, data.feel)
end

function State.setFeel(key: string, value: any)
	if key == "smartCast" then -- iteration 8: boolean setting (Data/Settings BOOL_KEYS)
		local cur = if type(data.feel) == "table" then table.clone(data.feel) else {}
		cur.smartCast = value == true
		State.set("feel", cur)
		if Remotes.C2S.SetSetting then
			Remotes.fire(Remotes.C2S.SetSetting, "smartCast", value == true)
		end
		return
	end
	if key ~= "shake" and key ~= "castSfx" and key ~= "castMode" then
		return
	end
	local GameFeel = require(Client.Util.GameFeel) :: any
	local v = if key == "shake"
		then GameFeel.shake(value)
		elseif key == "castMode" then GameFeel.castMode(value)
		else GameFeel.cast(value)
	local cur = if type(data.feel) == "table" then table.clone(data.feel) else {}
	cur[key] = v
	State.set("feel", cur)
	if Remotes.C2S.SetSetting and settingAllowed(key, v) then
		Remotes.fire(Remotes.C2S.SetSetting, key, v)
	end
end

-- ===== iteration 8 (team Client): keybinds (Util/Keybinds, Shared Data/Settings) =====
-- State "bindsPick" = the local binds string (wins over profile.settings.binds).
-- Consumers re-read State.bindKey(action) when "bindsPick" or "profile" changes.
local bindsCfg: any = nil
function State.bindsCfg(): any
	if bindsCfg == nil then
		local ok, mod = pcall(function()
			local shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared", 10)
			local dataFolder = shared and shared:FindFirstChild("Data")
			local m = dataFolder and dataFolder:FindFirstChild("Settings")
			return if m and m:IsA("ModuleScript") then require(m) :: any else nil
		end)
		bindsCfg = if ok and type(mod) == "table" and mod.decodeBinds then mod else false
	end
	return bindsCfg or nil
end

function State.binds(): { [string]: string }
	local cfg = State.bindsCfg()
	if not cfg then
		return {}
	end
	local Keybinds = require(Client.Util.Keybinds) :: any
	return Keybinds.fromProfile(cfg, data.profile, data.bindsPick)
end

-- Saves a full map (nil = reset to the defaults).
local BINDS_SEND_DELAY = 0.8
local bindsSendToken = 0
function State.setBinds(map: { [string]: string }?)
	local cfg = State.bindsCfg()
	if not cfg then
		return
	end
	local Keybinds = require(Client.Util.Keybinds) :: any
	local str = if map then Keybinds.encode(cfg, map) else nil
	State.set("bindsPick", str or cfg.DEFAULT_BINDS)
	-- (QC iteration 8) trailing debounce: quick rebinds send only the last string,
	-- so the SetSetting rate limit (2/s) never drops the final save
	bindsSendToken += 1
	local my = bindsSendToken
	task.delay(BINDS_SEND_DELAY, function()
		if my == bindsSendToken and Remotes.C2S.SetSetting then
			Remotes.fire(Remotes.C2S.SetSetting, "binds", data.bindsPick or cfg.DEFAULT_BINDS)
		end
	end)
end

-- The Enum.KeyCode bound to an action, or `fallback`.
function State.bindKey(action: string, fallback: Enum.KeyCode?): Enum.KeyCode?
	local name = State.binds()[action]
	if type(name) == "string" then
		local ok, kc = pcall(function()
			return (Enum.KeyCode :: any)[name]
		end)
		if ok and kc then
			return kc
		end
	end
	return fallback
end

-- Short label of an action's key ("V", ",", "LShift"), for key hints.
function State.bindLabel(action: string, fallback: string?): string
	local name = State.binds()[action]
	if type(name) ~= "string" then
		return fallback or "?"
	end
	local Keybinds = require(Client.Util.Keybinds) :: any
	return Keybinds.keyLabel(name)
end

-- Subscribes fn to bind changes (local pick or profile). Returns an unsubscribe.
function State.onBinds(fn: () -> ()): () -> ()
	local last = ""
	local function check()
		local m = State.binds()
		local parts = {}
		for k, v in m do
			table.insert(parts, k .. "=" .. v)
		end
		table.sort(parts)
		local sig = table.concat(parts, ",")
		if sig ~= last then
			last = sig
			fn()
		end
	end
	local a = State.subscribe("bindsPick", check)
	local b = State.subscribe("profile", check)
	last = ""
	return function()
		a()
		b()
	end
end
-- ===== end iteration 8 keybinds =====

local function onHud(hud: any)
	if type(hud) ~= "table" then
		return
	end
	AbilitySlots.observe(cdTrack, AbilitySlots.readyAts(hud), State.serverNow(), AbilitySlots.cooldowns(hud))
	State.set("hud", hud)
end

-- Votes per option, tolerant of string keys from the network.
local function normaliseTally(t: any): { [number]: number }
	local out = {}
	if type(t) ~= "table" then
		return out
	end
	for k, v in t do
		local i = tonumber(k)
		if i then
			out[i] = tonumber(v) or 0
		end
	end
	return out
end

-- Local optimistic vote pick (the server tally is authoritative).
function State.castVote(option: number)
	local v = data.vote
	if type(v) ~= "table" or v.closed then
		return
	end
	v.myPick = option
	Remotes.fire(Remotes.C2S.Vote, option)
	State.set("vote", v)
end

function State.removeOffer(offerId: number)
	local q = data.offers or {}
	for i, o in q do
		if o.offerId == offerId then
			table.remove(q, i)
			break
		end
	end
	State.set("offers", q)
end

-- Lobby Pressure block (GDD §3.7), tolerant of a missing / malformed payload.
-- Ranks are display-only here; the server validates every SetPressure.
function State.normalisePressure(p: any): { [string]: any }
	local board: { [string]: number } = {}
	local points = 0
	if type(p) == "table" and type(p.board) == "table" then
		for k, v in p.board do
			local r = tonumber(v)
			if type(k) == "string" and r and r == r and r > 0 then
				board[k] = math.floor(r)
			end
		end
	end
	if type(p) == "table" then
		local n = tonumber(p.points)
		if n and n == n then
			points = math.max(0, math.floor(n))
		end
	end
	return {
		board = board,
		points = points,
		leaderId = if type(p) == "table" then tonumber(p.leaderId) else nil,
		unlocked = type(p) == "table" and p.unlocked == true,
		youUnlocked = type(p) == "table" and p.youUnlocked == true,
		-- v4 Rookie Run: the server hides the board from rookies (LobbyService)
		hidden = type(p) == "table" and p.hidden == true,
		known = type(p) == "table",
	}
end

-- Am I the party leader (the one who sets Pressure)?
function State.isLeader(): boolean
	local lobby = data.lobby
	return type(lobby) == "table"
		and type(lobby.pressure) == "table"
		and lobby.pressure.leaderId ~= nil
		and lobby.pressure.leaderId == State.localUserId()
end

----------------------------------------------------------------------
-- v2: squads, kill feed, gear, extraction, shop cart, class progression
----------------------------------------------------------------------

-- My squad id in the match (or the lobby before it starts), else nil.
function State.mySquad(): number?
	local m = data.match
	if type(m) == "table" and m.mySquad then
		return m.mySquad
	end
	local lobby = data.lobby
	if type(lobby) == "table" and lobby.yourSquad then
		return lobby.yourSquad
	end
	if type(lobby) == "table" and type(lobby.squads) == "table" then
		local me = State.localUserId()
		for id, sq in lobby.squads do
			if table.find(sq.members, me) then
				return id
			end
		end
	end
	return nil
end

-- Squad id of any participant (match first, then the lobby), else nil.
function State.squadOf(id: number?): number?
	if id == nil then
		return nil
	end
	local m = data.match
	if type(m) == "table" and type(m.squads) == "table" then
		local s = Scoreboard.squadOf(m.squads, id)
		if s then
			return s
		end
	end
	local lobby = data.lobby
	if type(lobby) == "table" and type(lobby.squads) == "table" then
		for sid, sq in lobby.squads do
			if table.find(sq.members, id) then
				return sid
			end
		end
	end
	return nil
end

-- Squad entry (Scoreboard.Squad) by id from the match, else nil.
function State.squad(id: number?): any
	local m = data.match
	if id == nil or type(m) ~= "table" then
		return nil
	end
	for _, s in m.squads do
		if s.id == id then
			return s
		end
	end
	return nil
end

-- Best display name for a participant id (party, lobby, Players, bot model).
function State.nameOf(id: any): string
	if type(id) == "string" and tonumber(id) == nil then
		return id -- the server already sent a name
	end
	local n = tonumber(id)
	if n == nil then
		return "???"
	end
	local party = data.party
	if type(party) == "table" and type(party[n]) == "table" and party[n].name then
		return tostring(party[n].name)
	end
	local lobby = data.lobby
	if type(lobby) == "table" and type(lobby.players) == "table" then
		local e = lobby.players[n]
		if type(e) == "table" and e.name then
			return tostring(e.name)
		end
	end
	local m = data.match
	if type(m) == "table" and type(m.names) == "table" and m.names[n] then
		return tostring(m.names[n])
	end
	if n > 0 or not Ids.isBot(n) then
		local p = Players:GetPlayerByUserId(n)
		if p then
			return p.DisplayName
		end
	end
	local bots = workspace:FindFirstChild("Bots")
	if bots then
		for _, model in bots:GetChildren() do
			if model:GetAttribute("BotId") == n then
				local dn = model:GetAttribute("DisplayName")
				return Format.botName(if type(dn) == "string" then dn else "Bot")
			end
		end
	end
	return if Ids.isBot(n) then "🤖 Bot" else "Hero"
end

-- Is the match a v2 squad match? (Net.S2C.Match seen this run.)
function State.isSquadMatch(): boolean
	return type(data.match) == "table"
end

-- Has `id` a bounty? In a squad match only the server's Match.bounties counts
-- (QC-A M4); otherwise the kill-feed streaks are a fallback.
function State.hasBounty(id: any): boolean
	if id == nil then
		return false
	end
	local m = data.match
	if type(m) == "table" then
		return type(m.bounties) == "table" and m.bounties[tostring(id)] == true
	end
	local kf = data.killfeed
	return type(kf) == "table" and KillStreaks.hasBounty(kf.streaks, id)
end

-- Every bounty holder key (strings): Match.bounties in a squad match, else the
-- kill-feed streaks.
function State.bountyHolders(): { string }
	local seen: { [string]: boolean } = {}
	local out = {}
	local m = data.match
	if type(m) == "table" and type(m.bounties) == "table" then
		for k in m.bounties do
			if not seen[k] then
				seen[k] = true
				table.insert(out, k)
			end
		end
	end
	local kf = data.killfeed
	if type(m) ~= "table" and type(kf) == "table" then
		for _, k in KillStreaks.holders(kf.streaks) do
			if not seen[k] then
				seen[k] = true
				table.insert(out, k)
			end
		end
	end
	return out
end

-- Per-class progression block from the profile, with safe defaults.
function State.classState(classId: string?): { [string]: any }
	local p = data.profile
	local c = if type(p) == "table"
			and type(p.classes) == "table"
			and classId
		then p.classes[classId]
		else nil
	local t = if type(c) == "table" then c else {}
	local perks: { [string]: boolean } = {}
	if type(t.perks) == "table" then
		for k, v in t.perks do
			if v == true then
				perks[tostring(k)] = true
			elseif type(v) == "string" then
				perks[v] = true -- array form {perkId…}
			end
		end
	end
	local function idSet(v: any): { [string]: boolean }?
		if type(v) ~= "table" then
			return nil
		end
		local out: { [string]: boolean } = {}
		for k, x in v do
			if type(x) == "string" then
				out[x] = true
			elseif x == true then
				out[tostring(k)] = true
			end
		end
		return out
	end
	-- R3 profile view: classes[id] = {level, xp, xpToNext, maxLevel, perks, perkPoints,
	-- perkPointsFree, ability, skin, mastery, respecCost, unlockedAbilities, unlockedSkins}.
	return {
		xp = math.max(0, tonumber(t.xp) or 0),
		level = math.max(1, math.floor(tonumber(t.level) or 1)),
		perks = perks,
		perkPoints = tonumber(t.perkPoints),
		perkPointsFree = tonumber(t.perkPointsFree),
		xpToNext = tonumber(t.xpToNext),
		maxLevel = tonumber(t.maxLevel),
		respecCost = tonumber(t.respecCost),
		unlockedAbilities = idSet(t.unlockedAbilities),
		unlockedSkins = idSet(t.unlockedSkins),
		ability = if t.ability ~= nil then tostring(t.ability) else nil,
		-- iteration 5 (A3): slot loadout {[slot]: id?} and the unlocked slot count
		abilities = AbilitySlots.loadout(t),
		abilitySlots = AbilitySlots.classCount(t),
		slot4 = if type(t.slot4) == "table" then t.slot4 else nil, -- (iteration 6) {prestige, node}
		skin = if t.skin ~= nil then tostring(t.skin) else nil,
		mastery = if type(t.mastery) == "string" then t.mastery else nil,
		-- iteration 2 (P): Prestige; the shown level restarts at 1 after each one
		prestige = math.max(0, math.floor(tonumber(t.prestige) or 0)),
		displayLevel = tonumber(t.displayLevel),
		prestigeXp = tonumber(t.prestigeXp),
		prestigeXpToNext = tonumber(t.prestigeXpToNext),
		known = type(c) == "table",
	}
end

-- Extraction vote (optimistic pick; the server's yourChoice wins).
function State.castExtract(choice: string)
	local e = data.extract
	if type(e) ~= "table" or e.closed then
		return
	end
	e.myPick = choice
	e.myPickAt = os.clock()
	Remotes.fire(Remotes.C2S.ExtractVote, choice)
	State.set("extract", e)
end

-- Gear swap answer: true = equip the offered item, false = keep the current one.
function State.answerSwap(take: boolean): boolean
	local inv = data.inventory
	if type(inv) ~= "table" or type(inv.swapOffer) ~= "table" then
		return false
	end
	Remotes.fire(Remotes.C2S.SwapGear, take)
	inv.swapOffer = nil
	State.set("inventory", inv)
	return true
end

-- Shop Cart purchase (pending cheese only, never Robux).
function State.buyCart(index: number)
	local cart = data.shopCart
	if type(cart) ~= "table" or cart.sold[index] then
		return
	end
	Remotes.fire(Remotes.C2S.BuyCartItem, cart.poi, index)
	cart.sold[index] = "pending"
	State.set("shopCart", cart)
end

function State.closeShopCart()
	State.set("shopCart", nil)
end

function State.toggleScoreboard(open: boolean?)
	local want = if open == nil then not data.scoreboardOpen else open
	State.set("scoreboardOpen", want)
end

-- Gear item -> plain table (items are {id, slot, rarity, …}; tolerate an id string).
local function normaliseItem(it: any): any
	if type(it) == "table" and it.id ~= nil then
		return it
	elseif type(it) == "string" and it ~= "" then
		return { id = it }
	end
	return nil
end

local function normaliseChampions(list: any): { any }
	local out = {}
	if type(list) ~= "table" then
		return out
	end
	for _, ch in list do
		if type(ch) == "table" and tonumber(ch.x) and tonumber(ch.z) then
			table.insert(out, {
				id = tonumber(ch.id),
				champId = tostring(ch.champId),
				x = tonumber(ch.x) :: number,
				z = tonumber(ch.z) :: number,
				hpFrac = math.clamp(tonumber(ch.hpFrac) or 1, 0, 1),
				lair = ch.lair == true,
			})
		end
	end
	return out
end

local function normaliseMatch(m: any): any
	local squadsIn = if type(m.squads) == "table" then m.squads else {}
	local squads = Scoreboard.normalise(squadsIn, nil)
	local me = State.localUserId()
	local mine: number? = nil
	for _, s in squads do
		if s.isYou or table.find(s.members, me) then
			mine = s.id
		end
	end
	if mine then
		for _, s in squads do
			s.isYou = s.id == mine
		end
	end
	local bounties: { [string]: boolean } = {}
	local b = m.bounties or m.bounty
	if type(b) == "table" then
		for k, v in b do
			if v == true then
				bounties[tostring(k)] = true
			elseif tonumber(v) or type(v) == "string" then
				bounties[tostring(v)] = true
			end
		end
	elseif b ~= nil then
		bounties[tostring(b)] = true
	end
	local chooser = m.routeChooser
	local chooserId = tonumber(chooser)
	if chooserId == nil and type(chooser) == "table" then
		chooserId = tonumber(chooser.squad or chooser.id)
	end
	if chooserId == nil and type(chooser) == "string" then
		for _, s in squads do
			if s.name == chooser then
				chooserId = s.id
			end
		end
	end
	return {
		phase = if m.phase ~= nil then tostring(m.phase) else nil,
		stage = tonumber(m.stage),
		squads = squads,
		mySquad = mine,
		routeChooser = chooserId,
		bounties = bounties,
		names = if type(m.names) == "table" then Format.numericKeys(m.names) else nil,
		-- v3 Mouse Champions: {{id, champId, x, z, hpFrac, lair}} and the squad's
		-- timed buffs {{kind, untilT, stat?, mul?}}
		champions = normaliseChampions(m.champions),
		buffs = if type(m.buffs) == "table" then m.buffs else {},
		-- iteration 2 (M2): numbered waves, the Early Horn, the difficulty tier
		wave = tonumber(m.wave),
		waves = tonumber(m.waves),
		wavesPerStage = tonumber(m.wavesPerStage),
		bossWave = m.bossWave == true,
		horn = if type(m.horn) == "table" then m.horn else nil,
		tier = tonumber(m.tier),
	}
end

-- Lobby squads: `l.squads` (array or map, entries {members|seats|ids, name?, color?})
-- or players[id].squad. Returns nil when the server sends no squad info (v1).
local function normaliseLobbySquads(l: any, players: { [number]: any }): { [number]: any }?
	local out: { [number]: any } = {}
	local any = false
	local function ensure(i: number): any
		local s = out[i]
		if not s then
			local d = Scoreboard.squad(i, nil, nil)
			s = { id = i, name = d.name, color = d.color, members = {} }
			out[i] = s
		end
		return s
	end
	if type(l.squads) == "table" then
		for k, sq in l.squads do
			local i = tonumber(k)
			if type(sq) == "table" and tonumber(sq.id) then
				i = tonumber(sq.id)
			end
			if i and i >= 1 and i <= 4 and type(sq) == "table" then
				any = true
				local s = ensure(i)
				if type(sq.name) == "string" then
					s.name = sq.name
				end
				if type(sq.color) == "table" then
					s.color = sq.color
				end
				local list = sq.members or sq.seats or sq.ids or sq
				for _, v in list do
					local n = tonumber(if type(v) == "table" then v.id else v)
					if n and not table.find(s.members, n) then
						table.insert(s.members, n)
					end
				end
			end
		end
	end
	for id, e in players do
		local sq = type(e) == "table" and tonumber(e.squad)
		if sq and sq >= 1 and sq <= 4 then
			any = true
			local s = ensure(sq)
			if not table.find(s.members, id) then
				table.insert(s.members, id)
			end
		end
	end
	if not any then
		return nil
	end
	for i = 1, 4 do
		ensure(i)
	end
	return out
end

----------------------------------------------------------------------
-- v4: busy flag, storm, pings
----------------------------------------------------------------------

-- Lobby "busy" (shop, perk tree, Herd panel): the server keeps a busy player
-- out of the auto-start pull (V4-PLAN M8). Several panels may be open at
-- once; SetBusy is sent only when the combined flag changes.
local busyReasons: { [string]: boolean } = {}
local busySent = false
function State.setBusy(reason: string, on: boolean)
	busyReasons[reason] = if on then true else nil
	local any = next(busyReasons) ~= nil
	if any ~= busySent then
		busySent = any
		Remotes.fire(Remotes.C2S.SetBusy, any)
		State.set("busy", any)
	end
end

function State.isBusy(): boolean
	return busySent
end

-- Storm payload (remote or Fx) -> State "storm".
function State.setStorm(p: any)
	if p == nil or (type(p) == "table" and p.clear == true) then
		State.set("storm", nil)
		return
	end
	local s = HudMath.storm(p, State.serverNow())
	if s then
		State.set("storm", s)
	end
end

-- Drops expired pings (HudMath.PING_SECONDS) and returns the live list.
function State.livePings(): { any }
	local list = data.pings
	if type(list) ~= "table" then
		return {}
	end
	local now = os.clock()
	for i = #list, 1, -1 do
		if now - (list[i].localAt or 0) > HudMath.PING_SECONDS then
			table.remove(list, i)
		end
	end
	return list
end

-- Auto-attack aim (iteration 4): "nearest" (default) or "cursor". The saved
-- value is profile.settings.aimMode (or profile.aimMode); a local pick wins
-- until the profile echoes it. Net.C2S.SetAimMode(mode) saves it.
local aimLocal: string? = nil
function State.aimMode(): string
	local p = data.profile
	local saved = nil
	if type(p) == "table" then
		saved = if type(p.settings) == "table" and type(p.settings.aimMode) == "string"
			then p.settings.aimMode
			elseif type(p.aimMode) == "string" then p.aimMode
			else nil
	end
	if aimLocal and aimLocal ~= saved then
		return aimLocal
	end
	aimLocal = nil
	return if saved == "cursor" then "cursor" else "nearest"
end

function State.setAimMode(mode: string)
	local m = if mode == "cursor" then "cursor" else "nearest"
	aimLocal = m
	if Remotes.C2S.SetAimMode then
		Remotes.fire(Remotes.C2S.SetAimMode, m)
	end
	State.set("aimMode", m)
end

function State.toggleAimMode()
	State.setAimMode(if State.aimMode() == "cursor" then "nearest" else "cursor")
end

-- World marks the minimap knows (POIs, portal, boss, champions), refreshed at
-- 10 Hz by UI/MinimapUI without firing a signal. Read by the objective arrow
-- and context pings.
function State.setMarks(m: any)
	data.marks = m
end

function State.marks(): any
	return data.marks
end

-- Squad ping / quick-chat (server validates, rate-limits and relays to the squad).
function State.sendPing(kind: string, x: number, z: number)
	Remotes.fire(Remotes.C2S.Ping, kind, x, z)
end

function State.sendQuickChat(index: number)
	Remotes.fire(Remotes.C2S.QuickChat, index)
end

local handles: { any } = {}
local started = false

function State.init()
	if started then
		return
	end
	started = true
	data.offers = {}
	local S2C = Remotes.S2C

	table.insert(
		handles,
		Remotes.on(S2C.RunState, function(rs)
			if type(rs) ~= "table" then
				return
			end
			local prev = data.run
			if prev == nil and rs.phase ~= nil and rs.phase ~= "Lobby" and data.classesAtStart == nil then
				local p = data.profile
				data.classesAtStart = if type(p) == "table" and type(p.classes) == "table"
					then table.clone(p.classes)
					else {}
			end
			State.set("run", rs)
			-- A new phase that is not a vote clears any stale vote panel.
			if prev and prev.phase ~= rs.phase then
				local v = data.vote
				if v and rs.phase ~= "RouteVote" and rs.phase ~= "BankVote" and rs.phase ~= "CycleVote" then
					State.set("vote", nil)
				end
				if rs.phase == "Lobby" then
					State.set("storm", nil)
					State.set("redeploy", nil)
					State.set("wallet", nil)
					State.set("stalls", nil)
					State.set("pings", {})
					State.set("offers", {})
					State.set("boss", nil)
					State.set("extract", nil)
					State.set("shopCart", nil)
					State.set("inventory", nil)
					State.set("match", nil)
					State.set("scoreboardOpen", false)
					State.set("meter", nil)
					State.set("meterOpen", false)
					State.set("overtime", nil)
					local kf = data.killfeed
					if type(kf) == "table" then
						table.clear(kf.entries)
						KillStreaks.reset(kf.streaks)
						State.set("killfeed", kf)
					end
				elseif prev.phase == "Lobby" or prev.phase == nil then
					-- A run starts: remember class progress for the results screen.
					data.awards = nil
					data.profileAtStart = data.profile -- iteration 3 T-12: the loot diff on Results
					local p = data.profile
					data.classesAtStart = if type(p) == "table" and type(p.classes) == "table"
						then table.clone(p.classes)
						else {}
				end
				if rs.phase == "Waves" or rs.phase == "Results" then
					local e = data.extract
					if type(e) == "table" then
						State.set("extract", nil)
					end
				end
			end
		end)
	)
	table.insert(handles, Remotes.on(S2C.PlayerHud, onHud))
	table.insert(
		handles,
		Remotes.on(S2C.PartyHud, function(p)
			State.set("party", Format.numericKeys(p))
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.Profile, function(p)
			if type(p) == "table" then
				data.profileAt = os.clock()
				State.set("profile", p)
				-- iteration 5: saved graphics settings (a fresh local pick wins for 3 s)
				if os.clock() - gfxPickedAt > 3 then
					local g = GfxSettings.fromProfile(p)
					local cur = data.gfx
					if
						type(cur) ~= "table"
						or cur.fx ~= g.fx
						or cur.decor ~= g.decor
						or cur.models ~= g.models
					then
						State.set("gfx", g)
					end
				end
			end
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.Lobby, function(l)
			if type(l) ~= "table" then
				return
			end
			local botCount = tonumber(l.botCount)
			local players = Format.numericKeys(l.players) -- server keys are tostring(userId)
			State.set("lobby", {
				players = players,
				-- v2: 4 squad pads x 3 seats (nil from a v1 server).
				squads = normaliseLobbySquads(l, players),
				yourSquad = tonumber(l.yourSquad),
				startsAt = tonumber(l.startsAt),
				runActive = l.runActive == true,
				-- while a match runs: {endsAt (estimate), stage, stages} (QC-A minor 6)
				runInfo = if type(l.runInfo) == "table"
					then {
						endsAt = tonumber(l.runInfo.endsAt),
						stage = tonumber(l.runInfo.stage),
						stages = tonumber(l.runInfo.stages),
					}
					else nil,
				-- true: the countdown is the idle auto-start; false: someone readied (nil = unknown).
				autoStart = if type(l.autoStart) == "boolean" then l.autoStart else nil,
				-- This player's own bot-fill toggle (nil = unknown, UI keeps its local value).
				botFill = if type(l.botFill) == "boolean" then l.botFill else nil,
				-- Whether any lobby human has bot fill on, i.e. bots will come at all.
				botFillAny = if type(l.botFillAny) == "boolean" then l.botFillAny else nil,
				-- Bots currently placed on the pad for the next run.
				botCount = if botCount then math.max(0, math.floor(botCount)) else nil,
				-- Party leader's Pressure board (GDD §3.7).
				pressure = State.normalisePressure(l.pressure),
				-- iteration 2 (M2): the difficulty ladder pick ({tier, leaderId?} or a number)
				tier = l.tier,
				ladder = if type(l.ladder) == "table" then l.ladder else nil,
			})
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.VoteOpen, function(v)
			if type(v) ~= "table" then
				return
			end
			State.set("vote", {
				kind = v.kind,
				options = if type(v.options) == "table" then v.options else {},
				cleanse = if type(v.cleanse) == "table" then v.cleanse else nil, -- iteration 8
				endsAt = tonumber(v.endsAt),
				tally = {},
				myPick = nil,
				closed = false,
				winner = nil,
			})
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.VoteTally, function(t)
			local v = data.vote
			if type(v) == "table" then
				v.tally = normaliseTally(t)
				State.set("vote", v)
			end
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.VoteClosed, function(winner)
			local v = data.vote
			if type(v) == "table" then
				v.closed = true
				v.winner = tonumber(winner)
				State.set("vote", v)
			end
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.UpgradeOffer, function(o)
			if type(o) ~= "table" or tonumber(o.offerId) == nil then
				return
			end
			local q = data.offers or {}
			local entry = {
				offerId = tonumber(o.offerId),
				cards = if type(o.cards) == "table" then o.cards else {},
				rerollsLeft = tonumber(o.rerollsLeft) or 0,
				queued = tonumber(o.queued) or 0, -- levels waiting behind this offer (server-side queue)
				-- nil (level-up) | "chest" (Elite Camp) | "pantry" (Grandma's Pantry): UpgradeUI's title
				source = if o.source == "chest" or o.source == "pantry" then o.source else nil,
			}
			-- The server has one live offer per player. A reroll may come back under
			-- the same offerId or a new one, so any older offer still queued here is
			-- stale: drop it, or the UI would keep showing (and picking) dead cards.
			local replaced = false
			for i = #q, 1, -1 do
				local existing = q[i]
				if existing.offerId == entry.offerId then
					q[i] = entry
					replaced = true
				elseif existing.offerId < entry.offerId then
					table.remove(q, i)
				end
			end
			if not replaced then
				table.insert(q, entry)
			end
			table.sort(q, function(a, b)
				return a.offerId < b.offerId
			end)
			-- Rerolls left is shared per player; keep every queued offer in sync.
			for _, e in q do
				e.rerollsLeft = entry.rerollsLeft
			end
			State.set("offers", q)
		end)
	)
	-- v2 squad PvPvE ------------------------------------------------------
	data.killfeed = { entries = {}, streaks = KillStreaks.new(), seq = 0 }
	data.scoreboardOpen = false
	table.insert(
		handles,
		Remotes.on(S2C.Match, function(m)
			if type(m) ~= "table" then
				State.set("match", nil)
				return
			end
			State.set("match", normaliseMatch(m))
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.KillFeed, function(...)
			local kf = data.killfeed
			-- One entry, or a batch {entry, entry…}.
			local first = ...
			local list = if type(first) == "table"
					and first.kind == nil
					and first.killer == nil
					and first.victim == nil
				then first
				else { first }
			for _, e in list do
				if type(e) == "table" then
					kf.seq += 1
					local entry = {
						killer = e.killer,
						victim = e.victim,
						killerSquad = tonumber(e.killerSquad),
						victimSquad = tonumber(e.victimSquad),
						kind = tostring(e.kind or "kill"),
						champId = if e.champId ~= nil then tostring(e.champId) else nil, -- v3 kind "champion"
						lair = e.lair == true,
						at = os.clock(),
						seq = kf.seq,
					}
					-- squad match: only the server's bounty / bountyClaimed entries
					entry.newBounty = KillStreaks.push(kf.streaks, entry, State.isSquadMatch())
					table.insert(kf.entries, entry)
					while #kf.entries > KILLFEED_MAX do
						table.remove(kf.entries, 1)
					end
				end
			end
			State.set("killfeed", kf)
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.Inventory, function(inv)
			if type(inv) ~= "table" then
				State.set("inventory", nil)
				return
			end
			local offer = nil
			local so = inv.swapOffer
			if type(so) == "table" and normaliseItem(so.item) then
				offer = {
					item = normaliseItem(so.item),
					slot = tostring(so.slot or (normaliseItem(so.item) :: any).slot or "weapon"),
					endsAt = tonumber(so.endsAt) or (State.serverNow() + 4),
					current = normaliseItem(so.current),
				}
			end
			State.set("inventory", {
				weapon = normaliseItem(inv.weapon),
				armor = normaliseItem(inv.armor),
				trinket = normaliseItem(inv.trinket),
				swapOffer = offer,
			})
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.Extract, function(e)
			if type(e) ~= "table" or e.closed == true then
				local cur = data.extract
				if type(cur) == "table" and type(e) == "table" then
					cur.closed = true
					cur.result = e.result or e.choice
					State.set("extract", cur)
				else
					State.set("extract", nil)
				end
				return
			end
			local prev = data.extract
			local votes: { [string]: number } = {}
			if type(e.votes) == "table" then
				for k, v in e.votes do
					votes[tostring(k)] = tonumber(v) or 0
				end
			end
			local options = {}
			if type(e.options) == "table" then
				for _, o in e.options do
					table.insert(options, tostring(o))
				end
			end
			if #options == 0 then
				options = { "Extract", "Stay", "DoubleOrNothing" }
			end
			local yours = if e.yourChoice ~= nil then tostring(e.yourChoice) else nil
			local sameWindow = type(prev) == "table" and not prev.closed and prev.endsAt == tonumber(e.endsAt)
			State.set("extract", {
				endsAt = tonumber(e.endsAt),
				options = options,
				votes = votes,
				yourChoice = yours,
				-- keep an optimistic pick for 2 s, until the server echoes it
				myPick = if yours
					then yours
					elseif
						sameWindow
						and prev.myPick
						and os.clock() - (prev.myPickAt or 0) < 2
					then prev.myPick
					else nil,
				myPickAt = if sameWindow then prev.myPickAt else nil,
				squadSize = tonumber(e.squadSize),
				-- your own share and what Extract banks for you (QC-A minor 2)
				share = tonumber(e.share),
				bank = tonumber(e.bank),
				closed = false,
			})
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.ShopCart, function(c)
			if type(c) ~= "table" or c.closed == true or type(c.offers) ~= "table" then
				State.set("shopCart", nil)
				return
			end
			local prev = data.shopCart
			-- a live update (squad-mate bought / share changed) only refreshes a
			-- panel that is still open on this cart; it never reopens it
			if c.refresh == true and (type(prev) ~= "table" or prev.poi ~= c.poi) then
				return
			end
			local offers, prices = {}, {}
			for i, it in c.offers do
				local n = tonumber(i)
				local item = normaliseItem(it)
				if n and item then
					offers[n] = item
					prices[n] = tonumber(type(c.prices) == "table" and (c.prices[i] or c.prices[tostring(i)]))
						or tonumber(item.price)
						or 0
				end
			end
			-- The server's `bought` is the authority (`sold` is an older alias). A
			-- buy of ours still in flight keeps its "pending" marker until the
			-- server answers (or the 3 s timeout in ShopCartUI clears it).
			local sold: { [number]: any } = {}
			local src = if type(c.bought) == "table"
				then c.bought
				elseif type(c.sold) == "table" then c.sold
				else nil
			if src then
				for k, v in src do
					if v then
						sold[tonumber(k) or 0] = true
					end
				end
			end
			if type(prev) == "table" and prev.poi == c.poi and type(prev.sold) == "table" then
				for k, v in prev.sold do
					if v == "pending" and not sold[k] then
						sold[k] = "pending"
					elseif v == true and src == nil then
						sold[k] = true
					end
				end
			end
			-- the cart charges your OWN pending share, not the squad pot
			local share = tonumber(c.share)
			if share == nil and type(prev) == "table" and prev.poi == c.poi then
				share = prev.share
			end
			State.set(
				"shopCart",
				{ poi = c.poi, offers = offers, prices = prices, sold = sold, share = share }
			)
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.Results, function(r)
			if type(r) == "table" then
				-- Keep the final squad standings and gear for the results screen.
				data.resultsMatch = data.match
				data.resultsInventory = data.inventory
				State.set("offers", {})
				State.set("extract", nil)
				State.set("shopCart", nil)
				State.set("scoreboardOpen", false)
				State.set("results", r)
			end
		end)
	)
	-- v4 ---------------------------------------------------------------
	data.pings = {}
	table.insert(handles, Remotes.on(S2C.Storm, State.setStorm))
	table.insert(
		handles,
		Remotes.on(S2C.PingShown, function(p)
			local mark = HudMath.ping(p, State.serverNow())
			if not mark then
				return
			end
			local list = State.livePings()
			local entry = mark :: any
			entry.localAt = os.clock()
			table.insert(list, entry)
			while #list > PINGS_MAX do
				table.remove(list, 1)
			end
			data.pings = list
			State.set("pings", list)
		end)
	)
	for _, key in { "Quests", "Pass", "Leaderboards" } do
		local name = S2C[key]
		if name then
			local stateKey = string.lower(string.sub(key, 1, 1)) .. string.sub(key, 2)
			table.insert(
				handles,
				Remotes.on(name, function(v)
					if type(v) == "table" then
						State.set(stateKey, v)
					end
				end)
			)
		end
	end
	table.insert(
		handles,
		Remotes.on(S2C.Awards, function(a)
			State.set("awards", if type(a) == "table" then a else nil)
		end)
	)
	-- v5 run economy
	if S2C.Wallet then
		table.insert(
			handles,
			Remotes.on(S2C.Wallet, function(w)
				if type(w) == "table" then
					State.set("wallet", w)
				end
			end)
		)
	end
	if S2C.Stalls then
		table.insert(
			handles,
			Remotes.on(S2C.Stalls, function(st)
				State.set("stalls", if type(st) == "table" then st else nil)
			end)
		)
	end
	-- iteration 5 Phase B: damage meter (~1 Hz) and the Overtime state
	if S2C.Meter then
		table.insert(
			handles,
			Remotes.on(S2C.Meter, function(m)
				State.set("meter", if type(m) == "table" then m else nil)
			end)
		)
	end
	if S2C.Overtime then
		table.insert(
			handles,
			Remotes.on(S2C.Overtime, function(o)
				State.set("overtime", if type(o) == "table" then o else nil)
			end)
		)
	end
	table.insert(
		handles,
		Remotes.on(S2C.Redeploy, function(r)
			State.set("redeploy", if type(r) == "table" then r else nil)
		end)
	)
	table.insert(
		handles,
		Remotes.on(S2C.Toast, function(text, kind)
			if text ~= nil then
				State.toast:Fire(tostring(text), if type(kind) == "string" then kind else "info")
			end
		end)
	)
end

function State.destroy()
	for _, h in handles do
		h.Disconnect()
	end
	table.clear(handles)
	started = false
end

return State
