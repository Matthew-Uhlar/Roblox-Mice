-- Per-map budget spec (iter4, team G): every arena, at today's stage-1 radius
-- and at the iter4 big-map radius (x1.35, up to 760), stays inside the mobile
-- budgets with the new biome terrain and the doubled POIs:
--   * <= 3,400 BaseParts (Rind Gate included) and <= 30 PointLights;
--   * POI parts <= ArenaBuilder.POI_BUDGET + one POI of overshoot;
--   * biome colliders <= 180, and every river map has >= 2 bridges;
--   * the "Heights" attribute decodes to the built plateaus, and heightAt is
--     the plateau height at a plateau centre and 0 at the boss pad.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")

local rt = Runtime.new({ root = ".", dt = 1 / 30 })
rt:startServer()
rt:advance(2)

local ArenaBuilder = rt:serverModule("ServerScriptService.Server.Services.ArenaBuilder")
local Biomes = rt:serverModule("ServerScriptService.Server.Visuals.Biomes")
local Maps = rt:serverModule("ReplicatedStorage.Shared.Config.Maps")
local Pois = rt:serverModule("ReplicatedStorage.Shared.Combat.Pois")
local Rng = rt:serverModule("ReplicatedStorage.Shared.Util.Rng")

local function build(id: string, seed: number, R: number?): any
	return rt:asServer(function()
		local layout = Pois.layout(Rng.new(seed):fork(0x9017), id, Pois.arenaRadius(id))
		local info = ArenaBuilder.build(id, seed, { pois = layout, radius = R })
		ArenaBuilder.buildPortal(0, 0)
		return info
	end)
end

local function count(root: any): (number, number, number)
	local parts, lights, poi = 0, 0, 0
	rt:runIn(nil, function()
		local poiFolder = root:FindFirstChild("POIs")
		for _, d in root:GetDescendants() do
			if d:IsA("BasePart") then
				parts += 1
				if poiFolder and d:IsDescendantOf(poiFolder) then
					poi += 1
				end
			elseif d:IsA("PointLight") then
				lights += 1
			end
		end
	end)
	return parts, lights, poi
end

T.describe("MapBudget", function()
	T.it("every map, at the stage-1 and the x1.35 radius, keeps its budgets", function()
		for i, id in Maps.ORDER do
			local def = Maps.get(id)
			local base = Maps.stageRadius and Maps.stageRadius(id, 1) or def.size
			for _, R in { base, math.clamp(base * 1.35, 400, 760) } do
				local info = build(id, 31 * i + math.floor(R), R)
				local parts, lights, poi = count(info.model)
				local tag = string.format("%s R=%d", id, R)
				T.truthy(parts <= 3400, tag .. ": " .. parts .. " parts <= 3400")
				T.truthy(lights <= 30, tag .. ": " .. lights .. " PointLights <= 30")
				T.truthy(
					poi <= ArenaBuilder.POI_BUDGET + 250,
					tag .. ": " .. poi .. " POI parts within the POI budget"
				)
				local biome = info.biome
				T.truthy(biome ~= nil, tag .. ": biome built")
				if biome then
					T.truthy(biome.colliders <= 180, tag .. ": " .. biome.colliders .. " colliders <= 180")
					local layout = Biomes.LAYOUTS[id]
					if layout and layout.river then
						T.truthy(#biome.bridges >= 2, tag .. ": a river map has >= 2 bridges")
					end
					local decoded = Biomes.decode(info.model:GetAttribute("Heights"))
					T.eq(#decoded, #biome.heights, tag .. ": Heights attribute round-trips")
					for _, p in biome.heights do
						T.eq(ArenaBuilder.heightAt(p.x, p.z), p.h, tag .. ": plateau top height")
					end
					T.eq(ArenaBuilder.heightAt(0, 0), 0, tag .. ": the boss pad is flat")
				end
				print(string.format("  %s: %d parts, %d lights, POIs %d", tag, parts, lights, poi))
			end
		end
		rt:assertClean(nil, "map budgets")
	end)
end)

return T.finish()
