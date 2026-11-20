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
	-- iter3 (T-28): 12 clearly separated hues; cut by band (GemArt.cutFor)
	{ name = "Curd", color = rgb(236, 228, 196), glow = rgb(255, 250, 225) },
	{ name = "Whey Jade", color = rgb(110, 215, 110), glow = rgb(180, 255, 170) },
	{ name = "Brie Aquamarine", color = rgb(50, 205, 225), glow = rgb(150, 245, 255) },
	{ name = "Gouda Sapphire", color = rgb(55, 100, 240), glow = rgb(130, 165, 255) },
	{ name = "Edam Amethyst", color = rgb(140, 85, 240), glow = rgb(195, 150, 255) },
	{ name = "Smoked Orchid", color = rgb(225, 80, 205), glow = rgb(255, 150, 240) },
	{ name = "Stilton Rose", color = rgb(255, 120, 150), glow = rgb(255, 185, 200) },
	{ name = "Pungent Amber", color = rgb(255, 150, 35), glow = rgb(255, 200, 100) },
	{ name = "Scorched Ruby", color = rgb(235, 45, 45), glow = rgb(255, 120, 100) },
	{ name = "Moldy Emerald", color = rgb(25, 150, 85), glow = rgb(110, 240, 160) },
	{ name = "Doomwheel Obsidian", color = rgb(70, 25, 75), glow = rgb(255, 60, 90) },
	{ name = "Golden Wheel", color = rgb(255, 201, 60), glow = rgb(255, 240, 160) },
}

-- Cut by tier band: "wedge" 1-4 (a cheese-wedge crystal), "wheel" 5-8 (a round
-- brilliant with a rind band), "crown" 9-12 (a brilliant with a spiked crown).
function GemArt.cutFor(tier: any): string
	local t = math.clamp(math.floor(tonumber(tier) or 1), 1, 12)
	return if t <= 4 then "wedge" elseif t <= 8 then "wheel" else "crown"
end

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

function GemArt.build(parent: Instance, tier: any, cf: CFrame, size: number?, unique: boolean?): { BasePart }
	local t = tierOf(tier)
	local s = size or 1
	local col, glow = GemArt.color(t), GemArt.glow(t)
	local out = {}
	local cut = GemArt.cutFor(t)
	local G = Enum.Material.Glass
	if cut == "wedge" then
		-- a cheese-wedge crystal: two wedge halves, a bright top facet and the core
		local w = cf * ANG(0, math.rad(30), 0)
		table.insert(out, part(parent, nil, V3(0.7, 0.9, 1.1) * s, w * CF(0.18 * s, 0, 0), col, G, 0.08))
		table.insert(
			out,
			part(
				parent,
				nil,
				V3(0.7, 0.9, 1.1) * s,
				w * CF(-0.18 * s, 0, 0),
				col:Lerp(rgb(0, 0, 0), 0.15),
				G,
				0.08
			)
		)
		local top = w * CF(0, 0.12 * s, 0.1 * s) * ANG(math.rad(-39), 0, 0)
		table.insert(out, part(parent, Enum.PartType.Block, V3(1.05, 0.06, 1.2) * s, top, glow, G, 0.25))
		table.insert(
			out,
			part(parent, Enum.PartType.Ball, V3(0.36, 0.36, 0.36) * s, cf, glow, Enum.Material.Neon, 0)
		)
	else
		local n = if cut == "crown" then 8 else 6
		-- crown (upper, short) and pavilion (lower, long) facets as wedges round the axis
		for k = 0, n - 1 do
			local a = k / n * math.pi * 2
			local w = 2 * math.sin(math.pi / n) * 0.5 * s * 1.02
			local up = cf * ANG(0, a, 0) * CF(0, 0.18 * s, -0.25 * s) * ANG(math.rad(180), 0, 0)
			table.insert(
				out,
				part(parent, nil, V3(w, 0.36 * s, 0.5 * s), up, col:Lerp(rgb(255, 255, 255), 0.15), G, 0.15)
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
					G,
					0.1
				)
			)
		end
		table.insert(
			out,
			part(parent, Enum.PartType.Ball, V3(0.45, 0.45, 0.45) * s, cf, glow, Enum.Material.Neon, 0)
		)
		if cut == "wheel" then
			local band = cf * CF(0, -0.02 * s, 0) * ANG(0, 0, math.pi / 2)
			table.insert(
				out,
				part(
					parent,
					Enum.PartType.Cylinder,
					V3(0.12, 1.08, 1.08) * s,
					band,
					col:Lerp(rgb(255, 255, 255), 0.4),
					G,
					0.2
				)
			)
		else
			for k = 0, 4 do
				local a = k / 5 * math.pi * 2
				local spike = cf * ANG(0, a, 0) * CF(0, 0.5 * s, -0.32 * s)
				table.insert(
					out,
					part(parent, nil, V3(0.12, 0.42, 0.14) * s, spike, glow, Enum.Material.Neon, 0.05)
				)
			end
		end
	end
	if unique then
		local halo = cf * ANG(0, 0, math.pi / 2)
		table.insert(
			out,
			part(
				parent,
				Enum.PartType.Cylinder,
				V3(0.06, 1.6, 1.6) * s,
				halo,
				rgb(255, 201, 60),
				Enum.Material.Neon,
				0.6
			)
		)
	end
	return out
end

return GemArt
