-- iter7 (team Mesh): the real client renderer (Controllers/HordeRenderer +
-- Visuals/MeshModels) with and without procedural mesh assets.
--   * no assets: every mouse / champion is a part model, no errors.
--   * assets present (fake imported models in ReplicatedStorage.TrunkfallAssets:
--     one MeshPart per piece, re-centred on its bounds and at a foreign unit
--     scale, like the importer; ids added to the client's AssetIds): mice and
--     champions are built from MeshParts posed by the rig, the far LOD and the
--     fallback for a missing / broken template still use parts, hit flashes go
--     through the texture-swap tint (TextureID cleared, then restored).
--   * MeshModels directly: scale from MeshData radius, pivots from the authored
--     centres, boss anim channels, crown condition, paint round trip.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")
local Driver = require("../runtime/Driver")
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local INFO = serde.decode("json", fs.readFile("assets/models/meshes/meshes.json")) :: { [string]: any }
local IMPORT_SCALE = 3 -- the fake importer's unit scale (must not matter)
local TEX = "rbxassetid://424242"
local MISSING = "mouse_chonk" -- no template at all
local BROKEN = "mouse_carrier" -- template without its tail piece

local function scenario(withMeshes: boolean, meshesOff: boolean?)
	local rt = Runtime.new({ root = ".", dt = 1 / 30 })
	rt:startServer()
	local RD = rt:serverModule("ServerScriptService.Server.Services.RunDirector")
	RD.WAVE_SECONDS = 20
	Driver.powerUp(rt, 25)
	local G = rt:baseGlobals()
	if withMeshes then
		rt:asServer(function()
			local RS = G.game:GetService("ReplicatedStorage")
			local folder = RS:FindFirstChild("TrunkfallAssets") or G.Instance.new("Folder")
			folder.Name = "TrunkfallAssets"
			for name, e in INFO do
				if name == MISSING or type(e.pieces) ~= "table" then
					continue
				end
				local m = G.Instance.new("Model")
				m.Name = name
				for _, pc in e.pieces do
					if name == BROKEN and pc.name == "tail" then
						continue
					end
					local p = G.Instance.new("MeshPart")
					p.Name = pc.name
					p.Size = G.Vector3.new(pc.size[1], pc.size[2], pc.size[3]) * IMPORT_SCALE
					p.CFrame = G.CFrame.new(
						G.Vector3.new(pc.center[1], pc.center[2], pc.center[3]) * IMPORT_SCALE
							+ G.Vector3.new(7, 0, 3)
					)
					p.TextureID = TEX
					p.Parent = m
				end
				m.Parent = folder
			end
			folder.Parent = RS
		end)
	end
	rt:advance(1)
	local player, client = rt:addPlayer({ userId = 717171, name = "MeshTester" })
	rt:advance(2)
	if withMeshes then
		local ids = rt:require(client, rt:find("ReplicatedStorage.Shared.Config.AssetIds", client))
		for name in INFO do
			ids[name] = 1
		end
	end
	if meshesOff then
		-- the live kill switch (Shared.Config.Visuals.USE_MESHES), as a publish would set it
		rt:require(client, rt:find("ReplicatedStorage.Shared.Config.Visuals", client)).USE_MESHES = false
	end
	local horde = rt:clientModule(client, "Client.Controllers.HordeRenderer")
	Driver.autoplay(rt, client, function(kind)
		return if kind == "extract" then "Stay" elseif kind == "route" then "risk" else nil
	end)
	rt:setWalker(player, Driver.circleWalker(rt, 18, 10))
	rt:click(client, Driver.findButton(rt, client, "TrunkfallLobby", "READY"))
	T.truthy(
		rt:runUntil(function()
			return RD.getPhase() == "Waves"
		end, 30),
		"reached Waves"
	)
	rt:advance(24) -- mice, hits and the first champions
	local folder = rt:find("Workspace.TrunkfallHorde", client)
	local meshParts, parts, flat = 0, 0, 0
	rt:runIn(client, function()
		for _, x in folder:GetDescendants() do
			if x:IsA("BasePart") and x.Position.Y > -1000 and x.Transparency < 1 then
				if x:IsA("MeshPart") then
					meshParts += 1
					if x.TextureID == "" and x.Material ~= G.Enum.Material.Neon then
						flat += 1
					end
				else
					parts += 1
				end
			end
		end
	end)
	return {
		rt = rt,
		horde = horde,
		player = player,
		client = client,
		stats = table.clone(horde.meshStats),
		meshParts = meshParts,
		parts = parts,
		flatNow = flat,
		G = G,
	}
end

T.describe("HordeRenderer without mesh assets", function()
	local r = scenario(false)
	T.it("draws part models only, no errors", function()
		T.eq(r.stats.mesh, 0, "no mesh sets")
		T.truthy(r.stats.parts > 0, "part models built: " .. r.stats.parts)
		T.eq(r.meshParts, 0, "no MeshParts on screen")
		T.truthy(r.parts > 0, "parts on screen: " .. r.parts)
		r.rt:assertClean(nil, "no meshes")
	end)
end)

T.describe("HordeRenderer with mesh assets", function()
	local r = scenario(true)
	T.it("builds mice / champions from the meshes and falls back to parts", function()
		T.truthy(r.stats.mesh > 0, "mesh sets built: " .. r.stats.mesh)
		T.truthy(r.meshParts > 0, "MeshParts on screen: " .. r.meshParts)
		-- (which kinds spawn is random: the missing / broken fallbacks are checked directly below)
		T.truthy(r.stats.lod > 0, "far mice switched to the 3-part LOD: " .. r.stats.lod)
	end)
	T.it("hit flashes use the texture-swap tint", function()
		T.truthy(r.stats.flat > 0, "flat paints: " .. r.stats.flat)
	end)
	T.it("runs clean (only the broken-template warning)", function()
		r.rt:assertClean(
			{ "%[MeshModels%] " .. BROKEN .. " has no piece", "DataStore request was added to queue" },
			"meshes"
		)
	end)
	T.it("Settings > Models: Classic forces the part models and is saved", function()
		local State = r.rt:clientModule(r.client, "Client.Controllers.State")
		r.rt:runIn(r.client, function()
			State.setGfx("models", "classic")
		end)
		r.rt:advance(1)
		T.eq(r.horde.meshesAllowed(), false, "renderer honours the setting")
		local DataService = r.rt:serverModule("ServerScriptService.Server.Services.DataService")
		T.eq(DataService.get(r.player).settings.models, "classic", "saved as SetSetting models = classic")
		local before = r.horde.meshStats.mesh
		local partsBefore = r.horde.meshStats.parts
		r.rt:advance(10) -- new spawns (pooled mesh visuals are dropped)
		T.eq(r.horde.meshStats.mesh, before, "no new mesh sets")
		T.truthy(r.horde.meshStats.parts > partsBefore, "new part models")
		r.rt:runIn(r.client, function()
			State.setGfx("models", "detailed")
		end)
		r.rt:advance(1)
		T.eq(r.horde.meshesAllowed(), true, "back to Detailed")
		T.eq(DataService.get(r.player).settings.models, nil, "Detailed is stored as nil")
		r.rt:assertClean(
			{ "%[MeshModels%] " .. BROKEN .. " has no piece", "DataStore request was added to queue" },
			"models setting"
		)
	end)

	local MeshModels = r.rt:clientModule(r.client, "Client.Visuals.MeshModels")
	local G = r.G
	local function template(name: string): any
		return r.rt:find("ReplicatedStorage.TrunkfallAssets." .. name, r.client)
	end
	T.it("scales from MeshData radius and places pieces by their authored centres", function()
		local holder = r.rt:runIn(r.client, function()
			local f = G.Instance.new("Folder")
			f.Parent = G.workspace
			return f
		end)
		local e = INFO.mouse_mouse
		local b = r.rt:runIn(r.client, function()
			return MeshModels.build(template("mouse_mouse"), "mouse_mouse", 2.4, holder, true)
		end)
		T.truthy(b, "built")
		local s = 2.4 / e.radius
		local byName: { [string]: number } = {}
		for i, sp in b.specs do
			byName[sp.mesh] = i
		end
		for _, pc in e.pieces do
			local i = byName[pc.name]
			T.truthy(i, "piece " .. pc.name)
			local p = b.parts[i]
			T.truthy(math.abs(p.Size.X - pc.size[1] * s) < 1e-3, pc.name .. " size")
			local o = b.specs[i].offset.Position
			T.truthy(math.abs(o.Y - pc.center[2] * s) < 1e-3, pc.name .. " centre")
		end
		T.truthy(b.bones and b.bones.legFL and b.bones.head and b.bones.earL and b.bones.tail, "rig bones")
		T.eq(b.specs[byName.crown].cond, "elite", "crown is elite-only")
		T.eq(b.specs[byName.crown].bone, "head", "crown rides the head")
		-- paint round trip
		local i = byName.body
		r.rt:runIn(r.client, function()
			MeshModels.paint(b, i, G.Color3.new(1, 1, 1))
		end)
		T.eq(b.parts[i].TextureID, "", "flat while tinted")
		T.eq(b.parts[i].Color, G.Color3.new(1, 1, 1), "tint colour")
		r.rt:runIn(r.client, function()
			MeshModels.paint(b, i, nil)
		end)
		T.eq(b.parts[i].TextureID, TEX, "texture restored")
	end)
	T.it("bosses get their anim channels (wheel spin, wing flaps)", function()
		local holder = r.rt:runIn(r.client, function()
			local f = G.Instance.new("Folder")
			f.Parent = G.workspace
			return f
		end)
		for _, case in { { "boss_zoomzola", "wheel", "spin" }, { "boss_ice_dragon", "wingL", "roll" } } do
			local b = r.rt:runIn(r.client, function()
				return MeshModels.build(template(case[1]), case[1], 4, holder, false)
			end)
			T.truthy(b and b.animated, case[1] .. " animated")
			local found = false
			for _, sp in b.specs do
				if sp.mesh == case[2] then
					found = sp.anim and sp.anim.kind == case[3]
				end
				T.falsy(sp.bone, "boss pieces have no bones")
			end
			T.truthy(found, case[1] .. " " .. case[2] .. " " .. case[3])
		end
		T.eq(
			r.rt:runIn(r.client, function()
				return MeshModels.build(template(BROKEN), BROKEN, 1.2, holder, true)
			end),
			nil,
			"a template missing a piece falls back"
		)
	end)
end)

T.describe("Config/Visuals.USE_MESHES = false (live kill switch)", function()
	local r = scenario(true, true)
	T.it("assets present but every creature is a part model", function()
		T.eq(r.stats.mesh, 0, "no mesh sets")
		T.eq(r.meshParts, 0, "no MeshParts on screen")
		T.truthy(r.stats.parts > 0, "part models: " .. r.stats.parts)
		r.rt:assertClean({ "DataStore request was added to queue" }, "kill switch")
	end)
end)

T.describe("Rig / BotAnimator: iteration 7 classes and ability kinds", function()
	local rt = Runtime.new({ root = ".", dt = 1 / 30 })
	local Rig = rt:serverModule("StarterPlayer.StarterPlayerScripts.Client.Visuals.Rig")
	local BotAnimator = rt:serverModule("StarterPlayer.StarterPlayerScripts.Client.Visuals.BotAnimator")
	local B = Rig.B
	T.it("the new classes have attack styles", function()
		T.eq(BotAnimator.SWING.ele_vation, "snipe")
		T.eq(BotAnimator.SWING.elephaid, "shoot")
		T.eq(BotAnimator.SWING.trunkillery, "mortar")
	end)
	local function bodyPose(kind: string?, cast: number, hold: number): any
		local st = Rig.newState(0)
		st.cast = cast
		st.castKind = kind
		st.castHold = hold
		local D = Rig.newPose()
		Rig.pose("elephant", st, D, 1, 1)
		return D
	end
	T.it("every ability kind has its own cast pose", function()
		local generic = bodyPose(nil, 0.3, 0)
		for _, kind in
			{
				"lance",
				"tether",
				"anchor",
				"chain",
				"vortex",
				"leap",
				"mark",
				"turret",
				"barricade",
				"repair",
			}
		do
			T.truthy(Rig.CAST[kind], kind .. " in Rig.CAST")
			local D = bodyPose(kind, 0.3, 0)
			local diff = (D[B.body].Position - generic[B.body].Position).Magnitude
				+ (D[B.trunk].LookVector - generic[B.trunk].LookVector).Magnitude
			T.truthy(diff > 1e-3, kind .. " differs from the generic rear-up")
		end
		-- anchored: crouched lower than standing
		T.truthy(
			bodyPose("anchor", 0.5, 5)[B.body].Position.Y < bodyPose(nil, 0, 0)[B.body].Position.Y - 0.2,
			"dig-in"
		)
	end)
	T.it("held casts keep their pose for the ability duration, then release", function()
		local st = Rig.newState(0)
		st.cast, st.castKind, st.castHold = 0.001, "tether", 1.0
		for _ = 1, 20 do
			Rig.step(st, 0.025, 0, 1, 2.2)
		end
		T.truthy(st.cast > 0 and st.castHold > 0, "still channeling")
		for _ = 1, 120 do
			Rig.step(st, 0.025, 0, 1, 2.2)
		end
		T.eq(st.cast, 0, "released")
		T.eq(st.castKind, nil, "kind cleared")
	end)
end)

return T.finish()
