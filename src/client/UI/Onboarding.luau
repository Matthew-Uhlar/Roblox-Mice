--!strict
-- First-session coach marks (QC2 minor 12). One small corner card at a time
-- (v3: PC bottom-right corner, which the centred ability row leaves free;
-- touch: right edge above the touch ability button, clear of the thumbstick),
-- with device-specific text for touch, keyboard/mouse and gamepad:
--
--   move     how to move                     } first time combat starts,
--   attack   attacks are automatic           } shown one after another
--   crumbs   cheese crumbs give XP           }
--   ability  the ability button / keys       } (closes when the ability is used)
--   revive   stand near a downed teammate      first time a teammate goes down
--   pois     stand on glowing spots, avoid traps  first time a live POI is near (HudUI)
--   route    route cards (inline in VoteUI via Onboarding.claim("route"))
--   v2 (squad PvPvE; shown to players new to v2, see `newToV2`):
--   squads   enemy squads are rivals, friendly fire is off   first Waves of a squad match
--   gear     gear is run-only, 3 slots, swap with F / G       first Inventory with an item
--   extract  Extract banks the pot, Stay grows it, DoN gambles  first extraction window (ExtractUI)
--   perks    you have free perk points: open Perks           lobby, whenever points are free
--   melt     (v4) the storm circle closes in                  first shrinking storm, runs < 3
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
local UiSizes = require(Client.Util.UiSizes)
local State = require(Client.Controllers.State)

local Onboarding = {}

local C = Theme.C

-- Text is looked up when shown, so it matches the input mode in use then.
type Hint = { key: string, seconds: number, anywhere: boolean? }

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

-- New to the v2 squad game: no class has reached level 3 yet (profile.classes).
function Onboarding.newToV2(): boolean
	local p = State.get("profile")
	if type(p) ~= "table" or type(p.classes) ~= "table" then
		return true
	end
	for _, c in p.classes do
		if type(c) == "table" and (tonumber(c.level) or 1) >= 3 then
			return false
		end
	end
	return true
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
	if key == "revive" or key == "melt" then
		return runs < 3
	end
	if key == "squads" or key == "gear" or key == "extract" or key == "perks" then
		return runs < 3 or Onboarding.newToV2()
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

-- v4 (review B S2-2): hints are short, about 8 words, with an icon.
local function textFor(key: string): (string, string)
	local mode = Device.mode()
	if key == "move" then
		if mode == "touch" then
			return "👆", "Drag on the left side to move."
		elseif mode == "gamepad" then
			return "🎮", "Left stick to move."
		end
		return "⌨", "WASD to move · attacks are automatic."
	elseif key == "attack" then
		return "🐘", "You attack automatically. Dodge the red zones!"
	elseif key == "crumbs" then
		return "🧀", "Grab cheese crumbs to level up."
	elseif key == "ability" then
		if mode == "touch" then
			return "💥", "Tap 💥 for your ability. Drag to aim."
		elseif mode == "gamepad" then
			return "💥", "X: ability. Right stick aims."
		end
		return "💥", "Space, Q or right-click: ability."
	elseif key == "revive" then
		return "💫", "Teammate down! Stand next to them."
	elseif key == "pois" then
		return "✨", "Stand on glowing spots for rewards."
	elseif key == "squads" then
		return "⚔", "Other squads are rivals. Stay together!"
	elseif key == "gear" then
		local swap = if mode == "touch"
			then "Tap Equip or Keep"
			elseif mode == "gamepad" then "L1 equip · R1 keep"
			else "F equip · G keep"
		return "🛡", "Gear lasts this run. " .. swap .. "."
	elseif key == "extract" then
		return "🌀", "Extract banks your cheese. Stay risks it."
	elseif key == "perks" then
		return "🌳", "Free perk points! Tap Perks."
	elseif key == "melt" then
		return "🔥", "The Melt closes in. Stay inside the circle!"
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
	if current ~= nil then
		return
	end
	local combat = State.inCombat()
	for i, h in queue do
		-- Combat hints wait for a fight; "anywhere" hints (lobby, extraction) don't.
		if combat or h.anywhere then
			table.remove(queue, i)
			showHint(h)
			return
		end
	end
end

local function enqueue(key: string, seconds: number, urgent: boolean?, anywhere: boolean?)
	if not Onboarding.claim(key) then
		return
	end
	local h: Hint = { key = key, seconds = seconds, anywhere = anywhere }
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

-- ExtractUI calls this when the extraction window opens.
function Onboarding.extractSeen()
	enqueue("extract", 9, true, true)
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

-- Lobby: free perk points on the selected class.
function Onboarding.checkPerks()
	if shown.perks or not State.inLobby() or State.get("results") ~= nil then
		return
	end
	local ok, ClassInfo = pcall(require, script.Parent.ClassInfo)
	if not ok then
		return
	end
	local p = State.get("profile")
	local classId = if type(p) == "table" and p.selectedClass then tostring(p.selectedClass) else nil
	if classId and ClassInfo.progress(classId).free > 0 then
		enqueue("perks", 8, false, true)
	end
end

function Onboarding.init()
	if screen then
		return
	end
	screen = Theme.screen("TrunkfallHints", 32)
	local dense = Theme.dense()
	local H = UiSizes.hint(dense)
	-- Slim "Got it" on PC, a full touch target on touch devices.
	local buttonH = if Device.hasTouch() then Theme.TOUCH else Theme.SLIM
	local cornerPC = not Device.hasTouch()
	local c = Theme.panel({
		Name = "Hint",
		AnchorPoint = if cornerPC then Vector2.new(1, 1) else Vector2.new(1, 0.5),
		Position = if cornerPC then UDim2.new(1, -12, 1, -12) else UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(H.w, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 0.05,
		Visible = false,
		Parent = screen.root,
	})
	Theme.padding(H.pad, H.pad - 2).Parent = c
	Theme.list(Enum.FillDirection.Vertical, H.gap, Enum.HorizontalAlignment.Left).Parent = c
	local row = Theme.make("Frame", {
		LayoutOrder = 1,
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, H.iconBox),
		Parent = c,
	})
	iconLabel = Theme.label({
		Size = UDim2.fromOffset(H.iconBox, H.iconBox),
		TextSize = H.iconText,
		Parent = row,
	})
	textLabel = Theme.label({
		Position = UDim2.fromOffset(H.iconBox + 6, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -(H.iconBox + 6), 0, H.iconBox),
		TextSize = H.text,
		Font = Theme.FONT_BODY,
		TextColor3 = C.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})
	Theme.button("Got it ✔", C.green, {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, buttonH),
		TextSize = H.buttonText,
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
				if State.isSquadMatch() then
					enqueue("squads", 9)
				end
				enqueue("crumbs", 6)
				enqueue("ability", 10)
				pump()
			elseif phase == "Lobby" or phase == nil then
				hideCard()
				Onboarding.checkPerks()
			elseif not State.inCombat() then
				hideCard() -- votes, results, lobby: queued hints wait for the next fight
			end
		end, true)
	)

	-- First gear in a slot.
	table.insert(
		unsubs,
		State.subscribe("inventory", function(inv)
			if shown.gear or type(inv) ~= "table" then
				return
			end
			if inv.weapon or inv.armor or inv.trinket or inv.swapOffer then
				enqueue("gear", 10, false, true)
			end
		end)
	)
	-- v4: the first storm shrink.
	table.insert(
		unsubs,
		State.subscribe("storm", function(st)
			if type(st) == "table" and not shown.melt and st.toR < st.r - 1 then
				enqueue("melt", 7)
			end
		end)
	)
	-- A squad match started mid-Waves (Match arrives after RunState).
	table.insert(
		unsubs,
		State.subscribe("match", function(m)
			if type(m) == "table" and not shown.squads and State.inCombat() then
				enqueue("squads", 9)
			end
		end)
	)
	table.insert(
		unsubs,
		State.subscribe("profile", function()
			Onboarding.checkPerks()
		end)
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
