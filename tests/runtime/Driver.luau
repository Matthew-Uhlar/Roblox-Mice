-- Scenario helpers: a scripted "player" that clicks the real client UI
-- (READY, vote cards, upgrade cards) and walks its character, plus test-only
-- knobs that speed a run up. Everything here lives in tests/, never in src/.

local roblox = require("@lune/roblox")
local Inst = require("./Instance")

local D = Inst.D
local rawGet = Inst.rawGet

local Driver = {}

-- First on-screen GuiButton under PlayerGui[screenName] whose text (or a label
-- inside it) contains `pattern` (plain find, case-insensitive). nil pattern = any.
function Driver.findButton(rt: any, client: any, screenName: string, pattern: string?): any
	local gui = rt:playerGui(client)
	local screen = gui and Inst.findVisibleChild(D[gui], screenName, client)
	if not screen then
		return nil
	end
	local S = rt.S
	local prev = S.current
	S.current = client
	local found = nil
	for _, x in screen:GetDescendants() do
		local d = D[x]
		if d.cls.isA.GuiButton and rt:isShown(x) then
			if pattern == nil then
				found = x
				break
			end
			local texts = {}
			if d.cls.props.Text then
				table.insert(texts, rawGet(d, "Text"))
			end
			for _, y in x:GetDescendants() do
				local yd = D[y]
				if yd.cls.props.Text then
					table.insert(texts, rawGet(yd, "Text"))
				end
			end
			for _, t in texts do
				if string.find(string.lower(t), string.lower(pattern), 1, true) then
					found = x
					break
				end
			end
			if found then
				break
			end
		end
	end
	S.current = prev
	return found
end

-- Autoplay: every `interval` seconds the scripted player answers whatever the UI
-- shows: upgrade cards (first card), votes (policy(kind, options) -> text to click).
function Driver.autoplay(rt: any, client: any, policy: (kind: string, options: { any }) -> string?)
	local State = nil
	local log = { picks = 0, votes = {}, voteKinds = {} }
	local lastVote = nil
	local nextAt = 0
	table.insert(rt.S.frameHooks, function(_dt, phase)
		if phase ~= "post" or client.dead or rt.S.now < nextAt then
			return
		end
		nextAt = rt.S.now + 0.3
		if not State then
			local ok, mod = pcall(rt.clientModule, rt, client, "Client.Controllers.State")
			if not ok then
				return -- client not booted yet
			end
			State = mod
		end
		-- upgrade offer on screen?
		local card = Driver.findButton(rt, client, "TrunkfallUpgrades", nil)
		if card then
			-- skip reroll/close buttons: upgrade cards contain a rarity band label
			local pick = Driver.findButton(rt, client, "TrunkfallUpgrades", "common")
				or Driver.findButton(rt, client, "TrunkfallUpgrades", "rare")
				or Driver.findButton(rt, client, "TrunkfallUpgrades", "epic")
				or Driver.findButton(rt, client, "TrunkfallUpgrades", "legendary")
				or Driver.findButton(rt, client, "TrunkfallUpgrades", "uncommon")
			if pick then
				rt:click(client, pick)
				log.picks += 1
			end
		end
		local vote = State.get("vote")
		if type(vote) == "table" and not vote.closed and vote ~= lastVote then
			local text = policy(tostring(vote.kind), vote.options)
			local b = if text then Driver.findButton(rt, client, "TrunkfallVote", text) else nil
			if b then
				rt:click(client, b)
				lastVote = vote
				table.insert(log.votes, text)
				table.insert(log.voteKinds, vote.kind)
			end
		end
	end)
	return log
end

-- Walks the character in a circle around the arena (or stands in the lobby).
function Driver.circleWalker(rt: any, radius: number, period: number)
	return function(now: number, _pos: any)
		local arena = rt.workspace:FindFirstChild("Arena")
		if not arena then
			return nil
		end
		local c = arena:GetPivot().Position
		local a = (now / period) * math.pi * 2
		return roblox.Vector3.new(c.X + math.cos(a) * radius, c.Y, c.Z + math.sin(a) * radius)
	end
end

-- TEST-ONLY KNOB: wraps the SERVER context's Stats.compute so every hero (the
-- test player and the bots) deals `mult`x damage and has `mult`x max HP. It
-- patches the module table the server scripts already required; src/ is untouched.
function Driver.powerUp(rt: any, mult: number)
	local Stats = rt:serverModule("ReplicatedStorage.Shared.Run.Stats")
	local original = Stats.compute
	Stats.compute = function(...)
		local stats, weapon, ability = original(...)
		stats.damageMult = (stats.damageMult or 1) * mult
		stats.maxHp = (stats.maxHp or 100) * mult
		return stats, weapon, ability
	end
	return function()
		Stats.compute = original
	end
end

return Driver
