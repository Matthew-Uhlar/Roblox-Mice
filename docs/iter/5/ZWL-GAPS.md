# Iteration 5, Phase B: Zombie World Liberty gap review (team Research, 2026-11-21)

**Question:** which Liberty features does Trunkfall still lack?

**Scope:**
- Mechanics only. Every suggestion uses our names, never Liberty's names or art.
- Phase A items are excluded: auto start, camera rotation, and ability slots by level.
- Monetization rule: Robux never buy gems, dust, prestige, ascension or challenges, and nothing is pay-to-win.

## Sources and confidence

| Source | What it confirms | Status |
|---|---|---|
| Owner's decoded Liberty save (`docs/research/zwl-save-model.md`) | 11 heroes; per-hero kills, level, prestige and 8-node ascension; 11 difficulties; Best Solo; jewels (14 tiers, 5 rolled stats, uniques, upgrade level, dust, 200 slots); `skipwavethreshold` (a kill count); `Particles` / `Visuals` toggles; 30 challenges; `TimePlayed` | **Liberty-verified** |
| The creator's series site (read 2026-11-18, summarized in `docs/research/zombie-world.md`) | minerals → upgrade menu; vespene buffs lost on death; late-game store; two-way resource exchange; three boost zones; respawning corner minibosses; XP shared in range; per-level buff list; `-status`; spawn invulnerability; Speed × Life difficulty; kill-milestone hero unlocks; hero stages | **Series-verified** (Zombie World / Unity, so Liberty may differ) |
| Bank-tool discussion, github.com/DarthVan/StarCraft2-Bank-Restorer/discussions/2 (re-read today) | jewels drop from bosses or at match end, rarer ones less often, and they boost each team player | **Liberty-verified** |
| Searched today, with no new facts | Web search found no Liberty or Unity pages on Reddit, YouTube, Blizzard forums or CurseForge. The hosts zombieworldgames.weebly.com and sc2arcade.com are blocked by this session's network policy. The fandom wiki refuses automated fetches (403), and brainnations.com is spam. | — |

Anything not covered by these sources is marked **unverified**. Unverified items are common arcade-survival features the owner listed. They may or may not be in Liberty.

## Feature table

Legend:
- **Have**: built and live.
- **Partial**: exists, but differs from Liberty in a way players would notice.
- **Missing**: not built.
- **N/A**: deliberately not adopted, by an earlier owner or lead decision.

### Heroes and roles

| Liberty feature | Source | Us | Evidence | How it maps to our game |
|---|---|---|---|---|
| 11 heroes with separate progress | save | Partial | `src/shared/Config/Classes.luau` (7 classes) | Add classes over time, toward 9–11. Each new class should fill a missing role (see the next two rows). |
| Roles: sniper, melee, tank, caster, healer, builder (inferred from hero types) | save (names only); roles unverified | Partial | Our roles: Brawler, Water mage (heals), Ranger, Duelist, Chef, Flyer, Alchemist (`Config/Classes.luau`) | The missing roles are a dedicated **long-range sniper** and a **builder** that places structures. |
| A builder hero places structures (turrets, walls) | unverified | Missing | no deployables in `Combat/World.luau` | A class whose ability places a short-lived **Peanut Turret** or **Hay Wall** (server-side entities in World). |
| New heroes unlock at kill milestones | series | Have | `Data/Evolution.luau` `freeUnlocks` | — |
| Hero stages by kills | series | N/A | Replaced by Ascension (`Config/Ascension.luau`, `AscensionNodes.luau`) | — |

### In-round economy and upgrades

| Liberty feature | Source | Us | Evidence | How it maps to our game |
|---|---|---|---|---|
| Kill currency → repeatable stat upgrade menu (V) | series | Have | `Config/RunShop.luau` `RANKS` (8 stats, soft cap 100) | — |
| An upgrade that raises the level-up rate | series | Partial | Only the **Scholar** card (+30% XP), `RunShop.luau`. The V menu has no XP rank. | Add a 9th V-menu rank, **Quick Study** (+% crumb XP, capped). |
| Second currency → buffs at map sale points, lost on death | series | Have | Whey stalls; `RunWallet.knockout` (`Run/RunWallet.luau:229`) | — |
| Class-specific expensive buffs | series | Have | Class Stall, `RunShop.luau` (class deltas) | — |
| Late-game store with huge items, lost on death | series | Have | Big Cheese Altar ultimates, `RunShop.ALTAR_FROM_STAGE = 3` | — |
| Resource exchange, both ways | series | **Partial** | Swap Stand goes rinds → whey only (`RunShop.luau:268`) | Add whey → rinds at the Swap Stand, with a fee so neither direction can be used to farm. |
| A `-status` list of unbought buffs and where they are | series | Have | RunShopUI "What's left" (`client/UI/RunShopUI.luau:11`) | — |
| A per-level buff list ("levels" screen) | series | Have | `Run/Stats.luau` level gains; the Levels tab in `RunShopUI` | — |
| Items or gear from shops | series | Have | Run gear and the Shop Cart (`Config/Gear.luau`, `Run/CartRules.luau`) | — |
| Hero abilities unlocked by level | series | Excluded | Phase A3 | — |
| Ultimates | series | Have | Altar ultimates (`RunShop.luau` `titan`, `cataclysm`, `overdrive`, `herdguard`) | — |
| Team auras from jewels | Liberty-verified | Partial (owner decision) | Gems became personal in iteration 4 (`Config/Gems.luau:99`) | Keep the owner's decision. Do not revert. |

### Waves, bosses, map and difficulty

| Liberty feature | Source | Us | Evidence | How it maps to our game |
|---|---|---|---|---|
| Numbered waves; spawners at map edges; boss waves | series | Have | `Run/Waves.luau` (5 per stage, the 5th a boss), `Combat/WaveDirector.luau`, 13 bosses in `Config/Bosses.luau` | — |
| Minibosses respawn on a timer in the corners | series | Have | Miniboss camps, `Combat/Champions.luau:412` | — |
| Minibosses pay a long-term reward (talent points) | series | Partial | Camps pay only rinds, whey and XP. The Herd Talent Board was cut (ALIGNMENT §2a). | Give the first miniboss kill per match a small **Crumb Dust** chance or class-XP burst (never Robux). |
| Three boost zones: minerals, vespene, and both plus XP | series | **Partial** | One Power Totem type, rinds ×1.6 (`RunShop.TOTEM_RIND_MULT`) | Add **Whey** and **Crumb (XP)** variants of the capture-and-hold totem, one of each per map. |
| An 11-tier named ladder with Best Solo | Liberty-verified | Have | `Config/Difficulty.luau`, `Data/Ladder.luau`, `client/UI/LadderUI.luau` | — |
| Speed and Life chosen as separate settings | series | Partial | One tier plus a Custom Pressure board; `rush_hour` covers spawn pace (`Config/Pressure.luau`) | Add a lobby **Pace** toggle (Normal / Fast: shorter waves and lulls, ×1.15 stomps). It combines with any tier. |
| Endless or overtime after the final wave | unverified | Missing | none (`grep endless` returns nothing) | **Overtime**: after a full clear the squad can stay for scaling waves until it wipes. Banked rewards are kept, and a best-wave record is saved per tier. |
| Spawn invulnerability | series | Have | `World.REVIVE_GRACE`, `DROP_PROTECT` (`Combat/World.luau:124`) | — |
| Objectives on a large map, plus PvP | owner | Have | iteration 4 beacons, rescue and caravan (`Config/Pois.luau`); squads PvPvE | — |

### Long-term progression

| Liberty feature | Source | Us | Evidence | How it maps to our game |
|---|---|---|---|---|
| Kills per hero and in total | Liberty-verified | Have | stomps in `Data/Evolution.luau` | — |
| Hero level (cap about 70) | Liberty-verified | Have (cap 30) | `Data/ClassProgress.luau` | — |
| Prestige 0–99 | Liberty-verified | Have | `Config/Ascension.luau:18` `MAX_PRESTIGE = 99` | — |
| 8-node ascension per hero | Liberty-verified | Have | `Config/AscensionNodes.luau` | — |
| Jewels: tier by difficulty, 5 rolled stats, uniques, upgrade, dust, 200 slots | Liberty-verified | Have (12 tiers, not 14) | `Config/Gems.luau` (`INVENTORY = 200`, 12 uniques), `Data/Gems.luau` | Tiers 13–14 are optional, for example from Overtime records. |
| Jewel drops from bosses or at match end | Liberty-verified | Have (end only, by owner decision) | iteration 4 plan; `Data/Gems.luau` | — |
| 30 challenges | Liberty-verified | Have | `Config/Challenges.luau` | — |
| Talent points (Unity) | series | N/A | cut in iteration 2 (ALIGNMENT §2a) | — |
| Time played per hero | Liberty-verified (field) | Missing | no playtime field in `Data/ProfileSchema.luau` | Track seconds per class and show them on the Hero screen and the lifetime stats card. |

### Team play

| Liberty feature | Source | Us | Evidence | How it maps to our game |
|---|---|---|---|---|
| XP shared in range | series | Have | `RunShop.XP_SHARE` and `XP_SHARE_RADIUS` (`World.luau:3095`) | — |
| Kill currency shared in range | series | Have | `RunShop.SHARE`, `SHARE_RADIUS` | — |
| Revives | unverified | Have | `World.REVIVE_*`; Herd Call (`client/UI/CombatHudUI.luau:186`) | — |
| Sending resources to a teammate | unverified | Have | rind gifting (`Net.luau`, `RunDirector`) | — |
| Team-wide paid upgrades (one buy helps the squad) | unverified | Missing | none (`grep teamUpgrade` returns nothing) | A **Squad Stall**: a pricier whey buff that applies to every squadmate in range. |

### QoL and screens

| Liberty feature | Source | Us | Evidence | How it maps to our game |
|---|---|---|---|---|
| Skip Wave At (a kill threshold, saved per player) | Liberty-verified | Have (as a % of the wave, set by the leader) | `Run/Waves.luau`, `settings.skipWaveAt` (`ProfileSchema.luau:812`) | — |
| Graphics toggles (particles, visuals) saved per player | Liberty-verified | **Partial** | Detail is set automatically by device only (`client/Visuals/DetailLevel.luau`) | Add saved **Effects: Full / Reduced / Minimal** and **Decor: On / Off** settings. |
| A live damage meter | unverified | **Missing** | World tracks only damage to bosses by squad (`World.luau:324`); nothing per player | Track per-hero damage dealt to mice, bosses and heroes, plus healing and damage taken. Show a **Tab meter** and a results table. |
| Kill counts in the HUD and on the scoreboard | Liberty-verified (kills are core) | Have | `client/UI/HudUI.luau:555`, `ScoreboardUI.luau` | — |
| An end-of-game stats screen | unverified | Partial | ResultsUI shows kills, downs, stages, MVP and awards (`client/UI/ResultsUI.luau`) | Add a per-player table: damage, healing, deaths, rinds earned and waves horned. |
| Spectating after death | unverified | Have | `CameraController`, `CombatService` | — |
| Leaderboards (total kills, Best Solo) | Liberty-verified (Best Solo) | Have | `Services/LeaderboardService.luau` | — |

## Top 10 Missing or Partial items, ranked by player value against effort

Effort: **S** ≤ 1 day, **M** 2–4 days, **L** a week or more.

| Rank | Item | Status | Areas | Effort | Why |
|---|---|---|---|---|---|
| 1 | **Damage and kill meter**: live Tab panel plus a results table (damage to mice, bosses and heroes; healing; damage taken; kills; deaths) | Missing (unverified in Liberty; on the owner's list) | combat (tracking in World), UI | M | The owner asked for it by name. It is the most-wanted QoL in co-op survival and feeds the existing MVP and awards. |
| 2 | **Two-way Swap Stand** (whey → rinds, with a fee) | Partial | match flow, UI | S | A one-line rule plus a button. It fixes stranded whey late in a match. |
| 3 | **Graphics settings** (Effects and Decor, saved) | Partial | graphics, UI | S | Liberty saves them. Phones and low-end PCs benefit on our bigger maps. |
| 4 | **Whey and Crumb boost totems** (the three-zone layout) | Partial | match flow, combat, graphics | M | More map spots worth fighting over in PvP. Reuses the totem code. |
| 5 | **Quick Study V-menu rank** (+crumb XP) | Partial | combat, UI | S | Liberty has a level-rate upgrade. It adds a real choice to the V menu. |
| 6 | **Overtime**: endless scaling waves after a full clear, with a best-wave record per tier | Missing (unverified) | match flow, progression, UI | M | An end-game chase for players at the top of the ladder. |
| 7 | **Pace toggle** (Normal / Fast; Fast gives more stomps) | Partial | match flow, UI | M | The series' Speed × Life choice, and faster stomp farming for veterans. |
| 8 | **Time played per class** plus a lifetime stats card (stomps, best tier, prestige, time) | Missing | progression, UI | S | Liberty stores it. Cheap, and it makes the lifetime number more visible. |
| 9 | **Squad Stall** (one whey buff that helps squadmates in range) | Missing (unverified) | combat, match flow | M | Makes team play pay off again now that gems are personal. |
| 10 | **New builder-role class** that places turrets and walls (roster toward 9–11) | Partial (roster) / Missing (role, unverified) | combat, graphics, progression | L | Liberty's roster is wider. Needs art, Ascension nodes and balance work. |

Also considered, not ranked:
- A miniboss long-term reward (S). Small value, and it needs a farming cap.
- Gem tiers 13–14 (S). They only make sense after Overtime.
