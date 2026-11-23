--!strict
-- PreviewRecipe (iteration 6, team Preview): what the cosmetic showroom
-- (UI/CosmeticPreview) draws for one item, and which icon it uses. Pure: it
-- takes the Shared config modules as arguments, so Lune specs run it as-is.
--
-- An item is a REF string "<kind>:<id>":
--   cosmetic:<id>   Config/Cosmetics trail / hat / tint (resolved with Data/Looks,
--                   exactly as the server's CosmeticsService draws it)
--   skin:<id>       Config/ClassSkins skin (the hero is that skin's class)
--   class:<id>      a class's default look (the "Classic" skin row)
--   look:<name>     Ascension look "base" | "bull" | "matriarch" | "ancient"
--   title:<id>      Config/Cosmetics TITLES or EARNED_TITLES (nameplate title)
--   dye:<id>        Config/Cosmetics DYES (nameplate name colour)
--   chattag:<id>    Config/Cosmetics CHAT_TAGS (chat tag)
--   frame:<key>     Prestige nameplate frame "p<prestige>" (Config/Ascension FRAMES)
--                   or "wheel" (the Wheel of Legends frame)
-- A bare cosmetic or skin id is accepted too.
--
--   PreviewRecipe.resolve(ref, cfg) -> Recipe?     cfg = { Cosmetics, ClassSkins, Looks, Ascension? }
--   PreviewRecipe.outfit(base, recipe?) -> Outfit   the hero with the item tried on
--   PreviewRecipe.allRefs(cfg) -> { string }        every previewable item
--   PreviewRecipe.iconName(ref) -> string           "icon_cos_<slug>" (atlas entry name)
--   PreviewRecipe.motion(fx) -> Motion              Effects setting -> turntable / idle / sweep
--   PreviewRecipe.panelLayout(w, h) -> Layout       side panel or overlay sheet

local PreviewRecipe = {}

export type Rgb = { number }
export type HatLook = { id: string, shape: string, color: Rgb, accent: Rgb }
export type TrailLook = { id: string, color: Rgb, color2: Rgb }
export type TintLook = { id: string, color: Rgb }
export type Badge = { text: string, color: Rgb }

export type Recipe = {
	ref: string,
	kind: string, -- "cosmetic" | "skin" | "look" | "title" | "dye" | "chattag" | "frame"
	id: string,
	name: string,
	slot: string, -- "hat" | "trail" | "tint" | "skin" | "look" | "title" | "dye" | "chattag" | "frame"
	classId: string?, -- skins: the hero is drawn as this class
	skinId: string?,
	ascLook: string?, -- "bull" | "matriarch" | "ancient" (nil = base)
	hat: HatLook?,
	trail: TrailLook?,
	tint: TintLook?,
	title: Badge?,
	nameColor: Rgb?,
	chatTag: Badge?,
	frame: { key: string, prestige: number, wheel: boolean }?,
	swatch: Rgb?, -- a representative colour (cards, drawn icons)
	swatch2: Rgb?,
	focus: string, -- camera framing: "body" | "head" | "feet" | "name"
	icon: string, -- PreviewRecipe.iconName(ref)
}

export type Outfit = {
	classId: string,
	skinId: string?,
	ascLook: string?,
	hat: HatLook?,
	trail: TrailLook?,
	tint: TintLook?,
	title: Badge?,
	nameColor: Rgb?,
	chatTag: Badge?,
	frame: { key: string, prestige: number, wheel: boolean }?,
	focus: string,
	tried: string?, -- the ref being tried on
}

export type Cfg = { Cosmetics: any, ClassSkins: any, Looks: any, Ascension: any? }

PreviewRecipe.LOOKS = { "base", "bull", "matriarch", "ancient" }
PreviewRecipe.LOOK_NAMES =
	{ base = "Base", bull = "Bull", matriarch = "Matriarch", ancient = "Ancient" } :: { [string]: string }
PreviewRecipe.ICON_PREFIX = "icon_cos_"
-- Kinds whose icon is a rendered 3-D thumbnail in the atlas (scripts/make-cosmetic-icons.py);
-- the text kinds (titles, dyes, chat tags, frames) are drawn in code (UI/CosmeticIcon).
PreviewRecipe.RENDERED = { cosmetic = true, skin = true, look = true } :: { [string]: boolean }

local DEFAULT_FRAMES = { 1, 5, 10, 20, 40, 70, 99 }

local function slug(s: string): string
	local out = string.gsub(string.lower(s), "[^%w]+", "_")
	out = string.gsub(out, "^_+", "")
	out = string.gsub(out, "_+$", "")
	return out
end

-- Splits a ref into (kind, id). Bare ids are guessed from the config.
function PreviewRecipe.split(ref: any, cfg: Cfg?): (string?, string?)
	if type(ref) ~= "string" or ref == "" then
		return nil, nil
	end
	local kind, id = string.match(ref, "^(%a+):(.+)$")
	if kind and id then
		return kind, id
	end
	if cfg then
		local C, S = cfg.Cosmetics, cfg.ClassSkins
		if type(C) == "table" and type(C.byId) == "table" and C.byId[ref] then
			return "cosmetic", ref
		end
		if type(S) == "table" and type(S.byId) == "table" and S.byId[ref] then
			return "skin", ref
		end
	end
	return nil, nil
end

function PreviewRecipe.iconName(ref: string): string
	local kind, id = PreviewRecipe.split(ref)
	if not kind or not id then
		return PreviewRecipe.ICON_PREFIX .. slug(ref)
	end
	if kind == "cosmetic" or kind == "skin" then
		return PreviewRecipe.ICON_PREFIX .. slug(id)
	elseif kind == "chattag" then
		return PreviewRecipe.ICON_PREFIX .. "chat_" .. slug(id)
	elseif kind == "title" and string.sub(id, 1, 6) == "title_" then
		return PreviewRecipe.ICON_PREFIX .. slug(id)
	end
	return PreviewRecipe.ICON_PREFIX .. kind .. "_" .. slug(id)
end

local function badge(b: any): Badge?
	if type(b) ~= "table" or type(b.text) ~= "string" or type(b.color) ~= "table" then
		return nil
	end
	return { text = b.text, color = b.color }
end

local function frameKeys(cfg: Cfg): { number }
	local A = cfg.Ascension
	if type(A) == "table" and type(A.FRAMES) == "table" and #A.FRAMES > 0 then
		return A.FRAMES
	end
	return DEFAULT_FRAMES
end

function PreviewRecipe.resolve(ref: any, cfg: Cfg): Recipe?
	local kind, id = PreviewRecipe.split(ref, cfg)
	if not kind or not id then
		return nil
	end
	local full = kind .. ":" .. id
	local C, S, L = cfg.Cosmetics, cfg.ClassSkins, cfg.Looks
	local r: Recipe = {
		ref = full,
		kind = kind,
		id = id,
		name = id,
		slot = kind,
		focus = "body",
		icon = PreviewRecipe.iconName(full),
	}
	if kind == "cosmetic" then
		local def = type(C) == "table" and type(C.get) == "function" and C.get(id) or nil
		if type(def) ~= "table" or type(L) ~= "table" or type(L.resolve) ~= "function" then
			return nil
		end
		r.name = tostring(def.name or id)
		r.slot = tostring(def.slot)
		-- the server's own resolver (Data/Looks): same colours and fallbacks as in game
		local look = L.resolve({ [r.slot] = id }, { [id] = true }, nil)
		if r.slot == "hat" and look.hat then
			r.hat = look.hat
			r.swatch, r.swatch2 = look.hat.color, look.hat.accent
			r.focus = "head"
		elseif r.slot == "trail" and look.trail then
			r.trail = look.trail
			r.swatch, r.swatch2 = look.trail.color, look.trail.color2
			r.focus = "feet"
		elseif r.slot == "tint" and look.tint then
			r.tint = look.tint
			r.swatch = look.tint.color
		else
			return nil -- not drawable (DataConfig.spec keeps this from happening)
		end
		return r
	elseif kind == "skin" then
		local def = type(S) == "table" and type(S.get) == "function" and S.get(id) or nil
		if type(def) ~= "table" or type(def.classId) ~= "string" then
			return nil
		end
		r.name = tostring(def.name or id)
		r.slot = "skin"
		r.classId = def.classId
		r.skinId = id
		local colors = if type(def.colors) == "table" then def.colors else {}
		r.swatch, r.swatch2 = colors.body, colors.accent
		return r
	elseif kind == "class" then
		-- a class's default look ("Classic" in the Skins list): no skin
		r.name = "Classic"
		r.slot = "skin"
		r.classId = id
		r.skinId = nil
		r.swatch = { 158, 160, 172 }
		return r
	elseif kind == "look" then
		if not PreviewRecipe.LOOK_NAMES[id] then
			return nil
		end
		r.name = PreviewRecipe.LOOK_NAMES[id]
		r.ascLook = if id == "base" then nil else id
		r.swatch = ({
			base = { 158, 160, 172 },
			bull = { 255, 170, 60 },
			matriarch = { 255, 120, 200 },
			ancient = { 110, 220, 255 },
		})[id]
		return r
	elseif kind == "title" then
		local b = type(C) == "table"
			and (
				(type(C.TITLES) == "table" and C.TITLES[id])
				or (type(C.EARNED_TITLES) == "table" and C.EARNED_TITLES[id])
			)
		local t = badge(b)
		if not t then
			return nil
		end
		r.name = "Title: " .. t.text
		r.title = t
		r.swatch = t.color
		r.focus = "name"
		return r
	elseif kind == "dye" then
		local d = type(C) == "table" and type(C.DYES) == "table" and C.DYES[id] or nil
		if type(d) ~= "table" or type(d.color) ~= "table" then
			return nil
		end
		r.name = "Name dye: " .. tostring(d.name or id)
		r.nameColor = d.color
		r.swatch = d.color
		r.focus = "name"
		return r
	elseif kind == "chattag" then
		local t = badge(type(C) == "table" and type(C.CHAT_TAGS) == "table" and C.CHAT_TAGS[id] or nil)
		if not t then
			return nil
		end
		r.name = "Chat tag: " .. t.text
		r.chatTag = t
		r.swatch = t.color
		r.focus = "name"
		return r
	elseif kind == "frame" then
		if id == "wheel" then
			r.name = "Wheel of Legends frame"
			r.frame = { key = "wheel", prestige = 0, wheel = true }
		else
			local n = tonumber(string.match(id, "^p(%d+)$"))
			if not n or not table.find(frameKeys(cfg), n) then
				return nil
			end
			r.name = string.format("Prestige ⭐%d frame", n)
			r.frame = { key = id, prestige = n, wheel = false }
		end
		r.swatch = { 255, 201, 60 }
		r.focus = "name"
		return r
	end
	return nil
end

-- The hero with `recipe` tried on over the `base` outfit (what the player wears now).
-- A skin's class wins over the base class; every other item keeps the base class.
function PreviewRecipe.outfit(base: Outfit, recipe: Recipe?): Outfit
	local o: Outfit = {
		classId = base.classId,
		skinId = base.skinId,
		ascLook = base.ascLook,
		hat = base.hat,
		trail = base.trail,
		tint = base.tint,
		title = base.title,
		nameColor = base.nameColor,
		chatTag = base.chatTag,
		frame = base.frame,
		focus = "body",
		tried = nil,
	}
	if not recipe then
		return o
	end
	o.tried = recipe.ref
	o.focus = recipe.focus
	local s = recipe.slot
	if s == "skin" then
		if recipe.classId and recipe.classId ~= base.classId then
			o.ascLook = nil -- the Ascension look belongs to the base class
		end
		o.classId = recipe.classId or base.classId
		o.skinId = recipe.skinId -- nil for "class:<id>" (the default look)
	elseif s == "look" then
		o.ascLook = recipe.ascLook
	elseif s == "hat" then
		o.hat = recipe.hat
	elseif s == "trail" then
		o.trail = recipe.trail
	elseif s == "tint" then
		o.tint = recipe.tint
	elseif s == "title" then
		o.title = recipe.title
	elseif s == "dye" then
		o.nameColor = recipe.nameColor
	elseif s == "chattag" then
		o.chatTag = recipe.chatTag
	elseif s == "frame" then
		o.frame = recipe.frame
	end
	return o
end

-- Every previewable item, in a stable order (the icon atlas and the spec walk this).
function PreviewRecipe.allRefs(cfg: Cfg): { string }
	local out: { string } = {}
	local C, S = cfg.Cosmetics, cfg.ClassSkins
	if type(C) == "table" and type(C.LIST) == "table" then
		for _, def in C.LIST do
			table.insert(out, "cosmetic:" .. tostring(def.id))
		end
	end
	if type(S) == "table" and type(S.LIST) == "table" then
		for _, def in S.LIST do
			table.insert(out, "skin:" .. tostring(def.id))
		end
	end
	for _, lk in PreviewRecipe.LOOKS do
		table.insert(out, "look:" .. lk)
	end
	local function keys(map: any, prefix: string)
		if type(map) ~= "table" then
			return
		end
		local ks = {}
		for k in map do
			table.insert(ks, tostring(k))
		end
		table.sort(ks)
		for _, k in ks do
			table.insert(out, prefix .. k)
		end
	end
	if type(C) == "table" then
		keys(C.TITLES, "title:")
		keys(C.EARNED_TITLES, "title:")
		if type(C.DYE_ORDER) == "table" then
			for _, k in C.DYE_ORDER do
				table.insert(out, "dye:" .. tostring(k))
			end
		else
			keys(C.DYES, "dye:")
		end
		keys(C.CHAT_TAGS, "chattag:")
	end
	for _, n in frameKeys(cfg) do
		table.insert(out, "frame:p" .. tostring(n))
	end
	table.insert(out, "frame:wheel")
	return out
end

export type Motion = { rotate: boolean, animate: boolean, sweep: boolean, spin: number }

-- Effects setting (Util/GfxSettings fx) -> what moves. "off" = a still hero: no
-- turntable, no idle, no trail sweep (the trail is drawn as a still ribbon).
-- Dragging always rotates (it is the player's own input).
function PreviewRecipe.motion(fx: any): Motion
	if fx == "off" then
		return { rotate = false, animate = false, sweep = false, spin = 0 }
	elseif fx == "reduced" then
		return { rotate = true, animate = true, sweep = true, spin = 0.25 }
	end
	return { rotate = true, animate = true, sweep = true, spin = 0.45 }
end

export type Layout = { mode: string, panelW: number, contentW: number }

-- Where the preview sits in a modal `w` x `h` design px wide: a side panel when the
-- list keeps at least MIN_LIST px, else an overlay sheet over the list (tap an item,
-- the sheet opens; "✕" folds it).
PreviewRecipe.PANEL_W = 300
PreviewRecipe.MIN_LIST = 460
PreviewRecipe.MIN_H = 300
function PreviewRecipe.panelLayout(w: number, h: number): Layout
	local panel = math.clamp(math.floor(w * 0.34), 240, PreviewRecipe.PANEL_W)
	if w - panel - 12 >= PreviewRecipe.MIN_LIST and h >= PreviewRecipe.MIN_H then
		return { mode = "side", panelW = panel, contentW = w - panel - 12 }
	end
	return { mode = "overlay", panelW = w, contentW = w }
end

return PreviewRecipe
