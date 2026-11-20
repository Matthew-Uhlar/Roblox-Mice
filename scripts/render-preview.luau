--!nocheck
-- render-preview.luau (R4 Graphics): exports the geometry the real builders make,
-- for scripts/render-preview.py to draw as PNG contact sheets (no Studio needed).
--
--   lune run scripts/render-preview.luau <outDir>
--
-- Runs the real server modules (ArenaBuilder, LobbyWorld, BotModel) inside the
-- headless runtime emulator (tests/runtime) and the client model builders
-- (src/client/Visuals/MouseModels, BossModels) as plain modules, then writes one
-- JSON scene per subject: every BasePart (class, shape, size, CFrame, colour,
-- material, transparency, sphere-mesh flag), every PointLight / SpotLight, and
-- every Terrain fill call (recorded by stub Terrain methods registered here, so
-- tests/runtime itself is not modified).

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Inst = require("../tests/runtime/Instance")
local Runtime = require("../tests/runtime/Runtime")

local outDir = process.args[1] or "assets/previews/_scenes"
fs.writeDir(outDir)

-- Terrain recorder ---------------------------------------------------------------------------
local ops = {}
local function cfList(cf)
	return { cf:GetComponents() }
end
local function v3(v)
	return { v.X, v.Y, v.Z }
end
local T = Inst.reg(Inst.METHODS, "Terrain")
function T.FillBlock(_, cf, size, mat)
	table.insert(ops, { op = "block", cf = cfList(cf), size = v3(size), mat = mat.Name })
end
function T.FillBall(_, c, r, mat)
	table.insert(ops, { op = "ball", c = v3(c), r = r, mat = mat.Name })
end
function T.FillCylinder(_, cf, h, r, mat)
	table.insert(ops, { op = "cyl", cf = cfList(cf), h = h, r = r, mat = mat.Name })
end
function T.FillWedge(_, cf, size, mat)
	table.insert(ops, { op = "wedge", cf = cfList(cf), size = v3(size), mat = mat.Name })
end
local matColors = {}
function T.SetMaterialColor(_, mat, col)
	matColors[mat.Name] = { col.R, col.G, col.B }
end
function T.GetMaterialColor(_, mat)
	local c = matColors[mat.Name]
	return if c then roblox.Color3.new(c[1], c[2], c[3]) else roblox.Color3.new(0.5, 0.5, 0.5)
end
function T.Clear()
	table.clear(ops)
end

local rt = Runtime.new({ root = "." })

local function partRecord(p)
	local shape = "Block"
	local cls = p.ClassName
	if cls == "Part" or cls == "SpawnLocation" then
		shape = p.Shape.Name
	elseif cls == "WedgePart" then
		shape = "Wedge"
	elseif cls == "CornerWedgePart" then
		shape = "CornerWedge"
	end
	local mesh = p:FindFirstChildOfClass("SpecialMesh")
	if mesh and mesh.MeshType == roblox.Enum.MeshType.Sphere then
		shape = "Egg"
	end
	return {
		shape = shape,
		size = v3(p.Size),
		cf = cfList(p.CFrame),
		color = { p.Color.R, p.Color.G, p.Color.B },
		mat = p.Material.Name,
		t = p.Transparency,
	}
end

local function collect(root, scene)
	scene.parts = scene.parts or {}
	scene.lights = scene.lights or {}
	local list = root:GetDescendants()
	if root:IsA("BasePart") then
		table.insert(list, root)
	end
	for _, d in list do
		if d:IsA("BasePart") then
			if d.Transparency < 0.99 then
				table.insert(scene.parts, partRecord(d))
			end
		elseif d:IsA("PointLight") or d:IsA("SpotLight") then
			local parent = d.Parent
			if parent and parent:IsA("BasePart") then
				table.insert(scene.lights, {
					p = v3(parent.Position),
					color = { d.Color.R, d.Color.G, d.Color.B },
					range = d.Range,
					brightness = d.Brightness,
				})
			end
		end
	end
	return scene
end

local function lightingSnapshot()
	local L = rt.game:GetService("Lighting")
	local a = L:FindFirstChild("TrunkfallAtmosphere")
	local cc = L:FindFirstChild("TrunkfallGrade")
	return {
		clock = L.ClockTime,
		brightness = L.Brightness,
		ambient = { L.OutdoorAmbient.R, L.OutdoorAmbient.G, L.OutdoorAmbient.B },
		shift = { L.ColorShift_Top.R, L.ColorShift_Top.G, L.ColorShift_Top.B },
		atmo = if a
			then {
				density = a.Density,
				haze = a.Haze,
				color = { a.Color.R, a.Color.G, a.Color.B },
				decay = { a.Decay.R, a.Decay.G, a.Decay.B },
			}
			else nil,
		grade = if cc
			then {
				contrast = cc.Contrast,
				saturation = cc.Saturation,
				tint = { cc.TintColor.R, cc.TintColor.G, cc.TintColor.B },
			}
			else nil,
	}
end

local function write(name, scene)
	fs.writeFile(outDir .. "/" .. name .. ".json", serde.encode("json", scene))
	print(
		string.format(
			"%-22s parts=%5d lights=%3d terrainOps=%4d",
			name,
			#(scene.parts or {}),
			#(scene.lights or {}),
			#(scene.terrain or {})
		)
	)
end

local only = process.args[2]

local result = rt:asServer(function()
	local ArenaBuilder = rt:serverModule("ServerScriptService.Server.Services.ArenaBuilder")
	local LobbyWorld = rt:serverModule("ServerScriptService.Server.Services.LobbyWorld")
	local Maps = rt:serverModule("ReplicatedStorage.Shared.Config.Maps")
	local Pois = rt:serverModule("ReplicatedStorage.Shared.Combat.Pois")
	local Rng = rt:serverModule("ReplicatedStorage.Shared.Util.Rng")
	local BotModel = rt:serverModule("ServerScriptService.Server.Visuals.BotModel")

	for _, mapId in Maps.ORDER do
		if only and only ~= mapId then
			continue
		end
		table.clear(ops)
		local seed = 1234
		local layout = Pois.layout(Rng.new(seed):fork(7), mapId, Pois.arenaRadius(mapId))
		local arena = ArenaBuilder.build(mapId, seed, { pois = layout })
		-- v4: the client's streamed micro decor (Visuals/GroundScatter) around the
		-- gameplay-camera focus, so the close-up shows what a player sees
		local scatter = nil
		local okScatter, errScatter = pcall(function()
			local GS = rt:serverModule("StarterPlayer.StarterPlayerScripts.Client.Visuals.GroundScatter")
			GS.init(false, false)
			local sz = arena.safeZones[3] or { x = 0, z = arena.radius * 0.5 }
			GS.step(1, roblox.Vector3.new(sz.x * 0.7, 0, sz.z * 0.7))
			scatter = rt.workspace:FindFirstChild("TrunkfallScatter")
		end)
		if not okScatter then
			print("  (no ground scatter: " .. tostring(errScatter) .. ")")
		end
		local scene = collect(arena.model, {
			kind = "arena",
			name = mapId,
			radius = arena.radius,
			obstacles = arena.obstacles,
			safeZones = arena.safeZones,
			terrain = table.clone(ops),
			matColors = table.clone(matColors),
		})
		if scatter then
			local extra = collect(scatter, { kind = "object", name = "scatter" })
			for _, p in extra.parts do
				if p.cf[2] > -100 then
					table.insert(scene.parts, p)
				end
			end
			scatter:Destroy()
		end
		scene.lighting = lightingSnapshot()
		write("map_" .. mapId, scene)
		ArenaBuilder.buildPortal(0, 0, roblox.Color3.fromRGB(255, 204, 51))
		local portal = arena.model:FindFirstChild(ArenaBuilder.PORTAL_NAME)
		write("portal_" .. mapId, collect(portal, { kind = "object", name = "portal" }))
		ArenaBuilder.clear()
	end

	if not only or only == "lobby" then
		table.clear(ops)
		local lobby = LobbyWorld.build()
		local scene = collect(lobby.model, {
			kind = "lobby",
			name = "lobby",
			center = v3(lobby.center),
			terrain = table.clone(ops),
			matColors = table.clone(matColors),
		})
		scene.lighting = lightingSnapshot()
		write("lobby", scene)
	end

	if not only or only == "pois" then
		local PoiModels = rt:serverModule("ServerScriptService.Server.Visuals.PoiModels")
		local PoiDefs = rt:serverModule("ReplicatedStorage.Shared.Config.Pois")
		local ids = {
			"armory",
			"cheese_vault",
			"power_totem",
			"shop_cart",
			"cheese_cache",
			"shrine_swift",
			"shrine_might",
			"shrine_mending",
			"elite_camp",
			"crumb_fountain",
			"mousetrap_field",
			"grandmas_pantry",
			"lost_herd_statue",
			"giant_cowbell",
			"gouda_wheel_hut",
			"pepper_idol",
			"message_bottle",
			"frozen_mammoth",
			"molten_fondue",
			"witch_hut",
			"crashed_rocket",
			"sunken_chest",
			-- iter4 objectives
			"caravan",
			"beacon",
			"rescue_cage",
			"miniboss_camp",
		}
		for _, id in ids do
			local m = Inst.make("Model", { name = "POI_" .. id })
			local def = PoiDefs.get(id)
			local c = def and def.color or { 255, 200, 60 }
			local glow = roblox.Color3.fromRGB(c[1], c[2], c[3])
			local entry = { kind = id, x = 0, z = 0, r = 6 }
			if id == "mousetrap_field" then
				entry.traps = { { x = 0, z = 0 }, { x = 4, z = 2 }, { x = -3, z = 3 }, { x = 2, z = -4 } }
			end
			PoiModels.build(m, id, 0, 0, roblox.Color3.fromRGB(250, 220, 110), glow, Rng.new(7), entry)
			write("poi_" .. id, collect(m, { kind = "object", name = id }))
		end
	end

	if not only or only == "bots" then
		local Classes = rt:serverModule("ReplicatedStorage.Shared.Config.Classes")
		local BotAnimator = rt:serverModule("StarterPlayer.StarterPlayerScripts.Client.Visuals.BotAnimator")
		local Rig = rt:serverModule("StarterPlayer.StarterPlayerScripts.Client.Visuals.Rig")
		for i, cid in Classes.ORDER do
			local m = BotModel.build({ id = -1000 - i, name = cid, classId = cid }, ((i - 1) % 4) + 1)
			write("bot_" .. cid, collect(m, { kind = "object", name = cid }))
			-- posed: the client's BotAnimator rewrites each RigWeld's C0
			local r = BotAnimator.compile(m)
			if r then
				local poses = {
					idle = function(st)
						st.t = 0.7
					end,
					walk = function(st)
						st.t = 1.2
						st.moving = 1
						st.gait = math.pi / 2
					end,
					attack = function(st)
						st.t = 1.5
						st.swingKind = BotAnimator.SWING[cid] or "melee"
						st.swing = 0.42 -- iter1: the hit frame (after the anticipation)
					end,
					ability = function(st)
						st.t = 1.5
						st.cast = 0.3
					end,
					downed = function(st)
						st.t = 2
						st.downed = 1
					end,
				}
				for _, pose in { "idle", "walk", "attack", "ability", "downed" } do
					local st = Rig.newState(0)
					poses[pose](st)
					Rig.pose("elephant", st, r.D, r.scale or 1, 1)
					Rig.solve(r.rig, roblox.CFrame.identity, r.D, r.A)
					local scene = { kind = "object", name = cid, parts = {}, lights = {} }
					local rootCF = if pose == "downed"
						then roblox.CFrame.new(0, 1.4, 0) * roblox.CFrame.Angles(0, 0, math.rad(80))
						else roblox.CFrame.identity
					for wi, w in r.welds do
						local part = w.Part1
						local b = r.rig.partBone[wi]
						local c0 = if b ~= 0 then r.A[b] * r.rig.partLocal[wi] else w.C0
						local rec = partRecord(part)
						rec.cf = cfList(rootCF * c0)
						if part.Transparency < 0.99 then
							table.insert(scene.parts, rec)
						end
					end
					write("botpose_" .. cid .. "_" .. pose, scene)
				end
			end
		end
		-- v4: player heroes = a blocky R15 stand-in avatar wearing the elephant hood
		-- (HeroDecor.apply with a squad = during a run), BodyColors baked into the
		-- part colours as Roblox would draw them.
		local HeroDecor = rt:serverModule("ServerScriptService.Server.Visuals.HeroDecor")
		local R15 = {
			{ "HumanoidRootPart", { 2, 2, 1 }, { 0, 3, 0 }, nil, 1 },
			{ "Head", { 1.2, 1.2, 1.2 }, { 0, 5.1, 0 }, "HeadColor3" },
			{ "UpperTorso", { 2, 1.6, 1 }, { 0, 3.7, 0 }, "TorsoColor3" },
			{ "LowerTorso", { 2, 0.4, 1 }, { 0, 2.7, 0 }, "TorsoColor3" },
			{ "LeftUpperArm", { 1, 1.2, 1 }, { -1.5, 3.8, 0 }, "LeftArmColor3" },
			{ "RightUpperArm", { 1, 1.2, 1 }, { 1.5, 3.8, 0 }, "RightArmColor3" },
			{ "LeftHand", { 1, 0.9, 1 }, { -1.5, 2.75, 0 }, "LeftArmColor3" },
			{ "RightHand", { 1, 0.9, 1 }, { 1.5, 2.75, 0 }, "RightArmColor3" },
			{ "LeftUpperLeg", { 1, 2.5, 1 }, { -0.5, 1.25, 0 }, "LeftLegColor3" },
			{ "RightUpperLeg", { 1, 2.5, 1 }, { 0.5, 1.25, 0 }, "RightLegColor3" },
		}
		for i, cid in Classes.ORDER do
			local char = Inst.make("Model", { name = "Hero_" .. cid })
			local bc = Inst.make("BodyColors", { name = "Body Colors" })
			for _, prop in
				{
					"HeadColor3",
					"TorsoColor3",
					"LeftArmColor3",
					"RightArmColor3",
					"LeftLegColor3",
					"RightLegColor3",
				}
			do
				bc[prop] = roblox.Color3.fromRGB(245, 205, 150)
			end
			bc.TorsoColor3 = roblox.Color3.fromRGB(60, 120, 200)
			bc.Parent = char
			for _, d in R15 do
				local part = Inst.make("Part", { name = d[1] })
				part.Size = roblox.Vector3.new(d[2][1], d[2][2], d[2][3])
				part.CFrame = roblox.CFrame.new(d[3][1], d[3][2], d[3][3])
				part.Transparency = d[5] or 0
				part.Anchored = true
				part.Parent = char
			end
			HeroDecor.apply(char, cid, nil, ((i - 1) % 4) + 1)
			for _, d in R15 do
				local part = char:FindFirstChild(d[1])
				if part and d[4] then
					part.Color = bc[d[4]]
				end
			end
			write("hero_" .. cid, collect(char, { kind = "object", name = cid }))
		end
		-- iter2: Ascension looks (nodes 2 / 4 / 8) on the Herd Suit
		for _, look in { "bull", "matriarch", "ancient" } do
			local am = BotModel.build(
				{ id = 0, name = look, classId = "elephante", ascLook = look },
				1,
				{ suit = true }
			)
			write("asc_" .. look, collect(am, { kind = "object", name = look }))
		end
		-- iter2: Cheese Gems (client Visuals/GemArt), one per tier
		pcall(function()
			local GemArt = rt:serverModule("StarterPlayer.StarterPlayerScripts.Client.Visuals.GemArt")
			for t = 1, 12 do
				local gm = Inst.make("Model", { name = "Gem" .. t })
				GemArt.build(gm, t, roblox.CFrame.new(0, 1.2, 0), 1.6, t >= 11)
				write(string.format("gem_t%02d", t), collect(gm, { kind = "object", name = "tier " .. t }))
			end
		end)
		local ClassSkins = rt:serverModule("ReplicatedStorage.Shared.Config.ClassSkins")
		local done = {}
		for _, skin in ClassSkins.LIST do
			if not done[skin.accessory] then
				done[skin.accessory] = true
				local m = BotModel.build(
					{ id = -1999, name = skin.id, classId = skin.classId, skinId = skin.id },
					1
				)
				write("skin_" .. skin.accessory, collect(m, { kind = "object", name = skin.accessory }))
			end
		end
	end
	return true
end)

-- Client models: plain modules that return part specs.
local function specRecord(s, cf)
	return {
		shape = s.shape,
		size = v3(s.size),
		cf = cfList(cf),
		color = { s.color.R, s.color.G, s.color.B },
		mat = (s.material or roblox.Enum.Material.SmoothPlastic).Name,
		t = s.transparency or 0,
	}
end

local function specScene(name, spec, elite)
	local scene = { kind = "object", name = name, parts = {}, lights = {} }
	for _, s in spec.parts do
		if (s.transparency or 0) < 0.99 and (s.cond ~= "elite" or elite) then
			table.insert(scene.parts, specRecord(s, s.offset))
		end
	end
	return scene
end

-- Poses for the v3 rigs (Visuals/Rig): idle, mid-walk, attack.
local POSES = {
	idle = function(st)
		st.t = 0.6
	end,
	walk = function(st)
		st.t = 1.3
		st.moving = 1
		st.gait = math.pi / 2
	end,
	attack = function(st, style)
		st.t = 2.1
		if style == "mouse" then
			st.lunge = 0.33
		elseif style == "elephant" then
			st.swing = 0.55
		else
			st.windup = 1
		end
	end,
	strike = function(st)
		st.t = 2.4
		st.strike = 0.3
	end,
	cast = function(st)
		st.t = 2.4
		st.cast = 0.3
	end,
	roar = function(st)
		st.t = 2.4
		st.roar = 0.25
	end,
	dead = function(st)
		st.t = 3
		st.dead = 0.7
	end,
}

local function posedScene(Rig, name, model, poseName, elite)
	local scene = { kind = "object", name = name, parts = {}, lights = {} }
	local style = model.style or "mouse"
	local c = Rig.compile(model.parts, model.bones)
	local st = Rig.newState(0)
	st.aim = model.aim or 0
	st.variant = model.variant
	POSES[poseName](st, style)
	local D, A = Rig.newPose(), {}
	local k = model.scaleK or 1
	Rig.pose(style, st, D, k, 1)
	local root = Rig.rootPose(style, st, k)
	Rig.solve(c, root, D, A)
	for i, s in model.parts do
		if (s.transparency or 0) < 0.99 and (s.cond ~= "elite" or elite) then
			local cf = if s.ground then s.offset else Rig.place(c, i, root, A)
			if s.anim and s.anim.kind ~= "pulse" and s.anim.kind ~= "bob" then
				-- legacy channel: apply its rest-relative pose on top
				local Spec = model.Spec
				if Spec then
					cf = cf * s.offset:ToObjectSpace(Spec.pose(s, st.t, st.moving))
				end
			end
			table.insert(scene.parts, specRecord(s, cf))
		end
	end
	return scene
end

local POSE_SET = { "idle", "walk", "attack" }

if not only or only == "mice" or only == "bosses" or only == "champs" then
	rt:asServer(function()
		local Enemies = rt:serverModule("ReplicatedStorage.Shared.Config.Enemies")
		local Bosses = rt:serverModule("ReplicatedStorage.Shared.Config.Bosses")
		local MouseModels = rt:serverModule("StarterPlayer.StarterPlayerScripts.Client.Visuals.MouseModels")
		local BossModels = rt:serverModule("StarterPlayer.StarterPlayerScripts.Client.Visuals.BossModels")
		local Rig = rt:serverModule("StarterPlayer.StarterPlayerScripts.Client.Visuals.Rig")
		local Spec = rt:serverModule("StarterPlayer.StarterPlayerScripts.Client.Visuals.Spec")
		if not only or only == "mice" then
			for _, id in Enemies.ORDER do
				local def = Enemies.get(id)
				local m = MouseModels.build(id, def, 1, false)
				m.scaleK = m.radius / 1.2
				for _, pose in POSE_SET do
					write("mouse_" .. id .. "_" .. pose, posedScene(Rig, id, m, pose, false))
				end
				local me = MouseModels.build(id, def, 1.3, true)
				me.scaleK = me.radius / 1.2
				write("mouse_" .. id .. "_elite", posedScene(Rig, id, me, "walk", true))
				write("mouse_" .. id .. "_lod", specScene(id, { parts = m.lod }))
				write(
					"mouse_" .. id .. "_low",
					posedScene(
						Rig,
						id,
						{ parts = m.low, bones = m.bones, style = "mouse", scaleK = m.scaleK },
						"walk",
						false
					)
				)
			end
		end
		if not only or only == "bosses" then
			for _, id in Bosses.ORDER do
				local b = BossModels.build(id, Bosses.get(id))
				write("boss_" .. id, specScene(id, b))
				do
					-- root pose layer (HordeRenderer: k = radius * 0.8) + idle channels
					b.Spec = Spec
					b.style = "boss"
					b.scaleK = b.radius * 0.8
					b.variant = Rig.BOSS_VARIANTS and Rig.BOSS_VARIANTS[id] or nil
					for _, pose in { "walk", "attack", "strike", "roar", "dead" } do
						write("bosspose_" .. id .. "_" .. pose, posedScene(Rig, id, b, pose, false))
					end
				end
			end
		end
		if not only or only == "champs" then
			local okC, ChampionModels =
				pcall(rt.serverModule, rt, "StarterPlayer.StarterPlayerScripts.Client.Visuals.ChampionModels")
			if okC and ChampionModels then
				for _, id in ChampionModels.ORDER do
					local m = ChampionModels.build(id, nil)
					m.scaleK = m.k
					for _, pose in { "idle", "walk", "attack", "strike", "roar" } do
						write("champ_" .. id .. "_" .. pose, posedScene(Rig, id, m, pose, false))
					end
				end
			end
		end
	end)
end

print("done", result)
