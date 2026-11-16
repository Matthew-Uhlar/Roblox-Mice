# V4 Review Team C: progression, economy and monetization

_Date: 2026-11-16. Branch `claude/focused-gates-jihpzi` at 9c3c4b0 (live place v6). Report only: no source changed._

## 0. Method

- **Real server code in the runtime emulator** (`tests/runtime`). Four scratch scenarios played real matches through the real UI (READY, upgrade cards, ExtractUI) and drove every progression remote from the client: `ClaimDaily`, `SelectPerk`, `ResetPerks`, `SelectAbility`, `SelectSkin`, `BuyShopItem`, `Equip`, `SetPressure`, `PromptProduct`. They also called `rt:processReceipt` for every developer product and set pass ownership (`rt.config.ownedPasses`, then `PromptProduct("refresh")`).
  - The scenarios kept the usual test knobs: `RunDirector.WAVE_SECONDS = 20` and `Driver.powerUp(25)`.
  - The scratch files are in the session scratchpad (`.../scratchpad/v4c/specs/progression{2,3,4}.luau`) and may be cleaned up. §6 lists the exact steps so anyone can rebuild them.
  - All four ended with **0 script errors and 0 emulator gaps**.
- **Pacing** comes from the headless sim (`tests/sim/Headless.luau`): 48 seeds, a solo human stand-in plus 11 bots, default timings (150 s waves), POIs on. Class XP uses the real `ClassProgress.runXp` on each payout summary.
- **Live prices.** Every pass and product in `Config/ProductIds.luau` was read from the public Roblox endpoints (`apis.roblox.com/game-passes/v1/game-passes/<id>/product-info`, `apis.roblox.com/developer-products/v1/developer-products/<id>/details`). **All 17 live prices match `fallbackPrice`.** Cheese Club and `ad_reward` have id 0 and are not live.

| Live item | R$ | Live item | R$ |
|---|---|---|---|
| VIP Herd | 399 | Golden Cheese x100 / x210 / x550 / x1150 / x2400 | 49 / 99 / 249 / 499 / 999 |
| Fast Learner | 249 | Second Wind / x3 | 49 / 129 |
| Herd Leader | 349 | Cheese Rush | 99 |
| Founders' Stampede | 499 | Cheese Feast | 149 |
| Cheese Wardrobe | 99 | Perk Respec Token | 49 |
| Gilded Herd Skins | 199 | Cheese Club (subscription) | not created (shows "Coming soon") |
| Neon Herd Skins | 149 | Snack Break (ad) | not created (ads off) |

## 1. Findings

Severity:

- **Broken** means a feature that is wrong or that players can't reach.
- **Major** means a large gap in value, honesty or retention.
- **Minor** means polish.

### Broken

| # | Finding | Evidence / repro |
|---|---|---|
| **B1** | **The Pressure record (and Pressure unlock) is set by extracting after stage 1.** `RunDirector.payMember` passes `won = po.extracted`, and `Pressure.recordRun` raises `highestCleared` to the run's full points on any "win". At P8, a player who clears one boss and leaves gets "New Pressure record: 8!". The record, and the planned Pressure title badges (`Pressure.badges`), therefore measure nothing. | Emulator (progression3): match A extract@1 gives "Pressure unlocked!". The leader then sets `stampede 3, big_cheese 2, rush_hour 3` (8 points). Match B extracts at stage 1 (`stagesCleared 1`), and the profile shows `pressure.highestCleared = 8` with the toast "New Pressure record: 8!". Fix: record only when `po.stagesCleared >= MatchState.CONFIG.STAGES`, or store the record per stage cleared. |
| **B2** | **Leaderboards are written but nobody can see them.** `LeaderboardService.getTop` has no callers. There is no S2C remote, no lobby board and no UI (HANDOFF already lists this as an open Minor). Given the brief, it is a missing feature: a "live" game with five boards nobody can see. | `grep -rn getTop src/` finds only its definition. Emulator: after 3 matches and a 310 s refresh, `getTop("wins")` returns `#1 Prog=2`, and the client has no way to show it. |
| **B3** | **The `deepestCycle` board is always 1.** v2 runs are a single cycle (`payMember` passes `cycle = 1`), so every player who ever finishes a run ties at 1. | Emulator: `deepestCycle #1 Prog=1` after a stage-1 extraction. Replace it with "stages cleared in one run" or "highest Pressure fully cleared" (after B1). |

### Major

| # | Finding | Evidence / repro |
|---|---|---|
| M1 | **The `wins` board and `stats.wins` count stage-1 extractions.** A win is any extraction, so the fastest way to climb is to extract at the first Rind Gate (about 4–5 min of real time). | Emulator: two stage-1 extractions give `wins = 2` and `ranked.wins = 2`. Count a win only on `lastHerd`, or on a stage-4 finish / extraction after stage 3. |
| M2 | **The account level is never shown.** The profile view sends `level` and `xp`, but no client file reads them: there is no badge, bar or lobby label. Level cosmetics (L5–L30) say "Unlocks at level N" in the shop, yet players can't see their own level. **Fast Learner (249 R$) sells 2x of a number the game never displays.** | `grep -rn "profile.level" src/client` finds nothing. The only trace is the toast "Level up! You are now level N". |
| M3 | **Paid timed boosts are invisible.** Nothing in the client reads `cheese2xUntil`, `feastSecondsLeft`, `cheeseMult` or `herdLeaderActive` (the Results screen alone shows the final multiplier). A Cheese Rush buyer can't see that the boost is active or how much time is left. | `grep -rn "cheeseMult\|feastSecondsLeft\|herdLeaderActive" src/client` matches only ResultsUI. Emulator: after Rush + Feast, `MS.cheeseMult` is 2.5, and the lobby and HUD show nothing. |
| M4 | **Golden Cheese single-skin prices are higher than the 7-skin passes.** One Gilded skin costs 450 GC. That is 199–220 R$ at pack rates (you have to buy golden_m for 249 R$), while the Gilded pass gives all 7 skins for 199 R$. One Neon skin costs 350 GC, about 146–171 R$, against 149 R$ for all 7. Anyone who buys skins one by one loses badly, which risks refund requests and bad reviews. | `Config/ClassSkins` priceGolden; packs give 2.04–2.40 GC per R$. Shop check: `skin:le_fante_gilded:golden` takes the whole 450 GC. |
| M5 | **Golden Cheese cosmetics cost more than the Wardrobe pass.** Wizard Hat (300 GC) costs about 148 R$ in packs (golden_s + golden_xs), while Cheese Wardrobe gives 6 cosmetics for 99 R$. | `Config/Cosmetics` and the live prices above. |
| M6 | **Golden Cheese has almost nothing to buy.** The whole GC catalog is 2,700 GC of cosmetics (6 items) plus 5,600 GC of paid skins (14), which is 8,300 GC. Anyone who owns both skin passes has 2,700 GC of things left. The largest pack (2,400 GC) nearly empties the shop. Cheese Club would grant 1,200 GC a month into that empty catalog. | `sim/tables.luau`: shop cosmetics are 13 in total (7 cheese-only, 3 GC-only, 3 both). |
| M7 | **The daily streak can only be claimed inside the Shop modal**, and nothing in the lobby says a reward is waiting: no dot, no toast. This is the main retention loop. | `grep -rn ClaimDaily src/client` matches only ShopUI. |
| M8 | **The lobby auto-start pulls players out of the shop and the perk tree.** A player who is not ready is still "auto-eligible", so 30 s after joining (or after returning) the match starts and `ShopUI` closes itself (`State.subscribe("run")`). Browsing the shop, the perk tree or the class picker never counts as engagement. | Emulator (progression first draft): with no READY click, the run started about 30 s after join, mid-way through the shop and perk calls ("You're on squad Brie…"). `LobbyRules.autoEligible`. |
| M9 | **Robux benefit text is cut off.** Shop cards give the description a 220×54 px box at 14 px (about 90 characters). The Second Wind benefit is about 430 characters, VIP about 190 and Cheese Rush about 260. The rules a buyer must read (Second Wind "only when your squad is the last one left", the Rush cap and refund) are cut. | `ShopUI.card` subtitle `Size = UDim2.new(1, -20, 0, 54)`; `Config/Monetization` benefit strings. |
| M10 | **There is no goal after the class and account caps.** Class XP above level 30 is thrown away (`ClassProgress.addXp`), and there is no prestige. Account levels 31–100 give nothing (level cosmetics stop at 30), and the account level isn't shown anyway (M2). Class levels 20→30 take about 160 matches (~24 h) with only one skin and one title. | `ClassProgress.addXp` ("Overflow at MAX_LEVEL is dropped"), `Cosmetics.forLevel`. See §2. |
| M11 | **Cheese inflates.** Every permanent cheese sink costs about 78,400 cheese in total (§3), which a player earns in about 64 matches (~10 h). One class alone takes about 38 h to reach level 30. After about 10 h, cheese has only consumable uses (respec, tokens), and balances grow without limit. | §3. |
| M12 | **Policy risk: Robux speeds up PvP power.** Cheese Rush, Cheese Feast and Herd Leader multiply cheese, and cheese buys talents (+20 max HP, +10% damage, +1.6 speed). Those talents apply in squad PvP. MONETIZATION.md says so openly, and the effect is small (talents cost ~33 matches of cheese, ~12 with every boost). It still conflicts with the owner's stated "no PvP power" rule for the new shop. | `Config/Talents`, `RunDirector.computeStats` (talents read from the live profile). Recommendation in §5.6. |

### Minor

| # | Finding | Evidence / repro |
|---|---|---|
| m1 | **A full level-30 tree is one point short of two capstones.** Level 30 gives 29 points, one branch costs 15, and two branches cost 30. "Fill a perk tree" is impossible (45 points); even two full branches are out of reach. | Emulator: at L30, taking branches in order gives `elephante_stampede_5`, then "Not enough perk points" on branch 2's capstone; final state: 11 perks, spent 28, free 1. Give 1 point at level 1, or make prestige star 1 (§5.4) grant a 30th point. |
| m2 | **The mastery title on the nametag doesn't update on level-up.** `awardRun` doesn't call `CosmeticsService.refresh`. The title only changes on a respawn, Equip, class change or entitlement change. | Emulator (progression2): after L30 the nametag still reads `Prog` (no "Gold Herd"). |
| m3 | **The level-cosmetic toast shows the raw id**, e.g. "New cosmetic unlocked: hat_cheese_wedge". | `DataService.awardRun`: `toast(player, "New cosmetic unlocked: " .. id)`. |
| m4 | **The daily button shows the wrong day.** The label is `min(7, streak+1)`: at streak 7 the next claim is ladder day 1 but shows "day 7", and the missed-day step-back isn't reflected. | Emulator: claiming on day +7 grants "Day 1 reward: +100 cheese". `ShopUI.renderHeader`. |
| m5 | **Owned passes still show "R$ 399".** The server answers "You already own…" only after a click. `view.passes` is sent but ShopUI ignores it. | ShopUI.renderBoosts. |
| m6 | **Cheese Club appears as "Coming soon"** in the live shop (subscription id 0). Hide it until it exists; showing an unbuyable item is noise. | `ProductIds.cheese_club = 0`. |
| m7 | **Discoveries, the Pressure record and Pressure badges are never listed.** There is a toast and the Herd Keeper title, and nothing else. | `grep -rn "discoveries\|highest" src/client` finds nothing. |
| m8 | `BuyShopItem` (talents) and `ResetPerks` are not refused during a run. Talents are read live by `computeStats`, so an exploit client can buy talents mid-run and get the stats at the next recompute. The real UI closes the shop in a run. | ShopService.onBuy has no `isRunMember` check. |
| m9 | Class, talent and cosmetic purchases don't ask for a save; only the 120 s autosave picks them up. The daily claim and respec do save. A server crash would roll back both the spend and the grant (consistent, but annoying). | ShopService.onBuy. |
| m10 | The Club monthly rotation has only 3 cosmetics. From month 4 the fallback is 300 GC. | `Receipts.applyClubMonthly`. |
| m11 | Founders' Stampede says "launch window only", but nothing ends the window. | Config/Monetization. |
| m12 | Second Wind (49 / 129 R$) is usable only once your squad is the last one left. That makes it a low-value buy that shares the Robux grid with everything else. Keep it out of any Featured slot. | MONETIZATION.md. |

### Verified working (emulator, real server code)

| System | Result |
|---|---|
| Account XP / level | Match XP: 50 (stage-1 extract), 110 (stage 2), 260 (4 stages). Fast Learner doubled a wipe's 110 to 220. Level-up toast fires; cosmetics are granted by `Award.addXp` (code read). |
| Cheese earned | Stage-1 extract 100 + first-run-of-day bonus +100 (once per day; the second match got none). Pressure 8 turned a 100 chest into 164 (+8% per point, as designed). Full 4-stage Last Herd: 1,485. |
| Golden Cheese | Every pack granted exactly 100 / 210 / 550 / 1,150 / 2,400. A duplicate PurchaseId gave `PurchaseGranted` with no second grant. Spent on a skin (450). |
| Class XP / levels | 94–135 XP for a stage-1 extract or a wipe, 602 for a 4-stage Last Herd. Level-up toasts with the number of perk points. Abilities: "New Elephante ability: Trunk Quake" at L5 and "Iron Hide" at L15. Skins at L3 / 10 / 20 / 30 (Field Grey, Ironclad, Gladiator, Mammoth King). Mastery Bronze / Silver / Gold toasts at 10 / 20 / 30. The client view lists unlocked abilities and skins. |
| Perks | Tier-order lock ("Take the perk before it…"), locked class, wrong class and no points are all refused with clear toasts. |
| Respec | Cheese: refused below 3,000 at L30 (100 × level). Token: refused without one; after buying `respec_token`, "Perks reset with a Respec Token: 28 points back", and the token count went back to 0. |
| Alternate ability / skin selection | `SelectSkin(paid gilded)` works once owned; `SelectAbility(nil)` returns to the base ability. |
| Daily streak | Days 1–7 ladder exact (100, 150, Second Wind, Sunny, 300, 25 GC, Streak Sparks). The same day is refused. Day 8 loops. Missing 1 day repeats; missing 3 steps back 3 (day 13 gave the day-6 reward). VIP adds +150 cheese and +5 GC. |
| Class unlock | `class:le_fante` is refused at 2,499 and bought at 2,500 (creates the class block). Founders unlocks all 7 (then "You already own that"). |
| Cosmetics | Party Hat bought for 800 cheese and equipped; the `TrunkfallCosmetics` folder is drawn. |
| Talents | Thick Hide L1 bought; `computeStats` reads talents into run stats. |
| Pressure unlock | Unlocked on the first extraction; the leader board took 8 points. (See B1.) |
| Discoveries | With injected `poiActivated` events: "New discovery: Grandma's Pantry! Unlocked: Boss Embers" and "Lost Herd Statue! Title unlocked: Herd Keeper". The nametag shows "Herd Keeper". A repeat find grants nothing. |
| Leaderboards | Writes happen (`wins = 2`, `deepestCycle = 1`); `fastestCycle1` after a full 4-stage clear (133 s in the emulator). (See B2, B3, M1.) |
| Passes | All 7 verified through `UserOwnsGamePassAsync`. VIP: crown + trail, `ChatTag = "VIP"`, daily bonus. Fast Learner: `xpMult = 2`. Herd Leader: +0.15. Founders: 7 classes + plume + gold tint. Wardrobe: 6 cosmetics. Gilded + Neon: 14 `ownedSkins`. |
| Products | Second Wind +1 / +3. Respec +1. Cheese Rush took `cheeseMult` from 1 to 2.0. Cheese Feast started after the save (server toast) and took it to 2.5 (2.65 once Herd Leader was owned). The second-wind prompt is refused in a run (`in_run`) and allowed in the lobby. |

Every Robux item grants exactly what its benefit text says. The only exception is the Club, which isn't live. **No grant mismatch was found.** The problems are in surfacing (M2, M3, M9) and in pricing (M4, M5, M6).

## 2. Pacing

**Per match (sim, 48 seeds, solo + bots, default timings).**

- Averages:
  - banked cheese: **1,188** (before boosts)
  - account XP: **139**
  - class XP: **557**
- The squad leaves at stage 2.6 on average.
- The match takes about **8.1 min**; with lobby time, about **9 min per match** (~6.7 matches an hour).
- Results are bimodal:
  - wipe (48%): 43 cheese / 112 class XP
  - Last Herd (44%): 2,356 / 954
  - extraction (8%): 1,640 / 1,030

A weaker real player (70% wipes) gets about 370 class XP per match, which makes every number below about **1.5× longer**.

| Goal | XP / cost | Matches | Time |
|---|---|---|---|
| Class L3 (first skin) | 364 | 0.7 | ~6 min |
| Class L5 (alt ability 1) | 1,526 | 2.7 | ~25 min |
| Class L10 (skin, Bronze) | 9,237 | 17 | ~2.5 h |
| Class L15 (alt ability 2) | 25,511 | 46 | ~7 h |
| Class L20 (skin, Silver) | 51,962 | 93 | ~14 h |
| Class L30 (skin, Gold) | 140,372 | 252 | **~38 h** |
| All 7 classes to L30 | 982,604 | 1,764 | ~265 h |
| Account L5 (first level cosmetic) | 1,100 | 8 | ~1.2 h |
| Account L30 (last level cosmetic) | 26,100 | 188 (94 with Fast Learner) | ~28 h |
| Buy all 4 locked classes | 13,000 cheese | ~11 (with first-run bonuses) | ~1.7 h |
| Max all talents | 39,700 cheese | +33 | +5 h |
| Every cheese cosmetic | 25,700 cheese | +22 | +3.3 h |
| Fill a perk tree | impossible (45 points, 29 earnable) | — | — |
| Two full branches | impossible (30 points) | — | m1 |

Is there always a next goal?

- **Early game:** yes, and it is good. Class L2 comes inside the first match, L3 and a skin by match 1–2, an ability by match 3. On top of that come the first-run bonus, the daily day 1 and a first class purchase around match 2–3.
- **Mid game (L10 → L15, about 30 matches):** only 5 perk points arrive. Cheese still has talents to buy, so it holds up.
- **Late game (L15 → L30, about 200 matches):** a skin every ~50–160 matches, no account level on screen, and cheese with nothing to buy after about 10 h. **This is the retention cliff.**
- **Max level:** nothing. Overflow XP is dropped, there is no prestige, and the account levels 31–100 are empty.

§5 fixes this with quests, a pass, mastery stars, achievements and a collection log.

## 3. Economy

Faucets, per day for a player who plays 6 matches:

| Faucet | Amount |
|---|---|
| Matches | 6 × 1,188 = ~7,100 cheese |
| First run of the day | up to 1,000 |
| Daily streak | ~80 cheese/day average, plus ~3.6 GC/day (25 GC every 7 days) |
| VIP | +150 cheese and +5 GC per claim |
| Boost multipliers | up to 2.75× (all stack additively) |

Sinks:

| Sink | Type | Cost |
|---|---|---|
| Classes | one-time | 13,000 |
| Talents | one-time | 39,700 |
| Cheese cosmetics | one-time | 25,700 |
| Respec | repeatable | 200–3,000 |
| Reroll tokens | repeatable | 100 each, cap 30, at most 2 used per stage |
| Second Wind | repeatable | 1,000 each, cap 10, rarely usable |

Conclusions:

- The one-time sinks total **78,400** cheese, which is about 10 h of play. After that the repeatable sinks drain less than 5% of income.
  - **Inflation risk: high.** Within about 2 weeks a regular player has six-figure cheese and nothing to want.
  - The fix is new repeatable sinks: a cheese side of the rotating shop, mastery-star recolours and title plates (§5).
- **Golden Cheese value.** Packs give 2.04 → 2.40 GC per R$ (a fair +5…+20% ladder). The catalog behind them is too small (M6) and priced inconsistently with the passes (M4, M5).
  - The fix is to reprice: pass ≈ 55–60% off the sum of its singles.
  - Then grow the GC catalog to 40+ items through the rotation (§4).
- **Pass prices are in line with the genre.** VIP 399, Herd Leader 349 and Wardrobe 99 are fine.
  - Fast Learner (249) is weak until the account level is visible and rewarded (M2, M10).
  - Founders (499) unlocks about 1.7 h of cheese plus 3 cosmetics. It is fair as a supporter item, but it should end as its text promises (m11).
- **Respec (49 R$ against 100 × level cheese)** is fine as a convenience.

## 4. The Robux shop (design)

### 4.1 Audit of the current ShopUI

**What is there:**

- One lobby button ("🛒 Shop") and a modal with 3 tabs:
  - Cosmetics: cheese or GC, plus paid skins
  - Boosts & Passes: all 17 Robux items plus cheese token bundles
  - Talents
- The daily claim sits in the header.
- Prices come live from `GetProductInfoAsync` (showing "R$ —" until loaded). That is correct.

**What is missing:**

- no Featured page, no sections and no previews
- no "Owned" state for passes (m5)
- benefit text clipped (M9)
- no "get Golden Cheese" path from a disabled GC button
- no active-boost display (M3)
- the auto-start closes it (M8)
- Classes are bought in the class picker; that is fine, but the shop should link to them.

### 4.2 Entry points (no auto-prompts anywhere)

1. **Lobby HUD button.** Top-right "🛒 Shop", with a small cheese-yellow dot when something new is waiting:
   - the daily reward can be claimed (fixes M7)
   - a new rotation day
   - a pass tier can be claimed

   A dot, never a timer.
2. **Lobby kiosk.** A "Cheese Market" stall on the lobby island, with a ProximityPrompt "Browse" that opens the shop on Featured.
   - Three mannequins wear today's featured cosmetics; the stall's sign shows the featured hat.
   - Also add a **Hall of Herds**: a physical leaderboard wall next to it (fixes B2).
3. **Post-match, on Win results only** (extracted or Last Herd).
   - Under the class XP bar, a non-modal card: "Today in the Market: <item icon> <name>" with a "View in shop" button. The button opens the shop; it never prompts.
   - **Hidden on Wipe / eliminated results and on any death screen** (the rule). Shown at most once per session.
4. **Context links:**
   - Class picker skin row → "More skins" (Skins tab).
   - Perk tree → the existing respec-token button.
   - A disabled GC price → "Get Golden Cheese" (GC tab).
   - Each link opens the shop; none of them prompts.
5. **While the shop or perk tree is open,** the player sits out the auto-start (`LobbyRules.autoEligible` false while `browsing`), with a small "You'll join the next match when you close the shop" note. This fixes M8.

### 4.3 Tabs

| Tab | Contents |
|---|---|
| **Featured** | Today's 4 rotating cosmetics (GC) + 2 rotating cosmetics (cheese), the Starter Pack (until bought), the current Herd Pass, and one bundle. |
| **Cosmetics** | Filters: Hats · Trails · Tints · Class Skins · Owned. Each card has a 3D preview viewport (a "Try on" button puts it on your character in the lobby until you close the shop). Earned items show how to earn them ("Account level 15", "Class L20"). |
| **Passes** | 7 permanent passes, with Owned ✔ when owned (m5). Benefits are a 3–4 bullet list on the card, plus a "Details" button that opens the full benefit text (fixes M9). |
| **Golden Cheese** | The 5 packs with their bonus %, plus Cheese Club (only once it is live, m6). |
| **Boosts** | Cheese Rush / Feast with the **active timer** ("Rush: 42 min left", "Server Feast: 18 min", "Herd Leader in server +15%"; fixes M3), Respec Token, Second Wind (last, with its rules in full). |
| **Herd Pass** | Season track (§5.2). |
| **Cheese Shop** | Talents, class unlocks (mirroring the class picker), token bundles. |

### 4.4 Daily rotation (no paid randomness, no FOMO)

- **Deterministic and shared.** Slots come from `Rng.new(dayNumber)` over the eligible pool, and every player sees the same items that day.
  - The player sees exactly what they pay for; nothing about the purchase is random.
  - Already-owned items are greyed out, not re-rolled per player.
- **No countdown.** The label says "Changes every day". Never show a ticking clock, "only N left" or a fake discount.
- **Slots:**
  - GC: 1 hat, 1 trail, 1 tint, 1 class skin
  - cheese: 1 hat or trail, 1 tint (the cheese sink for M11)
- **Pool:** at least 40 new rotation cosmetics before launch, so an item comes back about every 10 days. Add 8 a month after that.

### 4.5 Exact catalog (suggested prices)

Golden Cheese costs about 0.42–0.49 R$ (2.04–2.40 GC per R$ depending on the pack).

**Game passes (permanent):**

| Item | R$ | Change |
|---|---|---|
| VIP Herd | 399 | keep; add "VIP" badge frame in the collection log |
| Herd Leader | 349 | keep |
| Fast Learner | 249 | keep, **only after** the account level is visible (M2) and levels 31–100 have rewards (§5.4); extend to "2x account XP and +25% Herd Pass XP" |
| Cheese Wardrobe | 99 | keep (the best first purchase) |
| Gilded Herd Skins | 199 | keep |
| Neon Herd Skins | 149 | keep |
| Founders' Stampede | 499 | end the sale on a fixed, announced date (it then shows "Thank you, Founders" to owners only). No countdown. |

**Developer products:**

| Item | R$ | Grants (fixed) |
|---|---|---|
| Golden Cheese x100 / x210 / x550 / x1150 / x2400 | 49 / 99 / 249 / 499 / 999 | unchanged |
| **Starter Herd Pack** (once per account; server-enforced in `profile.purchasesOnce`) | 99 | 300 GC + Rookie Bandana hat + Rookie Dust trail (both exclusive) + 1 Perk Respec Token. Shown on Featured until bought or account level 20. No timer. |
| **Herd Pass Premium** (per season, §5.2) | 399 | the season's premium track (cosmetics + 600 GC over 30 tiers) |
| **Skin Collector Bundle** (Gilded + Neon sets) | 299 | 14 skins (saves 49 against the two passes). Grant through an entitlement record (`profile.entitlements.skins_gilded/neon`) that `hasPass` also checks, so buying a pass later is refused as "owned". |
| **Wardrobe+ Bundle** (Wardrobe + 4 rotation-pool hats) | 199 | 10 cosmetics; same entitlement mechanism |
| Cheese Rush | 99 | unchanged (needs the visible timer, M3) |
| Cheese Feast | 149 | unchanged |
| Perk Respec Token | 49 | unchanged |
| Second Wind / x3 | 49 / 129 | keep, never on Featured; review retirement if purchase share is under 2% |

**Subscription:** Cheese Club, 249 R$ a month. Create it, or hide it. When it ships, grow the monthly cosmetic list from 3 to 12.

**Golden Cheese repricing.** The rule: a pass costs about 40–45% of its singles. The new prices are also the rotation prices.

| GC item | Now | New |
|---|---|---|
| Neon class skin (each) | 350 | **150** (×7 = 1,050 GC ≈ 440–515 R$; pass 149) |
| Gilded class skin (each) | 450 | **200** (×7 = 1,400 GC ≈ 585–685 R$; pass 199) |
| Wizard Hat | 300 | **200** |
| Midnight tint | 300 | **120** |
| Cheddar tint | 300 GC / 3,000 cheese | **120** / 3,000 |
| Molten (lava) trail | 400 | **300** |
| Astronaut Helmet | 600 / 6,000 | 400 / 6,000 |
| Stardust trail | 800 / 8,000 | 500 / 8,000 |
| New rotation items | — | hat 150–250, trail 250–400, tint 100–150, class skin 150–200, "Legendary" sets (hat + trail + tint) 600 |

The Club's 10% discount stays.

## 5. Progression improvements (exact specs)

All rewards are cosmetic, currency or titles. None adds combat stats.

### 5.1 Daily and weekly quests (`Data/Quests`, pure)

- **Daily quests:** 3 a day, picked deterministically from `Rng.new(day * 7919 + userId)`.
  - One free reroll a day (choose a new quest from the pool; deterministic order).
  - Rewards per quest: **150 cheese + 150 Herd Pass XP**. All 3: a bonus of **+10 GC**.
- **Weekly quests:** 5 a week (keyed by ISO week). Each gives **600 Pass XP + 400 cheese**. All 5 give **+40 GC**.

Daily pool, with targets per day:

| Quest | Target |
|---|---|
| Clear stages | 3 |
| Deal damage to bosses | 15% total boss damage share |
| Activate POIs | 4 |
| Defeat a Mouse Champion (squad credit) | 1 |
| Pick up gear items | 3 |
| Extract or finish Last Herd | 1 |
| Revive a teammate | 2 |
| Play 2 matches as a non-default class | 2 |
| Bank cheese | 1,000 |
| Use your alternate ability | 15 times |
| Down enemy heroes | 2 (counts bots too, so a solo player can finish it) |

Weekly pool:

| Quest | Target |
|---|---|
| Clear stages | 20 |
| Finish Last Herd | 2 |
| Play 3 different classes | 3 |
| Win boss chests (killing blow) | 2 |
| Clear a run at Pressure ≥ 3 | 1 (stage-4 finish, after B1 is fixed) |
| Activate POIs | 25 |
| Defeat Mouse Champions | 5 |

### 5.2 Herd Pass (battle pass)

- **Season:** 28 days, 30 tiers, 1,000 Pass XP per tier (30,000 for the season).
- **Pass XP per match:** `60 + 40 × stages survived + 60 if extracted or Last Herd`, capped at 280 a match. The sim average is about 167.
- **Target:** someone who plays 4 matches on 4 days a week and does dailies and weeklies earns about 2,670 + 1,800 + 3,000 = **7,470 a week**, so they finish 30 tiers in about 4 weeks. Players who play daily finish around week 3.
- **Free track (all 30 tiers):**
  - 300 cheese on every non-cosmetic tier (21 tiers; 6,300 in total)
  - 10 GC at tiers 5, 10, 15, 20 and 25
  - 2 cosmetics (tier 10 tint, tier 30 trail)
  - 2 reroll-token bundles
- **Premium track (399 R$):**
  - 8 cosmetics (themed season set: hat, trail, tint, 2 class skins, title plate, nameplate frame, a tier-30 "Season" trail)
  - **600 GC** spread across tiers (100 at tiers 3, 8, 13, 18, 23 and 28)
- **No paid tier skips** at launch. The free track holds cheese, which buys talents. Rewards are fixed and listed, with nothing random.
- **Fast Learner owners get +25% Pass XP.** It is an account-progression speed-up, not combat power.

### 5.3 Achievements (`Config/Achievements`, with Roblox badges for the starred ones)

| Achievement | Requirement | Reward |
|---|---|---|
| ★ First Steps | finish 1 match | 100 cheese |
| ★ Over the Rind | first extraction | 250 cheese |
| ★ Last Herd Standing | first Last Herd | 25 GC + title "Last Herd" |
| Herd of Many | own 5 classes / all 7 | 500 cheese / title "Herdmaster" |
| ★ Bronze / Silver / Gold Herd | any class L10 / L20 / L30 | (already badges; needs badge ids) |
| Seven Masteries | all 7 classes L10 | 100 GC + "Rainbow Mastery" nameplate frame |
| Champion Slayer | 10 / 50 / 200 champions (squad credit) | 300 cheese / 50 GC / title "Champion Slayer" |
| Boss Hunter | defeat all 13 bosses at least once | "Boss Horns" recolour + 100 GC |
| World Walker | clear a stage on all 9 maps | 50 GC + title "Cartographer" |
| ★ Under Pressure | a full run cleared at P5 / P10 / P15 / P21 | titles "Pressured", "Squeezed", "Crushed", "Unbreakable" (the existing `Pressure.badges`, once B1 is fixed) |
| Discoverer | find Grandma's Pantry and the Lost Herd Statue | 50 GC |
| Streak Keeper | reach a 30-day streak | "Streak" nameplate frame |

### 5.4 Prestige: class Mastery Stars and account levels past 30

- **Mastery Stars (per class, after L30).**
  - XP keeps counting instead of being dropped: **12,000 class XP = 1 star**, up to 20 stars (about 22 matches per star).
  - Every star: **300 cheese + 10 GC**.
  - Star 1 also gives **+1 perk point (the 30th)**. That fixes m1: two capstones at star 1. It is a one-time +3% power cap raise for players who already maxed the class.
  - Stars 5 / 10 / 15 / 20 unlock prestige recolours of the class's Mammoth King-tier skin (Bronze, Silver, Gold and Prismatic).
  - The star count shows next to the mastery title ("Gold Herd ★7").
  - **No level reset.** Resetting perks in a PvP game feels like punishment.
- **Account levels 31–100.** Show the level as a badge on the lobby HUD and the nametag (M2). Every 5 levels: a nameplate frame or title. Every 10 levels: 50 GC. Level 100: "Centennial Herd" trail.
  - The curve is the existing one (`200 + 50 × (L-1)`; L100 is about 262,000 XP, roughly 1,900 matches, or 950 with Fast Learner).

### 5.5 Collection log (a "Collection" tab in the lobby)

- **Pages:**
  - Cosmetics: owned / total by source.
  - Class skins: 28 earned + 14 paid + season skins.
  - Abilities: 14 alternates.
  - Discoveries: the 2 rare POIs plus each landmark kind.
  - Bosses defeated: 13.
  - Champions slain: 6 kinds.
  - Maps extracted from: 9.
  - Pressure record and badges (after B1).
- **Milestones** on the overall completion percentage:

  | Completion | Reward |
  |---|---|
  | 25% | 100 GC |
  | 50% | "Collector" title + 150 GC |
  | 75% | "Curator" nameplate frame |
  | 100% | "Archivist" trail |

- This fixes m7, and it gives Golden Cheese and the rotation a reason to exist (M6).

### 5.6 Economy changes

1. **Cheese sinks:**
   - the cheese slots of the daily rotation (1,500–8,000)
   - mastery-star recolours as an alternative cheese path (25,000 each, or earned by stars)
   - title plates (2,500)
   - a "Herd Banner" lobby flag (5,000, with recolours at 1,000)

   The target is that a 20 h player still has about 40% of total sinks left.
2. **Talents and Robux (M12).** Pick one:
   - (a) Normalise talents in PvP damage (apply talent damage and HP only against mice and bosses), or
   - (b) keep it, and state plainly in the shop's Boosts tab: "Cheese boosts also speed up talents (small permanent bonuses)".

   The recommendation is (a). It honours "no PvP power" without changing PvE balance.
3. **Repricing:** the Golden Cheese repricing in §4.5.

## 6. Repro steps (to rebuild the scratch scenarios)

Base, as in `tests/specs/RuntimeVeteran.spec.luau`:

1. Give fake asset ids to every `Config/Monetization` item in the server context.
2. Set `LobbyRules.AUTO_START_SECONDS = 1e6` in the server context before `rt:startServer()`.
3. Set `RD.WAVE_SECONDS = 20` and call `Driver.powerUp(rt, 25)`.
4. Add one player and fire remotes from the client with `Remotes.fire(Remotes.C2S.X, ...)`.

| Finding | Steps |
|---|---|
| B1 | Play one match with `Driver.autoplay`, extracting when `match.stage >= 1`. Fire `SetPressure("stampede",3)`, `("big_cheese",2)`, `("rush_hour",3)`. Play another stage-1 extraction. Expect `profile.pressure.highestCleared == 8` with `stagesCleared == 1`. |
| M1 | The same two matches give `profile.stats.wins == 2`. |
| M8 | Remove step 2 above and do nothing for 30 s after join: the run starts, and `TrunkfallShop` closes if it was open. |
| m1 | Call `DataService.awardRun(player, 0, 0, {classId="elephante", classXp=5000, ranked=false})` until level 30. Fire `SelectPerk` for every perk in branch order. Expect 11 perks, 1 point free, and the second capstone refused. |
| m2 | After m1, read the character's nametag TextLabels: there is no "Gold Herd". |
| m4 | Set `DataService.today` to return `base + d` and fire `ClaimDaily` for `d = 0..7`. Day 8 grants the Day 1 reward while the button said "day 7". |
| Products | `rt:processReceipt{PlayerId, ProductId = <fake id>, PurchaseId = unique}` for each key, then compare profile deltas. |
| Passes | Set `rt.config.ownedPasses[userId][id] = true`, wait 31 s, then fire `PromptProduct("refresh")`. |
| Discoveries | Wrap the server `World.drainEvents` and append `{type="poiActivated", kind="grandmas_pantry", by=userId}` during Waves. |
| Pacing | `Headless.new({seed, humans={{classId}}}):playRun()`, then `ClassProgress.runXp(result.payout.summary)` over 48 seeds. |

## 7. Priorities

1. **Fix B1** (record a Pressure clear only on a full clear) and **M1** (what counts as a win). **Replace the `deepestCycle` board (B3).**
2. **Surface what is already built:**
   - account level badge (M2)
   - active boost timers (M3)
   - a daily-ready dot in the lobby (M7)
   - an in-lobby leaderboard wall and a remote for it (B2)
   - "Owned" on passes and readable benefit details (m5, M9)
3. **Stop the auto-start from pulling a player out of the shop or perk tree** (M8).
4. **Reprice Golden Cheese items** (M4, M5), then ship the new shop structure with Featured, the deterministic daily rotation, the Starter Pack (99) and the bundles.
5. **Ship daily and weekly quests, then the Herd Pass** (399 premium). Add Mastery Stars (with the 30th perk point, m1), account rewards to level 100, and the collection log.
6. **Add cheese sinks.** Decide the talents-in-PvP question (M12).
