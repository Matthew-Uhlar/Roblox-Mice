--!strict
-- v4 "The Melt" (docs/V4-PLAN.md "Maps and storm"): a closing circle that pushes
-- squads toward the centre during the waves and squeezes a long boss fight.
-- Pure data + pure helpers. Two ways to drive it:
--   * RunDirector calls world:setZone(Storm.toWorld(Storm.zoneAt(...), t0)) at
--     each step (the contract), or
--   * world:setStormPlan({radius, stage, seed, duration?}) and the World follows
--     this schedule by itself (waves: wave clock; boss: time since the boss spawned).
--
-- Times are seconds into the waves for REFERENCE_WAVE (150 s) waves; other
-- durations scale them (stage 1 may use 165 s). Radii are fractions of the stage's
-- arena radius R (Config/Maps.stageRadius). Damage outside the circle is a
-- fraction of max HP per second; it ignores armor, dodge and i-frames and never
-- interrupts POI channels or sprint (Combat/World).
--
-- Steps (wave time): each one is a zone {r, toR, closeStart, closeEnd, dps}:
--   0 s    edge   -> 0.65 R closing 30-60    dps 2%
--   60 s   0.65 R -> 0.40 R closing 85-110   dps 2% (Circle 2 shown)
--   85 s   same geometry                     dps 4%
--   110 s  0.40 R -> 0.22 R closing 125-150  dps 4% (Circle 3 = the boss ring)
--   125 s  same geometry                     dps 8%
--   boss   holds 0.22 R (8%); BOSS_SQUEEZE.after s into the fight it closes to
--          0.12 R over BOSS_SQUEEZE.over s at 12%.
-- The centre is the arena centre offset by up to CENTER_OFFSET x R (seeded, one
-- per stage); every circle shares it, so each circle sits inside the last.

local Rng = require("../Util/Rng")

local Storm = {}

Storm.REFERENCE_WAVE = 150
Storm.CIRCLES = table.freeze({
	table.freeze({ frac = 0.65, close = table.freeze({ 30, 60 }), dps = 0.02 }),
	table.freeze({ frac = 0.40, close = table.freeze({ 85, 110 }), dps = 0.04 }),
	table.freeze({ frac = 0.22, close = table.freeze({ 125, 150 }), dps = 0.08 }),
})
Storm.BOSS_SQUEEZE = table.freeze({ after = 90, over = 30, frac = 0.12, dps = 0.12 })
Storm.CENTER_OFFSET = 0.1 -- x R: max distance of the circle centre from the arena centre
Storm.SAFE_CORNERS_OFF = 30 -- s into the waves: squad safe corners stop working
Storm.CENTER_SALT = 0x5703 -- seed salt for the centre roll

export type Zone = {
	cx: number,
	cz: number,
	r: number, -- radius before the close
	toR: number, -- radius after the close (== r: holding)
	closeStart: number,
	closeEnd: number,
	dps: number, -- fraction of max HP per second outside
	step: number?, -- schedule index (1..), "boss" steps are 100+
}

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function timeScale(duration: number?): number
	if finite(duration) and (duration :: number) > 0 then
		return (duration :: number) / Storm.REFERENCE_WAVE
	end
	return 1
end

-- The stage's circle centre: arena centre + up to CENTER_OFFSET x R (seeded).
function Storm.center(R: number, stage: number, seed: number?): (number, number)
	local s = if finite(seed) then math.floor(seed :: number) else 0
	local st = if finite(stage) then math.floor(stage) else 1
	local rng = Rng.new(s + Storm.CENTER_SALT + st * 7919)
	local ang = rng:range(0, math.pi * 2)
	local d = math.sqrt(rng:nextFloat()) * Storm.CENTER_OFFSET * math.max(0, R)
	return math.cos(ang) * d, math.sin(ang) * d
end

-- Every wave step (wave time): {at, zone}. See the header table.
function Storm.schedule(
	R: number,
	stage: number,
	seed: number?,
	duration: number?
): { { at: number, zone: Zone } }
	local k = timeScale(duration)
	local cx, cz = Storm.center(R, stage, seed)
	local out = {}
	local prevR = R
	local prevDps = Storm.CIRCLES[1].dps
	for i, c in Storm.CIRCLES do
		local toR = c.frac * R
		local cs, ce = c.close[1] * k, c.close[2] * k
		-- the circle is shown when the previous one has closed (wave start for the first)
		local shownAt = if i == 1 then 0 else Storm.CIRCLES[i - 1].close[2] * k
		local function zone(dps: number, step: number): Zone
			return {
				cx = cx,
				cz = cz,
				r = prevR,
				toR = toR,
				closeStart = cs,
				closeEnd = ce,
				dps = dps,
				step = step,
			}
		end
		if shownAt < cs and i > 1 then
			table.insert(out, { at = shownAt, zone = zone(prevDps, #out + 1) })
		end
		table.insert(out, { at = if i == 1 then 0 else cs, zone = zone(c.dps, #out + 1) })
		prevR = toR
		prevDps = c.dps
	end
	return out
end

-- The zone in force `waveT` seconds into the waves (wave-time close times).
function Storm.zoneAt(R: number, stage: number, waveT: number, seed: number?, duration: number?): Zone
	local steps = Storm.schedule(R, stage, seed, duration)
	local pick = steps[1]
	local t = if finite(waveT) then waveT else 0
	for _, s in steps do
		if t >= s.at then
			pick = s
		end
	end
	return table.clone(pick.zone)
end

-- The zone during the boss fight, `bossT` seconds after the boss spawned. Close
-- times are in boss time (add the boss spawn's world time with Storm.toWorld).
function Storm.bossZone(R: number, stage: number, bossT: number, seed: number?): Zone
	local cx, cz = Storm.center(R, stage, seed)
	local last = Storm.CIRCLES[#Storm.CIRCLES]
	local hold = last.frac * R
	local sq = Storm.BOSS_SQUEEZE
	local t = if finite(bossT) then bossT else 0
	if t < sq.after then
		return {
			cx = cx,
			cz = cz,
			r = hold,
			toR = hold,
			closeStart = 0,
			closeEnd = 0,
			dps = last.dps,
			step = 100,
		}
	end
	return {
		cx = cx,
		cz = cz,
		r = hold,
		toR = sq.frac * R,
		closeStart = sq.after,
		closeEnd = sq.after + sq.over,
		dps = sq.dps,
		step = 101,
	}
end

-- Shifts a zone's close times from wave (or boss) time to world time: t0 = the
-- world time the waves (or the boss) started. Returns a new table for world:setZone.
function Storm.toWorld(zone: Zone, t0: number): Zone
	local z = table.clone(zone)
	local base = if finite(t0) then t0 else 0
	z.closeStart += base
	z.closeEnd += base
	return z
end

-- Radius of `zone` at time t (same clock as its close times).
function Storm.radiusAt(zone: Zone, t: number): number
	if t <= zone.closeStart or zone.closeEnd <= zone.closeStart then
		return if t >= zone.closeEnd and zone.closeEnd > zone.closeStart then zone.toR else zone.r
	end
	if t >= zone.closeEnd then
		return zone.toR
	end
	local a = (t - zone.closeStart) / (zone.closeEnd - zone.closeStart)
	return zone.r + (zone.toR - zone.r) * a
end

-- Squad safe corners work only before SAFE_CORNERS_OFF s (scaled like the waves).
function Storm.safeCornersOn(waveT: number, duration: number?): boolean
	return finite(waveT) and waveT < Storm.SAFE_CORNERS_OFF * timeScale(duration)
end

return Storm
