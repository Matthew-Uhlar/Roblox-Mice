-- Deterministic scheduler with virtual time for the runtime emulator.
--
-- Every script thread is a plain coroutine resumed by this scheduler. Each thread
-- carries a context (the server, or one client), so `Players.LocalPlayer`,
-- `RunService:IsClient()` and remote routing know who is running. Errors in any
-- thread or signal handler are recorded with a traceback (never swallowed), and
-- `warn` output is recorded too, so specs can assert on both.

local Scheduler = {}
Scheduler.__index = Scheduler

export type Ctx = {
	name: string,
	isServer: boolean,
	isClient: boolean,
	player: any,
	dead: boolean,
	moduleCache: { [any]: any },
	loading: { [any]: any },
	shared: { [any]: any },
	G: { [any]: any },
	camera: any,
	callbacks: { [any]: any },
	viewport: any,
	kicked: string?,
}

local function heapPush(h, item)
	table.insert(h, item)
	local i = #h
	while i > 1 do
		local p = i // 2
		local a, b = h[p], h[i]
		if a.at < b.at or (a.at == b.at and a.seq < b.seq) then
			break
		end
		h[p], h[i] = b, a
		i = p
	end
end

local function heapPop(h)
	local n = #h
	if n == 0 then
		return nil
	end
	local top = h[1]
	h[1] = h[n]
	h[n] = nil
	n -= 1
	local i = 1
	while true do
		local l, r = i * 2, i * 2 + 1
		local s = i
		local function less(x, y)
			local a, b = h[x], h[y]
			return a.at < b.at or (a.at == b.at and a.seq < b.seq)
		end
		if l <= n and less(l, s) then
			s = l
		end
		if r <= n and less(r, s) then
			s = r
		end
		if s == i then
			break
		end
		h[s], h[i] = h[i], h[s]
		i = s
	end
	return top
end

function Scheduler.new(opts: { [string]: any }?)
	local o = opts or {}
	local self = setmetatable({}, Scheduler)
	self.now = 0
	self.frame = 0
	self.dt = o.dt or (1 / 60)
	self.epoch = o.epoch or 1_790_000_000 -- os.time() at virtual t = 0
	self.timers = {}
	self.seq = 0
	self.deferred = {}
	self.threadCtx = setmetatable({}, { __mode = "k" })
	self.cancelled = setmetatable({}, { __mode = "k" })
	self.current = nil :: Ctx?
	self.errors = {} :: { { ctx: string, message: string, traceback: string } }
	self.warnings = {} :: { { ctx: string, message: string } }
	self.prints = {} :: { { ctx: string, message: string } }
	self.gaps = {} :: { string }
	self.gapSet = {}
	self.echo = o.echo == true
	self.signalBehavior = o.signalBehavior or "Deferred"
	self.frameHooks = {} -- functions(dt) run by step() in the driver thread
	return self
end

function Scheduler:ctxName(ctx: Ctx?): string
	return if ctx then ctx.name else "driver"
end

function Scheduler:recordError(ctx: Ctx?, message: any, traceback: string?)
	local msg = tostring(message)
	table.insert(self.errors, { ctx = self:ctxName(ctx), message = msg, traceback = traceback or "" })
	if self.echo then
		print(string.format("[ERROR %s] %s\n%s", self:ctxName(ctx), msg, traceback or ""))
	end
end

function Scheduler:recordWarning(ctx: Ctx?, message: string)
	table.insert(self.warnings, { ctx = self:ctxName(ctx), message = message })
	if self.echo then
		print(string.format("[WARN %s] %s", self:ctxName(ctx), message))
	end
end

function Scheduler:recordGap(what: string)
	if not self.gapSet[what] then
		self.gapSet[what] = true
		table.insert(self.gaps, what)
		if self.echo then
			print("[GAP] " .. what)
		end
	end
end

-- Wraps a function so its errors are recorded with a full traceback.
function Scheduler:wrap(fn: (...any) -> ...any): (...any) -> ()
	return function(...)
		local ctx = self.current
		local ok, err = xpcall(fn, function(e)
			return { e = e, tb = debug.traceback(tostring(e), 2) }
		end, ...)
		if not ok then
			if type(err) == "table" and err.tb then
				self:recordError(ctx, err.e, err.tb)
			else
				self:recordError(ctx, err, nil)
			end
		end
	end
end

function Scheduler:newThread(fn: (...any) -> ...any, ctx: Ctx?): thread
	local co = coroutine.create(self:wrap(fn))
	self.threadCtx[co] = ctx
	return co
end

function Scheduler:ctxOf(co: thread): Ctx?
	return self.threadCtx[co]
end

-- Resumes a suspended thread in its own context.
function Scheduler:resume(co: thread, ...: any)
	if self.cancelled[co] or coroutine.status(co) ~= "suspended" then
		return
	end
	local ctx = self.threadCtx[co]
	if ctx and ctx.dead then
		return
	end
	local prev = self.current
	self.current = ctx
	local ok, err = coroutine.resume(co, ...)
	self.current = prev
	if not ok then
		self:recordError(ctx, err, debug.traceback(co))
	end
end

function Scheduler:schedule(co: thread, at: number, ...: any)
	self.seq += 1
	heapPush(self.timers, { at = at, seq = self.seq, co = co, args = table.pack(...) })
end

function Scheduler:defer(co: thread, ...: any)
	table.insert(self.deferred, { co = co, args = table.pack(...) })
end

-- Runs fn(...) in ctx: immediately ("Immediate") or at the next resumption point.
function Scheduler:dispatch(fn: (...any) -> ...any, ctx: Ctx?, deferred: boolean, ...: any)
	local co = self:newThread(fn, ctx)
	if deferred then
		self:defer(co, ...)
	else
		self:resume(co, ...)
	end
end

function Scheduler:flushDeferred()
	local guard = 0
	while #self.deferred > 0 do
		guard += 1
		if guard > 100000 then
			self:recordError(nil, "deferred queue did not drain (re-entrancy loop)", nil)
			self.deferred = {}
			return
		end
		local q = self.deferred
		self.deferred = {}
		for _, item in q do
			self:resume(item.co, table.unpack(item.args, 1, item.args.n))
		end
	end
end

-- task library ------------------------------------------------------------------------

function Scheduler:makeTask()
	local s = self
	local task = {}

	local function toThread(f: any): thread
		if type(f) == "thread" then
			if s.threadCtx[f] == nil then
				s.threadCtx[f] = s.current
			end
			return f
		end
		if type(f) ~= "function" then
			error("invalid argument #1 to 'task' function (function or thread expected)", 3)
		end
		return s:newThread(f, s.current)
	end

	function task.spawn(f: any, ...: any): thread
		local co = toThread(f)
		s:resume(co, ...)
		return co
	end

	function task.defer(f: any, ...: any): thread
		local co = toThread(f)
		s:defer(co, ...)
		return co
	end

	function task.delay(t: number?, f: any, ...: any): thread
		local co = toThread(f)
		local d = tonumber(t) or 0
		if d ~= d then
			d = 0
		end
		s:schedule(co, s.now + math.max(d, 0), ...)
		return co
	end

	function task.wait(t: number?): number
		local co, isMain = coroutine.running()
		if isMain or not coroutine.isyieldable() then
			error("attempt to yield across metamethod/C-call boundary (task.wait outside a script thread)", 2)
		end
		if s.threadCtx[co] == nil then
			s.threadCtx[co] = s.current
		end
		local d = tonumber(t) or 0
		if d ~= d then
			d = 0
		end
		local start = s.now
		s:schedule(co, s.now + math.max(d, 0), "__wait")
		coroutine.yield()
		return s.now - start
	end

	function task.cancel(co: thread)
		if type(co) ~= "thread" then
			error("invalid argument #1 to 'cancel' (thread expected)", 2)
		end
		s.cancelled[co] = true
		if coroutine.status(co) == "suspended" then
			pcall(coroutine.close, co)
		end
	end

	function task.synchronize() end
	function task.desynchronize() end

	return table.freeze(task)
end

-- Yields the running thread until resumed by someone else (signals, WaitForChild).
function Scheduler:yieldCurrent(what: string): ...any
	local co, isMain = coroutine.running()
	if isMain or not coroutine.isyieldable() then
		error(what .. " cannot yield here (called outside a script thread)", 3)
	end
	if self.threadCtx[co] == nil then
		self.threadCtx[co] = self.current
	end
	return coroutine.yield()
end

-- One frame: advance virtual time, run frame hooks (RunService events, network),
-- then resume every timer that is due.
function Scheduler:step()
	self:flushDeferred()
	self.frame += 1
	self.now += self.dt
	for _, hook in self.frameHooks do
		hook(self.dt, "pre")
	end
	self:flushDeferred()
	-- timers scheduled while this loop runs (e.g. task.wait() = 0) wait for the next frame
	local frameSeq = self.seq
	while true do
		local top = self.timers[1]
		if not top or top.at > self.now + 1e-9 or top.seq > frameSeq then
			break
		end
		heapPop(self.timers)
		local args = top.args
		if args.n == 1 and args[1] == "__wait" then
			self:resume(top.co)
		else
			self:resume(top.co, table.unpack(args, 1, args.n))
		end
		self:flushDeferred()
	end
	for _, hook in self.frameHooks do
		hook(self.dt, "post")
	end
	self:flushDeferred()
end

function Scheduler:advance(seconds: number)
	local target = self.now + seconds
	while self.now + 1e-9 < target do
		self:step()
	end
end

-- Steps until pred() is true or `timeout` virtual seconds pass. Returns pred's result.
function Scheduler:runUntil(pred: () -> any, timeout: number, every: number?): any
	local deadline = self.now + timeout
	local n = 0
	while self.now < deadline do
		local v = pred()
		if v then
			return v
		end
		self:step()
		n += 1
		if every and n % every == 0 then
			print(string.format("  … t=%.1f", self.now))
		end
	end
	return pred()
end

return Scheduler
