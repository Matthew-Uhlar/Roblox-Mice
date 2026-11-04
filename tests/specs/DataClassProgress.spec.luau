local T = require("../lib/Test")
local ClassProgress = require("../../src/shared/Data/ClassProgress")
local ClassPerks = require("../../src/shared/Config/ClassPerks")
local ClassAbilities = require("../../src/shared/Config/ClassAbilities")
local ClassSkins = require("../../src/shared/Config/ClassSkins")
local Classes = require("../../src/shared/Config/Classes")
local Monetization = require("../../src/shared/Config/Monetization")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local Award = require("../../src/shared/Data/Award")
local Passes = require("../../src/shared/Data/Passes")
local Receipts = require("../../src/shared/Data/Receipts")
local Shop = require("../../src/shared/Data/Shop")
local Looks = require("../../src/shared/Data/Looks")
local Stats = require("../../src/shared/Run/Stats")

local VALID_KINDS =
	{ dash = true, burst = true, ring = true, shield = true, puddle = true, hover = true, field = true }

local function state(level: number): any
	return { xp = 0, level = level, perks = {} }
end

-- Rough "overall power" of a computed hero relative to its level-1 self (balance guard).
-- Damage per cast (per mouse) x sqrt(area) / cooldown, by Combat/Weapons tick rules.
local TICK = { ring = 0.5, puddle = 0.4, field = 0.5 }
local function abilityPower(a: any): number
	local hits = 1
	local tick = TICK[a.kind]
	if tick and a.duration and a.duration > 0 then
		hits = (if a.kind == "ring" then 1 else 0) + a.duration / tick
	end
	local p = a.damage * hits * math.sqrt(a.area) / a.cooldown
	if a.distance then
		p *= a.distance ^ 0.25
	end
	return p
end
local function power(classId: string, classState: any): number
	local s0, w0, a0 = Stats.compute(classId, {}, {})
	local s, w, a = Stats.compute(classId, {}, {}, nil, nil, classState)
	local function crit(x: any): number
		return 1 + x.critChance * (x.critMult - 1)
	end
	local off = (s.damageMult / s0.damageMult)
		* (s.attackSpeedMult / s0.attackSpeedMult)
		* (crit(s) / crit(s0))
		* (1 + 0.5 * (s.areaMult / s0.areaMult - 1))
		* (1 + 0.5 * ((w.count + s.projectileBonus) / (w0.count + s0.projectileBonus) - 1))
		* (w.damage / w0.damage)
		* (1 + 0.06 * (s.pierceBonus - s0.pierceBonus))
		* (1 + 0.08 * (s.chain - s0.chain))
		* (1 + 0.015 * (s.explodeOnKill - s0.explodeOnKill))
		* (1 + 0.15 * (s.extraOrbiters - s0.extraOrbiters))
		* (1 + 0.25 * (abilityPower(a) * (s0.cooldownMult / s.cooldownMult) / abilityPower(a0) - 1))
	local def = (s.maxHp / s0.maxHp)
		* (1 + 0.04 * (s.armor - s0.armor))
		* (1 + 0.05 * (s.regen - s0.regen))
		* (1 + 2 * (s.lifesteal - s0.lifesteal))
		* (1 + 0.5 * (s.moveSpeed / s0.moveSpeed - 1))
	return off ^ 0.6 * def ^ 0.4
end

T.describe("Config/ClassPerks", function()
	T.it("every class has 3 branches x 5 tiers with costs 1..5 and unique ids", function()
		local seen = {}
		for _, cid in Classes.ORDER do
			local branches = ClassPerks.branches(cid)
			T.eq(#branches, 3, cid)
			for bi, b in branches do
				T.eq(#b.perks, 5, cid .. " " .. b.id)
				T.truthy(#b.name > 0 and #b.theme > 0)
				for tier, def in b.perks do
					T.falsy(seen[def.id], def.id)
					seen[def.id] = true
					T.eq(def.tier, tier)
					T.eq(def.cost, tier)
					T.eq(def.branchIndex, bi)
					T.eq(def.classId, cid)
					T.truthy(#def.id <= ProfileSchema.MAX_KEY_LEN, def.id)
					T.eq(ClassPerks.get(def.id), def)
				end
			end
		end
	end)
	T.it("perk effects are real stats and moderate (never bigger than an Epic card)", function()
		for _, cid in Classes.ORDER do
			for _, def in ClassPerks.forClass(cid) do
				T.truthy(#def.description > 0, def.id)
				local any = def.abilityMul ~= nil
				for k, v in def.delta.add or {} do
					any = true
					T.truthy(Stats.DEFAULT[k] ~= nil, def.id .. " add." .. k)
					T.truthy(v > 0 and v <= 5, def.id .. " add." .. k)
				end
				for k, v in def.delta.mul or {} do
					any = true
					T.truthy(Stats.DEFAULT[k] ~= nil, def.id .. " mul." .. k)
					T.truthy(v >= 0.9 and v <= 1.15 and v ~= 1, def.id .. " mul." .. k)
				end
				for k, v in def.delta.weapon or {} do
					any = true
					T.truthy(k == "knockback" or k == "range", def.id .. " weapon." .. k)
					T.truthy(v > 0 and v <= 4, def.id)
				end
				for k, v in def.abilityMul or {} do
					T.truthy(
						k == "damage" or k == "area" or k == "duration" or k == "distance",
						def.id .. " " .. k
					)
					T.truthy(v > 1 and v <= 1.15, def.id .. " ability." .. k)
				end
				T.truthy(any, def.id .. " does something")
				if def.behaviour then
					T.truthy((def.delta.add or {})[def.behaviour] ~= nil, def.id .. " behaviour is its stat")
				end
			end
		end
	end)
	T.it("a fully specced level-30 hero is about +25-30% (best build), never over +35%", function()
		local COST = { 0, 1, 3, 6, 10, 15 } -- points for branch depth 0..5
		for _, cid in Classes.ORDER do
			local branches = ClassPerks.branches(cid)
			local best, worst = 0, math.huge
			for d1 = 0, 5 do
				for d2 = 0, 5 do
					for d3 = 0, 5 do
						local cost = COST[d1 + 1] + COST[d2 + 1] + COST[d3 + 1]
						if cost <= 29 and cost >= 25 then
							local perks = {}
							for bi, d in { d1, d2, d3 } do
								for t = 1, d do
									perks[branches[bi].perks[t].id] = true
								end
							end
							local pw = power(cid, { perks = perks, level = 30 })
							best = math.max(best, pw)
							worst = math.min(worst, pw)
						end
					end
				end
			end
			T.truthy(best >= 1.22 and best <= 1.35, string.format("%s best %.3f", cid, best))
			T.truthy(worst >= 1.1, string.format("%s worst full build %.3f", cid, worst))
		end
	end)
end)

T.describe("Config/ClassAbilities", function()
	T.it("base + 2 alternates per class, unlocking at 1 / 5 / 15, valid kinds", function()
		local seen = {}
		for _, cid in Classes.ORDER do
			local list = ClassAbilities.forClass(cid)
			T.eq(#list, 3, cid)
			T.eq(list[1].id, ClassAbilities.baseId(cid))
			T.deepEq({ list[1].unlockLevel, list[2].unlockLevel, list[3].unlockLevel }, { 1, 5, 15 })
			local names, kinds = {}, {}
			for i, e in list do
				T.falsy(seen[e.id], e.id)
				seen[e.id] = true
				T.eq(e.def.id, e.id)
				T.eq(e.slot, i)
				T.truthy(VALID_KINDS[e.def.kind], e.id)
				T.truthy(e.def.cooldown > 0 and e.def.damage > 0 and e.def.area > 0, e.id)
				T.falsy(names[e.def.name], e.id .. " distinct name")
				names[e.def.name] = true
				kinds[e.def.kind] = true
			end
			local n = 0
			for _ in kinds do
				n += 1
			end
			T.eq(n, 3, cid .. " alternates use different kinds from the base")
			local base = Classes.get(cid) :: any
			for k, v in base.ability do
				T.eq((list[1].def :: any)[k], v, cid .. " base keeps " .. k)
			end
		end
	end)
	T.it("alternates are sidegrades: no power creep over max(own base, median base)", function()
		local bases = {}
		for _, cid in Classes.ORDER do
			table.insert(bases, abilityPower(ClassAbilities.forClass(cid)[1].def))
		end
		table.sort(bases)
		local median = bases[math.ceil(#bases / 2)]
		for _, cid in Classes.ORDER do
			local list = ClassAbilities.forClass(cid)
			local ref = math.max(abilityPower(list[1].def), median)
			for i = 2, 3 do
				local r = abilityPower(list[i].def) / ref
				T.truthy(r >= 0.1 and r <= 1.25, string.format("%s %.2f", list[i].id, r))
			end
		end
	end)
end)

T.describe("Config/ClassSkins", function()
	T.it("4 earned skins at 3/10/20/30 plus the paid sets, with drawable colours and accessories", function()
		for _, cid in Classes.ORDER do
			local earned, paid = 0, 0
			for _, def in ClassSkins.forClass(cid) do
				T.eq(ClassSkins.get(def.id), def)
				T.truthy(ClassSkins.ACCESSORIES[def.accessory], def.id .. " accessory")
				for _, k in { "body", "accent", "trim" } do
					T.truthy(Looks.validRgb((def.colors :: any)[k]), def.id .. " " .. k)
				end
				if def.source == "level" then
					earned += 1
					T.eq(def.unlockLevel, ClassSkins.UNLOCK_LEVELS[earned])
					T.eq(def.priceGolden, nil, "earned skins are never sold")
				else
					paid += 1
					local pass = Monetization.get(def.passKey :: string)
					T.truthy(pass and pass.kind == "pass", def.id)
					T.truthy((def.priceGolden or 0) > 0, def.id)
				end
			end
			T.eq(earned, 4, cid)
			T.truthy(paid >= 1, cid)
		end
	end)
	T.it("mastery titles Bronze/Silver/Gold Herd at 10/20/30", function()
		T.eq(ClassProgress.mastery(1), "none")
		T.eq(ClassProgress.mastery(9), "none")
		T.eq(ClassProgress.mastery(10), "bronze")
		T.eq(ClassProgress.mastery(19), "bronze")
		T.eq(ClassProgress.mastery(20), "silver")
		T.eq(ClassProgress.mastery(30), "gold")
		T.eq((ClassSkins.masteryByTier("gold") :: any).title, "Gold Herd")
	end)
end)

T.describe("ClassProgress: XP", function()
	T.it("level n needs floor(100 * n^1.4) XP; nothing past 30", function()
		T.eq(ClassProgress.xpToNext(1), 100)
		T.eq(ClassProgress.xpToNext(2), math.floor(100 * 2 ^ 1.4 + 0.5))
		T.eq(ClassProgress.xpToNext(10), math.floor(100 * 10 ^ 1.4 + 0.5))
		T.eq(ClassProgress.xpToNext(30), 0)
		T.eq(ClassProgress.xpToNext(0 / 0), 100)
	end)
	T.it("addXp levels up through several levels and caps at 30", function()
		local st = state(1)
		local _, gained = ClassProgress.addXp(st, 100 + ClassProgress.xpToNext(2) + 5)
		T.eq(gained, 2)
		T.eq(st.level, 3)
		T.eq(st.xp, 5)
		local _, g2 = ClassProgress.addXp(st, 1e9)
		T.eq(st.level, 30)
		T.eq(st.xp, 0)
		T.eq(g2, 27)
		T.eq(select(2, ClassProgress.addXp(st, 500)), 0)
		for _, junk in { 0 / 0, -5, math.huge, 0 } do
			local s2 = state(4)
			T.eq(select(2, ClassProgress.addXp(s2, junk)), 0)
			T.eq(s2.level, 4)
		end
	end)
	T.it("runXp: stages, boss share, downs, POIs, x1.5 when extracted", function()
		local W = ClassProgress.RUN_XP
		local base = { stagesSurvived = 3, bossDamageShare = 0.5, heroDowns = 2, pois = 4 }
		local raw = 3 * W.perStage + 0.5 * W.perBossShare + 2 * W.perHeroDown + 4 * W.perPoi
		T.eq(ClassProgress.runXp(base), math.floor(raw + 0.5))
		local ext = table.clone(base) :: any
		ext.extracted = true
		T.eq(ClassProgress.runXp(ext), math.floor(raw * 1.5 + 0.5))
		T.eq(ClassProgress.runXp(nil), 0)
		T.eq(ClassProgress.runXp({ stagesSurvived = 0 / 0, heroDowns = -3, pois = "x" }), 0)
		local huge = ClassProgress.runXp({
			stagesSurvived = 1e9,
			bossDamageShare = 1e9,
			heroDowns = 1e9,
			pois = 1e9,
			extracted = true,
		})
		T.truthy(huge <= ClassProgress.MAX_RUN_XP)
	end)
	T.it("reaching 30 takes a long time (100+ typical runs), the first alternate a few runs", function()
		local typical = ClassProgress.runXp({
			stagesSurvived = 3,
			bossDamageShare = 0.6,
			heroDowns = 2,
			pois = 5,
			extracted = true,
		})
		T.truthy(ClassProgress.totalXpFor(5) / typical <= 5, "level 5 within ~5 runs")
		T.truthy(ClassProgress.totalXpFor(30) / typical >= 100, "level 30 is long-term")
	end)
end)

T.describe("ClassProgress: perks", function()
	local bw = ClassPerks.branches("elephante")[1].perks
	T.it("1 point per level after the first; cost = tier", function()
		T.eq(ClassProgress.perkPoints(1), 0)
		T.eq(ClassProgress.perkPoints(30), 29)
		local st = state(4)
		T.eq(ClassProgress.perkPointsFree(st), 3)
		st.perks[bw[1].id] = true
		st.perks[bw[2].id] = true
		T.eq(ClassProgress.perkPointsFree(st), 0)
	end)
	T.it("canTake checks class, order, duplicates and points", function()
		local st = state(30)
		T.deepEq({ ClassProgress.canTake("elephante", st, "nope") }, { false, "unknown_perk" })
		T.deepEq({ ClassProgress.canTake("jumbo", st, bw[1].id) }, { false, "wrong_class" })
		T.deepEq({ ClassProgress.canTake("elephante", st, bw[2].id) }, { false, "locked_tier" })
		T.truthy(ClassProgress.takePerk("elephante", st, bw[1].id))
		T.deepEq({ ClassProgress.canTake("elephante", st, bw[1].id) }, { false, "taken" })
		T.truthy(ClassProgress.canTake("elephante", st, bw[2].id))
		local poor = state(2)
		T.truthy(ClassProgress.takePerk("elephante", poor, bw[1].id))
		T.deepEq({ ClassProgress.canTake("elephante", poor, bw[2].id) }, { false, "no_points" })
		T.deepEq({ ClassProgress.canTake("elephante", nil :: any, bw[1].id) }, { false, "no_points" })
	end)
	T.it("level 30 cannot take the whole tree (45 points) but fills two branches", function()
		local spec = ClassProgress.autoSpec("elephante", 30)
		local n = 0
		for _ in spec.perks do
			n += 1
		end
		T.truthy(n >= 10 and n < 15, "perks taken " .. n)
		T.eq(ClassProgress.perkPointsSpent({ xp = 0, level = 30, perks = spec.perks }) <= 29, true)
		T.deepEq(ClassProgress.autoSpec("elephante", 1).perks, {})
	end)
	T.it("sanitizePerks drops out-of-order, foreign and over-budget perks", function()
		local raw = { [bw[1].id] = true, [bw[3].id] = true, jumbo_gale_1 = true, junk = true }
		T.deepEq(ClassProgress.sanitizePerks("elephante", 30, raw), { [bw[1].id] = true })
		local full = {}
		for _, def in ClassPerks.forClass("elephante") do
			full[def.id] = true
		end
		local clean = ClassProgress.sanitizePerks("elephante", 30, full)
		local spent = ClassProgress.perkPointsSpent({ xp = 0, level = 30, perks = clean })
		T.truthy(spent <= 29 and spent >= 25, "spent " .. spent)
		T.deepEq(ClassProgress.sanitizePerks("elephante", 1, full), {})
		T.deepEq(ClassProgress.sanitizePerks("elephante", 30, "x"), {})
	end)
	T.it("respec cost scales with level", function()
		T.eq(ClassProgress.respecCost(1), ClassProgress.RESPEC_MIN)
		T.truthy(ClassProgress.respecCost(30) > ClassProgress.respecCost(10))
		T.eq(ClassProgress.respecCost(30), 3000)
	end)
end)

T.describe("ClassProgress: unlocks", function()
	T.it("alternate abilities unlock at 5 and 15", function()
		T.eq(#ClassProgress.unlockedAbilities("jumbo", 1), 1)
		T.eq(#ClassProgress.unlockedAbilities("jumbo", 5), 2)
		T.eq(#ClassProgress.unlockedAbilities("jumbo", 14), 2)
		T.eq(#ClassProgress.unlockedAbilities("jumbo", 15), 3)
		T.deepEq(ClassProgress.unlockedAbilities("nope", 30), {})
	end)
	T.it("earned skins unlock at 3/10/20/30; paid skins need ownership", function()
		T.eq(#ClassProgress.unlockedSkins("filet", 2), 0)
		T.eq(#ClassProgress.unlockedSkins("filet", 3), 1)
		T.eq(#ClassProgress.unlockedSkins("filet", 30), 4)
		T.falsy(ClassProgress.skinAllowed("filet", 30, "filet_gilded", {}))
		T.truthy(ClassProgress.skinAllowed("filet", 1, "filet_gilded", { filet_gilded = true }))
		T.falsy(ClassProgress.skinAllowed("jumbo", 30, "filet_line_cook", nil), "another class's skin")
	end)
	T.it("award reports levels, ability/skin unlocks, mastery and points", function()
		local p = ProfileSchema.default() :: any
		local st = p.classes.elephante
		local a = ClassProgress.award(p, "elephante", ClassProgress.totalXpFor(5)) :: any
		T.eq(a.level, 5)
		T.eq(a.levelsGained, 4)
		T.eq(a.perkPoints, 4)
		T.deepEq(a.abilities, { "elephante_trunk_quake" })
		T.deepEq(a.skins, { "elephante_field_grey" })
		T.eq(a.mastery, nil)
		st.level, st.xp = 9, 0
		local b = ClassProgress.award(p, "elephante", ClassProgress.xpToNext(9)) :: any
		T.eq(b.level, 10)
		T.deepEq(b.abilities, {})
		T.deepEq(b.skins, { "elephante_ironclad" })
		T.eq(b.mastery, "bronze")
		T.eq(ClassProgress.award(p, "nope", 100), nil)
		local c = ClassProgress.award(p, "elephante", 1) :: any
		T.eq(c.levelsGained, 0)
		T.eq(c.mastery, nil)
		local capped = ClassProgress.award(p, "ele_fonte", 1e9) :: any
		T.eq(capped.xp, ClassProgress.MAX_RUN_XP, "one run is capped")
	end)
end)

T.describe("ClassProgress: ShopService operations (pure validation)", function()
	local function rich(): any
		local p = ProfileSchema.default() :: any
		p.cheese = 10000
		p.classes.elephante.level = 20
		return p
	end
	T.it("SelectPerk validates ownership and canTake", function()
		local p = rich()
		T.deepEq({ ClassProgress.selectPerk(p, "jumbo", "jumbo_gale_1") }, { false, "class_locked", nil })
		T.deepEq({ ClassProgress.selectPerk(p, "nope", "x") }, { false, "bad_class", nil })
		T.deepEq({ ClassProgress.selectPerk(p, 5, "x") }, { false, "bad_class", nil })
		local ok, reason, def = ClassProgress.selectPerk(p, "elephante", "elephante_bulwark_1")
		T.truthy(ok, reason)
		T.eq((def :: any).name, "Thick Plating")
		T.truthy(p.classes.elephante.perks.elephante_bulwark_1)
		T.deepEq(
			{ ClassProgress.selectPerk(p, "elephante", "elephante_bulwark_3") },
			{ false, "locked_tier", nil }
		)
	end)
	T.it("ResetPerks charges cheese, or spends a token, and refunds every point", function()
		local p = rich()
		T.deepEq({ ClassProgress.resetPerks(p, "elephante") }, { false, "nothing_to_reset", nil })
		ClassProgress.selectPerk(p, "elephante", "elephante_bulwark_1")
		ClassProgress.selectPerk(p, "elephante", "elephante_bulwark_2")
		local ok, _, res = ClassProgress.resetPerks(p, "elephante")
		T.truthy(ok)
		T.deepEq(res, { paid = "cheese", cost = 2000, refunded = 3 })
		T.eq(p.cheese, 8000)
		T.deepEq(p.classes.elephante.perks, {})
		T.eq(ClassProgress.perkPointsFree(p.classes.elephante), 19)
		-- [QC-B V2-m5] a token is never spent unless the player asks for it
		p.respecTokens = 1
		ClassProgress.selectPerk(p, "elephante", "elephante_bulwark_1")
		T.deepEq(
			{ ClassProgress.resetPerks(p, "elephante", "cheese") },
			{ true, nil, { paid = "cheese", cost = 2000, refunded = 1 } }
		)
		T.eq(p.respecTokens, 1)
		ClassProgress.selectPerk(p, "elephante", "elephante_bulwark_1")
		T.deepEq(
			{ ClassProgress.resetPerks(p, "elephante") },
			{ true, nil, { paid = "cheese", cost = 2000, refunded = 1 } },
			"no choice sent: cheese, the token stays"
		)
		T.eq(p.respecTokens, 1)
		ClassProgress.selectPerk(p, "elephante", "elephante_bulwark_1")
		local ok2, _, res2 = ClassProgress.resetPerks(p, "elephante", "token")
		T.truthy(ok2)
		T.eq((res2 :: any).paid, "token")
		T.eq(p.respecTokens, 0)
		T.eq(p.cheese, 4000)
		ClassProgress.selectPerk(p, "elephante", "elephante_bulwark_1")
		T.deepEq({ ClassProgress.resetPerks(p, "elephante", "token") }, { false, "no_token", nil })
		p.cheese = 5
		T.deepEq({ ClassProgress.resetPerks(p, "elephante") }, { false, "insufficient_funds", nil })
		T.truthy(p.classes.elephante.perks.elephante_bulwark_1, "a failed respec changes nothing")
	end)
	T.it("SelectAbility needs the unlock level; nil or the base id resets", function()
		local p = rich()
		p.classes.elephante.level = 4
		T.deepEq(
			{ ClassProgress.selectAbility(p, "elephante", "elephante_trunk_quake") },
			{ false, "ability_locked" }
		)
		T.deepEq(
			{ ClassProgress.selectAbility(p, "elephante", "jumbo_dive_bomb") },
			{ false, "unknown_ability" }
		)
		p.classes.elephante.level = 5
		T.truthy(ClassProgress.selectAbility(p, "elephante", "elephante_trunk_quake"))
		T.eq(p.classes.elephante.ability, "elephante_trunk_quake")
		T.deepEq(
			{ ClassProgress.selectAbility(p, "elephante", "elephante_iron_hide") },
			{ false, "ability_locked" }
		)
		T.truthy(ClassProgress.selectAbility(p, "elephante", "elephante_stampede"))
		T.eq(p.classes.elephante.ability, nil)
	end)
	T.it("SelectSkin needs the level or ownership; default resets", function()
		local p = rich()
		p.classes.elephante.level = 3
		T.truthy(ClassProgress.selectSkin(p, "elephante", "elephante_field_grey"))
		T.deepEq({ ClassProgress.selectSkin(p, "elephante", "elephante_ironclad") }, { false, "skin_locked" })
		T.deepEq({ ClassProgress.selectSkin(p, "elephante", "elephante_gilded") }, { false, "skin_locked" })
		T.deepEq({ ClassProgress.selectSkin(p, "elephante", "jumbo_aviator") }, { false, "unknown_skin" })
		p.ownedSkins.elephante_gilded = true
		T.truthy(ClassProgress.selectSkin(p, "elephante", "elephante_gilded"))
		T.eq(ClassProgress.skinFor(p, "elephante"), "elephante_gilded")
		T.truthy(ClassProgress.selectSkin(p, "elephante", "default"))
		T.eq(p.classes.elephante.skin, nil)
	end)
	T.it("operations on a newly bought class create its block", function()
		local p = rich()
		T.truthy(Shop.buy(p, "class:jumbo"))
		T.eq(p.classes.jumbo.level, 1)
		T.deepEq({ ClassProgress.selectPerk(p, "jumbo", "jumbo_gale_1") }, { false, "no_points", nil })
	end)
end)

T.describe("Award + view: class XP, PvP stats", function()
	local function run(extra: any): any
		local r: any = { cheese = 10, xp = 10, won = true, cycle = 1, bosses = 1, ranked = true }
		for k, v in extra do
			r[k] = v
		end
		return r
	end
	T.it("awards class XP to stats.classId only, never touching account XP math", function()
		local p = ProfileSchema.default()
		local r = Award.applyRun(p, run({ classId = "ele_fonte", classXp = 250 }))
		T.eq((r.class :: any).level, 2)
		T.eq((p.classes :: any).ele_fonte.xp, 150)
		T.eq((p.classes :: any).elephante.xp, 0)
		T.eq(p.xp, 10)
		T.eq(Award.applyRun(p, run({})).class, nil)
		T.eq(Award.applyRun(p, run({ classId = "nope", classXp = 50 })).class, nil)
		Award.applyRun(p, run({ classId = "ele_fonte", classXp = 1e12 }))
		T.truthy((p.classes :: any).ele_fonte.level < 30, "one run is capped at MAX_RUN_XP")
	end)
	T.it("counts hero downs and Last Herd Standing (ranked only for the boards)", function()
		local p = ProfileSchema.default() :: any
		Award.applyRun(p, run({ heroDowns = 3, lastHerd = true }))
		Award.applyRun(p, run({ heroDowns = 2, lastHerd = false, ranked = false }))
		Award.applyRun(p, run({ heroDowns = 0 / 0, lastHerd = "x" }))
		T.eq(p.stats.heroDowns, 5)
		T.eq(p.stats.lastHerd, 1)
		T.eq(p.stats.ranked.heroDowns, 3)
		T.eq(p.stats.ranked.lastHerd, 1)
	end)
	T.it("the view shows classes with resolved choices and derived numbers", function()
		local p = ProfileSchema.default() :: any
		p.classes.elephante.level = 12
		p.classes.elephante.ability = "elephante_trunk_quake"
		p.classes.elephante.perks.elephante_bulwark_1 = true
		p.respecTokens = 2
		local v = ProfileSchema.view(p)
		local e = v.classes.elephante
		T.eq(e.level, 12)
		T.eq(e.ability, "elephante_trunk_quake")
		T.eq(e.perkPoints, 11)
		T.eq(e.perkPointsFree, 10)
		T.eq(e.mastery, "bronze")
		T.eq(e.xpToNext, ClassProgress.xpToNext(12))
		T.eq(#e.unlockedAbilities, 2)
		T.eq(v.classes.ele_fonte.ability, "ele_fonte_geyser", "base when nothing chosen")
		T.eq(v.classes.jumbo, nil, "locked classes have no block")
		T.eq(v.respecTokens, 2)
		e.perks.elephante_bulwark_2 = true
		T.eq(p.classes.elephante.perks.elephante_bulwark_2, nil, "view is a copy")
	end)
	T.it("Looks shows the mastery title", function()
		local look = Looks.resolve({}, {}, { mastery = "silver" })
		T.eq(look.nameplate.title, "Silver Herd")
		T.eq(Looks.resolve({}, {}, { mastery = "bogus" }).nameplate.title, nil)
	end)
end)

T.describe("Monetization v5: paid skins and the respec token", function()
	T.it("skin passes grant their whole set, revocably, and keep Golden-Cheese buys", function()
		local p = ProfileSchema.default() :: any
		p.goldenCheese = 1000
		T.truthy(Shop.buy(p, "skin:elephante_gilded:golden"))
		T.eq(p.goldenCheese, 550)
		T.deepEq({ Shop.buy(p, "skin:elephante_gilded:golden") }, { false, "owned" })
		T.deepEq({ Shop.buy(p, "skin:elephante_gilded") }, { false, "bad_id" })
		T.deepEq({ Shop.buy(p, "skin:elephante_field_grey:golden") }, { false, "not_for_sale" })
		T.truthy(Passes.apply(p, "skins_gilded"))
		for _, cid in Classes.ORDER do
			T.truthy(p.ownedSkins[cid .. "_gilded"], cid)
		end
		T.falsy(Passes.apply(p, "skins_gilded"), "idempotent")
		ClassProgress.selectSkin(p, "ele_fonte", "ele_fonte_gilded")
		-- survives a save/load
		local loaded = ProfileSchema.migrate(ProfileSchema.deepCopy(p)) :: any
		T.eq(loaded.classes.ele_fonte.skin, "ele_fonte_gilded")
		T.truthy(loaded.passGrants.skins_gilded.skins.jumbo_gilded)
		T.eq(loaded.passGrants.skins_gilded.skins.elephante_gilded, nil, "Golden-Cheese buy not recorded")
		local removed = Passes.revoke(loaded, "skins_gilded")
		T.eq(#removed.skins, 6)
		T.truthy(loaded.ownedSkins.elephante_gilded, "the Golden Cheese purchase stays")
		T.eq(loaded.ownedSkins.jumbo_gilded, nil)
		T.eq(loaded.classes.ele_fonte.skin, nil, "a revoked skin is unequipped")
	end)
	T.it("the shop lists every paid skin for Golden Cheese with the Club discount", function()
		local p = ProfileSchema.default() :: any
		p.goldenCheese = 450
		local price = Shop.price(p, "skin:jumbo_gilded:golden", { club = true }) :: any
		T.eq(price.amount, math.ceil(450 * 0.9))
		local n = 0
		for _, def in ClassSkins.LIST do
			if def.source == "paid" then
				n += 1
			end
		end
		local listed = 0
		for _, e in require("../../src/shared/Config/Shop").list() do
			if e.kind == "skin" then
				listed += 1
			end
		end
		T.eq(listed, n)
	end)
	T.it("Perk Respec Token is a fixed, non-random product with a handler", function()
		local item = Monetization.get("respec_token") :: any
		T.eq(item.kind, "product")
		T.eq(item.random, false)
		local p = ProfileSchema.default() :: any
		local status, res = Receipts.apply(p, "r1", "respec_token", { now = 0, day = 1 })
		T.eq(status, "granted")
		T.eq(res.respecTokens, 1)
		T.eq(p.respecTokens, 1)
		T.eq(Receipts.apply(p, "r1", "respec_token", { now = 0, day = 1 }), "duplicate")
		T.eq(p.respecTokens, 1)
	end)
	T.it("no Robux item sells class power: no XP, levels, perks or abilities", function()
		for _, item in Monetization.ALL do
			local it = item :: any
			T.eq(it.classXp, nil, item.key)
			T.eq(it.perkPoints, nil, item.key)
			T.eq(it.classLevels, nil, item.key)
			T.eq(it.abilities, nil, item.key)
		end
		for _, item in Monetization.PASSES do
			if (item :: any).skinSet then
				T.eq((item :: any).skinSet, item.key)
				T.truthy(#ClassSkins.forPass(item.key) == #Classes.ORDER, item.key)
			end
		end
	end)
end)

return T.finish()
