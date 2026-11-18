--!strict
-- Pure maths for Controllers/HeroTags (no Roblox APIs; tested in
-- tests/specs/ClientHeroTags.spec.luau).
--
--   HeroTagMath.ease(shown, target, dt, time?)     frame-rate independent lerp:
--                                                  ~95% of the way in `time` s
--   HeroTagMath.newBar(frac) -> Bar                {shown, chip, hold}
--   HeroTagMath.stepBar(bar, target, dt) -> chipAlpha
--                                                  eases the fill, holds then
--                                                  drains the white damage chip;
--                                                  returns the chip's opacity 0..1
--   HeroTagMath.fade(relation, dist) -> (scale, alpha)
--                                                  enemies shrink and fade with
--                                                  distance; you and allies never
--   HeroTagMath.marker(relation, downed) -> string  "▼" ally, "" otherwise
--   HeroTagMath.downIcon(relation) -> string       🩹 own squad / 💀 enemy

local HeroTagMath = {}

HeroTagMath.EASE_TIME = 0.15 -- s for the fill to reach a new HP
HeroTagMath.CHIP_HOLD = 0.35 -- s the damage chip waits before draining
HeroTagMath.CHIP_TIME = 0.45 -- s for the chip to drain to the fill
-- Enemy distance fade (studs from your hero): full until NEAR, then shrink to
-- FAR_SCALE and fade to FAR_ALPHA at FAR (~120), then out by CUT.
HeroTagMath.NEAR = 70
HeroTagMath.FAR = 120
HeroTagMath.CUT = 180
HeroTagMath.FAR_SCALE = 0.7
HeroTagMath.FAR_ALPHA = 0.55
HeroTagMath.MIN_SCALE = 0.55

local LN20 = math.log(20) -- 1 - e^-ln20 = 0.95

local function finite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

function HeroTagMath.ease(shown: number, target: number, dt: number, time: number?): number
	if not finite(target) then
		return if finite(shown) then shown else 0
	end
	if not finite(shown) then
		return target
	end
	local t = time or HeroTagMath.EASE_TIME
	if not finite(dt) or dt <= 0 then
		return shown
	end
	if t <= 0 then
		return target
	end
	local k = 1 - math.exp(-dt * LN20 / t)
	local v = shown + (target - shown) * k
	if math.abs(target - v) < 1e-3 then
		return target
	end
	return v
end

export type Bar = { shown: number, chip: number, hold: number }

function HeroTagMath.newBar(frac: number?): Bar
	local f = math.clamp(if finite(frac) then frac :: number else 1, 0, 1)
	return { shown = f, chip = f, hold = 0 }
end

-- One frame of a health bar towards `target` (0..1). A drop leaves the chip
-- where the fill was; it holds CHIP_HOLD s (a new drop re-arms it), then drains
-- to the fill. A heal snaps the chip to the fill. Returns the chip opacity:
-- 1 while held, fading as it drains, 0 once it meets the fill.
function HeroTagMath.stepBar(bar: Bar, target: number, dt: number): number
	local t = math.clamp(if finite(target) then target else bar.shown, 0, 1)
	local before = bar.shown
	bar.shown = HeroTagMath.ease(bar.shown, t, dt)
	if t < before - 1e-4 then
		bar.hold = HeroTagMath.CHIP_HOLD -- new damage
		if bar.chip < before then
			bar.chip = before
		end
	end
	if bar.chip <= bar.shown then
		bar.chip = bar.shown
		bar.hold = 0
		return 0
	end
	if bar.hold > 0 then
		bar.hold = math.max(0, bar.hold - (if finite(dt) then dt else 0))
		return 1
	end
	local gap0 = bar.chip - bar.shown
	bar.chip = HeroTagMath.ease(bar.chip, bar.shown, dt, HeroTagMath.CHIP_TIME)
	local gap = bar.chip - bar.shown
	if gap <= 1e-3 then
		bar.chip = bar.shown
		return 0
	end
	-- fade with the drain: a big gap stays bright, the tail end disappears
	return math.clamp(gap / math.max(gap0, 0.05), 0, 1) * math.clamp(gap * 8, 0.25, 1)
end

local function lerp(a: number, b: number, x: number): number
	return a + (b - a) * math.clamp(x, 0, 1)
end

-- (scale, alpha) for a tag at `dist` studs. "self" / "ally" are always (1, 1).
-- Enemies: 1 until NEAR, then down to (FAR_SCALE, FAR_ALPHA) at FAR, then to
-- (MIN_SCALE, 0) at CUT. alpha 0 = hide the tag.
function HeroTagMath.fade(relation: string, dist: number?): (number, number)
	if relation == "self" or relation == "ally" then
		return 1, 1
	end
	local d = if finite(dist) then dist :: number else 0
	if d <= HeroTagMath.NEAR then
		return 1, 1
	elseif d <= HeroTagMath.FAR then
		local x = (d - HeroTagMath.NEAR) / (HeroTagMath.FAR - HeroTagMath.NEAR)
		return lerp(1, HeroTagMath.FAR_SCALE, x), lerp(1, HeroTagMath.FAR_ALPHA, x)
	elseif d < HeroTagMath.CUT then
		local x = (d - HeroTagMath.FAR) / (HeroTagMath.CUT - HeroTagMath.FAR)
		return lerp(HeroTagMath.FAR_SCALE, HeroTagMath.MIN_SCALE, x), lerp(HeroTagMath.FAR_ALPHA, 0, x)
	end
	return HeroTagMath.MIN_SCALE, 0
end

-- Snap a 0..1 value to steps of 1/n so GUI properties are only written when the
-- visible value really changes.
function HeroTagMath.quantize(v: number, n: number?): number
	local steps = n or 20
	return math.floor(math.clamp(if finite(v) then v else 0, 0, 1) * steps + 0.5) / steps
end

function HeroTagMath.marker(relation: string, _downed: boolean?): string
	return if relation == "ally" then "▼" else ""
end

function HeroTagMath.downIcon(relation: string): string
	return if relation == "enemy" or relation == "neutral" then "💀" else "🩹"
end

-- "🤖 Name" / "Name", plus " · Lv N" when a level is known.
function HeroTagMath.label(name: string, level: number?): string
	if finite(level) and (level :: number) >= 1 then
		return string.format("%s · Lv %d", name, math.floor(level :: number))
	end
	return name
end

return HeroTagMath
