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
--   (iteration 6, Tinkerphant; World "build" entities, Combat/World builds)
--   turret     distance = cast range, area = targeting range, damage per rivet,
--              duration = lifetime, hp (x stats.buildHpMult); World.TURRET_CAP per hero
--   barricade  distance = cast range, area = half length (wall across the aim line),
--              duration = lifetime, hp; blocks mice and enemy heroes, not projectiles
--   repair     area = radius around the caster; heal = squadmates' max-HP share,
--              own turrets / barricades heal Weapons.REPAIR_BUILD_MULT x that share
--   (iteration 6, team Abilities) advanced abilities, ADVANCED below
--   chain   distance = reach to the first target, damage, jumps = extra targets
--           (each x Weapons.CHAIN_ABILITY_FALLOFF), area = jump range
--   vortex  distance = cast range, area = radius, damage per 0.5 s tick, duration,
--           pull = studs pulled toward the centre per tick
--   leap    distance = max leap, duration = air time (immune), area = landing radius,
--           damage on landing
--   mark    distance = cast range, area = mark radius, duration = fuse; each marked
--           mouse / foe still alive then pops for damage (Weapons.MARK_POP_RADIUS)
-- Ids are global and stable (saved in profiles): "<classId>_<slug>".
--
-- (iteration 6) Unlock gates: base L1, alternates L5 / L15, then ADVANCED: class level
-- 25, Prestige 3, Prestige 10 and Ascension node 6 (the `ascended` signature). An entry
-- has unlockLevel and optionally unlockPrestige / unlockNode (Data/ClassProgress checks).

local Types = require("../Types")
local Classes = require("./Classes")

type AbilityDef = Types.AbilityDef

export type Entry = {
	id: string,
	classId: string,
	slot: number, -- list index: 1 = base, 2-3 = alternates, 4-7 = (iteration 6) advanced
	unlockLevel: number,
	unlockPrestige: number?, -- (iteration 6) also needs this Prestige
	unlockNode: number?, -- (iteration 6) also needs this many Ascension nodes
	def: AbilityDef, -- full AbilityDef (def.id == id)
}

local ClassAbilities = {}

ClassAbilities.UNLOCK_LEVELS = table.freeze({ 1, 5, 15 })
-- (iteration 5, A3) cooldown multiplier per equipped SLOT (Run/Stats.compute applies it
-- to the def in that slot). The balance lever for extra slots: raise slots 2-3, never
-- slot 1 (docs/iter/5/PLAN.md A3).
ClassAbilities.SLOT_COOLDOWN_MULT = table.freeze({ 1, 1.25, 1.25, 1.35 }) -- (iteration 6) slot 4
-- (iteration 6) gates of ADVANCED[classId][1..4]: level 25, Prestige 3, Prestige 10, node 6
ClassAbilities.ADVANCED_GATES = table.freeze({
	table.freeze({ level = 25 }),
	table.freeze({ level = 1, prestige = 3 }),
	table.freeze({ level = 1, prestige = 10 }),
	table.freeze({ level = 1, node = 6 }),
})

-- Base ability ids (the Config/Classes ability of each class).
local BASE_IDS: { [string]: string } = {
	elephante = "elephante_stampede",
	ele_fonte = "ele_fonte_geyser",
	ellie_fawn = "ellie_fawn_thorn_ring",
	le_fante = "le_fante_riposte",
	filet = "filet_sizzle",
	jumbo = "jumbo_updraft",
	fizzante = "fizzante_soda_geyser",
	tinkerphant = "tinkerphant_deploy_turret", -- (iteration 6, team Builder)
}

local ALTERNATES: { [string]: { AbilityDef } } = {
	elephante = {
		{
			id = "elephante_trunk_quake",
			kind = "ring",
			name = "Trunk Quake",
			description = "Slam the ground with your trunk: one heavy shockwave around you.",
			cooldown = 8,
			damage = 34,
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
			damage = 6,
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
			damage = 8,
			area = 13,
			duration = 3,
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
	-- (iteration 6, team Builder)
	tinkerphant = {
		{
			id = "tinkerphant_barricade",
			kind = "barricade",
			name = "Barricade",
			description = "Bolt a short wall across the aim point. Mice must go around it or chew through.",
			cooldown = 11,
			damage = 0,
			area = 7, -- half length: a 14-stud wall
			distance = 22,
			duration = 12,
			hp = 220,
		},
		{
			id = "tinkerphant_repair_pulse",
			kind = "repair",
			name = "Repair Pulse",
			description = "A wrench-shaped pulse: patches up your turrets, barricades and nearby squadmates.",
			cooldown = 12,
			damage = 0,
			area = 16,
			heal = 0.12,
		},
	},
}

-- (iteration 6, team Abilities) 4 more abilities per class, in gate order (see header).
-- Power budget: like the alternates; the 4th (ascended) is about x1.35 and flashier.
local ADVANCED: { [string]: { AbilityDef } } = {
	elephante = {
		{ id = "elephante_tusk_leap", kind = "leap", name = "Tusk Leap",
			description = "Leap at the aim point and land tusks-first, scattering mice.",
			cooldown = 9, damage = 40, area = 10, distance = 28, duration = 0.55 },
		{ id = "elephante_dust_devil", kind = "vortex", name = "Dust Devil",
			description = "Stamp up a spinning dust storm that drags mice into its middle.",
			cooldown = 12, damage = 6, area = 12, distance = 25, duration = 3, pull = 3 },
		{ id = "elephante_war_trumpet", kind = "ring", name = "War Trumpet",
			description = "A deafening trumpet blast that slams everything around you.",
			cooldown = 10, damage = 30, area = 15, duration = 0 },
		{ id = "elephante_titan_stomp", kind = "leap", name = "Titan Stomp", ascended = true,
			description = "Ascended: soar high and crash down in a ground-splitting shockwave.",
			cooldown = 14, damage = 70, area = 15, distance = 34, duration = 0.6 },
	},
	ele_fonte = {
		{ id = "ele_fonte_arc_spray", kind = "chain", name = "Arc Spray",
			description = "A jet of water that ricochets from mouse to mouse.",
			cooldown = 8, damage = 30, area = 14, distance = 40, jumps = 5 },
		{ id = "ele_fonte_whirlpool", kind = "vortex", name = "Whirlpool",
			description = "Open a whirlpool that sucks mice in and keeps them spinning.",
			cooldown = 12, damage = 7, area = 13, distance = 35, duration = 3.5, pull = 3 },
		{ id = "ele_fonte_tide_mark", kind = "mark", name = "Tide Mark",
			description = "Soak every mouse in an area; a moment later each one bursts.",
			cooldown = 10, damage = 34, area = 12, distance = 40, duration = 1.5 },
		{ id = "ele_fonte_maelstrom", kind = "vortex", name = "Maelstrom", ascended = true,
			description = "Ascended: a roaring maelstrom that swallows the whole horde.",
			cooldown = 15, damage = 11, area = 17, distance = 40, duration = 4.5, pull = 4 },
	},
	ellie_fawn = {
		{ id = "ellie_fawn_vine_lash", kind = "chain", name = "Vine Lash",
			description = "A whipping vine that snaps from one mouse to the next.",
			cooldown = 8, damage = 28, area = 13, distance = 38, jumps = 6 },
		{ id = "ellie_fawn_seed_pods", kind = "mark", name = "Seed Pods",
			description = "Pelt an area with seed pods that sprout and pop a moment later.",
			cooldown = 10, damage = 32, area = 12, distance = 42, duration = 1.6 },
		{ id = "ellie_fawn_tangle_snare", kind = "vortex", name = "Tangle Snare",
			description = "Roots burst up and drag mice into a thorny knot.",
			cooldown = 12, damage = 6, area = 12, distance = 35, duration = 3, pull = 2.5 },
		{ id = "ellie_fawn_heartwood_bloom", kind = "ring", name = "Heartwood Bloom", ascended = true,
			description = "Ascended: an ancient tree blooms around you, lashing the horde for seconds.",
			cooldown = 15, damage = 14, area = 15, duration = 4 },
	},
	le_fante = {
		{ id = "le_fante_balestra", kind = "leap", name = "Balestra",
			description = "A jumping attack: hop in and strike everything where you land.",
			cooldown = 7, damage = 38, area = 8, distance = 24, duration = 0.4 },
		{ id = "le_fante_touche", kind = "mark", name = "Touche",
			description = "Flick a mark onto every mouse nearby; each mark pops a moment later.",
			cooldown = 9, damage = 40, area = 9, distance = 30, duration = 1.2 },
		{ id = "le_fante_flicker_blades", kind = "chain", name = "Flicker Blades",
			description = "A flurry of thrusts that hops between targets.",
			cooldown = 8, damage = 30, area = 12, distance = 26, jumps = 5 },
		{ id = "le_fante_grand_finale", kind = "mark", name = "Grand Finale", ascended = true,
			description = "Ascended: a dazzling salute marks the crowd; every mark explodes at once.",
			cooldown = 14, damage = 70, area = 13, distance = 34, duration = 1.4 },
	},
	filet = {
		{ id = "filet_chili_chain", kind = "chain", name = "Chili Chain",
			description = "A fiery chili that bounces between mice.",
			cooldown = 8, damage = 28, area = 13, distance = 34, jumps = 5 },
		{ id = "filet_stew_whirl", kind = "vortex", name = "Stew Whirl",
			description = "Stir a bubbling stew vortex that pulls mice into the pot.",
			cooldown = 12, damage = 7, area = 12, distance = 30, duration = 3.5, pull = 3 },
		{ id = "filet_skillet_slam", kind = "leap", name = "Skillet Slam",
			description = "Jump and smash down with a giant skillet.",
			cooldown = 9, damage = 42, area = 11, distance = 26, duration = 0.5 },
		{ id = "filet_inferno_banquet", kind = "puddle", name = "Inferno Banquet", ascended = true,
			description = "Ascended: flip a blazing banquet table into a sea of fire.",
			cooldown = 15, damage = 12, area = 15, distance = 34, duration = 5 },
	},
	jumbo = {
		{ id = "jumbo_twister", kind = "vortex", name = "Twister",
			description = "Flap up a twister that drags mice off their feet.",
			cooldown = 12, damage = 6, area = 13, distance = 30, duration = 3, pull = 3.5 },
		{ id = "jumbo_sky_drop", kind = "leap", name = "Sky Drop",
			description = "Fly up and drop onto the aim point like a boulder.",
			cooldown = 10, damage = 44, area = 11, distance = 34, duration = 0.7 },
		{ id = "jumbo_static_ears", kind = "chain", name = "Static Ears",
			description = "Rub your ears for a crackling spark that jumps through the horde.",
			cooldown = 9, damage = 30, area = 14, distance = 36, jumps = 6 },
		{ id = "jumbo_hurricane", kind = "vortex", name = "Hurricane", ascended = true,
			description = "Ascended: a full hurricane that hauls in everything around it.",
			cooldown = 15, damage = 10, area = 18, distance = 36, duration = 4.5, pull = 4.5 },
	},
	fizzante = {
		{ id = "fizzante_mint_mark", kind = "mark", name = "Mint Mark",
			description = "Drop mints on the crowd; a moment later every marked mouse fizzes over.",
			cooldown = 10, damage = 38, area = 12, distance = 38, duration = 1.5 },
		{ id = "fizzante_cola_arc", kind = "chain", name = "Cola Arc",
			description = "A sticky jet of cola that splashes from mouse to mouse.",
			cooldown = 8, damage = 30, area = 13, distance = 36, jumps = 5 },
		{ id = "fizzante_float_hop", kind = "leap", name = "Float Hop",
			description = "Bounce on a cloud of foam and land with a splash.",
			cooldown = 9, damage = 40, area = 12, distance = 28, duration = 0.6 },
		{ id = "fizzante_mega_eruption", kind = "mark", name = "Mega Eruption", ascended = true,
			description = "Ascended: shake the whole crowd; every one of them erupts at once.",
			cooldown = 15, damage = 64, area = 16, distance = 40, duration = 1.6 },
	},
	tinkerphant = {
		{ id = "tinkerphant_tesla_arc", kind = "chain", name = "Tesla Arc",
			description = "A coil discharge that arcs through the nearest mice.",
			cooldown = 8, damage = 28, area = 13, distance = 36, jumps = 6 },
		{ id = "tinkerphant_magnet_field", kind = "vortex", name = "Magnet Field",
			description = "A big magnet that drags mice together and grinds them.",
			cooldown = 12, damage = 6, area = 13, distance = 30, duration = 3.5, pull = 3 },
		{ id = "tinkerphant_rocket_boots", kind = "leap", name = "Rocket Boots",
			description = "Blast off on rocket boots and land in a fiery thump.",
			cooldown = 9, damage = 40, area = 11, distance = 30, duration = 0.5 },
		{ id = "tinkerphant_demolition_charge", kind = "mark", name = "Demolition Charge", ascended = true,
			description = "Ascended: tag the whole crowd with charges and blow them all at once.",
			cooldown = 15, damage = 66, area = 15, distance = 36, duration = 1.5 },
	},
}
ClassAbilities.ADVANCED = ADVANCED

local byId: { [string]: Entry } = {}
local byClass: { [string]: { Entry } } = {}

for _, classId in Classes.ORDER do
	local class = Classes.get(classId)
	local baseId = BASE_IDS[classId]
	if class and baseId then
		local base = table.clone(class.ability)
		base.id = baseId
		local list: { Entry } = {
			{
				id = baseId,
				classId = classId,
				slot = 1,
				unlockLevel = ClassAbilities.UNLOCK_LEVELS[1],
				def = base,
			},
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
		-- (iteration 6) the advanced abilities, behind their gates
		for i, adv in ADVANCED[classId] or {} do
			local gate = ClassAbilities.ADVANCED_GATES[i]
			if gate then
				local def = table.clone(adv)
				table.insert(list, {
					id = def.id :: string,
					classId = classId,
					slot = #list + 1,
					unlockLevel = gate.level,
					unlockPrestige = gate.prestige,
					unlockNode = gate.node,
					def = def,
				})
			end
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
