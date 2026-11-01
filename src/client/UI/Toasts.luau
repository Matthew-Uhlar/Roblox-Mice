--!strict
-- Net.S2C.Toast queue: up to 3 stacked banners under the run header, each
-- shown ~3 s. Overflow waits in a queue (capped so spam can't pile up).

local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local State = require(Client.Controllers.State)

local Toasts = {}

local MAX_VISIBLE = 3
local MAX_QUEUED = 8
local SHOW_SECONDS = 3

local KIND_COLOR: { [string]: Color3 } = {
	info = Theme.C.cream,
	good = Color3.fromRGB(190, 240, 170),
	bad = Color3.fromRGB(255, 190, 175),
}
local KIND_ICON: { [string]: string } = { info = "🧀", good = "✨", bad = "⚠️" }

local screen: any = nil
local holder: Frame? = nil
local queue: { { text: string, kind: string } } = {}
local visible = 0
local seq = 0
local conn: any = nil

local pump: () -> ()

local function show(text: string, kind: string)
	local h = holder
	if not h then
		return
	end
	visible += 1
	seq += 1
	local frame = Theme.make("Frame", {
		LayoutOrder = seq,
		BackgroundColor3 = Theme.C.brownDark,
		BackgroundTransparency = 0.1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromOffset(460, 0),
		Parent = h,
	})
	Theme.corner(12).Parent = frame
	Theme.stroke(if kind == "bad" then Theme.C.red elseif kind == "good" then Theme.C.green else Theme.C.cheese, 3).Parent =
		frame
	Theme.padding(14, 8).Parent = frame
	local label = Theme.label({
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		TextSize = 22,
		TextColor3 = KIND_COLOR[kind] or Theme.C.cream,
		Text = (KIND_ICON[kind] or "🧀") .. " " .. text,
		Parent = frame,
	})
	Theme.popIn(frame)
	task.delay(SHOW_SECONDS, function()
		if frame.Parent then
			TweenService:Create(label, TweenInfo.new(0.25), { TextTransparency = 1 }):Play()
			TweenService:Create(frame, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
			task.wait(0.27)
			frame:Destroy()
		end
		visible -= 1
		pump()
	end)
end

pump = function()
	while visible < MAX_VISIBLE and #queue > 0 do
		local t = table.remove(queue, 1)
		if t then
			show(t.text, t.kind)
		end
	end
end

function Toasts.push(text: string, kind: string?)
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

function Toasts.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallToasts", 40)
	local h = Theme.make("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(0.5, 0, 0, 215),
		Size = UDim2.fromOffset(460, 300),
		Parent = screen.root,
	})
	Theme.list(Enum.FillDirection.Vertical, 6).Parent = h
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
	visible = 0
end

return Toasts
