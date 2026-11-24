--!strict
-- Data/Settings: the profile.settings keys a client may change (C2S.SetSetting) and
-- their allowed values. Pure (Lune-tested); ShopService validates with it.
--
--   * Boolean keys (BOOL_KEYS): true / false.
--   * String keys (iter 5 #3, saved graphics settings; the client applies them):
--       fx    = "full" | "reduced" | "off"   (particles, juice)
--       decor = "full" | "low"               (DetailLevel, ground scatter)
--       shake = "full" | "low" | "off"       (iteration 7: screen shake)
--       castSfx = "full" | "low" | "off"     (iteration 7: cast sounds)
--       models = "detailed" | "classic"      (iteration 7, team Mesh: "classic"
--                                             forces the part models; default
--                                             "detailed" is stored as nil)
--       castMode = "quick" | "hold"         (iteration 7, team Client: ability keys
--                                             cast on press, or hold to aim and cast
--                                             on release; default "quick" stored as nil)
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
	"smartCast", -- iteration 8 (team Client): phone smart-cast (auto-cast slot 1)
})

Settings.STRING_KEYS = table.freeze({
	fx = table.freeze({ "full", "reduced", "off" }),
	decor = table.freeze({ "full", "low" }),
	-- iteration 7 (team Systems, for team Client's game-feel settings)
	shake = table.freeze({ "full", "low", "off" }),
	castSfx = table.freeze({ "full", "low", "off" }),
	-- iteration 7 (team Mesh): Models: Detailed (meshes) / Classic (part models)
	models = table.freeze({ "detailed", "classic" }),
	-- iteration 7 (team Client): Ability casting: Quick (cast on press) / Hold to aim
	castMode = table.freeze({ "quick", "hold" }),
})

Settings.DEFAULTS = table.freeze({
	fx = "full",
	decor = "full",
	shake = "full",
	castSfx = "full",
	models = "detailed", -- iteration 7 (team Mesh)
	castMode = "quick", -- iteration 7 (team Client)
})

-- Every key SetSetting accepts (bool keys first, then the string keys).
Settings.KEYS = table.freeze((function()
	local out = table.clone(Settings.BOOL_KEYS)
	table.insert(out, "fx")
	table.insert(out, "decor")
	table.insert(out, "shake") -- iteration 7
	table.insert(out, "castSfx")
	table.insert(out, "models") -- iteration 7 (team Mesh)
	table.insert(out, "castMode") -- iteration 7 (team Client)
	table.insert(out, "binds") -- iteration 8 (team Client): keybinds, Settings.validBinds
	return out
end)())

-- Validates a SetSetting(key, value). Returns (ok, valueToStore): the stored value
-- is nil for a string key set to its default ("full").
function Settings.validate(key: any, value: any): (boolean, any)
	if type(key) ~= "string" then
		return false, nil
	end
	if key == "binds" then -- iteration 8 (team Client): keybind string
		if not Settings.validBinds(value) then
			return false, nil
		end
		return true, if value == Settings.DEFAULT_BINDS then nil else value
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

-- ===== iteration 8 (team Client): keybinds =====
-- profile.settings.binds is a compact string (profile strings are capped at 64 chars):
-- "1" (format version) + one character per BIND_ACTIONS entry, in that order; each
-- character indexes BIND_KEYS through BIND_ALPHABET (1-based). Two actions may not
-- share a key. Default binds are stored as nil. Actions are append-only (a shorter
-- saved string keeps the defaults for actions added later). Gamepad buttons, mouse
-- buttons and the fixed keys (WASD movement, Escape, F / G gear swap, 1-9 menu picks)
-- are not remappable. The client (Util/Keybinds) maps names to Enum.KeyCode.
Settings.BIND_VERSION = "1"
Settings.BIND_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
Settings.BIND_ACTIONS = table.freeze({
	"ability1", -- Space
	"ability1Alt", -- Q (also cycles the spectated squadmate)
	"ability2", -- E
	"ability3", -- R
	"ability4", -- C
	"ping", -- G
	"meter", -- Tab (damage meter / scoreboard)
	"runShop", -- V (the V menu)
	"leftList", -- B (what's left)
	"aimMode", -- T (nearest / cursor aim)
	"camLeft", -- Comma
	"camRight", -- Period
	"camNorth", -- N
	"extract", -- X
})
Settings.BIND_KEYS = table.freeze({
	"Space",
	"Q",
	"E",
	"R",
	"C",
	"G",
	"Tab",
	"V",
	"B",
	"T",
	"Comma",
	"Period",
	"N",
	"X",
	"H",
	"I",
	"J",
	"K",
	"L",
	"M",
	"O",
	"P",
	"U",
	"Y",
	"Z",
	"Zero",
	"One",
	"Two",
	"Three",
	"Four",
	"Five",
	"Six",
	"Seven",
	"Eight",
	"Nine",
	"LeftShift",
	"LeftControl",
	"LeftAlt",
	"RightShift",
	"RightControl",
	"RightAlt",
	"CapsLock",
	"Semicolon",
	"Quote",
	"Slash",
	"BackSlash",
	"LeftBracket",
	"RightBracket",
	"Minus",
	"Equals",
	"Backquote",
	"Return",
	"Backspace",
	"Up",
	"Down",
	"Left",
	"Right",
	"F1",
	"F2",
	"F3",
	"F4",
	"F5",
})
-- defaults: key i of BIND_KEYS for action i (the first 14 keys are in action order)
Settings.DEFAULT_BINDS = (function()
	local out = Settings.BIND_VERSION
	for i = 1, #Settings.BIND_ACTIONS do
		out ..= string.sub(Settings.BIND_ALPHABET, i, i)
	end
	return out
end)()

-- action -> key name for a binds string (nil / invalid -> the defaults).
function Settings.decodeBinds(v: any): { [string]: string }
	local out: { [string]: string } = {}
	local ok = Settings.validBinds(v)
	for i, action in Settings.BIND_ACTIONS do
		local key = Settings.BIND_KEYS[i]
		if ok and i + 1 <= #v then
			local idx = string.find(Settings.BIND_ALPHABET, string.sub(v, i + 1, i + 1), 1, true)
			key = Settings.BIND_KEYS[idx :: number]
		end
		out[action] = key
	end
	return out
end

-- The binds string for an action -> key name map (missing actions: defaults);
-- nil when a key is unknown.
function Settings.encodeBinds(map: { [string]: string }): string?
	local out = Settings.BIND_VERSION
	for i, action in Settings.BIND_ACTIONS do
		local key = map[action] or Settings.BIND_KEYS[i]
		local idx = table.find(Settings.BIND_KEYS, key)
		if not idx then
			return nil
		end
		out ..= string.sub(Settings.BIND_ALPHABET, idx, idx)
	end
	return out
end

-- A valid binds string: the version, 1..#BIND_ACTIONS known key characters, no key twice.
-- Keys an action may not take (iteration 8 QC): 1-9 are the V-menu rank picks and
-- the upgrade-strip picks; R rerolls the upgrade strip, so only ability 3 (which
-- passes R through while the strip is up) may use it. The list order of BIND_KEYS
-- never changes (saved strings index it), so these stay listed but refused.
Settings.BIND_RESERVED = table.freeze({
	One = true,
	Two = true,
	Three = true,
	Four = true,
	Five = true,
	Six = true,
	Seven = true,
	Eight = true,
	Nine = true,
})
Settings.BIND_ONLY = table.freeze({ R = "ability3" })

-- Whether `action` may be bound to the key named `key`.
function Settings.bindAllowed(action: string, key: string): boolean
	if Settings.BIND_RESERVED[key] then
		return false
	end
	local only = Settings.BIND_ONLY[key]
	return only == nil or only == action
end

function Settings.validBinds(v: any): boolean
	if type(v) ~= "string" or #v < 2 or #v > #Settings.BIND_ACTIONS + 1 then
		return false
	end
	if string.sub(v, 1, 1) ~= Settings.BIND_VERSION then
		return false
	end
	local seen = {}
	for i = 2, #v do
		local idx = string.find(Settings.BIND_ALPHABET, string.sub(v, i, i), 1, true)
		if not idx or idx > #Settings.BIND_KEYS or seen[idx] then
			return false
		end
		local action = Settings.BIND_ACTIONS[i - 1]
		if action and not Settings.bindAllowed(action, Settings.BIND_KEYS[idx]) then
			return false
		end
		seen[idx] = true
	end
	return true
end
-- ===== end iteration 8 keybinds =====

return Settings
