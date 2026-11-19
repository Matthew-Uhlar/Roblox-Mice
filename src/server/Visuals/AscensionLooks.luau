--!strict
-- AscensionLooks (iter2, team G): the elephant looks unlocked by Ascension
-- nodes 2, 4 and 8 (docs/iter/2/ALIGNMENT.md, H4).
--
--   AscensionLooks.add(model, look, colors) -> {BasePart}
--       look = "bull" (node 2) | "matriarch" (node 4) | "ancient" (node 8).
--       Each look includes the ones below it. Parts are built in BotModel's unit
--       space (feet at the origin, facing -Z) and tagged with a "Bone" attribute,
--       so BotModel's rig and the client animator move them with the head / body
--       / ears. Call it BEFORE BotModel scales and rigs the model.
--   AscensionLooks.lookFor(node: number?) -> string?    1-8 -> highest look owned
--   AscensionLooks.ORDER = {"bull", "matriarch", "ancient"}
--
-- Data contract: the server sets the attribute "AscLook" ("bull" | "matriarch"
-- | "ancient", or a node number) on the Player (or the character) for heroes
-- and on the bot spec; HeroDecor / BotModel read it. Part budget: bull +11,
-- matriarch +16 more, ancient +22 more (heroes and bots are not in the arena budget).
--
--   Bull:      big curved bronze-capped tusks, a riveted forehead plate, a gold
--              nose ring, shoulder pauldrons.
--   Matriarch: a flower garland round the neck, a jewelled headdress, gold ear
--              cuffs, an embroidered back blanket.
--   Ancient:   mammoth-length spiral tusks, shaggy fur along the back and flanks,
--              glowing blue runes, a crown of small tusks and a soft aura.

local Build = require(script.Parent.Build)

local AscensionLooks = {}

AscensionLooks.ORDER = { "bull", "matriarch", "ancient" }
AscensionLooks.NODES = { bull = 2, matriarch = 4, ancient = 8 }

local M = Enum.Material
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local rad = math.rad
local rgb = Color3.fromRGB

local BRONZE = rgb(176, 120, 60)
local GOLD = rgb(255, 201, 60)
local IVORY = rgb(250, 244, 226)
local FUR = rgb(120, 82, 52)
local FUR_DARK = rgb(92, 62, 40)
local RUNE = rgb(110, 220, 255)

function AscensionLooks.lookFor(node: any): string?
	if type(node) == "string" then
		return if AscensionLooks.NODES[node] then node else nil
	end
	local n = tonumber(node) or 0
	if n >= 8 then
		return "ancient"
	elseif n >= 4 then
		return "matriarch"
	elseif n >= 2 then
		return "bull"
	end
	return nil
end

local function rank(look: string?): number
	return if look == "ancient" then 3 elseif look == "matriarch" then 2 elseif look == "bull" then 1 else 0
end

function AscensionLooks.add(m: Model, look: string?, colors: any): { BasePart }
	local r = rank(look)
	local out: { BasePart } = {}
	if r <= 0 then
		return out
	end
	local accent = (colors and colors.accent) or GOLD
	local function put(p: BasePart, bone: string): BasePart
		p:SetAttribute("Bone", bone)
		p:SetAttribute("AscLook", true)
		table.insert(out, p)
		return p
	end
	local NOSH = { shadow = false }

	-- Bull ---------------------------------------------------------------------
	for _, s in { -1, 1 } do
		-- curved tusk: three segments sweeping out and up, bronze cap
		local base = CF(s * 1.05, 4.0, -4.6) * ANG(rad(-70), 0, rad(s * -18))
		local seg1 = base * CF(0, 0.6, 0)
		put(Build.ucyl(m, 1.3, 0.5, seg1, IVORY, M.Marble), "head")
		local seg2 = base * CF(0, 1.2, 0) * ANG(rad(-25), 0, rad(s * -10)) * CF(0, 0.55, 0)
		put(Build.ucyl(m, 1.1, 0.42, seg2, IVORY, M.Marble), "head")
		put(Build.ball(m, 0.5, seg2 * CF(0, 0.6, 0), BRONZE, M.Metal, NOSH), "head")
		-- pauldron on the shoulder
		put(
			Build.egg(
				m,
				V3(1.8, 0.9, 2.2),
				CF(s * 2.05, 4.65, -0.9) * ANG(0, 0, rad(s * -25)),
				BRONZE,
				M.Metal
			),
			"body"
		)
	end
	-- forehead plate with rivets
	local brow = CF(0, 6.25, -4.55) * ANG(rad(-35), 0, 0)
	put(Build.block(m, V3(1.8, 1.3, 0.25), brow, BRONZE, M.Metal), "head")
	for _, dx in { -0.6, 0, 0.6 } do
		put(Build.ball(m, 0.22, brow * CF(dx, -0.4, -0.14), GOLD, M.Metal, NOSH), "head")
	end
	-- gold nose ring through the trunk root
	put(Build.cyl(m, 0.12, 0.9, CF(0, 3.55, -5.25) * ANG(0, rad(90), 0), GOLD, M.Metal, NOSH), "trunk")
	if r < 2 then
		return out
	end

	-- Matriarch ------------------------------------------------------------------
	local flowers = { rgb(255, 120, 160), rgb(255, 230, 120), rgb(255, 255, 255), rgb(190, 140, 255) }
	for k = 0, 7 do
		local a = rad(-70) + k / 7 * rad(140) -- an arc under the chin and over the neck sides
		local p = CF(math.sin(a) * 2.15, 3.85 + math.cos(a * 2) * 0.15, -2.6 - math.cos(a) * 1.2)
		put(Build.ball(m, 0.62, p, flowers[(k % #flowers) + 1], M.SmoothPlastic, NOSH), "body")
	end
	-- headdress: a gold band with a big gem
	local band = CF(0, 6.9, -3.6) * ANG(rad(-20), 0, 0)
	put(Build.block(m, V3(3.0, 0.32, 0.3), band, GOLD, M.Metal), "head")
	put(Build.ball(m, 0.75, band * CF(0, 0.35, -0.2), accent, M.Glass, NOSH), "head")
	for _, s in { -1, 1 } do
		put(Build.ball(m, 0.4, band * CF(s * 1.1, 0.15, -0.1), rgb(150, 220, 255), M.Glass, NOSH), "head")
		-- ear cuffs
		local ear = CF(s * 2.65, 5.05, -2.45) * ANG(0, rad(s * -30), rad(s * 12))
		put(
			Build.cyl(m, 0.3, 0.7, ear * CF(s * 1.2, -1.1, 0.05) * ANG(0, rad(90), 0), GOLD, M.Metal, NOSH),
			if s < 0 then "earL" else "earR"
		)
	end
	-- embroidered blanket over the saddle with tassels
	put(
		Build.block(m, V3(5.0, 0.18, 2.6), CF(0, 5.55, 0.9), accent:Lerp(rgb(120, 40, 60), 0.4), M.Fabric),
		"body"
	)
	put(Build.block(m, V3(5.1, 0.2, 0.3), CF(0, 5.6, -0.4), GOLD, M.Fabric, NOSH), "body")
	for _, s in { -1, 1 } do
		put(
			Build.block(
				m,
				V3(0.25, 1.4, 2.4),
				CF(s * 2.55, 4.95, 0.9),
				accent:Lerp(rgb(120, 40, 60), 0.4),
				M.Fabric
			),
			"body"
		)
		put(Build.ball(m, 0.35, CF(s * 2.6, 4.1, 0.2), GOLD, M.Fabric, NOSH), "body")
		put(Build.ball(m, 0.35, CF(s * 2.6, 4.1, 1.6), GOLD, M.Fabric, NOSH), "body")
	end
	if r < 3 then
		return out
	end

	-- Ancient ----------------------------------------------------------------------
	for _, s in { -1, 1 } do
		-- mammoth spiral tusks: a long curl forward and up
		local cf = CF(s * 1.15, 3.9, -4.7) * ANG(rad(-80), 0, rad(s * -14))
		for k = 1, 4 do
			cf = cf * CF(0, 0.7, 0) * ANG(rad(-14), 0, rad(s * -12))
			put(Build.ucyl(m, 0.8, 0.55 - k * 0.07, cf, IVORY, M.Marble), "head")
		end
		put(Build.ball(m, 0.45, cf * CF(0, 0.45, 0), GOLD, M.Metal, NOSH), "head")
		-- shaggy flank fur
		for k = 0, 2 do
			put(
				Build.wedge(
					m,
					V3(0.5, 1.6, 1.4),
					CF(s * 2.4, 3.2, -0.8 + k * 1.3) * ANG(0, rad(s * 90), 0),
					if k % 2 == 0 then FUR else FUR_DARK,
					M.Fabric
				),
				"body"
			)
		end
		-- runes on the flanks
		put(Build.block(m, V3(0.08, 1.2, 0.2), CF(s * 2.3, 3.6, 1.6), RUNE, M.Neon, NOSH), "body")
		put(Build.block(m, V3(0.08, 0.2, 0.9), CF(s * 2.3, 3.6, 1.6), RUNE, M.Neon, NOSH), "body")
	end
	-- fur ridge along the back
	for k = 0, 3 do
		put(
			Build.wedge(
				m,
				V3(1.6, 1.1, 1.0),
				CF(0, 6.0, -1.4 + k * 1.0),
				if k % 2 == 0 then FUR else FUR_DARK,
				M.Fabric
			),
			"body"
		)
	end
	-- crown of small tusks
	for k = -1, 1 do
		put(
			Build.wedge(
				m,
				V3(0.35, 0.9, 0.35),
				CF(k * 0.7, 7.55, -3.35) * ANG(0, 0, rad(k * -15)),
				IVORY,
				M.Marble,
				NOSH
			),
			"head"
		)
	end
	local core = put(Build.ball(m, 0.5, CF(0, 6.3, -4.75), RUNE, M.Neon, NOSH), "head")
	Build.emitter(core, {
		name = "AncientAura",
		texture = Build.TEX.sparkles,
		color = Build.cs(RUNE, rgb(255, 255, 255)),
		size = Build.ns(0.5, 0),
		transparency = Build.ns(0.2, 1),
		lifetime = NumberRange.new(1, 1.6),
		rate = 6,
		speed = NumberRange.new(1, 2),
		lightEmission = 1,
	})
	return out
end

return AscensionLooks
