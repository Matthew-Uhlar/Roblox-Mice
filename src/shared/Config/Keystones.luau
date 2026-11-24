--!strict
-- (iteration 6, team Talents) The talent / ascension MECHANICS: tunables and the exact
-- text for every mechanic stat. Pure data, loads in Lune.
--
-- A mechanic is a numeric PlayerStats field (0 = off) set by a perk-tree node
-- (Config/ClassPerks, `tk*`) or an Ascension node (Config/AscensionNodes, `asc*`), so it
-- flows through every existing stat layer (Run/Stats.compute for perks, World ascMods
-- for ascension). Combat/Talents reads them at run time; the client (Visuals/TalentFx)
-- draws Fx {t = "tk", k = <kind>} events.
--
-- Rules (load-bearing):
--   * Damage from a mechanic hits MICE, champions and bosses only (never heroes), so
--     long-term progress never adds PvP damage. Shape / utility effects (charges, cooldown
--     refunds, invulnerability windows, heals) work everywhere.
--   * Every number below is the number the UI prints (Keystones.phrase).

local K = {}

-- Perk-tree mechanics ------------------------------------------------------------------
K.EMPOWER_DAMAGE = 1.75 -- an empowered weapon attack: x damage...
K.EMPOWER_AREA = 1.35 -- ...and x radius
K.FRENZY_MAX = 10 -- tkFrenzy: stacks (one per kill) of +value attack speed...
K.FRENZY_TIME = 3 -- ...each kill refreshes them for this many s
K.AURA_RADIUS = 9 -- tkAura: mice this close (x sqrt(area)) take value x weapon damage / s
K.AURA_TICK = 0.5
K.ORB_EVERY = 1.4 -- tkOrbs / ascSpirit: each orb zaps a mouse every this many s...
K.ORB_DAMAGE = 0.3 -- ...for this x weapon damage...
K.ORB_RANGE = 30 -- ...within this range of the hero
K.SHARD_DAMAGE = 0.35 -- tkShards: a kill flings value shards at mice within SHARD_RANGE
K.SHARD_RANGE = 12
K.CDKILL_CAP = 1.5 -- tkCdKill: at most this many s of cooldown refunded per s
K.COMBO_WINDOW = 6 -- tkCombo: casting a DIFFERENT slot within this many s of the last cast...
K.COMBO_TIME = 4 -- ...gives +value damage to mice for this many s
K.LASTSTAND_BELOW = 0.3 -- tkLastStand: dropping under this HP share heals value x max HP,
K.LASTSTAND_CD = 60 -- once per this many s, with a knockback burst and a short invulnerability
K.LASTSTAND_RADIUS = 10
K.LASTSTAND_INVULN = 1
K.RETALIATE_CD = 1.2 -- tkRetaliate: a mouse hit sets off a quake (value x weapon damage)
K.RETALIATE_RADIUS = 7
K.KILLHEAL_CAP = 5 -- tkKillHeal: at most this many kills per s heal
K.GUARD_TIME = 3 -- tkGuard: after a cast, value less damage from mice for this many s
K.NOVA_DAMAGE = 1.4 -- tkNova: every value s a pulse of this x weapon damage...
K.NOVA_RADIUS = 10 -- ...(x sqrt(area)) with knockback
K.NOVA_KNOCK = 6
K.CHARGE_GAP = 0.5 -- tkCharges: a held charge recasts slot 1 after this many s

-- Ascension mechanics ------------------------------------------------------------------
K.SECOND_WIND_BELOW = 0.25 -- node 1: under this HP share: heal, burst, invulnerable
K.SECOND_WIND_HEAL = 0.3
K.SECOND_WIND_CD = 90
K.SECOND_WIND_INVULN = 1.5
K.SECOND_WIND_RADIUS = 12
K.WAVE_DAMAGE = 0.6 -- node 2: every cast also sends a shockwave ring from the hero
K.WAVE_RADIUS = 10
K.WAVE_KNOCK = 7
K.OVERCHARGE = 2 -- node 6: the next value weapon attacks after a cast are empowered
K.ASC_FRENZY_KILLS = 12 -- node 7: this many kills inside ASC_FRENZY_WINDOW s...
K.ASC_FRENZY_WINDOW = 4
K.ASC_FRENZY_TIME = 6 -- ...start a Frenzy: +ASC_FRENZY_SPEED attack speed and
K.ASC_FRENZY_SPEED = 0.25 -- +ASC_FRENZY_DAMAGE damage to mice for this many s
K.ASC_FRENZY_DAMAGE = 0.1
K.STOMP_EVERY = 12 -- node 8: an Ancient Stomp every this many s...
K.STOMP_DAMAGE = 1.6 -- ...of this x weapon damage...
K.STOMP_RADIUS = 14 -- ...(x sqrt(area))...
K.STOMP_KNOCK = 8

-- Every mechanic field (perk `tk*` and ascension `asc*`), with its safe range.
K.FIELDS = table.freeze({
	tkEmpower = { 0, 12 }, -- every Nth weapon attack is empowered (0 = off; lowest N wins)
	tkCharge = { 0, 6 }, -- empowered weapon attacks after each ability cast
	tkFrenzy = { 0, 0.1 },
	tkAura = { 0, 2 },
	tkOrbs = { 0, 4 },
	tkShards = { 0, 6 },
	tkCdKill = { 0, 1 },
	tkCombo = { 0, 1 },
	tkLastStand = { 0, 1 },
	tkRetaliate = { 0, 5 },
	tkExecute = { 0, 0.3 },
	tkKillHeal = { 0, 0.05 },
	tkGuard = { 0, 0.6 },
	tkNova = { 0, 30 }, -- period in s (0 = off)
	tkCharges = { 0, 2 },
	ascSecondWind = { 0, 1 },
	ascWave = { 0, 1 },
	ascTrail = { 0, 1 },
	ascSpirit = { 0, 2 },
	ascEcho = { 0, 1 },
	ascOvercharge = { 0, 4 },
	ascFrenzy = { 0, 1 },
	ascStomp = { 0, 1 },
})

local function pct(v: number): string
	local x = math.floor(v * 1000 + 0.5) / 10
	return (if x == math.floor(x) then string.format("%d", x) else string.format("%.1f", x)) .. "%"
end
K.pct = pct

local function num(v: number): string
	local r = math.floor(v * 100 + 0.5) / 100
	return if r == math.floor(r) then string.format("%d", r) else tostring(r)
end

-- The exact text of a mechanic field at value `v` (nil for an unknown field).
local PHRASE: { [string]: (v: number) -> string } = {
	tkEmpower = function(v)
		return string.format(
			"every %s weapon attack is EMPOWERED (x%s damage, x%s size)",
			if v == 1 then "" else num(v) .. "th",
			num(K.EMPOWER_DAMAGE),
			num(K.EMPOWER_AREA)
		)
	end,
	tkCharge = function(v)
		return string.format(
			"after any ability, your next %s weapon attack%s %s EMPOWERED (x%s damage)",
			num(v),
			if v == 1 then "" else "s",
			if v == 1 then "is" else "are",
			num(K.EMPOWER_DAMAGE)
		)
	end,
	tkFrenzy = function(v)
		return string.format(
			"each kill adds +%s attack speed for %ss (up to %d stacks, +%s)",
			pct(v),
			num(K.FRENZY_TIME),
			K.FRENZY_MAX,
			pct(v * K.FRENZY_MAX)
		)
	end,
	tkAura = function(v)
		return string.format(
			"an aura deals %s of your weapon damage per second to mice within %s studs",
			pct(v),
			num(K.AURA_RADIUS)
		)
	end,
	tkOrbs = function(v)
		return string.format(
			"%s orb%s circle%s you, each zapping a mouse every %ss for %s weapon damage",
			num(v),
			if v == 1 then "" else "s",
			if v == 1 then "s" else "",
			num(K.ORB_EVERY),
			pct(K.ORB_DAMAGE)
		)
	end,
	tkShards = function(v)
		return string.format(
			"kills fling %s shard%s at nearby mice (%s weapon damage each)",
			num(v),
			if v == 1 then "" else "s",
			pct(K.SHARD_DAMAGE)
		)
	end,
	tkCdKill = function(v)
		return string.format(
			"each kill cuts every ability cooldown by %ss (max %ss per second)",
			num(v),
			num(K.CDKILL_CAP)
		)
	end,
	tkCombo = function(v)
		return string.format(
			"casting a different ability slot within %ss of your last cast: +%s damage to mice for %ss",
			num(K.COMBO_WINDOW),
			pct(v),
			num(K.COMBO_TIME)
		)
	end,
	tkLastStand = function(v)
		return string.format(
			"dropping under %s HP heals %s of max HP, knocks mice back and makes you invulnerable for %ss (every %ss)",
			pct(K.LASTSTAND_BELOW),
			pct(v),
			num(K.LASTSTAND_INVULN),
			num(K.LASTSTAND_CD)
		)
	end,
	tkRetaliate = function(v)
		return string.format(
			"when a mouse hits you, a quake deals %s weapon damage around you (every %ss)",
			pct(v),
			num(K.RETALIATE_CD)
		)
	end,
	tkExecute = function(v)
		return string.format("your hits finish mice (not champions or bosses) under %s HP", pct(v))
	end,
	tkKillHeal = function(v)
		return string.format("each kill heals %s of max HP", pct(v))
	end,
	tkGuard = function(v)
		return string.format(
			"after any ability, take %s less damage from mice for %ss",
			pct(v),
			num(K.GUARD_TIME)
		)
	end,
	tkNova = function(v)
		return string.format(
			"every %ss a pulse deals %s weapon damage around you and knocks mice back",
			num(v),
			pct(K.NOVA_DAMAGE)
		)
	end,
	tkCharges = function(v)
		return string.format("ability slot 1 holds %s extra charge%s", num(v), if v == 1 then "" else "s")
	end,
	ascSecondWind = function(_v)
		return string.format(
			"Second Wind: under %s HP you heal %s of max HP, blast mice away and are invulnerable for %ss (every %ss)",
			pct(K.SECOND_WIND_BELOW),
			pct(K.SECOND_WIND_HEAL),
			num(K.SECOND_WIND_INVULN),
			num(K.SECOND_WIND_CD)
		)
	end,
	ascWave = function(_v)
		return string.format(
			"every ability cast also sends out a shockwave (%s weapon damage, knockback)",
			pct(K.WAVE_DAMAGE)
		)
	end,
	ascTrail = function(_v)
		return "your weapon glows and leaves an ascended trail"
	end,
	ascSpirit = function(v)
		return string.format(
			"%s spirit calf%s circle%s you, zapping a mouse every %ss for %s weapon damage",
			num(v),
			if v == 1 then "" else "s",
			if v == 1 then "s" else "",
			num(K.ORB_EVERY),
			pct(K.ORB_DAMAGE)
		)
	end,
	ascEcho = function(_v)
		return "a ghostly echo of you repeats each ability"
	end,
	ascOvercharge = function(v)
		return string.format(
			"Overcharge: after any ability your next %s weapon attacks are EMPOWERED (x%s damage)",
			num(v),
			num(K.EMPOWER_DAMAGE)
		)
	end,
	ascFrenzy = function(_v)
		return string.format(
			"Frenzy: %d kills within %ss: +%s attack speed and +%s damage to mice for %ss",
			K.ASC_FRENZY_KILLS,
			num(K.ASC_FRENZY_WINDOW),
			pct(K.ASC_FRENZY_SPEED),
			pct(K.ASC_FRENZY_DAMAGE),
			num(K.ASC_FRENZY_TIME)
		)
	end,
	ascStomp = function(_v)
		return string.format(
			"Ancient Stomp: every %ss a quake deals %s weapon damage within %s studs",
			num(K.STOMP_EVERY),
			pct(K.STOMP_DAMAGE),
			num(K.STOMP_RADIUS)
		)
	end,
}
K.PHRASE = PHRASE

function K.phrase(field: string, v: number): string?
	local f = PHRASE[field]
	return if f then f(v) else nil
end

function K.isField(field: any): boolean
	return type(field) == "string" and K.FIELDS[field] ~= nil
end

return K
