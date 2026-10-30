# Market Research: Roblox Co-op "RougePG-like" (Elephants vs Mice)

_Prepared 2026-10-30 by the market research team. Source spec: `../brainstorm-2026-06.md`._
_Convention: **[E]** = our estimate or inference, not a sourced figure. Tracker numbers (RoWatcher, Rotrends) are third-party snapshots and drift daily. The Roblox primary pages (about.roblox.com, devforum, create.roblox.com) were blocked by this session's network allowlist, so some Roblox statements are cited through secondary coverage. Verify them before quoting externally._

---

## TL;DR (decisions)

| Decision | Recommendation |
|---|---|
| Positioning | "Vampire Survivors with your friends": a silly co-op boss-rush survivors-like. We found no breakout survivors-like on Roblox. |
| Maturity label | **Mild**. This keeps the game eligible for Roblox Kids (5–8) and Select (9–15). Defeated mice "poof" into cheese crumbs, with no blood. |
| Run length | Map + boss in **5–7 min**. A 4-map cycle takes **~25 min**. "Go home free" at cycle end. |
| Party size | **1–4 per run** at launch, with quick-match fill. Test 6 (the Roblox Party size) once mobile performance is proven. |
| Launch scope | **3 classes, 4 maps (1 cycle), 5 bosses**, 3 modifier tiers, double-or-nothing. |
| Live ops | Weekly small drop (same weekday every week). Major content every 3–4 weeks. Seasonal events. |

---

## 1. Roblox audience 2025–2026

| Metric | Figure | Source |
|---|---|---|
| DAU, Q3 2026 | **138M** (−9% YoY, +12% QoQ). Hours ~34B (−15% YoY) | [gaming.net](https://www.gaming.net/roblox-q3-revenue-rises-16-as-bookings-fall-12-to-1-7-billion/), [Q3'26 letter](https://s27.q4cdn.com/984876518/files/content_files/Q3-2026-Earnings-Shareholder-Letter.pdf) |
| DAU trend | Peak 152M (Q3'25) → 144M → 132M → 123M (Q2'26) → 138M. The dip is blamed on mandatory age-check friction | [interspacemusic](https://interspacemusic.com/blog/roblox-daily-active-users-fall-to-123-million-in-q2-2026/), [octagonai](https://www.octagonai.co/markets/financials/companies/roblox-daily-active-users-in-q3/) |
| Bookings | Q3'26 $1.70B (−12% YoY). Q4 guided −10 to −15% | [gaming.net](https://www.gaming.net/roblox-q3-revenue-rises-16-as-bookings-fall-12-to-1-7-billion/) |
| Platform peak CCU | 47.4M (Aug 2025) | [PocketGamer.biz](https://www.pocketgamer.biz/robloxs-peak-concurrent-user-count-hits-record-474m-as-steal-a-brainrot-and-grow-a-garden-compete) |
| Engagement | ~2.6 h per DAU per day [E: hours ÷ DAU ÷ 90] | [GameAnalytics via substack](https://gamedevreports.substack.com/p/gameanalytics-key-roblox-and-roblox) |

**Age split.** About 40% of DAU were under 13 in 2024 ([PC Gamer](https://www.pcgamer.com/gaming-industry/roblox-to-make-facial-age-checks-mandatory-to-access-any-chat-features-and-will-put-common-sense-limits-on-the-age-ranges-users-can-chat-within)). In Q3 2025, 68% of hours came from 13+ users ([Q3'25 call](https://ng.investing.com/news/transcripts/earnings-call-transcript-roblox-q3-2025-shows-strong-growth-but-stock-dips-2174759)). Growth is concentrated in older users: in Q2 2026, 18+ DAU rose +32% and US 18–34 DAU rose ~+40% ([Respawn](https://respawn.outlookindia.com/gaming/gaming-news/roblox-q2-2026-revenue-soars-36-to-15b-despite-bookings-miss)). In Q3 2026, 18+ made up 29% of global age-checked DAU and 37% in the US ([gaming.net](https://www.gaming.net/roblox-q3-revenue-rises-16-as-bookings-fall-12-to-1-7-billion/)). Monetization per hour is **weakest among under-13s** ([Respawn](https://respawn.outlookindia.com/gaming/gaming-news/roblox-q2-2026-revenue-soars-36-to-15b-despite-bookings-miss)). Since January 2026, chat requires an age check, and users are bucketed into the bands <9 / 9–12 / 13–15 / 16–17 / 18–20 / 21+ ([PC Gamer](https://www.pcgamer.com/gaming-industry/roblox-to-make-facial-age-checks-mandatory-to-access-any-chat-features-and-will-put-common-sense-limits-on-the-age-ranges-users-can-chat-within)). Roblox Kids (5–8) and Roblox Select (9–15) accounts launched globally on June 17, 2026 ([MB](https://mb.com.ph/2026/06/17/age-based-roblox-kids-and-select-accounts-now-globally-available)).

**Platforms.** About **80% of sessions are on mobile**, 17% desktop and 3% console. That figure is widely repeated but is not a Roblox primary number ([Exploding Topics](https://explodingtopics.com/blog/roblox-stats)). Another source says mobile is ~70% of sessions but only 53% of playtime ([RoLearn](https://rolearn.dev/trend-reports/roblox-mobile-gaming-trends-2026)). About 44% of players use both mobile and PC ([GameAnalytics](https://gamedevreports.substack.com/p/gameanalytics-key-roblox-and-roblox)).

**Regions (DAU share).** APAC ~29.5%, US/Canada ~28%, Europe ~23%, rest of world ~20% [E: remainder] ([Statista via demandsage](https://www.demandsage.com/how-many-people-play-roblox/)). Q1 2026 hours were APAC 11.2B, RoW 9.5B, Europe 8.1B and US/Canada 6.3B (same source). **Localization matters, because most play happens outside the US.**

**Session lengths.** GameAnalytics finds a widening gap: casual users leave within about 2 minutes, while core users average 37+ minutes per session ([GameAnalytics](https://gamedevreports.substack.com/p/gameanalytics-key-roblox-and-roblox), [2025 report](https://investgame.net/wp-content/uploads/2025/09/2025-Roblox-Benchmark-Report.pdf)). Mobile sessions are estimated at about 8 minutes in the morning and 16 minutes in the evening ([RoLearn](https://rolearn.dev/trend-reports/roblox-mobile-gaming-trends-2026), estimate).

---

## 2. Comparable games

| Game | Scale (snapshot) | Core loop | Retention driver | Monetization |
|---|---|---|---|---|
| **Doors** (LSPLASH, 2022) | 3B+ visits ([Pocket Tactics](https://www.pockettactics.com/roblox/doors-visits)) | Co-op roguelite horror. Runs through 100 randomized rooms with entity "bosses" | Run variance, floor expansions (Hotel+, The Mines), streamer virality ([Wikipedia](https://en.wikipedia.org/wiki/Doors_(game))) | Knobs currency, **revives**, boosts ([ginx](https://www.ginx.tv/en/doors-codes-free-knobs-revives)) |
| **Dead Rails** | 6.4B visits, 16-player servers ([profitable.app](https://profitable.app/roblox/games/dead-rails)) | Co-op train journey through waves of zombies to reach a destination | Teamwork plus emergent stories ([GameAnalytics blog](https://www.gameanalytics.com/blog/dead-rails-and-the-hit-makers-formula)). Declining in 2026 ([RoWatcher](https://rowatcher.com/games/7018190066/dead-rails/dying)) | Classes and items |
| **99 Nights in the Forest** | 14.2M peak CCU (2025) ([PC Gamer](https://www.pcgamer.com/games/survival-crafting/with-a-peak-player-count-of-14-2-million-99-nights-in-the-forest-has-an-audience-other-multiplayer-games-would-kill-for-to-find-these-behemoth-playerbases-you-need-to-be-on-a-platform-like-roblox/)) | Co-op survive-the-night with a boss monster | Night-count goal, class unlocks. A film deal followed ([AV Club](https://www.avclub.com/roblox-99-nights-in-the-forest-movie)) | Class unlocks, gems |
| **Dandy's World** | ~600K+ peak ([RoWatcher](https://rowatcher.com/games/5569032992)) | Co-op roguelike floors with 39 collectible "Toons" | Character collection, events ([earnaldo](https://earnaldo.com/blog/99-nights-in-the-forest-vs-dandy-s-world)) | Character and cosmetic sales |
| **Anime Last Stand** | 157K peak, 1.1B visits ([Rotrends](https://rotrends.com/game/4509896324/Shibuya-Pt1-Anime-Last-Stand)) | Co-op wave tower defense | Unit gacha, story and raid modes | 5 passes, 304 dev products (same source) |
| **Anime Vanguards** | 338K peak (Mar 2026). Was the top-earning game at one point ([RoWatcher](https://rowatcher.com/news/anime-vanguards-update-11-5-how-this-tower-defense-game-holds-55k-players), [Beebom](https://beebom.com/anime-vanguards-surpasses-blox-fruits-top-earning-roblox-game)) | Co-op wave TD | **Content every 3–4 weeks**. Each update spikes CCU above 100K over a 50–60K floor | Gacha units, passes |
| **Dungeon Quest** | 2.2B visits ([Roblox](https://web.roblox.com/games/2414851778)) | Co-op dungeon runs, loot, gear | Gear grind, harder tiers | Passes (2x loot, etc.) |
| **Grow a Garden** (2025 trend setter) | 22.3M peak CCU ([Wikipedia](https://en.wikipedia.org/wiki/Grow_a_Garden)) | Idle plant-and-sell | **Weekly Saturday updates**. Update days peaked ~195% higher ([Metaverse Marcom](https://www.metaversemarcom.io/post/why-grow-a-garden-is-winning-and-what-you-can-learn-from-it), unverified) | Seeds, gear, limited items |
| **Steal An Egg** (current #1) | 986K CCU on Oct 14, 2026 ([RoWatcher](https://rowatcher.com/news/the-most-popular-roblox-games-right-now-ranked-by-live-players)) | Steal-a-Brainrot-style social theft | Social conflict, collection | Collectibles |

**Survivors-likes on Roblox.** We found **no breakout Roblox survivors-like**. The only signals are funded projects in development, such as the UK Games Fund's "Roblox Survivor (WT)" and "Rogue Rage" ([UK Games Fund](https://www.ukgamesfund.com/funded-project/roblox-survivor-working-title/)). That means the space is open, and that competitors are coming. Meanwhile, survivors-likes are booming on PC ([Lords of Gaming](https://lordsofgaming.net/2025/12/roguelike-thats-old-news-survivors-like-is-the-new-wave)).

**Pattern across the hits.** Co-op against waves or a boss, classes or collectibles to unlock, a clear run goal, and a relentless update cadence. Viral meme genres burn out: brainrot is down 99% from its peak ([RoWatcher](https://rowatcher.com/news/is-the-brainrot-trend-dying-what-ccu-data-from-three-top-games-reveals)). The top 10 games' share of hours has fallen from ~30% to ~20% ([Q2'26 summary](https://transcripts.platformaeronaut.com/summaries/RBLX-2Q26-AI-Summary)), so the long tail is getting more room.

---

## 3. What makes Roblox games succeed now

**The discovery algorithm rewards retention over virality.**

| Signal | Notes |
|---|---|
| Play-through rate (impression → play) | Thumbnail and title conversion |
| First-play bounce rate | Split out from qualified play-through in 2026. **The first minute is now scored on its own.** |
| Qualified play sessions (~5+ min) | Short visits don't count ([devforum via search](https://devforum.roblox.com/t/how-we-are-improving-home-this-year/4502571?page=5)) |
| Play days per user, window extended **7 → 28 days** | Long-term retention ([devforum](https://devforum.roblox.com/t/recommended-for-you-algorithm-improvements-that-better-value-long-term-retention/4684575)) |
| Intentional co-play days | Playing with friends ([Q3'25 letter](https://www.sec.gov/Archives/edgar/data/1315098/000131509825000326/ex991-q32025shareholderl.htm)) |

In Q2 2026 Roblox said it "intentionally provides more impressions for highly retentive games at the expense of near term monetization" ([godisageek](https://godisageek.com/2026/08/roblox-9-billion-algorithm-change/)).

**Thumbnails.** Thumbnail personalization lets a game run up to 5 active thumbnails through a multi-armed bandit. Games using it averaged **+8.5% qualified play-through, and some gained 50%** ([devforum](https://devforum.roblox.com/t/live-now-personalize-your-thumbnails-to-attract-more-users/3257233), [GamesBeat](https://gamesbeat.com/roblox-will-let-game-devs-personalize-thumbnails-to-attract-more-players/)). There is no native icon A/B testing ([devforum request](https://devforum.roblox.com/t/icon-ab-testing/3274267)).

**Social play.** Roblox Party lets up to **6 friends** join together, and friend sessions run **1.9× longer** than solo ones ([Roblox newsroom](https://corp.roblox.com/newsroom/2024/12/join-the-party-on-roblox)).

**Onboarding.** Roblox's own guidance is to get players to the fun immediately and not gate it behind progression ([Creator Hub](https://create.roblox.com/docs/production/analytics/engagement)). Practitioner benchmarks: the core action within 60 seconds, an "aha" moment within 3–5 minutes, D1 retention of at least 30% as healthy, and average session under 8 minutes as a warning sign ([RoWatcher](https://rowatcher.com/news/how-to-launch-a-roblox-game-in-2026-the-pre-launch-playbook), unverified).

**Update cadence.** Successful games update weekly (Grow a Garden) or every 3–4 weeks with spikes (Anime Vanguards), as covered in section 2. Titles carry update tags such as "Dead Rails [ENDLESS]" ([RoWatcher](https://rowatcher.com/games/7018190066/dead-rails-endless)).

**Viral hooks.** Absurd humor travels well, as the brainrot wave showed, but the evergreen ones survive it. Our hooks are a "My Grandma" boss, a Gragas-like frog, cheese worlds, and elephants stomping mice. **[E]** These clip naturally for TikTok and YouTube Shorts.

---

## 4. Recommendations for this game

**Positioning.** *"Stomp the mouse horde with your friends."* This is the first polished co-op survivors-like boss-rush on Roblox. Lead with the absurdity (the thumbnails, Grandma) and keep the buildcraft depth for 13+ players. The risk-reward choices (modifier tiers, double-or-nothing) are our differentiator from tower defense and survival games.

**Maturity label: Mild.** Defeated mice should vanish into cheese crumbs. Roblox counts an unrealistic consequence of violence as Mild, and "occasional" unrealistic blood qualifies as Minimal ([Creator Hub](https://create.roblox.com/docs/production/promotion/content-maturity)). Mild keeps the game eligible for Kids and Select accounts. Moderate would lose under-9s by default and Kids eligibility ([Creator Hub](https://create.roblox.com/docs/en-us/production/promotion/content-maturity)). To appear in Kids and Select, the game must pass a selection review. Expedited review costs a refundable 100K Robux ([devforum via search](https://devforum.roblox.com/t/roblox-kids-and-select-global-launch-upcoming-updates-to-eligibility-ads-manager-and-expedited-review/4685717)). Avoid realistic blood and keep fear content mild; spooky bosses like the Void Cat must stay cartoonish. Note the tradeoff: the 42% higher DevEx rate for US 18+ spend ([MoguraVR](https://www.moguravr.com/?p=311657)) rewards adult-targeted games, which we are deliberately not making.

**Session and run length [E].**
- The first map plus its boss should take **5–7 minutes**. That clears the qualified-session threshold and gives a new player a win in the first session.
- A cycle of 4 maps takes **~25 minutes**, which matches the 16-minute evening mobile session plus one more map.
- The free "go home" exit at cycle end should bank progress, so quitting on mobile never feels punishing.
- **Combat starts within 30 seconds** of joining. No lobby menus before the first stomp.

**Party size.** 1–4 per run at launch, scaled to player count, with quick-match to fill. Lobby servers hold about 20 players. A Roblox Party of 5–6 should land in the same lobby. Test 6-player runs after profiling enemy counts on low-end phones **[E]**.

**Launch scope (minimum lovable product).**

| Content | Launch | Brainstorm pool |
|---|---|---|
| Classes | 3: melee tank, ranged caster, support | 7 |
| Maps | 4, one full cycle: Plains, Beach (Parmesan), Volcano (Cheddar), Toxic Swamp (Moldy) | 9 |
| Bosses | 5: My Grandma, Frogas, Corndog Bunny, Giant Tree, Floating Witch | 13 |
| Systems | 3 modifier tiers, group buffs, double-or-nothing, meta-currency and unlocks, daily quest | |
| Upgrades | ~30 meaningful upgrades. Follow the brainstorm rule: no "1% at range while frozen" | |

**Live ops.**
- **Weekly** on the same weekday: a rotating "Cheese of the Week" mutator, a featured boss, and a shop rotation.
- **Every 3–4 weeks**: a new map, boss or class.
- **Seasonal**: Halloween and Winter "aged cheese" events.

**Monetization [E].** Cosmetics such as elephant skins, trunk trails and stomp VFX. Classes can be bought outright or earned. Private servers. Battle-pass-style season tracks. Sell **no paid power that affects teammates**. If we sell revives in the style of Doors, cap them per run.

**Working titles.**
1. **Elephants vs Mice** (clear and searchable)
2. **Trunk Survivors**
3. **Big Cheese Stampede**
4. **Double or Cheese**
5. **Mouse Panic! Elephant Squad**

**IP hygiene.** "Dumbo" (Disney), "Fanta" (Coca-Cola) and "Speedy Gonzalez" (Warner Bros.) are well-known third-party marks. "Frogas" riffs on Riot's Gragas. We should rename or abstract all of them **[E, not legal advice]**.

**Top 5 risks.**

| # | Risk | Mitigation |
|---|---|---|
| 1 | **Mobile performance and readability.** About 80% of sessions are on mobile; hundreds of enemies plus VFX on low-end phones | Pooled, server-authoritative enemies with client-side visuals. A minimum-spec device test gate. Mobile-first controls with auto-aim |
| 2 | **The retention algorithm.** First-play bounce and 28-day retention decide whether we get distribution | Hit in the first minute. Meta-progression and dailies. Measure D1, D7 and D28 in Creator Analytics from day one |
| 3 | **Live-ops load on a 4-person team** | Data-driven content pipeline (maps, bosses and mutators as configs). Bank 6–8 weeks of updates before launch |
| 4 | **Weaker platform monetization.** Bookings are down YoY; under-13 spend per hour is weakest | Cosmetics-led offers that appeal to 13+. Don't depend on gacha. Keep the budget lean |
| 5 | **Unproven genre and fast followers.** No survivors-like hit exists on Roblox yet, and funded competitors are in development | Ship the minimum lovable product fast. Own the comedic brand. Lean on the co-op risk-reward differentiator |
