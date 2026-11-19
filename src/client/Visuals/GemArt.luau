--!strict
-- GemArt (iter2, team G, client): how Cheese Gems look (docs/iter/2/ALIGNMENT.md A2).
--
--   GemArt.TIERS[1..12] = {name, color, glow}   one cut and colour per tier
--   GemArt.color(tier) -> Color3, GemArt.glow(tier) -> Color3
--   GemArt.icon(tier) -> string?       uploaded icon "rbxassetid://..." (Config/AssetIds
--                                      "gem_t<tier>", made by assets/gems/make-gems.py), or nil
--   GemArt.build(parent, tier, cf, size, unique?) -> {BasePart}   a faceted 3-D gem:
--       crown + pavilion wedges, a glass body and a neon core (6-14 parts); a unique
--       gem gets a gold halo ring. For ViewportFrames (U) and world drops.
--
-- The drop VFX lives in Visuals/Juice (Juice.gemDrop), fired by FxController for
-- Fx `gemDrop` {x, z, tier, unique?, id?} (M2 emits it) and removed on `gemGone`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GemArt = {}

local rgb = Color3.fromRGB
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

-- Tier 1 (Mild) .. 11 (Doomwheel), 12 = the Golden Wheel. Colours climb the
-- rarity ladder: pale -> blue -> purple -> orange -> red -> gold.
GemArt.TIERS = {
	{ name = "Curd", color = rgb(222, 222, 210), glow = rgb(255, 255, 240) },
	{ name = "Whey Quartz", color = rgb(170, 230, 190), glow = rgb(200, 255, 215) },
	{ name = "Brie Beryl", color = rgb(120, 210, 255), glow = rgb(170, 230, 255) },
	{ name = "Gouda Topaz", color = rgb(78, 168, 255), glow = rgb(140, 200, 255) },
	{ name = "Edam Sapphire", color = rgb(70, 110, 240), glow = rgb(130, 160, 255) },
	{ name = "Smoked Amethyst", color = rgb(150, 100, 240), glow = rgb(190, 150, 255) },
	{ name = "Stilton Opal", color = rgb(190, 90, 230), glow = rgb(230, 150, 255) },
	{ name = "Pungent Garnet", color = rgb(230, 80, 150), glow = rgb(255, 140, 200) },
	{ name = "Scorched Amber", color = rgb(255, 140, 40), glow = rgb(255, 190, 90) },
	{ name = "Moldy Emerald", color = rgb(60, 200, 110), glow = rgb(150, 255, 170) },
	{ name = "Doomwheel Ruby", color = rgb(235, 40, 50), glow = rgb(255, 110, 100) },
	{ name = "Golden Wheel", color = rgb(255, 201, 60), glow = rgb(255, 240, 160) },
}

local function tierOf(t: any): number
	return math.clamp(math.floor(tonumber(t) or 1), 1, #GemArt.TIERS)
end

function GemArt.color(tier: any): Color3
	return GemArt.TIERS[tierOf(tier)].color
end

function GemArt.glow(tier: any): Color3
	return GemArt.TIERS[tierOf(tier)].glow
end

function GemArt.name(tier: any): string
	return GemArt.TIERS[tierOf(tier)].name
end

local assetIds: any = nil
function GemArt.icon(tier: any): string?
	if assetIds == nil then
		local ok, mod = pcall(function()
			local cfg = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
			local inst = cfg:FindFirstChild("AssetIds")
			return if inst then require(inst) :: any else nil
		end)
		assetIds = if ok and type(mod) == "table" then mod else {}
	end
	local id = tonumber(assetIds["gem_t" .. tostring(tierOf(tier))])
	return if id and id > 0 then "rbxassetid://" .. tostring(math.floor(id)) else nil
end

local function part(
	parent: Instance,
	shape: Enum.PartType?,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	mat: Enum.Material,
	t: number?
): BasePart
	local p: BasePart
	if shape == nil then
		p = Instance.new("WedgePart")
	else
		local pp = Instance.new("Part")
		pp.Shape = shape
		p = pp
	end
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = mat
	p.Transparency = t or 0
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

-- Higher tiers get more facets (4 / 6 / 8 around).
function GemArt.build(parent: Instance, tier: any, cf: CFrame, size: number?, unique: boolean?): { BasePart }
	local t = tierOf(tier)
	local s = size or 1
	local col, glow = GemArt.color(t), GemArt.glow(t)
	local out = {}
	local n = if t >= 9 then 8 elseif t >= 5 then 6 else 4
	-- crown (upper, short) and pavilion (lower, long) facets as wedges round the axis
	for k = 0, n - 1 do
		local a = k / n * math.pi * 2
		local w = 2 * math.sin(math.pi / n) * 0.5 * s * 1.02
		local up = cf * ANG(0, a, 0) * CF(0, 0.18 * s, -0.25 * s) * ANG(math.rad(180), 0, 0)
		table.insert(
			out,
			part(
				parent,
				nil,
				V3(w, 0.36 * s, 0.5 * s),
				up,
				col:Lerp(rgb(255, 255, 255), 0.15),
				Enum.Material.Glass,
				0.15
			)
		)
		local down = cf * ANG(0, a, 0) * CF(0, -0.42 * s, -0.25 * s)
		table.insert(
			out,
			part(
				parent,
				nil,
				V3(w, 0.84 * s, 0.5 * s),
				down * ANG(math.rad(180), math.rad(180), 0),
				col,
				Enum.Material.Glass,
				0.1
			)
		)
	end
	table.insert(
		out,
		part(parent, Enum.PartType.Ball, V3(0.45, 0.45, 0.45) * s, cf, glow, Enum.Material.Neon, 0)
	)
	if unique then
		table.insert(
			out,
			part(
				parent,
				Enum.PartType.Cylinder,
				V3(0.06, 1.5, 1.5) * s,
				cf * ANG(0, 0, math.pi / 2),
				rgb(255, 201, 60),
				Enum.Material.Neon,
				0.2
			)
		)
	end
	return out
end

return GemArt
