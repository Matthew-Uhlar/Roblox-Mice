# v4 Feature Research: what to build next for Trunkfall

_Prepared 2026-11-16 by the v4 market & feature research team. Inputs: `docs/GDD-v2.md`,
`docs/MONETIZATION.md`, `docs/HANDOFF.md`, `docs/research/{market,monetization}.md`._

_Conventions:_
- **[E]** marks our estimate or inference, not a sourced figure.
- **[verify]** marks a claim to check against the live Creator Hub before building.
- _Method note:_ this session could search the web but could not fetch pages: `create.roblox.com`,
  `rowatcher.com` and others failed DNS under the sandbox network allowlist. Every citation below
  comes from search-result summaries of the linked page. Treat exact numbers from fan wikis and
  guide sites as approximate. To re-verify, allow `create.roblox.com` and `devforum.roblox.com` in
  the session's network settings.

---

## TL;DR

Trunkfall already has a strong core: squad PvPvE, champions, extraction and Double or Nothing,
per-class levels, a daily streak, first-run-of-day bonus, passes, Cheese Club and coach-mark
hints. **What it lacks is the layer that brings players back on day 2, 7 and 28, and the match
glue that makes 2.5× maps feel like a battle royale.** No quests, no season pass, no shrinking
zone, no redeploy, no pings, no end-of-match MVP screen, no friend-invite rewards, no collection
book, no starter pack and no emotes.

Roblox's discovery now scores first-play bounce, qualified (5+ min) sessions, play days over 28
days and intentional co-play (see `market.md` §3). The top 10 below are ranked by how directly
each one moves those signals, then by revenue, then by effort.

| # | Feature | Effort | Main metric it moves |
|---|---|---|---|
| 1 | **Rookie Run** (first-session flow) | M | First-play bounce, D1 |
| 2 | **The Melt** (shrinking zone) | M | Session quality, PvP density, clip-ability |
| 3 | **Herd Contracts** (daily + weekly quests) | M | D1–D7 return, play days |
| 4 | **Herd Pass** (season pass, free + premium) | L | D7–D28, revenue |
| 5 | **Herd Call** (squad redeploy) | M | Fewer early quits, session length |
| 6 | **Pings + quick-chat + bot commands** | S–M | Squad play with chat age-gated |
| 7 | **End-of-run MVP and Herd Awards** | S | Session-to-session loop, sharing |
| 8 | **Bring Your Herd** (friend referrals + party bonus) | S | Co-play days, acquisition |
| 9 | **Mousepedia** (collection book + badges) | M | D7–D28 long goals |
| 10 | **Shop v2** (starter pack, featured shelf, emotes, bundles) | M | Conversion, ARPPU |

---

## 1. Gap analysis: what Trunkfall has vs. what the hits have

| System | Trunkfall today | Comparable games |
|---|---|---|
| Daily login streak | Yes (7 days; a missed day steps back one day) | Rivals free login track with a day-7 prize ([allthings.how](https://allthings.how/roblox-rivals-wildcat-cost-stats-and-contract-rewards/)) |
| First run of the day | Yes (2× cheese, cap 1,000) | — |
| Daily / weekly quests | **No** | Rivals: 3 daily tasks ([robloxden](https://robloxden.com/game-codes/rivals/guides/how-to-get-keys-fast-in-rivals)). Anime Vanguards: daily, weekly and season quests feeding the pass ([allthings.how](https://allthings.how/anime-vanguards-how-to-max-the-meliodas-battle-pass-fast/)). Fisch: event quests ([progameguides](https://progameguides.com/roblox/complete-fisch-fischgiving-event-guide-quests-rewards-more/)) |
| Season / battle pass | **No** | Rivals: 50 tiers over 8 weeks ([dungeonpath](https://dungeonpath.com/posts/rivals/season-3-battle-pass-guide/)). Bedwars: 799 R$ ([sportskeeda](https://www.sportskeeda.com/roblox-news/5-best-gamepasses-roblox-bedwars)). Anime Vanguards: 50 levels ([sportskeeda](https://www.sportskeeda.com/roblox-news/anime-vanguards-neon-chrome-battle-pass-all-rewards-premium-price)). Arc Raiders: 60-level Reward Pass whose premium refunds its own price ([games.gg](https://games.gg/news/arc-raiders-paid-battle-pass/)) |
| Achievements / collection | Mastery badges only (ids still 0) | Vampire Survivors: achievements *are* the unlock system ([rogueranker](https://rogueranker.com/vampire-survivors-achievements/)). Fisch: bestiary pages give XP + badge ([deltiasgaming](https://deltiasgaming.com/?p=194530)). Doors: 68 badges ([progameguides](https://progameguides.com/roblox/how-to-get-all-badges-in-roblox-doors/)) |
| Shrinking zone | **No** (2.5× maps; squads meet at champions) | Fortnite storm phases ([gamertagmythras](https://gamertagmythras.com/blog/fortnite/fortnite-storm-phases-guide)). Fortnite Blitz: 6 phases in about 5 min ([same](https://gamertagmythras.com/blog/fortnite/fortnite-blitz-royale-guide)) |
| Redeploy | No (dead heroes spectate until the next stage) | Fortnite Reload: personal reboot timers that teammates shorten by fighting ([ggrecon](https://www.ggrecon.com/guides/fortnite-reload-explained/)). PUBG Comeback BR ([pcgamer](https://pcgamer.com/pubgs-latest-patch-adds-an-apex-legends-style-respawn-system)) |
| Pings | No | Apex ping system makes voice optional ([PC Gamer](https://www.pcgamer.com/apex-legends-ping-system-is-a-tiny-miracle-for-fps-teamwork-and-communication)) |
| End-of-match MVP | Kill feed and scoreboard only | — |
| Friend invites with reward | No | Roblox Friend Referral System, Apr 2025 ([devforum](https://devforum.roblox.com/t/announcing-the-new-friend-referral-system-for-your-experiences/3623795), [docs](https://create.roblox.com/docs/production/promotion/referral-system)) |
| Codes / group reward | No | Doors: revive for joining the group, plus codes ([progameguides](https://progameguides.com/roblox/how-to-get-all-badges-in-roblox-doors/), [pcgamesn](https://www.pcgamesn.com/roblox/doors-codes)). Rivals codes ([PC Gamer](https://www.pcgamer.com/games/roblox/roblox-rivals-codes/)) |
| Starter pack | No | Roblox docs: +2–10% revenue on average; show it from first spawn ([Creator Hub](https://create.roblox.com/docs/production/game-design/starter-pack-design)) |
| Emotes | No (dropped from the plan) | Strongest Battlegrounds: hundreds of emotes, 25 R$ each, or earned by play ([gamezebo](https://www.gamezebo.com/walkthroughs/how-to-get-emotes-in-the-strongest-battlegrounds/), [ginx](https://www.ginx.tv/en/?p=63335)) |
| Live events | No | Grow a Garden update days ~8.1M vs ~2.8M CCU other days ([Metaverse Marcom](https://www.metaversemarcom.io/post/why-grow-a-garden-is-winning-and-what-you-can-learn-from-it)). 99 Nights: weekly updates, classes, badges ([GameDiscoverCo](https://newsletter.gamediscover.co/p/analysis-ugc-still-powers-sales-and)) |
| Notifications / event RSVP | No | Experience Notifications, 13+ opt-in ([docs](https://create.roblox.com/docs/production/promotion/experience-notifications)). Event RSVP APIs ([devforum](https://devforum.roblox.com/t/introducing-the-new-experience-event-apis/3754058)) |

---

## 2. Evidence by area

### 2.1 Retention loops that work on Roblox now

- **The algorithm.** Roblox gives impressions to retentive games: play days over 28 days, qualified
  sessions, first-play bounce scored on its own, and co-play days (summarised in `market.md` §3).
  A third-party 2026 summary makes the same point ([RoWatcher](https://rowatcher.com/news/what-the-roblox-algorithm-actually-rewards-in-2026-not-ccu)).
- **Plain login bonuses are weak on their own.** Commentators argue that fixed daily bonuses lift D2
  but trade away D30, and that they train "open, claim, close"
  ([RoWatcher](https://rowatcher.com/news/reward-schedules-in-roblox-why-daily-login-bonuses-backfire),
  [RoWatcher](https://rowatcher.com/news/daily-login-bonuses-are-lazy-design-here-s-what-works-instead),
  [RoWatcher](https://rowatcher.com/news/why-roblox-reward-schedules-break-after-day-14)).
  The 2025 Roblox Benchmark Report advises "engagement-driven spend such as quests, streaks or
  battle passes" ([gameindustrylibrary](https://gameindustrylibrary.com/documents/the-2025-roblox-benchmark-report)).
  **Takeaway:** quests that send players *into a run* beat more login rewards. We already have a streak.
- **Season pass.** Roblox's own design guide says:
  - free enrolment is the default;
  - premium is a superset of free;
  - **back-date premium rewards** when someone upgrades mid-season;
  - **auto-award unclaimed rewards** at season end.

  ([season pass design](https://create.roblox.com/docs/production/game-design/season-pass-design);
  there is a ready-made [Season Passes package](https://create.roblox.com/docs/resources/feature-packages/season-passes).)

  Market norm: 50 tiers over 8 weeks; premium 400–799 R$
  ([dungeonpath](https://dungeonpath.com/posts/rivals/season-3-battle-pass-guide/),
  [sportskeeda Bedwars](https://www.sportskeeda.com/roblox-news/5-best-gamepasses-roblox-bedwars)).
  Arc Raiders' premium track refunds its own price in currency, which builds goodwill and season-to-season
  carry ([arcraidershub](https://arcraidershub.com/blog), [games.gg](https://games.gg/news/arc-raiders-paid-battle-pass/)).
- **Collections and achievements.**
  - Vampire Survivors uses achievements as its unlock system; completion runs from ~98% down to <1%
    ([Steam stats](https://steamcommunity.com/stats/1794680/achievements),
    [rogueranker](https://rogueranker.com/vampire-survivors-achievements/)).
  - Brotato unlocks characters by kill counts, wins and odd in-run challenges
    ([commonsensegamer](https://commonsensegamer.com/brotato-how-to-unlock-all-characters/),
    [Brotato wiki](https://brotato.wiki.spellsandguns.com/Progress)).
  - Fisch's bestiary gives XP + a badge per page; its developer says retention comes from "multiple
    ways to play" and events that add a challenge, not just cosmetics
    ([DevForum spotlight](https://devforum.roblox.com/t/creator-spotlight-woozynate-makes-a-splash-with-fisch/3269481)).
  - Badges cost nothing for 5 per experience per day; beyond that they cost 100 R$ each
    ([DevForum](https://devforum.roblox.com/t/announcing-free-badge-creations/1680515)).
- **Live events and update cadence.**
  - Grow a Garden: Saturday drops spike CCU ~3× ([Metaverse Marcom](https://www.metaversemarcom.io/post/why-grow-a-garden-is-winning-and-what-you-can-learn-from-it)),
    but spikes fade within hours ([PocketGamer.biz](https://www.pocketgamer.biz/roblox-game-grow-a-garden-beats-steam-with-record-concurrent-user-high-of-89m)),
    and the developer later moved off strictly weekly events because they were hard to keep fresh
    ([NME](https://www.nme.com/news/gaming-news/roblox-grow-a-garden-major-changes-coming-update-cooking-3884432)).
  - 99 Nights held a strict weekly cadence ([GameDiscoverCo](https://newsletter.gamediscover.co/p/analysis-ugc-still-powers-sales-and)).
  - Dead Rails led with retention (class unlocks) before heavy monetization
    ([Metaverse Marcom](https://www.metaversemarcom.io/post/how-dead-rails-became-hottest-roblox-game),
    [GameAnalytics](https://www.gameanalytics.com/blog/dead-rails-and-the-hit-makers-formula)).
  - Dandy's World event currencies reset each year, and event Toons need event currency
    ([Dandy's World wiki](https://dandys-world-robloxhorror.fandom.com/wiki/Currencies)).
- **Codes and group rewards.**
  - Doors gives a revive for joining its group and runs codes for knobs, revives and boosts
    ([progameguides](https://progameguides.com/roblox/how-to-get-all-badges-in-roblox-doors/),
    [pcgamesn](https://www.pcgamesn.com/roblox/doors-codes)).
  - Rivals codes give keys and wraps ([gamesradar](https://www.gamesradar.com/games/fps/roblox-rivals-codes)).
  - Membership is checked with `Player:IsInGroupAsync` ([GroupService](https://create.roblox.com/docs/en-us/reference/engine/classes/GroupService.md)).
- **Ranked ladders.** Bedwars runs a seasonal ladder: Bronze→Nightmare, 100 RP per sub-rank, rewards
  at season end ([sportskeeda](https://sportskeeda.com/roblox-news/roblox-bedwars-ranked-guide)).
  Arc Raiders Trials are a free weekly-task leaderboard that freezes at season end and pays by
  bracket ([playnews](https://www.playnews.gg/en/guides/arc-raiders-the-trials-system-guide-ranks-scorta-and-patch-1-36-to-dominate-season-5-2026)).
- **Notifications and events.**
  - Experience Notifications: 13+ opt-in only; the in-game permission prompt is limited to once
    every 30 days; reported cap of 1 notification per player per day
    ([docs](https://create.roblox.com/docs/production/promotion/experience-notifications),
    [DevForum](https://devforum.roblox.com/t/issues-with-opencloud-experience-notifications/3874557),
    [prompt](https://devforum.roblox.com/t/introducing-in-experience-notification-permission-prompts/2909125)).
  - Event RSVP prompts via `SocialService` ([DevForum](https://devforum.roblox.com/t/introducing-the-new-experience-event-apis/3754058)).
- **AFK / offline rewards.** Creator Rewards pays only for 10+ minutes of play by Active Spenders, and
  exploit attempts can forfeit rewards ([Creator Rewards](https://create.roblox.com/docs/creator-rewards),
  [wiki](https://roblox.fandom.com/wiki/Creator_Rewards)). An earlier payout program was reportedly
  retired partly over AFK farming ([DevForum](https://devforum.roblox.com/t/introducing-creator-rewards-earn-more-by-growing-the-community/3777628/363)).
  AFK rewards also clash with our run-based loop and our AFK rules. **Not recommended.**

### 2.2 First session

- Roblox's FTUE guidance: cut drop-off at each step, use Experiments to find where players leave,
  and **end onboarding on a deliberate celebration** ([onboarding](https://create.roblox.com/docs/production/game-design/onboarding)).
- Practitioner benchmarks (`market.md` §3): core action within 60 s, "aha" within 3–5 min, and
  D1 ≥ 30% is healthy.
- Doors has no formal tutorial (players learn by trial and error), but it gives a "Welcome" achievement
  on first join and a free revive ([droidgamers](https://www.droidgamers.com/guides/roblox-doors-achievements/),
  [sites.google](https://sites.google.com/view/doors-the-guide/game-mechanics)).
- **Our current risk [E]:**
  - A new player waits up to 30 s in the lobby.
  - They then drop into a 12-seat PvP match on a 350-stud map, where bots can hunt them after 75 s.
  - Coach marks exist (`client/UI/Onboarding.luau`), but nothing protects or celebrates the first run.
  - Extraction decisions (Extract / Stay / Double or Nothing) are complex for an 8-year-old.

### 2.3 Match feel

- **Zones.**
  - Fortnite's modern storm is 12 phases (~22 min) with damage of 1% for five phases, then 2%, then 5%
    ([gamertagmythras](https://gamertagmythras.com/blog/fortnite/fortnite-storm-phases-guide)).
  - Blitz compresses it to 6 phases in ~5 min 10 s, with damage up to 40% by phase 6
    ([gamertagmythras](https://gamertagmythras.com/blog/fortnite/fortnite-blitz-royale-guide)).
  - Older tables: each phase is a wait of about 60–80 s, then a shrink of 60–70 s
    ([Fortnite wiki](https://fortnite-archive.fandom.com/wiki/The_Storm_(Battle_Royale))).
  - Dark and Darker used a staged circle with escape portals appearing in later circles
    ([vhpg](https://www.vhpg.com/?p=49961)). Players complained that escapes got hard to find after it
    was removed ([Steam](https://steamcommunity.com/app/2016590/discussions/0/4340987076277810630)).
  - Hunt has no circle, and late pressure comes only from players
    ([PC Gamer](https://www.pcgamer.com/au/the-future-of-battle-royale-is-here-and-theres-no-circle/)).
    That works at 45 min, not in our 150 s stages.
- **Redeploy.**
  - Fortnite Reload: personal reboot timers start at 12–30 s by mode; teammates shorten them
    (2 s per down, 4 s per elimination, 10 s per squad wipe); reboots switch off late in the match.
    Reload briefly drew more players than core BR ([ggrecon](https://www.ggrecon.com/guides/fortnite-reload-explained/),
    [videogamer](https://videogamer.com/news/fortnite-reload-duos-makes-essential-changes-to-keep-players-in-the-game),
    [mp1st](https://mp1st.com/title-updates-and-patches/fortnite-update-4-29-for-v30-20-brings-squad-reload)).
  - PUBG Comeback BR keeps the death meaningful but gives "a sliver of hope"
    ([pcgamer](https://pcgamer.com/pubgs-latest-patch-adds-an-apex-legends-style-respawn-system)).
  - Too many ways back dilutes stakes ([charlieintel](https://charlieintel.com/call-of-duty/warzone-players-divided-over-excessive-respawn-options-in-battle-royale-mode-301162)).
- **Pings.** Apex's context pings let players contribute fully without voice; Respawn tested them with
  voice banned ([PC Gamer](https://www.pcgamer.com/apex-legends-ping-system-is-a-tiny-miracle-for-fps-teamwork-and-communication),
  [GamesRadar](https://gamesradar.com/the-apex-legends-ping-system-is-a-brilliant-solution-to-the-horror-of-playing-with-strangers-online)).
  **This matters more on Roblox in 2026.** Since January 2026, text, voice and party chat need a facial
  age check, and chat is limited to nearby age bands; under-9s have chat off by default
  ([Business Wire](https://www.businesswire.com/news/home/20260107986568/en/Roblox-Requires-Users-Worldwide-to-Age-Check-to-Access-Chat),
  [PC Gamer](https://www.pcgamer.com/gaming-industry/roblox-to-make-facial-age-checks-mandatory-to-access-any-chat-features-and-will-put-common-sense-limits-on-the-age-ranges-users-can-chat-within)).
  Many squadmates therefore **cannot talk at all**, and pings are the only shared language.
- **PvPvE social contract.** Arc Raiders found that a large share of players prefer cooperating against
  the PvE threat, with PvP as "anxiety" rather than the point
  ([mein-mmo](https://mein-mmo.de/en/of-course-that-encourages-us-developers-behind-arc-raiders-had-to-rethink-because-the-community-is-more-peaceful-than-expected,1552698),
  [gfinity](https://www.gfinityesports.com/article/arc-raiders-creators-want-you-to-stop-shooting-each-other)).
  **Takeaway [E]:** reward PvE objectives at least as well as PvP; keep PvP quests optional.
- **Extraction timers.**
  - DRG: Survivor's drop pod gives 30 s after the elite or boss dies; missing it ends the run
    ([techraptor](https://techraptor.net/gaming/guides/deep-rock-galactic-survivor-guide)).
  - Hunt's hidden extracts make carriers unpredictable ([PC Gamer](https://www.pcgamer.com/games/fps/hunt-showdown-keeps-experimenting-with-the-extraction-genre-and-its-next-twist-sounds-irresistible-soon-extraction-points-and-loot-wont-appear-on-the-map)).
  - Our 20 s Rind Gate already fits this.
- **Emotes as a social and revenue layer.** Strongest Battlegrounds sells emotes at 25 R$ or earns
  them by play (100 kills) ([ginx](https://www.ginx.tv/en/?p=63335)), with a rotating "limited" emote
  shelf ([bloxodes](https://bloxodes.com/wiki/the-strongest-battlegrounds)).

### 2.4 Monetization

- **Starter pack** (Roblox's own guide):
  - offer it from first spawn, because gating behind a tutorial cuts views;
  - make it the best value in the game;
  - keep other price points so new payers keep spending;
  - expect +2–10% revenue on average.

  ([starter pack design](https://create.roblox.com/docs/production/game-design/starter-pack-design).)
  Community price points: ~49–198 R$ ([DevForum poll](https://devforum.roblox.com/t/poll-starter-pack-price-points/397653),
  [rolearn](https://rolearn.dev/guidance/roblox-gamepass-pricing-strategy-guide)).
  One unsourced claim: conversion drops sharply between 400 and 600 R$ ([rowatcher](https://rowatcher.com/news/why-your-roblox-game-pass-pricing-is-backwards)).
- **Season pass premium:** 400–799 R$ (above). Tier skips: Rivals sells +5 tiers for 400 R$ and
  +30 for 2,400 R$ ([dungeonpath](https://dungeonpath.com/posts/rivals/complete-season-guide/)).
  Bedwars sells levels at 300 R$ ([progameguides](https://progameguides.com/roblox/roblox-bedwars-update-patch-notes/)).
- **Private servers:**
  - Developers set the price, often free or 100–200 R$ a month ([stealthygaming](https://stealthygaming.com/?p=22576)).
  - With Roblox Plus, a qualifying paid private server pays the creator based on its price, up to
    100 R$ per subscriber per server ([DevForum: Introducing Roblox Plus](https://devforum.roblox.com/t/introducing-roblox-plus/4567894/1)) [verify].
- **Paid random items.** Odds disclosure is mandatory; `PolicyService.ArePaidRandomItemsRestricted`
  must gate them; UK under-18s are blocked ([policy](https://create.roblox.com/docs/production/monetization/paid-random-items),
  [DevForum](https://devforum.roblox.com/t/update-on-paid-random-items-restriction-for-uk-users-under-18/3072183)).
  Rivals still sells wrap boxes at 5 keys a roll ([bloxodes](https://bloxodes.com/wiki/rivals/loot-boxes)).
  **We keep zero paid randomness.**
- **Regulatory heat on scarcity (important).**
  - May 2026: Fairplay and NCOSE asked the FTC to investigate Roblox games for "scarcity marketing" and
    "items only available for a limited time" ([Fortune](https://fortune.com/2026/05/20/exclusive-advocacy-groups-file-complaint-roblox-manipulative-design/?rand=8593),
    [Claims Journal](https://www.claimsjournal.com/news/national/2026/05/21/337716.htm)).
  - Italy's AGCM opened probes into Roblox, Fortnite and Brawl Stars in January 2026 (same coverage).
  - A University of Sydney study flags countdown timers and limited-time offers as misleading to children
    ([USyd](https://www.sydney.edu.au/news-opinion/news/2026/05/17/inside-the-pay-to-play-world-of-roblox-targeting-children-.html)).

  **Our "no timers / no only-N-left" rule is now also a regulatory hedge. A rotating shop must never make
  an item unobtainable.**

### 2.5 Social and viral

- **Friend Referral System** (Apr 2025):
  - developers can reward both the inviter and the invitee;
  - Roblox recommends one-time rewards, cooldowns and abuse monitoring.

  ([docs](https://create.roblox.com/docs/production/promotion/referral-system),
  [DevForum](https://devforum.roblox.com/t/announcing-the-new-friend-referral-system-for-your-experiences/3623795),
  [corp.roblox.com](https://corp.roblox.com)).
- **Party API.**
  - Tells the server who is in a Roblox Party together, so members aren't split across teams.
  - Does not work in Studio play-test.
  - Friend sessions run 1.9× longer.

  ([gameranx](https://gameranx.com/updates/id/540805/article/roblox-releases-party-api-system/),
  [newsroom](https://corp.roblox.com/newsroom/2024/12/join-the-party-on-roblox)).
- **Captures.** `CaptureService`: screenshot to a temporary content id, `PromptShareCapture` (native
  share sheet with an invite link), `PromptSaveCapturesToGallery`. Video capture appears in the current
  reference [verify] ([DevForum](https://devforum.roblox.com/t/captures-apis-are-now-available/2838188),
  [reference](https://create.roblox.com/docs/reference/engine/classes/CaptureService.md)).
- **Roblox Moments** (beta from Sep 2025): 13+ users share 30 s clips in a TikTok-style feed with a
  one-tap "play" into the experience ([TechCrunch](https://techcrunch.com/2025/09/05/roblox-announces-short-form-video-feed-for-gameplay-clips-new-ai-tools-for-creators-and-more),
  [DevForum](https://devforum.roblox.com/t/roblox-moments-a-new-era-of-user-generated-discovery-for-experiences-and-gameplay-is-here/3919813)).
  **Takeaway [E]:** design for 30-second highlights: champion kills, last-second extractions,
  Double or Nothing payoffs, the Melt closing.
- **Do not reward likes or favourites.** The Community Rules allow promo codes only when they are not
  in exchange for something, with a thumbs-up as the example
  ([DevForum](https://devforum.roblox.com/t/is-rewarding-players-for-liking-favoriting-a-game-allowed/2926286),
  [DevForum](https://devforum.roblox.com/t/the-issue-of-bribing-players-for-likes/4495969)).

---

## 3. Ranked feature table

Effort, in one engineer's days including specs and tests [E]: **S** ≤ 3 d · **M** 4–8 d · **L** 9–15 d · **XL** > 15 d.
"Fits rules" checks our rules: no paid randomness, no pay-to-win in PvP, no auto-prompts, no
countdown offers, earned skins stay earnable, kid-safe.

| Rank | Feature | Evidence / source | Expected impact [E] | Effort | Fits rules? |
|---|---|---|---|---|---|
| 1 | **Rookie Run**: training yard while waiting, protected first run, guaranteed first extraction, celebration | Roblox FTUE guide (end on a celebration); first-play bounce is scored on its own; Doors "Welcome" | First-play bounce −15–25% relative; D1 +3–5 pts | M | Yes |
| 2 | **The Melt**: shrinking zone per stage | Fortnite storm / Blitz; Dark and Darker circle; our 2.5× maps spread squads thin | More fights per stage, fewer dead minutes, better clips; median first PvP earlier | M | Yes (PvE hazard; pay can't affect it) |
| 3 | **Herd Contracts**: 3 daily + 6 weekly quests | Rivals daily tasks; AV daily/weekly; Benchmark Report | D1→D7 +10–20% relative; runs/day +0.5 | M | Yes (no quest needs Robux or a friend; PvP optional) |
| 4 | **Herd Pass**: 8-week, 50-tier free + premium track | Roblox season pass guide; Rivals / Bedwars / AV; Arc Raiders refund | D7–D28 +; 2–4% of payers buy it each season; +15–30% revenue | L | Yes (cosmetics + Golden Cheese only; no class XP, no power) |
| 5 | **Herd Call**: squad redeploy timer | Fortnite Reload; PUBG Comeback; Warzone debate | Fewer rage-quits after an early death; longer sessions | M | Yes (free for everyone; Second Wind rules unchanged) |
| 6 | **Pings + quick-chat + bot commands** | Apex pings; chat age-gated since Jan 2026 | Squad coordination for chat-less kids; bots feel smarter | S–M | Yes (preset text only = safe for under-13s) |
| 7 | **End-of-run MVP + Herd Awards + share card** | Celebrate moments (FTUE guide); CaptureService share; Moments | Raises "one more run"; organic shares | S | Yes (no purchase prompts on this screen) |
| 8 | **Bring Your Herd**: referral rewards + party bonus + Party API squads | Friend Referral System; Party API; friend sessions 1.9× longer | Co-play days ↑; cheap acquisition | S | Yes (one-time, abuse-capped) |
| 9 | **Mousepedia**: collection book + badges + achievements | Vampire Survivors; Brotato; Fisch bestiary; 5 free badges/day | Long-tail goals for D14–D28; class variety | M | Yes |
| 10 | **Shop v2**: starter pack, featured shelf (no scarcity), class bundles, emotes, best-value tags | Roblox starter pack guide (+2–10%); emotes in TSB; FTC / AGCM scarcity scrutiny | Payer conversion +20–40% relative; ARPPU ↑ | M | Yes, if the featured shelf never removes items from sale |
| 11 | Live-ops cadence: weekly "Cheese of the Week" mutator + monthly event | Grow a Garden / 99 Nights / AV cadence | Weekly CCU bumps; content for notifications | M + ongoing | Yes (events return; no FOMO-only items) |
| 12 | Codes + group reward (Herd Club group) | Doors, Rivals | Community growth, Discord / YouTube funnel | S | Yes (never for likes or favourites) |
| 13 | Experience Notifications + event RSVP | Notifications 13+, 1/day; RSVP API | Re-engage lapsed 13+ players | S | Yes (13+ only, opt-in, rare) |
| 14 | Leaderboard UI + weekly Herd Trials (free bracket rewards) | Arc Raiders Trials; Bedwars ladder; leaderboard UI is an open Minor | Competitive 13+ retention | M | Yes (cosmetic titles only; runs with paid tokens stay unranked) |
| 15 | Spectate upgrade: follow killer / squadmate, swap target, show redeploy timer | Standard in BR | Fewer quits while dead | S | Yes |
| 16 | Underdog bonus (comeback): +cheese and XP for the lowest-pot squad on champion kills | Warzone "fear of revenge" debate | Smooths snowballs | S | Yes |
| 17 | Private servers at 99 R$/month (bots fill seats) | Developer-set; Plus payout up to 100 R$ per subscriber [verify] | Small revenue; friends groups and YouTubers | S | Yes |
| 18 | Tier-skip bundle for the Herd Pass (+10 tiers) | Rivals / Bedwars | Small revenue | S | Borderline: cosmetics only, so allowed; ship after season 1 data |
| 19 | Gift a skin / pass | Dropped earlier (atomicity) | Social revenue | M | Yes, if done right |
| 20 | Kill cam | BR norm | Low for a top-down camera; the MVP screen covers it | M | Yes (low priority) |
| — | AFK / offline rewards | Creator Rewards anti-exploit; conflicts with run loop | Hurts session quality | — | **No** |
| — | Paid streak restore | Was dropped in MONETIZATION.md | — | — | **No** (pressure mechanic) |
| — | Rewards for likes or favourites | Community Rules | — | — | **No** |
| — | Paid gacha / crates | Paid random items policy; UK <18 blocked | — | — | **No** (our rule) |

---

## 4. Specs for the top 10

All tunables should live in `src/shared/Config/*` as pure Luau (HANDOFF §3). Numbers are starting
points to tune with live data [E].

### 4.1 Rookie Run (first-session flow)

**Goal:** first stomp within 20 s of spawning, a first extraction within about 8 min, and a celebration.

- **Training Yard (lobby):**
  - A fenced pen next to the lobby pad with 3 waves of 20 plain mice that respawn while the player waits.
  - Auto-attack and the ability work there. It gives no rewards except the coach marks, and teaches
    move / attack / ability before the match.
  - It opens automatically for players with `stats.runs == 0` (the camera pans to it). Anyone can walk in.
- **Faster start for rookies:** when the only humans in a lobby are rookies (`runs == 0`), the lobby
  auto-starts at **15 s** (instead of 30 s).
- **Rookie protection (runs 0–2):**
  - Enemy bot squads never target a rookie in stage 1 (they still fight back if attacked).
  - The rookie's squad bots stay within 20 studs of them.
  - Human enemies get no bounty for downing a rookie.
  - A "Rookie" leaf badge shows on the nameplate.
- **Guided first gate:**
  - In run 1, at the first Rind Gate, the Extract button pulses and is pre-selected (one tap).
  - Double or Nothing is hidden in runs 1–2 and introduced with a hint in run 3.
- **Guaranteed first champion:** in run 1, the first Mouse Champion spawns at the Champion Site nearest
  the rookie's corner, with ×0.7 HP.
- **Celebration (end of run 1):**
  - Full-screen "FIRST EXTRACTION!" with confetti.
  - Rewards: 500 cheese, 50 Golden Cheese, the **Rookie Trunk** trail (free cosmetic), the Welcome badge.
  - Then the screen points at the 3 daily Contracts (4.3).
- **Day-1 goals card (runs 1–5):** 5 checklist goals that each pay 100 cheese:
  - Extract once.
  - Kill a Mouse Champion.
  - Equip a gear item.
  - Spend a perk point.
  - Play a second class.
- **Analytics funnel** (`AnalyticsService:LogOnboardingFunnelStepEvent` [verify]), steps:
  join → yard → match start → first kill → first champion → first gate → extract → run 2 start.

### 4.2 The Melt (shrinking zone)

Hot fondue floods in from the arena edge. It reuses the arena radius R (320–400 studs) and the
150 s wave stage.

| Phase | Stage time (waves) | Zone radius | Damage outside (% max HP/s) |
|---|---|---|---|
| Safe | 0–55 s | R (no Melt) | — |
| Warning | 40 s | next ring (0.72 R) shown on the minimap + "The Melt rises in 15 s" | — |
| Shrink 1 | 55–80 s | R → 0.72 R | 2% |
| Hold 1 | 80–105 s (next ring 0.52 R shown at 90 s) | 0.72 R | 2% |
| Shrink 2 | 105–130 s | 0.72 R → 0.52 R | 4% |
| Hold 2 | 130–150 s | 0.52 R | 4% |
| Boss shrink | boss +15 s → +45 s | 0.52 R → max(0.30 R, 90 studs) | 6% |
| Final | boss +90 s, if the boss is alive | → max(0.18 R, 60 studs) over 20 s | 10% |
| Rind Gate | gate window (20 s) | frozen | 10% |

- **Centre:** the arena centre plus a random offset of ≤ 0.08 R (seeded per stage), so the boss
  (spawned at the centre) is always inside. Each ring is nested in the previous one.
- **At R = 350:** 252 → 182 → 105 → 63 studs. The champion ring (0.42–0.5 R) stays inside until
  shrink 2 ends. Lairs (0.2–0.25 R) stay inside throughout.
- **Squad corners** (≈0.9 R) are swallowed in shrink 1. Corner safe zones (−60% PvP damage) switch off
  at 55 s, with a toast: "Your corner is melting – move in!" The 9 s drop-in protection is unchanged.
- **Mice and POIs:**
  - Mice spawn only inside the zone.
  - POIs outside it grey out; channels there are cancelled.
  - Champion Sites outside the next ring don't spawn new champions.
  - Loot bags outside stay where they are (risk / reward).
- **Downed heroes in the Melt:** the downed timer runs ×2.
- **Bots:**
  - Start moving inside 10 s before each shrink.
  - Never path through the Melt unless already outside it.
  - Below 50% HP outside the zone, flee inward before anything else.
- **Pressure modifier "Hot Fondue":** every shrink 25% earlier, damage ×1.5.
- **Visuals:**
  - A rising orange-gold translucent wall (pooled Parts) with bubbles (ParticleEmitter) and a minimap ring.
  - Screen-edge orange vignette while outside.
- **Pacing guard:** re-run `IntegrationSquads.spec`. Expected: stage-1 eliminations ≤ 1 still; first PvP
  down median 40–60 s; champions killed per stage unchanged (±10%).

### 4.3 Herd Contracts (daily + weekly quests)

**Rules:**
- Daily: 3 contracts from the pool, reset 00:00 UTC.
- Unclaimed dailies **bank for up to 3 days**, so missing a day never wipes progress: a kind,
  kid-safe alternative to a streak penalty.
- 1 free reroll per day; extra rerolls cost 150 cheese (never Robux).
- Weekly: 6 contracts, reset Monday 00:00 UTC.
- Bot squadmates' actions never count, but **downs of enemy bots do count** toward PvP-flavoured
  contracts, so solo players can always finish everything.
- No contract requires Robux, a friend, Double or Nothing, or downing *human* players.

**Daily pool (each rolls Easy, Medium or Hard; one of each per day):**

| Id | Contract | Tier | Pass XP | Cheese |
|---|---|---|---|---|
| d_mice | Stomp 1,200 mice | E | 150 | 100 |
| d_runs | Finish 2 runs (extract or reach a gate) | E | 150 | 100 |
| d_crates | Channel 3 Armory Crates | E | 150 | 100 |
| d_ability | Use your ability 30 times | E | 150 | 100 |
| d_revive | Revive squadmates 2 times | E | 150 | 100 |
| d_champ2 | Help kill 2 Mouse Champions | M | 250 | 150 |
| d_extract | Extract with at least 300 pending cheese | M | 250 | 150 |
| d_stage3 | Reach stage 3 | M | 250 | 150 |
| d_totem | Hold a Power Totem for 30 s total | M | 250 | 150 |
| d_gear | Equip 3 Rare-or-better gear items | M | 250 | 150 |
| d_class | Finish a run as `<rotating class>` | M | 250 | 150 |
| d_golden | Catch a golden carrier mouse | M | 250 | 150 |
| d_vault | Open a Cheese Vault | H | 350 | 200 |
| d_lair | Help kill a Lair Champion | H | 350 | 200 |
| d_boss | Land a boss killing blow, or deal the most boss damage | H | 350 | 200 |
| d_stage4 | Reach stage 4 | H | 350 | 200 |
| d_route | Win a route choice | H | 350 | 200 |
| d_downs | Down 3 enemy heroes (bots count) | H | 350 | 200 |

**Weekly (all 6 every week; numbers scale ×1.0 / ×1.2 / ×1.4 in weeks 1–2 / 3–5 / 6–8 of a season):**

| Id | Contract | Pass XP | Reward |
|---|---|---|---|
| w_extract | Extract 5 times | 500 | 300 cheese |
| w_champs | Help kill 12 Mouse Champions | 500 | 300 cheese |
| w_stage4 | Reach stage 4 twice | 500 | 300 cheese |
| w_chests | Win 2 boss chests | 500 | 300 cheese |
| w_classes | Finish runs with 3 different classes | 500 | 300 cheese |
| w_bank | Bank 3,000 cheese in total | 500 | 300 cheese |
| **Bonus** | Complete all 6 | 600 | 25 Golden Cheese |

**Run XP to the pass:** 40 per stage reached + 60 for extracting + 20 per champion assist, at most
300 a run. The first run of the day ×2 (stacks with the existing first-run cheese bonus).

**Budget check [E]** (pass of 50 tiers × 1,000 XP = 50,000 XP):

| Player type | Days/week | Runs/day | Run XP (avg ~150/run, first run of day ×2) | Daily XP (750/day) | Weekly XP (max 3,600) | Per week | Tier 50 by |
|---|---|---|---|---|---|---|---|
| Regular | 4 | 3 | ~2,400 | 3,000 | 3,600 | ~9,000 | week 6 |
| Casual | 2 | 2 | ~900 | ~2,250 (banked days) | ~1,500 | ~4,650 | tier ~37 by week 8 |
| Daily grinder | 7 | 5 | ~6,300 | 5,250 | 3,600 | ~15,150 | week 4 (then tiers 51–60) |

### 4.4 Herd Pass (season pass)

- **Season 1, "Winter Rind":** 8 weeks, about 2026-12-14 to 2027-02-08. Seasons 2+ are 8 weeks each with a
  1-week overlap break.
- **Tiers:** 50 × 1,000 XP, plus bonus tiers 51–60 (2,000 XP each).
- **Free track:** every player is enrolled. **Premium:** a one-time 499 R$ game pass *per season*.
- **Roblox guide rules** ([season pass design](https://create.roblox.com/docs/production/game-design/season-pass-design)):
  - premium is a superset of free;
  - **back-date** premium rewards for tiers already reached when someone upgrades mid-season;
  - **auto-grant** unclaimed rewards at season end.
- **Never in the pass:** class XP, perk points, gear, talents, cheese boosts, Second Wind tokens.
- **Pass XP sources:** contracts (4.3) and play only. Robux never buys pass XP in season 1.

| Track | Count | Rewards |
|---|---|---|
| **Free** (20 rewards, at roughly every 2nd–3rd tier) | 20 | 6 × 300–600 cheese (3,000 total); 3 × reroll-token packs of 3; 3 × 25 Golden Cheese (75); 2 emotes (Trunk Toot at T8, Cheese Wave at T26); 1 trail (Frost Crumbs, T18); 1 hat (Snow Cap, T36); 1 title ("Winter Herd", T40); 1 tint (Icy Rind, T46); **T50: Winter Herd universal class skin colours** |
| **Premium** (50 rewards, one per tier, on top of free) | 50 | 3 class skins (Elephante, Ellie Fawn, Jumbo "Winter" skins at T10 / T25 / T40); 1 universal Elephant Snowsuit (T30); 5 trails; 5 hats; 4 tints; 4 emotes; 1 stomp VFX (Snowburst, T20); 2 nametag frames; 2 titles; **500 Golden Cheese total** in 10 × 50 drops (T5, T9, T14, T19, T24, T29, T34, T39, T44, T49); remaining tiers are sprays-as-hat-decals / colour variants; **T50: animated "Aurora Trunk" tint + Winter Monarch title** |
| **Bonus tiers 51–60** | 10 | Free and premium: 25 Golden Cheese each (premium) / 100 cheese each (free) |

- **Value story [E]:** 500 Golden Cheese ≈ 230 R$ of GC packs, so premium "pays back" about 45% of its
  price, like Arc Raiders' refund but smaller, which encourages renewal.
- **Shown value:** "about 3,000 R$ of items". This is computed honestly from the Golden Cheese shop price
  of each item and displayed as a fixed fact, never as "–80%!".
- **Season skins:** after their season they move to the Golden Cheese shop at full price 6 months later.
  That avoids "gone forever" scarcity (FTC / AGCM scrutiny, §2.4) while keeping pass owners early.
- **UI:**
  - Lobby board + a Pass tab with a tier track and a free / premium row.
  - "Upgrade" is a button the player presses; we never prompt on our own.
- **Implementation:** start from Roblox's Season Passes feature package
  ([docs](https://create.roblox.com/docs/resources/feature-packages/season-passes)). Persist
  `profile.season = {id, xp, claimedFree, claimedPremium}`; premium ownership comes from
  `UserOwnsGamePassAsync` like the other passes.

### 4.5 Herd Call (squad redeploy)

Today a dead hero spectates until the next stage. That is up to about 3 minutes doing nothing on
mobile, a quit risk [E].

- **Timer:** when a hero dies (not downed) and **at least one squadmate is standing**, a personal timer
  starts: **20 / 25 / 30 / 35 s** in stages 1 / 2 / 3 / 4.
- **Teammates shorten it:** −3 s per champion kill by the squad; −2 s per enemy hero downed;
  −1 s per POI channel finished.
- **Redeploy:**
  - The hero drops next to the squadmate with the most HP, at 60% HP, with 5 s of spawn protection
    (`World.SPAWN_PROTECT`) that ends if they attack.
  - Gear is gone (it dropped in the loot bag); in-run level and upgrade cards are kept.
- **Limits:**
  - At most 1 redeploy per hero per stage.
  - Timers freeze during the boss phase and the last 20 s of waves (the Melt is closing); such heroes
    return at the next stage start, as today.
- **Elimination is unchanged:** if everyone is dead or downed with nobody to revive, the squad is out.
  Herd Call never brings back an eliminated squad.
- **Monetization:** none. Second Wind tokens keep their v2 rules. Herd Call is free and identical for everyone.
- **Spectate while waiting:**
  - The camera follows the squadmate the redeploy will land on.
  - The timer shows big; "your squad cuts this timer by fighting" is the hint.
  - Tap to cycle between squadmates (feature 15).
- **Sim guard:** pacing targets still hold; stage-4 reach may rise. Cap with the per-stage limit.

### 4.6 Pings, quick-chat and bot commands

- **Ping key:** Q / MMB on PC, R1 on gamepad, a ping button on touch, or tap the minimap. It is
  context-sensitive:

  | Pinged thing | Marker | Bot squadmates respond |
  |---|---|---|
  | Ground | "Go here" (squad colour) | Move there and hold for 15 s |
  | Enemy hero / squad | "Enemy!" (red, follows the target for 6 s) | Engage if ≥ 65% HP, else keep distance |
  | Mouse Champion | "Fight Champion" | Join the champion fight |
  | POI / gear / loot bag | "Loot here" / item name | One bot channels / picks up (gear goes to the human first) |
  | Rind Gate (gate window) | "Extract!" / "Stay!" | Counts as the human's vote hint for bots |
  | Long-press | "Help!" at your position | Nearest bot comes to you |

- **Limits:** visible only to your squad; 3 active pings per player; 1.2 s cooldown; markers last 6 s.
- **Quick-chat wheel** (preset, localised text; no free text, so it is safe for chat-less and under-13
  players): "Nice!", "Thanks!", "Follow me", "Wait", "Group up", "Champion!", "Extract?", "Let's stay!".
  Squad-only.
- **Emote wheel:** shares the radial UI and uses the emotes from 4.10 / 4.4. Emotes play anywhere and
  are visible to all.
- **Server:** a new `Net.C2S.Ping(kind, targetId?, pos?)` through `Guard.connect`, rate-limited.
  BotBrain gets a `pingGoal` that outranks POIs but not survival.

### 4.7 End-of-run MVP and Herd Awards

- **Results screen (5 s auto-advance on mobile; tap to skip):**
  1. **Match MVP card:** the human or bot with the highest score:
     `score = mice/10 + 40·championKillsShare + 25·heroDowns + 30·revives + 2·bossDamagePct + 50·extracted`.
     A bot can win MVP, labelled 🤖.
  2. **Your 3 Herd Awards** from 12 accolades, picked by percentile against the match:
     - Mouse Masher (mice)
     - Champion Slayer
     - Clutch Reviver
     - Loot Goblin (gear picked up)
     - Vault Raider
     - Totem Keeper
     - Boss Breaker
     - Escape Artist (extracted under 30% HP)
     - Pack Mule (cheese banked)
     - Bounty Hunter
     - Melt Dodger (least Melt damage while moving)
     - Iron Trunk (least damage taken)
  3. **Progress panel:** class XP bar, pass XP bar, contracts ticked this run, Mousepedia entries found.
- **Buttons:** **Play again** (default; same squad, same class), **Share** (`CaptureService`
  screenshot of the MVP card → `PromptShareCapture`, with an invite link [verify]), **Invite friends**.
  **No purchase buttons or prompts on this screen** (existing rule).
- **Moments-friendly [E]:** a 2-second "slow-mo stomp" replay of the MVP's last champion kill, rendered
  from the existing snapshot buffer client-side, so 13+ players' native clip tools catch a hype moment.

### 4.8 Bring Your Herd (friend referrals and party bonus)

- **Referral** (Roblox Friend Referral System + `SocialService:PromptGameInvite` with `launchData` [verify]):
  - Invitee, when they **finish their first run** (≥ 5 min in game, first-time player):
    100 Golden Cheese + the "Herd Buddy" emote.
  - Inviter, per qualifying friend: 100 Golden Cheese; at 3 friends, the **Herd Bond** trail; at 10,
    the **Matriarch** title.
  - Caps: 10 rewarded referrals per 30 days; 1 reward per invitee ever; no reward for alt accounts
    (same-device heuristics are not available, so rely on "first run finished" plus the cap).
- **Party bonus:** for each friend (Roblox friend or Party member) in your squad, +10% pass XP and
  +5% cheese, max +20% / +10%. Additive with the cheese stack in MONETIZATION.md and applied after
  Double or Nothing, like the other multipliers.
- **Party API:** keep Roblox Party members in the same squad and the same server (extend "friends who
  join together are placed in the same squad"). It doesn't run in Studio, so test on a private live place.
- **Squad invite after a good match:** on the results screen, "Add to squad again" for non-friend
  humans you played with. It only keeps them together for the next run on this server; it sends no
  friend request.

### 4.9 Mousepedia (collection book + badges + achievements)

- **Pages and entries** (an entry fills on first defeat / find / use):

  | Page | Entries | Page reward |
  |---|---|---|
  | Bosses | 13 | Badge "Boss Hunter" + Golden Rind hat |
  | Mouse Champions (+ lair variants) | 6 + 6 | Badge "Champion's Bane" + Champion Crest nameplate frame |
  | Mice (enemy types) | all enemy types in `Config/Enemies` | Badge "Mouseologist" + 500 cheese |
  | Gear | ~30 (each counts at any rarity; Legendary sets a gold star) | Badge "Quartermaster" + Gear Rack lobby emote |
  | Maps | 9 (reach the boss on each) | Badge "World Wanderer" + map-themed trail |
  | Classes | 7 (reach class level 5) | Badge "Whole Herd" + Herd Banner title |

- **Per entry:** +5 Golden Cheese and +50 pass XP the first time, about 450 GC across the book [E].
- **Achievements** (40 at launch, 10 per category: Combat, Squad, Risk, Mastery). Examples:
  - Win a Double or Nothing (Risk; allowed because no Robux touches it)
  - Extract with all 3 squadmates alive
  - Kill a champion while the Melt is closing
  - Clear stage 4 at Pressure 10

  Each gives a title or nametag sticker; the 10 hardest also give badges.
- **Badge rollout:** 5 free badges per day per experience, so create 20 in 4 days, then wire the
  existing Mastery badge ids.

### 4.10 Shop v2 (Robux and Golden Cheese)

**Principles:**
- Fixed contents shown before purchase.
- No timers, no "only N left", no discount countdowns.
- The weekly featured shelf is a **spotlight, not a vault**: everything stays buyable in the catalog.
- Price anchoring uses honest, fixed value numbers only.

**Layout (lobby Shop tab):**
1. **Featured shelf** (top): 4 items or bundles, rotating each Monday. Past featured items move to
   the catalog; nothing disappears.
2. **Starter Pack tile:** visible from first spawn to accounts with < 5 runs or < 7 days, and in the
   catalog after that. It never auto-prompts.
3. **Herd Pass tile.**
4. **Catalog tabs:** Skins · Trails · Hats · Tints · Emotes · Bundles · Passes · Golden Cheese.

**New Robux items (to add to `Config/Monetization.luau`):**

| Key | Type | Price (R$) | Contents | Why |
|---|---|---|---|---|
| `starter_pack` | Pass (one-time) | **149** | "Rookie Herd": Rookie skin for the 3 starter classes, Rookie Trunk Gold trail, 2 emotes (Trunk Toot, Peanut Toss), 250 Golden Cheese. Shown value "≈ 650 R$ of items" | Roblox: starter pack = best value, shown early; 149 sits in the community 49–198 band |
| `herd_pass_s1` | Pass (per season) | **499** | Premium Herd Pass track (4.4) | Below the Bedwars / Rivals 799 norm for a new game; under the claimed 400–600 R$ conversion drop |
| `emote_pack_1` | Pass | **199** | 6 emotes: Stomp Dance, Trunk Trumpet, Cheese Juggle, Belly Flop, Mouse Shoo, Victory Spray | Replaces the dropped Emote & Sticker Pack |
| `private_server` | Private server | **99 / month** | Your own 12-seat server; friends join; bots fill the rest; unranked | Low price; Roblox Plus payout up to 100 R$ per subscriber [verify] |
| Golden Cheese packs | Product | 49–999 (existing) | Add a "Best value" tag on `golden_l` (499) and "+N% bonus" chips | Anchoring with facts already true |

**Golden Cheese catalog additions:**

| Item | Golden Cheese |
|---|---|
| Single emote | 150 (common) / 250 (fancy, e.g. a particle emote) |
| Class Look bundle (skin + hat + trail for one class) | 600, a fixed 15% below buying each item |
| Stomp VFX (cosmetic hit effect) | 300 |
| Nameplate frame | 200 |
| Past-season skin (6 months after its season) | 450 |

Cheese Club's 10% off applies to all of these.

**Featured shelf rotation (week 1 example):** Class Look: Ellie Fawn "Moonlit" (600 GC) · Emote:
Belly Flop (250 GC) · Trail: Swiss Steam (300 GC) · Golden Cheese 550 pack (249 R$).

**Conversion targets [E]:**
- Starter pack bought by 1.5–3% of new players who finish run 1.
- Herd Pass bought by 25–35% of existing payers per season.
- Re-check the revenue model in MONETIZATION.md after season 1.

---

## 5. Policy-sensitive notes for kids (keep these)

| Topic | Rule for Trunkfall |
|---|---|
| Limited-time items | Items rotate but **return**: season skins come back to the GC shop after 6 months; event cosmetics return the next year (Dandy's World pattern). No countdowns on offers (FTC complaint May 2026, AGCM Jan 2026). |
| Streaks | Keep the existing "step back one day" streak. Dailies bank up to 3 days. **Never sell streak restores.** |
| Quests | No quest needs Robux, a friend, Double or Nothing, or downing a *human*. Solo + bots can finish all of them. |
| Pass | Cosmetics + Golden Cheese only. No power, no class XP, no Second Wind. Upgrade only by pressing a button. |
| Pings / quick-chat | Preset phrases only, squad-only, so they work for chat-less (age-gated) players and carry no moderation risk. |
| Referrals / codes / group | One-time rewards, capped. **Never reward likes or favourites.** Codes are never "in exchange for" anything. |
| Notifications | 13+ opt-in only; the prompt at most every 30 days; at most 1 a day; only for real events (new season, weekly event). |
| Rewarded ads / Moments | 13+ only (existing rule for ads). Share buttons use the native flow; no forced sharing. |
| AFK rewards | Not offered. |
| Paid randomness | None. `DataConfig.spec`'s `random = false` assertion covers new items. |

---

## 6. Suggested build order [E]

1. **Sprint A (2 weeks):** Rookie Run (4.1), Pings (4.6), MVP / results (4.7), Bring Your Herd (4.8).
   Mostly client and small server work, aimed at first-session and co-play metrics.
2. **Sprint B (2 weeks):** The Melt (4.2) and Herd Call (4.5) together, because both change pacing; one
   sim re-tune pass.
3. **Sprint C (3 weeks):** Contracts (4.3), Herd Pass (4.4), Shop v2 (4.10). Launch Season 1 about 2026-12-14
   with a winter event (feature 11) and a code and notification push.
4. **Sprint D:** Mousepedia (4.9), leaderboard UI + weekly Herd Trials (14), spectate upgrade (15).

Instrument every feature with funnel and custom events before shipping it. "No analytics events" is an
open Minor in HANDOFF §5, and without them we cannot tell which of these moved D1 or D7.

---

## Sources

Roblox official / DevForum:
- https://create.roblox.com/docs/production/game-design/season-pass-design
- https://create.roblox.com/docs/resources/feature-packages/season-passes
- https://create.roblox.com/docs/production/game-design/starter-pack-design
- https://create.roblox.com/docs/production/game-design/onboarding
- https://create.roblox.com/docs/production/promotion/referral-system
- https://devforum.roblox.com/t/announcing-the-new-friend-referral-system-for-your-experiences/3623795
- https://create.roblox.com/docs/production/promotion/experience-notifications
- https://devforum.roblox.com/t/introducing-in-experience-notification-permission-prompts/2909125
- https://devforum.roblox.com/t/issues-with-opencloud-experience-notifications/3874557
- https://devforum.roblox.com/t/introducing-the-new-experience-event-apis/3754058
- https://create.roblox.com/docs/production/monetization/paid-random-items
- https://devforum.roblox.com/t/update-on-paid-random-items-restriction-for-uk-users-under-18/3072183
- https://create.roblox.com/docs/creator-rewards
- https://devforum.roblox.com/t/introducing-creator-rewards-earn-more-by-growing-the-community/3777628/363
- https://devforum.roblox.com/t/announcing-free-badge-creations/1680515
- https://devforum.roblox.com/t/captures-apis-are-now-available/2838188
- https://create.roblox.com/docs/reference/engine/classes/CaptureService.md
- https://devforum.roblox.com/t/roblox-moments-a-new-era-of-user-generated-discovery-for-experiences-and-gameplay-is-here/3919813
- https://corp.roblox.com/newsroom/2024/12/join-the-party-on-roblox
- https://devforum.roblox.com/t/introducing-roblox-plus/4567894/1
- https://create.roblox.com/docs/en-us/reference/engine/classes/GroupService.md
- https://devforum.roblox.com/t/is-rewarding-players-for-liking-favoriting-a-game-allowed/2926286
- https://devforum.roblox.com/t/the-issue-of-bribing-players-for-likes/4495969
- https://devforum.roblox.com/t/creator-spotlight-woozynate-makes-a-splash-with-fisch/3269481
- https://devforum.roblox.com/t/poll-starter-pack-price-points/397653
- https://www.businesswire.com/news/home/20260107986568/en/Roblox-Requires-Users-Worldwide-to-Age-Check-to-Access-Chat

Industry / press:
- https://gameindustrylibrary.com/documents/the-2025-roblox-benchmark-report
- https://newsletter.gamediscover.co/p/analysis-ugc-still-powers-sales-and
- https://www.gameanalytics.com/blog/dead-rails-and-the-hit-makers-formula
- https://www.metaversemarcom.io/post/why-grow-a-garden-is-winning-and-what-you-can-learn-from-it
- https://www.metaversemarcom.io/post/how-dead-rails-became-hottest-roblox-game
- https://www.pocketgamer.biz/roblox-game-grow-a-garden-beats-steam-with-record-concurrent-user-high-of-89m
- https://www.nme.com/news/gaming-news/roblox-grow-a-garden-major-changes-coming-update-cooking-3884432
- https://www.pcgamer.com/gaming-industry/roblox-to-make-facial-age-checks-mandatory-to-access-any-chat-features-and-will-put-common-sense-limits-on-the-age-ranges-users-can-chat-within
- https://techcrunch.com/2025/09/05/roblox-announces-short-form-video-feed-for-gameplay-clips-new-ai-tools-for-creators-and-more
- https://gameranx.com/updates/id/540805/article/roblox-releases-party-api-system/
- https://fortune.com/2026/05/20/exclusive-advocacy-groups-file-complaint-roblox-manipulative-design/?rand=8593
- https://www.claimsjournal.com/news/national/2026/05/21/337716.htm
- https://www.sydney.edu.au/news-opinion/news/2026/05/17/inside-the-pay-to-play-world-of-roblox-targeting-children-.html
- https://rowatcher.com/news/what-the-roblox-algorithm-actually-rewards-in-2026-not-ccu
- https://rowatcher.com/news/reward-schedules-in-roblox-why-daily-login-bonuses-backfire
- https://rowatcher.com/news/daily-login-bonuses-are-lazy-design-here-s-what-works-instead
- https://rowatcher.com/news/why-roblox-reward-schedules-break-after-day-14
- https://rowatcher.com/news/why-your-roblox-game-pass-pricing-is-backwards
- https://rolearn.dev/guidance/roblox-gamepass-pricing-strategy-guide
- https://www.pcgamer.com/apex-legends-ping-system-is-a-tiny-miracle-for-fps-teamwork-and-communication
- https://gamesradar.com/the-apex-legends-ping-system-is-a-brilliant-solution-to-the-horror-of-playing-with-strangers-online
- https://www.ggrecon.com/guides/fortnite-reload-explained/
- https://videogamer.com/news/fortnite-reload-duos-makes-essential-changes-to-keep-players-in-the-game
- https://mp1st.com/title-updates-and-patches/fortnite-update-4-29-for-v30-20-brings-squad-reload
- https://pcgamer.com/pubgs-latest-patch-adds-an-apex-legends-style-respawn-system
- https://charlieintel.com/call-of-duty/warzone-players-divided-over-excessive-respawn-options-in-battle-royale-mode-301162
- https://gamertagmythras.com/blog/fortnite/fortnite-storm-phases-guide
- https://gamertagmythras.com/blog/fortnite/fortnite-blitz-royale-guide
- https://fortnite-archive.fandom.com/wiki/The_Storm_(Battle_Royale)
- https://www.vhpg.com/?p=49961
- https://steamcommunity.com/app/2016590/discussions/0/4340987076277810630
- https://www.pcgamer.com/au/the-future-of-battle-royale-is-here-and-theres-no-circle/
- https://www.pcgamer.com/games/fps/hunt-showdown-keeps-experimenting-with-the-extraction-genre-and-its-next-twist-sounds-irresistible-soon-extraction-points-and-loot-wont-appear-on-the-map
- https://mein-mmo.de/en/of-course-that-encourages-us-developers-behind-arc-raiders-had-to-rethink-because-the-community-is-more-peaceful-than-expected,1552698
- https://www.gfinityesports.com/article/arc-raiders-creators-want-you-to-stop-shooting-each-other
- https://games.gg/news/arc-raiders-paid-battle-pass/
- https://arcraidershub.com/blog
- https://www.playnews.gg/en/guides/arc-raiders-the-trials-system-guide-ranks-scorta-and-patch-1-36-to-dominate-season-5-2026
- https://techraptor.net/gaming/guides/deep-rock-galactic-survivor-guide
- https://steamcommunity.com/stats/1794680/achievements
- https://rogueranker.com/vampire-survivors-achievements/
- https://commonsensegamer.com/brotato-how-to-unlock-all-characters/
- https://brotato.wiki.spellsandguns.com/Progress

Game guides / wikis (approximate figures):
- https://dungeonpath.com/posts/rivals/season-3-battle-pass-guide/
- https://dungeonpath.com/posts/rivals/complete-season-guide/
- https://robloxden.com/game-codes/rivals/guides/how-to-get-keys-fast-in-rivals
- https://allthings.how/roblox-rivals-wildcat-cost-stats-and-contract-rewards/
- https://bloxodes.com/wiki/rivals/loot-boxes
- https://www.gamesradar.com/games/fps/roblox-rivals-codes
- https://www.pcgamer.com/games/roblox/roblox-rivals-codes/
- https://www.sportskeeda.com/roblox-news/5-best-gamepasses-roblox-bedwars
- https://progameguides.com/roblox/roblox-bedwars-update-patch-notes/
- https://sportskeeda.com/roblox-news/roblox-bedwars-ranked-guide
- https://allthings.how/anime-vanguards-how-to-max-the-meliodas-battle-pass-fast/
- https://www.sportskeeda.com/roblox-news/anime-vanguards-neon-chrome-battle-pass-all-rewards-premium-price
- https://progameguides.com/roblox/how-to-get-all-badges-in-roblox-doors/
- https://www.droidgamers.com/guides/roblox-doors-achievements/
- https://sites.google.com/view/doors-the-guide/game-mechanics
- https://www.pcgamesn.com/roblox/doors-codes
- https://deltiasgaming.com/?p=194530
- https://progameguides.com/roblox/complete-fisch-fischgiving-event-guide-quests-rewards-more/
- https://dandys-world-robloxhorror.fandom.com/wiki/Currencies
- https://www.ginx.tv/en/?p=63335
- https://www.gamezebo.com/walkthroughs/how-to-get-emotes-in-the-strongest-battlegrounds/
- https://bloxodes.com/wiki/the-strongest-battlegrounds
- https://stealthygaming.com/?p=22576
