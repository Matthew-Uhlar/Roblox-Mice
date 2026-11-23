--!strict
-- Run/Pace (iteration 6 §2, team Flow): the match pace the lobby leader picks next to
-- the tier (C2S SetPace, saved in profile.settings.pace). Pure.
--
--   normal  today's pacing (every multiplier 1)
--   fast    horde wave timers x0.7 (waves and lulls; the Melt follows the wave clock),
--           mouse spawn rate x1.35, the boss storm squeeze x0.8 (it starts and closes
--           sooner), boss HP x1.0; rewards: cheese x1.15, class XP x1.15 (stomps are
--           naturally higher). Records and Best Solo stay per tier: a Fast clear counts.

local Pace = {}

export type PaceId = "normal" | "fast"
export type PaceDef = {
	id: PaceId,
	name: string,
	wave: number, -- x horde wave and lull seconds
	spawn: number, -- x mouse spawn rate (WorldMods.spawnRateMult)
	storm: number, -- x the boss storm squeeze times
	bossHp: number, -- x boss HP
	cheese: number, -- x payout cheese
	classXp: number, -- x class XP
}

Pace.NORMAL = "normal" :: PaceId
Pace.FAST = "fast" :: PaceId
Pace.DEFAULT = Pace.NORMAL
Pace.ORDER = table.freeze({ Pace.NORMAL, Pace.FAST })

Pace.DEFS = table.freeze({
	normal = table.freeze({
		id = Pace.NORMAL,
		name = "Normal",
		wave = 1,
		spawn = 1,
		storm = 1,
		bossHp = 1,
		cheese = 1,
		classXp = 1,
	}),
	fast = table.freeze({
		id = Pace.FAST,
		name = "Fast",
		wave = 0.7,
		spawn = 1.35,
		storm = 0.8,
		bossHp = 1.0,
		cheese = 1.15,
		classXp = 1.15,
	}),
}) :: { [string]: PaceDef }

-- Any value -> a valid pace id ("normal" unless exactly "fast").
function Pace.clamp(v: any): PaceId
	if v == Pace.FAST then
		return Pace.FAST
	end
	return Pace.NORMAL
end

function Pace.isValid(v: any): boolean
	return type(v) == "string" and Pace.DEFS[v] ~= nil
end

function Pace.get(v: any): PaceDef
	return Pace.DEFS[Pace.clamp(v)]
end

function Pace.isFast(v: any): boolean
	return Pace.clamp(v) == Pace.FAST
end

-- Multiplies the pace onto WorldMods (in place; returns it).
function Pace.applyMods(mods: any, pace: any): any
	local def = Pace.get(pace)
	if type(mods) ~= "table" then
		return mods
	end
	if def.spawn ~= 1 and type(mods.spawnRateMult) == "number" then
		mods.spawnRateMult *= def.spawn
	end
	if def.bossHp ~= 1 and type(mods.bossHpMult) == "number" then
		mods.bossHpMult *= def.bossHp
	end
	return mods
end

-- The horde phase length (waves + lulls) for a base length.
function Pace.waveSeconds(base: number, pace: any): number
	return base * Pace.get(pace).wave
end

-- The lobby / Match / Results view: {id, name, fast?}.
function Pace.view(pace: any): { [string]: any }
	local def = Pace.get(pace)
	return {
		id = def.id,
		name = def.name,
		fast = if def.id == Pace.FAST then true else nil,
		wave = def.wave,
		spawn = def.spawn,
		cheese = def.cheese,
		classXp = def.classXp,
	}
end

-- The settings.pace value to store: "fast", or nil for the default (normal).
function Pace.stored(v: any): string?
	return if Pace.clamp(v) == Pace.FAST then Pace.FAST else nil
end

return Pace
