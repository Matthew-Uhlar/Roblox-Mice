--!strict
-- Controls panel (iteration 8 §C, team Client), opened from Settings (⌨ Controls):
--   * Phone smart-cast On / Off (Util/SmartCast; saved as settings.smartCast).
--   * Keyboard keybinds for every remappable action (Util/Keybinds over Shared
--     Data/Settings BIND_ACTIONS): tap a key button, then press the new key
--     (Backspace or Cancel cancels; QC: Escape belongs to the Roblox menu). While
--     capturing, a top-priority ContextActionService sink swallows every key so
--     Space / Tab / ... don't also cast or open things. A key another action uses swaps the two, so binds never
--     conflict; a key that can't be bound shows why. "Reset to defaults" clears.
--     Saved with SetSetting("binds", <compact string>) through State.setBinds.
-- ControlsUI.open() / close() / toggle().

local ContextActionService = game:GetService("ContextActionService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Keybinds = require(Client.Util.Keybinds)
local State = require(Client.Controllers.State)

local ControlsUI = {}

local C = Theme.C
local make = Theme.make

local screen: any = nil
local modal: Frame? = nil
local unsubs: { () -> () } = {}
local render: () -> () = function() end
local capturing: string? = nil
local note = ""
local ACTION_CAPTURE = "TrunkfallBindCapture"
local CAPTURE_PRIORITY = Enum.ContextActionPriority.High.Value + 1000
local stopCapture: () -> () = function() end

function ControlsUI.open()
	if modal then
		modal.Visible = true
		Theme.popIn(modal)
		render()
	end
end

function ControlsUI.close()
	stopCapture()
	if modal then
		modal.Visible = false
	end
end

function ControlsUI.toggle()
	if modal and modal.Visible then
		ControlsUI.close()
	else
		ControlsUI.open()
	end
end

function ControlsUI.init()
	if screen then
		return
	end
	local cfg = State.bindsCfg()
	screen = Theme.screen("TrunkfallControls", 41)
	local touch = Theme.TOUCH
	local W, H = 560, 620
	local m = Theme.panel({
		Name = "Controls",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(W, H),
		Visible = false,
		Parent = screen.root,
	})
	table.insert(unsubs, Theme.fitFrame(screen, m, W, H, 10))
	modal = m
	local title = Theme.label({
		Position = UDim2.fromOffset(16, 6),
		Size = UDim2.new(1, -(touch + 40), 0, 38),
		TextSize = 26,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "⌨ Controls",
		Parent = m,
	})
	Theme.header(title)
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		Size = UDim2.fromOffset(touch, touch),
		TextColor3 = C.white,
		Parent = m,
	}, ControlsUI.close)

	local top = math.max(52, touch + 12)
	-- smart-cast row
	local smart = make("Frame", {
		Position = UDim2.fromOffset(14, top),
		Size = UDim2.new(1, -28, 0, touch + 12),
		BackgroundColor3 = C.cream,
		Parent = m,
	})
	Theme.corner(10).Parent = smart
	Theme.label({
		Position = UDim2.fromOffset(10, 2),
		Size = UDim2.new(1, -150, 0, 24),
		TextSize = 18,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "📱 Smart-cast (phones)",
		Parent = smart,
	})
	Theme.label({
		Position = UDim2.fromOffset(10, 26),
		Size = UDim2.new(1, -150, 0, 20),
		TextSize = 14,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "Ability 1 casts itself at the nearest mouse. Off near rival heroes.",
		Parent = smart,
	})
	local smartBtn = Theme.pill("Off", C.creamDark, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(120, touch),
		TextSize = 16,
		Parent = smart,
	}, function()
		local ok, f = pcall(State.feel)
		State.setFeel("smartCast", not (ok and type(f) == "table" and f.smartCast == true))
	end)

	-- key capture (QC iteration 8): a top-priority sink on every keyboard key
	local function onCapture(
		_n: string,
		st: Enum.UserInputState,
		input: InputObject
	): Enum.ContextActionResult
		local action = capturing
		if st ~= Enum.UserInputState.Begin or not action or not cfg then
			return Enum.ContextActionResult.Sink
		end
		stopCapture()
		local name = input.KeyCode.Name
		if input.KeyCode == Enum.KeyCode.Backspace then
			note = ""
		else
			local map, swapped, why = Keybinds.assign(cfg, State.binds(), action, name)
			note = if why
				then Keybinds.keyLabel(name) .. " " .. why .. "."
				elseif swapped then string.format(
					"%s took %s; %s moved to %s.",
					Keybinds.LABEL[action] or action,
					Keybinds.keyLabel(name),
					Keybinds.LABEL[swapped] or swapped,
					Keybinds.keyLabel(map[swapped])
				)
				else ""
			if not why then
				State.setBinds(map)
			end
		end
		render()
		return Enum.ContextActionResult.Sink
	end
	local function startCapture(action: string)
		capturing = action
		ContextActionService:UnbindAction(ACTION_CAPTURE)
		ContextActionService:BindActionAtPriority(
			ACTION_CAPTURE,
			onCapture,
			false,
			CAPTURE_PRIORITY,
			Enum.UserInputType.Keyboard
		)
	end
	stopCapture = function()
		capturing = nil
		ContextActionService:UnbindAction(ACTION_CAPTURE)
	end

	-- keybind list
	local listTop = top + touch + 24
	local hint = Theme.label({
		Position = UDim2.fromOffset(16, listTop),
		Size = UDim2.new(1, -32, 0, 20),
		TextSize = 14,
		Font = Theme.FONT_BODY,
		TextColor3 = C.brown,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
		Parent = m,
	})
	local scroll = Theme.scroller({
		Position = UDim2.fromOffset(14, listTop + 24),
		Size = UDim2.new(1, -28, 1, -(listTop + 24 + touch + 20)),
		Parent = m,
	})
	Theme.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = scroll
	type Row = { action: string, key: TextButton, frame: Frame }
	local rows: { Row } = {}
	for i, action in (if cfg then cfg.BIND_ACTIONS else {}) :: { string } do
		local f = make("Frame", {
			LayoutOrder = i,
			Size = UDim2.new(1, -14, 0, touch),
			BackgroundColor3 = C.cream,
			Parent = scroll,
		}) :: Frame
		Theme.corner(8).Parent = f
		Theme.label({
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.new(1, -170, 1, 0),
			TextSize = 16,
			TextColor3 = C.ink,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Text = Keybinds.LABEL[action] or action,
			Parent = f,
		})
		local keyBtn = Theme.pill("?", C.creamDark, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0),
			Size = UDim2.fromOffset(150, touch - 6),
			TextSize = 16,
			Parent = f,
		}, function()
			note = ""
			if capturing == action then
				stopCapture()
			else
				startCapture(action)
			end
			render()
		end)
		table.insert(rows, { action = action, key = keyBtn, frame = f })
	end
	local cancelBtn = Theme.button("Cancel", C.creamDark, {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -14, 1, -10),
		Size = UDim2.fromOffset(140, touch),
		TextSize = 16,
		Visible = false,
		Parent = m,
	}, function()
		stopCapture()
		note = ""
		render()
	end)
	Theme.button("Reset to defaults", C.creamDark, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -10),
		Size = UDim2.fromOffset(220, touch),
		TextSize = 16,
		Parent = m,
	}, function()
		stopCapture()
		note = "Keys reset to the defaults."
		State.setBinds(nil)
	end)

	render = function()
		local ok, f = pcall(State.feel)
		local on = ok and type(f) == "table" and f.smartCast == true
		cancelBtn.Visible = capturing ~= nil
		smartBtn.Text = if on then "✔ On" else "Off"
		smartBtn.BackgroundColor3 = if on then C.cheese else C.creamDark
		local map = State.binds()
		local clash = if cfg then Keybinds.conflicts(cfg, map) else {}
		for _, r in rows do
			local cur = map[r.action]
			if capturing == r.action then
				r.key.Text = "Press a key…"
				r.key.BackgroundColor3 = C.orange
			else
				r.key.Text = Keybinds.keyLabel(cur) .. (if clash[r.action] then " ⚠" else "")
				r.key.BackgroundColor3 = if clash[r.action] then C.red else C.creamDark
			end
		end
		hint.Text = if note ~= ""
			then note
			elseif capturing then "Press the new key (Backspace or Cancel stops). A key in use swaps."
			else "Tap a key to change it. Gamepad buttons stay fixed."
	end

	table.insert(unsubs, function()
		stopCapture()
	end)
	table.insert(unsubs, State.subscribe("feel", render))
	table.insert(unsubs, State.onBinds(render))
end

function ControlsUI.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	if screen then
		screen.destroy()
		screen = nil
	end
	modal = nil
end

return ControlsUI
