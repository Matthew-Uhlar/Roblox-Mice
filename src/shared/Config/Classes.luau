--!strict
-- The 7 playable elephants (GDD §4). Pure data, loads in Lune.
--
-- Conventions (Team A):
--   * `baseStats` are ABSOLUTE overrides on top of Stats.DEFAULT (so Elephante's
--     "+25% max HP" is written as maxHp = 125 when DEFAULT.maxHp is 100).
--   * Weapon `area` is a radius in studs for melee_arc / lob / puddle / orbit
--     (hit radius of each orbiter), and an angle in degrees for spread / cone.
--   * Orbit weapons: `range` is the orbit radius and `speed` the tangential speed
--     in studs/s; `cooldown` is the per-enemy re-hit interval.
--   * Ability `distance` is the dash length or the max cast range for aimed
--     abilities; `damage` is per hit (or per tick for ring / puddle / field).
--   * Filet's GDD passive is "crumbs heal 1 HP". PlayerStats has no field for
--     that yet, so it is implemented as regen = 1 hp/s until the Lead adds a
--     `crumbHeal` stat (reported as an open issue).

local Types = require("../Types")

type ClassDef = Types.ClassDef

local Classes = {}

Classes.ORDER = {
	"elephante",
	"ele_fonte",
	"ellie_fawn",
	"le_fante",
	"filet",
	"jumbo",
	"fizzante",
}

Classes.DEFAULT_ID = "elephante"

local defs: { [string]: ClassDef } = {
	elephante = {
		id = "elephante",
		name = "Elephante",
		role = "Brawler",
		description = "A big grey wall of muscle. Slams everything in front of the trunk.",
		color = { 150, 150, 165 },
		unlockCost = 0,
		baseStats = { maxHp = 125, armor = 1 },
		weapon = {
			kind = "melee_arc",
			damage = 18,
			cooldown = 0.9,
			range = 10,
			count = 1,
			speed = 0,
			pierce = 99,
			area = 9,
			knockback = 6,
		},
		ability = {
			kind = "dash",
			name = "Stampede",
			description = "Charge forward, trampling and knocking back every mouse in the way.",
			cooldown = 8,
			damage = 30,
			area = 6,
			distance = 24,
			duration = 0.4,
		},
		passiveText = "Thick Skin: +25% max HP.",
	},
	ele_fonte = {
		id = "ele_fonte",
		name = "Ele Fonte",
		role = "Water mage",
		description = "A walking fountain. Fires water jets that punch through lines of mice.",
		color = { 80, 160, 230 },
		unlockCost = 0,
		baseStats = { pierceBonus = 1 },
		weapon = {
			kind = "bolt",
			damage = 14,
			cooldown = 0.7,
			range = 45,
			count = 1,
			speed = 70,
			pierce = 2,
			area = 0,
			knockback = 1,
		},
		ability = {
			kind = "burst",
			name = "Geyser",
			description = "Erupt a geyser at the target, blasting every mouse in the splash.",
			cooldown = 7,
			damage = 45,
			area = 12,
			distance = 40,
		},
		passiveText = "Pressure Washer: +1 pierce on every shot.",
	},
	ellie_fawn = {
		id = "ellie_fawn",
		name = "Ellie Fawn",
		role = "Ranger",
		description = "A nimble forest ranger who sprays peanuts in a wide fan.",
		color = { 120, 190, 100 },
		unlockCost = 0,
		baseStats = { moveSpeed = 18.4 },
		weapon = {
			kind = "spread",
			damage = 9,
			cooldown = 0.8,
			range = 40,
			count = 3,
			speed = 60,
			pierce = 0,
			area = 30,
			knockback = 1,
		},
		ability = {
			kind = "ring",
			name = "Thorn Ring",
			description = "Grow a ring of thorns around you that shreds mice for a few seconds.",
			cooldown = 9,
			damage = 12,
			area = 14,
			duration = 4,
		},
		passiveText = "Light Hooves: +15% move speed.",
	},
	le_fante = {
		id = "le_fante",
		name = "Le F'ante",
		role = "Duelist",
		description = "En garde! A French fencer whose rapier thrusts land critical hits.",
		color = { 170, 90, 160 },
		unlockCost = 2500,
		baseStats = { critChance = 0.2 },
		weapon = {
			kind = "cone",
			damage = 8,
			cooldown = 0.35,
			range = 11,
			count = 1,
			speed = 0,
			pierce = 99,
			area = 40,
			knockback = 1,
		},
		ability = {
			kind = "shield",
			name = "Riposte",
			description = "Parry: become invulnerable for a moment, then explode in a counter-burst.",
			cooldown = 10,
			damage = 50,
			area = 10,
			duration = 1.2,
		},
		passiveText = "Panache: +15% crit chance.",
	},
	filet = {
		id = "filet",
		name = "Filet",
		role = "Chef",
		description = "A chef with cleavers whirling around them. Leaves sizzling oil behind.",
		color = { 230, 90, 70 },
		unlockCost = 2500,
		baseStats = { regen = 1 },
		weapon = {
			kind = "orbit",
			damage = 10,
			cooldown = 0.5,
			range = 8,
			count = 2,
			speed = 25,
			pierce = 99,
			area = 2,
			knockback = 2,
		},
		ability = {
			kind = "puddle",
			name = "Sizzle",
			description = "Splash a pool of hot oil that burns every mouse that crosses it.",
			cooldown = 8,
			damage = 8,
			area = 10,
			distance = 25,
			duration = 5,
		},
		passiveText = "Taste Tester: regenerate 1 HP every second.",
	},
	jumbo = {
		id = "jumbo",
		name = "Jumbo",
		role = "Flyer",
		description = "Ears so big they fly. Flaps gusts that blow mice away.",
		color = { 240, 170, 200 },
		unlockCost = 4000,
		baseStats = { pickupRadius = 10.4 },
		weapon = {
			kind = "cone",
			damage = 10,
			cooldown = 1.0,
			range = 14,
			count = 1,
			speed = 0,
			pierce = 99,
			area = 70,
			knockback = 14,
		},
		ability = {
			kind = "hover",
			name = "Updraft",
			description = "Take off for 2 seconds: immune to contact damage, then land with a gust.",
			cooldown = 12,
			damage = 20,
			area = 10,
			duration = 2,
		},
		passiveText = "Big Ears: +30% pickup radius.",
	},
	fizzante = {
		id = "fizzante",
		name = "Fizzante",
		role = "Alchemist",
		description = "A fizzy alchemist who lobs exploding soda bombs.",
		color = { 255, 140, 30 },
		unlockCost = 4000,
		baseStats = { areaMult = 1.2 },
		weapon = {
			kind = "lob",
			damage = 20,
			cooldown = 1.4,
			range = 30,
			count = 1,
			speed = 40,
			pierce = 0,
			area = 7,
			knockback = 3,
		},
		ability = {
			kind = "field",
			name = "Soda Geyser",
			description = "Flood an area with sticky soda that hugely slows and damages mice.",
			cooldown = 14,
			damage = 6,
			area = 18,
			distance = 30,
			duration = 6,
		},
		passiveText = "Carbonated: +20% area.",
	},
}

Classes.defs = defs

function Classes.get(id: string): ClassDef?
	return defs[id]
end

function Classes.isFree(id: string): boolean
	local def = defs[id]
	return def ~= nil and def.unlockCost == 0
end

-- Ids of the classes every new profile owns.
function Classes.freeIds(): { string }
	local out = {}
	for _, id in Classes.ORDER do
		if defs[id].unlockCost == 0 then
			table.insert(out, id)
		end
	end
	return out
end

return Classes
