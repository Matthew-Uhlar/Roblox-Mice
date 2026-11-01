--!strict
-- Pure UI layout maths (no Roblox APIs), so it can be unit-tested under Lune.
--
-- Every ScreenGui has a design-space root (DESIGN_W x DESIGN_H design px)
-- scaled by one UIScale. Two separate rules keep phones usable:
--
--   1. fitScale: the UI scale falls all the way to the fitted value, so the
--      whole design area always fits the safe viewport (no 0.7 floor that
--      pushed panels off small phones; QC2 M8).
--   2. touchSize: touch targets are sized in design px so that they are at
--      least MIN_TOUCH_PX screen px at the current scale, independently of
--      rule 1 (STYLE.md: minimum touch target 48 px).
--
-- Screen px here are Roblox GUI px (points on iOS, dp on Android).

local Layout = {}

Layout.DESIGN_W = 1100
Layout.DESIGN_H = 620
Layout.MIN_SCALE = 0.3 -- sanity floor for absurdly small windows only
Layout.MAX_SCALE = 1.5
Layout.BASE_TOUCH = 70 -- design px; the touch target size on large screens
Layout.MIN_TOUCH_PX = 48 -- screen px, touch devices
Layout.MIN_CLICK_PX = 36 -- screen px, mouse / gamepad
Layout.MAX_TOUCH = 140 -- design px; never let a button eat the screen

-- UI scale for a safe viewport of w x h screen px.
function Layout.fitScale(w: number, h: number): number
	if w <= 0 or h <= 0 then
		return 1
	end
	local s = math.min(w / Layout.DESIGN_W, h / Layout.DESIGN_H)
	return math.clamp(s, Layout.MIN_SCALE, Layout.MAX_SCALE)
end

-- Size of the design-space root (design px) for a w x h safe viewport.
function Layout.rootSize(w: number, h: number, scale: number): (number, number)
	return w / scale, h / scale
end

-- Touch-target size in design px at `scale`: at least BASE_TOUCH and at least
-- MIN_TOUCH_PX (touch) / MIN_CLICK_PX (mouse) on screen.
function Layout.touchSize(scale: number, touch: boolean): number
	local minPx = if touch then Layout.MIN_TOUCH_PX else Layout.MIN_CLICK_PX
	local need = math.ceil(minPx / math.max(scale, 0.05))
	return math.min(math.max(Layout.BASE_TOUCH, need), Layout.MAX_TOUCH)
end

-- Clamp a wanted panel extent to what is available, keeping a margin.
function Layout.cap(want: number, available: number, margin: number?): number
	return math.max(0, math.min(want, available - 2 * (margin or 0)))
end

-- Safe viewport from the raw camera viewport and the core-GUI inset
-- (GuiService:GetGuiInset(): top-left and bottom-right).
function Layout.safeViewport(
	viewW: number,
	viewH: number,
	insetLeft: number,
	insetTop: number,
	insetRight: number,
	insetBottom: number
): (number, number)
	return math.max(1, viewW - insetLeft - insetRight), math.max(1, viewH - insetTop - insetBottom)
end

-- Everything a screen needs from one viewport size.
export type Metrics = {
	scale: number,
	rootW: number,
	rootH: number,
	touch: number, -- design px
	touchPx: number, -- resulting screen px
}

function Layout.metrics(w: number, h: number, touch: boolean): Metrics
	local s = Layout.fitScale(w, h)
	local rw, rh = Layout.rootSize(w, h, s)
	local t = Layout.touchSize(s, touch)
	return { scale = s, rootW = rw, rootH = rh, touch = t, touchPx = t * s }
end

return Layout
