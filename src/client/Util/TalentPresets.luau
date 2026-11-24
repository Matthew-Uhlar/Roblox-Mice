--!strict
-- TalentPresets (iteration 7 §B6, team Client): the talent preset row of the
-- Talent Tree screen (UI/PerkTreeUI). Pure (Lune-tested, ClientIter7.spec).
--
-- Server side (team Systems): Net.C2S.SavePreset(classId, slot) / LoadPreset(classId,
-- slot); profile view classes[id].presets = { [slot] = {perks, points, valid} | {} }
-- (Data/ClassProgress.presetView). Save is free any time; Load is free, lobby only,
-- and replays the build through the normal perk rules (valid = loadable now).
-- (iteration 7, Systems) a slot also carries `need` = the class's total talent
-- points; a build only loads when its points equal that (refusal "preset_points"),
-- shown as "Needs N points".

local TalentPresets = {}

TalentPresets.SLOTS = 2

export type Slot = {
	slot: number,
	empty: boolean,
	points: number,
	valid: boolean,
	current: boolean, -- the saved build equals the current perks
	need: number?, -- the class's point total a build must spend to load
	mismatch: boolean, -- points ~= need (shown as "Needs N points")
	text: string,
}

local function sameSet(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if v == true and b[k] ~= true then
			return false
		end
	end
	for k, v in b do
		if v == true and a[k] ~= true then
			return false
		end
	end
	return true
end

-- The slot views from a class's profile view block (`presets` may be missing:
-- every slot is then empty) and the current perk set.
function TalentPresets.slots(classView: any, perks: any): { Slot }
	local raw = if type(classView) == "table" and type(classView.presets) == "table"
		then classView.presets
		else {}
	local out: { Slot } = {}
	for i = 1, TalentPresets.SLOTS do
		local p = raw[i] or raw[tostring(i)]
		local set = if type(p) == "table" and type(p.perks) == "table" then p.perks else nil
		local empty = set == nil or next(set) == nil
		local points = if type(p) == "table" then math.max(0, math.floor(tonumber(p.points) or 0)) else 0
		local need = if type(p) == "table" and tonumber(p.need)
			then math.floor(tonumber(p.need) :: number)
			else nil
		local mismatch = not empty and need ~= nil and points ~= need
		local s: Slot = {
			slot = i,
			empty = empty,
			points = points,
			valid = not empty and (type(p) ~= "table" or p.valid ~= false),
			current = not empty and sameSet(set, perks),
			need = need,
			mismatch = mismatch,
			text = "",
		}
		s.text = if empty
			then string.format("Build %d · empty", i)
			else string.format("Build %d · %d pt%s", i, points, if points == 1 then "" else "s")
		out[i] = s
	end
	return out
end

-- Whether Load is allowed: lobby only, a saved build that still fits, and not
-- already the current one. Returns (ok, why?).
function TalentPresets.canLoad(s: Slot, inLobby: boolean): (boolean, string?)
	if s.empty then
		return false, "Empty: save your current talents here first."
	elseif not inLobby then
		return false, "Builds swap in the lobby only."
	elseif s.mismatch then
		return false, string.format("Needs %d points: this build spends %d.", s.need or 0, s.points)
	elseif not s.valid then
		return false, "This build no longer fits this class's points or tree."
	elseif s.current then
		return false, "Already your current build."
	end
	return true, nil
end

-- Save asks for a second tap when it would overwrite a different saved build.
function TalentPresets.needsConfirm(s: Slot): boolean
	return not s.empty and not s.current
end

return TalentPresets
