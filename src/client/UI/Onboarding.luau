--!strict
-- First-session coach marks (QC2 minor 12). One small card at a time on the
-- right-middle of the screen (clear of the HUD, the thumbstick and the touch
-- ability button), with device-specific text for touch, keyboard/mouse and
-- gamepad:
--
--   move     how to move                     } first time combat starts,
--   attack   attacks are automatic           } shown one after another
--   crumbs   cheese crumbs give XP           }
--   ability  the ability button / keys       } (closes when the ability is used)
--   revive   stand near a downed teammate      first time a teammate goes down
--   pois     stand on glowing spots, avoid traps  first time a live POI is near (HudUI)
--   route    route cards (inline in VoteUI via Onboarding.claim("route"))
--
-- Who sees them: players whose profile shows no finished run yet
-- (profile.stats.runs == 0; the revive hint while runs < 3, since a revive
-- may never happen in the first run), or whose profile.settings.hints is true.
-- profile.settings.hints == false always hides them. Each hint is shown at
-- most once per session (client-side flag). After the first finished run the
-- server's run counter makes them stop for good.

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Device = require(Client.Util.Device)
local State = require(Client.Controllers.State)

local Onboarding = {}

local C = Theme.C

-- Text is looked up when shown, so it matches the input mode in use then.
type Hint = { key: string, seconds: number }

local shown: { [string]: boolean } = {}
local queue: { Hint } = {}
local current: Hint? = nil
local token = 0

local screen: any = nil
local card: Frame? = nil
local iconLabel: TextLabel? = nil
local textLabel: TextLabel? = nil
local unsubs: { () -> () } = {}

local function profileStats(): (number?, any)
	local p = State.get("profile")
	if type(p) ~= "table" then
		return nil, nil
	end
	local stats = if type(p.stats) == "table" then p.stats else {}
	local settings = if type(p.settings) == "table" then p.settings else {}
	return tonumber(stats.runs) or 0, settings
end

-- True if `key` may be shown to this player (ignores the once-per-session flag).
function Onboarding.eligible(key: string): boolean
	local runs, settings = profileStats()
	if runs == nil then
		return false -- profile not loaded: don't guess
	end
	if settings.hints == false then
		return false
	end
	if settings.hints == true then
		return true
	end
	if key == "revive" then
		return runs < 3
	end
	return runs == 0
end

-- Marks `key` as shown and returns true if it should be shown now.
function Onboarding.claim(key: string): boolean
	if shown[key] or not Onboarding.eligible(key) then
		return false
	end
	shown[key] = true
	return true
end

local function textFor(key: string): (string, string)
	local mode = Device.mode()
	if key == "move" then
		if mode == "touch" then
			return "👆", "Drag on the left side of the screen to move."
		elseif mode == "gamepad" then
			return "🎮", "Move with the left stick."
		end
		return "⌨", "Move with WASD or the arrow keys."
	elseif key == "attack" then
		return "🐘", "You attack nearby mice automatically. Keep moving and stay out of the red zones!"
	elseif key == "crumbs" then
		return "🧀", "Walk over cheese crumbs to earn XP and level up."
	elseif key == "ability" then
		if mode == "touch" then
			return "💥", "Tap the big 💥 button for your ability. Drag from it to aim."
		elseif mode == "gamepad" then
			return "💥", "Press X for your ability. The right stick aims it."
		end
		return "💥", "Space, Q or right-click uses your ability. It aims at your mouse."
	elseif key == "revive" then
		return "💫", "A teammate is down! Stand next to them to revive them."
	elseif key == "pois" then
		return "✨", "Stand on glowing spots for rewards: cheese, buffs and more. Avoid the mousetraps!"
	end
	return "🧀", ""
end

local function hideCard()
	current = nil
	token += 1
	if card then
		card.Visible = false
	end
end

local pump: () -> ()

local function showHint(h: Hint)
	local c, icon, label = card, iconLabel, textLabel
	if not (c and icon and label) then
		return
	end
	current = h
	token += 1
	local my = token
	local glyph, text = textFor(h.key)
	icon.Text = glyph
	label.Text = text
	c.Visible = true
	Theme.popIn(c)
	task.delay(h.seconds, function()
		if token == my then
			hideCard()
			task.delay(0.6, pump)
		end
	end)
end

pump = function()
	if current ~= nil or not State.inCombat() then
		return
	end
	local h = table.remove(queue, 1)
	if h then
		showHint(h)
	end
end

local function enqueue(key: string, seconds: number, urgent: boolean?)
	if not Onboarding.claim(key) then
		return
	end
	local h: Hint = { key = key, seconds = seconds }
	if urgent then
		-- Revives are time-critical: jump the queue and replace the current card.
		table.insert(queue, 1, h)
		if current then
			local cur = current :: Hint
			if cur.key ~= "revive" then
				table.insert(queue, 2, cur)
			end
			hideCard()
		end
	else
		table.insert(queue, h)
	end
	pump()
end

-- HudUI calls this the first time a live POI is near the local hero.
function Onboarding.poiSeen()
	enqueue("pois", 8)
end

-- Closes the card if it is showing `key` (e.g. the player just did the thing).
function Onboarding.done(key: string)
	shown[key] = true
	for i = #queue, 1, -1 do
		if queue[i].key == key then
			table.remove(queue, i)
		end
	end
	if current and (current :: Hint).key == key then
		hideCard()
		task.delay(0.6, pump)
	end
end

function Onboarding.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallHints", 32)
	local touch = Theme.TOUCH
	local c = Theme.panel({
		Name = "Hint",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.42, 0),
		Size = UDim2.fromOffset(400, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 0.05,
		Visible = false,
		Parent = screen.root,
	})
	Theme.padding(14, 10).Parent = c
	Theme.list(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Left).Parent = c
	local row = Theme.make("Frame", {
		LayoutOrder = 1,
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 40),
		Parent = c,
	})
	iconLabel = Theme.label({
		Size = UDim2.fromOffset(44, 44),
		TextSize = 34,
		Parent = row,
	})
	textLabel = Theme.label({
		Position = UDim2.fromOffset(52, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -52, 0, 40),
		TextSize = 20,
		Font = Theme.FONT_BODY,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})
	Theme.button("Got it ✔", C.green, {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, touch),
		TextSize = 22,
		TextColor3 = C.white,
		Parent = c,
	}, function()
		hideCard()
		task.delay(0.4, pump)
	end)
	card = c

	-- Combat start: movement, auto-attack, crumbs, then the ability.
	local lastPhase: string? = nil
	table.insert(
		unsubs,
		State.subscribe("run", function(run)
			local phase = if type(run) == "table" then run.phase else nil
			if phase == lastPhase then
				return
			end
			lastPhase = phase
			if phase == "Waves" then
				enqueue("move", 6)
				enqueue("attack", 7)
				enqueue("crumbs", 6)
				enqueue("ability", 10)
				pump()
			elseif not State.inCombat() then
				hideCard() -- votes, results, lobby: queued hints wait for the next fight
			end
		end, true)
	)

	-- A teammate (human or bot) goes down.
	table.insert(
		unsubs,
		State.subscribe("party", function(party)
			if type(party) ~= "table" or shown.revive then
				return
			end
			local me = State.localUserId()
			for id, e in party do
				if id ~= me and type(e) == "table" and e.downed == true and e.dead ~= true then
					enqueue("revive", 7, true)
					return
				end
			end
		end)
	)

	-- Using the ability closes its hint.
	local okIc, Input = pcall(require, Client.Controllers.InputController)
	if okIc and type(Input) == "table" and Input.abilityFired then
		local conn = Input.abilityFired:Connect(function()
			Onboarding.done("ability")
		end)
		table.insert(unsubs, function()
			conn:Disconnect()
		end)
	end
end

function Onboarding.destroy()
	for _, u in unsubs do
		u()
	end
	table.clear(unsubs)
	table.clear(queue)
	current = nil
	token += 1
	if screen then
		screen.destroy()
		screen = nil
	end
	card = nil
	iconLabel = nil
	textLabel = nil
end

return Onboarding
