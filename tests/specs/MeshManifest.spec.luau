--!strict
-- Mesh pipeline (assets/models/PLAN.md): every mouse enemy and boss has a
-- procedural mesh (scripts/make-meshes.py) listed in assets/models/manifest.meshes.json (parked until iteration 7 adopts the meshes at runtime; then merged into manifest.json)
-- as a Model named mouse_<enemyId> / boss_<bossId>, and every listed mesh file
-- exists. Champions (their own ids) and hero_elephant are checked too.
local T = require("../lib/Test")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Enemies = require("../../src/shared/Config/Enemies")
local Bosses = require("../../src/shared/Config/Bosses")
local Champions = require("../../src/shared/Config/Champions")

local BASE = "assets/models/"
local manifest = serde.decode("json", fs.readFile(BASE .. "manifest.meshes.json")) :: { any }
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
	T.it("hero_elephant exists", function()
		checkEntry("hero_elephant", 5000)
	end)
	T.it("every Model entry's file exists and is a glTF binary", function()
		for _, e in manifest do
			if e.type == "Model" then
				T.truthy(fs.isFile(BASE .. e.path), e.name .. ": " .. e.path)
				T.eq(string.sub(fs.readFile(BASE .. e.path), 1, 4), "glTF", e.name .. " magic")
			end
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
