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

-- Autoplay: every 0.3 s the scripted player answers whatever the UI shows:
--   * upgrade cards: the first card with a rarity band (TrunkfallUpgrades);
--   * route votes: policy("route", options) -> text of the card to click
--     (TrunkfallVote). v2: VoteOpen kind "route" only reaches the squad that won
--     the boss, so most stages show no route vote at all;
--   * the extraction window: policy("extract", options) -> "Extract" | "Stay" |
--     "DoubleOrNothing". The card with that title is clicked in TrunkfallExtract
--     (ExtractUI -> State.castExtract -> Net.C2S.ExtractVote(choice: string)). If
--     the card is not on screen the driver calls State.castExtract itself, which
--     sends the same remote, and counts it in log.extractFallbacks;
--   * gear swap prompts: policy("swap", {item, current}) -> true (take) / false
--     (keep) / nil (let it time out), through State.answerSwap (Net.C2S.SwapGear).
-- log = { picks, votes = {text}, voteKinds = {kind}, extracts = {choice},
--         extractStages = {stage}, extractFallbacks, swaps }
local EXTRACT_TITLE = { Extract = "Extract", Stay = "Stay", DoubleOrNothing = "Double or Nothing" }
Driver.EXTRACT_TITLE = EXTRACT_TITLE

function Driver.autoplay(rt: any, client: any, policy: (kind: string, options: any) -> any)
	local State = nil
	local log = {
		picks = 0,
		votes = {},
		voteKinds = {},
		extracts = {},
		extractStages = {},
		extractFallbacks = 0,
		swaps = 0,
	}
	local lastVote = nil
	local lastExtract = nil
	local lastSwap = nil
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
			local b = if type(text) == "string" then Driver.findButton(rt, client, "TrunkfallVote", text) else nil
			if b then
				rt:click(client, b)
				lastVote = vote
				table.insert(log.votes, text)
				table.insert(log.voteKinds, vote.kind)
			end
		end
		local ex = State.get("extract")
		if type(ex) == "table" and not ex.closed and ex.endsAt ~= lastExtract then
			local choice = policy("extract", ex.options)
			if type(choice) == "string" and EXTRACT_TITLE[choice] then
				local b = Driver.findButton(rt, client, "TrunkfallExtract", EXTRACT_TITLE[choice])
				if b then
					rt:click(client, b)
				else
					log.extractFallbacks += 1
					rt:runIn(client, function()
						State.castExtract(choice)
					end)
				end
				lastExtract = ex.endsAt
				local match = State.get("match")
				table.insert(log.extracts, choice)
				table.insert(log.extractStages, if type(match) == "table" then match.stage else nil)
			end
		end
		local inv = State.get("inventory")
		local offer = if type(inv) == "table" then inv.swapOffer else nil
		if type(offer) == "table" and offer ~= lastSwap and type(State.answerSwap) == "function" then
			local take = policy("swap", offer)
			if take ~= nil then
				lastSwap = offer
				rt:runIn(client, function()
					State.answerSwap(take == true)
				end)
				log.swaps += 1
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
