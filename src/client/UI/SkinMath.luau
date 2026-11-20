--!strict
-- Pure helpers of the UI skin (UI/Skin): no game access, so the Lune specs can
-- test them (tests/specs/ClientSkin.spec.luau).
--
--   SkinMath.buttonTexture(r, g, b, text, kind) -> base texture name
--   SkinMath.sliceScale(slice, w, h, dense, mul?) -> SliceScale
--   SkinMath.frameRect(slice, s) -> (left, top, extraW, extraH) design px
--   SkinMath.splitIcon(text) -> (iconTexture?, rest)
--   SkinMath.ICON_KINDS[kind] -> icon texture for a UI/Icons kind
--   SkinMath.rarityTexture(rarity) -> (card texture, tint?)

local SkinMath = {}

export type Slice = {
	size: { number },
	center: { number },
	pad: { number },
	scale: number,
	inset: { number }?,
}

-- Theme.C colours (0..255) that map to a coloured button texture. Anything
-- else uses the neutral "tint" button with ImageColor3 = the colour.
local BUTTON_COLORS: { { rgb: { number }, name: string } } = {
	{ rgb = { 255, 204, 51 }, name = "ui_btn_primary" }, -- cheese
	{ rgb = { 232, 162, 32 }, name = "ui_btn_primary" }, -- cheeseDark
	{ rgb = { 255, 214, 92 }, name = "ui_btn_primary" }, -- gold
	{ rgb = { 255, 244, 214 }, name = "ui_btn_secondary" }, -- cream
	{ rgb = { 238, 222, 184 }, name = "ui_btn_secondary" }, -- creamDark
	{ rgb = { 255, 255, 255 }, name = "ui_btn_secondary" }, -- white
	{ rgb = { 226, 72, 58 }, name = "ui_btn_danger" }, -- red
	{ rgb = { 96, 190, 92 }, name = "ui_btn_robux" }, -- green
	{ rgb = { 52, 132, 60 }, name = "ui_btn_robux" }, -- greenDark
}

local CLOSE_TEXT = { ["✕"] = true, ["×"] = true, ["X"] = true, ["x"] = true }

local function near(a: { number }, r: number, g: number, b: number): boolean
	return math.abs(a[1] - r) <= 3 and math.abs(a[2] - g) <= 3 and math.abs(a[3] - b) <= 3
end

-- Base texture for a Theme.button (state suffixes "_hover" / "_pressed" are
-- added by the skin). `kind` "tab" picks the tab textures: the active tab is
-- the cheese-coloured one (ShopUI colours the current tab C.cheese).
function SkinMath.buttonTexture(r: number, g: number, b: number, text: string?, kind: string?): string
	if kind == "tab" then
		return if near({ 255, 204, 51 }, r, g, b) then "ui_tab_active" else "ui_tab_inactive"
	end
	if text and CLOSE_TEXT[text] and near({ 226, 72, 58 }, r, g, b) then
		return "ui_close"
	end
	for _, e in BUTTON_COLORS do
		if near(e.rgb, r, g, b) then
			return e.name
		end
	end
	return "ui_btn_tint"
end

-- Textures that have hover / pressed variants.
SkinMath.HAS_STATES = {
	ui_btn_primary = true,
	ui_btn_secondary = true,
	ui_btn_danger = true,
	ui_btn_robux = true,
	ui_btn_tint = true,
	ui_close = true,
	-- set 2 (ui2_) squircles; Skin.resolve maps ui_btn_*_sq -> ui2_btn_*_sq
	ui_btn_primary_sq = true,
	ui_btn_secondary_sq = true,
	ui_btn_danger_sq = true,
	ui_btn_robux_sq = true,
	ui_btn_tint_sq = true,
} :: { [string]: boolean }

function SkinMath.stateTexture(base: string, state: string?): string
	if state and state ~= "normal" and SkinMath.HAS_STATES[base] then
		return base .. "_" .. state
	end
	return base
end

-- SliceScale for a w x h (design px) object: the texture's preferred scale
-- (a little smaller on roomy PC screens, where panels are compact), capped so
-- the visible borders never take more than ~90% of the object.
function SkinMath.sliceScale(slice: Slice, w: number, h: number, dense: boolean, mul: number?): number
	local s = slice.scale * (if dense then 0.85 else 1) * (mul or 1)
	local size, c, p = slice.size, slice.center, slice.pad
	local bx = (c[1] - p[1]) + (size[1] - c[3] - p[3])
	local by = (c[2] - p[2]) + (size[2] - c[4] - p[4])
	if w > 0 and bx > 0 then
		s = math.min(s, w * 0.9 / bx)
	end
	if h > 0 and by > 0 then
		s = math.min(s, h * 0.9 / by)
	end
	return math.max(s, 0.02)
end

-- The image is drawn bigger than its object by the texture's transparent pad
-- (drop shadow / glow), so the visible frame lines up with the object's edge.
function SkinMath.frameRect(slice: Slice, s: number): (number, number, number, number)
	local p = slice.pad
	return -p[1] * s, -p[2] * s, (p[1] + p[3]) * s, (p[2] + p[4]) * s
end

-- Leading emoji / symbol -> icon texture (the emoji stays as the fallback).
SkinMath.EMOJI = {
	{ "🧀", "ui_icon_cheese" },
	{ "✨", "ui_icon_golden_cheese" },
	{ "R$", "ui_icon_coin" },
	{ "⚡", "ui_icon_boost" },
	{ "🎟️", "ui_icon_pass" },
	{ "🎟", "ui_icon_pass" },
	{ "⭐", "ui_icon_star" },
	{ "★", "ui_icon_star" },
	{ "🔒", "ui_icon_lock" },
	{ "✔", "ui_icon_check" },
	{ "✅", "ui_icon_check" },
	{ "🎁", "ui_icon_gift" },
	{ "🏆", "ui_icon_trophy" },
	{ "📜", "ui_icon_scroll" },
	{ "📖", "ui_icon_book" },
	{ "📘", "ui_icon_book" },
	{ "🐘", "ui_icon_elephant" },
	{ "🐭", "ui_icon_mouse" },
} :: { { string } }

-- "🧀 120" -> ("ui_icon_cheese", "120"). Only a leading token followed by a
-- space (or the whole text) counts; RichText / multi-line texts keep the emoji.
function SkinMath.splitIcon(text: string): (string?, string)
	if string.find(text, "\n", 1, true) or string.find(text, "<", 1, true) then
		return nil, text
	end
	for _, e in SkinMath.EMOJI do
		local tok = e[1]
		if string.sub(text, 1, #tok) == tok then
			local rest = string.sub(text, #tok + 1)
			if rest == "" then
				return e[2], ""
			elseif string.sub(rest, 1, 1) == " " then
				return e[2], (string.gsub(rest, "^%s+", ""))
			end
		end
	end
	return nil, text
end

-- UI/Icons kinds that have a texture.
SkinMath.ICON_KINDS = {
	cheese = "ui_icon_cheese",
	star = "ui_icon_star",
	lock = "ui_icon_lock",
	check = "ui_icon_check",
	coin = "ui_icon_coin",
	bolt = "ui_icon_boost",
	hero = "ui_icon_elephant",
} :: { [string]: string }

-- Card frame per rarity; Uncommon reuses the common frame tinted green.
function SkinMath.rarityTexture(rarity: any): (string, { number }?)
	local r = string.lower(tostring(rarity or "common"))
	if r == "rare" or r == "epic" or r == "legendary" then
		return "ui_card_" .. r, nil
	elseif r == "uncommon" then
		return "ui_card_common", { 150, 230, 140 }
	end
	return "ui_card_common", nil
end

-- Light text gets a dark outline, dark text a soft light one (readability on
-- textures).
function SkinMath.isLight(r: number, g: number, b: number): boolean
	return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6
end

return SkinMath
