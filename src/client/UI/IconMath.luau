--!strict
-- Pure maths of the animated icons (UI/AnimatedIcon): which sprite frame to
-- show, the idle motion, hover / press reactions, atlas rects and the text a
-- decorated button keeps. No Roblox APIs: tests/specs/ClientIcons.spec.luau
-- runs it under Lune.
--
--   IconMath.rect(entry, i, cell) -> (x, y)          frame i (0-based) in its atlas
--   IconMath.frame(entry, t, fx, phase) -> number    0-based frame at time t
--   IconMath.motion(entry, t, fx, phase) -> (dy, scale, rot)
--                                                    dy as a fraction of the icon size
--   IconMath.react(state, fx) -> (scale, glowAlpha)  "normal" | "hover" | "pressed"
--   IconMath.stripLead(text) -> string               text without a leading emoji
--   IconMath.atlasId(entry, ids) -> number?          the uploaded atlas id, if any
--
-- Effects setting (State "gfx".fx): "full" animates everything; "reduced" runs
-- the sprite frames at half speed with longer holds and no idle motion; "off"
-- shows the static first frame and no motion or glow (hover / press still
-- give a small scale nudge so the button feels alive).

local IconMath = {}

export type Entry = {
	atlas: string,
	x: number,
	y: number,
	frames: number,
	anim: string,
	motion: string,
	fps: number,
	hold: number,
	glow: { number },
}

IconMath.BOB = 0.05 -- bob amplitude (fraction of the icon size)
IconMath.BOB_PERIOD = 1.8
IconMath.PULSE = 0.045 -- pulse amplitude (scale)
IconMath.PULSE_PERIOD = 1.6
IconMath.TILT = 7 -- tilt amplitude (degrees)
IconMath.TILT_PERIOD = 2.6
IconMath.HOVER_SCALE = 1.14
IconMath.PRESS_SCALE = 0.9

function IconMath.rect(entry: Entry, i: number, cell: number): (number, number)
	local n = math.max(1, entry.frames)
	local k = math.clamp(math.floor(i), 0, n - 1)
	return entry.x + k * cell, entry.y
end

local function finite(v: number): boolean
	return v == v and v ~= math.huge and v ~= -math.huge
end

function IconMath.frame(entry: Entry, t: number, fx: string, phase: number?): number
	local n = entry.frames
	if fx == "off" or n <= 1 or entry.fps <= 0 or not finite(t) then
		return 0
	end
	local fps = if fx == "reduced" then entry.fps * 0.5 else entry.fps
	local u = t + (phase or 0)
	if entry.anim == "shine" then
		-- one sweep over frames 1..n-1, then hold the clean frame 0
		local sweep = (n - 1) / fps
		local hold = entry.hold * (if fx == "reduced" then 2 else 1)
		local cycle = sweep + hold
		local p = u % cycle
		if p < sweep then
			return math.clamp(1 + math.floor(p * fps), 1, n - 1)
		end
		return 0
	end
	return math.floor(u * fps) % n
end

function IconMath.motion(entry: Entry, t: number, fx: string, phase: number?): (number, number, number)
	if fx ~= "full" or not finite(t) then
		return 0, 1, 0
	end
	local u = t + (phase or 0)
	local m = entry.motion
	if m == "bob" then
		return -IconMath.BOB * (0.5 + 0.5 * math.sin(u * 2 * math.pi / IconMath.BOB_PERIOD)), 1, 0
	elseif m == "pulse" then
		return 0, 1 + IconMath.PULSE * math.sin(u * 2 * math.pi / IconMath.PULSE_PERIOD), 0
	elseif m == "tilt" then
		return 0, 1, IconMath.TILT * math.sin(u * 2 * math.pi / IconMath.TILT_PERIOD)
	end
	return 0, 1, 0
end

function IconMath.react(state: string, fx: string): (number, number)
	local glowOn = fx ~= "off"
	if state == "hover" then
		return if fx == "off" then 1.06 else IconMath.HOVER_SCALE, if glowOn then 0.45 else 1
	elseif state == "pressed" then
		return IconMath.PRESS_SCALE, if glowOn then 0.25 else 1
	end
	return 1, 1
end

-- A leading emoji / symbol token (any non-ASCII run, then spaces) is dropped:
-- the icon replaces it. "🛒 Shop" -> "Shop", "⚙" -> "", "Ranks" -> "Ranks".
function IconMath.stripLead(text: string): string
	if text == "" or string.byte(text, 1) < 0x80 then
		return text
	end
	local i = 1
	local n = #text
	while i <= n and string.byte(text, i) >= 0x80 do
		i += 1
	end
	-- a variation selector or keycap glued to the emoji is non-ASCII too;
	-- an ASCII letter glued to it ("✨x") keeps the text as it is
	if i <= n and string.sub(text, i, i) ~= " " then
		return text
	end
	return (string.gsub(string.sub(text, i), "^%s+", ""))
end

function IconMath.atlasId(entry: Entry?, ids: { [string]: any }): number?
	if not entry then
		return nil
	end
	local v = ids[entry.atlas]
	if type(v) == "number" and v > 0 then
		return v
	end
	return nil
end

-- A stable per-key phase (0..3 s) so icons do not all bob in step.
function IconMath.phase(key: string): number
	local h = 0
	for i = 1, #key do
		h = (h * 31 + string.byte(key, i)) % 1000
	end
	return h / 1000 * 3
end

return IconMath
