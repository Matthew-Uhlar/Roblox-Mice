# Research: Zombie World (StarCraft II arcade), by TKS (2026-11-18)

The owner asked us to study "Zombie World Liberty" and adopt its design for
in-round and long-term character progression. We borrow **mechanics only**:
no names, art, units or text from the original.

## Sources

- The creator's official series site, read 2026-11-18:
  - https://zombieworldgames.weebly.com/ (overview of Zombie World and Zombie World: Unity)
  - https://zombieworldgames.weebly.com/zombie-world.html (original map: tips for kills, waves and leveling)
  - https://zombieworldgames.weebly.com/zombie-world-unity.html (Unity: resources, talent points, map layout)
- The Liberty jewel mechanic (maintainer comment, Sep 2023): https://github.com/DarthVan/StarCraft2-Bank-Restorer/discussions/2
- **Unreachable:** the fan wiki zombie-world-unity.fandom.com returns 403 to automated fetches. The class-guide domain (brainnations.com) has been hijacked by spam. Details that only those pages hold, such as exact talent trees and the hero roster, are therefore not verified.

## What the series does (verified)

### Match

- **Format:** co-op survival for up to 6–8 players. Zombies come from spawners at the map edges in lanes, and boss waves come from one corner.
- **Difficulty:** players pick two separate settings, **Speed** and **Life** (enemy HP), with tiers up to IMPOSSIBLE and GODLIKE. Higher difficulty earns kills and progress faster.
- **Spawning:** players are briefly invulnerable and untargetable when they spawn.
- **Map layout:**
  - Three **resource boost zones**: left (minerals), right (vespene), and centre (both, plus XP).
  - **Minibosses** patrol the bottom corners and respawn on a timer. They give talent points and XP.
- **XP sharing:** a hero standing near the hero that kills (about 10 range) also gets part of the XP. A "level-up rate" upgrade and boss kills speed leveling up.

### In-round progression (resets)

- **Minerals** come from kills. They buy **hero upgrades** from the upgrade menu (hotkey V): repeatable stat ranks such as damage, armor, life and regeneration.
- **Vespene** buys **buffs** at sale points around the map.
  - Each buff costs 500, except two class-specific buffs at the bottom of the map, which cost 1,000.
  - **Vespene buffs are lost on death.**
  - A `-status` command lists every unbought upgrade with its location and cost.
- **Late-game store** in the map centre: very powerful upgrades for every hero, costing 150,000 minerals and 15,000 vespene each. **They are lost on death.**
- **Resource exchange:** trade minerals for vespene and back.
- **Hero levels:** heroes level up in the round, with a listed buff for each level (a "levels" screen). In Unity, levels are lost on death.

### Long-term progression (saved)

- **Only two things carry between games in Unity: Talent Points and Kills.**
- **Talent points** are earned by killing bosses (including minibosses), winning, and progressing through waves. They are spent on permanent per-hero bonuses on the "show stats" screen.
- **Kills** are a lifetime counter, and the main unlock currency.
  - **Hero stages (evolutions):** each hero line has stages 1–4, each needing more kills. Players say "upgrade stages to stage 4 as soon as possible".
  - **New heroes unlock at kill milestones.** For example, a heavy hero unlocks at 12,500 kills, and late-game heroes after that.
  - Players chase "1 million kills". Kills are split between the players present, so solo farming on high speed is optimal.
- The original Zombie World saved **hero levels** (cap 251) and had **achievements** that changed heroes (for example, an "immortal" achievement).
- **Jewels (Liberty):**
  - An inventory of jewels.
  - **Each jewel buffs every player on the team.**
  - Jewels drop from **bosses** or at **match end**, and rarer jewels drop less often.
- **Saves:** bank files hold the save data. The community values its saves enough to run recovery tools.

### Why players stick (inferred from the sources)

1. **A visible lifetime number that always goes up (kills).** It unlocks new heroes and stages, so every session moves you forward even if you lose.
2. **Two in-round currencies with different jobs.** Minerals are safe, permanent-for-the-round power. Vespene buffs and late-game items are lost on death, so they add risk and make you play carefully.
3. **Map spots worth fighting for:** boost zones, sale points and the centre store.
4. **Team-wide rewards (jewels, shared XP)** make playing together pay off.
5. **Repeatable talent ranks** keep the grind going after unlocks run out.

## How it maps onto our game

| Zombie World | Our game (v5) | Notes |
|---|---|---|
| Minerals → hero upgrades (V menu) | **Rinds** dropped by mice → **Stat Ranks** (V menu) | kept on death, lost at run end |
| Vespene → map sale points, lost on death | **Whey** → **Buff Stalls** at map spots, lost on death | |
| Two class-specific 1,000 buffs | one **Class Stall** buff per class | |
| Centre late-game store | **Big Cheese Altar** at the arena centre (the storm pushes everyone there) | lost on death; contested PvP hotspot |
| Resource exchange | **Swap Stand** | 20% fee |
| Three boost zones | **Rind Mill / Whey Spring / Golden Glade** | contested; capture-and-hold like the Power Totem |
| Shared XP in range | squadmates within 45 studs get 50% of kill XP | |
| Levels with listed buffs | each in-run level adds a small listed buff on top of the upgrade cards | levels are **kept** on redeploy (deviation: our redeploy already costs time) |
| Minibosses give talent points | Champions give talent points | |
| Talent points (bosses, wins, waves) | **Herd Talent Points**, per class | |
| Kills: lifetime unlock currency | **Lifetime stomps** per class and in total | |
| Hero stages 1–4 by kills | **Evolutions** per class: stage 2/3/4 at 2,500 / 15,000 / 60,000 class stomps | |
| New heroes at kill milestones | free unlock path for each paid class | cheese purchase stays |
| Jewels: team buff, boss or match-end drop, rarity | **Charms**: squad-wide auras, boss and match-end drops, 4 rarities, 3 sockets, fuse 3 → 1 | never sold, no paid rerolls |
| Speed × Life difficulty | the existing **Pressure** board | Pressure multiplies talent points and stomps |
