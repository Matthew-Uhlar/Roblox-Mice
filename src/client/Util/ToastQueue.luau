--!strict
-- Pure toast priority model (iteration 1 #13: P-7, C-8). No Roblox APIs;
-- specs run it in Lune (tests/specs/ClientIter1.spec.luau).
--
-- Classes:
--   critical  downs, revives, the Melt, the Rind Gate, champions, the boss.
--             Never dropped; may evict a waiting info toast.
--   reward    cheese, gear, level-ups (level-ups coalesce: "Level 9 → 13").
--   info      everything else. Rate-limited (1 per INFO_GAP s); extras merge
--             into one "+N more" line.
--   meta      Mousepedia, achievements, contracts, pass tiers. Held during a
--             run and released in the lobby / on Results as one summary line.
-- A server `kind` of "critical" / "bad" maps to critical, "reward" / "good" to
-- reward, "meta" to meta; "info" falls back to the text rules below.
-- While a STAGE CLEAR banner is up (`absorbing`), boss / chest / blessing /
-- Epic lines join the banner instead of stacking as toasts.

local ToastQueue = {}
ToastQueue.__index = ToastQueue

ToastQueue.MAX_QUEUED = 8
ToastQueue.INFO_GAP = 1.2

local CRITICAL = {
	"down",
	"revive",
	"melt",
	"storm",
	"gate",
	"champion",
	"boss",
	"eliminated",
	"bounty",
	"herd call",
	"extract",
}
local META = {
	"mousepedia",
	"achievement",
	"contract",
	"herd pass",
	"pass tier",
	"discovered",
	"new entry",
	"title unlocked",
	"pressure unlocked",
}
local REWARD = { "level", "gear", "cheese", "🧀", "golden", "✨", "epic", "legendary", "xp" }
local BANNER = { "boss", "chest", "blessing", "epic", "stage clear", "slain", "defeated" }

local function has(text: string, words: { string }): boolean
	local l = string.lower(text)
	for _, w in words do
		if string.find(l, w, 1, true) then
			return true
		end
	end
	return false
end

function ToastQueue.classify(text: string, kind: string?): string
	local k = string.lower(kind or "info")
	if k == "critical" or k == "bad" then
		return "critical"
	elseif k == "meta" then
		return "meta"
	end
	if has(text, META) then
		return "meta"
	end
	if has(text, CRITICAL) then
		return "critical"
	end
	if k == "reward" or k == "good" or has(text, REWARD) then
		return "reward"
	end
	return "info"
end

-- "Level up! You are now level 13" / "Level 13" -> 13
function ToastQueue.levelOf(text: string): number?
	local l = string.lower(text)
	if not string.find(l, "level", 1, true) then
		return nil
	end
	local n = string.match(l, "level%D*(%d+)")
	return if n then tonumber(n) else nil
end

export type Entry = { text: string, kind: string, class: string, count: number, level0: number? }

export type Queue = typeof(setmetatable(
	{} :: {
		queue: { Entry },
		held: { string },
		lastInfoAt: number,
		absorbing: boolean,
		absorbed: { string },
		overflow: number,
	},
	ToastQueue
))

function ToastQueue.new(): Queue
	return setmetatable({
		queue = {},
		held = {},
		lastInfoAt = -math.huge,
		absorbing = false,
		absorbed = {},
		overflow = 0,
	}, ToastQueue)
end

-- Adds a toast. `inRun` holds meta lines until the run ends.
-- Returns "queued" | "merged" | "held" | "banner" | "dropped".
function ToastQueue.push(self: Queue, text: string, kind: string?, inRun: boolean?): string
	local class = ToastQueue.classify(text, kind)
	if class == "meta" and inRun then
		table.insert(self.held, text)
		return "held"
	end
	if self.absorbing and class ~= "critical" and has(text, BANNER) then
		table.insert(self.absorbed, text)
		return "banner"
	end
	if self.absorbing and class == "critical" and has(text, { "boss", "chest", "slain", "defeated" }) then
		table.insert(self.absorbed, text)
		return "banner"
	end
	-- coalesce level-ups into one "Level a → b" entry
	local lv = ToastQueue.levelOf(text)
	if lv then
		for _, e in self.queue do
			if e.level0 then
				e.text = string.format("⬆ Level %d → %d", e.level0, lv)
				e.count += 1
				return "merged"
			end
		end
	end
	for _, e in self.queue do
		if e.text == text then
			e.count += 1
			return "merged"
		end
	end
	local entry: Entry = {
		text = text,
		kind = if class == "critical" then "bad" elseif class == "reward" then "good" else "info",
		class = class,
		count = 1,
		level0 = if lv then lv - 1 else nil,
	}
	if lv then
		entry.text = string.format("⬆ Level %d", lv)
	end
	if #self.queue >= ToastQueue.MAX_QUEUED then
		-- evict the oldest info, else the oldest reward; criticals stay
		local evicted = false
		for _, cls in { "info", "reward" } do
			for i, e in self.queue do
				if e.class == cls then
					table.remove(self.queue, i)
					self.overflow += 1
					evicted = true
					break
				end
			end
			if evicted then
				break
			end
		end
		if not evicted and class ~= "critical" then
			self.overflow += 1
			return "dropped"
		end
	end
	if class == "critical" then
		-- criticals jump ahead of every non-critical entry
		local at = #self.queue + 1
		for i, e in self.queue do
			if e.class ~= "critical" then
				at = i
				break
			end
		end
		table.insert(self.queue, at, entry)
	else
		table.insert(self.queue, entry)
	end
	return "queued"
end

-- Next entry to show at `now`, or nil. Info toasts wait INFO_GAP apart; when
-- several infos pile up behind the gap, they are merged into one line.
function ToastQueue.pop(self: Queue, now: number): Entry?
	for i, e in self.queue do
		if e.class ~= "info" then
			table.remove(self.queue, i)
			return e
		end
	end
	local first = self.queue[1]
	if not first then
		return nil
	end
	if now - self.lastInfoAt < ToastQueue.INFO_GAP then
		return nil
	end
	table.remove(self.queue, 1)
	local more = #self.queue + self.overflow
	if more > 2 then
		-- merge the rest of the info backlog into the line shown now
		for i = #self.queue, 1, -1 do
			if self.queue[i].class == "info" then
				table.remove(self.queue, i)
			end
		end
		first = {
			text = first.text .. string.format("  (+%d more)", more),
			kind = first.kind,
			class = first.class,
			count = first.count,
		}
		self.overflow = 0
	end
	self.lastInfoAt = now
	return first
end

-- The held meta lines as one summary (and clears them), or nil.
function ToastQueue.flushHeld(self: Queue): string?
	local n = #self.held
	if n == 0 then
		return nil
	end
	local text = if n == 1 then self.held[1] else string.format("📖 +%d new: %s, and more", n, self.held[1])
	table.clear(self.held)
	return text
end

-- STAGE CLEAR banner: start absorbing boss / chest lines; `stop` returns them.
function ToastQueue.beginBanner(self: Queue)
	self.absorbing = true
	table.clear(self.absorbed)
end

function ToastQueue.endBanner(self: Queue): { string }
	self.absorbing = false
	local out = table.clone(self.absorbed)
	table.clear(self.absorbed)
	return out
end

return ToastQueue
