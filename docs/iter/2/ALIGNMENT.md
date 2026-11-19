# Iteration 2: Liberty alignment audit (2026-11-19)

**Team:** Liberty Alignment Audit. We were read-only on `src/`, and this file is our only output.

**Owner direction:** "a sort of Zombie World Liberty that plays on a larger map with additional objectives and PvP, plus the other features from the original outline". We were asked to go through every feature, especially **progression and gameplay**.

**Reference:** `docs/research/zwl-save-model.md` (the decoded Liberty save). Liberty's model is:
- per hero: **kills → level → prestige → 8-node ascension**;
- an **11-tier named difficulty ladder**, with **Best Solo** recorded;
- **jewels**: the tier comes from the difficulty they dropped on, 5 rolled stats, a unique perk, an upgrade level paid in dust, and they are team-wide;
- **minerals → upgrade menu**;
- **Skip Wave At**;
- **30 challenges**;
- wave-survival pacing.

Owners follow the `docs/V4-PLAN.md` table: **M1** combat, **M2** match flow, **P** progression, **U** UI, **G** graphics and audio. Effort scale: **S** ≤ 1 day, **M** 2–4 days, **L** a week or more.

---

## 0. Two facts that shape everything

1. **The live game is profile v6.**
   - `origin/main` has `ProfileSchema.VERSION = 6`. Profile v7 (Herd Talent Board, charms, stomps, evolutions) exists only on `claude/focused-gates-jihpzi` and has **never reached a player**.
   - So the v5 systems that conflict with Liberty (the Herd Talent Board, Evolutions and Charms) can be **reshaped or cut before they ship, at zero migration cost**.
   - The only live data that needs converting is v6:
     - Mastery Stars;
     - `pressure.highestCleared`;
     - class levels and perks;
     - account Talents (cheese).
   - To be safe either way, every conversion below is written as a **v7 → v8 step**: the existing v6 → v7 step stays as it is, and v8 converts whatever v7 holds. This also covers Studio or test saves that are already at v7.
2. **We currently have six separate permanent stat layers:**

   | Layer | Live? | Currency |
   |---|---|---|
   | account Talents | live | cheese |
   | class Perks | live | class level |
   | Mastery Stars | live | class XP past level 30 |
   | Herd Talent Board | branch only | TP |
   | Evolutions | branch only | stomps |
   | Charms | branch only | drops |

   - Three more sit beside them: Pressure records, account level and achievements.
   - Liberty has three per-hero tracks (level, prestige, ascension) plus one team layer (jewels). A player can't hold nine layers in their head.
   - The target model below collapses them to **four power layers**, plus a frozen cheese sink and the cosmetic and currency meta.

---

## (1) Target model: one page

**The sentence a new player hears:** *"Survive 20 waves of mice on a shrinking map with your herd, spend rinds on upgrades between waves, beat the boss every fifth wave, and climb the cheese difficulty ladder to earn better Gems for your whole squad, while each elephant levels, prestiges and ascends from the mice it stomps."*

### In the match (resets every run)

| # | Layer (our name) | Liberty term | One sentence for the player |
|---|---|---|---|
| R1 | **Waves** (20 per match, 5 per stage; waves 5/10/15/20 are boss waves) | numbered waves, Skip Wave At | "Mice come in numbered waves; every 5th wave is a boss, and the **Early Horn** calls the next wave as soon as enough of this one is stomped." |
| R2 | **Rinds → Upgrade menu (V)** | minerals → hero upgrades | "Every mouse drops rinds; press V between waves to buy stat ranks that last the whole match." |
| R3 | **Whey → Stalls, Class Stall, Big Cheese Altar** | vespene buffs, class buffs, late-game store | "Objectives pay whey for powerful stall and Altar buffs, but you lose them when you are knocked out." |
| R4 | **Level-up cards and run gear** (ours, from the outline) | in-round hero level | "Crumbs level your elephant during the match; each level offers a big upgrade card, and champions and POIs drop gear." |
| R5 | **Route cards, Double or Nothing, the Rind Gate** (ours, from the outline) | — | "After each boss, the winning squad picks the next route, any squad can bet its pot on Double or Nothing, and any squad may extract." |

### Saved per elephant (each class is a "hero")

| # | Layer | Liberty term | One sentence |
|---|---|---|---|
| H1 | **Stomps** (per class and in total) | kills (`H<i>K`, `Primary`) | "Every mouse your elephant stomps counts forever." |
| H2 | **Class level 1–30** (perks and alternate abilities) | hero level (`L`) | "Stomps and match results level your elephant, and each level is a perk point." |
| H3 | **Prestige P0–99** (replaces Mastery Stars) | prestige (`P`) | "At level 30, Prestige: your level number restarts at 1 for a permanent star, a perk point and a small bonus; you keep every perk, ability and skin." |
| H4 | **Ascension, 8 nodes** (replaces Evolutions) | ascension (`A`, 8 bits) | "Prestige milestones plus class stomps unlock 8 ascension nodes in order: big class-defining upgrades, with the Bull, Matriarch and Ancient looks at nodes 2, 4 and 8." |

### Saved per account

| # | Layer | Liberty term | One sentence |
|---|---|---|---|
| A1 | **Difficulty ladder** (11 named cheeses; Pressure becomes "Custom") | 11 difficulties plus Best Solo | "Pick one of 11 difficulties; clearing one unlocks the next, and your Best Solo and Best Squad are recorded." |
| A2 | **Cheese Gems and Crumb Dust** (replaces Charms) | jewels plus jewel dust | "Bosses and clears drop Gems whose tier is the difficulty you beat. Each has 5 rolled stats and maybe a unique perk, and the gems you equip boost your whole squad. Salvage gems into Crumb Dust to upgrade the keepers." |
| A3 | **Challenges (30)** | 30 challenges (`CLHistory`) | "30 hard, one-time feats that pay titles, gems and dust; finishing all 30 earns the Wheel frame." |
| A4 | **Cheese and Golden Cheese** (class unlocks, Herd Upgrades, cosmetics) | — (ours) | "Cheese buys classes, small Herd Upgrades and cosmetics; Golden Cheese buys cosmetics." |
| A5 | **Account level, Herd Pass, Contracts, Achievements, Mousepedia** | — (ours) | "Everything you do also fills your account level, the Herd Pass and your contracts, which pay currency and cosmetics, never stats. Account level opens gem sockets." |

### What disappears or merges

- **Herd Talent Board:** cut before it ships. Its job (a long tail of account power) goes to Gems and Prestige.
- **Evolutions:** merged into Ascension.
- **Charms:** become Gems.
- **Mastery Stars:** become Prestige.
- **Pressure board:** becomes the content of the difficulty tiers, plus an advanced "Custom" mode.
- **Account Talents:** frozen and renamed **Herd Upgrades**, a cheese sink.
- **v5 A7 "level buffs":** cut (never built).

---

## (2) Per-system table

**Verdict:** **K** keep · **C** change · **M** merge · **X** cut.

**Migration:**
- "none" means no saved data is touched.
- "v8" means an additive step in `ProfileSchema` (P owns it).
- No old field is deleted in the release that converts it; it stays read-only for one release so we can roll back.

### 2a. Progression

#### Class level 1–30
- **Verdict:** C. **Owner:** P. **Effort:** S.
- **How close to Liberty:** close; Liberty saves hero level.
- **Change: level from kills.**
  - Class XP gets **+0.5 per stomp** with no cap. Today it is +1 per 10 mice, capped at 30 (`RUN_XP.perTenMice` / `maxMiceXp`).
  - XP is × the **tier multiplier** (A1 table).
  - The champion XP escalates within a match: the n-th champion your squad kills pays **50·n** class XP (cap 250). This replaces Z-4's escalating talent points.
- **Change: a gentler curve.** `xpToNext = floor(70·l^1.35)` brings the total to level 30 from 140k down to **85k XP**.
- **Why:** a typical Medium run (about 600 stomps) then pays about 700–900 XP, so level 30 takes about 100–120 runs, and about 40 at higher tiers.
- **Migration (v8):**
  - Recompute each class's level from its lifetime XP (`ClassProgress.totalXpFor(level) + xp`) on the new curve, **upward only**: never lower a level.
  - The extra perk points simply appear.
  - Show a toast: "Your elephants grew: Elephante 14 → 16".

#### Perks (3 branches × 5 tiers)
- **Verdict:** K. **Owner:** P. **Effort:** S.
- **How close to Liberty:** fills the role of Liberty's level stats.
- **Keep.** Prestige adds **+1 perk point per Prestige up to P16**, so the 45-point tree is full at P16. P1 is today's "first star gives the 30th point", unchanged.
- **Migration:** none (the points are derived).

#### Alternate abilities (levels 5 and 15)
- **Verdict:** K. **Owner:** P.
- **Keep.** They stay unlocked by the highest level ever reached (Prestige never takes them away).
- **Migration:** none.

#### Mastery Stars → Prestige
- **Verdict:** C. **Owners:** P, U. **Effort:** M.
- **How close to Liberty:** today, stars count up after 30 with no reset. Liberty prestige resets the level.
- **The Prestige action:** at level 30 a **Prestige** button appears.
  - `prestige` +1 (cap 99).
  - The **displayed level** (`plevel`) restarts at 1 and re-climbs to 30 on a Prestige curve whose total is 12,000 XP, the same as one star today. That is about 15 runs, with a level-up popup roughly every half run.
  - Unlocks use the stored `level`, which stays 30, so **nothing is lost**.
  - You must reach 30 again before the next Prestige.
- **Each Prestige gives:**
  - +0.5% PvE damage and +0.25% max HP per P, up to P40 (+20% / +10%);
  - +1 perk point up to P16;
  - the existing `STAR_REWARD` (300 cheese and 10 Golden Cheese);
  - a star frame on the nameplate at P1/5/10/20/40/70/99.
- **Migration (v8):**
  - `prestige = stars`.
  - `plevel = 1 + floor(29·starXp/12000)`, with its XP carried.
  - `prestigePaid = stars`, so star rewards are never paid twice.
  - Keep `stars` and `starXp` read-only for one release.
  - Achievement `stars` reads `prestige`.

#### Evolutions (stomps 2.5k/15k/60k; small bonuses) → Ascension
- **Verdict:** M. **Owners:** P (data), M1 (behaviours), G (looks), U (panel). **Effort:** L.
- **How close to Liberty:** this is Unity's stage model. Liberty has **8 ascension nodes per hero**.
- **The change: 8 nodes per class, unlocked in order.** Each node needs a Prestige milestone **and** class stomps.

  | Node | Prestige needed | Class stomps needed |
  |---|---|---|
  | 1 | P1 | 5k |
  | 2 | P3 | 10k |
  | 3 | P5 | 20k |
  | 4 | P8 | 35k |
  | 5 | P12 | 60k |
  | 6 | P16 | 90k |
  | 7 | P20 | 130k |
  | 8 | P25 | 200k |

- **Node template** (class flavour per node; M1 writes the 7 × 8 table):
  1. +8% max HP.
  2. **Bull look**, and the ability gets +20% area.
  3. Weapon +1 projectile / pierce / arc.
  4. **Matriarch look**, and the passive is doubled.
  5. The ability leaves a second effect.
  6. −10% cooldowns.
  7. The class's Class-Stall buff at half strength, permanently.
  8. **Ancient look**, plus a squad aura (+5% PvE damage).
- **PvP rule:** behaviours (shape) apply in PvP. Numbers on damage are PvE-only, and HP from all meta layers is capped (see the PvP rule in §3).
- **Display:** the save holds an 8-bit `asc` string, exactly like Liberty.
- **Migration (v8):**
  - If v7 is not live: none.
  - If v7 shipped: `evo` stages already reached become **owned looks** (`ascLooks`), usable even before the node.

#### Stomps (per class and account)
- **Verdict:** K. **Owners:** P, U. **Effort:** S.
- **How close to Liberty:** this is Liberty's kills.
- **Keep (v7).**
- **Change:** use the tier multiplier instead of ×(1 + 0.05·Pressure).
- **Show the count everywhere:** nameplate "P7 · 🐾 12.5k", the class card, Results ("+640 stomps"), and the **Total Stomps** leaderboard.
- Free class unlocks by stomps stay (3k / 8k / 20k / 50k).
- **Migration:** none beyond v7. Z-6 already seeds veterans from class XP.

#### Herd Talent Board (12 talents, TP, weekly bands)
- **Verdict:** X. **Owners:** P, U. **Effort:** S.
- **How close to Liberty:** none. This is Unity's account talents. It duplicates Perks, Prestige and Gems, and it was the fourth "+% damage" layer.
- **Cut before v7 ships.** Remove the Talents tab.
- **TP sources become:**
  - boss/champion → class XP (escalating champion XP above);
  - weekly band bonus → the **weekly first clear per tier** pays one guaranteed gem at that tier.
- The good ideas move elsewhere:
  - Packed Lunch / Canteen → the gem **rinds** stat;
  - Homing Call → ascension node 6 for support classes.
- **Migration (v8, only if v7 shipped):**
  - Every TP (spent + unspent) refunds as **cheese 5/TP plus Crumb Dust 1 per 20 TP**.
  - Toast: "Talents became Gems: here is your dust".

#### Account Talents (cheese, 8 talents, about 39.7k cheese to max)
- **Verdict:** C. **Owners:** P, U. **Effort:** S.
- **How close to Liberty:** none. It is a live cheese sink, and paid cheese boosts feed it.
- **Keep, frozen.** Rename it to **Herd Upgrades**, show it only in the cheese shop, add no new talents and never raise caps.
- It stays the one cheese → power path.
- **Migration:** none (same keys).

#### Charms (10 types × 4 rarities, single stat, fuse, squad aura)
- **Verdict:** C. **Owners:** P (data), M1 (aura), M2 (drops), U, G. **Effort:** L.
- **How close to Liberty:** weak. A charm has one fixed stat, its quality is not tied to difficulty, and it has no uniques or dust.
- **The change:** replace charms with **Cheese Gems** before v7 ships. Full spec in §2c.
- **Migration (v8, only if v7 shipped):**
  - Each charm becomes a gem.
  - Gem tier = clamp(2·charmTier − 1 + (rarity − 1), 1, 11).
  - The charm's own stat rolls at the **top** of the range; the other 4 roll at the midpoint.
  - Legendary charms also get a random generic unique.
  - Each converted charm also grants `tier` Crumb Dust.
  - Equipped charms map to the same sockets.

#### Pressure board (8 modifiers, 21 points; leader sets it)
- **Verdict:** C. **Owners:** M2 (rules), P (records), U (lobby). **Effort:** M.
- **How close to Liberty:** Liberty uses named tiers; a point-buy board is not Liberty.
- **The change:** Pressure becomes the **content** of the 11 named tiers (§2c table). The leader picks a **tier**. **Custom** (advanced, unlocked after a Sharp clear) shows the board.
- **A Custom run counts as the highest tier whose preset is at or below its points.**
- `Pressure.REWARDS` is replaced by the tier reward table.
- **Migration (v8):**
  - `difficulty.cleared` = the highest tier whose preset points ≤ `pressure.highestCleared` (records count full clears only, per B1).
  - Anyone with `pressure.unlocked` gets at least Medium cleared.
  - `difficulty.unlocked = cleared + 1`.
  - Best Solo stays 0, because we can't know it; `bestSquad = cleared`.
  - `pressure.*` is kept, so Pressure achievements still work: tier presets use the same points (5 → Extra Sharp, 10 → Smoked, 15 → Stinky, 21 → Scorched).

#### Best Solo / Best Squad
- **Verdict:** C (new). **Owners:** P, M2, U. **Effort:** S.
- **How close to Liberty:** Liberty has `BS`.
- **Records:**
  - `difficulty.bestSolo` and `bestSquad`, for the account and per class.
  - **Solo** = the only human in the server (bots fill everything else).
  - Only ranked runs count (MoveGuard).
- **Leaderboards:** Best Solo (tier, then the fastest clear time).
- **Migration:** v8 adds the fields.

#### Achievements (~25 milestones)
- **Verdict:** M. **Owners:** U, P. **Effort:** S.
- **How close to Liberty:** they are passive milestones, not challenges.
- **The change:** keep the data, but show them inside the new **Challenges** tab as "Milestones".
- **Migration:** none.

#### Challenges (30)
- **Verdict:** C (new). **Owners:** P (defs and evaluation), M2 (match flags), U. **Effort:** M.
- **How close to Liberty:** Liberty has `CLHistory` ×30. The list is in §2d.
- **Migration:** v8 adds `challenges = {}`.

#### Contracts (3 daily, weekly)
- **Verdict:** K. **Owner:** P. **Effort:** S.
- **The change:** reword the pool in Liberty terms, for example "Clear Sharp or higher", "Stomp 1,500 with Filet" or "Sound the Early Horn 5 times". Keep the rules: no Robux, no friend, no Double or Nothing, no downing humans.
- **Migration:** none (the pool is redrawn the next day).

#### Herd Pass (28 days, 30 tiers)
- **Verdict:** K. **Owner:** P.
- **Keep.** It is cosmetic and currency only. Add "Crumb Dust ×5" rewards on a few free tiers.
- **Migration:** none.

#### Account level and rewards
- **Verdict:** K. **Owner:** P.
- **Keep.** The gem sockets (levels 1/10/25) carry over from charms.
- **Migration:** none.

#### Mousepedia
- **Verdict:** K. **Owner:** U.
- **Keep.** Add a **Gems page** (one entry per unique perk seen) and a **Difficulties page** (one per tier cleared).
- **Migration:** none.

#### Cheese
- **Verdict:** K. **Owner:** P.
- **Keep.** The payout scales by the tier multiplier, replacing +8% per Pressure point.
- **Migration:** none.

#### Golden Cheese
- **Verdict:** K. **Owner:** P.
- **Keep.** It is cosmetic. Gems are **never** sold, rerolled or upgraded with Robux or Golden Cheese.
- **Migration:** none.

#### Cheese shop and Robux shop
- **Verdict:** K. **Owners:** P, U.
- **Keep.** Herd Upgrades move here. No new paid items touch tiers, gems or dust.
- **Migration:** none.

#### Mastery skins (bronze/silver/gold at levels 10/20/30)
- **Verdict:** K. **Owner:** P.
- **Keep.** They go by the highest level ever reached.
- **Migration:** none.

### 2b. Gameplay

#### Waves (150 s continuous spawning per stage)
- **Verdict:** C. **Owners:** M1 (`WaveDirector`), M2 (`RunDirector`), U (HUD). **Effort:** M.
- **How close to Liberty:** Liberty has numbered escalating waves. We have one long ramp, and sim idle time is about 30%.
- **The change: each stage = 5 numbered waves.**
  - Waves 1–4 are 30 s hordes, with a 4 s lull between waves.
  - Wave 5 is the **boss wave**: the boss appears, with a light trickle of mice.
  - The match has **20 waves**. The HUD shows "Wave 7 / 20".
  - Spawn budget per wave = `PER_HERO_RATE × heroes × 30 × ramp(wave)`. The ramp now steps per wave: ×1.0 at wave 1 → ×3.2 at wave 19. In-stage HP rises +4% per wave.
  - 40% of a wave arrives in its first 6 s.
  - The storm steps start at waves 2, 3 and 4.
- **Migration:** none.

#### Early Horn (Skip Wave At)
- **Verdict:** C (new). **Owners:** M2, U, P (setting). **Effort:** S.
- **How close to Liberty:** Liberty has `skipwavethreshold`.
- **Setting:** `settings.skipWaveAt` ∈ {Off, 50, 70, 90}, meaning % of the current wave's budget stomped.
  - The default is **Off** for runs 0–2, then 70.
  - The match uses the **leader's** setting.
- **Rule:** the wave must have run at least 10 s. Then a 3 s horn warning, then the next wave starts.
- **Reward:** each skipped second gives +3 rinds per standing hero. The HUD shows a "Horn ×3" streak.
- **Contracts and Challenges** can count horns.
- **Migration:** a v8 setting default.

#### Mice and spawning
- **Verdict:** C. **Owner:** M1. **Effort:** M.
- **How close to Liberty:** Liberty spawns from edges and lanes.
- **The change:** keep hero-relative anchors, but each wave's opening burst comes as **2–3 "fronts" from the storm edge** toward the squads. "Mice pour out of the Melt" reads as a wave and pushes play to the centre. The mix unlocks by **wave number** instead of the fraction of the stage.
- **Migration:** none.

#### Champions (6 sites, 1–2 lairs)
- **Verdict:** C. **Owners:** M1, M2. **Effort:** S.
- **How close to Liberty:** these are Zombie World's corner minibosses.
- **The change:**
  - Sync them to waves: a champion at the start of waves 2 and 3, and the lair champion on wave 4.
  - Escalating **class XP** (50·n).
  - The **lair** has a 10% chance to drop a gem at tier − 1.
- **Migration:** none.

#### Bosses (13, one per stage; the final ×2.5)
- **Verdict:** K. **Owners:** M2, M1.
- **Keep** as boss waves 5, 10, 15 and 20.
- **Gem drops (top-damage squad, humans only):**

  | Boss | Gem chance at the match tier |
  |---|---|
  | Bosses 1–3 | 35% |
  | Final boss | 100% |

  - A **won Double or Nothing** on that stage doubles the chance.
  - A **High route** stage rolls the stats in the top half of the range.
- **Migration:** none.

#### POIs (24–36 slots, shrines, camps, totems, vaults, cart)
- **Verdict:** K. **Owner:** M2.
- **Keep.** These are Liberty's boost zones and sale points on a bigger map.
- **One change:** shrines also pay **+20 whey**, so every objective feeds the R3 economy.
- **Migration:** none.

#### Storm (the Melt)
- **Verdict:** C. **Owners:** M1, M2. **Effort:** S.
- **The change:** circle steps are keyed to the **wave index** instead of seconds, so the Early Horn shrinks the map with the pace. The boss squeeze stays at 90 s.
- **Migration:** none.

#### Squads and PvP (4 × 3, PvP ×0.3, time-to-kill about 20 s)
- **Verdict:** K. **Owner:** M1.
- **Keep.** This is our big extra.
- **New rule: meta never decides PvP.**
  - Meta damage (perks excepted) is PvE-only.
  - Meta max HP counts in PvP at most **+25%** in total (a `metaHpPvpCap` in World).
- **Migration:** none.

#### Extraction (the Rind Gate)
- **Verdict:** K. **Owner:** M2.
- **Keep.**
- Extracting at stage ≥ 3 on tiers 1–3 counts as a "clear" **for unlocking only** (onboarding).
- Extracting at stage ≥ 2 has a 50% chance of a gem at tier − 1.
- **Migration:** none.

#### Double or Nothing (×2 if the squad survives and kills a champion or the boss)
- **Verdict:** K. **Owner:** M2.
- **Keep.** It also ties into the gem chase: a won DoN doubles boss gem odds, and the **tier-12 Golden Wheel gem** drops only from a final boss kill on Doomwheel by a squad on a won DoN.
- Robux still never touches DoN.
- **Migration:** none.

#### Route cards (Low / Mid / High)
- **Verdict:** K. **Owner:** M2.
- **Keep** (outline).
- A High route also improves gem rolls (top half of the range).
- **Migration:** none.

#### Rinds and the V menu (8 stats × 25 ranks)
- **Verdict:** K. **Owners:** M2, U. **Effort:** S.
- **How close to Liberty:** this is Liberty's minerals and upgrade menu.
- **Keep the prices** (36.5k rinds to max everything).
- **Add:**
  - **Shift-click / long-press "buy 5"**;
  - a "V: 340 rinds" pulse during the lull between waves;
  - a guard that the cadence is 1–3 rank buys per wave.
- **Migration:** none.

#### Rind gifting (new)
- **Verdict:** C (new). **Owners:** M2, U. **Effort:** S.
- **How close to Liberty:** Liberty players "send minerals" to a teammate.
- **The change:** a "Gift 100 rinds" button on a squadmate's card, with no fee, squad only. Bots never receive gifts.
- **Migration:** none.

#### Whey, stalls and the Class Stall
- **Verdict:** K. **Owner:** M2.
- **How close to Liberty:** this is vespene buffs. Keep.
- **Migration:** none.

#### Big Cheese Altar (stage 3+, 6k rinds + 600 whey)
- **Verdict:** K. **Owner:** M2.
- **How close to Liberty:** this is the late-game store. Keep.
- **Migration:** none.

#### Swap Stand (rinds → whey, 20% fee)
- **Verdict:** K. **Owner:** M2. Keep.
- **Migration:** none.

#### Level-up cards (13–16 offers per stage)
- **Verdict:** C. **Owner:** M2. **Effort:** S.
- **The change:** offer a card every level up to level 10, then every 2 levels (P-13). The V menu now carries the small steady stats.
- **Migration:** none.

#### Run gear (3 slots, 4 rarities)
- **Verdict:** K. **Owner:** M2.
- **Keep** (GDD-v2 owner decision). It is loot, not a layer to explain.
- **Migration:** none.

#### v5 A7 level buffs (+2 HP per level, …)
- **Verdict:** X. **Owner:** (lead). **Effort:** —
- **Not built, and invisible.** Drop it from the plan.

#### Rookie protection (×0.75 damage in stage 1)
- **Verdict:** K. **Owner:** M2.
- **Keep.** Rookies also default to **Mild**.
- **Migration:** none.

### 2c. Specs for the two big new systems

#### A1. The difficulty ladder

Each tier is a **Pressure preset** (`Config/Pressure` board points, chosen by M2 so that the points match) plus a base multiplier on top for tiers 1 and 10–11.

| Tier | Ours | Liberty | Preset points | Extra base (HP / damage / spawn) | Reward × (cheese, stomps, class XP) | Gem tier |
|---|---|---|---|---|---|---|
| 1 | **Mild** | Easy | 0 | 0.7 / 0.7 / 0.85 | 0.75 | 1 |
| 2 | **Medium** | Normal | 0 | — (today's P0) | 1.0 | 2 |
| 3 | **Sharp** | Hard | 3 | — | 1.2 | 3 |
| 4 | **Extra Sharp** | Brutal | 5 | — | 1.4 | 4 |
| 5 | **Aged** | Insane | 8 | — | 1.7 | 5 |
| 6 | **Smoked** | Nightmare | 11 | — | 2.0 | 6 |
| 7 | **Pungent** | Chaotic | 14 | — | 2.4 | 7 |
| 8 | **Stinky** | Torture | 17 | — | 2.9 | 8 |
| 9 | **Scorched** | Inferno | 21 (full board) | — | 3.5 | 9 |
| 10 | **Moldy** | Torment | 21 | 1.5 / 1.25 / 1.0 | 4.2 | 10 |
| 11 | **Doomwheel** | Death | 21 | 2.2 / 1.5 / 1.2 | 5.0 | 11 (12 on a won-DoN final boss) |

**Notes:**
- **Names:** working names. U/G finalize them; they must stay cheese-themed and not copy Liberty.
- **Unlocking:** a full clear (your squad is in the run when the final boss falls, or Last Herd) unlocks the next tier.
- **Who picks:** the lobby leader (the existing `Pressure.pickLeader`) chooses among tiers **they** have unlocked.
  - Humans who haven't unlocked that tier can still play (carrying is allowed, as in Liberty), but Best Solo can't be carried.
- **Rookies:** runs 0–2 force Mild unless a non-rookie leads.
- **First weekly clear:** the first clear of each tier per UTC week pays a guaranteed gem of that tier. This replaces the TP weekly bands.
- **Balance guard (M2, new `IntegrationDifficulty` spec, 24 seeds per row):**

  | Squad | Target clear rate |
  |---|---|
  | Fresh level-1 squad on Medium | ≥ 70% |
  | Fresh level-1 squad on Sharp | ≈ 50% |
  | "P10 + three tier-6 gems" stand-in on Smoked | ≈ 50% |
  | "P40 + nodes 1–8 + 9 tier-11 gems" stand-in on Doomwheel | 30–40% |
  | Fresh squad on Doomwheel | < 2% |

#### A2. Cheese Gems (replace charms)

| Field | Spec |
|---|---|
| Tier | 1–11 = the difficulty it dropped on; 12 = Golden Wheel (Doomwheel final boss on a won DoN). |
| 5 rolled stats | Each an integer in the tier range: **Rinds**, **Bite** (PvE damage), **Hide** (max HP), **Plating** (PvE damage taken), **Stride** (move speed). |
| Tier ranges | Liberty's ranges: 1–5, 5–10, 5–20, 10–30, 15–40, 20–50, 25–60, 30–75, 35–90, 40–105, 50–125; tier 12 is 75–170. |
| Point values | Rinds 0.1% · Bite 0.05% · Hide 0.02% · Plating 0.03% · Stride 0.01%. A perfect tier-11 stat = +12.5% rinds, +6.25% PvE damage, +2.5% HP, −3.75% PvE damage taken, +1.25% speed. |
| Unique perk | Optional. The chance by tier is 2% (tier 1) → 10% (tier 6) → 25% (tier 11) → 40% (tier 12). There are 11 uniques: 7 class uniques (one per class; they apply to that class in your squad), plus Cooldowns −10%, Stride +6%, Glass Tusk (−15% HP, +20% PvE damage), Lucky Crumb (20% chance of ×2 PvE damage), and Unshakable (immune to mouse and boss slows and stuns). At most one copy of each unique per squad. |
| Upgrade | Level 0–5. Each level adds +10% to all rolled stats. Level n costs **n × tier Crumb Dust** (15 × tier in total). |
| Crumb Dust | Salvaging a gem gives `tier` dust (+`tier` if it has a unique). Challenges and a few free Herd Pass tiers also give dust. Never sold. |
| Sockets | 3, opening at account level 1 / 10 / 25 (unchanged). |
| Team-wide | Your **squad** gets the **sum** of every member's equipped gems. Bots receive the aura but carry none. Squad caps: Bite +60%, Rinds +100%, Hide +25%, Plating −30%, Stride +8%. So 3 humans with 9 gems beat 1 human with 3: team play pays off, as in Liberty. |
| Inventory | 200 (Liberty's limit). Stored compactly as `{t, s = {5 ints}, u, lv}`, about 40 bytes each, so about 8 KB. |
| Live rules | Free drops only. Never sold or rerolled for Robux or Golden Cheese. Damage is PvE-only. Hide counts toward the +25% PvP meta-HP cap. |

#### Challenges (30)

Each pays a one-time title, plus a gem at the listed tier and/or dust. **All 30** earn the "Wheel of Legends" nameplate frame. Bots count as enemy heroes. None needs Robux or a friend.

| # | Challenge | Requirement | Reward |
|---|---|---|---|
| 1–7 | **Lone Tusk: <class>** (one per class) | Clear Smoked solo with that class | tier-6 gem |
| 8 | **Bare Trunk** | Clear Sharp without buying a stat rank | 10 dust |
| 9 | **Whey Ascetic** | Clear Aged with no stall or Altar buff | tier-5 gem |
| 10 | **Unbroken** | Clear Aged without ever being knocked out | tier-5 gem |
| 11 | **Paper Elephant** | Clear Medium with the one-hit curse active all run | title |
| 12 | **Double Down** | Win Double or Nothing on 3 stages, then clear Aged | tier-6 gem |
| 13 | **High Roller** | Pick High on every route and clear Smoked | tier-7 gem |
| 14 | **Altar Titan** | Buy 2 ultimates in one match | 15 dust |
| 15 | **Champion Hunter** | Your squad kills 8 champions in one match | tier-4 gem |
| 16 | **Lair Raider** | Kill both lair champions in one stage | 10 dust |
| 17 | **Last Herd** | Win by Last Herd Standing on Pungent | tier-7 gem |
| 18 | **Snatcher** | Land the killing blow on a boss another squad led | title |
| 19 | **Bounty Breaker** | Down 3 bountied heroes in one match | title |
| 20 | **Horn Blower** | Clear Sharp with every wave called early | 10 dust |
| 21 | **Speed Herd** | Clear Medium in under 13 minutes | title |
| 22 | **Peacekeeper** | Clear Sharp without downing an enemy hero | title |
| 23 | **Clean Exit** | Extract at stage 3 on Smoked with the whole squad standing | tier-6 gem |
| 24 | **Herd of Three** | Clear Aged with your whole squad (bots count) never knocked out | tier-5 gem |
| 25 | **Iron Will** | Clear Stinky solo | tier-8 gem |
| 26 | **Gem Cutter** | Upgrade a gem to +5 | 20 dust |
| 27 | **Jeweler** | Own a tier-11 gem | title |
| 28 | **Doomwheel** | Clear Doomwheel | tier-11 gem |
| 29 | **Doomwheel Alone** | Clear Doomwheel solo | tier-11 gem with a unique |
| 30 | **Golden Wheel** | Earn a tier-12 gem | frame part |

**Who does what:** M2 sets the per-match flags (no rank bought, no buff, no knockout, all routes High, horns, etc.), and P evaluates them in `Data/Challenges`.

---

## (3) Gameplay: how a match should feel like Liberty on our bigger PvP map

**Target length:** about 13–16 minutes, which the Early Horn shortens to about 11.

1. **Lobby, about 30 s.** The leader picks a **tier** from the ladder. Each tile shows its name, reward ×, gem tier and "Best Solo: Aged". Everyone sees "Tier 6 · Smoked · gems tier 6". The Skip Wave At setting is on the same card.
2. **Waves 1–4 of a stage, 4 × 30 s with 4 s lulls.**
   - Each wave opens with mice pouring from 2–3 storm-edge fronts toward the squads, then a trickle.
   - Stomping fills **rinds**, about 150–350 per wave per hero at stage 1.
   - In every lull the HUD pulses "V · 340 rinds", and a good player buys **1–3 ranks per wave**. This is Liberty's upgrade-menu rhythm: kill, buy, kill, buy.
   - **Whey** (from POIs, champions and shrines) builds over the stage, for about **one stall trip per stage**. It is a risk decision, because the buffs are lost on a knockout.
3. **Champions on waves 2–3, the lair on wave 4.** These are the "corner minibosses": the squad fights for escalating class XP (50 → 100 → 150), gear and a lair gem chance. **PvP happens here**, at contested objectives and when the storm squeezes.
4. **The Early Horn.** When 70% of a wave is stomped, the horn calls the next wave early and pays rinds for the skipped seconds. Strong squads speed the whole server up, which is Liberty's "skip wave" feel. The storm follows the wave index, so the map shrinks with the pace.
5. **Wave 5 is the boss wave.** A boss ceremony (iteration 1), the top-damage squad wins the chest and the gem roll, and Snatch still applies.
   - Then the **route card** (winning squad), then **Double or Nothing** (any squad), then the **Rind Gate**.
   - The 4-stage cycle and the outline features stay as they are, inside Liberty's wave count: "Wave 10 / 20".
6. **Stages 3–4: the late game.** The **Big Cheese Altar** opens in the centre, where the storm drives everyone. Ultimates cost 6k rinds + 600 whey and make the buyer a bounty. This is Liberty's centre store and our PvP hotspot.
7. **Results.** The breakdown shows:
   - "+640 stomps (Smoked ×2.0)" and the **class XP bar** (P-level up!);
   - the **gem drop card** with its 5 rolls, the unique, and Equip / Salvage buttons;
   - challenges progressed, and "Tier unlocked: Pungent".

**Team play, Liberty-style:**
- shared XP (45 studs);
- **rind gifting**;
- **squad-summed gem aura** (3 humans > 1);
- Herdguard;
- revives;
- **Best Squad** records next to Best Solo.

**Difficulty choice is the main lever of the meta loop:**
1. Farm gems at tier k.
2. Prestige and ascend.
3. Clear tier k + 1.

Pressure, as **Custom**, is for the experts who want to mix the modifiers themselves.

**PvP stays the spice.**
- Long-term damage is PvE-only.
- Meta HP counts in PvP at most +25%.
- Run-only power (ranks, whey, Altar, cards, gear) decides fights, so a P40 veteran wins against a newcomer with better play and better spending, not with save-file stats.

---

## (4) Ranked build list for iteration 2

The ranking is by alignment impact ÷ effort and by dependency (items 1–3 unblock the rest).

| Rank | Build | Owners | Effort | Depends on |
|---|---|---|---|---|
| 1 | **Stop v7 shipping as-is.** Cut the Herd Talent Board and the Evolution and Charms tabs from the release branch. Keep stomps (v7) and the v6 → v7 step. | P, U, lead | S | — |
| 2 | **Profile v8** (additive): `prestige/plevel/prestigePaid`, `asc`, `difficulty {unlocked, cleared, bestSolo, bestSquad, perClass}`, `gems {inv, equipped, dust, nextId}`, `challenges`, `settings.skipWaveAt`, the upward level recompute, and the stars / Pressure / (if shipped) TP, charm and evo conversions. Include a pre-v8 raw backup (the Z-17 pattern) and specs for every conversion. | P | M | 1 |
| 3 | **Difficulty ladder:** `Config/Difficulty` (11 tiers = presets + base + reward ×), `Run/Pressure` reading the tier, the leader tier pick, unlock on clear, Best Solo / Squad, the `IntegrationDifficulty` sim guard. | M2, P, U | M | 2 |
| 4 | **Numbered waves + Early Horn:** `WaveDirector` per-wave budgets and lulls, the storm keyed to the wave, champion sync, the HUD "Wave 7/20", the Skip Wave At setting. | M1, M2, U | M | — |
| 5 | **Cheese Gems:** `Config/Gems`, `Data/Gems` (roll, equip, salvage, upgrade, squad sum with caps), drops (boss / final / DoN / High / lair / extract / weekly first clear), `World` aura, the Gems screen, tier colours and icons. | P, M2, M1, U, G | L | 2, 3 |
| 6 | **Prestige:** the button, the P-level climb (12k), the perk point to P16, the bonus to P40, nameplate frames, the achievement `stars` → `prestige` remap. | P, U, G | M | 2 |
| 7 | **Class XP from kills** (+0.5 per stomp), the tier multiplier, the 70·l^1.35 curve, escalating champion XP. | P, M2 | S | 2, 3 |
| 8 | **Ascension:** 7 × 8 node table, node gates, behaviours in `Stats`/`World`, Bull, Matriarch and Ancient looks (G), the Ascension panel. | P, M1, G, U | L | 6 |
| 9 | **Hero screen and menu restructure:** a Hero screen (Level & Perks · Prestige & Ascension · Abilities · Skins); ProgressUI tabs go from 9 to 6 (Contracts, Herd Pass, Challenges+Milestones, Mousepedia, Levels, Boards); Herd Upgrades move to the cheese shop. | U | M | 5, 6 |
| 10 | **30 Challenges:** match flags (M2), `Data/Challenges` (P), the tab (U). | P, M2, U | M | 3, 5 |
| 11 | **Upgrade-menu cadence:** the lull pulse, buy ×5, rind gifting, cards every 2 levels after 10. | M2, U | S | 4 |
| 12 | **Leaderboards:** Total Stomps, Best Solo (tier → time), Best Squad; the lobby wall. | P, U | S | 3 |
| 13 | **Storm-edge wave fronts** and the mix unlocking by wave. | M1 | M | 4 |
| 14 | **Contracts reworded** to tiers, horns and stomps; Mousepedia Gems and Difficulties pages; Herd Pass dust tiers. | P, U | S | 3, 5 |
| 15 | **PvP meta cap:** `metaHpPvpCap` 25% in `World`, plus a spec. | M1 | S | 5, 6 |
| 16 | **Docs:** GDD-v2 progression chapter rewritten to this model, V5-PLAN B1/B2/B3/A7 marked superseded, HANDOFF updated. | lead | S | — |

**Cut list:**
- the Herd Talent Board;
- Evolutions as a separate system;
- Charms;
- v5 A7 level buffs;
- the Pressure board as the main selector (kept as Custom).

**Live-safety checklist for every item above:**
1. Additive v8 fields only.
2. Old fields stay read-only for one release.
3. Conversions only ever raise a value: levels never drop, stars become an equal Prestige, charms become better-than-midpoint gems, TP is refunded as cheese and dust.
4. One-time explanatory toasts.
5. A pre-v8 raw backup copy.
6. `DataProfileSchema` specs migrate saved fixtures from v1, v6 and v7 (including a maxed v6 veteran and a corrupted save).
