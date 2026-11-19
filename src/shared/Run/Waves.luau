--!strict
-- Run/Waves: numbered waves and the Early Horn (docs/iter/2/ALIGNMENT.md §2b,
-- iteration-2 PLAN). Pure: the caller passes the clock.
--
-- Each stage is 5 numbered waves (20 per match): waves 1-4 are WAVE_SECONDS
-- hordes with a LULL_SECONDS lull between them; wave 5 is the boss wave
-- (RunDirector's boss phase). The match-wide index is (stage - 1) * 5 + n.
--
-- Early Horn ("Skip Wave At"): with the leader's setting at 50 / 70 / 90 (% of the
-- wave's budget stomped), once the wave has run HORN_MIN_SECONDS and enough is
-- stomped, the horn sounds: HORN_WARN_SECONDS later the next wave starts. Every
-- skipped second pays HORN_RINDS rinds to each standing hero. A manual horn
-- (C2S, team U's button) obeys the same minimum time and needs MANUAL_MIN stomped.
--
-- "Virtual wave time" (waveTime) maps the waves onto the storm schedule: wave n
-- starts at (n - 1) * (WAVE_SECONDS + LULL_SECONDS), so the Melt follows the wave
-- index and a horn shrinks the map with the pace.

local Waves = {}

Waves.PER_STAGE = 5 -- the 5th is the boss wave
Waves.HORDE_WAVES = 4
Waves.WAVE_SECONDS = 30
Waves.LULL_SECONDS = 4
Waves.HORN_MIN_SECONDS = 10
Waves.HORN_WARN_SECONDS = 3
Waves.HORN_RINDS = 3 -- per skipped second, per standing hero
Waves.MANUAL_MIN = 0.5 -- a manual horn needs at least half the wave stomped
Waves.SETTINGS = table.freeze({ 0, 50, 70, 90 }) -- 0 = Off
-- the budget estimate (team M1's WaveDirector owns the real one): per hero per
-- second, ramping x1.0 at wave 1 to x3.2 at wave 19
Waves.PER_HERO_RATE = 0.9
Waves.RAMP_FROM, Waves.RAMP_TO = 1.0, 3.2

export type State = {
	stage: number,
	wave: number, -- 1..HORDE_WAVES in this stage (5 = boss)
	phase: string, -- "wave" | "lull" | "horn" | "done"
	startedAt: number, -- this wave's (or lull's / horn's) start
	waveStart: number, -- this wave's start (horn timing)
	kills: number, -- mice stomped this wave
	budget: number, -- this wave's expected mice
	horns: number, -- horns this stage
	skipped: number, -- seconds skipped by horns this stage
	skippedNow: number, -- seconds the current horn skipped (paid once)
	hornAll: boolean, -- every horde wave so far was called early
	waveSeconds: number, -- timing (Waves.new `scale`: tests shorten the waves)
	lullSeconds: number,
	hornMin: number,
}

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function Waves.index(stage: number, wave: number): number
	return (math.max(1, stage) - 1) * Waves.PER_STAGE + wave
end

function Waves.total(stages: number): number
	return stages * Waves.PER_STAGE
end

-- Expected mice in wave `index` (1..20) for `heroes` heroes.
function Waves.budget(heroes: number, index: number, perHeroRate: number?): number
	local i = math.clamp(index, 1, 19)
	local ramp = Waves.RAMP_FROM + (Waves.RAMP_TO - Waves.RAMP_FROM) * (i - 1) / 18
	local rate = if finite(perHeroRate) then perHeroRate :: number else Waves.PER_HERO_RATE
	return math.max(1, rate * math.max(1, heroes) * Waves.WAVE_SECONDS * ramp)
end

-- The horde phase of one stage; `heroes` sizes the first wave's budget. `scale`
-- (default 1) multiplies the wave, lull and minimum-horn times (test knobs).
function Waves.new(stage: number, now: number, heroes: number, perHeroRate: number?, scale: number?): State
	local k = if finite(scale) and (scale :: number) > 0 then scale :: number else 1
	return {
		waveSeconds = Waves.WAVE_SECONDS * k,
		lullSeconds = Waves.LULL_SECONDS * k,
		hornMin = math.max(1, Waves.HORN_MIN_SECONDS * k),
		stage = stage,
		wave = 1,
		phase = "wave",
		startedAt = now,
		waveStart = now,
		kills = 0,
		budget = Waves.budget(heroes, Waves.index(stage, 1), perHeroRate) * k,
		horns = 0,
		skipped = 0,
		skippedNow = 0,
		hornAll = true,
	}
end

function Waves.noteKill(s: State, n: number?)
	if s.phase == "wave" or s.phase == "horn" then
		s.kills += n or 1
	end
end

function Waves.stomped(s: State): number
	return math.clamp(s.kills / math.max(1, s.budget), 0, 1)
end

-- The horde waves' virtual time (the storm's wave clock).
function Waves.waveTime(s: State, now: number): number
	local slot = s.waveSeconds + s.lullSeconds
	local base = (s.wave - 1) * slot
	if s.phase == "done" then
		return Waves.HORDE_WAVES * slot - s.lullSeconds
	elseif s.phase == "lull" then
		return base + s.waveSeconds + math.min(s.lullSeconds, now - s.startedAt)
	end
	return base + math.min(s.waveSeconds, now - s.waveStart)
end

-- The horde waves' full length without horns (the storm schedule's duration).
function Waves.hordeSeconds(s: State?): number
	local w = if s then s.waveSeconds else Waves.WAVE_SECONDS
	local l = if s then s.lullSeconds else Waves.LULL_SECONDS
	return Waves.HORDE_WAVES * (w + l) - l
end

-- Can the horn sound now? `threshold` = % (0 = Off); `manual` = a player's button.
function Waves.canHorn(s: State, now: number, threshold: number?, manual: boolean?): boolean
	if s.phase ~= "wave" or now - s.waveStart < s.hornMin then
		return false
	end
	if now - s.waveStart >= s.waveSeconds - Waves.HORN_WARN_SECONDS then
		return false -- too late to skip anything
	end
	local need = if manual
		then Waves.MANUAL_MIN
		else (if finite(threshold) and threshold :: number > 0 then threshold :: number / 100 else nil)
	if need == nil then
		return false
	end
	return Waves.stomped(s) >= need
end

-- Sounds the horn: the next wave starts HORN_WARN_SECONDS from now. Returns the
-- seconds it skips.
function Waves.horn(s: State, now: number): number
	local skipped = math.max(0, s.waveSeconds - (now - s.waveStart) - Waves.HORN_WARN_SECONDS)
	s.phase = "horn"
	s.startedAt = now
	s.horns += 1
	s.skipped += skipped
	s.skippedNow = skipped
	return skipped
end

-- Advances the clock. Returns an event: "wave" (a new horde wave began),
-- "lull" (a wave ended), "boss" (the 4th wave is over: the boss wave),
-- or nil. `heroes` sizes the next wave's budget.
function Waves.tick(s: State, now: number, heroes: number, perHeroRate: number?): string?
	if s.phase == "done" then
		return nil
	end
	local function nextWave(): string
		if s.wave >= Waves.HORDE_WAVES then
			s.phase = "done"
			return "boss"
		end
		s.wave += 1
		s.phase = "wave"
		s.startedAt = now
		s.waveStart = now
		s.kills = 0
		s.budget = Waves.budget(heroes, Waves.index(s.stage, s.wave), perHeroRate)
			* (s.waveSeconds / Waves.WAVE_SECONDS)
		return "wave"
	end
	if s.phase == "wave" and now - s.waveStart >= s.waveSeconds then
		s.hornAll = false
		if s.wave >= Waves.HORDE_WAVES then
			s.phase = "done"
			return "boss"
		end
		s.phase = "lull"
		s.startedAt = now
		return "lull"
	elseif s.phase == "lull" and now - s.startedAt >= s.lullSeconds then
		return nextWave()
	elseif s.phase == "horn" and now - s.startedAt >= Waves.HORN_WARN_SECONDS then
		return nextWave()
	end
	return nil
end

-- The leader's Skip Wave At setting (profile.settings.skipWaveAt, team P): one of
-- SETTINGS; rookies (runs 0-2) default to Off, everyone else to 70.
function Waves.setting(raw: any, rookie: boolean?): number
	if finite(raw) and table.find(Waves.SETTINGS, raw) then
		return raw
	end
	return if rookie then 0 else 70
end

return Waves
