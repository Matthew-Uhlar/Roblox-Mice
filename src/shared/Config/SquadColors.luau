--!strict
-- The one squad colour palette (team CLARITY). Pure data + helpers: RGB
-- triples {r, g, b} (0..255), never Color3, so it runs under Lune.
--
-- Every place that draws a squad colour reads it from here: Util/Squads
-- (match / lobby squads and pads, HeroDecor sash, HeroFx ring, FxController
-- highlight), BotModel band, BotService name, ArenaBuilder squad bases, the
-- minimap and the client HeroTags.
--
-- The four colours follow the Okabe-Ito colour-blind-safe set (orange-gold,
-- sky blue, reddish purple, bluish green), lifted a little for dark arenas.
-- They differ in hue AND lightness, so they stay apart under protanopia,
-- deuteranopia and tritanopia (tests/specs/ClientHeroTags.spec.luau checks
-- a simulated distance). The squad's cheese name (Util/Squads: Swiss, Brie,
-- Blue, Pepper Jack) stays; `name` here is the colour's name.
--
-- Ally / enemy accents are VIEWER-relative and sit outside the squad hues:
--   ALLY       bright lime: the ▼ chevron, ground ring and outline on squadmates
--   ALLY_BAR   green health fill (your squad, you included)
--   ENEMY_BAR  red health fill (every other squad)
--   DOWNED_BAR grey fill while downed
--   CHIP       the white "damage chip" that trails a drop

local SquadColors = {}

export type RGB = { number }

SquadColors.LIST = {
	{ id = 1, name = "Gold", rgb = { 240, 185, 40 } },
	{ id = 2, name = "Rose", rgb = { 205, 75, 150 } },
	{ id = 3, name = "Sky", rgb = { 90, 180, 240 } },
	{ id = 4, name = "Mint", rgb = { 120, 230, 195 } },
}

SquadColors.ALLY = { 140, 255, 120 }
SquadColors.ALLY_BAR = { 80, 220, 100 }
SquadColors.ENEMY = { 240, 70, 60 }
SquadColors.ENEMY_BAR = { 235, 64, 64 }
SquadColors.DOWNED_BAR = { 135, 135, 145 }
SquadColors.CHIP = { 255, 255, 255 }
SquadColors.NEUTRAL = { 200, 200, 200 } -- no squad (should not happen in a run)

-- A fresh {r, g, b} for squad `id` (NEUTRAL for an unknown id).
function SquadColors.rgb(id: any): RGB
	local e = SquadColors.LIST[tonumber(id) or 0]
	return table.clone(if e then e.rgb else SquadColors.NEUTRAL)
end

-- The colour's name ("Gold") for squad `id`, else "Squad N".
function SquadColors.name(id: any): string
	local e = SquadColors.LIST[tonumber(id) or 0]
	return if e then e.name else ("Squad " .. tostring(id))
end

-- How the viewer sees a hero: "self" (the viewer's own hero), "ally" (same
-- squad), "enemy" (another squad), or "neutral" (a squad is unknown).
function SquadColors.relation(viewerSquad: number?, heroSquad: number?, isSelf: boolean?): string
	if isSelf then
		return "self"
	elseif viewerSquad == nil or heroSquad == nil then
		return "neutral"
	elseif viewerSquad == heroSquad then
		return "ally"
	end
	return "enemy"
end

-- Health fill colour for a relation: your squad (and you) green, enemies red,
-- downed grey. A neutral hero reads as an enemy (never show an unknown as safe).
function SquadColors.barColor(relation: string, downed: boolean?): RGB
	if downed then
		return table.clone(SquadColors.DOWNED_BAR)
	elseif relation == "self" or relation == "ally" then
		return table.clone(SquadColors.ALLY_BAR)
	end
	return table.clone(SquadColors.ENEMY_BAR)
end

return SquadColors
