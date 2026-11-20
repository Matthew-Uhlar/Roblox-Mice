# Iteration 3: Playtest and research report

**Team:** Playtest + Research (read-only on `src/`; this file is our only repo output). **Date:** 2026-11-20. **Build:** `claude/focused-gates-jihpzi` at `9925a19` (iterations 1 + 2, = `origin/main`, profile v7).

**Owner goals we tested against:** Zombie World Liberty on a larger map with objectives and squad PvP; progression and gameplay on Liberty's model (`docs/research/zwl-save-model.md`); much more intricate, smoother graphics and animation.

## How we played

All scripts, logs and PNGs are in `/tmp/claude-0/-home-user/62ecd08e-82c1-5cab-a26b-5e0b2b23913e/scratchpad/iter3/`.

- **Runtime emulator (real server + client scripts, default timings).** We ran 10 full matches with `match3.luau`, a driver extended from iteration 1.
  - **What the driver does:**
    - It walks like a person (champions, then POIs, then the nearest mice), casts its ability and takes level-up cards in the real UI.
    - It opens the **V menu** every 4 s and clicks the cheapest affordable rank button.
    - It presses the **📯 Early Horn** pill whenever it is shown.
    - It walks to the **Swap Stand** or a **whey stall** and clicks the popup (`addon2.luau`).
    - It picks a ladder tier with the lobby **▶** button.
    - It answers the Rind Gate per profile.
  - **Profiles:**
    - Rookie on PC: `rookie_a`, `_d` (no manual horn), `_f` (careful), `_i` (stalls), `_j` (whey and Altar probe).
    - Phone rookie: `phone_e`, touch at a 667×317 safe area.
    - **Veteran migrated from a live v6 save** (`vet.luau`): 320 runs, level 42, 7 classes, Elephante L30 with 6 Mastery Stars, Filet L30 with 2, Jumbo L22, Pressure unlocked with `highestCleared = 14`. Matches: `veteran_b` (Smoked), `_c` (Medium), `_g` and `_h` (Extra Sharp).
  - **Result: 0 script errors and 0 emulator gaps in every run.**
- **Lobby and menu walkthroughs** (`lobby3.luau`) for rookie, veteran, phone and veteran-on-phone:
  - Hero screen (all 4 tabs), Gems, Ladder, Horn, ◀ ▶, and the Herd tabs (Challenges, Levels, Boards, Mousepedia).
  - `gems3.luau`: a profile holding 4 gems, run through equip, upgrade and salvage.
  - `prest.luau`: Prestige through the real button.
  - `t_tier.luau`: which tier the server really uses.
- **Sims:**
  - `tests/sim/v4-report.luau 24`.
  - Our ladder sweep `ladder.luau`: Headless, solo human + 11 bots, 8 seeds per tier for all 11 tiers, plus Medium and Sharp with the horn Off.
  - Our **veteran meta stand-in** `meta.luau`: the human's squad gets a real `RunBonus` (Prestige, all 8 nodes, perfect +5 gems) through `Stats.compute`'s 7th parameter, which is the "P40 + gems" row that `IntegrationDifficulty` does not have yet.
  - `tests/specs/IntegrationDifficulty.spec.luau` (run alone).
- **Renders:** we ran `scripts/render-preview.luau` + `.py` into the scratchpad and read the PNGs, together with the committed `assets/previews/*.png` from 2026-11-19 (heroes, asc, gems, bot_poses, boss_poses, champions, mice, pois, lobby, maps). We also made a contact sheet of the 56 `assets/ui` textures.
- **Caveat:** the emulator's GUI geometry ignores UIListLayout and real text metrics, so the phone layout items are marked **verify on device**.

### Headline numbers

| Source | Result |
|---|---|
| Ladder sweep: fresh solo, clears out of 8 per tier, 1 → 11 | **6, 5, 8, 6, 5, 5, 6**, then 2, 3, **0, 0**. Moldy and Doomwheel wipe in **stage 1 every time** (average match 91 s and 72 s). |
| Meta stand-in (6 seeds each) | P40, all 8 nodes and **9 perfect +5 tier-11 gems** on Doomwheel: **0/6** (stage-1 wipes). P20 + 3 tier-10 gems on Moldy: **0/6**. P10 + 3 tier-6 gems on Smoked: 2/6, lower than fresh (5/8). |
| Horn On (the default, 70 %) vs Off | Rinds per match: Medium **11.2k vs 25.6k**, Sharp **16.8k vs 36.5k**. The horn sounds on 13–16 of the 16 horde waves. |
| `IntegrationDifficulty` (12 seeds) | Medium 9/12, Sharp 3/12, Doomwheel 0/12. It passes, with a `[BALANCE]` warning on Sharp. |
| `v4-report` (24 seeds) | Wins 17, wipes 7. Idle **37.1 %** (p75 53.8 %). Whey median **901 per 4-stage match**. Herd Call 1 redeploy of 7 timers. Double or Nothing paid 0 and lost 0. High route 13 %. |
| Runtime damage taken by the human | Enemy-hero PvP **311–2,620** per match vs mouse contact **115–313**. A rookie was downed 22 times by bots in one match. |
| Runtime phase time (horn on) | Boss phases are longer than the hordes: 345 s vs 185 s, 269 vs 172, 352 vs 243. |

---

## Entries

### T-1: The Early Horn HUD shows "4600 % / 7000 % stomped", and its "ready" check is wrong
- **Type:** bug · **Impact:** H · **Effort:** S · **Owner:** U (contract with M2)
- **Evidence:**
  - Runtime text dumps, every veteran match: `📯 1000% / 7000% stomped`, `📯 4600% / 7000% stomped` (8 distinct values seen).
  - `RunDirector.matchPayload` sends `horn.stomped` as an integer **percent** (`floor(stomped*100+0.5)`) and `need = c.skipWaveAt` (70). `LadderModel.horn` treats them as fractions, and CombatHud prints `frac*100`.
  - `ClientIter2.spec` tests the wrong shape: `{stomped = 0.72, need = 0.7}`.
  - The client's own "ready" (`frac >= need`) also ignores the server's 10 s minimum and late-wave rules. The player gets a "📯 Call the next wave!" pill, and tapping it brings the server's "Stomp half of this wave first (and give it 10 s)" toast. That toast appeared more than 20 times in `veteran_b`.
- **Proposed change:**
  - Normalise in `LadderModel.horn`: values above 1 are percents.
  - Use only `h.ready` from the server for the ready state.
  - Rewrite the spec on a real `matchPayload` table.

### T-2: The difficulty ladder doesn't climb: tiers 1–7 barely differ, and 10–11 are walls nobody can clear
- **Type:** balance · **Impact:** H · **Effort:** M · **Owner:** M1 (numbers), M2 (sim guard)
- **Evidence:**
  - Ladder sweep, clears out of 8, fresh level-1 solo with bots: Mild 6, Medium 5, **Sharp 8**, Extra Sharp 6, Aged 5, Smoked 5, **Pungent 6**, Stinky 2, Scorched 3, **Moldy 0, Doomwheel 0**. Every Moldy and Doomwheel run wiped in stage 1.
  - `IntegrationDifficulty` (12 other seeds): Medium 9/12, **Sharp 3/12**, Doomwheel 0/12. The same tier gives 25 % with one seed set and 100 % with another, so seed noise outweighs the tier step.
  - Meta stand-in (`meta.luau`): **P40 + 8 nodes + 9 perfect +5 tier-11 gems = 0/6 on Doomwheel**, and P20 + tier-10 gems = 0/6 on Moldy.
  - The stand-in's `RunBonus` is real: +80 % PvE damage, ×1.43 max HP, −10 % cooldowns.
  - Consequences:
    - Best Solo can't go above Scorched.
    - 4 Challenges (#27 Jeweler, #28 Doomwheel, #29 Doomwheel Alone, #30 Golden Wheel) can't be earned, because tier-11 and tier-12 gems only drop from Doomwheel bosses.
    - The "Wheel of Legends" frame is out of reach.
  - Liberty's ladder is a long climb with a reachable top for maxed heroes.
- **Proposed change:**
  - Re-space the presets so a fresh solo clears about 85 % → 10 % from Mild to Scorched.
  - Cut the Moldy and Doomwheel bases (about 1.6/1.4/1.2 and 2.2/1.8/1.3 instead of 2.6/2.2 and 4.0/3.2) until the stand-in hits the ALIGNMENT targets (Doomwheel 30–40 % maxed, < 2 % fresh).
  - Add the meta stand-in rows to `IntegrationDifficulty` as hard guards. A `Stats.compute` wrapper that passes `RunBonus.resolve` as the 7th parameter is enough.

### T-3: The Early Horn costs mice: horn On halves rinds, stomps and class XP
- **Type:** balance / feature · **Impact:** H · **Effort:** M · **Owner:** M1 (WaveDirector), M2
- **Evidence:**
  - Ladder sweep with the horn Off: Medium **25.6k** rinds per match vs **11.2k** with the default 70 %; Sharp 36.5k vs 16.8k.
  - The horn sounds on 13–16 of 16 waves (`horns/match`).
  - `WaveDirector` spawns at a per-second rate, so a horn just deletes the rest of the current wave. The horn pays 3 rinds per skipped second per hero, about 40 rinds, while the lost mice were worth several hundred.
  - Class XP (+0.5 per stomp) and stomps (Ascension gates) drop too.
  - In Liberty, skipping a wave stacks the next one on top: more kills per minute.
- **Proposed change:**
  - On a horn, carry the current wave's unspawned budget into the next wave as an immediate front ("waves stack").
  - Add a sim guard: horn On must earn **≥** horn Off rinds per minute.
  - Keep the 3 rinds/s as a bonus.

### T-4: Bot squads, not mice, are what kill humans, and they camp a downed rookie
- **Type:** balance / fun · **Impact:** H · **Effort:** M · **Owner:** M1 (BotBrain), M2
- **Evidence:**
  - Human damage by source in runtime matches (`hero:pvp` vs mouse `contact`):
    - `veteran_c` (Medium): 840 vs 115;
    - `veteran_b` (Smoked): 979 vs 727;
    - `veteran_g`: 866 vs 244;
    - `rookie_d`: 728 vs 219, eliminated by bots in stage 3;
    - `rookie_f`: **2,620 vs 287**.
  - In `rookie_f` (run 0, Mild), the human was downed **22 times**, by bots −1012 and −1013, **every ~8 s** from t = 495 to 616 during the final stage.
  - Rookie safety ends at stage 2 (`BotBrain.ROOKIE_STAGES = 2`).
  - A PvE-ladder game where a Mild rookie's main threat is bots doesn't feel like Liberty, where PvP is the spice.
- **Proposed change:**
  - Bots don't target humans on tiers ≤ Sharp, or a rookie's squad for the whole of runs 0–2.
  - A revived or redeployed hero is not a bot target for 10 s.
  - Per-human bot "aggro budget" (at most one bot attacker at a time).
  - Sim guard: bot PvP is less than 40 % of human damage on tiers ≤ 3.

### T-5: The Results class-XP bar uses the old XP curve and shows the wrong level
- **Type:** bug · **Impact:** H · **Effort:** S · **Owner:** U
- **Evidence:**
  - `rookie_a` Results: `Elephante · +46 class XP | LV 1 | 46 / 100 XP`, while the toast and the saved profile say **level 2** (first-match guarantee; the new curve's level 1 → 2 costs 70).
  - `ResultsUI` uses `ClassMath.xpToNext` = `floor(100·n^1.4)`, the v6 curve. ClassProgress uses `70·l^1.35`.
  - Every non-prestiged player's bar and level-up animation is off on every match.
- **Proposed change:**
  - Take `xpToNext` from the profile view (`classes[id].xpToNext`), or mirror the new formula in `ClassMath`.
  - Apply the first-match level-2 bump in the "after" state.

### T-6: The leaderboards show raw keys, and Best Solo shows an encoded number
- **Type:** bug · **Impact:** M · **Effort:** S · **Owner:** U (P for the decode)
- **Evidence:**
  - Herd → Boards for the veteran: `bestSolo`, `bestSquad`, `bestStage`, `championKills`, `fastestCycle1`, `heroDowns`, `lastHerd`. Only "🐭 Most Stomps" and "🏆 Most Wins" are labelled.
  - `ProgressUI.BOARD_NAMES` lacks the rest.
  - `LeaderboardService` stores Best Solo as `tier×100000 + (99999−s)`, and the UI prints that integer, e.g. "1,099,500".
  - Best Solo is Liberty's headline record (`Primary.BS`).
- **Proposed change:**
  - Labels for all 9 boards.
  - Decode Best Solo as "Smoked · 12:34" (the row already gets `tier`).
  - Order: Best Solo, Best Squad, Stomps, Wins, then the rest.

### T-7: For veterans with a saved Pressure board, the lobby card shows a different tier from the one the server plays
- **Type:** bug · **Impact:** H · **Effort:** S · **Owner:** U, M2
- **Evidence:**
  - We gave a v6 veteran `pressure.board = {stampede=2, big_cheese=2}` (live v6 profiles keep their board).
  - `LobbyService.getDifficulty()` → **0 (Custom)**, and the Lobby payload has `ladder.name = "Custom"`, effective Sharp, reward ×1.2.
  - The lobby card shows **"Tier 2 · Medium · Reward ×1 · gems tier 2"**, plus the legacy line "🔥 Pressure 4 · +32 % 🧀 cheese · +0.20 luck". That reward no longer exists, because tier rewards replaced it.
  - `currentTier`: "a leader who set a Pressure board and never picked a tier plays it as Custom".
- **Proposed change:**
  - Pick one of:
    - Show a real "Custom" tile with its effective tier and reward.
    - (Our preference) Ignore a stale v6 board until the player opens Custom.
  - Remove the old Pressure reward text.

### T-8: The chosen tier isn't saved, so every new server and every Play Again goes back to Medium
- **Type:** UX / retention · **Impact:** H · **Effort:** S · **Owner:** P (setting), M2 (LobbyService)
- **Evidence:**
  - `LobbyService.onSetDifficulty` stores `e.tier` on the per-server lobby entry only ("remembered; applies while this player leads").
  - Play Again teleports to a fresh server.
  - The migrated veteran (8 tiers unlocked) starts on "Tier 2 · Medium" and needs 6 clicks on ▶ before every match.
  - Liberty players replay their farming difficulty over and over.
- **Proposed change:**
  - Persist `settings.tier` (P; SetTier saves it), clamped to the unlocked tier.
  - Default new veterans to their highest cleared tier.
  - Show "Last played: Smoked".

### T-9: Challenges go to the whole squad; "Snatcher" was done in 3 of 7 matches, once while knocked out
- **Type:** bug / balance · **Impact:** M · **Effort:** S · **Owner:** M2 (flags), P
- **Evidence:**
  - "✨ Challenge complete: Snatcher!" ("Land the killing blow on a boss another squad led") appeared in `rookie_a` (first match ever, **spectating** after being knocked out; the bot squadmates landed the blow), `veteran_c` and `rookie_f`.
  - `RunDirector`: `K.flagSquad(c, result.snatch, "snatchBoss", true)`.
  - The 30 Challenges are meant to be hard, personal one-time feats (Liberty `CLHistory`).
- **Proposed change:**
  - Flag only the human who landed the blow.
  - Audit the other per-squad flags (Lair Raider, Champion Hunter, Bounty Breaker) for "you took part" rules.

### T-10: The whey layer (stalls, Class Stall, Altar, Swap) is almost never reachable
- **Type:** balance · **Impact:** H · **Effort:** S · **Owner:** M2 (with M1)
- **Evidence:**
  - Peak whey in the veterans' 3-stage runs: **233, 267, 238, 227**. A stall buff costs **250** and the Class Stall **500**. No whey buff was bought in any veteran run.
  - The rookie's 4-stage run reached 317 whey only in stage 4 (t = 318 s); the sim median is 901 per full match.
  - The Altar costs **6,000 rinds + 600 whey**, but the peak wallet was **1.6–1.7k rinds** (`rookie_f`, `rookie_i`).
  - Challenge #14 "Altar Titan" (2 ultimates in one match) needs 12k rinds + 1.2k whey, more than a horn-on match earns in total (sim median 10.6k rinds).
  - Swap: 300 rinds → about 24 whey.
  - Probe `rookie_j`: whey rate patched 8× (1 per 3 rinds) and **no rank bought all match**. Stall buffs then work (keen, rush, leech bought), but the player ends a full 4-stage clear with **5,948 rinds**, which is still short of one Altar ultimate.
  - ALIGNMENT §3 targeted "one stall trip per stage".
- **Proposed change:**
  - Whey 1 per 10 rinds (was 25).
  - Champions and shrines pay +40 whey.
  - Buff 150, Class Stall 300, Altar 3,000 rinds + 300 whey.
  - Swap 5 : 1 with no fee.
  - Guards: about 1 buff per stage, and an Altar is affordable in stage 3 if you saved.

### T-11: Rookies are forced onto Mild, which pays ×0.75 cheese and useless tier-1 gems
- **Type:** retention · **Impact:** H · **Effort:** S · **Owner:** P, M2
- **Evidence:**
  - Runs 0–2 force Mild (`currentTier`, `isRookieHidden`). The Results show `cheeseMult=0.75` (rookie_a/d/f) and the line "⚡ Boosts and difficulty x0.75 **+-37**".
  - The rookies' gems: `{"s":[1,1,5,5,1],"t":1}` and `[3,1,2,1,4]`. The Gems screen shows "+0.3 % rinds 🦷 +0.1 % bite ❤ +0.0 % hide 🛡 -0.0 % plating 👟 +0.0 % stride".
  - A new player's first three runs pay *less* than Medium, and their first "loot" is visibly worthless.
- **Proposed change:**
  - Mild reward 1.0 for rookies (or keep 0.75 and pay a matching rookie bonus).
  - Rookie gem drops roll at least tier 2 with the top-half roll.
  - Fix the "+-37" sign formatting (ResultsModel).

### T-12: The Results screen has no Liberty loot moment and mixes currencies with XP
- **Type:** UX / retention · **Impact:** H · **Effort:** M · **Owner:** U (P sends the data)
- **Evidence (Results text):**
  - Missing: a gem card (5 rolls, unique, Equip / Salvage), "Tier unlocked", "New Best Solo", and challenge progress. ALIGNMENT §3.7 asked for all of these, but `ResultsUI` has no gem or challenge code. A gem shows only as a toast ("✨ New Aged gem (tier 5)!").
  - The Smoked ×2.0 reward reads as "⚡ Cheese bonus ×2 (boosts / passes / talents)".
  - Pass XP, Class XP and Account XP are listed with 🧀 icons inside the cheese total.
  - A rookie who extracted after stage 1 (and got the first-extraction bonus) reads "Brie · **4th of 4 squads**".
- **Proposed change:**
  - Add a "Loot" column (gem card, dust, challenge ticks, tier unlock, Best Solo).
  - Name the tier ("Smoked ×2.0").
  - Separate XP from cheese.
  - Show "Extracted · secured X" instead of a placement for extractions.

### T-13: The core Liberty loop (V menu, horn, whey, gems) is never taught
- **Type:** UX / onboarding · **Impact:** H · **Effort:** S · **Owner:** U
- **Evidence:**
  - `Onboarding` hints cover move, attack, crumbs, ability, revive, glowing spots, rivals, gear, extract, perks and the Melt. **None** mention rinds or V (🛠 on phone), the Early Horn, whey stalls, or Gems.
  - The wallet pulse is the only cue.
  - The rookie walkthrough's lobby shows "📯 Horn: Off" with no explanation.
- **Proposed change:** add 4 hints:
  - "🔶 Rinds! Press V (🛠) to buy upgrades that last the run" at the first affordable rank;
  - "📯 Stomp 50 % then call the next wave";
  - "🥛 Whey buys strong buffs at stalls";
  - "💎 You found a gem: equip it in 💎 Gems (boosts your squad)".

### T-14: Prestige has no celebration; the only feedback is "⬆ Level 1"
- **Type:** UX · **Impact:** M · **Effort:** S · **Owner:** U, P
- **Evidence:**
  - `prest.luau`: Hero → Fizzante (L30, P0) → Prestige → "Sure?". The only toast is **"⬆ Level 1"**. The lobby reads "Fizzante ⭐1 Lv 1".
  - The reward (300 cheese + 10 Golden Cheese, `PRESTIGE_REWARD`) is not shown, and neither is the new frame or the unlocked Ascension node 1 ("✔ 1 · Thick Skin").
  - Prestige is Liberty's main long-term beat.
- **Proposed change:**
  - A Prestige toast or banner: "⭐ Prestige 1! +1 perk point, +0.5 % damage, +300 🧀 +10 ✨, Ascension 1 unlocked".
  - Suppress the level-up toast on a Prestige reset.

### T-15: Migrated veterans see their level drop (L30 ⭐6 becomes "Lv 13")
- **Type:** UX / retention · **Impact:** M · **Effort:** S · **Owner:** P, U
- **Evidence:**
  - v6 Elephante L30 with 6 stars and starXp 5,000 shows **"⭐6 · Level 13"** in the lobby, the Hero screen and the nameplate: `displayLevel = 1 + floor(5000/12000·29)`.
  - The Hero screen says "⭐ Prestige 7 · Reach level 30 first (now 13)".
  - The join toasts explain stomps and level growth, but not this.
  - A long-time player reads this as a downgrade on the day of the update.
- **Proposed change:**
  - A one-time card: "Your 6 Mastery Stars are now ⭐6 Prestige. Your level shows progress to ⭐7 (13/30). Nothing was lost."
  - Or show "Lv 30 ⭐6 · 42 % to ⭐7" until the first new Prestige.

### T-16: Rind gifting exists on the server but players can't use it
- **Type:** feature · **Impact:** M · **Effort:** S · **Owner:** U
- **Evidence:**
  - `Net.C2S.GiftRinds` and `K.onGiftRinds` (100 rinds to a human squadmate) are wired.
  - `grep -rn Gift src/client` finds nothing; no UI fires it.
  - Team-play pillar from ALIGNMENT §3 ("send minerals").
- **Proposed change:** add a "🎁 100" button on human squadmates in the HUD squad panel and on phone, with a 2 s cooldown.

### T-17: Two difficulty systems on one lobby card, and the blurbs are jargon
- **Type:** UX · **Impact:** M · **Effort:** S · **Owner:** U
- **Evidence:**
  - Veteran lobby: the ladder card **and** "🔥 Pressure 0 · Off. You're the leader: stack modifiers for more rewards! · Edit board".
  - The Ladder panel blurbs read "Pressure 3.", "Pressure 5.", … "The full Pressure board.". New players never meet Pressure.
  - PLAN said "Pressure stays as an advanced Custom option".
- **Proposed change:**
  - Move the board behind a "Custom" tile (unlocked after Sharp).
  - Blurbs say what changes, e.g. "Faster mice, elite packs" or "Tough champions, angry bosses".

### T-18: The "20 waves" are short warm-ups before long boss fights
- **Type:** balance / pacing · **Impact:** M · **Effort:** M · **Owner:** M2, M1
- **Evidence:**
  - Wave starts (veteran_g): w1 at 2 s, w2 at 16, w3 at 30, w4 at 46, w5 (boss) at 61. With the horn, a horde wave lasts about 14–16 s.
  - Phase time per match:
    - Boss **345 s** vs Waves **185 s** (veteran_b);
    - 269 vs 172 (veteran_c);
    - 198 vs 171 (veteran_g);
    - 352 vs 243 (rookie_f).
  - The rookie spent most of the stage-1 boss knocked out and spectating (rookie_a).
  - Liberty's identity is wave after wave.
- **Proposed change:**
  - Horn minimum 15 s and lull 6 s.
  - Boss waves keep a real trickle, and the boss time limit drops from 180 s to 120 s.
  - Target: hordes ≥ 55 % of stage time (sim guard).

### T-19: Idle time is still far above target
- **Type:** balance · **Impact:** M · **Effort:** M · **Owner:** M1
- **Evidence:** `v4-report`: idle **37.1 %** of wave time (p75 53.8 %, longest streak 36 s). Runtime: 18–37 % (rookie_i 35 %, rookie_f 37 %). The target in ALIGNMENT / PLAN is ≤ 20 %.
- **Proposed change:**
  - Fronts aim at the humans' squad first.
  - Minimum density within 40 studs of each standing human.
  - Measure with the same "no mouse within 30" metric.

### T-20: Gems are too weak to chase
- **Type:** balance · **Impact:** M · **Effort:** S · **Owner:** P (Config/Gems), M1
- **Evidence:**
  - The Gems screen: a **perfect +5 tier-11 gem = +9.0 % bite, +3.5 % hide, −2.2 % plating, +1.5 % stride**; a tier-6 +2 = +1.3 % bite.
  - The meta stand-in (T-2) shows 9 such gems don't move a clear.
  - In Liberty, jewels are the end-game power chase (a tier-14 jewel at 2000/200/200/200/200).
- **Proposed change:**
  - Triple `POINT.bite` and `POINT.hide`.
  - Make uniques the stars (e.g. "+1 projectile" for every squad member, and "×2 damage chance" at 20 %).
  - Re-run the T-2 stand-in to fit.

### T-21: Gem stat names are jargon and "Plating" reads as a penalty
- **Type:** UX · **Impact:** L · **Effort:** S · **Owner:** U
- **Evidence:**
  - "🦷 Bite · ❤ Hide · 🛡 **-2.2 % plating** · 👟 Stride" has no tooltip, and the negative number reads as a malus.
  - The unique name overflows on PC: "💎 Tier 9 Scorched Amber gem · Stampede Heart: …" needs about 533 px in 250 (verify on device).
- **Proposed change:**
  - Use plain words: "+9 % damage to mice", "−2 % damage taken".
  - Put the unique on its own line.

### T-22: Phone players can barely use the V menu and the horn (verify on device)
- **Type:** UX / phone · **Impact:** M · **Effort:** S · **Owner:** U
- **Evidence (phone_e, 667×317):**
  - V menu tabs, rows and rank buttons at **10.4 px** text.
  - The 📯 horn pill is **17 px** tall; the wallet pill that opens the V menu is **14 px** tall; "Auto: off" is 15 px.
  - The Altar popup is at 10.4 px.
  - The lobby "Tier 1 · Mild" label overflows (needs 82 px, has 51).
  - Liberty's kill-buy rhythm lives in this menu.
- **Proposed change:**
  - Raise phone touch targets to ≥ 44 px (wallet and horn).
  - V menu text ≥ 14 px with 2-column rows.
  - Shrink the tier label to "Mild" with the number as a badge.

### T-23: "⚠ OUTSIDE THE MELT!" shows while you are knocked out and spectating
- **Type:** bug · **Impact:** L · **Effort:** S · **Owner:** U
- **Evidence:** rookie_a Boss@1 and Results dumps: `👀 Spectating Squeaky 🤖 | ⚠ OUTSIDE THE MELT! Get inside the circle` (the camera follows a mate, but the warning uses the dead hero).
- **Proposed change:** hide the warning while spectating or out.

### T-24: The Hero screen shows the generic Ascension text, not the class's own nodes
- **Type:** UX · **Impact:** L · **Effort:** S · **Owner:** U
- **Evidence:**
  - Every class shows "3 · Extra Edge: Weapon +1 projectile, pierce or arc" and "4 · Matriarch: class passive doubled" (from `Config/Ascension`).
  - `Config/AscensionNodes` has the class versions: Elephante node 3 = +15 % area, node 4 = ×1.25 max HP; Le F'ante node 4 = +15 % crit.
- **Proposed change:** build the node rows from `AscensionNodes.node(classId, n)` with concrete numbers.

### T-25: Prestige XP is lost past the bank cap and at the first Prestige
- **Type:** balance · **Impact:** L · **Effort:** S · **Owner:** P
- **Evidence:**
  - `addPrestigeXp` caps the bank at 2 × 12,000.
  - `doPrestige` at P0 keeps at most 11,999 (`carry` clamped).
  - A level-30 P0 player who keeps playing banks up to 24k but leaves with 12k, which is one Prestige lost. The only cue is the `prestigeReady` toast.
- **Proposed change:**
  - Allow multi-Prestige ("Prestige ×2"), or keep the full bank.
  - Pulse the Hero button while a Prestige is ready.

### T-26: Boss death collapse rotates the ground ring, and the boss poses barely differ
- **Type:** graphics / animation · **Impact:** M · **Effort:** M · **Owner:** G
- **Evidence:**
  - `assets/previews/boss_poses.png`: in the "dead" column every boss tips over **together with its ground disc**, which stands upright like a coin (corndog_bunny, froggus, giant_tree, green_gorilla, hematite_snake).
  - Walk, wind-up, strike and roar are nearly the same frame for corndog_bunny and hematite_snake.
- **Proposed change:**
  - Keep the ring world-aligned (parent it outside the rotating root).
  - Give each boss a clear anticipation lean or crouch, a strike extension and a roar head-up, with squash and stretch.

### T-27: The Ascension looks don't read from the gameplay camera
- **Type:** graphics · **Impact:** M · **Effort:** M · **Owner:** G
- **Evidence:**
  - `heroes.png` and `asc.png`: Bull, Matriarch and Ancient differ from the base only by small tusks, side plates and a brown back shield. From the front they are almost identical.
  - These are the end-game status symbols: node 8 needs P25 and 200k stomps.
- **Proposed change:** each stage gets a bigger silhouette:
  - +8 % / +15 % / +25 % scale;
  - curved glowing tusks;
  - a cape or banner;
  - a ground aura ring in the tier colour;
  - an Ancient trail of cheese motes.

### T-28: Gem art is one shape in 12 colours, and some tiers look alike
- **Type:** graphics · **Impact:** L · **Effort:** S · **Owner:** G
- **Evidence:** `gems.png`: tiers 1 and 2, 3 and 4, and 6 and 7 are near-identical hues on the same crystal. Nothing about them reads as cheese.
- **Proposed change:**
  - 3 cuts by tier band: wedge (1–4), wheel (5–8), crown (9–12).
  - Distinct hue steps, a tier number pip, and a sparkle count that grows with the tier.

### T-29: The gameplay-camera map views are flat and empty
- **Type:** graphics · **Impact:** M · **Effort:** M · **Owner:** G
- **Evidence:**
  - Fresh renders `renders/map_volcano.png` and `assets/previews/map_plains.png`, gameplay camera: flat terrain with a voxel lava band and almost no props in frame.
  - The overviews are washed out by fog.
  - GroundScatter is client-only and not in the preview, so verify in Studio.
- **Proposed change:**
  - Mid-size landmark clusters every ~60 studs (rocks, cheese rinds, fences).
  - Path edging.
  - Include GroundScatter in the preview so the team can judge density.

### T-30: Hero and bot animations are still stiff
- **Type:** graphics / animation · **Impact:** M · **Effort:** M · **Owner:** G
- **Evidence:** `bot_poses.png`: idle, walk and attack are the same body pose for all 7 classes; only the weapon moves. No squash, stretch or anticipation is visible. The "ability" pose is the only large change.
- **Proposed change:**
  - Walk: body bob plus an ear-flap cycle and a trunk sway.
  - Attack: a 0.12 s wind-back lean and a forward stretch.
  - Hit: squash.
  - Blend with eased weights (Rig / BotAnimator).

### T-31: Challenges list polish
- **Type:** UX · **Impact:** L · **Effort:** S · **Owner:** U, P
- **Evidence:**
  - "Lone Tusk: **Le Fante**" vs the class name "Le F'ante".
  - All 30 are shown to a rookie on Mild with no hint of which are reachable now.
  - 4 are currently impossible (T-2).
  - No progress counters (e.g. "Champion Hunter 5/8").
- **Proposed change:**
  - Group the challenges by tier needed.
  - Grey out the ones above the unlocked tier.
  - Add counters for the multi-step ones.
  - Use the display name from Config/Classes.

## What still doesn't feel like Liberty (summary)

1. **The ladder:** the climb is flat through tier 7 and blocked at 10–11, even for maxed veterans (T-2).
2. **The wave rhythm:**
   - the horn removes waves instead of stacking them (T-3);
   - bosses take more time than hordes (T-18);
   - bots are a bigger threat than mice (T-4).
3. **The spending loop:**
   - rinds → V works;
   - whey → stalls and the Altar is almost dead (T-10);
   - gifting is invisible (T-16);
   - gems are too weak to chase (T-20).
4. **The reward beats:** Prestige, gem drops, tier unlocks and Best Solo have no moment on screen, and the leaderboards and Results are partly broken (T-5, T-6, T-12, T-14).
