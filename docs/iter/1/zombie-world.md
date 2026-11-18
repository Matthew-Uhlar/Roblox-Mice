# Iteration 1: Zombie World research team report (2026-11-18)

Scope: deepen `docs/research/zombie-world.md` on Zombie World (TKS, original), Zombie World: Unity
and Zombie World: Liberty (StarCraft II arcade). Then compare with our game and `docs/V5-PLAN.md`.
Mechanics only; no names, art or text are to be copied. Read-only on `src/`.

## Sources and access log

| Source | Status |
|---|---|
| S1 https://zombieworldgames.weebly.com/ (home) | read |
| S2 https://zombieworldgames.weebly.com/zombie-world.html (original map, TKS tips) | read |
| S3 https://zombieworldgames.weebly.com/zombie-world-unity.html | read |
| S4 https://zombieworldgames.weebly.com/zombie-world-unity-donations.html | read |
| S5 https://github.com/DarthVan/StarCraft2-Bank-Restorer (public clone: `README.md`, `updates.json`, compiled bundles `js/index-eR9pMu5H.js` = Liberty bank generator, `js/index-Mm2SNkkl.js` = Unity bank generator, both compiled 2024-11-26) | read (git clone). The GitHub API and the discussions page answered 403 through the proxy, so they were skipped. |
| S6 YouTube search result pages (titles and snippets), e.g. https://www.youtube.com/results?search_query=zombie+world+unity+sc2 , `...=ZWU+challenge`, `...=zombie+world+liberty+sc2`, `...=zombie+world+unity+prestige` | read. Individual watch pages returned a bot check ("unusual traffic") after 3 fetches, so they were skipped. |
| S7 Blizzard SC2 forums (public Discourse JSON): https://us.forums.blizzard.com/en/sc2/t/12968 , /t/19410 , /t/24633 , /t/25925 , /t/26644 , /t/26798 | read |
| S8 Fan wiki zombie-world-unity.fandom.com (Talents, Bosses, Difficulty, Challenges, Characters, Ancient Shrine) | **403 to curl, so not fetched.** Facts tagged **[wiki-snippet]** come only from web-search result snippets of these pages. They are **unverified**, and the wiki itself says some pages are 100–1,000 days old and contradict each other. |
| Reddit (search.json) | 403, skipped |
| Liquipedia (API, gzip) | no Zombie World page exists (search hits are unrelated players and tournaments) |
| Korean (Inven) / Russian (Blizzard RU forum) web searches | no relevant hits |

## New findings

Each fact gives its source. **[verified]** means read directly from the source. **[wiki-snippet]** means unverified (see S8). **[inferred]** is our reading of a data field or a title.

### F1. Unity: what is saved (bank fields) — S5 `js/index-Mm2SNkkl.js`

- **Kills are saved per class (role), not per hero** [verified]: `assassinkills`, `builderkills`, `singletargetkills`, `specialistkills`, `splashkills`, `supportkills`, `tankkills`. The editor caps each at 1.5 billion.
- **Best wave** `wave`, and the talent-point balance [verified].
- **20 account-wide talents**, with the values the editor's "fill all talents" writes, which we read as the rank caps [verified field list; caps inferred]:

  | Talent | Ranks | Talent | Ranks |
  |---|---|---|---|
  | Damage | 100 | Shield armor bonus | 10 |
  | Move speed | 10 | Shield armor multiply | 10 |
  | Life | 100 | Energy | 10 |
  | Life regen | 100 | Energy regen | 10 |
  | Life armor bonus | 10 | Cooldown | 25 |
  | Life armor multiply | 10 | Build | 25 |
  | Shield | 100 | Damage reduction | 10 |
  | Shield regen | 100 | Experience | 100 |
  | Mineral start | 5,000 | Respawn speed | 20 |
  | Vespene start | 500 | Mastery | 15 |

  The talents are stored once per account (section `TP`), not per hero.
- **Evolution stage per hero line** [verified field names; meaning inferred]: `marinestage`, `goliathstage`, `archonstage` and so on. "Upgrade all units" sets most of them to 9 or 10 (adept 4, hotshot 3). So Unity heroes have up to about 9–10 upgrade steps, not 4.
- Flags `unlockhero`, `UnlockHydralisk2` and `KillReducerForBounty` [verified names]. A `Plays` counter [verified].
- **Challenges** are saved as progress values 0–100: Infantry, Team Game, Constructor, Shield Problems, Next-to-Dead, Warp Speed and Torture, plus an Evasive flag [verified].

### F2. Liberty: what is saved — S5 `js/index-eR9pMu5H.js`; `updates.json`

- **Account:** Total Kills, **Best Solo** (a difficulty tier, from a selector with 12 entries: None, Easy, Normal, Hard, Brutal, Insane, Nightmare, Chaotic, Torture, Inferno, Torment, Death), **Jewel Dust** (a currency), the "Skip Wave At" setting (default 125), and **30 challenge flags** (`CLHistory`, loop of 30) [verified].
- **11 heroes, each with:** kills, **level 1–50**, **prestige** (the editor's sample values are 5–20; the editor cap is 99), and an **8-node "ascension" string** (`"00000000"` to `"11111111"`) [verified]. One starter hero is always owned. Other heroes are flagged under `Purchases` [verified]. So Liberty keeps hero level across games, then prestige, then 8 ascension nodes.
- **Jewels** (`SoulType` / `SoulStat`) [verified]:
  - Each jewel has a **tier 1–14** and **5 rolled stats**: income (minerals; the roll ×10), damage, life, armor and speed.
  - It also has a **unique perk** slot (0 = none) and an **upgrade** level.
  - Stat roll range by tier: 1: 1–5 · 2: 5–10 · 3: 5–20 · 4: 10–30 · 5: 15–40 · 6: 20–50 · 7: 25–60 · 8: 30–75 · 9: 35–90 · 10: 40–105 · 11: 50–125 · 12: 60–145 · 13: 75–170 · 14: 90–200.
  - **The tier names match the difficulty names** (tier 4 "Brutality" ↔ Brutal, tier 6 "Nightmare", tier 9 "Inferno", tier 11 "Death"…). [inferred] A jewel's tier comes from the difficulty it dropped on, so jewel quality is tied to difficulty.
  - **11 unique perks:**
    - 5 class-specific buffs;
    - −10% cooldowns;
    - +2 move speed;
    - "less HP, more damage";
    - 20% chance of double damage;
    - immunity to slows and stuns.
  - **Jewel inventory limit: 200** (`updates.json` 1.1.9, 2024-11-26).
- **Liberty is versioned "beta" 0.112 → 0.145** (Nov 2023 → Jun 2024) [verified, `updates.json`]. It is still played in Nov 2026: S6 shows a Liberty "Insanity" run from 3 weeks ago, and a "Blackout Challenge 2026 May edition".
- The prior claim that "each jewel buffs every player" comes from the maintainer comment in the earlier research. It could not be re-read here (403).

### F3. Unity hero ladder and unlocks — S8 [wiki-snippet, unverified; the wiki has two conflicting versions]

- **About 48 characters in about 7–8 classes.** Each class is a ladder from T1 (free) to T6, unlocked by **that class's kills**. Newer page:
  - Assassin: T2 20k · T4 161k · T5 386k · T6 1.0M
  - Splash: T2 25k · T3 78k · T4 157k · T5 375k · T6 750k
  - Specialist: T2 20k · T3 123k · T4 221k · T5 525k · T6 1.25M
  - Support: T2 10k · T3 56k · T4 142k · T5 333,333 · T6 666,666
  - Tank: T2 20k · T3 60k · T4 123k · T5 311k · T6 1.0M
- **A "Combo" class needs kills in several classes** (e.g. one hero needs Assassin + Splash + Tank kills).
- **The ladder is steep, roughly ×50 from T2 to T6.** Original map: "1 million kills in 10 hours" [verified, S2].

### F4. Unity talent-point sources and costs — S8 [wiki-snippet] unless noted

- **Damage talent:** +1% damage per point, 100 TP per point, up to +100% (so 10,000 TP to max).
- **Respawn speed talent:** −1 s per level, 10 TP per level, 20 levels (200 TP).
- **The Prestige talent opens only when every other talent except Mastery is maxed.**
- **Corner minibosses** (2, respawning every 5 min):
  - The TP reward **escalates with each consecutive kill in the same game**: 8, +8 per kill (another page says 4, +4), **capped at 160**.
  - They are "the best TP source".
- Wave bosses give 1 TP, and the twin boss gives 2. Every 5th wave is a boss wave. Boss waves past wave 100 give almost no TP.
- **A hidden crystal on the map gives 10 TP.**
- **Difficulty rewards** (10 tiers, Easy → Torment III):

  | Tier | Wave goal | Win reward | Completion reward |
  |---|---|---|---|
  | Easy | 50 | ×0.5 kills, 13 TP | 100 TP |
  | Normal | 60 | ×1 kills, 30 TP | 200 TP |
  | Brutal | — | a flat 5,000 class kills | — |
  | Torment I | — | ×9.5 kills, 650 TP | — |
  | Torment II | — | ×22 kills, 1,250 TP | — |
  | Torment III | 225 | **×70 kills, 2,250 TP** | **5,000 TP** |

  - Boss spawn rate goes from ×1 (Easy, Normal) to ×10 (Torment II) and ×14 (Torment III).
  - The reward spread from bottom to top tier is about 170× in TP.
- **"Ancient Shrine" gamble:**
  - Only the hero can trigger it, and it works at most 3 times per game.
  - About 60% of rolls give nothing.
  - The good outcomes include a solo or team TP gift. The bad ones include the hero dying or pulling every monster's attention.
- **Challenges** (8):
  - **Restricted rosters:**
    - Infantry: 2 heroes only;
    - Team Game: tank + support only;
    - Constructor: 3 builders;
    - Evasive: 2 heroes;
    - Torture: everyone except 2 heroes;
    - Next-to-Dead: 2 heroes, start with +2,500 minerals and **1 HP**;
    - Warp Speed and Shield Problems.
  - **Rewards** (one-time): 150–750 TP plus **×2 to ×6.25 of the kills earned in that game**, an achievement, and "Evolutions". The figures conflict between pages.

### F5. Original Zombie World — S2 [verified]

- **Saved hero levels go to 251.** An achievement ("immortal") changes a hero's power.
- **A wave 999 final boss**, and players "pick IMPOSSIBLE speed and GODLIKE life".
- **Kills were split 1/N across up to 8 players, so solo farming was faster.** The creator's own guide says so: "less than the other plan because the kills are split into 1/8". This is a design anti-pattern.
- One player per lane (6 lanes) is the high-wave team strategy.
- A lifesteal ("leech") vespene buff in a map corner makes a hero "not killable".
- **Leveling a fresh hero:** stand within about 10 range of a hero that has the "level-up rate" upgrade.

### F6. Business model — S4 [verified]

- **Paid items are sold through the creator (PayPal, then manual grant):**
  - golden skins and portraits ($5 each, or a $20 bundle of 10);
  - "builder" skin bundles;
  - donor heroes at $5, $20 and $30.
- No power items, talent points or kills are sold.
- Unity is described as "greater emphasis on hero progression rather than evolution or upgrades" [S1].

### F7. Player sentiment

**Most-viewed topics** (S6 titles and view counts):
- "Kill Farming and Talent Points Explained" (16k views);
- "Everything you need to know" (18k);
- "Tips n Tricks" (16k);
- "Starting 100% Fresh" (7k);
- "How to Prestige the RIGHT way" (7k);
- "I maxed out the advanced Marine" (7k).

**What gets praised and shown off:**
- **Maxing a hero is a content event:** "maxed out", "1-shotting bosses", "is it worth 200,000 kills?" (that title suggests some unlocks or upgrades are bought with kills: [inferred]).
- **Solo world-record speedruns** of a difficulty tier ("Solo T3 Speedrun 20:22").
- **Solo + AI challenge runs.** Videos are titled "Solo + 5 AIs", so ZW lets AI teammates fill challenge lobbies.

**Complaints:**
- **Lost saves.** Six Blizzard forum threads from 2020–2023 report all kills and TP gone after a power cut, a reinstall or a new PC (S7). The community runs a recovery service (S3).
- **Class balance inside a ladder blocks progress.** "Splash class has a bad progression because of the state Siege Tank and Reaver has been [in] for a long time" (S6, video `S_-I65SZfcQ` snippet).
- **Big patches change the meta.** "Huge Update Explained! Is The Game Worse??" (S6). "As of Feb 2025, this video is somewhat outdated due to changes in the map layout" (S6).

**Strategy notes from players:**
- The first 2–5 minutes of a guide are "initial maze farming" before the first purchases (S6 snippets with chapter times: "Attack Speed bought 02:05", "Hero Buff 1 bought 03:37", "Wave 20 05:30").
- In Liberty, players **send minerals to a teammate** ("one person collects tech and the other sends him minerals", S6 `rQx_xfZ9dAA`).
- Gating by power: "you need tank min P3", "5 asc" (S6 snippets).

## Comparison: our game and V5 vs. Zombie World

| Topic | Zombie World | Ours (files) | Gap |
|---|---|---|---|
| Lifetime kill counter | per class/role; unlocks a 6-tier ladder up to ~1M | none: `ProfileSchema.stats` has no `kills` field; V5 B2 plans `stomps` | V5's veteran seed reads `stats.kills`, which does not exist |
| Unlocks | class kills (and combo multi-class) | cheese: `Config/Classes` unlockCost 0/0/0/2500/2500/4000/4000 | V5 lists 6 thresholds for 4 locked classes |
| Talents | **account-wide**, 20 talents, big ranks (Damage 100 ranks), Prestige gate | account Talents (cheese, 8 × 4–5 levels, `Config/Talents`); V5 adds a **per-class** board with 10 × 50 ranks | per-class split is 7× slower and punishes trying classes |
| TP income curve | ~170× spread by difficulty, escalating miniboss TP, completion bonus | V5: flat 1–5 per event, ×(1+0.1P) | too flat to drive Pressure climbing |
| Jewels | 14 tiers tied to difficulty, 5 rolled stats + unique perk, dust, upgrade, 200 slots | V5 charms: flat rarity weights, fixed values, fuse 3→1, 60 slots | no link between charm quality and Pressure |
| Run economy | minerals: repeatable upgrades; vespene: buffs; late store 30× a buff | V5 A1–A5 | V5's rind-income assumption looks about 5× too high (Z-1) |
| Challenges | 8–30 restricted-roster modes, one-time big rewards, AI allowed | none | missing system |
| Team play | XP range share; mineral sending; lane split; kill split was an anti-pattern | squads, revive, shared XP planned | no resource gifting, no group bonus |
| Saves | local bank, lost often (top complaint) | DataStore + session lock + receipts | a v7 migration risk window; no backup snapshot |

## Improvement entries

Format per `docs/ITERATIONS.md`. Impact H/M/L, effort S/M/L. "V5" marks a refinement of `docs/V5-PLAN.md`.

### Z-1 (V5) Rebase the run economy: rind income is about 5× lower than V5 assumes
- **Type:** balance
- **Evidence:**
  - V5 A2 says "a good run earns about 8–15k" rinds, and A1 pays 1 rind per mouse.
  - Spawning (`src/shared/Combat/WaveDirector.luau`: `PER_HERO_RATE` 0.6/s ramping ×3.2 over the 150 s wave in `Config/Storm.REFERENCE_WAVE`) gives about 1.26 spawns/s per hero, so about 190 mice per hero per stage. A full 4-stage run is about 750–1,100 kills, and a median run (stage 2–3) about 500–700.
  - With elites ×3, the 50% squad share and the ×(1+0.25(stage−1)) stage multiplier, plus champions and the boss, that is roughly **1.5–2.5k rinds per full run**, not 8–15k (desk estimate; M2 must measure it in `tests/sim`).
  - At that income the Altar (6,000 rinds, A4) is unreachable, and ranks stall at about 5 per stat.
  - ZW prices its late store at 30× a buff, so it really is late game but still reachable (S3).
- **Impact:** H. **Effort:** S.
- **Proposed change:**
  - Multiply rind drops ×5: normal 5, elite 15, champion 200, boss 750 (split rules unchanged). Bigger numbers also read better (ZW uses 150,000-scale prices).
  - Keep rank costs.
  - Add a sim guard in `IntegrationSquads`: the human stand-in's median rinds per full run are 8–15k, and by stage 3 they are 4–7k.
  - Altar: keep 6,000 rinds, raise to 800 whey. Target: 20–40% of humans reaching stage 3 buy one.

### Z-2 (V5) Make the Herd Talent Board account-wide, not per class
- **Type:** feature / balance
- **Evidence:**
  - Unity saves talents once per account (`TP` section, F1). Only kills are per class.
  - V5 B1 makes 10 × 50-rank talents per class: 1,200 points per class, at about 6 points per run. That is 200 runs per class and 1,400 runs for all 7 classes.
  - It also punishes switching classes, which Unity rewards through combo unlocks (F3).
- **Impact:** H. **Effort:** S (it is still unbuilt).
- **Proposed change:**
  - Profile v7: `herdTalents = {points, spent, ranks = {[id]=n}}` at account level, instead of `classes[id].talentPoints/talents`.
  - Per-class identity comes from Evolutions (B2) and Z-11.
  - Keep the cost curve 1/2/3 per rank.
  - Raise the earn rate (Z-3) so the first talent maxes in about 15 runs and the whole board in about 250 runs.

### Z-3 (V5) Inflate and steepen talent-point income (Pressure must matter)
- **Type:** balance
- **Evidence:**
  - Unity pays 13 TP on Easy up to 2,250 + 5,000 TP on Torment III (about 170×). Its Damage talent costs 100 TP per point (F4).
  - V5 B1 pays +1 to +5 per event, ×(1 + 0.1·Pressure): at most ×3.1 at P21 (`Config/Pressure` `MAX_POINTS` 21).
  - HANDOFF §5 already says "the Pressure board barely separates".
- **Impact:** H. **Effort:** S.
- **Proposed change:**
  - Show all TP values ×10, so ranks cost 10/20/30. The numbers feel bigger, and nothing else changes.
  - Sources:

    | Source | TP |
    |---|---|
    | Boss | 30 |
    | Champion | Z-4 |
    | Stage cleared alive | 10 |
    | Extraction | 20 |
    | Win | 50 |

  - Multiplier: **1 + 0.2·P** (P21 → ×5.2).
  - **Full-clear completion bonus** by Pressure band: P0–4 = 100, P5–9 = 250, P10–14 = 500, P15–19 = 900, P20–21 = 1,500. It pays **once per band per class per week**, so it can't be farmed.
  - First-of-day ×2 up to 100.

### Z-4 (V5) Escalating champion talent points within a match
- **Type:** feature / balance
- **Evidence:**
  - Unity's corner minibosses pay 8 TP, +8 per consecutive kill in the same game, capped at 160. Players call them "the best TP source" (F4).
  - HANDOFF §5: champion kills are 1.4–1.6 per stage against a target of 2+.
  - V5 B1 pays a flat +1.
- **Impact:** M. **Effort:** S.
- **Proposed change:**
  - The n-th champion a squad kills in a match pays **10·n TP** (Z-3 scale), capped at 60 per kill, to participating members.
  - Show it in the champion marker tooltip ("next: +40 TP").

### Z-5 (V5) Fix the free-unlock thresholds (4 locked classes, not 6) and add a combo unlock
- **Type:** bug (plan)
- **Evidence:**
  - V5 B2 lists 1,000 / 5,000 / 12,500 / 25,000 / 50,000 / 100,000 "for each locked class".
  - `Config/Classes.luau` has only 4 locked classes: le_fante 2500, filet 2500, jumbo 4000, fizzante 4000.
  - Unity also has a combo hero that needs kills in several classes (F3).
- **Impact:** M. **Effort:** S.
- **Proposed change:**

  | Class | Free unlock |
  |---|---|
  | le_fante | 3,000 account stomps |
  | filet | 8,000 account stomps |
  | jumbo | 4,000 stomps on elephante + 4,000 on any other free class ("combo") |
  | fizzante | 6,000 stomps on ele_fonte + 6,000 on ellie_fawn |

  - Cheese purchase stays.
  - The class card shows a progress bar for each requirement.

### Z-6 (V5) Seed veteran stomps from data that exists
- **Type:** bug (plan)
- **Evidence:**
  - V5 B4: "start stomps at `stats.kills` if that field exists, otherwise 0".
  - `src/shared/Data/ProfileSchema.luau` `stats` has no `kills` (runs, wins, bossesKilled, heroDowns, lastHerd, extractions, bestStage, championKills only). So every veteran would start at 0, which would be a visible "wipe" in a live game.
  - Lost progress is ZW's top complaint (S7).
- **Impact:** H. **Effort:** S.
- **Proposed change:**
  - In the v7 migration: `classes[id].stomps = floor(1.2 × lifetime class XP)`, where lifetime XP = the sum of `xpToNext` up to `level` + `xp` + `starXp`. Class XP is about 400–600 per run (`ClassProgress.RUN_XP`), against about 500–700 kills per run.
  - Then set `stats.stomps` to the sum over classes.
  - Show a one-time "Your herd remembers: N stomps" toast.

### Z-7 (V5) Tie charm quality to Pressure, with rolled stats (the jewel model)
- **Type:** feature
- **Evidence:**
  - Liberty jewels have 14 tiers named after the difficulties. Each jewel has 5 rolled stats whose range rises with the tier (1–5 at tier 1, up to 90–200 at tier 14), an optional unique perk, an upgrade level and a dust currency. The limit is 200 (F2).
  - V5 B3 uses flat weights 70/22/7/1 (Rare+ guaranteed only at stage 4) and fixed values, so playing on higher Pressure does not give better charms.
- **Impact:** H. **Effort:** M.
- **Proposed change:**
  - **Tier and rarity floor:** charm tier = Pressure band (P0–4 T1 … P20–21 T5). The tier sets the rarity floor (T3+ is at least Rare, T5 at least Epic).
  - **Rolled stats:**
    - Each charm has 1 main stat (the 12 V5 types minus Fortune, see Z-20) **rolled in a range**: C 60–100%, R, E and L ranges overlapping by 20% of the V5 values. A charm can be "a great Rare".
    - Epic+ charms add a second, smaller stat at 50% value.
    - Legendary charms add 1 of 6 **unique perks** (e.g. −8% cooldowns, slow immunity, 15% chance of a double hit vs mice). PvE only.
  - **Charm Dust:** salvage gives dust (C 5 / R 20 / E 80 / L 300). Dust upgrades a charm +1 level, up to +5, at +6% of its value per level.
  - Fuse stays.
  - Inventory 100.
  - Never sold, never rerolled for Robux (unchanged).

### Z-8 Herd Trials (challenge modes with restricted rosters)
- **Type:** feature
- **Evidence:**
  - Unity has 8 challenges and Liberty saves 30 challenge flags (F1, F2). They are restricted-roster or rule-twist runs with big one-time rewards, often run "Solo + AI" (S6).
  - They are a large share of current ZW videos (Blackout, Runaway, Champion Only, Warp Speed, Next-to-Dead in 2025–2026).
  - We have no equivalent. Our lobbies are bot-filled (HANDOFF rule 4), so a trial never needs a full human lobby.
- **Impact:** H (veteran retention). **Effort:** M–L.
- **Proposed change:**
  - 6 trials at launch, chosen from the lobby board as a "Trial" preset (private squad + 🤖 bots):
    1. Thin Skin: 1 max HP, +50% start rinds;
    2. Herd of Two: only 2 named classes;
    3. Champions Only: no normal mice, 2× champions;
    4. Blackout: tiny light radius;
    5. Rush: ×1.6 game speed;
    6. No Shops: stalls and Altar off.
  - **One-time reward per trial:** 300–750 TP (Z-3 scale), a title, a nameplate badge and an Evolution colour variant.
  - **Repeat clears:** ×2 stomps for that match, once per week.
  - Track trials in `achievements` (no new store).

### Z-9 Gift rinds to a squadmate
- **Type:** feature (team play)
- **Evidence:**
  - Liberty players run a "one collects, the other sends minerals" strategy (S6 `rQx_xfZ9dAA`). In the original, a support/leveler role existed (S2).
  - V5 A1 rinds are personal, with no way to help a squadmate who died or plays a rind-hungry build.
- **Impact:** M. **Effort:** S.
- **Proposed change:**
  - New C2S `GiftRinds(targetId, amount)`, same squad only, no fee.
  - Limits: at most 50% of your current balance per gift, a 10 s cooldown, and no gifts during the boss.
  - The receiver gets a toast. A "Generous Herd" award goes on Results.
  - Bots can receive and spend (they buy ranks by script) but never send.

### Z-10 (V5) Reward grouping explicitly (avoid ZW's "solo is optimal")
- **Type:** balance
- **Evidence:**
  - The original split kills 1/N, and the creator recommended solo farming (S2).
  - V5 keeps kills unsplit (good) but adds nothing for grouping, while squads of strangers are our core loop.
- **Impact:** M. **Effort:** S.
- **Proposed change:**
  - **Herd Bonus:** +10% stomps and TP per *other human* in your squad at match end (max +30%).
  - +5% more if any of them is a Roblox friend.
  - Bots do not count, which also blocks farming with bots.

### Z-11 (V5) Class-specific rank lines in the upgrade menu
- **Type:** feature
- **Evidence:**
  - ZW upgrade menus are per hero, with researches priced in both currencies (e.g. a kiting upgrade at 2,500 minerals + 350 vespene: [wiki-snippet] Ghost page). The tutorial video shows hero-specific stat upgrades (S2).
  - V5 A2 has only 8 generic ranks plus one Class Stall buff, so every class's V menu is identical.
- **Impact:** M. **Effort:** M.
- **Proposed change:**
  - Add 2 class lines per class to `Config/RunShop` (10 ranks each), costing `ceil(40·1.18^rank)` rinds + 10 whey per rank from rank 5.
  - Examples: ability radius +4%/rank; ability damage +6%/rank; signature +1 (e.g. one extra orbiting cleaver at rank 5 and 10, +1 projectile at 10).
  - PvP effect ×0.5.

### Z-12 Head-start talents (start rinds and whey) on the board
- **Type:** feature / UX
- **Evidence:**
  - Unity talents include starting minerals (5,000 ranks) and starting vespene (500) (F1). ZW guides spend the first 2–5 minutes on "initial maze farming" (S6).
  - HANDOFF reports about 30% human idle time, and stage 1 of every run starts from zero.
- **Impact:** M. **Effort:** S.
- **Proposed change:**
  - Herd board (Z-2) talents:
    - "Packed Lunch": +20 start rinds per rank, 20 ranks (+400);
    - "Canteen": +5 start whey per rank, 10 ranks (+50).
  - Small enough not to decide PvP, since 400 rinds buys about 3 low ranks.

### Z-13 Cut the herd-talent list down to what matters, and add cooldown and redeploy
- **Type:** balance (V5)
- **Evidence:**
  - Unity's talent set is combat-heavy: cooldown 25 ranks, damage reduction 10, respawn speed 20 (−1 s each), XP 100 (F1, F4).
  - V5 B1 spends 3 of 10 slots on economy (Fortune, Scavenger, Alchemy). Fortune overlaps the account talent "Cheese Nose" (`Config/Talents.luau`) and the M11 cheese cap (`docs/MONETIZATION.md`).
- **Impact:** M. **Effort:** S.
- **Proposed change:**
  - Final list (12):
    - Brawn, Bulk, Guard, Vigor, Haste, Fleet, Insight, Scavenger (as in V5);
    - **Focus**: −0.2% cooldown per rank, 25 ranks;
    - **Homing Call**: −0.15 s redeploy per rank, 20 ranks (−3 s; redeploy is 20–35 s in V4);
    - Packed Lunch and Canteen (Z-12).
  - **Cut Fortune.**
  - Alchemy is folded into Scavenger (+0.8% rinds and whey).

### Z-14 Prestige gate: a capstone talent after the board is full
- **Type:** feature
- **Evidence:**
  - Unity's Prestige talent opens only when every other talent except Mastery is maxed (F4). Liberty saves per-hero prestige (the editor's sample values are 5–20; the cap is 99) and 8 ascension nodes (F2).
  - "How to Prestige the RIGHT way" has 7k views (S6).
  - V5 gives no end goal after the board is full.
- **Impact:** M (long tail). **Effort:** M.
- **Proposed change:**
  - When all board talents except Insight are maxed, unlock **Herd Prestige**: each prestige costs 1,000 TP (Z-3 scale) and gives +1% PvE damage and +1% max HP, with no cap.
  - It also shows a prestige numeral on the nameplate, and every 5th prestige gives a cosmetic frame.
  - It is never refundable.
  - Later (iter 2–3): 8 per-class ascension nodes from Mastery Stars (one per 3 stars), each a choice of 2 ability sidegrades (VFX + small PvE numbers).

### Z-15 (V5) Win multiplier on match stomps
- **Type:** balance
- **Evidence:**
  - Unity multiplies the kills earned in a game by the difficulty's win multiplier: ×1 (Normal) up to ×70 (Torment III). Challenge wins give ×2 to ×6.25 (F4).
  - V5 B2 only applies ×(1+0.05P) and pays nothing for a good finish, so a stage-1 wipe and a full clear give the same stomps per kill.
- **Impact:** M. **Effort:** S.
- **Proposed change:** match stomps × outcome × (1 + 0.1·P).
  - Outcome: eliminated ×1, extracted ×1.5, Last Herd or full clear ×2.
  - P21 is then up to ×6.2.
  - Show it on Results as "Stomps 640 × 1.5 × 2.1 = 2,016".

### Z-16 (V5) Steeper Evolution ladder and more steps
- **Type:** balance
- **Evidence:**
  - Unity's class ladder spans about ×50 (T2 10–25k → T6 0.67–1.25M), and its bank has about 9–10 upgrade steps per hero line (F1, F3).
  - V5 B2 has 3 thresholds (2,500 / 15,000 / 60,000; ×24). With Z-15 multipliers and about 600 kills per run, stage 4 arrives after about 50–60 runs, after which there is nothing left to chase.
- **Impact:** M. **Effort:** S (data) + G art.
- **Proposed change:**
  - Keep the 4 looks.
  - Add **stage 5 at 250,000** (aura and trail, no stat).
  - Add **"stars" within each stage**: every 20% of the way to the next stage shows a pip. That is 4 pips per stage, so progress is visible every 2–3 runs.
  - Thresholds: 2,500 / 15,000 / 60,000 / 250,000.

### Z-17 Save safety for the v7 migration (ZW's top complaint)
- **Type:** feature (live safety)
- **Evidence:**
  - Six public forum threads report lost kills and TP (S7). ZW runs a manual recovery service (S3).
  - v7 adds the largest saved data yet (charms inventory, talents, stomps). A bad migration or an exploit-driven charm dupe would be hard to roll back.
- **Impact:** H. **Effort:** M.
- **Proposed change:**
  - Before the first v7 write, copy the raw v6 profile to a `backup_v6/<userId>` key (once).
  - Add an admin-only `RestoreProfile` server command (Studio/console, not a remote).
  - Bound the charm inventory and log charm grants (count per day) for dupe detection.

### Z-18 Map secret: one-time hidden relics per map
- **Type:** feature
- **Evidence:**
  - Unity hides a crystal worth 10 TP (F4). Discovery content gets made into videos.
  - We have rare POIs (Pantry about 3%, Statue about 2%: HANDOFF) but nothing permanent to find per map.
- **Impact:** L. **Effort:** S.
- **Proposed change:**
  - One hidden relic per map (9 maps), placed off-path by ArenaBuilder.
  - The first touch per account gives 50 TP (Z-3 scale) and a Mousepedia entry.
  - A "Relic Hunter" achievement for all 9.

### Z-19 Call the Horde: an optional early-wave lure to cut idle time
- **Type:** UX / balance
- **Evidence:**
  - Liberty saves a "Skip Wave At" setting (default 125, F2), so even ZW lets veterans skip slack.
  - HANDOFF: humans are idle about 30% of stages 3–4.
- **Impact:** M. **Effort:** M.
- **Proposed change:**
  - Each squad gets a Lure Horn, once per 60 s, only when fewer than 8 mice are within 48 studs.
  - It spawns a ring of `6 + 2·stage` mice around the squad, worth +50% rinds and stomps.
  - Bots use it too.
  - It does not move the storm timer, so other squads are not affected.

### Z-20 (V5) Cut or merge systems to keep v5 shippable
- **Type:** feature (scope)
- **Evidence:**
  - V5 adds about 11 systems at once.
  - ZW's own creator says Unity puts "greater emphasis on hero progression rather than evolution or upgrades" (S1). It slimmed down rather than stacking systems.
  - Boost zones duplicate the Power Totem capture logic. Up to 3 totems already spawn per stage (`Config/Pois.luau`, v3 note).
- **Impact:** H (delivery risk). **Effort:** S.
- **Proposed change:**
  - **(a)** Drop the 3 new boost-zone models. Instead give the existing Totems a random boost type (rind / whey / XP) on top of their damage buff.
  - **(b)** Swap Stand: rinds → whey only (10:1 with no fee), not both ways.
  - **(c)** Drop the charms Fortune and Luck (they touch cheese and loot, both monetization-adjacent). That leaves 10 charm types.
  - **(d)** Ship the Talent Board, Stomps and Evolutions first (P). Charms can follow in iter 2 if P is late.

### Z-21 Milestone broadcasts and the "maxed" moment
- **Type:** UX
- **Evidence:** "I maxed out the advanced Marine" (7k views), "maxed out the most expensive champion" and "1-shotting bosses" (S6). Maxing is the social payoff in ZW.
- **Impact:** M. **Effort:** S.
- **Proposed change:**
  - Server-wide kill-feed line and lobby toast when a player reaches Evolution 3/4/5, maxes a talent, completes a Trial, or gets a Legendary charm.
  - Results gets a "New milestone" card with a Share button (existing Share flow).

### Z-22 Fastest-clear leaderboard per Pressure band
- **Type:** feature
- **Evidence:**
  - "SOLO T3 Speedrun (20:22) world record" and "Torment 3 Speedrun" videos (S6).
  - Liberty saves "Best Solo" difficulty (F2).
  - Our profile has a legacy `fastestCycle1` (`ProfileSchema.luau`) but no live board. HANDOFF lists "per-Pressure leaderboard" as an open Minor.
- **Impact:** L. **Effort:** M.
- **Proposed change:**
  - Record the fastest full 4-stage clear for P0–9, P10–19 and P20+, plus a "best Pressure cleared with ≤1 human" record.
  - Two OrderedDataStore boards on the lobby wall.

### Z-23 Class-balance watch per ladder (avoid a "dead class" progression)
- **Type:** balance (process)
- **Evidence:**
  - A ZW player says one class "has a bad progression because of the state [two heroes] have been [in] for a long time" (S6).
  - With Evolutions and per-class stomps, a weak class becomes a slow ladder too.
- **Impact:** M. **Effort:** S.
- **Proposed change:**
  - Add a sim report: stomps per minute by class (7 classes × 24 seeds) in `tests/sim`.
  - Any class below 80% of the median gets +10% stomp gain (`Config/Evolutions.classStompMult`) until it is rebalanced.
  - Shown honestly in the class card ("Underdog: +10% stomps").

### Z-24 (V5) Lower the whey-stall price and add a second class buff tier
- **Type:** balance
- **Evidence:**
  - Unity: each buff costs 500 vespene, and 2 class-specific buffs cost 1,000 each (S3).
  - V5 has 1 class buff (500) and 8 generic buffs at 250.
  - Whey income by our estimate: POIs 6–10 × 40, champions about 6 × 30–60, stages 4 × 50, and rinds/25 (1–2.5k before Z-1) is about 1,000–1,400 per full run. After Z-1 the rinds/25 term grows ×5, so whey must be rebased too.
- **Impact:** M. **Effort:** S.
- **Proposed change:**
  - After Z-1, change the whey trickle to **+1 per 100 rinds** (not 25), so whey stays scarce.
  - Stall buffs stay at 250.
  - **2 class buffs:** tier I 500, tier II 1,000 (needs I; e.g. tier II is the "+1 projectile" kind).
  - Sim target: a median full-run human buys 3–4 stall buffs and class buff I.

### Z-25 Shrine gamble gains a talent-point outcome (no Robux)
- **Type:** feature
- **Evidence:**
  - Unity's Ancient Shrine: 3 uses per game, about 60% nothing, solo or team TP gifts, and risky bad outcomes (F4).
  - We already have the Witch's Hut (`Config/Pois.luau` `witch_hut`), which Robux never touch (HANDOFF rule 3).
- **Impact:** L. **Effort:** S.
- **Proposed change:**
  - Add 2 outcomes to the Witch roll table: "+40 TP to you" (8%) and "+20 TP to your squad" (5%).
  - It stays free and cannot be rerolled for Robux.

## Ranking (impact ÷ effort, for the verification team)

1. Z-1 economy rebase (H/S)
2. Z-6 veteran stomp seed (H/S)
3. Z-2 account-wide talents (H/S)
4. Z-3 steeper TP (H/S)
5. Z-20 scope cuts (H/S)
6. Z-5 unlock thresholds (M/S)
7. Z-15 win multiplier (M/S)
8. Z-4 escalating champion TP (M/S)
9. Z-10 herd bonus (M/S)
10. Z-9 gift rinds (M/S)
11. Z-24 whey/class buffs (M/S)
12. Z-13 talent list (M/S)
13. Z-12 head start (M/S)
14. Z-21 broadcasts (M/S)
15. Z-23 class watch (M/S)
16. Z-16 evolution ladder (M/S)
17. Z-7 charm tiers (H/M)
18. Z-17 save safety (H/M)
19. Z-8 trials (H/M–L)
20. Z-11 class rank lines (M/M)
21. Z-14 prestige (M/M)
22. Z-19 lure horn (M/M)
23. Z-18 relics (L/S)
24. Z-25 witch TP (L/S)
25. Z-22 speed boards (L/M)
