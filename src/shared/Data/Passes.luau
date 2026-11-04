--!strict
-- Game-pass perks saved on the profile, with their source (Team D). Pure.
--
-- A pass can be refunded or charged back, so everything it puts on the profile is
-- revocable. `profile.passGrants[passKey]` records exactly what that pass added:
--   cosmetics  the pass's own cosmetics (Config/Cosmetics source = "pass")
--   classes    classes that were still LOCKED when Founders unlocked them. A class
--              the player had already bought with cheese is never recorded, so a
--              revoke never takes away something the player paid cheese for.
--   skins      (v5) paid class skins of the pass's set (Config/ClassSkins.forPass) that
--              the profile did NOT own yet. A skin bought alone with Golden Cheese is
--              never recorded, so a revoke never takes it away.
-- MonetizationService calls apply() only after MarketplaceService:UserOwnsGamePassAsync
-- confirms ownership, and revoke() when it confirms the pass is no longer owned.
--
-- `passGrants` is not in Types.Profile yet (the lead owns Types.luau), so it is read
-- through Passes.grants(). ProfileSchema creates, migrates and sanitises it.

local Types = require("../Types")
local Monetization = require("../Config/Monetization")
local Cosmetics = require("../Config/Cosmetics")
local ShopConfig = require("../Config/Shop")
local ClassSkins = require("../Config/ClassSkins")
local ClassProgress = require("./ClassProgress")

type Profile = Types.Profile

export type Grant = {
	cosmetics: { [string]: boolean },
	classes: { [string]: boolean },
	skins: { [string]: boolean }?, -- (v5)
}
export type PassGrants = { [string]: Grant }
export type Revoked = { cosmetics: { string }, classes: { string }, skins: { string } }

local function ownedSkins(profile: Profile): { [string]: boolean }
	local p = profile :: any
	if type(p.ownedSkins) ~= "table" then
		p.ownedSkins = {}
	end
	return p.ownedSkins
end

local Passes = {}

local function isPassKey(key: any): boolean
	if type(key) ~= "string" then
		return false
	end
	local item = Monetization.get(key)
	return item ~= nil and item.kind == "pass"
end
Passes.isPassKey = isPassKey

-- The profile's grant records (created on first use).
function Passes.grants(profile: Profile): PassGrants
	local p = profile :: any
	if type(p.passGrants) ~= "table" then
		p.passGrants = {}
	end
	return p.passGrants
end

local function record(grants: PassGrants, key: string): Grant
	local g = grants[key]
	if not g then
		g = { cosmetics = {}, classes = {}, skins = {} }
		grants[key] = g
	end
	if g.skins == nil then
		g.skins = {}
	end
	return g
end

-- Applies a VERIFIED pass's perks and records their source. Idempotent.
-- Returns true when the profile changed.
function Passes.apply(profile: Profile, passKey: string): boolean
	if not isPassKey(passKey) then
		return false
	end
	local item = Monetization.get(passKey) :: Monetization.Item
	local grants = Passes.grants(profile)
	local changed = false
	for _, id in item.cosmetics or {} do
		local def = Cosmetics.get(id)
		if def then
			if not profile.cosmetics[id] then
				profile.cosmetics[id] = true
				changed = true
			end
			-- Pass cosmetics can only come from this pass: always record the source.
			local g = record(grants, passKey)
			if not g.cosmetics[id] then
				g.cosmetics[id] = true
				changed = true
			end
		end
	end
	if item.unlockAllClasses then
		for _, id in ShopConfig.classIds() do
			if not profile.unlockedClasses[id] then
				profile.unlockedClasses[id] = true
				record(grants, passKey).classes[id] = true
				changed = true
			end
			ClassProgress.ensure(profile, id) -- (v5) class progression block
		end
	end
	local skins = ClassSkins.forPass(passKey)
	if #skins > 0 then
		local owned = ownedSkins(profile)
		for _, id in skins do
			if not owned[id] then
				owned[id] = true
				(record(grants, passKey).skins :: any)[id] = true
				changed = true
			end
		end
	end
	return changed
end

local function defaultClass(profile: Profile): string
	local Classes = ShopConfig.classes()
	local id = if Classes and type(Classes.DEFAULT_ID) == "string" then Classes.DEFAULT_ID else nil
	if id and profile.unlockedClasses[id] then
		return id
	end
	for _, free in ShopConfig.freeClassIds() do
		if profile.unlockedClasses[free] then
			return free
		end
	end
	return id or "elephante"
end

-- Removes everything this pass recorded (the pass is no longer owned). Unequips
-- removed cosmetics and moves the selected class off a removed class.
function Passes.revoke(profile: Profile, passKey: string): Revoked
	local out: Revoked = { cosmetics = {}, classes = {}, skins = {} }
	local grants = Passes.grants(profile)
	local g = grants[passKey]
	if not g then
		return out
	end
	local free: { [string]: boolean } = {}
	for _, id in ShopConfig.freeClassIds() do
		free[id] = true
	end
	for id in g.cosmetics do
		if profile.cosmetics[id] then
			profile.cosmetics[id] = nil
			table.insert(out.cosmetics, id)
		end
		for slot, eq in profile.equipped :: any do
			if eq == id then
				(profile.equipped :: any)[slot] = nil
			end
		end
	end
	for id in g.classes do
		if profile.unlockedClasses[id] and not free[id] then
			profile.unlockedClasses[id] = nil
			table.insert(out.classes, id)
		end
	end
	local owned = ownedSkins(profile)
	local classes = (profile :: any).classes
	for id in g.skins or {} do
		if owned[id] then
			owned[id] = nil
			table.insert(out.skins, id)
		end
		if type(classes) == "table" then
			for _, st in classes do
				if type(st) == "table" and st.skin == id then
					st.skin = nil
				end
			end
		end
	end
	if not profile.unlockedClasses[profile.selectedClass] then
		profile.selectedClass = defaultClass(profile)
	end
	grants[passKey] = nil
	table.sort(out.cosmetics)
	table.sort(out.classes)
	table.sort(out.skins)
	return out
end

-- Pass keys this profile holds revocable grants for.
function Passes.recordedKeys(profile: Profile): { string }
	local out = {}
	for key in Passes.grants(profile) do
		table.insert(out, key)
	end
	table.sort(out)
	return out
end

-- Migration helper (profiles saved before grants were tracked): every owned
-- cosmetic whose def says source = "pass" is recorded under its pass. Class unlocks
-- can't be told apart from cheese purchases, so they stay (never revoked).
function Passes.inferFromCosmetics(cosmetics: any): PassGrants
	local out: PassGrants = {}
	if type(cosmetics) ~= "table" then
		return out
	end
	for id, owned in cosmetics do
		if type(id) == "string" and owned == true then
			local def = Cosmetics.get(id)
			if def and def.source == "pass" and isPassKey(def.passKey) then
				record(out, def.passKey :: string).cosmetics[id] = true
			end
		end
	end
	return out
end

-- Sanitises raw saved grants against the (already reconciled) profile: only real
-- pass keys, only ids the profile still has, no empty records.
function Passes.sanitize(raw: any, profile: Profile): PassGrants
	local out: PassGrants = {}
	if type(raw) ~= "table" then
		return out
	end
	for key, g in raw do
		if isPassKey(key) and type(g) == "table" then
			local clean: Grant = { cosmetics = {}, classes = {}, skins = {} }
			local any = false
			if type(g.cosmetics) == "table" then
				for id, x in g.cosmetics do
					if type(id) == "string" and x == true and profile.cosmetics[id] and Cosmetics.get(id) then
						clean.cosmetics[id] = true
						any = true
					end
				end
			end
			if type(g.classes) == "table" then
				for id, x in g.classes do
					if type(id) == "string" and x == true and profile.unlockedClasses[id] then
						clean.classes[id] = true
						any = true
					end
				end
			end
			local owned = (profile :: any).ownedSkins
			if type(g.skins) == "table" and type(owned) == "table" then
				for id, x in g.skins do
					local def = ClassSkins.get(id)
					if x == true and def and def.passKey == key and owned[id] then
						(clean.skins :: any)[id] = true
						any = true
					end
				end
			end
			if any then
				out[key] = clean
			end
		end
	end
	return out
end

return Passes
