--!strict
-- Data/Settings: the profile.settings keys a client may change (C2S.SetSetting) and
-- their allowed values. Pure (Lune-tested); ShopService validates with it.
--
--   * Boolean keys (BOOL_KEYS): true / false.
--   * String keys (iter 5 #3, saved graphics settings; the client applies them):
--       fx    = "full" | "reduced" | "off"   (particles, juice)
--       decor = "full" | "low"               (DetailLevel, ground scatter)
--     The default is "full", stored as nil (profile default nil = full), so
--     choosing "full" clears the key.

local Settings = {}

Settings.BOOL_KEYS = table.freeze({
	"hints",
	"music",
	"sfx",
	"avatarLook",
	"hintRanks",
	"hintHorn",
	"hintWhey",
	"hintGems",
})

Settings.STRING_KEYS = table.freeze({
	fx = table.freeze({ "full", "reduced", "off" }),
	decor = table.freeze({ "full", "low" }),
})

Settings.DEFAULTS = table.freeze({ fx = "full", decor = "full" })

-- Every key SetSetting accepts (bool keys first, then the string keys).
Settings.KEYS = table.freeze((function()
	local out = table.clone(Settings.BOOL_KEYS)
	table.insert(out, "fx")
	table.insert(out, "decor")
	return out
end)())

-- Validates a SetSetting(key, value). Returns (ok, valueToStore): the stored value
-- is nil for a string key set to its default ("full").
function Settings.validate(key: any, value: any): (boolean, any)
	if type(key) ~= "string" then
		return false, nil
	end
	local allowed = (Settings.STRING_KEYS :: any)[key]
	if allowed then
		if type(value) ~= "string" or not table.find(allowed, value) then
			return false, nil
		end
		return true, if value == (Settings.DEFAULTS :: any)[key] then nil else value
	end
	if table.find(Settings.BOOL_KEYS, key) and type(value) == "boolean" then
		return true, value
	end
	return false, nil
end

-- The effective value of a string setting from a profile's settings map (nil or
-- an unknown value -> the default).
function Settings.get(settings: any, key: string): string?
	local allowed = (Settings.STRING_KEYS :: any)[key]
	if not allowed then
		return nil
	end
	local v = if type(settings) == "table" then settings[key] else nil
	if type(v) == "string" and table.find(allowed, v) then
		return v
	end
	return (Settings.DEFAULTS :: any)[key]
end

return Settings
