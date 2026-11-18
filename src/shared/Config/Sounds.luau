--!strict
-- Config/Sounds (v4, team G): every sound slot the client plays
-- (src/client/Controllers/SoundController). Pure data, runs under Lune.
--
--   Sounds.GROUPS[name] = volume            SoundGroups under SoundService
--   Sounds.SLOTS[key] = {
--       id         asset id string; "" = silent (the controller skips it)
--       volume     0..1 (before the group volume)
--       group      "Music" | "SFX" | "UI"
--       pitch      base PlaybackSpeed (default 1)
--       vary       true: random pitch in Sounds.PITCH_MIN..PITCH_MAX x pitch
--       maxPerSecond   rate cap (nil = uncapped)
--       is3D       true: played at a world position (RollOff below)
--       looped     music beds
--   }
--
-- Ids: only sounds that ship inside the Roblox client (rbxasset://sounds/...)
-- are used, because they need no upload and no permission. The ones below are
-- the classic tool sounds (ClassicSword: swordslash / swordlunge / unsheath),
-- the default character sounds (RbxCharacterSounds: action_*.mp3) and the
-- files the lead listed (electronicpingshort, button, uuhhh, snap). Every other
-- slot is "" with a TODO: paste a Toolbox id (creator "Roblox") or an uploaded
-- one (scripts/publish.py assets) and it starts playing; nothing else changes.

local Sounds = {}

Sounds.GROUPS = {
	Music = 0.35,
	SFX = 0.6,
	UI = 0.5,
}

Sounds.PITCH_MIN = 0.92
Sounds.PITCH_MAX = 1.12
Sounds.POOL_SIZE = 24 -- pooled Sound objects for one-shots
Sounds.ROLLOFF_MIN = 20 -- studs (the camera sits ~60 studs away)
Sounds.ROLLOFF_MAX = 110
Sounds.PICKUP_CHAIN_STEP = 0.04 -- pitch added per crumb picked up within the window
Sounds.PICKUP_CHAIN_WINDOW = 0.6
Sounds.PICKUP_CHAIN_MAX = 0.5
Sounds.DUCK_VOLUME = 0.15 -- music volume factor during a duck
Sounds.DUCK_TIME = 1.5

local S = "rbxasset://sounds/"

export type Slot = {
	id: string,
	volume: number,
	group: string,
	pitch: number?,
	vary: boolean?,
	maxPerSecond: number?,
	is3D: boolean?,
	looped: boolean?,
	-- iter1: our own procedural audio (assets/audio, uploaded through
	-- assets/models/manifest.json). When Config/AssetIds has this name the
	-- uploaded id wins; until then `id` (a built-in fallback, or "") is used.
	asset: string?,
	-- several assets picked at random (squeak chorus)
	assets: { string }?,
}

Sounds.SLOTS = {
	-- combat
	hit = {
		id = S .. "swordslash.wav",
		volume = 0.35,
		group = "SFX",
		pitch = 1.25,
		vary = true,
		maxPerSecond = 10,
		is3D = true,
	},
	crit = {
		id = S .. "swordlunge.wav",
		volume = 0.55,
		group = "SFX",
		pitch = 1.3,
		vary = true,
		maxPerSecond = 6,
		is3D = true,
	},
	critDing = {
		id = S .. "electronicpingshort.wav",
		volume = 0.3,
		group = "SFX",
		pitch = 1.6,
		maxPerSecond = 6,
	},
	die = {
		id = S .. "snap.mp3",
		volume = 0.4,
		group = "SFX",
		pitch = 1.4,
		vary = true,
		maxPerSecond = 8,
		is3D = true,
	},
	swing = {
		id = S .. "swordslash.wav",
		volume = 0.18,
		group = "SFX",
		pitch = 0.9,
		vary = true,
		maxPerSecond = 6,
	},
	boom = {
		id = S .. "action_jump_land.mp3",
		volume = 0.7,
		group = "SFX",
		pitch = 0.55,
		vary = true,
		maxPerSecond = 4,
		is3D = true,
	},
	hurt = {
		id = S .. "action_jump_land.mp3",
		volume = 0.5,
		group = "SFX",
		pitch = 1.1,
		vary = true,
		maxPerSecond = 4,
	},
	down = { id = S .. "uuhhh.mp3", volume = 0.6, group = "SFX", vary = true, maxPerSecond = 2 },
	revive = { id = S .. "action_get_up.mp3", volume = 0.6, group = "SFX", maxPerSecond = 2 },
	tele = {
		id = S .. "electronicpingshort.wav",
		volume = 0.35,
		group = "SFX",
		pitch = 0.6,
		maxPerSecond = 3,
		is3D = true,
	},
	-- progress
	pickup = {
		id = S .. "electronicpingshort.wav",
		volume = 0.22,
		group = "SFX",
		pitch = 1.5,
		maxPerSecond = 12,
	},
	levelUp = { id = S .. "unsheath.wav", volume = 0.6, group = "SFX", pitch = 1.1 },
	levelUpChime = { id = S .. "electronicpingshort.wav", volume = 0.45, group = "SFX", pitch = 1.2 },
	gear = {
		id = S .. "unsheath.wav",
		volume = 0.45,
		group = "SFX",
		pitch = 1.3,
		vary = true,
		maxPerSecond = 3,
	},
	poiDone = {
		id = S .. "electronicpingshort.wav",
		volume = 0.45,
		group = "SFX",
		pitch = 0.9,
		maxPerSecond = 3,
	},
	-- set pieces
	champion = { id = S .. "swordlunge.wav", volume = 0.7, group = "SFX", pitch = 0.55, maxPerSecond = 1 },
	boss = { id = S .. "uuhhh.mp3", volume = 0.9, group = "SFX", pitch = 0.5, maxPerSecond = 1 },
	bossPhase = { id = S .. "uuhhh.mp3", volume = 0.8, group = "SFX", pitch = 0.62, maxPerSecond = 1 },
	stormWarn = {
		id = S .. "electronicpingshort.wav",
		volume = 0.55,
		group = "SFX",
		pitch = 0.45,
		maxPerSecond = 2,
	},
	stormOutside = {
		id = S .. "electronicpingshort.wav",
		volume = 0.3,
		group = "SFX",
		pitch = 0.35,
		maxPerSecond = 1,
	},
	portal = { id = S .. "unsheath.wav", volume = 0.6, group = "SFX", pitch = 0.7, maxPerSecond = 1 },
	extract = { id = S .. "unsheath.wav", volume = 0.7, group = "SFX", pitch = 0.85 },
	-- UI
	click = { id = S .. "button.wav", volume = 0.5, group = "UI", vary = true, maxPerSecond = 12 },
	countdown = {
		id = S .. "electronicpingshort.wav",
		volume = 0.4,
		group = "UI",
		pitch = 1.0,
		maxPerSecond = 2,
	},
	win = { id = S .. "electronicpingshort.wav", volume = 0.6, group = "UI", pitch = 1.3 },
	loss = { id = S .. "uuhhh.mp3", volume = 0.5, group = "UI", pitch = 0.8 },
	-- music beds: our procedural loops (assets/audio/make-audio.py); silent until uploaded
	musicLobby = { id = "", asset = "music_lobby", volume = 0.8, group = "Music", looped = true },
	musicRun = { id = "", asset = "music_run", volume = 0.8, group = "Music", looped = true },
	musicBoss = { id = "", asset = "music_boss", volume = 0.9, group = "Music", looped = true },
	-- iter1 (VERIFIED #5): squeaks, the elephant trumpet, a stomp, and one
	-- telegraph wind-up per pattern base. Built-in fallbacks until uploaded.
	squeak = {
		id = S .. "electronicpingshort.wav",
		assets = { "sfx_squeak1", "sfx_squeak2", "sfx_squeak3" },
		volume = 0.35,
		group = "SFX",
		pitch = 2.2,
		vary = true,
		maxPerSecond = 6,
		is3D = true,
	},
	trumpet = {
		id = S .. "unsheath.wav",
		asset = "sfx_trumpet",
		volume = 0.6,
		group = "SFX",
		vary = true,
		maxPerSecond = 3,
	},
	stomp = {
		id = S .. "action_jump_land.mp3",
		asset = "sfx_stomp",
		volume = 0.5,
		group = "SFX",
		pitch = 0.7,
		vary = true,
		maxPerSecond = 4,
		is3D = true,
	},
	teleSlam = {
		id = S .. "action_jump_land.mp3",
		asset = "tele_slam",
		volume = 0.6,
		group = "SFX",
		pitch = 0.4,
		maxPerSecond = 3,
		is3D = true,
	},
	teleCharge = {
		id = S .. "swordlunge.wav",
		asset = "tele_charge",
		volume = 0.5,
		group = "SFX",
		pitch = 0.7,
		maxPerSecond = 3,
		is3D = true,
	},
	teleVolley = {
		id = S .. "button.wav",
		asset = "tele_volley",
		volume = 0.5,
		group = "SFX",
		pitch = 0.8,
		maxPerSecond = 3,
		is3D = true,
	},
	teleSummon = {
		id = S .. "electronicpingshort.wav",
		asset = "tele_summon",
		volume = 0.45,
		group = "SFX",
		pitch = 0.75,
		maxPerSecond = 3,
		is3D = true,
	},
} :: { [string]: Slot }

-- Telegraph style / pattern -> wind-up slot (unknown styles use "tele").
Sounds.TELE = {
	-- styles (World / BossPatterns) first, then shapes as the fallback
	slam = "teleSlam",
	rock = "teleSlam",
	fuse = "teleSlam",
	burst = "teleSlam",
	trap = "teleVolley",
	spiral = "teleVolley",
	bossIntro = "teleSummon",
	stomp = "teleSlam",
	ring = "teleSlam",
	circle = "teleSlam",
	line = "teleCharge",
	charge = "teleCharge",
	dash = "teleCharge",
	cone = "teleVolley",
	volley = "teleVolley",
	chain = "teleVolley",
	summon = "teleSummon",
	rally = "teleSummon",
	champIntro = "teleSummon",
	roulette = "teleSummon",
}

-- The playable id of a slot: an uploaded asset (ids = Config/AssetIds) beats the
-- built-in fallback. `u` (0..1) picks among `assets`. "" = silent.
function Sounds.resolve(slot: Slot, ids: { [string]: any }?, u: number?): string
	local names = slot.assets or (if slot.asset then { slot.asset } else nil)
	if names and ids then
		local name = names[1 + math.floor(math.clamp(u or 0, 0, 0.999) * #names)]
		local id = tonumber(ids[name])
		if id and id > 0 then
			return "rbxassetid://" .. tostring(math.floor(id))
		end
		for _, n in names do
			local alt = tonumber(ids[n])
			if alt and alt > 0 then
				return "rbxassetid://" .. tostring(math.floor(alt))
			end
		end
	end
	return slot.id or ""
end

-- The slot for `key` or nil.
function Sounds.get(key: string): Slot?
	return Sounds.SLOTS[key]
end

-- True when the slot has an id the controller can play.
function Sounds.playable(key: string): boolean
	local s = Sounds.SLOTS[key]
	return s ~= nil and type(s.id) == "string" and s.id ~= ""
end

-- Pitch for one play: the base pitch, randomised into PITCH_MIN..PITCH_MAX when
-- `vary` (u is a 0..1 random number the caller supplies: shared code has no RNG).
function Sounds.pitchFor(slot: Slot, u: number): number
	local base = slot.pitch or 1
	if slot.vary then
		return base * (Sounds.PITCH_MIN + (Sounds.PITCH_MAX - Sounds.PITCH_MIN) * math.clamp(u, 0, 1))
	end
	return base
end

-- Rate limiter state: allow(state, key, now, cap) -> boolean. `state` is a table
-- the caller keeps ({[key]: {times}}); at most `cap` plays in any 1 s window.
function Sounds.allow(state: { [string]: { number } }, key: string, now: number, cap: number?): boolean
	if not cap or cap <= 0 then
		return true
	end
	local list = state[key]
	if not list then
		list = {}
		state[key] = list
	end
	local i = 1
	while i <= #list do
		if now - list[i] >= 1 then
			table.remove(list, i)
		else
			i += 1
		end
	end
	if #list >= cap then
		return false
	end
	table.insert(list, now)
	return true
end

return Sounds
