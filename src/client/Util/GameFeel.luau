--!strict
-- GameFeel (iteration 7 §B2, team Client): pure rules for hit-stop, impact
-- shakes and cast sounds. No Roblox APIs (Lune-tested, ClientIter7.spec).
-- Controllers/GameFeel applies them; CameraController scales every shake by
-- GameFeel.shakeMult(setting, fx).
--
--   Screen shake setting "full" | "low" | "off": profile.settings.shake when
--   the server allowlists the key (Data/Settings.STRING_KEYS.shake), else a
--   client-only pick (State "feel"). Effects "off" also turns shakes off.
--   Cast sounds setting "full" | "low" | "off" (same storage, key "castSfx").
--   Ability casting "quick" | "hold" (key "castMode", QC iteration 7): quick casts
--   on key press with no preview (the default on keyboard / mouse and gamepad);
--   hold shows the aim preview and casts on release. Phones keep drag-to-aim.

local GameFeel = {}

GameFeel.SHAKE = { "full", "low", "off" }
GameFeel.SHAKE_LABEL = { full = "Full", low = "Low", off = "Off" } :: { [string]: string }
GameFeel.CAST = { "full", "low", "off" }
GameFeel.CAST_LABEL = { full = "Full", low = "Quiet", off = "Off" } :: { [string]: string }

GameFeel.BIG_HIT = 60 -- an own hit at least this big (or a crit this big) is "big"
GameFeel.HITSTOP_MIN_GAP = 0.3 -- s between hit-stops
GameFeel.HITSTOP_HIT = 0.045 -- s: a big own crit
GameFeel.HITSTOP_KILL = 0.07 -- s: an own boss / champion kill
GameFeel.HITSTOP_MAX = 0.08
GameFeel.SHAKE_MAX = 0.9 -- studs: impact shakes stay small
GameFeel.OTHERS_VOLUME = 0.45 -- squadmates' cast sounds (x the slot volume)

function GameFeel.shake(v: any): string
	return if v == "low" or v == "off" then v else "full"
end

function GameFeel.cast(v: any): string
	return if v == "low" or v == "off" then v else "full"
end

-- Shake multiplier for a setting and the Effects level.
function GameFeel.shakeMult(shake: string, fx: string?): number
	if fx == "off" or shake == "off" then
		return 0
	elseif shake == "low" then
		return 0.45
	end
	return 1
end

-- Cast-sound volume multiplier for a setting.
function GameFeel.castVolume(v: string): number
	if v == "off" then
		return 0
	elseif v == "low" then
		return 0.5
	end
	return 1
end

-- The live pair from the profile (when saved there) and the local pick (wins).
GameFeel.CAST_MODE = { "quick", "hold" }
GameFeel.CAST_MODE_LABEL = { quick = "Quick", hold = "Hold to aim" } :: { [string]: string }

function GameFeel.castMode(v: any): string
	return if v == "hold" then "hold" else "quick"
end

-- Whether a key press casts at once (quick) rather than starting a hold.
function GameFeel.castsOnPress(mode: string): boolean
	return mode ~= "hold"
end

function GameFeel.fromProfile(
	profile: any,
	localPick: any
): { shake: string, castSfx: string, castMode: string, smartCast: boolean }
	local st = if type(profile) == "table" and type(profile.settings) == "table" then profile.settings else {}
	local lp = if type(localPick) == "table" then localPick else {}
	return {
		shake = GameFeel.shake(if lp.shake ~= nil then lp.shake else st.shake),
		castSfx = GameFeel.cast(if lp.castSfx ~= nil then lp.castSfx else st.castSfx),
		castMode = GameFeel.castMode(if lp.castMode ~= nil then lp.castMode else st.castMode),
		-- iteration 8: phone smart-cast (Util/SmartCast), saved as a boolean
		smartCast = (if lp.smartCast ~= nil then lp.smartCast else st.smartCast) == true,
	}
end

-- Hit-stop seconds for one Fx event seen by local user `me` (0 = none).
--   hit {by = me, amount, crit}: a big crit -> HITSTOP_HIT
--   die {by = me, kind} of a boss / champion -> HITSTOP_KILL (`bigTarget`: the
--   caller's HordeRenderer.isBoss check)
function GameFeel.hitStopFor(ev: any, me: number, bigTarget: boolean?): number
	if type(ev) ~= "table" or tonumber(ev.by) ~= me then
		return 0
	end
	if ev.t == "hit" then
		local amount = tonumber(ev.amount) or 0
		if ev.crit == true and amount >= GameFeel.BIG_HIT then
			return GameFeel.HITSTOP_HIT
		end
		if amount >= GameFeel.BIG_HIT * 4 then
			return GameFeel.HITSTOP_HIT
		end
	elseif ev.t == "die" then
		local kind = tostring(ev.kind or "")
		if
			bigTarget == true
			or ev.boss == true
			or ev.champ == true
			or string.find(kind, "boss", 1, true)
			or string.find(kind, "champ", 1, true)
		then
			return GameFeel.HITSTOP_KILL
		end
	end
	return 0
end

-- Whether a hit-stop may start now (rate limit).
function GameFeel.mayStop(lastAt: number, now: number): boolean
	return now - lastAt >= GameFeel.HITSTOP_MIN_GAP
end

-- Impact shake (studs) for damage `amount`: small, grows with the hit, capped.
-- `own` = dealt by the local hero; `taken` = the local hero was hit.
function GameFeel.impactShake(amount: number, crit: boolean?, taken: boolean?): number
	local a = math.max(0, tonumber(amount) or 0)
	if a <= 0 then
		return 0
	end
	local base = if taken then a / 60 else a / 220
	if crit then
		base *= 1.4
	end
	if base < 0.12 then
		return 0
	end
	return math.min(GameFeel.SHAKE_MAX, base)
end

-- Cast sounds: ability kind -> (Config/Sounds slot, pitch offset). Every kind
-- gets its own slot + pitch pair so the 70+ abilities stop sounding alike.
-- Only slots built from Roblox's own client sounds or our procedural audio.
GameFeel.KIND_SOUND = table.freeze({
	dash = { "swing", 0.25 },
	burst = { "boom", -0.05 },
	ring = { "stomp", 0.1 },
	shield = { "gear", -0.25 },
	puddle = { "pickup", -0.35 },
	hover = { "swing", -0.3 },
	field = { "tele", -0.1 },
	turret = { "gear", 0.15 },
	barricade = { "stomp", -0.2 },
	repair = { "levelUpChime", -0.1 },
	chain = { "critDing", 0.25 },
	vortex = { "tele", -0.35 },
	leap = { "swing", -0.1 },
	mark = { "critDing", -0.25 },
	lance = { "crit", 0.3 },
	tether = { "levelUpChime", -0.3 },
	anchor = { "stomp", -0.4 },
} :: { [string]: { any } })

-- Signature trumpet pitch per class (one distinct trumpet per class).
GameFeel.CLASS_PITCH = table.freeze({
	elephante = 0,
	ele_fonte = 0.12,
	ellie_fawn = 0.24,
	le_fante = -0.12,
	filet = 0.32,
	jumbo = -0.28,
	fizzante = 0.18,
	tinkerphant = -0.06,
	ele_vation = 0.4,
	elephaid = 0.06,
	trunkillery = -0.36,
} :: { [string]: number })

export type CastSound = { key: string, pitch: number }

-- The sounds one ability cast plays: the kind's sound, then (own casts only)
-- the class signature trumpet. Unknown kinds fall back to "boom".
function GameFeel.castSounds(kind: any, classId: any, own: boolean): { CastSound }
	local k = GameFeel.KIND_SOUND[tostring(kind)]
	local out: { CastSound } = {
		{ key = if k then k[1] else "boom", pitch = if k then k[2] else 0 },
	}
	if own then
		local cp = GameFeel.CLASS_PITCH[tostring(classId)]
		if cp == nil and type(classId) == "string" then
			-- a class we do not know yet: a stable pitch from its id
			local h = 0
			for i = 1, #classId do
				h = (h * 31 + string.byte(classId, i)) % 997
			end
			cp = (h % 9 - 4) * 0.08
		end
		table.insert(out, { key = "trumpet", pitch = cp or 0 })
	end
	return out
end

return GameFeel
