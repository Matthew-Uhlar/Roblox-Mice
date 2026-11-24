--!strict
-- The 11 playable elephants (GDD §4; Tinkerphant is iteration 6; Ele Vation, Elephaid and
-- Trunkillery are iteration 7). Pure data, loads in Lune.
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
--   * v4 PvP (V4-A M3): crits land on heroes at half bonus (Combat/World
--     PVP_CRIT_BONUS); weapon `pvpMult` scales one class's damage to heroes.
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
	"tinkerphant", -- (iteration 6, team Builder)
	-- (iteration 7, team Classes)
	"ele_vation",
	"elephaid",
	"trunkillery",
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
			pvpMult = 0.8, -- v4: the fastest 1v1 (CombatTtk)
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
			pvpMult = 0.75, -- v4: Geyser + jets were among the fastest 1v1s (CombatTtk)
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
			damage = 10, -- v4: 9 -> 10 (V4-A M3)
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
			pvpMult = 1.0, -- v4: the 0.5 s per-attacker lockout already caps its 0.35 s thrusts (CombatTtk)
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
			pvpMult = 1.3, -- v4: cleavers re-hit at the lockout, the slowest 1v1 (CombatTtk)
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
		unlockCost = 6000, -- iteration 6 (Economy x1.5 above the cheapest paid tier): was 4000
		baseStats = { pickupRadius = 10.4 },
		weapon = {
			kind = "cone",
			damage = 13, -- v4: 10 -> 13 (V4-A M3; Updraft's gust also slows rival heroes)
			cooldown = 1.0,
			range = 14,
			count = 1,
			speed = 0,
			pierce = 99,
			area = 70,
			knockback = 14,
			pvpMult = 1.1, -- v4: the slowest duellist (CombatTtk)
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
		unlockCost = 6000, -- iteration 6 (Economy x1.5 above the cheapest paid tier): was 4000
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
			pvpMult = 0.8, -- v4: the AoE lob won every trade (V4-A M3)
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
	-- (iteration 6, team Builder) The engineer: turrets, barricades and repairs are
	-- World "build" entities (Combat/World builds, Combat/Weapons ABILITY.turret /
	-- barricade / repair). Cheese or the stomp track only: never a Robux pass.
	tinkerphant = {
		id = "tinkerphant",
		name = "Tinkerphant",
		role = "Engineer",
		description = "A tinkering engineer who bolts together rivet turrets and barricades.",
		color = { 210, 170, 60 },
		unlockCost = 6000, -- iteration 6 (Economy x1.5 above the cheapest paid tier): was 4000
		noPassUnlock = true,
		baseStats = { buildHpMult = 1.25 },
		weapon = {
			kind = "bolt",
			damage = 11,
			cooldown = 0.65,
			range = 26,
			count = 1,
			speed = 75,
			pierce = 0,
			area = 0,
			knockback = 1,
			pvpMult = 1.0,
		},
		ability = {
			kind = "turret",
			name = "Deploy Turret",
			description = "Bolt down a rivet turret that shoots the nearest mouse for 20 seconds (2 at once).",
			cooldown = 10,
			damage = 5, -- per rivet
			area = 40, -- targeting range
			distance = 30, -- cast range
			duration = 20, -- lifetime
			hp = 120,
		},
		passiveText = "Sturdy Builds: +25% turret and barricade HP.",
	},
	-- (iteration 7, team Classes) docs/iter/7/ZWL-NEXT.md §2. Cheese or the stomp track
	-- only (noPassUnlock): never a Robux pass. Weapon ranges stay inside the client's
	-- ability auto-aim range (70): Ele Vation's 60 x Steady Trunk's 1.15 = 69.
	ele_vation = {
		id = "ele_vation",
		name = "Ele Vation",
		role = "Marksman",
		description = "A calm sharpshooter with a long peanut rifle. Wins fights from 60 studs away.",
		color = { 120, 150, 110 },
		unlockCost = 6000,
		noPassUnlock = true,
		baseStats = { steadyAim = 0.3 },
		weapon = {
			kind = "bolt",
			damage = 34,
			cooldown = 1.5,
			range = 60,
			count = 1,
			speed = 140,
			pierce = 2,
			area = 0.8,
			knockback = 2,
			pvpMult = 0.55, -- long range must not decide PvP
		},
		ability = {
			kind = "lance",
			name = "Long Shot",
			description = "A laser sight, then one shot that pierces everything on a 90-stud line.",
			cooldown = 9,
			damage = 70,
			area = 1.5, -- half width
			distance = 90, -- line length
			duration = 0, -- no burning line
		},
		passiveText = "Steady Trunk: after standing still for 1 s, +30% weapon damage and +15% range.",
	},
	elephaid = {
		id = "elephaid",
		name = "Elephaid",
		role = "Field Medic",
		description = "A field medic with a herbal spritzer who keeps the whole squad on its feet.",
		color = { 235, 235, 245 },
		unlockCost = 6000,
		noPassUnlock = true,
		baseStats = { reviveSpeedMult = 2, allyHealShare = 0.15 },
		weapon = {
			kind = "bolt",
			damage = 16, -- (CombatTtk) few, bigger spritzes: PvP armour and lockout eat tiny hits
			cooldown = 0.8,
			range = 32,
			count = 1,
			speed = 70,
			pierce = 0,
			area = 0,
			knockback = 1,
			pvpMult = 0.75,
		},
		ability = {
			kind = "tether",
			name = "Lifeline",
			description = "Link to a squadmate for 5 s, healing 4% of their max HP every 0.5 s. "
				.. "No squadmate near: links to yourself at half rate.",
			cooldown = 10,
			damage = 0,
			area = 0,
			distance = 35, -- link range
			duration = 5,
			heal = 0.04, -- max-HP share per 0.5 s tick
			breakRange = 45,
		},
		passiveText = "Bedside Manner: revives twice as fast; 15% of your damage heals the lowest-HP squadmate nearby.",
	},
	trunkillery = {
		id = "trunkillery",
		-- display name: "Trunkillery" contains "killer" (ConfigData kid-friendly names rule);
		-- the id stays "trunkillery"
		name = "Trunktillery",
		role = "Artillery",
		description = "A heavy elephant with a coconut mortar. Mediocre on the move, devastating dug in.",
		color = { 125, 110, 80 },
		unlockCost = 6000,
		noPassUnlock = true,
		baseStats = { armor = 2, areaMult = 1.15, unshakable = 1 },
		weapon = {
			kind = "lob",
			damage = 26,
			cooldown = 1.8,
			range = 55,
			count = 1,
			speed = 45,
			pierce = 0,
			area = 7,
			knockback = 3,
			pvpMult = 0.7, -- (CombatTtk) rooted to hit hard: the duel band needs it
		},
		ability = {
			kind = "anchor",
			name = "Dig In",
			description = "Root yourself for 8 s: mortar range x1.6, damage x1.5, area x1.3, +3 armour. "
				.. "Cast again to dig out.",
			cooldown = 10,
			damage = 0,
			area = 0,
			duration = 8,
			rangeMult = 1.6,
			damageMult = 1.5,
			areaMult = 1.3,
			armorAdd = 3,
		},
		passiveText = "Heavy Plating: +2 armour, +15% area, immune to slows from mice and bosses.",
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
