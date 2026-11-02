--!strict
-- Guard: validation helpers + per-player, per-remote token-bucket rate limiting.
-- Every OnServerEvent in the game goes through Guard.connect (ARCHITECTURE.md,
-- "Server authority rules"). Clients are hostile: type-check, reject NaN/inf,
-- clamp, whitelist, rate-limit, and only then call the handler.
--
-- Usage:
--   Guard.connect(Net.C2S.Vote, {
--       rate = 4, burst = 4,                -- tokens per second / bucket size
--       args = { Guard.T.int(1, 8) },       -- one validator per argument
--   }, function(player, optionIndex) ... end)
--
-- A validator is `(value: any) -> (ok: boolean, cleaned: any)`. Number
-- validators clamp; int/string/enum validators reject out-of-range values.
-- Extra arguments beyond `args` are rejected as malformed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any

local Guard = {}

export type Validator = (value: any) -> (boolean, any)
export type Spec = {
	args: { Validator }?,
	rate: number?, -- tokens refilled per second (default 5)
	burst: number?, -- bucket capacity (default = rate)
	name: string?, -- rate-limit key (default remote.Name)
}

-- Tunables -------------------------------------------------------------------
Guard.DEFAULT_RATE = 5
Guard.LOG_INTERVAL = 10 -- seconds between reject logs per player+remote
Guard.MALFORMED_KICK_THRESHOLD = 60 -- malformed calls inside the window -> kick
Guard.MALFORMED_WINDOW = 60 -- seconds
Guard.MAX_STRING = 64 -- default max string length

-- Validation helpers ----------------------------------------------------------

function Guard.isFiniteNumber(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

function Guard.clamp(x: number, lo: number, hi: number): number
	if x ~= x then
		return lo
	end
	return math.clamp(x, lo, hi)
end

function Guard.isString(x: any, maxLen: number?): boolean
	if type(x) ~= "string" then
		return false
	end
	if #x > (maxLen or Guard.MAX_STRING) then
		return false
	end
	return utf8.len(x) ~= nil -- reject invalid UTF-8
end

function Guard.isInt(x: any, lo: number?, hi: number?): boolean
	if not Guard.isFiniteNumber(x) or x % 1 ~= 0 then
		return false
	end
	if lo ~= nil and x < lo then
		return false
	end
	if hi ~= nil and x > hi then
		return false
	end
	return true
end

function Guard.isBoolean(x: any): boolean
	return type(x) == "boolean"
end

-- Validator constructors -----------------------------------------------------
Guard.T = {}

-- Finite number, clamped into [lo, hi].
function Guard.T.number(lo: number, hi: number): Validator
	return function(v: any)
		if not Guard.isFiniteNumber(v) then
			return false, nil
		end
		return true, Guard.clamp(v, lo, hi)
	end
end

-- Integer in [lo, hi]; anything else is rejected (indices must be exact).
function Guard.T.int(lo: number, hi: number): Validator
	return function(v: any)
		if not Guard.isInt(v, lo, hi) then
			return false, nil
		end
		return true, v
	end
end

function Guard.T.string(maxLen: number?): Validator
	return function(v: any)
		if not Guard.isString(v, maxLen) then
			return false, nil
		end
		return true, v
	end
end

function Guard.T.boolean(): Validator
	return function(v: any)
		if type(v) ~= "boolean" then
			return false, nil
		end
		return true, v
	end
end

-- String from a fixed whitelist.
function Guard.T.enum(values: { string }): Validator
	local set: { [string]: boolean } = {}
	for _, s in values do
		set[s] = true
	end
	return function(v: any)
		if type(v) ~= "string" or not set[v] then
			return false, nil
		end
		return true, v
	end
end

-- nil is allowed; otherwise the inner validator decides.
function Guard.T.optional(inner: Validator): Validator
	return function(v: any)
		if v == nil then
			return true, nil
		end
		return inner(v)
	end
end

-- Rate limiting --------------------------------------------------------------

type Bucket = { tokens: number, last: number }
type LogState = { lastLog: number, suppressed: number }
type PlayerState = {
	buckets: { [string]: Bucket },
	logs: { [string]: LogState },
	malformed: { number }, -- timestamps (os.clock) of malformed calls
}

local states: { [Player]: PlayerState } = {}

local function stateFor(player: Player): PlayerState
	local s = states[player]
	if not s then
		s = { buckets = {}, logs = {}, malformed = {} }
		states[player] = s
	end
	return s
end

-- Takes one token from the player's bucket for `key`. Returns false if empty.
function Guard.allow(player: Player, key: string, rate: number?, burst: number?): boolean
	local r = rate or Guard.DEFAULT_RATE
	local cap = burst or r
	local s = stateFor(player)
	local now = os.clock()
	local b = s.buckets[key]
	if not b then
		b = { tokens = cap, last = now }
		s.buckets[key] = b
	end
	b.tokens = math.min(cap, b.tokens + (now - b.last) * r)
	b.last = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

-- Logs a rejected call at most once per LOG_INTERVAL per player+remote.
-- `malformed` rejections (bad types/counts) count toward a kick threshold;
-- rate-limit drops do not, since a laggy honest client can burst.
function Guard.reject(player: Player, key: string, reason: string, malformed: boolean?)
	local s = stateFor(player)
	local now = os.clock()
	local log = s.logs[key]
	if not log then
		log = { lastLog = -math.huge, suppressed = 0 }
		s.logs[key] = log
	end
	if now - log.lastLog >= Guard.LOG_INTERVAL then
		local extra = if log.suppressed > 0 then string.format(" (+%d suppressed)", log.suppressed) else ""
		warn(
			string.format("[Guard] %s (%d) rejected %s: %s%s", player.Name, player.UserId, key, reason, extra)
		)
		log.lastLog = now
		log.suppressed = 0
	else
		log.suppressed += 1
	end

	if malformed then
		local list = s.malformed
		table.insert(list, now)
		while #list > 0 and now - list[1] > Guard.MALFORMED_WINDOW do
			table.remove(list, 1)
		end
		if #list >= Guard.MALFORMED_KICK_THRESHOLD then
			warn(
				string.format(
					"[Guard] kicking %s (%d) for sustained malformed remote calls",
					player.Name,
					player.UserId
				)
			)
			player:Kick("Connection error (invalid data). Please rejoin.")
		end
	end
end

-- Player input hub ------------------------------------------------------------
-- Every accepted remote call counts as input; CombatService also reports real
-- movement. LobbyService listens to reset its AFK auto-start counter (QC1 #15).

local inputListeners: { (Player) -> () } = {}

function Guard.onInput(fn: (Player) -> ())
	table.insert(inputListeners, fn)
end

function Guard.noteInput(player: Player)
	for _, fn in inputListeners do
		local ok, err = pcall(fn, player)
		if not ok then
			warn("[Guard] input listener errored: " .. tostring(err))
		end
	end
end

-- Connect --------------------------------------------------------------------

local function resolveRemote(remote: any): RemoteEvent
	if type(remote) == "string" then
		return Net.get(remote)
	end
	return remote
end

-- Validates arguments and rate-limits before calling handler(player, ...cleaned).
-- Handler errors are caught and logged with a traceback.
function Guard.connect(
	remote: RemoteEvent | string,
	spec: Spec,
	handler: (Player, ...any) -> ()
): RBXScriptConnection
	local ev = resolveRemote(remote)
	local key = spec.name or ev.Name
	local validators: { Validator } = spec.args or {}
	local nArgs = #validators
	local rate = spec.rate or Guard.DEFAULT_RATE
	local burst = spec.burst or rate

	return ev.OnServerEvent:Connect(function(player: Player, ...: any)
		if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
			return
		end
		if not Guard.allow(player, key, rate, burst) then
			Guard.reject(player, key, "rate limited", false)
			return
		end
		local packed = table.pack(...)
		if packed.n > nArgs then
			Guard.reject(player, key, string.format("too many args (%d > %d)", packed.n, nArgs), true)
			return
		end
		local cleaned = table.create(nArgs)
		for i = 1, nArgs do
			local ok, value = validators[i](packed[i])
			if not ok then
				Guard.reject(player, key, string.format("bad arg #%d (%s)", i, typeof(packed[i])), true)
				return
			end
			cleaned[i] = value
		end
		Guard.noteInput(player)
		local ok, err = xpcall(handler, debug.traceback, player, table.unpack(cleaned, 1, nArgs))
		if not ok then
			warn(string.format("[Guard] handler for %s errored: %s", key, tostring(err)))
		end
	end)
end

Players.PlayerRemoving:Connect(function(player: Player)
	states[player] = nil
end)

return Guard
