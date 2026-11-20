# Iteration 3: Verification (T-1 … T-31)

**Method:** every entry was checked against the code at the cited lines. Several were also re-run:
- T-14 was reproduced with `scratchpad/iter3/prest.luau` in the runtime emulator.
- The ladder, meta stand-in, `IntegrationDifficulty` and `v4-report` logs were re-read, along with the PNGs `boss_poses`, `asc`, `gems`, `bot_poses` and `map_volcano`.
- The full 11-minute ladder sweep was not re-run. Its log was read instead.

No source files were edited.

**Ownership gaps in `docs/V4-PLAN.md`:** `Config/RunShop.luau`, `Config/Difficulty.luau`, `Config/Gems.luau`, `Config/Challenges.luau` and `shared/Run/Waves.luau` are not in the table.
- I assign `RunShop` and `Waves` to M2.
- I assign `Difficulty` to M1, as its comments do.
- I assign `Gems` and `Challenges` to P.

**Scale:** impact H/M/L. Effort S is under about 1 hour, M about half a day, L more than 1 day. Score = impact (3/2/1) ÷ effort (1/2/4).

## 1. Verdict table

| Id | Verdict | Reason (one line) | Impact (was → now) | Effort (was → now) | Owner |
|---|---|---|---|---|---|
| T-1 | **Confirmed** | `RunDirector.luau:741` sends `stomped` as a percent and `LadderModel.horn` plus `CombatHudUI.luau:815` treat it as a fraction. Server `ready` is OR-ed with `frac>=need`. | H | S | U |
| T-2 | **Confirmed** (Partly on "tiers 1–7 barely differ") | Moldy and Doomwheel multipliers (`Difficulty.luau:57-58`) are far above ALIGNMENT (2.6/2.2/1.3 vs 1.5/1.25/1.0, 4.0/3.2/1.5 vs 2.2/1.5/1.2). `ladder.txt` shows 0/8 and stage-1 wipes in 91 s and 72 s. Meta stand-in 0/6. The 1–7 flatness is within N=8 noise, so not proven. | H | M | M1, M2 (guard) |
| T-3 | **Confirmed** (absorbs T-18) | The horn shortens waves while the match length stays about 570 s (`ladder.txt` vs `ladder_hornoff.txt`). Rinds are 11.2k vs 25.6k. The default is 70 % for non-rookies. | H | M | M2 (Waves), M1 (WaveDirector) |
| T-4 | **Partly** | Numbers are real (`m3_rookie_f.txt`: pvp 2620 vs contact 287, `pvpDowns` 50). But squad PvP is an owner goal, so "bots never target humans on tiers ≤ Sharp" is too blunt. Rookie safety already runs through stage 2 (`BotBrain.luau:219`, `World.luau:168`). | H → M | M | M1 |
| T-5 | **Confirmed** | `ClassMath.xpToNext` is `100·n^1.4` (`Util/ClassMath.luau:23`). `ClassProgress` uses `70·l^1.35`. The bar total and level-up animation are wrong for every class. | H → M (cosmetic) | S | U |
| T-6 | **Confirmed** (one correction) | `BOARD_NAMES` has 8 keys and none of `bestSolo`, `bestSquad`, `bestStage`, `championKills`, `fastestCycle1`, `heroDowns`, `lastHerd`. Correction: the server already decodes Best Solo (`LeaderboardService.luau:290-295`), so the UI prints the tier number (`value = tier`). It does not print "1,099,500", and it drops `seconds`. | M | S | U |
| T-7 | **Confirmed** | `currentTier` returns CUSTOM for a stale v6 board (`LobbyService.luau:652`). The client card falls back to Medium (`LadderUI.luau:197`, `tiles0[t] or tiles0[2]`, with t = 0). The player is shown Medium and plays Custom or Sharp. | H | S | M2 (server), U |
| T-8 | **Confirmed** | `e.tier` lives only on the per-server entry (`LobbyService.luau:1357`). No `settings.tier` exists in `ProfileSchema`. | H | S | P, M2 |
| T-9 | **Partly** | `flagSquad` flags the whole squad (`RunDirector.luau:5692`), which is consistent with squad rewards (`snatchCheese`). Credit to a spectating squadmate is a design choice. Bots make Snatcher easy. | M → L | S | M2 |
| T-10 | **Confirmed** (one correction) | Costs match: whey per rinds 25, buff 250, class buff 500, Altar 6000 rinds + 600 whey, Swap 10:1 minus 20 % (`RunShop.luau`). Correction: whey from champions (30/60), POIs (40) and stages (50) already exists, so "+40 for champions" is not new. The peak of about 233 vs a cost of 250 is real. | H | S | M2 (RunShop) |
| T-11 | **Partly** | Mild ×0.75 and the Mild-only rookie runs are by design (`Difficulty.luau:48`). Two parts hold: the "+-37" sign (`RunDirector.luau:4900` and the `"+" ..` formatting) and worthless tier-1 gem drops for rookies. | H → M | S | P (gem floor), M2 (sign) |
| T-12 | **Confirmed** | `ResultsUI.luau` has no gem, challenge, tier-unlock or Best Solo code. Placement is shown for extractions as well. | H | M | U (P and M2 supply the data) |
| T-13 | **Confirmed** | `Onboarding.textFor` has 11 hints and none for V, horn, whey or gems. Only a hover tooltip on the wallet exists (`RunShopUI.luau:240`). | H | S | U |
| T-14 | **Confirmed** (reproduced) | `prest.luau` shows only "⬆ Level 1" in the toasts. The server sends a Prestige toast with the reward (`ShopService.luau:489-497`), but the player sees only the level toast. There is no banner, frame or Ascension note. | M | S | U, P |
| T-15 | **Confirmed** | `ClassProgress.displayLevel` for P ≥ 1 is `1 + floor(pxp/12000·29)`. A migrated 6-star hero with starXp 5000 shows 13. | M | S | U, P |
| T-16 | **Confirmed** | Only the server handler exists (`RunDirector.luau:5196`) and nothing in `src/client` fires it. It works only for human squadmates, and most squads are 1 human plus bots. | M → L | S → M | U |
| T-17 | **Confirmed** | `LobbyUI.luau:1314-1520` still shows the Pressure board next to the ladder. `LadderModel.luau:50-74` blurbs read "Pressure N.". | M | S | U |
| T-18 | **Merged into T-3** | Same root. Boss 345 s vs hordes 185 s is real. `BOSS_SECONDS = 180` (`RunDirector.luau:143`) is a cap, not the cause. The boss-limit cut is Partly and kept as a sub-item of T-3. | M | M | M2 |
| T-19 | **Partly** | `v4report.txt` idle runs 7–65 %, but it measures the whole match, including boss and lull phases. The ≤ 20 % target is not met, but the metric needs defining first. | M | M | M1 |
| T-20 | **Partly** | `POINT.bite = 0.0005` is real. But "9 gems don't move a clear" is T-2's wall, not gem weakness. Retune only after T-2. | M | S | P |
| T-21 | **Confirmed** | `GemModel.luau:23` shows "Plating" with a "-" sign and no tooltip. The overflow is unverified. | L | S | U |
| T-22 | **Partly** | The dense layout values are small (`UiSizes.luau:596` and `:611`: redeploy 30, wallet 22, text 13). The emulator ignores real scaling, so 14 px and 17 px are unverified. Verify on device. | M | S | U |
| T-23 | **Confirmed** | The warning uses `myRoot()` (`CombatHudUI.luau:773-790`), not the spectated hero. The horn pill has the same issue. | L | S | U |
| T-24 | **Confirmed** | `HeroUI` reads `Defs.module("Ascension")`, which is generic. `AscensionNodes` is the class-specific config. | L | S | U |
| T-25 | **Confirmed** | `doPrestige` at P0 clamps `carry` to 11,999 (`ClassProgress.luau:804-806`), while the bank allows 24k. Rare, and it loses at most one Prestige of surplus XP. | L | S | P |
| T-26 | **Confirmed** (ring part) | In `boss_poses.png` the ground disc stands up in the "dead" column. The disc is a model part (`BossModels.luau:1271`). "Poses barely differ" holds for corndog_bunny and hematite_snake only. | M → L | S (ring), M (poses) | G |
| T-27 | **Confirmed** | `asc.png`: the stages are tiny add-ons. | M | M | G |
| T-28 | **Confirmed** | `gems.png`: one cut. Tiers 1/2, 3/4 and 6/7 are near-identical. | L | S | G |
| T-29 | **Partly** | The gameplay view is flat (`map_volcano.png`). But `scripts/render-preview.luau:170` already includes GroundScatter, so "not in the preview" is wrong. Judge density in Studio. | M | M | G |
| T-30 | **Partly** | `BotAnimator.luau` already has body bob, trunk sway, ear flaps and a hit flinch. The static preview frames hide that. Missing: anticipation and squash. | M → L | M | G |
| T-31 | **Partly** | Confirmed: "Le Fante" vs "Le F'ante" (`Challenges.luau:47`). Grouping and counters are a feature, not a bug. | L | S | P |

**Counts:**
- 31 entries.
- Confirmed: **21** (T-1, 2, 3, 5, 6, 7, 8, 10, 12, 13, 14, 15, 16, 17, 21, 23, 24, 25, 26, 27, 28).
- Partly: **9** (T-4, 9, 11, 19, 20, 22, 29, 30, 31).
- Merged: **1** (T-18 into T-3).
- Rejected: **0**.

Rejected sub-claims:
- "Best Solo shows 1,099,500."
- "GroundScatter is not in the preview."
- "Whey from champions is missing."
- "Animators have no bob or ear flaps."

## 2. Hotfix now (live bugs, small, no balance risk)

| Id | Change | Owner |
|---|---|---|
| **T-1** | In `LadderModel.horn`, if `h.need > 1 or h.stomped > 1` divide both by 100. If `h.ready ~= nil`, use `h.ready` only. Fix `CombatHudUI.luau:815` to print the percentages. Rewrite the spec on a real `matchPayload` shape. | U |
| **T-7** | In `LobbyService.currentTier`, delete the "stale board → CUSTOM" rule (`:651-654`). Custom is chosen only by an explicit `SetTier(0)`. Client `LadderUI`: show "Custom" when `t == 0` instead of falling back to Medium. | M2, U |
| **T-5** | `ResultsUI` takes `xpToNext` from `ClassProgress.xpToNext` (or mirror `70·l^1.35` in `ClassMath`). | U |
| **T-6** | Add `BOARD_NAMES` for all 9 boards. Print Best Solo as "<tier name> · m:ss" from `row.tier` and `row.seconds`. | U |
| **T-11 (sign only)** | Format negative rows without the `+` (`ResultsUI.luau:734` and the breakdown rows). | U |
| **T-23** | Hide the Melt warning and the horn pill while spectating or out. | U |
| **T-31 (name only)** | `CLASSES` entry becomes "Le F'ante" (`Challenges.luau:47`). | P |

## 3. Confirmed items ranked by impact ÷ effort

| # | Id | Score | Concrete change | Owner |
|---|---|---|---|---|
| 1 | T-1 | 3.0 | See the hotfix table. | U |
| 2 | T-7 | 3.0 | See the hotfix table. Also remove the legacy "🔥 Pressure N · +32 % cheese" line (`LobbyUI.luau:1490`). | M2, U |
| 3 | T-10 | 3.0 | `RunShop`: `WHEY_PER_RINDS` 25 → 10, `BUFF_COST` 250 → 150, `CLASS_BUFF_COST` 500 → 300, `ULTIMATE_COST` → {3000 rinds, 300 whey}, Swap 5:1 with fee 0. Keep the champion, POI and stage whey as is. Update `CombatV5.spec` (whey sum) and `RunWallet.spec`. Sim guard: about 1 buff per stage, and an Altar is affordable at stage 3. | M2 |
| 4 | T-13 | 3.0 | Add 4 `Onboarding` hints:<br>- first affordable rank: "Press V (🛠) to buy upgrades that last the run";<br>- first horn-ready: "Stomp 70 % then call the next wave";<br>- first whey ≥ stall cost: "Whey buys buffs at stalls";<br>- first gem drop: "Equip it in 💎 Gems". | U |
| 5 | T-8 | 3.0 | Add optional `settings.tier` (sanitised, clamped to unlocked) in `ProfileSchema`. `onSetDifficulty` saves it. `currentTier` uses it. Veterans with no value default to their highest cleared tier. Show "Last played" in the card. This is additive and needs no migration. | P, M2 |
| 6 | T-5 | 2.0 | See the hotfix table. | U |
| 7 | T-6 | 2.0 | See the hotfix table. | U |
| 8 | T-17 | 2.0 | Hide the Pressure board behind a "Custom" tile (unlocked after Sharp). Replace the blurbs "Pressure N." with plain text. | U |
| 9 | T-14 | 2.0 | Give the Prestige toast priority, or show a banner: "⭐ Prestige N! +perk point, +0.5 % dmg, +300 🧀 +10 ✨, Ascension N unlocked". Suppress the "⬆ Level 1" toast when the level change comes from a Prestige. | U, P |
| 10 | T-15 | 2.0 | A one-time join toast or card for migrated heroes: "Your N Mastery Stars are now ⭐N Prestige. Nothing was lost." Show "Lv 30 ⭐N · x % to ⭐N+1". | P, U |
| 11 | T-11 | 2.0 | Rookie gem floor: roll at least tier 2 for runs 0–2. Fix the sign (hotfix). Leave ×0.75, or pay a rookie bonus. | P, M2 |
| 12 | T-2 | 1.5 | Set Moldy and Doomwheel bases back toward ALIGNMENT: Moldy about 1.6/1.4/1.2, Doomwheel 2.2/1.8/1.3. Re-run the ladder sweep (`scripts/ladder.luau`) and the meta stand-in until maxed P40 reaches 30–40 % on Doomwheel and fresh stays under 2 %. Add the stand-in rows to `IntegrationDifficulty` using `Stats.compute`'s 7th parameter. Also use more than 8 seeds for tiers 1–7. | M1, M2 |

**Next, below the top 12:**

| Id | Score | Concrete change | Owner |
|---|---|---|---|
| T-3 (+T-18) | 1.5 | On a horn, carry the unspawned budget into the next wave. Sim guard: horn On earns ≥ horn Off rinds per minute and per match. Then cut `BOSS_SECONDS` 180 → 120 and raise `HORN_MIN_SECONDS` to 15. Target hordes ≥ 55 % of stage time. | M2, M1 |
| T-12 | 1.5 | Loot column in Results: gem card, tier unlock, Best Solo, challenge ticks. Separate XP from cheese. Name the tier. "Extracted · secured X" instead of a placement. | U (P, M2 data) |
| T-26 (ring) | 1.0 | Keep the shadow disc outside the tilting root, or skip it in the death rotation. | G |
| T-21, T-24 | 1.0 each | T-21: plain-word gem stats ("+9 % damage to mice", "−2 % damage taken"), unique on its own line. T-24: build the node rows from `AscensionNodes.node(classId, n)`. | U |
| T-25 | 1.0 | Allow multi-Prestige or keep the full bank. Pulse the Hero button when ready. | P |
| T-28 | 1.0 | Gem cuts by tier band: wedge 1–4, wheel 5–8, crown 9–12, plus distinct hues. | G |
| T-16 | 0.5 | A "🎁 100" button on human squadmates in the squad panel, cooldown 2 s. | U |
| T-27 | 1.0 | Per-stage scale +8 %, +15 %, +25 %, glowing tusks, cape and a ground aura ring. | G |
| T-4 (Partly) | 1.0 | Narrow: a revived or redeployed hero is not a bot target for 10 s. At most 1 bot attacker per human at a time. Extend rookie safety by one stage. Sim guard: bot PvP below 40 % of a rookie's damage taken. | M1 |
| T-9, T-19, T-20, T-22, T-29, T-30, T-31 (Partly) | ≤ 1 | T-9: flag only the human who landed the blow. T-19: define the idle metric per phase first. T-20: triple `POINT.bite` and `POINT.hide` after T-2. T-22: verify on device first. T-29: judge in Studio. T-30: add anticipation and squash only. T-31: grouping and counters. | as listed |
