# Trunkfall v2: squad PvPvE redesign (authoritative)

> This file supersedes `docs/GDD.md` wherever the two disagree. The owner's
> direction (2026-11-03) was that the game is not a generic co-op roguelike.
> v2 adds:
> - classes with **permanent per-class progression**, alongside **in-run
>   progression that resets** every run;
> - **multiple squads in one run that fight each other**;
> - **points of interest (POIs) that give in-run power and items**;
> - **much better graphics**.
>
> Owner decisions: squad PvPvE; 12-player servers (4 squads × 3); per-class
> levels + perk tree + skins/mastery + alternate abilities; **gear only lasts
> for the run** (found in runs, never kept); built-in graphics plus AI-generated
> meshes.
>
> Everything from v1 still applies unless changed here: 7 classes, 9 cheese
> maps, 13 bosses, mice hordes, the Low/Mid/High route cards, Pressure, Double
> or Nothing, labelled bots, the monetization rules.

## 1. The match

- **Server:** 12 seats = **4 squads of 3**. Each squad has a colour and a name:
  Swiss (gold), Brie (cream/white), Blue (blue), Pepper Jack (red).
  - Friends who join together are placed in the same squad.
  - Empty seats are filled by 🤖 bots when the match starts. Bots are always
    labelled. Every squad gets at least 1 bot if needed, so all 4 squads exist.
  - A solo player gets 2 bot squad-mates and plays against 3 bot squads. You
    can always play, even when nobody else is online.
- **Lobby:**
  - Pick a class, an alternate ability and a skin.
  - The countdown starts when any human is ready: 5 s once all humans are
    ready, otherwise 30 s auto-start (the AFK rules from v1 still apply).
- **Run = stages on shared maps.** All 4 squads play the **same map at the same
  time**. A run is one cycle of 4 stages. Each stage:
  1. **Drop-in:** each squad spawns at its own corner of the arena.
  2. **Waves:** 150 s of mice hordes spread across the whole map. POIs are live.
     Squads farm XP and gear and **may fight each other** (§2).
  3. **Boss:** spawns at the centre. Every squad damages it. The squad that
     lands the **killing blow** (or deals the most damage if the boss
     times out) wins:
     - the **boss chest** (gear plus cheese);
     - the **route choice** for the next stage: it picks 1 of the 3 route
       cards; the other squads see the choice but don't vote.
  4. **Extraction:** a Rind Gate portal opens for 20 s. Each squad decides as a
     group, by majority with bots following their humans:
     - **Extract:** bank 100% of the squad's pending cheese and leave the run
       (back to the lobby with rewards).
     - **Stay:** go on to the next stage, where pending cheese keeps growing.
       Staying with ≥ 2 squads already extracted gives a "brave" bonus (+25%
       stage cheese).
     - **Double or Nothing** (per squad): stay with the pot ×1.5 on your next boss
       kill, but you lose the pot if you're eliminated.
- **Run ends** when stage 4 is done (survivors extract automatically), when
  every squad has extracted or been eliminated, or after 2 stages with only
  one squad left: the last squad standing gets a **Last Herd Standing** bonus
  (+50% pot) and is extracted.

## 2. PvP between squads

- **Friendly fire is off.** Every weapon and ability hits enemy-squad heroes
  as well as mice, at **PvP damage ×0.45**, with no crit bonus against players.
  The ×0.45 exists because hero damage is tuned for hordes.
- **Downed and eliminated:**
  - A hero at 0 HP is **downed** (v1 rules: crawl, revive by a squadmate in
    3 s within 8 studs).
  - A downed hero takes damage from enemy heroes and dies after 4 more hits or
    when the downed timer runs out.
  - Dead heroes spectate their squad and respawn at the next stage start if
    their squad survives.
  - A squad is **eliminated** when all its members are dead or downed with no
    one left to revive them. Second Wind still works, with the v1 limit of 1
    per stage.
- **Loot on elimination:** an eliminated hero drops a **loot bag** holding all
  their gear and 30% of their squad's pending cheese share. Any squad can pick
  it up (channel 1.5 s). This is the extraction-shooter risk/reward.
- **Kill feed and bounties:**
  - Kills appear in a kill feed.
  - A hero on a 3-kill streak gets a **bounty** shown on the map; whoever
    downs them gets +100 cheese.
- **Spawn protection:** 5 s of invulnerability at drop-in and after a revive.
  Every squad also has a safe corner where its members take −60% damage from
  other squads.
- **Bots fight too,** but they prefer mice and POIs. A bot only attacks enemy
  heroes within 18 studs, or heroes attacking its own squad.

## 3. In-run progression (resets every run)

- **Levels and upgrade cards:** the v1 system (Config/Upgrades, rarity and
  luck) is unchanged.
- **Gear (new, run-only):** items found in a run. They are lost when the run
  ends, whether you extract or die; you only keep the cheese and XP. Every
  hero has 3 gear slots:

  | Slot | Effect |
  |---|---|
  | **Weapon mod** | changes your auto-weapon (e.g. Splitting Shots: +2 projectiles at −20% dmg; Cheddar Rounds: burn; Heavy Trunk: +50% knockback and area) |
  | **Armor** | defence (e.g. Rind Plate: +25% max HP; Swiss Mesh: −30% projectile damage) |
  | **Trinket** | utility (e.g. Mouse Whistle: +30% XP; Lucky Cheese: +1 luck; Portal Charm: Extract keeps 115%; Revive Bell: revive in 1.5 s) |

  - **Rarity:** Common, Rare, Epic, Legendary, with bigger numbers at each
    tier. About 30 items in total (Config/Gear).
  - **Equipping:** picking up an item fills an empty slot automatically. If
    the slot is full, a 4 s swap prompt appears; the dropped item stays on
    the ground.
  - **Sources:** POIs, Elite Camps, boss chests, loot bags, and rare mouse
    "carriers" (golden mice that run away).
  - **Bots** equip whatever they find.

## 4. Points of interest (power and items)

The v1 POIs (caches, shrines, elite camps, fountains, mousetraps, the rare
Pantry and Statue) are kept and become **contested**: any squad can channel or
use them. Channelling is interrupted by damage, so squads fight over them.

New POIs:

| POI | What it does |
|---|---|
| **Armory Crate** (common) | channel 4 s → 1 random gear item (Rare or better at stage 3+) |
| **Cheese Vault** (uncommon) | channel 8 s; announced to all squads → 2 gear items + a big cheese pot |
| **Power Totem** (uncommon) | capture-and-hold zone: the owning squad gets +15% damage while it holds it; it can be contested |
| **Shop Cart** (rare) | spend *pending* cheese on 1 of 3 gear items (this is in-run soft currency, never Robux) |

## 5. Long-term progression (per class, permanent)

Each of the 7 classes has its own profile block: `classes[classId] = {xp,
level, perkPoints, perks, ability, skin, mastery}`.

- **Class XP** comes from runs played as that class:
  - +XP per stage survived, per boss damage share, per hero down and per POI;
  - ×1.5 when you extract.
  - Levels 1–30. Level n needs `100 · n^1.4` XP.
- **Perk tree:**
  - You earn 1 perk point per level. Each class has a tree of **3 branches ×
    5 tiers**.
  - Tier t needs t−1 points already spent in that branch, so tiers unlock in
    order.
  - Perks are moderate (+8–15%, or small new behaviours), never bigger than an
    epic upgrade card.
  - Respec costs cheese (scaling with level). A Perk Respec Token (Robux) is a convenience shortcut; it gives no power, and respec is always available for cheese.
  - A level-30 hero is about 25–30% stronger than a level-1 hero at
    the same in-run level. Matchmaking doesn't need to be skill-based, because
    bots and PvE keep things fair.
- **Alternate abilities:** each class has its base ability plus **2 alternates**,
  unlocking at class levels 5 and 15. You choose one in the lobby.
- **Skins and mastery:**
  - Class skins (colour sets + accessories) unlock at levels 3, 10, 20 and 30.
  - **Mastery** titles and badges at levels 10, 20 and 30 (Bronze, Silver,
    Gold Herd), shown on the nameplate.
- **Account-wide:** account level, cheese, Golden Cheese, cosmetics, account
  talents (kept, but smaller) and leaderboards.
- **Migration:** existing profiles get `classes = {}`. Players who already
  owned a class start that class at level 1.

## 6. Graphics overhaul

- **Lighting:**
  - Future lighting, Atmosphere, Sky, Bloom, ColorCorrection, SunRays and
    DepthOfField (off on mobile).
  - Each map has its own mood preset (ClockTime, fog and colour grade).
- **Maps:**
  - Built from **Terrain** (FillBlock, FillBall and FillWedge with Grass, Sand,
    Rock, Snow, Basalt, CrackedLava, Mud, Water and so on) instead of flat
    plates. Each map gets hills, cliffs, water and paths.
  - Props are detailed, multi-part, use PBR materials and are themed per map:
    cheese-wedge rocks, holes, trees, waterfalls, lava cracks, coral.
  - Decoration density depends on the device (low, mid or high).
- **Characters:**
  - Heroes keep the player's avatar plus class gear: a sash, a hat and a
    held-weapon prop.
  - Optional elephant suits use generated meshes.
  - Mice and bosses use AI-generated meshes when `Config/AssetIds` has ids.
    Otherwise they fall back to much richer part-built models (more parts,
    smooth shapes, Neon eyes).
- **VFX:**
  - ParticleEmitters using built-in `rbxasset://textures/particles/*` textures.
  - Trails on projectiles and Beams for chains.
  - Squad-coloured Highlights on enemy heroes, damage numbers and screen
    shake. All pooled.
- **UI:**
  - A cohesive cheese-themed theme with gradients, strokes and icons drawn
    from UI primitives.
  - A squad scoreboard, kill feed, minimap and gear slots.
  - The v1 mobile and text-size rules still apply.
- **Budget:** 60 fps on mid phones. Under 3,000 rendered parts in view on the
  mid tier. LOD for mice beyond 80 studs.

## 7. Monetization (unchanged rules)

- No paid random items, no Robux near Double or Nothing, Pressure or gear, and
  no pay-to-win.
- Skins earned through class levels stay earnable. Robux can buy **extra
  cosmetic skins**, a perk-respec token (convenience) and the v1 items.
- Gear can never be bought.

## 8. What stays

- Pressure modifiers apply to the whole match; the lobby leader picks them.
- Cycles: v2 uses a single cycle of 4 stages per run. Deeper runs are a later
  live-ops option.
- Leaderboards: wins (extractions), PvP downs, Last Herd Standing.
