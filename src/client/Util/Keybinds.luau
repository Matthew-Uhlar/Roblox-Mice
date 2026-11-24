--!strict
-- Keybinds (iteration 8 §C, team Client): remappable keyboard keys. Pure
-- (Lune-tested, ClientIter8.spec). The saved form and the action / key lists
-- live in Shared Data/Settings (BIND_ACTIONS, BIND_KEYS, encode / decode /
-- validBinds); `cfg` below is that module. State.binds() gives the live map
-- (a fresh local pick wins over the profile); State.bindKey(action) the
-- Enum.KeyCode. Gamepad / mouse buttons and the fixed keys are not remappable.

local Keybinds = {}

export type Map = { [string]: string }

Keybinds.LABEL = table.freeze({
	ability1 = "Ability 1",
	ability1Alt = "Ability 1 (alt)",
	ability2 = "Ability 2",
	ability3 = "Ability 3",
	ability4 = "Ability 4",
	ping = "Ping wheel",
	meter = "Damage meter",
	runShop = "Upgrade menu (V)",
	leftList = "What's left",
	aimMode = "Aim mode",
	camLeft = "Camera left",
	camRight = "Camera right",
	camNorth = "Camera north",
	extract = "Extract now",
} :: { [string]: string })

local SHORT: { [string]: string } = {
	Comma = ",",
	Period = ".",
	Semicolon = ";",
	Quote = "'",
	Slash = "/",
	BackSlash = "\\",
	LeftBracket = "[",
	RightBracket = "]",
	Minus = "-",
	Equals = "=",
	Backquote = "`",
	LeftShift = "LShift",
	RightShift = "RShift",
	LeftControl = "LCtrl",
	RightControl = "RCtrl",
	LeftAlt = "LAlt",
	RightAlt = "RAlt",
	CapsLock = "Caps",
	Return = "Enter",
	Backspace = "Bksp",
	Zero = "0",
	One = "1",
	Two = "2",
	Three = "3",
	Four = "4",
	Five = "5",
	Six = "6",
	Seven = "7",
	Eight = "8",
	Nine = "9",
	Up = "↑",
	Down = "↓",
	Left = "←",
	Right = "→",
}

-- Short label for a key name ("Comma" -> ",", "LeftShift" -> "LShift").
function Keybinds.keyLabel(key: string?): string
	if key == nil then
		return "?"
	end
	return SHORT[key] or key
end

-- The live map: the local pick (a binds string) wins over the profile's.
function Keybinds.fromProfile(cfg: any, profile: any, localPick: string?): Map
	local st = if type(profile) == "table" and type(profile.settings) == "table" then profile.settings else {}
	local v = if localPick ~= nil then localPick else st.binds
	return cfg.decodeBinds(v)
end

-- {action = otherAction} for every action sharing its key with another one.
function Keybinds.conflicts(cfg: any, map: Map): { [string]: string }
	local byKey: { [string]: string } = {}
	local out: { [string]: string } = {}
	for _, action in cfg.BIND_ACTIONS do
		local key = map[action]
		if key then
			local other = byKey[key]
			if other then
				out[action] = other
				out[other] = action
			else
				byKey[key] = action
			end
		end
	end
	return out
end

-- Binds `action` to `key`. When another action had that key, the two swap so
-- the result never has a conflict. Returns (newMap, swappedAction?).
function Keybinds.assign(cfg: any, map: Map, action: string, key: string): (Map, string?)
	local out = table.clone(map)
	if not table.find(cfg.BIND_KEYS, key) or not table.find(cfg.BIND_ACTIONS, action) then
		return out, nil
	end
	local old = out[action]
	local swapped: string? = nil
	for a, k in out do
		if k == key and a ~= action then
			out[a] = old
			swapped = a
		end
	end
	out[action] = key
	return out, swapped
end

function Keybinds.defaults(cfg: any): Map
	return cfg.decodeBinds(nil)
end

-- The saved string for a map (nil = the defaults or an invalid map).
function Keybinds.encode(cfg: any, map: Map): string?
	local s = cfg.encodeBinds(map)
	if s == nil or s == cfg.DEFAULT_BINDS or not cfg.validBinds(s) then
		return nil
	end
	return s
end

-- "[V]"-style hint for an action ("" on touch, the gamepad text on a pad).
function Keybinds.hint(map: Map, action: string, mode: string?, pad: string?): string
	if mode == "touch" then
		return ""
	elseif mode == "gamepad" then
		return pad or ""
	end
	return Keybinds.keyLabel(map[action])
end

return Keybinds
