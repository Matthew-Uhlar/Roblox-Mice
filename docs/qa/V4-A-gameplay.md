# V4 review, team A: gameplay loop and fun

_Date: 2026-11-16. Branch `claude/focused-gates-jihpzi`. This is a report only: no code was changed._

Scope: the moment-to-moment loop and the run-level loop of the live v3 build (place v6), seen from the player's side. The review covers pacing, difficulty, class balance, cards, gear, champions and bosses, PvP, extraction and Double or Nothing, Pressure, bots and the end-of-run payoff. It also assesses the planned bigger maps with a closing storm.

## How the numbers were measured

All numbers come from the real shared modules, driven by the headless sim (`tests/sim/Headless.luau`) and by direct `World` duels. The scratch scripts are in `/tmp/claude-0/-home-user/62ecd08e-82c1-5cab-a26b-5e0b2b23913e/scratchpad/v4a/`:

| Script | What it does |
|---|---|
| `run.luau` | Instrumented full matches via the `onTick` hook |
| `run2.luau` | Mice density and idle time in 10 s buckets; boss and champion kill attribution |
| `duel.luau` / `duel2.luau` / `focus.luau` | PvP time to kill (TTK) in an empty World |
| `agg.py` | Aggregation |

Data sets:

| Set | Setup | Size |
|---|---|---|
| **Solo** | 1 "human" + 11 bots, POIs on | 140 matches (20 seeds × 7 human classes, seeds 100–119) |
| **Party3** | 3 human stand-ins in one squad + 9 bots | 12 matches |
| **Full12** | 12 human stand-ins in 4 parties of 3 | 12 matches |
| **Pacing buckets** | Ele Fonte human | 10 matches |
| **Duels** | Base stats, plus real end-of-stage-2 builds taken from 21 sims (81/81/78 builds for the 3 free classes, only 3 each for the others) | — |

**Caveat.** The sim's "human" is a BotBrain stand-in. Absolute win rates say more about the stand-in than about real players. The structural findings below (spawn budget, i-frames, attrition, last-hit rewards) do not depend on who is driving.

---

## Findings, ranked by player impact

### HIGH

#### H1. Stages 3–4 are an empty solo PvE epilogue, and the PvPvE game ends after stage 2

**Evidence (Solo, 140 matches):**

| Stage | Squads in the run at stage start | PvP downs per stage | Eliminations per stage |
|---|---|---|---|
| 1 | 4.00 | 13.0 | 0.85 |
| 2 | 2.88 | 9.0 | 0.85 |
| 3 | 1.19 (only 1 squad in 57 of 68 stage-3s) | 0.9 | 0.12 |
| 4 | 1.00 (always 1 squad) | 0.0 | 0 |

- The human's squad kills 65% of all champions over a run (a fair share is 25%), only because it is alone in stages 3–4.
- **Attrition:** bot squads extract at the stage-1 gate in 47 of 140 matches and at the stage-2 gate in 57. That comes from `BotBrain.EXTRACT_POT = 260` (`src/shared/Bots/BotBrain.luau:174`). Add 0.85 eliminations per stage on top.
- Last Herd Standing needs `LAST_HERD_STAGES = 2` alone stages (`src/shared/Run/MatchState.luau:210`). A squad left alone at stage 3 therefore has to play stages 3 **and** 4 alone. That is about 7–8 minutes with no rival, and Last Herd never shortens anything.
- The live server shows the same thing: any squad that survives the stage-2 gate plays half the match with nobody to fight.

**Fix:**

- **Bots stay longer.** Bot-only squads never extract before the stage-2 gate. Change `EXTRACT_POT` from a flat 260 to `{∞, 330, 420}` by gate.
- **Reinforcements.** If at most 1 squad is left when a stage starts, drop in one fresh "Rival Herd" bot squad.
  - It joins at the current stage, at the human squad's average level minus 2.
  - It gets 1 Rare gear item per member.
  - It is labelled 🤖 like every bot.
  - At most 1 reinforcement per match.
- **Shorter Last Herd.** Set `LAST_HERD_STAGES` to 1, so that being alone for one stage ends the run with the +50%.
  - Or offer a "Victory lap": Extract now with +50%, or Stay for the PvE stage with no bonus.

**Targets:** squads at stage-3 start ≥ 2.0 on average, and PvP downs in stage 3 ≥ 5.

#### H2. Dead time: the horde budget is a v1 co-op budget spread over 12 heroes on maps 6× bigger

**Evidence.** Mean mice on the whole map, mean mice within 48 studs (the screen) of the human, and the human's idle share:

| Stage | Mice on the whole map | Mice on screen | Human idle |
|---|---|---|---|
| 1 | ~17 at 0 s, ~65 from 40 s | 1.8 → 7–12 | 32% in the first 10 s, then 0–10% |
| 2 | 12–37 | 1.7–5.1 | 10–23% all stage |
| 3 | 6–26 | 1.2–4.0 | 7–29% |
| 4 | 2–7 | 0.4–0.8 | 40–62% |

- The `DEFAULT_CAP` of 220 is never approached.
- Across all 140 Solo matches, **24% of wave time is spent in idle streaks of ≥ 10 s** with nothing in weapon reach. There are 205 streaks of ≥ 20 s, and the longest is 154 s.
- Melee humans have nothing within weapon range + 4 studs for 54–65% of wave time (Elephante 63%, Le F'ante 65%, Jumbo 54%, Filet 58%).
- Heroes sprint (out of combat) for 42–59% of wave time and walk about 750 studs per wave-minute. **The stage is mostly travel.**

**Cause:** `WaveDirector.rate` (`src/shared/Combat/WaveDirector.luau:136`) works out to `BASE_RATE 1.5 × (1 + 0.3 × (partyWeight − 1)) × spawnRateMult`.

- For 12 heroes that is about 6.6/s at the start and 28/s at the end, for the **whole server**. That is about 0.55 mice/s per hero early on.
- In v1, 3 heroes on a 140-stud map got about 1/s per hero.
- `Stats.DIFFICULTY.maxPlayers = 4` (`src/shared/Run/Stats.luau:137`) clamps the party scaling.
- Mouse HP does not follow hero level, so a level-15–23 hero deletes what little spawns.

**Fix:** spawn per standing hero, not per server.

- **Per-hero rate:** `0.9/s × ramp(1 → 3.2)`.
- **Density target:** spawn until each hero has **8–14 mice within 48 studs**. Count shared mice once.
- **Caps:** 28 per hero, global cap 300. PerfWorld measured 0.70 ms/step at 220 enemies, so 300 should cost about 1 ms.
- **Mouse HP** × (1 + 0.06 × (average hero level − 1)).
- **Start of stage:** the WaveDirector seeds 6 mice per squad at drop-in, so the first 10 s are not empty.

**Targets:** idle (nothing in reach) < 15% of wave time for every class in every stage, and no idle streak over 15 s outside travel to an objective.

#### H3. PvP i-frames make focus fire, fast weapons and abilities worthless; armor after the ×0.3 makes builds near-immune

**Evidence:**

- `World.damagePlayer` gives the victim `IFRAMES = 0.5` s after **any** hit, from any source (`src/shared/Combat/World.luau:108` and `:891`).
- Armor is subtracted **after** `PVP_MULT 0.3` (`:911`, `math.max(1, amount - armor)`).

Duel results (`duel.luau`, `focus.luau`, `duel2.luau`):

| Duel | Result |
|---|---|
| 1v1 base-stat time-to-down, 100 HP victim | Elephante / Ele Fonte 16.0 s, Fizzante 22.5 s, Le F'ante 29.6 s, Ellie 29.8 s, Filet 32.6 s, Jumbo 33.1 s |
| Same against a 125 HP / 1 armor Elephante | 25–65 s (Ellie 59.8 s, Le F'ante 64.8 s, Jumbo 63.1 s) |
| **3v1** with weapons in sync | **exactly the same as 1v1** (16.0 / 16.0 / 22.5 / 33.1 s) |
| 3v1 with weapons staggered 0.3 s | only 1.0–1.5× faster (Elephante 10.7 s, Ele Fonte 16.1 s, Jumbo 21.8 s). A victim can take at most 2 hits/s. |
| End-of-stage-2 builds, one-sided, median time-to-down | 11–52 s (Fizzante 11.2 s, Elephante 16.6 s, Ele Fonte 28.6 s, Ellie 29.8 s, Le F'ante 39.9 s, Jumbo 52.4 s). **20–60% of pairings never down the target in 90 s.** |

- Average builds at that point: 157–293 HP, 2–5 armor, 0.7–2.7 HP/s regen. Armor Plates (+3 each, ×3) and Mammoth (+5 armor, +5 regen) make light hitters deal 1 damage per hit (`src/shared/Config/Upgrades.luau:100`, `:409`).
- Abilities that land in the same 0.5 s as a weapon hit do nothing. With abilities on cooldown, Stampede, Trunk Quake, Iron Hide, Geyser, Riptide and all 3 Jumbo abilities did not change TTK at all (`duel.luau` table).
- **In real matches** (in-sim, engagement start to down, n = 2,854): median 6.9 s, p75 14.4 s, p90 29.8 s. Downs happen when mice and champions do the damage. Rival heroes mostly chip, and a fight with no mice around is a stalemate. The 3:1 ratio of engagements to downs (8,592 / 2,854) says the same.

**Fix:** a separate PvP damage channel.

- **I-frames:** PvP hits ignore `iframeUntil` and use a per-attacker lockout (`h.pvpLock[by.id]`) of 0.25 s. Mice i-frames stay 0.5 s.
- **Armor in PvP:** `amount − armor × PVP_MULT`.
- **Regen:** paused for 3 s after taking PvP damage.
- **`PVP_MULT`:** 0.3 → 0.35.

**Targets** (even levels, measured with `duel2.luau`):

| Fight | TTK target |
|---|---|
| 1v1 | 6–9 s |
| 2v1 | 3.5–5 s |
| 3v1 | 2.5–4 s |
| No pairing | above 20 s |

#### H4. A player who is out sits in the lobby for the rest of the match (multi-human servers)

**Evidence:**

- One match per server (`src/server/Services/LobbyService.luau:519` "Run in progress... next one soon!", and `:905`).
- `RunDirector.estimateEnd` (`src/server/Services/RunDirector.luau:3013`) tells them how long to wait.
- The median elimination happens 129 s into stage 1 and 112 s into stage 2 (Solo). A player wiped then waits about **10–12 minutes**. In a public 12-player server that is the most likely moment to quit.

**Fix:**

- **Play Again** teleports the player (and their party) to a fresh server via `TeleportService:ReserveServer` / matchmaking, straight away, with the payout already banked.
- Until then, add a spectate-a-rival-squad mode with a "next match in N" queue.

#### H5. The end-of-run payoff is bimodal and punishing: half the solo runs pay almost nothing

**Evidence (Solo):**

- Win: 68 runs, median **2,566** cheese.
- Wipe: 72 runs, median **42** cheese. 30 wipes in stage 1 and 41 in stage 2.
- Overall median 145.5 (p25 42, p75 2,544). 11 runs paid 0.
- Class unlocks cost 2,500 and 4,000.
- The cause: pots are tiny when most eliminations happen (stages 1–2). Champion and vault cheese all goes into the losable pot.

**Fix:** "secured cheese".

- 25% of every champion, vault and boss reward goes straight to the bank and can never be lost.
- An eliminated squad keeps 50% (`ELIMINATED_KEEP_FRAC`), with a floor of 40 cheese per stage reached.
- Class XP stays as it is.

**Target:** median wipe payout ≥ 25% of the median win payout.

### MEDIUM

#### M1. Double or Nothing and extraction lose their tension just when pots peak

**Evidence:** the human squad's elimination risk is 21% in stage 1 (30 of 140), 37% in stage 2 (41 of 110) and **1.5% in stage 3** (1 of 68). Expected value per unit of pot:

| Gate | Extract | Stay | DoN (×1.5, `DON_POT_MULT`, `src/shared/Run/MatchState.luau:209`) | Verdict |
|---|---|---|---|---|
| Stage 1 | 1.0 | 0.63 + 0.37 × 0.5 = 0.82 | 0.95 | Extract is right |
| Stage 2 / 3 | — | — | ≈ 1.48 | DoN is a free ×1.5 |

- The stand-in human chose Stay 224 times and Extract 4 times.
- The name promises "Double", but the multiplier is ×1.5.

**Fix:**

- After H1 (reinforcements) and the storm, stages 3–4 carry real risk again.
- Make DoN a real **×2**, on the condition that you survive **and** your squad kills at least 1 champion or the boss that stage.
- Show every squad's DoN status on the scoreboard, and give DoN squads a map marker. That makes them targets, which is how third-party pressure is meant to work.

#### M2. Champions and bosses reward the last hit, which invites kill steals and turns a 12-hero boss into a lottery

**Evidence:**

- The champion reward goes to `killerSquad or top` (`src/shared/Combat/Champions.luau:562-563`). The boss uses `bossDead.killerSquad` (`src/shared/Combat/World.luau:1430`).
- `run2.luau`: the killing blow came from the top-damage squad in 81% of champion kills and 88% of boss kills.
  - So 19% of champions go to a squad that did less damage. The killer's damage share is 0.68 at p25.
  - 33% of champion kills were contested by 2+ squads.
- Champion gear only reaches members who are `not p.dead` (`:575`). A player who did the work and then died gets nothing.

**Fix:**

- **Champion:** the top-damage squad gets the full reward. A different squad that lands the killing blow gets a 50% "Snatch" bonus (half the XP and cheese, no gear).
- **Boss:** the chest goes to the top-damage squad. Damage share is shown live on the boss bar.
- Dead members get their gear at respawn.

#### M3. Class balance: Jumbo is weakest; Fizzante and Elephante are strongest; Le F'ante is a "Duelist" that cannot duel

**Evidence:**

| Class | Solo win rate (human seat, n = 20) | Median payout | PvP duel win rate (stage-2 builds) |
|---|---|---|---|
| Elephante | **65%** | 1,860 | 67% |
| Filet | 55% | 1,414 | 52% |
| Ele Fonte | 50% | 883 | 48% |
| Fizzante | 50% | 920 | **80%** |
| Le F'ante | 50% | 914 | 38% |
| Ellie Fawn | 45% | 108 | 38% |
| Jumbo | **25%** | **79** | **34%** |

- With n = 20, a win rate carries about ±11 points of noise.
- Kills per minute (human): Elephante 235, Fizzante 225, Le F'ante 212, Ele Fonte 187, Filet 171, Jumbo 144, Ellie 127.
- Why:
  - Hits never crit in PvP, so Le F'ante's crit identity (`Classes.luau` passive, the Flurry card, Lucky Tusk, Crushing Blow) is worthless there.
  - The i-frames (H3) cap Ellie's 3 pellets and Le F'ante's 0.35 s thrusts to 1 hit per 0.5 s.
  - Jumbo deals 10 damage per 1.0 s, and its knockback does nothing to heroes.
  - Fizzante's 20-damage AoE lob plus the +20% area passive wins every trade.

**Fix (after H3):**

- Crits apply in PvP at half bonus (critMult − 1) × 0.5.
- Jumbo weapon damage 10 → 13, and Updraft's take-off gust gets a 0.6 s slow on heroes.
- Ellie's pellets 9 → 10.
- Fizzante's lob PvP damage × 0.8: a per-weapon `pvpMult` field in WeaponDef, with Fizzante at 0.8.

**Target:** every class at 40–60% solo win rate and 40–60% overall in the duel matrix. Re-run `duel2.luau` and the 140-match batch to check.

#### M4. Alternate abilities are mouse-only sidegrades and do not change PvP or champion play

**Evidence:**

- Per ability, TTK against a 100 HP target (`duel.luau`). The best alternates are Shaken Can (18.0 s vs Soda Geyser 23.9 s) and Fleche (24.5 s vs Riposte 26.0 s). Nine of the 21 abilities change nothing (the i-frames swallow them).
- Bots never use alternates: the Headless humans and BotRoster have no `classState`.

**Fix:**

- With H3 in place, give each alternate a PvP or objective identity:
  - shields block 100% PvP damage;
  - dashes knock rival heroes back 6 studs;
  - bursts deal ×1.5 to champions;
  - fields slow heroes by 30%.
- Bots roll alternates by their seat's class level.

#### M5. Bot opponents are always the same three classes

**Evidence:**

- `BotRoster.fillSquads` and `pickClass` use `freeClassIds()` only (`src/shared/Bots/BotRoster.luau:332`, `:430`).
- Every bot squad is Elephante + Ele Fonte + Ellie Fawn (seat dump, seeds 1–3). A solo player meets the same 9-hero composition every match and never sees Fizzante, Filet, Le F'ante or Jumbo as rivals.

**Fix:** bots pick from all 7 classes, still covering roles (tank / ranged / support), with locked classes weighted 0.5. Bots also roll alternates.

#### M6. Pressure means little in a 12-player PvP server and is imposed on strangers

**Evidence:**

- The earliest-joined player's board applies to the whole server (`src/server/Services/LobbyService.luau:40-45`).
- The handoff log for 2026-11-16 shows Pressure no longer separates win rates (6/7/7 of 16). PvP at champions decides matches, and Pressure only changes mice and bosses, which are a small share of the danger (H2).

**Fix:** make Pressure a **squad** choice: the "Heat" of a party.

- It scales only that squad's local mice spawns, elites and its share of champion HP.
- It pays that squad +8% cheese per point.
- The squad is shown with a 🔥N badge.
- Public servers default everyone else to 0.
- Pressure badges and leaderboards stay per squad.

#### M7. Champion pacing: too many unfinished champions early, too easy late

**Evidence (Solo, full stages):**

| Stage | Champions spawned | Champions killed | Median fight (p25–p75) |
|---|---|---|---|
| 1 | 4.18 | 1.84 | **35.4 s** (26–46) |
| 2 | 4.22 | 2.05 | 22.9 s |
| 3 | 4.53 | 3.13 | 14.7 s |
| 4 | 4.33 | 3.60 | 13.3 s |

- In stage 1, 56% of champions leave unkilled.
- In Full12 (human stand-ins), only 0.42 are killed per stage, with 60 s fights.
- By champion: Golem is slowest (31 s median, p90 63 s), Rat King fastest (14.5 s).
- Late fights are short because heroes are levels 15–23. The `HP_WAVE_GROWTH` of 2.5 follows wave time, not hero power.

**Fix:**

- Stage 1: `FIRST` 25–35 → 35–45, and at most 2 alive.
- Champion HP × (1 + 0.05 × (average hero level − 8)), clamped to 0.85–1.6.
- Golem HP 1,500 → 1,250.
- **Target:** a 20–30 s median fight in every stage.

#### M8. Bosses: the final boss is a 12 s anticlimax

**Evidence:**

| Stage | Median boss time (p90) |
|---|---|
| 1 | 38.0 s (69.7) |
| 2 | 37.5 s (80.8) |
| 3 | 16.1 s |
| 4 | **12.2 s** |

- Boss HP scales with the party weight per squad (`Stats.worldMods`, `bossHpPerExtraPlayer`), not with how many squads are fighting. So 12 heroes in stage 1 face the same pool as 3 heroes in stage 4.

**Fix:**

- Boss HP × (0.55 + 0.15 × heroes standing at spawn ÷ 3 squads' worth).
- Stage 4: × 2.5 with a third phase.
- **Targets:** 40–60 s fights in stages 1–3 and 60–90 s on the final boss.

#### M9. The safe corner is a dominant turtle spot for cautious squads

**Evidence:**

- Inside your own corner you take −60% PvP damage, all stage long (`World.SAFE_ZONE_REDUCTION`, `src/shared/Combat/World.luau:144`).
- In Party3 and Full12, the all-human squads (stand-ins with no bot leader) spent **50–52% of wave time at 0.9–1.0 R**. They took 8–9% of champions and showed 41–44% idle.
- Also a sim gap: `IntegrationSquads` only covers the solo case, so the pacing targets say nothing about full lobbies.

**Fix:**

- The safe zone lasts 40 s after drop-in (the storm replaces it; see below).
- Add a Party3 / Full12 variant to the integration specs, with a "human leads" stand-in.

### LOW

#### L1. Gear is a lot of pickups for little effect

**Evidence:**

- Gear numbers are small next to cards (`src/shared/Config/Gear.luau`):

  | Legendary gear | Common card |
  |---|---|
  | War Drum +12% damage (`:317`) | Heavy Hitter +35% per stack |
  | Rind Plate +35% HP | Thick Hide +50% |
  | Rapid Tusks +30% attack speed | Rapid Fire +35% |

- Weapon mods (pierce, chain, explode) do nothing to heroes and little to champions.
- 15–26 pickups per stage across the server, each a possible 4 s swap prompt. Gear is lost at run end.

**Fix:**

- Double stat values at Epic and Legendary.
- Give each Legendary a unique effect (for example, Cheddar Rounds Legendary: burn spreads to 2 nearby foes; Bark Hide Legendary: the first PvP hit every 5 s is ignored).
- Auto-equip only an upgrade of the same slot, and show the compare as a non-blocking chip.

#### L2. Card variety and feel

- 37 cards, only 7 of them class-specific (1 per class).
- About 10 cards are dead in PvP and against bosses (pierce, chain, explode-on-kill, knockback, pickup, crit for heroes).
- Levels are front-loaded (5.8 per hero in stage 1, about 2 per stage after), plus a spike of +8 levels in stage 4 from champion XP (`XP_BY_STAGE` 90/180/300/450) when there is little left to use them on.
- **Fix:**
  - Add 2 more class cards per class, each tied to the alternate ability.
  - Change `XP_BY_STAGE` to 90/150/200/240.
  - Offer 1 "objective" card per stage (×1.3 damage to champions / the boss, channel speed).

#### L3. Sprint ignores rival heroes

`World._updateSprint` only checks the mouse hash (`src/shared/Combat/World.luau:1852`). You can sprint right up to an enemy squad: the "no enemy within 18 studs" in GDD §4a does not hold. **Fix:** include enemy heroes in the 18-stud check.

#### L4. Downed finish and loot bags

- 6 downed hits at 0.5 s i-frames is ≥ 3 s per finish, while the finisher stands still and the bag channel takes another 1.5 s.
- **Fix:** with H3's per-attacker lockout, keep `DOWNED_HITS` 6 but let each attacker count. Then 3 attackers finish in about 1 s, and a lone attacker in 1.5–3 s.

#### L5. The gate window is dead time with PvP on

After the boss: up to 4 s clear, then up to 15 s route choice, then up to 20 s extraction. That is up to 39 s with no mice. Both vote windows end early once everyone has voted (`RunDirector.luau:2436` and the extraction window's `allExtractVoted`), which helps. **Fix:** a 3 s Extract channel inside the gate (see the storm section) gives the window a job.

---

## Pacing summary (current live build)

**Per stage:** waves 150 s, then the boss (median 38 s in stages 1–2, 12–16 s in stages 3–4), then stage clear 4 s, route choice ≤ 15 s, extraction ≤ 20 s, portal 1.5 s. That is about 200–230 s per stage and about 13–15 minutes per full run.

**First PvP down:** median 53–56 s into stages 1–3 (Solo). In Full12 it is 164 s in stage 1.

**Levels per hero:**

| Stage | Levels gained |
|---|---|
| 1 | 5.8 |
| 2 | 2.4 |
| 3 | 2.1 |
| 4 | 1.7 |

The human's level at each stage start is 1 / 8.8 / 15.2 / 23.1.

**Where heroes stand:** 0.3–0.5 R holds 40% of hero time, and 0.8–1.0 R only 7% in Solo. The outer POI ring (0.65–0.86 R) is underused.

**Party3 / Full12 vs Solo:** human squads reach stage 4 in 9 of 12 and 12 of 12 matches (Solo: 45 of 140). They kill far fewer champions (0.4 per stage in Full12) and idle 41–44% of the time. The game in full human lobbies depends on players choosing to hunt.

---

## The planned change: bigger maps, smaller each stage, plus a closing storm

**Assessment.** On its own, "much bigger maps" makes H2 worse: today's maps are already 42–59% sprinting and 24% long idle. **The storm is what makes bigger maps work.** It turns travel into a decision (rotate early for outer loot, or late and pay), squeezes the density back up, and forces squads into contact at the end of every stage, which also fixes H1's empty late stages if reinforcements exist.

Ship the storm **together with** per-hero spawning (H2) and the PvP channel (H3). Otherwise the storm only gathers squads to stalemate in the centre.

### Map radius per stage

About −13% per stage, matching the expected number of squads:

| Stage | Radius (plains-size map; today 350) | Expected squads |
|---|---|---|
| 1 | 480 | 4 |
| 2 | 420 | 3 |
| 3 | 360 | 2+ (with H1) |
| 4 | 310 | 2 |

Do not go past ×1.4 of today on stage 1. The corner-to-centre walk is then about 430 studs, which is 21 s sprinting.

### Storm schedule (waves 150 s; stage 1 may use 165 s)

| Wave time | Storm | Circle (fraction of R) |
|---|---|---|
| 0 s | drop-in; Circle 1 shown on the minimap | edge |
| 30–60 s | Circle 1 closes; the safe corners turn off at 30 s | → 0.65 R |
| 60–85 s | hold; Circle 2 shown | 0.65 R |
| 85–110 s | Circle 2 closes | → 0.40 R |
| 110–125 s | hold; Circle 3 (the boss ring) shown | 0.40 R |
| 125–150 s | Circle 3 closes | → 0.22 R |
| Boss | hold; if the boss is still alive at 90 s, close to 0.12 R over 30 s (this replaces the 120 s enrage as the anti-stall) | 0.22 → 0.12 R |
| Extraction window | hold | 0.22 R |

- **Centre:** concentric on the origin in stages 1–2. In stages 3–4, the final centre is offset by up to 0.12 R (random, announced with Circle 1), and the boss spawns at the final centre.
- **Closing speed** is at most 5.6 studs/s on R = 480, so any hero can always outrun it at walking speed (16).

### Storm damage

Each tick is 1 s, outside the current circle:

| Phase | Damage per tick |
|---|---|
| Circle 1 | 2% max HP + 2 |
| Circle 2 | 4% max HP |
| Circle 3 / boss | 8% max HP |
| Boss squeeze | 12% max HP |

- It ignores armor, dodge and i-frames, and it does **not** set `iframeUntil` or `lastHurtAt`. So it does not interrupt POI channels or sprint, and it does not block PvP hits.
- It gives no kill credit. A storm down counts as a mice down, with the assist window kept.
- Downed heroes outside the circle lose downed time twice as fast.
- At 4%/s a full-HP hero lasts 25 s. That is enough to finish a channel and run, and too little to camp.

### How the storm interacts with the rest of the stage

**Mice.**
- No spawns outside the current circle; strays outside it are recycled.
- With per-hero density targets (H2), the shrinking area raises contact naturally.

**Champions.**
- When a circle is announced, sites outside it are disabled.
- The middle ring (0.42–0.5 R) sits inside Circle 1 and outside Circle 2. So regular champions live from about 30 to 85 s and act as the mid-game draw.
- After 85 s, only the Lairs (0.2–0.25 R, inside Circle 3) are active. Move `LAIR_AT` from 55 / 95 to 70 / 112, so the lair fights become the late-stage climax every squad converges on.
- A champion overtaken by the storm leaves after a 5 s telegraph, with no reward. Clamp the leash to the circle.

**POIs.**
- Outer ring (0.65–0.86 R), live only before about 60 s: Armory Crates, Caches and **one Cheese Vault, announced at 15 s**. This rewards the early rotation gamble.
- Middle ring (0.28–0.42 R): Power Totems, contested from 85 s.
- Shop Cart near the centre, opening at 110 s.
- Elite Camps outside the current circle do not wake.

**Safe corners.** They work only until 30 s, then the storm owns the map. `DROP_PROTECT` stays 9 s.

**Boss.**
- The final circle (0.22 R ≈ 105 studs at R = 480, 68 at R = 310) is the boss arena, so every surviving squad fights in one space.
- Use M2's top-damage rule. Otherwise the converge-and-last-hit dynamic gets worse.

**Extraction.**
- The Rind Gate opens at the centre of the final circle for 20 s with PvP live.
- Squads that vote **Extract** must channel 3 s inside the gate (radius 6), and the channel is interrupted by damage. The vote alone does not extract.
- A squad that fails the channel is treated as Stay.
- This puts the extract-or-greed tension into play instead of a menu. DoN squads are marked (M1), so third parties have a target.

**Bots.**
- When the next circle is announced, or whenever outside the circle, bots path to the nearest point inside it with 15 studs of margin.
- Champion and POI seeking ignores targets outside the next circle.
- Low-HP bots outside the circle prioritise getting in over fleeing.

### Tests to add

1. **IntegrationStorm**, Solo + Full12, 24 seeds. Guards:
   - idle (nothing in reach) < 15% of wave time for every class;
   - longest idle streak < 20 s;
   - first PvP down after 45 s in stage 1;
   - squads at stage-3 start ≥ 2.0;
   - champions killed ≥ 2.5 per stage;
   - storm deaths < 10% of all downs.
2. The PvP TTK matrix (`duel2.luau` as a spec): even-level 1v1 TTK 6–9 s, and no pairing above 20 s.

---

## Top 10 changes that would most improve fun

1. **Spawn mice per hero, not per server.** Density target: 8–14 mice on screen per hero, 0.9/s per hero ramping ×3.2, 28 per hero, global cap 300. Mouse HP follows the average hero level. This removes the 24% long-idle time and the empty stage 4 (H2).
2. **A real PvP damage channel.** Per-attacker 0.25 s lockout instead of the shared 0.5 s i-frames, armor × `PVP_MULT` in PvP, regen paused 3 s after PvP damage, `PVP_MULT` 0.35. Target TTK 6–9 s for 1v1 and 2.5–4 s for 3v1 (H3).
3. **Keep the late game populated.** Bot squads never extract before the stage-2 gate (`EXTRACT_POT` 330 / 420 after that). Add one 🤖 Rival Herd reinforcement when at most 1 squad is left. Set `LAST_HERD_STAGES` to 1 (H1).
4. **Ship the closing storm with the per-stage shrink:**
   - radius 480 / 420 / 360 / 310;
   - circles at 0.65 / 0.40 / 0.22 R, closing at 30–60, 85–110 and 125–150 s, plus a boss squeeze to 0.12 R;
   - damage 2 / 4 / 8 / 12% max HP per second, which interrupts nothing;
   - safe corners off at 30 s;
   - champions on the middle ring early and lairs at 70 / 112 s;
   - a 3 s Extract channel at the gate.
5. **Instant Play Again.** Teleport out players (and their party) to a fresh server straight away instead of making them wait 10–12 minutes in the lobby (H4).
6. **Secured cheese.** 25% of champion, vault and boss rewards bank instantly, plus a 40-cheese floor per stage reached. Wipes then pay something: today the median is 42 vs 2,566 for a win (H5).
7. **Reward damage, not the last hit.** Champions and the boss go to the top-damage squad, with a 50% "Snatch" bonus for a different killing blow. Dead members still get their gear (M2).
8. **Rebalance the classes for PvP.** Half crit bonus applies to heroes (Le F'ante), Jumbo 10 → 13 damage plus a slow on Updraft, Ellie 9 → 10, Fizzante PvP × 0.8. Bots use all 7 classes and their alternates (M3, M5, M4).
9. **Make Double or Nothing a true ×2** that needs survival **plus** a champion or boss kill, with DoN squads marked on the map. Together with items 3–4, the stage-2 and stage-3 gates become real decisions again (M1).
10. **Tune champions and bosses to the fight that is actually happening.** Champion HP follows hero level (target 20–30 s fights; stage-1 first spawn at 35–45 s, at most 2 alive). Boss HP follows the heroes present, and the final boss gets ×2.5 and a third phase (target 60–90 s). Make Pressure a per-squad "Heat" choice instead of a server-wide board set by the first player to join (M7, M8, M6).
