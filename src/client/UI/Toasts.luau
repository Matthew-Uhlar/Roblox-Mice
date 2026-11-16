--!strict
-- Net.S2C.Toast queue (v3 compact): small toasts stacked top-centre under the
-- run header (on PC below the Extract / vote bar slots), at most 3 on screen, each ~2.4 s. A toast that repeats one
-- already on screen merges into it ("×2", timer refreshed) instead of
-- stacking; exact duplicates waiting in the queue are dropped, and the queue
-- is capped so spam can't pile up. Sizes: Util/UiSizes.toast.

local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local UiSizes = require(Client.Util.UiSizes)
local State = require(Client.Controllers.State)

local Toasts = {}

local MAX_QUEUED = 6

local KIND_COLOR: { [string]: Color3 } = {
	info = Theme.C.cream,
	good = Color3.fromRGB(190, 240, 170),
	bad = Color3.fromRGB(255, 190, 175),
}
local KIND_ICON: { [string]: string } = { info = "🧀", good = "✨", bad = "⚠️" }

type Live = { text: string, kind: string, label: TextLabel, frame: Frame, count: number, token: number }

local screen: any = nil
local holder: Frame? = nil
local queue: { { text: string, kind: string } } = {}
local live: { Live } = {}
local seq = 0
local conn: any = nil
local sizes = UiSizes.toast(false)

local pump: () -> ()

local function caption(t: Live): string
	return (KIND_ICON[t.kind] or "🧀") .. " " .. t.text .. (if t.count > 1 then "  ×" .. t.count else "")
end

local function expire(t: Live, token: number)
	task.delay(sizes.seconds, function()
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

local function show(text: string, kind: string)
	local h = holder
	if not h then
		return
	end
	seq += 1
	local frame = Theme.card({
		LayoutOrder = seq,
		BackgroundTransparency = 0.12,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromOffset(sizes.w, 0),
		Parent = h,
	}, {
		shadow = false,
		accent = if kind == "bad" then Theme.C.red elseif kind == "good" then Theme.C.green else nil,
		stroke = 1.5,
	})
	Theme.padding(sizes.padX, sizes.padY).Parent = frame
	local label = Theme.label({
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, sizes.lineH),
		TextSize = sizes.text,
		TextColor3 = KIND_COLOR[kind] or Theme.C.cream,
		Text = "",
		Parent = frame,
	})
	Theme.textStroke(Theme.C.shade, 1).Parent = label
	local t: Live = { text = text, kind = kind, label = label, frame = frame, count = 1, token = 0 }
	label.Text = caption(t)
	table.insert(live, t)
	Theme.popIn(frame)
	t.token += 1
	expire(t, t.token)
end

pump = function()
	while #live < sizes.maxVisible and #queue > 0 do
		local t = table.remove(queue, 1)
		if t then
			show(t.text, t.kind)
		end
	end
end

function Toasts.push(text: string, kind: string?)
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
	-- Drop exact duplicates already waiting.
	for _, q in queue do
		if q.text == text then
			return
		end
	end
	if #queue >= MAX_QUEUED then
		table.remove(queue, 1)
	end
	table.insert(queue, { text = text, kind = kind or "info" })
	pump()
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
	conn = State.toast:Connect(function(text: string, kind: string)
		Toasts.push(text, kind)
	end)
end

function Toasts.destroy()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	if screen then
		screen.destroy()
		screen = nil
	end
	holder = nil
	table.clear(queue)
	table.clear(live)
end

return Toasts
