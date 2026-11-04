-- Runtime emulator, scenario (a): the server boots in the Roblox-like runtime.
-- Main.server.luau inits every service with no script errors, no emulator gaps and
-- no unexpected warnings; ReplicatedStorage.Remotes holds every Net remote with
-- the right class; and the emulated DataModel matches what `rojo build` produces.
-- Also checks the emulator itself (so a clean run means something).
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")
local Inst = require("../runtime/Instance")
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local rt = Runtime.new({ root = ".", dt = 1 / 30 })
rt:startServer()
rt:advance(2)

T.describe("RuntimeBoot", function()
	T.it("Main.server.luau boots with zero errors, gaps or unexpected warnings", function()
		rt:assertClean(nil, "boot")
		local ready = false
		for _, p in rt.S.prints do
			if string.find(p.message, "Trunkfall server ready", 1, true) then
				ready = true
			end
		end
		T.truthy(ready, "server printed ready")
	end)

	T.it("every service module loaded in the server context", function()
		for _, name in
			{
				"DataService",
				"MonetizationService",
				"ShopService",
				"LeaderboardService",
				"CosmeticsService",
				"LobbyService",
				"RunDirector",
				"CombatService",
				"ArenaBuilder",
				"BotService",
				"Guard",
				"Remotes",
			}
		do
			local inst = rt:find("ServerScriptService.Server.Services." .. name)
			T.truthy(inst, name .. " exists")
			T.truthy(rt.server.moduleCache[inst], name .. " was required by the server")
		end
	end)

	T.it("ReplicatedStorage.Remotes holds every Net remote", function()
		local Net = rt:serverModule("ReplicatedStorage.Shared.Net")
		local folder = rt:find("ReplicatedStorage.Remotes")
		T.truthy(folder, "Remotes folder")
		local n = 0
		for _, group in { Net.C2S, Net.S2C } do
			for _, name in group do
				n += 1
				local r = folder:FindFirstChild(name)
				T.truthy(r, "remote " .. name)
				local want = if name == Net.S2C.Snapshot then "UnreliableRemoteEvent" else "RemoteEvent"
				T.eq(r.ClassName, want, name)
			end
		end
		T.eq(#folder:GetChildren(), n, "no stray remotes")
	end)

	T.it("the emulated tree matches `rojo build` (names, classes, sources)", function()
		local ok = pcall(process.exec, "rojo", { "--version" })
		if not ok then
			print("    (rojo not installed: skipped the rbxlx cross-check)")
			return
		end
		fs.writeDir("build")
		local res = process.exec("rojo", { "build", "-o", "build/Trunkfall.rbxlx" })
		T.truthy(res.ok, "rojo build: " .. tostring(res.stderr))
		local place = roblox.deserializePlace(fs.readFile("build/Trunkfall.rbxlx"))
		local checked = 0
		local function compare(real: any, emu: any, path: string)
			T.eq(emu.ClassName, real.ClassName, path .. " class")
			if real:IsA("LuaSourceContainer") then
				T.eq(Inst.D[emu].extra.source, real.Source, path .. " source")
			end
			local realKids = real:GetChildren()
			local emuKids = rt:runIn(nil, function()
				return emu:GetChildren()
			end)
			T.eq(#emuKids, #realKids, path .. " child count")
			for _, rc in realKids do
				local ec = emu:FindFirstChild(rc.Name)
				T.truthy(ec, path .. "." .. rc.Name .. " exists in the emulator")
				checked += 1
				compare(rc, ec, path .. "." .. rc.Name)
			end
		end
		for _, path in
			{
				{ "ReplicatedStorage", "Shared" },
				{ "ServerScriptService", "Server" },
				{ "StarterPlayer", "StarterPlayerScripts", "Client" },
			}
		do
			local real = place
			local emu = rt.game
			for _, seg in path do
				real = real:FindFirstChild(seg)
				emu = emu:FindFirstChild(seg)
			end
			T.truthy(real and emu, table.concat(path, "."))
			compare(real, emu, table.concat(path, "."))
		end
		T.truthy(checked > 80, "compared " .. checked .. " instances")
		local players = place:FindFirstChild("Players")
		T.eq(players and players.CharacterAutoLoads, true, "Players.CharacterAutoLoads")
	end)
end)

-- Emulator self-checks: these are the behaviours that make "zero errors" meaningful.
T.describe("Runtime emulator fidelity", function()
	local client
	T.it("a client boots with its own module cache and context", function()
		local _, c = rt:addPlayer({ userId = 77, name = "Probe" })
		client = c
		rt:advance(3)
		local shared = rt:find("ReplicatedStorage.Shared.Net")
		T.truthy(client.moduleCache[shared], "client required Net")
		T.truthy(client.moduleCache[shared].value ~= rt.server.moduleCache[shared].value, "separate caches")
		T.eq(
			rt:runIn(client, function()
				return rt.game:GetService("RunService"):IsClient()
			end),
			true
		)
		T.eq(
			rt:runIn(client, function()
				return rt.game:GetService("Players").LocalPlayer.Name
			end),
			"Probe"
		)
		T.eq(rt.game:GetService("Players").LocalPlayer, nil, "no LocalPlayer on the server")
	end)

	T.it("unknown members, bad property types and read-only writes raise", function()
		-- LobbyWorld keeps the lobby model's name (LobbyWorld.NAME = "LobbyPad");
		-- LobbyService's own fallback pad is a "LobbyPad" model too (SquadPad1..4).
		local p = rt:runIn(rt.server, function()
			return rt.workspace:FindFirstChild("LobbyPad")
		end)
		T.truthy(p and p:IsA("Model"), "LobbyPad model (LobbyWorld or the SquadPad fallback)")
		T.truthy(
			rt:runIn(rt.server, function()
				return p:FindFirstChild("SquadPad1", true) ~= nil or #p:GetChildren() > 4
			end),
			"the lobby model has its squad pads / dressing"
		)
		T.throws(function()
			local _x = (p :: any).NoSuchChild
		end)
		T.throws(function()
			(p :: any).WorldPivot = "nope"
		end)
		T.throws(function()
			(rt.game:GetService("Players") :: any).LocalPlayer = p
		end)
		T.throws(function()
			p:SetAttribute("Bad", {})
		end)
		T.eq(
			rt:gaps()[#rt:gaps()],
			"member Model.NoSuchChild (not a property, emulated method/event, or child)"
		)
		-- the probe's expected gap
		table.clear(rt.S.gaps)
		table.clear(rt.S.gapSet)
	end)

	T.it("Terrain fills are validated and recorded; Lighting follows Roblox's rules", function()
		local terrain = rt.workspace.Terrain
		T.truthy(terrain and terrain.ClassName == "Terrain", "Workspace.Terrain is the Terrain")
		local stats = rt:terrainStats()
		T.truthy(stats.solidFills > 0, "the lobby island was filled: " .. stats.solidFills)
		T.truthy(stats.colorSets > 0, "SetMaterialColor was used")
		local before = #rt:gaps()
		T.throws(function()
			terrain:FillBlock(roblox.CFrame.new(), roblox.Vector3.new(4, 4, 4), roblox.Enum.Material.Plastic)
		end)
		T.throws(function()
			terrain:FillBall(roblox.Vector3.new(0 / 0, 0, 0), 4, roblox.Enum.Material.Grass)
		end)
		T.throws(function()
			terrain:SetMaterialColor(roblox.Enum.Material.Water, roblox.Color3.new())
		end)
		terrain:FillBall(roblox.Vector3.new(0, -500, 0), 8, roblox.Enum.Material.Rock)
		T.eq(rt:terrainStats().byMaterial.Rock ~= nil, true, "a fill is recorded by material")
		T.eq(terrain:GetMaterialColor(roblox.Enum.Material.Mud), roblox.Color3.fromRGB(58, 46, 36))
		terrain.WaterWaveSize = 0.3
		T.near(terrain.WaterWaveSize, 0.3, 1e-6)
		-- not scriptable on Roblox: Roblox's error, NOT an emulator gap
		T.throws(function()
			terrain.Decoration = true
		end)
		local lighting = rt.game:GetService("Lighting")
		T.eq(lighting.Technology, roblox.Enum.Technology.Future, "Technology from default.project.json")
		T.throws(function()
			lighting.Technology = roblox.Enum.Technology.Voxel
		end)
		T.eq(lighting.LightingStyle, roblox.Enum.LightingStyle.Realistic)
		for _, cls in
			{
				"Atmosphere",
				"Sky",
				"BloomEffect",
				"ColorCorrectionEffect",
				"SunRaysEffect",
				"DepthOfFieldEffect",
			}
		do
			T.truthy(lighting:FindFirstChildOfClass(cls), "lobby mood has " .. cls)
		end
		T.eq(#rt:gaps(), before, "no emulator gaps from Roblox-rule errors")
	end)

	T.it("handler errors are recorded with a traceback, not swallowed", function()
		local before = #rt:errors()
		rt:runIn(rt.server, function()
			local be = Inst.new("BindableEvent")
			be.Event:Connect(function()
				error("probe failure")
			end)
			be:Fire()
		end)
		rt:advance(0.1)
		T.eq(#rt:errors(), before + 1, "one recorded error")
		local e = rt:errors()[#rt:errors()]
		T.truthy(string.find(e.message, "probe failure", 1, true), e.message)
		table.remove(rt:errors()) -- expected
	end)

	T.it("string requires resolve on the instance tree and cycles are detected", function()
		local rs = rt:find("ReplicatedStorage.Shared.Run.RunState")
		local mod = rt:require(rt.server, rs)
		T.truthy(type(mod.new) == "function", "RunState via ../ requires")
		local a = rt:asServer(function()
			local folder = Inst.new("Folder")
			folder.Name = "CycleProbe"
			local ma = Inst.make("ModuleScript", { name = "A" })
			Inst.D[ma].extra.source = 'return require("./B")'
			Inst.D[ma].extra.path = "probe/A.luau"
			ma.Parent = folder
			local mb = Inst.make("ModuleScript", { name = "B" })
			Inst.D[mb].extra.source = 'return require("./A")'
			Inst.D[mb].extra.path = "probe/B.luau"
			mb.Parent = folder
			folder.Parent = rt.game:GetService("ReplicatedStorage")
			return ma
		end)
		local before = #rt:errors()
		local ok, err = pcall(rt.require, rt, rt.server, a)
		T.falsy(ok, "cycle must fail")
		T.truthy(string.find(tostring(err), "experienced an error", 1, true), tostring(err))
		local found = false
		for i = before + 1, #rt:errors() do
			if string.find(rt:errors()[i].message, "required recursively", 1, true) then
				found = true
			end
		end
		T.truthy(found, "recursive require reported")
		while #rt:errors() > before do
			table.remove(rt:errors())
		end
	end)

	T.it("remotes copy arguments with Roblox semantics", function()
		local Net = rt:serverModule("ReplicatedStorage.Shared.Net")
		local toast = rt:find("ReplicatedStorage.Remotes." .. Net.S2C.Toast)
		local player = rt.players[1]
		rt:runIn(rt.server, function()
			-- deliberately un-Roblox-like payloads: a numeric-keyed dictionary and a mixed table
			local mixed: any = { 1, 2 }
			mixed.extra = true
			toast:FireClient(player, { [1001] = "x" }, mixed)
		end)
		rt:advance(0.2)
		local last = client.inbox.Toast.last
		T.eq(last[1]["1001"], "x", "numeric dictionary keys become strings")
		T.eq(last[2][1], 1)
		T.eq(last[2].extra, nil, "mixed table loses its dictionary part")
		local warned = false
		for _, w in rt.S.warnings do
			if string.find(w.message, "REMOTE LOSSY", 1, true) then
				warned = true
			end
		end
		T.truthy(warned, "lossy remote recorded")
		local keep = {}
		for _, w in rt.S.warnings do
			if not string.find(w.message, "REMOTE LOSSY", 1, true) then
				table.insert(keep, w)
			end
		end
		rt.S.warnings = keep
	end)

	T.it("client-created instances are invisible to the server", function()
		rt:runIn(client, function()
			local f = Inst.new("Folder")
			f.Name = "ClientOnlyProbe"
			f.Parent = rt.workspace
		end)
		T.eq(rt.workspace:FindFirstChild("ClientOnlyProbe"), nil, "server can't see it")
		T.truthy(
			rt:runIn(client, function()
				return rt.workspace:FindFirstChild("ClientOnlyProbe")
			end),
			"client sees it"
		)
	end)

	T.it("still clean after the probes", function()
		rt:advance(2)
		rt:assertClean(nil, "after probes")
	end)
end)

return T.finish()
