-- Pure parts of the client hero tags (team CLARITY): the shared squad palette
-- (Config/SquadColors: distinct under colour-blindness, ally vs enemy colours)
-- and Util/HeroTagMath (bar easing, damage chip, fade by distance).
local T = require("../lib/Test")
local SquadColors = require("../../src/shared/Config/SquadColors")
local Squads = require("../../src/shared/Util/Squads")
local HeroTagMath = require("../../src/client/Util/HeroTagMath")
local Scoreboard = require("../../src/client/Util/Scoreboard")

-- sRGB -> linear, a colour-blindness matrix (Machado et al. 2009, severity 1),
-- back to 0..255 sRGB; distance in that space.
local function lin(c: number): number
	c /= 255
	return if c <= 0.04045 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
end
local function srgb(c: number): number
	c = math.clamp(c, 0, 1)
	return 255 * (if c <= 0.0031308 then c * 12.92 else 1.055 * c ^ (1 / 2.4) - 0.055)
end
local MATS = {
	normal = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } },
	protan = {
		{ 0.152286, 1.052583, -0.204868 },
		{ 0.114503, 0.786281, 0.099216 },
		{ -0.003882, -0.048116, 1.051998 },
	},
	deutan = {
		{ 0.367322, 0.860646, -0.227968 },
		{ 0.280085, 0.672501, 0.047413 },
		{ -0.01182, 0.04294, 0.968881 },
	},
	tritan = {
		{ 1.255528, -0.076749, -0.178779 },
		{ -0.078411, 0.930809, 0.147602 },
		{ 0.004733, 0.691367, 0.3039 },
	},
}
local function sim(rgb: { number }, m: { { number } }): { number }
	local l = { lin(rgb[1]), lin(rgb[2]), lin(rgb[3]) }
	local out = {}
	for i = 1, 3 do
		out[i] = srgb(m[i][1] * l[1] + m[i][2] * l[2] + m[i][3] * l[3])
	end
	return out
end
local function dist(a: { number }, b: { number }): number
	return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
end

T.describe("SquadColors palette", function()
	T.it("has 4 named squad colours", function()
		T.eq(#SquadColors.LIST, 4)
		local names = {}
		for i, e in SquadColors.LIST do
			T.eq(e.id, i)
			T.truthy(type(e.name) == "string" and #e.name > 0)
			names[e.name] = true
			T.eq(#e.rgb, 3)
		end
		T.truthy(names.Gold and names.Sky and names.Rose and names.Mint, "Gold / Sky / Rose / Mint")
		T.eq(SquadColors.name(3), "Sky")
		T.eq(SquadColors.name(9), "Squad 9")
	end)
	T.it("stays distinct under protan, deutan and tritan vision", function()
		for kind, m in MATS do
			for i = 1, 4 do
				for j = i + 1, 4 do
					local d = dist(sim(SquadColors.rgb(i), m), sim(SquadColors.rgb(j), m))
					T.truthy(d >= 50, string.format("%s: squads %d/%d only %.0f apart", kind, i, j, d))
				end
			end
		end
	end)
	T.it("is the one source: Squads and the client Scoreboard defaults match it", function()
		for i = 1, 4 do
			T.deepEq(Squads.get(i).color, SquadColors.rgb(i), "Util/Squads " .. i)
			T.deepEq(Scoreboard.DEFAULTS[i].color, SquadColors.rgb(i), "Scoreboard.DEFAULTS " .. i)
		end
	end)
	T.it("rgb returns a copy and a neutral fallback", function()
		local c = SquadColors.rgb(1)
		c[1] = 0
		T.truthy(SquadColors.rgb(1)[1] ~= 0, "copy")
		T.deepEq(SquadColors.rgb(nil), SquadColors.NEUTRAL)
	end)
end)

T.describe("ally vs enemy colours", function()
	T.it("relation is viewer-relative", function()
		T.eq(SquadColors.relation(2, 2, true), "self")
		T.eq(SquadColors.relation(2, 2, false), "ally")
		T.eq(SquadColors.relation(2, 3, false), "enemy")
		T.eq(SquadColors.relation(nil, 3, false), "neutral")
		T.eq(SquadColors.relation(2, nil, false), "neutral")
	end)
	T.it("own squad green, enemies red, downed grey, unknown never green", function()
		T.deepEq(SquadColors.barColor("self"), SquadColors.ALLY_BAR)
		T.deepEq(SquadColors.barColor("ally"), SquadColors.ALLY_BAR)
		T.deepEq(SquadColors.barColor("enemy"), SquadColors.ENEMY_BAR)
		T.deepEq(SquadColors.barColor("neutral"), SquadColors.ENEMY_BAR)
		T.deepEq(SquadColors.barColor("ally", true), SquadColors.DOWNED_BAR)
		T.deepEq(SquadColors.barColor("enemy", true), SquadColors.DOWNED_BAR)
		local g, r = SquadColors.ALLY_BAR, SquadColors.ENEMY_BAR
		T.truthy(g[2] > g[1] and r[1] > r[2], "green is green, red is red")
	end)
	T.it("markers and down icons", function()
		T.eq(HeroTagMath.marker("ally"), "▼")
		T.eq(HeroTagMath.marker("enemy"), "")
		T.eq(HeroTagMath.marker("self"), "")
		T.eq(HeroTagMath.downIcon("ally"), "🩹")
		T.eq(HeroTagMath.downIcon("enemy"), "💀")
		T.eq(HeroTagMath.label("🤖 Tusk", 4), "🤖 Tusk · Lv 4")
		T.eq(HeroTagMath.label("Ann", nil), "Ann")
	end)
end)

T.describe("bar easing", function()
	T.it("ease reaches ~95% in EASE_TIME at any frame rate", function()
		for _, fps in { 30, 60, 144 } do
			local v = 1
			local dt = 1 / fps
			for _ = 1, math.floor(HeroTagMath.EASE_TIME * fps + 0.5) do
				v = HeroTagMath.ease(v, 0, dt)
			end
			T.near(v, 0.05, 0.02, "fps " .. fps)
		end
		T.eq(HeroTagMath.ease(0.5, 0.2, 0), 0.5, "dt 0 holds")
		T.eq(HeroTagMath.ease(0.5, 0.2, 1 / 60, 0), 0.2, "time 0 snaps")
		T.eq(HeroTagMath.ease(0 / 0, 0.3, 1 / 60), 0.3, "NaN shown recovers")
		T.eq(HeroTagMath.ease(0.4, 0 / 0, 1 / 60), 0.4, "NaN target ignored")
	end)
	T.it("the damage chip holds, drains and fades; heals never leave a chip", function()
		local b = HeroTagMath.newBar(1)
		local a = HeroTagMath.stepBar(b, 0.4, 1 / 60)
		T.eq(b.chip, 1, "chip marks the old HP")
		T.eq(a, 1, "chip opaque while held")
		local t = 1 / 60
		while t < HeroTagMath.EASE_TIME + HeroTagMath.CHIP_HOLD - 0.05 do
			a = HeroTagMath.stepBar(b, 0.4, 1 / 60)
			t += 1 / 60
		end
		T.near(b.shown, 0.4, 0.01, "fill eased")
		T.eq(b.chip, 1, "chip still held")
		local last = 1
		local faded = false
		for _ = 1, 120 do
			a = HeroTagMath.stepBar(b, 0.4, 1 / 60)
			T.truthy(a <= last + 1e-9, "chip only fades")
			last = a
			if a == 0 then
				faded = true
				break
			end
		end
		T.truthy(faded, "chip gone within 2 s")
		T.eq(b.chip, b.shown)
		-- heal: no chip
		local h = HeroTagMath.newBar(0.2)
		for _ = 1, 30 do
			T.eq(HeroTagMath.stepBar(h, 0.9, 1 / 60), 0, "no chip on a heal")
		end
		T.near(h.shown, 0.9, 0.01)
	end)
end)

T.describe("fade by distance", function()
	T.it("you and squadmates never fade", function()
		for _, d in { 0, 120, 500 } do
			local s, a = HeroTagMath.fade("ally", d)
			T.eq(s, 1)
			T.eq(a, 1)
			s, a = HeroTagMath.fade("self", d)
			T.eq(a, 1)
		end
	end)
	T.it("enemies shrink and fade past ~120 studs, monotonically", function()
		local s0, a0 = HeroTagMath.fade("enemy", 10)
		T.eq(s0, 1)
		T.eq(a0, 1)
		local s1, a1 = HeroTagMath.fade("enemy", 120)
		T.near(s1, HeroTagMath.FAR_SCALE, 1e-6)
		T.near(a1, HeroTagMath.FAR_ALPHA, 1e-6)
		local _, a2 = HeroTagMath.fade("enemy", 200)
		T.eq(a2, 0, "hidden far away")
		local ps, pa = 2, 2
		for d = 0, 220, 5 do
			local s, a = HeroTagMath.fade("enemy", d)
			T.truthy(s <= ps + 1e-9 and a <= pa + 1e-9, "monotone at " .. d)
			T.truthy(s >= HeroTagMath.MIN_SCALE - 1e-9, "never tiny")
			ps, pa = s, a
		end
		local _, an = HeroTagMath.fade("neutral", 150)
		T.truthy(an < 1, "unknown squads fade like enemies")
	end)
	T.it("quantize snaps to steps", function()
		T.eq(HeroTagMath.quantize(0.52, 20), 0.5)
		T.eq(HeroTagMath.quantize(2, 20), 1)
		T.eq(HeroTagMath.quantize(0 / 0, 20), 0)
	end)
end)

return T.finish()
