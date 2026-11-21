--!strict
-- Settings panel (iteration 5 Phase B #3): Effects (Full / Reduced / Off) and
-- Decor (Full / Low), applied live (State.setGfx -> State "gfx": FxController
-- drives Visuals/Particles + Juice, CameraController drives DetailLevel +
-- GroundScatter) and saved with SetSetting("fx" | "decor", value).
-- Opened from the lobby bar's ⚙ button (LobbyUI) and the in-run ⚙ on the
-- damage meter strip (MeterUI): SettingsUI.open() / close() / toggle().

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local GfxSettings = require(Client.Util.GfxSettings)
local State = require(Client.Controllers.State)

local SettingsUI = {}

local C = Theme.C
local make = Theme.make

local screen: any = nil
local modal: Frame? = nil
local unsubs: { () -> () } = {}
local render: () -> () = function() end

function SettingsUI.open()
	if modal then
		modal.Visible = true
		Theme.popIn(modal)
		render()
	end
end

function SettingsUI.close()
	if modal then
		modal.Visible = false
	end
end

function SettingsUI.toggle()
	if modal and modal.Visible then
		SettingsUI.close()
	else
		SettingsUI.open()
	end
end

function SettingsUI.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallSettings", 40)
	local touch = Theme.TOUCH
	local rowH = math.max(84, touch + 36)
	local y0 = math.max(52, touch + 12)
	local W, H = 520, y0 + 2 * rowH + 24
	local m = Theme.panel({
		Name = "Settings",
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
		Text = "⚙ Settings",
		Parent = m,
	})
	Theme.header(title)
	Theme.button("✕", C.red, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		Size = UDim2.fromOffset(touch, touch),
		TextColor3 = C.white,
		Parent = m,
	}, SettingsUI.close)

	type Row = {
		key: string,
		values: { string },
		labels: { [string]: string },
		buttons: { [string]: TextButton },
	}
	local rows: { Row } = {}
	local function row(
		y: number,
		key: string,
		name: string,
		sub: string,
		values: { string },
		labels: { [string]: string }
	)
		local f = make("Frame", {
			Position = UDim2.fromOffset(14, y),
			Size = UDim2.new(1, -28, 0, rowH),
			BackgroundColor3 = C.cream,
			Parent = m,
		})
		Theme.corner(10).Parent = f
		Theme.stroke(C.brown, 2).Parent = f
		Theme.skinCard(f)
		Theme.label({
			Position = UDim2.fromOffset(10, 4),
			Size = UDim2.new(1, -20, 0, 22),
			TextSize = 18,
			TextColor3 = C.ink,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = name,
			Parent = f,
		})
		Theme.label({
			Position = UDim2.fromOffset(10, 26),
			Size = UDim2.new(1, -20, 0, 16),
			TextSize = 12,
			Font = Theme.FONT_BODY,
			TextColor3 = C.brown,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = sub,
			Parent = f,
		})
		local holder = make("Frame", {
			Position = UDim2.fromOffset(10, 46),
			Size = UDim2.new(1, -20, 1, -52),
			BackgroundTransparency = 1,
			Parent = f,
		})
		Theme.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left).Parent = holder
		local r: Row = { key = key, values = values, labels = labels, buttons = {} }
		for i, v in values do
			r.buttons[v] = Theme.pill(labels[v] or v, C.creamDark, {
				LayoutOrder = i,
				Size = UDim2.new(1 / #values, -8, 1, 0),
				TextSize = 16,
				Parent = holder,
			}, function()
				State.setGfx(key, v)
			end)
		end
		table.insert(rows, r)
	end
	row(
		y0,
		"fx",
		"✨ Effects",
		"Particles and pops. Danger zones always show.",
		GfxSettings.FX,
		GfxSettings.FX_LABEL
	)
	row(
		y0 + rowH + 10,
		"decor",
		"🌿 Decor",
		"Floor scatter and props. Low runs faster.",
		GfxSettings.DECOR,
		GfxSettings.DECOR_LABEL
	)

	render = function()
		local g = State.gfx()
		for _, r in rows do
			local cur = (g :: any)[r.key]
			for v, b in r.buttons do
				b.BackgroundColor3 = if v == cur then C.cheese else C.creamDark
				b.Text = (if v == cur then "✔ " else "") .. (r.labels[v] or v)
			end
		end
	end
	table.insert(unsubs, State.subscribe("gfx", render, true))
	table.insert(unsubs, State.subscribe("profile", render))
end

function SettingsUI.destroy()
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

return SettingsUI
