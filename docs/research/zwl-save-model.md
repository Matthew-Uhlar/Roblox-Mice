# Zombie World Liberty: the saved progression model (decoded 2026-11-19)

The owner supplied a Zombie World Liberty save, an SC2 bank named `DirectStrike`, plus a 16-byte `.bin` file.
- **Decoding:** we used the open-source bank tool's Liberty form (github.com/DarthVan/StarCraft2-Bank-Restorer, chunk `zombie-world-liberty/*`).
- **Privacy:** the raw files stay out of the repo. Only the structure is recorded here, with the owner's values as an example of a deep save.

## Owner direction

The game should be "a sort of Zombie World Liberty that plays on a larger map, with additional objectives and PvP", plus the other features from the original outline (`docs/brainstorm-2026-06.md`). **Progression and gameplay should follow Liberty's model.**

## What Liberty saves

### Account
| Key | Meaning | Owner's value |
|---|---|---|
| `Primary.Primary` | **Total kills** (lifetime, all heroes) | 5,085,714 |
| `Primary.BS` | **Best Solo**: the highest difficulty cleared solo (1–11) | 10 (Torment) |
| `Primary.BC` | checksum for BS | — |
| `Settings.Ratio` | **Jewel Dust** × 13 (the dust currency) | 130 → 10 dust |
| `Settings.skipwavethreshold` | **"Skip Wave At"**: a player option. The next wave is called early once this many kills are reached. | 1,200 |
| `Settings.Particles` / `Visuals` | graphics toggles | — |
| `CLHistory.C<n>` | **30 challenges** completed (flags, obfuscated by player id) | all 30 |
| `TimePlayed`, `Version` | checksums | — |

### Heroes (11)
Sniper, Adept, Zealot, Archon, Marine, Medic, Probe, Dark Templar, Firebat, Siege Tank, High Templar.

`Purchases.H<i>` marks a hero as unlocked. `Primary.H<i>K / L / P / A` hold its kills, level, prestige and ascension.

| Field | Meaning | Range | Owner's best |
|---|---|---|---|
| K | **kills with this hero** | 0 … millions | Siege Tank 321,522; Dark Templar 102,762 |
| L | **hero level** | 1 … about 70 | Dark Templar 68 |
| P | **prestige** | 0 … 99 (the tool's default "max" is 16–20) | several at 20 |
| A | **ascension**: 8 binary nodes, unlocked one by one | `00000000` … `11111111` | Dark Templar `11111000` |

So each hero has three long tracks:
- level, which resets on prestige;
- prestige count, a permanent star;
- an 8-node ascension tree, the end-game unlocks.

All three are fed by kills and play time on that hero.

### Difficulty ladder (11)
Easy, Normal, Hard, Brutal, Insane, Nightmare, Chaotic, Torture, Inferno, Torment, Death.
- Chosen when a game starts.
- "Best Solo" records the highest one cleared alone.

### Jewels (team boosts), at most 200 in the save
Each jewel has:
- **tier** 1–14: Simple, Regular, Advanced, Brutality, Insanity, Nightmare, Chaos, Agonizing, Inferno, Tormented, Death, Crucified, ?, ??. The tier follows the difficulty it dropped on.
- **five rolled stats**, each a random value inside the tier's range:
  - **minerals** (×10: extra in-round income);
  - **damage**, **life**, **armor** and **speed**.

| Tier | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Min–max | 1–5 | 5–10 | 5–20 | 10–30 | 15–40 | 20–50 | 25–60 | 30–75 | 35–90 | 40–105 | 50–125 | 60–145 | 75–170 | 90–200 |

- **unique perk**, optional, one of 11:
  - one of 6 hero-specific buffs (Marine, Adept, Ghost, Dark Templar, Medic, Siege Tank);
  - Cooldowns −10%;
  - Movespeed +2;
  - "Less HP, more DMG";
  - "20% chance ×2 DMG";
  - "Slows/stuns immune".
- **upgrade** level, raised with **Jewel Dust**. Dust comes from breaking jewels.
- **Drops:** from bosses and at match end. Better jewels drop less often. They boost every player on the team.

The owner's save holds 19 jewels. Most are tier 11–14 rolled near max (for example tier 14 at 2000/200/200/200/200), with uniques. That's the end game: chasing perfect high-tier rolls with the right unique.

## What this means for Trunkfall (alignment targets)

| Liberty | Trunkfall today (v4 + iteration 1) | Alignment |
|---|---|---|
| 11 heroes with separate progress | 7 classes, with class level 1–30, a perk tree, Mastery Stars and alternate abilities | Keep the classes. Make each class's tracks match Liberty: **level → prestige → ascension**, all per class. |
| Prestige 0–99 (level resets, +1 permanent star) | Mastery Stars after level 30 (12k XP each, no reset) | Turn Mastery Stars into **Prestige**. At max level, prestige resets the class level to 1 for +1 Prestige. Each Prestige gives a small permanent class bonus and a cosmetic star, with a cap of 99. Old Mastery Stars convert one for one. |
| Ascension: 8 nodes per hero | Evolutions (3 stages by class stomps), perks | **Ascension**: 8 nodes per class, unlocked by Prestige milestones (P1, P3, P5, P8, P12, P16, P20, P25) plus class stomps. Each node is a strong class-defining upgrade, and the evolution looks attach to nodes 2, 4 and 8. |
| Kills per hero plus total kills | stomps per class plus account total | Already aligned: stomps = kills. Surface them as **Kills** everywhere: nameplate, class card, leaderboard. |
| 11 named difficulties, plus Best Solo | the Pressure board (point-buy modifiers) | Add a **named difficulty ladder** of 11 tiers, Easy → Death. It is set as the main lobby selector, with each tier being a Pressure preset. Record **Best Solo** and **Best Squad** per class and per account, and unlock higher tiers by clearing the one below. Custom Pressure stays as an advanced option. |
| Jewels: tier by difficulty, 5 rolled stats, unique perk, upgrade, dust, team-wide | Charms: 10 types × 4 rarities, a single stat, fusing, squad aura | **Rework charms into Liberty-style Cheese Gems:** tier = the difficulty cleared (11–12 tiers), 5 rolled stats (rinds, damage, HP, armor, speed) in the tier's range, an optional unique perk, an upgrade level paid in **Crumb Dust**, salvage → dust, and the squad aura kept. Keep "never Robux". |
| Minerals for in-round upgrades | rinds and stat ranks (V menu) | Already aligned. Gem "minerals" maps to +rinds income. |
| Skip Wave At (call waves early) | none | Add an **"Early Horn"** option: once the squad's wave kills pass a threshold (a lobby setting), the next wave starts early for a bonus. This cuts idle time (Z-19). |
| 30 challenges | achievements and contracts | Add **Challenges**: 30 permanent goals, each one a hard run (class X on difficulty Y, no deaths, solo). Each pays a title or gem, and the full set rewards a prestige frame. |
| Larger map, objectives, PvP (owner) | done in v4: shrinking storm, POIs, champions, squads PvPvE | Keep. Liberty's wave survival sits inside our larger arena, with objectives and PvP on top. |
