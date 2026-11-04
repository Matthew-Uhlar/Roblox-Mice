-- Runtime emulator: the v2 final-fix behaviours that only show with the real
-- server + client scripts (docs/qa/V2-QC-A-integration.md, V2-QC-B-security-policy.md).
--   * QC-A M2: loot bags and dropped gear get pooled in-world visuals (rarity
--     colour, a label) that go away on bagGone / gearGone.
--   * QC-A minor 5: the map's lighting is applied once per stage.
--   * QC-A minor 7: the lobby island's decor is hidden locally during a run.
--   * QC-A minor 8: an enemy's "DOWN!" tag lives as long as the server's
--     Downed attribute (not dropped by PartyHud).
--   * QC-A M3: the Shop Cart panel uses the hero's own `share` and the server's
--     `bought`, and live updates never reopen a closed panel.
--   * QC-B V2-M1: Second Wind can't be prompted by a run member (lobby: yes).
--   * QC-B V2-m4 / m7: the Rind Gate stays neutral on the server, your squad's
--     pick tints it on your client only; the Extract panel folds to a bar.
--   * QC-A minor 6: a lobby player sees how long the running match has left.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")
local Driver = require("../runtime/Driver")
local roblox = require("@lune/roblox")

local USER_A, USER_B = 515151, 626262
local SW_PRODUCT = 77001
local rt = Runtime.new({ root = ".", dt = 1 / 30 })
local Monetization = rt:serverModule("ReplicatedStorage.Shared.Config.Monetization")
for _, it in Monetization.ALL do
	if it.key == "second_wind_1" then
		it.assetId = SW_PRODUCT -- fake Creator Dashboard id (test only)
	end
end
rt:startServer()
local RD = rt:serverModule("ServerScriptService.Server.Services.RunDirector")
local Remotes = rt:serverModule("ServerScriptService.Server.Services.Remotes")
local LightingService = rt:serverModule("ServerScriptService.Server.Services.LightingService")
RD.WAVE_SECONDS = 20
Driver.powerUp(rt, 25)
rt:advance(1)

-- every LightingService.apply call (map id), server side
local lightCalls: { string } = {}
local applyOriginal = LightingService.apply
LightingService.apply = function(id: string, ...)
	table.insert(lightCalls, tostring(id))
	return applyOriginal(id, ...)
end

local worldRef: any = nil
Driver.tapWorldEvents(rt, function(w)
	worldRef = w
end)

local failed = false
local function step(name: string, fn: () -> ())
	T.it(name, function()
		if failed then
			error("skipped (an earlier step failed)")
		end
		local ok, err = pcall(fn)
		if not ok then
			failed = true
			error(err, 0)
		end
	end)
end

local playerA, clientA, StateA
local function fxFolder(client: any): any
	return rt:find("Workspace.TrunkfallFx", client)
end
local function lootLabels(client: any): { string }
	return rt:runIn(client, function()
		local out = {}
		local f = fxFolder(client)
		for _, d in if f then f:GetDescendants() else {} do
			if d:IsA("BillboardGui") and d.Name == "LootLabel" and d.Enabled then
				local l = d:FindFirstChild("Label")
				table.insert(out, if l then l.Text else "?")
			end
		end
		return out
	end)
end
local function toasts(client: any, pattern: string): number
	local n = 0
	for _, args in client.inbox.Toast and client.inbox.Toast.list or {} do
		if string.find(tostring(args[1]), pattern, 1, true) then
			n += 1
		end
	end
	return n
end

T.describe("RuntimeV2Fixes", function()
	step("A joins and starts a solo match; the map lighting is applied once", function()
		playerA, clientA = rt:addPlayer({ userId = USER_A, name = "Alpha" })
		rt:advance(4)
		StateA = rt:clientModule(clientA, "Client.Controllers.State")
		Driver.autoplay(rt, clientA, function(kind)
			if kind == "route" then
				return "risk"
			elseif kind == "extract" then
				local m = StateA.get("match")
				return if type(m) == "table" and m.stage >= 2 then "Extract" else "Stay"
			elseif kind == "swap" then
				return true
			end
			return nil
		end)
		rt:setWalker(playerA, Driver.circleWalker(rt, 18, 10))
		table.clear(lightCalls)
		rt:click(clientA, Driver.findButton(rt, clientA, "TrunkfallLobby", "READY"))
		T.truthy(
			rt:runUntil(function()
				return RD.getPhase() == "Waves"
			end, 30),
			"reached Waves"
		)
		rt:advance(1)
		local maps = {}
		for _, id in lightCalls do
			if id ~= "lobby" then
				table.insert(maps, id)
			end
		end
		T.eq(#maps, 1, "[QC-A minor 5] one lighting apply for the stage: " .. table.concat(lightCalls, ","))
		rt:assertClean(nil, "start")
	end)

	step("[QC-A minor 7] the lobby island's decor is hidden on A's client during the run", function()
		local hidden, total = rt:runIn(clientA, function()
			local pad = rt.workspace:FindFirstChild("LobbyPad")
			local deco = pad and pad:FindFirstChild("Decor")
			local h, n = 0, 0
			for _, d in if deco then deco:GetDescendants() else {} do
				if d:IsA("BasePart") then
					n += 1
					if d.LocalTransparencyModifier >= 1 then
						h += 1
					end
				end
			end
			return h, n
		end)
		T.truthy(total > 0, "lobby decor exists")
		T.eq(hidden, total, "every lobby decor part hidden locally")
	end)

	local bagId, gearId
	step("[QC-A M2] a loot bag and dropped gear show in the world, coloured, with a label", function()
		T.truthy(worldRef, "world tapped")
		rt:asServer(function()
			local item = { id = "splitting_shots", slot = "weapon", rarity = "Epic" }
			bagId = worldRef:addLootBag(30, 30, { item }, 45)
			gearId = worldRef:dropGear({ id = "splitting_shots", slot = "weapon", rarity = "Rare" }, -30, -30)
		end)
		T.truthy(bagId and gearId, "server made a bag and a ground item")
		rt:advance(1)
		local labels = lootLabels(clientA)
		local bagLabel, gearLabel = false, false
		for _, l in labels do
			if string.find(l, "45", 1, true) and string.find(l, "gear ×1", 1, true) then
				bagLabel = true
			elseif l ~= "" and not string.find(l, "🧀", 1, true) then
				gearLabel = true
			end
		end
		T.truthy(bagLabel, "bag label (cheese + gear): " .. table.concat(labels, " | "))
		T.truthy(gearLabel, "ground gear label (item name)")
		-- an Epic-coloured neon disc under the bag (STYLE.md rarity colour)
		local epicDisc = rt:runIn(clientA, function()
			for _, d in fxFolder(clientA):GetDescendants() do
				if d:IsA("BasePart") and d.Transparency < 1 and d.Material == roblox.Enum.Material.Neon then
					local c = d.Color
					if
						math.abs(c.R * 255 - 179) < 2
						and math.abs(c.G * 255 - 107) < 2
						and math.abs(c.B * 255 - 255) < 2
					then
						return true
					end
				end
			end
			return false
		end)
		T.truthy(epicDisc, "the bag is drawn in the Epic colour")
	end)

	step("[QC-A M2] bagGone / gearGone remove the visuals", function()
		local before = #lootLabels(clientA)
		rt:asServer(function()
			worldRef:emit({ t = "bagGone", id = bagId })
			worldRef:emit({ t = "gearGone", id = gearId })
		end)
		rt:advance(1)
		T.eq(#lootLabels(clientA), before - 2, "both markers gone")
		rt:assertClean(nil, "loot")
	end)

	step("[QC-A minor 8] an enemy's DOWN tag stays while the server says Downed", function()
		local view = RD.getMatchView()
		local mine = nil
		for s = 1, 4 do
			if table.find(view.squads[s].members, USER_A) then
				mine = s
			end
		end
		local enemyId = nil
		for s = 1, 4 do
			if s ~= mine then
				for _, id in view.squads[s].members do
					local p = worldRef.players[id]
					if p and not p.downed and not p.dead then
						enemyId = enemyId or id
					end
				end
			end
		end
		T.truthy(enemyId, "a standing enemy bot")
		rt:asServer(function()
			worldRef:_down(worldRef.players[enemyId], nil)
		end)
		rt:advance(2)
		local function tagged(): boolean
			return rt:runIn(clientA, function()
				for _, d in fxFolder(clientA):GetChildren() do
					if d:IsA("BillboardGui") then
						for _, l in d:GetChildren() do
							if l:IsA("TextLabel") and l.Text == "Enemy squad" then
								return true
							end
						end
					end
				end
				return false
			end)
		end
		local p = worldRef.players[enemyId]
		if p and p.downed and not p.dead then
			T.truthy(tagged(), "the enemy tag survives PartyHud updates (2 s)")
			rt:asServer(function()
				worldRef:_revive(p, 0.5, "test")
			end)
			rt:advance(2)
		end
		T.falsy(tagged(), "removed once the Downed attribute clears")
		rt:assertClean(nil, "down tags")
	end)

	step("[QC-A M3] the Shop Cart panel: own share, server `bought`, live updates", function()
		local offers = {
			{ id = "splitting_shots", slot = "weapon", rarity = "Common" },
			{ id = "splitting_shots", slot = "weapon", rarity = "Rare" },
			{ id = "splitting_shots", slot = "weapon", rarity = "Epic" },
		}
		rt:asServer(function()
			Remotes.shopCart(playerA, {
				poi = 99,
				offers = offers,
				prices = { 60, 120, 220 },
				bought = { ["3"] = true }, -- RunDirector.sendCart sends string keys
				share = 100,
			})
		end)
		rt:advance(0.5)
		local function rows(): any
			return rt:runIn(clientA, function()
				local gui = rt:playerGui(clientA):FindFirstChild("TrunkfallShopCart")
				local out = { buttons = {}, balance = nil, visible = false }
				for _, d in gui:GetDescendants() do
					if d.Name == "ShopCart" and d:IsA("Frame") then
						out.visible = d.Visible
					elseif d:IsA("TextLabel") and string.find(d.Text, "Your share", 1, true) then
						out.balance = d.Text
					elseif
						d:IsA("TextButton") and (string.find(d.Text, "pending", 1, true) or d.Text == "Sold")
					then
						table.insert(out.buttons, { text = d.Text, active = d.Active })
					end
				end
				return out
			end)
		end
		local r = rows()
		T.truthy(r.visible, "panel open")
		T.truthy(
			r.balance and string.find(r.balance, "100", 1, true),
			"balance is your share: " .. tostring(r.balance)
		)
		local byText = {}
		for _, b in r.buttons do
			byText[b.text] = b.active
		end
		T.eq(byText["🧀 60 pending"], true, "60 <= your share 100: enabled")
		T.eq(byText["🧀 120 pending"], false, "120 > your share: disabled (not the squad pot)")
		T.eq(byText["Sold"], false, "the server's bought[3] shows Sold")
		-- a squad-mate bought item 1: live refresh
		rt:asServer(function()
			Remotes.shopCart(playerA, {
				poi = 99,
				offers = offers,
				prices = { 60, 120, 220 },
				bought = { ["1"] = true, ["3"] = true },
				share = 100,
				refresh = true,
			})
		end)
		rt:advance(0.5)
		local sold = 0
		for _, b in rows().buttons do
			if b.text == "Sold" then
				sold += 1
			end
		end
		T.eq(sold, 2, "a squad-mate's buy shows as Sold")
		-- closed panels never reopen on a live update
		rt:runIn(clientA, function()
			StateA.closeShopCart()
		end)
		rt:asServer(function()
			Remotes.shopCart(playerA, {
				poi = 99,
				offers = offers,
				prices = { 60, 120, 220 },
				bought = { ["1"] = true },
				share = 150,
				refresh = true,
			})
		end)
		rt:advance(0.5)
		T.eq(StateA.get("shopCart"), nil, "still closed")
		T.falsy(rows().visible)
	end)

	step("[QC-B V2-M1] Second Wind can't be prompted in a run", function()
		local before = #rt.prompts
		local ARemotes = rt:clientModule(clientA, "Client.Util.Remotes")
		rt:runIn(clientA, function()
			ARemotes.fire(ARemotes.C2S.PromptProduct, "second_wind_1")
		end)
		rt:advance(1)
		T.eq(#rt.prompts, before, "no prompt for a run member")
		T.eq(toasts(clientA, "can't be bought during a run"), 1, "a clear toast")
	end)

	local playerB, clientB
	step("[QC-A minor 6] a lobby player sees the match's time left; [V2-M1] lobby prompts work", function()
		playerB, clientB = rt:addPlayer({ userId = USER_B, name = "Bravo" })
		rt:advance(4)
		local StateB = rt:clientModule(clientB, "Client.Controllers.State")
		local lobby = StateB.get("lobby")
		T.truthy(type(lobby) == "table" and lobby.runActive, "B sees a run in progress")
		local info = lobby.runInfo
		T.truthy(type(info) == "table" and tonumber(info.endsAt), "run info sent")
		T.truthy(tonumber(info.endsAt) > StateB.serverNow(), "ends in the future")
		local text = rt:runIn(clientB, function()
			for _, d in rt:playerGui(clientB):FindFirstChild("TrunkfallLobby"):GetDescendants() do
				if
					d:IsA("TextLabel")
					and string.find(d.Text, "next match starts when this one ends", 1, true)
				then
					return d.Text
				end
			end
			return nil
		end)
		T.truthy(text and string.find(text, "left", 1, true), "lobby says when: " .. tostring(text))
		local before = #rt.prompts
		local BRemotes = rt:clientModule(clientB, "Client.Util.Remotes")
		rt:runIn(clientB, function()
			BRemotes.fire(BRemotes.C2S.PromptProduct, "second_wind_1")
		end)
		rt:advance(1)
		T.eq(#rt.prompts, before + 1, "a lobby player can still buy Second Wind")
		T.eq(rt.prompts[#rt.prompts].id, SW_PRODUCT)
		rt:assertClean(nil, "lobby B")
	end)

	step(
		"[QC-B V2-m4 / m7] the gate stays gold on the server; A's squad pick tints A's view; the panel folds",
		function()
			local sawVote = false
			local serverNonGold, clientTint, folded = 0, false, false
			local function poolColor(ctx: any): any
				return rt:runIn(ctx, function()
					local gate = rt.workspace:FindFirstChild("RindGate", true)
					local pool = gate and gate:FindFirstChild("Pool")
					return if pool then pool.Color else nil
				end)
			end
			local done = rt:runUntil(function()
				if RD.getPhase() == "Extraction" then
					local e = StateA.get("extract")
					if type(e) == "table" and e.yourChoice == "Stay" then
						sawVote = true
						local sc = poolColor(nil)
						if sc and math.abs(sc.G * 255 - 204) > 2 then
							serverNonGold += 1
						end
						local cc = poolColor(clientA)
						if cc and math.abs(cc.G * 255 - 220) < 2 and math.abs(cc.R * 255 - 110) < 2 then
							clientTint = true
						end
						local bar = rt:runIn(clientA, function()
							local g = rt:playerGui(clientA):FindFirstChild("TrunkfallExtract")
							return g and g:FindFirstChild("ExtractBar", true)
						end)
						local panel = rt:runIn(clientA, function()
							local g = rt:playerGui(clientA):FindFirstChild("TrunkfallExtract")
							return g and g:FindFirstChild("Extract", true)
						end)
						if bar and rt:isShown(bar) and panel and not rt:isShown(panel) then
							folded = true
						end
						return clientTint and folded
					end
				end
				return false
			end, 400)
			T.truthy(sawVote, "A voted Stay at a Rind Gate (phase " .. RD.getPhase() .. ")")
			T.truthy(done, "tint and fold observed")
			T.eq(serverNonGold, 0, "the server's gate never shows a squad's vote")
			T.truthy(clientTint, "A's own client shows the Stay tint")
			T.truthy(folded, "the Extract panel folded to the compact bar after the vote")
			-- [QC-A minor 2] the Extract card banks YOUR share (x Portal Charm), not the squad pot
			local e = StateA.get("extract")
			local cardText = rt:runIn(clientA, function()
				for _, d in rt:playerGui(clientA):FindFirstChild("TrunkfallExtract"):GetDescendants() do
					if d:IsA("TextLabel") and string.find(d.Text, "(your share)", 1, true) then
						return d.Text
					end
				end
				return nil
			end)
			T.truthy(cardText, "the Extract card says '(your share)'")
			if type(e) == "table" and tonumber(e.bank) then
				local Format = rt:clientModule(clientA, "Client.Util.Format")
				T.truthy(
					string.find(cardText, Format.int(e.bank), 1, true),
					"shows the server's bank " .. tostring(e.bank) .. ": " .. tostring(cardText)
				)
			end
			local open = Driver.findButton(rt, clientA, "TrunkfallExtract", "Open")
			T.truthy(open, "the bar has Open")
			rt:click(clientA, open)
			rt:advance(0.2)
			local panel = rt:runIn(clientA, function()
				return rt:playerGui(clientA)
					:FindFirstChild("TrunkfallExtract")
					:FindFirstChild("Extract", true)
			end)
			if RD.getPhase() == "Extraction" then
				T.truthy(rt:isShown(panel), "Open brings the cards back")
			end
			rt:assertClean(nil, "gate")
		end
	)

	step("teardown is clean", function()
		rt:setWalker(playerA, nil)
		rt:removePlayer(playerA)
		rt:removePlayer(playerB)
		rt:advance(5)
		rt:assertClean(nil, "teardown")
	end)
end)

return T.finish()
