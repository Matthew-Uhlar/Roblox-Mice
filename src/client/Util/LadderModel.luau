--!strict
-- Pure model of the difficulty ladder, numbered waves and the Early Horn
-- (iteration 2 PLAN; docs/iter/2/ALIGNMENT.md §2b, §2c A1). No Roblox APIs.
--
--   LadderModel.tiers(cfg)                 the 11 tiers (Config/Difficulty, else the fallback below)
--   LadderModel.view(cfg, profile, lobby)  tiles: name, reward ×, gem tier, locked, best solo / squad
--   LadderModel.skipOptions(profile)       Early Horn ("Skip Wave At") choices
--   LadderModel.wave(match, run)           {wave, waves, stageWave, boss}
--   LadderModel.horn(h, now)               {phase = "ready" | "warning" | nil, seconds?, streak}
--
-- Tier names are ours (cheese-themed, never Liberty's). Config/Difficulty (M2)
-- wins when present: {TIERS = {{id/tier, name, reward, gemTier, ...}}}.

local LadderModel = {}

local function num(v: any, d: number): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return d
	end
	return n
end

export type Tier = {
	tier: number,
	name: string,
	reward: number,
	gemTier: number,
	color: { number },
	blurb: string,
}

LadderModel.FALLBACK = {
	{ tier = 1, name = "Mild", reward = 0.75, gemTier = 1, color = { 255, 236, 160 }, blurb = "Softer mice. Learn the ropes." },
	{ tier = 2, name = "Medium", reward = 1.0, gemTier = 2, color = { 255, 214, 92 }, blurb = "The standard run." },
	{ tier = 3, name = "Sharp", reward = 1.2, gemTier = 3, color = { 255, 190, 60 }, blurb = "Pressure 3." },
	{ tier = 4, name = "Extra Sharp", reward = 1.4, gemTier = 4, color = { 250, 160, 40 }, blurb = "Pressure 5." },
	{ tier = 5, name = "Aged", reward = 1.7, gemTier = 5, color = { 230, 130, 40 }, blurb = "Pressure 8." },
	{ tier = 6, name = "Smoked", reward = 2.0, gemTier = 6, color = { 190, 110, 60 }, blurb = "Pressure 11." },
	{ tier = 7, name = "Pungent", reward = 2.4, gemTier = 7, color = { 160, 170, 60 }, blurb = "Pressure 14." },
	{ tier = 8, name = "Stinky", reward = 2.9, gemTier = 8, color = { 120, 150, 70 }, blurb = "Pressure 17." },
	{ tier = 9, name = "Scorched", reward = 3.5, gemTier = 9, color = { 220, 80, 40 }, blurb = "The full Pressure board." },
	{ tier = 10, name = "Moldy", reward = 4.2, gemTier = 10, color = { 110, 160, 130 }, blurb = "Full board, tougher mice." },
	{ tier = 11, name = "Doomwheel", reward = 5.0, gemTier = 11, color = { 150, 60, 200 }, blurb = "The top of the ladder." },
} :: { Tier }

function LadderModel.tiers(cfg: any): { Tier }
	local src = if type(cfg) == "table" then (cfg.TIERS or cfg.LIST or cfg.tiers) else nil
	if type(src) ~= "table" or #src == 0 then
		return LadderModel.FALLBACK
	end
	local out: { Tier } = {}
	for i, t in src do
		if type(t) == "table" then
			local fb = LadderModel.FALLBACK[i] or LadderModel.FALLBACK[#LadderModel.FALLBACK]
			local n = math.floor(num(t.tier or t.id, i))
			table.insert(out, {
				tier = n,
				name = tostring(t.name or fb.name),
				reward = num(t.reward or t.rewardMult or t.mult, fb.reward),
				gemTier = math.floor(num(t.gemTier, n)),
				color = if type(t.color) == "table" then t.color else fb.color,
				blurb = tostring(t.blurb or t.text or fb.blurb),
			})
		end
	end
	table.sort(out, function(a, b)
		return a.tier < b.tier
	end)
	return out
end

function LadderModel.name(cfg: any, tier: number?): string
	for _, t in LadderModel.tiers(cfg) do
		if t.tier == tier then
			return t.name
		end
	end
	return "Tier " .. tostring(tier or "?")
end

-- The profile's ladder record. Accepts profile.ladder = {unlocked, bestSolo,
-- bestSquad} (numbers, or maps with `account` / per-class entries).
function LadderModel.record(profile: any, classId: string?): (number, number, number)
	local l = if type(profile) == "table" and type(profile.ladder) == "table" then profile.ladder else {}
	local unlocked = math.max(1, math.floor(num(l.unlocked or l.unlockedTier or l.maxTier, 2)))
	local function best(v: any): number
		if type(v) == "table" then
			return math.floor(num((classId and v[classId]) or v.account or v.best, 0))
		end
		return math.floor(num(v, 0))
	end
	return unlocked, best(l.bestSolo), best(l.bestSquad)
end

-- The lobby's chosen tier (Lobby payload `tier` / `ladder.tier`), else nil.
function LadderModel.lobbyTier(lobby: any): number?
	if type(lobby) ~= "table" then
		return nil
	end
	local t = lobby.tier
	if type(t) == "table" then
		t = t.tier or t.id
	end
	if t == nil and type(lobby.ladder) == "table" then
		t = lobby.ladder.tier
	end
	return tonumber(t)
end

export type Tile = Tier & { locked: boolean, selected: boolean, isBestSolo: boolean, isBestSquad: boolean }

function LadderModel.view(cfg: any, profile: any, lobby: any, classId: string?): { Tile }
	local unlocked, bestSolo, bestSquad = LadderModel.record(profile, classId)
	local chosen = LadderModel.lobbyTier(lobby)
	local out: { Tile } = {}
	for _, t in LadderModel.tiers(cfg) do
		local tile = table.clone(t) :: any
		tile.locked = t.tier > unlocked
		tile.selected = t.tier == chosen
		tile.isBestSolo = t.tier == bestSolo
		tile.isBestSquad = t.tier == bestSquad
		table.insert(out, tile)
	end
	return out
end

-- Early Horn / Skip Wave At: Off, 50, 70, 90 (% of the wave stomped).
-- Default Off for rookies (runs 0-2), else 70.
LadderModel.SKIP_OPTIONS = { 0, 50, 70, 90 }

function LadderModel.skipWaveAt(profile: any): number
	local st = if type(profile) == "table" and type(profile.settings) == "table" then profile.settings else {}
	local v = tonumber(st.skipWaveAt)
	if v ~= nil then
		return v
	end
	local runs = if type(profile) == "table" and type(profile.stats) == "table" then num(profile.stats.runs, 0) else 0
	return if runs < 3 then 0 else 70
end

function LadderModel.skipLabel(v: number): string
	return if v <= 0 then "Off" else tostring(math.floor(v)) .. "%"
end

function LadderModel.nextSkip(v: number): number
	local opts = LadderModel.SKIP_OPTIONS
	local i = table.find(opts, v) or 1
	return opts[(i % #opts) + 1]
end

-- Wave counter: Match `wave` / `waves` (20 per match, 5 per stage, every 5th a boss).
export type Wave = { wave: number, waves: number, stageWave: number, boss: boolean }
function LadderModel.wave(match: any, run: any): Wave?
	local src = if type(match) == "table" and match.wave ~= nil then match else run
	if type(src) ~= "table" or src.wave == nil then
		return nil
	end
	local w = math.max(1, math.floor(num(src.wave, 1)))
	local waves = math.max(w, math.floor(num(src.waves, 20)))
	local per = math.max(1, math.floor(num(src.wavesPerStage, 5)))
	local sw = ((w - 1) % per) + 1
	return { wave = w, waves = waves, stageWave = sw, boss = src.bossWave == true or sw == per }
end

export type Horn = { phase: string?, seconds: number?, streak: number, frac: number?, need: number? }

-- Horn state from Match `horn` {stomped (0..1), need (0..1), at? (server time
-- the next wave is called), streak?, ready?}. "ready" = the threshold is met
-- and the button may call it now; "warning" = called, the next wave in N s.
function LadderModel.horn(h: any, now: number): Horn
	if type(h) ~= "table" then
		return { phase = nil, seconds = nil, streak = 0 }
	end
	local streak = math.floor(num(h.streak, 0))
	local at = tonumber(h.at)
	if at and at > now then
		return { phase = "warning", seconds = at - now, streak = streak, frac = tonumber(h.stomped), need = tonumber(h.need) }
	end
	local frac, need = tonumber(h.stomped), tonumber(h.need)
	local ready = h.ready == true or (frac ~= nil and need ~= nil and need > 0 and frac >= need)
	return { phase = if ready then "ready" else nil, seconds = nil, streak = streak, frac = frac, need = need }
end

return LadderModel
