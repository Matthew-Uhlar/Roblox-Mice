--!strict
-- Saved graphics settings (iteration 5 Phase B #3). Pure: no Roblox APIs,
-- unit-tested under Lune (tests/specs/ClientIter5.spec.luau).
--
--   Effects  fx    = "full" | "reduced" | "off"   particles, juice pops, Fx detail
--   Decor    decor = "full" | "low"               floor scatter, streamed props, backdrop
--   Models   models = "detailed" | "classic"      iteration 7 (team Mesh): mesh
--            creatures or the part models (HordeRenderer; Config/Visuals.USE_MESHES
--            switches meshes off for everyone)
--
-- Saved with SetSetting("fx" | "decor", value) in profile.settings. State key
-- "gfx" holds the live pair (an optimistic local pick wins for a few seconds,
-- then the profile). "off" never hides gameplay telegraphs: those are parts,
-- not particles, and FxController keeps drawing them.

local GfxSettings = {}

GfxSettings.FX = { "full", "reduced", "off" }
GfxSettings.DECOR = { "full", "low" }
GfxSettings.FX_LABEL = { full = "Full", reduced = "Reduced", off = "Off" } :: { [string]: string }
GfxSettings.DECOR_LABEL = { full = "Full", low = "Low" } :: { [string]: string }
GfxSettings.MODELS = { "detailed", "classic" } -- iteration 7 (team Mesh)
GfxSettings.MODELS_LABEL = { detailed = "Detailed", classic = "Classic" } :: { [string]: string }

export type Gfx = { fx: string, decor: string, models: string }

function GfxSettings.fx(v: any): string
	return if v == "reduced" or v == "off" then v else "full"
end

function GfxSettings.decor(v: any): string
	return if v == "low" then "low" else "full"
end

function GfxSettings.models(v: any): string
	return if v == "classic" then "classic" else "detailed"
end

-- From a profile (profile.settings.fx / decor); defaults full / full.
function GfxSettings.fromProfile(profile: any): Gfx
	local st = if type(profile) == "table" and type(profile.settings) == "table" then profile.settings else {}
	return {
		fx = GfxSettings.fx(st.fx),
		decor = GfxSettings.decor(st.decor),
		models = GfxSettings.models(st.models),
	}
end

-- Particle multiplier and per-second budget for an fx level on a device.
function GfxSettings.particles(fx: string, lowSpec: boolean): (number, number)
	local mult = if lowSpec then 0.4 else 1
	local budget = if lowSpec then 300 else 900
	if fx == "reduced" then
		return mult * 0.5, math.floor(budget / 3)
	elseif fx == "off" then
		return 0, 0
	end
	return mult, budget
end

-- Whether the FxController / Juice should run their low-spec path.
function GfxSettings.lowFx(fx: string, lowSpec: boolean): boolean
	return lowSpec or fx ~= "full"
end

-- Next value in a cycle (for one-button toggles).
function GfxSettings.nextOf(list: { string }, cur: string): string
	local i = table.find(list, cur) or 0
	return list[i % #list + 1]
end

return GfxSettings
