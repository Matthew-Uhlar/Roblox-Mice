--!strict
-- Base + alternate abilities per class (GDD-v2 §5, team R3). Pure data.
--
-- Each class keeps its Config/Classes ability (unlocked at class level 1) and gets
-- 2 alternates, unlocking at class levels 5 and 15. The player picks one in the
-- lobby (Net.C2S.SelectAbility); Run/Stats.compute returns the chosen one when it
-- is given a classState. Alternates are sidegrades: same power budget as the base,
-- different shape. They only use the AbilityKinds Combat/Weapons implements:
--   dash    distance = dash length, area = half width, damage per mouse hit
--   burst   distance = cast range, area = radius, damage
--   ring    area = radius, damage on cast AND per 0.5 s tick for `duration` (0 = one slam)
--   shield  duration = invulnerability, then a counter-burst (damage, area)
--   puddle  distance = cast range, area, damage per 0.4 s tick, duration
--   hover   duration in the air, gust (damage, area) on take-off
--   field   distance, area, damage per 0.5 s tick, duration, 50% slow
-- Ids are global and stable (saved in profiles): "<classId>_<slug>".

local Types = require("../Types")
local Classes = require("./Classes")

type AbilityDef = Types.AbilityDef

export type Entry = {
	id: string,
	classId: string,
	slot: number, -- 1 = base, 2 = first alternate, 3 = second alternate
	unlockLevel: number,
	def: AbilityDef, -- full AbilityDef (def.id == id)
}

local ClassAbilities = {}

ClassAbilities.UNLOCK_LEVELS = table.freeze({ 1, 5, 15 })

-- Base ability ids (the Config/Classes ability of each class).
local BASE_IDS: { [string]: string } = {
	elephante = "elephante_stampede",
	ele_fonte = "ele_fonte_geyser",
	ellie_fawn = "ellie_fawn_thorn_ring",
	le_fante = "le_fante_riposte",
	filet = "filet_sizzle",
	jumbo = "jumbo_updraft",
	fizzante = "fizzante_soda_geyser",
}

local ALTERNATES: { [string]: { AbilityDef } } = {
	elephante = {
		{
			id = "elephante_trunk_quake",
			kind = "ring",
			name = "Trunk Quake",
			description = "Slam the ground with your trunk: one heavy shockwave around you.",
			cooldown = 7,
			damage = 40,
			area = 13,
			duration = 0,
		},
		{
			id = "elephante_iron_hide",
			kind = "shield",
			name = "Iron Hide",
			description = "Brace: become invulnerable, then shrug off the hits in a big burst.",
			cooldown = 12,
			damage = 45,
			area = 11,
			duration = 1.6,
		},
	},
	ele_fonte = {
		{
			id = "ele_fonte_tidal_pool",
			kind = "puddle",
			name = "Tidal Pool",
			description = "Flood a spot with churning water that hurts every mouse inside.",
			cooldown = 9,
			damage = 7,
			area = 11,
			distance = 35,
			duration = 5,
		},
		{
			id = "ele_fonte_riptide",
			kind = "dash",
			name = "Riptide",
			description = "Surf forward on a wave, sweeping mice aside.",
			cooldown = 8,
			damage = 32,
			area = 5,
			distance = 30,
			duration = 0.4,
		},
	},
	ellie_fawn = {
		{
			id = "ellie_fawn_bramble_burst",
			kind = "burst",
			name = "Bramble Burst",
			description = "Hurl a seed that bursts into a thicket of thorns at the target.",
			cooldown = 8,
			damage = 40,
			area = 10,
			distance = 45,
		},
		{
			id = "ellie_fawn_canopy_leap",
			kind = "hover",
			name = "Canopy Leap",
			description = "Leap into the treetops for a moment, scattering mice as you jump.",
			cooldown = 10,
			damage = 24,
			area = 11,
			duration = 1.8,
		},
	},
	le_fante = {
		{
			id = "le_fante_fleche",
			kind = "dash",
			name = "Fleche",
			description = "A lightning lunge through the crowd. Short cooldown, narrow line.",
			cooldown = 6,
			damage = 34,
			area = 4,
			distance = 20,
			duration = 0.3,
		},
		{
			id = "le_fante_blade_flurry",
			kind = "ring",
			name = "Blade Flurry",
			description = "Spin your rapier in a whirl that keeps cutting around you.",
			cooldown = 11,
			damage = 9,
			area = 9,
			duration = 3,
		},
	},
	filet = {
		{
			id = "filet_flambe",
			kind = "burst",
			name = "Flambe",
			description = "Toss a flaming pan: one big burst of fire at the target.",
			cooldown = 8,
			damage = 42,
			area = 11,
			distance = 30,
		},
		{
			id = "filet_pepper_cloud",
			kind = "field",
			name = "Pepper Cloud",
			description = "A cloud of ground pepper that slows and stings mice.",
			cooldown = 13,
			damage = 7,
			area = 15,
			distance = 28,
			duration = 5,
		},
	},
	jumbo = {
		{
			id = "jumbo_dive_bomb",
			kind = "dash",
			name = "Dive Bomb",
			description = "Swoop down in a straight line, flattening mice beneath you.",
			cooldown = 9,
			damage = 36,
			area = 7,
			distance = 28,
			duration = 0.4,
		},
		{
			id = "jumbo_ear_cyclone",
			kind = "ring",
			name = "Ear Cyclone",
			description = "Flap into a spinning cyclone that follows you and batters mice.",
			cooldown = 12,
			damage = 10,
			area = 13,
			duration = 4,
		},
	},
	fizzante = {
		{
			id = "fizzante_shaken_can",
			kind = "burst",
			name = "Shaken Can",
			description = "Lob a shaken can that explodes in one big fizzy blast.",
			cooldown = 9,
			damage = 50,
			area = 12,
			distance = 35,
		},
		{
			id = "fizzante_bubble_wrap",
			kind = "shield",
			name = "Bubble Wrap",
			description = "Wrap yourself in a bubble, then pop it in a sticky burst.",
			cooldown = 12,
			damage = 42,
			area = 12,
			duration = 1.4,
		},
	},
}

local byId: { [string]: Entry } = {}
local byClass: { [string]: { Entry } } = {}

for _, classId in Classes.ORDER do
	local class = Classes.get(classId)
	local baseId = BASE_IDS[classId]
	if class and baseId then
		local base = table.clone(class.ability)
		base.id = baseId
		local list: { Entry } = {
			{ id = baseId, classId = classId, slot = 1, unlockLevel = ClassAbilities.UNLOCK_LEVELS[1], def = base },
		}
		for i, alt in ALTERNATES[classId] or {} do
			local def = table.clone(alt)
			table.insert(list, {
				id = def.id :: string,
				classId = classId,
				slot = i + 1,
				unlockLevel = ClassAbilities.UNLOCK_LEVELS[i + 1],
				def = def,
			})
		end
		for _, e in list do
			table.freeze(e.def)
			byId[e.id] = e
		end
		byClass[classId] = list
	end
end

ClassAbilities.byId = byId

function ClassAbilities.get(abilityId: any): Entry?
	if type(abilityId) ~= "string" then
		return nil
	end
	return byId[abilityId]
end

-- Base first, then the alternates in unlock order (empty for an unknown class).
function ClassAbilities.forClass(classId: string): { Entry }
	return byClass[classId] or {}
end

function ClassAbilities.baseId(classId: string): string?
	return BASE_IDS[classId]
end

-- A fresh, mutable copy of an ability's AbilityDef (nil if unknown).
function ClassAbilities.defCopy(abilityId: string): AbilityDef?
	local e = byId[abilityId]
	return if e then table.clone(e.def) else nil
end

return ClassAbilities
