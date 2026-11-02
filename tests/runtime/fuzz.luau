-- Exploratory UI fuzz run (not a spec; nothing runs it automatically).
--
--   lune run tests/runtime/fuzz.luau [seed] [Deferred|Immediate] [seconds]
--
-- Three players (keyboard, phone, a late gamepad joiner) click random on-screen
-- buttons, fire abilities through ContextActionService and walk under laggy
-- replication while runs play out; one player leaves halfway. Prints the click
-- histogram and the emulator report; exits 1 on any script error or emulator gap.
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Runtime = require("./Runtime")
local Driver = require("./Driver")

local seed = tonumber(process.args[1]) or 1
local mode = process.args[2] or "Deferred"
local seconds = tonumber(process.args[3]) or 400

local rt = Runtime.new({ root = ".", dt = 1 / 30, signalBehavior = mode })
rt:startServer()
local RD = rt:serverModule("ServerScriptService.Server.Services.RunDirector")
RD.WAVE_SECONDS = 25
rt:advance(1)

local state = seed
local function rnd(n: number): number
	state = (state * 1103515245 + 12345) % 2147483648
	return 1 + (state % n)
end

local players = {}
local function join(id: number, name: string, opts: { [string]: any }?)
	local o = opts or {}
	o.userId = id
	o.name = name
	local p, c = rt:addPlayer(o)
	table.insert(players, { p = p, c = c })
	rt:setWalker(p, Driver.circleWalker(rt, 10 + rnd(15), 8 + rnd(8)))
	rt:setNetConditions(p, { rate = 20, latency = 0.15, jitter = 0.1, seed = id })
end

join(100 + seed, "Kbm")
join(200 + seed, "Phone", {
	device = { touch = true, keyboard = false, mouse = false },
	viewport = roblox.Vector2.new(667, 375),
})
rt:advance(4)

local clicks = {}
local nextFuzz = 0
local joinedLate, left = false, false
local lastPhase
rt:runUntil(function()
	local ph = RD.getPhase()
	if ph ~= lastPhase then
		print(string.format("t=%.1f %s errors=%d gaps=%d", rt.S.now, ph, #rt:errors(), #rt:gaps()))
		lastPhase = ph
	end
	if rt.S.now >= nextFuzz then
		nextFuzz = rt.S.now + 0.4
		for _, e in players do
			if not e.c.dead then
				local buttons = rt:findButtons(e.c, "")
				if #buttons > 0 then
					local b = buttons[rnd(#buttons)]
					local label = string.gsub(b.Text, "\n", " ")
					clicks[label] = (clicks[label] or 0) + 1
					rt:click(e.c, b)
				end
				if e.c.actions.TrunkfallAbility and rnd(3) == 1 then
					rt:action(e.c, "TrunkfallAbility", roblox.Enum.UserInputState.Begin, {
						KeyCode = roblox.Enum.KeyCode.Q,
						UserInputType = roblox.Enum.UserInputType.Keyboard,
					})
				end
			end
		end
	end
	if not joinedLate and ph == "Waves" and rt.S.now > 40 then
		joinedLate = true
		join(300 + seed, "Late", { device = { gamepad = true, keyboard = true, mouse = true } })
	end
	if not left and rt.S.now > seconds / 3 then
		left = true
		rt:removePlayer(players[2].p)
	end
	return #rt:errors() > 0 or #rt:gaps() > 0 or rt.S.now > seconds
end, seconds + 10)

print("clicks:")
for label, n in clicks do
	print(string.format("  %4d  %s", n, label))
end
print(rt:report({ "rate limited" }))
if #rt:errors() > 0 or #rt:gaps() > 0 then
	process.exit(1)
end
