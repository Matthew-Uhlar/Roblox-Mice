--!strict
-- Pure camera maths for the rotatable top-down camera (iteration 5 A2). No
-- Roblox APIs: unit-tested under Lune (tests/specs/ClientIter5.spec.luau).
--
-- Yaw convention (radians): yaw 0 = north-up, the old fixed camera: the camera
-- sits on the +Z side of the focus and looks toward -Z, so screen right =
-- world +X and screen down = world +Z. A positive yaw turns the view LEFT
-- (Roblox's CFrame.Angles(0, yaw, 0) convention), so dragging the mouse right
-- lowers the yaw (the view turns right), like the default Roblox camera.
--
-- Screen vectors are (dx right, dy down) in px or any unit; world vectors are
-- (wx, wz) on the ground plane.

local CameraMath = {}

local TAU = 2 * math.pi

CameraMath.STEP = math.rad(45) -- `,` / `.` rotate in 45° steps
CameraMath.MOUSE_SENS = math.rad(0.4) -- radians per px of right-mouse drag
CameraMath.TOUCH_SENS = math.rad(0.35) -- radians per px of a one-finger drag
CameraMath.STICK_SPEED = math.rad(160) -- radians / s at full right-stick X
CameraMath.STICK_DEAD = 0.3
CameraMath.DRAG_PX = 6 -- a right-click that moves less than this is a click, not a drag
CameraMath.CLICK_TIME = 0.35 -- ...and is released within this many seconds
CameraMath.TOUCH_DRAG_PX = 14 -- a touch must move this far before it rotates
CameraMath.RATE = 16 -- yaw smoothing (higher = snappier)

-- Wraps an angle to (-pi, pi].
function CameraMath.wrap(a: number): number
	if a ~= a or a == math.huge or a == -math.huge then
		return 0
	end
	local r = (a + math.pi) % TAU - math.pi
	if r <= -math.pi then
		r += TAU
	end
	return r
end

-- Shortest-path angle interpolation (t in 0..1).
function CameraMath.lerpAngle(a: number, b: number, t: number): number
	return CameraMath.wrap(a + CameraMath.wrap(b - a) * math.clamp(t, 0, 1))
end

-- Frame-rate independent smoothing step toward `target`.
function CameraMath.approach(current: number, target: number, rate: number, dt: number): number
	return CameraMath.lerpAngle(current, target, 1 - math.exp(-rate * math.max(dt, 0)))
end

-- Yaw of a camera from its look vector (any length; the Y part is ignored).
-- A look straight down (no horizontal part) reads as 0.
function CameraMath.yawFromLook(lx: number, lz: number): number
	if lx * lx + lz * lz < 1e-8 then
		return 0
	end
	return math.atan2(-lx, -lz)
end

-- Camera offset from the focus for (yaw, pitch, distance): (x, y, z).
function CameraMath.offset(yaw: number, pitch: number, dist: number): (number, number, number)
	local h = math.cos(pitch) * dist
	return math.sin(yaw) * h, math.sin(pitch) * dist, math.cos(yaw) * h
end

-- Screen vector (dx right, dy down) -> world ground vector (wx, wz).
function CameraMath.screenToWorld(dx: number, dy: number, yaw: number): (number, number)
	local c, s = math.cos(yaw), math.sin(yaw)
	return dx * c + dy * s, -dx * s + dy * c
end

-- World ground vector (wx, wz) -> screen vector (dx right, dy down).
function CameraMath.worldToScreen(wx: number, wz: number, yaw: number): (number, number)
	local c, s = math.cos(yaw), math.sin(yaw)
	return wx * c - wz * s, wx * s + wz * c
end

-- Screen angle (radians, 0 = up, clockwise) of a world direction.
function CameraMath.screenAngle(wx: number, wz: number, yaw: number): number
	local sx, sy = CameraMath.worldToScreen(wx, wz, yaw)
	return math.atan2(sx, -sy)
end

-- Yaw change from a right-mouse / one-finger drag of `dx` px to the right.
function CameraMath.dragYaw(dx: number, sens: number?): number
	return -dx * (sens or CameraMath.MOUSE_SENS)
end

-- Yaw change from the right stick X (-1..1) over `dt` seconds (0 inside the dead zone).
function CameraMath.stickYaw(x: number, dt: number, speed: number?, dead: number?): number
	local dz = dead or CameraMath.STICK_DEAD
	local m = math.abs(x)
	if m <= dz then
		return 0
	end
	local k = (m - dz) / (1 - dz) -- rescale so the edge of the dead zone is 0
	local sign = if x > 0 then 1 else -1
	return -sign * k * k * (speed or CameraMath.STICK_SPEED) * dt
end

-- Next 45° step from `yaw` in direction `dir` (+1 turns the view right,
-- -1 left): snaps to the grid first, so repeated presses land on N/NE/E/....
function CameraMath.stepYaw(yaw: number, dir: number): number
	local step = CameraMath.STEP
	local k = math.floor(yaw / step + 0.5)
	local snapped = k * step
	local off = CameraMath.wrap(yaw - snapped)
	-- already off the grid in the pressed direction: just snap there
	if dir > 0 and off > 1e-3 then
		return CameraMath.wrap(snapped)
	elseif dir < 0 and off < -1e-3 then
		return CameraMath.wrap(snapped)
	end
	return CameraMath.wrap(snapped - (if dir > 0 then step else -step))
end

-- Angle (radians) between two touch points, for two-finger twists.
function CameraMath.twistAngle(ax: number, ay: number, bx: number, by: number): number
	return math.atan2(by - ay, bx - ax)
end

-- Whether a touch at screen x (px) may rotate the camera: never on the left
-- part of the screen, which belongs to the movement thumbstick.
CameraMath.THUMB_FRAC = 0.4
function CameraMath.touchMayRotate(x: number, viewportW: number): boolean
	return x > viewportW * CameraMath.THUMB_FRAC
end

-- Whether a right-click was a click (fire the ability) rather than a drag.
function CameraMath.isClick(movedPx: number, heldSeconds: number): boolean
	return movedPx < CameraMath.DRAG_PX and heldSeconds <= CameraMath.CLICK_TIME
end

return CameraMath
