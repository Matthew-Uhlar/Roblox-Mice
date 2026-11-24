--!strict
-- Mesh pipeline (assets/models/PLAN.md): every mouse enemy and boss has a
-- procedural mesh (scripts/make-meshes.py) listed in assets/models/manifest.json (iter7: adopted at runtime by
-- Visuals/MeshModels; each mesh is split into animation pieces named after the Rig bones)
-- as a Model named mouse_<enemyId> / boss_<bossId>, and every listed mesh file
-- exists. Champions (their own ids) and hero_elephant are checked too.
local T = require("../lib/Test")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Enemies = require("../../src/shared/Config/Enemies")
local Bosses = require("../../src/shared/Config/Bosses")
local Champions = require("../../src/shared/Config/Champions")
-- Visuals/Rig needs Roblox datatypes: read its bone list from the source
local Rig = { INDEX = {} :: { [string]: number } }
do
	local src = fs.readFile("src/client/Visuals/Rig.luau")
	local list = string.match(src, "Rig%.BONES = (%b{})") or ""
	local i = 0
	for n in string.gmatch(list, '"(%w+)"') do
		i += 1
		Rig.INDEX[n] = i
	end
end

local BASE = "assets/models/"
local manifest = serde.decode("json", fs.readFile(BASE .. "manifest.json")) :: { any }
local info = serde.decode("json", fs.readFile(BASE .. "meshes/meshes.json")) :: { [string]: any }

local byName: { [string]: any } = {}
for _, e in manifest do
	byName[e.name] = e
end

local function checkEntry(name: string, budget: number)
	local e = byName[name]
	T.truthy(e, name .. " is in the manifest")
	T.eq(e.type, "Model", name .. " type")
	T.truthy(string.match(e.path, "%.glb$"), name .. " is a .glb")
	T.truthy(fs.isFile(BASE .. e.path), name .. " file exists: " .. e.path)
	local m = info[name]
	T.truthy(m, name .. " is in meshes/meshes.json")
	T.truthy(m.triangles > 0 and m.triangles <= budget, name .. " triangle budget " .. tostring(m.triangles))
end

-- glTF node names of a .glb (one node per animation piece)
local function glbNodes(path: string): { string }
	local data = fs.readFile(BASE .. path)
	local jsonLen = string.unpack("<I4", data, 13)
	local gltf = serde.decode("json", string.sub(data, 21, 20 + jsonLen)) :: any
	local out = {}
	for _, n in gltf.nodes do
		table.insert(out, n.name)
	end
	return out
end

local function pieces(name: string): { [string]: any }
	local m = info[name]
	local out = {}
	for _, pc in m.pieces or {} do
		out[pc.name] = pc
	end
	return out
end

-- iter7: the pieces the client animator expects (Visuals/Rig bones).
local function expectPieces(name: string, want: { string })
	local have = pieces(name)
	for _, n in want do
		T.truthy(have[n], name .. " has piece " .. n)
	end
end

T.describe("MeshManifest", function()
	T.it("every mouse enemy has mouse_<id>", function()
		for _, id in Enemies.ORDER do
			checkEntry("mouse_" .. id, 1500)
		end
	end)
	T.it("every boss has boss_<id>", function()
		for _, id in Bosses.ORDER do
			checkEntry("boss_" .. id, 8000)
		end
	end)
	T.it("every champion has a mesh named by its id", function()
		for _, id in Champions.ORDER do
			checkEntry(id, 8000)
		end
	end)
	T.it("hero_elephant exists with the BotModel bones", function()
		checkEntry("hero_elephant", 5000)
		expectPieces(
			"hero_elephant",
			{ "body", "head", "trunk", "earL", "earR", "tail", "legFL", "legFR", "legBL", "legBR" }
		)
	end)
	-- iteration 8 (team Mesh)
	T.it("every class has a weapon mesh wpn_<classId> (grip space)", function()
		local Classes = require("../../src/shared/Config/Classes")
		for _, id in Classes.ORDER do
			checkEntry("wpn_" .. id, 900)
			T.eq(info["wpn_" .. id].kind, "weapon")
		end
	end)
	T.it("builds, props and objectives have meshes", function()
		checkEntry("build_turret", 1500)
		checkEntry("build_barricade", 1500)
		expectPieces("build_turret", { "body", "head" })
		for _, n in { "prop_totem", "prop_stall", "prop_class_stall", "prop_altar", "prop_swap" } do
			checkEntry(n, 2500)
		end
		local src = fs.readFile("src/server/Visuals/ObjectiveModels.luau")
		local n = 0
		for id in string.gmatch(src, "\nB%.([%w_]+) = function") do
			checkEntry("obj_" .. id, 2500)
			n += 1
		end
		T.truthy(n >= 4, "objective ids found: " .. n)
	end)
	T.it("every obstacle kind has a landmark lm_<kind> (+ ruins)", function()
		local src = fs.readFile("src/server/Visuals/Props.luau")
		local block = string.match(src, "Props%.OBSTACLES = (%b{})") or ""
		local n = 0
		for kind in string.gmatch(block, "([%w_]+) = Props") do
			checkEntry("lm_" .. kind, 800)
			n += 1
		end
		T.truthy(n >= 14, "obstacle kinds: " .. n)
		checkEntry("lm_pillar", 800)
		checkEntry("lm_mesa", 800)
	end)
	T.it("every Model entry's file exists and is a glTF binary", function()
		for _, e in manifest do
			if e.type == "Model" then
				T.truthy(fs.isFile(BASE .. e.path), e.name .. ": " .. e.path)
				T.eq(string.sub(fs.readFile(BASE .. e.path), 1, 4), "glTF", e.name .. " magic")
			end
		end
	end)
	T.it("every mesh is split into named animation pieces (glb nodes = meshes.json pieces)", function()
		for name, m in info do
			local creature = m.kind == "mouse" or m.kind == "boss" or m.kind == "champ" or m.kind == "hero"
			T.truthy(
				type(m.pieces) == "table" and #m.pieces >= (if creature then 2 else 1),
				name .. " has pieces"
			)
			local nodes = glbNodes(m.path)
			T.eq(#nodes, #m.pieces, name .. " node count")
			local sum = 0
			for i, pc in m.pieces do
				T.eq(nodes[i], pc.name, name .. " node " .. i)
				sum += pc.tris
				T.truthy(
					#pc.center == 3 and #pc.size == 3 and #pc.joint == 3,
					name .. "." .. pc.name .. " bounds"
				)
				-- a piece rides a Rig bone (by name or `bone`) or plays its own channel
				local bone = pc.bone or pc.name
				T.truthy(
					Rig.INDEX[bone] ~= nil or pc.anim ~= nil or pc.neon == true,
					name .. "." .. pc.name .. " is animated"
				)
				if pc.parent then
					T.truthy(Rig.INDEX[pc.parent], name .. "." .. pc.name .. " parent bone")
				end
			end
			T.eq(sum, m.triangles, name .. " piece triangles add up")
			T.eq(m.pieces[1].name, "body", name .. " body first")
		end
	end)
	T.it("mice have the MouseModels rig pieces and an elite-only crown", function()
		for _, id in Enemies.ORDER do
			local name = "mouse_" .. id
			expectPieces(
				name,
				{ "body", "head", "earL", "earR", "tail", "legFL", "legFR", "legBL", "legBR", "crown" }
			)
			local crown = pieces(name).crown
			T.eq(crown.cond, "elite", name .. " crown cond")
			T.eq(crown.bone, "head", name .. " crown bone")
		end
		T.truthy(pieces("mouse_fuse_mouse").spark.neon, "fuse spark is Neon")
		T.truthy(pieces("mouse_crumb_slinger").weapon, "slingshot piece")
	end)
	T.it("champions have the biped rig pieces", function()
		for _, id in Champions.ORDER do
			expectPieces(id, { "body", "legFL", "legFR" })
		end
		for _, id in { "champ_captain", "champ_ratking", "champ_sniper", "champ_chemist" } do
			expectPieces(id, { "head", "earL", "earR", "armL", "armR", "weapon" })
		end
	end)
	T.it("bosses have animated pieces (wheels spin, wings flap)", function()
		for _, id in Bosses.ORDER do
			local n = 0
			for _, pc in info["boss_" .. id].pieces do
				if pc.anim then
					n += 1
				end
			end
			T.truthy(n >= 1, "boss_" .. id .. " has an animated piece")
		end
		T.eq(pieces("boss_zoomzola").wheel.anim.kind, "spin", "zoomzola wheel")
		T.eq(pieces("boss_floating_witch").wheel.anim.kind, "spin", "witch wheel")
		T.eq(pieces("boss_ice_dragon").wingL.anim.kind, "roll", "dragon wings")
	end)
	T.it("the rig table (Shared/Config/MeshData) lists every mesh", function()
		local src = fs.readFile("src/shared/Config/MeshData.luau")
		for name in info do
			T.truthy(string.find(src, '["' .. name .. '"]', 1, true), "MeshData has " .. name)
			T.truthy(type(info[name].shift) == "table" and #info[name].shift == 3, name .. " shift")
		end
	end)
	T.it("names are unique", function()
		local seen: { [string]: boolean } = {}
		for _, e in manifest do
			T.falsy(seen[e.name], "duplicate " .. tostring(e.name))
			seen[e.name] = true
		end
	end)
end)

return T.finish()
