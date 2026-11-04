-- Runtime emulator: every arena builds cleanly, in sequence, on one server
-- (QC-A M1 and minor 7). The emulator validates each Terrain fill like Roblox
-- (terrain-only materials, finite numbers), so a theme that uses a Part-only
-- material (ocean's old Enum.Material.Pebble) fails here with a warning. Also
-- checks that a terrain failure on one map does not switch terrain off for the
-- maps after it, and the per-map part and PointLight budgets.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")
local roblox = require("@lune/roblox")
local CFrame, Vector3, Enum = roblox.CFrame, roblox.Vector3, roblox.Enum

local rt = Runtime.new({ root = ".", dt = 1 / 30 })
rt:startServer()
rt:advance(2)

local ArenaBuilder = rt:serverModule("ServerScriptService.Server.Services.ArenaBuilder")
local Terra = rt:serverModule("ServerScriptService.Server.Visuals.Terra")
local Maps = rt:serverModule("ReplicatedStorage.Shared.Config.Maps")
local Pois = rt:serverModule("ReplicatedStorage.Shared.Combat.Pois")
local Rng = rt:serverModule("ReplicatedStorage.Shared.Util.Rng")

local function fills(): number
	local ts = rt:terrainStats()
	return if ts then ts.fills else 0
end

local function solidFills(): number
	local ts = rt:terrainStats()
	return if ts then ts.solidFills else 0
end

local function build(id: string, seed: number): any
	return rt:asServer(function()
		local layout = Pois.layout(Rng.new(seed):fork(0x9017), id, Pois.arenaRadius(id))
		local info = ArenaBuilder.build(id, seed, { pois = layout })
		-- the Rind Gate is built into the arena later in the stage: count it too
		ArenaBuilder.buildPortal(0, 0)
		return info
	end)
end

local function count(root: any): (number, number)
	local parts, lights = 0, 0
	rt:runIn(nil, function()
		for _, d in root:GetDescendants() do
			if d:IsA("BasePart") then
				parts += 1
			elseif d:IsA("PointLight") then
				lights += 1
			end
		end
	end)
	return parts, lights
end

T.describe("RuntimeArenas", function()
	T.it("all 9 arenas build in sequence with working terrain and no warnings", function()
		T.eq(#Maps.ORDER, 9, "9 maps")
		-- ocean first: the map that used to break terrain for the rest of the server
		local order = { "ocean" }
		for _, id in Maps.ORDER do
			if id ~= "ocean" then
				table.insert(order, id)
			end
		end
		table.insert(order, "ocean")
		for i, id in order do
			local before, solidBefore = fills(), solidFills()
			local info = build(id, 1000 + i)
			T.truthy(info and info.model, id .. " built a model")
			T.truthy(Terra.ok(), id .. ": terrain still enabled after the build")
			T.truthy(fills() - before >= 20, id .. ": terrain fills made (" .. (fills() - before) .. ")")
			T.truthy(solidFills() - solidBefore >= 10, id .. ": solid terrain fills made")
			local floor = info.model:FindFirstChild("Floor")
			T.eq(floor and floor.Transparency, 1, id .. ": the flat fallback floor stays hidden (terrain OK)")
			rt:assertClean(nil, "arena " .. id)
		end
	end)

	T.it("every arena stays under 3,000 parts and 30 PointLights (portal included)", function()
		for i, id in Maps.ORDER do
			for seed = 1, 2 do
				local info = build(id, i * 7919 + seed)
				local parts, lights = count(info.model)
				T.truthy(parts < 3000, string.format("%s seed %d: %d parts < 3000", id, seed, parts))
				T.truthy(lights <= 30, string.format("%s seed %d: %d PointLights <= 30", id, seed, lights))
			end
		end
		rt:assertClean(nil, "budgets")
	end)

	T.it("a failed terrain fill is not permanent: the next build and clearBox still run", function()
		rt:asServer(function()
			-- Pebble is a Part material: Roblox (and the emulator) reject it in a fill
			Terra.cylinder(CFrame.new(0, -2, 0), 4, 10, Enum.Material.Pebble)
		end)
		local warned = false
		for _, w in rt.S.warnings do
			if string.find(w.message, "[Terra]", 1, true) then
				warned = true
			end
		end
		T.truthy(warned, "the bad fill warned")
		T.falsy(Terra.ok(), "the rest of that build is skipped")
		-- clearBox still clears (forced Air fills) while the failure stands
		local airBefore = (rt:terrainStats() or {}).airFills or 0
		rt:asServer(function()
			Terra.clearBox(Vector3.new(0, 0, 0), Vector3.new(64, 32, 64))
		end)
		T.truthy(((rt:terrainStats() or {}).airFills or 0) > airBefore, "clearBox ran after the failure")
		-- the next arena build retries terrain
		local before = fills()
		build("plains", 4242)
		T.truthy(Terra.ok(), "terrain back on for the next build")
		T.truthy(fills() - before >= 20, "the next build made its terrain fills")
		rt:assertClean({ "%[Terra%]" }, "after failure")
	end)
end)

return T.finish()
