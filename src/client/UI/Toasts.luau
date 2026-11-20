--!strict
-- Net.S2C.Toast queue with priorities (iteration 1 #13: P-7, C-8). Small
-- toasts stack top-centre under the run header, at most 3 on screen, each
-- ~2.4 s. The order and merging come from Util/ToastQueue:
--   critical (downs, Melt, gate, champions, boss) jump the line and are never
--   dropped; rewards next; info is rate-limited and merged ("+N more");
--   meta lines (Mousepedia, achievements, contracts) wait for the lobby or
--   Results and show as one summary line.
-- A repeat of a toast on screen merges into it ("×2", timer refreshed).
--
-- STAGE CLEAR banner: when the stage's boss falls (Fx t = "stageClear", or
-- Toasts.banner from other UIs), one big banner shows for BANNER_SECONDS and
-- the boss / chest / blessing / Epic toasts of that moment become its lines.

local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local UiSizes = require(Client.Util.UiSizes)
local ToastQueue = require(Client.Util.ToastQueue)
local Progression = require(Client.Util.Progression)
local Remotes = require(Client.Util.Remotes)
local State = require(Client.Controllers.State)

local Toasts = {}

local BANNER_SECONDS = 3.6
local BANNER_ABSORB = 2.5 -- seconds after the kill during which boss toasts join the banner

local KIND_COLOR: { [string]: Color3 } = {
	info = Theme.C.cream,
	good = Color3.fromRGB(190, 240, 170),
	bad = Color3.fromRGB(255, 190, 175),
}
local CLASS_ICON: { [string]: string } = { info = "🧀", reward = "✨", critical = "⚠️", meta = "📖" }

type Live = {
	text: string,
	kind: string,
	class: string,
	label: TextLabel,
	frame: Frame,
	count: number,
	token: number,
}

local screen: any = nil
local holder: Frame? = nil
local q = ToastQueue.new()
local live: { Live } = {}
local seq = 0
local conns: { any } = {}
local sizes = UiSizes.toast(false)
local bannerFrame: Frame? = nil
local bannerTitle: TextLabel? = nil
local bannerLines: TextLabel? = nil
local bannerToken = 0
local lastBannerHead: string? = nil

local pump: () -> ()

local function caption(t: Live): string
	local icon = CLASS_ICON[t.class] or "🧀"
	if string.find(t.text, "^[^%w%s]") then
		icon = "" -- the text brings its own icon
	end
	return (if icon ~= "" then icon .. " " else "")
		.. t.text
		.. (if t.count > 1 then "  ×" .. t.count else "")
end

local function expire(t: Live, token: number)
	task.delay(sizes.seconds + (if t.class == "critical" then 0.6 else 0), function()
		if t.token ~= token then
			return -- merged again: a fresh timer owns it
		end
		local idx = table.find(live, t)
		if idx then
			table.remove(live, idx)
		end
		if t.frame.Parent then
			TweenService:Create(t.label, TweenInfo.new(0.2), { TextTransparency = 1 }):Play()
			TweenService:Create(t.frame, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
			task.wait(0.22)
			t.frame:Destroy()
		end
		pump()
	end)
end

local function show(e: ToastQueue.Entry)
	local h = holder
	if not h then
		return
	end
	seq += 1
	local frame = Theme.card({
		LayoutOrder = if e.class == "critical" then -seq else seq,
		BackgroundTransparency = 0.12,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromOffset(sizes.w, 0),
		Parent = h,
	}, {
		shadow = false,
		accent = if e.class == "critical"
			then Theme.C.red
			elseif e.class == "reward" then Theme.C.green
			else nil,
		stroke = if e.class == "critical" then 2.5 else 1.5,
	})
	Theme.padding(sizes.padX, sizes.padY).Parent = frame
	local label = Theme.label({
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, sizes.lineH),
		TextSize = sizes.text,
		TextColor3 = KIND_COLOR[e.kind] or Theme.C.cream,
		Text = "",
		Parent = frame,
	})
	Theme.textStroke(Theme.C.shade, 1).Parent = label
	local t: Live = {
		text = e.text,
		kind = e.kind,
		class = e.class,
		label = label,
		frame = frame,
		count = e.count,
		token = 0,
	}
	label.Text = caption(t)
	table.insert(live, t)
	Theme.popIn(frame)
	t.token += 1
	expire(t, t.token)
end

pump = function()
	while #live < sizes.maxVisible do
		local e = q:pop(os.clock())
		if not e then
			break
		end
		show(e)
	end
	-- a critical toast may take the slot of the oldest info toast on screen
	if #live >= sizes.maxVisible then
		local nextE = q.queue[1]
		if nextE and nextE.class == "critical" then
			for i, t in live do
				if t.class == "info" then
					table.remove(live, i)
					t.token += 1
					t.frame:Destroy()
					local e = q:pop(os.clock())
					if e then
						show(e)
					end
					break
				end
			end
		end
	end
end

local function inRun(): boolean
	local ph = State.phase()
	return ph ~= nil and ph ~= "Lobby" and ph ~= "Results"
end

local suppressLevelUntil = 0 -- T-14: no "⬆ Level 1" right after a Prestige

function Toasts.push(text: string, kind: string?)
	if os.clock() < suppressLevelUntil and ToastQueue.levelOf(text) ~= nil then
		return
	end
	-- H5: no "Pressure unlocked!" for rookies (runs 0-2); the server gates it too.
	if
		string.find(string.lower(text), "pressure unlocked", 1, true)
		and Progression.isRookie(State.get("profile"))
	then
		return
	end
	-- Same text already on screen: merge ("×2") and keep it up a bit longer.
	for _, t in live do
		if t.text == text then
			t.count += 1
			t.label.Text = caption(t)
			Theme.popIn(t.frame)
			t.token += 1
			expire(t, t.token)
			return
		end
	end
	local res = q:push(text, kind, inRun())
	if res == "banner" then
		local l = bannerLines
		if l and bannerFrame and bannerFrame.Visible then
			local lines = {}
			if lastBannerHead then
				table.insert(lines, lastBannerHead)
			end
			for _, s in q.absorbed do
				table.insert(lines, s)
				if #lines >= 3 then
					break
				end
			end
			l.Text = table.concat(lines, "\n")
		end
		return
	end
	pump()
end

-- One big banner (STAGE CLEAR, or another title). `lines` are short subtitles.
function Toasts.banner(title: string, lines: { string }?)
	local f, tl, ll = bannerFrame, bannerTitle, bannerLines
	if not (f and tl and ll) then
		return
	end
	bannerToken += 1
	local my = bannerToken
	q:beginBanner()
	tl.Text = title
	lastBannerHead = if lines then lines[1] else nil
	ll.Text = if lines then table.concat(lines, "\n") else ""
	f.Visible = true
	Theme.popIn(f)
	task.delay(BANNER_ABSORB, function()
		if bannerToken == my then
			q:endBanner()
		end
	end)
	task.delay(BANNER_SECONDS, function()
		if bannerToken == my then
			f.Visible = false
			pump()
		end
	end)
end

-- Number of toasts on screen (tests).
function Toasts.visibleCount(): number
	return #live
end

function Toasts.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallToasts", 40)
	local dense = Theme.dense()
	sizes = UiSizes.toast(dense)
	local h = Theme.make("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		-- top-centre, under the HUD header (strip + rows + boss bar + banner)
		Position = UDim2.new(0.5, 0, 0, UiSizes.toastTop(dense, Theme.TOUCH, Theme.SLIM)),
		Size = UDim2.fromOffset(sizes.w, sizes.maxVisible * (2 * sizes.lineH + 2 * sizes.padY + sizes.gap)),
		Parent = screen.root,
	})
	Theme.list(Enum.FillDirection.Vertical, sizes.gap).Parent = h
	holder = h

	-- STAGE CLEAR banner (upper third, under the header)
	local bw = if dense then 460 else 560
	local f = Theme.make("Frame", {
		Name = "StageBanner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.3),
		Size = UDim2.fromOffset(bw, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 5,
		Parent = screen.root,
	}) :: Frame
	Theme.list(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Center).Parent = f
	local tl = Theme.label({
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, if dense then 52 else 60),
		TextSize = if dense then 46 else 54,
		TextColor3 = Theme.C.cheese,
		Text = "STAGE CLEAR!",
		ZIndex = 5,
		Parent = f,
	})
	Theme.textStroke(Theme.C.brownDark, 3).Parent = tl
	local ll = Theme.label({
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextSize = if dense then 16 else 18,
		TextColor3 = Theme.C.cream,
		Text = "",
		ZIndex = 5,
		Parent = f,
	})
	Theme.textStroke(Theme.C.shade, 1.5).Parent = ll
	bannerFrame, bannerTitle, bannerLines = f, tl, ll

	table.insert(
		conns,
		State.toast:Connect(function(text: string, kind: string)
			Toasts.push(text, kind)
		end)
	)
	-- the stage's boss falls: one banner instead of a toast stack
	table.insert(
		conns,
		Remotes.on(Remotes.S2C.Fx, function(batch)
			if type(batch) ~= "table" then
				return
			end
			for _, ev in batch do
				-- M2's per-squad `stageClear` (the World's `clear` also fires from
				-- clearEnemies() before a boss spawns, so it is not used here)
				if type(ev) == "table" and ev.t == "stageClear" then
					local title, lines = ToastQueue.stageClear(ev)
					Toasts.banner(title, lines)
					break
				end
			end
		end)
	)
	-- T-14: a Prestige gets one big banner (the server's Prestige toast joins it)
	local prestigeSeen: { [string]: number }? = nil
	local ascSeen: { [string]: number } = {}
	table.insert(
		conns,
		State.subscribe("profile", function(p)
			local cl = type(p) == "table" and p.classes
			if type(cl) ~= "table" then
				return
			end
			local first = prestigeSeen == nil
			local seen: { [string]: number } = prestigeSeen or {}
			prestigeSeen = seen
			for id, c in cl do
				if type(c) == "table" then
					local n = math.floor(tonumber(c.prestige) or 0)
					local asc = type(c.ascension) == "table" and tonumber(c.ascension.nodes) or 0
					local before = seen[id]
					local ascBefore = ascSeen[id] or asc
					seen[id] = n
					ascSeen[id] = asc
					if not first and before ~= nil and n > before then
						suppressLevelUntil = os.clock() + 5
						local title, lines = ToastQueue.prestige(n, if asc > ascBefore then asc else nil)
						Toasts.banner(title, lines)
					end
				end
			end
		end)
	)
	-- held meta lines (Mousepedia, achievements, contracts) show once the run ends
	table.insert(
		conns,
		State.subscribe("run", function()
			if not inRun() then
				local s = q:flushHeld()
				if s then
					q:push(s, "info", false)
					pump()
				end
			end
		end)
	)
	-- info toasts wait out their rate limit: keep pumping
	table.insert(
		conns,
		task.spawn(function()
			while screen do
				task.wait(0.4)
				if #q.queue > 0 then
					pump()
				end
			end
		end)
	)
end

function Toasts.destroy()
	for _, c in conns do
		if typeof(c) == "RBXScriptConnection" or (type(c) == "table" and c.Disconnect) then
			c:Disconnect()
		elseif typeof(c) == "thread" then
			pcall(task.cancel, c)
		elseif type(c) == "function" then
			c()
		end
	end
	table.clear(conns)
	if screen then
		screen.destroy()
		screen = nil
	end
	holder = nil
	bannerFrame = nil
	q = ToastQueue.new()
	table.clear(live)
end

return Toasts
