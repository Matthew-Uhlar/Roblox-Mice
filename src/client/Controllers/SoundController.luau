--!strict
-- SoundController (v4, team G): all game audio, from Config/Sounds.
--
--   SoundController.init()                    idempotent (FxController.init starts it;
--                                             Main.client may also list it)
--   SoundController.play(key, at?: Vector3, pitchAdd?: number) -> boolean
--   SoundController.setMuted(group: "Music"|"SFX"|"UI"|"all", muted: boolean)
--   SoundController.setVolume(group, 0..1)    multiplies the Config group volume
--   SoundController.music(key?: string)       switch the music bed (nil = stop)
--   SoundController.duck()                    music to DUCK_VOLUME for DUCK_TIME
--   SoundController.destroy()
--
-- Hooks (no other module has to call it):
--   * Net.S2C.Fx batches: hit / crit, die, pickupTaken (own: rising pitch chain),
--     melee (own swing), boom, hurt (own), down, revive, tele, boss, bossPhase,
--     champ (spawn), poiDone, portal (open), gearEquip (own), storm (warning on
--     every new circle)
--   * Net.S2C.Storm (same payload as the Fx) when it exists
--   * State "hud": level increase -> level-up fanfare + music duck
--   * State "results": win / loss sting; "run".phase: lobby / run / boss music,
--     extraction sting when the squad extracts
--   * every GuiButton in PlayerGui: a UI click on Activated
--   * mute: profile.settings.music / profile.settings.sfx == false (when team P
--     allowlists them for SetSetting) and the client-only State key "audio"
--     {music = bool, sfx = bool, ui = bool} (false = muted)
-- Slots with an empty id are skipped silently. Hit sounds are capped at 10/s,
-- every slot has its own cap (Config/Sounds maxPerSecond); one-shots come from
-- a pool of POOL_SIZE Sounds (2-D in a SoundService folder, 3-D on pooled
-- attachments on Terrain).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Client = script.Parent.Parent
local Remotes = require(Client.Util.Remotes)
local State = require(script.Parent.State)

local SoundController = {}

local Sounds: any = nil
do
	local ok, mod = pcall(function()
		local cfg = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
		local inst = cfg:WaitForChild("Sounds", 10)
		return if inst then require(inst) :: any else nil
	end)
	Sounds = if ok then mod else nil
end

local started = false
local connections: { any } = {}
local groups: { [string]: SoundGroup } = {}
local userVolume: { [string]: number } = { Music = 1, SFX = 1, UI = 1 }
local muted: { [string]: boolean } = { Music = false, SFX = false, UI = false }
local rate: { [string]: { number } } = {}
local folder: Folder? = nil

type Voice = { sound: Sound, att: Attachment?, busyUntil: number }
local voices2D: { Voice } = {}
local voices3D: { Voice } = {}

local musicSound: Sound? = nil
local musicKey: string? = nil
local duckUntil = 0

local chainPitch = 0
local chainAt = 0

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "TrunkfallSounds"
	f.Parent = SoundService
	folder = f
	return f
end

local function applyGroupVolume(name: string)
	local g = groups[name]
	if not g or not Sounds then
		return
	end
	local base = Sounds.GROUPS[name] or 0.5
	local v = if muted[name] then 0 else base * (userVolume[name] or 1)
	if name == "Music" and os.clock() < duckUntil then
		v *= Sounds.DUCK_VOLUME
	end
	g.Volume = v
end

local function ensureGroups()
	if not Sounds then
		return
	end
	for name in Sounds.GROUPS do
		if not groups[name] then
			local g = Instance.new("SoundGroup")
			g.Name = "Trunkfall" .. name
			g.Parent = SoundService
			groups[name] = g
		end
		applyGroupVolume(name)
	end
end

local function newVoice(is3D: boolean): Voice
	local s = Instance.new("Sound")
	s.Name = "Voice"
	local att: Attachment? = nil
	if is3D then
		local a = Instance.new("Attachment")
		a.Name = "TrunkfallSound"
		a.Parent = workspace.Terrain
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = if Sounds then Sounds.ROLLOFF_MIN else 20
		s.RollOffMaxDistance = if Sounds then Sounds.ROLLOFF_MAX else 110
		s.Parent = a
		att = a
	else
		s.Parent = getFolder()
	end
	return { sound = s, att = att, busyUntil = 0 }
end

local function voice(is3D: boolean, now: number): Voice?
	local list = if is3D then voices3D else voices2D
	local cap = math.ceil((if Sounds then Sounds.POOL_SIZE else 24) / 2)
	local oldest: Voice? = nil
	for _, v in list do
		if v.busyUntil <= now then
			return v
		end
		if not oldest or v.busyUntil < oldest.busyUntil then
			oldest = v
		end
	end
	if #list < cap then
		local v = newVoice(is3D)
		table.insert(list, v)
		return v
	end
	return oldest -- steal the voice that finishes first
end

-- Plays slot `key`; `at` makes it a 3-D sound there (only for is3D slots).
function SoundController.play(key: string, at: Vector3?, pitchAdd: number?): boolean
	if not Sounds then
		return false
	end
	local slot = Sounds.SLOTS[key]
	if not slot or type(slot.id) ~= "string" or slot.id == "" then
		return false -- TODO slots stay silent
	end
	if slot.looped then
		return false -- music goes through SoundController.music
	end
	if muted[slot.group] then
		return false
	end
	local now = os.clock()
	if not Sounds.allow(rate, key, now, slot.maxPerSecond) then
		return false
	end
	local is3D = slot.is3D == true and at ~= nil
	local v = voice(is3D, now)
	if not v then
		return false
	end
	local s = v.sound
	s:Stop()
	s.SoundId = slot.id
	s.Volume = slot.volume
	s.PlaybackSpeed = math.max(0.1, Sounds.pitchFor(slot, math.random()) + (pitchAdd or 0))
	s.SoundGroup = groups[slot.group]
	if is3D and v.att and at then
		v.att.WorldPosition = at
	end
	v.busyUntil = now + 1.5
	s:Play()
	return true
end

function SoundController.setMuted(group: string, on: boolean)
	if group == "all" then
		for name in muted do
			muted[name] = on
			applyGroupVolume(name)
		end
		return
	end
	if muted[group] ~= nil then
		muted[group] = on
		applyGroupVolume(group)
	end
end

function SoundController.setVolume(group: string, v: number)
	if userVolume[group] ~= nil then
		userVolume[group] = math.clamp(tonumber(v) or 1, 0, 1)
		applyGroupVolume(group)
	end
end

function SoundController.music(key: string?)
	if key == musicKey then
		return
	end
	musicKey = key
	if musicSound then
		musicSound:Stop()
	end
	if not key or not Sounds then
		return
	end
	local slot = Sounds.SLOTS[key]
	if not slot or slot.id == "" then
		return -- TODO: no music id yet
	end
	local s = musicSound
	if not s then
		local ns = Instance.new("Sound")
		ns.Name = "Music"
		ns.Looped = true
		ns.Parent = getFolder()
		musicSound = ns
		s = ns
	end
	assert(s, "music sound")
	s.SoundId = slot.id
	s.Volume = slot.volume
	s.SoundGroup = groups.Music
	s:Play()
end

function SoundController.duck()
	if not Sounds then
		return
	end
	duckUntil = os.clock() + Sounds.DUCK_TIME
	applyGroupVolume("Music")
	task.delay(Sounds.DUCK_TIME + 0.05, function()
		applyGroupVolume("Music")
	end)
end

----------------------------------------------------------------------
-- Hooks
----------------------------------------------------------------------

local function num(v: any): number?
	local n = tonumber(v)
	if n == nil or n ~= n then
		return nil
	end
	return n
end

local function at(ev: any): Vector3?
	local x, z = num(ev.x), num(ev.z)
	return if x and z then Vector3.new(x, 2, z) else nil
end

local lastStormKey = ""
local function onStorm(p: any)
	if type(p) ~= "table" then
		return
	end
	-- a new circle (target radius / centre) = the warning sting
	local key = string.format("%d/%d/%d", num(p.toR) or 0, num(p.cx) or 0, num(p.cz) or 0)
	if key ~= lastStormKey then
		lastStormKey = key
		SoundController.play("stormWarn")
	end
end

local FX: { [string]: (any, number) -> () } = {
	hit = function(ev)
		if ev.crit == true then
			SoundController.play("crit", at(ev))
			SoundController.play("critDing")
		else
			SoundController.play("hit", at(ev))
		end
	end,
	die = function(ev)
		SoundController.play("die", at(ev))
	end,
	pickupTaken = function(ev, me)
		if num(ev.by) ~= me then
			return
		end
		local now = os.clock()
		if now - chainAt > (Sounds.PICKUP_CHAIN_WINDOW or 0.6) then
			chainPitch = 0
		else
			chainPitch =
				math.min(Sounds.PICKUP_CHAIN_MAX or 0.5, chainPitch + (Sounds.PICKUP_CHAIN_STEP or 0.04))
		end
		chainAt = now
		SoundController.play("pickup", nil, chainPitch)
	end,
	melee = function(ev, me)
		if num(ev.id) == me then
			SoundController.play("swing")
		end
	end,
	boom = function(ev)
		SoundController.play("boom", at(ev))
	end,
	hurt = function(ev, me)
		if num(ev.id) == me then
			SoundController.play("hurt")
		end
	end,
	down = function(ev)
		SoundController.play("down")
		local _ = ev
	end,
	revive = function()
		SoundController.play("revive")
	end,
	tele = function(ev)
		SoundController.play("tele", at(ev))
	end,
	boss = function()
		SoundController.play("boss")
		SoundController.duck()
	end,
	bossPhase = function()
		SoundController.play("bossPhase")
	end,
	champ = function(ev)
		if tostring(ev.phase or "spawn") == "spawn" then
			SoundController.play("champion")
		end
	end,
	poiDone = function()
		SoundController.play("poiDone")
	end,
	portal = function(ev)
		if ev.phase == "open" then
			SoundController.play("portal")
		end
	end,
	gearEquip = function(ev, me)
		if num(ev.id) == me then
			SoundController.play("gear")
		end
	end,
	storm = function(ev)
		onStorm(ev)
	end,
}
SoundController.FX_KINDS = FX

local function onFx(batch: any)
	if type(batch) ~= "table" then
		return
	end
	local me = State.localUserId()
	for _, ev in batch do
		if type(ev) == "table" then
			local h = FX[tostring(ev.t)]
			if h then
				pcall(h, ev, me)
			end
		end
	end
end

local function applySettings()
	local prof = State.get("profile")
	local settings = if type(prof) == "table" and type(prof.settings) == "table" then prof.settings else {}
	local local_ = State.get("audio")
	local la = if type(local_) == "table" then local_ else {}
	muted.Music = settings.music == false or la.music == false
	muted.SFX = settings.sfx == false or la.sfx == false
	muted.UI = settings.sfx == false or la.ui == false or la.sfx == false
	for name in muted do
		applyGroupVolume(name)
	end
end

local hookedButtons: { [Instance]: boolean } = {}
local function hookButton(b: Instance)
	if hookedButtons[b] or not b:IsA("GuiButton") then
		return
	end
	hookedButtons[b] = true
	local c = (b :: GuiButton).Activated:Connect(function()
		SoundController.play("click")
	end)
	b.Destroying:Connect(function()
		hookedButtons[b] = nil
		c:Disconnect()
	end)
end

local function hookGui()
	local lp = Players.LocalPlayer
	if not lp then
		return
	end
	local pg = lp:WaitForChild("PlayerGui", 30)
	if not pg then
		return
	end
	for _, d in pg:GetDescendants() do
		hookButton(d)
	end
	table.insert(connections, pg.DescendantAdded:Connect(hookButton))
end

function SoundController.init()
	if started then
		return
	end
	started = true
	if not Sounds then
		warn("[Trunkfall] Config/Sounds missing: audio off")
		return
	end
	ensureGroups()
	applySettings()
	table.insert(connections, Remotes.on(Remotes.S2C.Fx, onFx))
	if Remotes.S2C.Storm then
		table.insert(connections, Remotes.on(Remotes.S2C.Storm, onStorm))
	end
	local function sub(key: string, fn: (any) -> ())
		table.insert(connections, { Disconnect = State.subscribe(key, fn) })
	end
	sub("profile", applySettings)
	sub("audio", applySettings)
	local lastLevel: number? = nil
	sub("hud", function(hud)
		local lv = if type(hud) == "table" then tonumber(hud.level) else nil
		if lv and lastLevel and lv > lastLevel and State.inCombat() then
			SoundController.play("levelUp")
			task.delay(0.12, function()
				SoundController.play("levelUpChime")
			end)
			SoundController.duck()
		end
		lastLevel = lv
	end)
	local lastPhase: string? = nil
	sub("run", function(run)
		local phase = if type(run) == "table" then run.phase else nil
		if phase == lastPhase then
			return
		end
		lastPhase = phase
		if phase == "Boss" then
			SoundController.music("musicBoss")
		elseif phase == "Waves" or phase == "StageClear" or phase == "Vote" then
			SoundController.music("musicRun")
		elseif phase == nil or phase == "Lobby" or phase == "Results" then
			SoundController.music("musicLobby")
			lastLevel = nil
		end
	end)
	sub("results", function(r)
		if type(r) ~= "table" then
			return
		end
		local result = if type(r.result) == "string" then string.lower(r.result) else ""
		local good = r.outcome == "Win" or result == "extracted" or result == "lastherd" or r.lastHerd == true
		if result == "extracted" then
			SoundController.play("extract")
		end
		task.delay(0.3, function()
			SoundController.play(if good then "win" else "loss")
		end)
	end)
	task.spawn(hookGui)
	SoundController.music("musicLobby")
end

function SoundController.destroy()
	for _, c in connections do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(connections)
	for _, list in { voices2D, voices3D } do
		for _, v in list do
			if v.att then
				v.att:Destroy()
			else
				v.sound:Destroy()
			end
		end
		table.clear(list)
	end
	if musicSound then
		musicSound:Destroy()
		musicSound = nil
	end
	musicKey = nil
	for _, g in groups do
		g:Destroy()
	end
	table.clear(groups)
	table.clear(hookedButtons)
	if folder then
		folder:Destroy()
		folder = nil
	end
	started = false
end

return SoundController
