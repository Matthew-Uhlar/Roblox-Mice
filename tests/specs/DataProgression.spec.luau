-- v4 progression (Team P): Herd Contracts, Herd Pass, Mastery Stars, Mousepedia,
-- achievements, account rewards, bundles, the daily Featured shelf and name dyes.
local T = require("../lib/Test")
local ProfileSchema = require("../../src/shared/Data/ProfileSchema")
local Quests = require("../../src/shared/Data/Quests")
local HerdPass = require("../../src/shared/Data/HerdPass")
local Progress = require("../../src/shared/Data/Progress")
local Achievements = require("../../src/shared/Data/Achievements")
local AccountRewards = require("../../src/shared/Data/AccountRewards")
local ClassProgress = require("../../src/shared/Data/ClassProgress")
local Receipts = require("../../src/shared/Data/Receipts")
local Passes = require("../../src/shared/Data/Passes")
local Shop = require("../../src/shared/Data/Shop")
local Looks = require("../../src/shared/Data/Looks")
local Q = require("../../src/shared/Config/Quests")
local Pass = require("../../src/shared/Config/Pass")
local Collection = require("../../src/shared/Config/Collection")
local AchievementConfig = require("../../src/shared/Config/Achievements")
local AccountConfig = require("../../src/shared/Config/AccountRewards")
local Cosmetics = require("../../src/shared/Config/Cosmetics")
local ClassSkins = require("../../src/shared/Config/ClassSkins")
local Monetization = require("../../src/shared/Config/Monetization")

local DAY = Pass.EPOCH_DAY + 3
local UID = 4242
local CTX = { now = DAY * 86400 + 100, day = DAY }

local function fresh(): any
	local p = ProfileSchema.default() :: any
	Progress.sync(p, DAY, UID)
	return p
end

T.describe("Config/Quests (policy)", function()
	T.it("about 18 dailies (6 per tier) and 5-6 weeklies with the planned rewards", function()
		T.eq(#Q.DAILY, 18)
		T.truthy(#Q.WEEKLY >= 5 and #Q.WEEKLY <= 6)
		for _, tier in { "Easy", "Medium", "Hard" } do
			T.eq(#Q.dailyPool(tier :: any), 6, tier)
		end
		for _, def in Q.DAILY do
			T.eq(def.passXp, ({ Easy = 150, Medium = 250, Hard = 350 } :: any)[def.tier], def.id)
			T.truthy(def.cheese >= 100 and def.cheese <= 200, def.id)
		end
		for _, def in Q.WEEKLY do
			T.truthy(def.passXp >= 500 and def.passXp <= 600, def.id)
			T.eq(def.cheese, 300)
		end
	end)
	T.it("no contract needs Robux, a friend, Double or Nothing or downing a human", function()
		local allowed: { [string]: boolean } = {}
		for k in Q.LIVE_KINDS do
			allowed[k] = true
		end
		for k in Q.RUN_KINDS do
			allowed[k] = true
		end
		for _, list in { Q.DAILY, Q.WEEKLY } do
			for _, def in list do
				T.truthy(allowed[def.kind], def.id .. " uses a known kind")
				local text = string.lower(def.text)
				for _, banned in { "robux", "friend", "double", "nothing", "player", "hero", "down " } do
					T.falsy(string.find(text, banned, 1, true), def.id .. " mentions " .. banned)
				end
			end
		end
		T.falsy(allowed.heroDowns)
	end)
end)

T.describe("Data/Quests", function()
	T.it("deals one Easy, Medium and Hard daily, deterministic per player and day", function()
		local a = Quests.dealDaily(DAY, UID)
		T.deepEq(a, Quests.dealDaily(DAY, UID))
		T.eq(#a, 3)
		for i, tier in { "Easy", "Medium", "Hard" } do
			T.eq((Q.get(a[i]) :: any).tier, tier)
		end
		local differs = false
		for d = 1, 10 do
			if table.concat(Quests.dealDaily(DAY + d, UID), ",") ~= table.concat(a, ",") then
				differs = true
			end
		end
		T.truthy(differs, "changes over days")
	end)
	T.it("progress, claim (cheese + Pass XP) and no double claim", function()
		local p = fresh()
		local st = Quests.state(p)
		p.quests.daily[1] = { id = "d_matches", p = 0, c = false }
		T.deepEq(Quests.progress(p, "match", 1), {})
		T.deepEq({ Quests.claim(p, "d_matches") }, { false, "not_done" })
		T.deepEq(Quests.progress(p, "match", 1), { "d_matches" })
		local cheese = p.cheese
		local ok, given = Quests.claim(p, "d_matches", Progress.addPassXp)
		T.truthy(ok)
		T.eq(given.cheese, 100)
		T.eq(given.passXp, 150)
		T.eq(p.cheese, cheese + 100)
		T.eq(p.pass.xp, 150)
		T.deepEq({ Quests.claim(p, "d_matches") }, { false, "claimed" })
		T.eq(#st.weekly, #Q.WEEKLY)
	end)
	T.it("'max' and 'distinct' contracts", function()
		local p = fresh()
		p.quests.daily[2] = { id = "d_clear3", p = 0, c = false }
		Quests.progress(p, "clearMax", 2)
		Quests.progress(p, "clearMax", 1)
		T.eq(p.quests.daily[2].p, 2, "best match, not a sum")
		Quests.progress(p, "clearMax", 3)
		T.truthy(Quests.isDone(p.quests.daily[2]))
		local w
		for _, q in p.quests.weekly do
			if q.id == "w_classes" then
				w = q
			end
		end
		Quests.progress(p, "classRun", 1, "jumbo")
		Quests.progress(p, "classRun", 1, "jumbo")
		Quests.progress(p, "classRun", 1, "filet")
		T.eq(w.p, 2)
	end)
	T.it("1 free reroll a day, then cheese (sink), capped; same tier, never a dealt one", function()
		local p = fresh()
		p.cheese = 1000
		local id = p.quests.daily[3].id
		local ok, res = Quests.reroll(p, id, UID)
		T.truthy(ok)
		T.eq(res.cost, 0)
		T.eq((Q.get(res.id) :: any).tier, "Hard")
		T.truthy(res.id ~= id)
		T.eq(Quests.rerollCost(p), Q.EXTRA_REROLL_CHEESE)
		for _ = 1, Q.MAX_EXTRA_REROLLS_PER_DAY do
			T.truthy(Quests.reroll(p, p.quests.daily[3].id, UID))
		end
		T.eq(p.cheese, 1000 - Q.EXTRA_REROLL_CHEESE * Q.MAX_EXTRA_REROLLS_PER_DAY)
		T.deepEq({ Quests.reroll(p, p.quests.daily[3].id, UID) }, { false, "no_rerolls" })
		T.deepEq({ Quests.reroll(p, "w_bank", UID) }, { false, "weekly" })
		local seen = {}
		for _, q in p.quests.daily do
			T.falsy(seen[q.id], "no duplicate contract")
			seen[q.id] = true
		end
	end)
	T.it("UTC rollover: new dailies each day, weeklies each Monday, finished work auto-claimed", function()
		local p = fresh()
		p.quests.daily[1] = { id = "d_matches", p = 2, c = false } -- done, not claimed
		local cheese = p.cheese
		local _, given = Quests.sync(p, DAY + 1, UID, Progress.addPassXp)
		T.eq(given.cheese, 100, "finished contract auto-granted at rollover")
		T.eq(p.cheese, cheese + 100)
		T.eq(p.quests.day, DAY + 1)
		T.eq(p.quests.rerolls, 0)
		T.deepEq(Quests.state(p).daily[1].p, 0)
		-- weeks start Monday 00:00 UTC (day 20773 = Monday 2026-11-16)
		local MONDAY = 20773
		T.eq(Q.weekFor(MONDAY), Q.weekFor(MONDAY + 6))
		T.eq(Q.weekFor(MONDAY + 7), Q.weekFor(MONDAY) + 1)
		T.eq(Q.weekFor(MONDAY - 1), Q.weekFor(MONDAY) - 1)
		T.falsy((Quests.sync(p, DAY + 1, UID)), "same day: no change")
		-- clock skew: a server one day behind must not re-deal or reset the reroll
		local before = table.clone(p.quests.daily[1])
		p.quests.rerolls = 1
		T.falsy((Quests.sync(p, DAY, UID)), "an older day changes nothing")
		T.eq(p.quests.day, DAY + 1)
		T.eq(p.quests.rerolls, 1)
		T.deepEq(p.quests.daily[1], before)
		T.falsy((Quests.sync(p, DAY - 30, UID)), "an older week changes nothing")
		T.eq(#p.quests.weekly, #Q.WEEKLY)
	end)
	T.it("the view lists 3 dailies and the weeklies with progress and reset timers", function()
		local p = fresh()
		local v = Quests.view(p, CTX.now)
		T.eq(#v.daily, 3)
		T.eq(#v.weekly, #Q.WEEKLY)
		T.truthy(v.dailyResetsIn > 0 and v.dailyResetsIn <= 86400)
		T.truthy(v.weeklyResetsIn > 0 and v.weeklyResetsIn <= 7 * 86400)
		T.eq(v.rerollCost, 0)
		T.eq(type(v.daily[1].text), "string")
	end)
end)

T.describe("Herd Pass", function()
	T.it("28-day seasons from a UTC epoch, 30 tiers x 1,000 XP", function()
		T.eq(Pass.seasonFor(Pass.EPOCH_DAY), 1)
		T.eq(Pass.seasonFor(Pass.EPOCH_DAY + 27), 1)
		T.eq(Pass.seasonFor(Pass.EPOCH_DAY + 28), 2)
		T.eq(Pass.seasonFor(Pass.EPOCH_DAY - 100), 1)
		-- season 1 starts 2026-11-18 UTC; before that: season 1, day 0
		T.eq(Pass.EPOCH_DAY, 20775)
		T.eq(Pass.dayInSeason(20774), 0)
		T.eq(Pass.dayInSeason(20775), 1)
		T.eq(Pass.dayInSeason(20775 + 27), 28)
		local p0 = ProfileSchema.default() :: any
		local v0 = HerdPass.view(p0, 20770, false)
		T.eq(v0.season, 1)
		T.eq(v0.dayInSeason, 0)
		T.eq(v0.daysLeft, 28)
		T.eq(Pass.TIERS, 30)
		T.eq(Pass.XP_PER_TIER, 1000)
		T.eq(Pass.runXp(4, true), 280)
		T.eq(Pass.runXp(1, false), 100)
	end)
	T.it("premium: exactly 8 cosmetics + 600 GC; every reward is cosmetic or currency", function()
		local def = Pass.season(1)
		local cos, gc = 0, 0
		for _, r in def.premium do
			for k in r do
				T.truthy(k == "cosmetic" or k == "goldenCheese", "premium reward " .. k)
			end
			if r.cosmetic then
				cos += 1
				T.truthy(Cosmetics.get(r.cosmetic), r.cosmetic)
			end
			gc += r.goldenCheese or 0
		end
		T.eq(cos, 8)
		T.eq(gc, 600)
		for _, r in def.free do
			for k in r do
				T.truthy(
					k == "cosmetic"
						or k == "goldenCheese"
						or k == "cheese"
						or k == "rerollTokens"
						or k == "title",
					"free reward " .. k
				)
			end
		end
		T.eq(Pass.premiumKey(1), "herd_pass_s1")
		local item = Monetization.get("herd_pass_s1") :: any
		T.eq(item.kind, "pass")
		T.eq(item.fallbackPrice, 399)
	end)
	T.it("claims: reached tiers only, once; premium needs the pass; mid-season upgrade back-fills", function()
		local p = fresh()
		HerdPass.addXp(p, 3500)
		T.deepEq({ HerdPass.claim(p, 4, "free") }, { false, "not_reached" })
		T.truthy(HerdPass.claim(p, 1, "free"))
		T.deepEq({ HerdPass.claim(p, 1, "free") }, { false, "claimed" })
		T.deepEq({ HerdPass.claim(p, 1, "premium", false) }, { false, "no_premium" })
		-- buys premium now: tiers 1 and 3 (already reached) become claimable at once
		local ok, given = HerdPass.claim(p, 3, "premium", true)
		T.truthy(ok)
		T.eq(given.goldenCheese, 100)
		T.truthy(HerdPass.claim(p, 1, "premium", false), "premium remembered for the season")
		T.truthy(p.cosmetics.hat_snow_cap)
		T.deepEq({ HerdPass.claim(p, 2, "premium", true) }, { false, "no_reward" })
		T.deepEq({ HerdPass.claim(p, 0, "free") }, { false, "bad_tier" })
		T.deepEq({ HerdPass.claim(p, 1, "gold") }, { false, "bad_track" })
		-- refund: premium turns off for this season (claimed rewards stay)
		T.truthy(HerdPass.revokePremium(p, 1))
		T.deepEq({ HerdPass.claim(p, 8, "premium", false) }, { false, "not_reached" })
		HerdPass.addXp(p, 10_000)
		T.deepEq({ HerdPass.claim(p, 8, "premium", false) }, { false, "no_premium" })
		T.truthy(p.cosmetics.hat_snow_cap, "claimed rewards stay")
		T.falsy(HerdPass.revokePremium(p, 2), "another season: no change")
	end)
	T.it("rollover auto-grants unclaimed reached rewards, then starts the new season", function()
		local p = fresh()
		HerdPass.setPremium(p, true)
		HerdPass.addXp(p, 10_000) -- tier 10
		local gc, cheese = p.goldenCheese, p.cheese
		local rolled, given = HerdPass.sync(p, Pass.EPOCH_DAY + 28)
		T.truthy(rolled)
		T.truthy(given.goldenCheese >= 10 + 200, "free tier 5 + premium tiers 3 and 8")
		T.truthy(p.cosmetics.tint_icy_rind, "free tier 10")
		T.truthy(p.cosmetics.trail_snowfall, "premium tier 6")
		T.eq(p.goldenCheese, gc + given.goldenCheese)
		T.eq(p.cheese, cheese + given.cheese)
		T.eq(p.pass.season, 2)
		T.eq(p.pass.xp, 0)
		T.eq(p.pass.premiumOwned, false, "premium is per season")
		T.falsy((HerdPass.sync(p, Pass.EPOCH_DAY + 29)))
		T.falsy((HerdPass.sync(p, Pass.EPOCH_DAY + 3)), "an older day never rolls back")
	end)
	T.it("Pass XP caps at 30 tiers and the view has every tier", function()
		local p = fresh()
		HerdPass.addXp(p, 1e9)
		T.eq(p.pass.xp, Pass.MAX_XP)
		local v = HerdPass.view(p, DAY, false)
		T.eq(#v.tiers, 30)
		T.eq(v.tier, 30)
		T.eq(v.premiumKey, "herd_pass_s1")
		T.truthy(v.daysLeft >= 1 and v.daysLeft <= 28)
		T.truthy(v.claimable > 0)
	end)
end)

T.describe("Mastery Stars", function()
	T.it("12,000 XP each after level 30; the first star gives the 30th perk point", function()
		local p = fresh()
		local st = ClassProgress.ensure(p, "elephante") :: any
		st.level = 30
		T.eq(ClassProgress.perkPointsFree(st), 29)
		local a = ClassProgress.award(p, "elephante", 5000) :: any
		T.eq(a.stars, nil)
		a = ClassProgress.award(p, "elephante", 5000) :: any
		T.eq(a.stars, nil)
		a = ClassProgress.award(p, "elephante", 2500) :: any
		T.eq(a.stars, 1)
		T.eq(a.perkPoints, 1, "the 30th point")
		T.eq(ClassProgress.perkPointsFree(st), 30)
		T.eq(st.starXp, 500)
		T.eq(ClassProgress.view(p).elephante.stars, 1)
		-- survives a save/load
		local loaded = ProfileSchema.migrate(ProfileSchema.deepCopy(p)) :: any
		T.eq(loaded.classes.elephante.stars, 1)
		T.eq(loaded.classes.elephante.starXp, 500)
	end)
	T.it("XP that crosses level 30 carries into stars; afterRun pays 300 cheese + 10 GC a star", function()
		local p = fresh()
		local st = ClassProgress.ensure(p, "jumbo") :: any
		st.level = 29
		st.xp = ClassProgress.xpToNext(29) - 1
		local a = ClassProgress.award(p, "jumbo", 1 + 5000) :: any
		T.eq(a.level, 30)
		T.eq(st.starXp, 4999, "one run is capped at MAX_RUN_XP (5,000): 1 to level up, 4,999 to stars")
		st.starXp = ClassProgress.STAR_XP - 1
		local award = ClassProgress.award(p, "jumbo", 1)
		local gc = p.goldenCheese
		local sum = Progress.afterRun(p, { day = DAY, userId = UID, classAward = award })
		T.eq(sum.stars, 1)
		T.eq(p.goldenCheese - gc >= 10, true)
	end)
	T.it("stars cap at 20 and the nametag shows them on Gold Herd", function()
		local st = { level = 30, xp = 0, perks = {} } :: any
		T.eq(ClassProgress.addStarXp(st, 1e9), 20)
		T.eq(st.stars, 20)
		T.eq(ClassProgress.addStarXp(st, 1e6), 0)
		local look = Looks.resolve({}, {}, { mastery = "gold", stars = 3 })
		T.truthy(string.find(look.nameplate.title :: string, "★3", 1, true))
	end)
end)

T.describe("Mousepedia and achievements", function()
	T.it("each new entry: +5 GC and +50 Pass XP once; unknown ids ignored", function()
		local p = fresh()
		local boss = Collection.get("bosses").entries[1]
		local isNew, given = Achievements.collect(p, "bosses", boss, Progress.addPassXp)
		T.truthy(isNew)
		T.eq(given.goldenCheese, 5)
		T.eq(given.passXp, 50)
		T.eq(p.pass.xp, 50)
		T.falsy((Achievements.collect(p, "bosses", boss, Progress.addPassXp)))
		T.falsy((Achievements.collect(p, "bosses", "not_a_boss")))
		T.falsy((Achievements.collect(p, "nope", boss)))
	end)
	T.it("a finished page gives its reward once; milestones by overall completion", function()
		local p = fresh()
		for _, id in Collection.get("maps").entries do
			Achievements.collect(p, "maps", id)
		end
		T.truthy(p.achievements.page_maps)
		T.truthy(p.titles.title_cartographer)
		local done = Progress.checkAchievements(p)
		local found = false
		for _, a in done do
			if a.id == "world_walker" then
				found = true
			end
		end
		T.truthy(found, "World Walker after the maps page")
		for _, page in Collection.PAGES do
			for _, id in page.entries do
				Achievements.collect(p, page.id, id)
			end
		end
		T.eq(Achievements.completionPct(p), 100)
		T.truthy(p.cosmetics.trail_archivist)
		T.truthy(p.achievements.collect_100)
	end)
	T.it("achievement rewards are cosmetic, title or currency, and reference real items", function()
		for _, def in AchievementConfig.LIST do
			for k, v in def.reward do
				T.truthy(k == "cheese" or k == "goldenCheese" or k == "title" or k == "cosmetic", def.id)
				if k == "title" then
					T.truthy(Cosmetics.EARNED_TITLES[v], def.id)
				elseif k == "cosmetic" then
					T.truthy(Cosmetics.get(v), def.id)
				end
			end
		end
	end)
	T.it("afterRun: Pass XP, contracts, Mousepedia, achievements in one call", function()
		local p = fresh()
		p.quests.daily[1] = { id = "d_matches", p = 1, c = false }
		local award = { classId = "elephante" }
		local sum = Progress.afterRun(p, {
			day = DAY,
			userId = UID,
			classId = "elephante",
			stagesCleared = 2,
			stagesSurvived = 3,
			extracted = true,
			bosses = 2,
			championKills = 1,
			bossIds = { Collection.get("bosses").entries[2] },
			mapIds = { Collection.get("maps").entries[1] },
			classAward = award,
		})
		T.truthy(table.find(sum.completed, "d_matches"))
		T.eq(#sum.collected, 2)
		T.truthy(sum.passXp >= Pass.runXp(3, true) + 100)
		T.eq(
			Progress.event(p, "match", 5, { day = DAY, userId = UID })[1],
			nil,
			"run kinds are not live events"
		)
		T.deepEq(Progress.event(p, "mice", 1, { day = DAY, userId = UID }), {})
	end)
end)

T.describe("Account level rewards", function()
	T.it("every 5 levels to 100; claim once when reached", function()
		local levels = AccountConfig.levels()
		T.eq(#levels, 20)
		T.eq(levels[1], 5)
		T.eq(levels[20], 100)
		local p = fresh()
		p.level = 12
		T.eq(AccountRewards.claimable(p), 2)
		T.deepEq({ AccountRewards.claim(p, 15) }, { false, "not_reached" })
		T.deepEq({ AccountRewards.claim(p, 7) }, { false, "bad_level" })
		local ok, given = AccountRewards.claim(p, 10)
		T.truthy(ok)
		T.eq(given.goldenCheese, 25)
		T.deepEq({ AccountRewards.claim(p, 10) }, { false, "claimed" })
	end)
end)

T.describe("Robux bundles (fixed contents, receipt ledger)", function()
	T.it("new items: keys, prices, kinds and never random", function()
		local want = {
			starter_pack = { "product", 99 },
			skin_bundle = { "product", 299 },
			wardrobe_plus = { "product", 199 },
			emote_pack = { "product", 199 },
			herd_pass_s1 = { "pass", 399 },
		}
		for key, w in want do
			local item = Monetization.get(key) :: any
			T.truthy(item, key)
			T.eq(item.kind, w[1], key)
			T.eq(item.fallbackPrice, w[2], key)
			T.eq(item.random, false, key)
		end
	end)
	T.it("Starter Pack grants its contents once; a duplicate PurchaseId grants nothing", function()
		local p = ProfileSchema.default() :: any
		local status, r = Receipts.apply(p, "sp-1", "starter_pack", CTX)
		T.eq(status, "granted")
		T.eq(r.goldenCheese, 300)
		T.truthy(p.cosmetics.hat_rookie_bandana and p.cosmetics.trail_rookie_dust)
		T.eq(p.respecTokens, 1)
		T.truthy(p.entitlements.starter_pack)
		T.eq((Receipts.apply(p, "sp-1", "starter_pack", CTX)), "duplicate")
		T.eq(p.goldenCheese, 300)
		local why = Monetization.bundleRefusal(Monetization.get("starter_pack"), p.entitlements)
		T.eq(why, "owned", "one per account")
		-- a second receipt that slips through still never grants nothing
		local s2, r2 = Receipts.apply(p, "sp-2", "starter_pack", CTX)
		T.eq(s2, "granted")
		T.eq(r2.goldenCheese, 300 + 2 * 100)
	end)
	T.it(
		"Skin Collector Bundle: all 14 paid skins, owned ones as Golden Cheese; covered passes refused",
		function()
			local p = ProfileSchema.default() :: any
			p.ownedSkins.elephante_gilded = true
			local _, r = Receipts.apply(p, "sk-1", "skin_bundle", CTX)
			T.eq(r.skins, 13)
			T.eq(r.goldenCheese, 40)
			local n = 0
			for _, def in ClassSkins.LIST do
				if def.source == "paid" then
					n += 1
					T.truthy(p.ownedSkins[def.id], def.id)
				end
			end
			T.eq(n, 14)
			T.eq((Monetization.bundleRefusal(Monetization.get("skins_neon"), p.entitlements)), "owned")
			local fresh2 = ProfileSchema.default() :: any
			T.eq((Monetization.bundleRefusal(Monetization.get("skin_bundle"), fresh2.entitlements, function(k)
				return k == "skins_gilded"
			end)), "owns_pass")
			-- a pass bought later (website) records nothing, so a refund can't take bundle skins
			Passes.apply(p, "skins_gilded")
			Passes.revoke(p, "skins_gilded")
			T.truthy(p.ownedSkins.jumbo_gilded)
		end
	)
	T.it("Wardrobe+ and the Emote Pack; the Emote Pack stays unsellable until emotes exist", function()
		local p = ProfileSchema.default() :: any
		local _, r = Receipts.apply(p, "w-1", "wardrobe_plus", CTX)
		T.eq(r.cosmetics, 10)
		for _, id in Cosmetics.forBundle("wardrobe_plus") do
			T.truthy(p.cosmetics[id], id)
		end
		local _, e = Receipts.apply(p, "e-1", "emote_pack", CTX)
		T.eq(e.emotes, 6)
		T.falsy(Monetization.featureOn(Monetization.get("emote_pack")))
		T.truthy(Monetization.featureOn(Monetization.get("starter_pack")))
	end)
	T.it("benefits list every bundle cosmetic by name", function()
		for _, key in { "starter_pack", "wardrobe_plus" } do
			local item = Monetization.get(key) :: any
			for _, id in item.cosmetics do
				local name = (Cosmetics.get(id) :: any).name
				local short = string.match(name, "^(%S+)") :: string
				T.truthy(string.find(item.benefit, short, 1, true), key .. " lists " .. name)
			end
		end
	end)
end)

T.describe("Shop v2: repricing, Featured, dyes, titles", function()
	T.it("GC repricing (v4 plan): Neon 150, Gilded 200, hats 150-250, tints 100-150", function()
		for _, def in ClassSkins.LIST do
			if def.source == "paid" then
				T.eq(def.priceGolden, if string.find(def.id, "gilded") then 200 else 150, def.id)
			end
		end
		for _, def in Cosmetics.LIST do
			if def.source == "shop" and def.priceGolden then
				if def.slot == "hat" and def.id ~= "hat_astronaut" then
					T.truthy(def.priceGolden >= 150 and def.priceGolden <= 250, def.id)
				elseif def.slot == "tint" then
					T.truthy(def.priceGolden >= 100 and def.priceGolden <= 150, def.id)
				end
			end
		end
	end)
	T.it("the Featured shelf is the same for everyone on a day and lists buyable items", function()
		local a = Shop.featured(DAY)
		T.deepEq(a, Shop.featured(DAY))
		T.eq(#a.golden, 4)
		T.eq(#a.cheese, 2)
		local p = ProfileSchema.default() :: any
		for _, id in a.golden do
			T.truthy(Shop.price(p, id), id)
		end
		for _, id in a.cheese do
			T.truthy(Shop.price(p, id), id)
		end
	end)
	T.it("name dyes are a repeatable cheese sink", function()
		local p = ProfileSchema.default() :: any
		p.cheese = 5000
		T.truthy(Shop.buy(p, "dye:mint"))
		T.eq(p.nameDye, "mint")
		T.deepEq({ Shop.buy(p, "dye:mint") }, { false, "owned" })
		T.truthy(Shop.buy(p, "dye:rose"))
		T.truthy(Shop.buy(p, "dye:mint"), "buying it again costs again")
		T.eq(p.cheese, 5000 - 3000)
		T.truthy(Shop.buy(p, "dye:default"))
		T.eq(p.cheese, 2000, "default is free")
		T.eq(p.nameDye, nil)
		local look = Looks.resolve({}, {}, { nameDye = "sky", vip = true })
		T.deepEq(look.nameplate.nameColor, Cosmetics.DYES.sky.color)
	end)
	T.it("earned titles: equip only owned ones; shown on the nametag", function()
		local p = ProfileSchema.default() :: any
		T.deepEq({ Shop.equip(p, "title", "title_veteran") }, { false, "not_owned" })
		p.titles.title_veteran = true
		T.truthy(Shop.equip(p, "title", "title_veteran"))
		T.eq(p.equipped.title, "title_veteran")
		local look = Looks.resolve(p.equipped, p.cosmetics, { title = "title_veteran" })
		T.truthy(string.find(look.nameplate.title :: string, "Veteran", 1, true))
		T.truthy(Shop.equip(p, "title", nil))
		T.eq(p.equipped.title, nil)
	end)
	T.it("every new cosmetic has a drawable shape and a valid source", function()
		for _, def in Cosmetics.LIST do
			if def.slot == "hat" then
				T.truthy(Cosmetics.HAT_SHAPES[def.shape :: string], def.id)
			end
			if def.source == "bundle" then
				T.truthy(Monetization.get(def.bundleKey :: string), def.id)
			end
		end
	end)
end)

return T.finish()
