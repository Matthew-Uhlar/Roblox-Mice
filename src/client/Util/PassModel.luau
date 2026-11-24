--!strict
-- PassModel (iteration 6, team Pass): the pure maths behind UI/PassUI, the
-- season-pass screen of the Herd Pass. No Roblox APIs and no requires: specs
-- run it in Lune (tests/specs/ClientPass.spec.luau) with Util/Progression and
-- Config/Pass passed in.
--
--   PassModel.build(pv, seasonDef?, rewardOf) -> Model   tiers, slots, states
--   PassModel.slotState(...)                            one slot's state
--   PassModel.claimQueue(model, pending?)                 every claimable slot, in order
--   PassModel.focusTier(model)                            the tier the screen centres on
--   PassModel.rewardInfo(reward, track, cosmeticDef?)     card title / icon / rarity
--   PassModel.anim(fx)                                    Effects setting -> what animates
--   PassModel.layout(rootW, rootH, touch, dense)          panel / header / track / cards
--   PassModel.centreOffset / nearestIndex / canvasWidth   scroll snap maths
--   PassModel.ease / approach / bob / pulse / shine / burst  animation curves
--
-- Policy (docs/MONETIZATION.md, HANDOFF §3.3): the premium track is cosmetics
-- and Golden Cheese only; nothing here counts down, says "ends", or nags.
-- PassModel.TEXT holds every fixed string the screen shows, and the spec checks
-- it (and the UI source) against PassModel.FORBIDDEN.

local PassModel = {}

----------------------------------------------------------------------
-- Text
----------------------------------------------------------------------

PassModel.TEXT = {
	free = "FREE",
	premium = "PREMIUM",
	premiumOwned = "PREMIUM ✔",
	unlock = "Unlock Premium",
	claimAll = "Claim all",
	claim = "Claim",
	claimed = "Claimed",
	ready = "Ready to claim!",
	reach = "Reach tier %d",
	needsPremium = "Premium track reward",
	empty = "No reward on this tier",
	loading = "The Herd Pass is loading…",
	maxTier = "Max tier reached!",
	toNext = "%s / %s XP to tier %d",
	tierUp = "TIER %d!",
	season = "SEASON %s",
	premiumPitch = "Premium adds cosmetics and Golden Cheese. Tiers you have reached unlock at once. Free rewards stay free.",
	xpHint = "Earn Pass XP from runs, Herd Contracts and new Mousepedia entries.",
	selectHint = "Pick a reward to see it here",
} :: { [string]: string }

-- Scarcity / countdown / pressure wording the pass screen must never show
-- (lower-case substrings).
PassModel.FORBIDDEN = {
	"ends in",
	"season ends",
	"days left",
	"hours left",
	"time left",
	"left to",
	"countdown",
	"expires",
	"expiring",
	"hurry",
	"last chance",
	"limited time",
	"limited-time",
	"don't miss",
	"dont miss",
	"before it's gone",
	"gone forever",
	"only today",
	"act now",
	"remaining",
	"before the season ends",
	"buy now",
}

-- True when `s` has none of the FORBIDDEN phrases.
function PassModel.safeText(s: string): boolean
	local low = string.lower(s)
	for _, bad in PassModel.FORBIDDEN do
		if string.find(low, bad, 1, true) then
			return false
		end
	end
	return true
end

----------------------------------------------------------------------
-- Model
----------------------------------------------------------------------

-- Slot states:
--   "claimable"     reached, on your track, not claimed yet
--   "claimed"       already claimed
--   "locked"        tier not reached yet
--   "needsPremium"  premium slot of a reached tier, premium not owned
--   "empty"         this tier has no reward on this track
export type Slot = {
	tier: number,
	track: string, -- "free" | "premium"
	reward: any?, -- Progression.Reward
	state: string,
}

export type Column = {
	tier: number,
	reached: boolean,
	current: boolean, -- the tier the player is working towards (or the last one)
	free: Slot,
	premium: Slot,
}

export type Model = {
	known: boolean,
	season: string,
	seasonName: string,
	tier: number, -- tiers reached, 0..maxTier
	maxTier: number,
	xp: number, -- inside the next tier
	xpPerTier: number,
	frac: number, -- 0..1 towards the next tier
	premium: boolean,
	premiumKey: string?, -- nil = premium not sold this season
	columns: { Column },
	claimable: number,
	currentTier: number,
}

local function num(v: any, default: number): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return default
	end
	return n
end

function PassModel.slotState(
	reward: any?,
	reached: boolean,
	claimed: boolean,
	track: string,
	premiumOwned: boolean
): string
	if reward == nil then
		return "empty"
	elseif claimed then
		return "claimed"
	elseif not reached then
		return "locked"
	elseif track == "premium" and not premiumOwned then
		return "needsPremium"
	end
	return "claimable"
end

local function seasonReward(seasonDef: any, track: string, tier: number): any?
	if type(seasonDef) ~= "table" then
		return nil
	end
	local list = seasonDef[track]
	return if type(list) == "table" then list[tier] else nil
end

-- `pv` is Progression.pass(view, cfg); `seasonDef` is Config/Pass.season(n)
-- (fills rewards the view leaves out, and the whole track before the view
-- arrives); `rewardOf` is Progression.reward.
function PassModel.build(pv: any, seasonDef: any?, rewardOf: (any) -> any): Model
	local v = if type(pv) == "table" then pv else {}
	local tiers = if type(v.tiers) == "table" then v.tiers else {}
	local maxTier = math.max(#tiers, 1)
	if #tiers == 0 and type(seasonDef) == "table" then
		local n = 0
		for _, track in { "free", "premium" } do
			local list = seasonDef[track]
			if type(list) == "table" then
				for k in list do
					n = math.max(n, math.floor(num(k, 0)))
				end
			end
		end
		maxTier = math.max(n, 1)
	end
	local xpPerTier = math.max(1, num(v.xpPerTier, 1000))
	local tier = math.clamp(math.floor(num(v.tier, 0)), 0, maxTier)
	local xp = math.clamp(num(v.xp, 0), 0, xpPerTier)
	local premium = v.premium == true
	local m: Model = {
		known = v.known == true,
		season = if v.season ~= nil then tostring(v.season) else "1",
		seasonName = if type(v.seasonName) == "string"
			then v.seasonName
			elseif type(seasonDef) == "table" and type(seasonDef.name) == "string" then seasonDef.name
			else "Herd Pass",
		tier = tier,
		maxTier = maxTier,
		xp = xp,
		xpPerTier = xpPerTier,
		frac = if tier >= maxTier then 1 else math.clamp(xp / xpPerTier, 0, 1),
		premium = premium,
		premiumKey = if type(v.premiumKey) == "string" and v.premiumKey ~= "" then v.premiumKey else nil,
		columns = {},
		claimable = 0,
		currentTier = math.clamp(tier + 1, 1, maxTier),
	}
	for t = 1, maxTier do
		local row = tiers[t]
		local r = if type(row) == "table" then row else {}
		local reached = if type(row) == "table" then r.unlocked == true else t <= tier
		local free = r.free
		if free == nil then
			local raw = seasonReward(seasonDef, "free", t)
			free = if raw ~= nil then rewardOf(raw) else nil
		end
		local prem = r.premium
		if prem == nil then
			local raw = seasonReward(seasonDef, "premium", t)
			prem = if raw ~= nil then rewardOf(raw) else nil
		end
		if type(free) == "table" and free.kind == "none" then
			free = nil
		end
		if type(prem) == "table" and prem.kind == "none" then
			prem = nil
		end
		local col: Column = {
			tier = t,
			reached = reached,
			current = t == m.currentTier,
			free = {
				tier = t,
				track = "free",
				reward = free,
				state = PassModel.slotState(free, reached, r.freeClaimed == true, "free", premium),
			},
			premium = {
				tier = t,
				track = "premium",
				reward = prem,
				state = PassModel.slotState(prem, reached, r.premiumClaimed == true, "premium", premium),
			},
		}
		if col.free.state == "claimable" then
			m.claimable += 1
		end
		if col.premium.state == "claimable" then
			m.claimable += 1
		end
		table.insert(m.columns, col)
	end
	return m
end

-- Every claimable slot, tier by tier (free before premium), skipping the
-- `pending` keys ("<tier>:<track>") already sent.
function PassModel.claimQueue(m: Model, pending: { [string]: any }?): { { tier: number, track: string } }
	local out = {}
	for _, col in m.columns do
		for _, slot in { col.free, col.premium } do
			local key = PassModel.key(slot.tier, slot.track)
			if slot.state == "claimable" and not (pending and pending[key]) then
				table.insert(out, { tier = slot.tier, track = slot.track })
			end
		end
	end
	return out
end

function PassModel.key(tier: number, track: string): string
	return tostring(tier) .. ":" .. track
end

-- The tier the screen opens on: the first one with something to claim, else
-- the tier being worked towards.
function PassModel.focusTier(m: Model): number
	for _, col in m.columns do
		if col.free.state == "claimable" or col.premium.state == "claimable" then
			return col.tier
		end
	end
	return m.currentTier
end

-- Header caption under the XP bar.
function PassModel.xpCaption(m: Model, fmt: ((number) -> string)?): string
	if m.tier >= m.maxTier then
		return PassModel.TEXT.maxTier
	end
	local f = fmt or function(n: number): string
		return tostring(math.floor(n))
	end
	return string.format(PassModel.TEXT.toNext, f(m.xp), f(m.xpPerTier), m.tier + 1)
end

-- Status line for a slot (featured panel).
function PassModel.stateText(slot: Slot): string
	local s = slot.state
	if s == "claimable" then
		return PassModel.TEXT.ready
	elseif s == "claimed" then
		return PassModel.TEXT.claimed
	elseif s == "locked" then
		return string.format(PassModel.TEXT.reach, slot.tier)
	elseif s == "needsPremium" then
		return PassModel.TEXT.needsPremium
	end
	return PassModel.TEXT.empty
end

----------------------------------------------------------------------
-- Reward presentation
----------------------------------------------------------------------

export type RewardInfo = {
	title: string, -- big line ("300", "Snow Cap")
	sub: string, -- small line ("Cheese", "Hat")
	icon: string, -- UI/Icons kind (drawn fallback)
	anim: string, -- IconAtlas name (UI/AnimatedIcon), may be missing there
	emoji: string,
	rarity: string, -- Theme.RARITY key
	ref: string?, -- CosmeticPreview ref ("cosmetic:<id>" / "title:<id>")
	fly: string, -- where a claimed reward flies: "cheese" | "golden" | "locker"
	featured: boolean, -- worth the big preview (cosmetics, titles)
}

local SLOT_NAME: { [string]: string } = { hat = "Hat", trail = "Trail", tint = "Tint" }
local SLOT_ANIM: { [string]: string } = { hat = "hats", trail = "trails", tint = "tints" }

local function shortInt(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return out
end

-- `reward` is a Progression.Reward; `cosmeticDef` the Config/Cosmetics entry
-- of its id (slot, name), when the UI has it.
function PassModel.rewardInfo(reward: any, track: string, cosmeticDef: any?): RewardInfo
	local premium = track == "premium"
	local r = if type(reward) == "table" then reward else {}
	local kind = tostring(r.kind or "none")
	local amount = num(r.amount, 0)
	local extra = ""
	if type(r.text) == "string" then
		-- a second reward on the same tier ("🧀 300  ✨ 5 dust") goes in the sub line
		local _, two = string.find(r.text, "  ", 1, true)
		if two then
			extra = " + " .. string.gsub(string.sub(r.text, two + 1), "^[^%w]*", "")
		end
	end
	if kind == "cheese" then
		return {
			title = shortInt(amount),
			sub = "Cheese" .. extra,
			icon = "cheese",
			anim = "cheese_shop",
			emoji = "🧀",
			rarity = if premium then "Rare" else "Common",
			ref = nil,
			fly = "cheese",
			featured = false,
		}
	elseif kind == "golden" then
		return {
			title = shortInt(amount),
			sub = "Golden Cheese" .. extra,
			icon = "coin",
			anim = if amount >= 100 then "golden_l" else "golden_s",
			emoji = "✨",
			rarity = if premium then "Legendary" else "Uncommon",
			ref = nil,
			fly = "golden",
			featured = false,
		}
	elseif kind == "token" then
		return {
			title = "×" .. shortInt(amount),
			sub = "Reroll tokens" .. extra,
			icon = "star",
			anim = "reroll",
			emoji = "🎟",
			rarity = "Uncommon",
			ref = nil,
			fly = "locker",
			featured = false,
		}
	elseif kind == "dust" then
		return {
			title = shortInt(amount),
			sub = "Crumb Dust" .. extra,
			icon = "gem",
			anim = "gems",
			emoji = "✨",
			rarity = "Uncommon",
			ref = nil,
			fly = "locker",
			featured = false,
		}
	elseif kind == "cosmetic" or kind == "skin" then
		local def = if type(cosmeticDef) == "table" then cosmeticDef else {}
		local slot = tostring(def.slot or "")
		local id = tostring(r.id or "")
		local name = if type(def.name) == "string" then def.name else nil
		if not name and type(r.text) == "string" then
			name = string.gsub(r.text, "^[^%w]*", "")
		end
		return {
			title = name or id,
			sub = (SLOT_NAME[slot] or "Cosmetic") .. extra,
			icon = if slot == "hat" then "crown" elseif slot == "tint" then "gem" else "star",
			anim = SLOT_ANIM[slot] or "cosmetics",
			emoji = "🎩",
			rarity = if premium then "Epic" else "Rare",
			ref = if id ~= "" then (if kind == "skin" then "skin:" else "cosmetic:") .. id else nil,
			fly = "locker",
			featured = true,
		}
	elseif kind == "title" then
		local name = if type(r.text) == "string" then string.gsub(r.text, "^[^%w]*", "") else tostring(r.id)
		name = string.gsub(name, "^Title: ", "")
		return {
			title = name,
			sub = "Title" .. extra,
			icon = "crown",
			anim = "ranks",
			emoji = "🏷",
			rarity = if premium then "Epic" else "Rare",
			ref = if r.id then "title:" .. tostring(r.id) else nil,
			fly = "locker",
			featured = true,
		}
	end
	return {
		title = "—",
		sub = "",
		icon = "gem",
		anim = "herd_pass",
		emoji = "·",
		rarity = "Common",
		ref = nil,
		fly = "locker",
		featured = false,
	}
end

----------------------------------------------------------------------
-- Effects setting -> animation profile
----------------------------------------------------------------------

export type Anim = {
	intro: string, -- "cascade" (cards slide / scale in one by one) | "pop" (the panel only) | "none"
	stagger: number, -- s between cards in the cascade
	bob: boolean, -- claimable cards float
	glowPulse: boolean, -- claimable glow breathes (else a steady glow)
	shine: boolean, -- light sweep over premium cards
	particles: number, -- particles per claim burst
	fly: boolean, -- reward flies to the currency / locker chip
	flash: boolean, -- tier-up flash + banner
	pop: boolean, -- claimed card pops
	smoothBar: boolean, -- XP bar fills smoothly (else jumps)
	smoothScroll: boolean, -- scroll / snap eases (else jumps)
	previewMotion: boolean, -- featured icon idles (bob / spin)
}

-- "full" = everything; "reduced" = minimal (smooth bar and scroll, a small
-- pop, steady glow); "off" = static.
function PassModel.anim(fx: any): Anim
	if fx == "off" then
		return {
			intro = "none",
			stagger = 0,
			bob = false,
			glowPulse = false,
			shine = false,
			particles = 0,
			fly = false,
			flash = false,
			pop = false,
			smoothBar = false,
			smoothScroll = false,
			previewMotion = false,
		}
	elseif fx == "reduced" then
		return {
			intro = "pop",
			stagger = 0,
			bob = false,
			glowPulse = false,
			shine = false,
			particles = 0,
			fly = false,
			flash = false,
			pop = true,
			smoothBar = true,
			smoothScroll = true,
			previewMotion = false,
		}
	end
	return {
		intro = "cascade",
		stagger = 0.035,
		bob = true,
		glowPulse = true,
		shine = true,
		particles = 14,
		fly = true,
		flash = true,
		pop = true,
		smoothBar = true,
		smoothScroll = true,
		previewMotion = true,
	}
end

----------------------------------------------------------------------
-- Layout (design px, Util/Layout root sizes)
----------------------------------------------------------------------

export type Rect = { x: number, y: number, w: number, h: number }

export type PassLayout = {
	panel: Rect, -- inside the root
	pad: number,
	header: Rect, -- inside the panel
	track: Rect, -- inside the panel (row labels + scroller)
	labelW: number, -- sticky FREE / PREMIUM column on the left of the track
	scroller: Rect, -- inside the panel
	featured: Rect, -- inside the panel (side) or over the track (drawer)
	featuredMode: string, -- "side" | "drawer"
	pillH: number, -- tier number pill on top of each column
	rowGap: number,
	cardW: number,
	cardH: number,
	colGap: number,
	stride: number, -- cardW + colGap
	visibleCols: number,
	touch: number, -- button height
	headerParts: { [string]: Rect }, -- season, badge, bar, claimAll, unlock, close (inside the header)
	text: { title: number, card: number, small: number },
}

PassModel.MAX_W = 1640
PassModel.MAX_H = 900
PassModel.FEATURED_W = 360
PassModel.MIN_SIDE_TRACK = 900 -- track width kept when the featured panel sits beside it

local function rect(x: number, y: number, w: number, h: number): Rect
	return { x = x, y = y, w = w, h = h }
end

-- rootW x rootH: the screen's design-space root (Layout.rootSize); `touch`:
-- Theme.TOUCH (design px); `dense`: Layout.dense (PC). Narrow / touch screens
-- fold the featured panel into a drawer over the track.
function PassModel.layout(rootW: number, rootH: number, touch: number, dense: boolean): PassLayout
	local margin = if dense then 24 else 10
	local pad = if dense then 16 else 12
	local pw = math.min(rootW - 2 * margin, PassModel.MAX_W)
	local ph = math.min(rootH - 2 * margin, PassModel.MAX_H)
	local panel = rect(math.floor((rootW - pw) / 2), math.floor((rootH - ph) / 2), pw, ph)
	local headerH = math.max(touch + 40, 118)
	local header = rect(pad, pad, pw - 2 * pad, headerH)
	local side = dense and pw - 2 * pad - PassModel.FEATURED_W - pad >= PassModel.MIN_SIDE_TRACK
	local featW = if side then PassModel.FEATURED_W else 0
	local trackY = pad + headerH + pad
	local trackW = pw - 2 * pad - (if side then featW + pad else 0)
	local trackH = ph - trackY - pad
	local track = rect(pad, trackY, trackW, trackH)
	local labelW = if dense then 92 else 104
	local scroller = rect(pad + labelW + 8, trackY, trackW - labelW - 8, trackH)
	local pillH = if dense then 40 else 48
	local rowGap = 10
	local cardH = math.min(math.floor((trackH - pillH - 2 * rowGap) / 2), 250)
	local cardW = math.clamp(math.floor(cardH * 0.8), 132, 184)
	local colGap = if dense then 14 else 12
	local featured = if side
		then rect(pad + trackW + pad, trackY, featW, trackH)
		else rect(
			pad + trackW - math.min(440, math.floor(trackW * 0.46)),
			trackY,
			math.min(440, math.floor(trackW * 0.46)),
			trackH
		)
	-- header: season | tier badge | bar (+ chips) | claim all | unlock | close
	local hp = header
	local gap = 12
	local btnH = touch
	local closeW = touch
	local claimW = if dense then 190 else 210
	local unlockW = if dense then 220 else 240
	local seasonW = if dense then 280 else 250
	local badgeW = math.min(headerH, if dense then 104 else 112)
	local barW = hp.w - (seasonW + badgeW + claimW + unlockW + closeW + 5 * gap)
	local by = math.floor((hp.h - btnH) / 2)
	local x = 0
	local parts: { [string]: Rect } = {}
	parts.season = rect(x, 0, seasonW, hp.h)
	x += seasonW + gap
	parts.badge = rect(x, math.floor((hp.h - badgeW) / 2), badgeW, badgeW)
	x += badgeW + gap
	parts.bar = rect(x, 0, barW, hp.h)
	x += barW + gap
	parts.claimAll = rect(x, by, claimW, btnH)
	x += claimW + gap
	parts.unlock = rect(x, by, unlockW, btnH)
	x += unlockW + gap
	parts.close = rect(x, by, closeW, btnH)
	return {
		panel = panel,
		pad = pad,
		header = header,
		track = track,
		labelW = labelW,
		scroller = scroller,
		featured = featured,
		featuredMode = if side then "side" else "drawer",
		pillH = pillH,
		rowGap = rowGap,
		cardW = cardW,
		cardH = cardH,
		colGap = colGap,
		stride = cardW + colGap,
		visibleCols = scroller.w / (cardW + colGap),
		touch = touch,
		headerParts = parts,
		text = if dense then { title = 34, card = 22, small = 14 } else { title = 30, card = 22, small = 14 },
	}
end

----------------------------------------------------------------------
-- Scroll / snap (columns centred in the scroller)
----------------------------------------------------------------------

-- Space before the first column (and after the last), so any column can sit
-- in the middle of the scroller.
function PassModel.leadPad(viewW: number, cardW: number): number
	return math.max(0, (viewW - cardW) / 2)
end

function PassModel.canvasWidth(n: number, cardW: number, colGap: number, viewW: number): number
	return 2 * PassModel.leadPad(viewW, cardW) + n * cardW + math.max(0, n - 1) * colGap
end

-- Left edge of column i (1-based) on the canvas.
function PassModel.columnX(i: number, cardW: number, colGap: number, viewW: number): number
	return PassModel.leadPad(viewW, cardW) + (i - 1) * (cardW + colGap)
end

-- CanvasPosition.X that centres column i, clamped to the canvas.
function PassModel.centreOffset(i: number, n: number, cardW: number, colGap: number, viewW: number): number
	local x = PassModel.columnX(i, cardW, colGap, viewW) + cardW / 2 - viewW / 2
	local maxX = math.max(0, PassModel.canvasWidth(n, cardW, colGap, viewW) - viewW)
	return math.clamp(x, 0, maxX)
end

-- Column whose centre is nearest the middle of the view at `offset`.
function PassModel.nearestIndex(
	offset: number,
	n: number,
	cardW: number,
	colGap: number,
	viewW: number
): number
	local mid = offset + viewW / 2 - PassModel.leadPad(viewW, cardW) - cardW / 2
	return math.clamp(math.floor(mid / (cardW + colGap) + 0.5) + 1, 1, math.max(n, 1))
end

-- Progress rail fill width on the canvas: up to the reached tier's centre,
-- plus the fraction towards the next one.
function PassModel.railFill(
	tier: number,
	frac: number,
	n: number,
	cardW: number,
	colGap: number,
	viewW: number
): number
	local lead = PassModel.leadPad(viewW, cardW)
	local stride = cardW + colGap
	local x = lead + cardW / 2 + (tier - 1 + math.clamp(frac, 0, 1)) * stride
	if tier >= n then
		x = PassModel.canvasWidth(n, cardW, colGap, viewW)
	end
	return math.max(0, x)
end

----------------------------------------------------------------------
-- Curves
----------------------------------------------------------------------

function PassModel.ease(kind: string, t: number): number
	local x = math.clamp(t, 0, 1)
	if kind == "outBack" then
		local c1 = 1.70158
		local c3 = c1 + 1
		return 1 + c3 * (x - 1) ^ 3 + c1 * (x - 1) ^ 2
	elseif kind == "outCubic" then
		return 1 - (1 - x) ^ 3
	elseif kind == "inOutSine" then
		return -(math.cos(math.pi * x) - 1) / 2
	elseif kind == "outQuad" then
		return 1 - (1 - x) * (1 - x)
	end
	return x
end

-- Frame-rate independent smoothing towards `target` (`speed` per second).
function PassModel.approach(cur: number, target: number, dt: number, speed: number): number
	local k = 1 - math.exp(-speed * math.max(dt, 0))
	local v = cur + (target - cur) * k
	if math.abs(target - v) < 0.0005 then
		return target
	end
	return v
end

-- Claimable cards float (design px offset) and their glow breathes (0..1).
function PassModel.bob(t: number, phase: number): number
	return math.sin(t * 2 * math.pi * 0.7 + phase) * 4
end

function PassModel.pulse(t: number, phase: number): number
	return 0.5 + 0.5 * math.sin(t * 2 * math.pi * 0.9 + phase)
end

-- Shine sweep: a UIGradient offset from -1.5 (left, off the card) to 1.5
-- over SHINE_SWEEP s, then a rest, staggered per column.
PassModel.SHINE_SWEEP = 0.9
PassModel.SHINE_PERIOD = 3.2
function PassModel.shine(t: number, index: number): number
	local p = (t + index * 0.11) % PassModel.SHINE_PERIOD
	if p >= PassModel.SHINE_SWEEP then
		return 1.5
	end
	return -1.5 + 3 * PassModel.ease("inOutSine", p / PassModel.SHINE_SWEEP)
end

-- Claim pop scale over `t` s (1 -> 1.18 -> 1 in 0.35 s).
PassModel.POP_TIME = 0.35
function PassModel.popScale(t: number): number
	local x = math.clamp(t / PassModel.POP_TIME, 0, 1)
	return 1 + 0.18 * math.sin(math.pi * x) * (1 - 0.4 * x)
end

-- Deterministic particle burst: `n` particles {dx, dy (px/s), size, life, spin}.
export type Particle = { vx: number, vy: number, size: number, life: number, spin: number }
function PassModel.burst(n: number, seed: number): { Particle }
	local out: { Particle } = {}
	local s = math.floor(math.abs(seed)) % 2147483647 + 1
	local function rnd(): number
		s = (s * 16807) % 2147483647
		return s / 2147483647
	end
	for i = 1, math.max(0, math.floor(n)) do
		local a = (i / math.max(n, 1)) * 2 * math.pi + (rnd() - 0.5) * 0.6
		local speed = 260 + rnd() * 260
		table.insert(out, {
			vx = math.cos(a) * speed,
			vy = math.sin(a) * speed - 120,
			size = 8 + rnd() * 10,
			life = 0.45 + rnd() * 0.35,
			spin = (rnd() - 0.5) * 720,
		})
	end
	return out
end

-- Fly-to-target path: a quadratic arc from a to b lifted by `lift` px.
function PassModel.arc(
	ax: number,
	ay: number,
	bx: number,
	by: number,
	lift: number,
	t: number
): (number, number)
	local x = math.clamp(t, 0, 1)
	local cx, cy = (ax + bx) / 2, math.min(ay, by) - lift
	local u = 1 - x
	return u * u * ax + 2 * u * x * cx + x * x * bx, u * u * ay + 2 * u * x * cy + x * x * by
end

-- Keyboard / gamepad: next selection from (tier, track) for a move.
function PassModel.move(tier: number, track: string, dir: string, n: number): (number, string)
	if dir == "left" then
		return math.max(1, tier - 1), track
	elseif dir == "right" then
		return math.min(n, tier + 1), track
	elseif dir == "pageLeft" then
		return math.max(1, tier - 5), track
	elseif dir == "pageRight" then
		return math.min(n, tier + 5), track
	elseif dir == "up" then
		return tier, "free"
	elseif dir == "down" then
		return tier, "premium"
	end
	return tier, track
end

return PassModel
