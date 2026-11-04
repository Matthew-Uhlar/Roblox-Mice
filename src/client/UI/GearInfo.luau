--!strict
-- Display info for run-only gear items (GDD-v2 §3). Items arrive in
-- Net.S2C.Inventory / ShopCart as `{id, slot = "weapon"|"armor"|"trinket",
-- rarity, …}`; the definition lives in Shared.Config.Gear (Team R2), which
-- may not exist yet, so every field falls back to the item itself and then to
-- a readable placeholder.

local Client = script.Parent.Parent
local Defs = require(Client.Util.Defs)
local Theme = require(script.Parent.Theme)

local GearInfo = {}

GearInfo.SLOTS = { "weapon", "armor", "trinket" }
GearInfo.SLOT_NAME = { weapon = "Weapon mod", armor = "Armor", trinket = "Trinket" }
GearInfo.SLOT_HINT = {
	weapon = "Changes your auto-weapon",
	armor = "Defence",
	trinket = "Utility",
}

export type Info = {
	id: string,
	name: string,
	slot: string,
	rarity: string,
	color: Color3,
	text: string,
	icon: string,
	known: boolean, -- true when Config/Gear had a definition
}

local function cap(s: string): string
	return string.upper(string.sub(s, 1, 1)) .. string.lower(string.sub(s, 2))
end

-- Effect text from a def: description, or a per-rarity line, or stat pairs.
local function effectText(def: any, item: any, rarity: string): string
	for _, src in { item, def } do
		if type(src) == "table" then
			local d = src.description or src.desc or src.text or src.effectText
			if type(d) == "string" and d ~= "" then
				return d
			end
		end
	end
	if type(def) == "table" then
		local tiers = def.tiers or def.byRarity or def.rarities
		if type(tiers) == "table" then
			local t = tiers[rarity] or tiers[string.lower(rarity)]
			if type(t) == "table" and type(t.description or t.text) == "string" then
				return t.description or t.text
			end
		end
	end
	return ""
end

function GearInfo.describe(item: any): Info?
	if type(item) ~= "table" or item.id == nil then
		return nil
	end
	local id = tostring(item.id)
	local def = Defs.get("Gear", id)
	local slot = tostring(item.slot or (def and def.slot) or "trinket")
	local rarity = cap(tostring(item.rarity or (def and def.rarity) or "Common"))
	local name = if type(item.name) == "string"
		then item.name
		elseif def then Defs.name(def, id)
		else Defs.name(nil, id)
	local text = effectText(def, item, rarity)
	if text == "" then
		text = (GearInfo.SLOT_HINT[slot] or "Gear") .. ". Lost when the run ends."
	end
	return {
		id = id,
		name = name,
		slot = slot,
		rarity = rarity,
		color = Theme.rarityColor(rarity),
		text = text,
		icon = Theme.Icons.forSlot(slot),
		known = def ~= nil,
	}
end

-- Tooltip text (rich text) for an item, or the empty-slot explainer.
function GearInfo.tooltip(item: any, slot: string?): string
	local info = GearInfo.describe(item)
	if not info then
		local s = slot or "trinket"
		return string.format(
			"<b>%s</b> (empty)\n%s. Find gear at POIs, Elite Camps, boss chests and loot bags.\n<i>Gear only lasts for this run.</i>",
			GearInfo.SLOT_NAME[s] or "Gear slot",
			GearInfo.SLOT_HINT[s] or "Gear"
		)
	end
	return string.format(
		'<b><font color="#%s">%s</font></b> · %s %s\n%s\n<i>Run-only: lost when the run ends.</i>',
		info.color:ToHex(),
		info.name,
		info.rarity,
		GearInfo.SLOT_NAME[info.slot] or info.slot,
		info.text
	)
end

return GearInfo
