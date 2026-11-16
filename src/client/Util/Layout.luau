--!strict
-- Pure UI layout maths (no Roblox APIs), so it can be unit-tested under Lune.
--
-- Every ScreenGui has a design-space root scaled by one UIScale. Three rules:
--
--   1. fitScale: large screens fit a DESIGN_W x DESIGN_H (1600 x 900) design
--      area, capped at MAX_SCALE 1.0, so a 1920x1080 PC renders the UI at 1:1
--      (v3 owner feedback "all of the UI needs to be smaller": the old
--      1100 x 620 area at up to 1.5x made everything huge). Small screens
--      (phones) instead fit the COMPACT_W x COMPACT_H (1100 x 620) area up to
--      COMPACT_MAX_SCALE, which keeps the phone scale exactly as before: on a
--      phone the text floor (rule 3) already binds, so a smaller scale would
--      only make floored text overflow its boxes. The root is never smaller
--      than the compact area, so every screen authored for 1100 x 620 fits.
--   2. touchSize: touch targets are sized in design px so that they are at
--      least MIN_TOUCH_PX screen px at the current scale, independently of
--      rule 1 (STYLE.md: minimum touch target 48 px). Mouse targets keep
--      MIN_CLICK_PX; slimSize is the small control for slim bars.
--   3. textSize: text never renders under MIN_TEXT_PX (touch) / 11 px (mouse).
--
-- `dense` screens (scale >= DENSE_SCALE: PCs, laptops) use the compact v3
-- panel sizes from Util/UiSizes; phones keep their roomier text-floored ones.
--
-- Screen px here are Roblox GUI px (points on iOS, dp on Android).

local Layout = {}

Layout.DESIGN_W = 1600
Layout.DESIGN_H = 900
Layout.COMPACT_W = 1100 -- minimum design area (phones fit this one)
Layout.COMPACT_H = 620
Layout.COMPACT_MAX_SCALE = 0.6 -- the compact fit only applies up to this scale
Layout.MIN_SCALE = 0.3 -- sanity floor for absurdly small windows only
Layout.MAX_SCALE = 1.0
Layout.DENSE_SCALE = 0.75 -- at or above this scale, panels use their dense sizes
Layout.BASE_TOUCH = 52 -- design px; the touch target size on large screens
Layout.MIN_TOUCH_PX = 48 -- screen px, touch devices
Layout.MIN_CLICK_PX = 36 -- screen px, mouse / gamepad
Layout.MAX_TOUCH = 140 -- design px; never let a button eat the screen

-- UI scale for a safe viewport of w x h screen px.
function Layout.fitScale(w: number, h: number): number
	if w <= 0 or h <= 0 then
		return 1
	end
	local big = math.min(w / Layout.DESIGN_W, h / Layout.DESIGN_H)
	local small = math.min(w / Layout.COMPACT_W, h / Layout.COMPACT_H, Layout.COMPACT_MAX_SCALE)
	return math.clamp(math.max(big, small), Layout.MIN_SCALE, Layout.MAX_SCALE)
end

-- True on roomy screens (PC, laptop): panels use their compact v3 sizes.
function Layout.dense(scale: number): boolean
	return scale >= Layout.DENSE_SCALE - 1e-9
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

-- Small control for slim bars (minimised panels): a full touch target on
-- touch devices, otherwise just MIN_CLICK_PX on screen.
function Layout.slimSize(scale: number, touch: boolean): number
	if touch then
		return Layout.touchSize(scale, true)
	end
	return math.min(math.ceil(Layout.MIN_CLICK_PX / math.max(scale, 0.05)), Layout.MAX_TOUCH)
end

-- Readable text: a design TextSize is raised so it renders at least
-- MIN_TEXT_PX (touch) / MIN_TEXT_PX_MOUSE screen px at `scale`, growing at most
-- MAX_TEXT_GROWTH x so fixed-size labels don't explode. (Final QC B, FB-M1.)
Layout.MIN_TEXT_PX = 12
Layout.MIN_TEXT_PX_MOUSE = 11
Layout.MAX_TEXT_GROWTH = 2.2
function Layout.textSize(designSize: number, scale: number, touch: boolean): number
	local minPx = if touch then Layout.MIN_TEXT_PX else Layout.MIN_TEXT_PX_MOUSE
	local need = math.ceil(minPx / math.max(scale, 0.05))
	return math.min(math.max(designSize, need), math.ceil(designSize * Layout.MAX_TEXT_GROWTH))
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
	dense: boolean,
}

function Layout.metrics(w: number, h: number, touch: boolean): Metrics
	local s = Layout.fitScale(w, h)
	local rw, rh = Layout.rootSize(w, h, s)
	local t = Layout.touchSize(s, touch)
	return { scale = s, rootW = rw, rootH = rh, touch = t, touchPx = t * s, dense = Layout.dense(s) }
end

return Layout
