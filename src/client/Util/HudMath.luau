--!strict
-- Pure maths for the v4 in-run HUD (docs/V4-PLAN.md "Interface", review B
-- S2-1 / S2-2). No Roblox APIs; specs run it in Lune.
--
--   storm      Net.S2C.Storm {cx, cz, r, toR, closeStart, closeEnd, dps, now}
--   redeploy   Net.S2C.Redeploy {untilT}
--   vignette   damage flash + low-HP pulse alpha
--   objective  the next goal for the objective arrow (champion / POI / gate / boss)
--   pings      ping kinds, quick-chat presets, wheel sector picking
--   awards     Net.S2C.Awards {mvp, accolades, you}
--   results    secured cheese, Play Again / Share visibility, win check

local HudMath = {}

local function num(v: any, d: number): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return d
	end
	return n
end

----------------------------------------------------------------------
-- Storm ("The Melt")
----------------------------------------------------------------------

export type Storm = {
	cx: number,
	cz: number,
	r: number,
	toR: number,
	closeStart: number, -- local clock (State.serverNow) after the offset fix
	closeEnd: number,
	dps: number,
}

-- Normalises a Storm payload. `clientNow` is State.serverNow() when it
-- arrived: the payload's own `now` may be World time, so closeStart/closeEnd
-- are shifted onto the client clock by (clientNow - now).
function HudMath.storm(p: any, clientNow: number): Storm?
	if type(p) ~= "table" then
		return nil
	end
	local r = tonumber(p.r)
	if r == nil or r <= 0 then
		return nil
	end
	local offset = clientNow - num(p.now, clientNow)
	local cs = num(p.closeStart, clientNow) + offset
	local ce = num(p.closeEnd, cs) + offset
	if ce < cs then
		ce = cs
	end
	return {
		cx = num(p.cx, 0),
		cz = num(p.cz, 0),
		r = r,
		toR = math.max(0, num(p.toR, r)),
		closeStart = cs,
		closeEnd = ce,
		dps = math.max(0, num(p.dps, 0)),
	}
end

-- Current safe radius at `now`.
function HudMath.stormRadius(s: Storm, now: number): number
	if now <= s.closeStart then
		return s.r
	elseif now >= s.closeEnd or s.closeEnd <= s.closeStart then
		return s.toR
	end
	local a = (now - s.closeStart) / (s.closeEnd - s.closeStart)
	return s.r + (s.toR - s.r) * a
end

export type StormStatus = {
	radius: number,
	dist: number, -- from the centre
	outside: boolean,
	edge: number, -- studs to the edge (negative when outside)
	phase: string, -- "wait" (shrink ahead) | "closing" | "still"
	seconds: number?, -- until the shrink starts (wait) or ends (closing)
	text: string,
}

function HudMath.stormStatus(s: Storm, x: number, z: number, now: number): StormStatus
	local radius = HudMath.stormRadius(s, now)
	local dx, dz = x - s.cx, z - s.cz
	local dist = math.sqrt(dx * dx + dz * dz)
	local phase, seconds, text
	if s.toR < s.r - 0.5 and now < s.closeStart then
		phase, seconds = "wait", s.closeStart - now
		text = "The Melt closes in " .. HudMath.clock(seconds)
	elseif s.toR < s.r - 0.5 and now < s.closeEnd then
		phase, seconds = "closing", s.closeEnd - now
		text = "The Melt is closing " .. HudMath.clock(seconds)
	else
		phase, seconds = "still", nil
		text = "The Melt"
	end
	return {
		radius = radius,
		dist = dist,
		outside = dist > radius,
		edge = radius - dist,
		phase = phase,
		seconds = seconds,
		text = text,
	}
end

-- Points on a circle (world x, z) for the minimap ring.
function HudMath.ringPoints(cx: number, cz: number, r: number, n: number): { { number } }
	local out = {}
	for i = 0, n - 1 do
		local a = (i / n) * math.pi * 2
		table.insert(out, { cx + math.cos(a) * r, cz + math.sin(a) * r })
	end
	return out
end

function HudMath.clock(seconds: number?): string
	local s = math.max(0, math.ceil(num(seconds, 0)))
	return string.format("%d:%02d", s // 60, s % 60)
end

----------------------------------------------------------------------
-- Redeploy (Herd Call)
----------------------------------------------------------------------

-- Seconds left (nil when no redeploy is pending).
function HudMath.redeployLeft(p: any, now: number): number?
	if type(p) ~= "table" then
		return nil
	end
	local u = tonumber(p.untilT or p["until"] or p.at)
	if u == nil then
		return nil
	end
	local left = u - now
	if left <= -1 then
		return nil
	end
	return math.max(0, left)
end

----------------------------------------------------------------------
-- Damage vignette
----------------------------------------------------------------------

HudMath.FLASH_IN = 0.05
HudMath.FLASH_OUT = 0.4
HudMath.LOW_HP = 0.3
HudMath.PULSE_HZ = 1.2

-- Edge transparency (1 = invisible). `sinceHit` seconds since the last hit,
-- `hpFrac` 0..1, `t` a running clock for the pulse, `downed` dims fully.
function HudMath.vignette(sinceHit: number, hpFrac: number, t: number, downed: boolean?): number
	local flash = 1
	if sinceHit >= 0 and sinceHit < HudMath.FLASH_IN + HudMath.FLASH_OUT then
		if sinceHit < HudMath.FLASH_IN then
			flash = 1 - 0.65 * (sinceHit / HudMath.FLASH_IN)
		else
			flash = 0.35 + 0.65 * ((sinceHit - HudMath.FLASH_IN) / HudMath.FLASH_OUT)
		end
	end
	local pulse = 1
	if downed then
		pulse = 0.55
	elseif hpFrac > 0 and hpFrac < HudMath.LOW_HP then
		local wave = 0.5 + 0.5 * math.sin(t * math.pi * 2 * HudMath.PULSE_HZ)
		-- deeper the lower the HP, min transparency 0.55
		local depth = 1 - hpFrac / HudMath.LOW_HP
		pulse = 1 - (0.45 * depth * (0.4 + 0.6 * wave))
		pulse = math.max(0.55, pulse)
	end
	return math.clamp(math.min(flash, pulse), 0, 1)
end

----------------------------------------------------------------------
-- Objective arrow
----------------------------------------------------------------------

export type Goal = { kind: string, x: number, z: number, label: string }

-- Picks the next goal: during the gate window the Rind Gate; in the boss
-- phase the boss; else the nearest live champion inside the storm, else the
-- nearest unfinished POI inside the storm. `ctx` = {phase, portal?, boss?,
-- champions?, pois?, storm?, now}.
function HudMath.objective(ctx: any, x: number, z: number): Goal?
	if type(ctx) ~= "table" then
		return nil
	end
	local phase = tostring(ctx.phase or "")
	local function d2(px: number, pz: number): number
		return (px - x) ^ 2 + (pz - z) ^ 2
	end
	local storm: Storm? = ctx.storm
	local now = num(ctx.now, 0)
	local function safe(px: number, pz: number): boolean
		if not storm then
			return true
		end
		local r = math.min(HudMath.stormRadius(storm, now), storm.toR + 1)
		return (px - storm.cx) ^ 2 + (pz - storm.cz) ^ 2 <= r * r
	end
	local portal = ctx.portal
	if (phase == "Extraction" or phase == "StageClear") and type(portal) == "table" and portal.x then
		return { kind = "gate", x = portal.x, z = portal.z, label = "Rind Gate" }
	end
	local boss = ctx.boss
	if phase == "Boss" and type(boss) == "table" and boss.x then
		return { kind = "boss", x = boss.x, z = boss.z, label = "Boss" }
	end
	if phase ~= "Waves" and phase ~= "Boss" then
		return nil
	end
	local best: Goal? = nil
	local bestD = math.huge
	for _, ch in (if type(ctx.champions) == "table" then ctx.champions else {}) do
		local cx, cz = tonumber(ch.liveX or ch.x), tonumber(ch.liveZ or ch.z)
		if cx and cz and safe(cx, cz) then
			local d = d2(cx, cz)
			if d < bestD then
				bestD = d
				best = { kind = "champion", x = cx, z = cz, label = "Champion" }
			end
		end
	end
	if best then
		return best
	end
	for _, p in (if type(ctx.pois) == "table" then ctx.pois else {}) do
		local px, pz = tonumber(p.x), tonumber(p.z)
		if px and pz and not p.done and safe(px, pz) then
			local d = d2(px, pz)
			if d < bestD then
				bestD = d
				best = { kind = "poi", x = px, z = pz, label = tostring(p.label or "Point of interest") }
			end
		end
	end
	-- nothing safe left: head for the storm centre
	if not best and storm then
		local dist = math.sqrt(d2(storm.cx, storm.cz))
		if dist > HudMath.stormRadius(storm, now) * 0.5 then
			return { kind = "safe", x = storm.cx, z = storm.cz, label = "Safe zone" }
		end
	end
	return best
end

-- Screen-space angle (radians, 0 = up, clockwise) from the hero to a goal.
-- `yaw` is the camera yaw (Util/CameraMath; iteration 5: free). At yaw 0
-- (north-up) +X is right and +Z is down the screen.
function HudMath.arrowAngle(fromX: number, fromZ: number, toX: number, toZ: number, yaw: number?): number
	local dx, dz = toX - fromX, toZ - fromZ
	local y = yaw or 0
	if y ~= 0 then
		local c, s = math.cos(y), math.sin(y)
		dx, dz = dx * c - dz * s, dx * s + dz * c
	end
	return math.atan2(dx, -dz)
end

----------------------------------------------------------------------
-- Pings and quick-chat (squad-only, preset text only)
----------------------------------------------------------------------

-- Kinds sent with Net.C2S.Ping(kind, x, z): the same list as RunDirector K.PING_KINDS.
HudMath.PING_KINDS = { "go", "enemy", "loot", "help", "champion", "extract", "stay" }
HudMath.PING_INFO = {
	go = { text = "Go here", icon = "📍", color = { 255, 214, 92 } },
	enemy = { text = "Enemy!", icon = "⚔", color = { 226, 72, 58 } },
	loot = { text = "Loot here", icon = "💰", color = { 96, 190, 92 } },
	help = { text = "Help!", icon = "🆘", color = { 255, 140, 40 } },
	champion = { text = "Fight champion", icon = "👑", color = { 179, 107, 255 } },
	extract = { text = "Extract!", icon = "🌀", color = { 160, 120, 255 } },
	stay = { text = "Stay!", icon = "🛡", color = { 255, 201, 60 } },
	-- iteration 7 (team Systems, Run/DeathRecap): the automatic "needs revive"
	-- ping of a downed squadmate (server-sent only; not on the ping wheel)
	revive = { text = "Revive me!", icon = "💗", color = { 255, 90, 120 } },
} :: { [string]: { text: string, icon: string, color: { number } } }

-- Net.C2S.QuickChat(index): 1-based into this list. Team M2 must use the same
-- order (docs/research/v4-features.md §4.6).
HudMath.QUICK_CHAT =
	{ "Nice!", "Thanks!", "Follow me", "Wait", "Group up", "Champion!", "Extract?", "Let's stay!" }

-- Wheel sector under a pointer offset (dx right, dy down, screen px).
-- Sector 1 is at the top, then clockwise. nil inside the dead zone.
function HudMath.wheelSector(dx: number, dy: number, n: number, dead: number?): number?
	if n <= 0 then
		return nil
	end
	if dx * dx + dy * dy < (dead or 18) ^ 2 then
		return nil
	end
	local a = math.atan2(dx, -dy) -- 0 = up, clockwise
	if a < 0 then
		a += math.pi * 2
	end
	local step = math.pi * 2 / n
	return (math.floor((a + step / 2) / step) % n) + 1
end

-- Offset (x, y) of wheel slot `i` of `n` at radius `r` (slot 1 at the top).
function HudMath.wheelSlot(i: number, n: number, r: number): (number, number)
	local a = (i - 1) / n * math.pi * 2
	return math.sin(a) * r, -math.cos(a) * r
end

export type PingMark = {
	by: any,
	squad: number?,
	kind: string,
	x: number,
	z: number,
	t: number,
	text: string,
	icon: string,
	color: { number },
	chat: string?,
}

HudMath.PING_SECONDS = 6

-- Context kind for a quick ping at (x, z): a champion or the boss nearby ->
-- "champion", the Rind Gate -> "extract", a live POI / loot -> "loot", else "go".
-- `marks` = {champions?, portal?, boss?, pois?} (world positions).
function HudMath.contextPing(x: number, z: number, marks: any): string
	if type(marks) ~= "table" then
		return "go"
	end
	local function near(px: any, pz: any, r: number): boolean
		local a, b = tonumber(px), tonumber(pz)
		return a ~= nil and b ~= nil and (a - x) ^ 2 + (b - z) ^ 2 <= r * r
	end
	for _, ch in (if type(marks.champions) == "table" then marks.champions else {}) do
		if near(ch.liveX or ch.x, ch.liveZ or ch.z, 14) then
			return "champion"
		end
	end
	local boss = marks.boss
	if type(boss) == "table" and near(boss.x, boss.z, 16) then
		return "champion"
	end
	local portal = marks.portal
	if type(portal) == "table" and near(portal.x, portal.z, 16) then
		return "extract"
	end
	for _, p in (if type(marks.pois) == "table" then marks.pois else {}) do
		if not p.done and near(p.x, p.z, 10) then
			return "loot"
		end
	end
	return "go"
end

-- Normalises a PingShown payload. Quick-chat lines arrive as kind "chat"
-- with `index` (or kind "chat:<i>"), and carry no position.
function HudMath.ping(p: any, now: number): PingMark?
	if type(p) ~= "table" then
		return nil
	end
	local kind = tostring(p.kind or "go")
	local chat: string? = nil
	local idx = tonumber(p.index)
	local ci = string.match(kind, "^chat:(%d+)$")
	if ci then
		idx = tonumber(ci)
		kind = "chat"
	end
	if kind == "chat" then
		chat = if idx then HudMath.QUICK_CHAT[idx :: number] else nil
		if type(p.text) == "string" and chat == nil then
			chat = p.text
		end
		if not chat then
			return nil
		end
	end
	local info = HudMath.PING_INFO[kind] or HudMath.PING_INFO.go
	return {
		by = p.by,
		squad = tonumber(p.squad),
		kind = kind,
		x = num(p.x, 0),
		z = num(p.z, 0),
		t = num(p.t, now),
		text = chat or info.text,
		icon = if chat then "💬" else info.icon,
		color = info.color,
		chat = chat,
	}
end

----------------------------------------------------------------------
-- Awards (MVP + accolades)
----------------------------------------------------------------------

export type Accolade = { id: string, text: string, icon: string, value: string? }

local ACCOLADE_TEXT: { [string]: { string } } = {
	mouse_masher = { "Mouse Masher", "🐭" },
	champion_slayer = { "Champion Slayer", "👑" },
	clutch_reviver = { "Clutch Reviver", "💫" },
	loot_goblin = { "Loot Goblin", "💰" },
	vault_raider = { "Vault Raider", "🏦" },
	totem_keeper = { "Totem Keeper", "🗿" },
	boss_breaker = { "Boss Breaker", "💥" },
	escape_artist = { "Escape Artist", "🌀" },
	pack_mule = { "Pack Mule", "🧀" },
	bounty_hunter = { "Bounty Hunter", "🎯" },
	melt_dodger = { "Melt Dodger", "🔥" },
	iron_trunk = { "Iron Trunk", "🛡" },
}

local function titleCase(id: string): string
	local s = id:gsub("_", " ")
	return (s:gsub("(%a)([%w]*)", function(a, b)
		return string.upper(a) .. b
	end))
end

function HudMath.accolade(a: any): Accolade?
	if type(a) == "string" then
		local t = ACCOLADE_TEXT[a]
		return { id = a, text = if t then t[1] else titleCase(a), icon = if t then t[2] else "🏅" }
	elseif type(a) == "table" then
		local id = tostring(a.id or a.key or a.kind or "award")
		local t = ACCOLADE_TEXT[id]
		local v = a.value or a.stat
		return {
			id = id,
			text = tostring(a.label or a.name or a.title or (if t then t[1] else titleCase(id))),
			icon = tostring(a.icon or (if t then t[2] else "🏅")),
			value = if v ~= nil then tostring(v) else nil,
		}
	end
	return nil
end

export type Awards = {
	mvpId: any,
	mvpName: string?,
	mvpScore: number?,
	mvpIsYou: boolean,
	yours: { Accolade },
	topBotName: string?,
}

-- `meId` is the local UserId. `you` may be the accolade list or {accolades = ...}.
-- `mice` (optional): your mice count, for the fallback accolade when the
-- server gave you none (iteration 1 #12: every human gets one).
function HudMath.awards(p: any, meId: number, mice: number?): Awards?
	if type(p) ~= "table" then
		return nil
	end
	local mvp = p.mvp
	local mvpId, mvpName, mvpScore = nil, nil, nil
	if type(mvp) == "table" then
		mvpId = mvp.id or mvp.userId
		mvpName = if mvp.name ~= nil then tostring(mvp.name) else nil
		mvpScore = tonumber(mvp.score)
	elseif mvp ~= nil then
		mvpId = mvp
	end
	local yours: { Accolade } = {}
	local src = p.you
	if type(src) == "table" and type(src.accolades) == "table" then
		src = src.accolades
	end
	if type(src) ~= "table" and type(p.accolades) == "table" then
		src = p.accolades[meId] or p.accolades[tostring(meId)]
	end
	if type(src) == "table" then
		for _, a in src do
			local e = HudMath.accolade(a)
			if e and #yours < 3 then
				table.insert(yours, e)
			end
		end
	end
	if #yours == 0 and mice and mice > 0 then
		table.insert(
			yours,
			{ id = "mouse_masher", text = "Mouse Masher", icon = "🐭", value = tostring(math.floor(mice)) }
		)
	end
	-- iteration 1 #12: the MVP is a human; the best bot is shown apart
	local tb = p.topBot
	local topBotName: string? = if type(tb) == "table" and tb.name ~= nil then tostring(tb.name) else nil
	return {
		mvpId = mvpId,
		mvpName = mvpName,
		mvpScore = mvpScore,
		mvpIsYou = mvpId ~= nil and tonumber(mvpId) == meId,
		yours = yours,
		topBotName = topBotName,
	}
end

----------------------------------------------------------------------
-- Results
----------------------------------------------------------------------

-- Lower-case result kind: "extracted" | "lastherd" | "eliminated" | "win" | "wipe" | nil
function HudMath.resultKind(r: any): string?
	if type(r) ~= "table" then
		return nil
	end
	if r.lastHerd == true then
		return "lastherd"
	end
	if type(r.result) == "string" then
		return string.lower(r.result)
	end
	if r.outcome == "Win" then
		return "win"
	elseif r.outcome ~= nil then
		return "wipe"
	end
	return nil
end

-- A WIN: extracted or Last Herd (v1: outcome Win). The shop card and the
-- "View in shop" link only ever show on a win.
function HudMath.isWin(r: any): boolean
	local k = HudMath.resultKind(r)
	return k == "extracted" or k == "lastherd" or k == "win"
end

-- Play Again (fresh server) is offered once you are out: eliminated or extracted.
function HudMath.canPlayAgain(r: any): boolean
	local k = HudMath.resultKind(r)
	return k == "extracted" or k == "lastherd" or k == "eliminated" or k == "win" or k == "wipe"
end

-- Secured cheese (banked instantly during the run, kept even on a wipe).
function HudMath.secured(r: any): number
	if type(r) ~= "table" then
		return 0
	end
	return math.max(0, math.floor(num(r.secured or r.securedCheese or r.cheeseSecured, 0)))
end

----------------------------------------------------------------------
-- Kill streak (PvE)
----------------------------------------------------------------------

HudMath.STREAK_RESET = 2 -- seconds without a kill

-- Label for a streak count, plus whether it is a milestone pop (25 / 50 / 100…).
function HudMath.streakLabel(n: number): (string, boolean)
	local milestone = n == 25 or n == 50 or (n >= 100 and n % 50 == 0)
	local word = if n >= 100
		then "STAMPEDE!"
		elseif n >= 50 then "RAMPAGE!"
		elseif n >= 25 then "STOMPING!"
		else "STOMP!"
	return string.format("×%d %s", n, word), milestone
end

----------------------------------------------------------------------
-- Calm upgrade picker (iteration 1 #19, P-13)
----------------------------------------------------------------------

HudMath.CALM_MICE = 6 -- this many mice within CALM_RADIUS = "in a fight"
HudMath.CALM_RADIUS = 20
HudMath.CALM_SECONDS = 1.5 -- open after this long without a fight
HudMath.CALM_MAX_WAIT = 8 -- ... or after this long, whatever happens

export type CalmGate = { offerId: number?, firstAt: number, calmSince: number?, open: boolean }

function HudMath.newCalmGate(): CalmGate
	return { offerId = nil, firstAt = 0, calmSince = nil, open = false }
end

-- Should the picker for `offerId` be open now? `nearMice` = mice within
-- CALM_RADIUS of the hero. Once open it stays open for that offer.
function HudMath.calmGate(g: CalmGate, offerId: number?, nearMice: number, now: number): boolean
	if offerId == nil then
		g.offerId, g.calmSince, g.open = nil, nil, false
		return false
	end
	if g.offerId ~= offerId then
		local wasOpen = g.open and g.offerId ~= nil
		g.offerId = offerId
		g.firstAt = now
		g.calmSince = nil
		-- the next queued level opens at once while the strip is already up
		g.open = wasOpen
	end
	if g.open then
		return true
	end
	if nearMice >= HudMath.CALM_MICE then
		g.calmSince = nil
	elseif g.calmSince == nil then
		g.calmSince = now
	end
	if
		(g.calmSince ~= nil and now - (g.calmSince :: number) >= HudMath.CALM_SECONDS)
		or now - g.firstAt >= HudMath.CALM_MAX_WAIT
	then
		g.open = true
	end
	return g.open
end

-- Recommended card for auto-pick: the server's `recommended` flag, else the
-- highest rarity, else the first.
local RARITY_RANK = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5 }
function HudMath.recommendedCard(cards: any): number
	if type(cards) ~= "table" then
		return 1
	end
	local best, bestRank = 1, -1
	for i, c in cards do
		if type(c) == "table" then
			if c.recommended == true then
				return i
			end
			local r = RARITY_RANK[tostring(c.rarity)] or 0
			if r > bestRank then
				best, bestRank = i, r
			end
		end
	end
	return best
end

return HudMath
