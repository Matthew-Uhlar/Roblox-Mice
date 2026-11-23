-- Runtime emulator, lobby look (iter 6, team Look): players wear their elephant
-- (the Herd Suit: class + skin + ascension look + cosmetics) in the lobby too.
-- A player joins -> suited with their class; SelectClass -> the suit is rebuilt
-- in place (same character, old suit destroyed) and the client's LobbyLook plays
-- one swap puff; redraw spam is debounced; SelectSkin -> changes; the avatarLook
-- opt-out -> no suit (avatar restored), and back; 4 players stay within the
-- in-run part count (same builder); leaving cleans up; zero errors / warnings.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")

local rt = Runtime.new({ root = ".", dt = 1 / 30 })
rt:startServer()
local DataService = rt:serverModule("ServerScriptService.Server.Services.DataService")
local Cosmetics = rt:serverModule("ServerScriptService.Server.Services.CosmeticsService")
local ClassProgress = rt:serverModule("ReplicatedStorage.Shared.Data.ClassProgress")
local ClassSkins = rt:serverModule("ReplicatedStorage.Shared.Config.ClassSkins")
local BotModel = rt:serverModule("ServerScriptService.Server.Visuals.BotModel")
rt:advance(1)

local function fire(client: any, name: string, ...: any)
	local args = table.pack(...)
	local Remotes = rt:clientModule(client, "Client.Util.Remotes")
	rt:runIn(client, function()
		Remotes.fire(Remotes.C2S[name] or name, table.unpack(args, 1, args.n))
	end)
end

local function suitOf(player: any): any
	local char = player.Character
	return char and char:FindFirstChild("HerdSuit")
end

local function suitCount(char: any): number
	local n = 0
	for _, c in char:GetChildren() do
		if c.Name == "HerdSuit" then
			n += 1
		end
	end
	return n
end

local function partCount(model: any): number
	local n = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

T.describe("RuntimeLobbyLook", function()
	local p, c
	local LobbyLook
	local firstSuit, firstChar
	local moreShared: { any } = {}
	T.it("a joining player wears the Herd Suit of their class in the lobby", function()
		p, c = rt:addPlayer({ userId = 8301, name = "Trunky" })
		rt:advance(6)
		local char = p.Character
		T.truthy(char, "character")
		local suit = suitOf(p)
		T.truthy(suit, "HerdSuit in the lobby")
		T.eq(char:GetAttribute("HerdSuit"), true, "HerdSuit attribute")
		T.eq(p:GetAttribute("Squad"), nil, "no squad in the lobby")
		T.eq(suit:GetAttribute("ClassId"), p:GetAttribute("ClassId"), "suit = selected class")
		T.eq(suit:GetAttribute("RigStyle"), "elephant", "animated by BotAnimator")
		T.eq(char.Head.Transparency, 1, "avatar head hidden under the suit")
		T.truthy(type(char:GetAttribute("LookKey")) == "string", "LookKey set")
		local tag = suit:FindFirstChild("Head", true)
		T.falsy(suit:FindFirstChild("NameTag", true), "no bot tag on a player's suit")
		T.truthy(tag, "suit head")
		firstSuit, firstChar = suit, char
		-- the client animator picks the suit up (same as in a run)
		local Anim = rt:clientModule(c, "Client.Visuals.BotAnimator")
		rt:advance(1.5)
		T.truthy(Anim.has(p.UserId), "BotAnimator drives the lobby suit")
		LobbyLook = rt:clientModule(c, "Client.Controllers.LobbyLook")
		rt:runIn(c, function()
			LobbyLook.destroy() -- the test polls by hand from here
			T.eq(LobbyLook.poll(), 0, "first sight is silent")
		end)
		rt:assertClean(nil, "join")
	end)

	T.it("SelectClass rebuilds the suit in place, with one swap puff", function()
		local before = p:GetAttribute("ClassId")
		local target = if before == "ele_fonte" then "ellie_fawn" else "ele_fonte"
		fire(c, "SelectClass", target)
		rt:advance(1)
		T.eq(p:GetAttribute("ClassId"), target, "class changed")
		T.eq(p.Character, firstChar, "no respawn")
		local suit = suitOf(p)
		T.truthy(suit and suit ~= firstSuit, "a new suit")
		T.eq(firstSuit.Parent, nil, "old suit destroyed")
		T.eq(suitCount(p.Character), 1, "exactly one suit")
		T.eq(suit:GetAttribute("ClassId"), target, "suit class follows")
		rt:runIn(c, function()
			T.eq(LobbyLook.poll(), 1, "one swap puff")
			T.eq(LobbyLook.poll(), 0, "no repeat")
		end)
		rt:assertClean(nil, "select class")
	end)

	T.it("redraw spam in the lobby is debounced", function()
		rt:advance(1)
		local char = p.Character
		local builds = 0
		local conn = char.ChildAdded:Connect(function(x)
			if x.Name == "HerdSuit" then
				builds += 1
			end
		end)
		for _ = 1, 6 do
			rt:runIn(rt.server, function()
				Cosmetics.refresh(p)
			end)
			rt:advance(0.05)
		end
		rt:advance(1)
		conn:Disconnect()
		print("BUILDS", builds)
		T.truthy(builds >= 1 and builds <= 3, "6 redraws in 0.3 s build " .. builds .. " suits")
		T.eq(suitCount(char), 1, "exactly one suit")
		rt:assertClean(nil, "debounce")
	end)

	T.it("SelectSkin changes the suit", function()
		local cid = p:GetAttribute("ClassId")
		local skin
		for _, def in ClassSkins.forClass(cid) do
			if def.source == "level" then
				skin = def
				break
			end
		end
		T.truthy(skin, "a level skin for " .. tostring(cid))
		rt:runIn(rt.server, function()
			DataService.update(p, function(profile)
				ClassProgress.ensure(profile, cid).level = 30
			end)
		end)
		local old = suitOf(p)
		local oldKey = p.Character:GetAttribute("LookKey")
		fire(c, "SelectSkin", cid, skin.id)
		rt:advance(1)
		local suit = suitOf(p)
		T.truthy(suit and suit ~= old, "suit rebuilt")
		T.eq(old.Parent, nil, "old suit destroyed")
		local key = p.Character:GetAttribute("LookKey")
		T.truthy(key ~= oldKey and string.find(key, skin.id, 1, true), "LookKey has the skin: " .. tostring(key))
		rt:runIn(c, function()
			T.eq(LobbyLook.poll(), 1, "swap puff on skin change")
		end)
		rt:assertClean(nil, "select skin")
	end)

	T.it("the avatarLook opt-out shows the Roblox avatar, and back", function()
		fire(c, "SetSetting", "avatarLook", true)
		rt:advance(1)
		local char = p.Character
		T.eq(p:GetAttribute("HeroLook"), "avatar", "HeroLook mirrored")
		T.eq(suitOf(p), nil, "no suit")
		T.eq(char:GetAttribute("HerdSuit"), false, "HerdSuit attribute off")
		T.truthy(char.Head.Transparency < 1, "avatar head visible again")
		fire(c, "SetSetting", "avatarLook", false)
		rt:advance(1)
		T.truthy(suitOf(p), "suit back")
		T.eq(suitCount(p.Character), 1, "exactly one suit")
		rt:assertClean(nil, "opt-out")
	end)

	T.it("4 players: every suit within the in-run part count", function()
		local more = {}
		for i = 1, 3 do
			local q = rt:addPlayer({ userId = 8301 + i, name = "Herd" .. i })
			table.insert(more, q)
		end
		rt:advance(6)
		local players = { p, more[1], more[2], more[3] }
		for _, q in players do
			local suit = suitOf(q)
			T.truthy(suit, q.Name .. " suited")
			local cid = q:GetAttribute("ClassId")
			local runParts = rt:runIn(rt.server, function()
				local m = BotModel.build({
					id = 0,
					name = q.Name,
					classId = cid,
					skinId = ClassProgress.skinFor(DataService.get(q), cid),
					ascLook = q:GetAttribute("AscLook"),
				}, 1, { suit = true })
				local n = partCount(m)
				m:Destroy()
				return n
			end)
			T.eq(partCount(suit), runParts, q.Name .. " lobby suit = in-run suit parts")
			print("PARTS", q.Name, runParts, partCount(suit))
			T.truthy(runParts <= 200, "suit budget: " .. runParts .. " parts")
		end
		-- bots (if any) keep their own models: never a player's suit
		local bots = rt.workspace:FindFirstChild("Bots")
		for _, m in (if bots then bots:GetChildren() else {}) do
			T.falsy(m:FindFirstChild("HerdSuit"), "bot unchanged")
		end
		rt:assertClean(nil, "4 players")
		moreShared = more
	end)

	T.it("leaving cleans up", function()
		local more = moreShared
		local leaver = more[3]
		local char = leaver.Character
		local suit = suitOf(leaver)
		rt:removePlayer(leaver)
		rt:advance(2)
		T.truthy(char == nil or char.Parent == nil, "character gone")
		T.truthy(suit == nil or not suit:IsDescendantOf(rt.workspace), "suit gone")
		local suits = 0
		for _, d in rt.workspace:GetDescendants() do
			if d.Name == "HerdSuit" then
				suits += 1
			end
		end
		T.eq(suits, 3, "one suit per remaining player")
		rt:runIn(c, function()
			LobbyLook.poll()
			LobbyLook.init()
		end)
		rt:advance(1)
		rt:assertClean(nil, "leave")
	end)
end)

return T.finish()
